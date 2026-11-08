;;; agent-report-test.el --- Tests for agent-report -*- lexical-binding: t -*-

;; Tests for turning a bug report or feature idea into a session.

;;; Code:

(require 'ert)
(require 'agent-test-helper
         (expand-file-name "agent-test-helper"
                           (file-name-directory (or load-file-name buffer-file-name))))
(require 'agent-report)

(ert-deftest agent-report-test-prompt-fills-placeholders ()
  "The prompt carries the report and the checkout paths."
  (let ((prompt (agent-report-prompt "The list flickers")))
    (should (string-search "The list flickers" prompt))
    (should (string-search (abbreviate-file-name agent-report--package-directory)
                           prompt))
    (should (string-search "gh pr create" prompt))
    (should-not (string-search "{{" prompt))))

(ert-deftest agent-report-test-prompt-keeps-placeholders-in-report ()
  "A report quoting a placeholder keeps it as written."
  (should (string-search "see {{AGENT_DIR}}"
                         (agent-report-prompt "see {{AGENT_DIR}}"))))

(ert-deftest agent-report-test-submit-starts-session-in-checkout ()
  "Submitting starts a session in the package checkout with the prompt."
  (let ((agent-backends (list (cons 'codex nil)))
        started)
    (cl-letf (((symbol-function 'agent--free-instance-name)
               (lambda (_backend _directory prefix) (concat prefix "-1")))
              ((symbol-function 'agent-start-session)
               (lambda (session &rest options)
                 (setq started (list session options))
                 'buffer)))
      (should (eq (agent-report-submit "Add a button" 'codex) 'buffer))
      (let ((session (car started)))
        (should (eq (agent-session-backend session) 'codex))
        (should (equal (agent-session-directory session)
                       (abbreviate-file-name agent-report--package-directory)))
        (should (equal (agent-session-instance session) "report-1"))
        (should (string-search "Add a button"
                               (plist-get (cadr started) :initial-prompt)))))))

(ert-deftest agent-report-test-submit-refuses-unknown-backend ()
  "Submitting to a backend that is not registered starts nothing."
  (let ((agent-backends nil))
    (should-error (agent-report-submit "x" 'codex) :type 'user-error)))

(ert-deftest agent-report-test-send-refuses-empty-description ()
  "Sending an empty description is refused."
  (with-temp-buffer
    (insert "  \n")
    (should-error (agent-report-send) :type 'user-error)))

(provide 'agent-report-test)

;;; agent-report-test.el ends here
