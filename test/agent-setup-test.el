;;; agent-setup-test.el --- Tests for agent-setup -*- lexical-binding: t -*-

;; Tests for the first-run checks in agent-setup.el.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'agent-setup)
(require 'agent-claude)

(defmacro agent-setup-test--with-settings (var json &rest body)
  "Bind VAR to a temporary Claude settings file holding JSON and run BODY.
A nil JSON leaves the file absent."
  (declare (indent 2))
  `(let* ((dir (make-temp-file "agent-setup-test" t))
          (,var (expand-file-name "settings.json" dir)))
     (unwind-protect
         (progn
           (when ,json (with-temp-file ,var (insert ,json)))
           ,@body)
       (delete-directory dir t))))

(ert-deftest agent-setup-test-missing-program-has-hint ()
  "A missing program is reported with its install instructions."
  (let ((check (agent-setup--check-program 'codex "agent-setup-no-such-program")))
    (should-not (plist-get check :ok))
    (should (string-match-p "npm install" (plist-get check :hint)))))

(ert-deftest agent-setup-test-found-program ()
  "A program on PATH is reported as found."
  (should (plist-get (agent-setup--check-program 'emacsclient "sh") :ok)))

(ert-deftest agent-setup-test-installs-hooks-into-empty-settings ()
  "Accepting the prompt installs agent's status line into new settings."
  (agent-setup-test--with-settings file nil
    (let ((agent-claude-settings-file file))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
        (should (plist-get (agent-setup--check-claude-settings) :ok)))
      (should (eq (agent-setup--claude-statusline-state file) 'agent)))))

(ert-deftest agent-setup-test-declining-leaves-settings-alone ()
  "Declining the prompt writes nothing."
  (agent-setup-test--with-settings file nil
    (let ((agent-claude-settings-file file))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
        (should-not (plist-get (agent-setup--check-claude-settings) :ok)))
      (should-not (file-exists-p file)))))

(ert-deftest agent-setup-test-refreshes-without-asking ()
  "Settings already carrying agent's status line are refreshed silently."
  (agent-setup-test--with-settings file
      "{\"statusLine\": {\"type\": \"command\", \"command\": \"/old/claude-code-statusline.sh\"}}"
    (let ((agent-claude-settings-file file))
      (cl-letf (((symbol-function 'y-or-n-p)
                 (lambda (&rest _) (error "Should not ask"))))
        (should (plist-get (agent-setup--check-claude-settings) :ok))))))

(ert-deftest agent-setup-test-keeps-a-foreign-status-line ()
  "A status line agent does not own is kept and reported."
  (agent-setup-test--with-settings file
      "{\"statusLine\": {\"type\": \"command\", \"command\": \"my-line\"}}"
    (let ((agent-claude-settings-file file))
      (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
        (let ((check (agent-setup--check-claude-settings)))
          (should-not (plist-get check :ok))
          (should (string-match-p "another status line"
                                  (plist-get check :label)))))
      (should (eq (agent-setup--claude-statusline-state file) 'other)))))

(ert-deftest agent-setup-test-report-summarizes ()
  "The report marks each check and says whether anything is left."
  (save-window-excursion
    (with-current-buffer
        (agent-setup--report (list (list :ok t :label "one")
                                   (list :ok nil :label "two" :hint "fix it")))
      (should (string-match-p "✓ one" (buffer-string)))
      (should (string-match-p "✗ two\n      fix it" (buffer-string)))
      (should (string-match-p "Fix the items" (buffer-string))))))

(provide 'agent-setup-test)
;;; agent-setup-test.el ends here
