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

;; The body ran from the end of the heading's own lines to the heading
;; after that point, which for a TODO without a body is the heading after
;; the next one: the brief then carried the whole following entry.
(ert-deftest agent-todo-test-empty-body-stops-at-the-next-heading ()
  "Brief a TODO that has no body with its title alone.
Whatever follows it belongs to another entry: a sibling with a drawer
and a body of its own, or a child.  Blank lines, a drawer and a planning
line under the TODO itself make no body either."
  (let ((next "* TODO Renew the passport
:PROPERTIES:
:ID: abc
:END:
Bring two photos.
* TODO Third task
"))
    (dolist (own '("" "\n\n" ":PROPERTIES:\n:ID: def\n:END:\n\n"
                   "DEADLINE: <2026-11-20 Fri>\n"))
      (let ((context (agent-todo-test--context-at
                      "Pay the accountant"
                      (concat "* TODO Pay the accountant\n" own next))))
        (should (equal (plist-get context :payload) "Pay the accountant"))
        (should (equal (plist-get context :text) "Pay the accountant"))))
    (dolist (contents '("* TODO Pay the accountant\n** TODO A step\nIts body.\n"
                        "* TODO Pay the accountant\n"
                        "* TODO Pay the accountant"))
      (should (equal (plist-get (agent-todo-test--context-at
                                 "Pay the accountant" contents)
                                :payload)
                     "Pay the accountant")))
    (should (equal (plist-get (agent-todo-test--context-at
                               "Pay the accountant"
                               (concat "* TODO Pay the accountant\nBy Friday.\n"
                                       next))
                              :payload)
                   "Pay the accountant\n\nBy Friday."))))

;;;; Directory property

(defun agent-todo-test--subdirectory (root name)
  "Create the directory NAME under ROOT and return its directory name."
  (let ((directory (file-name-as-directory (expand-file-name name root))))
    (make-directory directory)
    directory))

(defmacro agent-todo-test--at (heading contents &rest body)
  "Evaluate BODY on HEADING in an org buffer holding CONTENTS."
  (declare (indent 2) (debug (form form body)))
  `(with-temp-buffer
     (insert ,contents)
     (org-mode)
     (goto-char (point-min))
     (search-forward ,heading)
     ,@body))

(defun agent-todo-test--context ()
  "Return the context `agent-todo-context' reads at point."
  (let (context)
    (agent-todo-context (lambda (c) (setq context c)))
    context))

(defun agent-todo-test--context-at (heading contents)
  "Return the TODO context of HEADING in an org buffer holding CONTENTS."
  (agent-todo-test--at heading contents
    (agent-todo-test--context)))

