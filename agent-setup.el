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
(declare-function agent-claude-setup-config "agent-claude")
(declare-function agent-claude--read-json-object "agent-claude" (file))
(declare-function agent-claude--agent-statusline-p "agent-claude" (statusline))

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
through, and add agent's status line and hooks to Claude Code's
settings, asking before each.  Missing programs are reported with
instructions, since installing them is left to the user."
  (interactive)
  (agent-setup--report
   (list (agent-setup--check-program
          'claude (agent-setup--program 'claude-code-program "claude"))
         (agent-setup--check-program
          'codex (agent-setup--program 'codex-program "codex"))
         (agent-setup--check-program 'emacsclient "emacsclient")
         (agent-setup--check-server)
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
  "Return the Claude settings check result, updating the settings if needed.
Settings that already carry agent's status line are refreshed without
asking, because the update rewrites only entries agent owns."
  (if (not (require 'agent-claude nil t))
      (list :ok nil :label "agent-claude could not be loaded"
            :hint "Install the claude-code and consult packages")
    (let* ((file agent-claude-settings-file)
           (before (agent-setup--claude-statusline-state file)))
      (when (or (eq before 'agent)
                (y-or-n-p (format "Add agent's status line and hooks to %s? "
                                  (abbreviate-file-name file))))
        (agent-claude-setup-config))
      (agent-setup--claude-settings-result
       file before (agent-setup--claude-statusline-state file)))))

(defun agent-setup--claude-statusline-state (file)
  "Return who owns the status line in Claude settings FILE.
The value is `agent', `other', or nil when FILE sets no status line."
  (when-let* ((statusline (gethash "statusLine"
                                   (agent-claude--read-json-object file))))
    (if (agent-claude--agent-statusline-p statusline) 'agent 'other)))

(defun agent-setup--claude-settings-result (file before after)
  "Return the check result for Claude settings FILE.
BEFORE and AFTER are the status-line states, as returned by
`agent-setup--claude-statusline-state', before and after setup ran."
  (let ((name (abbreviate-file-name file)))
    (cond ((eq after 'agent)
           (list :ok t :label (format "Claude Code hooks installed in %s" name)))
          ((eq before 'other)
           (list :ok nil :label "Claude Code uses another status line"
                 :hint (format "Remove the statusLine entry from %s and rerun \
M-x agent-setup; without agent's status line, session status is approximate"
                               name)))
          (t
           (list :ok nil :label "Claude Code hooks not installed"
                 :hint "Rerun M-x agent-setup and accept the settings change")))))

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
