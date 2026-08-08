# Thing-at-point Layers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `agent-act-on-thing-at-point` decide session targeting and project choice uniformly for every kind of thing, and add email as a fifth kind.

**Architecture:** Three layers. Predicates recognize the thing (unchanged). The core then chooses a session — new by default, a running one with a prefix argument — deriving the directory from the thing when it is anchored and from account-scoped project sources when it is not. Each kind supplies only its payload and whether to submit. Handlers become context extractors that call a continuation, because the Slack path is inherently asynchronous.

**Tech Stack:** Emacs Lisp (Emacs 30+), ERT, `gptel` for optional ranking, `json-parse-string` for registry sources.

## Global Constraints

- Emacs 30.0 floor; `lexical-binding: t` in every file.
- Docstrings fill to 80 columns, first line one sentence, no blank line between the first and second lines, uppercase argument names, no trailing period on error messages.
- No empty lines inside a function. Helper functions come after the function that calls them.
- `agent.el` may not `require` a feature module; it declares autoloads and `declare-function` instead. `agent-project.el` follows `agent-account.el`: required *by* `agent.el`, declaring what it needs from core.
- Predicates in `agent.el` answer from the buffer alone and never load the module owning their handler.
- Every commit runs `~/My\ Drive/dotfiles/claude/bin/batch-test.sh agent` first; the pre-commit hook requires it.
- Full suite: `make test` from the package root. Focused: `~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/<file>.el [TEST-NAME]`.

---

### Task 1: Project sources and path enumeration

**Files:**
- Create: `agent-project.el`
- Create: `test/agent-project-test.el`
- Modify: `Makefile:5-6` (add `agent-project.el` to `SRC`, `test/agent-project-test.el` to `TEST_FILES`)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `agent-project-sources` (defcustom, alist of (REGEXP . list-of-strings)); `agent-project-candidates (&optional ACCOUNT)` returning a list of plists `(:label STRING :directory STRING :description STRING-or-nil)` with `:directory` ending in a slash; `agent-project--sources-for-account (ACCOUNT)`; `agent-project--candidates-from-pattern (PATTERN)`; `agent-project--git-directory-p (DIRECTORY)`.

- [ ] **Step 1: Write the failing test**

Create `test/agent-project-test.el`:

```elisp
;;; agent-project-test.el --- Tests for agent-project -*- lexical-binding: t -*-

;; Tests for project source enumeration.

;;; Code:

(require 'ert)
(require 'agent-project)

(defun agent-project-test--make-tree (specs)
  "Return a temporary directory populated from SPECS.
Each spec is a cons of a relative directory name and a flag saying
whether that directory is a git repository."
  (let ((root (make-temp-file "agent-project-test" t)))
    (dolist (spec specs root)
      (let ((dir (expand-file-name (car spec) root)))
        (make-directory dir t)
        (when (cdr spec)
          (make-directory (expand-file-name ".git" dir) t))))))

(ert-deftest agent-project-test-wildcard-keeps-only-repositories ()
  "Expand a wildcard one level and drop directories without git."
  (let* ((root (agent-project-test--make-tree
                '(("alpha" . t) ("beta" . t) ("container" . nil))))
         (labels (mapcar (lambda (c) (plist-get c :label))
                         (agent-project--candidates-from-pattern
                          (expand-file-name "*" root)))))
    (should (equal (sort labels #'string<) '("alpha" "beta")))))

(ert-deftest agent-project-test-wildcard-does-not-recurse ()
  "Match one level only, leaving nested repositories out."
  (let* ((root (agent-project-test--make-tree
                '(("outer" . nil) ("outer/inner" . t))))
         (labels (mapcar (lambda (c) (plist-get c :label))
                         (agent-project--candidates-from-pattern
                          (expand-file-name "*" root)))))
    (should-not (member "inner" labels))))

(ert-deftest agent-project-test-plain-path-needs-no-repository ()
  "Keep a wildcard-free path whether or not it is a repository."
  (let* ((root (agent-project-test--make-tree '(("notes" . nil))))
         (dir (expand-file-name "notes" root))
         (candidates (agent-project--candidates-from-pattern dir)))
    (should (= (length candidates) 1))
    (should (equal (plist-get (car candidates) :label) "notes"))
    (should (equal (plist-get (car candidates) :directory)
                   (file-name-as-directory dir)))))

(ert-deftest agent-project-test-plain-path-that-is-missing-is-dropped ()
  "Contribute nothing for a path that does not exist."
  (should-not (agent-project--candidates-from-pattern "/nonexistent/xyzzy")))

(ert-deftest agent-project-test-account-lookup-takes-the-first-match ()
  "Return the sources of the first regexp that matches the account."
  (let ((agent-project-sources '(("epoch" . ("/a")) ("" . ("/b")))))
    (should (equal (agent-project--sources-for-account "epoch") '("/a")))
    (should (equal (agent-project--sources-for-account "personal") '("/b")))
    (should (equal (agent-project--sources-for-account nil) '("/b")))))

(ert-deftest agent-project-test-candidates-are-deduplicated ()
  "Keep one candidate per true directory across sources."
  (let* ((root (agent-project-test--make-tree '(("alpha" . t))))
         (dir (expand-file-name "alpha" root))
         (agent-project-sources
          (list (cons "" (list dir (expand-file-name "*" root))))))
    (should (= (length (agent-project-candidates nil)) 1))))

(ert-deftest agent-project-test-repeated-labels-become-directories ()
  "Replace a label shared by two candidates with its directory."
  (let* ((one (agent-project-test--make-tree '(("notes" . t))))
         (two (agent-project-test--make-tree '(("notes" . t))))
         (agent-project-sources
          (list (cons "" (list (expand-file-name "*" one)
                               (expand-file-name "*" two)))))
         (labels (mapcar (lambda (c) (plist-get c :label))
                         (agent-project-candidates nil))))
    (should-not (member "notes" labels))
    (should (= (length labels) 2))))

(provide 'agent-project-test)
;;; agent-project-test.el ends here
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-project-test.el`
Expected: FAIL — `Cannot open load file: agent-project`.

- [ ] **Step 3: Write the implementation**

Create `agent-project.el`:

```elisp
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
\".json\", or a path pattern.  A pattern containing a wildcard is
expanded one level, never recursively, and keeps only git repositories
and worktrees.  A pattern without a wildcard names exactly one
directory and is kept whether or not it is a repository."
  :type '(alist :key-type regexp :value-type (repeat string))
  :group 'agent)

;;;; Candidates

(defun agent-project-candidates (&optional account)
  "Return candidate projects for ACCOUNT, deduplicated by true path.
Each candidate is a plist with `:label', `:directory' and
`:description'.  Labels shared by two candidates are replaced with
their directories, so completion never offers the same string twice."
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
A PATTERN containing a wildcard matches one level and keeps only git
repositories and worktrees.  A PATTERN without one names a single
directory, kept whether or not it is a repository."
  (let ((expanded (expand-file-name pattern)))
    (if (string-match-p "[*?]" expanded)
        (mapcar #'agent-project--directory-candidate
                (seq-filter #'agent-project--git-directory-p
                            (file-expand-wildcards expanded)))
      (when (file-directory-p expanded)
        (list (agent-project--directory-candidate expanded))))))

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
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-project-test.el`
Expected: PASS, 7 tests.

