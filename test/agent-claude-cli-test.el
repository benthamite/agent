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
