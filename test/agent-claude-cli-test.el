;;; agent-claude-cli-test.el --- Tests for agent-claude-cli -*- lexical-binding: t -*-

;;; Commentary:

;; Tests for the Claude Code CLI conventions in agent-claude-cli.el.

;;; Code:

(require 'ert)
(require 'agent-test-helper
         (expand-file-name "agent-test-helper"
                           (file-name-directory (or load-file-name buffer-file-name))))
(require 'cl-lib)
(require 'agent-claude-cli)

;;;; Loading

(ert-deftest agent-claude-cli-test-loads ()
  "Loading the test file provides the `agent-claude-cli' feature."
  (should (featurep 'agent-claude-cli)))

;;;; Projects directory

(ert-deftest agent-claude-cli-test-encode-project-cwd ()
  "Encode a cwd by replacing non-alphanumeric characters with dashes."
  (should (equal (agent-claude-cli-encode-project-cwd "/a/b c/d")
                 "-a-b-c-d")))

;;;; Session directory

(ert-deftest agent-claude-cli-test-session-directory-reads-transcript-cwd ()
  "Return the first string `cwd' recorded in the session's transcript."
  (let* ((root (make-temp-file "agent-projects-" t))
         (agent-claude-cli-projects-directory (file-name-as-directory root))
         (id "11111111-2222-3333-4444-555555555555")
         (project (expand-file-name "-work-proj" root)))
    (unwind-protect
        (progn
          (make-directory project)
          (with-temp-file (expand-file-name (concat id ".jsonl") project)
            (insert "{\"type\":\"mode\",\"cwd\":null}\n"
                    "{\"type\":\"user\",\"cwd\":\"/work/proj\"}\n"))
          (should (equal (agent-claude-cli-session-directory id)
                         "/work/proj"))
          (should-not (agent-claude-cli-session-directory
                       "99999999-2222-3333-4444-555555555555")))
      (delete-directory root t))))

(ert-deftest agent-claude-cli-test-session-file-prefers-original ()
  "Prefer the original transcript to a symlink of it in another project."
  (let* ((root (make-temp-file "agent-projects-" t))
         (agent-claude-cli-projects-directory (file-name-as-directory root))
         (id "11111111-2222-3333-4444-555555555555")
         (original (expand-file-name (concat "-b/" id ".jsonl") root))
         (link (expand-file-name (concat "-a/" id ".jsonl") root)))
    (unwind-protect
        (progn
          (make-directory (file-name-directory original))
          (make-directory (file-name-directory link))
          (with-temp-file original (insert "{}\n"))
          (make-symbolic-link original link)
          (should (equal (agent-claude-cli--session-file id) original)))
      (delete-directory root t))))

;;;; Keychain

(ert-deftest agent-claude-cli-test-keychain-service-for-config-dir ()
  "Derive a suffixed Keychain service name from a config directory."
  (should (string-prefix-p "Claude Code-credentials-"
                           (agent-claude-cli-keychain-service "/tmp/x"))))

(ert-deftest agent-claude-cli-test-keychain-service-default ()
  "Return the default Keychain service name when no config dir is given."
  (should (equal (agent-claude-cli-keychain-service nil)
                 "Claude Code-credentials")))

;;;; Warn-once

(ert-deftest agent-claude-cli-test-warn-once-memoizes-keys ()
  "Report a key once, then stay silent on repeated calls."
  (let ((agent-claude-cli--warned nil)
        (warnings nil))
    (cl-letf (((symbol-function 'display-warning)
               (lambda (&rest args) (push args warnings))))
      (agent-claude-cli--warn-once (list 'test "key") "boom %s" "x")
      (agent-claude-cli--warn-once (list 'test "key") "boom %s" "x"))
    (should (= (length agent-claude-cli--warned) 1))
    (should (= (length warnings) 1))))

;;;; OAuth token lookup

(defmacro agent-claude-cli-test--with-security (output &rest body)
  "Run BODY with `security' stubbed to emit OUTPUT on stdout.
Also binds a `warnings' list capturing `display-warning' calls so BODY
can assert on them."
  (declare (indent 1))
  `(let ((agent-claude-cli--warned nil)
         (warnings nil))
     (cl-letf (((symbol-function 'call-process)
                (lambda (&rest _args) (insert ,output) 0))
               ((symbol-function 'display-warning)
                (lambda (&rest args) (push args warnings))))
       ,@body)))

(ert-deftest agent-claude-cli-test-oauth-token-returns-token ()
  "Return the access token from a valid OAuth credentials blob."
  (agent-claude-cli-test--with-security
      "{\"claudeAiOauth\":{\"accessToken\":\"tok-123\"}}"
    (should (equal (agent-claude-cli-oauth-token "/tmp/acct") "tok-123"))
    (should (null warnings))))

(ert-deftest agent-claude-cli-test-oauth-token-empty-blob-is-silent ()
  "An empty `{}' store (an API-key account) yields nil without warning.
A valid parse that merely lacks `claudeAiOauth' means the account is not
OAuth-authenticated, which is expected rather than a breakage."
  (agent-claude-cli-test--with-security "{}"
    (should (null (agent-claude-cli-oauth-token "/tmp/acct")))
    (should (null warnings))
    (should (null agent-claude-cli--warned))))

(ert-deftest agent-claude-cli-test-oauth-token-survives-deleted-default-directory ()
  "Token lookup succeeds when the caller's `default-directory' is gone.
The usage poller calls this from a timer, so the current buffer's
`default-directory' can name a deleted worktree.  `call-process' spawns
its subprocess in `default-directory' and signals `file-missing' when
that directory no longer exists; the stub reproduces that documented
behavior."
  (let ((agent-claude-cli--warned nil))
    (cl-letf (((symbol-function 'call-process)
               (lambda (&rest _args)
                 (unless (file-directory-p default-directory)
                   (signal 'file-missing
                           (list "Setting current directory"
                                 "No such file or directory"
                                 default-directory)))
                 (insert "{\"claudeAiOauth\":{\"accessToken\":\"tok-123\"}}")
                 0))
              ((symbol-function 'display-warning) #'ignore))
      (let ((default-directory "/nonexistent/deleted-worktree/"))
        (should (equal (agent-claude-cli-oauth-token "/tmp/acct")
                       "tok-123"))))))

(ert-deftest agent-claude-cli-test-oauth-token-unreadable-warns ()
  "An empty or unparseable Keychain read warns once: the lookup failed.
This is the CLI-convention-break signal the warning exists to surface."
  (agent-claude-cli-test--with-security ""
    (should (null (agent-claude-cli-oauth-token "/tmp/acct")))
    (should (= (length warnings) 1))))

;;;; Transcript history

(defmacro agent-claude-cli-test--with-transcript (spec &rest body)
  "Bind (VAR CONTENT) of SPEC to a temp transcript holding CONTENT, run BODY.
CONTENT is written as UTF-8."
  (declare (indent 1))
  `(let ((,(car spec) (make-temp-file "agent-transcript-" nil ".jsonl")))
     (unwind-protect
         (progn
           (let ((coding-system-for-write 'utf-8-unix))
             (write-region ,(cadr spec) nil ,(car spec) nil 'silent))
           ,@body)
       (delete-file ,(car spec)))))

(defun agent-claude-cli-test--line (type &rest fields)
  "Return a transcript line of TYPE with extra FIELDS, newline-terminated."
  (concat (json-serialize (append (list :type type) fields)) "\n"))

(defun agent-claude-cli-test--user (text &rest fields)
  "Return a user transcript line holding TEXT, plus extra FIELDS."
  (apply #'agent-claude-cli-test--line "user"
         :message (list :role "user" :content text)
         fields))

(defun agent-claude-cli-test--assistant (&rest blocks)
  "Return an assistant transcript line holding content BLOCKS."
  (agent-claude-cli-test--line
   "assistant" :message (list :role "assistant" :content (vconcat blocks))))

(defun agent-claude-cli-test--texts (history)
  "Return the (ROLE TEXT) pairs of the messages in HISTORY."
  (mapcar (lambda (message)
            (list (plist-get message :role) (plist-get message :text)))
          (plist-get history :messages)))

(ert-deftest agent-claude-cli-test-history-shows-conversation-only ()
  "User and assistant text is kept; thinking and tool output are not."
  (agent-claude-cli-test--with-transcript
      (file (concat
             (agent-claude-cli-test--line "api-request-blob" :data "noise")
             (agent-claude-cli-test--user "hello" :timestamp "2026-11-04T10:00:00Z")
             (agent-claude-cli-test--assistant
              (list :type "thinking" :thinking "private"))
             (agent-claude-cli-test--assistant (list :type "text" :text "hi"))
             (agent-claude-cli-test--user
              (vector (list :type "tool_result" :content "tool output")))
             (agent-claude-cli-test--user
              (vector (list :type "image" :source "data")
                      (list :type "text" :text "look")))))
    (let ((history (agent-claude-cli-transcript-history file 100000)))
      (should (equal (agent-claude-cli-test--texts history)
                     '(("user" "hello") ("assistant" "hi")
                       ("user" "[image]") ("user" "look"))))
      (should (equal (plist-get (car (plist-get history :messages)) :time)
                     "2026-11-04T10:00:00Z")))))

(ert-deftest agent-claude-cli-test-history-hides-injected-text ()
  "Text the CLI wrote and subagents' conversations are hidden."
  (agent-claude-cli-test--with-transcript
      (file (concat
             (agent-claude-cli-test--user "meta" :isMeta t)
             (agent-claude-cli-test--user "summary" :isCompactSummary t)
             (agent-claude-cli-test--user "subagent" :isSidechain t)
             (agent-claude-cli-test--user "<system-reminder>x</system-reminder>")
             (agent-claude-cli-test--user "<task-notification>x</task-notification>")
             (agent-claude-cli-test--user "<local-command-stdout>x</local-command-stdout>")
             (agent-claude-cli-test--user "<div> typed by a person")))
    (should (equal (agent-claude-cli-test--texts
                    (agent-claude-cli-transcript-history file 100000))
                   '(("user" "<div> typed by a person"))))))

(ert-deftest agent-claude-cli-test-history-shows-slash-command-as-typed ()
  "A slash command appears as typed, without the tags recording it."
  (agent-claude-cli-test--with-transcript
      (file (agent-claude-cli-test--user
             (concat "<command-message>fix</command-message>\n"
                     "<command-name>/fix</command-name>\n"
                     "<command-args>the bug</command-args>")))
    (should (equal (agent-claude-cli-test--texts
                    (agent-claude-cli-transcript-history file 100000))
                   '(("user" "/fix the bug"))))))

(ert-deftest agent-claude-cli-test-history-shows-prompt-typed-mid-turn ()
  "Only prompts a person queued mid-turn appear from attachments."
  (let ((queued (lambda (mode prompt &rest fields)
                  (agent-claude-cli-test--line
                   "attachment"
                   :attachment (append (list :type "queued_command"
                                             :commandMode mode :prompt prompt)
                                       fields)))))
    (agent-claude-cli-test--with-transcript
        (file (concat
               (funcall queued "prompt" "typed")
               (funcall queued "prompt"
                        (vector (list :type "text" :text "typed too")))
               (funcall queued "prompt" "from a peer" :isMeta t)
               (funcall queued "task-notification" "finished")
               (agent-claude-cli-test--line
                "attachment" :attachment (list :type "file" :prompt "no"))))
      (should (equal (agent-claude-cli-test--texts
                      (agent-claude-cli-transcript-history file 100000))
                     '(("user" "typed") ("user" "typed too")))))))

(ert-deftest agent-claude-cli-test-history-merges-tool-runs ()
  "A run of tool calls becomes one line of counted names."
  (let ((tool (lambda (name)
                (agent-claude-cli-test--assistant
                 (list :type "tool_use" :name name
                       :input (list :command "secret"))))))
    (agent-claude-cli-test--with-transcript
        (file (concat
               (funcall tool "Bash") (funcall tool "Read") (funcall tool "Bash")
               (agent-claude-cli-test--user
                (vector (list :type "tool_result" :content "out")))
               (funcall tool "Bash")
               (agent-claude-cli-test--assistant (list :type "text" :text "done"))
               (funcall tool "Edit")))
      (should (equal (agent-claude-cli-test--texts
                      (agent-claude-cli-transcript-history file 100000))
                     '(("tool" "Bash ×3, Read") ("assistant" "done")
                       ("tool" "Edit")))))))

(ert-deftest agent-claude-cli-test-history-survives-odd-lines ()
  "Lines that are not JSON, not UTF-8 or of an unknown shape are skipped."
  (agent-claude-cli-test--with-transcript
      (file (concat
             "not json\n"
             "[1,2]\n"
             "{\"type\":\"user\",\"message\":\"a string\"}\n"
             "{\"type\":\"user\",\"message\":{\"content\":7}}\n"
             "{\"type\":\"user\",\"message\":{\"content\":[7,null]}}\n"
             (agent-claude-cli-test--user "kept")))
    (should (equal (agent-claude-cli-test--texts
                    (agent-claude-cli-transcript-history file 100000))
                   '(("user" "kept")))))
  (let ((file (make-temp-file "agent-transcript-" nil ".jsonl")))
    (unwind-protect
        (let ((coding-system-for-write 'no-conversion))
          (write-region
           (concat "{\"type\":\"user\",\"message\":{\"content\":\"bad \xff\"}}\n"
                   (encode-coding-string (agent-claude-cli-test--user "kept")
                                         'utf-8))
           nil file nil 'silent)
          (should (equal (agent-claude-cli-test--texts
                          (agent-claude-cli-transcript-history file 100000))
                         '(("user" "kept")))))
      (delete-file file))))

(ert-deftest agent-claude-cli-test-history-window-starts-mid-line ()
  "A line the window cuts is left out, and `:before' finds it next time."
  (let* ((first (agent-claude-cli-test--user "first"))
         (second (agent-claude-cli-test--user "second")))
    (agent-claude-cli-test--with-transcript (file (concat first second))
      (let ((history (agent-claude-cli-transcript-history
                      file (+ (length second) 5))))
        (should (equal (agent-claude-cli-test--texts history)
                       '(("user" "second"))))
        (should (= (plist-get history :before) (length first)))
        (should (= (plist-get history :after)
                   (+ (length first) (length second))))
        (should (= (plist-get history :size)
                   (+ (length first) (length second))))))))

(ert-deftest agent-claude-cli-test-history-window-cuts-multibyte-text ()
  "No window size breaks a multibyte character or loses a message."
  (let* ((texts '("ñandú 🙂 uno" "日本語のテキスト" "ñandú 🙂 tres" "cuatro é"))
         (content (mapconcat #'agent-claude-cli-test--user texts ""))
         (byte-size (string-bytes content)))
    (agent-claude-cli-test--with-transcript (file content)
      (dolist (window (number-sequence 150 (+ byte-size 1) 7))
        (let ((before nil) (seen nil) (steps 0))
          (while (not (eql before 0))
            (let ((history (agent-claude-cli-transcript-history
                            file window before)))
              (setq seen (append (mapcar #'cadr
                                         (agent-claude-cli-test--texts history))
                                 seen)
                    before (plist-get history :before)
                    steps (1+ steps))
              (should (< steps 100))))
          (should (equal seen texts)))))))

(ert-deftest agent-claude-cli-test-history-ignores-line-being-written ()
  "An unterminated last line is left out and `:after' stops before it."
  (let ((line (agent-claude-cli-test--user "whole")))
    (agent-claude-cli-test--with-transcript
        (file (concat line "{\"type\":\"user\",\"mess"))
      (let ((history (agent-claude-cli-transcript-history file 100000)))
        (should (equal (agent-claude-cli-test--texts history)
                       '(("user" "whole"))))
        (should (= (plist-get history :after) (length line)))))))

(ert-deftest agent-claude-cli-test-history-line-longer-than-window ()
  "A line longer than the window is skipped and the walk still terminates."
  (let* ((old (agent-claude-cli-test--user "old"))
         (huge (agent-claude-cli-test--user (make-string 5000 ?x)))
         (new (agent-claude-cli-test--user "new"))
         (seen nil) (before nil) (steps 0))
    (agent-claude-cli-test--with-transcript (file (concat old huge new))
      (while (not (eql before 0))
        (let ((history (agent-claude-cli-transcript-history file 1000 before)))
          (when before
            (should (< (plist-get history :before) before)))
          (setq seen (append (mapcar #'cadr
                                     (agent-claude-cli-test--texts history))
                             seen)
                before (plist-get history :before)
                steps (1+ steps))
          (should (< steps 100))))
      (should (equal seen '("old" "new"))))))

(ert-deftest agent-claude-cli-test-history-reads-only-its-window ()
  "However long the transcript, only the requested bytes are read."
  (let ((reads nil)
        (original (symbol-function 'insert-file-contents-literally)))
    (agent-claude-cli-test--with-transcript
        (file (mapconcat #'agent-claude-cli-test--user
                         (make-list 2000 "some line of text") ""))
      (cl-letf (((symbol-function 'insert-file-contents-literally)
                 (lambda (filename &optional visit beg end replace)
                   (push (cons beg end) reads)
                   (funcall original filename visit beg end replace))))
        (let ((history (agent-claude-cli-transcript-history file 1000)))
          (should (> (plist-get history :before) 0))
          (should (plist-get history :messages))
          (should (= (length reads) 1))
          (should (= (- (cdar reads) (caar reads)) 1000))
          (should (= (cdar reads) (plist-get history :size))))))))

(ert-deftest agent-claude-cli-test-history-reads-what-follows ()
  "AFTER returns only newer lines, and flags a gap when too far behind."
  (let* ((old (agent-claude-cli-test--user "old"))
         (new (agent-claude-cli-test--user "new")))
    (agent-claude-cli-test--with-transcript (file (concat old new))
      (let ((history (agent-claude-cli-transcript-history
                      file 100000 nil (length old))))
        (should (equal (agent-claude-cli-test--texts history)
                       '(("user" "new"))))
        (should-not (plist-get history :gap))
        (should (= (plist-get history :after) (+ (length old) (length new)))))
      (let ((history (agent-claude-cli-transcript-history
                      file 100000 nil (+ (length old) (length new)))))
        (should-not (plist-get history :messages))
        (should-not (plist-get history :gap)))
      (let ((history (agent-claude-cli-transcript-history
                      file (+ (length new) 2) nil 0)))
        (should (equal (agent-claude-cli-test--texts history)
                       '(("user" "new"))))
        (should (plist-get history :gap))
        (should (= (plist-get history :before) (length old)))))))

(ert-deftest agent-claude-cli-test-history-follows-symlink ()
  "A symlinked transcript is measured and read through its target."
  (agent-claude-cli-test--with-transcript
      (file (agent-claude-cli-test--user "through the link"))
    (let ((link (concat file ".link.jsonl")))
      (unwind-protect
          (progn
            (make-symbolic-link file link)
            (should (equal (agent-claude-cli-test--texts
                            (agent-claude-cli-transcript-history link 100000))
                           '(("user" "through the link")))))
        (delete-file link)))))

(ert-deftest agent-claude-cli-test-session-file-under-given-directory ()
  "The projects directory can be named, as each account has its own."
  (let* ((root (make-temp-file "agent-projects-" t))
         (project (expand-file-name "-some-project" root))
         (id "12345678-aaaa-bbbb-cccc-1234567890ab"))
    (unwind-protect
        (progn
          (make-directory project)
          (with-temp-file (expand-file-name (concat id ".jsonl") project)
            (insert "{}\n"))
          (should (equal (agent-claude-cli--session-file id root)
                         (expand-file-name (concat id ".jsonl") project)))
          (let ((agent-claude-cli-projects-directory "/nonexistent/"))
            (should (agent-claude-cli--session-file id root))
            (should-not (agent-claude-cli--session-file id))))
      (delete-directory root t))))

;;;; Sessions continued elsewhere

(defconst agent-claude-cli-test--stub
  "{\"type\":\"ai-title\",\"aiTitle\":\"T\",\"sessionId\":\"stub\"}
{\"type\":\"agent-name\",\"agentName\":\"T\",\"sessionId\":\"stub\"}
"
  "A transcript holding only title records.")

(defun agent-claude-cli-test--continued-in (id)
  "Return a conversation transcript that continued in session ID."
  (format "{\"type\":\"user\",\"cwd\":\"/p\"}
{\"type\":\"continued-in\",\"continuedInSessionId\":\"%s\"}
" id))

(defmacro agent-claude-cli-test--with-transcripts (transcripts &rest body)
  "Run BODY with TRANSCRIPTS, an alist of id to text, in one project."
  (declare (indent 1))
  `(let* ((root (make-temp-file "agent-projects-" t))
          (agent-claude-cli-projects-directory (file-name-as-directory root))
          (project (expand-file-name "-p/" root)))
     (unwind-protect
         (progn
           (make-directory project)
           (pcase-dolist (`(,id . ,text) ,transcripts)
             (with-temp-file (expand-file-name (concat id ".jsonl") project)
               (insert text)))
           ,@body)
       (delete-directory root t))))

(ert-deftest agent-claude-cli-test-conversation-session-follows-empty-successor ()
  "A session with only titles leads to the session that continued in it."
  (agent-claude-cli-test--with-transcripts
      `(("stub" . ,agent-claude-cli-test--stub)
        ("real" . ,(agent-claude-cli-test--continued-in "stub")))
    (should (equal (agent-claude-cli-conversation-session "stub") "real"))))

(ert-deftest agent-claude-cli-test-conversation-session-follows-a-chain ()
  "Several empty successors in a row all lead to the conversation."
  (agent-claude-cli-test--with-transcripts
      `(("late" . ,agent-claude-cli-test--stub)
        ("early" . ,(concat agent-claude-cli-test--stub
                            "{\"type\":\"continued-in\",\"continuedInSessionId\":\"late\"}\n"))
        ("real" . ,(agent-claude-cli-test--continued-in "early")))
    (should (equal (agent-claude-cli-conversation-session "late") "real"))))

(ert-deftest agent-claude-cli-test-conversation-session-keeps-a-conversation ()
  "A successor that ran a turn is the conversation itself."
  (agent-claude-cli-test--with-transcripts
      `(("next" . ,(concat agent-claude-cli-test--stub
                           "{\"type\":\"assistant\"}\n"))
        ("real" . ,(agent-claude-cli-test--continued-in "next")))
    (should (equal (agent-claude-cli-conversation-session "next") "next"))))

(ert-deftest agent-claude-cli-test-conversation-session-keeps-unknown-cases ()
  "No transcript, no origin and an unparsable line all keep the given id."
  (agent-claude-cli-test--with-transcripts
      `(("alone" . ,agent-claude-cli-test--stub)
        ("broken" . "not json\n")
        ("real" . ,(agent-claude-cli-test--continued-in "broken")))
    (should (equal (agent-claude-cli-conversation-session "absent") "absent"))
    (should (equal (agent-claude-cli-conversation-session "alone") "alone"))
    (should (equal (agent-claude-cli-conversation-session "broken") "broken"))))

(ert-deftest agent-claude-cli-test-conversation-session-ignores-a-mention ()
  "A conversation quoting the record, escaped, is not the origin."
  (agent-claude-cli-test--with-transcripts
      `(("stub" . ,agent-claude-cli-test--stub)
        ("chat" . ,(concat "{\"type\":\"user\",\"text\":\"grep "
                           "\\\"continuedInSessionId\\\":\\\"stub\\\"\"}\n")))
    (should (equal (agent-claude-cli-conversation-session "stub") "stub"))))

(ert-deftest agent-claude-cli-test-conversation-session-survives-a-cycle ()
  "Two empty sessions naming each other do not loop."
  (agent-claude-cli-test--with-transcripts
      '(("a" . "{\"type\":\"continued-in\",\"continuedInSessionId\":\"b\"}\n")
        ("b" . "{\"type\":\"continued-in\",\"continuedInSessionId\":\"a\"}\n"))
    (should (member (agent-claude-cli-conversation-session "a") '("a" "b")))))

(ert-deftest agent-claude-cli-test-conversation-session-other-project ()
  "A session in another project is not the origin."
  (agent-claude-cli-test--with-transcripts
      `(("stub" . ,agent-claude-cli-test--stub))
    (make-directory (expand-file-name "-q/" root))
    (with-temp-file (expand-file-name "-q/real.jsonl" root)
      (insert (agent-claude-cli-test--continued-in "stub")))
    (should (equal (agent-claude-cli-conversation-session "stub") "stub"))))

;;;; Screen panel
;; The screens below follow real captures of Claude Code 2.1.318 under eat.

(defconst agent-claude-cli-test--rule (make-string 60 ?─))

(defun agent-claude-cli-test--screen (&rest lines)
  "Return a screen from LINES, where `rule' stands for a full-width rule."
  (mapconcat (lambda (line)
               (if (eq line 'rule) agent-claude-cli-test--rule line))
             lines "\n"))

(defun agent-claude-cli-test--panel-lines (screen)
  "Return the lines of SCREEN from where its panel starts."
  (nthcdr (plist-get (agent-claude-cli-screen-panel screen) :start)
          (split-string screen "\n")))

(ert-deftest agent-claude-cli-test-panel-idle-input-box ()
  "At rest the panel starts at the status line above the input box."
  (let ((screen (agent-claude-cli-test--screen
                 "⏺ The answer is here" "  and goes on." ""
                 "✻ Worked for 34s · done 17:34" "        "
                 'rule "❯ " 'rule "" "  ⏵⏵ auto mode on")))
    (should (equal (car (agent-claude-cli-test--panel-lines screen))
                   "✻ Worked for 34s · done 17:34"))
    (should-not (plist-get (agent-claude-cli-screen-panel screen) :dialog))
    (should-not (plist-get (agent-claude-cli-screen-panel screen) :block))))

(ert-deftest agent-claude-cli-test-panel-keeps-what-follows-the-box ()
  "The mode line and the agent list stay in the panel."
  (let ((lines (agent-claude-cli-test--panel-lines
                (agent-claude-cli-test--screen
                 "✻ Symbioting… (48s)" "  " 'rule "❯ " 'rule ""
                 "  ⏵⏵ auto mode on" "" "  ⏺ main"
                 "  ◯ general-purpose  Some task"))))
    (should (member "  ◯ general-purpose  Some task" lines))
    (should (member "❯ " lines))))

(ert-deftest agent-claude-cli-test-panel-input-box-variants ()
  "A bare prompt, a titled rule and multi-line input all count as the box."
  (dolist (screen (list
                   (agent-claude-cli-test--screen
                    "⏺ Text" "" "✻ Done" "" 'rule "❯" 'rule "  mode")
                   (agent-claude-cli-test--screen
                    "⏺ Text" "" "✻ Done" ""
                    (concat agent-claude-cli-test--rule " make-cup-of-tea ─")
                    "❯" 'rule "  mode")
                   (agent-claude-cli-test--screen
                    "⏺ Text" "" "✻ Done" ""
                    'rule "❯ first line" "  second line" 'rule "  mode")))
    (should-not (plist-get (agent-claude-cli-screen-panel screen) :dialog))
    (should (equal (car (agent-claude-cli-test--panel-lines screen)) "✻ Done"))))

(ert-deftest agent-claude-cli-test-panel-keeps-a-notice-with-options ()
  "A notice above the box that offers options stays in the panel."
  (let ((lines (agent-claude-cli-test--panel-lines
                (agent-claude-cli-test--screen
                 "⏺ Compacted" "" "✦ Heads up · Something new"
                 "  1: Learn more   2: Knew this   0: Dismiss" "   "
                 'rule "❯ " 'rule "  mode"))))
    (should (equal (car lines) "✦ Heads up · Something new"))
    (should (member "  1: Learn more   2: Knew this   0: Dismiss" lines))))

(ert-deftest agent-claude-cli-test-panel-keeps-notice-under-filled-blank ()
  "Right-aligned text filling the blank lines does not lose a notice."
  (let ((lines (agent-claude-cli-test--panel-lines
                (agent-claude-cli-test--screen
                 "⏺ Compacted while idle" "                     [-]"
                 "✦ Heads up · Something new" "  1: Learn more   0: Dismiss"
                 "            Restart to update"
                 'rule "❯" 'rule "  mode"))))
    (should (equal (car lines) "✦ Heads up · Something new"))
    (should (member "  1: Learn more   0: Dismiss" lines))))

(ert-deftest agent-claude-cli-test-panel-sees-status-past-effort-line ()
  "The right-aligned effort line does not hide the status line above it."
  (let ((screen (agent-claude-cli-test--screen
                 "  ⎿  Interrupted" "" "✻ Brewed for 1s" "" "" ""
                 "        ◐ medium · /effort" 'rule "❯" 'rule "  mode")))
    (should (equal (car (agent-claude-cli-test--panel-lines screen))
                   "✻ Brewed for 1s"))))

(ert-deftest agent-claude-cli-test-panel-marks-text-being-written ()
  "The message running up to the panel is offered while it is written."
  (let* ((screen (agent-claude-cli-test--screen
                  "❯ Write about tea" ""
                  "⏺ Tea asks for patience" "  and it suits the pace." ""
                  "  Its history runs longer." "  than most realize."
                  "        ◐ medium · /effort" 'rule "❯" 'rule "  mode"))
         (panel (agent-claude-cli-screen-panel screen)))
    (should (= (plist-get panel :block) 2))
    (should (> (plist-get panel :start) 2)))
  (let ((panel (agent-claude-cli-screen-panel
                (agent-claude-cli-test--screen
                 "⏺ Old" "" "✻ Done" "" "❯ New prompt" ""
                 "· Slithering…" "" 'rule "❯" 'rule "  mode"))))
    (should-not (plist-get panel :block))))

(ert-deftest agent-claude-cli-test-panel-bash-dialog-shows-whole-dialog ()
  "A permission dialog appears whole, with its inner rules and options."
  (let* ((screen (agent-claude-cli-test--screen
                  "⏺ Earlier text" "" "❯ Run it" ""
                  "  Creating empty file" "  ⎿  $ touch x" ""
                  'rule " Bash command" " Create empty file"
                  (make-string 60 ?╌) " touch x" (make-string 60 ?╌)
                  " Do you want to proceed?" " ❯ 1. Yes" "   2. No" ""
                  " Esc to cancel · Tab to amend"))
         (panel (agent-claude-cli-screen-panel screen))
         (lines (agent-claude-cli-test--panel-lines screen)))
    (should (plist-get panel :dialog))
    (should (member " Bash command" lines))
    (should (member " ❯ 1. Yes" lines))
    (should (equal (car lines) agent-claude-cli-test--rule))
    (should-not (member "⏺ Earlier text" lines))
    (should-not (member "❯ Run it" lines))))

(ert-deftest agent-claude-cli-test-panel-unnumbered-margin-option ()
  "An option at the margin that reads like a past prompt cuts nothing off."
  (let* ((screen (agent-claude-cli-test--screen
                  "✻ Sautéed" "" "❯ Ask me" 'rule " ☐ Drink" ""
                  "Do you prefer tea or coffee?" "" "❯ Tea" "  Coffee"
                  'rule "  Chat about this" "" "Enter to select"))
         (lines (agent-claude-cli-test--panel-lines screen)))
    (should (equal (car lines) agent-claude-cli-test--rule))
    (should (member "Do you prefer tea or coffee?" lines))
    (should-not (member "❯ Ask me" lines))))

(ert-deftest agent-claude-cli-test-panel-dialog-taller-than-screen ()
  "With its opening rule gone, a dialog's inner rule does not cut it."
  (let ((screen (agent-claude-cli-test--screen
                 "Do you prefer tea or coffee?" "❯ 1. Tea" "  2. Coffee"
                 'rule "  3. Chat about this" "Enter to select")))
    (should (= (plist-get (agent-claude-cli-screen-panel screen) :start) 0))))

(ert-deftest agent-claude-cli-test-panel-dialog-with-no-rule-below-the-mark ()
  "A screen with a mark but no rule below it shows from the mark."
  (let ((screen (agent-claude-cli-test--screen
                 'rule "old" "⏺ Something" "  and then" " an unknown prompt")))
    (should (= (plist-get (agent-claude-cli-screen-panel screen) :start) 2))))

(ert-deftest agent-claude-cli-test-panel-question-dialog-with-inner-rule ()
  "An option at the margin and a rule inside the dialog do not cut it."
  (let* ((screen (agent-claude-cli-test--screen
                  "✻ Sautéed" "" "❯ Ask me" "  please." 'rule " ☐ Drink" ""
                  "Do you prefer tea or coffee?" "" "❯ 1. Tea" "  2. Coffee"
                  'rule "  4. Chat about this" ""
                  "Enter to select · Esc to cancel"))
         (lines (agent-claude-cli-test--panel-lines screen)))
    (should (plist-get (agent-claude-cli-screen-panel screen) :dialog))
    (should (member "Do you prefer tea or coffee?" lines))
    (should (member " ☐ Drink" lines))
    (should (member "❯ 1. Tea" lines))
    (should-not (member "  please." lines))))

(ert-deftest agent-claude-cli-test-panel-picker-with-block-rule ()
  "A picker opening with an upper-block rule and effort text is a dialog."
  (let* ((screen (agent-claude-cli-test--screen
                  "⏺ Declined" "  ⎿  Tea or coffee?" "" "✻ Sautéed for 1s"
                  (concat (make-string 50 ?▔) " ◐ medium · /effort")
                  "   Select model" "   ❯ 5.  Haiku" "   Esc to cancel"))
         (lines (agent-claude-cli-test--panel-lines screen)))
    (should (plist-get (agent-claude-cli-screen-panel screen) :dialog))
    (should (member "   Select model" lines))
    (should-not (member "✻ Sautéed for 1s" lines))))

(ert-deftest agent-claude-cli-test-panel-unrecognized-shows-everything ()
  "With nothing to go by the panel is the whole screen."
  (dolist (screen '("just some text\nand more" "" "⏺ No rules here\nat all"))
    (let ((panel (agent-claude-cli-screen-panel screen)))
      (should (= (plist-get panel :start) 0))
      (should (plist-get panel :dialog))))
  (let ((screen (agent-claude-cli-test--screen
                 " a dialog taller" " than the screen" 'rule " ❯ 1. Yes")))
    (should (= (plist-get (agent-claude-cli-screen-panel screen) :start) 0))))

(ert-deftest agent-claude-cli-test-panel-past-prompt-is-not-the-box ()
  "A rule followed by a past prompt, with a space, is not an input box."
  (let ((screen (agent-claude-cli-test--screen
                 'rule "❯ Earlier prompt" 'rule " ❯ 1. Yes" " Esc to cancel")))
    (should (plist-get (agent-claude-cli-screen-panel screen) :dialog))))

;;;; Screen state

(defun agent-claude-cli-test--state (&rest lines)
  "Return the screen state of a screen made from LINES."
  (agent-claude-cli-screen-state (apply #'agent-claude-cli-test--screen lines)))

(ert-deftest agent-claude-cli-test-state-spinner-and-mode ()
  "A running spinner and the mode line become plain text."
  (let ((state (agent-claude-cli-test--state
                "⏺ Earlier" "" "✶ Forging… (11m 33s · ↓ 2.9k tokens · esc to interrupt)"
                "  ⎿  Tip: Create skills" "" 'rule "❯ " 'rule ""
                "  ⏵⏵ auto mode on (shift+tab to cycle) · 5 shells · ← 1 agent")))
    (should (equal (plist-get state :status) "Forging… 11m 33s · 2.9k tokens"))
    (should (plist-get state :running))
    (should (equal (plist-get state :mode) "auto mode on · 5 shells · 1 agent"))
    (should-not (plist-get state :card))))

(ert-deftest agent-claude-cli-test-state-spinner-variants ()
  "Spinners without details, or with the ended turn's glyph, still count."
  (should (equal (plist-get (agent-claude-cli-test--state
                             "· Slithering…" "   ◐ medium" 'rule "❯" 'rule "  m")
                            :status)
                 "Slithering…"))
  (should (equal (plist-get (agent-claude-cli-test--state
                             "✻ Symbioting… (48s · ↓ 2.1k tokens)" "  "
                             'rule "❯" 'rule "  m")
                            :status)
                 "Symbioting… 48s · 2.1k tokens")))

(ert-deftest agent-claude-cli-test-state-idle-has-no-status ()
  "An ended turn is no status, and hints leave the mode line."
  (let ((state (agent-claude-cli-test--state
                "⏺ Answer" "" "✻ Worked for 34s · done 17:34" ""
                'rule "❯" 'rule
                "  ⏸ manual mode on · ? for shortcuts · ← for agents     ◐ medium · /effort")))
    (should-not (plist-get state :status))
    (should-not (plist-get state :running))
    (should-not (plist-get state :writing))
    (should (equal (plist-get state :mode) "manual mode on"))))

(ert-deftest agent-claude-cli-test-state-mode-absent ()
  "A screen with nothing below the box has no mode."
  (should-not (plist-get (agent-claude-cli-test--state "✻ Done" 'rule "❯" 'rule)
                         :mode)))

(ert-deftest agent-claude-cli-test-state-text-being-written ()
  "A message above the box is unwrapped, without the effort line."
  (let ((state (agent-claude-cli-test--state
                "❯ Write about tea" ""
                "⏺ Tea asks for patience, and it"
                "  suits the pace." ""
                "  - a list"
                "  - of things" ""
                "  Its history runs" "  longer."
                "                         ◐ medium · /effort"
                'rule "❯" 'rule "  m")))
    (should (equal (plist-get state :writing)
                   (concat "Tea asks for patience, and it suits the pace.\n\n"
                           "- a list\n- of things\n\nIts history runs longer.")))))

(ert-deftest agent-claude-cli-test-state-stops-writing-at-spinner ()
  "The spinner and what follows are not part of the message."
  (should (equal (plist-get (agent-claude-cli-test--state
                             "⏺ Short text" "" "✶ Forging… (1s)" "  ⎿  Tip: x"
                             'rule "❯" 'rule "  m")
                            :writing)
                 "Short text")))

(ert-deftest agent-claude-cli-test-state-tool-call-is-not-writing ()
  "A tool call on screen is left to the spinner."
  (dolist (lines '(("⏺ Bash(touch x)" "  ⎿  Running…")
                   ("⏺ User declined" "  ⎿  · Tea?")))
    (should-not (plist-get (apply #'agent-claude-cli-test--state
                                  (append lines '("" "✶ Forging… (1s)" "" rule "❯" rule)))
                           :writing))))

(ert-deftest agent-claude-cli-test-state-dialog-card ()
  "A dialog becomes a card with the digits of its options."
  (let* ((state (agent-claude-cli-test--state
                 "⏺ Earlier" "" 'rule " Write a.txt"
                 (make-string 60 ?╌) "  1 1. Line one" "  9 9. Line nine"
                 (make-string 60 ?╌) " Do you want to create a.txt?"
                 " ❯ 1. Yes" "   2. Yes, and allow" "   3. No" ""
                 " Esc to cancel"))
         (card (plist-get state :card)))
    (should (string-search " Write a.txt" card))
    (should (string-search "Esc to cancel" card))
    (should-not (string-search "Earlier" card))
    (should (equal (plist-get state :options) '("1" "2" "3")))
    (should-not (plist-get state :status))))

(ert-deftest agent-claude-cli-test-state-dialog-takes-keys ()
  "A dialog in place of the input box says so; one with the box does not."
  (should (plist-get (agent-claude-cli-test--state
                      "⏺ Earlier" "" 'rule " Do you want to create a.txt?"
                      " ❯ 1. Yes" "   2. No" "" " Esc to cancel")
                     :dialog))
  (should (plist-get (agent-claude-cli-test--state
                      "✻ Sautéed" "" "❯ Ask me" 'rule " ☐ Drink" ""
                      "Do you prefer tea or coffee?" "" "❯ Tea" "  Coffee"
                      'rule "  Chat about this" "" "Enter to select")
                     :dialog))
  (should-not (plist-get (agent-claude-cli-test--state
                          "⏺ Answer" "" 'rule "❯" 'rule "  m")
                         :dialog))
  (should-not (plist-get (agent-claude-cli-test--state
                          "✻ Done" "" "✦ Heads up · A notice" "  1: Learn more   0: Dismiss"
                          'rule "❯" 'rule "  m")
                         :dialog)))

(ert-deftest agent-claude-cli-test-state-unrecognized-is-no-dialog ()
  "A screen with neither an input box nor a dialog's marks is not a dialog."
  (should-not (plist-get (agent-claude-cli-screen-state "") :dialog))
  (should-not (plist-get (agent-claude-cli-screen-state "something\nunknown")
                         :dialog)))

(ert-deftest agent-claude-cli-test-state-picker-options ()
  "A scrolled picker offers only the options on screen."
  (should (equal (plist-get (agent-claude-cli-test--state
                             "✻ Done" (make-string 60 ?▔) "   Select model"
                             "   ↑ 3.  Fable" "     4.  Sonnet" "   ❯ 5.  Haiku"
                             "      … +8 models" "   Esc to cancel")
                            :options)
                 '("3" "4" "5"))))

(ert-deftest agent-claude-cli-test-state-unrecognized-is-a-card ()
  "A screen with nothing recognized is shown whole on a card."
  (let ((state (agent-claude-cli-screen-state "something\nunknown")))
    (should (equal (plist-get state :card) "something\nunknown"))
    (should-not (plist-get state :options))))

(ert-deftest agent-claude-cli-test-state-notice-with-options ()
  "A notice taking input is a card; without options it is dropped."
  (let ((state (agent-claude-cli-test--state
                "⏺ Compacted" "                [-]" "✦ Heads up · Something new"
                "  1: Learn more   2: Knew this   0: Dismiss" "   Restart"
                'rule "❯" 'rule "  m")))
    (should (string-search "Heads up" (plist-get state :card)))
    (should (equal (plist-get state :options) '("1" "2" "0"))))
  (let ((state (agent-claude-cli-test--state
                "✦ Heads up · Something new" "  more of it" ""
                'rule "❯" 'rule "  m")))
    (should-not (plist-get state :card))
    (should-not (plist-get state :status))))

(ert-deftest agent-claude-cli-test-state-done-time-is-not-an-option ()
  "A clock in the status line does not make a notice."
  (should-not (plist-get (agent-claude-cli-test--state
                          "✻ Worked for 3s · done 19:37" "" 'rule "❯" 'rule "  m")
                         :card)))

(ert-deftest agent-claude-cli-test-plain-text-drops-unknown-glyphs ()
  "Status text holds no glyph a phone font may lack."
  (should (equal (agent-claude-cli--screen-plain "⏵⏵ auto ◐ ↓ 2k · ñandú…")
                 "auto 2k · ñandú…")))

;;;; Claude JSON

(ert-deftest agent-claude-cli-test-read-claude-json-retries-mid-write ()
  "Recover from a parse failure caused by reading during a rewrite.
The first read sees a truncated file; the retry, after the delay during
which the writer finishes, sees valid JSON.  No warning is emitted."
  (let ((path (make-temp-file "claude-json" nil ".json" "{\"a\": "))
        (agent-claude-cli--warned nil))
    (unwind-protect
        (cl-letf (((symbol-function 'sleep-for)
                   (lambda (&rest _)
                     (with-temp-file path (insert "{\"a\": 1}")))))
          (let ((result (agent-claude-cli-read-claude-json path)))
            (should (hash-table-p result))
            (should (= (gethash "a" result) 1))
            (should (null agent-claude-cli--warned))))
      (delete-file path))))

(ert-deftest agent-claude-cli-test-read-claude-json-invalid-warns-once ()
  "A persistently invalid file warns once, with a snapshot, and returns nil."
  (let ((path (make-temp-file "claude-json" nil ".json" "{\"a\": "))
        (agent-claude-cli--warned nil)
        (warnings nil))
    (unwind-protect
        (cl-letf (((symbol-function 'display-warning)
                   (lambda (&rest args) (push args warnings)))
                  ((symbol-function 'sleep-for) #'ignore)
                  ((symbol-function 'agent-claude-cli--snapshot-invalid-json)
                   (lambda (_) "/tmp/snapshot.json")))
          (should (null (agent-claude-cli-read-claude-json path)))
          (should (= (length warnings) 1))
          (should (string-match-p "snapshot" (nth 1 (car warnings)))))
      (delete-file path))))

(ert-deftest agent-claude-cli-test-read-claude-json-skips-retries-after-warned ()
  "Once a persistent failure was warned about, reads fail fast.
The retry delays must not be re-paid on every read of a file already
known to be corrupt."
  (let ((path (make-temp-file "claude-json" nil ".json" "{\"a\": "))
        (agent-claude-cli--warned nil)
        (sleeps 0))
    (unwind-protect
        (cl-letf (((symbol-function 'display-warning) #'ignore)
                  ((symbol-function 'sleep-for)
                   (lambda (&rest _) (setq sleeps (1+ sleeps))))
                  ((symbol-function 'agent-claude-cli--snapshot-invalid-json)
                   (lambda (_) "/tmp/snapshot.json")))
          (should (null (agent-claude-cli-read-claude-json path)))
          (let ((first-pass-sleeps sleeps))
            (should (> first-pass-sleeps 0))
            (should (null (agent-claude-cli-read-claude-json path)))
            (should (= sleeps first-pass-sleeps))))
      (delete-file path))))

(ert-deftest agent-claude-cli-test-write-claude-json-round-trip ()
  "Write JSON atomically and read it back, leaving no temporary file."
  (let* ((dir (make-temp-file "claude-json-dir" t))
         (path (expand-file-name ".claude.json" dir))
         (data (make-hash-table :test #'equal)))
    (puthash "a" 1 data)
    (unwind-protect
        (progn
          (agent-claude-cli-write-claude-json path data)
          (let ((read-back (agent-claude-cli-read-claude-json path)))
            (should (hash-table-p read-back))
            (should (= (gethash "a" read-back) 1)))
          (should (equal (directory-files dir nil "claude")
                         '(".claude.json"))))
      (delete-directory dir t))))

;;;; Transcript JSONL

(ert-deftest agent-claude-cli-test-read-session-header-round-trip ()
  "Parse session and fork identifiers from a transcript's first line."
  (let ((file (make-temp-file
               "agent-claude-cli-test" nil ".jsonl"
               (concat "{\"sessionId\":\"s1\",\"forkedFrom\":"
                       "{\"sessionId\":\"s0\",\"messageUuid\":\"u0\"}}\n"))))
    (unwind-protect
        (let ((header (agent-claude-cli-read-session-header file)))
          (should (equal (plist-get header :session-id) "s1"))
          (should (equal (plist-get header :forked-from) "s0"))
          (should (equal (plist-get header :fork-uuid) "u0"))
          (should (equal (plist-get header :file-path) file)))
      (delete-file file))))

(ert-deftest agent-claude-cli-test-read-session-header-long-first-line ()
  "Parse a first line longer than one read chunk, ending in multibyte text."
  (let* ((padding (make-string agent-util--first-line-chunk-size ?x))
         (file (make-temp-file
                "agent-claude-cli-test" nil ".jsonl"
                (concat "{\"type\":\"queue-operation\",\"content\":\""
                        padding "é\",\"sessionId\":\"s1\"}\n"
                        "{\"type\":\"user\"}\n"))))
    (unwind-protect
        (should (equal (plist-get
                        (agent-claude-cli-read-session-header file)
                        :session-id)
                       "s1"))
      (delete-file file))))

;;;; Background sessions

(defconst agent-claude-cli-test--sessions-json
  "[{\"pid\":1,\"id\":\"420819cf\",\"kind\":\"background\",
     \"sessionId\":\"420819cf-9776\"},
    {\"pid\":2,\"kind\":\"interactive\",\"sessionId\":\"11e3c9fd-17e5\"}]"
  "Output of `claude agents --json' with one background session.")

(ert-deftest agent-claude-cli-test-background-attach-id-matches-session ()
  "Return the short id of a background session with the given full id."
  (should (equal (agent-claude-cli-background-attach-id
                  agent-claude-cli-test--sessions-json "420819cf-9776")
                 "420819cf")))

(ert-deftest agent-claude-cli-test-background-attach-id-ignores-interactive ()
  "Return nil for an interactive or unknown session."
  (should-not (agent-claude-cli-background-attach-id
               agent-claude-cli-test--sessions-json "11e3c9fd-17e5"))
  (should-not (agent-claude-cli-background-attach-id
               agent-claude-cli-test--sessions-json "absent")))

(ert-deftest agent-claude-cli-test-background-attach-id-warns-on-bad-json ()
  "Warn once and return nil when the output is not JSON."
  (let ((agent-claude-cli--warned nil)
        (warnings nil))
    (cl-letf (((symbol-function 'display-warning)
               (lambda (&rest args) (push args warnings))))
      (should-not (agent-claude-cli-background-attach-id "not json" "x")))
    (should (= (length warnings) 1))))

(provide 'agent-claude-cli-test)
;;; agent-claude-cli-test.el ends here
