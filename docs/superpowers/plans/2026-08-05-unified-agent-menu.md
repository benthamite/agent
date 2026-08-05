# Unified Model-Agnostic `agent-menu` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `agent-menu`'s two per-backend columns with one static, model-agnostic command list in which every command works with both Claude Code and Codex.

**Architecture:** Each command that exists today for one backend moves to `agent.el` and dispatches through a new optional slot on the `agent-backend` struct; the two backend files supply the small, genuinely backend-specific piece (a transcript scan, a non-interactive runner, a fork preparation step). `codex.el` gains fork-by-session-id so Codex can fork the current session the way Claude does. The `menu-suffixes` slot and the dynamic backend columns are deleted, so no backend can add a heading to the menu again.

**Tech Stack:** Emacs Lisp, `transient`, `consult`, `ert`. Three repositories: `agent` (this one), `codex` (`../codex`, the user's), `claude-code` (`../claude-code`, read-only, never edited).

**Spec:** `docs/superpowers/specs/2026-08-05-unified-agent-menu-design.md`

## Global Constraints

- **Never edit `../claude-code/`.** It is not the user's package.
- **Never hand-edit `agent.texi`.** It is generated from `README.org` with
  `emacs -Q --batch -l ox-texinfo README.org -f org-texinfo-export-to-texinfo`.
- **Baselines that must not regress:** `agent` 386 tests passing, `make compile`
  clean; `codex` 395 tests (394 expected, 1 skipped) plus
  `codex-hook-wrapper-test.sh` and the `ground-truth` Python suite, `make compile`
  clean with `byte-compile-error-on-warn`.
- **Obsolescence version string is `"0.3"`** for every
  `define-obsolete-function-alias` / `define-obsolete-variable-alias` added here
  (`"0.2"` was the previous refactor).
- **Elisp conventions in this repo:** docstrings on every definition, first line a
  complete sentence; `when-let*`/`if-let*` over `when-let`/`if-let`; private
  names use `agent--`, `agent-claude--`, `agent-codex--`; user-facing errors use
  `user-error`, programmer errors use `error`.
- **Commit hook:** on `main` it refuses any commit that stages a non-test `.el`
  without `README.org`. Task 0 creates a branch and sets
  `deferDocUpdates` so the intermediate commits are accepted; Task 13 removes it.
- **Focused test recipe (`agent`)** — the Makefile has no selector support, so
  run one test with:

```bash
emacs --batch \
  --eval '(dolist (dir (file-expand-wildcards "~/.config/emacs-profiles/8.3.0-dev/elpaca/builds/*/")) (add-to-list (quote load-path) dir))' \
  --eval '(push default-directory load-path)' \
  -l test/agent-test.el \
  --eval '(ert-run-tests-batch-and-exit "TEST-NAME-REGEXP")'
```

- **Focused test recipe (`codex`)** — from `../codex`:

```bash
emacs -Q --batch -L . -L ../compat -L ../seq -L ../inheritenv \
  -L ../transient/lisp -L ../cond-let \
  -l codex.el -l codex-test.el \
  --eval '(ert-run-tests-batch-and-exit "TEST-NAME-REGEXP")'
```

- **Full suite:** `make test` in the repository being changed. It takes ~10s in
  `agent` and ~6s in `codex`.

## Rename table

Every move in this plan uses these names. Nothing else changes name.

| Old | New | Home |
| --- | --- | --- |
| `agent-claude--enrich-sessions` | `agent--branch-enrich-sessions` | `agent.el` |
| `agent-claude--find-branch-root` | `agent--branch-root` | `agent.el` |
| `agent-claude--build-children-map` | `agent--branch-children-map` | `agent.el` |
| `agent-claude--collect-tree-members` | `agent--branch-tree-members` | `agent.el` |
| `agent-claude--format-branch-timestamp` | `agent--branch-format-timestamp` | `agent.el` |
| `agent-claude--format-branch-tree` | `agent--branch-format-tree` | `agent.el` |
| `agent-claude--format-branch-subtree` | `agent--branch-format-subtree` | `agent.el` |
| `agent-claude--find-buffer-for-session` | `agent--buffer-for-session-id` | `agent.el` (rewritten) |
| `agent-claude--resume-session` | `agent--branch-resume-session` | `agent.el` |
| `agent-claude-switch-branch` | `agent-switch-branch` | `agent.el` |
| `agent-claude-create-branch` | `agent-create-branch` | `agent.el` |
| `agent-claude--git-toplevel` | `agent--git-toplevel` | `agent.el` |
| `agent-claude--make-fork-worktree` | `agent--make-branch-worktree` | `agent.el` |
| `agent-claude--git-worktree-add` | `agent--git-worktree-add` | `agent.el` |
| `agent-claude--confirm-kill-branches` | `agent--confirm-kill-branches` | `agent.el` (rewritten) |
| `agent-claude-warn-kill-with-branches` | `agent-warn-kill-with-branches` | `agent.el` |
| `agent-claude-fork-worktree-directory` | `agent-branch-worktree-directory` | `agent.el` |
| `agent-claude-batch-todos` | `agent-batch-todos` | `agent-todo.el` |
| `agent-claude-send-todo-at-point` | `agent-send-todo-at-point` | `agent-todo.el` |
| `agent-claude--batch-collect-todos` | `agent-todo--collect-todos` | `agent-todo.el` |
| `agent-claude--batch-format-prompt` | `agent-todo--format-prompt` | `agent-todo.el` |
| `agent-claude--org-to-markdown` | `agent-todo--org-to-markdown` | `agent-todo.el` |
| `agent-claude--collect-todo-at-point` | `agent-todo--collect-at-point` | `agent-todo.el` |
| `agent-claude--batch-start` | `agent-todo--batch-start` | `agent-todo.el` |
| `agent-claude--ensure-clean-worktree` | `agent-todo--ensure-clean-worktree` | `agent-todo.el` |
| `agent-claude--batch-run-next` | `agent-todo--batch-run-next` | `agent-todo.el` |
| `agent-claude--batch-commit-changes` | `agent-todo--batch-commit-changes` | `agent-todo.el` |
| `agent-claude--batch-finish` | `agent-todo--batch-finish` | `agent-todo.el` |
| `agent-claude--resolve-session-for-file` | `agent--session-buffer-for-project` | `agent.el` (rewritten) |
| `agent-claude-log-directory` | `agent-todo-log-directory` | `agent-todo.el` |
| `agent-claude-org-todo-in-progress-keyword` | `agent-todo-in-progress-keyword` | `agent-todo.el` |
| `agent-claude--batch-parse-stream-json` | `agent-claude--parse-stream-json` | `agent-claude.el` |
| `agent-claude--batch-process-environment` | `agent-claude--exec-process-environment` | `agent-claude.el` |

The `agent-claude-batch-*` defcustoms (`-allowed-tools`, `-permission-mode`,
`-max-turns`, `-system-prompt`, `-model`) keep their names: they are `claude -p`
knobs read by `agent-claude--build-cli-args`, they stay in `agent-claude.el`,
and renaming user-facing options would add obsolete aliases for no behavior
change.

---

### Task 0: Branch setup in both repositories

**Files:** none (git configuration only)

**Interfaces:**
- Produces: a branch in each repository on which later tasks commit.

- [ ] **Step 1: Confirm both trees are clean and baselines pass**

```bash
cd /Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent
git status --porcelain            # expect: empty
make test 2>&1 | tail -2          # expect: Ran 386 tests, 386 results as expected, 0 unexpected
cd ../codex
git status --porcelain            # expect: empty
make test 2>&1 | grep -E "^Ran"   # expect: Ran 395 tests, 394 results as expected, 0 unexpected, 1 skipped
```

- [ ] **Step 2: Create the branches**

```bash
cd /Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent
git switch -c unified-menu
git config branch.unified-menu.deferDocUpdates true
cd ../codex
git switch -c fork-by-session-id
git config branch.fork-by-session-id.deferDocUpdates true
```

---

### Task 1: `codex.el` forks a session by id

**Files:**
- Modify: `../codex/codex.el:1132-1177` (`codex-start-session`, `codex--start-session-buffer`, `codex--start-session-switches`)
- Modify: `../codex/codex-app-server.el:340-355` (startup action docstrings), `:3965-3975` (`codex--app-server-after-initialize`), `:4650-4663` (add `codex--app-server-launch-fork-session`)
- Test: `../codex/codex-test.el`

**Interfaces:**
- Produces: `codex-start-session` accepts `:fork t` alongside `:resume-id`. With a
  terminal backend it launches `codex fork <SESSION-ID>`; with the app-server
  backend it launches a session whose startup action is `fork-session`, which
  sends `thread/fork` for that session id.
- Produces: `codex--app-server-launch-fork-session (session-id &optional instance-name)`.

- [ ] **Step 1: Write the failing tests**

Append to `../codex/codex-test.el`:

```elisp
(ert-deftest codex-test-start-session-switches-fork-uses-fork-subcommand ()
  "A forked terminal-backend session runs `codex fork SESSION-ID'."
  (let ((codex-program-switches nil))
    (should (equal (codex--start-session-switches 'eat nil "abc-123" nil t)
                   '("fork" "abc-123")))))

(ert-deftest codex-test-start-session-switches-resume-is-unchanged ()
  "A resumed terminal-backend session still runs `codex resume SESSION-ID'."
  (let ((codex-program-switches nil))
    (should (equal (codex--start-session-switches 'eat nil "abc-123" nil nil)
                   '("resume" "abc-123")))))

(ert-deftest codex-test-app-server-fork-sets-pending-startup-action ()
  "Forking an app-server session pends the `fork-session' startup action."
  (let ((codex--app-server-pending-startup-action 'start)
        (codex--app-server-pending-startup-session-id nil)
        (recorded nil))
    (cl-letf (((symbol-function 'codex--launch-session)
               (lambda (&rest _)
                 (setq recorded
                       (list codex--app-server-pending-startup-action
                             codex--app-server-pending-startup-session-id))
                 (current-buffer)))
              ((symbol-function 'codex--directory) (lambda () "/tmp/p/"))
              ((symbol-function 'codex--session-instance-name)
               (lambda (&rest _) "one")))
      (codex--app-server-launch-fork-session "abc-123")
      (should (equal recorded '(fork-session "abc-123"))))))
```

Note: `codex--build-cli-args` returns model/config switches from the user's
`codex-*` options; the two switch tests bind `codex-program-switches` to nil and
assert only on the tail, so append the assertion as written only if
`codex--build-cli-args` returns nil in a `-Q` batch session. Run the test first
(Step 2); if it fails on extra leading switches, change the two assertions to
`(should (equal (last (codex--start-session-switches ...) 2) '("fork" "abc-123")))`.

- [ ] **Step 2: Run the tests to verify they fail**

```bash
cd ../codex
emacs -Q --batch -L . -L ../compat -L ../seq -L ../inheritenv \
  -L ../transient/lisp -L ../cond-let -l codex.el -l codex-test.el \
  --eval '(ert-run-tests-batch-and-exit "codex-test-\\(start-session-switches\\|app-server-fork\\)")'
```

Expected: failures — `codex--start-session-switches` takes 4 arguments, and
`codex--app-server-launch-fork-session` is void.

- [ ] **Step 3: Thread `:fork` through `codex.el`**

In `../codex/codex.el`, replace `codex-start-session`,
`codex--start-session-buffer` and `codex--start-session-switches` with:

```elisp
;;;###autoload
(cl-defun codex-start-session (&key directory instance-name initial-prompt
                                    resume-id fork terminal-backend)
  "Start a Codex session from explicit parameters and return its buffer.
DIRECTORY is the project directory, defaulting to `codex--directory'.
INSTANCE-NAME names the session instance; when nil, derive one the way
`codex' does, prompting only when instances already exist in DIRECTORY.
INITIAL-PROMPT is submitted as the first user message.  RESUME-ID
resumes the session with that id instead of starting fresh; with FORK
non-nil it forks that session into a new one instead, leaving the
original untouched.  TERMINAL-BACKEND overrides `codex-terminal-backend'
for this session; because that variable is buffer-local in session
buffers, calling this function from inside a session buffer reuses that
session's backend."
  (let* ((dir (file-name-as-directory
               (expand-file-name (or directory (codex--directory)))))
         (backend (or terminal-backend codex-terminal-backend))
         (instance (or instance-name (codex--session-instance-name dir))))
    (codex--start-session-buffer dir backend instance nil resume-id
                                 initial-prompt t fork)))

(defun codex--start-session-buffer (dir backend instance extra-switches
                                        resume-id initial-prompt switch-after
                                        &optional fork)
  "Launch a Codex session and return its buffer.
DIR, BACKEND, and INSTANCE identify the session.  EXTRA-SWITCHES are
appended CLI switches.  RESUME-ID resumes that session id, or forks it
when FORK is non-nil.  INITIAL-PROMPT is the opening user message.
SWITCH-AFTER non-nil pops to the new buffer."
  (let* ((buffer-name (codex--buffer-name-for-directory dir instance))
         (prompt-via-cli-p (and initial-prompt
                                (not resume-id)
                                (not (eq backend 'app-server))))
         (switches (codex--start-session-switches
                    backend extra-switches resume-id
                    (and prompt-via-cli-p initial-prompt)
                    fork))
         (codex--app-server-pending-startup-action
          (if (and resume-id (eq backend 'app-server))
              (if fork 'fork-session 'resume-session)
            codex--app-server-pending-startup-action))
         (codex--app-server-pending-startup-session-id
          (if (and resume-id (eq backend 'app-server))
              resume-id
            codex--app-server-pending-startup-session-id))
         (buffer (codex--launch-session dir backend buffer-name instance
                                        switches switch-after)))
    (when (and initial-prompt (not prompt-via-cli-p))
      (codex--send-command-to-buffer initial-prompt buffer))
    buffer))

(defun codex--start-session-switches (backend extra-switches resume-id
                                              initial-prompt &optional fork)
  "Return CLI switches for BACKEND, EXTRA-SWITCHES, RESUME-ID, INITIAL-PROMPT.
FORK non-nil turns a RESUME-ID into a `codex fork' of that session."
  (cond
   ((eq backend 'app-server)
    (codex--build-backend-switches 'app-server extra-switches))
   (resume-id
    (append codex-program-switches
            (codex--build-cli-args)
            (list (if fork "fork" "resume") resume-id)
            extra-switches))
   (t
    (codex--build-backend-switches
     backend
     (append extra-switches
             (when initial-prompt (list initial-prompt)))))))
```

- [ ] **Step 4: Add the app-server fork launcher**

In `../codex/codex-app-server.el`, add after
`codex--app-server-launch-resume-session` (currently ending at line 4661):

```elisp
(defun codex--app-server-launch-fork-session (session-id &optional instance-name)
  "Launch an app-server Codex session forking SESSION-ID.
The forked thread starts as a copy of SESSION-ID and diverges from it;
SESSION-ID itself is left untouched.  When INSTANCE-NAME is non-nil, use
it for the new buffer instead of prompting."
  (let* ((dir (codex--directory))
         (instance-name (or instance-name (codex--session-instance-name dir)))
         (buffer-name (codex--buffer-name-for-directory dir instance-name))
         (codex--app-server-pending-startup-action 'fork-session)
         (codex--app-server-pending-startup-session-id session-id))
    (codex--launch-session dir 'app-server buffer-name instance-name
                           (codex--build-backend-switches 'app-server nil) t)))
```

Extend the resume-by-id path to carry a method. Replace
`codex--app-server-begin-resume-session-id` (currently at line 4030) with:

```elisp
(defun codex--app-server-begin-resume-session-id (session-id &optional method)
  "Resume SESSION-ID in the current app-server buffer.
METHOD defaults to `thread/resume'; pass `thread/fork' to fork
SESSION-ID into a new thread instead of continuing it."
  (let ((file (codex--find-session-transcript session-id)))
    (if (not file)
        (codex--app-server-insert-status
         (format "No Codex transcript found for session %s" session-id))
      (codex--app-server-send-resume
       (or method "thread/resume")
       `((id . ,session-id)
         (path . ,file))))))
```

In `codex--app-server-after-initialize` (line 3968), add the new action:

```elisp
(defun codex--app-server-after-initialize ()
  "Continue app-server startup after initialize-time setup."
  (pcase codex--app-server-startup-action
    ('resume (codex--app-server-begin-resume "thread/resume"))
    ('resume-session
     (codex--app-server-begin-resume-session-id
      codex--app-server-startup-session-id))
    ('fork-session
     (codex--app-server-begin-resume-session-id
      codex--app-server-startup-session-id "thread/fork"))
    ('fork (codex--app-server-begin-resume "thread/fork"))
    (_ (codex--app-server-send-thread-start))))
```

Update both startup-action docstrings at lines 341-348 to list the new value:

```elisp
(defvar codex--app-server-pending-startup-action 'start
  "Startup action for the next app-server session.
One of `start', `resume', `resume-session', `fork', or `fork-session'.
`resume' and `fork' prompt for a thread; `resume-session' and
`fork-session' act on a known session id.")

(defvar-local codex--app-server-startup-action 'start
  "Startup action for this app-server buffer.
One of `start', `resume', `resume-session', `fork', or `fork-session'.
`resume' and `fork' prompt for a thread; `resume-session' and
`fork-session' act on a known session id.")
```

- [ ] **Step 5: Run the focused tests, then the full suite**

```bash
cd ../codex
emacs -Q --batch -L . -L ../compat -L ../seq -L ../inheritenv \
  -L ../transient/lisp -L ../cond-let -l codex.el -l codex-test.el \
  --eval '(ert-run-tests-batch-and-exit "codex-test-\\(start-session-switches\\|app-server-fork\\)")'
make test 2>&1 | grep -E "^Ran|unexpected"
make compile
```

Expected: 3 new tests pass; `Ran 398 tests, 397 results as expected, 0 unexpected, 1 skipped`; compile silent.

- [ ] **Step 6: Commit and push**

```bash
cd ../codex
git add codex.el codex-app-server.el codex-test.el
git commit -m "codex: fork a session by id from codex-start-session"
```

Do not merge or push yet — Task 12 lands both halves in order.

---

### Task 2: New backend slots

**Files:**
- Modify: `agent.el:123-137` (the `agent-backend` struct), `agent.el:155-179` (the `agent-register-backend` docstring)
- Test: `test/agent-test.el`

**Interfaces:**
- Produces: five optional slots and their accessors —
  `agent-backend-resume`, `agent-backend-session-headers`,
  `agent-backend-session-prompt`, `agent-backend-exec-prompt`,
  `agent-backend-prepare-fork`.
- Slot contracts (documented here, implemented in Tasks 3, 4, 6, 8, 9):
  - `resume`: `(ARG)` — resume a past session of this backend, prompting the
    user; ARG is a raw prefix argument meaning "the most recent session".
  - `session-headers`: `(BUFFER &optional DESCENDANTS-OF)` — return a hash table
    mapping session id to a header plist with `:session-id`, `:forked-from`,
    `:timestamp` and any backend-private keys. With DESCENDANTS-OF non-nil the
    result need only be complete enough to find that session's descendants,
    which lets a backend bound an expensive scan.
  - `session-prompt`: `(HEADER)` — return HEADER enriched with `:first-prompt`,
    keeping `:session-id` and `:forked-from` readable.
  - `exec-prompt`: `(PROMPT &rest KWARGS)` with `:dir` and `:callback`; the
    callback receives a plist with `:exit-code`, `:duration`, `:text` and
    `:raw`, optionally `:cost` and `:session-id`.
  - `prepare-fork`: `(SESSION-ID FROM-DIR TO-DIR)` — prepare the backend to fork
    SESSION-ID, recorded under FROM-DIR, inside TO-DIR.

- [ ] **Step 1: Write the failing test**

Add to `test/agent-test.el`, next to the other registry tests:

```elisp
(ert-deftest agent-test-backend-accepts-the-new-capability-slots ()
  "Register a backend that supplies every slot the unified menu dispatches on."
  (let ((agent-backends nil))
    (agent-register-backend
     'stub
     :buffer-p #'ignore
     :find-all-buffers #'ignore
     :start-session #'ignore
     :resume #'ignore
     :session-headers #'ignore
     :session-prompt #'ignore
     :exec-prompt #'ignore
     :prepare-fork #'ignore)
    (let ((struct (agent-backend 'stub)))
      (should (agent-backend-resume struct))
      (should (agent-backend-session-headers struct))
      (should (agent-backend-session-prompt struct))
      (should (agent-backend-exec-prompt struct))
      (should (agent-backend-prepare-fork struct)))))

(ert-deftest agent-test-backend-capability-slots-are-optional ()
  "A backend that supplies none of the new slots still registers."
  (let ((agent-backends nil))
    (agent-register-backend
     'stub :buffer-p #'ignore :find-all-buffers #'ignore
     :start-session #'ignore)
    (let ((struct (agent-backend 'stub)))
      (should-not (agent-backend-resume struct))
      (should-not (agent-backend-session-headers struct)))))
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
emacs --batch \
  --eval '(dolist (dir (file-expand-wildcards "~/.config/emacs-profiles/8.3.0-dev/elpaca/builds/*/")) (add-to-list (quote load-path) dir))' \
  --eval '(push default-directory load-path)' \
  -l test/agent-test.el \
  --eval '(ert-run-tests-batch-and-exit "agent-test-backend-\\(accepts\\|capability\\)")'
```

Expected: FAIL — "AI backend `stub' has unknown slot keyword `:resume'".

- [ ] **Step 3: Add the slots**

In `agent.el`, replace the struct's slot list (lines 127-137) with:

```elisp
  name label icon program
  buffer-p find-all-buffers find-buffers-for-dir
  start-session session-identity restart-options resume
  send-string send-return submit
  waiting-p busy-p background-tasks-p duration-ms display-name-suffix
  notify
  account-env-var accounts account-file shared-config-items canonical-home
  account-init
  run-prompt exec-prompt skill-roots skill-command-prefix
  session-headers session-prompt prepare-fork
  sync-theme menu-suffixes
  before-exit-ready-to-close-p before-kill-check)
```

`menu-suffixes` stays until Task 11 deletes it along with its last users.

Add to the `agent-register-backend` docstring, after the paragraph about
`:restart-options`:

```elisp
Backends that support the unified session commands provide the
optional capability keys `:resume' (resume a past session, called
with a prefix argument), `:session-headers' (return a hash table of
session id to a header plist with `:session-id', `:forked-from' and
`:timestamp', called with a session buffer and an optional session id
whose descendants are the only ones the caller needs),
`:session-prompt' (enrich one header with `:first-prompt'),
`:exec-prompt' (run a prompt non-interactively, calling back with a
plist of `:exit-code', `:duration', `:text' and `:raw'), and
`:prepare-fork' (prepare a fork of a session recorded under one
directory to run in another).  A backend that omits a key does not
support the commands that dispatch on it.
```

- [ ] **Step 4: Run the tests**

Run the Step 2 command. Expected: both tests PASS. Then `make test 2>&1 | tail -2`
— expect 388 tests, 0 unexpected.

- [ ] **Step 5: Commit**

```bash
git add agent.el test/agent-test.el
git commit -m "agent: add the capability slots the unified menu dispatches on"
```

---

### Task 3: Move the branch tree to `agent.el`, with Claude's scan behind a slot

**Files:**
- Modify: `agent.el` (add a "Branch navigation" section before the transient menu section, currently starting at line 2870)
- Modify: `agent-claude.el:2191-2300` (delete the moved helpers), `:225-246` (registration), add `agent-claude--session-headers`, `agent-claude--session-prompt`, `agent-claude--prepare-fork`
- Test: `test/agent-test.el`, `test/agent-claude-test.el`

**Interfaces:**
- Consumes: `agent-backend-session-headers`, `agent-backend-session-prompt` (Task 2).
- Produces: `agent--branch-root (session-id sessions)`,
  `agent--branch-children-map (sessions)`,
  `agent--branch-tree-members (root-id children-map)`,
  `agent--branch-enrich-sessions (backend headers member-ids)`,
  `agent--branch-format-tree (root-id sessions children-map current-id)` →
  alist of `(DISPLAY . SESSION-ID)`,
  `agent--branch-format-timestamp (iso-ts)`,
  `agent--branch-format-subtree (id sessions children-map current-id prefix child-prefix)`.
- Produces: Claude registers `:session-headers`, `:session-prompt`,
  `:prepare-fork`.

- [ ] **Step 1: Write the failing tests**

Add to `test/agent-test.el`:

```elisp
;;;; Branch navigation

(defun agent-test--branch-sessions (specs)
  "Return a session hash table from SPECS, a list of (ID PARENT TIMESTAMP)."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (spec specs table)
      (puthash (nth 0 spec)
               (list :session-id (nth 0 spec)
                     :forked-from (nth 1 spec)
                     :timestamp (nth 2 spec))
               table))))

(ert-deftest agent-test-branch-root-follows-the-fork-chain ()
  "Walk up the fork chain to the session that has no recorded parent."
  (let ((sessions (agent-test--branch-sessions
                   '(("a" nil "2026-08-01T10:00:00Z")
                     ("b" "a" "2026-08-01T11:00:00Z")
                     ("c" "b" "2026-08-01T12:00:00Z")))))
    (should (equal (agent--branch-root "c" sessions) "a"))
    (should (equal (agent--branch-root "a" sessions) "a"))))

(ert-deftest agent-test-branch-root-stops-on-an-unknown-parent ()
  "Treat a parent outside the scanned set as the top of the chain."
  (let ((sessions (agent-test--branch-sessions '(("b" "missing" nil)))))
    (should (equal (agent--branch-root "b" sessions) "b"))))

(ert-deftest agent-test-branch-children-are-sorted-by-timestamp ()
  "Order each parent's children oldest first."
  (let* ((sessions (agent-test--branch-sessions
                    '(("a" nil "2026-08-01T10:00:00Z")
                      ("c" "a" "2026-08-01T12:00:00Z")
                      ("b" "a" "2026-08-01T11:00:00Z"))))
         (map (agent--branch-children-map sessions)))
    (should (equal (gethash "a" map) '("b" "c")))))

(ert-deftest agent-test-branch-tree-members-collect-every-descendant ()
  "Collect the root and everything reachable from it."
  (let* ((sessions (agent-test--branch-sessions
                    '(("a" nil nil) ("b" "a" nil) ("c" "b" nil))))
         (members (agent--branch-tree-members
                   "a" (agent--branch-children-map sessions))))
    (should (= (hash-table-count members) 3))
    (should (gethash "c" members))))

(ert-deftest agent-test-branch-format-tree-marks-the-current-session ()
  "Draw the tree with connectors and a marker on the current session."
  (let* ((sessions (make-hash-table :test #'equal)))
    (puthash "a" '(:session-id "a" :forked-from nil :first-prompt "root"
                   :timestamp nil)
             sessions)
    (puthash "b" '(:session-id "b" :forked-from "a" :first-prompt "child"
                   :timestamp nil)
             sessions)
    (let* ((tree (agent--branch-format-tree
                  "a" sessions (agent--branch-children-map sessions) "b")))
      (should (equal (mapcar #'cdr tree) '("a" "b")))
      (should (string-match-p "\\`root" (car (nth 0 tree))))
      (should (string-match-p "└─ child" (car (nth 1 tree))))
      (should (string-suffix-p " *" (car (nth 1 tree)))))))

(ert-deftest agent-test-branch-enrich-sessions-uses-the-backend-slot ()
  "Enrich only the tree members, through the backend's session-prompt slot."
  (let ((agent-backends nil)
        (headers (agent-test--branch-sessions '(("a" nil nil) ("b" "a" nil))))
        (members (make-hash-table :test #'equal)))
    (puthash "a" t members)
    (agent-register-backend
     'stub :buffer-p #'ignore :find-all-buffers #'ignore
     :start-session #'ignore
     :session-prompt (lambda (header)
                       (append (list :first-prompt "enriched") header)))
    (let ((enriched (agent--branch-enrich-sessions 'stub headers members)))
      (should (= (hash-table-count enriched) 1))
      (should (equal (plist-get (gethash "a" enriched) :first-prompt)
                     "enriched"))
      (should (equal (plist-get (gethash "a" enriched) :session-id) "a")))))
```

Add to `test/agent-claude-test.el`:

```elisp
(ert-deftest agent-claude-test-session-headers-scan-the-transcript-project ()
  "Scan the project directory named by the buffer's status file."
  (let ((scanned nil))
    (cl-letf (((symbol-function 'agent-claude--parse-status-file)
               (lambda () '(:session_id "abc"
                            :transcript_path "/tmp/proj/abc.jsonl")))
              ((symbol-function 'agent-claude-cli-scan-session-headers)
               (lambda (dir) (setq scanned dir) 'headers)))
      (should (eq (agent-claude--session-headers (current-buffer)) 'headers))
      (should (equal scanned "/tmp/proj/")))))

(ert-deftest agent-claude-test-session-headers-without-a-status-file ()
  "Return nil rather than signalling when the status file is unavailable."
  (cl-letf (((symbol-function 'agent-claude--parse-status-file)
             (lambda () nil)))
    (should-not (agent-claude--session-headers (current-buffer)))))
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
emacs --batch \
  --eval '(dolist (dir (file-expand-wildcards "~/.config/emacs-profiles/8.3.0-dev/elpaca/builds/*/")) (add-to-list (quote load-path) dir))' \
  --eval '(push default-directory load-path)' \
  -l test/agent-test.el -l test/agent-claude-test.el \
  --eval '(ert-run-tests-batch-and-exit "\\(agent-test-branch\\|agent-claude-test-session-headers\\)")'
```

Expected: FAIL — `agent--branch-root` and friends are void.

- [ ] **Step 3: Move the tree helpers into `agent.el`**

Cut these functions from `agent-claude.el` and paste them into `agent.el` under a
new `;;;; Branch navigation` section placed immediately before
`;;;; Transient menu` (currently line 2870), renaming them per the rename table
and changing nothing else in their bodies:

- `agent-claude--find-branch-root` (2204-2216) → `agent--branch-root`
- `agent-claude--build-children-map` (2218-2237) → `agent--branch-children-map`
- `agent-claude--collect-tree-members` (2239-2249) → `agent--branch-tree-members`
- `agent-claude--format-branch-timestamp` (2251-2257) → `agent--branch-format-timestamp`
- `agent-claude--format-branch-tree` (2259-2265) → `agent--branch-format-tree`
- `agent-claude--format-branch-subtree` (2267-2292) → `agent--branch-format-subtree`

Inside `agent--branch-format-tree`, update the call to
`agent-claude--format-branch-subtree` → `agent--branch-format-subtree`; inside
`agent--branch-format-subtree`, update its recursive call to itself and its call
to `agent-claude--format-branch-timestamp` → `agent--branch-format-timestamp`.

`agent.el` requires `iso8601` for `agent--branch-format-timestamp`; add
`(require 'iso8601)` next to the other requires at the top of `agent.el` if
`make compile` reports `iso8601-parse` as undefined in Step 5.

Then write the one helper that changes, in the same new section:

```elisp
(defun agent--branch-enrich-sessions (backend headers member-ids)
  "Enrich BACKEND's session HEADERS with prompt text for MEMBER-IDS.
HEADERS is a hash table of session id to header plist, MEMBER-IDS a hash
table of the session ids to keep.  Return a new hash table of enriched
plists, each still carrying `:session-id' and `:forked-from' so the tree
can be rebuilt from it."
  (let ((enrich (or (when-let* ((struct (agent-backend backend)))
                      (agent-backend-session-prompt struct))
                    #'identity))
        (table (make-hash-table :test #'equal)))
    (maphash (lambda (id header)
               (when (gethash id member-ids)
                 (puthash id (funcall enrich header) table)))
             headers)
    table))
```

- [ ] **Step 4: Add Claude's slot implementations**

In `agent-claude.el`, in the `;;;;; Branch navigation` section (where the moved
functions used to live), add:

```elisp
(defun agent-claude--session-headers (buffer &optional _descendants-of)
  "Return session headers for BUFFER's Claude project directory.
Return nil when the status file is unavailable, since the project
directory is only known from its transcript path.  DESCENDANTS-OF is
accepted for the `session-headers' slot contract and ignored: the scan
is already limited to one project directory and reads only each file's
first line."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when-let* ((status (agent-claude--parse-status-file))
                  (transcript (plist-get status :transcript_path)))
        (agent-claude-cli-scan-session-headers
         (file-name-directory transcript))))))

(defun agent-claude--session-prompt (header)
  "Return HEADER enriched with its first prompt and timestamp."
  (agent-claude-cli-read-session-prompt header))

(defun agent-claude--prepare-fork (session-id from-dir to-dir)
  "Link SESSION-ID, recorded under FROM-DIR, into TO-DIR's Claude project.
Claude Code stores transcripts per project directory, so a fork that
runs in a different directory cannot see its parent session until the
transcript is linked into the new project."
  (agent-claude-cli-link-session-into-project session-id from-dir to-dir))
```

Add to the `agent-register-backend` call for `claude-code` (line 225-246):

```elisp
  :session-headers #'agent-claude--session-headers
  :session-prompt #'agent-claude--session-prompt
  :prepare-fork #'agent-claude--prepare-fork
```

`agent-claude-switch-branch`, `agent-claude-create-branch`,
`agent-claude--find-buffer-for-session`, `agent-claude--resume-session` and
`agent-claude--enrich-sessions` still exist and still call the old names — they
are replaced in Tasks 5 and 6. To keep the file loadable in between, leave
`agent-claude--enrich-sessions` where it is and point the four remaining
functions at the new names:

- in `agent-claude--enrich-sessions`: unchanged.
- in `agent-claude-switch-branch`: `agent-claude--build-children-map` →
  `agent--branch-children-map`, `agent-claude--find-branch-root` →
  `agent--branch-root`, `agent-claude--collect-tree-members` →
  `agent--branch-tree-members`, `agent-claude--format-branch-tree` →
  `agent--branch-format-tree`.
- in `agent-claude--confirm-kill-branches`: the same three renames.

- [ ] **Step 5: Run the tests and compile**

```bash
make test 2>&1 | tail -2
make compile
```

Expected: 396 tests, 0 unexpected; compile silent.

- [ ] **Step 6: Commit**

```bash
git add agent.el agent-claude.el test/agent-test.el test/agent-claude-test.el
git commit -m "agent: move the branch tree out of the Claude backend"
```

---

### Task 4: Codex session headers and prompts

**Files:**
- Modify: `agent-codex.el` (new `;;;;; Session headers` section before `;;;; Minor mode`), registration at `:140-170`
- Test: `test/agent-codex-test.el`

**Interfaces:**
- Consumes: the `session-headers` / `session-prompt` slot contracts (Task 2).
- Produces: `agent-codex--session-headers (buffer &optional descendants-of)`,
  `agent-codex--session-prompt (header)`,
  `agent-codex--session-id-from-file (file)`,
  `agent-codex--read-session-header (file dir)`,
  `agent-codex--first-user-prompt (file)`.

- [ ] **Step 1: Write the failing tests**

Add to `test/agent-codex-test.el`:

```elisp
;;;; Session headers

(defun agent-codex-test--write-rollout (dir id meta &optional lines)
  "Write a rollout file for session ID under DIR and return its path.
META is an alist merged into the session_meta payload.  LINES is a list
of extra JSON strings appended after the meta line."
  (let* ((file (expand-file-name
                (format "rollout-2026-08-05T08-08-27-%s.jsonl" id) dir))
         (payload (append meta `((session_id . ,id)
                                 (timestamp . "2026-08-05T11:08:27.217Z")))))
    (make-directory dir t)
    (with-temp-file file
      (insert (json-encode `((timestamp . "2026-08-05T11:08:31.433Z")
                             (type . "session_meta")
                             (payload . ,payload)))
              "\n")
      (dolist (line (or lines '()))
        (insert line "\n")))
    file))

(ert-deftest agent-codex-test-session-id-comes-from-the-file-name ()
  "Take a thread's id from its file name, not the payload's session_id.
Subagent rollouts record the parent's id in `session_id', so trusting
the payload would collapse distinct threads onto one key."
  (should (equal (agent-codex--session-id-from-file
                  "/x/rollout-2026-08-05T08-08-27-019fd19c-44b9-7042-93b6-e4f7e21036ad.jsonl")
                 "019fd19c-44b9-7042-93b6-e4f7e21036ad"))
  (should-not (agent-codex--session-id-from-file "/x/notes.jsonl")))

(ert-deftest agent-codex-test-session-headers-keep-sessions-of-this-project ()
  "Keep rollouts whose cwd is the buffer's project and drop the others."
  (let* ((root (make-temp-file "codex-sessions" t))
         (codex-transcript-sessions-directory root))
    (unwind-protect
        (progn
          (agent-codex-test--write-rollout
           root "019fd19c-44b9-7042-93b6-e4f7e21036ad"
           `((cwd . "/tmp/mine")))
          (agent-codex-test--write-rollout
           root "019fd19c-44b9-7042-93b6-e4f7e2103bbb"
           `((cwd . "/tmp/other")))
          (let ((headers (agent-codex--scan-session-headers "/tmp/mine/")))
            (should (= (hash-table-count headers) 1))
            (should (gethash "019fd19c-44b9-7042-93b6-e4f7e21036ad" headers))))
      (delete-directory root t))))

(ert-deftest agent-codex-test-session-headers-skip-subagent-threads ()
  "Skip subagent rollouts: they are forks, but not branches to navigate."
  (let* ((root (make-temp-file "codex-sessions" t))
         (codex-transcript-sessions-directory root))
    (unwind-protect
        (progn
          (agent-codex-test--write-rollout
           root "019fd19c-44b9-7042-93b6-e4f7e21036ad"
           `((cwd . "/tmp/mine") (thread_source . "subagent")))
          (should (= (hash-table-count
                      (agent-codex--scan-session-headers "/tmp/mine/"))
                     0)))
      (delete-directory root t))))

(ert-deftest agent-codex-test-session-headers-read-fork-parents ()
  "Read `forked_from_id' as the parent, ignoring a self-referential one."
  (let* ((root (make-temp-file "codex-sessions" t))
         (codex-transcript-sessions-directory root)
         (child "019fd19c-44b9-7042-93b6-e4f7e21036ad")
         (self "019fd19c-44b9-7042-93b6-e4f7e2103bbb"))
    (unwind-protect
        (progn
          (agent-codex-test--write-rollout
           root child `((cwd . "/tmp/mine") (forked_from_id . "parent-id")))
          (agent-codex-test--write-rollout
           root self `((cwd . "/tmp/mine") (forked_from_id . ,self)))
          (let ((headers (agent-codex--scan-session-headers "/tmp/mine/")))
            (should (equal (plist-get (gethash child headers) :forked-from)
                           "parent-id"))
            (should-not (plist-get (gethash self headers) :forked-from))))
      (delete-directory root t))))

(ert-deftest agent-codex-test-first-user-prompt-skips-injected-messages ()
  "Return the first human prompt, not the instructions Codex injects."
  (let* ((root (make-temp-file "codex-sessions" t))
         (codex-transcript-sessions-directory root)
         (file (agent-codex-test--write-rollout
                root "019fd19c-44b9-7042-93b6-e4f7e21036ad"
                '((cwd . "/tmp/mine"))
                (list
                 (json-encode
                  '((type . "response_item")
                    (payload . ((type . "message") (role . "user")
                                (content . [((type . "input_text")
                                             (text . "# AGENTS.md instructions for /x"))])))))
                 (json-encode
                  '((type . "response_item")
                    (payload . ((type . "message") (role . "user")
                                (content . [((type . "input_text")
                                             (text . "Fix the failing test"))])))))))))
    (unwind-protect
        (should (equal (agent-codex--first-user-prompt file)
                       "Fix the failing test"))
      (delete-directory root t))))

(ert-deftest agent-codex-test-session-prompt-falls-back-to-no-prompt ()
  "Render a session with no human message as `(no prompt)'."
  (let* ((root (make-temp-file "codex-sessions" t))
         (codex-transcript-sessions-directory root)
         (file (agent-codex-test--write-rollout
                root "019fd19c-44b9-7042-93b6-e4f7e21036ad"
                '((cwd . "/tmp/mine"))))
         (header (list :session-id "019fd19c-44b9-7042-93b6-e4f7e21036ad"
                       :forked-from nil :file-path file)))
    (unwind-protect
        (let ((enriched (agent-codex--session-prompt header)))
          (should (equal (plist-get enriched :first-prompt) "(no prompt)"))
          (should (equal (plist-get enriched :session-id)
                         "019fd19c-44b9-7042-93b6-e4f7e21036ad")))
      (delete-directory root t))))
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
emacs --batch \
  --eval '(dolist (dir (file-expand-wildcards "~/.config/emacs-profiles/8.3.0-dev/elpaca/builds/*/")) (add-to-list (quote load-path) dir))' \
  --eval '(push default-directory load-path)' \
  -l test/agent-codex-test.el \
  --eval '(ert-run-tests-batch-and-exit "agent-codex-test-\\(session-\\|first-user\\)")'
```

Expected: FAIL — `agent-codex--session-id-from-file` is void.

- [ ] **Step 3: Implement the scan**

Add to `agent-codex.el`, in a new `;;;;; Session headers` section placed before
`;;;; Minor mode`:

```elisp
(defconst agent-codex--injected-prompt-prefixes
  '("# AGENTS.md" "<environment_context>" "<user_instructions>")
  "Prefixes of the messages Codex injects before the user's first prompt.
These arrive as user-role messages in the transcript but are not
anything the user typed.")

(defun agent-codex--session-id-from-file (file)
  "Return the session id encoded in rollout FILE's name, or nil.
The id is taken from the file name rather than the payload's
`session_id' because subagent rollouts record the parent's id there."
  (let ((name (file-name-base file)))
    (when (and (> (length name) 36)
               (string-match-p
                "\\`[0-9a-f]\\{8\\}-[0-9a-f]\\{4\\}-[0-9a-f]\\{4\\}-\
[0-9a-f]\\{4\\}-[0-9a-f]\\{12\\}\\'"
                (substring name -36)))
      (substring name -36))))

(defun agent-codex--same-directory-p (a b)
  "Return non-nil when directories A and B name the same place."
  (and (stringp a) (stringp b)
       (equal (file-truename (file-name-as-directory a))
              (file-truename (file-name-as-directory b)))))

(defun agent-codex--read-session-header (file dir)
  "Return a header plist for rollout FILE when its session ran in DIR.
Return nil for files from another directory, for subagent threads,
and for anything unparseable.  Only the first line, which holds the
`session_meta' record, is read."
  (condition-case nil
      (with-temp-buffer
        (let ((coding-system-for-read 'utf-8))
          (insert-file-contents file nil 0 8192))
        (goto-char (point-min))
        (let* ((line (buffer-substring-no-properties
                      (point) (line-end-position)))
               (json (json-parse-string line :object-type 'plist))
               (payload (plist-get json :payload))
               (id (agent-codex--session-id-from-file file))
               (parent (plist-get payload :forked_from_id)))
          (when (and id payload
                     (not (equal (plist-get payload :thread_source)
                                 "subagent"))
                     (agent-codex--same-directory-p
                      (plist-get payload :cwd) dir))
            (list :session-id id
                  :forked-from (unless (equal parent id) parent)
                  :timestamp (plist-get payload :timestamp)
                  :file-path file))))
    (error nil)))

(defun agent-codex--scan-session-headers (dir &optional since)
  "Return a hash of session id to header plist for sessions run in DIR.
SINCE, when non-nil, is a time value; rollout files last modified
before it are skipped, which is what bounds the scan when only a
session's descendants matter."
  (let ((table (make-hash-table :test #'equal))
        (root (expand-file-name codex-transcript-sessions-directory)))
    (when (file-directory-p root)
      (dolist (file (directory-files-recursively
                     root "\\`rollout-.*\\.jsonl\\'"))
        (when (or (null since)
                  (time-less-p since (file-attribute-modification-time
                                      (file-attributes file))))
          (when-let* ((header (agent-codex--read-session-header file dir)))
            (puthash (plist-get header :session-id) header table)))))
    table))

(defun agent-codex--session-headers (buffer &optional descendants-of)
  "Return Codex session headers for BUFFER's project directory.
With DESCENDANTS-OF, bound the scan to files newer than that session's
own rollout file, which is enough to find its descendants and avoids
reading every rollout on disk."
  (when (buffer-live-p buffer)
    (let ((dir (with-current-buffer buffer default-directory))
          (since (when descendants-of
                   (when-let* ((file (codex--find-session-transcript
                                      descendants-of))
                               (attrs (file-attributes file)))
                     (file-attribute-modification-time attrs)))))
      (agent-codex--scan-session-headers dir since))))

(defun agent-codex--user-prompt-from-line (line)
  "Return the human prompt text in rollout LINE, or nil."
  (condition-case nil
      (let* ((json (json-parse-string line :object-type 'plist))
             (payload (plist-get json :payload)))
        (when (and (equal (plist-get payload :type) "message")
                   (equal (plist-get payload :role) "user"))
          (let* ((content (plist-get payload :content))
                 (text (when (and (vectorp content) (> (length content) 0))
                         (plist-get (aref content 0) :text))))
            (when (and (stringp text)
                       (not (string-empty-p (string-trim text)))
                       (not (seq-some
                             (lambda (prefix) (string-prefix-p prefix text))
                             agent-codex--injected-prompt-prefixes)))
              (string-trim text)))))
    (error nil)))

(defun agent-codex--first-user-prompt (file)
  "Return the first human prompt in rollout FILE, or nil."
  (when (and file (file-readable-p file))
    (with-temp-buffer
      (let ((coding-system-for-read 'utf-8))
        (insert-file-contents file))
      (goto-char (point-min))
      (catch 'found
        (while (not (eobp))
          (when-let* ((text (agent-codex--user-prompt-from-line
                             (buffer-substring-no-properties
                              (point) (line-end-position)))))
            (throw 'found text))
          (forward-line 1))
        nil))))

(defun agent-codex--session-prompt (header)
  "Return HEADER enriched with the session's first prompt.
The prompt is truncated to one short line, matching how the Claude
backend renders branch trees."
  (append (list :first-prompt
                (if-let* ((text (agent-codex--first-user-prompt
                                 (plist-get header :file-path))))
                    (truncate-string-to-width
                     (replace-regexp-in-string "[\n\r\t]+" " " text)
                     60 nil nil "…")
                  "(no prompt)"))
          header))
```

Add to the `agent-register-backend` call for `codex`:

```elisp
  :session-headers #'agent-codex--session-headers
  :session-prompt #'agent-codex--session-prompt
```

- [ ] **Step 4: Run the tests and compile**

Run the Step 2 command — expect all six PASS. Then:

```bash
make test 2>&1 | tail -2
make compile
```

Expected: 402 tests, 0 unexpected; compile silent.

- [ ] **Step 5: Sanity-check the scan against real data**

```bash
emacs --batch \
  --eval '(dolist (dir (file-expand-wildcards "~/.config/emacs-profiles/8.3.0-dev/elpaca/builds/*/")) (add-to-list (quote load-path) dir))' \
  --eval '(push default-directory load-path)' \
  -l agent-codex.el \
  --eval '(let ((t0 (float-time))
                (h (agent-codex--scan-session-headers default-directory)))
            (message "%d sessions for this project in %.2fs"
                     (hash-table-count h) (- (float-time) t0)))'
```

Expected: a non-zero count in roughly one second. A count of zero means the cwd
comparison is wrong — check `file-truename` handling of the `~/My Drive` symlink
before continuing.

- [ ] **Step 6: Commit**

```bash
git add agent-codex.el test/agent-codex-test.el
git commit -m "agent: read Codex fork lineage from rollout transcripts"
```

---

### Task 5: `agent-switch-branch`

**Files:**
- Modify: `agent.el` (Branch navigation section), `agent-claude.el:2294-2356` (delete `--find-buffer-for-session`, `agent-claude-switch-branch`, `--resume-session`; add the obsolete alias)
- Test: `test/agent-test.el`

**Interfaces:**
- Consumes: `agent--branch-root`, `agent--branch-children-map`,
  `agent--branch-tree-members`, `agent--branch-enrich-sessions`,
  `agent--branch-format-tree` (Task 3); `agent-backend-session-headers` (Task 2).
- Produces: `agent-switch-branch` (interactive, autoloaded),
  `agent--session-identity (buffer &optional backend)`,
  `agent--buffer-for-session-id (session-id)`,
  `agent--branch-resume-session (backend session-id)`.

- [ ] **Step 1: Write the failing tests**

Add to `test/agent-test.el`:

```elisp
(ert-deftest agent-test-buffer-for-session-id-matches-the-session-struct ()
  "Find the live buffer whose session struct carries the given id."
  (let ((buffer (generate-new-buffer " *agent-test-session*")))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (setq-local agent--session
                        (agent-session-create :backend 'stub :id "abc")))
          (cl-letf (((symbol-function 'agent-session-buffers)
                     (lambda () (list buffer))))
            (should (eq (agent--buffer-for-session-id "abc") buffer))
            (should-not (agent--buffer-for-session-id "zzz"))))
      (kill-buffer buffer))))

(ert-deftest agent-test-switch-branch-refuses-a-lone-session ()
  "Say so rather than opening a one-entry picker."
  (let ((agent-backends nil)
        (buffer (generate-new-buffer " *agent-test-session*")))
    (unwind-protect
        (progn
          (agent-register-backend
           'stub :buffer-p (lambda (buf) (eq buf buffer))
           :find-all-buffers (lambda () (list buffer))
           :start-session #'ignore
           :session-identity (lambda (_buf) "abc")
           :session-headers
           (lambda (_buf &optional _d)
             (let ((table (make-hash-table :test #'equal)))
               (puthash "abc" '(:session-id "abc" :forked-from nil) table)
               table)))
          (with-current-buffer buffer
            (setq-local agent--backend 'stub)
            (should-error (agent-switch-branch) :type 'user-error)))
      (kill-buffer buffer))))

(ert-deftest agent-test-switch-branch-switches-to-a-live-branch ()
  "Switch to the selected branch's existing buffer instead of resuming it."
  (let ((agent-backends nil)
        (parent (generate-new-buffer " *agent-test-parent*"))
        (child (generate-new-buffer " *agent-test-child*"))
        (switched nil))
    (unwind-protect
        (progn
          (with-current-buffer child
            (setq-local agent--session
                        (agent-session-create :backend 'stub :id "b")))
          (agent-register-backend
           'stub :buffer-p #'ignore
           :find-all-buffers (lambda () (list parent child))
           :start-session #'ignore
           :session-identity (lambda (_buf) "a")
           :session-prompt (lambda (header)
                             (append (list :first-prompt "p") header))
           :session-headers
           (lambda (_buf &optional _d)
             (let ((table (make-hash-table :test #'equal)))
               (puthash "a" '(:session-id "a" :forked-from nil) table)
               (puthash "b" '(:session-id "b" :forked-from "a") table)
               table)))
          (cl-letf (((symbol-function 'consult--read)
                     (lambda (candidates &rest _)
                       (cl-find-if (lambda (c) (string-match-p "└─" c))
                                   candidates)))
                    ((symbol-function 'switch-to-buffer)
                     (lambda (buf &rest _) (setq switched buf))))
            (with-current-buffer parent
              (setq-local agent--backend 'stub)
              (agent-switch-branch))
            (should (eq switched child))))
      (kill-buffer parent)
      (kill-buffer child))))
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
emacs --batch \
  --eval '(dolist (dir (file-expand-wildcards "~/.config/emacs-profiles/8.3.0-dev/elpaca/builds/*/")) (add-to-list (quote load-path) dir))' \
  --eval '(push default-directory load-path)' \
  -l test/agent-test.el \
  --eval '(ert-run-tests-batch-and-exit "agent-test-\\(buffer-for-session\\|switch-branch\\)")'
```

Expected: FAIL — `agent--buffer-for-session-id` and `agent-switch-branch` are void.

- [ ] **Step 3: Implement the command**

Add to `agent.el`'s Branch navigation section:

```elisp
(defun agent--session-identity (buffer &optional backend)
  "Return BUFFER's native session id, or nil when it is not known yet.
BACKEND defaults to BUFFER's detected backend."
  (when-let* ((backend (or backend (agent--detect-backend buffer)))
              (struct (agent-backend backend))
              (fn (agent-backend-session-identity struct)))
    (funcall fn buffer)))

(defun agent--buffer-for-session-id (session-id)
  "Return the live session buffer whose native id is SESSION-ID, or nil."
  (cl-find-if
   (lambda (buffer)
     (when-let* ((session (agent-session buffer)))
       (equal (agent-session-id session) session-id)))
   (agent-session-buffers)))

(defun agent--branch-resume-session (backend session-id)
  "Resume BACKEND's SESSION-ID in a new session buffer.
The instance name is derived from the session id so resuming never
stops to ask for one."
  (agent-start-session
   (agent-session-create
    :backend backend
    :directory default-directory
    :instance (format "branch-%s" (substring session-id 0 8)))
   :resume-id session-id))

;;;###autoload
(defun agent-switch-branch ()
  "Navigate between branches of the current session.
Show every session that shares a fork ancestor with this one as a
tree, then switch to the selected session's live buffer, or resume it
in a new buffer when it has none."
  (interactive)
  (let* ((buffer (current-buffer))
         (backend (or (agent--detect-backend buffer)
                      (user-error "Not in an AI session buffer")))
         (scan (or (when-let* ((struct (agent-backend backend)))
                     (agent-backend-session-headers struct))
                   (user-error "Backend `%s' does not track branches"
                               backend)))
         (session-id (or (agent--session-identity buffer backend)
                         (user-error "Current session has no session id")))
         (headers (or (funcall scan buffer)
                      (user-error "No sessions found for this project")))
         (root (agent--branch-root
                session-id headers))
         (members (agent--branch-tree-members
                   root (agent--branch-children-map headers))))
    (when (<= (hash-table-count members) 1)
      (user-error "No branches for this session"))
    (let* ((sessions (agent--branch-enrich-sessions backend headers members))
           (tree (agent--branch-format-tree
                  root sessions (agent--branch-children-map sessions)
                  session-id))
           (selection (consult--read (mapcar #'car tree)
                                     :prompt "Branch: "
                                     :require-match t
                                     :sort nil))
           (selected (cdr (assoc selection tree))))
      (cond
       ((equal selected session-id) (message "Already on this session"))
       ((agent--buffer-for-session-id selected)
        (switch-to-buffer (agent--buffer-for-session-id selected)))
       (t (agent--branch-resume-session backend selected))))))
```

In `agent-claude.el`, delete `agent-claude--find-buffer-for-session` (2294-2304),
`agent-claude-switch-branch` (2306-2344) and `agent-claude--resume-session`
(2346-2356), and add in their place:

```elisp
(define-obsolete-function-alias 'agent-claude-switch-branch
  #'agent-switch-branch "0.3")
```

- [ ] **Step 4: Run the tests and compile**

Run the Step 2 command — expect three PASS. Then `make test 2>&1 | tail -2` (405
tests, 0 unexpected) and `make compile`.

- [ ] **Step 5: Commit**

```bash
git add agent.el agent-claude.el test/agent-test.el
git commit -m "agent: switch branches for any backend"
```

---

### Task 6: `agent-create-branch`

**Files:**
- Modify: `agent.el` (Branch navigation section; move the worktree helpers here), `agent.el:60-71` region equivalent in `agent-claude.el` for the defcustom
- Modify: `agent-claude.el:2358-2437` (delete `agent-claude-create-branch` and the three git helpers), `agent-claude.el:60-70` (move the defcustom out)
- Modify: `agent-codex.el:259-274` (`agent-codex--start-session` accepts `:fork`)
- Test: `test/agent-test.el`, `test/agent-codex-test.el`

**Interfaces:**
- Consumes: `agent--session-identity` (Task 5); `agent-backend-prepare-fork`
  (Task 2); `codex-start-session`'s `:fork` (Task 1).
- Produces: `agent-create-branch` (interactive, autoloaded),
  `agent--git-toplevel (&optional dir)`,
  `agent--make-branch-worktree (toplevel branch-id)` → `(PATH . BRANCH-NAME)`,
  `agent--git-worktree-add (toplevel branch-name worktree-path)`,
  `agent--prepare-fork (backend session-id from-dir to-dir)`,
  defcustom `agent-branch-worktree-directory`.

- [ ] **Step 1: Write the failing tests**

Add to `test/agent-test.el`:

```elisp
(ert-deftest agent-test-create-branch-forks-the-current-session ()
  "Fork the current session id through the backend's start-session slot."
  (let ((agent-backends nil)
        (buffer (generate-new-buffer " *agent-test-session*"))
        (started nil))
    (unwind-protect
        (progn
          (agent-register-backend
           'stub :buffer-p #'ignore :find-all-buffers (lambda () (list buffer))
           :start-session (lambda (session &rest options)
                            (setq started (cons session options))
                            buffer)
           :session-identity (lambda (_buf) "abc-123"))
          (with-current-buffer buffer
            (setq-local agent--backend 'stub)
            (agent-create-branch))
          (should (equal (plist-get (cdr started) :resume-id) "abc-123"))
          (should (plist-get (cdr started) :fork))
          (should (string-prefix-p "branch-"
                                   (agent-session-instance (car started)))))
      (kill-buffer buffer))))

(ert-deftest agent-test-create-branch-outside-a-session-errors ()
  "Refuse to branch from a buffer that is not a session."
  (with-temp-buffer
    (should-error (agent-create-branch) :type 'user-error)))

(ert-deftest agent-test-prepare-fork-is-skipped-without-a-slot ()
  "Do nothing when the backend registers no fork preparation."
  (let ((agent-backends nil))
    (agent-register-backend
     'stub :buffer-p #'ignore :find-all-buffers #'ignore
     :start-session #'ignore)
    (should-not (agent--prepare-fork 'stub "abc" "/a/" "/b/"))))
```

Add to `test/agent-codex-test.el`:

```elisp
(ert-deftest agent-codex-test-start-session-passes-fork-through ()
  "Pass `:fork' on to `codex-start-session'."
  (let ((received nil))
    (cl-letf (((symbol-function 'codex-start-session)
               (lambda (&rest args) (setq received args) (current-buffer)))
              ((symbol-function 'agent--set-session) #'ignore))
      (agent-codex--start-session
       (agent-session-create :backend 'codex :directory "/tmp/p/")
       :resume-id "abc" :fork t)
      (should (plist-get received :fork))
      (should (equal (plist-get received :resume-id) "abc")))))
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
emacs --batch \
  --eval '(dolist (dir (file-expand-wildcards "~/.config/emacs-profiles/8.3.0-dev/elpaca/builds/*/")) (add-to-list (quote load-path) dir))' \
  --eval '(push default-directory load-path)' \
  -l test/agent-test.el -l test/agent-codex-test.el \
  --eval '(ert-run-tests-batch-and-exit "\\(agent-test-\\(create-branch\\|prepare-fork\\)\\|agent-codex-test-start-session-passes\\)")'
```

Expected: FAIL — `agent-create-branch` is void and `:fork` is an unknown keyword.

- [ ] **Step 3: Move the defcustom and the git helpers**

Cut `agent-claude-fork-worktree-directory` (`agent-claude.el:60-70`) into
`agent.el`'s customization section, renamed and with an alias left behind. In
`agent.el`:

```elisp
(defcustom agent-branch-worktree-directory
  (expand-file-name "~/repos/.worktrees/agent-branches/")
  "Directory under which isolated session branches create git worktrees."
  :type 'directory
  :group 'agent)
```

Use the existing default value from `agent-claude.el:60-70` verbatim rather than
the one written above if they differ; read that defcustom before deleting it.

In `agent-claude.el`, in place of the deleted defcustom:

```elisp
(define-obsolete-variable-alias 'agent-claude-fork-worktree-directory
  'agent-branch-worktree-directory "0.3")
```

Cut `agent-claude--git-toplevel` (2396-2402), `agent-claude--make-fork-worktree`
(2404-2415) and `agent-claude--git-worktree-add` (2417-2426) into `agent.el`'s
Branch navigation section, renamed per the rename table. Inside
`agent--make-branch-worktree`, rename the parameter `fork-id` to `branch-id`,
change `agent-claude-fork-worktree-directory` to
`agent-branch-worktree-directory`, change the branch name format string from
`"claude-fork-%s"` to `"agent-branch-%s"`, the worktree directory format string
from `"%s-fork-%s"` to `"%s-branch-%s"`, and the call to
`agent-claude--git-worktree-add` to `agent--git-worktree-add`.

- [ ] **Step 4: Write the command**

Add to `agent.el`'s Branch navigation section:

```elisp
(defun agent--prepare-fork (backend session-id from-dir to-dir)
  "Prepare BACKEND to fork SESSION-ID from FROM-DIR inside TO-DIR.
Backends that record sessions per project directory use this to make
the parent session visible from TO-DIR; backends that record them
globally register no `prepare-fork' slot and nothing happens."
  (when-let* ((struct (agent-backend backend))
              (fn (agent-backend-prepare-fork struct)))
    (funcall fn session-id from-dir to-dir)))

;;;###autoload
(defun agent-create-branch (&optional isolated)
  "Create a branch of the current session and switch to it.
Fork the session in this buffer and open the fork in a separate
buffer.  By default the branch shares the parent's working tree,
matching the behavior of starting a second session in the same
project.

With prefix arg ISOLATED, also create a git worktree on a fresh
branch under `agent-branch-worktree-directory' and run the fork
inside it.  The worktree starts at the parent's HEAD, so uncommitted
parent changes are NOT carried over.  Use this when concurrent
destructive git operations across branches are a concern; otherwise
the default is what you want."
  (interactive "P")
  (let* ((buffer (current-buffer))
         (backend (or (agent--detect-backend buffer)
                      (user-error "Not in an AI session buffer")))
         (session-id (or (agent--session-identity buffer backend)
                         (user-error "Current session has no session id")))
         (parent-cwd default-directory)
         (branch-id (format-time-string "%H%M%S"))
         (worktree (and isolated
                        (agent--make-branch-worktree
                         (or (agent--git-toplevel)
                             (user-error "Not in a git repo; cannot isolate"))
                         branch-id))))
    (when worktree
      (agent--prepare-fork backend session-id parent-cwd (car worktree)))
    (agent-start-session
     (agent-session-create
      :backend backend
      :directory (or (car worktree) default-directory)
      :instance (format "branch-%s" branch-id))
     :resume-id session-id
     :fork t)
    (when worktree
      (message "Branched in worktree %s on branch %s"
               (car worktree) (cdr worktree)))))
```

In `agent-claude.el`, delete `agent-claude-create-branch` (2358-2394) and add:

```elisp
(define-obsolete-function-alias 'agent-claude-create-branch
  #'agent-create-branch "0.3")
```

- [ ] **Step 5: Accept `:fork` in the Codex backend**

In `agent-codex.el`, replace `agent-codex--start-session` (259-274) with:

```elisp
(cl-defun agent-codex--start-session (session &key initial-prompt resume-id
                                              fork terminal-backend)
  "Start the Codex session described by SESSION; return its buffer.
SESSION is an `agent-session'.  INITIAL-PROMPT is submitted as the
first user message.  RESUME-ID resumes that session id, or forks it
into a new session when FORK is non-nil.  TERMINAL-BACKEND overrides
`codex-terminal-backend' for this session.  The session account is
bound as `agent-account--starting' by `agent-start-session' so
environment hooks see it at spawn time."
  (let ((buffer (codex-start-session
                 :directory (agent-session-directory session)
                 :instance-name (agent-session-instance session)
                 :initial-prompt initial-prompt
                 :resume-id resume-id
                 :fork fork
                 :terminal-backend terminal-backend)))
    (agent--set-session buffer session)
    buffer))
```

- [ ] **Step 6: Run the tests and compile**

Run the Step 2 command — expect four PASS. Then `make test 2>&1 | tail -2` (409
tests, 0 unexpected) and `make compile`.

- [ ] **Step 7: Commit**

```bash
git add agent.el agent-claude.el agent-codex.el test/agent-test.el test/agent-codex-test.el
git commit -m "agent: branch any session, in a worktree when asked"
```

---

### Task 7: Generalized branch-kill confirmation

**Files:**
- Modify: `agent.el:2763-2771` (`agent--before-kill-allowed-p`), Branch navigation section (add `agent--confirm-kill-branches`), customization section (add `agent-warn-kill-with-branches`)
- Modify: `agent-claude.el:52-58` (delete the defcustom, add the alias), `:304-329` (delete `agent-claude--confirm-kill-branches`), `:242` (drop `:before-kill-check`)
- Test: `test/agent-test.el`

**Interfaces:**
- Consumes: `agent--session-identity`, `agent--branch-children-map`,
  `agent--branch-tree-members`, `agent-backend-session-headers`.
- Produces: defcustom `agent-warn-kill-with-branches` (default `t`),
  `agent--confirm-kill-branches (buffer backend)`.

- [ ] **Step 1: Write the failing tests**

Add to `test/agent-test.el`:

```elisp
(ert-deftest agent-test-confirm-kill-branches-honors-the-option ()
  "Ask nothing when `agent-warn-kill-with-branches' is nil.
The Claude-era option was defined and toggled but never read, so this
is the behavior the toggle always claimed to have."
  (let ((agent-backends nil)
        (agent-warn-kill-with-branches nil)
        (buffer (generate-new-buffer " *agent-test-session*")))
    (unwind-protect
        (progn
          (agent-register-backend
           'stub :buffer-p #'ignore :find-all-buffers #'ignore
           :start-session #'ignore
           :session-identity (lambda (_buf) "a")
           :session-headers
           (lambda (&rest _) (error "must not scan when the option is off")))
          (should (agent--confirm-kill-branches buffer 'stub)))
      (kill-buffer buffer))))

(ert-deftest agent-test-confirm-kill-branches-allows-a-lone-session ()
  "Allow the kill without prompting when the session has no branches."
  (let ((agent-backends nil)
        (agent-warn-kill-with-branches t)
        (buffer (generate-new-buffer " *agent-test-session*")))
    (unwind-protect
        (progn
          (agent-register-backend
           'stub :buffer-p #'ignore :find-all-buffers #'ignore
           :start-session #'ignore
           :session-identity (lambda (_buf) "a")
           :session-headers
           (lambda (_buf &optional _d)
             (let ((table (make-hash-table :test #'equal)))
               (puthash "a" '(:session-id "a" :forked-from nil) table)
               table)))
          (cl-letf (((symbol-function 'yes-or-no-p)
                     (lambda (&rest _) (error "must not prompt"))))
            (should (agent--confirm-kill-branches buffer 'stub))))
      (kill-buffer buffer))))

(ert-deftest agent-test-confirm-kill-branches-prompts-with-a-count ()
  "Prompt, naming how many branches the session has, and obey the answer."
  (let ((agent-backends nil)
        (agent-warn-kill-with-branches t)
        (asked nil)
        (buffer (generate-new-buffer " *agent-test-session*")))
    (unwind-protect
        (progn
          (agent-register-backend
           'stub :buffer-p #'ignore :find-all-buffers #'ignore
           :start-session #'ignore
           :session-identity (lambda (_buf) "a")
           :session-headers
           (lambda (_buf &optional _d)
             (let ((table (make-hash-table :test #'equal)))
               (puthash "a" '(:session-id "a" :forked-from nil) table)
               (puthash "b" '(:session-id "b" :forked-from "a") table)
               table)))
          (cl-letf (((symbol-function 'yes-or-no-p)
                     (lambda (prompt) (setq asked prompt) nil)))
            (should-not (agent--confirm-kill-branches buffer 'stub))
            (should (string-match-p "1 branch" asked))))
      (kill-buffer buffer))))

(ert-deftest agent-test-confirm-kill-branches-survives-a-broken-scan ()
  "Allow the kill when the scan signals, rather than trapping the buffer."
  (let ((agent-backends nil)
        (agent-warn-kill-with-branches t)
        (buffer (generate-new-buffer " *agent-test-session*")))
    (unwind-protect
        (progn
          (agent-register-backend
           'stub :buffer-p #'ignore :find-all-buffers #'ignore
           :start-session #'ignore
           :session-identity (lambda (_buf) "a")
           :session-headers (lambda (&rest _) (error "boom")))
          (should (agent--confirm-kill-branches buffer 'stub)))
      (kill-buffer buffer))))
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
emacs --batch \
  --eval '(dolist (dir (file-expand-wildcards "~/.config/emacs-profiles/8.3.0-dev/elpaca/builds/*/")) (add-to-list (quote load-path) dir))' \
  --eval '(push default-directory load-path)' \
  -l test/agent-test.el \
  --eval '(ert-run-tests-batch-and-exit "agent-test-confirm-kill-branches")'
```

Expected: FAIL — `agent-warn-kill-with-branches` is void.

- [ ] **Step 3: Implement**

In `agent.el`'s customization section:

```elisp
(defcustom agent-warn-kill-with-branches t
  "When non-nil, warn before killing a session that has branches.
If the session being killed has other sessions forked from it, a
second confirmation prompt is shown after the standard kill-protection
prompt."
  :type 'boolean
  :group 'agent)
```

In `agent.el`'s Branch navigation section:

```elisp
(defun agent--confirm-kill-branches (buffer backend)
  "Return non-nil unless BUFFER's session has branches and the user declines.
Scan only for sessions that could descend from this one, which is what
keeps the check off the critical path when a backend stores every
session in one directory.  Any failure to scan allows the kill: a
session must never become unkillable because its transcripts moved."
  (if (not agent-warn-kill-with-branches)
      t
    (condition-case nil
        (let* ((struct (agent-backend backend))
               (scan (and struct (agent-backend-session-headers struct)))
               (session-id (and scan (agent--session-identity buffer backend))))
          (if (not session-id)
              t
            (let* ((headers (funcall scan buffer session-id))
                   (members (agent--branch-tree-members
                             session-id
                             (agent--branch-children-map headers)))
                   (count (1- (hash-table-count members))))
              (or (<= count 0)
                  (yes-or-no-p
                   (format "Session has %d %s — kill anyway? "
                           count
                           (if (= count 1) "branch" "branches")))))))
      (error t))))
```

Replace `agent--before-kill-allowed-p` (2763-2771) with:

```elisp
(defun agent--before-kill-allowed-p (backend buffer)
  "Return non-nil when killing session BUFFER is allowed by BACKEND.
The shared branch warning runs first, then the backend's own
`before-kill-check' slot, which may veto or prompt for its own
reasons."
  (let ((check (when-let* ((struct (agent-backend backend)))
                 (agent-backend-before-kill-check struct))))
    (and (with-current-buffer buffer
           (agent--confirm-kill-branches buffer backend))
         (or (null check)
             (with-current-buffer buffer
               (funcall check buffer))))))
```

In `agent-claude.el`: delete the `agent-claude-warn-kill-with-branches`
defcustom (52-58) and `agent-claude--confirm-kill-branches` (304-329), delete the
`:before-kill-check` line from the registration (242), and add next to the other
aliases:

```elisp
(define-obsolete-variable-alias 'agent-claude-warn-kill-with-branches
  'agent-warn-kill-with-branches "0.3")
```

- [ ] **Step 4: Run the tests and compile**

Run the Step 2 command — expect four PASS. Then `make test 2>&1 | tail -2` (413
tests, 0 unexpected) and `make compile`.

- [ ] **Step 5: Commit**

```bash
git add agent.el agent-claude.el test/agent-test.el
git commit -m "agent: warn about branches on kill for any backend"
```

---

### Task 8: `agent-resume`

**Files:**
- Modify: `agent.el` (Branch navigation section), `agent-claude.el` registration, `agent-codex.el` registration
- Test: `test/agent-test.el`

**Interfaces:**
- Consumes: `agent-backend-resume` (Task 2), `agent--resolve-backend` (existing).
- Produces: `agent-resume (arg)` (interactive, autoloaded). Claude registers
  `:resume #'claude-code-resume`; Codex registers `:resume #'codex-resume`.

- [ ] **Step 1: Write the failing tests**

Add to `test/agent-test.el`:

```elisp
(ert-deftest agent-test-resume-calls-the-backend-slot-with-the-prefix ()
  "Hand the raw prefix argument to the backend's resume command."
  (let ((agent-backends nil)
        (received 'unset))
    (agent-register-backend
     'stub :buffer-p #'ignore :find-all-buffers #'ignore
     :start-session #'ignore
     :resume (lambda (arg) (setq received arg)))
    (cl-letf (((symbol-function 'agent--resolve-backend) (lambda () 'stub)))
      (agent-resume '(4))
      (should (equal received '(4))))))

(ert-deftest agent-test-resume-without-a-slot-errors ()
  "Say which backend cannot resume rather than failing obscurely."
  (let ((agent-backends nil))
    (agent-register-backend
     'stub :buffer-p #'ignore :find-all-buffers #'ignore
     :start-session #'ignore)
    (cl-letf (((symbol-function 'agent--resolve-backend) (lambda () 'stub)))
      (should-error (agent-resume nil) :type 'user-error))))
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
emacs --batch \
  --eval '(dolist (dir (file-expand-wildcards "~/.config/emacs-profiles/8.3.0-dev/elpaca/builds/*/")) (add-to-list (quote load-path) dir))' \
  --eval '(push default-directory load-path)' \
  -l test/agent-test.el \
  --eval '(ert-run-tests-batch-and-exit "agent-test-resume")'
```

Expected: FAIL — `agent-resume` is void.

- [ ] **Step 3: Implement**

In `agent.el`'s Branch navigation section:

```elisp
;;;###autoload
(defun agent-resume (arg)
  "Resume a past session of the current or prompted backend.
The backend is the current session's when called from a session
buffer, and prompted for otherwise.  ARG is passed to the backend's
own resume command, where it means \"the most recent session\"."
  (interactive "P")
  (let* ((backend (agent--resolve-backend))
         (resume (or (when-let* ((struct (agent-backend backend)))
                       (agent-backend-resume struct))
                     (user-error "Backend `%s' does not support resume"
                                 backend))))
    (funcall resume arg)))
```

Add `:resume #'claude-code-resume` to the `claude-code` registration and
`:resume #'codex-resume` to the `codex` registration.

`agent-codex-resume` and `agent-codex-fork` stay defined: `agent-codex-fork`
forks a *picked past* session, which `agent-create-branch` (current session) does
not cover, and neither is aliased away. They simply no longer appear in the menu.

- [ ] **Step 4: Run the tests and compile**

Run the Step 2 command — expect two PASS. Then `make test 2>&1 | tail -2` (415
tests, 0 unexpected) and `make compile`.

- [ ] **Step 5: Commit**

```bash
git add agent.el agent-claude.el agent-codex.el test/agent-test.el
git commit -m "agent: resume past sessions of any backend"
```

---

### Task 9: `agent-todo.el`

**Files:**
- Create: `agent-todo.el`, `test/agent-todo-test.el`
- Modify: `agent.el` (add `agent--session-buffer-for-project`), `agent-claude.el` (delete the moved code, rename two internals, add aliases, register `:exec-prompt`), `agent-codex.el` (register `:exec-prompt`), `Makefile`
- Modify: `test/agent-claude-test.el` (the moved tests and the two renames)

**Interfaces:**
- Consumes: `agent-backend-exec-prompt` (Task 2), `agent-submit` (existing),
  `agent-backend-find-buffers-for-dir` (existing), `agent--resolve-backend`.
- Produces: `agent-batch-todos`, `agent-send-todo-at-point` (both interactive,
  autoloaded), defcustoms `agent-todo-log-directory` and
  `agent-todo-in-progress-keyword`, and
  `agent--session-buffer-for-project ()` in `agent.el`.

- [ ] **Step 1: Write the failing tests**

Create `test/agent-todo-test.el`:

```elisp
;;; agent-todo-test.el --- Tests for agent-todo -*- lexical-binding: t -*-

;; Tests for org TODO batching and sending.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'org)
(require 'agent-todo)

(ert-deftest agent-todo-test-loads ()
  "Loading the test file provides the `agent-todo' feature."
  (should (featurep 'agent-todo)))

(ert-deftest agent-todo-test-format-prompt-joins-title-and-body ()
  "Join a TODO's title and body with a blank line."
  (should (equal (agent-todo--format-prompt '(:title "Fix it" :body "Details"))
                 "Fix it\n\nDetails"))
  (should (equal (agent-todo--format-prompt '(:title "Fix it" :body ""))
                 "Fix it")))

(ert-deftest agent-todo-test-collect-todos-reads-the-buffer ()
  "Collect every TODO heading in the buffer."
  (with-temp-buffer
    (org-mode)
    (insert "* TODO First\nBody one\n* TODO Second\n")
    (let ((entries (agent-todo--collect-todos 'buffer)))
      (should (= (length entries) 2))
      (should (equal (plist-get (nth 0 entries) :title) "First")))))

(ert-deftest agent-todo-test-batch-runs-through-the-exec-prompt-slot ()
  "Run each entry through the resolved backend's exec-prompt slot."
  (let ((agent-backends nil)
        (prompts nil)
        (dir (make-temp-file "agent-todo" t)))
    (unwind-protect
        (progn
          (agent-register-backend
           'stub :buffer-p #'ignore :find-all-buffers #'ignore
           :start-session #'ignore
           :exec-prompt
           (lambda (prompt &rest kwargs)
             (push prompt prompts)
             (funcall (plist-get kwargs :callback)
                      (list :exit-code 0 :duration 1.0 :text "ok" :raw "{}"))))
          (cl-letf (((symbol-function 'agent-todo--batch-finish) #'ignore))
            (agent-todo--batch-run-next
             (list :backend 'stub
                   :queue '((:title "One" :body ""))
                   :results nil
                   :log-dir dir
                   :working-dir dir
                   :start-time (current-time))))
          (should (equal prompts '("One"))))
      (delete-directory dir t))))

(ert-deftest agent-todo-test-batch-tolerates-a-backend-without-cost ()
  "Sum costs as zero when the backend reports none, as `codex exec' does."
  (should (= (agent-todo--total-cost
              '((:cost 0.5) (:cost nil) (:cost 0.25)))
             0.75)))
```

Add to `test/agent-test.el`:

```elisp
(ert-deftest agent-test-session-buffer-for-project-uses-the-only-session ()
  "Return the single session running in the project without prompting."
  (let ((agent-backends nil)
        (buffer (generate-new-buffer " *agent-test-session*")))
    (unwind-protect
        (progn
          (agent-register-backend
           'stub :buffer-p #'ignore :find-all-buffers (lambda () (list buffer))
           :start-session #'ignore
           :find-buffers-for-dir (lambda (_dir) (list buffer)))
          (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil)))
            (should (eq (agent--session-buffer-for-project) buffer))))
      (kill-buffer buffer))))

(ert-deftest agent-test-session-buffer-for-project-without-sessions-errors ()
  "Say there is no session rather than returning nil into a submit call."
  (let ((agent-backends nil))
    (agent-register-backend
     'stub :buffer-p #'ignore :find-all-buffers (lambda () nil)
     :start-session #'ignore
     :find-buffers-for-dir (lambda (_dir) nil))
    (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil)))
      (should-error (agent--session-buffer-for-project) :type 'user-error))))
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
emacs --batch \
  --eval '(dolist (dir (file-expand-wildcards "~/.config/emacs-profiles/8.3.0-dev/elpaca/builds/*/")) (add-to-list (quote load-path) dir))' \
  --eval '(push default-directory load-path)' \
  -l test/agent-test.el \
  --eval '(ert-run-tests-batch-and-exit "agent-test-session-buffer-for-project")'
```

Expected: FAIL — `agent--session-buffer-for-project` is void. (`agent-todo-test.el`
cannot even load yet; that is expected.)

- [ ] **Step 3: Add the general session resolver**

In `agent.el`, next to `agent--single-session-buffer-for-dir` (line 2177):

```elisp
(defun agent--session-buffer-for-project ()
  "Return a session buffer for the current project, prompting if needed.
Ask every registered backend for its sessions in the project root,
falling back to `default-directory' when there is no project.  Use the
only match when there is one and prompt when there are several."
  (let* ((project (project-current))
         (dir (if project (project-root project) default-directory))
         (buffers (delq nil
                        (mapcan
                         (lambda (entry)
                           (when-let* ((fn (agent-backend-find-buffers-for-dir
                                            (cdr entry))))
                             (copy-sequence (funcall fn dir))))
                         agent-backends))))
    (pcase buffers
      ('nil (user-error "No AI session running in %s"
                        (abbreviate-file-name dir)))
      (`(,buffer) buffer)
      (_ (get-buffer
          (completing-read "Session: " (mapcar #'buffer-name buffers)
                           nil t))))))
```

- [ ] **Step 4: Create `agent-todo.el`**

Create `agent-todo.el` with this header and section layout, then move the bodies
listed in the rename table into it, applying only the renames:

```elisp
;;; agent-todo.el --- Org TODO workflows for AI sessions -*- lexical-binding: t -*-

;; Copyright (C) 2026

;;; Commentary:

;; Send org TODO entries to a running AI session, or process a whole
;; list of them non-interactively through the backend's `exec-prompt'
;; slot.  Both work with any registered backend.

;;; Code:

(require 'org)
(require 'agent)

;;;; Customization

(defgroup agent-todo nil
  "Org TODO workflows for AI sessions."
  :group 'agent)
```

Moved bodies, in this order, with no logic changes beyond the renames and the
three edits called out below:

1. defcustom `agent-todo-log-directory` (from `agent-claude.el:72-80`)
2. defcustom `agent-todo-in-progress-keyword` (from `agent-claude.el:1363-1379`)
3. `agent-todo--collect-todos` (from `agent-claude.el:1381-1405`)
4. `agent-todo--format-prompt` (1407-1414)
5. `agent-todo--org-to-markdown` (1462-1465)
6. `agent-todo--collect-at-point` (1467-1478)
7. `agent-todo--ensure-clean-worktree` (1520-1533)
8. `agent-todo--batch-start` (1501-1518)
9. `agent-todo--batch-run-next` (1535-1580)
10. `agent-todo--batch-commit-changes` (1582-1594)
11. `agent-todo--batch-finish` (1786-1824)
12. `agent-batch-todos` (1416-1437)
13. `agent-send-todo-at-point` (1439-1460)

End the file with:

```elisp
(provide 'agent-todo)
;;; agent-todo.el ends here
```

Three edits inside the moved code:

**(a)** `agent-batch-todos` resolves and records a backend, and its docstring
stops naming Claude:

```elisp
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
```

`agent-todo--batch-start` gains BACKEND as its first parameter and puts
`:backend backend` into the state plist. `agent-todo--batch-run-next` runs the
prompt through the slot instead of calling Claude directly — replace its
`(agent-claude--run-prompt prompt :dir ... :callback ...)` call with:

```elisp
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
                   ;; body unchanged from agent-claude--batch-run-next
                   )))
```

**(b)** `agent-send-todo-at-point` uses the general resolver and the renamed
option:

```elisp
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
```

**(c)** `agent-todo--batch-finish` tolerates a backend that reports no cost.
Rename the summary buffer from `*Claude Batch Results*` to `*Agent Batch
Results*`, and replace the two cost expressions:

```elisp
(defun agent-todo--total-cost (results)
  "Return the summed `:cost' of RESULTS, counting a missing cost as zero."
  (cl-reduce #'+ results
             :key (lambda (result) (or (plist-get result :cost) 0))
             :initial-value 0))
```

In the `let*`, `total-cost` becomes `(agent-todo--total-cost results)`; the
per-entry property line becomes:

```elisp
            (insert (format ":PROPERTIES:\n:COST: %s\n:DURATION: %.1fs\n:END:\n\n"
                            (if-let* ((cost (plist-get result :cost)))
                                (format "$%.4f" cost)
                              "—")
                            (plist-get result :duration)))
```

- [ ] **Step 5: Trim `agent-claude.el` and register `:exec-prompt`**

Delete from `agent-claude.el` every function and defcustom moved in Step 4, plus
`agent-claude--resolve-session-for-file` (1480-1499). Add next to the other
aliases:

```elisp
(define-obsolete-function-alias 'agent-claude-batch-todos
  #'agent-batch-todos "0.3")
(define-obsolete-function-alias 'agent-claude-send-todo-at-point
  #'agent-send-todo-at-point "0.3")
(define-obsolete-variable-alias 'agent-claude-log-directory
  'agent-todo-log-directory "0.3")
(define-obsolete-variable-alias 'agent-claude-org-todo-in-progress-keyword
  'agent-todo-in-progress-keyword "0.3")
```

Rename `agent-claude--batch-parse-stream-json` → `agent-claude--parse-stream-json`
and `agent-claude--batch-process-environment` →
`agent-claude--exec-process-environment` (definitions, the two call sites inside
`agent-claude--run-prompt`, and the five tests in `test/agent-claude-test.el` at
lines 625-765).

Move the tests for the moved functions out of `test/agent-claude-test.el` into
`test/agent-todo-test.el`, renaming them from `agent-claude-test-*` to
`agent-todo-test-*`: the three `--batch-format-prompt` tests (401-415) and the
five `--batch-collect-todos` tests (960-1005). These supersede the two
provisional tests written in Step 1 — delete
`agent-todo-test-format-prompt-joins-title-and-body` and
`agent-todo-test-collect-todos-reads-the-buffer`, which exist only to drive the
file into being. Net: three new tests in `agent-todo-test.el` (`-loads`,
`-batch-runs-through-the-exec-prompt-slot`, `-batch-tolerates-a-backend-without-cost`)
plus the eight moved ones.

Add `:exec-prompt #'agent-claude--run-prompt` to the `claude-code` registration
and `:exec-prompt #'agent-codex--run-prompt` to the `codex` registration.

- [ ] **Step 6: Update the Makefile**

```make
SRC := agent.el agent-account.el agent-capture.el agent-slack.el agent-snippet.el agent-forge.el agent-todo.el agent-claude-cli.el agent-claude.el agent-codex.el agent-chief.el
TEST_FILES := test/agent-test.el test/agent-account-test.el test/agent-capture-test.el test/agent-slack-test.el test/agent-snippet-test.el test/agent-todo-test.el test/agent-claude-cli-test.el test/agent-claude-test.el test/agent-codex-test.el test/agent-chief-test.el
```

`agent-forge.el` was missing from `SRC` and so was never byte-compiled; adding it
may surface pre-existing warnings. Fix any that appear — they are in scope
because `make compile` must be clean.

- [ ] **Step 7: Run the tests and compile**

```bash
make test 2>&1 | tail -2
make compile
```

Expected: 420 tests (415 + 3 new in `agent-todo-test.el` + 2 new in
`agent-test.el`; the 8 moved tests keep their count), 0 unexpected; compile
silent. If the count differs, reconcile it before committing — a test that
vanished in the move is a test that stopped running.

- [ ] **Step 8: Commit**

```bash
git add agent-todo.el test/agent-todo-test.el agent.el agent-claude.el agent-codex.el test/agent-test.el test/agent-claude-test.el Makefile
git commit -m "agent: run org TODO workflows through any backend"
```

---

### Task 10: One account infix

**Files:**
- Modify: `agent.el` (infix class section, near `agent--boolean-variable` at line 2860)
- Modify: `agent-claude.el:2445-2449` and `agent-codex.el:852-857` (delete the two infixes — done in Task 11 with their menu entries; only the new one is added here)
- Test: `test/agent-test.el`

**Interfaces:**
- Consumes: `agent-account-variable` (`agent-account.el`), `agent-account-current`,
  `agent-account-set`, `agent-account-sync`, `agent-account--prompt`,
  `agent--resolve-backend`.
- Produces: `agent--account-variable` (transient class), `agent--infix-account`
  (transient infix), `agent--account-summary ()` → string.

- [ ] **Step 1: Write the failing tests**

Add to `test/agent-test.el`:

```elisp
(ert-deftest agent-test-account-summary-lists-every-backend ()
  "Show one backend per entry, sorted, with its current account."
  (let ((agent-backends nil))
    (agent-register-backend
     'zeta :buffer-p #'ignore :find-all-buffers #'ignore :start-session #'ignore)
    (agent-register-backend
     'alpha :buffer-p #'ignore :find-all-buffers #'ignore :start-session #'ignore)
    (cl-letf (((symbol-function 'agent-account-current)
               (lambda (backend) (when (eq backend 'alpha) "work"))))
      (should (equal (agent--account-summary) "alpha: work  zeta: default")))))
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
emacs --batch \
  --eval '(dolist (dir (file-expand-wildcards "~/.config/emacs-profiles/8.3.0-dev/elpaca/builds/*/")) (add-to-list (quote load-path) dir))' \
  --eval '(push default-directory load-path)' \
  -l test/agent-test.el \
  --eval '(ert-run-tests-batch-and-exit "agent-test-account-summary")'
```

Expected: FAIL — `agent--account-summary` is void.

- [ ] **Step 3: Implement**

In `agent.el`, next to `agent--boolean-variable`:

```elisp
(defun agent--account-summary ()
  "Return a one-line summary of every backend's current account."
  (mapconcat (lambda (entry)
               (format "%s: %s"
                       (car entry)
                       (or (agent-account-current (car entry)) "default")))
             (sort (copy-sequence agent-backends)
                   (lambda (a b) (string< (symbol-name (car a))
                                          (symbol-name (car b)))))
             "  "))

(eval-and-compile
  (defclass agent--account-variable (agent-account-variable)
    ((backend :initarg :backend :initform nil))
    "An infix showing every backend's account and setting one of them.
The backend acted on is resolved when the infix is invoked, so the
same entry works from a session buffer of either backend and prompts
only when the context does not name one."))

(cl-defmethod transient-init-value ((obj agent--account-variable))
  "Initialize OBJ's value from the accounts of every backend."
  (oset obj value (agent--account-summary)))

(cl-defmethod transient-infix-read ((obj agent--account-variable))
  "Resolve a backend for OBJ, then prompt for one of its accounts."
  (let ((backend (agent--resolve-backend)))
    (oset obj backend backend)
    (agent-account--prompt backend)))

(cl-defmethod transient-infix-set ((obj agent--account-variable) value)
  "Persist VALUE as the account of OBJ's backend and re-render the summary."
  (when value
    (agent-account-set (oref obj backend) value)
    (agent-account-sync (oref obj backend) value))
  (oset obj value (agent--account-summary)))

(transient-define-infix agent--infix-account ()
  "Select the account of the current or prompted backend."
  :class 'agent--account-variable
  :description "account")
```

- [ ] **Step 4: Run the test and compile**

Run the Step 2 command — expect PASS. Then `make test 2>&1 | tail -2` (421 tests,
0 unexpected) and `make compile`.

- [ ] **Step 5: Commit**

```bash
git add agent.el test/agent-test.el
git commit -m "agent: select any backend's account from one infix"
```

---

### Task 11: The unified menu

**Files:**
- Modify: `agent.el:2884-2940` (the prefix and the backend-column machinery), `agent.el:127-137` (drop `menu-suffixes`)
- Modify: `agent-claude.el:2437-2461` (delete the infixes and the suffix function, drop the registration key), `agent-codex.el:852-866` (same)
- Test: `test/agent-test.el:2512-2519` (replace `agent-test-menu-backend-children`)

**Interfaces:**
- Consumes: `agent-resume`, `agent-create-branch`, `agent-switch-branch`,
  `agent-batch-todos`, `agent-send-todo-at-point`, `agent--infix-account`,
  `agent-warn-kill-with-branches`.
- Produces: a static `agent-menu` with no dynamic group; `menu-suffixes`,
  `agent-menu--backend-children`, `agent-menu--backend-column` and
  `agent-menu--sorted-backends` no longer exist.

- [ ] **Step 1: Write the failing test**

Replace `agent-test-menu-backend-children` (2512-2519) in `test/agent-test.el`
with:

```elisp
(defun agent-test--menu-keys ()
  "Return every key bound in `agent-menu', flattened."
  (let ((keys nil))
    (letrec ((walk (lambda (node)
                     (cond
                      ((vectorp node) (mapc walk (append node nil)))
                      ((listp node)
                       (when-let* ((key (plist-get (nthcdr 2 node) :key)))
                         (push key keys))
                       (mapc walk (nthcdr 2 node)))))))
      (funcall walk (get 'agent-menu 'transient--layout)))
    (nreverse keys)))

(ert-deftest agent-test-menu-has-no-backend-column ()
  "Build the whole menu statically, with no per-backend group."
  (should-not (fboundp 'agent-menu--backend-children))
  (should-not (fboundp 'agent-menu--backend-column))
  (should-not (memq 'menu-suffixes
                    (mapcar #'car (cdr (cl-struct-slot-info 'agent-backend))))))

(ert-deftest agent-test-menu-binds-the-unified-commands ()
  "Bind every unified session command in the static layout."
  (let ((keys (agent-test--menu-keys)))
    (dolist (key '("R" "N" "B" "b" "t" "-c" "-w"))
      (should (member key keys)))
    (should-not (member "F" keys))
    (should-not (member "u" keys))
    (should-not (member "U" keys))
    (should-not (member "-x" keys))))
```

If `agent-test--menu-keys` returns nothing because transient's layout shape
differs from the walker's assumption, print the layout once
(`(pp (get 'agent-menu 'transient--layout))`) and adjust the walker to that
shape before continuing — the test must actually read the built menu.

- [ ] **Step 2: Run the tests to verify they fail**

```bash
emacs --batch \
  --eval '(dolist (dir (file-expand-wildcards "~/.config/emacs-profiles/8.3.0-dev/elpaca/builds/*/")) (add-to-list (quote load-path) dir))' \
  --eval '(push default-directory load-path)' \
  -l test/agent-test.el \
  --eval '(ert-run-tests-batch-and-exit "agent-test-menu-\\(has-no\\|binds\\)")'
```

Expected: FAIL — `agent-menu--backend-children` is still bound and `R` is not in
the static layout.

- [ ] **Step 3: Rewrite the prefix**

In `agent.el`, replace the whole `transient-define-prefix agent-menu` form and the
three helper functions after it (2884-2940) with:

```elisp
;;;###autoload (autoload 'agent-menu "agent" nil t)
(transient-define-prefix agent-menu ()
  "Dispatch AI session commands."
  [["Sessions"
    ("e" "start or switch" agent-start-or-switch)
    ("w" "jump to waiting" agent-jump-to-waiting)
    ("R" "resume" agent-resume)
    ("N" "new branch" agent-create-branch)
    ("B" "switch branch" agent-switch-branch)
    ("h" "handoff" agent-handoff)
    ("x" "exit session" agent-exit)
    ("r" "restart" agent-restart)
    ("l" "history" agent-history)
    ""
    "Buffer"
    ("K" "setup kill on exit" agent-setup-kill-on-exit)
    ("f" "fix rendering" agent-fix-rendering)
    ("S" "disable scrollback" agent-disable-scrollback-truncation)]
   ["Tools"
    ("s" "run skill" agent-run-skill)
    ("n" "new CR task" agent-trajectory-new-task)
    ("c" "post-push CI" agent-post-push-ci)
    ("a" "audit project" agent-audit-project)
    ("d" "debug backtrace" agent-debug-backtrace)
    ("m" "act on Slack message" agent-act-on-slack-message)
    ("g" "act on Forge notification" agent-act-on-forge-notification)
    ""
    "Alerts"
    ("T" "toggle alert" agent-toggle-alert)]
   ["Prompts"
    ("p" "capture prompt" agent-capture-prompt)
    ("i" "insert prompt" agent-insert-captured-prompt)
    ("b" "batch todos" agent-batch-todos)
    ("t" "send todo at point" agent-send-todo-at-point)]
   ["Options"
    ("-A" agent--infix-alert-on-ready)
    ("-p" agent--infix-protect-buffers)
    ("-t" agent--infix-sync-theme)
    ("-c" agent--infix-account)
    ("-w" agent--infix-warn-kill-with-branches)]])
```

`agent-batch-todos` and `agent-send-todo-at-point` live in `agent-todo.el`, which
`agent.el` does not require. Add autoload cookies to both (Task 9 already
specifies them) and declare them next to the other forward declarations in
`agent.el`:

```elisp
(declare-function agent-batch-todos "agent-todo" ())
(declare-function agent-send-todo-at-point "agent-todo" ())
```

Add the boolean infix for the branch warning next to the other option infixes:

```elisp
(transient-define-infix agent--infix-warn-kill-with-branches ()
  "Toggle `agent-warn-kill-with-branches'."
  :class 'agent--boolean-variable
  :variable 'agent-warn-kill-with-branches
  :description "warn kill with branches")
```

Delete `agent-menu--backend-children`, `agent-menu--sorted-backends` and
`agent-menu--backend-column` outright, and remove `menu-suffixes` from the struct
slot list (line 136).

- [ ] **Step 4: Delete the backend menu contributions**

In `agent-claude.el`, delete the `;;;; Extend unified menu` section
(2437-2461): both infixes and `agent-claude--menu-suffixes`. Remove
`:menu-suffixes #'agent-claude--menu-suffixes` from the registration.

In `agent-codex.el`, delete the account infix and
`agent-codex--menu-suffixes` (852-866). Remove
`:menu-suffixes #'agent-codex--menu-suffixes` from the registration.

- [ ] **Step 5: Run the tests and compile**

Run the Step 2 command — expect both PASS. Then:

```bash
make test 2>&1 | tail -2
make compile
```

Expected: 422 tests (421 + 2 new menu tests − 1 deleted
`agent-test-menu-backend-children`), 0 unexpected; compile silent.

- [ ] **Step 6: Commit**

```bash
git add agent.el agent-claude.el agent-codex.el test/agent-test.el
git commit -m "agent: build one model-agnostic menu"
```

---

### Task 12: Documentation, and landing both halves

**Files:**
- Modify: `README.org` (lines 175, 196, 268, 443, 466, 494-502 and the customization sections listing the renamed options)
- Regenerate: `agent.texi`
- Modify: `../codex/README.org` (the `codex-start-session` description)

**Interfaces:**
- Consumes: everything above.
- Produces: documentation matching the shipped behavior; both branches merged.

- [ ] **Step 1: Update `README.org` in `agent`**

Make these edits, each in the section named:

1. **Line 466 (backend slot list):** replace the tail of the sentence so it reads
   `… skills (~run-prompt~, ~exec-prompt~, ~skill-roots~, ~skill-command-prefix~),
   session history (~session-headers~, ~session-prompt~, ~resume~,
   ~prepare-fork~), integration hooks (~sync-theme~), and exit safety
   (~before-exit-ready-to-close-p~, ~before-kill-check~).`
2. **Lines 494-502 (Transient menu section):** replace the first paragraph, which
   still describes the pre-refactor `transient-append-suffix` mechanism and the
   per-backend columns, with a description of the static menu: four columns,
   every command backend-agnostic, dispatch through backend slots, no mechanism
   for a backend to add entries. State that `-c` selects the account of the
   current or prompted backend and shows every backend's current account.
3. **Line 268 (agent-menu overview):** delete "Backend modules append their own
   suffixes to the same menu when loaded" and add resume, branch creation, branch
   switching, batch TODOs and TODO sending to the list of shared entries.
4. **Line 175 (Claude options):** drop `agent-claude-warn-kill-with-branches`,
   `agent-claude-log-directory`, `agent-claude-org-todo-in-progress-keyword` and
   `agent-claude-fork-worktree-directory`; note they are now
   `agent-warn-kill-with-branches`, `agent-todo-log-directory`,
   `agent-todo-in-progress-keyword` and `agent-branch-worktree-directory`, with
   the old names kept as obsolete aliases.
5. **Line 196 (Codex options):** note that the Codex account is selected through
   the shared account infix.
6. **Line 443 (Codex restart):** replace the last sentence about
   `agent-codex-resume` / `agent-codex-fork` "from the unified menu" — they are
   no longer in it — with a sentence saying `agent-resume` resumes either
   backend's sessions and `agent-create-branch` forks the current session of
   either backend, Codex through `codex fork` and `thread/fork`.
7. **New subsection** under the session documentation describing branch
   navigation across backends: what `agent-create-branch` does with and without a
   prefix argument, what `agent-switch-branch` shows, where each backend's
   lineage comes from (Claude's per-project transcripts, Codex's rollout
   `forked_from_id`), and that Codex subagent threads are deliberately excluded.
8. **New subsection** for `agent-todo.el`: `agent-batch-todos`,
   `agent-send-todo-at-point`, the two options, and that batch runs through the
   backend's `exec-prompt` slot so cost is reported only where the CLI reports it.
9. **Line 26 table:** add a row for `agent-todo.el`.

- [ ] **Step 2: Regenerate `agent.texi`**

```bash
emacs -Q --batch -l ox-texinfo README.org -f org-texinfo-export-to-texinfo
git diff --stat agent.texi     # expect: agent.texi changed
```

- [ ] **Step 3: Update `codex`'s README**

In `../codex/README.org`, find the `codex-start-session` documentation and add
`:fork` to its keyword list: with `:resume-id`, it forks that session instead of
continuing it, using `codex fork` on the terminal backends and `thread/fork` on
the app-server backend. Regenerate `codex.texi` the same way if that repository
generates it from `README.org` (check for a `codex.texi` target or an existing
`#+TEXINFO` header before running the export).

- [ ] **Step 4: Verify both suites once more, then commit the docs**

```bash
cd ../codex && make test 2>&1 | grep -E "^Ran" && make compile
cd ../agent && make test 2>&1 | tail -2 && make compile
```

```bash
cd ../codex
git add README.org codex.texi
git commit -m "docs: describe forking a session by id"
cd ../agent
git add README.org agent.texi
git commit -m "docs: describe the unified model-agnostic menu"
```

- [ ] **Step 5: Land `codex` first, then `agent`**

The `agent` half calls `codex-start-session` with `:fork`, which is a
`cl-defun` error against a `codex.el` that lacks the keyword. Land and reload the
`codex` half first.

```bash
cd ../codex
git switch main && git merge --no-ff fork-by-session-id -m "Merge fork-by-session-id"
git config --unset branch.fork-by-session-id.deferDocUpdates
git branch -d fork-by-session-id
git push
```

Confirm the running Emacs has the new `codex.el` before merging `agent`:

```bash
emacsclient -e '(fboundp (quote codex--app-server-launch-fork-session))'
```

Expected: `t`. If it is `nil`, wait for the post-commit rebuild to finish and
re-check rather than proceeding.

```bash
cd ../agent
git switch main && git merge --no-ff unified-menu -m "Merge unified-menu"
git config --unset branch.unified-menu.deferDocUpdates
git branch -d unified-menu
```

Do not push `agent` until Task 13 passes.

---

### Task 13: Live verification

**Files:** none

**Interfaces:**
- Consumes: the merged work in the user's running Emacs.

Every check runs against the live Emacs through `emacsclient`. A failure here is
a bug to fix and re-verify, not a note to file. Do not report the work as done
until every box is ticked.

- [ ] **Step 1: The menu is static and correctly keyed**

Read the built layout out of the live Emacs — `agent-test--menu-keys` is a test
helper and is not loaded there:

```bash
emacsclient -e '(pp-to-string (get (quote agent-menu) (quote transient--layout)))'
```

Expected: four columns; `R`, `N`, `B` in Sessions; `b`, `t` in Prompts; `-c`,
`-w` in Options; no group titled "Claude Code" or "Codex"; no `u`, `U`, `F` or
`-x`.

- [ ] **Step 2: Claude branch round trip**

In a live Claude session buffer:

```bash
emacsclient -e '(with-current-buffer "BUFFER-NAME" (call-interactively (function agent-create-branch)))'
```

Expected: a new Claude buffer named `…branch-HHMMSS…` resuming the parent's
conversation. Then from the new buffer:

```bash
emacsclient -e '(with-current-buffer "NEW-BUFFER-NAME" (agent--session-identity (current-buffer)))'
```

Expected: a session id different from the parent's. Then run
`agent-switch-branch` from the parent buffer and confirm the picker lists both
sessions with the current one marked ` *`.

- [ ] **Step 3: Codex branch round trip, both terminal backends**

Repeat Step 2 in a Codex session with `codex-terminal-backend` set to
`app-server`, then again with the default terminal backend. Confirm the forked
Codex buffer shows the parent's history, and that `agent-switch-branch` from it
lists the parent.

```bash
emacsclient -e '(with-current-buffer "CODEX-BUFFER" (hash-table-count (agent-codex--session-headers (current-buffer))))'
```

Expected: a count matching the number of Codex sessions this project has had.

- [ ] **Step 4: Isolated branch in a worktree, both backends**

```bash
emacsclient -e '(with-current-buffer "BUFFER-NAME" (let ((current-prefix-arg (quote (4)))) (call-interactively (function agent-create-branch))))'
```

Expected: a new worktree under `agent-branch-worktree-directory` on branch
`agent-branch-HHMMSS`, and a session running inside it that can see the parent's
conversation. This is the path most likely to fail for Codex, where the session
was recorded under a different `cwd`; if the fork starts empty, that is a real
bug in the `:fork` path, not an acceptable difference.

Remove the worktrees created by this check when done:

```bash
git worktree list
git worktree remove PATH
git branch -d agent-branch-HHMMSS
```

- [ ] **Step 5: Resume**

```bash
emacsclient -e '(with-current-buffer "CLAUDE-BUFFER" (call-interactively (function agent-resume)))'
emacsclient -e '(with-current-buffer "CODEX-BUFFER" (call-interactively (function agent-resume)))'
```

Expected: each opens its own backend's resume picker, with no backend prompt.

- [ ] **Step 6: TODO workflows against Codex**

From an org buffer with a TODO heading, with a Codex session running in the
project:

```bash
emacsclient -e '(with-current-buffer "TODO.org" (call-interactively (function agent-send-todo-at-point)))'
```

Expected: the prompt arrives in the Codex session, and the heading's state
changes when `agent-todo-in-progress-keyword` is set. Then run
`agent-batch-todos` over a two-entry region with the backend resolved to Codex,
and confirm the `*Agent Batch Results*` buffer shows both entries with an em
dash in the cost property rather than an error.

- [ ] **Step 7: The account infix**

```bash
emacsclient -e '(agent--account-summary)'
```

Expected: `claude-code: NAME  codex: NAME`. Open `agent-menu` from a Claude
session buffer, press `-c`, and confirm it prompts for a Claude account with no
backend prompt; repeat from a Codex buffer; repeat from a non-session buffer and
confirm it prompts for the backend first. After a change, confirm
`agent-account-current` reports the new account and the config home was synced.

- [ ] **Step 8: Kill warning, on and off**

With a session that has a branch:

```bash
emacsclient -e '(setq agent-warn-kill-with-branches t)'
```

Kill it and confirm the prompt names the branch count. Then:

```bash
emacsclient -e '(setq agent-warn-kill-with-branches nil)'
```

Kill another branched session and confirm no branch prompt appears — the
behavior the toggle never had before. Restore the option to `t` afterwards.

- [ ] **Step 9: Push**

Only after every box above is ticked:

```bash
cd /Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent
git push
```

---

## Self-review notes

- **Spec coverage:** menu layout (Task 11), resume (8), create branch (6), switch
  branch (5), batch todos and todo-at-point (9), account infix (10), warn-kill
  option and its dead-option bug (7), struct slots added and `menu-suffixes`
  removed (2, 11), `codex.el` fork by id (1), Codex lineage scan with its three
  format quirks (4), `agent-todo.el` and the Makefile (9), README/texi (12),
  landing order (12), the eight live checks (13).
- **Deliberate omission:** the spec's "cache the header scan per directory keyed
  by the newest file's mtime" is not implemented. The kill check is bounded by
  `descendants-of`, which is the case that runs unattended; `agent-switch-branch`
  is an explicit user action that pays a measured 0.82s. Add the cache only if
  Step 3 of Task 13 shows it is slow in practice.
