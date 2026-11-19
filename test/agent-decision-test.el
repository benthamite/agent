;;; agent-decision-test.el --- Tests for agent-decision -*- lexical-binding: t -*-

;; Tests for the record of a decision on an Org task, the text of its
;; sends and the menu that reads the user's answer.

;;; Code:

(require 'ert)
(require 'org)
(require 'agent-decision)
(require 'agent-test-helper)

;;;; Fixtures

(defconst agent-decision-test--reply
  "{\"id\":\"d1\",\"proposer\":\"engine\",\"source\":\"src:145\",\"basis\":\"7\",\"items\":[{\"question\":\"Send this reply?\",\"recommended\":0,\"why\":\"It answers him.\",\"options\":[{\"label\":\"Send it\",\"effect\":{\"kind\":\"send\",\"to\":\"src:145\",\"to_label\":\"Ann, chat\",\"instruction\":\"Send it.\",\"text\":\"Hello Ann.\\n* Not a heading\"}},{\"label\":\"Work on it in a session\",\"effect\":{\"kind\":\"session\",\"instruction\":\"Rework it.\"}},{\"label\":\"Nothing needed\",\"effect\":{\"kind\":\"command\",\"command\":\"ignore\"}}]}]}"
  "A decision of one item whose recommended option sends a draft.")

(defconst agent-decision-test--three
  "{\"id\":\"d3\",\"proposer\":\"session\",\"source\":\"sid-1\",\"basis\":\"b\",\"items\":[{\"question\":\"First?\",\"recommended\":1,\"options\":[{\"label\":\"A\",\"effect\":{\"kind\":\"session\",\"instruction\":\"a\"}},{\"label\":\"B\",\"effect\":{\"kind\":\"session\",\"instruction\":\"b\"}}]},{\"question\":\"Second?\",\"recommended\":null,\"options\":[{\"label\":\"C\",\"effect\":{\"kind\":\"session\",\"instruction\":\"c\"}},{\"label\":\"D\",\"effect\":{\"kind\":\"session\",\"instruction\":\"d\"}}]},{\"question\":\"Third?\",\"recommended\":0,\"options\":[{\"label\":\"E\",\"effect\":{\"kind\":\"session\",\"instruction\":\"e\"}}]}]}"
  "A decision of three items, the second with no recommendation.")

(defmacro agent-decision-test--in-task (property &rest body)
  "Evaluate BODY in an Org buffer whose one task has the decision PROPERTY.
Point is on the task's heading."
  (declare (indent 1) (debug (form body)))
  `(with-temp-buffer
     (let ((org-log-into-drawer t))
       (org-mode)
       (insert "* TODO Reply to Ann\n:PROPERTIES:\n:ID: x\n:END:\n:LOGBOOK:\n- Note\n:END:\nThe body.\n* TODO Next\n")
       (goto-char (point-min))
       (when ,property
         (org-entry-put nil agent-decision-property ,property))
       (goto-char (point-min))
       ,@body)))

(defun agent-decision-test--body ()
  "Return the body of the task at point, after its drawers."
  (save-excursion
    (org-back-to-heading t)
    (org-end-of-meta-data t)
    (buffer-substring-no-properties
     (point) (save-excursion (outline-next-heading) (point)))))

(defun agent-decision-test--answer (record keys &optional drafts comments)
  "Return the answer to RECORD given with KEYS in its menu, or nil.
DRAFTS and COMMENTS are as for `agent-decision-ask'.  Nil means the menu
was quit, or KEYS ended, before the answer was complete."
  (let (reply)
    (funcall (agent-test-helper-decision-keys keys)
             record drafts comments (lambda (r) (setq reply r)))
    reply))

;;;; The record

(ert-deftest agent-decision-test-record-round-trip ()
  "Write a record back exactly as it was read, nulls included."
  (let ((record (agent-decision-parse agent-decision-test--three)))
    (should (equal (agent-decision-serialize record)
                   agent-decision-test--three))
    (should-not (agent-decision-problem record))
    (should (null (agent-decision-recommended
                   (nth 1 (agent-decision-items record)))))
    (should (equal (agent-decision-state record) "open"))))

(ert-deftest agent-decision-test-text-beyond-ascii ()
  "Keep text other than ASCII through the property, and out of the body."
  (agent-decision-test--in-task nil
    (agent-decision-write
     (agent-decision-put (agent-decision-parse agent-decision-test--reply)
                         'items
                         (vector `((question . "¿Enviar a Damián?")
                                   (options . [((label . "Sí ✓")
                                                (effect . ((kind . "session")
                                                           (instruction . "ñ"))))])))))
    (should (equal (agent-decision-get
                    (aref (agent-decision-get (agent-decision-read) 'items) 0)
                    'question)
                   "¿Enviar a Damián?"))
    (should (equal (agent-decision-test--body) "The body.\n"))))

(ert-deftest agent-decision-test-problems ()
  "Say why a record is no decision."
  (should (equal (agent-decision-problem '((id . "x") (items . [])))
                 "it has no item"))
  (should (string-match-p
           "unknown kind"
           (agent-decision-problem
            (agent-decision-parse
             "{\"id\":\"x\",\"items\":[{\"question\":\"q\",\"options\":[{\"label\":\"l\",\"effect\":{\"kind\":\"shell\"}}]}]}"))))
  (should-not (agent-decision-parse "not json")))

(ert-deftest agent-decision-test-refused-commands ()
  "Name the commands of a decision that are not on the list."
  (let ((record (agent-decision-parse agent-decision-test--reply)))
    (let ((agent-decision-commands nil))
      (should (equal (agent-decision-refused-commands record) '("ignore"))))
    (let ((agent-decision-commands '(ignore)))
      (should-not (agent-decision-refused-commands record)))))

;;;; The text of a send

(ert-deftest agent-decision-test-draft-from-the-hook ()
  "Take a send's text from the first function that gives a string.
A function that returns nil, or no function, leaves it to the next one,
then to the effect's own text.  Each is called with the effect, with
point on the task's heading."
  (agent-decision-test--in-task agent-decision-test--reply
    (let ((record (agent-decision-read)))
      (let ((agent-decision-draft-functions nil))
        (should (equal (agent-decision-drafts record)
                       '(((0 . 0) . "Hello Ann.\n* Not a heading")))))
      (let* ((seen nil)
             (agent-decision-draft-functions
              (list (lambda (effect)
                      (push (list (agent-decision-get effect 'to) (org-at-heading-p))
                            seen)
                      nil)
                    (lambda (_) "From the body.")
                    (lambda (_) "Never asked."))))
        (should (equal (agent-decision-drafts record)
                       '(((0 . 0) . "From the body."))))
        (should (equal seen '(("src:145" t))))))))

(ert-deftest agent-decision-test-write-leaves-the-body-alone ()
  "Write a decision, its states and its removal in the property only."
  (agent-decision-test--in-task nil
    (agent-decision-write (agent-decision-parse agent-decision-test--reply))
    (agent-decision-write (agent-decision-put (agent-decision-read)
                                              'state "answered"))
    (should (equal (agent-decision-test--body) "The body.\n"))
    (agent-decision-write nil)
    (should-not (org-entry-get nil agent-decision-property))
    (should (equal (agent-decision-test--body) "The body.\n"))))

(ert-deftest agent-decision-test-state-changes-are-told ()
  "Tell `agent-decision-functions' of each change of state, and of a drop."
  (agent-decision-test--in-task agent-decision-test--reply
    (let* ((seen nil)
           (agent-decision-functions
            (list (lambda (record)
                    (push (agent-decision-state record) seen)))))
      (agent-decision-write (agent-decision-put (agent-decision-read)
                                                'state "answered"))
      (agent-decision-write (agent-decision-put (agent-decision-read)
                                                'stale "x"))
      (agent-decision-drop)
      (should (equal (reverse seen) '("answered" "dropped")))
      (should-not (agent-decision-read)))))

;;;; The answer

(ert-deftest agent-decision-test-three-items ()
  "Answer three items, one menu each: the recommendation, a digit, the recommendation.
The second item has no recommendation, so its menu offers no RET.  The
options are numbered as shown, the recommended one first."
  (let ((record (agent-decision-parse agent-decision-test--three)))
    (should (equal (agent-decision-test--answer record '("RET" "2" "RET"))
                   '(answer (0 . 1) (1 . 1) (2 . 0))))
    (should (equal (agent-decision-test--answer record '("2" "1" "RET"))
                   '(answer (0 . 0) (1 . 0) (2 . 0))))
    (should (string-match-p "shows no key RET"
                            (cadr (should-error (agent-decision-test--answer
                                                 record '("RET" "RET"))))))))

(ert-deftest agent-decision-test-quit-before-the-last-item ()
  "Answer nothing when the menu is quit before the last item is answered."
  (let ((record (agent-decision-parse agent-decision-test--three)))
    (should-not (agent-decision-test--answer record '("RET" "1" "q")))
    (should-not (agent-decision-test--answer record '("RET" "1")))))

(ert-deftest agent-decision-test-comment-and-drop ()
  "Read a comment only when comments are taken, and a drop."
  (let ((record (agent-decision-parse agent-decision-test--reply)))
    (should (equal (agent-decision-test--answer record '("x") nil t) '(drop)))
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "Shorter")))
      (should (equal (agent-decision-test--answer record '("c") nil t)
                     '(comment . "Shorter")))
      (should-error (agent-decision-test--answer record '("c") nil nil)))
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "  ")))
      (should (string-match-p "empty"
                              (cadr (should-error
                                     (agent-decision-test--answer record '("c") nil t)
                                     :type 'user-error)))))))

(ert-deftest agent-decision-test-menu-shows-the-draft ()
  "Show the question, the reason, the options and, under a send, its text.
The recommended option is first and marked, and the text of the send
is shown under it with the conversation it goes to, as the drafts
give it, each of its lines kept."
  (let* ((record (agent-decision-parse agent-decision-test--reply))
         (asking (agent-decision--asking-create
                  :record record :drafts '(((0 . 0) . "Hi.\nBye."))))
         (specs (agent-decision--option-specs asking))
         (text (mapconcat (lambda (spec)
                            (substring-no-properties
                             (if (keywordp (car spec)) (cadr spec)
                               (concat (car spec) " " (cadr spec)))))
                          specs "\n")))
    (should (equal (agent-decision--heading asking) "Send this reply?"))
    ;; Transient puts one column before the first line of each.
    (should (equal text (concat "It answers him.\n \n"
                                "1 Send it  (recommended)\n"
                                "  To Ann, chat:\n   Hi.\n   Bye.\n \n"
                                "2 Work on it in a session\n"
                                "3 Nothing needed")))
    (should (equal (mapcar #'car (agent-decision--action-specs asking))
                   '("RET" "x" "q")))))

(ert-deftest agent-decision-test-menu-wraps-a-long-draft ()
  "Fill a long line of a draft to the frame, indented under its option."
  (let* ((long (string-join (make-list 40 "word") " "))
         (shown (agent-decision--send-text '((kind . "send") (to . "a")) long)))
    (should (> (length (split-string shown "\n")) 2))
    (dolist (line (butlast (cdr (split-string shown "\n"))))
      (should (string-prefix-p "   word" line))
      (should (<= (length line) 84)))
    (should (equal (string-join (mapcar #'string-trim
                                        (butlast (cdr (split-string shown "\n"))))
                                " ")
                   long))))

(ert-deftest agent-decision-test-menu-says-why-an-answer-failed ()
  "Say, above the reason, why the last answer could not be carried out."
  (let* ((record (agent-decision-reopen
                  (agent-decision-parse agent-decision-test--reply)
                  "start failed: no directory"))
         (specs (agent-decision--option-specs
                 (agent-decision--asking-create :record record))))
    (should (equal (substring-no-properties (cadr (car specs)))
                   "The last answer could not be carried out: start failed: no directory."))
    (should (string-search "It answers him." (cadr (cadr specs))))))

(ert-deftest agent-decision-test-menu-heading-counts-questions ()
  "Say which question of several the menu shows."
  (let ((asking (agent-decision--asking-create
                 :record (agent-decision-parse agent-decision-test--three)
                 :index 1)))
    (should (equal (substring-no-properties (agent-decision--heading asking))
                   "Second?  (question 2 of 3)"))))

(ert-deftest agent-decision-test-menu-only-from-the-keyboard ()
  "Refuse a key of the menu that a program calls, as through `emacsclient'.
The command loop calls a suffix with it as `this-command' and quitting
allowed; a program's call has another command, or quitting inhibited,
as in a process filter."
  (let* ((reply nil)
         (asking (agent-decision--asking-create
                  :record (agent-decision-parse agent-decision-test--reply)
                  :callback (lambda (r) (setq reply r)))))
    (cl-letf (((symbol-function 'agent-decision--menu-asking) (lambda () asking)))
      (let ((this-command 'eval-expression)
            (last-input-event ?1))
        (should-error (agent-decision--menu-act 'agent-decision-menu-accept '(accept))
                      :type 'user-error))
      (let ((this-command 'agent-decision-menu-accept)
            (last-input-event 13)
            (inhibit-quit t))
        (should-error (agent-decision--menu-act 'agent-decision-menu-accept '(accept))
                      :type 'user-error))
      (should-not reply)
      (let ((this-command 'agent-decision-menu-accept)
            (last-input-event 'return)
            (inhibit-quit nil))
        (agent-decision--menu-act 'agent-decision-menu-accept '(accept)))
      (should (equal reply '(answer (0 . 0)))))))

(ert-deftest agent-decision-test-answer-keeps-the-text ()
  "Keep with the answer the text the send was approved with."
  (let* ((record (agent-decision-parse agent-decision-test--reply))
         (drafts '(((0 . 0) . "Exactly this.")))
         (answered (agent-decision-answer record '((0 . 0)) drafts)))
    (should (equal (agent-decision-state answered) "answered"))
    (should (equal (nth 2 (car (agent-decision-chosen answered)))
                   "Exactly this."))
    (should (stringp (agent-decision-get answered 'answered_at)))))

(ert-deftest agent-decision-test-from-keyboard ()
  "Tell a command called from the keyboard from one a program calls.
A program's call, as through `emacsclient', runs with another command
or none as `this-command', and with quitting inhibited, as in a process
filter."
  (let ((this-command 'agent-decide)
        (last-input-event ?Y)
        (inhibit-quit nil))
    (should (agent-decision-from-keyboard-p 'agent-decide))
    (let ((inhibit-quit t))
      (should-not (agent-decision-from-keyboard-p 'agent-decide)))
    (let ((last-input-event nil))
      (should-not (agent-decision-from-keyboard-p 'agent-decide))))
  (let ((this-command nil)
        (last-input-event ?Y))
    (should-not (agent-decision-from-keyboard-p 'agent-decide))))

(provide 'agent-decision-test)

;;; agent-decision-test.el ends here
