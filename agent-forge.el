;;; agent-forge.el --- Route Forge notifications to AI sessions -*- lexical-binding: t -*-

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

;; Forge-to-project routing for AI coding sessions.  Starts a session in
;; the working tree of the repository the notification belongs to and
;; inserts the topic's URL into the prompt for review.
;;
;; This is the Forge counterpart of `agent-act-on-slack-message'.  It
;; needs no language model: a Slack message must be classified to find
;; its project, whereas a Forge notification already records its
;; repository, and the repository already records its working tree.

;;; Code:

(require 'agent)

;;;; Forward declarations

(declare-function forge-get-repository "forge-repo" (demand &optional remote notatpt))
(declare-function forge-get-topic "forge-topic" (id &optional number))
(declare-function forge-get-url "forge-core" (obj))
(declare-function forge-get-worktree "forge-repo" (repo))
(declare-function forge-notification-at-point "forge-notify" (&optional demand))
(declare-function forge-topic-at-point "forge-topic" (&optional demand))

;;;; Forge notification routing

;;;###autoload
(defun agent-act-on-forge-notification (&optional existing)
  "Route the Forge notification or topic at point to an AI session.
With prefix argument EXISTING send it to a running session instead of
starting one in the repository's working tree."
  (interactive "P")
  (agent--act-on-context #'agent-forge-context existing))

(defun agent-forge-context (callback)
  "Call CALLBACK with the context for the Forge topic at point.
The context is anchored: the repository's working tree is where the
session belongs, so no project has to be chosen."
  (let* ((topic (agent-forge--topic-at-point))
         (repo (forge-get-repository topic))
         (url (or (forge-get-url topic)
                  (user-error "Forge topic has no URL"))))
    (funcall callback (list :directory (agent-forge--worktree repo)
                            :payload url
                            :submit nil))))

(defun agent-forge--topic-at-point ()
  "Return the Forge topic for the notification or topic at point."
  (unless (require 'forge nil t)
    (user-error "Package `forge' is required"))
  (or (when-let* ((notification (forge-notification-at-point)))
        (forge-get-topic notification))
      (forge-topic-at-point)
      (user-error "No Forge notification or topic at point")))

(defun agent-forge--worktree (repo)
  "Return the working tree directory for REPO.
Signals an error when REPO has no local clone, or when the recorded
path no longer exists.  Forge does not update the recorded path when a
repository is renamed or moved, so a stale entry is a normal failure
rather than an exceptional one."
  (let ((directory (forge-get-worktree repo)))
    (unless directory
      (user-error "No local clone recorded for %s" (agent-forge--slug repo)))
    (unless (file-directory-p directory)
      (user-error "Recorded clone for %s is missing: %s"
                  (agent-forge--slug repo) directory))
    (file-name-as-directory (expand-file-name directory))))

(defun agent-forge--slug (repo)
  "Return REPO's owner/name slug."
  (format "%s/%s"
          (agent-forge--slot-value repo 'owner)
          (agent-forge--slot-value repo 'name)))

(defun agent-forge--slot-value (object slot)
  "Return OBJECT's dynamic EIEIO SLOT value.
Forge's classes are not loaded when this file is byte-compiled, so a
literal `oref' would warn about every slot being unknown."
  (eieio-oref object slot))

;;;; Provide

(provide 'agent-forge)
;;; agent-forge.el ends here
