;;; agent-forge-test.el --- Tests for agent-forge -*- lexical-binding: t -*-

;; Tests for the Forge notification routing helpers in agent-forge.el.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'agent-forge)

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
          (cl-letf (((symbol-function 'agent-forge--topic-at-point)
                     (lambda () 'topic))
                    ((symbol-function 'forge-get-repository)
                     (lambda (_topic &rest _) 'repo))
                    ((symbol-function 'forge-get-worktree)
                     (lambda (_repo) worktree))
                    ((symbol-function 'forge-get-url)
                     (lambda (_topic) "https://example.com/repo/pull/1")))
            (let ((default-directory (file-name-as-directory elsewhere)))
              (agent-forge-context (lambda (c) (setq context c)))))
          (should (equal (plist-get context :directory)
                         (file-name-as-directory worktree)))
          (should (equal (plist-get context :payload)
                         "https://example.com/repo/pull/1"))
          (should-not (plist-get context :submit))
          (should-not (plist-get context :text)))
      (delete-directory worktree t)
      (delete-directory elsewhere t))))

(ert-deftest agent-forge-test-context-requires-a-url ()
  "Signal a user error when the topic at point carries no URL."
  (let ((worktree (make-temp-file "agent-forge-test-worktree" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'agent-forge--topic-at-point)
                   (lambda () 'topic))
                  ((symbol-function 'forge-get-repository)
                   (lambda (_topic &rest _) 'repo))
                  ((symbol-function 'forge-get-worktree)
                   (lambda (_repo) worktree))
                  ((symbol-function 'forge-get-url) (lambda (_topic) nil)))
          (should-error (agent-forge-context #'ignore) :type 'user-error))
      (delete-directory worktree t))))

(provide 'agent-forge-test)
;;; agent-forge-test.el ends here
