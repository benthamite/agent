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
;; The record is data only: nothing of it is written in the task's body.
;; A send's text is read when the user opens the decision, from where
;; the program that proposed it keeps the draft (see
;; `agent-decision-draft-functions'), so that there is one copy of it,
;; which the user edits where it is.
;;
;; This file holds what is generic about a decision: reading and writing
;; the record, the states it goes through, and the menu that reads the
;; user's answer from the keyboard.  Carrying an answer out, which can
;; start or resume a session, is `agent-auto''s; see `agent-decide'.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'subr-x)
(require 'transient)

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
the text goes to, and may carry `text', its draft, which
`agent-decision-draft-functions' can supersede; \"command\" names a
`command'.  The answer adds `state', `answer' and `answered_at'.  The
record is data only: nothing of it is written in the task's body."
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
menu opens, to ask whether the decision takes comments, which it does
when the function returns non-nil; and with the record and the comment,
which it passes on.  Point is on the task's heading both times.  Nil
offers no comment on such a decision."
  :type '(choice (const :tag "No comments" nil) function)
  :group 'agent-decision)

(defcustom agent-decision-draft-functions nil
  "Abnormal hook giving the text a send would send.
Each function is called with the effect of an option that sends, an
alist as the record has it, with point on the task's heading, when the
user opens the decision.  The first string a function returns is the
text: the menu shows it under the option, and it is what the answer
keeps and the session is given to send, whatever happens to the task
afterwards.  A function returns nil for a send it does not know.  With
no string from any, the text is the effect's `text', else empty.  This
lets the program that proposed the decision keep the draft where the
user edits it, such as in the task's body, as the only copy."
  :type 'hook
  :group 'agent-decision)

(defcustom agent-decision-functions nil
  "Abnormal hook run each time a decision changes its state.
Each function is called with the decision as it now is, with point on
the task's heading.  A decision the user drops is passed with the state
\"dropped\", just before it is removed from the task.  A program that
proposed the decision can thus record what came of it."
  :type 'hook
  :group 'agent-decision)

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
the order in which the menu shows them."
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
  "Make RECORD the decision of the task at point.
A nil RECORD removes the decision.  Every function in
`agent-decision-functions' is told when the state changed."
  (let ((before (agent-decision-read))
        (inhibit-message t))
    (if record
        (org-entry-put nil agent-decision-property
                       (agent-decision-serialize record))
      (org-entry-delete nil agent-decision-property))
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

;;;; The text of a send

(defun agent-decision-drafts (record)
  "Return the text each send of RECORD would send, from the task at point.
The result is an alist from (ITEM . OPTION), indices into RECORD, to
the text, in the order of `agent-decision-sends'.  The text is the
first string a function of `agent-decision-draft-functions' returns
for the send's effect, else the effect's `text', else an empty string.
It is read once, when the user opens the decision: the menu shows it,
and it is the text the answer keeps and a session sends."
  (mapcar (pcase-lambda (`(,i ,j ,effect))
            (cons (cons i j) (agent-decision--draft effect)))
          (agent-decision-sends record)))

(defun agent-decision--draft (effect)
  "Return the text the send EFFECT would send, for the task at point.
See `agent-decision-drafts'."
  (or (save-excursion
        (run-hook-wrapped 'agent-decision-draft-functions
                          (lambda (function)
                            (let ((text (funcall function effect)))
                              (and (stringp text) text)))))
      (agent-decision-get effect 'text)
      ""))

(defun agent-decision--to-label (effect)
  "Return the name of the conversation the send EFFECT goes to."
  (or (agent-decision-get effect 'to_label) (agent-decision-get effect 'to)))

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

;;;; The menu

(cl-defstruct (agent-decision--asking
               (:constructor agent-decision--asking-create)
               (:copier nil))
  "A decision being answered in `agent-decision-menu'.
RECORD is the decision, DRAFTS the text of each of its sends, as
`agent-decision-drafts' returns it, COMMENTS non-nil when it takes a
comment and CALLBACK the function that gets the answer.  INDEX is the
item shown, and CHOICES the options chosen for the items before it, as
\(ITEM . OPTION), last first."
  record drafts comments callback (index 0) choices)

(defun agent-decision-ask (record drafts comments callback)
  "Show RECORD, a decision, in a menu, and pass the user's answer to CALLBACK.
DRAFTS maps each send of RECORD to the text it would send, as
`agent-decision-drafts' returns it, and the menu shows the text under
the option.  The menu, `agent-decision-menu', shows one item at a time,
in order, and stays until the user acts on it.  For each item a digit
chooses the option shown with it and \\`RET' the recommended one, when
there is one; \\`x' drops the decision; \\`c', when COMMENTS is non-nil,
reads a comment instead of an answer; and \\`q' or \\`C-g' quits, so that
nothing is answered, also when it comes before the last item.

CALLBACK is called once the answer is complete, from the command that
completed it, with (answer . CHOICES), where CHOICES is a list of
\(ITEM . OPTION), one for each item, as indices into RECORD;
\(comment . TEXT); or (drop).  It is not called when the user quits."
  (transient-setup 'agent-decision-menu nil nil
                   :scope (agent-decision--asking-create
                           :record record :drafts drafts :comments comments
                           :callback callback)))

(transient-define-prefix agent-decision-menu ()
  "Answer the decision of a task.
This menu is opened by `agent-decision-ask', with the decision; called
on its own, it has no decision to show."
  :refresh-suffixes t
  [:description agent-decision--menu-heading
   :class transient-column
   :setup-children agent-decision--menu-options]
  [:class transient-row
   :setup-children agent-decision--menu-actions]
  (interactive)
  (user-error "Open a task's decision with `agent-decide'"))

(defclass agent-decision--option (transient-suffix)
  ((option :initarg :option :initform nil
           :documentation "The index of the option in its item."))
  "A suffix of `agent-decision-menu' that chooses an option.")

(transient-define-suffix agent-decision-menu-choose ()
  "Choose the option of this key for the question shown."
  :class 'agent-decision--option
  (interactive)
  (agent-decision--menu-act 'agent-decision-menu-choose
                            (cons 'choose (oref (transient-suffix-object)
                                                option))))

(transient-define-suffix agent-decision-menu-accept ()
  "Choose the recommended option for the question shown."
  (interactive)
  (agent-decision--menu-act 'agent-decision-menu-accept '(accept)))

(transient-define-suffix agent-decision-menu-comment ()
  "Comment on the decision instead of answering it."
  (interactive)
  (agent-decision--menu-act 'agent-decision-menu-comment '(comment)))

(transient-define-suffix agent-decision-menu-drop ()
  "Drop the decision, answering nothing."
  (interactive)
  (agent-decision--menu-act 'agent-decision-menu-drop '(drop)))

(defun agent-decision--menu-asking ()
  "Return the decision `agent-decision-menu' is showing, or nil."
  (let ((asking (transient-scope 'agent-decision-menu)))
    (and (agent-decision--asking-p asking) asking)))

(defun agent-decision--asking-item (asking)
  "Return the item ASKING shows."
  (nth (agent-decision--asking-index asking)
       (agent-decision-items (agent-decision--asking-record asking))))

(defun agent-decision--asking-last-p (asking)
  "Return non-nil when ASKING shows the last item of its decision."
  (= (1+ (agent-decision--asking-index asking))
     (length (agent-decision-items (agent-decision--asking-record asking)))))

(defun agent-decision--menu-heading ()
  "Return the heading of `agent-decision-menu': the question it shows."
  (when-let* ((asking (agent-decision--menu-asking)))
    (agent-decision--heading asking)))

(defun agent-decision--heading (asking)
  "Return the question ASKING shows, with its place among several."
  (let ((count (length (agent-decision-items
                        (agent-decision--asking-record asking)))))
    (concat (propertize (agent-decision-get (agent-decision--asking-item asking)
                                            'question)
                        'face 'transient-heading)
            (if (> count 1)
                (propertize (format "  (question %d of %d)"
                                    (1+ (agent-decision--asking-index asking))
                                    count)
                            'face 'shadow)
              ""))))

(defun agent-decision--menu-options (_)
  "Return the suffixes of `agent-decision-menu' for the item it shows."
  (when-let* ((asking (agent-decision--menu-asking)))
    (transient-parse-suffixes 'agent-decision-menu
                              (agent-decision--option-specs asking))))

(defun agent-decision--menu-actions (_)
  "Return the suffixes of `agent-decision-menu' that answer otherwise."
  (when-let* ((asking (agent-decision--menu-asking)))
    (transient-parse-suffixes 'agent-decision-menu
                              (agent-decision--action-specs asking))))

(defun agent-decision--option-specs (asking)
  "Return the suffix specs of the options of the item ASKING shows.
Why the last answer could not be carried out comes first, when it
could not; then the item's reason; then its options, numbered in the order
they are shown, the recommended one first and marked; under an option
that sends, the conversation and the text it sends, wrapped.  Choosing
an option of the last item ends the menu; one of another goes on to the
next item."
  (let* ((item (agent-decision--asking-item asking))
         (index (agent-decision--asking-index asking))
         (options (agent-decision-options item))
         (recommended (agent-decision-recommended item))
         (stay (not (agent-decision--asking-last-p asking)))
         (n 0))
    (append
     (when-let* ((failure (agent-decision-get (agent-decision--asking-record
                                               asking)
                                              'failure)))
       (list (list :info* (propertize
                           (agent-decision--wrap
                            (format "The last answer could not be carried out: %s."
                                    failure)
                            1 0)
                           'face 'warning))))
     (when-let* ((why (agent-decision-get item 'why)))
       (list (list :info* (concat (agent-decision--wrap why 1 0) "\n "))))
     (mapcan
      (lambda (j)
        (let* ((option (nth j options))
               (effect (agent-decision-effect option)))
          (setq n (1+ n))
          (cons (list (number-to-string n)
                      (concat (agent-decision-get option 'label)
                              (if (eql j recommended)
                                  (propertize "  (recommended)" 'face 'success)
                                ""))
                      'agent-decision-menu-choose
                      :option j :transient stay)
                (when (equal (agent-decision-kind effect) "send")
                  (list (list :info* (agent-decision--send-text
                                      effect
                                      (alist-get (cons index j)
                                                 (agent-decision--asking-drafts
                                                  asking)
                                                 nil nil #'equal))))))))
      (agent-decision-display-order item)))))

(defconst agent-decision--draft-column 3
  "The column at which the menu shows the text of a send.
It is that of the options' labels, under which the text is shown.")

(defun agent-decision--send-text (effect text)
  "Return what the menu shows under the send EFFECT: where TEXT goes, and TEXT.
Transient indents the first line of an information by one column, which
the first line here leaves out."
  (let ((indent (make-string agent-decision--draft-column ?\s)))
    (concat (substring indent 1)
            (propertize (format "To %s:" (agent-decision--to-label effect))
                        'face 'shadow)
            "\n"
            (if (string-blank-p (or text ""))
                (concat indent (propertize "(no text)" 'face 'warning))
              (agent-decision--wrap text agent-decision--draft-column))
            ;; A blank line parts the text from the next option.
            "\n ")))

(defun agent-decision--wrap (text indent &optional first)
  "Return TEXT filled to the frame's width, each line indented by INDENT.
The first line is indented by FIRST instead, when it is given.  The
lines TEXT breaks stay broken; only lines too long are filled."
  (let ((fill-column (max 30 (min 80 (- (frame-width) indent 4))))
        (prefix (make-string indent ?\s))
        (lines (split-string (string-trim-right text) "\n")))
    (string-remove-prefix
     (make-string (- indent (or first indent)) ?\s)
     (mapconcat
      (lambda (line)
        (if (string-blank-p line)
            ""
          (with-temp-buffer
            (insert line)
            (let ((fill-prefix prefix))
              (goto-char (point-min))
              (insert prefix)
              (fill-region (point-min) (point-max) nil t))
            (string-trim-right (buffer-string)))))
      lines
      "\n"))))

(defun agent-decision--action-specs (asking)
  "Return the suffix specs of the answers ASKING offers besides an option.
\\`RET' takes the recommendation, when the item shown has one; \\`c'
comments, when the decision takes comments; \\`x' drops it; \\`q' quits."
  (append
   (when (agent-decision-recommended (agent-decision--asking-item asking))
     (list (list "RET" "accept the recommendation" 'agent-decision-menu-accept
                 :transient (not (agent-decision--asking-last-p asking)))))
   (when (agent-decision--asking-comments asking)
     (list (list "c" "comment" 'agent-decision-menu-comment)))
   (list (list "x" "remove this decision (the task stays open)" 'agent-decision-menu-drop)
         (list "q" "quit" 'transient-quit-one))))

(defun agent-decision--menu-act (command action)
  "Act on ACTION, which COMMAND of `agent-decision-menu' was called to do.
ACTION is (choose . OPTION), (accept), (comment) or (drop).  COMMAND
must have been called from the keyboard, as
`agent-decision-from-keyboard-p' tells, while the menu shows a decision."
  (unless (agent-decision-from-keyboard-p command)
    (user-error "A decision is answered only from the keyboard"))
  (let ((asking (or (agent-decision--menu-asking)
                    (user-error "No decision is being answered"))))
    (pcase action
      (`(choose . ,option) (agent-decision--choose asking option))
      ('(accept)
       (agent-decision--choose
        asking (or (agent-decision-recommended
                    (agent-decision--asking-item asking))
                   (user-error "This question has no recommendation"))))
      ('(comment)
       (let ((text (string-trim (read-string "Comment: "))))
         (when (string-empty-p text)
           (user-error "The comment was empty; nothing was answered"))
         (funcall (agent-decision--asking-callback asking)
                  (cons 'comment text))))
      ('(drop) (funcall (agent-decision--asking-callback asking) '(drop))))))

(defun agent-decision--choose (asking option)
  "Choose OPTION for the item ASKING shows.
After the last item, give the answer to ASKING's callback; else show
the next item."
  (push (cons (agent-decision--asking-index asking) option)
        (agent-decision--asking-choices asking))
  (if (agent-decision--asking-last-p asking)
      (funcall (agent-decision--asking-callback asking)
               (cons 'answer (reverse (agent-decision--asking-choices asking))))
    (cl-incf (agent-decision--asking-index asking))))

(defun agent-decision-answer (record choices drafts)
  "Return RECORD answered with CHOICES, now.
CHOICES is a list of (ITEM . OPTION), as `agent-decision-ask' passes
it.  DRAFTS maps each send to its text, which the answer keeps:
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
