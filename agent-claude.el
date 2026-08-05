;;; agent-claude.el --- Extensions for claude-code -*- lexical-binding: t -*-

;; Copyright (C) 2026

;; Author: Pablo Stafforini
;; URL: https://github.com/benthamite/agent
;; Version: 0.1
;; Package-Requires: ((claude-code "0.1") (consult "1.0") (agent "0.1"))

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

;; Extensions for `claude-code'.

;;; Code:

(require 'claude-code)
(eval-and-compile (require 'agent))
(require 'agent-account)
(require 'agent-claude-cli)
(require 'consult)
(require 'subr-x)
(require 'transient)

;;;; Variables

(defgroup agent-claude ()
  "Extensions for `claude-code'."
  :group 'claude-code)

(defcustom agent-claude-programmatic-skill-directories
  (list (expand-file-name "~/.claude/programmatic-skills"))
  "Directories to scan for skills run only by `agent-run-skill'.
These directories are not loaded by ordinary Claude Code sessions."
  :type '(repeat directory)
  :group 'agent-claude)

(define-obsolete-variable-alias 'agent-claude-fork-worktree-directory
  'agent-branch-worktree-directory "0.3")

(define-obsolete-variable-alias 'agent-claude-warn-kill-with-branches
  'agent-warn-kill-with-branches "0.3")

(define-obsolete-variable-alias 'agent-claude-log-directory
  'agent-todo-log-directory "0.3")

(define-obsolete-variable-alias 'agent-claude-org-todo-in-progress-keyword
  'agent-todo-in-progress-keyword "0.3")

(define-obsolete-function-alias 'agent-claude-batch-todos
  #'agent-batch-todos "0.3")

(define-obsolete-function-alias 'agent-claude-send-todo-at-point
  #'agent-send-todo-at-point "0.3")

(defcustom agent-claude-status-interval 5
  "Interval in seconds between status file polls."
  :type 'integer
  :group 'agent-claude)

(defcustom agent-claude-usage-interval 300
  "Base interval in seconds between usage API polls.
Fetches 5-hour session and 7-day weekly utilization from the API.
On HTTP 429 responses the interval doubles, up to
`agent-claude-usage-max-interval'; it resets on success."
  :type 'integer
  :group 'agent-claude)

(defcustom agent-claude-usage-max-interval 900
  "Maximum polling interval in seconds after repeated 429 backoffs."
  :type 'integer
  :group 'agent-claude)

(defcustom agent-claude-accounts nil
  "Alist of account names to `CLAUDE_CONFIG_DIR' paths.
Each entry is (NAME . CONFIG-DIR).  When non-nil,
`agent-claude-start-or-switch' uses the persisted account
selection and sets `CLAUDE_CONFIG_DIR' accordingly so each account
maintains its own OAuth credentials.

Use `agent-claude-select-account' to change the active account.
The selection persists in `agent-claude-account-file'.

Example:
  \\='((\"personal\" . \"~/.claude-personal\")
    (\"work\"     . \"~/.claude-work\"))"
  :type '(alist :key-type string :value-type directory)
  :group 'agent-claude)

(defcustom agent-claude-account-file
  (expand-file-name ".claude-current-account" "~")
  "File storing the name of the currently active Claude account.
The file contains a single account name from `agent-claude-accounts'.
Written by `agent-claude-select-account', read at session start."
  :type 'file
  :group 'agent-claude)

(defface agent-claude-waiting
  '((t :inherit warning))
  "Face for sessions waiting for user input in the session switcher."
  :group 'agent-claude)

(defcustom agent-claude-settings-file
  (expand-file-name "settings.json" "~/.claude/")
  "Claude Code settings file updated by setup commands."
  :type 'file
  :group 'agent-claude)

(defcustom agent-claude-hook-wrapper
  (when-let* ((library (locate-library "claude-code")))
    (expand-file-name "bin/claude-code-hook-wrapper"
                      (file-name-directory library)))
  "Absolute path to the claude-code hook wrapper script."
  :type '(choice (const :tag "Unavailable" nil) file)
  :group 'agent-claude)

(defconst agent-claude--hooks-directory
  (file-truename
   (expand-file-name "hooks/"
                     (file-name-directory
                      (file-truename
                       (or load-file-name buffer-file-name)))))
  "Absolute path to the bundled Claude hook helper directory.")

(defcustom agent-claude-status-directory
  (expand-file-name "claude-code-status/" temporary-file-directory)
  "Directory where the statusline script writes JSON status files."
  :type 'directory
  :group 'agent-claude)

(defcustom agent-claude-statusline-script
  (expand-file-name "etc/claude-code-statusline.sh"
                    (file-name-directory
                     (file-truename
                      (or load-file-name buffer-file-name))))
  "Absolute path to the bundled Claude Code statusline script."
  :type 'file
  :group 'agent-claude)

(defvar-local agent-claude--status-data nil
  "Parsed status plist for the current Claude buffer.")

(defvar-local agent-claude--original-session-id nil
  "Session ID when this buffer was first created.
Used to detect when `/branch' creates a new session.")

(defvar-local agent-claude--status-polled-at nil
  "Value of `float-time' at the previous successful status poll.
Used to tell a turn that began since the last poll from one that also
ended in that window.")

(defvar-local agent-claude--status-timer nil
  "Timer for periodic status polling in the current Claude buffer.")

(defvar agent-claude--usage-data (make-hash-table :test #'equal)
  "Hash table mapping account names to parsed usage plists.")

(defvar agent-claude--usage-timer nil
  "Timer for periodic usage API polling.")

(defvar agent-claude--usage-current-interval nil
  "Current polling interval in seconds, possibly increased by backoff.")

(defvar agent-codex-mode)
(defvar eat-terminal)
(defvar url-http-end-of-headers)
(declare-function agent-svg-icon "agent" (svg-data &optional face))
(declare-function agent-act-on-slack-message "agent-slack" ())
(declare-function agent-batch-todos "agent-todo" ())
(declare-function agent-send-todo-at-point "agent-todo" ())
(declare-function claude-code--get-or-prompt-for-buffer "claude-code" ())
(declare-function claude-code--term-send-string "claude-code" (backend string))
(declare-function claude-code--directory "claude-code" ())
(declare-function claude-code--prompt-for-instance-name
                  "claude-code" (dir existing-instance-names &optional force-prompt))
(declare-function eat-self-input "eat" (n &optional e))
(declare-function eat-term-display-cursor "eat" (terminal))
(declare-function eat-term-send-string "eat" (terminal string))

;;;; Backend registration

(defconst agent-claude-icon-svg
  "<svg fill=\"none\" viewBox=\"0 0 24 24\" xmlns=\"http://www.w3.org/2000/svg\"><path clip-rule=\"evenodd\" d=\"M20.998 10.949H24v3.102h-3v3.028h-1.487V20H18v-2.921h-1.487V20H15v-2.921H9V20H7.488v-2.921H6V20H4.487v-2.921H3V14.05H0V10.95h3V5h17.998v5.949zM6 10.949h1.488V8.102H6v2.847zm10.51 0H18V8.102h-1.49v2.847z\" fill=\"#D97757\" fill-rule=\"evenodd\"/></svg>"
  "SVG path data for the Claude Code mascot (Clawd pixel art).
Source: lobehub/lobe-icons (MIT).")

(agent-register-backend 'claude-code
  :buffer-p #'claude-code--buffer-p
  :find-all-buffers #'claude-code--find-all-claude-buffers
  :find-buffers-for-dir #'claude-code--find-claude-buffers-for-directory
  :send-string #'agent-claude-send-command
  :submit #'agent-claude-submit-command
  :program "claude"
  :send-return #'agent-claude-send-return
  :icon (lambda (&optional face)
          (let ((svg (agent-svg-icon agent-claude-icon-svg face)))
            (if (string-empty-p svg) "CC" svg)))
  :account-env-var "CLAUDE_CONFIG_DIR"
  :accounts 'agent-claude-accounts
  :account-file 'agent-claude-account-file
  :shared-config-items 'agent-claude--shared-config-items
  :canonical-home "~/.claude/"
  :account-init #'agent-claude--sync-account-json
  :background-tasks-p #'agent-claude--has-background-tasks-p
  :duration-ms (lambda (buf)
                 (with-current-buffer buf
                   (agent-claude-status-duration-ms)))
  :display-name-suffix #'agent-claude--branch-suffix
  :label "Claude Code"
  :run-prompt #'agent-claude-run-prompt
  :exec-prompt #'agent-claude--run-prompt
  :notify #'agent-claude-notify
  :skill-roots #'agent-claude-skill-roots
  :skill-command-prefix "/"
  :start-session #'agent-claude--start-session
  :session-identity #'agent-claude--session-identity
  :sync-theme #'agent-claude--sync-theme
  :menu-suffixes #'agent-claude--menu-suffixes
  :session-headers #'agent-claude--session-headers
  :session-prompt #'agent-claude--session-prompt
  :prepare-fork #'agent-claude--prepare-fork
  :resume #'claude-code-resume)

;;;; Functions

;;;;; Exit

(defun agent-claude-send-command (cmd &optional buffer)
  "Insert CMD into BUFFER's Claude Code prompt without submitting it."
  (when-let* ((claude-buffer (agent-claude--target-buffer buffer)))
    (with-current-buffer claude-buffer
      (claude-code--term-send-string claude-code-terminal-backend cmd)
      (display-buffer claude-buffer))
    claude-buffer))

(defun agent-claude-send-return (&optional buffer)
  "Submit the active prompt in BUFFER's Claude Code session."
  (when-let* ((claude-buffer (agent-claude--target-buffer buffer)))
    (with-current-buffer claude-buffer
      (sit-for 0.1)
      (claude-code--term-send-string claude-code-terminal-backend (kbd "RET"))
      (display-buffer claude-buffer))
    claude-buffer))

(defun agent-claude-submit-command (cmd &optional buffer)
  "Insert CMD into BUFFER's Claude Code prompt and submit it atomically."
  (when-let* ((claude-buffer (agent-claude-send-command cmd buffer)))
    (agent-claude-send-return claude-buffer)))

(defun agent-claude--target-buffer (buffer)
  "Return the Claude Code target BUFFER, current buffer, or prompted buffer."
  (cond
   ((and (buffer-live-p buffer)
         (claude-code--buffer-p buffer))
    buffer)
   ((claude-code--buffer-p (current-buffer))
    (current-buffer))
   (t
    (claude-code--get-or-prompt-for-buffer))))

(define-obsolete-function-alias 'agent-claude-exit #'agent-exit "0.2")

;;;;; C-g fix

(defun agent-claude--send-escape-in-current-buffer (orig-fn)
  "When already in a Claude buffer, send escape directly without prompting.
ORIG-FN is `claude-code-send-escape'.  The upstream implementation uses
`claude-code--with-buffer', which re-resolves the target buffer via
`claude-code--get-or-prompt-for-buffer'.  When multiple sessions share
the same project directory, that triggers a selection prompt--defeating
the purpose of \\`ESC\\' as a quick interrupt.  This advice short-circuits
the lookup: if the current buffer is already a Claude buffer, send the
escape sequence directly to it."
  (if (claude-code--buffer-p (current-buffer))
      (claude-code--term-send-string claude-code-terminal-backend (kbd "ESC"))
    (funcall orig-fn)))

;;;;; Buffer protection

(define-obsolete-function-alias 'agent-claude-setup-kill-on-exit
  #'agent-setup-kill-on-exit "0.2")

;;;;; Smart start

(defconst agent-claude--account-auth-shadow-env
  '("ANTHROPIC_API_KEY" "ANTHROPIC_AUTH_TOKEN" "CLAUDE_CODE")
  "Environment variable names removed from account Claude Code sessions.
Each is a bare variable name without a trailing \"=\", so the variable is
unset for the launched process and every subprocess it spawns, rather than
set to the empty string.  An empty ANTHROPIC_AUTH_TOKEN is inherited by
subprocesses and makes the Anthropic SDK build an illegal empty
\"Authorization: Bearer\" header, surfacing as a misleading connection
error; see `process-environment'.  This mirrors the shell `claude' shim,
which clears the same variables with `unset'.")

(defun agent-claude-account-env (_buffer-name _dir)
  "Return `CLAUDE_CONFIG_DIR' for the Claude session being started.
Resolves the account via `agent-account-resolve' (the in-flight
start binding first, then the persisted selection) and never
prompts or touches the filesystem."
  (when-let* ((account (agent-account-resolve 'claude-code)))
    (append (agent-account-env 'claude-code account)
            agent-claude--account-auth-shadow-env)))

(defconst agent-claude--shared-config-items
  '("settings.json" "settings.local.json"
    "skills" "plugins" "projects" "memory" "history.jsonl")
  "Files and directories symlinked from `~/.claude/' into each account config dir.
These items are shared across all accounts so that skills, plugins,
project trust, memory, session history, permissions, and hooks are
available regardless of which account is active.  Only OAuth
credentials remain account-specific.")

(defun agent-claude--sync-account-json (account)
  "Sync shared `.claude.json' state into ACCOUNT's config directory.
Deep-merges `mcpServers' per-server from canonical, preserving
per-account `env' entries (e.g. account-specific API keys).
Copies theme and chrome settings verbatim.  Merges the `projects'
key from all account configs so folder trust decisions are
available everywhere.  Directory creation and shared symlinks are
handled by `agent-account-sync', which calls this function as the
backend's account-init step.

Only writes `.claude.json' when actual changes are detected, to
avoid triggering file-change detection in running Claude Code
sessions."
  (when-let* ((config-dir (alist-get account agent-claude-accounts
                                     nil nil #'string=))
              (target-path (expand-file-name
                            ".claude.json" (expand-file-name config-dir))))
    (condition-case err
        (let* ((target (agent-claude-cli-read-claude-json target-path))
               (canonical (agent-claude-cli-read-claude-json
                           (expand-file-name ".claude.json" "~")))
               (merged-projects (agent-claude--collect-all-projects))
               (changed nil))
          (when target
            ;; Sync shared keys from canonical config.
            (when canonical
              (dolist (key agent-claude-cli-shared-claude-json-keys)
                (let ((val (gethash key canonical)))
                  (when (and val
                             (not (equal (json-serialize
                                         (gethash key target))
                                        (json-serialize val))))
                    (puthash key val target)
                    (setq changed t))))
              ;; Deep-merge mcpServers per-server, preserving per-account env.
              (when-let* ((canonical-servers (gethash "mcpServers" canonical)))
                (let ((merged (agent-claude-cli-merge-mcp-servers
                               canonical-servers
                               (gethash "mcpServers" target))))
                  (unless (equal (json-serialize (gethash "mcpServers" target))
                                 (json-serialize merged))
                    (puthash "mcpServers" merged target)
                    (setq changed t)))))
            ;; Merge projects from all accounts.
            (when (> (hash-table-count merged-projects) 0)
              (unless (equal (json-serialize (gethash "projects" target))
                             (json-serialize merged-projects))
                (puthash "projects" merged-projects target)
                (setq changed t)))
            (when changed
              (agent-claude-cli-write-claude-json target-path target))))
      (error
       (message "agent-claude: failed to sync account config: %S" err)))))

(defun agent-claude--collect-all-projects ()
  "Collect and merge `projects' from all `.claude.json' sources.
Reads the canonical `~/.claude.json' first, then each account
config.  For duplicate keys, prefers entries where
`hasTrustDialogAccepted' is true."
  (let ((merged (make-hash-table :test #'equal))
        (paths (agent-claude--all-claude-json-paths)))
    (dolist (path paths)
      (when-let* ((data (agent-claude-cli-read-claude-json path))
                  (projects (gethash "projects" data)))
        (when (hash-table-p projects)
          (maphash (lambda (key val)
                     (agent-claude-cli-merge-project merged key val))
                   projects))))
    merged))

(defun agent-claude--all-claude-json-paths ()
  "Return paths to the canonical and all account `.claude.json' files."
  (cons (expand-file-name ".claude.json" "~")
        (mapcar (lambda (entry)
                  (expand-file-name ".claude.json"
                                    (expand-file-name (cdr entry))))
                agent-claude-accounts)))

;;;###autoload
(defun agent-claude-select-account ()
  "Switch the active Claude account.
Prompts for an account from `agent-claude-accounts', persists the
selection, and syncs the account's config directory.  New sessions
will use this account."
  (interactive)
  (agent-account-select 'claude-code))

;;;###autoload
(defun agent-claude-init-account (account)
  "Initialize ACCOUNT's config directory without switching to it.
Creates the config directory and all shared symlinks pointing at
`~/.claude/', then merges shared `.claude.json' state.  Safe to
call on an already-initialized account.  Does not change the
persisted active account."
  (interactive
   (list (completing-read "Initialize account: "
                          (mapcar #'car agent-claude-accounts)
                          nil t)))
  (agent-account-init 'claude-code account))

(defun agent-claude--start-new ()
  "Start a new Claude session using the current account."
  (interactive)
  (agent-start-session
   (agent-session-create :backend 'claude-code
                         :account (agent-account-resolve 'claude-code t))))

;;;###autoload
(defun agent-claude-start-or-switch ()
  "Start a new Claude session or switch to an existing one.
If no sessions are active, start a new one.  If sessions exist,
show the unified session switcher."
  (interactive)
  (if (null (claude-code--find-all-claude-buffers))
      (agent-claude--start-new)
    (agent--ensure-all-session-keys)
    (transient-setup 'agent--session-switcher)))

(defun agent-claude--branch-suffix (buffer)
  "Return a short branch ID for BUFFER, or nil if not branched."
  (with-current-buffer buffer
    (let ((original agent-claude--original-session-id)
          (current (when agent-claude--status-data
                     (plist-get agent-claude--status-data :session_id))))
      (when (and original current (not (string= original current)))
        (substring current 0 8)))))

;;;;; Status polling

(defun agent-claude-start-status-polling ()
  "Start polling the status file for the current Claude buffer."
  (interactive)
  (when (claude-code--buffer-p (current-buffer))
    (when agent-claude--status-timer
      (cancel-timer agent-claude--status-timer))
    (let* ((buf (current-buffer))
           (timer-cell (cons nil nil))
           (timer (run-with-timer
                   agent-claude-status-interval
                   agent-claude-status-interval
                   #'agent-claude--read-status
                   timer-cell buf)))
      (setcar timer-cell timer)
      (setq agent-claude--status-timer timer))))

(defvar monet--sessions)
(declare-function monet--session-server "monet")
(declare-function monet--session-port "monet")
(declare-function monet--session-directory "monet")
(declare-function monet--remove-lockfile "monet")
(declare-function websocket-server-close "websocket")

(defvar agent-claude--pending-monet-key nil
  "Monet session key for the Claude process currently being started.")

(defvar agent-claude--pending-monet-server nil
  "Monet websocket server for the Claude process currently being started.")

(defvar-local agent-claude--monet-key nil
  "Monet session key owned by this Claude buffer.")

(defvar-local agent-claude--monet-server nil
  "Monet websocket server process owned by this Claude buffer.")

(defun agent-claude--monet-stop-session (key)
  "Fully stop the monet session for KEY.
Closes the websocket server, removes the lockfile, and removes
the session from `monet--sessions'."
  (when-let ((session (and key (gethash key monet--sessions))))
    (ignore-errors
      (monet--remove-lockfile (monet--session-port session)))
    (when-let ((server (monet--session-server session)))
      (agent-claude--monet-close-server server))
    (remhash key monet--sessions)))

(defun agent-claude--monet-close-server (server)
  "Close the listening websocket SERVER process, forcing it if needed."
  (when (process-live-p server)
    (ignore-errors (websocket-server-close server))
    (when (process-live-p server)
      (delete-process server))))

(defun agent-claude--monet-close-server-on-disconnect (session &rest _)
  "Close SESSION's websocket server when its Claude client disconnects.
`monet--on-close-server' drops the session from `monet--sessions'
but leaves the listening server process alive, so it escapes
session teardown.  Closing it here reaps the server at the source
of the disconnect instead of waiting for the GC safety net."
  (when-let* ((server (monet--session-server session)))
    (agent-claude--monet-close-server server)))

(defun agent-claude--cleanup-monet-session ()
  "Clean up the monet websocket session for the current Claude buffer."
  (when (or (claude-code--buffer-p (current-buffer))
            agent-claude--monet-key
            agent-claude--monet-server)
    (when (boundp 'monet--sessions)
      (agent-claude--monet-stop-session
       (or agent-claude--monet-key (buffer-name))))
    (when agent-claude--monet-server
      (agent-claude--monet-close-server agent-claude--monet-server))
    (setq agent-claude--monet-key nil)
    (setq agent-claude--monet-server nil)))

(defun agent-claude--monet-cleanup-before-start (orig-fn key directory)
  "Clean up old monet session for KEY before starting a new one.
ORIG-FN is called with KEY and DIRECTORY after cleanup."
  (when (agent-claude--monet-claude-key-p key)
    (setq agent-claude--pending-monet-key nil)
    (setq agent-claude--pending-monet-server nil))
  (when (and (boundp 'monet--sessions)
             (gethash key monet--sessions))
    (agent-claude--monet-stop-session key))
  (let* ((result (funcall orig-fn key directory))
         (server (and result
                      (fboundp 'monet--session-server)
                      (monet--session-server result))))
    (agent-claude--monet-register-server server)
    (when (agent-claude--monet-claude-key-p key)
      (setq agent-claude--pending-monet-key key)
      (setq agent-claude--pending-monet-server server))
    result))

(defun agent-claude--monet-claude-key-p (key)
  "Return non-nil when KEY names a Claude Code session buffer."
  (and (stringp key)
       (string-prefix-p "*claude:" key)))

(defun agent-claude--capture-monet-key ()
  "Store pending or existing Monet session data for this Claude buffer."
  (when (claude-code--buffer-p (current-buffer))
    (if agent-claude--pending-monet-key
        (progn
          (setq agent-claude--monet-key agent-claude--pending-monet-key)
          (setq agent-claude--monet-server agent-claude--pending-monet-server)
          (setq agent-claude--pending-monet-key nil)
          (setq agent-claude--pending-monet-server nil))
      (agent-claude--adopt-existing-monet-session))))

(defun agent-claude--adopt-existing-monet-session ()
  "Record the current buffer's already-running Monet session."
  (when (boundp 'monet--sessions)
    (let* ((key (or agent-claude--monet-key (buffer-name)))
           (session (and key (gethash key monet--sessions))))
      (when session
        (setq agent-claude--monet-key key)
        (setq agent-claude--monet-server
              (and (fboundp 'monet--session-server)
                   (monet--session-server session)))
        (agent-claude--monet-register-server agent-claude--monet-server)))))

(defvar agent-claude--monet-owned-servers nil
  "Websocket server processes created or adopted through monet.
The leak GC sweep inspects only the processes in this list, so websocket
servers owned by other packages (such as atomic-chrome or org-roam-ui)
can never be mistaken for leaked monet servers.")

(defun agent-claude--monet-register-server (server)
  "Record SERVER as a monet-owned websocket server process."
  (when (and (processp server)
             (not (memq server agent-claude--monet-owned-servers)))
    (push server agent-claude--monet-owned-servers)))

(defun agent-claude--monet-gc-orphaned-servers ()
  "Delete monet-owned server processes not tracked by any monet session.
Runs periodically as a safety net to catch servers leaked through any
monet code path.  Only servers registered in
`agent-claude--monet-owned-servers' are considered, so the sweep never
touches websocket servers created by other packages."
  (setq agent-claude--monet-owned-servers
        (seq-filter #'process-live-p agent-claude--monet-owned-servers))
  (when (boundp 'monet--sessions)
    (let ((active-servers (agent-claude--monet-active-servers)))
      (dolist (p agent-claude--monet-owned-servers)
        (when (and (eq (process-status p) 'listen)
                   (not (memq p active-servers)))
          (agent--report-leak "monet server" "%s escaped session teardown"
                              (process-name p))
          (delete-process p)
          (setq agent-claude--monet-owned-servers
                (delq p agent-claude--monet-owned-servers)))))))

(defun agent-claude--monet-active-servers ()
  "Return the server processes tracked by `monet--sessions'."
  (let (servers)
    (maphash (lambda (_k session)
               (when-let* ((server (monet--session-server session)))
                 (push server servers)))
             monet--sessions)
    servers))

(defun agent-claude--diff-file-in-session-p (diff-buffer session)
  "Return non-nil if DIFF-BUFFER's file is inside SESSION's directory."
  (when-let ((session-dir (and session (monet--session-directory session)))
             (file-dir (buffer-local-value 'default-directory diff-buffer)))
    (file-in-directory-p (expand-file-name file-dir)
                         (file-name-as-directory
                          (expand-file-name session-dir)))))

(defun agent-claude--display-diff-buffer (diff-buffer &optional session)
  "Display DIFF-BUFFER in a bottom side window without switching tabs.
Override for `monet--display-diff-buffer' that avoids the tab-switching
side effects of `display-buffer-in-tab', which can corrupt the window
layout when called from an async websocket callback.
When SESSION is provided and the file is outside the session directory,
the diff is suppressed entirely; the terminal approval prompt suffices."
  (if (and session (not (agent-claude--diff-file-in-session-p diff-buffer session)))
      nil
    (display-buffer diff-buffer
                    '((display-buffer-in-side-window)
                      (side . bottom)
                      (slot . 0)
                      (window-height . 0.3)
                      (preserve-size . (nil . t))))))

(defvar agent-claude--monet-gc-timer nil
  "Repeating timer that reports and reaps leaked monet servers.
Owned by `agent-claude-mode': started on enable, cancelled on
disable.")

(defun agent-claude--monet-install ()
  "Install monet advice and the leak-reporting GC timer.
Idempotent, so deferred installs after re-enables are safe."
  (advice-add 'monet-start-server-in-directory :around
              #'agent-claude--monet-cleanup-before-start)
  (advice-add 'monet--on-close-server :after
              #'agent-claude--monet-close-server-on-disconnect)
  (advice-add 'monet--display-diff-buffer :override
              #'agent-claude--display-diff-buffer)
  (unless agent-claude--monet-gc-timer
    (setq agent-claude--monet-gc-timer
          (run-with-timer 60 60 #'agent-claude--monet-gc-orphaned-servers))))

(defun agent-claude--monet-remove ()
  "Remove monet advice and cancel the GC timer."
  (advice-remove 'monet-start-server-in-directory
                 #'agent-claude--monet-cleanup-before-start)
  (advice-remove 'monet--on-close-server
                 #'agent-claude--monet-close-server-on-disconnect)
  (advice-remove 'monet--display-diff-buffer
                 #'agent-claude--display-diff-buffer)
  (when agent-claude--monet-gc-timer
    (cancel-timer agent-claude--monet-gc-timer)
    (setq agent-claude--monet-gc-timer nil)))

(defun agent-claude-stop-status-polling ()
  "Stop status polling and clean up the status file."
  (interactive)
  (when (and (claude-code--buffer-p (current-buffer))
             agent-claude--status-timer)
    (cancel-timer agent-claude--status-timer)
    (agent-claude--cleanup-status-file)))

(defun agent-claude--read-status (timer-cell buffer)
  "Read and parse the status file for BUFFER.
TIMER-CELL is a cons whose car is the timer that triggered this
call; it is canceled automatically when BUFFER is no longer live.
Each poll also records the reported native session id through
`agent--note-session-id', so the session struct tracks branch
switches as soon as the status line reports them."
  (if (not (buffer-live-p buffer))
      (progn
        (agent--report-leak "status timer" "poll timer outlived %s" buffer)
        (cancel-timer (car timer-cell)))
    (with-current-buffer buffer
      (when-let* ((data (agent-claude--parse-status-file)))
        (agent-claude--detect-branch data)
        (agent--note-session-id buffer (plist-get data :session_id))
        (agent-claude--detect-turn-start data buffer)
        (setq agent-claude--status-data data)
        (setq agent-claude--status-polled-at (float-time))))))

(defun agent-claude--detect-turn-start (new-data buffer)
  "Mark BUFFER busy when NEW-DATA reports a turn that has not been seen.
NEW-DATA is the freshly parsed status plist.

Claude Code publishes no turn-start hook, so a turn the user did not
type -- one driven by remote control, a scheduled task, or a resumed
background job -- is otherwise unobservable, and the session keeps
displaying as waiting while it works.  The statusline reports a fresh
`prompt_id' for every turn whatever its origin, so a changed value
means a new turn began.

A turn shorter than the poll interval both starts and ends between two
polls.  Its `stop' event has already landed by the time the change is
noticed, so treating it as a start would strand the session as busy.
`agent-claude--turn-ended-since-last-poll-p' detects that case, and the
new identifier is recorded without marking the session busy."
  (let ((new-id (plist-get new-data :prompt_id))
        (old-id (plist-get agent-claude--status-data :prompt_id)))
    (when (and new-id old-id
               (not (string= new-id old-id))
               (not (agent-claude--turn-ended-since-last-poll-p buffer)))
      (agent-session-event buffer 'activity))))

(defun agent-claude--turn-ended-since-last-poll-p (buffer)
  "Return non-nil when BUFFER stopped responding since the previous poll."
  (let ((changed (buffer-local-value 'agent--session-state-changed-at buffer))
        (polled agent-claude--status-polled-at))
    (and changed polled (> changed polled)
         (eq (buffer-local-value 'agent--session-state buffer)
             'awaiting-input))))

(defun agent-claude--detect-branch (new-data)
  "Detect a session ID change, indicating a branch.
NEW-DATA is the freshly parsed status plist.  On the first poll,
records the session ID as the original.  On subsequent polls, if
the ID differs from the previous one, refreshes display names so
the modeline reflects the new branch."
  (let ((new-id (plist-get new-data :session_id)))
    (when new-id
      (if (not agent-claude--original-session-id)
          (setq agent-claude--original-session-id new-id)
        (let ((old-id (plist-get agent-claude--status-data :session_id)))
          (when (and old-id (not (string= new-id old-id)))
            (agent--refresh-display-names)))))))

(defun agent-claude--parse-status-file ()
  "Parse the status JSON file for the current buffer.
Returns a plist, or nil if the file is missing or malformed."
  (let ((file (agent-claude--status-file)))
    (when (file-exists-p file)
      (condition-case nil
          (json-parse-string
           (with-temp-buffer
             (insert-file-contents file)
             (buffer-string))
           :object-type 'plist)
        (json-parse-error nil)))))

(defvar agent-claude--pending-status-uuid nil
  "Status UUID for the Claude process currently being started.
Set by `agent-claude--status-uuid-env' on the environment hook and
consumed by `agent-claude--capture-status-uuid' on the start hook.")

(defvar-local agent-claude--status-uuid nil
  "Per-process UUID keying this session's statusline file.
Restarted sessions reuse buffer names, so files keyed by buffer
name would be inherited from dead processes; the UUID is unique
per CLI process.")

(defun agent-claude--status-uuid-env (_buffer-name _dir)
  "Return the AGENT_SESSION_UUID environment entry for a new session."
  (setq agent-claude--pending-status-uuid (agent-claude--generate-uuid))
  (list (format "AGENT_SESSION_UUID=%s" agent-claude--pending-status-uuid)))

(defun agent-claude--capture-status-uuid ()
  "Store the pending status UUID buffer-locally at session start."
  (when (claude-code--buffer-p (current-buffer))
    (setq agent-claude--status-uuid agent-claude--pending-status-uuid)
    (setq agent-claude--pending-status-uuid nil)))

(defun agent-claude--generate-uuid ()
  "Return a random UUID-shaped string for status-file identity."
  (format "%08x-%04x-%04x-%04x-%012x"
          (random (expt 2 32)) (random (expt 2 16)) (random (expt 2 16))
          (random (expt 2 16)) (random (expt 2 48))))

(defun agent-claude--status-file ()
  "Return the status file path for the current buffer.
Keyed by the per-process UUID when available; falls back to the
buffer name for sessions started before the UUID existed."
  (expand-file-name
   (concat (secure-hash 'sha256 (or agent-claude--status-uuid (buffer-name)))
           ".json")
   agent-claude-status-directory))

(defun agent-claude--cleanup-status-file ()
  "Delete the status file for the current buffer."
  (let ((file (agent-claude--status-file)))
    (when (file-exists-p file)
      (delete-file file))))

(defconst agent-claude--status-file-max-age (* 7 24 60 60)
  "Seconds after which an unclaimed status file is considered stale.")

(defun agent-claude--sweep-stale-status-files ()
  "Delete status files older than `agent-claude--status-file-max-age'."
  (when (file-directory-p agent-claude-status-directory)
    (dolist (file (directory-files agent-claude-status-directory t "\\.json\\'"))
      (when-let* ((mtime (file-attribute-modification-time
                          (file-attributes file))))
        (when (> (float-time (time-subtract (current-time) mtime))
                 agent-claude--status-file-max-age)
          (delete-file file))))))

;;;;; Usage polling

(defun agent-claude--fetch-usage ()
  "Fetch usage data for all accounts with active sessions."
  (dolist (account (agent-claude--active-accounts))
    (agent-claude--fetch-usage-for-account account)))

(defun agent-claude--fetch-usage-for-account (account)
  "Fetch usage data for ACCOUNT asynchronously.
Reads the OAuth token from the macOS Keychain and queries the
undocumented `api/oauth/usage' endpoint.  Stores the parsed
response in `agent-claude--usage-data' keyed by ACCOUNT."
  (when-let* ((token (agent-claude-cli-oauth-token
                      (agent-claude--account-config-dir account))))
    (agent-claude--fetch-usage-with-token account token t)))

(defun agent-claude--account-config-dir (account)
  "Return the expanded `CLAUDE_CONFIG_DIR' for ACCOUNT, or nil.
Nil means ACCOUNT uses the default `~/.claude' configuration,
either because ACCOUNT is nil or because it has no entry in
`agent-claude-accounts'."
  (when-let* ((config-dir (and (stringp account)
                               (alist-get account agent-claude-accounts
                                          nil nil #'string=))))
    (expand-file-name config-dir)))

(defun agent-claude--fetch-usage-with-token (account token retry)
  "Fetch usage data for ACCOUNT with TOKEN.
If RETRY is non-nil, retry stale URL process write failures once."
  (condition-case err
      (agent-claude--url-retrieve-usage account token)
    (file-error
     (agent-claude--handle-usage-retrieve-error account token err retry))))

(defun agent-claude--url-retrieve-usage (account token)
  "Start the async usage request for ACCOUNT with TOKEN."
  (agent-claude-cli-fetch-usage
   token #'agent-claude--handle-usage-response (list account)))

(defun agent-claude--handle-usage-retrieve-error (account token err retry)
  "Handle synchronous usage request error ERR for ACCOUNT.
TOKEN is reused only when RETRY allows a stale-process retry."
  (agent-claude--delete-error-process err)
  (if (and retry (agent-claude--url-process-write-error-p err))
      (agent-claude--fetch-usage-with-token account token nil)
    (message "agent-claude usage poll failed for %s: %s"
             (or account "default")
             (error-message-string err))
    (agent-claude--usage-backoff)))

(defun agent-claude--url-process-write-error-p (err)
  "Return non-nil if ERR is a URL process write failure."
  (and (eq (car-safe err) 'file-error)
       (member "Writing to process" (cdr err))
       (agent-claude--error-process err)))

(defun agent-claude--delete-error-process (err)
  "Delete the process recorded in ERR, if any."
  (when-let* ((process (agent-claude--error-process err)))
    (delete-process process)))

(defun agent-claude--error-process (err)
  "Return the first process object recorded in ERR."
  (let ((items (cdr-safe err))
        process)
    (while (and items (not process))
      (when (processp (car items))
        (setq process (car items)))
      (setq items (cdr items)))
    process))

(defun agent-claude--handle-usage-response (status account)
  "Handle the async usage API response for ACCOUNT.
STATUS is the plist passed by `url-retrieve'."
  (unwind-protect
      (let ((err (plist-get status :error)))
        (if (agent-claude--usage-response-429-p err)
            (agent-claude--usage-backoff)
          (when (and (null err) url-http-end-of-headers)
            (goto-char url-http-end-of-headers)
            (condition-case nil
                (progn
                  (puthash account
                           (json-parse-buffer :object-type 'plist)
                           agent-claude--usage-data)
                  (agent-claude--usage-reset-interval))
              (json-parse-error nil)))))
    (kill-buffer)))

(defun agent-claude--usage-response-429-p (err)
  "Return non-nil if ERR indicates an HTTP 429 response."
  (and (consp err)
       (eq (car err) 'error)
       (member 429 (cdr err))))

(defun agent-claude--usage-backoff ()
  "Double the polling interval, capped at the configured maximum."
  (let ((new-interval (min (* 2 (or agent-claude--usage-current-interval
                                    agent-claude-usage-interval))
                           agent-claude-usage-max-interval)))
    (setq agent-claude--usage-current-interval new-interval)
    (agent-claude--usage-reschedule new-interval)))

(defun agent-claude--usage-reset-interval ()
  "Reset the polling interval to the base value after a successful fetch."
  (when (and agent-claude--usage-current-interval
             (> agent-claude--usage-current-interval
                agent-claude-usage-interval))
    (setq agent-claude--usage-current-interval
          agent-claude-usage-interval)
    (agent-claude--usage-reschedule
     agent-claude-usage-interval)))

(defun agent-claude--usage-reschedule (interval)
  "Cancel the current usage timer and restart it with INTERVAL seconds."
  (when agent-claude--usage-timer
    (cancel-timer agent-claude--usage-timer)
    (setq agent-claude--usage-timer
          (run-with-timer interval interval
                          #'agent-claude--fetch-usage))))

(defun agent-claude--session-account (&optional buffer)
  "Return the account recorded for BUFFER's Claude session, or nil."
  (when-let* ((session (agent-session buffer)))
    (agent-session-account session)))

(defun agent-claude--active-accounts ()
  "Return a list of unique account names with active Claude sessions.
Returns a list containing nil when no multi-account setup exists."
  (let ((accounts nil))
    (dolist (buf (claude-code--find-all-claude-buffers))
      (when (buffer-live-p buf)
        (cl-pushnew (agent-claude--session-account buf) accounts
                    :test #'equal)))
    (or accounts (list nil))))

(defun agent-claude-start-usage-polling ()
  "Start polling the usage API.
Does nothing if the timer is already running."
  (interactive)
  (unless agent-claude--usage-timer
    (setq agent-claude--usage-current-interval
          agent-claude-usage-interval)
    (agent-claude--fetch-usage)
    (setq agent-claude--usage-timer
          (run-with-timer
           agent-claude-usage-interval
           agent-claude-usage-interval
           #'agent-claude--fetch-usage))))

(defun agent-claude-stop-usage-polling ()
  "Stop polling the usage API."
  (interactive)
  (when agent-claude--usage-timer
    (cancel-timer agent-claude--usage-timer)
    (setq agent-claude--usage-timer nil
          agent-claude--usage-current-interval nil)))

(defvar-local agent-claude--session-teardown-registered nil
  "Non-nil when this Claude buffer has registered session teardown.")

(defun agent-claude--register-session-teardown ()
  "Register per-session cleanup for the current Claude session.
Idempotently pushes one closure that cancels the status timer,
deletes the status file, stops the monet session, and stops usage
polling when this was the last live Claude session.  Also ensures
the account-wide usage poller is running."
  (when (claude-code--buffer-p (current-buffer))
    (agent-claude--adopt-existing-monet-session)
    (if (agent-claude--session-teardown-registered-p)
        (setq agent-claude--session-teardown-registered t)
      (setq agent-claude--session-teardown-registered t)
      (agent--install-session-teardown)
      (let ((buffer (current-buffer)))
        (push (lambda ()
                (when agent-claude--status-timer
                  (cancel-timer agent-claude--status-timer)
                  (setq agent-claude--status-timer nil))
                (agent-claude--cleanup-status-file)
                (agent-claude--cleanup-monet-session)
                (agent-claude--maybe-stop-usage-polling buffer))
              agent--teardown-functions)))
    (agent-claude-start-usage-polling)))

(defun agent-claude--session-teardown-registered-p ()
  "Return non-nil when current Claude buffer already has teardown."
  (or agent-claude--session-teardown-registered
      (and agent--teardown-functions
           (memq #'agent--session-teardown-current kill-buffer-hook))))

(defun agent-claude--maybe-stop-usage-polling (buffer)
  "Stop usage polling when BUFFER was the last live Claude session."
  (when (null (cl-remove buffer
                         (cl-remove-if-not #'buffer-live-p
                                           (claude-code--find-all-claude-buffers))))
    (agent-claude-stop-usage-polling)))

;;;;; Status accessors

(defun agent-claude-status-model ()
  "Return the model display name from the status data."
  (when-let* ((model (plist-get agent-claude--status-data :model)))
    (plist-get model :display_name)))

(defun agent-claude-status-effort ()
  "Return the reasoning effort level from the status data."
  (when-let* ((effort (plist-get agent-claude--status-data :effort)))
    (plist-get effort :level)))

(defun agent-claude-status-cost ()
  "Return the total session cost in USD from the status data."
  (when-let* ((cost (plist-get agent-claude--status-data :cost)))
    (plist-get cost :total_cost_usd)))

(defun agent-claude-status-context-percent ()
  "Return the context window usage percentage from the status data."
  (when-let* ((ctx (plist-get agent-claude--status-data :context_window)))
    (plist-get ctx :used_percentage)))

(defun agent-claude-status-token-count ()
  "Return the total input token count from the status data."
  (when-let* ((ctx (plist-get agent-claude--status-data :context_window)))
    (plist-get ctx :total_input_tokens)))

(defun agent-claude-status-lines-added ()
  "Return the total lines added from the status data."
  (when-let* ((cost (plist-get agent-claude--status-data :cost)))
    (plist-get cost :total_lines_added)))

(defun agent-claude-status-lines-removed ()
  "Return the total lines removed from the status data."
  (when-let* ((cost (plist-get agent-claude--status-data :cost)))
    (plist-get cost :total_lines_removed)))

(defun agent-claude-status-duration-ms ()
  "Return the total session duration in milliseconds from the status data."
  (when-let* ((cost (plist-get agent-claude--status-data :cost)))
    (plist-get cost :total_duration_ms)))

(defun agent-claude-status-cache-read-tokens ()
  "Return the cache read input token count from the status data."
  (when-let* ((ctx (plist-get agent-claude--status-data :context_window))
              (usage (plist-get ctx :current_usage)))
    (plist-get usage :cache_read_input_tokens)))

(defun agent-claude-status-cache-total-tokens ()
  "Return the total input tokens for the current turn from the status data.
This is the sum of INPUT_TOKENS, CACHE_CREATION_INPUT_TOKENS, and
CACHE_READ_INPUT_TOKENS."
  (when-let* ((ctx (plist-get agent-claude--status-data :context_window))
              (usage (plist-get ctx :current_usage)))
    (let ((input (or (plist-get usage :input_tokens) 0))
          (creation (or (plist-get usage :cache_creation_input_tokens) 0))
          (read (or (plist-get usage :cache_read_input_tokens) 0)))
      (+ input creation read))))

;;;;; Usage accessors

(defun agent-claude--usage-for-buffer ()
  "Return the usage plist for the current buffer's account."
  (gethash (agent-claude--session-account) agent-claude--usage-data))

(defun agent-claude-status-session-usage ()
  "Return the 5-hour session utilization percentage."
  (when-let* ((data (agent-claude--usage-for-buffer))
              (five (plist-get data :five_hour)))
    (plist-get five :utilization)))

(defun agent-claude-status-weekly-usage ()
  "Return the 7-day weekly utilization percentage."
  (when-let* ((data (agent-claude--usage-for-buffer))
              (seven (plist-get data :seven_day)))
    (plist-get seven :utilization)))

(defun agent-claude-status-session-reset ()
  "Return the 5-hour session reset time as an ISO string."
  (when-let* ((data (agent-claude--usage-for-buffer))
              (five (plist-get data :five_hour)))
    (plist-get five :resets_at)))

(defun agent-claude-status-weekly-reset ()
  "Return the 7-day weekly reset time as an ISO string."
  (when-let* ((data (agent-claude--usage-for-buffer))
              (seven (plist-get data :seven_day)))
    (plist-get seven :resets_at)))

;;;;; Alert

(defun agent-claude-notify (title message)
  "Notification function combining modeline pulse with optional alert.
TITLE is the notification title.  MESSAGE is the notification
body.  When `agent-alert-on-ready' is non-nil, dispatch to
the style configured in `agent-alert-style'."
  (claude-code-default-notification title message)
  (agent--alert-route title message))

(defun agent-claude--notification-type (json-str)
  "Extract the notification type from JSON-STR.
Return a string like \"idle_prompt\" or \"permission_prompt\", or
nil if the type cannot be determined."
  (when json-str
    (condition-case nil
        (let ((parsed (json-parse-string json-str :object-type 'alist)))
          (or (alist-get 'notification_type parsed)
              (alist-get 'type parsed)))
      (error nil))))

(defun agent-claude--note-submission (&rest _)
  "Emit a `submit' session event for the current Claude buffer.
Installed as advice on claude-code.el's send paths because that
package is third-party and exposes no submission hook.  Phase 7
moves the installation into a minor mode."
  (when (claude-code--buffer-p (current-buffer))
    (agent-session-event (current-buffer) 'submit)))

(defun agent-claude--handle-notification (message)
  "Handle a notification event from the Claude Code CLI.
MESSAGE is a plist with :type, :buffer-name, :json-data, and
:args.  Translates idle_prompt into a session event and fires OS
alerts for permission_prompt and elicitation_dialog notifications.

Permission and elicitation dialogs also mark the session as blocked on
the user.  Claude reaches them from inside a turn, with a tool call
still in flight, so nothing else reports them as waiting even though
they proceed only once the user answers."
  (when (eq (plist-get message :type) 'notification)
    (when-let* ((buf (get-buffer (plist-get message :buffer-name))))
      (let ((name (agent--buffer-session-name buf))
            (label (agent-backend-label (agent-backend 'claude-code)))
            (ntype (agent-claude--notification-type
                    (plist-get message :json-data))))
        (pcase ntype
          ("idle_prompt"
           (agent-session-event buf 'idle-prompt))
          ("permission_prompt"
           (agent-session-event buf 'blocked)
           (agent-claude-notify
            (format "%s needs approval" label)
            (format "%s: permission request pending" name)))
          ("elicitation_dialog"
           (agent-session-event buf 'blocked)
           (agent-claude-notify
            (format "%s needs input" label)
            (format "%s: waiting for your input" name)))
          (_
           (agent-claude-notify
            label
            (format "%s: needs your attention" name)))))))
  nil)

(defconst agent-claude--background-tasks-regexp
  "· *[0-9]+ +\\(shells?\\|monitors?\\)"
  "Regexp matching the background-task count in Claude's status line.
Claude Code renders \"· N shells\" or \"· N monitors\" near the
footer when background Bash processes or Task agent are running.")

(defconst agent-claude--remote-control-active-regexp
  "Remote Control active"
  "Regexp matching Claude's active Remote Control task UI.")

(defun agent-claude--has-background-tasks-p (&optional buffer)
  "Return non-nil when Claude session BUFFER has active background tasks.
Scans the tail of the terminal buffer for Claude Code's status
indicators, e.g. \"· 3 shells\", \"· 5 monitors\", or \"Remote
Control active\"."
  (let ((buf (or buffer (current-buffer))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (save-excursion
          (goto-char (point-max))
          (let ((limit (max (point-min) (- (point-max) 800))))
            (or (re-search-backward agent-claude--background-tasks-regexp
                                    limit t)
                (re-search-backward
                 agent-claude--remote-control-active-regexp
                 limit t))))))))

(defun agent-claude--handle-session-state (message)
  "Handle a turn-state event from the Claude Code CLI.
MESSAGE is a plist with :type, :buffer-name, :json-data, and :args.

Claude Code publishes no hook for the start of a turn, so turns the user
did not type cannot be observed directly.  The `notify-emacs-state.sh'
hook wrapper forwards ordinary lifecycle events in their place:
`activity' when the session is demonstrably working, and `blocked' when
it will not proceed without the user."
  (when-let* ((event (memq (plist-get message :type) '(activity blocked)))
              (buf (get-buffer (plist-get message :buffer-name))))
    (agent-session-event buf (car event)))
  nil)

(defun agent-claude--handle-stop (message)
  "Handle a stop event from the Claude Code CLI.
MESSAGE is a plist with :type, :buffer-name, :json-data, and
:args.  Translates the event into a `stop' session event."
  (when (eq (plist-get message :type) 'stop)
    (when-let* ((buf (get-buffer (plist-get message :buffer-name))))
      (agent-session-event buf 'stop)))
  nil)

;;;;; Modeline

(declare-function doom-modeline-set-modeline "doom-modeline-core")

(defun agent-claude-set-modeline ()
  "Set the doom-modeline to the `ai-session' modeline for this buffer.
Also starts status and usage polling if not already active."
  (when (claude-code--buffer-p (current-buffer))
    (unless agent-claude--status-timer
      (agent-claude-start-status-polling))
    (agent-claude-start-usage-polling)
    (when (require 'doom-modeline-core nil t)
      (doom-modeline-set-modeline 'ai-session))))

;;;;; Parameterized session start

(cl-defun agent-claude--start-session (session &key initial-prompt resume-id
                                               fork)
  "Start the Claude Code session described by SESSION; return its buffer.
SESSION is an `agent-session'.  INITIAL-PROMPT is passed to the Claude
CLI as the opening user message.  RESUME-ID resumes that session id.
FORK non-nil adds `--fork-session' to a resume.  The session account
is bound as `agent-account--starting' by `agent-start-session' so
environment hooks see it at spawn time."
  (let* ((switches (append (when resume-id (list "--resume" resume-id))
                           (when fork (list "--fork-session"))
                           (when initial-prompt (list initial-prompt))))
         (buffer (agent-claude--start-with-overrides
                  (agent-session-directory session)
                  (agent-session-instance session)
                  switches)))
    (agent--set-session buffer session)
    buffer))

(defun agent-claude--start-with-overrides (dir instance switches)
  "Run `claude-code--start' with DIR and INSTANCE injected.
SWITCHES are extra CLI switches.  A nil DIR or INSTANCE keeps the
upstream ambient behavior for that value.  This is the ONLY place that
rebinds the private `claude-code--directory' and
`claude-code--prompt-for-instance-name'; never add new `cl-letf' calls
against claude-code.el elsewhere."
  (let ((orig-directory (symbol-function 'claude-code--directory))
        (orig-prompt (symbol-function 'claude-code--prompt-for-instance-name)))
    (cl-letf (((symbol-function 'claude-code--directory)
               (lambda () (or dir (funcall orig-directory))))
              ((symbol-function 'claude-code--prompt-for-instance-name)
               (lambda (prompt-dir existing &optional force-prompt)
                 (or instance
                     (funcall orig-prompt prompt-dir existing force-prompt)))))
      (claude-code--start nil switches nil t))))

(defun agent-claude--session-identity (buffer)
  "Return the session id of the Claude session in BUFFER.
Signal a `user-error' when the status file is missing or names no
session id, so callers refuse to act before losing the session."
  (with-current-buffer buffer
    (agent-claude--current-session-id)))

;;;;; Non-interactive execution

(defcustom agent-claude-batch-allowed-tools nil
  "Tools to auto-allow via `--allowedTools' for non-interactive execution.
When nil (the default), no `--allowedTools' flag is passed and tool
access is governed by `agent-claude-batch-permission-mode'
and the user's settings.json."
  :type '(choice (const :tag "None (use permission-mode)" nil)
                 (repeat string))
  :group 'agent-claude)

(defcustom agent-claude-batch-permission-mode "auto"
  "Permission mode passed via `--permission-mode' for non-interactive execution.
The default \"auto\" uses a background classifier to allow most
actions while blocking risky ones (force pushes, mass deletion,
sending secrets to external endpoints, etc.)."
  :type '(choice (const :tag "Auto" "auto")
                 (const :tag "Bypass all" "bypassPermissions")
                 (const :tag "Default" "default")
                 (const :tag "Accept edits" "acceptEdits")
                 (const :tag "Don't ask" "dontAsk")
                 (const :tag "None" nil))
  :group 'agent-claude)

(defcustom agent-claude-batch-max-turns 30
  "Maximum agentic turns per entry in non-interactive execution."
  :type 'integer
  :group 'agent-claude)

(defcustom agent-claude-batch-system-prompt nil
  "Optional system prompt appended via `--append-system-prompt'.
When non-nil, passed to each `claude -p' invocation."
  :type '(choice (const :tag "None" nil) string)
  :group 'agent-claude)

(defcustom agent-claude-batch-model nil
  "Optional model override via `--model' for non-interactive execution.
When non-nil, passed to each `claude -p' invocation."
  :type '(choice (const :tag "Default" nil) string)
  :group 'agent-claude)

(defcustom agent-claude-run-skill-model "opus"
  "Model to use for `agent-claude-run-skill'.
Skills are complex agentic tasks that benefit from the most
capable model.  Supports aliases like \"opus\", \"sonnet\",
\"haiku\" as well as full model IDs.  Set to nil to use
`agent-claude-batch-model' or Claude's default."
  :type '(choice (const :tag "Opus (latest)" "opus")
                 (const :tag "Sonnet (latest)" "sonnet")
                 (const :tag "Haiku (latest)" "haiku")
                 (const :tag "Use batch default" nil)
                 string)
  :group 'agent-claude)

(defun agent-claude--parse-stream-json (raw)
  "Parse stream-json output RAW into a plist.
Returns (:text ASSISTANT-TEXT :cost COST :session-id ID
         :num-turns N :subtype TYPE)."
  (let (texts cost session-id num-turns subtype)
    (dolist (line (split-string raw "\n" t))
      (condition-case nil
          (let ((obj (json-parse-string line :object-type 'plist)))
            (pcase (plist-get obj :type)
              ("assistant"
               (let ((content (plist-get (plist-get obj :message) :content)))
                 (when (vectorp content)
                   (seq-doseq (block content)
                     (when (equal (plist-get block :type) "text")
                       (push (plist-get block :text) texts))))))
              ("result"
               (setq cost (or (plist-get obj :total_cost_usd)
                              (plist-get obj :cost_usd) 0)
                     session-id (plist-get obj :session_id)
                     num-turns (plist-get obj :num_turns)
                     subtype (plist-get obj :subtype)))))
        (error nil)))
    (list :text (if texts
                    (string-join (nreverse texts) "\n\n")
                  (format (concat "No assistant text captured.\n"
                                  "Session: %s | Turns: %s | Reason: %s\n"
                                  "Resume with: claude --resume %s")
                          (or session-id "?") (or num-turns "?")
                          (or subtype "unknown") (or session-id "?")))
          :cost (or cost 0)
          :session-id session-id)))

(defun agent-claude--build-cli-args (prompt &rest kwargs)
  "Build the argument list for `claude -p' with PROMPT.
KWARGS are keyword arguments:
  :allowed-tools   list of tool name strings
  :permission-mode permission mode string
  :system-prompt   string appended via --append-system-prompt
  :model           model name string
  :max-turns       integer, maximum agentic turns
Each defaults to the corresponding `agent-claude-batch-*'
customization variable when not supplied."
  (let ((allowed-tools (or (plist-get kwargs :allowed-tools)
                           agent-claude-batch-allowed-tools))
        (permission-mode (or (plist-get kwargs :permission-mode)
                             agent-claude-batch-permission-mode))
        (system-prompt (or (plist-get kwargs :system-prompt)
                           agent-claude-batch-system-prompt))
        (model (or (plist-get kwargs :model)
                   agent-claude-batch-model))
        (max-turns (or (plist-get kwargs :max-turns)
                       agent-claude-batch-max-turns))
        (args (list claude-code-program
                    "-p" prompt
                    "--output-format" "stream-json"
                    "--verbose")))
    (setq args (append args (list "--max-turns"
                                  (number-to-string max-turns))))
    (when permission-mode
      (setq args (append args (list "--permission-mode" permission-mode))))
    (when allowed-tools
      (setq args (append args (list "--allowedTools"
                                    (string-join allowed-tools ",")))))
    (when system-prompt
      (setq args (append args (list "--append-system-prompt"
                                    system-prompt))))
    (when model
      (setq args (append args (list "--model" model))))
    args))

(defun agent-claude--run-prompt (prompt &rest kwargs)
  "Run PROMPT non-interactively via `claude -p' and call back with results.
KWARGS are keyword arguments:
  :dir             working directory (default `default-directory')
  :callback        function called with a result plist (required)
  :allowed-tools   passed to `agent-claude--build-cli-args'
  :system-prompt   passed to `agent-claude--build-cli-args'
  :model           passed to `agent-claude--build-cli-args'
  :max-turns       passed to `agent-claude--build-cli-args'

The CALLBACK receives a plist with keys:
  :exit-code  process exit code
  :duration   elapsed seconds (float)
  :cost       USD cost (float)
  :text       parsed assistant text
  :session-id session ID string
  :raw        raw stream-json output

Returns the process object."
  (let* ((dir (or (plist-get kwargs :dir) default-directory))
         (callback (or (plist-get kwargs :callback)
                       (error "agent-claude--run-prompt: :callback required")))
         (args (apply #'agent-claude--build-cli-args prompt
                      (cl-loop for key in '(:allowed-tools :system-prompt
                                            :model :max-turns)
                               for val = (plist-get kwargs key)
                               when val append (list key val))))
         (env (agent-claude--exec-process-environment))
         (start-time (current-time))
         (output-buf (generate-new-buffer " *claude-run-output*")))
    (let ((process-environment env)
          (default-directory dir))
      (make-process
       :name "claude-run"
       :buffer output-buf
       :command args
       :sentinel
       (lambda (proc _event)
         (when (memq (process-status proc) '(exit signal))
           (let (result)
             (condition-case err
                 (let* ((exit-code (process-exit-status proc))
                        (raw (with-current-buffer (process-buffer proc)
                               (buffer-string)))
                        (duration (float-time
                                   (time-subtract (current-time) start-time)))
                        (parsed (agent-claude--parse-stream-json raw)))
                   (setq result (list :exit-code exit-code
                                      :duration duration
                                      :cost (or (plist-get parsed :cost) 0)
                                      :text (plist-get parsed :text)
                                      :session-id (plist-get parsed :session-id)
                                      :raw raw)))
               (error
                (setq result (list :exit-code -1
                                   :duration (float-time
                                              (time-subtract (current-time)
                                                             start-time))
                                   :cost 0
                                   :text (format "Sentinel error: %S" err)
                                   :session-id nil
                                   :raw ""))))
             (ignore-errors (kill-buffer (process-buffer proc)))
             (funcall callback result))))))))

(cl-defun agent-claude-run-prompt (prompt &key directory callback)
  "Run PROMPT through `claude -p' with the normalized agent signature.
DIRECTORY is the working directory; it defaults to
`default-directory'.  CALLBACK is called as (TEXT &key ERROR),
where ERROR is nil on success or a short failure description.
This is the `run-prompt' backend slot implementation."
  (agent-claude--run-prompt
   prompt
   :dir (or directory default-directory)
   :callback
   (lambda (result)
     (let ((code (plist-get result :exit-code)))
       (funcall callback (plist-get result :text)
                :error (unless (eq code 0)
                         (format "claude exited with exit code %s" code)))))))

(defun agent-claude--exec-process-environment ()
  "Return the process environment for a non-interactive Claude run."
  (if-let* ((account (agent-account-resolve 'claude-code))
            (env (agent-account-env 'claude-code account)))
      (append env
              (cl-remove-if
               (lambda (s)
                 (or (string-prefix-p "CLAUDE_CODE" s)
                     (string-prefix-p "ANTHROPIC_API_KEY=" s)
                     (string-prefix-p "ANTHROPIC_AUTH_TOKEN=" s)))
               process-environment))
    process-environment))

;;;;; Skill runner

(defun agent-claude-skill-roots ()
  "Return Claude skill roots as (DIRECTORY . STYLE) conses.
Global and project skills run via native slash expansion;
programmatic directories are pointed at by file."
  (let* ((project-root (or (when-let* ((proj (project-current)))
                             (project-root proj))
                           (locate-dominating-file default-directory ".claude")
                           (locate-dominating-file default-directory ".git"))))
    (append
     (list (cons (expand-file-name "~/.claude/skills") 'slash))
     (when project-root
       (list (cons (expand-file-name ".claude/skills" project-root) 'slash)
             (cons (expand-file-name ".claude/programmatic-skills"
                                     project-root)
                   'file)))
     (mapcar (lambda (dir) (cons dir 'file))
             agent-claude-programmatic-skill-directories))))

(define-obsolete-function-alias 'agent-claude-run-skill #'agent-run-skill "0.2")
(make-obsolete-variable 'agent-claude-run-skill-model
                        'agent-claude-batch-model "0.2")

;;;;; Project audit

(define-obsolete-function-alias 'agent-claude-audit-project
  #'agent-audit-project "0.2")

;;;;; Theme sync

(defun agent-claude--sync-theme (theme)
  "Update Claude Code persistent theme settings to THEME.
THEME is either \"light\" or \"dark\".  Return the number of files
changed."
  (let ((changed 0))
    (dolist (path (agent-claude--theme-config-files))
      (when (agent-claude--write-claude-json-key path "theme" theme)
        (setq changed (1+ changed))))
    changed))

(defun agent-claude--theme-config-files ()
  "Return Claude Code JSON files that should receive theme sync."
  (agent-claude--dedupe-existing-files
   (append
    (agent-claude--primary-or-existing-files
     (agent-claude--all-claude-settings-paths))
    (agent-claude--primary-or-existing-files
     (agent-claude--all-claude-json-paths)))))

(defun agent-claude--all-claude-settings-paths ()
  "Return paths to canonical and account `settings.json' files."
  (cons (expand-file-name "settings.json" "~/.claude/")
        (mapcar (lambda (entry)
                  (expand-file-name "settings.json"
                                    (expand-file-name (cdr entry))))
                agent-claude-accounts)))

(defun agent-claude--primary-or-existing-files (paths)
  "Return the first file from PATHS, plus any other existing files."
  (let ((primary t)
        result)
    (dolist (path paths (nreverse result))
      (when (or primary (file-exists-p path))
        (push path result))
      (setq primary nil))))

(defun agent-claude--dedupe-existing-files (paths)
  "Return PATHS de-duplicated by true name when possible."
  (let (seen result)
    (dolist (path paths (nreverse result))
      (let ((key (if (file-exists-p path)
                     (file-truename path)
                   (expand-file-name path))))
        (unless (member key seen)
          (push key seen)
          (push path result))))))

(defun agent-claude--write-claude-json-key (path key value)
  "Write KEY to VALUE in Claude JSON file PATH if it changed.
Return non-nil when PATH was written."
  (let ((data (if (file-exists-p path)
                  (or (agent-claude-cli-read-claude-json path)
                      (error "Invalid JSON in %s" path))
                (make-hash-table :test #'equal))))
    (unless (equal (gethash key data) value)
      (puthash key value data)
      (make-directory (file-name-directory path) t)
      (agent-claude-cli-write-claude-json path data)
      t)))

(defun agent-claude--sync-theme-before-start (&rest _)
  "Persist the shared AI theme before starting a Claude Code process."
  (agent-sync-theme-now)
  nil)

;;;;; Setup

;;;###autoload
(defun agent-claude-setup-config ()
  "Ensure Claude Code settings contain agent statusline and hooks."
  (interactive)
  (agent-claude-ensure-statusline-config)
  (agent-claude-ensure-stop-hook-config)
  (agent-claude-ensure-notification-hook-config)
  (message "agent-claude: updated %s" agent-claude-settings-file))

(defun agent-claude-ensure-statusline-config (&optional file)
  "Ensure FILE has a `statusLine' entry.
FILE defaults to `agent-claude-settings-file'."
  (interactive)
  (agent-claude--update-settings
   (or file agent-claude-settings-file)
   #'agent-claude--ensure-statusline))

(defun agent-claude-ensure-stop-hook-config (&optional file)
  "Ensure FILE has a Claude Code `Stop' hook.
FILE defaults to `agent-claude-settings-file'."
  (interactive)
  (agent-claude--update-settings
   (or file agent-claude-settings-file)
   #'agent-claude--ensure-stop-hook))

(defun agent-claude-ensure-notification-hook-config (&optional file)
  "Ensure FILE has a Claude Code `Notification' hook.
FILE defaults to `agent-claude-settings-file'."
  (interactive)
  (agent-claude--update-settings
   (or file agent-claude-settings-file)
   #'agent-claude--ensure-notification-hook))

(defun agent-claude--update-settings (file updater)
  "Read JSON settings FILE, apply UPDATER, and write when changed."
  (let* ((settings (agent-claude--read-json-object file))
         (before (json-serialize settings)))
    (funcall updater settings)
    (unless (equal before (json-serialize settings))
      (make-directory (file-name-directory file) t)
      (agent-claude-cli-write-claude-json file settings)
      t)))

(defun agent-claude--read-json-object (file)
  "Read FILE as a JSON object, or return an empty object if missing."
  (if (not (file-exists-p file))
      (make-hash-table :test #'equal)
    (let ((data (with-temp-buffer
                  (insert-file-contents file)
                  (json-parse-buffer))))
      (unless (hash-table-p data)
        (error "Expected JSON object in %s" file))
      data)))

(defun agent-claude--ensure-statusline (settings)
  "Ensure SETTINGS has an agent statusline command."
  (when (agent-claude--replace-statusline-p settings)
    (puthash "statusLine" (agent-claude--statusline-entry) settings)))

(defun agent-claude--replace-statusline-p (settings)
  "Return non-nil when SETTINGS needs this package's statusline."
  (let ((statusline (gethash "statusLine" settings)))
    (or (not statusline)
        (agent-claude--agent-statusline-p statusline))))

(defun agent-claude--agent-statusline-p (statusline)
  "Return non-nil when STATUSLINE is an agent-owned statusline."
  (and (hash-table-p statusline)
       (let ((command (gethash "command" statusline)))
         (and (stringp command)
              (string-match-p
               "\\(?:^\\|/\\)claude-code-statusline\\.sh\\(?:\\'\\|[[:space:]]\\)"
               command)))))

(defun agent-claude--statusline-entry ()
  "Return the JSON object for the Claude Code statusline command."
  (agent-claude--require-executable agent-claude-statusline-script)
  (let ((entry (make-hash-table :test #'equal)))
    (puthash "type" "command" entry)
    (puthash "command" (agent-claude--statusline-command) entry)
    (puthash "padding" 0 entry)
    entry))

(defun agent-claude--statusline-command ()
  "Return the shell command for the bundled statusline script."
  (format "AGENT_CLAUDE_STATUS_DIR=%s %s"
          (shell-quote-argument
           (directory-file-name
            (expand-file-name agent-claude-status-directory)))
          (shell-quote-argument agent-claude-statusline-script)))

(defun agent-claude--ensure-stop-hook (settings)
  "Ensure SETTINGS has the agent Stop hook."
  (agent-claude--ensure-hook
   settings "Stop" (agent-claude--stop-hook-command) nil))

(defun agent-claude--ensure-notification-hook (settings)
  "Ensure SETTINGS has the agent Notification hook."
  (agent-claude--ensure-hook
   settings "Notification" (agent-claude--notification-hook-command) 5))

(defun agent-claude--ensure-hook (settings name command timeout)
  "Ensure SETTINGS hook NAME includes COMMAND with optional TIMEOUT."
  (let* ((hooks (agent-claude--ensure-hooks settings))
         (entries (agent-claude--json-list (gethash name hooks))))
    (unless (agent-claude--hook-command-present-p entries command)
      (puthash name
               (vconcat entries
                        (vector (agent-claude--hook-entry command timeout)))
               hooks))))

(defun agent-claude--ensure-hooks (settings)
  "Return SETTINGS' `hooks' object, creating it when needed."
  (let ((hooks (gethash "hooks" settings)))
    (unless (hash-table-p hooks)
      (setq hooks (make-hash-table :test #'equal))
      (puthash "hooks" hooks settings))
    hooks))

(defun agent-claude--json-list (value)
  "Return JSON array VALUE as a list."
  (cond
   ((vectorp value) (append value nil))
   ((listp value) value)
   (t nil)))

(defun agent-claude--hook-command-present-p (entries command)
  "Return non-nil if ENTRIES already contain hook COMMAND."
  (cl-some
   (lambda (entry)
     (cl-some
      (lambda (hook)
        (and (hash-table-p hook)
             (equal (gethash "command" hook) command)))
      (agent-claude--json-list (and (hash-table-p entry)
                                       (gethash "hooks" entry)))))
   entries))

(defun agent-claude--hook-entry (command &optional timeout)
  "Return a Claude Code hook entry object for COMMAND.
TIMEOUT, when non-nil, is written as the hook command timeout."
  (let ((entry (make-hash-table :test #'equal)))
    (puthash "matcher" "" entry)
    (puthash "hooks" (vector (agent-claude--hook-command command timeout))
             entry)
    entry))

(defun agent-claude--hook-command (command &optional timeout)
  "Return a Claude Code command hook object for COMMAND.
TIMEOUT, when non-nil, is written as the hook command timeout."
  (let ((hook (make-hash-table :test #'equal)))
    (puthash "type" "command" hook)
    (puthash "command" command hook)
    (when timeout
      (puthash "timeout" timeout hook))
    hook))

(defun agent-claude--stop-hook-command ()
  "Return the command string for the Stop hook."
  (format "%s stop"
          (shell-quote-argument (agent-claude--hook-wrapper))))

(defun agent-claude--hook-wrapper ()
  "Return a verified path to `claude-code-hook-wrapper'."
  (agent-claude--require-executable agent-claude-hook-wrapper))

(defun agent-claude--notification-hook-command ()
  "Return the command string for the Notification hook in settings.json."
  (let ((fire-and-forget
         (expand-file-name "fire-and-forget.sh"
                           agent-claude--hooks-directory))
        (notification
         (expand-file-name "notify-emacs-notification.sh"
                           agent-claude--hooks-directory)))
    (agent-claude--require-executable fire-and-forget)
    (agent-claude--require-executable notification)
    (format "%s %s"
            (shell-quote-argument fire-and-forget)
            (shell-quote-argument notification))))

(defun agent-claude--require-executable (file)
  "Return FILE or signal an error if it is not executable."
  (unless (and file (file-executable-p file))
    (error "Executable not found: %s" file))
  file)

(defun agent-claude--has-statusline-key-p ()
  "Return non-nil if the current buffer has a `statusLine' JSON key."
  (when-let* ((settings (agent-claude--parse-current-json-object)))
    (gethash "statusLine" settings)))

(defun agent-claude--has-stop-hook-p ()
  "Return non-nil if the current buffer has a `Stop' hook."
  (when-let* ((settings (agent-claude--parse-current-json-object))
              (hooks (gethash "hooks" settings)))
    (and (hash-table-p hooks) (gethash "Stop" hooks))))

(defun agent-claude--has-notification-hook-p ()
  "Return non-nil if the current buffer has a configured Notification hook."
  (when-let* ((settings (agent-claude--parse-current-json-object))
              (hooks (gethash "hooks" settings))
              ((hash-table-p hooks))
              (entries (agent-claude--json-list
                        (gethash "Notification" hooks))))
    (cl-some
     (lambda (entry)
       (cl-some
        (lambda (hook)
          (and (hash-table-p hook)
               (string-match-p
                "notify-emacs-notification"
                (or (gethash "command" hook) ""))))
        (agent-claude--json-list (gethash "hooks" entry))))
     entries)))

(defun agent-claude--parse-current-json-object ()
  "Parse the current buffer as a JSON object, returning nil on failure."
  (save-excursion
    (goto-char (point-min))
    (condition-case nil
        (let ((data (json-parse-buffer)))
          (and (hash-table-p data) data))
      (error nil))))

;; Work around upstream bug: `claude-code--adjust-window-size-advice' crashes
;; when `claude-code--window-widths' is nil or void during redisplay.
(defvar claude-code--window-widths nil)
(unless (hash-table-p claude-code--window-widths)
  (setq claude-code--window-widths
        (make-hash-table :test 'eq :weakness 'key)))

;; Fix upstream scroll function.  Two problems:
;;
;; 1. `eat--synchronize-scroll-windows' only includes windows whose
;;    `window-point' equals the terminal cursor.  When eat modifies the
;;    buffer during a terminal redraw, Emacs can reset window-point to 1
;;    for non-selected windows.  Once that happens the equality check
;;    fails and the window is permanently excluded from sync.
;;
;; 2. The upstream conditional recenter (checking `pos-visible-in-window-p')
;;    can miss recenters when display state is stale.
;;
;; We fix both by re-including any desynchronized windows and always
;; recentering with `(recenter -1)'.  The override advice is installed
;; by `agent-claude-mode'.
(defun agent-claude--eat-synchronize-scroll (windows)
  "Keep the terminal cursor at the bottom of WINDOWS.
Re-include any windows showing this buffer that were excluded from
WINDOWS because their point drifted from the cursor, then
unconditionally recenter with `(recenter -1)'."
  (when (not buffer-read-only)
    (let ((cursor-pos (eat-term-display-cursor eat-terminal)))
      ;; Re-include windows that fell out of sync (point != cursor).
      (dolist (w (get-buffer-window-list nil nil t))
        (unless (memq w windows)
          (push w windows)))
      (dolist (window windows)
        (if (eq window 'buffer)
            (goto-char cursor-pos)
          (set-window-point window cursor-pos)
          (with-selected-window window
            (goto-char cursor-pos)
            (recenter -1)))))))

;;;;; Debug backtrace

(define-obsolete-function-alias 'agent-claude-debug-backtrace
  #'agent-debug-backtrace "0.2")

;;;;; Slack message routing

(define-obsolete-function-alias
  'agent-claude-act-on-slack-message #'agent-act-on-slack-message "0.2")
(define-obsolete-function-alias
  'agent-claude-debug-slack-message #'agent-act-on-slack-message "0.2")

;;;;; Handoff

(define-obsolete-function-alias 'agent-claude-handoff #'agent-handoff "0.2")
(define-obsolete-function-alias 'agent-claude-handoff-from-emacsclient
  #'agent-handoff-from-emacsclient "0.2")
(make-obsolete-variable 'agent-claude-handoff-file 'agent-handoff-files "0.2")

;;;;; Restart

(define-obsolete-function-alias 'agent-claude-restart #'agent-restart "0.2")

;;;;; Branch navigation

(defun agent-claude--enrich-sessions (headers member-ids)
  "Enrich session HEADERS with full prompt text for MEMBER-IDS.
HEADERS is a hash table of session ID to header plist.  MEMBER-IDS
is a hash table of session IDs to include.  Return a new hash table
with :first-prompt and :timestamp populated."
  (let ((table (make-hash-table :test 'equal)))
    (maphash (lambda (id header)
               (when (gethash id member-ids)
                 (puthash id (agent-claude-cli-read-session-prompt header)
                          table)))
             headers)
    table))

(defun agent-claude--session-headers (buffer &optional _descendants-of)
  "Return session headers for BUFFER's Claude project directory.
Return nil when the status file is unavailable, since the project
directory is only known from its transcript path.  DESCENDANTS-OF is
accepted for the `session-headers' slot contract and ignored: the scan
is already limited to one project directory and reads only each file's
first line."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when-let* ((status (agent-claude--parse-status-file))
                  (transcript (plist-get status :transcript_path)))
        (agent-claude-cli-scan-session-headers
         (file-name-directory transcript))))))

(defun agent-claude--session-prompt (header)
  "Return HEADER enriched with its first prompt and timestamp."
  (agent-claude-cli-read-session-prompt header))

(defun agent-claude--prepare-fork (session-id from-dir to-dir)
  "Link SESSION-ID, recorded under FROM-DIR, into TO-DIR's Claude project.
Claude Code stores transcripts per project directory, so a fork that
runs in a different directory cannot see its parent session until the
transcript is linked into the new project."
  (agent-claude-cli-link-session-into-project session-id from-dir to-dir))

(define-obsolete-function-alias 'agent-claude-switch-branch
  #'agent-switch-branch "0.3")

(define-obsolete-function-alias 'agent-claude-create-branch
  #'agent-create-branch "0.3")

(defun agent-claude--current-session-id ()
  "Return the session ID of the current Claude buffer.
Signals an error if the status file is missing or incomplete."
  (let ((status (agent-claude--parse-status-file)))
    (unless status
      (user-error "No status file; is status polling enabled?"))
    (or (plist-get status :session_id)
        (user-error "Status file missing session_id"))))

;;;; Extend unified menu

(transient-define-infix agent-claude--infix-warn-kill-with-branches ()
  "Toggle `agent-claude-warn-kill-with-branches'."
  :class 'agent--boolean-variable
  :variable 'agent-claude-warn-kill-with-branches
  :description "warn kill with branches")

(transient-define-infix agent-claude--infix-account ()
  "Select the active Claude account."
  :class 'agent-account-variable
  :backend 'claude-code
  :description "claude account")

(defun agent-claude--menu-suffixes ()
  "Return Claude Code suffix specs for the unified agent menu."
  '(("B" "switch branch" agent-claude-switch-branch)
    ("N" "new branch" agent-claude-create-branch)
    ("b" "batch todos" agent-claude-batch-todos)
    ("t" "send todo at point" agent-claude-send-todo-at-point)
    ("u" "start status polling" agent-claude-start-status-polling)
    ("U" "stop status polling" agent-claude-stop-status-polling)
    ("-c" agent-claude--infix-account)
    ("-w" agent-claude--infix-warn-kill-with-branches)))

;;;; Minor mode

(defvar agent-claude--saved-notification-function nil
  "Value of `claude-code-notification-function' before enabling the mode.")

(defconst agent-claude--start-hook-functions
  '(agent-setup-kill-on-exit
    agent-claude--capture-status-uuid
    agent-claude--capture-monet-key
    agent-claude-start-status-polling
    agent-claude-set-modeline
    agent--refresh-display-names
    agent-disable-scrollback-truncation
    agent-setup-scroll-keys
    agent-setup-snippet-keys
    agent--assign-session-key
    agent-claude--register-session-teardown)
  "Functions `agent-claude-mode' adds to `claude-code-start-hook'.")

;;;###autoload
(define-minor-mode agent-claude-mode
  "Global minor mode wiring `claude-code' sessions into agent.
Owns every hook, advice, and timer the Claude backend installs;
nothing is installed at load time.  Disabling removes them
symmetrically and restores `claude-code-notification-function'."
  :global t
  :group 'agent-claude
  (if agent-claude-mode
      (agent-claude--mode-enable)
    (agent-claude--mode-disable)))

(defun agent-claude--mode-enable ()
  "Install Claude backend hooks, advice, and timers."
  (agent-claude--sweep-stale-status-files)
  (setq agent-claude--saved-notification-function
        claude-code-notification-function)
  (setq claude-code-notification-function #'claude-code-default-notification)
  (add-hook 'claude-code-event-hook #'agent-claude--handle-notification)
  (add-hook 'claude-code-event-hook #'agent-claude--handle-stop)
  (add-hook 'claude-code-event-hook #'agent-claude--handle-session-state)
  (add-hook 'kill-buffer-query-functions #'agent-protect-buffer)
  (dolist (fn agent-claude--start-hook-functions)
    (add-hook 'claude-code-start-hook fn))
  (agent-scroll-keys-global-mode 1)
  (agent-setup-scroll-keys-in-existing-buffers)
  (add-hook 'claude-code-process-environment-functions
            #'agent-claude-account-env)
  (add-hook 'claude-code-process-environment-functions
            #'agent-claude--status-uuid-env)
  (add-hook 'claude-code-process-environment-functions
            #'agent-claude--sync-theme-before-start)
  (advice-add 'claude-code--eat-send-return :before
              #'agent-claude--note-submission)
  (advice-add 'claude-code--vterm-send-return :before
              #'agent-claude--note-submission)
  (advice-add 'claude-code--do-send-command :before
              #'agent-claude--note-submission)
  (advice-add 'claude-code-send-escape :around
              #'agent-claude--send-escape-in-current-buffer)
  (advice-add 'claude-code--eat-synchronize-scroll :override
              #'agent-claude--eat-synchronize-scroll)
  (if (featurep 'monet)
      (agent-claude--monet-install)
    (with-eval-after-load 'monet
      (when agent-claude-mode (agent-claude--monet-install))))
  (agent-claude--register-existing-session-teardowns))

(defun agent-claude--register-existing-session-teardowns ()
  "Register teardown for Claude buffers that predate mode enablement."
  (dolist (buf (claude-code--find-all-claude-buffers))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (agent-claude--register-session-teardown)))))

(defun agent-claude--mode-disable ()
  "Remove Claude backend hooks, advice, and timers."
  (setq claude-code-notification-function
        agent-claude--saved-notification-function)
  (remove-hook 'claude-code-event-hook #'agent-claude--handle-notification)
  (remove-hook 'claude-code-event-hook #'agent-claude--handle-stop)
  (remove-hook 'claude-code-event-hook #'agent-claude--handle-session-state)
  (unless (bound-and-true-p agent-codex-mode)
    (remove-hook 'kill-buffer-query-functions #'agent-protect-buffer)
    (agent-scroll-keys-global-mode -1))
  (dolist (fn agent-claude--start-hook-functions)
    (remove-hook 'claude-code-start-hook fn))
  (remove-hook 'claude-code-process-environment-functions
               #'agent-claude-account-env)
  (remove-hook 'claude-code-process-environment-functions
               #'agent-claude--status-uuid-env)
  (remove-hook 'claude-code-process-environment-functions
               #'agent-claude--sync-theme-before-start)
  (advice-remove 'claude-code--eat-send-return #'agent-claude--note-submission)
  (advice-remove 'claude-code--vterm-send-return #'agent-claude--note-submission)
  (advice-remove 'claude-code--do-send-command #'agent-claude--note-submission)
  (advice-remove 'claude-code-send-escape
                 #'agent-claude--send-escape-in-current-buffer)
  (advice-remove 'claude-code--eat-synchronize-scroll
                 #'agent-claude--eat-synchronize-scroll)
  (agent-claude--monet-remove)
  (agent-claude-stop-usage-polling))

(provide 'agent-claude)
;;; agent-claude.el ends here
