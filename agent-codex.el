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
(defvar codex--app-server-process)
(defvar codex--app-server-thread-id)
(defvar codex--app-server-turn-active-p)
(declare-function agent-svg-icon "agent" (svg-data &optional face))
(declare-function agent-act-on-slack-message "agent-slack" ())
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
  :exec-prompt #'agent-codex--run-prompt
  :notify #'agent-codex-notify
  :skill-roots #'agent-codex-skill-roots
  :skill-command-prefix "$"
  :start-session #'agent-codex--start-session
  :session-identity #'agent-codex--session-identity
  :restart-options #'agent-codex--restart-options
  :sync-theme #'agent-codex--sync-theme
  :session-headers #'agent-codex--session-headers
  :session-prompt #'agent-codex--session-prompt
  :resume #'codex-resume)

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
                                              fork terminal-backend)
  "Start the Codex session described by SESSION; return its buffer.
SESSION is an `agent-session'.  INITIAL-PROMPT is submitted as the
first user message.  RESUME-ID resumes that session id, or forks it
into a new session when FORK is non-nil.  TERMINAL-BACKEND overrides
`codex-terminal-backend' for this session.  The session account is
bound as `agent-account--starting' by `agent-start-session' so
environment hooks see it at spawn time.  Signal a `user-error' when
asked to fork a RESUME-ID that has not produced a transcript yet,
since Codex has nothing on disk to fork from and would otherwise fail
silently, leaving an empty, unrelated session buffer in place of the
requested branch."
  (when (and fork resume-id (not (codex--find-session-transcript resume-id)))
    (user-error
     "Codex session %s can't be branched yet: it hasn't produced any output.
Run at least one turn in it, then branch again"
     resume-id))
  (let ((buffer (codex-start-session
                 :directory (agent-session-directory session)
                 :instance-name (agent-session-instance session)
                 :initial-prompt initial-prompt
                 :resume-id resume-id
                 :fork fork
                 :terminal-backend terminal-backend)))
    (agent--set-session buffer session)
    buffer))

(defun agent-codex--session-identity (buffer)
  "Return the session id of the Codex session in BUFFER, or nil."
  (plist-get (codex-session-identity buffer) :session-id))

(defun agent-codex--restart-options (buffer)
  "Return Codex start options for restart.
BUFFER is accepted for the backend restart-options contract.
Restarts use the current default `codex-terminal-backend' rather
than stale buffer-local launch state from the replaced session."
  (ignore buffer)
  (list :terminal-backend
        (default-value 'codex-terminal-backend)))

;;;;; TOML helpers

(defvar agent-codex--toml-cache (make-hash-table :test #'equal)
  "Map from config file path to (MTIME . VALUES) for TOML reads.
VALUES maps (KEY . SECTION) cons keys to string values, so reads
for different account config files never evict each other.")

(defun agent-codex--toml-get (file key &optional section)
  "Return the string value of KEY in TOML FILE, or nil.
With SECTION, look KEY up inside the [SECTION] table; otherwise
look it up in the top-level table before the first section
header.  Results are cached per FILE keyed by modification time."
  (when-let* ((mtime (file-attribute-modification-time
                      (file-attributes file))))
    (let* ((entry (gethash file agent-codex--toml-cache))
           (values (if (and entry (equal (car entry) mtime))
                       (cdr entry)
                     (cdr (puthash file
                                   (cons mtime (make-hash-table :test #'equal))
                                   agent-codex--toml-cache))))
           (cache-key (cons key section))
           (cached (gethash cache-key values 'agent-codex--toml-miss)))
      (if (eq cached 'agent-codex--toml-miss)
          (puthash cache-key (agent-codex--toml-read-value file key section)
                   values)
        cached))))

(defun agent-codex--toml-read-value (file key section)
  "Read KEY from TOML FILE inside SECTION, without caching."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (pcase-let ((`(,beg . ,end) (agent-codex--toml-region section)))
      (when beg
        (goto-char beg)
        (when (re-search-forward
               (format "^%s *= *\"\\([^\"]*\\)\"" (regexp-quote key)) end t)
          (match-string 1))))))

(defun agent-codex--toml-region (section)
  "Return the (BEG . END) region for SECTION in the current buffer.
A nil SECTION means the top-level table: point-min up to the
first section header.  Returns (nil . nil) when SECTION is absent."
  (goto-char (point-min))
  (if (null section)
      (cons (point-min)
            (if (re-search-forward "^\\[" nil t)
                (line-beginning-position)
              (point-max)))
    (if (re-search-forward (format "^\\[%s\\]" (regexp-quote section)) nil t)
        (cons (point)
              (if (re-search-forward "^\\[" nil t)
                  (line-beginning-position)
                (point-max)))
      (cons nil nil))))

(defun agent-codex--toml-set (file key value &optional section)
  "Set KEY to string VALUE in TOML FILE, inside [SECTION] when given.
Create the file and the section as needed.  Write only when the
content changes; return non-nil in that case.  Invalidates the
read cache for FILE."
  (make-directory (file-name-directory file) t)
  (with-temp-buffer
    (when (file-exists-p file)
      (insert-file-contents file))
    (let ((original (buffer-string))
          (new-line (format "%s = \"%s\"" key value)))
      (pcase-let ((`(,beg . ,end) (agent-codex--toml-region section)))
        (cond
         ((and beg (progn (goto-char beg)
                          (re-search-forward
                           (format "^%s *= *\"[^\"]*\"" (regexp-quote key))
                           end t)))
          (replace-match new-line t t))
         (beg
          (goto-char beg)
          (if section
              (insert "\n" new-line)
            (goto-char end)
            (insert new-line "\n")))
         (t
          (goto-char (point-max))
          (unless (or (bobp) (bolp)) (insert "\n"))
          (unless (bobp) (insert "\n"))
          (insert (format "[%s]\n" section) new-line "\n"))))
      (unless (equal original (buffer-string))
        (write-region (point-min) (point-max) file nil 'silent)
        (remhash file agent-codex--toml-cache)
        t))))

;;;;; Mode line

(declare-function doom-modeline-set-modeline "doom-modeline-core")

(defvar-local agent-codex--start-time nil
  "Time when this Codex session started.")

(defun agent-codex--read-config-model (&optional account)
  "Return the model declared in ACCOUNT's Codex config, or nil."
  (agent-codex--toml-get (agent-codex--config-file account) "model"))

(defun agent-codex--read-config-effort (&optional account)
  "Return the reasoning effort declared in ACCOUNT's Codex config, or nil."
  (agent-codex--toml-get (agent-codex--config-file account)
                         "model_reasoning_effort"))

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
When THEME is nil, use the current Emacs AI theme.  Return
non-nil when the file changed."
  (let* ((theme (or theme (agent--theme)))
         (account (or (and (eq (car-safe agent-account--starting) 'codex)
                           (cdr agent-account--starting))
                      (agent-codex--session-account)))
         (config-file (agent-codex--config-file account)))
    (agent-codex--toml-set config-file "theme" theme "tui")))

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
        (save-excursion
          (goto-char (point-max))
          (re-search-backward agent-codex--background-tasks-regexp
                              (max (point-min) (- (point-max) 800))
                              t))))))

(defun agent-codex--waiting-p (&optional buffer)
  "Return non-nil when Codex session BUFFER is blocked on user input.
App-server sessions learn turn boundaries from the JSON-RPC stream, so
an inactive turn means Codex has finished and will not proceed until
the user submits something.  Being able to queue text mid-turn is not
waiting, and does not count here.

Terminal sessions have no protocol signal and return nil, leaving the
decision to `agent--session-state' and `agent-codex--busy-p'."
  (let ((buf (or buffer (current-buffer))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (and (agent-codex--app-server-live-p)
             (not codex--app-server-turn-active-p))))))

(defun agent-codex--app-server-live-p ()
  "Return non-nil when the current buffer has a live Codex app server."
  (and (boundp 'codex--app-server-process)
       (process-live-p codex--app-server-process)))

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
translated into an `idle-prompt' session event.  PermissionRequest
fires while the CLI waits at an approval prompt mid-turn, so it only
raises an attention alert and leaves the session state untouched.
Every handled event also records the native session id reported by
`codex-session-identity' through `agent--note-session-id'."
  (let ((hook-type (plist-get message :type)))
    (when (member hook-type
                  '("Stop" "Notification" "PermissionRequest" "SessionStart"))
      (when-let* ((buf (get-buffer (plist-get message :buffer-name))))
        (agent-codex--note-session-id buf)
        (pcase hook-type
          ("Stop"
           (agent-session-event buf 'idle-prompt))
          ("PermissionRequest"
           (agent-codex-notify
            (format "%s needs approval"
                    (agent-backend-label (agent-backend 'codex)))
            (format "%s: permission request pending"
                    (agent--buffer-session-name buf))))
          ("Notification"
           (agent-notify
            (agent-backend-label (agent-backend 'codex))
            (format "%s: needs your attention"
                    (agent--buffer-session-name buf))))))))
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
  "Return the process environment for a non-interactive Codex run in DIR."
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
Runs on `codex-command-submitted-hook' for every submission path.
Also records the native session id, because a fresh app-server session
knows its thread id before any CLI hook event fires, and this hook is
the earliest per-buffer signal after that point."
  (agent-codex--note-session-id buffer)
  (agent-session-event buffer 'submit))

(defun agent-codex--note-session-id (buffer)
  "Record BUFFER's native Codex session id on its session struct."
  (agent--note-session-id
   buffer (plist-get (codex-session-identity buffer) :session-id)))

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

;;;;; Session headers

(defconst agent-codex--injected-prompt-prefixes
  '("# AGENTS.md" "<environment_context>" "<user_instructions>")
  "Prefixes of the messages Codex injects before the user's first prompt.
These arrive as user-role messages in the transcript but are not
anything the user typed.")

(defconst agent-codex--uuid-regexp
  "[0-9a-f]\\{8\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{4\\}-\
[0-9a-f]\\{12\\}"
  "Regexp matching the session id ending a rollout file's base name.
A rollout is named `rollout-TIMESTAMP-UUID.jsonl'.")

(defun agent-codex--session-id-from-file (file)
  "Return the session id encoded in rollout FILE's name, or nil.
The id is taken from the file name rather than the payload's
`session_id' because subagent rollouts record the parent's id there."
  (let ((name (file-name-base file)))
    (when (and (> (length name) 36)
               (string-match-p (concat "\\`" agent-codex--uuid-regexp "\\'")
                               (substring name -36)))
      (substring name -36))))

(defun agent-codex--session-start-timestamp (file)
  "Return the start timestamp encoded in rollout FILE's name, or nil.
Rollouts are named `rollout-2026-08-05T08-08-27-UUID.jsonl', and that
timestamp is fixed-width, so the values sort as plain strings.  It
records when the session started, which -- unlike the file's
modification time -- stops changing while the session runs."
  (let ((name (file-name-base file)))
    (when (string-match (concat "\\`rollout-\\(.+\\)-"
                                agent-codex--uuid-regexp "\\'")
                        name)
      (match-string 1 name))))

(defun agent-codex--same-directory-p (a b)
  "Return non-nil when directories A and B name the same place."
  (and (stringp a) (stringp b)
       (equal (file-truename (file-name-as-directory a))
              (file-truename (file-name-as-directory b)))))

(defconst agent-codex--first-line-chunk-size 32768
  "Bytes read at a time when fetching a rollout's first line.
Real `session_meta' records run to a few tens of kilobytes, so one
read usually reaches the newline; a longer record costs another read
rather than being truncated into unparseable JSON.")

(defun agent-codex--read-first-line (file)
  "Return the first line of FILE as a string, or nil when it is empty.
The file is read a chunk at a time and stops at the first newline,
because rollout transcripts run to megabytes but only their opening
`session_meta' record matters here.  Chunks are read as bytes and
decoded once, so a chunk boundary cannot split a character."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (let ((start 0)
          (line nil)
          (exhausted nil))
      (while (and (null line) (not exhausted))
        (goto-char (point-max))
        (let* ((end (+ start agent-codex--first-line-chunk-size))
               (bytes (cadr (insert-file-contents-literally
                             file nil start end))))
          (setq start end
                exhausted (< bytes agent-codex--first-line-chunk-size))
          (goto-char (point-min))
          (cond ((search-forward "\n" nil t)
                 (setq line (buffer-substring-no-properties
                             (point-min) (1- (point)))))
                (exhausted
                 (setq line (buffer-substring-no-properties
                             (point-min) (point-max)))))))
      (unless (or (null line) (string-empty-p line))
        (decode-coding-string line 'utf-8)))))

(defun agent-codex--read-session-header (file dir)
  "Return a header plist for rollout FILE when its session ran in DIR.
Return nil for files from another directory, for subagent threads, and
for files that cannot be read or parsed."
  (when-let* ((header (agent-codex--rollout-header file)))
    (when (and (not (equal (plist-get header :thread-source) "subagent"))
               (agent-codex--same-directory-p (plist-get header :cwd) dir))
      header)))

(defconst agent-codex--rollout-header-cache-limit 4096
  "Entries `agent-codex--rollout-header-cache' holds before it is emptied.
A full scan of a large session store caches a few thousand small
plists.  Emptying the table wholesale past this point bounds what a
long-running Emacs accumulates without the bookkeeping an eviction
order would need, and the next scan refills it.")

(defvar agent-codex--rollout-header-cache (make-hash-table :test #'equal)
  "Map from rollout file path to (MTIME . HEADER) for parsed headers.
HEADER is what `agent-codex--parse-rollout-header' returned when the
file was last modified at MTIME.  A rollout's opening `session_meta'
record is written once and never rewritten, so the parse stays valid
until the file changes -- and a session still appending to its own
rollout is the one file whose header is read again.")

(defun agent-codex--rollout-header (file)
  "Return the header plist parsed from rollout FILE, or nil.
The parse is memoized on FILE's modification time, so scanning the same
store twice costs a stat per file rather than a read and a JSON parse.
A file whose modification time cannot be read is parsed without being
cached, since there is nothing to invalidate the entry against."
  (let ((mtime (file-attribute-modification-time (file-attributes file))))
    (or (agent-codex--cached-rollout-header file mtime)
        (when-let* ((header (agent-codex--parse-rollout-header file)))
          (agent-codex--cache-rollout-header file mtime header)
          header))))

(defun agent-codex--cached-rollout-header (file mtime)
  "Return the header cached for FILE when it was parsed at MTIME."
  (when-let* ((mtime)
              (entry (gethash file agent-codex--rollout-header-cache))
              ((time-equal-p (car entry) mtime)))
    (cdr entry)))

(defun agent-codex--cache-rollout-header (file mtime header)
  "Cache HEADER as the header FILE had when last modified at MTIME."
  (when mtime
    (when (> (hash-table-count agent-codex--rollout-header-cache)
             agent-codex--rollout-header-cache-limit)
      (clrhash agent-codex--rollout-header-cache))
    (puthash file (cons mtime header) agent-codex--rollout-header-cache)))

(defun agent-codex--parse-rollout-header (file)
  "Return the header plist read from rollout FILE, or nil.
Only the first line, which holds the `session_meta' record, is read.
The error guard sits in `agent-codex--read-session-meta' and covers that
read alone, so a fault in the extraction below signals instead of
passing for a session that simply is not there."
  (when-let* ((json (agent-codex--read-session-meta file))
              (payload (plist-get json :payload))
              (id (agent-codex--session-id-from-file file)))
    (let ((parent (plist-get payload :forked_from_id)))
      (list :session-id id
            :forked-from (and (stringp parent)
                              (not (equal parent id))
                              parent)
            :thread-source (plist-get payload :thread_source)
            :cwd (plist-get payload :cwd)
            :timestamp (plist-get payload :timestamp)
            :file-path file))))

(defun agent-codex--read-session-meta (file)
  "Return the parsed `session_meta' record opening rollout FILE, or nil.
FILE is skipped, rather than signalling, only when it is unreadable or
malformed -- the two things a directory of transcripts written by
another process can legitimately hand us."
  (condition-case nil
      (when-let* ((line (agent-codex--read-first-line file)))
        (json-parse-string line :object-type 'plist))
    ((json-error file-error end-of-file) nil)))

(defun agent-codex--scan-session-headers (dir &optional since)
  "Return a hash of session id to header plist for sessions run in DIR.
SINCE, when non-nil, is a rollout start timestamp; rollouts that started
before it are skipped, which is what bounds the scan when only a
session's descendants matter."
  (let ((table (make-hash-table :test #'equal))
        (root (expand-file-name codex-transcript-sessions-directory)))
    (when (file-directory-p root)
      (dolist (file (directory-files-recursively
                     root "\\`rollout-.*\\.jsonl\\'"))
        (unless (agent-codex--rollout-started-before-p file since)
          (when-let* ((header (agent-codex--read-session-header file dir)))
            (puthash (plist-get header :session-id) header table)))))
    table))

(defun agent-codex--rollout-started-before-p (file since)
  "Return non-nil when rollout FILE started before timestamp SINCE.
SINCE is a start timestamp string, or nil to bound nothing.  A FILE
whose name carries no start timestamp is never reported as earlier, so
an unrecognized name widens the scan rather than dropping the file."
  (when-let* ((since)
              (start (agent-codex--session-start-timestamp file)))
    (string< start since)))

(defun agent-codex--session-headers (buffer &optional descendants-of)
  "Return Codex session headers for BUFFER's project directory.
BUFFER is a session buffer; a dead one yields an empty table rather than
nil, because the backend slot promises a hash table.  DESCENDANTS-OF is
a session id that bounds the scan to rollouts started no earlier than
that session's own.  A fork always starts after its parent, so the bound
still reaches the whole subtree below it, and it spares the caller a
read of every rollout on disk.  Without DESCENDANTS-OF the bound comes
from the root of BUFFER's own fork family, which reaches every member of
that family for the same reason.  An anchor whose rollout cannot be
found, and a family whose root cannot be established, leave the scan
unbounded: slow, but never silently partial."
  (if (not (buffer-live-p buffer))
      (make-hash-table :test #'equal)
    (let* ((dir (with-current-buffer buffer default-directory))
           (file (if descendants-of
                     (codex--find-session-transcript descendants-of)
                   (when-let* ((id (agent-codex--session-identity buffer)))
                     (agent-codex--fork-family-root-file id))))
           (since (when file (agent-codex--session-start-timestamp file))))
      (agent-codex--scan-session-headers dir since))))

(defun agent-codex--fork-family-root-file (session-id)
  "Return the rollout file of the fork family SESSION-ID belongs to.
Climb the `forked_from_id' chain a file at a time -- fork chains run a
few links long, and each link costs one header read -- and return the
rollout of the topmost ancestor.  Return nil whenever the chain cannot
be followed all the way up: when an ancestor's rollout is missing or
unreadable, or when a corrupt `forked_from_id' points back into its own
ancestry.  A half-climbed chain is no answer, because the ancestor that
stopped it can have other children older than anything the climb saw."
  (let ((id session-id)
        (seen (make-hash-table :test #'equal))
        (file nil))
    (catch 'done
      (while id
        (when (gethash id seen)
          (throw 'done nil))
        (puthash id t seen)
        (let* ((found (or (codex--find-session-transcript id)
                          (throw 'done nil)))
               (header (or (agent-codex--rollout-header found)
                           (throw 'done nil))))
          (setq file found
                id (plist-get header :forked-from))))
      file)))

(defun agent-codex--user-prompt-from-line (line)
  "Return the human prompt text in rollout LINE, or nil."
  (condition-case nil
      (let* ((json (json-parse-string line :object-type 'plist))
             (payload (plist-get json :payload)))
        (when (and (equal (plist-get payload :type) "message")
                   (equal (plist-get payload :role) "user"))
          (let* ((content (plist-get payload :content))
                 (text (when (and (vectorp content) (> (length content) 0))
                         (plist-get (aref content 0) :text))))
            (when (and (stringp text)
                       (not (string-empty-p (string-trim text)))
                       (not (seq-some
                             (lambda (prefix) (string-prefix-p prefix text))
                             agent-codex--injected-prompt-prefixes)))
              (string-trim text)))))
    (error nil)))

(defun agent-codex--first-user-prompt (file)
  "Return the first human prompt in rollout FILE, or nil."
  (when (and file (file-readable-p file))
    (with-temp-buffer
      (let ((coding-system-for-read 'utf-8))
        (insert-file-contents file))
      (goto-char (point-min))
      (catch 'found
        (while (not (eobp))
          (when-let* ((text (agent-codex--user-prompt-from-line
                             (buffer-substring-no-properties
                              (point) (line-end-position)))))
            (throw 'found text))
          (forward-line 1))
        nil))))

(defun agent-codex--session-prompt (header)
  "Return HEADER enriched with the session's first prompt.
The prompt is truncated to one short line, matching how the Claude
backend renders branch trees."
  (append (list :first-prompt
                (if-let* ((text (agent-codex--first-user-prompt
                                 (plist-get header :file-path))))
                    (truncate-string-to-width
                     (replace-regexp-in-string "[\n\r\t]+" " " text)
                     60 nil nil "…")
                  "(no prompt)"))
          header))

;;;; Minor mode

(defvar agent-codex--saved-notification-function nil
  "Value of `codex-notification-function' before enabling the mode.")

(defconst agent-codex--start-hook-functions
  '(agent-setup-kill-on-exit
    agent-codex-set-modeline
    agent--refresh-display-names
    agent-disable-scrollback-truncation
    agent-setup-scroll-keys
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
  (setq codex-notification-function #'codex-default-notification)
  (add-hook 'codex-event-hook #'agent-codex--handle-notification)
  (add-hook 'kill-buffer-query-functions #'agent-protect-buffer)
  (dolist (fn agent-codex--start-hook-functions)
    (add-hook 'codex-start-hook fn))
  (agent-scroll-keys-global-mode 1)
  (agent-setup-scroll-keys-in-existing-buffers)
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
    (remove-hook 'kill-buffer-query-functions #'agent-protect-buffer)
    (agent-scroll-keys-global-mode -1))
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
