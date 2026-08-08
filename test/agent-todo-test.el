;;; agent-todo-test.el --- Tests for agent-todo -*- lexical-binding: t -*-

;; Tests for org TODO batching and sending.

;;; Code:

(require 'ert)
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

(ert-deftest agent-todo-test-collect-todos-buffer-scope ()
  "Collect TODO entries from the entire buffer."
  (with-temp-buffer
    (org-mode)
    (insert "* TODO First task\nSome body text\n* TODO Second task\nMore body\n* DONE Finished\nDone body\n")
    (let ((entries (agent-todo--collect-todos 'buffer)))
      (should (= (length entries) 2))
      (should (equal (plist-get (nth 0 entries) :title) "First task"))
      (should (string-match-p "Some body text" (plist-get (nth 0 entries) :body)))
      (should (equal (plist-get (nth 1 entries) :title) "Second task")))))

(ert-deftest agent-todo-test-collect-todos-skips-done ()
  "DONE entries are excluded from the collected list."
  (with-temp-buffer
    (org-mode)
    (insert "* DONE Completed\nBody\n* TODO Active\nActive body\n")
    (let ((entries (agent-todo--collect-todos 'buffer)))
      (should (= (length entries) 1))
      (should (equal (plist-get (nth 0 entries) :title) "Active")))))

(ert-deftest agent-todo-test-collect-todos-empty-body ()
  "TODO entries with no body text get an empty string body."
  (with-temp-buffer
    (org-mode)
    (insert "* TODO No body entry\n* TODO Another entry\n")
    (let ((entries (agent-todo--collect-todos 'buffer)))
      (should (= (length entries) 2))
      (should (equal (plist-get (nth 0 entries) :title) "No body entry"))
      (should (string-empty-p (plist-get (nth 0 entries) :body))))))

(ert-deftest agent-todo-test-collect-todos-no-todos ()
  "Return nil when buffer has no TODO entries."
  (with-temp-buffer
    (org-mode)
    (insert "* Regular heading\nSome text\n* Another heading\n")
    (let ((entries (agent-todo--collect-todos 'buffer)))
      (should (null entries)))))

(ert-deftest agent-todo-test-collect-todos-subtree-scope ()
  "Collect only TODO entries within the current subtree."
  (with-temp-buffer
    (org-mode)
    (insert "* Parent\n** TODO Child task\nChild body\n** DONE Done child\n* TODO Outside\nOutside body\n")
    (goto-char (point-min))
    (save-restriction
      (org-narrow-to-subtree)
      (let ((entries (agent-todo--collect-todos 'subtree)))
        (should (= (length entries) 1))
        (should (equal (plist-get (nth 0 entries) :title) "Child task"))))))

;;;; Batch processing

(ert-deftest agent-todo-test-batch-runs-through-the-exec-prompt-slot ()
  "Run each entry through the resolved backend's exec-prompt slot."
  (let ((agent-backends nil)
        (prompts nil)
        (dir (make-temp-file "agent-todo" t)))
    (unwind-protect
        (progn
          (agent-register-backend
           'stub :buffer-p #'ignore :find-all-buffers #'ignore
           :start-session #'ignore
           :exec-prompt
           (lambda (prompt &rest kwargs)
             (push prompt prompts)
             (funcall (plist-get kwargs :callback)
                      (list :exit-code 0 :duration 1.0 :text "ok" :raw "{}"))))
          (cl-letf (((symbol-function 'agent-todo--batch-finish) #'ignore))
            (agent-todo--batch-run-next
             (list :backend 'stub
                   :queue '((:title "One" :body ""))
                   :results nil
                   :log-dir dir
                   :working-dir dir
                   :start-time (current-time))))
          (should (equal prompts '("One"))))
      (delete-directory dir t))))

(ert-deftest agent-todo-test-batch-tolerates-a-backend-without-cost ()
  "Sum costs as zero when the backend reports none, as `codex exec' does."
  (should (= (agent-todo--total-cost
              '((:cost 0.5) (:cost nil) (:cost 0.25)))
             0.75)))

;;;; Context

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

(provide 'agent-todo-test)
;;; agent-todo-test.el ends here
