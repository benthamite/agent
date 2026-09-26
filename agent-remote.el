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
;; output, and sends typed replies and single keys to it.  Because it
;; drives the session buffers themselves, it reaches Claude and Codex
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
(require 'url-util)

;;;; Forward declarations

(defvar eat-terminal)
(declare-function eat-term-send-string "eat" (terminal string))
(declare-function claude-code-send-escape "claude-code" ())

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

;;;; Internal state

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

(defvar agent-remote--server nil
  "The listening server process, or nil when the server is stopped.")

(defconst agent-remote--keys
  '(("enter" . "\r") ("esc" . "\e") ("tab" . "\t") ("shift-tab" . "\e[Z")
    ("up" . "\e[A") ("down" . "\e[B") ("left" . "\e[D") ("right" . "\e[C")
    ("ctrl-c" . "\C-c") ("backspace" . "\d")
    ("1" . "1") ("2" . "2") ("3" . "3") ("4" . "4") ("5" . "5")
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
  "Start the remote-control server, replacing any running one."
  (agent-remote--stop)
  (let ((host (agent-remote--host)))
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
    (let ((authority (format "%s:%d" host (process-contact agent-remote--server
                                                          :service))))
      (process-put agent-remote--server :authority authority)
      (message "agent-remote: serving http://%s/" authority))))

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
      (agent-remote--respond proc (agent-remote--dispatch proc request)))))

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
RESPONSE is a list (STATUS CONTENT-TYPE BODY), BODY being a string."
  (pcase-let* ((`(,status ,type ,body) response)
               (bytes (encode-coding-string body 'utf-8-unix)))
    (process-send-string
     proc
     (concat (format "HTTP/1.1 %s\r\n" status)
             (format "Content-Type: %s\r\n" type)
             (format "Content-Length: %d\r\n" (length bytes))
             "Cache-Control: no-store\r\n"
             "X-Content-Type-Options: nosniff\r\n"
             "Connection: close\r\n\r\n"
             bytes))
    (process-send-eof proc)))

;;;; Routing

(defun agent-remote--dispatch (proc request)
  "Return the response to REQUEST received on connection PROC."
  (condition-case err
      (let ((method (plist-get request :method))
            (path (plist-get request :path)))
        (cond
         ((not (agent-remote--authority-ok-p proc request))
          (agent-remote--error "421 Misdirected Request" "Wrong host"))
         ((and (equal method "GET") (equal path "/"))
          (list "200 OK" "text/html; charset=utf-8" (agent-remote--page)))
         ((and (equal method "GET") (equal path "/api/sessions"))
          (agent-remote--json (list :sessions (agent-remote--sessions))))
         ((and (equal method "GET") (equal path "/api/output"))
          (agent-remote--json (agent-remote--output request)))
         ((not (equal method "POST"))
          (agent-remote--error "405 Method Not Allowed" "Method not allowed"))
         ((not (assoc "x-agent-remote" (plist-get request :headers)))
          (agent-remote--error "403 Forbidden" "Missing X-Agent-Remote header"))
         ((equal path "/api/send")
          (agent-remote--json (agent-remote--send request)))
         ((equal path "/api/key")
          (agent-remote--json (agent-remote--key request)))
         (t (agent-remote--error "404 Not Found" "Not found"))))
    (user-error (agent-remote--error "400 Bad Request" (cadr err)))
    (error (agent-remote--error "500 Internal Server Error"
                                (error-message-string err)))))

(defun agent-remote--authority-ok-p (proc request)
  "Return non-nil when REQUEST's Host header names the server on PROC.
PROC is a connection process, which inherits the expected authority
from its server's property list."
  (let ((authority (process-get proc :authority)))
    (and authority
         (equal (cdr (assoc "host" (plist-get request :headers)))
                authority))))

(defun agent-remote--page ()
  "Return the contents of the bundled phone page."
  (with-temp-buffer
    (insert-file-contents agent-remote--page-file)
    (buffer-string)))

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
          :backend (symbol-name (or (agent--detect-backend buffer) 'unknown))
          :account (agent--session-account-name buffer)
          :state (symbol-name (agent-session-display-state buffer))
          :changed (and changed (truncate changed))
          :snoozed (if (agent-session-snoozed-p buffer) t :false))))

(defun agent-remote--output (request)
  "Return the session summary and recent output named by REQUEST."
  (let* ((buffer (agent-remote--session-buffer
                  (agent-remote--query-param request "id")))
         (summary (agent-remote--session-summary buffer)))
    (append summary (list :output (agent-remote--buffer-tail buffer)))))

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

(defun agent-remote--send (request)
  "Submit the text in REQUEST's JSON body to the session it names."
  (let* ((args (agent-remote--json-body request))
         (buffer (agent-remote--session-buffer (alist-get 'id args)))
         (text (alist-get 'text args)))
    (unless (and (stringp text) (not (string-blank-p text)))
      (user-error "Nothing to send"))
    (agent-submit text buffer)
    (list :ok t)))

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
An escape to a Claude session goes through `claude-code-send-escape',
so the session notices when the escape interrupts a running turn."
  (with-current-buffer buffer
    (unless (and (local-variable-p 'eat-terminal) eat-terminal)
      (user-error "Session has no terminal to send keys to"))
    (if (and (equal key "esc")
             (eq (agent--detect-backend buffer) 'claude)
             (fboundp 'claude-code-send-escape))
        (claude-code-send-escape)
      (eat-term-send-string eat-terminal
                            (cdr (assoc key agent-remote--keys))))))

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
