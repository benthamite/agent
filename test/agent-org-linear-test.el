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
  `(agent-test-helper-with-org-file agent-org-linear-test--file-contents
     ,@body))

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
    (agent-test-helper-in-agenda "Agree on"
      (should (eq (agent--extractor-at-point) 'agent-org-linear-context))
      (goto-char (point-min))
      (search-forward "Not from Linear")
      (should (eq (agent--extractor-at-point) 'agent-todo-context)))))

;;;; Context

(ert-deftest agent-org-linear-test-context-from-the-agenda ()
  "Read the issue the agenda line shows, with its project and URL."
  (agent-org-linear-test--with-file
    (agent-test-helper-in-agenda "Agree on"
      (let ((context (agent-org-linear-test--context)))
        (should (plist-member context :submit))
        (should-not (plist-get context :submit))
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
      (agent-test-helper-in-agenda "Agree on"
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

(ert-deftest agent-org-linear-test-context-suggests-the-named-project ()
  "Suggest the account's project named like the issue's Linear project."
  (let ((elsewhere (make-temp-file "agent-org-linear-test-other" t))
        (root (make-temp-file "agent-org-linear-test-root" t)))
    (unwind-protect
        (let ((named (file-name-as-directory
                      (expand-file-name "research-stages" root))))
          (make-directory named)
          (cl-letf (((symbol-function 'agent-project-candidates)
                     (lambda (_account)
                       (list (list :label "other" :directory elsewhere)
                             (list :label "research-stages" :directory named)))))
            (agent-org-linear-test--with-file
              (goto-char (point-min))
              (search-forward "Agree on")
              (should (equal (plist-get (agent-org-linear-test--context)
                                        :suggested-directory)
                             named))
              (let ((agent--context-wants-directory nil))
                (should-not (plist-get (agent-org-linear-test--context)
                                       :suggested-directory)))
              (search-forward "Loose issue")
              (should-not (plist-get (agent-org-linear-test--context)
                                     :suggested-directory)))))
      (delete-directory elsewhere t)
      (delete-directory root t))))

;;;; Directory and submit properties

(defconst agent-org-linear-test--brief-contents
  "#+TODO: TODO DOING | DONE
* Research stages
:PROPERTIES:
:LINEAR_PROJECT: 4efcab9d
:DIR: %s
:END:
** TODO Synced brief
:PROPERTIES:
:LINEAR_URL: https://linear.app/acme/issue/AS-40/synced
:BRIEF: t
:END:
Do all of it.
** TODO Unsynced brief
:PROPERTIES:
:BRIEF: t
:END:
Do the rest.
** TODO Tracked issue
:PROPERTIES:
:LINEAR_URL: https://linear.app/acme/issue/AS-41/tracked
:END:
"
  "A project heading naming its directory, with the tasks filed under it.
It is a format string taking that directory.  Two of the tasks are
marked as ready prompts, one a Linear issue and one not yet synced, and
the third is an issue that is not marked.")

(defmacro agent-org-linear-test--with-brief-file (directory &rest body)
  "Evaluate BODY in a buffer visiting tasks whose project names DIRECTORY."
  (declare (indent 1) (debug (form body)))
  `(agent-test-helper-with-org-file
       (format agent-org-linear-test--brief-contents ,directory)
     ,@body))

(defun agent-org-linear-test--context-at (heading)
  "Return the Linear context of HEADING in the current buffer."
  (goto-char (point-min))
  (search-forward heading)
  (agent-org-linear-test--context))

