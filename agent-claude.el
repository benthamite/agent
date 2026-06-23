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

(defcustom agent-claude-warn-kill-with-branches t
  "When non-nil, warn before killing a session that has branches.
If the session being killed is the root of a branch tree with
more than one member, a second confirmation prompt is shown after
the standard kill-protection prompt."
  :type 'boolean
  :group 'agent-claude)

(defcustom agent-claude-fork-worktree-directory
  (expand-file-name "claude-worktrees"
                    (or (getenv "XDG_CACHE_HOME")
                        (expand-file-name ".cache" "~")))
  "Base directory for git worktrees created by `agent-claude-create-branch'.
Each forked session gets a sibling worktree under this directory,
isolating its filesystem and git state from the parent session.
Defaults to a cache location to avoid cloud sync
interference with concurrent git operations."
  :type 'directory
  :group 'agent-claude)

(defcustom agent-claude-log-directory
  (expand-file-name "agent/claude-logs/" user-emacs-directory)
  "Directory where Claude conversation logs are saved."
  :type 'directory
  :group 'agent-claude)

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
(declare-function claude-code--get-or-prompt-for-buffer "claude-code" ())
(declare-function claude-code--term-send-string "claude-code" (backend string))
(declare-function claude-code--directory "claude-code" ())
(declare-function claude-code--prompt-for-instance-name
                  "claude-code" (dir existing-instance-names &optional force-prompt))
(declare-function org-back-to-heading "org" (&optional invisible-ok))
(declare-function org-map-entries "org" (func &optional match scope &rest skip))
(declare-function org-get-todo-state "org" ())
(declare-function org-get-heading "org" (&optional no-tags no-todo no-priority no-comment))
(declare-function org-end-of-meta-data "org" (&optional full))
(declare-function org-entry-is-done-p "org" ())
(declare-function org-todo "org" (&optional arg))
(declare-function outline-next-heading "outline" ())
(declare-function agent-log-menu "agent-log" ())
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
  :notify #'agent-claude-notify
  :skill-roots #'agent-claude-skill-roots
  :skill-command-prefix "/"
  :before-kill-check (lambda (_buffer) (agent-claude--confirm-kill-branches))
  :start-session #'agent-claude--start-session
  :session-identity #'agent-claude--session-identity
  :sync-theme #'agent-claude--sync-theme
  :menu-suffixes #'agent-claude--menu-suffixes)

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

(defun agent-claude--confirm-kill-branches ()
  "Return t unless the current session has branches and user declines.
Reads the status file to find the session ID and project
directory, then does a fast header-only scan to check for
branches.  Returns t (allow kill) if the session has no branches,
if the status file is unavailable, or if the user confirms."
  (condition-case nil
      (let ((status (agent-claude--parse-status-file)))
        (if (not status)
            t
          (let ((sid (plist-get status :session_id))
                (transcript (plist-get status :transcript_path)))
            (if (not (and sid transcript))
                t
              (let* ((project-dir (file-name-directory transcript))
                     (headers (agent-claude-cli-scan-session-headers project-dir))
                     (children-map (agent-claude--build-children-map headers))
                     (members (agent-claude--collect-tree-members sid children-map))
                     (branch-count (1- (hash-table-count members))))
                (if (<= branch-count 0)
                    t
                  (yes-or-no-p
                   (format "Session has %d %s — kill anyway? "
                           branch-count
                           (if (= branch-count 1) "branch" "branches")))))))))
    (error t)))

(define-obsolete-function-alias 'agent-claude-setup-kill-on-exit
  #'agent-setup-kill-on-exit "0.2")

;;;;; Smart start

(defconst agent-claude--account-auth-shadow-env
  '("ANTHROPIC_API_KEY=" "ANTHROPIC_AUTH_TOKEN=" "CLAUDE_CODE=")
  "Environment entries that keep account sessions from inheriting auth.")

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

(defvar-local agent-claude--monet-key nil
  "Monet session key owned by this Claude buffer.")

(defun agent-claude--monet-stop-session (key)
  "Fully stop the monet session for KEY.
Closes the websocket server, removes the lockfile, and removes
the session from `monet--sessions'."
  (when-let* ((session (gethash key monet--sessions))
              (server (monet--session-server session)))
    (ignore-errors
      (monet--remove-lockfile (monet--session-port session)))
    (agent-claude--monet-close-server server)
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
  (when (and (claude-code--buffer-p (current-buffer))
             (boundp 'monet--sessions))
    (agent-claude--monet-stop-session
     (or agent-claude--monet-key (buffer-name)))))

(defun agent-claude--monet-cleanup-before-start (orig-fn key directory)
  "Clean up old monet session for KEY before starting a new one.
ORIG-FN is called with KEY and DIRECTORY after cleanup."
  (when (and (boundp 'monet--sessions)
             (gethash key monet--sessions))
    (agent-claude--monet-stop-session key))
  (let ((result (funcall orig-fn key directory)))
    (when (agent-claude--monet-claude-key-p key)
      (setq agent-claude--pending-monet-key key))
    result))

(defun agent-claude--monet-claude-key-p (key)
  "Return non-nil when KEY names a Claude Code session buffer."
  (and (stringp key)
       (string-prefix-p "*claude:" key)))

(defun agent-claude--capture-monet-key ()
  "Store the pending Monet key buffer-locally at Claude session start."
  (when (claude-code--buffer-p (current-buffer))
    (setq agent-claude--monet-key agent-claude--pending-monet-key)
    (setq agent-claude--pending-monet-key nil)))

(defun agent-claude--monet-gc-orphaned-servers ()
  "Delete websocket server processes not tracked by any monet session.
Runs periodically as a safety net to catch servers leaked through
any code path."
  (when (boundp 'monet--sessions)
    (let ((active-servers nil))
      (maphash (lambda (_k session)
        (when-let* ((server (monet--session-server session)))
          (push server active-servers)))
        monet--sessions)
      (dolist (p (process-list))
        (when (and (string-match-p "\\`websocket server on port [0-9]"
                                   (process-name p))
                   (eq (process-status p) 'listen)
                   (not (memq p active-servers)))
          (agent--report-leak "monet server" "%s escaped session teardown"
                              (process-name p))
          (delete-process p))))))

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
call; it is canceled automatically when BUFFER is no longer live."
  (if (not (buffer-live-p buffer))
      (progn
        (agent--report-leak "status timer" "poll timer outlived %s" buffer)
        (cancel-timer (car timer-cell)))
    (with-current-buffer buffer
      (when-let* ((data (agent-claude--parse-status-file)))
        (agent-claude--detect-branch data)
        (setq agent-claude--status-data data)))))

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
alerts for permission_prompt and elicitation_dialog notifications."
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
           (agent-claude-notify
            (format "%s needs approval" label)
            (format "%s: permission request pending" name)))
          ("elicitation_dialog"
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

(defcustom agent-claude-org-todo-in-progress-keyword nil
  "Org TODO keyword to set when sending a heading to Claude Code.
When non-nil, `agent-claude-send-todo-at-point' changes the
heading's TODO state to this keyword after sending.  The keyword
must be one of the values in `org-todo-keywords' for the current
buffer.  When nil, the TODO state is not changed.

Org's built-in keywords are just TODO and DONE, with no
intermediate state, so this is disabled by default.  Users who
have configured an in-progress keyword (e.g. DOING, IN-PROGRESS,
STARTED) can set this option to that keyword."
  :type '(choice (const :tag "Don't change TODO state" nil)
                 (string :tag "Keyword"))
  :group 'agent-claude)

;; Batch state is passed as a plist through closures to support
;; parallel runs.  Keys: :queue :results :log-dir :working-dir :start-time

(defun agent-claude--batch-collect-todos (scope)
  "Collect TODO entries from the current org buffer according to SCOPE.
SCOPE is one of `buffer', `subtree', or `region'.
Returns a list of plists with :title and :body keys."
  (let ((entries '()))
    (org-map-entries
     (lambda ()
       (when (and (org-get-todo-state)
                  (not (org-entry-is-done-p)))
         (let* ((title (org-get-heading t t t t))
                (body-start (save-excursion
                              (org-end-of-meta-data t)
                              (point)))
                (body-end (save-excursion
                            (outline-next-heading)
                            (or (point) (point-max))))
                (body (string-trim
                       (buffer-substring-no-properties body-start body-end))))
           (push (list :title title :body body) entries))))
     nil
     (pcase scope
       ('buffer nil)
       ('subtree 'tree)
       ('region 'region)))
    (nreverse entries)))

(defun agent-claude--batch-format-prompt (entry)
  "Format ENTRY plist as a prompt string for `claude -p'.
Combines :title and :body, using title alone when body is empty."
  (let ((title (plist-get entry :title))
        (body (plist-get entry :body)))
    (if (or (null body) (string-empty-p body))
        title
      (concat title "\n\n" body))))

(defun agent-claude-batch-todos ()
  "Process org TODO entries sequentially via `claude -p'.
Infers scope automatically: region if active, subtree if the
buffer is narrowed, buffer otherwise.  Prompts for a working
directory, then runs each TODO as a non-interactive Claude
session.  Results are logged to timestamped files and displayed
in a summary buffer when all entries have been processed."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Must be called from an org-mode buffer"))
  (let* ((scope (cond
                 ((use-region-p) 'region)
                 ((buffer-narrowed-p) 'subtree)
                 (t 'buffer)))
         (entries (agent-claude--batch-collect-todos scope)))
    (when (null entries)
      (user-error "No TODO entries found in %s" scope))
    (let ((dir (project-prompt-project-dir)))
      (when (or (eq scope 'region)
                (yes-or-no-p
                 (format "Process %d TODO(s) in %s?" (length entries) dir)))
        (agent-claude--batch-start entries dir)))))

(defun agent-claude-send-todo-at-point ()
  "Send the org TODO at point to a running Claude Code session.
Extracts the heading and body of the TODO entry at point,
formats them as a prompt, and sends it to the Claude Code
session associated with the current file's project.  When no
unique session can be inferred, prompts for selection.

When `agent-claude-org-todo-in-progress-keyword' is
non-nil, the heading's TODO state is changed to that keyword
after sending."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Must be called from an org-mode buffer"))
  (unless (org-get-todo-state)
    (user-error "Point is not on a TODO heading"))
  (let* ((entry (agent-claude--collect-todo-at-point))
         (prompt (agent-claude--batch-format-prompt entry))
         (buf (agent-claude--resolve-session-for-file)))
    (agent-submit prompt buf)
    (when agent-claude-org-todo-in-progress-keyword
      (org-todo agent-claude-org-todo-in-progress-keyword))
    (display-buffer buf)))

(defun agent-claude--org-to-markdown (text)
  "Convert org inline markup in TEXT to Markdown equivalents.
Handles verbatim (=…=) and code (~…~) to backticks."
  (replace-regexp-in-string "[=~]\\([^=~\n]+\\)[=~]" "`\\1`" text))

(defun agent-claude--collect-todo-at-point ()
  "Return a plist with :title and :body for the TODO at point."
  (save-excursion
    (org-back-to-heading t)
    (let* ((title (agent-claude--org-to-markdown
                   (org-get-heading t t t t)))
           (body-start (progn (org-end-of-meta-data t) (point)))
           (body-end (progn (outline-next-heading)
                            (or (point) (point-max))))
           (body (string-trim
                  (buffer-substring-no-properties body-start body-end))))
      (list :title title :body body))))

(defun agent-claude--resolve-session-for-file ()
  "Find the Claude Code session for the current file's project.
Returns a buffer.  Uses the project root to find matching
sessions.  Falls back to `claude-code--get-or-prompt-for-buffer'
when no project is detected or no session matches."
  (let* ((project (project-current))
         (dir (and project (project-root project)))
         (buffers (and dir
                       (claude-code--find-claude-buffers-for-directory dir))))
    (cond
     ((= (length buffers) 1)
      (car buffers))
     ((> (length buffers) 1)
      (claude-code--select-buffer-from-choices
       (format "Multiple sessions for %s: "
               (abbreviate-file-name dir))
       buffers t))
     (t
      (or (claude-code--get-or-prompt-for-buffer)
          (user-error "No running Claude Code session found"))))))

(defun agent-claude--batch-start (entries dir &optional commit-after-each)
  "Start batch processing of ENTRIES in working directory DIR.
When COMMIT-AFTER-EACH is non-nil, automatically commit any uncommitted
changes in DIR after each entry completes successfully."
  (when commit-after-each
    (agent-claude--ensure-clean-worktree dir))
  (let* ((log-dir (expand-file-name
                   (format-time-string "batch_%Y-%m-%d_%H-%M-%S")
                   agent-claude-log-directory))
         (state (list :queue entries
                      :results nil
                      :log-dir log-dir
                      :working-dir dir
                      :start-time (current-time)
                      :commit-after-each commit-after-each)))
    (make-directory log-dir t)
    (message "Batch processing %d TODO(s)..." (length entries))
    (agent-claude--batch-run-next state)))

(defun agent-claude--ensure-clean-worktree (dir)
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

(defun agent-claude--batch-run-next (state)
  "Process the next entry in the batch queue in STATE.
STATE is a plist with keys :queue :results :log-dir :working-dir
:start-time.  When the queue is empty, display the summary buffer."
  (if (null (plist-get state :queue))
      (agent-claude--batch-finish state)
    (let* ((queue (plist-get state :queue))
           (entry (car queue))
           (index (1+ (length (plist-get state :results))))
           (title (plist-get entry :title))
           (prompt (agent-claude--batch-format-prompt entry))
           (log-file (expand-file-name
                      (format "%02d_%s.json"
                              index
                              (replace-regexp-in-string
                               "[^a-zA-Z0-9_-]" "-"
                               (truncate-string-to-width title 50)))
                      (plist-get state :log-dir))))
      (plist-put state :queue (cdr queue))
      (message "Batch [%d/%d]: %s"
               index
               (+ index (length (plist-get state :queue)))
               title)
      (agent-claude--run-prompt
       prompt
       :dir (plist-get state :working-dir)
       :callback
       (lambda (result)
         (when-let* ((raw (plist-get result :raw)))
           (with-temp-file log-file
             (insert raw)))
         (plist-put state :results
                    (cons (list :title title
                                :index index
                                :exit-code (plist-get result :exit-code)
                                :duration (plist-get result :duration)
                                :cost (plist-get result :cost)
                                :result-text (or (plist-get result :text)
                                                 "(failed to parse output)")
                                :log-file log-file)
                          (plist-get state :results)))
         (when (and (zerop (plist-get result :exit-code))
                    (plist-get state :commit-after-each))
           (ignore-errors
             (agent-claude--batch-commit-changes state title)))
         (agent-claude--batch-run-next state))))))

(defun agent-claude--batch-commit-changes (state title)
  "Commit uncommitted work in the working directory of STATE.
TITLE is the entry title, used to derive the commit message scope."
  (let ((default-directory (plist-get state :working-dir)))
    (with-temp-buffer
      (call-process "git" nil t nil "status" "--porcelain")
      (when (> (buffer-size) 0)
        (call-process "git" nil nil nil "add" "-A")
        (let ((scope (replace-regexp-in-string
                      "^/" ""
                      (car (split-string title " ")))))
          (call-process "git" nil nil nil "commit" "-m"
                        (format "%s: apply audit recommendations" scope)))))))

(defun agent-claude--batch-parse-stream-json (raw)
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
         (env (agent-claude--batch-process-environment))
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
                        (parsed (agent-claude--batch-parse-stream-json raw)))
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

(defun agent-claude--batch-process-environment ()
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

;;;;; Batch TODO processing

(defun agent-claude--batch-finish (state)
  "Display the batch processing summary buffer for STATE."
  (let* ((results (sort (plist-get state :results)
                        (lambda (a b)
                          (< (plist-get a :index) (plist-get b :index)))))
         (total (length results))
         (successes (cl-count 0 results :key (lambda (r) (plist-get r :exit-code))))
         (failures (- total successes))
         (total-cost (cl-reduce #'+ results :key (lambda (r) (plist-get r :cost))))
         (start-time (plist-get state :start-time))
         (total-time (float-time
                      (time-subtract (current-time) start-time)))
         (buf (get-buffer-create "*Claude Batch Results*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "#+title: Batch results — %s\n\n"
                        (format-time-string "%Y-%m-%d %H:%M:%S" start-time)))
        (insert (format "- Total: %d | Success: %d | Failed: %d\n" total successes failures))
        (insert (format "- Cost: $%.4f\n" total-cost))
        (insert (format "- Time: %.1f seconds\n" total-time))
        (insert (format "- Logs: [[file:%s]]\n\n" (plist-get state :log-dir)))
        (dolist (result results)
          (let ((status (if (= 0 (plist-get result :exit-code)) "DONE" "FAIL")))
            (insert (format "* %s %s\n" status (plist-get result :title)))
            (insert (format ":PROPERTIES:\n:COST: $%.4f\n:DURATION: %.1fs\n:END:\n\n"
                            (plist-get result :cost)
                            (plist-get result :duration)))
            (insert (format "Log: [[file:%s]]\n\n" (plist-get result :log-file)))
            (insert "#+begin_example\n")
            (insert (or (plist-get result :result-text) "(no output)"))
            (unless (string-suffix-p "\n" (or (plist-get result :result-text) ""))
              (insert "\n"))
            (insert "#+end_example\n\n"))))
      (org-mode)
      (goto-char (point-min)))
    (pop-to-buffer buf)
    (message "Batch complete: %d/%d succeeded (%.1fs, $%.4f)"
             successes total total-time total-cost)))

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

(require 'iso8601)

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

(defun agent-claude--find-branch-root (session-id sessions)
  "Follow forkedFrom chain from SESSION-ID upward in SESSIONS hash table.
Returns the root session ID."
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

(defun agent-claude--build-children-map (sessions)
  "Build hash table mapping parent session ID to sorted list of child IDs.
SESSIONS is a hash table of session ID to metadata.  Children are
sorted by timestamp."
  (let ((map (make-hash-table :test 'equal)))
    (maphash (lambda (_id meta)
               (let ((parent (plist-get meta :forked-from)))
                 (when (and parent (gethash parent sessions))
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

(defun agent-claude--collect-tree-members (root-id children-map)
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

(defun agent-claude--format-branch-timestamp (iso-ts)
  "Format ISO-TS as \"Mon DD HH:MM\" for branch display."
  (when iso-ts
    (condition-case nil
        (format-time-string "%b %d %H:%M"
                            (encode-time (iso8601-parse iso-ts)))
      (error (substring iso-ts 0 (min 16 (length iso-ts)))))))

(defun agent-claude--format-branch-tree (root-id sessions children-map current-id)
  "Format the branch tree rooted at ROOT-ID as an alist.
SESSIONS maps IDs to metadata, CHILDREN-MAP maps parent to child
IDs, CURRENT-ID is the active session.  Returns an alist of
\(display-string . session-id)."
  (agent-claude--format-branch-subtree
   root-id sessions children-map current-id "" ""))

(defun agent-claude--format-branch-subtree
    (id sessions children-map current-id prefix child-prefix)
  "Format branch node ID and its children recursively.
SESSIONS maps IDs to metadata, CHILDREN-MAP maps parent to child
IDs, CURRENT-ID is the active session.  PREFIX is the tree connector
for this node, CHILD-PREFIX is the continuation for children.
Return a list of (display . session-id)."
  (let* ((meta (gethash id sessions))
         (prompt (or (plist-get meta :first-prompt) "(no prompt)"))
         (ts (agent-claude--format-branch-timestamp
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
                             (agent-claude--format-branch-subtree
                              child sessions children-map current-id
                              (concat child-prefix (if last-p "└─ " "├─ "))
                              (concat child-prefix (if last-p "   " "│  "))))))
    result))

(defun agent-claude--find-buffer-for-session (session-id)
  "Return a live Claude buffer whose session matches SESSION-ID, or nil."
  (cl-find-if
   (lambda (buf)
     (when (buffer-live-p buf)
       (with-current-buffer buf
         (let ((status (agent-claude--parse-status-file)))
           (and status
                (string= (plist-get status :session_id) session-id))))))
   (claude-code--find-all-claude-buffers)))

;;;###autoload
(defun agent-claude-switch-branch ()
  "Navigate between branches of the current Claude session.
Shows a tree of all sessions related by branching and lets you
select one to switch to or resume."
  (interactive)
  (unless (claude-code--buffer-p (current-buffer))
    (user-error "Not in a Claude buffer"))
  (let ((status (agent-claude--parse-status-file)))
    (unless status
      (user-error "No status file; is status polling enabled?"))
    (let ((session-id (plist-get status :session_id))
          (transcript (plist-get status :transcript_path)))
      (unless (and session-id transcript)
        (user-error "Status file missing session_id or transcript_path"))
      (let* ((project-dir (file-name-directory transcript))
             (headers (agent-claude-cli-scan-session-headers project-dir))
             (children-map (agent-claude--build-children-map headers))
             (root-id (agent-claude--find-branch-root session-id headers))
             (members (agent-claude--collect-tree-members root-id children-map)))
        (when (<= (hash-table-count members) 1)
          (user-error "No branches for this session"))
        (let* ((sessions (agent-claude--enrich-sessions headers members))
               (tree-children (agent-claude--build-children-map sessions))
               (tree (agent-claude--format-branch-tree
                      root-id sessions tree-children session-id))
               (selection (consult--read
                           (mapcar #'car tree)
                           :prompt "Branch: "
                           :require-match t
                           :sort nil))
               (selected-id (cdr (assoc selection tree))))
          (cond
           ((string= selected-id session-id)
            (message "Already on this session"))
           ((agent-claude--find-buffer-for-session selected-id)
            (switch-to-buffer
             (agent-claude--find-buffer-for-session selected-id)))
           (t
            (agent-claude--resume-session selected-id))))))))

(defun agent-claude--resume-session (session-id)
  "Resume SESSION-ID in a new Claude buffer.
Auto-generates an instance name from the session ID to avoid the
interactive instance-name prompt."
  (agent-start-session
   (agent-session-create
    :backend 'claude-code
    :directory default-directory
    :instance (format "branch-%s" (substring session-id 0 8)))
   :resume-id session-id))

;;;###autoload
(defun agent-claude-create-branch (&optional isolated)
  "Create a branch of the current Claude session and switch to it.
Forks the current session via `--resume --fork-session' and opens
the new branch in a separate buffer.  By default the fork shares
the parent's working tree, matching the behavior of launching a
second Claude instance in the same project.

With prefix arg ISOLATED, also create a git worktree on a fresh
branch under `agent-claude-fork-worktree-directory' and run
the fork inside it.  The worktree starts at the parent's HEAD,
so uncommitted parent changes are NOT carried over.  Use this
when concurrent destructive git operations across forks are a
concern; otherwise the default is what you want."
  (interactive "P")
  (unless (claude-code--buffer-p (current-buffer))
    (user-error "Not in a Claude buffer"))
  (let* ((session-id (agent-claude--current-session-id))
         (parent-cwd default-directory)
         (fork-id (format-time-string "%H%M%S"))
         (worktree (and isolated
                        (agent-claude--make-fork-worktree
                         (or (agent-claude--git-toplevel)
                             (user-error "Not in a git repo; cannot isolate"))
                         fork-id))))
    (when worktree
      (agent-claude-cli-link-session-into-project
       session-id parent-cwd (car worktree)))
    (agent-start-session
     (agent-session-create
      :backend 'claude-code
      :directory (or (car worktree) default-directory)
      :instance (format "fork-%s" fork-id))
     :resume-id session-id
     :fork t)
    (when worktree
      (message "Forked in worktree %s on branch %s"
               (car worktree) (cdr worktree)))))

(defun agent-claude--git-toplevel (&optional dir)
  "Return git toplevel for DIR (or `default-directory'), or nil if none."
  (let ((default-directory (or dir default-directory)))
    (with-temp-buffer
      (when (zerop (call-process "git" nil t nil
                                 "rev-parse" "--show-toplevel"))
        (file-name-as-directory (string-trim (buffer-string)))))))

(defun agent-claude--make-fork-worktree (toplevel fork-id)
  "Create a git worktree of TOPLEVEL identified by FORK-ID.
Returns a cons (PATH . BRANCH-NAME).  Signals an error on failure."
  (let* ((repo-name (file-name-nondirectory (directory-file-name toplevel)))
         (branch-name (format "claude-fork-%s" fork-id))
         (worktree-path (file-name-as-directory
                         (expand-file-name
                          (format "%s-fork-%s" repo-name fork-id)
                          agent-claude-fork-worktree-directory))))
    (make-directory agent-claude-fork-worktree-directory t)
    (agent-claude--git-worktree-add toplevel branch-name worktree-path)
    (cons worktree-path branch-name)))

(defun agent-claude--git-worktree-add (toplevel branch-name worktree-path)
  "Run `git worktree add' in TOPLEVEL for BRANCH-NAME at WORKTREE-PATH."
  (let ((default-directory toplevel))
    (with-temp-buffer
      (let ((exit (call-process "git" nil t nil
                                "worktree" "add" "-b" branch-name
                                (directory-file-name worktree-path))))
        (unless (zerop exit)
          (error "Git worktree add failed: %s"
                 (string-trim (buffer-string))))))))

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

(defun agent-claude-agent-log-menu ()
  "Open the optional `agent-log' menu."
  (interactive)
  (unless (require 'agent-log nil t)
    (user-error "Package `agent-log' is required for log browsing"))
  (call-interactively #'agent-log-menu))

(defun agent-claude--menu-suffixes ()
  "Return Claude Code suffix specs for the unified agent menu."
  '(("B" "switch branch" agent-claude-switch-branch)
    ("N" "new branch" agent-claude-create-branch)
    ("b" "batch todos" agent-claude-batch-todos)
    ("t" "send todo at point" agent-claude-send-todo-at-point)
    ("l" "logs" agent-claude-agent-log-menu)
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
  (add-hook 'kill-buffer-query-functions #'agent-protect-buffer)
  (dolist (fn agent-claude--start-hook-functions)
    (add-hook 'claude-code-start-hook fn))
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
  (unless (bound-and-true-p agent-codex-mode)
    (remove-hook 'kill-buffer-query-functions #'agent-protect-buffer))
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
