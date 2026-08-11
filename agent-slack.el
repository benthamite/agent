;;; agent-slack.el --- Route Slack messages to AI sessions -*- lexical-binding: t -*-

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

;; Slack-to-project routing for AI coding sessions.  The command only
;; wraps the core's routing layer: `agent-slack-context' reads the
;; message at point and answers with a context carrying its text, and
;; the core picks the project that text is about, starts a session
;; there, and inserts the message URL into the prompt for review.
;;
;; A message names no directory of its own, which is what separates it
;; from `agent-act-on-forge-notification': the project has to be chosen
;; from the text, out of the candidates `agent-project' collects.

;;; Code:

(require 'agent)

;;;; Forward declarations

(defvar slack-current-buffer)
(defvar slack-get-permalink-url)
(declare-function slack-buffer-copy-link "slack-room-buffer")
(declare-function slack-buffer-room "slack-buffer")
(declare-function slack-buffer-team "slack-buffer")
(declare-function slack-get-ts "slack-util")
(declare-function slack-message-body "slack-message")
(declare-function slack-room-find "slack-room")
(declare-function slack-room-find-message "slack-room")
(declare-function slack-request "slack-request")
(declare-function slack-request-create "slack-request")

;;;; Slack message routing

;;;###autoload
(defun agent-act-on-slack-message (&optional existing)
  "Route the Slack message at point to an AI session.
With prefix argument EXISTING send it to a running session instead of
starting one in a project chosen from the message text."
  (interactive "P")
  (agent--act-on-context #'agent-slack-context existing))

;;;###autoload
(define-obsolete-function-alias
  'agent-debug-slack-message #'agent-act-on-slack-message "0.2")

(defun agent-slack-context (callback)
  "Call CALLBACK with the context for the Slack message at point.
The context is unanchored: a message names no directory, so its text
picks the project."
  (agent-slack--with-message-context
   (lambda (context)
     (funcall callback (list :text (plist-get context :text)
                             :payload (plist-get context :url)
                             :submit nil)))))

(defun agent-slack--with-message-context (callback)
  "Call CALLBACK with the Slack message context at point."
  (unless (require 'slack nil t)
    (user-error "Package `slack' is required"))
  (let* ((ts (agent-slack--message-ts-at-point))
         (team (agent-slack--team-at-point))
         (room (agent-slack--room-at-point team))
         (message (and room ts (slack-room-find-message room ts)))
         (text (agent-slack--message-text message team)))
    (unless (and team room ts text)
      (user-error "No Slack message at point"))
    (agent-slack--message-url
     team room ts
     (lambda (url)
       (funcall callback
                (list :text text :url url :ts ts
                      :room-id (agent--slot-value room 'id)))))))

(defun agent-slack--message-ts-at-point ()
  "Return the Slack message timestamp at point."
  (or (and (fboundp 'slack-get-ts) (slack-get-ts))
      (get-text-property (point) 'ts)
      (get-text-property (line-beginning-position) 'ts)))

(defun agent-slack--team-at-point ()
  "Return the Slack team for the current buffer."
  (and (boundp 'slack-current-buffer)
       slack-current-buffer
       (slack-buffer-team slack-current-buffer)))

(defun agent-slack--room-at-point (team)
  "Return the Slack room at point for TEAM."
  (or (ignore-errors (slack-buffer-room slack-current-buffer))
      (when-let* ((room-id (get-text-property (point) 'room-id)))
        (slack-room-find room-id team))))

(defun agent-slack--message-text (message team)
  "Return plain text for Slack MESSAGE in TEAM."
  (string-trim
   (cond
    (message (substring-no-properties (slack-message-body message team)))
    (t (buffer-substring-no-properties
        (line-beginning-position) (line-end-position))))))

(defun agent-slack--message-url (team room ts callback)
  "Call CALLBACK with a Slack permalink for TS in ROOM on TEAM."
  (if (and (fboundp 'slack-buffer-copy-link)
           (ignore-errors
             (slack-buffer-copy-link slack-current-buffer ts callback)
             t))
      nil
    (funcall callback (agent-slack--message-url-fallback team room ts))))

(defun agent-slack--message-url-fallback (team room ts)
  "Return a best-effort Slack permalink for TS in ROOM on TEAM."
  (let ((domain (or (and (slot-boundp team 'domain)
                         (agent--slot-value team 'domain))
                    (and (slot-boundp team 'name)
                         (agent--slot-value team 'name)))))
    (unless domain
      (user-error "Slack team has no domain"))
    (format "https://%s.slack.com/archives/%s/p%s"
            domain (agent--slot-value room 'id)
            (replace-regexp-in-string "\\." "" ts))))

;;;; Provide

(provide 'agent-slack)
;;; agent-slack.el ends here
