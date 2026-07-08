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

(provide 'agent-claude-cli-test)
;;; agent-claude-cli-test.el ends here