- [ ] **Step 5: Add the new files to the Makefile**

In `Makefile`, append `agent-project.el` to `SRC` and `test/agent-project-test.el` to `TEST_FILES`.

- [ ] **Step 6: Run the full suite**

Run: `make compile && make test`
Expected: compile silent, all tests pass.

- [ ] **Step 7: Commit**

```bash
~/My\ Drive/dotfiles/claude/bin/batch-test.sh agent
git add agent-project.el test/agent-project-test.el Makefile
git commit -m "agent-project: enumerate candidate projects per account"
```

---

### Task 2: Registry sources

**Files:**
- Modify: `agent-project.el` (add registry parsing and `agent-project-registry-root`)
- Modify: `test/agent-project-test.el` (add registry tests)

**Interfaces:**
- Consumes: `agent-project--candidates-from-source`, `agent-project--directory-candidate` from Task 1.
- Produces: `agent-project-registry-root` (defcustom directory); `agent-project--candidates-from-registry (FILE)` returning candidates whose `:description` is non-nil.

- [ ] **Step 1: Write the failing test**

Append to `test/agent-project-test.el`, before the `provide` form:

```elisp
(defconst agent-project-test--registry-json
  "{\"projects\": [
     {\"id\": \"alpha\", \"title\": \"Alpha\", \"summary\": \"First project\",
      \"project_doc_paths\": [\"alpha/alpha.org\"], \"repo_paths\": [],
      \"slack_channels\": [\"#alpha\"], \"aliases\": []},
     {\"id\": \"beta\", \"title\": \"Beta\", \"project_doc_paths\": [],
      \"repo_paths\": [\"~/repos/epoch/beta\"], \"slack_channels\": [],
      \"aliases\": [\"b\"]}]}"
  "Registry JSON exercising both directory sources and both summaries.")

(defun agent-project-test--registry-file ()
  "Return a temporary registry file holding the test JSON."
  (let ((file (make-temp-file "agent-project-registry" nil ".json")))
    (with-temp-file file
      (insert agent-project-test--registry-json))
    file))

(ert-deftest agent-project-test-registry-prefers-the-doc-directory ()
  "Resolve a project to its doc folder when it records one."
  (let* ((agent-project-registry-root "/tmp/projects/")
         (candidates (agent-project--candidates-from-registry
                      (agent-project-test--registry-file)))
         (alpha (car candidates)))
    (should (equal (plist-get alpha :directory) "/tmp/projects/alpha/"))))

(ert-deftest agent-project-test-registry-falls-back-to-the-repository ()
  "Resolve a project to its repository when it records no doc path."
  (let* ((agent-project-registry-root "/tmp/projects/")
         (beta (nth 1 (agent-project--candidates-from-registry
                       (agent-project-test--registry-file)))))
    (should (equal (plist-get beta :directory)
                   (file-name-as-directory
                    (expand-file-name "~/repos/epoch/beta"))))))

(ert-deftest agent-project-test-registry-labels-and-descriptions ()
  "Label a registry project by id and title, and describe it for ranking."
  (let* ((agent-project-registry-root "/tmp/projects/")
         (candidates (agent-project--candidates-from-registry
                      (agent-project-test--registry-file))))
    (should (equal (plist-get (car candidates) :label) "alpha - Alpha"))
    (should (string-match-p "First project"
                            (plist-get (car candidates) :description)))
    (should (string-match-p "#alpha"
                            (plist-get (car candidates) :description)))
    (should (string-match-p "b" (plist-get (nth 1 candidates) :description)))))

(ert-deftest agent-project-test-json-source-is-read-as-a-registry ()
  "Route a source ending in .json through the registry reader."
  (let* ((agent-project-registry-root "/tmp/projects/")
         (agent-project-sources
          (list (cons "" (list (agent-project-test--registry-file)))))
         (candidates (agent-project-candidates nil)))
    (should (= (length candidates) 2))
    (should (plist-get (car candidates) :description))))

(ert-deftest agent-project-test-missing-registry-signals ()
  "Signal a user error when a registry source does not exist."
  (let ((agent-project-sources '(("" . ("/nonexistent/registry.json")))))
    (should-error (agent-project-candidates nil) :type 'user-error)))
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-project-test.el`
Expected: FAIL — `agent-project--candidates-from-registry` is void.

- [ ] **Step 3: Write the implementation**

In `agent-project.el`, add `(require 'json)` to the requires, add the option after `agent-project-sources`:

```elisp
(defcustom agent-project-registry-root nil
  "Directory that relative registry paths are expanded against.
Registry entries record project paths relative to the directory holding
the projects; set this to that directory."
  :type '(choice (const :tag "Unconfigured" nil) directory)
  :group 'agent)
```

Replace `agent-project--candidates-from-source` with the dispatching version and add the registry reader after it:

```elisp
(defun agent-project--candidates-from-source (source)
  "Return the candidates contributed by SOURCE.
A SOURCE naming a JSON file is a registry; anything else is a path
pattern."
  (if (string-suffix-p ".json" source)
      (agent-project--candidates-from-registry (expand-file-name source))
    (agent-project--candidates-from-pattern source)))

(defun agent-project--candidates-from-registry (file)
  "Return the candidates recorded in registry FILE."
  (unless (file-exists-p file)
    (user-error "Project registry not found: %s" file))
  (with-temp-buffer
    (insert-file-contents file)
    (mapcar #'agent-project--candidate-from-registry-entry
            (alist-get 'projects (json-parse-string (buffer-string)
                                                    :object-type 'alist
                                                    :array-type 'list)))))

(defun agent-project--candidate-from-registry-entry (entry)
  "Return a candidate plist for registry ENTRY."
  (let ((doc (car (agent-project--string-list
                   (alist-get 'project_doc_paths entry))))
        (repo (car (agent-project--string-list
                    (alist-get 'repo_paths entry)))))
    (list :label (format "%s - %s"
                         (alist-get 'id entry) (alist-get 'title entry))
          :directory (agent-project--registry-directory doc repo)
          :description (agent-project--registry-description entry))))

(defun agent-project--registry-directory (doc repo)
  "Return the working directory for relative DOC and REPO paths.
The doc folder wins when an entry records both, because it holds the
project's instruction files."
  (cond
   (doc (file-name-directory (agent-project--registry-path doc)))
   (repo (file-name-as-directory
          (directory-file-name (agent-project--registry-path repo))))
   (t (or agent-project-registry-root
          (user-error
           "Set `agent-project-registry-root' to your projects directory")))))

