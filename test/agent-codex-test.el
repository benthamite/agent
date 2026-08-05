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
          (should (eq (buffer-local-value 'agent--session-state buf) 'unknown)))
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

(ert-deftest agent-codex-test-app-server-active-prompt-is-busy ()
  "Show app-server turns as busy even when the prompt accepts input.
Queueing text mid-turn has always been possible and does not mean Codex
is waiting for the user."
  (let ((buf (generate-new-buffer "*codex-test*"))
        (proc (start-process "agent-codex-test-server" nil "sleep" "30")))
    (unwind-protect
        (with-current-buffer buf
          (insert "❯ ")
          (setq-local codex--app-server-process proc)
          (setq-local codex--app-server-turn-active-p t)
          (setq-local codex--app-server-input-marker
                      (copy-marker (point-max) nil))
          (setq-local agent--session-state 'awaiting-input)
          (should (eq (agent-session-display-state buf 'codex) 'busy)))
      (delete-process proc)
      (kill-buffer buf))))

(ert-deftest agent-codex-test-app-server-completed-turn-is-waiting ()
  "Show a finished app-server turn as waiting despite a stale busy state."
  (let ((buf (generate-new-buffer "*codex-test*"))
        (proc (start-process "agent-codex-test-server" nil "sleep" "30")))
    (unwind-protect
        (with-current-buffer buf
          (insert "❯ ")
          (setq-local codex--app-server-process proc)
          (setq-local codex--app-server-turn-active-p nil)
          (setq-local agent--session-state 'busy)
          (should (eq (agent-session-display-state buf 'codex) 'waiting)))
      (delete-process proc)
      (kill-buffer buf))))

(ert-deftest agent-codex-test-terminal-session-ignores-app-server-turn-flag ()
  "Leave terminal Codex sessions to the session-event state machine.
Without a live app server an inactive turn flag carries no information,
so it must not be read as waiting."
  (let ((buf (generate-new-buffer "*codex-test*")))
    (unwind-protect
        (with-current-buffer buf
          (insert "❯ ")
          (setq-local codex--app-server-process nil)
          (setq-local codex--app-server-turn-active-p nil)
          (setq-local agent--session-state 'busy)
          (should (eq (agent-session-display-state buf 'codex) 'busy)))
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

(ert-deftest agent-codex-test-start-session-passes-fork-through ()
  "Pass `:fork' on to `codex-start-session' for a session with a transcript.
A rollout file on disk is what makes a session forkable, so writing one
for the resumed id is what lets this fork reach `codex-start-session'
at all."
  (let* ((root (make-temp-file "codex-sessions" t))
         (codex-transcript-sessions-directory root)
         (codex--transcript-file-cache (make-hash-table :test #'equal))
         (received nil))
    (unwind-protect
        (progn
          (write-region "" nil (expand-file-name "abc.jsonl" root))
          (cl-letf (((symbol-function 'codex-start-session)
                     (lambda (&rest args) (setq received args) (current-buffer)))
                    ((symbol-function 'agent--set-session) #'ignore))
            (agent-codex--start-session
             (agent-session-create :backend 'codex :directory "/tmp/p/")
             :resume-id "abc" :fork t)
            (should (plist-get received :fork))
            (should (equal (plist-get received :resume-id) "abc"))))
      (delete-directory root t))))

(ert-deftest agent-codex-test-start-session-fork-without-transcript-errors ()
  "Refuse to fork a Codex session that has produced no transcript yet.
Codex forks by locating the parent session's rollout file on disk, and
Codex does not write that file until the session has run a turn.  Left
unchecked, forking such a session does not error inside Codex either:
the app server just prints a status line into the new, empty session
buffer, so the caller has no way to tell the fork failed.  Catching the
missing transcript here, before any session is started, turns that
silent failure into a `user-error' the caller can see."
  (let* ((root (make-temp-file "codex-sessions" t))
         (codex-transcript-sessions-directory root)
         (codex--transcript-file-cache (make-hash-table :test #'equal)))
    (unwind-protect
        (should-error
         (agent-codex--start-session
          (agent-session-create :backend 'codex :directory "/tmp/p/")
          :resume-id "abc-123" :fork t)
         :type 'user-error)
      (delete-directory root t))))

;;;; Session id recording

(ert-deftest agent-codex-test-handle-notification-notes-session-id ()
  "Record the native session id reported by a Codex hook event."
  (let ((buf (generate-new-buffer "*codex-test-session-id*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (agent--set-session
             buf (agent-session-create :backend 'codex
                                       :directory "~/project/")))
          (cl-letf (((symbol-function 'codex-session-identity)
                     (lambda (&optional _buffer)
                       '(:session-id "codex-sid-1")))
                    ((symbol-function 'agent-session-event) #'ignore))
            (agent-codex--handle-notification
             (list :type "SessionStart" :buffer-name (buffer-name buf)))
            (should (equal (agent-session-id (agent-session buf))
                           "codex-sid-1"))))
      (kill-buffer buf))))

(ert-deftest agent-codex-test-note-submission-notes-session-id ()
  "Record the native session id when a submission fires the hook.
A fresh app-server session knows its thread id before any CLI hook
event, so the submission hook must also record it."
  (let ((buf (generate-new-buffer "*codex-test-submit-id*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (agent--set-session
             buf (agent-session-create :backend 'codex
                                       :directory "~/project/")))
          (cl-letf (((symbol-function 'codex-session-identity)
                     (lambda (&optional _buffer)
                       '(:session-id "codex-sid-2")))
                    ((symbol-function 'agent-session-event) #'ignore))
            (agent-codex--note-submission buf)
            (should (equal (agent-session-id (agent-session buf))
                           "codex-sid-2"))))
      (kill-buffer buf))))

;;;; Session headers

(defun agent-codex-test--write-rollout (dir id meta &optional lines timestamp)
  "Write a rollout file for session ID under DIR and return its path.
META is an alist merged into the session_meta payload; a `session_id'
entry in META overrides the default of ID, which is how a subagent
rollout records its parent's id.  LINES is a list of extra JSON strings
appended after the meta line.  TIMESTAMP is the start time encoded in
the file name, defaulting to a fixed one."
  (let* ((file (expand-file-name
                (format "rollout-%s-%s.jsonl"
                        (or timestamp "2026-08-05T08-08-27") id)
                dir))
         (payload (append meta
                          (unless (assq 'session_id meta)
                            `((session_id . ,id)))
                          `((timestamp . "2026-08-05T11:08:27.217Z")))))
    (make-directory dir t)
    (with-temp-file file
      (insert (json-encode `((timestamp . "2026-08-05T11:08:31.433Z")
                             (type . "session_meta")
                             (payload . ,payload)))
              "\n")
      (dolist (line (or lines '()))
        (insert line "\n")))
    file))

(ert-deftest agent-codex-test-session-id-comes-from-the-file-name ()
  "Take a thread's id from its file name, not the payload's session_id.
Subagent rollouts record the parent's id in `session_id', so trusting
the payload would collapse distinct threads onto one key."
  (should (equal (agent-codex--session-id-from-file
                  "/x/rollout-2026-08-05T08-08-27-019fd19c-44b9-7042-93b6-e4f7e21036ad.jsonl")
                 "019fd19c-44b9-7042-93b6-e4f7e21036ad"))
  (should-not (agent-codex--session-id-from-file "/x/notes.jsonl")))

(ert-deftest agent-codex-test-session-headers-keep-sessions-of-this-project ()
  "Keep rollouts whose cwd is the buffer's project and drop the others.
The kept rollout carries a payload `session_id' that differs from the id
in its file name, as a subagent rollout does, so a scan that trusted the
payload would key the table on the wrong thread."
  (let* ((root (make-temp-file "codex-sessions" t))
         (codex-transcript-sessions-directory root))
    (unwind-protect
        (progn
          (agent-codex-test--write-rollout
           root "019fd19c-44b9-7042-93b6-e4f7e21036ad"
           `((cwd . "/tmp/mine")
             (session_id . "019fd19c-44b9-7042-93b6-e4f7e2103ccc")))
          (agent-codex-test--write-rollout
           root "019fd19c-44b9-7042-93b6-e4f7e2103bbb"
           `((cwd . "/tmp/other")))
          (let ((headers (agent-codex--scan-session-headers "/tmp/mine/")))
            (should (= (hash-table-count headers) 1))
            (should (gethash "019fd19c-44b9-7042-93b6-e4f7e21036ad" headers))
            (should-not (gethash "019fd19c-44b9-7042-93b6-e4f7e2103ccc"
                                 headers))))
      (delete-directory root t))))

(ert-deftest agent-codex-test-session-headers-skip-subagent-threads ()
  "Skip subagent rollouts: they are forks, but not branches to navigate."
  (let* ((root (make-temp-file "codex-sessions" t))
         (codex-transcript-sessions-directory root))
    (unwind-protect
        (progn
          (agent-codex-test--write-rollout
           root "019fd19c-44b9-7042-93b6-e4f7e21036ad"
           `((cwd . "/tmp/mine") (thread_source . "subagent")))
          (should (= (hash-table-count
                      (agent-codex--scan-session-headers "/tmp/mine/"))
                     0)))
      (delete-directory root t))))

(ert-deftest agent-codex-test-session-headers-read-fork-parents ()
  "Read `forked_from_id' as the parent, ignoring a self-referential one."
  (let* ((root (make-temp-file "codex-sessions" t))
         (codex-transcript-sessions-directory root)
         (child "019fd19c-44b9-7042-93b6-e4f7e21036ad")
         (self "019fd19c-44b9-7042-93b6-e4f7e2103bbb"))
    (unwind-protect
        (progn
          (agent-codex-test--write-rollout
           root child `((cwd . "/tmp/mine") (forked_from_id . "parent-id")))
          (agent-codex-test--write-rollout
           root self `((cwd . "/tmp/mine") (forked_from_id . ,self)))
          (let ((headers (agent-codex--scan-session-headers "/tmp/mine/")))
            (should (equal (plist-get (gethash child headers) :forked-from)
                           "parent-id"))
            (should-not (plist-get (gethash self headers) :forked-from))))
      (delete-directory root t))))

(ert-deftest agent-codex-test-session-headers-read-long-meta-lines ()
  "Read a `session_meta' record longer than one read chunk.
Real rollouts carry tens of kilobytes of instructions on that first
line, so a reader that stops after a fixed prefix parses none of them."
  (let* ((root (make-temp-file "codex-sessions" t))
         (codex-transcript-sessions-directory root)
         (id "019fd19c-44b9-7042-93b6-e4f7e21036ad"))
    (unwind-protect
        (progn
          (agent-codex-test--write-rollout
           root id `((cwd . "/tmp/mine")
                     (instructions . ,(make-string 65536 ?x))))
          (should (gethash id (agent-codex--scan-session-headers "/tmp/mine/"))))
      (delete-directory root t))))

(ert-deftest agent-codex-test-session-headers-bound-by-start-not-mtime ()
  "Bound a descendant scan by rollout start time, not modification time.
The anchor is the session being killed, so it is still being written and
its file's mtime is newer than that of any descendant that has already
finished.  Bounding on mtime therefore hides exactly the descendants the
bound exists to find."
  (let* ((root (make-temp-file "codex-sessions" t))
         (codex-transcript-sessions-directory root)
         (codex--transcript-file-cache (make-hash-table :test #'equal))
         (anchor "019fd19c-44b9-7042-93b6-e4f7e21036ad")
         (child "019fd19c-44b9-7042-93b6-e4f7e2103bbb")
         (buffer (generate-new-buffer " *codex-headers*")))
    (unwind-protect
        (let ((anchor-file (agent-codex-test--write-rollout
                            root anchor `((cwd . ,root))
                            nil "2026-08-05T08-08-27"))
              (child-file (agent-codex-test--write-rollout
                           root child `((cwd . ,root)
                                        (forked_from_id . ,anchor))
                           nil "2026-08-05T09-30-00")))
          (set-file-times child-file (encode-time 0 0 12 1 1 2020))
          (set-file-times anchor-file (encode-time 0 0 12 1 1 2030))
          (with-current-buffer buffer
            (setq default-directory (file-name-as-directory root)))
          (let ((headers (agent-codex--session-headers buffer anchor)))
            (should (gethash child headers))
            (should (equal (plist-get (gethash child headers) :forked-from)
                           anchor))
            (should (gethash anchor headers))))
      (kill-buffer buffer)
      (delete-directory root t))))

(ert-deftest agent-codex-test-session-headers-drop-rollouts-started-earlier ()
  "Skip rollouts that started before the anchor, since none can descend."
  (let* ((root (make-temp-file "codex-sessions" t))
         (codex-transcript-sessions-directory root)
         (codex--transcript-file-cache (make-hash-table :test #'equal))
         (anchor "019fd19c-44b9-7042-93b6-e4f7e21036ad")
         (older "019fd19c-44b9-7042-93b6-e4f7e2103bbb")
         (buffer (generate-new-buffer " *codex-headers*")))
    (unwind-protect
        (progn
          (agent-codex-test--write-rollout
           root anchor `((cwd . ,root)) nil "2026-08-05T08-08-27")
          (agent-codex-test--write-rollout
           root older `((cwd . ,root)) nil "2026-08-04T23-59-59")
          (with-current-buffer buffer
            (setq default-directory (file-name-as-directory root)))
          (let ((headers (agent-codex--session-headers buffer anchor)))
            (should (gethash anchor headers))
            (should-not (gethash older headers))))
      (kill-buffer buffer)
      (delete-directory root t))))

(ert-deftest agent-codex-test-session-headers-unbounded-without-an-anchor-file ()
  "Scan everything when the anchor's own rollout cannot be located.
Returning nothing would silently drop the branch warning the bound
exists to speed up."
  (let* ((root (make-temp-file "codex-sessions" t))
         (codex-transcript-sessions-directory root)
         (codex--transcript-file-cache (make-hash-table :test #'equal))
         (id "019fd19c-44b9-7042-93b6-e4f7e21036ad")
         (buffer (generate-new-buffer " *codex-headers*")))
    (unwind-protect
        (progn
          (agent-codex-test--write-rollout
           root id `((cwd . ,root)) nil "2026-08-01T00-00-00")
          (with-current-buffer buffer
            (setq default-directory (file-name-as-directory root)))
          (should (gethash
                   id (agent-codex--session-headers
                       buffer "019fd19c-44b9-7042-93b6-e4f7e2103fff"))))
      (kill-buffer buffer)
      (delete-directory root t))))

(ert-deftest agent-codex-test-session-headers-empty-for-a-dead-buffer ()
  "Return an empty hash table, not nil, once the session buffer is gone.
The backend slot promises a hash table, and callers count its entries."
  (let ((buffer (generate-new-buffer " *codex-headers*")))
    (kill-buffer buffer)
    (let ((headers (agent-codex--session-headers buffer)))
      (should (hash-table-p headers))
      (should (= (hash-table-count headers) 0)))))

(ert-deftest agent-codex-test-session-headers-ignore-null-fork-parents ()
  "Treat a JSON null `forked_from_id' as no parent at all.
`json-parse-string' reads null as `:null', which is non-nil and unequal
to the session id, so an unguarded read makes an unforked session look
like a fork of a parent that does not exist."
  (let* ((root (make-temp-file "codex-sessions" t))
         (codex-transcript-sessions-directory root)
         (id "019fd19c-44b9-7042-93b6-e4f7e21036ad"))
    (unwind-protect
        (progn
          (agent-codex-test--write-rollout
           root id `((cwd . "/tmp/mine") (forked_from_id . ,json-null)))
          (let ((header (gethash id (agent-codex--scan-session-headers
                                     "/tmp/mine/"))))
            (should header)
            (should-not (plist-get header :forked-from))))
      (delete-directory root t))))

(ert-deftest agent-codex-test-session-header-lets-extraction-bugs-surface ()
  "Let a fault in header extraction signal instead of skipping the file.
A guard around the whole body turns a bug in this code into a silently
empty scan: that is how a fixed-size-read bug once dropped 3,185 of
3,186 real rollouts while every unit test stayed green."
  (let* ((root (make-temp-file "codex-sessions" t))
         (codex-transcript-sessions-directory root)
         (id "019fd19c-44b9-7042-93b6-e4f7e21036ad"))
    (unwind-protect
        (let ((file (agent-codex-test--write-rollout
                     root id `((cwd . "/tmp/mine")))))
          (cl-letf (((symbol-function 'agent-codex--session-id-from-file)
                     (lambda (&rest _)
                       (signal 'wrong-type-argument '(stringp 7)))))
            (should-error (agent-codex--read-session-header file "/tmp/mine/")
                          :type 'wrong-type-argument)))
      (delete-directory root t))))

(ert-deftest agent-codex-test-session-headers-skip-unparseable-rollouts ()
  "Keep scanning past a rollout whose first line is not JSON.
Narrowing the error guard must still tolerate malformed input on disk."
  (let* ((root (make-temp-file "codex-sessions" t))
         (codex-transcript-sessions-directory root)
         (id "019fd19c-44b9-7042-93b6-e4f7e21036ad"))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name
                           (concat "rollout-2026-08-05T08-08-27-"
                                   "019fd19c-44b9-7042-93b6-e4f7e2103bbb"
                                   ".jsonl")
                           root)
            (insert "not json at all\n"))
          (agent-codex-test--write-rollout root id `((cwd . "/tmp/mine")))
          (let ((headers (agent-codex--scan-session-headers "/tmp/mine/")))
            (should (= (hash-table-count headers) 1))
            (should (gethash id headers))))
      (delete-directory root t))))

;;;; Fork family bound

(defun agent-codex-test--session-id (suffix)
  "Return a UUID-shaped session id ending in SUFFIX.
SUFFIX is three hex characters, which is enough to tell one fixture
session from another while keeping the id shaped like the real thing."
  (concat "019fd19c-44b9-7042-93b6-e4f7e2103" suffix))

(defun agent-codex-test--write-fork-family (dir)
  "Write a five-session fork fixture under DIR and return its session ids.
The ids come back as (ROOT CHILD CURRENT SIBLING STRANGER).  CURRENT
forks CHILD, CHILD and SIBLING fork ROOT, and STRANGER started before
ROOT and belongs to no family.  Every session records DIR as its
working directory, so a scan of DIR keeps them all."
  (let ((root (agent-codex-test--session-id "aaa"))
        (child (agent-codex-test--session-id "bbb"))
        (current (agent-codex-test--session-id "ccc"))
        (sibling (agent-codex-test--session-id "ddd"))
        (stranger (agent-codex-test--session-id "eee")))
    (agent-codex-test--write-rollout
     dir root `((cwd . ,dir)) nil "2026-08-05T08-00-00")
    (agent-codex-test--write-rollout
     dir child `((cwd . ,dir) (forked_from_id . ,root))
     nil "2026-08-05T09-00-00")
    (agent-codex-test--write-rollout
     dir current `((cwd . ,dir) (forked_from_id . ,child))
     nil "2026-08-05T10-00-00")
    (agent-codex-test--write-rollout
     dir sibling `((cwd . ,dir) (forked_from_id . ,root))
     nil "2026-08-05T08-30-00")
    (agent-codex-test--write-rollout
     dir stranger `((cwd . ,dir)) nil "2026-08-01T00-00-00")
    (list root child current sibling stranger)))

(defun agent-codex-test--branch-members (session-id headers)
  "Return the sorted ids of SESSION-ID's branch family within HEADERS."
  (sort (hash-table-keys
         (agent--branch-tree-members
          (agent--branch-root session-id headers)
          (agent--branch-children-map headers)))
        #'string<))

(ert-deftest agent-codex-test-session-headers-bound-by-the-fork-family-root ()
  "Bound an unanchored scan by the root of the buffer's own fork family.
The current session sits two forks below that root, so the walk has to
climb twice to find it.  Every member of a family starts at or after
its root, so the bound keeps the whole family while dropping the rest
of a session store that holds thousands of unrelated rollouts."
  (let* ((dir (make-temp-file "codex-sessions" t))
         (codex-transcript-sessions-directory dir)
         (codex--transcript-file-cache (make-hash-table :test #'equal))
         (agent-codex--rollout-header-cache (make-hash-table :test #'equal))
         (ids (agent-codex-test--write-fork-family dir))
         (current (nth 2 ids))
         (buffer (generate-new-buffer " *codex-headers*")))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (setq default-directory (file-name-as-directory dir)))
          (cl-letf (((symbol-function 'codex-session-identity)
                     (lambda (&optional _buffer) (list :session-id current))))
            (let ((headers (agent-codex--session-headers buffer)))
              (should (gethash (nth 0 ids) headers))
              (should (gethash (nth 1 ids) headers))
              (should (gethash current headers))
              (should (gethash (nth 3 ids) headers))
              (should-not (gethash (nth 4 ids) headers)))))
      (kill-buffer buffer)
      (delete-directory dir t))))

(ert-deftest agent-codex-test-session-headers-family-matches-a-full-scan ()
  "Return the family a full scan of the store would have produced.
The bound is an optimization, so the tree the user navigates has to be
identical to the one an unbounded scan builds."
  (let* ((dir (make-temp-file "codex-sessions" t))
         (codex-transcript-sessions-directory dir)
         (codex--transcript-file-cache (make-hash-table :test #'equal))
         (agent-codex--rollout-header-cache (make-hash-table :test #'equal))
         (ids (agent-codex-test--write-fork-family dir))
         (current (nth 2 ids))
         (buffer (generate-new-buffer " *codex-headers*")))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (setq default-directory (file-name-as-directory dir)))
          (cl-letf (((symbol-function 'codex-session-identity)
                     (lambda (&optional _buffer) (list :session-id current))))
            (let ((bounded (agent-codex-test--branch-members
                            current (agent-codex--session-headers buffer)))
                  (full (agent-codex-test--branch-members
                         current
                         (agent-codex--scan-session-headers
                          (file-name-as-directory dir)))))
              (should (equal bounded full))
              (should (= (length bounded) 4)))))
      (kill-buffer buffer)
      (delete-directory dir t))))

(ert-deftest agent-codex-test-session-headers-survive-a-fork-cycle ()
  "Scan everything when the fork chain loops back into itself.
A corrupt `forked_from_id' can name a session further down its own
ancestry.  The climb has to stop, and a bound taken from inside the
loop could hide members older than the loop, so the scan widens."
  (let* ((dir (make-temp-file "codex-sessions" t))
         (codex-transcript-sessions-directory dir)
         (codex--transcript-file-cache (make-hash-table :test #'equal))
         (agent-codex--rollout-header-cache (make-hash-table :test #'equal))
         (current (agent-codex-test--session-id "aaa"))
         (parent (agent-codex-test--session-id "bbb"))
         (stranger (agent-codex-test--session-id "eee"))
         (buffer (generate-new-buffer " *codex-headers*")))
    (unwind-protect
        (progn
          (agent-codex-test--write-rollout
           dir current `((cwd . ,dir) (forked_from_id . ,parent))
           nil "2026-08-05T09-00-00")
          (agent-codex-test--write-rollout
           dir parent `((cwd . ,dir) (forked_from_id . ,current))
           nil "2026-08-05T08-00-00")
          (agent-codex-test--write-rollout
           dir stranger `((cwd . ,dir)) nil "2026-08-01T00-00-00")
          (with-current-buffer buffer
            (setq default-directory (file-name-as-directory dir)))
          (cl-letf (((symbol-function 'codex-session-identity)
                     (lambda (&optional _buffer) (list :session-id current))))
            (let ((headers (agent-codex--session-headers buffer)))
              (should (gethash current headers))
              (should (gethash parent headers))
              (should (gethash stranger headers)))))
      (kill-buffer buffer)
      (delete-directory dir t))))

(ert-deftest agent-codex-test-session-headers-unbounded-without-a-session-id ()
  "Scan everything when the buffer's own session id is not known yet.
A session that has not reported its id has no family to bound by, and
an empty branch tree would be worse than a slow one."
  (let* ((dir (make-temp-file "codex-sessions" t))
         (codex-transcript-sessions-directory dir)
         (codex--transcript-file-cache (make-hash-table :test #'equal))
         (agent-codex--rollout-header-cache (make-hash-table :test #'equal))
         (ids (agent-codex-test--write-fork-family dir))
         (buffer (generate-new-buffer " *codex-headers*")))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (setq default-directory (file-name-as-directory dir)))
          (cl-letf (((symbol-function 'codex-session-identity)
                     (lambda (&optional _buffer) nil)))
            (let ((headers (agent-codex--session-headers buffer)))
              (should (= (hash-table-count headers) 5))
              (should (gethash (nth 4 ids) headers)))))
      (kill-buffer buffer)
      (delete-directory dir t))))

(ert-deftest agent-codex-test-session-headers-unbounded-when-an-ancestor-is-gone ()
  "Scan everything when an ancestor's rollout is missing from the store.
The missing ancestor's other children can have started before the
oldest session the climb could reach, so bounding there would drop real
family members."
  (let* ((dir (make-temp-file "codex-sessions" t))
         (codex-transcript-sessions-directory dir)
         (codex--transcript-file-cache (make-hash-table :test #'equal))
         (agent-codex--rollout-header-cache (make-hash-table :test #'equal))
         (current (agent-codex-test--session-id "aaa"))
         (stranger (agent-codex-test--session-id "eee"))
         (buffer (generate-new-buffer " *codex-headers*")))
    (unwind-protect
        (progn
          (agent-codex-test--write-rollout
           dir current
           `((cwd . ,dir)
             (forked_from_id . ,(agent-codex-test--session-id "fff")))
           nil "2026-08-05T09-00-00")
          (agent-codex-test--write-rollout
           dir stranger `((cwd . ,dir)) nil "2026-08-01T00-00-00")
          (with-current-buffer buffer
            (setq default-directory (file-name-as-directory dir)))
          (cl-letf (((symbol-function 'codex-session-identity)
                     (lambda (&optional _buffer) (list :session-id current))))
            (let ((headers (agent-codex--session-headers buffer)))
              (should (gethash current headers))
              (should (gethash stranger headers)))))
      (kill-buffer buffer)
      (delete-directory dir t))))

;;;; Header cache

(ert-deftest agent-codex-test-session-header-parsed-once-per-file ()
  "Parse a rollout's opening record once while the file stays unchanged.
A second branch command in the same family must cost a stat per file,
not a read and a JSON parse."
  (let* ((dir (make-temp-file "codex-sessions" t))
         (codex-transcript-sessions-directory dir)
         (agent-codex--rollout-header-cache (make-hash-table :test #'equal))
         (id (agent-codex-test--session-id "aaa")))
    (unwind-protect
        (progn
          (agent-codex-test--write-rollout dir id `((cwd . ,dir)))
          (should (gethash id (agent-codex--scan-session-headers dir)))
          (cl-letf (((symbol-function 'agent-codex--read-first-line)
                     (lambda (&rest _)
                       (error "an unchanged rollout must not be re-read"))))
            (should (gethash id (agent-codex--scan-session-headers dir)))))
      (delete-directory dir t))))

(ert-deftest agent-codex-test-session-header-reparsed-when-the-file-changes ()
  "Re-read a rollout whose modification time has moved on.
A running session appends to its rollout, and a resumed one can gain a
fork parent, so a cache that never expires would serve a stale tree."
  (let* ((dir (make-temp-file "codex-sessions" t))
         (codex-transcript-sessions-directory dir)
         (agent-codex--rollout-header-cache (make-hash-table :test #'equal))
         (id (agent-codex-test--session-id "aaa"))
         (parent (agent-codex-test--session-id "bbb")))
    (unwind-protect
        (let ((file (agent-codex-test--write-rollout dir id `((cwd . ,dir)))))
          (should-not (plist-get (gethash id (agent-codex--scan-session-headers
                                              dir))
                                 :forked-from))
          (agent-codex-test--write-rollout
           dir id `((cwd . ,dir) (forked_from_id . ,parent)))
          (set-file-times file (encode-time 0 0 12 1 1 2030))
          (should (equal (plist-get (gethash id
                                             (agent-codex--scan-session-headers
                                              dir))
                                    :forked-from)
                         parent)))
      (delete-directory dir t))))

(ert-deftest agent-codex-test-session-header-cache-stays-bounded ()
  "Drop the cached headers once the table outgrows its limit.
A scan of a large store caches thousands of entries, and an Emacs
session that never restarts would otherwise keep every one of them."
  (let* ((dir (make-temp-file "codex-sessions" t))
         (codex-transcript-sessions-directory dir)
         (agent-codex--rollout-header-cache (make-hash-table :test #'equal))
         (agent-codex--rollout-header-cache-limit 1))
    (unwind-protect
        (progn
          (dolist (suffix '("aaa" "bbb" "ccc"))
            (agent-codex-test--write-rollout
             dir (agent-codex-test--session-id suffix) `((cwd . ,dir))))
          (should (= (hash-table-count (agent-codex--scan-session-headers dir))
                     3))
          (should (> (hash-table-count agent-codex--rollout-header-cache) 0))
          (should (<= (hash-table-count agent-codex--rollout-header-cache)
                      (1+ agent-codex--rollout-header-cache-limit))))
      (delete-directory dir t))))

(ert-deftest agent-codex-test-first-user-prompt-skips-injected-messages ()
  "Return the first human prompt, not the instructions Codex injects."
  (let* ((root (make-temp-file "codex-sessions" t))
         (codex-transcript-sessions-directory root)
         (file (agent-codex-test--write-rollout
                root "019fd19c-44b9-7042-93b6-e4f7e21036ad"
                '((cwd . "/tmp/mine"))
                (list
                 (json-encode
                  '((type . "response_item")
                    (payload . ((type . "message") (role . "user")
                                (content . [((type . "input_text")
                                             (text . "# AGENTS.md instructions for /x"))])))))
                 (json-encode
                  '((type . "response_item")
                    (payload . ((type . "message") (role . "user")
                                (content . [((type . "input_text")
                                             (text . "Fix the failing test"))])))))))))
    (unwind-protect
        (should (equal (agent-codex--first-user-prompt file)
                       "Fix the failing test"))
      (delete-directory root t))))

(ert-deftest agent-codex-test-session-prompt-falls-back-to-no-prompt ()
  "Render a session with no human message as `(no prompt)'."
  (let* ((root (make-temp-file "codex-sessions" t))
         (codex-transcript-sessions-directory root)
         (file (agent-codex-test--write-rollout
                root "019fd19c-44b9-7042-93b6-e4f7e21036ad"
                '((cwd . "/tmp/mine"))))
         (header (list :session-id "019fd19c-44b9-7042-93b6-e4f7e21036ad"
                       :forked-from nil :file-path file)))
    (unwind-protect
        (let ((enriched (agent-codex--session-prompt header)))
          (should (equal (plist-get enriched :first-prompt) "(no prompt)"))
          (should (equal (plist-get enriched :session-id)
                         "019fd19c-44b9-7042-93b6-e4f7e21036ad")))
      (delete-directory root t))))

;;;; Minor mode

(ert-deftest agent-codex-test-snippet-start-hook-function-is-autoloaded ()
  "Source-loaded Codex hooks reference an available snippet command."
  (should (memq 'agent-setup-scroll-keys
                agent-codex--start-hook-functions))
  (should (fboundp 'agent-setup-scroll-keys))
  (should (memq 'agent-setup-snippet-keys
                agent-codex--start-hook-functions))
  (should (fboundp 'agent-setup-snippet-keys)))

(ert-deftest agent-codex-test-mode-symmetric ()
  "Enabling then disabling the mode leaves global state untouched."
  (let ((codex-notification-function #'ignore)
        (codex-start-hook nil)
        (codex-event-hook nil)
        (codex-command-submitted-hook nil)
        (codex-process-environment-functions nil)
        (agent-scroll-keys-global-mode nil)
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
    (should agent-scroll-keys-global-mode)
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
    (should-not agent-scroll-keys-global-mode)
    (should-not (advice-member-p #'agent-codex--intercept-exit
                                 'codex--do-send-command))
    (should-not (advice-member-p #'agent-codex--intercept-exit-to-buffer
                                 'codex--send-command-to-buffer))))

(provide 'agent-codex-test)
;;; agent-codex-test.el ends here
