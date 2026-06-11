;;; agent-capture.el --- Org prompt capture for AI sessions -*- lexical-binding: t -*-

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

;; Persisted Org prompt capture for AI coding sessions.  Prompts are
;; captured into per-session Org files so they survive Emacs restarts
;; and can later be inserted into the session's CLI input with
;; `agent-insert-captured-prompt'.

;;; Code:

(require 'agent)

;;;; Customization

(defcustom agent-prompt-capture-directory
  (expand-file-name "agent/prompts/" user-emacs-directory)
  "Directory where session-specific prompt capture files are stored."
  :type 'directory
  :group 'agent)

(defcustom agent-prompt-capture-auto-save-delay 1
  "Idle seconds before prompt capture buffers are saved.
Set to nil to disable automatic saving of capture buffers."
  :type '(choice (const :tag "Disabled" nil) number)
  :group 'agent)

;;;; State variables

(defvar-local agent-capture--save-timer nil
  "Idle timer used to save prompt capture buffers.")

(defconst agent-capture--preview-width 100
  "Maximum width for prompt body previews in completion candidates.")

;;;; Forward declarations

(declare-function org-back-to-heading "org" (&optional invisible-ok))
(declare-function org-entry-get "org" (pom property &optional inherit literal-nil))
(declare-function org-get-heading "org" (&optional no-tags no-todo no-priority no-comment))
(declare-function org-set-property "org" (property value))
(declare-function outline-next-heading "outline" ())

(defvar org-heading-regexp)

;;;; Prompt capture

;;;###autoload
(defun agent-capture-prompt (&optional buffer)
  "Open a persisted Org capture entry for an AI session BUFFER.
When BUFFER is nil, use the current AI session buffer or prompt
for a session.  The capture file is specific to the resolved
session identity, so prompts survive Emacs restarts and can later
be retrieved with `agent-insert-captured-prompt'."
  (interactive)
  (let* ((session-buffer (agent--resolve-session-buffer buffer))
         (backend (agent--detect-backend session-buffer))
         (file (agent-capture--file backend session-buffer)))
    (agent-capture--open-file file backend session-buffer)))

;;;###autoload
(defun agent-insert-captured-prompt (&optional buffer include-inserted)
  "Insert a captured prompt into an AI session BUFFER.
Prompts are loaded from the current session's persisted Org
capture file.  The selected prompt is inserted into the CLI input
field but is not submitted.  After successful insertion, the Org
entry is removed from the capture file.

With prefix argument INCLUDE-INSERTED, include prompts that have
already been inserted."
  (interactive (list nil current-prefix-arg))
  (let* ((session-buffer (agent--resolve-session-buffer buffer))
         (backend (agent--detect-backend session-buffer))
         (prompts (agent-capture--prompts
                   backend session-buffer include-inserted)))
    (unless (agent--backend-get backend :send-string)
      (user-error "Backend `%s' does not support prompt insertion" backend))
    (unless prompts
      (user-error "No captured prompts for this session"))
    (let ((prompt (agent-capture--select-prompt prompts)))
      (agent-send-string (plist-get prompt :text) session-buffer)
      (agent-capture--delete-prompt prompt))))

(defun agent-capture-confirm-no-pending (backend buffer action)
  "Confirm ACTION for BACKEND session BUFFER when captures are pending.
Return non-nil when ACTION may proceed."
  (let ((count (length (agent-capture--prompts backend buffer))))
    (or (zerop count)
        (yes-or-no-p
         (format "%s has %d captured prompt%s.  %s anyway? "
                 (agent-display-name buffer) count
                 (if (= count 1) "" "s") action)))))

(defun agent-capture--file (backend buffer)
  "Return the Org capture file for BACKEND session BUFFER."
  (expand-file-name
   (concat (agent-capture--session-slug backend buffer) ".org")
   agent-prompt-capture-directory))

