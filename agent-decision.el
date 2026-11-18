;;; agent-decision.el --- Decisions proposed on Org tasks -*- lexical-binding: t -*-

;; Copyright (C) 2026

;; Author: Pablo Stafforini
;; URL: https://github.com/benthamite/agent
;; Version: 0.1
;; Package-Requires: ((emacs "30.0") (org "9.6"))

;; This file is NOT part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; A decision is a record on an Org task of what only the user can
;; decide: one or more items, each a question with its options, one of
;; them perhaps recommended, with the reason.  Each option has an effect,
;; which says what choosing it does.  The record is one line of JSON in
;; the task's property `agent-decision-property', whoever proposed it: a
;; program that files tasks, or a session that needs the user.
;;
;; This file holds what is generic about a decision: reading and writing
;; the record, the block that shows it at the top of the task's body, the
;; states it goes through, and the prompt that reads the user's answer
;; from the keyboard.  Carrying an answer out, which can start or resume
;; a session, is `agent-auto''s; see `agent-decide'.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'subr-x)

;;;; Customization

(defgroup agent-decision nil
  "Decisions proposed on Org tasks, and the user's answers."
  :group 'agent)

(defcustom agent-decision-property "AGENT_DECISION"
  "Org property holding the decision proposed on a task.
Its value is one line of JSON, a record whose shape whoever proposes a
decision follows: `id', `proposer' (\"engine\" or \"session\"),
`source', `basis' and `items'.  Each item has `question', `options',
`recommended', the index of the recommended option or null, and `why'.
Each option has `label' and `effect'.  An effect has `kind', one of
\"session\", \"send\" and \"command\": \"session\" and \"send\" carry
an `instruction', \"send\" also `to' and `to_label', the conversation
the text goes to, and may carry `text', its first draft; \"command\"
names a `command'.  The answer adds `state', `answer' and `answered_at'."
  :type 'string
  :group 'agent-decision)

(defcustom agent-decision-commands nil
  "Commands a decision may run as the effect of an option.
A decision naming any other command is refused, and none of its options
can be chosen.  Each command is called interactively with point on the
task's heading, and asks no confirmation of its own: the answer is the
confirmation."
  :type '(repeat function)
  :group 'agent-decision)

(defcustom agent-decision-stale-functions nil
  "Abnormal hook telling whether an open decision rests on what has changed.
Each function is called with the decision, a record as
`agent-decision-read' returns it, and with point on the task's heading.
A function that returns a string says that the decision is stale and
why, and the decision cannot be answered.  A decision a session proposed
is checked by `agent-auto' itself: it goes stale when the session works
on after proposing it."
  :type 'hook
  :group 'agent-decision)

(defcustom agent-decision-task-functions nil
  "Abnormal hook finding the Org task of the thing at point.
`agent-decide' calls each function with no arguments, in the buffer it
was called in, until one returns a marker at a task's heading.  This is
for buffers that show a task without being an Org buffer or an agenda.
With no function, or none that answers, the task is the heading at
point, or the one the agenda line at point shows."
  :type 'hook
  :group 'agent-decision)

(defcustom agent-decision-comment-function nil
  "Function that takes the user's comment on a decision a program proposed.
A comment on a decision a session proposed goes to that session.  A
decision with any other proposer can be commented on only when this is
a function, and it is called twice: with the record and nil, when the
prompt opens, to ask whether the decision takes comments, which it does
when the function returns non-nil; and with the record and the comment,
which it passes on.  Point is on the task's heading both times.  Nil
offers no comment on such a decision."
  :type '(choice (const :tag "No comments" nil) function)
  :group 'agent-decision)

(defcustom agent-decision-functions nil
  "Abnormal hook run each time a decision changes its state.
Each function is called with the decision as it now is, with point on
the task's heading.  A decision the user drops is passed with the state
\"dropped\", just before it is removed from the task.  A program that
proposed the decision can thus record what came of it."
  :type 'hook
  :group 'agent-decision)

(defconst agent-decision-shown-property "AGENT_DECISION_SHOWN"
  "Org property recording which record the decision block of a task shows.
Its value is the record's id and a hash of the property's value, so the
block is shown again when the record changes, and only then: the drafts
the user edited in the block are his until the record changes.")

(defconst agent-decision-states
  '("open" "answered" "carrying-out" "done" "failed" "uncertain")
  "The states of a decision, in the order it goes through them.
Only an open decision can be answered.  An answer that could not be
carried out puts the decision back as open, saying why.")

;;;; The record

(defun agent-decision-parse (string)
  "Return the decision STRING holds as JSON, or nil when it holds none.
The record is an alist with symbol keys.  An array is a vector and a
JSON null is `:null', so that the record is written back as it was."
  (when (and (stringp string) (not (string-blank-p string)))
    (condition-case nil
        (let ((record (json-parse-string string :object-type 'alist
                                         :null-object :null
                                         :false-object :false)))
          (and (consp record) record))
      (json-error nil))))

(defun agent-decision-serialize (record)
  "Return RECORD, a decision, as one line of JSON.
`json-serialize' returns UTF-8 bytes, which are decoded, so that text
other than ASCII reaches the Org property as the characters it is."
  (decode-coding-string
   (json-serialize record :null-object :null :false-object :false)
   'utf-8))

(defun agent-decision-get (record key)
  "Return the value of KEY in RECORD, or nil when it is missing or null."
  (let ((value (alist-get key record)))
    (unless (memq value '(:null :false))
      value)))

(defun agent-decision-put (record key value)
  "Return a copy of RECORD whose KEY is VALUE.
A key RECORD has keeps its place, and a new one goes at the end."
  (if (assq key record)
      (mapcar (lambda (pair)
                (if (eq (car pair) key) (cons key value) pair))
              record)
    (append record (list (cons key value)))))

(defun agent-decision-items (record)
  "Return the items of RECORD as a list."
  (append (agent-decision-get record 'items) nil))

(defun agent-decision-options (item)
  "Return the options of ITEM, an item of a decision, as a list."
  (append (agent-decision-get item 'options) nil))

(defun agent-decision-effect (option)
  "Return the effect of OPTION, an option of a decision."
  (agent-decision-get option 'effect))

(defun agent-decision-kind (effect)
  "Return the kind of EFFECT, as a string."
  (agent-decision-get effect 'kind))

(defun agent-decision-state (record)
  "Return the state of RECORD; a decision that names none is open."
  (or (agent-decision-get record 'state) "open"))

(defun agent-decision-recommended (item)
  "Return the index of the option ITEM recommends, or nil."
  (let ((index (agent-decision-get item 'recommended)))
    (and (natnump index)
         (< index (length (agent-decision-options item)))
         index)))

(defun agent-decision-problem (record)
  "Return why RECORD is not a decision that can be shown, or nil.
It must have an id and at least one item; every item a question and at
least one option; and every option a label and an effect of a known
kind, with what that kind needs."
  (let ((items (agent-decision-items record)))
    (cond
     ((not (stringp (agent-decision-get record 'id))) "it has no id")
     ((null items) "it has no item")
     (t (seq-some #'agent-decision--item-problem items)))))

(defun agent-decision--item-problem (item)
  "Return why ITEM is not an item of a decision, or nil."
  (let ((options (and (consp item) (agent-decision-options item))))
    (cond
     ((not (stringp (agent-decision-get item 'question)))
      "an item has no question")
     ((null options) "an item has no option")
     ((let ((index (agent-decision-get item 'recommended)))
        (and index (not (and (natnump index) (< index (length options))))))
      "an item recommends an option it does not have")
     (t (seq-some #'agent-decision--option-problem options)))))

(defun agent-decision--option-problem (option)
  "Return why OPTION is not an option of a decision, or nil."
  (let ((effect (and (consp option) (agent-decision-effect option))))
    (cond
     ((not (stringp (agent-decision-get option 'label)))
      "an option has no label")
     ((not (consp effect)) "an option has no effect")
     (t (pcase (agent-decision-kind effect)
          ("session" (unless (stringp (agent-decision-get effect 'instruction))
                       "a session effect has no instruction"))
          ("send" (unless (and (stringp (agent-decision-get effect 'to))
                               (stringp (agent-decision-get effect 'instruction)))
                    "a send effect names no conversation or no instruction"))
          ("command" (unless (stringp (agent-decision-get effect 'command))
                       "a command effect names no command"))
          (kind (format "an effect has the unknown kind %S" kind)))))))

(defun agent-decision-refused-commands (record)
  "Return the commands RECORD names that `agent-decision-commands' lacks."
  (let (refused)
    (dolist (item (agent-decision-items record))
      (dolist (option (agent-decision-options item))
        (let ((effect (agent-decision-effect option)))
          (when (equal (agent-decision-kind effect) "command")
            (let ((name (agent-decision-get effect 'command)))
              (unless (memq (intern-soft name) agent-decision-commands)
                (cl-pushnew name refused :test #'equal)))))))
    (nreverse refused)))

(defun agent-decision-sends (record)
  "Return each send effect of RECORD as a list (ITEM OPTION EFFECT).
ITEM and OPTION are indices.  The order is that of the record, which is
the order of the drafts in the block."
  (let ((sends nil) (i 0))
    (dolist (item (agent-decision-items record))
      (let ((j 0))
        (dolist (option (agent-decision-options item))
          (let ((effect (agent-decision-effect option)))
            (when (equal (agent-decision-kind effect) "send")
              (push (list i j effect) sends)))
          (setq j (1+ j))))
      (setq i (1+ i)))
    (nreverse sends)))

(defun agent-decision-display-order (item)
  "Return the indices of ITEM's options in the order they are shown.
The recommended option comes first, the others follow in their order."
  (let ((recommended (agent-decision-recommended item))
        (indices (number-sequence 0 (1- (length (agent-decision-options item))))))
    (if recommended
        (cons recommended (delq recommended indices))
      indices)))

(defun agent-decision-time ()
  "Return the time now as the record writes it."
  (format-time-string "%FT%T%z"))

;;;; The record on its task

(defun agent-decision-read ()
  "Return the decision the task at point records, or nil."
  (agent-decision-parse (org-entry-get nil agent-decision-property)))

(defun agent-decision-write (record)
  "Make RECORD the decision of the task at point, and show it.
A nil RECORD removes the decision and its block.  Every function in
`agent-decision-functions' is told when the state changed."
  (let ((before (agent-decision-read))
        (inhibit-message t))
    (if record
        (org-entry-put nil agent-decision-property
                       (agent-decision-serialize record))
      (org-entry-delete nil agent-decision-property))
    (agent-decision-render)
    (when (and record
               (not (and before
                         (equal (agent-decision-get before 'id)
                                (agent-decision-get record 'id))
                         (equal (agent-decision-state before)
                                (agent-decision-state record)))))
      (save-excursion
        (run-hook-with-args 'agent-decision-functions record)))))

(defun agent-decision-update (function)
  "Replace the decision of the task at point by what FUNCTION returns.
FUNCTION is called with the record and returns the new one.  Nothing is
done when the task records no decision.  Return the new record."
  (when-let* ((record (agent-decision-read)))
    (let ((new (funcall function record)))
      (agent-decision-write new)
      new)))

(defun agent-decision-drop ()
  "Remove the decision of the task at point, telling who wants to know.
The functions of `agent-decision-functions' get it with the state
\"dropped\" first."
  (when-let* ((record (agent-decision-read)))
    (save-excursion
      (run-hook-with-args 'agent-decision-functions
                          (agent-decision-put record 'state "dropped")))
    (agent-decision-write nil)))

;;;; The block

(defun agent-decision-render ()
  "Show the decision of the task at point in a block at the top of its body.
The block is `#+begin_decision' to `#+end_decision', right after the
heading's planning line and drawers.  It is written again only when the
record changed since it was last written, as
`agent-decision-shown-property' tells; the drafts in it are kept while
the record is the same open decision, since they are the user's to edit.
A task whose decision is gone loses its block."
  (save-excursion
    (org-back-to-heading t)
    (let* ((value (org-entry-get nil agent-decision-property))
           (record (agent-decision-parse value))
           (shown (org-entry-get nil agent-decision-shown-property))
           (stamp (and record (agent-decision--stamp record value))))
      (cond
       ((null record)
        (when shown
          (agent-decision--replace-block nil)
          (org-entry-delete nil agent-decision-shown-property)))
       ((or (not (equal shown stamp)) (not (agent-decision--block-bounds)))
        (let ((drafts (and shown
                           (equal (car (split-string shown))
                                  (agent-decision-get record 'id))
                           (agent-decision-block-drafts))))
          (org-entry-put nil agent-decision-shown-property stamp)
          (agent-decision--replace-block
           (agent-decision-block-text record drafts))))))))

(defun agent-decision--stamp (record value)
  "Return what `agent-decision-shown-property' holds for RECORD.
VALUE is the property's text, from which RECORD was read."
  (format "%s %s" (agent-decision-get record 'id)
          (substring (secure-hash 'md5 value) 0 12)))

(defun agent-decision--block-bounds ()
  "Return (START . END) of the decision block of the task at point, or nil.
START is where its first line begins and END is after its last line.
Point is on the task's heading."
  (save-excursion
    (let ((limit (save-excursion (outline-next-heading) (point))))
      (org-end-of-meta-data t)
      (let ((case-fold-search t))
        (when (and (< (point) limit)
                   (looking-at "^[ \t]*#\\+begin_decision\\b"))
          (let ((start (point)))
            (when (re-search-forward "^[ \t]*#\\+end_decision\\b.*$" limit t)
              (cons start (min (1+ (point)) (point-max))))))))))

(defun agent-decision--replace-block (text)
  "Replace the decision block of the task at point with TEXT.
A nil TEXT removes the block.  A task without a block gets one at the
top of its body."
  (save-excursion
    (let ((bounds (agent-decision--block-bounds)))
      (if bounds
          (progn (goto-char (car bounds))
                 (delete-region (car bounds) (cdr bounds)))
        (org-end-of-meta-data t)
        (unless (bolp) (insert "\n")))
      (when text
        (insert text)))))

(defun agent-decision-block-drafts ()
  "Return the drafts in the decision block of the task at point, in order.
Each is the text of an example block inside the decision block."
  (when-let* ((bounds (agent-decision--block-bounds)))
    (save-excursion
      (goto-char (car bounds))
      (let ((case-fold-search t) drafts)
        (while (re-search-forward "^[ \t]*#\\+begin_example\\b.*\n" (cdr bounds) t)
          (let ((start (point)))
            (when (re-search-forward "^[ \t]*#\\+end_example\\b" (cdr bounds) t)
              (push (org-unescape-code-in-string
                     (string-remove-suffix
                      "\n" (buffer-substring-no-properties
                            start (line-beginning-position))))
                    drafts))))
        (nreverse drafts)))))

(defun agent-decision-drafts (record &optional drafts)
  "Return the text of each send effect of RECORD, as `agent-decision-sends'.
The result is an alist from (ITEM . OPTION) to the text.  DRAFTS, the
drafts of the block in order, are taken first; a send with no draft has
its record's `text', else an empty string."
  (let ((k 0) result)
    (pcase-dolist (`(,i ,j ,effect) (agent-decision-sends record))
      (push (cons (cons i j)
                  (or (nth k drafts) (agent-decision-get effect 'text) ""))
            result)
      (setq k (1+ k)))
    (nreverse result)))

(defun agent-decision-block-text (record &optional drafts)
  "Return the decision block of RECORD, ending with a newline.
DRAFTS are the drafts to show for its send effects, in order; see
`agent-decision-drafts'.  An answered decision shows what was answered,
and the text that was approved in place of the draft.  A record that is
no decision that can be shown says so in the block, and why."
  (if-let* ((problem (agent-decision-problem record)))
      (format "#+begin_decision\nThis decision cannot be shown: %s.\n#+end_decision\n"
              problem)
    (agent-decision--valid-block-text record drafts)))

(defun agent-decision--valid-block-text (record drafts)
  "Return the decision block of RECORD, a valid decision, with DRAFTS.
See `agent-decision-block-text'."
  (let* ((answered (agent-decision--answered-texts record))
         (texts (append answered (agent-decision-drafts record drafts)))
         (items (agent-decision-items record))
         (count (length items)))
    (concat "#+begin_decision\n"
            (agent-decision--status-text record)
            (mapconcat
             (lambda (index)
               (agent-decision--item-text (nth index items) index count texts))
             (number-sequence 0 (1- count))
             "\n")
            "#+end_decision\n")))

(defun agent-decision--answered-texts (record)
  "Return the texts RECORD's answer approved, as `agent-decision-drafts' does."
  (delq nil (mapcar (lambda (choice)
                      (when-let* ((text (agent-decision-get choice 'text)))
                        (cons (cons (agent-decision-get choice 'item)
                                    (agent-decision-get choice 'option))
                              text)))
                    (agent-decision-get record 'answer))))

(defun agent-decision--status-text (record)
  "Return the lines saying where RECORD stands, or an empty string."
  (let ((state (agent-decision-state record))
        (answer (agent-decision--answer-summary record)))
    (concat
     (when-let* ((failure (agent-decision-get record 'failure)))
       (format "The last answer could not be carried out: %s\n" failure))
     (when-let* (((equal state "open"))
                 (stale (agent-decision-get record 'stale)))
       (format "Stale: %s.\n" stale))
     (unless (equal state "open")
       (format "Answered%s: %s.  %s\n"
               (if-let* ((time (agent-decision-get record 'answered_at)))
                   (concat " " time)
                 "")
               answer
               (pcase state
                 ((or "answered" "carrying-out") "Being carried out.")
                 ("done" "Carried out.")
                 ("failed" (format "Not carried out%s."
                                   (agent-decision--outcome record)))
                 ("uncertain" (format "Outcome uncertain%s; nothing resends it."
                                      (agent-decision--outcome record)))
                 (_ "")))))))

(defun agent-decision--outcome (record)
  "Return \": OUTCOME\" for the outcome RECORD names, or an empty string."
  (if-let* ((outcome (agent-decision-get record 'outcome)))
      (concat ": " outcome)
    ""))

(defun agent-decision--answer-summary (record)
  "Return the answer of RECORD in a few words."
  (if-let* ((comment (agent-decision-get record 'comment)))
      (format "commented, %S" comment)
    (mapconcat (lambda (choice) (or (agent-decision-get choice 'label) "?"))
               (agent-decision-get record 'answer) "; ")))

(defun agent-decision--item-text (item index count texts)
  "Return the lines of ITEM, item INDEX of COUNT, in the block.
TEXTS maps (ITEM . OPTION) to the text of a send; see
`agent-decision-drafts'."
  (let ((options (agent-decision-options item))
        (recommended (agent-decision-recommended item))
        (n 0))
    (concat
     (if (> count 1)
         (format "Question %d of %d: %s\n" (1+ index) count
                 (agent-decision-get item 'question))
       (format "%s\n" (agent-decision-get item 'question)))
     (mapconcat (lambda (j)
                  (setq n (1+ n))
                  (format "%d. %s%s\n" n
                          (agent-decision-get (nth j options) 'label)
                          (if (eql j recommended) " (recommended)" "")))
                (agent-decision-display-order item) "")
     (when-let* ((why (agent-decision-get item 'why)))
       (format "Why: %s\n" why))
     (mapconcat (lambda (j)
                  (let ((effect (agent-decision-effect (nth j options))))
                    (if (equal (agent-decision-kind effect) "send")
                        (format "Draft of “%s”, to %s (edit it here before answering):\n#+begin_example\n%s#+end_example\n"
                                (agent-decision-get (nth j options) 'label)
                                (agent-decision--to-label effect)
                                (agent-decision--example-body
                                 (alist-get (cons index j) texts nil nil #'equal)))
                      "")))
                (number-sequence 0 (1- (length options))) ""))))

(defun agent-decision--to-label (effect)
  "Return the name of the conversation the send EFFECT goes to."
  (or (agent-decision-get effect 'to_label) (agent-decision-get effect 'to)))

(defun agent-decision--example-body (text)
  "Return TEXT as the body of an example block, ending with a newline."
  (let ((body (org-escape-code-in-string (or text ""))))
    (if (or (string-empty-p body) (string-suffix-p "\n" body))
        body
      (concat body "\n"))))

;;;; The answer

(defun agent-decision-from-keyboard-p (command)
  "Return non-nil when COMMAND was called from the keyboard by the command loop.
That is when it is `this-command', the last input event is a keyboard
event, and nothing has inhibited quitting, as Emacs does for the code
of a timer or of a process filter, which is where a command evaluated
through `emacsclient' runs."
  (and (eq this-command command)
       (not inhibit-quit)
       (or (integerp last-input-event)
           (and (symbolp last-input-event) last-input-event t))))

(defun agent-decision-read-answer (record drafts &optional comments)
  "Read from the keyboard the user's answer to RECORD, a decision.
DRAFTS maps each send of RECORD to the text it would send, as
`agent-decision-drafts' returns it; the prompt shows the text with the
option.  The items are taken in order.  For each, \\`RET' takes the
recommended option and a digit the option shown with it; an item with
no recommendation needs a digit.  \\`x' drops the decision, \\`c', when
COMMENTS is non-nil, reads a comment instead of an answer, and \\`C-g'
quits, so that nothing is answered.

Return (answer . CHOICES), where CHOICES is a list of (ITEM . OPTION),
one for each item, as indices into the record; (comment . TEXT); or
\(drop)."
  (let* ((items (agent-decision-items record))
         (count (length items))
         (index 0)
         choices)
    (catch 'done
      (dolist (item items)
        (let ((choice (agent-decision--read-item item index count drafts
                                                 comments)))
          (if (consp choice)
              (throw 'done choice)
            (push (cons index choice) choices)))
        (setq index (1+ index)))
      (cons 'answer (nreverse choices)))))

(defun agent-decision--read-item (item index count drafts comments)
  "Read the option chosen for ITEM, item INDEX of COUNT, and return its index.
Return a cons instead for a comment or a drop; see
`agent-decision-read-answer', which says what DRAFTS and COMMENTS are."
  (let* ((order (agent-decision-display-order item))
         (recommended (agent-decision-recommended item))
         (prompt (agent-decision--item-prompt item index count drafts comments))
         (problem nil)
         result)
    (while (not result)
      (let ((key (read-key (if problem (concat problem "\n" prompt) prompt))))
        (setq problem nil)
        (cond
         ((eql key ?\C-g) (keyboard-quit))
         ((memq key '(13 return))
          (if recommended
              (setq result (list recommended))
            (setq problem "This question has no recommendation: choose a number.")))
         ((and (integerp key) (<= ?1 key ?9) (<= (- key ?0) (length order)))
          (setq result (list (nth (- key ?1) order))))
         ((eq key ?x) (setq result (list '(drop))))
         ((and comments (eq key ?c))
          (let ((text (string-trim (read-string "Comment: "))))
            (if (string-empty-p text)
                (setq problem "The comment was empty.")
              (setq result (list (cons 'comment text))))))
         (t (setq problem "Not a choice.")))))
    (car result)))

(defun agent-decision--item-prompt (item index count drafts comments)
  "Return the prompt for ITEM, item INDEX of COUNT.
DRAFTS and COMMENTS are as for `agent-decision-read-answer'."
  (let ((options (agent-decision-options item))
        (recommended (agent-decision-recommended item))
        (n 0))
    (concat
     (if (> count 1)
         (format "Decision, question %d of %d: " (1+ index) count)
       "Decision: ")
     (agent-decision-get item 'question) "\n"
     (mapconcat
      (lambda (j)
        (let* ((option (nth j options))
               (effect (agent-decision-effect option)))
          (setq n (1+ n))
          (concat
           (format "  %d. %s%s\n" n (agent-decision-get option 'label)
                   (if (eql j recommended) " (recommended)" ""))
           (when (equal (agent-decision-kind effect) "send")
             (concat (format "     sends to %s exactly:\n"
                             (agent-decision--to-label effect))
                     (mapconcat (lambda (line) (concat "     | " line "\n"))
                                (split-string
                                 (or (alist-get (cons index j) drafts
                                                nil nil #'equal)
                                     "")
                                 "\n")
                                ""))))))
      (agent-decision-display-order item) "")
     (when-let* ((why (agent-decision-get item 'why)))
       (format "Why: %s\n" why))
     (format "%s%s, x drops the decision%s, C-g cancels: "
             (if recommended "RET takes the recommendation, " "")
             (if (= (length options) 1) "1 chooses" (format "1-%d choose" (length options)))
             (if comments ", c comments" "")))))

(defun agent-decision-answer (record choices drafts)
  "Return RECORD answered with CHOICES, now.
CHOICES is a list of (ITEM . OPTION), as `agent-decision-read-answer'
returns it.  DRAFTS maps each send to its text, which the answer keeps:
it is the text the user approved, and the one that is sent."
  (let ((items (agent-decision-items record)))
    (thread-first
      record
      (agent-decision-put 'state "answered")
      (agent-decision-put 'answered_at (agent-decision-time))
      (agent-decision-put
       'answer
       (vconcat
        (mapcar (pcase-lambda (`(,i . ,j))
                  (let* ((option (nth j (agent-decision-options (nth i items))))
                         (send (equal (agent-decision-kind
                                       (agent-decision-effect option))
                                      "send")))
                    (append `((item . ,i) (option . ,j)
                              (label . ,(agent-decision-get option 'label)))
                            (when send
                              `((text . ,(alist-get (cons i j) drafts
                                                    nil nil #'equal)))))))
                choices)))
      (agent-decision--forget 'failure)
      (agent-decision--forget 'stale))))

(defun agent-decision-comment (record text)
  "Return RECORD answered, now, with the comment TEXT instead of a choice."
  (thread-first
    record
    (agent-decision-put 'state "answered")
    (agent-decision-put 'answered_at (agent-decision-time))
    (agent-decision-put 'comment text)
    (agent-decision--forget 'failure)
    (agent-decision--forget 'stale)))

(defun agent-decision--forget (record key)
  "Return RECORD without KEY."
  (seq-remove (lambda (pair) (eq (car pair) key)) record))

(defun agent-decision-reopen (record reason)
  "Return RECORD open again, its answer not carried out for REASON."
  (thread-first
    record
    (agent-decision-put 'state "open")
    (agent-decision-put 'failure reason)
    (agent-decision--forget 'answer)
    (agent-decision--forget 'answered_at)
    (agent-decision--forget 'comment)))

(defun agent-decision-chosen (record)
  "Return the options RECORD's answer chose, as a list of (ITEM OPTION TEXT).
ITEM and OPTION are the item and the option themselves, and TEXT is the
text approved for a send, or nil."
  (let ((items (agent-decision-items record)))
    (mapcar (lambda (choice)
              (let ((item (nth (agent-decision-get choice 'item) items)))
                (list item
                      (nth (agent-decision-get choice 'option)
                           (agent-decision-options item))
                      (agent-decision-get choice 'text))))
            (agent-decision-get record 'answer))))

(provide 'agent-decision)

;;; agent-decision.el ends here
