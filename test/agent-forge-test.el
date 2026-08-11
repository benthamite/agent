;;; agent-forge-test.el --- Tests for agent-forge -*- lexical-binding: t -*-

;; Tests for the Forge notification routing helpers in agent-forge.el.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'agent-forge)

;;;; Helpers

(defmacro agent-forge-test--at-point (notification topic &rest body)
  "Evaluate BODY with NOTIFICATION at point reporting TOPIC as its subject.
No topic section is at point, so a topic reaches the routing layer
through NOTIFICATION alone.  forge is reported as loaded, so the
`require' in `agent-forge-context' is a no-op that cannot replace the
stand-ins installed here, and these tests run whether or not forge is
installed.  `features' is not a special variable, so a `let' would bind
it lexically and leave the global list untouched; the value cell has to
be bound instead."
  (declare (indent 2) (debug (form form body)))
  `(cl-letf (((symbol-value 'features) (cons 'forge features))
             ((symbol-function 'forge-notification-at-point)
              (lambda (&optional _) ,notification))
             ((symbol-function 'agent-forge--notification-topic)
              (lambda (_notification) ,topic))
             ((symbol-function 'forge-topic-at-point) (lambda (&optional _) nil))
             ((symbol-function 'agent-forge--slug) (lambda (_repo) "owner/name")))
     ,@body))

;;;; Loading

(ert-deftest agent-forge-test-loads ()
  "Loading the test file provides the `agent-forge' feature."
  (should (featurep 'agent-forge)))

;;;; Context

(ert-deftest agent-forge-test-context-is-anchored-in-the-worktree ()
  "Anchor the context in the working tree Forge records for the repository."
  (let ((worktree (make-temp-file "agent-forge-test-worktree" t))
        (elsewhere (make-temp-file "agent-forge-test-elsewhere" t))
        (context nil))
    (unwind-protect
        (progn
          (agent-forge-test--at-point nil 'topic
            (cl-letf (((symbol-function 'forge-get-repository)
                       (lambda (_topic &rest _) 'repo))
                      ((symbol-function 'forge-get-worktree)
                       (lambda (_repo) worktree))
                      ((symbol-function 'forge-get-url)
                       (lambda (_topic) "https://example.com/repo/pull/1")))
              (let ((default-directory (file-name-as-directory elsewhere)))
                (agent-forge-context (lambda (c) (setq context c))))))
          (should (equal (plist-get context :directory)
                         (file-name-as-directory worktree)))
          (should (equal (plist-get context :payload)
                         "https://example.com/repo/pull/1"))
          (should-not (plist-get context :submit))
          (should (string-prefix-p "owner/name" (plist-get context :text))))
      (delete-directory worktree t)
      (delete-directory elsewhere t))))

(ert-deftest agent-forge-test-worktree-comes-from-the-project-sources ()
  "Anchor the context in the clone the account's project sources name.
Forge records a worktree only for a repository it has seen from a local
clone, and forgets one whose recorded path stopped being a worktree, so
the sources are what still know where the clone is."
  (let ((clone (make-temp-file "agent-forge-test-clone" t))
        (asked nil)
        (context nil))
    (unwind-protect
        (progn
          (agent-forge-test--at-point nil 'topic
            (cl-letf (((symbol-function 'forge-get-repository)
                       (lambda (_topic &rest _) 'repo))
                      ((symbol-function 'forge-get-worktree) (lambda (_repo) nil))
                      ((symbol-function 'agent--slot-value)
                       (lambda (_repo _slot) "uqbar-es"))
                      ((symbol-function 'agent-project-repository-directory)
                       (lambda (name account)
                         (setq asked (list name account))
                         clone))
                      ((symbol-function 'forge-get-url)
                       (lambda (_topic) "https://example.com/repo/issues/1")))
              (let ((agent--context-account "epoch"))
                (agent-forge-context (lambda (c) (setq context c))))))
          (should (equal asked '("uqbar-es" "epoch")))
          (should (equal (plist-get context :directory)
                         (file-name-as-directory clone))))
      (delete-directory clone t))))

(ert-deftest agent-forge-test-context-without-a-clone-carries-text ()
  "Leave the directory out when no clone is known, and describe the subject.
The core reads a project from the text, which is a completion prompt
rather than a refusal."
  (let ((context nil))
    (agent-forge-test--at-point nil 'topic
      (cl-letf (((symbol-function 'forge-get-repository)
                 (lambda (_topic &rest _) 'repo))
                ((symbol-function 'forge-get-worktree) (lambda (_repo) nil))
                ((symbol-function 'agent--slot-value)
                 (lambda (_repo _slot) "uqbar-es"))
                ((symbol-function 'agent-project-repository-directory)
                 (lambda (_name _account) nil))
                ((symbol-function 'forge-get-url)
                 (lambda (_topic) "https://example.com/repo/issues/1")))
        (agent-forge-context (lambda (c) (setq context c)))))
    (should-not (plist-get context :directory))
    (should (equal (plist-get context :text)
                   "owner/name\nhttps://example.com/repo/issues/1"))
    (should (equal (plist-get context :payload)
                   "https://example.com/repo/issues/1"))))

(ert-deftest agent-forge-test-context-requires-a-url ()
  "Signal a user error when the topic at point carries no URL."
  (let ((worktree (make-temp-file "agent-forge-test-worktree" t)))
    (unwind-protect
        (agent-forge-test--at-point nil 'topic
          (cl-letf (((symbol-function 'forge-get-repository)
                     (lambda (_topic &rest _) 'repo))
                    ((symbol-function 'forge-get-worktree)
                     (lambda (_repo) worktree))
                    ((symbol-function 'forge-get-url) (lambda (_topic) nil)))
            (should-error (agent-forge-context #'ignore) :type 'user-error)))
      (delete-directory worktree t))))

(ert-deftest agent-forge-test-a-running-session-needs-no-clone ()
  "Route a topic to a running session whose repository was never cloned.
The session already has a directory, so refusing the topic for a missing
working tree would refuse it over a directory nobody reads."
  (with-temp-buffer
    (let ((target (current-buffer))
          (sent nil))
      (agent-forge-test--at-point nil 'topic
        (cl-letf (((symbol-function 'forge-get-repository)
                   (lambda (_topic &rest _) 'repo))
                  ((symbol-function 'forge-get-worktree) (lambda (_repo) nil))
                  ((symbol-function 'forge-get-url)
                   (lambda (_topic) "https://example.com/repo/pull/1"))
                  ((symbol-function 'agent--read-session-buffer)
                   (lambda () target))
                  ((symbol-function 'agent-send-string)
                   (lambda (string _buffer) (setq sent string)))
                  ((symbol-function 'display-buffer) #'ignore))
          (agent--act-on-context #'agent-forge-context t)))
      (should (equal sent "https://example.com/repo/pull/1")))))

;;;; Notifications about no topic

(ert-deftest agent-forge-test-context-routes-a-topicless-notification ()
  "Route a notification about no topic by its own repository and URL.
Github notifies about check suites, commits and releases as well as
about topics, and the title is what says which run this is: the URL
alone names the page listing every run of the repository."
  (let ((worktree (make-temp-file "agent-forge-test-worktree" t))
        (context nil))
    (unwind-protect
        (progn
          (agent-forge-test--at-point 'notification nil
            (cl-letf (((symbol-function 'agent--slot-value)
                       (lambda (_notification _slot) "test workflow run failed"))
                      ((symbol-function 'forge-get-repository)
                       (lambda (_notification &rest _) 'repo))
                      ((symbol-function 'forge-get-worktree)
                       (lambda (_repo) worktree))
                      ((symbol-function 'forge-get-url)
                       (lambda (_notification)
                         "https://example.com/repo/actions")))
              (agent-forge-context (lambda (c) (setq context c)))))
          (should (equal (plist-get context :directory)
                         (file-name-as-directory worktree)))
          (should (equal (plist-get context :payload)
                         (concat "test workflow run failed\n"
                                 "https://example.com/repo/actions")))
          (should-not (plist-get context :submit)))
      (delete-directory worktree t))))

(ert-deftest agent-forge-test-context-refuses-an-empty-buffer ()
  "Refuse a buffer holding neither a notification nor a topic."
  (agent-forge-test--at-point nil nil
    (should (string-match-p
             "No Forge notification or topic"
             (error-message-string
              (should-error (agent-forge-context #'ignore) :type 'user-error))))))

(provide 'agent-forge-test)
;;; agent-forge-test.el ends here
