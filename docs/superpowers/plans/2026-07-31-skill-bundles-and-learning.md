# Skill Bundles and Reviewable Learning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `agent` named multi-skill bundles, durable provenance and
usage history for every skill invocation, a skill health check, and an
Emacs review lifecycle for agent-authored learning candidates — per
`docs/superpowers/specs/2026-07-31-skill-bundles-and-learning-design.md`.

**Architecture:** `agent.el` gains one observer hook
(`agent-skill-invocation-functions`), one function that runs it
(`agent-note-skill-invocation`), three small dispatch helpers shared by
the new modules, and `:root` in discovered skill plists.  Two new
optional modules consume that contract: `agent-skill.el` (bundles,
provenance, JSONL usage history, health check) and `agent-learn.el`
(learning-candidate inbox review).  No new `agent-backend` slot is
added; bundles dispatch through the existing `agent-submit` and
`agent-start-session`.

**Tech Stack:** Emacs Lisp 30, `tabulated-list-mode`, `special-mode`,
`json-serialize`, `transient`, ERT.

## Global Constraints

These apply to every task.  They restate the spec's non-negotiables.

- **No automatic persistent memory injection.**  Nothing in this plan
  makes a model-authored learning active by itself.  No command may
  edit `CLAUDE.md`, `AGENTS.md`, a skill file, a hook, or any other
  target artifact; no command may apply a `**Proposed patch:**`.
  Approval is a recorded decision, never an installation step.
- **No command deletes a file.**  Archiving is `rename-file` inside
  `agent-learn-directory`.  History rotation renames; it never removes.
- **Agent-authored files are preserved byte-for-byte** except for the
  `**Review:**` and `**Dispatched:**` lines this package owns.
- **No new `agent-backend` slots.**  If a task seems to need one, stop:
  the design is wrong, not the constraint.
- **Modules install nothing at load time.**  Loading `agent-skill.el` or
  `agent-learn.el` adds no hook, timer, or keymap entry.  Only
  `agent-skill-mode` (global minor mode) installs the history consumer;
  everything else happens inside a command.
- **Never guess backend facts.**  A `busy` target is refused by name;
  an `unknown` state is confirmed, never assumed idle; "dispatched"
  means the text was submitted at the session's prompt and nothing
  more.
- **Provenance is never cached.**  Git is re-read on each resolution.
- **Nothing is silently dropped.**  Unparsable history lines, skipped
  optional bundle steps, bounded file scans, and shadowed skills are
  each reported with a count or a named path.
- Defcustom defaults: `agent-skill-bundles` nil,
  `agent-skill-bundle-confirm` t, `agent-skill-record-git-provenance` t,
  `agent-skill-history-max-bytes` 5242880, `agent-learn-file-limit` 200.
- All 362 existing tests keep passing; `make compile` stays
  warning-free.
- Commit after every task with a single-purpose message.

Run tests with `make test` from the repo root; byte-compile with `make
compile`.  Both must be clean before each commit.

## Relationship to the other planned work

Neither the attention/queue plan
(`docs/superpowers/plans/2026-07-31-attention-and-queue.md`) nor the
context-composer plan
(`docs/superpowers/plans/2026-07-30-context-composer.md`) has been
implemented.  This plan does not depend on either and must not edit
either.  Three contact points:

1. **Busy policy.**  Both other plans and this one refuse to submit into
   a busy session while no queue exists.  This plan puts its version in
   one core helper, `agent-ensure-dispatch-target` (Task 6).  If the
   composer's `:ready-to-submit-p` slot has already landed when Task 6
   runs, make `agent-ensure-dispatch-target` consult it and keep the
   same user-visible behaviour; do not add the slot yourself.
2. **`agent-menu` columns.**  This plan adds `b`, `u`, `k` to Tools and
   `L` to Prompts.  The composer adds `C` to Prompts; attention adds an
   entry to Sessions.  No key collides.  Whichever lands second adds
   only its own entries.
3. **Step-at-a-time dispatch** is explicitly deferred to the queue
   project (spec §2).  Do not build a submit-and-wait driver here.

## Deliberate deviations from the spec

Each is a decision made while planning; do not "fix" it back.

1. **`agent-note-skill-invocation` uses `run-hook-wrapped`, not a
   `dolist`.**  The spec says consumers run inside `condition-case`;
   `run-hook-wrapped` gives that while still honouring buffer-local hook
   values and the `t` element convention.
2. **Records carry `:path`; `:source` is resolved by the recorder.**
   The spec's §3 table now says this, but the plan states it again
   because it is the reason `agent.el` needs no git code: core reports
   the path it already has, and `agent-skill.el` turns it into
   provenance only when it is actually recording.
3. **The bundle preview buffer uses `special-mode`, not `org-mode`.**
   Other informational buffers in this package use `org-mode`, but this
   one shows the exact outgoing bytes and must not fontify `*text*` as
   Org emphasis.
4. **`agent-learn` sorts inbox files by name descending, then mtime
   descending.**  Names begin with `YYYY-MM-DD`, and mtime alone would
   reorder a file the moment this package writes a `**Review:**` line
   into it.
5. **A candidate whose `**Review:**` line names an unrecognized state
   parses as state `other` and is shown verbatim.**  Refusing to parse
   would hide a hand-edited file; guessing would misreport it.
6. **`agent-learn` refuses to write to a file with unsaved changes in a
   live buffer**, naming the file, instead of saving the user's edits as
   a side effect of approving something.

---

### Task 1: Core invocation records

**Files:**
- Modify: `agent.el` — new hook and function near the skill section
  (before `agent--skill-argument-candidates`, ~line 1798); `:root` in
  `agent-discover-skills` (~line 2117); emitters in `agent--run-skill`
  (~line 2046), `agent--audit-run-next` (~line 2294), and
  `agent--before-exit-submit-next` (~line 1665).
- Test: `test/agent-test.el`

**Interfaces:**
- Consumes: nothing new.
- Produces:
  - `agent-skill-invocation-functions` — abnormal hook, each function
    called with one plist.
  - `agent-note-skill-invocation (PLIST)` → the delivered plist, with
    `:id` (string) and `:time` (float) filled in when absent.
  - `agent-discover-skills` return plists additionally carry
    `:root` (directory string).

- [ ] **Step 1: Write the failing tests**

Append to `test/agent-test.el`, before the final `provide`:

