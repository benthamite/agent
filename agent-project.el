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
(require 'json)
(require 'seq)
(require 'subr-x)

(defvar gptel-backend)
(defvar gptel-include-reasoning)
(defvar gptel-model)
(defvar gptel-use-tools)
(defvar gptel--known-backends)

(declare-function gptel-request "gptel")

;;;; Obsolete names

;; These renamings come before the options they rename, and live in this
;; file rather than in `agent-slack.el', where the old names were
;; defined, for one reason: a user sets an option before the package
;; that owns it is loaded, and the value reaches the new name only while
;; that name is still unbound.  A value already set on the old symbol is
;; propagated by `defvaralias'; a value merely recorded for Customize,
;; which is what `use-package' does with `:custom', is carried by
;; `define-obsolete-variable-alias' copying the `saved-value' property
;; over for the `defcustom' below to pick up.  Declared after the
;; `defcustom', or in a file that loads only when a Slack command is
;; first called, the alias would silently drop the setting.

(define-obsolete-variable-alias 'agent-claude-debug-slack-message-model
  'agent-act-on-slack-message-model "0.2")
(define-obsolete-variable-alias 'agent-claude-act-on-slack-message-model
  'agent-act-on-slack-message-model "0.2")
(make-obsolete-variable 'agent-codex-debug-slack-message-model
                        'agent-act-on-slack-message-model "0.2")
(make-obsolete-variable 'agent-codex-act-on-slack-message-model
                        'agent-act-on-slack-message-model "0.2")
(define-obsolete-variable-alias 'agent-act-on-slack-message-model
  'agent-project-ranking-model "0.3")

(define-obsolete-variable-alias 'agent-claude-debug-slack-message-backend
  'agent-act-on-slack-message-backend "0.2")
(define-obsolete-variable-alias 'agent-claude-act-on-slack-message-backend
  'agent-act-on-slack-message-backend "0.2")
(make-obsolete-variable 'agent-codex-debug-slack-message-backend
                        'agent-act-on-slack-message-backend "0.2")
(make-obsolete-variable 'agent-codex-act-on-slack-message-backend
                        'agent-act-on-slack-message-backend "0.2")
(define-obsolete-variable-alias 'agent-act-on-slack-message-backend
  'agent-project-ranking-backend "0.3")

(make-obsolete-variable 'agent-epoch-project-registry-file
                        "name the registry file in `agent-project-sources'"
                        "0.3")
(define-obsolete-variable-alias 'agent-epoch-projects-root
  'agent-project-registry-root "0.3")
(make-obsolete 'agent-epoch-project-candidates 'agent-project-candidates "0.3")

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

(defun agent-project--warn-retired-registry-file ()
  "Warn when `agent-epoch-project-registry-file' holds a value.
Nothing reads that option any more, and marking it obsolete warns only
code that mentions the symbol, which a configuration merely setting it
never does.  Without this warning such a configuration would lose its
registry from routing with no message anywhere."
  (when (bound-and-true-p agent-epoch-project-registry-file)
    (display-warning
     'agent
     (concat "`agent-epoch-project-registry-file' is obsolete and ignored; "
             "name the registry file in `agent-project-sources' instead"))))

(agent-project--warn-retired-registry-file)

(defcustom agent-project-registry-root nil
  "Directory that relative registry paths are expanded against.
Registry entries record project paths relative to the directory holding
the projects; set this to that directory."
  :type '(choice (const :tag "Unconfigured" nil) directory)
  :group 'agent)

(defcustom agent-project-ranking-model 'gemini-flash-lite-latest
  "GPtel model that orders project candidates by relevance."
  :type 'symbol
  :group 'agent)

(defcustom agent-project-ranking-backend "Gemini"
  "GPtel backend name used to order project candidates."
  :type 'string
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
  "Return the candidates contributed by SOURCE.
A SOURCE naming a JSON file is a registry; anything else is a path
pattern."
  (if (string-suffix-p ".json" source)
      (agent-project--candidates-from-registry (expand-file-name source))
    (agent-project--candidates-from-pattern source)))

(defun agent-project--candidates-from-registry (file)
  "Return the candidates recorded in registry FILE.
A JSON null is read as nil, so an entry that records one where a string
belongs falls back the same way an entry omitting the key does."
  (unless (file-exists-p file)
    (user-error "Project registry not found: %s" file))
  (with-temp-buffer
    (insert-file-contents file)
    (mapcar #'agent-project--candidate-from-registry-entry
            (alist-get 'projects (json-parse-string (buffer-string)
                                                    :object-type 'alist
                                                    :array-type 'list
                                                    :null-object nil)))))

(defun agent-project--candidate-from-registry-entry (entry)
  "Return a candidate plist for registry ENTRY."
  (let ((doc (car (agent-project--string-list
                   (alist-get 'project_doc_paths entry))))
        (repo (car (agent-project--string-list
                    (alist-get 'repo_paths entry)))))
    (list :label (agent-project--registry-label entry)
          :directory (agent-project--registry-directory doc repo)
          :description (agent-project--registry-description entry))))

(defun agent-project--registry-label (entry)
  "Return the completion label for registry ENTRY.
The title is dropped when ENTRY records none, so that a missing one
never reaches completion as the string \"nil\"."
  (if-let* ((title (alist-get 'title entry)))
      (format "%s - %s" (alist-get 'id entry) title)
    (format "%s" (alist-get 'id entry))))

(defun agent-project--registry-directory (doc repo)
  "Return the working directory for DOC and REPO paths.
The doc folder wins when an entry records both, because it holds the
project's instruction files.  An entry recording neither resolves to the
registry root."
  (cond
   (doc (file-name-directory (agent-project--registry-path doc)))
   (repo (file-name-as-directory (agent-project--registry-path repo)))
   (t (file-name-as-directory
       (expand-file-name (agent-project--registry-root))))))

(defun agent-project--registry-path (path)
  "Return PATH expanded against `agent-project-registry-root'."
  (when path
    (expand-file-name path (unless (file-name-absolute-p path)
                             (agent-project--registry-root)))))

(defun agent-project--registry-root ()
  "Return `agent-project-registry-root', or signal when it is unset."
  (or agent-project-registry-root
      (user-error
       "Set `agent-project-registry-root' to your projects directory")))

(defun agent-project--registry-description (entry)
  "Return the text that ranking judges registry ENTRY by, or nil.
Falls back to the entry's aliases when it records no summary, and to nil
when it records nothing at all, so that an uninformative candidate is
never offered for ranking."
  (when-let* ((parts (delq nil
                           (list (or (alist-get 'summary entry)
                                     (agent-project--registry-aliases entry))
                                 (agent-project--registry-keywords entry)
                                 (agent-project--registry-channels entry)))))
    (string-join parts "; ")))

(defun agent-project--registry-aliases (entry)
  "Return the aliases registry ENTRY records, as one string, or nil."
  (when-let* ((aliases (agent-project--string-list
                        (alist-get 'aliases entry))))
    (concat "aliases: " (string-join aliases ", "))))

(defun agent-project--registry-keywords (entry)
  "Return the keywords registry ENTRY records, as one string, or nil.
These are the terms the project is recognized by elsewhere, repository
slugs and domain names among them, which is the kind of token the text
being routed is likely to carry."
  (when-let* ((keywords (agent-project--string-list
                         (alist-get 'browser_keywords entry))))
    (concat "keywords: " (string-join keywords ", "))))

(defun agent-project--registry-channels (entry)
  "Return the Slack channels registry ENTRY records, as one string, or nil."
  (when-let* ((channels (agent-project--string-list
                         (alist-get 'slack_channels entry))))
    (concat "channels: " (string-join channels ", "))))

(defun agent-project--string-list (value)
  "Return VALUE as a list of strings, tolerating JSON nulls."
  (seq-filter #'stringp (if (listp value) value (list value))))

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
  "Return CANDIDATES with repeated labels disambiguated.
A label shared by two candidates is replaced with the abbreviated
directory."
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

;;;; Reading

(defun agent-project-read (account text prompt callback)
  "Read a project directory for ACCOUNT and call CALLBACK with it.
TEXT describes the thing being routed and orders the candidates when TEXT
and at least one description hold more than whitespace; a blank string is
nothing to rank on, so no request is made.  PROMPT is the completion
prompt.  CALLBACK receives the directory of the chosen project."
  (let ((candidates (agent-project-candidates account)))
    (unless candidates
      (user-error "No project candidates for account %s" (or account "(none)")))
    (if (agent-project--rankable-p text candidates)
        (agent-project--rank
         candidates text
         (lambda (ordered)
           (funcall callback (agent-project--complete ordered prompt))))
      (funcall callback (agent-project--complete candidates prompt)))))

(defun agent-project--rankable-p (text candidates)
  "Return non-nil when TEXT and CANDIDATES give a model something to rank.
A blank string is nothing to rank on, whether it is TEXT or a
description, so it counts as absent and no request is made."
  (and (agent-project--text-p text)
       (seq-some (lambda (candidate)
                   (agent-project--text-p (plist-get candidate :description)))
                 candidates)))

(defun agent-project--text-p (value)
  "Return non-nil when VALUE is a string holding more than whitespace."
  (and (stringp value) (not (string-blank-p value))))

(defun agent-project--rank (candidates text callback)
  "Order CANDIDATES by relevance to TEXT and call CALLBACK with the list.
A response that is neither text nor nil is an event sent before the
answer, such as a reasoning block, and is waited out rather than taken
for a failure, so the user is never prompted twice for one request."
  (unless (and (require 'gptel nil t) (fboundp 'gptel-request))
    (user-error "Package `gptel' is required for project ranking"))
  (let ((gptel-backend (alist-get agent-project-ranking-backend
                                  gptel--known-backends nil nil #'string=))
        (gptel-model agent-project-ranking-model)
        (gptel-include-reasoning nil)
        (gptel-use-tools nil))
    (message "Ranking projects...")
    (gptel-request
     (agent-project--ranking-prompt candidates text)
     :system (concat "You route work to existing projects. Return ONLY a "
                     "comma-separated list of project labels from the "
                     "provided list, ordered from most likely to least "
                     "likely. Do not invent labels.")
     :callback
     (lambda (response info)
       (when (or (stringp response) (null response))
         (funcall callback
                  (agent-project--ranked candidates response info)))))))

(defun agent-project--ranking-prompt (candidates text)
  "Return the ranking prompt for CANDIDATES and TEXT."
  (format "Text:\n%s\n\nProjects:\n%s"
          text
          (string-join (mapcar #'agent-project--ranking-line candidates) "\n")))

(defun agent-project--ranking-line (candidate)
  "Return the ranking description of CANDIDATE."
  (format "%s: %s"
          (plist-get candidate :label)
          (or (plist-get candidate :description) "")))

(defun agent-project--ranked (candidates response info)
  "Return CANDIDATES ordered by RESPONSE, or unchanged when it failed.
INFO describes the request.  A nil RESPONSE is a failure, reported and
answered with the original order, so a ranking failure costs order rather
than the whole action."
  (if (stringp response)
      (agent-project--ordered candidates response)
    (message "Project ranking failed: %s" (plist-get info :status))
    candidates))

(defun agent-project--ordered (candidates response)
  "Return CANDIDATES ordered by the labels named in RESPONSE.
Candidates the response did not name keep their original order at the
end, so an incomplete answer never hides a project.  A name RESPONSE
repeats, or leaves blank, matches at most the one candidate it names, so
that no candidate is offered twice or picked up by an empty name."
  (let* ((names (seq-filter #'agent-project--text-p
                            (mapcar #'string-trim (split-string response ","))))
         (matched (seq-uniq
                   (delq nil (mapcar (lambda (name)
                                       (agent-project--named name candidates))
                                     names))
                   #'eq)))
    (append matched (seq-remove (lambda (c) (memq c matched)) candidates))))

(defun agent-project--named (name candidates)
  "Return the candidate in CANDIDATES that NAME names, or nil.
A label equal to NAME wins outright, so a label that is the start of
another still names its own candidate.  Otherwise NAME is read as the
start of a label, which is what lets the model answer \"gamma\" for
\"gamma - Gamma\", and the shortest label it starts wins, resolving a
truncated name toward the closest project."
  (or (seq-find (lambda (candidate)
                  (equal name (plist-get candidate :label)))
                candidates)
      (car (seq-sort-by (lambda (candidate)
                          (length (plist-get candidate :label)))
                        #'<
                        (seq-filter
                         (lambda (candidate)
                           (string-prefix-p name (plist-get candidate :label)))
                         candidates)))))

(defun agent-project--complete (candidates prompt)
  "Return the directory of the candidate chosen from CANDIDATES with PROMPT."
  (let* ((labels (mapcar (lambda (c) (plist-get c :label)) candidates))
         (choice (completing-read prompt labels nil t nil nil (car labels))))
    (plist-get (seq-find (lambda (c) (equal (plist-get c :label) choice))
                         candidates)
               :directory)))

(provide 'agent-project)
;;; agent-project.el ends here
