;;; agent.el --- Shared extensions for AI coding CLI tools -*- lexical-binding: t -*-

;; Copyright (C) 2026

;; Author: Pablo Stafforini
;; URL: https://github.com/benthamite/agent
;; Version: 0.1
;; Package-Requires: ((emacs "30.0") (transient "0.9") (consult "1.0") (claude-code "0.1") (codex "0.1"))

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

;; Shared abstractions for AI coding CLI tool extensions.
;; Provides backend-agnostic session management, notifications, and
;; terminal integration for packages like `agent-claude' and
;; `agent-codex'.

;;; Code:

(require 'cl-lib)
(require 'eieio)
(require 'iso8601)
(require 'json)
(require 'subr-x)
(eval-and-compile (require 'transient))
(require 'agent-account)
(require 'agent-project)

;;;; Split-module autoloads

(autoload 'agent-capture-prompt "agent-capture" nil t)
(autoload 'agent-insert-captured-prompt "agent-capture" nil t)
(autoload 'agent-act-on-slack-message "agent-slack" nil t)
(autoload 'agent-act-on-forge-notification "agent-forge" nil t)
(autoload 'agent-act-on-email "agent-mu4e" nil t)
(autoload 'agent-setup-snippet-keys "agent-snippet" nil t)
(autoload 'agent-slack-context "agent-slack")
(autoload 'agent-forge-context "agent-forge")
(autoload 'agent-mu4e-context "agent-mu4e")
(autoload 'agent-todo-context "agent-todo")

;;;; Custom group

(defgroup agent ()
  "Shared extensions for AI coding CLI tools."
  :group 'tools)

(defcustom agent-before-exit-functions nil
  "Abnormal hook run before `agent-exit' exits a session.
Each function is called with two arguments: the resolved BACKEND
symbol and the session BUFFER.  If any function returns nil, the
exit is aborted."
  :type 'hook
  :group 'agent)

(defcustom agent-before-exit-skill-name nil
  "Skill name to submit before exiting matching AI sessions.
When nil or empty, `agent-run-skill-before-exit' does nothing.  This is the
single-skill fallback used when `agent-before-exit-skill-names' is nil."
  :type '(choice (const :tag "Disabled" nil) string)
  :group 'agent)

(defcustom agent-before-exit-skill-names nil
  "Ordered skills to submit before exiting matching AI sessions.
Each entry is either a skill-name string, or a list whose car is the skill
name and whose cdr is a plist accepting `:directories' (a list of directories
that restrict where the skill runs, overriding
`agent-before-exit-skill-directories') and `:args' (a string appended to the
submitted command).

Skills are submitted in order, each after the previous one finishes, and the
session exits after the last.  When nil, `agent-before-exit-skill-name' is used
as a single-skill fallback."
  :type '(repeat sexp)
  :group 'agent)

(defcustom agent-before-exit-skill-directories nil
  "Directories whose sessions should run the before-exit skills.
When nil, run a configured skill before exiting every session.  An entry in
`agent-before-exit-skill-names' may override this with its own `:directories'."
  :type '(repeat directory)
  :group 'agent)

(defcustom agent-before-exit-skill-min-duration-seconds 60
  "Minimum session duration before running the before-exit skill.
Set to nil or 0 to run `agent-before-exit-skill-name' regardless
of session duration.  Backends that cannot report a duration are
treated as eligible."
  :type '(choice (const :tag "Disabled" nil) number)
  :group 'agent)

(defcustom agent-before-exit-timeout 600
  "Seconds before an unfinished before-exit skill is abandoned.
The watchdog restarts whenever the chain advances to another
skill.  If the current skill runs this long without finishing,
the watchdog resets the chain state, warns, and leaves the
session open."
  :type 'number
  :group 'agent)

(defvar-local agent--before-exit nil
  "State of the before-exit skill chain in this session buffer.
Nil when no chain has started.  Otherwise a plist with keys
`:queue' (skill entries not yet submitted), `:state' (`running'
or `closing'), `:started-at' (`float-time' when the chain
started), and `:timer' (the watchdog timer, or nil).  Only
`agent--before-exit-transition' may set this variable.")

(defvar-local agent-before-exit-skill-inhibit nil
  "Non-nil means skip the configured before-exit skill in this buffer.
This is useful for orchestration sessions that must close immediately,
such as handoff-driven autoloops.")

;;;; Backend registry

(cl-defstruct (agent-backend
               (:constructor agent-backend--create)
               (:copier nil))
  "Static description of one registered AI agent backend."
  name label icon program
  buffer-p find-all-buffers find-buffers-for-dir
  start-session session-identity restart-options resume
  send-string send-return submit
  waiting-p busy-p background-tasks-p duration-ms display-name-suffix
  notify
  account-env-var accounts account-file shared-config-items canonical-home
  account-init credential-file login-args
  run-prompt exec-prompt skill-roots skill-command-prefix
  session-headers session-prompt prepare-fork
  sync-theme
  before-exit-ready-to-close-p before-kill-check)

(defvar agent-backends nil
  "Alist of registered AI backends.
Each entry is (NAME . STRUCT) where NAME is the backend symbol
and STRUCT is an `agent-backend'.")

(defvar-local agent--backend nil
  "Cached backend symbol for this buffer.")

(defconst agent--required-backend-keys
  '(:buffer-p :find-all-buffers :start-session)
  "Backend slots required by the shared session layer.")

(defconst agent--backend-slot-names
  (mapcar #'car (cdr (cl-struct-slot-info 'agent-backend)))
  "Slot names accepted by `agent-register-backend'.")

(defun agent-register-backend (name &rest slots)
  "Register NAME as an AI agent backend built from SLOTS.
SLOTS is a keyword-value list whose keywords match `agent-backend'
slot names, e.g. (:buffer-p #\\='fn :label \"Codex\").  Signal an
error when SLOTS contains an unknown keyword or lacks a key in
`agent--required-backend-keys'.

Backends whose sessions carry launch state beyond the
`agent-session' identity provide the optional `:restart-options'
key: a function called with the session buffer before
`agent-restart' kills it, returning a plist of extra keyword
options passed through to `agent-start-session' when the session
is resumed.

Backends that support the unified session commands provide the
optional capability keys `:resume' (resume a past session, called
with a prefix argument), `:session-headers' (return a hash table of
session id to a header plist with `:session-id', `:forked-from' and
`:timestamp', called with a session buffer and an optional session id
whose descendants are the only ones the caller needs),
`:session-prompt' (enrich one header with `:first-prompt'),
`:exec-prompt' (run a prompt non-interactively, calling back with a
plist of `:exit-code', `:duration', `:text' and `:raw'), and
`:prepare-fork' (prepare a fork of a session recorded under one
directory to run in another).  A backend that omits a key does not
support the commands that dispatch on it.

Multi-account backends provide the optional account keys read by
`agent-account': `:account-env-var' (environment variable naming
the account config home), `:accounts' (alist of (NAME . HOME)),
`:account-file' (file persisting the current account name),
`:shared-config-items' (items symlinked from the canonical home
into each account home), `:canonical-home' (the backend's default
config directory), `:account-init' (function called with the
account name after syncing), `:credential-file' (account-local
credentials file inside the account home, used to detect
logged-out accounts), and `:login-args' (arguments appended to
`:program' to run the backend's login flow; see
`agent-account-login').  The `:accounts', `:account-file',
`:shared-config-items', `:canonical-home', `:credential-file',
and `:login-args' values may each be a literal value, a function
returning one, or a symbol naming a variable, resolved at read
time by `agent-account--backend-value'."
  (agent--validate-backend name slots)
  (setf (alist-get name agent-backends)
        (apply #'agent-backend--create :name name slots)))

(defun agent--validate-backend (name plist)
  "Signal an error if backend NAME's PLIST is invalid.
PLIST must contain only keywords naming `agent-backend' slots and
must include every key in `agent--required-backend-keys'."
  (let ((rest plist))
    (while rest
      (let ((key (car rest)))
        (unless (and (keywordp key)
                     (memq (intern (substring (symbol-name key) 1))
                           agent--backend-slot-names))
          (error "AI backend `%s' has unknown slot keyword `%S'" name key))
        (setq rest (cddr rest)))))
  (dolist (key agent--required-backend-keys)
    (unless (plist-get plist key)
      (error "AI backend `%s' is missing required key `%s'" name key))))

(defun agent-backend (name)
  "Return the registered `agent-backend' struct for NAME, or nil."
  (alist-get name agent-backends))

(defun agent--detect-backend (&optional buffer)
  "Detect which AI backend BUFFER belongs to.
Try each registered backend's buffer predicate.  Return the
backend name symbol or nil."
  (let ((buf (or buffer (current-buffer))))
    (or (buffer-local-value 'agent--backend buf)
        (let ((found (cl-find-if
                      (lambda (entry)
                        (funcall (agent-backend-buffer-p (cdr entry)) buf))
                      agent-backends)))
          (when found
            (with-current-buffer buf
              (setq agent--backend (car found)))
            (car found))))))

(defun agent-backend-icon-string (backend &optional face)
  "Return the icon string for the backend named BACKEND.
BACKEND is a backend name symbol.  FACE is passed to the icon
function to control the rendering color; see `agent-svg-icon'.
The icon slot can be a string or a function; if a function, it is
called with FACE to produce the icon."
  (let ((icon (when-let* ((struct (agent-backend backend)))
                (agent-backend-icon struct))))
    (if (functionp icon) (funcall icon face) (or icon ""))))

(defun agent-svg-icon (svg-data &optional face)
  "Return a propertized string displaying SVG-DATA as an inline icon.
FACE determines the color and height; it defaults to `default'.
The SVG should use \"currentColor\" for fill or stroke attributes,
which this function replaces with the foreground color of FACE.
For mode-line display, pass `mode-line-active' (not `mode-line',
whose foreground may not match the active mode-line in Emacs 29+).
Falls back to an empty string when SVG support is unavailable."
  (if (not (image-type-available-p 'svg))
      ""
    (let* ((face (or face 'default))
           (fg (face-foreground face nil t))
           (h (window-font-height nil face))
           (colored (replace-regexp-in-string "currentColor" (or fg "#000") svg-data t t))
           (img (create-image colored 'svg t :height h :ascent 'center)))
      (propertize " " 'display img 'rear-nonsticky '(display)))))

(defun agent--find-all-buffers ()
  "Return all active AI session buffers across all backends."
  (let (result)
    (dolist (entry agent-backends)
      (let ((bufs (funcall (agent-backend-find-all-buffers (cdr entry)))))
        (setq result (nconc result bufs))))
    result))

(defun agent--session-name (buffer-name)
  "Extract the project name from BUFFER-NAME.
Given \"*claude:~/path/to/project/:default*\" or
\"*codex:~/path/to/project/:default*\", return \"project\"."
  (if-let* ((directory (agent--session-directory-from-buffer-name buffer-name))
            (name (file-name-nondirectory
                   (directory-file-name directory)))
            ((not (string-empty-p name))))
      name
    buffer-name))

(defun agent--session-directory-from-buffer-name (buffer-name)
  "Return the directory encoded in AI session BUFFER-NAME."
  (when-let* ((payload (agent--session-buffer-payload buffer-name)))
    (let ((separator (agent--buffer-name-instance-separator payload)))
      (if separator
          (substring payload 0 separator)
        payload))))

(defun agent--session-instance-from-buffer-name (buffer-name)
  "Return the instance name encoded in AI session BUFFER-NAME, or nil."
  (when-let* ((payload (agent--session-buffer-payload buffer-name))
              (separator (agent--buffer-name-instance-separator payload)))
    (substring payload (1+ separator))))

(defun agent--session-buffer-payload (buffer-name)
  "Return the payload encoded in AI session BUFFER-NAME."
  (when (and (stringp buffer-name)
             (string-match "\\`\\*[^:]+:\\(.+\\)\\*\\'" buffer-name))
    (match-string 1 buffer-name)))

(defun agent--buffer-name-instance-separator (payload)
  "Return the instance separator position in session buffer PAYLOAD."
  (let ((search-end (length payload))
        separator)
    (while (and (not separator)
                (setq separator (cl-position ?: payload
                                             :from-end t
                                             :end search-end)))
      (let ((suffix (substring payload (1+ separator))))
        (when (or (string-empty-p suffix)
                  (string-match-p "[/\\\\]" suffix))
          (setq search-end separator
                separator nil))))
    separator))

;;;; Session identity

(cl-defstruct (agent-session (:constructor agent-session-create) (:copier nil))
  "Canonical identity of one AI agent session."
  (backend nil :documentation "Backend symbol: `claude-code' or `codex'.")
  (account nil :documentation "Account name string, or nil for default.")
  (directory nil :documentation "Abbreviated absolute project directory,
with a trailing slash.")
  (instance nil :documentation "Instance name string, or nil for default.")
  (id nil :documentation "CLI session id string, or nil until known."))

(cl-defun agent-start-session (session &rest options
                                       &key initial-prompt resume-id
                                       &allow-other-keys)
  "Start SESSION through its backend's `start-session' function.
SESSION is an `agent-session' whose backend, account, directory, and
instance slots parameterize the new session; nil slots fall back to the
backend's ambient defaults, except that a nil account slot is filled
from `agent-account-resolve' so the recorded identity always matches
the environment the backend spawns with (still nil when the backend has
no accounts configured).  INITIAL-PROMPT is submitted as the first
user message.  RESUME-ID resumes that session id instead of starting
fresh; a non-fork RESUME-ID also seeds the session's `id' slot, because
that identity is already known, while a fork acquires a fresh id that
only the backend can report.  Remaining OPTIONS are passed through to
the backend, which may support extras such as `:fork' (both backends)
or `:terminal-backend' \(Codex).  When SESSION carries an account,
defensively sync its config home with `agent-account-sync' and bind
`agent-account--starting' around the backend call so
`process-environment' hooks see the account at spawn time.  Signal a
`user-error' before spawning anything when the account is logged out
per `agent-account-logged-in-p', since the backend would only produce
authentication failures.  Return the new session buffer."
  (ignore initial-prompt)
  (let* ((backend (agent-session-backend session))
         (account (or (agent-session-account session)
                      (setf (agent-session-account session)
                            (agent-account-resolve backend)))))
    (agent-check-session-start backend account)
    (when (and resume-id (not (plist-get options :fork)))
      (setf (agent-session-id session) resume-id))
    (when account
      (agent-account-sync backend account))
    (let ((agent-account--starting (and account (cons backend account))))
      (apply (agent-backend-start-session (agent-backend backend))
             session options))))

(defun agent-check-session-start (backend account)
  "Signal a `user-error' unless a BACKEND session can start under ACCOUNT.
Refuse backends that cannot start a parameterized session, and accounts
that `agent-account-logged-in-p' reports as logged out, since the
backend would only produce authentication failures.  Callers that
destroy an existing session before starting the replacement, such as
`agent-restart', must run this first so a refused start leaves the
original session intact."
  (unless (when-let* ((struct (agent-backend backend)))
            (agent-backend-start-session struct))
    (user-error "Backend `%s' does not support parameterized session start"
                backend))
  (when (and account (not (agent-account-logged-in-p backend account)))
    (user-error
     "%s account `%s' is logged out; run `agent-account-login' to log back in"
     (or (agent-backend-label (agent-backend backend)) backend) account)))

(defvar-local agent--session nil
  "The `agent-session' struct for this buffer, or nil.")

(defun agent-session (&optional buffer)
  "Return the `agent-session' struct for BUFFER, or nil.
BUFFER defaults to the current buffer.  When BUFFER has no stored
struct yet, lazily backfill one with `agent--capture-session' so
sessions created before the struct existed keep working during
the migration."
  (let ((buf (or buffer (current-buffer))))
    (when (buffer-live-p buf)
      (if-let* ((session (buffer-local-value 'agent--session buf)))
          (agent--complete-session buf session)
        (agent--capture-session buf)))))

(defun agent--complete-session (buffer session)
  "Fill missing identity slots in SESSION from BUFFER.
Keep the account recorded on SESSION when present, because it names
the account that launched the session and may intentionally differ
from the currently selected account."
  (if (agent--session-complete-p buffer session)
      session
    (when-let* ((captured (agent--derive-session buffer)))
      (unless (agent-session-backend session)
        (setf (agent-session-backend session)
              (agent-session-backend captured)))
      (unless (agent-session-account session)
        (setf (agent-session-account session)
              (agent-session-account captured)))
      (unless (agent-session-directory session)
        (setf (agent-session-directory session)
              (agent-session-directory captured)))
      (unless (agent-session-instance session)
        (setf (agent-session-instance session)
              (agent-session-instance captured)))
      (agent--set-session buffer session))
    session))

(defun agent--session-complete-p (buffer session)
  "Return non-nil when SESSION has all identity available from BUFFER."
  (and (agent-session-backend session)
       (agent-session-directory session)
       (or (agent-session-instance session)
           (not (agent--session-instance-from-buffer-name
                 (buffer-name buffer))))))

(defun agent--capture-session (buffer)
  "Construct, store, and return the `agent-session' struct for BUFFER.
Derive the backend with `agent--detect-backend', the directory
and instance by parsing BUFFER's name, and the account from the
in-flight `agent-account--starting' binding when it belongs to
the backend, falling back to the persisted current account.
Return nil when BUFFER belongs to no registered backend or its
name encodes no directory."
  (when-let* ((session (agent--derive-session buffer)))
    (agent--set-session buffer session)))

(defun agent--derive-session (buffer)
  "Return a session identity derived from BUFFER, or nil."
  (when-let* ((backend (agent--detect-backend buffer))
              (name (buffer-name buffer))
              (directory (agent--session-directory-from-buffer-name name)))
    (let ((account (or (and (eq (car-safe agent-account--starting) backend)
                            (cdr agent-account--starting))
                       (agent-account-current backend))))
      (agent-session-create
       :backend backend
       :account account
       :directory directory
       :instance (agent--session-instance-from-buffer-name name)))))

(defun agent-session-buffer-name (session)
  "Return the buffer name encoding SESSION's identity.
SESSION is an `agent-session' struct.  Follows the CLI packages'
naming convention: \"*claude:DIR*\" or \"*claude:DIR:INSTANCE*\"
for the `claude-code' backend, and \"*codex:DIR*\" or
\"*codex:DIR:INSTANCE*\" for the `codex' backend."
  (let ((prefix (pcase (agent-session-backend session)
                  ('claude-code "claude")
                  (backend (symbol-name backend))))
        (instance (agent-session-instance session)))
    (format "*%s:%s%s*" prefix
            (agent-session--normalize-directory
             (agent-session-directory session))
            (if instance (format ":%s" instance) ""))))

(defun agent-session--normalize-directory (directory)
  "Return DIRECTORY normalized for session identity.
Resolves symlinks, abbreviates the home directory, and ensures a
trailing slash, matching the directory form the backend CLIs encode
in their native buffer names."
  (abbreviate-file-name (file-name-as-directory (file-truename directory))))

(defun agent--set-session (buffer session)
  "Store SESSION as BUFFER's `agent--session' and return SESSION.
Also cache SESSION's backend symbol in `agent--backend' and
install `agent--session-teardown' so every captured or started
session releases its resources exactly once."
  (with-current-buffer buffer
    (setq agent--session session)
    (setq agent--backend (agent-session-backend session)))
  (agent--install-session-teardown buffer)
  session)

(defcustom agent-session-id-functions nil
  "Abnormal hook run when a live session's native id is recorded or changes.
Each function is called with the session buffer, after the `id' slot of
the buffer's `agent-session' struct has been updated.  Read the new
value with (agent-session-id (agent-session BUFFER))."
  :type 'hook
  :group 'agent)

(defcustom agent-session-annotation-functions nil
  "Abnormal hook supplying a short annotation for a live session buffer.
Each function is called with the session buffer and returns a
single-line string to show after the session name in the session
switcher, or nil to leave the session to the functions after it.  The
first non-nil answer is the one shown.  Whitespace is collapsed and
long annotations are truncated, so a function may return whatever text
it has.

Each function must be cheap and free of side effects: opening the
switcher calls it for every live session, and the menu is opened often
enough that slow work here is felt directly.

Nil, the default, shows session names alone.  Optional integrations
add a function here; `agent' renders whatever it returns and never
depends on where the text comes from."
  :type 'hook
  :group 'agent)

(defun agent--note-session-id (buffer id)
  "Record ID as the native session id of the session in BUFFER.
Do nothing unless BUFFER is live, belongs to a session, and ID is a
non-empty string that differs from the recorded id.  Run
`agent-session-id-functions' with BUFFER after recording, so optional
integrations can observe identity changes without reading private
variables."
  (when (and (buffer-live-p buffer)
             (stringp id)
             (not (string-empty-p id)))
    (when-let* ((session (agent-session buffer)))
      (unless (equal (agent-session-id session) id)
        (setf (agent-session-id session) id)
        (run-hook-with-args 'agent-session-id-functions buffer)))))

(defun agent-session-buffers ()
  "Return all live AI session buffers across registered backends."
  (agent--find-all-buffers))

;;;; Customization

(defcustom agent-protect-buffers t
  "When non-nil, prompt for confirmation before killing AI session buffers."
  :type 'boolean
  :group 'agent)

(defcustom agent-alert-style 'both
  "Style of alert when an AI session finishes responding.
Only takes effect when `agent-alert-on-ready' is non-nil."
  :type '(choice (const :tag "Visual notification only" visual)
                 (const :tag "Sound only" sound)
                 (const :tag "Both visual and sound" both))
  :group 'agent)

(defcustom agent-alert-sound nil
  "Path to the sound file played when a session finishes responding.
When nil, sound alerts are disabled even if `agent-alert-style'
is `sound' or `both'."
  :type '(choice (const :tag "No sound" nil) file)
  :group 'agent)

(defcustom agent-alert-sound-player nil
  "External program used to play `agent-alert-sound'.
When nil, `agent--alert-sound' uses `play-sound-file' when
that function is available."
  :type '(choice (const :tag "Use Emacs sound support" nil) string)
  :group 'agent)

(defcustom agent-backtrace-file
  (expand-file-name "agent-backtrace.el" temporary-file-directory)
  "File where `agent-save-backtrace' writes Emacs backtraces."
  :type 'file
  :group 'agent)

(define-obsolete-variable-alias 'agent-claude-debug-backtrace-model
  'agent-debug-backtrace-model "0.2")
(make-obsolete-variable 'agent-codex-debug-backtrace-model
                        'agent-debug-backtrace-model "0.2")

(defcustom agent-debug-backtrace-model 'gemini-flash-lite-latest
  "GPtel model for identifying candidate packages from a backtrace."
  :type 'symbol
  :group 'agent)

(define-obsolete-variable-alias 'agent-claude-debug-backtrace-backend
  'agent-debug-backtrace-backend "0.2")
(make-obsolete-variable 'agent-codex-debug-backtrace-backend
                        'agent-debug-backtrace-backend "0.2")

(defcustom agent-debug-backtrace-backend "Gemini"
  "GPtel backend name for backtrace analysis."
  :type 'string
  :group 'agent)

(defcustom agent-handoff-files
  '((claude-code . "/tmp/claude-code-handoff.md")
    (codex . "/tmp/codex-handoff.md"))
  "Alist mapping backend symbols to handoff files written by /handoff."
  :type '(alist :key-type symbol :value-type file)
  :group 'agent)

(define-obsolete-variable-alias 'agent-claude-audit-skills
  'agent-audit-skills "0.2")
(make-obsolete-variable 'agent-codex-audit-skills 'agent-audit-skills "0.2")

(defcustom agent-audit-skills
  '("code-audit" "design-audit" "interpretability-audit")
  "Skills to run when performing an integral project audit.
Each entry is a skill name without prefix; each is invoked with
`--accept'."
  :type '(repeat string)
  :group 'agent)

(define-obsolete-variable-alias 'agent-claude-audit-project-directories
  'agent-audit-project-directories "0.2")
(define-obsolete-variable-alias 'agent-codex-audit-project-directories
  'agent-audit-project-directories "0.2")

(defcustom agent-audit-project-directories nil
  "Directories available for selection in `agent-audit-project'.
New directories entered by the user are automatically added."
  :type '(repeat directory)
  :group 'agent)

(defconst agent-trajectory--legacy-agent-c-root-default
  (expand-file-name "~/Trajectory/agent-c/")
  "Previous default for `agent-trajectory-agent-c-root'.")

(defcustom agent-trajectory-reasoning-tasks-root
  (expand-file-name "~/Trajectory/reasoning-tasks/")
  "Root directory containing Trajectory reasoning-tasks worktrees."
  :type 'directory
  :group 'agent)

(make-obsolete-variable 'agent-trajectory-agent-c-root
                        'agent-trajectory-reasoning-tasks-root "0.2")

(defcustom agent-trajectory-sync-worktree-script
  (expand-file-name
   "~/My Drive/dotfiles/claude/hooks/sync-reasoning-tasks-worktree.sh")
  "Script that initializes and syncs a reasoning-tasks task worktree.
This SessionStart hook is the single source of truth for composing the
local `AGENTS.md'/`CLAUDE.md' instruction overlay, linking the
canonical key and injecting private skills.  `agent-trajectory-new-task'
runs it once so a fresh worktree matches what every later session start
produces.  Overlay locations are configured through the script's
SYNC_REASONING_TASKS_* environment variables, not through Emacs."
  :type 'file
  :group 'agent)

(make-obsolete-variable 'agent-trajectory-agent-c-overlay-directory
                        'agent-trajectory-sync-worktree-script "0.2")
(make-obsolete-variable 'agent-trajectory-reasoning-tasks-overlay-directory
                        'agent-trajectory-sync-worktree-script "0.2")
(make-obsolete-variable 'agent-trajectory-parent-agents-file
                        'agent-trajectory-sync-worktree-script "0.2")

(defcustom agent-alert-on-ready nil
  "When non-nil, alert the user when an AI session finishes responding."
  :type 'boolean
  :group 'agent)

(defcustom agent-sync-theme nil
  "When non-nil, sync AI CLI themes with the current Emacs theme.
Theme changes are persisted through registered backend
`:sync-theme' handlers.  This intentionally updates configuration
files instead of sending slash commands to active terminal sessions,
so it does not inject text into a running conversation."
  :type 'boolean
  :group 'agent)

(defcustom agent-sigwinch-delay 0.5
  "Delay in seconds before sending SIGWINCH to fix terminal rendering."
  :type 'number
  :group 'agent)

(defcustom agent-branch-worktree-directory
  (expand-file-name "claude-worktrees"
                    (or (getenv "XDG_CACHE_HOME")
                        (expand-file-name ".cache" "~")))
  "Base directory for git worktrees created by `agent-create-branch'.
Each isolated branch gets a sibling worktree under this directory,
separating its filesystem and git state from the parent session.
Defaults to a cache location to avoid cloud sync
interference with concurrent git operations."
  :type 'directory
  :group 'agent)

(defcustom agent-warn-kill-with-branches t
  "When non-nil, warn before killing a session that has branches.
If the session being killed has other sessions forked from it, a
second confirmation prompt is shown after the standard kill-protection
prompt."
  :type 'boolean
  :group 'agent)

(defcustom agent-session-annotation-max-width nil
  "Maximum display width of session annotations in the session switcher.
Annotations are always fitted to the switcher window, which is as wide
as the frame.  An integer narrows them further, to at most that many
columns; it never widens them past what the frame holds.  Nil applies
no cap beyond the frame fit.  Annotations longer than the available
width are truncated with an ellipsis.  Zero leaves no room at all, so
every session renders as the bare label it would have without an
annotation."
  :type '(choice (const :tag "Fit the frame" nil)
                 (natnum :tag "Columns"))
  :group 'agent)

;;;; Faces

(defface agent-waiting
  '((t :inherit success))
  "Face for sessions waiting for user input in the session switcher."
  :group 'agent)

(defface agent-waiting-with-background
  '((t :inherit warning))
  "Face for sessions waiting for user input while background work runs.
Applied in the session switcher when the backend's
`:background-tasks-p' reports ongoing work, to distinguish
these sessions from `agent-waiting' (truly idle)."
  :group 'agent)

(defface agent-unknown
  '((t :inherit shadow))
  "Face for sessions whose state has never been observed.
Applied in the session switcher when no session event has reached a
buffer, so that an unknown state is not presented as a known one."
  :group 'agent)

(defface agent-session-annotation
  '((t :inherit shadow))
  "Face for session annotations in the session switcher.
Applied to the text `agent-session-annotation-functions' returns, so
that a session's name stays the prominent part of its entry.
Transient adds a suffix's own face behind the faces a string already
carries, so annotations stay dim even next to a name colored by
`agent-waiting'."
  :group 'agent)

;;;; State variables

(defconst agent--home-row-keys '("a" "s" "d" "f" "j" "k" "l" ";")
  "Home row keys assigned to AI sessions, in allocation order.")

(defconst agent--fallback-keys
  '("g" "h" "q" "r" "t" "y" "u" "i" "o" "p"
    "z" "x" "c" "v" "b" "n" "m")
  "Fallback keys used when home-row keys are exhausted.
Excludes \"w\" and \"e\", which are reserved for actions in
`agent--session-switcher'.")

(defconst agent--session-key-pool
  (append agent--home-row-keys agent--fallback-keys)
  "Full pool of keys for AI session assignment, home row first.")

(defvar agent--session-keys (make-hash-table :test 'eq)
  "Map from live AI session buffer to its assigned key.")

(defvar-local agent--display-name-cache nil
  "Cached display name for the modeline.")

(defvar-local agent--session-state 'unknown
  "Lifecycle state of this AI session buffer.
One of the symbols `unknown', `busy', `awaiting-input', and `closing'.
Buffers start as `unknown' because no session event has been observed
yet; assuming `busy' would report a state that was never seen.
Only `agent-session-event' may set this variable.")

(defvar-local agent--session-state-changed-at nil
  "Value of `float-time' at this session's last state transition.")

(defvar agent--sync-theme-timer nil
  "Pending timer for deferred theme sync, or nil.")

;;;; Forward declarations

(defvar eat-terminal)
(defvar eat-term-scrollback-size)
(declare-function eat-self-input "eat" (n &optional e))
(declare-function eat-term-send-string "eat" (terminal string))
(declare-function eat-term-display-cursor "eat" (terminal))
(declare-function eat-term-set-scrollback-size "eat" (terminal size))
(declare-function alert "alert")
(declare-function elpaca-get "elpaca")
(declare-function elpaca-source-dir "elpaca")
(declare-function find-library-name "find-func")
(declare-function project-root "project" (project))
(declare-function org-get-todo-state "org" ())
(declare-function forge-notification-at-point "forge-notify" (&optional demand))
(declare-function forge-topic-at-point "forge-topic" (&optional demand))
(declare-function mu4e-message-at-point "mu4e-message" (&optional noerror))
(declare-function agent-log-menu "agent-log" ())
(declare-function agent-batch-todos "agent-todo" ())
(declare-function agent-send-todo-at-point "agent-todo"
                  (&optional existing))
(declare-function agent-capture-confirm-no-pending "agent-capture"
                  (backend buffer action))
(declare-function consult--read "consult" (table &rest options))

;;;; Theme sync

(defun agent-sync-theme (&rest _)
  "Sync registered AI backend themes with Emacs in a deferred timer."
  (interactive)
  (when agent-sync-theme
    (unless agent--sync-theme-timer
      (setq agent--sync-theme-timer
            (run-at-time 0 nil #'agent--do-sync-theme)))))

(defun agent-sync-theme-now (&rest _)
  "Sync registered AI backend themes with Emacs immediately.
This is useful before starting a CLI process, so the process reads
the current persisted theme at startup."
  (interactive)
  (when agent-sync-theme
    (when agent--sync-theme-timer
      (cancel-timer agent--sync-theme-timer)
      (setq agent--sync-theme-timer nil))
    (agent--do-sync-theme t)))

(defun agent--do-sync-theme (&optional force)
  "Perform the actual AI backend theme sync.
When FORCE is non-nil, sync even if `agent-sync-theme' is nil."
  (setq agent--sync-theme-timer nil)
  (when (or force agent-sync-theme)
    (let ((theme (agent--theme)))
      (dolist (entry agent-backends)
        (when-let* ((sync-fn (agent-backend-sync-theme (cdr entry))))
          (condition-case err
              (funcall sync-fn theme)
            (error
             (message "agent: failed to sync %s theme: %S"
                      (car entry) err))))))))

(defun agent--theme ()
  "Return \"light\" or \"dark\" based on the current frame background mode."
  (if (eq (frame-parameter nil 'background-mode) 'dark) "dark" "light"))

;;;; Session teardown

(defvar-local agent--teardown-functions nil
  "Functions run once when this session buffer is torn down.
Backends push closures onto this list at session start.  Each
closure is called with no arguments, inside the session buffer,
by `agent--session-teardown'.")

(defvar-local agent--teardown-done nil
  "Non-nil once `agent--session-teardown' has run for this buffer.")

(defun agent--install-session-teardown (&optional buffer)
  "Arrange for session BUFFER to be torn down exactly once.
BUFFER defaults to the current buffer.  Installs a buffer-local
`kill-buffer-hook' entry and a process-exit hook so teardown runs
whether the buffer is killed first or the CLI process exits first."
  (let ((buf (or buffer (current-buffer))))
    (with-current-buffer buf
      (add-hook 'kill-buffer-hook #'agent--session-teardown-current nil t))
    (agent--add-process-exit-hook buf #'agent--session-teardown)))

(defun agent--session-teardown-current ()
  "Run `agent--session-teardown' for the current buffer."
  (agent--session-teardown (current-buffer)))

(defun agent--session-teardown (buffer)
  "Release every per-session resource owned by session BUFFER.
Runs BUFFER's `agent--teardown-functions', releases its session
key, and schedules a display-name refresh.  Idempotent: only the
first call has any effect."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (unless agent--teardown-done
        (setq agent--teardown-done t)
        (dolist (fn agent--teardown-functions)
          (condition-case err
              (funcall fn)
            (error
             (agent--report-leak "teardown function" "%S signaled: %S" fn err))))
        (setq agent--teardown-functions nil)
        (remhash buffer agent--session-keys)
        (agent--refresh-display-names-deferred)))))

(defun agent--report-leak (kind format &rest args)
  "Report a leaked KIND resource described by FORMAT and ARGS.
Primary cleanup is owned by `agent--session-teardown'; safety
nets call this so escaping resources surface as warnings instead
of being silently mopped up."
  (display-warning
   'agent (format "leaked %s: %s" kind (apply #'format format args))
   :warning))

;;;; Home-row session keys

(defun agent--purge-dead-session-keys ()
  "Drop dead buffers from `agent--session-keys', reporting each as a leak.
`agent--session-teardown' owns key release; a dead entry here
means a session escaped teardown."
  (let (dead)
    (maphash (lambda (buf _) (unless (buffer-live-p buf) (push buf dead)))
             agent--session-keys)
    (dolist (buf dead)
      (agent--report-leak "session key" "dead buffer %s still held a key" buf)
      (remhash buf agent--session-keys))))

(defun agent--assign-session-key ()
  "Assign a key from `agent--session-key-pool' to the current buffer."
  (when (agent--detect-backend (current-buffer))
    (unless (gethash (current-buffer) agent--session-keys)
      (agent--purge-dead-session-keys)
      (let ((used (hash-table-values agent--session-keys)))
        (when-let* ((key (cl-find-if (lambda (k) (not (member k used)))
                                      agent--session-key-pool)))
          (puthash (current-buffer) key agent--session-keys))))))

(defun agent--ensure-all-session-keys ()
  "Ensure every active AI session buffer has a session key."
  (agent--purge-dead-session-keys)
  (dolist (buf (agent--find-all-buffers))
    (unless (gethash buf agent--session-keys)
      (let ((used (hash-table-values agent--session-keys)))
        (when-let* ((key (cl-find-if (lambda (k) (not (member k used)))
                                      agent--session-key-pool)))
          (puthash buf key agent--session-keys))))))

(defun agent--session-key-index (key)
  "Return the index of KEY in `agent--session-key-pool'."
  (or (cl-position key agent--session-key-pool :test #'string=) 99))

;;;; Display names

(defun agent--buffer-session-name (buffer)
  "Return the session name for BUFFER.
Prefers the directory stored in BUFFER's `agent-session' struct,
falling back to parsing the buffer name."
  (if-let* ((session (agent-session buffer))
            (directory (agent-session-directory session)))
      (agent--directory-project-name directory)
    (agent--session-name (buffer-name buffer))))

(defun agent--directory-project-name (directory)
  "Return the project name for DIRECTORY, its last path component."
  (let ((name (file-name-nondirectory (directory-file-name directory))))
    (if (string-empty-p name) directory name)))

(defun agent--qualified-session-name (buffer)
  "Return a qualified session name for BUFFER.
Includes the instance name when present for disambiguation.
Prefers BUFFER's `agent-session' fields, falling back to parsing
the buffer's name."
  (let* ((session (agent-session buffer))
         (project (agent--buffer-session-name buffer))
         (instance
          (if session
              (agent-session-instance session)
            (agent--session-instance-from-buffer-name (buffer-name buffer)))))
    (if instance
        (format "%s:%s" project instance)
      project)))

(defun agent-display-name (&optional buffer)
  "Return the display name for BUFFER.
Use the project name alone when it is unique among active sessions,
or \"project:instance\" when multiple sessions share the same
project.  Appends the backend's display suffix when provided.
Returns the cached value when available."
  (let ((buf (or buffer (current-buffer))))
    (or (buffer-local-value 'agent--display-name-cache buf)
        (agent--compute-display-name buf))))

(defun agent--compute-display-name (buffer)
  "Compute the display name for BUFFER by scanning active sessions."
  (let* ((name (agent--buffer-session-name buffer))
         (backend (agent--detect-backend buffer))
         (all-bufs (if backend
                       (funcall (agent-backend-find-all-buffers
                                 (agent-backend backend)))
                     (agent--find-all-buffers)))
         (others (cl-remove buffer all-bufs))
         (sibling-names (mapcar #'agent--buffer-session-name others))
         (base (if (member name sibling-names)
                   (agent--qualified-session-name buffer)
                 name)))
    (agent--display-name-with-suffix buffer backend base)))

(defun agent--display-name-with-suffix (buffer backend base)
  "Return BASE plus BACKEND's display suffix for BUFFER, when any."
  (if-let* ((struct (and backend (agent-backend backend)))
            (suffix-fn (agent-backend-display-name-suffix struct))
            (suffix (funcall suffix-fn buffer)))
      (format "%s:%s" base suffix)
    base))

(defun agent--refresh-display-names ()
  "Recompute and cache display names for all AI session buffers."
  (dolist (buf (agent--find-all-buffers))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (setq agent--display-name-cache
              (agent--compute-display-name buf))))))

(defun agent--refresh-display-names-deferred ()
  "Refresh AI display names after the current hook finishes."
  (run-at-time 0 nil #'agent--refresh-display-names))

;;;; Session switcher

;;;###autoload
(defun agent-start-or-switch ()
  "Start a new AI session or switch to an existing one.
If no sessions are active, prompt for which backend to start.
If sessions exist, show a transient menu with home-row keys."
  (interactive)
  (let ((all-bufs (agent--find-all-buffers)))
    (if (null all-bufs)
        (agent-start-new-session)
      (agent--ensure-all-session-keys)
      (transient-setup 'agent--session-switcher))))

(defun agent-start-new-session ()
  "Start a new session, prompting for backend if multiple are registered."
  (interactive)
  (let ((backends agent-backends))
    (cond
     ((null backends) (user-error "No AI backends registered"))
     ((= (length backends) 1)
      (agent--start-new-session-for-backend (caar backends)))
     (t
      (let* ((names (mapcar (lambda (e)
                              (cons (or (agent-backend-label (cdr e))
                                        (symbol-name (car e)))
                                    (car e)))
                            backends))
             (choice (completing-read "Backend: " (mapcar #'car names) nil t))
             (backend-sym (cdr (assoc choice names))))
        (agent--start-new-session-for-backend backend-sym))))))

(defun agent--start-new-session-for-backend (backend)
  "Start a new BACKEND session using its current account."
  (agent-start-session
   (agent-session-create :backend backend
                         :account (agent-account-resolve backend t))))

(transient-define-prefix agent--session-switcher ()
  "Switch to an AI session or start a new one."
  [["Actions"
    ("w" "jump to waiting" agent-jump-to-waiting)
    ("e" "new session" agent-start-new-session)]
   ["Sessions"
    :class transient-column
    :setup-children agent--session-switcher-children]])

(defun agent--session-switcher-children (_)
  "Build transient suffixes for the session switcher, grouped by account.
Labels are built in two passes, because aligning annotations needs the
widest label, which is only known once every label exists."
  (let* ((pad (agent--session-label-pad))
         (groups (agent--group-sessions-by-account pad)))
    (transient-parse-suffixes
     'agent--session-switcher
     (apply #'vector (agent--interleave-group-headers groups)))))

(defun agent--group-sessions-by-account (&optional pad)
  "Return an alist of (ACCOUNT . SPECS) sorted by account name.
Each SPECS is a list of suffix specs sorted by home-row key.  PAD is
the width to pad session labels to; nil pads nothing."
  (let ((groups (make-hash-table :test 'equal)))
    (maphash
     (lambda (buf key)
       (when (buffer-live-p buf)
         (push (agent--session-suffix-spec buf key pad)
               (gethash (agent--session-group-key buf) groups))))
     agent--session-keys)
    (agent--hash-to-sorted-alist groups)))

(defun agent--session-group-key (buffer)
  "Return the group key for BUFFER in the session switcher.
Uses the account recorded in the buffer's session, falling back to
the backend's :label or symbol name."
  (let ((backend (agent--detect-backend buffer)))
    (or (when-let* ((session (agent-session buffer)))
          (agent-session-account session))
        (when-let* ((struct (and backend (agent-backend backend))))
          (agent-backend-label struct))
        (and backend (symbol-name backend))
        "Sessions")))

(defconst agent--switcher-suffix-padding 2
  "Columns a transient suffix spends beyond its key and description.
Transient formats a suffix as \" %k %d\": one leading space and one
separator.")

(defconst agent--switcher-column-padding 2
  "Columns transient leaves between adjacent menu columns.
Matches the padding `transient--column-stops' adds between columns.")

(defconst agent--switcher-session-key-width 1
  "Display width of a session key in the switcher.
Every key in `agent--session-key-pool' is one character wide.")

(defconst agent--session-annotation-separator-width 1
  "Columns between a padded session label and its annotation.
`agent--session-label' joins the two with a single space, which the
width available to an annotation has to allow for.")

(defconst agent--session-annotation-margin 2
  "Columns left empty to the right of a session annotation.
Keeps an annotation clear of the window's last column, where a
character would wrap onto the next line.")

(defconst agent--session-annotation-min-width 20
  "Fewest columns a session annotation may occupy when fitted to the frame.
A frame too narrow for the full fit yields a short annotation rather
than none.")

(defun agent--switcher-columns ()
  "Return the column vectors of the session switcher's layout.
Read the layout through `transient--get-children', which rejects a
layout whose representation this arithmetic does not understand."
  (aref (car (transient--get-children 'agent--session-switcher)) 2))

(defun agent--switcher-column-width (column)
  "Return the display width of COLUMN in the switcher's layout.
A transient column is as wide as its widest cell: its heading, or one
of its suffixes formatted as \" KEY DESCRIPTION\".  A column with no
heading is as wide as its widest suffix.  Signal an error when a
heading is present but is not a string, since transient computes such
a heading only at display time and its width is not known here."
  (let ((heading (plist-get (aref column 1) :description)))
    (when (and heading (not (stringp heading)))
      (error "Non-string column heading in `agent--session-switcher' layout: %S"
             heading))
    (apply #'max
           (if heading (string-width heading) 0)
           (mapcar (lambda (suffix)
                     (+ agent--switcher-suffix-padding
                        (string-width (or (plist-get (cdr suffix) :key) ""))
                        (string-width (or (plist-get (cdr suffix) :description)
                                          ""))))
                   (aref column 2)))))

(defun agent--switcher-sessions-column-offset ()
  "Return the column at which the switcher's Sessions column starts.
Transient places each column two columns past the widest cell of the
one before it, so the room left for annotations depends on the columns
to the left of Sessions.  Measuring the prefix's own layout keeps that
number correct when an action is added or renamed.  Assumes
`transient-align-variable-pitch' is nil, since transient measures
columns in pixels rather than characters when it is set."
  (let ((offset 0))
    (cl-dolist
        (column (agent--switcher-columns)
                (error "No Sessions column in `agent--session-switcher' layout"))
      (when (equal (plist-get (aref column 1) :description) "Sessions")
        (cl-return offset))
      (setq offset (+ offset
                      agent--switcher-column-padding
                      (agent--switcher-column-width column))))))

(defun agent--session-annotation-width (pad)
  "Return the display width available to a session annotation.
PAD is the width session labels are padded to.  Fit the annotation to
the switcher window, which spans the frame, and never return less than
`agent--session-annotation-min-width' columns, so a narrow frame
yields a short annotation rather than none.  The fit accounts for
everything the line spends before and after the annotation: the
columns left of the Sessions column, the key and the padding transient
formats a suffix with, the padded label, the separator space
`agent--session-label' inserts, and the trailing margin.  When
`agent-session-annotation-max-width' is an integer it caps that fit: it
can only narrow the annotation, never widen it past what the frame
holds."
  (let ((fit (max agent--session-annotation-min-width
                  (- (frame-width)
                     (agent--switcher-sessions-column-offset)
                     agent--switcher-suffix-padding
                     agent--switcher-session-key-width
                     pad
                     agent--session-annotation-separator-width
                     agent--session-annotation-margin))))
    (if agent-session-annotation-max-width
        (min agent-session-annotation-max-width fit)
      fit)))

(defun agent--session-label-base (buffer)
  "Return BUFFER's switcher label without any annotation."
  (let* ((backend (agent--detect-backend buffer))
         (icon (when backend (agent-backend-icon-string backend)))
         (name (agent-display-name buffer)))
    (if (and icon (not (string-empty-p icon)))
        (format "%s %s" icon name)
      name)))

(defun agent--session-annotation (buffer)
  "Return the annotation for session BUFFER, or nil for none.
The text is the first non-nil answer from
`agent-session-annotation-functions'.  Whitespace is collapsed to
single spaces so a multi-line answer cannot break the menu's layout,
and an answer that is blank or not a string counts as no annotation."
  (let ((text (run-hook-with-args-until-success
               'agent-session-annotation-functions buffer)))
    (when (stringp text)
      (let ((line (string-trim
                   (replace-regexp-in-string "[ \t\n\r\f\v]+" " " text))))
        (unless (string-empty-p line) line)))))

(defun agent--session-label (buffer pad)
  "Return BUFFER's switcher label, annotated and padded to PAD columns.
Sessions without an annotation keep the bare label they had before
annotations existed, with no trailing padding.  A session whose
annotation has no room left to it renders the same way, since padding
and a separator around nothing is not a label anyone asked for; that
happens when `agent-session-annotation-max-width' caps the width at
zero.  PAD counts display columns, as `agent--session-label-pad'
measures them, so a name containing double-width characters lines up
with the rest; padding it to a character count would push its
annotation to the right."
  (let* ((base (agent--session-label-base buffer))
         (annotation (agent--session-annotation buffer))
         (width (and annotation (agent--session-annotation-width pad))))
    (if (or (not annotation) (<= width 0))
        base
      (concat base
              (make-string (max 0 (- pad (string-width base))) ?\s)
              " "
              (propertize (truncate-string-to-width
                           annotation width nil nil t)
                          'face 'agent-session-annotation)))))

(defun agent--session-label-pad ()
  "Return the width to pad session labels to in the switcher.
The widest label in the menu, counting every live session and not only
the annotated ones, so that the annotations start clear of every name
on screen and no name runs past the column they share.  The cost is
that one long name without an annotation pushes every annotation to
the right; that was chosen over a name column left ragged by the
sessions that have nothing after them.  Zero when there are no
sessions, which leaves every label unpadded.  Assumes every backend's
icon occupies one column, since `string-width' counts an icon's image
as the single character it is displayed over however wide the image
draws; a backend whose icon renders wider than that would sit off the
column shared by the rest."
  (let ((widths (list 0)))
    (maphash (lambda (buf _key)
               (when (buffer-live-p buf)
                 (push (string-width (agent--session-label-base buf))
                       widths)))
             agent--session-keys)
    (apply #'max widths)))

(defun agent--session-suffix-spec (buf key &optional pad)
  "Build a transient suffix spec for BUF bound to KEY.
PAD is the width to pad the session label to, so that annotations line
up across the switcher; nil pads nothing."
  (let* ((backend (agent--detect-backend buf))
         (label (agent--session-label buf (or pad 0)))
         (state (agent-session-display-state buf backend))
         (cmd (make-symbol (format "ai-switch-%s" key)))
         (spec (list key label cmd)))
    (when-let* ((face (agent--session-state-face state)))
      (setq spec (append spec (list :face face))))
    (fset cmd (lambda () (interactive) (switch-to-buffer buf)))
    spec))

(defun agent--session-state-face (state)
  "Return the session-switcher face for display STATE, or nil for none."
  (pcase state
    ('waiting 'agent-waiting)
    ('background-waiting 'agent-waiting-with-background)
    ('unknown 'agent-unknown)
    (_ nil)))

(defun agent--session-waiting-p (buffer &optional backend)
  "Return non-nil when BUFFER is blocked on user input.
BACKEND defaults to the detected backend."
  (memq (agent-session-display-state buffer backend)
        '(waiting background-waiting)))

(defun agent-session-display-state (buffer &optional backend)
  "Return the switcher display state for session BUFFER.
BACKEND defaults to the detected backend.  The result is one of the
symbols `busy', `waiting', `background-waiting', and `unknown'.

A session is waiting only when it is blocked on the user, meaning it
has stopped and will not proceed until the user submits something.
Being able to type into the prompt mid-turn is not waiting.

Backends that observe a protocol report authoritatively through
`:waiting-p' and `:busy-p', and those answers win.  Otherwise the
session-event state machine decides, and a session that has never
received an event displays as `unknown' rather than guessing.
Waiting sessions whose backend reports work via `:background-tasks-p'
display as `background-waiting'."
  (let ((backend (or backend (agent--detect-backend buffer)))
        (state (buffer-local-value 'agent--session-state buffer)))
    (cond
     ((agent--backend-waiting-p buffer backend)
      (agent--waiting-display-state buffer backend))
     ((agent--backend-busy-p buffer backend) 'busy)
     ((eq state 'awaiting-input)
      (agent--waiting-display-state buffer backend))
     ((eq state 'unknown) 'unknown)
     (t 'busy))))

(defun agent--waiting-display-state (buffer backend)
  "Return the waiting display state for BUFFER according to BACKEND.
Sessions with reported background work are distinguished from idle ones."
  (if (agent--backend-background-tasks-p buffer backend)
      'background-waiting
    'waiting))

(defun agent--backend-waiting-p (buffer backend)
  "Return non-nil when BACKEND reports BUFFER is accepting input."
  (when-let* ((struct (and backend (agent-backend backend)))
              (fn (agent-backend-waiting-p struct)))
    (funcall fn buffer)))

(defun agent--backend-busy-p (buffer backend)
  "Return non-nil when BACKEND reports BUFFER is actively responding."
  (when-let* ((struct (and backend (agent-backend backend)))
              (fn (agent-backend-busy-p struct)))
    (funcall fn buffer)))

(defun agent--backend-background-tasks-p (buffer backend)
  "Return non-nil when BACKEND reports background work in BUFFER."
  (when-let* ((struct (and backend (agent-backend backend)))
              (fn (agent-backend-background-tasks-p struct)))
    (funcall fn buffer)))

(defun agent--hash-to-sorted-alist (groups)
  "Convert GROUPS hash table to an alist sorted by key.
Each value's suffix specs are sorted by session-key pool index."
  (let (alist)
    (maphash
     (lambda (group-key specs)
       (push (cons group-key
                   (sort specs
                         (lambda (a b)
                           (< (agent--session-key-index (car a))
                              (agent--session-key-index (car b))))))
             alist))
     groups)
    (sort alist (lambda (a b) (string< (car a) (car b))))))

(defun agent--accountless-labels ()
  "Return labels for backends without configured accounts.
These backends don't support multi-account grouping, so their
sessions appear without a heading."
  (let (labels)
    (dolist (entry agent-backends labels)
      (unless (agent-account-list (car entry))
        (when-let* ((label (agent-backend-label (cdr entry))))
          (push label labels))))))

(defun agent--interleave-group-headers (groups)
  "Interleave :info headers before each group's suffix specs.
GROUPS is an alist of (ACCOUNT . SPECS).  When there is only one
group, no headers are added.  Groups whose key matches an
accountless backend label appear without a heading."
  (if (<= (length groups) 1)
      (mapcan #'cdr groups)
    (let ((no-header (agent--accountless-labels)))
      (mapcan (lambda (entry)
                (if (member (car entry) no-header)
                    (copy-sequence (cdr entry))
                  (cons (list :info (car entry)) (cdr entry))))
              groups))))

;;;; Buffer protection

(defun agent-protect-buffer ()
  "Prompt for confirmation before killing AI session buffers.
Returns t if the buffer should be killed, nil otherwise."
  (or (not agent-protect-buffers)
      (not (agent--detect-backend (current-buffer)))
      (not (process-live-p (get-buffer-process (current-buffer))))
      (yes-or-no-p "Kill AI session buffer? ")))

;;;; Session exit

(defun agent-kill-session-buffer ()
  "Kill the current AI session buffer, bypassing confirmation.
Terminates the CLI process if still running, then kills the
buffer.  Signals an error unless the current buffer is an AI
session."
  (interactive)
  (unless (agent--detect-backend (current-buffer))
    (user-error "Not in an AI session buffer"))
  (agent--force-kill-buffer (current-buffer)))

(defun agent--force-kill-buffer (buffer)
  "Terminate the process in BUFFER and kill it without confirmation."
  (when-let* ((proc (get-buffer-process buffer)))
    (set-process-query-on-exit-flag proc nil)
    (set-process-sentinel proc #'ignore)
    (delete-process proc))
  (with-current-buffer buffer
    (let ((kill-buffer-query-functions nil))
      (kill-buffer (current-buffer)))))

;;;; Alert and notification system

(defun agent-notify (title message)
  "Show notification with TITLE and MESSAGE.
When `agent-alert-on-ready' is non-nil, dispatch to the
configured alert style."
  (message "%s: %s" title message)
  (agent--alert-route title message))

(defun agent--alert-route (title message)
  "Fire the configured visual/sound alert for TITLE and MESSAGE."
  (when agent-alert-on-ready
    (agent--alert-visual title message)
    (agent--alert-sound)))

(defun agent--alert-visual (title message)
  "Show a visual notification with TITLE and MESSAGE."
  (when (memq agent-alert-style '(visual both))
    (when (and (require 'alert nil t) (fboundp 'alert))
      (alert message :title title))))

(defun agent--alert-sound ()
  "Play the configured alert sound."
  (when (memq agent-alert-style '(sound both))
    (when-let* ((sound agent-alert-sound))
      (if (not (file-exists-p sound))
          (message "AI alert sound file not found: %s" sound)
        (cond
         ((fboundp 'play-sound-file)
          (condition-case err
              (play-sound-file sound)
            (error
             (message "AI alert sound failed: %s"
                      (error-message-string err)))))
         ((and agent-alert-sound-player
               (executable-find agent-alert-sound-player))
          (start-process "agent-alert-sound" nil
                         agent-alert-sound-player sound))
         (agent-alert-sound-player
          (message "AI alert sound player not found: %s"
                   agent-alert-sound-player))
         (t
          (message "No Emacs sound support or `agent-alert-sound-player'")))))))

;;;; Session state machine

(defun agent-session-event (buffer event)
  "Apply session EVENT to BUFFER's state machine.
EVENT is one of the symbols `stop', `idle-prompt', `blocked',
`submit', `activity', and `exit-request'.  A `blocked' event marks the
session as waiting on the user without firing a ready alert, for cases
where the backend has already alerted, such as a permission or input
dialog.  An `activity' event marks the session busy on evidence that it
is working, for backends whose CLI reports no turn start.
This function is the single owner of
`agent--session-state'; backends translate raw CLI events into
calls to it and never set session state directly.  A `submit'
event delivered while BUFFER is already busy is ignored, because
backend submission hooks can fire multiple times per submission
and on submissions that start no turn."
  (when (buffer-live-p buffer)
    (pcase event
      ((or 'stop 'idle-prompt 'blocked)
       (agent--session-event-awaiting-input buffer event))
      ((or 'submit 'activity)
       (unless (eq (buffer-local-value 'agent--session-state buffer) 'busy)
         (agent--session-set-state buffer 'busy)))
      ('exit-request
       (agent--session-set-state buffer 'closing))
      (_ (error "Unknown agent session event: %s" event)))))

(defun agent--session-event-awaiting-input (buffer event)
  "Transition BUFFER to `awaiting-input' and run the ready side effects.
EVENT is `stop', `idle-prompt', or `blocked'.  Completion events
advance the before-exit chain first; when it consumes the event,
the ready alert, scrolling, and display-name refresh are
suppressed.  A `blocked' event never advances the chain.  The
ready alert fires only for `idle-prompt' events."
  (agent--session-set-state buffer 'awaiting-input)
  (unless (and (memq event '(stop idle-prompt))
               (agent--before-exit-transition buffer 'step))
    (when (eq event 'idle-prompt)
      (agent--session-notify-ready buffer))
    (agent--scroll-to-bottom buffer)
    (agent--refresh-display-names-deferred)))

(defun agent--session-set-state (buffer state)
  "Set BUFFER's session state to STATE and record the transition time."
  (with-current-buffer buffer
    (setq agent--session-state state)
    (setq agent--session-state-changed-at (float-time))))

(defun agent--session-notify-ready (buffer)
  "Fire the ready alert for session BUFFER.
Dispatch through the backend's `:notify' function when one is
registered, falling back to `agent-notify'."
  (let* ((backend (agent--detect-backend buffer))
         (struct (and backend (agent-backend backend)))
         (label (or (and struct (agent-backend-label struct))
                    "Session"))
         (name (agent--buffer-session-name buffer))
         (notify (or (and struct (agent-backend-notify struct))
                     #'agent-notify)))
    (funcall notify
             (format "%s ready" label)
             (format "%s: waiting for your response" name))))

;;;###autoload
(defun agent-jump-to-waiting ()
  "Switch to the AI session that most recently started waiting for input."
  (interactive)
  (let (best-buf best-time)
    (dolist (buf (agent--find-all-buffers))
      (when (buffer-live-p buf)
        (let ((ts (and (agent--session-waiting-p buf)
                       (buffer-local-value 'agent--session-state-changed-at
                                           buf))))
          (when (and ts (or (null best-time) (> ts best-time)))
            (setq best-buf buf best-time ts)))))
    (if best-buf
        (switch-to-buffer best-buf)
      (message "No sessions waiting for input"))))

(defun agent-alert-indicator ()
  "Return a bell icon reflecting the current alert state."
  (if agent-alert-on-ready "🔔" "🔕"))

;;;; Scroll to bottom

(defun agent--scroll-to-bottom (buffer)
  "Scroll BUFFER and its windows to the terminal cursor."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (bound-and-true-p eat-terminal)
        (let ((cursor-pos (eat-term-display-cursor eat-terminal)))
          (goto-char cursor-pos)
          (dolist (window (get-buffer-window-list nil nil t))
            (set-window-point window cursor-pos)
            (with-selected-window window
              (goto-char cursor-pos)
              (recenter -1))))))))

;;;; Page scrolling

(defcustom agent-scroll-wheel-events 8
  "Number of terminal wheel events sent by one PageUp/PageDown press."
  :type 'natnum
  :group 'agent)

(defvar agent-scroll-keys-mode-map nil
  "Keymap for `agent-scroll-keys-mode'.")

(defvar agent-scroll-keys-global-mode-map nil
  "Obsolete global PageUp/PageDown keymap cleared during package load.")

(setq agent-scroll-keys-mode-map
      (let ((map (make-sparse-keymap)))
        (define-key map [prior] #'agent-scroll-page-up)
        (define-key map [next] #'agent-scroll-page-down)
        (define-key map [kp-prior] #'agent-scroll-page-up)
        (define-key map [kp-next] #'agent-scroll-page-down)
        (define-key map [remap scroll-down-command] #'agent-scroll-page-up)
        (define-key map [remap scroll-up-command] #'agent-scroll-page-down)
        map))

(define-minor-mode agent-scroll-keys-mode
  "Minor mode making PageUp and PageDown scroll AI terminal sessions."
  :keymap agent-scroll-keys-mode-map)

(define-minor-mode agent-scroll-keys-global-mode
  "Global mode redirecting scroll commands in selected AI terminals."
  :global t
  (if agent-scroll-keys-global-mode
      (agent--scroll-command-advice-add)
    (agent--scroll-command-advice-remove)))

(defun agent--clear-global-scroll-keymap ()
  "Remove obsolete global PageUp/PageDown bindings."
  (setq agent-scroll-keys-global-mode-map nil
        minor-mode-map-alist
        (assq-delete-all 'agent-scroll-keys-global-mode
                         minor-mode-map-alist)))

(agent--clear-global-scroll-keymap)

(defun agent-scroll-page-up ()
  "Scroll the current AI terminal session upward."
  (interactive)
  (agent--send-terminal-wheel 'wheel-up))

(defun agent-scroll-page-down ()
  "Scroll the current AI terminal session downward."
  (interactive)
  (agent--send-terminal-wheel 'wheel-down))

(defun agent--terminal-scroll-window-p (window)
  "Return non-nil when WINDOW displays an agent EAT terminal."
  (and (window-live-p window)
       (with-current-buffer (window-buffer window)
         (and (bound-and-true-p eat-terminal)
              (agent--detect-backend (current-buffer))))))

(defun agent--scroll-command-advice-add ()
  "Install scroll-command advice for agent terminal buffers."
  (unless (advice-member-p #'agent--scroll-down-command
                           'scroll-down-command)
    (advice-add 'scroll-down-command
                :around #'agent--scroll-down-command))
  (unless (advice-member-p #'agent--scroll-up-command
                           'scroll-up-command)
    (advice-add 'scroll-up-command
                :around #'agent--scroll-up-command)))

(defun agent--scroll-command-advice-remove ()
  "Remove scroll-command advice for agent terminal buffers."
  (advice-remove 'scroll-down-command #'agent--scroll-down-command)
  (advice-remove 'scroll-up-command #'agent--scroll-up-command))

(defun agent--scroll-down-command (original &rest args)
  "Send PageUp-like `scroll-down-command' calls to AI terminals.
ORIGINAL and ARGS describe the wrapped command call."
  (if-let* ((window (agent--scroll-command-redirect-window)))
      (agent--send-terminal-wheel 'wheel-up window)
    (apply original args)))

(defun agent--scroll-up-command (original &rest args)
  "Send PageDown-like `scroll-up-command' calls to AI terminals.
ORIGINAL and ARGS describe the wrapped command call."
  (if-let* ((window (agent--scroll-command-redirect-window)))
      (agent--send-terminal-wheel 'wheel-down window)
    (apply original args)))

(defun agent--scroll-command-redirect-window ()
  "Return the AI terminal window a scroll command should target."
  (let ((window (selected-window)))
    (and (agent--terminal-scroll-window-p window) window)))

(defun agent--send-terminal-wheel (event &optional window)
  "Send terminal mouse wheel EVENT to WINDOW or the current AI terminal."
  (let ((buffer (if window (window-buffer window) (current-buffer))))
    (with-current-buffer buffer
      (unless (bound-and-true-p eat-terminal)
        (user-error "Not in an EAT terminal session"))
      (let* ((window (or window
                         (get-buffer-window buffer t)
                         (selected-window)))
             (position (agent--terminal-wheel-position window)))
        (eat-self-input agent-scroll-wheel-events (list event position))))))

(defun agent--terminal-wheel-position (window)
  "Return a mouse position near the center of WINDOW."
  (or (posn-at-x-y (/ (max 1 (window-body-width window t)) 2)
                   (/ (max 1 (window-body-height window t)) 2)
                   window)
      (posn-at-x-y 10 10 window)))

;;;###autoload
(defun agent-setup-scroll-keys ()
  "Make PageUp and PageDown scroll the current AI terminal buffer."
  (interactive)
  (when (and (agent--detect-backend (current-buffer))
             (bound-and-true-p eat-terminal))
    (agent-scroll-keys-mode 1)
    (setq minor-mode-overriding-map-alist
          (assq-delete-all 'agent-scroll-keys-mode
                           minor-mode-overriding-map-alist))
    (push (cons 'agent-scroll-keys-mode agent-scroll-keys-mode-map)
          minor-mode-overriding-map-alist)))

(defun agent-setup-scroll-keys-in-existing-buffers ()
  "Make PageUp and PageDown scroll all existing AI terminal buffers."
  (dolist (buffer (agent--find-all-buffers))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (agent-setup-scroll-keys)))))

;;;; Terminal rendering fix

(defun agent-fix-rendering ()
  "Send SIGWINCH to fix terminal rendering after startup."
  (interactive)
  (when-let* ((proc (get-buffer-process (current-buffer))))
    (agent--send-sigwinch-after-delay (current-buffer))))

(defun agent--send-sigwinch-after-delay (buffer)
  "Send SIGWINCH to the process in BUFFER after a short delay."
  (run-at-time agent-sigwinch-delay nil
               #'agent--send-sigwinch buffer))

(defun agent--send-sigwinch (buffer)
  "Send SIGWINCH to the process in BUFFER."
  (when (buffer-live-p buffer)
    (when-let* ((proc (get-buffer-process buffer)))
      (signal-process proc 'SIGWINCH))))

;;;; Scrollback truncation fix

(defun agent-disable-scrollback-truncation ()
  "Disable eat's default scrollback limit for the current buffer.
Without this, eat truncates terminal output to
`eat-term-scrollback-size' lines, causing older AI session output
to vanish."
  (interactive)
  (when (bound-and-true-p eat-terminal)
    (if (fboundp 'eat-term-set-scrollback-size)
        (eat-term-set-scrollback-size eat-terminal most-positive-fixnum)
      (setq-local eat-term-scrollback-size nil))))

;;;; Escape key fix

(defun agent--send-escape-in-current-buffer (orig-fn)
  "When already in an AI buffer, send escape directly without prompting.
ORIG-FN is the original escape command."
  (if (agent--detect-backend (current-buffer))
      (when (bound-and-true-p eat-terminal)
        (eat-term-send-string eat-terminal (kbd "ESC")))
    (funcall orig-fn)))

;;;; Core send wrappers

(defun agent-send-string (string &optional buffer)
  "Insert STRING into session BUFFER's prompt without submitting it.
BUFFER defaults to the current session buffer, prompting for one
when the current buffer is not a session.  Emits a `submit'
session event before dispatching so stale waiting state clears."
  (agent--dispatch-send :send-string (list string) buffer))

(defun agent-submit (string &optional buffer)
  "Insert STRING into session BUFFER's prompt and submit it.
BUFFER defaults to the current session buffer.  Prefer the
backend's atomic `:submit'; fall back to `:send-string' followed
by `:send-return' when the backend registers none."
  (let* ((buf (agent--resolve-session-buffer buffer))
         (backend (agent--detect-backend buf))
         (struct (and backend (agent-backend backend))))
    (if (and struct (agent-backend-submit struct))
        (agent--dispatch-send :submit (list string) buf)
      (agent--dispatch-send :send-string (list string) buf)
      (when-let* ((send-return-fn (and struct
                                       (agent-backend-send-return struct))))
        (funcall send-return-fn buf)))))

(defun agent-send-return (&optional buffer)
  "Submit the pending prompt in session BUFFER.
BUFFER defaults to the current session buffer.  Emits a `submit'
session event before dispatching to the backend's `:send-return'."
  (agent--dispatch-send :send-return nil buffer))

(defun agent--dispatch-send (slot args buffer)
  "Emit a `submit' event for BUFFER and call its backend SLOT with ARGS.
SLOT is one of `:send-string', `:submit', and `:send-return'.
BUFFER is resolved with `agent--resolve-session-buffer' and
appended to ARGS."
  (let* ((buf (agent--resolve-session-buffer buffer))
         (backend (agent--detect-backend buf))
         (fn (when-let* ((struct (and backend (agent-backend backend))))
               (pcase slot
                 (:send-string (agent-backend-send-string struct))
                 (:submit (agent-backend-submit struct))
                 (:send-return (agent-backend-send-return struct))))))
    (unless fn
      (user-error "Backend `%s' does not support `%s'" backend slot))
    (agent-session-event buf 'submit)
    (apply fn (append args (list buf)))))

(defun agent--resolve-session-buffer (&optional buffer)
  "Return an AI session buffer from BUFFER, current context, or prompt."
  (cond
   ((and (buffer-live-p buffer)
         (agent--detect-backend buffer))
    buffer)
   ((agent--detect-backend (current-buffer))
    (current-buffer))
   (t
    (agent--read-session-buffer))))

(defun agent--read-session-buffer ()
  "Prompt for and return an active AI session buffer."
  (let ((buffers (agent--find-all-buffers)))
    (unless buffers
      (user-error "No AI sessions"))
    (if (= (length buffers) 1)
        (car buffers)
      (let* ((candidates
              (mapcar (lambda (buf)
                        (propertize (agent--session-candidate-label buf)
                                    'agent-buffer buf))
                      buffers))
             (choice (completing-read "Session: " candidates nil t)))
        (or (get-text-property 0 'agent-buffer choice)
            (get-text-property
             0 'agent-buffer
             (cl-find choice candidates :test #'string=)))))))

(defun agent--session-candidate-label (buffer)
  "Return a completion label for session BUFFER."
  (let* ((backend (agent--detect-backend buffer))
         (label (when-let* ((struct (and backend (agent-backend backend))))
                  (agent-backend-label struct)))
         (account (when-let* ((session (agent-session buffer)))
                    (agent-session-account session))))
    (string-join (delq nil (list label account (agent-display-name buffer)))
                 " ")))

;;;; Orchestration

(defun agent--resolve-backend ()
  "Return the backend for the current context.
If in a session buffer, use that backend.  If only one backend is
registered, use it.  Otherwise, prompt."
  (or (agent--detect-backend)
      (if (= (length agent-backends) 1)
          (caar agent-backends)
        (let* ((entries (mapcar (lambda (e)
                                  (cons (or (agent-backend-label (cdr e))
                                            (symbol-name (car e)))
                                        (car e)))
                                agent-backends))
               (labels (mapcar #'car entries))
               (affixate (lambda (cands)
                           (mapcar (lambda (c)
                                     (let* ((sym (cdr (assoc c entries)))
                                            (icon (agent-backend-icon-string
                                                   sym)))
                                       (list c
                                             (if (string-empty-p icon) ""
                                               (concat icon " "))
                                             "")))
                                   cands)))
               (choice (completing-read
                        "Backend: "
                        (lambda (str pred action)
                          (if (eq action 'metadata)
                              `(metadata (affixation-function . ,affixate))
                            (complete-with-action action labels str pred)))
                        nil t)))
          (cdr (assoc choice entries))))))

(defun agent--run-before-exit-functions (backend buffer)
  "Return non-nil if BACKEND session BUFFER should exit."
  (and (agent--confirm-no-captured-prompts backend buffer "Exit")
       (catch 'abort
         (dolist (fn agent-before-exit-functions t)
           (unless (funcall fn backend buffer)
             (throw 'abort nil))))))

(defun agent--confirm-no-captured-prompts (backend buffer action)
  "Confirm ACTION for BACKEND session BUFFER when captures are pending.
Return non-nil when ACTION may proceed.  Defer to `agent-capture' when
it is installed; otherwise allow ACTION, since no prompts can have
been captured without it."
  (if (require 'agent-capture nil t)
      (agent-capture-confirm-no-pending backend buffer action)
    t))

(defun agent-run-skill-before-exit (backend buffer)
  "Submit the before-exit skills for BUFFER before BACKEND exits it.
Member of `agent-before-exit-functions'.  Return nil to delay the
exit while the chain runs, and t when there is nothing to run."
  (with-current-buffer buffer
    (setq agent--backend backend))
  (not (agent--before-exit-transition buffer 'start)))

(defun agent--before-exit-transition (buffer event)
  "Advance the before-exit chain in BUFFER for EVENT.
EVENT is one of the symbols `start', `step', and `abort'.  This
function is the only writer of `agent--before-exit'.  Return
non-nil when the chain consumed the event."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (pcase event
        ('start (agent--before-exit-start buffer))
        ('step (agent--before-exit-step buffer))
        ('abort (agent--before-exit-abort buffer))
        (_ (error "Unknown before-exit event: %s" event))))))

(defun agent--before-exit-start (buffer)
  "Start the before-exit skill chain in BUFFER.
Return non-nil when a chain started and the exit must wait.
Return nil when a chain is already running, the buffer inhibits
the chain, no skill applies, or nothing could be submitted."
  (unless (or agent--before-exit agent-before-exit-skill-inhibit)
    (let* ((backend (agent--detect-backend buffer))
           (queue (agent--before-exit-skill-queue backend buffer)))
      (when queue
        (cl-pushnew #'agent--before-exit-teardown agent--teardown-functions)
        (setq agent--before-exit
              (list :queue queue
                    :state 'running
                    :started-at (float-time)
                    :timer (agent--before-exit-start-watchdog buffer)))
        (if (agent--before-exit-submit-next buffer)
            t
          (agent--before-exit-reset)
          nil)))))

(defun agent--before-exit-step (buffer)
  "Advance BUFFER's running before-exit chain on a stop event.
Submit the next queued skill, or schedule the exit once the queue
is drained.  When the backend's readiness veto applies, leave the
chain untouched so it is re-checked on the next stop event.
Return non-nil when the chain consumed the event."
  (when (eq (plist-get agent--before-exit :state) 'running)
    (let ((backend (agent--detect-backend buffer)))
      (when (agent--before-exit-ready-to-close-p backend buffer)
        (if (and (plist-get agent--before-exit :queue)
                 (agent--before-exit-submit-next buffer))
            (progn
              (agent--before-exit-restart-watchdog buffer)
              t)
          (agent--before-exit-close buffer backend))))))

(defun agent--before-exit-restart-watchdog (buffer)
  "Restart BUFFER's watchdog after its before-exit chain advances."
  (agent--before-exit-cancel-watchdog)
  (setq agent--before-exit
        (plist-put agent--before-exit :timer
                   (agent--before-exit-start-watchdog buffer))))

(defun agent--before-exit-abort (buffer)
  "Abandon BUFFER's before-exit chain, leaving the session open."
  (when agent--before-exit
    (agent--before-exit-reset)
    (message "agent: before-exit skills timed out in %s; leaving session open"
             (buffer-name buffer))
    t))

(defun agent--before-exit-close (buffer backend)
  "Mark BUFFER's chain as closing and schedule BACKEND's exit."
  (agent--before-exit-cancel-watchdog)
  (setq agent--before-exit (plist-put agent--before-exit :state 'closing))
  (agent-session-event buffer 'exit-request)
  (run-at-time 0 nil #'agent--exit-after-before-exit-skill backend buffer)
  t)

(defun agent--before-exit-submit-next (buffer)
  "Submit the next queued before-exit skill in BUFFER.
Skip entries that yield no command, and return non-nil when one
is submitted."
  (let ((backend (agent--detect-backend buffer))
        sent)
    (while (and (not sent) (plist-get agent--before-exit :queue))
      (let* ((queue (plist-get agent--before-exit :queue))
             (entry (car queue))
             (command (agent--before-exit-skill-command backend entry)))
        (setq agent--before-exit
              (plist-put agent--before-exit :queue (cdr queue)))
        (when command
          (agent-submit command buffer)
          (message "Started %s; this session will close when the before-exit skills finish"
                   command)
          (setq sent t))))
    sent))

(defun agent--before-exit-reset ()
  "Clear the current buffer's chain state and watchdog."
  (agent--before-exit-cancel-watchdog)
  (setq agent--before-exit nil))

(defun agent--before-exit-start-watchdog (buffer)
  "Return a timer that aborts BUFFER's chain after the timeout."
  (run-at-time agent-before-exit-timeout nil
               #'agent--before-exit-watchdog-fire buffer))

(defun agent--before-exit-watchdog-fire (buffer)
  "Abort the before-exit chain in BUFFER when the watchdog expires."
  (when (buffer-live-p buffer)
    (agent--before-exit-transition buffer 'abort)))

(defun agent--before-exit-cancel-watchdog ()
  "Cancel the current buffer's before-exit watchdog timer, if any."
  (when-let* ((timer (plist-get agent--before-exit :timer)))
    (cancel-timer timer)
    (setq agent--before-exit (plist-put agent--before-exit :timer nil))))

(defun agent--before-exit-teardown ()
  "Cancel the before-exit watchdog at session teardown.
Member of `agent--teardown-functions', registered when a chain
starts."
  (agent--before-exit-cancel-watchdog))

(defun agent--before-exit-ready-to-close-p (backend buffer)
  "Return non-nil when BUFFER can close after a before-exit skill.
BACKEND may veto closing while the submitted command is still
unaccepted at the prompt."
  (if-let* ((struct (agent-backend backend))
            (fn (agent-backend-before-exit-ready-to-close-p struct)))
      (funcall fn buffer)
    t))

(defun agent--exit-after-before-exit-skill (_backend buffer)
  "Exit the session in BUFFER without re-running before-exit hooks."
  (when (buffer-live-p buffer)
    (agent--exit-session buffer)))

(defun agent--before-exit-skill-queue (backend buffer)
  "Return the ordered before-exit skill entries applicable to BUFFER.
Return nil when BACKEND session BUFFER is too short-lived or no configured
entry matches its directory."
  (when (agent--before-exit-skill-duration-p backend buffer)
    (seq-filter
     (lambda (entry)
       (agent--before-exit-skill-directory-match-p
        backend buffer (agent--before-exit-skill-entry-directories entry)))
     (agent--before-exit-skill-entries))))

(defun agent--before-exit-skill-entries ()
  "Return the configured ordered before-exit skill entries.
Use `agent-before-exit-skill-names' when set; otherwise fall back to a
single-entry list built from `agent-before-exit-skill-name'."
  (or agent-before-exit-skill-names
      (and agent-before-exit-skill-name
           (not (string-empty-p agent-before-exit-skill-name))
           (list agent-before-exit-skill-name))))

(defun agent--before-exit-skill-entry-name (entry)
  "Return the skill-name string for before-exit ENTRY."
  (if (consp entry) (car entry) entry))

(defun agent--before-exit-skill-entry-directories (entry)
  "Return the directory restriction for before-exit ENTRY.
Fall back to `agent-before-exit-skill-directories' when ENTRY sets none."
  (or (and (consp entry) (plist-get (cdr entry) :directories))
      agent-before-exit-skill-directories))

(defun agent--before-exit-skill-entry-args (entry)
  "Return the extra command-argument string for before-exit ENTRY, or nil."
  (and (consp entry) (plist-get (cdr entry) :args)))

(defun agent--before-exit-skill-directory-match-p (backend buffer directories)
  "Return non-nil if BACKEND session BUFFER lies within DIRECTORIES.
A nil DIRECTORIES matches every session."
  (or (null directories)
      (when-let* ((directory (agent--buffer-directory backend buffer)))
        (cl-some (lambda (candidate)
                   (file-in-directory-p directory (file-truename candidate)))
                 directories))))

(defun agent--before-exit-skill-duration-p (backend buffer)
  "Return non-nil if BACKEND session BUFFER is old enough."
  (let* ((duration-ms-fn (when-let* ((struct (agent-backend backend)))
                           (agent-backend-duration-ms struct)))
         (duration-ms (when duration-ms-fn
                        (funcall duration-ms-fn buffer))))
    (or (not agent-before-exit-skill-min-duration-seconds)
        (<= agent-before-exit-skill-min-duration-seconds 0)
        (not duration-ms-fn)
        (not duration-ms)
        (>= duration-ms (* agent-before-exit-skill-min-duration-seconds
                           1000)))))

(defun agent--buffer-directory (_backend buffer)
  "Return the normalized directory for BUFFER's session.
_BACKEND is unused; the directory comes from BUFFER's
`agent-session' struct."
  (when-let* ((session (agent-session buffer))
              (directory (agent-session-directory session)))
    (file-name-as-directory (file-truename directory))))

(defun agent--before-exit-skill-command (backend entry)
  "Return the interactive command string for before-exit ENTRY on BACKEND.
Append ENTRY's `:args' when present."
  (when-let* ((struct (agent-backend backend))
              (prefix (agent-backend-skill-command-prefix struct)))
    (let ((args (agent--before-exit-skill-entry-args entry)))
      (concat prefix (agent--before-exit-skill-entry-name entry)
              (and args (concat " " args))))))

(defun agent--skill-argument-candidates (skill)
  "Return completion candidates for SKILL's arguments.
SKILL is a plist.  If the skill has an :argument-source glob,
resolve it relative to the skill's directory and return file stems.
If it has :argument-choices, return those.  Otherwise return nil."
  (or (when-let* ((source (plist-get skill :argument-source))
                  (skill-dir (file-name-directory (plist-get skill :path))))
        (let ((pattern (expand-file-name source skill-dir)))
          (mapcar (lambda (f)
                    (file-name-sans-extension (file-name-nondirectory f)))
                  (file-expand-wildcards pattern))))
      (plist-get skill :argument-choices)))

(defun agent-parse-skill-frontmatter (file)
  "Parse skill frontmatter from FILE and return a plist.
Recognizes :name, :description, :argument-hint, :argument-source,
:argument-choices, :argument-default, :argument-multiple,
:user-invocable, and :model."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (when (looking-at-p "---")
      (forward-line 1)
      (let ((start (point))
            (result nil))
        (when (re-search-forward "^---$" nil t)
          (dolist (line (split-string
                         (buffer-substring-no-properties
                          start (line-beginning-position))
                         "\n" t))
            (when (string-match "^\\([a-z0-9_-]+\\): *\\(.*\\)$" line)
              (setq result
                    (agent--put-skill-frontmatter-field
                     result
                     (match-string 1 line)
                     (agent--clean-skill-frontmatter-value
                      (match-string 2 line)))))))
        result))))

(defun agent--clean-skill-frontmatter-value (value)
  "Return normalized frontmatter VALUE."
  (let ((val (string-trim value)))
    (if (string-match "^[\"']\\(.*\\)[\"']$" val)
        (match-string 1 val)
      val)))

(defun agent--put-skill-frontmatter-field (plist key value)
  "Return PLIST with frontmatter KEY set to VALUE when recognized."
  (pcase key
    ("name" (plist-put plist :name value))
    ("description" (plist-put plist :description value))
    ("argument-hint" (plist-put plist :argument-hint value))
    ("argument-source" (plist-put plist :argument-source value))
    ("argument-choices"
     (plist-put plist :argument-choices
                (mapcar #'string-trim (split-string value "," t))))
    ("argument-default" (plist-put plist :argument-default value))
    ("argument-multiple"
     (plist-put plist :argument-multiple
                (not (string= (downcase value) "false"))))
    ("user-invocable"
     (plist-put plist :user-invocable
                (not (string= (downcase value) "false"))))
    ("model" (plist-put plist :model value))
    (_ plist)))

(defun agent--discover-all-skills ()
  "Discover user-invocable skills from all registered backends.
Calls `agent-discover-skills' for each backend, filters out skills
marked `user-invocable: false', and returns a combined list of
skill plists, each augmented with `:backend'."
  (let (all-skills)
    (dolist (entry agent-backends)
      (dolist (skill (agent-discover-skills (car entry)))
        (unless (and (plist-member skill :user-invocable)
                     (not (plist-get skill :user-invocable)))
          (push (plist-put (copy-sequence skill) :backend (car entry))
                all-skills))))
    (sort all-skills (lambda (a b)
                       (string< (plist-get a :name) (plist-get b :name))))))

(defun agent--skill-candidate (skill)
  "Return a unique completion candidate for SKILL."
  (let* ((backend (plist-get skill :backend))
         (label (or (when-let* ((struct (agent-backend backend)))
                      (agent-backend-label struct))
                    (symbol-name backend))))
    (propertize (format "%s [%s]" (plist-get skill :name) label)
                'agent-skill skill)))

(defun agent--skill-candidates (skills)
  "Return completion candidates for SKILLS with embedded skill plists."
  (mapcar #'agent--skill-candidate skills))

(defun agent--skill-from-candidate (candidate candidates)
  "Return the skill plist for CANDIDATE from CANDIDATES."
  (or (get-text-property 0 'agent-skill candidate)
      (get-text-property 0 'agent-skill
                         (cl-find candidate candidates :test #'string=))))

;;;###autoload
(defun agent-handoff (&optional buffer-name)
  "Close the current session and start a new one with the handoff prompt.
The /handoff skill must have been run first to write the handoff
file.  BUFFER-NAME optionally names the source session buffer; it
defaults to the current buffer.  The new session starts in the
same directory with the same account and the handoff contents
passed as the initial prompt."
  (interactive)
  (let* ((source (agent--handoff-source-buffer buffer-name))
         (session (agent--handoff-session source))
         (backend (agent-session-backend session))
         (prompt (agent--read-handoff-file (agent--handoff-file backend))))
    (when (and source
               (not (agent--confirm-no-captured-prompts
                     backend source "Handoff")))
      (user-error "Handoff aborted"))
    (agent--kill-handoff-source backend source
                                (agent-session-directory session))
    (agent-start-session session :initial-prompt prompt)))

(defun agent--handoff-source-buffer (buffer-name)
  "Return the session buffer named BUFFER-NAME, or the current buffer.
Return nil when neither names a live session buffer."
  (cond
   ((and buffer-name (not (string-empty-p buffer-name)))
    (let ((buffer (get-buffer buffer-name)))
      (unless buffer
        (user-error "No session buffer named `%s'" buffer-name))
      (unless (agent--detect-backend buffer)
        (user-error "Buffer `%s' is not an AI session" buffer-name))
      buffer))
   ((agent--detect-backend (current-buffer))
    (current-buffer))))

(defun agent--handoff-session (source)
  "Return the session to hand off to, derived from SOURCE.
Without a SOURCE buffer, build a session for a prompted backend in
`default-directory'."
  (if source
      (agent-session source)
    (agent-session-create :backend (agent--resolve-backend)
                          :directory default-directory)))

(defun agent--handoff-file (backend)
  "Return the handoff file configured for BACKEND."
  (or (alist-get backend agent-handoff-files)
      (user-error "No handoff file configured for backend `%s'" backend)))

(defun agent--read-handoff-file (file)
  "Return the trimmed contents of handoff FILE, validating it."
  (unless (file-exists-p file)
    (user-error "No handoff file at %s — run /handoff first" file))
  (let ((prompt (with-temp-buffer
                  (insert-file-contents file)
                  (string-trim (buffer-string)))))
    (when (string-empty-p prompt)
      (user-error "Handoff file is empty — run /handoff first"))
    prompt))

(defun agent--kill-handoff-source (backend source dir)
  "Kill SOURCE, or the single existing BACKEND buffer in DIR.
The fallback handles emacsclient invocations that reach Emacs
without the requesting buffer name; leaving that buffer alive
would trigger an instance-name prompt and break unattended loops."
  (when-let* ((target (or source
                          (agent--single-session-buffer-for-dir backend dir))))
    (with-current-buffer target
      (setq-local agent-before-exit-skill-inhibit t))
    (agent--force-kill-buffer target)))

(defun agent--single-session-buffer-for-dir (backend dir)
  "Return the only BACKEND session buffer for DIR, or signal on ambiguity."
  (let* ((find-fn (when-let* ((struct (agent-backend backend)))
                    (agent-backend-find-buffers-for-dir struct)))
         (buffers (and find-fn (funcall find-fn dir))))
    (pcase buffers
      ('nil nil)
      (`(,buffer) buffer)
      (_ (user-error "Multiple sessions already exist for %s"
                     (abbreviate-file-name dir))))))

(defvar server-eval-args-left)

;;;###autoload
(defun agent-handoff-from-emacsclient ()
  "Run `agent-handoff' for the client-provided buffer name.
The first value in `server-eval-args-left' is treated as the
session buffer that requested the handoff."
  (interactive)
  (let ((buffer-name (car server-eval-args-left)))
    (setq server-eval-args-left nil)
    (agent-handoff buffer-name)))

;;;###autoload
(defun agent-run-skill ()
  "Discover and run a skill from any registered backend.
Shows an aggregated list of all skills with an indication of
the backend next to each."
  (interactive)
  (let* ((skills (agent--discover-all-skills))
         (_ (unless skills (user-error "No user-invocable skills found")))
         (skill-candidates (agent--skill-candidates skills))
         (max-cand-len (apply #'max (mapcar #'length skill-candidates)))
         (annotate
          (lambda (cand)
            (when-let* ((skill (agent--skill-from-candidate
                                cand skill-candidates)))
              (let ((desc (or (plist-get skill :description) "")))
                (concat (make-string (- (+ max-cand-len 2) (length cand)) ?\s)
                        (propertize desc 'face 'completions-annotations))))))
         (candidate (completing-read
                     "Skill: "
                     (lambda (str pred action)
                       (if (eq action 'metadata)
                           `(metadata (annotation-function . ,annotate))
                         (complete-with-action
                          action skill-candidates str pred)))
                     nil t))
         (skill (agent--skill-from-candidate candidate skill-candidates))
         (backend (plist-get skill :backend))
         ;; Prompt for arguments using skill metadata
         (hint (plist-get skill :argument-hint))
         (candidates (agent--skill-argument-candidates skill))
         (default (plist-get skill :argument-default))
         (multiple-p (plist-get skill :argument-multiple))
         (args (cond
                ((and candidates multiple-p)
                 (let ((selected (completing-read-multiple
                                  (format "Arguments %s: " (or hint ""))
                                  candidates)))
                   (when selected (string-join selected " "))))
                (candidates
                 (let ((selected (completing-read
                                  (format "Arguments%s: "
                                          (cond
                                           ((and hint default)
                                            (format " %s (default %s)" hint default))
                                           (hint (format " %s" hint))
                                           (default (format " (default %s)" default))
                                           (t "")))
                                  candidates nil nil nil nil default)))
                   (unless (string-empty-p selected) selected)))
                (hint
                 (let ((input (read-string (format "Arguments %s: " hint))))
                   (unless (string-empty-p input) input))))))
    (agent--run-skill backend skill args)))

(defun agent--run-skill (backend skill arguments)
  "Run SKILL plist with ARGUMENTS through BACKEND's run-prompt slot."
  (let ((run (or (when-let* ((struct (agent-backend backend)))
                   (agent-backend-run-prompt struct))
                 (user-error "Backend `%s' does not register run-prompt"
                             backend)))
        (name (plist-get skill :name)))
    (message "Running skill %s..." name)
    (funcall run (agent--skill-prompt skill arguments)
             :directory default-directory
             :callback
             (cl-function
              (lambda (text &key error)
                (agent--display-skill-result name text error))))))

(defun agent--skill-prompt (skill arguments)
  "Return the CLI prompt for SKILL plist with ARGUMENTS.
Skills from `slash' roots use the backend CLI's native slash
expansion; skills from `file' roots point the CLI at the skill
file directly."
  (let ((name (plist-get skill :name))
        (args (and arguments (not (string-empty-p arguments)) arguments)))
    (if (eq (plist-get skill :style) 'slash)
        (if args (format "/%s %s" name args) (format "/%s" name))
      (format (string-join
               '("Run the skill `%s`%s."
                 ""
                 "Skill file: %s"
                 ""
                 "Read the skill file first and follow its instructions exactly."
                 "Resolve relative paths mentioned by the skill relative to the skill file's directory.%s")
               "\n")
              name
              (if args (format " with these arguments: %s" args) "")
              (plist-get skill :path)
              (if args (format "\n\nArguments: %s" args) "")))))

(defun agent--display-skill-result (name text error)
  "Display skill NAME output TEXT, noting ERROR when non-nil."
  (let ((buf (get-buffer-create (format "*Agent skill: %s*" name))))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "#+title: %s — %s\n" name
                        (format-time-string "%Y-%m-%d %H:%M:%S")))
        (when error
          (insert (format "#+error: %s\n" error)))
        (insert "\n")
        (insert (or text "(no output)"))
        (unless (string-suffix-p "\n" (or text "")) (insert "\n")))
      (org-mode)
      (goto-char (point-min)))
    (pop-to-buffer buf)
    (message "Skill %s %s" name (if error (format "failed: %s" error) "complete"))))

(defun agent-discover-skills (backend)
  "Discover all skills for BACKEND from its registered skill roots.
Return a list of skill plists with :name, :description, :path,
:style, and the argument metadata recognized by
`agent-parse-skill-frontmatter'.  Later roots shadow earlier ones."
  (let ((roots-fn (when-let* ((struct (agent-backend backend)))
                    (agent-backend-skill-roots struct)))
        (skills (make-hash-table :test #'equal)))
    (dolist (root (and roots-fn (funcall roots-fn)))
      (let ((dir (car root))
            (style (cdr root)))
        (when (file-directory-p dir)
          (dolist (file (file-expand-wildcards
                         (expand-file-name "*/SKILL.md" dir)))
            (when-let* ((meta (agent-parse-skill-frontmatter file))
                        (name (plist-get meta :name)))
              (puthash name (append meta (list :path file :style style))
                       skills))))))
    (let (result)
      (maphash (lambda (_name skill) (push skill result)) skills)
      (sort result (lambda (a b)
                     (string< (plist-get a :name) (plist-get b :name)))))))

;;;###autoload
(defun agent-post-push-ci (&optional commit)
  "Run the post-push CI closeout skill for COMMIT.
When COMMIT is nil, use the current Git HEAD."
  (interactive)
  (let* ((backend (agent--resolve-backend))
         (skill (or (cl-find "post-push-ci" (agent-discover-skills backend)
                             :key (lambda (s) (plist-get s :name))
                             :test #'equal)
                    (user-error "Skill `post-push-ci' not found for `%s'"
                                backend)))
         (sha (or commit (agent--git-head))))
    (agent--run-skill backend skill
                      (format "--no-push --commit %s" sha))))

(defun agent--git-head ()
  "Return the current Git HEAD SHA."
  (with-temp-buffer
    (unless (zerop (process-file "git" nil t nil "rev-parse" "HEAD"))
      (user-error "Could not resolve Git HEAD"))
    (string-trim (buffer-string))))

;;;###autoload
(defun agent-trajectory-new-task (slug)
  "Create a Trajectory reasoning-tasks worktree for SLUG.
SLUG must be the exact task slug and a single path component.  The
new worktree is created at
`agent-trajectory-reasoning-tasks-root'/SLUG on branch pablo/SLUG
from origin/main, then wired to the canonical Rubric Studio
`.claude/.env' symlink, and sparse-checked-out to
`.claude'/`meta'/`platform' so the checkout stays small instead of
materializing the whole repo's task corpus.  Finally, run
`agent-trajectory-sync-worktree-script' in the new worktree so it
gets the same local instruction overlay, key link and private
skills as any later session start."
  (interactive (list (agent-trajectory--read-task-slug)))
  (let* ((slug (agent-trajectory--validate-task-slug slug))
         (root (agent-trajectory--root-directory))
         (target (expand-file-name slug root)))
    (agent-trajectory--git root "fetch" "origin" "main")
    (agent-trajectory--git root "worktree" "add" target
                           "-b" (concat "pablo/" slug) "origin/main")
    (agent-trajectory--link-task-key root target)
    (agent-trajectory--sparse-task-worktree target)
    (agent-trajectory--sync-worktree target)
    (dired target)
    (message "Ready: cd %s && claude-trajectory" target)
    target))

(defun agent-trajectory--read-task-slug ()
  "Read a Trajectory reasoning-tasks slug from the minibuffer."
  (agent-trajectory--validate-task-slug
   (read-string "Task slug: ")))

(defun agent-trajectory--root-directory ()
  "Return the Trajectory reasoning-tasks worktree root directory."
  (file-name-as-directory
   (expand-file-name
    (or (agent-trajectory--legacy-custom-directory
         'agent-trajectory-agent-c-root
         agent-trajectory--legacy-agent-c-root-default)
        agent-trajectory-reasoning-tasks-root))))

(defun agent-trajectory--validate-task-slug (slug)
  "Return normalized task SLUG, or signal if it is unsafe."
  (let ((slug (string-trim (or slug ""))))
    (unless (string-match-p "\\`[[:alnum:]][[:alnum:]_-]*\\'" slug)
      (user-error "Task slug must be a single path component"))
    slug))

(defun agent-trajectory--git (root &rest args)
  "Run git in ROOT's main worktree with ARGS."
  (let ((default-directory (expand-file-name "main/" root)))
    (with-temp-buffer
      (let ((exit (apply #'process-file "git" nil (current-buffer) nil args)))
        (unless (zerop exit)
          (user-error "Git failed in %s: git %s\n%s"
                      default-directory
                      (string-join args " ")
                      (string-trim (buffer-string))))))))

(defun agent-trajectory--link-task-key (root target)
  "Link TARGET's `.claude/.env' to the canonical key under ROOT."
  (let* ((claude-dir (expand-file-name ".claude" target))
         (link (expand-file-name ".env" claude-dir))
         (key (expand-file-name "reasoning-tasks-cr-studio/.claude/.env" root)))
    (make-directory claude-dir t)
    (when (or (file-exists-p link) (file-symlink-p link))
      (user-error "Refusing to overwrite existing key link: %s" link))
    (make-symbolic-link key link)))

(defun agent-trajectory--sparse-task-worktree (target)
  "Sparse-checkout TARGET to the directories a CR task worktree needs.
Keep `.claude', `meta' and `platform' (root files stay too), dropping
the rest of the repo's large task corpus; the new task's own files are
created under `tasks/' as work proceeds.  Best-effort: a failure is
reported but does not abort task creation."
  (let ((default-directory (file-name-as-directory target)))
    (condition-case err
        (agent-trajectory--git-command
         "sparse-checkout" "set" ".claude" "meta" "platform")
      (error
       (message "agent-trajectory: sparse-checkout skipped (%s)"
                (error-message-string err))))))

(defun agent-trajectory--sync-worktree (target)
  "Run the reasoning-tasks sync hook script in TARGET.
Delegates to `agent-trajectory-sync-worktree-script', the single
source of truth for the local instruction overlay.  Best-effort: a
failure is reported but does not abort task creation, since the same
script re-runs on every session start."
  (let ((script (expand-file-name agent-trajectory-sync-worktree-script))
        (default-directory (file-name-as-directory target)))
    (if (file-readable-p script)
        (agent-trajectory--run-sync-script script)
      (message "agent-trajectory: worktree sync skipped (unreadable %s)"
               script))))

(defun agent-trajectory--run-sync-script (script)
  "Run sync SCRIPT in `default-directory', reporting failure.
Passes SYNC_REASONING_TASKS_SKIP_FETCH=1 because the caller just
fetched, and points CLAUDE_PROJECT_DIR at the worktree so the script
acts on it rather than on any inherited project directory."
  (let ((process-environment
         (append (list "SYNC_REASONING_TASKS_SKIP_FETCH=1"
                       (concat "CLAUDE_PROJECT_DIR="
                               (directory-file-name default-directory)))
                 process-environment)))
    (with-temp-buffer
      (unless (zerop (process-file "bash" nil (current-buffer) nil script))
        (message "agent-trajectory: worktree sync failed\n%s"
                 (string-trim (buffer-string)))))))

(defun agent-trajectory--legacy-custom-directory (symbol old-default)
  "Return obsolete SYMBOL's directory if it differs from OLD-DEFAULT."
  (when (and (boundp symbol)
             (stringp (symbol-value symbol)))
    (let ((value (file-name-as-directory
                  (expand-file-name (symbol-value symbol))))
          (default (file-name-as-directory
                    (expand-file-name old-default))))
      (unless (equal value default)
        (symbol-value symbol)))))

(defun agent-trajectory--git-command (&rest args)
  "Run git with ARGS in `default-directory'."
  (with-temp-buffer
    (let ((exit (apply #'process-file "git" nil (current-buffer) nil args)))
      (unless (zerop exit)
        (user-error "Git failed in %s: git %s\n%s"
                    default-directory
                    (string-join args " ")
                    (string-trim (buffer-string)))))))

;;;###autoload
(defun agent-audit-project ()
  "Run a comprehensive project audit via the selected backend.
Sequentially runs each skill in `agent-audit-skills' with
`--accept' through the backend's run-prompt slot, auto-committing
after each successful skill, and displays a summary when done."
  (interactive)
  (let* ((backend (agent--resolve-backend))
         (dir (agent--read-audit-directory)))
    (when (yes-or-no-p
           (format "Run %d audit(s) on %s?" (length agent-audit-skills) dir))
      (agent--audit-ensure-clean-worktree dir)
      (agent--audit-run-next
       (list :backend backend :queue agent-audit-skills :results nil
             :dir dir :start-time (current-time))))))

(defun agent--audit-run-next (state)
  "Run the next audit skill in STATE, or finish."
  (if (null (plist-get state :queue))
      (agent--audit-finish state)
    (let* ((backend (plist-get state :backend))
           (queue (plist-get state :queue))
           (name (string-remove-prefix "/" (car queue)))
           (skill (or (cl-find name (agent-discover-skills backend)
                               :key (lambda (s) (plist-get s :name))
                               :test #'equal)
                      (list :name name :style 'slash)))
           (run (or (when-let* ((struct (agent-backend backend)))
                      (agent-backend-run-prompt struct))
                    (user-error "Backend `%s' does not support run-prompt"
                                backend))))
      (message "Running audit %s..." name)
      (funcall run (agent--skill-prompt skill "--accept")
               :directory (plist-get state :dir)
               :callback
               (cl-function
                (lambda (text &key error)
                  (plist-put state :results
                             (cons (list :skill name :text text :error error)
                                   (plist-get state :results)))
                  (plist-put state :queue (cdr queue))
                  (unless error
                    (ignore-errors
                      (agent--audit-commit-changes (plist-get state :dir) name)))
                  (agent--audit-run-next state)))))))

(defun agent--audit-finish (state)
  "Display the audit results from STATE."
  (let* ((results (reverse (plist-get state :results)))
         (total (length results))
         (successes (cl-count-if (lambda (result)
                                   (null (plist-get result :error)))
                                 results))
         (failures (- total successes))
         (duration (float-time
                    (time-subtract (current-time)
                                   (plist-get state :start-time))))
         (buf (get-buffer-create "*Agent audit results*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "#+title: Agent audit results — %s\n\n"
                        (format-time-string "%Y-%m-%d %H:%M:%S")))
        (insert (format "- Directory: [[file:%s]]\n" (plist-get state :dir)))
        (insert (format "- Total: %d | Success: %d | Failed: %d\n" total successes failures))
        (insert (format "- Time: %.1f seconds\n\n" duration))
        (dolist (result results)
          (insert (format "* %s %s\n"
                          (if (plist-get result :error) "FAIL" "DONE")
                          (plist-get result :skill)))
          (insert (format ":PROPERTIES:\n:ERROR: %s\n:END:\n\n"
                          (or (plist-get result :error) "none")))
          (insert "#+begin_example\n")
          (insert (or (plist-get result :text) "(no output)"))
          (unless (string-suffix-p "\n" (or (plist-get result :text) ""))
            (insert "\n"))
          (insert "#+end_example\n\n")))
      (org-mode)
      (goto-char (point-min)))
    (pop-to-buffer buf)
    (message "Agent audit complete: %d/%d succeeded (%.1fs)"
             successes total duration)))

(defun agent--audit-commit-changes (dir title)
  "Commit uncommitted work in DIR after an audit skill completes.
TITLE is the skill name, used to derive the commit message scope."
  (let ((default-directory dir))
    (with-temp-buffer
      (call-process "git" nil t nil "status" "--porcelain")
      (when (> (buffer-size) 0)
        (call-process "git" nil nil nil "add" "-A")
        (let ((scope (replace-regexp-in-string
                      "^/" ""
                      (car (split-string title " ")))))
          (call-process "git" nil nil nil "commit" "-m"
                        (format "%s: apply audit recommendations" scope)))))))

(defun agent--read-audit-directory ()
  "Prompt for a project directory with completion."
  (let* ((candidates (mapcar #'abbreviate-file-name
                             agent-audit-project-directories))
         (input (completing-read "Project directory: " candidates nil nil))
         (dir (file-truename (expand-file-name input))))
    (unless (file-directory-p dir)
      (user-error "Not a directory: %s" dir))
    (unless (member dir (mapcar #'file-truename
                                agent-audit-project-directories))
      (customize-save-variable 'agent-audit-project-directories
                               (append agent-audit-project-directories
                                       (list dir))))
    dir))

(defun agent--audit-ensure-clean-worktree (dir)
  "Signal a user error unless DIR is a clean git worktree."
  (let ((default-directory dir))
    (with-temp-buffer
      (let ((exit (call-process "git" nil t nil
                                "status" "--porcelain")))
        (cond
         ((not (zerop exit))
          (user-error "Cannot inspect git worktree in %s: %s"
                      dir (string-trim (buffer-string))))
         ((> (buffer-size) 0)
          (user-error
           "Refusing audit auto-commit because %s has uncommitted changes"
           dir)))))))

;;;###autoload
(defun agent-debug-backtrace (&optional existing)
  "Route the backtrace in the current buffer to an AI session.
Save it to `agent-backtrace-file', ask `gptel' which packages the
backtrace implicates, let the user pick one, and start a session in that
package's source directory with instructions to read the saved backtrace
and fix the bug.  With prefix argument EXISTING send those instructions
to a running session instead."
  (interactive "P")
  (agent--act-on-context #'agent--backtrace-context existing))

(defun agent--backtrace-context (callback)
  "Call CALLBACK with the context for the backtrace in this buffer.
Saving the backtrace kills its buffer, which exits the debugger's
`recursive-edit' and unwinds this frame, so identification is scheduled
to run after the current command rather than called here."
  (let ((file (expand-file-name agent-backtrace-file)))
    (run-with-timer 0 nil #'agent--backtrace-context-for-file file callback)
    (agent-save-backtrace)))

(defconst agent--backtrace-prompt
  "Read the backtrace at %s. Identify the bug, fix it, and commit the fix."
  "Prompt submitted for a saved backtrace, formatted with its file path.")

(defun agent--backtrace-context-for-file (file callback)
  "Identify the package for FILE and call CALLBACK with its context."
  (agent--debug-read-package-directory
   file
   (lambda (directory)
     (funcall callback
              (list :directory directory
                    :payload (format agent--backtrace-prompt file)
                    :submit t)))))

;;;###autoload
(defun agent-save-backtrace ()
  "Save the current Emacs backtrace and return its file path."
  (interactive)
  (unless (string-match-p "\\*Backtrace\\*" (buffer-name))
    (user-error "Not in a backtrace buffer"))
  (let ((file (expand-file-name agent-backtrace-file))
        (contents (buffer-string)))
    (make-directory (file-name-directory file) t)
    (with-temp-buffer
      (insert contents)
      (write-region (point-min) (point-max) file nil 'silent))
    (kill-new file)
    (kill-buffer)
    (message "Backtrace saved to %s" (abbreviate-file-name file))
    file))

(defun agent--package-source-directory (package)
  "Return a source directory for PACKAGE, or nil."
  (or (when-let* ((entry (and (fboundp 'elpaca-get) (elpaca-get package)))
                  ((fboundp 'elpaca-source-dir)))
        (elpaca-source-dir entry))
      (when (require 'find-func nil t)
        (condition-case nil
            (file-name-directory (find-library-name (symbol-name package)))
          (error nil)))))

(defvar gptel-backend)
(defvar gptel-include-reasoning)
(defvar gptel-model)
(defvar gptel-use-tools)
(defvar gptel--known-backends)
(declare-function gptel-request "gptel")

(defun agent--gptel-response-text (response)
  "Return final text from gptel RESPONSE, or nil.
Custom gptel callbacks may receive non-text events such as
reasoning blocks before the final response."
  (when (stringp response)
    response))

(defun agent--debug-read-package-directory (backtrace-file callback)
  "Identify candidate packages from BACKTRACE-FILE and let the user choose.
Ask a light LLM to list all packages implicated in the backtrace,
then present the list via `completing-read' and call CALLBACK with the
source directory of the package the user selects."
  (unless (file-exists-p backtrace-file)
    (user-error "Backtrace file not found: %s" backtrace-file))
  (unless (and (require 'gptel nil t) (fboundp 'gptel-request))
    (user-error "Package `gptel' is required for backtrace debugging"))
  (message "Identifying packages from backtrace...")
  (let ((contents (agent--debug-backtrace-excerpt
                   (with-temp-buffer
                     (insert-file-contents backtrace-file)
                     (buffer-string))))
        (gptel-backend (alist-get agent-debug-backtrace-backend
                                  gptel--known-backends nil nil #'string=))
        (gptel-model agent-debug-backtrace-model)
        (gptel-include-reasoning nil)
        (gptel-use-tools nil))
    (gptel-request
     (format "Backtrace file: %s\n\nContents:\n%s" backtrace-file contents)
     :system "You are an Emacs expert. Given the backtrace, identify ALL Emacs packages that appear in the stack trace and could be the root cause of the error. Return ONLY a comma-separated list of package names, ordered from most likely root cause to least likely. For example: \"org-roam, org, emacsql\" or \"magit, transient, with-editor\"."
     :callback
     (lambda (response info)
       (if (not response)
           (message "gptel request failed: %s" (plist-get info :status))
         (when-let* ((text (agent--gptel-response-text response)))
           (let* ((candidates (mapcar #'string-trim
                                      (split-string text ",")))
                  (selected
                   (completing-read "Package to debug: " candidates nil
                                    nil nil nil (car candidates)))
                  (directory (or (agent--package-source-directory
                                  (intern selected))
                                 (user-error "Package `%s' not found"
                                             selected))))
             (funcall callback directory))))))))

(defconst agent--debug-backtrace-line-limit 400
  "Maximum characters kept per backtrace line sent to the model.")

(defconst agent--debug-backtrace-size-limit 100000
  "Maximum total characters of backtrace contents sent to the model.")

(defun agent--debug-backtrace-excerpt (contents)
  "Return backtrace CONTENTS truncated to fit within model request limits.
Backtraces can embed multi-megabyte printed objects in single frames,
which makes the identification request exceed API payload limits.  The
frame names at the start of each line are all the model needs, so long
lines are cut at `agent--debug-backtrace-line-limit' and the result is
capped at `agent--debug-backtrace-size-limit'."
  (let* ((lines (split-string contents "\n"))
         (trimmed (mapcar #'agent--debug-truncate-line lines))
         (joined (string-join trimmed "\n")))
    (if (> (length joined) agent--debug-backtrace-size-limit)
        (substring joined 0 agent--debug-backtrace-size-limit)
      joined)))

(defun agent--debug-truncate-line (line)
  "Return LINE cut at `agent--debug-backtrace-line-limit' characters."
  (if (> (length line) agent--debug-backtrace-line-limit)
      (concat (substring line 0 agent--debug-backtrace-line-limit)
              " [truncated]")
    line))

;;;###autoload
(defun agent-act-on-thing-at-point (&optional existing)
  "Route the thing at point to an AI session.
Start a new session for it, or with prefix argument EXISTING send it to
a running session chosen by completion.  The thing is the first entry
in `agent-at-point-things' whose predicate matches: a backtrace, a
Slack message, a Forge notification or topic, an email, or an org
TODO."
  (interactive "P")
  (agent--act-on-context
   (or (agent--extractor-at-point)
       (user-error "Nothing to act on at point; expected a backtrace, a Slack message, a Forge notification or topic, an email, or an org TODO"))
   existing))

(defvar agent-at-point-things
  '((agent--backtrace-at-point-p . agent--backtrace-context)
    (agent--slack-message-at-point-p . agent-slack-context)
    (agent--forge-topic-at-point-p . agent-forge-context)
    (agent--mu4e-message-at-point-p . agent-mu4e-context)
    (agent--org-todo-at-point-p . agent-todo-context))
  "Things `agent-act-on-thing-at-point' recognizes, in order.
Each entry is a cons of a predicate called with no arguments in the
current buffer and an extractor called with one continuation.  Every
predicate answers from the buffer alone, without loading the module
that owns its extractor.

An extractor calls its continuation with a context plist: `:directory'
when the thing carries a working directory, as an absolute path,
`:text' when it carries only text for a project to be chosen from,
`:payload' for what to send, `:submit' for whether to submit it, and an
optional `:after' thunk run once the payload is delivered, in the
buffer the command was invoked from.  The continuation is called rather
than returned to because extraction can require network round-trips,
and it may therefore run in another buffer than the one the thing was
read from.")

(defun agent--extractor-at-point ()
  "Return the extractor for the thing at point, or nil when there is none."
  (cdr (seq-find (lambda (thing) (funcall (car thing)))
                 agent-at-point-things)))

(defun agent--act-on-context (extractor existing)
  "Extract a context with EXTRACTOR and deliver it to a session.
With EXISTING non-nil the context goes to a running session chosen by
completion; otherwise a new session is started for it.  Extraction can
be asynchronous, so the buffer the command was invoked from and the
backend resolved there are captured now and threaded through delivery:
by the time the continuation runs, the user may have moved."
  (let ((origin (current-buffer))
        (backend (unless existing (agent--resolve-backend))))
    (funcall extractor
             (lambda (context)
               (agent--deliver-context context existing origin backend)))))

(defun agent--deliver-context (context existing origin backend)
  "Deliver CONTEXT to a session, choosing a running one when EXISTING.
ORIGIN is the buffer the command was invoked from and BACKEND the
backend resolved there."
  (if existing
      (agent--deliver-to context (agent--read-session-buffer) origin)
    (agent--deliver-to-new-session context origin backend)))

(defun agent--deliver-to-new-session (context origin backend)
  "Start a BACKEND session for CONTEXT and deliver it there.
An anchored context names its own directory; an unanchored one has its
project read from the account's sources, ranked by its text.  ORIGIN is
the buffer the command was invoked from."
  (if-let* ((directory (plist-get context :directory)))
      (agent--start-and-deliver context backend directory origin)
    (agent-project-read
     (agent-account-current backend)
     (plist-get context :text)
     "Project: "
     (lambda (directory)
       (agent--start-and-deliver context backend directory origin)))))

(defun agent--start-and-deliver (context backend directory origin)
  "Start a BACKEND session in DIRECTORY for CONTEXT and deliver it there.
A payload the context asks to submit is given to the new session as its
initial prompt, which the backend passes to the CLI on the command line.
Typing it in instead would race the session's startup: nothing sequences
terminal input against a CLI that has only just been spawned, and a
directory the CLI has not seen before opens with a trust prompt that the
typed text would answer.  An unsubmitted payload is typed in, since it
is meant to sit in the prompt for the user to edit.  ORIGIN is the
buffer the command was invoked from."
  (let* ((payload (plist-get context :payload))
         (submit (plist-get context :submit))
         (buffer (agent--start-session-in backend directory
                                          (and submit payload))))
    (unless submit
      (agent-send-string payload buffer))
    (agent--finish-delivery context buffer origin)))

(defun agent--start-session-in (backend directory &optional initial-prompt)
  "Start a BACKEND session in DIRECTORY and return its buffer.
INITIAL-PROMPT, when non-nil, is submitted as the session's first user
message."
  (let ((dir (file-name-as-directory (expand-file-name directory)))
        (label (when-let* ((struct (agent-backend backend)))
                 (agent-backend-label struct))))
    (message "Starting %s in %s..." label (abbreviate-file-name dir))
    (agent-start-session
     (agent-session-create :backend backend :directory dir)
     :initial-prompt initial-prompt)))

(defun agent--deliver-to (context buffer origin)
  "Deliver CONTEXT's payload to running session BUFFER and return it.
ORIGIN is the buffer the command was invoked from."
  (if (plist-get context :submit)
      (agent-submit (plist-get context :payload) buffer)
    (agent-send-string (plist-get context :payload) buffer))
  (agent--finish-delivery context buffer origin))

(defun agent--finish-delivery (context buffer origin)
  "Run CONTEXT's `:after' thunk, display session BUFFER and return it.
The thunk acts on the thing at point, so it runs in ORIGIN, the buffer
the command was invoked from: starting a session pops to BUFFER and
makes it current, and an origin that died meanwhile has nothing left to
act on."
  (when-let* ((after (plist-get context :after))
              ((buffer-live-p origin)))
    (with-current-buffer origin (funcall after)))
  (display-buffer buffer)
  buffer)

(defun agent--backtrace-at-point-p ()
  "Return non-nil in a backtrace buffer."
  (string-match-p "\\*Backtrace\\*" (buffer-name)))

(defun agent--slack-message-at-point-p ()
  "Return non-nil in a Slack message buffer.
Reads the buffer-local `slack-current-buffer', which `slack' sets on
every room buffer."
  (bound-and-true-p slack-current-buffer))

(defun agent--forge-topic-at-point-p ()
  "Return non-nil when a Forge notification or topic is at point.
Checks the major mode first, so a buffer that cannot hold a topic never
calls into `forge'."
  (and (derived-mode-p '(forge-notifications-mode forge-topic-mode magit-mode))
       (or (forge-notification-at-point) (forge-topic-at-point))))

(defun agent--mu4e-message-at-point-p ()
  "Return non-nil when a mu4e message is at point.
Checks the major mode first, so a buffer that cannot hold a message
never calls into `mu4e'."
  (and (derived-mode-p '(mu4e-headers-mode mu4e-view-mode))
       (mu4e-message-at-point t)))

(defun agent--org-todo-at-point-p ()
  "Return non-nil when point is on an org TODO heading."
  (and (derived-mode-p 'org-mode) (org-get-todo-state)))

;;;###autoload
(defun agent-setup-kill-on-exit ()
  "Arrange for the buffer to be killed when the session process exits.
Consults the backend's `before-kill-check' slot, which may veto or
prompt before the buffer is killed."
  (interactive)
  (when-let* ((session (agent-session))
              (backend (agent-session-backend session))
              ((get-buffer-process (current-buffer))))
    (agent--add-process-exit-hook
     (current-buffer)
     (lambda (buffer)
       (when (and (buffer-live-p buffer)
                  (agent--before-kill-allowed-p backend buffer))
         (ignore-errors (kill-buffer buffer)))))))

(defun agent--before-kill-allowed-p (backend buffer)
  "Return non-nil when killing session BUFFER is allowed by BACKEND.
The shared branch warning runs first, then the backend's own
`before-kill-check' slot, which may veto or prompt for its own
reasons."
  (let ((check (when-let* ((struct (agent-backend backend)))
                 (agent-backend-before-kill-check struct))))
    (and (with-current-buffer buffer
           (agent--confirm-kill-branches buffer backend))
         (or (null check)
             (with-current-buffer buffer
               (funcall check buffer))))))

(defun agent--add-process-exit-hook (buffer fn)
  "Call FN with BUFFER after the process in BUFFER exits.
Composes with any existing sentinel via `add-function', so
repeated calls and pre-existing sentinels all run."
  (when-let* ((proc (get-buffer-process buffer)))
    (unless (process-sentinel proc)
      (set-process-sentinel proc #'ignore))
    (add-function :after (process-sentinel proc)
                  (lambda (process _event)
                    (when (memq (process-status process) '(exit signal))
                      (funcall fn buffer))))))

;;;###autoload
(defun agent-exit ()
  "Exit the current AI session and kill its buffer.
Runs the before-exit chain, then submits `/exit'.  Claude Code
handles `/exit' natively; the codex backend intercepts it and
kills the session, since the Codex CLI has no `/exit'."
  (interactive)
  (let* ((session (or (agent-session)
                      (user-error "Not in an AI session buffer")))
         (backend (agent-session-backend session))
         (buffer (current-buffer)))
    (when (agent--run-before-exit-functions backend buffer)
      (agent--exit-session buffer))))

(defun agent--exit-session (buffer)
  "Submit `/exit' to session BUFFER without re-running before-exit hooks."
  (agent-submit "/exit" buffer))

;;;###autoload
(defun agent-restart ()
  "Kill the current AI session and resume it in place.
Useful when a setting change requires relaunching the CLI.
Preserves the session's directory, instance name, account, and any
launch state the backend's `:restart-options' function captures; if
the active account differs from the session account, prompt for
which one to use."
  (interactive)
  (let* ((session (or (agent-session)
                      (user-error "Not in an AI session buffer")))
         (backend (agent-session-backend session))
         (buffer (current-buffer)))
    (when (agent--confirm-no-captured-prompts backend buffer "Restart")
      (let* ((struct (agent-backend backend))
             (identity-fn (and struct (agent-backend-session-identity struct)))
             (session-id (or (and identity-fn (funcall identity-fn buffer))
                             (user-error "Current session has no session id")))
             (extra-options
              (when-let* ((fn (and struct
                                   (agent-backend-restart-options struct))))
                (funcall fn buffer)))
             (account (agent-restart--account
                       backend (agent-session-account session))))
        (agent-check-session-start backend account)
        (setf (agent-session-account session) account)
        (agent--force-kill-buffer buffer)
        (apply #'agent-start-session session
               :resume-id session-id extra-options)))))

(defun agent-restart--account (backend session-account)
  "Return the account to restart a BACKEND session with.
SESSION-ACCOUNT is the account recorded on the session.  Prompt for
which account to use when it differs from the currently selected
account.

Return nil when neither is set, because the session ran under the
backend's ambient default home and the restart must reuse it.
Prompting here would instead force an account the session never had
and persist that choice globally, which also hides the session's own
transcript from account-scoped history browsers."
  (let ((selected (agent-account-resolve backend)))
    (agent-restart--ensure-account backend selected)
    (cond
     ((and session-account selected
           (not (equal session-account selected)))
      (agent-restart--ensure-account
       backend
       (completing-read "Restart with account: "
                        (list selected session-account)
                        nil t nil nil selected)))
     (selected)
     (session-account
      (agent-restart--ensure-account backend session-account)))))

(defun agent-restart--ensure-account (backend account)
  "Return ACCOUNT after checking it is configured for BACKEND."
  (when (and account (not (agent-account-home backend account)))
    (user-error "Account `%s' is not configured" account))
  account)

;;;; Transient boolean infix class

(eval-and-compile
  (defclass agent--boolean-variable (transient-lisp-variable)
    ()
    "A `transient-lisp-variable' that toggles a boolean on each press."))

(cl-defmethod transient-infix-read ((obj agent--boolean-variable))
  "Toggle the boolean value of OBJ."
  (not (oref obj value)))

;;;; Transient account infix class

(defun agent--account-summary ()
  "Return a one-line summary of every backend's current account."
  (mapconcat (lambda (entry)
               (format "%s: %s"
                       (car entry)
                       (or (agent-account-current (car entry)) "default")))
             (sort (copy-sequence agent-backends)
                   (lambda (a b) (string< (symbol-name (car a))
                                          (symbol-name (car b)))))
             "  "))

(eval-and-compile
  (defclass agent--account-variable (agent-account-variable)
    ((backend :initarg :backend :initform nil))
    "An infix showing every backend's account and setting one of them.
The backend acted on is resolved when the infix is invoked, so the
same entry works from a session buffer of either backend and prompts
only when the context does not name one."))

(cl-defmethod transient-init-value ((obj agent--account-variable))
  "Initialize OBJ's value from the accounts of every backend."
  (oset obj value (agent--account-summary)))

(cl-defmethod transient-infix-read ((obj agent--account-variable))
  "Resolve a backend for OBJ, then prompt for one of its accounts."
  (let ((backend (agent--resolve-backend)))
    (oset obj backend backend)
    (agent-account--prompt backend)))

(cl-defmethod transient-infix-set ((obj agent--account-variable) value)
  "Persist VALUE as the account of OBJ's backend and re-render the summary."
  (when-let* ((value)
              (backend (oref obj backend)))
    (agent-account-set backend value)
    (agent-account-sync backend value))
  (oset obj value (agent--account-summary)))

(cl-defmethod transient-format-value ((obj agent--account-variable))
  "Render OBJ's account summary as plain text.
The inherited method prints the value with `prin1-to-string', which
wraps this whole line in double quotes and makes the per-backend
accounts harder to read at a glance."
  (propertize (format "%s" (oref obj value)) 'face 'transient-value))

(transient-define-infix agent--infix-account ()
  "Select the account of the current or prompted backend."
  :class 'agent--account-variable
  :description "account")

;;;; Branch navigation

(defun agent--branch-root (session-id sessions)
  "Follow forkedFrom chain from SESSION-ID upward in SESSIONS hash table.
Return the root session ID."
  (let ((current session-id)
        (seen (make-hash-table :test 'equal)))
    (catch 'done
      (while t
        (puthash current t seen)
        (let* ((meta (gethash current sessions))
               (parent (when meta (plist-get meta :forked-from))))
          (if (and parent (gethash parent sessions) (not (gethash parent seen)))
              (setq current parent)
            (throw 'done current)))))))

(defun agent--branch-children-map (sessions)
  "Build hash table mapping parent session ID to sorted list of child IDs.
SESSIONS is a hash table of session ID to metadata.  A child is linked
under its recorded parent even when that parent has no entry of its
own in SESSIONS, since a bounded scan may return only the descendants
of a root the caller already knows by id.  Children are sorted by
timestamp."
  (let ((map (make-hash-table :test 'equal)))
    (maphash (lambda (_id meta)
               (let ((parent (plist-get meta :forked-from)))
                 (when parent
                   (push (plist-get meta :session-id)
                         (gethash parent map)))))
             sessions)
    (maphash (lambda (parent children)
               (puthash parent
                        (sort children
                              (lambda (a b)
                                (string< (or (plist-get (gethash a sessions) :timestamp) "")
                                         (or (plist-get (gethash b sessions) :timestamp) ""))))
                        map))
             map)
    map))

(defun agent--branch-tree-members (root-id children-map)
  "Return hash table of all session IDs reachable from ROOT-ID via CHILDREN-MAP."
  (let ((members (make-hash-table :test 'equal))
        (queue (list root-id)))
    (while queue
      (let ((id (pop queue)))
        (unless (gethash id members)
          (puthash id t members)
          (dolist (child (gethash id children-map))
            (push child queue)))))
    members))

(defun agent--confirm-kill-branches (buffer backend)
  "Return non-nil unless BUFFER's session has branches and the user declines.
Scan only for sessions that could descend from this one, which is what
keeps the check off the critical path when a backend stores every
session in one directory.  Any failure to scan allows the kill: a
session must never become unkillable because its transcripts moved."
  (if (not agent-warn-kill-with-branches)
      t
    (condition-case nil
        (let* ((struct (agent-backend backend))
               (scan (and struct (agent-backend-session-headers struct)))
               (session-id (and scan (agent--session-identity buffer backend))))
          (if (not session-id)
              t
            (let* ((headers (funcall scan buffer session-id))
                   (members (agent--branch-tree-members
                             session-id
                             (agent--branch-children-map headers)))
                   (count (1- (hash-table-count members))))
              (or (<= count 0)
                  (yes-or-no-p
                   (format "Session has %d %s — kill anyway? "
                           count
                           (if (= count 1) "branch" "branches")))))))
      (error t))))

(defun agent--branch-format-timestamp (iso-ts)
  "Format ISO-TS as \"Mon DD HH:MM\" for branch display."
  (when iso-ts
    (condition-case nil
        (format-time-string "%b %d %H:%M"
                            (encode-time (iso8601-parse iso-ts)))
      (error (substring iso-ts 0 (min 16 (length iso-ts)))))))

(defun agent--branch-format-tree (root-id sessions children-map current-id)
  "Format the branch tree rooted at ROOT-ID as an alist.
SESSIONS maps IDs to metadata, CHILDREN-MAP maps parent to child
IDs, CURRENT-ID is the active session.  Return an alist of
\(display-string . session-id)."
  (agent--branch-format-subtree
   root-id sessions children-map current-id "" ""))

(defun agent--branch-format-subtree
    (id sessions children-map current-id prefix child-prefix)
  "Format branch node ID and its children recursively.
SESSIONS maps IDs to metadata, CHILDREN-MAP maps parent to child
IDs, CURRENT-ID is the active session.  PREFIX is the tree connector
for this node, CHILD-PREFIX is the continuation for children.
Return a list of (display . session-id)."
  (let* ((meta (gethash id sessions))
         (prompt (or (plist-get meta :first-prompt) "(no prompt)"))
         (ts (agent--branch-format-timestamp
              (plist-get meta :timestamp)))
         (marker (if (string= id current-id) " *" ""))
         (display (format "%s%s  %s%s" prefix prompt (or ts "") marker))
         (children (gethash id children-map))
         (len (length children))
         (result (list (cons display id))))
    (cl-loop for child in children
             for i from 0
             for last-p = (= i (1- len))
             do (setq result
                      (nconc result
                             (agent--branch-format-subtree
                              child sessions children-map current-id
                              (concat child-prefix (if last-p "└─ " "├─ "))
                              (concat child-prefix (if last-p "   " "│  "))))))
    result))

(defun agent--branch-enrich-sessions (backend headers member-ids)
  "Enrich BACKEND's session HEADERS with prompt text for MEMBER-IDS.
HEADERS is a hash table of session id to header plist, MEMBER-IDS a hash
table of the session ids to keep.  Return a new hash table of enriched
plists, each still carrying `:session-id' and `:forked-from' so the tree
can be rebuilt from it."
  (let ((enrich (or (when-let* ((struct (agent-backend backend)))
                      (agent-backend-session-prompt struct))
                    #'identity))
        (table (make-hash-table :test #'equal)))
    (maphash (lambda (id header)
               (when (gethash id member-ids)
                 (puthash id (funcall enrich header) table)))
             headers)
    table))

(defun agent--session-identity (buffer &optional backend)
  "Return BUFFER's native session id, or nil when it is not known yet.
BACKEND defaults to BUFFER's detected backend."
  (when-let* ((backend (or backend (agent--detect-backend buffer)))
              (struct (agent-backend backend))
              (fn (agent-backend-session-identity struct)))
    (funcall fn buffer)))

(defun agent--buffer-for-session-id (session-id)
  "Return the live session buffer whose native id is SESSION-ID, or nil.
Try each buffer's cached `agent-session' id first, so the common case
does no backend work.  A buffer whose cached id does not match falls
back to asking its backend for the live identity via
`agent--session-identity' \(a freshly forked session has not submitted
anything yet, so nothing has cached its id), silently treating a
signal from that lookup as no match rather than aborting the search.
A live id found this way is cached with `agent--note-session-id' so
later lookups take the fast path."
  (cl-find-if
   (lambda (buffer)
     (or (when-let* ((session (agent-session buffer)))
           (equal (agent-session-id session) session-id))
         (when-let* ((backend (agent--detect-backend buffer))
                     (id (ignore-errors
                           (agent--session-identity buffer backend))))
           (agent--note-session-id buffer id)
           (equal id session-id))))
   (agent-session-buffers)))

(defun agent--branch-resume-session (backend session-id)
  "Resume BACKEND's SESSION-ID in a new session buffer.
The instance name is derived from the session id so resuming never
stops to ask for one."
  (agent-start-session
   (agent-session-create
    :backend backend
    :directory default-directory
    :instance (format "branch-%s" (substring session-id 0 8)))
   :resume-id session-id))

;;;###autoload
(defun agent-switch-branch ()
  "Navigate between branches of the current session.
Show every session that shares a fork ancestor with this one as a
tree, then switch to the selected session's live buffer, or resume it
in a new buffer when it has none."
  (interactive)
  (let* ((buffer (current-buffer))
         (backend (or (agent--detect-backend buffer)
                      (user-error "Not in an AI session buffer")))
         (scan (or (when-let* ((struct (agent-backend backend)))
                     (agent-backend-session-headers struct))
                   (user-error "Backend `%s' does not track branches"
                               backend)))
         (session-id (or (agent--session-identity buffer backend)
                         (user-error "Current session has no session id")))
         (headers (or (funcall scan buffer)
                      (user-error "No sessions found for this project")))
         (root (agent--branch-root
                session-id headers))
         (members (agent--branch-tree-members
                   root (agent--branch-children-map headers))))
    (when (<= (hash-table-count members) 1)
      (user-error "No branches for this session"))
    (let* ((sessions (agent--branch-enrich-sessions backend headers members))
           (tree (agent--branch-format-tree
                  root sessions (agent--branch-children-map sessions)
                  session-id))
           (selection (consult--read (mapcar #'car tree)
                                     :prompt "Branch: "
                                     :require-match t
                                     :sort nil))
           (selected (cdr (assoc selection tree))))
      (let ((selected-buffer (agent--buffer-for-session-id selected)))
        (cond
         ((equal selected session-id) (message "Already on this session"))
         (selected-buffer (switch-to-buffer selected-buffer))
         (t (agent--branch-resume-session backend selected)))))))

;;;###autoload
(defun agent-resume (arg)
  "Resume a past session of the current or prompted backend.
The backend is the current session's when called from a session
buffer, and prompted for otherwise.  ARG is passed to the backend's
own resume command, where it means \"the most recent session\"."
  (interactive "P")
  (let* ((backend (agent--resolve-backend))
         (resume (or (when-let* ((struct (agent-backend backend)))
                       (agent-backend-resume struct))
                     (user-error "Backend `%s' does not support resume"
                                 backend))))
    (funcall resume arg)))

;;;###autoload
(defun agent-create-branch (&optional isolated)
  "Create a branch of the current session and switch to it.
Fork the session in this buffer and open the fork in a separate
buffer.  By default the branch shares the parent's working tree,
matching the behavior of starting a second session in the same
project.

With prefix arg ISOLATED, also create a git worktree on a fresh
branch under `agent-branch-worktree-directory' and run the fork
inside it.  The worktree starts at the parent's HEAD, so uncommitted
parent changes are NOT carried over.  Use this when concurrent
destructive git operations across branches are a concern; otherwise
the default is what you want.  When the forked session fails to
start, the worktree and its branch are removed rather than left
behind, and the original error is re-signaled."
  (interactive "P")
  (let* ((buffer (current-buffer))
         (backend (or (agent--detect-backend buffer)
                      (user-error "Not in an AI session buffer")))
         (session-id (or (agent--session-identity buffer backend)
                         (user-error "Current session has no session id")))
         (parent-cwd default-directory)
         (branch-id (format-time-string "%H%M%S"))
         (toplevel (and isolated
                        (or (agent--git-toplevel)
                            (user-error "Not in a git repo; cannot isolate"))))
         (worktree (and isolated
                        (agent--make-branch-worktree toplevel branch-id))))
    (when worktree
      (agent--prepare-fork backend session-id parent-cwd (car worktree)))
    (condition-case err
        (agent-start-session
         (agent-session-create
          :backend backend
          :directory (or (car worktree) default-directory)
          :instance (format "branch-%s" branch-id))
         :resume-id session-id
         :fork t)
      (error
       (when worktree
         (agent--remove-branch-worktree toplevel worktree))
       (signal (car err) (cdr err))))
    (when worktree
      (message "Branched in worktree %s on branch %s"
               (car worktree) (cdr worktree)))))

(defun agent--prepare-fork (backend session-id from-dir to-dir)
  "Prepare BACKEND to fork SESSION-ID from FROM-DIR inside TO-DIR.
Backends that record sessions per project directory use this to make
the parent session visible from TO-DIR; backends that record them
globally register no `prepare-fork' slot and nothing happens."
  (when-let* ((struct (agent-backend backend))
              (fn (agent-backend-prepare-fork struct)))
    (funcall fn session-id from-dir to-dir)))

(defun agent--git-toplevel (&optional dir)
  "Return git toplevel for DIR (or `default-directory'), or nil if none."
  (let ((default-directory (or dir default-directory)))
    (with-temp-buffer
      (when (zerop (call-process "git" nil t nil
                                 "rev-parse" "--show-toplevel"))
        (file-name-as-directory (string-trim (buffer-string)))))))

(defun agent--make-branch-worktree (toplevel branch-id)
  "Create a git worktree of TOPLEVEL identified by BRANCH-ID.
Returns a cons (PATH . BRANCH-NAME).  Signals an error on failure."
  (let* ((repo-name (file-name-nondirectory (directory-file-name toplevel)))
         (branch-name (format "agent-branch-%s" branch-id))
         (worktree-path (file-name-as-directory
                         (expand-file-name
                          (format "%s-branch-%s" repo-name branch-id)
                          agent-branch-worktree-directory))))
    (make-directory agent-branch-worktree-directory t)
    (agent--git-worktree-add toplevel branch-name worktree-path)
    (cons worktree-path branch-name)))

(defun agent--git-worktree-add (toplevel branch-name worktree-path)
  "Run `git worktree add' in TOPLEVEL for BRANCH-NAME at WORKTREE-PATH."
  (let ((default-directory toplevel))
    (with-temp-buffer
      (let ((exit (call-process "git" nil t nil
                                "worktree" "add" "-b" branch-name
                                (directory-file-name worktree-path))))
        (unless (zerop exit)
          (error "Git worktree add failed: %s"
                 (string-trim (buffer-string))))))))

(defun agent--remove-branch-worktree (toplevel worktree)
  "Remove WORKTREE and its branch, created under TOPLEVEL, best-effort.
WORKTREE is a (PATH . BRANCH-NAME) cons as returned by
`agent--make-branch-worktree'.  Called only after the session inside
WORKTREE failed to start, so nothing of value is expected to be in
it; still, never signal here, since the caller re-signals the
original start-session error and a cleanup failure must not replace
it."
  (let ((default-directory toplevel))
    (ignore-errors
      (call-process "git" nil nil nil "worktree" "remove" "--force"
                    (directory-file-name (car worktree))))
    (ignore-errors
      (call-process "git" nil nil nil "branch" "-D" (cdr worktree)))))

;;;; Transient menu

;;;###autoload
(defun agent-history ()
  "Browse and act on historical sessions with the optional Agent Log package.
Delegate to `agent-log-menu'.  Loading `agent' never requires
`agent-log'; this command loads it on demand and signals a clear error
when it is not installed."
  (interactive)
  (unless (require 'agent-log nil t)
    (user-error "Package `agent-log' is required for history browsing"))
  (call-interactively #'agent-log-menu))

;;;###autoload (autoload 'agent-menu "agent" nil t)
(transient-define-prefix agent-menu ()
  "Dispatch AI session commands."
  [["Sessions"
    ("e" "start or switch" agent-start-or-switch)
    ("w" "jump to waiting" agent-jump-to-waiting)
    ("R" "resume" agent-resume)
    ("N" "new branch" agent-create-branch)
    ("B" "switch branch" agent-switch-branch)
    ("h" "handoff" agent-handoff)
    ("x" "exit session" agent-exit)
    ("r" "restart" agent-restart)
    ("l" "history" agent-history)
    ("L" "login" agent-account-login)]
   ["Tools"
    ("s" "run skill" agent-run-skill)
    ("n" "new CR task" agent-trajectory-new-task)
    ("c" "post-push CI" agent-post-push-ci)
    ("a" "audit project" agent-audit-project)
    ("." "act on thing at point" agent-act-on-thing-at-point)]
   ["Prompts"
    ("p" "capture prompt" agent-capture-prompt)
    ("i" "insert prompt" agent-insert-captured-prompt)
    ("b" "batch todos" agent-batch-todos)]
   ["Options"
    ("-a" agent--infix-alert-on-ready)
    ("-p" agent--infix-protect-buffers)
    ("-t" agent--infix-sync-theme)
    ("-c" agent--infix-account)
    ("-w" agent--infix-warn-kill-with-branches)]])

(transient-define-infix agent--infix-alert-on-ready ()
  "Toggle `agent-alert-on-ready'."
  :class 'agent--boolean-variable
  :variable 'agent-alert-on-ready
  :description "alert on ready")

(transient-define-infix agent--infix-protect-buffers ()
  "Toggle `agent-protect-buffers'."
  :class 'agent--boolean-variable
  :variable 'agent-protect-buffers
  :description "protect buffers")

(eval-and-compile
  (defclass agent--sync-theme-variable (agent--boolean-variable)
    ()
    "A boolean infix that syncs themes when enabled."))

(cl-defmethod transient-infix-set :after
  ((obj agent--sync-theme-variable) _value)
  "Sync themes after OBJ enables `agent-sync-theme'."
  (when (symbol-value (oref obj variable))
    (agent-sync-theme-now)))

(transient-define-infix agent--infix-sync-theme ()
  "Toggle `agent-sync-theme'."
  :class 'agent--sync-theme-variable
  :variable 'agent-sync-theme
  :description "sync theme")

(transient-define-infix agent--infix-warn-kill-with-branches ()
  "Toggle `agent-warn-kill-with-branches'."
  :class 'agent--boolean-variable
  :variable 'agent-warn-kill-with-branches
  :description "warn kill with branches")

(add-hook 'enable-theme-functions #'agent-sync-theme)
(add-hook 'agent-before-exit-functions #'agent-run-skill-before-exit)

;;;; Provide

(provide 'agent)
;;; agent.el ends here