(defun agent-capture--session-slug (backend buffer)
  "Return a stable file slug for BACKEND session BUFFER."
  (format "%s-%s"
          backend
          (secure-hash 'sha1 (agent-capture--session-identity backend buffer))))

(defun agent-capture--session-identity (backend buffer)
  "Return the stable prompt capture identity for BACKEND session BUFFER."
  (let* ((directory (or (agent--buffer-directory backend buffer) ""))
         (session (agent-session buffer))
         (account (when session (agent-session-account session)))
         (instance (if session
                       (agent-session-instance session)
                     (agent--session-instance-from-buffer-name
                      (buffer-name buffer)))))
    (prin1-to-string (list backend account directory instance))))

(defun agent-capture--open-file (file backend buffer)
  "Open FILE and append a prompt entry for BACKEND session BUFFER."
  (require 'org)
  (make-directory (file-name-directory file) t)
  (let ((capture-buffer (find-file-noselect file)))
    (with-current-buffer capture-buffer
      (org-mode)
      (agent-prompt-capture-mode 1)
      (agent-capture--ensure-header backend buffer)
      (agent-capture--append-entry)
      (save-buffer))
    (pop-to-buffer capture-buffer)))

(defun agent-capture--ensure-header (backend buffer)
  "Insert the prompt capture file header for BACKEND session BUFFER."
  (when (zerop (buffer-size))
    (insert "#+title: Agent prompt captures\n")
    (insert "#+agent_backend: " (symbol-name backend) "\n")
    (insert "#+agent_session: " (agent-display-name buffer) "\n\n")))

(defun agent-capture--append-entry ()
  "Append a new prompt capture entry at the end of the current buffer."
  (goto-char (point-max))
  (unless (bolp) (insert "\n"))
  (insert "* Prompt " (format-time-string "%Y-%m-%d %H:%M") "\n")
  (insert ":PROPERTIES:\n")
  (insert ":CREATED: " (format-time-string "[%Y-%m-%d %a %H:%M]") "\n")
  (insert ":END:\n\n")
  (point))

(define-minor-mode agent-prompt-capture-mode
  "Automatically save persisted Agent prompt capture buffers."
  :lighter " AgentCapture"
  (if agent-prompt-capture-mode
      (add-hook 'after-change-functions
                #'agent-capture--after-change nil t)
    (remove-hook 'after-change-functions
                 #'agent-capture--after-change t)
    (agent-capture--cancel-save)))

(defun agent-capture--after-change (&rest _)
  "Schedule an automatic save for the current prompt capture buffer."
  (when agent-prompt-capture-auto-save-delay
    (agent-capture--cancel-save)
    (setq agent-capture--save-timer
          (run-with-idle-timer agent-prompt-capture-auto-save-delay
                               nil
                               #'agent-capture--save-buffer
                               (current-buffer)))))

(defun agent-capture--cancel-save ()
  "Cancel the pending prompt capture save timer, if any."
  (when (timerp agent-capture--save-timer)
    (cancel-timer agent-capture--save-timer))
  (setq agent-capture--save-timer nil))

(defun agent-capture--save-buffer (buffer)
  "Save prompt capture BUFFER when it is still live and modified."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq agent-capture--save-timer nil)
      (when (and buffer-file-name (buffer-modified-p))
        (save-buffer)))))

(defun agent-capture--prompts (backend buffer &optional include-inserted)
  "Return nonempty captured prompts for BACKEND session BUFFER.
When INCLUDE-INSERTED is non-nil, include prompts already marked
as inserted."
  (let ((file (agent-capture--file backend buffer)))
    (when (file-exists-p file)
      (agent-capture--read-prompts file include-inserted))))

(defun agent-capture--read-prompts (file &optional include-inserted)
  "Read captured prompt entries from Org FILE.
When INCLUDE-INSERTED is non-nil, include prompts already marked
as inserted."
  (require 'org)
  (with-temp-buffer
    (insert-file-contents file)
    (org-mode)
    (let (prompts)
      (goto-char (point-min))
      (while (re-search-forward org-heading-regexp nil t)
        (goto-char (match-beginning 0))
        (when-let* ((prompt (agent-capture--prompt-at-point
                             file include-inserted)))
          (push prompt prompts))
        (or (outline-next-heading) (goto-char (point-max))))
      (nreverse prompts))))

(defun agent-capture--prompt-at-point (file include-inserted)
  "Return the captured prompt at point as a plist, or nil.
FILE is the Org file being parsed.  When INCLUDE-INSERTED is
non-nil, include prompts already marked as inserted."
  (org-back-to-heading t)
  (let* ((title (org-get-heading t t t t))
         (created (org-entry-get (point) "CREATED"))
         (inserted (org-entry-get (point) "INSERTED"))
         (body-start (agent-capture--prompt-body-start))
         (body-end (save-excursion
                     (or (outline-next-heading) (goto-char (point-max)))
                     (point)))
         (text (string-trim
                (buffer-substring-no-properties body-start body-end))))
    (when (and (not (string-empty-p text))
               (or include-inserted (not inserted)))
      (list :file file
            :title title
            :created created
            :inserted inserted
            :text text))))

(defun agent-capture--prompt-body-start ()
  "Return the content start for the Org heading at point."
  (save-excursion
    (forward-line 1)
    (when (looking-at-p "[ \t]*:PROPERTIES:[ \t]*$")
      (when (re-search-forward "^[ \t]*:END:[ \t]*$" nil t)
        (forward-line 1)))
    (point)))

(defun agent-capture--select-prompt (prompts)
  "Prompt for one of PROMPTS and return its plist."
  (let* ((candidates (mapcar #'agent-capture--prompt-candidate prompts))
         (choice (completing-read "Prompt: " candidates nil t)))
    (or (get-text-property 0 'agent-prompt choice)
        (get-text-property
         0 'agent-prompt
         (cl-find choice candidates :test #'string=)))))

(defun agent-capture--prompt-candidate (prompt)
  "Return a completion candidate for captured PROMPT."
  (let ((label (agent-capture--prompt-candidate-label prompt)))
    (propertize label 'agent-prompt prompt)))

(defun agent-capture--prompt-candidate-label (prompt)
  "Return the completion label for captured PROMPT."
  (let ((heading (if-let* ((created (plist-get prompt :created)))
                     (format "%s %s" created (plist-get prompt :title))
                   (plist-get prompt :title)))
        (preview (agent-capture--prompt-preview prompt)))
    (if (string-empty-p preview)
        heading
      (format "%s: %s" heading preview))))

(defun agent-capture--prompt-preview (prompt)
  "Return a single-line truncated preview for captured PROMPT."
  (truncate-string-to-width
   (replace-regexp-in-string
    "[[:space:]\n]+" " " (string-trim (or (plist-get prompt :text) "")))
   agent-capture--preview-width nil nil "..."))

(defun agent-capture--delete-prompt (prompt)
  "Remove PROMPT's Org entry from its capture file."
  (when-let* ((file (plist-get prompt :file)))
    (let ((buffer (find-file-noselect file)))
      (with-current-buffer buffer
        (org-mode)
        (when (agent-capture--find-prompt prompt)
          (delete-region
           (point)
           (save-excursion
             (or (outline-next-heading) (goto-char (point-max)))
             (point)))
          (save-buffer))))))

(defun agent-capture--find-prompt (prompt)
  "Move point to PROMPT's matching Org heading in the current buffer."
  (goto-char (point-min))
  (catch 'found
    (while (re-search-forward org-heading-regexp nil t)
      (goto-char (match-beginning 0))
      (when (agent-capture--prompt-match-p prompt)
        (throw 'found t))
      (or (outline-next-heading) (goto-char (point-max))))
    nil))

(defun agent-capture--prompt-match-p (prompt)
  "Return non-nil when the current Org heading matches PROMPT."
  (when-let* ((candidate (agent-capture--prompt-at-point
                          (plist-get prompt :file) t)))
    (and (equal (plist-get candidate :title)
                (plist-get prompt :title))
         (equal (plist-get candidate :created)
                (plist-get prompt :created))
         (equal (plist-get candidate :text)
                (plist-get prompt :text)))))

;;;; Provide

(provide 'agent-capture)
;;; agent-capture.el ends here
