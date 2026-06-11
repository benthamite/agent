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

(ert-deftest agent-test-act-on-slack-message-uses-unified-defcustoms ()
  "Route Slack-message action through the unified core defcustom pair."
  (let ((agent-backends nil)
        (agent-act-on-slack-message-model 'test-model)
        (agent-act-on-slack-message-backend "TestBackend")
        (captured nil))
    (apply #'agent-register-backend 'one (agent-test--backend))
    (cl-letf (((symbol-function 'agent--act-on-slack-message)
               (lambda (model backend _start-function)
                 (setq captured (list model backend)))))
      (agent-act-on-slack-message)
      (should (equal captured '(test-model "TestBackend"))))))

(ert-deftest agent-test-act-on-slack-start-session-inserts-url-for-review ()
  "Start a backend session and insert the Slack URL without submitting it."
  (let ((agent-backends nil)
        (project '(:id "project" :directory "/tmp/project"))
        (url "https://example.slack.com/archives/C1/p123")
        (buffer (generate-new-buffer " *agent-test*"))
        started
        sent)
    (apply #'agent-register-backend 'one (agent-test--backend))
    (unwind-protect
        (cl-letf (((symbol-function 'agent-start-session)
                   (lambda (session &rest options)
                     (setq started (list session options))
                     buffer))
                  ((symbol-function 'agent-send-string)
                   (lambda (cmd target)
                     (setq sent (list cmd target))
                     target))
                  ((symbol-function 'agent-submit)
                   (lambda (&rest _) (ert-fail "agent-submit was called")))
                  ((symbol-function 'agent-send-return)
                   (lambda (&rest _)
                     (ert-fail "agent-send-return was called"))))
          (should (eq (agent--act-on-slack-start-session 'one project url)
                      buffer))
          (let ((session (car started)))
            (should (eq (agent-session-backend session) 'one))
            (should (equal (agent-session-directory session) "/tmp/project/"))
            (should-not (agent-session-instance session)))
          (should-not (cadr started))
          (should (equal sent (list url buffer))))
      (kill-buffer buffer))))

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
  "Group session switcher suffixes by session account."
  (let ((agent-backends nil)
        (agent--session-keys (make-hash-table :test 'eq)))
    (with-temp-buffer
      (rename-buffer "*one:~/repo/a/:default*" t)
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :find-all-buffers (lambda () (list buf))))
        (setq-local agent--session
                    (agent-session-create :backend 'one :account "work"))
        (puthash buf "a" agent--session-keys)
        (should (equal (mapcar #'car (agent--group-sessions-by-account))
                       '("work")))))))

;;;; Display state

(ert-deftest agent-test-display-state-busy-by-default ()
  "Report busy for sessions without waiting state."
  (let ((agent-backends nil))
    (with-temp-buffer
      (should (eq (agent-session-display-state (current-buffer)) 'busy)))))

(ert-deftest agent-test-display-state-waiting-after-awaiting-input ()
  "Report waiting once the session state machine awaits input."
  (let ((agent-backends nil))
    (with-temp-buffer
      (setq-local agent--session-state 'awaiting-input)
      (should (eq (agent-session-display-state (current-buffer)) 'waiting)))))

(ert-deftest agent-test-display-state-busy-backend-suppresses-stale-waiting ()
  "Suppress stale waiting state while the backend reports busy."
  (let ((agent-backends nil))
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :busy-p (lambda (_buffer) t)))
        (setq-local agent--session-state 'awaiting-input)
        (should (eq (agent-session-display-state buf) 'busy))))))

(ert-deftest agent-test-display-state-background-tasks-mark-amber ()
  "Report background-waiting for waiting sessions with background work."
  (let ((agent-backends nil))
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :background-tasks-p (lambda (_buffer) t)))
        (setq-local agent--session-state 'awaiting-input)
        (should (eq (agent-session-display-state buf)
                    'background-waiting))))))

(ert-deftest agent-test-display-state-steering-overrides-busy ()
  "Report background-waiting for busy sessions accepting steering input."
  (let ((agent-backends nil))
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :waiting-p (lambda (_buffer) t)
          :busy-p (lambda (_buffer) t)
          :background-tasks-p (lambda (_buffer) t)))
        (should (eq (agent-session-display-state buf)
                    'background-waiting))))))

(ert-deftest agent-test-jump-to-waiting-picks-most-recent ()
  "Jump to the session that most recently started waiting."
  (let ((agent-backends nil)
        (a (generate-new-buffer "agent-wait-a"))
        (b (generate-new-buffer "agent-wait-b"))
        switched)
    (unwind-protect
        (progn
          (apply #'agent-register-backend
           'one
           (agent-test--backend
            :buffer-p (lambda (candidate) (memq candidate (list a b)))
            :find-all-buffers (lambda () (list a b))))
          (with-current-buffer a
            (setq-local agent--session-state 'awaiting-input)
            (setq-local agent--session-state-changed-at 100.0))
          (with-current-buffer b
            (setq-local agent--session-state 'awaiting-input)
            (setq-local agent--session-state-changed-at 200.0))
          (cl-letf (((symbol-function 'switch-to-buffer)
                     (lambda (buffer) (setq switched buffer))))
            (agent-jump-to-waiting))
          (should (eq switched b)))
      (kill-buffer a)
      (kill-buffer b))))

(ert-deftest agent-test-waiting-with-background-work-displays-amber ()
  "Use the background-waiting state when the backend reports work."
  (let ((agent-backends nil))
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :find-all-buffers (lambda () (list buf))
          :background-tasks-p (lambda (_buffer) t)))
        (setq-local agent--session-state 'awaiting-input)
        (should (eq (agent-session-display-state buf 'one)
                    'background-waiting))))))

;;;; Skills

(ert-deftest agent-test-run-skill-distinguishes-backends ()
  "Run the selected backend skill when names collide."
  (let* ((agent-backends nil)
         (dir-one (make-temp-file "agent-skills-one" t))
         (dir-two (make-temp-file "agent-skills-two" t))
         ran)
    (unwind-protect
        (progn
          (dolist (dir (list dir-one dir-two))
            (make-directory (expand-file-name "audit" dir) t)
            (with-temp-file (expand-file-name "audit/SKILL.md" dir)
              (insert "---\nname: audit\n---\nAudit.\n")))
          (apply #'agent-register-backend
           'one
           (agent-test--backend
            :label "One"
            :skill-roots (lambda () (list (cons dir-one 'file)))
            :run-prompt (cl-function
                         (lambda (prompt &key directory callback)
                           (ignore directory callback)
                           (setq ran (list 'one prompt))))))
          (apply #'agent-register-backend
           'two
           (agent-test--backend
            :label "Two"
            :skill-roots (lambda () (list (cons dir-two 'file)))
            :run-prompt (cl-function
                         (lambda (prompt &key directory callback)
                           (ignore directory callback)
                           (setq ran (list 'two prompt))))))
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (&rest _args) "audit [Two]")))
            (agent-run-skill)
            (should (eq (car ran) 'two))
            (should (string-match-p "audit" (cadr ran)))))
      (delete-directory dir-one t)
      (delete-directory dir-two t))))

(ert-deftest agent-test-post-push-ci-runs-skill-for-head ()
  "Run post-push CI through the selected backend with the current HEAD."
  (let* ((agent-backends nil)
         (root (make-temp-file "agent-skills" t))
         (skill-file (expand-file-name "post-push-ci/SKILL.md" root))
         ran)
    (unwind-protect
        (progn
          (make-directory (file-name-directory skill-file) t)
          (with-temp-file skill-file
            (insert "---\nname: post-push-ci\n---\nClose the loop.\n"))
          (apply #'agent-register-backend
           'one
           (agent-test--backend
            :skill-roots (lambda () (list (cons root 'file)))
            :run-prompt (cl-function
                         (lambda (prompt &key directory callback)
                           (ignore directory callback)
                           (setq ran prompt)))))
          (cl-letf (((symbol-function 'process-file)
                     (lambda (&rest _args)
                       (insert "abc123\n")
                       0)))
            (agent-post-push-ci)
            (should (string-match-p (regexp-quote skill-file) ran))
            (should (string-match-p "--no-push --commit abc123" ran))))
      (delete-directory root t))))

(ert-deftest agent-test-skill-result-does-not-modify-new-user-buffer ()
  "Display skill output in a result buffer, not an unrelated new buffer."
  (let ((unrelated (get-buffer-create "*agent-unrelated*"))
        (result-buffer "*Agent skill: proofread*"))
    (unwind-protect
        (progn
          (with-current-buffer unrelated
            (erase-buffer)
            (insert "#+title: User buffer\nBody\n"))
          (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
            (agent--display-skill-result "proofread" "ok" nil))
          (with-current-buffer unrelated
            (should (equal (buffer-string) "#+title: User buffer\nBody\n")))
          (should (get-buffer result-buffer)))
      (when (buffer-live-p unrelated)
        (kill-buffer unrelated))
      (when-let* ((buf (get-buffer result-buffer)))
        (kill-buffer buf)))))

;;;; Project audit

(ert-deftest agent-test-audit-commits-after-successful-skill ()
  "Auto-commit after each successful audit skill and not after failures."
  (let ((agent-backends nil)
        (agent-audit-skills '("a" "b"))
        commits)
    (apply #'agent-register-backend
     'one
     (agent-test--backend
      :skill-roots (lambda () nil)
      :run-prompt (cl-function
                   (lambda (prompt &key directory callback)
                     (ignore directory)
                     (funcall callback "out"
                              :error (when (string-match-p "/b" prompt)
                                       "exit code 1"))))))
    (cl-letf (((symbol-function 'agent--audit-commit-changes)
               (lambda (_dir title) (push title commits)))
              ((symbol-function 'agent--audit-finish) #'ignore))
      (agent--audit-run-next (list :backend 'one :queue agent-audit-skills
                                   :results nil :dir "/tmp/"
                                   :start-time (current-time))))
    (should (equal commits '("a")))))

(ert-deftest agent-test-audit-strips-leading-slash-from-skill-names ()
  "Resolve legacy slash-format audit skill names like plain names."
  (let ((agent-backends nil)
        prompts)
    (apply #'agent-register-backend
     'one
     (agent-test--backend
      :skill-roots (lambda () nil)
      :run-prompt (cl-function
                   (lambda (prompt &key directory callback)
                     (ignore directory)
                     (push prompt prompts)
                     (funcall callback "out" :error nil)))))
    (cl-letf (((symbol-function 'agent--audit-commit-changes) #'ignore)
              ((symbol-function 'agent--audit-finish) #'ignore))
      (dolist (queue '(("/code-audit") ("code-audit")))
        (agent--audit-run-next (list :backend 'one :queue queue
                                     :results nil :dir "/tmp/"
                                     :start-time (current-time)))))
    (should (equal prompts
                   '("/code-audit --accept" "/code-audit --accept")))))

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

(ert-deftest agent-test-add-process-exit-hook-composes-with-sentinel ()
  "Run the original sentinel and stacked exit hooks once each on exit."
  (let* ((buf (generate-new-buffer " *agent-exit-hook*"))
         (events nil)
         (proc (make-process :name "agent-exit-hook-test" :buffer buf
                             :command '("true") :connection-type 'pipe)))
    (unwind-protect
        (progn
          (set-process-sentinel proc (lambda (_p _e) (push 'orig events)))
          (agent--add-process-exit-hook
           buf (lambda (_buffer) (push 'hook events)))
          (agent--add-process-exit-hook
           buf (lambda (_buffer) (push 'hook2 events)))
          (while (process-live-p proc)
            (accept-process-output proc 0.1))
          (with-timeout (2 (ert-fail "sentinel never ran"))
            (while (< (length events) 3)
              (sit-for 0.05)))
          (should (= (length events) 3))
          (should (memq 'orig events))
          (should (memq 'hook events))
          (should (memq 'hook2 events)))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest agent-test-setup-kill-on-exit-honors-before-kill-check ()
  "Do not kill the buffer when the backend before-kill-check vetoes."
  (let ((agent-backends nil)
        (hook-fn nil))
    (with-temp-buffer
      (rename-buffer "*one:~/repo/project/:default*" t)
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :before-kill-check (lambda (_buffer) nil)))
        (cl-letf (((symbol-function 'get-buffer-process)
                   (lambda (_b) 'fake-proc))
                  ((symbol-function 'agent--add-process-exit-hook)
                   (lambda (_buffer fn) (setq hook-fn fn))))
          (agent-setup-kill-on-exit))
        (funcall hook-fn buf)
        (should (buffer-live-p buf))))))

(ert-deftest agent-test-exit-runs-before-exit-functions ()
  "Abort exit when a before-exit function returns nil."
  (let ((agent-backends nil)
        (agent-before-exit-functions nil)
        ran
        seen)
    (with-temp-buffer
      (rename-buffer "*one:~/repo/project/:default*" t)
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))))
        (add-hook 'agent-before-exit-functions
                  (lambda (backend buffer)
                    (setq seen (list backend buffer))
                    nil))
        (cl-letf (((symbol-function 'agent--exit-session)
                   (lambda (_buffer) (setq ran t))))
          (agent-exit))
        (should (equal seen (list 'one buf)))
        (should-not ran)))))

(ert-deftest agent-test-exit-proceeds-after-before-exit-functions ()
  "Exit when every before-exit function returns non-nil."
  (let ((agent-backends nil)
        (agent-before-exit-functions nil)
        ran)
    (with-temp-buffer
      (rename-buffer "*one:~/repo/project/:default*" t)
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))))
        (add-hook 'agent-before-exit-functions (lambda (_backend _buffer) t))
        (cl-letf (((symbol-function 'agent--exit-session)
                   (lambda (_buffer) (setq ran t))))
          (agent-exit))
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
              :buffer-p (lambda (candidate) (eq candidate buf))))
            (let ((file (agent--prompt-capture-file 'one buf)))
              (make-directory (file-name-directory file) t)
              (with-temp-file file
                (insert "* Prompt A\n\nAlpha\n")))
            (cl-letf (((symbol-function 'yes-or-no-p)
                       (lambda (prompt)
                         (setq prompted prompt)
                         nil))
                      ((symbol-function 'agent--exit-session)
                       (lambda (_buffer) (setq ran t))))
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
              :buffer-p (lambda (candidate) (eq candidate buf))))
            (cl-letf (((symbol-function 'yes-or-no-p)
                       (lambda (_prompt)
                         (setq prompted t)
                         nil))
                      ((symbol-function 'agent--exit-session)
                       (lambda (_buffer) (setq ran t))))
              (agent-exit))
            (should-not prompted)
            (should ran)))
      (delete-directory agent-prompt-capture-directory t))))

(ert-deftest agent-test-restart-confirms-when-captured-prompts-pending ()
  "Abort restart when pending captures exist and confirmation is declined."
  (let ((agent-backends nil)
        (agent-prompt-capture-directory (make-temp-file "agent-prompts" t))
        prompted
        killed)
    (unwind-protect
        (with-temp-buffer
          (rename-buffer "*one:~/repo/project/:default*" t)
          (let ((buf (current-buffer)))
            (apply #'agent-register-backend
             'one
             (agent-test--backend
              :buffer-p (lambda (candidate) (eq candidate buf))
              :session-identity (lambda (_buffer) "sid-123")))
            (let ((file (agent--prompt-capture-file 'one buf)))
              (make-directory (file-name-directory file) t)
              (with-temp-file file
                (insert "* Prompt A\n\nAlpha\n")))
            (cl-letf (((symbol-function 'yes-or-no-p)
                       (lambda (prompt)
                         (setq prompted prompt)
                         nil))
                      ((symbol-function 'agent--force-kill-buffer)
                       (lambda (_buffer) (setq killed t))))
              (agent-restart))
            (should (string-match-p "1 captured prompt" prompted))
            (should-not killed)))
      (delete-directory agent-prompt-capture-directory t))))

(ert-deftest agent-test-restart-resumes-with-session-identity ()
  "Restart kills the buffer and resumes the exact session id."
  (let ((agent-backends nil)
        (agent-prompt-capture-directory (make-temp-file "agent-prompts" t))
        killed
        resumed)
    (unwind-protect
        (with-temp-buffer
          (rename-buffer "*one:~/repo/project/:default*" t)
          (let ((buf (current-buffer)))
            (apply #'agent-register-backend
             'one
             (agent-test--backend
              :buffer-p (lambda (candidate) (eq candidate buf))
              :session-identity (lambda (_buffer) "sid-123")))
            (cl-letf (((symbol-function 'agent--force-kill-buffer)
                       (lambda (_buffer) (setq killed t)))
                      ((symbol-function 'agent-restart--account)
                       (lambda (_backend _account) nil))
                      ((symbol-function 'agent-start-session)
                       (cl-function
                        (lambda (session &key initial-prompt resume-id)
                          (ignore initial-prompt)
                          (setq resumed (list (agent-session-backend session)
                                              resume-id))))))
              (agent-restart))
            (should killed)
            (should (equal resumed '(one "sid-123")))))
      (delete-directory agent-prompt-capture-directory t))))

(ert-deftest agent-test-restart-without-identity-does-not-kill ()
  "Restart refuses to kill the buffer when no session id exists."
  (let ((agent-backends nil)
        (agent-prompt-capture-directory (make-temp-file "agent-prompts" t))
        killed)
    (unwind-protect
        (with-temp-buffer
          (rename-buffer "*one:~/repo/project/:default*" t)
          (let ((buf (current-buffer)))
            (apply #'agent-register-backend
             'one
             (agent-test--backend
              :buffer-p (lambda (candidate) (eq candidate buf))
              :session-identity (lambda (_buffer) nil)))
            (cl-letf (((symbol-function 'agent--force-kill-buffer)
                       (lambda (_buffer) (setq killed t))))
              (should-error (agent-restart) :type 'user-error))
            (should-not killed)))
      (delete-directory agent-prompt-capture-directory t))))

(ert-deftest agent-test-restart-without-restart-options-omits-extras ()
  "Restart backends lacking restart-options with only the resume id."
  (let ((agent-backends nil)
        (agent-prompt-capture-directory (make-temp-file "agent-prompts" t))
        (captured 'unset))
    (unwind-protect
        (with-temp-buffer
          (rename-buffer "*one:~/repo/project/:default*" t)
          (let ((buf (current-buffer)))
            (apply #'agent-register-backend
             'one
             (agent-test--backend
              :buffer-p (lambda (candidate) (eq candidate buf))
              :session-identity (lambda (_buffer) "sid-123")))
            (cl-letf (((symbol-function 'agent--force-kill-buffer) #'ignore)
                      ((symbol-function 'agent-restart--account)
                       (lambda (_backend _account) nil))
                      ((symbol-function 'agent-start-session)
                       (lambda (_session &rest options)
                         (setq captured options))))
              (agent-restart))
            (should (equal captured '(:resume-id "sid-123")))))
      (delete-directory agent-prompt-capture-directory t))))

(ert-deftest agent-test-handoff-carries-source-session ()
  "Start the handoff session with the source buffer's account and directory."
  (let* ((agent-backends nil)
         (agent-prompt-capture-directory (make-temp-file "agent-prompts" t))
         (dir (file-name-as-directory (make-temp-file "agent-handoff" t)))
         (handoff-file (expand-file-name "handoff.md" dir))
         killed started)
    (unwind-protect
        (with-temp-buffer
          (let ((buf (current-buffer)))
            (setq default-directory dir)
            (apply #'agent-register-backend
             'one
             (agent-test--backend
              :buffer-p (lambda (candidate) (eq candidate buf))))
            (with-temp-file handoff-file (insert "continue\n"))
            (let ((agent-handoff-files '((one . "handoff.md"))))
              (cl-letf (((symbol-function 'agent--handoff-file)
                         (lambda (_backend) handoff-file))
                        ((symbol-function 'agent-session)
                         (lambda (&optional _buffer)
                           (agent-session-create :backend 'one :account "work"
                                                 :directory dir)))
                        ((symbol-function 'agent--force-kill-buffer)
                         (lambda (buffer) (setq killed buffer)))
                        ((symbol-function 'agent-start-session)
                         (cl-function
                          (lambda (session &key initial-prompt &allow-other-keys)
                            (setq started (list (agent-session-account session)
                                                (agent-session-directory session)
                                                initial-prompt))))))
                (agent-handoff)))
            (should (eq killed buf))
            (should (equal started (list "work" dir "continue")))))
      (delete-directory agent-prompt-capture-directory t)
      (delete-directory dir t))))

(ert-deftest agent-test-run-skill-before-exit-submits-codex-skill ()
  "Submit a Codex skill and abort the first exit globally by default."
  (let ((agent-backends nil)
        (agent-before-exit-skill-name "session-retro")
        (agent-before-exit-skill-directories nil)
        events)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'codex
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :skill-command-prefix "$"
          :send-command (lambda (cmd &optional _buffer)
                          (push (list 'command cmd) events))
          :send-return (lambda (&optional _buffer) (push 'return events))))
        (should-not (agent-run-skill-before-exit 'codex buf))
        (should (equal (nreverse events)
                       '((command "$session-retro") return)))
        (should (eq (plist-get agent--before-exit :state) 'running))
        (should-not (plist-get agent--before-exit :queue))
        (should (numberp (plist-get agent--before-exit :started-at)))
        (should (agent-run-skill-before-exit 'codex buf))))))

(ert-deftest agent-test-before-exit-chain-advances-on-stop-events ()
  "Advance a two-skill chain across stop events, then close."
  (let ((agent-backends nil)
        (agent-before-exit-skill-names '("update-log" "session-retro"))
        (agent-before-exit-skill-name nil)
        (agent-before-exit-skill-directories nil)
        (events nil)
        exited)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'codex
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :skill-command-prefix "$"
          :submit-command (lambda (cmd &optional _buffer) (push cmd events))))
        (cl-letf (((symbol-function 'agent--before-exit-start-watchdog)
                   (lambda (_buffer) nil))
                  ((symbol-function 'agent--exit-session)
                   (lambda (_buffer) (setq exited t)))
                  ((symbol-function 'run-at-time)
                   (lambda (_time _repeat function &rest args)
                     (apply function args))))
          (should-not (agent-run-skill-before-exit 'codex buf))
          (should (equal events '("$update-log")))
          (should-not exited)
          (should (agent--before-exit-transition buf 'step))
          (should (equal events '("$session-retro" "$update-log")))
          (should-not exited)
          (should (agent--before-exit-transition buf 'step))
          (should exited)
          (should (eq (plist-get agent--before-exit :state) 'closing)))))))

(ert-deftest agent-test-before-exit-veto-defers-exactly-one-stop ()
  "Defer chain advance while the backend vetoes, then proceed."
  (let ((agent-backends nil)
        (agent-before-exit-skill-name "session-retro")
        (agent-before-exit-skill-directories nil)
        (ready nil)
        exited)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'codex
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :skill-command-prefix "$"
          :submit-command (lambda (_cmd &optional _buffer))
          :before-exit-ready-to-close-p (lambda (_buffer) ready)))
        (cl-letf (((symbol-function 'agent--before-exit-start-watchdog)
                   (lambda (_buffer) nil))
                  ((symbol-function 'agent--exit-session)
                   (lambda (_buffer) (setq exited t)))
                  ((symbol-function 'run-at-time)
                   (lambda (_time _repeat function &rest args)
                     (apply function args))))
          (should-not (agent-run-skill-before-exit 'codex buf))
          (should-not (agent--before-exit-transition buf 'step))
          (should-not exited)
          (should (eq (plist-get agent--before-exit :state) 'running))
          (setq ready t)
          (should (agent--before-exit-transition buf 'step))
          (should exited))))))

(ert-deftest agent-test-before-exit-timeout-aborts-and-warns ()
  "Reset the chain and warn when the watchdog expires."
  (let ((agent-backends nil)
        (agent-before-exit-skill-name "session-retro")
        (agent-before-exit-skill-directories nil)
        (agent-before-exit-timeout 600)
        watchdog
        messages
        exited)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'codex
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :skill-command-prefix "$"
          :submit-command (lambda (_cmd &optional _buffer))))
        (cl-letf (((symbol-function 'agent--exit-session)
                   (lambda (_buffer) (setq exited t)))
                  ((symbol-function 'run-at-time)
                   (lambda (time _repeat function &rest args)
                     (when (equal time agent-before-exit-timeout)
                       (setq watchdog (cons function args)))
                     'agent-test-timer))
                  ((symbol-function 'cancel-timer) #'ignore)
                  ((symbol-function 'message)
                   (lambda (fmt &rest args)
                     (push (apply #'format fmt args) messages))))
          (should-not (agent-run-skill-before-exit 'codex buf))
          (should watchdog)
          (apply (car watchdog) (cdr watchdog))
          (should-not agent--before-exit)
          (should-not exited)
          (should (cl-some (lambda (m) (string-match-p "timed out" m))
                           messages)))))))

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
          :skill-command-prefix "$"
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
          :skill-command-prefix "$"
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
          :skill-command-prefix "/"
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
          :buffer-p (lambda (candidate) (eq candidate buf))
          :duration-ms (lambda (_buffer) 30000)
          :send-command (lambda (&rest _args) (setq called t))))
        (should (agent-run-skill-before-exit 'codex buf))
        (should-not called)
        (should-not agent--before-exit)))))

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
          :buffer-p (lambda (candidate) (eq candidate buf))
          :send-command (lambda (&rest _args) (setq called t))))
        (should (agent-run-skill-before-exit 'codex buf))
        (should-not called)
        (should-not agent--before-exit)))))

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
          :buffer-p (lambda (candidate) (eq candidate buf))
          :skill-command-prefix "$"
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
          :skill-command-prefix "$"
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

(ert-deftest agent-test-before-exit-step-closes-pending-session ()
  "Exit a session when its before-exit chain has drained."
  (let ((agent-backends nil)
        ran)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))))
        (setq-local agent--before-exit (list :queue nil :state 'running))
        (cl-letf (((symbol-function 'agent--exit-session)
                   (lambda (_buffer) (setq ran t)))
                  ((symbol-function 'run-at-time)
                   (lambda (_time _repeat function &rest args)
                     (apply function args))))
          (should (agent--before-exit-transition buf 'step))
          (should ran)
          (should (eq (plist-get agent--before-exit :state) 'closing)))))))

(ert-deftest agent-test-before-exit-step-ignores-idle-sessions ()
  "Do not consume stop events in sessions without a running chain."
  (let ((agent-backends nil)
        ran)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))))
        (cl-letf (((symbol-function 'agent--exit-session)
                   (lambda (_buffer) (setq ran t))))
          (should-not (agent--before-exit-transition buf 'step)))
        (should-not ran)))))

(ert-deftest agent-test-before-exit-step-honors-backend-veto ()
  "Do not close while a backend reports unaccepted prompt input."
  (let ((agent-backends nil)
        ran)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :before-exit-ready-to-close-p (lambda (_buffer) nil)))
        (setq-local agent--before-exit '(:queue nil :state running))
        (cl-letf (((symbol-function 'agent--exit-session)
                   (lambda (_buffer) (setq ran t))))
          (should-not (agent--before-exit-transition buf 'step)))
        (should-not ran)
        (should (eq (plist-get agent--before-exit :state) 'running))))))

(ert-deftest agent-test-before-exit-step-advances-to-next-skill ()
  "Submit the next queued skill instead of exiting while the chain has more."
  (let ((agent-backends nil)
        (events nil)
        ran)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :skill-command-prefix "/"
          :submit-command (lambda (cmd &optional _buffer) (push cmd events))))
        (setq-local agent--before-exit
                    (list :queue (list (list "update-log" :args "--auto"))
                          :state 'running))
        (cl-letf (((symbol-function 'agent--exit-session)
                   (lambda (_buffer) (setq ran t))))
          (should (agent--before-exit-transition buf 'step)))
        (should (equal events '("/update-log --auto")))
        (should-not ran)
        (should-not (plist-get agent--before-exit :queue))
        (should (eq (plist-get agent--before-exit :state) 'running))))))

(ert-deftest agent-test-discover-all-skills-skips-non-invocable ()
  "Do not expose skills marked `user-invocable: false' interactively."
  (let* ((agent-backends nil)
         (root (make-temp-file "agent-skills" t)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "visible" root) t)
          (with-temp-file (expand-file-name "visible/SKILL.md" root)
            (insert "---\nname: visible\n---\n"))
          (make-directory (expand-file-name "hidden" root) t)
          (with-temp-file (expand-file-name "hidden/SKILL.md" root)
            (insert "---\nname: hidden\nuser-invocable: false\n---\n"))
          (apply #'agent-register-backend
           'one
           (agent-test--backend
            :skill-roots (lambda () (list (cons root 'file)))))
          (should (equal (mapcar (lambda (skill) (plist-get skill :name))
                                 (agent-discover-skills 'one))
                         '("hidden" "visible")))
          (should (equal (mapcar (lambda (skill) (plist-get skill :name))
                                 (agent--discover-all-skills))
                         '("visible"))))
      (delete-directory root t))))

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
          :extract-instance-name (lambda (_buffer-name) "default")))
        (setq-local agent--session
                    (agent-session-create :backend 'one :account "work"))
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
              (match-string 1 name)))))
        (let* ((agent-account--starting '(one . "work"))
               (session (agent-session buf)))
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

(ert-deftest agent-test-capture-session-replaces-stale-struct ()
  "Re-capture session identity over an earlier accountless struct."
  (let ((agent-backends nil))
    (with-temp-buffer
      (rename-buffer "*one:~/repo/recapture-proj/:tests*" t)
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
               'one
               (agent-test--backend
                :buffer-p (lambda (candidate) (eq candidate buf))
                :extract-instance-name
                (lambda (name)
                  (when (string-match ":\\([^:/*]+\\)\\*\\'" name)
                    (match-string 1 name)))))
        (agent--set-session
         buf
         (agent-session-create :backend 'one
                               :directory "~/repo/recapture-proj/"))
        (let* ((agent-account--starting '(one . "work"))
               (session (agent--capture-session buf)))
          (should (equal (agent-session-account session) "work"))
          (should (eq (buffer-local-value 'agent--session buf) session)))))))

(ert-deftest agent-test-display-name-prefers-session-struct ()
  "Use the stored session identity instead of buffer-name parsing."
  (let ((agent-backends nil))
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
               'one
               (agent-test--backend
                :buffer-p (lambda (candidate) (eq candidate buf))
                :find-all-buffers (lambda () (list buf))))
        (agent--set-session
         buf
         (agent-session-create :backend 'one
                               :directory "~/repo/struct-name-wins/"))
        (should (equal (agent-display-name buf) "struct-name-wins"))))))

(ert-deftest agent-test-session-group-key-prefers-struct-account ()
  "Group sessions by the account stored in the session struct."
  (let ((agent-backends nil))
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
               'one
               (agent-test--backend
                :buffer-p (lambda (candidate) (eq candidate buf))
                :account (lambda (_buffer) "fallback-account")))
        (agent--set-session
         buf
         (agent-session-create :backend 'one
                               :account "struct-account"
                               :directory "~/repo/a/"))
        (should (equal (agent--session-group-key buf) "struct-account"))))))

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

(ert-deftest agent-test-start-session-dispatches-to-backend ()
  "Dispatch session starts to the backend's start-session function."
  (let* ((buffer (generate-new-buffer " *agent-test-session*"))
         (session (agent-session-create :backend 'codex :directory "/tmp/"))
         captured)
    (unwind-protect
        (cl-letf (((symbol-function 'agent--backend-get)
                   (lambda (_backend key)
                     (when (eq key :start-session)
                       (lambda (sess &rest options)
                         (setq captured (cons sess options))
                         buffer)))))
          (should (eq (agent-start-session session :resume-id "abc") buffer))
          (should (eq (car captured) session))
          (should (equal (plist-get (cdr captured) :resume-id) "abc")))
      (kill-buffer buffer))))

(ert-deftest agent-test-start-session-rejects-unsupported-backend ()
  "Signal a user error for backends without start-session support."
  (let ((session (agent-session-create :backend 'codex :directory "/tmp/")))
    (cl-letf (((symbol-function 'agent--backend-get)
               (lambda (_backend _key) nil)))
      (should-error (agent-start-session session) :type 'user-error))))

(ert-deftest agent-test-start-session-binds-starting-account ()
  "Bind `agent-account--starting' and sync before the backend start call."
  (let ((agent-backends nil)
        (events nil))
    (apply #'agent-register-backend
     'one
     (agent-test--backend
      :start-session (lambda (_session &rest _)
                       (push (cons 'start agent-account--starting) events))))
    (cl-letf (((symbol-function 'agent-account-sync)
               (lambda (backend account)
                 (push (cons 'sync (cons backend account)) events))))
      (agent-start-session
       (agent-session-create :backend 'one :account "work")))
    (should (equal (nreverse events)
                   '((sync . (one . "work"))
                     (start . (one . "work")))))))

(ert-deftest agent-test-start-session-backfills-account-from-current ()
  "Fill an accountless session's account slot from the active account."
  (let ((agent-backends nil)
        (agent-account--current (make-hash-table :test #'eq))
        (events nil)
        captured-account captured-starting)
    (puthash 'one "work" agent-account--current)
    (apply #'agent-register-backend
     'one
     (agent-test--backend
      :accounts '(("work" . "/tmp/agent-test-work/"))
      :start-session (lambda (session &rest _)
                       (setq captured-account (agent-session-account session)
                             captured-starting agent-account--starting))))
    (cl-letf (((symbol-function 'agent-account-sync)
               (lambda (backend account)
                 (push (cons backend account) events))))
      (let ((session (agent-session-create :backend 'one)))
        (agent-start-session session)
        (should (equal (agent-session-account session) "work"))))
    (should (equal captured-account "work"))
    (should (equal captured-starting '(one . "work")))
    (should (equal events '((one . "work"))))))

(ert-deftest agent-test-account-sync-reads-backend-account-slots ()
  "Sync shared symlinks through the real backend registry slots."
  (let* ((root (make-temp-file "agent-account-sync" t))
         (canonical (expand-file-name "canonical/" root))
         (home (expand-file-name "home/" root))
         (agent-backends nil)
         (inits nil))
    (unwind-protect
        (progn
          (make-directory canonical t)
          (with-temp-file (expand-file-name "settings.json" canonical)
            (insert "{\"shared\": true}"))
          (apply #'agent-register-backend
           'throwaway
           (agent-test--backend
            :accounts `(("work" . ,home))
            :canonical-home canonical
            :shared-config-items '("settings.json")
            :account-init (lambda (account) (push account inits))))
          (agent-account-sync 'throwaway "work")
          (let ((link (expand-file-name "settings.json" home)))
            (should (file-symlink-p link))
            (should (equal (file-truename link)
                           (file-truename
                            (expand-file-name "settings.json" canonical)))))
          (should (equal inits '("work"))))
      (delete-directory root t))))

;;;; Session state machine

(ert-deftest agent-test-session-event-stop-marks-awaiting-input ()
  "Transition sessions to awaiting-input on stop events."
  (let ((agent-backends nil)
        (agent-alert-on-ready nil))
    (with-temp-buffer
      (agent-session-event (current-buffer) 'stop)
      (should (eq agent--session-state 'awaiting-input))
      (should (floatp agent--session-state-changed-at)))))

(ert-deftest agent-test-session-event-idle-prompt-alerts ()
  "Fire the ready alert on idle-prompt events."
  (let ((agent-backends nil)
        notified)
    (with-temp-buffer
      (rename-buffer "*one:~/repo/project/:default*" t)
      (cl-letf (((symbol-function 'agent-notify)
                 (lambda (title message)
                   (setq notified (list title message)))))
        (agent-session-event (current-buffer) 'idle-prompt))
      (should (eq agent--session-state 'awaiting-input))
      (should (equal notified
                     '("Session ready"
                       "project: waiting for your response"))))))

(ert-deftest agent-test-notify-ready-dispatches-backend-notify ()
  "Dispatch the ready alert through the backend's notify slot."
  (let ((agent-backends nil)
        notified fallback)
    (with-temp-buffer
      (rename-buffer "*one:~/repo/project/:default*" t)
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :notify (lambda (title message)
                    (setq notified (list title message)))))
        (cl-letf (((symbol-function 'agent-notify)
                   (lambda (&rest args) (setq fallback args))))
          (agent--session-notify-ready buf))
        (should (equal notified
                       '("Test ready"
                         "project: waiting for your response")))
        (should-not fallback)))))

(ert-deftest agent-test-notify-ready-falls-back-to-agent-notify ()
  "Fall back to `agent-notify' when the backend lacks a notify slot."
  (let ((agent-backends nil)
        notified)
    (with-temp-buffer
      (rename-buffer "*one:~/repo/project/:default*" t)
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))))
        (cl-letf (((symbol-function 'agent-notify)
                   (lambda (title message)
                     (setq notified (list title message)))))
          (agent--session-notify-ready buf))
        (should (equal notified
                       '("Test ready"
                         "project: waiting for your response")))))))

(ert-deftest agent-test-session-event-stop-does-not-alert ()
  "Do not fire the ready alert on bare stop events."
  (let ((agent-backends nil)
        notified)
    (with-temp-buffer
      (cl-letf (((symbol-function 'agent-notify)
                 (lambda (&rest args) (setq notified args))))
        (agent-session-event (current-buffer) 'stop))
      (should-not notified))))

(ert-deftest agent-test-session-event-submit-marks-busy ()
  "Return sessions to busy when input is submitted while awaiting input."
  (with-temp-buffer
    (setq-local agent--session-state 'awaiting-input)
    (agent-session-event (current-buffer) 'submit)
    (should (eq agent--session-state 'busy))))

(ert-deftest agent-test-session-event-exit-request-marks-closing ()
  "Mark sessions closing on exit-request events."
  (with-temp-buffer
    (agent-session-event (current-buffer) 'exit-request)
    (should (eq agent--session-state 'closing))))

(ert-deftest agent-test-session-event-records-transition-times ()
  "Record a fresh timestamp on every session event."
  (let ((agent-backends nil)
        (agent-alert-on-ready nil))
    (with-temp-buffer
      (agent-session-event (current-buffer) 'stop)
      (let ((first agent--session-state-changed-at))
        (should (floatp first))
        (agent-session-event (current-buffer) 'submit)
        (should (>= agent--session-state-changed-at first))))))

(ert-deftest agent-test-session-event-rejects-unknown-events ()
  "Signal an error for unknown session events."
  (with-temp-buffer
    (should-error (agent-session-event (current-buffer) 'bogus))))

(ert-deftest agent-test-session-event-ignores-dead-buffers ()
  "Ignore session events delivered for killed buffers."
  (let ((buf (generate-new-buffer "agent-dead-test")))
    (kill-buffer buf)
    (should-not (agent-session-event buf 'stop))))

(ert-deftest agent-test-session-event-chain-suppresses-ready-alert ()
  "Suppress the ready alert when the before-exit chain consumes the event."
  (let ((agent-backends nil)
        notified)
    (with-temp-buffer
      (cl-letf (((symbol-function 'agent-notify)
                 (lambda (&rest args) (setq notified args)))
                ((symbol-function 'agent--before-exit-transition)
                 (lambda (_buffer _event) t)))
        (agent-session-event (current-buffer) 'idle-prompt))
      (should (eq agent--session-state 'awaiting-input))
      (should-not notified))))

(ert-deftest agent-test-session-event-submit-when-busy-is-noop ()
  "Ignore submit events when the session is already busy.
Backend submission hooks can multi-fire and fire on no-turn
submissions; a redundant submit must not refresh the transition
timestamp."
  (with-temp-buffer
    (setq-local agent--session-state 'busy)
    (agent-session-event (current-buffer) 'submit)
    (should (eq agent--session-state 'busy))
    (should-not agent--session-state-changed-at)))

;;;; Core send wrappers

(ert-deftest agent-test-send-string-emits-submit-and-dispatches ()
  "Emit a submit event, then dispatch to the backend send slot."
  (let ((agent-backends nil)
        events)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :send-command (lambda (cmd &optional buffer)
                          (push (list cmd buffer agent--session-state)
                                events))))
        (setq-local agent--session-state 'awaiting-input)
        (agent-send-string "hello" buf)
        (should (equal events (list (list "hello" buf 'busy))))))))

(ert-deftest agent-test-submit-prefers-atomic-submit-command ()
  "Dispatch through the backend's atomic submit slot when present."
  (let ((agent-backends nil)
        events)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :submit-command (lambda (cmd &optional _buffer)
                            (push (list 'submit cmd) events))
          :send-command (lambda (cmd &optional _buffer)
                          (push (list 'command cmd) events))))
        (agent-submit "/retro" buf)
        (should (equal events '((submit "/retro"))))))))

(ert-deftest agent-test-submit-falls-back-to-send-and-return ()
  "Compose send-command and send-return when no atomic submit exists."
  (let ((agent-backends nil)
        events)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :send-command (lambda (cmd &optional _buffer)
                          (push (list 'command cmd) events))
          :send-return (lambda (&optional _buffer) (push 'return events))))
        (agent-submit "/retro" buf)
        (should (equal (nreverse events) '((command "/retro") return)))))))

(ert-deftest agent-test-send-return-emits-submit-event ()
  "Return sessions to busy when the pending prompt is submitted."
  (let ((agent-backends nil)
        sent)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :send-return (lambda (&optional _buffer) (setq sent t))))
        (setq-local agent--session-state 'awaiting-input)
        (agent-send-return buf)
        (should sent)
        (should (eq agent--session-state 'busy))))))

(ert-deftest agent-test-send-string-rejects-slotless-backends ()
  "Signal a user error when the backend lacks the send slot."
  (let ((agent-backends nil))
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))))
        (should-error (agent-send-string "hello" buf) :type 'user-error)))))

(provide 'agent-test)
;;; agent-test.el ends here
