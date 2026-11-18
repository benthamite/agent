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
;; A session that is closed with `agent-exit' while its task is open is
;; first asked for a handover: a few lines on where the task stands,
;; which it writes to a file as JSON.  They become a dated note in the
;; task's log, its one-line result and its tag.  Each close has a
;; receipt on disk, kept until it is written on the task, so a handover
;; survives a task whose buffer has unsaved edits and a restart of Emacs.
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
Nil means the one `agent-todo-backend' names, else the only registered
backend; with several registered, no session is started until one of
the two options names one of them, such as `claude-code'."
  :type '(choice (const :tag "As for a TODO started by hand" nil) symbol)
  :group 'agent-auto)

(defcustom agent-auto-handover-prompt
  "This session is being closed, and it is linked to a task.  Before it \
closes, write a handover receipt for that task: one JSON object, in the file \
%f and nowhere else.  Its fields, every value a string: `state', which is \
`finished' when the task's work is done, `needs-pablo' when it cannot go on \
without a decision or input from the user, `waiting-on-someone' when it \
waits for another person's reply or action, and `interrupted' when the work \
stopped part-way for any other reason; `summary', what was done, in a \
sentence or two; `next', the next step; for `needs-pablo' also `question', \
the question to answer; and for `waiting-on-someone' also `who', the person \
waited for, `what', what is awaited from them, and `wait', the id of the \
wait you registered for their reply, exactly as the tool printed it, or an \
empty string when you registered none.  Say what happened in your own words: \
never quote or paste a message, an email or any other private material, and \
name no secret.  Apart from the receipt, and from registering a wait when \
these instructions say how, do nothing in this turn: do not go on with the \
task, and do not send a message to anyone."
  "The prompt asking a session that is being closed for its handover.
`agent-exit' submits it, as the first step of its before-exit chain, to
a session linked to an open task.  %f is replaced by the name of the
file the session is to write, and %% by a percent sign.  The file must
hold one JSON object with the field `state', one of `finished',
`needs-pablo', `waiting-on-someone' and `interrupted', and may hold
`summary', `next', `question', `who', `what' and `wait'; the prompt has
to say so, since nothing else tells the session.
`agent-auto-wait-instructions', when not empty, follows it as a
paragraph of its own."
  :type 'string
  :group 'agent-auto)

(defcustom agent-auto-wait-instructions ""
  "How a session registers a wait for someone's reply, for its handover.
The text is added to `agent-auto-handover-prompt' as its last paragraph,
so that a session that closes waiting on someone registers the wait
first and names it in the `wait' field of its handover.  Empty, the
default, adds nothing."
  :type 'string
  :group 'agent-auto)

(defcustom agent-auto-waiting-keyword "WAITING"
  "Org TODO keyword of a task whose session closed waiting on someone.
A handover whose state is `waiting-on-someone' moves its task to this
keyword, and records the keyword the task had, so that it can go back to
it; see `agent-auto-keyword-property'.  No other state changes a task's
keyword.  A task in a file whose keywords do not include it keeps its
keyword.  Nil leaves the keyword of every task alone."
  :type '(choice (const :tag "Leave the keyword alone" nil)
                 (string :tag "Keyword"))
  :group 'agent-auto)

(defcustom agent-auto-wait-over-functions nil
  "Abnormal hook telling whether a wait a task records is over.
Each function is called with one argument, the wait a task records in
`agent-auto-wait-property': the string its session's handover gave as
`wait', which is whatever `agent-auto-wait-instructions' had the session
register.  A non-nil value means the wait is over, whichever session
heard of it: the task then goes back to the keyword it had before it
was moved to `agent-auto-waiting-keyword', and a note in its log says
that the wait is over.  The hook is run on every search of
`agent-auto-mode', for each task that records a wait, so its functions
must be quick and must not wait for anything; one that signals an error
counts as answering nil.  With no function, tasks are not looked at."
  :type 'hook
  :group 'agent-auto)

