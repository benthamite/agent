;;; agent-report.el --- Turn a bug report or feature idea into a pull request -*- lexical-binding: t -*-

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

;; `agent-report' asks for a description of a bug or a feature idea and
;; hands it to a new agent session, which works out where the change
;; belongs, makes it in a fresh clone and opens a pull request for the
;; maintainer to review.  The phone page of `agent-remote' offers the
;; same through its Report button.

;;; Code:

(require 'agent)

(defconst agent-report--package-directory
  (file-name-directory
   (file-truename
    (concat (file-name-sans-extension (or load-file-name buffer-file-name))
            ".el")))
  "Absolute path to the source checkout holding this library.
Resolved through the `.el' file because Elpaca's build directory holds
only the Lisp files, not the bundled `etc/' directory.  The reporting
session runs here.")

(defcustom agent-report-prompt-file
  (expand-file-name "etc/agent-report-prompt.md"
                    agent-report--package-directory)
  "File holding the instructions a reporting session starts with.
In it, {{REPORT}} stands for the report, {{AGENT_DIR}} for the source
checkout of this package and {{EMACS_DIR}} for `user-emacs-directory'."
  :type 'file
  :group 'agent)

(defconst agent-report--buffer-name "*agent report*"
  "Name of the buffer `agent-report' collects the description in.")

(defvar-keymap agent-report-mode-map
  "C-c C-c" #'agent-report-send
  "C-c C-k" #'agent-report-cancel)

(define-derived-mode agent-report-mode text-mode "Agent-Report"
  "Mode for describing a bug or feature idea for `agent-report'."
  (setq header-line-format
        (substitute-command-keys
         "Describe the bug or idea.  \\[agent-report-send] sends it, \\[agent-report-cancel] cancels.")))

;;;###autoload
(defun agent-report ()
  "Describe a bug or feature idea, to become a pull request.
The description goes to a new agent session, which turns it into a
pull request for the maintainer of Agent Emacs to review."
  (interactive)
  (pop-to-buffer (get-buffer-create agent-report--buffer-name))
  (unless (derived-mode-p 'agent-report-mode)
    (agent-report-mode)))

(defun agent-report-send ()
  "Send the description in the current buffer to a new agent session."
  (interactive)
  (let ((text (string-trim (buffer-string))))
    (when (string-empty-p text)
      (user-error "Describe the bug or idea first"))
    (let ((buffer (agent-report-submit text (agent-read-backend))))
      (kill-buffer agent-report--buffer-name)
      (pop-to-buffer buffer))))

(defun agent-report-cancel ()
  "Discard the description being written."
  (interactive)
  (kill-buffer agent-report--buffer-name))

(defun agent-report-submit (text backend)
  "Start a BACKEND session that turns report TEXT into a pull request.
The session runs in this package's source checkout, under an instance
name of the form report-N when a BACKEND session already runs there.
Return its buffer."
  (unless (assq backend agent-backends)
    (user-error "No AI backend named `%s'" backend))
  (let ((directory (abbreviate-file-name agent-report--package-directory)))
    (agent-start-session
     (agent-session-create
      :backend backend
      :directory directory
      :instance (agent--free-instance-name backend directory "report"))
     :initial-prompt (agent-report-prompt text))))

(defun agent-report-prompt (text)
  "Return the instructions for a session handling report TEXT.
They are `agent-report-prompt-file' with its placeholders filled in.
TEXT goes in last, so that a report quoting a placeholder stays as
written."
  (let ((template (with-temp-buffer
                    (insert-file-contents agent-report-prompt-file)
                    (buffer-string))))
    (dolist (pair `(("{{AGENT_DIR}}" . ,(abbreviate-file-name
                                         agent-report--package-directory))
                    ("{{EMACS_DIR}}" . ,(abbreviate-file-name
                                         (expand-file-name user-emacs-directory)))
                    ("{{REPORT}}" . ,text)))
      (setq template (string-replace (car pair) (cdr pair) template)))
    template))

(provide 'agent-report)

;;; agent-report.el ends here