```elisp
;;;; Skill invocation records

(ert-deftest agent-test-note-skill-invocation-fills-id-and-time ()
  "Fill `:id' and `:time' and deliver the record to every consumer."
  (let* ((seen nil)
         (agent-skill-invocation-functions
          (list (lambda (record) (push record seen)))))
    (let ((delivered (agent-note-skill-invocation
                      (list :skill "demo" :origin 'run-skill))))
      (should (stringp (plist-get delivered :id)))
      (should (floatp (plist-get delivered :time)))
      (should (equal (list delivered) seen)))))

(ert-deftest agent-test-note-skill-invocation-keeps-supplied-id ()
  "Never overwrite an `:id' the caller supplied."
  (let ((agent-skill-invocation-functions nil))
    (should (equal "fixed"
                   (plist-get (agent-note-skill-invocation
                               (list :id "fixed" :skill "demo"
                                     :origin 'bundle))
                              :id)))))

(ert-deftest agent-test-note-skill-invocation-survives-a-signal ()
  "A signalling consumer warns and does not stop later consumers."
  (let* ((seen nil)
         (warned nil)
         (agent-skill-invocation-functions
          (list (lambda (_record) (error "boom"))
                (lambda (record) (push record seen)))))
    (cl-letf (((symbol-function 'display-warning)
               (lambda (&rest args) (push args warned))))
      (agent-note-skill-invocation (list :skill "demo" :origin 'audit)))
    (should (= 1 (length seen)))
    (should warned)))

(ert-deftest agent-test-run-skill-notes-dispatch-and-outcome ()
  "Emit a dispatched record and a correlated outcome record."
  (let* ((agent-backends nil)
         (records nil)
         (agent-skill-invocation-functions
          (list (lambda (record) (push record records)))))
    (apply #'agent-register-backend
           'stub
           (agent-test--backend
            :run-prompt
            (cl-function
             (lambda (_prompt &key directory callback)
               (ignore directory)
               (funcall callback "output" :error nil)))))
    (cl-letf (((symbol-function 'agent--display-skill-result)
               (lambda (&rest _) nil)))
      (agent--run-skill 'stub
                        (list :name "demo" :style 'file
                              :path "/skills/demo/SKILL.md")
                        "--accept"))
    (setq records (nreverse records))
    (should (= 2 (length records)))
    (should (eq 'run-skill (plist-get (nth 0 records) :origin)))
    (should (eq 'batch (plist-get (nth 0 records) :mode)))
    (should (equal "--accept" (plist-get (nth 0 records) :args)))
    (should (equal "/skills/demo/SKILL.md" (plist-get (nth 0 records) :path)))
    (should (eq 'dispatched (plist-get (nth 0 records) :outcome)))
    (should (eq 'ok (plist-get (nth 1 records) :outcome)))
    (should (equal (plist-get (nth 0 records) :id)
                   (plist-get (nth 1 records) :id)))))

(ert-deftest agent-test-run-skill-notes-error-outcome ()
  "Report a failing batch run as an `error' outcome carrying the message."
  (let* ((agent-backends nil)
         (records nil)
         (agent-skill-invocation-functions
          (list (lambda (record) (push record records)))))
    (apply #'agent-register-backend
           'stub
           (agent-test--backend
            :run-prompt
            (cl-function
             (lambda (_prompt &key directory callback)
               (ignore directory)
               (funcall callback nil :error "exit 1")))))
    (cl-letf (((symbol-function 'agent--display-skill-result)
               (lambda (&rest _) nil)))
      (agent--run-skill 'stub (list :name "demo" :style 'file) nil))
    (let ((outcome (car records)))
      (should (eq 'error (plist-get outcome :outcome)))
      (should (equal "exit 1" (plist-get outcome :error))))))

(ert-deftest agent-test-discover-skills-records-root ()
  "Every discovered skill names the root it came from."
  (let* ((agent-backends nil)
         (root (make-temp-file "agent-skill-root" t))
         (dir (expand-file-name "demo" root)))
    (unwind-protect
        (progn
          (make-directory dir)
          (with-temp-file (expand-file-name "SKILL.md" dir)
            (insert "---\nname: demo\ndescription: Demo skill\n---\n"))
          (apply #'agent-register-backend
                 'stub
                 (agent-test--backend
                  :skill-roots (lambda () (list (cons root 'file)))))
          (let ((skill (car (agent-discover-skills 'stub))))
            (should (equal "demo" (plist-get skill :name)))
            (should (equal root (plist-get skill :root)))))
      (delete-directory root t))))
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `make test 2>&1 | tail -30`
Expected: failures naming `agent-note-skill-invocation` as a void
function and `:root` as nil.

- [ ] **Step 3: Add the hook and the recorder**

In `agent.el`, immediately before `agent--skill-argument-candidates`:

```elisp
;;;; Skill invocation records

(defcustom agent-skill-invocation-functions nil
  "Abnormal hook run with one plist each time a skill is invoked.
The plist describes a single invocation and always carries `:skill'
\(name string), `:origin' (`run-skill', `bundle', `audit', or
`before-exit'), `:id' and `:time'.  It may also carry `:mode'
\(`session' or `batch'), `:backend', `:args', `:buffer', `:directory',
`:path' (the skill file), `:source' (a resolved provenance plist),
`:bundle' with `:step' and `:steps', `:outcome' (`dispatched', `ok',
or `error') and `:error'.

Consumers are observers: they must not submit session input, and their
return values are ignored.  A consumer that signals is reported with
`display-warning' and does not disturb the dispatch that produced the
record.  `agent-skill.el' subscribes to this hook to write the durable
usage history."
  :type 'hook
  :group 'agent)

(defun agent--skill-invocation-id ()
  "Return a fresh skill-invocation id string."
  (format "%s-%04x%04x"
          (format-time-string "%Y%m%dT%H%M%S")
          (random (expt 2 16))
          (random (expt 2 16))))

(defun agent-note-skill-invocation (plist)
  "Run `agent-skill-invocation-functions' with the completed PLIST.
Fill `:id' and `:time' when PLIST omits them, and return the plist
actually delivered so a caller can correlate a later outcome record
with the same `:id'.  Each consumer runs inside `condition-case'."
  (let ((record (copy-sequence plist)))
    (unless (plist-get record :id)
      (setq record (plist-put record :id (agent--skill-invocation-id))))
    (unless (plist-get record :time)
      (setq record (plist-put record :time (float-time))))
    (run-hook-wrapped
     'agent-skill-invocation-functions
     (lambda (fn payload)
       (condition-case err
           (funcall fn payload)
         (error
          (display-warning
           'agent
           (format "skill invocation consumer %S signaled: %S" fn err)
           :warning)))
       nil)
     record)
    record))
```

- [ ] **Step 4: Record the discovery root**

In `agent-discover-skills`, change the `puthash` call:

```elisp
              (puthash name
                       (append meta (list :path file :style style :root dir))
                       skills)
```

and extend its docstring's first sentence:

```elisp
  "Discover all skills for BACKEND from its registered skill roots.
Return a list of skill plists with :name, :description, :path,
:style, :root, and the argument metadata recognized by
`agent-parse-skill-frontmatter'.  Later roots shadow earlier ones."
```

- [ ] **Step 5: Emit from `agent--run-skill`**

Replace `agent--run-skill` with:

```elisp
(defun agent--run-skill (backend skill arguments)
  "Run SKILL plist with ARGUMENTS through BACKEND's run-prompt slot."
  (let* ((run (or (when-let* ((struct (agent-backend backend)))
                    (agent-backend-run-prompt struct))
                  (user-error "Backend `%s' does not register run-prompt"
                              backend)))
         (name (plist-get skill :name))
         (facts (list :skill name :origin 'run-skill :mode 'batch
                      :backend backend :args arguments
                      :path (plist-get skill :path)
                      :directory default-directory))
         (record (agent-note-skill-invocation
                  (append facts (list :outcome 'dispatched)))))
    (message "Running skill %s..." name)
    (funcall run (agent--skill-prompt skill arguments)
             :directory default-directory
             :callback
             (cl-function
              (lambda (text &key error)
                (agent-note-skill-invocation
                 (append (list :id (plist-get record :id))
                         facts
                         (list :outcome (if error 'error 'ok)
                               :error error)))
                (agent--display-skill-result name text error))))))
```

- [ ] **Step 6: Emit from the audit runner**

In `agent--audit-run-next`, after the `run` binding and before the
`message` call, add a `facts`/`record` pair and emit the outcome inside
the callback:

```elisp
           (facts (list :skill name :origin 'audit :mode 'batch
                        :backend backend :args "--accept"
                        :path (plist-get skill :path)
                        :directory (plist-get state :dir)))
           (record (agent-note-skill-invocation
                    (append facts (list :outcome 'dispatched)))))
      (message "Running audit %s..." name)
      (funcall run (agent--skill-prompt skill "--accept")
               :directory (plist-get state :dir)
               :callback
               (cl-function
                (lambda (text &key error)
                  (agent-note-skill-invocation
                   (append (list :id (plist-get record :id))
                           facts
                           (list :outcome (if error 'error 'ok)
                                 :error error)))
                  (plist-put state :results
                             (cons (list :skill name :text text :error error)
                                   (plist-get state :results)))
                  (plist-put state :queue (cdr queue))
                  (unless error
                    (ignore-errors
                      (agent--audit-commit-changes (plist-get state :dir) name)))
                  (agent--audit-run-next state))))))))
```

- [ ] **Step 7: Emit from the before-exit chain**

In `agent--before-exit-submit-next`, after the successful
`(agent-submit command buffer)`:

```elisp
        (when command
          (agent-submit command buffer)
          (agent-note-skill-invocation
           (list :skill (agent--before-exit-skill-entry-name entry)
                 :origin 'before-exit :mode 'session
                 :backend backend
                 :args (agent--before-exit-skill-entry-args entry)
                 :buffer buffer
                 :directory (agent--buffer-directory backend buffer)
                 :outcome 'dispatched))
          (message "Started %s; this session will close when the before-exit skills finish"
                   command)
          (setq sent t))
```

- [ ] **Step 8: Run the tests**

Run: `make test 2>&1 | tail -10`
Expected: all tests pass, count up by 6.

Run: `make compile`
Expected: no output beyond the compile banner; no warnings.

- [ ] **Step 9: Commit**

```bash
git add agent.el test/agent-test.el
git commit -m "agent: report every skill invocation on a public hook"
```

---

### Task 2: Provenance resolution (`agent-skill.el`)

**Files:**
- Create: `agent-skill.el`
- Create: `test/agent-skill-test.el`
- Modify: `Makefile` (add the module to `SRC` and the test to
  `TEST_FILES`)

**Interfaces:**
- Consumes: `agent-discover-skills` plists (`:name`, `:path`, `:style`,
  `:root`).
- Produces:
  - `agent-skill-provenance (SKILL)` → plist `(:path :root :style
    :content-sha1 :repo :commit :dirty)`.
  - `agent-skill-record-git-provenance` — defcustom boolean, default t.

- [ ] **Step 1: Write the failing tests**

Create `test/agent-skill-test.el`:

```elisp
;;; agent-skill-test.el --- Tests for agent-skill -*- lexical-binding: t -*-

;; Tests for bundles, provenance, usage history, and health checks.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'agent)
(require 'agent-skill)

(defun agent-skill-test--stub-git (responses)
  "Return a `process-file' replacement answering from RESPONSES.
RESPONSES is an alist mapping an argument list to (EXIT . OUTPUT)."
  (lambda (program &optional _infile destination _display &rest args)
    (unless (equal program "git")
      (error "Unexpected program %s" program))
    (let ((entry (assoc args responses)))
      (if (null entry)
          128
        (let ((dest (if (consp destination) (car destination) destination)))
          (when (or (eq dest t) (bufferp dest))
            (with-current-buffer (if (bufferp dest) dest (current-buffer))
              (insert (cddr entry)))))
        (cadr entry)))))

(defmacro agent-skill-test--with-skill (var &rest body)
  "Bind VAR to a temporary skill plist and run BODY, then clean up."
  (declare (indent 1))
  `(let* ((root (make-temp-file "agent-skill-root" t))
          (dir (expand-file-name "demo" root))
          (path (expand-file-name "SKILL.md" dir)))
     (unwind-protect
         (progn
           (make-directory dir)
           (with-temp-file path
             (insert "---\nname: demo\ndescription: Demo\n---\nBody\n"))
           (let ((,var (list :name "demo" :path path :style 'file
                             :root root)))
             ,@body))
       (delete-directory root t))))

;;;; Provenance

(ert-deftest agent-skill-test-provenance-hashes-the-file ()
  "Report the SKILL.md content hash, path, root, and style."
  (agent-skill-test--with-skill skill
    (let* ((agent-skill-record-git-provenance nil)
           (prov (agent-skill-provenance skill)))
      (should (equal (plist-get skill :path) (plist-get prov :path)))
      (should (equal (plist-get skill :root) (plist-get prov :root)))
      (should (eq 'file (plist-get prov :style)))
      (should (equal (with-temp-buffer
                       (insert-file-contents-literally
                        (plist-get skill :path))
                       (secure-hash 'sha1 (buffer-string)))
                     (plist-get prov :content-sha1)))
      (should-not (plist-member prov :commit)))))

(ert-deftest agent-skill-test-provenance-reads-git ()
  "Report repository, commit, and a clean worktree."
  (agent-skill-test--with-skill skill
    (let ((agent-skill-record-git-provenance t))
      (cl-letf (((symbol-function 'process-file)
                 (agent-skill-test--stub-git
                  `((("rev-parse" "--show-toplevel") . (0 . "/repo\n"))
                    (("rev-parse" "HEAD") . (0 . "abc123\n"))
                    (("status" "--porcelain" "--"
                      ,(plist-get skill :path)) . (0 . ""))))))
        (let ((prov (agent-skill-provenance skill)))
          (should (equal "/repo/" (plist-get prov :repo)))
          (should (equal "abc123" (plist-get prov :commit)))
          (should-not (plist-get prov :dirty)))))))

(ert-deftest agent-skill-test-provenance-reports-dirty ()
  "Set `:dirty' when git reports uncommitted changes to the skill file."
  (agent-skill-test--with-skill skill
    (let ((agent-skill-record-git-provenance t))
      (cl-letf (((symbol-function 'process-file)
                 (agent-skill-test--stub-git
                  `((("rev-parse" "--show-toplevel") . (0 . "/repo\n"))
                    (("rev-parse" "HEAD") . (0 . "abc123\n"))
                    (("status" "--porcelain" "--"
                      ,(plist-get skill :path))
                     . (0 . " M claude/skills/demo/SKILL.md\n"))))))
        (should (plist-get (agent-skill-provenance skill) :dirty))))))

(ert-deftest agent-skill-test-provenance-outside-a-repository ()
  "Report nil repository and commit without signaling."
  (agent-skill-test--with-skill skill
    (let ((agent-skill-record-git-provenance t))
      (cl-letf (((symbol-function 'process-file)
                 (agent-skill-test--stub-git nil)))
        (let ((prov (agent-skill-provenance skill)))
          (should-not (plist-get prov :repo))
          (should-not (plist-get prov :commit))
          (should-not (plist-get prov :dirty)))))))

(ert-deftest agent-skill-test-provenance-of-a-missing-file ()
  "Report a nil content hash rather than signaling."
  (let ((agent-skill-record-git-provenance nil))
    (should-not (plist-get (agent-skill-provenance
                            (list :name "gone" :path "/nowhere/SKILL.md"))
                           :content-sha1))))

(provide 'agent-skill-test)
;;; agent-skill-test.el ends here
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `emacs --batch --eval '(dolist (dir (file-expand-wildcards "'"$HOME"'/.config/emacs-profiles/8.3.0-dev/elpaca/builds/*/")) (add-to-list (quote load-path) dir))' --eval '(push default-directory load-path)' -l test/agent-skill-test.el -f ert-run-tests-batch-and-exit`
Expected: it fails to load — `Cannot open load file: agent-skill`.

- [ ] **Step 3: Create the module with provenance**

Create `agent-skill.el`:

```elisp
;;; agent-skill.el --- Skill bundles, provenance, and history -*- lexical-binding: t -*-

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

;; Named bundles of skills, provenance for the instructions a session
;; was given, a durable usage history, and a health check over the
;; discovered skill set.  Loading this file installs nothing; the
;; global minor mode `agent-skill-mode' owns the history consumer and
;; every other entry point is a command.

;;; Code:

(require 'agent)
(require 'cl-lib)
(require 'subr-x)

;;;; Customization

(defgroup agent-skill ()
  "Skill bundles, provenance, and usage history."
  :group 'agent)

(defcustom agent-skill-record-git-provenance t
  "When non-nil, resolve the git repository, commit, and dirty flag of skills.
Set to nil on slow filesystems or non-git skill trees; provenance then
records the path, root, style, and content hash only."
  :type 'boolean
  :group 'agent-skill)

;;;; Provenance

(defun agent-skill--file-sha1 (path)
  "Return the SHA-1 of PATH's bytes, or nil when it cannot be read."
  (when (and path (file-readable-p path))
    (with-temp-buffer
      (insert-file-contents-literally path)
      (secure-hash 'sha1 (buffer-string)))))

(defun agent-skill--git-output (&rest args)
  "Return the trimmed output of git ARGS, or nil.
Return nil when git exits non-zero or prints nothing, so a caller
cannot mistake a failure for an answer."
  (with-temp-buffer
    (let ((exit (apply #'process-file "git" nil t nil args)))
      (when (eq exit 0)
        (let ((output (string-trim (buffer-string))))
          (unless (string-empty-p output) output))))))

(defun agent-skill--git-provenance (path)
  "Return the git provenance plist for skill file PATH."
  (let* ((default-directory (file-name-directory path))
         (repo (agent-skill--git-output "rev-parse" "--show-toplevel")))
    (if (not repo)
        (list :repo nil :commit nil :dirty nil)
      (list :repo (file-name-as-directory repo)
            :commit (agent-skill--git-output "rev-parse" "HEAD")
            :dirty (and (agent-skill--git-output
                         "status" "--porcelain" "--" path)
                        t)))))

(defun agent-skill-provenance (skill)
  "Return the provenance plist for SKILL.
SKILL is a plist from `agent-discover-skills'.  The result carries
`:path', `:root', `:style', `:content-sha1' and, unless
`agent-skill-record-git-provenance' is nil or the file is unreadable,
`:repo', `:commit' and `:dirty'.

The content hash is the authoritative record of which instructions were
in force.  The commit locates them in history, and `:dirty' says the
commit alone does not describe the file.  Other files in the skill's
directory are covered by the commit when the repository is clean and by
`:dirty' when it is not; they are not hashed individually.

Git is re-read on every call: stale provenance would be worse than
none."
  (let* ((path (plist-get skill :path))
         (base (list :path path
                     :root (plist-get skill :root)
                     :style (plist-get skill :style)
                     :content-sha1 (agent-skill--file-sha1 path))))
    (if (and agent-skill-record-git-provenance
             path
             (file-readable-p path))
        (append base (agent-skill--git-provenance path))
      base)))

;;;; Provide

(provide 'agent-skill)
;;; agent-skill.el ends here
```

- [ ] **Step 4: Add the module to the Makefile**

In `Makefile`, extend the two lists:

```make
SRC := agent.el agent-account.el agent-capture.el agent-slack.el agent-snippet.el agent-claude-cli.el agent-claude.el agent-codex.el agent-chief.el agent-skill.el
TEST_FILES := test/agent-test.el test/agent-account-test.el test/agent-capture-test.el test/agent-slack-test.el test/agent-snippet-test.el test/agent-claude-cli-test.el test/agent-claude-test.el test/agent-codex-test.el test/agent-chief-test.el test/agent-skill-test.el
```

- [ ] **Step 5: Run the tests**

Run: `make test 2>&1 | tail -10`
Expected: all pass, including the five new provenance tests.

Run: `make compile`
Expected: no warnings.

- [ ] **Step 6: Commit**

```bash
git add agent-skill.el test/agent-skill-test.el Makefile
git commit -m "agent-skill: resolve provenance for a discovered skill"
```

---

### Task 3: Usage history

**Files:**
- Modify: `agent-skill.el`
- Modify: `test/agent-skill-test.el`

**Interfaces:**
- Consumes: `agent-skill-invocation-functions` (Task 1),
  `agent-skill-provenance` (Task 2).
- Produces:
  - `agent-skill-history-file`, `agent-skill-history-max-bytes` —
    defcustoms.
  - `agent-skill-mode` — global minor mode owning the consumer.
  - `agent-skill-history-read (&optional LIMIT)` → plist
    `(:records LIST :unparsable INT :total INT)`, records newest first.

- [ ] **Step 1: Write the failing tests**

Append to `test/agent-skill-test.el`, before the `provide`:

```elisp
;;;; History

(defmacro agent-skill-test--with-history (&rest body)
  "Run BODY with a temporary history file."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "agent-skill-history" t))
          (agent-skill-history-file (expand-file-name "history.jsonl" dir))
          (agent-skill-history-max-bytes 5242880)
          (agent-skill-record-git-provenance nil))
     (unwind-protect (progn ,@body)
       (delete-directory dir t))))

(ert-deftest agent-skill-test-history-round-trips-a-record ()
  "Append a record and read it back with its fields intact."
  (agent-skill-test--with-history
    (agent-skill--record (list :id "one" :time 1.0 :skill "demo"
                               :origin 'bundle :mode 'session
                               :backend 'claude-code :bundle "review-pr"
                               :step 1 :steps 2 :outcome 'dispatched))
    (let* ((read (agent-skill-history-read))
           (record (car (plist-get read :records))))
      (should (= 1 (plist-get read :total)))
      (should (zerop (plist-get read :unparsable)))
      (should (equal "demo" (alist-get 'skill record)))
      (should (equal "bundle" (alist-get 'origin record)))
      (should (equal "review-pr" (alist-get 'bundle record)))
      (should (equal 1 (alist-get 'step record))))))

(ert-deftest agent-skill-test-history-is-newest-first-and-limited ()
  "Return the most recent records first, honoring LIMIT."
  (agent-skill-test--with-history
    (dotimes (i 5)
      (agent-skill--record (list :id (number-to-string i) :time (float i)
                                 :skill (format "s%d" i) :origin 'run-skill)))
    (let ((records (plist-get (agent-skill-history-read 2) :records)))
      (should (equal '("s4" "s3")
                     (mapcar (lambda (r) (alist-get 'skill r)) records))))))

(ert-deftest agent-skill-test-history-counts-unparsable-lines ()
  "Skip a corrupt line and report it instead of failing."
  (agent-skill-test--with-history
    (agent-skill--record (list :id "one" :skill "demo" :origin 'run-skill))
    (write-region "not json\n" nil agent-skill-history-file t 'no-message)
    (let ((read (agent-skill-history-read)))
      (should (= 1 (plist-get read :total)))
      (should (= 1 (plist-get read :unparsable))))))

(ert-deftest agent-skill-test-history-rotates-at-the-size-limit ()
  "Move the oversized file aside and keep appending to a fresh one."
  (agent-skill-test--with-history
    (let ((agent-skill-history-max-bytes 10))
      (agent-skill--record (list :id "one" :skill "demo" :origin 'run-skill))
      (agent-skill--record (list :id "two" :skill "demo" :origin 'run-skill))
      (should (file-exists-p (concat agent-skill-history-file ".1")))
      (should (= 1 (plist-get (agent-skill-history-read) :total))))))

(ert-deftest agent-skill-test-history-missing-file-is-empty ()
  "Report an empty history rather than signaling."
  (agent-skill-test--with-history
    (let ((read (agent-skill-history-read)))
      (should (null (plist-get read :records)))
      (should (zerop (plist-get read :total))))))

(ert-deftest agent-skill-test-history-resolves-provenance-from-path ()
  "Fill `source' from `:path' when the emitter supplied no provenance."
  (agent-skill-test--with-history
    (agent-skill-test--with-skill skill
      (agent-skill--record (list :id "one" :skill "demo" :origin 'run-skill
                                 :path (plist-get skill :path)))
      (let* ((record (car (plist-get (agent-skill-history-read) :records)))
             (source (alist-get 'source record)))
        (should (stringp (alist-get 'content_sha1 source)))))))

(ert-deftest agent-skill-test-mode-owns-the-consumer ()
  "Install the consumer on enable and remove it on disable."
  (let ((agent-skill-invocation-functions nil))
    (agent-skill-mode 1)
    (should (memq #'agent-skill--record agent-skill-invocation-functions))
    (agent-skill-mode -1)
    (should-not (memq #'agent-skill--record
                      agent-skill-invocation-functions))))
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `make test 2>&1 | tail -20`
Expected: `agent-skill--record` and `agent-skill-history-read` are void.

- [ ] **Step 3: Implement the writer**

Add to `agent-skill.el` after the provenance section:

```elisp
;;;; Usage history

(defcustom agent-skill-history-file
  (expand-file-name "agent/skill-history.jsonl" user-emacs-directory)
  "Append-only JSON Lines file recording every skill invocation.
Written only while `agent-skill-mode' is enabled."
  :type 'file
  :group 'agent-skill)

(defcustom agent-skill-history-max-bytes 5242880
  "Size at which `agent-skill-history-file' is rolled over.
The oversized file is renamed with a `.1' suffix, replacing any
previous one.  Set to nil to never roll over."
  :type '(choice (const :tag "Never" nil) integer)
  :group 'agent-skill)

(defun agent-skill--json-value (value)
  "Return VALUE in a form `json-serialize' accepts."
  (cond
   ((null value) :null)
   ((eq value t) t)
   ((keywordp value) (substring (symbol-name value) 1))
   ((symbolp value) (symbol-name value))
   ((or (stringp value) (numberp value)) value)
   ((bufferp value) (buffer-name value))
   (t (format "%S" value))))

(defun agent-skill--json-plist (plist keys)
  "Return an alist of KEYS taken from PLIST, JSON-ready.
KEYS is a list of (JSON-NAME . PLIST-KEY) conses."
  (mapcar (lambda (pair)
            (cons (car pair)
                  (agent-skill--json-value (plist-get plist (cdr pair)))))
          keys))

(defconst agent-skill--source-json-keys
  '((path . :path) (root . :root) (style . :style)
    (content_sha1 . :content-sha1) (repo . :repo)
    (commit . :commit) (dirty . :dirty))
  "JSON field names for a provenance plist.")

(defun agent-skill--session-json (buffer)
  "Return the JSON session identity of session BUFFER, or `:null'."
  (if-let* (((buffer-live-p buffer))
            (session (agent-session buffer)))
      (list (cons 'backend (agent-skill--json-value
                            (agent-session-backend session)))
            (cons 'directory (agent-skill--json-value
                              (agent-session-directory session)))
            (cons 'instance (agent-skill--json-value
                             (agent-session-instance session)))
            (cons 'account (agent-skill--json-value
                            (agent-session-account session)))
            (cons 'id (agent-skill--json-value (agent-session-id session))))
    :null))

(defun agent-skill--record-source (record)
  "Return RECORD's provenance plist, resolving it from `:path' when absent."
  (or (plist-get record :source)
      (when-let* ((path (plist-get record :path)))
        (agent-skill-provenance (list :path path
                                      :root (plist-get record :root)
                                      :style (plist-get record :style))))))

(defun agent-skill--record-json (record)
  "Return RECORD as a JSON-ready alist."
  (let ((source (agent-skill--record-source record)))
    (append
     (list (cons 'time (format-time-string
                        "%FT%T%z"
                        (seconds-to-time (or (plist-get record :time)
                                             (float-time))))))
     (agent-skill--json-plist
      record
      '((id . :id) (skill . :skill) (origin . :origin) (mode . :mode)
        (backend . :backend) (args . :args) (bundle . :bundle)
        (step . :step) (steps . :steps) (directory . :directory)
        (outcome . :outcome) (error . :error)))
     (list (cons 'session (agent-skill--session-json
                           (plist-get record :buffer)))
           (cons 'source (if source
                             (agent-skill--json-plist
                              source agent-skill--source-json-keys)
                           :null))))))

(defun agent-skill--rotate-history ()
  "Roll `agent-skill-history-file' over when it exceeds its size limit."
  (when (and agent-skill-history-max-bytes
             (file-exists-p agent-skill-history-file)
             (> (or (file-attribute-size
                     (file-attributes agent-skill-history-file))
                    0)
                agent-skill-history-max-bytes))
    (rename-file agent-skill-history-file
                 (concat agent-skill-history-file ".1")
                 t)))

(defun agent-skill--record (record)
  "Append RECORD to `agent-skill-history-file'.
Member of `agent-skill-invocation-functions' while `agent-skill-mode'
is enabled."
  (make-directory (file-name-directory agent-skill-history-file) t)
  (agent-skill--rotate-history)
  (write-region (concat (json-serialize (agent-skill--record-json record))
                        "\n")
                nil agent-skill-history-file t 'no-message))

;;;###autoload
(define-minor-mode agent-skill-mode
  "Record every skill invocation to `agent-skill-history-file'.
Bundles, provenance, and the health check work without this mode; only
the durable history depends on it."
  :global t
  :group 'agent-skill
  (if agent-skill-mode
      (add-hook 'agent-skill-invocation-functions #'agent-skill--record)
    (remove-hook 'agent-skill-invocation-functions #'agent-skill--record)))
```

- [ ] **Step 4: Implement the reader**

Append to the same section:

```elisp
(defun agent-skill-history-read (&optional limit)
  "Return recorded invocations, newest first.
LIMIT bounds how many are returned.  The result is a plist with
`:records' (alists as stored), `:total' (records returned), and
`:unparsable' (lines skipped because they were not valid JSON).  A
missing history file yields an empty result, not an error."
  (let ((records nil)
        (unparsable 0))
    (when (file-readable-p agent-skill-history-file)
      (with-temp-buffer
        (insert-file-contents agent-skill-history-file)
        (goto-char (point-max))
        (while (and (or (null limit) (< (length records) limit))
                    (> (point) (point-min)))
          (forward-line -1)
          (let ((line (string-trim
                       (buffer-substring-no-properties
                        (point) (line-end-position)))))
            (unless (string-empty-p line)
              (condition-case nil
                  (push (json-parse-string line
                                           :object-type 'alist
                                           :null-object nil
                                           :false-object nil)
                        records)
                (error (setq unparsable (1+ unparsable)))))))))
    (list :records (nreverse records)
          :total (length records)
          :unparsable unparsable)))
```

Note the `nreverse`: lines are visited bottom-up and pushed, so the
list is oldest-first before reversing — reversing restores newest-first.

- [ ] **Step 5: Run the tests**

Run: `make test 2>&1 | tail -10`
Expected: all pass.

Run: `make compile`
Expected: no warnings.

- [ ] **Step 6: Commit**

```bash
git add agent-skill.el test/agent-skill-test.el
git commit -m "agent-skill: record skill invocations to a durable history"
```

---

### Task 4: Bundle definition and resolution

**Files:**
- Modify: `agent-skill.el`
- Modify: `test/agent-skill-test.el`

**Interfaces:**
- Consumes: `agent-discover-skills`, `agent-skill-provenance`.
- Produces:
  - `agent-skill-bundles` — defcustom alist.
  - `agent-skill-bundle (NAME)` → plist; `user-error` when unknown.
  - `agent-skill-resolve-bundle (NAME BACKEND)` → list of step plists
    `(:name :args :optional :skill :source :skipped)`, in bundle order.

- [ ] **Step 1: Write the failing tests**

Append to `test/agent-skill-test.el`:

```elisp
;;;; Bundles

(defmacro agent-skill-test--with-skills (skills &rest body)
  "Run BODY with `agent-discover-skills' returning SKILLS."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'agent-discover-skills)
              (lambda (_backend) ,skills)))
     ,@body))

(defconst agent-skill-test--skills
  (list (list :name "pr-audit" :path "/s/pr-audit/SKILL.md"
              :style 'slash :root "/s")
        (list :name "code-audit" :path "/s/code-audit/SKILL.md"
              :style 'slash :root "/s"))
  "Two discoverable skills for bundle tests.")

(ert-deftest agent-skill-test-resolve-bundle-in-order ()
  "Resolve every step, in order, with its arguments."
  (let ((agent-skill-bundles
         '(("review-pr" :description "Review a PR"
            :skills ("pr-audit" ("code-audit" :args "--accept")))))
        (agent-skill-record-git-provenance nil))
    (agent-skill-test--with-skills agent-skill-test--skills
      (let ((steps (agent-skill-resolve-bundle "review-pr" 'claude-code)))
        (should (equal '("pr-audit" "code-audit")
                       (mapcar (lambda (s) (plist-get s :name)) steps)))
        (should-not (plist-get (nth 0 steps) :args))
        (should (equal "--accept" (plist-get (nth 1 steps) :args)))
        (should (equal "/s/pr-audit/SKILL.md"
                       (plist-get (plist-get (nth 0 steps) :source) :path)))))))

(ert-deftest agent-skill-test-resolve-bundle-refuses-a-missing-skill ()
  "Abort when a required step names a skill the backend cannot discover."
  (let ((agent-skill-bundles '(("x" :skills ("nope")))))
    (agent-skill-test--with-skills agent-skill-test--skills
      (should-error (agent-skill-resolve-bundle "x" 'claude-code)
                    :type 'user-error))))

(ert-deftest agent-skill-test-resolve-bundle-skips-an-optional-skill ()
  "Keep an optional missing step as a skipped entry."
  (let ((agent-skill-bundles
         '(("x" :skills ("pr-audit" ("nope" :optional t)))))
        (agent-skill-record-git-provenance nil))
    (agent-skill-test--with-skills agent-skill-test--skills
      (let ((steps (agent-skill-resolve-bundle "x" 'claude-code)))
        (should (= 2 (length steps)))
        (should-not (plist-get (nth 0 steps) :skipped))
        (should (stringp (plist-get (nth 1 steps) :skipped)))))))

(ert-deftest agent-skill-test-resolve-bundle-checks-the-backend ()
  "Refuse a bundle restricted to other backends."
  (let ((agent-skill-bundles
         '(("x" :skills ("pr-audit") :backends (codex)))))
    (agent-skill-test--with-skills agent-skill-test--skills
      (should-error (agent-skill-resolve-bundle "x" 'claude-code)
                    :type 'user-error))))

(ert-deftest agent-skill-test-bundle-rejects-a-malformed-entry ()
  "Refuse an entry that is neither a string nor a name-and-plist list."
  (let ((agent-skill-bundles '(("x" :skills (42)))))
    (agent-skill-test--with-skills agent-skill-test--skills
      (should-error (agent-skill-resolve-bundle "x" 'claude-code)
                    :type 'user-error))))

(ert-deftest agent-skill-test-bundle-rejects-an-unknown-name ()
  "Name the bundle that does not exist."
  (let ((agent-skill-bundles nil))
    (should-error (agent-skill-bundle "nope") :type 'user-error)))
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `make test 2>&1 | tail -20`
Expected: `agent-skill-resolve-bundle` is void.

- [ ] **Step 3: Implement bundles**

Add to `agent-skill.el` after the history section:

```elisp
;;;; Bundles

(defcustom agent-skill-bundles nil
  "Named ordered groups of skills dispatched into one session.
Each entry is (NAME . PLIST) where NAME is a string and PLIST accepts:

  `:description'  string shown when choosing a bundle.
  `:skills'       ordered list.  Each element is a skill-name string,
                  or a list whose car is the name and whose cdr is a
                  plist accepting `:args' (a string passed to that
                  skill) and `:optional' (non-nil to skip the step,
                  with a note, when the skill is not discoverable).
  `:instruction'  prose prepended to the dispatched message.
  `:backends'     list of backend symbols the bundle applies to; nil
                  means any registered backend.

A bundle is dispatched as one message naming every skill file in
order, so it behaves identically on both backends.  Native `/name'
expansion is available through `agent-run-skill' instead.

Example:

  \\='((\"review-pr\"
      :description \"Audit a branch before opening a PR\"
      :instruction \"Work on the current branch only.\"
      :skills (\"pr-audit\" (\"code-audit\" :args \"--accept\")))))"
  :type '(alist :key-type string :value-type plist)
  :group 'agent-skill)

(defun agent-skill-bundle (name)
  "Return the bundle plist named NAME, or signal a `user-error'."
  (or (cdr (assoc name agent-skill-bundles))
      (user-error "No skill bundle named `%s'" name)))

(defun agent-skill-bundle-names ()
  "Return the names of every configured bundle."
  (mapcar #'car agent-skill-bundles))

(defun agent-skill--bundle-entry (entry bundle-name)
  "Return ENTRY of bundle BUNDLE-NAME as a (NAME . PLIST) cons.
Signal a `user-error' when ENTRY has no recognized shape."
  (cond
   ((stringp entry) (cons entry nil))
   ((and (consp entry) (stringp (car entry)) (listp (cdr entry)))
    (cons (car entry) (cdr entry)))
   (t (user-error "Bundle `%s' has a malformed skill entry: %S"
                  bundle-name entry))))

(defun agent-skill--bundle-backend-ok-p (bundle backend)
  "Return non-nil when BUNDLE applies to BACKEND."
  (let ((backends (plist-get bundle :backends)))
    (or (null backends) (memq backend backends))))

(defun agent-skill-resolve-bundle (name backend)
  "Resolve bundle NAME against the skills BACKEND can discover.
Return an ordered list of step plists carrying `:name', `:args',
`:optional', `:skill' (the discovered plist), `:source' (provenance)
and, for an optional step whose skill is missing, `:skipped' (a reason
string).  Signal a `user-error' when the bundle does not apply to
BACKEND, when an entry is malformed, or when a required skill is not
discoverable — a bundle that runs half of itself is worse than one
that refuses."
  (let ((bundle (agent-skill-bundle name)))
    (unless (agent-skill--bundle-backend-ok-p bundle backend)
      (user-error "Bundle `%s' does not apply to backend `%s'" name backend))
    (let ((available (agent-discover-skills backend)))
      (mapcar
       (lambda (entry)
         (let* ((parsed (agent-skill--bundle-entry entry name))
                (skill-name (car parsed))
                (options (cdr parsed))
                (skill (cl-find skill-name available
                                :key (lambda (s) (plist-get s :name))
                                :test #'equal)))
           (cond
            (skill
             (list :name skill-name
                   :args (plist-get options :args)
                   :optional (plist-get options :optional)
                   :skill skill
                   :source (agent-skill-provenance skill)))
            ((plist-get options :optional)
             (list :name skill-name
                   :args (plist-get options :args)
                   :optional t
                   :skipped (format "not discoverable for backend `%s'"
                                    backend)))
            (t (user-error "Bundle `%s' needs skill `%s', which backend `%s' \
does not provide"
                           name skill-name backend)))))
       (plist-get bundle :skills)))))

(defun agent-skill--bundle-steps (steps)
  "Return the STEPS that will actually be dispatched."
  (cl-remove-if (lambda (step) (plist-get step :skipped)) steps))
```

- [ ] **Step 4: Run the tests**

Run: `make test 2>&1 | tail -10`
Expected: all pass.

Run: `make compile`
Expected: no warnings.

- [ ] **Step 5: Commit**

```bash
git add agent-skill.el test/agent-skill-test.el
git commit -m "agent-skill: define and resolve named skill bundles"
```

---

### Task 5: The bundle message renderer

**Files:**
- Modify: `agent-skill.el`
- Modify: `test/agent-skill-test.el`

**Interfaces:**
- Consumes: `agent-skill-resolve-bundle` step plists.
- Produces: `agent-skill-bundle-message (NAME STEPS)` → string.  Pure:
  it reads no state beyond `agent-skill-bundles` for the instruction.

- [ ] **Step 1: Write the failing fixture tests**

Append to `test/agent-skill-test.el`:

```elisp
;;;; Rendering

(ert-deftest agent-skill-test-bundle-message-fixture ()
  "Render the exact message for a two-step bundle with an instruction."
  (let ((agent-skill-bundles
         '(("review-pr" :instruction "Work on the current branch only."
            :skills ("pr-audit" ("code-audit" :args "--accept")))))
        (steps (list (list :name "pr-audit"
                           :skill (list :path "/s/pr-audit/SKILL.md"))
                     (list :name "code-audit" :args "--accept"
                           :skill (list :path "/s/code-audit/SKILL.md")))))
    (should (equal
             (concat
              "Work on the current branch only.\n"
              "\n"
              "Run these skills in order.  Do not skip a step and do not reorder them.\n"
              "\n"
              "1. `pr-audit` — /s/pr-audit/SKILL.md\n"
              "2. `code-audit` — /s/code-audit/SKILL.md\n"
              "   Arguments: --accept\n"
              "\n"
              "Read each skill file before starting that step and follow its\n"
              "instructions exactly.  Resolve relative paths mentioned by a skill\n"
              "relative to that skill file's directory.\n"
              "\n"
              "Bundle: review-pr")
             (agent-skill-bundle-message "review-pr" steps)))))

(ert-deftest agent-skill-test-bundle-message-without-instruction ()
  "Omit the instruction paragraph when the bundle sets none."
  (let ((agent-skill-bundles '(("solo" :skills ("pr-audit"))))
        (steps (list (list :name "pr-audit"
                           :skill (list :path "/s/pr-audit/SKILL.md")))))
    (should (string-prefix-p
             "Run these skills in order."
             (agent-skill-bundle-message "solo" steps)))))

(ert-deftest agent-skill-test-bundle-message-omits-skipped-steps ()
  "Number only the steps that are dispatched."
  (let ((agent-skill-bundles '(("x" :skills ("a" "b"))))
        (steps (list (list :name "a" :skipped "not discoverable")
                     (list :name "b"
                           :skill (list :path "/s/b/SKILL.md")))))
    (let ((message (agent-skill-bundle-message "x" steps)))
      (should (string-match-p "^1\\. `b`" message))
      (should-not (string-match-p "`a`" message)))))

(ert-deftest agent-skill-test-bundle-message-refuses-an-empty-bundle ()
  "Signal rather than dispatch a message with no steps."
  (let ((agent-skill-bundles '(("x" :skills ("a")))))
    (should-error (agent-skill-bundle-message
                   "x" (list (list :name "a" :skipped "missing")))
                  :type 'user-error)))
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `make test 2>&1 | tail -20`
Expected: `agent-skill-bundle-message` is void.

- [ ] **Step 3: Implement the renderer**

Add to `agent-skill.el` after the bundle section:

```elisp
;;;; Rendering

(defconst agent-skill--bundle-preamble
  "Run these skills in order.  Do not skip a step and do not reorder them."
  "Sentence introducing the numbered steps of a dispatched bundle.")

(defconst agent-skill--bundle-postamble
  "Read each skill file before starting that step and follow its
instructions exactly.  Resolve relative paths mentioned by a skill
relative to that skill file's directory."
  "Sentences closing a dispatched bundle message.")

(defun agent-skill--bundle-step-lines (step index)
  "Return the rendered lines for STEP at one-based INDEX."
  (concat (format "%d. `%s` — %s"
                  index
                  (plist-get step :name)
                  (plist-get (plist-get step :skill) :path))
          (if-let* ((args (plist-get step :args)))
              (format "\n   Arguments: %s" args)
            "")))

(defun agent-skill-bundle-message (name steps)
  "Return the message dispatching bundle NAME's resolved STEPS.
Skipped steps are omitted.  The result is a pure function of NAME, the
bundle's `:instruction', and STEPS, so it is safe to show as a preview
of exactly what will be sent.  Signal a `user-error' when no step
remains."
  (let* ((bundle (agent-skill-bundle name))
         (live (agent-skill--bundle-steps steps))
         (instruction (plist-get bundle :instruction))
         (index 0))
    (unless live
      (user-error "Bundle `%s' has no step left to run" name))
    (string-join
     (delq nil
           (list (and instruction (not (string-empty-p instruction))
                      (string-trim instruction))
                 agent-skill--bundle-preamble
                 (string-join
                  (mapcar (lambda (step)
                            (setq index (1+ index))
                            (agent-skill--bundle-step-lines step index))
                          live)
                  "\n")
                 agent-skill--bundle-postamble
                 (format "Bundle: %s" name)))
     "\n\n")))
```

- [ ] **Step 4: Run the tests**

Run: `make test 2>&1 | tail -10`
Expected: all pass, including the byte-compared fixture.

Run: `make compile`
Expected: no warnings.

- [ ] **Step 5: Commit**

```bash
git add agent-skill.el test/agent-skill-test.el
git commit -m "agent-skill: render a bundle as one deterministic message"
```

---

### Task 6: Dispatch helpers and `agent-skill-run-bundle`

**Files:**
- Modify: `agent.el` (three helpers, in the "Core send wrappers"
  section after `agent--session-candidate-label`, ~line 1533)
- Modify: `agent-skill.el`
- Modify: `test/agent-test.el`, `test/agent-skill-test.el`

**Interfaces:**
- Consumes: `agent-submit`, `agent-start-session`,
  `agent-session-display-state`, `agent-account-resolve`,
  `agent-skill-bundle-message`, `agent-note-skill-invocation`.
- Produces (in `agent.el`, for reuse by Task 13):
  - `agent-ensure-dispatch-target (BUFFER)` → BUFFER; `user-error` when
    busy; confirms when `unknown`.
  - `agent-read-dispatch-target (&optional PROMPT)` → a live session
    buffer or the symbol `new`.
  - `agent-dispatch-prompt (TEXT TARGET &key backend directory)` → the
    session buffer the text was submitted to.
- Produces (in `agent-skill.el`):
  - `agent-skill-run-bundle (&optional NAME)` — autoloaded command.
  - `agent-skill-describe-session (&optional BUFFER)` — autoloaded
    command.
  - `agent-skill-bundle-confirm` — defcustom boolean, default t.

- [ ] **Step 1: Write the failing core tests**

Append to `test/agent-test.el`:

```elisp
;;;; Dispatch helpers

(ert-deftest agent-test-ensure-dispatch-target-refuses-a-busy-session ()
  "Name the busy state instead of submitting into a running turn."
  (with-temp-buffer
    (let ((buffer (current-buffer)))
      (cl-letf (((symbol-function 'agent-session-display-state)
                 (lambda (&rest _) 'busy))
                ((symbol-function 'agent-display-name)
                 (lambda (&rest _) "demo")))
        (should-error (agent-ensure-dispatch-target buffer)
                      :type 'user-error)))))

(ert-deftest agent-test-ensure-dispatch-target-confirms-unknown ()
  "Ask before sending to a session whose state is unknown."
  (with-temp-buffer
    (let ((buffer (current-buffer))
          (asked nil))
      (cl-letf (((symbol-function 'agent-session-display-state)
                 (lambda (&rest _) 'unknown))
                ((symbol-function 'agent-display-name)
                 (lambda (&rest _) "demo"))
                ((symbol-function 'yes-or-no-p)
                 (lambda (_prompt) (setq asked t) nil)))
        (should-error (agent-ensure-dispatch-target buffer)
                      :type 'user-error)
        (should asked)))))

(ert-deftest agent-test-ensure-dispatch-target-accepts-a-waiting-session ()
  "Return the buffer when the session is waiting for input."
  (with-temp-buffer
    (let ((buffer (current-buffer)))
      (cl-letf (((symbol-function 'agent-session-display-state)
                 (lambda (&rest _) 'waiting)))
        (should (eq buffer (agent-ensure-dispatch-target buffer)))))))

(ert-deftest agent-test-dispatch-prompt-starts-a-new-session ()
  "Pass the text as the new session's initial prompt."
  (let ((seen nil))
    (cl-letf (((symbol-function 'agent--resolve-backend) (lambda () 'stub))
              ((symbol-function 'agent-account-resolve) (lambda (&rest _) nil))
              ((symbol-function 'agent-start-session)
               (cl-function
                (lambda (session &key initial-prompt &allow-other-keys)
                  (setq seen (cons session initial-prompt))
                  (current-buffer)))))
      (agent-dispatch-prompt "hello" 'new :directory "/tmp/")
      (should (equal "hello" (cdr seen)))
      (should (equal "/tmp/" (agent-session-directory (car seen)))))))

(ert-deftest agent-test-dispatch-prompt-submits-to-a-live-session ()
  "Submit into an existing session after the readiness check."
  (with-temp-buffer
    (let ((buffer (current-buffer))
          (sent nil))
      (cl-letf (((symbol-function 'agent-session-display-state)
                 (lambda (&rest _) 'waiting))
                ((symbol-function 'agent-submit)
                 (lambda (text buf) (setq sent (cons text buf)))))
        (should (eq buffer (agent-dispatch-prompt "hello" buffer)))
        (should (equal (cons "hello" buffer) sent))))))
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `make test 2>&1 | tail -20`
Expected: the three helpers are void functions.

- [ ] **Step 3: Implement the core helpers**

Add to `agent.el` at the end of the "Core send wrappers" section:

```elisp
(defun agent-ensure-dispatch-target (buffer)
  "Return BUFFER after checking it can accept a submitted prompt now.
Signal a `user-error' when the session is busy, naming the state: no
queue exists, so a submission mid-turn would land wherever the CLI
happens to put it.  An `unknown' state is confirmed explicitly rather
than assumed idle.  Waiting states proceed."
  (unless (buffer-live-p buffer)
    (user-error "That session buffer is gone"))
  (pcase (agent-session-display-state buffer)
    ('busy
     (user-error "%s is busy; wait for the current turn to finish"
                 (agent-display-name buffer)))
    ('unknown
     (unless (yes-or-no-p
              (format "State of %s is unknown; send anyway? "
                      (agent-display-name buffer)))
       (user-error "Aborted")))
    (_ nil))
  buffer)

(defun agent-read-dispatch-target (&optional prompt)
  "Read a dispatch target: a live session buffer or the symbol `new'.
PROMPT overrides the completion prompt."
  (let* ((buffers (agent--find-all-buffers))
         (new-label "New session…")
         (candidates
          (cons new-label
                (mapcar (lambda (buf)
                          (propertize (agent--session-candidate-label buf)
                                      'agent-buffer buf))
                        buffers)))
         (choice (completing-read (or prompt "Send to: ") candidates nil t)))
    (if (equal choice new-label)
        'new
      (or (get-text-property 0 'agent-buffer choice)
          (get-text-property
           0 'agent-buffer
           (cl-find choice candidates :test #'string=))
          (user-error "No session matches `%s'" choice)))))

(cl-defun agent-dispatch-prompt (text target &key backend directory)
  "Send TEXT to TARGET and return the session buffer it went to.
TARGET is a live session buffer or the symbol `new'.  An existing
target passes `agent-ensure-dispatch-target' first.  A new session is
started with BACKEND (prompted for when nil) in DIRECTORY (the current
project root or `default-directory' when nil), with TEXT as its initial
prompt.

As everywhere in this package, a successful return means the text was
submitted at the session's prompt; terminal transports can attest
nothing further."
  (if (eq target 'new)
      (let* ((backend (or backend (agent--resolve-backend)))
             (directory (or directory
                            (when-let* ((project (project-current)))
                              (project-root project))
                            default-directory)))
        (agent-start-session
         (agent-session-create
          :backend backend
          :account (agent-account-resolve backend t)
          :directory directory)
         :initial-prompt text))
    (agent-ensure-dispatch-target target)
    (agent-submit text target)
    target))
```

`project-current` and `project-root` are already used in this file's
backend adapters; add `(require 'project)` to the top-level requires if
byte-compilation warns.

- [ ] **Step 4: Write the failing bundle-dispatch tests**

Append to `test/agent-skill-test.el`:

```elisp
;;;; Dispatch

(defmacro agent-skill-test--dispatching (sent &rest body)
  "Run BODY capturing dispatches into SENT as (TEXT . TARGET) conses."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'agent-dispatch-prompt)
              (lambda (text target &rest _)
                (push (cons text target) ,sent)
                (if (bufferp target) target (current-buffer)))))
     ,@body))

(ert-deftest agent-skill-test-run-bundle-dispatches-and-records ()
  "Send the rendered message once and record one entry per step."
  (let* ((agent-skill-bundles
          '(("review-pr" :skills ("pr-audit" ("code-audit" :args "-a")))))
         (agent-skill-record-git-provenance nil)
         (agent-skill-bundle-confirm nil)
         (records nil)
         (agent-skill-invocation-functions
          (list (lambda (record) (push record records))))
         (sent nil))
    (agent-skill-test--with-skills agent-skill-test--skills
      (agent-skill-test--dispatching sent
        (with-temp-buffer
          (cl-letf (((symbol-function 'agent--resolve-backend)
                     (lambda () 'claude-code))
                    ((symbol-function 'agent-read-dispatch-target)
                     (lambda (&rest _) 'new))
                    ((symbol-function 'y-or-n-p) (lambda (_prompt) t)))
            (agent-skill-run-bundle "review-pr")))))
    (should (= 1 (length sent)))
    (should (string-match-p "1\\. `pr-audit`" (car (car sent))))
    (setq records (nreverse records))
    (should (= 2 (length records)))
    (should (equal "review-pr" (plist-get (nth 0 records) :bundle)))
    (should (= 1 (plist-get (nth 0 records) :step)))
    (should (= 2 (plist-get (nth 0 records) :steps)))
    (should (eq 'bundle (plist-get (nth 1 records) :origin)))
    (should (eq 'session (plist-get (nth 1 records) :mode)))))

(ert-deftest agent-skill-test-run-bundle-aborts-without-confirmation ()
  "Send nothing and record nothing when the preview is declined."
  (let* ((agent-skill-bundles '(("x" :skills ("pr-audit"))))
         (agent-skill-record-git-provenance nil)
         (agent-skill-bundle-confirm t)
         (records nil)
         (agent-skill-invocation-functions
          (list (lambda (record) (push record records))))
         (sent nil))
    (agent-skill-test--with-skills agent-skill-test--skills
      (agent-skill-test--dispatching sent
        (cl-letf (((symbol-function 'agent--resolve-backend)
                   (lambda () 'claude-code))
                  ((symbol-function 'agent-read-dispatch-target)
                   (lambda (&rest _) 'new))
                  ((symbol-function 'y-or-n-p) (lambda (_prompt) nil)))
          (should-error (agent-skill-run-bundle "x") :type 'user-error))))
    (should-not sent)
    (should-not records)))

(ert-deftest agent-skill-test-run-bundle-records-nothing-when-submit-fails ()
  "Leave no record behind when the dispatch itself signals."
  (let* ((agent-skill-bundles '(("x" :skills ("pr-audit"))))
         (agent-skill-record-git-provenance nil)
         (agent-skill-bundle-confirm nil)
         (records nil)
         (agent-skill-invocation-functions
          (list (lambda (record) (push record records)))))
    (agent-skill-test--with-skills agent-skill-test--skills
      (cl-letf (((symbol-function 'agent--resolve-backend)
                 (lambda () 'claude-code))
                ((symbol-function 'agent-read-dispatch-target)
                 (lambda (&rest _) 'new))
                ((symbol-function 'agent-dispatch-prompt)
                 (lambda (&rest _) (user-error "no session"))))
        (should-error (agent-skill-run-bundle "x") :type 'user-error)))
    (should-not records)))

(ert-deftest agent-skill-test-describe-session-lists-applied-skills ()
  "Report the bundle steps dispatched into a session buffer."
  (let ((agent-skill-bundles '(("x" :skills ("pr-audit"))))
        (agent-skill-record-git-provenance nil)
        (agent-skill-bundle-confirm nil))
    (with-temp-buffer
      (let ((session (current-buffer)))
        (agent-skill-test--with-skills agent-skill-test--skills
          (cl-letf (((symbol-function 'agent--resolve-backend)
                     (lambda () 'claude-code))
                    ((symbol-function 'agent-read-dispatch-target)
                     (lambda (&rest _) session))
                    ((symbol-function 'agent-dispatch-prompt)
                     (lambda (_text target &rest _) target)))
            (agent-skill-run-bundle "x")))
        (should (= 1 (length (buffer-local-value 'agent-skill--applied
                                                 session))))))))
```

- [ ] **Step 5: Implement the bundle command**

Add to `agent-skill.el` after the rendering section:

```elisp
;;;; Dispatch

(defcustom agent-skill-bundle-confirm t
  "When non-nil, preview a bundle in a buffer and confirm before sending.
With a nil value the preview buffer is skipped and the dispatch is
confirmed in the minibuffer."
  :type 'boolean
  :group 'agent-skill)

(defvar-local agent-skill--applied nil
  "Invocation records for skills dispatched into this session buffer.
Newest last.  This dies with the buffer by design; the durable copy is
`agent-skill-history-file'.")

(defun agent-skill--read-bundle-name ()
  "Read a bundle name with completion, annotated with its description."
  (let* ((names (agent-skill-bundle-names))
         (_ (unless names
              (user-error "No bundles configured; see `agent-skill-bundles'")))
         (annotate
          (lambda (name)
            (let* ((bundle (cdr (assoc name agent-skill-bundles)))
                   (count (length (plist-get bundle :skills)))
                   (description (or (plist-get bundle :description) "")))
              (concat "  " (propertize (format "%d skill%s  %s"
                                               count (if (= count 1) "" "s")
                                               description)
                                       'face 'completions-annotations))))))
    (completing-read
     "Bundle: "
     (lambda (str pred action)
       (if (eq action 'metadata)
           `(metadata (annotation-function . ,annotate))
         (complete-with-action action names str pred)))
     nil t)))

(defun agent-skill--source-summary (source)
  "Return a one-line description of provenance SOURCE."
  (cond
   ((null source) "no provenance")
   ((plist-get source :commit)
    (format "%s%s"
            (substring (plist-get source :commit) 0
                       (min 8 (length (plist-get source :commit))))
            (if (plist-get source :dirty) " (uncommitted changes)" "")))
   (t "not in a git repository")))

(defun agent-skill--preview (name steps target message)
  "Show the bundle NAME preview for STEPS going to TARGET with MESSAGE.
Return the preview buffer."
  (let ((buffer (get-buffer-create (format "*Agent bundle: %s*" name))))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Bundle:  %s\n" name))
        (insert (format "Target:  %s\n"
                        (if (bufferp target)
                            (agent-display-name target)
                          "new session")))
        (insert "\nSteps:\n")
        (dolist (step steps)
          (insert (format "  %s %s\n"
                          (if (plist-get step :skipped) "skip" " run")
                          (plist-get step :name)))
          (if-let* ((reason (plist-get step :skipped)))
              (insert (format "       %s\n" reason))
            (insert (format "       %s\n       %s\n"
                            (plist-get (plist-get step :source) :path)
                            (agent-skill--source-summary
                             (plist-get step :source))))))
        (insert "\nMessage to send:\n\n")
        (insert message)
        (insert "\n"))
      (special-mode)
      (goto-char (point-min)))
    (display-buffer buffer)
    buffer))

(defun agent-skill--note-steps (name steps buffer backend)
  "Record one invocation per live step of bundle NAME.
STEPS are the resolved steps, BUFFER the session they were sent to and
BACKEND its backend.  Also push each record onto BUFFER's
`agent-skill--applied'."
  (let* ((live (agent-skill--bundle-steps steps))
         (total (length live))
         (index 0))
    (dolist (step live)
      (setq index (1+ index))
      (let ((record (agent-note-skill-invocation
                     (list :skill (plist-get step :name)
                           :origin 'bundle :mode 'session
                           :backend backend
                           :bundle name :step index :steps total
                           :args (plist-get step :args)
                           :buffer buffer
                           :directory (when (buffer-live-p buffer)
                                        (buffer-local-value 'default-directory
                                                            buffer))
                           :path (plist-get (plist-get step :source) :path)
                           :source (plist-get step :source)
                           :outcome 'dispatched))))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (setq agent-skill--applied
                  (append agent-skill--applied (list record)))))))))

;;;###autoload
(defun agent-skill-run-bundle (&optional name)
  "Dispatch the skills of bundle NAME into one session.
Read NAME and a target when they are not supplied, resolve every step
against the target backend, show what will be sent, and submit it as a
single message.  Nothing is sent and nothing is recorded unless every
step resolves and the dispatch succeeds."
  (interactive)
  (let* ((name (or name (agent-skill--read-bundle-name)))
         (target (agent-read-dispatch-target
                  (format "Run bundle `%s' in: " name)))
         (backend (if (bufferp target)
                      (agent--detect-backend target)
                    (agent--resolve-backend)))
         (steps (agent-skill-resolve-bundle name backend))
         (message-text (agent-skill-bundle-message name steps))
         (preview (when agent-skill-bundle-confirm
                    (agent-skill--preview name steps target message-text))))
    (unwind-protect
        (unless (y-or-n-p (format "Send bundle `%s' (%d skill%s)? "
                                  name
                                  (length (agent-skill--bundle-steps steps))
                                  (if (= 1 (length (agent-skill--bundle-steps
                                                    steps)))
                                      "" "s")))
          (user-error "Aborted"))
      (when (buffer-live-p preview)
        (quit-windows-on preview t)))
    (let ((buffer (agent-dispatch-prompt message-text target
                                         :backend backend)))
      (agent-skill--note-steps name steps buffer backend)
      (message "Dispatched bundle %s (%d skill%s) to %s"
               name
               (length (agent-skill--bundle-steps steps))
               (if (= 1 (length (agent-skill--bundle-steps steps))) "" "s")
               (if (buffer-live-p buffer)
                   (agent-display-name buffer)
                 "the new session"))
      buffer)))

;;;###autoload
(defun agent-skill-describe-session (&optional buffer)
  "Show which skills were dispatched into session BUFFER, and from where."
  (interactive)
  (let* ((session (agent--resolve-session-buffer buffer))
         (records (buffer-local-value 'agent-skill--applied session))
         (report (get-buffer-create "*Agent session skills*")))
    (with-current-buffer report
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Skills dispatched into %s\n\n"
                        (agent-display-name session)))
        (if (null records)
            (insert "None recorded in this Emacs session.\n")
          (dolist (record records)
            (let ((source (plist-get record :source)))
              (insert (format "%s  %s%s\n"
                              (format-time-string
                               "%F %T"
                               (seconds-to-time (plist-get record :time)))
                              (plist-get record :skill)
                              (if-let* ((bundle (plist-get record :bundle)))
                                  (format "  [%s %d/%d]" bundle
                                          (plist-get record :step)
                                          (plist-get record :steps))
                                "")))
              (insert (format "    %s\n    %s\n"
                              (or (plist-get source :path) "unknown path")
                              (agent-skill--source-summary source)))))))
      (special-mode)
      (goto-char (point-min)))
    (pop-to-buffer report)))
```

- [ ] **Step 6: Run the tests**

Run: `make test 2>&1 | tail -10`
Expected: all pass.

Run: `make compile`
Expected: no warnings.

- [ ] **Step 7: Commit**

```bash
git add agent.el agent-skill.el test/agent-test.el test/agent-skill-test.el
git commit -m "agent-skill: dispatch a bundle into one session with provenance"
```

---

### Task 7: The usage-history buffer

**Files:**
- Modify: `agent-skill.el`
- Modify: `test/agent-skill-test.el`

**Interfaces:**
- Consumes: `agent-skill-history-read`.
- Produces: `agent-skill-history` — autoloaded command;
  `agent-skill-history-mode`; `agent-skill-history-limit` defcustom
  (default 200).

- [ ] **Step 1: Write the failing tests**

Append to `test/agent-skill-test.el`:

```elisp
;;;; History buffer

(ert-deftest agent-skill-test-history-rows-render-every-column ()
  "Build one tabulated row per record, with an abbreviated commit."
  (let* ((record '((time . "2026-07-31T10:00:00+0200")
                   (origin . "bundle") (bundle . "review-pr")
                   (skill . "pr-audit") (backend . "claude-code")
                   (mode . "session") (outcome . "dispatched")
                   (source . ((commit . "abc1234567") (dirty . t)))))
         (row (cadr (agent-skill--history-row record))))
    (should (equal "pr-audit" (aref row 3)))
    (should (equal "abc12345*" (aref row 6)))))

(ert-deftest agent-skill-test-history-header-reports-what-was-read ()
  "State how many records were read and how many lines were unparsable."
  (should (string-match-p
           "2 records.*1 unparsable"
           (agent-skill--history-header (list :total 2 :unparsable 1)))))
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `make test 2>&1 | tail -20`
Expected: `agent-skill--history-row` is void.

- [ ] **Step 3: Implement the buffer**

Add to `agent-skill.el`:

```elisp
;;;; History buffer

(defcustom agent-skill-history-limit 200
  "How many history records `agent-skill-history' reads."
  :type 'integer
  :group 'agent-skill)

(defun agent-skill--history-commit (source)
  "Return the abbreviated commit of SOURCE, with `*' when dirty."
  (let ((commit (alist-get 'commit source)))
    (if (not (stringp commit))
        ""
      (concat (substring commit 0 (min 8 (length commit)))
              (if (alist-get 'dirty source) "*" "")))))

(defun agent-skill--history-row (record)
  "Return the tabulated-list entry for history RECORD."
  (let ((source (alist-get 'source record)))
    (list record
          (vector (or (alist-get 'time record) "")
                  (or (alist-get 'origin record) "")
                  (or (alist-get 'bundle record) "")
                  (or (alist-get 'skill record) "")
                  (or (alist-get 'backend record) "")
                  (or (alist-get 'mode record) "")
                  (agent-skill--history-commit source)
                  (or (alist-get 'outcome record) "")))))

(defun agent-skill--history-header (read)
  "Return the header line describing a READ result."
  (format "%d records%s%s"
          (plist-get read :total)
          (if (zerop (plist-get read :unparsable))
              ""
            (format ", %d unparsable line%s skipped"
                    (plist-get read :unparsable)
                    (if (= 1 (plist-get read :unparsable)) "" "s")))
          (if agent-skill-mode "" "  (agent-skill-mode is off)")))

(defvar-keymap agent-skill-history-mode-map
  :doc "Keymap for `agent-skill-history-mode'."
  "RET" #'agent-skill-history-show
  "g" #'agent-skill-history-refresh)

(define-derived-mode agent-skill-history-mode tabulated-list-mode
  "Agent skill history"
  "Major mode listing recorded skill invocations."
  (setq tabulated-list-format
        [("Time" 21 t) ("Origin" 11 t) ("Bundle" 12 t) ("Skill" 22 t)
         ("Backend" 12 t) ("Mode" 8 t) ("Commit" 10 nil)
         ("Outcome" 10 t)])
  (tabulated-list-init-header))

(defun agent-skill-history-refresh ()
  "Re-read the history file into the current buffer."
  (interactive nil agent-skill-history-mode)
  (let ((read (agent-skill-history-read agent-skill-history-limit)))
    (setq tabulated-list-entries
          (mapcar #'agent-skill--history-row (plist-get read :records)))
    (setq header-line-format (agent-skill--history-header read))
    (tabulated-list-print t)))

(defun agent-skill-history-show ()
  "Show the full record at point."
  (interactive nil agent-skill-history-mode)
  (let ((record (tabulated-list-get-id))
        (buffer (get-buffer-create "*Agent skill record*")))
    (unless record (user-error "No record at point"))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (pp record (current-buffer)))
      (special-mode)
      (goto-char (point-min)))
    (pop-to-buffer buffer)))

;;;###autoload
(defun agent-skill-history ()
  "List recorded skill invocations, newest first."
  (interactive)
  (let ((buffer (get-buffer-create "*Agent skill history*")))
    (with-current-buffer buffer
      (agent-skill-history-mode)
      (agent-skill-history-refresh))
    (pop-to-buffer buffer)))
```

- [ ] **Step 4: Run the tests**

Run: `make test 2>&1 | tail -10`
Expected: all pass.

Run: `make compile`
Expected: no warnings.

- [ ] **Step 5: Commit**

```bash
git add agent-skill.el test/agent-skill-test.el
git commit -m "agent-skill: list recorded skill invocations"
```

---

### Task 8: The health check

**Files:**
- Modify: `agent-skill.el`
- Modify: `test/agent-skill-test.el`

**Interfaces:**
- Consumes: `agent-backends`, `agent-backend-skill-roots`,
  `agent-parse-skill-frontmatter`, `agent-skill-bundles`.
- Produces:
  - `agent-skill-check-issues ()` → list of plists `(:severity :backend
    :skill :issue :detail)`.
  - `agent-skill-check` — autoloaded command;
    `agent-skill-check-mode`.

- [ ] **Step 1: Write the failing tests**

Append to `test/agent-skill-test.el`:

```elisp
;;;; Health check

(defmacro agent-skill-test--with-roots (roots &rest body)
  "Register a stub backend whose skill roots are ROOTS and run BODY."
  (declare (indent 1))
  `(let ((agent-backends nil))
     (apply #'agent-register-backend
            'stub
            (list :buffer-p (lambda (_b) nil)
                  :find-all-buffers (lambda () nil)
                  :start-session #'ignore
                  :label "Stub"
                  :skill-roots (lambda () ,roots)))
     ,@body))

(defun agent-skill-test--make-skill (root name body)
  "Write a SKILL.md named NAME under ROOT with BODY as its frontmatter."
  (let ((dir (expand-file-name name root)))
    (make-directory dir t)
    (with-temp-file (expand-file-name "SKILL.md" dir) (insert body))
    dir))

(ert-deftest agent-skill-test-check-reports-unparsable-frontmatter ()
  "Report a SKILL.md whose frontmatter names no skill."
  (let ((root (make-temp-file "agent-skill-check" t)))
    (unwind-protect
        (progn
          (agent-skill-test--make-skill root "broken" "no frontmatter\n")
          (agent-skill-test--with-roots (list (cons root 'file))
            (let ((issues (agent-skill-check-issues)))
              (should (cl-find-if
                       (lambda (issue)
                         (and (eq 'error (plist-get issue :severity))
                              (string-match-p "frontmatter"
                                              (plist-get issue :issue))))
                       issues)))))
      (delete-directory root t))))

(ert-deftest agent-skill-test-check-reports-shadowing ()
  "Name the winner and the shadowed path when two roots share a name."
  (let ((first (make-temp-file "agent-skill-a" t))
        (second (make-temp-file "agent-skill-b" t)))
    (unwind-protect
        (progn
          (agent-skill-test--make-skill
           first "demo" "---\nname: demo\ndescription: One\n---\n")
          (agent-skill-test--make-skill
           second "demo" "---\nname: demo\ndescription: Two\n---\n")
          (agent-skill-test--with-roots (list (cons first 'file)
                                              (cons second 'file))
            (let ((issue (cl-find-if
                          (lambda (i) (string-match-p "shadow"
                                                      (plist-get i :issue)))
                          (agent-skill-check-issues))))
              (should issue)
              (should (eq 'warning (plist-get issue :severity)))
              (should (string-match-p (regexp-quote first)
                                      (plist-get issue :detail))))))
      (delete-directory first t)
      (delete-directory second t))))

(ert-deftest agent-skill-test-check-reports-a-name-mismatch ()
  "Warn when the frontmatter name differs from the directory name."
  (let ((root (make-temp-file "agent-skill-check" t)))
    (unwind-protect
        (progn
          (agent-skill-test--make-skill
           root "folder" "---\nname: other\ndescription: X\n---\n")
          (agent-skill-test--with-roots (list (cons root 'file))
            (should (cl-find-if
                     (lambda (i) (string-match-p "directory"
                                                 (plist-get i :issue)))
                     (agent-skill-check-issues)))))
      (delete-directory root t))))

(ert-deftest agent-skill-test-check-reports-a-missing-description ()
  "Warn about a skill with no description."
  (let ((root (make-temp-file "agent-skill-check" t)))
    (unwind-protect
        (progn
          (agent-skill-test--make-skill root "demo" "---\nname: demo\n---\n")
          (agent-skill-test--with-roots (list (cons root 'file))
            (should (cl-find-if
                     (lambda (i) (string-match-p "description"
                                                 (plist-get i :issue)))
                     (agent-skill-check-issues)))))
      (delete-directory root t))))

(ert-deftest agent-skill-test-check-reports-an-unknown-bundle-skill ()
  "Report a bundle step no backend can provide."
  (let ((root (make-temp-file "agent-skill-check" t))
        (agent-skill-bundles '(("x" :skills ("absent")))))
    (unwind-protect
        (agent-skill-test--with-roots (list (cons root 'file))
          (should (cl-find-if
                   (lambda (i)
                     (and (eq 'error (plist-get i :severity))
                          (string-match-p "bundle" (plist-get i :issue))))
                   (agent-skill-check-issues))))
      (delete-directory root t))))
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `make test 2>&1 | tail -20`
Expected: `agent-skill-check-issues` is void.

- [ ] **Step 3: Implement the checks**

Add to `agent-skill.el`:

```elisp
;;;; Health check

(defun agent-skill--root-files (backend)
  "Return (ROOT STYLE PATH META) for every SKILL.md under BACKEND's roots.
Roots are returned in discovery order, so a later entry for the same
name shadows an earlier one, exactly as `agent-discover-skills'
resolves it.  META is nil when the frontmatter could not be parsed."
  (let ((roots-fn (when-let* ((struct (agent-backend backend)))
                    (agent-backend-skill-roots struct)))
        (result nil))
    (dolist (root (and roots-fn (funcall roots-fn)))
      (let ((dir (car root))
            (style (cdr root)))
        (when (file-directory-p dir)
          (dolist (path (file-expand-wildcards
                         (expand-file-name "*/SKILL.md" dir)))
            (push (list dir style path
                        (ignore-errors (agent-parse-skill-frontmatter path)))
                  result)))))
    (nreverse result)))

(defun agent-skill--issue (severity backend skill issue detail)
  "Return a health issue plist.
SEVERITY is `error', `warning', or `info'.  BACKEND is the backend
symbol, SKILL the skill name, ISSUE a short description, and DETAIL the
path or explanation behind it."
  (list :severity severity :backend backend :skill skill
        :issue issue :detail detail))

(defun agent-skill--check-file (backend entry)
  "Return the issues found in root-file ENTRY of BACKEND.
ENTRY is one element of `agent-skill--root-files'."
  (let* ((path (nth 2 entry))
         (meta (nth 3 entry))
         (name (plist-get meta :name))
         (directory (file-name-nondirectory
                     (directory-file-name (file-name-directory path))))
         (issues nil))
    (cl-flet ((add (severity skill issue detail)
                (push (agent-skill--issue severity backend skill issue detail)
                      issues)))
      (if (null name)
          (add 'error directory "frontmatter missing or unparsable" path)
        (unless (equal name directory)
          (add 'warning name "frontmatter name differs from its directory"
               (format "directory `%s' at %s" directory path)))
        (let ((description (plist-get meta :description)))
          (when (or (null description) (string-empty-p description))
            (add 'warning name "description missing or empty" path)))
        (when-let* ((source (plist-get meta :argument-source)))
          (unless (file-expand-wildcards
                   (expand-file-name source (file-name-directory path)))
            (add 'warning name "argument-source matches no files" source)))
        (when (and (plist-member meta :argument-choices)
                   (null (plist-get meta :argument-choices)))
          (add 'warning name "argument-choices is empty" path))
        (when agent-skill-record-git-provenance
          (let ((provenance (agent-skill-provenance (list :path path))))
            (cond
             ((null (plist-get provenance :repo))
              (add 'info name "not in a git repository" path))
             ((plist-get provenance :dirty)
              (add 'info name "has uncommitted changes" path)))))))
    (nreverse issues)))

(defun agent-skill--check-shadowing (backend entries)
  "Return shadowing issues among BACKEND's root ENTRIES."
  (let ((by-name (make-hash-table :test #'equal))
        (issues nil))
    (dolist (entry entries)
      (when-let* ((name (plist-get (nth 3 entry) :name)))
        (push entry (gethash name by-name))))
    (maphash
     (lambda (name found)
       (when (cdr found)
         ;; `found' is reverse discovery order, so its car is the winner.
         (push (agent-skill--issue
                'warning backend name
                "provided by more than one root; later roots shadow earlier"
                (format "using %s; shadowed: %s"
                        (nth 2 (car found))
                        (string-join (mapcar (lambda (e) (nth 2 e))
                                             (cdr found))
                                     ", ")))
               issues)))
     by-name)
    issues))

(defun agent-skill--check-bundles ()
  "Return the issues found in `agent-skill-bundles'."
  (let ((issues nil))
    (pcase-dolist (`(,name . ,bundle) agent-skill-bundles)
      (dolist (backend (or (plist-get bundle :backends)
                           (mapcar #'car agent-backends)))
        (condition-case err
            (agent-skill-resolve-bundle name backend)
          (user-error
           (push (agent-skill--issue
                  'error backend name "bundle cannot be resolved"
                  (error-message-string err))
                 issues)))))
    (nreverse issues)))

(defun agent-skill-check-issues ()
  "Return every health issue found in the skill set and the bundles.
Each issue is a plist with `:severity' (`error', `warning', `info'),
`:backend', `:skill', `:issue' and `:detail'.  Read-only: nothing is
modified."
  (let ((issues nil))
    (dolist (entry agent-backends)
      (let* ((backend (car entry))
             (files (agent-skill--root-files backend)))
        (dolist (file files)
          (setq issues (append issues (agent-skill--check-file backend file))))
        (setq issues (append issues
                             (agent-skill--check-shadowing backend files)))))
    (append issues (agent-skill--check-bundles))))

(defconst agent-skill--severity-order '((error . 0) (warning . 1) (info . 2))
  "Sort order for health severities.")

(define-derived-mode agent-skill-check-mode tabulated-list-mode
  "Agent skill health"
  "Major mode listing skill health issues."
  (setq tabulated-list-format
        [("Severity" 9 t) ("Backend" 12 t) ("Skill" 24 t)
         ("Issue" 46 t) ("Detail" 60 nil)])
  (tabulated-list-init-header))

;;;###autoload
(defun agent-skill-check ()
  "Report problems in the discovered skills and configured bundles."
  (interactive)
  (let* ((issues (sort (agent-skill-check-issues)
                       (lambda (a b)
                         (< (alist-get (plist-get a :severity)
                                       agent-skill--severity-order)
                            (alist-get (plist-get b :severity)
                                       agent-skill--severity-order)))))
         (counts (mapcar (lambda (severity)
                           (cons severity
                                 (cl-count severity issues
                                           :key (lambda (i)
                                                  (plist-get i :severity)))))
                         '(error warning info)))
         (buffer (get-buffer-create "*Agent skill health*")))
    (with-current-buffer buffer
      (agent-skill-check-mode)
      (setq tabulated-list-entries
            (mapcar (lambda (issue)
                      (list issue
                            (vector (symbol-name (plist-get issue :severity))
                                    (symbol-name (plist-get issue :backend))
                                    (or (plist-get issue :skill) "")
                                    (or (plist-get issue :issue) "")
                                    (or (plist-get issue :detail) ""))))
                    issues))
      (setq header-line-format
            (format "%d error%s, %d warning%s, %d note%s"
                    (alist-get 'error counts)
                    (if (= 1 (alist-get 'error counts)) "" "s")
                    (alist-get 'warning counts)
                    (if (= 1 (alist-get 'warning counts)) "" "s")
                    (alist-get 'info counts)
                    (if (= 1 (alist-get 'info counts)) "" "s")))
      (tabulated-list-print t))
    (pop-to-buffer buffer)
    (message "Skill health: %d error(s), %d warning(s), %d note(s)"
             (alist-get 'error counts)
             (alist-get 'warning counts)
             (alist-get 'info counts))))
```

- [ ] **Step 4: Run the tests**

Run: `make test 2>&1 | tail -10`
Expected: all pass.

Run: `make compile`
Expected: no warnings.  If the compiler flags `agent-skill--issue` for
a docstring-less argument list, add the missing docstring rather than
silencing it.

- [ ] **Step 5: Commit**

```bash
git add agent-skill.el test/agent-skill-test.el
git commit -m "agent-skill: check discovered skills and configured bundles"
```

---

### Task 9: Learning-candidate parser

**Files:**
- Create: `agent-learn.el`
- Create: `test/agent-learn-test.el`
- Modify: `Makefile`

**Interfaces:**
- Consumes: nothing from the other new module; `agent-learn.el` never
  requires `agent-skill.el`.
- Produces:
  - `agent-learn-directory` — defcustom, default
    `(expand-file-name "agent/learnings/" user-emacs-directory)`.
  - `agent-learn-parse-file (FILE)` → plist `(:file :title :transcript
    :directory :captured :candidates :error)`.
  - Candidate plist: `(:file :index :title :fields :state :review-date
    :review-note :dispatched :text)`.
  - `agent-learn-candidate-field (CANDIDATE NAME)` → string or nil.

- [ ] **Step 1: Write the failing tests**

Create `test/agent-learn-test.el`:

````elisp
;;; agent-learn-test.el --- Tests for agent-learn -*- lexical-binding: t -*-

;; Tests for parsing, reviewing, and archiving learning candidates.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'agent)
(require 'agent-learn)

(defconst agent-learn-test--file
  "# Session learning candidates: 2026-05-11 codex 019e16d6

Source transcript: /tmp/rollout.jsonl
Working directory: /tmp/project
Captured: 2026-05-11

## Candidate 1: Harden ad hoc zsh loops

**Project:** dotfiles

**Summary:** Avoid reserved parameter names such as `status`.

**Value:** 32/100

**Implementation safety:** 58/100

**Proposed action:** `script`

**Proposed patch:**

```diff
-status=1
+audit_status=1
```

## Candidate 2: Second lesson

**Review:** approved 2026-07-31 — do this one

**Project:** agent

**Summary:** Something else.

**Value:** 80/100
"
  "A candidate file exercising headers, fields, fences, and a review.")

(defmacro agent-learn-test--with-file (var &rest body)
  "Write the fixture to a temporary inbox, bind VAR to it, and run BODY."
  (declare (indent 1))
  `(let* ((agent-learn-directory (make-temp-file "agent-learn" t))
          (inbox (expand-file-name "inbox" agent-learn-directory))
          (,var (expand-file-name "2026-05-11-codex-019e16d6.md" inbox)))
     (unwind-protect
         (progn
           (make-directory inbox t)
           (with-temp-file ,var (insert agent-learn-test--file))
           ,@body)
       (delete-directory agent-learn-directory t))))

;;;; Parsing

(ert-deftest agent-learn-test-parse-header ()
  "Read the file title, transcript, directory, and capture date."
  (agent-learn-test--with-file file
    (let ((parsed (agent-learn-parse-file file)))
      (should (equal "/tmp/rollout.jsonl" (plist-get parsed :transcript)))
      (should (equal "/tmp/project" (plist-get parsed :directory)))
      (should (equal "2026-05-11" (plist-get parsed :captured)))
      (should-not (plist-get parsed :error)))))

(ert-deftest agent-learn-test-parse-candidates ()
  "Return one candidate per section, in order, with its fields."
  (agent-learn-test--with-file file
    (let* ((candidates (plist-get (agent-learn-parse-file file) :candidates))
           (first (nth 0 candidates)))
      (should (= 2 (length candidates)))
      (should (equal "Harden ad hoc zsh loops" (plist-get first :title)))
      (should (= 1 (plist-get first :index)))
      (should (equal "dotfiles"
                     (agent-learn-candidate-field first "Project")))
      (should (equal "32/100"
                     (agent-learn-candidate-field first "Value"))))))

(ert-deftest agent-learn-test-parse-keeps-a-fenced-patch-whole ()
  "Keep a fenced diff in one field instead of splitting it."
  (agent-learn-test--with-file file
    (let* ((candidate (car (plist-get (agent-learn-parse-file file)
                                      :candidates)))
           (patch (agent-learn-candidate-field candidate "Proposed patch")))
      (should (string-match-p "audit_status=1" patch))
      (should (string-match-p "```diff" patch)))))

(ert-deftest agent-learn-test-parse-state-defaults-to-pending ()
  "A candidate with no review line is pending."
  (agent-learn-test--with-file file
    (let ((candidate (car (plist-get (agent-learn-parse-file file)
                                     :candidates))))
      (should (eq 'pending (plist-get candidate :state))))))

(ert-deftest agent-learn-test-parse-review-line ()
  "Read the state, date, and note from a review line."
  (agent-learn-test--with-file file
    (let ((candidate (nth 1 (plist-get (agent-learn-parse-file file)
                                       :candidates))))
      (should (eq 'approved (plist-get candidate :state)))
      (should (equal "2026-07-31" (plist-get candidate :review-date)))
      (should (equal "do this one" (plist-get candidate :review-note))))))

(ert-deftest agent-learn-test-parse-unknown-state-is-other ()
  "Show an unrecognized state verbatim rather than guessing."
  (should (eq 'other
              (plist-get (agent-learn--parse-review "maybe 2026-07-31")
                         :state))))

(ert-deftest agent-learn-test-parse-file-without-candidates ()
  "Return no candidates and no error for a file with only a header."
  (let ((file (make-temp-file "agent-learn" nil ".md" "# Nothing here\n")))
    (unwind-protect
        (let ((parsed (agent-learn-parse-file file)))
          (should-not (plist-get parsed :candidates))
          (should-not (plist-get parsed :error)))
      (delete-file file))))

(ert-deftest agent-learn-test-parse-unreadable-file-reports-an-error ()
  "Report an unreadable file instead of signaling."
  (let ((parsed (agent-learn-parse-file "/nowhere/missing.md")))
    (should (plist-get parsed :error))
    (should-not (plist-get parsed :candidates))))

(provide 'agent-learn-test)
;;; agent-learn-test.el ends here
````

Note: the fixture embeds a fenced block inside an Elisp string, so the
inner triple backticks are ordinary characters — no escaping needed.
(This plan wraps that block in a four-backtick fence for the same
reason.)

- [ ] **Step 2: Run the tests and watch them fail**

Run: `make test 2>&1 | tail -20`
Expected: `Cannot open load file: agent-learn`.

- [ ] **Step 3: Create the module with the parser**

Create `agent-learn.el`:

```elisp
;;; agent-learn.el --- Review agent-authored learning candidates -*- lexical-binding: t -*-

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

;; Agent sessions can write learning candidates — Markdown proposals
;; about how future sessions should behave — into an inbox directory.
;; This module reviews them: approve, reject, edit, archive, and hand an
;; approved candidate to an ordinary session for implementation.
;;
;; Approval records a decision.  It never installs anything: no command
;; here edits a skill, an instructions file, a hook, or any other target
;; artifact, and no command applies a proposed patch.  Nothing is ever
;; deleted; archiving moves a file inside `agent-learn-directory'.

;;; Code:

(require 'agent)
(require 'cl-lib)
(require 'subr-x)

;;;; Customization

(defgroup agent-learn ()
  "Review of agent-authored learning candidates."
  :group 'agent)

(defcustom agent-learn-directory
  (expand-file-name "agent/learnings/" user-emacs-directory)
  "Directory holding learning candidate files.
Candidates awaiting review live in the `inbox' subdirectory; reviewed
files are moved to `archive/YYYY-MM-DD/'.  Point this at whatever
directory the capture skill writes to."
  :type 'directory
  :group 'agent-learn)

(defcustom agent-learn-file-limit 200
  "How many inbox files `agent-learn' reads, newest first.
The list buffer always states how many of the available files were
read, so a bounded view never reads as a complete one."
  :type 'integer
  :group 'agent-learn)

;;;; Parsing

(defconst agent-learn--candidate-regexp
  "^## Candidate \\([0-9]+\\): \\(.*\\)$"
  "Regexp matching a candidate heading.")

(defconst agent-learn--field-regexp
  "^\\*\\*\\([^*]+?\\):\\*\\*[ \t]*\\(.*\\)$"
  "Regexp matching the first line of a candidate field.")

(defconst agent-learn--fence-regexp "^[ \t]*```"
  "Regexp matching a fenced-block delimiter.")

(defconst agent-learn--managed-fields '("Review" "Dispatched")
  "Fields this package owns, in the order it writes them.")

(defconst agent-learn--states
  '("approved" "rejected" "archived-unreviewed")
  "Review states this package writes.")

(defun agent-learn--trim-lines (lines)
  "Return LINES joined, with trailing blank lines removed."
  (string-trim-right (string-join (nreverse lines) "\n")))

(defun agent-learn--parse-fields (text)
  "Return an alist of field name to value found in candidate TEXT.
A field runs from its `**Name:**' line to the line before the next
field line, so multi-paragraph values survive.  Lines inside a fenced
block never start a field."
  (let ((in-fence nil)
        (fields nil)
        (current nil)
        (value nil))
    (dolist (line (split-string text "\n"))
      (cond
       ((string-match-p agent-learn--fence-regexp line)
        (setq in-fence (not in-fence))
        (when current (push line value)))
       ((and (not in-fence) (string-match agent-learn--field-regexp line))
        (when current
          (push (cons current (agent-learn--trim-lines value)) fields))
        (setq current (string-trim (match-string 1 line))
              value (list (match-string 2 line))))
       (current (push line value))))
    (when current
      (push (cons current (agent-learn--trim-lines value)) fields))
    (nreverse fields)))

(defun agent-learn--parse-review (value)
  "Return the state plist encoded in review field VALUE.
VALUE looks like \"approved 2026-07-31 — a note\".  An unrecognized
state parses as `other' and is shown verbatim rather than guessed at."
  (let* ((parts (split-string (or value "") " — " t))
         (head (string-trim (or (car parts) "")))
         (note (when (cdr parts)
                 (string-trim (string-join (cdr parts) " — "))))
         (words (split-string head " " t))
         (state (car words))
         (date (cadr words)))
    (list :state (if (member state agent-learn--states)
                     (intern state)
                   'other)
          :state-text state
          :date date
          :note note)))

(defun agent-learn-candidate-field (candidate name)
  "Return CANDIDATE's field NAME, or nil."
  (cdr (assoc name (plist-get candidate :fields))))

(defun agent-learn--parse-candidate (file index title text)
  "Return the candidate plist for section TEXT.
FILE, INDEX, and TITLE identify it."
  (let* ((fields (agent-learn--parse-fields text))
         (review (agent-learn--parse-review (cdr (assoc "Review" fields)))))
    (list :file file
          :index index
          :title title
          :fields fields
          :text text
          :state (if (assoc "Review" fields)
                     (plist-get review :state)
                   'pending)
          :state-text (plist-get review :state-text)
          :review-date (plist-get review :date)
          :review-note (plist-get review :note)
          :dispatched (cdr (assoc "Dispatched" fields)))))

(defun agent-learn--parse-header (text)
  "Return the header plist parsed from TEXT."
  (let ((result nil))
    (dolist (pair '(("Source transcript" . :transcript)
                    ("Working directory" . :directory)
                    ("Captured" . :captured)))
      (when (string-match (format "^%s: *\\(.*\\)$" (car pair)) text)
        (setq result (plist-put result (cdr pair)
                                (string-trim (match-string 1 text))))))
    (when (string-match "^# \\(.*\\)$" text)
      (setq result (plist-put result :title (string-trim
                                             (match-string 1 text)))))
    result))

(defun agent-learn-parse-file (file)
  "Return the candidates and header of learning FILE.
The result is a plist with `:file', `:title', `:transcript',
`:directory', `:captured', `:candidates' and, when the file could not
be read, `:error'."
  (if (not (file-readable-p file))
      (list :file file :error (format "cannot read %s" file))
    (with-temp-buffer
      (insert-file-contents file)
      (let* ((content (buffer-string))
             (starts nil)
             (candidates nil))
        (goto-char (point-min))
        (while (re-search-forward agent-learn--candidate-regexp nil t)
          (push (list (match-beginning 0)
                      (string-to-number (match-string 1))
                      (string-trim (match-string 2)))
                starts))
        (setq starts (nreverse starts))
        (let ((bounds (append (mapcar #'car (cdr starts))
                              (list (point-max)))))
          (cl-loop for start in starts
                   for end in bounds
                   do (push (agent-learn--parse-candidate
                             file (nth 1 start) (nth 2 start)
                             (buffer-substring-no-properties (car start) end))
                            candidates)))
        (append (list :file file :candidates (nreverse candidates))
                (agent-learn--parse-header
                 (substring content 0 (min (length content) 2000))))))))

;;;; Provide

(provide 'agent-learn)
;;; agent-learn.el ends here
```

- [ ] **Step 4: Add the module to the Makefile**

```make
SRC := agent.el agent-account.el agent-capture.el agent-slack.el agent-snippet.el agent-claude-cli.el agent-claude.el agent-codex.el agent-chief.el agent-skill.el agent-learn.el
TEST_FILES := test/agent-test.el test/agent-account-test.el test/agent-capture-test.el test/agent-slack-test.el test/agent-snippet-test.el test/agent-claude-cli-test.el test/agent-claude-test.el test/agent-codex-test.el test/agent-chief-test.el test/agent-skill-test.el test/agent-learn-test.el
```

- [ ] **Step 5: Run the tests**

Run: `make test 2>&1 | tail -10`
Expected: all pass.

Run: `make compile`
Expected: no warnings.

- [ ] **Step 6: Commit**

```bash
git add agent-learn.el test/agent-learn-test.el Makefile
git commit -m "agent-learn: parse agent-authored learning candidate files"
```

---

### Task 10: Writing review state back

**Files:**
- Modify: `agent-learn.el`
- Modify: `test/agent-learn-test.el`

**Interfaces:**
- Consumes: the candidate plists of Task 9.
- Produces:
  - `agent-learn-set-review (CANDIDATE STATE &optional NOTE)` — writes
    the `**Review:**` line and returns the re-parsed candidate.
  - `agent-learn-note-dispatch (CANDIDATE LABEL)` — writes the
    `**Dispatched:**` line.

- [ ] **Step 1: Write the failing tests**

Append to `test/agent-learn-test.el`, before the `provide`:

```elisp
;;;; Writing

(defun agent-learn-test--candidate (file index)
  "Return candidate INDEX of FILE, re-parsed from disk."
  (nth (1- index) (plist-get (agent-learn-parse-file file) :candidates)))

(ert-deftest agent-learn-test-set-review-inserts-a-line ()
  "Insert the review line directly after the candidate heading."
  (agent-learn-test--with-file file
    (cl-letf (((symbol-function 'format-time-string)
               (lambda (&rest _) "2026-07-31")))
      (agent-learn-set-review (agent-learn-test--candidate file 1)
                              'approved "a note"))
    (with-temp-buffer
      (insert-file-contents file)
      (should (string-match-p
               "^## Candidate 1: Harden ad hoc zsh loops\n\n\\*\\*Review:\\*\\* \
approved 2026-07-31 — a note\n\n\\*\\*Project:\\*\\*"
               (buffer-string))))))

(ert-deftest agent-learn-test-set-review-replaces-an-existing-line ()
  "Replace a review line instead of stacking a second one."
  (agent-learn-test--with-file file
    (cl-letf (((symbol-function 'format-time-string)
               (lambda (&rest _) "2026-08-01")))
      (agent-learn-set-review (agent-learn-test--candidate file 2)
                              'rejected "changed my mind"))
    (let ((candidate (agent-learn-test--candidate file 2)))
      (should (eq 'rejected (plist-get candidate :state)))
      (should (equal "changed my mind" (plist-get candidate :review-note))))
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-min))
      (should (= 1 (how-many "^\\*\\*Review:\\*\\*"))))))

(ert-deftest agent-learn-test-set-review-preserves-every-other-byte ()
  "Change nothing but the managed lines."
  (agent-learn-test--with-file file
    (let ((before (with-temp-buffer (insert-file-contents file)
                                    (buffer-string))))
      (cl-letf (((symbol-function 'format-time-string)
                 (lambda (&rest _) "2026-07-31")))
        (agent-learn-set-review (agent-learn-test--candidate file 1)
                                'approved nil))
      (let ((after (with-temp-buffer (insert-file-contents file)
                                     (buffer-string))))
        (should (equal before
                       (replace-regexp-in-string
                        "\\*\\*Review:\\*\\* approved 2026-07-31\n\n" ""
                        after)))))))

(ert-deftest agent-learn-test-note-dispatch-follows-the-review ()
  "Write the dispatch line after the review line, not before it."
  (agent-learn-test--with-file file
    (cl-letf (((symbol-function 'format-time-string)
               (lambda (&rest _) "2026-07-31")))
      (agent-learn-note-dispatch (agent-learn-test--candidate file 2)
                                 "Claude agent"))
    (with-temp-buffer
      (insert-file-contents file)
      (should (string-match-p
               "\\*\\*Review:\\*\\* approved.*\n\n\\*\\*Dispatched:\\*\\* \
2026-07-31 — Claude agent\n"
               (buffer-string))))))

(ert-deftest agent-learn-test-write-refuses-a-modified-buffer ()
  "Refuse to save someone else's unsaved edits as a side effect."
  (agent-learn-test--with-file file
    (let ((buffer (find-file-noselect file)))
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (goto-char (point-max))
              (insert "scratch\n"))
            (should-error
             (agent-learn-set-review (agent-learn-test--candidate file 1)
                                     'approved nil)
             :type 'user-error))
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer)))))

(ert-deftest agent-learn-test-write-refuses-a-moved-candidate ()
  "Refuse when the heading no longer matches what was parsed."
  (agent-learn-test--with-file file
    (let ((candidate (agent-learn-test--candidate file 1)))
      (with-temp-file file (insert "# Emptied\n"))
      (should-error (agent-learn-set-review candidate 'approved nil)
                    :type 'user-error))))
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `make test 2>&1 | tail -20`
Expected: `agent-learn-set-review` is void.

- [ ] **Step 3: Implement the writer**

Add to `agent-learn.el` after the parsing section:

```elisp
;;;; Writing review state

(defun agent-learn--find-candidate (candidate)
  "Move point to CANDIDATE's heading in the current buffer.
Signal a `user-error' when the heading is gone or its title changed:
the file may have been rewritten since it was parsed."
  (goto-char (point-min))
  (let ((heading (format "^## Candidate %d: %s$"
                         (plist-get candidate :index)
                         (regexp-quote (plist-get candidate :title)))))
    (unless (re-search-forward heading nil t)
      (user-error "Candidate `%s' is no longer in %s"
                  (plist-get candidate :title)
                  (abbreviate-file-name (plist-get candidate :file))))
    (goto-char (match-beginning 0))))

(defun agent-learn--managed-bounds ()
  "Return (START . END) of the managed block after the heading at point.
The block is the run of `**Review:**' and `**Dispatched:**' paragraphs
immediately following the heading.  START is where the block begins;
END is where the rest of the candidate resumes."
  (forward-line 1)
  (when (looking-at-p "^[ \t]*$") (forward-line 1))
  (let ((start (point)))
    (while (looking-at (format "^\\*\\*\\(?:%s\\):\\*\\*"
                               (string-join agent-learn--managed-fields "\\|")))
      (forward-line 1)
      (while (looking-at-p "^[ \t]*$") (forward-line 1)))
    (cons start (point))))

(defun agent-learn--managed-values (text)
  "Return the alist of managed fields present in block TEXT."
  (let ((fields (agent-learn--parse-fields text)))
    (cl-remove-if-not (lambda (pair)
                        (member (car pair) agent-learn--managed-fields))
                      fields)))

(defun agent-learn--write-managed (candidate updates)
  "Rewrite CANDIDATE's managed block, applying UPDATES.
UPDATES is an alist of field name to value string; a nil value removes
the field.  Every other byte of the file is left untouched.

The edit happens in a temporary buffer rather than through
`find-file-noselect', so this never leaves a stale file-visiting buffer
behind and never saves someone else's unsaved edits as a side effect: a
visiting buffer with unsaved changes is refused by name, and an
unmodified one is reverted afterwards."
  (let* ((file (plist-get candidate :file))
         (visiting (get-file-buffer file)))
    (when (and visiting (buffer-modified-p visiting))
      (user-error "%s has unsaved changes; save or revert it first"
                  (abbreviate-file-name file)))
    (with-temp-buffer
      (insert-file-contents file)
      (agent-learn--find-candidate candidate)
      (let* ((bounds (agent-learn--managed-bounds))
             (existing (agent-learn--managed-values
                        (buffer-substring-no-properties
                         (car bounds) (cdr bounds)))))
        (pcase-dolist (`(,name . ,value) updates)
          (setf (alist-get name existing nil t #'equal) value))
        (delete-region (car bounds) (cdr bounds))
        (goto-char (car bounds))
        (dolist (name agent-learn--managed-fields)
          (when-let* ((value (cdr (assoc name existing))))
            (insert (format "**%s:** %s\n\n" name value)))))
      (write-region (point-min) (point-max) file nil 'no-message))
    (when (buffer-live-p visiting)
      (with-current-buffer visiting
        (revert-buffer t t t)))
    (agent-learn--reparse candidate)))

(defun agent-learn--reparse (candidate)
  "Return CANDIDATE re-read from its file."
  (let ((parsed (agent-learn-parse-file (plist-get candidate :file))))
    (cl-find (plist-get candidate :index)
             (plist-get parsed :candidates)
             :key (lambda (c) (plist-get c :index)))))

(defun agent-learn-set-review (candidate state &optional note)
  "Record STATE, today's date, and NOTE as CANDIDATE's review.
STATE is `approved', `rejected', or `archived-unreviewed'.  Nothing
outside the `**Review:**' line is modified, and nothing is installed:
this records a decision."
  (unless (member (symbol-name state) agent-learn--states)
    (error "Unknown review state `%s'" state))
  (agent-learn--write-managed
   candidate
   (list (cons "Review"
               (concat (symbol-name state)
                       " " (format-time-string "%F")
                       (if (and note (not (string-empty-p note)))
                           (format " — %s" note)
                         ""))))))

(defun agent-learn-note-dispatch (candidate label)
  "Record that CANDIDATE was handed to the session named LABEL."
  (agent-learn--write-managed
   candidate
   (list (cons "Dispatched"
               (format "%s — %s" (format-time-string "%F") label)))))
```

- [ ] **Step 4: Run the tests**

Run: `make test 2>&1 | tail -10`
Expected: all pass, including the byte-preservation test.

Run: `make compile`
Expected: no warnings.

- [ ] **Step 5: Commit**

```bash
git add agent-learn.el test/agent-learn-test.el
git commit -m "agent-learn: record review decisions inside candidate files"
```

---

### Task 11: The review list

**Files:**
- Modify: `agent-learn.el`
- Modify: `test/agent-learn-test.el`

**Interfaces:**
- Consumes: `agent-learn-parse-file`, `agent-learn-set-review`.
- Produces:
  - `agent-learn-files (&optional INCLUDE-ARCHIVED)` → plist
    `(:files LIST :total INT)`.
  - `agent-learn-candidates (&optional INCLUDE-ARCHIVED)` → plist
    `(:candidates LIST :files INT :total INT :errors LIST)`.
  - `agent-learn` — autoloaded command; `agent-learn-mode`;
    `agent-learn-approve`, `agent-learn-reject`, `agent-learn-edit`,
    `agent-learn-show`, `agent-learn-refresh`.

- [ ] **Step 1: Write the failing tests**

Append to `test/agent-learn-test.el`:

```elisp
;;;; Listing

(ert-deftest agent-learn-test-candidates-are-sorted-pending-first ()
  "List pending candidates before reviewed ones, then by value."
  (agent-learn-test--with-file file
    (let* ((result (agent-learn-candidates))
           (states (mapcar (lambda (c) (plist-get c :state))
                           (plist-get result :candidates))))
      (should (equal '(pending approved) states))
      (should (= 1 (plist-get result :files)))
      (should (= 1 (plist-get result :total))))))

(ert-deftest agent-learn-test-file-limit-is-reported ()
  "Read at most `agent-learn-file-limit' files and say so."
  (agent-learn-test--with-file file
    (let ((second (expand-file-name "2026-05-12-codex-b.md"
                                    (file-name-directory file))))
      (with-temp-file second (insert agent-learn-test--file))
      (let* ((agent-learn-file-limit 1)
             (result (agent-learn-candidates)))
        (should (= 1 (plist-get result :files)))
        (should (= 2 (plist-get result :total)))))))

(ert-deftest agent-learn-test-unreadable-file-is-reported ()
  "Collect a parse error instead of dropping the file silently."
  (agent-learn-test--with-file file
    (let ((unreadable (expand-file-name "2026-05-13-broken.md"
                                        (file-name-directory file))))
      (with-temp-file unreadable (insert "# Header only\n"))
      (set-file-modes unreadable #o000)
      (unwind-protect
          (let ((result (agent-learn-candidates)))
            (should (= 1 (length (plist-get result :errors))))
            (should (equal unreadable
                           (plist-get (car (plist-get result :errors))
                                      :file))))
        (set-file-modes unreadable #o600)))))

(ert-deftest agent-learn-test-approve-updates-the-row ()
  "Approving a candidate re-reads it as approved."
  (agent-learn-test--with-file file
    (agent-learn-set-review (agent-learn-test--candidate file 1)
                            'approved nil)
    (should (eq 'approved
                (plist-get (agent-learn-test--candidate file 1) :state)))))
```

If the test runner happens to run as a user who can read mode-000 files
(root), the unreadable-file test will fail honestly rather than pass
vacuously; run the suite as your normal user.

- [ ] **Step 2: Run the tests and watch them fail**

Run: `make test 2>&1 | tail -20`
Expected: `agent-learn-candidates` is void.

- [ ] **Step 3: Implement listing and the buffer**

Add to `agent-learn.el`:

```elisp
;;;; Listing

(defun agent-learn--inbox ()
  "Return the inbox directory."
  (expand-file-name "inbox" agent-learn-directory))

(defun agent-learn--archive-root ()
  "Return the archive directory."
  (expand-file-name "archive" agent-learn-directory))

(defun agent-learn--markdown-files (directory)
  "Return the Markdown files directly under DIRECTORY."
  (when (file-directory-p directory)
    (directory-files directory t "\\.md\\'")))

(defun agent-learn-files (&optional include-archived)
  "Return candidate files newest first, bounded by `agent-learn-file-limit'.
The result is a plist with `:files' (the bounded list) and `:total'
\(how many exist).  INCLUDE-ARCHIVED adds every archived date
directory.  Files sort by name descending, then modification time
descending: names begin with a date, and mtime alone would reorder a
file the moment a review line is written into it."
  (let* ((all (append (agent-learn--markdown-files (agent-learn--inbox))
                      (when include-archived
                        (mapcan #'agent-learn--markdown-files
                                (let ((root (agent-learn--archive-root)))
                                  (when (file-directory-p root)
                                    (directory-files root t "\\`[^.]")))))))
         (sorted (sort all
                       (lambda (a b)
                         (let ((na (file-name-nondirectory a))
                               (nb (file-name-nondirectory b)))
                           (if (equal na nb)
                               (time-less-p
                                (file-attribute-modification-time
                                 (file-attributes b))
                                (file-attribute-modification-time
                                 (file-attributes a)))
                             (string> na nb)))))))
    (list :files (if (and agent-learn-file-limit
                          (> (length sorted) agent-learn-file-limit))
                     (take agent-learn-file-limit sorted)
                   sorted)
          :total (length sorted))))

(defun agent-learn--candidate-number (candidate name)
  "Return CANDIDATE's field NAME parsed as a leading integer, or -1."
  (let ((value (agent-learn-candidate-field candidate name)))
    (if (and value (string-match "\\([0-9]+\\)" value))
        (string-to-number (match-string 1 value))
      -1)))

(defun agent-learn--candidate-less-p (a b)
  "Return non-nil when candidate A sorts before candidate B."
  (let ((pending-a (eq 'pending (plist-get a :state)))
        (pending-b (eq 'pending (plist-get b :state))))
    (cond
     ((not (eq pending-a pending-b)) pending-a)
     (t (> (agent-learn--candidate-number a "Value")
           (agent-learn--candidate-number b "Value"))))))

(defun agent-learn-candidates (&optional include-archived)
  "Return the candidates of the files `agent-learn-files' selected.
The result is a plist with `:candidates' (sorted pending first, then by
value descending), `:files' (files read), `:total' (files available)
and `:errors' (plists naming files that could not be parsed)."
  (let* ((selection (agent-learn-files include-archived))
         (candidates nil)
         (errors nil))
    (dolist (file (plist-get selection :files))
      (let ((parsed (agent-learn-parse-file file)))
        (if (plist-get parsed :error)
            (push parsed errors)
          (setq candidates (append candidates
                                   (plist-get parsed :candidates))))))
    (list :candidates (sort candidates #'agent-learn--candidate-less-p)
          :files (length (plist-get selection :files))
          :total (plist-get selection :total)
          :errors (nreverse errors))))

;;;; Review buffer

(defvar-local agent-learn--show-archived nil
  "Non-nil when the list buffer includes archived files.")

(defvar-keymap agent-learn-mode-map
  :doc "Keymap for `agent-learn-mode'."
  "RET" #'agent-learn-show
  "a" #'agent-learn-approve
  "r" #'agent-learn-reject
  "e" #'agent-learn-edit
  "A" #'agent-learn-archive
  "i" #'agent-learn-implement
  "t" #'agent-learn-toggle-archived
  "L" #'agent-learn-set-file-limit
  "g" #'agent-learn-refresh)

(define-derived-mode agent-learn-mode tabulated-list-mode
  "Agent learnings"
  "Major mode for reviewing agent-authored learning candidates.

Approval records a decision; it never installs anything."
  (setq tabulated-list-format
        [("State" 20 t) ("Value" 6 t) ("Safety" 7 t) ("Action" 15 t)
         ("Project" 18 t) ("Title" 52 t) ("Captured" 11 t)])
  (tabulated-list-init-header))

(defun agent-learn--row (candidate)
  "Return the tabulated-list entry for CANDIDATE."
  (list candidate
        (vector (if (eq 'other (plist-get candidate :state))
                    (or (plist-get candidate :state-text) "other")
                  (symbol-name (plist-get candidate :state)))
                (or (agent-learn-candidate-field candidate "Value") "")
                (or (agent-learn-candidate-field candidate
                                                 "Implementation safety")
                    "")
                (or (agent-learn-candidate-field candidate "Proposed action")
                    "")
                (or (agent-learn-candidate-field candidate "Project") "")
                (or (plist-get candidate :title) "")
                (or (file-name-base (plist-get candidate :file)) ""))))

(defun agent-learn-refresh ()
  "Re-read the candidate files into the current buffer."
  (interactive nil agent-learn-mode)
  (let ((result (agent-learn-candidates agent-learn--show-archived)))
    (setq tabulated-list-entries
          (mapcar #'agent-learn--row (plist-get result :candidates)))
    (setq header-line-format
          (format "%d candidates from %d of %d files%s%s"
                  (length (plist-get result :candidates))
                  (plist-get result :files)
                  (plist-get result :total)
                  (if (plist-get result :errors)
                      (format "  %d unreadable"
                              (length (plist-get result :errors)))
                    "")
                  (if agent-learn--show-archived "  (including archive)" "")))
    (tabulated-list-print t)))

(defun agent-learn--candidate-at-point ()
  "Return the candidate at point, or signal."
  (or (tabulated-list-get-id)
      (user-error "No candidate at point")))

(defun agent-learn-show ()
  "Show the full text of the candidate at point."
  (interactive nil agent-learn-mode)
  (let ((candidate (agent-learn--candidate-at-point))
        (buffer (get-buffer-create "*Agent learning*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "File: %s\n\n"
                        (abbreviate-file-name (plist-get candidate :file))))
        (insert (plist-get candidate :text)))
      (special-mode)
      (goto-char (point-min)))
    (pop-to-buffer buffer)))

(defun agent-learn-approve ()
  "Approve the candidate at point.
Recording approval installs nothing: use \\[agent-learn-implement] to
hand an approved candidate to a session."
  (interactive nil agent-learn-mode)
  (let* ((candidate (agent-learn--candidate-at-point))
         (note (read-string "Approval note (optional): ")))
    (agent-learn-set-review candidate 'approved note)
    (agent-learn-refresh)
    (message "Approved: %s" (plist-get candidate :title))))

(defun agent-learn-reject ()
  "Reject the candidate at point, recording a reason."
  (interactive nil agent-learn-mode)
  (let* ((candidate (agent-learn--candidate-at-point))
         (reason (read-string "Rejection reason: ")))
    (when (string-empty-p (string-trim reason))
      (user-error "A rejection needs a reason"))
    (agent-learn-set-review candidate 'rejected reason)
    (agent-learn-refresh)
    (message "Rejected: %s" (plist-get candidate :title))))

(defun agent-learn-edit ()
  "Open the candidate at point in its file for free editing."
  (interactive nil agent-learn-mode)
  (let ((candidate (agent-learn--candidate-at-point)))
    (find-file (plist-get candidate :file))
    (goto-char (point-min))
    (re-search-forward (format "^## Candidate %d: "
                               (plist-get candidate :index))
                       nil t)
    (beginning-of-line)))

(defun agent-learn-toggle-archived ()
  "Toggle whether archived files are listed."
  (interactive nil agent-learn-mode)
  (setq agent-learn--show-archived (not agent-learn--show-archived))
  (agent-learn-refresh))

(defun agent-learn-set-file-limit (limit)
  "Re-read the list with LIMIT files."
  (interactive (list (read-number "Files to read: " agent-learn-file-limit))
               agent-learn-mode)
  (setq-local agent-learn-file-limit limit)
  (agent-learn-refresh))

;;;###autoload
(defun agent-learn ()
  "Review agent-authored learning candidates.
Approve, reject, edit, or archive them.  Nothing here installs a
change: an approved candidate reaches its target only through a session
you start with \\[agent-learn-implement]."
  (interactive)
  (let ((buffer (get-buffer-create "*Agent learnings*")))
    (with-current-buffer buffer
      (agent-learn-mode)
      (agent-learn-refresh))
    (pop-to-buffer buffer)))
```

- [ ] **Step 4: Run the tests**

Run: `make test 2>&1 | tail -10`
Expected: all pass.  `agent-learn-archive` and `agent-learn-implement`
are referenced by the keymap but defined in Tasks 12 and 13; add
forward declarations at the top of the "Review buffer" section so the
byte-compiler stays quiet:

```elisp
(declare-function agent-learn-archive "agent-learn" ())
(declare-function agent-learn-implement "agent-learn" ())
```

Run: `make compile`
Expected: no warnings.

- [ ] **Step 5: Commit**

```bash
git add agent-learn.el test/agent-learn-test.el
git commit -m "agent-learn: review candidates in a dedicated list buffer"
```

---

### Task 12: Archiving

**Files:**
- Modify: `agent-learn.el`
- Modify: `test/agent-learn-test.el`

**Interfaces:**
- Consumes: `agent-learn-set-review`, `agent-learn-parse-file`.
- Produces:
  - `agent-learn-archive-file (FILE &optional FORCE)` → the new path.
  - `agent-learn-archive` — command bound to `A`.
  - `agent-learn-archive-resolved` — autoloaded command.

- [ ] **Step 1: Write the failing tests**

Append to `test/agent-learn-test.el`:

```elisp
;;;; Archiving

(ert-deftest agent-learn-test-archive-moves-a-resolved-file ()
  "Move a fully reviewed file into a dated archive directory."
  (agent-learn-test--with-file file
    (dolist (index '(1 2))
      (agent-learn-set-review (agent-learn-test--candidate file index)
                              'approved nil))
    (let ((target (agent-learn-archive-file file)))
      (should-not (file-exists-p file))
      (should (file-exists-p target))
      (should (string-match-p "/archive/[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}/"
                              target)))))

(ert-deftest agent-learn-test-archive-refuses-unresolved-without-force ()
  "Refuse to archive a file with a pending candidate."
  (agent-learn-test--with-file file
    (should-error (agent-learn-archive-file file) :type 'user-error)
    (should (file-exists-p file))))

(ert-deftest agent-learn-test-archive-force-marks-unreviewed ()
  "Record `archived-unreviewed' before a forced archive."
  (agent-learn-test--with-file file
    (let ((target (agent-learn-archive-file file t)))
      (should (eq 'archived-unreviewed
                  (plist-get (car (plist-get (agent-learn-parse-file target)
                                             :candidates))
                             :state))))))

(ert-deftest agent-learn-test-archive-never-overwrites ()
  "Give a second file of the same name a distinct archived path."
  (agent-learn-test--with-file file
    (let* ((first (agent-learn-archive-file file t))
           (_ (with-temp-file file (insert agent-learn-test--file)))
           (second (agent-learn-archive-file file t)))
      (should (file-exists-p first))
      (should (file-exists-p second))
      (should-not (equal first second)))))

(ert-deftest agent-learn-test-archive-resolved-skips-pending-files ()
  "Archive only the files whose candidates are all resolved."
  (agent-learn-test--with-file file
    (let ((other (expand-file-name "2026-05-12-codex-b.md"
                                   (file-name-directory file))))
      (with-temp-file other (insert agent-learn-test--file))
      (dolist (index '(1 2))
        (agent-learn-set-review (agent-learn-test--candidate other index)
                                'rejected "no"))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_prompt) t)))
        (agent-learn-archive-resolved))
      (should (file-exists-p file))
      (should-not (file-exists-p other)))))
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `make test 2>&1 | tail -20`
Expected: `agent-learn-archive-file` is void.

- [ ] **Step 3: Implement archiving**

Add to `agent-learn.el`:

```elisp
;;;; Archiving

(defun agent-learn--resolved-p (candidate)
  "Return non-nil when CANDIDATE has a recorded decision."
  (not (memq (plist-get candidate :state) '(pending other))))

(defun agent-learn--file-resolved-p (file)
  "Return non-nil when every candidate in FILE has a decision."
  (let ((candidates (plist-get (agent-learn-parse-file file) :candidates)))
    (cl-every #'agent-learn--resolved-p candidates)))

(defun agent-learn--archive-target (file)
  "Return an unused path for FILE inside today's archive directory."
  (let* ((directory (expand-file-name (format-time-string "%F")
                                      (agent-learn--archive-root)))
         (base (file-name-base file))
         (extension (or (file-name-extension file t) ".md"))
         (candidate (expand-file-name (concat base extension) directory))
         (counter 1))
    (make-directory directory t)
    (while (file-exists-p candidate)
      (setq candidate (expand-file-name
                       (format "%s-%d%s" base counter extension) directory)
            counter (1+ counter)))
    candidate))

(defun agent-learn-archive-file (file &optional force)
  "Move FILE into today's archive directory and return the new path.
Signal a `user-error' when a candidate has no recorded decision, unless
FORCE is non-nil — in which case each such candidate is first marked
`archived-unreviewed', so nothing leaves the inbox undecided.  The file
is renamed, never deleted."
  (let ((parsed (agent-learn-parse-file file)))
    (when (plist-get parsed :error)
      (user-error "%s" (plist-get parsed :error)))
    (let ((unresolved (cl-remove-if #'agent-learn--resolved-p
                                    (plist-get parsed :candidates))))
      (when unresolved
        (unless force
          (user-error "%s has %d candidate%s with no decision"
                      (abbreviate-file-name file)
                      (length unresolved)
                      (if (= 1 (length unresolved)) "" "s")))
        (dolist (candidate unresolved)
          (agent-learn-set-review candidate 'archived-unreviewed nil)))))
  (let ((target (agent-learn--archive-target file)))
    (rename-file file target)
    target))

(defun agent-learn-archive ()
  "Archive the file holding the candidate at point."
  (interactive nil agent-learn-mode)
  (let* ((candidate (agent-learn--candidate-at-point))
         (file (plist-get candidate :file))
         (force (not (agent-learn--file-resolved-p file))))
    (when (and force
               (not (yes-or-no-p
                     (format "%s has undecided candidates; \
mark them archived-unreviewed and archive? "
                             (abbreviate-file-name file)))))
      (user-error "Aborted"))
    (let ((target (agent-learn-archive-file file force)))
      (agent-learn-refresh)
      (message "Archived to %s" (abbreviate-file-name target)))))

;;;###autoload
(defun agent-learn-archive-resolved ()
  "Archive every inbox file whose candidates all have a decision.
This considers the whole inbox, not the bounded set the list buffer
shows: a bulk operation that silently skipped files would be worse than
no bulk operation."
  (interactive)
  (let* ((agent-learn-file-limit nil)
         (files (cl-remove-if-not #'agent-learn--file-resolved-p
                                  (plist-get (agent-learn-files) :files)))
         (count (length files)))
    (cond
     ((zerop count) (message "No fully reviewed files to archive"))
     ((not (yes-or-no-p (format "Archive %d reviewed file%s? "
                                count (if (= 1 count) "" "s"))))
      (message "Nothing archived"))
     (t
      (dolist (file files) (agent-learn-archive-file file))
      (when (derived-mode-p 'agent-learn-mode) (agent-learn-refresh))
      (message "Archived %d file%s" count (if (= 1 count) "" "s"))))))
```

- [ ] **Step 4: Run the tests**

Run: `make test 2>&1 | tail -10`
Expected: all pass.

Run: `make compile`
Expected: no warnings.  Remove the `agent-learn-archive` forward
declaration added in Task 11 now that the function exists.

- [ ] **Step 5: Commit**

```bash
git add agent-learn.el test/agent-learn-test.el
git commit -m "agent-learn: archive reviewed candidate files"
```

---

### Task 13: Handing an approved candidate to a session

**Files:**
- Modify: `agent-learn.el`
- Modify: `test/agent-learn-test.el`

**Interfaces:**
- Consumes: `agent-read-dispatch-target`, `agent-dispatch-prompt`,
  `agent-display-name` (Task 6), `agent-learn-note-dispatch` (Task 10).
- Produces:
  - `agent-learn-implementation-prompt (CANDIDATE)` → string (pure).
  - `agent-learn-implement` — command bound to `i`.

- [ ] **Step 1: Write the failing tests**

Append to `test/agent-learn-test.el`:

```elisp
;;;; Implementing

(ert-deftest agent-learn-test-implement-refuses-a-pending-candidate ()
  "Only an approved candidate may be handed to a session."
  (agent-learn-test--with-file file
    (should-error (agent-learn-implementation-prompt
                   (agent-learn-test--candidate file 1))
                  :type 'user-error)))

(ert-deftest agent-learn-test-implementation-prompt-labels-the-patch ()
  "Include the proposed patch, marked as unverified."
  (agent-learn-test--with-file file
    (agent-learn-set-review (agent-learn-test--candidate file 1)
                            'approved "yes")
    (let ((prompt (agent-learn-implementation-prompt
                   (agent-learn-test--candidate file 1))))
      (should (string-match-p "audit_status=1" prompt))
      (should (string-match-p "unverified" prompt))
      (should (string-match-p "Harden ad hoc zsh loops" prompt))
      (should (string-match-p (regexp-quote file) prompt)))))

(ert-deftest agent-learn-test-implement-records-the-dispatch ()
  "Write the dispatch line only after a successful dispatch."
  (agent-learn-test--with-file file
    (agent-learn-set-review (agent-learn-test--candidate file 2)
                            'approved "yes")
    (cl-letf (((symbol-function 'agent-read-dispatch-target)
               (lambda (&rest _) 'new))
              ((symbol-function 'agent-dispatch-prompt)
               (lambda (&rest _) (current-buffer)))
              ((symbol-function 'agent-display-name)
               (lambda (&rest _) "Claude agent")))
      (agent-learn--implement (agent-learn-test--candidate file 2)))
    (should (string-match-p
             "Claude agent"
             (or (plist-get (agent-learn-test--candidate file 2) :dispatched)
                 "")))))

(ert-deftest agent-learn-test-implement-records-nothing-on-failure ()
  "Leave the file untouched when the dispatch signals."
  (agent-learn-test--with-file file
    (agent-learn-set-review (agent-learn-test--candidate file 2)
                            'approved "yes")
    (cl-letf (((symbol-function 'agent-read-dispatch-target)
               (lambda (&rest _) 'new))
              ((symbol-function 'agent-dispatch-prompt)
               (lambda (&rest _) (user-error "no session"))))
      (should-error (agent-learn--implement
                     (agent-learn-test--candidate file 2))
                    :type 'user-error))
    (should-not (plist-get (agent-learn-test--candidate file 2) :dispatched))))
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `make test 2>&1 | tail -20`
Expected: `agent-learn-implementation-prompt` is void.

- [ ] **Step 3: Implement the handoff**

Add to `agent-learn.el`:

```elisp
;;;; Implementing an approved candidate

(defconst agent-learn--implementation-preamble
  "This is a learning candidate written by an earlier agent session and
since approved by the user.  Approval means the idea is worth doing; it
is not verification that the candidate is correct.  Work out the right
change yourself, and say so if the candidate turns out to be wrong."
  "Framing sentence prepended to an implementation prompt.")

(defconst agent-learn--implementation-patch-note
  "The earlier session sketched this patch.  It is unverified and may be
stale: treat it as a hint, re-derive the change, and do not apply it as
written without checking."
  "Framing sentence introducing a proposed patch.")

(defconst agent-learn--implementation-fields
  '("Project" "Summary" "Why it matters" "Proposed action"
    "Target artifact" "Evidence" "Risk / uncertainty")
  "Candidate fields quoted into an implementation prompt, in order.")

(defun agent-learn-implementation-prompt (candidate)
  "Return the prompt handing approved CANDIDATE to a session.
Signal a `user-error' when CANDIDATE is not approved."
  (unless (eq 'approved (plist-get candidate :state))
    (user-error "Only an approved candidate can be implemented (this one is %s)"
                (plist-get candidate :state)))
  (let ((patch (agent-learn-candidate-field candidate "Proposed patch")))
    (string-join
     (delq nil
           (append
            (list agent-learn--implementation-preamble
                  (format "Candidate: %s" (plist-get candidate :title))
                  (format "Source file: %s" (plist-get candidate :file)))
            (mapcar (lambda (name)
                      (when-let* ((value (agent-learn-candidate-field
                                          candidate name)))
                        (format "%s: %s" name value)))
                    agent-learn--implementation-fields)
            (when patch
              (list agent-learn--implementation-patch-note patch))
            (list "Implement the change, or explain why it should not be \
made.  Do not edit the source file above; the review record is managed \
by Emacs.")))
     "\n\n")))

(defun agent-learn--implement (candidate)
  "Dispatch CANDIDATE to a session and record the dispatch."
  (let* ((prompt (agent-learn-implementation-prompt candidate))
         (target (agent-read-dispatch-target
                  (format "Implement `%s' in: " (plist-get candidate :title))))
         (buffer (agent-dispatch-prompt prompt target))
         (label (if (buffer-live-p buffer)
                    (agent-display-name buffer)
                  "a new session")))
    (agent-learn-note-dispatch candidate label)
    (message "Handed `%s' to %s" (plist-get candidate :title) label)
    buffer))

(defun agent-learn-implement ()
  "Hand the approved candidate at point to a session for implementation."
  (interactive nil agent-learn-mode)
  (agent-learn--implement (agent-learn--candidate-at-point))
  (agent-learn-refresh))
```

- [ ] **Step 4: Run the tests**

Run: `make test 2>&1 | tail -10`
Expected: all pass.

Run: `make compile`
Expected: no warnings.  Remove the `agent-learn-implement` forward
declaration from Task 11.

- [ ] **Step 5: Commit**

```bash
git add agent-learn.el test/agent-learn-test.el
git commit -m "agent-learn: hand an approved candidate to a session"
```

---

### Task 14: Menu and autoloads

**Files:**
- Modify: `agent.el` — split-module autoloads (~line 43) and
  `agent-menu` (~line 2676)
- Modify: `test/agent-test.el`

**Interfaces:**
- Consumes: the autoloaded commands of Tasks 6–13.
- Produces: menu entries `b`, `u`, `k` (Tools) and `L` (Prompts &
  learning).

- [ ] **Step 1: Write the failing test**

Append to `test/agent-test.el`:

```elisp
(ert-deftest agent-test-menu-includes-the-skill-and-learning-entries ()
  "Bind the four new commands in `agent-menu'."
  (require 'transient)
  (let ((commands (list #'agent-skill-run-bundle #'agent-skill-history
                        #'agent-skill-check #'agent-learn)))
    (dolist (command commands)
      (should (fboundp command)))
    (dolist (key '("b" "u" "k" "L"))
      (should (transient-get-suffix 'agent-menu key)))))
```

- [ ] **Step 2: Run the test and watch it fail**

Run: `make test 2>&1 | tail -20`
Expected: `transient-get-suffix` signals for `b`.

- [ ] **Step 3: Add the autoloads**

In `agent.el`'s "Split-module autoloads" section:

```elisp
(autoload 'agent-skill-run-bundle "agent-skill" nil t)
(autoload 'agent-skill-history "agent-skill" nil t)
(autoload 'agent-skill-check "agent-skill" nil t)
(autoload 'agent-skill-describe-session "agent-skill" nil t)
(autoload 'agent-learn "agent-learn" nil t)
(autoload 'agent-learn-archive-resolved "agent-learn" nil t)
```

- [ ] **Step 4: Extend the menu**

In `agent-menu`, replace the Tools and Prompts columns:

```elisp
   ["Tools"
    ("s" "run skill" agent-run-skill)
    ("b" "run skill bundle" agent-skill-run-bundle)
    ("u" "skill usage history" agent-skill-history)
    ("k" "check skills" agent-skill-check)
    ("n" "new CR task" agent-trajectory-new-task)
    ("c" "post-push CI" agent-post-push-ci)
    ("a" "audit project" agent-audit-project)
    ("d" "debug backtrace" agent-debug-backtrace)
    ("m" "act on Slack message" agent-act-on-slack-message)
    ("g" "act on Forge notification" agent-act-on-forge-notification)
    ""
    "Alerts"
    ("T" "toggle alert" agent-toggle-alert)]
   ["Prompts & learning"
    ("p" "capture prompt" agent-capture-prompt)
    ("i" "insert prompt" agent-insert-captured-prompt)
    ("L" "review learnings" agent-learn)]
```

- [ ] **Step 5: Run the tests**

Run: `make test 2>&1 | tail -10`
Expected: all pass.

Run: `make compile`
Expected: no warnings.

- [ ] **Step 6: Commit**

```bash
git add agent.el test/agent-test.el
git commit -m "agent: add skill bundle and learning entries to the menu"
```

---

### Task 15: Manual

**Files:**
- Modify: `README.org`
- Modify: `agent.texi` (regenerated, not hand-edited)

**Interfaces:**
- Consumes: everything above.
- Produces: two new manual sections and updated command/option indexes.

- [ ] **Step 1: Add the modules to the overview table**

In `README.org`'s module table, after the `agent-capture.el` row:

```org
| =agent-skill.el=     | Named skill bundles, provenance for dispatched instructions, a durable usage history, and a health check over the discovered skill set                                                                                    |
| =agent-learn.el=     | Review of agent-authored learning candidates: approve, reject, edit, archive, and hand an approved candidate to a session.  Records decisions; never installs a change                                                     |
```

- [ ] **Step 2: Write the "Skill bundles" section**

Add after the "Shared commands" section:

```org
* Skill bundles
:PROPERTIES:
:CUSTOM_ID: h:skill-bundles
:END:

#+findex: agent-skill-run-bundle
#+findex: agent-skill-describe-session
#+findex: agent-skill-history
#+findex: agent-skill-check
#+vindex: agent-skill-bundles
#+vindex: agent-skill-mode

A /bundle/ is a named, ordered group of skills dispatched into one
session.  ~agent-skill-run-bundle~ (=b= in the Tools column) asks which
bundle to run and where, resolves every step against the target
backend's discoverable skills, shows exactly what will be sent, and
submits it as a single message.

Bundles are configured in ~agent-skill-bundles~:

#+begin_src emacs-lisp
(setq agent-skill-bundles
      '(("review-pr"
         :description "Audit a branch before opening a PR"
         :instruction "Work on the current branch only."
         :skills ("pr-audit" ("code-audit" :args "--accept")))
        ("implement-plan"
         :description "Execute a written implementation plan"
         :skills ("build" ("post-push-ci" :optional t)))
        ("release-package"
         :description "Release an Emacs package"
         :skills ("release-package" "generate-readme"))))
#+end_src

Each ~:skills~ entry is a skill name, or a name with ~:args~ (a string
passed to that skill) and ~:optional~ (skip the step, with a note, when
the skill is not discoverable).  A missing /required/ skill aborts the
dispatch: a bundle that runs half of itself is worse than one that
refuses.  ~:backends~ restricts a bundle to particular backends and
~:instruction~ adds prose to the top of the message.

A bundle is sent as one message that names each skill file by absolute
path, in order.  That is what makes ordering behave identically on both
backends: a message can carry only one native slash expansion, so a
style-dependent rendering would work for one-skill bundles and silently
break for the rest.  Use ~agent-run-skill~ when you want the CLI's own
=/name= expansion for a single skill.

A bundle is only sent to an idle session.  A busy target is refused by
name, an unknown state is confirmed explicitly, and "dispatched" means
the message was submitted at the session's prompt — which is all a
terminal transport can attest.

** Provenance and usage history
:PROPERTIES:
:CUSTOM_ID: h:skill-provenance
:END:

For each dispatched skill, Agent records the file it came from, the
SHA-1 of that file's bytes, the git repository and commit, and whether
the file had uncommitted changes at the time.  The content hash is the
authoritative answer to "which instructions were these"; the commit
locates them in history.  Other files in a skill's directory are covered
by the commit when the repository is clean, and by the uncommitted-changes
flag when it is not — they are not hashed individually.  Git is re-read
on every dispatch and never cached, and
~agent-skill-record-git-provenance~ turns the git half off entirely.

~agent-skill-describe-session~ shows what has been dispatched into the
current session.  The durable record is ~agent-skill-history-file~, an
append-only JSON Lines file written while the global minor mode
~agent-skill-mode~ is enabled; with the mode off, bundles still work and
still show provenance, but nothing is written.  ~agent-skill-history~
(=u=) lists the records, newest first, and states how many lines it
read and how many were unparsable.  Single skills run with
~agent-run-skill~, the project audit, and before-exit skills are all
recorded through the same hook, ~agent-skill-invocation-functions~.

** Health checks
:PROPERTIES:
:CUSTOM_ID: h:skill-health
:END:

~agent-skill-check~ (=k=) reports problems in the discovered skills and
the configured bundles: unparsable frontmatter, a name that differs from
its directory, a missing description, an ~argument-source~ glob that
matches nothing, a bundle step no backend provides, and — as notes —
skills outside a git repository or with uncommitted changes.  It also
reports /shadowing/: skill discovery resolves a name collision by root
order and says nothing, so a project-level =SKILL.md= can quietly
replace a global one.  The check names the winner and every shadowed
path.  It is read-only.
```

- [ ] **Step 3: Write the "Reviewable learning" section**

```org
* Reviewable learning
:PROPERTIES:
:CUSTOM_ID: h:reviewable-learning
:END:

#+findex: agent-learn
#+findex: agent-learn-archive-resolved
#+vindex: agent-learn-directory
#+vindex: agent-learn-file-limit

Agent sessions can write /learning candidates/ — Markdown proposals
about how future sessions should behave — into an inbox.  ~agent-learn~
(=L= in the Prompts & learning column) reviews them.

*Approval records a decision; it never installs anything.*  No command
in this module edits a skill, an instructions file, a hook, or any other
target artifact, and none applies a proposed patch.  An approved
candidate reaches its target only through an ordinary session you start
on purpose, whose changes you review as usual.  Nothing is ever deleted:
archiving renames a file inside ~agent-learn-directory~.

Candidates live under ~agent-learn-directory~ in =inbox/=; reviewed
files move to =archive/YYYY-MM-DD/=.  A file has a header block and one
or more =## Candidate N: TITLE= sections of =**Field:** value=
paragraphs.  Review state is written into the file as the first
paragraph after the candidate heading:

#+begin_example
## Candidate 1: Harden ad hoc zsh loops

**Review:** approved 2026-07-31 — worth doing in agent.el

**Project:** dotfiles
#+end_example

States are =approved=, =rejected=, and =archived-unreviewed=; a
candidate with no review line is pending.  Handing a candidate to a
session adds a =**Dispatched:**= line.  Those two lines are the only
bytes this package writes; everything else in an agent-authored file is
preserved exactly.  A file with unsaved changes in a live buffer is
refused rather than saved as a side effect.

In the list buffer: =RET= shows the full candidate, =a= approves (with
an optional note), =r= rejects (a reason is required), =e= opens the
file for free editing, =A= archives the candidate's file, =i= hands an
approved candidate to a session, =t= toggles archived files, =L= changes
how many files are read, and =g= refreshes.
~agent-learn-archive-resolved~ archives every file whose candidates all
have a decision.

Reading is bounded by ~agent-learn-file-limit~ (200 files by default,
newest first), and the header line always says how many of the available
files were read, so a bounded view never reads as a complete one.
```

- [ ] **Step 4: Add the new options to the user-options section**

Add this subsection to `README.org`'s "User options" chapter, after
"Shared session behavior":

```org
** Skills and learning
:PROPERTIES:
:CUSTOM_ID: h:skill-options
:END:

#+vindex: agent-skill-bundles
~agent-skill-bundles~ (default nil) holds the named bundles; its format
is described in [[#h:skill-bundles][Skill bundles]].  No bundles are
predefined, because a default would name skills a given installation may
not have and the health check would then report errors about the
package's own configuration.

#+vindex: agent-skill-bundle-confirm
~agent-skill-bundle-confirm~ (default =t=) shows a preview buffer with
the resolved steps, their provenance, and the exact outgoing message
before dispatching.  With a nil value the dispatch is still confirmed,
in the minibuffer.

#+vindex: agent-skill-record-git-provenance
~agent-skill-record-git-provenance~ (default =t=) resolves each skill's
git repository, commit, and uncommitted-changes flag.  Set it to nil on
slow filesystems or non-git skill trees; the path, root, style, and
content hash are still recorded.

#+vindex: agent-skill-history-file
~agent-skill-history-file~ (default
=~/.emacs.d/agent/skill-history.jsonl=) is the append-only JSON Lines
file of invocation records.

#+vindex: agent-skill-history-max-bytes
~agent-skill-history-max-bytes~ (default 5242880) is the size at which
that file is renamed with a =.1= suffix and started afresh.  A nil value
never rolls over.  Nothing is deleted either way.

#+vindex: agent-skill-history-limit
~agent-skill-history-limit~ (default 200) is how many records
~agent-skill-history~ reads.

#+vindex: agent-learn-directory
~agent-learn-directory~ (default =~/.emacs.d/agent/learnings/=) holds
learning candidates in =inbox/= and reviewed files in
=archive/YYYY-MM-DD/=.  Point it at whatever directory your capture
skill writes to.

#+vindex: agent-learn-file-limit
~agent-learn-file-limit~ (default 200) is how many inbox files
~agent-learn~ reads, newest first.  The list buffer always states how
many of the available files it read.
```

- [ ] **Step 5: Update the transient-menu section**

In `README.org`'s "Transient menu" section, replace the sentence listing
the Tools and Prompts entries with:

```org
The Tools column runs a single skill (=s=), a named skill bundle (=b=),
the skill usage history (=u=) and health check (=k=), Trajectory CR task
worktree creation (=n=), post-push CI (=c=), a project audit (=a=),
backtrace debugging (=d=), and Slack and Forge action routing (=m=, =g=).
The Prompts & learning column captures a prompt (=p=), inserts a
captured prompt (=i=), and opens the learning review inbox (=L=).
```

Update the "Shared commands" `#+findex:` block in the same file to
include `agent-skill-run-bundle`, `agent-skill-history`,
`agent-skill-check`, `agent-skill-describe-session`, `agent-learn`, and
`agent-learn-archive-resolved`.

- [ ] **Step 6: Regenerate the texi export**

Run in Emacs (not batch, so Org's exporter is fully loaded):

```elisp
(with-current-buffer (find-file-noselect "README.org")
  (org-texinfo-export-to-texinfo))
```

Verify `agent.texi` changed and contains the two new nodes:

Run: `grep -c "Skill bundles\|Reviewable learning" agent.texi`
Expected: at least 4 (node, menu entry, and section headings).

- [ ] **Step 7: Commit**

```bash
git add README.org agent.texi
git commit -m "agent: document skill bundles and reviewable learning"
```

---

### Task 16: Full checks and live verification

**Files:** none changed unless a check fails.

- [ ] **Step 1: Run the full suite**

Run: `make test 2>&1 | tail -5`
Expected: `Ran N tests, N results as expected`, with N at least 362 plus
the roughly 45 tests this plan adds.

- [ ] **Step 2: Byte-compile**

Run: `make compile 2>&1`
Expected: no warnings at all.  Fix any that appear; do not silence them
with `with-suppressed-warnings`.

- [ ] **Step 3: Check the package loads cleanly from scratch**

Run: `emacs --batch --eval '(dolist (dir (file-expand-wildcards "'"$HOME"'/.config/emacs-profiles/8.3.0-dev/elpaca/builds/*/")) (add-to-list (quote load-path) dir))' --eval '(push default-directory load-path)' --eval '(progn (require (quote agent-skill)) (require (quote agent-learn)) (message "loaded"))'`
Expected: `loaded`, and no hook installed — confirm with:

Run: `emacs --batch ... --eval '(progn (require (quote agent-skill)) (message "%S" agent-skill-invocation-functions))'`
Expected: `nil`.

- [ ] **Step 4: Live — bundles, both backends**

In a real Emacs session, with `agent-skill-mode` enabled and a bundle of
two real skills configured:

1. Run `agent-skill-run-bundle` against an idle Claude session.  Confirm
   from the conversation that the model read both skill files and
   worked through them in order.
2. Repeat against an idle Codex session.
3. Run it with the target "New session…" and confirm the message arrives
   as the opening prompt.
4. Start a turn, then run the bundle against that session: confirm it is
   refused by name and nothing is sent.
5. Decline the preview confirmation: confirm nothing is sent and
   `agent-skill-history` gains no record.

- [ ] **Step 5: Live — provenance and history**

1. `touch` a change into one skill file without committing it, dispatch
   a bundle containing it, and confirm the record's commit carries the
   dirty marker in `agent-skill-history` and in
   `agent-skill-describe-session`.
2. Compare a record's `content_sha1` against
   `shasum -a 1 <path>` in a shell.
3. Run `agent-run-skill` and `agent-audit-project`, and confirm each
   produces a dispatched record followed by an outcome record with the
   same id.

- [ ] **Step 6: Live — health check**

Run `agent-skill-check` against the real skill tree.  Confirm by
inspection every reported shadowing (two roots really do provide that
name) and every frontmatter complaint.  Any false positive is a bug in
the check, not in the tree.

- [ ] **Step 7: Live — learning review**

With `agent-learn-directory` set to the real inbox
(`~/My Drive/dotfiles/.agent-learnings/`):

1. Open `agent-learn` and confirm the header states how many of the
   available files were read.
2. Approve one candidate, reject another with a reason, and confirm with
   `git diff`/`diff` that only the `**Review:**` lines changed.
3. Edit a candidate with `e`, save, and confirm the list refreshes
   correctly.
4. Archive a fully reviewed file and confirm it moved into
   `archive/YYYY-MM-DD/` and that nothing was deleted.
5. Hand one approved candidate to a session with `i`, confirm the
   session receives the prompt with the patch marked unverified, and
   confirm the `**Dispatched:**` line appears only after the dispatch
   succeeded.
6. Open one of the files in a buffer, modify it without saving, and
   confirm approving that candidate is refused by name.

- [ ] **Step 8: Confirm the tree is clean**

Every task committed its own work, so there should be nothing left.

Run: `git status --porcelain`
Expected: no output.  If anything is uncommitted, it belongs to the task
that produced it — commit it there with that task's message rather than
in a catch-all commit.

The session log under `logs/` and the "Latest session" section of
`CLAUDE.md` are written by the `update-log` skill when the user asks for
it; this plan does not write them.