(defun agent-project--registry-path (path)
  "Return PATH expanded against `agent-project-registry-root'."
  (when path
    (when (and (not (file-name-absolute-p path))
               (null agent-project-registry-root))
      (user-error
       "Set `agent-project-registry-root' to your projects directory"))
    (expand-file-name path agent-project-registry-root)))

(defun agent-project--registry-description (entry)
  "Return the text ranking uses to judge registry ENTRY.
Falls back to the entry's aliases when it records no summary."
  (string-join
   (delq nil
         (list (or (alist-get 'summary entry)
                   (when-let* ((aliases (agent-project--string-list
                                         (alist-get 'aliases entry))))
                     (concat "aliases: " (string-join aliases ", "))))
               (when-let* ((channels (agent-project--string-list
                                      (alist-get 'slack_channels entry))))
                 (concat "channels: " (string-join channels ", ")))))
   "; "))

(defun agent-project--string-list (value)
  "Return VALUE as a list of strings, tolerating JSON nulls."
  (seq-filter #'stringp (if (listp value) value (list value))))
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-project-test.el`
Expected: PASS, 12 tests.

- [ ] **Step 5: Run the full suite and commit**

```bash
make compile && make test
~/My\ Drive/dotfiles/claude/bin/batch-test.sh agent
git add agent-project.el test/agent-project-test.el
git commit -m "agent-project: read projects from a registry source"
```

---

### Task 3: Ranking and the project prompt

**Files:**
- Modify: `agent-project.el`
- Modify: `test/agent-project-test.el`

**Interfaces:**
- Consumes: `agent-project-candidates` from Tasks 1-2.
- Produces: `agent-project-read (ACCOUNT TEXT PROMPT CALLBACK)` calling CALLBACK with the chosen directory string; `agent-project-ranking-model`; `agent-project-ranking-backend`.

- [ ] **Step 1: Write the failing test**

Append to `test/agent-project-test.el` before the `provide` form:

```elisp
(ert-deftest agent-project-test-read-skips-ranking-without-descriptions ()
  "Complete directly when no candidate carries a description."
  (let* ((root (agent-project-test--make-tree '(("alpha" . t))))
         (agent-project-sources (list (cons "" (list (expand-file-name "*" root)))))
         (ranked nil)
         (chosen nil))
    (cl-letf (((symbol-function 'agent-project--rank)
               (lambda (&rest _) (setq ranked t)))
              ((symbol-function 'completing-read)
               (lambda (&rest _) "alpha")))
      (agent-project-read nil "some text" "Project: "
                          (lambda (dir) (setq chosen dir))))
    (should-not ranked)
    (should (equal chosen (file-name-as-directory
                           (expand-file-name "alpha" root))))))

(ert-deftest agent-project-test-read-ranks-when-descriptions-exist ()
  "Rank candidates when a registry contributed them."
  (let* ((agent-project-registry-root "/tmp/projects/")
         (agent-project-sources
          (list (cons "" (list (agent-project-test--registry-file)))))
         (ranked nil))
    (cl-letf (((symbol-function 'agent-project--rank)
               (lambda (candidates _text callback)
                 (setq ranked t)
                 (funcall callback candidates)))
              ((symbol-function 'completing-read)
               (lambda (&rest _) "alpha - Alpha")))
      (agent-project-read nil "some text" "Project: " #'ignore))
    (should ranked)))

(ert-deftest agent-project-test-read-without-text-does-not-rank ()
  "Skip ranking when the thing carries no text to rank on."
  (let* ((agent-project-registry-root "/tmp/projects/")
         (agent-project-sources
          (list (cons "" (list (agent-project-test--registry-file)))))
         (ranked nil))
    (cl-letf (((symbol-function 'agent-project--rank)
               (lambda (&rest _) (setq ranked t)))
              ((symbol-function 'completing-read)
               (lambda (&rest _) "alpha - Alpha")))
      (agent-project-read nil nil "Project: " #'ignore))
    (should-not ranked)))

(ert-deftest agent-project-test-read-without-sources-signals ()
  "Signal a user error when the account has no configured sources."
  (let ((agent-project-sources nil))
    (should-error (agent-project-read nil nil "Project: " #'ignore)
                  :type 'user-error)))

(ert-deftest agent-project-test-ordering-follows-the-response ()
  "Order candidates by the labels the model returned, keeping the rest."
  (let ((candidates (list (list :label "alpha - Alpha")
                          (list :label "beta - Beta")
                          (list :label "gamma - Gamma"))))
    (should (equal (mapcar (lambda (c) (plist-get c :label))
                           (agent-project--ordered candidates "gamma, alpha"))
                   '("gamma - Gamma" "alpha - Alpha" "beta - Beta")))))
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-project-test.el`
Expected: FAIL — `agent-project-read` is void.

- [ ] **Step 3: Write the implementation**

In `agent-project.el`, add the forward declarations after the requires:

```elisp
(defvar gptel-backend)
(defvar gptel-include-reasoning)
(defvar gptel-model)
(defvar gptel-use-tools)
(defvar gptel--known-backends)
(declare-function gptel-request "gptel")
```

Add the options after `agent-project-registry-root`:

```elisp
(defcustom agent-project-ranking-model 'gemini-flash-lite-latest
  "GPtel model that orders project candidates by relevance."
  :type 'symbol
  :group 'agent)

(defcustom agent-project-ranking-backend "Gemini"
  "GPtel backend name used to order project candidates."
  :type 'string
  :group 'agent)
```

Add the prompt and ranking after `agent-project-candidates`:

```elisp
(defun agent-project-read (account text prompt callback)
  "Read a project directory for ACCOUNT and call CALLBACK with it.
TEXT describes the thing being routed and orders the candidates when
any of them carries a description; without descriptions there is
nothing to rank on, so no request is made.  PROMPT is the completion
prompt.  CALLBACK receives the directory of the chosen project."
  (let ((candidates (agent-project-candidates account)))
    (unless candidates
      (user-error "No project sources for account %s" (or account "(none)")))
    (if (and text (seq-some (lambda (c) (plist-get c :description)) candidates))
        (agent-project--rank
         candidates text
         (lambda (ordered)
           (funcall callback (agent-project--complete ordered prompt))))
      (funcall callback (agent-project--complete candidates prompt)))))

(defun agent-project--complete (candidates prompt)
  "Return the directory of the candidate chosen from CANDIDATES with PROMPT."
  (let* ((labels (mapcar (lambda (c) (plist-get c :label)) candidates))
         (choice (completing-read prompt labels nil t nil nil (car labels))))
    (plist-get (seq-find (lambda (c) (equal (plist-get c :label) choice))
                         candidates)
               :directory)))

(defun agent-project--rank (candidates text callback)
  "Order CANDIDATES by relevance to TEXT and call CALLBACK with the list.
Call CALLBACK with the original order when the request fails, so a
ranking failure costs order rather than the whole action."
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
       (if (stringp response)
           (funcall callback (agent-project--ordered candidates response))
         (message "Project ranking failed: %s" (plist-get info :status))
         (funcall callback candidates))))))

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

(defun agent-project--ordered (candidates response)
  "Return CANDIDATES ordered by the labels named in RESPONSE.
Candidates the response did not name keep their original order at the
end, so an incomplete answer never hides a project."
  (let* ((names (mapcar #'string-trim (split-string response ",")))
         (matched (delq nil
                        (mapcar (lambda (name)
                                  (seq-find (lambda (candidate)
                                              (string-prefix-p
                                               name
                                               (plist-get candidate :label)))
                                            candidates))
                                names))))
    (append matched (seq-remove (lambda (c) (memq c matched)) candidates))))
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-project-test.el`
Expected: PASS, 17 tests.

- [ ] **Step 5: Run the full suite and commit**

```bash
make compile && make test
~/My\ Drive/dotfiles/claude/bin/batch-test.sh agent
git add agent-project.el test/agent-project-test.el
git commit -m "agent-project: rank and read a project for a routed thing"
```

---

### Task 4: The dispatcher's session and delivery layers

**Files:**
- Modify: `agent.el:40` (require `agent-project`), `agent.el:42-48` (autoloads), and the act-on-thing block added earlier (currently `agent-act-on-thing-at-point`, `agent-at-point-actions`, `agent--action-at-point`)
- Modify: `test/agent-test.el` (`;;;; Act on thing at point` section)

**Interfaces:**
- Consumes: `agent-project-read` from Task 3; `agent--resolve-backend`, `agent-account-current`, `agent-start-session`, `agent-session-create`, `agent-send-string`, `agent-submit`, `agent--find-all-buffers` from core.
- Produces: `agent-at-point-things` (defvar, alist of PREDICATE . EXTRACTOR); `agent-act-on-thing-at-point (&optional EXISTING)`; `agent--act-on-context (EXTRACTOR EXISTING)`; `agent--deliver-context (CONTEXT EXISTING)`; `agent--read-session-buffer ()`. A context is a plist with `:directory` or `:text`, plus `:payload`, `:submit` and optional `:after`.

- [ ] **Step 1: Update the existing predicate tests**

The predicate tests written earlier call `agent--action-at-point` and expect command symbols. Rename the calls to `agent--extractor-at-point` and change every expectation to the extractor: in `agent-test-action-at-point-finds-a-backtrace` expect `agent--backtrace-context`, in `...-finds-a-slack-message` expect `agent-slack-context`, in `...-finds-a-forge-topic` expect `agent-forge-context`, in `...-finds-an-org-todo` expect `agent-todo-context`. The four negative tests (`...-ignores-a-forge-buffer-without-a-topic`, `...-never-consults-forge-elsewhere`, `...-ignores-an-org-heading-without-a-todo`) only assert nil and need the rename alone.

- [ ] **Step 2: Write the failing test**

In `test/agent-test.el`, replace the tests `agent-test-action-at-point-takes-the-first-match` and `agent-test-act-on-thing-at-point-errors-without-a-thing` with:

```elisp
(ert-deftest agent-test-thing-at-point-takes-the-first-match ()
  "Take the earliest matching entry when two predicates match."
  (let ((agent-at-point-things '((always . first-extractor)
                                 (always . second-extractor))))
    (should (eq (agent--extractor-at-point) 'first-extractor))))

(ert-deftest agent-test-act-on-thing-at-point-errors-without-a-thing ()
  "Signal a user error when nothing at point is actionable."
  (with-temp-buffer
    (should-error (agent-act-on-thing-at-point) :type 'user-error)))

(defun agent-test--context-extractor (context)
  "Return an extractor that yields CONTEXT immediately."
  (lambda (callback) (funcall callback context)))

(ert-deftest agent-test-anchored-context-starts-a-session-in-its-directory ()
  "Start the new session in the directory the thing carries."
  (let ((started nil))
    (cl-letf (((symbol-function 'agent--resolve-backend) (lambda () 'test))
              ((symbol-function 'agent--start-session-in)
               (lambda (_backend dir) (setq started dir) (current-buffer)))
              ((symbol-function 'agent-send-string) #'ignore)
              ((symbol-function 'display-buffer) #'ignore))
      (agent--act-on-context
       (agent-test--context-extractor '(:directory "/tmp/anchored/" :payload "url"))
       nil))
    (should (equal started "/tmp/anchored/"))))

(ert-deftest agent-test-unanchored-context-reads-a-project ()
  "Choose a project from the account's sources when nothing is anchored."
  (let ((asked nil)
        (started nil))
    (cl-letf (((symbol-function 'agent--resolve-backend) (lambda () 'test))
              ((symbol-function 'agent-account-current) (lambda (_) "epoch"))
              ((symbol-function 'agent-project-read)
               (lambda (account text _prompt callback)
                 (setq asked (list account text))
                 (funcall callback "/tmp/chosen/")))
              ((symbol-function 'agent--start-session-in)
               (lambda (_backend dir) (setq started dir) (current-buffer)))
              ((symbol-function 'agent-send-string) #'ignore)
              ((symbol-function 'display-buffer) #'ignore))
      (agent--act-on-context
       (agent-test--context-extractor '(:text "hello" :payload "url"))
       nil))
    (should (equal asked '("epoch" "hello")))
    (should (equal started "/tmp/chosen/"))))

(ert-deftest agent-test-prefix-argument-targets-a-running-session ()
  "Send to a chosen running session instead of starting one."
  (with-temp-buffer
    (let ((sent nil)
          (target (current-buffer)))
      (cl-letf (((symbol-function 'agent--read-session-buffer) (lambda () target))
                ((symbol-function 'agent--start-session-in)
                 (lambda (&rest _) (error "Started a session")))
                ((symbol-function 'agent-send-string)
                 (lambda (string buffer) (setq sent (cons string buffer))))
                ((symbol-function 'display-buffer) #'ignore))
        (agent--act-on-context
         (agent-test--context-extractor '(:text "hello" :payload "url"))
         t))
      (should (equal sent (cons "url" target))))))

(ert-deftest agent-test-context-submits-when-it-asks ()
  "Submit the payload when the context says so, and run its after thunk."
  (with-temp-buffer
    (let ((submitted nil)
          (after nil)
          (target (current-buffer)))
      (cl-letf (((symbol-function 'agent--read-session-buffer) (lambda () target))
                ((symbol-function 'agent-submit)
                 (lambda (string _buffer) (setq submitted string)))
                ((symbol-function 'agent-send-string)
                 (lambda (&rest _) (error "Sent without submitting")))
                ((symbol-function 'display-buffer) #'ignore))
        (agent--act-on-context
         (agent-test--context-extractor
          (list :text "t" :payload "do it" :submit t
                :after (lambda () (setq after t))))
         t))
      (should (equal submitted "do it"))
      (should after))))

(ert-deftest agent-test-read-session-buffer-without-sessions-signals ()
  "Signal a user error when no session is running."
  (cl-letf (((symbol-function 'agent--find-all-buffers) (lambda () nil)))
    (should-error (agent--read-session-buffer) :type 'user-error)))
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-test.el`
Expected: FAIL — `agent--extractor-at-point` and `agent--act-on-context` are void.

- [ ] **Step 4: Write the implementation**

In `agent.el`, add `(require 'agent-project)` next to `(require 'agent-account)`, and add these autoloads to the split-module block:

```elisp
(autoload 'agent-slack-context "agent-slack")
(autoload 'agent-forge-context "agent-forge")
(autoload 'agent-todo-context "agent-todo")
```

Replace the whole act-on-thing block (`agent-act-on-thing-at-point`, `agent-at-point-actions`, `agent--action-at-point`, keeping the four predicates as they are) with:

```elisp
;;;###autoload
(defun agent-act-on-thing-at-point (&optional existing)
  "Route the thing at point to an AI session.
Start a new session for it, or with prefix argument EXISTING send it to
a running session chosen by completion.  The thing is the first entry
in `agent-at-point-things' whose predicate matches: a backtrace, a
Slack message, a Forge notification or topic, or an org TODO."
  (interactive "P")
  (agent--act-on-context
   (or (agent--extractor-at-point)
       (user-error "Nothing to act on at point; expected a Slack message, a Forge notification or topic, a backtrace, or an org TODO"))
   existing))

(defvar agent-at-point-things
  '((agent--backtrace-at-point-p . agent--backtrace-context)
    (agent--slack-message-at-point-p . agent-slack-context)
    (agent--forge-topic-at-point-p . agent-forge-context)
    (agent--org-todo-at-point-p . agent-todo-context))
  "Things `agent-act-on-thing-at-point' recognizes, in order.
Each entry is a cons of a predicate called with no arguments in the
current buffer and an extractor called with one continuation.  Every
predicate answers from the buffer alone, without loading the module
that owns its extractor.

An extractor calls its continuation with a context plist: `:directory'
when the thing carries a working directory, `:text' when it carries
only text for a project to be chosen from, `:payload' for what to send,
`:submit' for whether to submit it, and an optional `:after' thunk run
once the payload is delivered.  The continuation is called rather than
returned to because extraction can require network round-trips.")

(defun agent--extractor-at-point ()
  "Return the extractor for the thing at point, or nil when there is none."
  (cdr (seq-find (lambda (thing) (funcall (car thing)))
                 agent-at-point-things)))

(defun agent--act-on-context (extractor existing)
  "Extract a context with EXTRACTOR and deliver it to a session.
With EXISTING non-nil the context goes to a running session chosen by
completion; otherwise a new session is started for it."
  (funcall extractor (lambda (context)
                       (agent--deliver-context context existing))))

(defun agent--deliver-context (context existing)
  "Deliver CONTEXT to a session, choosing a running one when EXISTING."
  (if existing
      (agent--deliver-to context (agent--read-session-buffer))
    (agent--deliver-to-new-session context)))

(defun agent--deliver-to-new-session (context)
  "Start a session for CONTEXT and deliver it there.
An anchored context names its own directory; an unanchored one has its
project read from the account's sources, ranked by its text."
  (let ((backend (agent--resolve-backend)))
    (if-let* ((directory (plist-get context :directory)))
        (agent--deliver-to context (agent--start-session-in backend directory))
      (agent-project-read
       (agent-account-current backend)
       (plist-get context :text)
       "Project: "
       (lambda (directory)
         (agent--deliver-to context
                            (agent--start-session-in backend directory)))))))

(defun agent--start-session-in (backend directory)
  "Start a BACKEND session in DIRECTORY and return its buffer."
  (let ((dir (file-name-as-directory (expand-file-name directory)))
        (label (when-let* ((struct (agent-backend backend)))
                 (agent-backend-label struct))))
    (message "Starting %s in %s..." label (abbreviate-file-name dir))
    (agent-start-session
     (agent-session-create :backend backend :directory dir))))

(defun agent--deliver-to (context buffer)
  "Deliver CONTEXT's payload to session BUFFER and return the buffer."
  (if (plist-get context :submit)
      (agent-submit (plist-get context :payload) buffer)
    (agent-send-string (plist-get context :payload) buffer))
  (when-let* ((after (plist-get context :after)))
    (funcall after))
  (display-buffer buffer)
  buffer)

(defun agent--read-session-buffer ()
  "Return a running session buffer, prompting when there are several."
  (let ((buffers (agent--find-all-buffers)))
    (pcase buffers
      ('nil (user-error "No AI session is running"))
      (`(,buffer) buffer)
      (_ (get-buffer (completing-read "Session: "
                                      (mapcar #'buffer-name buffers) nil t))))))
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-test.el`
Expected: PASS. The extractors do not exist yet, but nothing calls them: the predicate tests compare symbols and the delivery tests supply their own extractor, so the suite is green at the end of this task.

- [ ] **Step 6: Commit**

```bash
~/My\ Drive/dotfiles/claude/bin/batch-test.sh agent
git add agent.el test/agent-test.el
git commit -m "agent: split thing-at-point into extraction, targeting and delivery"
```

---

### Task 5: Anchored extractors — Forge and backtrace

**Files:**
- Modify: `agent-forge.el:52-69` (replace `agent-act-on-forge-notification`), delete `agent-forge--start-session`
- Modify: `agent.el` (backtrace extractor; rework `agent--debug-identify-package` and `agent--debug-start-session`)
- Modify: `test/agent-test.el`

**Interfaces:**
- Consumes: `agent--act-on-context` from Task 4.
- Produces: `agent-forge-context (CALLBACK)`; `agent--backtrace-context (CALLBACK)`; `agent--debug-read-package-directory (BACKTRACE-FILE CALLBACK)` calling CALLBACK with a directory.

- [ ] **Step 1: Write the failing test**

Append to the act-on-thing section of `test/agent-test.el`:

```elisp
(ert-deftest agent-test-backtrace-context-carries-the-file-and-submits ()
  "Describe a backtrace as an anchored, submitted context."
  (let ((context nil))
    (cl-letf (((symbol-function 'agent-save-backtrace) (lambda () "/tmp/bt.txt"))
              ((symbol-function 'agent--debug-read-package-directory)
               (lambda (_file callback) (funcall callback "/tmp/pkg/"))))
      (agent--backtrace-context (lambda (c) (setq context c))))
    (should (equal (plist-get context :directory) "/tmp/pkg/"))
    (should (plist-get context :submit))
    (should (string-match-p "/tmp/bt.txt" (plist-get context :payload)))))
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-test.el agent-test-backtrace-context-carries-the-file-and-submits`
Expected: FAIL — `agent--backtrace-context` is void.

- [ ] **Step 3: Write the backtrace extractor**

In `agent.el`, replace `agent-debug-backtrace` and `agent--debug-start-session` with:

```elisp
;;;###autoload
(defun agent-debug-backtrace (&optional existing)
  "Route the backtrace in the current buffer to an AI session.
With prefix argument EXISTING send it to a running session."
  (interactive "P")
  (agent--act-on-context #'agent--backtrace-context existing))

(defun agent--backtrace-context (callback)
  "Call CALLBACK with the context for the backtrace in this buffer.
Saving the backtrace kills its buffer, which exits the debugger's
`recursive-edit' and unwinds this frame, so identification is scheduled
to run after the current command rather than called here."
  (let ((file (expand-file-name agent-backtrace-file)))
    (run-with-timer 0 nil #'agent--backtrace-context-for-file file callback)
    (agent-save-backtrace)))

(defun agent--backtrace-context-for-file (file callback)
  "Identify the package for FILE and call CALLBACK with its context."
  (agent--debug-read-package-directory
   file
   (lambda (directory)
     (funcall callback
              (list :directory directory
                    :payload (format "Read the backtrace at %s. Identify the bug, fix it, and commit the fix."
                                     file)
                    :submit t)))))
```

Rename `agent--debug-identify-package` to `agent--debug-read-package-directory`, drop its BACKEND argument, and have its `completing-read` callback resolve a directory instead of starting a session. Its body changes only in the final callback, which becomes:

```elisp
           (let* ((candidates (mapcar #'string-trim
                                      (split-string text ",")))
                  (selected
                   (completing-read "Package to debug: " candidates nil
                                    nil nil nil (car candidates)))
                  (directory (or (agent--package-source-directory
                                  (intern selected))
                                 (user-error "Package `%s' not found"
                                             selected))))
             (funcall callback directory))
```

- [ ] **Step 4: Write the Forge extractor**

In `agent-forge.el`, replace `agent-act-on-forge-notification` and delete `agent-forge--start-session`:

```elisp
;;;###autoload
(defun agent-act-on-forge-notification (&optional existing)
  "Route the Forge notification or topic at point to an AI session.
With prefix argument EXISTING send it to a running session instead of
starting one in the repository's working tree."
  (interactive "P")
  (agent--act-on-context #'agent-forge-context existing))

(defun agent-forge-context (callback)
  "Call CALLBACK with the context for the Forge topic at point.
The context is anchored: the repository's working tree is where the
session belongs, so no project has to be chosen."
  (let* ((topic (agent-forge--topic-at-point))
         (repo (forge-get-repository topic))
         (url (or (forge-get-url topic)
                  (user-error "Forge topic has no URL"))))
    (funcall callback (list :directory (agent-forge--worktree repo)
                            :payload url
                            :submit nil))))
```

- [ ] **Step 5: Run the tests**

Run: `make compile && make test`
Expected: PASS, including the new backtrace-context test.

- [ ] **Step 6: Commit**

```bash
make compile
~/My\ Drive/dotfiles/claude/bin/batch-test.sh agent
git add agent.el agent-forge.el test/agent-test.el
git commit -m "agent: turn the Forge and backtrace handlers into extractors"
```

---

### Task 6: Unanchored extractors — Slack and org TODO

**Files:**
- Modify: `agent-slack.el` (replace `agent-act-on-slack-message`; delete `agent-slack--act-on-start-session`, `agent-slack--act-on-message`, `agent-slack--identify-epoch-project`, `agent-slack--project-selection-prompt`, `agent-slack--format-epoch-project`, `agent-slack--read-epoch-project-from-response`, `agent-slack--ordered-epoch-project-candidates`, `agent-slack--epoch-project-label`, `agent-epoch-project-candidates`, `agent-slack--epoch-projects-from-json`, `agent-slack--epoch-project-from-project-registry`, `agent-slack--epoch-project-registry-summary`, `agent-slack--epoch-project-registry-notes`, `agent-slack--epoch-project-directory-from-paths`, `agent-slack--epoch-project-path`, `agent-slack--json-list`, and the `agent-epoch-project-registry-file`, `agent-epoch-projects-root`, `agent-act-on-slack-message-model`, `agent-act-on-slack-message-backend` options)
- Modify: `agent-todo.el:309-329`
- Modify: `test/agent-slack-test.el`, `test/agent-todo-test.el`

**Interfaces:**
- Consumes: `agent--act-on-context` from Task 4; `agent-slack--with-message-context` (unchanged).
- Produces: `agent-slack-context (CALLBACK)`; `agent-todo-context (CALLBACK)`.

- [ ] **Step 1: Write the failing tests**

In `test/agent-slack-test.el`, delete every test naming a deleted function and add:

```elisp
(ert-deftest agent-slack-test-context-is-unanchored ()
  "Describe a Slack message by its text and permalink, unsubmitted."
  (let ((context nil))
    (cl-letf (((symbol-function 'agent-slack--with-message-context)
               (lambda (callback)
                 (funcall callback '(:text "ship it" :url "https://slack/x")))))
      (agent-slack-context (lambda (c) (setq context c))))
    (should (equal (plist-get context :text) "ship it"))
    (should (equal (plist-get context :payload) "https://slack/x"))
    (should-not (plist-get context :directory))
    (should-not (plist-get context :submit))))
```

In `test/agent-todo-test.el`, add:

```elisp
(ert-deftest agent-todo-test-context-submits-and-marks-in-progress ()
  "Describe a TODO as unanchored, submitted, and state-changing."
  (with-temp-buffer
    (org-mode)
    (insert "* TODO Fix the thing\nSome body\n")
    (goto-char (point-min))
    (let ((context nil)
          (agent-todo-in-progress-keyword "DOING"))
      (agent-todo-context (lambda (c) (setq context c)))
      (should (plist-get context :submit))
      (should-not (plist-get context :directory))
      (should (string-match-p "Fix the thing" (plist-get context :payload)))
      (should (equal (plist-get context :text) (plist-get context :payload)))
      (cl-letf (((symbol-function 'org-todo)
                 (lambda (state) (should (equal state "DOING")))))
        (funcall (plist-get context :after))))))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-slack-test.el` and the same for `test/agent-todo-test.el`
Expected: FAIL — `agent-slack-context` and `agent-todo-context` are void.

- [ ] **Step 3: Write the Slack extractor**

In `agent-slack.el`, replace `agent-act-on-slack-message` and its helpers with:

```elisp
;;;###autoload
(defun agent-act-on-slack-message (&optional existing)
  "Route the Slack message at point to an AI session.
With prefix argument EXISTING send it to a running session instead of
starting one in a project chosen from the message text."
  (interactive "P")
  (agent--act-on-context #'agent-slack-context existing))

(defun agent-slack-context (callback)
  "Call CALLBACK with the context for the Slack message at point.
The context is unanchored: a message names no directory, so its text
picks the project."
  (agent-slack--with-message-context
   (lambda (context)
     (funcall callback (list :text (plist-get context :text)
                             :payload (plist-get context :url)
                             :submit nil)))))
```

Delete the listed helpers and options. Add obsolescence markers where the old option names were:

```elisp
(define-obsolete-variable-alias 'agent-act-on-slack-message-model
  'agent-project-ranking-model "0.3")
(define-obsolete-variable-alias 'agent-act-on-slack-message-backend
  'agent-project-ranking-backend "0.3")
(define-obsolete-variable-alias 'agent-epoch-projects-root
  'agent-project-registry-root "0.3")
(make-obsolete-variable 'agent-epoch-project-registry-file
                        "name the registry file in `agent-project-sources'"
                        "0.3")
(make-obsolete 'agent-epoch-project-candidates 'agent-project-candidates "0.3")
```

- [ ] **Step 4: Write the org TODO extractor**

In `agent-todo.el`, replace `agent-send-todo-at-point` with:

```elisp
;;;###autoload
(defun agent-send-todo-at-point (&optional existing)
  "Route the org TODO at point to an AI session.
With prefix argument EXISTING send it to a running session instead of
starting one in a project chosen from the TODO's text."
  (interactive "P")
  (agent--act-on-context #'agent-todo-context existing))

(defun agent-todo-context (callback)
  "Call CALLBACK with the context for the org TODO at point.
The TODO is both the text a project is chosen from and the request
itself, so it is submitted rather than left for review."
  (unless (derived-mode-p 'org-mode)
    (user-error "Must be called from an org-mode buffer"))
  (unless (org-get-todo-state)
    (user-error "Point is not on a TODO heading"))
  (let* ((prompt (agent-todo--format-prompt (agent-todo--collect-at-point)))
         (marker (point-marker)))
    (funcall callback
             (list :text prompt
                   :payload prompt
                   :submit t
                   :after (lambda () (agent-todo--mark-in-progress marker))))))

(defun agent-todo--mark-in-progress (marker)
  "Set the TODO state at MARKER to `agent-todo-in-progress-keyword'."
  (when (and agent-todo-in-progress-keyword (marker-buffer marker))
    (with-current-buffer (marker-buffer marker)
      (save-excursion
        (goto-char marker)
        (org-todo agent-todo-in-progress-keyword)))))
```

- [ ] **Step 5: Run the tests**

Run: `make compile && make test`
Expected: all tests pass.

- [ ] **Step 6: Commit**

```bash
~/My\ Drive/dotfiles/claude/bin/batch-test.sh agent
git add agent-slack.el agent-todo.el test/agent-slack-test.el test/agent-todo-test.el
git commit -m "agent: turn the Slack and TODO handlers into extractors"
```

---

### Task 7: Email

**Files:**
- Create: `agent-mu4e.el`
- Create: `test/agent-mu4e-test.el`
- Modify: `agent.el` (mu4e predicate, forward declarations, autoload, `agent-at-point-things`)
- Modify: `test/agent-test.el`
- Modify: `Makefile:5-6`

**Interfaces:**
- Consumes: `agent--act-on-context` from Task 4.
- Produces: `agent-act-on-email (&optional EXISTING)`; `agent-mu4e-context (CALLBACK)`; `agent--mu4e-message-at-point-p ()`.

- [ ] **Step 1: Write the failing tests**

Create `test/agent-mu4e-test.el`:

```elisp
;;; agent-mu4e-test.el --- Tests for agent-mu4e -*- lexical-binding: t -*-

;; Tests for routing the email at point.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'agent-mu4e)

(ert-deftest agent-mu4e-test-context-carries-the-path-unsubmitted ()
  "Describe an email by its maildir path, unsubmitted and unanchored."
  (let ((context nil))
    (cl-letf (((symbol-function 'mu4e-message-field-at-point)
               (lambda (field)
                 (pcase field
                   (:path "/Mail/Inbox/cur/1786193068")
                   (:subject "Quarterly numbers")
                   (:from '(("Ada" . "ada@example.com")))))))
      (agent-mu4e-context (lambda (c) (setq context c))))
    (should (equal (plist-get context :payload) "/Mail/Inbox/cur/1786193068"))
    (should-not (plist-get context :submit))
    (should-not (plist-get context :directory))
    (should (string-match-p "Quarterly numbers" (plist-get context :text)))
    (should (string-match-p "ada@example.com" (plist-get context :text)))))

(ert-deftest agent-mu4e-test-context-without-a-path-signals ()
  "Signal a user error when the message records no path."
  (cl-letf (((symbol-function 'mu4e-message-field-at-point) (lambda (_) nil)))
    (should-error (agent-mu4e-context #'ignore) :type 'user-error)))

(provide 'agent-mu4e-test)
;;; agent-mu4e-test.el ends here
```

In `test/agent-test.el`, add to the act-on-thing section:

```elisp
(ert-deftest agent-test-extractor-at-point-finds-an-email ()
  "Route a mu4e buffer holding a message to the email extractor."
  (with-temp-buffer
    (setq major-mode 'mu4e-view-mode)
    (cl-letf (((symbol-function 'mu4e-message-at-point) (lambda (&optional _) 'msg)))
      (should (eq (agent--extractor-at-point) 'agent-mu4e-context)))))

(ert-deftest agent-test-extractor-at-point-never-consults-mu4e-elsewhere ()
  "Leave mu4e alone in buffers that cannot hold a message."
  (with-temp-buffer
    (cl-letf (((symbol-function 'mu4e-message-at-point)
               (lambda (&optional _) (error "Consulted mu4e"))))
      (should-not (agent--extractor-at-point)))))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-mu4e-test.el`
Expected: FAIL — `Cannot open load file: agent-mu4e`.

- [ ] **Step 3: Write the implementation**

Create `agent-mu4e.el`:

```elisp
;;; agent-mu4e.el --- Route email to AI sessions -*- lexical-binding: t -*-

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

;; Routes the mu4e message at point to a session by its maildir path,
;; which is what an agent needs to read the mail itself.

;;; Code:

(require 'agent)

(declare-function mu4e-message-field-at-point "mu4e-message" (field))

;;;; Commands

;;;###autoload
(defun agent-act-on-email (&optional existing)
  "Route the email at point to an AI session.
With prefix argument EXISTING send it to a running session instead of
starting one in a project chosen from the message."
  (interactive "P")
  (agent--act-on-context #'agent-mu4e-context existing))

(defun agent-mu4e-context (callback)
  "Call CALLBACK with the context for the mu4e message at point.
The payload is the maildir path, which an agent can read directly.  The
subject and sender are the text a project is chosen from."
  (let ((path (or (mu4e-message-field-at-point :path)
                  (user-error "No email at point"))))
    (funcall callback (list :text (agent-mu4e--message-text)
                            :payload path
                            :submit nil))))

(defun agent-mu4e--message-text ()
  "Return the subject and sender of the message at point."
  (format "Subject: %s\nFrom: %s"
          (or (mu4e-message-field-at-point :subject) "")
          (agent-mu4e--sender)))

(defun agent-mu4e--sender ()
  "Return the sender of the message at point as a string."
  (let ((from (mu4e-message-field-at-point :from)))
    (cond
     ((stringp from) from)
     ((consp (car from)) (format "%s <%s>" (or (caar from) "") (cdar from)))
     (t ""))))

(provide 'agent-mu4e)
;;; agent-mu4e.el ends here
```

In `agent.el`, add the forward declarations next to the Forge ones:

```elisp
(declare-function mu4e-message-at-point "mu4e-message" (&optional noerror))
```

Add the autoload next to the other extractor autoloads:

```elisp
(autoload 'agent-mu4e-context "agent-mu4e")
```

Add the predicate after `agent--forge-topic-at-point-p`:

```elisp
(defun agent--mu4e-message-at-point-p ()
  "Return non-nil when a mu4e message is at point.
Checks the major mode first, so a buffer that cannot hold a message
never calls into `mu4e'."
  (and (derived-mode-p '(mu4e-headers-mode mu4e-view-mode))
       (mu4e-message-at-point t)))
```

Add its entry to `agent-at-point-things`, after the Forge entry:

```elisp
    (agent--mu4e-message-at-point-p . agent-mu4e-context)
```

Extend the `agent-act-on-thing-at-point` docstring and its `user-error` to name email:

```elisp
       (user-error "Nothing to act on at point; expected a Slack message, an email, a Forge notification or topic, a backtrace, or an org TODO"))
```

- [ ] **Step 4: Add the new files to the Makefile and run the tests**

Append `agent-mu4e.el` to `SRC` and `test/agent-mu4e-test.el` to `TEST_FILES`, then run `make compile && make test`.
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
~/My\ Drive/dotfiles/claude/bin/batch-test.sh agent
git add agent-mu4e.el test/agent-mu4e-test.el agent.el test/agent-test.el Makefile
git commit -m "agent-mu4e: route the email at point to a session"
```

---

### Task 8: Documentation and live verification

**Files:**
- Modify: `README.org` (findex block near line 271, the act-on-thing paragraph near line 337, the module table near line 26)
- Modify: `agent.texi` (the same three places)

**Interfaces:**
- Consumes: everything above.
- Produces: no new code.

- [ ] **Step 1: Update the act-on-thing paragraph**

In `README.org`, replace the paragraph beginning "The menu binds no routing command directly." with:

```
#+findex: agent-act-on-thing-at-point
The menu binds no routing command directly. ~agent-act-on-thing-at-point~, bound to =.= in the Tools column, walks ~agent-at-point-things~ and calls the first extractor whose predicate matches the current buffer: a backtrace in a =*Backtrace*= buffer, a Slack message in a Slack room buffer, a Forge notification or topic, an email in a mu4e buffer, or an org TODO heading. Every predicate answers from the buffer alone — the buffer name, the buffer-local variable =slack= sets on room buffers, the major mode, the org TODO state — so dispatch never loads a module to ask whether it applies. When nothing matches, the command signals an error naming the five kinds it recognizes.

Without a prefix argument the thing goes to a new session; with one it goes to a running session chosen by completion. A new session needs a directory. Things that carry one use it: a Forge topic has its repository's working tree, a backtrace has its package's source directory. Things that carry only text — a Slack message, an email, an org TODO — have their project read from ~agent-project-sources~, an alist mapping an account-name regexp to a list of sources, first match winning and =""= covering an account with no entry. A source ending in =.json= is a registry, whose projects carry descriptions that =gptel= ranks against the thing's text; any other source is a path pattern, expanded one level, keeping only git repositories when it contains a wildcard and named as-is when it does not. With no descriptions among the candidates there is nothing to rank on, so no request is made.

What each kind sends differs, because the payloads differ. A Forge or Slack URL and an email's maildir path are references: they arrive unsubmitted so the request can be typed next to them. A backtrace and an org TODO are already requests, so they submit.
```

Mirror all three paragraphs into `agent.texi` with `@code{}` for symbols, `@samp{}` for literals, and `@findex` in place of `#+findex:`.

- [ ] **Step 2: Record the new modules**

In the module table near the top of `README.org` and `agent.texi`, add rows for `agent-project.el` ("Account-scoped project sources: registry and path-pattern candidates, ranking, project prompt") and `agent-mu4e.el` ("Email routing: the maildir path of the message at point").

- [ ] **Step 3: Run the full suite**

Run: `make compile && make test`
Expected: all tests pass.

- [ ] **Step 4: Verify live in the running Emacs**

```bash
emacsclient -e '(list (commandp (quote agent-act-on-email))
                      (with-temp-buffer (rename-buffer "*Backtrace*" t)
                        (agent--extractor-at-point))
                      (length (agent-project-candidates nil)))'
```
Expected: `(t agent--backtrace-context N)` with N the number of catch-all candidates. Then open a real `*mu4e-article*` buffer and run `M-x agent-act-on-email`, confirming the project prompt appears and the session opens with the maildir path in its prompt, unsubmitted.

- [ ] **Step 5: Commit**

```bash
~/My\ Drive/dotfiles/claude/bin/batch-test.sh agent
git add README.org agent.texi
git commit -m "docs: document the layers behind acting on the thing at point"
```

---

## Configuration to set after implementation

`agent-project-sources` ships with a catch-all of `~/repos/*`. Set the real value once, along with the registry root:

```elisp
(setq agent-project-registry-root "~/My Drive/Epoch/projects/")
(setq agent-project-sources
      '(("epoch"      . ("~/My Drive/Epoch/projects/shared/project-registry.json"))
        ("trajectory" . ("~/Trajectory/reasoning-tasks/*"))
        (""           . ("~/repos/*"))))
```

Claude currently has no account selected, so Claude sessions match the catch-all while Codex sessions match tlon's entry, which is the `""` entry too unless one is added for tlon.
