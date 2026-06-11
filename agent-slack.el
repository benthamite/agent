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

;; Slack-to-project routing for AI coding sessions.  Identifies the
;; Epoch project a Slack message belongs to with `gptel', starts a
;; session in the project directory, and inserts the message URL into
;; the prompt for review.

;;; Code:

(require 'agent)

;;;; Customization

(define-obsolete-variable-alias 'agent-claude-debug-slack-message-model
  'agent-act-on-slack-message-model "0.2")
(define-obsolete-variable-alias 'agent-claude-act-on-slack-message-model
  'agent-act-on-slack-message-model "0.2")
(make-obsolete-variable 'agent-codex-debug-slack-message-model
                        'agent-act-on-slack-message-model "0.2")
(make-obsolete-variable 'agent-codex-act-on-slack-message-model
                        'agent-act-on-slack-message-model "0.2")

(defcustom agent-act-on-slack-message-model 'gemini-flash-lite-latest
  "GPtel model for selecting an Epoch project from a Slack message."
  :type 'symbol
  :group 'agent)

(define-obsolete-variable-alias 'agent-claude-debug-slack-message-backend
  'agent-act-on-slack-message-backend "0.2")
(define-obsolete-variable-alias 'agent-claude-act-on-slack-message-backend
  'agent-act-on-slack-message-backend "0.2")
(make-obsolete-variable 'agent-codex-debug-slack-message-backend
                        'agent-act-on-slack-message-backend "0.2")
(make-obsolete-variable 'agent-codex-act-on-slack-message-backend
                        'agent-act-on-slack-message-backend "0.2")

(defcustom agent-act-on-slack-message-backend "Gemini"
  "GPtel backend name for Slack message project selection."
  :type 'string
  :group 'agent)

(defcustom agent-epoch-project-registry-file nil
  "JSON registry of canonical Epoch projects.
When nil, Slack message routing is unavailable until configured."
  :type '(choice (const :tag "Unconfigured" nil) file)
  :group 'agent)

(defcustom agent-epoch-projects-root nil
  "Root directory containing canonical Epoch automation project files.
When nil, registry entries with relative paths cannot be resolved."
  :type '(choice (const :tag "Unconfigured" nil) directory)
  :group 'agent)

;;;; Forward declarations

(defvar gptel-backend)
(defvar gptel-include-reasoning)
(defvar gptel-model)
(defvar gptel-use-tools)
(defvar gptel--known-backends)
(defvar slack-current-buffer)
(defvar slack-get-permalink-url)
(declare-function gptel-request "gptel")
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
(defun agent-act-on-slack-message ()
  "Route the Slack message at point to an Epoch project session.
Identifies the project with `gptel', starts a session in the
project directory, and inserts the Slack message URL into the
prompt for review without submitting it."
  (interactive)
  (let ((backend (agent--resolve-backend)))
    (agent-slack--act-on-message
     agent-act-on-slack-message-model
     agent-act-on-slack-message-backend
     (lambda (project slack-url)
       (agent-slack--act-on-start-session backend project slack-url)))))

;;;###autoload
(define-obsolete-function-alias
  'agent-debug-slack-message #'agent-act-on-slack-message "0.2")

(defun agent-slack--act-on-start-session (backend project slack-url)
  "Start a BACKEND session for PROJECT and insert SLACK-URL.
PROJECT is an Epoch registry project plist.  Return the new session
buffer with SLACK-URL inserted into its prompt, unsubmitted."
  (let ((dir (file-name-as-directory
              (expand-file-name (plist-get project :directory)))))
    (message "Starting %s for `%s' in %s..."
             (agent--backend-get backend :label)
             (plist-get project :id) dir)
    (let ((buffer (agent-start-session
                   (agent-session-create :backend backend :directory dir))))
      (agent-send-string slack-url buffer)
      buffer)))

