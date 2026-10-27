;;; agent-doom-modeline.el --- Session modeline for doom-modeline -*- lexical-binding: t -*-

;; Copyright (C) 2026

;; Author: Pablo Stafforini
;; URL: https://github.com/benthamite/agent
;; Version: 0.1
;; Package-Requires: ((emacs "30.0"))

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

;; The `ai-session' modeline that session buffers use under
;; `doom-modeline': the backend icon, the session name, the model, the
;; reasoning effort, the account and the status the session's agent
;; last published.
;;
;; `doom-modeline' is optional.  `agent' loads this file only once
;; `doom-modeline' is loaded, and nothing here is needed without it.

;;; Code:

(declare-function agent--detect-backend "agent")
(declare-function agent-backend-icon-string "agent")
(declare-function agent-display-name "agent")
(declare-function agent-session "agent")
(declare-function agent-session-account "agent")
(declare-function agent-session-state-summary "agent")
(declare-function agent-session-accepts-wake-ups-p "agent")
(declare-function agent-claude-status-model "agent-claude")
(declare-function agent-claude-status-effort "agent-claude")
(declare-function agent-codex-status-model "agent-codex")
(declare-function agent-codex-status-effort "agent-codex")
(declare-function doom-modeline-spc "doom-modeline-core")
(declare-function doom-modeline-def-modeline "doom-modeline-core")

(defun agent-doom-modeline-session-status ()
  "Return the description of the current buffer's session for the modeline.
It holds the backend icon, the session name, the model, the reasoning
effort, the account and the status the session's agent last published,
with a monitor icon after the name while the session accepts wake-ups
from outside tools.
Return nil when the current buffer is not a session."
  (when-let* ((backend (agent--detect-backend (current-buffer))))
    (let ((icon (agent-backend-icon-string backend 'mode-line-active))
          (session (agent-session)))
      (concat
       (doom-modeline-spc)
       (unless (string-empty-p icon) (concat icon " "))
       (propertize (agent-display-name (current-buffer))
                   'face '(bold doom-modeline-buffer-major-mode))
       (when (agent-session-accepts-wake-ups-p (current-buffer))
         (concat " " (agent-doom-modeline--monitor-icon)))
       (agent-doom-modeline--field (agent-doom-modeline--model backend) "Model")
       (agent-doom-modeline--field (agent-doom-modeline--effort backend)
                                   "Reasoning effort")
       (agent-doom-modeline--field (and session (agent-session-account session))
                                   "Account" 'doom-modeline-buffer-path)
       (agent-doom-modeline--field
        (agent-session-state-summary (current-buffer))
        "Latest published session status")
       (doom-modeline-spc)))))

(defun agent-doom-modeline--monitor-icon ()
  "Return the icon that marks a session accepting wake-ups.
Use a Nerd Fonts broadcast icon when `nerd-icons' is available, else M."
  (propertize (or (and (fboundp 'nerd-icons-mdicon)
                       (ignore-errors (nerd-icons-mdicon "nf-md-access_point")))
                  "M")
              'help-echo "Monitor on: accepts wake-ups from outside tools (m m in agent-menu)"))

(defun agent-doom-modeline--model (backend)
  "Return the model name of the current buffer's session, or nil.
BACKEND is the name of the session's backend."
  (pcase backend
    ('claude-code (agent-claude-status-model))
    ('codex (agent-codex-status-model))))

(defun agent-doom-modeline--effort (backend)
  "Return the reasoning effort of the current buffer's session, or nil.
BACKEND is the name of the session's backend."
  (pcase backend
    ('claude-code (agent-claude-status-effort))
    ('codex (agent-codex-status-effort))))

(defun agent-doom-modeline--field (text help &optional face)
  "Return TEXT as a modeline field preceded by a separator, or nil.
HELP is the field's tooltip and FACE, when non-nil, its face.  Return nil
when TEXT is nil.  Each percent sign is doubled, since the modeline would
otherwise read it as a construct."
  (when text
    (let ((field (propertize (string-replace "%" "%%" text) 'help-echo help)))
      (concat " | " (if face (propertize field 'face face) field)))))

(defun agent-doom-modeline-setup ()
  "Define the `ai-session' modeline that session buffers use."
  ;; `doom-modeline-def-segment' is a macro, unknown to the compiler when
  ;; this file is compiled without `doom-modeline' installed.
  (eval '(doom-modeline-def-segment agent-session
           "Describe the AI session of the current buffer."
           (agent-doom-modeline-session-status))
        t)
  (doom-modeline-def-modeline 'ai-session
    '(bar agent-session)
    '(misc-info major-mode process time)))

(agent-doom-modeline-setup)

(provide 'agent-doom-modeline)
;;; agent-doom-modeline.el ends here
