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
;; invokes with a normalized usage plist or nil.  The plist holds
;; `:session-pct' and `:weekly-pct' (percent of the short and long
;; windows used), `:session-reset' and `:weekly-reset' (window reset
;; times as float seconds), `:limited' (non-nil when the backend
;; refuses further requests), and `:fetched-at'.
;;
;; One timer polls every account that has a live session plus every
;; member of every pool, so routing has data for idle members too.
;; Results are cached on disk so a fresh Emacs can route immediately.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'iso8601)
(require 'tabulated-list)

(defvar agent-backends)
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
  "Base interval in seconds between usage polls.
After a failed or rate-limited poll the interval doubles up to
`agent-usage-max-interval'; it resets on success."
  :type 'integer
  :group 'agent-usage)

(defcustom agent-usage-max-interval 900
  "Maximum interval in seconds between usage polls after backoff."
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

(defvar agent-usage--current-interval nil
  "Current polling interval in seconds, possibly increased by backoff.")

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

(defun agent-usage-fetch (backend account &optional callback)
  "Fetch usage for BACKEND's ACCOUNT and record the result.
Calls the backend's `:usage-fetch' slot.  CALLBACK, when non-nil, is
called with the recorded plist, or with nil when the fetch failed.
Returns nil without fetching when BACKEND declares no fetcher."
  (when-let* ((fetch (agent-usage--fetcher backend)))
    (funcall fetch account
             (lambda (usage)
               (let ((stored (when usage
                               (agent-usage-record backend account usage))))
                 (if stored
                     (agent-usage--reset-interval)
                   (agent-usage-backoff))
                 (when callback
                   (funcall callback stored)))))
    t))

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
    (setq agent-usage--current-interval agent-usage-interval)
    (agent-usage--poll)
    (setq agent-usage--timer
          (run-with-timer agent-usage-interval agent-usage-interval
                          #'agent-usage--poll))))

(defun agent-usage-stop-polling ()
  "Stop the usage poller."
  (interactive)
  (when agent-usage--timer
    (cancel-timer agent-usage--timer)
    (setq agent-usage--timer nil
          agent-usage--current-interval nil)))

(defun agent-usage-maybe-stop-polling (&optional buffer)
  "Stop polling when no backend has a live session other than BUFFER."
  (unless (cl-some (lambda (entry)
                     (cl-remove buffer (agent-usage--live-buffers (car entry))))
                   agent-backends)
    (agent-usage-stop-polling)))

(defun agent-usage-backoff ()
  "Double the polling interval, capped at `agent-usage-max-interval'."
  (when agent-usage--timer
    (agent-usage--reschedule
     (min (* 2 (or agent-usage--current-interval agent-usage-interval))
          agent-usage-max-interval))))

(defun agent-usage--reset-interval ()
  "Reset the polling interval to the base value after a success."
  (when (and agent-usage--timer
             agent-usage--current-interval
             (> agent-usage--current-interval agent-usage-interval))
    (agent-usage--reschedule agent-usage-interval)))

(defun agent-usage--reschedule (interval)
  "Restart the poll timer with INTERVAL seconds between polls."
  (setq agent-usage--current-interval interval)
  (cancel-timer agent-usage--timer)
  (setq agent-usage--timer
        (run-with-timer interval interval #'agent-usage--poll)))

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
         ("Weekly reset" 18 nil) ("Limited" 8 nil) ("Age" 8 nil)])
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
          (agent-usage-fetch backend account #'agent-usage--refresh-done)))))
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
  "Return the tabulated-list entry for BACKEND's ACCOUNT."
  (let ((usage (agent-usage-get backend account)))
    (list (cons backend account)
          (vector (symbol-name backend)
                  (or account "default")
                  (or (agent-account-pool backend account) "")
                  (agent-usage--pct (plist-get usage :session-pct))
                  (agent-usage--pct (plist-get usage :weekly-pct))
                  (agent-usage--reset (plist-get usage :weekly-reset))
                  (if (plist-get usage :limited) "yes" "")
                  (agent-usage--age usage)))))

(defun agent-usage--pct (value)
  "Return VALUE as a percentage string, or a dash when unknown."
  (if (numberp value) (format "%.0f%%" value) "-"))

(defun agent-usage--reset (seconds)
  "Return float SECONDS as a local timestamp, or an empty string."
  (if (numberp seconds) (format-time-string "%a %d %b %H:%M" seconds) ""))

(defun agent-usage--age (usage)
  "Return how long ago USAGE was fetched, or a dash when never."
  (if-let* ((at (plist-get usage :fetched-at)))
      (let ((seconds (- (float-time) at)))
        (cond
         ((< seconds 60) "now")
         ((< seconds 3600) (format "%dm" (/ seconds 60)))
         ((< seconds 86400) (format "%dh" (/ seconds 3600)))
         (t (format "%dd" (/ seconds 86400)))))
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
