;;; agent-test-helper.el --- Shared setup for agent's tests -*- lexical-binding: t -*-

;; Loaded by every test file.  Code under test schedules timers, for example
;; to refresh after the current hook finishes.  A timer a test leaves pending
;; fires during whichever later test is waiting then, under that test's
;; mocks, where it can fail, raise errors or start real processes.

;;; Code:

(require 'ert)

(defun agent-test-helper--cancel-leftover-timers (run test)
  "Call RUN on TEST, then cancel every timer TEST left pending."
  (let ((before (append timer-list timer-idle-list)))
    (unwind-protect
        (funcall run test)
      (dolist (timer (append timer-list timer-idle-list))
        (unless (memq timer before)
          (cancel-timer timer))))))

(advice-add 'ert-run-test :around #'agent-test-helper--cancel-leftover-timers)

(provide 'agent-test-helper)

;;; agent-test-helper.el ends here
