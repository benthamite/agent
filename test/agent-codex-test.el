;;; agent-codex-test.el --- Tests for agent-codex -*- lexical-binding: t -*-

;; Tests for pure and near-pure helper functions in agent-codex.el.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'agent-account)
(require 'agent-codex)
(require 'agent-capture)

;;;; Account selection

(ert-deftest agent-codex-test-handoff-file-default-matches-skill ()
  "Use the path written by the Codex `/handoff' skill."
  (should (equal (alist-get 'codex agent-handoff-files)
                 "/tmp/codex-handoff.md")))

(ert-deftest agent-codex-test-shared-config-items-use-agents-md ()
  "Share the actual Codex instruction filename across account homes."
  (should (member "AGENTS.md" agent-codex--shared-config-items))
  (should-not (member "AGENT.md" agent-codex--shared-config-items)))

(ert-deftest agent-codex-test-account-env-uses-starting-account ()
  "Set CODEX_HOME from the in-flight start binding, without syncing."
  (let* ((dir (make-temp-file "codex-account" t))
         (home (expand-file-name "work" dir))
         (agent-codex-accounts `(("work" . ,home)))
         (agent-account--current (make-hash-table :test #'eq))
         (agent-account--starting '(codex . "work")))
    (unwind-protect
        (cl-letf (((symbol-function 'make-symbolic-link)
                   (lambda (&rest _) (error "env hook must not sync"))))
          (should (equal (agent-codex-account-env "*codex*" dir)
                         (list (format "CODEX_HOME=%s" home)))))
      (delete-directory dir t))))

;;;; TOML helpers

(ert-deftest agent-codex-test-toml-roundtrip ()
  "toml-set writes values that toml-get reads back, per section."
  (let ((file (make-temp-file "agent-codex-toml" nil ".toml"))
        (agent-codex--toml-cache (make-hash-table :test #'equal)))
    (unwind-protect
        (progn
          (should (agent-codex--toml-set file "model" "gpt-5.2" nil))
          (should (agent-codex--toml-set file "theme" "dark" "tui"))
          (should (equal (agent-codex--toml-get file "model") "gpt-5.2"))
          (should (equal (agent-codex--toml-get file "theme" "tui") "dark"))
          (should-not (agent-codex--toml-get file "theme"))
          (should-not (agent-codex--toml-set file "theme" "dark" "tui")))
      (delete-file file))))

(ert-deftest agent-codex-test-toml-get-ignores-commented-keys ()
  "Commented-out TOML keys are not matched by toml-get."
  (let ((file (make-temp-file "agent-codex-toml" nil ".toml"))
        (agent-codex--toml-cache (make-hash-table :test #'equal)))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "# model = \"old\"\nmodel = \"new\"\n# effort = \"high\"\n"))
          (should (equal (agent-codex--toml-get file "model") "new"))
          (should-not (agent-codex--toml-get file "effort")))
      (delete-file file))))

(ert-deftest agent-codex-test-toml-cache-invalidates-on-mtime-change ()
  "A changed file modification time refreshes cached TOML reads."
  (let ((file (make-temp-file "agent-codex-toml" nil ".toml"))
        (agent-codex--toml-cache (make-hash-table :test #'equal)))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "model = \"before\"\n"))
          (should (equal (agent-codex--toml-get file "model") "before"))
          (with-temp-file file
            (insert "model = \"after\"\n"))
          (set-file-times file (time-add (current-time) 5))
          (should (equal (agent-codex--toml-get file "model") "after")))
      (delete-file file))))

(ert-deftest agent-codex-test-toml-cache-per-file ()
  "Reads from two files do not evict each other."
  (let ((a (make-temp-file "agent-codex-a" nil ".toml"))
        (b (make-temp-file "agent-codex-b" nil ".toml"))
        (agent-codex--toml-cache (make-hash-table :test #'equal)))
    (unwind-protect
        (progn
          (agent-codex--toml-set a "model" "model-a" nil)
          (agent-codex--toml-set b "model" "model-b" nil)
          (agent-codex--toml-get a "model")
          (agent-codex--toml-get b "model")
          (should (equal (agent-codex--toml-get a "model") "model-a"))
          (should (= (hash-table-count agent-codex--toml-cache) 2)))
      (delete-file a) (delete-file b))))

(ert-deftest agent-codex-test-read-config-model-uses-account-home ()
  "Read model configuration from the selected account's CODEX_HOME."
  (let* ((dir (make-temp-file "codex-account" t))
         (home (expand-file-name "work" dir))
         (config (expand-file-name "config.toml" home))
         (agent-codex-accounts `(("work" . ,home)))
         (agent-codex--toml-cache (make-hash-table :test #'equal)))
    (unwind-protect
        (progn
          (make-directory home t)
          (with-temp-file config
            (insert "model = \"gpt-5.5\"\n"))
          (should (equal (agent-codex--read-config-model "work")
                         "gpt-5.5")))
      (delete-directory dir t))))

(ert-deftest agent-codex-test-read-config-effort-uses-account-home ()
  "Read reasoning effort configuration from the selected account's CODEX_HOME."
  (let* ((dir (make-temp-file "codex-account" t))
         (home (expand-file-name "work" dir))
         (config (expand-file-name "config.toml" home))
         (agent-codex-accounts `(("work" . ,home)))
         (agent-codex--toml-cache (make-hash-table :test #'equal)))
    (unwind-protect
        (progn
          (make-directory home t)
          (with-temp-file config
            (insert "model = \"gpt-5.5\"\n")
            (insert "model_reasoning_effort = \"high\"\n"))
          (should (equal (agent-codex--read-config-effort "work")
                         "high")))
      (delete-directory dir t))))

(ert-deftest agent-codex-test-status-effort-prefers-buffer-override ()
  "Return the live buffer-local reasoning effort before config."
  (with-temp-buffer
    (setq-local codex-reasoning-effort "xhigh")
    (cl-letf (((symbol-function 'agent-codex--read-config-effort)
               (lambda (_account) "medium")))
      (should (equal (agent-codex-status-effort) "xhigh")))))

(ert-deftest agent-codex-test-status-effort-uses-codex-default ()
  "Return Codex's default reasoning effort when no override is present."
  (with-temp-buffer
    (setq-local codex-reasoning-effort nil)
    (cl-letf (((symbol-function 'agent-codex--read-config-effort)
               (lambda (_account) nil)))
      (should (equal (agent-codex-status-effort) "medium")))))

(ert-deftest agent-codex-test-restart-preserves-buffer-account ()
  "Restart Codex with the account attached to the current session."
  (let ((dir (make-temp-file "codex-restart" t))
        (agent-prompt-capture-directory (make-temp-file "agent-prompts" t))
        captured-account)
    (unwind-protect
        (with-temp-buffer
          (rename-buffer "*codex:~/project/:default*" t)
          (setq-local codex--session-id "019ea295-c3df-70b0-a8e5-a8ffe9df220a")
          (setq-local agent--session (agent-session-create :backend 'codex
                                                           :account "work"))
          (let ((agent-codex-accounts
                 `(("work" . ,(expand-file-name "work" dir))))
                (agent-account--current (make-hash-table :test #'eq))
                (agent-codex-account-file (expand-file-name "current" dir)))
            (cl-letf (((symbol-function 'codex--buffer-p) (lambda (_buffer) t))
                      ((symbol-function 'agent--force-kill-buffer) #'ignore)                      ((symbol-function 'agent-account-sync) #'ignore)
                      ((symbol-function 'agent-account-resolve)
                       (lambda (_backend &optional prompt)
                         (when prompt
                           (error "should not resolve active account"))))
                      ((symbol-function 'codex-start-session)
                       (lambda (&rest _keys)
                         (setq captured-account
                               (cdr-safe agent-account--starting))
                         (generate-new-buffer " *codex-restart-target*"))))
              (kill-buffer (agent-restart)))))
      (delete-directory agent-prompt-capture-directory t)
      (delete-directory dir t))
    (should (equal captured-account "work"))))

(ert-deftest agent-codex-test-restart-prompts-when-active-account-differs ()
  "Restart Codex with the selected account when the user chooses it."
  (let ((dir (make-temp-file "codex-restart" t))
        (agent-prompt-capture-directory (make-temp-file "agent-prompts" t))
        captured-account captured-session-id prompt-choices)
    (unwind-protect
        (with-temp-buffer
          (rename-buffer "*codex:~/project/:default*" t)
          (setq-local codex--session-id "019ea295-c3df-70b0-a8e5-a8ffe9df220a")
          (setq-local agent--session (agent-session-create :backend 'codex
                                                           :account "work"))
          (let ((agent-codex-accounts
                 `(("work" . ,(expand-file-name "work" dir))
                   ("personal" . ,(expand-file-name "personal" dir))))
                (agent-account--current (make-hash-table :test #'eq)))
            (puthash 'codex "personal" agent-account--current)
            (cl-letf (((symbol-function 'codex--buffer-p) (lambda (_buffer) t))
                      ((symbol-function 'agent--force-kill-buffer) #'ignore)                      ((symbol-function 'agent-account-sync) #'ignore)
                      ((symbol-function 'completing-read)
                       (lambda (_prompt choices &rest _args)
                         (setq prompt-choices choices)
                         "personal"))
                      ((symbol-function 'codex-start-session)
                       (lambda (&rest keys)
                         (setq captured-account
                               (cdr-safe agent-account--starting))
                         (setq captured-session-id (plist-get keys :resume-id))
                         (generate-new-buffer " *codex-restart-target*"))))
              (kill-buffer (agent-restart)))))
      (delete-directory agent-prompt-capture-directory t)
      (delete-directory dir t))
    (should (equal prompt-choices '("personal" "work")))
    (should (equal captured-account "personal"))
    (should (equal captured-session-id
                   "019ea295-c3df-70b0-a8e5-a8ffe9df220a"))))

(ert-deftest agent-codex-test-restart-completes-partial-session-identity ()
  "Restart a migrated session in its buffer directory, not ambient state."
  (let ((dir (make-temp-file "codex-restart" t))
        (ambient-dir (file-name-as-directory
                      (make-temp-file "codex-ambient" t)))
        (agent-prompt-capture-directory (make-temp-file "agent-prompts" t))
        captured-directory)
    (unwind-protect
        (with-temp-buffer
          (rename-buffer "*codex:~/project/:default*" t)
          (setq-local codex--session-id "019ea295-c3df-70b0-a8e5-a8ffe9df220a")
          (setq-local agent--session (agent-session-create :backend 'codex
                                                           :account "work"))
          (let ((default-directory ambient-dir)
                (agent-codex-accounts
                 `(("work" . ,(expand-file-name "work" dir))
                   ("personal" . ,(expand-file-name "personal" dir))))
                (agent-account--current (make-hash-table :test #'eq)))
            (puthash 'codex "personal" agent-account--current)
            (cl-letf (((symbol-function 'codex--buffer-p) (lambda (_buffer) t))
                      ((symbol-function 'agent--force-kill-buffer) #'ignore)
                      ((symbol-function 'agent-account-sync) #'ignore)
                      ((symbol-function 'completing-read)
                       (lambda (_prompt _choices &rest _args) "personal"))
                      ((symbol-function 'codex-start-session)
                       (lambda (&rest keys)
                         (setq captured-directory
                               (plist-get keys :directory))
                         (generate-new-buffer " *codex-restart-target*"))))
              (kill-buffer (agent-restart)))))
      (delete-directory agent-prompt-capture-directory t)
      (delete-directory ambient-dir t)
      (delete-directory dir t))
    (should (equal captured-directory "~/project/"))))

(ert-deftest agent-codex-test-restart-fails-when-active-account-is-missing ()
  "Do not fall back to the session account when the selected account is stale."
  (let ((dir (make-temp-file "codex-restart" t))
        (agent-prompt-capture-directory (make-temp-file "agent-prompts" t))
        killed started)
    (unwind-protect
        (with-temp-buffer
          (rename-buffer "*codex:~/project/:default*" t)
          (setq-local codex--session-id "019ea295-c3df-70b0-a8e5-a8ffe9df220a")
          (setq-local agent--session (agent-session-create :backend 'codex
                                                           :account "work"))
          (let ((agent-codex-accounts
                 `(("work" . ,(expand-file-name "work" dir))))
                (agent-account--current (make-hash-table :test #'eq)))
            (puthash 'codex "personal" agent-account--current)
            (cl-letf (((symbol-function 'codex--buffer-p) (lambda (_buffer) t))
                      ((symbol-function 'agent--force-kill-buffer)
                       (lambda (_buffer) (setq killed t)))
                      ((symbol-function 'codex-start-session)
                       (lambda (&rest _args)
                         (setq started t)
                         (generate-new-buffer " *codex-restart-target*"))))
              (should-error (agent-restart) :type 'user-error))))
      (delete-directory agent-prompt-capture-directory t)
      (delete-directory dir t))
    (should-not killed)
    (should-not started)))

(ert-deftest agent-codex-test-restart-resumes-current-session-id ()
  "Restart Codex with the session id attached to the current buffer."
  (let ((agent-prompt-capture-directory (make-temp-file "agent-prompts" t))
        (agent-account--current (make-hash-table :test #'eq))
        captured-session-id captured-instance-name)
    (unwind-protect
        (with-temp-buffer
          (rename-buffer "*codex:~/project/:default*" t)
          (setq-local codex--session-id "019ea295-c3df-70b0-a8e5-a8ffe9df220a")
          (cl-letf (((symbol-function 'codex--buffer-p) (lambda (_buffer) t))
                    ((symbol-function 'agent--force-kill-buffer) #'ignore)                    ((symbol-function 'agent-account-resolve)
                     (lambda (_backend &optional _prompt) nil))
                    ((symbol-function 'codex-start-session)
                     (lambda (&rest keys)
                       (setq captured-session-id (plist-get keys :resume-id))
                       (setq captured-instance-name
                             (plist-get keys :instance-name))
                       (generate-new-buffer " *codex-restart-target*"))))
            (kill-buffer (agent-restart))))
      (delete-directory agent-prompt-capture-directory t))
    (should (equal captured-session-id
                   "019ea295-c3df-70b0-a8e5-a8ffe9df220a"))
    (should (equal captured-instance-name "default"))))

(ert-deftest agent-codex-test-restart-uses-codex-session-identity ()
  "Restart Codex through the canonical session identity resolver."
  (let ((agent-prompt-capture-directory (make-temp-file "agent-prompts" t))
        (agent-account--current (make-hash-table :test #'eq))
        captured-session-id)
    (unwind-protect
        (with-temp-buffer
          (rename-buffer "*codex:~/project/:default*" t)
          (setq-local codex--session-id nil)
          (setq-local codex--app-server-thread-id nil)
          (cl-letf (((symbol-function 'codex--buffer-p) (lambda (_buffer) t))
                    ((symbol-function 'agent--force-kill-buffer) #'ignore)                    ((symbol-function 'agent-account-resolve)
                     (lambda (_backend &optional _prompt) nil))
                    ((symbol-function 'codex--current-session-identity)
                     (lambda ()
                       '(:id "019eada4-ebff-7721-9df6-642202f1138f"
                         :transcript-file "/tmp/session.jsonl")))
                    ((symbol-function 'codex-start-session)
                     (lambda (&rest keys)
                       (setq captured-session-id (plist-get keys :resume-id))
                       (generate-new-buffer " *codex-restart-target*"))))
            (kill-buffer (agent-restart))))
      (delete-directory agent-prompt-capture-directory t))
    (should (equal captured-session-id
                   "019eada4-ebff-7721-9df6-642202f1138f"))))

(ert-deftest agent-codex-test-restart-without-session-identity-does-not-kill ()
  "Restart refuses to kill the current buffer without session identity."
  (let ((agent-prompt-capture-directory (make-temp-file "agent-prompts" t))
        (agent-account--current (make-hash-table :test #'eq))
        killed started)
    (unwind-protect
        (with-temp-buffer
          (rename-buffer "*codex:~/project/:default*" t)
          (cl-letf (((symbol-function 'codex--buffer-p) (lambda (_buffer) t))
                    ((symbol-function 'agent--force-kill-buffer)
                     (lambda (_buffer) (setq killed t)))
                    ((symbol-function 'agent-account-resolve)
                     (lambda (_backend &optional _prompt) nil))
                    ((symbol-function 'codex--current-session-identity)
                     (lambda () nil))
                    ((symbol-function 'codex-start-session)
                     (lambda (&rest _args) (setq started t))))
            (should-error (agent-restart) :type 'user-error)))
      (delete-directory agent-prompt-capture-directory t))
    (should-not killed)
    (should-not started)))

(ert-deftest agent-codex-test-restart-uses-default-backend ()
  "Restart uses the current default terminal backend."
  (let ((agent-prompt-capture-directory (make-temp-file "agent-prompts" t))
        (agent-account--current (make-hash-table :test #'eq))
        (old-backend (default-value 'codex-terminal-backend))
        captured-backend)
    (unwind-protect
        (progn
          (setq-default codex-terminal-backend 'app-server)
          (with-temp-buffer
            (rename-buffer "*codex:~/project/:default*" t)
            (setq-local codex-terminal-backend 'eat)
            (setq-local codex--session-id "019ea295-c3df-70b0-a8e5-a8ffe9df220a")
            (cl-letf (((symbol-function 'codex--buffer-p)
                       (lambda (_buffer) t))
                      ((symbol-function 'agent--force-kill-buffer)
                       #'ignore)
                      ((symbol-function 'agent-account-resolve)
                       (lambda (_backend &optional _prompt) nil))
                      ((symbol-function 'codex-start-session)
                       (lambda (&rest keys)
                         (setq captured-backend
                               (plist-get keys :terminal-backend))
                         (generate-new-buffer " *codex-restart-target*"))))
              (kill-buffer (agent-restart)))))
      (setq-default codex-terminal-backend old-backend)
      (delete-directory agent-prompt-capture-directory t))
    (should (eq captured-backend 'app-server))))

(ert-deftest agent-codex-test-handoff-kills-single-existing-buffer-when-source-missing ()
  "Avoid instance-name prompts when emacsclient did not pass a source buffer."
  (let* ((dir (file-name-as-directory (make-temp-file "codex-handoff" t)))
         (handoff-file (expand-file-name "handoff.md" dir))
         (existing (generate-new-buffer "*codex:handoff*"))
         killed started)
    (unwind-protect
        (progn
          (with-temp-file handoff-file
            (insert "continue\n"))
          (with-current-buffer existing
            (setq default-directory dir))
          (let ((agent-handoff-files `((codex . ,handoff-file)))
                (default-directory dir))
            (cl-letf (((symbol-function 'agent--handoff-source-buffer)
                       (lambda (_buffer-name) nil))
                      ((symbol-function 'agent--resolve-backend)
                       (lambda () 'codex))
                      ((symbol-function 'codex--find-codex-buffers-for-directory)
                       (lambda (_dir) (list existing)))
                      ((symbol-function 'agent--force-kill-buffer)
                       (lambda (buffer) (push buffer killed)))
                      ((symbol-function 'agent-start-session)
                       (cl-function
                        (lambda (_session &key initial-prompt
                                          &allow-other-keys)
                          (setq started initial-prompt)))))
              (agent-handoff)
              (should (equal killed (list existing)))
              (should (equal started "continue")))))
      (when (buffer-live-p existing)
        (kill-buffer existing))
      (delete-directory dir t))))

(ert-deftest agent-codex-test-record-start-time-sets-duration ()
  "Record a start time for Codex buffers."
  (let ((buf (generate-new-buffer "*codex:/tmp/project/*")))
    (unwind-protect
        (with-current-buffer buf
          (agent-codex--record-start-time)
          (should (integerp (agent-codex-status-duration-ms))))
      (kill-buffer buf))))

(ert-deftest agent-codex-test-send-command-and-return-are-separate ()
  "Insert Codex command text separately from submitting it."
  (let (events)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (cl-letf (((symbol-function 'codex--term-send-string)
                   (lambda (_backend string)
                     (push (list 'string string) events)))
                  ((symbol-function 'codex--term-send-action)
                   (lambda (_backend action &optional _payload)
                     (push (list 'action action) events)))
                  ((symbol-function 'display-buffer)
                   (lambda (_buffer &optional _action _frame) nil)))
          (agent-codex-send-command "$session-learning-capture" buf)
          (agent-codex-send-return buf))))
    (should (equal (nreverse events)
                   '((string "$session-learning-capture")
                     (action :return))))))

(ert-deftest agent-codex-test-send-return-sends-return-action ()
  "Send the Codex return action when submitting the current prompt."
  (let (actions)
    (with-temp-buffer
      (cl-letf (((symbol-function 'codex--term-send-action)
                 (lambda (_backend action &optional _payload)
                   (push action actions)))
                ((symbol-function 'display-buffer) #'ignore))
        (agent-codex-send-return (current-buffer))))
    (should (equal actions '(:return)))))

(ert-deftest agent-codex-test-submit-command-delegates-to-codex-buffer-submit ()
  "Submit Codex command text through Codex's target-buffer primitive."
  (let (events expected-buffer)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (setq expected-buffer buf)
        (cl-letf (((symbol-function 'codex--send-command-to-buffer)
                   (lambda (cmd buffer)
                     (push (list cmd buffer) events))))
          (agent-codex-submit-command "$session-learning-capture" buf))))
    (should (equal (nreverse events)
                   (list (list "$session-learning-capture"
                               expected-buffer))))))

;;;; Session event translation

(ert-deftest agent-codex-test-stop-marks-awaiting-input-and-alerts ()
  "Mark Codex sessions awaiting input and alert on CLI Stop events."
  (let ((buf (generate-new-buffer "*codex:/tmp/project/:default*"))
        notified)
    (unwind-protect
        (cl-letf (((symbol-function 'agent-codex-notify)
                   (lambda (title message)
                     (setq notified (list title message)))))
          (with-current-buffer buf
            (setq-local agent--backend 'codex))
          (agent-codex--handle-notification
           (list :type "Stop" :buffer-name (buffer-name buf)))
          (should (eq (buffer-local-value 'agent--session-state buf)
                      'awaiting-input))
          (should (equal notified
                         '("Codex ready"
                           "project: waiting for your response"))))
      (kill-buffer buf))))

(ert-deftest agent-codex-test-permission-request-alerts-without-state-change ()
  "Alert on CLI PermissionRequest events without touching session state."
  (let ((buf (generate-new-buffer "*codex:/tmp/project/:default*"))
        notified session-events)
    (unwind-protect
        (cl-letf (((symbol-function 'agent-codex-notify)
                   (lambda (title message)
                     (setq notified (list title message))))
                  ((symbol-function 'agent-session-event)
                   (lambda (&rest args) (push args session-events))))
          (with-current-buffer buf
            (setq-local agent--backend 'codex))
          (agent-codex--handle-notification
           (list :type "PermissionRequest"
                 :buffer-name (buffer-name buf)
                 :json-data (concat "{\"hook_event_name\":\"PermissionRequest\","
                                    "\"tool_name\":\"Bash\","
                                    "\"tool_input\":{\"command\":\"touch /tmp/x\"}}")))
          (should (equal notified
                         '("Codex needs approval"
                           "project: permission request pending")))
          (should-not session-events)
          (should (eq (buffer-local-value 'agent--session-state buf) 'busy)))
      (kill-buffer buf))))

(ert-deftest agent-codex-test-notify-ready-dispatches-backend-notify ()
  "Dispatch Codex ready alerts through the registered notify slot."
  (let ((buf (generate-new-buffer "*codex:/tmp/project/:default*"))
        notified fallback)
    (unwind-protect
        (cl-letf (((symbol-function 'agent-codex-notify)
                   (lambda (title message)
                     (setq notified (list title message))))
                  ((symbol-function 'agent-notify)
                   (lambda (&rest args) (setq fallback args))))
          (with-current-buffer buf
            (setq-local agent--backend 'codex))
          (agent--session-notify-ready buf)
          (should (equal notified
                         '("Codex ready"
                           "project: waiting for your response")))
          (should-not fallback))
      (kill-buffer buf))))

(ert-deftest agent-codex-test-submitted-hook-emits-submit-event ()
  "Return Codex sessions to busy when a command is submitted."
  (with-temp-buffer
    (let ((buf (current-buffer)))
      (setq-local agent--session-state 'awaiting-input)
      (agent-codex--note-submission buf)
      (should (eq (buffer-local-value 'agent--session-state buf) 'busy)))))

(ert-deftest agent-codex-test-before-exit-ready-vetoes-pending-prompt ()
  "Do not auto-close while Codex still has prompt input."
  (with-temp-buffer
    (cl-letf (((symbol-function 'codex-prompt-input)
               (lambda (&optional _buffer) "git status")))
      (should-not (agent-codex-before-exit-ready-to-close-p
                   (current-buffer))))))

(ert-deftest agent-codex-test-before-exit-ready-allows-empty-prompt ()
  "Allow auto-close when Codex is back at an empty prompt."
  (with-temp-buffer
    (cl-letf (((symbol-function 'codex-prompt-input)
               (lambda (&optional _buffer) nil)))
      (should (agent-codex-before-exit-ready-to-close-p
               (current-buffer))))))

(ert-deftest agent-codex-test-stop-closes-after-submitted-before-exit-skill ()
  "Close a pending before-exit session when the submitted skill finishes."
  (let ((buf (generate-new-buffer "*codex:/tmp/project/*"))
        ran)
    (unwind-protect
        (cl-letf (((symbol-function 'codex-prompt-input)
                   (lambda (&optional _buffer) nil))
                  ((symbol-function 'run-at-time)
                   (lambda (_time _repeat function &rest args)
                     (apply function args)))
                  ((symbol-function 'agent--exit-session)
                   (lambda (_buffer) (setq ran t))))
          (with-current-buffer buf
            (setq-local agent--backend 'codex)
            (setq-local agent--before-exit
                        (list :queue nil :state 'running)))
          (agent-codex--handle-notification
           (list :type "Stop" :buffer-name (buffer-name buf)))
          (should ran)
          (with-current-buffer buf
            (should (eq (plist-get agent--before-exit :state) 'closing))))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest agent-codex-test-detects-background-terminal-work ()
  "Detect Codex status lines that report background terminal work."
  (let ((buf (generate-new-buffer "*codex-test*")))
    (unwind-protect
        (with-current-buffer buf
          (insert "• Working (13m 19s · esc to interrupt) · 1 background terminal running · /ps to view\n")
          (should (agent-codex--has-background-tasks-p buf)))
      (kill-buffer buf))))

(ert-deftest agent-codex-test-detects-working-status ()
  "Detect Codex status lines that report an active response."
  (let ((buf (generate-new-buffer "*codex-test*")))
    (unwind-protect
        (with-current-buffer buf
          (insert "• Working (20m 58s • esc to interrupt)\n")
          (should (agent-codex--busy-p buf)))
      (kill-buffer buf))))

(ert-deftest agent-codex-test-detects-app-server-active-turn ()
  "Detect active app-server turns without rendered TUI status text."
  (let ((buf (generate-new-buffer "*codex-test*")))
    (unwind-protect
        (with-current-buffer buf
          (setq-local codex--app-server-turn-active-p t)
          (should (agent-codex--busy-p buf)))
      (kill-buffer buf))))

(ert-deftest agent-codex-test-working-status-is-not-waiting ()
  "Do not display stale Codex waiting state while Codex is working."
  (let ((buf (generate-new-buffer "*codex-test*")))
    (unwind-protect
        (with-current-buffer buf
          (setq-local agent--session-state 'awaiting-input)
          (insert "• Working (20m 58s • esc to interrupt)\n")
          (should (eq (agent-session-display-state buf 'codex) 'busy)))
      (kill-buffer buf))))

(ert-deftest agent-codex-test-app-server-active-turn-is-not-waiting ()
  "Do not display stale Codex waiting state during app-server turns."
  (let ((buf (generate-new-buffer "*codex-test*")))
    (unwind-protect
        (with-current-buffer buf
          (setq-local agent--session-state 'awaiting-input)
          (setq-local codex--app-server-turn-active-p t)
          (should (eq (agent-session-display-state buf 'codex) 'busy)))
      (kill-buffer buf))))

(ert-deftest agent-codex-test-app-server-active-prompt-is-background-waiting ()
  "Show app-server turns with an available prompt as background waiting."
  (let ((buf (generate-new-buffer "*codex-test*")))
    (unwind-protect
        (with-current-buffer buf
          (insert "❯ ")
          (setq-local codex--app-server-turn-active-p t)
          (setq-local codex--app-server-input-marker
                      (copy-marker (point-max) nil))
          (should (eq (agent-session-display-state buf 'codex)
                      'background-waiting)))
      (kill-buffer buf))))

(ert-deftest agent-codex-test-waiting-with-background-work-is-amber ()
  "Show waiting Codex sessions with background work as background waiting."
  (let ((buf (generate-new-buffer "*codex-test*")))
    (unwind-protect
        (with-current-buffer buf
          (setq-local agent--session-state 'awaiting-input)
          (insert "  · 2 background terminals running\n")
          (should (eq (agent-session-display-state buf 'codex)
                      'background-waiting)))
      (kill-buffer buf))))

(ert-deftest agent-codex-test-notify-uses-agent-alert ()
  "Route Codex notifications through the shared Agent alert setting."
  (let ((agent-alert-on-ready t)
        (agent-alert-style 'visual)
        visual)
    (cl-letf (((symbol-function 'codex-default-notification) #'ignore)
              ((symbol-function 'agent--alert-visual)
               (lambda (title message)
                 (setq visual (list title message)))))
      (agent-codex-notify "Codex Ready" "Waiting for your response")
      (should (equal visual
                     '("Codex Ready" "Waiting for your response"))))))

;;;; Theme sync

(ert-deftest agent-codex-test-sync-theme-updates-existing-tui-section ()
  "Persist theme changes to an existing Codex `[tui]' section."
  (let* ((dir (make-temp-file "codex-theme" t))
         (config (expand-file-name "config.toml" dir))
         (codex-hooks-config-path config))
    (unwind-protect
        (progn
          (with-temp-file config
            (insert "model = \"gpt-5.5\"\n\n[tui]\ntheme = \"light\"\n"))
          (should (agent-codex--sync-theme "dark"))
          (should (string-match-p
                   "^\\[tui\\]\ntheme = \"dark\""
                   (with-temp-buffer
                     (insert-file-contents config)
                     (buffer-string)))))
      (delete-directory dir t))))

(ert-deftest agent-codex-test-sync-theme-adds-tui-section ()
  "Create a Codex `[tui]' section when the config has none."
  (let* ((dir (make-temp-file "codex-theme" t))
         (config (expand-file-name "config.toml" dir))
         (codex-hooks-config-path config))
    (unwind-protect
        (progn
          (with-temp-file config
            (insert "model = \"gpt-5.5\"\n"))
          (should (agent-codex--sync-theme "light"))
          (should (string-match-p
                   "\\[tui\\]\ntheme = \"light\""
                   (with-temp-buffer
                     (insert-file-contents config)
                     (buffer-string)))))
      (delete-directory dir t))))

(ert-deftest agent-codex-test-sync-theme-skips-unchanged-config ()
  "Avoid rewriting Codex config when the theme already matches."
  (let* ((dir (make-temp-file "codex-theme" t))
         (config (expand-file-name "config.toml" dir))
         (codex-hooks-config-path config))
    (unwind-protect
        (progn
          (with-temp-file config
            (insert "[tui]\ntheme = \"dark\"\n"))
          (should-not (agent-codex--sync-theme "dark")))
      (delete-directory dir t))))

(ert-deftest agent-codex-test-sync-theme-to-config-allows-legacy-call ()
  "Accept the old no-argument theme config writer call."
  (let* ((dir (make-temp-file "codex-theme" t))
         (config (expand-file-name "config.toml" dir))
         (codex-hooks-config-path config))
    (unwind-protect
        (progn
          (with-temp-file config
            (insert "[tui]\ntheme = \"light\"\n"))
          (cl-letf (((symbol-function 'frame-parameter)
                     (lambda (_frame param)
                       (when (eq param 'background-mode) 'dark))))
            (should (agent-codex--sync-theme-to-config)))
          (should (string-match-p
                   "^\\[tui\\]\ntheme = \"dark\""
                   (with-temp-buffer
                     (insert-file-contents config)
                     (buffer-string)))))
      (delete-directory dir t))))

(ert-deftest agent-codex-test-sync-theme-uses-starting-account-home ()
  "Persist theme changes to the starting account's Codex config."
  (let* ((dir (make-temp-file "codex-theme" t))
         (home (expand-file-name "work" dir))
         (canonical (expand-file-name ".codex" dir))
         (config (expand-file-name "config.toml" home))
         (canonical-config (expand-file-name "config.toml" canonical))
         (process-environment (cons (format "HOME=%s" dir)
                                    process-environment))
         (agent-codex-accounts `(("work" . ,home)))
         (agent-account--starting '(codex . "work")))
    (unwind-protect
        (progn
          (make-directory canonical t)
          (with-temp-file canonical-config
            (insert "[tui]\ntheme = \"light\"\n"))
          (agent-account-sync 'codex "work")
          (should (agent-codex--sync-theme "dark"))
          (should (string-match-p
                   "^\\[tui\\]\ntheme = \"dark\""
                   (with-temp-buffer
                     (insert-file-contents config)
                     (buffer-string)))))
      (delete-directory dir t))))

;;;; Skill runner

(ert-deftest agent-codex-test-parse-skill-frontmatter-argument-metadata ()
  "Parse Codex skill argument metadata with the shared parser."
  (let ((file (make-temp-file "codex-skill" nil ".md")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "---\n")
            (insert "name: proofread\n")
            (insert "description: Proofread a file\n")
            (insert "argument-hint: FILE\n")
            (insert "argument-source: references/*.org\n")
            (insert "---\n"))
          (let ((meta (agent-parse-skill-frontmatter file)))
            (should (equal (plist-get meta :name) "proofread"))
            (should (equal (plist-get meta :argument-hint) "FILE"))
            (should (equal (plist-get meta :argument-source)
                           "references/*.org"))))
      (delete-file file))))

(ert-deftest agent-codex-test-discover-skills-skips-non-invocable ()
  "Discover non-invocable Codex skills but hide them from completion."
  (let* ((dir (make-temp-file "codex-skills" t))
         (codex-home (make-temp-file "codex-home" t))
         (visible (expand-file-name "visible/SKILL.md" dir))
         (hidden (expand-file-name "hidden/SKILL.md" dir))
         (process-environment
          (cons (format "CODEX_HOME=%s" codex-home) process-environment))
         (agent-backends (list (assq 'codex agent-backends)))
         (agent-codex-skill-directories (list dir))
         (agent-codex-programmatic-skill-directories nil)
         (default-directory dir))
    (unwind-protect
        (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil))
                  ((symbol-function 'agent-codex--codex-plugin-list)
                   (lambda (_codex-home) nil)))
          (make-directory (file-name-directory visible) t)
          (make-directory (file-name-directory hidden) t)
          (with-temp-file visible
            (insert "---\nname: visible\n---\n"))
          (with-temp-file hidden
            (insert "---\nname: hidden\nuser-invocable: false\n---\n"))
          (should (equal (mapcar (lambda (skill) (plist-get skill :name))
                                 (agent-discover-skills 'codex))
                         '("hidden" "visible")))
          (should (equal (mapcar (lambda (skill) (plist-get skill :name))
                                 (agent--discover-all-skills))
                         '("visible"))))
      (delete-directory dir t)
      (delete-directory codex-home t))))

(ert-deftest agent-codex-test-discover-skills-uses-selected-account-home ()
  "Discover user skills from the selected account's CODEX_HOME."
  (let* ((dir (make-temp-file "codex-account-skills" t))
         (env-home (expand-file-name "env-home" dir))
         (selected-home (expand-file-name "selected-home" dir))
         (env-skill (expand-file-name "skills/env-only/SKILL.md" env-home))
         (selected-skill
          (expand-file-name "skills/selected-only/SKILL.md" selected-home))
         (process-environment
          (cons (format "CODEX_HOME=%s" env-home) process-environment))
         (agent-codex-accounts `(("work" . ,selected-home)))
         (agent-account--starting '(codex . "work"))
         (agent-codex-skill-directories nil)
         (agent-codex-programmatic-skill-directories nil)
         (default-directory dir))
    (unwind-protect
        (progn
          (make-directory (file-name-directory env-skill) t)
          (make-directory (file-name-directory selected-skill) t)
          (with-temp-file env-skill
            (insert "---\nname: env-only\n---\n"))
          (with-temp-file selected-skill
            (insert "---\nname: selected-only\n---\n"))
          (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil))
                    ((symbol-function 'agent-codex--codex-plugin-list)
                     (lambda (_codex-home) nil)))
            (should (equal (mapcar (lambda (skill) (plist-get skill :name))
                                   (agent-discover-skills 'codex))
                           '("selected-only")))))
      (delete-directory dir t))))

(ert-deftest agent-codex-test-discover-skills-includes-current-plugin-roots ()
  "Discover plugin skills only from enabled current plugin versions."
  (let* ((dir (make-temp-file "codex-plugin-skills" t))
         (codex-home (expand-file-name ".codex-work" dir))
         (old-skill
          (expand-file-name
           "plugins/cache/openai-curated/superpowers/oldhash/skills/old-plugin/SKILL.md"
           codex-home))
         (new-skill
          (expand-file-name
           "plugins/cache/openai-curated/superpowers/newhash/skills/new-plugin/SKILL.md"
           codex-home))
         (disabled-skill
          (expand-file-name
           "plugins/cache/openai-curated/browser/newhash/skills/disabled-plugin/SKILL.md"
           codex-home))
         (agent-codex-accounts `(("work" . ,codex-home)))
         (agent-account--starting '(codex . "work"))
         (agent-codex-skill-directories nil)
         (agent-codex-programmatic-skill-directories nil)
         (plugin-list '(((name . "superpowers")
                         (marketplaceName . "openai-curated")
                         (version . "newhash")
                         (installed . t)
                         (enabled . t))
                        ((name . "browser")
                         (marketplaceName . "openai-curated")
                         (version . "newhash")
                         (installed . t)
                         (enabled . :false))))
         (default-directory dir))
    (unwind-protect
        (progn
          (dolist (file (list old-skill new-skill disabled-skill))
            (make-directory (file-name-directory file) t))
          (with-temp-file old-skill
            (insert "---\nname: old-plugin\n---\n"))
          (with-temp-file new-skill
            (insert "---\nname: new-plugin\n---\n"))
          (with-temp-file disabled-skill
            (insert "---\nname: disabled-plugin\n---\n"))
          (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil))
                    ((symbol-function 'agent-codex--codex-plugin-list)
                     (lambda (_codex-home) plugin-list)))
            (should (equal (mapcar (lambda (skill) (plist-get skill :name))
                                   (agent-discover-skills 'codex))
                           '("new-plugin")))))
      (delete-directory dir t))))

(ert-deftest agent-codex-test-build-exec-command ()
  "Build a current `codex exec' command line."
  (let ((codex-program "codex")
        (codex-program-switches '("--search"))
        (codex-model "gpt-5.5")
        (codex-profile "work")
        (codex-sandbox-mode 'workspace-write)
        (codex-approval-policy 'on-request)
        (codex-default-images '("image.png"))
        (agent-codex-exec-approval-policy 'never)
        (agent-codex-exec-sandbox-mode nil)
        (agent-codex-exec-skip-git-repo-check t))
    (should (equal
             (agent-codex--build-exec-command "prompt" "/tmp/project")
             '("codex" "--search" "--ask-for-approval" "never"
               "exec" "--model" "gpt-5.5"
               "--profile" "work" "--sandbox" "workspace-write"
               "--image" "image.png" "--cd" "/tmp/project" "--color" "never"
               "--skip-git-repo-check" "prompt")))))

(ert-deftest agent-codex-test-run-skill-uses-codex-exec ()
  "Run discovered skills through the non-interactive Codex path."
  (let* ((dir (make-temp-file "codex-skills" t))
         (codex-home (make-temp-file "codex-home" t))
         (skill-file (expand-file-name "proofread/SKILL.md" dir))
         (process-environment
          (cons (format "CODEX_HOME=%s" codex-home) process-environment))
         (agent-codex-skill-directories (list dir))
         (agent-codex-programmatic-skill-directories nil)
         (default-directory dir)
         captured-prompt
         captured-dir)
    (unwind-protect
        (progn
          (make-directory (file-name-directory skill-file) t)
          (with-temp-file skill-file
            (insert "---\nname: proofread\n---\nProofread the file.\n"))
          (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil))
                    ((symbol-function 'agent-codex--codex-plugin-list)
                     (lambda (_codex-home) nil))
                    ((symbol-function 'agent-codex-run-prompt)
                     (cl-function
                      (lambda (prompt &key directory callback)
                        (ignore callback)
                        (setq captured-prompt prompt
                              captured-dir directory)))))
            (let ((skill (cl-find "proofread" (agent-discover-skills 'codex)
                                  :key (lambda (s) (plist-get s :name))
                                  :test #'equal)))
              (agent--run-skill 'codex skill "file.org")))
          (should (string-match-p (regexp-quote skill-file) captured-prompt))
          (should (string-match-p "Arguments: file.org" captured-prompt))
          (should (equal captured-dir default-directory)))
      (delete-directory dir t)
      (delete-directory codex-home t))))

(ert-deftest agent-codex-test-run-prompt-slot-normalizes-success ()
  "Translate the rich codex result plist into the normalized callback."
  (let (got)
    (cl-letf (((symbol-function 'agent-codex--run-prompt)
               (lambda (_prompt &rest kwargs)
                 (funcall (plist-get kwargs :callback)
                          '(:exit-code 0 :duration 1.0
                            :text "done" :raw "done")))))
      (agent-codex-run-prompt "p" :directory "/tmp/"
                              :callback (cl-function
                                         (lambda (text &key error)
                                           (setq got (list text error)))))
      (should (equal got '("done" nil))))))

(ert-deftest agent-codex-test-run-prompt-slot-reports-error ()
  "Pass a non-nil :error to the normalized callback on failure."
  (let (got)
    (cl-letf (((symbol-function 'agent-codex--run-prompt)
               (lambda (_prompt &rest kwargs)
                 (funcall (plist-get kwargs :callback)
                          '(:exit-code 2 :duration 1.0
                            :text "boom" :raw "boom")))))
      (agent-codex-run-prompt "p"
                              :callback (cl-function
                                         (lambda (text &key error)
                                           (setq got (list text error)))))
      (should (equal (car got) "boom"))
      (should (string-match-p "exit code 2" (cadr got))))))

;;;; Session capture

(ert-deftest agent-codex-test-capture-session-stores-starting-account ()
  "Replace a stale accountless struct when capturing the session."
  (with-temp-buffer
    (rename-buffer "*codex:~/repo/codex-capture-session-test/:default*" t)
    ;; Simulate lazy backfill running before the start binding existed.
    (agent--set-session
     (current-buffer)
     (agent-session-create :backend 'codex
                           :directory "~/repo/codex-capture-session-test/"))
    (let ((agent-account--starting '(codex . "personal")))
      (agent--capture-session (current-buffer))
      (let ((session (agent-session (current-buffer))))
        (should session)
        (should (eq (agent-session-backend session) 'codex))
        (should (equal (agent-session-account session) "personal"))
        (should (equal (agent-session-directory session)
                       "~/repo/codex-capture-session-test/"))
        (should (equal (agent-session-instance session) "default"))))))

(ert-deftest agent-codex-test-start-session-binds-account-and-records-session ()
  "Bind the starting account and attach the session to the new buffer."
  (let ((buffer (generate-new-buffer " *codex-test-session*"))
        captured)
    (unwind-protect
        (cl-letf (((symbol-function 'agent-account-sync) #'ignore)
                  ((symbol-function 'codex-start-session)
                   (lambda (&rest keys)
                     (setq captured
                           (append keys
                                   (list :account
                                         (cdr-safe agent-account--starting))))
                     buffer)))
          (let ((session (agent-session-create
                          :backend 'codex
                          :account "work"
                          :directory "/tmp/project/"
                          :instance "fix")))
            (should (eq (agent-start-session session :resume-id "abc")
                        buffer))
            (should (equal (plist-get captured :directory) "/tmp/project/"))
            (should (equal (plist-get captured :instance-name) "fix"))
            (should (equal (plist-get captured :resume-id) "abc"))
            (should (equal (plist-get captured :account) "work"))
            (should (eq (agent-session buffer) session))))
      (kill-buffer buffer))))

;;;; Minor mode

(ert-deftest agent-codex-test-mode-symmetric ()
  "Enabling then disabling the mode leaves global state untouched."
  (let ((codex-notification-function #'ignore)
        (codex-start-hook nil)
        (codex-event-hook nil)
        (codex-command-submitted-hook nil)
        (codex-process-environment-functions nil)
        (kill-buffer-query-functions kill-buffer-query-functions))
    (agent-codex-mode 1)
    (should (memq #'agent-codex--handle-notification codex-event-hook))
    (should (memq #'agent-codex-account-env
                  codex-process-environment-functions))
    (should (memq #'agent-codex--note-submission
                  codex-command-submitted-hook))
    (should (memq #'agent-codex--record-start-time codex-start-hook))
    (should (memq #'agent-codex--register-session-teardown codex-start-hook))
    (should (eq codex-notification-function #'codex-default-notification))
    (should (advice-member-p #'agent-codex--intercept-exit
                             'codex--do-send-command))
    (should (advice-member-p #'agent-codex--intercept-exit-to-buffer
                             'codex--send-command-to-buffer))
    (agent-codex-mode -1)
    (should-not (memq #'agent-codex--handle-notification codex-event-hook))
    (should-not codex-start-hook)
    (should-not codex-command-submitted-hook)
    (should-not codex-process-environment-functions)
    (should (eq codex-notification-function #'ignore))
    (should-not (advice-member-p #'agent-codex--intercept-exit
                                 'codex--do-send-command))
    (should-not (advice-member-p #'agent-codex--intercept-exit-to-buffer
                                 'codex--send-command-to-buffer))))

(provide 'agent-codex-test)
;;; agent-codex-test.el ends here
