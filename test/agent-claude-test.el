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
      (setq-local agent--session-state-changed-at 100.0)
      (cl-letf (((symbol-function 'float-time) (lambda (&optional _) 205.0))
                ((symbol-function 'agent--scroll-to-bottom) #'ignore)
                ((symbol-function 'agent--refresh-display-names-deferred) #'ignore))
        (agent-session-event buf 'stop))
      (should (= agent--session-state-changed-at 100.0))
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

;; Hook wrappers deliver events in the background, so a tool event can
;; land after the stop event of the turn it belongs to.
(ert-deftest agent-claude-test-activity-sent-before-stop-is-ignored ()
  "Ignore an activity event sent before the session last began waiting."
  (let ((buf (generate-new-buffer "*claude:~/repo/project/:default*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (setq-local agent--session-state 'awaiting-input)
            (setq-local agent--session-last-waiting-event-at 200.0))
          (agent-claude--handle-session-state
           (list :type 'activity :buffer-name (buffer-name buf)
                 :args '("199.5")))
          (should (eq (buffer-local-value 'agent--session-state buf)
                      'awaiting-input))
          (agent-claude--handle-session-state
           (list :type 'activity :buffer-name (buffer-name buf)
                 :args '("200.5")))
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

;;;; Terminal idle detection

(defun agent-claude-test--with-fake-process (body)
  "Run BODY in a temp buffer that has a live dummy process."
  (with-temp-buffer
    (let ((proc (start-process "agent-claude-test-idle" (current-buffer)
                               "sleep" "30")))
      (unwind-protect
          (funcall body)
        (delete-process proc)))))

(ert-deftest agent-claude-test-terminal-waiting-detects-idle-prompt ()
  "An idle prompt with no interrupt hint is waiting even when state is stale."
  (agent-claude-test--with-fake-process
   (lambda ()
     (insert "\u2727 Baked for 59s\n\n\u276f \u00a0\n")
     (setq agent--session-state 'busy)
     (setq agent--session-state-changed-at (- (float-time) 60))
     (should (agent-claude--terminal-waiting-p (current-buffer))))))

(ert-deftest agent-claude-test-terminal-waiting-respects-running-turn ()
  "The interrupt hint means a turn is running, whatever the prompt shows."
  (agent-claude-test--with-fake-process
   (lambda ()
     (insert "\u2727 Baking\u2026 (esc to interrupt)\n\n\u276f \u00a0\n")
     (setq agent--session-state 'busy)
     (setq agent--session-state-changed-at (- (float-time) 60))
     (should-not (agent-claude--terminal-waiting-p (current-buffer))))))

(ert-deftest agent-claude-test-terminal-waiting-respects-spinner-line ()
  "The elapsed-time spinner line means a turn is running."
  (agent-claude-test--with-fake-process
   (lambda ()
     (insert "\u2722 Billowing\u2026 (4m 35s \u00b7 \u2193 6.7k tokens)\n\n\u276f \u00a0\n")
     (setq agent--session-state 'busy)
     (setq agent--session-state-changed-at (- (float-time) 60))
     (should-not (agent-claude--terminal-waiting-p (current-buffer))))))

(ert-deftest agent-claude-test-terminal-waiting-respects-background-task-wait ()
  "Waiting on a background task is a running turn, not user-blocked."
  (agent-claude-test--with-fake-process
   (lambda ()
     (insert "Waiting for task (esc to give additional instructions)\n\u276f \u00a0\n")
     (setq agent--session-state 'busy)
     (setq agent--session-state-changed-at (- (float-time) 60))
     (should-not (agent-claude--terminal-waiting-p (current-buffer))))))

(ert-deftest agent-claude-test-terminal-waiting-trusts-fresh-busy-state ()
  "A busy state younger than the grace period wins over the screen."
  (agent-claude-test--with-fake-process
   (lambda ()
     (insert "\u276f \u00a0\n")
     (setq agent--session-state 'busy)
     (setq agent--session-state-changed-at (float-time))
     (should-not (agent-claude--terminal-waiting-p (current-buffer))))))

(ert-deftest agent-claude-test-terminal-waiting-needs-process ()
  "A dead terminal never reports as waiting."
  (with-temp-buffer
    (insert "\u276f \u00a0\n")
    (should-not (agent-claude--terminal-waiting-p (current-buffer)))))

;;;; Background task detection

(defconst agent-claude-test--stop-payload
  "{\"session_id\":\"s\",\"hook_event_name\":\"Stop\",\"stop_hook_active\":false,\"background_tasks\":[{\"id\":\"boi38yr6f\",\"type\":\"shell\",\"status\":\"running\",\"description\":\"sleep 40\",\"command\":\"sleep 40\"},{\"id\":\"a460d36ea76c0bc45\",\"type\":\"subagent\",\"status\":\"completed\",\"description\":\"Run task\",\"agent_type\":\"general-purpose\"}],\"session_crons\":[]}"
  "A Stop hook payload as Claude Code 2.1.288 sends it, trimmed.")

(defmacro agent-claude-test--with-tasks-session (&rest body)
  "Run BODY in a session buffer whose status directory is a temporary one."
  (declare (indent 0) (debug t))
  `(let ((agent-claude-status-directory (make-temp-file "claude-status" t)))
     (unwind-protect
         (with-temp-buffer
           (setq agent-claude--status-uuid "test-uuid")
           ,@body)
       (delete-directory agent-claude-status-directory t))))

(defvar agent-claude-test--tasks-tick 0
  "Seconds added to successive tasks-file modification times.")

(defun agent-claude-test--write-tasks (payload)
  "Store hook PAYLOAD as the current session's tasks file."
  (let ((file (agent-claude--tasks-file (current-buffer))))
    (with-temp-file file (insert payload))
    ;; Give each write a distinct modification time.
    (set-file-times file (time-add (current-time)
                                   (cl-incf agent-claude-test--tasks-tick)))))

(ert-deftest agent-claude-test-running-task-ids-keeps-running-tasks ()
  "Only tasks whose status is running count."
  (should (equal (agent-claude--running-task-ids
                  (json-parse-string agent-claude-test--stop-payload
                                     :object-type 'plist :array-type 'list))
                 '("boi38yr6f"))))

(ert-deftest agent-claude-test-running-task-ids-skips-stopping-subagent ()
  "A SubagentStop payload's own subagent is not background work.
Its subagent's shell is, as in a session whose subagent finished while
its shell kept running."
  (should (equal (agent-claude--running-task-ids
                  '(:hook_event_name "SubagentStop" :agent_id "a1"
                    :background_tasks ((:id "a1" :status "running")
                                       (:id "b1" :status "running"))))
                 '("b1"))))

(ert-deftest agent-claude-test-running-task-ids-requires-the-field ()
  "A payload without `background_tasks' is an error, not an empty list."
  (should-error (agent-claude--running-task-ids '(:hook_event_name "Stop")))
  (should-not (agent-claude--running-task-ids
               '(:hook_event_name "Stop" :background_tasks nil))))

(ert-deftest agent-claude-test-has-background-tasks-reads-tasks-file ()
  "The latest tasks file decides whether the session has background work."
  (agent-claude-test--with-tasks-session
    (should-not (agent-claude--has-background-tasks-p (current-buffer)))
    (agent-claude-test--write-tasks agent-claude-test--stop-payload)
    (should (agent-claude--has-background-tasks-p (current-buffer)))
    (agent-claude-test--write-tasks
     "{\"hook_event_name\":\"Stop\",\"background_tasks\":[]}")
    (should-not (agent-claude--has-background-tasks-p (current-buffer)))))

(ert-deftest agent-claude-test-tasks-file-without-field-warns ()
  "A tasks file lacking `background_tasks' warns instead of passing silently."
  (agent-claude-test--with-tasks-session
    (agent-claude-test--write-tasks "{\"hook_event_name\":\"Stop\"}")
    (let (warnings)
      (cl-letf (((symbol-function 'display-warning)
                 (lambda (_type message &rest _) (push message warnings))))
        (should-not (agent-claude--background-tasks (current-buffer))))
      (should (string-match-p "no background_tasks field" (car warnings))))))

(ert-deftest agent-claude-test-record-background-tasks-script ()
  "The hook script stores its payload where the session reads it."
  (agent-claude-test--with-tasks-session
    (let ((process-environment
           (append (list "AGENT_SESSION_UUID=test-uuid"
                         (concat "AGENT_CLAUDE_STATUS_DIR="
                                 agent-claude-status-directory))
                   process-environment)))
      (with-temp-buffer
        (insert agent-claude-test--stop-payload)
        (should (zerop (call-process-region
                        (point-min) (point-max)
                        (expand-file-name "hooks/record-background-tasks.sh"
                                          agent-claude--package-directory)
                        nil nil nil)))))
    (should (equal (agent-claude--background-tasks (current-buffer))
                   '("boi38yr6f")))
    (should (equal (directory-files agent-claude-status-directory nil "tasks")
                   (list (file-name-nondirectory
                          (agent-claude--tasks-file (current-buffer))))))))

(defun agent-claude-test--run-hook (script payload)
  "Run hook SCRIPT on PAYLOAD as the current session's CLI would.
Return the exit status."
  (let ((process-environment
         (append (list "AGENT_SESSION_UUID=test-uuid"
                       (concat "AGENT_CLAUDE_STATUS_DIR="
                               agent-claude-status-directory))
                 process-environment)))
    (with-temp-buffer
      (insert payload)
      (call-process-region (point-min) (point-max)
                           (expand-file-name script
                                             agent-claude--package-directory)
                           nil nil nil))))

(ert-deftest agent-claude-test-record-session-id-writes-on-change ()
  "The status line's session id is written once per change."
  (agent-claude-test--with-tasks-session
    (let ((file (agent-claude--session-id-file (current-buffer))))
      (agent-claude--record-session-id (current-buffer) "s1")
      (should (equal (with-temp-buffer (insert-file-contents file)
                                       (buffer-string))
                     "s1"))
      (delete-file file)
      (agent-claude--record-session-id (current-buffer) "s1")
      (should-not (file-exists-p file))
      (agent-claude--record-session-id (current-buffer) "s2")
      (should (file-exists-p file)))))

(ert-deftest agent-claude-test-tasks-hook-drops-foreign-session ()
  "A payload from another session, such as a child `claude -p', is dropped."
  (agent-claude-test--with-tasks-session
    (agent-claude--record-session-id (current-buffer) "parent")
    (agent-claude-test--run-hook
     "hooks/record-background-tasks.sh"
     "{\"session_id\":\"child\",\"hook_event_name\":\"Stop\",\"background_tasks\":[]}")
    (should-not (file-exists-p (agent-claude--tasks-file (current-buffer))))
    (agent-claude-test--run-hook
     "hooks/record-background-tasks.sh"
     (replace-regexp-in-string "\"s\"" "\"parent\""
                               agent-claude-test--stop-payload))
    (should (equal (agent-claude--background-tasks (current-buffer))
                   '("boi38yr6f")))))

(ert-deftest agent-claude-test-session-owner-check ()
  "Only a payload naming a different recorded session is foreign."
  (agent-claude-test--with-tasks-session
    (let ((check (lambda (payload)
                   (let ((process-environment
                          (append (list "AGENT_SESSION_UUID=test-uuid"
                                        (concat "AGENT_CLAUDE_STATUS_DIR="
                                                agent-claude-status-directory))
                                  process-environment)))
                     (zerop (call-process
                             "bash" nil nil nil "-c"
                             ". \"$1\"; agent_hook_foreign_p \"$2\"" "check"
                             (expand-file-name "hooks/session-owner.sh"
                                               agent-claude--package-directory)
                             payload))))))
      (should-not (funcall check "{\"session_id\":\"child\"}"))
      (agent-claude--record-session-id (current-buffer) "parent")
      (should (funcall check "{\"session_id\":\"child\"}"))
      (should-not (funcall check "{\"session_id\":\"parent\"}"))
      (should-not (funcall check "{\"hook_event_name\":\"Stop\"}")))))

(ert-deftest agent-claude-test-stop-from-another-session-is-ignored ()
  "A Stop whose payload names another session leaves the session busy."
  (agent-claude-test--with-tasks-session
    (agent-claude--record-session-id (current-buffer) "parent")
    (let (events)
      (cl-letf (((symbol-function 'agent-session-event)
                 (lambda (_buffer event) (push event events))))
        (dolist (id '("child" "parent"))
          (agent-claude--handle-stop
           (list :type 'stop :buffer-name (buffer-name)
                 :json-data (format "{\"session_id\":\"%s\"}" id)))))
      (should (equal events '(stop))))))

(ert-deftest agent-claude-test-has-background-tasks-ignores-footer-counts ()
  "Footer task counts are not evidence; the fleet count spans all sessions."
  (with-temp-buffer
    (insert "⏵⏵ auto mode on · 1 shell · ← 2 agents\n")
    (should-not (agent-claude--has-background-tasks-p (current-buffer)))))

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

(ert-deftest agent-claude-test-parse-status-file-tolerates-partial-write ()
  "A status file caught empty or mid-write parses as nil instead of signaling.
An error escaping the status poll leaves its timer marked triggered
when `debug-on-error' is set, and Emacs never runs it again."
  (let ((agent-claude-status-directory (make-temp-file "claude-status" t)))
    (unwind-protect
        (with-temp-buffer
          (setq agent-claude--status-uuid "partial-write")
          (dolist (contents '("" "{\"session_id\":"))
            (with-temp-file (agent-claude--status-file)
              (insert contents))
            (should-not (agent-claude--parse-status-file))))
      (delete-directory agent-claude-status-directory t))))

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

;;;; Session settings

(defmacro agent-claude-test--with-session-dir (&rest body)
  "Run BODY with session settings written to a temporary directory."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "agent-claude-session" t))
          (agent-claude-session-settings-directory dir))
     (unwind-protect (progn ,@body)
       (delete-directory dir t))))

(defun agent-claude-test--hook-commands (settings event)
  "Return the commands SETTINGS runs for hook EVENT."
  (mapcan (lambda (group)
            (mapcar (lambda (hook) (gethash "command" hook))
                    (agent-claude--json-list (gethash "hooks" group))))
          (agent-claude--json-list (gethash event (gethash "hooks" settings)))))

(defun agent-claude-test--start-switches (extra &optional program-switches)
  "Return what `claude-code--start' receives for EXTRA and PROGRAM-SWITCHES.
The value is (PROGRAM-SWITCHES-SEEN . EXTRA-SWITCHES-SEEN)."
  (let ((claude-code-program-switches program-switches)
        (agent-claude-use-session-settings t))
    (agent-claude--start-with-session-settings
     (lambda (_arg extra-switches &rest _)
       (cons claude-code-program-switches extra-switches))
     nil extra)))

(ert-deftest agent-claude-test-session-settings-carry-every-hook ()
  "The session settings hold the status line and every hook agent needs."
  (let ((settings (agent-claude--session-settings)))
    (should (agent-claude--agent-statusline-p (gethash "statusLine" settings)))
    (dolist (event '("Stop" "Notification" "UserPromptSubmit" "PreToolUse"
                     "PostToolUse" "PostToolUseFailure" "SubagentStart"
                     "StopFailure" "SubagentStop"))
      (should (agent-claude-test--hook-commands settings event)))
    (should (seq-some (lambda (command)
                        (string-match-p "claude-code-hook-wrapper stop" command))
                      (agent-claude-test--hook-commands settings "Stop")))))

(ert-deftest agent-claude-test-session-settings-ignore-package-override ()
  "Session settings name the loaded checkout even when an override is set."
  (let* ((agent-claude-settings-package-directory "/nonexistent/agent/")
         (json (json-serialize (agent-claude--session-settings))))
    (should-not (string-match-p "/nonexistent/" json))
    (should (string-match-p (regexp-quote agent-claude--package-directory) json))))

(ert-deftest agent-claude-test-session-settings-keep-a-foreign-status-line ()
  "A status line the user passes is kept; agent's hooks are still added."
  (let* ((base (json-parse-string
                "{\"statusLine\": {\"type\": \"command\", \"command\": \"mine\"}}"))
         (settings (agent-claude--session-settings base)))
    (should (equal (gethash "command" (gethash "statusLine" settings)) "mine"))
    (should (agent-claude-test--hook-commands settings "Stop"))
    (should-not (gethash "hooks" base))))

(ert-deftest agent-claude-test-start-adds-one-settings-switch ()
  "A session started without `--settings' gets exactly one, pointing at agent's file."
  (agent-claude-test--with-session-dir
    (pcase-let ((`(,program . ,extra)
                 (agent-claude-test--start-switches '("--resume"))))
      (should (equal program nil))
      (should (equal (seq-take extra 2) '("--resume" "--settings")))
      (should (= (seq-count (lambda (s) (equal s "--settings")) extra) 1))
      (should (file-exists-p (nth 2 extra)))
      (should (equal (nth 2 extra)
                     (cadr (cdr (agent-claude-test--start-switches nil))))))))

(ert-deftest agent-claude-test-start-merges-inline-user-settings ()
  "Inline JSON the caller passes is merged, not overridden."
  (agent-claude-test--with-session-dir
    (pcase-let* ((user "{\"hooks\": {\"Stop\": [{\"hooks\": [{\"type\": \"command\", \"command\": \"user-stop\"}]}]}}")
                 (`(,_ . ,extra)
                  (agent-claude-test--start-switches (list "--settings" user))))
      (should (= (seq-count (lambda (s) (equal s "--settings")) extra) 1))
      (let ((settings (agent-claude--read-json-object (cadr (member "--settings" extra)))))
        (should (member "user-stop" (agent-claude-test--hook-commands settings "Stop")))
        (should (agent-claude--agent-statusline-p (gethash "statusLine" settings)))))))

(ert-deftest agent-claude-test-start-merges-program-switch-settings-file ()
  "A settings file in `claude-code-program-switches' moves into agent's file."
  (agent-claude-test--with-session-dir
    (let ((user-file (expand-file-name "user.json" agent-claude-session-settings-directory)))
      (with-temp-file user-file
        (insert "{\"env\": {\"FOO\": \"1\"}}"))
      (pcase-let ((`(,program . ,extra)
                   (agent-claude-test--start-switches
                    nil (list "--chrome" (concat "--settings=" user-file)))))
        (should (equal program '("--chrome")))
        (let ((settings (agent-claude--read-json-object (cadr (member "--settings" extra)))))
          (should (equal (gethash "FOO" (gethash "env" settings)) "1")))))))

(ert-deftest agent-claude-test-start-without-session-settings ()
  "With the option off, the switches pass through unchanged."
  (let ((agent-claude-use-session-settings nil)
        (claude-code-program-switches '("--settings" "x")))
    (should (equal (agent-claude--start-with-session-settings
                    (lambda (_arg extra &rest _) (cons claude-code-program-switches extra))
                    nil '("--resume"))
                   '(("--settings" "x") "--resume")))))

(ert-deftest agent-claude-test-session-settings-files-coexist ()
  "Different settings produce different files, and neither is overwritten."
  (agent-claude-test--with-session-dir
    (let ((plain (agent-claude--session-settings-file))
          (merged (agent-claude--session-settings-file
                   (json-parse-string "{\"env\": {\"A\": \"1\"}}"))))
      (should-not (equal plain merged))
      (should (file-exists-p plain))
      (should (file-exists-p merged))
      (should (= (file-modes plain) #o600))
      (should (equal (agent-claude--session-settings-file) plain)))))

(ert-deftest agent-claude-test-mode-installs-and-removes-start-advice ()
  "The start advice exists only while the mode is on."
  (let ((was agent-claude-mode))
    (unwind-protect
        (progn
          (agent-claude-mode 1)
          (should (advice-member-p #'agent-claude--start-with-session-settings
                                   'claude-code--start))
          (agent-claude-mode -1)
          (should-not (advice-member-p #'agent-claude--start-with-session-settings
                                       'claude-code--start)))
      (agent-claude-mode (if was 1 -1)))))

;;;; Global settings cleanup

(defconst agent-claude-test--global-settings
  (concat
   "{\"statusLine\": {\"type\": \"command\", \"command\": \"AGENT_CLAUDE_STATUS_DIR=/t /old/elpaca/sources/agent/etc/claude-code-statusline.sh\"},"
   " \"hooks\": {"
   "\"Stop\": ["
   "{\"matcher\": \"\", \"hooks\": [{\"type\": \"command\", \"command\": \"/old/elpaca/sources/claude-code/bin/claude-code-hook-wrapper stop\"}]},"
   "{\"hooks\": [{\"type\": \"command\", \"command\": \"/x/bin/claude-code-hook-wrapper stop\"}, {\"type\": \"command\", \"command\": \"mine\"}]},"
   "{\"hooks\": [{\"type\": \"command\", \"command\": \"/old/My\\\\ Drive/agent/hooks/record-background-tasks.sh\"}, {\"type\": \"command\", \"command\": \"keep-me\"}]}],"
   "\"Notification\": [{\"hooks\": [{\"type\": \"command\", \"command\": \"/old/agent/hooks/fire-and-forget.sh /old/agent/hooks/notify-emacs-notification.sh\"}]},"
   "{\"hooks\": [{\"type\": \"command\", \"command\": \"/dotfiles/claude/hooks/fire-and-forget.sh /dotfiles/claude/hooks/notify-emacs-notification.sh\"}]}]}}")
  "Global settings mixing agent entries from an old checkout with the user's.")

(ert-deftest agent-claude-test-remove-global-config-keeps-foreign-entries ()
  "Remove agent's entries from any checkout path, keeping everything else."
  (let ((file (make-temp-file "agent-claude-global" nil ".json")))
    (unwind-protect
        (progn
          (with-temp-file file (insert agent-claude-test--global-settings))
          (should (= (length (agent-claude-global-config-entries file)) 4))
          (should (= (agent-claude-remove-global-config file) 4))
          (let ((settings (agent-claude--read-json-object file)))
            (should-not (gethash "statusLine" settings))
            (should (equal (agent-claude-test--hook-commands settings "Stop")
                           '("/x/bin/claude-code-hook-wrapper stop" "mine" "keep-me")))
            (should (equal (agent-claude-test--hook-commands settings "Notification")
                           '("/dotfiles/claude/hooks/fire-and-forget.sh /dotfiles/claude/hooks/notify-emacs-notification.sh"))))
          (should-not (agent-claude-global-config-entries file)))
      (delete-file file))))

(ert-deftest agent-claude-test-remove-global-config-keeps-a-foreign-status-line ()
  "A status line agent did not write survives."
  (let ((file (make-temp-file "agent-claude-global" nil ".json")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "{\"statusLine\": {\"type\": \"command\", \"command\": \"mine\"}}"))
          (should (= (agent-claude-remove-global-config file) 0))
          (should (gethash "statusLine" (agent-claude--read-json-object file))))
      (delete-file file))))

;;;; Server environment

(ert-deftest agent-claude-test-server-env-names-the-running-socket ()
  "The env hook points emacsclient at this Emacs's server socket."
  (require 'server)
  (let ((server-process t)
        (server-use-tcp nil)
        (server-name "agent-test")
        (server-socket-dir "/tmp/emacs501/"))
    (should (equal (agent-claude--server-env "buf" "/tmp/")
                   '("EMACS_SOCKET_NAME=/tmp/emacs501/agent-test")))))

(ert-deftest agent-claude-test-server-env-names-the-tcp-server-file ()
  "A TCP server is named through its server file."
  (require 'server)
  (let ((server-process t)
        (server-use-tcp t)
        (server-name "agent-test")
        (server-auth-dir "/tmp/auth/"))
    (should (equal (agent-claude--server-env "buf" "/tmp/")
                   '("EMACS_SERVER_FILE=/tmp/auth/agent-test")))))

(ert-deftest agent-claude-test-server-env-without-server ()
  "Add nothing when this Emacs runs no server."
  (require 'server)
  (let ((server-process nil))
    (should-not (agent-claude--server-env "buf" "/tmp/"))))

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
        reported)
    (unwind-protect
        (cl-letf (((symbol-function 'agent-claude-cli-oauth-token)
                   (lambda (_config-dir) "token"))
                  ((symbol-function 'delete-process)
                   (lambda (process)
                     (setq deleted process)))
                  ((symbol-function 'url-retrieve)
                   (lambda (&rest args)
                     (push args calls)
                     (if (= (length calls) 1)
                         (signal 'file-error
                                 (list "Writing to process"
                                       "Invalid argument"
                                       proc))
                       :retrieved))))
          (should (eq (agent-claude--usage-fetch
                       "personal" (lambda (usage) (setq reported (list usage))))
                      :retrieved))
          (should (= (length calls) 2))
          (should (eq deleted proc))
          (should-not reported))
      (when (process-live-p proc)
        (delete-process proc)))))

(ert-deftest agent-claude-test-fetch-usage-reports-failure-after-retry-fails ()
  "Report a failed fetch instead of signaling when the retry also fails."
  (let ((proc (make-pipe-process :name "agent-usage-test" :noquery t))
        (calls 0)
        reported)
    (unwind-protect
        (cl-letf (((symbol-function 'agent-claude-cli-oauth-token)
                   (lambda (_config-dir) "token"))
                  ((symbol-function 'url-retrieve)
                   (lambda (&rest _args)
                     (setq calls (1+ calls))
                     (signal 'file-error
                             (list "Writing to process"
                                   "Invalid argument"
                                   proc)))))
          (agent-claude--usage-fetch
           "personal" (lambda (usage) (setq reported (list usage))))
          (should (= calls 2))
          (should (stringp (plist-get (car reported) :error))))
      (when (process-live-p proc)
        (delete-process proc)))))

(ert-deftest agent-claude-test-fetch-usage-reports-dns-failure ()
  "Report synchronous DNS failure once without retrying or debugging."
  (let ((calls 0)
        (debug-on-error t)
        reported)
    (cl-letf (((symbol-function 'agent-claude-cli-oauth-token)
               (lambda (_config-dir) "token"))
              ((symbol-function 'url-retrieve)
               (lambda (&rest _args)
                 (cl-incf calls)
                 (error "api.anthropic.com/443 nodename nor servname provided, or not known"))))
      (agent-claude--usage-fetch
       "personal" (lambda (usage) (push usage reported)))
      (should (= calls 1))
      (should (stringp (plist-get (car reported) :error))))))

(ert-deftest agent-claude-test-fetch-usage-reports-dns-failure-on-retry ()
  "Report DNS failure on the stale-process retry without a third attempt."
  (let ((proc (make-pipe-process :name "agent-usage-test" :noquery t))
        (calls 0)
        reported)
    (unwind-protect
        (cl-letf (((symbol-function 'agent-claude-cli-oauth-token)
                   (lambda (_config-dir) "token"))
                  ((symbol-function 'url-retrieve)
                   (lambda (&rest _args)
                     (if (= (cl-incf calls) 1)
                         (signal 'file-error
                                 (list "Writing to process" "Invalid argument" proc))
                       (error "api.anthropic.com/443 nodename nor servname provided, or not known")))))
          (agent-claude--usage-fetch
           "personal" (lambda (usage) (push usage reported)))
          (should (= calls 2))
          (should-not (process-live-p proc))
          (should (stringp (plist-get (car reported) :error))))
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
      (should (eq (agent-claude--usage-fetch "personal" #'ignore)
                  :retrieved))
      (should-not observed))))

(ert-deftest agent-claude-test-fetch-usage-reports-missing-token ()
  "Report failure without a request when the account has no OAuth token."
  (let (reported called)
    (cl-letf (((symbol-function 'agent-claude-cli-oauth-token) #'ignore)
              ((symbol-function 'url-retrieve)
               (lambda (&rest _args) (setq called t))))
      (agent-claude--usage-fetch
       "personal" (lambda (usage) (setq reported (list usage))))
      (should-not called)
      (should (stringp (plist-get (car reported) :error))))))

(ert-deftest agent-claude-test-normalize-usage ()
  "Normalize the usage endpoint's windows into the shared plist shape."
  (let ((usage (agent-claude--normalize-usage
                '(:five_hour (:utilization 42 :resets_at "2026-08-22T18:00:00Z")
                  :seven_day (:utilization 100 :resets_at "2026-08-25T00:00:00Z")))))
    (should (= (plist-get usage :session-pct) 42.0))
    (should (= (plist-get usage :weekly-pct) 100.0))
    (should (plist-get usage :limited))
    (should (equal (agent-usage-iso-time (plist-get usage :session-reset))
                   "2026-08-22T18:00:00Z"))))

(ert-deftest agent-claude-test-status-usage-reads-shared-store ()
  "Read session usage from the shared store keyed by the buffer's account."
  (let ((agent-usage--data (make-hash-table :test #'equal))
        (agent-usage-cache-file (make-temp-file "agent-usage")))
    (unwind-protect
        (with-temp-buffer
          (agent--set-session
           (current-buffer)
           (agent-session-create :backend 'claude-code :account "personal"
                                 :directory "~/repo/"))
          (agent-usage-record 'claude-code "personal"
                              '(:session-pct 12.0 :weekly-pct 34.0
                                :session-reset 1787423929.0))
          (should (= (agent-claude-status-session-usage) 12.0))
          (should (= (agent-claude-status-weekly-usage) 34.0))
          (should (equal (agent-claude-status-session-reset)
                         "2026-08-22T18:38:49Z"))
          (should-not (agent-claude-status-weekly-reset)))
      (delete-file agent-usage-cache-file))))

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
         (result (agent-claude--parse-stream-json raw)))
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
         (result (agent-claude--parse-stream-json raw)))
    (should (equal (plist-get result :text) "Part one\n\nPart two"))))

(ert-deftest agent-claude-test-batch-parse-stream-json-no-text ()
  "Produce fallback message when no assistant text is captured."
  (let* ((line (json-encode '(:type "result" :total_cost_usd 0.0
                               :session_id "s99" :num_turns 0 :subtype "timeout")))
         (raw line)
         (result (agent-claude--parse-stream-json raw)))
    (should (string-match-p "No assistant text captured" (plist-get result :text)))
    (should (string-match-p "s99" (plist-get result :text)))))

(ert-deftest agent-claude-test-batch-parse-stream-json-cost-usd-fallback ()
  "Use cost_usd when total_cost_usd is absent."
  (let* ((line (json-encode '(:type "result" :cost_usd 0.03
                               :session_id "s1" :num_turns 1 :subtype "ok")))
         (result (agent-claude--parse-stream-json line)))
    (should (= (plist-get result :cost) 0.03))))

(ert-deftest agent-claude-test-batch-parse-stream-json-malformed-lines ()
  "Malformed JSON lines are silently skipped."
  (let* ((good (json-encode '(:type "result" :total_cost_usd 0.01
                               :session_id "s1" :num_turns 1 :subtype "ok")))
         (raw (concat "not valid json\n" good))
         (result (agent-claude--parse-stream-json raw)))
    (should (= (plist-get result :cost) 0.01))))

(ert-deftest agent-claude-test-batch-parse-stream-json-empty-input ()
  "Empty input returns zero cost and fallback text."
  (let ((result (agent-claude--parse-stream-json "")))
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
                    (agent-claude--exec-process-environment)))
    (should (member "ANTHROPIC_AUTH_TOKEN=token"
                    (agent-claude--exec-process-environment)))))

(ert-deftest agent-claude-test-batch-env-strips-api-key-with-account ()
  "Strip conflicting auth when `CLAUDE_CONFIG_DIR' is set."
  (let ((process-environment '("ANTHROPIC_API_KEY=key"
                               "ANTHROPIC_AUTH_TOKEN=token"
                               "CLAUDE_CODE=1"))
        (agent-claude-accounts '(("work" . "/tmp/claude-work")))
        (agent-account--current (make-hash-table :test #'eq)))
    (puthash 'claude-code "work" agent-account--current)
    (let ((env (agent-claude--exec-process-environment)))
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

(ert-deftest agent-claude-test-source-directory-follows-build-symlink ()
  "Resolve a compiled build file to the checkout its source links to."
  (let* ((checkout (file-truename (make-temp-file "agent-src" t)))
         (build (make-temp-file "agent-build" t)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "agent-claude.el" checkout))
          (make-symbolic-link (expand-file-name "agent-claude.el" checkout)
                              (expand-file-name "agent-claude.el" build))
          (with-temp-file (expand-file-name "agent-claude.elc" build))
          (should (equal (agent-claude--source-directory
                          (expand-file-name "agent-claude.elc" build))
                         (file-name-as-directory checkout))))
      (delete-directory checkout t)
      (delete-directory build t))))

(ert-deftest agent-claude-test-bundled-helpers-exist ()
  "Find every bundled helper the setup commands install."
  (dolist (file (list agent-claude-statusline-script
                      (expand-file-name "fire-and-forget.sh"
                                        agent-claude--hooks-directory)
                      (expand-file-name "notify-emacs-notification.sh"
                                        agent-claude--hooks-directory)
                      (expand-file-name "notify-emacs-state.sh"
                                        agent-claude--hooks-directory)))
    (should (file-executable-p file))))

(ert-deftest agent-claude-test-ensure-state-hook-config-adds-each-event ()
  "Write one state hook per forwarded event, and only once."
  (let ((settings (make-temp-file "hooks-test" nil ".json")))
    (unwind-protect
        (progn
          (with-temp-file settings (insert "{}"))
          (should (agent-claude-ensure-state-hook-config settings))
          (should-not (agent-claude-ensure-state-hook-config settings))
          (let ((hooks (gethash "hooks"
                                (agent-claude--read-json-object settings))))
            (pcase-dolist (`(,name . ,type) agent-claude--state-hook-events)
              (let ((entries (append (gethash name hooks) nil)))
                (should (= (length entries) 1))
                (should (string-suffix-p
                         (concat "notify-emacs-state.sh " type)
                         (gethash "command"
                                  (aref (gethash "hooks" (car entries))
                                        0))))))))
      (delete-file settings))))

(ert-deftest agent-claude-test-ensure-state-hooks-replaces-other-checkouts ()
  "Replace a state hook from another checkout and keep unrelated commands."
  (let* ((settings (make-hash-table :test #'equal))
         (stale "/old/agent/hooks/fire-and-forget.sh /old/agent/hooks/notify-emacs-state.sh activity")
         (other (make-hash-table :test #'equal))
         (entry (make-hash-table :test #'equal))
         (hooks (make-hash-table :test #'equal)))
    (puthash "command" "other-tool --flag" other)
    (puthash "matcher" "" entry)
    (puthash "hooks" (vector (agent-claude--hook-command stale 5) other) entry)
    (puthash "PreToolUse" (vector entry) hooks)
    (puthash "hooks" hooks settings)
    (agent-claude--ensure-state-hooks settings)
    (let ((commands (mapcan (lambda (entry)
                              (mapcar (lambda (hook) (gethash "command" hook))
                                      (append (gethash "hooks" entry) nil)))
                            (append (gethash "PreToolUse" hooks) nil))))
      (should (member "other-tool --flag" commands))
      (should-not (member stale commands))
      (should (equal (seq-filter (lambda (command)
                                   (string-match-p "notify-emacs-state" command))
                                 commands)
                     (list (agent-claude--state-hook-command "activity")))))))

(ert-deftest agent-claude-test-ensure-background-hooks-installs-once ()
  "Install the tasks hook under Stop and SubagentStop, replacing stale copies."
  (let* ((settings (make-hash-table :test #'equal))
         (stale "AGENT_CLAUDE_STATUS_DIR=/x /old/agent/hooks/record-background-tasks.sh")
         (hooks (make-hash-table :test #'equal)))
    (puthash "Stop" (vector (agent-claude--hook-entry stale 5)) hooks)
    (puthash "hooks" hooks settings)
    (agent-claude--ensure-background-hooks settings)
    (agent-claude--ensure-background-hooks settings)
    (dolist (name agent-claude--background-hook-events)
      (should (equal (mapcan (lambda (entry)
                               (mapcar (lambda (hook) (gethash "command" hook))
                                       (append (gethash "hooks" entry) nil)))
                             (append (gethash name hooks) nil))
                     (list (agent-claude--background-hook-command)))))))

(ert-deftest agent-claude-test-settings-path-follows-configured-directory ()
  "Re-root bundled helpers under the configured settings directory."
  (let ((helper (expand-file-name "hooks/notify-emacs-state.sh"
                                  agent-claude--package-directory)))
    (let ((agent-claude-settings-package-directory nil))
      (should (equal (agent-claude--settings-path helper) helper)))
    (let ((agent-claude-settings-package-directory "/stable/agent/"))
      (should (equal (agent-claude--settings-path helper)
                     "/stable/agent/hooks/notify-emacs-state.sh"))
      (should (equal (agent-claude--settings-path "/elsewhere/tool.sh")
                     "/elsewhere/tool.sh")))))

(ert-deftest agent-claude-test-state-hook-script-forwards-event ()
  "Forward TYPE, the buffer name, and a send time to emacsclient."
  (let* ((bin (make-temp-file "agent-bin" t))
         (log (expand-file-name "args" bin))
         (script (expand-file-name "notify-emacs-state.sh"
                                   agent-claude--hooks-directory))
         (process-environment
          (append (list (concat "PATH=" bin ":" (getenv "PATH"))
                        "CLAUDE_BUFFER_NAME=*claude:\"q\"*")
                  (seq-remove (lambda (var)
                                (string-prefix-p "AGENT_SESSION_UUID=" var))
                              process-environment))))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "emacsclient" bin)
            (insert "#!/bin/sh\nprintf '%s\\n' \"$@\" > " log "\n"))
          (set-file-modes (expand-file-name "emacsclient" bin) #o755)
          (with-temp-buffer
            (insert "{}")
            (call-process-region (point-min) (point-max) script
                                 nil nil nil "activity"))
          (let* ((args (with-temp-buffer
                         (insert-file-contents log)
                         (split-string (buffer-string) "\n" t)))
                 (form (car (read-from-string (cadr args)))))
            (should (equal (car args) "--eval"))
            (should (equal (nth 1 (cadr form)) 'activity))
            (should (equal (nth 2 form) "*claude:\"q\"*"))
            (should (< (abs (- (string-to-number (nth 3 form)) (float-time)))
                       60))))
      (delete-directory bin t))))

(ert-deftest agent-claude-test-state-hook-script-skips-non-emacs-sessions ()
  "Do not call emacsclient for a Claude session outside Emacs."
  (let* ((bin (make-temp-file "agent-bin" t))
         (log (expand-file-name "args" bin))
         (script (expand-file-name "notify-emacs-state.sh"
                                   agent-claude--hooks-directory))
         (process-environment
          (cons (concat "PATH=" bin ":" (getenv "PATH"))
                (seq-remove (lambda (var)
                              (string-prefix-p "CLAUDE_BUFFER_NAME=" var))
                            process-environment))))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "emacsclient" bin)
            (insert "#!/bin/sh\ntouch " log "\n"))
          (set-file-modes (expand-file-name "emacsclient" bin) #o755)
          (call-process script nil nil nil "activity")
          (should-not (file-exists-p log)))
      (delete-directory bin t))))

;;;; Session state file

(defun agent-claude-test--state-hook-sends-p (status-dir uuid)
  "Return non-nil when the state hook calls emacsclient for an activity event.
Run the hook as session UUID with state files in STATUS-DIR."
  (let* ((bin (make-temp-file "agent-bin" t))
         (log (expand-file-name "called" bin))
         (process-environment
          (append (list (concat "PATH=" bin ":" (getenv "PATH"))
                        "CLAUDE_BUFFER_NAME=*claude:~/repo/:default*"
                        (concat "AGENT_SESSION_UUID=" uuid)
                        (concat "AGENT_CLAUDE_STATUS_DIR=" status-dir))
                  process-environment)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "emacsclient" bin)
            (insert "#!/bin/sh\ntouch " log "\n"))
          (set-file-modes (expand-file-name "emacsclient" bin) #o755)
          (with-temp-buffer
            (insert "{}")
            (call-process-region (point-min) (point-max)
                                 (expand-file-name "notify-emacs-state.sh"
                                                   agent-claude--hooks-directory)
                                 nil nil nil "activity"))
          (file-exists-p log))
      (delete-directory bin t))))

(ert-deftest agent-claude-test-state-hook-skips-only-busy-sessions ()
  "Skip emacsclient while Emacs records the session busy, and only then."
  (let ((agent-claude-status-directory
         (file-name-as-directory (make-temp-file "agent-status" t))))
    (unwind-protect
        (with-temp-buffer
          (setq-local agent-claude--status-uuid "uuid-state")
          (cl-letf (((symbol-function 'agent-claude--publisher-token)
                     (lambda (_) "uuid-state")))
            (should (agent-claude-test--state-hook-sends-p
                     agent-claude-status-directory "uuid-state"))
            (agent-claude--record-state (current-buffer) 'busy)
            (should-not (agent-claude-test--state-hook-sends-p
                         agent-claude-status-directory "uuid-state"))
            (should (agent-claude-test--state-hook-sends-p
                     agent-claude-status-directory "uuid-other"))
            (agent-claude--record-state (current-buffer) 'awaiting-input)
            (should (agent-claude-test--state-hook-sends-p
                     agent-claude-status-directory "uuid-state"))
            (agent-claude--record-state (current-buffer) 'busy)
            (agent-claude--cleanup-status-file)
            (should (agent-claude-test--state-hook-sends-p
                     agent-claude-status-directory "uuid-state"))))
      (delete-directory agent-claude-status-directory t))))

(ert-deftest agent-claude-test-state-change-records-state-file ()
  "A lifecycle transition rewrites the session's state file."
  (let ((agent-claude-status-directory
         (file-name-as-directory (make-temp-file "agent-status" t))))
    (unwind-protect
        (with-temp-buffer
          (setq-local agent-claude--status-uuid "uuid-transition")
          (cl-letf (((symbol-function 'agent-claude--publisher-token)
                     (lambda (_) "uuid-transition")))
            (agent--session-set-state (current-buffer) 'busy)
            (let ((file (agent-claude--state-file (current-buffer))))
              (should (equal (with-temp-buffer
                               (insert-file-contents file)
                               (buffer-string))
                             "busy")))))
      (delete-directory agent-claude-status-directory t))))

;;;; Interrupt detection

(ert-deftest agent-claude-test-interrupt-marks-idle-terminal-waiting ()
  "Mark a busy session waiting when its terminal is idle after an escape."
  (with-temp-buffer
    (let ((buf (current-buffer)))
      (setq-local agent--session-state 'busy)
      (setq-local agent--session-state-changed-at 100.0)
      (cl-letf (((symbol-function 'agent-claude--terminal-waiting-p)
                 (lambda (&optional _) t))
                ((symbol-function 'agent--scroll-to-bottom) #'ignore)
                ((symbol-function 'agent--refresh-display-names-deferred)
                 #'ignore))
        (agent-claude--check-interrupt buf 150.0))
      (should (eq agent--session-state 'awaiting-input)))))

(ert-deftest agent-claude-test-interrupt-check-needs-idle-terminal ()
  "Leave a session busy when the escape did not end its turn."
  (with-temp-buffer
    (let ((buf (current-buffer)))
      (setq-local agent--session-state 'busy)
      (setq-local agent--session-state-changed-at 100.0)
      (cl-letf (((symbol-function 'agent-claude--terminal-waiting-p)
                 (lambda (&optional _) nil)))
        (agent-claude--check-interrupt buf 150.0))
      (should (eq agent--session-state 'busy)))))

(ert-deftest agent-claude-test-interrupt-check-yields-to-later-state ()
  "Skip the check when the session changed state after the escape."
  (with-temp-buffer
    (let ((buf (current-buffer)))
      (setq-local agent--session-state 'busy)
      (setq-local agent--session-state-changed-at 160.0)
      (cl-letf (((symbol-function 'agent-claude--terminal-waiting-p)
                 (lambda (&optional _) t)))
        (agent-claude--check-interrupt buf 150.0))
      (should (eq agent--session-state 'busy)))))

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
        (cl-letf (((symbol-function 'agent-usage--poll) #'ignore)
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
        (cl-letf (((symbol-function 'agent-usage--poll) #'ignore)
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
        (cl-letf (((symbol-function 'agent-usage--poll) #'ignore)
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
        (cl-letf (((symbol-function 'agent-usage--poll) #'ignore)
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
        (cl-letf (((symbol-function 'agent-usage--poll) #'ignore)
                  ((symbol-function 'claude-code--find-all-claude-buffers)
                   (lambda () (list buf-a buf-b))))
          (agent-claude-start-usage-polling)
          (should agent-usage--timer)
          (agent-claude--maybe-stop-usage-polling buf-a)
          (should agent-usage--timer)
          (cl-letf (((symbol-function 'claude-code--find-all-claude-buffers)
                     (lambda () (list buf-b))))
            (agent-claude--maybe-stop-usage-polling buf-b)
            (should-not agent-usage--timer)))
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
                  ((symbol-function 'agent-usage--poll) #'ignore)
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
                  ((symbol-function 'agent-usage--poll) #'ignore))
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
