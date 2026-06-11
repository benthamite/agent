;;; agent-slack-test.el --- Tests for agent-slack -*- lexical-binding: t -*-

;; Tests for the Slack message routing helpers in agent-slack.el.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'agent-slack)

(defun agent-slack-test--backend (&rest keys)
  "Return a minimal valid backend plist extended with KEYS."
  (append
   keys
   (list :buffer-p (lambda (_buffer) nil)
         :find-all-buffers (lambda () nil)
         :start-session #'ignore
         :label "Test")))

;;;; Loading

(ert-deftest agent-slack-test-loads ()
  "Loading the test file provides the `agent-slack' feature."
  (should (featurep 'agent-slack)))

;;;; Slack message routing

(ert-deftest agent-slack-test-act-on-slack-message-uses-unified-defcustoms ()
  "Route Slack-message action through the unified core defcustom pair."
  (let ((agent-backends nil)
        (agent-act-on-slack-message-model 'test-model)
        (agent-act-on-slack-message-backend "TestBackend")
        (captured nil))
    (apply #'agent-register-backend 'one (agent-slack-test--backend))
    (cl-letf (((symbol-function 'agent-slack--act-on-message)
               (lambda (model backend _start-function)
                 (setq captured (list model backend)))))
      (agent-act-on-slack-message)
      (should (equal captured '(test-model "TestBackend"))))))

(ert-deftest agent-slack-test-act-on-slack-start-session-inserts-url-for-review ()
  "Start a backend session and insert the Slack URL without submitting it."
  (let ((agent-backends nil)
        (project '(:id "project" :directory "/tmp/project"))
        (url "https://example.slack.com/archives/C1/p123")
        (buffer (generate-new-buffer " *agent-test*"))
        started
        sent)
    (apply #'agent-register-backend 'one (agent-slack-test--backend))
    (unwind-protect
        (cl-letf (((symbol-function 'agent-start-session)
                   (lambda (session &rest options)
                     (setq started (list session options))
                     buffer))
                  ((symbol-function 'agent-send-string)
                   (lambda (cmd target)
                     (setq sent (list cmd target))
                     target))
                  ((symbol-function 'agent-submit)
                   (lambda (&rest _) (ert-fail "agent-submit was called")))
                  ((symbol-function 'agent-send-return)
                   (lambda (&rest _)
                     (ert-fail "agent-send-return was called"))))
          (should (eq (agent-slack--act-on-start-session 'one project url)
                      buffer))
          (let ((session (car started)))
            (should (eq (agent-session-backend session) 'one))
            (should (equal (agent-session-directory session) "/tmp/project/"))
            (should-not (agent-session-instance session)))
          (should-not (cadr started))
          (should (equal sent (list url buffer))))
      (kill-buffer buffer))))

;;;; Epoch project registry

(ert-deftest agent-slack-test-epoch-candidates-require-configuration ()
  "Signal a user error when the registry defcustom is unset."
  (let ((agent-epoch-project-registry-file nil))
    (should-error (agent-epoch-project-candidates) :type 'user-error)))

(ert-deftest agent-slack-test-epoch-project-candidates-read-project-registry ()
  "Read candidates from the canonical project registry schema."
  (let* ((root (file-name-as-directory (make-temp-file "agent-projects" t)))
         (registry (expand-file-name "project_registry.json" root))
         (project-dir (expand-file-name "slack-emoji-to-asana" root))
         (repo-dir (expand-file-name "repo" project-dir))
         (agent-epoch-projects-root root)
         (agent-epoch-project-registry-file registry))
    (unwind-protect
        (progn
          (make-directory repo-dir t)
          (with-temp-file registry
            (insert (json-serialize
                     '((schema_version . 1)
                       (projects
                        . [((id . "slack-emoji-to-asana")
                             (title . "Slack Emoji To Asana")
                             (aliases . ["slack-emoji-to-asana"
                                         "slack emoji to asana"])
                             (browser_keywords . ["slack-emoji-to-asana"])
                             (project_doc_paths . [])
                             (repo_paths . ["slack-emoji-to-asana/repo"])
                             (slack_channels . []))])))))
          (let* ((projects (agent-epoch-project-candidates))
                 (project (cl-find "slack-emoji-to-asana" projects
                                   :key (lambda (item)
                                          (plist-get item :id))
                                   :test #'string=)))
            (should project)
            (should (equal (plist-get project :directory)
                           (file-name-as-directory project-dir)))
            (should (equal (plist-get project :repo)
                           "slack-emoji-to-asana/repo"))
            (should-not (plist-get project :doc))))
      (delete-directory root t))))

(ert-deftest agent-slack-test-ordered-epoch-project-candidates-puts-model-first ()
  "Put model-selected project IDs before the remaining registry entries."
  (let* ((a (list :id "a"))
         (b (list :id "b"))
         (c (list :id "c")))
    (should (equal (agent-slack--ordered-epoch-project-candidates
                    '("c" "missing" "a") (list a b c))
                   (list c a b)))))

(provide 'agent-slack-test)
;;; agent-slack-test.el ends here
