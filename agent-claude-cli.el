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
(require 'seq)
(require 'subr-x)
(require 'agent-util)

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

(defun agent-claude-cli-usage-headers (token)
  "Return the request headers for the usage endpoint with OAuth TOKEN.
The value is an alist of (NAME . VALUE) strings."
  `(("Authorization" . ,(concat "Bearer " token))
    ("anthropic-beta" . ,agent-claude-cli-usage-beta-header)))

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

(defvar agent-claude-cli-projects-directory "~/.claude/projects/"
  "Directory under which Claude Code stores per-project transcripts.")

(defun agent-claude-cli-project-dir (cwd)
  "Return the `~/.claude/projects/' directory Claude Code derives from CWD."
  (expand-file-name (agent-claude-cli-encode-project-cwd cwd)
                    agent-claude-cli-projects-directory))

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
This is fast (reads only the first line) and is used for the initial
scan to build the branch tree."
  (condition-case nil
      (let* ((line (agent-util-read-first-line jsonl-file))
             (json (json-parse-string line :object-type 'plist))
             (forked (plist-get json :forkedFrom)))
        (list :session-id (plist-get json :sessionId)
              :forked-from (when forked (plist-get forked :sessionId))
              :fork-uuid (when forked (plist-get forked :messageUuid))
              :file-path jsonl-file))
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

;; CLI convention: transcript lines after the first few carry the
;; session's working directory as a string `cwd'.  A session's JSONL
;; may also appear in other project dirs as a symlink created by
;; `agent-claude-cli-link-session-into-project'.
;; Last verified against Claude Code 2.1.172 on 2026-10-02.

(defconst agent-claude-cli-cwd-scan-bytes 262144
  "Bytes read from the start of a transcript when looking for its `cwd'.")

(defun agent-claude-cli-session-directory (session-id)
  "Return the working directory SESSION-ID was started in, or nil.
Look for the transcript under `agent-claude-cli-projects-directory',
preferring the original file to any symlink of it, and read the first
`cwd' it records."
  (when-let* ((file (agent-claude-cli--session-file session-id)))
    (agent-claude-cli--transcript-cwd file)))

(defun agent-claude-cli--session-file (session-id &optional projects-directory)
  "Return the transcript file for SESSION-ID, or nil when there is none.
Look under PROJECTS-DIRECTORY, by default
`agent-claude-cli-projects-directory'.  An original file is preferred to
a symlink of it."
  (let ((files (file-expand-wildcards
                (expand-file-name (concat "*/" session-id ".jsonl")
                                  (or projects-directory
                                      agent-claude-cli-projects-directory)))))
    (or (seq-find (lambda (file) (not (file-symlink-p file))) files)
        (car files))))

(defun agent-claude-cli--transcript-cwd (file)
  "Return the first `cwd' string recorded in transcript FILE, or nil."
  (with-temp-buffer
    (let ((coding-system-for-read 'utf-8))
      (insert-file-contents file nil 0 agent-claude-cli-cwd-scan-bytes))
    (goto-char (point-min))
    (let (cwd)
      (while (and (not cwd) (not (eobp)))
        (let ((json (agent-claude-cli--parse-jsonl-line)))
          (when (stringp (plist-get json :cwd))
            (setq cwd (plist-get json :cwd))))
        (forward-line 1))
      cwd)))

;; CLI convention: continuing a session in a background session gives the
;; successor its own transcript and records a `continued-in' line in the
;; original.  The successor holds only title records until it runs a turn,
;; and resuming it then shows an empty conversation.
;;
;; Last verified against the transcripts of Claude Code on 2026-11-05.

(defconst agent-claude-cli-empty-transcript-limit 65536
  "Size in bytes above which a transcript is taken to hold a conversation.")

(defun agent-claude-cli-conversation-session (session-id &optional seen)
  "Return the id of the session holding the conversation of SESSION-ID.
That is SESSION-ID itself, unless its transcript records no messages and
another session in the same project continued in it.  That session is
then followed in turn.  SEEN lists the ids already followed."
  (if-let* (((not (member session-id seen)))
            (file (agent-claude-cli--session-file session-id))
            ((agent-claude-cli--transcript-empty-p file))
            (origin (agent-claude-cli--continued-from session-id file)))
      (agent-claude-cli-conversation-session origin (cons session-id seen))
    session-id))

(defun agent-claude-cli--transcript-empty-p (file)
  "Return non-nil if transcript FILE records no messages.
A line that does not parse counts as a message, so that doubt leaves the
session as it is."
  (and (<= (file-attribute-size (file-attributes file))
           agent-claude-cli-empty-transcript-limit)
       (with-temp-buffer
         (let ((coding-system-for-read 'utf-8))
           (insert-file-contents file))
         (goto-char (point-min))
         (let ((empty t))
           (while (and empty (not (eobp)))
             (unless (looking-at-p "[ \t]*$")
               (let ((type (plist-get (agent-claude-cli--parse-jsonl-line)
                                      :type)))
                 (setq empty (and type (not (member type '("user" "assistant")))))))
             (forward-line 1))
           empty))))

(defun agent-claude-cli--continued-from (session-id file)
  "Return the id of the session that continued in SESSION-ID, or nil.
Search the project directory of FILE, the transcript of SESSION-ID.  The
text searched for has unescaped quotes, so a conversation that merely
mentions the record does not match.  When several sessions match, return
the one whose transcript changed last."
  (let* ((directory (file-name-directory file))
         (record (format "\"continuedInSessionId\":\"%s\"" session-id))
         (origins (seq-filter
                   (lambda (candidate)
                     (equal (file-name-directory candidate) directory))
                   (process-lines-ignore-status
                    "grep" "-rlF" "--include=*.jsonl" "--"
                    record (directory-file-name directory)))))
    (when origins
      (file-name-base
       (car (sort origins #'file-newer-than-file-p))))))

;;;; Transcript history
;; CLI convention: a transcript is JSONL, and most of its bytes are not
;; conversation.  What a person said is a `user' line whose
;; `message.content' is a string or an array of blocks; what the model
;; said is an `assistant' line with one block per line.  A prompt typed
;; while the model works is a `queued_command' attachment.  `isMeta',
;; `isCompactSummary' and `isSidechain' mark text the CLI injected or a
;; subagent's own conversation.  User text the CLI injected also opens
;; with one of the tags in `agent-claude-cli--injected-text-regexp'.
;; Last verified against the transcripts of Claude Code on 2026-11-04.

(defconst agent-claude-cli--injected-text-regexp
  "\\`[ \t\n]*<\\(?:local-command-[a-z]+\\|task-notification\\|teammate-message\\|system-reminder\\|bash-[a-z]+\\|user-prompt-submit-hook\\)[ >]"
  "Regexp matching user text that the CLI wrote rather than the user.")

(defun agent-claude-cli-transcript-history (file bytes &optional before after)
  "Return the conversation in at most BYTES bytes of transcript FILE.
BEFORE and AFTER, and the plist returned, are as in
`agent-util-jsonl-history', which reads the lines; this function says
what each Claude transcript line means."
  (agent-util-jsonl-history file bytes before after
                            #'agent-claude-cli--entry-messages))

(defun agent-claude-cli--entry-messages (entry)
  "Return the messages transcript line ENTRY records, as a list of plists."
  (let* ((type (plist-get entry :type))
         (message (plist-get entry :message))
         (time (plist-get entry :timestamp)))
    (unless (or (plist-get entry :isSidechain)
                (plist-get entry :isMeta)
                (plist-get entry :isCompactSummary)
                (not (listp message)))
      (mapcar (lambda (part)
                (list :role (car part) :text (cdr part) :time time))
              (pcase type
                ("user" (agent-claude-cli--user-parts
                         (plist-get message :content)))
                ("assistant" (agent-claude-cli--assistant-parts
                              (plist-get message :content)))
                ("attachment" (agent-claude-cli--queued-prompt-parts
                               (plist-get entry :attachment))))))))

(defun agent-claude-cli--queued-prompt-parts (attachment)
  "Return (ROLE . TEXT) pairs for a prompt the user typed mid-turn.
Such a prompt is recorded only as an ATTACHMENT of type `queued_command',
which also carries background task notifications and messages from other
sessions, the latter marked `isMeta'."
  (when (and (equal (plist-get attachment :type) "queued_command")
             (equal (plist-get attachment :commandMode) "prompt")
             (not (plist-get attachment :isMeta)))
    (agent-claude-cli--user-parts (plist-get attachment :prompt))))

(defun agent-claude-cli--user-parts (content)
  "Return (ROLE . TEXT) pairs for what the user wrote in message CONTENT."
  (delq nil
        (mapcar (lambda (block)
                  (pcase (and (not (stringp block)) (plist-get block :type))
                    ('nil (agent-claude-cli--user-text-part block))
                    ("text" (agent-claude-cli--user-text-part
                             (plist-get block :text)))
                    ("image" (cons "user" "[image]"))))
                (if (stringp content) (list content) content))))

(defun agent-claude-cli--user-text-part (text)
  "Return a (ROLE . TEXT) pair for user TEXT, or nil if the CLI wrote it.
A slash command is recorded wrapped in tags, and is shown as typed."
  (when (and (stringp text)
             (not (string-blank-p text))
             (not (string-match-p agent-claude-cli--injected-text-regexp text)))
    (cons "user" (or (agent-claude-cli--slash-command text) text))))

(defun agent-claude-cli--slash-command (text)
  "Return the slash command recorded in user TEXT as typed, or nil."
  (when-let* ((name (agent-claude-cli--tag-content text "command-name")))
    (string-trim (concat name " " (agent-claude-cli--tag-content
                                   text "command-args")))))

(defun agent-claude-cli--tag-content (text tag)
  "Return what the first element named TAG holds in TEXT, or nil."
  (when-let* ((open (concat "<" tag ">"))
              (start (string-search open text))
              (beg (+ start (length open)))
              (end (string-search (concat "</" tag ">") text beg)))
    (substring text beg end)))

(defun agent-claude-cli--assistant-parts (content)
  "Return (ROLE . TEXT) pairs for the text and tool calls in message CONTENT.
Thinking is left out, and a tool call is reduced to the tool's name."
  (delq nil
        (mapcar (lambda (block)
                  (pcase (and (not (stringp block)) (plist-get block :type))
                    ('nil (agent-claude-cli--assistant-text-part block))
                    ("text" (agent-claude-cli--assistant-text-part
                             (plist-get block :text)))
                    ("tool_use" (cons "tool" (plist-get block :name)))))
                (if (stringp content) (list content) content))))

(defun agent-claude-cli--assistant-text-part (text)
  "Return a (ROLE . TEXT) pair for assistant TEXT, or nil if it is blank."
  (when (and (stringp text) (not (string-blank-p text)))
    (cons "assistant" text)))


;;;; Screen panel
;; CLI convention: the bottom of the screen shows what a transcript
;; cannot.  At rest it reads, from the top: a status line such as
;; "✻ Worked for 34s" or a notice with its own options, a rule, the input
;; line "❯" with a no-break space or nothing after it, more input lines,
;; a rule, then the mode line and any agent list.  A rule is full width,
;; and may carry a session name or effort indicator.  A dialog or picker
;; replaces the input box, opens with a rule of its own, may hold further
;; rules, and marks its options "❯ 1." with an ordinary space, as earlier
;; prompts in the conversation are also marked.  The spinner reads
;; "✢ Forging… (4m 35s · ↓ 2.9k tokens)", with or without parentheses, and
;; the line below the box reads "⏵⏵ auto mode on (shift+tab to cycle) · 5 shells".
;; Last verified against Claude Code 2.1.318 on 2026-11-04.

(defconst agent-claude-cli--screen-rule-regexp "\\`[─▔]\\{20,\\}"
  "Regexp matching a full-width rule on a Claude Code screen.")

(defconst agent-claude-cli--screen-input-regexp "\\`[❯>]\\(?: \\|[ \t]*\\'\\)"
  "Regexp matching the first line of Claude Code's input box.")

(defconst agent-claude-cli--screen-message-regexp "\\`⏺[  ]"
  "Regexp matching the first line of a message on a Claude Code screen.")

(defconst agent-claude-cli--screen-prompt-regexp "\\`❯ "
  "Regexp matching a past prompt on a Claude Code screen.
Only meaningful with an input box on the screen, as without one this may
be a dialog's option.")

(defconst agent-claude-cli--screen-done-regexp "\\`✻ [^…]*\\'"
  "Regexp matching the line Claude Code prints when a turn has ended.
The running spinner may use the same glyph, but has an ellipsis.")

(defconst agent-claude-cli--screen-spinner-regexp
  "\\`[^[:space:][:alnum:]] \\([[:alpha:]][^…(]*…\\)\\(?: *(\\(.*\\))\\)?"
  "Regexp matching Claude Code's spinner line, such as \"✢ Forging… (4m 35s)\".
Group 1 is its verb and group 2 the details in parentheses, if any.")

(defconst agent-claude-cli--screen-notice-option-regexp
  "\\(?:\\`\\| \\)[0-9]: [[:alpha:]]"
  "Regexp matching an option in a notice, such as \"1: Learn more\".")

(defconst agent-claude-cli--screen-option-regexp
  "\\`[^[:alnum:]]*\\([0-9]\\)\\. "
  "Regexp matching a numbered option in a dialog, such as \" ❯ 1. Yes\".")

(defconst agent-claude-cli--screen-dialog-hint-regexp
  "\\(?:Esc to cancel\\|Enter to select\\|Enter to confirm\\)"
  "Regexp matching the key hint a dialog or picker ends with.")

(defun agent-claude-cli-screen-panel (screen)
  "Return which trailing lines of SCREEN the transcript cannot show.
SCREEN is the text of a Claude Code screen.  Return a plist.  `:start' is
the index of the first such line.  `:block' is the index of the message
just above them, which the transcript lacks while it is still being
written, or nil.  `:dialog' is non-nil when SCREEN shows no input box,
which means a dialog, a picker or something unrecognized.  In that case
`:start' errs towards more lines, so no part of a dialog is cut off: the
whole screen if nothing marks where the dialog can begin."
  (let* ((lines (vconcat (split-string screen "\n")))
         (rules (agent-claude-cli--screen-rules lines))
         (box-rule (cadr rules)))
    (if (and box-rule
             (string-match-p agent-claude-cli--screen-input-regexp
                             (aref lines (1+ box-rule))))
        (let ((start (agent-claude-cli--screen-status-start lines box-rule)))
          (list :start start
                :block (agent-claude-cli--screen-message-above lines start)
                :dialog nil))
      (list :start (agent-claude-cli--screen-dialog-start lines rules)
            :block nil
            :dialog t))))

(defun agent-claude-cli--screen-rules (lines)
  "Return the indices of the rules in vector LINES, last first."
  (let (rules)
    (dotimes (index (length lines))
      (when (string-match-p agent-claude-cli--screen-rule-regexp
                            (aref lines index))
        (push index rules)))
    rules))

(defun agent-claude-cli--screen-status-start (lines rule)
  "Return the index where the status above the input box at RULE starts.
LINES is the screen as a vector.  Go up to the first line at the margin,
which is what a status or notice opens with.  Lines above it stay out,
as does a message or past prompt, which is conversation even when
right-aligned text fills the blank line under it.  Failing that, stop
after two blocks of indented lines."
  (let ((start rule) (index (1- rule)) (blocks 0) (in-block nil) (done nil))
    (while (and (not done) (>= index 0))
      (let ((line (aref lines index)))
        (cond ((string-blank-p line)
               (when in-block
                 (setq in-block nil
                       blocks (1+ blocks)
                       done (= blocks 2))))
              ((agent-claude-cli--screen-conversation-p line)
               (setq done t))
              (t
               (setq start index
                     in-block t
                     done (not (string-prefix-p " " line))))))
      (setq index (1- index)))
    start))

(defun agent-claude-cli--screen-conversation-p (line)
  "Return non-nil when screen LINE opens a message or a past prompt."
  (or (string-match-p agent-claude-cli--screen-message-regexp line)
      (string-match-p agent-claude-cli--screen-prompt-regexp line)))

(defun agent-claude-cli--screen-message-above (lines start)
  "Return the index of the message that runs up to line START of LINES, or nil.
Nil when a past prompt or an ended turn comes first, at START or above
it, since then nothing is still being written."
  (let ((index start) (found nil) (done nil))
    (while (and (not done) (>= index 0))
      (let ((line (aref lines index)))
        (cond ((string-match-p agent-claude-cli--screen-message-regexp line)
               (setq found index done t))
              ((or (string-match-p agent-claude-cli--screen-prompt-regexp line)
                   (string-match-p agent-claude-cli--screen-done-regexp line))
               (setq done t))))
      (setq index (1- index)))
    found))

(defun agent-claude-cli--screen-dialog-start (lines rules)
  "Return the index where a dialog on a screen with no input box shows from.
LINES is the screen as a vector and RULES the indices of its rules, last
first.  A dialog opens with a rule and may hold more, so take the topmost
rule below the nearest message or ended turn, which no dialog holds.  A
past prompt is no such mark, as it reads like an option.  Without a mark
the dialog may have outgrown the screen, leaving only its inner rules,
so show all of it."
  (let ((mark (agent-claude-cli--screen-last-mark lines)))
    (cond ((null mark) 0)
          ((car (last (seq-filter (lambda (rule) (> rule mark)) rules))))
          (t mark))))

(defun agent-claude-cli--screen-last-mark (lines)
  "Return the index of the last message or ended turn in vector LINES, or nil."
  (let ((index (1- (length lines))) (found nil))
    (while (and (not found) (>= index 0))
      (let ((line (aref lines index)))
        (when (or (string-match-p agent-claude-cli--screen-message-regexp line)
                  (string-match-p agent-claude-cli--screen-done-regexp line))
          (setq found index)))
      (setq index (1- index)))
    found))

(defun agent-claude-cli-screen-state (screen)
  "Return what the text of a Claude Code SCREEN shows that a transcript cannot.
Return a plist.  `:status' is the running spinner as plain text, or nil.
`:mode' is the mode line as plain text, or nil.  `:running' is non-nil
when a spinner shows.  `:writing' is the text of the message just above
the status, unwrapped, which the transcript lacks while it is being
written, or nil.  `:card' is the text of a dialog, a picker or a notice
that takes input, or nil.  `:options' lists as strings the digits that
choose among the card's options.  `:input' is the text in the input
box, typed or inserted but not yet submitted, or nil.  `:dialog' is
non-nil when the card is a dialog or picker shown in place of the input
box, recognized by its numbered options or its key hint: text typed
then would go to it as keystrokes, not to the prompt.  A card under an
input box, such as a notice, and a screen with nothing recognized are
not dialogs.

A screen with no input box always has a card, by the rules of
`agent-claude-cli-screen-panel'.  A notice with no options takes no input
and is dropped."
  (let* ((lines (vconcat (split-string screen "\n")))
         (panel (agent-claude-cli-screen-panel screen))
         (start (plist-get panel :start)))
    (if (plist-get panel :dialog)
        (let* ((card (append (seq-subseq lines start) nil))
               (options (agent-claude-cli--screen-options card)))
          (list :card (string-join card "\n")
                :options options
                :dialog (and (or options
                                 (seq-some
                                  (lambda (line)
                                    (string-match-p
                                     agent-claude-cli--screen-dialog-hint-regexp
                                     line))
                                  card))
                             t)))
      (agent-claude-cli--screen-box-state lines panel))))

(defun agent-claude-cli--screen-box-state (lines panel)
  "Return the state of a screen that shows an input box.
LINES is the screen as a vector and PANEL the result of
`agent-claude-cli-screen-panel' for it."
  (let* ((rules (agent-claude-cli--screen-rules lines))
         (box (cadr rules))
         (status (append (seq-subseq lines (plist-get panel :start) box) nil))
         (spinner (seq-find (lambda (line)
                              (string-match-p
                               agent-claude-cli--screen-spinner-regexp line))
                            status))
         (notice (seq-some (lambda (line)
                             (string-match-p
                              agent-claude-cli--screen-notice-option-regexp line))
                           status)))
    (list :status (and spinner (agent-claude-cli--screen-spinner-text spinner))
          :running (and spinner t)
          :mode (agent-claude-cli--screen-mode-text
                 (append (seq-subseq lines (1+ (car rules))) nil))
          :writing (when-let* ((block (plist-get panel :block)))
                     (agent-claude-cli--screen-writing lines block box))
          :card (and notice
                     (string-join (seq-remove
                                   (lambda (line) (equal line spinner)) status)
                                  "\n"))
          :options (and notice
                        (agent-claude-cli--screen-notice-options status))
          :input (agent-claude-cli--screen-input
                  (append (seq-subseq lines (1+ box) (car rules)) nil)))))

(defun agent-claude-cli--screen-input (lines)
  "Return the text of input box LINES, those between its rules, or nil.
The first line opens with the prompt mark and the rest are indented by
two columns, which are left out, as is trailing space.  So is text with
the `agent-faint' property: an empty box shows a placeholder or a
suggested prompt faint, and Return would not submit it."
  (agent-claude-cli--non-empty-string
   (string-trim-right
    (string-join
     (mapcar (lambda (line)
               (string-trim-right
                (replace-regexp-in-string
                 (concat "\\(?:" agent-claude-cli--screen-input-regexp
                         "\\|\\`  \\)")
                 "" (agent-claude-cli--without-faint line))))
             lines)
     "\n"))))

(defun agent-claude-cli--without-faint (text)
  "Return TEXT without its characters that have the `agent-faint' property."
  (let ((position 0)
        (parts nil))
    (while (< position (length text))
      (let ((next (next-single-property-change position 'agent-faint text
                                               (length text))))
        (unless (get-text-property position 'agent-faint text)
          (push (substring-no-properties text position next) parts))
        (setq position next)))
    (apply #'concat (nreverse parts))))

(defun agent-claude-cli--screen-plain (text)
  "Return TEXT without glyphs a phone's fonts may lack, and trimmed."
  (string-join
   (split-string (replace-regexp-in-string "[^[:alnum:] !-~…·]" "" text) " +" t)
   " "))

(defun agent-claude-cli--screen-spinner-text (line)
  "Return spinner LINE as \"Verb… 4m 35s · 2.9k tokens\"."
  (when (string-match agent-claude-cli--screen-spinner-regexp line)
    (let ((verb (match-string 1 line))
          (details (match-string 2 line)))
      (string-join
       (delq nil
             (list verb
                  (when details
                    (agent-claude-cli--screen-plain
                     (string-join
                      (seq-remove (lambda (part)
                                    (string-search "esc to" part))
                                  (split-string details " · " t))
                      " · ")))))
       " "))))

(defun agent-claude-cli--screen-mode-text (lines)
  "Return the mode line found in LINES, those below the input box, as text.
Hints on how to use the terminal, and what is right-aligned, are left out."
  (when-let* ((line (seq-find (lambda (line) (not (string-blank-p line))) lines))
              (left (car (split-string (string-trim line) "  +" t))))
    (let ((parts (seq-remove
                  (lambda (part)
                    (string-match-p
                     "esc to\\|for shortcuts\\|for agents\\|/rc\\|/effort" part))
                  (split-string left " · " t))))
      (agent-claude-cli--non-empty-string
       (string-join
        (mapcar (lambda (part)
                  (agent-claude-cli--screen-plain
                   (replace-regexp-in-string " *(.*)" "" part)))
                parts)
        " · ")))))

(defun agent-claude-cli--non-empty-string (string)
  "Return STRING, or nil if it is empty."
  (unless (string-empty-p string) string))

(defun agent-claude-cli--screen-writing (lines block end)
  "Return the text of the message at BLOCK in LINES, before index END, or nil.
It stops at the next line at the margin, a spinner or notice, and leaves
out right-aligned text.  A tool call is no message being written."
  (let ((head (aref lines block))
        (index (1+ block))
        (body nil))
    (while (and (< index end)
                (let ((line (aref lines index)))
                  (or (string-blank-p line) (string-prefix-p " " line))))
      (push (aref lines index) body)
      (setq index (1+ index)))
    (setq body (nreverse body))
    (unless (or (string-match-p "\\`⏺[  ][[:alpha:]_-]+(" head)
                (seq-some (lambda (line)
                            (string-match-p "\\`[  ]*⎿" line))
                          body))
      (agent-claude-cli--screen-unwrap
       (cons (substring head 2)
             (mapcar (lambda (line)
                       (if (string-prefix-p "  " line) (substring line 2) line))
                     (seq-remove (lambda (line)
                                   (string-match-p "\\` \\{20,\\}" line))
                                 body)))))))

(defun agent-claude-cli--screen-unwrap (lines)
  "Return LINES of a message as text, undoing the terminal's wrapping.
A line joins the one before unless it is blank, indented or starts a
list, and it is a guess: only the transcript has the real line breaks."
  (let ((text "") (previous-blank t))
    (dolist (line lines)
      (let ((blank (string-blank-p line)))
        (setq text
              (concat text
                      (cond ((string-empty-p text) "")
                            ((or blank previous-blank
                                 (string-match-p "\\`\\(?: \\|[-*+] \\|[0-9]+[.)] \\)" line))
                             "\n")
                            (t " "))
                      (if blank "" line))
              previous-blank blank)))
    (string-trim text)))

(defun agent-claude-cli--screen-options (lines)
  "Return the digits choosing among the options of a dialog in LINES.
Options come after any content the dialog shows between dashed rules,
such as a file with numbered steps of its own."
  (let (options)
    (dolist (line (reverse (seq-take-while
                            (lambda (line)
                              (not (string-prefix-p "╌╌╌" line)))
                            (reverse lines))))
      (when (string-match agent-claude-cli--screen-option-regexp line)
        (push (match-string 1 line) options)))
    (delete-dups (nreverse options))))

(defun agent-claude-cli--screen-notice-options (lines)
  "Return the digits choosing among the options of a notice in LINES."
  (let (options)
    (dolist (line lines)
      (let ((start 0))
        (while (string-match "\\(?:\\`\\| \\)\\([0-9]\\): [[:alpha:]]" line start)
          (push (match-string 1 line) options)
          (setq start (match-end 1)))))
    (delete-dups (nreverse options))))

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

(defvar agent-claude-cli-read-retry-delays '(0.2 0.5 1.0)
  "Seconds to wait before each re-read of a `.claude.json' that failed to parse.
The CLI rewrites the file frequently, so a read can land mid-write and
see truncated JSON; each retry gives an in-progress writer more time to
finish.")

(defun agent-claude-cli-read-claude-json (path)
  "Read and parse the JSON file at PATH.
Return a hash table, or nil if PATH does not exist or is invalid.  A
parse failure is retried per `agent-claude-cli-read-retry-delays': the
CLI rewrites this file frequently, so a read can land mid-write and see
truncated JSON.  A failure that persists across every retry is warned
about once, with the invalid bytes preserved in a snapshot file."
  (when (file-exists-p path)
    (or (agent-claude-cli--parse-json-file path)
        (agent-claude-cli--reread-claude-json path))))

(defun agent-claude-cli--reread-claude-json (path)
  "Retry parsing PATH, then warn once with an evidence snapshot.
Return the parsed hash table, or nil when every retry fails.  Once a
persistent failure for PATH has been warned about, skip the retries so
a corrupt file does not add delays to every subsequent read."
  (let ((key (list 'claude-json path)))
    (unless (member key agent-claude-cli--warned)
      (or (catch 'parsed
            (dolist (delay agent-claude-cli-read-retry-delays)
              (sleep-for delay)
              (when-let* ((data (agent-claude-cli--parse-json-file path)))
                (throw 'parsed data)))
            nil)
          (progn
            (agent-claude-cli--warn-once
             key "unreadable or invalid JSON at %s (snapshot: %s)"
             path (or (agent-claude-cli--snapshot-invalid-json path)
                      "copy failed"))
            nil)))))

(defun agent-claude-cli--snapshot-invalid-json (path)
  "Copy PATH to a temporary evidence file and return the copy's name.
The CLI rewrites the file frequently, so the invalid bytes must be
preserved to distinguish a read that raced a rewrite from real
corruption.  Return nil if the copy fails."
  (condition-case nil
      (let ((evidence (make-temp-file "agent-claude-cli-invalid-json-"
                                      nil ".json")))
        (copy-file path evidence t)
        evidence)
    (error nil)))

(defun agent-claude-cli--parse-json-file (path)
  "Parse the JSON file at PATH, returning nil on any read or parse error."
  (condition-case nil
      (with-temp-buffer
        (insert-file-contents path)
        (json-parse-buffer))
    (error nil)))

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
  "Write DATA as pretty-printed JSON to PATH.
The JSON is written to a temporary file in PATH's directory and renamed
into place, so a concurrent reader (another Emacs process or the CLI
itself) never observes a truncated file."
  (let* ((path (expand-file-name path))
         (temp (make-temp-file
                (expand-file-name ".claude-json-" (file-name-directory path)))))
    (condition-case err
        (progn
          (with-temp-file temp
            (insert (json-serialize data))
            (json-pretty-print-buffer))
          (rename-file temp path t))
      (error
       (when (file-exists-p temp)
         (delete-file temp))
       (signal (car err) (cdr err))))))

;;;; Background sessions

;; CLI convention: a session whose terminal closes while it is working
;; keeps running in the background.  `claude --resume ID' refuses such
;; a session until it stops; `claude attach SHORT-ID' reopens it.
;; `claude agents --json' lists live sessions as an array of objects
;; whose `sessionId' is the full id, `kind' is "background" or
;; "interactive", and `id' is the short id `attach' takes.
;; Last verified against Claude Code 2.1.302 on 2026-10-16.

(defconst agent-claude-cli-list-sessions-args '("agents" "--json")
  "CLI arguments that print the live sessions as JSON.")

(defun agent-claude-cli-background-attach-id (json session-id)
  "Return the id that attaches to background session SESSION-ID, or nil.
JSON is the output of the CLI run with
`agent-claude-cli-list-sessions-args'.  Return nil when SESSION-ID is
not a live background session.  Unparseable JSON warns once and
returns nil, so the caller resumes as before."
  (condition-case nil
      (when-let* ((entry (seq-find
                          (lambda (entry)
                            (and (equal (plist-get entry :sessionId) session-id)
                                 (equal (plist-get entry :kind) "background")))
                          (json-parse-string json :object-type 'plist
                                             :array-type 'list))))
        (plist-get entry :id))
    (error
     (agent-claude-cli--warn-once
      'list-sessions "unparseable output from `claude agents --json'")
     nil)))

;;;; Provide

(provide 'agent-claude-cli)
;;; agent-claude-cli.el ends here
