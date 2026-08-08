;;; agent-mu4e.el --- Route email to AI sessions -*- lexical-binding: t -*-

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

;; Routes the mu4e message at point to a session by its maildir path,
;; which is what an agent needs to read the mail itself.

;;; Code:

(require 'agent)

;;;; Forward declarations

(declare-function mu4e-message-field-at-point "mu4e-message" (field))

;;;; Commands

;;;###autoload
(defun agent-act-on-email (&optional existing)
  "Route the email at point to an AI session.
With prefix argument EXISTING send it to a running session instead of
starting one in a project chosen from the message."
  (interactive "P")
  (agent--act-on-context #'agent-mu4e-context existing))

(defun agent-mu4e-context (callback)
  "Call CALLBACK with the context for the mu4e message at point.
The payload is the maildir path, which an agent can read directly.  The
subject and sender are the text a project is chosen from."
  (unless (require 'mu4e nil t)
    (user-error "Package `mu4e' is required"))
  (let ((path (agent-mu4e--path)))
    (funcall callback (list :text (agent-mu4e--message-text)
                            :payload path
                            :submit nil))))

(defun agent-mu4e--path ()
  "Return the maildir path of the message at point.
`mu4e-message-field' sanitizes a missing string field to the empty
string, so a message that records no path answers with \"\" rather than
nil.  A maildir file name encodes the message's flags, so reading the
message or another mail program touching it renames the file, and mu's
index can name a path that no longer exists until it is reindexed: a
path the agent could not open is an ordinary failure rather than an
exceptional one."
  (let ((path (mu4e-message-field-at-point :path)))
    (unless (and (stringp path) (not (string-empty-p path)))
      (user-error "Message at point records no file path"))
    (unless (file-readable-p path)
      (user-error "Message file is not readable: %s" path))
    path))

(defun agent-mu4e--message-text ()
  "Return the subject and sender of the message at point."
  (format "Subject: %s\nFrom: %s"
          (mu4e-message-field-at-point :subject)
          (agent-mu4e--sender)))

(defun agent-mu4e--sender ()
  "Return the senders of the message at point as one string.
The `:from' field is a list of (:email EMAIL :name NAME) plists, one per
sender, and the name is absent for a sender that gave none."
  (mapconcat #'agent-mu4e--contact-string
             (mu4e-message-field-at-point :from) ", "))

(defun agent-mu4e--contact-string (contact)
  "Return CONTACT, one plist of the `:from' field, as a string."
  (let ((name (plist-get contact :name))
        (email (plist-get contact :email)))
    (if (and name (not (string-empty-p name)))
        (format "%s <%s>" name email)
      (or email ""))))

;;;; Provide

(provide 'agent-mu4e)
;;; agent-mu4e.el ends here