(defmacro agent-org-linear-test--with-named-project (named root &rest body)
  "Evaluate BODY with the account holding a project named like the tasks'.
NAMED is bound to its directory, created under ROOT, which is where
`agent-project-named-directory' finds the Linear project of the tasks."
  (declare (indent 2) (debug (symbolp form body)))
  `(let ((,named (file-name-as-directory
                  (expand-file-name "research-stages" ,root))))
     (make-directory ,named)
     (cl-letf (((symbol-function 'agent-project-candidates)
                (lambda (_account)
                  (list (list :label "research-stages" :directory ,named)))))
       ,@body)))

(ert-deftest agent-org-linear-test-context-submits-a-ready-prompt ()
  "Submit an issue marked as a ready prompt, and leave any other to edit.
The issue's URL still follows the prompt."
  (agent-org-linear-test--with-brief-file "/nonexistent"
    (let ((agent-todo-submit-property "BRIEF")
          (agent-todo-directory-property nil))
      (let ((context (agent-org-linear-test--context-at "Synced brief")))
        (should (eq (plist-get context :submit) t))
        (should (equal (plist-get context :payload)
                       "Synced brief\n\nDo all of it.\n\nLinear issue: https://linear.app/acme/issue/AS-40/synced")))
      (let ((context (agent-org-linear-test--context-at "Tracked issue")))
        (should (plist-member context :submit))
        (should-not (plist-get context :submit))))))

(ert-deftest agent-org-linear-test-context-ignores-the-mark-when-unset ()
  "Leave a marked issue in the prompt while the submit option is nil.
Its directory property is not read either, so the named project is
suggested as before."
  (agent-test-helper-with-directory root
    (agent-org-linear-test--with-named-project named root
      (agent-org-linear-test--with-brief-file root
        (let* ((agent-todo-submit-property nil)
               (agent-todo-directory-property nil)
               (context (agent-org-linear-test--context-at "Synced brief")))
          (should (plist-member context :submit))
          (should-not (plist-get context :submit))
          (should-not (plist-member context :directory))
          (should (equal (plist-get context :suggested-directory) named)))))))

(ert-deftest agent-org-linear-test-context-carries-the-property-directory ()
  "Carry the directory a heading above the issue names, and suggest none.
The account's project sources are not read for it.  An unmarked issue is
still left in the prompt, and a running session wants no directory."
  (agent-test-helper-with-directory root
    (cl-letf (((symbol-function 'agent-project-candidates)
               (lambda (_account) (error "Consulted the project sources"))))
      (agent-org-linear-test--with-brief-file root
        (let ((agent-todo-directory-property "DIR"))
          (let ((context (agent-org-linear-test--context-at "Tracked issue")))
            (should (equal (plist-get context :directory) root))
            (should-not (plist-member context :suggested-directory))
            (should-not (plist-get context :submit)))
          (let* ((agent--context-wants-directory nil)
                 (context (agent-org-linear-test--context-at "Tracked issue")))
            (should-not (plist-member context :directory))
            (should-not (plist-member context :suggested-directory))))))))

(ert-deftest agent-org-linear-test-context-suggests-past-a-missing-directory ()
  "Suggest the named project when the property's directory does not exist."
  (agent-test-helper-with-directory root
    (agent-org-linear-test--with-named-project named root
      (agent-org-linear-test--with-brief-file (expand-file-name "gone" root)
        (let ((agent-todo-directory-property "DIR"))
          (agent-test-helper-with-messages messages
            (let ((context (agent-org-linear-test--context-at "Tracked issue")))
              (should-not (plist-member context :directory))
              (should (equal (plist-get context :suggested-directory) named)))
            (should (string-match-p "Ignoring the DIR property" messages))))))))

(ert-deftest agent-org-linear-test-brief-routes-alike-synced-or-not ()
  "Route a marked task from the agenda the same with or without a URL.
Either way it starts in the directory its project heading names, with
its text submitted; only the extractor differs, and the issue's URL."
  (agent-test-helper-with-directory root
    (agent-org-linear-test--with-brief-file root
      (let ((agent-todo-directory-property "DIR")
            (agent-todo-submit-property "BRIEF")
            contexts)
        (agent-test-helper-in-agenda "Synced brief"
          (dolist (heading '("Synced brief" "Unsynced brief"))
            (goto-char (point-min))
            (search-forward heading)
            (let ((extractor (agent--extractor-at-point)))
              (funcall extractor
                       (lambda (context)
                         (push (cons extractor context) contexts))))))
        (pcase-let ((`((,unsynced-extractor . ,unsynced)
                       (,synced-extractor . ,synced))
                     contexts))
          (should (eq synced-extractor 'agent-org-linear-context))
          (should (eq unsynced-extractor 'agent-todo-context))
          (dolist (context (list synced unsynced))
            (should (equal (plist-get context :directory) root))
            (should (eq (plist-get context :submit) t)))
          (should (equal (plist-get unsynced :payload)
                         "Unsynced brief\n\nDo the rest."))
          (should (string-prefix-p "Synced brief\n\nDo all of it.\n\nLinear issue: "
                                   (plist-get synced :payload))))))))

;;;; Origin

(ert-deftest agent-org-linear-test-origin-names-the-workspace ()
  "Name the Linear workspace of the issue's URL as its origin."
  (agent-org-linear-test--with-file
    (agent-test-helper-in-agenda "Agree on"
      (should (equal (agent-org-linear-origin) "linear:acme")))))

(provide 'agent-org-linear-test)
;;; agent-org-linear-test.el ends here
