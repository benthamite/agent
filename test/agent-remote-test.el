;;; agent-remote-test.el --- Tests for agent-remote -*- lexical-binding: t -*-

;; Tests for the phone remote-control server in agent-remote.el.

;;; Code:

(require 'ert)
(require 'agent-test-helper
         (expand-file-name "agent-test-helper"
                           (file-name-directory (or load-file-name buffer-file-name))))
(require 'cl-lib)
(require 'agent-remote)
(require 'agent-claude-cli)

;;;; Helpers

(defmacro agent-remote-test--with-server (&rest body)
  "Run BODY with the remote server listening on a free loopback port."
  (declare (indent 0))
  `(let ((agent-remote-host "127.0.0.1")
         (agent-remote-listen-address "127.0.0.1")
         (agent-remote-allowed-networks '("127.0.0.0/8"))
         (agent-remote-port t)
         (agent-remote--server nil))
     (unwind-protect
         (progn (agent-remote--start) ,@body)
       (agent-remote--stop))))

(defun agent-remote-test--request (raw)
  "Send RAW to the running test server and return the full response text."
  (let* ((port (process-contact agent-remote--server :service))
         (response "")
         (client (make-network-process
                  :name "agent-remote-test-client" :host "127.0.0.1"
                  :service port :coding 'binary
                  :filter (lambda (_proc data)
                            (setq response (concat response data))))))
    (unwind-protect
        (progn
          (process-send-string client raw)
          (with-timeout (5 (error "No response from server"))
            (while (process-live-p client)
              (accept-process-output nil 0.05)))
          (decode-coding-string response 'utf-8-unix))
      (delete-process client))))

(defun agent-remote-test--http (method path &optional body headers host)
  "Send an HTTP METHOD request for PATH with BODY and extra HEADERS.
HOST overrides the Host header, which defaults to the server's own."
  (let ((bytes (encode-coding-string (or body "") 'utf-8-unix)))
    (agent-remote-test--request
     (concat (format "%s %s HTTP/1.1\r\n" method path)
             (format "Host: %s\r\n"
                     (or host (process-get agent-remote--server :authority)))
             (mapconcat (lambda (h) (concat h "\r\n")) headers "")
             (format "Content-Length: %d\r\n\r\n" (length bytes))
             bytes))))

(defun agent-remote-test--status (response)
  "Return the numeric status code of RESPONSE."
  (string-to-number (nth 1 (split-string response " "))))

(defun agent-remote-test--json (response)
  "Return the JSON body of RESPONSE parsed as an alist."
  (json-parse-string (cadr (split-string response "\r\n\r\n"))
                     :object-type 'alist :array-type 'list))

;;;; Loading

(ert-deftest agent-remote-test-loads ()
  "Loading the test file provides the `agent-remote' feature."
  (should (featurep 'agent-remote)))

;;;; Request parsing

(ert-deftest agent-remote-test-parse-incomplete-headers ()
  "A request whose headers have not all arrived is not parsed."
  (should-not (agent-remote--parse-request "GET / HTTP/1.1\r\nHost: x\r\n")))

(ert-deftest agent-remote-test-parse-waits-for-body ()
  "A request whose body is shorter than its Content-Length is not parsed."
  (should-not (agent-remote--parse-request
               "POST /api/send HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc")))

(ert-deftest agent-remote-test-parse-complete-request ()
  "A complete request yields its method, path, query, headers and body."
  (let ((request (agent-remote--parse-request
                  (concat "POST /api/output?id=%2Afoo%20bar%2A HTTP/1.1\r\n"
                          "Host: h:1\r\nContent-Length: 2\r\n\r\nhi"))))
    (should (equal (plist-get request :method) "POST"))
    (should (equal (plist-get request :path) "/api/output"))
    (should (equal (agent-remote--query-param request "id") "*foo bar*"))
    (should (equal (cdr (assoc "host" (plist-get request :headers))) "h:1"))
    (should (equal (plist-get request :body) "hi"))))

(ert-deftest agent-remote-test-parse-utf8-body ()
  "Content-Length counts bytes, and the body is decoded as UTF-8."
  (let* ((bytes (encode-coding-string "{\"text\":\"¿sí?\"}" 'utf-8-unix))
         (request (agent-remote--parse-request
                   (concat (format "POST /api/send HTTP/1.1\r\nContent-Length: %d\r\n\r\n"
                                   (length bytes))
                           bytes))))
    (should (equal (plist-get request :body) "{\"text\":\"¿sí?\"}"))))

;;;; Host lookup

(ert-deftest agent-remote-test-host-prefers-option ()
  "An explicit `agent-remote-host' is used without asking Tailscale."
  (let ((agent-remote-host "10.0.0.5"))
    (cl-letf (((symbol-function 'agent-remote--tailscale-address)
               (lambda () (error "Should not be called"))))
      (should (equal (agent-remote--host) "10.0.0.5")))))

(ert-deftest agent-remote-test-missing-tailscale-errors ()
  "A missing Tailscale program is reported instead of guessing an address."
  (let ((agent-remote-host nil)
        (agent-remote-tailscale-program "/nonexistent/tailscale"))
    (should-error (agent-remote--host) :type 'user-error)))

(ert-deftest agent-remote-test-starts-before-tailscale ()
  "The server starts while Tailscale is down and serves once it is up."
  (let ((address nil))
    (cl-letf (((symbol-function 'agent-remote--tailscale-address)
               (lambda ()
                 (or address (user-error "Tailscale reported no address")))))
      (agent-remote-test--with-server
        (let ((agent-remote-host nil)
              port)
          (agent-remote--start)
          (setq port (process-contact agent-remote--server :service))
          (should (process-live-p agent-remote--server))
          (should (= (agent-remote-test--status
                      (agent-remote-test--http
                       "GET" "/" nil nil (format "127.0.0.1:%d" port)))
                     421))
          (setq address "127.0.0.1")
          (should (= (agent-remote-test--status
                      (agent-remote-test--http
                       "GET" "/" nil nil (format "127.0.0.1:%d" port)))
                     200)))))))

;;;; Peer filtering

(ert-deftest agent-remote-test-address-in-network ()
  "CIDR matching honours the prefix length."
  (should (agent-remote--address-in-network-p [100 99 24 38 5000]
                                              "100.64.0.0/10"))
  (should (agent-remote--address-in-network-p [100 127 255 255 1]
                                              "100.64.0.0/10"))
  (should-not (agent-remote--address-in-network-p [100 128 0 1 1]
                                                  "100.64.0.0/10"))
  (should-not (agent-remote--address-in-network-p [192 168 68 104 1]
                                                  "100.64.0.0/10")))

(ert-deftest agent-remote-test-peer-must-be-ipv4-address ()
  "Anything but an IPv4 address vector is refused."
  (let ((agent-remote-allowed-networks '("0.0.0.0/0")))
    (should (agent-remote--peer-allowed-p [10 0 0 1 80]))
    (should-not (agent-remote--peer-allowed-p nil))
    (should-not (agent-remote--peer-allowed-p [0 0 0 0 0 0 0 1 80]))))

(ert-deftest agent-remote-test-disallowed-peer-gets-no-response ()
  "A connection from outside the allowed networks is closed unanswered."
  (agent-remote-test--with-server
    (let ((agent-remote-allowed-networks '("100.64.0.0/10")))
      (should (equal (agent-remote-test--http "GET" "/api/sessions") "")))))

;;;; Security checks over a live connection

(ert-deftest agent-remote-test-rejects-foreign-host ()
  "A request naming another host is refused, defeating DNS rebinding."
  (agent-remote-test--with-server
    (let ((response (agent-remote-test--http "GET" "/api/sessions" nil nil
                                             "evil.example:80")))
      (should (= (agent-remote-test--status response) 421)))))

(ert-deftest agent-remote-test-post-requires-custom-header ()
  "A state-changing request without X-Agent-Remote is refused."
  (agent-remote-test--with-server
    (let ((response (agent-remote-test--http
                     "POST" "/api/send" "{\"id\":\"x\",\"text\":\"hi\"}"
                     '("Content-Type: text/plain"))))
      (should (= (agent-remote-test--status response) 403)))))

(ert-deftest agent-remote-test-serves-page ()
  "The root path serves the bundled HTML page."
  (agent-remote-test--with-server
    (let ((response (agent-remote-test--http "GET" "/")))
      (should (= (agent-remote-test--status response) 200))
      (should (string-match-p "text/html" response))
      (should (string-match-p "<title>Agents</title>" response)))))

;;;; Session API

(defmacro agent-remote-test--with-session (var &rest body)
  "Run BODY with VAR bound to a temporary buffer registered as a session."
  (declare (indent 1))
  `(let ((,var (generate-new-buffer "*claude:~/proj/:default*")))
     (unwind-protect
         (cl-letf (((symbol-function 'agent-session-buffers)
                    (lambda () (list ,var)))
                   ((symbol-function 'agent-display-name) (lambda (_) "proj"))
                   ((symbol-function 'agent--detect-backend) (lambda (_) 'claude))
                   ((symbol-function 'agent--session-account-name)
                    (lambda (_) "personal"))
                   ((symbol-function 'agent-session-display-state)
                    (lambda (_) 'waiting))
                   ((symbol-function 'agent-session-snoozed-p) #'ignore))
           ,@body)
       (kill-buffer ,var))))

(ert-deftest agent-remote-test-lists-sessions ()
  "The sessions endpoint describes each live session."
  (agent-remote-test--with-session buffer
    (with-current-buffer buffer
      (setq-local agent--session-state-changed-at 1000.5))
    (agent-remote-test--with-server
      (let* ((response (agent-remote-test--http "GET" "/api/sessions"))
             (session (car (alist-get 'sessions
                                      (agent-remote-test--json response)))))
        (should (= (agent-remote-test--status response) 200))
        (should (equal (alist-get 'id session) (buffer-name buffer)))
        (should (equal (alist-get 'name session) "proj"))
        (should (equal (alist-get 'account session) "personal"))
        (should (equal (alist-get 'state session) "waiting"))
        (should (equal (alist-get 'changed session) 1000))
        (should (eq (alist-get 'snoozed session) :false))))))

(ert-deftest agent-remote-test-output-drops-trailing-blank-lines ()
  "The output endpoint returns the buffer tail without screen padding."
  (agent-remote-test--with-session buffer
    (with-current-buffer buffer (insert "line 1\nline 2\n\n   \n"))
    (agent-remote-test--with-server
      (let ((response (agent-remote-test--http
                       "GET" (concat "/api/output?id="
                                     (url-hexify-string (buffer-name buffer))))))
        (should (equal (alist-get 'output (agent-remote-test--json response))
                       "line 1\nline 2"))))))

(ert-deftest agent-remote-test-output-limits-lines ()
  "Only the last `agent-remote-output-lines' lines are returned."
  (agent-remote-test--with-session buffer
    (with-current-buffer buffer (insert "a\nb\nc\nd"))
    (let ((agent-remote-output-lines 2))
      (should (equal (agent-remote--buffer-tail buffer) "c\nd")))))

;;;; History

(defconst agent-remote-test--transcript
  (concat
   "{\"type\":\"user\",\"timestamp\":\"2026-11-04T10:00:00Z\",\"message\":{\"content\":\"older question\"}}\n"
   "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"tool_use\",\"name\":\"Bash\",\"input\":{}}]}}\n"
   "{\"type\":\"assistant\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"older ñ answer\"}]}}\n")
  "A fixture transcript.")

(defmacro agent-remote-test--with-history (buffer &rest body)
  "Run BODY with session BUFFER reading history from a fixture transcript.
BODY can refer to the transcript as `file'."
  (declare (indent 1))
  `(let ((file (make-temp-file "agent-remote-transcript-" nil ".jsonl")))
     (unwind-protect
         (let ((coding-system-for-write 'utf-8-unix)
               (backend (agent-backend--create
                         :session-history
                         (lambda (_buffer bytes &optional before after)
                           (agent-claude-cli-transcript-history
                            file bytes before after)))))
           (write-region agent-remote-test--transcript nil file nil 'silent)
           (agent-remote-test--with-session ,buffer
             (cl-letf (((symbol-function 'agent-backend) (lambda (_) backend))
                       ((symbol-function 'agent-remote--redactor) #'ignore))
               (agent-remote-test--with-server ,@body))))
       (delete-file file))))

(defun agent-remote-test--history-path (buffer &optional query)
  "Return the history path for session BUFFER, with extra QUERY text."
  (concat "/api/history?id=" (url-hexify-string (buffer-name buffer))
          (or query "")))

(ert-deftest agent-remote-test-history-returns-conversation ()
  "The history endpoint returns the messages and how much there is."
  (agent-remote-test--with-history buffer
    (let* ((response (agent-remote-test--http
                      "GET" (agent-remote-test--history-path buffer)))
           (data (agent-remote-test--json response)))
      (should (= (agent-remote-test--status response) 200))
      (should (eq (alist-get 'available data) t))
      (should (equal (mapcar (lambda (m) (alist-get 'role m))
                             (alist-get 'messages data))
                     '("user" "tool" "assistant")))
      (should (equal (alist-get 'text (car (alist-get 'messages data)))
                     "older question"))
      (should (equal (alist-get 'text (nth 2 (alist-get 'messages data)))
                     "older ñ answer"))
      (should (= (alist-get 'before data) 0))
      (should (= (alist-get 'size data)
                 (string-bytes agent-remote-test--transcript)))
      (should (eq (alist-get 'redacted data) :false)))))

(ert-deftest agent-remote-test-history-is-bounded-by-the-option ()
  "A request reads no more than `agent-remote-history-bytes'."
  (agent-remote-test--with-history buffer
    (let* ((agent-remote-history-bytes 60)
           (data (agent-remote-test--json
                  (agent-remote-test--http
                   "GET" (agent-remote-test--history-path buffer)))))
      (should (> (alist-get 'before data) 0)))))

(ert-deftest agent-remote-test-history-takes-offsets-only ()
  "Offsets must be numbers, and nothing in a request can name a file."
  (agent-remote-test--with-history buffer
    (should (= 400 (agent-remote-test--status
                    (agent-remote-test--http
                     "GET" (agent-remote-test--history-path
                            buffer "&before=../../etc/passwd")))))
    (should (= 400 (agent-remote-test--status
                    (agent-remote-test--http
                     "GET" (agent-remote-test--history-path buffer "&after=-1")))))
    (let ((other (make-temp-file "agent-remote-other-" nil ".jsonl"
                                 "{\"type\":\"user\",\"message\":{\"content\":\"other file\"}}\n")))
      (unwind-protect
          (let ((response (agent-remote-test--http
                           "GET" (agent-remote-test--history-path
                                  buffer (concat "&file=" other "&path=" other)))))
            (should-not (string-search "other file" response))
            (should (string-search "older question" response))
            (should-not (string-search (file-name-nondirectory file) response)))
        (delete-file other)))))

(ert-deftest agent-remote-test-history-requires-a-session-and-the-right-host ()
  "History obeys the same session and authority checks as the rest."
  (agent-remote-test--with-history buffer
    (should (= 400 (agent-remote-test--status
                    (agent-remote-test--http "GET" "/api/history?id=nope"))))
    (should (= 400 (agent-remote-test--status
                    (agent-remote-test--http "GET" "/api/history"))))
    (should (= 421 (agent-remote-test--status
                    (agent-remote-test--http
                     "GET" (agent-remote-test--history-path buffer)
                     nil nil "evil.example:80"))))))

(ert-deftest agent-remote-test-history-unavailable-without-a-reader ()
  "A backend with no transcript support, like Codex, gets `available' false."
  (agent-remote-test--with-session buffer
    (cl-letf (((symbol-function 'agent-backend)
               (lambda (_) (agent-backend--create))))
      (agent-remote-test--with-server
        (let ((data (agent-remote-test--json
                     (agent-remote-test--http
                      "GET" (agent-remote-test--history-path buffer)))))
          (should (eq (alist-get 'available data) :false)))))))

(ert-deftest agent-remote-test-history-unavailable-without-a-transcript ()
  "A session with no transcript yet gets `available' false."
  (agent-remote-test--with-session buffer
    (cl-letf (((symbol-function 'agent-backend)
               (lambda (_) (agent-backend--create :session-history #'ignore))))
      (agent-remote-test--with-server
        (let ((data (agent-remote-test--json
                     (agent-remote-test--http
                      "GET" (agent-remote-test--history-path buffer)))))
          (should (eq (alist-get 'available data) :false)))))))

(ert-deftest agent-remote-test-output-never-reads-history ()
  "The polled output endpoint does not touch the transcript."
  (agent-remote-test--with-session buffer
    (cl-letf (((symbol-function 'agent-backend)
               (lambda (_) (agent-backend--create
                            :session-history
                            (lambda (&rest _) (error "History was read"))))))
      (agent-remote-test--with-server
        (should (= 200 (agent-remote-test--status
                        (agent-remote-test--http
                         "GET" (concat "/api/output?id="
                                       (url-hexify-string (buffer-name buffer)))))))))))

(ert-deftest agent-remote-test-output-with-after-brings-what-is-new ()
  "A poll with `after' carries only what the transcript gained."
  (agent-remote-test--with-history buffer
    (let* ((size (string-bytes agent-remote-test--transcript))
           (path (concat "/api/output?id=" (url-hexify-string (buffer-name buffer))))
           (quiet (agent-remote-test--json
                   (agent-remote-test--http "GET" (format "%s&after=%d" path size))))
           (history (alist-get 'history quiet)))
      (should (null (alist-get 'messages history)))
      (should (= (alist-get 'after history) size))
      (with-temp-buffer
        (insert "{\"type\":\"user\",\"message\":{\"content\":\"new one\"}}\n")
        (write-region nil nil file t 'silent))
      (let ((grown (alist-get 'history
                              (agent-remote-test--json
                               (agent-remote-test--http
                                "GET" (format "%s&after=%d" path size))))))
        (should (equal (mapcar (lambda (m) (alist-get 'text m))
                               (alist-get 'messages grown))
                       '("new one")))
        (should (> (alist-get 'after grown) size))))))

(ert-deftest agent-remote-test-output-survives-a-failing-reader ()
  "A failing transcript read leaves the poll's screen intact."
  (agent-remote-test--with-session buffer
    (with-current-buffer buffer (insert "screen"))
    (cl-letf (((symbol-function 'agent-backend)
               (lambda (_) (agent-backend--create
                            :session-history
                            (lambda (&rest _) (error "Read failed"))))))
      (let ((data (agent-remote--output
                   (list :query (list (list "id" (buffer-name buffer))
                                      (list "after" "10"))))))
        (should (equal (plist-get data :output) "screen"))
        (should-not (plist-member data :history))))))

(ert-deftest agent-remote-test-output-carries-the-screen-state ()
  "The backend's reading of the screen reaches the page, if it has one."
  (agent-remote-test--with-session buffer
    (with-current-buffer buffer (insert "screen"))
    (let ((path (concat "/api/output?id=" (url-hexify-string (buffer-name buffer)))))
      (cl-letf (((symbol-function 'agent-backend)
                 (lambda (_) (agent-backend--create
                              :screen-state
                              (lambda (text)
                                (should (equal text "screen"))
                                (list :status "Forging…" :running t
                                      :card "A dialog" :options '("1" "2")))))))
        (agent-remote-test--with-server
          (let ((state (alist-get 'screen
                                  (agent-remote-test--json
                                   (agent-remote-test--http "GET" path)))))
            (should (equal (alist-get 'status state) "Forging…"))
            (should (eq (alist-get 'running state) t))
            (should (equal (alist-get 'card state) "A dialog"))
            (should (equal (alist-get 'options state) '("1" "2"))))))
      (cl-letf (((symbol-function 'agent-backend)
                 (lambda (_) (agent-backend--create))))
        (agent-remote-test--with-server
          (should-not (alist-get 'screen
                                 (agent-remote-test--json
                                  (agent-remote-test--http "GET" path)))))))))

(ert-deftest agent-remote-test-history-message-redacts ()
  "Message text goes through the redactor, and is hidden if that fails."
  (let ((message '(:role "user" :text "secret" :time "t")))
    (should (equal (agent-remote--history-message message #'upcase)
                   '(:role "user" :time "t" :text "SECRET")))
    (should (equal (plist-get (agent-remote--history-message
                               message (lambda (_) (error "Stack overflow")))
                              :text)
                   "[hidden: secret redaction failed]"))
    (should (equal (plist-get (agent-remote--history-message message nil) :text)
                   "secret"))))

(ert-deftest agent-remote-test-history-reports-redaction ()
  "The response says whether a redactor ran."
  (should (eq (plist-get (cl-letf (((symbol-function 'agent-remote--redactor)
                                    (lambda () #'identity)))
                           (agent-remote--history-response '(:messages nil)))
                         :redacted)
              t))
  (should (eq (plist-get (cl-letf (((symbol-function 'agent-remote--redactor)
                                    #'ignore))
                           (agent-remote--history-response '(:messages nil)))
                         :redacted)
              :false)))

(ert-deftest agent-remote-test-redactor-absent-without-agent-log ()
  "Without `agent-log' there is no redactor, and no error."
  (let ((load-path nil)
        (features (remq 'agent-log-redact features)))
    (should-not (agent-remote--redactor))))

(ert-deftest agent-remote-test-redactor-uses-agent-log ()
  "With `agent-log' installed, a token in the history is redacted."
  (skip-unless (locate-library "agent-log-redact"))
  (let ((redactor (agent-remote--redactor))
        (token (concat "ghp_" (make-string 40 ?a))))
    (should (eq redactor 'agent-log-redact-text))
    (should-not (string-search token (funcall redactor (concat "x " token))))
    (let ((agent-log-redact-enabled nil))
      (should-not (agent-remote--redactor)))))

(ert-deftest agent-remote-test-send-submits-text ()
  "The send endpoint submits the text to the named session."
  (agent-remote-test--with-session buffer
    (let (submitted)
      (cl-letf (((symbol-function 'agent-submit)
                 (lambda (text buf) (setq submitted (list text buf)))))
        (agent-remote-test--with-server
          (let ((response (agent-remote-test--http
                           "POST" "/api/send"
                           (json-serialize (list :id (buffer-name buffer)
                                                 :text "¿sí?"))
                           '("X-Agent-Remote: 1"))))
            (should (= (agent-remote-test--status response) 200))
            (should (equal submitted (list "¿sí?" buffer)))))))))

(ert-deftest agent-remote-test-send-rejects-unknown-session ()
  "Sending to a buffer that is not a session is refused."
  (agent-remote-test--with-session _buffer
    (agent-remote-test--with-server
      (let ((response (agent-remote-test--http
                       "POST" "/api/send"
                       "{\"id\":\"*scratch*\",\"text\":\"hi\"}"
                       '("X-Agent-Remote: 1"))))
        (should (= (agent-remote-test--status response) 400))))))

(ert-deftest agent-remote-test-key-sends-terminal-sequence ()
  "The key endpoint sends the mapped sequence to the session terminal."
  (agent-remote-test--with-session buffer
    (with-current-buffer buffer (setq-local eat-terminal 'fake-terminal))
    (let (sent)
      (cl-letf (((symbol-function 'eat-term-send-string)
                 (lambda (terminal string) (setq sent (list terminal string)))))
        (agent-remote--send-key buffer "down")
        (should (equal sent '(fake-terminal "\e[B")))))))

(ert-deftest agent-remote-test-claude-escape-goes-through-claude-code ()
  "Escape to a Claude session uses `claude-code-send-escape'."
  (agent-remote-test--with-session buffer
    (with-current-buffer buffer (setq-local eat-terminal 'fake-terminal))
    (let (called-in)
      (cl-letf (((symbol-function 'claude-code-send-escape)
                 (lambda () (setq called-in (current-buffer))))
                ((symbol-function 'eat-term-send-string)
                 (lambda (&rest _) (error "Should not send raw escape"))))
        (agent-remote--send-key buffer "esc")
        (should (eq called-in buffer))))))

(ert-deftest agent-remote-test-every-digit-is-a-key ()
  "A dialog's option or a notice's can have any digit."
  (dolist (digit (number-sequence 0 9))
    (should (equal (cdr (assoc (number-to-string digit) agent-remote--keys))
                   (number-to-string digit)))))

(ert-deftest agent-remote-test-unknown-key-rejected ()
  "A key name outside the allowed set is refused."
  (agent-remote-test--with-session buffer
    (agent-remote-test--with-server
      (let ((response (agent-remote-test--http
                       "POST" "/api/key"
                       (json-serialize (list :id (buffer-name buffer)
                                             :key "rm -rf"))
                       '("X-Agent-Remote: 1"))))
        (should (= (agent-remote-test--status response) 400))))))

(ert-deftest agent-remote-test-accounts-lists-choices-with-usage ()
  "The accounts endpoint lists pools and accounts with their usage."
  (agent-remote-test--with-session buffer
    (cl-letf (((symbol-function 'agent-account-current) (lambda (_) "p"))
              ((symbol-function 'agent-account-selection-names)
               (lambda (_) '("p" "e1")))
              ((symbol-function 'agent-account-pool-p)
               (lambda (_ name) (equal name "p")))
              ((symbol-function 'agent-account-pool-members)
               (lambda (&rest _) '("e1")))
              ((symbol-function 'agent-usage-get)
               (lambda (&rest _) (list :weekly-pct 100.0 :session-pct 20.0
                                       :fetched-at (float-time))))
              ((symbol-function 'agent-account-logged-in-p) (lambda (&rest _) t)))
      (agent-remote-test--with-server
        (let* ((data (agent-remote-test--json
                      (agent-remote-test--http
                       "GET" (concat "/api/accounts?id="
                                     (url-hexify-string (buffer-name buffer))))))
               (choices (alist-get 'choices data)))
          (should (equal (alist-get 'account data) "personal"))
          (should (equal (alist-get 'selected data) "p"))
          (should (equal (mapcar (lambda (c) (alist-get 'name c)) choices)
                         '("p" "e1")))
          (should (equal (alist-get 'members (car choices)) '("e1")))
          (should (eq (alist-get 'limited (cadr choices)) t))
          (should (equal (alist-get 'weekly (cadr choices)) 100.0)))))))

(ert-deftest agent-remote-test-restart-uses-chosen-account ()
  "The restart endpoint restarts the session with the chosen account."
  (agent-remote-test--with-session buffer
    (let (called)
      (cl-letf (((symbol-function 'agent-restart-with-account)
                 (lambda (buf account) (setq called (list buf account)) buf)))
        (agent-remote-test--with-server
          (let ((response (agent-remote-test--http
                           "POST" "/api/restart"
                           (json-serialize (list :id (buffer-name buffer)
                                                 :account "work"))
                           '("X-Agent-Remote: 1"))))
            (should (= (agent-remote-test--status response) 200))
            (should (equal (alist-get 'id (agent-remote-test--json response))
                           (buffer-name buffer)))
            (should (equal called (list buffer "work")))))))))

(ert-deftest agent-remote-test-backends-lists-own-backend-first ()
  "The backends endpoint offers the session's own backend first."
  (agent-remote-test--with-session buffer
    (let ((agent-backends
           (list (cons 'codex (agent-backend--create :label "Codex"))
                 (cons 'claude (agent-backend--create)))))
      (cl-letf (((symbol-function 'agent-session)
                 (lambda (_) (agent-session-create :backend 'claude
                                                   :directory "~/proj/"))))
        (agent-remote-test--with-server
          (let ((data (agent-remote-test--json
                       (agent-remote-test--http
                        "GET" (concat "/api/backends?id="
                                      (url-hexify-string
                                       (buffer-name buffer)))))))
            (should (equal (alist-get 'directory data) "~/proj/"))
            (should (equal (mapcar (lambda (c) (alist-get 'name c))
                                   (alist-get 'choices data))
                           '("claude" "codex")))
            (should (equal (mapcar (lambda (c) (alist-get 'label c))
                                   (alist-get 'choices data))
                           '("claude" "Codex")))))))))

(ert-deftest agent-remote-test-icons-maps-backends-to-their-svg ()
  "The icons endpoint gives each backend's SVG and skips one without it."
  (let ((agent-backends
         (list (cons 'codex (agent-backend--create :icon-svg "<svg>c</svg>"))
               (cons 'claude (agent-backend--create)))))
    (agent-remote-test--with-server
      (should (equal (agent-remote-test--json
                      (agent-remote-test--http "GET" "/api/icons"))
                     '((codex . "<svg>c</svg>")))))))

(ert-deftest agent-remote-test-history-says-when-transcript-is-pending ()
  "A backend that keeps transcripts promises one a new session lacks."
  (agent-remote-test--with-session buffer
    (dolist (case '((t . t) (nil . :false)))
      (let ((backend (agent-backend--create
                      :session-history (and (car case) #'ignore))))
        (cl-letf (((symbol-function 'agent-backend) (lambda (_) backend)))
          (agent-remote-test--with-server
            (let ((data (agent-remote-test--json
                         (agent-remote-test--http
                          "GET" (concat "/api/history?id="
                                        (url-hexify-string
                                         (buffer-name buffer)))))))
              (should (eq (alist-get 'available data) :false))
              (should (eq (alist-get 'pending data) (cdr case))))))))))

(ert-deftest agent-remote-test-backends-without-session-starts-at-home ()
  "Opened from the session list, the sheet starts in the home directory."
  (let ((agent-backends (list (cons 'claude (agent-backend--create)))))
    (agent-remote-test--with-server
      (let ((data (agent-remote-test--json
                   (agent-remote-test--http "GET" "/api/backends"))))
        (should (equal (alist-get 'directory data) "~/"))
        (should (equal (mapcar (lambda (c) (alist-get 'name c))
                               (alist-get 'choices data))
                       '("claude")))))))

(ert-deftest agent-remote-test-directories-lists-folders ()
  "The directories endpoint lists folders and links to them, and no files."
  (let ((root (file-name-as-directory
               (file-truename (make-temp-file "agent-remote" t)))))
    (unwind-protect
        (progn
          (dolist (name '("beta" "Alpha" ".hidden"))
            (make-directory (expand-file-name name root)))
          (write-region "" nil (expand-file-name "file.txt" root))
          (make-symbolic-link (expand-file-name "beta" root)
                              (expand-file-name "link" root))
          (make-symbolic-link (expand-file-name "missing" root)
                              (expand-file-name "broken" root))
          (make-symbolic-link (expand-file-name "file.txt" root)
                              (expand-file-name "file-link" root))
          (agent-remote-test--with-server
            (let ((data (agent-remote-test--json
                         (agent-remote-test--http
                          "GET" (concat "/api/directories?path="
                                        (url-hexify-string root))))))
              (should (equal (alist-get 'path data)
                             (abbreviate-file-name root)))
              (should (equal (alist-get 'parent data)
                             (abbreviate-file-name
                              (file-name-directory
                               (directory-file-name root)))))
              (should (equal (alist-get 'folders data)
                             '(".hidden" "Alpha" "beta" "link"))))))
      (delete-directory root t))))

(ert-deftest agent-remote-test-directories-root-has-no-parent ()
  "The file system's root has no folder above it."
  (agent-remote-test--with-server
    (let ((data (agent-remote-test--json
                 (agent-remote-test--http
                  "GET" "/api/directories?path=%2F"))))
      (should (equal (alist-get 'path data) "/"))
      (should (eq (alist-get 'parent data) :null)))))

(ert-deftest agent-remote-test-directories-refuses-non-folders ()
  "A missing path, a missing folder and a file are client errors."
  (let ((file (make-temp-file "agent-remote")))
    (unwind-protect
        (agent-remote-test--with-server
          (dolist (query (list ""
                               "?path=%2Fno%2Fsuch%2Ffolder"
                               (concat "?path=" (url-hexify-string file))))
            (should (= (agent-remote-test--status
                        (agent-remote-test--http
                         "GET" (concat "/api/directories" query)))
                       400))))
      (delete-file file))))

(ert-deftest agent-remote-test-directories-never-opens-a-remote-path ()
  "A remote-looking path is an ordinary missing folder, with no handler run."
  (let ((file-name-handler-alist
         (cons (cons "\\`/fake:" (lambda (&rest _) (error "Handler ran")))
               file-name-handler-alist)))
    (agent-remote-test--with-server
      (should (= (agent-remote-test--status
                  (agent-remote-test--http
                   "GET" "/api/directories?path=%2Ffake%3Ahost%3A%2F"))
                 400)))))

(ert-deftest agent-remote-test-new-starts-session-in-directory ()
  "The new endpoint starts a session in the chosen folder and returns it."
  (agent-remote-test--with-session buffer
    (let ((directory (file-name-as-directory temporary-file-directory))
          called)
      (cl-letf (((symbol-function 'agent-start-session-in)
                 (lambda (dir backend) (setq called (list dir backend)) buffer)))
        (agent-remote-test--with-server
          (let ((response (agent-remote-test--http
                           "POST" "/api/new"
                           (json-serialize (list :directory directory
                                                 :backend "codex"))
                           '("X-Agent-Remote: 1"))))
            (should (= (agent-remote-test--status response) 200))
            (should (equal (alist-get 'id (agent-remote-test--json response))
                           (buffer-name buffer)))
            (should (equal (alist-get 'name (agent-remote-test--json response))
                           (agent-display-name buffer)))
            (should (equal called
                           (list (abbreviate-file-name
                                  (expand-file-name directory))
                                 'codex)))))))))

(ert-deftest agent-remote-test-new-refuses-missing-folder ()
  "The new endpoint starts nothing in a folder that does not exist."
  (let (called)
    (cl-letf (((symbol-function 'agent-start-session-in)
               (lambda (&rest _) (setq called t))))
      (agent-remote-test--with-server
        (should (= (agent-remote-test--status
                    (agent-remote-test--http
                     "POST" "/api/new"
                     (json-serialize (list :directory "/no/such/folder"
                                           :backend "claude"))
                     '("X-Agent-Remote: 1")))
                   400))
        (should-not called)))))

(ert-deftest agent-remote-test-attach-saves-image ()
  "The attach endpoint saves an image byte for byte in a private file."
  (let ((bytes (concat "\xff\xd8\xff" (unibyte-string 0 200 255 10 13))))
    (agent-remote-test--with-server
      (let* ((response (agent-remote-test--http
                        "POST" "/api/attach"
                        (json-serialize
                         (list :data (base64-encode-string bytes t)))
                        '("X-Agent-Remote: 1")))
             (file (alist-get 'path (agent-remote-test--json response))))
        (unwind-protect
            (progn
              (should (= (agent-remote-test--status response) 200))
              (should (string-suffix-p ".jpg" file))
              (should (= (file-modes file) #o600))
              (should (equal (with-temp-buffer
                               (set-buffer-multibyte nil)
                               (insert-file-contents-literally file)
                               (buffer-string))
                             bytes)))
          (delete-file file))))))

(ert-deftest agent-remote-test-attach-recognizes-png ()
  "A PNG signature gets a PNG file name."
  (should (equal (agent-remote--image-extension "\x89PNG\r\n\x1a\nrest") ".png")))

(ert-deftest agent-remote-test-attach-refuses-other-data ()
  "Anything but a JPEG or PNG image, of a usable size, is refused."
  (cl-letf (((symbol-function 'make-temp-file)
             (lambda (&rest _) (error "A file was created"))))
    (agent-remote-test--with-server
      (dolist (data (list (base64-encode-string "#!/bin/sh\n" t)
                          "not base64!"
                          7
                          (make-string (1+ agent-remote--attachment-limit) ?A)))
        (should (= (agent-remote-test--status
                    (agent-remote-test--http
                     "POST" "/api/attach"
                     (json-serialize (list :data data))
                     '("X-Agent-Remote: 1")))
                   400))))))

(ert-deftest agent-remote-test-exit-passes-skills-choice ()
  "The exit endpoint skips the before-exit skills only when told to."
  (agent-remote-test--with-session buffer
    (let (calls)
      (cl-letf (((symbol-function 'agent-exit-buffer)
                 (lambda (buf without-skills) (push (list buf without-skills) calls))))
        (agent-remote-test--with-server
          (dolist (skills '(t :false))
            (should (= (agent-remote-test--status
                        (agent-remote-test--http
                         "POST" "/api/exit"
                         (json-serialize (list :id (buffer-name buffer)
                                               :skills skills))
                         '("X-Agent-Remote: 1")))
                       200))))
        (should (equal (reverse calls) (list (list buffer nil)
                                             (list buffer t))))))))

(ert-deftest agent-remote-test-snooze-sets-the-requested-state ()
  "The snooze endpoint toggles only when the session is in the other state."
  (agent-remote-test--with-session buffer
    (let (snoozed calls)
      (cl-letf (((symbol-function 'agent-session-snoozed-p)
                 (lambda (_) snoozed))
                ((symbol-function 'agent-toggle-snooze)
                 (lambda (buf &optional hours)
                   (push (list buf hours) calls)
                   (setq snoozed (not snoozed)))))
        (agent-remote-test--with-server
          (dolist (wanted '(t t :false :false))
            (should (= (agent-remote-test--status
                        (agent-remote-test--http
                         "POST" "/api/snooze"
                         (json-serialize (list :id (buffer-name buffer)
                                               :snoozed wanted))
                         '("X-Agent-Remote: 1")))
                       200))
            (should (eq snoozed (eq wanted t)))))
        (should (equal calls (list (list buffer nil) (list buffer nil))))))))

(ert-deftest agent-remote-test-connections-are-cleaned-up ()
  "Closed client connections do not accumulate as processes."
  (agent-remote-test--with-server
    (dotimes (_ 3) (agent-remote-test--http "GET" "/api/sessions"))
    (accept-process-output nil 0.2)
    (should-not (cl-find-if (lambda (p)
                              (and (string-prefix-p "agent-remote" (process-name p))
                                   (not (eq p agent-remote--server))
                                   (not (string-prefix-p "agent-remote-test"
                                                         (process-name p)))))
                            (process-list)))))

(provide 'agent-remote-test)

;;; agent-remote-test.el ends here
