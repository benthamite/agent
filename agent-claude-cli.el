;;; agent-claude-cli.el --- Claude Code CLI conventions -*- lexical-binding: t -*-

;; Copyright (C) 2026

;; Author: Pablo Stafforini
;; URL: https://github.com/benthamite/agent
;; Version: 0.1
;; Package-Requires: ((emacs "30.0"))

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

;; Quarantines every undocumented Claude Code CLI convention that the
;; agent package relies on: Keychain credential naming, the usage API
;; endpoint, the `~/.claude/projects/' directory encoding, transcript
;; JSONL parsing, and the `.claude.json' merge engine.  Each group
;; carries a header comment naming the convention and the CLI version
;; it was last verified against.  This file is deliberately a leaf: it
;; requires no other agent module.

;;; Code:

(require 'json)
(require 'subr-x)
(require 'url)

(defvar url-http-attempt-keepalives)

;;;; Warn-once machinery

(defvar agent-claude-cli--warned nil
  "Keys already reported by `agent-claude-cli--warn-once'.")

(defun agent-claude-cli--warn-once (key format &rest args)
  "Warn once per KEY with FORMAT and ARGS, then stay silent.
Replaces the silent nil-on-failure behavior of the CLI-convention
helpers so breakage after a CLI update surfaces exactly once."
  (unless (member key agent-claude-cli--warned)
    (push key agent-claude-cli--warned)
    (display-warning 'agent-claude-cli (apply #'format format args) :warning)))

;;;; Keychain credentials

;; CLI convention: OAuth credentials live in the macOS Keychain under
;; the generic-password service "Claude Code-credentials"; when a
;; non-default CLAUDE_CONFIG_DIR is active, the service name gains a
;; suffix of the first 8 hex chars of the SHA-256 of the expanded
;; config-dir path.  The secret is a JSON object whose
;; `claudeAiOauth.accessToken' field holds the bearer token.  An
;; API-key account instead caches its key under the sibling service
;; "Claude Code[-<hash>]" (no "-credentials") and leaves the OAuth
;; service holding an empty "{}"; that is a valid non-OAuth account,
;; not a breakage, so it must not warn.
;; Last verified against Claude Code 2.1.202 on 2026-07-07.

(defun agent-claude-cli-oauth-token (config-dir)
  "Extract the OAuth access token from the macOS Keychain for CONFIG-DIR.
CONFIG-DIR is the account's `CLAUDE_CONFIG_DIR' path, or nil for the
default configuration.  Returns the token string, or nil when the
account is not OAuth-authenticated (for example an API-key account,
whose OAuth store is an empty `{}').  Warns once only when the Keychain
read itself fails, since a failed read—not a missing subscription
login—is what signals a CLI-convention change.

Runs `security' from `temporary-file-directory': callers such as the
usage-poller timer can fire with `default-directory' naming a deleted
worktree, and `call-process' signals `file-missing' when asked to spawn
there."
  (let* ((service (agent-claude-cli-keychain-service config-dir))
         (default-directory temporary-file-directory)
         (raw (string-trim
               (with-output-to-string
                 (with-current-buffer standard-output
                   (call-process "security" nil t nil
                                 "find-generic-password"
                                 "-s" service "-w")))))
         (parsed (condition-case nil
                     (json-parse-string raw :object-type 'plist)
                   (json-error 'unreadable))))
    (if (eq parsed 'unreadable)
        (progn
          (agent-claude-cli--warn-once
           (list 'oauth service)
           "no OAuth credentials in Keychain service %s" service)
          nil)
      (plist-get (plist-get parsed :claudeAiOauth) :accessToken))))

(defun agent-claude-cli-keychain-service (config-dir)
  "Return the macOS Keychain service name for CONFIG-DIR.
Computes the SHA-256 prefix of the expanded CONFIG-DIR path,
matching Claude Code's credential storage convention.  When
CONFIG-DIR is nil, returns the default service name."
  (if config-dir
      (concat "Claude Code-credentials-"
              (substring (secure-hash 'sha256 (expand-file-name config-dir))
                         0 8))
    "Claude Code-credentials"))

;;;; Usage API

;; CLI convention: account utilization (5-hour session and 7-day
;; weekly windows) comes from the undocumented
;; `api.anthropic.com/api/oauth/usage' endpoint, authenticated with
;; the Keychain OAuth bearer token plus an `anthropic-beta:
;; oauth-2025-04-20' header.
;; Last verified against Claude Code 2.1.172 on 2026-06-11.

(defconst agent-claude-cli-usage-endpoint
  "https://api.anthropic.com/api/oauth/usage"
  "Undocumented usage endpoint queried with an OAuth bearer token.")

(defconst agent-claude-cli-usage-beta-header "oauth-2025-04-20"
  "Value of the `anthropic-beta' header required by the usage endpoint.")

(defun agent-claude-cli-fetch-usage (token callback cbargs)
  "Start an async request against the usage endpoint with TOKEN.
CALLBACK and CBARGS are passed through to `url-retrieve'.
Returns the value of `url-retrieve'."
  (let ((url-http-attempt-keepalives nil)
        (url-request-method "GET")
        (url-request-extra-headers
         `(("Authorization" . ,(concat "Bearer " token))
           ("anthropic-beta" . ,agent-claude-cli-usage-beta-header))))
    (url-retrieve agent-claude-cli-usage-endpoint callback cbargs t t)))

;;;; Projects directory

;; CLI convention: session transcripts are stored under
;; `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl', where
;; <encoded-cwd> is the absolute working directory with every
;; character outside [A-Za-z0-9-] replaced by "-".  `--resume ID'
;; only finds sessions in the directory encoded from the current cwd,
;; and follows symlinked JSONL files.
;; Last verified against Claude Code 2.1.172 on 2026-06-11.

(defun agent-claude-cli-link-session-into-project (session-id source-cwd target-cwd)
  "Symlink SESSION-ID's JSONL from SOURCE-CWD's project dir into TARGET-CWD's.
Lets `--resume SESSION-ID' find the session when the CLI runs from
TARGET-CWD instead of SOURCE-CWD, since Claude Code stores sessions
under `~/.claude/projects/<encoded-cwd>/'."
  (let* ((filename (concat session-id ".jsonl"))
         (src (expand-file-name
               filename
               (agent-claude-cli-project-dir source-cwd)))
         (dst-dir (agent-claude-cli-project-dir target-cwd))
         (dst (expand-file-name filename dst-dir)))
    (unless (file-exists-p src)
      (error "Session JSONL not found: %s" src))
    (make-directory dst-dir t)
    (unless (file-exists-p dst)
      (make-symbolic-link src dst))))

(defun agent-claude-cli-project-dir (cwd)
  "Return the `~/.claude/projects/' directory Claude Code derives from CWD."
  (expand-file-name (agent-claude-cli-encode-project-cwd cwd)
                    "~/.claude/projects/"))

(defun agent-claude-cli-encode-project-cwd (path)
  "Encode PATH the way Claude Code names dirs under `~/.claude/projects/'."
  (replace-regexp-in-string
   "[^A-Za-z0-9-]" "-"
   (directory-file-name (expand-file-name path))))

;;;; Transcript JSONL

;; CLI convention: transcripts are JSONL whose first line carries
;; `sessionId' and, for branched sessions, a `forkedFrom' object with
;; `sessionId' and `messageUuid'.  User prompts are lines of type
;; "user" whose `message.content' is a non-empty string; each line
;; carries a `uuid' and a `timestamp'.
;; Last verified against Claude Code 2.1.172 on 2026-06-11.

(defun agent-claude-cli-read-session-header (jsonl-file)
  "Read first line of JSONL-FILE and return a lightweight metadata plist.
Returns (:session-id :forked-from :fork-uuid :file-path) or nil.
This is fast (reads only first few KB) and is used for the initial
scan to build the branch tree."
  (condition-case nil
      (with-temp-buffer
        (let ((coding-system-for-read 'utf-8))
          (insert-file-contents jsonl-file nil 0 65536))
        (goto-char (point-min))
        (let* ((line (buffer-substring-no-properties
                      (point) (line-end-position)))
               (json (json-parse-string line :object-type 'plist))
               (forked (plist-get json :forkedFrom)))
          (list :session-id (plist-get json :sessionId)
                :forked-from (when forked (plist-get forked :sessionId))
                :fork-uuid (when forked (plist-get forked :messageUuid))
                :file-path jsonl-file)))
    (error
     (agent-claude-cli--warn-once
      (list 'session-header jsonl-file)
      "unparseable session header in %s" jsonl-file)
     nil)))

(defun agent-claude-cli-read-session-prompt (header)
  "Enrich HEADER plist with :first-prompt and :timestamp.
Reads the full JSONL file referenced by HEADER's :file-path."
  (let ((file (plist-get header :file-path))
        (fork-uuid (plist-get header :fork-uuid))
        (session-id (plist-get header :session-id))
        (forked-from (plist-get header :forked-from)))
    (condition-case nil
        (with-temp-buffer
          (let ((coding-system-for-read 'utf-8))
            (insert-file-contents file))
          (goto-char (point-min))
          (if fork-uuid
              (agent-claude-cli--branch-prompt
               session-id forked-from fork-uuid)
            (agent-claude-cli--root-prompt session-id)))
      (error (list :session-id session-id
                   :forked-from forked-from
                   :first-prompt "(error reading session)"
                   :timestamp nil)))))

(defun agent-claude-cli--user-message-prompt-p (json)
  "Return non-nil if JSON is a user message with text content."
  (and (equal (plist-get json :type) "user")
       (let* ((msg (plist-get json :message))
              (content (when msg (plist-get msg :content))))
         (and (stringp content)
              (not (string-empty-p (string-trim content)))))))

(defun agent-claude-cli--root-prompt (session-id)
  "Find the first user prompt in the current buffer for SESSION-ID."
  (goto-char (point-min))
  (let ((result nil))
    (while (and (not result) (not (eobp)))
      (let ((json (agent-claude-cli--parse-jsonl-line)))
        (when (and json (agent-claude-cli--user-message-prompt-p json))
          (setq result (agent-claude-cli--meta-from-json
                        session-id nil json))))
      (forward-line 1))
    (or result
        (list :session-id session-id :forked-from nil
              :first-prompt "(no prompt)" :timestamp nil))))

(defun agent-claude-cli--branch-prompt (session-id forked-from fork-uuid)
  "Find the first new user prompt after FORK-UUID in the current buffer.
SESSION-ID and FORKED-FROM are passed through to the result."
  (goto-char (point-min))
  (let ((found-fork nil)
        (result nil))
    (while (and (not result) (not (eobp)))
      (let ((json (agent-claude-cli--parse-jsonl-line)))
        (when json
          (if (not found-fork)
              (when (string= (plist-get json :uuid) fork-uuid)
                (setq found-fork t))
            (when (agent-claude-cli--user-message-prompt-p json)
              (setq result (agent-claude-cli--meta-from-json
                            session-id forked-from json))))))
      (forward-line 1))
    (or result
        (list :session-id session-id
              :forked-from forked-from
              :first-prompt "(branch)"
              :timestamp nil))))

(defun agent-claude-cli--parse-jsonl-line ()
  "Parse the current line as JSON, returning a plist or nil."
  (let ((line (buffer-substring-no-properties
               (line-beginning-position) (line-end-position))))
    (unless (string-empty-p line)
      (condition-case nil
          (json-parse-string line :object-type 'plist)
        (error nil)))))

(defun agent-claude-cli--meta-from-json (session-id forked-from json)
  "Build metadata plist from SESSION-ID, FORKED-FROM id, and message JSON."
  (let* ((msg (plist-get json :message))
         (content (when msg (plist-get msg :content))))
    (list :session-id session-id
          :forked-from forked-from
          :first-prompt (agent-claude-cli--truncate-prompt content)
          :timestamp (plist-get json :timestamp))))

(defun agent-claude-cli--truncate-prompt (content)
  "Truncate CONTENT to a short display string."
  (if (stringp content)
      (truncate-string-to-width
       (replace-regexp-in-string "[\n\r\t]+" " " (string-trim content))
       60 nil nil "…")
    "(no prompt)"))

(defun agent-claude-cli-scan-session-headers (project-dir)
  "Scan JSONL files in PROJECT-DIR and return session headers.
Returns a hash table mapping session ID to a lightweight header
plist.  Only reads the first line of each file (fast)."
  (let ((table (make-hash-table :test 'equal)))
    (dolist (file (directory-files project-dir t "\\.jsonl\\'"))
      (let ((header (agent-claude-cli-read-session-header file)))
        (when (and header (plist-get header :session-id))
          (puthash (plist-get header :session-id) header table))))
    table))

;;;; .claude.json merge engine

;; CLI convention: `~/.claude.json' (or `<CLAUDE_CONFIG_DIR>/.claude.json')
;; is a single JSON object holding `mcpServers' (per-server config
;; with a nested `env' object), `projects' (per-directory state with
;; `hasTrustDialogAccepted'), and UI keys such as `theme'.  The CLI
;; watches the file for changes while running.
;; Last verified against Claude Code 2.1.172 on 2026-06-11.

(defconst agent-claude-cli-shared-claude-json-keys
  '("theme" "claudeInChromeDefaultEnabled"
    "hasCompletedClaudeInChromeOnboarding")
  "Keys copied verbatim from canonical `~/.claude.json' to account copies.
The `mcpServers' key is handled separately via per-server deep
merge.  The `projects' key is handled separately via trust-aware
merge logic.")

(defun agent-claude-cli-merge-mcp-servers (canonical target)
  "Merge CANONICAL MCP servers into TARGET, preserving per-account env.
For each server in CANONICAL, copy all keys into TARGET's entry
but deep-merge the `env' hash table so per-account entries
survive.  Returns the merged result."
  (let ((result (or target (make-hash-table :test #'equal))))
    (maphash
     (lambda (name config)
       (let ((existing (gethash name result)))
         (if (not (and existing (hash-table-p existing)))
             (puthash name config result)
           (let ((account-env (copy-hash-table (gethash "env" existing
                                                        (make-hash-table)))))
             (maphash (lambda (k v) (puthash k v existing)) config)
             (agent-claude-cli--deep-merge-env account-env
                                               (gethash "env" existing))))))
     canonical)
    result))

(defun agent-claude-cli--deep-merge-env (account-env target-env)
  "Merge ACCOUNT-ENV entries into TARGET-ENV, account wins on conflict.
Modifies TARGET-ENV in place."
  (when (and (hash-table-p account-env)
             (> (hash-table-count account-env) 0))
    (maphash (lambda (k v) (puthash k v target-env)) account-env)))

(defun agent-claude-cli-read-claude-json (path)
  "Read and parse the JSON file at PATH.
Return a hash table, or nil if PATH does not exist or is invalid."
  (when (file-exists-p path)
    (condition-case nil
        (with-temp-buffer
          (insert-file-contents path)
          (json-parse-buffer))
      (error
       (agent-claude-cli--warn-once
        (list 'claude-json path)
        "unreadable or invalid JSON at %s" path)
       nil))))

(defun agent-claude-cli-merge-project (table key val)
  "Merge project VAL under KEY into TABLE.
Prefers entries where `hasTrustDialogAccepted' is true."
  (let ((existing (gethash key table)))
    (cond
     ((not existing)
      (puthash key val table))
     ((and (hash-table-p val)
           (eq (gethash "hasTrustDialogAccepted" val) t)
           (not (eq (gethash "hasTrustDialogAccepted" existing) t)))
      (puthash key val table)))))

(defun agent-claude-cli-write-claude-json (path data)
  "Write DATA as pretty-printed JSON to PATH."
  (require 'json)
  (with-temp-file path
    (insert (json-serialize data))
    (json-pretty-print-buffer)))

;;;; Provide

(provide 'agent-claude-cli)
;;; agent-claude-cli.el ends here
