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
(declare-function org-tags-view "org-agenda" (&optional todo-only match))
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

(defvar agent-test-helper-check-directories nil
  "Non-nil to let `agent--check-start-directory' look at the file system.
Most tests start sessions in made-up directories, so the check passes
unless a test binds this.")

(advice-add 'agent--check-start-directory :before-while
            (lambda (&rest _) agent-test-helper-check-directories)
            '((name . agent-test-helper-check-directories)))

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

(defmacro agent-test-helper-in-tags-agenda (match heading &rest body)
  "Evaluate BODY in an agenda of the current file's entries matching MATCH.
Point is on the HEADING line.  Such an agenda is rebuilt from its query,
as a custom list of tasks is, where the TODO agenda of
`agent-test-helper-in-agenda' is rebuilt from a keyword."
  (declare (indent 2) (debug (form form body)))
  `(agent-test-helper--call-in-agenda ,heading (lambda () ,@body)
                                      (lambda () (org-tags-view nil ,match))))

(defun agent-test-helper--call-in-agenda (heading function &optional build)
  "Call FUNCTION in an agenda of the current file, on the HEADING line.
The agenda is the TODO agenda, or the one BUILD, a function of no
arguments, builds.  It is quit afterwards."
  (require 'org-agenda)
  (let ((org-agenda-files (list (buffer-file-name)))
        (org-agenda-sticky nil)
        (org-agenda-window-setup 'current-window))
    (save-window-excursion
      (funcall (or build #'org-todo-list))
      (unwind-protect
          (progn
            (goto-char (point-min))
            (search-forward heading)
            (funcall function))
        (org-agenda-quit)))))

(defun agent-test-helper-batch-eval (form)
  "Evaluate FORM in a new batch Emacs and return its value.
The new Emacs has the `load-path' of this one and loads source files as
this one does, so what FORM requires and loads is the code under test.
The value must be printable and readable.  This is for what cannot be
tried in the Emacs running the tests without changing it for the tests
that follow, such as loading a file of the package a second time."
  (with-temp-buffer
    (let* ((setup `(setq load-path ',load-path
                         load-prefer-newer ,load-prefer-newer
                         load-suffixes ',load-suffixes))
           (status (call-process
                    (expand-file-name invocation-name invocation-directory)
                    nil '(t nil) nil "-Q" "--batch"
                    "--eval" (prin1-to-string
                              `(progn ,setup (prin1 ,form))))))
      (unless (eql status 0)
        (error "The batch Emacs exited with %s: %s" status (buffer-string)))
      (goto-char (point-min))
      (read (current-buffer)))))

;;;; Answering a decision

(declare-function agent-decision--asking-create "agent-decision")
(declare-function agent-decision--option-specs "agent-decision" (asking))
(declare-function agent-decision--action-specs "agent-decision" (asking))
(declare-function agent-decision--menu-act "agent-decision" (command action))

(defun agent-test-helper-decision-keys (keys)
  "Return a stand-in for `agent-decision-ask' that answers with KEYS.
Each of KEYS is a key of `agent-decision-menu' as a string, as its
suffixes name it, or as an event: 13 for \"RET\" and a character for
itself.  Each is pressed in turn, as the menu would run the suffix the
menu shows for it, from the keyboard; a key the menu does not show
signals an error, and \"q\" quits, answering nothing."
  (lambda (record drafts comments callback)
    (let ((asking (agent-decision--asking-create
                   :record record :drafts drafts :comments comments
                   :callback callback)))
      (cl-letf (((symbol-function 'agent-decision--menu-asking)
                 (lambda () asking)))
        (catch 'agent-test-helper--quit
          (dolist (key keys)
            (agent-test-helper--decision-press
             asking (cond ((eql key 13) "RET")
                          ((integerp key) (string key))
                          (t key)))))))))

(defun agent-test-helper--decision-press (asking key)
  "Press KEY, a string, in `agent-decision-menu' showing ASKING."
  (let* ((spec (or (seq-find (lambda (spec) (equal (car spec) key))
                             (append (agent-decision--option-specs asking)
                                     (agent-decision--action-specs asking)))
                   (error "The menu shows no key %s" key)))
         (command (nth 2 spec)))
    (if (eq command 'transient-quit-one)
        (throw 'agent-test-helper--quit nil)
      (let ((this-command command)
            (last-input-event (if (equal key "RET") 13 (aref key 0)))
            (inhibit-quit nil))
        (agent-decision--menu-act
         command
         (pcase command
           ('agent-decision-menu-choose
            (cons 'choose (plist-get (nthcdr 3 spec) :option)))
           ('agent-decision-menu-accept '(accept))
           ('agent-decision-menu-comment '(comment))
           ('agent-decision-menu-drop '(drop))))))))

(provide 'agent-test-helper)

;;; agent-test-helper.el ends here
