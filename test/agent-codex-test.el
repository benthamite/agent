;;; agent-codex-test.el --- Tests for agent-codex -*- lexical-binding: t -*-

;; Tests for pure and near-pure helper functions in agent-codex.el.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'agent-codex)

;;;; Account selection

(ert-deftest agent-codex-test-handoff-file-default-matches-skill ()
  "Use the path written by the Codex `/handoff' skill."
  (should (equal agent-codex-handoff-file "/tmp/codex-handoff.md")))

(ert-deftest agent-codex-test-shared-config-items-use-agents-md ()
  "Share the actual Codex instruction filename across account homes."
  (should (member "AGENTS.md" agent-codex--shared-config-items))
  (should-not (member "AGENT.md" agent-codex--shared-config-items)))

(ert-deftest agent-codex-test-account-env-uses-pending-account ()
  "Set CODEX_HOME from the dynamically bound pending account."
  (let* ((dir (make-temp-file "codex-account" t))
         (home (expand-file-name "work" dir))
         (canonical (expand-file-name ".codex" dir))
         (process-environment (cons (format "HOME=%s" dir)
                                    process-environment))
         (agent-codex-accounts `(("work" . ,home)))
         (agent-codex--pending-account "work"))
    (unwind-protect
        (progn
          (make-directory canonical t)
          (with-temp-file (expand-file-name "config.toml" canonical)
            (insert "model = \"gpt-5.5\"\n"))
          (should (equal (agent-codex-account-env "*codex*" dir)
                         (list (format "CODEX_HOME=%s" home)))))
      (delete-directory dir t))))

(ert-deftest agent-codex-test-account-env-symlinks-shared-state ()
  "Share hooks, skills, and history from the canonical Codex home."
  (let* ((dir (make-temp-file "codex-account" t))
         (home (expand-file-name "work" dir))
         (canonical (expand-file-name ".codex" dir))
         (process-environment (cons (format "HOME=%s" dir)
                                    process-environment))
         (agent-codex-accounts `(("work" . ,home)))
         (agent-codex--pending-account "work"))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "skills" canonical) t)
          (with-temp-file (expand-file-name "hooks.json" canonical)
            (insert "{}\n"))
          (with-temp-file (expand-file-name "history.jsonl" canonical)
            (insert "{\"text\":\"old chat\"}\n"))
          (agent-codex-account-env "*codex*" dir)
          (dolist (item '("hooks.json" "history.jsonl" "skills"))
            (let ((target (expand-file-name item home))
                  (source (expand-file-name item canonical)))
              (should (file-symlink-p target))
              (should (equal (file-truename target)
                             (file-truename source))))))
      (delete-directory dir t))))

(ert-deftest agent-codex-test-account-env-backs-up-conflicting-state ()
  "Back up account-local shared state before linking canonical state."
  (let* ((dir (make-temp-file "codex-account" t))
         (home (expand-file-name "work" dir))
         (canonical (expand-file-name ".codex" dir))
         (process-environment (cons (format "HOME=%s" dir)
                                    process-environment))
         (agent-codex-accounts `(("work" . ,home)))
         (agent-codex--pending-account "work"))
    (unwind-protect
        (progn
          (make-directory home t)
          (make-directory canonical t)
          (with-temp-file (expand-file-name "history.jsonl" canonical)
            (insert "{\"text\":\"canonical\"}\n"))
          (with-temp-file (expand-file-name "history.jsonl" home)
            (insert "{\"text\":\"account-local\"}\n"))
          (agent-codex-account-env "*codex*" dir)
          (let ((target (expand-file-name "history.jsonl" home))
                (backups (file-expand-wildcards
                          (expand-file-name
                           "history.jsonl.agent-backup-*" home))))
            (should (file-symlink-p target))
            (should (equal (length backups) 1))
            (with-temp-buffer
              (insert-file-contents (car backups))
              (should (string-match-p "account-local" (buffer-string))))))
      (delete-directory dir t))))

(ert-deftest agent-codex-test-load-account-ignores-stale-selection ()
  "Ignore account-file contents not present in configured accounts."
  (let* ((dir (make-temp-file "codex-account" t))
         (file (expand-file-name "current" dir))
         (agent-codex-account-file file)
         (agent-codex-accounts `(("work" . ,(expand-file-name "work" dir)))))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "missing\n"))
          (should-not (agent-codex--load-account)))
      (delete-directory dir t))))

