;;; agent-run.el --- Inspect orchestration runs -*- lexical-binding: t -*-

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

;; A read-only view of orchestrate-review run files.  The helper owns all
;; workflow decisions; this module reads recorded state and progress only.

;;; Code:

(require 'agent)
(require 'button)
(require 'json)

(defvar-local agent-run--file nil
  "Run file displayed in this buffer.")

(defvar-local agent-run--timer nil
  "Refresh timer owned by this view.")

(defvar agent-run--history nil
  "History of explicitly opened run files.")

(define-derived-mode agent-run-mode special-mode "Agent Run"
  "Inspect a recorded orchestration run without controlling its actors.
Use \`g' to refresh and \`q' to quit.  Visible views refresh every five seconds."
  (setq-local revert-buffer-function #'agent-run--revert)
  (add-hook 'kill-buffer-hook #'agent-run--stop-timer nil t)
  (add-hook 'change-major-mode-hook #'agent-run--stop-timer nil t))

;;;###autoload
(defun agent-run-open (file)
  "Display the orchestrate-review run in FILE."
  (interactive (list (read-file-name "Orchestration run: " nil
                                     (car agent-run--history) t)))
  (setq file (expand-file-name file))
  (agent-run--read file)
  (add-to-history 'agent-run--history file)
  (let ((buffer (get-buffer-create (format "*Agent Run: %s*" file))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'agent-run-mode) (agent-run-mode))
      (setq agent-run--file file)
      (agent-run--revert)
      (unless (timerp agent-run--timer)
        (setq agent-run--timer
              (run-with-timer 5 5 #'agent-run--refresh-visible buffer))))
    (pop-to-buffer buffer)))

(defun agent-run--read (file)
  "Read supported display fields from FILE without evaluating its contents."
  (when (file-remote-p file) (user-error "Run views require a local file"))
  (with-temp-buffer
    (when (> (file-attribute-size (file-attributes file)) (* 4 1024 1024))
      (user-error "Run file exceeds the 4 MiB display limit"))
    (insert-file-contents file)
    (let ((run (json-parse-buffer :object-type 'alist :array-type 'list
                                  :null-object nil :false-object nil)))
      (unless (and (memq (alist-get 'version run) '(2 3))
                   (stringp (alist-get 'stage run))
                   (stringp (alist-get 'status run))
                   (stringp (alist-get 'repo run))
                   (listp (alist-get 'agent1 run))
                   (listp (alist-get 'agent2 run)))
        (user-error "Unsupported orchestration run format"))
      run)))

(defun agent-run--revert (&rest _ignored)
  "Refresh this view from its run file, exposing read errors in the view."
  (let ((inhibit-read-only t)
        (position (point)))
    (erase-buffer)
    (condition-case error
        (agent-run--render (agent-run--read agent-run--file))
      (error (insert "Run unavailable: " (error-message-string error) "\n"
                     "No cached state is displayed.  Press g to retry.\n")))
    (goto-char (min position (point-max)))))

(defun agent-run--render (run)
  "Insert the recorded state of RUN into the current view."
  (let* ((status (alist-get 'status run))
         (phase (cond ((string-prefix-p "implementation-" status) "implementation")
                      ((equal status "complete") "complete")
                      (t (or (alist-get 'active_phase run)
                             (alist-get 'expected_phase run) "not recorded")))))
    (insert (propertize (format "Stage %s — %s\n\n" (alist-get 'stage run) phase)
                        'face 'bold)
            "Recorded status: " status "\n"
            "Attention: " (cond ((alist-get 'pending_submission run)
                                 "delivery needs reconciliation")
                                ((equal status "implementation-stopped")
                                 "implementation stopped; consult the orchestrator")
                                (t "no separate blocker recorded")) "\n\n")
    (agent-run--actor "Author" (alist-get 'agent1 run))
    (agent-run--actor "Reviewer" (alist-get 'agent2 run))
    (insert "\n")
    (agent-run--progress)
    (insert "\nFiles\n")
    (agent-run--file-link "Run record" agent-run--file)
    (agent-run--file-link "Run directory" (file-name-directory agent-run--file))
    (agent-run--file-link "Repository" (alist-get 'repo run))
    (insert "\nSpec/plan paths and blocker reasons are not stored by this run format.\n"
            "Read-only view; completion and verification remain the helper's responsibility.\n")))

(defun agent-run--actor (label actor)
  "Insert LABEL and an identity-checked link for ACTOR."
  (let ((buffer (agent-run--actor-buffer actor)))
    (insert label ": ")
    (if buffer
        (insert-text-button (buffer-name buffer) 'follow-link t
                            'action (lambda (_) (pop-to-buffer
                                                 (or (agent-run--actor-buffer actor)
                                                     (user-error "Recorded session is no longer live")))))
      (insert (format "%s (recorded session unavailable)"
                      (or (alist-get 'buffer actor) "not recorded"))))
    (insert "\n")))

(defun agent-run--actor-buffer (actor)
  "Return ACTOR's buffer only when its recorded identity still matches."
  (let* ((name (alist-get 'buffer actor))
         (buffer (and (stringp name) (get-buffer name)))
         (identity (alist-get 'identity actor))
         (session (and buffer (agent-session buffer))))
    (when (and session identity (memq buffer (agent-session-buffers))
               (equal (symbol-name (agent-session-backend session))
                      (alist-get 'backend identity))
               (equal (agent-session-id session) (alist-get 'session_id identity))
               (stringp (alist-get 'session_id identity))
               (agent-run--same-directory-p (agent-session-directory session)
                                            (alist-get 'directory identity)))
      buffer)))

(defun agent-run--same-directory-p (left right)
  "Return non-nil when local directory names LEFT and RIGHT resolve alike."
  (and (stringp left) (stringp right)
       (not (string-empty-p left)) (not (string-empty-p right))
       (not (file-remote-p left)) (not (file-remote-p right))
       (equal (directory-file-name (file-truename left))
              (directory-file-name (file-truename right)))))

(defun agent-run--progress ()
  "Insert the latest nonblank progress line and its file age."
  (let* ((file (concat agent-run--file ".progress"))
         (attributes (file-attributes file)))
    (if (not attributes)
        (insert "Progress: not published\n")
      (let* ((size (file-attribute-size attributes))
             (start (max 0 (- size 16384)))
             (latest (with-temp-buffer
                       (insert-file-contents file nil start size)
                       (when (> start 0) (delete-region (point-min)
                                                       (progn (goto-char (point-min))
                                                              (forward-line 1) (point))))
                       (car (last (split-string (buffer-string) "[\r\n]+" t "[ \t]+"))))))
        (insert "Progress: " (or latest "no nonblank line in the last 16 KiB") "\n"
                (format "Progress file updated %s ago\n"
                        (format-seconds "%hh %mm %ss"
                                        (max 0 (float-time
                                                (time-subtract nil
                                                 (file-attribute-modification-time attributes)))))))
        (agent-run--file-link "Progress file" file)))))

(defun agent-run--file-link (label file)
  "Insert a read-only navigation link labeled LABEL to local FILE."
  (insert-text-button label 'follow-link t
                      'action (lambda (_)
                                (when (file-remote-p file)
                                  (user-error "Run links require local paths"))
                                (unless (file-exists-p file)
                                  (user-error "Recorded path no longer exists: %s" file))
                                (if (file-directory-p file)
                                    (dired file)
                                  (let ((enable-local-variables nil)
                                        (enable-local-eval nil))
                                    (view-file file)))))
  (insert "\n"))

(defun agent-run--refresh-visible (buffer)
  "Refresh BUFFER only while it is displayed."
  (when (and (buffer-live-p buffer) (get-buffer-window buffer t))
    (with-current-buffer buffer
      (when (and (derived-mode-p 'agent-run-mode) agent-run--file)
        (agent-run--revert)))))

(defun agent-run--stop-timer ()
  "Cancel the refresh timer owned by this view."
  (when (timerp agent-run--timer) (cancel-timer agent-run--timer))
  (setq agent-run--timer nil))

(provide 'agent-run)
;;; agent-run.el ends here
