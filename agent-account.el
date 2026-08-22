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
;; Accounts are declared per backend as (NAME . HOME) or as
;; (NAME :home HOME :pool POOL ...).  Accounts sharing a `:pool' are
;; interchangeable: the persisted selection may name a pool instead of
;; an account, and `agent-account-resolve' then routes each new session
;; to one member via `agent-account-route'.
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
(require 'agent-usage)

(defvar agent-backends)
(declare-function agent-backend "agent" (name))
(declare-function agent-backend-account-env-var "agent" (struct))
(declare-function agent-backend-account-file "agent" (struct))
(declare-function agent-backend-account-init "agent" (struct))
(declare-function agent-backend-accounts "agent" (struct))
(declare-function agent-backend-canonical-home "agent" (struct))
(declare-function agent-backend-credential-file "agent" (struct))
(declare-function agent-backend-login-args "agent" (struct))
(declare-function agent-backend-program "agent" (struct))
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
    (agent-account-sync-selection backend account)
    (message "Switched %s to %s: %s" backend
             (if (agent-account-pool-p backend account) "pool" "account")
             account)
    account))

(defun agent-account-sync-selection (backend selection)
  "Sync the config home of SELECTION for BACKEND.
SELECTION is an account name, whose single home is synced, or a pool
name, in which case every member's home is synced so routing can
pick any of them without a further filesystem step."
  (dolist (account (agent-account--selection-accounts backend selection))
    (agent-account-sync backend account)))

(defun agent-account--selection-accounts (backend selection)
  "Return the account names SELECTION stands for in BACKEND.
A pool name expands to its members; an account name to itself."
  (if (agent-account-pool-p backend selection)
      (agent-account-pool-members backend selection)
    (list selection)))

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

;;;###autoload
(defun agent-account-login (backend &optional account)
  "Run BACKEND's login flow for ACCOUNT in a dedicated buffer.
Spawns the backend's login command with ACCOUNT's environment, so the
credentials land in the account's config home rather than the
backend's default home.  ACCOUNT defaults to a prompted choice among
BACKEND's configured accounts.  The account home is synced first so a
fresh account can log in immediately.  Signal a `user-error' for
backends without a `login-args' slot.  Return the login process."
  (interactive (list (agent-account--read-backend #'agent-account--login-args)))
  (unless (agent-account--login-args backend)
    (user-error "Backend `%s' does not support login from Emacs" backend))
  (let ((account (or account (agent-account--prompt-account backend))))
    (unless account
      (user-error "No account selected"))
    (agent-account-sync backend account)
    (agent-account--login-process backend account)))

