;;; agent-todo-test.el --- Tests for agent-todo -*- lexical-binding: t -*-

;; Tests for org TODO batching and sending.

;;; Code:

(require 'ert)
(require 'agent-test-helper
         (expand-file-name "agent-test-helper"
                           (file-name-directory (or load-file-name buffer-file-name))))
(require 'cl-lib)
(require 'org)
(require 'agent-todo)

;;;; Loading

(ert-deftest agent-todo-test-loads ()
  "Loading the test file provides the `agent-todo' feature."
  (should (featurep 'agent-todo)))

;;;; Format prompt

(ert-deftest agent-todo-test-format-prompt-title-only ()
  "Return title alone when body is empty."
  (should (equal (agent-todo--format-prompt
                  '(:title "Fix the bug" :body ""))
                 "Fix the bug")))

(ert-deftest agent-todo-test-format-prompt-title-and-body ()
  "Return title and body separated by blank line."
  (should (equal (agent-todo--format-prompt
                  '(:title "Fix the bug" :body "See error in log"))
                 "Fix the bug\n\nSee error in log")))

(ert-deftest agent-todo-test-format-prompt-nil-body ()
  "Return title alone when body is nil."
  (should (equal (agent-todo--format-prompt
                  '(:title "Refactor module" :body nil))
                 "Refactor module")))

;;;; Collect todos

(ert-deftest agent-todo-test-context-submits-and-marks-in-progress ()
  "Describe a TODO as unanchored, submitted, and state-changing."
  (with-temp-buffer
    (org-mode)
    (insert "* TODO Fix the thing\nSome body\n")
    (goto-char (point-min))
    (let ((context nil)
          (agent-todo-in-progress-keyword "DOING"))
      (agent-todo-context (lambda (c) (setq context c)))
      (should (plist-get context :submit))
      (should-not (plist-get context :directory))
      (should (string-match-p "Fix the thing" (plist-get context :payload)))
      (should (equal (plist-get context :text) (plist-get context :payload)))
      (cl-letf (((symbol-function 'org-todo)
                 (lambda (state) (should (equal state "DOING")))))
        (funcall (plist-get context :after))))))

(ert-deftest agent-todo-test-context-after-thunk-follows-the-heading ()
  "Move the heading the context was read from, not the one point ended on.
The project prompt runs between extraction and the thunk, so the user
may have moved by the time the state change happens."
  (with-temp-buffer
    (insert "#+TODO: TODO DOING | DONE\n* TODO First\n* TODO Second\n")
    (org-mode)
    (goto-char (point-min))
    (re-search-forward "^\\* TODO First")
    (let ((context nil)
          (agent-todo-in-progress-keyword "DOING"))
      (agent-todo-context (lambda (c) (setq context c)))
      (goto-char (point-max))
      (funcall (plist-get context :after))
      (goto-char (point-min))
      (re-search-forward "^\\*+ ")
      (should (equal (org-get-todo-state) "DOING"))
      (goto-char (point-max))
      (should (equal (org-get-todo-state) "TODO")))))

(ert-deftest agent-todo-test-context-after-thunk-tolerates-a-deleted-heading ()
  "Change nothing when the heading is gone by the time the thunk runs.
The thunk runs after the session has started and before it is shown, so
an error there would leave a running session unshown."
  (with-temp-buffer
    (insert "#+TODO: TODO DOING | DONE\n* TODO Vanishing\n")
    (org-mode)
    (goto-char (point-min))
    (re-search-forward "^\\* TODO Vanishing")
    (let ((context nil)
          (agent-todo-in-progress-keyword "DOING"))
      (agent-todo-context (lambda (c) (setq context c)))
      (erase-buffer)
      (should-not (funcall (plist-get context :after))))))

(provide 'agent-todo-test)
;;; agent-todo-test.el ends here
