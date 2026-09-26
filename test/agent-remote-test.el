;;; agent-remote-test.el --- Tests for agent-remote -*- lexical-binding: t -*-

;; Tests for the phone remote-control server in agent-remote.el.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'agent-remote)

;;;; Helpers

(defmacro agent-remote-test--with-server (&rest body)
  "Run BODY with the remote server listening on a free loopback port."
  (declare (indent 0))
  `(let ((agent-remote-host "127.0.0.1")
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
