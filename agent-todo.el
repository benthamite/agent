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
;; project chosen from the TODO's own text, or a running one with a
;; prefix argument.  It works with any registered backend.

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
starting one in a project chosen from the TODO's text."
  (interactive "P")
  (agent--act-on-context #'agent-todo-context existing))

(defun agent-todo-context (callback)
  "Call CALLBACK with the context for the org TODO at point.
The TODO is the heading at point in an org buffer, or the heading the
line at point shows in an agenda.  It is both the text a project is
chosen from and the request itself, so it is submitted rather than left
for review.  The heading is remembered as a marker because choosing that
project can take a model request and a prompt, by which time point has
moved, or the agenda has been rebuilt."
  (let ((marker (or (agent--org-entry-marker)
                    (user-error "Must be called on an org heading or agenda entry"))))
    (unless (agent--at-org-entry #'org-get-todo-state)
      (user-error "Point is not on a TODO heading"))
    (let ((prompt (agent-todo--format-prompt
                   (agent--at-org-entry #'agent-todo--collect-at-point))))
      (funcall callback
               (list :text prompt
                     :payload prompt
                     :submit t
                     :after (lambda () (agent-todo--mark-in-progress marker)))))))

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