(defun agent-account--login-args (backend)
  "Return BACKEND's login command arguments, or nil."
  (agent-account--backend-value backend #'agent-backend-login-args))

(defun agent-account--login-process (backend account)
  "Start BACKEND's login command for ACCOUNT and return the process.
The command runs with ACCOUNT's environment in a visible buffer, so
the user can follow the authentication URL when the browser does not
open automatically."
  (let* ((buffer (get-buffer-create
                  (format "*agent-login: %s/%s*" backend account)))
         (process-environment (append (agent-account-env backend account)
                                      process-environment))
         (command (cons (agent-backend-program (agent-backend backend))
                        (agent-account--login-args backend))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)))
    (display-buffer buffer)
    (make-process
     :name (format "agent-login-%s-%s" backend account)
     :buffer buffer
     :command command
     :sentinel (lambda (process event)
                 (agent-account--login-sentinel process event
                                                backend account)))))

(defun agent-account--login-sentinel (process event backend account)
  "Report the completion of BACKEND ACCOUNT's login PROCESS.
EVENT is the process status change description."
  (when (memq (process-status process) '(exit signal))
    (if (and (eq (process-status process) 'exit)
             (zerop (process-exit-status process)))
        (message "Logged in to %s account: %s" backend account)
      (message "Login for %s account %s failed (%s); see buffer %s"
               backend account (string-trim event)
               (buffer-name (process-buffer process))))))

(defun agent-account--read-backend (&optional predicate)
  "Prompt for a registered backend that has accounts configured.
When PREDICATE is non-nil, restrict candidates to backends for which
it returns non-nil when called with the backend symbol."
  (let ((candidates
         (cl-remove-if-not (lambda (backend)
                             (and (agent-account-list backend)
                                  (or (null predicate)
                                      (funcall predicate backend))))
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
when it belongs to BACKEND, then the persisted current selection,
then -- only when PROMPT-P is non-nil -- an interactive prompt
whose choice is persisted.  A selection naming a pool is routed to
one of its members with `agent-account-route', so the result is
always a concrete account name.  Returns nil when BACKEND has no
accounts configured."
  (when (agent-account-list backend)
    (or (and (eq (car-safe agent-account--starting) backend)
             (cdr agent-account--starting))
        (agent-account--route-selection
         backend
         (or (agent-account-current backend)
             (when prompt-p
               (when-let* ((account (agent-account--prompt backend)))
                 (agent-account-set backend account))))))))

(defun agent-account--route-selection (backend selection)
  "Return the concrete account SELECTION stands for in BACKEND.
A pool name is routed to a member; an account name is returned as is."
  (when selection
    (if (agent-account-pool-p backend selection)
        (agent-account-route backend selection)
      selection)))

(defcustom agent-account-route-hysteresis 10
  "Usage points by which another pool member must beat the current one.
Routing keeps the member it last chose for a pool unless a sibling's
usage score is lower by at least this much, so near-equal members do
not alternate between consecutive sessions."
  :type 'number
  :group 'agent)

(defvar agent-account--routed (make-hash-table :test #'equal)
  "Map from (BACKEND . POOL) to the member most recently routed to.")

(defun agent-account-route (backend pool)
  "Return the member of BACKEND's POOL a new session should use.
Members whose credentials are known missing are skipped.  Among the
rest, members whose latest usage reading is fresh and marks them as
limited -- or as having exhausted either window -- are set aside,
and the remaining members are ranked by `agent-account-usage-score',
unknown usage ranking last.  The member routed to last time is kept
unless another beats it by `agent-account-route-hysteresis'.  When
every member is limited, the one whose weekly window resets soonest
is returned so the session start can still report the limit.
Returns nil for an empty pool.  Also refreshes the pool's usage so
the next routing decision sees current data."
  (when-let* ((members (agent-account-pool-members backend pool)))
    (let* ((available (or (cl-remove-if-not
                           (lambda (account)
                             (agent-account-logged-in-p backend account))
                           members)
                          members))
           (open (cl-remove-if (lambda (account)
                                 (agent-account--limited-p backend account))
                               available))
           (choice (if open
                       (agent-account--route-among backend pool open)
                     (agent-account--soonest-reset backend available))))
      (puthash (cons backend pool) choice agent-account--routed)
      (agent-account--announce-route backend pool choice (null open))
      (agent-usage-refresh-pool backend pool)
      choice)))

(defun agent-account--route-among (backend pool open)
  "Return the member of OPEN to route BACKEND's POOL to.
OPEN is the list of members not currently limited."
  (let* ((ranked (agent-account--rank-by-usage backend open))
         (best (car ranked))
         (current (gethash (cons backend pool) agent-account--routed)))
    (if (and current
             (member current open)
             (agent-account--within-hysteresis-p
              (agent-account-usage-score backend current)
              (agent-account-usage-score backend best)))
        current
      best)))

(defun agent-account--within-hysteresis-p (current-score best-score)
  "Return non-nil when CURRENT-SCORE is close enough to BEST-SCORE to keep.
A current member without a score is kept only when the best has none
either, since unknown usage should not hold off a known-good member."
  (cond
   ((null best-score) t)
   ((null current-score) nil)
   (t (< (- current-score best-score) agent-account-route-hysteresis))))

(defun agent-account--rank-by-usage (backend accounts)
  "Return ACCOUNTS of BACKEND sorted by ascending usage score.
Accounts without a score come last, in their original order."
  (let ((scored (mapcar (lambda (account)
                          (cons account (agent-account-usage-score backend account)))
                        accounts)))
    (mapcar #'car
            (sort scored
                  (lambda (a b)
                    (cond
                     ((and (cdr a) (cdr b)) (< (cdr a) (cdr b)))
                     ((cdr a) t)
                     (t nil)))))))

(defun agent-account-usage-score (backend account)
  "Return a usage score for BACKEND's ACCOUNT, or nil when unknown.
The score is the larger of the weekly and session percentages from
the latest fresh reading, with the weekly percentage breaking ties by
contributing a small fraction, so a member with the same peak but a
fuller week ranks later.  Lower is better."
  (when-let* ((usage (agent-usage-get backend account))
              ((agent-usage-fresh-p usage)))
    (let ((weekly (plist-get usage :weekly-pct))
          (session (plist-get usage :session-pct)))
      (when (or weekly session)
        (+ (max (or weekly 0) (or session 0))
           (* 0.01 (or weekly 0)))))))

(defun agent-account--limited-p (backend account)
  "Return non-nil when a fresh reading says ACCOUNT of BACKEND is limited.
An account is limited when the backend flags it so or either window
is at or above 100 percent.  Stale or missing readings never count
as limited, so an account the poller has not reached stays usable."
  (when-let* ((usage (agent-usage-get backend account))
              ((agent-usage-fresh-p usage)))
    (or (plist-get usage :limited)
        (>= (or (plist-get usage :weekly-pct) 0) 100)
        (>= (or (plist-get usage :session-pct) 0) 100))))

(defun agent-account--soonest-reset (backend accounts)
  "Return the member of ACCOUNTS of BACKEND whose limit lifts soonest.
The soonest of the weekly and session resets counts; an account with
no known reset sorts last."
  (car (sort (copy-sequence accounts)
             (lambda (a b)
               (let ((ra (agent-account--next-reset backend a))
                     (rb (agent-account--next-reset backend b)))
                 (cond
                  ((and ra rb) (< ra rb))
                  (ra t)
                  (t nil)))))))

(defun agent-account--next-reset (backend account)
  "Return the earliest known window reset time for BACKEND's ACCOUNT."
  (when-let* ((usage (agent-usage-get backend account)))
    (let ((resets (delq nil (list (plist-get usage :weekly-reset)
                                  (plist-get usage :session-reset)))))
      (when resets
        (apply #'min resets)))))

(defun agent-account--announce-route (backend pool account all-limited)
  "Report that BACKEND's POOL was routed to ACCOUNT.
ALL-LIMITED non-nil means every member was limited and ACCOUNT is
merely the one whose limit lifts soonest."
  (let ((usage (agent-usage-get backend account)))
    (message "%s pool %s -> %s%s%s" backend pool account
             (if usage
                 (format " (weekly %s%%, session %s%%)"
                         (agent-account--pct (plist-get usage :weekly-pct))
                         (agent-account--pct (plist-get usage :session-pct)))
               " (usage unknown)")
             (if all-limited "; every member is at its limit" ""))))

(defun agent-account--pct (value)
  "Return VALUE formatted as a whole-number percentage, or a dash."
  (if (numberp value) (format "%.0f" value) "-"))

(defun agent-account-current (backend)
  "Return the persisted selection for new BACKEND sessions, or nil.
The selection is an account name or a pool name; callers that need
a concrete account use `agent-account-resolve'.  Loads the
selection from the backend's account file on first use and caches
it; `agent-account-set' updates both."
  (let ((cached (gethash backend agent-account--current 'unset)))
    (when (eq cached 'unset)
      (setq cached (or (agent-account--load backend) 'none))
      (puthash backend cached agent-account--current))
    (unless (eq cached 'none)
      cached)))

(defun agent-account-set (backend account)
  "Persist ACCOUNT as the current selection for BACKEND.
ACCOUNT is an account name or a pool name.  Updates the in-memory
cache and the backend's account file.  Returns ACCOUNT."
  (puthash backend account agent-account--current)
  (agent-account--save backend account)
  account)

(defun agent-account--prompt (backend)
  "Prompt for one of BACKEND's accounts or pools and return its name.
Pools are listed before the accounts and annotated with their
members.  Returns the single account without prompting when only
one exists, and nil when the prompt is quit."
  (when-let* ((names (agent-account-selection-names backend)))
    (if (= (length names) 1)
        (car names)
      (completing-read (format "%s account: " backend)
                       (agent-account--selection-table backend names)
                       nil t))))

(defun agent-account--prompt-account (backend)
  "Prompt for one of BACKEND's accounts, never a pool, and return it.
Returns the single account without prompting when only one exists."
  (when-let* ((names (mapcar #'car (agent-account-list backend))))
    (if (= (length names) 1)
        (car names)
      (completing-read (format "%s account: " backend) names nil t))))

(defun agent-account-selection-names (backend)
  "Return BACKEND's selectable names: its pools, then its accounts."
  (append (agent-account-pools backend)
          (mapcar #'car (agent-account-list backend))))

(defun agent-account--selection-table (backend names)
  "Return a completion table over NAMES annotating BACKEND's pools."
  (lambda (string pred action)
    (if (eq action 'metadata)
        `(metadata
          (annotation-function
           . ,(lambda (name) (agent-account--selection-annotation backend name)))
          (display-sort-function . identity)
          (cycle-sort-function . identity))
      (complete-with-action action names string pred))))

(defun agent-account--selection-annotation (backend name)
  "Return the completion annotation for NAME in BACKEND."
  (if (agent-account-pool-p backend name)
      (format "  pool: %s"
              (string-join (agent-account-pool-members backend name) ", "))
    (when-let* ((pool (agent-account-pool backend name)))
      (format "  in pool %s" pool))))

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
        (when (member name (agent-account-selection-names backend))
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
  (when-let* ((dir (agent-account-property backend account :home)))
    (expand-file-name dir)))

(defun agent-account-property (backend account key)
  "Return property KEY of BACKEND's ACCOUNT, or nil.
KEY is a keyword.  An entry of the form (NAME . HOME) has only a
`:home' property; an entry of the form (NAME :home HOME ...) has
every property in its plist."
  (when-let* ((entry (agent-account-entry backend account)))
    (let ((spec (cdr entry)))
      (if (stringp spec)
          (and (eq key :home) spec)
        (plist-get spec key)))))

(defun agent-account-entry (backend account)
  "Return the accounts-list entry named ACCOUNT for BACKEND, or nil."
  (when (stringp account)
    (assoc account (agent-account-list backend))))

(defun agent-account-pool (backend account)
  "Return the name of the pool BACKEND's ACCOUNT belongs to, or nil."
  (agent-account-property backend account :pool))

(defun agent-account-pools (backend)
  "Return the distinct pool names declared by BACKEND's accounts."
  (let (pools)
    (dolist (entry (agent-account-list backend) (nreverse pools))
      (when-let* ((pool (agent-account-pool backend (car entry))))
        (cl-pushnew pool pools :test #'string=)))))

(defun agent-account-pool-p (backend name)
  "Return non-nil when NAME is a pool declared by BACKEND's accounts."
  (and (stringp name)
       (member name (agent-account-pools backend))
       t))

(defun agent-account-pool-members (backend pool)
  "Return the names of BACKEND's accounts belonging to POOL, in order."
  (cl-loop for entry in (agent-account-list backend)
           when (equal (agent-account-pool backend (car entry)) pool)
           collect (car entry)))

(defun agent-account-logged-in-p (backend account)
  "Return non-nil unless ACCOUNT's BACKEND credentials are known missing.
Checks that the backend's declared credential file exists inside
ACCOUNT's config home.  Backends that declare no credential file are
assumed logged in, since their credential storage cannot be
inspected."
  (let ((file (agent-account-credential-file backend account)))
    (or (null file) (file-exists-p file))))

(defun agent-account-credential-file (backend account)
  "Return the credential file path for BACKEND's ACCOUNT, or nil.
Nil when BACKEND declares no credential file or ACCOUNT has no
configured home."
  (when-let* ((name (agent-account--backend-value
                     backend #'agent-backend-credential-file))
              (home (agent-account-home backend account)))
    (expand-file-name name home)))

(defun agent-account-list (backend)
  "Return the accounts alist for BACKEND.
Each entry is (NAME . HOME-DIRECTORY) or (NAME :home HOME-DIRECTORY
:pool POOL ...); see `agent-account-property'.  The backend's
accounts slot may hold an alist, a function returning one, or a
symbol naming a variable holding one."
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
runs the backend's optional account-init function.  Signal any
sync error so session startup cannot continue with missing or stale
configuration."
  (when-let* ((home (agent-account-home backend account)))
    (make-directory home t)
    (agent-account--ensure-shared-symlinks backend home)
    (when-let* ((struct (agent-backend backend))
                (fn (agent-backend-account-init struct)))
      (funcall fn account))))

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
    (agent-account-sync-selection (oref obj backend) value)))

(cl-defmethod transient-init-value ((obj agent-account-variable))
  "Initialize OBJ's value from the persisted current account."
  (oset obj value (agent-account-current (oref obj backend))))

(provide 'agent-account)
;;; agent-account.el ends here
