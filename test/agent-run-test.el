;;; agent-run-test.el --- Run view tests -*- lexical-binding: t -*-
(require 'ert)
(require 'agent-run)

(defun agent-run-test--state ()
  "Return an independent recorded-run fixture."
  '((version . 3) (stage . "5") (repo . "/tmp/")
    (status . "implementation-active") (active_phase . "implementation")
    (agent1 . ((buffer . "*absent-author*")))
    (agent2 . ((buffer . "*absent-reviewer*")))))

(ert-deftest agent-run-test-refresh-and-error ()
  (let ((file (make-temp-file "agent-run-test-")))
    (unwind-protect
        (with-temp-buffer
          (agent-run-mode)
          (setq agent-run--file file)
          (with-temp-file file (insert (json-encode (agent-run-test--state))))
          (with-temp-file (concat file ".progress") (insert "First\nTesting menus\n"))
          (agent-run--revert)
          (should (string-match-p "Stage 5 — implementation" (buffer-string)))
          (should (string-match-p "Testing menus" (buffer-string)))
          (should-not (string-match-p "First" (buffer-string)))
          (with-temp-file file (insert "invalid"))
          (agent-run--revert)
          (should (string-match-p "Run unavailable" (buffer-string)))
          (should-not (string-match-p "Testing menus" (buffer-string))))
      (delete-file file)
      (delete-file (concat file ".progress")))))

(ert-deftest agent-run-test-attention-not-completion ()
  (with-temp-buffer
    (let ((agent-run--file "/nonexistent/run")
          (run (agent-run-test--state)))
      (setf (alist-get 'status run) "implementation-returned"
            (alist-get 'pending_submission run) '((kind . "steering")))
      (agent-run--render run)
      (should (string-match-p "Recorded status: implementation-returned" (buffer-string)))
      (should (string-match-p "delivery needs reconciliation" (buffer-string)))
      (should (string-match-p "Progress: not published" (buffer-string))))))

(ert-deftest agent-run-test-reused-buffer-not-linked ()
  (with-temp-buffer
    (let* ((buffer (current-buffer))
           (session (agent-session-create :backend 'codex :id "current"
                                          :directory "/tmp/"))
           (actor `((buffer . ,(buffer-name))
                    (identity . ((session_id . "old") (backend . "codex")
                                 (directory . "/tmp"))))))
      (cl-letf (((symbol-function 'agent-session) (lambda (&optional _) session))
                ((symbol-function 'agent-session-buffers) (lambda () (list buffer))))
        (should-not (agent-run--actor-buffer actor))
        (setf (alist-get 'session_id (alist-get 'identity actor)) "current")
        (should (eq buffer (agent-run--actor-buffer actor)))))))

(ert-deftest agent-run-test-unsupported-version ()
  (let ((file (make-temp-file "agent-run-test-")))
    (unwind-protect
        (progn
          (with-temp-file file (insert "{\"version\":99}"))
          (should-error (agent-run--read file) :type 'user-error))
      (delete-file file))))

(ert-deftest agent-run-test-timer-cleanup ()
  (let ((buffer (generate-new-buffer " *agent-run-test*")) timer)
    (with-current-buffer buffer
      (agent-run-mode)
      (setq timer (run-with-timer 100 100 #'ignore)
            agent-run--timer timer))
    (kill-buffer buffer)
    (should-not (memq timer timer-list))))

(ert-deftest agent-run-test-mode-change-cleans-timer ()
  (with-temp-buffer
    (agent-run-mode)
    (let ((timer (run-with-timer 100 100 #'ignore)))
      (setq agent-run--timer timer)
      (fundamental-mode)
      (should-not (memq timer timer-list)))))

(ert-deftest agent-run-test-directory-identity ()
  (should (agent-run--same-directory-p "~/" (expand-file-name "~")))
  (should-not (agent-run--same-directory-p "" "/tmp"))
  (should-not (agent-run--same-directory-p "/ssh:host:/tmp" "/tmp")))

(provide 'agent-run-test)
;;; agent-run-test.el ends here