(ert-deftest agent-todo-test-property-options-default-to-nil ()
  "Leave both property options off unless the user sets them."
  (dolist (option '(agent-todo-directory-property agent-todo-submit-property))
    (should (custom-variable-p option))
    (should-not (eval (car (get option 'standard-value)) t))))

(ert-deftest agent-todo-test-directory-property-on-the-heading ()
  "Carry the directory the TODO's own property names, and still submit.
The directory is a directory name, however the property spells it."
  (agent-test-helper-with-directory root
    (let* ((agent-todo-directory-property "DIR")
           (context (agent-todo-test--context-at "Fix it"
                      (format "* TODO Fix it\n:PROPERTIES:\n:DIR: %s\n:END:\nThe brief.\n"
                              (directory-file-name root)))))
      (should (equal (plist-get context :directory) root))
      (should (plist-get context :submit))
      (should (equal (plist-get context :payload) "Fix it\n\nThe brief.")))))

(ert-deftest agent-todo-test-directory-property-on-an-ancestor ()
  "Inherit the directory from a heading above, however far up.
The lookup does not depend on `org-use-property-inheritance', and a TODO
under no such heading carries no directory."
  (agent-test-helper-with-directory root
    (let ((agent-todo-directory-property "DIR")
          (org-use-property-inheritance nil)
          (contents (format "* Project
:PROPERTIES:
:DIR: %s
:END:
** TODO Near task
** Group
*** TODO Deep task
* Elsewhere
** TODO Stray task
" root)))
      (should (equal (plist-get (agent-todo-test--context-at "Near task" contents)
                                :directory)
                     root))
      (should (equal (plist-get (agent-todo-test--context-at "Deep task" contents)
                                :directory)
                     root))
      (should-not (plist-member
                   (agent-todo-test--context-at "Stray task" contents)
                   :directory)))))

(ert-deftest agent-todo-test-directory-property-nearest-wins ()
  "Prefer the TODO's own directory to a parent's, and that to a grandparent's."
  (agent-test-helper-with-directory root
    (let* ((agent-todo-directory-property "DIR")
           (outer (agent-todo-test--subdirectory root "outer"))
           (inner (agent-todo-test--subdirectory root "inner"))
           (own (agent-todo-test--subdirectory root "own"))
           (contents (format "* Area
:PROPERTIES:
:DIR: %s
:END:
** Project
:PROPERTIES:
:DIR: %s
:END:
*** TODO Own task
:PROPERTIES:
:DIR: %s
:END:
*** TODO Project task
** TODO Area task
" outer inner own)))
      (should (equal (plist-get (agent-todo-test--context-at "Own task" contents)
                                :directory)
                     own))
      (should (equal (plist-get
                      (agent-todo-test--context-at "Project task" contents)
                      :directory)
                     inner))
      (should (equal (plist-get (agent-todo-test--context-at "Area task" contents)
                                :directory)
                     outer)))))

(ert-deftest agent-todo-test-directory-property-ignores-a-missing-directory ()
  "Report a property naming no existing directory and carry no directory.
The nearest value is the one read, so the existing directory a heading
above names does not stand in for it."
  (agent-test-helper-with-directory root
    (let ((agent-todo-directory-property "DIR")
          (contents (format "* Project
:PROPERTIES:
:DIR: %s
:END:
** TODO Lost task
:PROPERTIES:
:DIR: %s
:END:
" root (expand-file-name "gone" root))))
      (agent-test-helper-with-messages messages
        (let ((context (agent-todo-test--context-at "Lost task" contents)))
          (should-not (plist-member context :directory))
          (should (plist-get context :submit))
          (should (equal (plist-get context :text) "Lost task")))
        (should (string-match-p "Ignoring the DIR property: no directory .*gone"
                                messages))))))

(ert-deftest agent-todo-test-directory-property-can-be-emptied-below ()
  "Carry no directory under a heading whose own value is empty or \"nil\".
Neither is a directory that went missing, so nothing is reported."
  (agent-test-helper-with-directory root
    (let ((agent-todo-directory-property "DIR")
          (contents (format "* Project
:PROPERTIES:
:DIR: %s
:END:
** TODO Emptied task
:PROPERTIES:
:DIR:
:END:
** TODO Exempt task
:PROPERTIES:
:DIR: nil
:END:
** TODO Kept task
" root)))
      (agent-test-helper-with-messages messages
        (should-not (plist-member
                     (agent-todo-test--context-at "Emptied task" contents)
                     :directory))
        (should-not (plist-member
                     (agent-todo-test--context-at "Exempt task" contents)
                     :directory))
        (should-not (string-match-p "Ignoring" messages)))
      (should (equal (plist-get (agent-todo-test--context-at "Kept task" contents)
                                :directory)
                     root)))))

(ert-deftest agent-todo-test-directory-property-expands-a-relative-name ()
  "Expand a relative name against the directory of the org buffer."
  (agent-test-helper-with-directory root
    (let ((agent-todo-directory-property "DIR")
          (sub (agent-todo-test--subdirectory root "sub")))
      (agent-todo-test--at "Fix it" "* TODO Fix it\n:PROPERTIES:\n:DIR: sub\n:END:\n"
        (setq default-directory root)
        (should (equal (plist-get (agent-todo-test--context) :directory)
                       sub))))))

(ert-deftest agent-todo-test-directory-property-unset-changes-nothing ()
  "Carry no directory while the option is nil, whatever the heading holds."
  (agent-test-helper-with-directory root
    (let* ((agent-todo-directory-property nil)
           (context (agent-todo-test--context-at "Fix it"
                      (format "* TODO Fix it\n:PROPERTIES:\n:DIR: %s\n:END:\nBody\n"
                              root))))
      (should-not (plist-member context :directory))
      (should (plist-get context :submit))
      (should (equal (plist-get context :payload) "Fix it\n\nBody"))
      (should (equal (plist-get context :text) (plist-get context :payload))))))

(ert-deftest agent-todo-test-directory-property-is-not-read-for-a-running-session ()
  "Leave the property alone when the payload is bound for a running session.
That session has a directory of its own, so a missing one is not reported."
  (agent-test-helper-with-directory root
    (let ((agent-todo-directory-property "DIR")
          (agent--context-wants-directory nil))
      (agent-test-helper-with-messages messages
        (should-not (plist-member
                     (agent-todo-test--context-at "Fix it"
                       (format "* TODO Fix it\n:PROPERTIES:\n:DIR: %s\n:END:\n"
                               root))
                     :directory))
        (should-not (plist-member
                     (agent-todo-test--context-at "Fix it"
                       (format "* TODO Fix it\n:PROPERTIES:\n:DIR: %s\n:END:\n"
                               (expand-file-name "gone" root)))
                     :directory))
        (should-not (string-match-p "Ignoring" messages))))))

(ert-deftest agent-todo-test-directory-property-from-the-agenda ()
  "Read the directory for the heading an agenda line shows.
The property is inherited in the heading's own file, and a relative name
is expanded against that file's directory, not the agenda's."
  (agent-test-helper-with-directory root
    (agent-test-helper-with-directory beside
      (let ((agent-todo-directory-property "DIR"))
        (agent-test-helper-with-org-file
            (format "* Project
:PROPERTIES:
:DIR: %s
:END:
** TODO Agenda task
The brief.
** TODO Relative task
:PROPERTIES:
:DIR: %s
:END:
" root (file-name-nondirectory (directory-file-name beside)))
          (agent-test-helper-in-agenda "Agenda task"
            (setq default-directory root)
            (should (derived-mode-p 'org-agenda-mode))
            (should (eq (agent--extractor-at-point) 'agent-todo-context))
            (let ((context (agent-todo-test--context)))
              (should (equal (plist-get context :directory) root))
              (should (plist-get context :submit))
              (should (equal (plist-get context :payload)
                             "Agenda task\n\nThe brief.")))
            (goto-char (point-min))
            (search-forward "Relative task")
            (should (equal (plist-get (agent-todo-test--context) :directory)
                           beside))))))))

;;;; Routing a TODO that names its directory

(defmacro agent-todo-test--with-backend (captured &rest body)
  "Evaluate BODY with one backend registered that has two accounts.
The backend is `one', its accounts are \"work\" and \"personal\", and
\"personal\" is the persisted selection.  A session it starts sets
CAPTURED to the list of its directory, its account and its initial
prompt.  The project reader refuses to be consulted."
  (declare (indent 1) (debug (symbolp body)))
  `(let ((agent-backends nil)
         (agent-account--current (make-hash-table :test #'eq)))
     (puthash 'one "personal" agent-account--current)
     (agent-register-backend
      'one
      :buffer-p #'ignore
      :find-all-buffers #'ignore
      :label "Test"
      :accounts '(("work" . "/tmp/agent-test-work/")
                  ("personal" . "/tmp/agent-test-personal/"))
      :start-session (lambda (session &rest options)
                       (setq ,captured
                             (list (agent-session-directory session)
                                   (agent-session-account session)
                                   (plist-get options :initial-prompt)))
                       (current-buffer)))
     (cl-letf (((symbol-function 'agent-account-sync) #'ignore)
               ((symbol-function 'agent-project-read)
                (lambda (&rest _) (error "Consulted the project reader")))
               ((symbol-function 'display-buffer) #'ignore))
       ,@body)))

(ert-deftest agent-todo-test-directory-property-starts-the-session-there ()
  "Start the session in the property's directory, with the brief submitted.
No project is read.  The account is the persisted selection when no
rule covers the directory."
  (agent-test-helper-with-directory root
    (let ((agent-todo-directory-property "DIR")
          (agent-account-directory-rules nil)
          captured)
      (agent-todo-test--with-backend captured
        (agent-todo-test--at "Do it"
            (format "* Project\n:PROPERTIES:\n:DIR: %s\n:END:\n** TODO Do it\nThe brief.\n"
                    root)
          (agent-act-on-thing-at-point)))
      (should (equal captured (list root "personal" "Do it\n\nThe brief."))))))

(ert-deftest agent-todo-test-directory-property-follows-the-directory-rule ()
  "Start the session under the account its directory's rule names.
A context that carries a directory leaves the account to
`agent-start-session', so `agent-account-directory-rules' outranks the
persisted selection, as for any session started in that directory."
  (agent-test-helper-with-directory root
    (let ((agent-todo-directory-property "DIR")
          (agent-account-directory-rules `((,root . "work")))
          captured)
      (agent-todo-test--with-backend captured
        (agent-todo-test--at "Do it"
            (format "* Project\n:PROPERTIES:\n:DIR: %s\n:END:\n** TODO Do it\n"
                    root)
          (agent-act-on-thing-at-point)))
      (should (equal captured (list root "work" "Do it"))))))

;;;; Session names

(defmacro agent-todo-test--with-sessions (sessions &rest body)
  "Evaluate BODY with one backend whose sessions are collected in SESSIONS.
The backend is `one'.  SESSIONS is a symbol, bound to the `agent-session'
of each session started, the latest first, and each of them counts as
live.  Every function that asks the user something signals an error, as
does the project reader."
  (declare (indent 1) (debug (symbolp body)))
  `(let ((agent-backends nil)
         (agent-account-directory-rules nil)
         (,sessions nil))
     (agent-register-backend
      'one
      :buffer-p #'ignore
      :find-all-buffers #'ignore
      :label "Test"
      :start-session (lambda (session &rest _)
                       (push session ,sessions)
                       (current-buffer)))
     (cl-letf (((symbol-function 'agent-session-buffers)
                (lambda () (copy-sequence ,sessions)))
               ((symbol-function 'agent-session) #'identity)
               ((symbol-function 'read-string)
                (lambda (&rest _) (error "Asked with `read-string'")))
               ((symbol-function 'completing-read)
                (lambda (&rest _) (error "Asked with `completing-read'")))
               ((symbol-function 'y-or-n-p)
                (lambda (&rest _) (error "Asked with `y-or-n-p'")))
               ((symbol-function 'yes-or-no-p)
                (lambda (&rest _) (error "Asked with `yes-or-no-p'")))
               ((symbol-function 'agent-project-read)
                (lambda (&rest _) (error "Consulted the project reader")))
               ((symbol-function 'display-buffer) #'ignore))
       ,@body)))

(defun agent-todo-test--start (command contents &rest headings)
  "Call COMMAND on each of HEADINGS in an org buffer holding CONTENTS."
  (with-temp-buffer
    (insert contents)
    (org-mode)
    (dolist (heading headings)
      (goto-char (point-min))
      (search-forward heading)
      (funcall command))))

(defun agent-todo-test--instances (sessions)
  "Return the instance names of SESSIONS, the first started first."
  (reverse (mapcar #'agent-session-instance sessions)))

(ert-deftest agent-todo-test-slug ()
  "Make a short name of lower-case letters, digits and hyphens."
  (should (equal (agent-todo--slug "Fix the Build!") "fix-the-build"))
  (should (equal (agent-todo--slug "!!!") "task"))
  (should (<= (length (agent-todo--slug (make-string 80 ?a))) 40)))

(ert-deftest agent-todo-test-context-carries-the-task-name ()
  "Name the session of a TODO after its heading."
  (let ((context (agent-todo-test--context-at
                  "Fix it" "* TODO Fix it: now\nBody.\n")))
    (should (equal (plist-get context :instance) "fix-it-now"))))

(ert-deftest agent-todo-test-two-todos-in-one-directory-ask-for-no-name ()
  "Start two TODOs of one directory as two sessions named after them.
Neither is the default instance, and nothing is asked."
  (dolist (command '(agent-act-on-thing-at-point agent-send-todo-at-point))
    (agent-test-helper-with-directory root
      (let ((agent-todo-directory-property "DIR"))
        (agent-todo-test--with-sessions sessions
          (agent-todo-test--start
           command
           (format "* Project\n:PROPERTIES:\n:DIR: %s\n:END:\n** TODO Fix the build\n** TODO Write the docs\n"
                   root)
           "Fix the build" "Write the docs")
          (should (equal (agent-todo-test--instances sessions)
                         '("fix-the-build" "write-the-docs")))
          (should (equal (mapcar #'agent-session-directory sessions)
                         (list root root))))))))

(ert-deftest agent-todo-test-two-todos-start-with-prompts-inhibited ()
  "Start two TODOs of one directory where nothing may be asked."
  (agent-test-helper-with-directory root
    (let ((agent-todo-directory-property "DIR")
          (agent-inhibit-prompts t)
          (inhibit-interaction t))
      (agent-todo-test--with-sessions sessions
        (agent-todo-test--start
         #'agent-act-on-thing-at-point
         (format "* Project\n:PROPERTIES:\n:DIR: %s\n:END:\n** TODO Fix the build\n** TODO Write the docs\n"
                 root)
         "Fix the build" "Write the docs")
        (should (equal (agent-todo-test--instances sessions)
                       '("fix-the-build" "write-the-docs")))))))

(ert-deftest agent-todo-test-a-task-session-shows-its-name ()
  "Mark the session of a TODO as named, so that it shows the task's name.
A session started for a thing that is no TODO is left unmarked."
  (agent-test-helper-with-directory root
    (let ((agent-todo-directory-property "DIR")
          (extractor (lambda (callback)
                       (funcall callback (list :directory root
                                               :payload "Look"
                                               :submit t)))))
      (dolist (command '(agent-act-on-thing-at-point agent-send-todo-at-point))
        (agent-todo-test--with-sessions sessions
          (with-temp-buffer
            (insert (format "#+PROPERTY: DIR %s\n* TODO Fix the build\n" root))
            (org-mode)
            (search-backward "Fix")
            (funcall command)
            (should agent--named))))
      (agent-todo-test--with-sessions sessions
        (with-temp-buffer
          (agent--act-on-context extractor nil)
          (should (= (length sessions) 1))
          (should-not agent--named))))))

(ert-deftest agent-todo-test-a-taken-task-name-is-numbered ()
  "Number the name of a TODO whose heading names a live session there."
  (agent-test-helper-with-directory root
    (let ((agent-todo-directory-property "DIR"))
      (agent-todo-test--with-sessions sessions
        (agent-todo-test--start
         #'agent-act-on-thing-at-point
         (format "#+PROPERTY: DIR %s\n* TODO Do it\n* TODO Do it!\n" root)
         "Do it" "Do it!")
        (should (equal (agent-todo-test--instances sessions)
                       '("do-it" "do-it-1")))))))

(ert-deftest agent-todo-test-a-chosen-project-takes-the-task-name ()
  "Name the session after the TODO when its project was chosen, too."
  (agent-test-helper-with-directory root
    (agent-todo-test--with-sessions sessions
      (cl-letf (((symbol-function 'agent-project-read)
                 (lambda (_account _text _prompt callback &rest _)
                   (funcall callback root))))
        (agent-todo-test--start #'agent-act-on-thing-at-point
                                "* TODO Fix the build\n" "Fix the build"))
      (should (equal (agent-todo-test--instances sessions)
                     '("fix-the-build"))))))

(ert-deftest agent-todo-test-another-thing-is-named-as-before ()
  "Leave the name of a session started for a thing that is no TODO.
The first in a directory is the default instance, and the second has its
name read."
  (agent-test-helper-with-directory root
    (agent-todo-test--with-sessions sessions
      (let ((extractor (lambda (callback)
                         (funcall callback (list :directory root
                                                 :payload "Look"
                                                 :submit t))))
            asked)
        (agent--act-on-context extractor nil)
        (should (equal (agent-todo-test--instances sessions) '(nil)))
        (should-error (agent--act-on-context extractor nil))
        (cl-letf (((symbol-function 'read-string)
                   (lambda (&rest _) (setq asked t) "")))
          (agent--act-on-context extractor nil))
        (should asked)
        (should (equal (agent-todo-test--instances sessions)
                       '(nil "new-1")))))))

(ert-deftest agent-todo-test-a-running-session-keeps-its-name ()
  "Send a TODO to a running session without starting or naming one."
  (agent-todo-test--with-sessions sessions
    (let (sent)
      (cl-letf (((symbol-function 'agent--read-session-buffer)
                 (lambda () (current-buffer)))
                ((symbol-function 'agent-submit)
                 (lambda (payload _buffer) (setq sent payload))))
        (agent-todo-test--start (lambda () (agent-send-todo-at-point '(4)))
                                "* TODO Fix the build\n" "Fix the build"))
      (should (equal sent "Fix the build"))
      (should-not sessions))))

(ert-deftest agent-todo-test-missing-directory-leaves-the-project-choice ()
  "Choose the project from the TODO's text when its directory is gone.
The project is read from the sources of the account selected, with
nothing suggested, and the session starts in the one chosen."
  (agent-test-helper-with-directory root
    (let ((agent-todo-directory-property "DIR")
          asked started)
      (cl-letf (((symbol-function 'agent--resolve-backend) (lambda () 'test))
                ((symbol-function 'agent-account-current) (lambda (_) "work"))
                ((symbol-function 'agent-project-read)
                 (lambda (account text _prompt callback &optional suggestion)
                   (setq asked (list account text suggestion))
                   (funcall callback root)))
                ((symbol-function 'agent--start-session-in)
                 (lambda (_backend directory &optional prompt _name)
                   (setq started (list directory prompt))
                   (current-buffer)))
                ((symbol-function 'display-buffer) #'ignore))
        (agent-test-helper-with-messages messages
          (agent-todo-test--at "Do it"
              (format "* TODO Do it\n:PROPERTIES:\n:DIR: %s\n:END:\n"
                      (expand-file-name "gone" root))
            (agent-act-on-thing-at-point))
          (should (string-match-p "Ignoring the DIR property" messages))))
      (should (equal asked '("work" "Do it" nil)))
      (should (equal started (list root "Do it"))))))

;;;; Submit property

(ert-deftest agent-todo-test-ready-prompt-reads-the-heading-alone ()
  "Mark a TODO as a ready prompt by its own property, whatever its value.
A property on a heading above marks nothing below it, and neither does
one whose value is \"nil\"."
  (let ((contents "* Project
:PROPERTIES:
:BRIEF: t
:END:
** TODO Briefed task
:PROPERTIES:
:BRIEF: 2026-11-17
:END:
** TODO Bare task
** TODO Valueless task
:PROPERTIES:
:BRIEF:
:END:
** TODO Declined task
:PROPERTIES:
:BRIEF: nil
:END:
"))
    (let ((agent-todo-submit-property "BRIEF"))
      (should (eq (agent-todo-test--at "Briefed task" contents
                    (agent-todo-ready-prompt-p))
                  t))
      (should (agent-todo-test--at "Valueless task" contents
                (agent-todo-ready-prompt-p)))
      (should-not (agent-todo-test--at "Bare task" contents
                    (agent-todo-ready-prompt-p)))
      (should-not (agent-todo-test--at "Declined task" contents
                    (agent-todo-ready-prompt-p))))
    (let ((agent-todo-submit-property nil))
      (should-not (agent-todo-test--at "Briefed task" contents
                    (agent-todo-ready-prompt-p))))))

(provide 'agent-todo-test)
;;; agent-todo-test.el ends here
