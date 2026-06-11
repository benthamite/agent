;;; agent.el --- Shared extensions for AI coding CLI tools -*- lexical-binding: t -*-

;; Copyright (C) 2026

;; Author: Pablo Stafforini
;; URL: https://github.com/benthamite/agent
;; Version: 0.1
;; Package-Requires: ((emacs "30.0") (transient "0.9") (consult "1.0"))

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
(require 'json)
(require 'subr-x)
(eval-and-compile (require 'transient))
(require 'agent-account)

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
  "Seconds before an unfinished before-exit skill chain is abandoned.
When a session's chain has run this long without reaching its
exit, the watchdog resets the chain state, warns, and leaves the
session open."
  :type 'number
  :group 'agent)

(defcustom agent-skill-command-prefix-alist
  '((claude-code . "/")
    (codex . "$"))
  "Alist mapping backend symbols to interactive skill command prefixes."
  :type '(alist :key-type symbol :value-type string)
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
  "Static description of one registered AI agent backend.
Slots listed after the transitional marker mirror legacy plist
keys and are deleted as later refactoring phases migrate their
call sites."
  name label icon program
  buffer-p find-all-buffers find-buffers-for-dir
  start-session session-identity
  send-string send-return submit target-buffer
  waiting-p busy-p background-tasks-p duration-ms display-name-suffix
  notify
  account-env-var accounts account-file shared-config-items account-init
  canonical-home
  run-prompt skill-roots skill-command-prefix
  sync-theme modeline-status menu-suffixes
  before-exit-ready-to-close-p before-kill-check
  ;; Transitional slots, deleted in later phases:
  start start-new extract-directory extract-instance-name account
  send-command submit-command discover-skills handoff run-skill
  audit-project debug-backtrace act-on-slack-message setup-kill-on-exit
  exit restart)

(defvar agent-backends nil
  "Alist of registered AI backends.
Each entry is (NAME . STRUCT) where NAME is the backend symbol
and STRUCT is an `agent-backend'.")

(defvar-local agent--backend nil
  "Cached backend symbol for this buffer.")

(defconst agent--required-backend-keys
  '(:buffer-p :find-all-buffers :extract-instance-name :start-new)
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

Multi-account backends provide the optional account keys read by
`agent-account': `:account-env-var' (environment variable naming
the account config home), `:accounts' (alist of (NAME . HOME)),
`:account-file' (file persisting the current account name),
`:shared-config-items' (items symlinked from the canonical home
into each account home), `:canonical-home' (the backend's default
config directory), and `:account-init' (function called with the
account name after syncing).  The `:accounts', `:account-file',
`:shared-config-items', and `:canonical-home' values may each be
a literal value, a function returning one, or a symbol naming a
variable, resolved at read time by `agent-account--backend-value'."
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
                     (memq (agent--backend-keyword-slot key)
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

(defun agent--backend-get (backend key)
  "Return the slot named by keyword KEY in BACKEND's struct.
BACKEND is a backend name symbol.  KEY is a keyword whose name,
minus the leading colon, matches an `agent-backend' slot name.
This is a compatibility shim during the struct migration; new
code should call `agent-backend' slot accessors directly.
Return nil when BACKEND is not registered."
  (when-let* ((struct (agent-backend backend)))
    (cl-struct-slot-value 'agent-backend
                          (agent--backend-keyword-slot key)
                          struct)))

(defun agent--backend-keyword-slot (key)
  "Return the `agent-backend' slot symbol named by keyword KEY."
  (intern (substring (symbol-name key) 1)))

(defun agent-backend-icon-string (backend &optional face)
  "Return the icon string for the backend named BACKEND.
BACKEND is a backend name symbol.  FACE is passed to the icon
function to control the rendering color; see `agent-svg-icon'.
The icon slot can be a string or a function; if a function, it is
called with FACE to produce the icon."
  (let ((icon (agent--backend-get backend :icon)))
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
fresh.  Remaining OPTIONS are passed through to the backend, which may
support extras such as `:fork' (Claude Code) or `:terminal-backend'
\(Codex).  When SESSION carries an account, defensively sync its config
home with `agent-account-sync' and bind `agent-account--starting'
around the backend call so process-environment hooks see the account
at spawn time.  Return the new session buffer."
  (ignore initial-prompt resume-id)
  (let* ((backend (agent-session-backend session))
         (account (or (agent-session-account session)
                      (setf (agent-session-account session)
                            (agent-account-resolve backend))))
         (start (agent--backend-get backend :start-session)))
    (unless start
      (user-error "Backend `%s' does not support parameterized session start"
                  backend))
    (when account
      (agent-account-sync backend account))
    (let ((agent-account--starting (and account (cons backend account))))
      (apply start session options))))

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
      (or (buffer-local-value 'agent--session buf)
          (agent--capture-session buf)))))

(defun agent--capture-session (buffer)
  "Construct, store, and return the `agent-session' struct for BUFFER.
Derive the backend with `agent--detect-backend', the directory
and instance by parsing BUFFER's name, and the account from the
in-flight `agent-account--starting' binding when it belongs to
the backend, falling back to the persisted current account.
Return nil when BUFFER belongs to no registered backend or its
name encodes no directory."
  (when-let* ((backend (agent--detect-backend buffer))
              (name (buffer-name buffer))
              (directory (agent--session-directory-from-buffer-name name)))
    (let* ((instance-fn (agent--backend-get backend :extract-instance-name))
           (instance (when instance-fn (funcall instance-fn name)))
           (account (or (and (eq (car-safe agent-account--starting) backend)
                             (cdr agent-account--starting))
                        (agent-account-current backend))))
      (agent--set-session
       buffer
       (agent-session-create :backend backend
                             :account account
                             :directory directory
                             :instance instance)))))

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
Also cache SESSION's backend symbol in `agent--backend'."
  (with-current-buffer buffer
    (setq agent--session session)
    (setq agent--backend (agent-session-backend session))
    session))

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

(defconst agent--epoch-project-registry-file-default
  "/Users/pablostafforini/My Drive/Epoch/projects/shared/project-registry.json"
  "Default canonical Epoch project registry file.")

