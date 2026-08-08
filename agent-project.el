;;; agent-project.el --- Project sources for AI sessions -*- lexical-binding: t -*-

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

;; Candidate projects for a session that has no directory of its own.
;; Sources are scoped by account: a registry file contributes projects
;; with descriptions, a path pattern contributes directories.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)

;;;; Customization

(defcustom agent-project-sources '(("" . ("~/repos/*")))
  "Candidate project sources per account, as an alist of (REGEXP . SOURCES).
REGEXP is matched against the account name of the backend that will run
the session; the first matching entry wins, so \"\" is a catch-all that
also covers a backend with no account selected.

Each source in SOURCES is either a registry file, whose name ends in
\".json\", or a path pattern.  A wildcard is `*', `?' or a `[...]'
character class, and a pattern containing one is expanded a single
level per wildcard component, so \"*\" reaches the children of a
directory and \"*/*\" its grandchildren, keeping only git repositories
and worktrees.  A pattern without a wildcard names exactly one
directory and is kept whether or not it is a repository."
  :type '(alist :key-type regexp :value-type (repeat string))
  :group 'agent)

;;;; Candidates

(defun agent-project-candidates (&optional account)
  "Return candidate projects for ACCOUNT, deduplicated by true path.
Each candidate is a plist with `:label', `:directory' and
`:description'.  A label shared by two candidates is replaced with the
abbreviated directory, so completion never offers the same string
twice."
  (agent-project--disambiguate
   (agent-project--dedupe
    (mapcan #'agent-project--candidates-from-source
            (agent-project--sources-for-account account)))))

(defun agent-project--sources-for-account (account)
  "Return the sources of the first entry matching ACCOUNT, or nil.
ACCOUNT may be nil, which matches a catch-all entry."
  (cdr (seq-find (lambda (entry)
                   (string-match-p (car entry) (or account "")))
                 agent-project-sources)))

(defun agent-project--candidates-from-source (source)
  "Return the candidates contributed by SOURCE."
  (agent-project--candidates-from-pattern source))

(defun agent-project--candidates-from-pattern (pattern)
  "Return the candidates matching path PATTERN.
A PATTERN containing a wildcard -- `*', `?' or a `[...]' character
class -- matches a single level per wildcard component and keeps only
git repositories and worktrees.  A PATTERN without one names a single
directory, kept whether or not it is a repository."
  (let ((expanded (expand-file-name pattern)))
    (if (string-match-p "[*?[]" expanded)
        (mapcar #'agent-project--directory-candidate
                (seq-filter #'agent-project--git-directory-p
                            (agent-project--expand-wildcards expanded)))
      (when (file-directory-p expanded)
        (list (agent-project--directory-candidate expanded))))))

(defun agent-project--expand-wildcards (pattern)
  "Return the files matching PATTERN, or nil when PATTERN cannot compile.
An unbalanced `[' makes PATTERN an invalid regexp once translated, and
the resulting error is reported rather than raised so that one bad
source does not take every other source's candidates down with it."
  (condition-case error
      (file-expand-wildcards pattern)
    (invalid-regexp
     (message "Ignoring malformed project source %s: %s"
              pattern (error-message-string error))
     nil)))

(defun agent-project--directory-candidate (directory)
  "Return a candidate plist for DIRECTORY."
  (let ((dir (file-name-as-directory (expand-file-name directory))))
    (list :label (file-name-nondirectory (directory-file-name dir))
          :directory dir
          :description nil)))

(defun agent-project--git-directory-p (directory)
  "Return non-nil when DIRECTORY is a git repository or worktree.
A worktree records its git directory in a file rather than a
directory, so both are accepted."
  (and (file-directory-p directory)
       (file-exists-p (expand-file-name ".git" directory))))

(defun agent-project--dedupe (candidates)
  "Return CANDIDATES without repeated directories, keeping the first."
  (let (seen result)
    (dolist (candidate candidates (nreverse result))
      (let ((key (file-truename (plist-get candidate :directory))))
        (unless (member key seen)
          (push key seen)
          (push candidate result))))))

(defun agent-project--disambiguate (candidates)
  "Return CANDIDATES with repeated labels replaced by directories."
  (let ((counts (make-hash-table :test #'equal)))
    (dolist (candidate candidates)
      (cl-incf (gethash (plist-get candidate :label) counts 0)))
    (mapcar (lambda (candidate)
              (if (> (gethash (plist-get candidate :label) counts 0) 1)
                  (plist-put (copy-sequence candidate) :label
                             (abbreviate-file-name
                              (plist-get candidate :directory)))
                candidate))
            candidates)))

(provide 'agent-project)
;;; agent-project.el ends here
