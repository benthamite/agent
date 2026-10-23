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
;; CLIs, `emacsclient', the Emacs server, Claude Code's hooks and the
;; skills some commands rely on -- fixes what can be fixed from Emacs
;; after asking, and reports the rest with instructions.

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

(defconst agent-setup--package-directory
  (file-name-directory
   (file-truename
    (concat (file-name-sans-extension (or load-file-name buffer-file-name))
            ".el")))
  "Absolute path to the source checkout holding this library.
Resolved through the `.el' file because Elpaca's build directory holds
only the Lisp files, not the bundled `etc/' directory.")

(defcustom agent-setup-package-directory nil
  "Checkout whose bundled skills `agent-setup' links, or nil.
Nil links the loaded checkout.  Set this to a stable alias of the
checkout when its real path changes, for example between Emacs
profiles, so the links keep working after a change."
  :type '(choice (const :tag "The loaded checkout" nil) directory)
  :group 'agent)

(defun agent-setup--tool-skill-directory (variable default)
  "Return the skills directory under the configuration home in VARIABLE.
VARIABLE names the environment variable the tool reads its home from;
DEFAULT is the home the tool uses when it is unset."
  (file-name-as-directory
   (expand-file-name "skills" (or (getenv variable) default))))

(defcustom agent-setup-skill-directories
  `(("Claude Code" . ,(agent-setup--tool-skill-directory
                       "CLAUDE_CONFIG_DIR" "~/.claude/"))
    ("Codex" . ,(agent-setup--tool-skill-directory "CODEX_HOME" "~/.codex/")))
  "Directories `agent-setup' links the bundled skills into.
Each entry is (TOOL . DIRECTORY).  A tool whose configuration
directory, the parent of DIRECTORY, does not exist is skipped.  The
defaults are the skills directories of the homes Claude Code and Codex
read, `CLAUDE_CONFIG_DIR' and `CODEX_HOME', when Emacs has them set."
  :type '(alist :key-type string :value-type directory)
  :group 'agent)

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
Offer to link the skills bundled with agent into each tool's skills
directory; `agent-handoff' needs the handoff skill.  Ask before each
change.  Missing programs are reported with instructions, since
installing them is left to the user."
  (interactive)
  (agent-setup--report
   (append
    (list (agent-setup--check-program
           'claude (agent-setup--program 'claude-code-program "claude"))
          (agent-setup--check-program
           'codex (agent-setup--program 'codex-program "codex"))
          (agent-setup--check-program 'emacsclient "emacsclient")
          (agent-setup--check-server))
    (delq nil (list (agent-setup--check-codex-timeout
                     (agent-setup--program 'codex-program "codex"))))
    (agent-setup--check-claude-settings)
    (agent-setup--check-skills))))

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

(defun agent-setup--check-codex-timeout (codex)
  "Return the check result for the timeout program Codex sessions need, or nil.
CODEX is the Codex program.  agent-log lists Codex sessions from a
catalog it builds behind `timeout' or `gtimeout', and macOS ships
neither; without one its session browser and search silently show no
Codex sessions.  Return nil when CODEX or agent-log is not installed."
  (when (and (executable-find codex) (locate-library "agent-log-codex"))
    (if-let* ((file (seq-some #'executable-find '("timeout" "gtimeout"))))
        (list :ok t :label (format "timeout found at %s"
                                   (abbreviate-file-name file)))
      (list :ok nil :label "timeout and gtimeout not found"
            :hint "agent-log lists no Codex sessions without one; on macOS, run brew install coreutils"))))

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

;;;; Bundled skills

(defun agent-setup--skills-source ()
  "Return the directory holding the skills bundled with agent."
  (file-name-as-directory
   (expand-file-name "etc/skills"
                     (or agent-setup-package-directory
                         agent-setup--package-directory))))

(defun agent-setup--bundled-skills ()
  "Return the names of the skills bundled with agent."
  (let ((source (agent-setup--skills-source)))
    (seq-filter (lambda (name)
                  (file-exists-p (expand-file-name "SKILL.md"
                                                   (expand-file-name name source))))
                (and (file-directory-p source)
                     (directory-files source nil "\\`[^.]")))))

(defun agent-setup--check-skills ()
  "Return the check results for the bundled skills, one per tool.
Offer to link the skills that are not installed."
  (delq nil
        (mapcar (lambda (entry)
                  (agent-setup--check-skill-directory (car entry) (cdr entry)))
                agent-setup-skill-directories)))

(defun agent-setup--check-skill-directory (tool directory)
  "Return the check result for the bundled skills of TOOL in DIRECTORY.
Return nil when TOOL has no configuration directory.  Offer to link the
skills that are missing or linked to another checkout.  A skill of the
same name that agent did not link is the user's own and is left alone."
  (let* ((directory (file-name-as-directory (expand-file-name directory)))
         (name (abbreviate-file-name directory)))
    (when (file-directory-p (file-name-directory (directory-file-name directory)))
      (let* ((states (mapcar (lambda (skill)
                               (cons skill (agent-setup--skill-state skill directory)))
                             (agent-setup--bundled-skills)))
             (wanted (agent-setup--skills-in-state states 'missing 'stale)))
        (cond ((null wanted)
               (list :ok t :label (agent-setup--skills-label tool name states)))
              ((y-or-n-p (format "Link %s into %s? "
                                 (agent-setup--skill-list wanted) name))
               (dolist (skill wanted)
                 (agent-setup--link-skill skill directory))
               (list :ok t :label (format "%s skills linked into %s: %s"
                                          tool name (string-join wanted ", "))))
              (t
               (list :ok nil
                     :label (format "%s skills not linked into %s: %s"
                                    tool name (string-join wanted ", "))
                     :hint (if (member "handoff" wanted)
                               "agent-handoff needs the handoff skill; \
run M-x agent-setup again to link it"
                             "Run M-x agent-setup again to link them"))))))))

(defun agent-setup--skill-state (skill directory)
  "Return how the bundled SKILL is installed in DIRECTORY.
The value is `linked' when it is a link to the bundled skill, `stale'
when it is a link to another checkout's copy or to nothing, `own' when
something else has that name, and `missing' otherwise."
  (let* ((target (expand-file-name skill directory))
         (source (expand-file-name skill (agent-setup--skills-source)))
         (link (file-symlink-p target)))
    (cond ((and link (equal (file-truename target) (file-truename source)))
           'linked)
          ((and link (or (not (file-exists-p target))
                         (string-suffix-p (concat "etc/skills/" skill)
                                          (directory-file-name link))))
           'stale)
          ((or link (file-exists-p target)) 'own)
          (t 'missing))))

(defun agent-setup--skills-in-state (states &rest wanted)
  "Return the skills in STATES whose state is one of WANTED.
STATES is an alist from skill name to state."
  (mapcar #'car (seq-filter (lambda (state) (memq (cdr state) wanted)) states)))

(defun agent-setup--link-skill (skill directory)
  "Link the bundled SKILL into DIRECTORY, replacing a stale link."
  (let ((target (expand-file-name skill directory)))
    (make-directory directory t)
    (when (file-symlink-p target)
      (delete-file target))
    (make-symbolic-link (expand-file-name skill (agent-setup--skills-source))
                        target)))

(defun agent-setup--skills-label (tool name states)
  "Return the label for TOOL's skills in the directory NAME, all settled.
STATES is an alist from skill name to state."
  (let ((linked (agent-setup--skills-in-state states 'linked))
        (own (agent-setup--skills-in-state states 'own)))
    (concat (if linked
                (format "%s skills linked into %s: %s"
                        tool name (string-join linked ", "))
              (format "%s skills in %s are your own" tool name))
            (when (and linked own)
              (format " (your own %s left alone)" (string-join own ", "))))))

(defun agent-setup--skill-list (skills)
  "Return a phrase naming SKILLS, such as \"the handoff skill\"."
  (if (cdr skills)
      (format "the %s skills" (string-join skills ", "))
    (format "the %s skill" (car skills))))

;;;; Report

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