(defun agent-slack--act-on-message (model backend start-function)
  "Route the Slack message at point using MODEL, BACKEND, and START-FUNCTION.
START-FUNCTION is called with the selected project plist and the
Slack message URL."
  (agent-slack--with-message-context
   (lambda (context)
     (agent-slack--identify-epoch-project
      context model backend start-function))))

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
                      :room-id (agent-slack--slot-value room 'id)))))))

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
                         (agent-slack--slot-value team 'domain))
                    (and (slot-boundp team 'name)
                         (agent-slack--slot-value team 'name)))))
    (unless domain
      (user-error "Slack team has no domain"))
    (format "https://%s.slack.com/archives/%s/p%s"
            domain (agent-slack--slot-value room 'id)
            (replace-regexp-in-string "\\." "" ts))))

(defun agent-slack--slot-value (object slot)
  "Return OBJECT's dynamic EIEIO SLOT value."
  (eieio-oref object slot))

(defun agent-slack--identify-epoch-project
    (context model backend callback)
  "Identify the Epoch project for Slack CONTEXT and call CALLBACK.
MODEL and BACKEND configure the `gptel' request.  CALLBACK is
called with the selected project plist and Slack URL."
  (unless (and (require 'gptel nil t) (fboundp 'gptel-request))
    (user-error "Package `gptel' is required for Slack message routing"))
  (let* ((projects (agent-epoch-project-candidates))
         (prompt (agent-slack--project-selection-prompt context projects))
         (gptel-backend (alist-get backend gptel--known-backends nil nil
                                   #'string=))
         (gptel-model model)
         (gptel-include-reasoning nil)
         (gptel-use-tools nil))
    (message "Identifying Epoch project from Slack message...")
    (gptel-request
     prompt
     :system (concat
              "You route Slack messages to existing Epoch automation "
              "projects. Return ONLY a comma-separated list of project IDs "
              "from the provided registry, ordered from most likely to least "
              "likely. Do not invent project IDs.")
     :callback
     (lambda (response info)
       (if (not response)
           (message "gptel request failed: %s" (plist-get info :status))
         (when-let* ((text (agent--gptel-response-text response)))
           (agent-slack--read-epoch-project-from-response
            text projects (plist-get context :url) callback)))))))

(defun agent-slack--project-selection-prompt (context projects)
  "Return a project-selection prompt from Slack CONTEXT and PROJECTS."
  (format "Slack message URL: %s\n\nSlack message text:\n%s\n\nProjects:\n%s"
          (plist-get context :url)
          (plist-get context :text)
          (string-join (mapcar #'agent-slack--format-epoch-project projects) "\n")))

(defun agent-slack--format-epoch-project (project)
  "Format PROJECT as one compact registry line."
  (format "- %s | %s | %s | outputs: %s | notes: %s"
          (plist-get project :id)
          (plist-get project :title)
          (plist-get project :summary)
          (or (plist-get project :outputs) "")
          (or (plist-get project :comments) "")))

(defun agent-slack--read-epoch-project-from-response
    (response projects slack-url callback)
  "Read a project from RESPONSE and call CALLBACK with SLACK-URL."
  (let* ((ids (mapcar #'string-trim (split-string response "," t)))
         (candidates (agent-slack--ordered-epoch-project-candidates ids projects))
         (labels (mapcar #'agent-slack--epoch-project-label candidates))
         (selected (completing-read "Project: " labels nil t nil nil
                                    (car labels)))
         (project (nth (cl-position selected labels :test #'string=)
                       candidates)))
    (funcall callback project slack-url)))

(defun agent-slack--ordered-epoch-project-candidates (ids projects)
  "Return PROJECTS ordered by candidate IDS, with remaining projects appended."
  (let ((matched (delq nil
                       (mapcar (lambda (id)
                                 (cl-find id projects :key
                                          (lambda (project)
                                            (plist-get project :id))
                                          :test #'string=))
                               ids))))
    (append matched (cl-set-difference projects matched :test #'eq))))

(defun agent-slack--epoch-project-label (project)
  "Return a completion label for PROJECT."
  (format "%s - %s" (plist-get project :id) (plist-get project :title)))

(defun agent-epoch-project-candidates ()
  "Return canonical Epoch project candidates from the registry file."
  (unless agent-epoch-project-registry-file
    (user-error
     "Set `agent-epoch-project-registry-file' to your registry JSON"))
  (unless (file-exists-p agent-epoch-project-registry-file)
    (user-error "Epoch project registry not found: %s"
                agent-epoch-project-registry-file))
  (with-temp-buffer
    (insert-file-contents agent-epoch-project-registry-file)
    (agent-slack--epoch-projects-from-json (buffer-string))))

(defun agent-slack--epoch-projects-from-json (json)
  "Return project plists parsed from registry JSON."
  (let* ((data (json-parse-string json :object-type 'alist
                                  :array-type 'list))
         (projects (alist-get 'projects data)))
    (mapcar #'agent-slack--epoch-project-from-project-registry projects)))

(defun agent-slack--epoch-project-from-project-registry (project)
  "Return an internal project plist from canonical PROJECT registry entry."
  (let* ((repo (car (agent-slack--json-list (alist-get 'repo_paths project))))
         (doc (car (agent-slack--json-list (alist-get 'project_doc_paths project)))))
    (list :id (alist-get 'id project)
          :title (alist-get 'title project)
          :summary (agent-slack--epoch-project-registry-summary project)
          :comments (agent-slack--epoch-project-registry-notes project)
          :outputs (string-join
                    (agent-slack--json-list (alist-get 'slack_channels project))
                    ", ")
          :directory (agent-slack--epoch-project-directory-from-paths doc repo)
          :repo repo
          :doc doc)))

(defun agent-slack--epoch-project-registry-summary (project)
  "Return a compact summary for canonical PROJECT registry entry."
  (or (alist-get 'summary project)
      (let ((aliases (agent-slack--json-list (alist-get 'aliases project))))
        (if aliases
            (format "Aliases: %s" (string-join aliases ", "))
          ""))))

(defun agent-slack--epoch-project-registry-notes (project)
  "Return matching notes for canonical PROJECT registry entry."
  (let ((keywords (agent-slack--json-list (alist-get 'browser_keywords project))))
    (if keywords
        (format "keywords: %s" (string-join keywords ", "))
      "")))

(defun agent-slack--epoch-project-directory-from-paths (doc repo)
  "Return the best local working directory for relative DOC and REPO paths."
  (cond
   (doc (file-name-directory (agent-slack--epoch-project-path doc)))
   (repo (file-name-directory
          (directory-file-name (agent-slack--epoch-project-path repo))))
   (t (or agent-epoch-projects-root
          (user-error
           "Set `agent-epoch-projects-root' to your Epoch projects directory")))))

(defun agent-slack--epoch-project-path (path)
  "Return PATH expanded relative to `agent-epoch-projects-root'."
  (when path
    (when (and (not (file-name-absolute-p path))
               (null agent-epoch-projects-root))
      (user-error
       "Set `agent-epoch-projects-root' to your Epoch projects directory"))
    (expand-file-name path agent-epoch-projects-root)))

(defun agent-slack--json-list (value)
  "Return VALUE when it is a list, otherwise nil."
  (and (listp value) value))

;;;; Provide

(provide 'agent-slack)
;;; agent-slack.el ends here
