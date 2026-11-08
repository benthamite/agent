;;; agent-remote.el --- Control AI sessions from a phone -*- lexical-binding: t -*-

;; Copyright (C) 2026

;; Author: Pablo Stafforini
;; URL: https://github.com/benthamite/agent
;; Version: 0.1
;; Package-Requires: ((emacs "30.0") (agent "0.1"))

;; This file is NOT part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; A small HTTP server that lets a phone watch and unblock the running
;; AI sessions.  `agent-remote-mode' serves a touch-friendly page and a
;; JSON API on the machine's Tailscale address: the page lists every
;; session with its state and account, shows a session's recent
;; output and, on request, its past conversation from the session's
;; transcript, sends typed replies, images and single keys to it, restarts it
;; under another account when it has run out of usage, starts a new
;; session in any folder it lets the phone browse to, snoozes it and exits it.
;; Because it drives the session buffers themselves, it reaches Claude and Codex
;; sessions under every account alike.
;;
;; The server closes every connection that does not come from
;; `agent-remote-allowed-networks', by default the range Tailscale
;; assigns to tailnet devices, so only devices on the tailnet can use
;; it.  Two checks keep web pages open in a browser on this machine
;; from driving it: every request must name the server's own
;; address in its Host header, which defeats DNS rebinding, and every
;; request that changes anything must carry the `X-Agent-Remote'
;; header, which a cross-origin page cannot send without a preflight
;; the server never approves.

;;; Code:

(require 'agent)
(require 'agent-report)
(require 'url-util)

;;;; Forward declarations

(defvar eat-terminal)
(defvar agent-log-redact-enabled)
(declare-function agent-log-redact-text "agent-log-redact" (text))
(declare-function eat-term-send-string "eat" (terminal string))

;;;; User options

(defgroup agent-remote nil
  "Control AI sessions from a phone over Tailscale."
  :group 'agent)

(defcustom agent-remote-host nil
  "Address the phone uses to reach the remote-control server.
When nil, use this machine's Tailscale IPv4 address as reported by
`agent-remote-tailscale-program'.  Requests must name this address in
their Host header."
  :type '(choice (const :tag "Tailscale address" nil) string)
  :group 'agent-remote)

(defcustom agent-remote-listen-address "0.0.0.0"
  "Local address the remote-control server binds to.
The default binds every IPv4 interface because the macOS Tailscale app
does not deliver connections to a socket bound to the Tailscale address
alone.  `agent-remote-allowed-networks' restricts who may connect."
  :type 'string
  :group 'agent-remote)

(defcustom agent-remote-allowed-networks '("100.64.0.0/10")
  "IPv4 networks, in CIDR notation, whose connections the server accepts.
The default is the range Tailscale assigns to tailnet devices.
Connections from any other address are closed without a response."
  :type '(repeat string)
  :group 'agent-remote)

(defcustom agent-remote-port 8787
  "TCP port the remote-control server listens on."
  :type 'natnum
  :group 'agent-remote)

(defcustom agent-remote-tailscale-program
  (or (executable-find "tailscale")
      "/Applications/Tailscale.app/Contents/MacOS/Tailscale")
  "Tailscale command-line program used to look up this machine's address."
  :type 'file
  :group 'agent-remote)

(defcustom agent-remote-output-lines 300
  "Maximum number of trailing lines of session output sent to the phone."
  :type 'natnum
  :group 'agent-remote)

(defcustom agent-remote-new-session-directory "~/"
  "Folder the new-session sheet starts in when opened from the session list.
Opened from a session, the sheet starts in that session's folder."
  :type 'directory
  :group 'agent-remote)

(defcustom agent-remote-history-bytes (* 4 1024 1024)
  "Most bytes of a session's transcript that one history request reads.
A request runs on Emacs's main thread, at roughly 12 ms per MiB, so
this bounds how long it can hold Emacs up.  Most of a transcript is not
conversation: expect 2 to 15 KiB of text per MiB read."
  :type 'natnum
  :group 'agent-remote)

;;;; Internal state

(defconst agent-remote--attachment-limit (* 16 1024 1024)
  "Most characters of base64 one image attachment may take.
The page shrinks images well below this before sending them.")

(defconst agent-remote--package-directory
  (file-name-directory
   (file-truename
    (concat (file-name-sans-extension (or load-file-name buffer-file-name))
            ".el")))
  "Absolute path to the source checkout holding this library.
Resolved through the `.el' file because Elpaca's build directory holds
only the Lisp files, not the bundled `etc/' directory.")

(defconst agent-remote--page-file
  (expand-file-name "etc/agent-remote.html" agent-remote--package-directory)
  "Absolute path to the bundled phone page.")

(defconst agent-remote--library-hash
  (with-temp-buffer
    (insert-file-contents
     (expand-file-name "agent-remote.el" agent-remote--package-directory))
    (secure-hash 'md5 (current-buffer)))
  "MD5 of this library's source as it stood when the library was loaded.
Part of `agent-remote--version': the API's shape is whatever was
loaded, whatever the file now says.")

(defvar agent-remote--page-hash nil
  "Cache of the page file's MD5, as (MODIFICATION-TIME . HASH).")

(defconst agent-remote--version-placeholder "__AGENT_REMOTE_VERSION__"
  "Text in the page that serving it replaces with `agent-remote--version'.")

(defvar agent-remote--server nil
  "The listening server process, or nil when the server is stopped.")

(defconst agent-remote--keys
  '(("enter" . "\r") ("esc" . "\e") ("tab" . "\t") ("shift-tab" . "\e[Z")
    ("up" . "\e[A") ("down" . "\e[B") ("left" . "\e[D") ("right" . "\e[C")
    ("ctrl-c" . "\C-c") ("backspace" . "\d")
    ("0" . "0") ("1" . "1") ("2" . "2") ("3" . "3") ("4" . "4") ("5" . "5")
    ("6" . "6") ("7" . "7") ("8" . "8") ("9" . "9")
    ("y" . "y") ("n" . "n"))
  "Alist mapping key names the phone may send to terminal input.")

