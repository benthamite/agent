;;; agent-todo.el --- Org TODO workflows for AI sessions -*- lexical-binding: t -*-

;; Copyright (C) 2026

;; Author: Pablo Stafforini
;; URL: https://github.com/benthamite/agent
;; Version: 0.1
;; Package-Requires: ((emacs "30.0") (agent "0.1"))

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

;; Route the org TODO at point to an AI session -- a new one in a
;; project chosen from the TODO's own text, or in the directory an org
;; property names for it, or a running one with a prefix argument.  It
;; works with any registered backend.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'project)
(require 'agent)

(declare-function org-agenda-redo "org-agenda" (&optional all))

;;;; Customization

(defgroup agent-todo nil
  "Org TODO workflows for AI sessions."
  :group 'agent)

(defcustom agent-todo-in-progress-keyword nil
  "Org TODO keyword to set when sending a heading to an AI session.
When non-nil, `agent-send-todo-at-point' changes the heading's TODO
state to this keyword after sending.  The keyword must be one of the
values in `org-todo-keywords' for the current buffer.  When nil, the
TODO state is not changed.

Org's built-in keywords are just TODO and DONE, with no intermediate
state, so this is disabled by default.  Users who have configured an
in-progress keyword (e.g. DOING, IN-PROGRESS, STARTED) can set this
option to that keyword."
  :type '(choice (const :tag "Don't change TODO state" nil)
                 (string :tag "Keyword"))
  :group 'agent-todo)

(defcustom agent-todo-directory-property nil
  "Org property naming the directory a TODO's session starts in.
When non-nil, it is the name of an org property, such as \"DIRECTORY\".
A TODO routed to a new session starts that session in the directory the
property names, without a project being ranked or asked for.  The
property is read from the TODO's own heading, else from the nearest
heading above it that has it, else from a PROPERTY keyword of the file
or from `org-global-properties', whatever `org-use-property-inheritance'
says.  A relative name is expanded against the directory of the org
file.

A value that is empty or \"nil\" names no directory, which exempts a
heading from the value set above it.  A value naming a directory that
does not exist is reported and ignored.  In both cases, as when this
option is nil, the project is chosen from the TODO's text.

The session's account is the one any session started in that directory
gets: the one `agent-account-directory-rules' names for it, else the
selected account."
  :type '(choice (const :tag "Choose a project for every TODO" nil)
                 (string :tag "Property"))
  :group 'agent-todo)

(defcustom agent-todo-submit-property nil
  "Org property marking a TODO whose text is a ready prompt.
When non-nil, it is the name of an org property.  A TODO whose own
heading has that property, with any value but \"nil\", is submitted as
it stands even when it is of a kind that is otherwise left in the
prompt to be edited, as a Linear issue is; see
`agent-org-linear-context'.  The property is not inherited from the
headings above.  A plain TODO is submitted either way, so this option
changes nothing for it."
  :type '(choice (const :tag "Mark no TODO as a ready prompt" nil)
                 (string :tag "Property"))
  :group 'agent-todo)

;;;; Functions

;;;;; Entry collection

(defun agent-todo--format-prompt (entry)
  "Format ENTRY plist as a prompt string for a non-interactive run.
Combines :title and :body, using title alone when body is empty."
  (let ((title (plist-get entry :title))
        (body (plist-get entry :body)))
    (if (or (null body) (string-empty-p body))
        title
      (concat title "\n\n" body))))

(defun agent-todo--org-to-markdown (text)
  "Convert org inline markup in TEXT to Markdown equivalents.
Handles verbatim (=…=) and code (~…~) to backticks."
  (replace-regexp-in-string "[=~]\\([^=~\n]+\\)[=~]" "`\\1`" text))

(defun agent-todo--collect-at-point ()
  "Return a plist with :title and :body for the TODO at point."
  (save-excursion
    (org-back-to-heading t)
    (let* ((title (agent-todo--org-to-markdown
                   (org-get-heading t t t t)))
           (body-start (progn (org-end-of-meta-data t) (point)))
           (body-end (progn (outline-next-heading)
                            (or (point) (point-max))))
           (body (string-trim
                  (buffer-substring-no-properties body-start body-end))))
      (list :title title :body body))))

;;;;; Commands

;;;###autoload
(defun agent-send-todo-at-point (&optional existing)
  "Route the org TODO at point to an AI session.
With prefix argument EXISTING send it to a running session instead of
starting one in a project chosen from the TODO's text, or in the
directory `agent-todo-directory-property' names for the TODO."
  (interactive "P")
  (agent--act-on-context #'agent-todo-context existing))

(defun agent-todo-context (callback)
  "Call CALLBACK with the context for the org TODO at point.
The TODO is the heading at point in an org buffer, or the heading the
line at point shows in an agenda.  It is both the text a project is
chosen from and the request itself, so it is submitted rather than left
for review.  A TODO that `agent-todo-directory-property' names a
directory for carries that directory, and no project is then chosen.
The context's `:todo' is a marker at the heading, for
`agent-delivery-functions'.  The heading is remembered as a marker
because choosing that project can take a model request and a prompt, by
which time point has moved, or the agenda has been rebuilt."
  (let ((marker (or (agent--org-entry-marker)
                    (user-error "Must be called on an org heading or agenda entry"))))
    (unless (agent--at-org-entry #'org-get-todo-state)
      (user-error "Point is not on a TODO heading"))
    (let ((prompt (agent-todo--format-prompt
                   (agent--at-org-entry #'agent-todo--collect-at-point))))
      (funcall callback
               (append (agent-todo--directory-context)
                       (list :text prompt
                             :payload prompt
                             :submit t
                             :todo marker
                             :after (lambda ()
                                      (agent-todo--mark-in-progress
                                       marker))))))))

(defun agent-todo--directory-context ()
  "Return the `:directory' part of the context for the TODO at point, or nil.
The directory is the one `agent-todo-directory-property' names for the
TODO.  It is imposed, where a Forge topic's clone is only suggested,
because a property is the user's own answer to the question the project
choice asks.  Nothing is returned, and the property is not read, when no
directory is wanted; see `agent--context-wants-directory'."
  (when-let* ((agent--context-wants-directory)
              (agent-todo-directory-property)
              (directory (agent--at-org-entry
                          #'agent-todo--property-directory)))
    (list :directory directory)))

(defun agent-todo--property-directory ()
  "Return the directory `agent-todo-directory-property' names at point, or nil.
Point is on an org entry.  The property is inherited, so the entry's own
value answers, else that of the nearest heading above it that has one.
A relative name is expanded against the buffer's directory.  An empty
value names no directory, and one naming a directory that does not
exist is reported and ignored."
  (when-let* ((name (org-entry-get nil agent-todo-directory-property t))
              ((not (string-empty-p name)))
              (directory (file-name-as-directory (expand-file-name name))))
    (if (file-directory-p directory)
        directory
      (message "Ignoring the %s property: no directory %s"
               agent-todo-directory-property
               (abbreviate-file-name directory))
      nil)))

(defun agent-todo-ready-prompt-p ()
  "Return non-nil when the TODO at point is marked as a ready prompt.
It is when its own heading has the property `agent-todo-submit-property'
names; the headings above it are not consulted.  The TODO is the heading
at point in an org buffer, or the heading the line at point shows in an
agenda."
  (and agent-todo-submit-property
       (agent--at-org-entry
        (lambda () (org-entry-get nil agent-todo-submit-property)))
       t))

(defun agent-todo--mark-in-progress (marker)
  "Set the TODO state at MARKER to `agent-todo-in-progress-keyword'.
A heading deleted while the session was starting leaves MARKER pointing
at text that is no longer a TODO entry, and there is then nothing to
mark: this runs after the session exists but before it is displayed, so
signalling here would leave a running session unshown."
  (when (and agent-todo-in-progress-keyword (marker-buffer marker))
    (with-current-buffer (marker-buffer marker)
      (save-excursion
        (goto-char marker)
        (when (and (not (org-before-first-heading-p))
                   (org-get-todo-state))
          (org-todo agent-todo-in-progress-keyword))))
    (agent-todo--redo-agenda)))

(defun agent-todo--redo-agenda ()
  "Rebuild the agenda when it is the current buffer.
The state change was made in the heading's own buffer, which leaves the
agenda line showing the old keyword, and in an agenda grouped by keyword
on the wrong group."
  (when (derived-mode-p 'org-agenda-mode)
    (org-agenda-redo t)))

(provide 'agent-todo)
;;; agent-todo.el ends here
