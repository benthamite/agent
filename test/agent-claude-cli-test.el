;;; agent-claude-cli-test.el --- Tests for agent-claude-cli -*- lexical-binding: t -*-

;;; Commentary:

;; Tests for the Claude Code CLI conventions in agent-claude-cli.el.

;;; Code:

(require 'ert)
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

(provide 'agent-claude-cli-test)
;;; agent-claude-cli-test.el ends here
