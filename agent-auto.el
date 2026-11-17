;;; agent-auto.el --- Start sessions on tagged Org tasks -*- lexical-binding: t -*-

;; Copyright (C) 2026

;; Author: Pablo Stafforini
;; URL: https://github.com/benthamite/agent
;; Version: 0.1
;; Package-Requires: ((emacs "30.0") (agent "0.1"))

;; This file is NOT part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; `agent-auto-mode' starts a session, unattended, on every open Org
;; TODO that carries a tag marking it ready for an agent and has a
;; directory (`agent-todo-directory-property').  The task is the record:
;; it gets the session in a property, and when the session's turn ends
;; the tag is replaced by one saying how it ended, with a one-line
;; result.  A task is started once, and never again.  A task sent to a
;; session by hand is recorded, and hears back from its session, the
;; same way, whatever its tags.
;;
;; While a task's session is open, its heading and its agenda lines show
;; a mark that says whether the session is working or waiting.
;;
;; A timer does the looking.  It searches the files with ripgrep and
;; visits only those that have a ready task, edits an Org file only in
;; the buffer visiting it and only when that buffer has no unsaved
;; edits, and does its work in short steps, one file or one start each.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'agent)
(require 'agent-todo)

;;;; Customization

(defgroup agent-auto nil
  "Sessions started unattended on tagged Org tasks."
  :group 'agent)

(defcustom agent-auto-ready-tag "agent"
  "Org tag marking a task as ready for an agent.
`agent-auto-mode' starts a session on every open TODO that carries this
tag on its own heading; a tag inherited from a heading above does not
count."
  :type 'string
  :group 'agent-auto)

(defcustom agent-auto-review-tag "review"
  "Org tag given to a task whose session reported it done.
It replaces `agent-auto-ready-tag' when the session ends its turn with
\"Status: done\" or \"Status: done, pending verification\".  A task
sent to a session by hand gets it too, whatever its tags."
  :type 'string
  :group 'agent-auto)

(defcustom agent-auto-blocked-tag "blocked"
  "Org tag given to a task whose session waits on the user.
It replaces `agent-auto-ready-tag' when the session ends its turn with
\"Status: waiting on you\", shows a permission or input prompt or any
other dialog in place of its input box, or has its turn interrupted."
  :type 'string
  :group 'agent-auto)

(defcustom agent-auto-stuck-tag "stuck"
  "Org tag given to a task whose session ended with no result.
It replaces `agent-auto-ready-tag' when the session could not be
started, stopped without a status line, gave no sign of life for
`agent-auto-silence-timeout', or is no longer running.  Only a session
the timer started is stuck for stopping without a status line: one
started by hand, or resumed, is the user's to drive."
  :type 'string
  :group 'agent-auto)

(defcustom agent-auto-files nil
  "Where `agent-auto-mode' looks for tasks.
Nil means the files of `org-agenda-files'.  Otherwise a list of Org
files and of directories, whose Org files are searched, or a function
called with no arguments that returns such a list.  The files are
searched on disk with ripgrep for the tags, and only a file that has
one is visited."
  :type '(choice (const :tag "The agenda files" nil)
                 (repeat :tag "Files and directories" file)
                 (function :tag "Function returning them"))
  :group 'agent-auto)

(defcustom agent-auto-interval 30
  "Seconds between two searches for ready tasks.
A change takes effect when `agent-auto-mode' is next turned on."
  :type 'number
  :group 'agent-auto)

(defcustom agent-auto-silence-timeout 30
  "Minutes without a sign of life after which a task is stuck.
A sign of life is an event of the task's session, or activity recorded
in its transcript.  A task whose recorded session is not running for
this long is stuck too."
  :type 'number
  :group 'agent-auto)

(defcustom agent-auto-eligible-functions nil
  "Abnormal hook deciding whether a ready task may be started.
Each function is called with no arguments, with point on the task's
heading in the buffer visiting its file, widened.  The task is started
only when every function returns non-nil, so any function can veto it,
and a function that signals an error vetoes it too.  The hook runs on
every search for as long as the task is ready and unstarted, so its
functions must be quick and must not change the buffer."
  :type 'hook
  :group 'agent-auto)

(defcustom agent-auto-instructions
  "You are working on this task unattended: nobody is watching this \
session.  Do what this project's own instructions allow an agent to do, and \
nothing beyond them.  Never send a message to a person, whether by email, \
chat, a comment or any other channel.  End your reply with exactly one \
status line: `Status: done: RESULT', with the result in one line; `Status: \
done, pending verification: WHAT at WHEN', when proof arrives later; \
`Status: waiting on you: QUESTION', when you need a decision or input; or \
`Status: in progress: WHAT next', only when a background task you started \
will resume you."
  "Standing instructions added to the brief of every unattended session.
The brief is the task's heading and body, then this paragraph.  Nil or
an empty string adds nothing."
  :type '(choice (const :tag "None" nil) string)
  :group 'agent-auto)

(defcustom agent-auto-backend nil
  "The backend unattended sessions are started with.
Nil means the only registered backend; with several registered, no
session is started until this names one of them, such as `claude-code'."
  :type '(choice (const :tag "The only registered backend" nil) symbol)
  :group 'agent-auto)

(defcustom agent-auto-working-mark "▶"
  "Mark shown on a task whose session is open and working.
It is shown after the TODO keyword of the task's heading, and before the
task's title on its lines in an Org agenda, for as long as the session
the task records has a live buffer.  A session whose state is not known
yet, as before its first event, shows this mark too.  Nil shows no mark
for such a session."
  :type '(choice (const :tag "No mark" nil) string)
  :group 'agent-auto)

(defcustom agent-auto-waiting-mark "⏸"
  "Mark shown on a task whose session is open and waiting for input.
It is shown where `agent-auto-working-mark' is.  Nil shows no mark for
such a session."
  :type '(choice (const :tag "No mark" nil) string)
  :group 'agent-auto)

(defconst agent-auto-session-property "AGENT_SESSION"
  "Org property recording a task's session.
Its value is the session's id, or the name of its buffer until the id
is known.  A task that has it is never started.")

(defconst agent-auto-backend-property "AGENT_BACKEND"
  "Org property recording the backend of a task's session.
A session can be resumed only by the backend that ran it.")

(defconst agent-auto-directory-property "AGENT_DIRECTORY"
  "Org property recording where a task's session runs.
It is recorded only for a session that does not run in the task's own
directory, as one given a worktree; a session is resumed where it ran.")

(defconst agent-auto-started-property "AGENT_STARTED"
  "Org property recording when a task's session was started.")

(defconst agent-auto-result-property "AGENT_RESULT"
  "Org property holding the one-line result of a task's session.")

;;;; State

(cl-defstruct (agent-auto-link (:constructor agent-auto-link-create)
                               (:copier nil))
  "The link from a session to the Org task it works on."
  (file nil :documentation "The Org file holding the task.")
  (recorded nil :documentation "The value of the task's
`agent-auto-session-property', by which its heading is found."))

(defvar-local agent-auto--link nil
  "The `agent-auto-link' of this session buffer, or nil.")

(defvar-local agent-auto--last-event nil
  "Float time of this session's last event, or nil before the first.")

(defvar-local agent-auto--unattended nil
  "Non-nil in a session the timer started, which nobody is watching.
Such a session was told to end its replies with a status line, so a
reply without one leaves its task stuck.  A session started by hand or
resumed is the user's to drive, and its task is never stuck for that.")

(defvar-local agent-auto--settled nil
  "Non-nil once this session's turn ended with a result written to its task.
A session that works again is unsettled.")

(defvar-local agent-auto--exiting nil
  "Non-nil while this session is being exited.")

(defvar-local agent-auto--checked nil
  "The values of this session already searched for among the tasks.")

(defvar agent-auto--timer nil
  "Timer running `agent-auto--tick'.")

(defvar agent-auto--queue nil
  "Steps waiting to run, each a function of no arguments.")

(defvar agent-auto--queue-timer nil
  "Timer running the next step of `agent-auto--queue'.")

(defvar agent-auto--marks-timer nil
  "Timer running `agent-auto--refresh-marks', or nil when none is pending.")

(defvar agent-auto--processes nil
  "The subprocesses now running.")

(defvar agent-auto--starting nil
  "The starts in flight, each a cons of a link and the checkout it holds.")

(defvar agent-auto--pending nil
  "Results not yet written, each a list of a link, a kind, a text and a flag.
See `agent-auto--conclude'.")

(defvar agent-auto--missing (make-hash-table :test #'equal)
  "Hash table from a recorded session that is not running to when that was seen.
The key is a cons of the task's file and the recorded value.")

(defvar agent-auto--turn-end-delay 2
  "Seconds after a session's turn ends before its last reply is read.
The transcript is written a moment after the event.")

(defvar agent-auto--turn-end-retries 5
  "Times a turn's end is looked at again while its reply cannot be read.
A turn that ends within seconds of the session's start can end before
the backend has reported the session's id, by which its transcript is
found.")

(defvar agent-auto--start-check-delay 10
  "Seconds after a session starts before it is checked for a dialog.
See `agent-auto--check-dialog'.")

(defmacro agent-auto--guard (what &rest body)
  "Evaluate BODY, reporting an error instead of signalling it.
WHAT says what was being done.  Code run from a timer, a sentinel or a
hook must not signal."
  (declare (indent 1) (debug (form body)))
  `(condition-case err
       (progn ,@body)
     (error (message "agent-auto: %s: %s" ,what (error-message-string err))
            nil)))

;;;; The mode

;;;###autoload
(define-minor-mode agent-auto-mode
  "Start sessions, unattended, on Org tasks tagged for an agent.
Every `agent-auto-interval' seconds, look in `agent-auto-files' for open
TODOs that carry `agent-auto-ready-tag', have a directory that exists
\(`agent-todo-directory-property', their own or inherited), record no
session and are not vetoed by `agent-auto-eligible-functions', and start
a session on each: in that directory, or in a worktree when another
tracked session holds the checkout, with the task's heading and body as
its brief, followed by `agent-auto-instructions'.

The task records its session in `agent-auto-session-property', so it is
started once.  When the session's turn ends, the tag is replaced by
`agent-auto-review-tag', `agent-auto-blocked-tag' or
`agent-auto-stuck-tag', and the result is written in
`agent-auto-result-property'.  A task sent to a session by hand is
recorded the same way and gets its session's result the same way,
whatever its tags, but is never stuck for a reply without a status line.

While a task's session is open, its heading and its lines in an Org
agenda show `agent-auto-working-mark' or `agent-auto-waiting-mark'."
  :global t
  :group 'agent-auto
  (agent-auto--reset)
  (if agent-auto-mode
      (agent-auto--enable)
    (agent-auto--disable)))

(defun agent-auto--enable ()
  "Watch sessions and start the timer; refuse without ripgrep."
  (unless (executable-find "rg")
    (setq agent-auto-mode nil)
    (user-error "`agent-auto-mode' needs ripgrep (rg) to search for tasks"))
  (unless agent-todo-directory-property
    (message "agent-auto: no task has a directory while `agent-todo-directory-property' is nil"))
  (add-to-list 'agent-session-inherited-variables 'agent-auto--link)
  (add-to-list 'agent-session-inherited-variables 'agent-auto--unattended)
  (add-hook 'agent-session-event-functions #'agent-auto--on-event)
  (add-hook 'agent-session-id-functions #'agent-auto--on-id)
  (add-hook 'agent-delivery-functions #'agent-auto--record-delivery)
  (add-hook 'agent-recorded-session-functions #'agent-auto--recorded-session)
  (add-hook 'agent-session-state-change-functions #'agent-auto--schedule-marks)
  (add-hook 'agent-session-id-functions #'agent-auto--schedule-marks)
  (add-hook 'kill-buffer-hook #'agent-auto--session-killed)
  (add-hook 'org-mode-hook #'agent-auto--schedule-marks)
  (add-hook 'org-agenda-finalize-hook #'agent-auto--mark-agenda)
  (agent-auto--schedule-marks)
  (setq agent-auto--timer
        (run-with-timer agent-auto-interval agent-auto-interval
                        #'agent-auto--tick)))

(defun agent-auto--disable ()
  "Stop watching sessions."
  (setq agent-session-inherited-variables
        (seq-difference agent-session-inherited-variables
                        '(agent-auto--link agent-auto--unattended)))
  (remove-hook 'agent-session-event-functions #'agent-auto--on-event)
  (remove-hook 'agent-session-id-functions #'agent-auto--on-id)
  (remove-hook 'agent-delivery-functions #'agent-auto--record-delivery)
  (remove-hook 'agent-recorded-session-functions
               #'agent-auto--recorded-session)
  (remove-hook 'agent-session-state-change-functions
               #'agent-auto--schedule-marks)
  (remove-hook 'agent-session-id-functions #'agent-auto--schedule-marks)
  (remove-hook 'kill-buffer-hook #'agent-auto--session-killed)
  (remove-hook 'org-mode-hook #'agent-auto--schedule-marks)
  (remove-hook 'org-agenda-finalize-hook #'agent-auto--mark-agenda)
  (agent-auto--remove-marks))

(defun agent-auto--reset ()
  "Cancel the timers and subprocesses and forget the steps waiting.
Results not yet written are kept."
  (dolist (timer (list agent-auto--timer agent-auto--queue-timer
                       agent-auto--marks-timer))
    (when (timerp timer)
      (cancel-timer timer)))
  (dolist (process agent-auto--processes)
    (when (process-live-p process)
      (set-process-sentinel process #'ignore)
      (delete-process process))
    (when (buffer-live-p (process-buffer process))
      (kill-buffer (process-buffer process))))
  (setq agent-auto--timer nil
        agent-auto--queue-timer nil
        agent-auto--marks-timer nil
        agent-auto--queue nil
        agent-auto--processes nil
        agent-auto--starting nil))

;;;###autoload
(defun agent-auto-run-now ()
  "Look for ready tasks now instead of waiting for the timer."
  (interactive)
  (unless agent-auto-mode
    (user-error "Turn `agent-auto-mode' on first"))
  (agent-auto--tick))

(defun agent-auto--tick ()
  "Bring the tasks and their sessions up to date, then look for ready tasks."
  (agent-auto--guard "updating tasks"
    (mapc #'agent-auto--sync-session (agent-auto--linked-buffers))
    (mapc #'agent-auto--check-dialog (agent-auto--linked-buffers))
    (agent-auto--check-silence)
    (agent-auto--flush-pending))
  (agent-auto--schedule-marks)
  (agent-auto--guard "searching for tasks"
    (agent-auto--scan)))

(defun agent-auto--log (format-string &rest arguments)
  "Log FORMAT-STRING with ARGUMENTS to *Messages* without echoing it."
  (let ((inhibit-message t))
    (apply #'message (concat "agent-auto: " format-string) arguments)))

;;;; Steps

(defun agent-auto--enqueue (function)
  "Run FUNCTION, of no arguments, as a step of its own.
Steps run one at a time, each from a timer, so that Emacs handles input
between them."
  (setq agent-auto--queue (nconc agent-auto--queue (list function)))
  (agent-auto--schedule-step))

(defun agent-auto--schedule-step ()
  "Arrange for the next step to run."
  (unless (timerp agent-auto--queue-timer)
    (setq agent-auto--queue-timer
          (run-with-timer 0 nil #'agent-auto--run-step))))

(defun agent-auto--run-step ()
  "Run the next step of `agent-auto--queue'."
  (setq agent-auto--queue-timer nil)
  (when-let* ((step (pop agent-auto--queue)))
    (agent-auto--guard "running a step"
      (funcall step)))
  (when agent-auto--queue
    (agent-auto--schedule-step)))

(defun agent-auto--call (program arguments directory callback)
  "Run PROGRAM with ARGUMENTS in DIRECTORY without waiting for it.
Call CALLBACK with its exit status and its output when it ends.  A nil
DIRECTORY is the home directory."
  (let* ((default-directory (or directory (expand-file-name "~/")))
         (output (generate-new-buffer " *agent-auto*" t))
         (process (make-process
                   :name "agent-auto"
                   :buffer output
                   :command (cons program arguments)
                   :noquery t
                   :connection-type 'pipe
                   :sentinel (lambda (process _event)
                               (unless (process-live-p process)
                                 (agent-auto--finish-call process callback))))))
    (push process agent-auto--processes)
    process))

(defun agent-auto--finish-call (process callback)
  "Call CALLBACK with the exit status and output of PROCESS, which ended."
  (setq agent-auto--processes (delq process agent-auto--processes))
  (let* ((buffer (process-buffer process))
         (output (with-current-buffer buffer (buffer-string))))
    (kill-buffer buffer)
    (agent-auto--guard "reading a subprocess"
      (funcall callback (process-exit-status process) output))))

;;;; Searching

(defun agent-auto--scan ()
  "Search the files for ready tasks and recorded sessions.
Each file ripgrep finds is then visited in a step of its own.  Nothing
is searched while the steps of the search before are still running."
  (unless (or agent-auto--queue agent-auto--processes)
    (when-let* ((files (agent-auto--files)))
      (agent-auto--call
       "rg"
       (append '("--files-with-matches" "--null" "--fixed-strings"
                 "--no-messages")
               (mapcan (lambda (pattern) (list "-e" pattern))
                       (cons (format ":%s:" agent-auto-ready-tag)
                             (agent-auto--unchecked-values)))
               '("--")
               files)
       nil
       (lambda (_status output)
         (dolist (file (split-string output "\0" t))
           (agent-auto--enqueue (lambda () (agent-auto--visit-file file)))))))))

(defun agent-auto--files ()
  "Return the Org files to search, as absolute names of files that exist."
  (let ((entries (cond ((functionp agent-auto-files)
                        (funcall agent-auto-files))
                       (agent-auto-files)
                       (t (org-agenda-files t)))))
    (seq-filter #'file-regular-p
                (mapcan (lambda (entry)
                          (let ((name (expand-file-name entry)))
                            (if (file-directory-p name)
                                (directory-files name t "\\.org\\'")
                              (list name))))
                        entries))))

(defun agent-auto--unchecked-values ()
  "Return the values of the sessions not yet searched for among the tasks.
A session resumed or restarted is linked again to the task that records
it; each of its values, its id and its buffer's name, is searched for
once.  The values returned are marked as searched."
  (mapcan (lambda (buffer)
            (let* ((values (agent-auto--session-values buffer))
                   (new (seq-difference
                         values
                         (buffer-local-value 'agent-auto--checked buffer))))
              (with-current-buffer buffer
                (setq agent-auto--checked values))
              new))
          (agent-auto--unlinked-buffers)))

(defun agent-auto--visit-file (file)
  "Link the sessions FILE records and queue its ready tasks.
A file whose buffer has unsaved edits is left for a later search."
  (when-let* ((buffer (agent-auto--org-buffer file)))
    (with-current-buffer buffer
      (agent-auto--attach-recorded file))
    (when (eq (agent-auto--editable-buffer file) buffer)
      (dolist (marker (with-current-buffer buffer
                        (agent-auto--ready-headings)))
        (agent-auto--enqueue
         (lambda () (agent-auto--consider file marker)))))))

(defun agent-auto--ready-headings ()
  "Return a marker at each heading of the buffer that shows the ready tag."
  (org-with-wide-buffer
   (goto-char (point-min))
   (let ((regexp (format "^\\*+[ \t]+.*:%s:" (regexp-quote agent-auto-ready-tag)))
         (case-fold-search nil)
         markers)
     (while (re-search-forward regexp nil t)
       (push (copy-marker (line-beginning-position)) markers))
     (nreverse markers))))

(defun agent-auto--consider (file marker)
  "Start the task at MARKER in FILE if it may be started.
A ready task that records a session is checked for that session
instead; see `agent-auto--check-missing'."
  (unwind-protect
      (when-let* ((buffer (marker-buffer marker))
                  ((eq (agent-auto--editable-buffer file) buffer)))
        (with-current-buffer buffer
          (org-with-wide-buffer
           (goto-char marker)
           (when (agent-auto--ready-task-p)
             (if-let* ((recorded (org-entry-get
                                  nil agent-auto-session-property)))
                 (agent-auto--check-missing file recorded)
               (when-let* ((directory (agent-auto--eligible-directory)))
                 (agent-auto--start file directory)))))))
    (set-marker marker nil)))

(defun agent-auto--ready-task-p ()
  "Return non-nil when point is on an open TODO that carries the ready tag."
  (and (org-at-heading-p)
       (org-entry-is-todo-p)
       (member agent-auto-ready-tag (org-get-tags nil t))
       t))

(defun agent-auto--eligible-directory ()
  "Return the directory of the task at point if it may be started, or nil.
The directory is the one `agent-todo-directory-property' names, and must
exist.  Any function in `agent-auto-eligible-functions' can veto the
task."
  (when-let* ((agent-todo-directory-property)
              (directory (let ((inhibit-message t))
                           (agent-todo--property-directory)))
              ((save-excursion
                 (run-hook-with-args-until-failure
                  'agent-auto-eligible-functions))))
    directory))

(defun agent-auto--check-missing (file recorded)
  "Mark the task in FILE stuck when its RECORDED session stays away.
A session can be away for a while, as after Emacs restarts and before it
is resumed, so the task is stuck only once the session has not been
running for `agent-auto-silence-timeout'."
  (let ((key (cons file recorded))
        (now (float-time)))
    (if (agent-auto--session-live-p recorded)
        (remhash key agent-auto--missing)
      (let ((since (or (gethash key agent-auto--missing)
                       (puthash key now agent-auto--missing))))
        (when (> (- now since) (* 60 agent-auto-silence-timeout))
          (remhash key agent-auto--missing)
          (agent-auto--conclude
           (agent-auto-link-create :file file :recorded recorded)
           'stuck "its session is not running" t))))))

(defun agent-auto--session-live-p (recorded)
  "Return non-nil when the session a task records as RECORDED is running.
A session being started counts."
  (or (seq-some (lambda (start)
                  (equal (agent-auto-link-recorded (car start)) recorded))
                agent-auto--starting)
      (agent-auto--session-buffer recorded)))

(defun agent-auto--session-buffer (recorded)
  "Return the live buffer of the session a task records as RECORDED, or nil."
  (seq-find (lambda (buffer)
              (or (member recorded (agent-auto--session-values buffer))
                  (when-let* ((link (buffer-local-value 'agent-auto--link
                                                        buffer)))
                    (equal (agent-auto-link-recorded link) recorded))))
            (agent-session-buffers)))

;;;; Starting

(defun agent-auto--start (file directory)
  "Start a session in DIRECTORY on the task at point, which is in FILE.
The task records the start before anything else happens, so that it is
never started twice."
  (let* ((backend (agent-auto--backend))
         (entry (agent-todo--collect-at-point))
         (link (agent-auto-link-create :file file
                                       :recorded (agent-auto--placeholder))))
    (agent-auto--record (agent-auto-link-recorded link) backend)
    (agent-todo--save)
    (agent-auto--launch link backend directory
                        (agent-todo--slug (plist-get entry :title))
                        (agent-auto--brief entry))))

(defun agent-auto--backend ()
  "Return the backend to start sessions with, or signal an error."
  (cond (agent-auto-backend
         (if (agent-backend agent-auto-backend)
             agent-auto-backend
           (error "`agent-auto-backend' names `%s', which is not registered"
                  agent-auto-backend)))
        ((= (length agent-backends) 1) (caar agent-backends))
        (t (error "Set `agent-auto-backend': %s"
                  (if agent-backends
                      "several backends are registered"
                    "no backend is registered")))))

(defun agent-auto--placeholder ()
  "Return a value recording a session that is being started."
  (format "starting-%s-%04x" (format-time-string "%Y%m%dT%H%M%S")
          (random #x10000)))

(defun agent-auto--record (value backend)
  "Record VALUE as the BACKEND session of the task at point, started now."
  (let ((inhibit-message t))
    (org-entry-put nil agent-auto-session-property value)
    (org-entry-put nil agent-auto-backend-property (symbol-name backend))
    (org-entry-put nil agent-auto-started-property
                   (format-time-string "[%Y-%m-%d %a %H:%M]"))))

(defun agent-auto--brief (entry)
  "Return the brief of a session on ENTRY, a plist of `:title' and `:body'.
It is the task's heading and body, then `agent-auto-instructions'."
  (let ((task (agent-todo--format-prompt entry)))
    (if (member agent-auto-instructions '(nil ""))
        task
      (concat task "\n\n" agent-auto-instructions))))

(defun agent-auto--launch (link backend directory slug brief)
  "Start a BACKEND session named after SLUG on LINK's task, with BRIEF.
It runs in DIRECTORY, or in a worktree of DIRECTORY's checkout when
another tracked session holds that checkout.  A failure marks the task
stuck."
  (let* ((checkout (agent-auto--checkout directory))
         (start (cons link checkout)))
    (push start agent-auto--starting)
    (condition-case err
        (if (and checkout (agent-auto--checkout-held-p checkout start))
            (agent-auto--add-worktree
             checkout slug
             (lambda (worktree problem)
               (if problem
                   (agent-auto--start-failed start problem)
                 (setcdr start worktree)
                 (agent-auto--spawn
                  start backend
                  (agent-auto--worktree-directory directory checkout worktree)
                  directory slug brief))))
          (agent-auto--spawn start backend directory directory slug brief))
      (error (agent-auto--start-failed start (error-message-string err))))))

(defun agent-auto--spawn (start backend directory account-directory slug brief)
  "Start the BACKEND session of START in DIRECTORY with BRIEF.
START is an entry of `agent-auto--starting'.  The session is named
after SLUG and runs under the account ACCOUNT-DIRECTORY gets, which is
the task's own directory even when DIRECTORY is a worktree made for it.
Nothing is asked, and the windows are left as they are."
  (condition-case err
      (let* ((directory (file-name-as-directory (expand-file-name directory)))
             (buffer
              (save-window-excursion
                (save-current-buffer
                  (let ((agent-inhibit-prompts t))
                    (agent--start-named-session
                     (agent-session-create
                      :backend backend
                      :account (agent-account-resolve backend nil
                                                      account-directory)
                      :directory directory)
                     slug
                     :initial-prompt brief))))))
        (setq agent-auto--starting (delq start agent-auto--starting))
        (agent-auto--attach buffer (car start) t)
        (agent-auto--sync-session buffer)
        (run-with-timer agent-auto--start-check-delay nil
                        #'agent-auto--check-dialog buffer)
        (agent-auto--log "started %s in %s" (buffer-name buffer)
                         (abbreviate-file-name directory)))
    (error (agent-auto--start-failed start (error-message-string err)))))

(defun agent-auto--start-failed (start reason)
  "Mark the task of START stuck because its session did not start for REASON."
  (setq agent-auto--starting (delq start agent-auto--starting))
  (message "agent-auto: could not start a session: %s" reason)
  (agent-auto--conclude (car start) 'stuck (concat "start failed: " reason) t))

(defun agent-auto--attach (buffer link &optional unattended)
  "Record that session BUFFER works on the task of LINK.
UNATTENDED is non-nil for a session the timer started; see
`agent-auto--unattended'."
  (with-current-buffer buffer
    (setq agent-auto--link link
          agent-auto--unattended unattended
          agent-auto--last-event (float-time)
          agent-auto--settled nil
          agent-auto--exiting nil))
  (agent-auto--schedule-marks))

;;;; Where sessions run

(defun agent-auto--checkout (directory)
  "Return the root of the Git checkout holding DIRECTORY, or nil."
  (when-let* ((root (locate-dominating-file directory ".git")))
    (file-name-as-directory (file-truename root))))

(defun agent-auto--checkout-held-p (checkout &optional except)
  "Return non-nil when a tracked session runs, or is to run, in CHECKOUT.
A tracked session is one linked to a task.  EXCEPT is a start in flight
that does not count."
  (or (seq-some (lambda (start)
                  (and (not (eq start except))
                       (equal (cdr start) checkout)))
                agent-auto--starting)
      (seq-some (lambda (buffer)
                  (when-let* ((session (agent-session buffer))
                              (directory (agent-session-directory session)))
                    (equal (agent-auto--checkout directory) checkout)))
                (agent-auto--linked-buffers))))

(defun agent-auto--add-worktree (checkout slug callback)
  "Find or create a worktree of CHECKOUT named after SLUG.
Call CALLBACK with the worktree and nil, or with nil and why it could
not be created.  It goes in `agent-branch-worktree-directory', under the
repository's name, on the branch agent-auto/NAME.  Creating it can take
a while in a large repository, so it is not waited for."
  (let* ((path (agent-auto--free-worktree checkout slug))
         (name (file-name-nondirectory (directory-file-name path)))
         (branch (concat "agent-auto/" name)))
    (if (file-exists-p path)
        (funcall callback path nil)
      (make-directory (file-name-directory (directory-file-name path)) t)
      (agent-auto--git checkout "worktree" "prune")
      (agent-auto--call
       "git"
       (if (zerop (agent-auto--git checkout "rev-parse" "--verify" "--quiet"
                                   (concat "refs/heads/" branch)))
           (list "worktree" "add" (directory-file-name path) branch)
         (list "worktree" "add" "-b" branch (directory-file-name path)))
       checkout
       (lambda (status output)
         (if (zerop status)
             (funcall callback path nil)
           (funcall callback nil
                    (format "could not create the worktree %s: %s"
                            (abbreviate-file-name path)
                            (string-trim output)))))))))

(defun agent-auto--free-worktree (checkout slug)
  "Return a worktree path of CHECKOUT for SLUG that no tracked session holds.
A path that exists and is no worktree is passed over."
  (let ((base (expand-file-name (agent--git-repository-name checkout)
                                agent-branch-worktree-directory))
        (n 1)
        path)
    (while (progn
             (setq path (file-name-as-directory
                         (file-truename
                          (expand-file-name
                           (if (= n 1) slug (format "%s-%d" slug n))
                           base))))
             (or (agent-auto--checkout-held-p path)
                 (and (file-exists-p path)
                      (not (file-exists-p (expand-file-name ".git" path))))))
      (setq n (1+ n)))
    path))

(defun agent-auto--git (checkout &rest arguments)
  "Run git with ARGUMENTS in CHECKOUT and return its exit status."
  (let ((default-directory checkout))
    (apply #'call-process "git" nil nil nil arguments)))

(defun agent-auto--worktree-directory (directory checkout worktree)
  "Return the directory in WORKTREE that DIRECTORY is in CHECKOUT.
That is WORKTREE itself when it has no such directory."
  (let ((inside (file-name-as-directory
                 (expand-file-name
                  (file-relative-name (file-truename directory) checkout)
                  worktree))))
    (if (file-directory-p inside) inside worktree)))

;;;; Watching sessions

(defun agent-auto--linked-buffers ()
  "Return the live session buffers linked to a task."
  (seq-filter (lambda (buffer) (buffer-local-value 'agent-auto--link buffer))
              (agent-session-buffers)))

(defun agent-auto--unlinked-buffers ()
  "Return the live session buffers linked to no task."
  (seq-remove (lambda (buffer) (buffer-local-value 'agent-auto--link buffer))
              (agent-session-buffers)))

(defun agent-auto--session-values (buffer)
  "Return what a task can record session BUFFER as, the preferred value first.
That is its id, when known, and its buffer's name."
  (delq nil (list (when-let* ((session (agent-session buffer)))
                    (agent-session-id session))
                  (buffer-name buffer))))

(defun agent-auto--on-event (buffer event)
  "Follow EVENT of session BUFFER when it works on a task.
For `agent-session-event-functions'."
  (when (buffer-local-value 'agent-auto--link buffer)
    (agent-auto--guard "following a session"
      (with-current-buffer buffer
        (setq agent-auto--last-event (float-time))
        (pcase event
          ((or 'stop 'idle-prompt)
           (run-with-timer agent-auto--turn-end-delay nil
                           #'agent-auto--turn-end buffer
                           agent-auto--turn-end-retries))
          ('blocked
           (agent-auto--settle
            buffer 'blocked
            "the session waits at a permission or input prompt, or was interrupted"))
          ('exit-request (setq agent-auto--exiting t))
          ('user-submit (setq agent-auto--exiting nil
                              agent-auto--settled nil))
          ((or 'submit 'activity) (setq agent-auto--settled nil)))))))

(defun agent-auto--on-id (buffer)
  "Record the new id of session BUFFER on its task.
For `agent-session-id-functions'."
  (when (buffer-local-value 'agent-auto--link buffer)
    (agent-auto--guard "recording a session id"
      (agent-auto--sync-session buffer))))

(defun agent-auto--turn-end (buffer &optional retries)
  "Write on its task how the turn of session BUFFER ended.
A session being exited is left alone: the turns of its exit are not the
task's result.  With RETRIES, a positive number, a session whose reply
cannot be read yet is looked at again after `agent-auto--turn-end-delay',
that many times at most, before it counts as stopped without a status
line, which leaves the task stuck only when the timer started the
session; see `agent-auto--unattended'."
  (when (and (buffer-live-p buffer)
             (buffer-local-value 'agent-auto--link buffer)
             (not (buffer-local-value 'agent-auto--exiting buffer)))
    (agent-auto--guard "reading a session's reply"
      (let ((text (plist-get (agent-session-last-reply buffer) :text)))
        (if (and (null text) retries (> retries 0))
            (run-with-timer agent-auto--turn-end-delay nil
                            #'agent-auto--turn-end buffer (1- retries))
          (agent-auto--apply-reply-text
           buffer text (buffer-local-value 'agent-auto--unattended buffer)))))))

(defun agent-auto--apply-reply (buffer strict)
  "Write on its task what the last reply of session BUFFER reports.
STRICT is as for `agent-auto--apply-reply-text'."
  (agent-auto--apply-reply-text
   buffer (plist-get (agent-session-last-reply buffer) :text) strict))

(defun agent-auto--apply-reply-text (buffer text strict)
  "Write on its task what TEXT, the last reply of session BUFFER, reports.
TEXT is nil when the session has no reply that can be read.  Done and
done pending verification are a review, waiting is blocked, and in
progress changes nothing.  With STRICT non-nil, a reply without a status
line is stuck; otherwise it changes nothing either."
  (let* ((status (and text (agent--reply-text-status text)))
         (detail (agent-auto--one-line (plist-get status :detail))))
    (pcase (plist-get status :status)
      ('done
       (agent-auto--settle
        buffer 'review
        (or detail (agent-auto--summary text (plist-get status :line)) "done")))
      ('pending-verification
       (agent-auto--settle
        buffer 'review (concat "pending verification"
                               (and detail (concat ": " detail)))))
      ('waiting
       (agent-auto--settle buffer 'blocked
                           (or detail "the session is waiting on you")))
      ('in-progress nil)
      (_ (when strict
           (agent-auto--settle
            buffer 'stuck "the session stopped without a status line"))))))

(defun agent-auto--one-line (text)
  "Return TEXT on one line of at most 300 characters, or nil when empty."
  (when text
    (let ((line (string-trim (replace-regexp-in-string "[ \t\n\r]+" " " text))))
      (unless (string-empty-p line)
        (truncate-string-to-width line 300 nil nil "…")))))

(defun agent-auto--summary (text line)
  "Return the last paragraph of reply TEXT before its status LINE, on one line.
A bare \"Status: done\" says nothing of the result, and the paragraph
above it is where a reply sums up what it did."
  (when-let* ((end (string-search line text))
              (paragraphs (split-string (substring text 0 end)
                                        "\n[ \t]*\n" t "[ \t\n]+")))
    (agent-auto--one-line (car (last paragraphs)))))

(defun agent-auto--settle (buffer kind text &optional only-ready)
  "Write the result KIND with TEXT on the task of session BUFFER.
KIND, TEXT and ONLY-READY are as for `agent-auto--conclude'."
  (with-current-buffer buffer
    (setq agent-auto--settled t))
  (agent-auto--conclude (buffer-local-value 'agent-auto--link buffer)
                        kind text only-ready))

(defun agent-auto--check-dialog (buffer)
  "Mark the task of session BUFFER blocked when the session shows a dialog.
A dialog a session opens before its first turn, as the question whether
to trust a directory it has not seen, comes with no event: the brief
waits behind it and nothing reports the wait.  The screen is therefore
looked at, once a moment after the session starts and then on every
search, for as long as the session has no result.  Answering the dialog
lets the turn run, and its end writes the result as usual."
  (when (and (buffer-live-p buffer)
             (buffer-local-value 'agent-auto--link buffer)
             (not (buffer-local-value 'agent-auto--settled buffer))
             (not (buffer-local-value 'agent-auto--exiting buffer)))
    (agent-auto--guard "looking at a session's screen"
      (when (agent-auto--dialog-p buffer)
        (message "agent-auto: %s waits at a dialog that needs an answer"
                 (buffer-name buffer))
        (agent-auto--settle
         buffer 'blocked
         "the session waits at a dialog that needs an answer, such as whether to trust its directory")))))

(defun agent-auto--dialog-p (buffer)
  "Return non-nil when session BUFFER shows a dialog in place of its input box."
  (plist-get (run-hook-with-args-until-success
              'agent-session-input-state-functions buffer)
             :dialog))

(defun agent-auto--check-silence ()
  "Mark stuck the tasks whose sessions gave no sign of life for too long."
  (let ((limit (* 60 agent-auto-silence-timeout))
        (now (float-time)))
    (dolist (buffer (agent-auto--linked-buffers))
      (unless (buffer-local-value 'agent-auto--settled buffer)
        (when (> (- now (agent-auto--last-sign buffer)) limit)
          (agent-auto--settle
           buffer 'stuck
           (format "no sign of life from the session for %d minutes"
                   agent-auto-silence-timeout)
           t))))))

(defun agent-auto--last-sign (buffer)
  "Return the float time of the last sign of life of session BUFFER.
That is its last event, the latest activity derived from its transcript,
or the last status its agent published.  A session linked without an
event, as the successor of a handoff is, counts from now."
  (with-current-buffer buffer
    (max (or agent-auto--last-event
             (setq agent-auto--last-event (float-time)))
         (or (car-safe agent--session-derived-status) 0)
         (or agent--session-published-status-at 0))))

(defun agent-auto--sync-session (buffer)
  "Make the task of session BUFFER record the session as it is now.
A session is recorded by its id, and by its buffer's name until the id
is known; the session a handoff starts replaces the one it took over
from.  A session whose task is gone is unlinked."
  (let ((link (buffer-local-value 'agent-auto--link buffer))
        (value (car (agent-auto--session-values buffer))))
    (unless (equal value (agent-auto-link-recorded link))
      (pcase (agent-auto--edit-task
              link (lambda () (agent-auto--put-session buffer)))
        ('done (setf (agent-auto-link-recorded link) value))
        ('missing (with-current-buffer buffer
                    (setq agent-auto--link nil)))))))

(defun agent-auto--put-session (buffer)
  "Record on the task at point what session BUFFER is now.
That is its id, or its buffer's name until the id is known, its backend,
and its directory when that is not the task's own."
  (let* ((session (agent-session buffer))
         (directory (agent-session-directory session))
         (own (let ((inhibit-message t))
                (and agent-todo-directory-property
                     (agent-todo--property-directory)))))
    (org-entry-put nil agent-auto-session-property
                   (car (agent-auto--session-values buffer)))
    (org-entry-put nil agent-auto-backend-property
                   (symbol-name (agent-session-backend session)))
    (if (and directory
             (not (and own (file-equal-p directory own))))
        (org-entry-put nil agent-auto-directory-property
                       (abbreviate-file-name directory))
      (org-entry-delete nil agent-auto-directory-property))))

(defun agent-auto--attach-recorded (file)
  "Link each unlinked session that a task in the current buffer records.
The buffer visits FILE.  This is how a session resumed in a new buffer
finds its task again.  A session found waiting has its last reply read,
since its turn may have ended while nothing was watching."
  (dolist (buffer (agent-auto--unlinked-buffers))
    (when-let* ((value (seq-find #'agent-auto--recorded-p
                                 (agent-auto--session-values buffer))))
      (agent-auto--attach buffer (agent-auto-link-create :file file
                                                         :recorded value))
      (when (eq (agent-session-display-state buffer) 'waiting)
        (agent-auto--apply-reply buffer nil)))))

(defun agent-auto--recorded-p (value)
  "Return non-nil when a task in the current buffer records session VALUE."
  (org-with-wide-buffer (agent-auto--goto-recorded value)))

(defun agent-auto--record-delivery (context buffer)
  "Record session BUFFER on the Org task CONTEXT was made from.
For `agent-delivery-functions': a task sent to a session by hand is
recorded as one started by the timer is, so the timer starts no second
session on it, and the session's result is written on it.  The user is
at the task, so it is recorded at once, also in a buffer with unsaved
edits, which is then left unsaved."
  (when-let* ((marker (plist-get context :todo))
              (org (marker-buffer marker))
              (org (or (buffer-base-buffer org) org))
              (file (buffer-file-name org)))
    (agent-auto--guard "recording a session on its task"
      (let ((value (car (agent-auto--session-values buffer))))
        (with-current-buffer org
          (org-with-wide-buffer
           (goto-char marker)
           (org-back-to-heading t)
           (let ((clean (not (buffer-modified-p))))
             (unless (equal (org-entry-get nil agent-auto-session-property)
                            value)
               (agent-auto--record
                value (agent-session-backend (agent-session buffer)))
               (let ((inhibit-message t))
                 (agent-auto--put-session buffer)))
             (when clean
               (agent-todo--save)))))
        (unless (buffer-local-value 'agent-auto--link buffer)
          (agent-auto--attach
           buffer (agent-auto-link-create :file file :recorded value)))))))

(defun agent-auto--recorded-session ()
  "Return a context naming the session the Org task at point records, or nil.
For `agent-recorded-session-functions': acting on a task that already
has a session shows that session instead of starting another.  The
context names the session's buffer when it is live, and otherwise the
session to resume, by its id, with the backend that ran it, where it
ran, on the account the task's directory gets, under the name a session
started on the task gets, which is made from its heading.  A task that records a
session by no id, since it never got one, records nothing that can be
resumed: that is said, and nil returned, so a new session is started."
  (when-let* ((marker (agent--org-entry-marker))
              (task (agent--at-org-entry #'agent-auto--recorded-at-point)))
    (let ((recorded (plist-get task :session))
          (backend (plist-get task :backend))
          (directory (or (plist-get task :ran-in) (plist-get task :directory))))
      (cond
       ((when-let* ((buffer (agent-auto--session-buffer recorded)))
          (list :buffer buffer :todo marker)))
       ((and backend directory (agent-auto--session-id-p recorded))
        (list :resume-id recorded :backend backend :directory directory
              :account (let ((agent-inhibit-prompts t))
                         (agent-account-resolve
                          backend nil
                          (or (plist-get task :directory) directory)))
              :instance (plist-get task :instance)
              :todo marker))
       (t (message "The session this task records (%s) cannot be resumed; starting a new one"
                   recorded)
          nil)))))

(defun agent-auto--recorded-at-point ()
  "Return what the task at point records of its session, or nil.
The result is a plist of `:session', the recorded value; `:backend', a
registered backend, or nil; `:ran-in', the directory recorded for the
session when it exists, or nil; `:directory', the task's own; and
`:instance', the name a session started on the task gets."
  (when-let* ((recorded (org-entry-get nil agent-auto-session-property)))
    (let ((backend (org-entry-get nil agent-auto-backend-property))
          (ran-in (org-entry-get nil agent-auto-directory-property)))
      (list :session recorded
            :backend (and backend (agent-backend (intern backend))
                          (intern backend))
            :ran-in (and ran-in (file-directory-p ran-in)
                         (file-name-as-directory (expand-file-name ran-in)))
            :directory (let ((inhibit-message t))
                         (and agent-todo-directory-property
                              (agent-todo--property-directory)))
            :instance (agent-todo--slug
                       (plist-get (agent-todo--collect-at-point) :title))))))

(defun agent-auto--session-id-p (recorded)
  "Return non-nil when RECORDED, a task's recorded session, is a session id.
A start that never got a session leaves a placeholder, and a session
whose id the backend never reported leaves its buffer's name."
  (not (or (string-prefix-p "starting-" recorded)
           (string-prefix-p "*" recorded))))

;;;; Marks

(defun agent-auto--schedule-marks (&rest _)
  "Arrange for the marks of open sessions to be brought up to date.
The work is done once, from a timer, however often it is asked for
before then.  The arguments a hook passes are ignored."
  (unless (timerp agent-auto--marks-timer)
    (setq agent-auto--marks-timer
          (run-with-timer 0 nil #'agent-auto--run-marks))))

(defun agent-auto--run-marks ()
  "Bring the marks up to date, from the timer `agent-auto--schedule-marks' set."
  (setq agent-auto--marks-timer nil)
  (agent-auto--guard "marking tasks with an open session"
    (agent-auto--refresh-marks)))

(defun agent-auto--session-killed ()
  "Bring the marks up to date once the current buffer, a session, is killed.
For `kill-buffer-hook'."
  (when agent--session
    (agent-auto--schedule-marks)))

(defun agent-auto--mark-agenda ()
  "Mark the lines of the agenda just built whose tasks have an open session.
For `org-agenda-finalize-hook'."
  (agent-auto--guard "marking an agenda"
    (agent-auto--refresh-marks)))

(defun agent-auto--refresh-marks ()
  "Show a mark on every task whose session is open, and on no other.
The marks are overlays on the headings of the live Org buffers and on
the lines of the live agenda buffers: no file is visited, no agenda is
rebuilt, and no text is changed.  An Org buffer is searched only when a
session is open."
  (let ((open (agent-auto--open-sessions))
        (tasks (make-hash-table :test #'equal))
        agendas)
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (cond ((derived-mode-p 'org-mode)
               (agent-auto--mark-org-buffer open tasks))
              ((derived-mode-p 'org-agenda-mode)
               (push buffer agendas)))))
    (dolist (buffer agendas)
      (with-current-buffer buffer
        (agent-auto--mark-agenda-buffer tasks)))))

(defun agent-auto--open-sessions ()
  "Return a hash table from what a task can record to its open session's buffer.
A session is open while its buffer is live.  The keys are the values of
`agent-auto--session-values' and the value its task is known to record."
  (let ((open (make-hash-table :test #'equal)))
    (dolist (buffer (agent-session-buffers))
      (dolist (value (agent-auto--session-values buffer))
        (puthash value buffer open))
      (when-let* ((link (buffer-local-value 'agent-auto--link buffer)))
        (puthash (agent-auto-link-recorded link) buffer open)))
    open))

(defun agent-auto--mark-org-buffer (open tasks)
  "Mark the headings of the current Org buffer whose sessions are in OPEN.
OPEN is the table of `agent-auto--open-sessions'.  Record each such
heading in the hash table TASKS, under a cons of the buffer holding its
text and its position, with the mark it shows.  The headings are found
by searching for `agent-auto-session-property'."
  (org-with-wide-buffer
   (remove-overlays (point-min) (point-max) 'agent-auto-mark t)
   (unless (hash-table-empty-p open)
     (goto-char (point-min))
     (let ((regexp (format "^[ \t]*:%s:[ \t]+\\(.*?\\)[ \t]*$"
                           agent-auto-session-property))
           (base (or (buffer-base-buffer) (current-buffer)))
           (case-fold-search nil))
       (while (re-search-forward regexp nil t)
         (when-let* ((session (gethash (match-string-no-properties 1) open))
                     (mark (agent-auto--mark session))
                     ((save-match-data (ignore-errors (org-back-to-heading t)))))
           (puthash (cons base (point)) mark tasks)
           (agent-auto--mark-heading mark)
           (outline-next-heading)))))))

(defun agent-auto--mark (session)
  "Return the mark of the open session in buffer SESSION, or nil for none.
It is `agent-auto-waiting-mark' for a session waiting for input and
`agent-auto-working-mark' for any other, in the face of its state, with
a `help-echo' naming the session and the state."
  (let* ((state (agent-session-display-state session))
         (waiting (memq state '(waiting background-waiting)))
         (mark (if waiting agent-auto-waiting-mark agent-auto-working-mark)))
    (unless (member mark '(nil ""))
      (propertize
       mark
       'face (agent--session-state-face state)
       'help-echo (format "Session %s: %s" (buffer-name session)
                          (pcase state
                            ('waiting "waiting for input")
                            ('background-waiting
                             "waiting for input, with background work")
                            ('busy "working")
                            (_ "state not known yet")))))))

(defun agent-auto--mark-heading (mark)
  "Show MARK on the heading at point: after its TODO keyword, or before its text."
  (let ((case-fold-search nil))
    (when (looking-at org-complex-heading-regexp)
      (if (match-beginning 2)
          (agent-auto--put-mark (match-beginning 2) (match-end 2)
                                'after-string (concat " " mark))
        (let ((start (min (1+ (match-end 1)) (line-end-position))))
          (agent-auto--put-mark start (min (1+ start) (line-end-position))
                                'before-string (concat mark " ")))))))

(defun agent-auto--put-mark (start end property string)
  "Show STRING at the text from START to END, as the overlay PROPERTY.
PROPERTY is `before-string' or `after-string'.  The overlay goes when
its text does."
  (let ((overlay (make-overlay start end nil t)))
    (overlay-put overlay 'agent-auto-mark t)
    (overlay-put overlay property string)
    (overlay-put overlay 'evaporate t)))

(defun agent-auto--mark-agenda-buffer (tasks)
  "Mark the lines of the current agenda buffer whose tasks are in TASKS.
TASKS is the table `agent-auto--mark-org-buffer' fills.  The mark goes
just before the task's title."
  (save-excursion
    (save-restriction
      (widen)
      (remove-overlays (point-min) (point-max) 'agent-auto-mark t)
      (unless (hash-table-empty-p tasks)
        (goto-char (point-min))
        (while (not (eobp))
          (when-let* ((marker (get-text-property (point) 'org-hd-marker))
                      (buffer (marker-buffer marker))
                      (mark (gethash (cons buffer (marker-position marker))
                                     tasks))
                      (start (agent-auto--agenda-title-start))
                      ((< start (line-end-position))))
            (agent-auto--put-mark start (1+ start)
                                  'before-string (concat mark " ")))
          (forward-line 1))))))

(defun agent-auto--agenda-title-start ()
  "Return where the title of the task on the current agenda line starts.
That is after the line's prefix, the task's TODO keyword and its
priority cookie.  The agenda marks where the heading's text starts with
the text property `org-heading'."
  (save-excursion
    (let ((end (line-end-position))
          (keyword (get-text-property (point) 'todo-state))
          (case-fold-search nil))
      (goto-char (or (text-property-any (point) end 'org-heading t)
                     (progn (back-to-indentation) (point))))
      (when (and keyword
                 (looking-at (concat "\\.*" (regexp-quote keyword) "[ \t]+")))
        (goto-char (match-end 0)))
      (when (looking-at "\\[#[A-Z0-9]+\\][ \t]+")
        (goto-char (match-end 0)))
      (min (point) end))))

(defun agent-auto--remove-marks ()
  "Remove every mark, from the Org buffers and the agenda buffers."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (derived-mode-p '(org-mode org-agenda-mode))
        (save-restriction
          (widen)
          (remove-overlays (point-min) (point-max) 'agent-auto-mark t))))))

;;;; Results

(defun agent-auto--conclude (link kind text &optional only-ready)
  "Write the result KIND with TEXT on the task of LINK.
KIND is `review', `blocked' or `stuck'.  With ONLY-READY non-nil the
result is written only on a task that still carries the ready tag;
otherwise on any task `agent-auto--write-result' does not leave alone.
A result that cannot be written yet, because the task's buffer has
unsaved edits, is kept and written once the buffer is saved; it replaces
an earlier one still waiting for the same task."
  (setq agent-auto--pending
        (append (seq-remove (lambda (entry) (eq (car entry) link))
                            agent-auto--pending)
                (list (list link kind text only-ready))))
  (agent-auto--flush-pending))

(defun agent-auto--flush-pending ()
  "Write the results that can now be written."
  (setq agent-auto--pending
        (seq-filter (pcase-lambda (`(,link ,kind ,text ,only-ready))
                      (eq (agent-auto--edit-task
                           link (lambda ()
                                  (agent-auto--write-result
                                   kind text only-ready)))
                          'deferred))
                    agent-auto--pending)))

(defun agent-auto--write-result (kind text only-ready)
  "Give the task at point the tag of result KIND and the result TEXT.
The task is the one that records the session, whether the timer started
it or the user did.  The tag replaces whichever of the ready and result
tags the task carries, and a task that carries none of them and has no
result yet, as one sent to a session by hand, gets it too.  A task that
has a result and none of the tags is left alone, so a tag the user
removed is never added back, and so is a task that is closed.  With
ONLY-READY non-nil the task must carry the ready tag."
  (let ((tags (org-get-tags nil t))
        (lifecycle (list agent-auto-ready-tag agent-auto-review-tag
                         agent-auto-blocked-tag agent-auto-stuck-tag)))
    (when (and (org-entry-is-todo-p)
               (if only-ready
                   (member agent-auto-ready-tag tags)
                 (or (seq-intersection tags lifecycle)
                     (not (org-entry-get nil agent-auto-result-property)))))
      (let ((new (append (seq-difference tags lifecycle)
                         (list (agent-auto--tag kind)))))
        (unless (equal new tags)
          (org-set-tags new)))
      (unless (equal (org-entry-get nil agent-auto-result-property) text)
        (org-entry-put nil agent-auto-result-property text))
      (agent-auto--log "%s: %s" (agent-auto--tag kind) text))))

(defun agent-auto--tag (kind)
  "Return the Org tag of result KIND."
  (pcase kind
    ('review agent-auto-review-tag)
    ('blocked agent-auto-blocked-tag)
    ('stuck agent-auto-stuck-tag)))

;;;; Editing tasks

(defun agent-auto--edit-task (link function)
  "Call FUNCTION with point on the heading of the task of LINK.
Return `done' after the call, when the buffer is saved if FUNCTION
changed it; `deferred' when the task's buffer has unsaved edits, and is
therefore left alone; and `missing' when the file or the task is gone.
The edit is made in the buffer visiting the file, widened, without
moving point or touching a window."
  (let ((buffer (agent-auto--editable-buffer (agent-auto-link-file link))))
    (cond
     ((eq buffer 'gone) 'missing)
     ((null buffer) 'deferred)
     (t (with-current-buffer buffer
          (org-with-wide-buffer
           (if (not (agent-auto--goto-recorded (agent-auto-link-recorded link)))
               'missing
             (let ((inhibit-message t))
               (funcall function))
             (agent-todo--save)
             'done)))))))

(defun agent-auto--goto-recorded (value)
  "Move to the heading of the task recording session VALUE.
Return non-nil when there is one in the current buffer."
  (goto-char (point-min))
  (let ((case-fold-search nil))
    (and (re-search-forward
          (format "^[ \t]*:%s:[ \t]+%s[ \t]*$"
                  agent-auto-session-property (regexp-quote value))
          nil t)
         (ignore-errors (org-back-to-heading t)))))

(defun agent-auto--editable-buffer (file)
  "Return the buffer visiting FILE when it may be edited.
Return nil when it has unsaved edits or is read-only, and the symbol
`gone' when FILE does not exist or is no Org file.  A buffer whose file
changed on disk is reverted first, since it has no edits to lose."
  (let ((buffer (agent-auto--org-buffer file)))
    (cond
     ((null buffer) 'gone)
     ((with-current-buffer buffer (or (buffer-modified-p) buffer-read-only))
      nil)
     (t (unless (verify-visited-file-modtime buffer)
          (with-current-buffer buffer
            (let ((inhibit-message t))
              (revert-buffer t t t))))
        buffer))))

(defun agent-auto--org-buffer (file)
  "Return the Org buffer visiting FILE, visiting it if need be, or nil.
Nothing is asked: a file is visited without the warning for a large one,
and without the question about file-local variables."
  (when (file-regular-p file)
    (let ((buffer (or (find-buffer-visiting file)
                      (let ((large-file-warning-threshold nil)
                            (enable-local-variables
                             (if (eq enable-local-variables t)
                                 :safe
                               enable-local-variables))
                            (inhibit-message t))
                        (find-file-noselect file t)))))
      (and (with-current-buffer buffer (derived-mode-p 'org-mode))
           buffer))))

(provide 'agent-auto)
;;; agent-auto.el ends here
