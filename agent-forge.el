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
;; inserts the URL of the thing notified about into the prompt for
;; review, or under a prefix argument inserts it into a session already
;; running.  The command only wraps the core's routing layer:
;; `agent-forge-context' reads the subject at point and answers with a
;; context anchored in that working tree, and the core chooses the
;; session and delivers the URL.
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
Start a session in the working tree of the repository the thing at point
belongs to and insert its URL into the prompt without submitting it.
The thing is an issue, a discussion or a pull request, or the
notification itself when Github notified about something that is none of
those, such as a failed workflow run.  With prefix argument EXISTING
insert the URL into a running session instead."
  (interactive "P")
  (agent--act-on-context #'agent-forge-context existing))

(defun agent-forge-context (callback)
  "Call CALLBACK with the context for the Forge subject at point.
The context is anchored when a working tree is wanted: the repository's
working tree is where the session belongs, so no project has to be
chosen.  A running session is already somewhere, so the tree is looked
up only when the core asks for it; looking it up regardless would refuse
a subject whose repository was never cloned locally, for a directory
nobody would read."
  (unless (require 'forge nil t)
    (user-error "Package `forge' is required"))
  (let* ((notification (forge-notification-at-point))
         (subject (agent-forge--subject-at-point notification)))
    (funcall callback
             (append (agent-forge--worktree-context subject)
                     (list :payload (agent-forge--payload subject notification)
                           :submit nil)))))

(defun agent-forge--subject-at-point (notification)
  "Return the Forge subject at point, given the NOTIFICATION there.
The subject is the topic NOTIFICATION is about, or the topic at point
when no notification is, or NOTIFICATION itself when it is about no
topic.  Github also notifies about check suites, commits and releases,
and Forge records no topic for those, but such a notification is a
subject of its own: it names a repository to work in and a URL to read."
  (or (agent-forge--notification-topic notification)
      (forge-topic-at-point)
      notification
      (user-error "No Forge notification or topic at point")))

(defun agent-forge--notification-topic (notification)
  "Return the Forge topic NOTIFICATION is about, or nil when it is about none.
NOTIFICATION may be nil, for a buffer holding none.  The topic slot is
read before the topic is looked up because Forge answers a notification
about no topic by comparing its missing number with zero, which raises."
  (when (and notification (agent--slot-value notification 'topic))
    (forge-get-topic notification)))

(defun agent-forge--worktree-context (subject)
  "Return the `:directory' part of the context for SUBJECT, or nil."
  (when agent--context-wants-directory
    (list :directory
          (agent-forge--worktree (forge-get-repository subject)))))

(defun agent-forge--payload (subject notification)
  "Return the prompt payload for SUBJECT, the thing at point.
SUBJECT is NOTIFICATION itself when the notification is about no topic.
A topic's URL names the topic completely, so the URL is all that is
sent.  A notification about no topic points at a page holding many
things, such as a repository's workflow runs, so its title goes with the
URL: the title is what says which of them this is."
  (if (eq subject notification)
      (format "%s\n%s"
              (agent--slot-value notification 'title)
              (agent-forge--url notification "notification"))
    (agent-forge--url subject "topic")))

(defun agent-forge--url (object kind)
  "Return OBJECT's URL, or refuse the KIND at point for having none."
  (or (forge-get-url object)
      (user-error "Forge %s at point has no URL" kind)))

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
          (agent--slot-value repo 'owner)
          (agent--slot-value repo 'name)))

;;;; Provide

(provide 'agent-forge)
;;; agent-forge.el ends here
