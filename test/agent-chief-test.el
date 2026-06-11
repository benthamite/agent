;;; agent-chief-test.el --- Tests for agent-chief -*- lexical-binding: t -*-

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'agent-chief)

(defun agent-chief-test--backend (&rest keys)
  "Return a minimal valid backend plist extended with KEYS."
  (append
   keys
   (list :buffer-p (lambda (_buffer) nil)
         :find-all-buffers (lambda () nil)
         :start-session #'ignore
         :label "Test")))

(ert-deftest agent-chief-test-extract-json-from-fenced-output ()
  "Extract a JSON object from fenced model output."
  (should
   (equal (agent-chief--extract-decision-json
           "```json\n{\"notify\":false,\"message\":\"\"}\n```")
          "{\"notify\":false,\"message\":\"\"}")))

(ert-deftest agent-chief-test-extract-json-skips-echoed-schema ()
  "Skip invalid JSON-like objects before the model's decision."
  (should
   (equal
    (agent-chief--extract-decision-json
     (concat
      "Return {\"notify\":true|false,\"message\":\"shape\"}\n"
      "codex\n"
      "{\"notify\":true,\"title\":\"Focus\",\"message\":\"Go\",\"state_update\":\"\"}\n"
      "tokens used\n16,134"))
    "{\"notify\":true,\"title\":\"Focus\",\"message\":\"Go\",\"state_update\":\"\"}")))

(ert-deftest agent-chief-test-extract-json-respects-braces-in-strings ()
  "Do not treat braces inside JSON strings as object delimiters."
  (should
   (equal
    (agent-chief--extract-decision-json
     "{\"notify\":false,\"message\":\"literal { brace }\"}")
    "{\"notify\":false,\"message\":\"literal { brace }\"}")))

(ert-deftest agent-chief-test-parse-decision-requires-notify ()
  "Reject decisions without a notify field."
  (should-error
   (agent-chief--parse-decision "{\"message\":\"hi\"}")))

(ert-deftest agent-chief-test-handle-decision-notifies-without-recording-state ()
  "Notify but do not persist model state updates by default."
  (let ((agent-chief-state-file (make-temp-file "agent-chief" nil ".org"))
        (calls nil))
    (unwind-protect
        (progn
          (let ((agent-chief-notify-function
                 (lambda (title message)
                   (push (list title message) calls))))
            (agent-chief--handle-decision
             '(:notify t
               :title "Focus"
               :message "Start the planned review."
               :state_update "Pablo should start with review.")))
          (should (equal calls '(("Focus" "Start the planned review."))))
          (should (zerop (nth 7 (file-attributes agent-chief-state-file)))))
      (when (file-exists-p agent-chief-state-file)
        (delete-file agent-chief-state-file)))))

(ert-deftest agent-chief-test-handle-decision-records-state-when-enabled ()
  "Append model state updates only when explicitly enabled."
  (let ((agent-chief-state-file (make-temp-file "agent-chief" nil ".org"))
        (agent-chief-record-model-state-updates t))
    (unwind-protect
        (progn
          (agent-chief--handle-decision
           '(:notify :false
             :title ""
             :message ""
             :state_update "Pablo should start with review."))
          (with-temp-buffer
            (insert-file-contents agent-chief-state-file)
            (should (string-match-p "Model state update" (buffer-string)))
            (should (string-match-p "Pablo should start" (buffer-string)))))
      (when (file-exists-p agent-chief-state-file)
        (delete-file agent-chief-state-file)))))

(ert-deftest agent-chief-test-build-prompt-includes-context-functions ()
  "Include configured context snippets in the tick prompt."
  (let ((agent-chief-state-file "/tmp/missing-agent-chief-state")
        (agent-chief-context-functions
         (list (lambda () "Calendar: write block at 10")
               (lambda () "")
               (lambda () nil))))
    (let ((prompt (agent-chief--build-prompt)))
      (should (string-match-p "Calendar: write block at 10" prompt))
      (should (string-match-p "state file is empty or missing" prompt)))))

(ert-deftest agent-chief-test-directory-prefers-epoch-when-present ()
  "Default chief sessions should not start in the Emacs profile."
  (when (file-directory-p "/Users/pablostafforini/My Drive/Epoch/")
    (should (equal (file-name-as-directory agent-chief-directory)
                   "/Users/pablostafforini/My Drive/Epoch/"))))

