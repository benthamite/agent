;;; agent-setup-test.el --- Tests for agent-setup -*- lexical-binding: t -*-

;; Tests for the first-run checks in agent-setup.el.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'agent-setup)
(require 'agent-claude)

(defmacro agent-setup-test--with-settings (var json &rest body)
  "Bind VAR to a temporary Claude settings file holding JSON and run BODY.
A nil JSON leaves the file absent.  Session settings go to a temporary
directory as well."
  (declare (indent 2))
  `(let* ((dir (make-temp-file "agent-setup-test" t))
          (,var (expand-file-name "settings.json" dir))
          (agent-claude-settings-file ,var)
          (agent-claude-session-settings-directory
           (expand-file-name "session/" dir)))
     (unwind-protect
         (progn
           (when ,json (with-temp-file ,var (insert ,json)))
           ,@body)
       (delete-directory dir t))))

(defun agent-setup-test--contents (file)
  "Return the contents of FILE, or nil when it does not exist."
  (when (file-exists-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (buffer-string))))

(defconst agent-setup-test--global-with-agent-entries
  (concat "{\"statusLine\": {\"type\": \"command\", \"command\": "
          "\"/old/agent/etc/claude-code-statusline.sh\"},"
          " \"hooks\": {\"Stop\": [{\"hooks\": ["
          "{\"type\": \"command\", \"command\": \"/old/agent/hooks/record-background-tasks.sh\"}]},"
          " {\"hooks\": [{\"type\": \"command\", \"command\": \"my-own-hook\"}]}]}}")
  "Global settings holding two agent entries and one of the user's.")

(ert-deftest agent-setup-test-missing-program-has-hint ()
  "A missing program is reported with its install instructions."
  (let ((check (agent-setup--check-program 'codex "agent-setup-no-such-program")))
    (should-not (plist-get check :ok))
    (should (string-match-p "npm install" (plist-get check :hint)))))

(ert-deftest agent-setup-test-found-program ()
  "A program on PATH is reported as found."
  (should (plist-get (agent-setup--check-program 'emacsclient "sh") :ok)))

(ert-deftest agent-setup-test-session-settings-written ()
  "The session settings check writes the file it reports."
  (agent-setup-test--with-settings file nil
    (let ((check (agent-setup--check-session-settings)))
      (should (plist-get check :ok))
      (should (directory-files agent-claude-session-settings-directory nil
                               "\\.json\\'")))))

(ert-deftest agent-setup-test-global-settings-without-agent-entries ()
  "Settings without agent entries are left untouched and nothing is asked."
  (agent-setup-test--with-settings file "{\"model\": \"x\"}"
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (&rest _) (error "Should not ask"))))
      (should (plist-get (agent-setup--check-global-settings) :ok)))
    (should (equal (agent-setup-test--contents file) "{\"model\": \"x\"}"))))

(ert-deftest agent-setup-test-missing-global-settings-stay-missing ()
  "A missing global settings file is not created."
  (agent-setup-test--with-settings file nil
    (should (plist-get (agent-setup--check-global-settings) :ok))
    (should-not (file-exists-p file))))

(ert-deftest agent-setup-test-declining-cleanup-leaves-settings-alone ()
  "Declining the removal writes nothing and reports the duplicates."
  (agent-setup-test--with-settings file agent-setup-test--global-with-agent-entries
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
      (let ((check (agent-setup--check-global-settings)))
        (should-not (plist-get check :ok))
        (should (string-match-p "2 agent entries remain" (plist-get check :label)))))
    (should (equal (agent-setup-test--contents file)
                   agent-setup-test--global-with-agent-entries))))

(ert-deftest agent-setup-test-accepting-cleanup-removes-only-agent-entries ()
  "Accepting the removal keeps the user's own hook."
  (agent-setup-test--with-settings file agent-setup-test--global-with-agent-entries
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
      (should (plist-get (agent-setup--check-global-settings) :ok)))
    (let ((settings (agent-claude--read-json-object file)))
      (should-not (gethash "statusLine" settings))
      (should (equal (agent-claude-global-config-entries file) nil))
      (should (string-match-p "my-own-hook" (json-serialize settings))))))

(ert-deftest agent-setup-test-report-summarizes ()
  "The report marks each check and says whether anything is left."
  (save-window-excursion
    (with-current-buffer
        (agent-setup--report (list (list :ok t :label "one")
                                   (list :ok nil :label "two" :hint "fix it")))
      (should (string-match-p "✓ one" (buffer-string)))
      (should (string-match-p "✗ two\n      fix it" (buffer-string)))
      (should (string-match-p "Fix the items" (buffer-string))))))

;;;; Bundled skills

(defmacro agent-setup-test--with-skills (var &rest body)
  "Bind VAR to a temporary tool home and run BODY against bundled skills.
The package directory holds the skills `one' and `two'; the tool's
skills directory is VAR/skills/."
  (declare (indent 1))
  `(let* ((root (make-temp-file "agent-setup-skills" t))
          (,var (expand-file-name "home/" root))
          (agent-setup-package-directory (expand-file-name "package/" root)))
     (unwind-protect
         (progn
           (make-directory ,var t)
           (dolist (skill '("one" "two"))
             (let ((dir (expand-file-name (concat "etc/skills/" skill)
                                          agent-setup-package-directory)))
               (make-directory dir t)
               (with-temp-file (expand-file-name "SKILL.md" dir)
                 (insert "---\nname: " skill "\n---\n"))))
           ,@body)
       (delete-directory root t))))

(defun agent-setup-test--check-skills (home answer)
  "Check the bundled skills for the tool home HOME, answering ANSWER.
ANSWER is t, nil, or `fail' to signal an error when asked."
  (cl-letf (((symbol-function 'y-or-n-p)
             (lambda (&rest _)
               (if (eq answer 'fail) (error "Should not ask") answer))))
    (agent-setup--check-skill-directory
     "Tool" (expand-file-name "skills/" home))))

(ert-deftest agent-setup-test-skill-directory-follows-tool-home ()
  "A tool's skills go under the home its variable names, else the default."
  (let ((process-environment (cons "AGENT_SETUP_TEST_HOME=/tmp/tool"
                                   process-environment)))
    (should (equal (agent-setup--tool-skill-directory
                    "AGENT_SETUP_TEST_HOME" "~/.tool/")
                   "/tmp/tool/skills/")))
  (should (equal (agent-setup--tool-skill-directory
                  "AGENT_SETUP_TEST_UNSET" "/tmp/default/")
                 "/tmp/default/skills/")))

(ert-deftest agent-setup-test-skills-are-linked-on-yes ()
  "Accepting links every bundled skill, and a second run asks nothing."
  (agent-setup-test--with-skills home
    (let ((check (agent-setup-test--check-skills home t)))
      (should (plist-get check :ok))
      (should (string-match-p "one, two" (plist-get check :label))))
    (should (file-exists-p (expand-file-name "skills/one/SKILL.md" home)))
    (should (file-symlink-p (expand-file-name "skills/two" home)))
    (should (plist-get (agent-setup-test--check-skills home 'fail) :ok))))

(ert-deftest agent-setup-test-declining-skills-links-nothing ()
  "Declining creates nothing and reports the skills as not linked."
  (agent-setup-test--with-skills home
    (let ((check (agent-setup-test--check-skills home nil)))
      (should-not (plist-get check :ok))
      (should (string-match-p "not linked" (plist-get check :label))))
    (should-not (file-exists-p (expand-file-name "skills" home)))))

(ert-deftest agent-setup-test-own-skill-is-left-alone ()
  "A skill of the same name that agent did not link is never replaced."
  (agent-setup-test--with-skills home
    (let ((own (expand-file-name "skills/one/" home)))
      (make-directory own t)
      (with-temp-file (expand-file-name "SKILL.md" own) (insert "mine"))
      (let ((check (agent-setup-test--check-skills home t)))
        (should (plist-get check :ok)))
      (should-not (file-symlink-p (directory-file-name own)))
      (should (equal (agent-setup-test--contents
                      (expand-file-name "SKILL.md" own))
                     "mine"))
      (should (file-symlink-p (expand-file-name "skills/two" home)))
      (should (string-match-p
               "your own one left alone"
               (plist-get (agent-setup-test--check-skills home 'fail) :label))))))

(ert-deftest agent-setup-test-stale-skill-link-is-repointed ()
  "A link into another checkout's bundled skills is replaced on yes."
  (agent-setup-test--with-skills home
    (make-directory (expand-file-name "skills/" home) t)
    (make-symbolic-link "/gone/agent/etc/skills/one"
                        (expand-file-name "skills/one" home))
    (should (plist-get (agent-setup-test--check-skills home t) :ok))
    (should (file-exists-p (expand-file-name "skills/one/SKILL.md" home)))))

(ert-deftest agent-setup-test-tool-without-home-is-skipped ()
  "A tool whose configuration directory is absent gets no check."
  (agent-setup-test--with-skills home
    (should-not (agent-setup-test--check-skills
                 (expand-file-name "absent/" home) 'fail))))

(ert-deftest agent-setup-test-bundled-skills-ship-with-the-package ()
  "The checkout bundles the skills the commands rely on."
  (let ((agent-setup-package-directory nil))
    (dolist (skill '("handoff" "live-session-status" "message-agent-session"))
      (should (member skill (agent-setup--bundled-skills))))
    (should (file-executable-p
             (expand-file-name "message-agent-session/scripts/agent-send"
                               (agent-setup--skills-source))))))

(provide 'agent-setup-test)
;;; agent-setup-test.el ends here