(defcustom agent-epoch-project-registry-file
  agent--epoch-project-registry-file-default
  "JSON registry of canonical Epoch projects."
  :type 'file
  :group 'agent)

(defcustom agent-epoch-projects-root
  "/Users/pablostafforini/My Drive/Epoch/projects/"
  "Root directory containing canonical Epoch automation project files."
  :type 'directory
  :group 'agent)

(defcustom agent-prompt-capture-directory
  (expand-file-name "agent/prompts/" user-emacs-directory)
  "Directory where session-specific prompt capture files are stored."
  :type 'directory
  :group 'agent)

(defcustom agent-prompt-capture-auto-save-delay 1
  "Idle seconds before prompt capture buffers are saved.
Set to nil to disable automatic saving of capture buffers."
  :type '(choice (const :tag "Disabled" nil) number)
  :group 'agent)

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

(defvar-local agent--session-state 'busy
  "Lifecycle state of this AI session buffer.
One of the symbols `busy', `awaiting-input', and `closing'.
Only `agent-session-event' may set this variable.")

(defvar-local agent--session-state-changed-at nil
  "Value of `float-time' at this session's last state transition.")

(defvar agent--sync-theme-timer nil
  "Pending timer for deferred theme sync, or nil.")

(defvar-local agent--prompt-capture-save-timer nil
  "Idle timer used to save prompt capture buffers.")

(defconst agent--captured-prompt-preview-width 100
  "Maximum width for prompt body previews in completion candidates.")

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
(declare-function org-back-to-heading "org" (&optional invisible-ok))
(declare-function org-entry-get "org" (pom property &optional inherit literal-nil))
(declare-function org-get-heading "org" (&optional no-tags no-todo no-priority no-comment))
(declare-function org-set-property "org" (property value))
(declare-function outline-next-heading "outline" ())

(declare-function consult--read "consult")
(declare-function consult--prefix-group "consult")
(declare-function consult--lookup-cdr "consult")
(declare-function consult-yasnippet--candidates "consult-yasnippet")
(declare-function consult-yasnippet--annotate "consult-yasnippet")

(declare-function yas--template-content "yasnippet")
(declare-function yas--template-expand-env "yasnippet")
(declare-function yas--template-key "yasnippet")
(declare-function yas--all-templates "yasnippet")
(declare-function yas--get-snippet-tables "yasnippet")
(declare-function yas-minor-mode "yasnippet")
(declare-function yas-expand-snippet "yasnippet")
(declare-function yas-active-snippets "yasnippet")
(declare-function yas--commit-snippet "yasnippet")
(declare-function map-values "map")

(defvar yas-minor-mode)
(defvar yas-prompt-functions)
(defvar yas--tables)
(defvar org-heading-regexp)

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

;;;; Home-row session keys

(defun agent--purge-dead-session-keys ()
  "Remove entries for buffers that are no longer live."
  (let (dead)
    (maphash (lambda (buf _) (unless (buffer-live-p buf) (push buf dead)))
             agent--session-keys)
    (dolist (buf dead)
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

(defun agent--release-session-key ()
  "Release the session key for the current buffer."
  (remhash (current-buffer) agent--session-keys))

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
Prefers BUFFER's `agent-session' fields, falling back to
buffer-name parsing."
  (let* ((session (agent-session buffer))
         (project (agent--buffer-session-name buffer))
         (instance
          (if session
              (agent-session-instance session)
            (when-let* ((backend (agent--detect-backend buffer)))
              (funcall (agent--backend-get backend :extract-instance-name)
                       (buffer-name buffer))))))
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
                       (funcall (agent--backend-get backend :find-all-buffers))
                     (agent--find-all-buffers)))
         (others (cl-remove buffer all-bufs))
         (sibling-names (mapcar #'agent--buffer-session-name others))
         (base (if (member name sibling-names)
                   (agent--qualified-session-name buffer)
                 name)))
    (agent--display-name-with-suffix buffer backend base)))

(defun agent--display-name-with-suffix (buffer backend base)
  "Return BASE plus BACKEND's display suffix for BUFFER, when any."
  (if-let* ((suffix-fn (and backend
                            (agent--backend-get backend
                                                    :display-name-suffix)))
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
      (funcall (agent-backend-start-new (cdar backends))))
     (t
      (let* ((names (mapcar (lambda (e)
                              (cons (or (agent-backend-label (cdr e))
                                        (symbol-name (car e)))
                                    (car e)))
                            backends))
             (choice (completing-read "Backend: " (mapcar #'car names) nil t))
             (backend-sym (cdr (assoc choice names))))
        (funcall (agent--backend-get backend-sym :start-new)))))))

(transient-define-prefix agent--session-switcher ()
  "Switch to an AI session or start a new one."
  [["Actions"
    ("w" "jump to waiting" agent-jump-to-waiting)
    ("e" "new session" agent-start-new-session)]
   ["Sessions"
    :class transient-column
    :setup-children agent--session-switcher-children]])

(defun agent--session-switcher-children (_)
  "Build transient suffixes for the session switcher, grouped by account."
  (let ((groups (agent--group-sessions-by-account)))
    (transient-parse-suffixes
     'agent--session-switcher
     (apply #'vector (agent--interleave-group-headers groups)))))

(defun agent--group-sessions-by-account ()
  "Return an alist of (ACCOUNT . SPECS) sorted by account name.
Each SPECS is a list of suffix specs sorted by home-row key."
  (let ((groups (make-hash-table :test 'equal)))
    (maphash
     (lambda (buf key)
       (when (buffer-live-p buf)
         (push (agent--session-suffix-spec buf key)
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
        (agent--backend-get backend :label)
        (and backend (symbol-name backend))
        "Sessions")))

(defun agent--session-suffix-spec (buf key)
  "Build a transient suffix spec for BUF bound to KEY."
  (let* ((backend (agent--detect-backend buf))
         (icon (when backend (agent-backend-icon-string backend)))
         (name (agent-display-name buf))
         (label (if (and icon (not (string-empty-p icon)))
                    (format "%s %s" icon name) name))
         (state (agent-session-display-state buf backend))
         (cmd (make-symbol (format "ai-switch-%s" key)))
         (spec (list key label cmd)))
    (unless (eq state 'busy)
      (setq spec (append spec
                         (list :face (if (eq state 'background-waiting)
                                         'agent-waiting-with-background
                                       'agent-waiting)))))
    (fset cmd (lambda () (interactive) (switch-to-buffer buf)))
    spec))

(defun agent--session-waiting-p (buffer &optional backend)
  "Return non-nil when BUFFER is waiting for input.
BACKEND defaults to the detected backend."
  (not (eq (agent-session-display-state buffer backend) 'busy)))

(defun agent-session-display-state (buffer &optional backend)
  "Return the switcher display state for session BUFFER.
BACKEND defaults to the detected backend.  The result is one of
the symbols `busy', `waiting', and `background-waiting'.  A
session counts as waiting when its backend reports an input
prompt directly via `:waiting-p' (an active turn that accepts
steering input), or when `agent--session-state' is
`awaiting-input' and the backend's `:busy-p' does not veto it as
stale.  Waiting sessions whose backend reports work via
`:background-tasks-p' display as `background-waiting'."
  (let* ((backend (or backend (agent--detect-backend buffer)))
         (backend-waiting (agent--backend-waiting-p buffer backend))
         (awaiting (eq (buffer-local-value 'agent--session-state buffer)
                       'awaiting-input)))
    (cond
     ((and (not backend-waiting)
           (or (not awaiting)
               (agent--backend-busy-p buffer backend)))
      'busy)
     ((agent--backend-background-tasks-p buffer backend)
      'background-waiting)
     (t 'waiting))))

(defun agent--backend-waiting-p (buffer backend)
  "Return non-nil when BACKEND reports BUFFER is accepting input."
  (and backend
       (when-let* ((fn (agent--backend-get backend :waiting-p)))
         (funcall fn buffer))))

(defun agent--backend-busy-p (buffer backend)
  "Return non-nil when BACKEND reports BUFFER is actively responding."
  (and backend
       (when-let* ((fn (agent--backend-get backend :busy-p)))
         (funcall fn buffer))))

(defun agent--backend-background-tasks-p (buffer backend)
  "Return non-nil when BACKEND reports background work in BUFFER."
  (and backend
       (when-let* ((fn (agent--backend-get backend :background-tasks-p)))
         (funcall fn buffer))))

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
        (when-let* ((label (agent--backend-get (car entry) :label)))
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
EVENT is one of the symbols `stop', `idle-prompt', `submit', and
`exit-request'.  This function is the single owner of
`agent--session-state'; backends translate raw CLI events into
calls to it and never set session state directly.  A `submit'
event delivered while BUFFER is already busy is ignored, because
backend submission hooks can fire multiple times per submission
and on submissions that start no turn."
  (when (buffer-live-p buffer)
    (pcase event
      ((or 'stop 'idle-prompt)
       (agent--session-event-awaiting-input buffer event))
      ('submit
       (unless (eq (buffer-local-value 'agent--session-state buffer) 'busy)
         (agent--session-set-state buffer 'busy)))
      ('exit-request
       (agent--session-set-state buffer 'closing))
      (_ (error "Unknown agent session event: %s" event)))))

(defun agent--session-event-awaiting-input (buffer event)
  "Transition BUFFER to `awaiting-input' and run the ready side effects.
EVENT is `stop' or `idle-prompt'.  The before-exit chain is
advanced first; when it consumes the event, the ready alert,
scrolling, and display-name refresh are suppressed.  The ready
alert fires only for `idle-prompt' events."
  (agent--session-set-state buffer 'awaiting-input)
  (unless (agent--before-exit-transition buffer 'step)
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
         (label (or (and backend (agent--backend-get backend :label))
                    "Session"))
         (name (agent--session-name (buffer-name buffer)))
         (notify (or (and backend (agent--backend-get backend :notify))
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

;;;###autoload
(defun agent-toggle-alert ()
  "Toggle OS notifications for AI sessions."
  (interactive)
  (setq agent-alert-on-ready (not agent-alert-on-ready))
  (message "AI alert notifications %s"
           (if agent-alert-on-ready "enabled" "disabled")))

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

;;;; Snippet insertion

(defun agent--expand-snippet-to-text (template)
  "Expand yasnippet TEMPLATE to plain text in a temporary buffer."
  (with-temp-buffer
    (yas-minor-mode 1)
    (let ((yas-prompt-functions '(yas-no-prompt)))
      (yas-expand-snippet (yas--template-content template)
                          nil nil
                          (yas--template-expand-env template)))
    (mapc #'yas--commit-snippet (yas-active-snippets))
    (buffer-string)))

(defun agent--consult-yasnippet (orig-fn arg)
  "In eat-mode buffers, send snippet content via the terminal.
ORIG-FN is `consult-yasnippet'; ARG is the prefix argument."
  (if (not (derived-mode-p 'eat-mode))
      (funcall orig-fn arg)
    (let* ((candidates
            (consult-yasnippet--candidates
             (if arg
                 (progn (require 'map)
                        (yas--all-templates (map-values yas--tables)))
               (yas--all-templates (yas--get-snippet-tables)))))
           (template
            (consult--read
             candidates
             :prompt "Choose a snippet: "
             :annotate (consult-yasnippet--annotate candidates)
             :lookup 'consult--lookup-cdr
             :require-match t
             :group 'consult--prefix-group
             :category 'yasnippet)))
      (when template
        (let* ((expanded (agent--expand-snippet-to-text template))
               (text (replace-regexp-in-string "\n" "\e\r" expanded)))
          (eat-term-send-string eat-terminal text))))))

(with-eval-after-load 'consult-yasnippet
  (advice-add 'consult-yasnippet :around #'agent--consult-yasnippet))

(defun agent--try-expand-snippet-at-prompt ()
  "Try to expand a yasnippet key at the eat terminal prompt.
Search backward from `point-max' for a prompt marker, extract the
user's input, and check whether it ends with a snippet key.  If
found, erase the key and send the expanded text.  Return non-nil
if a snippet was expanded."
  (when (and (derived-mode-p 'eat-mode)
             (bound-and-true-p eat-terminal)
             (bound-and-true-p yas-minor-mode))
    (save-excursion
      (goto-char (point-max))
      (when (re-search-backward "^[❯>$][[:space:]]" nil t)
        (let* ((prompt-start (match-end 0))
               (prompt-end (progn (end-of-line) (point)))
               (input (string-trim-right
                       (buffer-substring-no-properties prompt-start prompt-end)))
               (templates (yas--all-templates (yas--get-snippet-tables)))
               (best-match nil)
               (best-key nil))
          (dolist (template templates)
            (let ((key (yas--template-key template)))
              (when (and key
                         (> (length key) 0)
                         (<= (length key) (length input))
                         (string= key (substring input (- (length input) (length key))))
                         (or (null best-key)
                             (> (length key) (length best-key))))
                (setq best-match template
                      best-key key))))
          (when best-match
            (eat-term-send-string eat-terminal
                                  (make-string (length best-key) ?\x7f))
            (let* ((expanded (agent--expand-snippet-to-text best-match))
                   (text (replace-regexp-in-string "\n" "\e\r" expanded)))
              (eat-term-send-string eat-terminal text))
            t))))))

(defun agent-snippet-tab ()
  "Try snippet expansion at prompt, otherwise send TAB to eat."
  (interactive)
  (unless (agent--try-expand-snippet-at-prompt)
    (eat-self-input 1 ?\t)))

(defvar agent--snippet-keys-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "TAB") #'agent-snippet-tab)
    (define-key map [tab] #'agent-snippet-tab)
    map)
  "Keymap for `agent--snippet-keys-mode'.")

(define-minor-mode agent--snippet-keys-mode
  "Minor mode providing yasnippet TAB expansion in AI session buffers."
  :keymap agent--snippet-keys-mode-map)

(defun agent-setup-snippet-keys ()
  "Enable yasnippet TAB expansion in the current AI session buffer."
  (when (and (agent--detect-backend (current-buffer))
             (bound-and-true-p eat-terminal)
             (require 'yasnippet nil t))
    (yas-minor-mode 1)
    (agent--snippet-keys-mode 1)))

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
  (agent--dispatch-send :send-command (list string) buffer))

(defun agent-submit (string &optional buffer)
  "Insert STRING into session BUFFER's prompt and submit it.
BUFFER defaults to the current session buffer.  Prefer the
backend's atomic `:submit-command'; fall back to `:send-command'
followed by `:send-return' when the backend registers none."
  (let* ((buf (agent--resolve-session-buffer buffer))
         (backend (agent--detect-backend buf)))
    (if (agent--backend-get backend :submit-command)
        (agent--dispatch-send :submit-command (list string) buf)
      (agent--dispatch-send :send-command (list string) buf)
      (when-let* ((send-return-fn (agent--backend-get backend :send-return)))
        (funcall send-return-fn buf)))))

(defun agent-send-return (&optional buffer)
  "Submit the pending prompt in session BUFFER.
BUFFER defaults to the current session buffer.  Emits a `submit'
session event before dispatching to the backend's `:send-return'."
  (agent--dispatch-send :send-return nil buffer))

(defun agent--dispatch-send (slot args buffer)
  "Emit a `submit' event for BUFFER and call its backend SLOT with ARGS.
SLOT is one of `:send-command', `:submit-command', and
`:send-return'.  BUFFER is resolved with
`agent--resolve-session-buffer' and appended to ARGS."
  (let* ((buf (agent--resolve-session-buffer buffer))
         (backend (agent--detect-backend buf))
         (fn (and backend (agent--backend-get backend slot))))
    (unless fn
      (user-error "Backend `%s' does not support `%s'" backend slot))
    (agent-session-event buf 'submit)
    (apply fn (append args (list buf)))))

;;;; Prompt capture

;;;###autoload
(defun agent-capture-prompt (&optional buffer)
  "Open a persisted Org capture entry for an AI session BUFFER.
When BUFFER is nil, use the current AI session buffer or prompt
for a session.  The capture file is specific to the resolved
session identity, so prompts survive Emacs restarts and can later
be retrieved with `agent-insert-captured-prompt'."
  (interactive)
  (let* ((session-buffer (agent--resolve-session-buffer buffer))
         (backend (agent--detect-backend session-buffer))
         (file (agent--prompt-capture-file backend session-buffer)))
    (agent--open-prompt-capture-file file backend session-buffer)))

;;;###autoload
(defun agent-insert-captured-prompt (&optional buffer include-inserted)
  "Insert a captured prompt into an AI session BUFFER.
Prompts are loaded from the current session's persisted Org
capture file.  The selected prompt is inserted into the CLI input
field but is not submitted.  After successful insertion, the Org
entry is removed from the capture file.

With prefix argument INCLUDE-INSERTED, include prompts that have
already been inserted."
  (interactive (list nil current-prefix-arg))
  (let* ((session-buffer (agent--resolve-session-buffer buffer))
         (backend (agent--detect-backend session-buffer))
         (prompts (agent--captured-prompts
                   backend session-buffer include-inserted)))
    (unless (agent--backend-get backend :send-command)
      (user-error "Backend `%s' does not support prompt insertion" backend))
    (unless prompts
      (user-error "No captured prompts for this session"))
    (let ((prompt (agent--select-captured-prompt prompts)))
      (agent-send-string (plist-get prompt :text) session-buffer)
      (agent--delete-captured-prompt prompt))))

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
         (label (agent--backend-get backend :label))
         (account (when-let* ((session (agent-session buffer)))
                    (agent-session-account session))))
    (string-join (delq nil (list label account (agent-display-name buffer)))
                 " ")))

(defun agent--prompt-capture-file (backend buffer)
  "Return the Org capture file for BACKEND session BUFFER."
  (expand-file-name
   (concat (agent--prompt-session-slug backend buffer) ".org")
   agent-prompt-capture-directory))

(defun agent--prompt-session-slug (backend buffer)
  "Return a stable file slug for BACKEND session BUFFER."
  (format "%s-%s"
          backend
          (secure-hash 'sha1 (agent--prompt-session-identity backend buffer))))

(defun agent--prompt-session-identity (backend buffer)
  "Return the stable prompt capture identity for BACKEND session BUFFER."
  (let* ((directory (or (agent--buffer-directory backend buffer) ""))
         (account (when-let* ((session (agent-session buffer)))
                    (agent-session-account session)))
         (instance (funcall (agent--backend-get backend :extract-instance-name)
                            (buffer-name buffer))))
    (prin1-to-string (list backend account directory instance))))

(defun agent--open-prompt-capture-file (file backend buffer)
  "Open FILE and append a prompt entry for BACKEND session BUFFER."
  (require 'org)
  (make-directory (file-name-directory file) t)
  (let ((capture-buffer (find-file-noselect file)))
    (with-current-buffer capture-buffer
      (org-mode)
      (agent-prompt-capture-mode 1)
      (agent--ensure-prompt-capture-header backend buffer)
      (agent--append-prompt-capture-entry)
      (save-buffer))
    (pop-to-buffer capture-buffer)))

(defun agent--ensure-prompt-capture-header (backend buffer)
  "Insert the prompt capture file header for BACKEND session BUFFER."
  (when (zerop (buffer-size))
    (insert "#+title: Agent prompt captures\n")
    (insert "#+agent_backend: " (symbol-name backend) "\n")
    (insert "#+agent_session: " (agent-display-name buffer) "\n\n")))

(defun agent--append-prompt-capture-entry ()
  "Append a new prompt capture entry at the end of the current buffer."
  (goto-char (point-max))
  (unless (bolp) (insert "\n"))
  (insert "* Prompt " (format-time-string "%Y-%m-%d %H:%M") "\n")
  (insert ":PROPERTIES:\n")
  (insert ":CREATED: " (format-time-string "[%Y-%m-%d %a %H:%M]") "\n")
  (insert ":END:\n\n")
  (point))

(define-minor-mode agent-prompt-capture-mode
  "Automatically save persisted Agent prompt capture buffers."
  :lighter " AgentCapture"
  (if agent-prompt-capture-mode
      (add-hook 'after-change-functions
                #'agent--prompt-capture-after-change nil t)
    (remove-hook 'after-change-functions
                 #'agent--prompt-capture-after-change t)
    (agent--cancel-prompt-capture-save)))

(defun agent--prompt-capture-after-change (&rest _)
  "Schedule an automatic save for the current prompt capture buffer."
  (when agent-prompt-capture-auto-save-delay
    (agent--cancel-prompt-capture-save)
    (setq agent--prompt-capture-save-timer
          (run-with-idle-timer agent-prompt-capture-auto-save-delay
                               nil
                               #'agent--save-prompt-capture-buffer
                               (current-buffer)))))

(defun agent--cancel-prompt-capture-save ()
  "Cancel the pending prompt capture save timer, if any."
  (when (timerp agent--prompt-capture-save-timer)
    (cancel-timer agent--prompt-capture-save-timer))
  (setq agent--prompt-capture-save-timer nil))

(defun agent--save-prompt-capture-buffer (buffer)
  "Save prompt capture BUFFER when it is still live and modified."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq agent--prompt-capture-save-timer nil)
      (when (and buffer-file-name (buffer-modified-p))
        (save-buffer)))))

(defun agent--captured-prompts (backend buffer &optional include-inserted)
  "Return nonempty captured prompts for BACKEND session BUFFER.
When INCLUDE-INSERTED is non-nil, include prompts already marked
as inserted."
  (let ((file (agent--prompt-capture-file backend buffer)))
    (when (file-exists-p file)
      (agent--read-captured-prompts file include-inserted))))

(defun agent--read-captured-prompts (file &optional include-inserted)
  "Read captured prompt entries from Org FILE.
When INCLUDE-INSERTED is non-nil, include prompts already marked
as inserted."
  (require 'org)
  (with-temp-buffer
    (insert-file-contents file)
    (org-mode)
    (let (prompts)
      (goto-char (point-min))
      (while (re-search-forward org-heading-regexp nil t)
        (goto-char (match-beginning 0))
        (when-let* ((prompt (agent--captured-prompt-at-point
                             file include-inserted)))
          (push prompt prompts))
        (or (outline-next-heading) (goto-char (point-max))))
      (nreverse prompts))))

(defun agent--captured-prompt-at-point (file include-inserted)
  "Return the captured prompt at point as a plist, or nil.
FILE is the Org file being parsed.  When INCLUDE-INSERTED is
non-nil, include prompts already marked as inserted."
  (org-back-to-heading t)
  (let* ((title (org-get-heading t t t t))
         (created (org-entry-get (point) "CREATED"))
         (inserted (org-entry-get (point) "INSERTED"))
         (body-start (agent--captured-prompt-body-start))
         (body-end (save-excursion
                     (or (outline-next-heading) (goto-char (point-max)))
                     (point)))
         (text (string-trim
                (buffer-substring-no-properties body-start body-end))))
    (when (and (not (string-empty-p text))
               (or include-inserted (not inserted)))
      (list :file file
            :title title
            :created created
            :inserted inserted
            :text text))))

(defun agent--captured-prompt-body-start ()
  "Return the content start for the Org heading at point."
  (save-excursion
    (forward-line 1)
    (when (looking-at-p "[ \t]*:PROPERTIES:[ \t]*$")
      (when (re-search-forward "^[ \t]*:END:[ \t]*$" nil t)
        (forward-line 1)))
    (point)))

(defun agent--select-captured-prompt (prompts)
  "Prompt for one of PROMPTS and return its plist."
  (let* ((candidates (mapcar #'agent--captured-prompt-candidate prompts))
         (choice (completing-read "Prompt: " candidates nil t)))
    (or (get-text-property 0 'agent-prompt choice)
        (get-text-property
         0 'agent-prompt
         (cl-find choice candidates :test #'string=)))))

(defun agent--captured-prompt-candidate (prompt)
  "Return a completion candidate for captured PROMPT."
  (let ((label (agent--captured-prompt-candidate-label prompt)))
    (propertize label 'agent-prompt prompt)))

(defun agent--captured-prompt-candidate-label (prompt)
  "Return the completion label for captured PROMPT."
  (let ((heading (if-let* ((created (plist-get prompt :created)))
                     (format "%s %s" created (plist-get prompt :title))
                   (plist-get prompt :title)))
        (preview (agent--captured-prompt-preview prompt)))
    (if (string-empty-p preview)
        heading
      (format "%s: %s" heading preview))))

(defun agent--captured-prompt-preview (prompt)
  "Return a single-line truncated preview for captured PROMPT."
  (truncate-string-to-width
   (replace-regexp-in-string
    "[[:space:]\n]+" " " (string-trim (or (plist-get prompt :text) "")))
   agent--captured-prompt-preview-width nil nil "..."))

(defun agent--delete-captured-prompt (prompt)
  "Remove PROMPT's Org entry from its capture file."
  (when-let* ((file (plist-get prompt :file)))
    (let ((buffer (find-file-noselect file)))
      (with-current-buffer buffer
        (org-mode)
        (when (agent--find-captured-prompt prompt)
          (delete-region
           (point)
           (save-excursion
             (or (outline-next-heading) (goto-char (point-max)))
             (point)))
          (save-buffer))))))

(defun agent--find-captured-prompt (prompt)
  "Move point to PROMPT's matching Org heading in the current buffer."
  (goto-char (point-min))
  (catch 'found
    (while (re-search-forward org-heading-regexp nil t)
      (goto-char (match-beginning 0))
      (when (agent--captured-prompt-match-p prompt)
        (throw 'found t))
      (or (outline-next-heading) (goto-char (point-max))))
    nil))

(defun agent--captured-prompt-match-p (prompt)
  "Return non-nil when the current Org heading matches PROMPT."
  (when-let* ((candidate (agent--captured-prompt-at-point
                          (plist-get prompt :file) t)))
    (and (equal (plist-get candidate :title)
                (plist-get prompt :title))
         (equal (plist-get candidate :created)
                (plist-get prompt :created))
         (equal (plist-get candidate :text)
                (plist-get prompt :text)))))

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

(defun agent--dispatch (key)
  "Dispatch command KEY to the appropriate backend.
Uses `call-interactively' so the target command's interactive spec
runs and prompts for arguments as needed."
  (let* ((backend (agent--resolve-backend))
         (fn (agent--backend-get backend key)))
    (if fn
        (call-interactively fn)
      (user-error "Backend `%s' does not support `%s'" backend key))))

(defun agent--run-before-exit-functions (backend buffer)
  "Return non-nil if BACKEND session BUFFER should exit."
  (and (agent--confirm-no-captured-prompts backend buffer "Exit")
       (catch 'abort
         (dolist (fn agent-before-exit-functions t)
           (unless (funcall fn backend buffer)
             (throw 'abort nil))))))

(defun agent--confirm-no-captured-prompts (backend buffer action)
  "Confirm ACTION for BUFFER when it has pending captured prompts."
  (let ((count (length (agent--captured-prompts backend buffer))))
    (or (zerop count)
        (yes-or-no-p
         (format "%s has %d captured prompt%s.  %s anyway? "
                 (agent-display-name buffer)
                 count
                 (if (= count 1) "" "s")
                 action)))))

(defun agent--dispatch-with-captured-prompt-confirmation (key action)
  "Dispatch command KEY after confirming pending captures for ACTION."
  (let* ((backend (agent--resolve-backend))
         (buffer (current-buffer))
         (fn (agent--backend-get backend key)))
    (if (not fn)
        (user-error "Backend `%s' does not support `%s'" backend key)
      (when (agent--confirm-no-captured-prompts backend buffer action)
        (call-interactively fn)))))

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
            t
          (agent--before-exit-close buffer backend))))))

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
        (when (and command
                   (or (agent--backend-get backend :submit-command)
                       (agent--backend-get backend :send-command)))
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
  "Cancel the before-exit watchdog when a session buffer is killed."
  (agent--before-exit-cancel-watchdog))

(defun agent--before-exit-ready-to-close-p (backend buffer)
  "Return non-nil when BUFFER can close after a before-exit skill.
Backends may veto closing while the submitted command is still
unaccepted at the prompt."
  (if-let* ((fn (agent--backend-get backend :before-exit-ready-to-close-p)))
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
  (let* ((duration-ms-fn (agent--backend-get backend :duration-ms))
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
  (when-let* ((prefix (alist-get backend agent-skill-command-prefix-alist)))
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
  "Discover skills from all registered backends.
Calls each backend's `:discover-skills' function and returns a
combined list of skill plists, each augmented with `:backend'."
  (let (all-skills)
    (dolist (entry agent-backends)
      (when-let* ((discover-fn (agent-backend-discover-skills (cdr entry))))
        (dolist (skill (funcall discover-fn))
          (unless (and (plist-member skill :user-invocable)
                       (not (plist-get skill :user-invocable)))
            (push (plist-put (copy-sequence skill) :backend (car entry))
                  all-skills)))))
    (sort all-skills (lambda (a b)
                       (string< (plist-get a :name) (plist-get b :name))))))

(defun agent--skill-candidate (skill)
  "Return a unique completion candidate for SKILL."
  (let* ((backend (plist-get skill :backend))
         (label (or (agent--backend-get backend :label)
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
(defun agent-handoff ()
  "Close the current session and start a new one with the handoff prompt.
Dispatches to the appropriate backend."
  (interactive)
  (agent--dispatch-with-captured-prompt-confirmation :handoff "Handoff"))

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
                   (unless (string-empty-p input) input)))))
         (run-fn (agent--backend-get backend :run-skill)))
    (unless run-fn
      (user-error "Backend `%s' does not support `:run-skill'" backend))
    (funcall run-fn (plist-get skill :name) args)))

;;;###autoload
(defun agent-post-push-ci (&optional commit)
  "Run the post-push CI closeout skill for COMMIT.
When COMMIT is nil, use the current Git HEAD.  The selected backend
must support `:run-skill'."
  (interactive)
  (let* ((backend (agent--resolve-backend))
         (run-fn (agent--backend-get backend :run-skill))
         (sha (or commit (agent--git-head)))
         (args (format "--no-push --commit %s" sha)))
    (unless run-fn
      (user-error "Backend `%s' does not support `:run-skill'" backend))
    (funcall run-fn "post-push-ci" args)))

(defun agent--git-head ()
  "Return the current Git HEAD SHA."
  (with-temp-buffer
    (unless (zerop (process-file "git" nil t nil "rev-parse" "HEAD"))
      (user-error "Could not resolve Git HEAD"))
    (string-trim (buffer-string))))

;;;###autoload
(defun agent-audit-project ()
  "Run a comprehensive project audit via the appropriate backend."
  (interactive)
  (agent--dispatch :audit-project))

;;;###autoload
(defun agent-debug-backtrace ()
  "Analyze a backtrace and start a session in the culprit package."
  (interactive)
  (agent--dispatch :debug-backtrace))

;;;###autoload
(defun agent-act-on-slack-message ()
  "Route the Slack message at point to an Epoch project session."
  (interactive)
  (agent--dispatch :act-on-slack-message))

;;;###autoload
(define-obsolete-function-alias
  'agent-debug-slack-message #'agent-act-on-slack-message "0.2")

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
(defvar slack-current-buffer)
(defvar slack-get-permalink-url)
(declare-function gptel-request "gptel")
(declare-function slack-buffer-copy-link "slack-room-buffer")
(declare-function slack-buffer-room "slack-buffer")
(declare-function slack-buffer-team "slack-buffer")
(declare-function slack-get-ts "slack-util")
(declare-function slack-message-body "slack-message")
(declare-function slack-room-find "slack-room")
(declare-function slack-room-find-message "slack-room")
(declare-function slack-request "slack-request")
(declare-function slack-request-create "slack-request")

(defun agent--gptel-response-text (response)
  "Return final text from gptel RESPONSE, or nil.
Custom gptel callbacks may receive non-text events such as
reasoning blocks before the final response."
  (when (stringp response)
    response))

(defun agent--act-on-slack-message (model backend start-function)
  "Route the Slack message at point using MODEL, BACKEND, and START-FUNCTION.
START-FUNCTION is called with the selected project plist and the
Slack message URL."
  (agent--with-slack-message-context
   (lambda (context)
     (agent--identify-epoch-project-for-slack-message
      context model backend start-function))))

(defun agent--with-slack-message-context (callback)
  "Call CALLBACK with the Slack message context at point."
  (unless (require 'slack nil t)
    (user-error "Package `slack' is required"))
  (let* ((ts (agent--slack-message-ts-at-point))
         (team (agent--slack-team-at-point))
         (room (agent--slack-room-at-point team))
         (message (and room ts (slack-room-find-message room ts)))
         (text (agent--slack-message-text message team)))
    (unless (and team room ts text)
      (user-error "No Slack message at point"))
    (agent--slack-message-url
     team room ts
     (lambda (url)
       (funcall callback
                (list :text text :url url :ts ts
                      :room-id (agent--slot-value room 'id)))))))

(defun agent--slack-message-ts-at-point ()
  "Return the Slack message timestamp at point."
  (or (and (fboundp 'slack-get-ts) (slack-get-ts))
      (get-text-property (point) 'ts)
      (get-text-property (line-beginning-position) 'ts)))

(defun agent--slack-team-at-point ()
  "Return the Slack team for the current buffer."
  (and (boundp 'slack-current-buffer)
       slack-current-buffer
       (slack-buffer-team slack-current-buffer)))

(defun agent--slack-room-at-point (team)
  "Return the Slack room at point for TEAM."
  (or (ignore-errors (slack-buffer-room slack-current-buffer))
      (when-let* ((room-id (get-text-property (point) 'room-id)))
        (slack-room-find room-id team))))

(defun agent--slack-message-text (message team)
  "Return plain text for Slack MESSAGE in TEAM."
  (string-trim
   (cond
    (message (substring-no-properties (slack-message-body message team)))
    (t (buffer-substring-no-properties
        (line-beginning-position) (line-end-position))))))

(defun agent--slack-message-url (team room ts callback)
  "Call CALLBACK with a Slack permalink for TS in ROOM on TEAM."
  (if (and (fboundp 'slack-buffer-copy-link)
           (ignore-errors
             (slack-buffer-copy-link slack-current-buffer ts callback)
             t))
      nil
    (funcall callback (agent--slack-message-url-fallback team room ts))))

(defun agent--slack-message-url-fallback (team room ts)
  "Return a best-effort Slack permalink for TS in ROOM on TEAM."
  (let ((domain (or (and (slot-boundp team 'domain)
                         (agent--slot-value team 'domain))
                    (and (slot-boundp team 'name)
                         (agent--slot-value team 'name)))))
    (unless domain
      (user-error "Slack team has no domain"))
    (format "https://%s.slack.com/archives/%s/p%s"
            domain (agent--slot-value room 'id)
            (replace-regexp-in-string "\\." "" ts))))

(defun agent--slot-value (object slot)
  "Return OBJECT's dynamic EIEIO SLOT value."
  (eieio-oref object slot))

(defun agent--identify-epoch-project-for-slack-message
    (context model backend callback)
  "Identify the Epoch project for Slack CONTEXT and call CALLBACK.
MODEL and BACKEND configure the `gptel' request.  CALLBACK is
called with the selected project plist and Slack URL."
  (unless (and (require 'gptel nil t) (fboundp 'gptel-request))
    (user-error "Package `gptel' is required for Slack message routing"))
  (let* ((projects (agent-epoch-project-candidates))
         (prompt (agent--slack-project-selection-prompt context projects))
         (gptel-backend (alist-get backend gptel--known-backends nil nil
                                   #'string=))
         (gptel-model model)
         (gptel-include-reasoning nil)
         (gptel-use-tools nil))
    (message "Identifying Epoch project from Slack message...")
    (gptel-request
     prompt
     :system (concat
              "You route Slack messages to existing Epoch automation "
              "projects. Return ONLY a comma-separated list of project IDs "
              "from the provided registry, ordered from most likely to least "
              "likely. Do not invent project IDs.")
     :callback
     (lambda (response info)
       (if (not response)
           (message "gptel request failed: %s" (plist-get info :status))
         (when-let* ((text (agent--gptel-response-text response)))
           (agent--read-epoch-project-from-response
            text projects (plist-get context :url) callback)))))))

(defun agent--slack-project-selection-prompt (context projects)
  "Return a project-selection prompt from Slack CONTEXT and PROJECTS."
  (format "Slack message URL: %s\n\nSlack message text:\n%s\n\nProjects:\n%s"
          (plist-get context :url)
          (plist-get context :text)
          (string-join (mapcar #'agent--format-epoch-project projects) "\n")))

(defun agent--format-epoch-project (project)
  "Format PROJECT as one compact registry line."
  (format "- %s | %s | %s | outputs: %s | notes: %s"
          (plist-get project :id)
          (plist-get project :title)
          (plist-get project :summary)
          (or (plist-get project :outputs) "")
          (or (plist-get project :comments) "")))

(defun agent--read-epoch-project-from-response
    (response projects slack-url callback)
  "Read a project from RESPONSE and call CALLBACK with SLACK-URL."
  (let* ((ids (mapcar #'string-trim (split-string response "," t)))
         (candidates (agent--ordered-epoch-project-candidates ids projects))
         (labels (mapcar #'agent--epoch-project-label candidates))
         (selected (completing-read "Project: " labels nil t nil nil
                                    (car labels)))
         (project (nth (cl-position selected labels :test #'string=)
                       candidates)))
    (funcall callback project slack-url)))

(defun agent--ordered-epoch-project-candidates (ids projects)
  "Return PROJECTS ordered by candidate IDS, with remaining projects appended."
  (let ((matched (delq nil
                       (mapcar (lambda (id)
                                 (cl-find id projects :key
                                          (lambda (project)
                                            (plist-get project :id))
                                          :test #'string=))
                               ids))))
    (append matched (cl-set-difference projects matched :test #'eq))))

(defun agent--epoch-project-label (project)
  "Return a completion label for PROJECT."
  (format "%s - %s" (plist-get project :id) (plist-get project :title)))

(defun agent-epoch-project-candidates ()
  "Return canonical Epoch project candidates from the registry file."
  (unless (file-exists-p agent-epoch-project-registry-file)
    (user-error "Epoch project registry not found: %s"
                agent-epoch-project-registry-file))
  (with-temp-buffer
    (insert-file-contents agent-epoch-project-registry-file)
    (agent--epoch-projects-from-json (buffer-string))))

(defun agent--epoch-projects-from-json (json)
  "Return project plists parsed from registry JSON."
  (let* ((data (json-parse-string json :object-type 'alist
                                  :array-type 'list))
         (projects (alist-get 'projects data)))
    (mapcar #'agent--epoch-project-from-project-registry projects)))

(defun agent--epoch-project-from-project-registry (project)
  "Return an internal project plist from canonical PROJECT registry entry."
  (let* ((repo (car (agent--json-list (alist-get 'repo_paths project))))
         (doc (car (agent--json-list (alist-get 'project_doc_paths project)))))
    (list :id (alist-get 'id project)
          :title (alist-get 'title project)
          :summary (agent--epoch-project-registry-summary project)
          :comments (agent--epoch-project-registry-notes project)
          :outputs (string-join
                    (agent--json-list (alist-get 'slack_channels project))
                    ", ")
          :directory (agent--epoch-project-directory-from-paths doc repo)
          :repo repo
          :doc doc)))

(defun agent--epoch-project-registry-summary (project)
  "Return a compact summary for canonical PROJECT registry entry."
  (or (alist-get 'summary project)
      (let ((aliases (agent--json-list (alist-get 'aliases project))))
        (if aliases
            (format "Aliases: %s" (string-join aliases ", "))
          ""))))

(defun agent--epoch-project-registry-notes (project)
  "Return matching notes for canonical PROJECT registry entry."
  (let ((keywords (agent--json-list (alist-get 'browser_keywords project))))
    (if keywords
        (format "keywords: %s" (string-join keywords ", "))
      "")))

(defun agent--epoch-project-directory-from-paths (doc repo)
  "Return the best local working directory for relative DOC and REPO paths."
  (cond
   (doc (file-name-directory (agent--epoch-project-path doc)))
   (repo (file-name-directory
          (directory-file-name (agent--epoch-project-path repo))))
   (t agent-epoch-projects-root)))

(defun agent--epoch-project-path (path)
  "Return PATH expanded relative to `agent-epoch-projects-root'."
  (when path
    (expand-file-name path agent-epoch-projects-root)))

(defun agent--json-list (value)
  "Return VALUE when it is a list, otherwise nil."
  (and (listp value) value))

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
  "Return non-nil when BACKEND allows killing session BUFFER."
  (let ((check (agent--backend-get backend :before-kill-check)))
    (or (null check)
        (with-current-buffer buffer
          (funcall check buffer)))))

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
Dispatches to the backend's `:restart' handler."
  (interactive)
  (agent--dispatch-with-captured-prompt-confirmation :restart "Restart"))

;;;; Transient boolean infix class

(eval-and-compile
  (defclass agent--boolean-variable (transient-lisp-variable)
    ()
    "A `transient-lisp-variable' that toggles a boolean on each press."))

(cl-defmethod transient-infix-read ((obj agent--boolean-variable))
  "Toggle the boolean value of OBJ."
  (not (oref obj value)))

;;;; Transient menu

;;;###autoload (autoload 'agent-menu "agent" nil t)
(transient-define-prefix agent-menu ()
  "Dispatch AI session commands."
  [["Sessions"
    ("e" "start or switch" agent-start-or-switch)
    ("w" "jump to waiting" agent-jump-to-waiting)
    ("h" "handoff" agent-handoff)
    ("x" "exit session" agent-exit)
    ("r" "restart" agent-restart)
    ""
    "Buffer"
    ("K" "setup kill on exit" agent-setup-kill-on-exit)
    ("f" "fix rendering" agent-fix-rendering)
    ("S" "disable scrollback" agent-disable-scrollback-truncation)]
   ["Tools"
    ("s" "run skill" agent-run-skill)
    ("c" "post-push CI" agent-post-push-ci)
    ("a" "audit project" agent-audit-project)
    ("d" "debug backtrace" agent-debug-backtrace)
    ("m" "act on Slack message" agent-act-on-slack-message)
    ""
    "Alerts"
    ("T" "toggle alert" agent-toggle-alert)]
   ["Prompts"
    ("p" "capture prompt" agent-capture-prompt)
    ("i" "insert prompt" agent-insert-captured-prompt)]
   ["Options"
    ("-A" agent--infix-alert-on-ready)
    ("-p" agent--infix-protect-buffers)
    ("-t" agent--infix-sync-theme)]])

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

(add-hook 'enable-theme-functions #'agent-sync-theme)
(add-hook 'agent-before-exit-functions #'agent-run-skill-before-exit)
;; Phase 7 moves this into the agent minor mode's teardown.
(add-hook 'kill-buffer-hook #'agent--before-exit-teardown)

;;;; Provide

(provide 'agent)
;;; agent.el ends here