(ert-deftest agent-codex-test-read-config-model-uses-account-home ()
  "Read model configuration from the selected account's CODEX_HOME."
  (let* ((dir (make-temp-file "codex-account" t))
         (home (expand-file-name "work" dir))
         (config (expand-file-name "config.toml" home))
         (agent-codex-accounts `(("work" . ,home)))
         (agent-codex--config-model-cache nil))
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
         (agent-codex--config-model-cache nil))
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
        captured-account)
    (unwind-protect
        (with-temp-buffer
          (rename-buffer "*codex:~/project/:default*" t)
          (setq-local codex--session-id "019ea295-c3df-70b0-a8e5-a8ffe9df220a")
          (setq-local agent-codex--buffer-account "work")
          (let ((agent-codex-accounts
                 `(("work" . ,(expand-file-name "work" dir))))
                (agent-codex--current-account nil)
                (agent-codex-account-file (expand-file-name "current" dir)))
            (cl-letf (((symbol-function 'codex--buffer-p) (lambda (_buffer) t))
                      ((symbol-function 'agent--force-kill-buffer) #'ignore)
                      ((symbol-function 'agent-codex--resolve-account)
                       (lambda () (error "should not resolve active account")))
                      ((symbol-function 'codex--directory)
                       (lambda () default-directory))
                      ((symbol-function 'codex--app-server-launch-resume-session)
                       (lambda (&rest _)
                         (setq captured-account agent-codex--pending-account))))
              (agent-codex-restart))))
      (delete-directory dir t))
    (should (equal captured-account "work"))))

(ert-deftest agent-codex-test-restart-prompts-when-active-account-differs ()
  "Restart Codex with the selected account when the user chooses it."
  (let ((dir (make-temp-file "codex-restart" t))
        captured-account prompt-choices)
    (unwind-protect
        (with-temp-buffer
          (rename-buffer "*codex:~/project/:default*" t)
          (setq-local codex--session-id "019ea295-c3df-70b0-a8e5-a8ffe9df220a")
          (setq-local agent-codex--buffer-account "work")
          (let ((agent-codex-accounts
                 `(("work" . ,(expand-file-name "work" dir))
                   ("personal" . ,(expand-file-name "personal" dir))))
                (agent-codex--current-account "personal"))
            (cl-letf (((symbol-function 'codex--buffer-p) (lambda (_buffer) t))
                      ((symbol-function 'agent--force-kill-buffer) #'ignore)
                      ((symbol-function 'codex--directory)
                       (lambda () default-directory))
                      ((symbol-function 'completing-read)
                       (lambda (_prompt choices &rest _args)
                         (setq prompt-choices choices)
                         "personal"))
                      ((symbol-function 'codex--app-server-launch-resume-session)
                       (lambda (&rest _)
                         (setq captured-account agent-codex--pending-account))))
              (agent-codex-restart))))
      (delete-directory dir t))
    (should (equal prompt-choices '("personal" "work")))
    (should (equal captured-account "personal"))))

(ert-deftest agent-codex-test-restart-fails-when-active-account-is-missing ()
  "Do not fall back to the session account when the selected account is stale."
  (let ((dir (make-temp-file "codex-restart" t))
        killed started)
    (unwind-protect
        (with-temp-buffer
          (rename-buffer "*codex:~/project/:default*" t)
          (setq-local codex--session-id "019ea295-c3df-70b0-a8e5-a8ffe9df220a")
          (setq-local agent-codex--buffer-account "work")
          (let ((agent-codex-accounts
                 `(("work" . ,(expand-file-name "work" dir))))
                (agent-codex--current-account "personal"))
            (cl-letf (((symbol-function 'codex--buffer-p) (lambda (_buffer) t))
                      ((symbol-function 'agent--force-kill-buffer)
                       (lambda (_buffer) (setq killed t)))
                      ((symbol-function 'codex--app-server-launch-resume-session)
                       (lambda (&rest _args) (setq started t))))
              (should-error (agent-codex-restart) :type 'user-error))))
      (delete-directory dir t))
    (should-not killed)
    (should-not started)))

(ert-deftest agent-codex-test-restart-resumes-current-session-id-with-app-server ()
  "Restart Codex with the session id attached to the current buffer."
  (let (captured-session-id captured-instance-name)
    (with-temp-buffer
      (rename-buffer "*codex:~/project/:default*" t)
      (setq-local codex--session-id "019ea295-c3df-70b0-a8e5-a8ffe9df220a")
      (cl-letf (((symbol-function 'codex--buffer-p) (lambda (_buffer) t))
                ((symbol-function 'agent--force-kill-buffer) #'ignore)
                ((symbol-function 'agent-codex--resolve-account) (lambda () nil))
                ((symbol-function 'codex--directory) (lambda () default-directory))
                ((symbol-function 'codex--app-server-launch-resume-session)
                 (lambda (session-id instance-name)
                   (setq captured-session-id session-id)
                   (setq captured-instance-name instance-name))))
        (agent-codex-restart)))
    (should (equal captured-session-id
                   "019ea295-c3df-70b0-a8e5-a8ffe9df220a"))
    (should (equal captured-instance-name "default"))))

(ert-deftest agent-codex-test-restart-uses-codex-session-identity ()
  "Restart Codex through the canonical session identity resolver."
  (let (captured-session-id)
    (with-temp-buffer
      (rename-buffer "*codex:~/project/:default*" t)
      (setq-local codex--session-id nil)
      (setq-local codex--app-server-thread-id nil)
      (cl-letf (((symbol-function 'codex--buffer-p) (lambda (_buffer) t))
                ((symbol-function 'agent--force-kill-buffer) #'ignore)
                ((symbol-function 'agent-codex--resolve-account) (lambda () nil))
                ((symbol-function 'codex--directory) (lambda () default-directory))
                ((symbol-function 'codex--current-session-identity)
                 (lambda ()
                   '(:id "019eada4-ebff-7721-9df6-642202f1138f"
                     :transcript-file "/tmp/session.jsonl")))
                ((symbol-function 'codex--app-server-launch-resume-session)
                 (lambda (session-id _instance-name)
                   (setq captured-session-id session-id))))
        (agent-codex-restart)))
    (should (equal captured-session-id
                   "019eada4-ebff-7721-9df6-642202f1138f"))))

(ert-deftest agent-codex-test-restart-without-session-identity-does-not-kill ()
  "Restart refuses to kill the current buffer without session identity."
  (let (killed started)
    (with-temp-buffer
      (rename-buffer "*codex:~/project/:default*" t)
      (cl-letf (((symbol-function 'codex--buffer-p) (lambda (_buffer) t))
                ((symbol-function 'agent--force-kill-buffer)
                 (lambda (_buffer) (setq killed t)))
                ((symbol-function 'agent-codex--resolve-account) (lambda () nil))
                ((symbol-function 'codex--current-session-identity)
                 (lambda () nil))
                ((symbol-function 'codex--app-server-launch-resume-session)
                 (lambda (&rest _args) (setq started t))))
        (should-error (agent-codex-restart) :type 'user-error)))
    (should-not killed)
    (should-not started)))

(ert-deftest agent-codex-test-restart-uses-default-backend-option ()
  "Restart uses the configured default backend for the new session."
  (let ((codex-terminal-backend 'eat)
        (other (generate-new-buffer "agent-codex-post-kill"))
        app-server-called
        terminal-called)
    (unwind-protect
        (let ((old-default (default-value 'codex-terminal-backend)))
          (unwind-protect
              (progn
                (setq-default codex-terminal-backend 'app-server)
                (with-temp-buffer
                  (rename-buffer "*codex:~/project/:default*" t)
                  (setq-local codex-terminal-backend 'eat)
                  (setq-local codex--session-id
                              "019ea295-c3df-70b0-a8e5-a8ffe9df220a")
                  (cl-letf (((symbol-function 'codex--buffer-p)
                             (lambda (_buffer) t))
                            ((symbol-function 'agent--force-kill-buffer)
                             (lambda (_buffer) (set-buffer other)))
                            ((symbol-function 'agent-codex--resolve-account)
                             (lambda () nil))
                            ((symbol-function 'codex--directory)
                             (lambda () default-directory))
                            ((symbol-function
                              'codex--app-server-launch-resume-session)
                             (lambda (&rest _args)
                               (setq app-server-called t)))
                            ((symbol-function 'codex--start-subcommand)
                             (lambda (&rest _args)
                               (setq terminal-called t))))
                    (agent-codex-restart))))
            (setq-default codex-terminal-backend old-default)))
      (kill-buffer other))
    (should app-server-called)
    (should-not terminal-called)))

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
          (let ((agent-codex-handoff-file handoff-file))
            (cl-letf (((symbol-function 'agent-codex--handoff-source-buffer)
                       (lambda (_buffer-name) nil))
                      ((symbol-function 'agent-codex--handoff-directory)
                       (lambda (_source-buffer) dir))
                      ((symbol-function 'agent-codex--resolve-account)
                       (lambda () nil))
                      ((symbol-function 'agent-codex--install-hooks)
                       #'ignore)
                      ((symbol-function 'codex--find-codex-buffers-for-directory)
                       (lambda (_dir) (list existing)))
                      ((symbol-function 'codex--buffer-instance-name-for)
                       (lambda (_buffer) "default"))
                      ((symbol-function 'agent--force-kill-buffer)
                       (lambda (buffer) (push buffer killed)))
                      ((symbol-function 'codex--start)
                       (lambda (&rest _args) (setq started t))))
              (agent-codex-handoff)
              (should (equal killed (list existing)))
              (should started))))
      (when (buffer-live-p existing)
        (kill-buffer existing))
      (delete-directory dir t))))

(ert-deftest agent-codex-test-start-with-account-installs-start-hook ()
  "Install Codex start hooks before launching sessions."
  (let ((codex-start-hook nil)
        (agent-codex-accounts '(("work" . "/tmp/codex-work"))))
    (cl-letf (((symbol-function 'agent-codex--resolve-account)
               (lambda () "work"))
              ((symbol-function 'codex)
               (lambda ()
                 (should (memq #'agent-codex--record-start-time
                               codex-start-hook)))))
      (agent-codex--start-with-account))))

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

(ert-deftest agent-codex-test-send-return-clears-waiting-flag ()
  "Clear stale waiting state when submitting the current Codex prompt."
  (with-temp-buffer
    (setq-local agent--waiting-for-input (current-time))
    (cl-letf (((symbol-function 'codex--term-send-action) #'ignore)
              ((symbol-function 'display-buffer) #'ignore))
      (agent-codex-send-return (current-buffer)))
    (should-not agent--waiting-for-input)))

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

(ert-deftest agent-codex-test-target-buffer-submit-clears-waiting-flag ()
  "Clear stale waiting state in the target Codex buffer."
  (with-temp-buffer
    (let ((buf (current-buffer)))
      (setq-local agent--waiting-for-input (current-time))
      (agent-codex--clear-waiting-before-send-command-to-buffer "prompt" buf)
      (should-not agent--waiting-for-input))))

;;;; Slack message action routing

(ert-deftest agent-codex-test-act-on-slack-message-inserts-url-for-review ()
  "Start Codex without an initial prompt and insert the Slack URL."
  (let ((project '(:id "project" :directory "/tmp/project"))
        (url "https://example.slack.com/archives/C1/p123")
        (buffer (generate-new-buffer " *codex-test*"))
        started
        sent
        launch-directory)
    (unwind-protect
        (cl-letf (((symbol-function 'agent-codex--install-hooks) #'ignore)
                  ((symbol-function 'codex--start)
                   (lambda (arg extra-switches force-prompt force-switch-to-buffer)
                     (setq started
                           (list arg extra-switches force-prompt
                                 force-switch-to-buffer
                                 (codex--directory)))
                     (setq launch-directory default-directory)
                     buffer))
                  ((symbol-function 'agent-codex-send-command)
                   (lambda (cmd target)
                     (setq sent (list cmd target))
                     target)))
          (should (eq (agent-codex--act-on-slack-message-start-session
                       project url)
                      buffer))
          (should (equal started
                         (list nil nil nil t "/tmp/project/")))
          (should (equal launch-directory "/tmp/project/"))
          (should (equal sent (list url buffer))))
      (kill-buffer buffer))))

(ert-deftest agent-codex-test-before-exit-ready-vetoes-pending-prompt ()
  "Do not auto-close while Codex still has prompt input."
  (let ((buf (generate-new-buffer "*codex-test*")))
    (unwind-protect
        (with-current-buffer buf
          (insert "› $session-learning-capture\n\n  gpt-5.5 medium · /tmp")
          (should-not (agent-codex-before-exit-ready-to-close-p buf)))
      (kill-buffer buf))))

(ert-deftest agent-codex-test-before-exit-ready-allows-empty-prompt ()
  "Allow auto-close when Codex is back at an empty prompt."
  (let ((buf (generate-new-buffer "*codex-test*")))
    (unwind-protect
        (with-current-buffer buf
          (insert "› \n\n  gpt-5.5 medium · /tmp")
          (should (agent-codex-before-exit-ready-to-close-p buf)))
      (kill-buffer buf))))

(ert-deftest agent-codex-test-before-exit-ready-ignores-submitted-command ()
  "Allow auto-close when the skill command is scrollback, not prompt input."
  (let ((buf (generate-new-buffer "*codex-test*")))
    (unwind-protect
        (cl-letf (((symbol-function 'codex--terminal-cursor-position)
                   (lambda () (point-max))))
          (with-current-buffer buf
            (insert "› $session-learning-capture\n\n  gpt-5.5 medium · /tmp")
            (should (agent-codex-before-exit-ready-to-close-p buf))))
      (kill-buffer buf))))

(ert-deftest agent-codex-test-before-exit-ready-ignores-autosuggestion ()
  "Allow auto-close when Codex shows placeholder prompt text."
  (let ((buf (generate-new-buffer "*codex-test*")))
    (unwind-protect
        (cl-letf (((symbol-function 'codex--known-prompt-autosuggestion-p)
                   (lambda (input)
                     (string= input "Summarize recent commits"))))
          (with-current-buffer buf
            (insert "› Summarize recent commits\n\n  gpt-5.5 medium · /tmp")
            (should (agent-codex-before-exit-ready-to-close-p buf))))
      (kill-buffer buf))))

(ert-deftest agent-codex-test-before-exit-ready-vetoes-pending-heavy-prompt ()
  "Veto auto-close when the `❯'-rendered Codex prompt has pending input."
  (let ((buf (generate-new-buffer "*codex-test*")))
    (unwind-protect
        (with-current-buffer buf
          (insert "❯ git status\n\n  gpt-5.5 medium · /tmp")
          (should-not (agent-codex-before-exit-ready-to-close-p buf)))
      (kill-buffer buf))))

(ert-deftest agent-codex-test-before-exit-ready-ignores-stale-heavy-prompt-echo ()
  "Allow auto-close at an empty `❯' prompt despite a stale `›' echo above it."
  (let ((buf (generate-new-buffer "*codex-test*")))
    (unwind-protect
        (with-current-buffer buf
          (insert "› $session-learning-capture\n\n❯ \n\n  gpt-5.5 medium · /tmp")
          (should (agent-codex-before-exit-ready-to-close-p buf)))
      (kill-buffer buf))))

(ert-deftest agent-codex-test-stop-closes-after-submitted-before-exit-skill ()
  "Close a pending before-exit session when the submitted skill finishes."
  (let ((buf (generate-new-buffer "*codex:/tmp/project/*"))
        ran)
    (unwind-protect
        (cl-letf (((symbol-function 'codex--terminal-cursor-position)
                   (lambda () (point-max)))
                  ((symbol-function 'run-at-time)
                   (lambda (_time _repeat function &rest args)
                     (apply function args)))
                  ((symbol-function 'agent-codex-exit)
                   (lambda () (interactive) (setq ran t))))
          (with-current-buffer buf
            (setq-local agent--before-exit-skill-exit-pending t)
            (insert "› $session-learning-capture\n\n  gpt-5.5 medium · /tmp"))
          (agent-codex--handle-notification
           (list :type "Stop" :buffer-name (buffer-name buf)))
          (should ran)
          (with-current-buffer buf
            (should-not agent--before-exit-skill-exit-pending)))
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
  "Do not render stale Codex waiting flags while Codex is working."
  (let ((buf (generate-new-buffer "*codex-test*")))
    (unwind-protect
        (with-current-buffer buf
          (setq-local agent--waiting-for-input (current-time))
          (insert "• Working (20m 58s • esc to interrupt)\n")
          (should-not (agent--session-waiting-p buf 'codex)))
      (kill-buffer buf))))

(ert-deftest agent-codex-test-app-server-active-turn-is-not-waiting ()
  "Do not render stale Codex waiting flags during app-server turns."
  (let ((buf (generate-new-buffer "*codex-test*")))
    (unwind-protect
        (with-current-buffer buf
          (setq-local agent--waiting-for-input (current-time))
          (setq-local codex--app-server-turn-active-p t)
          (should-not (agent--session-waiting-p buf 'codex)))
      (kill-buffer buf))))

(ert-deftest agent-codex-test-waiting-face-uses-background-work ()
  "Show Codex waiting sessions with background work as background-work."
  (let ((buf (generate-new-buffer "*codex-test*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (insert "• Working (13m 19s) · 2 background terminals running\n"))
          (should (eq (agent--waiting-face buf 'codex)
                      'agent-waiting-with-background)))
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

(ert-deftest agent-codex-test-sync-theme-uses-pending-account-home ()
  "Persist theme changes to the pending account's Codex config."
  (let* ((dir (make-temp-file "codex-theme" t))
         (home (expand-file-name "work" dir))
         (canonical (expand-file-name ".codex" dir))
         (config (expand-file-name "config.toml" home))
         (canonical-config (expand-file-name "config.toml" canonical))
         (process-environment (cons (format "HOME=%s" dir)
                                    process-environment))
         (agent-codex-accounts `(("work" . ,home)))
         (agent-codex--pending-account "work"))
    (unwind-protect
        (progn
          (make-directory canonical t)
          (with-temp-file canonical-config
            (insert "[tui]\ntheme = \"light\"\n"))
          (should (agent-codex--sync-theme "dark"))
          (should (file-symlink-p config))
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
          (let ((meta (agent-codex--parse-skill-frontmatter file)))
            (should (equal (plist-get meta :name) "proofread"))
            (should (equal (plist-get meta :argument-hint) "FILE"))
            (should (equal (plist-get meta :argument-source)
                           "references/*.org"))))
      (delete-file file))))

(ert-deftest agent-codex-test-discover-skills-skips-non-invocable ()
  "Do not expose Codex skills marked `user-invocable: false'."
  (let* ((dir (make-temp-file "codex-skills" t))
         (codex-home (make-temp-file "codex-home" t))
         (visible (expand-file-name "visible/SKILL.md" dir))
         (hidden (expand-file-name "hidden/SKILL.md" dir))
         (process-environment
          (cons (format "CODEX_HOME=%s" codex-home) process-environment))
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
                                 (agent-codex--discover-skills))
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
         (agent-codex--pending-account "work")
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
                                   (agent-codex--discover-skills))
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
         (agent-codex--pending-account "work")
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
                                   (agent-codex--discover-skills))
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
         (skill-file (expand-file-name "proofread/SKILL.md" dir))
         (agent-codex-skill-directories (list dir))
         captured-prompt
         captured-dir)
    (unwind-protect
        (progn
          (make-directory (file-name-directory skill-file) t)
          (with-temp-file skill-file
            (insert "---\nname: proofread\n---\nProofread the file.\n"))
          (cl-letf (((symbol-function 'agent-codex--run-prompt)
                     (lambda (prompt &rest kwargs)
                       (setq captured-prompt prompt
                             captured-dir (plist-get kwargs :dir))
                       (funcall (plist-get kwargs :callback)
                                '(:exit-code 0 :duration 0.1 :text "ok"))))
                    ((symbol-function 'agent-codex--display-result)
                     #'ignore))
            (agent-codex-run-skill "proofread" "file.org"))
          (should (string-match-p (regexp-quote skill-file) captured-prompt))
          (should (string-match-p "Arguments: file.org" captured-prompt))
          (should (equal captured-dir default-directory)))
      (delete-directory dir t))))

(provide 'agent-codex-test)
;;; agent-codex-test.el ends here
