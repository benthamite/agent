;;; agent-codex.el --- Extensions for codex -*- lexical-binding: t -*-

;; Copyright (C) 2026

;; Author: Pablo Stafforini
;; URL: https://github.com/benthamite/agent
;; Version: 0.1
;; Package-Requires: ((codex "0.1") (agent "0.1"))

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

;; Extensions for `codex'.

;;; Code:

(require 'codex)
(eval-and-compile (require 'agent))
(require 'agent-account)
(require 'cl-lib)
(require 'json)
(require 'subr-x)
(require 'transient)

;;;; Variables

(defgroup agent-codex ()
  "Extensions for `codex'."
  :group 'codex)

(defcustom agent-codex-accounts nil
  "Alist of account names to Codex home directories.
Each entry is (NAME . CODEX-HOME).  When non-nil,
`agent-codex-start-or-switch' uses the persisted account
selection and sets `CODEX_HOME' accordingly so each account
maintains its own credentials while sharing the standard Codex
configuration, hooks, skills, sessions, and history from
`~/.codex/'.

Use `agent-codex-select-account' to change the active account.
The selection persists in `agent-codex-account-file'.

Example:
  \\='((\"personal\" . \"~/.codex-personal\")
    (\"work\"     . \"~/.codex-work\"))"
  :type '(alist :key-type string :value-type directory)
  :group 'agent-codex)

(defcustom agent-codex-account-file
  (expand-file-name ".codex-current-account" "~")
  "File storing the name of the currently active Codex account.
The file contains a single account name from `agent-codex-accounts'.
Written by `agent-codex-select-account', read at session start."
  :type 'file
  :group 'agent-codex)

(defcustom agent-codex-skill-directories nil
  "Additional directories to scan for Codex skills.
Searched in addition to the standard locations."
  :type '(repeat directory)
  :group 'agent-codex)

(defcustom agent-codex-programmatic-skill-directories
  (list (expand-file-name "~/.codex/programmatic-skills"))
  "Directories to scan for skills run only by `agent-run-skill'.
These directories are not loaded by ordinary Codex sessions."
  :type '(repeat directory)
  :group 'agent-codex)

(defcustom agent-codex-exec-approval-policy 'never
  "Approval policy used for non-interactive `codex exec' runs.
When nil, use `codex-approval-policy' or the CLI default."
  :type '(choice (const :tag "Codex default" nil)
                 (const :tag "Untrusted" untrusted)
                 (const :tag "On request" on-request)
                 (const :tag "Never" never))
  :group 'agent-codex)

(defcustom agent-codex-exec-sandbox-mode nil
  "Sandbox mode used for non-interactive `codex exec' runs.
When nil, use `codex-sandbox-mode' or the CLI default."
  :type '(choice (const :tag "Codex default" nil)
                 (const :tag "Read-only" read-only)
                 (const :tag "Workspace write" workspace-write)
                 (const :tag "Full access" danger-full-access))
  :group 'agent-codex)

(defcustom agent-codex-exec-skip-git-repo-check t
  "When non-nil, pass `--skip-git-repo-check' to `codex exec'."
  :type 'boolean
  :group 'agent-codex)

(defvar agent-claude-mode)
(defvar codex-reasoning-effort)
(defvar codex--session-id)
(defvar codex--app-server-input-marker)
(defvar codex--app-server-thread-id)
(defvar codex--app-server-turn-active-p)
(declare-function agent-svg-icon "agent" (svg-data &optional face))
(declare-function codex-start-session "codex")
(declare-function codex-session-identity "codex" (&optional buffer))
(declare-function codex-prompt-input "codex" (&optional buffer))

(defconst agent-codex--shared-config-items
  '("config.toml" "hooks.json" "AGENTS.md" "rules"
    "skills" "programmatic-skills" "plugins" "vendor_imports"
    "history.jsonl" "sessions" "session_index.jsonl"
    "archived_sessions" "memories" "shell_snapshots"
    ".codex-global-state.json")
  "Files and directories symlinked from `~/.codex/' into each account home.
These items are shared across accounts so hooks, skills, project
trust, memories, session history, and other user-facing Codex
state remain available regardless of which account is active.
Only account credentials such as `auth.json' remain account-local.")

;;;; Backend registration

(defconst agent-codex-icon-svg
  "<svg fill=\"currentColor\" viewBox=\"0 0 24 24\" xmlns=\"http://www.w3.org/2000/svg\"><path d=\"M22.2819 9.8211a5.9847 5.9847 0 0 0-.5157-4.9108 6.0462 6.0462 0 0 0-6.5098-2.9A6.0651 6.0651 0 0 0 4.9807 4.1818a5.9847 5.9847 0 0 0-3.9977 2.9 6.0462 6.0462 0 0 0 .7427 7.0966 5.98 5.98 0 0 0 .511 4.9107 6.051 6.051 0 0 0 6.5146 2.9001A5.9847 5.9847 0 0 0 13.2599 24a6.0557 6.0557 0 0 0 5.7718-4.2058 5.9894 5.9894 0 0 0 3.9977-2.9001 6.0557 6.0557 0 0 0-.7475-7.0729zm-9.022 12.6081a4.4755 4.4755 0 0 1-2.8764-1.0408l.1419-.0804 4.7783-2.7582a.7948.7948 0 0 0 .3927-.6813v-6.7369l2.02 1.1686a.071.071 0 0 1 .038.052v5.5826a4.504 4.504 0 0 1-4.4945 4.4944zm-9.6607-4.1254a4.4708 4.4708 0 0 1-.5346-3.0137l.142.0852 4.783 2.7582a.7712.7712 0 0 0 .7806 0l5.8428-3.3685v2.3324a.0804.0804 0 0 1-.0332.0615L9.74 19.9502a4.4992 4.4992 0 0 1-6.1408-1.6464zM2.3408 7.8956a4.485 4.485 0 0 1 2.3655-1.9728V11.6a.7664.7664 0 0 0 .3879.6765l5.8144 3.3543-2.0201 1.1685a.0757.0757 0 0 1-.071 0l-4.8303-2.7865A4.504 4.504 0 0 1 2.3408 7.872zm16.5963 3.8558L13.1038 8.364 15.1192 7.2a.0757.0757 0 0 1 .071 0l4.8303 2.7913a4.4944 4.4944 0 0 1-.6765 8.1042v-5.6772a.79.79 0 0 0-.407-.667zm2.0107-3.0231l-.142-.0852-4.7735-2.7818a.7759.7759 0 0 0-.7854 0L9.409 9.2297V6.8974a.0662.0662 0 0 1 .0284-.0615l4.8303-2.7866a4.4992 4.4992 0 0 1 6.6802 4.66zM8.3065 12.863l-2.02-1.1638a.0804.0804 0 0 1-.038-.0567V6.0742a4.4992 4.4992 0 0 1 7.3757-3.4537l-.142.0805L8.704 5.459a.7948.7948 0 0 0-.3927.6813zm1.0976-2.3654l2.602-1.4998 2.6069 1.4998v2.9994l-2.5974 1.4997-2.6067-1.4997Z\"/></svg>"
  "SVG path data for the OpenAI logo (knot icon).
Source: SVG Repo (CC0).")

(agent-register-backend 'codex
  :buffer-p #'codex--buffer-p
  :find-all-buffers #'codex--find-all-codex-buffers
  :find-buffers-for-dir #'codex--find-codex-buffers-for-directory
  :send-string #'agent-codex-send-command
  :send-return #'agent-codex-send-return
  :submit #'agent-codex-submit-command
  :before-exit-ready-to-close-p #'agent-codex-before-exit-ready-to-close-p
  :duration-ms (lambda (buf)
                 (with-current-buffer buf
                   (agent-codex-status-duration-ms)))
  :program "codex"
  :icon (lambda (&optional face)
          (let ((svg (agent-svg-icon agent-codex-icon-svg face)))
            (if (string-empty-p svg) "CX" svg)))
  :account-env-var "CODEX_HOME"
  :accounts 'agent-codex-accounts
  :account-file 'agent-codex-account-file
  :shared-config-items 'agent-codex--shared-config-items
  :canonical-home "~/.codex/"
  :waiting-p #'agent-codex--waiting-p
  :background-tasks-p #'agent-codex--has-background-tasks-p
  :busy-p #'agent-codex--busy-p
  :label "Codex"
  :run-prompt #'agent-codex-run-prompt
  :skill-roots #'agent-codex-skill-roots
  :skill-command-prefix "$"
  :start-session #'agent-codex--start-session
  :session-identity #'agent-codex--session-identity
  :restart-options #'agent-codex--restart-options
  :sync-theme #'agent-codex--sync-theme
  :menu-suffixes #'agent-codex--menu-suffixes)

;;;; Functions

(defun agent-codex-send-command (cmd &optional buffer)
  "Insert CMD into BUFFER's Codex prompt without submitting it."
  (when-let* ((codex-buffer (agent-codex--target-buffer buffer)))
    (with-current-buffer codex-buffer
      (codex--term-send-string codex-terminal-backend cmd)
      (display-buffer codex-buffer))
    codex-buffer))

(defun agent-codex-send-return (&optional buffer)
  "Submit the active prompt in BUFFER's Codex session."
  (when-let* ((codex-buffer (agent-codex--target-buffer buffer)))
    (with-current-buffer codex-buffer
      (sit-for 0.1)
      (codex--term-send-action codex-terminal-backend :return)
      (display-buffer codex-buffer))
    codex-buffer))

(defun agent-codex-submit-command (cmd &optional buffer)
  "Insert CMD into BUFFER's Codex prompt and submit it atomically."
  (when-let* ((codex-buffer (agent-codex--target-buffer buffer)))
    (codex--send-command-to-buffer cmd codex-buffer)))

(defun agent-codex-before-exit-ready-to-close-p (&optional buffer)
  "Return non-nil when BUFFER has no pending Codex prompt input."
  (when-let* ((codex-buffer (agent-codex--target-buffer buffer)))
    (not (codex-prompt-input codex-buffer))))

(defun agent-codex--target-buffer (buffer)
  "Return BUFFER when live, otherwise prompt for a Codex buffer."
  (if (buffer-live-p buffer)
      buffer
    (codex--get-or-prompt-for-buffer)))

;;;;; Account selection

(defun agent-codex-account-env (_buffer-name _dir)
  "Return `CODEX_HOME' for the Codex session being started.
Resolves the account via `agent-account-resolve' (the in-flight
start binding first, then the persisted selection) and never
prompts or touches the filesystem.  Config-home syncing happens in
`agent-account-sync' from selection, initialization, and
`agent-start-session' -- in particular, `codex exec' batch runs
never trigger filesystem mutation."
  (when-let* ((account (agent-account-resolve 'codex)))
    (agent-account-env 'codex account)))

(defun agent-codex--effective-codex-home ()
  "Return the Codex home for noninteractive helper discovery.
Prefer the resolved account home.  Fall back to `CODEX_HOME' and
then the ordinary `~/.codex' home.  This function never prompts."
  (expand-file-name
   (or (when-let* ((account (agent-account-resolve 'codex)))
         (agent-account-home 'codex account))
       (getenv "CODEX_HOME")
       "~/.codex")))

(defun agent-codex--config-file (&optional account)
  "Return the config.toml path for ACCOUNT or the default Codex config."
  (if-let* ((home (and account (agent-account-home 'codex account))))
      (expand-file-name "config.toml" home)
    (expand-file-name codex-hooks-config-path)))

(defun agent-codex--session-account (&optional buffer)
  "Return the account recorded for BUFFER's Codex session, or nil."
  (when-let* ((session (agent-session buffer)))
    (agent-session-account session)))

;;;###autoload
(defun agent-codex-select-account ()
  "Switch the active Codex account.
Prompts for an account from `agent-codex-accounts', persists the
selection, and syncs the account's home.  New sessions will use
this account."
  (interactive)
  (agent-account-select 'codex))

(defun agent-codex--start-new ()
  "Start a new Codex session using the current account."
  (interactive)
  (agent-start-session
   (agent-session-create :backend 'codex
                         :account (agent-account-resolve 'codex t))))

;;;;; Parameterized session start

(cl-defun agent-codex--start-session (session &key initial-prompt resume-id
                                              terminal-backend)
  "Start the Codex session described by SESSION; return its buffer.
SESSION is an `agent-session'.  INITIAL-PROMPT is submitted as the
first user message.  RESUME-ID resumes that session id.
TERMINAL-BACKEND overrides `codex-terminal-backend' for this session.
The session account is bound as `agent-account--starting' by
`agent-start-session' so environment hooks see it at spawn time."
  (let ((buffer (codex-start-session
                 :directory (agent-session-directory session)
                 :instance-name (agent-session-instance session)
                 :initial-prompt initial-prompt
                 :resume-id resume-id
                 :terminal-backend terminal-backend)))
    (agent--set-session buffer session)
    buffer))

(defun agent-codex--session-identity (buffer)
  "Return the session id of the Codex session in BUFFER, or nil."
  (plist-get (codex-session-identity buffer) :session-id))

(defun agent-codex--restart-options (buffer)
  "Return start options preserving BUFFER's terminal backend on restart."
  (list :terminal-backend
        (plist-get (codex-session-identity buffer) :terminal-backend)))

;;;;; Mode line

(declare-function doom-modeline-set-modeline "doom-modeline-core")

(defvar-local agent-codex--start-time nil
  "Time when this Codex session started.")

(defvar agent-codex--config-model-cache nil
  "Cached model lookup as (CONFIG MTIME MODEL EFFORT) for Codex config.")

(defun agent-codex--parse-config-value (config-file key)
  "Return the string value declared for KEY in CONFIG-FILE, or nil."
  (with-temp-buffer
    (insert-file-contents config-file)
    (goto-char (point-min))
    (when (re-search-forward
           (format "^%s *= *\"\\([^\"]+\\)\"" (regexp-quote key)) nil t)
      (match-string 1))))

(defun agent-codex--parse-config-model (config-file)
  "Return the model string declared in CONFIG-FILE, or nil."
  (agent-codex--parse-config-value config-file "model"))

(defun agent-codex--parse-config-effort (config-file)
  "Return the reasoning effort declared in CONFIG-FILE, or nil."
  (agent-codex--parse-config-value config-file "model_reasoning_effort"))

(defun agent-codex--read-config-field (account index)
  "Read a cached config field for ACCOUNT at INDEX."
  (let* ((config-file (agent-codex--config-file account))
         (mtime (file-attribute-modification-time
                 (file-attributes config-file))))
    (cond
     ((null mtime) nil)
     ((and agent-codex--config-model-cache
           (equal config-file (nth 0 agent-codex--config-model-cache))
           (equal mtime (nth 1 agent-codex--config-model-cache)))
      (nth index agent-codex--config-model-cache))
     (t
      (let ((model (agent-codex--parse-config-model config-file))
            (effort (agent-codex--parse-config-effort config-file)))
        (setq agent-codex--config-model-cache
              (list config-file mtime model effort))
        (nth index agent-codex--config-model-cache))))))

(defun agent-codex--read-config-model (&optional account)
  "Read the model from ACCOUNT's Codex config.
Cached by file modification time so the doom-modeline ai-session
segment does not perform disk I/O on every redisplay."
  (agent-codex--read-config-field account 2))

(defun agent-codex--read-config-effort (&optional account)
  "Read the reasoning effort from ACCOUNT's Codex config.
Cached by file modification time so the doom-modeline ai-session
segment does not perform disk I/O on every redisplay."
  (agent-codex--read-config-field account 3))

(defun agent-codex-set-modeline ()
  "Set the doom-modeline to the `ai-session' modeline for this buffer."
  (when (codex--buffer-p (current-buffer))
    (when (require 'doom-modeline-core nil t)
      (doom-modeline-set-modeline 'ai-session))))

(defun agent-codex--record-start-time ()
  "Record the current Codex session start time."
  (when (codex--buffer-p (current-buffer))
    (setq agent-codex--start-time (current-time))))

(defun agent-codex-status-model ()
  "Return the model name for the current Codex session."
  (agent-codex--read-config-model (agent-codex--session-account)))

(defun agent-codex-status-effort ()
  "Return the reasoning effort for the current Codex session."
  (or codex-reasoning-effort
      (agent-codex--read-config-effort (agent-codex--session-account))
      "medium"))

(defun agent-codex-status-duration-ms ()
  "Return session duration in milliseconds, or nil."
  (when agent-codex--start-time
    (truncate (* 1000 (float-time
                       (time-subtract (current-time)
                                      agent-codex--start-time))))))

;;;;; Theme sync

(defun agent-codex--sync-theme (theme)
  "Update Codex persistent theme configuration to THEME.
THEME is either \"light\" or \"dark\".  Return non-nil when the
config file changed."
  (agent-codex--sync-theme-to-config theme))

(defun agent-codex--sync-theme-to-config (&optional theme)
  "Update `tui.theme' in the active Codex config to THEME.
When THEME is nil, use the current Emacs AI theme.  Only writes
the file when the theme value actually changes."
  (let* ((theme (or theme (agent--theme)))
         (account (or (and (eq (car-safe agent-account--starting) 'codex)
                           (cdr agent-account--starting))
                      (agent-codex--session-account)))
         (config-file (agent-codex--config-file account))
         (new-line (format "theme = \"%s\"" theme)))
    (make-directory (file-name-directory config-file) t)
    (with-temp-buffer
      (when (file-exists-p config-file)
        (insert-file-contents config-file))
      (let ((original (buffer-string))
            (found nil))
        (goto-char (point-min))
        (when (re-search-forward "^\\[tui\\]" nil t)
          (let ((section-end (save-excursion
                               (if (re-search-forward "^\\[" nil t)
                                   (line-beginning-position)
                                 (point-max)))))
            (when (re-search-forward "^theme *= *\"[^\"]*\"" section-end t)
              (replace-match new-line)
              (setq found t))))
        (unless found
          (goto-char (point-min))
          (if (re-search-forward "^\\[tui\\]" nil t)
              (progn
                (end-of-line)
                (insert "\n" new-line))
            (goto-char (point-max))
            (unless (or (bobp) (bolp)) (insert "\n"))
            (unless (bobp) (insert "\n"))
            (insert "[tui]\n" new-line "\n")))
        (unless (equal original (buffer-string))
          (write-region (point-min) (point-max) config-file nil 'silent)
          t)))))

(defun agent-codex--sync-theme-before-start (&rest _)
  "Persist the shared AI theme before starting a Codex process."
  (agent-sync-theme-now)
  nil)

;;;;; Notification handling

(defconst agent-codex--background-tasks-regexp
  "· *[0-9]+ +background +\\(?:[[:word:]-]+ +\\)?\\(?:terminals?\\|agents?\\|tasks?\\) +running"
  "Regexp matching Codex status lines with active background work.")

(defconst agent-codex--working-regexp
  "^• +Working[[:alnum:][:space:][:punct:]]*$"
  "Regexp matching Codex status lines for active response work.")

(defun agent-codex-notify (title message)
  "Notification function combining Codex pulse with optional alert.
TITLE is the notification title.  MESSAGE is the notification body.
When `agent-alert-on-ready' is non-nil, dispatch to the style
configured in `agent-alert-style'."
  (codex-default-notification title message)
  (agent--alert-route title message))

(defun agent-codex--has-background-tasks-p (&optional buffer)
  "Return non-nil when Codex session BUFFER has active background work.
Scans the tail of the terminal buffer for Codex's status-line
indicator, e.g. \"1 background terminal running\"."
  (let ((buf (or buffer (current-buffer))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (or (agent-codex--app-server-accepting-input-p)
            (save-excursion
              (goto-char (point-max))
              (re-search-backward agent-codex--background-tasks-regexp
                                  (max (point-min) (- (point-max) 800))
                                  t)))))))

(defun agent-codex--waiting-p (&optional buffer)
  "Return non-nil when Codex session BUFFER is accepting input."
  (let ((buf (or buffer (current-buffer))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (agent-codex--app-server-accepting-input-p)))))

(defun agent-codex--app-server-accepting-input-p ()
  "Return non-nil when an active app-server turn has an input prompt."
  (and (boundp 'codex--app-server-turn-active-p)
       codex--app-server-turn-active-p
       (boundp 'codex--app-server-input-marker)
       (markerp codex--app-server-input-marker)
       (marker-position codex--app-server-input-marker)
       t))

(defun agent-codex--busy-p (&optional buffer)
  "Return non-nil when Codex session BUFFER is actively responding."
  (let ((buf (or buffer (current-buffer))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (or (and (boundp 'codex--app-server-turn-active-p)
                 codex--app-server-turn-active-p)
            (save-excursion
              (goto-char (point-max))
              (re-search-backward agent-codex--working-regexp
                                  (max (point-min) (- (point-max) 800))
                                  t)))))))

(defun agent-codex--handle-notification (message)
  "Handle a notification event from Codex CLI.
MESSAGE is a plist with :type, :buffer-name, :json-data, and :args.
The :type field is a string from the hook wrapper (e.g. \"Stop\").
Codex's Stop fires when the CLI is back at its prompt, so it is
translated into an `idle-prompt' session event."
  (let ((hook-type (plist-get message :type)))
    (when (member hook-type '("Stop" "Notification" "SessionStart"))
      (when-let* ((buf (get-buffer (plist-get message :buffer-name))))
        (pcase hook-type
          ("Stop"
           (agent-session-event buf 'idle-prompt))
          ("Notification"
           (agent-notify
            (agent--backend-get 'codex :label)
            (format "%s: needs your attention"
                    (agent--session-name (buffer-name buf)))))))))
  nil)

;;;;; Skill runner

(defun agent-codex-skill-roots ()
  "Return Codex skill roots as (DIRECTORY . STYLE) conses.
Codex exec has no slash expansion, so every root is file-style."
  (let* ((codex-home (agent-codex--effective-codex-home))
         (project-root (or (when-let* ((proj (project-current)))
                             (project-root proj))
                           (locate-dominating-file default-directory ".codex")
                           (locate-dominating-file default-directory ".git"))))
    (mapcar (lambda (dir) (cons dir 'file))
            (append
             (list (expand-file-name "skills" codex-home))
             (when project-root
               (list (expand-file-name ".agent/skills" project-root)
                     (expand-file-name ".codex/skills" project-root)
                     (expand-file-name ".codex/programmatic-skills"
                                       project-root)))
             (agent-codex--codex-plugin-skill-roots codex-home)
             agent-codex-skill-directories
             agent-codex-programmatic-skill-directories))))

(defun agent-codex--codex-plugin-list (codex-home)
  "Return enabled-plugin metadata from `codex plugin list --json' for CODEX-HOME."
  (when-let* ((program (or codex-program (executable-find "codex"))))
    (with-temp-buffer
      (let* ((process-environment
              (cons (format "CODEX_HOME=%s" (expand-file-name codex-home))
                    process-environment))
             (exit-code
              (process-file program nil t nil "plugin" "list" "--json"))
             (output (buffer-string)))
        (if (not (equal exit-code 0))
            (progn
              (unless (string-empty-p (string-trim output))
                (message "agent-codex: codex plugin list failed: %s"
                         (string-trim output)))
              nil)
          (condition-case err
              (let* ((json-object-type 'alist)
                     (json-array-type 'list)
                     (json-false :false)
                     (data (json-read-from-string output))
                     (installed (alist-get 'installed data)))
                (and (listp installed) installed))
            (json-error
             (message "agent-codex: cannot parse codex plugin list JSON: %S" err)
             nil)))))))

(defun agent-codex--codex-plugin-entry-skill-root (codex-home entry)
  "Return the skill root for active plugin ENTRY under CODEX-HOME."
  (when (and (eq (alist-get 'installed entry) t)
             (eq (alist-get 'enabled entry) t))
    (let ((name (alist-get 'name entry))
          (marketplace (alist-get 'marketplaceName entry))
          (version (alist-get 'version entry)))
      (when (and (stringp name)
                 (stringp marketplace)
                 version)
        (let ((root (expand-file-name
                     (string-join
                      (list "plugins" "cache" marketplace name
                            (format "%s" version) "skills")
                      "/")
                     codex-home)))
          (when (and (file-directory-p root)
                     (not (agent-codex--codex-plugin-root-orphaned-p root)))
            root))))))

(defun agent-codex--codex-plugin-root-orphaned-p (path)
  "Return non-nil if PATH is inside an orphaned Codex plugin cache."
  (let ((current (file-name-as-directory (expand-file-name path)))
        orphaned)
    (while (and current (not orphaned))
      (when (file-exists-p (expand-file-name ".orphaned_at" current))
        (setq orphaned t))
      (if (string= (file-name-nondirectory (directory-file-name current))
                   "cache")
          (setq current nil)
        (let ((parent (file-name-directory (directory-file-name current))))
          (setq current
                (unless (or (null parent) (equal parent current))
                  parent)))))
    orphaned))

(defun agent-codex--codex-plugin-skill-roots (codex-home)
  "Return current enabled Codex plugin skill roots under CODEX-HOME."
  (let (roots seen)
    (dolist (entry (agent-codex--codex-plugin-list codex-home))
      (when-let* ((root (agent-codex--codex-plugin-entry-skill-root
                         codex-home entry))
                  (real (file-truename root)))
        (unless (member real seen)
          (push real seen)
          (push root roots))))
    (nreverse roots)))

(define-obsolete-function-alias 'agent-codex-run-skill #'agent-run-skill "0.2")

(defun agent-codex--build-exec-command (prompt dir)
  "Return the `codex exec' command for PROMPT in DIR."
  (append (list codex-program)
          codex-program-switches
          (agent-codex--exec-approval-args)
          (list "exec")
          (agent-codex--exec-model-args)
          (agent-codex--exec-profile-args)
          (agent-codex--exec-sandbox-args)
          (agent-codex--exec-image-args)
          (list "--cd" (expand-file-name dir)
                "--color" "never")
          (when agent-codex-exec-skip-git-repo-check
            (list "--skip-git-repo-check"))
          (list prompt)))

(defun agent-codex--exec-model-args ()
  "Return `codex exec' model arguments."
  (when codex-model
    (list "--model" codex-model)))

(defun agent-codex--exec-profile-args ()
  "Return `codex exec' profile arguments."
  (when codex-profile
    (list "--profile" codex-profile)))

(defun agent-codex--exec-sandbox-args ()
  "Return `codex exec' sandbox arguments."
  (when-let* ((mode (or agent-codex-exec-sandbox-mode codex-sandbox-mode)))
    (list "--sandbox" (symbol-name mode))))

(defun agent-codex--exec-approval-args ()
  "Return Codex approval-policy arguments."
  (when-let* ((policy (or agent-codex-exec-approval-policy
                          codex-approval-policy)))
    (list "--ask-for-approval" (symbol-name policy))))

(defun agent-codex--exec-image-args ()
  "Return `codex exec' image arguments."
  (cl-loop for image in codex-default-images
           append (list "--image" image)))

(defun agent-codex--exec-process-environment (dir)
  "Return the process environment for non-interactive Codex runs in DIR."
  (let* ((buffer-name (format "*codex-exec:%s*"
                              (file-name-nondirectory
                               (directory-file-name dir))))
         (extra-env (apply #'append
                           (mapcar (lambda (func)
                                     (funcall func buffer-name dir))
                                   codex-process-environment-functions))))
    (append `(,(format "CODEX_BUFFER_NAME=%s" buffer-name))
            extra-env
            process-environment)))

(defun agent-codex--run-prompt (prompt &rest kwargs)
  "Run PROMPT non-interactively via `codex exec'.
KWARGS accepts :dir and :callback.  The callback receives a plist
with :exit-code, :duration, :text, and :raw."
  (let* ((dir (or (plist-get kwargs :dir) default-directory))
         (callback (or (plist-get kwargs :callback)
                       (error "agent-codex--run-prompt: :callback required")))
         (args (agent-codex--build-exec-command prompt dir))
         (env (agent-codex--exec-process-environment dir))
         (start-time (current-time))
         (output-buf (generate-new-buffer " *codex-exec-output*")))
    (unless (executable-find codex-program)
      (error "Codex program `%s' not found in PATH" codex-program))
    (let ((process-environment env)
          (default-directory dir))
      (make-process
       :name "codex-exec"
       :buffer output-buf
       :command args
       :sentinel
       (lambda (proc _event)
         (when (memq (process-status proc) '(exit signal))
           (let* ((exit-code (process-exit-status proc))
                  (raw (with-current-buffer (process-buffer proc)
                         (buffer-string)))
                  (duration (float-time
                             (time-subtract (current-time) start-time)))
                  (result (list :exit-code exit-code
                                :duration duration
                                :text (string-trim raw)
                                :raw raw)))
             (ignore-errors (kill-buffer (process-buffer proc)))
             (funcall callback result))))))))

(cl-defun agent-codex-run-prompt (prompt &key directory callback)
  "Run PROMPT through `codex exec' with the normalized agent signature.
DIRECTORY is the working directory; it defaults to
`default-directory'.  CALLBACK is called as (TEXT &key ERROR),
where ERROR is nil on success or a short failure description.
This is the `run-prompt' backend slot implementation."
  (agent-codex--run-prompt
   prompt
   :dir (or directory default-directory)
   :callback
   (lambda (result)
     (let ((code (plist-get result :exit-code)))
       (funcall callback (plist-get result :text)
                :error (unless (eq code 0)
                         (format "codex exited with exit code %s" code)))))))

;;;;; Project audit

(define-obsolete-function-alias 'agent-codex-audit-project
  #'agent-audit-project "0.2")

;;;;; Debug backtrace

(define-obsolete-function-alias 'agent-codex-debug-backtrace
  #'agent-debug-backtrace "0.2")

;;;;; Slack message routing

(define-obsolete-function-alias
  'agent-codex-act-on-slack-message #'agent-act-on-slack-message "0.2")
(define-obsolete-function-alias
  'agent-codex-debug-slack-message #'agent-act-on-slack-message "0.2")

;;;;; Handoff

(define-obsolete-function-alias 'agent-codex-handoff #'agent-handoff "0.2")
(define-obsolete-function-alias 'agent-codex-handoff-from-emacsclient
  #'agent-handoff-from-emacsclient "0.2")
(make-obsolete-variable 'agent-codex-handoff-file 'agent-handoff-files "0.2")

;;;;; Restart

(define-obsolete-function-alias 'agent-codex-restart #'agent-restart "0.2")

;;;;; Start or switch (Codex-specific entry point)

;;;###autoload
(defun agent-codex-start-or-switch ()
  "Start a new Codex session or switch to an existing one.
If no Codex sessions exist, start a new one.  Otherwise, show the
unified session switcher."
  (interactive)
  (if (null (codex--find-all-codex-buffers))
      (agent-codex--start-new)
    (agent--ensure-all-session-keys)
    (transient-setup 'agent--session-switcher)))

;;;;; Branch navigation

;;;###autoload
(defun agent-codex-resume (arg)
  "Resume a previous Codex session.
With prefix ARG, use Codex CLI's `--last' flag."
  (interactive "P")
  (codex-resume arg))

;;;###autoload
(defun agent-codex-fork (arg)
  "Fork a previous Codex session.
With prefix ARG, use Codex CLI's `--last' flag."
  (interactive "P")
  (codex-fork arg))

;;;; Hooks

(defun agent-codex--note-submission (buffer)
  "Emit a `submit' session event for Codex session BUFFER.
Runs on `codex-command-submitted-hook' for every submission path."
  (agent-session-event buffer 'submit))

;;;;; Exit and kill on exit

(defun agent-codex--intercept-exit (orig-fn cmd)
  "Intercept `/exit' and kill the session instead of forwarding it.
ORIG-FN is `codex--do-send-command'.  CMD is the command string.
Codex CLI does not recognize `/exit', so we handle it on the
Emacs side to match Claude Code's behavior."
  (if (string= (string-trim cmd) "/exit")
      (when-let* ((buf (codex--get-or-prompt-for-buffer)))
        (with-current-buffer buf
          (agent-kill-session-buffer)))
    (funcall orig-fn cmd)))

(defun agent-codex--intercept-exit-to-buffer (orig-fn cmd buffer)
  "Intercept `/exit' submitted to BUFFER and kill the session instead.
ORIG-FN is `codex--send-command-to-buffer'.  CMD is the command
string.  Codex CLI does not recognize `/exit', so it is handled on
the Emacs side to match Claude Code's behavior."
  (if (string= (string-trim cmd) "/exit")
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (agent-kill-session-buffer)))
    (funcall orig-fn cmd buffer)))

(define-obsolete-function-alias 'agent-codex-exit #'agent-exit "0.2")
(define-obsolete-function-alias 'agent-codex-setup-kill-on-exit
  #'agent-setup-kill-on-exit "0.2")

(defun agent-codex--register-session-teardown ()
  "Register core session teardown for a freshly started Codex session."
  (when (codex--buffer-p (current-buffer))
    (agent--install-session-teardown)))

;;;;; Account menu infix

(transient-define-infix agent-codex--infix-account ()
  "Select the active Codex account."
  :class 'agent-account-variable
  :backend 'codex
  :description "codex account")

;;;;; Extend unified menu

(defun agent-codex--menu-suffixes ()
  "Return Codex suffix specs for the unified agent menu."
  '(("R" "codex resume" agent-codex-resume)
    ("F" "codex fork" agent-codex-fork)
    ("-x" agent-codex--infix-account)))

;;;; Minor mode

(defvar agent-codex--saved-notification-function nil
  "Value of `codex-notification-function' before enabling the mode.")

(defconst agent-codex--start-hook-functions
  '(agent-setup-kill-on-exit
    agent-codex-set-modeline
    agent--refresh-display-names
    agent-disable-scrollback-truncation
    agent-setup-snippet-keys
    agent-fix-rendering
    agent--assign-session-key
    agent-codex--record-start-time
    agent-codex--register-session-teardown)
  "Functions `agent-codex-mode' adds to `codex-start-hook'.")

;;;###autoload
(define-minor-mode agent-codex-mode
  "Global minor mode wiring `codex' sessions into agent.
Owns every hook, advice, and notification handler the Codex
backend installs; nothing is installed at load time.  Disabling
removes them symmetrically and restores
`codex-notification-function'."
  :global t
  :group 'agent-codex
  (if agent-codex-mode
      (agent-codex--mode-enable)
    (agent-codex--mode-disable)))

(defun agent-codex--mode-enable ()
  "Install Codex backend hooks and advice."
  (setq agent-codex--saved-notification-function codex-notification-function)
  (setq codex-notification-function #'agent-codex-notify)
  (add-hook 'codex-event-hook #'agent-codex--handle-notification)
  (add-hook 'kill-buffer-query-functions #'agent-protect-buffer)
  (dolist (fn agent-codex--start-hook-functions)
    (add-hook 'codex-start-hook fn))
  (add-hook 'codex-process-environment-functions
            #'agent-codex-account-env)
  (add-hook 'codex-process-environment-functions
            #'agent-codex--sync-theme-before-start)
  (add-hook 'codex-command-submitted-hook #'agent-codex--note-submission)
  (advice-add 'codex--do-send-command :around #'agent-codex--intercept-exit)
  (advice-add 'codex--send-command-to-buffer :around
              #'agent-codex--intercept-exit-to-buffer))

(defun agent-codex--mode-disable ()
  "Remove Codex backend hooks and advice."
  (setq codex-notification-function agent-codex--saved-notification-function)
  (remove-hook 'codex-event-hook #'agent-codex--handle-notification)
  (unless (bound-and-true-p agent-claude-mode)
    (remove-hook 'kill-buffer-query-functions #'agent-protect-buffer))
  (dolist (fn agent-codex--start-hook-functions)
    (remove-hook 'codex-start-hook fn))
  (remove-hook 'codex-process-environment-functions
               #'agent-codex-account-env)
  (remove-hook 'codex-process-environment-functions
               #'agent-codex--sync-theme-before-start)
  (remove-hook 'codex-command-submitted-hook #'agent-codex--note-submission)
  (advice-remove 'codex--do-send-command #'agent-codex--intercept-exit)
  (advice-remove 'codex--send-command-to-buffer
                 #'agent-codex--intercept-exit-to-buffer))

;;;; Provide

(provide 'agent-codex)
;;; agent-codex.el ends here
