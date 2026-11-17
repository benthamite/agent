;;; agent-test-helper.el --- Shared setup for agent's tests -*- lexical-binding: t -*-

;; Loaded by every test file.  Code under test schedules timers, for example
;; to refresh after the current hook finishes.  A timer a test leaves pending
;; fires during whichever later test is waiting then, under that test's
;; mocks, where it can fail, raise errors or start real processes.
;;
;; It also holds the fixtures more than one test file needs: a directory
;; and an org file on disk, an agenda built from that file, and the
;; messages a test issues.

;;; Code:

(require 'cl-lib)
(require 'ert)

(defvar org-agenda-files)
(defvar org-agenda-sticky)
(defvar org-agenda-window-setup)
(declare-function org-todo-list "org-agenda" (&optional arg))
(declare-function org-agenda-quit "org-agenda" ())

(defun agent-test-helper--cancel-leftover-timers (run test)
  "Call RUN on TEST, then cancel every timer TEST left pending."
  (let ((before (append timer-list timer-idle-list)))
    (unwind-protect
        (funcall run test)
      (dolist (timer (append timer-list timer-idle-list))
        (unless (memq timer before)
          (cancel-timer timer))))))

(advice-add 'ert-run-test :around #'agent-test-helper--cancel-leftover-timers)

(defmacro agent-test-helper-with-messages (messages &rest body)
  "Evaluate BODY with MESSAGES bound to the text `message' is given.
MESSAGES is a string holding each message BODY has issued so far, one to
a line and the latest last.  Nothing is echoed."
  (declare (indent 1) (debug (symbolp body)))
  `(let ((,messages ""))
     (cl-letf (((symbol-function 'message)
                (lambda (format-string &rest arguments)
                  (when format-string
                    (let ((text (apply #'format-message
                                       format-string arguments)))
                      (setq ,messages (concat ,messages text "\n"))
                      text)))))
       ,@body)))

(defmacro agent-test-helper-with-directory (directory &rest body)
  "Evaluate BODY with DIRECTORY bound to a new directory, deleted afterwards.
DIRECTORY is a symbol, bound to the name of a directory created where
temporary files go, which is also where the file of
`agent-test-helper-with-org-file' is written."
  (declare (indent 1) (debug (symbolp body)))
  `(let ((,directory (file-name-as-directory
                      (make-temp-file "agent-test" t))))
     (unwind-protect (progn ,@body)
       (delete-directory ,directory t))))

(defmacro agent-test-helper-with-org-file (contents &rest body)
  "Evaluate BODY in a buffer visiting a new org file holding CONTENTS.
The file is written to disk so that an agenda can be built from it."
  (declare (indent 1) (debug (form body)))
  `(agent-test-helper--call-with-org-file ,contents (lambda () ,@body)))

(defun agent-test-helper--call-with-org-file (contents function)
  "Call FUNCTION in a buffer visiting a new org file holding CONTENTS.
The file and its buffer are deleted afterwards."
  (let ((file (make-temp-file "agent-test" nil ".org" contents)))
    (unwind-protect
        (with-current-buffer (find-file-noselect file)
          (unwind-protect (funcall function)
            (set-buffer-modified-p nil)
            (kill-buffer)))
      (delete-file file))))

(defmacro agent-test-helper-in-agenda (heading &rest body)
  "Evaluate BODY in a TODO agenda of the current file, on the HEADING line."
  (declare (indent 1) (debug (form body)))
  `(agent-test-helper--call-in-agenda ,heading (lambda () ,@body)))

(defun agent-test-helper--call-in-agenda (heading function)
  "Call FUNCTION in a TODO agenda of the current file, on the HEADING line.
The agenda is quit afterwards."
  (require 'org-agenda)
  (let ((org-agenda-files (list (buffer-file-name)))
        (org-agenda-sticky nil)
        (org-agenda-window-setup 'current-window))
    (save-window-excursion
      (org-todo-list)
      (unwind-protect
          (progn
            (goto-char (point-min))
            (search-forward heading)
            (funcall function))
        (org-agenda-quit)))))

(provide 'agent-test-helper)

;;; agent-test-helper.el ends here