(ert-deftest agent-chief-test-state-context-labels-old-plans-historical ()
  "Tell the model not to treat stale plan headings as active obligations."
  (let ((agent-chief-state-file (make-temp-file "agent-chief" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file agent-chief-state-file
            (insert "* Plan 2026-05-20 [2026-05-20 Wed 18:54]\n\n"
                    "make progress with bench-scraper by 19:00\n"))
          (let ((context (agent-chief--state-context)))
            (should (string-match-p "older Plan headings are historical"
                                    context))
            (should (string-match-p "bench-scraper" context))))
      (when (file-exists-p agent-chief-state-file)
        (delete-file agent-chief-state-file)))))

(ert-deftest agent-chief-test-run-backend-dispatches-to-codex ()
  "Dispatch a chief tick through the codex run-prompt slot."
  (let ((agent-backends nil)
        (agent-chief-backend 'codex)
        (agent-chief-directory "/tmp/")
        called)
    (apply #'agent-register-backend
     'codex
     (agent-chief-test--backend
      :run-prompt (cl-function
                   (lambda (prompt &key directory callback)
                     (setq called (list prompt directory callback))))))
    (cl-letf (((symbol-function 'require) #'ignore))
      (agent-chief--run-backend "Prompt" #'ignore)
      (should (equal (car called) "Prompt"))
      (should (equal (cadr called) "/tmp/")))))

(ert-deftest agent-chief-test-stateless-tick-clears-flag-on-bad-backend ()
  "Clear the in-flight flag when the backend symbol is unsupported."
  (let ((agent-chief-backend 'unsupported)
        (agent-chief--stateless-in-flight nil))
    (cl-letf (((symbol-function 'agent-chief--build-prompt)
               (lambda () "Prompt")))
      (should-error (agent-chief-stateless-tick) :type 'user-error)
      (should-not agent-chief--stateless-in-flight))))

(ert-deftest agent-chief-test-stateless-tick-clears-flag-on-sync-error ()
  "Clear the in-flight flag when dispatch signals synchronously."
  (let ((agent-backends nil)
        (agent-chief-backend 'codex)
        (agent-chief-directory "/tmp/")
        (agent-chief--stateless-in-flight nil))
    (apply #'agent-register-backend
     'codex
     (agent-chief-test--backend
      :run-prompt (lambda (&rest _)
                    (error "Codex program not found"))))
    (cl-letf (((symbol-function 'agent-chief--build-prompt)
               (lambda () "Prompt"))
              ((symbol-function 'require) #'ignore))
      (should-error (agent-chief-stateless-tick))
      (should-not agent-chief--stateless-in-flight))))

(ert-deftest agent-chief-test-session-heartbeat-runs-out-of-band ()
  "Run heartbeats through run-prompt, reserving the live buffer for chat."
  (let ((agent-backends nil)
        (agent-chief-backend 'codex)
        (agent-chief-directory "/tmp/")
        (agent-chief-session-buffer nil)
        (agent-chief--last-session-response nil)
        started-buffer
        submitted
        ran
        notified)
    (unwind-protect
        (progn
          (apply #'agent-register-backend
           'codex
           (agent-chief-test--backend
            :find-buffers-for-dir (lambda (_dir)
                                    (and started-buffer
                                         (list started-buffer)))
            :start-session (lambda (_session &rest _options)
                             (setq started-buffer
                                   (get-buffer-create "*codex:/tmp/:chief*")))
            :submit (lambda (prompt buffer)
                      (setq submitted (list prompt buffer)))
            :run-prompt (cl-function
                         (lambda (prompt &key directory callback)
                           (setq ran (list prompt directory callback))))))
          (cl-letf (((symbol-function 'require) #'ignore))
            (agent-chief-session-heartbeat))
          (should-not submitted)
          (should (string-match-p "Chief-of-staff heartbeat" (car ran)))
          (should (equal (cadr ran) agent-chief-directory))
          (with-current-buffer started-buffer
            (should (eq agent-chief--heartbeat-state 'in-flight)))
          (let ((agent-chief-notify-function
                 (lambda (&rest args) (push args notified))))
            (funcall (nth 2 ran) "No nudge."))
          (should-not notified)
          (should (equal agent-chief--last-session-response '(no-nudge . nil)))
          (with-current-buffer started-buffer
            (should-not agent-chief--heartbeat-state)))
      (when (buffer-live-p started-buffer)
        (kill-buffer started-buffer)))))

(ert-deftest agent-chief-test-session-heartbeat-skips-while-in-flight ()
  "Skip a heartbeat while the previous one is still in flight."
  (with-temp-buffer
    (setq-local agent-chief--heartbeat-state 'in-flight)
    (let ((buffer (current-buffer))
          ran)
      (cl-letf (((symbol-function 'agent-chief--ensure-session)
                 (lambda () buffer))
                ((symbol-function 'agent-chief--run-backend)
                 (lambda (&rest args) (setq ran args))))
        (agent-chief-session-heartbeat))
      (should-not ran)
      (should (eq agent-chief--heartbeat-state 'in-flight)))))

(ert-deftest agent-chief-test-session-heartbeat-clears-state-on-sync-error ()
  "Clear in-flight heartbeat state when dispatch signals synchronously."
  (with-temp-buffer
    (let ((buffer (current-buffer)))
      (cl-letf (((symbol-function 'agent-chief--ensure-session)
                 (lambda () buffer))
                ((symbol-function 'agent-chief--session-heartbeat-prompt)
                 (lambda () "Prompt"))
                ((symbol-function 'agent-chief--run-backend)
                 (lambda (&rest _) (error "Codex program not found"))))
        (should-error (agent-chief-session-heartbeat)))
      (should-not agent-chief--heartbeat-state))))

(ert-deftest agent-chief-test-heartbeat-prompt-omits-conversation ()
  "Build heartbeat prompts from the day plan and explicit state only."
  (let ((agent-chief-state-file "/tmp/missing-agent-chief-state"))
    (let ((prompt (agent-chief--session-heartbeat-prompt)))
      (should (string-match-p
               "Review the current day plan and explicit state\\."
               prompt))
      (should-not (string-match-p "this conversation" prompt))
      (should-not (string-match-p "conversation context" prompt)))))

(ert-deftest agent-chief-test-start-session-asks-for-plan-in-session ()
  "Start the chief session without prompting in the minibuffer."
  (let ((agent-backends nil)
        (agent-chief-backend 'codex)
        (agent-chief-directory "/tmp/")
        (agent-chief-session-buffer nil)
        (agent-chief--timer nil)
        started-buffer
        submitted
        minibuffer-prompted)
    (unwind-protect
        (progn
          (apply #'agent-register-backend
           'codex
           (agent-chief-test--backend
            :find-buffers-for-dir (lambda (_dir)
                                    (and started-buffer
                                         (list started-buffer)))
            :start-session (lambda (_session &rest _options)
                             (setq started-buffer
                                   (get-buffer-create "*codex:/tmp/:chief*")))
            :submit (lambda (prompt buffer)
                              (push (list prompt buffer) submitted))))
          (cl-letf (((symbol-function 'require) #'ignore)
                    ((symbol-function 'read-string)
                     (lambda (&rest _args)
                       (setq minibuffer-prompted t)
                       "should not happen"))
                    ((symbol-function 'run-at-time)
                     (lambda (&rest _args) 'timer))
                    ((symbol-function 'pop-to-buffer) #'ignore))
            (agent-chief-start-session))
          (should-not minibuffer-prompted)
          (should (equal (cadar submitted) started-buffer))
          (should (string-match-p "Ask me for today's plan"
                                  (caar submitted)))
          (should-not (string-match-p "JSON" (caar submitted)))
          (should-not (string-match-p "State file" (caar submitted))))
      (when (buffer-live-p started-buffer)
        (kill-buffer started-buffer)))))

(ert-deftest agent-chief-test-set-day-plan-forwards-to-session ()
  "Record the day plan and submit it to the live chief session."
  (let ((agent-backends nil)
        (agent-chief-backend 'codex)
        (agent-chief-state-file (make-temp-file "agent-chief" nil ".org"))
        (agent-chief-session-buffer (get-buffer-create "*chief-test*"))
        submitted)
    (unwind-protect
        (progn
          (apply #'agent-register-backend
           'codex
           (agent-chief-test--backend
            :submit (lambda (prompt buffer)
                              (setq submitted (list prompt buffer)))))
          (with-current-buffer agent-chief-session-buffer
            (setq-local agent-chief--session-backend 'codex))
          (agent-chief-set-day-plan "Write the report by 15:00")
          (should (equal (cadr submitted) agent-chief-session-buffer))
          (should (string-match-p "Write the report" (car submitted)))
          (with-temp-buffer
            (insert-file-contents agent-chief-state-file)
            (should (string-match-p "Write the report" (buffer-string)))))
      (when (buffer-live-p agent-chief-session-buffer)
        (kill-buffer agent-chief-session-buffer))
      (when (file-exists-p agent-chief-state-file)
        (delete-file agent-chief-state-file)))))

(ert-deftest agent-chief-test-parse-heartbeat-reply ()
  "Classify structured heartbeat replies."
  (should (equal (agent-chief--parse-heartbeat-reply "No nudge.")
                 '(no-nudge . nil)))
  (should (equal (agent-chief--parse-heartbeat-reply "Nudge: drink water")
                 '(nudge . "drink water")))
  (should (eq (car (agent-chief--parse-heartbeat-reply "something else"))
              'unknown)))

(ert-deftest agent-chief-test-heartbeat-result-clears-state ()
  "Clear the in-flight state after applying a heartbeat result."
  (with-temp-buffer
    (setq-local agent-chief--heartbeat-state 'in-flight)
    (let ((agent-chief--last-session-response nil)
          (agent-chief-notify-function #'ignore))
      (agent-chief--handle-heartbeat-result
       (current-buffer) "No nudge." nil))
    (should-not agent-chief--heartbeat-state)))

(ert-deftest agent-chief-test-heartbeat-result-notifies-on-nudge ()
  "Notify when the heartbeat reply contains a nudge."
  (with-temp-buffer
    (setq-local agent-chief--heartbeat-state 'in-flight)
    (let ((agent-chief--last-session-response nil)
          calls)
      (let ((agent-chief-notify-function
             (lambda (title message) (push (list title message) calls))))
        (agent-chief--handle-heartbeat-result
         (current-buffer) "Nudge: Switch to the report now." nil))
      (should (equal calls '(("Chief of staff" "Switch to the report now."))))
      (should-not agent-chief--heartbeat-state))))

(ert-deftest agent-chief-test-heartbeat-result-reports-error-without-notify ()
  "Report backend heartbeat errors without invoking the notify function."
  (with-temp-buffer
    (setq-local agent-chief--heartbeat-state 'in-flight)
    (let ((agent-chief--last-session-response nil)
          calls)
      (let ((agent-chief-notify-function
             (lambda (&rest args) (push args calls))))
        (agent-chief--handle-heartbeat-result (current-buffer) nil "exit 1"))
      (should-not calls)
      (should-not agent-chief--heartbeat-state))))

(ert-deftest agent-chief-test-start-replaces-existing-timer ()
  "Starting the loop cancels any existing chief timer."
  (let ((agent-chief--timer 'old)
        (cancelled nil)
        (scheduled nil))
    (cl-letf (((symbol-function 'timerp) (lambda (value) (eq value 'old)))
              ((symbol-function 'cancel-timer)
               (lambda (timer) (setq cancelled timer)))
              ((symbol-function 'run-at-time)
               (lambda (delay repeat function &rest _args)
                 (setq scheduled (list delay repeat function))
                 'new)))
      (agent-chief-start t)
      (should (eq cancelled 'old))
      (should (eq agent-chief--timer 'new))
      (should (equal scheduled
                     (list agent-chief-interval
                           agent-chief-interval
                           #'agent-chief-tick))))))

(ert-deftest agent-chief-test-stop-clears-running-heartbeat-state ()
  "Stopping the chief loop clears stale in-flight tick and heartbeat state."
  (let ((agent-chief--timer 'old)
        (agent-chief--stateless-in-flight t)
        (agent-chief-session-buffer (get-buffer-create "*chief-test*"))
        cancelled)
    (unwind-protect
        (progn
          (with-current-buffer agent-chief-session-buffer
            (setq-local agent-chief--heartbeat-state 'in-flight))
          (cl-letf (((symbol-function 'timerp) (lambda (value) (eq value 'old)))
                    ((symbol-function 'cancel-timer)
                     (lambda (timer) (setq cancelled timer))))
            (agent-chief-stop))
          (should (eq cancelled 'old))
          (should-not agent-chief--timer)
          (should-not agent-chief--stateless-in-flight)
          (with-current-buffer agent-chief-session-buffer
            (should-not agent-chief--heartbeat-state)))
      (when (buffer-live-p agent-chief-session-buffer)
        (kill-buffer agent-chief-session-buffer)))))

(provide 'agent-chief-test)
;;; agent-chief-test.el ends here
