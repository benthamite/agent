;;; agent-org-linear-test.el --- Tests for agent-org-linear -*- lexical-binding: t -*-

;; Tests for routing Linear issues mirrored by org-linear.

;;; Code:

(require 'ert)
(require 'agent-test-helper
         (expand-file-name "agent-test-helper"
                           (file-name-directory (or load-file-name buffer-file-name))))
(require 'cl-lib)
(require 'org)
(require 'org-agenda)
(require 'agent-org-linear)

;;;; Helpers

(defconst agent-org-linear-test--file-contents
  "#+TODO: TODO DOING | DONE
* Research stages
:PROPERTIES:
:LINEAR_PROJECT: 4efcab9d
:END:
** TODO Agree on the pipeline version
:PROPERTIES:
:LINEAR_URL: https://linear.app/acme/issue/AS-33/agree
:LINEAR_ID: AS-33
:END:
Ask Peter which one.
* No project
:PROPERTIES:
:LINEAR_PROJECT: none
:END:
** TODO Loose issue
:PROPERTIES:
:LINEAR_URL: https://linear.app/acme/issue/AS-34/loose
:END:
* Plain
** TODO Not from Linear
"
  "A file in the shape `org-linear' writes, plus a heading it did not.")

(defmacro agent-org-linear-test--with-file (&rest body)
  "Evaluate BODY in a buffer visiting a mirrored Linear file.
The file is written to disk so that an agenda can be built from it."
  (declare (indent 0) (debug (body)))
  `(let ((file (make-temp-file "agent-org-linear-test" nil ".org"
                               agent-org-linear-test--file-contents)))
     (unwind-protect
         (with-current-buffer (find-file-noselect file)
           (unwind-protect (progn ,@body)
             (set-buffer-modified-p nil)
             (kill-buffer)))
       (delete-file file))))

(defmacro agent-org-linear-test--in-agenda (heading &rest body)
  "Evaluate BODY in a TODO agenda of the current file, on the HEADING line."
  (declare (indent 1) (debug (form body)))
  `(let ((org-agenda-files (list (buffer-file-name)))
         (org-agenda-sticky nil)
         (org-agenda-window-setup 'current-window))
     (save-window-excursion
       (org-todo-list)
       (unwind-protect
           (progn
             (goto-char (point-min))
             (search-forward ,heading)
             ,@body)
         (org-agenda-quit)))))

(defun agent-org-linear-test--context ()
  "Return the context `agent-org-linear-context' reads at point."
  (let (context)
    (agent-org-linear-context (lambda (c) (setq context c)))
    context))

;;;; Dispatch

(ert-deftest agent-org-linear-test-dispatch-prefers-the-linear-issue ()
  "Route a mirrored issue as a Linear issue, and a plain TODO as a TODO."
  (agent-org-linear-test--with-file
    (goto-char (point-min))
    (search-forward "Agree on")
    (should (eq (agent--extractor-at-point) 'agent-org-linear-context))
    (search-forward "Not from Linear")
    (should (eq (agent--extractor-at-point) 'agent-todo-context))))

(ert-deftest agent-org-linear-test-dispatch-reads-the-agenda ()
  "Recognize an issue and a plain TODO from the agenda lines showing them."
  (agent-org-linear-test--with-file
    (agent-org-linear-test--in-agenda "Agree on"
      (should (eq (agent--extractor-at-point) 'agent-org-linear-context))
      (goto-char (point-min))
      (search-forward "Not from Linear")
      (should (eq (agent--extractor-at-point) 'agent-todo-context)))))

;;;; Context

(ert-deftest agent-org-linear-test-context-from-the-agenda ()
  "Read the issue the agenda line shows, with its project and URL."
  (agent-org-linear-test--with-file
    (agent-org-linear-test--in-agenda "Agree on"
      (let ((context (agent-org-linear-test--context)))
        (should (plist-get context :submit))
        (should-not (plist-get context :directory))
        (should (equal (plist-get context :payload)
                       "Agree on the pipeline version\n\nAsk Peter which one.\n\nLinear issue: https://linear.app/acme/issue/AS-33/agree"))
        (should (string-prefix-p "Linear project: Research stages\n"
                                 (plist-get context :text)))))))

(ert-deftest agent-org-linear-test-context-without-a-project ()
  "Leave the project out of the text for an issue filed under none."
  (agent-org-linear-test--with-file
    (goto-char (point-min))
    (search-forward "Loose issue")
    (let ((context (agent-org-linear-test--context)))
      (should (equal (plist-get context :text) (plist-get context :payload)))
      (should (string-suffix-p "AS-34/loose" (plist-get context :payload))))))

(ert-deftest agent-org-linear-test-agenda-after-thunk-marks-the-heading ()
  "Move the issue's own heading to the in-progress keyword from the agenda.
The agenda is rebuilt, so its line shows the new keyword."
  (agent-org-linear-test--with-file
    (let ((agent-todo-in-progress-keyword "DOING"))
      (agent-org-linear-test--in-agenda "Agree on"
        (let ((context (agent-org-linear-test--context)))
          (goto-char (point-max))
          (funcall (plist-get context :after))
          (goto-char (point-min))
          (search-forward "Agree on")
          (should (string-match-p "DOING" (buffer-substring
                                           (line-beginning-position)
                                           (line-end-position))))))
      (goto-char (point-min))
      (search-forward "Agree on")
      (should (equal (org-get-todo-state) "DOING")))))

;;;; Origin

(ert-deftest agent-org-linear-test-origin-names-the-workspace ()
  "Name the Linear workspace of the issue's URL as its origin."
  (agent-org-linear-test--with-file
    (agent-org-linear-test--in-agenda "Agree on"
      (should (equal (agent-org-linear-origin) "linear:acme")))))

(provide 'agent-org-linear-test)
;;; agent-org-linear-test.el ends here
