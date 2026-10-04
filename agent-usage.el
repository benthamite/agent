;;; agent-usage.el --- Account usage tracking for agent backends -*- lexical-binding: t -*-

;; Copyright (C) 2026

;; Author: Pablo Stafforini
;; URL: https://github.com/benthamite/agent
;; Version: 0.1
;; Package-Requires: ((emacs "29.1"))

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

;; Backend-agnostic store and poller for per-account usage.  Each
;; backend that can report usage declares a `:usage-fetch' slot: a
;; function called with an account name and a callback, which it
;; invokes with a normalized usage plist, or with a failure built by
;; `agent-usage-failure' that says why no reading came back.  The
;; usage plist holds
;; `:session-pct' and `:weekly-pct' (percent of the short and long
;; windows used), `:session-reset' and `:weekly-reset' (window reset
;; times as float seconds), `:limited' (non-nil when the backend
;; refuses further requests), and `:fetched-at'.
;;
;; One timer polls every account that has a live session plus every
;; member of every pool, so routing has data for idle members too.
;; Results are cached on disk so a fresh Emacs can route immediately.
;;
;; A failed fetch leaves the last reading in place and adds `:error'
;; (the reason) and `:error-at' to it.  A network failure, such as a
;; dropped connection while the machine sleeps, says nothing about the
;; account, so it is marked `:network' and retried at the next poll.
;; Any other failure sets `:retry-at': the server's `Retry-After' when
;; it sent one, marked `:retry-required', else a per-account backoff.
;; The account is not polled again before `:retry-at'; a manual refresh
;; overrides the backoff but not a wait the server asked for.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'iso8601)
(require 'tabulated-list)

(defvar agent-backends)
(defvar url-http-end-of-headers)
(defvar url-http-response-status)
(declare-function agent-backend "agent" (name))
(declare-function agent-backend-find-all-buffers "agent" (struct))
(declare-function agent-backend-usage-fetch "agent" (struct))
(declare-function agent-session "agent" (&optional buffer))
(declare-function agent-session-account "agent" (session))
(declare-function agent-account-list "agent-account" (backend))
(declare-function agent-account-pool "agent-account" (backend account))
(declare-function agent-account-pools "agent-account" (backend))
(declare-function agent-account-pool-members "agent-account" (backend pool))

;;;; Options

(defgroup agent-usage ()
  "Account usage tracking for agent backends."
  :group 'agent)

(defcustom agent-usage-interval 300
  "Interval in seconds between usage polls."
  :type 'integer
  :group 'agent-usage)

(defcustom agent-usage-max-interval 900
  "Longest wait in seconds before refetching an account that keeps failing.
Each consecutive failure doubles the account's wait, starting from
`agent-usage-interval'.  A wait the server asks for with
`Retry-After' is honoured in full, even when longer."
  :type 'integer
  :group 'agent-usage)

(defcustom agent-usage-cache-file
  (locate-user-emacs-file "agent-usage-cache.eld")
  "File caching the last usage reading of every polled account.
Read on first use so that routing has data before the first poll of
a fresh Emacs completes."
  :type 'file
  :group 'agent-usage)

(defcustom agent-usage-stale-after 3600
  "Seconds after which a cached usage reading no longer counts for routing."
  :type 'integer
  :group 'agent-usage)

;;;; State

(defvar agent-usage--data nil
  "Hash table from (BACKEND . ACCOUNT) to a normalized usage plist.
Nil until `agent-usage--table' loads the cache.")

(defvar agent-usage--timer nil
  "Timer for periodic usage polling.")

