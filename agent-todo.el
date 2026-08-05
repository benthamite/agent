;;; agent-todo.el --- Org TODO workflows for AI sessions -*- lexical-binding: t -*-

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

;; Send org TODO entries to a running AI session, or process a whole
;; list of them non-interactively through the backend's `exec-prompt'
;; slot.  Both work with any registered backend.

;;; Code:

(require 'cl-lib)
(require 'org)
(require 'project)
(require 'agent)

;;;; Customization

(defgroup agent-todo nil
  "Org TODO workflows for AI sessions."
  :group 'agent)

(defcustom agent-todo-log-directory
  (expand-file-name "agent/claude-logs/" user-emacs-directory)
  "Directory where batch TODO run logs are saved."
  :type 'directory
  :group 'agent-todo)

(defcustom agent-todo-in-progress-keyword nil
  "Org TODO keyword to set when sending a heading to an AI session.
When non-nil, `agent-send-todo-at-point' changes the heading's TODO
state to this keyword after sending.  The keyword must be one of the
values in `org-todo-keywords' for the current buffer.  When nil, the
TODO state is not changed.

Org's built-in keywords are just TODO and DONE, with no intermediate
state, so this is disabled by default.  Users who have configured an
in-progress keyword (e.g. DOING, IN-PROGRESS, STARTED) can set this
option to that keyword."
  :type '(choice (const :tag "Don't change TODO state" nil)
                 (string :tag "Keyword"))
  :group 'agent-todo)

;;;; Functions

;;;;; Entry collection

;; Batch state is passed as a plist through closures to support
;; parallel runs.  Keys: :backend :queue :results :log-dir :working-dir
;; :start-time

(defun agent-todo--collect-todos (scope)
  "Collect TODO entries from the current org buffer according to SCOPE.
SCOPE is one of `buffer', `subtree', or `region'.
Returns a list of plists with :title and :body keys."
  (let ((entries '()))
    (org-map-entries
     (lambda ()
       (when (and (org-get-todo-state)
                  (not (org-entry-is-done-p)))
         (let* ((title (org-get-heading t t t t))
                (body-start (save-excursion
                              (org-end-of-meta-data t)
                              (point)))
                (body-end (save-excursion
                            (outline-next-heading)
                            (or (point) (point-max))))
                (body (string-trim
                       (buffer-substring-no-properties body-start body-end))))
           (push (list :title title :body body) entries))))
     nil
     (pcase scope
       ('buffer nil)
       ('subtree 'tree)
       ('region 'region)))
    (nreverse entries)))

(defun agent-todo--format-prompt (entry)
  "Format ENTRY plist as a prompt string for a non-interactive run.
Combines :title and :body, using title alone when body is empty."
  (let ((title (plist-get entry :title))
        (body (plist-get entry :body)))
    (if (or (null body) (string-empty-p body))
        title
      (concat title "\n\n" body))))

(defun agent-todo--org-to-markdown (text)
  "Convert org inline markup in TEXT to Markdown equivalents.
Handles verbatim (=…=) and code (~…~) to backticks."
  (replace-regexp-in-string "[=~]\\([^=~\n]+\\)[=~]" "`\\1`" text))

(defun agent-todo--collect-at-point ()
  "Return a plist with :title and :body for the TODO at point."
  (save-excursion
    (org-back-to-heading t)
    (let* ((title (agent-todo--org-to-markdown
                   (org-get-heading t t t t)))
           (body-start (progn (org-end-of-meta-data t) (point)))
           (body-end (progn (outline-next-heading)
                            (or (point) (point-max))))
           (body (string-trim
                  (buffer-substring-no-properties body-start body-end))))
      (list :title title :body body))))

;;;;; Batch processing

(defun agent-todo--ensure-clean-worktree (dir)
  "Signal a user error unless DIR is a clean git worktree."
  (let ((default-directory dir))
    (with-temp-buffer
      (let ((exit (call-process "git" nil t nil
                                "status" "--porcelain")))
        (cond
         ((not (zerop exit))
          (user-error "Cannot inspect git worktree in %s: %s"
                      dir (string-trim (buffer-string))))
         ((> (buffer-size) 0)
          (user-error
           "Refusing audit auto-commit because %s has uncommitted changes"
           dir)))))))

(defun agent-todo--batch-start (backend entries dir &optional commit-after-each)
  "Start batch processing of ENTRIES through BACKEND in working directory DIR.
When COMMIT-AFTER-EACH is non-nil, automatically commit any uncommitted
changes in DIR after each entry completes successfully."
  (when commit-after-each
    (agent-todo--ensure-clean-worktree dir))
  (let* ((log-dir (expand-file-name
                   (format-time-string "batch_%Y-%m-%d_%H-%M-%S")
                   agent-todo-log-directory))
         (state (list :backend backend
                      :queue entries
                      :results nil
                      :log-dir log-dir
                      :working-dir dir
                      :start-time (current-time)
                      :commit-after-each commit-after-each)))
    (make-directory log-dir t)
    (message "Batch processing %d TODO(s)..." (length entries))
    (agent-todo--batch-run-next state)))

(defun agent-todo--batch-run-next (state)
  "Process the next entry in the batch queue in STATE.
STATE is a plist with keys :backend :queue :results :log-dir
:working-dir :start-time.  When the queue is empty, display the
summary buffer."
  (if (null (plist-get state :queue))
      (agent-todo--batch-finish state)
    (let* ((queue (plist-get state :queue))
           (entry (car queue))
           (index (1+ (length (plist-get state :results))))
           (title (plist-get entry :title))
           (prompt (agent-todo--format-prompt entry))
           (log-file (expand-file-name
                      (format "%02d_%s.json"
                              index
                              (replace-regexp-in-string
                               "[^a-zA-Z0-9_-]" "-"
                               (truncate-string-to-width title 50)))
                      (plist-get state :log-dir))))
      (plist-put state :queue (cdr queue))
      (message "Batch [%d/%d]: %s"
               index
               (+ index (length (plist-get state :queue)))
               title)
      (let ((exec (or (when-let* ((struct (agent-backend
                                           (plist-get state :backend))))
                        (agent-backend-exec-prompt struct))
                      (user-error
                       "Backend `%s' does not support non-interactive runs"
                       (plist-get state :backend)))))
        (funcall exec
                 prompt
                 :dir (plist-get state :working-dir)
                 :callback
                 (lambda (result)
                   (when-let* ((raw (plist-get result :raw)))
                     (with-temp-file log-file
                       (insert raw)))
                   (plist-put state :results
                              (cons (list :title title
                                          :index index
                                          :exit-code (plist-get result :exit-code)
                                          :duration (plist-get result :duration)
                                          :cost (plist-get result :cost)
                                          :result-text (or (plist-get result :text)
                                                           "(failed to parse output)")
                                          :log-file log-file)
                                    (plist-get state :results)))
                   (when (and (zerop (plist-get result :exit-code))
                              (plist-get state :commit-after-each))
                     (ignore-errors
                       (agent-todo--batch-commit-changes state title)))
                   (agent-todo--batch-run-next state)))))))

(defun agent-todo--batch-commit-changes (state title)
  "Commit uncommitted work in the working directory of STATE.
TITLE is the entry title, used to derive the commit message scope."
  (let ((default-directory (plist-get state :working-dir)))
    (with-temp-buffer
      (call-process "git" nil t nil "status" "--porcelain")
      (when (> (buffer-size) 0)
        (call-process "git" nil nil nil "add" "-A")
        (let ((scope (replace-regexp-in-string
                      "^/" ""
                      (car (split-string title " ")))))
          (call-process "git" nil nil nil "commit" "-m"
                        (format "%s: apply audit recommendations" scope)))))))

(defun agent-todo--batch-finish (state)
  "Display the batch processing summary buffer for STATE."
  (let* ((results (sort (plist-get state :results)
                        (lambda (a b)
                          (< (plist-get a :index) (plist-get b :index)))))
         (total (length results))
         (successes (cl-count 0 results :key (lambda (r) (plist-get r :exit-code))))
         (failures (- total successes))
         (total-cost (agent-todo--total-cost results))
         (start-time (plist-get state :start-time))
         (total-time (float-time
                      (time-subtract (current-time) start-time)))
         (buf (get-buffer-create "*Agent Batch Results*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "#+title: Batch results — %s\n\n"
                        (format-time-string "%Y-%m-%d %H:%M:%S" start-time)))
        (insert (format "- Total: %d | Success: %d | Failed: %d\n" total successes failures))
        (insert (format "- Cost: $%.4f\n" total-cost))
        (insert (format "- Time: %.1f seconds\n" total-time))
        (insert (format "- Logs: [[file:%s]]\n\n" (plist-get state :log-dir)))
        (dolist (result results)
          (let ((status (if (= 0 (plist-get result :exit-code)) "DONE" "FAIL")))
            (insert (format "* %s %s\n" status (plist-get result :title)))
            (insert (format ":PROPERTIES:\n:COST: %s\n:DURATION: %.1fs\n:END:\n\n"
                            (if-let* ((cost (plist-get result :cost)))
                                (format "$%.4f" cost)
                              "—")
                            (plist-get result :duration)))
            (insert (format "Log: [[file:%s]]\n\n" (plist-get result :log-file)))
            (insert "#+begin_example\n")
            (insert (or (plist-get result :result-text) "(no output)"))
            (unless (string-suffix-p "\n" (or (plist-get result :result-text) ""))
              (insert "\n"))
            (insert "#+end_example\n\n"))))
      (org-mode)
      (goto-char (point-min)))
    (pop-to-buffer buf)
    (message "Batch complete: %d/%d succeeded (%.1fs, $%.4f)"
             successes total total-time total-cost)))

(defun agent-todo--total-cost (results)
  "Return the summed `:cost' of RESULTS, counting a missing cost as zero."
  (cl-reduce #'+ results
             :key (lambda (result) (or (plist-get result :cost) 0))
             :initial-value 0))

;;;;; Commands

;;;###autoload
(defun agent-batch-todos ()
  "Process org TODO entries sequentially through an AI backend.
Infer scope automatically: region if active, subtree if the buffer is
narrowed, buffer otherwise.  Resolve the backend the way the rest of
`agent' does — the current session's when called from a session
buffer, prompted for otherwise — then prompt for a working directory
and run each TODO as a non-interactive session.  Results are logged to
timestamped files and displayed in a summary buffer when all entries
have been processed."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Must be called from an org-mode buffer"))
  (let* ((scope (cond
                 ((use-region-p) 'region)
                 ((buffer-narrowed-p) 'subtree)
                 (t 'buffer)))
         (entries (agent-todo--collect-todos scope))
         (backend (agent--resolve-backend)))
    (when (null entries)
      (user-error "No TODO entries found in %s" scope))
    (let ((dir (project-prompt-project-dir)))
      (when (or (eq scope 'region)
                (yes-or-no-p
                 (format "Process %d TODO(s) in %s?" (length entries) dir)))
        (agent-todo--batch-start backend entries dir)))))

;;;###autoload
(defun agent-send-todo-at-point ()
  "Send the org TODO at point to a running AI session.
Extract the heading and body of the TODO entry at point, format them
as a prompt, and send them to the session associated with the current
file's project.  When no unique session can be inferred, prompt for
one.

When `agent-todo-in-progress-keyword' is non-nil, the heading's TODO
state is changed to that keyword after sending."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Must be called from an org-mode buffer"))
  (unless (org-get-todo-state)
    (user-error "Point is not on a TODO heading"))
  (let* ((entry (agent-todo--collect-at-point))
         (prompt (agent-todo--format-prompt entry))
         (buf (agent--session-buffer-for-project)))
    (agent-submit prompt buf)
    (when agent-todo-in-progress-keyword
      (org-todo agent-todo-in-progress-keyword))
    (display-buffer buf)))

(provide 'agent-todo)
;;; agent-todo.el ends here
