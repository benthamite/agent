;;; agent-account.el --- Unified account handling for agent backends -*- lexical-binding: t -*-

;; Copyright (C) 2026

;; Author: Pablo Stafforini
;; URL: https://github.com/benthamite/agent
;; Version: 0.1
;; Package-Requires: ((emacs "29.1") (transient "0.9"))

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

;; Single home for multi-account state shared by all agent backends.
;; Account identity lives in exactly two places: the persisted current
;; account (file-backed, cached in `agent-account--current') and the
;; per-session account recorded in the `agent-session' struct.  The
;; only dynamic variable is `agent-account--starting', let-bound by
;; `agent-start-session' around the backend start call so that
;; process-environment hooks see the session's account at spawn time.
;;
;; `agent-account-env' is pure: filesystem syncing of per-account
;; config homes happens only in `agent-account-sync', called from
;; account selection, account initialization, and the defensive sync
;; in `agent-start-session' -- never from process-environment hooks.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'transient)

(defvar agent-backends)
(declare-function agent-backend "agent" (name))
(declare-function agent-backend-account-env-var "agent" (struct))
(declare-function agent-backend-account-file "agent" (struct))
(declare-function agent-backend-account-init "agent" (struct))
(declare-function agent-backend-accounts "agent" (struct))
(declare-function agent-backend-canonical-home "agent" (struct))
(declare-function agent-backend-shared-config-items "agent" (struct))

;;;; Variables

(defvar agent-account--starting nil
  "Backend and account of the session currently being started.
A cons of (BACKEND . ACCOUNT) let-bound by `agent-start-session'
around the backend start call.  Process-environment hooks that run
during process spawn consult this before the persisted current
account, so the spawned process gets the session's account even
when it differs from the global selection.  This is the only
account-related dynamic variable in the package.")

(defvar agent-account--current (make-hash-table :test #'eq)
  "Cache of the current account per backend symbol.
Values are account name strings, or the symbol `none' when the
backend's account file held no valid selection.  Backed by each
backend's account file; see `agent-account-current' and
`agent-account-set'.")

;;;; Commands

;;;###autoload
(defun agent-account-select (backend)
  "Interactively switch BACKEND's current account.
Prompts for an account, persists the selection, and syncs the
account's config home.  New sessions will use this account.
Returns the account name, or nil when the prompt was quit."
  (interactive (list (agent-account--read-backend)))
  (unless (agent-account-list backend)
    (user-error "No accounts configured for backend `%s'" backend))
  (when-let* ((account (agent-account--prompt backend)))
    (agent-account-set backend account)
    (agent-account-sync backend account)
    (message "Switched %s to account: %s" backend account)
    account))

;;;###autoload
(defun agent-account-init (backend account)
  "Create or repair ACCOUNT's config home for BACKEND.
Creates the home directory, installs the shared symlinks, and runs
the backend's optional account-init step.  Safe to call on an
already-initialized account.  Does not change the persisted
current account."
  (interactive
   (let ((backend (agent-account--read-backend)))
     (list backend
           (completing-read "Initialize account: "
                            (mapcar #'car (agent-account-list backend))
                            nil t))))
  (unless (agent-account-home backend account)
    (user-error "Account %S is not configured for backend `%s'"
                account backend))
  (agent-account-sync backend account)
  (message "Initialized %s account: %s" backend account))

(defun agent-account--read-backend ()
  "Prompt for a registered backend that has accounts configured."
  (let ((candidates (cl-remove-if-not #'agent-account-list
                                      (mapcar #'car agent-backends))))
    (pcase candidates
      ('nil (user-error "No backend has accounts configured"))
      (`(,only) only)
      (_ (intern (completing-read "Backend: "
                                  (mapcar #'symbol-name candidates)
                                  nil t))))))

;;;; Resolution

(defun agent-account-resolve (backend &optional prompt-p)
  "Return the account to use for BACKEND, or nil.
Resolution order: the in-flight `agent-account--starting' binding
when it belongs to BACKEND, then the persisted current account,
then -- only when PROMPT-P is non-nil -- an interactive prompt
whose choice is persisted.  Returns nil when BACKEND has no
accounts configured."
  (when (agent-account-list backend)
    (or (and (eq (car-safe agent-account--starting) backend)
             (cdr agent-account--starting))
        (agent-account-current backend)
        (when prompt-p
          (when-let* ((account (agent-account--prompt backend)))
            (agent-account-set backend account))))))

(defun agent-account-current (backend)
  "Return the account used for new BACKEND sessions, or nil.
Loads the persisted selection from the backend's account file on
first use and caches it; `agent-account-set' updates both."
  (let ((cached (gethash backend agent-account--current 'unset)))
    (when (eq cached 'unset)
      (setq cached (or (agent-account--load backend) 'none))
      (puthash backend cached agent-account--current))
    (unless (eq cached 'none)
      cached)))

(defun agent-account-set (backend account)
  "Persist ACCOUNT as the current account for BACKEND.
Updates the in-memory cache and the backend's account file.
Returns ACCOUNT."
  (puthash backend account agent-account--current)
  (agent-account--save backend account)
  account)

(defun agent-account--prompt (backend)
  "Prompt for one of BACKEND's accounts and return its name, or nil.
Returns the single account without prompting when only one exists."
  (when-let* ((names (mapcar #'car (agent-account-list backend))))
    (if (= (length names) 1)
        (car names)
      (completing-read (format "%s account: " backend) names nil t))))

(defun agent-account--load (backend)
  "Read BACKEND's persisted account name from its account file.
Return nil when the file is missing or names an account that is
not configured."
  (when-let* ((file (agent-account--file backend)))
    (when (file-exists-p file)
      (let ((name (string-trim
                   (with-temp-buffer
                     (insert-file-contents file)
                     (buffer-string)))))
        (when (alist-get name (agent-account-list backend) nil nil #'string=)
          name)))))

(defun agent-account--save (backend account)
  "Write ACCOUNT to BACKEND's account file."
  (when-let* ((file (agent-account--file backend)))
    (with-temp-file file
      (insert account "\n"))))

(defun agent-account--file (backend)
  "Return BACKEND's account persistence file, or nil."
  (agent-account--backend-value backend #'agent-backend-account-file))

;;;; Environment

(defun agent-account-env (backend account)
  "Return process environment entries for BACKEND running as ACCOUNT.
The result is a list of \"VAR=VALUE\" strings, or nil when ACCOUNT
has no configured home.  This function is pure: it never touches
the filesystem.  Config-home syncing happens in
`agent-account-sync', which runs from selection, initialization,
and `agent-start-session' -- never from process-environment hooks."
  (when-let* ((struct (agent-backend backend))
              (var (agent-backend-account-env-var struct))
              (home (agent-account-home backend account)))
    (list (format "%s=%s" var home))))

(defun agent-account-home (backend account)
  "Return the expanded config home directory for BACKEND's ACCOUNT.
Return nil when ACCOUNT is nil or not configured."
  (when-let* ((dir (alist-get account (agent-account-list backend)
                              nil nil #'string=)))
    (expand-file-name dir)))

(defun agent-account-list (backend)
  "Return the accounts alist for BACKEND.
Each entry is (NAME . HOME-DIRECTORY).  The backend's accounts
slot may hold an alist, a function returning one, or a symbol
naming a variable holding one."
  (agent-account--backend-value backend #'agent-backend-accounts))

(defun agent-account--backend-value (backend accessor)
  "Return BACKEND's slot read by ACCESSOR, resolving indirections.
ACCESSOR is an `agent-backend' struct accessor function.  Bound
symbols are dereferenced and functions are called, so backend
registrations can point at live defcustoms.  Return nil when
BACKEND is not registered."
  (let ((value (when-let* ((struct (agent-backend backend)))
                 (funcall accessor struct))))
    (cond
     ((and value (symbolp value) (boundp value)) (symbol-value value))
     ((functionp value) (funcall value))
     (t value))))

;;;; Config-home sync

(defun agent-account-sync (backend account)
  "Sync shared state into BACKEND ACCOUNT's config home.
Creates the home directory, ensures each item in the backend's
shared-config-items slot is a symlink to the canonical home, and
runs the backend's optional account-init function.  Errors are
demoted to messages so session startup never aborts on a sync
failure."
  (when-let* ((home (agent-account-home backend account)))
    (make-directory home t)
    (condition-case err
        (progn
          (agent-account--ensure-shared-symlinks backend home)
          (when-let* ((struct (agent-backend backend))
                      (fn (agent-backend-account-init struct)))
            (funcall fn account)))
      (error
       (message "agent-account: failed to sync %s account %s: %S"
                backend account err)))))

(defun agent-account--ensure-shared-symlinks (backend home)
  "Ensure shared config symlinks exist in BACKEND's account HOME."
  (when-let* ((canonical (agent-account--canonical-home backend)))
    (dolist (item (agent-account--backend-value
                   backend #'agent-backend-shared-config-items))
      (agent-account--ensure-shared-symlink
       (expand-file-name item canonical)
       (expand-file-name item home)))))

(defun agent-account--canonical-home (backend)
  "Return BACKEND's canonical config home directory, or nil."
  (when-let* ((dir (agent-account--backend-value
                    backend #'agent-backend-canonical-home)))
    (expand-file-name dir)))

(defun agent-account--ensure-shared-symlink (source target)
  "Ensure TARGET is a symlink pointing at SOURCE.
Create the symlink when TARGET is missing.  Back up and re-point
TARGET when it is a symlink to somewhere else.  Replace TARGET
when it is a virgin-state file or empty directory.  Back TARGET up
to a timestamped sibling before linking when it has real content."
  (when (file-exists-p source)
    (cond
     ((file-symlink-p target)
      (unless (equal (file-truename target) (file-truename source))
        (agent-account--backup-item target)
        (make-symbolic-link source target)
        (message "agent-account: replaced %s with symlink to %s"
                 target source)))
     ((not (file-exists-p target))
      (make-symbolic-link source target)
      (message "agent-account: symlinked %s -> %s" target source))
     ((agent-account--item-virgin-p target)
      (agent-account--delete-item target)
      (make-symbolic-link source target)
      (message "agent-account: replaced virgin %s with symlink to %s"
               target source))
     (t
      (agent-account--backup-item target)
      (make-symbolic-link source target)
      (message "agent-account: backed up and symlinked %s -> %s"
               target source)))))

(defun agent-account--item-virgin-p (path)
  "Return non-nil if PATH is a virgin-state file or empty directory.
An empty directory is virgin.  A zero-byte file is virgin.  A small
JSON file containing only `{}' or `[]' is virgin."
  (cond
   ((file-directory-p path)
    (null (directory-files path nil directory-files-no-dot-files-regexp)))
   ((file-regular-p path)
    (agent-account--file-virgin-p path))))

(defun agent-account--file-virgin-p (path)
  "Return non-nil if regular file PATH has empty or placeholder content."
  (let ((size (file-attribute-size (file-attributes path))))
    (or (zerop size)
        (and (< size 16)
             (member (string-trim
                      (with-temp-buffer
                        (insert-file-contents path)
                        (buffer-string)))
                     '("" "{}" "[]"))))))

(defun agent-account--delete-item (path)
  "Delete PATH, whether it is a file or a directory."
  (if (file-directory-p path)
      (delete-directory path t)
    (delete-file path)))

(defun agent-account--backup-item (path)
  "Move PATH to a timestamped backup path."
  (let* ((timestamp (format-time-string "%Y%m%d%H%M%S"))
         (backup (format "%s.agent-backup-%s" path timestamp))
         (candidate backup)
         (counter 0))
    (while (file-exists-p candidate)
      (setq counter (1+ counter)
            candidate (format "%s.%d" backup counter)))
    (rename-file path candidate)
    (message "agent-account: backed up %s to %s" path candidate)))

;;;; Transient infix

(eval-and-compile
  (defclass agent-account-variable (transient-lisp-variable)
    ((backend :initarg :backend)
     (variable :initform nil))
    "An infix that displays and selects a backend's current account.
The `backend' slot names the registered backend symbol."))

(cl-defmethod transient-infix-read ((obj agent-account-variable))
  "Prompt for one of the accounts of OBJ's backend."
  (agent-account--prompt (oref obj backend)))

(cl-defmethod transient-infix-set ((obj agent-account-variable) value)
  "Persist VALUE as the current account of OBJ's backend and sync its home."
  (oset obj value value)
  (when value
    (agent-account-set (oref obj backend) value)
    (agent-account-sync (oref obj backend) value)))

(cl-defmethod transient-init-value ((obj agent-account-variable))
  "Initialize OBJ's value from the persisted current account."
  (oset obj value (agent-account-current (oref obj backend))))

(provide 'agent-account)
;;; agent-account.el ends here
