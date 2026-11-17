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
The hooks `agent-auto-mode' installs are in place, without its timer:
a test runs a search with `agent-auto-test--run'.  Tasks name their
directory in the property DIR, and worktrees go under ROOT."
  (declare (indent 1) (debug (symbolp body)))
  `(agent-test-helper-with-directory ,root
     (let ((agent-backends nil)
           (agent-auto-test--started nil)
           (agent-auto-test--buffers nil)
           (agent-auto-test--start-error nil)
           (agent-auto-test--resume-error nil)
           (agent-todo-directory-property "DIR")
           (agent-todo-in-progress-keyword nil)
           (agent-account-directory-rules nil)
           (agent-auto-files nil)
           (org-agenda-files nil)
           (agent-auto-eligible-functions nil)
           (agent-auto-backend nil)
           (agent-auto-instructions "Standing.")
           (agent-auto-silence-timeout 30)
           (agent-auto--pending nil)
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
           (agent-recorded-session-functions
            (list #'agent-auto--recorded-session))
           (agent-session-state-change-functions
            (list #'agent-auto--schedule-marks))
           (agent-auto--marks-timer nil)
           (agent-auto-working-mark "▶")
           (agent-auto-waiting-mark "⏸")
           (agent-session-inherited-variables '(agent-auto--link)))
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
  "Write a result only once the task's buffer has no unsaved edits."
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
        (agent-auto-test--run)
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

(ert-deftest agent-auto-test-acting-starts-anew-without-an-id ()
  "Say so and start a new session when the recorded one has no id.
A placeholder and a buffer's name name no conversation to resume.  The
task is linked to the new session."
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
        (agent-test-helper-with-messages messages
          (agent-auto-test--act file)
          (should (string-match-p "cannot be resumed; starting a new one"
                                  messages)))
        (should (= (length agent-auto-test--started) 2))
        (let ((new (car agent-auto-test--buffers)))
          (should (equal (plist-get (cdar agent-auto-test--started)
                                    :initial-prompt)
                         "Fix it\n\nThe body."))
          (should (equal (agent-auto-test--property file "Fix it" "AGENT_SESSION")
                         (buffer-name new)))
          (agent-auto-test--end-turn new "Status: done: fixed anew")
          (should (equal (agent-auto-test--tags file "Fix it") '("review"))))))))

(ert-deftest agent-auto-test-acting-starts-anew-when-resuming-fails ()
  "Report a failed resume and start a new session, linked to the task."
  (agent-auto-test--with root
    (let ((file (agent-auto-test--closed-task root "sid-00001"))
          (agent-auto-test--resume-error "no such conversation"))
      (agent-test-helper-with-messages messages
        (agent-auto-test--act file)
        (should (string-match-p
                 "Could not resume session sid-00001 (no such conversation); starting a new one"
                 messages)))
      (should (= (length agent-auto-test--started) 2))
      (let ((new (car agent-auto-test--buffers)))
        (should (equal (plist-get (cdar agent-auto-test--started) :initial-prompt)
                       "Fix it\n\nThe body."))
        (should (equal (agent-auto-test--property file "Fix it" "AGENT_SESSION")
                       (buffer-name new)))
        (should (buffer-local-value 'agent-auto--link new))))))

(ert-deftest agent-auto-test-double-prefix-starts-a-new-session ()
  "Start a new session with a double prefix, whatever the task records.
The task is linked to the new session, also while the old one is live."
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

(ert-deftest agent-auto-test-agenda-mark-follows-the-priority ()
  "Put the agenda mark after the TODO keyword and the priority cookie."
  (agent-auto-test--with root
    (let ((file (agent-auto-test--file
                 root (agent-auto-test--task root "[#A] Fix it"))))
      (agent-auto-test--run)
      (agent-auto-test--in-agenda file
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

(ert-deftest agent-auto-test-mode-installs-and-removes-itself ()
  "Turn the timer and the hooks on and off with the mode."
  (let ((agent-session-event-functions nil)
        (agent-session-id-functions nil)
        (agent-delivery-functions nil)
        (agent-recorded-session-functions nil)
        (agent-session-inherited-variables nil)
        (agent-session-state-change-functions nil)
        (kill-buffer-hook nil)
        (org-mode-hook nil)
        (org-agenda-finalize-hook nil)
        (agent-auto--marks-timer nil)
        (agent-auto--timer nil)
        (agent-auto--queue-timer nil)
        (agent-auto--queue nil)
        (agent-auto--processes nil)
        (agent-auto--starting nil)
        (agent-todo-directory-property "DIR")
        (agent-auto-interval 3600)
        (agent-auto-mode nil))
    (unwind-protect
        (progn
          (agent-auto-mode 1)
          (should (timerp agent-auto--timer))
          (should (memq agent-auto--timer timer-list))
          (should (memq #'agent-auto--on-event agent-session-event-functions))
          (should (memq #'agent-auto--on-id agent-session-id-functions))
          (should (memq #'agent-auto--record-delivery agent-delivery-functions))
          (should (memq #'agent-auto--recorded-session
                        agent-recorded-session-functions))
          (should (memq 'agent-auto--link agent-session-inherited-variables))
          (should (memq #'agent-auto--schedule-marks
                        agent-session-state-change-functions))
          (should (memq #'agent-auto--schedule-marks
                        agent-session-id-functions))
          (should (memq #'agent-auto--session-killed kill-buffer-hook))
          (should (memq #'agent-auto--schedule-marks org-mode-hook))
          (should (memq #'agent-auto--mark-agenda org-agenda-finalize-hook))
          (should (timerp agent-auto--marks-timer))
          (let ((timer agent-auto--timer))
            (agent-auto-mode -1)
            (should-not (memq timer timer-list)))
          (should-not agent-auto--timer)
          (should-not agent-session-event-functions)
          (should-not agent-session-id-functions)
          (should-not agent-delivery-functions)
          (should-not agent-recorded-session-functions)
          (should-not agent-session-inherited-variables)
          (should-not agent-session-state-change-functions)
          (should-not kill-buffer-hook)
          (should-not org-mode-hook)
          (should-not org-agenda-finalize-hook)
          (should-not agent-auto--marks-timer)
          (should-error (agent-auto-run-now) :type 'user-error))
      (agent-auto-mode -1))))

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
