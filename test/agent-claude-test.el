;;; agent-claude-test.el --- Tests for agent-claude -*- lexical-binding: t -*-

;; Tests for pure and near-pure helper functions in agent-claude.el.

;;; Code:

(require 'ert)
(require 'json)
(require 'agent-account)
(require 'agent-claude)
(require 'agent-capture)

;;;; Handoff

(ert-deftest agent-claude-test-handoff-file-default-matches-skill ()
  "Use the path written by the Claude `/handoff' skill."
  (should (equal (alist-get 'claude-code agent-handoff-files)
                 "/tmp/claude-code-handoff.md")))

;;;; Prompt submission

(ert-deftest agent-claude-test-submit-command-targets-explicit-buffer ()
  "Submit commands to the explicit Claude buffer without prompting."
  (let (events)
    (with-temp-buffer
      (let ((buf (current-buffer))
            (claude-code-terminal-backend 'eat))
        (cl-letf (((symbol-function 'claude-code--buffer-p)
                   (lambda (candidate) (eq candidate buf)))
                  ((symbol-function 'claude-code--get-or-prompt-for-buffer)
                   (lambda () (error "Should not prompt for a buffer")))
                  ((symbol-function 'claude-code--term-send-string)
                   (lambda (_backend string)
                     (push (list (current-buffer) string) events)))
                  ((symbol-function 'display-buffer) #'ignore)
                  ((symbol-function 'sit-for) #'ignore))
          (should (eq (agent-claude-submit-command "/session-retro" buf)
                      buf))
          (should (equal (nreverse events)
                         (list (list buf "/session-retro")
                               (list buf (kbd "RET"))))))))))

;;;; Session event translation

(ert-deftest agent-claude-test-handle-stop-marks-awaiting-input ()
  "Mark Claude sessions awaiting input on CLI stop events."
  (let ((buf (generate-new-buffer "*claude:~/repo/project/:default*"))
        (agent-alert-on-ready nil))
    (unwind-protect
        (progn
          (agent-claude--handle-stop
           (list :type 'stop :buffer-name (buffer-name buf)))
          (should (eq (buffer-local-value 'agent--session-state buf)
                      'awaiting-input)))
      (kill-buffer buf))))

(ert-deftest agent-claude-test-idle-prompt-emits-idle-prompt-event ()
  "Translate idle_prompt notifications into idle-prompt session events."
  (let ((buf (generate-new-buffer "*claude:~/repo/project/:default*"))
        emitted)
    (unwind-protect
        (cl-letf (((symbol-function 'agent-session-event)
                   (lambda (buffer event) (setq emitted (list buffer event)))))
          (agent-claude--handle-notification
           (list :type 'notification
                 :buffer-name (buffer-name buf)
                 :json-data "{\"notification_type\":\"idle_prompt\"}"))
          (should (equal emitted (list buf 'idle-prompt))))
      (kill-buffer buf))))

(ert-deftest agent-claude-test-permission-prompt-uses-backend-label ()
  "Title permission alerts with the registered backend label."
  (let ((buf (generate-new-buffer "*claude:~/repo/project/:default*"))
        notified)
    (unwind-protect
        (cl-letf (((symbol-function 'agent-claude-notify)
                   (lambda (title message)
                     (setq notified (list title message)))))
          (agent-claude--handle-notification
           (list :type 'notification
                 :buffer-name (buffer-name buf)
                 :json-data "{\"notification_type\":\"permission_prompt\"}"))
          (should (equal notified
                         '("Claude Code needs approval"
                           "project: permission request pending"))))
      (kill-buffer buf))))

(ert-deftest agent-claude-test-new-prompt-id-marks-session-busy ()
  "Treat a fresh statusline prompt id as the start of a turn.
Claude Code reports no turn-start hook, so this is how turns the user
did not type become visible."
  (with-temp-buffer
    (let ((buf (current-buffer)))
      (setq-local agent--session-state 'awaiting-input)
      (setq-local agent--session-state-changed-at 100.0)
      (setq-local agent-claude--status-polled-at 200.0)
      (setq-local agent-claude--status-data '(:prompt_id "turn-one"))
      (agent-claude--detect-turn-start '(:prompt_id "turn-two") buf)
      (should (eq (buffer-local-value 'agent--session-state buf) 'busy)))))

(ert-deftest agent-claude-test-unchanged-prompt-id-leaves-state-alone ()
  "Do not disturb a waiting session while the same turn id persists."
  (with-temp-buffer
    (let ((buf (current-buffer)))
      (setq-local agent--session-state 'awaiting-input)
      (setq-local agent-claude--status-polled-at 200.0)
      (setq-local agent-claude--status-data '(:prompt_id "turn-one"))
      (agent-claude--detect-turn-start '(:prompt_id "turn-one") buf)
      (should (eq (buffer-local-value 'agent--session-state buf)
                  'awaiting-input)))))

(ert-deftest agent-claude-test-first-poll-does-not-mark-busy ()
  "Do not infer a turn start merely from beginning to observe a session."
  (with-temp-buffer
    (let ((buf (current-buffer)))
      (setq-local agent--session-state 'awaiting-input)
      (setq-local agent-claude--status-data nil)
      (agent-claude--detect-turn-start '(:prompt_id "turn-one") buf)
      (should (eq (buffer-local-value 'agent--session-state buf)
                  'awaiting-input)))))

(ert-deftest agent-claude-test-turn-shorter-than-poll-stays-waiting ()
  "Do not resurrect a turn that started and finished between two polls.
Its stop event has already landed, so marking the session busy would
strand it there until the next turn."
  (with-temp-buffer
    (let ((buf (current-buffer)))
      (setq-local agent-claude--status-polled-at 200.0)
      (setq-local agent--session-state 'awaiting-input)
      (setq-local agent--session-state-changed-at 205.0)
      (setq-local agent-claude--status-data '(:prompt_id "turn-one"))
      (agent-claude--detect-turn-start '(:prompt_id "turn-two") buf)
      (should (eq (buffer-local-value 'agent--session-state buf)
                  'awaiting-input)))))

(ert-deftest agent-claude-test-activity-event-marks-session-busy ()
  "Return a session to busy on evidence of work, with no user submission.
This is the case Claude Code reports no hook for: a turn the user did
not start, such as one resumed after a background task finishes."
  (let ((buf (generate-new-buffer "*claude:~/repo/project/:default*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (setq-local agent--session-state 'awaiting-input))
          (agent-claude--handle-session-state
           (list :type 'activity :buffer-name (buffer-name buf)))
          (should (eq (buffer-local-value 'agent--session-state buf) 'busy)))
      (kill-buffer buf))))

(ert-deftest agent-claude-test-blocked-hook-event-marks-session-waiting ()
  "Mark sessions blocked when the CLI reports they cannot proceed alone."
  (let ((buf (generate-new-buffer "*claude:~/repo/project/:default*")))
    (unwind-protect
        (progn
          (with-current-buffer buf (setq-local agent--session-state 'busy))
          (agent-claude--handle-session-state
           (list :type 'blocked :buffer-name (buffer-name buf)))
          (should (eq (buffer-local-value 'agent--session-state buf)
                      'awaiting-input)))
      (kill-buffer buf))))

(ert-deftest agent-claude-test-session-state-handler-ignores-other-events ()
  "Leave state alone for unrelated events and never consume the hook.
`claude-code-event-hook' runs with `run-hook-with-args-until-success',
so a non-nil return would stop later handlers from seeing the event."
  (let ((buf (generate-new-buffer "*claude:~/repo/project/:default*")))
    (unwind-protect
        (progn
          (with-current-buffer buf (setq-local agent--session-state 'busy))
          (should-not (agent-claude--handle-session-state
                       (list :type 'notification :buffer-name (buffer-name buf))))
          (should (eq (buffer-local-value 'agent--session-state buf) 'busy))
          (should-not (agent-claude--handle-session-state
                       (list :type 'activity :buffer-name "*claude:~/gone/*"))))
      (kill-buffer buf))))

(ert-deftest agent-claude-test-permission-prompt-marks-session-blocked ()
  "Show sessions stopped at a permission dialog as waiting for the user.
Claude reaches these from inside a turn, so without this the session
reads as busy while it is in fact blocked on an answer."
  (let ((buf (generate-new-buffer "*claude:~/repo/project/:default*")))
    (unwind-protect
        (cl-letf (((symbol-function 'agent-claude-notify) #'ignore))
          (with-current-buffer buf (setq-local agent--session-state 'busy))
          (agent-claude--handle-notification
           (list :type 'notification
                 :buffer-name (buffer-name buf)
                 :json-data "{\"notification_type\":\"permission_prompt\"}"))
          (should (eq (buffer-local-value 'agent--session-state buf)
                      'awaiting-input)))
      (kill-buffer buf))))

(ert-deftest agent-claude-test-elicitation-dialog-marks-session-blocked ()
  "Show sessions stopped at an MCP input dialog as waiting for the user."
  (let ((buf (generate-new-buffer "*claude:~/repo/project/:default*")))
    (unwind-protect
        (cl-letf (((symbol-function 'agent-claude-notify) #'ignore))
          (with-current-buffer buf (setq-local agent--session-state 'busy))
          (agent-claude--handle-notification
           (list :type 'notification
                 :buffer-name (buffer-name buf)
                 :json-data "{\"notification_type\":\"elicitation_dialog\"}"))
          (should (eq (buffer-local-value 'agent--session-state buf)
                      'awaiting-input)))
      (kill-buffer buf))))

(ert-deftest agent-claude-test-blocked-event-does-not-alert-ready ()
  "Do not fire a ready alert for `blocked' events.
The backend has already alerted about the dialog, so a second
notification would double-report the same interruption."
  (with-temp-buffer
    (let ((buf (current-buffer))
          notified)
      (cl-letf (((symbol-function 'agent--session-notify-ready)
                 (lambda (&rest _) (setq notified t))))
        (agent-session-event buf 'blocked)
        (should (eq (buffer-local-value 'agent--session-state buf)
                    'awaiting-input))
        (should-not notified)))))

(ert-deftest agent-claude-test-note-submission-emits-submit-event ()
  "Return Claude sessions to busy when a prompt is sent."
  (with-temp-buffer
    (let ((buf (current-buffer)))
      (setq-local agent--session-state 'awaiting-input)
      (cl-letf (((symbol-function 'claude-code--buffer-p)
                 (lambda (candidate) (eq candidate buf))))
        (agent-claude--note-submission))
      (should (eq agent--session-state 'busy)))))

(ert-deftest agent-claude-test-note-submission-ignores-other-buffers ()
  "Do not emit submit events from non-Claude buffers."
  (with-temp-buffer
    (setq-local agent--session-state 'awaiting-input)
    (cl-letf (((symbol-function 'claude-code--buffer-p)
               (lambda (_candidate) nil)))
      (agent-claude--note-submission))
    (should (eq agent--session-state 'awaiting-input))))

;;;; Background task detection

(ert-deftest agent-claude-test-has-background-tasks-detects-remote-control ()
  "Detect Claude's active Remote Control task UI as background work."
  (with-temp-buffer
    (insert "Remote Control active\n")
    (insert "  \342\227\257 general-purpose  Implement Task 6.8\n")
    (insert "13s\n")
    (should (agent-claude--has-background-tasks-p (current-buffer)))))

;;;; Restart

(ert-deftest agent-claude-test-restart-prompts-when-active-account-differs ()
  "Prompt for the restart account when it differs from the session account."
  (let ((dir (make-temp-file "claude-restart" t))
        (agent-prompt-capture-directory (make-temp-file "agent-prompts" t))
        captured-account captured-resume-id prompt-choices)
    (unwind-protect
        (with-temp-buffer
          (rename-buffer "*claude:~/project/:default*" t)
          (setq-local agent--session
                      (agent-session-create :backend 'claude-code
                                            :account "work"))
          (let ((agent-claude-accounts
                 `(("work" . ,(expand-file-name "work" dir))
                   ("personal" . ,(expand-file-name "personal" dir))))
                (agent-account--current (make-hash-table :test #'eq)))
            (puthash 'claude-code "personal" agent-account--current)
            (cl-letf (((symbol-function 'agent--force-kill-buffer) #'ignore)
                      ((symbol-function 'agent-claude--current-session-id)
                       (lambda () "0c5e1c5e-claude-session"))
                      ((symbol-function 'completing-read)
                       (lambda (_prompt choices &rest _args)
                         (setq prompt-choices choices)
                         "work"))
                      ((symbol-function 'agent-start-session)
                       (cl-function
                        (lambda (session &key resume-id &allow-other-keys)
                          (setq captured-account
                                (agent-session-account session))
                          (setq captured-resume-id resume-id)))))
              (agent-restart))))
      (delete-directory agent-prompt-capture-directory t)
      (delete-directory dir t))
    (should (equal prompt-choices '("personal" "work")))
    (should (equal captured-account "work"))
    (should (equal captured-resume-id "0c5e1c5e-claude-session"))))

(ert-deftest agent-claude-test-status-file-name-avoids-sanitizer-collisions ()
  "Distinct buffer names get distinct status files in the UUID-less fallback."
  (let (file-a file-b)
    (with-temp-buffer
      (rename-buffer "*claude:~/foo/bar/:default*" t)
      (setq file-a (agent-claude--status-file)))
    (with-temp-buffer
      (rename-buffer "*claude:~/foo_bar/:default*" t)
      (setq file-b (agent-claude--status-file)))
    (should-not (equal file-a file-b))))

(ert-deftest agent-claude-test-status-file-keyed-by-uuid ()
  "Two buffers with the same name but different UUIDs get distinct files."
  (with-temp-buffer
    (setq-local agent-claude--status-uuid "uuid-a")
    (let ((a (agent-claude--status-file)))
      (setq-local agent-claude--status-uuid "uuid-b")
      (should-not (equal a (agent-claude--status-file))))))

(ert-deftest agent-claude-test-status-uuid-env-shape ()
  "The env hook returns one AGENT_SESSION_UUID entry."
  (let ((entries (agent-claude--status-uuid-env "buf" "/tmp/")))
    (should (= (length entries) 1))
    (should (string-prefix-p "AGENT_SESSION_UUID=" (car entries)))))

;;;; Theme sync

(defun agent-claude-test--json-theme (file)
  "Return the `theme' value from JSON FILE."
  (with-temp-buffer
    (insert-file-contents file)
    (gethash "theme" (json-parse-buffer))))

(ert-deftest agent-claude-test-sync-theme-writes-config-files ()
  "Persist theme changes to Claude Code JSON config files."
  (let* ((dir (make-temp-file "claude-theme" t))
         (settings (expand-file-name ".claude/settings.json" dir))
         (legacy (expand-file-name ".claude.json" dir))
         (account (expand-file-name "account/.claude.json" dir)))
    (unwind-protect
        (progn
          (make-directory (file-name-directory settings) t)
          (make-directory (file-name-directory account) t)
          (with-temp-file settings
            (insert "{\"theme\":\"light\",\"other\":1}"))
          (with-temp-file legacy
            (insert "{\"theme\":\"light\",\"other\":1}"))
          (with-temp-file account
            (insert "{\"theme\":\"light\"}"))
          (cl-letf (((symbol-function 'agent-claude--theme-config-files)
                     (lambda () (list settings legacy account))))
            (should (= (agent-claude--sync-theme "dark") 3))
            (should (equal (agent-claude-test--json-theme settings)
                           "dark"))
            (should (equal (agent-claude-test--json-theme legacy)
                           "dark"))
            (should (equal (agent-claude-test--json-theme account)
                           "dark"))))
      (delete-directory dir t))))

(ert-deftest agent-claude-test-theme-config-files-prefers-settings ()
  "Sync modern settings files before legacy `.claude.json' files."
  (let* ((dir (make-temp-file "claude-theme" t))
         (settings (expand-file-name "settings.json" dir))
         (missing-settings (expand-file-name "missing/settings.json" dir))
         (legacy (expand-file-name ".claude.json" dir))
         (missing-legacy (expand-file-name "missing/.claude.json" dir)))
    (unwind-protect
        (progn
          (with-temp-file settings (insert "{}"))
          (with-temp-file legacy (insert "{}"))
          (cl-letf (((symbol-function 'agent-claude--all-claude-settings-paths)
                     (lambda () (list settings missing-settings)))
                    ((symbol-function 'agent-claude--all-claude-json-paths)
                     (lambda () (list legacy missing-legacy))))
            (should (equal (agent-claude--theme-config-files)
                           (list settings legacy)))))
      (delete-directory dir t))))

(ert-deftest agent-claude-test-sync-theme-skips-unchanged-config ()
  "Avoid rewriting Claude Code JSON files when the theme already matches."
  (let* ((dir (make-temp-file "claude-theme" t))
         (canonical (expand-file-name ".claude.json" dir)))
    (unwind-protect
        (progn
          (with-temp-file canonical
            (insert "{\"theme\":\"dark\"}"))
          (cl-letf (((symbol-function 'agent-claude--theme-config-files)
                     (lambda () (list canonical))))
            (should (= (agent-claude--sync-theme "dark") 0))))
      (delete-directory dir t))))

(ert-deftest agent-claude-test-sync-theme-errors-on-invalid-json ()
  "Do not overwrite an existing invalid Claude Code JSON file."
  (let* ((dir (make-temp-file "claude-theme" t))
         (canonical (expand-file-name ".claude.json" dir)))
    (unwind-protect
        (progn
          (with-temp-file canonical
            (insert "{"))
          (cl-letf (((symbol-function 'agent-claude--theme-config-files)
                     (lambda () (list canonical))))
            (should-error (agent-claude--sync-theme "dark")))
          (should (equal (with-temp-buffer
                           (insert-file-contents canonical)
                           (buffer-string))
                         "{")))
      (delete-directory dir t))))

;;;; Batch format prompt

(ert-deftest agent-claude-test-batch-format-prompt-title-only ()
  "Return title alone when body is empty."
  (should (equal (agent-claude--batch-format-prompt
                  '(:title "Fix the bug" :body ""))
                 "Fix the bug")))

(ert-deftest agent-claude-test-batch-format-prompt-title-and-body ()
  "Return title and body separated by blank line."
  (should (equal (agent-claude--batch-format-prompt
                  '(:title "Fix the bug" :body "See error in log"))
                 "Fix the bug\n\nSee error in log")))

(ert-deftest agent-claude-test-batch-format-prompt-nil-body ()
  "Return title alone when body is nil."
  (should (equal (agent-claude--batch-format-prompt
                  '(:title "Refactor module" :body nil))
                 "Refactor module")))

;;;; Status accessors

(ert-deftest agent-claude-test-status-model-present ()
  "Return display_name when model data is present."
  (let ((agent-claude--status-data
         '(:model (:display_name "Claude Opus 4"))))
    (should (equal (agent-claude-status-model) "Claude Opus 4"))))

(ert-deftest agent-claude-test-status-model-nil ()
  "Return nil when status data has no model."
  (let ((agent-claude--status-data nil))
    (should-not (agent-claude-status-model))))

(ert-deftest agent-claude-test-status-effort-present ()
  "Return level when effort data is present."
  (let ((agent-claude--status-data '(:effort (:level "high"))))
    (should (equal (agent-claude-status-effort) "high"))))

(ert-deftest agent-claude-test-status-effort-nil ()
  "Return nil when status data has no effort."
  (let ((agent-claude--status-data nil))
    (should-not (agent-claude-status-effort))))

(ert-deftest agent-claude-test-status-cost-present ()
  "Return total_cost_usd when cost data is present."
  (let ((agent-claude--status-data
         '(:cost (:total_cost_usd 0.42))))
    (should (= (agent-claude-status-cost) 0.42))))

(ert-deftest agent-claude-test-status-cost-nil ()
  "Return nil when status data has no cost."
  (let ((agent-claude--status-data nil))
    (should-not (agent-claude-status-cost))))

(ert-deftest agent-claude-test-status-context-percent ()
  "Return used_percentage from context_window data."
  (let ((agent-claude--status-data
         '(:context_window (:used_percentage 73.5))))
    (should (= (agent-claude-status-context-percent) 73.5))))

(ert-deftest agent-claude-test-status-context-percent-nil ()
  "Return nil when no context_window data."
  (let ((agent-claude--status-data nil))
    (should-not (agent-claude-status-context-percent))))

(ert-deftest agent-claude-test-status-token-count ()
  "Return total_input_tokens from context_window data."
  (let ((agent-claude--status-data
         '(:context_window (:total_input_tokens 50000))))
    (should (= (agent-claude-status-token-count) 50000))))

(ert-deftest agent-claude-test-status-token-count-nil ()
  "Return nil when no context_window data."
  (let ((agent-claude--status-data nil))
    (should-not (agent-claude-status-token-count))))

(ert-deftest agent-claude-test-status-lines-added ()
  "Return total_lines_added from cost data."
  (let ((agent-claude--status-data
         '(:cost (:total_lines_added 120))))
    (should (= (agent-claude-status-lines-added) 120))))

(ert-deftest agent-claude-test-status-lines-removed ()
  "Return total_lines_removed from cost data."
  (let ((agent-claude--status-data
         '(:cost (:total_lines_removed 30))))
    (should (= (agent-claude-status-lines-removed) 30))))

(ert-deftest agent-claude-test-status-duration-ms ()
  "Return total_duration_ms from cost data."
  (let ((agent-claude--status-data
         '(:cost (:total_duration_ms 12500))))
    (should (= (agent-claude-status-duration-ms) 12500))))

(ert-deftest agent-claude-test-status-cache-read-tokens ()
  "Return cache_read_input_tokens from current_usage."
  (let ((agent-claude--status-data
         '(:context_window (:current_usage (:cache_read_input_tokens 8000)))))
    (should (= (agent-claude-status-cache-read-tokens) 8000))))

(ert-deftest agent-claude-test-status-cache-read-tokens-nil ()
  "Return nil when current_usage is missing."
  (let ((agent-claude--status-data
         '(:context_window (:used_percentage 50))))
    (should-not (agent-claude-status-cache-read-tokens))))

(ert-deftest agent-claude-test-status-cache-total-tokens-all-fields ()
  "Sum input_tokens, cache_creation_input_tokens, and cache_read_input_tokens."
  (let ((agent-claude--status-data
         '(:context_window
           (:current_usage (:input_tokens 100
                            :cache_creation_input_tokens 200
                            :cache_read_input_tokens 300)))))
    (should (= (agent-claude-status-cache-total-tokens) 600))))

(ert-deftest agent-claude-test-status-cache-total-tokens-partial ()
  "Missing sub-fields default to zero in the sum."
  (let ((agent-claude--status-data
         '(:context_window
           (:current_usage (:cache_read_input_tokens 500)))))
    (should (= (agent-claude-status-cache-total-tokens) 500))))

(ert-deftest agent-claude-test-status-cache-total-tokens-nil ()
  "Return nil when current_usage is absent."
  (let ((agent-claude--status-data
         '(:context_window (:used_percentage 50))))
    (should-not (agent-claude-status-cache-total-tokens))))

;;;; Usage polling

(defvar url-http-attempt-keepalives)

(ert-deftest agent-claude-test-fetch-usage-retries-stale-url-process ()
  "Retry once when `url-retrieve' signals a stale process write error."
  (let ((proc (make-pipe-process :name "agent-usage-test" :noquery t))
        calls
        deleted
        backed-off)
    (unwind-protect
        (cl-letf (((symbol-function 'agent-claude-cli-oauth-token)
                   (lambda (_config-dir) "token"))
                  ((symbol-function 'delete-process)
                   (lambda (process)
                     (setq deleted process)))
                  ((symbol-function 'agent-claude--usage-backoff)
                   (lambda ()
                     (setq backed-off t)))
                  ((symbol-function 'url-retrieve)
                   (lambda (&rest args)
                     (push args calls)
                     (if (= (length calls) 1)
                         (signal 'file-error
                                 (list "Writing to process"
                                       "Invalid argument"
                                       proc))
                       :retrieved))))
          (should (eq (agent-claude--fetch-usage-for-account "personal")
                      :retrieved))
          (should (= (length calls) 2))
          (should (eq deleted proc))
          (should-not backed-off))
      (when (process-live-p proc)
        (delete-process proc)))))

(ert-deftest agent-claude-test-fetch-usage-backs-off-after-retry-fails ()
  "Back off instead of signaling when retrying a usage poll also fails."
  (let ((proc (make-pipe-process :name "agent-usage-test" :noquery t))
        (calls 0)
        backed-off)
    (unwind-protect
        (cl-letf (((symbol-function 'agent-claude-cli-oauth-token)
                   (lambda (_config-dir) "token"))
                  ((symbol-function 'agent-claude--usage-backoff)
                   (lambda ()
                     (setq backed-off t)
                     :backoff))
                  ((symbol-function 'url-retrieve)
                   (lambda (&rest _args)
                     (setq calls (1+ calls))
                     (signal 'file-error
                             (list "Writing to process"
                                   "Invalid argument"
                                   proc)))))
          (should (eq (agent-claude--fetch-usage-for-account "personal")
                      :backoff))
          (should (= calls 2))
          (should backed-off))
      (when (process-live-p proc)
        (delete-process proc)))))

(ert-deftest agent-claude-test-fetch-usage-disables-url-keepalives ()
  "Do not keep idle URL connections open for periodic usage polling."
  (let ((url-http-attempt-keepalives t)
        observed)
    (cl-letf (((symbol-function 'agent-claude-cli-oauth-token)
               (lambda (_config-dir) "token"))
              ((symbol-function 'url-retrieve)
               (lambda (&rest _args)
                 (setq observed url-http-attempt-keepalives)
                 :retrieved)))
      (should (eq (agent-claude--fetch-usage-for-account "personal")
                  :retrieved))
      (should-not observed))))

;;;; Display names

(ert-deftest agent-claude-test-display-name-adds-branch-suffix ()
  "Append Claude branch suffixes via the shared display-name hook."
  (with-temp-buffer
    (rename-buffer "*claude:~/repo/unique-claude-display-test/:default*" t)
    (let ((agent-claude--original-session-id "original-session")
          (agent-claude--status-data
           '(:session_id "branched-session-id")))
      (should (equal (agent-display-name (current-buffer))
                     "unique-claude-display-test:branched")))))

;;;; Batch parse stream JSON

(ert-deftest agent-claude-test-batch-parse-stream-json-assistant-text ()
  "Extract assistant text from stream-json output."
  (let* ((line1 (json-encode '(:type "assistant"
                                :message (:content [(:type "text" :text "Hello world")]))))
         (line2 (json-encode '(:type "result"
                                :total_cost_usd 0.05
                                :session_id "sess-123"
                                :num_turns 1
                                :subtype "success")))
         (raw (concat line1 "\n" line2))
         (result (agent-claude--batch-parse-stream-json raw)))
    (should (equal (plist-get result :text) "Hello world"))
    (should (= (plist-get result :cost) 0.05))
    (should (equal (plist-get result :session-id) "sess-123"))))

(ert-deftest agent-claude-test-batch-parse-stream-json-multiple-blocks ()
  "Multiple assistant text blocks are joined with double newlines."
  (let* ((line1 (json-encode '(:type "assistant"
                                :message (:content [(:type "text" :text "Part one")]))))
         (line2 (json-encode '(:type "assistant"
                                :message (:content [(:type "text" :text "Part two")]))))
         (line3 (json-encode '(:type "result" :total_cost_usd 0.1
                                :session_id "s1" :num_turns 2 :subtype "success")))
         (raw (concat line1 "\n" line2 "\n" line3))
         (result (agent-claude--batch-parse-stream-json raw)))
    (should (equal (plist-get result :text) "Part one\n\nPart two"))))

(ert-deftest agent-claude-test-batch-parse-stream-json-no-text ()
  "Produce fallback message when no assistant text is captured."
  (let* ((line (json-encode '(:type "result" :total_cost_usd 0.0
                               :session_id "s99" :num_turns 0 :subtype "timeout")))
         (raw line)
         (result (agent-claude--batch-parse-stream-json raw)))
    (should (string-match-p "No assistant text captured" (plist-get result :text)))
    (should (string-match-p "s99" (plist-get result :text)))))

(ert-deftest agent-claude-test-batch-parse-stream-json-cost-usd-fallback ()
  "Use cost_usd when total_cost_usd is absent."
  (let* ((line (json-encode '(:type "result" :cost_usd 0.03
                               :session_id "s1" :num_turns 1 :subtype "ok")))
         (result (agent-claude--batch-parse-stream-json line)))
    (should (= (plist-get result :cost) 0.03))))

(ert-deftest agent-claude-test-batch-parse-stream-json-malformed-lines ()
  "Malformed JSON lines are silently skipped."
  (let* ((good (json-encode '(:type "result" :total_cost_usd 0.01
                               :session_id "s1" :num_turns 1 :subtype "ok")))
         (raw (concat "not valid json\n" good))
         (result (agent-claude--batch-parse-stream-json raw)))
    (should (= (plist-get result :cost) 0.01))))

(ert-deftest agent-claude-test-batch-parse-stream-json-empty-input ()
  "Empty input returns zero cost and fallback text."
  (let ((result (agent-claude--batch-parse-stream-json "")))
    (should (= (plist-get result :cost) 0))
    (should (string-match-p "No assistant text captured" (plist-get result :text)))))

;;;; Batch build args

(ert-deftest agent-claude-test-batch-build-args-minimal ()
  "Build args with only required settings (no optional overrides)."
  (let ((claude-code-program "claude")
        (agent-claude-batch-max-turns 10)
        (agent-claude-batch-permission-mode nil)
        (agent-claude-batch-allowed-tools nil)
        (agent-claude-batch-system-prompt nil)
        (agent-claude-batch-model nil))
    (should (equal (agent-claude--build-cli-args "do stuff")
                   '("claude" "-p" "do stuff"
                     "--output-format" "stream-json"
                     "--verbose"
                     "--max-turns" "10")))))

(ert-deftest agent-claude-test-batch-build-args-with-tools ()
  "Include --allowedTools when batch-allowed-tools is set."
  (let ((claude-code-program "claude")
        (agent-claude-batch-max-turns 5)
        (agent-claude-batch-permission-mode nil)
        (agent-claude-batch-allowed-tools '("Read" "Write"))
        (agent-claude-batch-system-prompt nil)
        (agent-claude-batch-model nil))
    (let ((args (agent-claude--build-cli-args "test")))
      (should (member "--allowedTools" args))
      (should (member "Read,Write" args)))))

(ert-deftest agent-claude-test-batch-build-args-with-system-prompt ()
  "Include --append-system-prompt when batch-system-prompt is set."
  (let ((claude-code-program "claude")
        (agent-claude-batch-max-turns 5)
        (agent-claude-batch-permission-mode nil)
        (agent-claude-batch-allowed-tools nil)
        (agent-claude-batch-system-prompt "Be concise")
        (agent-claude-batch-model nil))
    (let ((args (agent-claude--build-cli-args "test")))
      (should (member "--append-system-prompt" args))
      (should (member "Be concise" args)))))

(ert-deftest agent-claude-test-batch-build-args-with-model ()
  "Include --model when batch-model is set."
  (let ((claude-code-program "claude")
        (agent-claude-batch-max-turns 5)
        (agent-claude-batch-permission-mode nil)
        (agent-claude-batch-allowed-tools nil)
        (agent-claude-batch-system-prompt nil)
        (agent-claude-batch-model "opus"))
    (let ((args (agent-claude--build-cli-args "test")))
      (should (member "--model" args))
      (should (member "opus" args)))))

(ert-deftest agent-claude-test-batch-build-args-all-options ()
  "All optional flags appear when all batch variables are set."
  (let ((claude-code-program "/usr/bin/claude")
        (agent-claude-batch-max-turns 20)
        (agent-claude-batch-permission-mode "bypassPermissions")
        (agent-claude-batch-allowed-tools '("Bash" "Read"))
        (agent-claude-batch-system-prompt "Be thorough")
        (agent-claude-batch-model "sonnet"))
    (let ((args (agent-claude--build-cli-args "hello")))
      (should (equal (car args) "/usr/bin/claude"))
      (should (member "--permission-mode" args))
      (should (member "bypassPermissions" args))
      (should (member "--allowedTools" args))
      (should (member "Bash,Read" args))
      (should (member "--append-system-prompt" args))
      (should (member "Be thorough" args))
      (should (member "--model" args))
      (should (member "sonnet" args))
      (should (member "--max-turns" args))
      (should (member "20" args)))))

(ert-deftest agent-claude-test-batch-env-preserves-api-key-without-account ()
  "Preserve `ANTHROPIC_API_KEY' when no account config is active."
  (let ((process-environment '("ANTHROPIC_API_KEY=key"
                               "ANTHROPIC_AUTH_TOKEN=token"
                               "CLAUDE_CODE=1"))
        (agent-claude-accounts nil)
        (agent-account--current (make-hash-table :test #'eq)))
    (should (member "ANTHROPIC_API_KEY=key"
                    (agent-claude--batch-process-environment)))
    (should (member "ANTHROPIC_AUTH_TOKEN=token"
                    (agent-claude--batch-process-environment)))))

(ert-deftest agent-claude-test-batch-env-strips-api-key-with-account ()
  "Strip conflicting auth when `CLAUDE_CONFIG_DIR' is set."
  (let ((process-environment '("ANTHROPIC_API_KEY=key"
                               "ANTHROPIC_AUTH_TOKEN=token"
                               "CLAUDE_CODE=1"))
        (agent-claude-accounts '(("work" . "/tmp/claude-work")))
        (agent-account--current (make-hash-table :test #'eq)))
    (puthash 'claude-code "work" agent-account--current)
    (let ((env (agent-claude--batch-process-environment)))
      (should (member "CLAUDE_CONFIG_DIR=/tmp/claude-work" env))
      (should-not (member "ANTHROPIC_API_KEY=key" env))
      (should-not (member "ANTHROPIC_AUTH_TOKEN=token" env))
      (should-not (member "CLAUDE_CODE=1" env)))))

(ert-deftest agent-claude-test-account-env-shadows-api-key-with-account ()
  "Shadow inherited API-key auth when an interactive account is active."
  (let ((agent-claude-accounts '(("work" . "/tmp/claude-work")))
        (agent-account--current (make-hash-table :test #'eq)))
    (puthash 'claude-code "work" agent-account--current)
    (should (equal (agent-claude-account-env "*claude*" "/tmp/project/")
                   '("CLAUDE_CONFIG_DIR=/tmp/claude-work"
                     "ANTHROPIC_API_KEY"
                     "ANTHROPIC_AUTH_TOKEN"
                     "CLAUDE_CODE")))))

(ert-deftest agent-claude-test-run-prompt-slot-normalizes-success ()
  "Translate the rich claude result plist into the normalized callback."
  (let (got)
    (cl-letf (((symbol-function 'agent-claude--run-prompt)
               (lambda (_prompt &rest kwargs)
                 (funcall (plist-get kwargs :callback)
                          '(:exit-code 0 :duration 1.0 :cost 0.01
                            :text "done" :session-id "sid" :raw "")))))
      (agent-claude-run-prompt "p" :directory "/tmp/"
                               :callback (cl-function
                                          (lambda (text &key error)
                                            (setq got (list text error)))))
      (should (equal got '("done" nil))))))

(ert-deftest agent-claude-test-run-prompt-slot-reports-error ()
  "Pass a non-nil :error to the normalized callback on failure."
  (let (got)
    (cl-letf (((symbol-function 'agent-claude--run-prompt)
               (lambda (_prompt &rest kwargs)
                 (funcall (plist-get kwargs :callback)
                          '(:exit-code 2 :duration 1.0 :cost 0
                            :text "boom" :session-id nil :raw "")))))
      (agent-claude-run-prompt "p"
                               :callback (cl-function
                                          (lambda (text &key error)
                                            (setq got (list text error)))))
      (should (equal (car got) "boom"))
      (should (string-match-p "exit code 2" (cadr got))))))

(ert-deftest agent-claude-test-diff-file-in-session-uses-directory-boundary ()
  "Do not treat sibling paths with the same prefix as inside a session."
  (let* ((session-dir (make-temp-file "agent-proj" t))
         (sibling-dir (concat (directory-file-name session-dir) "-other")))
    (unwind-protect
        (progn
          (make-directory sibling-dir)
          (with-temp-buffer
            (setq default-directory (file-name-as-directory sibling-dir))
            (cl-letf (((symbol-function 'monet--session-directory)
                       (lambda (_session) session-dir)))
              (should-not
               (agent-claude--diff-file-in-session-p
                (current-buffer) 'session)))))
      (delete-directory session-dir t)
      (delete-directory sibling-dir t))))

;;;; Has statusline key

(ert-deftest agent-claude-test-has-statusline-key-present ()
  "Return non-nil when buffer contains a statusLine JSON key."
  (with-temp-buffer
    (insert "{\n  \"statusLine\": {}\n}")
    (should (agent-claude--has-statusline-key-p))))

(ert-deftest agent-claude-test-has-statusline-key-absent ()
  "Return nil when buffer lacks a statusLine JSON key."
  (with-temp-buffer
    (insert "{\n  \"someOtherKey\": true\n}")
    (should-not (agent-claude--has-statusline-key-p))))

(ert-deftest agent-claude-test-has-statusline-key-empty ()
  "Return nil in an empty buffer."
  (with-temp-buffer
    (should-not (agent-claude--has-statusline-key-p))))

;;;; Has stop hook

(ert-deftest agent-claude-test-has-stop-hook-present ()
  "Return non-nil when buffer contains a Stop JSON key."
  (with-temp-buffer
    (insert "{\n  \"hooks\": {\n    \"Stop\": []\n  }\n}")
    (should (agent-claude--has-stop-hook-p))))

(ert-deftest agent-claude-test-has-stop-hook-absent ()
  "Return nil when buffer lacks a Stop JSON key."
  (with-temp-buffer
    (insert "{\n  \"hooks\": {}\n}")
    (should-not (agent-claude--has-stop-hook-p))))

(ert-deftest agent-claude-test-has-stop-hook-empty ()
  "Return nil in an empty buffer."
  (with-temp-buffer
    (should-not (agent-claude--has-stop-hook-p))))

;;;; Settings setup

(defun agent-claude-test--executable ()
  "Return a temporary executable file path."
  (let ((file (make-temp-file "agent-exec")))
    (set-file-modes file #o755)
    file))

(ert-deftest agent-claude-test-ensure-statusline-config-valid-empty-json ()
  "Write a valid statusLine object into an empty settings object."
  (let ((settings (make-temp-file "statusline-test" nil ".json"))
        (script (agent-claude-test--executable)))
    (unwind-protect
        (let ((agent-claude-statusline-script script))
          (with-temp-file settings (insert "{}"))
          (should (agent-claude-ensure-statusline-config settings))
          (let* ((data (agent-claude--read-json-object settings))
                 (statusline (gethash "statusLine" data)))
            (should (hash-table-p statusline))
            (should (string-match-p (regexp-quote script)
                                    (gethash "command" statusline)))
            (should (string-match-p "AGENT_CLAUDE_STATUS_DIR="
                                    (gethash "command" statusline)))
            (should (= (gethash "padding" statusline) 0))))
      (delete-file settings)
      (delete-file script))))

(ert-deftest agent-claude-test-ensure-statusline-config-replaces-stale-agent-command ()
  "Replace stale agent-owned statusLine commands."
  (let ((settings (make-temp-file "statusline-test" nil ".json"))
        (script (agent-claude-test--executable)))
    (unwind-protect
        (let ((agent-claude-statusline-script script))
          (with-temp-file settings
            (insert "{"
                    "\"statusLine\":{"
                    "\"type\":\"command\","
                    "\"command\":\"~/My\\\\ Drive/dotfiles/emacs/extras/etc/claude-code-statusline.sh\","
                    "\"padding\":0"
                    "}}"))
          (should (agent-claude-ensure-statusline-config settings))
          (let* ((data (agent-claude--read-json-object settings))
                 (statusline (gethash "statusLine" data))
                 (command (gethash "command" statusline)))
            (should (string-match-p (regexp-quote script) command))
            (should (string-match-p "AGENT_CLAUDE_STATUS_DIR=" command))))
      (delete-file settings)
      (delete-file script))))

(ert-deftest agent-claude-test-ensure-statusline-config-preserves-custom-command ()
  "Do not replace unrelated user statusLine commands."
  (let ((settings (make-temp-file "statusline-test" nil ".json"))
        (script (agent-claude-test--executable)))
    (unwind-protect
        (let ((agent-claude-statusline-script script))
          (with-temp-file settings
            (insert "{"
                    "\"statusLine\":{"
                    "\"type\":\"command\","
                    "\"command\":\"/usr/bin/custom-statusline\","
                    "\"padding\":0"
                    "}}"))
          (should-not (agent-claude-ensure-statusline-config settings))
          (let* ((data (agent-claude--read-json-object settings))
                 (statusline (gethash "statusLine" data)))
            (should (equal (gethash "command" statusline)
                           "/usr/bin/custom-statusline"))))
      (delete-file settings)
      (delete-file script))))

(ert-deftest agent-claude-test-ensure-hooks-config-valid-empty-json ()
  "Write Stop and Notification hooks into an empty settings object."
  (let ((settings (make-temp-file "hooks-test" nil ".json"))
        (wrapper (agent-claude-test--executable)))
    (unwind-protect
        (let ((agent-claude-hook-wrapper wrapper))
          (with-temp-file settings (insert "{}"))
          (should (agent-claude-ensure-stop-hook-config settings))
          (should (agent-claude-ensure-notification-hook-config settings))
          (let* ((data (agent-claude--read-json-object settings))
                 (hooks (gethash "hooks" data)))
            (should (hash-table-p hooks))
            (should (gethash "Stop" hooks))
            (should (gethash "Notification" hooks))))
      (delete-file settings)
      (delete-file wrapper))))

;;;; Batch collect todos

(ert-deftest agent-claude-test-batch-collect-todos-buffer-scope ()
  "Collect TODO entries from the entire buffer."
  (with-temp-buffer
    (org-mode)
    (insert "* TODO First task\nSome body text\n* TODO Second task\nMore body\n* DONE Finished\nDone body\n")
    (let ((entries (agent-claude--batch-collect-todos 'buffer)))
      (should (= (length entries) 2))
      (should (equal (plist-get (nth 0 entries) :title) "First task"))
      (should (string-match-p "Some body text" (plist-get (nth 0 entries) :body)))
      (should (equal (plist-get (nth 1 entries) :title) "Second task")))))

(ert-deftest agent-claude-test-batch-collect-todos-skips-done ()
  "DONE entries are excluded from the collected list."
  (with-temp-buffer
    (org-mode)
    (insert "* DONE Completed\nBody\n* TODO Active\nActive body\n")
    (let ((entries (agent-claude--batch-collect-todos 'buffer)))
      (should (= (length entries) 1))
      (should (equal (plist-get (nth 0 entries) :title) "Active")))))

(ert-deftest agent-claude-test-batch-collect-todos-empty-body ()
  "TODO entries with no body text get an empty string body."
  (with-temp-buffer
    (org-mode)
    (insert "* TODO No body entry\n* TODO Another entry\n")
    (let ((entries (agent-claude--batch-collect-todos 'buffer)))
      (should (= (length entries) 2))
      (should (equal (plist-get (nth 0 entries) :title) "No body entry"))
      (should (string-empty-p (plist-get (nth 0 entries) :body))))))

(ert-deftest agent-claude-test-batch-collect-todos-no-todos ()
  "Return nil when buffer has no TODO entries."
  (with-temp-buffer
    (org-mode)
    (insert "* Regular heading\nSome text\n* Another heading\n")
    (let ((entries (agent-claude--batch-collect-todos 'buffer)))
      (should (null entries)))))

(ert-deftest agent-claude-test-batch-collect-todos-subtree-scope ()
  "Collect only TODO entries within the current subtree."
  (with-temp-buffer
    (org-mode)
    (insert "* Parent\n** TODO Child task\nChild body\n** DONE Done child\n* TODO Outside\nOutside body\n")
    (goto-char (point-min))
    (save-restriction
      (org-narrow-to-subtree)
      (let ((entries (agent-claude--batch-collect-todos 'subtree)))
        (should (= (length entries) 1))
        (should (equal (plist-get (nth 0 entries) :title) "Child task"))))))

;;;; Session capture

(ert-deftest agent-claude-test-capture-session-stores-account ()
  "Replace a stale accountless struct when re-capturing the session."
  (with-temp-buffer
    (rename-buffer "*claude:~/repo/claude-capture-session-test/:default*" t)
    ;; Simulate lazy backfill running before the start binding existed.
    (agent--set-session
     (current-buffer)
     (agent-session-create :backend 'claude-code
                           :directory "~/repo/claude-capture-session-test/"))
    (let ((agent-account--starting '(claude-code . "personal")))
      (agent--capture-session (current-buffer))
      (let ((session (agent-session (current-buffer))))
        (should session)
        (should (eq (agent-session-backend session) 'claude-code))
        (should (equal (agent-session-account session) "personal"))
        (should (equal (agent-session-directory session)
                       "~/repo/claude-capture-session-test/"))
        (should (equal (agent-session-instance session) "default"))))))

;;;; Session id recording

(ert-deftest agent-claude-test-read-status-notes-session-id ()
  "Record the native session id from the status poll on the session struct."
  (with-temp-buffer
    (agent--set-session (current-buffer)
                        (agent-session-create :backend 'claude-code
                                              :directory "~/project/"))
    (cl-letf (((symbol-function 'agent-claude--parse-status-file)
               (lambda () '(:session_id "sid-1" :prompt_id "p1"))))
      (agent-claude--read-status (cons nil nil) (current-buffer))
      (should (equal (agent-session-id (agent-session)) "sid-1")))))

;;;; Parameterized session start

(ert-deftest agent-claude-test-start-session-injects-parameters ()
  "Route directory, instance, account, and switches through the wrapper."
  (let ((buffer (generate-new-buffer " *claude-test-session*"))
        captured-dir captured-instance captured-switches captured-account)
    (unwind-protect
        (cl-letf (((symbol-function 'agent-account-sync) #'ignore)
                  ((symbol-function 'claude-code--start)
                   (lambda (_arg switches &optional _force-prompt _force-switch)
                     (setq captured-dir (claude-code--directory))
                     (setq captured-instance
                           (claude-code--prompt-for-instance-name
                            "/elsewhere/" nil))
                     (setq captured-switches switches)
                     (setq captured-account (cdr-safe agent-account--starting))
                     buffer)))
          (let ((session (agent-session-create
                          :backend 'claude-code
                          :account "work"
                          :directory "/tmp/project/"
                          :instance "fix")))
            (should (eq (agent-start-session
                         session :resume-id "abc" :fork t
                         :initial-prompt "continue")
                        buffer))
            (should (equal captured-dir "/tmp/project/"))
            (should (equal captured-instance "fix"))
            (should (equal captured-switches
                           '("--resume" "abc" "--fork-session" "continue")))
            (should (equal captured-account "work"))
            (should (eq (agent-session buffer) session))))
      (kill-buffer buffer))))

;;;; Minor mode

(ert-deftest agent-claude-test-snippet-start-hook-function-is-autoloaded ()
  "Source-loaded Claude hooks reference an available snippet command."
  (should (memq 'agent-setup-scroll-keys
                agent-claude--start-hook-functions))
  (should (fboundp 'agent-setup-scroll-keys))
  (should (memq 'agent-setup-snippet-keys
                agent-claude--start-hook-functions))
  (should (fboundp 'agent-setup-snippet-keys)))

(ert-deftest agent-claude-test-mode-symmetric ()
  "Enabling then disabling the mode leaves global state untouched."
  (let ((claude-code-notification-function #'ignore)
        (claude-code-start-hook nil)
        (claude-code-event-hook nil)
        (claude-code-process-environment-functions nil)
        (agent-scroll-keys-global-mode nil)
        (kill-buffer-query-functions kill-buffer-query-functions))
    (agent-claude-mode 1)
    (should (memq #'agent-claude--handle-stop claude-code-event-hook))
    (should (memq #'agent-claude-account-env
                  claude-code-process-environment-functions))
    (should (eq claude-code-notification-function
                #'claude-code-default-notification))
    (should agent-scroll-keys-global-mode)
    (should (advice-member-p #'agent-claude--note-submission
                             'claude-code--do-send-command))
    (should (advice-member-p #'agent-claude--send-escape-in-current-buffer
                             'claude-code-send-escape))
    (agent-claude-mode -1)
    (should-not (memq #'agent-claude--handle-stop claude-code-event-hook))
    (should-not claude-code-start-hook)
    (should-not claude-code-process-environment-functions)
    (should (eq claude-code-notification-function #'ignore))
    (should-not agent-scroll-keys-global-mode)
    (should-not (advice-member-p #'agent-claude--note-submission
                                 'claude-code--do-send-command))
    (should-not (advice-member-p #'agent-claude--send-escape-in-current-buffer
                                 'claude-code-send-escape))
    (should-not agent-claude--monet-gc-timer)))

(ert-deftest agent-claude-test-mode-registers-existing-session-teardown ()
  "Enabling the mode registers teardown for already-live Claude buffers."
  (let ((buf (generate-new-buffer "*claude:~/repo/project/:default*"))
        (claude-code-notification-function #'ignore)
        (claude-code-start-hook nil)
        (claude-code-event-hook nil)
        (claude-code-process-environment-functions nil)
        (kill-buffer-query-functions kill-buffer-query-functions))
    (unwind-protect
        (cl-letf (((symbol-function 'agent-claude--fetch-usage) #'ignore)
                  ((symbol-function 'agent-claude--monet-install) #'ignore)
                  ((symbol-function 'agent-claude--monet-remove) #'ignore)
                  ((symbol-function 'claude-code--find-all-claude-buffers)
                   (lambda () (list buf))))
          (agent-claude-mode -1)
          (agent-claude-mode 1)
          (with-current-buffer buf
            (should (memq #'agent--session-teardown-current
                          kill-buffer-hook))
            (should (= (length agent--teardown-functions) 1))))
      (agent-claude-mode -1)
      (kill-buffer buf))))

(ert-deftest agent-claude-test-mode-adopts-existing-monet-session ()
  "Enabling the mode records Monet ownership for already-live buffers."
  (let ((buf (generate-new-buffer "*claude:~/repo/project/:default*"))
        (proc (make-process :name "agent-test-monet-server"
                            :command '("sleep" "60")
                            :noquery t))
        (sessions (make-hash-table :test 'equal))
        (claude-code-notification-function #'ignore)
        (claude-code-start-hook nil)
        (claude-code-event-hook nil)
        (claude-code-process-environment-functions nil)
        (kill-buffer-query-functions kill-buffer-query-functions))
    (unwind-protect
        (cl-letf (((symbol-function 'agent-claude--fetch-usage) #'ignore)
                  ((symbol-function 'agent-claude--monet-install) #'ignore)
                  ((symbol-function 'agent-claude--monet-remove) #'ignore)
                  ((symbol-function 'claude-code--buffer-p)
                   (lambda (candidate) (eq candidate buf)))
                  ((symbol-function 'claude-code--find-all-claude-buffers)
                   (lambda () (list buf)))
                  ((symbol-function 'monet--session-server)
                   (lambda (_session) proc)))
          (puthash (buffer-name buf) 'session sessions)
          (cl-progv '(monet--sessions) (list sessions)
            (agent-claude-mode -1)
            (agent-claude-mode 1)
            (with-current-buffer buf
              (should (equal agent-claude--monet-key (buffer-name buf)))
              (should (eq agent-claude--monet-server proc)))))
      (agent-claude-mode -1)
      (when (process-live-p proc) (delete-process proc))
      (kill-buffer buf))))

(ert-deftest agent-claude-test-existing-monet-session-teardown-survives-orphaning ()
  "Retrofitted teardown closes an existing server after Monet drops it."
  (let ((buf (generate-new-buffer "*claude:~/repo/project/:default*"))
        (proc (make-process :name "agent-test-monet-server"
                            :command '("sleep" "60")
                            :noquery t))
        (sessions (make-hash-table :test 'equal))
        (claude-code-notification-function #'ignore)
        (claude-code-start-hook nil)
        (claude-code-event-hook nil)
        (claude-code-process-environment-functions nil)
        (kill-buffer-query-functions kill-buffer-query-functions))
    (unwind-protect
        (cl-letf (((symbol-function 'agent-claude--fetch-usage) #'ignore)
                  ((symbol-function 'agent-claude--monet-install) #'ignore)
                  ((symbol-function 'agent-claude--monet-remove) #'ignore)
                  ((symbol-function 'claude-code--buffer-p)
                   (lambda (candidate) (eq candidate buf)))
                  ((symbol-function 'claude-code--find-all-claude-buffers)
                   (lambda () (list buf)))
                  ((symbol-function 'monet--session-server)
                   (lambda (_session) proc)))
          (puthash (buffer-name buf) 'session sessions)
          (cl-progv '(monet--sessions) (list sessions)
            (agent-claude-mode -1)
            (agent-claude-mode 1)
            (remhash (buffer-name buf) monet--sessions)
            (agent--session-teardown buf)
            (should-not (process-live-p proc))))
      (agent-claude-mode -1)
      (when (process-live-p proc) (delete-process proc))
      (kill-buffer buf))))

(ert-deftest agent-claude-test-mode-does-not-duplicate-existing-teardown ()
  "Mode re-enable does not duplicate teardown registered before reload."
  (let ((buf (generate-new-buffer "*claude:~/repo/project/:default*"))
        (claude-code-notification-function #'ignore)
        (claude-code-start-hook nil)
        (claude-code-event-hook nil)
        (claude-code-process-environment-functions nil)
        (kill-buffer-query-functions kill-buffer-query-functions))
    (unwind-protect
        (cl-letf (((symbol-function 'agent-claude--fetch-usage) #'ignore)
                  ((symbol-function 'agent-claude--monet-install) #'ignore)
                  ((symbol-function 'agent-claude--monet-remove) #'ignore)
                  ((symbol-function 'claude-code--find-all-claude-buffers)
                   (lambda () (list buf))))
          (with-current-buffer buf
            (add-hook 'kill-buffer-hook
                      #'agent--session-teardown-current nil t)
            (push #'ignore agent--teardown-functions))
          (agent-claude-mode -1)
          (agent-claude-mode 1)
          (with-current-buffer buf
            (should (= (length agent--teardown-functions) 1))))
      (agent-claude-mode -1)
      (kill-buffer buf))))

(ert-deftest agent-claude-test-usage-polling-refcount ()
  "Stop usage polling only when the last Claude session is torn down."
  (let ((buf-a (generate-new-buffer " *claude-usage-a*"))
        (buf-b (generate-new-buffer " *claude-usage-b*")))
    (unwind-protect
        (cl-letf (((symbol-function 'agent-claude--fetch-usage) #'ignore)
                  ((symbol-function 'claude-code--find-all-claude-buffers)
                   (lambda () (list buf-a buf-b))))
          (agent-claude-start-usage-polling)
          (should agent-claude--usage-timer)
          (agent-claude--maybe-stop-usage-polling buf-a)
          (should agent-claude--usage-timer)
          (cl-letf (((symbol-function 'claude-code--find-all-claude-buffers)
                     (lambda () (list buf-b))))
            (agent-claude--maybe-stop-usage-polling buf-b)
            (should-not agent-claude--usage-timer)))
      (agent-claude-stop-usage-polling)
      (kill-buffer buf-a)
      (kill-buffer buf-b))))

;;;; Monet leak reaping

(ert-deftest agent-claude-test-monet-close-server-kills-live-process ()
  "`agent-claude--monet-close-server' terminates a live server process."
  (let ((proc (make-process :name "agent-test-monet-server"
                            :command '("sleep" "60")
                            :noquery t)))
    (unwind-protect
        (progn
          (should (process-live-p proc))
          (agent-claude--monet-close-server proc)
          (should-not (process-live-p proc)))
      (when (process-live-p proc) (delete-process proc)))))

(ert-deftest agent-claude-test-monet-close-on-disconnect-reaps-server ()
  "Disconnect handler closes the session's leaked server process.
Reproduces the leak where `monet--on-close-server' dropped the
session but left its listening server alive until the GC sweep."
  (let ((proc (make-process :name "agent-test-monet-server"
                            :command '("sleep" "60")
                            :noquery t)))
    (unwind-protect
        (cl-letf (((symbol-function 'monet--session-server)
                   (lambda (_session) proc)))
          (should (process-live-p proc))
          (agent-claude--monet-close-server-on-disconnect 'fake-session)
          (should-not (process-live-p proc)))
      (when (process-live-p proc) (delete-process proc)))))

(ert-deftest agent-claude-test-monet-teardown-uses-started-key ()
  "Session teardown stops the Monet key captured when the server started."
  (let ((buffer (generate-new-buffer "*claude:renamed*"))
        (sessions (make-hash-table :test 'equal))
        (agent-claude--pending-monet-key nil)
        stopped)
    (unwind-protect
        (cl-letf (((symbol-function 'claude-code--buffer-p)
                   (lambda (candidate) (eq candidate buffer)))
                  ((symbol-function 'agent-claude--fetch-usage) #'ignore)
                  ((symbol-function 'agent-claude--monet-stop-session)
                   (lambda (key) (push key stopped))))
          (cl-progv '(monet--sessions) (list sessions)
            (agent-claude--monet-cleanup-before-start
             (lambda (_key _directory) 'session)
             "*claude:original*" "/tmp/project/")
            (with-current-buffer buffer
              (dolist (fn agent-claude--start-hook-functions)
                (when (memq fn '(agent-claude--capture-monet-key
                                 agent-claude--register-session-teardown))
                  (funcall fn))))
            (agent--session-teardown buffer)
            (should (equal stopped '("*claude:original*")))))
      (agent-claude-stop-usage-polling)
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest agent-claude-test-monet-start-captures-server-process ()
  "Capture the Monet server process owned by the started Claude session."
  (let ((buffer (generate-new-buffer "*claude:renamed*"))
        (proc (make-process :name "agent-test-monet-server"
                            :command '("sleep" "60")
                            :noquery t))
        (agent-claude--pending-monet-key nil))
    (unwind-protect
        (cl-letf (((symbol-function 'claude-code--buffer-p)
                   (lambda (candidate) (eq candidate buffer)))
                  ((symbol-function 'monet--session-server)
                   (lambda (_session) proc)))
          (agent-claude--monet-cleanup-before-start
           (lambda (_key _directory) 'session)
           "*claude:original*" "/tmp/project/")
          (with-current-buffer buffer
            (agent-claude--capture-monet-key))
          (should (equal (buffer-local-value 'agent-claude--monet-key buffer)
                         "*claude:original*"))
          (should (local-variable-p 'agent-claude--monet-server buffer))
          (should (eq (buffer-local-value 'agent-claude--monet-server buffer)
                      proc)))
      (when (process-live-p proc) (delete-process proc))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest agent-claude-test-monet-teardown-closes-captured-server-without-session ()
  "Session teardown closes a captured Monet server missing from Monet's table."
  (let ((buffer (generate-new-buffer "*claude:renamed*"))
        (sessions (make-hash-table :test 'equal))
        (proc (make-process :name "agent-test-monet-server"
                            :command '("sleep" "60")
                            :noquery t)))
    (unwind-protect
        (cl-letf (((symbol-function 'claude-code--buffer-p)
                   (lambda (candidate) (eq candidate buffer)))
                  ((symbol-function 'agent-claude--fetch-usage) #'ignore))
          (cl-progv '(monet--sessions) (list sessions)
            (with-current-buffer buffer
              (set (make-local-variable 'agent-claude--monet-key)
                   "*claude:original*")
              (set (make-local-variable 'agent-claude--monet-server) proc)
              (agent-claude--register-session-teardown))
            (agent--session-teardown buffer)
            (should-not (process-live-p proc))))
      (agent-claude-stop-usage-polling)
      (when (process-live-p proc) (delete-process proc))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest agent-claude-test-monet-gc-ignores-foreign-websocket-server ()
  "GC sweep leaves unregistered websocket servers from other packages alone.
Reproduces the false positive where atomic-chrome's listening server on
its fixed port was reported and deleted as a leaked monet server."
  (let ((foreign (make-network-process :name "websocket server on port 64292"
                                       :server t
                                       :host 'local
                                       :service t
                                       :noquery t))
        (agent-claude--monet-owned-servers nil)
        (sessions (make-hash-table :test 'equal))
        reported)
    (unwind-protect
        (cl-letf (((symbol-function 'agent--report-leak)
                   (lambda (&rest args) (push args reported))))
          (cl-progv '(monet--sessions) (list sessions)
            (agent-claude--monet-gc-orphaned-servers))
          (should (process-live-p foreign))
          (should-not reported))
      (when (process-live-p foreign) (delete-process foreign)))))

(ert-deftest agent-claude-test-monet-gc-reaps-registered-orphan ()
  "GC sweep reports and closes a registered server with no monet session."
  (let ((server (make-network-process :name "websocket server on port 0"
                                      :server t
                                      :host 'local
                                      :service t
                                      :noquery t))
        (agent-claude--monet-owned-servers nil)
        (sessions (make-hash-table :test 'equal))
        reported)
    (unwind-protect
        (cl-letf (((symbol-function 'agent--report-leak)
                   (lambda (&rest args) (push args reported))))
          (agent-claude--monet-register-server server)
          (cl-progv '(monet--sessions) (list sessions)
            (agent-claude--monet-gc-orphaned-servers))
          (should-not (process-live-p server))
          (should (= (length reported) 1))
          (should-not (memq server agent-claude--monet-owned-servers)))
      (when (process-live-p server) (delete-process server)))))

(ert-deftest agent-claude-test-monet-gc-keeps-registered-active-server ()
  "GC sweep leaves a registered server that monet still tracks."
  (let ((server (make-network-process :name "websocket server on port 0"
                                      :server t
                                      :host 'local
                                      :service t
                                      :noquery t))
        (agent-claude--monet-owned-servers nil)
        (sessions (make-hash-table :test 'equal))
        reported)
    (unwind-protect
        (cl-letf (((symbol-function 'agent--report-leak)
                   (lambda (&rest args) (push args reported)))
                  ((symbol-function 'monet--session-server)
                   (lambda (_session) server)))
          (puthash "*claude:active*" 'fake-session sessions)
          (agent-claude--monet-register-server server)
          (cl-progv '(monet--sessions) (list sessions)
            (agent-claude--monet-gc-orphaned-servers))
          (should (process-live-p server))
          (should-not reported)
          (should (memq server agent-claude--monet-owned-servers)))
      (when (process-live-p server) (delete-process server)))))

(ert-deftest agent-claude-test-monet-start-registers-server ()
  "Starting a monet session registers its server for the GC sweep."
  (let ((proc (make-process :name "agent-test-monet-server"
                            :command '("sleep" "60")
                            :noquery t))
        (agent-claude--monet-owned-servers nil)
        (agent-claude--pending-monet-key nil)
        (agent-claude--pending-monet-server nil)
        (sessions (make-hash-table :test 'equal)))
    (unwind-protect
        (cl-letf (((symbol-function 'monet--session-server)
                   (lambda (_session) proc)))
          (cl-progv '(monet--sessions) (list sessions)
            (agent-claude--monet-cleanup-before-start
             (lambda (_key _directory) 'session)
             "*claude:original*" "/tmp/project/"))
          (should (memq proc agent-claude--monet-owned-servers)))
      (when (process-live-p proc) (delete-process proc)))))

(ert-deftest agent-claude-test-monet-adopt-registers-server ()
  "Adopting an existing monet session registers its server for the sweep."
  (let ((buffer (generate-new-buffer "*claude:existing*"))
        (proc (make-process :name "agent-test-monet-server"
                            :command '("sleep" "60")
                            :noquery t))
        (agent-claude--monet-owned-servers nil)
        (sessions (make-hash-table :test 'equal)))
    (unwind-protect
        (cl-letf (((symbol-function 'monet--session-server)
                   (lambda (_session) proc)))
          (puthash (buffer-name buffer) 'fake-session sessions)
          (cl-progv '(monet--sessions) (list sessions)
            (with-current-buffer buffer
              (agent-claude--adopt-existing-monet-session)))
          (should (memq proc agent-claude--monet-owned-servers)))
      (when (process-live-p proc) (delete-process proc))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest agent-claude-test-session-headers-scan-the-transcript-project ()
  "Scan the project directory named by the buffer's status file."
  (let ((scanned nil))
    (cl-letf (((symbol-function 'agent-claude--parse-status-file)
               (lambda () '(:session_id "abc"
                            :transcript_path "/tmp/proj/abc.jsonl")))
              ((symbol-function 'agent-claude-cli-scan-session-headers)
               (lambda (dir) (setq scanned dir) 'headers)))
      (should (eq (agent-claude--session-headers (current-buffer)) 'headers))
      (should (equal scanned "/tmp/proj/")))))

(ert-deftest agent-claude-test-session-headers-without-a-status-file ()
  "Return nil rather than signalling when the status file is unavailable."
  (cl-letf (((symbol-function 'agent-claude--parse-status-file)
             (lambda () nil)))
    (should-not (agent-claude--session-headers (current-buffer)))))

(provide 'agent-claude-test)
;;; agent-claude-test.el ends here
