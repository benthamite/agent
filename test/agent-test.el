;;; agent-test.el --- Tests for agent -*- lexical-binding: t -*-

;; Tests for pure and near-pure helper functions in agent.el.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'agent)

(defun agent-test--backend (&rest keys)
  "Return a minimal valid backend plist extended with KEYS."
  (append
   keys
   (list :buffer-p (lambda (_buffer) nil)
         :find-all-buffers (lambda () nil)
         :extract-instance-name (lambda (_buffer-name) nil)
         :start-new #'ignore
         :label "Test")))

;;;; Theme sync

(ert-deftest agent-test-sync-theme-dispatches-to-backends ()
  "Dispatch theme sync to all registered backend handlers."
  (let ((agent-backends nil)
        (seen nil))
    (apply #'agent-register-backend
     'one
     (agent-test--backend
      :sync-theme (lambda (theme) (push (cons 'one theme) seen))))
    (apply #'agent-register-backend
     'two
     (agent-test--backend
      :sync-theme (lambda (theme) (push (cons 'two theme) seen))))
    (cl-letf (((symbol-function 'frame-parameter)
               (lambda (_frame param)
                 (when (eq param 'background-mode) 'dark))))
      (agent--do-sync-theme t)
      (should (equal (sort seen (lambda (a b)
                                  (string< (symbol-name (car a))
                                           (symbol-name (car b)))))
                     '((one . "dark") (two . "dark")))))))

(ert-deftest agent-test-sync-theme-before-start-respects-toggle ()
  "Do not sync immediately when `agent-sync-theme' is disabled."
  (let ((agent-sync-theme nil)
        (called nil))
    (cl-letf (((symbol-function 'agent--do-sync-theme)
               (lambda () (setq called t))))
      (agent-sync-theme-now)
      (should-not called))))

;;;; Backend registration

(ert-deftest agent-test-register-backend-requires-session-keys ()
  "Reject backend registrations that are missing required keys."
  (let ((agent-backends nil))
    (should-error
     (apply #'agent-register-backend 'bad (list :buffer-p #'ignore)))))

(ert-deftest agent-test-act-on-slack-message-dispatches-new-backend-key ()
  "Dispatch Slack-message action routing through the renamed backend key."
  (let ((agent-backends nil)
        (called nil))
    (apply #'agent-register-backend
     'one
     (agent-test--backend
      :act-on-slack-message (lambda ()
                              (interactive)
                              (setq called t))))
    (agent-act-on-slack-message)
    (should called)))

;;;; Epoch project registry

(ert-deftest agent-test-gptel-response-text-accepts-final-response ()
  "Return final gptel response text unchanged."
  (should (equal (agent--gptel-response-text "agent, gptel") "agent, gptel")))

(ert-deftest agent-test-gptel-response-text-ignores-reasoning-event ()
  "Ignore gptel reasoning events sent before final response text."
  (should-not (agent--gptel-response-text '(reasoning . "thinking"))))

(ert-deftest agent-test-epoch-project-candidates-read-project-registry ()
  "Read candidates from the canonical project registry schema."
  (let* ((root (file-name-as-directory (make-temp-file "agent-projects" t)))
         (registry (expand-file-name "project_registry.json" root))
         (project-dir (expand-file-name "slack-emoji-to-asana" root))
         (repo-dir (expand-file-name "repo" project-dir))
         (agent-epoch-projects-root root)
         (agent-epoch-project-registry-file registry))
    (unwind-protect
        (progn
          (make-directory repo-dir t)
          (with-temp-file registry
            (insert (json-serialize
                     '((schema_version . 1)
                       (projects
                        . [((id . "slack-emoji-to-asana")
                             (title . "Slack Emoji To Asana")
                             (aliases . ["slack-emoji-to-asana"
                                         "slack emoji to asana"])
                             (browser_keywords . ["slack-emoji-to-asana"])
                             (project_doc_paths . [])
                             (repo_paths . ["slack-emoji-to-asana/repo"])
                             (slack_channels . []))])))))
          (let* ((projects (agent-epoch-project-candidates))
                 (project (cl-find "slack-emoji-to-asana" projects
                                   :key (lambda (item)
                                          (plist-get item :id))
                                   :test #'string=)))
            (should project)
            (should (equal (plist-get project :directory)
                           (file-name-as-directory project-dir)))
            (should (equal (plist-get project :repo)
                           "slack-emoji-to-asana/repo"))
            (should-not (plist-get project :doc))))
      (delete-directory root t))))

(ert-deftest agent-test-ordered-epoch-project-candidates-puts-model-first ()
  "Put model-selected project IDs before the remaining registry entries."
  (let* ((a (list :id "a"))
         (b (list :id "b"))
         (c (list :id "c")))
    (should (equal (agent--ordered-epoch-project-candidates
                    '("c" "missing" "a") (list a b c))
                   (list c a b)))))

;;;; Session keys and display names

(ert-deftest agent-test-session-name-handles-directory-without-trailing-slash ()
  "Extract the project name when the buffer directory lacks a trailing slash."
  (should (equal (agent--session-name
                  "*codex:~/My Drive/Epoch/projects/ai-access-management:default*")
                 "ai-access-management")))

(ert-deftest agent-test-session-name-standard ()
  "Extract the project name from a standard session buffer name."
  (should (equal (agent--session-name "*claude:~/path/to/project/:default*")
                 "project")))

(ert-deftest agent-test-session-name-named-instance ()
  "Extract the project name regardless of instance name."
  (should (equal (agent--session-name "*claude:~/repos/my-app/:worktree-1*")
                 "my-app")))

(ert-deftest agent-test-session-name-deep-path ()
  "Extract the project name from a deeply nested path."
  (should (equal (agent--session-name
                  "*claude:~/My Drive/repos/org/subdir/:main*")
                 "subdir")))

(ert-deftest agent-test-session-name-non-matching ()
  "Return the buffer name unchanged when it does not match the pattern."
  (should (equal (agent--session-name "*scratch*") "*scratch*")))

(ert-deftest agent-test-session-name-no-trailing-star ()
  "Return the buffer name unchanged when the trailing asterisk is missing."
  (should (equal (agent--session-name "*claude:~/path/to/project/:default")
                 "*claude:~/path/to/project/:default")))

(ert-deftest agent-test-ensure-session-keys-assigns-home-row-keys ()
  "Assign home-row keys to all active backend buffers."
  (let ((agent-backends nil)
        (agent--session-keys (make-hash-table :test 'eq)))
    (with-temp-buffer
      (rename-buffer "*one:~/repo/a/:default*" t)
      (let ((one (current-buffer)))
        (with-temp-buffer
          (rename-buffer "*one:~/repo/b/:default*" t)
          (let ((two (current-buffer)))
            (apply #'agent-register-backend
             'one
             (agent-test--backend
              :buffer-p (lambda (buf)
                          (string-prefix-p "*one:" (buffer-name buf)))
              :find-all-buffers (lambda () (list one two))))
            (agent--ensure-all-session-keys)
            (should (equal (gethash one agent--session-keys) "a"))
            (should (equal (gethash two agent--session-keys) "s"))))))))

(ert-deftest agent-test-display-name-appends-backend-suffix ()
  "Append backend display suffixes after the shared base name."
  (let ((agent-backends nil)
        (agent--session-keys (make-hash-table :test 'eq)))
    (with-temp-buffer
      (rename-buffer "*one:~/repo/project/:default*" t)
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :find-all-buffers (lambda () (list buf))
          :display-name-suffix (lambda (_buffer) "branch")))
        (should (equal (agent-display-name buf) "project:branch"))))))

(ert-deftest agent-test-session-groups-use-account-key ()
  "Group session switcher suffixes by backend account."
  (let ((agent-backends nil)
        (agent--session-keys (make-hash-table :test 'eq)))
    (with-temp-buffer
      (rename-buffer "*one:~/repo/a/:default*" t)
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :find-all-buffers (lambda () (list buf))
          :account (lambda (_buffer) "work")))
        (puthash buf "a" agent--session-keys)
        (should (equal (mapcar #'car (agent--group-sessions-by-account))
                       '("work")))))))

(ert-deftest agent-test-waiting-face-detects-background-work ()
  "Use the background-work face when the backend reports work."
  (let ((agent-backends nil))
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :find-all-buffers (lambda () (list buf))
          :background-tasks-p (lambda (_buffer) t)))
        (should (eq (agent--waiting-face buf 'one)
                    'agent-waiting-with-background))))))

;;;; Skills

(ert-deftest agent-test-run-skill-distinguishes-backends ()
  "Run the selected backend skill when names collide."
  (let ((agent-backends nil)
        (ran nil))
    (apply #'agent-register-backend
     'one
     (agent-test--backend
      :label "One"
      :discover-skills (lambda () (list (list :name "audit")))
      :run-skill (lambda (name args) (setq ran (list 'one name args)))))
    (apply #'agent-register-backend
     'two
     (agent-test--backend
      :label "Two"
      :discover-skills (lambda () (list (list :name "audit")))
      :run-skill (lambda (name args) (setq ran (list 'two name args)))))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _args) "audit [Two]")))
      (agent-run-skill)
      (should (equal ran '(two "audit" nil))))))

(ert-deftest agent-test-post-push-ci-runs-skill-for-head ()
  "Run post-push CI through the selected backend with the current HEAD."
  (let ((agent-backends nil)
        ran)
    (apply #'agent-register-backend
     'one
     (agent-test--backend
      :run-skill (lambda (name args) (setq ran (list name args)))))
    (cl-letf (((symbol-function 'process-file)
               (lambda (&rest _args)
                 (insert "abc123\n")
                 0)))
      (agent-post-push-ci)
      (should (equal ran '("post-push-ci" "--no-push --commit abc123"))))))

(ert-deftest agent-test-force-kill-buffer-ignores-query-functions ()
  "Kill buffers even when unrelated query functions would veto it."
  (let ((buf (generate-new-buffer "agent-force-kill-test")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (add-hook 'kill-buffer-query-functions (lambda () nil) nil t))
          (agent--force-kill-buffer buf)
          (should-not (buffer-live-p buf)))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest agent-test-exit-runs-before-exit-functions ()
  "Abort exit when a before-exit function returns nil."
  (let ((agent-backends nil)
        (agent-before-exit-functions nil)
        ran
        seen)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :exit (lambda () (interactive) (setq ran t))))
        (add-hook 'agent-before-exit-functions
                  (lambda (backend buffer)
                    (setq seen (list backend buffer))
                    nil))
        (agent-exit)
        (should (equal seen (list 'one buf)))
        (should-not ran)))))

(ert-deftest agent-test-exit-proceeds-after-before-exit-functions ()
  "Exit when every before-exit function returns non-nil."
  (let ((agent-backends nil)
        (agent-before-exit-functions nil)
        ran)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :exit (lambda () (interactive) (setq ran t))))
        (add-hook 'agent-before-exit-functions (lambda (_backend _buffer) t))
        (agent-exit)
        (should ran)))))

(ert-deftest agent-test-exit-confirms-when-captured-prompts-pending ()
  "Abort exit when pending captured prompts exist and confirmation is declined."
  (let ((agent-backends nil)
        (agent-before-exit-functions nil)
        (agent-prompt-capture-directory (make-temp-file "agent-prompts" t))
        prompted
        ran)
    (unwind-protect
        (with-temp-buffer
          (rename-buffer "*one:~/repo/project/:default*" t)
          (let ((buf (current-buffer)))
            (apply #'agent-register-backend
             'one
             (agent-test--backend
              :buffer-p (lambda (candidate) (eq candidate buf))
              :exit (lambda () (interactive) (setq ran t))))
            (let ((file (agent--prompt-capture-file 'one buf)))
              (make-directory (file-name-directory file) t)
              (with-temp-file file
                (insert "* Prompt A\n\nAlpha\n")))
            (cl-letf (((symbol-function 'yes-or-no-p)
                       (lambda (prompt)
                         (setq prompted prompt)
                         nil)))
              (agent-exit))
            (should (string-match-p "1 captured prompt" prompted))
            (should-not ran)))
      (delete-directory agent-prompt-capture-directory t))))

(ert-deftest agent-test-exit-skips-capture-confirmation-without-prompts ()
  "Do not prompt for capture confirmation when no captured prompts exist."
  (let ((agent-backends nil)
        (agent-before-exit-functions nil)
        (agent-prompt-capture-directory (make-temp-file "agent-prompts" t))
        prompted
        ran)
    (unwind-protect
        (with-temp-buffer
          (rename-buffer "*one:~/repo/project/:default*" t)
          (let ((buf (current-buffer)))
            (apply #'agent-register-backend
             'one
             (agent-test--backend
              :buffer-p (lambda (candidate) (eq candidate buf))
              :exit (lambda () (interactive) (setq ran t))))
            (cl-letf (((symbol-function 'yes-or-no-p)
                       (lambda (_prompt)
                         (setq prompted t)
                         nil)))
              (agent-exit))
            (should-not prompted)
            (should ran)))
      (delete-directory agent-prompt-capture-directory t))))

(ert-deftest agent-test-restart-confirms-when-captured-prompts-pending ()
  "Abort restart when pending captures exist and confirmation is declined."
  (let ((agent-backends nil)
        (agent-prompt-capture-directory (make-temp-file "agent-prompts" t))
        prompted
        ran)
    (unwind-protect
        (with-temp-buffer
          (rename-buffer "*one:~/repo/project/:default*" t)
          (let ((buf (current-buffer)))
            (apply #'agent-register-backend
             'one
             (agent-test--backend
              :buffer-p (lambda (candidate) (eq candidate buf))
              :restart (lambda () (interactive) (setq ran t))))
            (let ((file (agent--prompt-capture-file 'one buf)))
              (make-directory (file-name-directory file) t)
              (with-temp-file file
                (insert "* Prompt A\n\nAlpha\n")))
            (cl-letf (((symbol-function 'yes-or-no-p)
                       (lambda (prompt)
                         (setq prompted prompt)
                         nil)))
              (agent-restart))
            (should (string-match-p "1 captured prompt" prompted))
            (should-not ran)))
      (delete-directory agent-prompt-capture-directory t))))

(ert-deftest agent-test-run-skill-before-exit-submits-codex-skill ()
  "Submit a Codex skill and abort the first exit globally by default."
  (let ((agent-backends nil)
        (agent-before-exit-skill-name "session-retro")
        (agent-before-exit-skill-directories nil)
        events)
    (with-temp-buffer
      (let ((buf (current-buffer))
            (agent-before-exit-skill-directories nil))
        (apply #'agent-register-backend
         'codex
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :send-command (lambda (cmd &optional _buffer)
                          (push (list 'command cmd) events))
          :send-return (lambda (&optional _buffer) (push 'return events))))
        (should-not (agent-run-skill-before-exit 'codex buf))
        (should (equal (nreverse events)
                       '((command "$session-retro") return)))
        (should agent--before-exit-skill-started)
        (should agent--before-exit-skill-exit-pending)
        (should (agent-run-skill-before-exit 'codex buf))))))

(ert-deftest agent-test-run-skill-before-exit-submits-in-matching-directory ()
  "Submit a Codex skill in explicitly configured directories."
  (let ((agent-backends nil)
        (agent-before-exit-skill-name "session-retro")
        (events nil))
    (with-temp-buffer
      (let* ((dir (file-name-as-directory default-directory))
             (buf (current-buffer))
             (agent-before-exit-skill-directories (list dir)))
        (apply #'agent-register-backend
         'codex
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :send-command (lambda (cmd &optional _buffer)
                          (push (list 'command cmd) events))
          :send-return (lambda (&optional _buffer) (push 'return events))))
        (agent--set-session
         buf (agent-session-create :backend 'codex :directory dir))
        (should-not (agent-run-skill-before-exit 'codex buf))
        (should (equal (nreverse events)
                       '((command "$session-retro") return)))))))

(ert-deftest agent-test-run-skill-before-exit-prefers-submit-command ()
  "Submit before-exit skills through a backend's atomic submit function."
  (let ((agent-backends nil)
        (agent-before-exit-skill-name "session-retro")
        events)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'codex
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :submit-command (lambda (cmd &optional _buffer)
                            (push (list 'submit cmd) events))
          :send-command (lambda (cmd &optional _buffer)
                          (push (list 'command cmd) events))
          :send-return (lambda (&optional _buffer) (push 'return events))))
        (should-not (agent-run-skill-before-exit 'codex buf))
        (should (equal (nreverse events)
                       '((submit "$session-retro"))))))))

(ert-deftest agent-test-run-skill-before-exit-uses-claude-slash ()
  "Submit Claude skills with slash syntax."
  (let ((agent-backends nil)
        (agent-before-exit-skill-name "session-retro")
        (events nil))
    (with-temp-buffer
      (let* ((dir (file-name-as-directory default-directory))
             (buf (current-buffer))
             (agent-before-exit-skill-directories (list dir)))
        (apply #'agent-register-backend
         'claude-code
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :send-command (lambda (cmd &optional _buffer)
                          (push (list 'command cmd) events))
          :send-return (lambda (&optional _buffer) (push 'return events))))
        (agent--set-session
         buf (agent-session-create :backend 'claude-code :directory dir))
        (should-not (agent-run-skill-before-exit 'claude-code buf))
        (should (equal (nreverse events)
                       '((command "/session-retro") return)))))))

(ert-deftest agent-test-run-skill-before-exit-skips-other-directories ()
  "Do not submit before-exit skills outside configured directories."
  (let ((agent-backends nil)
        (agent-before-exit-skill-name "session-retro")
        (agent-before-exit-skill-directories '("/tmp/not-this-repo/"))
        called)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'codex
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :send-command (lambda (&rest _args) (setq called t))))
        (agent--set-session
         buf (agent-session-create :backend 'codex
                                   :directory default-directory))
        (should (agent-run-skill-before-exit 'codex buf))
        (should-not called)))))

(ert-deftest agent-test-run-skill-before-exit-skips-short-sessions ()
  "Do not submit before-exit skills before the minimum duration."
  (let ((agent-backends nil)
        (agent-before-exit-skill-name "session-retro")
        (agent-before-exit-skill-directories nil)
        (agent-before-exit-skill-min-duration-seconds 60)
        called)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'codex
         (agent-test--backend
          :duration-ms (lambda (_buffer) 30000)
          :send-command (lambda (&rest _args) (setq called t))))
        (should (agent-run-skill-before-exit 'codex buf))
        (should-not called)
        (should-not agent--before-exit-skill-started)
        (should-not agent--before-exit-skill-exit-pending)))))

(ert-deftest agent-test-run-skill-before-exit-honors-buffer-local-inhibit ()
  "Do not submit before-exit skills when the session inhibits them."
  (let ((agent-backends nil)
        (agent-before-exit-skill-name "session-retro")
        (agent-before-exit-skill-directories nil)
        called)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (setq-local agent-before-exit-skill-inhibit t)
        (apply #'agent-register-backend
         'codex
         (agent-test--backend
          :send-command (lambda (&rest _args) (setq called t))))
        (should (agent-run-skill-before-exit 'codex buf))
        (should-not called)
        (should-not agent--before-exit-skill-started)
        (should-not agent--before-exit-skill-exit-pending)))))

(ert-deftest agent-test-run-skill-before-exit-allows-long-sessions ()
  "Submit before-exit skills after the minimum duration."
  (let ((agent-backends nil)
        (agent-before-exit-skill-name "session-retro")
        (agent-before-exit-skill-directories nil)
        (agent-before-exit-skill-min-duration-seconds 60)
        events)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'codex
         (agent-test--backend
          :duration-ms (lambda (_buffer) 60000)
          :send-command (lambda (cmd &optional _buffer)
                          (push (list 'command cmd) events))
          :send-return (lambda (&optional _buffer) (push 'return events))))
        (should-not (agent-run-skill-before-exit 'codex buf))
        (should (equal (nreverse events)
                       '((command "$session-retro") return)))))))

(ert-deftest agent-test-run-skill-before-exit-matches-expanded-directory ()
  "Match sessions under configured directories that use `~'."
  (let ((agent-backends nil)
        (agent-before-exit-skill-name "session-retro")
        (events nil))
    (with-temp-buffer
      (let* ((dir (expand-file-name "~/tmp/agent-before-exit-test/"))
             (buf (current-buffer))
             (agent-before-exit-skill-directories '("~/tmp/")))
        (apply #'agent-register-backend
         'codex
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :send-command (lambda (cmd &optional _buffer)
                          (push (list 'command cmd) events))
          :send-return (lambda (&optional _buffer) (push 'return events))))
        (agent--set-session
         buf (agent-session-create :backend 'codex :directory dir))
        (should-not (agent-run-skill-before-exit 'codex buf))
        (should (equal (nreverse events)
                       '((command "$session-retro") return)))))))

(ert-deftest agent-test-run-skill-before-exit-skips-unknown-backends ()
  "Do not abort exit when BACKEND has no skill command prefix."
  (let ((agent-backends nil)
        (agent-before-exit-skill-name "session-retro")
        called)
    (with-temp-buffer
      (let* ((dir (file-name-as-directory default-directory))
             (buf (current-buffer))
             (agent-before-exit-skill-directories (list dir)))
        (apply #'agent-register-backend
         'other
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :send-command (lambda (&rest _args) (setq called t))))
        (agent--set-session
         buf (agent-session-create :backend 'other :directory dir))
        (should (agent-run-skill-before-exit 'other buf))
        (should-not called)))))

(ert-deftest agent-test-exit-after-before-exit-skill-closes-pending-session ()
  "Exit a session when its before-exit skill has finished."
  (let ((agent-backends nil)
        ran)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (setq-local agent--before-exit-skill-exit-pending t)
        (apply #'agent-register-backend
         'one
         (agent-test--backend
          :exit (lambda () (interactive) (setq ran t))))
        (cl-letf (((symbol-function 'run-at-time)
                   (lambda (_time _repeat function &rest args)
                     (apply function args))))
          (should (agent-exit-after-before-exit-skill 'one buf))
          (should ran)
          (should-not agent--before-exit-skill-exit-pending))))))

(ert-deftest agent-test-exit-after-before-exit-skill-ignores-ordinary-ready ()
  "Do not exit sessions without a pending before-exit skill."
  (let ((agent-backends nil)
        ran)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'one
         (agent-test--backend
          :exit (lambda () (interactive) (setq ran t))))
        (should-not (agent-exit-after-before-exit-skill 'one buf))
        (should-not ran)))))

(ert-deftest agent-test-exit-after-before-exit-skill-honors-backend-veto ()
  "Do not close while a backend reports unaccepted prompt input."
  (let ((agent-backends nil)
        ran)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (setq-local agent--before-exit-skill-exit-pending t)
        (apply #'agent-register-backend
         'one
         (agent-test--backend
          :before-exit-ready-to-close-p (lambda (_buffer) nil)
          :exit (lambda () (interactive) (setq ran t))))
        (should-not (agent-exit-after-before-exit-skill 'one buf))
        (should-not ran)
        (should agent--before-exit-skill-exit-pending)))))

(ert-deftest agent-test-exit-after-before-exit-skill-advances-to-next-skill ()
  "Submit the next queued skill instead of exiting while the chain has more."
  (let ((agent-backends nil)
        (agent-skill-command-prefix-alist '((one . "/")))
        (events nil)
        ran)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (setq-local agent--before-exit-skill-exit-pending t)
        (setq-local agent--before-exit-skill-remaining
                    '(("update-log" :args "--auto")))
        (apply #'agent-register-backend
         'one
         (agent-test--backend
          :submit-command (lambda (cmd &optional _buffer) (push cmd events))
          :exit (lambda () (interactive) (setq ran t))))
        (should (agent-exit-after-before-exit-skill 'one buf))
        (should (equal events '("/update-log --auto")))
        (should-not ran)
        (should-not agent--before-exit-skill-remaining)
        (should agent--before-exit-skill-exit-pending)))))

(ert-deftest agent-test-discover-all-skills-skips-non-invocable ()
  "Do not expose skills marked `user-invocable: false'."
  (let ((agent-backends nil))
    (apply #'agent-register-backend
     'one
     (agent-test--backend
      :discover-skills (lambda ()
                         (list (list :name "visible")
                               (list :name "hidden"
                                     :user-invocable nil)))))
    (should (equal (mapcar (lambda (skill) (plist-get skill :name))
                           (agent--discover-all-skills))
                   '("visible")))))

;;;; Prompt capture

(ert-deftest agent-test-prompt-capture-file-is-session-specific ()
  "Build prompt capture paths from stable session identity."
  (let ((agent-backends nil)
        (agent-prompt-capture-directory temporary-file-directory))
    (with-temp-buffer
      (rename-buffer "*one:~/repo/project/:default*" t)
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :account (lambda (_buffer) "work")
          :extract-instance-name (lambda (_buffer-name) "default")))
        (should
         (string-prefix-p
          (expand-file-name "one-" temporary-file-directory)
          (agent--prompt-capture-file 'one buf)))))))

(ert-deftest agent-test-read-captured-prompts-skips-empty-and-inserted ()
  "Read pending nonempty Org prompt capture entries."
  (let ((file (make-temp-file "agent-prompts" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "* Empty\n")
            (insert ":PROPERTIES:\n:CREATED: [2026-05-17 Sun 10:00]\n:END:\n\n")
            (insert "* Inserted\n")
            (insert ":PROPERTIES:\n")
            (insert ":CREATED: [2026-05-17 Sun 10:01]\n")
            (insert ":INSERTED: [2026-05-17 Sun 10:02]\n")
            (insert ":END:\n\n")
            (insert "Already used\n")
            (insert "* Use this\n")
            (insert ":PROPERTIES:\n:CREATED: [2026-05-17 Sun 10:03]\n:END:\n\n")
            (insert "First line\nSecond line\n"))
          (let ((prompts (agent--read-captured-prompts file)))
            (should (= (length prompts) 1))
            (should (equal (plist-get (car prompts) :title) "Use this"))
            (should (equal (plist-get (car prompts) :text)
                           "First line\nSecond line"))))
      (delete-file file))))

(ert-deftest agent-test-insert-captured-prompt-sends-selected-text ()
  "Insert the selected persisted prompt into the session."
  (let ((agent-backends nil)
        (agent-prompt-capture-directory
         (make-temp-file "agent-prompts" t))
        sent)
    (unwind-protect
        (with-temp-buffer
          (rename-buffer "*one:~/repo/project/:default*" t)
          (let ((buf (current-buffer)))
            (apply #'agent-register-backend
             'one
             (agent-test--backend
              :buffer-p (lambda (candidate) (eq candidate buf))
              :find-all-buffers (lambda () (list buf))
              :send-command (lambda (text target)
                              (setq sent (list text target)))))
            (let ((file (agent--prompt-capture-file 'one buf)))
              (make-directory (file-name-directory file) t)
              (with-temp-file file
                (insert "* Prompt A\n\nAlpha\n")
                (insert "* Prompt B\n\nBeta\n")))
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (_prompt candidates &rest _)
                         (cadr candidates))))
              (agent-insert-captured-prompt buf)
              (should (equal sent (list "Beta" buf)))
              (let ((pending (agent--captured-prompts 'one buf)))
                (should (= (length pending) 1))
                (should (equal (plist-get (car pending) :text) "Alpha")))
              (let ((all (agent--captured-prompts 'one buf t)))
                (should (= (length all) 1))
                (should (equal (plist-get (car all) :text) "Alpha"))))))
      (delete-directory agent-prompt-capture-directory t))))

(ert-deftest agent-test-captured-prompt-candidate-previews-body ()
  "Show a truncated prompt body preview in completion candidates."
  (let* ((text (concat "First line\nSecond line with extra spacing "
                       (make-string 120 ?x)))
         (prompt (list :title "Prompt A"
                       :created "[2026-05-17 Sun 10:03]"
                       :text text))
         (candidate (agent--captured-prompt-candidate prompt)))
    (should (string-prefix-p
             "[2026-05-17 Sun 10:03] Prompt A: First line Second line"
             candidate))
    (should (string-suffix-p "..." candidate))
    (should (eq (get-text-property 0 'agent-prompt candidate) prompt))))

;;;; Alerts

(ert-deftest agent-test-alert-sound-error-is-nonfatal ()
  "Report sound playback errors without signaling."
  (let ((sound-file (make-temp-file "agent-test-sound" nil ".aiff"))
        messages)
    (unwind-protect
        (let ((agent-alert-style 'sound)
              (agent-alert-sound sound-file))
          (cl-letf (((symbol-function 'play-sound-file)
                     (lambda (_file) (error "no sound support")))
                    ((symbol-function 'message)
                     (lambda (format-string &rest args)
                       (push (apply #'format format-string args) messages))))
            (should (condition-case nil
                        (progn
                          (agent--alert-sound)
                          t)
                      (error nil)))
            (should (member "AI alert sound failed: no sound support" messages))))
      (delete-file sound-file))))

(ert-deftest agent-test-alert-indicator-active ()
  "Return the bell-on icon when alerts are enabled."
  (let ((agent-alert-on-ready t))
    (should (equal (agent-alert-indicator) "🔔"))))

(ert-deftest agent-test-alert-indicator-inactive ()
  "Return the bell-off icon when alerts are disabled."
  (let ((agent-alert-on-ready nil))
    (should (equal (agent-alert-indicator) "🔕"))))

(ert-deftest agent-test-parse-skill-frontmatter-argument-metadata ()
  "Parse shared skill argument metadata from frontmatter."
  (let ((file (make-temp-file "skill" nil ".md")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "---\n")
            (insert "name: convert\n")
            (insert "description: Convert citations\n")
            (insert "argument-hint: FILE\n")
            (insert "argument-choices: a, b\n")
            (insert "argument-default: a\n")
            (insert "argument-multiple: false\n")
            (insert "user-invocable: false\n")
            (insert "model: gpt-5.5\n")
            (insert "---\n"))
          (let ((meta (agent-parse-skill-frontmatter file)))
            (should (equal (plist-get meta :name) "convert"))
            (should (equal (plist-get meta :argument-choices) '("a" "b")))
            (should (equal (plist-get meta :argument-default) "a"))
            (should-not (plist-get meta :argument-multiple))
            (should-not (plist-get meta :user-invocable))
            (should (equal (plist-get meta :model) "gpt-5.5"))))
      (delete-file file))))

;;;; Session identity

(ert-deftest agent-test-session-buffer-name-claude-directory-only ()
  "Derive a Claude buffer name from a session without an instance."
  (should (equal (agent-session-buffer-name
                  (agent-session-create :backend 'claude-code
                                        :directory "~/repos/proj/"))
                 "*claude:~/repos/proj/*")))

(ert-deftest agent-test-session-buffer-name-claude-with-instance ()
  "Derive a Claude buffer name from a session with an instance."
  (should (equal (agent-session-buffer-name
                  (agent-session-create :backend 'claude-code
                                        :directory "~/repos/proj/"
                                        :instance "tests"))
                 "*claude:~/repos/proj/:tests*")))

(ert-deftest agent-test-session-buffer-name-codex-directory-only ()
  "Derive a Codex buffer name from a session without an instance."
  (should (equal (agent-session-buffer-name
                  (agent-session-create :backend 'codex
                                        :directory "~/repos/proj/"))
                 "*codex:~/repos/proj/*")))

(ert-deftest agent-test-session-buffer-name-codex-with-instance ()
  "Derive a Codex buffer name from a session with an instance."
  (should (equal (agent-session-buffer-name
                  (agent-session-create :backend 'codex
                                        :directory "~/repos/proj/"
                                        :instance "tests"))
                 "*codex:~/repos/proj/:tests*")))

(ert-deftest agent-test-session-lazily-backfills-from-buffer-name ()
  "Backfill a session struct by parsing a legacy buffer name."
  (let ((agent-backends nil))
    (with-temp-buffer
      (rename-buffer "*one:~/repo/backfill-proj/:tests*" t)
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :extract-instance-name
          (lambda (name)
            (when (string-match ":\\([^:/*]+\\)\\*\\'" name)
              (match-string 1 name)))
          :account (lambda (_buffer) "work")))
        (let ((session (agent-session buf)))
          (should session)
          (should (eq (agent-session-backend session) 'one))
          (should (equal (agent-session-directory session)
                         "~/repo/backfill-proj/"))
          (should (equal (agent-session-instance session) "tests"))
          (should (equal (agent-session-account session) "work"))
          (should (eq (buffer-local-value 'agent--session buf) session))
          (should (eq (buffer-local-value 'agent--backend buf) 'one)))))))

(ert-deftest agent-test-session-returns-nil-for-non-session-buffer ()
  "Return nil for buffers that belong to no registered backend."
  (let ((agent-backends nil))
    (with-temp-buffer
      (should-not (agent-session (current-buffer))))))

(ert-deftest agent-test-session-round-trips-native-buffer-name ()
  "Round-trip a native session buffer name through the session struct."
  (let ((agent-backends nil))
    (with-temp-buffer
      (rename-buffer "*claude:~/repo/roundtrip-proj/:tests*" t)
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'claude-code
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :extract-instance-name
          (lambda (name)
            (when (string-match ":\\([^:/*]+\\)\\*\\'" name)
              (match-string 1 name)))))
        (should (equal (agent-session-buffer-name (agent-session buf))
                       (buffer-name buf)))))))

(ert-deftest agent-test-session-prefers-explicitly-set-struct ()
  "Return the explicitly stored struct instead of re-deriving one."
  (with-temp-buffer
    (let ((session (agent-session-create :backend 'codex
                                         :directory "~/repos/proj/")))
      (agent--set-session (current-buffer) session)
      (should (eq (agent-session (current-buffer)) session)))))

(ert-deftest agent-test-session-buffer-name-normalizes-directory ()
  "Normalize raw session directories when deriving the buffer name."
  (let ((directory "/tmp/agent-test-dir"))
    (make-directory directory t)
    (unwind-protect
        (should (equal (agent-session-buffer-name
                        (agent-session-create :backend 'codex
                                              :directory directory))
                       (format "*codex:%s*"
                               (file-name-as-directory
                                (file-truename directory)))))
      (delete-directory directory))))

;;;; Backend struct registry

(ert-deftest agent-test-register-backend-rejects-unknown-keyword ()
  "Signal an error when registering a backend with an unknown keyword."
  (let ((agent-backends nil))
    (should-error
     (apply #'agent-register-backend
      'bad
      (agent-test--backend :bogus-slot #'ignore)))))

(ert-deftest agent-test-registered-backend-is-struct ()
  "Store registrations as `agent-backend' structs keyed by name."
  (let ((agent-backends nil))
    (apply #'agent-register-backend 'one (agent-test--backend))
    (let ((struct (agent-backend 'one)))
      (should (agent-backend-p struct))
      (should (eq (agent-backend-name struct) 'one))
      (should (equal (agent-backend-label struct) "Test")))))

(ert-deftest agent-test-register-backend-accepts-keyword-spread ()
  "Register a backend from spread keyword arguments."
  (let ((agent-backends nil))
    (agent-register-backend
     'kwspread
     :buffer-p (lambda (_buffer) nil)
     :find-all-buffers (lambda () nil)
     :extract-instance-name (lambda (_buffer-name) nil)
     :start-new #'ignore
     :label "Spread")
    (let ((struct (agent-backend 'kwspread)))
      (should (agent-backend-p struct))
      (should (eq (agent-backend-name struct) 'kwspread))
      (should (equal (agent-backend-label struct) "Spread"))
      (should (eq (agent-backend-start-new struct) #'ignore)))))

(ert-deftest agent-test-backend-get-maps-keywords-to-slots ()
  "Map legacy keyword lookups onto struct slots."
  (let ((agent-backends nil))
    (apply #'agent-register-backend 'one (agent-test--backend :program "one-cli"))
    (should (equal (agent--backend-get 'one :program) "one-cli"))
    (should (equal (agent--backend-get 'one :label) "Test"))
    (should-not (agent--backend-get 'unregistered :label))))

(ert-deftest agent-test-backend-get-rejects-unknown-slot-keyword ()
  "Signal an error for shim lookups naming no struct slot."
  (let ((agent-backends nil))
    (apply #'agent-register-backend 'one (agent-test--backend))
    (should-error (agent--backend-get 'one :not-a-slot))))

(ert-deftest agent-test-detect-backend-resolves-with-struct-registry ()
  "Resolve a buffer's backend through struct-based registrations."
  (let ((agent-backends nil))
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))))
        (should (eq (agent--detect-backend buf) 'one))))))

(provide 'agent-test)
;;; agent-test.el ends here
