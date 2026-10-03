;;; agent-setup.el --- First-run checks for agent -*- lexical-binding: t -*-

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

;; `agent-setup' checks what agent needs outside Emacs -- the agent
;; CLIs, `emacsclient', the Emacs server and Claude Code's hooks --
;; fixes what can be fixed from Emacs after asking, and reports the
;; rest with instructions.

;;; Code:

(require 'server)
(require 'seq)
(require 'subr-x)

(defvar claude-code-program)
(defvar codex-program)
(defvar agent-claude-settings-file)
(defvar agent-claude-use-session-settings)
(declare-function agent-claude--session-settings-file "agent-claude" (&optional base))
(declare-function agent-claude-global-config-entries "agent-claude" (&optional file))
(declare-function agent-claude-remove-global-config "agent-claude" (&optional file))

(defconst agent-setup-buffer-name "*agent-setup*"
  "Name of the buffer `agent-setup' reports in.")

(defconst agent-setup--install-hints
  '((claude . "Install Claude Code: https://code.claude.com/docs/en/setup")
    (codex . "Install Codex: npm install -g @openai/codex")
    (emacsclient . "Put the directory holding Emacs's emacsclient on PATH"))
  "Instructions shown for each missing program.")

;;;###autoload
(defun agent-setup ()
  "Check what agent needs, offer to fix it, and report the result.
Start the Emacs server, which the Claude Code hooks report session state
through, and check the settings agent passes to each Claude session.
Offer to remove agent entries that earlier versions wrote into Claude
Code's global settings, since sessions would receive those events twice.
Ask before each change.  Missing programs are reported with
instructions, since installing them is left to the user."
  (interactive)
  (agent-setup--report
   (append
    (list (agent-setup--check-program
           'claude (agent-setup--program 'claude-code-program "claude"))
          (agent-setup--check-program
           'codex (agent-setup--program 'codex-program "codex"))
          (agent-setup--check-program 'emacsclient "emacsclient")
          (agent-setup--check-server))
    (agent-setup--check-claude-settings))))

(defun agent-setup--program (variable default)
  "Return the value of VARIABLE when it is bound, else DEFAULT."
  (if (boundp variable) (symbol-value variable) default))

(defun agent-setup--check-program (name program)
  "Return the check result for the program NAME, run as PROGRAM."
  (if-let* ((file (executable-find program)))
      (list :ok t :label (format "%s found at %s" name
                                 (abbreviate-file-name file)))
    (list :ok nil :label (format "%s not found" name)
          :hint (alist-get name agent-setup--install-hints))))

(defun agent-setup--check-server ()
  "Return the server check result, starting the server if the user agrees."
  (when (and (not (bound-and-true-p server-process))
             (y-or-n-p "Start the Emacs server so agent sessions can \
report their state? "))
    (server-start))
  (if (bound-and-true-p server-process)
      (list :ok t :label (format "Emacs server running (%s)" server-name))
    (list :ok nil :label "Emacs server not running"
          :hint "Run M-x server-start, or add (server-start) to your init file")))

(defun agent-setup--check-claude-settings ()
  "Return the check results for Claude Code's status line and hooks."
  (if (not (require 'agent-claude nil t))
      (list (list :ok nil :label "agent-claude could not be loaded"
                  :hint "Install the claude-code and consult packages"))
    (list (agent-setup--check-session-settings)
          (agent-setup--check-global-settings))))

(defun agent-setup--check-session-settings ()
  "Return the check result for the settings agent passes to Claude sessions."
  (if (not agent-claude-use-session-settings)
      (list :ok nil :label "agent-claude-use-session-settings is off"
            :hint "Without it, run M-x agent-claude-setup-config to install the hooks globally")
    (condition-case err
        (list :ok t
              :label (format "Claude Code hooks passed to each session (%s)"
                             (abbreviate-file-name
                              (agent-claude--session-settings-file))))
      (error
       (list :ok nil :label "Claude Code session settings could not be written"
             :hint (error-message-string err))))))

(defun agent-setup--check-global-settings ()
  "Return the check result for agent entries left in global Claude settings.
Offer to remove them, since sessions would otherwise receive each event
twice."
  (let* ((file agent-claude-settings-file)
         (name (abbreviate-file-name file))
         (count (length (agent-claude-global-config-entries file))))
    (cond ((or (zerop count) (not agent-claude-use-session-settings))
           (list :ok t :label (format "%s left alone" name)))
          ((y-or-n-p (format "Remove %d agent entries from %s?  Agent now \
passes them to each session itself " count name))
           (agent-claude-remove-global-config file)
           (list :ok t :label (format "Removed %d agent entries from %s"
                                      count name)))
          (t
           (list :ok nil
                 :label (format "%d agent entries remain in %s" count name)
                 :hint "Sessions receive those events twice; run M-x agent-claude-remove-global-config")))))

(defun agent-setup--report (checks)
  "Show CHECKS in `agent-setup-buffer-name' and return the buffer.
Each check is a plist with `:ok', `:label' and an optional `:hint'."
  (with-current-buffer (get-buffer-create agent-setup-buffer-name)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (insert "agent setup\n\n")
      (dolist (check checks)
        (insert (if (plist-get check :ok) "  ✓ " "  ✗ ")
                (plist-get check :label) "\n")
        (when-let* ((hint (plist-get check :hint)))
          (insert "      " hint "\n")))
      (insert "\n"
              (if (seq-every-p (lambda (check) (plist-get check :ok)) checks)
                  "Everything is in place."
                "Fix the items marked ✗, then run M-x agent-setup again.")
              "\nStart a session with M-x agent-menu.\n"))
    (special-mode)
    (goto-char (point-min))
    (pop-to-buffer (current-buffer))
    (current-buffer)))

(provide 'agent-setup)
;;; agent-setup.el ends here
