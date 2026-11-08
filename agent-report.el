;;; agent-report.el --- File a bug report or feature idea as a GitHub issue -*- lexical-binding: t -*-

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
;; files it as an issue on `agent-report-repository' with the GitHub
;; CLI, for the maintainer to act on.  The phone page of `agent-remote'
;; offers the same through its Report button.

;;; Code:

(require 'agent)

(defconst agent-report--package-directory
  (file-name-directory
   (file-truename
    (concat (file-name-sans-extension (or load-file-name buffer-file-name))
            ".el")))
  "Absolute path to the source checkout holding this library.
Resolved through the `.el' file because Elpaca's build directory holds
only the Lisp files.  Its commit goes into every report.")

(defcustom agent-report-repository "benthamite/agent"
  "GitHub repository, as OWNER/NAME, that reports are filed on."
  :type 'string
  :group 'agent)

(defcustom agent-report-gh-program "gh"
  "The GitHub CLI program that files reports."
  :type 'string
  :group 'agent)

(defconst agent-report--title-length 72
  "Most characters of a report's first line that become its title.")

(defconst agent-report--buffer-name "*agent report*"
  "Name of the buffer `agent-report' collects the description in.")

(defvar-keymap agent-report-mode-map
  "C-c C-c" #'agent-report-send
  "C-c C-k" #'agent-report-cancel)

(define-derived-mode agent-report-mode text-mode "Agent-Report"
  "Mode for describing a bug or feature idea for `agent-report'."
  (setq header-line-format
        (substitute-command-keys
         "Describe the bug or idea.  \\[agent-report-send] files it, \\[agent-report-cancel] cancels.")))

;;;###autoload
(defun agent-report ()
  "Describe a bug or feature idea, to be filed as a GitHub issue.
The issue goes to `agent-report-repository' for its maintainer."
  (interactive)
  (pop-to-buffer (get-buffer-create agent-report--buffer-name))
  (unless (derived-mode-p 'agent-report-mode)
    (agent-report-mode)))

(defun agent-report-send ()
  "File the description in the current buffer as a GitHub issue.
The buffer is killed once the issue exists, and kept if filing fails."
  (interactive)
  (let ((text (string-trim (buffer-string)))
        (buffer (current-buffer)))
    (when (string-empty-p text)
      (user-error "Describe the bug or idea first"))
    (message "Filing the report...")
    (agent-report-file
     text "Emacs"
     (lambda (url)
       (when (buffer-live-p buffer)
         (kill-buffer buffer))
       (message "Filed %s" url))
     (lambda (failure)
       (message "Report not filed, and kept in %s: %s"
                agent-report--buffer-name failure)))))

(defun agent-report-cancel ()
  "Discard the description being written."
  (interactive)
  (kill-buffer agent-report--buffer-name))

(defun agent-report-file (text origin on-success on-failure)
  "File report TEXT, sent from ORIGIN, as an issue without waiting.
ORIGIN, such as \"Emacs\" or \"the phone\", is named in the issue.
Call ON-SUCCESS with the issue's URL, or ON-FAILURE with a message
saying what went wrong, once the GitHub CLI has finished."
  (if (not (executable-find agent-report-gh-program))
      (funcall on-failure
               "the GitHub CLI is not installed; install it from https://cli.github.com and run `gh auth login'")
    (let* ((stderr (generate-new-buffer " *agent-report-gh-stderr*" t))
           (process
            (make-process
             :name "agent-report-gh"
             :buffer (generate-new-buffer " *agent-report-gh*" t)
             :stderr stderr
             :connection-type 'pipe
             :noquery t
             :command (list agent-report-gh-program "issue" "create"
                            "--repo" agent-report-repository
                            "--title" (agent-report-title text)
                            "--body-file" "-")
             :sentinel (lambda (process _event)
                         (unless (process-live-p process)
                           (agent-report--finish process stderr
                                                 on-success on-failure))))))
      (process-send-string process (agent-report-body text origin))
      (process-send-eof process))))

(defun agent-report--finish (process stderr on-success on-failure)
  "Report how the GitHub CLI's PROCESS ended, then clean up.
STDERR is its error buffer.  Call ON-SUCCESS with the issue URL it
printed, or ON-FAILURE with its error."
  (let ((output (with-current-buffer (process-buffer process)
                  (string-trim (buffer-string))))
        (failure (with-current-buffer stderr (string-trim (buffer-string)))))
    (kill-buffer (process-buffer process))
    (kill-buffer stderr)
    (if (and (zerop (process-exit-status process))
             (string-match "https://\\S-+" output))
        (funcall on-success (match-string 0 output))
      (funcall on-failure
               (format "%s; if you are not logged in, run `gh auth login'"
                       (if (string-empty-p failure) "gh failed" failure))))))

(defun agent-report-title (text)
  "Return the issue title for report TEXT: its first line, shortened."
  (truncate-string-to-width (car (split-string (string-trim text) "\n"))
                            agent-report--title-length nil nil "…"))

(defun agent-report-body (text origin)
  "Return the issue body for report TEXT sent from ORIGIN.
It is TEXT followed by what the maintainer needs to reproduce a bug."
  (format "%s\n\n---\nReported from %s with `agent-report`.\n\n- agent: %s\n- Emacs: %s\n- System: %s\n"
          text origin (agent-report--package-commit) emacs-version
          system-configuration))

(defun agent-report--package-commit ()
  "Return the commit this package's checkout is at, or \"unknown\"."
  (let ((default-directory agent-report--package-directory))
    (with-temp-buffer
      (if (eq 0 (ignore-errors
                  (call-process "git" nil t nil "rev-parse" "--short" "HEAD")))
          (string-trim (buffer-string))
        "unknown"))))

(provide 'agent-report)

;;; agent-report.el ends here