;;;; Server lifecycle

;;;###autoload
(define-minor-mode agent-remote-mode
  "Serve the phone control page for AI sessions over Tailscale.
When enabled, listen on `agent-remote-host' and `agent-remote-port'."
  :global t
  :group 'agent-remote
  (if agent-remote-mode
      (condition-case err
          (agent-remote--start)
        (error
         (setq agent-remote-mode nil)
         (signal (car err) (cdr err))))
    (agent-remote--stop)))

(defun agent-remote--start ()
  "Start the remote-control server, replacing any running one.
The server starts even when Tailscale is disconnected; the address
requests must name is looked up when the first request arrives."
  (agent-remote--stop)
  (setq agent-remote--server
        (make-network-process
         :name "agent-remote"
         :server t
         :host agent-remote-listen-address
         :service agent-remote-port
         :family 'ipv4
         :coding 'binary
         :noquery t
         :filter #'agent-remote--filter
         :sentinel #'agent-remote--sentinel
         :log #'agent-remote--log))
  (let ((authority (ignore-error user-error (agent-remote--authority))))
    (message "agent-remote: serving %s"
             (if authority
                 (format "http://%s/" authority)
               (format "on port %d; Tailscale address not yet known"
                       (process-contact agent-remote--server :service))))))

(defun agent-remote--authority ()
  "Return the host and port requests must name, as \"HOST:PORT\".
Look the host up on first use and cache it on `agent-remote--server'.
Signal a `user-error' when the host cannot be determined."
  (or (process-get agent-remote--server :authority)
      (let ((authority (format "%s:%d" (agent-remote--host)
                               (process-contact agent-remote--server
                                                :service))))
        (process-put agent-remote--server :authority authority)
        authority)))

(defun agent-remote--stop ()
  "Stop the remote-control server if it is running."
  (when (process-live-p agent-remote--server)
    (delete-process agent-remote--server))
  (setq agent-remote--server nil))

(defun agent-remote--host ()
  "Return the address to listen on.
Use `agent-remote-host' when set, else this machine's Tailscale address."
  (or agent-remote-host
      (agent-remote--tailscale-address)))

(defun agent-remote--tailscale-address ()
  "Return this machine's Tailscale IPv4 address.
Signal an error when Tailscale is unavailable or not connected."
  (unless (and agent-remote-tailscale-program
               (file-executable-p agent-remote-tailscale-program))
    (user-error "Tailscale program not found: %s"
                agent-remote-tailscale-program))
  (let ((address (car (ignore-errors
                        (process-lines agent-remote-tailscale-program
                                       "ip" "-4")))))
    (unless (and address
                 (string-match-p "\\`[0-9]+\\(\\.[0-9]+\\)\\{3\\}\\'" address))
      (user-error "Tailscale reported no IPv4 address; is it connected?"))
    address))