(defcustom agent-auto-handover-directory
  (expand-file-name "agent/handovers/" user-emacs-directory)
  "Directory holding the handover receipts not yet written on their tasks.
Each close of a session linked to an open task leaves one file here,
which is deleted once it has been written on the task."
  :type 'directory
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

(defconst agent-auto-handover-property "AGENT_HANDOVER"
  "Org property holding the id of the last handover written on a task.
A receipt whose id it holds has been written, and is not written again.")

(defconst agent-auto-keyword-property "AGENT_KEYWORD"
  "Org property recording the keyword a task had before it was set waiting.
A handover that moves a task to `agent-auto-waiting-keyword' records it,
and it goes when the task goes back to that keyword.")

(defconst agent-auto-wait-property "AGENT_WAIT"
  "Org property recording the wait a task's session registered.
It holds the `wait' field of the session's handover; see
`agent-auto-wait-over-functions'.")

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

(defvar-local agent-auto--handover-answer nil
  "The file this session was asked to write its handover to, or nil.")

(defvar-local agent-auto--handed-over nil
  "The state of the handover this session's close has left, or nil.
It is nil again once the session works on: a later close needs a
handover of its own.")

(defvar-local agent-auto--back nil
  "Non-nil once this session's task was told that the session works again.
A task that waits on someone goes back to its keyword when a turn starts
in its session; the task is looked at for the first such turn only.")

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

(defvar-local agent-auto--marked-tick nil
  "The `buffer-chars-modified-tick' of this agenda when it was last marked.
More exactly, when its marks were last brought up to date or asked for.
Nil in an agenda that was never marked, or was built again since.")

(defvar agent-auto--processes nil
  "The subprocesses now running.")

(defvar agent-auto--starting nil
  "The starts in flight, each a cons of a link and the checkout it holds.")

(defvar agent-auto--pending nil
  "Results not yet written, each a list of a link, a kind, a text and a flag.
See `agent-auto--conclude'.")

(defvar agent-auto--handovers nil
  "The handover receipts not yet written on their tasks, the oldest first.
Each is a plist, as `agent-auto--record-handover' makes it, and has a
file of its own under `agent-auto-handover-directory'.")

(defvar agent-auto--returning nil
  "The links of the tasks to take out of waiting, their sessions working again.
See `agent-auto--return'.")

(defvar agent-auto--last-handover-id nil
  "The id of the receipt made last, so that the next one sorts after it.")

(defvar agent-auto--flush-timer nil
  "Timer running `agent-auto--run-flush', or nil when none is pending.")

(defvar agent-auto--approved nil
  "The link the user has just agreed to, though it replaces another, or nil.
It is a cons of the marker of the task and the session's buffer, set by
`agent-auto--confirm-delivery' and used up by
`agent-auto--record-delivery'.")

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
agenda show `agent-auto-working-mark' or `agent-auto-waiting-mark'.

A session that `agent-exit' closes while its task is open is first asked
for a handover, with `agent-auto-handover-prompt', which becomes a dated
note in the task's log, its result and its tag."
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
  (agent-auto--install))

(defconst agent-auto--hooks
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
  "The hooks of the mode, each a cons of a hook and the function it gets.
The functions go on the global value of each hook.  An agenda is marked
from three of them, since no one of them sees every change of its text:
see `agent-auto--mark-agenda' and `agent-auto--check-agenda'.")

(defconst agent-auto--inherited-variables
  '(agent-auto--link agent-auto--unattended)
  "The variables of a session that the session replacing it takes over.
See `agent-session-inherited-variables'.")

(defun agent-auto--install ()
  "Install everything the mode needs while it is on, each thing once.
That is its hooks, the variables its sessions pass on, the handover
receipts left on disk, which are then written from a timer of their own,
and its timer, which replaces any timer already running the search.
Calling this again changes nothing but the timers, so the end of this
file calls it when the file is loaded while the mode is on: an Emacs
that turned the mode on with an older version of the file then has what
this version installs, without the mode being toggled."
  (dolist (variable agent-auto--inherited-variables)
    (add-to-list 'agent-session-inherited-variables variable))
  (pcase-dolist (`(,hook . ,function) agent-auto--hooks)
    (add-hook hook function))
  (agent-auto--schedule-marks)
  (agent-auto--guard "reading the handover receipts"
    (agent-auto--load-handovers))
  (cancel-function-timers #'agent-auto--run-flush)
  (when (or agent-auto--handovers agent-auto--pending agent-auto--returning)
    (agent-auto--schedule-flush))
  (cancel-function-timers #'agent-auto--tick)
  (setq agent-auto--timer
        (run-with-timer agent-auto-interval agent-auto-interval
                        #'agent-auto--tick)))

(defun agent-auto--disable ()
  "Stop watching sessions."
  (setq agent-session-inherited-variables
        (seq-difference agent-session-inherited-variables
                        agent-auto--inherited-variables))
  (pcase-dolist (`(,hook . ,function) agent-auto--hooks)
    (remove-hook hook function))
  (agent-auto--remove-marks))

(defun agent-auto--reset ()
  "Cancel the timers and subprocesses and forget the steps waiting.
Results and handovers not yet written are kept."
  (dolist (timer (list agent-auto--timer agent-auto--queue-timer
                       agent-auto--marks-timer agent-auto--flush-timer))
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
        agent-auto--flush-timer nil
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
    (agent-auto--flush))
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
  "Search the files for ready tasks, recorded sessions and recorded waits.
Waits are searched for only while `agent-auto-wait-over-functions' has a
function to ask.  Each file ripgrep finds is then visited in a step of
its own.  Nothing is searched while the steps of the search before are
still running."
  (unless (or agent-auto--queue agent-auto--processes)
    (when-let* ((files (agent-auto--files)))
      (agent-auto--call
       "rg"
       (append '("--files-with-matches" "--null" "--fixed-strings"
                 "--no-messages")
               (mapcan (lambda (pattern) (list "-e" pattern))
                       (append
                        (list (format ":%s:" agent-auto-ready-tag))
                        (and agent-auto-wait-over-functions
                             (list (format ":%s:" agent-auto-wait-property)))
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
The tasks whose wait is over leave the waiting keyword.  A file whose
buffer has unsaved edits is left for a later search."
  (when-let* ((buffer (agent-auto--org-buffer file)))
    (with-current-buffer buffer
      (agent-auto--attach-recorded file))
    (when (eq (agent-auto--editable-buffer file) buffer)
      (with-current-buffer buffer
        (agent-auto--check-waits))
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
  "Return the backend to start sessions with, or signal an error.
It is the one `agent-auto-backend' names, else the one
`agent-todo-backend' names, else the only registered backend."
  (let ((option (cond (agent-auto-backend 'agent-auto-backend)
                      (agent-todo-backend 'agent-todo-backend))))
    (cond (option
           (if (agent-backend (symbol-value option))
               (symbol-value option)
             (error "`%s' names `%s', which is not registered"
                    option (symbol-value option))))
          ((= (length agent-backends) 1) (caar agent-backends))
          (t (error "Set `agent-auto-backend' or `agent-todo-backend': %s"
                    (if agent-backends
                        "several backends are registered"
                      "no backend is registered"))))))

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
          agent-auto--exiting nil
          agent-auto--handed-over nil
          agent-auto--back nil))
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
           (unless (agent-auto--chain-turn-p buffer)
             (run-with-timer agent-auto--turn-end-delay nil
                             #'agent-auto--turn-end buffer
                             agent-auto--turn-end-retries)))
          ('blocked
           (unless (agent-auto--chain-turn-p buffer)
             (agent-auto--settle
              buffer 'blocked
              "the session waits at a permission or input prompt, or was interrupted")))
          ('exit-request (setq agent-auto--exiting t))
          ('user-submit (setq agent-auto--exiting nil
                              agent-auto--settled nil)
                        (agent-auto--turn-started buffer))
          ((or 'submit 'activity)
           (setq agent-auto--settled nil)
           (unless (agent-auto--chain-turn-p buffer)
             (agent-auto--turn-started buffer))))))))

(defun agent-auto--turn-started (buffer)
  "Note that a turn of the user's started in session BUFFER.
That is any turn but those of the session's exit; see
`agent-auto--chain-turn-p'.  A handover the session left when its exit
was asked for no longer closes it: the exit was abandoned, and a later
one asks for a handover again.  A task that waits on someone leaves the
waiting keyword, the work on it being resumed, and a receipt not yet
written on the task no longer sets it waiting."
  (with-current-buffer buffer
    (setq agent-auto--handed-over nil))
  (when-let* ((link (buffer-local-value 'agent-auto--link buffer)))
    (agent-auto--mark-resumed link)
    (unless (buffer-local-value 'agent-auto--back buffer)
      (with-current-buffer buffer
        (setq agent-auto--back t))
      (agent-auto--return link))))

(defun agent-auto--chain-turn-p (buffer)
  "Return non-nil when the turn of session BUFFER belongs to its exit.
That is a turn the before-exit chain submitted, as one of its skills,
and any turn of a session whose exit has been requested.  Nothing of
such a turn is written on the task: not how it ends, and not a prompt
or a dialog it waits at.  The turn that was running when `agent-exit'
was called is the user's: the chain waits for it, and its end is the
task's result."
  (or (buffer-local-value 'agent-auto--exiting buffer)
      (memq (plist-get (buffer-local-value 'agent--before-exit buffer) :state)
            '(running closing))))

(defun agent-auto--on-id (buffer)
  "Record the new id of session BUFFER on its task.
For `agent-session-id-functions'."
  (when (buffer-local-value 'agent-auto--link buffer)
    (agent-auto--guard "recording a session id"
      (agent-auto--sync-session buffer))))

(defun agent-auto--turn-end (buffer &optional retries)
  "Write on its task how the turn of session BUFFER ended.
A session being exited is left alone: the turns of its exit are not the
task's result, and those its before-exit chain submits are not even
looked at; see `agent-auto--chain-turn-p'.  So is a session whose close
has left a handover, which replaces the result.  With RETRIES, a
positive number, a session whose reply cannot be read yet is looked at
again after `agent-auto--turn-end-delay', that many times at most,
before it counts as stopped without a status line, which leaves the task
stuck only when the timer started the session; see
`agent-auto--unattended'."
  (when (and (buffer-live-p buffer)
             (buffer-local-value 'agent-auto--link buffer)
             (not (buffer-local-value 'agent-auto--exiting buffer))
             (member (buffer-local-value 'agent-auto--handed-over buffer)
                     '(nil "none")))
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
             (not (agent-auto--chain-turn-p buffer)))
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
from.  A session whose task is gone is unlinked.  The record is brought
up to date also in a buffer with unsaved edits, which is left unsaved:
it is there already, and an id that waited for the buffer to be saved
was lost when the session ended first, leaving a task whose session
nothing could resume."
  (let ((link (buffer-local-value 'agent-auto--link buffer))
        (value (car (agent-auto--session-values buffer))))
    (unless (equal value (agent-auto-link-recorded link))
      (pcase (agent-auto--edit-task
              link (lambda () (agent-auto--put-session buffer)) t)
        ('done (agent-auto--retarget-handovers
                (agent-auto-link-file link) (agent-auto-link-recorded link)
                value)
               (setf (agent-auto-link-recorded link) value))
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
edits, which is then left unsaved.

One session works on one task.  A session linked to another task is
recorded here only when the user agreed to it, which
`agent-auto--confirm-delivery' asked before the task was sent; without
that, both tasks are left as they are.  A session the task recorded
before is replaced unasked: it was a new session that was asked for."
  (when-let* ((marker (plist-get context :todo))
              ((agent-auto--task-file marker)))
    (agent-auto--guard "recording a session on its task"
      (let ((approved (and (eq (car agent-auto--approved) marker)
                           (eq (cdr agent-auto--approved) buffer))))
        (setq agent-auto--approved nil)
        (when (or approved
                  (not (plist-get (agent-auto--link-conflicts marker buffer)
                                  :task)))
          (agent-auto--link-task marker buffer))))))

(defun agent-auto--confirm-delivery (context buffer)
  "Ask before the Org task CONTEXT was made from and session BUFFER are linked.
For `agent-before-delivery-functions'.  Nothing is asked unless the link
would replace another; see `agent-auto--confirm-link'.  Return nil when
the user declines, so that the task is not sent."
  (let ((marker (plist-get context :todo)))
    (or (not (and marker (agent-auto--task-file marker)))
        (not (agent-auto--link-conflicts marker buffer))
        (and (agent-auto--confirm-link marker buffer)
             (setq agent-auto--approved (cons marker buffer))))))

(defun agent-auto--recorded-session ()
  "Return a context naming the session the Org task at point records, or nil.
For `agent-recorded-session-functions': acting on a task that already
has a session shows that session instead of starting another.  The
context names the session's buffer when it is live, and otherwise the
session to resume, by its id, with the backend that ran it, where it
ran, on the account the task's directory gets, under the name a session
started on the task gets, which is made from its heading.  A task that
records a session by no id, since it never got one, records nothing that
can be resumed: the context says so with `:lost', and the user is asked
before a new session is started.  Nothing is asked or said here, so the
hook can be run to learn what a task records."
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
       (t (list :lost recorded :todo marker))))))

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

;;;; One session, one task

(defun agent-auto--at-task (marker function)
  "Call FUNCTION with point on the heading of the task at MARKER.
MARKER is in an Org buffer, which can be an indirect one; the call is
made in the buffer that visits the file, widened, and its value is
returned."
  (let ((org (marker-buffer marker)))
    (with-current-buffer (or (buffer-base-buffer org) org)
      (org-with-wide-buffer
       (goto-char marker)
       (org-back-to-heading t)
       (funcall function)))))

(defun agent-auto--task-file (marker)
  "Return the file of the task at MARKER, or nil when it is in none."
  (when-let* ((org (marker-buffer marker)))
    (buffer-file-name (or (buffer-base-buffer org) org))))

(defun agent-auto--link-conflicts (marker buffer)
  "Return what linking session BUFFER to the task at MARKER would replace.
The result is a plist: `:session' is the session the task records, when
it records another than BUFFER's; `:task' is the title of the task
BUFFER is linked to, when that is another task and it is still there.
Nil when the link replaces nothing."
  (let* ((link (buffer-local-value 'agent-auto--link buffer))
         (recorded (agent-auto--at-task
                    marker
                    (lambda () (org-entry-get nil agent-auto-session-property))))
         (own (and link (agent-auto--link-of-task-p link marker))))
    (append
     (and recorded
          (not own)
          (not (member recorded (agent-auto--session-values buffer)))
          (list :session recorded))
     (when-let* (((and link (not own)))
                 (title (agent-auto--link-title link)))
       (list :task title)))))

(defun agent-auto--link-of-task-p (link marker)
  "Return non-nil when LINK is the link of the task at MARKER."
  (and (agent-auto--same-file-p (agent-auto-link-file link)
                                (agent-auto--task-file marker))
       (equal (agent-auto-link-recorded link)
              (agent-auto--at-task
               marker
               (lambda () (org-entry-get nil agent-auto-session-property))))))

(defun agent-auto--link-title (link)
  "Return the title of the task of LINK, or nil when the task is gone."
  (when-let* ((org (agent-auto--org-buffer (agent-auto-link-file link))))
    (with-current-buffer org
      (org-with-wide-buffer
       (and (agent-auto--goto-recorded (agent-auto-link-recorded link))
            (substring-no-properties (org-get-heading t t t t)))))))

(defun agent-auto--confirm-link (marker buffer)
  "Return non-nil when session BUFFER may be linked to the task at MARKER.
It may when the link replaces nothing.  When the task records another
session, or BUFFER is linked to another task, the user is asked about
each, and declining either leaves everything as it is.  Where nothing
may be asked, a link that would replace another is refused; see
`agent-inhibit-prompts'."
  (let* ((conflicts (agent-auto--link-conflicts marker buffer))
         (session (plist-get conflicts :session))
         (task (plist-get conflicts :task))
         (name (agent-display-name buffer)))
    (cond
     ((null conflicts) t)
     (agent-inhibit-prompts
      (message "agent-auto: linking %s would replace another link; not done"
               name)
      nil)
     (t (and (or (null session)
                 (y-or-n-p (format "This task records another session (%s).  Replace it with %s? "
                                   session name)))
             (or (null task)
                 (y-or-n-p (format "%s is linked to the task “%s”.  Link it to this task instead? "
                                   name task))))))))

(defun agent-auto--link-task (marker buffer)
  "Record session BUFFER on the task at MARKER and link the two.
The task records the session as one started from it does, and nothing
is sent to the session.  Whatever the link replaces goes first: the task
BUFFER was linked to stops recording it, and the session the task
recorded is no longer linked to it; see `agent-auto--release-task' and
`agent-auto--replace-recorded'.  The user is at the task, so all of it
is written at once, also in a buffer with unsaved edits, which is then
left unsaved."
  (let ((link (buffer-local-value 'agent-auto--link buffer))
        (file (agent-auto--task-file marker))
        (value (car (agent-auto--session-values buffer))))
    (when (and link (not (agent-auto--link-of-task-p link marker)))
      (agent-auto--release-task link buffer)
      (setq link nil))
    (agent-auto--at-task
     marker
     (lambda ()
       (let ((clean (not (buffer-modified-p)))
             (recorded (org-entry-get nil agent-auto-session-property))
             (inhibit-message t))
         (unless (equal recorded value)
           (when (and recorded
                      (not (member recorded
                                   (agent-auto--session-values buffer))))
             (agent-auto--replace-recorded file recorded value))
           (agent-auto--record
            value (agent-session-backend (agent-session buffer)))
           (agent-auto--put-session buffer))
         (when clean
           (agent-todo--save)))))
    (if link
        (setf (agent-auto-link-recorded link) value)
      (agent-auto--attach
       buffer (agent-auto-link-create :file file :recorded value)))))

(defun agent-auto--release-task (link buffer)
  "Make the task of LINK stop recording session BUFFER, which leaves it.
A note in the task's log names the session, so that it can still be
found.  The ready tag goes with the record: a task that carries it and
records no session would be started again.  BUFFER is linked to no task
afterwards."
  (agent-auto--edit-task
   link
   (lambda ()
     (agent-auto--add-note
      (list (format "Session %s is no longer linked to this task: it was linked to another."
                    (agent-auto--recorded-name
                     (agent-auto-link-recorded link)))))
     (dolist (property (list agent-auto-session-property
                             agent-auto-backend-property
                             agent-auto-directory-property))
       (org-entry-delete nil property))
     (let ((tags (org-get-tags nil t)))
       (when (member agent-auto-ready-tag tags)
         (org-set-tags (remove agent-auto-ready-tag tags)))))
   t)
  (with-current-buffer buffer
    (setq agent-auto--link nil)))

(defun agent-auto--replace-recorded (file recorded value)
  "Note on the task at point that it no longer records session RECORDED.
The task is in FILE and is about to record the session VALUE instead.  A
note in its log names the session it recorded, unless that was only the
placeholder of a start; a live session that was linked to the task is
linked to none; and the receipts waiting for the task find it as VALUE."
  (when (agent-auto--session-id-p recorded)
    (agent-auto--add-note
     (list (format "Session %s is no longer linked to this task: another took its place."
                   (agent-auto--recorded-name recorded)))))
  (dolist (buffer (agent-auto--linked-buffers))
    (let ((link (buffer-local-value 'agent-auto--link buffer)))
      (when (and (equal (agent-auto-link-recorded link) recorded)
                 (agent-auto--same-file-p (agent-auto-link-file link) file))
        (with-current-buffer buffer
          (setq agent-auto--link nil)))))
  (agent-auto--retarget-handovers file recorded value))

(defun agent-auto--recorded-name (recorded)
  "Return a name for the session the task at point records as RECORDED.
It is the recorded value, with the backend that ran the session and the
directory it ran in when the task records them, which is what resuming
the session takes."
  (let ((details (delq nil
                       (list (org-entry-get nil agent-auto-backend-property)
                             (org-entry-get nil
                                            agent-auto-directory-property)))))
    (if details
        (format "%s (%s)" recorded (string-join details ", "))
      recorded)))

;;;; Linking by hand

;;;###autoload
(defun agent-link-session (&optional send)
  "Link a running session and an Org task, sending the session nothing.
On an Org heading or on a line of an agenda, choose a running session
by completion, those in the task's directory first.  In a session's
buffer, choose a task by completion among the open TODOs of
`agent-auto-files', those whose directory is the session's first.

The task then records the session exactly as a task a session was
started from does: its heading shows the session's mark, acting on it
goes to the session, the session's results and its handover are written
on it, and the timer starts no session on it.  One session works on one
task, so a link that would replace another is asked about first, and
declining changes nothing; see `agent-auto--confirm-link'.

With prefix argument SEND, also send the session the task's text, as
`agent-send-todo-at-point' with a prefix argument does."
  (interactive "P")
  (unless agent-auto-mode
    (user-error "Turn `agent-auto-mode' on first"))
  (let* ((from-session (and (agent-session) (current-buffer)))
         (marker (if from-session
                     (agent-auto--read-task from-session)
                   (agent-auto--task-at-point)))
         (buffer (or from-session (agent-auto--read-session marker))))
    (cond
     (send (agent-auto--send-task marker buffer (and from-session t)))
     ((agent-auto--confirm-link marker buffer)
      (agent-auto--link-task marker buffer)
      (message "Linked %s to the task “%s”"
               (agent-display-name buffer)
               (agent-auto--at-task
                marker (lambda () (org-get-heading t t t t)))))
     (t (message "Nothing was linked")))))

(defun agent-auto--task-at-point ()
  "Return a marker at the open Org task at point, or signal a `user-error'.
The task is the heading at point in an Org buffer, or the one the line
at point shows in an agenda.  It must be a TODO that is not closed, in a
buffer that visits a file."
  (let ((marker (or (agent--org-entry-marker)
                    (user-error "Call this on an Org task, on an agenda line or in a session"))))
    (unless (agent--at-org-entry #'org-get-todo-state)
      (user-error "Point is not on a TODO heading"))
    (when (agent--at-org-entry #'org-entry-is-done-p)
      (user-error "This task is closed"))
    (unless (agent-auto--task-file marker)
      (user-error "This task's buffer visits no file"))
    marker))

(defun agent-auto--read-session (marker)
  "Read a running session to link to the task at MARKER; return its buffer.
The sessions that run in the task's directory come first."
  (let* ((buffers (or (agent-session-buffers)
                      (user-error "No session is running")))
         (directory (agent-auto--at-task marker #'agent-auto--task-directory))
         (same-p (agent-auto--same-directory-p directory))
         (candidates
          (agent-auto--label
           (agent-auto--first
            (lambda (buffer)
              (when-let* ((session (agent-session buffer)))
                (funcall same-p (agent-session-directory session))))
            buffers)
           #'agent--session-candidate-label)))
    (agent-auto--choose "Link the session: " candidates)))

(defun agent-auto--read-task (buffer)
  "Read an open task to link session BUFFER to; return a marker at it.
The tasks are the open TODOs of `agent-auto-files', those whose
directory is the session's first."
  (let* ((same-p (agent-auto--same-directory-p
                  (agent-session-directory (agent-session buffer))))
         (tasks (or (agent-auto--open-tasks)
                    (user-error "No open task in `agent-auto-files'")))
         (candidates
          (agent-auto--label
           (agent-auto--first
            (lambda (task) (funcall same-p (plist-get task :directory)))
            tasks)
           (lambda (task)
             (format "%s  (%s)" (plist-get task :title)
                     (file-name-nondirectory (plist-get task :file))))))
         (task (agent-auto--choose
                (format "Link %s to the task: " (agent-display-name buffer))
                candidates)))
    (with-current-buffer (plist-get task :buffer)
      (copy-marker (plist-get task :position)))))

(defun agent-auto--open-tasks ()
  "Return the open TODOs of `agent-auto-files', in the order of the files.
Each is a plist of `:title', `:file', `:buffer', the buffer visiting the
file, `:position', where the heading starts, and `:directory', the
directory `agent-todo-directory-property' names for the task, or nil."
  (mapcan
   (lambda (file)
     (when-let* ((org (agent-auto--org-buffer file)))
       (with-current-buffer org
         (org-with-wide-buffer
          (goto-char (point-min))
          (let ((case-fold-search nil)
                tasks)
            (while (re-search-forward org-not-done-heading-regexp nil t)
              (save-excursion
                (goto-char (match-beginning 0))
                (push (list :title (substring-no-properties
                                    (org-get-heading t t t t))
                            :file file
                            :buffer org
                            :position (point)
                            :directory (agent-auto--task-directory))
                      tasks)))
            (nreverse tasks))))))
   (agent-auto--files)))

(defun agent-auto--task-directory ()
  "Return the directory the task at point names, or nil when it names none.
The directory is the one `agent-todo-directory-property' names, on the
task's own heading or inherited.  Nothing is said of a directory that
does not exist, since this is asked of many tasks to put them in order."
  (when-let* ((agent-todo-directory-property)
              (name (org-entry-get nil agent-todo-directory-property t))
              ((not (member name '("" "nil")))))
    (file-name-as-directory (expand-file-name name))))

(defun agent-auto--same-directory-p (directory)
  "Return a function telling whether a directory is DIRECTORY.
The function takes a directory's name, or nil, and compares the true
names, each of which it works out once, so that it can be asked of many
tasks.  With DIRECTORY nil it always answers nil."
  (let ((seen (make-hash-table :test #'equal))
        (true (and directory
                   (file-truename (file-name-as-directory
                                   (expand-file-name directory))))))
    (lambda (other)
      (and true other
           (equal true
                  (or (gethash other seen)
                      (puthash other
                               (file-truename (file-name-as-directory
                                               (expand-file-name other)))
                               seen)))))))

(defun agent-auto--first (predicate items)
  "Return ITEMS with those PREDICATE holds for first, each group in its order."
  (append (seq-filter predicate items) (seq-remove predicate items)))

(defun agent-auto--label (items function)
  "Return an alist from a label to each of ITEMS, in their order.
FUNCTION, called with an item, returns its label.  A label that two
items share gets a number, so that each can be chosen."
  (let ((seen (make-hash-table :test #'equal)))
    (mapcar (lambda (item)
              (let* ((label (funcall function item))
                     (count (puthash label (1+ (gethash label seen 0)) seen)))
                (cons (if (= count 1) label (format "%s <%d>" label count))
                      item)))
            items)))

(defun agent-auto--choose (prompt candidates)
  "Read one of CANDIDATES with PROMPT, and return what it stands for.
CANDIDATES is an alist from a label to an item.  They are offered in
their order, which a completion interface would otherwise sort away, and
the first is the default."
  (let* ((labels (mapcar #'car candidates))
         (table (lambda (string predicate action)
                  (if (eq action 'metadata)
                      '(metadata (display-sort-function . identity)
                                 (cycle-sort-function . identity))
                    (complete-with-action action labels string predicate))))
         (choice (completing-read prompt table nil t nil nil (car labels))))
    (cdr (assoc choice candidates))))

(defun agent-auto--send-task (marker buffer from-session)
  "Send the task at MARKER to session BUFFER, as sending it by hand does.
The task is read by the extractor of the thing it is, so a Linear issue
is sent as one, and the link is asked about and recorded as for any task
sent to a running session; see `agent-auto--confirm-delivery'.  With
FROM-SESSION non-nil the command was called in the session and the task
is read in its own buffer; otherwise point is on the task already."
  (if from-session
      (with-current-buffer (marker-buffer marker)
        (save-excursion
          (save-restriction
            (widen)
            (goto-char marker)
            (agent-auto--send-thing-at-point buffer))))
    (agent-auto--send-thing-at-point buffer)))

(defun agent-auto--send-thing-at-point (buffer)
  "Send the thing at point to the running session BUFFER."
  (let ((origin (current-buffer))
        (agent--context-wants-directory nil))
    (funcall (or (agent--extractor-at-point)
                 (user-error "Nothing to send at point"))
             (lambda (context)
               (agent--deliver-to context buffer origin)))))

(defvar-keymap agent-task-keys-mode-map
  :doc "Keymap of `agent-task-keys-mode'.
It holds the keys that act on the session of the task at point in a
buffer that lists tasks.")

;; The keys are set outside the `defvar-keymap', whose value form runs
;; only the first time: loading the package again in a running Emacs, as
;; an update does, would otherwise leave the keymap with the keys of the
;; old code.  Keys the user bound in the keymap stay.
(keymap-set agent-task-keys-mode-map "S" #'agent-link-session)

;;;###autoload
(define-minor-mode agent-task-keys-mode
  "Minor mode with keys for the session of the task at point.
It is for buffers that list tasks, such as an Org agenda, and is turned
on in the lists it should work in from their hooks, as
`org-agenda-mode-hook'.  Its keys take precedence over those of the
buffer's major mode.

\\{agent-task-keys-mode-map}"
  :keymap agent-task-keys-mode-map)

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
  "Follow the killing of the current buffer when it is a session.
For `kill-buffer-hook'.  The marks are brought up to date, and a session
linked to a task that closes without a handover leaves a note saying so;
see `agent-auto--close-without-handover'."
  (when agent--session
    (agent-auto--guard "noting a session's close"
      (agent-auto--close-without-handover (current-buffer)))
    (agent-auto--schedule-marks)))

(defun agent-auto--mark-agenda ()
  "Mark the lines of the agenda just built whose tasks have an open session.
For `org-agenda-finalize-hook', which marks an agenda before it is first
shown.  It is on the hook's global value, and an agenda command can bind
the hook to functions of its own for the build and for every redo, so
the marks are also asked for from `org-agenda-mode-hook', which every
build runs, and from `agent-auto--check-agenda'."
  (agent-auto--guard "marking an agenda"
    (agent-auto--refresh-marks)))

(defun agent-auto--check-agenda ()
  "Bring the marks up to date when the agenda at hand has lost some.
For `post-command-hook'.  The agenda at hand is the current buffer or
the one in the selected window.  A mark is an overlay that goes with its
text, so an agenda whose text changed since it was marked may have lost
marks, whatever changed it and whichever hooks that ran.  Comparing two
numbers is all this costs after a command that changed no agenda, and
the marks are asked for once for each change, also if bringing them up
to date fails."
  (agent-auto--guard "checking an agenda's marks"
    (dolist (buffer (list (current-buffer) (window-buffer)))
      (when (agent-auto--agenda-stale-p buffer)
        (with-current-buffer buffer
          (setq agent-auto--marked-tick (buffer-chars-modified-tick)))
        (agent-auto--schedule-marks)))))

(defun agent-auto--agenda-stale-p (buffer)
  "Return non-nil when the text of agenda BUFFER changed since it was marked.
Return nil for a buffer that is no agenda."
  (and (provided-mode-derived-p (buffer-local-value 'major-mode buffer)
                                'org-agenda-mode)
       (not (eql (buffer-local-value 'agent-auto--marked-tick buffer)
                 (buffer-chars-modified-tick buffer)))))

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
just before the task's title.  The state of the buffer's text is
remembered, for `agent-auto--agenda-stale-p'."
  (setq agent-auto--marked-tick (buffer-chars-modified-tick))
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
                      (start (agent-auto--agenda-title-start marker))
                      ((< start (line-end-position))))
            (agent-auto--put-mark start (1+ start)
                                  'before-string (concat mark " ")))
          (forward-line 1))))))

(defun agent-auto--agenda-title-start (marker)
  "Return where the title of the task on the current agenda line starts.
MARKER is at the task's heading.  The title starts after the line's
prefix, the task's TODO keyword and its priority cookie.  The agenda
marks where the heading's text starts with the text property
`org-heading'.  The keyword is the one the line's `todo-state' property
names, or the one the heading has now: a line Org wrote again in place,
as when the task's state is changed from the agenda, shows the heading's
keyword and keeps the property of the line it replaced."
  (save-excursion
    (let ((end (line-end-position))
          (keywords (delq nil (list (get-text-property (point) 'todo-state)
                                    (agent-auto--heading-keyword marker))))
          (case-fold-search nil))
      (goto-char (or (text-property-any (point) end 'org-heading t)
                     (progn (back-to-indentation) (point))))
      (when (seq-some (lambda (keyword)
                        (looking-at (concat "\\.*" (regexp-quote keyword)
                                            "[ \t]+")))
                      keywords)
        (goto-char (match-end 0)))
      (when (looking-at "\\[#[A-Z0-9]+\\][ \t]+")
        (goto-char (match-end 0)))
      (min (point) end))))

(defun agent-auto--heading-keyword (marker)
  "Return the TODO keyword of the heading at MARKER, or nil when it has none."
  (with-current-buffer (marker-buffer marker)
    (org-with-wide-buffer
     (goto-char marker)
     (org-get-todo-state))))

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

;;;; Handover

(defconst agent-auto--handover-states
  '("finished" "needs-pablo" "waiting-on-someone" "interrupted")
  "The states a session can name in its handover.")

(defun agent-auto--handover-step (buffer)
  "Return the step that asks session BUFFER for its handover, or nil.
For `agent-before-exit-step-functions': a session linked to an open task
is asked, before the skills of its exit chain run, to write where the
task stands to a file.  A session linked to no task, or to one that is
closed or gone, is not asked."
  (when (buffer-local-value 'agent-auto--link buffer)
    (agent-auto--sync-session buffer)
    (when-let* ((link (buffer-local-value 'agent-auto--link buffer))
                ((agent-auto--task-at-close link)))
      (let ((file (agent-auto--answer-file buffer)))
        (list :name "handover"
              :prompt (agent-auto--handover-prompt file)
              :done-p (lambda (_buffer) (file-exists-p file))
              :finish #'agent-auto--handover-finish)))))

(defun agent-auto--handover-prompt (file)
  "Return the prompt asking a session to write its handover to FILE.
It is `agent-auto-handover-prompt', then `agent-auto-wait-instructions'."
  (concat (format-spec agent-auto-handover-prompt `((?f . ,file)) 'ignore)
          (unless (member agent-auto-wait-instructions '(nil ""))
            (concat "\n\n" agent-auto-wait-instructions))))

(defun agent-auto--answer-file (buffer)
  "Return a new file for session BUFFER to write its handover to.
It is in a private directory of its own, where temporary files go: a
session can write there whatever its project, and what it writes is
copied into a receipt when its turn ends.  A file BUFFER was given
before, by an exit that was abandoned, is deleted."
  (agent-auto--forget-answer buffer)
  (let ((directory (make-temp-file "agent-handover-" t)))
    (set-file-modes directory #o700)
    (with-current-buffer buffer
      (setq agent-auto--handover-answer
            (expand-file-name "handover.json" directory)))))

(defun agent-auto--forget-answer (buffer)
  "Delete the file session BUFFER was asked to write its handover to."
  (when-let* ((file (buffer-local-value 'agent-auto--handover-answer buffer))
              (directory (file-name-directory file)))
    (when (file-directory-p directory)
      (delete-directory directory t))
    (with-current-buffer buffer
      (setq agent-auto--handover-answer nil))))

(defun agent-auto--handover-finish (buffer)
  "Keep what session BUFFER wrote as its handover, for its task.
This is the `:finish' function of the step `agent-auto--handover-step'
gives.  A session that wrote nothing, or nothing that can be read,
leaves a receipt saying so, and its exit goes on.  A session that was
asked for no handover, or whose handover has been kept, leaves nothing."
  (when-let* ((file (buffer-local-value 'agent-auto--handover-answer buffer)))
    (let ((answer (agent-auto--read-answer file)))
      (agent-auto--forget-answer buffer)
      (agent-auto--record-handover buffer answer))))

(defun agent-auto--close-without-handover (buffer)
  "Leave a receipt for session BUFFER, which is being killed, if it has none.
A session closed with `agent-exit' has left its handover by now.  One
that is killed in any other way, as by `agent-exit-without-skills' or
when its process ends, closes without one, and its task's log says so.
What the session wrote before it was killed is kept all the same.  A
session linked to no task leaves nothing, and neither does one killed
for another to take its place; see `agent-session-being-replaced'."
  (let ((file (buffer-local-value 'agent-auto--handover-answer buffer)))
    (when (and (buffer-local-value 'agent-auto--link buffer)
               (not (buffer-local-value 'agent-auto--handed-over buffer))
               (not agent-session-being-replaced))
      (agent-auto--record-handover
       buffer (if (and file (file-exists-p file))
                  (agent-auto--read-answer file)
                (list :state "none" :reason "its buffer was killed"))))
    (agent-auto--forget-answer buffer)))

(defun agent-auto--read-answer (file)
  "Return the handover a session wrote to FILE, as a plist.
The plist has `:state', one of `agent-auto--handover-states', and those
of `:summary', `:next', `:question', `:who', `:what' and `:wait' that
the session gave, each a string on one line.  A FILE that is missing,
is no JSON object or names no such state gives the state \"none\", with
`:reason' saying which; nothing of what it held is repeated."
  (if (not (and file (file-readable-p file)))
      (list :state "none" :reason "it wrote no receipt")
    (let ((data (condition-case nil
                    (with-temp-buffer
                      (let ((coding-system-for-read 'utf-8))
                        (insert-file-contents file))
                      (json-parse-buffer :object-type 'plist
                                         :null-object nil
                                         :false-object nil))
                  (error 'invalid))))
      (cond
       ((eq data 'invalid)
        (list :state "none" :reason "its receipt is not valid JSON"))
       ((not (and (listp data)
                  (member (plist-get data :state) agent-auto--handover-states)))
        (list :state "none" :reason "its receipt names no known state"))
       (t (agent-auto--answer-fields data))))))

(defun agent-auto--answer-fields (data)
  "Return the fields of a handover in DATA, a plist read from JSON."
  (let ((answer (list :state (plist-get data :state))))
    (dolist (field '(:summary :next :question :who :what :wait) answer)
      (when-let* ((text (agent-auto--field-text (plist-get data field))))
        (setq answer (plist-put answer field text))))))

(defun agent-auto--field-text (value)
  "Return VALUE, a field of a handover, as text on one line, or nil when empty."
  (when value
    (let ((text (string-trim
                 (replace-regexp-in-string
                  "[ \t\n\r]+" " "
                  (if (stringp value) value (format "%s" value))))))
      (unless (string-empty-p text)
        text))))

(defun agent-auto--record-handover (buffer answer)
  "Make ANSWER the receipt of this close of session BUFFER, and write it.
ANSWER is as `agent-auto--read-answer' returns it.  The receipt is a
plist that adds what finds the task and what tells whether it is still
as the session left it: `:id', the receipt's own; `:created', the time;
`:file', the task's file; `:session', the session the task records;
`:org-id', its Org ID, when it has one; `:result', its result; and
`:keyword', its TODO keyword.  It is written to a file of its own and
then on the task, as soon as the task's buffer has no unsaved edits.  A
session whose task is closed or gone leaves no receipt.  A handover
replaces the result of the session's last turn, so one still waiting to
be written is dropped."
  (with-current-buffer buffer
    (setq agent-auto--handed-over (plist-get answer :state)
          agent-auto--back nil))
  (when-let* ((link (buffer-local-value 'agent-auto--link buffer))
              (task (agent-auto--task-at-close link)))
    (let ((receipt (append (list :id (agent-auto--handover-id)
                                 :created (float-time)
                                 :file (agent-auto-link-file link)
                                 :session (agent-auto-link-recorded link))
                           task answer)))
      (unless (equal (plist-get answer :state) "none")
        (agent-auto--drop-pending link))
      (agent-auto--save-handover receipt)
      (setq agent-auto--handovers
            (append agent-auto--handovers (list receipt)))
      (agent-auto--schedule-flush)
      receipt)))

(defun agent-auto--task-at-close (link)
  "Return what the open task of LINK is like now, or nil.
The result is a plist of `:keyword', the task's TODO keyword, and of
`:org-id' and `:result' when the task has them.  Nil when the task is
closed or cannot be found.  The task is read, never changed, so its
buffer may have unsaved edits."
  (when-let* ((org (agent-auto--org-buffer (agent-auto-link-file link))))
    (with-current-buffer org
      (org-with-wide-buffer
       (when (and (agent-auto--goto-recorded (agent-auto-link-recorded link))
                  (org-entry-is-todo-p))
         (agent-auto--without-nil
          (list :keyword (substring-no-properties (org-get-todo-state))
                :org-id (org-entry-get nil "ID")
                :result (org-entry-get nil agent-auto-result-property))))))))

(defun agent-auto--without-nil (plist)
  "Return PLIST without the keys whose value is nil."
  (let (result)
    (while plist
      (when (cadr plist)
        (setq result (plist-put result (car plist) (cadr plist))))
      (setq plist (cddr plist)))
    result))

(defun agent-auto--handover-id ()
  "Return an id for a new receipt, which sorts after every one made before.
It is the time, to the microsecond, and four random digits."
  (let (id)
    (while (not (and id (or (null agent-auto--last-handover-id)
                            (string> id agent-auto--last-handover-id))))
      (setq id (format "%s-%04x" (format-time-string "%Y%m%dT%H%M%S%6N")
                       (random #x10000))))
    (setq agent-auto--last-handover-id id)))

(defun agent-auto--drop-pending (link)
  "Forget the results still waiting to be written on the task of LINK."
  (setq agent-auto--pending
        (seq-remove (lambda (entry)
                      (let ((other (car entry)))
                        (and (agent-auto--same-file-p
                              (agent-auto-link-file other)
                              (agent-auto-link-file link))
                             (equal (agent-auto-link-recorded other)
                                    (agent-auto-link-recorded link)))))
                    agent-auto--pending)))

;;;;; Receipts

(defun agent-auto--handover-file (receipt)
  "Return the file that holds RECEIPT."
  (expand-file-name (concat (plist-get receipt :id) ".json")
                    agent-auto-handover-directory))

(defun agent-auto--save-handover (receipt)
  "Write RECEIPT to its file, replacing what the file held."
  (let* ((file (agent-auto--handover-file receipt))
         (temporary (concat file ".tmp"))
         (coding-system-for-write 'binary))
    (make-directory (file-name-directory file) t)
    (write-region (json-serialize (agent-auto--without-nil receipt))
                  nil temporary nil 'silent)
    (rename-file temporary file t)))

(defun agent-auto--update-handover (receipt key value)
  "Set KEY to VALUE in RECEIPT, in memory and in its file."
  (plist-put receipt key value)
  (agent-auto--save-handover receipt))

(defun agent-auto--load-handovers ()
  "Read the receipts on disk into `agent-auto--handovers', the oldest first.
This is how a handover that Emacs quit before writing is written at its
next start.  A file that holds no receipt is reported and left alone."
  (setq agent-auto--handovers
        (and (file-directory-p agent-auto-handover-directory)
             (delq nil (mapcar #'agent-auto--read-handover
                               (directory-files agent-auto-handover-directory
                                                t "\\.json\\'"))))))

(defun agent-auto--read-handover (file)
  "Return the receipt FILE holds, or nil, with a message, when it holds none."
  (let ((receipt (condition-case nil
                     (with-temp-buffer
                       (let ((coding-system-for-read 'utf-8))
                         (insert-file-contents file))
                       (json-parse-buffer :object-type 'plist
                                          :null-object nil
                                          :false-object nil))
                   (error nil))))
    (if (and (listp receipt)
             (seq-every-p (lambda (key) (stringp (plist-get receipt key)))
                          '(:id :file :session :state)))
        receipt
      (message "agent-auto: %s holds no handover receipt"
               (abbreviate-file-name file))
      nil)))

(defun agent-auto--discard-handover (receipt)
  "Forget RECEIPT, which has been written on its task, and delete its file."
  (setq agent-auto--handovers (delq receipt agent-auto--handovers))
  (let ((file (agent-auto--handover-file receipt)))
    (when (file-exists-p file)
      (delete-file file))))

(defun agent-auto--handover-target (receipt)
  "Return the session the task of RECEIPT records now, as far as is known.
That is the session it recorded at the close, unless the task was since
given another; see `agent-auto--retarget-handovers'."
  (or (plist-get receipt :found-as) (plist-get receipt :session)))

(defun agent-auto--retarget-handovers (file old new)
  "Let the receipts of the task in FILE that recorded session OLD find it as NEW.
A task whose recorded session changes while a receipt waits for it would
otherwise be lost to that receipt, unless it has an Org ID."
  (dolist (receipt agent-auto--handovers)
    (when (and (agent-auto--same-file-p (plist-get receipt :file) file)
               (equal (agent-auto--handover-target receipt) old))
      (agent-auto--update-handover receipt :found-as new))))

;;;;; Writing a receipt on its task

(defun agent-auto--schedule-flush ()
  "Arrange for what waits to be written on tasks to be written.
The work is done once, from a timer, however often it is asked for
before then.  A timer that was cancelled is replaced."
  (unless (and (timerp agent-auto--flush-timer)
               (memq agent-auto--flush-timer timer-list))
    (setq agent-auto--flush-timer
          (run-with-timer 0 nil #'agent-auto--run-flush))))

(defun agent-auto--run-flush ()
  "Write what waits, from the timer `agent-auto--schedule-flush' set."
  (setq agent-auto--flush-timer nil)
  (agent-auto--guard "writing on tasks"
    (agent-auto--flush)))

(defun agent-auto--flush ()
  "Write on the tasks everything that waits and can now be written.
Results go first: a receipt takes a result written since its session
closed as a sign that the task has moved on."
  (agent-auto--flush-pending)
  (agent-auto--flush-handovers)
  (agent-auto--flush-returning))

(defun agent-auto--after-save ()
  "Write what waited for the current buffer to be saved.
For `after-save-hook'.  The writing saves the buffer again, so it is
done from a timer and not from inside this save."
  (when (and (or agent-auto--pending agent-auto--handovers
                 agent-auto--returning)
             (derived-mode-p 'org-mode))
    (agent-auto--schedule-flush)))

(defun agent-auto--flush-handovers ()
  "Write on their tasks the receipts that can now be written, the oldest first.
A receipt is deleted once it is written and its task's buffer is saved.
One whose task cannot be found is kept, and reported once."
  (dolist (receipt (copy-sequence agent-auto--handovers))
    (pcase (agent-auto--apply-handover receipt)
      ('done (agent-auto--discard-handover receipt))
      ('missing (agent-auto--report-lost-handover receipt)))))

(defun agent-auto--apply-handover (receipt)
  "Write RECEIPT on its task; return `done', `deferred' or `missing'.
The values are those of `agent-auto--edit-task'.  A task whose buffer
could not be saved after the edit is `deferred': the receipt is kept
until the buffer is saved, and is then found written."
  (let* ((file (plist-get receipt :file))
         (result (agent-auto--edit-at
                  file
                  (lambda () (agent-auto--goto-handover-task receipt))
                  (lambda () (agent-auto--write-handover receipt)))))
    (if (and (eq result 'done)
             (when-let* ((buffer (find-buffer-visiting file)))
               (buffer-modified-p buffer)))
        'deferred
      result)))

(defun agent-auto--goto-handover-task (receipt)
  "Move to the heading of the task of RECEIPT; return non-nil when found.
The task is the one that has the Org ID the receipt names, when it names
one, and otherwise the one that records the receipt's session."
  (if-let* ((id (plist-get receipt :org-id)))
      (agent-auto--goto-property "ID" id)
    (agent-auto--goto-recorded (agent-auto--handover-target receipt))))

(defun agent-auto--report-lost-handover (receipt)
  "Say, once, that the task of RECEIPT cannot be found; the receipt is kept."
  (unless (plist-get receipt :reported)
    (message "agent-auto: no task for a handover in %s; its receipt is kept in %s"
             (abbreviate-file-name (plist-get receipt :file))
             (abbreviate-file-name (agent-auto--handover-file receipt)))
    (agent-auto--update-handover receipt :reported t)))

(defun agent-auto--write-handover (receipt)
  "Write RECEIPT on the task at point, unless it is written there already.
The task records the id of the last receipt written on it, in
`agent-auto-handover-property', so a receipt whose file outlived the
writing, as when Emacs was killed in between, is not written twice.
The dated note is history, and is always added.  The result, the tag
and the keyword say where the task stands now, and are written only
when `agent-auto--handover-current-p' holds."
  (let ((id (plist-get receipt :id))
        (last (org-entry-get nil agent-auto-handover-property)))
    (unless (equal last id)
      (let ((current (agent-auto--handover-current-p receipt last)))
        (agent-auto--add-note (agent-auto--handover-note receipt)
                              (plist-get receipt :created))
        (when current
          (agent-auto--write-handover-result receipt))
        (unless (and last (string> last id))
          (org-entry-put nil agent-auto-handover-property id))
        (agent-auto--log "handover %s: %s" id (plist-get receipt :state))))))

(defun agent-auto--handover-current-p (receipt last)
  "Return non-nil when RECEIPT still says where the task at point stands.
A receipt written late must not undo what happened since its session
closed.  It is current when it carries a handover; the task is open; it
still records the session it recorded then; no later handover has been
written on it, LAST being the id of the last one, or waits to be; and
its result is the one it had then."
  (and (not (equal (plist-get receipt :state) "none"))
       (org-entry-is-todo-p)
       (equal (org-entry-get nil agent-auto-session-property)
              (plist-get receipt :session))
       (not (and last (string> last (plist-get receipt :id))))
       (not (agent-auto--later-handover-p receipt))
       (equal (org-entry-get nil agent-auto-result-property)
              (plist-get receipt :result))))

(defun agent-auto--later-handover-p (receipt)
  "Return non-nil when a receipt later than RECEIPT waits for the same task."
  (seq-some (lambda (other)
              (and (string> (plist-get other :id) (plist-get receipt :id))
                   (agent-auto--same-file-p (plist-get other :file)
                                            (plist-get receipt :file))
                   (if (plist-get receipt :org-id)
                       (equal (plist-get other :org-id)
                              (plist-get receipt :org-id))
                     (equal (agent-auto--handover-target other)
                            (agent-auto--handover-target receipt)))))
            agent-auto--handovers))

(defun agent-auto--write-handover-result (receipt)
  "Give the task at point the result and the tag of RECEIPT.
A session that closed finished leaves the review tag, and one that needs
the user the blocked tag; the other two states leave none.  Whichever
of the ready and result tags the task carried goes.  A session that
closed waiting on someone also sets the task waiting; see
`agent-auto--set-waiting'."
  (let* ((tags (org-get-tags nil t))
         (lifecycle (list agent-auto-ready-tag agent-auto-review-tag
                          agent-auto-blocked-tag agent-auto-stuck-tag))
         (new (append (seq-difference tags lifecycle)
                      (pcase (plist-get receipt :state)
                        ("finished" (list agent-auto-review-tag))
                        ("needs-pablo" (list agent-auto-blocked-tag))))))
    (unless (equal new tags)
      (org-set-tags new))
    (org-entry-put nil agent-auto-result-property
                   (agent-auto--handover-result receipt))
    (when (equal (plist-get receipt :state) "waiting-on-someone")
      (agent-auto--set-waiting receipt))))

(defun agent-auto--handover-title (receipt)
  "Return in a few words how the session of RECEIPT closed."
  (pcase (plist-get receipt :state)
    ("finished" "finished")
    ("needs-pablo" "needs a decision")
    ("waiting-on-someone"
     (format "waiting on %s" (or (plist-get receipt :who) "someone")))
    (_ "interrupted")))

(defun agent-auto--handover-result (receipt)
  "Return the one-line result RECEIPT gives its task.
It is how the session closed, the question it asks, what it did and the
next step."
  (let* ((title (agent-auto--handover-title receipt))
         (next (plist-get receipt :next))
         (parts (delq nil
                      (list (agent-auto--sentence (plist-get receipt :question))
                            (agent-auto--sentence (plist-get receipt :summary))
                            (and next (concat "Next: " next))))))
    (agent-auto--one-line
     (concat (upcase (substring title 0 1)) (substring title 1)
             (and parts (concat ": " (string-join parts " ")))))))

(defun agent-auto--sentence (text)
  "Return TEXT ending as a sentence does, or nil when TEXT is nil."
  (and text
       (if (string-match-p "[.!?…]\\'" text) text (concat text "."))))

(defun agent-auto--handover-note (receipt)
  "Return the lines of the note RECEIPT leaves in its task's log.
A handover gives how the session closed, what it did, the next step and
every other field it gave, each in full.  A close without one says so,
and why."
  (if (equal (plist-get receipt :state) "none")
      (list (format "Session closed without a handover: %s."
                    (or (plist-get receipt :reason) "it left none")))
    (cons (format "Session closed: %s."
                  (pcase (plist-get receipt :state)
                    ("waiting-on-someone" "waiting on someone")
                    (_ (agent-auto--handover-title receipt))))
          (delq nil
                (mapcar (pcase-lambda (`(,label . ,field))
                          (when-let* ((text (plist-get receipt field)))
                            (format "%s: %s" label text)))
                        '(("Done" . :summary)
                          ("Next" . :next)
                          ("Question" . :question)
                          ("Waiting on" . :who)
                          ("Waiting for" . :what)))))))

;;;;; Waiting on someone

(defun agent-auto--set-waiting (receipt)
  "Move the task at point to the waiting keyword, as RECEIPT asks.
The keyword is `agent-auto-waiting-keyword', when the buffer's keywords
include it.  The task records the keyword it had in
`agent-auto-keyword-property' and the wait the session registered in
`agent-auto-wait-property'.  A task whose keyword changed since the
session closed keeps the keyword it has, and so does one whose session
has started a turn since: the work on it was resumed."
  (let ((keyword agent-auto-waiting-keyword)
        (current (org-get-todo-state))
        (wait (plist-get receipt :wait)))
    (when (and keyword
               (member keyword org-todo-keywords-1)
               (equal current (plist-get receipt :keyword))
               (not (plist-get receipt :resumed)))
      (unless (equal current keyword)
        (agent-auto--set-keyword keyword)
        (when (equal (org-get-todo-state) keyword)
          (org-entry-put nil agent-auto-keyword-property
                         (substring-no-properties current))))
      (when (equal (org-get-todo-state) keyword)
        (if wait
            (org-entry-put nil agent-auto-wait-property wait)
          (org-entry-delete nil agent-auto-wait-property))))))

(defun agent-auto--set-keyword (keyword)
  "Give the task at point the TODO KEYWORD, and log nothing of it.
Org would otherwise ask for a note, or add a line to the log after the
command, where a keyword is set up to be logged; the notes this file
writes say what happened."
  (let ((org-inhibit-logging t))
    (org-todo keyword)))

(defun agent-auto--mark-resumed (link)
  "Note in the receipts waiting for the task of LINK that its session works on.
Such a receipt, written later, no longer sets the task waiting."
  (dolist (receipt agent-auto--handovers)
    (when (and (agent-auto--same-file-p (plist-get receipt :file)
                                        (agent-auto-link-file link))
               (equal (agent-auto--handover-target receipt)
                      (agent-auto-link-recorded link))
               (not (plist-get receipt :resumed)))
      (agent-auto--update-handover receipt :resumed t))))

(defun agent-auto--return (link)
  "Take the task of LINK out of waiting, its session working again.
A task whose buffer has unsaved edits leaves it once the buffer is
saved."
  (unless (member link agent-auto--returning)
    (setq agent-auto--returning (append agent-auto--returning (list link))))
  (agent-auto--schedule-flush))

(defun agent-auto--flush-returning ()
  "Take out of waiting the tasks of `agent-auto--returning' that can be edited."
  (setq agent-auto--returning
        (seq-filter (lambda (link)
                      (eq (agent-auto--edit-task link #'agent-auto--leave-waiting)
                          'deferred))
                    agent-auto--returning)))

(defun agent-auto--leave-waiting (&optional over)
  "Take the task at point out of the waiting a handover set it in.
The task goes back to the keyword `agent-auto-keyword-property' records,
and that property and `agent-auto-wait-property' go.  A task that is no
longer in `agent-auto-waiting-keyword', its keyword having been changed
by hand, keeps the keyword it has.  With OVER non-nil the wait itself is
over, and a note in the task's log says so.  A task that records neither
property is left as it is."
  (let ((previous (org-entry-get nil agent-auto-keyword-property))
        (wait (org-entry-get nil agent-auto-wait-property))
        (back nil))
    (when (or previous wait)
      (when (and previous
                 agent-auto-waiting-keyword
                 (equal (org-get-todo-state) agent-auto-waiting-keyword)
                 (member previous org-todo-keywords-1))
        (agent-auto--set-keyword previous)
        (setq back (equal (org-get-todo-state) previous)))
      (org-entry-delete nil agent-auto-keyword-property)
      (org-entry-delete nil agent-auto-wait-property)
      (when over
        (agent-auto--add-note
         (list (if back
                   (format "The wait is over: the task is %s again." previous)
                 "The wait is over.")))))))

(defun agent-auto--check-waits ()
  "Take out of waiting the tasks of the current buffer whose wait is over.
A task's wait is over when a function in `agent-auto-wait-over-functions'
says so of the wait the task records.  The tasks are found by searching
for `agent-auto-wait-property', and nothing is searched while the hook
has no function.  The buffer is saved when it was changed."
  (when agent-auto-wait-over-functions
    (let ((regexp (format "^[ \t]*:%s:[ \t]+\\(.*?\\)[ \t]*$"
                          agent-auto-wait-property))
          (case-fold-search nil)
          (inhibit-message t))
      (org-with-wide-buffer
       (goto-char (point-min))
       (while (re-search-forward regexp nil t)
         (when (and (agent-auto--wait-over-p (match-string-no-properties 1))
                    (ignore-errors (org-back-to-heading t)))
           (agent-auto--leave-waiting t))))
      (agent-todo--save))))

(defun agent-auto--wait-over-p (wait)
  "Return non-nil when `agent-auto-wait-over-functions' say WAIT is over.
A function that signals an error is reported in *Messages* and counts as
saying no, and the functions after it are still asked."
  (run-hook-wrapped
   'agent-auto-wait-over-functions
   (lambda (function)
     (condition-case err
         (funcall function wait)
       (error (agent-auto--log "%s could not say whether the wait %s is over: %s"
                               function wait (error-message-string err))
              nil)))))

;;;;; Notes

(defun agent-auto--add-note (lines &optional time)
  "Add a note of LINES, dated TIME, to the log of the task at point.
LINES is a list of strings, each a line of the note, and TIME defaults
to now.  The note is written as Org writes one taken with
`org-add-note', so that whatever reads a task's notes reads this one: a
list item headed as `org-log-note-headings' says, in the drawer
`org-log-into-drawer' names for the task, which is created if need be,
or else where Org puts a task's notes."
  (save-excursion
    (org-back-to-heading t)
    (goto-char (org-log-beginning t))
    (cond ((not (bolp)) (insert "\n"))
          ((looking-at "[ \t]*\\S-") (save-excursion (insert "\n"))))
    (if-let* ((item (org-in-item-p)))
        (indent-line-to
         (let ((struct (save-excursion (goto-char item) (org-list-struct))))
           (org-list-get-ind (org-list-get-top-point struct) struct)))
      (org-indent-line))
    (insert (org-list-bullet-string "-") (agent-auto--note-heading time)
            " \\\\")
    (let ((column (org-list-item-body-column (line-beginning-position))))
      (dolist (line lines)
        (insert "\n")
        (indent-line-to column)
        (insert line)))))

(defun agent-auto--note-heading (time)
  "Return the heading of a note taken at TIME, as Org writes it."
  (let ((heading (cdr (assq 'note org-log-note-headings))))
    (org-replace-escapes
     (if (org-string-nw-p heading) heading "Note taken on %t")
     `(("%u" . ,(user-login-name))
       ("%U" . ,user-full-name)
       ("%t" . ,(format-time-string (org-time-stamp-format 'long 'inactive)
                                    time))
       ("%T" . ,(format-time-string (org-time-stamp-format 'long nil) time))
       ("%d" . ,(format-time-string (org-time-stamp-format nil 'inactive)
                                    time))
       ("%D" . ,(format-time-string (org-time-stamp-format nil nil) time))
       ("%s" . "")
       ("%S" . "")))))

;;;; Editing tasks

(defun agent-auto--edit-task (link function &optional unsaved)
  "Call FUNCTION with point on the heading of the task of LINK.
Return `done' after the call, when the buffer is saved if FUNCTION
changed it; `deferred' when the task's buffer has unsaved edits, and is
therefore left alone; and `missing' when the file or the task is gone.
With UNSAVED non-nil a buffer with unsaved edits is edited too, and
left unsaved.  The edit is made in the buffer visiting the file,
widened, without moving point or touching a window."
  (agent-auto--edit-at
   (agent-auto-link-file link)
   (lambda () (agent-auto--goto-recorded (agent-auto-link-recorded link)))
   function unsaved))

(defun agent-auto--edit-at (file goto function &optional unsaved)
  "Call FUNCTION with point on the heading GOTO finds in FILE.
GOTO is called with no arguments in the buffer visiting FILE, widened,
and moves to a heading, returning non-nil, or returns nil when the
heading is gone.  The value, and UNSAVED, are as for
`agent-auto--edit-task'."
  (let ((buffer (agent-auto--editable-buffer file unsaved)))
    (cond
     ((eq buffer 'gone) 'missing)
     ((null buffer) 'deferred)
     (t (with-current-buffer buffer
          (org-with-wide-buffer
           (if (not (funcall goto))
               'missing
             (let ((clean (not (buffer-modified-p)))
                   (inhibit-message t))
               (funcall function)
               (when clean
                 (agent-todo--save)))
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

(defun agent-auto--same-file-p (file other)
  "Return non-nil when FILE and OTHER name the same file."
  (or (equal file other)
      (and file other (file-equal-p file other))))

(defun agent-auto--goto-property (property value)
  "Move to the heading of the task whose PROPERTY is VALUE.
Return non-nil when there is one in the current buffer."
  (goto-char (point-min))
  (let ((case-fold-search t))
    (and (re-search-forward
          (format "^[ \t]*:%s:[ \t]+%s[ \t]*$"
                  (regexp-quote property) (regexp-quote value))
          nil t)
         (ignore-errors (org-back-to-heading t)))))

(defun agent-auto--editable-buffer (file &optional unsaved)
  "Return the buffer visiting FILE when it may be edited.
Return nil when it has unsaved edits or is read-only, and the symbol
`gone' when FILE does not exist or is no Org file.  With UNSAVED non-nil
a buffer with unsaved edits may be edited too.  A buffer without them
whose file changed on disk is reverted first, since it has no edits to
lose."
  (let ((buffer (agent-auto--org-buffer file)))
    (cond
     ((null buffer) 'gone)
     ((buffer-local-value 'buffer-read-only buffer) nil)
     ((buffer-modified-p buffer) (and unsaved buffer))
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

;;;; Loading again

;; The mode's own function runs only when the mode is toggled.  Loading
;; this file again while the mode is on, as when the package is updated
;; in a running Emacs, therefore installs what this version needs.
(when agent-auto-mode
  (agent-auto--install))

(provide 'agent-auto)
;;; agent-auto.el ends here