(defconst agent-usage--retry-slack 30
  "Seconds before an account's `:retry-at' at which it may be fetched again.
A repeating timer can fire slightly before the retry time computed
from the previous poll; without slack such a poll would skip the
account and double its wait.")

;;;; Store

(defun agent-usage--table ()
  "Return the usage table, loading the on-disk cache on first use."
  (or agent-usage--data
      (setq agent-usage--data (agent-usage--load-cache))))

(defun agent-usage--load-cache ()
  "Return a usage table read from `agent-usage-cache-file'."
  (let ((table (make-hash-table :test #'equal)))
    (when (file-readable-p agent-usage-cache-file)
      (condition-case nil
          (dolist (entry (with-temp-buffer
                           (insert-file-contents agent-usage-cache-file)
                           (read (current-buffer))))
            (puthash (car entry) (cdr entry) table))
        (error nil)))
    table))

(defun agent-usage--save-cache ()
  "Write the usage table to `agent-usage-cache-file'."
  (let (entries)
    (maphash (lambda (key value) (push (cons key value) entries))
             (agent-usage--table))
    (with-temp-file agent-usage-cache-file
      (let ((print-length nil)
            (print-level nil))
        (prin1 entries (current-buffer))))))

(defun agent-usage-get (backend account)
  "Return the last usage plist recorded for BACKEND's ACCOUNT, or nil."
  (gethash (cons backend account) (agent-usage--table)))

(defun agent-usage-record (backend account usage)
  "Store USAGE as the latest reading for BACKEND's ACCOUNT.
USAGE is a normalized plist; `:fetched-at' is filled in when absent.
Persists the table.  Returns the stored plist."
  (let ((stored (if (plist-member usage :fetched-at)
                    usage
                  (plist-put (copy-sequence usage) :fetched-at (float-time)))))
    (puthash (cons backend account) stored (agent-usage--table))
    (agent-usage--save-cache)
    stored))

(defun agent-usage-fresh-p (usage &optional now)
  "Return non-nil when USAGE was fetched within `agent-usage-stale-after'.
NOW defaults to the current time."
  (when-let* ((at (plist-get usage :fetched-at)))
    (< (- (or now (float-time)) at) agent-usage-stale-after)))

;;;; Fetching

(defun agent-usage-failure (reason &optional retry-after)
  "Return a failed fetch result giving REASON, a short string.
RETRY-AFTER, when non-nil, is the number of seconds the server asked
the client to wait before trying again."
  (list :error reason :retry-after retry-after))

(defun agent-usage-network-failure ()
  "Return the fetch result for a request that got no HTTP response.
Such a failure reflects the connection, not the account, so it is
retried at the next poll without backoff or an echo-area message."
  (list :error "network error" :network t))

(defun agent-usage-fetch (backend account &optional callback force)
  "Fetch usage for BACKEND's ACCOUNT and record the result.
Calls the backend's `:usage-fetch' slot, unless an earlier failure set
a retry time for ACCOUNT that has not come yet.  FORCE non-nil ignores
a retry time set by backoff, but not one the server asked for.
CALLBACK, when non-nil, is called with the recorded plist, or with nil
when the fetch failed or was deferred.  Returns nil without fetching
when BACKEND declares no fetcher."
  (when-let* ((fetch (agent-usage--fetcher backend)))
    (if (agent-usage--deferred-p (agent-usage-get backend account) nil force)
        (when callback
          (funcall callback nil))
      (let ((started (float-time)))
        (funcall fetch account
                 (lambda (result)
                   (let ((stored
                          (if (and result (not (plist-get result :error)))
                              (agent-usage--record-success backend account result)
                            (agent-usage--record-failure
                             backend account result started)
                            nil)))
                     (when callback
                       (funcall callback stored)))))))
    t))

(defun agent-usage--deferred-p (usage &optional now force)
  "Return non-nil when USAGE's account must not be fetched at NOW.
NOW defaults to the current time.  FORCE non-nil ignores a retry time
set by backoff, keeping only one the server asked for."
  (when-let* ((retry-at (plist-get usage :retry-at))
              ((or (not force) (plist-get usage :retry-required))))
    (< (or now (float-time)) (- retry-at agent-usage--retry-slack))))

(defun agent-usage--record-success (backend account usage)
  "Record USAGE for BACKEND's ACCOUNT, announcing recovery from an error.
Returns the stored plist."
  (when-let* ((old-error (plist-get (agent-usage-get backend account) :error)))
    (message "%s usage for %s works again (was: %s)"
             backend (or account "default") old-error))
  (agent-usage-record backend account usage))

(defun agent-usage--record-failure (backend account failure started)
  "Record FAILURE on BACKEND's ACCOUNT, keeping its last reading.
FAILURE is a plist from `agent-usage-failure' or
`agent-usage-network-failure', or nil when the fetcher gave no reason.
STARTED is when the fetch began; the retry time counts from it.  A
failure other than a network one is announced when its reason differs
from the previous one."
  (let ((old (agent-usage-get backend account))
        (reason (or (plist-get failure :error) "fetch failed")))
    (if (plist-get failure :network)
        (agent-usage--put-failure backend account old
                                  :error reason :network t
                                  :backoff nil :retry-at nil
                                  :retry-required nil)
      (let* ((retry-after (plist-get failure :retry-after))
             (backoff (if-let* ((previous (plist-get old :backoff)))
                          (min agent-usage-max-interval (* 2 previous))
                        agent-usage-interval))
             (wait (or retry-after backoff)))
        (unless (equal reason (plist-get old :error))
          (message "%s usage for %s failed: %s; retrying in %s"
                   backend (or account "default") reason
                   (agent-usage--duration wait)))
        (agent-usage--put-failure backend account old
                                  :error reason :network nil
                                  :backoff backoff
                                  :retry-at (+ started wait)
                                  :retry-required (and retry-after t))))))

(defun agent-usage--put-failure (backend account old &rest properties)
  "Store OLD with PROPERTIES and the current `:error-at' for BACKEND's ACCOUNT."
  (let ((entry (copy-sequence old)))
    (setq entry (plist-put entry :error-at (float-time)))
    (while properties
      (setq entry (plist-put entry (pop properties) (pop properties))))
    (puthash (cons backend account) entry (agent-usage--table))
    (agent-usage--save-cache)))

(defun agent-usage--duration (seconds)
  "Return SECONDS as a short human-readable duration."
  (cond
   ((< seconds 60) (format "%ds" seconds))
   ((< seconds 3600) (format "%dm" (/ seconds 60)))
   ((< seconds 86400) (format "%dh" (/ seconds 3600)))
   (t (format "%dd" (/ seconds 86400)))))

;;;;; HTTP responses

(defun agent-usage-response-result (status normalize &optional explain)
  "Return the fetch result for the `url-retrieve' response in this buffer.
STATUS is the plist `url-retrieve' passed to its callback.  On success
return NORMALIZE applied to the JSON body, parsed as a plist with JSON
null and false read as nil.  Otherwise return a failure from
`agent-usage-failure'.  EXPLAIN, when non-nil, is called in the
response buffer with the HTTP status code and may return a reason
string for it; a nil return falls back to the generic reason.  An
error without an HTTP status, or a response without headers, means the
request never got an answer and yields `agent-usage-network-failure'."
  (let ((code (and (boundp 'url-http-response-status)
                   url-http-response-status)))
    (cond
     ((and (plist-get status :error) (numberp code))
      (agent-usage-failure
       (or (and explain (funcall explain code))
           (agent-usage--http-reason code))
       (agent-usage--retry-after)))
     ((or (plist-get status :error)
          (not (and (boundp 'url-http-end-of-headers) url-http-end-of-headers)))
      (agent-usage-network-failure))
     (t
      (goto-char url-http-end-of-headers)
      (condition-case nil
          (funcall normalize (json-parse-buffer :object-type 'plist
                                                :null-object nil
                                                :false-object nil))
        (json-error (agent-usage-failure "unparseable response")))))))

(defun agent-usage--http-reason (code)
  "Return a reason for HTTP status CODE."
  (if (eql code 429) "rate-limited (HTTP 429)" (format "HTTP %d" code)))

(defun agent-usage-http-header (name)
  "Return the value of response header NAME in this buffer, or nil."
  (save-excursion
    (goto-char (point-min))
    (let ((case-fold-search t)
          (end (and (boundp 'url-http-end-of-headers) url-http-end-of-headers)))
      (when (re-search-forward
             (concat "^" (regexp-quote name) ":[ \t]*\\([^\r\n]*\\)")
             end t)
        (string-trim (match-string 1))))))

(defun agent-usage--retry-after ()
  "Return the response's `Retry-After' in seconds, or nil.
Only the delay-seconds form is read; an HTTP date yields nil."
  (when-let* ((value (agent-usage-http-header "Retry-After"))
              ((string-match-p "\\`[0-9]+\\'" value)))
    (string-to-number value)))

(defun agent-usage--fetcher (backend)
  "Return BACKEND's usage fetch function, or nil."
  (when-let* ((struct (agent-backend backend)))
    (agent-backend-usage-fetch struct)))

(defun agent-usage-refresh-pool (backend pool)
  "Fetch usage for every member of BACKEND's POOL."
  (dolist (account (agent-account-pool-members backend pool))
    (agent-usage-fetch backend account)))

;;;; Polling

(defun agent-usage--poll ()
  "Fetch usage for every account worth tracking on every backend."
  (dolist (entry agent-backends)
    (let ((backend (car entry)))
      (when (agent-usage--fetcher backend)
        (dolist (account (agent-usage--tracked-accounts backend))
          (agent-usage-fetch backend account))))))

(defun agent-usage--tracked-accounts (backend)
  "Return the accounts of BACKEND to poll.
These are the accounts of live sessions plus every pool member.  A
backend with sessions but no accounts configured yields (nil), so
its default home is polled."
  (let ((accounts (agent-usage--active-accounts backend)))
    (dolist (pool (agent-account-pools backend))
      (dolist (member (agent-account-pool-members backend pool))
        (cl-pushnew member accounts :test #'equal)))
    (if (or accounts (agent-account-list backend))
        (nreverse accounts)
      (when (agent-usage--live-buffers backend)
        (list nil)))))

(defun agent-usage--active-accounts (backend)
  "Return the distinct accounts recorded on BACKEND's live sessions."
  (let (accounts)
    (dolist (buffer (agent-usage--live-buffers backend) accounts)
      (when-let* ((session (agent-session buffer)))
        (cl-pushnew (agent-session-account session) accounts
                    :test #'equal)))))

(defun agent-usage--live-buffers (backend)
  "Return BACKEND's live session buffers."
  (when-let* ((struct (agent-backend backend))
              (finder (agent-backend-find-all-buffers struct)))
    (cl-remove-if-not #'buffer-live-p (funcall finder))))

(defun agent-usage-start-polling ()
  "Start the usage poller.
Polls immediately, then every `agent-usage-interval' seconds.  Does
nothing if the timer is already running."
  (interactive)
  (unless agent-usage--timer
    (agent-usage--poll)
    (setq agent-usage--timer
          (run-with-timer agent-usage-interval agent-usage-interval
                          #'agent-usage--poll))))

(defun agent-usage-stop-polling ()
  "Stop the usage poller."
  (interactive)
  (when agent-usage--timer
    (cancel-timer agent-usage--timer)
    (setq agent-usage--timer nil)))

(defun agent-usage-maybe-stop-polling (&optional buffer)
  "Stop polling when no backend has a live session other than BUFFER."
  (unless (cl-some (lambda (entry)
                     (cl-remove buffer (agent-usage--live-buffers (car entry))))
                   agent-backends)
    (agent-usage-stop-polling)))

;;;; Usage buffer

(defvar agent-usage-buffer-name "*agent-usage*"
  "Name of the buffer listing account usage.")

(defvar agent-usage--pending-refresh 0
  "Fetches started by `agent-usage-refresh' that have not reported yet.")

(defvar-keymap agent-usage-mode-map
  :doc "Keymap for `agent-usage-mode'."
  :parent tabulated-list-mode-map
  "g" #'agent-usage-refresh)

(define-derived-mode agent-usage-mode tabulated-list-mode "Agent-Usage"
  "Major mode listing usage for configured and active accounts."
  (setq tabulated-list-format
        [("Backend" 12 t) ("Account" 12 t) ("Pool" 10 t)
         ("Session" 8 nil :right-align t) ("Weekly" 8 nil :right-align t)
         ("Weekly reset" 18 nil) ("Limited" 8 nil) ("Age" 8 nil)
         ("Status" 0 nil)])
  (setq tabulated-list-padding 1)
  (tabulated-list-init-header))

;;;###autoload
(defun agent-usage-show ()
  "Show account usage and refresh it.
Lists configured accounts, live-session accounts, and pool members,
with the latest cached reading, then fetches fresh readings and
re-renders as they arrive."
  (interactive)
  (with-current-buffer (get-buffer-create agent-usage-buffer-name)
    (unless (derived-mode-p 'agent-usage-mode)
      (agent-usage-mode))
    (agent-usage--render)
    (pop-to-buffer (current-buffer))
    (agent-usage-refresh)))

(defun agent-usage-refresh ()
  "Fetch fresh readings for every displayed account and re-render."
  (interactive)
  (dolist (entry agent-backends)
    (let ((backend (car entry)))
      (when (agent-usage--fetcher backend)
        (dolist (account (agent-usage--display-accounts backend))
          (cl-incf agent-usage--pending-refresh)
          (agent-usage-fetch backend account #'agent-usage--refresh-done t)))))
  (message "Refreshing usage for %d account%s..."
           agent-usage--pending-refresh
           (if (= agent-usage--pending-refresh 1) "" "s")))

(defun agent-usage--refresh-done (_usage)
  "Re-render the usage buffer once a refresh fetch reports."
  (setq agent-usage--pending-refresh (max 0 (1- agent-usage--pending-refresh)))
  (when-let* ((buffer (get-buffer agent-usage-buffer-name)))
    (with-current-buffer buffer
      (agent-usage--render)))
  (when (zerop agent-usage--pending-refresh)
    (message "Usage refreshed")))

(defun agent-usage--render ()
  "Fill the current usage buffer from the store."
  (setq tabulated-list-entries (agent-usage--entries))
  (tabulated-list-print t))

(defun agent-usage--entries ()
  "Return `tabulated-list-entries' for every displayed account."
  (let (entries)
    (dolist (entry agent-backends (nreverse entries))
      (let ((backend (car entry)))
        (when (agent-usage--fetcher backend)
          (dolist (account (agent-usage--display-accounts backend))
            (push (agent-usage--entry backend account) entries)))))))

(defun agent-usage--display-accounts (backend)
  "Return BACKEND's configured and tracked accounts for the usage view.
Without configured or tracked accounts, include the default account."
  (or (cl-remove-duplicates
       (append (mapcar #'car (agent-account-list backend))
               (agent-usage--tracked-accounts backend))
       :test #'equal :from-end t)
      (list nil)))

(defun agent-usage--entry (backend account)
  "Return the tabulated-list entry for BACKEND's ACCOUNT.
A reading older than `agent-usage-stale-after' is shown in the
`shadow' face with its age in the `warning' face.  A window whose
reset time has passed shows no percentage or reset, since the reading
no longer describes the current window."
  (let* ((usage (agent-usage-get backend account))
         (stale (and (plist-get usage :fetched-at)
                     (not (agent-usage-fresh-p usage))))
         (data-face (and stale 'shadow)))
    (list (cons backend account)
          (vector (symbol-name backend)
                  (or account "default")
                  (or (agent-account-pool backend account) "")
                  (agent-usage--face
                   (agent-usage--window-pct usage :session-pct :session-reset)
                   data-face)
                  (agent-usage--face
                   (agent-usage--window-pct usage :weekly-pct :weekly-reset)
                   data-face)
                  (agent-usage--face
                   (agent-usage--reset (plist-get usage :weekly-reset))
                   data-face)
                  (agent-usage--face (if (plist-get usage :limited) "yes" "")
                                     data-face)
                  (agent-usage--face (agent-usage--age usage)
                                     (and stale 'warning))
                  (agent-usage--status usage)))))

(defun agent-usage--face (string face)
  "Return STRING in FACE, or STRING unchanged when FACE is nil."
  (if face (propertize string 'face face) string))

(defun agent-usage--window-pct (usage pct-key reset-key)
  "Return USAGE's PCT-KEY as a percentage unless RESET-KEY has passed."
  (let ((reset (plist-get usage reset-key)))
    (if (and (numberp reset) (< reset (float-time)))
        "-"
      (agent-usage--pct (plist-get usage pct-key)))))

(defun agent-usage--pct (value)
  "Return VALUE as a percentage string, or a dash when unknown."
  (if (numberp value) (format "%.0f%%" value) "-"))

(defun agent-usage--reset (seconds)
  "Return future SECONDS as a local timestamp, or an empty string."
  (if (and (numberp seconds) (>= seconds (float-time)))
      (format-time-string "%a %d %b %H:%M" seconds)
    ""))

(defun agent-usage--status (usage)
  "Return USAGE's last fetch error and next retry time, or an empty string.
A network error is shown in the `shadow' face with its time, since it
says nothing about the account; any other error in the `error' face."
  (cond
   ((not (plist-get usage :error)) "")
   ((plist-get usage :network)
    (propertize (format "network error at %s"
                        (format-time-string "%H:%M" (plist-get usage :error-at)))
                'face 'shadow))
   (t
    (propertize
     (if-let* ((retry-at (plist-get usage :retry-at))
               ((> retry-at (float-time))))
         (format "%s; retry %s" (plist-get usage :error)
                 (format-time-string "%H:%M" retry-at))
       (plist-get usage :error))
     'face 'error))))

(defun agent-usage--age (usage)
  "Return how long ago USAGE was fetched, or a dash when never."
  (if-let* ((at (plist-get usage :fetched-at)))
      (let ((seconds (- (float-time) at)))
        (if (< seconds 60) "now" (agent-usage--duration seconds)))
    "-"))

;;;; Normalization helpers

(defun agent-usage-window (pct reset)
  "Return (PCT . RESET) with RESET coerced to float seconds, or nil.
PCT is a number; RESET is an ISO 8601 string, a Unix timestamp, or
nil.  Returns nil when PCT is nil, so a missing window stays absent."
  (when (numberp pct)
    (cons (float pct) (agent-usage--time reset))))

(defun agent-usage--time (value)
  "Return VALUE as float seconds, or nil.
VALUE is an ISO 8601 string, a number of seconds, or nil."
  (cond
   ((numberp value) (float value))
   ((stringp value)
    (condition-case nil
        (float-time (encode-time (iso8601-parse value)))
      (error nil)))))

(defun agent-usage-iso-time (seconds)
  "Return float SECONDS as an ISO 8601 UTC timestamp, or nil."
  (when (numberp seconds)
    (format-time-string "%FT%TZ" seconds t)))

(provide 'agent-usage)
;;; agent-usage.el ends here