;;;; HTTP transport

(defun agent-remote--log (_server connection _message)
  "Close CONNECTION unless it comes from `agent-remote-allowed-networks'."
  (unless (agent-remote--peer-allowed-p (process-contact connection :remote))
    (delete-process connection)))

(defun agent-remote--peer-allowed-p (address)
  "Return non-nil when ADDRESS lies in `agent-remote-allowed-networks'.
ADDRESS is an IPv4 address vector as returned by `process-contact',
whose final element is the port."
  (and (vectorp address)
       (= (length address) 5)
       (seq-some (lambda (network)
                   (agent-remote--address-in-network-p address network))
                 agent-remote-allowed-networks)))

(defun agent-remote--address-in-network-p (address network)
  "Return non-nil when IPv4 vector ADDRESS lies in CIDR string NETWORK."
  (pcase-let* ((`(,base ,bits) (split-string network "/"))
               (prefix (string-to-number bits))
               (mask (logand #xffffffff (ash #xffffffff (- 32 prefix)))))
    (= (logand (agent-remote--address-number address) mask)
       (logand (agent-remote--address-number
                (vconcat (mapcar #'string-to-number (split-string base "\\."))))
               mask))))

(defun agent-remote--address-number (address)
  "Return the first four octets of vector ADDRESS as one integer."
  (+ (ash (aref address 0) 24) (ash (aref address 1) 16)
     (ash (aref address 2) 8) (aref address 3)))

(defun agent-remote--sentinel (proc _event)
  "Delete connection PROC once it has closed."
  (unless (process-live-p proc)
    (delete-process proc)))

(defun agent-remote--filter (proc data)
  "Accumulate DATA from connection PROC and answer complete requests."
  (let ((input (concat (or (process-get proc :input) "") data)))
    (process-put proc :input input)
    (when-let* ((request (agent-remote--parse-request input)))
      (process-put proc :input nil)
      (agent-remote--respond proc (agent-remote--dispatch request)))))

(defun agent-remote--parse-request (input)
  "Parse the raw HTTP request INPUT, or return nil if it is incomplete.
The result is a plist with `:method', `:path', `:query', `:headers'
and `:body'.  Header names are downcased; the body is decoded as UTF-8."
  (when-let* ((end (string-search "\r\n\r\n" input)))
    (let* ((lines (split-string (substring input 0 end) "\r\n"))
           (request-line (split-string (car lines) " "))
           (headers (agent-remote--parse-headers (cdr lines)))
           (length (string-to-number
                    (or (cdr (assoc "content-length" headers)) "0")))
           (body-start (+ end 4)))
      (when (>= (- (length input) body-start) length)
        (let ((target (or (nth 1 request-line) "/")))
          (list :method (car request-line)
                :path (car (split-string target "?"))
                :query (url-parse-query-string
                        (or (cadr (split-string target "?")) ""))
                :headers headers
                :body (decode-coding-string
                       (substring input body-start (+ body-start length))
                       'utf-8-unix)))))))

(defun agent-remote--parse-headers (lines)
  "Return an alist of downcased header names to values from LINES."
  (delq nil
        (mapcar (lambda (line)
                  (when (string-match "\\`\\([^:]+\\):[ \t]*\\(.*\\)\\'" line)
                    (cons (downcase (match-string 1 line))
                          (match-string 2 line))))
                lines)))

(defun agent-remote--respond (proc response)
  "Send RESPONSE to connection PROC and close it.
RESPONSE is a list (STATUS CONTENT-TYPE BODY), BODY being a string.

A client may hang up before the response is written, as a phone does
when the page is closed or the network drops mid-request.  Writing to
the closed connection then fails and Emacs deletes PROC, which leaves
nobody to answer, so that failure is dropped.  An error on a
connection that is still live is re-signaled."
  (pcase-let* ((`(,status ,type ,body) response)
               (bytes (encode-coding-string body 'utf-8-unix)))
    (condition-case err
        (progn
          (process-send-string
           proc
           (concat (format "HTTP/1.1 %s\r\n" status)
                   (format "Content-Type: %s\r\n" type)
                   (format "Content-Length: %d\r\n" (length bytes))
                   "Cache-Control: no-store\r\n"
                   (format "X-Agent-Remote-Version: %s\r\n"
                           (agent-remote--version))
                   "X-Content-Type-Options: nosniff\r\n"
                   "Connection: close\r\n\r\n"
                   bytes))
          (process-send-eof proc))
      (error
       (when (process-live-p proc)
         (signal (car err) (cdr err)))))))

;;;; Routing

(defun agent-remote--dispatch (request)
  "Return the response to REQUEST."
  (condition-case err
      (let ((method (plist-get request :method))
            (path (plist-get request :path)))
        (cond
         ((not (agent-remote--authority-ok-p request))
          (agent-remote--error "421 Misdirected Request" "Wrong host"))
         ((and (equal method "GET") (equal path "/"))
          (list "200 OK" "text/html; charset=utf-8" (agent-remote--page)))
         ((and (equal method "GET") (equal path "/api/sessions"))
          (agent-remote--json (list :sessions (agent-remote--sessions))))
         ((and (equal method "GET") (equal path "/api/output"))
          (agent-remote--json (agent-remote--output request)))
         ((and (equal method "GET") (equal path "/api/history"))
          (agent-remote--json (agent-remote--history request)))
         ((and (equal method "GET") (equal path "/api/accounts"))
          (agent-remote--json (agent-remote--accounts request)))
         ((and (equal method "GET") (equal path "/api/icons"))
          (agent-remote--json (agent-remote--icons)))
         ((and (equal method "GET") (equal path "/api/backends"))
          (agent-remote--json (agent-remote--backends request)))
         ((and (equal method "GET") (equal path "/api/directories"))
          (agent-remote--json (agent-remote--directories request)))
         ((not (equal method "POST"))
          (agent-remote--error "405 Method Not Allowed" "Method not allowed"))
         ((not (assoc "x-agent-remote" (plist-get request :headers)))
          (agent-remote--error "403 Forbidden" "Missing X-Agent-Remote header"))
         ((equal path "/api/send")
          (agent-remote--json (agent-remote--send request)))
         ((equal path "/api/attach")
          (agent-remote--json (agent-remote--attach request)))
         ((equal path "/api/key")
          (agent-remote--json (agent-remote--key request)))
         ((equal path "/api/restart")
          (agent-remote--json (agent-remote--restart request)))
         ((equal path "/api/new")
          (agent-remote--json (agent-remote--new request)))
         ((equal path "/api/report")
          (agent-remote--json (agent-remote--report request)))
         ((equal path "/api/exit")
          (agent-remote--json (agent-remote--exit request)))
         ((equal path "/api/snooze")
          (agent-remote--json (agent-remote--snooze request)))
         (t (agent-remote--error "404 Not Found" "Not found"))))
    (user-error (agent-remote--error "400 Bad Request" (cadr err)))
    (error (agent-remote--error "500 Internal Server Error"
                                (error-message-string err)))))

(defun agent-remote--authority-ok-p (request)
  "Return non-nil when REQUEST's Host header names this server."
  (let ((authority (ignore-error user-error (agent-remote--authority))))
    (and authority
         (equal (cdr (assoc "host" (plist-get request :headers)))
                authority))))

(defun agent-remote--page ()
  "Return the bundled phone page, stamped with `agent-remote--version'."
  (with-temp-buffer
    (insert-file-contents agent-remote--page-file)
    (string-replace agent-remote--version-placeholder
                    (agent-remote--version)
                    (buffer-string))))

(defun agent-remote--version ()
  "Return a stamp that changes whenever the page or the loaded API does.
Every response carries it, and the page compares it with the one it was
served with: a phone that kept an older page open across an update then
reloads instead of misreading the newer API's answers."
  (concat (substring agent-remote--library-hash 0 12)
          (substring (agent-remote--page-hash) 0 12)))

(defun agent-remote--page-hash ()
  "Return the page file's MD5, rehashing only when the file changes."
  (let ((modified (file-attribute-modification-time
                   (file-attributes agent-remote--page-file))))
    (unless (equal modified (car agent-remote--page-hash))
      (setq agent-remote--page-hash
            (cons modified
                  (with-temp-buffer
                    (insert-file-contents agent-remote--page-file)
                    (secure-hash 'md5 (current-buffer))))))
    (cdr agent-remote--page-hash)))

(defun agent-remote--json (object)
  "Return a 200 response carrying OBJECT as JSON."
  (list "200 OK" "application/json"
        (json-serialize object :null-object nil)))

(defun agent-remote--error (status message)
  "Return an error response with STATUS and MESSAGE as JSON."
  (list status "application/json"
        (json-serialize (list :error message))))

;;;; Session API

(defun agent-remote--sessions ()
  "Return a vector describing every live session for the phone."
  (vconcat (mapcar #'agent-remote--session-summary (agent-session-buffers))))

(defun agent-remote--session-summary (buffer)
  "Return a plist describing session BUFFER for the phone."
  (let ((changed (buffer-local-value 'agent--session-state-changed-at buffer)))
    (list :id (buffer-name buffer)
          :name (agent-display-name buffer)
          :project (agent--buffer-session-name buffer)
          :backend (symbol-name (or (agent--detect-backend buffer) 'unknown))
          :account (agent--session-account-name buffer)
          :state (symbol-name (agent-session-display-state buffer))
          :changed (and changed (truncate changed))
          :snoozed (if (agent-session-snoozed-p buffer) t :false))))

(defun agent-remote--output (request)
  "Return the session summary and recent output named by REQUEST.
`screen' is what the output shows that the transcript cannot, for a
backend that can tell, and `terminal' whether the session takes keys.
When REQUEST has `after', `history' is what the session's transcript
gained since that byte offset; the phone page polls this, so polling
costs one file status check while nothing is new."
  (let* ((buffer (agent-remote--session-buffer
                  (agent-remote--query-param request "id")))
         (after (agent-remote--offset-param request "after"))
         (backend (agent-backend (agent--detect-backend buffer)))
         (output (agent-remote--buffer-tail buffer)))
    (append (agent-remote--session-summary buffer)
            (list :output output
                  :terminal (if (agent-remote--terminal-p buffer) t :false))
            (agent-remote--output-screen backend output)
            (and after (agent-remote--output-history backend buffer after)))))

(defun agent-remote--output-screen (backend output)
  "Return a plist with `:screen', the state of screen text OUTPUT, or nil.
BACKEND is the session's backend struct, or nil.  Without it the page
shows the whole screen, so a failure here is safe to swallow."
  (when-let* ((function (and backend (agent-backend-screen-state backend)))
              (state (ignore-errors (funcall function output))))
    (list :screen (list :status (plist-get state :status)
                        :mode (plist-get state :mode)
                        :running (if (plist-get state :running) t :false)
                        :writing (plist-get state :writing)
                        :card (plist-get state :card)
                        :options (vconcat (plist-get state :options))))))

(defun agent-remote--output-history (backend buffer after)
  "Return a plist with `:history' from byte offset AFTER, or nil.
BACKEND and BUFFER are the session's.  A failure leaves the poll's other
fields intact, and the next poll asks again from the same offset."
  (when-let* ((reader (and backend (agent-backend-session-history backend)))
              (history (ignore-errors
                         (funcall reader buffer agent-remote-history-bytes
                                  nil after))))
    (list :history (agent-remote--history-response history))))

(defun agent-remote--query-param (request name)
  "Return the UTF-8 decoded query parameter NAME of REQUEST, or nil."
  (when-let* ((value (cadr (assoc name (plist-get request :query)))))
    (decode-coding-string value 'utf-8-unix)))

(defun agent-remote--buffer-tail (buffer)
  "Return the last `agent-remote-output-lines' lines of BUFFER as text.
Trailing blank lines, which terminal buffers pad their screens with,
are dropped."
  (with-current-buffer buffer
    (save-excursion
      (goto-char (point-max))
      (skip-chars-backward " \t\n")
      (let ((end (point)))
        (forward-line (- 1 agent-remote-output-lines))
        (buffer-substring-no-properties (point) end)))))

(defun agent-remote--history (request)
  "Return a bounded stretch of the past conversation of REQUEST's session.
The session comes from REQUEST's `id', and its transcript from the
session buffer alone; `before' and `after' are only byte offsets into
it.  The stretch holds at most `agent-remote-history-bytes' bytes.  A
session without a transcript gets `available' false.  When its backend
keeps transcripts, `pending' true says one is still to come, as it is
for a session with no prompt yet, and its phone page shows an empty
conversation.  Otherwise the page shows just the screen."
  (let* ((buffer (agent-remote--session-buffer
                  (agent-remote--query-param request "id")))
         (before (agent-remote--offset-param request "before"))
         (after (agent-remote--offset-param request "after"))
         (backend (agent-backend (agent--detect-backend buffer)))
         (reader (and backend (agent-backend-session-history backend)))
         (history (and reader
                       (funcall reader buffer agent-remote-history-bytes
                                before after))))
    (if history
        (agent-remote--history-response history)
      (list :available :false :pending (if reader t :false)))))

(defun agent-remote--offset-param (request name)
  "Return query parameter NAME of REQUEST as a byte offset, or nil if absent.
Signal a user error when it is not a natural number."
  (when-let* ((value (agent-remote--query-param request name)))
    (unless (string-match-p "\\`[0-9]+\\'" value)
      (user-error "Bad offset: %s" name))
    (string-to-number value)))

(defun agent-remote--history-response (history)
  "Return the response describing HISTORY, with its text redacted.
HISTORY is a plist as `agent-util-jsonl-history' returns.
`redacted' says whether secrets were looked for, so the page can warn
when they were not."
  (let ((redactor (agent-remote--redactor)))
    (list :available t
          :session (plist-get history :session)
          :redacted (if redactor t :false)
          :messages (vconcat
                     (mapcar (lambda (message)
                               (agent-remote--history-message message redactor))
                             (plist-get history :messages)))
          :before (plist-get history :before)
          :after (plist-get history :after)
          :size (plist-get history :size)
          :gap (if (plist-get history :gap) t :false))))

(defun agent-remote--redactor ()
  "Return the function that redacts secrets from text, or nil if there is none.
`agent-log' is optional, so there is none when it is not installed, when
it fails to load, or when `agent-log-redact-enabled' is nil.  Loading
`agent-log-redact' also turns on its redaction of rendered logs."
  (when (and (ignore-errors (require 'agent-log-redact nil t))
             agent-log-redact-enabled)
    #'agent-log-redact-text))

(defun agent-remote--history-message (message redactor)
  "Return a copy of history MESSAGE whose text went through REDACTOR.
A nil REDACTOR leaves the text as it is.  When REDACTOR fails, as a
regexp can on very long text, hide the text rather than serve it
unredacted."
  (let ((text (plist-get message :text)))
    (list :role (plist-get message :role)
          :time (plist-get message :time)
          :text (if redactor
                    (condition-case nil
                        (funcall redactor text)
                      (error "[hidden: secret redaction failed]"))
                  text))))

(defun agent-remote--send (request)
  "Submit the text in REQUEST's JSON body to the session it names."
  (let* ((args (agent-remote--json-body request))
         (buffer (agent-remote--session-buffer (alist-get 'id args)))
         (text (alist-get 'text args)))
    (unless (and (stringp text) (not (string-blank-p text)))
      (user-error "Nothing to send"))
    (agent-submit text buffer)
    (list :ok t)))

(defun agent-remote--attach (request)
  "Save the base64 image in REQUEST's JSON body and return its file name.
The body's `data' holds a JPEG or PNG image, which goes to a temporary
file only this user can read.  A reply naming the file gives it to the
session.  The system's temporary-file cleanup removes the file."
  (let* ((data (alist-get 'data (agent-remote--json-body request)))
         (bytes (and (stringp data)
                     (<= (length data) agent-remote--attachment-limit)
                     (ignore-errors (base64-decode-string data))))
         (extension (and bytes (agent-remote--image-extension bytes))))
    (unless extension
      (user-error "Not a JPEG or PNG image of a usable size"))
    (let ((file (make-temp-file "agent-remote-" nil extension))
          (coding-system-for-write 'binary))
      (write-region bytes nil file nil 'silent)
      (list :ok t :path file))))

(defun agent-remote--image-extension (bytes)
  "Return the file extension for image BYTES, or nil if not a known image."
  (cond ((string-prefix-p "\xff\xd8\xff" bytes) ".jpg")
        ((string-prefix-p "\x89PNG\r\n\x1a\n" bytes) ".png")))

(defun agent-remote--key (request)
  "Send the key named in REQUEST's JSON body to the session it names."
  (let* ((args (agent-remote--json-body request))
         (buffer (agent-remote--session-buffer (alist-get 'id args)))
         (key (alist-get 'key args)))
    (unless (assoc key agent-remote--keys)
      (user-error "Unknown key: %s" key))
    (agent-remote--send-key buffer key)
    (list :ok t)))

(defun agent-remote--send-key (buffer key)
  "Send the key named KEY to the terminal of session BUFFER.
An escape goes through the backend's `:interrupt' function when it has
one, so the session notices when the escape interrupts a running turn,
and so it reaches a session that has no terminal."
  (let* ((backend (agent-backend (agent--detect-backend buffer)))
         (interrupt (and (equal key "esc") backend
                         (agent-backend-interrupt backend))))
    (if interrupt
        (funcall interrupt buffer)
      (unless (agent-remote--terminal-p buffer)
        (user-error "Session has no terminal to send keys to"))
      (with-current-buffer buffer
        (eat-term-send-string eat-terminal
                              (cdr (assoc key agent-remote--keys)))))))

(defun agent-remote--terminal-p (buffer)
  "Return non-nil when session BUFFER has a terminal that takes keys."
  (with-current-buffer buffer
    (and (local-variable-p 'eat-terminal) eat-terminal t)))

(defun agent-remote--accounts (request)
  "Return the accounts the session named by REQUEST can restart under.
The result lists the backend's pools and accounts in the order
`agent-account-select' offers them, with each account's latest usage."
  (let* ((buffer (agent-remote--session-buffer
                  (agent-remote--query-param request "id")))
         (backend (agent--detect-backend buffer)))
    (list :account (agent--session-account-name buffer)
          :selected (agent-account-current backend)
          :choices (vconcat
                    (mapcar (lambda (name)
                              (agent-remote--account-choice backend name))
                            (agent-account-selection-names backend))))))

(defun agent-remote--account-choice (backend name)
  "Return a plist describing BACKEND's account or pool NAME for the phone."
  (if (agent-account-pool-p backend name)
      (list :name name :pool t
            :members (vconcat (agent-account-pool-members backend name)))
    (let ((usage (agent-usage-get backend name)))
      (list :name name :pool :false
            :weekly (plist-get usage :weekly-pct)
            :session (plist-get usage :session-pct)
            :stale (if (and usage (not (agent-usage-fresh-p usage))) t :false)
            :limited (if (agent-account--limited-p backend name) t :false)
            :loggedIn (if (agent-account-logged-in-p backend name) t :false)))))

(defun agent-remote--restart (request)
  "Restart the session named in REQUEST's JSON body under its account.
Return the name of the new session buffer, which the phone follows."
  (let* ((args (agent-remote--json-body request))
         (buffer (agent-remote--session-buffer (alist-get 'id args)))
         (account (alist-get 'account args)))
    (unless (stringp account)
      (user-error "No account given"))
    (list :ok t
          :id (buffer-name (agent-restart-with-account buffer account)))))

(defun agent-remote--icons ()
  "Return a table of each backend's name to its icon's SVG source.
A backend without an icon is left out, and the page names it in text."
  (let ((icons (make-hash-table :test #'equal)))
    (pcase-dolist (`(,name . ,backend) agent-backends)
      (when-let* ((svg (agent-backend-icon-svg backend)))
        (puthash (symbol-name name) svg icons)))
    icons))

(defun agent-remote--backends (request)
  "Return what the new-session sheet opened from REQUEST starts with.
REQUEST's `id', when given, names the session the sheet was opened
from: the browser then starts in its directory and its backend comes
first.  Without one the browser starts in
`agent-remote-new-session-directory'."
  (let* ((id (agent-remote--query-param request "id"))
         (buffer (and id (agent-remote--session-buffer id)))
         (own (and buffer (agent--detect-backend buffer)))
         (backends (mapcar #'car agent-backends)))
    (list :directory (if buffer
                         (agent-session-directory (agent-session buffer))
                       agent-remote-new-session-directory)
          :choices (vconcat
                    (mapcar (lambda (backend)
                              (list :name (symbol-name backend)
                                    :label (or (agent-backend-label
                                                (agent-backend backend))
                                               (symbol-name backend))))
                            (if (memq own backends)
                                (cons own (delq own backends))
                              backends))))))

(defun agent-remote--directories (request)
  "Return the folder that REQUEST's `path' names and the folders in it.
Each folder is a plist of its `:name' and `:modified', the time it last
changed in seconds since the epoch, so the page can sort by either.
File name handlers stay off, so that no path a client sends can make
Emacs open a remote connection on its main thread."
  (let* ((file-name-handler-alist nil)
         (directory (agent-remote--directory
                     (agent-remote--query-param request "path")))
         (parent (file-name-directory (directory-file-name directory))))
    (list :path (abbreviate-file-name directory)
          :parent (unless (equal parent directory)
                    (abbreviate-file-name parent))
          :folders (vconcat (agent-remote--subdirectories directory)))))

(defun agent-remote--directory (path)
  "Return PATH as an absolute directory name, relative to home.
Signal a user error unless PATH names an existing directory."
  (let ((directory (and (stringp path)
                        (file-name-as-directory
                         (expand-file-name path "~/")))))
    (unless (and directory (file-directory-p directory))
      (user-error "Not a folder: %s" path))
    directory))

(defun agent-remote--subdirectories (directory)
  "Return DIRECTORY's subdirectories, sorted by name ignoring case.
Each is a plist of its `:name' and `:modified' time in whole seconds.
A symbolic link counts when it leads to a directory, and its time is
that directory's."
  (sort (seq-keep
         (lambda (entry)
           (let* ((name (car entry))
                  (attributes (cdr entry))
                  (type (file-attribute-type attributes)))
             (when (stringp type)
               (setq attributes
                     (file-attributes
                      (file-truename (expand-file-name name directory)))
                     type (file-attribute-type attributes)))
             (when (eq type t)
               (list :name name
                     :modified (truncate
                                (float-time (file-attribute-modification-time
                                             attributes)))))))
         (directory-files-and-attributes
          directory nil directory-files-no-dot-files-regexp t))
        :key (lambda (folder) (downcase (plist-get folder :name)))
        :in-place t))

(defun agent-remote--new (request)
  "Start a session as REQUEST's JSON body says.
The body's `directory' is where it runs and its `backend' names its
backend.  Return the new session buffer's name and display name, which
the phone follows."
  (let* ((args (agent-remote--json-body request))
         (directory (let ((file-name-handler-alist nil))
                      (agent-remote--directory (alist-get 'directory args))))
         (name (alist-get 'backend args))
         (backend (and (stringp name) (intern-soft name))))
    (unless backend
      (user-error "No backend given"))
    (let ((buffer (agent-start-session-in
                   (abbreviate-file-name directory) backend)))
      (list :ok t
            :id (buffer-name buffer)
            :name (agent-display-name buffer)))))

(defun agent-remote--report (request)
  "Start a session that turns the report in REQUEST's JSON body into a PR.
The body's `text' is the report and its `backend' names the backend, as
for `agent-report-submit'.  Return the new session buffer's name and
display name, which the phone follows."
  (let* ((args (agent-remote--json-body request))
         (text (alist-get 'text args))
         (name (alist-get 'backend args))
         (backend (and (stringp name) (intern-soft name))))
    (unless (and (stringp text) (not (string-blank-p text)))
      (user-error "No report given"))
    (unless backend
      (user-error "No backend given"))
    (let ((buffer (agent-report-submit (string-trim text) backend)))
      (list :ok t
            :id (buffer-name buffer)
            :name (agent-display-name buffer)))))

(defun agent-remote--exit (request)
  "Exit the session named in REQUEST's JSON body.
The body's `skills' is false to skip the before-exit skills."
  (let* ((args (agent-remote--json-body request))
         (buffer (agent-remote--session-buffer (alist-get 'id args))))
    (agent-exit-buffer buffer (eq (alist-get 'skills args) :false))
    (list :ok t)))

(defun agent-remote--snooze (request)
  "Snooze or unsnooze the session named in REQUEST's JSON body.
The body's `snoozed' is true to snooze and false to unsnooze, so that a
repeated request cannot undo the first.  A snooze from the phone is
indefinite."
  (let* ((args (agent-remote--json-body request))
         (buffer (agent-remote--session-buffer (alist-get 'id args)))
         (wanted (eq (alist-get 'snoozed args) t)))
    (unless (eq wanted (and (agent-session-snoozed-p buffer) t))
      (agent-toggle-snooze buffer))
    (list :ok t)))

(defun agent-remote--json-body (request)
  "Return REQUEST's body parsed as a JSON object, as an alist."
  (condition-case nil
      (json-parse-string (plist-get request :body) :object-type 'alist)
    (json-error (user-error "Request body is not valid JSON"))))

(defun agent-remote--session-buffer (id)
  "Return the live session buffer whose name is ID.
Signal a user error when no session has that name."
  (let ((buffer (and (stringp id) (get-buffer id))))
    (unless (and buffer (memq buffer (agent-session-buffers)))
      (user-error "No such session: %s" id))
    buffer))

(provide 'agent-remote)

;;; agent-remote.el ends here
