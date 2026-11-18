;;; agent-decision-test.el --- Tests for agent-decision -*- lexical-binding: t -*-

;; Tests for the record of a decision on an Org task, its block and the
;; prompt that reads the user's answer.

;;; Code:

(require 'ert)
(require 'org)
(require 'agent-decision)

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

(defmacro agent-decision-test--keys (keys &rest body)
  "Evaluate BODY with KEYS, a list of events, waiting to be read."
  (declare (indent 1) (debug (form body)))
  `(let ((unread-command-events ,keys))
     ,@body))

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
  "Keep text other than ASCII through the property and the block."
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
    (should (string-search "1. Sí ✓\n" (agent-decision-test--body)))))

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

;;;; The block

(ert-deftest agent-decision-test-block-at-top-of-body ()
  "Show the decision in a block after the drawers, before the body.
The recommended option comes first and is marked, and the draft of the
send is in an example block, escaped as Org escapes one."
  (agent-decision-test--in-task agent-decision-test--reply
    (agent-decision-render)
    (should (equal (agent-decision-test--body)
                   "#+begin_decision
Send this reply?
1. Send it (recommended)
2. Work on it in a session
3. Nothing needed
Why: It answers him.
Draft of “Send it”, to Ann, chat (edit it here before answering):
#+begin_example
Hello Ann.
,* Not a heading
#+end_example
#+end_decision
The body.
"))
    (should (equal (agent-decision-block-drafts)
                   '("Hello Ann.\n* Not a heading")))))

(ert-deftest agent-decision-test-block-follows-the-property ()
  "Show the block again when the record changes, and only then.
The user's edit of the draft stays while the record is the same
decision, whatever else of it changes; a new decision brings its own
draft; and a task whose decision is gone loses its block."
  (agent-decision-test--in-task agent-decision-test--reply
    (agent-decision-render)
    (save-excursion
      (search-forward "#+begin_example")
      (search-forward "Hello Ann.")
      (replace-match "Hi Ann, edited." t t))
    (agent-decision-render)
    (should (equal (car (agent-decision-block-drafts))
                   "Hi Ann, edited.\n* Not a heading"))
    (agent-decision-write (agent-decision-put (agent-decision-read)
                                              'stale "a newer message"))
    (should (string-search "Stale: a newer message." (agent-decision-test--body)))
    (should (equal (car (agent-decision-block-drafts))
                   "Hi Ann, edited.\n* Not a heading"))
    (agent-decision-write (agent-decision-put (agent-decision-read) 'id "d2"))
    (should (equal (car (agent-decision-block-drafts))
                   "Hello Ann.\n* Not a heading"))
    (should (= (how-many "#\\+begin_decision" (point-min) (point-max)) 1))
    (agent-decision-write nil)
    (should (equal (agent-decision-test--body) "The body.\n"))
    (should-not (org-entry-get nil agent-decision-shown-property))))

(ert-deftest agent-decision-test-block-shows-the-answer ()
  "Show an answered decision with the text that was approved."
  (agent-decision-test--in-task agent-decision-test--reply
    (let* ((record (agent-decision-read))
           (drafts (agent-decision-drafts record '("Approved text."))))
      (agent-decision-write (agent-decision-put
                             (agent-decision-answer record '((0 . 0)) drafts)
                             'state "carrying-out"))
      (should (string-search ": Send it.  Being carried out."
                             (agent-decision-test--body)))
      (should (equal (agent-decision-block-drafts) '("Approved text."))))))

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
  "Answer three items: the recommendation, a digit, the recommendation.
The second item has no recommendation, so RET there is refused and asks
again.  The options are numbered as shown, the recommended one first."
  (let ((record (agent-decision-parse agent-decision-test--three)))
    (agent-decision-test--keys (list 13 13 ?2 13)
      (should (equal (agent-decision-read-answer record nil)
                     '(answer (0 . 1) (1 . 1) (2 . 0)))))
    (agent-decision-test--keys (list ?2 ?1 13)
      (should (equal (agent-decision-read-answer record nil)
                     '(answer (0 . 0) (1 . 0) (2 . 0)))))))

(ert-deftest agent-decision-test-cancel-before-the-last-item ()
  "Answer nothing when \\`C-g' comes before the last item is answered."
  (let ((record (agent-decision-parse agent-decision-test--three)))
    (agent-decision-test--keys (list 13 ?1 ?\C-g)
      (should (eq (condition-case nil
                      (agent-decision-read-answer record nil)
                    (quit 'quit))
                  'quit)))))

(ert-deftest agent-decision-test-comment-and-drop ()
  "Read a comment only when comments are taken, and a drop."
  (let ((record (agent-decision-parse agent-decision-test--reply)))
    (agent-decision-test--keys (list ?x)
      (should (equal (agent-decision-read-answer record nil t) '(drop))))
    (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "Shorter")))
      (agent-decision-test--keys (list ?c)
        (should (equal (agent-decision-read-answer record nil t)
                       '(comment . "Shorter"))))
      (agent-decision-test--keys (list ?c 13)
        (should (equal (agent-decision-read-answer record nil nil)
                       '(answer (0 . 0))))))))

(ert-deftest agent-decision-test-prompt-shows-the-draft ()
  "Show the conversation and the draft as they stand with the send option."
  (let* ((record (agent-decision-parse agent-decision-test--reply))
         (drafts (agent-decision-drafts record '("Hi.\nBye.")))
         (prompt nil))
    (cl-letf (((symbol-function 'read-key)
               (lambda (text) (setq prompt text) 13)))
      (agent-decision-read-answer record drafts))
    (should (string-search "sends to Ann, chat exactly:\n     | Hi.\n     | Bye.\n"
                           prompt))))

(ert-deftest agent-decision-test-answer-keeps-the-text ()
  "Keep with the answer the text the send was approved with."
  (let* ((record (agent-decision-parse agent-decision-test--reply))
         (drafts (agent-decision-drafts record '("Exactly this.")))
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
