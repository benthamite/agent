;;; agent-org-linear.el --- Route Linear issues to AI sessions -*- lexical-binding: t -*-

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

;; Linear-to-project routing for AI coding sessions.  `org-linear'
;; mirrors Linear issues as org TODO headings, each filed under a
;; level-1 heading named after its Linear project and carrying the
;; issue's URL in a `LINEAR_URL' property.  An issue is therefore routed
;; as the org TODO it is, through `agent-todo-context', from its heading
;; or from the agenda line showing it, such as one in the list
;; `org-linear-my-issues' builds.  Two things are added: the Linear
;; project's name leads the text the project is ranked by, since it is
;; the likeliest clue to the repository the issue is about, and the
;; issue's URL goes into the prompt, so the agent can reach the issue
;; itself.  Nothing of `org-linear' is loaded: everything is read from
;; the properties and outline it writes.

;;; Code:

(require 'agent)
(require 'agent-todo)
(require 'agent-project)
(require 'org)

;;;###autoload
(defun agent-act-on-linear-issue (&optional existing)
  "Route the Linear issue at point to an AI session.
The issue is the heading at point in the file `org-linear' mirrors, or
the heading the agenda line at point shows.  Start a session in a
project ranked by the issue's Linear project and text, and submit the
issue to it.  With prefix argument EXISTING submit it to a running
session instead."
  (interactive "P")
  (agent--act-on-context #'agent-org-linear-context existing))

(defun agent-org-linear-context (callback)
  "Call CALLBACK with the context for the Linear issue at point.
The context is the issue's org TODO context, see `agent-todo-context',
with the issue's URL added to the payload and its Linear project's name
put first in the text the project is ranked by.  When a directory is
wanted and the account has a project named like the Linear project, that
directory is suggested, so the project reader opens on it; see
`agent-project-named-directory'."
  (let ((url (or (agent--at-org-entry (lambda () (org-entry-get nil "LINEAR_URL")))
                 (user-error "No Linear issue at point")))
        (project (agent--at-org-entry #'agent-org-linear--project-name)))
    (agent-todo-context
     (lambda (context)
       (let ((payload (format "%s\n\nLinear issue: %s"
                              (plist-get context :payload) url)))
         (funcall callback
                  (append (agent-org-linear--project-context project)
                          (thread-first context
                                        (copy-sequence)
                                        (plist-put :payload payload)
                                        (plist-put :text
                                                   (if project
                                                       (format "Linear project: %s\n%s"
                                                               project payload)
                                                     payload))))))))))

(defun agent-org-linear--project-context (project)
  "Return the `:suggested-directory' part of the context for PROJECT, or nil.
PROJECT is the Linear project's name, or nil for an issue in none.  The
directory is offered rather than imposed, as a Forge topic's clone is,
so the issue ends in the same project choice as every other thing."
  (when-let* ((agent--context-wants-directory)
              (project)
              (directory (agent-project-named-directory
                          project agent--context-account)))
    (list :suggested-directory directory)))

(defun agent-org-linear--project-name ()
  "Return the name of the Linear project of the issue at point, or nil.
`org-linear' files each issue under a level-1 heading for its project,
named after it and carrying the project's ID in `LINEAR_PROJECT'.
Issues in no project sit under a heading whose ID is empty or \"none\",
and that heading names no project."
  (save-excursion
    (org-back-to-heading t)
    (when (and (org-up-heading-safe) (= (org-outline-level) 1))
      (let ((id (org-entry-get nil "LINEAR_PROJECT")))
        (unless (member id '(nil "" "none"))
          (org-get-heading t t t t))))))

(defun agent-org-linear-origin ()
  "Return the origin of the Linear issue at point, or nil.
It is \"linear:\" followed by the workspace slug in the issue's URL, as
in \"linear:acme\" for https://linear.app/acme/issue/ENG-1; see
`agent-account-origin-rules'."
  (when-let* ((url (agent--at-org-entry
                    (lambda () (org-entry-get nil "LINEAR_URL"))))
              ((string-match "\\`https?://linear\\.app/\\([^/]+\\)/" url)))
    (concat "linear:" (match-string 1 url))))

(provide 'agent-org-linear)
;;; agent-org-linear.el ends here
