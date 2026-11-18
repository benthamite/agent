;;; agent-auto-test.el --- Tests for agent-auto -*- lexical-binding: t -*-

;; Tests for the sessions started unattended on tagged Org tasks, against
;; a stub backend whose sessions are plain buffers.

;;; Code:

(require 'ert)
(require 'agent-test-helper
         (expand-file-name "agent-test-helper.el"
                           (file-name-directory
                            (or load-file-name buffer-file-name))))
(require 'cl-lib)
(require 'benchmark)
(require 'org)
(require 'org-agenda)
(require 'agent-auto)
(require 'agent-org-linear)

(defvar agent-prompt-capture-directory)

;;;; Fixtures

(defvar agent-auto-test--started nil
  "The sessions the stub backend started, newest first.
Each is a cons of the `agent-session' and the options it was started with.")

(defvar agent-auto-test--buffers nil
  "The session buffers of the stub backend.")

(defvar agent-auto-test--start-error nil
  "When non-nil, the message of the error the stub backend's start signals.")

(defvar agent-auto-test--resume-error nil
  "When non-nil, the message of the error resuming a stub session signals.")

(defvar-local agent-auto-test--reply nil
  "The last reply of this stub session.")

(defvar agent-auto-test--submitted nil
  "What was submitted to stub sessions, the latest first.
Each element is a cons of the text and the session's buffer.")

(defun agent-auto-test--start-session (session &rest options)
  "Start a stub session for SESSION with OPTIONS and return its buffer."
  (when agent-auto-test--start-error
    (error "%s" agent-auto-test--start-error))
  (when (and agent-auto-test--resume-error (plist-get options :resume-id))
    (error "%s" agent-auto-test--resume-error))
  (let ((buffer (generate-new-buffer (agent-session-buffer-name session))))
    (push (cons session options) agent-auto-test--started)
    (push buffer agent-auto-test--buffers)
    (agent--set-session buffer session)
    buffer))

(defun agent-auto-test--history (buffer &rest _)
  "Return the history of stub session BUFFER: its one reply."
  (when-let* ((text (buffer-local-value 'agent-auto-test--reply buffer)))
    (list :messages (list (list :role "assistant" :text text :time "now"))
          :before nil)))

(defmacro agent-auto-test--with (root &rest body)
  "Evaluate BODY with a stub backend and ROOT bound to a new directory.
The hooks `agent-auto-mode' installs are in place and the mode reads as
on, without its timer: a test runs a search with `agent-auto-test--run'.  Tasks name their
directory in the property DIR, and worktrees go under ROOT."
  (declare (indent 1) (debug (symbolp body)))
  `(agent-test-helper-with-directory ,root
     (let ((agent-backends nil)
           (agent-auto-test--started nil)
           (agent-auto-test--buffers nil)
           (agent-auto-test--start-error nil)
           (agent-auto-test--resume-error nil)
           (agent-auto-test--submitted nil)
           (agent-before-exit-skill-names nil)
           (agent-before-exit-skill-name nil)
           (agent-before-exit-skill-directories nil)
           (agent-todo-directory-property "DIR")
           (agent-todo-in-progress-keyword nil)
           (agent-account-directory-rules nil)
           (agent-auto-files nil)
           (org-agenda-files nil)
           (agent-auto-eligible-functions nil)
           (agent-auto-backend nil)
           (agent-todo-backend nil)
           (agent-auto-instructions "Standing.")
           (agent-auto-silence-timeout 30)
           (agent-auto--pending nil)
           (agent-auto--handovers nil)
           (agent-auto--last-handover-id nil)
           (agent-auto--flush-timer nil)
           (agent-auto-handover-directory (expand-file-name "handovers/" ,root))
           (agent-auto-wait-instructions "")
           (agent-auto-waiting-keyword "WAITING")
           (agent-auto-wait-over-functions nil)
           (agent-auto--returning nil)
           (agent-before-exit-step-functions (list #'agent-auto--handover-step))
           (after-save-hook (list #'agent-auto--after-save))
           (org-log-into-drawer t)
           (agent-auto--missing (make-hash-table :test #'equal))
           (agent-auto--starting nil)
           (agent-auto--queue nil)
           (agent-auto--queue-timer nil)
           (agent-auto--processes nil)
           (agent-branch-worktree-directory (expand-file-name "worktrees/" ,root))
           (agent-prompt-capture-directory (expand-file-name "prompts/" ,root))
           (agent-session-event-functions (list #'agent-auto--on-event))
           (agent-session-id-functions (list #'agent-auto--on-id))
           (agent-delivery-functions (list #'agent-auto--record-delivery))
           (agent-before-delivery-functions
            (list #'agent-auto--confirm-delivery))
           (agent-auto--approved nil)
           (agent-auto-mode t)
           (agent-recorded-session-functions
            (list #'agent-auto--recorded-session))
           (agent-session-state-change-functions
            (list #'agent-auto--schedule-marks))
           (agent-auto--marks-timer nil)
           (agent-auto-working-mark "▶")
           (agent-auto-waiting-mark "⏸")
           (agent-session-inherited-variables
            '(agent-auto--link agent-auto--unattended)))
       (agent-register-backend
        'stub
        :buffer-p (lambda (&optional buffer)
                    (memq (or buffer (current-buffer))
                          agent-auto-test--buffers))
        :find-all-buffers (lambda ()
                            (seq-filter #'buffer-live-p
                                        agent-auto-test--buffers))
        :label "Stub"
        :start-session #'agent-auto-test--start-session
        :session-identity (lambda (buffer)
                            (agent-session-id (agent-session buffer)))
        :session-history #'agent-auto-test--history)
       (unwind-protect
           (cl-letf (((symbol-function 'display-buffer) #'ignore))
             ,@body)
         (agent-auto--reset)
         (agent-auto-test--kill-buffers ,root)))))

(defun agent-auto-test--kill-buffers (root)
  "Kill the stub sessions and the buffers visiting files under ROOT."
  (let ((kill-buffer-query-functions nil)
        (root (file-truename root)))
    (dolist (buffer agent-auto-test--buffers)
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))
    (dolist (buffer (buffer-list))
      (when-let* ((file (buffer-file-name buffer))
                  ((string-prefix-p root (file-truename file))))
        (with-current-buffer buffer
          (set-buffer-modified-p nil))
        (kill-buffer buffer)))))

(defun agent-auto-test--file (root contents &optional name)
  "Write CONTENTS to an Org file NAME under ROOT and search it; return it."
  (let ((file (expand-file-name (or name "tasks.org") root)))
    (write-region contents nil file nil 'silent)
    (setq agent-auto-files (append agent-auto-files (list file)))
    file))

(defun agent-auto-test--run ()
  "Search for tasks and run every step of the search to its end."
  (agent-auto--tick)
  (agent-auto-test--drain))

(defun agent-auto-test--drain ()
  "Run the steps and wait for the subprocesses until none is left."
  (let ((limit (+ (float-time) 30)))
    (while (or agent-auto--queue agent-auto--processes)
      (when (> (float-time) limit)
        (ert-fail "The search did not finish"))
      (if agent-auto--queue
          (agent-auto--run-step)
        (accept-process-output nil 0.02)))))

(defun agent-auto-test--at (file heading function)
  "Call FUNCTION on HEADING in the buffer visiting FILE."
  (with-current-buffer (find-file-noselect file)
    (org-with-wide-buffer
     (goto-char (point-min))
     (re-search-forward (format "^\\*+ .*%s" (regexp-quote heading)))
     (org-back-to-heading t)
     (funcall function))))

(defun agent-auto-test--tags (file heading)
  "Return the tags of HEADING in FILE."
  (agent-auto-test--at file heading
                       (lambda () (mapcar #'substring-no-properties
                                          (org-get-tags nil t)))))

(defun agent-auto-test--property (file heading property)
  "Return the value of PROPERTY on HEADING in FILE."
  (agent-auto-test--at file heading (lambda () (org-entry-get nil property))))

(defun agent-auto-test--disk (file)
  "Return the contents of FILE on disk."
  (with-temp-buffer
    (insert-file-contents file)
    (buffer-string)))

(defun agent-auto-test--end-turn (buffer reply)
  "End the turn of stub session BUFFER with REPLY as its last reply."
  (with-current-buffer buffer
    (setq agent-auto-test--reply reply))
  (run-hook-with-args 'agent-session-event-functions buffer 'stop)
  (agent-auto--turn-end buffer))

(defun agent-auto-test--take-text ()
  "Make the stub backend take text and skills submitted to its sessions.
What is submitted is recorded in `agent-auto-test--submitted'."
  (let ((backend (agent-backend 'stub)))
    (setf (agent-backend-skill-command-prefix backend) "/"
          (agent-backend-submit backend)
          (lambda (text &optional buffer)
            (push (cons text buffer) agent-auto-test--submitted)))))

(defmacro agent-auto-test--exiting (&rest body)
  "Evaluate BODY with an exit chain that runs no watchdog and exits nothing.
The session a chain would exit is left open."
  (declare (indent 0) (debug (body)))
  `(cl-letf (((symbol-function 'agent--before-exit-start-watchdog) #'ignore)
             ((symbol-function 'agent--exit-session) #'ignore))
     ,@body))

(defun agent-auto-test--task (root &optional heading tags)
  "Return the text of a ready TODO named HEADING whose directory is ROOT.
TAGS replaces its tag string."
  (format "* TODO %s %s\n:PROPERTIES:\n:DIR: %s\n:END:\nThe body.\n"
          (or heading "Fix it") (or tags ":agent:") root))

(defun agent-auto-test--started-task (root)
  "Start the one task of a new file under ROOT; return (FILE . BUFFER)."
  (let ((file (agent-auto-test--file root (agent-auto-test--task root))))
    (agent-auto-test--run)
    (should (= (length agent-auto-test--started) 1))
    (cons file (car agent-auto-test--buffers))))

(defun agent-auto-test--git (directory &rest arguments)
  "Run git with ARGUMENTS in DIRECTORY, failing the test when it fails."
  (let ((default-directory directory))
    (with-temp-buffer
      (unless (zerop (apply #'call-process "git" nil t nil
                            "-c" "user.name=Test" "-c" "user.email=t@example.org"
                            "-c" "commit.gpgsign=false" arguments))
        (ert-fail (format "git %s: %s" arguments (buffer-string)))))))

(defun agent-auto-test--repository (root name)
  "Create a Git repository NAME under ROOT with one commit; return it."
  (let ((repo (file-name-as-directory (expand-file-name name root))))
    (make-directory repo t)
    (agent-auto-test--git repo "init" "-q")
    (write-region "x\n" nil (expand-file-name "README" repo) nil 'silent)
    (agent-auto-test--git repo "add" "README")
    (agent-auto-test--git repo "commit" "-q" "--no-verify" "-m" "First")
    repo))

;;;; Starting

(ert-deftest agent-auto-test-starts-a-ready-task ()
  "Start a session on a tagged TODO, in its directory, with it as the brief.
The directory is inherited from the heading above.  The brief is the
heading and the body, then the standing instructions, and it is
submitted.  The task records the session and when it started, on disk."
  (agent-auto-test--with root
    (let ((file (agent-auto-test--file
                 root (format "* Project\n:PROPERTIES:\n:DIR: %s\n:END:\n** TODO Fix it :agent:\nThe body.\n"
                              root))))
      (agent-auto-test--run)
      (should (= (length agent-auto-test--started) 1))
      (pcase-let ((`(,session . ,options) (car agent-auto-test--started))
                  (buffer (car agent-auto-test--buffers)))
        (should (equal (agent-session-directory session) root))
        (should (equal (agent-session-instance session) "fix-it"))
        (should (buffer-local-value 'agent--named buffer))
        (should (equal (agent-display-name buffer)
                       (format "%s:fix-it"
                               (agent--directory-project-name root))))
        (should (equal (plist-get options :initial-prompt)
                       "Fix it\n\nThe body.\n\nStanding."))
        (should (equal (agent-auto-test--property file "Fix it" "AGENT_SESSION")
                       (buffer-name buffer)))
        (should (string-match-p (regexp-quote (buffer-name buffer))
                                (agent-auto-test--disk file))))
      (should (string-match-p
               "\\`\\[[0-9-]+ [[:alpha:]]+ [0-9:]+\\]\\'"
               (agent-auto-test--property file "Fix it" "AGENT_STARTED")))
      (should (equal (agent-auto-test--tags file "Fix it") '("agent"))))))

(ert-deftest agent-auto-test-always-submits-the-brief ()
  "Submit the brief of a Linear issue too, whatever its submit property.
Started by hand such a task is left in the prompt to be edited."
  (agent-auto-test--with root
    (let ((agent-todo-submit-property "READY"))
      (agent-auto-test--file
       root (format "* TODO Issue :agent:\n:PROPERTIES:\n:DIR: %s\n:LINEAR_URL: https://linear.app/a/issue/A-1\n:END:\n"
                    root))
      (agent-auto-test--run)
      (should (equal (plist-get (cdar agent-auto-test--started) :initial-prompt)
                     "Issue\n\nStanding.")))))

(ert-deftest agent-auto-test-empty-body-stops-at-the-next-heading ()
  "Brief a ready task that has no body with its title and the instructions.
The task below it is no part of the brief."
  (agent-auto-test--with root
    (agent-auto-test--file
     root (format "* TODO Pay the accountant :agent:\n:PROPERTIES:\n:DIR: %s\n:END:\n* TODO Renew the passport\nBring two photos.\n"
                  root))
    (agent-auto-test--run)
    (should (= (length agent-auto-test--started) 1))
    (should (equal (plist-get (cdar agent-auto-test--started) :initial-prompt)
                   "Pay the accountant\n\nStanding."))))

(ert-deftest agent-auto-test-starts-only-eligible-tasks ()
  "Leave alone every task that lacks one of the conditions.
Only an open TODO that carries the tag itself, has a directory that
exists and records no session is started."
  (agent-auto-test--with root
    (let ((file (agent-auto-test--file
                 root
                 (concat
                  (format "* Tagged above :agent:\n:PROPERTIES:\n:DIR: %s\n:END:\n** TODO Inherits the tag\n" root)
                  (agent-auto-test--task root "Eligible")
                  (format "* DONE Closed :agent:\n:PROPERTIES:\n:DIR: %s\n:END:\n" root)
                  (format "* Not a task :agent:\n:PROPERTIES:\n:DIR: %s\n:END:\n" root)
                  "* TODO No directory :agent:\n"
                  (format "* TODO Directory gone :agent:\n:PROPERTIES:\n:DIR: %s\n:END:\n"
                          (expand-file-name "gone" root))
                  (format "* TODO Recorded :agent:\n:PROPERTIES:\n:DIR: %s\n:AGENT_SESSION: abc\n:END:\n" root)
                  (format "* TODO Untagged\n:PROPERTIES:\n:DIR: %s\n:END:\nMentions :agent: in passing.\n" root)))))
      (agent-auto-test--run)
      (should (equal (mapcar (lambda (start)
                               (plist-get (cdr start) :initial-prompt))
                             agent-auto-test--started)
                     '("Eligible\n\nThe body.\n\nStanding.")))
      (should-not (agent-auto-test--property file "No directory" "AGENT_SESSION"))
      (should (equal (agent-auto-test--property file "Recorded" "AGENT_SESSION")
                     "abc")))))

(ert-deftest agent-auto-test-eligible-functions-veto ()
  "Start a task only when every eligibility function returns non-nil.
The functions run at the task.  One that signals vetoes too."
  (agent-auto-test--with root
    (let* ((seen nil)
           (file (agent-auto-test--file
                  root (concat (agent-auto-test--task root "Allowed")
                               (agent-auto-test--task root "Vetoed")
                               (agent-auto-test--task root "Broken"))))
           (agent-auto-eligible-functions
            (list (lambda () t)
                  (lambda ()
                    (let ((heading (org-get-heading t t t t)))
                      (push heading seen)
                      (when (equal heading "Broken")
                        (error "Cannot tell"))
                      (not (equal heading "Vetoed")))))))
      (agent-test-helper-with-messages messages
        (agent-auto-test--run)
        (should (string-match-p "Cannot tell" messages)))
      (should (equal (sort seen #'string<) '("Allowed" "Broken" "Vetoed")))
      (should (= (length agent-auto-test--started) 1))
      (should (agent-auto-test--property file "Allowed" "AGENT_SESSION"))
      (should-not (agent-auto-test--property file "Vetoed" "AGENT_SESSION"))
      (should-not (agent-auto-test--property file "Broken" "AGENT_SESSION")))))

(ert-deftest agent-auto-test-removing-the-tag-prevents-the-start ()
  "Start nothing on a task whose ready tag was removed before the search."
  (agent-auto-test--with root
    (let ((file (agent-auto-test--file root (agent-auto-test--task root))))
      (agent-auto-test--at file "Fix it" (lambda () (org-set-tags nil)))
      (with-current-buffer (find-buffer-visiting file)
        (save-buffer))
      (agent-auto-test--run)
      (should-not agent-auto-test--started))))

(ert-deftest agent-auto-test-unsaved-buffer-is-left-alone ()
  "Leave a buffer with unsaved edits alone until it is saved.
The tag is on disk, but the user is editing the file: nothing is
started and the buffer is not touched.  Once saved, the task starts."
  (agent-auto-test--with root
    (let* ((file (agent-auto-test--file root (agent-auto-test--task root)))
           (buffer (find-file-noselect file)))
      (with-current-buffer buffer
        (goto-char (point-max))
        (insert "Typing.\n"))
      (let ((text (with-current-buffer buffer (buffer-string))))
        (agent-auto-test--run)
        (should-not agent-auto-test--started)
        (should (equal (with-current-buffer buffer (buffer-string)) text))
        (should (buffer-modified-p buffer)))
      (with-current-buffer buffer
        (save-buffer))
      (agent-auto-test--run)
      (should (= (length agent-auto-test--started) 1)))))

(ert-deftest agent-auto-test-account-follows-the-directory-rule ()
  "Start the session on the account the task's directory's rule gives."
  (agent-auto-test--with root
    (let ((agent-account-directory-rules `((,root . "work")))
          (agent-account--current (make-hash-table :test #'eq)))
      (setf (agent-backend-accounts (agent-backend 'stub))
            '(("work" . "/tmp/agent-test-work/")
              ("personal" . "/tmp/agent-test-personal/")))
      (puthash 'stub "personal" agent-account--current)
      (agent-auto-test--file root (agent-auto-test--task root))
      (cl-letf (((symbol-function 'agent-account-sync) #'ignore)
                ((symbol-function 'agent-account-logged-in-p)
                 (lambda (&rest _) t)))
        (agent-auto-test--run))
      (should (equal (agent-session-account (caar agent-auto-test--started))
                     "work")))))

(ert-deftest agent-auto-test-ten-tasks-start-ten-sessions ()
  "Start every ready task, with no limit, and keep sessions apart.
Two tasks in one repository get separate worktrees: the first runs in
the checkout and the second in a worktree named after it, under the
repository's name.  Tasks in one plain directory get distinct names."
  (agent-auto-test--with root
    (let* ((repo (agent-auto-test--repository root "repo"))
           (plain (file-name-as-directory (expand-file-name "plain" root))))
      (make-directory plain)
      (agent-auto-test--file
       root (concat (agent-auto-test--task repo "First in repo")
                    (agent-auto-test--task repo "Second in repo")
                    (mapconcat (lambda (n)
                                 (agent-auto-test--task plain (format "Plain %d" n)))
                               (number-sequence 1 8))))
      (agent-auto-test--run)
      (should (= (length agent-auto-test--started) 10))
      (let* ((sessions (mapcar #'car agent-auto-test--started))
             (in-repo (lambda (instance)
                        (agent-session-directory
                         (seq-find (lambda (session)
                                     (equal (agent-session-instance session)
                                            instance))
                                   sessions))))
             (worktree (file-name-as-directory
                        (file-truename
                         (expand-file-name "repo/second-in-repo"
                                           agent-branch-worktree-directory)))))
        (should (equal (funcall in-repo "first-in-repo") repo))
        (should (equal (funcall in-repo "second-in-repo") worktree))
        (should (file-exists-p (expand-file-name "README" worktree)))
        (should (= (length (delete-dups
                            (mapcar #'agent-session-buffer-name sessions)))
                   10))))))

(ert-deftest agent-auto-test-worktree-keeps-the-directory-rule ()
  "Start a session moved to a worktree on the account of the task's directory.
The worktree lies outside the directory the rule names."
  (agent-auto-test--with root
    (let* ((repo (agent-auto-test--repository root "repo"))
           (agent-account-directory-rules `((,repo . "work")))
           (agent-account--current (make-hash-table :test #'eq)))
      (setf (agent-backend-accounts (agent-backend 'stub))
            '(("work" . "/tmp/agent-test-work/")
              ("personal" . "/tmp/agent-test-personal/")))
      (puthash 'stub "personal" agent-account--current)
      (agent-auto-test--file root (concat (agent-auto-test--task repo "One")
                                          (agent-auto-test--task repo "Two")))
      (cl-letf (((symbol-function 'agent-account-sync) #'ignore)
                ((symbol-function 'agent-account-logged-in-p)
                 (lambda (&rest _) t)))
        (agent-auto-test--run))
      (should (equal (mapcar (lambda (start) (agent-session-account (car start)))
                             agent-auto-test--started)
                     '("work" "work"))))))

(ert-deftest agent-auto-test-a-task-is-started-once ()
  "Start no second session on a task, whatever happens to the first.
Neither while it runs, nor after it finished, nor when it failed."
  (agent-auto-test--with root
    (pcase-let ((`(,_file . ,buffer) (agent-auto-test--started-task root)))
      (agent-auto-test--run)
      (should (= (length agent-auto-test--started) 1))
      (agent-auto-test--end-turn buffer "Did it.\n\nStatus: done")
      (agent-auto-test--run)
      (should (= (length agent-auto-test--started) 1)))))

(ert-deftest agent-auto-test-start-error-is-stuck-without-retry ()
  "Mark a task stuck, with the reason, when its session cannot start.
The next search does not try again."
  (agent-auto-test--with root
    (let ((file (agent-auto-test--file root (agent-auto-test--task root)))
          (agent-auto-test--start-error "account logged out"))
      (agent-test-helper-with-messages messages
        (agent-auto-test--run)
        (should (string-match-p "could not start a session" messages)))
      (should (equal (agent-auto-test--tags file "Fix it") '("stuck")))
      (should (equal (agent-auto-test--property file "Fix it" "AGENT_RESULT")
                     "start failed: account logged out"))
      (setq agent-auto-test--start-error nil)
      (agent-auto-test--run)
      (should-not agent-auto-test--started)
      (should-not agent-auto--starting))))

(ert-deftest agent-auto-test-several-backends-need-a-choice ()
  "Start nothing, and record nothing, while the backend is ambiguous."
  (agent-auto-test--with root
    (let ((file (agent-auto-test--file root (agent-auto-test--task root))))
      (agent-register-backend 'other :buffer-p #'ignore
                              :find-all-buffers #'ignore
                              :start-session #'ignore)
      (agent-test-helper-with-messages messages
        (agent-auto-test--run)
        (should (string-match-p "agent-auto-backend" messages)))
      (should-not (agent-auto-test--property file "Fix it" "AGENT_SESSION"))
      (let ((agent-auto-backend 'stub))
        (agent-auto-test--run))
      (should (= (length agent-auto-test--started) 1)))))

(ert-deftest agent-auto-test-backend-falls-back-to-the-todo-backend ()
  "Start unattended sessions with `agent-todo-backend' when no own one is set.
`agent-auto-backend' wins when both are set, and a fallback that names
no registered backend starts nothing and records nothing."
  (agent-auto-test--with root
    (let ((file (agent-auto-test--file root (agent-auto-test--task root))))
      (agent-register-backend 'other :buffer-p #'ignore
                              :find-all-buffers #'ignore
                              :start-session #'ignore)
      (let ((agent-todo-backend 'gone))
        (agent-test-helper-with-messages messages
          (agent-auto-test--run)
          (should (string-match-p "agent-todo-backend.* names .*gone" messages))))
      (should-not (agent-auto-test--property file "Fix it" "AGENT_SESSION"))
      (let ((agent-todo-backend 'stub))
        (agent-auto-test--run))
      (should (= (length agent-auto-test--started) 1))
      (should (equal (agent-auto-test--property file "Fix it" "AGENT_BACKEND")
                     "stub"))))
  (agent-auto-test--with root
    (let ((file (agent-auto-test--file root (agent-auto-test--task root)))
          (agent-auto-backend 'stub)
          (agent-todo-backend 'other))
      (agent-register-backend 'other :buffer-p #'ignore
                              :find-all-buffers #'ignore
                              :start-session #'ignore)
      (agent-auto-test--run)
      (should (= (length agent-auto-test--started) 1))
      (should (equal (agent-auto-test--property file "Fix it" "AGENT_BACKEND")
                     "stub")))))

;;;; Results

(ert-deftest agent-auto-test-done-becomes-review ()
  "Replace the ready tag by the review tag, with the result, on done."
  (agent-auto-test--with root
    (pcase-let ((`(,file . ,buffer) (agent-auto-test--started-task root)))
      (agent-auto-test--end-turn
       buffer "Looked into it.\n\nStatus: done: the gather   now keeps all-day events")
      (should (equal (agent-auto-test--tags file "Fix it") '("review")))
      (should (equal (agent-auto-test--property file "Fix it" "AGENT_RESULT")
                     "the gather now keeps all-day events"))
      (should (string-match-p ":review:" (agent-auto-test--disk file)))
      (should (agent-auto-test--at file "Fix it" #'org-entry-is-todo-p)))))

(ert-deftest agent-auto-test-bare-done-takes-the-summary ()
  "Use the paragraph above a bare status line as the result."
  (agent-auto-test--with root
    (pcase-let ((`(,file . ,buffer) (agent-auto-test--started-task root)))
      (agent-auto-test--end-turn
       buffer "Details.\n\nFixed the parser\nand added a test.\n\nStatus: done")
      (should (equal (agent-auto-test--property file "Fix it" "AGENT_RESULT")
                     "Fixed the parser and added a test.")))))

(ert-deftest agent-auto-test-pending-verification-becomes-review ()
  "Give a review, saying what is still to be proved."
  (agent-auto-test--with root
    (pcase-let ((`(,file . ,buffer) (agent-auto-test--started-task root)))
      (agent-auto-test--end-turn
       buffer "Status: done, pending verification: the nightly run at 03:00")
      (should (equal (agent-auto-test--tags file "Fix it") '("review")))
      (should (equal (agent-auto-test--property file "Fix it" "AGENT_RESULT")
                     "pending verification: the nightly run at 03:00")))))

(ert-deftest agent-auto-test-waiting-becomes-blocked ()
  "Mark a task blocked, with the question, when its session waits."
  (agent-auto-test--with root
    (pcase-let ((`(,file . ,buffer) (agent-auto-test--started-task root)))
      (agent-auto-test--end-turn
       buffer "Status: waiting on you: which calendar is the source?")
      (should (equal (agent-auto-test--tags file "Fix it") '("blocked")))
      (should (equal (agent-auto-test--property file "Fix it" "AGENT_RESULT")
                     "which calendar is the source?")))))

(ert-deftest agent-auto-test-in-progress-keeps-tracking ()
  "Change nothing on in progress, and write the result of the turn after."
  (agent-auto-test--with root
    (pcase-let ((`(,file . ,buffer) (agent-auto-test--started-task root)))
      (let ((before (agent-auto-test--disk file)))
        (agent-auto-test--end-turn
         buffer "Status: in progress: the build finishes next")
        (should (equal (agent-auto-test--disk file) before))
        (should-not (buffer-local-value 'agent-auto--settled buffer)))
      (agent-auto-test--end-turn buffer "Status: done: built")
      (should (equal (agent-auto-test--tags file "Fix it") '("review"))))))

(ert-deftest agent-auto-test-no-status-line-is-stuck ()
  "Mark a task stuck when its session stops without a status line."
  (agent-auto-test--with root
    (pcase-let ((`(,file . ,buffer) (agent-auto-test--started-task root)))
      (agent-auto-test--end-turn buffer "API Error: overloaded")
      (should (equal (agent-auto-test--tags file "Fix it") '("stuck")))
      (should (equal (agent-auto-test--property file "Fix it" "AGENT_RESULT")
                     "the session stopped without a status line")))))

(ert-deftest agent-auto-test-permission-prompt-is-blocked ()
  "Mark a task blocked when its session shows a prompt nobody will answer."
  (agent-auto-test--with root
    (pcase-let ((`(,file . ,buffer) (agent-auto-test--started-task root)))
      (run-hook-with-args 'agent-session-event-functions buffer 'blocked)
      (should (equal (agent-auto-test--tags file "Fix it") '("blocked"))))))

;; A session started in a directory its CLI had not seen sat at the
;; question whether to trust it for three minutes, with the brief behind
;; the dialog and the task still marked ready: no event reports a dialog
;; that opens before the first turn.
(ert-deftest agent-auto-test-startup-dialog-is-blocked ()
  "Mark a task blocked when its session shows a dialog no event reported.
The dialog is said in the echo area, since somebody has to answer it.  A
session whose input box shows is left alone, and once the dialog is
answered the end of the turn writes the result."
  (agent-auto-test--with root
    (pcase-let ((`(,file . ,buffer) (agent-auto-test--started-task root))
                (dialog nil))
      (let ((agent-session-input-state-functions
             (list (lambda (session)
                     (and (eq session buffer)
                          (list :box (not dialog) :dialog dialog))))))
        (agent-auto-test--run)
        (should (equal (agent-auto-test--tags file "Fix it") '("agent")))
        (setq dialog t)
        (agent-test-helper-with-messages messages
          (agent-auto-test--run)
          (should (string-match-p "waits at a dialog" messages)))
        (should (equal (agent-auto-test--tags file "Fix it") '("blocked")))
        (should (string-match-p
                 "waits at a dialog"
                 (agent-auto-test--property file "Fix it" "AGENT_RESULT")))
        (agent-test-helper-with-messages messages
          (agent-auto-test--run)
          (should-not (string-match-p "waits at a dialog" messages)))
        (setq dialog nil)
        (run-hook-with-args 'agent-session-event-functions buffer 'activity)
        (agent-auto-test--end-turn buffer "Status: done: trusted and finished")
        (should (equal (agent-auto-test--tags file "Fix it") '("review")))
        (setq dialog t)
        (agent-auto-test--run)
        (should (equal (agent-auto-test--tags file "Fix it") '("review")))))))

(ert-deftest agent-auto-test-started-session-is-checked-for-a-dialog ()
  "Look at a session's screen a moment after it starts, not at the next search."
  (agent-auto-test--with root
    (let ((timer-function (symbol-function 'run-with-timer))
          checks)
      (cl-letf (((symbol-function 'run-with-timer)
                 (lambda (seconds repeat function &rest arguments)
                   (if (eq function #'agent-auto--check-dialog)
                       (push (cons seconds arguments) checks)
                     (apply timer-function seconds repeat function
                            arguments)))))
        (pcase-let ((`(,file . ,buffer) (agent-auto-test--started-task root)))
          (should (equal checks
                         (list (list agent-auto--start-check-delay buffer))))
          (let ((agent-session-input-state-functions
                 (list (lambda (_session) (list :dialog t)))))
            (agent-auto--check-dialog buffer))
          (should (equal (agent-auto-test--tags file "Fix it") '("blocked")))
          (let ((kill-buffer-query-functions nil))
            (kill-buffer buffer))
          (agent-auto--check-dialog buffer))))))

;; A turn that ends within seconds of the session's start can end before
;; the backend has reported the id by which the transcript is found; the
;; task was then stuck for want of a status line nobody had read.
(ert-deftest agent-auto-test-unreadable-reply-is-read-again ()
  "Look again at a turn's end while the session's reply cannot be read.
Only once the looks are used up does the task count as stuck."
  (agent-auto-test--with root
    (pcase-let ((`(,file . ,buffer) (agent-auto-test--started-task root))
                (timer-function (symbol-function 'run-with-timer))
                (again nil))
      (cl-letf (((symbol-function 'run-with-timer)
                 (lambda (seconds repeat function &rest arguments)
                   (if (eq function #'agent-auto--turn-end)
                       (push (cons seconds arguments) again)
                     (apply timer-function seconds repeat function
                            arguments)))))
        (run-hook-with-args 'agent-session-event-functions buffer 'stop)
        (should (equal again (list (list agent-auto--turn-end-delay buffer
                                         agent-auto--turn-end-retries))))
        (setq again nil)
        (agent-auto--turn-end buffer 2)
        (should (equal again (list (list agent-auto--turn-end-delay buffer 1))))
        (should (equal (agent-auto-test--tags file "Fix it") '("agent")))
        (setq again nil)
        (agent-auto--turn-end buffer 0)
        (should-not again)
        (should (equal (agent-auto-test--tags file "Fix it") '("stuck")))
        (with-current-buffer buffer
          (setq agent-auto-test--reply "Status: done: read at the second look"))
        (setq again nil)
        (agent-auto--turn-end buffer 1)
        (should-not again)
        (should (equal (agent-auto-test--tags file "Fix it") '("review")))
        (should (equal (agent-auto-test--property file "Fix it" "AGENT_RESULT")
                       "read at the second look"))))))

(ert-deftest agent-auto-test-silence-is-stuck ()
  "Mark a task stuck after the silence timeout, and not before.
Activity in the transcript counts as a sign of life."
  (agent-auto-test--with root
    (pcase-let ((`(,file . ,buffer) (agent-auto-test--started-task root)))
      (with-current-buffer buffer
        (setq agent-auto--last-event (- (float-time) (* 29 60))))
      (agent-auto-test--run)
      (should (equal (agent-auto-test--tags file "Fix it") '("agent")))
      (with-current-buffer buffer
        (setq agent-auto--last-event (- (float-time) (* 31 60))
              agent--session-derived-status (cons (float-time) "Running")))
      (agent-auto-test--run)
      (should (equal (agent-auto-test--tags file "Fix it") '("agent")))
      (with-current-buffer buffer
        (setq agent--session-derived-status nil))
      (agent-auto-test--run)
      (should (equal (agent-auto-test--tags file "Fix it") '("stuck")))
      (should (equal (agent-auto-test--property file "Fix it" "AGENT_RESULT")
                     "no sign of life from the session for 30 minutes")))))

(ert-deftest agent-auto-test-late-result-replaces-stuck ()
  "Write the result of a session that ends after it was given up on."
  (agent-auto-test--with root
    (pcase-let ((`(,file . ,buffer) (agent-auto-test--started-task root)))
      (with-current-buffer buffer
        (setq agent-auto--last-event (- (float-time) (* 31 60))))
      (agent-auto-test--run)
      (should (equal (agent-auto-test--tags file "Fix it") '("stuck")))
      (agent-auto-test--end-turn buffer "Status: done: slow but finished")
      (should (equal (agent-auto-test--tags file "Fix it") '("review"))))))

(ert-deftest agent-auto-test-missing-session-is-stuck-after-the-timeout ()
  "Mark a ready task stuck when its recorded session stays away.
It is given the silence timeout to come back, as after Emacs restarts."
  (agent-auto-test--with root
    (pcase-let ((`(,file . ,buffer) (agent-auto-test--started-task root)))
      (let ((recorded (agent-auto-test--property file "Fix it" "AGENT_SESSION"))
            (kill-buffer-query-functions nil))
        (kill-buffer buffer)
        (agent-auto-test--run)
        (should (equal (agent-auto-test--tags file "Fix it") '("agent")))
        (puthash (cons file recorded) (- (float-time) (* 31 60))
                 agent-auto--missing)
        (agent-auto-test--run)
        (should (equal (agent-auto-test--tags file "Fix it") '("stuck")))
        (should (equal (agent-auto-test--property file "Fix it" "AGENT_RESULT")
                       "its session is not running"))
        (should (= (length agent-auto-test--started) 1))))))

(ert-deftest agent-auto-test-removed-result-tag-is-not-added-back ()
  "Leave a task alone once the user removed its result tag."
  (agent-auto-test--with root
    (pcase-let ((`(,file . ,buffer) (agent-auto-test--started-task root)))
      (agent-auto-test--end-turn buffer "Status: done: fixed")
      (agent-auto-test--at file "Fix it" (lambda () (org-set-tags nil)))
      (with-current-buffer (find-buffer-visiting file)
        (save-buffer))
      (agent-auto-test--end-turn buffer "Status: waiting on you: anything else?")
      (agent-auto-test--run)
      (should-not (agent-auto-test--tags file "Fix it"))
      (should (equal (agent-auto-test--property file "Fix it" "AGENT_RESULT")
                     "fixed"))
      (should (= (length agent-auto-test--started) 1)))))

(ert-deftest agent-auto-test-closed-task-is-left-alone ()
  "Write no result on a task the user closed meanwhile."
  (agent-auto-test--with root
    (pcase-let ((`(,file . ,buffer) (agent-auto-test--started-task root)))
      (agent-auto-test--at file "Fix it" (lambda () (org-todo 'done)))
      (with-current-buffer (find-buffer-visiting file)
        (save-buffer))
      (agent-auto-test--end-turn buffer "Status: done: fixed")
      (should (equal (agent-auto-test--tags file "Fix it") '("agent")))
      (should-not (agent-auto-test--property file "Fix it" "AGENT_RESULT")))))

(ert-deftest agent-auto-test-result-waits-for-a-saved-buffer ()
  "Write a result only once the task's buffer has no unsaved edits.
The save itself then has it written, without waiting for a search."
  (agent-auto-test--with root
    (pcase-let ((`(,file . ,buffer) (agent-auto-test--started-task root)))
      (let ((org (find-buffer-visiting file)))
        (with-current-buffer org
          (goto-char (point-max))
          (insert "Typing.\n"))
        (let ((text (with-current-buffer org (buffer-string))))
          (agent-auto-test--end-turn buffer "Status: done: fixed")
          (agent-auto-test--run)
          (should (equal (with-current-buffer org (buffer-string)) text)))
        (with-current-buffer org
          (save-buffer))
        (agent-auto-test--flush-due)
        (should (equal (agent-auto-test--tags file "Fix it") '("review")))
        (should (string-match-p "Typing" (agent-auto-test--disk file)))
        (should-not agent-auto--pending)))))

(ert-deftest agent-auto-test-edits-leave-point-and-windows-alone ()
  "Start and finish a task without moving point or changing a window.
The file is shown in the selected window, narrowed, with point in the
body of another heading."
  (agent-auto-test--with root
    (let* ((file (agent-auto-test--file
                  root (concat "* Notes\nSome text here.\n"
                               (agent-auto-test--task root))))
           (org (find-file-noselect file)))
      (save-window-excursion
        (switch-to-buffer org)
        (goto-char (point-min))
        (search-forward "Some te")
        (org-narrow-to-subtree)
        (let ((window (selected-window))
              (configuration (current-window-configuration))
              (point (point)))
          (agent-auto-test--run)
          (agent-auto-test--end-turn (car agent-auto-test--buffers)
                                     "Status: done: fixed")
          (should (eq (selected-window) window))
          (should (eq (window-buffer window) org))
          (should (eq (current-buffer) org))
          (should (= (point) point))
          (should (= (window-point window) point))
          (should (looking-at-p "xt here"))
          (should (buffer-narrowed-p))
          (should (compare-window-configurations
                   configuration (current-window-configuration)))))
      (should (equal (agent-auto-test--tags file "Fix it") '("review"))))))

(ert-deftest agent-auto-test-stale-buffer-is-reverted-before-an-edit ()
  "Read a file changed on disk again before writing to it.
A session often edits the file that holds its own task."
  (agent-auto-test--with root
    (pcase-let ((`(,file . ,buffer) (agent-auto-test--started-task root)))
      (let ((text (agent-auto-test--disk file)))
        (sleep-for 1.1)
        (write-region (concat text "* Added by the session\n") nil file
                      nil 'silent))
      (agent-auto-test--end-turn buffer "Status: done: fixed")
      (should (equal (agent-auto-test--tags file "Fix it") '("review")))
      (should (string-match-p "Added by the session"
                              (agent-auto-test--disk file))))))

;;;; The session's identity

(ert-deftest agent-auto-test-records-the-session-id ()
  "Record the session by its id once the backend reports it."
  (agent-auto-test--with root
    (pcase-let ((`(,file . ,buffer) (agent-auto-test--started-task root)))
      (agent--note-session-id buffer "sid-1")
      (should (equal (agent-auto-test--property file "Fix it" "AGENT_SESSION")
                     "sid-1"))
      (agent-auto-test--end-turn buffer "Status: done: fixed")
      (should (equal (agent-auto-test--tags file "Fix it") '("review"))))))

(ert-deftest agent-auto-test-manual-start-is-recorded ()
  "Record on the task a session started on it by hand.
The timer then starts no second session, and the session's result is
written as for one it started."
  (agent-auto-test--with root
    (let ((file (agent-auto-test--file root (agent-auto-test--task root))))
      (with-current-buffer (find-file-noselect file)
        (goto-char (point-min))
        (agent-act-on-thing-at-point))
      (should (= (length agent-auto-test--started) 1))
      (let ((buffer (car agent-auto-test--buffers)))
        (should (equal (plist-get (cdar agent-auto-test--started) :initial-prompt)
                       "Fix it\n\nThe body."))
        (should (equal (agent-auto-test--property file "Fix it" "AGENT_SESSION")
                       (buffer-name buffer)))
        (should (agent-auto-test--property file "Fix it" "AGENT_STARTED"))
        (should (string-match-p "AGENT_SESSION" (agent-auto-test--disk file)))
        (agent-auto-test--run)
        (should (= (length agent-auto-test--started) 1))
        (agent-auto-test--end-turn buffer "Status: done: fixed by hand")
        (should (equal (agent-auto-test--tags file "Fix it") '("review")))))))

(ert-deftest agent-auto-test-manual-start-in-an-unsaved-buffer ()
  "Record a hand-started session at once, leaving unsaved edits unsaved."
  (agent-auto-test--with root
    (let ((file (agent-auto-test--file root (agent-auto-test--task root))))
      (with-current-buffer (find-file-noselect file)
        (goto-char (point-max))
        (insert "Typing.\n")
        (goto-char (point-min))
        (agent-send-todo-at-point)
        (should (buffer-modified-p))
        (should (org-entry-get nil "AGENT_SESSION")))
      (should-not (string-match-p "AGENT_SESSION" (agent-auto-test--disk file)))
      (agent-auto-test--run)
      (with-current-buffer (find-buffer-visiting file)
        (save-buffer))
      (agent-auto-test--run)
      (should (= (length agent-auto-test--started) 1)))))

;; The session was recorded and the buffer saved, and then the keyword
;; was changed, which left the file modified: until it was saved by hand
;; the session's id and its result waited, and so did every other edit
;; meant for that file.
(ert-deftest agent-auto-test-manual-start-leaves-a-saved-buffer-saved ()
  "Save a task's buffer after a session is started on it by hand.
The task is recorded and moved to the in-progress keyword, on disk, when
its buffer had no unsaved edits, from its heading and from an agenda
line.  The session's id is then recorded as soon as it is known.  A
buffer that had unsaved edits is left unsaved, with both changes in it."
  (dolist (from '(heading agenda))
    (agent-auto-test--with root
      (let* ((agent-todo-in-progress-keyword "DOING")
             (file (agent-auto-test--file
                    root (concat "#+TODO: TODO DOING | DONE\n"
                                 (agent-auto-test--task root nil ""))))
             (org (find-file-noselect file)))
        (with-current-buffer org
          (goto-char (point-min))
          (search-forward "Fix it")
          (if (eq from 'heading)
              (agent-act-on-thing-at-point)
            (agent-test-helper-in-agenda "Fix it"
              (agent-auto-test--keeping-buffer (agent-act-on-thing-at-point)))))
        (should (= (length agent-auto-test--started) 1))
        (should-not (buffer-modified-p org))
        (should (string-match-p "^\\* DOING Fix it" (agent-auto-test--disk file)))
        (should (string-match-p "AGENT_SESSION" (agent-auto-test--disk file)))
        (agent--note-session-id (car agent-auto-test--buffers) "sid-1")
        (should (string-match-p ":AGENT_SESSION: +sid-1"
                                (agent-auto-test--disk file))))))
  (agent-auto-test--with root
    (let* ((agent-todo-in-progress-keyword "DOING")
           (file (agent-auto-test--file
                  root (concat "#+TODO: TODO DOING | DONE\n"
                               (agent-auto-test--task root nil ""))))
           (org (find-file-noselect file)))
      (with-current-buffer org
        (goto-char (point-max))
        (insert "Typing.\n")
        (goto-char (point-min))
        (search-forward "Fix it")
        (agent-act-on-thing-at-point)
        (should (buffer-modified-p))
        (should (equal (org-get-todo-state) "DOING"))
        (should (org-entry-get nil "AGENT_SESSION")))
      (should (string-match-p "^\\* TODO Fix it" (agent-auto-test--disk file)))
      (should-not (string-match-p "AGENT_SESSION\\|Typing"
                                  (agent-auto-test--disk file))))))

;; A task sent by hand from a buffer with unsaved edits recorded its
;; session by the buffer's name, and the id waited for the buffer to be
;; saved.  A session closed before that left the task with a record
;; that nothing could resume.
(ert-deftest agent-auto-test-id-reaches-a-task-with-unsaved-edits ()
  "Record a session's id on its task also in a buffer with unsaved edits.
The buffer is left unsaved.  Once it is saved, the task names its
session by id, although the session ended meanwhile, so that acting on
the task resumes it."
  (agent-auto-test--with root
    (let* ((file (agent-auto-test--file
                  root (agent-auto-test--task root nil "")))
           (org (find-file-noselect file)))
      (with-current-buffer org
        (goto-char (point-max))
        (insert "Typing.\n")
        (goto-char (point-min))
        (agent-act-on-thing-at-point))
      (let ((session (car agent-auto-test--buffers))
            (kill-buffer-query-functions nil))
        (agent--note-session-id session "sid-1")
        (should (buffer-modified-p org))
        (should (equal (agent-auto-test--property file "Fix it" "AGENT_SESSION")
                       "sid-1"))
        (should-not (string-match-p "AGENT_SESSION\\|Typing"
                                    (agent-auto-test--disk file)))
        (kill-buffer session))
      (with-current-buffer org
        (save-buffer)
        (goto-char (point-min))
        (let ((context (agent-auto--recorded-session)))
          (should-not (plist-get context :lost))
          (should (equal (plist-get context :resume-id) "sid-1")))))))

(ert-deftest agent-auto-test-read-only-buffer-keeps-the-id-waiting ()
  "Leave a read-only buffer alone, and record the id once it can be edited."
  (agent-auto-test--with root
    (pcase-let* ((`(,file . ,session) (agent-auto-test--hand-started-task root))
                 (org (find-buffer-visiting file)))
      (with-current-buffer org
        (setq buffer-read-only t))
      (agent--note-session-id session "sid-1")
      (should-not (equal (agent-auto-test--property file "Fix it" "AGENT_SESSION")
                         "sid-1"))
      (with-current-buffer org
        (setq buffer-read-only nil))
      (agent-auto-test--run)
      (should (string-match-p ":AGENT_SESSION: +sid-1"
                              (agent-auto-test--disk file))))))

(defun agent-auto-test--hand-started-task (root &optional tags)
  "Start by hand the one task of a new file under ROOT; return (FILE . BUFFER).
The task carries TAGS, a tag string, and no tag when TAGS is nil."
  (let ((file (agent-auto-test--file
               root (agent-auto-test--task root nil (or tags "")))))
    (with-current-buffer (find-file-noselect file)
      (goto-char (point-min))
      (agent-act-on-thing-at-point))
    (should (= (length agent-auto-test--started) 1))
    (cons file (car agent-auto-test--buffers))))

;; A result was written only on a task that carried the ready tag or a
;; result tag, so a task started by hand, which has none, never heard
;; back from its session.
(ert-deftest agent-auto-test-hand-started-session-reports-back ()
  "Write the result of a session started by hand on a task that has no tag.
The task records the session, and that is enough: it gets the tag and
the result an unattended session's task gets, on disk, and a later turn
replaces them."
  (agent-auto-test--with root
    (pcase-let ((`(,file . ,buffer) (agent-auto-test--hand-started-task root)))
      (should-not (agent-auto-test--tags file "Fix it"))
      (agent-auto-test--end-turn buffer "Status: waiting on you: which account?")
      (should (equal (agent-auto-test--tags file "Fix it") '("blocked")))
      (should (equal (agent-auto-test--property file "Fix it" "AGENT_RESULT")
                     "which account?"))
      (should (string-match-p ":blocked:" (agent-auto-test--disk file)))
      (agent-auto-test--end-turn buffer "Paid it.\n\nStatus: done: paid from the joint account")
      (should (equal (agent-auto-test--tags file "Fix it") '("review")))
      (should (equal (agent-auto-test--property file "Fix it" "AGENT_RESULT")
                     "paid from the joint account"))
      (run-hook-with-args 'agent-session-event-functions buffer 'blocked)
      (should (equal (agent-auto-test--tags file "Fix it") '("blocked"))))))

(ert-deftest agent-auto-test-hand-started-result-tag-is-not-added-back ()
  "Leave a task started by hand alone once the user removed its result tag.
A task that has a result and none of the tags is one whose tag was
removed, not one that never had any."
  (agent-auto-test--with root
    (pcase-let ((`(,file . ,buffer) (agent-auto-test--hand-started-task root)))
      (agent-auto-test--end-turn buffer "Status: done: fixed")
      (should (equal (agent-auto-test--tags file "Fix it") '("review")))
      (agent-auto-test--at file "Fix it" (lambda () (org-set-tags nil)))
      (with-current-buffer (find-buffer-visiting file)
        (save-buffer))
      (agent-auto-test--end-turn buffer "Status: waiting on you: anything else?")
      (should-not (agent-auto-test--tags file "Fix it"))
      (should (equal (agent-auto-test--property file "Fix it" "AGENT_RESULT")
                     "fixed")))))

(ert-deftest agent-auto-test-hand-started-session-is-never-stuck ()
  "Leave a task alone when a session started by hand ends without a status line.
The user is driving that session, and it was not told to end its replies
with one.  That holds whether or not the task carries the ready tag, and
across a handoff; a session the timer started is stuck as before."
  (dolist (tags '(nil ":agent:"))
    (agent-auto-test--with root
      (pcase-let ((`(,file . ,buffer)
                   (agent-auto-test--hand-started-task root tags)))
        (agent-auto-test--end-turn buffer "Here is what I found so far.")
        (should (equal (agent-auto-test--tags file "Fix it")
                       (and tags '("agent"))))
        (should-not (agent-auto-test--property file "Fix it" "AGENT_RESULT")))))
  (agent-auto-test--with root
    (pcase-let ((`(,file . ,buffer) (agent-auto-test--started-task root)))
      (agent--note-session-id buffer "sid-1")
      (let* ((handoff (expand-file-name "handoff.md" root))
             (agent-handoff-files `((stub . ,handoff))))
        (write-region "Continue the fix." nil handoff nil 'silent)
        (cl-letf (((symbol-function 'agent--confirm-no-captured-prompts)
                   (lambda (&rest _) t)))
          (with-current-buffer buffer
            (agent-handoff))))
      (agent-auto-test--end-turn (car agent-auto-test--buffers)
                                 "Here is what I found so far.")
      (should (equal (agent-auto-test--tags file "Fix it") '("stuck"))))))

(ert-deftest agent-auto-test-handoff-carries-the-task ()
  "Move the task's link to the session a handoff starts.
The task then records the new session, and gets its result."
  (agent-auto-test--with root
    (pcase-let ((`(,file . ,buffer) (agent-auto-test--started-task root)))
      (agent--note-session-id buffer "sid-1")
      (let* ((handoff (expand-file-name "handoff.md" root))
             (agent-handoff-files `((stub . ,handoff))))
        (write-region "Continue the fix." nil handoff nil 'silent)
        (cl-letf (((symbol-function 'agent--confirm-no-captured-prompts)
                   (lambda (&rest _) t)))
          (with-current-buffer buffer
            (agent-handoff))))
      (should-not (buffer-live-p buffer))
      (should (= (length agent-auto-test--started) 2))
      (let ((successor (car agent-auto-test--buffers)))
        (should (equal (plist-get (cdar agent-auto-test--started) :initial-prompt)
                       "Continue the fix."))
        (agent--note-session-id successor "sid-2")
        (should (equal (agent-auto-test--property file "Fix it" "AGENT_SESSION")
                       "sid-2"))
        (agent-auto-test--run)
        (should (= (length agent-auto-test--started) 2))
        (agent-auto-test--end-turn successor "Status: done: finished after handoff")
        (should (equal (agent-auto-test--tags file "Fix it") '("review")))
        (should (equal (agent-auto-test--property file "Fix it" "AGENT_RESULT")
                       "finished after handoff"))))))

(ert-deftest agent-auto-test-restart-keeps-the-task ()
  "Keep the task's link on the session a restart resumes."
  (agent-auto-test--with root
    (pcase-let ((`(,file . ,buffer) (agent-auto-test--started-task root)))
      (agent--note-session-id buffer "sid-1")
      (cl-letf (((symbol-function 'agent-restart--account) #'ignore))
        (with-current-buffer buffer
          (agent-restart)))
      (should-not (buffer-live-p buffer))
      (let ((resumed (car agent-auto-test--buffers)))
        (should (equal (plist-get (cdar agent-auto-test--started) :resume-id)
                       "sid-1"))
        (should (buffer-local-value 'agent-auto--link resumed))
        (agent-auto-test--end-turn resumed "Status: done: finished after restart")
        (should (equal (agent-auto-test--tags file "Fix it") '("review")))
        (should (equal (agent-auto-test--property file "Fix it" "AGENT_SESSION")
                       "sid-1"))))))

(ert-deftest agent-auto-test-resume-finds-the-task-again ()
  "Link a session resumed in a new buffer to the task that records it.
As after Emacs restarts: nothing in memory links them, only the id on
the task.  A session resumed while waiting has its last reply read."
  (agent-auto-test--with root
    (pcase-let ((`(,file . ,buffer) (agent-auto-test--started-task root)))
      (agent--note-session-id buffer "sid-1")
      (let ((kill-buffer-query-functions nil))
        (kill-buffer buffer))
      (let ((resumed (agent-start-session
                      (agent-session-create :backend 'stub :directory root
                                            :instance "resumed")
                      :resume-id "sid-1")))
        (with-current-buffer resumed
          (setq agent-auto-test--reply "Status: done: finished before the restart"
                agent--session-state 'awaiting-input))
        (agent-auto-test--run)
        (should (buffer-local-value 'agent-auto--link resumed))
        (should (= (length agent-auto-test--started) 2))
        (should (equal (agent-auto-test--tags file "Fix it") '("review")))
        (should (equal (agent-auto-test--property file "Fix it" "AGENT_RESULT")
                       "finished before the restart"))))))

(ert-deftest agent-auto-test-exiting-session-writes-no-result ()
  "Ignore the turns of a session that is being exited."
  (agent-auto-test--with root
    (pcase-let ((`(,file . ,buffer) (agent-auto-test--started-task root)))
      (run-hook-with-args 'agent-session-event-functions buffer 'exit-request)
      (agent-auto-test--end-turn buffer "Logged the session.")
      (should (equal (agent-auto-test--tags file "Fix it") '("agent"))))))

;; The exit of a session was known to its task only once the chain had
;; run its last skill, so the turn of every skill before it was read as
;; the task's result.
(ert-deftest agent-auto-test-chain-turns-write-no-result ()
  "Look at the end of the user's last turn, and at no turn of the exit chain.
The turn running when the exit is asked for is the user's, and its end
is read as any other.  The turns the chain then submits are its own."
  (agent-auto-test--with root
    (pcase-let ((`(,_file . ,buffer) (agent-auto-test--started-task root))
                (timer-function (symbol-function 'run-with-timer))
                (looked nil))
      (agent-auto-test--take-text)
      (agent--note-session-id buffer "sid-1")
      (let ((agent-before-exit-skill-names '("update-log" "retro"))
            (agent-before-exit-step-functions nil))
        (cl-letf (((symbol-function 'run-with-timer)
                   (lambda (seconds repeat function &rest arguments)
                     (if (eq function #'agent-auto--turn-end)
                         (push arguments looked)
                       (apply timer-function seconds repeat function
                              arguments)))))
          (agent-auto-test--exiting
            (agent-session-event buffer 'submit)
            (should-not (agent-run-skill-before-exit 'stub buffer))
            (should-not agent-auto-test--submitted)
            (agent-session-event buffer 'stop)
            (should (= (length looked) 1))
            (should (equal (caar agent-auto-test--submitted) "/update-log"))
            (setq looked nil)
            (agent-session-event buffer 'stop)
            (should (equal (caar agent-auto-test--submitted) "/retro"))
            (agent-session-event buffer 'stop)
            (should-not looked)))))))

;;;; Handover

(defconst agent-auto-test--note-regexp
  "^[ \t]*- \\(Note taken on\\|State \"\\([^\"]+\\)\"\\)[^\n]*\\\\\\\\[ \t]*$"
  "The first line of a log item that carries text, as `org-linear' reads it.
This is its `org-linear--note-regexp', copied: a note it does not match
never reaches Linear as a comment.")

(defun agent-auto-test--notes (file heading)
  "Return the notes in the log drawer of HEADING in FILE, the first first.
They are read as `org-linear' reads them: from the drawer that
`org-log-into-drawer' names, each the lines indented under an item that
`agent-auto-test--note-regexp' matches, joined by newlines."
  (agent-auto-test--at
   file heading
   (lambda ()
     (let ((limit (save-excursion (outline-next-heading) (point)))
           (name (or (org-log-into-drawer) "LOGBOOK"))
           notes)
       (when (re-search-forward (format "^[ \t]*:%s:[ \t]*$" (regexp-quote name))
                                limit t)
         (let ((beg (1+ (line-end-position)))
               (end (and (re-search-forward "^[ \t]*:END:[ \t]*$" limit t)
                         (line-beginning-position))))
           (goto-char beg)
           (while (re-search-forward agent-auto-test--note-regexp end t)
             (let ((indent (current-indentation))
                   (start (progn (forward-line 1) (point))))
               (while (and (< (point) end)
                           (> (current-indentation) indent))
                 (forward-line 1))
               (push (string-trim
                      (replace-regexp-in-string
                       "^[ \t]+" "" (buffer-substring-no-properties
                                     start (point))))
                     notes)))))
       (nreverse notes)))))

(defun agent-auto-test--keyword (file heading)
  "Return the TODO keyword of HEADING in FILE."
  (agent-auto-test--at file heading
                       (lambda ()
                         (substring-no-properties (org-get-todo-state)))))

(defun agent-auto-test--receipt-files ()
  "Return the names of the handover receipts on disk."
  (and (file-directory-p agent-auto-handover-directory)
       (directory-files agent-auto-handover-directory nil "\\.json\\'")))

(defun agent-auto-test--flush-due ()
  "Write on the tasks what a hook asked to be written, unless it is written.
Nothing else writes it before the next search, so a test that sees it
written after this has seen the hook ask for it."
  (when (timerp agent-auto--flush-timer)
    (cancel-timer agent-auto--flush-timer)
    (agent-auto--run-flush)))

(defun agent-auto-test--working-task (root &optional properties keywords)
  "Start a session by hand on the one task of a new file under ROOT.
The file declares KEYWORDS, by default TODO, DOING, WAITING and DONE,
and the task is left in DOING, as in the middle of the work.  PROPERTIES
is text added to its property drawer.  The session has the id sid-1 and
takes text; see `agent-auto-test--take-text'.  Return (FILE . BUFFER)."
  (let ((file (agent-auto-test--file
               root (format "#+TODO: %s\n* TODO Fix it\n:PROPERTIES:\n:DIR: %s\n%s:END:\nThe body.\n"
                            (or keywords "TODO DOING WAITING | DONE")
                            root (or properties "")))))
    (with-current-buffer (find-file-noselect file)
      (goto-char (point-min))
      (search-forward "Fix it")
      (let ((agent-todo-in-progress-keyword "DOING"))
        (agent-act-on-thing-at-point)))
    (let ((buffer (car agent-auto-test--buffers)))
      (agent--note-session-id buffer "sid-1")
      (agent-auto-test--take-text)
      (should (equal (agent-auto-test--keyword file "Fix it") "DOING"))
      (should-not (buffer-modified-p (find-buffer-visiting file)))
      (cons file buffer))))

(defun agent-auto-test--ask-exit (buffer)
  "Ask for session BUFFER to be exited, as `agent-exit' does.
Return the text its exit chain submitted to it first, or nil when it
submitted none."
  (let ((before (length agent-auto-test--submitted)))
    (with-current-buffer buffer
      (let ((inhibit-message t))
        (agent-exit)))
    (and (> (length agent-auto-test--submitted) before)
         (caar agent-auto-test--submitted))))

(defun agent-auto-test--answer (buffer answer)
  "End the handover turn of session BUFFER, which wrote ANSWER.
ANSWER is a plist, written as JSON, a string, written as it is, or nil
for a session that wrote nothing.  What the end of the turn asks to be
written on the task is written."
  (when answer
    (write-region (if (stringp answer) answer (json-serialize answer)) nil
                  (buffer-local-value 'agent-auto--handover-answer buffer)
                  nil 'silent))
  (agent-session-event buffer 'stop)
  (agent-auto-test--flush-due))

(defun agent-auto-test--hand-over (buffer answer)
  "Exit session BUFFER with `agent-exit', the session writing ANSWER.
ANSWER is as for `agent-auto-test--answer'.  Return the handover prompt."
  (agent-auto-test--exiting
    (prog1 (agent-auto-test--ask-exit buffer)
      (agent-auto-test--answer buffer answer))))

(defun agent-auto-test--resume (root)
  "Kill the stub session and resume it in a new buffer, linked to its task.
The session is the one of the task under ROOT, whose id is sid-1.
Return the new buffer."
  (agent-auto-test--close (car agent-auto-test--buffers))
  (let ((resumed (agent-start-session
                  (agent-session-create :backend 'stub :directory root
                                        :instance "resumed")
                  :resume-id "sid-1")))
    (agent--note-session-id resumed "sid-1")
    (agent-auto-test--run)
    (should (buffer-local-value 'agent-auto--link resumed))
    resumed))

(ert-deftest agent-auto-test-handover-is-the-first-step-of-an-exit ()
  "Ask a session linked to an open task for its handover before its skills.
The prompt names the file to write and every field, and ends with the
wait instructions when there are any.  The file is new for each exit,
and is gone once the turn has ended, when the chain goes on to the
skills."
  (agent-auto-test--with root
    (pcase-let ((`(,_file . ,buffer) (agent-auto-test--working-task root)))
      (let ((agent-before-exit-skill-names '("update-log"))
            (agent-auto-wait-instructions "Register the wait with waits add."))
        (agent-auto-test--exiting
          (let ((prompt (agent-auto-test--ask-exit buffer))
                (answer (buffer-local-value 'agent-auto--handover-answer
                                            buffer)))
            (should (= (length agent-auto-test--submitted) 1))
            (should (string-search answer prompt))
            (should-not (file-exists-p answer))
            (should (file-directory-p (file-name-directory answer)))
            (dolist (word '("the task \"Fix it\"" "`state`" "`finished`"
                            "`needs-pablo`" "`waiting-on-someone`"
                            "`interrupted`" "`summary`" "`next`" "`question`"
                            "`who`" "`what`" "`wait`" "never quote"))
              (should (string-search word prompt)))
            (should (string-suffix-p " anyone.  Register the wait with waits add."
                                     prompt))
            (should-not (string-search "\n" prompt))
            (agent-auto-test--answer buffer '(:state "interrupted"))
            (should (equal (caar agent-auto-test--submitted) "/update-log"))
            (should-not (file-exists-p (file-name-directory answer)))))))))

(ert-deftest agent-auto-test-handover-prompt-takes-the-file-name ()
  "Put the file's name where the prompt has %f and the task's heading for %t.
A doubled percent sign is one, and any other is left as it is."
  (let ((agent-auto-handover-prompt "For %t write to %f, 100%% of it, %x.")
        (agent-auto-wait-instructions ""))
    (should (equal (agent-auto--handover-prompt "/tmp/x/handover.json" "Fix it")
                   "For Fix it write to /tmp/x/handover.json, 100% of it, %x."))))

(ert-deftest agent-auto-test-handover-is-asked-only-for-an-open-task ()
  "Ask no session for a handover that has no task, or whose task is closed.
Its exit chain runs its skills alone, and nothing is written."
  (agent-auto-test--with root
    (pcase-let ((`(,file . ,buffer) (agent-auto-test--working-task root)))
      (let ((agent-before-exit-skill-names '("update-log"))
            (other (agent-start-session
                    (agent-session-create :backend 'stub :directory root
                                          :instance "other"))))
        (agent--note-session-id other "sid-2")
        (agent-auto-test--at file "Fix it" (lambda () (org-todo "DONE")))
        (with-current-buffer (find-buffer-visiting file)
          (save-buffer))
        (let ((disk (agent-auto-test--disk file)))
          (agent-auto-test--exiting
            (should (equal (agent-auto-test--ask-exit buffer) "/update-log"))
            (should (equal (agent-auto-test--ask-exit other) "/update-log"))
            (agent-session-event buffer 'stop)
            (agent-session-event other 'stop))
          (agent-auto-test--close buffer)
          (agent-auto-test--close other)
          (agent-auto-test--flush-due)
          (should (equal (agent-auto-test--disk file) disk))
          (should-not (agent-auto-test--receipt-files)))))))

(ert-deftest agent-auto-test-handover-interrupted-keeps-the-keyword ()
  "Leave a note and a one-line result on a task whose session closed mid-work.
The keyword stays, no tag is added, and the note is one Org and
`org-linear' read: an item of the task's log drawer, headed as Org heads
a note and dated, with the state, what was done and the next step on
lines of their own.  The receipt is deleted once it is written."
  (agent-auto-test--with root
    (pcase-let ((`(,file . ,buffer) (agent-auto-test--working-task root)))
      (agent-auto-test--hand-over
       buffer '(:state "interrupted"
                :summary "Read the parser and found\nthe bug"
                :next "write the fix"))
      (should (equal (agent-auto-test--keyword file "Fix it") "DOING"))
      (should-not (agent-auto-test--tags file "Fix it"))
      (should (equal (agent-auto-test--property file "Fix it" "AGENT_RESULT")
                     "Interrupted: Read the parser and found the bug. Next: write the fix"))
      (should (equal (agent-auto-test--notes file "Fix it")
                     '("Session closed: interrupted.\nDone: Read the parser and found the bug\nNext: write the fix")))
      (should (string-match-p
               (concat ":LOGBOOK:\n"
                       "- Note taken on \\[[0-9]\\{4\\}-[0-9][0-9]-[0-9][0-9] [[:alpha:]]+ [0-9][0-9]:[0-9][0-9]\\] \\\\\\\\\n"
                       "  Session closed: interrupted\\.\n"
                       "  Done: Read the parser and found the bug\n"
                       "  Next: write the fix\n"
                       ":END:\n")
               (agent-auto-test--disk file)))
      (should (agent-auto-test--property file "Fix it" "AGENT_HANDOVER"))
      (should-not (buffer-modified-p (find-buffer-visiting file)))
      (should-not agent-auto--handovers)
      (should-not (agent-auto-test--receipt-files)))))

(defun agent-auto-test--org-note (lines time)
  "Add a note of LINES, taken at TIME, to the task at point as Org does.
The note is stored by the function that stores one written in the note
buffer of `org-add-note'."
  (move-marker org-log-note-marker (point))
  (move-marker org-log-note-return-to (point))
  (let ((org-log-note-purpose 'note)
        (org-log-note-effective-time time)
        (org-log-note-window-configuration (current-window-configuration))
        (org-note-abort nil)
        (org-log-post-message nil)
        (inhibit-message t))
    (with-current-buffer (generate-new-buffer "*Org Note*")
      (insert (string-join lines "\n"))
      (org-store-log-note))))

(ert-deftest agent-auto-test-note-is-written-as-org-writes-one ()
  "Write a note exactly as Org's own note command does.
Into a new log drawer and into one that has a note, in a task with a
body and in one at the end of the file, and where notes go when Org puts
them in no drawer."
  (dolist (org-log-into-drawer '(t "NOTES" nil))
    (dolist (text '("* TODO One\n:PROPERTIES:\n:DIR: /tmp/\n:END:\nThe body.\n* TODO Two\n"
                    "* TODO One\n:LOGBOOK:\n- Note taken on [2026-11-17 Tue 10:00] \\\\\n  An earlier note.\n:END:\n"
                    "* TODO One"))
      (let ((time (encode-time '(0 30 8 18 11 2026 nil -1 nil)))
            (lines '("Session closed: interrupted." "Done: it"))
            ours theirs)
        (agent-test-helper-with-org-file text
          (goto-char (point-min))
          (agent-auto--add-note lines time)
          (setq ours (buffer-string)))
        (agent-test-helper-with-org-file text
          (goto-char (point-min))
          (agent-auto-test--org-note lines time)
          (setq theirs (buffer-string)))
        (should (string-search "Done: it" ours))
        (should (equal ours theirs))))))

(ert-deftest agent-auto-test-handover-finished-and-needs-the-user ()
  "Tag a task for review when its session closed finished, and blocked with
the question when it closed needing the user.
The tag replaces whichever result tag the task carried, and a session
that closed interrupted removes it."
  (agent-auto-test--with root
    (pcase-let ((`(,file . ,buffer) (agent-auto-test--working-task root)))
      (agent-auto-test--hand-over
       buffer '(:state "finished" :summary "Fixed the parser."
                :next "review the diff"))
      (should (equal (agent-auto-test--tags file "Fix it") '("review")))
      (should (equal (agent-auto-test--property file "Fix it" "AGENT_RESULT")
                     "Finished: Fixed the parser. Next: review the diff"))
      (should (equal (agent-auto-test--keyword file "Fix it") "DOING"))
      (setq buffer (agent-auto-test--resume root))
      (agent-auto-test--hand-over
       buffer '(:state "needs-pablo" :summary "Compared the two accounts"
                :next "pay it" :question "Which account pays?"))
      (should (equal (agent-auto-test--tags file "Fix it") '("blocked")))
      (should (equal (agent-auto-test--property file "Fix it" "AGENT_RESULT")
                     "Needs a decision: Which account pays? Compared the two accounts. Next: pay it"))
      (should (equal (car (agent-auto-test--notes file "Fix it"))
                     "Session closed: needs a decision.\nDone: Compared the two accounts\nNext: pay it\nQuestion: Which account pays?"))
      (setq buffer (agent-auto-test--resume root))
      (agent-auto-test--hand-over
       buffer '(:state "interrupted" :summary "Paid half" :next "pay the rest"))
      (should-not (agent-auto-test--tags file "Fix it"))
      (should (= (length (agent-auto-test--notes file "Fix it")) 3)))))

(ert-deftest agent-auto-test-handover-replaces-the-result ()
  "Write the result of each turn as before, and the handover over it.
The ready tag of a task the timer started goes with the result tags."
  (agent-auto-test--with root
    (pcase-let ((`(,file . ,buffer) (agent-auto-test--started-task root)))
      (agent--note-session-id buffer "sid-1")
      (agent-auto-test--take-text)
      (agent-auto-test--end-turn buffer "Status: waiting on you: which one?")
      (should (equal (agent-auto-test--tags file "Fix it") '("blocked")))
      (should (equal (agent-auto-test--property file "Fix it" "AGENT_RESULT")
                     "which one?"))
      (agent-auto-test--hand-over
       buffer '(:state "interrupted" :summary "Asked which one" :next "wait"))
      (should-not (agent-auto-test--tags file "Fix it"))
      (should (equal (agent-auto-test--property file "Fix it" "AGENT_RESULT")
                     "Interrupted: Asked which one. Next: wait")))))

(ert-deftest agent-auto-test-chain-turns-leave-the-handover-alone ()
  "Write nothing on the task for a turn of the chain that follows the handover.
A skill that stops at a permission prompt, or shows a dialog, leaves the
task as the handover left it; before the exit was asked for, the same
prompt marks the task blocked."
  (agent-auto-test--with root
    (pcase-let ((`(,file . ,buffer) (agent-auto-test--working-task root))
                (agent-before-exit-skill-names '("update-log")))
      (agent-session-event buffer 'blocked)
      (should (equal (agent-auto-test--tags file "Fix it") '("blocked")))
      (agent-auto-test--exiting
        (agent-auto-test--ask-exit buffer)
        (agent-auto-test--answer
         buffer '(:state "finished" :summary "Fixed it"))
        (should (equal (caar agent-auto-test--submitted) "/update-log"))
        (let ((agent-session-input-state-functions
               (list (lambda (_session) (list :dialog t)))))
          (agent-session-event buffer 'blocked)
          (agent-auto--check-dialog buffer)
          (agent-auto-test--run)))
      (should (equal (agent-auto-test--tags file "Fix it") '("review")))
      (should (equal (agent-auto-test--property file "Fix it" "AGENT_RESULT")
                     "Finished: Fixed it.")))))

(ert-deftest agent-auto-test-handover-waits-for-a-saved-buffer ()
  "Write nothing of a handover while the task's buffer has unsaved edits.
The receipt is kept on disk, and everything is written once the buffer
is saved, by the save itself."
  (agent-auto-test--with root
    (pcase-let* ((`(,file . ,buffer) (agent-auto-test--working-task root))
                 (org (find-buffer-visiting file)))
      (with-current-buffer org
        (goto-char (point-max))
        (insert "Typing.\n"))
      (let ((text (with-current-buffer org (buffer-string))))
        (agent-auto-test--hand-over
         buffer '(:state "finished" :summary "Fixed it" :next "review it"))
        (agent-auto-test--run)
        (should (equal (with-current-buffer org (buffer-string)) text))
        (should (buffer-modified-p org)))
      (should (= (length agent-auto--handovers) 1))
      (should (= (length (agent-auto-test--receipt-files)) 1))
      (with-current-buffer org
        (save-buffer))
      (agent-auto-test--flush-due)
      (should (equal (agent-auto-test--tags file "Fix it") '("review")))
      (should (equal (agent-auto-test--notes file "Fix it")
                     '("Session closed: finished.\nDone: Fixed it\nNext: review it")))
      (should (string-match-p "Typing" (agent-auto-test--disk file)))
      (should (string-match-p "AGENT_HANDOVER" (agent-auto-test--disk file)))
      (should-not (buffer-modified-p org))
      (should-not agent-auto--handovers)
      (should-not (agent-auto-test--receipt-files)))))

(ert-deftest agent-auto-test-handover-survives-a-restart ()
  "Write at the next start a handover that Emacs quit before writing.
The receipt on disk is all that is left of it: the unsaved edits, the
session and what was in memory are gone."
  (agent-auto-test--with root
    (pcase-let* ((`(,file . ,buffer) (agent-auto-test--working-task root))
                 (org (find-buffer-visiting file)))
      (with-current-buffer org
        (goto-char (point-max))
        (insert "Typing.\n"))
      (agent-auto-test--hand-over
       buffer '(:state "needs-pablo" :summary "Found two ways" :next "pick one"
                :question "Which way?"))
      (should (= (length (agent-auto-test--receipt-files)) 1))
      (let ((kill-buffer-query-functions nil))
        (kill-buffer buffer)
        (with-current-buffer org
          (set-buffer-modified-p nil)
          (kill-buffer)))
      (setq agent-auto--handovers nil
            agent-auto--pending nil)
      (agent-auto--load-handovers)
      (should (= (length agent-auto--handovers) 1))
      (agent-auto--flush)
      (should (equal (agent-auto-test--tags file "Fix it") '("blocked")))
      (should (equal (agent-auto-test--notes file "Fix it")
                     '("Session closed: needs a decision.\nDone: Found two ways\nNext: pick one\nQuestion: Which way?")))
      (should-not (string-match-p "Typing" (agent-auto-test--disk file)))
      (should (string-match-p "AGENT_HANDOVER" (agent-auto-test--disk file)))
      (should-not (agent-auto-test--receipt-files)))))

(ert-deftest agent-auto-test-killed-session-leaves-a-note ()
  "Say in the task's log that a session killed without `agent-exit' left no handover.
Nothing else on the task changes.  A session that closed with a handover
gets no second note when its buffer is killed, and neither does one
killed for a handoff or a restart, which goes on in a new buffer."
  (agent-auto-test--with root
    (pcase-let ((`(,file . ,buffer) (agent-auto-test--working-task root)))
      (agent-auto-test--close buffer)
      (agent-auto-test--flush-due)
      (should (equal (agent-auto-test--notes file "Fix it")
                     '("Session closed without a handover: its buffer was killed.")))
      (should (equal (agent-auto-test--keyword file "Fix it") "DOING"))
      (should-not (agent-auto-test--tags file "Fix it"))
      (should-not (agent-auto-test--property file "Fix it" "AGENT_RESULT"))
      (should-not (agent-auto-test--receipt-files))
      (setq buffer (agent-auto-test--resume root))
      (agent-auto-test--hand-over buffer '(:state "interrupted" :summary "It"))
      (should (= (length (agent-auto-test--notes file "Fix it")) 2))
      (agent-auto-test--close buffer)
      (agent-auto-test--flush-due)
      (should (= (length (agent-auto-test--notes file "Fix it")) 2))
      (should (equal (car (agent-auto-test--notes file "Fix it"))
                     "Session closed: interrupted.\nDone: It"))))
  (agent-auto-test--with root
    (pcase-let ((`(,file . ,buffer) (agent-auto-test--working-task root)))
      (let* ((handoff (expand-file-name "handoff.md" root))
             (agent-handoff-files `((stub . ,handoff))))
        (write-region "Continue the fix." nil handoff nil 'silent)
        (add-hook 'kill-buffer-hook #'agent-auto--session-killed)
        (unwind-protect
            (cl-letf (((symbol-function 'agent--confirm-no-captured-prompts)
                       (lambda (&rest _) t))
                      ((symbol-function 'agent-restart--account) #'ignore))
              (with-current-buffer buffer
                (agent-handoff))
              (agent--note-session-id (car agent-auto-test--buffers) "sid-2")
              (with-current-buffer (car agent-auto-test--buffers)
                (agent-restart)))
          (remove-hook 'kill-buffer-hook #'agent-auto--session-killed)))
      (agent-auto-test--flush-due)
      (should (= (length agent-auto-test--started) 3))
      (should-not (agent-auto-test--notes file "Fix it"))
      (should-not (agent-auto-test--receipt-files)))))

(ert-deftest agent-auto-test-missing-and-malformed-receipts ()
  "Go on with the exit, and say so on the task, when no handover can be read.
A session that wrote nothing, text that is no JSON, and JSON that names
no known state each leave a note saying which, and the next skill of the
chain is submitted all the same.  Nothing of a receipt that cannot be
read is repeated."
  (agent-auto-test--with root
    (pcase-let ((`(,file . ,buffer) (agent-auto-test--working-task root))
                (agent-before-exit-skill-names '("update-log")))
      (dolist (case '((nil . "it wrote no receipt")
                      ("{\"state\": \"finished\", the secret" . "its receipt is not valid JSON")
                      ("{\"state\": \"done\", \"summary\": \"the secret\"}"
                       . "its receipt names no known state")
                      ("[\"finished\"]" . "its receipt names no known state")))
        (agent-auto-test--hand-over buffer (car case))
        (should (equal (caar agent-auto-test--submitted) "/update-log"))
        (should (equal (car (agent-auto-test--notes file "Fix it"))
                       (format "Session closed without a handover: %s."
                               (cdr case))))
        (should-not (string-match-p "secret" (agent-auto-test--disk file)))
        (should (equal (agent-auto-test--keyword file "Fix it") "DOING"))
        (should-not (agent-auto-test--property file "Fix it" "AGENT_RESULT"))
        (should-not (agent-auto-test--receipt-files))
        (setq buffer (agent-auto-test--resume root))))))

(ert-deftest agent-auto-test-note-shows-every-field ()
  "Show in the note each field a handover gave, whatever its summary says.
A summary that names neither the question nor who is waited for leaves
them in the note all the same, each in full and on a line of its own."
  (agent-auto-test--with root
    (pcase-let ((`(,file . ,buffer) (agent-auto-test--working-task root))
                (long (mapconcat #'identity (make-list 80 "word") " ")))
      (agent-auto-test--hand-over
       buffer (list :state "waiting-on-someone" :summary "Sent it." :next "wait"
                    :who "the accountant" :what long :question "Why?"))
      (should (equal (car (agent-auto-test--notes file "Fix it"))
                     (concat "Session closed: waiting on someone.\nDone: Sent it.\n"
                             "Next: wait\nQuestion: Why?\n"
                             "Waiting on: the accountant\nWaiting for: " long)))
      (should (string-prefix-p
               "Waiting on the accountant: Why? Sent it. Next: wait"
               (agent-auto-test--property file "Fix it" "AGENT_RESULT"))))))

(ert-deftest agent-auto-test-two-closes-before-a-save ()
  "Write the handovers of two closes in order once the buffer is saved.
Both notes are added, the later above the earlier as Org orders a log,
and the task shows the result of the later.  A receipt that is still on
disk after it was written, as when Emacs was killed before deleting it,
is deleted and not written again."
  (agent-auto-test--with root
    (pcase-let* ((`(,file . ,buffer) (agent-auto-test--working-task root))
                 (org (find-buffer-visiting file))
                 (kept (expand-file-name "kept/" root)))
      (with-current-buffer org
        (goto-char (point-max))
        (insert "Typing.\n"))
      (agent-auto-test--hand-over
       buffer '(:state "needs-pablo" :summary "First" :question "Which?"))
      (setq buffer (agent-auto-test--resume root))
      (agent-auto-test--hand-over buffer '(:state "finished" :summary "Second"))
      (should (= (length (agent-auto-test--receipt-files)) 2))
      (copy-directory agent-auto-handover-directory kept nil t t)
      (with-current-buffer org
        (save-buffer))
      (agent-auto-test--flush-due)
      (should (equal (agent-auto-test--notes file "Fix it")
                     '("Session closed: finished.\nDone: Second"
                       "Session closed: needs a decision.\nDone: First\nQuestion: Which?")))
      (should (equal (agent-auto-test--tags file "Fix it") '("review")))
      (should (equal (agent-auto-test--property file "Fix it" "AGENT_RESULT")
                     "Finished: Second."))
      (should-not (agent-auto-test--receipt-files))
      (let ((last (agent-auto-test--property file "Fix it" "AGENT_HANDOVER")))
        (should (equal (concat last ".json")
                       (car (last (directory-files kept nil "\\.json\\'")))))
        (copy-file (expand-file-name (concat last ".json") kept)
                   (expand-file-name (concat last ".json")
                                     agent-auto-handover-directory))
        (agent-auto--load-handovers)
        (should (= (length agent-auto--handovers) 1))
        (agent-auto--flush)
        (should (= (length (agent-auto-test--notes file "Fix it")) 2))
        (should-not (agent-auto-test--receipt-files))
        (should-not agent-auto--handovers)))))

(ert-deftest agent-auto-test-late-receipt-undoes-nothing ()
  "Add the note of a receipt written late, and leave what happened since.
After the session was resumed and its next turn left a result, after the
task was closed, and after the task was given another session: the note
is there each time, and the result, the tag and the keyword are those
the task had."
  (agent-auto-test--with root
    (pcase-let* ((`(,file . ,buffer) (agent-auto-test--working-task root))
                 (org (find-buffer-visiting file)))
      (with-current-buffer org
        (goto-char (point-max))
        (insert "Typing.\n"))
      (agent-auto-test--hand-over
       buffer '(:state "needs-pablo" :summary "Stopped" :question "Go on?"))
      (setq buffer (agent-auto-test--resume root))
      (run-hook-with-args 'agent-session-event-functions buffer 'user-submit)
      (agent-auto-test--end-turn buffer "Status: done: shipped it")
      (with-current-buffer org
        (save-buffer))
      (agent-auto-test--flush-due)
      (should (equal (agent-auto-test--notes file "Fix it")
                     '("Session closed: needs a decision.\nDone: Stopped\nQuestion: Go on?")))
      (should (equal (agent-auto-test--tags file "Fix it") '("review")))
      (should (equal (agent-auto-test--property file "Fix it" "AGENT_RESULT")
                     "shipped it"))
      (should-not (agent-auto-test--receipt-files))))
  (agent-auto-test--with root
    (pcase-let* ((`(,file . ,buffer) (agent-auto-test--working-task root))
                 (org (find-buffer-visiting file)))
      (with-current-buffer org
        (goto-char (point-max))
        (insert "Typing.\n"))
      (agent-auto-test--hand-over
       buffer '(:state "needs-pablo" :summary "Stopped" :question "Go on?"))
      (agent-auto-test--at file "Fix it" (lambda () (org-todo "DONE")))
      (with-current-buffer org
        (save-buffer))
      (agent-auto-test--flush-due)
      (should (= (length (agent-auto-test--notes file "Fix it")) 1))
      (should (equal (agent-auto-test--keyword file "Fix it") "DONE"))
      (should-not (agent-auto-test--tags file "Fix it"))
      (should-not (agent-auto-test--property file "Fix it" "AGENT_RESULT"))
      (should-not (agent-auto-test--receipt-files))))
  (agent-auto-test--with root
    (pcase-let* ((`(,file . ,buffer)
                  (agent-auto-test--working-task root ":ID: task-1\n"))
                 (org (find-buffer-visiting file)))
      (with-current-buffer org
        (goto-char (point-max))
        (insert "Typing.\n"))
      (agent-auto-test--hand-over
       buffer '(:state "finished" :summary "Stopped"))
      (agent-auto-test--at
       file "Fix it" (lambda () (org-entry-put nil "AGENT_SESSION" "sid-9")))
      (with-current-buffer org
        (save-buffer))
      (agent-auto-test--flush-due)
      (should (= (length (agent-auto-test--notes file "Fix it")) 1))
      (should (equal (agent-auto-test--property file "Fix it" "AGENT_SESSION")
                     "sid-9"))
      (should-not (agent-auto-test--tags file "Fix it"))
      (should-not (agent-auto-test--property file "Fix it" "AGENT_RESULT"))
      (should-not (agent-auto-test--receipt-files)))))

(ert-deftest agent-auto-test-late-receipt-finds-a-task-given-another-session ()
  "Write the note of a receipt whose task was linked to another session since.
The task has no Org ID and no longer records the session that closed;
the receipt finds it all the same, adds its note, and leaves the task
with the session, the tags and the result it has."
  (agent-auto-test--with root
    (pcase-let* ((`(,file . ,buffer) (agent-auto-test--working-task root))
                 (org (find-buffer-visiting file))
                 (second (agent-auto-test--open-session root "second" "sid-2")))
      (with-current-buffer org
        (goto-char (point-max))
        (insert "Typing.\n"))
      (agent-auto-test--hand-over buffer '(:state "finished" :summary "It"))
      (agent-auto-test--close buffer)
      (agent-auto-test--completing "." _offered
        (agent-auto-test--answering t _asked
          (with-current-buffer second
            (agent-link-session))))
      (should (buffer-modified-p org))
      (with-current-buffer org
        (save-buffer))
      (agent-auto-test--flush-due)
      (should (equal (agent-auto-test--notes file "Fix it")
                     '("Session closed: finished.\nDone: It"
                       "Session sid-1 (stub) is no longer linked to this task: another took its place.")))
      (should (equal (agent-auto-test--property file "Fix it" "AGENT_SESSION")
                     "sid-2"))
      (should-not (agent-auto-test--tags file "Fix it"))
      (should-not (agent-auto-test--property file "Fix it" "AGENT_RESULT"))
      (should-not (agent-auto-test--receipt-files)))))

(ert-deftest agent-auto-test-lost-task-keeps-the-receipt ()
  "Keep the receipt of a task that cannot be found, and say so once.
Such a task has no Org ID and no longer records the session."
  (agent-auto-test--with root
    (pcase-let* ((`(,file . ,buffer) (agent-auto-test--working-task root))
                 (org (find-buffer-visiting file)))
      (with-current-buffer org
        (goto-char (point-max))
        (insert "Typing.\n"))
      (agent-auto-test--hand-over buffer '(:state "finished" :summary "It"))
      (agent-auto-test--at
       file "Fix it" (lambda () (org-entry-put nil "AGENT_SESSION" "sid-9")))
      (with-current-buffer org
        (save-buffer))
      (agent-test-helper-with-messages messages
        (agent-auto-test--flush-due)
        (should (string-match-p "no task “Fix it” for a handover" messages)))
      (should (= (length (agent-auto-test--receipt-files)) 1))
      (agent-test-helper-with-messages messages
        (agent-auto--flush)
        (agent-auto--load-handovers)
        (agent-auto--flush)
        (should-not (string-match-p "for a handover" messages)))
      (should (= (length (agent-auto-test--receipt-files)) 1))
      (should-not (agent-auto-test--notes file "Fix it")))))

;;;; Waiting on someone

(defconst agent-auto-test--waiting
  '(:state "waiting-on-someone" :summary "Asked for the invoice"
    :next "pay it" :who "the accountant" :what "the invoice" :wait "w-17")
  "The handover of a session that closes waiting on someone.")

(ert-deftest agent-auto-test-handover-waiting-on-someone ()
  "Set a task waiting when its session closed waiting on someone, and back.
The task moves to the waiting keyword and records the keyword it had and
the wait its session registered; the note says who is waited for and for
what.  Org logs nothing of the change of keyword and asks for no note,
also where the keyword is set up to be logged.  Resuming the session
changes nothing; a turn that starts in it takes the task back to its
keyword, and both properties go."
  (dolist (keywords '(nil "TODO(t) DOING(d) WAITING(w@/!) | DONE(x@)"))
    (agent-auto-test--with root
      (pcase-let* ((post-command-hook nil)
                   (`(,file . ,buffer)
                    (agent-auto-test--working-task root nil keywords)))
        (agent-auto-test--hand-over buffer agent-auto-test--waiting)
        (should-not post-command-hook)
        (should (equal (agent-auto-test--keyword file "Fix it") "WAITING"))
        (should (equal (agent-auto-test--property file "Fix it" "AGENT_KEYWORD")
                       "DOING"))
        (should (equal (agent-auto-test--property file "Fix it" "AGENT_WAIT")
                       "w-17"))
        (should-not (agent-auto-test--tags file "Fix it"))
        (should (equal (agent-auto-test--notes file "Fix it")
                       '("Session closed: waiting on someone.\nDone: Asked for the invoice\nNext: pay it\nWaiting on: the accountant\nWaiting for: the invoice")))
        (should (equal (agent-auto-test--property file "Fix it" "AGENT_RESULT")
                       "Waiting on the accountant: Asked for the invoice. Next: pay it"))
        (should (string-match-p "^\\* WAITING Fix it"
                                (agent-auto-test--disk file)))
        (should-not (string-match-p "State \"" (agent-auto-test--disk file)))
        (setq buffer (agent-auto-test--resume root))
        (agent-auto-test--flush-due)
        (should (equal (agent-auto-test--keyword file "Fix it") "WAITING"))
        (agent-session-event buffer 'user-submit)
        (agent-auto-test--flush-due)
        (should-not post-command-hook)
        (should (equal (agent-auto-test--keyword file "Fix it") "DOING"))
        (should-not (agent-auto-test--property file "Fix it" "AGENT_KEYWORD"))
        (should-not (agent-auto-test--property file "Fix it" "AGENT_WAIT"))
        (should (= (length (agent-auto-test--notes file "Fix it")) 1))
        (should (string-match-p "^\\* DOING Fix it" (agent-auto-test--disk file)))
        (should-not (string-match-p "State \"" (agent-auto-test--disk file)))
        (should-not (buffer-modified-p (find-buffer-visiting file)))))))

(ert-deftest agent-auto-test-waiting-survives-the-exit-chain ()
  "Keep a task waiting through every turn of the chain that closes its session.
The skills that follow the handover, the activity of their turns and the
exit itself are no resumption of the work.  A turn started in the
session afterwards is, and takes the task back to its keyword."
  (agent-auto-test--with root
    (pcase-let ((`(,file . ,buffer) (agent-auto-test--working-task root))
                (agent-before-exit-skill-names '("update-log" "retro")))
      (agent-auto-test--exiting
        (agent-auto-test--ask-exit buffer)
        (agent-auto-test--answer buffer agent-auto-test--waiting)
        (should (equal (agent-auto-test--keyword file "Fix it") "WAITING"))
        (should (equal (caar agent-auto-test--submitted) "/update-log"))
        (agent-session-event buffer 'activity)
        (agent-session-event buffer 'stop)
        (should (equal (caar agent-auto-test--submitted) "/retro"))
        (agent-session-event buffer 'activity)
        (agent-session-event buffer 'stop)
        (should (eq (plist-get (buffer-local-value 'agent--before-exit buffer)
                               :state)
                    'closing))
        (agent-submit "/exit" buffer)
        (agent-auto-test--flush-due)
        (should-not agent-auto--returning)
        (should (equal (agent-auto-test--keyword file "Fix it") "WAITING"))
        (should (equal (agent-auto-test--property file "Fix it" "AGENT_KEYWORD")
                       "DOING")))
      (setq buffer (agent-auto-test--resume root))
      (agent-session-event buffer 'submit)
      (agent-auto-test--flush-due)
      (should (equal (agent-auto-test--keyword file "Fix it") "DOING"))
      (should-not (agent-auto-test--property file "Fix it" "AGENT_KEYWORD")))))

(ert-deftest agent-auto-test-wait-over-frees-that-task-alone ()
  "Take a task out of waiting when the hook says its wait is over.
Its own session stays closed, and another session is open in the
project.  The task alone goes back to its keyword, with a note: the
string the hook answered, or, for any other answer, that the wait is
over.  A task whose wait is not over stays, and so does the keyword of a
task that was changed by hand, whose properties go all the same.  The
first function to answer decides, and one that signals is passed over.
The tasks are found by ripgrep: a file that records no wait is not
visited, and without a function on the hook none is."
  (agent-auto-test--with root
    (let* ((task (lambda (heading keyword session wait)
                   (format "* %s %s\n:PROPERTIES:\n:DIR: %s\n:AGENT_SESSION: %s\n:AGENT_KEYWORD: DOING\n:AGENT_WAIT: %s\n:END:\n"
                           keyword heading root session wait)))
           (file (agent-auto-test--file
                  root (concat "#+TODO: TODO DOING WAITING | DONE\n"
                               (funcall task "First" "WAITING" "sid-1" "w-1")
                               (funcall task "Second" "WAITING" "sid-2" "w-2")
                               (funcall task "Third" "TODO" "sid-3" "w-3")
                               (funcall task "Fourth" "WAITING" "sid-4" "w-4"))))
           (other (agent-auto-test--file root "* TODO Elsewhere\n" "other.org"))
           (asked nil))
      (agent-start-session
       (agent-session-create :backend 'stub :directory root :instance "open"))
      (agent-auto-test--run)
      (should-not (find-buffer-visiting file))
      (let ((agent-auto-wait-over-functions
             (list (lambda (_wait) (error "Engine down"))
                   (lambda (wait)
                     (push wait asked)
                     (pcase wait
                       ("w-1" "Ann replied.\n  She agrees.")
                       ((or "w-3" "w-4") t)))
                   (lambda (wait)
                     (and (equal wait "w-1") "Never asked")))))
        (agent-auto-test--run))
      (should (equal (sort asked #'string<) '("w-1" "w-2" "w-3" "w-4")))
      (should-not (find-buffer-visiting other))
      (should (equal (agent-auto-test--keyword file "First") "DOING"))
      (should-not (agent-auto-test--property file "First" "AGENT_KEYWORD"))
      (should-not (agent-auto-test--property file "First" "AGENT_WAIT"))
      (should (equal (agent-auto-test--notes file "First")
                     '("Ann replied.\nShe agrees.")))
      (should (equal (agent-auto-test--keyword file "Second") "WAITING"))
      (should (equal (agent-auto-test--property file "Second" "AGENT_WAIT")
                     "w-2"))
      (should-not (agent-auto-test--notes file "Second"))
      (should (equal (agent-auto-test--keyword file "Third") "TODO"))
      (should-not (agent-auto-test--property file "Third" "AGENT_KEYWORD"))
      (should-not (agent-auto-test--property file "Third" "AGENT_WAIT"))
      (should (equal (agent-auto-test--notes file "Third")
                     '("The wait is over.")))
      (should (equal (agent-auto-test--keyword file "Fourth") "DOING"))
      (should (equal (agent-auto-test--notes file "Fourth")
                     '("The wait is over: the task is DOING again.")))
      (should (string-match-p "^\\* DOING First" (agent-auto-test--disk file)))
      (should-not (buffer-modified-p (find-buffer-visiting file)))
      (should (= (length agent-auto-test--started) 1)))))

(ert-deftest agent-auto-test-wait-over-waits-for-a-saved-buffer ()
  "Leave a waiting task alone while its buffer has unsaved edits."
  (agent-auto-test--with root
    (let* ((file (agent-auto-test--file
                  root (concat "#+TODO: TODO DOING WAITING | DONE\n"
                               "* WAITING First\n:PROPERTIES:\n:AGENT_KEYWORD: DOING\n:AGENT_WAIT: w-1\n:END:\n")))
           (org (find-file-noselect file))
           (agent-auto-wait-over-functions (list (lambda (_wait) t))))
      (with-current-buffer org
        (goto-char (point-max))
        (insert "Typing.\n"))
      (agent-auto-test--run)
      (should (equal (agent-auto-test--keyword file "First") "WAITING"))
      (with-current-buffer org
        (save-buffer))
      (agent-auto-test--run)
      (should (equal (agent-auto-test--keyword file "First") "DOING")))))

(ert-deftest agent-auto-test-waiting-keyword-can-be-off ()
  "Leave the keyword alone when the option is nil or the file lacks the keyword.
The note, the result and the tag are written all the same, and nothing
is recorded of a keyword or a wait."
  (dolist (case '((nil . nil) ("WAITING" . "TODO DOING | DONE")))
    (agent-auto-test--with root
      (pcase-let ((`(,file . ,buffer)
                   (agent-auto-test--working-task root nil (cdr case)))
                  (agent-auto-waiting-keyword (car case)))
        (agent-test-helper-with-messages messages
          (agent-auto-test--hand-over buffer agent-auto-test--waiting)
          (let ((case-fold-search nil))
            (should-not (string-match-p "WAITING\\|keyword" messages))))
        (should (equal (agent-auto-test--keyword file "Fix it") "DOING"))
        (should-not (agent-auto-test--property file "Fix it" "AGENT_KEYWORD"))
        (should-not (agent-auto-test--property file "Fix it" "AGENT_WAIT"))
        (should (= (length (agent-auto-test--notes file "Fix it")) 1))
        (should (string-prefix-p
                 "Waiting on the accountant"
                 (agent-auto-test--property file "Fix it" "AGENT_RESULT")))))))

(ert-deftest agent-auto-test-late-receipt-sets-nothing-waiting ()
  "Leave the keyword alone when a receipt that asks for waiting is written late.
After a turn started in the resumed session, and after the keyword was
changed by hand: the note is added, and the task keeps its keyword."
  (agent-auto-test--with root
    (pcase-let* ((`(,file . ,buffer) (agent-auto-test--working-task root))
                 (org (find-buffer-visiting file)))
      (with-current-buffer org
        (goto-char (point-max))
        (insert "Typing.\n"))
      (agent-auto-test--hand-over buffer agent-auto-test--waiting)
      (setq buffer (agent-auto-test--resume root))
      (agent-session-event buffer 'submit)
      (with-current-buffer org
        (save-buffer))
      (agent-auto-test--flush-due)
      (should (= (length (agent-auto-test--notes file "Fix it")) 1))
      (should (equal (agent-auto-test--keyword file "Fix it") "DOING"))
      (should-not (agent-auto-test--property file "Fix it" "AGENT_KEYWORD"))
      (should-not (agent-auto-test--property file "Fix it" "AGENT_WAIT"))
      (should-not (agent-auto-test--receipt-files))))
  (agent-auto-test--with root
    (pcase-let* ((`(,file . ,buffer) (agent-auto-test--working-task root))
                 (org (find-buffer-visiting file)))
      (with-current-buffer org
        (goto-char (point-max))
        (insert "Typing.\n"))
      (agent-auto-test--hand-over buffer agent-auto-test--waiting)
      (agent-auto-test--at file "Fix it" (lambda () (org-todo "TODO")))
      (with-current-buffer org
        (save-buffer))
      (agent-auto-test--flush-due)
      (should (= (length (agent-auto-test--notes file "Fix it")) 1))
      (should (equal (agent-auto-test--keyword file "Fix it") "TODO"))
      (should-not (agent-auto-test--property file "Fix it" "AGENT_KEYWORD"))
      (should-not (agent-auto-test--receipt-files)))))

(ert-deftest agent-auto-test-hand-changed-keyword-is-left-alone ()
  "Keep the keyword a waiting task was given by hand when its session works on.
The properties that recorded the wait go all the same."
  (agent-auto-test--with root
    (pcase-let ((`(,file . ,buffer) (agent-auto-test--working-task root)))
      (agent-auto-test--hand-over buffer agent-auto-test--waiting)
      (agent-auto-test--at file "Fix it" (lambda () (org-todo "TODO")))
      (with-current-buffer (find-buffer-visiting file)
        (save-buffer))
      (setq buffer (agent-auto-test--resume root))
      (agent-session-event buffer 'user-submit)
      (agent-auto-test--flush-due)
      (should (equal (agent-auto-test--keyword file "Fix it") "TODO"))
      (should-not (agent-auto-test--property file "Fix it" "AGENT_KEYWORD"))
      (should-not (agent-auto-test--property file "Fix it" "AGENT_WAIT")))))

;;;; Acting on a task that records a session

(defmacro agent-auto-test--keeping-buffer (&rest body)
  "Evaluate BODY and return to the current buffer and windows.
A command that shows a session leaves it current, and the agenda
fixture then quits whatever buffer that is."
  (declare (indent 0) (debug (body)))
  `(save-window-excursion (save-current-buffer ,@body)))

(defmacro agent-auto-test--acting (shown &rest body)
  "Evaluate BODY with SHOWN bound to the buffers `pop-to-buffer' is given.
Nothing may be typed into or submitted to a session."
  (declare (indent 1) (debug (symbolp body)))
  `(let ((pop (symbol-function 'pop-to-buffer))
         ,shown)
     (cl-letf (((symbol-function 'pop-to-buffer)
                (lambda (buffer &rest arguments)
                  (when (memq buffer agent-auto-test--buffers)
                    (push buffer ,shown))
                  (apply pop buffer arguments)))
               ((symbol-function 'agent-submit)
                (lambda (&rest _) (ert-fail "Submitted to a session")))
               ((symbol-function 'agent-send-string)
                (lambda (&rest _) (ert-fail "Typed into a session"))))
       ,@body)))

(defun agent-auto-test--act (file &optional prefix command heading)
  "Call COMMAND with PREFIX on HEADING of FILE, else on its first heading.
COMMAND defaults to `agent-act-on-thing-at-point'."
  (save-window-excursion
    (with-current-buffer (find-file-noselect file)
      (goto-char (point-min))
      (when heading
        (search-forward heading))
      (funcall (or command #'agent-act-on-thing-at-point) prefix))))

(defun agent-auto-test--closed-task (root id)
  "Start the one task under ROOT, give its session ID and close the session.
Return the task's file."
  (pcase-let ((`(,file . ,buffer) (agent-auto-test--started-task root))
              (kill-buffer-query-functions nil))
    (agent--note-session-id buffer id)
    (kill-buffer buffer)
    file))

(ert-deftest agent-auto-test-acting-shows-the-live-session ()
  "Show the live session a task records, and send it nothing.
From an Org buffer and from an agenda line."
  (agent-auto-test--with root
    (pcase-let ((`(,file . ,buffer) (agent-auto-test--started-task root)))
      (agent-auto-test--acting shown
        (agent-auto-test--act file)
        (should (equal shown (list buffer)))
        (with-current-buffer (find-buffer-visiting file)
          (agent-test-helper-in-agenda "Fix it"
            (agent-auto-test--keeping-buffer (agent-act-on-thing-at-point))))
        (should (equal shown (list buffer buffer))))
      (should (= (length agent-auto-test--started) 1))
      (should (equal (agent-auto-test--property file "Fix it" "AGENT_SESSION")
                     (buffer-name buffer))))))

(ert-deftest agent-auto-test-acting-on-a-closed-task-shows-its-session ()
  "Show the session a task that is done records, and leave the task done.
Starting a session on such a task is refused; going back to the one it
has sends nothing and changes no state."
  (agent-auto-test--with root
    (pcase-let ((`(,file . ,buffer) (agent-auto-test--started-task root)))
      (agent-auto-test--at file "Fix it" (lambda () (org-todo 'done)))
      (with-current-buffer (find-buffer-visiting file)
        (save-buffer))
      (agent-auto-test--acting shown
        (agent-auto-test--act file)
        (should (equal shown (list buffer))))
      (should (= (length agent-auto-test--started) 1))
      (should (agent-auto-test--at file "Fix it" #'org-entry-is-done-p))
      (should-error (agent-auto-test--act file '(16)) :type 'user-error)
      (should (= (length agent-auto-test--started) 1)))))

(ert-deftest agent-auto-test-acting-resumes-the-closed-session ()
  "Resume the closed session a task records, in the task's directory.
The same conversation is resumed with the backend that ran it, nothing
is sent, and the task is linked to the resumed buffer."
  (agent-auto-test--with root
    (let ((file (agent-auto-test--closed-task root "sid-00001")))
      (should (equal (agent-auto-test--property file "Fix it" "AGENT_BACKEND")
                     "stub"))
      (agent-auto-test--acting shown
        (agent-auto-test--act file)
        (should (equal shown (list (car agent-auto-test--buffers)))))
      (should (= (length agent-auto-test--started) 2))
      (pcase-let ((`(,session . ,options) (car agent-auto-test--started))
                  (resumed (car agent-auto-test--buffers)))
        (should (equal (plist-get options :resume-id) "sid-00001"))
        (should-not (plist-get options :initial-prompt))
        (should (eq (agent-session-backend session) 'stub))
        (should (equal (agent-session-directory session) root))
        (should (equal (agent-auto-test--property file "Fix it" "AGENT_SESSION")
                       "sid-00001"))
        (agent-auto-test--end-turn resumed "Status: done: finished on resume")
        (should (equal (agent-auto-test--tags file "Fix it") '("review")))))))

;; The resumed session was named resume-ID, which says nothing in a list
;; of sessions; the session the timer started was named after the task.
(ert-deftest agent-auto-test-resumed-session-takes-the-task-name ()
  "Resume a task's closed session under the name made from its heading.
That is the name the session had when it was started.  A live session
in the directory that holds the name makes it NAME-N."
  (agent-auto-test--with root
    (let ((file (agent-auto-test--closed-task root "sid-00001")))
      (should (equal (agent-session-instance (caar agent-auto-test--started))
                     "fix-it"))
      (agent-auto-test--acting shown
        (agent-auto-test--act file))
      (should (equal (plist-get (cdar agent-auto-test--started) :resume-id)
                     "sid-00001"))
      (should (equal (agent-session-instance (caar agent-auto-test--started))
                     "fix-it"))
      (should (string-suffix-p ":fix-it*"
                               (buffer-name (car agent-auto-test--buffers))))
      (should (buffer-local-value 'agent--named
                                  (car agent-auto-test--buffers)))
      (let ((kill-buffer-query-functions nil))
        (kill-buffer (car agent-auto-test--buffers)))
      (agent-start-session
       (agent-session-create :backend 'stub :directory root
                             :instance "fix-it"))
      (agent-auto-test--acting shown
        (agent-auto-test--act file))
      (should (equal (plist-get (cdar agent-auto-test--started) :resume-id)
                     "sid-00001"))
      (should (equal (agent-session-instance (caar agent-auto-test--started))
                     "fix-it-1")))))

(ert-deftest agent-auto-test-acting-resumes-from-the-agenda ()
  "Resume the closed session of the task an agenda line shows."
  (agent-auto-test--with root
    (let ((file (agent-auto-test--closed-task root "sid-00001")))
      (agent-auto-test--acting shown
        (with-current-buffer (find-buffer-visiting file)
          (agent-test-helper-in-agenda "Fix it"
            (agent-auto-test--keeping-buffer (agent-send-todo-at-point))))
        (should (equal shown (list (car agent-auto-test--buffers)))))
      (should (equal (plist-get (cdar agent-auto-test--started) :resume-id)
                     "sid-00001"))
      (should (buffer-local-value 'agent-auto--link
                                  (car agent-auto-test--buffers))))))

(ert-deftest agent-auto-test-acting-resumes-a-linear-issue ()
  "Show or resume the session a Linear issue records, as for a plain TODO.
Started fresh, such an issue is typed into the prompt; here nothing is."
  (agent-auto-test--with root
    (let ((file (agent-auto-test--file
                 root (format "* TODO Issue :agent:\n:PROPERTIES:\n:DIR: %s\n:LINEAR_URL: https://linear.app/a/issue/A-1\n:END:\n"
                              root))))
      (agent-auto-test--run)
      (let ((buffer (car agent-auto-test--buffers))
            (kill-buffer-query-functions nil))
        (agent--note-session-id buffer "sid-00001")
        (agent-auto-test--acting shown
          (agent-auto-test--act file)
          (should (equal shown (list buffer)))
          (kill-buffer buffer)
          (agent-auto-test--act file nil #'agent-act-on-linear-issue)
          (should (equal (plist-get (cdar agent-auto-test--started) :resume-id)
                         "sid-00001"))
          (with-current-buffer (find-buffer-visiting file)
            (let ((kill-buffer-query-functions nil))
              (kill-buffer (car agent-auto-test--buffers)))
            (agent-test-helper-in-agenda "Issue"
              (agent-auto-test--keeping-buffer (agent-act-on-thing-at-point))))
          (should (= (length agent-auto-test--started) 3))
          (should (equal (plist-get (cdar agent-auto-test--started) :resume-id)
                         "sid-00001")))))))

(ert-deftest agent-auto-test-acting-resumes-where-the-session-ran ()
  "Resume a session given a worktree in that worktree.
The account is still the one the task's own directory gets."
  (agent-auto-test--with root
    (let* ((repo (agent-auto-test--repository root "repo"))
           (agent-account-directory-rules `((,repo . "work")))
           (agent-account--current (make-hash-table :test #'eq))
           (file (agent-auto-test--file
                  root (concat (agent-auto-test--task repo "One")
                               (agent-auto-test--task repo "Two")))))
      (setf (agent-backend-accounts (agent-backend 'stub))
            '(("work" . "/tmp/agent-test-work/")
              ("personal" . "/tmp/agent-test-personal/")))
      (puthash 'stub "personal" agent-account--current)
      (cl-letf (((symbol-function 'agent-account-sync) #'ignore)
                ((symbol-function 'agent-account-logged-in-p)
                 (lambda (&rest _) t)))
        (agent-auto-test--run)
        (let* ((buffer (seq-find (lambda (buffer)
                                   (string-match-p ":two\\*\\'"
                                                   (buffer-name buffer)))
                                 agent-auto-test--buffers))
               (worktree (agent-session-directory (agent-session buffer)))
               (kill-buffer-query-functions nil))
          (should-not (file-equal-p worktree repo))
          (agent--note-session-id buffer "sid-00002")
          (should (file-equal-p (agent-auto-test--property
                                 file "Two" "AGENT_DIRECTORY")
                                worktree))
          (should-not (agent-auto-test--property file "One" "AGENT_DIRECTORY"))
          (kill-buffer buffer)
          (agent-auto-test--acting _shown
            (agent-auto-test--act file nil nil "Two"))
          (let ((session (caar agent-auto-test--started)))
            (should (equal (plist-get (cdar agent-auto-test--started)
                                      :resume-id)
                           "sid-00002"))
            (should (equal (agent-session-directory session) worktree))
            (should (equal (agent-session-account session) "work"))))))))

;; A session that could not be resumed was replaced without a word but a
;; line in the echo area, and the new one was given the brief again.
(defmacro agent-auto-test--answering (answer asked &rest body)
  "Evaluate BODY with `y-or-n-p' answering ANSWER.
ASKED is a symbol, bound to the prompts it was given, the latest first."
  (declare (indent 2) (debug (form symbolp body)))
  `(let (,asked)
     (cl-letf (((symbol-function 'y-or-n-p)
                (lambda (prompt) (push prompt ,asked) ,answer)))
       ,@body)))

(defun agent-auto-test--refused (file)
  "Act on the first task of FILE where nothing may be asked.
Return the message of the `user-error' that refuses it."
  (let ((agent-inhibit-prompts t))
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (&rest _) (ert-fail "Asked with `y-or-n-p'"))))
      (cadr (should-error (agent-auto-test--act file) :type 'user-error)))))

(ert-deftest agent-auto-test-acting-asks-before-starting-anew-without-an-id ()
  "Ask before a new session replaces a recorded one that has no id.
A placeholder and a buffer's name name no conversation to resume.  The
question is asked once.  Declined, or where nothing may be asked, no
session is started and the reason is given; accepted, the task is
linked to the new session.  Looking the session up asks nothing."
  (dolist (recorded '(nil "starting-20261117T120000-0a1b"))
    (agent-auto-test--with root
      (pcase-let ((`(,file . ,buffer) (agent-auto-test--started-task root))
                  (kill-buffer-query-functions nil))
        (kill-buffer buffer)
        (when recorded
          (agent-auto-test--at
           file "Fix it" (lambda () (org-entry-put nil "AGENT_SESSION" recorded)))
          (with-current-buffer (find-buffer-visiting file)
            (save-buffer)))
        (agent-auto-test--answering nil asked
          (should (string-match-p
                   "This task's session cannot be resumed"
                   (cadr (should-error (agent-auto-test--act file)
                                       :type 'user-error))))
          (should (equal asked '("This task's session cannot be resumed. Start a new one? "))))
        (agent-auto-test--answering (ert-fail "Asked with `y-or-n-p'") asked
          (let ((context (agent-auto-test--at
                          file "Fix it"
                          (lambda ()
                            (run-hook-with-args-until-success
                             'agent-recorded-session-functions)))))
            (should context)
            (should-not (plist-get context :buffer))
            (should-not (plist-get context :resume-id))))
        (should (string-match-p "This task's session cannot be resumed"
                                (agent-auto-test--refused file)))
        (should (= (length agent-auto-test--started) 1))
        (agent-auto-test--answering t asked
          (agent-auto-test--act file)
          (should (= (length asked) 1)))
        (should (= (length agent-auto-test--started) 2))
        (let ((new (car agent-auto-test--buffers)))
          (should (equal (plist-get (cdar agent-auto-test--started)
                                    :initial-prompt)
                         "Fix it\n\nThe body."))
          (should (equal (agent-auto-test--property file "Fix it" "AGENT_SESSION")
                         (buffer-name new)))
          (agent-auto-test--end-turn new "Status: done: fixed anew")
          (should (equal (agent-auto-test--tags file "Fix it") '("review"))))))))

(ert-deftest agent-auto-test-acting-asks-before-starting-anew-when-resuming-fails ()
  "Ask before a new session replaces a recorded one that fails to resume.
The question says why resuming failed.  Declined, or where nothing may
be asked, no session is started; accepted, the task is linked to the new
session."
  (agent-auto-test--with root
    (let ((file (agent-auto-test--closed-task root "sid-00001"))
          (agent-auto-test--resume-error "no such conversation"))
      (agent-auto-test--answering nil asked
        (should-error (agent-auto-test--act file) :type 'user-error)
        (should (equal asked '("This task's session cannot be resumed (no such conversation). Start a new one? "))))
      (should (string-match-p
               "This task's session cannot be resumed (no such conversation)"
               (agent-auto-test--refused file)))
      (should (= (length agent-auto-test--started) 1))
      (agent-auto-test--answering t asked
        (agent-auto-test--act file)
        (should (= (length asked) 1)))
      (should (= (length agent-auto-test--started) 2))
      (let ((new (car agent-auto-test--buffers)))
        (should (equal (plist-get (cdar agent-auto-test--started) :initial-prompt)
                       "Fix it\n\nThe body."))
        (should (equal (agent-auto-test--property file "Fix it" "AGENT_SESSION")
                       (buffer-name new)))
        (should (buffer-local-value 'agent-auto--link new))))))

(ert-deftest agent-auto-test-double-prefix-starts-a-new-session ()
  "Start a new session with a double prefix, whatever the task records.
The task is linked to the new session, also while the old one is live.
Nothing is asked, since a new session was asked for; the task's log
names the session it no longer records, and that session, linked to no
task now, writes nothing on it."
  (agent-auto-test--with root
    (pcase-let ((`(,file . ,buffer) (agent-auto-test--started-task root)))
      (agent--note-session-id buffer "sid-00001")
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "")))
        (agent-auto-test--act file '(16)))
      (should (= (length agent-auto-test--started) 2))
      (should (buffer-live-p buffer))
      (let ((new (car agent-auto-test--buffers)))
        (should (equal (plist-get (cdar agent-auto-test--started) :initial-prompt)
                       "Fix it\n\nThe body."))
        (should (equal (agent-auto-test--property file "Fix it" "AGENT_SESSION")
                       (buffer-name new)))
        (should (equal (agent-auto-test--notes file "Fix it")
                       '("Session sid-00001 (stub) is no longer linked to this task: another took its place.")))
        (should-not (buffer-local-value 'agent-auto--link buffer))
        (agent-auto-test--end-turn buffer "Status: waiting on you: still here?")
        (should (equal (agent-auto-test--tags file "Fix it") '("agent")))
        (agent-auto-test--end-turn new "Status: done: second attempt")
        (should (equal (agent-auto-test--property file "Fix it" "AGENT_RESULT")
                       "second attempt"))))))

(ert-deftest agent-auto-test-single-prefix-still-picks-a-running-session ()
  "Send the task to a session chosen by completion with a single prefix.
The session the task records is not shown in its place."
  (agent-auto-test--with root
    (pcase-let ((`(,file . ,buffer) (agent-auto-test--started-task root)))
      (let (sent)
        (cl-letf (((symbol-function 'agent--read-session-buffer)
                   (lambda (&rest _) buffer))
                  ((symbol-function 'agent-submit)
                   (lambda (text target) (setq sent (list text target)))))
          (agent-auto-test--act file '(4)))
        (should (equal sent (list "Fix it\n\nThe body." buffer)))
        (should (= (length agent-auto-test--started) 1))))))

;;;; One session, one task

(defun agent-auto-test--two-tasks (root)
  "Start a session by hand on Task A of a new file under ROOT that has Task B.
The session has the id sid-1 and takes text.  Return (FILE . BUFFER)."
  (let ((file (agent-auto-test--file
               root (concat (agent-auto-test--task root "Task A" "")
                            (agent-auto-test--task root "Task B" "")))))
    (agent-auto-test--act file nil nil "Task A")
    (let ((buffer (car agent-auto-test--buffers)))
      (agent--note-session-id buffer "sid-1")
      (agent-auto-test--take-text)
      (should (equal (agent-auto-test--property file "Task A" "AGENT_SESSION")
                     "sid-1"))
      (cons file buffer))))

(defmacro agent-auto-test--choosing (buffer &rest body)
  "Evaluate BODY with BUFFER as the session a prefix argument sends a task to."
  (declare (indent 1) (debug (form body)))
  `(cl-letf (((symbol-function 'agent--read-session-buffer)
              (lambda (&rest _) ,buffer)))
     ,@body))

;; A task sent to a session that another task recorded left both tasks
;; recording it, and the session's results went to the first.
(ert-deftest agent-auto-test-sending-to-a-linked-session-asks ()
  "Ask before a task takes a session from the task it is linked to.
Declined, or where nothing may be asked, nothing is sent and nothing
changes.  Accepted, the task is sent and records the session, the other
task no longer records it and names it in its log, and the session's
results reach the new task only."
  (agent-auto-test--with root
    (pcase-let ((`(,file . ,buffer) (agent-auto-test--two-tasks root)))
      (agent-auto-test--choosing buffer
        (let ((before (agent-auto-test--disk file)))
          (agent-auto-test--answering nil asked
            (should-error (agent-auto-test--act file '(4) nil "Task B")
                          :type 'user-error)
            (should (= (length asked) 1))
            (should (string-match-p "is linked to the task “Task A”"
                                    (car asked))))
          (let ((agent-inhibit-prompts t))
            (agent-auto-test--answering (ert-fail "Asked with `y-or-n-p'") asked
              (should-error (agent-auto-test--act file '(4) nil "Task B")
                            :type 'user-error)))
          (should-not agent-auto-test--submitted)
          (should (equal (agent-auto-test--disk file) before))
          (should-not (buffer-modified-p (find-buffer-visiting file))))
        (agent-auto-test--answering t asked
          (agent-auto-test--act file '(4) nil "Task B")
          (should (= (length asked) 1))))
      (should (equal agent-auto-test--submitted
                     (list (cons "Task B\n\nThe body." buffer))))
      (should (equal (agent-auto-test--property file "Task B" "AGENT_SESSION")
                     "sid-1"))
      (should (equal (agent-auto-test--property file "Task B" "AGENT_BACKEND")
                     "stub"))
      (should-not (agent-auto-test--property file "Task A" "AGENT_SESSION"))
      (should-not (agent-auto-test--property file "Task A" "AGENT_BACKEND"))
      (should (equal (agent-auto-test--notes file "Task A")
                     '("Session sid-1 (stub) is no longer linked to this task: it was linked to another.")))
      (should-not (agent-auto-test--notes file "Task B"))
      (should-not (buffer-modified-p (find-buffer-visiting file)))
      (agent-auto-test--end-turn buffer "Status: done: did B")
      (should (equal (agent-auto-test--tags file "Task B") '("review")))
      (should (equal (agent-auto-test--property file "Task B" "AGENT_RESULT")
                     "did B"))
      (should-not (agent-auto-test--tags file "Task A"))
      (should-not (agent-auto-test--property file "Task A" "AGENT_RESULT")))))

(ert-deftest agent-auto-test-sending-a-task-that-records-a-session-asks ()
  "Ask before a task that records a session is given another.
Declined, nothing is sent and the task keeps its session.  Accepted, the
task records the new session and names the old in its log, and the old
session, linked to no task now, writes nothing on it.  A session linked
to another task as well makes two questions, and declining the second
leaves all three as they were."
  (agent-auto-test--with root
    (pcase-let* ((`(,file . ,first) (agent-auto-test--two-tasks root))
                 (second (agent-start-session
                          (agent-session-create :backend 'stub :directory root
                                                :instance "second"))))
      (agent--note-session-id second "sid-2")
      (agent-auto-test--choosing second
        (agent-auto-test--answering nil asked
          (should-error (agent-auto-test--act file '(4) nil "Task A")
                        :type 'user-error)
          (should (equal (length asked) 1))
          (should (string-match-p "records another session (sid-1)"
                                  (car asked))))
        (should-not agent-auto-test--submitted)
        (should (equal (agent-auto-test--property file "Task A" "AGENT_SESSION")
                       "sid-1"))
        (agent-auto-test--answering t asked
          (agent-auto-test--act file '(4) nil "Task A")))
      (should (equal (agent-auto-test--property file "Task A" "AGENT_SESSION")
                     "sid-2"))
      (should (equal (agent-auto-test--notes file "Task A")
                     '("Session sid-1 (stub) is no longer linked to this task: another took its place.")))
      (should-not (buffer-local-value 'agent-auto--link first))
      (should (buffer-local-value 'agent-auto--link second))
      (agent-auto-test--end-turn first "Status: done: from the old session")
      (should-not (agent-auto-test--tags file "Task A"))
      (agent-auto-test--at
       file "Task B"
       (lambda () (org-entry-put nil "AGENT_SESSION" "sid-9")))
      (with-current-buffer (find-buffer-visiting file)
        (save-buffer))
      (let ((before (agent-auto-test--disk file))
            (answers (list t nil)))
        (setq agent-auto-test--submitted nil)
        (agent-auto-test--choosing second
          (cl-letf (((symbol-function 'y-or-n-p)
                     (lambda (_prompt) (pop answers))))
            (should-error (agent-auto-test--act file '(4) nil "Task B")
                          :type 'user-error)))
        (should-not answers)
        (should-not agent-auto-test--submitted)
        (should (equal (agent-auto-test--disk file) before))))))

(ert-deftest agent-auto-test-released-task-is-not-started-again ()
  "Take the ready tag from a task whose session was linked to another.
The task records no session any more, and the timer would otherwise
start a new one on it."
  (agent-auto-test--with root
    (let ((file (agent-auto-test--file
                 root (concat (agent-auto-test--task root "Task A")
                              (agent-auto-test--task root "Task B" "")))))
      (agent-auto-test--run)
      (should (= (length agent-auto-test--started) 1))
      (let ((buffer (car agent-auto-test--buffers)))
        (agent--note-session-id buffer "sid-1")
        (agent-auto-test--take-text)
        (agent-auto-test--choosing buffer
          (agent-auto-test--answering t _asked
            (agent-auto-test--act file '(4) nil "Task B")))
        (should-not (agent-auto-test--tags file "Task A"))
        (should-not (buffer-local-value 'agent-auto--unattended buffer))
        (agent-auto-test--run)
        (should (= (length agent-auto-test--started) 1))))))

;;;; Linking by hand

(defmacro agent-auto-test--completing (pick offered &rest body)
  "Evaluate BODY with `completing-read' choosing the candidate PICK matches.
PICK is a regexp.  OFFERED is a symbol, bound to the lists of candidates
that were offered, each in the order it was offered in, the latest
first."
  (declare (indent 2) (debug (form symbolp body)))
  `(let (,offered)
     (cl-letf (((symbol-function 'completing-read)
                (lambda (_prompt table &rest _)
                  (let ((all (all-completions "" table)))
                    (should (eq (completion-metadata-get
                                 (completion-metadata "" table nil)
                                 'display-sort-function)
                                #'identity))
                    (push all ,offered)
                    (or (seq-find (lambda (candidate)
                                    (string-match-p ,pick candidate))
                                  all)
                        (ert-fail (format "No candidate matches %s in %S"
                                          ,pick all)))))))
       ,@body)))

(defun agent-auto-test--open-session (root name id)
  "Start a session named NAME in ROOT by hand, on no task; return its buffer.
It has the id ID and takes text."
  (let ((buffer (agent-start-session
                 (agent-session-create :backend 'stub :directory root
                                       :instance name))))
    (agent--note-session-id buffer id)
    (agent-auto-test--take-text)
    buffer))

(defun agent-auto-test--existing-tasks (root)
  "Write two files of tasks under ROOT and return them, as (MADE . PLAIN).
The first holds a task some other program made, which names ROOT as its
directory and carries a property of that program's.  The second holds a
plain TODO with no property at all, and is searched first."
  (let ((plain (agent-auto-test--file root "* TODO Plain one\nIts body.\n"
                                      "plain.org"))
        (made (agent-auto-test--file
               root (format "* TODO Made elsewhere\n:PROPERTIES:\n:DIR: %s\n:OTHER_ID: p-1\n:END:\nIts body.\n"
                            root))))
    (cons made plain)))

(ert-deftest agent-auto-test-link-session-from-the-task ()
  "Link a running session to the task at point, and send it nothing.
The sessions in the task's directory are offered first.  The task then
records the session as one started from it does, on disk; its heading
shows the session's mark; acting on it goes to the session; and closing
the session writes its handover on the task."
  (agent-auto-test--with root
    (let* ((elsewhere (file-name-as-directory (expand-file-name "else" root)))
           (made (car (agent-auto-test--existing-tasks root)))
           (buffer (agent-auto-test--open-session root "open" "sid-1"))
           (other (progn (make-directory elsewhere)
                         (agent-auto-test--open-session elsewhere "far"
                                                        "sid-2"))))
      (should (equal (agent-session-buffers) (list other buffer)))
      (agent-auto-test--acting shown
        (agent-auto-test--completing "agent-test[^/]*\\'" offered
          (with-current-buffer (find-file-noselect made)
            (goto-char (point-min))
            (search-forward "Its body")
            (agent-link-session))
          (should (equal (car offered)
                         (list (agent--session-candidate-label buffer)
                               (agent--session-candidate-label other)))))
        (should-not shown)
        (should (equal (agent-auto-test--property made "Made elsewhere"
                                                  "AGENT_SESSION")
                       "sid-1"))
        (should (equal (agent-auto-test--property made "Made elsewhere"
                                                  "AGENT_BACKEND")
                       "stub"))
        (should (agent-auto-test--property made "Made elsewhere" "AGENT_STARTED"))
        (should (equal (agent-auto-test--property made "Made elsewhere" "OTHER_ID")
                       "p-1"))
        (should (string-match-p ":AGENT_SESSION: +sid-1"
                                (agent-auto-test--disk made)))
        (should (buffer-local-value 'agent-auto--link buffer))
        (should-not (buffer-local-value 'agent-auto--link other))
        (agent-auto-test--marks-due)
        (should (equal (agent-auto-test--heading-mark made "Made elsewhere")
                       " ▶"))
        (agent-auto-test--act made)
        (should (equal shown (list buffer))))
      (agent-auto-test--run)
      (should (= (length agent-auto-test--started) 2))
      (agent-auto-test--hand-over
       buffer '(:state "interrupted" :summary "Half of it" :next "the rest"))
      (should (equal (agent-auto-test--notes made "Made elsewhere")
                     '("Session closed: interrupted.\nDone: Half of it\nNext: the rest"))))))

(ert-deftest agent-auto-test-link-session-from-the-session ()
  "Link the session of the current buffer to a task chosen by completion.
The open TODOs of the files searched are offered, those whose directory
is the session's first, and a closed one is not.  A plain TODO in
another file, with no property of its own, is linked as any task: it
records the session and where it runs, shows its mark, goes to the
session when acted on, and gets the handover.  Nothing is sent."
  (agent-auto-test--with root
    (pcase-let* ((`(,_made . ,plain) (agent-auto-test--existing-tasks root))
                 (_done (agent-auto-test--file
                         root "* DONE Closed one\n" "done.org"))
                 (buffer (agent-auto-test--open-session root "open" "sid-1")))
      (agent-auto-test--acting shown
        (agent-auto-test--completing "Plain one" offered
          (with-current-buffer buffer
            (agent-link-session))
          (should (equal (car offered)
                         '("Made elsewhere  (tasks.org)"
                           "Plain one  (plain.org)"))))
        (should-not shown)
        (should (equal (agent-auto-test--property plain "Plain one"
                                                  "AGENT_SESSION")
                       "sid-1"))
        (should (file-equal-p (agent-auto-test--property plain "Plain one"
                                                         "AGENT_DIRECTORY")
                              root))
        (should (string-match-p ":AGENT_SESSION: +sid-1"
                                (agent-auto-test--disk plain)))
        (agent-auto-test--marks-due)
        (should (equal (agent-auto-test--heading-mark plain "Plain one") " ▶"))
        (agent-auto-test--act plain)
        (should (equal shown (list buffer))))
      (agent-auto-test--hand-over
       buffer '(:state "finished" :summary "All of it"))
      (should (equal (agent-auto-test--tags plain "Plain one") '("review")))
      (should (equal (agent-auto-test--notes plain "Plain one")
                     '("Session closed: finished.\nDone: All of it"))))))

(ert-deftest agent-auto-test-link-session-from-an-agenda-line ()
  "Link a running session to the task of the agenda line at point."
  (agent-auto-test--with root
    (let ((made (car (agent-auto-test--existing-tasks root)))
          (buffer (agent-auto-test--open-session root "open" "sid-1")))
      (agent-auto-test--acting _shown
        (agent-auto-test--completing "." _offered
          (with-current-buffer (find-file-noselect made)
            (agent-test-helper-in-agenda "Made elsewhere"
              (agent-link-session)))))
      (should (equal (agent-auto-test--property made "Made elsewhere"
                                                "AGENT_SESSION")
                     "sid-1"))
      (should (buffer-local-value 'agent-auto--link buffer)))))

(ert-deftest agent-auto-test-link-session-asks-before-replacing ()
  "Ask before a link made by hand replaces another, from either side.
A task that records another session, and a session linked to another
task: declined, nothing changes; accepted, the link is replaced and the
log of the task that lost its session names it.  Nothing is sent."
  (agent-auto-test--with root
    (pcase-let* ((`(,made . ,plain) (agent-auto-test--existing-tasks root))
                 (first (agent-auto-test--open-session root "first" "sid-1"))
                 (second (agent-auto-test--open-session root "second" "sid-2")))
      (agent-auto-test--acting _shown
        (agent-auto-test--completing "Made elsewhere" _offered
          (with-current-buffer first
            (agent-link-session)))
        (let ((before (agent-auto-test--disk made)))
          (agent-auto-test--completing "second" _offered
            (agent-auto-test--answering nil asked
              (agent-auto-test--act made nil #'agent-link-session
                                    "Made elsewhere")
              (should (= (length asked) 1))
              (should (string-match-p "records another session (sid-1)"
                                      (car asked)))))
          (should (equal (agent-auto-test--disk made) before))
          (should-not (buffer-local-value 'agent-auto--link second)))
        (agent-auto-test--completing "Plain one" _offered
          (agent-auto-test--answering nil asked
            (with-current-buffer first
              (agent-link-session))
            (should (= (length asked) 1))
            (should (string-match-p "is linked to the task “Made elsewhere”"
                                    (car asked))))
          (should-not (agent-auto-test--property plain "Plain one"
                                                 "AGENT_SESSION"))
          (agent-auto-test--answering t _asked
            (with-current-buffer first
              (agent-link-session))))
        (should (equal (agent-auto-test--property plain "Plain one"
                                                  "AGENT_SESSION")
                       "sid-1"))
        (should-not (agent-auto-test--property made "Made elsewhere"
                                               "AGENT_SESSION"))
        (should (equal (agent-auto-test--notes made "Made elsewhere")
                       '("Session sid-1 (stub) is no longer linked to this task: it was linked to another.")))
        (agent-auto-test--completing "second" _offered
          (agent-auto-test--answering t _asked
            (agent-auto-test--act plain nil #'agent-link-session "Plain one")))
        (should (equal (agent-auto-test--property plain "Plain one"
                                                  "AGENT_SESSION")
                       "sid-2"))
        (should (string-match-p
                 "\\`Session sid-1 (stub, .*) is no longer linked to this task: another took its place\\.\\'"
                 (car (agent-auto-test--notes plain "Plain one"))))
        (should-not (buffer-local-value 'agent-auto--link first))
        (should (buffer-local-value 'agent-auto--link second))))))

(ert-deftest agent-auto-test-link-session-with-a-prefix-sends-the-task ()
  "Send the task's text to the session as well, with a prefix argument.
From the task and from the session, the text is the one sending the
task to a running session submits, and the task moves to the keyword a
sent task moves to."
  (dolist (from '(task session))
    (agent-auto-test--with root
      (let* ((agent-todo-in-progress-keyword "DOING")
             (file (agent-auto-test--file
                    root (concat "#+TODO: TODO DOING | DONE\n"
                                 (agent-auto-test--task root nil ""))))
             (buffer (agent-auto-test--open-session root "open" "sid-1")))
        (if (eq from 'task)
            (agent-auto-test--completing "." _offered
              (agent-auto-test--act file '(4) #'agent-link-session "Fix it"))
          (agent-auto-test--completing "Fix it" _offered
            (with-current-buffer buffer
              (agent-link-session '(4)))))
        (should (equal agent-auto-test--submitted
                       (list (cons "Fix it\n\nThe body." buffer))))
        (should (equal (agent-auto-test--property file "Fix it" "AGENT_SESSION")
                       "sid-1"))
        (should (equal (agent-auto-test--keyword file "Fix it") "DOING"))
        (should (buffer-local-value 'agent-auto--link buffer))))))

(ert-deftest agent-auto-test-link-session-refuses-what-cannot-be-linked ()
  "Refuse to link where there is no open task, no session, or no mode."
  (agent-auto-test--with root
    (let ((file (agent-auto-test--file
                 root "Before the first heading.\n* Not a task\n* DONE Closed\n* TODO Open\n")))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _) (ert-fail "Asked for a choice"))))
        (dolist (place '("Before the first" "Not a task" "Closed"))
          (should-error (agent-auto-test--act file nil #'agent-link-session
                                              place)
                        :type 'user-error))
        (should-error (agent-auto-test--act file nil #'agent-link-session "Open")
                      :type 'user-error)
        (let ((agent-auto-mode nil))
          (agent-auto-test--open-session root "open" "sid-1")
          (should-error (agent-auto-test--act file nil #'agent-link-session
                                              "Open")
                        :type 'user-error)))
      (should-not (string-match-p "AGENT_SESSION" (agent-auto-test--disk file))))))

(ert-deftest agent-auto-test-task-keys-mode-links-from-an-agenda ()
  "Link a session to the task of an agenda line with S typed in the agenda.
The key is the mode's own: it runs the command only while the mode is on
in the agenda, where it takes precedence over the agenda's key.  It goes
through the command loop, links the session to the task of the line at
point, and sends nothing."
  (agent-auto-test--with root
    (let ((made (car (agent-auto-test--existing-tasks root)))
          (buffer (agent-auto-test--open-session root "open" "sid-1"))
          (pre-command-hook nil)
          (post-command-hook nil))
      (should (eq (keymap-lookup agent-task-keys-mode-map "S")
                  #'agent-link-session))
      (agent-auto-test--acting _shown
        (agent-auto-test--completing "." offered
          (with-current-buffer (find-file-noselect made)
            (agent-test-helper-in-agenda "Made elsewhere"
              (should-not (eq (key-binding (kbd "S")) #'agent-link-session))
              (agent-task-keys-mode 1)
              (should (eq (key-binding (kbd "S")) #'agent-link-session))
              (set-window-buffer (selected-window) (current-buffer))
              (set-window-point (selected-window) (point))
              (execute-kbd-macro (kbd "S"))
              (agent-task-keys-mode -1)
              (should-not (eq (key-binding (kbd "S")) #'agent-link-session))))
          (should (= (length offered) 1))))
      (should (equal (agent-auto-test--property made "Made elsewhere"
                                                "AGENT_SESSION")
                     "sid-1"))
      (should (string-match-p ":AGENT_SESSION: +sid-1"
                              (agent-auto-test--disk made)))
      (should (buffer-local-value 'agent-auto--link buffer)))))

;;;; Where to look

(ert-deftest agent-auto-test-looks-in-the-agenda-files-by-default ()
  "Search `org-agenda-files' when `agent-auto-files' is nil."
  (agent-auto-test--with root
    (let* ((file (agent-auto-test--file root (agent-auto-test--task root)))
           (agent-auto-files nil)
           (org-agenda-files (list file)))
      (agent-auto-test--run)
      (should (= (length agent-auto-test--started) 1)))))

(ert-deftest agent-auto-test-files-can-be-a-function-or-a-directory ()
  "Search the Org files of a directory a function returns."
  (agent-auto-test--with root
    (agent-auto-test--file root (agent-auto-test--task root))
    (write-region (agent-auto-test--task root "Not Org") nil
                  (expand-file-name "notes.txt" root) nil 'silent)
    (let ((agent-auto-files (lambda () (list root))))
      (agent-auto-test--run)
      (should (= (length agent-auto-test--started) 1)))))

(ert-deftest agent-auto-test-visits-only-files-with-a-ready-task ()
  "Visit no file that ripgrep did not find the tag in, and stay quick.
The search itself is not waited for, so the timer's own step takes a
fraction of a second however many files there are."
  (agent-auto-test--with root
    (dotimes (n 200)
      (agent-auto-test--file root "* TODO Nothing for an agent\n"
                             (format "plain-%d.org" n)))
    (let ((tagged (agent-auto-test--file root (agent-auto-test--task root)))
          (start (float-time)))
      (agent-auto--tick)
      (should (< (- (float-time) start) 0.5))
      (agent-auto-test--drain)
      (should (= (length agent-auto-test--started) 1))
      (should (find-buffer-visiting tagged))
      (should-not (find-buffer-visiting (expand-file-name "plain-0.org" root)))
      (should-not (find-buffer-visiting (expand-file-name "plain-199.org" root))))))

;;;; Marks

(defun agent-auto-test--marks-due ()
  "Run the update of the marks a hook asked for, unless it has run already.
Nothing else brings the marks up to date, so a test that sees them
change after this has seen the hook ask for it."
  (when (timerp agent-auto--marks-timer)
    (cancel-timer agent-auto--marks-timer)
    (agent-auto--run-marks)))

(defun agent-auto-test--close (buffer)
  "Kill session BUFFER with the mode's function on `kill-buffer-hook'.
The hook's global value is changed, since the buffer a test is in can
have a value of its own, which is the one `let' would bind."
  (let ((kill-buffer-query-functions nil))
    (add-hook 'kill-buffer-hook #'agent-auto--session-killed)
    (unwind-protect (kill-buffer buffer)
      (remove-hook 'kill-buffer-hook #'agent-auto--session-killed))))

(defun agent-auto-test--mark-strings ()
  "Return the marks of the current buffer, in order, as (STRING . POSITION)."
  (save-restriction
    (widen)
    (sort (mapcar (lambda (overlay)
                    (cons (substring-no-properties
                           (or (overlay-get overlay 'before-string)
                               (overlay-get overlay 'after-string)))
                          (overlay-start overlay)))
                  (seq-filter (lambda (overlay)
                                (overlay-get overlay 'agent-auto-mark))
                              (overlays-in (point-min) (point-max))))
          (lambda (a b) (< (cdr a) (cdr b))))))

(defun agent-auto-test--heading-mark (file heading)
  "Return the mark shown on HEADING in the buffer visiting FILE, or nil.
Fail unless it stands right after the heading's TODO keyword."
  (with-current-buffer (find-buffer-visiting file)
    (let ((marks (seq-filter
                  (lambda (mark)
                    (save-excursion
                      (goto-char (cdr mark))
                      (string-match-p (regexp-quote heading)
                                      (buffer-substring (pos-bol) (pos-eol)))))
                  (agent-auto-test--mark-strings))))
      (should (<= (length marks) 1))
      (when marks
        (save-excursion
          (goto-char (cdar marks))
          (should (looking-at "TODO "))
          (should (= (pos-bol) (- (point) 2))))
        (caar marks)))))

(defmacro agent-auto-test--in-agenda (file &rest body)
  "Evaluate BODY in a TODO agenda built from FILE with the marks' hook on."
  (declare (indent 1) (debug (form body)))
  `(let ((org-agenda-finalize-hook (list #'agent-auto--mark-agenda)))
     (with-current-buffer (find-buffer-visiting ,file)
       (agent-test-helper-in-agenda "Fix it" ,@body))))

(defun agent-auto-test--agenda-marks ()
  "Return the marks of the current agenda as (STRING . TEXT-AT-THE-MARK).
The text runs to the end of the line, with each run of blanks as one."
  (mapcar (lambda (mark)
            (cons (car mark)
                  (replace-regexp-in-string
                   "[ \t]+" " "
                   (buffer-substring-no-properties
                    (cdr mark) (save-excursion (goto-char (cdr mark))
                                               (pos-eol))))))
          (agent-auto-test--mark-strings)))

(ert-deftest agent-auto-test-mark-follows-the-session ()
  "Mark a task's heading from the start of its session until it is closed.
The mark changes when the session goes from working to waiting and
back, and nothing of the buffer's text changes."
  (agent-auto-test--with root
    (pcase-let ((`(,file . ,buffer) (agent-auto-test--started-task root)))
      (agent-auto-test--marks-due)
      (should (equal (agent-auto-test--heading-mark file "Fix it") " ▶"))
      (let ((text (with-current-buffer (find-buffer-visiting file)
                    (buffer-string))))
        (agent-session-event buffer 'submit)
        (agent-auto-test--marks-due)
        (should (equal (agent-auto-test--heading-mark file "Fix it") " ▶"))
        (agent-session-event buffer 'stop)
        (agent-auto-test--marks-due)
        (should (equal (agent-auto-test--heading-mark file "Fix it") " ⏸"))
        (agent-session-event buffer 'submit)
        (agent-auto-test--marks-due)
        (should (equal (agent-auto-test--heading-mark file "Fix it") " ▶"))
        (with-current-buffer (find-buffer-visiting file)
          (should (equal (buffer-string) text))
          (should-not (buffer-modified-p))))
      (agent-auto-test--close buffer)
      (agent-auto-test--marks-due)
      (should-not (agent-auto-test--heading-mark file "Fix it")))))

(ert-deftest agent-auto-test-mark-names-the-session-and-its-state ()
  "Give the mark a help-echo naming the session and what it is doing."
  (agent-auto-test--with root
    (pcase-let ((`(,_file . ,buffer) (agent-auto-test--started-task root)))
      (agent-session-event buffer 'submit)
      (should (equal (get-text-property 0 'help-echo (agent-auto--mark buffer))
                     (format "Session %s: working" (buffer-name buffer))))
      (should (eq (get-text-property 0 'face (agent-auto--mark buffer))
                  'agent-busy))
      (agent-session-event buffer 'stop)
      (should (equal (get-text-property 0 'help-echo (agent-auto--mark buffer))
                     (format "Session %s: waiting for input"
                             (buffer-name buffer)))))))

(ert-deftest agent-auto-test-mark-shows-in-the-agenda ()
  "Mark a task's agenda line before its title, and keep the mark current.
The line's text and markers stay as the agenda made them, a redo keeps
the mark, and closing the session removes it without a rebuild."
  (agent-auto-test--with root
    (pcase-let ((`(,file . ,buffer) (agent-auto-test--started-task root)))
      (agent-session-event buffer 'submit)
      (agent-auto-test--in-agenda file
        (let ((line (buffer-substring (pos-bol) (pos-eol)))
              (marker (get-text-property (pos-bol) 'org-hd-marker)))
          (should (equal (agent-auto-test--agenda-marks)
                         '(("▶ " . "Fix it :agent:"))))
          (agent-session-event buffer 'stop)
          (agent-auto-test--marks-due)
          (should (equal (mapcar #'car (agent-auto-test--agenda-marks))
                         '("⏸ ")))
          (should (equal-including-properties
                   (buffer-substring (pos-bol) (pos-eol)) line))
          (should (eq (get-text-property (pos-bol) 'org-hd-marker) marker))
          (org-agenda-redo)
          (should (equal (agent-auto-test--agenda-marks)
                         '(("⏸ " . "Fix it :agent:"))))
          (agent-auto-test--close buffer)
          (agent-auto-test--marks-due)
          (should-not (agent-auto-test--agenda-marks))
          (org-agenda-redo)
          (should-not (agent-auto-test--agenda-marks)))))))

(defmacro agent-auto-test--with-agenda-hooks (&rest body)
  "Evaluate BODY with what the mode puts on the hooks an agenda runs.
Those are the hook run when an agenda's mode is set up and the one run
after each command, bound to the functions `agent-auto--hooks' gives
them.  `org-agenda-finalize-hook' is left as it is."
  (declare (indent 0) (debug (body)))
  `(let ((org-agenda-mode-hook
          (agent-auto-test--hook-functions 'org-agenda-mode-hook))
         (post-command-hook
          (agent-auto-test--hook-functions 'post-command-hook)))
     ,@body))

(defun agent-auto-test--hook-functions (hook)
  "Return the functions the mode installs on HOOK."
  (mapcar #'cdr (seq-filter (lambda (entry) (eq (car entry) hook))
                            agent-auto--hooks)))

(defmacro agent-auto-test--in-custom-agenda (file &rest body)
  "Evaluate BODY in an agenda of FILE whose command binds the finalize hook.
The command binds `org-agenda-finalize-hook' to a function of its own,
for the build and for every redo, as a custom agenda command can.  What
the mode puts on the other hooks an agenda runs is in place."
  (declare (indent 1) (debug (form body)))
  `(agent-auto-test--with-agenda-hooks
     (let ((org-agenda-finalize-hook (list #'agent-auto--mark-agenda))
           (org-agenda-custom-commands
            '(("x" "Tasks" todo "TODO"
               ((org-agenda-finalize-hook '(ignore))))))
           (org-agenda-files (list ,file))
           (org-agenda-sticky nil)
           (org-agenda-window-setup 'current-window))
       (agent-auto-test--marks-due)
       (save-window-excursion
         (org-agenda nil "x")
         (unwind-protect
             (progn
               (should (derived-mode-p 'org-agenda-mode))
               (goto-char (point-min))
               (search-forward "Fix it")
               ,@body)
           (org-agenda-quit))))))

;; The mode's function on `org-agenda-finalize-hook' never ran in an
;; agenda whose command binds that hook, and the marks came back only
;; with the next search of the timer.
(ert-deftest agent-auto-test-marks-return-after-a-rebuild-that-hides-the-hook ()
  "Mark the lines of an agenda built with the finalize hook bound elsewhere.
The marks are there once the build's command is over, and again after
the agenda is redone."
  (agent-auto-test--with root
    (pcase-let ((`(,file . ,_buffer) (agent-auto-test--started-task root)))
      (agent-auto-test--in-custom-agenda file
        (agent-auto-test--marks-due)
        (should (equal (agent-auto-test--agenda-marks)
                       '(("▶ " . "Fix it :agent:"))))
        (org-agenda-redo)
        (agent-auto-test--marks-due)
        (should (equal (agent-auto-test--agenda-marks)
                       '(("▶ " . "Fix it :agent:"))))))))

;; A mark is an overlay that goes with the text it was put on.  Org puts
;; the marks back itself when it writes a line again, through the
;; finalize hook; a package that writes agenda lines its own way took the
;; marks with them until the next search of the timer.
(ert-deftest agent-auto-test-marks-return-after-an-agenda-line-changes ()
  "Mark an agenda line again once a command has written its text again.
The change is noticed after the command, from the agenda's text having
changed since it was marked, with no hook run by the change itself.
The marks are asked for once for a change, and nothing is done after a
command that changed nothing."
  (agent-auto-test--with root
    (pcase-let ((`(,file . ,_buffer) (agent-auto-test--started-task root)))
      (agent-auto-test--with-agenda-hooks
        (agent-auto-test--in-agenda file
          (agent-auto-test--marks-due)
          (should (equal (agent-auto-test--agenda-marks)
                         '(("▶ " . "Fix it :agent:"))))
          (run-hooks 'post-command-hook)
          (should-not (timerp agent-auto--marks-timer))
          (let ((inhibit-read-only t)
                (line (buffer-substring (pos-bol) (pos-eol))))
            (delete-region (pos-bol) (pos-eol))
            (insert line))
          (should-not (agent-auto-test--agenda-marks))
          (run-hooks 'post-command-hook)
          (should (timerp agent-auto--marks-timer))
          (cancel-timer agent-auto--marks-timer)
          (setq agent-auto--marks-timer nil)
          (run-hooks 'post-command-hook)
          (should-not (timerp agent-auto--marks-timer))
          (agent-auto--refresh-marks)
          (should (equal (agent-auto-test--agenda-marks)
                         '(("▶ " . "Fix it :agent:"))))
          (run-hooks 'post-command-hook)
          (should-not (timerp agent-auto--marks-timer)))))))

(ert-deftest agent-auto-test-agenda-mark-follows-the-priority ()
  "Put the agenda mark after the TODO keyword and the priority cookie."
  (agent-auto-test--with root
    (let ((file (agent-auto-test--file
                 root (agent-auto-test--task root "[#A] Fix it"))))
      (agent-auto-test--run)
      (agent-auto-test--in-agenda file
        (should (equal (agent-auto-test--agenda-marks)
                       '(("▶ " . "Fix it :agent:"))))))))

;; Org writes an agenda line again when the task's state is changed from
;; the agenda, and gives the new line the text properties of the old one,
;; the old keyword among them.  The mark, placed by that property, then
;; stood before the new keyword until the agenda was rebuilt.
(ert-deftest agent-auto-test-agenda-mark-follows-a-changed-keyword ()
  "Keep the mark before the title when the task's state changes in the agenda."
  (agent-auto-test--with root
    (let ((file (agent-auto-test--file
                 root (concat "#+TODO: TODO DOING | DONE\n"
                              (agent-auto-test--task root)))))
      (agent-auto-test--run)
      (agent-auto-test--in-agenda file
        (should (equal (agent-auto-test--agenda-marks)
                       '(("▶ " . "Fix it :agent:"))))
        (org-agenda-todo "DOING")
        (should (string-match-p "DOING Fix it"
                                (buffer-substring (pos-bol) (pos-eol))))
        (should (equal (agent-auto-test--agenda-marks)
                       '(("▶ " . "Fix it :agent:"))))
        (agent-auto--refresh-marks)
        (should (equal (agent-auto-test--agenda-marks)
                       '(("▶ " . "Fix it :agent:"))))))))

(ert-deftest agent-auto-test-closed-session-leaves-no-mark ()
  "Show no mark on a task whose recorded session is closed."
  (agent-auto-test--with root
    (let ((file (agent-auto-test--closed-task root "sid-00001"))
          (other (agent-auto-test--file
                  root (agent-auto-test--task root "Open one") "other.org")))
      (agent-auto-test--run)
      (should (= (length agent-auto-test--started) 2))
      (agent-auto--refresh-marks)
      (should (equal (agent-auto-test--heading-mark other "Open one") " ▶"))
      (should-not (agent-auto-test--heading-mark file "Fix it"))
      (agent-auto-test--in-agenda file
        (should-not (agent-auto-test--agenda-marks))))))

(ert-deftest agent-auto-test-unrecorded-task-gets-no-mark ()
  "Leave a task without a recorded session alone, next to a marked one."
  (agent-auto-test--with root
    (let ((file (agent-auto-test--file
                 root (concat (agent-auto-test--task root)
                              "* TODO Leave it\nA body.\n"))))
      (agent-auto-test--run)
      (should (= (length agent-auto-test--started) 1))
      (agent-auto-test--marks-due)
      (should (equal (agent-auto-test--heading-mark file "Fix it") " ▶"))
      (should-not (agent-auto-test--heading-mark file "Leave it"))
      (with-current-buffer (find-buffer-visiting file)
        (should (= (length (agent-auto-test--mark-strings)) 1)))
      (agent-auto-test--in-agenda file
        (should (equal (agent-auto-test--agenda-marks)
                       '(("▶ " . "Fix it :agent:"))))))))

(ert-deftest agent-auto-test-nil-mark-shows-nothing ()
  "Show no mark for a state whose option is nil."
  (agent-auto-test--with root
    (pcase-let ((`(,file . ,buffer) (agent-auto-test--started-task root)))
      (let ((agent-auto-waiting-mark nil))
        (agent-session-event buffer 'stop)
        (agent-auto-test--marks-due)
        (should-not (agent-auto-test--heading-mark file "Fix it"))
        (agent-session-event buffer 'submit)
        (agent-auto-test--marks-due)
        (should (equal (agent-auto-test--heading-mark file "Fix it") " ▶")))
      (let ((agent-auto-working-mark nil))
        (agent-auto--refresh-marks)
        (should-not (agent-auto-test--heading-mark file "Fix it"))))))

(ert-deftest agent-auto-test-marks-open-no-file ()
  "Mark only buffers that already visit a file, and remove marks with the mode."
  (agent-auto-test--with root
    (pcase-let ((`(,file . ,_buffer) (agent-auto-test--started-task root)))
      (with-current-buffer (find-buffer-visiting file)
        (set-buffer-modified-p nil)
        (kill-buffer))
      (agent-auto--refresh-marks)
      (should-not (find-buffer-visiting file))
      (find-file-noselect file)
      (agent-auto--refresh-marks)
      (should (equal (agent-auto-test--heading-mark file "Fix it") " ▶"))
      (agent-auto--remove-marks)
      (should-not (agent-auto-test--heading-mark file "Fix it")))))

(ert-deftest agent-auto-test-marks-are-quick ()
  "Bring the marks of a few hundred tasks and agenda lines up to date at once."
  (agent-auto-test--with root
    (let ((file (agent-auto-test--file
                 root (concat (agent-auto-test--task root)
                              (mapconcat (lambda (n)
                                           (format "* TODO Other %d\n:PROPERTIES:\n:AGENT_SESSION: old-%d\n:END:\nBody.\n"
                                                   n n))
                                         (number-sequence 1 400))))))
      (agent-auto-test--run)
      (agent-auto-test--in-agenda file
        (should (> (count-lines (point-min) (point-max)) 400))
        (let ((elapsed (benchmark-elapse (agent-auto--refresh-marks))))
          (should (< elapsed 0.2)))
        (should (equal (agent-auto-test--agenda-marks)
                       '(("▶ " . "Fix it :agent:"))))))))

;;;; The mode

(defconst agent-auto-test--installed
  '((agent-session-event-functions . agent-auto--on-event)
    (agent-session-id-functions . agent-auto--on-id)
    (agent-before-delivery-functions . agent-auto--confirm-delivery)
    (agent-delivery-functions . agent-auto--record-delivery)
    (agent-recorded-session-functions . agent-auto--recorded-session)
    (agent-session-state-change-functions . agent-auto--schedule-marks)
    (agent-session-id-functions . agent-auto--schedule-marks)
    (agent-before-exit-step-functions . agent-auto--handover-step)
    (after-save-hook . agent-auto--after-save)
    (kill-buffer-hook . agent-auto--session-killed)
    (org-mode-hook . agent-auto--schedule-marks)
    (org-agenda-finalize-hook . agent-auto--mark-agenda)
    (org-agenda-mode-hook . agent-auto--schedule-marks)
    (post-command-hook . agent-auto--check-agenda))
  "What the mode installs, each a cons of a hook and a function.")

(defmacro agent-auto-test--with-clean-mode (&rest body)
  "Evaluate BODY with the mode off and nothing of it installed.
Everything the mode installs is bound, so BODY can turn it on and off,
and it is turned off afterwards."
  (declare (indent 0) (debug (body)))
  `(let ((agent-session-event-functions nil)
         (agent-session-id-functions nil)
         (agent-delivery-functions nil)
         (agent-before-delivery-functions nil)
         (agent-recorded-session-functions nil)
         (agent-session-inherited-variables nil)
         (agent-session-state-change-functions nil)
         (agent-before-exit-step-functions nil)
         (after-save-hook nil)
         (agent-auto--handovers nil)
         (agent-auto--flush-timer nil)
         (agent-auto-handover-directory
          (expand-file-name "agent-auto-test-no-handovers/"
                            temporary-file-directory))
         (kill-buffer-hook nil)
         (org-mode-hook nil)
         (org-agenda-finalize-hook nil)
         (org-agenda-mode-hook nil)
         (post-command-hook nil)
         (agent-auto--marks-timer nil)
         (agent-auto--timer nil)
         (agent-auto--queue-timer nil)
         (agent-auto--queue nil)
         (agent-auto--processes nil)
         (agent-auto--starting nil)
         (agent-todo-directory-property "DIR")
         (agent-auto-interval 3600)
         (agent-auto-mode nil))
     (unwind-protect (progn ,@body)
       (agent-auto-mode -1))))

(defun agent-auto-test--tick-timers ()
  "Return the timers that run the mode's search."
  (seq-filter (lambda (timer)
                (eq (timer--function timer) #'agent-auto--tick))
              timer-list))

(defun agent-auto-test--should-be-installed ()
  "Fail unless everything the mode installs is installed exactly once."
  (pcase-dolist (`(,hook . ,function) agent-auto-test--installed)
    (should (equal (cons hook (seq-count (lambda (entry) (eq entry function))
                                         (symbol-value hook)))
                   (cons hook 1))))
  (dolist (variable '(agent-auto--link agent-auto--unattended))
    (should (= (seq-count (lambda (entry) (eq entry variable))
                          agent-session-inherited-variables)
               1)))
  (should (equal (agent-auto-test--tick-timers) (list agent-auto--timer))))

(ert-deftest agent-auto-test-mode-installs-and-removes-itself ()
  "Turn the timer and the hooks on and off with the mode."
  (agent-auto-test--with-clean-mode
    (agent-auto-mode 1)
    (should (timerp agent-auto--timer))
    (agent-auto-test--should-be-installed)
    (should (timerp agent-auto--marks-timer))
    (let ((timer agent-auto--timer))
      (agent-auto-mode -1)
      (should-not (memq timer timer-list)))
    (should-not agent-auto--timer)
    (should-not agent-session-event-functions)
    (should-not agent-session-id-functions)
    (should-not agent-delivery-functions)
    (should-not agent-before-delivery-functions)
    (should-not agent-recorded-session-functions)
    (should-not agent-session-inherited-variables)
    (should-not agent-session-state-change-functions)
    (should-not agent-before-exit-step-functions)
    (should-not after-save-hook)
    (should-not kill-buffer-hook)
    (should-not org-mode-hook)
    (should-not org-agenda-finalize-hook)
    (should-not org-agenda-mode-hook)
    (should-not post-command-hook)
    (should-not agent-auto--marks-timer)
    (should-error (agent-auto-run-now) :type 'user-error)))

;; The mode's function runs only when the mode is toggled, so an Emacs
;; that had the mode on kept the hooks and the timer of the version it
;; turned it on with, however often the file was loaded again.
(ert-deftest agent-auto-test-reload-installs-what-the-mode-needs ()
  "Load the file again while the mode is on and find everything installed.
Whatever the version that turned the mode on did not install is there,
and nothing is there twice, the timer included, however often the file
is loaded.  Loading it while the mode is off installs nothing."
  (let ((source (locate-library "agent-auto.el")))
    (agent-auto-test--with-clean-mode
      (load source nil t)
      (should-not (agent-auto-test--tick-timers))
      (should-not org-agenda-finalize-hook)
      (agent-auto-mode 1)
      (let ((timer agent-auto--timer))
        (remove-hook 'org-agenda-finalize-hook #'agent-auto--mark-agenda)
        (remove-hook 'agent-delivery-functions #'agent-auto--record-delivery)
        (setq agent-session-inherited-variables nil)
        (load source nil t)
        (agent-auto-test--should-be-installed)
        (should-not (memq timer timer-list)))
      (load source nil t)
      (agent-auto-test--should-be-installed)
      (should agent-auto-mode))))

(ert-deftest agent-auto-test-mode-needs-ripgrep ()
  "Refuse to turn on without ripgrep, and stay off."
  (let ((agent-auto-mode nil)
        (agent-auto--timer nil))
    (cl-letf (((symbol-function 'executable-find) #'ignore))
      (should-error (agent-auto-mode 1) :type 'user-error))
    (should-not agent-auto-mode)
    (should-not agent-auto--timer)))

(provide 'agent-auto-test)
;;; agent-auto-test.el ends here
