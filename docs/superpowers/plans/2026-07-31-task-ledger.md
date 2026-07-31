# Durable Task Ledger Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

Revision 2.  Revision 1 was reviewed and found not implementation-ready
on thirteen counts; this revision closes them without changing the
feature.  Three were reproduced in batch before being fixed:

1. The body codec was **not injective** — `" * a bullet"` decoded to
   `"* a bullet"`, so a dispatched prompt could differ from the stored
   instruction.  Task 1 now uses `^ *\*` / `^ +\*`, proved to round-trip
   six shapes exactly.
2. `grep -c 'agent-tasks.el'` over the planned Makefile returns **1**,
   not the 2 Task 12 expected, because `test/agent-tasks-test.el` does
   not contain that literal.  Task 12 now uses two exact anchored
   checks.
3. `write-region` with `'excl` does give an atomic exclusive create that
   signals `file-already-exists`, which is what Task 2's new
   interprocess lock rests on.

The rest: write atomicity across processes, duplicate-id rejection, a
centrally enforced transition matrix, commit-time revalidation against
the reviewed snapshot, binding bijection checked before the send,
post-start identity repair, a restart failure finalizer, `submit` no
longer treated as evidence, one owner per attention item, refresh always
reconciling, the required account/deps/age fields, task order so every
task compiles, and live-verification isolation.

**Goal:** Give `agent` a small durable ledger of tasks that survives an
Emacs restart, records which session each running task is bound to, and
never infers completion or retries a run on its own — per
`docs/superpowers/specs/2026-07-31-task-ledger-design.md`.

**Architecture:** One new optional module, `agent-tasks.el`, holding an
Org-file store, a six-state machine whose evidence transitions are
strictly limited, a dispatcher, and a `tabulated-list-mode` UI.
`agent.el` gains two menu entries and their autoloads and nothing else.
Every other module — `agent-chief.el`, `agent-claude.el`,
`agent-attention.el`, `agent-queue.el`, `agent-context.el`,
`agent-skill.el`, `agent-learn.el`, `agent-log` — is untouched, and all
integration is one-directional and guarded with `fboundp`/`boundp`.

**Tech Stack:** Emacs Lisp 30, `org-mode` as a data format,
`tabulated-list-mode`, `cl-lib`, ERT.

## Global Constraints

These apply to every task.  They restate the spec's non-negotiables.

- **Nothing starts work on its own.**  Every transition into `RUNNING`
  is caused by an interactive command.  There is exactly one dispatch
  path.  No timer, no scheduler, no dependency-driven start.
- **Nothing is ever retried automatically.**  An ambiguous end produces
  `UNKNOWN` with a recorded reason and stops there.
- **Completion is never inferred.**  A `stop`/`idle-prompt` event
  appends a `Log` line and changes no state.  No code path other than
  `agent-tasks-mark-done` may write `DONE`.
- **Evidence never produces `RUNNING` from `UNKNOWN`.**  The only
  evidence transition into `RUNNING` is `BLOCKED` → `RUNNING` for a
  binding that is already live.
- **Every write goes through `agent-tasks--update-task`**, which always:
  holds the interprocess lock for the whole read-check-edit-rename
  sequence, refuses when a modified buffer visits the ledger, refuses
  when the file's **raw-byte** token differs from the parse the caller
  holds, edits in a temp `org-mode` buffer with `org-mode-hook`,
  `org-after-todo-state-change-hook`, `org-log-done` and
  `org-todo-log-states` bound to nil and `org-inhibit-logging` bound to
  `t`, and replaces the file through a temporary file in the same
  directory plus `rename-file`.  Creating the ledger is part of the same
  locked, atomic protocol.
- **`agent-tasks-transition` is the only function that changes a state**
  and it validates every call against one constant matrix plus the
  destination invariants.  A caller never supplies its own list of
  acceptable source states.
- **Nothing is sent before ownership is settled.**  The task↔session
  bijection is checked while preparing a dispatch *and* again in the
  non-interactive commit block, both before `agent-submit`.
- **No file is deleted or overwritten except a temporary file this
  module wrote moments earlier.**  The ledger file is only ever replaced
  atomically.
- **The ledger writes no property with an empty value**, so "absent" and
  "empty" never become two ways of saying the same thing.
- **Never guess backend facts.**  A `busy` target is refused by name; an
  `unknown` state is confirmed, never assumed idle; a re-binding is
  claimed only on a proven native session id, never on a directory
  match.
- **Nothing is silently dropped.**  Unparsable headings, unknown
  dependencies, dependency cycles, and skipped imports are each reported
  with a count or a named heading.
- **Modules install nothing at load time.**  Loading `agent-tasks.el`
  adds no hook, timer, or keymap entry.  Only `agent-tasks-mode`
  installs hooks.
- **No new `agent-backend` slot and no new hook in `agent.el`.**  If a
  task seems to need one, stop: the design is wrong, not the constraint.
- Defcustom defaults: `agent-tasks-file`
  `(expand-file-name "agent/tasks.org" user-emacs-directory)`,
  `agent-tasks-dispatch-confirm` `t`,
  `agent-tasks-chief-context-max` `20`,
  `agent-tasks-lock-timeout` `5`.
- Every pre-existing test keeps passing, unedited; `make compile` stays
  warning-free.  **Record the baseline count before Task 1** — `make
  test` on the repository as you find it — because this plan lands
  after three others and the absolute total will not be the 362 that
  `make test` reported when the plan was written.  No task states an
  expected total, and no aggregate is stated here either: after each
  task the total must rise by exactly the number of `ert-deftest` forms
  that task's diff added, which is a mechanical check
  (`grep -c '^(ert-deftest' test/agent-tasks-test.el`) rather than a
  number in prose that goes stale the moment a test is added.
- Commit after every task with a single-purpose message.

Run tests with `make test` from the repo root; byte-compile with `make
compile`.  Both must be clean before each commit.

## Landing order and prerequisites

**This plan lands last, after attention/queue, context-composer, and
skill-bundles, and attention/queue is a hard functional prerequisite.**

- **Attention/queue (area 2) must already be implemented.**  Task 6 of
  this plan consumes `agent-session-event-functions` — the ledger's only
  evidence channel — and Task 8 consumes
  `agent-session-ready-to-submit-p`, the only source that can tell a
  session stopped at a permission dialog (which displays as `waiting`)
  from one that can take a turn.  Without them the ledger would have to
  guess, and guessing is the one thing it may not do.  **Do not
  implement a substitute here.**  If area 2 has not landed, stop and say
  so; do not start Task 6.
- **Composer (area 3) and skill bundles (area 4)** are ordering-only:
  the Makefile lists and the `agent-menu` keys.  The attention plan
  *assigns* `SRC :=` and `TEST_FILES :=` complete lists; the composer
  and skill-bundles plans append.  This plan appends with `+=` on new
  lines and never restates either list, so it is safe last and only
  last.
- Task 12 asserts that no entry present in the committed Makefile
  disappeared and names the other projects' modules explicitly, so a
  wrong order fails loudly instead of silently shipping a module that is
  never compiled or tested.

Contact points with the other plans:

1. **Readiness policy.**  Task 8 checks three sources in order: the
   public `agent-session-ready-to-submit-p` (attention/queue), then the
   backend `:ready-to-submit-p` slot via `agent-backend-ready-to-submit-p`
   (composer), then `agent-session-display-state`.  All three are
   accessed through `fboundp` so the module's tests run in isolation.
   Do not add the slot or the awaiting-reason machinery here.
2. **Prompt isolation and the send channel.**  The composer project
   also adds `:pending-input-p` and `:submit-literal`
   (`plans/2026-07-30-context-composer.md`).  Task 8 consumes both: a
   dispatch into an existing session refuses unless the pending-input
   probe returns nil, and the send goes through the literal submitter
   rather than `agent-submit`.  Do not add either slot here, and do not
   fall back to `agent-submit` for an existing session — a backend
   registering no literal submitter simply cannot receive one.
3. **Restart hooks.**  Task 9 uses `agent-before-restart-functions` and
   `agent-after-restart-functions` (attention/queue, Task 11) through
   `boundp`.  Do not add them here.
4. **Attention items.**  Filed through `agent-attention-file` under
   `fboundp`, and **only** for a task that became `UNKNOWN` while a
   session buffer existed.  The attention module already files items for
   `blocked`, `error`, and completion events; a second item would be
   duplicate noise.
5. **`agent-menu` keys.**  Keys must be unique across the *whole*
   prefix, which includes the per-backend columns
   `agent-menu--backend-children` builds at open time.  Taken today:
   static `e w h x r l K f S s n c a d m g T p i`; generated
   `B N b t u U -c -w` (Claude) and `R F -x` (Codex); attention/queue
   `A Q L I E`; composer `C`; skill bundles `W H k v`.  **This plan uses
   `j` and `J`.**  They are not mnemonic; every mnemonic letter is
   already taken, and that is stated in the manual.
6. **No queue integration.**  A busy target is refused, not queued.  Do
   not build a submit-and-wait driver here.

## Deliberate deviations from the spec

Each is a decision made while planning; do not "fix" it back.

1. **`agent-tasks.el` requires `org` at the top level**, unlike
   `agent-capture.el`, which requires it lazily inside commands.  Every
   operation in this module parses or writes Org; a lazy require would
   have to appear inside the `agent-tasks--with-org-text` macro
   expansion, which is worse than an honest dependency in an optional
   module the person loads deliberately.
2. **Directory normalisation calls `agent-session--normalize-directory`**
   (a private symbol in `agent.el`) rather than re-implementing it.  A
   second implementation would drift, and the whole point of recording a
   directory is that it compares `equal` with a live session's.
3. **`agent-tasks-new` opens the ledger at the new task after creating
   it** when called interactively, instead of prompting for a multi-line
   instruction in the minibuffer.  It costs no new UI and gives a real
   editor for the field that most needs one.
4. **The four sub-headings are created at task creation**, not on
   demand, so the common path never has to insert one.  The
   create-on-demand helper still exists for hand-written entries.
5. **The reconciliation loop re-parses after every write.**
   `agent-tasks--update-task` returns a freshly parsed ledger and the
   loop threads it; a loop over one parse would fail on its second write
   with a conflict, because the first write changed the hash.  This is
   the same lesson the learning-inbox archive path recorded.

## Reference: the format this plan implements

```org
#+title: Agent task ledger
#+agent_ledger_version: 1
#+TODO: PENDING RUNNING BLOCKED UNKNOWN | DONE CANCELLED

* RUNNING Port the reconciliation pass
:PROPERTIES:
:AGENT_TASK_ID: t-20260731T142211-8f3a
:CREATED:  [2026-07-31 Fri 14:22]
:UPDATED:  [2026-07-31 Fri 15:01]
:BACKEND:  claude-code
:ACCOUNT:  personal
:DIRECTORY: ~/repos/agent/
:REPOSITORY: ~/repos/agent/
:INSTANCE: default
:SESSION_ID: 0f9c4b12-...
:ATTEMPT:  2
:DEPENDS:  t-20260731T140002-11bc
:END:

Write the pass that turns orphaned running tasks into unknown ones.

** Result

** Evidence

** Comments

** Log
- [2026-07-31 Fri 14:25] PENDING → RUNNING (dispatch attempt 1: ...)
```

Parsed: the TODO keyword (the single authority for state — there is
deliberately no `:STATE:` property), the heading text, the properties,
the body between the drawer and the first sub-heading, and the four
fixed sub-headings.  Written only: the contents of `Log`, which the
ledger appends to and never reads back for a decision.

---

### Task 1: Ledger file format and parser

**Files:**
- Create: `agent-tasks.el`
- Create: `test/agent-tasks-test.el`
- Modify: `Makefile:5-6`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces (used by every later task):
  - `agent-tasks-file`, `agent-tasks--format-version`,
    `agent-tasks--states`, `agent-tasks--open-states`,
    `agent-tasks--closed-states`, `agent-tasks--live-states`,
    `agent-tasks--sections`, `agent-tasks--header`.
  - `cl-defstruct agent-tasks-task` with accessors
    `agent-tasks-task-id`, `-state`, `-title`, `-instruction`,
    `-created`, `-updated`, `-backend`, `-account`, `-directory`,
    `-repository`, `-instance`, `-session-id`, `-attempt`, `-depends`,
    `-blocked-reason`, `-outcome`, `-source-file`, `-source-heading`,
    `-result`, `-evidence`, `-comments`, `-log`.
  - `cl-defstruct agent-tasks-problem` with `agent-tasks-problem-heading`,
    `-issue`, `-detail`.
  - `cl-defstruct agent-tasks-ledger` with `agent-tasks-ledger-file`,
    `-hash`, `-version`, `-tasks`, `-problems`.
  - `agent-tasks-read (&optional FILE)` → an `agent-tasks-ledger`.
  - `agent-tasks-find (LEDGER ID)` → task or nil.
  - `agent-tasks--with-org-text (TEXT &rest BODY)` macro.
  - `agent-tasks--snapshot FILE` → `(:bytes :token :coding :text)` from
    one read, or nil; `agent-tasks--file-text FILE` (auxiliary files
    only), `agent-tasks--entry-end`, `agent-tasks--property NAME`,
    `agent-tasks--escape-body TEXT`, `agent-tasks--unescape-body TEXT`,
    `agent-tasks--entry-problems ID STATE`.

- [ ] **Step 1: Register the new files in the Makefile**

The test file must be in `TEST_FILES` before the failing-test step, or
`make test` will not run it and the step will pass vacuously.

Append two lines after `Makefile:6` (do **not** retype either list):

```make
SRC += agent-tasks.el
TEST_FILES += test/agent-tasks-test.el
```

Then prove nothing disappeared:

```bash
git diff Makefile
```

Expected: two added lines, no removed lines.  Then:

```bash
make -n test | tr ' ' '\n' | grep -c 'agent-tasks-test.el'
```

Expected: `1`.

- [ ] **Step 2: Write the failing tests**

Create `test/agent-tasks-test.el`:

```elisp
;;; agent-tasks-test.el --- Tests for agent-tasks -*- lexical-binding: t -*-

;; Tests for the durable task ledger: its Org store, its state machine,
;; its session bindings, and its dispatcher.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'agent-tasks)

(defun agent-tasks-test--backend (&rest keys)
  "Return a minimal valid backend plist extended with KEYS."
  (append
   keys
   (list :buffer-p (lambda (_buffer) nil)
         :find-all-buffers (lambda () nil)
         :start-session #'ignore
         :label "Test")))

(defconst agent-tasks-test--fixture
  (concat
   "#+title: Agent task ledger\n"
   "#+agent_ledger_version: 1\n"
   "#+TODO: PENDING RUNNING BLOCKED UNKNOWN | DONE CANCELLED\n"
   "\n"
   "* RUNNING Port the reconciliation pass\n"
   ":PROPERTIES:\n"
   ":AGENT_TASK_ID: t-a\n"
   ":CREATED:  [2026-07-31 Fri 14:22]\n"
   ;; The body below is stored encoded, so the parser must decode it.
   ":BODY_ENCODED: t\n"
   ":BACKEND:  claude-code\n"
   ":ACCOUNT:  personal\n"
   ":DIRECTORY: ~/repos/agent/\n"
   ":INSTANCE: default\n"
   ":SESSION_ID: sid-1\n"
   ":ATTEMPT:  2\n"
   ":DEPENDS:  t-b t-c\n"
   ":END:\n"
   "\n"
   "Write the pass.\n"
   " * not a heading\n"
   "\n"
   "** Result\n"
   "\n"
   "** Evidence\n"
   "\n"
   "** Comments\n"
   "*** a third level heading stays here\n"
   "\n"
   "** Log\n"
   "- [2026-07-31 Fri 14:25] PENDING → RUNNING (dispatch attempt 1)\n"
   "\n"
   "* PENDING Second task\n"
   ":PROPERTIES:\n"
   ":AGENT_TASK_ID: t-b\n"
   ":END:\n"
   "\n"
   "Do the second thing.\n")
  "A ledger exercising every parsed field.")

(defmacro agent-tasks-test--with-ledger (text &rest body)
  "Run BODY with `agent-tasks-file' bound to a temp file holding TEXT.
TEXT nil means the file is not created at all.  Binds `dir' to the
temporary directory and removes it afterwards."
  (declare (indent 1) (debug (form body)))
  `(let* ((dir (make-temp-file "agent-tasks-test" t))
          (agent-tasks-file (expand-file-name "tasks.org" dir)))
     (unwind-protect
         (progn
           (when ,text
             (let ((coding-system-for-write 'utf-8-unix))
               (with-temp-file agent-tasks-file (insert ,text))))
           ,@body)
       (delete-directory dir t))))

;;;; Loading

(ert-deftest agent-tasks-test-loads ()
  "Loading the test file provides the `agent-tasks' feature."
  (should (featurep 'agent-tasks)))

;;;; Parsing

(ert-deftest agent-tasks-test-read/parses-every-field ()
  "A full fixture round-trips every parsed field."
  (agent-tasks-test--with-ledger agent-tasks-test--fixture
    (let* ((ledger (agent-tasks-read))
           (task (agent-tasks-find ledger "t-a")))
      (should (= 2 (length (agent-tasks-ledger-tasks ledger))))
      (should (null (agent-tasks-ledger-problems ledger)))
      (should (= 1 (agent-tasks-ledger-version ledger)))
      (should (equal "RUNNING" (agent-tasks-task-state task)))
      (should (equal "Port the reconciliation pass"
                     (agent-tasks-task-title task)))
      (should (equal "claude-code" (agent-tasks-task-backend task)))
      (should (equal "personal" (agent-tasks-task-account task)))
      (should (equal "~/repos/agent/" (agent-tasks-task-directory task)))
      (should (equal "default" (agent-tasks-task-instance task)))
      (should (equal "sid-1" (agent-tasks-task-session-id task)))
      (should (= 2 (agent-tasks-task-attempt task)))
      (should (equal '("t-b" "t-c") (agent-tasks-task-depends task)))
      (should (null (agent-tasks-task-outcome task)))
      (should (null (agent-tasks-task-blocked-reason task))))))

(ert-deftest agent-tasks-test-read/unescapes-the-instruction-body ()
  "The body stops at the first sub-heading and unescapes leading stars."
  (agent-tasks-test--with-ledger agent-tasks-test--fixture
    (should (equal "Write the pass.\n* not a heading"
                   (agent-tasks-task-instruction
                    (agent-tasks-find (agent-tasks-read) "t-a"))))))

(ert-deftest agent-tasks-test-read/keeps-third-level-headings-in-a-section ()
  "A `***' heading belongs to the section it sits in."
  (agent-tasks-test--with-ledger agent-tasks-test--fixture
    (let ((task (agent-tasks-find (agent-tasks-read) "t-a")))
      (should (equal "*** a third level heading stays here"
                     (agent-tasks-task-comments task)))
      (should (string-prefix-p "- [2026-07-31 Fri 14:25]"
                               (agent-tasks-task-log task))))))

(ert-deftest agent-tasks-test-read/missing-file-is-an-empty-ledger ()
  "A ledger file that does not exist reads as empty, not as an error."
  (agent-tasks-test--with-ledger nil
    (let ((ledger (agent-tasks-read)))
      (should (null (agent-tasks-ledger-tasks ledger)))
      (should (null (agent-tasks-ledger-problems ledger)))
      (should (null (agent-tasks-ledger-token ledger)))
      (should (= 1 (agent-tasks-ledger-version ledger))))))

(ert-deftest agent-tasks-test-read/unknown-keyword-is-a-problem-row ()
  "A heading whose keyword is not a ledger state is reported, not dropped."
  (agent-tasks-test--with-ledger
      (concat agent-tasks--header
              "* WAITING Mangled\n:PROPERTIES:\n:AGENT_TASK_ID: t-x\n:END:\n")
    (let ((ledger (agent-tasks-read)))
      (should (null (agent-tasks-ledger-tasks ledger)))
      (should (= 1 (length (agent-tasks-ledger-problems ledger))))
      (let ((problem (car (agent-tasks-ledger-problems ledger))))
        (should (equal "no ledger state"
                       (agent-tasks-problem-issue problem)))
        (should (string-match-p "WAITING Mangled"
                                (agent-tasks-problem-heading problem)))))))

(ert-deftest agent-tasks-test-read/missing-id-is-a-problem-row ()
  "A heading with no task id is reported."
  (agent-tasks-test--with-ledger
      (concat agent-tasks--header "* PENDING No id\n")
    (let ((ledger (agent-tasks-read)))
      (should (null (agent-tasks-ledger-tasks ledger)))
      (should (equal "no task id"
                     (agent-tasks-problem-issue
                      (car (agent-tasks-ledger-problems ledger))))))))

(ert-deftest agent-tasks-test-read/duplicate-id-rejects-every-occurrence ()
  "A duplicated id yields no usable task at all.
`org-find-property' returns the first match, so keeping the first
heading as a task would let a write silently edit one of two headings a
person cannot tell apart."
  (agent-tasks-test--with-ledger
      (concat agent-tasks--header
              "* PENDING One\n:PROPERTIES:\n:AGENT_TASK_ID: t-d\n:END:\n"
              "* PENDING Two\n:PROPERTIES:\n:AGENT_TASK_ID: t-d\n:END:\n"
              "* PENDING Fine\n:PROPERTIES:\n:AGENT_TASK_ID: t-ok\n:END:\n")
    (let ((ledger (agent-tasks-read)))
      (should (equal '("t-ok")
                     (mapcar #'agent-tasks-task-id
                             (agent-tasks-ledger-tasks ledger))))
      (should-not (agent-tasks-find ledger "t-d"))
      (let ((duplicates (cl-remove-if-not
                         (lambda (problem)
                           (equal "duplicate task id"
                                  (agent-tasks-problem-issue problem)))
                         (agent-tasks-ledger-problems ledger))))
        (should (= 2 (length duplicates)))
        (should (cl-every (lambda (problem)
                            (string-match-p "t-d"
                                            (agent-tasks-problem-detail problem)))
                          duplicates))))))

(ert-deftest agent-tasks-test-read/malformed-attempt-is-a-problem-row ()
  "An unparsable attempt is reported, never coerced to zero."
  (agent-tasks-test--with-ledger
      (concat agent-tasks--header
              "* PENDING Bad\n:PROPERTIES:\n:AGENT_TASK_ID: t-h\n"
              ":ATTEMPT: two\n:END:\n")
    (let ((ledger (agent-tasks-read)))
      (should (null (agent-tasks-ledger-tasks ledger)))
      (should (equal "malformed attempt"
                     (agent-tasks-problem-issue
                      (car (agent-tasks-ledger-problems ledger))))))))

(ert-deftest agent-tasks-test-read/incomplete-states-are-problem-rows ()
  "A BLOCKED record must say why and a DONE record must say what happened."
  (agent-tasks-test--with-ledger
      (concat agent-tasks--header
              "* BLOCKED No reason\n:PROPERTIES:\n:AGENT_TASK_ID: t-i\n:END:\n"
              "* DONE No outcome\n:PROPERTIES:\n:AGENT_TASK_ID: t-j\n:END:\n"
              "* DONE Bad outcome\n:PROPERTIES:\n:AGENT_TASK_ID: t-k\n"
              ":OUTCOME: maybe\n:END:\n")
    (let ((ledger (agent-tasks-read)))
      (should (null (agent-tasks-ledger-tasks ledger)))
      (should (equal '("blocked without a reason"
                       "done without an outcome"
                       "done without an outcome")
                     (mapcar #'agent-tasks-problem-issue
                             (agent-tasks-ledger-problems ledger)))))))

(ert-deftest agent-tasks-test-read/records-a-newer-format-version ()
  "A newer format version is parsed and reported rather than ignored."
  (agent-tasks-test--with-ledger
      (concat "#+title: Agent task ledger\n"
              "#+agent_ledger_version: 2\n"
              "#+TODO: PENDING RUNNING BLOCKED UNKNOWN | DONE CANCELLED\n\n"
              "* PENDING One\n:PROPERTIES:\n:AGENT_TASK_ID: t-e\n:END:\n")
    (should (= 2 (agent-tasks-ledger-version (agent-tasks-read))))))

;;;; Snapshots

(ert-deftest agent-tasks-test-snapshot/is-one-coherent-read ()
  "Token, text and coding all describe the same bytes."
  (agent-tasks-test--with-ledger agent-tasks-test--fixture
    (let ((lf (agent-tasks--snapshot agent-tasks-file)))
      (should (equal agent-tasks-test--fixture (plist-get lf :text)))
      (should (equal (secure-hash 'sha1 (plist-get lf :bytes))
                     (plist-get lf :token)))
      ;; Raw bytes, not decoded text: a CRLF twin must differ.
      (let ((coding-system-for-write 'utf-8-dos))
        (with-temp-file agent-tasks-file
          (insert agent-tasks-test--fixture)))
      (let ((crlf (agent-tasks--snapshot agent-tasks-file)))
        (should-not (equal (plist-get lf :token) (plist-get crlf :token)))
        (should (equal 'utf-8-dos (plist-get crlf :coding)))
        ;; The decoded text is the same, which is exactly why hashing it
        ;; would have missed the change.
        (should (equal (plist-get lf :text) (plist-get crlf :text)))))))

(ert-deftest agent-tasks-test-snapshot/honours-emacs-coding-precedence ()
  "The snapshot decodes and re-encodes the way `insert-file-contents' would.
Content detection alone disagrees whenever a coding cookie, a
`file-coding-system-alist' entry, or a `coding-system-for-read' binding
applies; and a cookie says nothing about line endings, so the eol
variant has to come from the same bytes or a CRLF ledger is rewritten
as LF."
  (let ((cookie "# -*- coding: iso-8859-1 -*-\n"))
    ;; Every case must agree with `insert-file-contents' on the coding
    ;; system, on the decoded text, and on the bytes a write-back
    ;; produces.
    (dolist (case (list
                   ;; cookie, body valid UTF-8 -> detection would say utf-8
                   (cons (concat cookie agent-tasks--header "caf\303\251\n") nil)
                   ;; cookie plus CRLF -> eol must survive
                   (cons (replace-regexp-in-string
                          "\n" "\r\n"
                          (concat cookie agent-tasks--header "caf\303\251\n"))
                         nil)
                   ;; plain CRLF, no cookie
                   (cons (replace-regexp-in-string
                          "\n" "\r\n" agent-tasks--header)
                         nil)
                   ;; plain LF
                   (cons agent-tasks--header nil)))
      (agent-tasks-test--with-ledger (car case)
        (let ((reference (with-temp-buffer
                           (insert-file-contents agent-tasks-file)
                           (cons buffer-file-coding-system (buffer-string))))
              (snapshot (agent-tasks--snapshot agent-tasks-file))
              (out (expand-file-name "copy.org" dir)))
          (should (eq (car reference) (plist-get snapshot :coding)))
          (should (equal (cdr reference) (plist-get snapshot :text)))
          (let ((coding-system-for-write (plist-get snapshot :coding)))
            (with-temp-file out (insert (plist-get snapshot :text))))
          (should (equal (plist-get snapshot :bytes)
                         (plist-get (agent-tasks--snapshot out) :bytes)))))))
  ;; An explicit read override wins over everything in the file.
  (agent-tasks-test--with-ledger agent-tasks--header
    (let ((coding-system-for-read 'utf-8-unix))
      (should (eq 'utf-8-unix
                  (plist-get (agent-tasks--snapshot agent-tasks-file)
                             :coding)))))
  ;; A `file-coding-system-alist' entry applies when no cookie does.
  (agent-tasks-test--with-ledger agent-tasks--header
    (let ((file-coding-system-alist
           (cons (cons (regexp-quote agent-tasks-file) 'iso-latin-1-unix)
                 file-coding-system-alist)))
      (should (eq 'iso-latin-1-unix
                  (plist-get (agent-tasks--snapshot agent-tasks-file)
                             :coding)))))
  ;; ...but a cookie outranks it, which is the order Emacs uses.
  (agent-tasks-test--with-ledger
      (concat "# -*- coding: iso-8859-1 -*-\n" agent-tasks--header)
    (let ((file-coding-system-alist
           (cons (cons (regexp-quote agent-tasks-file) 'utf-8-unix)
                 file-coding-system-alist)))
      (let ((reference (with-temp-buffer
                         (insert-file-contents agent-tasks-file)
                         buffer-file-coding-system))
            (snapshot (agent-tasks--snapshot agent-tasks-file)))
        (should (eq reference (plist-get snapshot :coding)))
        (should (eq 'iso-latin-1 (coding-system-base
                                  (plist-get snapshot :coding))))))))

(ert-deftest agent-tasks-test-body/codec-is-injective ()
  "Encode-then-decode is the identity for every star shape.
The revision-1 pair (`^\\*+' / `^ \\*+') failed the second case: a line
the person had indented themselves did not match the encoder, matched
the decoder, and came back with its space removed — so a dispatched
prompt differed from the stored instruction."
  (let ((cases '("* x" " * x" "  * x" "   ** deep"
                 "  *bold* start" "plain" " plain" ""))
        (encodings (make-hash-table :test 'equal)))
    (dolist (line cases)
      (should (equal line
                     (agent-tasks--unescape-body
                      (agent-tasks--escape-body line))))
      ;; No two distinct inputs may share an encoding.
      (should-not (gethash (agent-tasks--escape-body line) encodings))
      (puthash (agent-tasks--escape-body line) line encodings)
      ;; Nothing the encoder emits can be read by Org as a heading.
      (should-not (string-match-p "\\`\\*"
                                  (agent-tasks--escape-body line))))))

(ert-deftest agent-tasks-test-body/decodes-only-what-it-encoded ()
  "A hand-written body is read verbatim; an encoded one is decoded.
Any prefix escape is ambiguous applied to text it did not produce:
after encoding, \"* x\" and a hand-typed \" * x\" are the same bytes,
so the `BODY_ENCODED' property is what makes the reading unambiguous."
  (agent-tasks-test--with-ledger
      (concat agent-tasks--header
              "* PENDING Hand written\n:PROPERTIES:\n:AGENT_TASK_ID: t-s\n:END:\n"
              "\nfirst\n\n    indented continuation\n"
              " * a bullet the person indented\n\n"
              "** Result\n"
              "* PENDING Encoded\n:PROPERTIES:\n:AGENT_TASK_ID: t-e\n"
              ":BODY_ENCODED: t\n:END:\n"
              "\n * was a column-zero star\n\n"
              "** Result\n")
    (let ((ledger (agent-tasks-read)))
      (should (equal (string-join
                      '("first"
                        ""
                        "    indented continuation"
                        " * a bullet the person indented")
                      "\n")
                     (agent-tasks-task-instruction
                      (agent-tasks-find ledger "t-s"))))
      (should (equal "* was a column-zero star"
                     (agent-tasks-task-instruction
                      (agent-tasks-find ledger "t-e")))))))

(provide 'agent-tasks-test)
;;; agent-tasks-test.el ends here
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `make test`
Expected: the run aborts loading `test/agent-tasks-test.el` with
`Cannot open load file: agent-tasks`.

- [ ] **Step 4: Create the module with its format and parser**

Create `agent-tasks.el`:

```elisp
;;; agent-tasks.el --- Durable task ledger for AI sessions -*- lexical-binding: t -*-

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

;; A small durable ledger of tasks an AI session should do.  The ledger
;; owns task state; Claude Code and Codex do the work.
;;
;; Nothing here starts work on its own, retries work on its own, or
;; decides that work finished.  Every transition into `RUNNING' comes
;; from an interactive command, and a run that ended ambiguously becomes
;; `UNKNOWN' rather than being silently retried.  A backend completion
;; event means the model stopped talking, not that the task is done, so
;; it is logged and changes no state.
;;
;; The store is one Org file.  The heading's TODO keyword is the single
;; authority for a task's state; properties carry the scalar fields; the
;; body carries the instruction; and four fixed sub-headings carry the
;; result, the evidence, the comments, and an append-only log.  Loading
;; this file installs nothing: only `agent-tasks-mode' and the commands
;; do anything.

;;; Code:

(require 'agent)
(require 'cl-lib)
(require 'org)
(require 'subr-x)

;;;; Customization

(defgroup agent-tasks ()
  "Durable task ledger for AI agent sessions."
  :group 'agent)

(defcustom agent-tasks-file
  (expand-file-name "agent/tasks.org" user-emacs-directory)
  "Org file holding the durable task ledger.
One ledger covers every project: a control plane that is per-project
is not a control plane.  Filtering by project happens in the list."
  :type 'file
  :group 'agent-tasks)

;;;; Constants

(defconst agent-tasks--format-version 1
  "Ledger format version this code writes and understands.
A file declaring a higher version is displayed read-only, because a
newer Emacs may have written fields a rewrite here would drop.")

(defconst agent-tasks--states
  '("PENDING" "RUNNING" "BLOCKED" "UNKNOWN" "DONE" "CANCELLED")
  "Every recognised ledger state.")

(defconst agent-tasks--open-states
  '("BLOCKED" "UNKNOWN" "RUNNING" "PENDING")
  "Open states, in the order the list sorts them.")

(defconst agent-tasks--closed-states '("DONE" "CANCELLED")
  "States a task reaches only through a person's decision.")

(defconst agent-tasks--live-states '("RUNNING" "BLOCKED")
  "States in which a task claims a bound session.")

(defconst agent-tasks--sections '("Result" "Evidence" "Comments" "Log")
  "The fixed sub-headings of a task entry, in order.")

(defconst agent-tasks--header
  (concat "#+title: Agent task ledger\n"
          "#+agent_ledger_version: 1\n"
          "#+TODO: PENDING RUNNING BLOCKED UNKNOWN | DONE CANCELLED\n"
          "\n")
  "Header written when the ledger file is created.
The keyword declaration lives in the file so the ledger parses
identically in a scratch fixture and in a person's Emacs, with no
configuration.")

;;;; Records

(cl-defstruct (agent-tasks-task
               (:constructor agent-tasks-task--create)
               (:copier nil))
  "One durable ledger task."
  id state title instruction created updated
  backend account directory repository instance session-id
  attempt depends blocked-reason outcome
  source-file source-heading
  result evidence comments log
  ;; SHA-1 of this entry's whole text as parsed.  The dispatcher
  ;; compares it at commit time, so *any* change to the entry — not
  ;; just the handful of fields an enumerated check would list —
  ;; refuses a send against a task the person no longer reviewed.
  entry-token)

(cl-defstruct (agent-tasks-problem
               (:constructor agent-tasks-problem--create)
               (:copier nil))
  "A level-1 heading in the ledger that is not a usable task."
  heading issue detail)

(cl-defstruct (agent-tasks-ledger
               (:constructor agent-tasks-ledger--create)
               (:copier nil))
  "A parsed snapshot of the ledger file.
TOKEN is the SHA-1 of the **raw bytes** this snapshot was parsed from;
every write compares it, under the lock, against the file's current
bytes, so a concurrent edit is refused rather than overwritten."
  file token version tasks problems)

;;;; Reading the file

(defun agent-tasks--file-text (file)
  "Return FILE's decoded contents, or nil when it cannot be read.
Used for small auxiliary files such as the lock; the ledger itself is
always read through `agent-tasks--snapshot', which keeps the text and
the conflict token in step."
  (when (and file (file-readable-p file))
    (with-temp-buffer
      (insert-file-contents file)
      (buffer-string))))

(defun agent-tasks--snapshot (file)
  "Return one coherent snapshot of FILE, or nil when it cannot be read.
The plist carries `:bytes', `:token', `:coding' and `:text', **all
derived from a single read**.

Two reads — one for the token and one for the text, as revision 2 did —
let a rename landing between them pair the old content with the new
file's token: the conflict check passes and the write resurrects stale
content.  `detect-coding-string' plus `decode-coding-string' over the
bytes reproduce `insert-file-contents'' text and coding exactly,
verified in batch including a CRLF file, and the bytes round-trip when
written back with that coding.

The token hashes raw bytes rather than decoded text, because a decoded
hash cannot tell a CRLF ledger from its LF twin."
  (when (and file (file-readable-p file))
    (let* ((bytes (with-temp-buffer
                    (set-buffer-multibyte nil)
                    (insert-file-contents-literally file)
                    (buffer-string)))
           (coding (agent-tasks--snapshot-coding file bytes)))
      (list :bytes bytes
            :token (secure-hash 'sha1 bytes)
            :coding coding
            :text (decode-coding-string bytes coding)))))

(defun agent-tasks--snapshot-coding (file bytes)
  "Return the coding system Emacs would read FILE with, given its BYTES.
Applies Emacs's own coding-selection precedence to the one raw-byte
snapshot, rather than guessing from content alone:

1. `coding-system-for-read', when a caller bound it;
2. `set-auto-coding', which reads a `-*- coding: -*-' cookie and
   `auto-coding-alist'/`auto-coding-functions';
3. `find-operation-coding-system', which consults
   `file-coding-system-alist';
4. content detection, as a last resort.

**The cookie outranks `file-coding-system-alist'**, which revision 4
had the other way round.  Verified in batch: with a cookie saying
`iso-8859-1' and an alist entry saying `utf-8-unix' for the same file,
`insert-file-contents' reports `iso-latin-1-unix'.

Content detection alone — all revision 3 used — is only step 4, and it
disagrees with `insert-file-contents' whenever any earlier step
applies: for a ledger whose cookie says `iso-8859-1' while its bytes
are valid UTF-8, detection returns `utf-8' and decodes to different
text.

The **end-of-line variant is carried over from the same byte
snapshot**.  A cookie names a character set and says nothing about line
endings, so `set-auto-coding' returns a coding whose eol type is
unspecified; writing back with it would use the platform default and
**rewrite a CRLF ledger as LF** — revision 4 did exactly that, and the
byte round-trip failed.  Detection over the same bytes supplies the eol
type, and `coding-system-change-eol-conversion' pins it.

With both corrections every case — cookie, cookie+CRLF, plain CRLF,
plain LF, alist entry, read override, and cookie-versus-alist conflict
— returns the same coding system symbol as `insert-file-contents',
decodes to the same text, and round-trips to identical bytes."
  (let* ((detected (car (detect-coding-string bytes)))
         (chosen
          (or coding-system-for-read
              (with-temp-buffer
                (set-buffer-multibyte nil)
                (insert bytes)
                (goto-char (point-min))
                (set-auto-coding file (buffer-size)))
              (let ((operation (find-operation-coding-system
                                'insert-file-contents file)))
                (and (consp operation)
                     (not (eq (car operation) 'undecided))
                     (car operation)))
              detected)))
    (if (vectorp (coding-system-eol-type chosen))
        (let ((eol (coding-system-eol-type detected)))
          (if (integerp eol)
              (coding-system-change-eol-conversion chosen eol)
            chosen))
      chosen)))

(defmacro agent-tasks--with-org-text (text &rest body)
  "Evaluate BODY in a temporary `org-mode' buffer holding TEXT.
Point starts at the beginning of the buffer.  Org's startup work, the
person's `org-mode-hook', TODO-state hooks, and state logging are all
disabled: a machine write must not run arbitrary user code, and a
person whose `org-log-done' is `note' must not be prompted every time
this package changes a state."
  (declare (indent 1) (debug (form body)))
  `(let ((org-mode-hook nil)
         (org-inhibit-startup t)
         (org-inhibit-logging t)
         (org-log-done nil)
         (org-todo-log-states nil)
         (org-after-todo-state-change-hook nil))
     (with-temp-buffer
       (insert ,text)
       (org-mode)
       (goto-char (point-min))
       ,@body)))

(defun agent-tasks--parse-version (text)
  "Return the ledger format version declared in TEXT.
A file with no declaration is treated as version 1: a person may have
written it by hand."
  (if (string-match "^#\\+agent_ledger_version:[ \t]*\\([0-9]+\\)" text)
      (string-to-number (match-string 1 text))
    agent-tasks--format-version))

(defun agent-tasks-read (&optional file)
  "Return a parsed `agent-tasks-ledger' for FILE.
FILE defaults to `agent-tasks-file'.  A missing file is an empty
ledger, not an error."
  (let* ((file (expand-file-name (or file agent-tasks-file)))
         (snapshot (agent-tasks--snapshot file)))
    (if (null snapshot)
        (agent-tasks-ledger--create
         :file file :token nil :version agent-tasks--format-version
         :tasks nil :problems nil)
      (agent-tasks--parse-text file snapshot))))

(defun agent-tasks--parse-text (file snapshot)
  "Parse SNAPSHOT of ledger FILE into an `agent-tasks-ledger'.
SNAPSHOT comes from `agent-tasks--snapshot', so its text and its token
describe the same bytes.
Two passes.  The first counts every `AGENT_TASK_ID' in the file; the
second builds tasks, and an id seen more than once yields a problem row
for **every** occurrence and no task at all.  One pass keeping the first
occurrence would be worse than useless: `org-find-property' returns the
first match, so a write aimed at that id would silently edit one of two
headings a person cannot tell apart."
  (let* ((text (plist-get snapshot :text))
         (version (agent-tasks--parse-version text))
         (counts (make-hash-table :test 'equal))
         tasks problems)
    (agent-tasks--with-org-text text
      ;; Pass 1: count ids.
      (while (re-search-forward "^\\* " nil t)
        (beginning-of-line)
        (let ((end (agent-tasks--entry-end)))
          (when-let* ((id (agent-tasks--property "AGENT_TASK_ID")))
            (puthash id (1+ (gethash id counts 0)) counts))
          (goto-char end)))
      ;; Pass 2: build tasks and problems.
      (goto-char (point-min))
      (while (re-search-forward "^\\* " nil t)
        (beginning-of-line)
        (let ((end (agent-tasks--entry-end))
              (line (buffer-substring-no-properties
                     (line-beginning-position) (line-end-position))))
          (pcase (agent-tasks--entry-at-point end line counts
                                              (buffer-substring-no-properties
                                               (point) end))
            (`(task . ,task) (push task tasks))
            (`(problems . ,found) (setq problems (append (nreverse found)
                                                         problems))))
          (goto-char end))))
    (agent-tasks-ledger--create
     :file file
     :token (plist-get snapshot :token)
     :version version
     :tasks (nreverse tasks)
     :problems (nreverse problems))))

(defun agent-tasks--entry-end ()
  "Return the end of the level-1 entry whose heading point is on."
  (save-excursion
    (goto-char (line-end-position))
    (if (re-search-forward "^\\* " nil t)
        (match-beginning 0)
      (point-max))))

(defun agent-tasks--entry-at-point (end line counts entry-text)
  "Return the task or the problems for the level-1 heading at point.
END bounds the entry, LINE is its raw heading line, COUNTS maps each id
in the file to how many headings carry it, and ENTRY-TEXT is the
entry's whole text, hashed into the task's `entry-token'.  The result
is \(task . TASK) or (problems . LIST)."
  (let* ((state (org-get-todo-state))
         (id (agent-tasks--property "AGENT_TASK_ID"))
         (problems (agent-tasks--entry-problems id state line counts)))
    (if problems
        (cons 'problems problems)
      (cons 'task
            (agent-tasks-task--create
             :id id
             :state state
             :title (org-get-heading t t t t)
             :instruction (agent-tasks--body
                           end (agent-tasks--property "BODY_ENCODED"))
             :created (agent-tasks--property "CREATED")
             :updated (agent-tasks--property "UPDATED")
             :backend (agent-tasks--property "BACKEND")
             :account (agent-tasks--property "ACCOUNT")
             :directory (agent-tasks--property "DIRECTORY")
             :repository (agent-tasks--property "REPOSITORY")
             :instance (agent-tasks--property "INSTANCE")
             :session-id (agent-tasks--property "SESSION_ID")
             :attempt (string-to-number
                       (or (agent-tasks--property "ATTEMPT") "0"))
             :depends (split-string
                       (or (agent-tasks--property "DEPENDS") "") nil t)
             :blocked-reason (agent-tasks--property "BLOCKED_REASON")
             :outcome (agent-tasks--property "OUTCOME")
             :source-file (agent-tasks--property "SOURCE_FILE")
             :source-heading (agent-tasks--property "SOURCE_HEADING")
             :result (agent-tasks--section "Result" end)
             :evidence (agent-tasks--section "Evidence" end)
             :comments (agent-tasks--section "Comments" end)
             :log (agent-tasks--section "Log" end)
             :entry-token (secure-hash 'sha1 entry-text))))))

(defun agent-tasks--entry-problems (id state line counts)
  "Return the problems of the entry at point, or nil when it is a task.
ID and STATE are its parsed id and keyword, LINE its raw heading, and
COUNTS the file-wide id tally.  Every class here means the record
cannot be acted on: silently coercing any of them would put a claim in
the ledger that nothing checked."
  (let ((attempt (agent-tasks--property "ATTEMPT"))
        (outcome (agent-tasks--property "OUTCOME"))
        problems)
    (cond
     ((null id)
      (push (agent-tasks-problem--create
             :heading line :issue "no task id"
             :detail "heading has no AGENT_TASK_ID property")
            problems))
     ((> (gethash id counts 0) 1)
      (push (agent-tasks-problem--create
             :heading line :issue "duplicate task id"
             :detail (format "id %s appears on %d headings; no task with that id is usable until they differ"
                             id (gethash id counts 0)))
            problems))
     ((not (member state agent-tasks--states))
      (push (agent-tasks-problem--create
             :heading line :issue "no ledger state"
             :detail (format "task %s has no recognised state keyword" id))
            problems))
     (t
      (when (and attempt (not (string-match-p "\\`[0-9]+\\'" attempt)))
        (push (agent-tasks-problem--create
               :heading line :issue "malformed attempt"
               :detail (format "task %s has ATTEMPT `%s', which is not a non-negative integer"
                               id attempt))
              problems))
      (when (and (equal state "BLOCKED")
                 (null (agent-tasks--property "BLOCKED_REASON")))
        (push (agent-tasks-problem--create
               :heading line :issue "blocked without a reason"
               :detail (format "task %s is BLOCKED with no BLOCKED_REASON" id))
              problems))
      (when (and (equal state "DONE")
                 (not (member outcome '("succeeded" "failed"))))
        (push (agent-tasks-problem--create
               :heading line :issue "done without an outcome"
               :detail (format "task %s is DONE with OUTCOME `%s'"
                               id (or outcome "absent")))
              problems))))
    (nreverse problems)))

(defun agent-tasks--property (name)
  "Return property NAME of the heading at point, or nil when it is empty.
The ledger never writes an empty property, so \"absent\" and \"empty\"
are the same answer and both read as nil."
  (let ((value (org-entry-get (point) name)))
    (when (and value (not (string-empty-p (string-trim value))))
      (string-trim value))))

(defun agent-tasks--body (end encoded)
  "Return the instruction body of the entry at point, bounded by END.
Decode the codec only when ENCODED is non-nil — that is, only for a
body this package wrote.  Outer whitespace is trimmed; interior blank
lines and indentation are kept exactly."
  (save-excursion
    (org-back-to-heading t)
    (forward-line 1)
    (when (looking-at-p "[ \t]*:PROPERTIES:[ \t]*$")
      (when (re-search-forward "^[ \t]*:END:[ \t]*$" end t)
        (forward-line 1)))
    (let* ((start (point))
           (stop (if (re-search-forward "^\\*\\* " end t)
                     (match-beginning 0)
                   end))
           (text (string-trim (buffer-substring-no-properties start stop))))
      (if encoded (agent-tasks--unescape-body text) text))))

(defun agent-tasks--section (name end)
  "Return the text of sub-heading NAME in the entry at point, or nil.
END bounds the entry.  A `***' heading inside the section stays in it:
the boundary regexp matches exactly one or two stars followed by a
space, so it does not match a deeper heading."
  (save-excursion
    (org-back-to-heading t)
    (let ((case-fold-search nil))
      (when (re-search-forward
             (format "^\\*\\* %s[ \t]*$" (regexp-quote name)) end t)
        (forward-line 1)
        (let* ((start (point))
               (stop (if (re-search-forward "^\\*\\{1,2\\} " end t)
                         (match-beginning 0)
                       end))
               (text (string-trim
                      (buffer-substring-no-properties start stop))))
          (unless (string-empty-p text) text))))))

(defun agent-tasks--escape-body (text)
  "Return TEXT with every star-leading line indented one more space.
A person's instruction may legitimately begin a line with `*'; Org
would read that as a heading and split the entry.  Escaping *every*
line whose first non-blank character is a star — not only those at
column zero — is what makes the pair injective: escaping only column
zero maps both \"* x\" and \" * x\" onto the same bytes."
  (replace-regexp-in-string "^\\( *\\*\\)" " \\1" text))

(defun agent-tasks--unescape-body (text)
  "Return TEXT with `agent-tasks--escape-body' undone.
Apply this only to a body this package encoded; see
`agent-tasks--body'."
  (replace-regexp-in-string "^ \\( *\\*\\)" "\\1" text))

(defun agent-tasks-find (ledger id)
  "Return the task with ID in LEDGER, or nil."
  (cl-find id (agent-tasks-ledger-tasks ledger)
           :key #'agent-tasks-task-id :test #'equal))

;;;; Provide

(provide 'agent-tasks)
;;; agent-tasks.el ends here
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `make test`
Expected: `0 unexpected`, and the total rises by exactly the number of `ert-deftest` forms this task adds (count them in the diff).

- [ ] **Step 6: Byte-compile**

Run: `make compile`
Expected: no output beyond the compilation banner; no warnings.

- [ ] **Step 7: Commit**

```bash
git add agent-tasks.el test/agent-tasks-test.el Makefile
git commit -m "feat(tasks): add the ledger file format and its parser"
```

---

### Task 2: Atomic, guarded writes

**Files:**
- Modify: `agent-tasks.el` (a new "Writing the file" section after the
  reading section)
- Test: `test/agent-tasks-test.el`

**Interfaces:**
- Consumes: Task 1's parser and structs.
- Produces (used by every later task):
  - `agent-tasks--ensure-file FILE` — create FILE with the header.
  - `agent-tasks--check-writable LEDGER` — signal unless the ledger may
    be written: version gate and modified-visiting-buffer gate.
  - `agent-tasks--update-task LEDGER ID FN` → a freshly parsed ledger.
    FN runs with point at the task's heading in a temp `org-mode`
    buffer.
  - `agent-tasks--append-entry LEDGER TEXT` → a freshly parsed ledger.
  - `agent-tasks--replace-file FILE CONTENT`,
    `agent-tasks--sync-visiting-buffer FILE`.
  - `agent-tasks--set-property NAME VALUE`,
    `agent-tasks--stamp-updated`, `agent-tasks--set-state STATE REASON`,
    `agent-tasks--log FORMAT &rest ARGS`,
    `agent-tasks--section-append-point NAME`,
    `agent-tasks--append-to-section NAME TEXT`,
    `agent-tasks--one-line TEXT`.

- [ ] **Step 1: Write the failing tests**

Add to `test/agent-tasks-test.el`, before the `provide`:

```elisp
;;;; Writing

(ert-deftest agent-tasks-test-write/changes-only-what-it-must ()
  "A state change rewrites the keyword, UPDATED and Log, and nothing else."
  (agent-tasks-test--with-ledger agent-tasks-test--fixture
    (agent-tasks--update-task
     (agent-tasks-read) "t-a"
     (lambda () (agent-tasks--set-state "UNKNOWN" "test reason")))
    (let* ((text (agent-tasks--file-text agent-tasks-file))
           (ledger (agent-tasks-read))
           (task (agent-tasks-find ledger "t-a")))
      (should (equal "UNKNOWN" (agent-tasks-task-state task)))
      (should (agent-tasks-task-updated task))
      (should (string-match-p "RUNNING → UNKNOWN (test reason)"
                              (agent-tasks-task-log task)))
      ;; The earlier log line and the second task are untouched.
      (should (string-match-p "dispatch attempt 1" text))
      (should (string-match-p "Do the second thing\\." text))
      (should (equal "Write the pass.\n* not a heading"
                     (agent-tasks-task-instruction task))))))

(ert-deftest agent-tasks-test-write/preserves-crlf ()
  "A CRLF ledger stays CRLF."
  (agent-tasks-test--with-ledger
      (replace-regexp-in-string "\n" "\r\n" agent-tasks-test--fixture)
    (agent-tasks--update-task
     (agent-tasks-read) "t-a"
     (lambda () (agent-tasks--set-state "UNKNOWN" "crlf")))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (let ((coding-system-for-read 'binary))
        (insert-file-contents-literally agent-tasks-file))
      (should (string-match-p "\r\n" (buffer-string)))
      (should-not (string-match-p "[^\r]\n" (buffer-string))))))

(ert-deftest agent-tasks-test-write/never-logs-a-closed-stamp ()
  "A person whose `org-log-done' is `note' is never prompted."
  (agent-tasks-test--with-ledger agent-tasks-test--fixture
    (let ((org-log-done 'note))
      (agent-tasks--update-task
       (agent-tasks-read) "t-a"
       (lambda () (agent-tasks--set-state "DONE" "closing"))))
    (let ((text (agent-tasks--file-text agent-tasks-file)))
      (should-not (string-match-p "CLOSED:" text))
      (should-not (string-match-p ":LOGBOOK:" text)))))

(ert-deftest agent-tasks-test-write/refuses-a-modified-visiting-buffer ()
  "An unsaved edit in a buffer visiting the ledger blocks the write."
  (agent-tasks-test--with-ledger agent-tasks-test--fixture
    (let ((buffer (find-file-noselect agent-tasks-file)))
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (goto-char (point-max))
              (insert "\n* PENDING typed by hand\n"))
            (let ((error-message
                   (cadr (should-error
                          (agent-tasks--update-task
                           (agent-tasks-read) "t-a"
                           (lambda () (agent-tasks--set-state "UNKNOWN" "x")))
                          :type 'user-error))))
              (should (string-match-p (regexp-quote (buffer-name buffer))
                                      error-message))))
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer)))))

(ert-deftest agent-tasks-test-write/refuses-a-stale-snapshot ()
  "A ledger changed on disk since it was parsed is a conflict."
  (agent-tasks-test--with-ledger agent-tasks-test--fixture
    (let ((ledger (agent-tasks-read)))
      (let ((coding-system-for-write 'utf-8-unix))
        (with-temp-file agent-tasks-file
          (insert agent-tasks-test--fixture)
          (insert "\n* PENDING added behind our back\n"
                  ":PROPERTIES:\n:AGENT_TASK_ID: t-z\n:END:\n")))
      (should-error
       (agent-tasks--update-task
        ledger "t-a" (lambda () (agent-tasks--set-state "UNKNOWN" "x")))
       :type 'user-error)
      ;; Nothing was written.
      (should (agent-tasks-find (agent-tasks-read) "t-z")))))

(ert-deftest agent-tasks-test-write/refuses-a-newer-format-version ()
  "A ledger from a newer Emacs is read-only."
  (agent-tasks-test--with-ledger
      (concat "#+title: Agent task ledger\n"
              "#+agent_ledger_version: 2\n"
              "#+TODO: PENDING RUNNING BLOCKED UNKNOWN | DONE CANCELLED\n\n"
              "* PENDING One\n:PROPERTIES:\n:AGENT_TASK_ID: t-e\n:END:\n")
    (should-error
     (agent-tasks--update-task
      (agent-tasks-read) "t-e"
      (lambda () (agent-tasks--set-state "RUNNING" "x")))
     :type 'user-error)))

(ert-deftest agent-tasks-test-write/leaves-no-temporary-file ()
  "A completed write leaves nothing behind in the ledger's directory."
  (agent-tasks-test--with-ledger agent-tasks-test--fixture
    (agent-tasks--update-task
     (agent-tasks-read) "t-a"
     (lambda () (agent-tasks--set-state "UNKNOWN" "x")))
    (should (equal '("tasks.org")
                   (directory-files dir nil directory-files-no-dot-files-regexp)))))

(ert-deftest agent-tasks-test-write/a-failed-rename-leaves-the-original ()
  "An interrupted replacement cannot truncate the ledger."
  (agent-tasks-test--with-ledger agent-tasks-test--fixture
    (cl-letf (((symbol-function 'rename-file)
               (lambda (&rest _) (error "disk full"))))
      (should-error
       (agent-tasks--update-task
        (agent-tasks-read) "t-a"
        (lambda () (agent-tasks--set-state "UNKNOWN" "x")))))
    (should (equal agent-tasks-test--fixture
                   (agent-tasks--file-text agent-tasks-file)))
    (should (equal '("tasks.org")
                   (directory-files dir nil directory-files-no-dot-files-regexp)))))

;; Both directory listings above must include dot files.  The
;; replacement temp file is named `.agent-tasks-…', so a listing that
;; filtered dot files would pass while a leaked temp file sat right
;; next to the ledger.  `directory-files-no-dot-files-regexp' excludes
;; only `.' and `..'.

(ert-deftest agent-tasks-test-write/creates-the-file-with-a-header ()
  "The first write creates the ledger with its keyword declaration."
  (agent-tasks-test--with-ledger nil
    (agent-tasks--ensure-file agent-tasks-file)
    (should (equal agent-tasks--header
                   (agent-tasks--file-text agent-tasks-file)))
    (should (equal '("tasks.org")
                   (directory-files dir nil
                                    directory-files-no-dot-files-regexp)))))

;;;; Concurrency

(ert-deftest agent-tasks-test-write/interleaved-writers-lose-nothing ()
  "The exact two-writer race: one commits, the other is refused.
Both parse the same bytes, so both hold the same token.  Writer B
commits first; writer A must then be refused rather than renaming its
own copy over B's change."
  (agent-tasks-test--with-ledger agent-tasks-test--fixture
    (let ((writer-a (agent-tasks-read))
          (writer-b (agent-tasks-read)))
      (should (equal (agent-tasks-ledger-token writer-a)
                     (agent-tasks-ledger-token writer-b)))
      (agent-tasks--update-task
       writer-b "t-b" (lambda () (agent-tasks--log "B was here")))
      (should-error
       (agent-tasks--update-task
        writer-a "t-a" (lambda () (agent-tasks--log "A was here")))
       :type 'user-error)
      (let ((ledger (agent-tasks-read)))
        ;; B's change survived and A's was not applied.
        (should (string-match-p "B was here"
                                (agent-tasks-task-log
                                 (agent-tasks-find ledger "t-b"))))
        (should-not (string-match-p "A was here"
                                    (or (agent-tasks-task-log
                                         (agent-tasks-find ledger "t-a"))
                                        "")))
        ;; Nothing was lost.
        (should (= 2 (length (agent-tasks-ledger-tasks ledger))))))))

(ert-deftest agent-tasks-test-lock/a-held-lock-refuses-and-changes-nothing ()
  "A lock another process holds times out with a message naming it."
  (agent-tasks-test--with-ledger agent-tasks-test--fixture
    (let ((agent-tasks-lock-timeout 0.2)
          (lock (agent-tasks--lock-file agent-tasks-file))
          (before (agent-tasks--file-text agent-tasks-file)))
      (write-region "999@other 2026-07-31 00:00:00\n" nil lock nil 'silent)
      (unwind-protect
          (let ((error-message
                 (cadr (should-error
                        (agent-tasks--update-task
                         (agent-tasks-read) "t-a"
                         (lambda () (agent-tasks--log "blocked")))
                        :type 'user-error))))
            (should (string-match-p "999@other" error-message))
            (should (string-match-p "agent-tasks-break-lock" error-message))
            (should (equal before (agent-tasks--file-text agent-tasks-file))))
        (delete-file lock)))))

(ert-deftest agent-tasks-test-lock/is-released-on-both-paths ()
  "The lock does not outlive a successful write or a signalling one."
  (agent-tasks-test--with-ledger agent-tasks-test--fixture
    (let ((lock (agent-tasks--lock-file agent-tasks-file)))
      (agent-tasks--update-task
       (agent-tasks-read) "t-a" (lambda () (agent-tasks--log "fine")))
      (should-not (file-exists-p lock))
      (should-error
       (agent-tasks--update-task
        (agent-tasks-read) "t-a" (lambda () (error "boom"))))
      (should-not (file-exists-p lock)))))

(ert-deftest agent-tasks-test-snapshot/a-rename-between-reads-cannot-slip-through ()
  "A file replaced after the snapshot is a conflict, not a stale write.
Revision 2 read the token and the text separately; a replacement
landing between them paired old content with the new token."
  (agent-tasks-test--with-ledger agent-tasks-test--fixture
    (let ((ledger (agent-tasks-read)))
      (let ((coding-system-for-write 'utf-8-unix))
        (with-temp-file agent-tasks-file
          (insert agent-tasks--header
                  "* PENDING Replaced\n:PROPERTIES:\n:AGENT_TASK_ID: t-r\n:END:\n")))
      (should-error
       (agent-tasks--update-task
        ledger "t-a" (lambda () (agent-tasks--log "stale")))
       :type 'user-error)
      ;; The replacement survived untouched.
      (should (agent-tasks-find (agent-tasks-read) "t-r")))))

(ert-deftest agent-tasks-test-write/appends-to-an-absent-section ()
  "A hand-written entry with no Log section gets one."
  (agent-tasks-test--with-ledger
      (concat agent-tasks--header
              "* PENDING Bare\n:PROPERTIES:\n:AGENT_TASK_ID: t-f\n:END:\n"
              "\nsome instruction\n")
    (agent-tasks--update-task
     (agent-tasks-read) "t-f"
     (lambda () (agent-tasks--log "created a section")))
    (let ((task (agent-tasks-find (agent-tasks-read) "t-f")))
      (should (string-match-p "created a section" (agent-tasks-task-log task)))
      (should (equal "some instruction"
                     (agent-tasks-task-instruction task))))))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test`
Expected: every test added in Step 1 fails, with each `Symbol's function definition is void:
agent-tasks--update-task` or `agent-tasks--ensure-file`.

- [ ] **Step 3: Implement the writer**

Add to `agent-tasks.el`, after the reading section and before
`;;;; Provide`:

```elisp
;;;; The interprocess lock

(defcustom agent-tasks-lock-timeout 5
  "Seconds to wait for another process to release the ledger lock."
  :type 'number
  :group 'agent-tasks)

(defun agent-tasks--lock-file (file)
  "Return the lock file guarding ledger FILE."
  (concat file ".lock"))

(defmacro agent-tasks--with-lock (file &rest body)
  "Evaluate BODY holding the interprocess lock on ledger FILE.
Acquisition uses `write-region' with the `excl' flag, an atomic
exclusive create that signals `file-already-exists' when another
process holds the lock — verified in batch.  The lock covers the whole
read-check-edit-rename sequence, because the conflict token alone does
not make concurrent writers safe: two processes can both read the same
bytes, both find the token matches, and both rename, and the second
rename silently discards the first writer's change."
  (declare (indent 1) (debug (form body)))
  `(let ((agent-tasks--locked-file ,file))
     (agent-tasks--acquire-lock agent-tasks--locked-file)
     (unwind-protect (progn ,@body)
       (agent-tasks--release-lock agent-tasks--locked-file))))

(defvar agent-tasks--locked-file nil
  "Ledger file whose lock this dynamic extent holds, or nil.")

(defun agent-tasks--acquire-lock (file)
  "Take the lock on ledger FILE, waiting up to `agent-tasks-lock-timeout'."
  (make-directory (file-name-directory file) t)
  (let ((lock (agent-tasks--lock-file file))
        (deadline (+ (float-time) agent-tasks-lock-timeout))
        (taken nil))
    (while (not taken)
      (condition-case nil
          (progn
            (write-region (format "%d@%s %s\n" (emacs-pid) (system-name)
                                  (format-time-string "%Y-%m-%d %H:%M:%S"))
                          nil lock nil 'silent nil 'excl)
            (setq taken t))
        (file-already-exists
         (when (> (float-time) deadline)
           (user-error
            "Ledger is locked by another process; %s says: %s.  If that process is gone, use `agent-tasks-break-lock'"
            (abbreviate-file-name lock)
            (string-trim (or (agent-tasks--file-text lock) "(unreadable)"))))
         (sleep-for 0.1))))
    taken))

(defun agent-tasks--release-lock (file)
  "Release the lock on ledger FILE."
  (let ((lock (agent-tasks--lock-file file)))
    (when (file-exists-p lock)
      (delete-file lock))))

;;;###autoload
(defun agent-tasks-break-lock ()
  "Remove a stale ledger lock after showing who holds it.
Never automatic: silently breaking a lock would reintroduce exactly
the race the lock exists to close."
  (interactive)
  (let ((lock (agent-tasks--lock-file (expand-file-name agent-tasks-file))))
    (unless (file-exists-p lock)
      (user-error "No ledger lock is held"))
    (unless (yes-or-no-p
             (format "Lock held by %s.  Break it? "
                     (string-trim (or (agent-tasks--file-text lock)
                                      "(unreadable)"))))
      (user-error "Lock not broken"))
    (delete-file lock)
    (message "Ledger lock removed")))

;;;; Writing the file

(defun agent-tasks--ensure-file (file)
  "Create FILE with the ledger header when it does not exist.
Call only while holding the lock.  The header is published through the
same temp-file-plus-rename path as every other write, so a reader never
sees a half-written header."
  (unless (file-exists-p file)
    (make-directory (file-name-directory file) t)
    ;; `agent-tasks--replace-file' falls back to `utf-8-unix' when there
    ;; is no existing file to detect a coding system from.
    (agent-tasks--replace-file file agent-tasks--header)))

(defun agent-tasks--check-writable (ledger)
  "Signal a `user-error' unless LEDGER's file may be written.
Two gates: a format version newer than this code understands, and a
buffer visiting the file with unsaved changes.  The second matters
because a machine write must never save a person's edits as a side
effect."
  (when (> (agent-tasks-ledger-version ledger) agent-tasks--format-version)
    (user-error
     "Ledger %s declares format version %d; this Emacs understands %d, so it is read-only"
     (agent-tasks-ledger-file ledger)
     (agent-tasks-ledger-version ledger)
     agent-tasks--format-version))
  (when-let* ((buffer (find-buffer-visiting (agent-tasks-ledger-file ledger))))
    (when (buffer-modified-p buffer)
      (user-error "Buffer %s has unsaved ledger changes; save or revert it first"
                  (buffer-name buffer)))))

(defun agent-tasks--current-snapshot (ledger)
  "Return LEDGER's file snapshot, signalling when its bytes changed.
Call only while holding the lock: the token detects a change that
already landed, and only the lock stops an interleaving that produces
one.  The returned snapshot is a single read, so the text the caller
edits and the token that authorised the edit describe the same bytes."
  (let* ((file (agent-tasks-ledger-file ledger))
         (snapshot (or (agent-tasks--snapshot file)
                       (user-error "Ledger file is gone: %s" file))))
    (unless (equal (plist-get snapshot :token)
                   (agent-tasks-ledger-token ledger))
      (user-error
       "The ledger changed on disk since it was read; refresh and retry"))
    snapshot))

(defun agent-tasks--update-task (ledger id fn)
  "Run FN at task ID's heading in LEDGER's file and save the result.
FN is called with no arguments, with point at the task's heading in a
temporary `org-mode' buffer holding the ledger's current text.  Return
a freshly parsed ledger, so a caller updating several tasks can thread
the new snapshot and never write against a stale token.

The whole read-check-edit-rename sequence runs under
`agent-tasks--with-lock'."
  (agent-tasks--check-writable ledger)
  (let ((file (agent-tasks-ledger-file ledger)))
    (agent-tasks--with-lock file
      (let* ((snapshot (agent-tasks--current-snapshot ledger))
             (new (agent-tasks--with-org-text (plist-get snapshot :text)
                    (let ((position (org-find-property "AGENT_TASK_ID" id)))
                      (unless position
                        (user-error "No task with id %s in %s" id file))
                      (goto-char position)
                      (funcall fn)
                      (goto-char (org-find-property "AGENT_TASK_ID" id))
                      (agent-tasks--stamp-updated)
                      (buffer-string)))))
        (agent-tasks--replace-file file new (plist-get snapshot :coding))))
    (agent-tasks--sync-visiting-buffer file)
    (agent-tasks-read file)))

(defun agent-tasks--append-entry (ledger builder)
  "Append the entry BUILDER returns to LEDGER's file; return the new ledger.
BUILDER is called **under the lock**, with the ledger as re-parsed from
disk at that moment, and returns the entry text to append.  Minting the
new task's id from that re-parse rather than from the caller's
unlocked snapshot is what stops two concurrent creators from choosing
the same id — ids embed a one-second timestamp and 16 random bits, and
a duplicated id makes both tasks unusable.

A snapshot taken when the ledger was absent may not append onto one
that appeared in between: another process published a file whose
version and contents this snapshot never saw, so that is a conflict."
  (agent-tasks--check-writable ledger)
  (let ((file (agent-tasks-ledger-file ledger)))
    (agent-tasks--with-lock file
      (let ((existed (file-exists-p file)))
        (when (and (null (agent-tasks-ledger-token ledger)) existed)
          (user-error
           "Another process created the ledger since it was read; refresh and retry"))
        (unless existed (agent-tasks--ensure-file file)))
      (let ((snapshot (or (agent-tasks--snapshot file)
                          (user-error "Ledger file is gone: %s" file))))
        (when (and (agent-tasks-ledger-token ledger)
                   (not (equal (plist-get snapshot :token)
                               (agent-tasks-ledger-token ledger))))
          (user-error
           "The ledger changed on disk since it was read; refresh and retry"))
        (let* ((fresh (agent-tasks--parse-text file snapshot))
               (entry (funcall builder fresh)))
          (agent-tasks--replace-file
           file
           (concat (string-trim-right (plist-get snapshot :text)) "\n\n" entry)
           (plist-get snapshot :coding)))))
    (agent-tasks--sync-visiting-buffer file)
    (agent-tasks-read file)))

(defun agent-tasks--replace-file (file content &optional coding)
  "Replace FILE's contents with CONTENT atomically.
CONTENT is written to a temporary file in FILE's own directory and
renamed over it, so an interrupted write cannot truncate the ledger.
CODING is the coding system from the caller's snapshot of FILE, so a
CRLF ledger stays CRLF; it defaults to `utf-8-unix' for a file being
created."
  (make-directory (file-name-directory file) t)
  (let ((coding (or coding 'utf-8-unix))
        (temp (make-temp-file
               (expand-file-name ".agent-tasks-" (file-name-directory file)))))
    (unwind-protect
        (progn
          (let ((coding-system-for-write coding))
            (with-temp-file temp (insert content)))
          (rename-file temp file t)
          (setq temp nil))
      (when (and temp (file-exists-p temp))
        (delete-file temp)))))

(defun agent-tasks--sync-visiting-buffer (file)
  "Revert a clean buffer visiting FILE so an open window shows the truth."
  (when-let* ((buffer (find-buffer-visiting file)))
    (with-current-buffer buffer
      (unless (buffer-modified-p)
        (revert-buffer t t t)))))

;;;; Editing one entry

(defun agent-tasks--set-property (name value)
  "Set property NAME of the task at point to VALUE.
A nil or empty VALUE deletes the property: the ledger never records an
empty value, so \"absent\" has exactly one representation.

VALUE's bytes are preserved.  Only leading and trailing whitespace is
dropped — Org itself does that on read, so keeping it would make the
written and read values differ.  A VALUE containing a newline is an
error naming the property: a property drawer cannot represent one, and
substituting a space would corrupt a value whose whole point is to be
verbatim, which is what revision 1 did to every `SOURCE_HEADING'."
  (let ((string (and value (string-trim (format "%s" value)))))
    (when (and string (string-match-p "\n" string))
      (error "Ledger property %s cannot contain a newline: %S" name string))
    (if (and string (not (string-empty-p string)))
        (org-set-property name string)
      (org-entry-delete (point) name))))

(defun agent-tasks--stamp-updated ()
  "Record the current time as the UPDATED property of the task at point."
  (org-set-property "UPDATED" (format-time-string "[%Y-%m-%d %a %H:%M]")))

(defun agent-tasks--set-state (state reason)
  "Set the task at point to STATE and log the transition with REASON.
This is the only function that changes a task's state keyword."
  (unless (member state agent-tasks--states)
    (error "Unknown ledger state: %s" state))
  (let ((old (or (org-get-todo-state) "(none)")))
    (org-todo state)
    (agent-tasks--log "%s → %s (%s)" old state reason)))

(defun agent-tasks--one-line (text)
  "Return TEXT collapsed to a single line."
  (string-trim (replace-regexp-in-string "[ \t\n\r]+" " " (or text ""))))

(defun agent-tasks--log (format-string &rest args)
  "Append a timestamped line built from FORMAT-STRING and ARGS to Log.
The Log section is append-only prose: the ledger writes it and never
reads it back for a decision."
  (agent-tasks--append-to-section
   "Log"
   (format "- %s %s"
           (format-time-string "[%Y-%m-%d %a %H:%M]")
           (agent-tasks--one-line (apply #'format format-string args)))))

(defun agent-tasks--append-to-section (name text)
  "Append TEXT as a line to section NAME of the task at point."
  (save-excursion
    (agent-tasks--section-append-point name)
    (insert text "\n")))

(defun agent-tasks--section-append-point (name)
  "Move point to where new content of section NAME should be inserted.
Create the section at the end of the entry when it is absent.  Point
must start inside the task's entry.  Return the new point."
  (org-back-to-heading t)
  (let ((end (agent-tasks--entry-end))
        (case-fold-search nil))
    (if (re-search-forward
         (format "^\\*\\* %s[ \t]*$" (regexp-quote name)) end t)
        (let ((stop (if (re-search-forward "^\\*\\{1,2\\} " end t)
                        (match-beginning 0)
                      end)))
          (goto-char stop)
          (skip-chars-backward " \t\n")
          (forward-line 1)
          (unless (bolp) (insert "\n")))
      (goto-char end)
      (skip-chars-backward " \t\n")
      (insert (format "\n\n** %s\n" name)))
    (point)))
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test`
Expected: `0 unexpected`, and the total rises by exactly the number of `ert-deftest` forms this task adds (count them in the diff).

- [ ] **Step 5: Byte-compile and commit**

```bash
make compile
git add agent-tasks.el test/agent-tasks-test.el
git commit -m "feat(tasks): add guarded atomic ledger writes"
```

---

### Task 3: Creating tasks, ids, and dependency validation

**Files:**
- Modify: `agent-tasks.el` (new "Creating tasks" and "Dependencies"
  sections)
- Test: `test/agent-tasks-test.el`

**Interfaces:**
- Consumes: Tasks 1 and 2.
- Produces (used by Tasks 4, 8, 10, 11):
  - `agent-tasks-create (&key TITLE INSTRUCTION DIRECTORY BACKEND
    ACCOUNT DEPENDS SOURCE-FILE SOURCE-HEADING)` → the new task's id.
  - `agent-tasks-new` (autoloaded command) → the new task's id.
  - `agent-tasks-edit (&optional ID)` — open the ledger at a heading.
  - `agent-tasks-validate LEDGER` → a list of `agent-tasks-problem`
    values for unknown dependencies and dependency cycles.
  - `agent-tasks-unsatisfied-dependencies LEDGER TASK` → a list of
    `(ID . DESCRIPTION)`.
  - `agent-tasks--new-id LEDGER`, `agent-tasks--entry-string`,
    `agent-tasks--property-line NAME VALUE`,
    `agent-tasks--repository DIRECTORY`,
    `agent-tasks--read-task-id LEDGER PROMPT &optional STATES`,
    `agent-tasks--read-backend`, `agent-tasks--read-dependencies`,
    `agent-tasks--dependency-cycles TASKS BY-ID`,
    `agent-tasks--cycle-members PATH ID`.

- [ ] **Step 1: Write the failing tests**

Add to `test/agent-tasks-test.el`:

```elisp
;;;; Creating tasks

(ert-deftest agent-tasks-test-create/writes-a-pending-task ()
  "A created task is PENDING, has attempt 0, and keeps its instruction."
  (agent-tasks-test--with-ledger nil
    (let* ((id (agent-tasks-create
                :title "Do the thing"
                :instruction "Line one\n* starred line"
                :directory dir))
           (task (agent-tasks-find (agent-tasks-read) id)))
      (should (string-match-p "\\`t-[0-9]\\{8\\}T[0-9]\\{6\\}-[0-9a-f]\\{4\\}\\'" id))
      (should (equal "PENDING" (agent-tasks-task-state task)))
      (should (equal "Do the thing" (agent-tasks-task-title task)))
      (should (equal "Line one\n* starred line"
                     (agent-tasks-task-instruction task)))
      (should (= 0 (agent-tasks-task-attempt task)))
      (should (agent-tasks-task-created task))
      (should (equal (agent-session--normalize-directory dir)
                     (agent-tasks-task-directory task))))))

(ert-deftest agent-tasks-test-create/omits-empty-properties ()
  "Fields that were not supplied leave no property behind."
  (agent-tasks-test--with-ledger nil
    (let ((id (agent-tasks-create :title "Bare")))
      (should-not (string-match-p ":BACKEND:"
                                  (agent-tasks--file-text agent-tasks-file)))
      (should-not (agent-tasks-task-backend
                   (agent-tasks-find (agent-tasks-read) id))))))

(ert-deftest agent-tasks-test-create/creates-the-four-sections ()
  "Every new task has Result, Evidence, Comments and Log."
  (agent-tasks-test--with-ledger nil
    (agent-tasks-create :title "Sections")
    (let ((text (agent-tasks--file-text agent-tasks-file)))
      (dolist (name agent-tasks--sections)
        (should (string-match-p (format "^\\*\\* %s$" name) text))))))

(ert-deftest agent-tasks-test-create/refuses-an-empty-title ()
  "A task needs a title."
  (agent-tasks-test--with-ledger nil
    (should-error (agent-tasks-create :title "   ") :type 'user-error)))

(ert-deftest agent-tasks-test-create/preserves-property-bytes ()
  "A property keeps its interior whitespace; a newline is refused."
  (agent-tasks-test--with-ledger nil
    (let ((id (agent-tasks-create
               :title "Imported"
               :source-file "/tmp/notes.org"
               :source-heading "* TODO  Two  spaces  kept")))
      (should (equal "* TODO  Two  spaces  kept"
                     (agent-tasks-task-source-heading
                      (agent-tasks-find (agent-tasks-read) id)))))
    (should-error (agent-tasks--property-line "SOURCE_HEADING" "a\nb"))))

(ert-deftest agent-tasks-test-create/star-heavy-instruction-round-trips ()
  "An instruction full of stars survives creation and parsing exactly."
  (agent-tasks-test--with-ledger nil
    (let* ((instruction "* top\n * indented\n   ** deep\nplain")
           (id (agent-tasks-create :title "Stars" :instruction instruction)))
      (should (equal instruction
                     (agent-tasks-task-instruction
                      (agent-tasks-find (agent-tasks-read) id))))
      ;; Every body star line was indented, so Org sees exactly one
      ;; column-zero heading for this entry: its own.
      (let ((text (agent-tasks--file-text agent-tasks-file)))
        (should (string-match-p "^\\* PENDING Stars$" text))
        (should (string-match-p "^ \\* top$" text))
        (should-not (string-match-p "^\\* top$" text))
        (should (string-match-p "^  \\* indented$" text))))))

(ert-deftest agent-tasks-test-create/concurrent-first-creation-conflicts ()
  "Two creators that both saw no ledger cannot both publish one.
The id generator is forced to collide, so the test fails loudly if the
second creator appends onto the file the first published instead of
refusing."
  (agent-tasks-test--with-ledger nil
    (let ((first-ledger (agent-tasks-read))
          (second-ledger (agent-tasks-read)))
      (should (null (agent-tasks-ledger-token first-ledger)))
      (should (null (agent-tasks-ledger-token second-ledger)))
      (cl-letf (((symbol-function 'agent-tasks--new-id)
                 (lambda (_ledger) "t-fixed")))
        (agent-tasks--append-entry
         first-ledger
         (lambda (fresh)
           (agent-tasks--entry-string :id (agent-tasks--new-id fresh)
                                      :title "First")))
        (should-error
         (agent-tasks--append-entry
          second-ledger
          (lambda (fresh)
            (agent-tasks--entry-string :id (agent-tasks--new-id fresh)
                                       :title "Second")))
         :type 'user-error))
      (let ((ledger (agent-tasks-read)))
        (should (= 1 (length (agent-tasks-ledger-tasks ledger))))
        (should (null (agent-tasks-ledger-problems ledger)))))))

(ert-deftest agent-tasks-test-create/two-tasks-get-distinct-ids ()
  "Ids are checked against the ledger, not merely generated."
  (agent-tasks-test--with-ledger nil
    (let ((first (agent-tasks-create :title "One"))
          (second (agent-tasks-create :title "Two")))
      (should-not (equal first second))
      (should (= 2 (length (agent-tasks-ledger-tasks (agent-tasks-read))))))))

;;;; Dependencies

(ert-deftest agent-tasks-test-dependencies/unsatisfied-lists-each-reason ()
  "A dependency is satisfied only when it is DONE and succeeded."
  (agent-tasks-test--with-ledger
      (concat agent-tasks--header
              "* PENDING A\n:PROPERTIES:\n:AGENT_TASK_ID: t-a\n"
              ":DEPENDS: t-b t-c t-d t-e\n:END:\n"
              "* PENDING B\n:PROPERTIES:\n:AGENT_TASK_ID: t-b\n:END:\n"
              "* DONE C\n:PROPERTIES:\n:AGENT_TASK_ID: t-c\n"
              ":OUTCOME: succeeded\n:END:\n"
              "* DONE D\n:PROPERTIES:\n:AGENT_TASK_ID: t-d\n"
              ":OUTCOME: failed\n:END:\n")
    (let* ((ledger (agent-tasks-read))
           (unsatisfied (agent-tasks-unsatisfied-dependencies
                         ledger (agent-tasks-find ledger "t-a"))))
      (should (equal '("t-b" "t-d" "t-e") (mapcar #'car unsatisfied)))
      (should (equal "PENDING" (cdr (assoc "t-b" unsatisfied))))
      (should (equal "not in the ledger" (cdr (assoc "t-e" unsatisfied)))))))

(ert-deftest agent-tasks-test-dependencies/unknown-id-is-a-problem ()
  "A dependency naming no task is reported."
  (agent-tasks-test--with-ledger
      (concat agent-tasks--header
              "* PENDING A\n:PROPERTIES:\n:AGENT_TASK_ID: t-a\n"
              ":DEPENDS: t-missing\n:END:\n")
    (let ((problems (agent-tasks-validate (agent-tasks-read))))
      (should (= 1 (length problems)))
      (should (equal "unknown dependency"
                     (agent-tasks-problem-issue (car problems))))
      (should (string-match-p "t-missing"
                              (agent-tasks-problem-detail (car problems)))))))

(ert-deftest agent-tasks-test-dependencies/reports-a-two-node-cycle ()
  "A cycle is reported with its members rather than silently blocking."
  (agent-tasks-test--with-ledger
      (concat agent-tasks--header
              "* PENDING A\n:PROPERTIES:\n:AGENT_TASK_ID: t-a\n"
              ":DEPENDS: t-b\n:END:\n"
              "* PENDING B\n:PROPERTIES:\n:AGENT_TASK_ID: t-b\n"
              ":DEPENDS: t-a\n:END:\n")
    (let* ((problems (agent-tasks-validate (agent-tasks-read)))
           (cycle (cl-find "dependency cycle" problems
                           :key #'agent-tasks-problem-issue :test #'equal)))
      (should cycle)
      (should (string-match-p "t-a" (agent-tasks-problem-detail cycle)))
      (should (string-match-p "t-b" (agent-tasks-problem-detail cycle))))))

(ert-deftest agent-tasks-test-dependencies/reports-a-self-cycle ()
  "A task depending on itself is a cycle of one."
  (agent-tasks-test--with-ledger
      (concat agent-tasks--header
              "* PENDING A\n:PROPERTIES:\n:AGENT_TASK_ID: t-a\n"
              ":DEPENDS: t-a\n:END:\n")
    (let ((problems (agent-tasks-validate (agent-tasks-read))))
      (should (cl-find "dependency cycle" problems
                       :key #'agent-tasks-problem-issue :test #'equal)))))

(ert-deftest agent-tasks-test-dependencies/a-diamond-is-not-a-cycle ()
  "Two paths to the same dependency are not a cycle."
  (agent-tasks-test--with-ledger
      (concat agent-tasks--header
              "* PENDING A\n:PROPERTIES:\n:AGENT_TASK_ID: t-a\n"
              ":DEPENDS: t-b t-c\n:END:\n"
              "* PENDING B\n:PROPERTIES:\n:AGENT_TASK_ID: t-b\n"
              ":DEPENDS: t-d\n:END:\n"
              "* PENDING C\n:PROPERTIES:\n:AGENT_TASK_ID: t-c\n"
              ":DEPENDS: t-d\n:END:\n"
              "* PENDING D\n:PROPERTIES:\n:AGENT_TASK_ID: t-d\n:END:\n")
    (should (null (agent-tasks-validate (agent-tasks-read))))))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test`
Expected: every test added in Step 1 fails, with `Symbol's function definition is void:
agent-tasks-create` and `agent-tasks-validate`.

- [ ] **Step 3: Implement creation and validation**

Add to `agent-tasks.el` after the editing section:

```elisp
;;;; Forward declarations

(declare-function org-fold-show-entry "org-fold" (&optional element))
(declare-function project-current "project" (&optional maybe-prompt directory))
(declare-function project-root "project" (project))

;;;; Creating tasks

(defun agent-tasks--new-id (ledger)
  "Return a task id not already used in LEDGER."
  (let ((id nil)
        (tries 0))
    (while (and (null id) (< tries 100))
      (let ((candidate (format "t-%s-%04x"
                               (format-time-string "%Y%m%dT%H%M%S" nil t)
                               (random 65536))))
        (unless (agent-tasks-find ledger candidate)
          (setq id candidate)))
      (setq tries (1+ tries)))
    (or id (error "Could not generate an unused task id"))))

(defun agent-tasks--property-line (name value)
  "Return a property drawer line for NAME and VALUE, or an empty string.
An empty value produces no line at all, so the ledger has exactly one
representation for \"absent\".  VALUE's bytes are preserved except for
outer whitespace, and a newline is an error — the same contract as
`agent-tasks--set-property', and for the same reason: revision 1 ran
every property through `agent-tasks--one-line', which collapsed runs of
whitespace inside a `SOURCE_HEADING' and then could not find that
heading again."
  (let ((string (and value (string-trim (format "%s" value)))))
    (when (and string (string-match-p "\n" string))
      (error "Ledger property %s cannot contain a newline: %S" name string))
    (if (and string (not (string-empty-p string)))
        (format ":%s: %s\n" name string)
      "")))

(cl-defun agent-tasks--entry-string (&key id title instruction directory
                                          repository backend account depends
                                          source-file source-heading)
  "Return the Org text of a new PENDING task entry."
  (let ((stamp (format-time-string "[%Y-%m-%d %a %H:%M]")))
    (concat
     (format "* PENDING %s\n" (agent-tasks--one-line title))
     ":PROPERTIES:\n"
     (format ":AGENT_TASK_ID: %s\n" id)
     (format ":CREATED: %s\n" stamp)
     (format ":UPDATED: %s\n" stamp)
     ":ATTEMPT: 0\n"
     ;; Records that this body went through the codec, so the parser
     ;; decodes it and leaves hand-written bodies alone.
     ":BODY_ENCODED: t\n"
     (agent-tasks--property-line "BACKEND" backend)
     (agent-tasks--property-line "ACCOUNT" account)
     (agent-tasks--property-line "DIRECTORY" directory)
     (agent-tasks--property-line "REPOSITORY" repository)
     (agent-tasks--property-line
      "DEPENDS" (and depends (string-join depends " ")))
     (agent-tasks--property-line "SOURCE_FILE" source-file)
     (agent-tasks--property-line "SOURCE_HEADING" source-heading)
     ":END:\n\n"
     (agent-tasks--escape-body
      (string-trim (or instruction title)))
     "\n\n"
     (mapconcat (lambda (name) (format "** %s\n" name))
                agent-tasks--sections "\n"))))

(defun agent-tasks--repository (directory)
  "Return the normalised git top level of DIRECTORY, or nil.
Resolved once, when the directory is recorded: which repository a task
belongs to is a fact worth keeping even after the worktree moves, and
silently re-deriving it later would change a recorded fact."
  (when (and directory (file-directory-p directory))
    (let ((default-directory directory))
      (with-temp-buffer
        (when (zerop (process-file "git" nil t nil
                                   "rev-parse" "--show-toplevel"))
          (let ((top (string-trim (buffer-string))))
            (unless (string-empty-p top)
              (agent-session--normalize-directory top))))))))

(cl-defun agent-tasks-create (&key title instruction directory backend
                                   account depends source-file source-heading)
  "Create a PENDING task in the ledger and return its new id.
Non-interactive: every task-creating path in this package funnels
through it.  DIRECTORY is normalised the way session identities are,
so a recorded directory compares `equal' with a live session's."
  (unless (and title (not (string-empty-p (string-trim title))))
    (user-error "A task needs a title"))
  (let* ((normalized (and directory
                          (agent-session--normalize-directory directory)))
         (repository (agent-tasks--repository normalized))
         (id nil))
    (agent-tasks--append-entry
     (agent-tasks-read)
     ;; The id is minted from the ledger as re-parsed under the lock,
     ;; not from the snapshot above, so two concurrent creators cannot
     ;; pick the same one.
     (lambda (fresh)
       (setq id (agent-tasks--new-id fresh))
       (agent-tasks--entry-string
        :id id :title title :instruction instruction
        :directory normalized :repository repository
        :backend backend :account account :depends depends
        :source-file source-file :source-heading source-heading)))
    id))

;;;###autoload
(defun agent-tasks-new ()
  "Create a task in the ledger and open it so the instruction can be written.
The instruction defaults to the title; the ledger file opens at the new
heading so a longer one can be typed with a real editor instead of the
minibuffer."
  (interactive)
  (let* ((title (read-string "Task title: "))
         (directory (read-directory-name
                     "Task directory: "
                     (or (when-let* ((project (project-current)))
                           (project-root project))
                         default-directory)))
         (backend (agent-tasks--read-backend))
         (depends (agent-tasks--read-dependencies (agent-tasks-read)))
         (id (agent-tasks-create :title title
                                 :directory directory
                                 :backend backend
                                 :depends depends)))
    (message "Created task %s" id)
    (agent-tasks-edit id)
    id))

;;;###autoload
(defun agent-tasks-edit (&optional id)
  "Open the ledger file at task ID's heading, prompting when ID is nil."
  (interactive)
  (let* ((ledger (agent-tasks-read))
         (id (or id (agent-tasks--read-task-id ledger "Edit task: ")))
         (buffer (find-file (agent-tasks-ledger-file ledger))))
    (with-current-buffer buffer
      (goto-char (point-min))
      (if-let* ((position (org-find-property "AGENT_TASK_ID" id)))
          (progn (goto-char position) (org-fold-show-entry))
        (message "Task %s is not in the ledger" id)))
    buffer))

;;;; Reading tasks from the user

(defun agent-tasks--read-task-id (ledger prompt &optional states)
  "Read a task id from LEDGER with PROMPT.
STATES, when non-nil, restricts the candidates to those states."
  (let* ((tasks (cl-remove-if-not
                 (lambda (task)
                   (or (null states)
                       (member (agent-tasks-task-state task) states)))
                 (agent-tasks-ledger-tasks ledger)))
         (candidates (mapcar #'agent-tasks--task-candidate tasks)))
    (unless candidates
      (user-error "No matching tasks in %s" (agent-tasks-ledger-file ledger)))
    (car (split-string (completing-read prompt candidates nil t)))))

(defun agent-tasks--task-candidate (task)
  "Return the completion candidate string for TASK.
The id is the first whitespace-delimited token, because
`completing-read-multiple' returns plain substrings with no text
properties, so the id has to survive in the visible text."
  (format "%s  %-9s %s"
          (agent-tasks-task-id task)
          (agent-tasks-task-state task)
          (agent-tasks-task-title task)))

(defun agent-tasks--read-backend ()
  "Read a backend name string for a task, or nil for none."
  (let ((names (mapcar (lambda (entry) (symbol-name (car entry)))
                       agent-backends)))
    (when names
      (let ((choice (completing-read "Backend (empty for none): "
                                     names nil t)))
        (unless (string-empty-p choice) choice)))))

(defun agent-tasks--read-dependencies (ledger)
  "Read zero or more dependency task ids from LEDGER."
  (let ((candidates (mapcar #'agent-tasks--task-candidate
                            (agent-tasks-ledger-tasks ledger))))
    (when candidates
      (mapcar (lambda (choice) (car (split-string choice)))
              (completing-read-multiple
               "Depends on (empty for none): " candidates nil t)))))

;;;; Dependencies

(defun agent-tasks-unsatisfied-dependencies (ledger task)
  "Return TASK's dependencies in LEDGER that do not permit a dispatch.
A dependency satisfies the gate only when it is DONE with outcome
`succeeded'.  Each element is (ID . DESCRIPTION)."
  (delq nil
        (mapcar
         (lambda (id)
           (let ((dependency (agent-tasks-find ledger id)))
             (cond
              ((null dependency) (cons id "not in the ledger"))
              ((not (equal "DONE" (agent-tasks-task-state dependency)))
               (cons id (agent-tasks-task-state dependency)))
              ((not (equal "succeeded" (agent-tasks-task-outcome dependency)))
               (cons id (format "DONE with outcome %s"
                                (or (agent-tasks-task-outcome dependency)
                                    "unrecorded"))))
              (t nil))))
         (agent-tasks-task-depends task))))

(defun agent-tasks-validate (ledger)
  "Return dependency problems in LEDGER, beyond its parse problems."
  (let ((by-id (make-hash-table :test 'equal))
        (tasks (agent-tasks-ledger-tasks ledger))
        problems)
    (dolist (task tasks)
      (puthash (agent-tasks-task-id task) task by-id))
    (dolist (task tasks)
      (dolist (dependency (agent-tasks-task-depends task))
        (unless (gethash dependency by-id)
          (push (agent-tasks-problem--create
                 :heading (agent-tasks-task-title task)
                 :issue "unknown dependency"
                 :detail (format "task %s depends on %s, which is not in the ledger"
                                 (agent-tasks-task-id task) dependency))
                problems))))
    (dolist (cycle (agent-tasks--dependency-cycles tasks by-id))
      (push (agent-tasks-problem--create
             :heading (or (when-let* ((task (gethash (car cycle) by-id)))
                            (agent-tasks-task-title task))
                          (car cycle))
             :issue "dependency cycle"
             :detail (format "cycle: %s"
                             (string-join (append cycle (list (car cycle)))
                                          " → ")))
            problems))
    (nreverse problems)))

(defun agent-tasks--dependency-cycles (tasks by-id)
  "Return each dependency cycle among TASKS as a list of ids.
BY-ID maps id to task.  A three-colour depth-first walk reports each
cycle once with its members: without this, a cycle would make the
dispatch gate permanently unsatisfiable with no explanation anywhere."
  (let ((color (make-hash-table :test 'equal))
        (cycles nil))
    (cl-labels
        ((visit (id path)
           (pcase (gethash id color)
             ('done nil)
             ('active (push (agent-tasks--cycle-members path id) cycles))
             (_
              (puthash id 'active color)
              (dolist (dependency (agent-tasks-task-depends
                                   (gethash id by-id)))
                (when (gethash dependency by-id)
                  (visit dependency (cons id path))))
              (puthash id 'done color)))))
      (dolist (task tasks)
        (visit (agent-tasks-task-id task) nil)))
    (nreverse cycles)))

(defun agent-tasks--cycle-members (path id)
  "Return the members of the dependency cycle closed by ID.
PATH lists the ancestors of the current edge, newest first, and
contains ID.  The result is in dependency order, starting at ID."
  (let ((members nil)
        (rest path))
    (while (and rest (not (equal (car rest) id)))
      (push (car rest) members)
      (setq rest (cdr rest)))
    (when rest (push (car rest) members))
    members))
```

Note the `(visit ... (cons id path))` recursion: `path` excludes the
node being visited, so when the walk meets an active node the ancestor
list still holds it and `agent-tasks--cycle-members` can cut the cycle
out of it.  A self-dependency reaches `active` immediately with
`path` = `(id)`, and the helper returns `(id)`, which renders as
`cycle: t-a → t-a`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test`
Expected: `0 unexpected`, and the total rises by exactly the number of `ert-deftest` forms this task adds (count them in the diff).

- [ ] **Step 5: Byte-compile and commit**

```bash
make compile
git add agent-tasks.el test/agent-tasks-test.el
git commit -m "feat(tasks): add task creation and dependency validation"
```

---

### Task 4: The state machine and its person-initiated commands

**Files:**
- Modify: `agent-tasks.el` (new "State transitions" section)
- Test: `test/agent-tasks-test.el`

**Interfaces:**
- Consumes: Tasks 1–3.
- Produces (used by Tasks 6, 7, 8, 9, 10):
  - `agent-tasks-transition (LEDGER ID STATE REASON &key ONLY-WHEN
    EXTRA)` → a freshly parsed ledger; signals a `user-error` when the
    current state is not in ONLY-WHEN.  EXTRA is a thunk run at the
    heading before the state change.
  - `agent-tasks--safe-transition (ID STATE REASON &key ONLY-WHEN)` →
    non-nil when written.  Warns instead of signalling; this is the
    only entry point evidence paths may use.
  - `agent-tasks--safe-log (ID FORMAT &rest ARGS)` → non-nil when
    written.
  - Commands `agent-tasks-mark-done`, `agent-tasks-cancel`,
    `agent-tasks-mark-blocked`, `agent-tasks-reopen`,
    `agent-tasks-add-comment`.
  - `agent-tasks--read-reason PROMPT` — a non-empty string or a
    `user-error`.

- [ ] **Step 1: Write the failing tests**

Add to `test/agent-tasks-test.el`:

```elisp
;;;; State transitions

(defmacro agent-tasks-test--with-task (state &rest body)
  "Run BODY with a single ledger task in STATE, bound to `id'.
Also binds `dir' and `agent-tasks-file' as
`agent-tasks-test--with-ledger' does.  Setting up a `BLOCKED' or `DONE'
task supplies the property that state requires: without it the parser
reports a problem row and `agent-tasks-find' would return nil, so the
test would fail on its own scaffolding."
  (declare (indent 1) (debug (form body)))
  `(agent-tasks-test--with-ledger nil
     (let ((id (agent-tasks-create :title "Subject" :instruction "Do it")))
       (unless (equal ,state "PENDING")
         (agent-tasks--update-task
          (agent-tasks-read) id
          (lambda ()
            (pcase ,state
              ("BLOCKED"
               (agent-tasks--set-property "BLOCKED_REASON" "test setup"))
              ("DONE"
               (agent-tasks--set-property "OUTCOME" "succeeded")))
            (agent-tasks--set-state ,state "test setup"))))
       ,@body)))

(ert-deftest agent-tasks-test-transition/writes-state-and-a-log-line ()
  "A transition records the new state and why it happened."
  (agent-tasks-test--with-task "PENDING"
    (agent-tasks-transition (agent-tasks-read) id "RUNNING" "dispatch")
    (let ((task (agent-tasks-find (agent-tasks-read) id)))
      (should (equal "RUNNING" (agent-tasks-task-state task)))
      (should (string-match-p "PENDING → RUNNING (dispatch)"
                              (agent-tasks-task-log task))))))

(ert-deftest agent-tasks-test-transition/enforces-the-whole-matrix ()
  "Every pair in the matrix is allowed and every other pair is refused.
Driven as a table rather than by example, because the defect this
guards against is a *missing* rule, which examples cannot find."
  (dolist (from agent-tasks--states)
    (dolist (to agent-tasks--states)
      (let ((allowed (member to (cdr (assoc from
                                            agent-tasks--transition-matrix)))))
        (agent-tasks-test--with-task from
          (let ((extra (pcase to
                         ("BLOCKED"
                          (lambda ()
                            (agent-tasks--set-property "BLOCKED_REASON" "r")))
                         ("DONE"
                          (lambda ()
                            (agent-tasks--set-property "OUTCOME" "succeeded")))
                         (_ nil))))
            (if allowed
                (progn
                  (agent-tasks-transition (agent-tasks-read) id to "matrix"
                                          :extra extra)
                  (should (equal to (agent-tasks-task-state
                                     (agent-tasks-find (agent-tasks-read) id)))))
              (should-error
               (agent-tasks-transition (agent-tasks-read) id to "matrix"
                                       :extra extra)
               :type 'user-error)
              (should (equal from (agent-tasks-task-state
                                   (agent-tasks-find (agent-tasks-read)
                                                     id)))))))))))

(ert-deftest agent-tasks-test-transition/refuses-pending-to-blocked ()
  "The one transition revision 1 allowed against its own table."
  (agent-tasks-test--with-task "PENDING"
    (should-error
     (agent-tasks-transition
      (agent-tasks-read) id "BLOCKED" "x"
      :extra (lambda () (agent-tasks--set-property "BLOCKED_REASON" "r")))
     :type 'user-error)
    (should-error (agent-tasks-mark-blocked id "stuck") :type 'user-error)))

(ert-deftest agent-tasks-test-transition/requires-a-reason ()
  "The API refuses a blank reason, not just the cancel command."
  (agent-tasks-test--with-task "PENDING"
    (should-error (agent-tasks-transition (agent-tasks-read) id "CANCELLED" "")
                  :type 'user-error)
    (should-error (agent-tasks-transition (agent-tasks-read) id "CANCELLED" "  ")
                  :type 'user-error)
    (should (equal "PENDING" (agent-tasks-task-state
                              (agent-tasks-find (agent-tasks-read) id))))))

(ert-deftest agent-tasks-test-transition/enforces-destination-invariants ()
  "A destination's required and forbidden properties are both checked."
  (agent-tasks-test--with-task "RUNNING"
    ;; BLOCKED with no reason.
    (should-error (agent-tasks-transition (agent-tasks-read) id "BLOCKED" "x")
                  :type 'error)
    ;; DONE with no outcome.
    (should-error (agent-tasks-transition (agent-tasks-read) id "DONE" "x")
                  :type 'error)
    (should (equal "RUNNING" (agent-tasks-task-state
                              (agent-tasks-find (agent-tasks-read) id)))))
  ;; A stale reason cannot survive a move to a state that forbids it.
  (agent-tasks-test--with-task "RUNNING"
    (agent-tasks-mark-blocked id "waiting")
    (agent-tasks-transition (agent-tasks-read) id "UNKNOWN" "lost")
    (should (null (agent-tasks-task-blocked-reason
                   (agent-tasks-find (agent-tasks-read) id))))))

(ert-deftest agent-tasks-test-mark-done/requires-an-outcome ()
  "DONE without an outcome is refused."
  (agent-tasks-test--with-task "RUNNING"
    (should-error (agent-tasks-mark-done id nil nil nil) :type 'user-error)
    (should-error (agent-tasks-mark-done id "maybe" nil nil)
                  :type 'user-error)
    (agent-tasks-mark-done id "succeeded" "it worked" "make test clean")
    (let ((task (agent-tasks-find (agent-tasks-read) id)))
      (should (equal "DONE" (agent-tasks-task-state task)))
      (should (equal "succeeded" (agent-tasks-task-outcome task)))
      (should (string-match-p "it worked" (agent-tasks-task-result task)))
      (should (string-match-p "make test clean"
                              (agent-tasks-task-evidence task))))))

(ert-deftest agent-tasks-test-mark-blocked/requires-a-reason ()
  "BLOCKED records why."
  (agent-tasks-test--with-task "RUNNING"
    (should-error (agent-tasks-mark-blocked id "  ") :type 'user-error)
    (agent-tasks-mark-blocked id "waiting on a credential")
    (let ((task (agent-tasks-find (agent-tasks-read) id)))
      (should (equal "BLOCKED" (agent-tasks-task-state task)))
      (should (equal "waiting on a credential"
                     (agent-tasks-task-blocked-reason task))))))

(ert-deftest agent-tasks-test-cancel/requires-a-reason-and-is-terminal ()
  "CANCELLED records why and is not DONE."
  (agent-tasks-test--with-task "PENDING"
    (should-error (agent-tasks-cancel id "") :type 'user-error)
    (agent-tasks-cancel id "no longer wanted")
    (let ((task (agent-tasks-find (agent-tasks-read) id)))
      (should (equal "CANCELLED" (agent-tasks-task-state task)))
      (should (null (agent-tasks-task-outcome task)))
      (should (string-match-p "no longer wanted" (agent-tasks-task-log task))))))

(ert-deftest agent-tasks-test-reopen/clears-the-outcome ()
  "Reopening a closed task returns it to PENDING with no stale outcome.
Both confirmation answers are stubbed: `yes-or-no-p' unstubbed in a
batch run reads from standard input, so the test would hang or fail on
its own scaffolding rather than on the behaviour."
  (agent-tasks-test--with-task "RUNNING"
    (agent-tasks-mark-done id "failed" nil nil)
    ;; Declined: nothing changes.
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
      (should-error (agent-tasks-reopen id) :type 'user-error))
    (should (equal "DONE" (agent-tasks-task-state
                           (agent-tasks-find (agent-tasks-read) id))))
    ;; Accepted: back to PENDING with no stale outcome.
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
      (agent-tasks-reopen id))
    (let ((task (agent-tasks-find (agent-tasks-read) id)))
      (should (equal "PENDING" (agent-tasks-task-state task)))
      (should (null (agent-tasks-task-outcome task))))))

(ert-deftest agent-tasks-test-mark-blocked/clears-on-leaving-blocked ()
  "The blocked reason does not outlive the blocked state."
  (agent-tasks-test--with-task "RUNNING"
    (agent-tasks-mark-blocked id "waiting")
    (agent-tasks-transition (agent-tasks-read) id "RUNNING" "resumed")
    (should (null (agent-tasks-task-blocked-reason
                   (agent-tasks-find (agent-tasks-read) id))))))

(ert-deftest agent-tasks-test-add-comment/appends-without-touching-state ()
  "A comment is recorded and changes nothing else."
  (agent-tasks-test--with-task "PENDING"
    (agent-tasks-add-comment id "look at the retry path")
    (let ((task (agent-tasks-find (agent-tasks-read) id)))
      (should (equal "PENDING" (agent-tasks-task-state task)))
      (should (string-match-p "look at the retry path"
                              (agent-tasks-task-comments task))))))

(ert-deftest agent-tasks-test-safe-transition/warns-instead-of-signalling ()
  "An evidence path never signals out of a failed write."
  (agent-tasks-test--with-task "RUNNING"
    (let ((warnings nil))
      (cl-letf (((symbol-function 'agent-tasks--update-task)
                 (lambda (&rest _) (error "no disk")))
                ((symbol-function 'display-warning)
                 (lambda (_type message &rest _) (push message warnings))))
        (should-not (agent-tasks--safe-transition id "UNKNOWN" "gone"))
        (should (= 1 (length warnings)))
        (should (string-match-p "no disk" (car warnings)))))))

(ert-deftest agent-tasks-test-safe-transition/honours-only-when ()
  "An evidence transition that does not apply writes nothing."
  (agent-tasks-test--with-task "DONE"
    (should-not (agent-tasks--safe-transition
                 id "UNKNOWN" "gone" :only-when agent-tasks--live-states))
    (should (equal "DONE" (agent-tasks-task-state
                           (agent-tasks-find (agent-tasks-read) id))))))

(ert-deftest agent-tasks-test-safe-transition/ignores-a-missing-task ()
  "A binding to a task that was deleted by hand is not an error."
  (agent-tasks-test--with-ledger nil
    (should-not (agent-tasks--safe-transition "t-gone" "UNKNOWN" "gone"))))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test`
Expected: every test added in Step 1 fails, with `Symbol's function definition is void:
agent-tasks-transition`.

- [ ] **Step 3: Implement the state machine**

Add to `agent-tasks.el`:

```elisp
;;;; State transitions

(defconst agent-tasks--transition-matrix
  '(("PENDING"   . ("RUNNING" "DONE" "CANCELLED"))
    ("RUNNING"   . ("BLOCKED" "UNKNOWN" "DONE" "CANCELLED"))
    ("BLOCKED"   . ("RUNNING" "BLOCKED" "UNKNOWN" "PENDING" "DONE" "CANCELLED"))
    ("UNKNOWN"   . ("RUNNING" "PENDING" "DONE" "CANCELLED"))
    ("DONE"      . ("PENDING"))
    ("CANCELLED" . ("PENDING")))
  "The only transitions the ledger permits, as FROM → allowed TOs.
This is the spec's table, transcribed.  `agent-tasks-transition'
validates every call against it, rather than trusting each caller to
pass a correct source-state list: with a per-caller check, a caller that
forgot one could write any transition at all and the table would be
documentation rather than a rule.

`PENDING' → `BLOCKED' is deliberately absent.  A task that has never
run and cannot start is either still pending or cancelled; `BLOCKED' is
for a run that started and stopped needing a person.")

(defun agent-tasks--check-destination (state)
  "Signal unless the task at point satisfies STATE's invariants.
Run after the caller's property thunk and before the write commits, so
the ledger cannot hold a `DONE' record nobody characterised or a
`BLOCKED' record that does not say why — the same two conditions the
parser reports as problem rows, checked on the way in as well as out."
  (let ((reason (agent-tasks--property "BLOCKED_REASON"))
        (outcome (agent-tasks--property "OUTCOME")))
    (pcase state
      ("BLOCKED"
       (unless reason
         (error "A BLOCKED task needs a BLOCKED_REASON"))
       (when outcome
         (error "A BLOCKED task must not carry an OUTCOME")))
      ("DONE"
       (unless (member outcome '("succeeded" "failed"))
         (error "A DONE task needs OUTCOME `succeeded' or `failed', not %S"
                outcome))
       (when reason
         (error "A DONE task must not carry a BLOCKED_REASON")))
      (_
       (when reason
         (error "A %s task must not carry a BLOCKED_REASON" state))
       (when outcome
         (error "A %s task must not carry an OUTCOME" state))))))

(cl-defun agent-tasks-transition (ledger id state reason &key extra)
  "Move task ID in LEDGER to STATE with REASON and return the new ledger.
Signal a `user-error' when the task is missing or when the move is not
in `agent-tasks--transition-matrix'.  EXTRA is a function of no
arguments run at the task's heading before the state change, for
properties the new state requires.

This is the only function that changes a state.  It is the
person-initiated entry point and it signals; evidence paths reach it
through `agent-tasks--safe-transition', which warns instead."
  (unless (and (stringp reason)
               (not (string-empty-p (string-trim reason))))
    ;; Enforced here, not only in `agent-tasks-cancel': a caller
    ;; reaching this API directly could otherwise cancel a task with no
    ;; recorded reason, and the reason is the whole record of why.
    (user-error "A transition needs a non-blank reason"))
  (let* ((task (or (agent-tasks-find ledger id)
                   (user-error "No task with id %s" id)))
         (from (agent-tasks-task-state task))
         (allowed (cdr (assoc from agent-tasks--transition-matrix))))
    (unless (member state allowed)
      (user-error "Task %s cannot go from %s to %s (allowed: %s)"
                  id from state
                  (if allowed (string-join allowed ", ") "nothing")))
    (agent-tasks--update-task
     ledger id
     (lambda ()
       ;; Clear the properties the destination must not carry before the
       ;; caller sets the ones it must.
       (unless (equal state "BLOCKED")
         (agent-tasks--set-property "BLOCKED_REASON" nil))
       (unless (equal state "DONE")
         (agent-tasks--set-property "OUTCOME" nil))
       (when extra (funcall extra))
       (agent-tasks--check-destination state)
       (agent-tasks--set-state state reason)))))

(cl-defun agent-tasks--safe-transition (id state reason &key only-when)
  "Move task ID to STATE with REASON without ever signalling.
Return non-nil when the ledger was written.  A missing task, a state
outside ONLY-WHEN, and a failed write are all handled here: an
evidence path runs inside session-event delivery or a teardown hook,
where a signal would break the other consumers.

ONLY-WHEN is an *applicability* filter for the caller — \"does this
evidence apply to a task in this state\" — and is deliberately not the
transition check.  `agent-tasks-transition' validates the move against
`agent-tasks--transition-matrix' on every call, so a caller cannot
widen what is legal by passing a laxer list."
  (condition-case err
      (let* ((ledger (agent-tasks-read))
             (task (agent-tasks-find ledger id)))
        (when (and task
                   (or (null only-when)
                       (member (agent-tasks-task-state task) only-when)))
          (agent-tasks-transition ledger id state reason)
          t))
    (error
     (display-warning
      'agent-tasks
      (format "could not move task %s to %s: %s"
              id state (error-message-string err))
      :warning)
     nil)))

(defun agent-tasks--safe-log (id format-string &rest args)
  "Append a log line to task ID without ever signalling.
Return non-nil when the ledger was written."
  (condition-case err
      (let ((ledger (agent-tasks-read)))
        (when (agent-tasks-find ledger id)
          (agent-tasks--update-task
           ledger id
           (lambda () (apply #'agent-tasks--log format-string args)))
          t))
    (error
     (display-warning
      'agent-tasks
      (format "could not log against task %s: %s"
              id (error-message-string err))
      :warning)
     nil)))

;;;; Closing and annotating commands

(defun agent-tasks--read-reason (prompt)
  "Read a non-empty reason with PROMPT, or signal a `user-error'."
  (let ((reason (string-trim (read-string prompt))))
    (when (string-empty-p reason)
      (user-error "A reason is required"))
    reason))

;;;###autoload
(defun agent-tasks-mark-done (id outcome result evidence)
  "Close task ID as DONE with OUTCOME, recording RESULT and EVIDENCE.
OUTCOME is \"succeeded\" or \"failed\"; DONE without one would record
a completion nobody characterised.  RESULT and EVIDENCE may be nil."
  (interactive
   (let* ((ledger (agent-tasks-read))
          (id (agent-tasks--read-task-id ledger "Close task: "
                                         agent-tasks--open-states)))
     (list id
           (completing-read "Outcome: " '("succeeded" "failed") nil t)
           (read-string "Result (optional): ")
           (read-string "Verification evidence (optional): "))))
  (unless (member outcome '("succeeded" "failed"))
    (user-error "Outcome must be `succeeded' or `failed'"))
  (agent-tasks-transition
   (agent-tasks-read) id "DONE" (format "closed as %s" outcome)
   :extra
   (lambda ()
     (agent-tasks--set-property "OUTCOME" outcome)
     (when (and result (not (string-empty-p (string-trim result))))
       (agent-tasks--append-to-section "Result" (string-trim result)))
     (when (and evidence (not (string-empty-p (string-trim evidence))))
       (agent-tasks--append-to-section "Evidence" (string-trim evidence)))))
  (message "Task %s closed as %s" id outcome))

;;;###autoload
(defun agent-tasks-cancel (id reason)
  "Close task ID as CANCELLED, recording REASON.
Cancelling is not the same as finishing, which is why the ledger has
both states: marking abandoned work DONE would record something
untrue in the one artifact whose point is to be true."
  (interactive
   (let* ((ledger (agent-tasks-read))
          (id (agent-tasks--read-task-id ledger "Cancel task: "
                                         agent-tasks--open-states)))
     (list id (agent-tasks--read-reason "Reason for cancelling: "))))
  (when (string-empty-p (string-trim (or reason "")))
    (user-error "A reason is required"))
  (agent-tasks-transition
   (agent-tasks-read) id "CANCELLED" (format "cancelled: %s" reason))
  (message "Task %s cancelled" id))

;;;###autoload
(defun agent-tasks-mark-blocked (id reason)
  "Mark task ID as BLOCKED, recording REASON."
  (interactive
   (let* ((ledger (agent-tasks-read))
          (id (agent-tasks--read-task-id ledger "Block task: "
                                         '("RUNNING" "BLOCKED"))))
     (list id (agent-tasks--read-reason "Reason for blocking: "))))
  (when (string-empty-p (string-trim (or reason "")))
    (user-error "A reason is required"))
  (agent-tasks-transition
   (agent-tasks-read) id "BLOCKED" (format "blocked: %s" reason)
   :extra (lambda () (agent-tasks--set-property "BLOCKED_REASON" reason)))
  (message "Task %s blocked" id))

;;;###autoload
(defun agent-tasks-reopen (id)
  "Return closed task ID to PENDING after confirmation."
  (interactive
   (list (agent-tasks--read-task-id (agent-tasks-read) "Reopen task: "
                                    agent-tasks--closed-states)))
  (let ((task (or (agent-tasks-find (agent-tasks-read) id)
                  (user-error "No task with id %s" id))))
    (unless (yes-or-no-p
             (format "Reopen %s (%s)? " (agent-tasks-task-title task)
                     (agent-tasks-task-state task)))
      (user-error "Not reopened")))
  (agent-tasks-transition
   (agent-tasks-read) id "PENDING" "reopened")
  (message "Task %s reopened" id))

;;;###autoload
(defun agent-tasks-add-comment (id comment)
  "Append COMMENT to task ID's Comments section."
  (interactive
   (let ((id (agent-tasks--read-task-id (agent-tasks-read) "Comment on task: ")))
     (list id (read-string "Comment: "))))
  (when (string-empty-p (string-trim (or comment "")))
    (user-error "A comment is required"))
  (agent-tasks--update-task
   (agent-tasks-read) id
   (lambda ()
     (agent-tasks--append-to-section
      "Comments"
      (format "- %s %s"
              (format-time-string "[%Y-%m-%d %a %H:%M]")
              (string-trim comment)))))
  (message "Comment added to task %s" id))
```

Note the `BLOCKED_REASON` rule inside `agent-tasks-transition`: any
transition to a state other than `BLOCKED` clears it, and the `:extra`
thunk for `agent-tasks-mark-blocked` sets it *before* the state change,
so a reason never outlives the state it explains.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test`
Expected: `0 unexpected`, and the total rises by exactly the number of `ert-deftest` forms this task adds (count them in the diff).

- [ ] **Step 5: Byte-compile and commit**

```bash
make compile
git add agent-tasks.el test/agent-tasks-test.el
git commit -m "feat(tasks): add the ledger state machine and closing commands"
```

---

### Task 5: The mode, session bindings, and teardown

**Files:**
- Modify: `agent-tasks.el` (new "Bindings" and "Mode" sections)
- Test: `test/agent-tasks-test.el`

**Interfaces:**
- Consumes: Tasks 1–4; `agent-session-id-functions`,
  `agent--teardown-functions`, `agent-session`, `agent-session-id`,
  `agent-session-buffers`, `agent-display-name`.
- Produces (used by Tasks 6–11):
  - `agent-tasks-mode` — global minor mode owning every hook.
  - `agent-tasks--bindings` — hash table, live session buffer → task id.
  - `agent-tasks--bind BUFFER ID`, `agent-tasks--unbind BUFFER`,
    `agent-tasks-bound-task BUFFER` → id or nil,
    `agent-tasks-task-buffer ID` → live buffer or nil,
    `agent-tasks--check-bindable BUFFER ID` — signal unless the
    bijection permits this pairing, without changing anything.
  - `agent-tasks--release-binding ID` — drop a task's binding after a
    durable close.
  - Amendments to `agent-tasks-mark-done` and `agent-tasks-cancel` from
    Task 4, which now release the binding after the write succeeds.
  - `agent-tasks--record-session-id BUFFER` — the
    `agent-session-id-functions` consumer.
  - `agent-tasks--session-torn-down` — the teardown closure.
  - `agent-tasks--attention BUFFER TITLE DETAIL` — file an attention
    item for an `UNKNOWN` task, or fall back to `message`.
  - `agent-tasks--require-mode` — `user-error` when the mode is off.
  - `agent-tasks-unbind` (command).

- [ ] **Step 1: Write the failing tests**

Add to `test/agent-tasks-test.el`:

```elisp
;;;; Bindings and the mode

(defmacro agent-tasks-test--with-session (name &rest body)
  "Run BODY with a stub session buffer bound to NAME.
Registers a backend whose predicate recognises only that buffer, gives
the buffer an `agent-session' identity, and gives the test its own
binding table so tests cannot leak bindings into one another."
  (declare (indent 1) (debug (symbolp body)))
  `(let ((agent-backends nil)
         (agent-tasks--bindings (make-hash-table :test 'eq)))
     (with-temp-buffer
       (rename-buffer "*stub:~/scratch/proj/:default*" t)
       (let ((,name (current-buffer)))
         (apply #'agent-register-backend 'stub
                (agent-tasks-test--backend
                 :buffer-p (lambda (candidate) (eq candidate ,name))
                 :find-all-buffers (lambda () (list ,name))))
         (setq-local agent--session
                     (agent-session-create
                      :backend 'stub
                      :account "acct"
                      :directory "~/scratch/proj/"
                      :instance "default"))
         (setq-local agent--backend 'stub)
         ,@body))))

(ert-deftest agent-tasks-test-mode/installs-and-removes-its-hooks ()
  "Enabling the mode installs exactly the hooks disabling it removes."
  (let ((before (list (copy-sequence agent-session-id-functions)
                      (copy-sequence
                       (bound-and-true-p agent-session-event-functions)))))
    (agent-tasks-mode 1)
    (should (memq #'agent-tasks--record-session-id agent-session-id-functions))
    (agent-tasks-mode -1)
    (should (equal before
                   (list (copy-sequence agent-session-id-functions)
                         (copy-sequence
                          (bound-and-true-p agent-session-event-functions)))))))

(ert-deftest agent-tasks-test-mode/dispatch-requires-the-mode ()
  "A command that needs the mode says so instead of half-working."
  (agent-tasks-mode -1)
  (let ((error-message (cadr (should-error (agent-tasks--require-mode)
                                           :type 'user-error))))
    (should (string-match-p "agent-tasks-mode" error-message))))

(ert-deftest agent-tasks-test-bind/round-trips-a-buffer-and-an-id ()
  "A binding is visible from both directions."
  (agent-tasks-test--with-ledger nil
    (agent-tasks-test--with-session buffer
      (let ((id (agent-tasks-create :title "Bound")))
        (agent-tasks--bind buffer id)
        (should (equal id (agent-tasks-bound-task buffer)))
        (should (eq buffer (agent-tasks-task-buffer id)))
        (agent-tasks--unbind buffer)
        (should-not (agent-tasks-bound-task buffer))
        (should-not (agent-tasks-task-buffer id))))))

(ert-deftest agent-tasks-test-bind/refuses-a-second-task-in-one-session ()
  "Two tasks in one session would make every later event ambiguous."
  (agent-tasks-test--with-ledger nil
    (agent-tasks-test--with-session buffer
      (let ((first (agent-tasks-create :title "One"))
            (second (agent-tasks-create :title "Two")))
        (agent-tasks--bind buffer first)
        (should-error (agent-tasks--bind buffer second) :type 'user-error)
        (should (equal first (agent-tasks-bound-task buffer)))))))

(ert-deftest agent-tasks-test-bind/refuses-one-task-in-two-sessions ()
  "The bijection holds in the task → session direction too."
  (agent-tasks-test--with-ledger nil
    (agent-tasks-test--with-session first-buffer
      (with-temp-buffer
        (rename-buffer "*stub:~/scratch/other/:default*" t)
        (let ((second-buffer (current-buffer))
              (id (agent-tasks-create :title "One")))
          (setq-local agent--session
                      (agent-session-create :backend 'stub
                                            :directory "~/scratch/other/"))
          (setq-local agent--backend 'stub)
          (agent-tasks--bind first-buffer id)
          (should-error (agent-tasks--bind second-buffer id) :type 'user-error)
          (should (eq first-buffer (agent-tasks-task-buffer id))))))))

(ert-deftest agent-tasks-test-close/releases-the-binding ()
  "Closing frees the session; a failed close does not."
  (agent-tasks-test--with-ledger nil
    (agent-tasks-test--with-session buffer
      (let ((id (agent-tasks-create :title "Bound")))
        (agent-tasks--bind buffer id)
        ;; A close that signals leaves the binding alone.
        (cl-letf (((symbol-function 'agent-tasks--update-task)
                   (lambda (&rest _) (user-error "read-only"))))
          (should-error (agent-tasks-mark-done id "succeeded" nil nil)
                        :type 'user-error))
        (should (equal id (agent-tasks-bound-task buffer)))
        ;; A close that succeeds frees it.
        (agent-tasks-mark-done id "succeeded" nil nil)
        (should-not (agent-tasks-bound-task buffer))))))

(ert-deftest agent-tasks-test-session-id/records-the-native-id ()
  "The id consumer fills SESSION_ID for a bound buffer only."
  (agent-tasks-test--with-ledger nil
    (agent-tasks-test--with-session buffer
      (let ((id (agent-tasks-create :title "Bound")))
        (agent-tasks--record-session-id buffer)
        (should-not (agent-tasks-task-session-id
                     (agent-tasks-find (agent-tasks-read) id)))
        (agent-tasks--bind buffer id)
        (setf (agent-session-id (agent-session buffer)) "sid-9")
        (agent-tasks--record-session-id buffer)
        (should (equal "sid-9"
                       (agent-tasks-task-session-id
                        (agent-tasks-find (agent-tasks-read) id))))))))

(ert-deftest agent-tasks-test-teardown/moves-a-live-task-to-unknown ()
  "A session that ends without an outcome leaves the task UNKNOWN."
  (agent-tasks-test--with-ledger nil
    (agent-tasks-test--with-session buffer
      (let ((id (agent-tasks-create :title "Bound")))
        (agent-tasks--update-task
         (agent-tasks-read) id
         (lambda () (agent-tasks--set-state "RUNNING" "setup")))
        (agent-tasks--bind buffer id)
        (with-current-buffer buffer (agent-tasks--session-torn-down))
        (let ((task (agent-tasks-find (agent-tasks-read) id)))
          (should (equal "UNKNOWN" (agent-tasks-task-state task)))
          (should (string-match-p "session ended without a recorded outcome"
                                  (agent-tasks-task-log task))))
        (should-not (agent-tasks-bound-task buffer))))))

(ert-deftest agent-tasks-test-teardown/leaves-a-closed-task-alone ()
  "Teardown does not disturb a task the person already closed."
  (agent-tasks-test--with-ledger nil
    (agent-tasks-test--with-session buffer
      (let ((id (agent-tasks-create :title "Bound")))
        (agent-tasks--bind buffer id)
        (agent-tasks-mark-done id "succeeded" nil nil)
        (with-current-buffer buffer (agent-tasks--session-torn-down))
        (should (equal "DONE" (agent-tasks-task-state
                               (agent-tasks-find (agent-tasks-read) id))))))))

(ert-deftest agent-tasks-test-teardown/an-unbound-buffer-changes-nothing ()
  "Teardown after a deliberate detach reports no lost session.
This is what the restart path relies on: it detaches the binding
before the kill, so teardown finds nothing to report and needs no
special-case flag."
  (agent-tasks-test--with-ledger nil
    (agent-tasks-test--with-session buffer
      (let ((id (agent-tasks-create :title "Bound")))
        (agent-tasks--update-task
         (agent-tasks-read) id
         (lambda () (agent-tasks--set-state "RUNNING" "setup")))
        (agent-tasks--bind buffer id)
        (agent-tasks--unbind buffer)
        (with-current-buffer buffer (agent-tasks--session-torn-down))
        (should (equal "RUNNING" (agent-tasks-task-state
                                  (agent-tasks-find (agent-tasks-read) id))))))))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test`
Expected: every test added in Step 1 fails, with `Symbol's function definition is void:
agent-tasks-mode`.

- [ ] **Step 3: Implement bindings, the id consumer, teardown, and the mode**

Add to `agent-tasks.el`:

```elisp
;;;; Session bindings

(defvar agent-tasks--bindings (make-hash-table :test 'eq)
  "Map from a live session buffer to the id of the task bound to it.
Deliberately in memory only: a buffer reference means nothing after a
restart.  The durable half of a binding is the task's recorded
identity properties, which is what reconciliation matches against.")

(defun agent-tasks-bound-task (buffer)
  "Return the id of the task bound to session BUFFER, or nil."
  (and (buffer-live-p buffer) (gethash buffer agent-tasks--bindings)))

(defun agent-tasks-task-buffer (id)
  "Return the live session buffer bound to task ID, or nil."
  (let (found)
    (maphash (lambda (buffer bound)
               (when (and (equal bound id) (buffer-live-p buffer))
                 (setq found buffer)))
             agent-tasks--bindings)
    found))

(defun agent-tasks--check-bindable (buffer id)
  "Signal unless task ID may be bound to session BUFFER.
Checks the bijection in **both** directions and changes nothing, so a
caller can preflight before it sends anything.  Revision 1 checked only
buffer → task, so a task could be attached to a second buffer while
still bound to the first and both buffers' events would be attributed
to it."
  (let ((occupant (agent-tasks-bound-task buffer))
        (other (agent-tasks-task-buffer id)))
    (when (and occupant (not (equal occupant id)))
      (user-error "Session %s is already bound to task %s"
                  (agent-display-name buffer) occupant))
    (when (and other (not (eq other buffer)))
      (user-error "Task %s is already bound to session %s"
                  id (agent-display-name other)))))

(defun agent-tasks--bind (buffer id)
  "Bind session BUFFER to task ID.
Signal unless `agent-tasks--check-bindable' allows the pairing: two
tasks sharing one session, or one task claiming two sessions, would
make every subsequent event ambiguous, and an ambiguous ledger is worse
than a small one."
  (agent-tasks--check-bindable buffer id)
  (puthash buffer id agent-tasks--bindings)
  (with-current-buffer buffer
    (cl-pushnew #'agent-tasks--session-torn-down agent--teardown-functions))
  id)

(defun agent-tasks--check-task-unbound (id)
  "Signal when task ID is already bound to a live session.
Checked for a **new**-session dispatch too, where there is no target
buffer to check against: revision 2 skipped the pairing entirely in
that case, so a task holding a stale binding could be re-dispatched
and `agent-start-session' would deliver the initial prompt before
`agent-tasks--bind' noticed.

A fresh attempt never steals a binding.  Deciding that an earlier run
is over is a judgement for the person — `u' to unbind, `R' to attach."
  (when-let* ((buffer (agent-tasks-task-buffer id)))
    (user-error "Task %s is already bound to session %s; unbind it first"
                id (agent-display-name buffer))))

(defun agent-tasks--release-binding (id)
  "Drop task ID's session binding, if it has one.
Called after a durable close: a session freed by closing a task can
immediately take another, and because this runs only once the write
succeeded, a failed close leaves the binding exactly as it was."
  (when-let* ((buffer (agent-tasks-task-buffer id)))
    (agent-tasks--unbind buffer)))

(defun agent-tasks--unbind (buffer)
  "Remove any task binding held by session BUFFER."
  (remhash buffer agent-tasks--bindings))

(defun agent-tasks--purge-dead-bindings ()
  "Drop bindings whose session buffer is dead."
  (let (dead)
    (maphash (lambda (buffer _) (unless (buffer-live-p buffer)
                                  (push buffer dead)))
             agent-tasks--bindings)
    (dolist (buffer dead) (remhash buffer agent-tasks--bindings))))

;;;###autoload
(defun agent-tasks-unbind (buffer)
  "Detach BUFFER's task binding without changing the task's state."
  (interactive (list (agent--resolve-session-buffer)))
  (let ((id (agent-tasks-bound-task buffer)))
    (unless id
      (user-error "No task is bound to %s" (agent-display-name buffer)))
    (agent-tasks--unbind buffer)
    (agent-tasks--safe-log id "unbound from its session by hand")
    (message "Task %s unbound" id)))

;;;; Native session ids

(defun agent-tasks--record-session-id (buffer)
  "Record BUFFER's native session id on the task bound to it.
Member of `agent-session-id-functions'."
  (when-let* ((id (agent-tasks-bound-task buffer))
              (session (agent-session buffer))
              (session-id (agent-session-id session)))
    (let ((task (agent-tasks-find (agent-tasks-read) id)))
      (when (and task (not (equal (agent-tasks-task-session-id task)
                                  session-id)))
        (condition-case err
            (agent-tasks--update-task
             (agent-tasks-read) id
             (lambda ()
               (agent-tasks--set-property "SESSION_ID" session-id)
               (agent-tasks--log "native session id recorded: %s" session-id)))
          (error
           (display-warning
            'agent-tasks
            (format "could not record the session id for task %s: %s"
                    id (error-message-string err))
            :warning)))))))

;;;; Teardown

(defun agent-tasks--session-torn-down ()
  "Move the task bound to the current session buffer to UNKNOWN.
Registered on `agent--teardown-functions' when a binding is made.  A
session that ended with no outcome recorded leaves the task's fate
unknown; it is never marked done and never re-dispatched.

A buffer with no binding is nothing to report — which is how the
restart path stays quiet: it detaches the binding before the kill, so
this function finds nothing and needs no special case."
  (let ((buffer (current-buffer)))
    (when-let* ((id (agent-tasks-bound-task buffer)))
      (agent-tasks--unbind buffer)
      (when (agent-tasks--safe-transition
             id "UNKNOWN" "session ended without a recorded outcome"
             :only-when agent-tasks--live-states)
        (agent-tasks--attention
         buffer "Task outcome unknown"
         (format "Task %s: its session ended without a recorded outcome."
                 id))))))

;;;; Attention

(defun agent-tasks--attention (buffer title detail)
  "File an attention item about BUFFER's task, or fall back to a message.
Only ever called for a task that became UNKNOWN.  Blocked, error and
completion events already produce their own attention items from
`agent-attention-mode'; a second one would be duplicate noise about
the same fact."
  (if (and buffer (buffer-live-p buffer) (fboundp 'agent-attention-file))
      (agent-attention-file buffer
                            :kind 'info
                            :title title
                            :detail detail
                            :fidelity 'rich)
    (message "%s: %s" title detail)))

;;;; Mode

;;;###autoload
(define-minor-mode agent-tasks-mode
  "Observe AI sessions on behalf of the durable task ledger.
This mode owns every hook the ledger installs.  With it off, the list,
the detail view and the manual state changes all still work; only
dispatch refuses, because a dispatch with nothing watching the session
would produce a RUNNING task that no evidence could ever move."
  :global t
  :group 'agent-tasks
  :lighter " AgentTasks"
  (if agent-tasks-mode
      (progn
        (add-hook 'agent-session-id-functions #'agent-tasks--record-session-id)
        (agent-tasks--install-event-hooks))
    (remove-hook 'agent-session-id-functions #'agent-tasks--record-session-id)
    (agent-tasks--remove-event-hooks)))

(defun agent-tasks--install-event-hooks ()
  "Install the session-event and restart hooks the mode owns.
Filled in by later tasks; separated so the mode's hook ownership is
one pair of functions rather than a growing mode body."
  nil)

(defun agent-tasks--remove-event-hooks ()
  "Remove the hooks `agent-tasks--install-event-hooks' installed."
  nil)

(defun agent-tasks--require-mode ()
  "Signal a `user-error' unless `agent-tasks-mode' is on."
  (unless agent-tasks-mode
    (user-error
     "Enable `agent-tasks-mode' first: without it nothing observes the session, so a dispatched task could never leave RUNNING")))
```

`agent-tasks--require-mode` goes **after** `define-minor-mode`, not
before it: the mode form is what defines the `agent-tasks-mode`
variable, and a reference above it byte-compiles with a free-variable
warning.

Add to the forward declarations:

```elisp
(declare-function agent-attention-file "agent-attention" (buffer &rest keys))
```

Finally, amend Task 4's two closing commands so a closed task releases
its session.  In `agent-tasks-mark-done`, after the
`agent-tasks-transition` call and before the `message`:

```elisp
  (agent-tasks--release-binding id)
```

and the identical line in `agent-tasks-cancel`.  The order matters:
`agent-tasks-transition` signals on a failed write, so the release is
never reached and the binding survives a close that did not happen.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test`
Expected: `0 unexpected`, and the total rises by exactly the number of `ert-deftest` forms this task adds (count them in the diff).

- [ ] **Step 5: Byte-compile and commit**

```bash
make compile
git add agent-tasks.el test/agent-tasks-test.el
git commit -m "feat(tasks): add session bindings, id correlation, and teardown"
```

---

### Task 6: Consuming session events

**Files:**
- Modify: `agent-tasks.el` (new "Session events" section;
  `agent-tasks--install-event-hooks` and
  `agent-tasks--remove-event-hooks` from Task 5)
- Test: `test/agent-tasks-test.el`

**Interfaces:**
- Consumes: Tasks 4 and 5; `agent-session-event-functions` from the
  attention/queue project, whose event plist is
  `(:type EVENT :time FLOAT :source SOURCE :redundant BOOL :payload
  PAYLOAD)`.
- Produces (used by Tasks 7, 9, 14):
  - `agent-tasks--handle-session-event BUFFER EVENT`.
  - `agent-tasks--event-blocked ID PAYLOAD`,
    `agent-tasks--event-error ID BUFFER PAYLOAD`.
  - `agent-tasks--blocked-reason PAYLOAD`,
    `agent-tasks--error-reason PAYLOAD`.

- [ ] **Step 0: Confirm the prerequisite landed**

```bash
grep -n "agent-session-event-functions" agent.el | head -3
```

Expected: a `defcustom`/`defvar` defining the hook, from the
attention/queue project's Task 1.  **If this prints nothing, stop.**
The ledger has no other evidence channel, and `add-hook` on an
undefined symbol would silently create a variable nothing ever runs.

- [ ] **Step 1: Write the failing tests**

Add to `test/agent-tasks-test.el`:

```elisp
;;;; Session events

(defun agent-tasks-test--event (type &optional payload redundant)
  "Return a session-event plist of TYPE with PAYLOAD and REDUNDANT."
  (list :type type :time (float-time) :source 'test
        :redundant redundant :payload payload))

(ert-deftest agent-tasks-test-event/blocked-records-the-reported-reason ()
  "A blocked event blocks the task with the backend's own detail."
  (agent-tasks-test--with-ledger nil
    (agent-tasks-test--with-session buffer
      (let ((id (agent-tasks-create :title "Bound")))
        (agent-tasks--update-task
         (agent-tasks-read) id
         (lambda () (agent-tasks--set-state "RUNNING" "setup")))
        (agent-tasks--bind buffer id)
        (agent-tasks--handle-session-event
         buffer (agent-tasks-test--event
                 'blocked '(:kind permission :tool "Bash")))
        (let ((task (agent-tasks-find (agent-tasks-read) id)))
          (should (equal "BLOCKED" (agent-tasks-task-state task)))
          (should (string-match-p "permission decision"
                                  (agent-tasks-task-blocked-reason task)))
          (should (string-match-p "Bash"
                                  (agent-tasks-task-blocked-reason task))))))))

(ert-deftest agent-tasks-test-event/activity-unblocks ()
  "Evidence that the session resumed returns the task to RUNNING."
  (agent-tasks-test--with-ledger nil
    (agent-tasks-test--with-session buffer
      (let ((id (agent-tasks-create :title "Bound")))
        (agent-tasks--bind buffer id)
        (agent-tasks--update-task
         (agent-tasks-read) id
         (lambda ()
           (agent-tasks--set-property "BLOCKED_REASON" "setup")
           (agent-tasks--set-state "BLOCKED" "setup")))
        (agent-tasks--handle-session-event
         buffer (agent-tasks-test--event 'activity))
        (should (equal "RUNNING"
                       (agent-tasks-task-state
                        (agent-tasks-find (agent-tasks-read) id))))))))

(ert-deftest agent-tasks-test-event/completion-logs-and-changes-nothing ()
  "A finished turn is not a finished task."
  (agent-tasks-test--with-ledger nil
    (agent-tasks-test--with-session buffer
      (let ((id (agent-tasks-create :title "Bound")))
        (agent-tasks--update-task
         (agent-tasks-read) id
         (lambda () (agent-tasks--set-state "RUNNING" "setup")))
        (agent-tasks--bind buffer id)
        (agent-tasks--handle-session-event
         buffer (agent-tasks-test--event 'idle-prompt))
        (let ((task (agent-tasks-find (agent-tasks-read) id)))
          (should (equal "RUNNING" (agent-tasks-task-state task)))
          (should (string-match-p "completed a turn"
                                  (agent-tasks-task-log task))))))))

(ert-deftest agent-tasks-test-event/redundant-completion-writes-nothing ()
  "A duplicated completion leaves no second log line."
  (agent-tasks-test--with-ledger nil
    (agent-tasks-test--with-session buffer
      (let ((id (agent-tasks-create :title "Bound")))
        (agent-tasks--update-task
         (agent-tasks-read) id
         (lambda () (agent-tasks--set-state "RUNNING" "setup")))
        (agent-tasks--bind buffer id)
        (agent-tasks--handle-session-event
         buffer (agent-tasks-test--event 'stop nil t))
        (should-not (string-match-p
                     "completed a turn"
                     (or (agent-tasks-task-log
                          (agent-tasks-find (agent-tasks-read) id))
                         "")))))))

(ert-deftest agent-tasks-test-event/error-goes-unknown ()
  "An abnormal turn end makes the task's outcome unknown."
  (agent-tasks-test--with-ledger nil
    (agent-tasks-test--with-session buffer
      (let ((id (agent-tasks-create :title "Bound")))
        (agent-tasks--update-task
         (agent-tasks-read) id
         (lambda () (agent-tasks--set-state "RUNNING" "setup")))
        (agent-tasks--bind buffer id)
        (agent-tasks--handle-session-event
         buffer (agent-tasks-test--event
                 'error '(:error "rate_limit" :message "slow down")))
        (let ((task (agent-tasks-find (agent-tasks-read) id)))
          (should (equal "UNKNOWN" (agent-tasks-task-state task)))
          (should (string-match-p "rate_limit" (agent-tasks-task-log task))))))))

(ert-deftest agent-tasks-test-event/ignores-an-unbound-buffer ()
  "Events for sessions with no task change nothing."
  (agent-tasks-test--with-ledger nil
    (agent-tasks-test--with-session buffer
      (let ((id (agent-tasks-create :title "Unbound")))
        (agent-tasks--handle-session-event
         buffer (agent-tasks-test--event 'error '(:error "boom")))
        (should (equal "PENDING"
                       (agent-tasks-task-state
                        (agent-tasks-find (agent-tasks-read) id))))))))

(ert-deftest agent-tasks-test-event/matrix-is-exact ()
  "Assert the exact resulting state for all 36 event/state pairs.
Revision 1 asserted only that the result \"is not closed\", which is
vacuous for the four open states and simply false for the two closed
ones — the test could not have passed.  The table below is the whole
contract: evidence moves a task only between RUNNING and BLOCKED and
into UNKNOWN, and never out of a closed state, out of UNKNOWN, or into
DONE."
  (let ((expected
         ;; (STATE . ((EVENT . RESULTING-STATE) ...))
         '(("PENDING"   . ((blocked . "PENDING") (activity . "PENDING")
                           (submit . "PENDING") (error . "PENDING")
                           (stop . "PENDING") (idle-prompt . "PENDING")))
           ("RUNNING"   . ((blocked . "BLOCKED") (activity . "RUNNING")
                           (submit . "RUNNING") (error . "UNKNOWN")
                           (stop . "RUNNING") (idle-prompt . "RUNNING")))
           ("BLOCKED"   . ((blocked . "BLOCKED") (activity . "RUNNING")
                           (submit . "BLOCKED") (error . "UNKNOWN")
                           (stop . "BLOCKED") (idle-prompt . "BLOCKED")))
           ("UNKNOWN"   . ((blocked . "UNKNOWN") (activity . "UNKNOWN")
                           (submit . "UNKNOWN") (error . "UNKNOWN")
                           (stop . "UNKNOWN") (idle-prompt . "UNKNOWN")))
           ("DONE"      . ((blocked . "DONE") (activity . "DONE")
                           (submit . "DONE") (error . "DONE")
                           (stop . "DONE") (idle-prompt . "DONE")))
           ("CANCELLED" . ((blocked . "CANCELLED") (activity . "CANCELLED")
                           (submit . "CANCELLED") (error . "CANCELLED")
                           (stop . "CANCELLED") (idle-prompt . "CANCELLED"))))))
    (pcase-dolist (`(,state . ,events) expected)
      (pcase-dolist (`(,type . ,result) events)
        (agent-tasks-test--with-ledger nil
          (agent-tasks-test--with-session buffer
            (let ((id (agent-tasks-create :title "Subject")))
              (unless (equal state "PENDING")
                (agent-tasks--update-task
                 (agent-tasks-read) id
                 (lambda ()
                   (pcase state
                     ("BLOCKED"
                      (agent-tasks--set-property "BLOCKED_REASON" "setup"))
                     ("DONE"
                      (agent-tasks--set-property "OUTCOME" "succeeded")))
                   (agent-tasks--set-state state "setup"))))
              (agent-tasks--bind buffer id)
              (agent-tasks--handle-session-event
               buffer (agent-tasks-test--event type '(:kind permission)))
              (should (equal result
                             (agent-tasks-task-state
                              (agent-tasks-find (agent-tasks-read) id)))))))))))

(ert-deftest agent-tasks-test-event/submit-is-not-evidence ()
  "A submission that started no turn must not clear a blocked reason."
  (agent-tasks-test--with-ledger nil
    (agent-tasks-test--with-session buffer
      (let ((id (agent-tasks-create :title "Bound")))
        (agent-tasks--bind buffer id)
        (agent-tasks--update-task
         (agent-tasks-read) id
         (lambda ()
           (agent-tasks--set-property "BLOCKED_REASON" "needs a decision")
           (agent-tasks--set-state "BLOCKED" "setup")))
        (agent-tasks--handle-session-event
         buffer (agent-tasks-test--event 'submit))
        (let ((task (agent-tasks-find (agent-tasks-read) id)))
          (should (equal "BLOCKED" (agent-tasks-task-state task)))
          (should (equal "needs a decision"
                         (agent-tasks-task-blocked-reason task))))))))

(ert-deftest agent-tasks-test-event/error-files-no-attention-item ()
  "The attention module owns session errors; the ledger must not duplicate."
  (agent-tasks-test--with-ledger nil
    (agent-tasks-test--with-session buffer
      (let ((id (agent-tasks-create :title "Bound"))
            (filed nil))
        (agent-tasks--update-task
         (agent-tasks-read) id
         (lambda () (agent-tasks--set-state "RUNNING" "setup")))
        (agent-tasks--bind buffer id)
        (cl-letf (((symbol-function 'agent-tasks--attention)
                   (lambda (&rest _) (push t filed))))
          (agent-tasks--handle-session-event
           buffer (agent-tasks-test--event 'error '(:error "boom"))))
        (should (null filed))
        (should (equal "UNKNOWN"
                       (agent-tasks-task-state
                        (agent-tasks-find (agent-tasks-read) id))))))))

(ert-deftest agent-tasks-test-event/a-write-failure-warns-and-does-not-signal ()
  "A consumer that signalled would break the other consumers on the hook."
  (agent-tasks-test--with-ledger nil
    (agent-tasks-test--with-session buffer
      (let ((id (agent-tasks-create :title "Bound"))
            (warnings nil))
        (agent-tasks--update-task
         (agent-tasks-read) id
         (lambda () (agent-tasks--set-state "RUNNING" "setup")))
        (agent-tasks--bind buffer id)
        (cl-letf (((symbol-function 'agent-tasks--update-task)
                   (lambda (&rest _) (error "no disk")))
                  ((symbol-function 'display-warning)
                   (lambda (_type message &rest _) (push message warnings))))
          (agent-tasks--handle-session-event
           buffer (agent-tasks-test--event 'error '(:error "boom")))
          (agent-tasks--handle-session-event
           buffer (agent-tasks-test--event 'blocked '(:kind question))))
        (should (= 2 (length warnings)))))))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test`
Expected: every test added in Step 1 fails, with `Symbol's function definition is void:
agent-tasks--handle-session-event`.

- [ ] **Step 3: Implement the event consumer**

Add to `agent-tasks.el`:

```elisp
;;;; Session events

(defun agent-tasks--handle-session-event (buffer event)
  "Apply session EVENT for BUFFER to the task bound to it.
Member of `agent-session-event-functions'.  EVENT is that hook's
plist: `:type', `:time', `:source', `:redundant', `:payload'.

This consumer sends no session input, as that hook's contract
requires, so nothing it does can nest a `submit' event inside an outer
delivery.  It never signals: every write goes through a warning
wrapper, because a signalling consumer would break the others on the
hook."
  (when-let* ((id (agent-tasks-bound-task buffer)))
    (pcase (plist-get event :type)
      ('blocked
       (agent-tasks--event-blocked id (plist-get event :payload)))
      ('activity
       ;; Only `activity' unblocks.  `submit' is emitted by
       ;; `agent--dispatch-send' *before* the backend is called
       ;; (agent.el:1492), and core documents that a submission may
       ;; duplicate and may start no turn — so treating it as evidence,
       ;; as revision 1 did, let a submission that failed or that the
       ;; CLI ignored clear a real BLOCKED_REASON and report the session
       ;; as working again.
       (agent-tasks--safe-transition
        id "RUNNING" "bound session resumed work"
        :only-when '("BLOCKED")))
      ('submit nil)
      ('error
       (agent-tasks--event-error id buffer (plist-get event :payload)))
      ((or 'stop 'idle-prompt)
       ;; A finished turn is not a finished task.  Record it and change
       ;; nothing: only a person closes a task.
       (unless (plist-get event :redundant)
         (agent-tasks--safe-log
          id "bound session completed a turn; task state unchanged"))))))

(defun agent-tasks--event-blocked (id payload)
  "Record that the session bound to task ID reported a block.
PAYLOAD is what the backend reported; nothing in the reason is
synthesized."
  (let ((reason (agent-tasks--blocked-reason payload)))
    (condition-case err
        (let* ((ledger (agent-tasks-read))
               (task (agent-tasks-find ledger id)))
          (when (and task
                     (member (agent-tasks-task-state task)
                             agent-tasks--live-states))
            (agent-tasks-transition
             ledger id "BLOCKED" (format "blocked: %s" reason)
             :extra (lambda ()
                      (agent-tasks--set-property "BLOCKED_REASON" reason)))))
      (error
       (display-warning
        'agent-tasks
        (format "could not block task %s: %s" id (error-message-string err))
        :warning)))))

(defun agent-tasks--blocked-reason (payload)
  "Return a reason string built only from `blocked' event PAYLOAD.
When the backend said nothing beyond \"blocked\", the reason says
exactly that rather than inventing a cause."
  (agent-tasks--one-line
   (string-join
    (delq nil
          (list (pcase (plist-get payload :kind)
                  ('permission "waiting for a permission decision")
                  ('question "the session asked a question")
                  (_ "the session reported it is blocked"))
                (when-let* ((tool (plist-get payload :tool)))
                  (format "tool: %s" tool))
                (when-let* ((message (plist-get payload :message)))
                  (unless (string-empty-p message)
                    (format "message: %s" message)))))
    "; ")))

(defun agent-tasks--event-error (id buffer payload)
  "Record that the session bound to task ID ended abnormally.
Files no attention item: `agent-attention-mode' already files one for
this same session error, and two items about one failure is noise.  The
ledger owns exactly one attention case — a task moved to UNKNOWN by its
session's teardown, which no session event covers."
  (ignore buffer)
  (let ((reason (agent-tasks--error-reason payload)))
    (agent-tasks--safe-transition
     id "UNKNOWN" (format "session error: %s" reason)
     :only-when agent-tasks--live-states)))

(defun agent-tasks--error-reason (payload)
  "Return a reason string built only from `error' event PAYLOAD."
  (let ((text (string-join
               (delq nil
                     (list (when-let* ((code (plist-get payload :error)))
                             (format "%s" code))
                           (plist-get payload :message)))
               ": ")))
    (if (string-empty-p text)
        "the backend reported no detail"
      (agent-tasks--one-line text))))
```

Replace the two stubs from Task 5 with:

```elisp
(defun agent-tasks--install-event-hooks ()
  "Install the session-event hooks the mode owns."
  (add-hook 'agent-session-event-functions
            #'agent-tasks--handle-session-event))

(defun agent-tasks--remove-event-hooks ()
  "Remove the hooks `agent-tasks--install-event-hooks' installed."
  (remove-hook 'agent-session-event-functions
               #'agent-tasks--handle-session-event))
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test`
Expected: `0 unexpected`, and the total rises by exactly the number of `ert-deftest` forms this task adds (count them in the diff).
The exhaustive invariant test contributes one test that runs 36
scenarios.

- [ ] **Step 5: Byte-compile and commit**

```bash
make compile
git add agent-tasks.el test/agent-tasks-test.el
git commit -m "feat(tasks): consume session events as ledger evidence"
```

---

### Task 7: Reconciliation after a crash

**Files:**
- Modify: `agent-tasks.el` (new "Reconciliation" section)
- Test: `test/agent-tasks-test.el`

**Interfaces:**
- Consumes: Tasks 4–6; `agent-session-buffers`, `agent-session`,
  `agent-session-id`, `agent-display-name`.
- Produces (used by Tasks 8, 10):
  - `agent-tasks-reconcile (&optional LEDGER)` → a ledger; also an
    interactive command.
  - `agent-tasks--ensure-reconciled LEDGER` → a ledger; reconciles once
    per Emacs session.
  - `agent-tasks--matching-session TASK` → buffer or nil.
  - `agent-tasks--identity-matches-p TASK BUFFER`.
  - `agent-tasks--reconciled` — the once-per-Emacs flag.

- [ ] **Step 1: Write the failing tests**

Add to `test/agent-tasks-test.el`:

```elisp
;;;; Reconciliation

(ert-deftest agent-tasks-test-reconcile/orphaned-running-becomes-unknown ()
  "A RUNNING task with no live session is unknown, not done, not retried."
  (agent-tasks-test--with-ledger nil
    (let ((agent-tasks--reconciled nil)
          (agent-tasks--bindings (make-hash-table :test 'eq))
          (agent-backends nil)
          (id nil))
      (setq id (agent-tasks-create :title "Orphan"))
      (agent-tasks--update-task
       (agent-tasks-read) id
       (lambda () (agent-tasks--set-state "RUNNING" "setup")))
      (agent-tasks-reconcile)
      (let ((task (agent-tasks-find (agent-tasks-read) id)))
        (should (equal "UNKNOWN" (agent-tasks-task-state task)))
        (should (string-match-p "no live session found at reconciliation"
                                (agent-tasks-task-log task)))))))

(ert-deftest agent-tasks-test-reconcile/rebinds-on-a-matching-session-id ()
  "A live session that proves the recorded identity keeps the task RUNNING."
  (agent-tasks-test--with-ledger nil
    (agent-tasks-test--with-session buffer
      (let ((agent-tasks--reconciled nil)
            (agent-tasks--bindings (make-hash-table :test 'eq))
            (id (agent-tasks-create :title "Resumable")))
        (setf (agent-session-id (agent-session buffer)) "sid-7")
        (agent-tasks--update-task
         (agent-tasks-read) id
         (lambda ()
           (agent-tasks--set-property "BACKEND" "stub")
           (agent-tasks--set-property "ACCOUNT" "acct")
           (agent-tasks--set-property "DIRECTORY" "~/scratch/proj/")
           (agent-tasks--set-property "INSTANCE" "default")
           (agent-tasks--set-property "SESSION_ID" "sid-7")
           (agent-tasks--set-state "RUNNING" "setup")))
        (agent-tasks-reconcile)
        (should (equal "RUNNING"
                       (agent-tasks-task-state
                        (agent-tasks-find (agent-tasks-read) id))))
        (should (eq buffer (agent-tasks-task-buffer id)))))))

(ert-deftest agent-tasks-test-reconcile/refuses-a-directory-only-match ()
  "Without a proven session id, a same-project session is not the same run."
  (agent-tasks-test--with-ledger nil
    (agent-tasks-test--with-session buffer
      (let ((agent-tasks--reconciled nil)
            (agent-tasks--bindings (make-hash-table :test 'eq))
            (id (agent-tasks-create :title "Ambiguous")))
        (setf (agent-session-id (agent-session buffer)) "sid-new")
        (agent-tasks--update-task
         (agent-tasks-read) id
         (lambda ()
           (agent-tasks--set-property "BACKEND" "stub")
           (agent-tasks--set-property "ACCOUNT" "acct")
           (agent-tasks--set-property "DIRECTORY" "~/scratch/proj/")
           (agent-tasks--set-property "INSTANCE" "default")
           (agent-tasks--set-state "RUNNING" "setup")))
        (agent-tasks-reconcile)
        (should (equal "UNKNOWN"
                       (agent-tasks-task-state
                        (agent-tasks-find (agent-tasks-read) id))))
        (should-not (agent-tasks-task-buffer id))))))

(ert-deftest agent-tasks-test-reconcile/refuses-a-different-session-id ()
  "Two ids that disagree are two different runs."
  (agent-tasks-test--with-ledger nil
    (agent-tasks-test--with-session buffer
      (let ((agent-tasks--reconciled nil)
            (agent-tasks--bindings (make-hash-table :test 'eq))
            (id (agent-tasks-create :title "Replaced")))
        (setf (agent-session-id (agent-session buffer)) "sid-new")
        (agent-tasks--update-task
         (agent-tasks-read) id
         (lambda ()
           (agent-tasks--set-property "BACKEND" "stub")
           (agent-tasks--set-property "ACCOUNT" "acct")
           (agent-tasks--set-property "DIRECTORY" "~/scratch/proj/")
           (agent-tasks--set-property "INSTANCE" "default")
           (agent-tasks--set-property "SESSION_ID" "sid-old")
           (agent-tasks--set-state "RUNNING" "setup")))
        (agent-tasks-reconcile)
        (should (equal "UNKNOWN"
                       (agent-tasks-task-state
                        (agent-tasks-find (agent-tasks-read) id))))))))

(ert-deftest agent-tasks-test-reconcile/handles-several-tasks-in-one-pass ()
  "Each write re-reads, so the second task does not hit a stale hash."
  (agent-tasks-test--with-ledger nil
    (let ((agent-tasks--reconciled nil)
          (agent-tasks--bindings (make-hash-table :test 'eq))
          (agent-backends nil)
          (ids nil))
      (dotimes (index 3)
        (let ((id (agent-tasks-create :title (format "Orphan %d" index))))
          (push id ids)
          (agent-tasks--update-task
           (agent-tasks-read) id
           (lambda () (agent-tasks--set-state "RUNNING" "setup")))))
      (agent-tasks-reconcile)
      (dolist (id ids)
        (should (equal "UNKNOWN"
                       (agent-tasks-task-state
                        (agent-tasks-find (agent-tasks-read) id))))))))

(ert-deftest agent-tasks-test-reconcile/goes-through-the-transition-api ()
  "Reconciliation is not an exception to the sole-transition contract.
An orphaned BLOCKED task must lose its BLOCKED_REASON, which only the
transition API's destination invariants enforce."
  (agent-tasks-test--with-ledger nil
    (let ((agent-tasks--reconciled nil)
          (agent-tasks--bindings (make-hash-table :test 'eq))
          (agent-backends nil)
          (calls nil)
          (id nil))
      (setq id (agent-tasks-create :title "Orphan"))
      (agent-tasks--update-task
       (agent-tasks-read) id
       (lambda ()
         (agent-tasks--set-property "BLOCKED_REASON" "waiting on a decision")
         (agent-tasks--set-state "BLOCKED" "setup")))
      (let ((real (symbol-function 'agent-tasks-transition)))
        (cl-letf (((symbol-function 'agent-tasks-transition)
                   (lambda (&rest args) (push (nth 2 args) calls)
                     (apply real args))))
          (agent-tasks-reconcile)))
      (should (equal '("UNKNOWN") calls))
      (let ((task (agent-tasks-find (agent-tasks-read) id)))
        (should (equal "UNKNOWN" (agent-tasks-task-state task)))
        (should (null (agent-tasks-task-blocked-reason task)))))))

(ert-deftest agent-tasks-test-reconcile/is-idempotent ()
  "A second pass over the same ledger writes nothing."
  (agent-tasks-test--with-ledger nil
    (let ((agent-tasks--reconciled nil)
          (agent-tasks--bindings (make-hash-table :test 'eq))
          (agent-backends nil)
          (id nil))
      (setq id (agent-tasks-create :title "Orphan"))
      (agent-tasks--update-task
       (agent-tasks-read) id
       (lambda () (agent-tasks--set-state "RUNNING" "setup")))
      (agent-tasks-reconcile)
      (let ((text (agent-tasks--file-text agent-tasks-file)))
        (agent-tasks-reconcile)
        (should (equal text (agent-tasks--file-text agent-tasks-file)))))))

(ert-deftest agent-tasks-test-reconcile/never-produces-running-from-unknown ()
  "Reconciliation is not a retry path."
  (agent-tasks-test--with-ledger nil
    (agent-tasks-test--with-session buffer
      (let ((agent-tasks--reconciled nil)
            (agent-tasks--bindings (make-hash-table :test 'eq))
            (id (agent-tasks-create :title "Unknown")))
        (setf (agent-session-id (agent-session buffer)) "sid-7")
        (agent-tasks--update-task
         (agent-tasks-read) id
         (lambda ()
           (agent-tasks--set-property "BACKEND" "stub")
           (agent-tasks--set-property "ACCOUNT" "acct")
           (agent-tasks--set-property "DIRECTORY" "~/scratch/proj/")
           (agent-tasks--set-property "INSTANCE" "default")
           (agent-tasks--set-property "SESSION_ID" "sid-7")
           (agent-tasks--set-state "UNKNOWN" "setup")))
        (agent-tasks-reconcile)
        (should (equal "UNKNOWN"
                       (agent-tasks-task-state
                        (agent-tasks-find (agent-tasks-read) id))))))))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test`
Expected: every test added in Step 1 fails, with `Symbol's value as variable is void:
agent-tasks--reconciled`.

- [ ] **Step 3: Implement reconciliation**

Add to `agent-tasks.el`:

```elisp
;;;; Reconciliation

(defvar agent-tasks--reconciled nil
  "Non-nil once reconciliation has run in this Emacs session.")

;;;###autoload
(defun agent-tasks-reconcile (&optional ledger)
  "Reconcile LEDGER's live-state tasks against the live sessions.
Return the resulting ledger.  A task recorded RUNNING or BLOCKED with
no in-memory binding is re-bound only when a live session proves its
identity; everything else becomes UNKNOWN with a recorded reason.
Nothing is ever re-dispatched, and no task ever leaves UNKNOWN here.

This is what covers the case teardown cannot: Emacs died, so no
teardown ran, and the only evidence left is what the file says and
which sessions exist now."
  (interactive)
  (agent-tasks--purge-dead-bindings)
  (let ((ledger (or ledger (agent-tasks-read)))
        (rebound 0)
        (unknown 0))
    ;; The list is taken once, from the snapshot passed in; each write
    ;; below returns a freshly parsed ledger, which the loop threads, so
    ;; the second write does not fail against the first one's hash.
    (dolist (task (agent-tasks-ledger-tasks ledger))
      (let ((id (agent-tasks-task-id task)))
        (when (and (member (agent-tasks-task-state task)
                           agent-tasks--live-states)
                   (not (agent-tasks-task-buffer id)))
          (if-let* ((buffer (agent-tasks--matching-session task)))
              (let ((label (agent-display-name buffer)))
                (agent-tasks--bind buffer id)
                (setq ledger
                      (agent-tasks--update-task
                       ledger id
                       (lambda ()
                         (agent-tasks--log
                          "re-bound to live session %s at reconciliation"
                          label))))
                (cl-incf rebound))
            ;; Through the transition API, not the raw state setter:
            ;; that is the only place the matrix and the destination
            ;; invariants are enforced, so an orphaned BLOCKED task also
            ;; loses its now-meaningless BLOCKED_REASON here.
            (setq ledger
                  (agent-tasks-transition
                   ledger id "UNKNOWN"
                   "no live session found at reconciliation"))
            (cl-incf unknown)))))
    (setq agent-tasks--reconciled t)
    (when (> (+ rebound unknown) 0)
      (message "Agent tasks: reconciled %d task%s: %d re-bound, %d unknown"
               (+ rebound unknown)
               (if (= 1 (+ rebound unknown)) "" "s")
               rebound unknown))
    ledger))

(defun agent-tasks--ensure-reconciled (ledger)
  "Reconcile LEDGER once per Emacs session and return the result."
  (if agent-tasks--reconciled
      ledger
    (agent-tasks-reconcile ledger)))

(defun agent-tasks--matching-session (task)
  "Return the live session buffer that proves TASK's recorded identity.
Return nil when none does.  A match requires the recorded native
session id: matching on backend, account, directory and instance alone
would happily re-bind the task to a *different* session that happens
to run in the same project, and then attribute that session's events
to it."
  (when (agent-tasks-task-session-id task)
    (cl-find-if
     (lambda (buffer)
       (and (buffer-live-p buffer)
            (not (agent-tasks-bound-task buffer))
            (agent-tasks--identity-matches-p task buffer)))
     (agent-session-buffers))))

(defun agent-tasks--identity-matches-p (task buffer)
  "Return non-nil when BUFFER's session is the one TASK recorded."
  (when-let* ((session (agent-session buffer)))
    (and (equal (agent-tasks-task-session-id task)
                (agent-session-id session))
         (equal (agent-tasks-task-backend task)
                (when-let* ((backend (agent-session-backend session)))
                  (symbol-name backend)))
         (equal (agent-tasks-task-account task)
                (agent-session-account session))
         (equal (agent-tasks-task-directory task)
                (when-let* ((directory (agent-session-directory session)))
                  (agent-session--normalize-directory directory)))
         (equal (agent-tasks-task-instance task)
                (agent-session-instance session)))))
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test`
Expected: `0 unexpected`, and the total rises by exactly the number of `ert-deftest` forms this task adds (count them in the diff).

- [ ] **Step 5: Byte-compile and commit**

```bash
make compile
git add agent-tasks.el test/agent-tasks-test.el
git commit -m "feat(tasks): reconcile orphaned running tasks after a crash"
```

---

### Task 8: The message and the dispatcher

**Files:**
- Modify: `agent-tasks.el` (new "Dispatch" section; two new defcustoms
  next to `agent-tasks-file`)
- Test: `test/agent-tasks-test.el`

**Interfaces:**
- Consumes: Tasks 3–7; `agent-submit`, `agent-start-session`,
  `agent-session-create`, `agent--read-session-buffer`,
  `agent--resolve-backend`, `agent-display-name`,
  `agent-session-display-state`, and — through `fboundp` —
  `agent-session-ready-to-submit-p` and
  `agent-backend-ready-to-submit-p`.
- Produces (used by Tasks 9, 10, 12):
  - `agent-tasks-dispatch-confirm`, `agent-tasks-dispatch-footer`.
  - `agent-tasks-message TASK ATTEMPT` → the exact outgoing string.
  - `agent-tasks-session-readiness BUFFER` → `ready`/`busy`/`unknown`.
  - `agent-tasks-dispatch (&optional ID OVERRIDE-DEPENDENCIES)` —
    autoloaded command.
  - `agent-tasks--prepare-dispatch LEDGER ID OVERRIDE` → the prepared
    plist `(:ledger :id :attempt :message :instruction :state :override
    :buffer :session :readiness)`.
  - `agent-tasks--assert-snapshot PREPARED` → a fresh ledger, or a
    `user-error` naming what changed since the preview.
  - `agent-tasks--perform-dispatch PREPARED` → the session buffer.
  - `agent-tasks--confirm-identity BUFFER ID` — the post-start identity
    repair.
  - `agent-tasks--check-pending-input BUFFER` — refuse unless the
    composer's `:pending-input-p` reports nil.
  - `agent-tasks--submit MESSAGE BUFFER` — send through the composer's
    `:submit-literal` slot.
  - `agent-tasks--check-dependencies` (returns the overridden list),
    `agent-tasks--describe-dependencies`, `agent-tasks--read-target`,
    `agent-tasks--new-session-identity`,
    `agent-tasks--confirm-readiness`, `agent-tasks--confirm-message`,
    `agent-tasks--record-target-properties`.

- [ ] **Step 1: Write the failing tests**

Add to `test/agent-tasks-test.el`:

```elisp
;;;; Dispatch

(defmacro agent-tasks-test--dispatchable (&rest body)
  "Run BODY with the mode on, a stub session, and a PENDING task.
Binds `buffer' to the session, `id' to the task, and `submitted' to a
list that records every `agent-submit' call."
  (declare (indent 0) (debug (body)))
  `(agent-tasks-test--with-ledger nil
     (agent-tasks-test--with-session buffer
       (let* ((agent-tasks--bindings (make-hash-table :test 'eq))
              (agent-tasks--reconciled t)
              (agent-tasks-dispatch-confirm nil)
              (agent-tasks-mode t)
              (submitted nil)
              (id (agent-tasks-create :title "Ship it"
                                      :instruction "Do the work")))
         (cl-letf (((symbol-function 'agent-tasks--submit)
                    (lambda (text target) (push (cons text target) submitted)))
                   ((symbol-function 'agent-tasks--check-pending-input)
                    (lambda (_buffer) t))
                   ((symbol-function 'agent-submit)
                    (lambda (&rest _)
                      (error "agent-submit must not be used; use :submit-literal")))
                   ((symbol-function 'agent--read-session-buffer)
                    (lambda () buffer))
                   ((symbol-function 'agent-tasks--read-target)
                    (lambda (_task) (list :buffer buffer))))
           ,@body)))))

(ert-deftest agent-tasks-test-message/renders-deterministically ()
  "The outgoing message is a pure function of the task and the attempt."
  (agent-tasks-test--with-ledger nil
    (let* ((id (agent-tasks-create :title "T" :instruction "Line one\nLine two"))
           (task (agent-tasks-find (agent-tasks-read) id)))
      (should (equal (agent-tasks-message task 2)
                     (concat
                      (format "[Agent task %s — attempt 2]\n\n" id)
                      "Line one\nLine two\n\n---\n"
                      agent-tasks-dispatch-footer "\n"))))))

(ert-deftest agent-tasks-test-message/omits-result-and-evidence ()
  "The person's record of an outcome is not input to a run."
  (agent-tasks-test--with-ledger nil
    (let ((id (agent-tasks-create :title "T" :instruction "Do it")))
      (agent-tasks--update-task
       (agent-tasks-read) id
       (lambda ()
         (agent-tasks--append-to-section "Result" "SECRET-RESULT")
         (agent-tasks--append-to-section "Evidence" "SECRET-EVIDENCE")))
      (let ((message (agent-tasks-message
                      (agent-tasks-find (agent-tasks-read) id) 1)))
        (should-not (string-match-p "SECRET-RESULT" message))
        (should-not (string-match-p "SECRET-EVIDENCE" message))))))

(ert-deftest agent-tasks-test-dispatch/marks-running-and-submits-once ()
  "A dispatch writes the ledger, sends once, and binds the session."
  (agent-tasks-test--dispatchable
    (cl-letf (((symbol-function 'agent-tasks-session-readiness)
               (lambda (_buffer) 'ready)))
      (agent-tasks-dispatch id)
      (let ((task (agent-tasks-find (agent-tasks-read) id)))
        (should (equal "RUNNING" (agent-tasks-task-state task)))
        (should (= 1 (agent-tasks-task-attempt task)))
        (should (= 1 (length submitted)))
        (should (string-match-p "Do the work" (car (car submitted))))
        (should (equal id (agent-tasks-bound-task buffer)))))))

(ert-deftest agent-tasks-test-dispatch/refuses-a-busy-session-by-name ()
  "A session that cannot take a turn is refused, not queued."
  (agent-tasks-test--dispatchable
    (cl-letf (((symbol-function 'agent-tasks-session-readiness)
               (lambda (_buffer) 'busy)))
      (let ((error-message
             (cadr (should-error (agent-tasks-dispatch id) :type 'user-error))))
        (should (string-match-p (regexp-quote (agent-display-name buffer))
                                error-message)))
      (should (equal "PENDING" (agent-tasks-task-state
                                (agent-tasks-find (agent-tasks-read) id))))
      (should (null submitted)))))

(ert-deftest agent-tasks-test-dispatch/unknown-state-needs-confirmation ()
  "An unknown state is confirmed, never assumed idle."
  (agent-tasks-test--dispatchable
    (cl-letf (((symbol-function 'agent-tasks-session-readiness)
               (lambda (_buffer) 'unknown))
              ((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
      (should-error (agent-tasks-dispatch id) :type 'user-error)
      (should (null submitted)))
    (cl-letf (((symbol-function 'agent-tasks-session-readiness)
               (lambda (_buffer) 'unknown))
              ((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
      (agent-tasks-dispatch id)
      (should (= 1 (length submitted))))))

(ert-deftest agent-tasks-test-dispatch/refuses-a-session-that-changed ()
  "A target that became unknown after the confirmation is refused."
  (agent-tasks-test--dispatchable
    (let ((answers '(ready busy)))
      (cl-letf (((symbol-function 'agent-tasks-session-readiness)
                 (lambda (_buffer) (pop answers))))
        (should-error (agent-tasks-dispatch id) :type 'user-error)
        (should (null submitted))
        (should (equal "PENDING"
                       (agent-tasks-task-state
                        (agent-tasks-find (agent-tasks-read) id))))))))

(ert-deftest agent-tasks-test-dispatch/an-unwritable-ledger-sends-nothing ()
  "A ledger that cannot record the run must not start it."
  (agent-tasks-test--dispatchable
    (cl-letf (((symbol-function 'agent-tasks-session-readiness)
               (lambda (_buffer) 'ready))
              ((symbol-function 'agent-tasks--update-task)
               (lambda (&rest _) (user-error "read-only ledger"))))
      (should-error (agent-tasks-dispatch id) :type 'user-error)
      (should (null submitted)))))

(ert-deftest agent-tasks-test-dispatch/a-failed-send-goes-unknown ()
  "A submission that signalled leaves delivery unproven, not pending."
  (agent-tasks-test--dispatchable
    (cl-letf (((symbol-function 'agent-tasks-session-readiness)
               (lambda (_buffer) 'ready))
              ((symbol-function 'agent-tasks--submit)
               (lambda (&rest _) (error "terminal is gone"))))
      (should-error (agent-tasks-dispatch id))
      (let ((task (agent-tasks-find (agent-tasks-read) id)))
        (should (equal "UNKNOWN" (agent-tasks-task-state task)))
        (should (string-match-p "delivery unproven"
                                (agent-tasks-task-log task)))))))

(ert-deftest agent-tasks-test-dispatch/refuses-a-snapshot-that-moved ()
  "A task that changed between preview and commit is not sent to.
Each case runs the interactive half, mutates the ledger behind it, and
then commits — which is exactly the window revision 1 left open."
  (dolist (mutate
           (list
            (cons "cancelled"
                  (lambda (id) (agent-tasks-cancel id "changed my mind")))
            (cons "closed"
                  (lambda (id) (agent-tasks-mark-done id "failed" nil nil)))
            (cons "instruction edited"
                  (lambda (id)
                    (agent-tasks--update-task
                     (agent-tasks-read) id
                     (lambda ()
                       ;; Rewrite the body in place, which is what a
                       ;; person editing the ledger file does.
                       (org-back-to-heading t)
                       (forward-line 1)
                       (when (looking-at-p "[ \t]*:PROPERTIES:[ \t]*$")
                         (re-search-forward "^[ \t]*:END:[ \t]*$")
                         (forward-line 1))
                       (let ((start (point))
                             (stop (progn (re-search-forward "^\\*\\* ")
                                          (match-beginning 0))))
                         (delete-region start stop)
                         (goto-char start)
                         (insert "\nDo something else entirely\n\n"))))))
            (cons "new dependency"
                  (lambda (id)
                    (let ((blocker (agent-tasks-create :title "Blocker")))
                      (agent-tasks--update-task
                       (agent-tasks-read) id
                       (lambda ()
                         (agent-tasks--set-property "DEPENDS" blocker))))))
            ;; The case a field-by-field check cannot catch: every
            ;; compared value is restored, yet the task has been through
            ;; two decisions the dispatcher never saw.
            (cons "cancelled then reopened"
                  (lambda (id)
                    (agent-tasks-cancel id "changed my mind")
                    (cl-letf (((symbol-function 'yes-or-no-p)
                               (lambda (&rest _) t)))
                      (agent-tasks-reopen id))))
            ;; Target identity: revision 2 compared none of it and the
            ;; commit would have overwritten the edit.
            (cons "recorded directory edited"
                  (lambda (id)
                    (agent-tasks--update-task
                     (agent-tasks-read) id
                     (lambda ()
                       (agent-tasks--set-property
                        "DIRECTORY" "~/somewhere/else/")))))))
    (agent-tasks-test--dispatchable
      (cl-letf (((symbol-function 'agent-tasks-session-readiness)
                 (lambda (_buffer) 'ready)))
        (let ((prepared (agent-tasks--prepare-dispatch
                         (agent-tasks-read) id nil)))
          (funcall (cdr mutate) id)
          (should-error (agent-tasks--perform-dispatch prepared)
                        :type 'user-error)
          (should (null submitted)))))))

(ert-deftest agent-tasks-test-dispatch/reopened-dependency-sends-nothing ()
  "A dependency reopened after the preview refuses the dispatch.
The entry token covers this task's bytes only; the dependency verdict
lives in another task's entry, so nothing about this task changes when
its dependency is reopened — which is why the verdict is recomputed at
commit as well."
  (agent-tasks-test--dispatchable
    (let ((blocker (agent-tasks-create :title "Blocker")))
      (agent-tasks-mark-done blocker "succeeded" nil nil)
      (agent-tasks--update-task
       (agent-tasks-read) id
       (lambda () (agent-tasks--set-property "DEPENDS" blocker)))
      (cl-letf (((symbol-function 'agent-tasks-session-readiness)
                 (lambda (_buffer) 'ready)))
        ;; Prepared while the dependency was satisfied, so no override.
        (let ((prepared (agent-tasks--prepare-dispatch
                         (agent-tasks-read) id nil)))
          (should (null (plist-get prepared :override)))
          (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
            (agent-tasks-reopen blocker))
          (let ((before (agent-tasks--file-text agent-tasks-file)))
            (should-error (agent-tasks--perform-dispatch prepared)
                          :type 'user-error)
            (should (null submitted))
            (should (equal before
                           (agent-tasks--file-text agent-tasks-file)))))))))

(ert-deftest agent-tasks-test-dispatch/records-a-dependency-override ()
  "An override that was asked for is an override that is recorded."
  (agent-tasks-test--dispatchable
    (let ((blocker (agent-tasks-create :title "Blocker")))
      (agent-tasks--update-task
       (agent-tasks-read) id
       (lambda () (agent-tasks--set-property "DEPENDS" blocker)))
      (cl-letf (((symbol-function 'agent-tasks-session-readiness)
                 (lambda (_buffer) 'ready))
                ((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (agent-tasks-dispatch id t)
        (let ((log (agent-tasks-task-log (agent-tasks-find (agent-tasks-read) id))))
          (should (string-match-p "dependency gate overridden" log))
          (should (string-match-p blocker log)))))))

(ert-deftest agent-tasks-test-dispatch/occupied-target-sends-nothing ()
  "A session already holding another task is refused before the send."
  (agent-tasks-test--dispatchable
    (let ((squatter (agent-tasks-create :title "Squatter")))
      (agent-tasks--bind buffer squatter)
      (cl-letf (((symbol-function 'agent-tasks-session-readiness)
                 (lambda (_buffer) 'ready)))
        (let ((error-message
               (cadr (should-error (agent-tasks-dispatch id)
                                   :type 'user-error))))
          (should (string-match-p squatter error-message)))
        (should (null submitted))
        (should (equal "PENDING"
                       (agent-tasks-task-state
                        (agent-tasks-find (agent-tasks-read) id))))))))

(ert-deftest agent-tasks-test-dispatch/sends-through-submit-literal ()
  "The task message is one isolated turn, not an append to the prompt."
  (agent-tasks-test--with-ledger nil
    (agent-tasks-test--with-session buffer
      (let* ((agent-tasks--reconciled t)
             (agent-tasks-dispatch-confirm nil)
             (agent-tasks-mode t)
             (agent-backends nil)
             (literal nil)
             (id (agent-tasks-create :title "Isolated" :instruction "Do it")))
        (apply #'agent-register-backend 'stub
               (agent-tasks-test--backend
                :buffer-p (lambda (candidate) (eq candidate buffer))
                :find-all-buffers (lambda () (list buffer))
                :pending-input-p (lambda (_b) nil)
                :submit-literal (lambda (text target)
                                  (push (cons text target) literal))))
        (setq-local agent--backend 'stub)
        (cl-letf (((symbol-function 'agent-tasks-session-readiness)
                   (lambda (_buffer) 'ready))
                  ((symbol-function 'agent-tasks--read-target)
                   (lambda (_task) (list :buffer buffer)))
                  ((symbol-function 'agent-submit)
                   (lambda (&rest _) (error "agent-submit must not be used"))))
          (agent-tasks-dispatch id)
          (should (= 1 (length literal)))
          (should (string-match-p "Do it" (car (car literal)))))))))

(ert-deftest agent-tasks-test-dispatch/confirms-identity-after-start ()
  "A new session's real account and instance reach the record.
`agent-start-session' resolves a nil account and a backend may pick a
different instance, so the identity known before the call is only a
prediction."
  (agent-tasks-test--with-ledger nil
    (agent-tasks-test--with-session buffer
      (let* ((agent-tasks--reconciled t)
             (agent-tasks-dispatch-confirm nil)
             (agent-tasks-mode t)
             (id (agent-tasks-create :title "Fresh" :instruction "Begin"
                                     :directory temporary-file-directory)))
        (cl-letf (((symbol-function 'agent-tasks--read-target)
                   (lambda (task)
                     (list :session (agent-tasks--new-session-identity task))))
                  ((symbol-function 'agent-start-session)
                   (cl-function
                    (lambda (_session &key _initial-prompt &allow-other-keys)
                      ;; The backend resolved a different account and
                      ;; chose a non-default instance.
                      (with-current-buffer buffer
                        (setq-local agent--session
                                    (agent-session-create
                                     :backend 'stub
                                     :account "resolved"
                                     :directory "~/scratch/proj/"
                                     :instance "proj-2"
                                     :id "sid-fresh")))
                      buffer))))
          (agent-tasks-dispatch id)
          (let ((task (agent-tasks-find (agent-tasks-read) id)))
            (should (equal "resolved" (agent-tasks-task-account task)))
            (should (equal "proj-2" (agent-tasks-task-instance task)))
            (should (equal "sid-fresh" (agent-tasks-task-session-id task)))
            (should (string-match-p "identity confirmed"
                                    (agent-tasks-task-log task)))))))))

(ert-deftest agent-tasks-test-dispatch/a-failed-identity-repair-warns ()
  "The work is running, so a failed repair warns rather than failing."
  (agent-tasks-test--dispatchable
    (let ((warnings nil))
      (cl-letf (((symbol-function 'agent-tasks-session-readiness)
                 (lambda (_buffer) 'ready))
                ((symbol-function 'agent-tasks--confirm-identity)
                 (lambda (target task-id)
                   (ignore target task-id)
                   (push t warnings))))
        (agent-tasks-dispatch id)
        (should (= 1 (length warnings)))
        (should (= 1 (length submitted)))
        (should (equal "RUNNING"
                       (agent-tasks-task-state
                        (agent-tasks-find (agent-tasks-read) id))))))))

(ert-deftest agent-tasks-test-dispatch/refuses-an-unsatisfied-dependency ()
  "The gate names each unsatisfied dependency."
  (agent-tasks-test--dispatchable
    (let ((blocker (agent-tasks-create :title "Blocker")))
      (agent-tasks--update-task
       (agent-tasks-read) id
       (lambda () (agent-tasks--set-property "DEPENDS" blocker)))
      (cl-letf (((symbol-function 'agent-tasks-session-readiness)
                 (lambda (_buffer) 'ready)))
        (let ((error-message
               (cadr (should-error (agent-tasks-dispatch id)
                                   :type 'user-error))))
          (should (string-match-p blocker error-message)))
        (should (null submitted))))))

(ert-deftest agent-tasks-test-dispatch/refuses-a-running-task ()
  "A dispatched task is not dispatched again by the same command."
  (agent-tasks-test--dispatchable
    (agent-tasks--update-task
     (agent-tasks-read) id
     (lambda () (agent-tasks--set-state "RUNNING" "setup")))
    (should-error (agent-tasks-dispatch id) :type 'user-error)
    (should (null submitted))))

(ert-deftest agent-tasks-test-dispatch/requires-the-mode ()
  "Dispatch with nothing observing sessions is refused."
  (agent-tasks-test--dispatchable
    (let ((agent-tasks-mode nil))
      (should-error (agent-tasks-dispatch id) :type 'user-error)
      (should (null submitted)))))

(ert-deftest agent-tasks-test-dispatch/new-session-gets-an-initial-prompt ()
  "A new session receives the message as its first user message."
  (agent-tasks-test--with-ledger nil
    (agent-tasks-test--with-session buffer
      (let* ((agent-tasks--bindings (make-hash-table :test 'eq))
             (agent-tasks--reconciled t)
             (agent-tasks-dispatch-confirm nil)
             (agent-tasks-mode t)
             (started nil)
             (id (agent-tasks-create :title "Fresh" :instruction "Begin"
                                     :directory temporary-file-directory)))
        (cl-letf (((symbol-function 'agent-tasks--read-target)
                   (lambda (task)
                     (list :session (agent-tasks--new-session-identity task))))
                  ((symbol-function 'agent-start-session)
                   (cl-function
                    (lambda (session &key initial-prompt &allow-other-keys)
                      (push (cons session initial-prompt) started)
                      buffer))))
          (agent-tasks-dispatch id)
          (should (= 1 (length started)))
          (should (string-match-p "Begin" (cdr (car started))))
          (should (equal id (agent-tasks-bound-task buffer)))
          (should (equal "RUNNING"
                         (agent-tasks-task-state
                          (agent-tasks-find (agent-tasks-read) id)))))))))

(defmacro agent-tasks-test--without-function (symbol &rest body)
  "Run BODY with SYMBOL temporarily unbound as a function."
  (declare (indent 1) (debug (symbolp body)))
  `(let ((saved (and (fboundp ,symbol) (symbol-function ,symbol))))
     (unwind-protect (progn (fmakunbound ,symbol) ,@body)
       (when saved (fset ,symbol saved)))))

(ert-deftest agent-tasks-test-readiness/prefers-the-public-helper ()
  "The attention/queue helper wins when it exists."
  (agent-tasks-test--with-session buffer
    (cl-letf (((symbol-function 'agent-session-ready-to-submit-p)
               (lambda (&rest _) 'busy))
              ((symbol-function 'agent-session-display-state)
               (lambda (&rest _) 'waiting)))
      (should (eq 'busy (agent-tasks-session-readiness buffer))))))

(ert-deftest agent-tasks-test-readiness/falls-back-to-the-backend-slot ()
  "Without the helper, a registered backend probe decides."
  (agent-tasks-test--without-function 'agent-session-ready-to-submit-p
    (let ((agent-backends nil))
      (with-temp-buffer
        (rename-buffer "*stub:~/scratch/proj/:default*" t)
        (let ((buffer (current-buffer)))
          (apply #'agent-register-backend 'stub
                 (agent-tasks-test--backend
                  :buffer-p (lambda (candidate) (eq candidate buffer))
                  :ready-to-submit-p (lambda (_b) 'busy)))
          (setq-local agent--backend 'stub)
          (cl-letf (((symbol-function 'agent-session-display-state)
                     (lambda (&rest _) 'waiting)))
            (should (eq 'busy (agent-tasks-session-readiness buffer)))))))))

(ert-deftest agent-tasks-test-readiness/falls-back-to-the-display-state ()
  "With neither source present, the display state decides — and
`waiting' is ambiguous, so it asks rather than assuming ready.

Revision 2's version of this test stubbed only the display state while
the public helper existed, so the fallback branch was never reached and
the assertions were vacuous.  Removing the higher-precedence sources is
what makes it a test."
  (agent-tasks-test--without-function 'agent-session-ready-to-submit-p
    (let ((agent-backends nil))
      (with-temp-buffer
        (rename-buffer "*stub:~/scratch/proj/:default*" t)
        (let ((buffer (current-buffer)))
          (apply #'agent-register-backend 'stub
                 (agent-tasks-test--backend
                  :buffer-p (lambda (candidate) (eq candidate buffer))))
          (setq-local agent--backend 'stub)
          (pcase-dolist (`(,display . ,expected)
                         '((busy . busy)
                           (waiting . unknown)
                           (background-waiting . unknown)
                           (unknown . unknown)))
            (cl-letf (((symbol-function 'agent-session-display-state)
                       (lambda (&rest _) display)))
              (should (eq expected
                          (agent-tasks-session-readiness buffer))))))))))

(ert-deftest agent-tasks-test-dispatch/pending-input-changes-nothing ()
  "A dirty or uninspectable prompt refuses before anything is written.
A warning shown only when `agent-tasks-dispatch-confirm' is non-nil
protects nobody who turned it off, which is why this is a refusal.

Asserting only that nothing was submitted would pass for an
implementation that wrote RUNNING and *then* refused, so this compares
the ledger's bytes, the state, the attempt, and the binding."
  (dolist (state '("half-typed prompt" unknown))
    (agent-tasks-test--dispatchable
      (let ((agent-tasks-dispatch-confirm nil)
            (before (agent-tasks--file-text agent-tasks-file)))
        (cl-letf (((symbol-function 'agent-tasks-session-readiness)
                   (lambda (_buffer) 'ready))
                  ((symbol-function 'agent-tasks--check-pending-input)
                   (lambda (buffer)
                     (if (eq state 'unknown)
                         (user-error "Cannot verify that %s's prompt is empty"
                                     (agent-display-name buffer))
                       (user-error "Session %s has unsent input (%s)"
                                   (agent-display-name buffer) state)))))
          (should-error (agent-tasks-dispatch id) :type 'user-error)
          (should (null submitted))
          (should (equal before (agent-tasks--file-text agent-tasks-file)))
          (let ((task (agent-tasks-find (agent-tasks-read) id)))
            (should (equal "PENDING" (agent-tasks-task-state task)))
            (should (= 0 (agent-tasks-task-attempt task))))
          (should-not (agent-tasks-bound-task buffer)))))))

(ert-deftest agent-tasks-test-pending-input/refuses-everything-but-nil ()
  "The probe's three answers map to proceed, refuse, refuse."
  (let ((agent-backends nil))
    (with-temp-buffer
      (rename-buffer "*stub:~/scratch/proj/:default*" t)
      (let ((buffer (current-buffer))
            (answer nil))
        (apply #'agent-register-backend 'stub
               (agent-tasks-test--backend
                :buffer-p (lambda (candidate) (eq candidate buffer))
                :pending-input-p (lambda (_b) answer)))
        (setq-local agent--backend 'stub)
        (setq answer nil)
        (should (agent-tasks--check-pending-input buffer))
        (setq answer "unsent text")
        (should-error (agent-tasks--check-pending-input buffer)
                      :type 'user-error)
        (setq answer 'unknown)
        (should-error (agent-tasks--check-pending-input buffer)
                      :type 'user-error)))))

(ert-deftest agent-tasks-test-dispatch/bound-task-never-starts-a-session ()
  "An already-bound task refuses before `agent-start-session' runs.
Revision 2 checked the pairing only for an existing target, so the new
session was created and given the initial prompt first."
  (agent-tasks-test--with-ledger nil
    (agent-tasks-test--with-session buffer
      (let* ((agent-tasks--reconciled t)
             (agent-tasks-dispatch-confirm nil)
             (agent-tasks-mode t)
             (started nil)
             (id (agent-tasks-create :title "Bound already"
                                     :directory temporary-file-directory)))
        (agent-tasks--update-task
         (agent-tasks-read) id
         (lambda () (agent-tasks--set-state "UNKNOWN" "setup")))
        (agent-tasks--bind buffer id)
        (cl-letf (((symbol-function 'agent-tasks--read-target)
                   (lambda (task)
                     (list :session (agent-tasks--new-session-identity task))))
                  ((symbol-function 'agent-start-session)
                   (lambda (&rest _) (push t started) buffer)))
          (should-error (agent-tasks-dispatch id) :type 'user-error)
          (should (null started))
          (should (equal "UNKNOWN"
                         (agent-tasks-task-state
                          (agent-tasks-find (agent-tasks-read) id)))))))))
```

Note the readiness fallback test only exercises the third source: the
first two are supplied by the other two projects, and Task 14's live
verification is what proves the preference order against a real
session.  The unit test asserts the fallback because that is the branch
this module owns.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test`
Expected: every test added in Step 1 fails, with `Symbol's function definition is void:
agent-tasks-message`.

- [ ] **Step 3: Implement the dispatcher**

Add the two defcustoms next to `agent-tasks-file`:

```elisp
(defcustom agent-tasks-dispatch-confirm t
  "When non-nil, show the outgoing message and confirm before dispatching."
  :type 'boolean
  :group 'agent-tasks)

(defcustom agent-tasks-dispatch-footer
  (concat
   "This task is tracked in a durable Emacs ledger that records its state.\n"
   "The ledger does not infer completion from your turn ending, and nothing\n"
   "marks this task done on your behalf.  When you stop, say plainly what\n"
   "you did, what you verified, and what you did not verify.")
  "Text appended to every dispatched task message."
  :type 'string
  :group 'agent-tasks)
```

Add the dispatch section:

```elisp
;;;; Dispatch

(defun agent-tasks-message (task attempt)
  "Return the exact message dispatched for TASK as ATTEMPT.
Pure: the same task and attempt always render the same bytes.  The
Result and Evidence sections are deliberately excluded — they are the
person's record of an outcome, not input to a run.  What the next
attempt should know goes in the instruction, which the person edits."
  (concat
   (format "[Agent task %s — attempt %d]\n\n"
           (agent-tasks-task-id task) attempt)
   (string-trim (or (agent-tasks-task-instruction task) ""))
   "\n\n---\n"
   agent-tasks-dispatch-footer
   "\n"))

(defun agent-tasks-session-readiness (buffer)
  "Return `ready', `busy', or `unknown' for session BUFFER.
Three sources, most authoritative first: the public readiness helper
\(attention/queue project), the backend readiness slot (composer
project), and the display state.  Only the first two can tell that a
session stopped at a permission dialog, which displays as `waiting'."
  (cond
   ((fboundp 'agent-session-ready-to-submit-p)
    (agent-session-ready-to-submit-p buffer))
   ((when-let* ((backend (agent--detect-backend buffer))
                (struct (agent-backend backend))
                (probe (and (fboundp 'agent-backend-ready-to-submit-p)
                            (agent-backend-ready-to-submit-p struct))))
      (funcall probe buffer)))
   (t
    ;; `waiting' is ambiguous here: it covers both "at a fresh prompt"
    ;; and "stopped at a permission dialog", and only the two sources
    ;; above can tell them apart — this branch runs precisely when
    ;; neither is available.  Calling it `ready' would send a task into
    ;; a dialog, so it maps to `unknown', which asks.
    (pcase (agent-session-display-state buffer)
      ('busy 'busy)
      (_ 'unknown)))))

(defun agent-tasks--check-pending-input (buffer)
  "Refuse a dispatch into BUFFER unless its prompt is verifiably clean.
Consumes the composer project's `:pending-input-p' slot: nil means
clean, a truthy value names what is pending, and `unknown' means the
transport cannot be inspected.  Anything but nil refuses — a blind
append is the outcome this exists to prevent, and `unknown' is not
evidence of cleanliness.

Revision 2 settled for a line in the confirmation buffer.  That is not
a safeguard: it disappears exactly when `agent-tasks-dispatch-confirm'
is nil, which is the configuration of the person who most needs it."
  (let* ((backend (agent--detect-backend buffer))
         (struct (and backend (agent-backend backend)))
         (probe (and struct (fboundp 'agent-backend-pending-input-p)
                     (agent-backend-pending-input-p struct)))
         (state (if probe (funcall probe buffer) 'unknown)))
    (cond
     ((null state) t)
     ((eq state 'unknown)
      (user-error
       "Cannot verify that %s's prompt is empty, so a task message would not be isolated; nothing was sent"
       (agent-display-name buffer)))
     (t
      (user-error "Session %s has unsent input (%s); nothing was sent"
                  (agent-display-name buffer) state)))))

(defun agent-tasks--submit (message buffer)
  "Submit MESSAGE into session BUFFER as one isolated turn.
Uses the composer project's `:submit-literal' slot rather than
`agent-submit', so the task's message is a literal turn of its own
instead of text appended to whatever the prompt already held."
  (let* ((backend (agent--detect-backend buffer))
         (struct (and backend (agent-backend backend)))
         (submit (and struct (fboundp 'agent-backend-submit-literal)
                      (agent-backend-submit-literal struct))))
    (unless submit
      (user-error
       "Backend `%s' registers no literal submitter, so a task cannot be dispatched into an existing session"
       backend))
    (funcall submit message buffer)))

;;;###autoload
(defun agent-tasks-dispatch (&optional id override-dependencies)
  "Dispatch task ID into a session and mark it RUNNING.
With a prefix argument, OVERRIDE-DEPENDENCIES asks to proceed past an
unsatisfied dependency gate instead of refusing.

This command is the only path into RUNNING.  Nothing here is
automatic, and nothing retries: a task that already ran and ended
ambiguously is dispatched again only through `agent-tasks-resume',
which records a new attempt."
  (interactive (list nil current-prefix-arg))
  (agent-tasks--require-mode)
  (let* ((ledger (agent-tasks--ensure-reconciled (agent-tasks-read)))
         (id (or id (agent-tasks--read-task-id
                     ledger "Dispatch task: "
                     '("PENDING" "UNKNOWN" "BLOCKED")))))
    (agent-tasks--perform-dispatch
     (agent-tasks--prepare-dispatch ledger id override-dependencies))))

(defun agent-tasks--prepare-dispatch (ledger id override-dependencies)
  "Validate a dispatch of task ID in LEDGER, asking every question now.
Return a plist with `:ledger', `:id', `:attempt', `:message',
`:instruction', `:state', `:override', `:buffer' (nil for a new
session), `:session' (nil for an existing one), and `:readiness' — the
answer the person agreed to.  Everything interactive happens here so
the send that follows asks nothing and nothing can intervene between
the last check and the message.

The snapshot fields are what the commit re-checks: the person approved
*this* task in *this* state with *this* instruction, and anything else
is a different decision."
  (let* ((task (or (agent-tasks-find ledger id)
                   (user-error "No task with id %s" id)))
         (state (agent-tasks-task-state task)))
    (unless (member state '("PENDING" "UNKNOWN" "BLOCKED"))
      (user-error
       "Task %s is %s; only PENDING, UNKNOWN and BLOCKED tasks are dispatched"
       id state))
    (let* ((override (agent-tasks--check-dependencies
                      ledger task override-dependencies))
           (attempt (1+ (agent-tasks-task-attempt task)))
           (message (agent-tasks-message task attempt))
           (target (agent-tasks--read-target task))
           (buffer (plist-get target :buffer))
           (readiness (when buffer (agent-tasks--confirm-readiness buffer))))
      ;; Both directions, both kinds of target.  A new session has no
      ;; buffer to check against, but the task may still be bound.
      (agent-tasks--check-task-unbound id)
      (when buffer (agent-tasks--check-bindable buffer id))
      (agent-tasks--confirm-message task message target)
      (list :ledger ledger :id id :attempt attempt :message message
            :entry-token (agent-tasks-task-entry-token task)
            :state state :override override
            :buffer buffer :session (plist-get target :session)
            :readiness readiness))))

(defun agent-tasks--check-dependencies (ledger task override)
  "Refuse a dispatch of TASK when a dependency in LEDGER is unsatisfied.
OVERRIDE non-nil asks for confirmation instead of refusing.  Return the
list of unsatisfied dependencies the person agreed to override, or nil
— the caller carries it into the record, because an override that is
asked for and then discarded leaves no trace that the gate was
bypassed."
  (let ((unsatisfied (agent-tasks-unsatisfied-dependencies ledger task)))
    (when unsatisfied
      (let ((description (agent-tasks--describe-dependencies unsatisfied)))
        (if override
            (unless (yes-or-no-p
                     (format "Dependencies unsatisfied: %s.  Dispatch anyway? "
                             description))
              (user-error "Not dispatched"))
          (user-error "Task %s depends on %s"
                      (agent-tasks-task-id task) description))))
    unsatisfied))

(defun agent-tasks--describe-dependencies (unsatisfied)
  "Return a readable rendering of UNSATISFIED dependency entries."
  (mapconcat (lambda (entry) (format "%s (%s)" (car entry) (cdr entry)))
             unsatisfied ", "))

(defun agent-tasks--read-target (task)
  "Read the session to dispatch TASK into.
Return a plist with either `:buffer' (an existing session) or
`:session' (the identity of a new one)."
  (if (equal "new session"
             (completing-read "Dispatch into: "
                              '("existing session" "new session") nil t))
      (list :session (agent-tasks--new-session-identity task))
    (list :buffer (agent--read-session-buffer))))

(defun agent-tasks--new-session-identity (task)
  "Return the `agent-session' identity of a new session running TASK.
A task with no recorded directory prompts for one: the directory
decides which project the agent will act in, so it is never defaulted
silently."
  (let* ((recorded (agent-tasks-task-directory task))
         (directory (if recorded
                        (expand-file-name recorded)
                      (read-directory-name "Directory for the new session: ")))
         (backend (if-let* ((name (agent-tasks-task-backend task)))
                      (intern name)
                    (agent--resolve-backend))))
    (unless (file-directory-p directory)
      (user-error "Task directory does not exist: %s" directory))
    (unless (agent-backend backend)
      (user-error "Backend `%s' is not registered" backend))
    (agent-session-create
     :backend backend
     :account (agent-tasks-task-account task)
     :directory (agent-session--normalize-directory directory))))

(defun agent-tasks--confirm-readiness (buffer)
  "Return BUFFER's readiness, confirming an unknown state.
Signal a `user-error' when the session cannot take a turn."
  (let ((readiness (agent-tasks-session-readiness buffer)))
    (pcase readiness
      ('ready readiness)
      ('unknown
       (if (yes-or-no-p (format "State of %s is unknown; dispatch anyway? "
                                (agent-display-name buffer)))
           readiness
         (user-error "Not dispatched")))
      (_
       (user-error
        "Session %s cannot take a turn now (%s); finish the turn first, or queue text by hand with `agent-queue-prompt'"
        (agent-display-name buffer) readiness)))))

(defun agent-tasks--confirm-message (task message target)
  "Show MESSAGE for TASK going to TARGET and confirm the dispatch."
  (when agent-tasks-dispatch-confirm
    (let ((buffer (get-buffer-create "*Agent task dispatch*")))
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (format "Task:   %s  %s\n"
                          (agent-tasks-task-id task)
                          (agent-tasks-task-title task)))
          (insert (format "Target: %s\n"
                          (if-let* ((existing (plist-get target :buffer)))
                              (agent-display-name existing)
                            (let ((session (plist-get target :session)))
                              (format "new %s session in %s"
                                      (agent-session-backend session)
                                      (agent-session-directory session))))))
          (insert "\n")
          (insert message))
        (special-mode)
        (goto-char (point-min)))
      (display-buffer buffer)
      (unwind-protect
          (unless (yes-or-no-p "Dispatch this message? ")
            (user-error "Not dispatched"))
        (when-let* ((window (get-buffer-window buffer)))
          (quit-window nil window))))))

(defun agent-tasks--record-target-properties (buffer)
  "Record BUFFER's session identity on the task at point."
  (when-let* ((session (agent-session buffer)))
    (let ((directory (when-let* ((raw (agent-session-directory session)))
                       (agent-session--normalize-directory raw))))
      (agent-tasks--set-property
       "BACKEND" (when-let* ((backend (agent-session-backend session)))
                   (symbol-name backend)))
      (agent-tasks--set-property "ACCOUNT" (agent-session-account session))
      (agent-tasks--set-property "DIRECTORY" directory)
      (agent-tasks--set-property "REPOSITORY"
                                 (agent-tasks--repository directory))
      (agent-tasks--set-property "INSTANCE"
                                 (agent-session-instance session)))))

(defun agent-tasks--assert-snapshot (prepared)
  "Signal unless the task's entry is byte-for-byte the reviewed one.
Return the fresh ledger.

One token over the whole entry, not a list of compared fields.
Revision 2 compared state, attempt, instruction and the dependency
verdict, and an ordinary cancel-then-reopen restores every one of them
while the task has been through two decisions the dispatcher knows
nothing about; edits to the recorded directory, backend or account were
not compared at all and would have been overwritten by the commit.  A
per-entry token covers every field, present and future, and cannot
drift out of step with the record.

It is also narrower than a whole-file token would be: an unrelated
task's event write during the preview does not refuse this dispatch."
  (let* ((ledger (agent-tasks-read))
         (id (plist-get prepared :id))
         (task (or (agent-tasks-find ledger id)
                   (user-error "Task %s is no longer in the ledger; nothing was sent"
                               id))))
    (unless (equal (agent-tasks-task-entry-token task)
                   (plist-get prepared :entry-token))
      (user-error "Task %s changed since the preview (now %s); nothing was sent"
                  id (agent-tasks-task-state task)))
    ;; The entry token covers this task's bytes; the dependency verdict
    ;; lives in *other* tasks' entries, so reopening a dependency that
    ;; was satisfied at preview changes the decision without touching
    ;; this entry at all.  Recompute and require the same verdict.
    (let ((now (agent-tasks-unsatisfied-dependencies ledger task)))
      (unless (equal now (plist-get prepared :override))
        (user-error
         "Task %s's dependencies changed since the preview (%s); nothing was sent"
         id (if now (agent-tasks--describe-dependencies now) "now satisfied"))))
    ledger))

(defun agent-tasks--perform-dispatch (prepared)
  "Send the dispatch described by PREPARED and return the session buffer.
Asks nothing.  The ledger is written *before* the send, so a ledger
that cannot record the run stops it rather than starting untracked
work; a send that does not complete moves the task to UNKNOWN, never
back to PENDING, because text may have reached the CLI before the
failure and PENDING would invite a second send of work that may
already be running."
  (let* ((id (plist-get prepared :id))
         (attempt (plist-get prepared :attempt))
         (message (plist-get prepared :message))
         (buffer (plist-get prepared :buffer))
         (session (plist-get prepared :session))
         (override (plist-get prepared :override)))
    (agent-tasks--check-task-unbound id)
    (when buffer
      (unless (buffer-live-p buffer)
        (user-error "The target session is gone; nothing was sent"))
      (unless (eq (agent-tasks-session-readiness buffer)
                  (plist-get prepared :readiness))
        (user-error "Session %s changed state before the send; nothing was sent"
                    (agent-display-name buffer)))
      ;; Re-check ownership immediately before the send.  Binding after
      ;; the send, as revision 1 did, delivers the prompt to a session
      ;; that already holds another task and only then signals.
      (agent-tasks--check-bindable buffer id)
      (agent-tasks--check-pending-input buffer))
    (agent-tasks-transition
     (agent-tasks--assert-snapshot prepared) id "RUNNING"
     (format "dispatch attempt %d into %s%s" attempt
             (if buffer (agent-display-name buffer) "a new session")
             (if override
                 (format "; dependency gate overridden: %s"
                         (agent-tasks--describe-dependencies override))
               ""))
     :extra
     (lambda ()
       (agent-tasks--set-property "ATTEMPT" attempt)
       ;; The previous attempt's native id describes a different run.
       (agent-tasks--set-property "SESSION_ID" nil)
       (if buffer
           (agent-tasks--record-target-properties buffer)
         (let ((directory (agent-session-directory session)))
           (agent-tasks--set-property
            "BACKEND" (symbol-name (agent-session-backend session)))
           (agent-tasks--set-property "ACCOUNT"
                                      (agent-session-account session))
           (agent-tasks--set-property "DIRECTORY" directory)
           (agent-tasks--set-property "REPOSITORY"
                                      (agent-tasks--repository directory))
           (agent-tasks--set-property "INSTANCE"
                                      (agent-session-instance session))))))
    (condition-case err
        (let ((target (if buffer
                          (progn (agent-tasks--submit message buffer) buffer)
                        (agent-start-session session :initial-prompt message))))
          (agent-tasks--bind target id)
          (agent-tasks--confirm-identity target id)
          (message "Dispatched task %s to %s" id (agent-display-name target))
          target)
      ((quit error)
       (agent-tasks--safe-transition
        id "UNKNOWN"
        (format "submission did not complete; delivery unproven: %s"
                (error-message-string err)))
       (signal (car err) (cdr err))))))

(defun agent-tasks--confirm-identity (buffer id)
  "Record BUFFER's actual identity on task ID after a successful start.
`agent-start-session' fills a nil account from `agent-account-resolve'
and a backend may choose a different instance when one is taken, so the
identity known *before* the call is a prediction — and reconciliation
compares recorded identity for equality, so a wrong prediction makes
the task unreconcilable.  Revision 1 repaired only the session id.

A failing repair leaves the task RUNNING and warns: the work is
running, so reporting the dispatch as failed would be worse."
  (condition-case err
      (agent-tasks--update-task
       (agent-tasks-read) id
       (lambda ()
         (agent-tasks--record-target-properties buffer)
         (agent-tasks--set-property
          "SESSION_ID" (when-let* ((session (agent-session buffer)))
                         (agent-session-id session)))
         (agent-tasks--log "identity confirmed against %s"
                           (agent-display-name buffer))))
    (error
     (display-warning
      'agent-tasks
      (format "task %s is running in %s, but its recorded identity could not be confirmed (%s); check it with `e'"
              id (agent-display-name buffer) (error-message-string err))
      :warning))))
```

The `condition-case` catches `quit` as well as `error` because starting
a new session can prompt (an instance name, an account), and a `C-g`
there leaves exactly the same "did text reach the CLI?" question a
signal does.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test`
Expected: `0 unexpected`, and the total rises by exactly the number of `ert-deftest` forms this task adds (count them in the diff).

- [ ] **Step 5: Byte-compile and commit**

```bash
make compile
git add agent-tasks.el test/agent-tasks-test.el
git commit -m "feat(tasks): add the task dispatcher and its message"
```

---

### Task 9: Resume actions and restart attachment

**Files:**
- Modify: `agent-tasks.el` (new "Resuming" and "Restart" sections;
  `agent-tasks--install-event-hooks` / `--remove-event-hooks`)
- Test: `test/agent-tasks-test.el`

**Interfaces:**
- Consumes: Tasks 5–8; `agent-before-restart-functions` and
  `agent-after-restart-functions` from the attention/queue project,
  both accessed through `boundp`.
- Produces (used by Tasks 10, 14):
  - `agent-tasks-resume ID ACTION` — autoloaded command; ACTION is
    `dispatch`, `attach`, or `pending`.
  - `agent-tasks--resume-actions` — the choice alist.
  - `agent-tasks--attach ID BUFFER`.
  - `agent-tasks--before-restart BUFFER SESSION-ID`,
    `agent-tasks--after-restart BUFFER SESSION-ID`,
    `agent-tasks--restart-pending`.

- [ ] **Step 1: Write the failing tests**

Add to `test/agent-tasks-test.el`:

```elisp
;;;; Resuming

(ert-deftest agent-tasks-test-resume/attach-binds-without-sending ()
  "Attaching records a binding the person vouched for and sends nothing."
  (agent-tasks-test--with-ledger nil
    (agent-tasks-test--with-session buffer
      (let* ((agent-tasks--bindings (make-hash-table :test 'eq))
             (agent-tasks-mode t)
             (submitted nil)
             (id (agent-tasks-create :title "Orphan")))
        (agent-tasks--update-task
         (agent-tasks-read) id
         (lambda () (agent-tasks--set-state "UNKNOWN" "setup")))
        (cl-letf (((symbol-function 'agent-tasks--submit)
                   (lambda (&rest _) (push t submitted)))
                  ((symbol-function 'agent-submit)
                   (lambda (&rest _) (push t submitted))))
          (agent-tasks-resume id 'attach)
          (should (null submitted))
          (should (equal id (agent-tasks-bound-task buffer)))
          (let ((task (agent-tasks-find (agent-tasks-read) id)))
            (should (equal "RUNNING" (agent-tasks-task-state task)))
            (should (string-match-p "no message was sent"
                                    (agent-tasks-task-log task)))))))))

(ert-deftest agent-tasks-test-resume/pending-unbinds-and-clears ()
  "Leaving a task pending detaches it and sends nothing."
  (agent-tasks-test--with-ledger nil
    (agent-tasks-test--with-session buffer
      (let* ((agent-tasks--bindings (make-hash-table :test 'eq))
             (agent-tasks-mode t)
             (id (agent-tasks-create :title "Orphan")))
        (agent-tasks--update-task
         (agent-tasks-read) id
         (lambda () (agent-tasks--set-state "UNKNOWN" "setup")))
        (agent-tasks--bind buffer id)
        (agent-tasks-resume id 'pending)
        (should-not (agent-tasks-bound-task buffer))
        (should (equal "PENDING"
                       (agent-tasks-task-state
                        (agent-tasks-find (agent-tasks-read) id))))))))

(ert-deftest agent-tasks-test-resume/refuses-a-session-already-bound ()
  "Attaching to a session that holds another task is refused."
  (agent-tasks-test--with-ledger nil
    (agent-tasks-test--with-session buffer
      (let* ((agent-tasks--bindings (make-hash-table :test 'eq))
             (agent-tasks-mode t)
             (first (agent-tasks-create :title "First"))
             (second (agent-tasks-create :title "Second")))
        (agent-tasks--bind buffer first)
        (agent-tasks--update-task
         (agent-tasks-read) second
         (lambda () (agent-tasks--set-state "UNKNOWN" "setup")))
        (should-error (agent-tasks--attach second buffer) :type 'user-error)
        (should (equal "UNKNOWN"
                       (agent-tasks-task-state
                        (agent-tasks-find (agent-tasks-read) second))))))))

;;;; Restart

(ert-deftest agent-tasks-test-restart/follows-a-resumed-session ()
  "A restart that resumed the same native id keeps the binding and state."
  (agent-tasks-test--with-ledger nil
    (agent-tasks-test--with-session buffer
      (let* ((agent-tasks--bindings (make-hash-table :test 'eq))
             (agent-tasks--restart-pending nil)
             (id (agent-tasks-create :title "Restarted")))
        (setf (agent-session-id (agent-session buffer)) "sid-3")
        (agent-tasks--update-task
         (agent-tasks-read) id
         (lambda () (agent-tasks--set-state "RUNNING" "setup")))
        (agent-tasks--bind buffer id)
        (agent-tasks--before-restart buffer "sid-3")
        (should-not (agent-tasks-bound-task buffer))
        (agent-tasks--after-restart buffer "sid-3")
        (should (equal id (agent-tasks-bound-task buffer)))
        (should (equal "RUNNING"
                       (agent-tasks-task-state
                        (agent-tasks-find (agent-tasks-read) id))))))))

(ert-deftest agent-tasks-test-restart/a-different-session-goes-unknown ()
  "A restart that produced a different session is not the same run."
  (agent-tasks-test--with-ledger nil
    (agent-tasks-test--with-session buffer
      (let* ((agent-tasks--bindings (make-hash-table :test 'eq))
             (agent-tasks--restart-pending nil)
             (id (agent-tasks-create :title "Replaced")))
        (setf (agent-session-id (agent-session buffer)) "sid-new")
        (agent-tasks--update-task
         (agent-tasks-read) id
         (lambda () (agent-tasks--set-state "RUNNING" "setup")))
        (agent-tasks--bind buffer id)
        (agent-tasks--before-restart buffer "sid-old")
        (agent-tasks--after-restart buffer "sid-new")
        (should-not (agent-tasks-bound-task buffer))
        (should (equal "UNKNOWN"
                       (agent-tasks-task-state
                        (agent-tasks-find (agent-tasks-read) id))))))))

(defun agent-tasks-test--simulate-restart (buffer session-id starter)
  "Drive a whole `agent-restart'-shaped command for BUFFER.
Runs the before hook, calls STARTER, runs the after hook on success,
and then runs `post-command-hook' — the boundary the real command ends
at.  Calling the handlers in a hand-picked order, as revision 2's tests
did, cannot show whether the finalizer fires at the wrong moment.

STARTER stands in for everything `agent-restart' does after the before
hooks: it owns the kill of the old buffer as well as the startup, so a
test can model a startup that fails *after* the session was killed —
which is the case that must end UNKNOWN — separately from an abort that
happens before any kill."
  (agent-tasks--before-restart buffer session-id)
  (unwind-protect
      (let ((new-buffer (funcall starter)))
        (agent-tasks--after-restart new-buffer session-id))
    (run-hooks 'post-command-hook)))

(ert-deftest agent-tasks-test-restart/a-yielding-startup-still-succeeds ()
  "A startup that waits on process output must not trip the finalizer.
A zero-delay timer fires during `sit-for' — verified in batch — which
is why the finalizer is armed on `post-command-hook' instead."
  (agent-tasks-test--with-ledger nil
    (agent-tasks-test--with-session buffer
      (let* ((agent-tasks--restart-pending nil)
             (post-command-hook nil)
             (id (agent-tasks-create :title "Restarted")))
        (setf (agent-session-id (agent-session buffer)) "sid-3")
        (agent-tasks--update-task
         (agent-tasks-read) id
         (lambda () (agent-tasks--set-state "RUNNING" "setup")))
        (agent-tasks--bind buffer id)
        (agent-tasks-test--simulate-restart
         buffer "sid-3"
         (lambda () (sit-for 0.2) buffer))
        (should (equal "RUNNING"
                       (agent-tasks-task-state
                        (agent-tasks-find (agent-tasks-read) id))))
        (should (equal id (agent-tasks-bound-task buffer)))
        (should (null agent-tasks--restart-pending))
        (should-not (memq #'agent-tasks--finalize-restart post-command-hook))))))

(ert-deftest agent-tasks-test-restart/a-later-before-hook-signalling-rebinds ()
  "An abort before the kill leaves the session alive, so the task stays.
Core runs every before-restart hook before killing the buffer; a later
hook signalling must not turn a session that is still running into an
UNKNOWN task."
  (agent-tasks-test--with-ledger nil
    (agent-tasks-test--with-session buffer
      (let* ((agent-tasks--restart-pending nil)
             (post-command-hook nil)
             (id (agent-tasks-create :title "Aborted")))
        (setf (agent-session-id (agent-session buffer)) "sid-5")
        (agent-tasks--update-task
         (agent-tasks-read) id
         (lambda () (agent-tasks--set-state "RUNNING" "setup")))
        (agent-tasks--bind buffer id)
        ;; Our hook runs, then a later one signals: no kill, no startup.
        (agent-tasks--before-restart buffer "sid-5")
        (should-error (error "a later before-restart hook failed"))
        (run-hooks 'post-command-hook)
        (should (equal "RUNNING"
                       (agent-tasks-task-state
                        (agent-tasks-find (agent-tasks-read) id))))
        (should (equal id (agent-tasks-bound-task buffer)))
        (should (null agent-tasks--restart-pending))))))

(ert-deftest agent-tasks-test-restart/a-signalling-startup-ends-in-unknown ()
  "A detach whose startup signals must not leave the task RUNNING.
Revision 1's test asserted the abandoned RUNNING state was acceptable;
it is not, because nothing would ever have noticed it."
  (agent-tasks-test--with-ledger nil
    (agent-tasks-test--with-session buffer
      (let* ((agent-tasks--restart-pending nil)
             (post-command-hook nil)
             (id (agent-tasks-create :title "Abandoned")))
        (agent-tasks--update-task
         (agent-tasks-read) id
         (lambda () (agent-tasks--set-state "RUNNING" "setup")))
        (agent-tasks--bind buffer id)
        (should-error
         (agent-tasks-test--simulate-restart
          buffer "sid-1"
          (lambda ()
            ;; The real command kills first, then starts.
            (let ((kill-buffer-query-functions nil)) (kill-buffer buffer))
            (error "backend would not start"))))
        (should (null agent-tasks--restart-pending))
        (let ((task (agent-tasks-find (agent-tasks-read) id)))
          (should (equal "UNKNOWN" (agent-tasks-task-state task)))
          (should (string-match-p "a restart did not complete"
                                  (agent-tasks-task-log task))))))))

(ert-deftest agent-tasks-test-attach/refuses-a-wrong-source-state ()
  "Attaching is a resume action, not a way into RUNNING from anywhere."
  (agent-tasks-test--with-ledger nil
    (agent-tasks-test--with-session buffer
      (let ((agent-tasks-mode t)
            (id (agent-tasks-create :title "Pending")))
        (should-error (agent-tasks--attach id buffer) :type 'user-error)
        (should-not (agent-tasks-bound-task buffer))))))

(ert-deftest agent-tasks-test-attach/clears-a-stale-session-id ()
  "An id from an earlier run must not survive onto a new binding."
  (agent-tasks-test--with-ledger nil
    (agent-tasks-test--with-session buffer
      (let ((agent-tasks-mode t)
            (id (agent-tasks-create :title "Orphan")))
        (agent-tasks--update-task
         (agent-tasks-read) id
         (lambda ()
           (agent-tasks--set-property "SESSION_ID" "sid-old")
           (agent-tasks--set-state "UNKNOWN" "setup")))
        (setf (agent-session-id (agent-session buffer)) "sid-new")
        (agent-tasks--attach id buffer)
        (should (equal "sid-new"
                       (agent-tasks-task-session-id
                        (agent-tasks-find (agent-tasks-read) id))))))))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test`
Expected: every test added in Step 1 fails, with `Symbol's function definition is void:
agent-tasks-resume`.

- [ ] **Step 3: Implement resume and restart attachment**

Add to `agent-tasks.el`:

```elisp
;;;; Resuming

(defconst agent-tasks--resume-actions
  '(("dispatch a fresh attempt" . dispatch)
    ("attach to a session I pick, sending nothing" . attach)
    ("unbind and leave it pending" . pending))
  "The choices `agent-tasks-resume' offers.
There is deliberately no automatic option: an ambiguous run is a
decision for a person, and the decision is what gets recorded.")

;;;###autoload
(defun agent-tasks-resume (id action)
  "Decide what to do about UNKNOWN or BLOCKED task ID.
ACTION is `dispatch' (a fresh attempt), `attach' (bind to a session
you pick, sending nothing), or `pending' (unbind and leave it
PENDING)."
  (interactive
   (let* ((ledger (agent-tasks--ensure-reconciled (agent-tasks-read)))
          (id (agent-tasks--read-task-id ledger "Resume task: "
                                         '("UNKNOWN" "BLOCKED"))))
     (list id
           (cdr (assoc (completing-read
                        "Action: "
                        (mapcar #'car agent-tasks--resume-actions) nil t)
                       agent-tasks--resume-actions)))))
  (pcase action
    ('dispatch (agent-tasks-dispatch id))
    ('attach (agent-tasks--attach id (agent--read-session-buffer)))
    ('pending
     (when-let* ((buffer (agent-tasks-task-buffer id)))
       (agent-tasks--unbind buffer))
     (agent-tasks-transition (agent-tasks-read) id "PENDING"
                             "resumed: unbound and left pending")
     (message "Task %s is pending again" id))
    (_ (user-error "Unknown resume action: %S" action))))

(defun agent-tasks--attach (id buffer)
  "Bind task ID to session BUFFER and mark it RUNNING, sending nothing.
The person's choice of session is the proof of identity, so this is a
person-initiated transition into RUNNING — the only kind there is.

Three guards, all before the write, so a refusal leaves the ledger
untouched: the source state must be one the matrix permits to reach
RUNNING this way, the bijection must allow the pairing in **both**
directions, and the previous attempt's `SESSION_ID' is cleared before
the new session's is recorded — otherwise a stale id from an earlier
run would sit on a task now bound to a different session, and
reconciliation would later match the wrong one."
  (agent-tasks--require-mode)
  (let ((task (or (agent-tasks-find (agent-tasks-read) id)
                  (user-error "No task with id %s" id))))
    (unless (member (agent-tasks-task-state task) '("UNKNOWN" "BLOCKED"))
      (user-error "Task %s is %s; only UNKNOWN and BLOCKED tasks are attached"
                  id (agent-tasks-task-state task))))
  (agent-tasks--check-bindable buffer id)
  (agent-tasks-transition
   (agent-tasks-read) id "RUNNING"
   (format "attached by hand to %s; no message was sent"
           (agent-display-name buffer))
   :extra
   (lambda ()
     (agent-tasks--set-property "SESSION_ID" nil)
     (agent-tasks--record-target-properties buffer)))
  (agent-tasks--bind buffer id)
  (agent-tasks--confirm-identity buffer id)
  (message "Task %s attached to %s" id (agent-display-name buffer)))

;;;; Restart

(defvar agent-tasks--restart-pending nil
  "The binding detached by `agent-tasks--before-restart', or nil.
A plist with `:id' and `:session-id'.")

(defun agent-tasks--before-restart (buffer session-id)
  "Detach BUFFER's task binding before `agent-restart' kills it.
Member of `agent-before-restart-functions'.  Detaching first is what
keeps teardown quiet: with no binding it has nothing to report, so no
special case is needed there.

A one-shot `post-command-hook' finalizer is armed at the same time.  If
`agent-start-session' signals, the after-restart hook never runs, and
revision 1 left the task RUNNING with no binding and nothing to notice
— its own test asserted that abandoned state was acceptable, which was
wrong.  The guarantee is that a detach is always followed by either a
re-attachment or an UNKNOWN, by the end of the command that started the
restart.

It must not be a timer.  Revision 2 used `run-at-time 0', and a
zero-delay timer **does** fire while a command yields — verified in
batch with `sit-for' standing in for a backend startup waiting on
process output — so a successful restart could be marked UNKNOWN
underneath itself.  `post-command-hook' runs after `agent-restart'
returns, whether it succeeded or signalled."
  (when-let* ((id (agent-tasks-bound-task buffer)))
    (setq agent-tasks--restart-pending
          (list :id id :session-id session-id :buffer buffer))
    (agent-tasks--unbind buffer)
    (add-hook 'post-command-hook #'agent-tasks--finalize-restart)))

(defun agent-tasks--finalize-restart ()
  "Close out a restart whose after-restart hook never ran.
One-shot: removes itself from `post-command-hook' however it exits.

Core runs **every** before-restart hook before killing the buffer, so a
*later* hook signalling aborts the restart with the original session
still alive.  Marking the task UNKNOWN there would be wrong: nothing
happened to the session.  The original buffer is therefore kept in the
pending record, and when it is still live and still reports the session
id the detach expected, the binding is simply restored."
  (remove-hook 'post-command-hook #'agent-tasks--finalize-restart)
  (when-let* ((pending agent-tasks--restart-pending))
    (setq agent-tasks--restart-pending nil)
    (let ((id (plist-get pending :id))
          (buffer (plist-get pending :buffer))
          (session-id (plist-get pending :session-id)))
      (if (and (buffer-live-p buffer)
               (equal session-id
                      (when-let* ((session (agent-session buffer)))
                        (agent-session-id session))))
          (progn
            (agent-tasks--bind buffer id)
            (agent-tasks--safe-log
             id "restart aborted before the session was replaced; binding restored"))
        (agent-tasks--safe-transition
         id "UNKNOWN" "a restart did not complete"
         :only-when agent-tasks--live-states)))))

(defun agent-tasks--after-restart (buffer session-id)
  "Re-attach the task detached by `agent-tasks--before-restart'.
Member of `agent-after-restart-functions'.  The task follows the
session only when the resumed native id is the one it was detached
from and the new buffer reports that same id — the non-fork resume
case, the only one where identity is proven.  Anything else leaves the
task UNKNOWN, the honest answer for a session that was replaced rather
than resumed."
  (remove-hook 'post-command-hook #'agent-tasks--finalize-restart)
  (let ((pending agent-tasks--restart-pending))
    (setq agent-tasks--restart-pending nil)
    (when pending
      (let ((id (plist-get pending :id)))
        (if (and (buffer-live-p buffer)
                 session-id
                 (equal session-id (plist-get pending :session-id))
                 (equal session-id
                        (when-let* ((session (agent-session buffer)))
                          (agent-session-id session))))
            (progn
              (agent-tasks--bind buffer id)
              (agent-tasks--safe-log
               id "re-attached after a restart that resumed session %s"
               session-id))
          (agent-tasks--safe-transition
           id "UNKNOWN" "a restart did not resume the same session"
           :only-when agent-tasks--live-states))))))
```

Extend the two hook installers from Task 6:

```elisp
(defun agent-tasks--install-event-hooks ()
  "Install the session-event and restart hooks the mode owns.
The restart hooks come from the attention/queue project and are
optional here: without them a restart looks like a session that ended,
which teardown already reports honestly as UNKNOWN."
  (add-hook 'agent-session-event-functions
            #'agent-tasks--handle-session-event)
  (when (boundp 'agent-before-restart-functions)
    (add-hook 'agent-before-restart-functions #'agent-tasks--before-restart))
  (when (boundp 'agent-after-restart-functions)
    (add-hook 'agent-after-restart-functions #'agent-tasks--after-restart)))

(defun agent-tasks--remove-event-hooks ()
  "Remove the hooks `agent-tasks--install-event-hooks' installed."
  (remove-hook 'agent-session-event-functions
               #'agent-tasks--handle-session-event)
  (when (boundp 'agent-before-restart-functions)
    (remove-hook 'agent-before-restart-functions
                 #'agent-tasks--before-restart))
  (when (boundp 'agent-after-restart-functions)
    (remove-hook 'agent-after-restart-functions
                 #'agent-tasks--after-restart)))
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test`
Expected: `0 unexpected`, and the total rises by exactly the number of `ert-deftest` forms this task adds (count them in the diff).

- [ ] **Step 5: Byte-compile and commit**

```bash
make compile
git add agent-tasks.el test/agent-tasks-test.el
git commit -m "feat(tasks): add resume actions and restart re-attachment"
```

---

### Task 10: The task list

**Files:**
- Modify: `agent-tasks.el` (new "The task list" section)
- Test: `test/agent-tasks-test.el`

**Interfaces:**
- Consumes: Tasks 3–9; `tabulated-list-mode`, `agent-display-name`.
- Produces (used by Tasks 11, 12, 14):
  - `agent-tasks` — the autoloaded command opening `*Agent tasks*`.
  - `agent-tasks-list-mode`, `agent-tasks-list-mode-map`.
  - `agent-tasks--list-entries LEDGER` → `tabulated-list-entries`.
  - `agent-tasks--task-less-p A B`, `agent-tasks--age TASK`,
    `agent-tasks--project-name TASK`,
    `agent-tasks--session-label TASK`,
    `agent-tasks--dependency-cell LEDGER TASK`,
    `agent-tasks--header-line LEDGER PROBLEMS`.
  - `agent-tasks-visit-source ID` — moved here from Task 11 so this
    task's `agent-tasks-list-visit-source' compiles without a forward
    reference.
  - The list commands `agent-tasks-list-show`,
    `-dispatch`, `-switch`, `-open-transcript`, `-block`, `-done`,
    `-cancel`, `-resume`, `-reopen`, `-unbind`, `-comment`, `-edit`,
    `-visit-source`, `-filter`, `-refresh`.
  - `agent-tasks-open-transcript ID`.

- [ ] **Step 1: Write the failing tests**

Add to `test/agent-tasks-test.el`:

```elisp
;;;; The list

(ert-deftest agent-tasks-test-list/orders-open-states-first ()
  "The order is total: rank, then newest first, then id."
  (agent-tasks-test--with-ledger
      (concat agent-tasks--header
              "* DONE Closed\n:PROPERTIES:\n:AGENT_TASK_ID: t-1\n"
              ":CREATED: [2026-07-31 Fri 10:00]\n:OUTCOME: succeeded\n:END:\n"
              "* PENDING Waiting\n:PROPERTIES:\n:AGENT_TASK_ID: t-2\n"
              ":CREATED: [2026-07-31 Fri 11:00]\n:END:\n"
              "* UNKNOWN Lost\n:PROPERTIES:\n:AGENT_TASK_ID: t-3\n"
              ":CREATED: [2026-07-31 Fri 09:00]\n:END:\n"
              "* BLOCKED Stuck\n:PROPERTIES:\n:AGENT_TASK_ID: t-4\n"
              ":CREATED: [2026-07-31 Fri 08:00]\n"
              ":BLOCKED_REASON: waiting\n:END:\n")
    (let* ((ledger (agent-tasks-read))
           (sorted (sort (copy-sequence (agent-tasks-ledger-tasks ledger))
                         #'agent-tasks--task-less-p)))
      (should (equal '("t-4" "t-3" "t-2" "t-1")
                     (mapcar #'agent-tasks-task-id sorted))))))

(ert-deftest agent-tasks-test-list/is-stable-across-refreshes ()
  "Sorting the same ledger twice gives the same order."
  (agent-tasks-test--with-ledger agent-tasks-test--fixture
    (let* ((tasks (agent-tasks-ledger-tasks (agent-tasks-read)))
           (first (sort (copy-sequence tasks) #'agent-tasks--task-less-p))
           (second (sort (copy-sequence tasks) #'agent-tasks--task-less-p)))
      (should (equal (mapcar #'agent-tasks-task-id first)
                     (mapcar #'agent-tasks-task-id second))))))

(ert-deftest agent-tasks-test-list/entries-carry-the-task-id ()
  "Every row's id is the task's, so a command acts on the right task."
  (agent-tasks-test--with-ledger agent-tasks-test--fixture
    (let ((entries (agent-tasks--list-entries (agent-tasks-read))))
      (should (= 2 (length entries)))
      (should (member "t-a" (mapcar #'car entries)))
      (should (equal "RUNNING" (aref (cadr (assoc "t-a" entries)) 0))))))

(ert-deftest agent-tasks-test-list/header-reports-counts-and-the-mode ()
  "A list that looks live while nothing observes sessions would mislead."
  (agent-tasks-test--with-ledger
      (concat agent-tasks-test--fixture "* PENDING No id\n")
    (let* ((ledger (agent-tasks-read))
           (agent-tasks-mode nil)
           (line (agent-tasks--header-line
                  ledger (agent-tasks-ledger-problems ledger))))
      (should (string-match-p "2 tasks" line))
      (should (string-match-p "1 problem" line))
      (should (string-match-p "agent-tasks-mode is off" line)))))

(ert-deftest agent-tasks-test-list/header-counts-dependency-problems ()
  "Validation problems reach the header, not just parse problems."
  (agent-tasks-test--with-ledger
      (concat agent-tasks--header
              "* PENDING A\n:PROPERTIES:\n:AGENT_TASK_ID: t-a\n"
              ":DEPENDS: t-missing\n:END:\n")
    (let* ((ledger (agent-tasks-read))
           (problems (append (agent-tasks-ledger-problems ledger)
                             (agent-tasks-validate ledger))))
      (should (string-match-p "1 problem"
                              (agent-tasks--header-line ledger problems))))))

(ert-deftest agent-tasks-test-list/opens-and-renders ()
  "The command produces a populated list buffer."
  (agent-tasks-test--with-ledger agent-tasks-test--fixture
    (let ((agent-tasks--reconciled t))
      (save-window-excursion
        (agent-tasks)
        (with-current-buffer "*Agent tasks*"
          (should (derived-mode-p 'agent-tasks-list-mode))
          (should (string-match-p "Port the reconciliation pass"
                                  (buffer-string)))
          (kill-buffer))))))

(ert-deftest agent-tasks-test-list/shows-account-and-unmet-dependencies ()
  "The row answers which account it runs under and whether it can start."
  (agent-tasks-test--with-ledger
      (concat agent-tasks--header
              "* PENDING Waiting\n:PROPERTIES:\n:AGENT_TASK_ID: t-1\n"
              ":ACCOUNT: personal\n:DEPENDS: t-2 t-3 t-4\n:END:\n"
              "* DONE Satisfied\n:PROPERTIES:\n:AGENT_TASK_ID: t-2\n"
              ":OUTCOME: succeeded\n:END:\n"
              "* PENDING Open\n:PROPERTIES:\n:AGENT_TASK_ID: t-3\n:END:\n"
              "* DONE Failed\n:PROPERTIES:\n:AGENT_TASK_ID: t-4\n"
              ":OUTCOME: failed\n:END:\n")
    (let* ((ledger (agent-tasks-read))
           (row (cadr (assoc "t-1" (agent-tasks--list-entries ledger)))))
      (should (equal "personal" (aref row 3)))
      (should (equal "2/3" (aref row 8)))
      (should (equal "" (aref (cadr (assoc "t-3"
                                           (agent-tasks--list-entries ledger)))
                              8))))))

(ert-deftest agent-tasks-test-list/refresh-always-reconciles ()
  "`g' reconciles every time, not only on the first pass.
A session lost after the first refresh must be noticed by the next
one; routing `g' through the once-per-Emacs guard, as revision 1 did,
meant waiting for an Emacs restart."
  (agent-tasks-test--with-ledger nil
    (agent-tasks-test--with-session buffer
      (let ((agent-tasks--reconciled nil)
            (id (agent-tasks-create :title "Lost later")))
        ;; First refresh: the task is PENDING, nothing to reconcile.
        (save-window-excursion
          (agent-tasks)
          (with-current-buffer "*Agent tasks*"
            (should agent-tasks--reconciled)
            ;; Now the task starts running and its session vanishes
            ;; without teardown running.
            (agent-tasks--update-task
             (agent-tasks-read) id
             (lambda () (agent-tasks--set-state "RUNNING" "setup")))
            (agent-tasks-list-refresh)
            (should (equal "UNKNOWN"
                           (agent-tasks-task-state
                            (agent-tasks-find (agent-tasks-read) id)))))
          (kill-buffer "*Agent tasks*"))))))

(ert-deftest agent-tasks-test-visit-source/is-anchored-and-case-sensitive ()
  "Neither a longer heading nor a case-differing one may be selected.
`case-fold-search' defaults to t, so an unbound search lands on
`* TODO ship' — verified in batch."
  (agent-tasks-test--with-ledger nil
    (let ((source (make-temp-file
                   "agent-tasks-source" nil ".org"
                   "* TODO Ship the second thing\n* TODO ship\n* TODO Ship\n")))
      (unwind-protect
          (let ((id (agent-tasks-create :title "Ship"
                                        :source-file source
                                        :source-heading "* TODO Ship")))
            (save-window-excursion
              (agent-tasks-visit-source id)
              (should (equal "* TODO Ship"
                             (buffer-substring-no-properties
                              (line-beginning-position)
                              (line-end-position))))
              (set-buffer-modified-p nil)
              (kill-buffer)))
        (delete-file source)))))

(ert-deftest agent-tasks-test-list/age-survives-a-missing-stamp ()
  "A task with no timestamps renders an age rather than signalling."
  (agent-tasks-test--with-ledger
      (concat agent-tasks--header
              "* PENDING Bare\n:PROPERTIES:\n:AGENT_TASK_ID: t-g\n:END:\n")
    (should (equal "?" (agent-tasks--age
                        (agent-tasks-find (agent-tasks-read) "t-g"))))))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test`
Expected: every test added in Step 1 fails, with `Symbol's function definition is void:
agent-tasks--task-less-p`.

- [ ] **Step 3: Implement the list**

Add to `agent-tasks.el`:

Add `(require 'tabulated-list)` to the top of the file alongside
`org`, so the derived mode compiles cleanly.

```elisp
;;;; The task list

(defvar agent-tasks--list-filter nil
  "Directory the list is filtered to, or nil for every project.")

(defvar agent-tasks-list-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'agent-tasks-list-show)
    (define-key map (kbd "n") #'agent-tasks-new)
    (define-key map (kbd "d") #'agent-tasks-list-dispatch)
    (define-key map (kbd "s") #'agent-tasks-list-switch)
    (define-key map (kbd "o") #'agent-tasks-list-open-transcript)
    (define-key map (kbd "b") #'agent-tasks-list-block)
    (define-key map (kbd "k") #'agent-tasks-list-done)
    (define-key map (kbd "x") #'agent-tasks-list-cancel)
    (define-key map (kbd "R") #'agent-tasks-list-resume)
    (define-key map (kbd "O") #'agent-tasks-list-reopen)
    (define-key map (kbd "u") #'agent-tasks-list-unbind)
    (define-key map (kbd "c") #'agent-tasks-list-comment)
    (define-key map (kbd "e") #'agent-tasks-list-edit)
    (define-key map (kbd "t") #'agent-tasks-list-visit-source)
    (define-key map (kbd "F") #'agent-tasks-list-filter)
    (define-key map (kbd "g") #'agent-tasks-list-refresh)
    map)
  "Keymap for `agent-tasks-list-mode'.")

(define-derived-mode agent-tasks-list-mode tabulated-list-mode "Agent Tasks"
  "Major mode for the durable task ledger."
  (setq tabulated-list-format
        [("State" 9 nil) ("Task" 30 nil) ("Backend" 11 nil)
         ("Account" 10 nil) ("Project" 14 nil) ("Session" 16 nil)
         ("Att" 4 nil) ("Age" 6 nil) ("Deps" 6 nil)])
  (setq tabulated-list-padding 1)
  ;; The order is computed, not delegated to the column sorter, so it
  ;; is total and the list does not reshuffle between refreshes.
  (setq tabulated-list-sort-key nil)
  (tabulated-list-init-header))

;;;###autoload
(defun agent-tasks ()
  "Show the durable task ledger."
  (interactive)
  (let ((buffer (get-buffer-create "*Agent tasks*")))
    (with-current-buffer buffer
      (agent-tasks-list-mode)
      (agent-tasks-list-refresh))
    (pop-to-buffer buffer)))

(defun agent-tasks-list-refresh ()
  "Re-read and reconcile the ledger, then redraw the list.
Reconciliation runs on **every** refresh, not through the
once-per-Emacs guard: revision 1 routed this through
`agent-tasks--ensure-reconciled', so a session that died after the
first refresh was never noticed until Emacs restarted, which defeats
the point of a refresh key."
  (interactive)
  (let* ((ledger (agent-tasks-reconcile (agent-tasks-read)))
         (problems (append (agent-tasks-ledger-problems ledger)
                           (agent-tasks-validate ledger))))
    (setq tabulated-list-entries (agent-tasks--list-entries ledger problems))
    (setq header-line-format (agent-tasks--header-line ledger problems))
    (tabulated-list-print t)
    (when problems
      (message "Agent tasks: %d problem row%s — see the list"
               (length problems) (if (= 1 (length problems)) "" "s")))))

(defun agent-tasks--list-entries (ledger &optional problems)
  "Return `tabulated-list-entries' for LEDGER, PROBLEMS included.
PROBLEMS defaults to LEDGER's parse problems plus its validation
problems; the caller passes them in so the header line and the rows
report the same list rather than each computing its own."
  (let ((problems (or problems
                      (append (agent-tasks-ledger-problems ledger)
                              (agent-tasks-validate ledger))))
        (tasks (sort (cl-remove-if-not
                      #'agent-tasks--passes-filter-p
                      (copy-sequence (agent-tasks-ledger-tasks ledger)))
                     #'agent-tasks--task-less-p)))
    (append
     (mapcar
      (lambda (task)
        (list (agent-tasks-task-id task)
              (vector (agent-tasks-task-state task)
                      (agent-tasks-task-title task)
                      (or (agent-tasks-task-backend task) "")
                      (or (agent-tasks-task-account task) "")
                      (or (agent-tasks--project-name task) "")
                      (agent-tasks--session-label task)
                      (number-to-string (agent-tasks-task-attempt task))
                      (agent-tasks--age task)
                      (agent-tasks--dependency-cell ledger task))))
      tasks)
     (mapcar
      (lambda (problem)
        (list (agent-tasks-problem-heading problem)
              (vector "PROBLEM"
                      (agent-tasks-problem-heading problem)
                      "" "" "" (agent-tasks-problem-issue problem)
                      "" "" "")))
      problems))))

(defun agent-tasks--dependency-cell (ledger task)
  "Return TASK's dependency cell: unsatisfied over total, or empty.
A bare total answers neither question the column exists for — which
account is this under, and is this one actually startable."
  (let ((total (length (agent-tasks-task-depends task))))
    (if (zerop total)
        ""
      (format "%d/%d"
              (length (agent-tasks-unsatisfied-dependencies ledger task))
              total))))

(defun agent-tasks--passes-filter-p (task)
  "Return non-nil when TASK passes the current project filter."
  (or (null agent-tasks--list-filter)
      (equal agent-tasks--list-filter (agent-tasks-task-directory task))))

(defun agent-tasks--task-less-p (a b)
  "Return non-nil when task A sorts before task B.
Open states first in `agent-tasks--open-states' order, then newer
first, then by id.  The order is total, so the list does not reshuffle
between refreshes."
  (let ((rank-a (agent-tasks--state-rank a))
        (rank-b (agent-tasks--state-rank b))
        (created-a (or (agent-tasks-task-created a) ""))
        (created-b (or (agent-tasks-task-created b) "")))
    (cond
     ((/= rank-a rank-b) (< rank-a rank-b))
     ((not (equal created-a created-b)) (string> created-a created-b))
     (t (string< (agent-tasks-task-id a) (agent-tasks-task-id b))))))

(defun agent-tasks--state-rank (task)
  "Return TASK's sort rank: open states first, then closed."
  (or (cl-position (agent-tasks-task-state task)
                   (append agent-tasks--open-states
                           agent-tasks--closed-states)
                   :test #'equal)
      99))

(defun agent-tasks--project-name (task)
  "Return the last component of TASK's directory, or nil."
  (when-let* ((directory (agent-tasks-task-directory task)))
    (file-name-nondirectory (directory-file-name directory))))

(defun agent-tasks--session-label (task)
  "Return a label for TASK's session: the live name, or what was recorded."
  (if-let* ((buffer (agent-tasks-task-buffer (agent-tasks-task-id task))))
      (agent-display-name buffer)
    (or (agent-tasks-task-session-id task)
        (agent-tasks-task-instance task)
        "")))

(defun agent-tasks--age (task)
  "Return a short age string for TASK's most recent timestamp."
  (let ((stamp (or (agent-tasks-task-updated task)
                   (agent-tasks-task-created task))))
    (if (null stamp)
        "?"
      (condition-case nil
          (let ((seconds (- (float-time) (org-time-string-to-seconds stamp))))
            (cond ((< seconds 3600) (format "%dm" (/ seconds 60)))
                  ((< seconds 86400) (format "%dh" (/ seconds 3600)))
                  (t (format "%dd" (/ seconds 86400)))))
        (error "?")))))

(defun agent-tasks--header-line (ledger problems)
  "Return the list's header line for LEDGER and its PROBLEMS."
  (format "%d task%s, %d problem%s from %s%s%s"
          (length (agent-tasks-ledger-tasks ledger))
          (if (= 1 (length (agent-tasks-ledger-tasks ledger))) "" "s")
          (length problems)
          (if (= 1 (length problems)) "" "s")
          (abbreviate-file-name (agent-tasks-ledger-file ledger))
          (if agent-tasks--list-filter
              (format " — filtered to %s" agent-tasks--list-filter)
            "")
          (if agent-tasks-mode
              ""
            " — agent-tasks-mode is off, so nothing is observing sessions")))

;;;; List commands

(defun agent-tasks--list-id ()
  "Return the task id on the current list line, or signal."
  (let ((id (tabulated-list-get-id)))
    (unless (and id (agent-tasks-find (agent-tasks-read) id))
      (user-error "No task on this line"))
    id))

(defun agent-tasks-list-show ()
  "Show the full record of the task on this line."
  (interactive)
  (let* ((id (agent-tasks--list-id))
         (task (agent-tasks-find (agent-tasks-read) id))
         (buffer (get-buffer-create "*Agent task*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (agent-tasks--describe task)))
      (special-mode)
      (goto-char (point-min)))
    (pop-to-buffer buffer)))

(defun agent-tasks--describe (task)
  "Return a readable rendering of TASK."
  (string-join
   (delq nil
         (list
          (format "%s  %s" (agent-tasks-task-state task)
                  (agent-tasks-task-title task))
          (format "id:         %s" (agent-tasks-task-id task))
          (format "attempt:    %d" (agent-tasks-task-attempt task))
          (format "created:    %s" (or (agent-tasks-task-created task) "?"))
          (format "updated:    %s" (or (agent-tasks-task-updated task) "?"))
          (format "backend:    %s" (or (agent-tasks-task-backend task) "-"))
          (format "account:    %s" (or (agent-tasks-task-account task) "-"))
          (format "directory:  %s" (or (agent-tasks-task-directory task) "-"))
          (format "repository: %s" (or (agent-tasks-task-repository task) "-"))
          (format "instance:   %s" (or (agent-tasks-task-instance task) "-"))
          (format "session id: %s" (or (agent-tasks-task-session-id task) "-"))
          (format "bound to:   %s"
                  (if-let* ((buffer (agent-tasks-task-buffer
                                     (agent-tasks-task-id task))))
                      (agent-display-name buffer)
                    "no live session"))
          (when (agent-tasks-task-depends task)
            (format "depends on: %s"
                    (string-join (agent-tasks-task-depends task) " ")))
          (when (agent-tasks-task-blocked-reason task)
            (format "blocked:    %s" (agent-tasks-task-blocked-reason task)))
          (when (agent-tasks-task-outcome task)
            (format "outcome:    %s" (agent-tasks-task-outcome task)))
          (when (agent-tasks-task-source-file task)
            (format "source:     %s  %s"
                    (agent-tasks-task-source-file task)
                    (or (agent-tasks-task-source-heading task) "")))
          ""
          "Instruction:"
          (or (agent-tasks-task-instruction task) "(none)")
          (when (agent-tasks-task-result task)
            (concat "\nResult:\n" (agent-tasks-task-result task)))
          (when (agent-tasks-task-evidence task)
            (concat "\nEvidence:\n" (agent-tasks-task-evidence task)))
          (when (agent-tasks-task-comments task)
            (concat "\nComments:\n" (agent-tasks-task-comments task)))
          (when (agent-tasks-task-log task)
            (concat "\nLog:\n" (agent-tasks-task-log task)))))
   "\n"))

(defmacro agent-tasks--define-list-command (name arglist docstring &rest body)
  "Define list command NAME with ARGLIST, DOCSTRING and BODY.
BODY runs with `id' bound to the task on the current line, and the
list is refreshed afterwards."
  (declare (indent 3) (doc-string 3))
  `(defun ,name ,arglist
     ,docstring
     (interactive)
     (let ((id (agent-tasks--list-id)))
       (ignore id)
       ,@body
       (agent-tasks-list-refresh))))

(agent-tasks--define-list-command agent-tasks-list-dispatch ()
  "Dispatch the task on this line."
  (agent-tasks-dispatch id current-prefix-arg))

(agent-tasks--define-list-command agent-tasks-list-block ()
  "Mark the task on this line blocked."
  (agent-tasks-mark-blocked id (agent-tasks--read-reason "Reason for blocking: ")))

(agent-tasks--define-list-command agent-tasks-list-done ()
  "Close the task on this line."
  (agent-tasks-mark-done
   id
   (completing-read "Outcome: " '("succeeded" "failed") nil t)
   (read-string "Result (optional): ")
   (read-string "Verification evidence (optional): ")))

(agent-tasks--define-list-command agent-tasks-list-cancel ()
  "Cancel the task on this line."
  (agent-tasks-cancel id (agent-tasks--read-reason "Reason for cancelling: ")))

(agent-tasks--define-list-command agent-tasks-list-reopen ()
  "Reopen the closed task on this line."
  (agent-tasks-reopen id))

(agent-tasks--define-list-command agent-tasks-list-comment ()
  "Add a comment to the task on this line."
  (agent-tasks-add-comment id (read-string "Comment: ")))

(agent-tasks--define-list-command agent-tasks-list-resume ()
  "Resume the task on this line."
  (agent-tasks-resume
   id
   (cdr (assoc (completing-read "Action: "
                                (mapcar #'car agent-tasks--resume-actions)
                                nil t)
               agent-tasks--resume-actions))))

(agent-tasks--define-list-command agent-tasks-list-unbind ()
  "Detach the task on this line from its session."
  (if-let* ((buffer (agent-tasks-task-buffer id)))
      (agent-tasks-unbind buffer)
    (user-error "Task %s has no live session" id)))

(defun agent-tasks-list-switch ()
  "Switch to the session bound to the task on this line."
  (interactive)
  (let* ((id (agent-tasks--list-id))
         (buffer (agent-tasks-task-buffer id)))
    (unless buffer
      (user-error "Task %s has no live session" id))
    (pop-to-buffer buffer)))

(defun agent-tasks-list-edit ()
  "Open the ledger file at the task on this line."
  (interactive)
  (agent-tasks-edit (agent-tasks--list-id)))

(defun agent-tasks-list-open-transcript ()
  "Open the transcript of the session that ran the task on this line."
  (interactive)
  (agent-tasks-open-transcript (agent-tasks--list-id)))

(defun agent-tasks-list-visit-source ()
  "Visit the Org TODO the task on this line was imported from."
  (interactive)
  (agent-tasks-visit-source (agent-tasks--list-id)))

(defun agent-tasks-list-filter ()
  "Filter the list to one project directory, or clear the filter."
  (interactive)
  (let* ((directories (delete-dups
                       (delq nil
                             (mapcar #'agent-tasks-task-directory
                                     (agent-tasks-ledger-tasks
                                      (agent-tasks-read))))))
         (choice (completing-read "Project (empty for all): "
                                  directories nil t)))
    (setq agent-tasks--list-filter
          (unless (string-empty-p choice) choice)))
  (agent-tasks-list-refresh))

;;;###autoload
(defun agent-tasks-visit-source (id)
  "Visit the Org TODO that task ID was imported from.
Defined here rather than with the import commands so that Task 10
byte-compiles cleanly: `agent-tasks-list-visit-source' calls it, and a
forward reference inside one file warns.

The heading is matched as a **whole line**.  An unanchored search finds
`* TODO Ship' inside `* TODO Ship the second thing' and sends the
person to the wrong heading."
  (interactive
   (list (agent-tasks--read-task-id (agent-tasks-read) "Source of task: ")))
  (let* ((task (or (agent-tasks-find (agent-tasks-read) id)
                   (user-error "No task with id %s" id)))
         (file (or (agent-tasks-task-source-file task)
                   (user-error "Task %s was not imported from a file" id)))
         (heading (agent-tasks-task-source-heading task)))
    (unless (file-readable-p file)
      (user-error "Source file is gone: %s" file))
    (find-file file)
    (goto-char (point-min))
    ;; `case-fold-search' defaults to t, so an unbound search matches
    ;; `* TODO ship' for `* TODO Ship' — verified in batch.
    (if (and heading
             (let ((case-fold-search nil))
               (re-search-forward
                (concat "^" (regexp-quote heading) "[ \t]*$") nil t)))
        (beginning-of-line)
      (message "The source heading is no longer in %s; showing the file"
               (abbreviate-file-name file)))))

;;;###autoload
(defun agent-tasks-open-transcript (id)
  "Open the durable transcript of the session that ran task ID.
Delegates to the optional Agent Log package, the same way
`agent-history' does; loading `agent-tasks' never requires it."
  (interactive
   (list (agent-tasks--read-task-id (agent-tasks-read) "Transcript for task: ")))
  (let* ((task (or (agent-tasks-find (agent-tasks-read) id)
                   (user-error "No task with id %s" id)))
         (session-id (or (agent-tasks-task-session-id task)
                         (user-error "Task %s has no recorded session id" id))))
    (unless (require 'agent-log nil t)
      (user-error "Package `agent-log' is required to open a transcript"))
    (agent-log-open-session session-id)))
```

Add the forward declaration next to the others:

```elisp
(declare-function agent-log-open-session "agent-log" (session-id))
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test`
Expected: `0 unexpected`, and the total rises by exactly the number of `ert-deftest` forms this task adds (count them in the diff).

- [ ] **Step 5: Byte-compile and commit**

```bash
make compile
git add agent-tasks.el test/agent-tasks-test.el
git commit -m "feat(tasks): add the task list and its commands"
```

---

### Task 11: Importing Org TODOs and the chief context function

**Files:**
- Modify: `agent-tasks.el` (new "Importing Org TODOs" and "Chief
  context" sections; one new defcustom)
- Test: `test/agent-tasks-test.el`

**Interfaces:**
- Consumes: Tasks 3 and 10.
- Produces (used by Tasks 12, 13, 14):
  - `agent-tasks-chief-context-max` (defcustom, default 20).
  - `agent-tasks-import-org-todos` — autoloaded command.
  - `agent-tasks-capture-org-todo` — autoloaded command for the TODO at
    point.
  - `agent-tasks-chief-context` → a string or nil.
  - `agent-tasks--collect-org-todos SCOPE`,
    `agent-tasks--org-entry-body`,
    `agent-tasks--imported-headings LEDGER SOURCE`.

- [ ] **Step 1: Write the failing tests**

Add to `test/agent-tasks-test.el`:

```elisp
;;;; Importing Org TODOs

(defmacro agent-tasks-test--with-org-source (text &rest body)
  "Run BODY in an Org buffer visiting a temp file holding TEXT.
Binds `source' to the file name."
  (declare (indent 1) (debug (form body)))
  `(let ((source (make-temp-file "agent-tasks-source" nil ".org" ,text)))
     (unwind-protect
         (let ((buffer (find-file-noselect source)))
           (unwind-protect
               (with-current-buffer buffer ,@body)
             (with-current-buffer buffer (set-buffer-modified-p nil))
             (kill-buffer buffer)))
       (delete-file source))))

(ert-deftest agent-tasks-test-import/creates-one-task-per-todo ()
  "Every unfinished TODO in the buffer becomes a PENDING task."
  (agent-tasks-test--with-ledger nil
    (agent-tasks-test--with-org-source
        "* TODO First\nbody one\n* DONE Second\n* TODO Third\n"
      (should (= 2 (agent-tasks-import-org-todos)))
      (let ((tasks (agent-tasks-ledger-tasks (agent-tasks-read))))
        (should (equal '("First" "Third")
                       (mapcar #'agent-tasks-task-title tasks)))
        (should (equal "body one"
                       (agent-tasks-task-instruction (car tasks))))
        (should (equal "* TODO First"
                       (agent-tasks-task-source-heading (car tasks))))
        (should (equal source (agent-tasks-task-source-file (car tasks))))
        (should (cl-every (lambda (task)
                            (equal "PENDING" (agent-tasks-task-state task)))
                          tasks))))))

(ert-deftest agent-tasks-test-import/skips-what-it-already-imported ()
  "A second import of the same file adds nothing and says so."
  (agent-tasks-test--with-ledger nil
    (agent-tasks-test--with-org-source "* TODO First\n* TODO Second\n"
      (should (= 2 (agent-tasks-import-org-todos)))
      (should (= 0 (agent-tasks-import-org-todos)))
      (should (= 2 (length (agent-tasks-ledger-tasks (agent-tasks-read))))))))

(ert-deftest agent-tasks-test-import/honours-a-narrowed-buffer ()
  "A narrowed buffer imports the subtree, as the batch runner does."
  (agent-tasks-test--with-ledger nil
    (agent-tasks-test--with-org-source
        "* TODO Outside\n* TODO Parent\n** TODO Inside\n"
      (goto-char (point-min))
      (re-search-forward "^\\* TODO Parent")
      (org-narrow-to-subtree)
      (should (= 2 (agent-tasks-import-org-todos)))
      (widen)
      (should (equal '("Parent" "Inside")
                     (mapcar #'agent-tasks-task-title
                             (agent-tasks-ledger-tasks
                              (agent-tasks-read))))))))

(ert-deftest agent-tasks-test-import/refuses-a-non-org-buffer ()
  "Import runs in Org buffers only."
  (agent-tasks-test--with-ledger nil
    (with-temp-buffer
      (fundamental-mode)
      (should-error (agent-tasks-import-org-todos) :type 'user-error))))

(ert-deftest agent-tasks-test-import/refuses-when-nothing-is-unfinished ()
  "A file of DONE headings is a clear refusal, not an empty success."
  (agent-tasks-test--with-ledger nil
    (agent-tasks-test--with-org-source "* DONE Only\n"
      (should-error (agent-tasks-import-org-todos) :type 'user-error))))

;;;; Chief context

(ert-deftest agent-tasks-test-chief-context/lists-open-tasks-only ()
  "Closed tasks are not open work."
  (agent-tasks-test--with-ledger
      (concat agent-tasks--header
              "* PENDING Open one\n:PROPERTIES:\n:AGENT_TASK_ID: t-1\n"
              ":DIRECTORY: ~/repos/thing/\n:END:\n"
              "* DONE Closed\n:PROPERTIES:\n:AGENT_TASK_ID: t-2\n"
              ":OUTCOME: succeeded\n:END:\n")
    (let ((context (agent-tasks-chief-context)))
      (should (string-match-p "Open one" context))
      (should (string-match-p "thing" context))
      ;; Age is part of the contract, not decoration.
      (should (string-match-p "old\\]" context))
      (should-not (string-match-p "Closed" context)))))

(ert-deftest agent-tasks-test-chief-context/caps-and-says-so ()
  "A bounded view never reads as a complete one."
  (agent-tasks-test--with-ledger nil
    (dotimes (index 5)
      (agent-tasks-create :title (format "Task %d" index)))
    (let* ((agent-tasks-chief-context-max 2)
           (context (agent-tasks-chief-context)))
      (should (string-match-p "and 3 more open tasks" context)))))

(ert-deftest agent-tasks-test-chief-context/empty-ledger-is-nil ()
  "An empty ledger contributes nothing rather than an empty heading."
  (agent-tasks-test--with-ledger nil
    (should (null (agent-tasks-chief-context)))))

(ert-deftest agent-tasks-test-chief-context/writes-nothing ()
  "The chief context function is read-only."
  (agent-tasks-test--with-ledger agent-tasks-test--fixture
    (let ((before (agent-tasks--file-text agent-tasks-file)))
      (agent-tasks-chief-context)
      (should (equal before (agent-tasks--file-text agent-tasks-file))))))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test`
Expected: every test added in Step 1 fails, with `Symbol's function definition is void:
agent-tasks-import-org-todos`.

- [ ] **Step 3: Implement import and the chief context function**

Add the defcustom next to `agent-tasks-file`:

```elisp
(defcustom agent-tasks-chief-context-max 20
  "Maximum number of open tasks `agent-tasks-chief-context' lists."
  :type 'integer
  :group 'agent-tasks)
```

Add the two sections:

```elisp
;;;; Importing Org TODOs

;;;###autoload
(defun agent-tasks-import-org-todos ()
  "Create a PENDING ledger task for each unfinished Org TODO in scope.
The scope is inferred the way `agent-claude-batch-todos' infers it:
the region when one is active, the subtree when the buffer is
narrowed, the whole buffer otherwise.  Headings already imported from
this file are skipped and counted.  Return the number created.

`agent-claude-batch-todos' is deliberately left alone: it is a batch
runner over `claude -p', which is a different operation from
recording durable work, and coupling this optional module to a
backend-specific one to save eight lines of collection code would buy
nothing."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Import runs in an Org buffer"))
  (let* ((scope (cond ((use-region-p) 'region)
                      ((buffer-narrowed-p) 'subtree)
                      (t 'buffer)))
         (entries (agent-tasks--collect-org-todos scope))
         (source (buffer-file-name))
         (known (agent-tasks--imported-headings (agent-tasks-read) source))
         (directory (if source
                        (file-name-directory source)
                      default-directory))
         (created 0)
         (skipped 0))
    (unless entries
      (user-error "No unfinished TODO entries in the %s" scope))
    (dolist (entry entries)
      (if (member (plist-get entry :heading) known)
          (cl-incf skipped)
        (agent-tasks-create
         :title (plist-get entry :title)
         :instruction (plist-get entry :body)
         :directory directory
         :source-file source
         :source-heading (plist-get entry :heading))
        (cl-incf created)))
    (message "Imported %d task%s from the %s; skipped %d already imported"
             created (if (= created 1) "" "s") scope skipped)
    created))

;;;###autoload
(defun agent-tasks-capture-org-todo ()
  "Create a ledger task from the Org TODO at point."
  (interactive)
  (unless (derived-mode-p 'org-mode)
    (user-error "Capture runs in an Org buffer"))
  (unless (org-get-todo-state)
    (user-error "Point is not on a TODO heading"))
  (save-restriction
    (org-narrow-to-subtree)
    (agent-tasks-import-org-todos)))

(defun agent-tasks--collect-org-todos (scope)
  "Return unfinished Org TODO entries in SCOPE as plists.
Each has `:title', `:body', and `:heading' — the literal heading line,
which is the only key that still finds the entry after a person edits
its wording, exactly as the learning inbox records literal headings."
  (let (entries)
    (org-map-entries
     (lambda ()
       (when (and (org-get-todo-state) (not (org-entry-is-done-p)))
         (push (list :title (org-get-heading t t t t)
                     ;; Raw, not collapsed: this is the key the anchored
                     ;; source lookup matches as a whole line, and a
                     ;; heading with two spaces between words must stay
                     ;; findable.  A heading line cannot contain a
                     ;; newline, so it is always a legal property value.
                     :heading (string-trim-right
                               (buffer-substring-no-properties
                                (line-beginning-position)
                                (line-end-position)))
                     :body (agent-tasks--org-entry-body))
               entries)))
     nil
     (pcase scope
       ('buffer nil)
       ('subtree 'tree)
       ('region 'region)))
    (nreverse entries)))

(defun agent-tasks--org-entry-body ()
  "Return the trimmed body of the Org entry at point."
  (save-excursion
    (let ((start (progn (org-end-of-meta-data t) (point)))
          (end (progn (outline-next-heading) (or (point) (point-max)))))
      (string-trim (buffer-substring-no-properties start end)))))

(defun agent-tasks--imported-headings (ledger source)
  "Return the heading lines already imported from SOURCE into LEDGER."
  (delq nil
        (mapcar (lambda (task)
                  (when (equal (agent-tasks-task-source-file task) source)
                    (agent-tasks-task-source-heading task)))
                (agent-tasks-ledger-tasks ledger))))

;;;; Chief context

;;;###autoload
(defun agent-tasks-chief-context ()
  "Return a compact summary of open ledger tasks, or nil when there are none.
Suitable for `agent-chief-context-functions'.  Deterministic, writes
nothing, and starts nothing.  Adding it to that hook is the person's
choice; nothing in this package adds it, and `agent-chief.el' is not
modified."
  (let* ((ledger (agent-tasks-read))
         (open (cl-remove-if-not
                (lambda (task)
                  (member (agent-tasks-task-state task)
                          agent-tasks--open-states))
                (agent-tasks-ledger-tasks ledger)))
         (sorted (sort (copy-sequence open) #'agent-tasks--task-less-p))
         (shown (seq-take sorted agent-tasks-chief-context-max))
         (extra (- (length sorted) (length shown))))
    (when shown
      (string-join
       (append
        (list "Open agent tasks (from Pablo's Emacs task ledger; these states are recorded, not inferred):")
        ;; Age is required, not decorative: the chief's whole job is to
        ;; notice drift, and "BLOCKED for six hours" is the observation
        ;; it exists to make.
        (mapcar (lambda (task)
                  (format "- %s %s [%s, %s old]"
                          (agent-tasks-task-state task)
                          (agent-tasks-task-title task)
                          (or (agent-tasks--project-name task) "no project")
                          (agent-tasks--age task)))
                shown)
        (when (> extra 0)
          (list (format "- and %d more open task%s"
                        extra (if (= extra 1) "" "s")))))
       "\n"))))
```

Add `(require 'seq)` to the top of the file alongside `subr-x`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test`
Expected: `0 unexpected`, and the total rises by exactly the number of `ert-deftest` forms this task adds (count them in the diff).

- [ ] **Step 5: Byte-compile and commit**

```bash
make compile
git add agent-tasks.el test/agent-tasks-test.el
git commit -m "feat(tasks): import Org TODOs and expose a chief context function"
```

---

### Task 12: Menu entries, autoloads, and the build

**Files:**
- Modify: `agent.el` (`agent-menu` ~line 2676 and the autoload block)
- Modify: `Makefile` (verification only; the lines were added in Task 1)
- Test: `test/agent-test.el`

**Interfaces:**
- Consumes: Tasks 3 and 10's autoloaded commands.
- Produces: `agent-menu` entries `j` (`agent-tasks`) and `J`
  (`agent-tasks-new`).

- [ ] **Step 0: Confirm the menu walker exists**

```bash
grep -n "agent-test--menu-bindings" test/agent-test.el | head -2
```

Expected: the helper from the skill-bundles plan's Task 14.  **If this
prints nothing, stop**: the landing order was not honoured, and a test
that walks only the declared layout cannot see the generated backend
columns where `b` and `u` already live.  Do not write a second walker.

- [ ] **Step 1: Write the failing tests**

Append to `test/agent-test.el`:

```elisp
(ert-deftest agent-test-menu-binds-the-task-ledger-keys ()
  "Assert the exact key each ledger command is bound to.
The mnemonic letters were all taken before this feature existed, so
`j' and `J' were chosen because they were free; asserting the exact
pair is what stops a later change from quietly moving them."
  (let ((bindings (agent-test--menu-bindings)))
    (should (equal 'agent-tasks (cdr (assoc "j" bindings))))
    (should (equal 'agent-tasks-new (cdr (assoc "J" bindings))))))

(ert-deftest agent-test-menu-keeps-the-neighbouring-tools-entries ()
  "The ledger entries are inserted, not swapped in for something else."
  (let ((bindings (agent-test--menu-bindings)))
    (should (equal 'agent-run-skill (cdr (assoc "s" bindings))))
    (should (equal 'agent-trajectory-new-task (cdr (assoc "n" bindings))))
    (should (equal 'agent-audit-project (cdr (assoc "a" bindings))))))
```

`agent-test-menu-keys-are-unique`, added by the skill-bundles plan,
already covers the collision case and will now also cover `j` and `J`.
Do not duplicate it.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test`
Expected: `agent-test-menu-binds-the-task-ledger-keys` fails, with
both assertions returning nil.

- [ ] **Step 3: Add the autoloads and the menu entries**

Add to `agent.el`'s split-module autoload block:

```elisp
(autoload 'agent-tasks "agent-tasks" nil t)
(autoload 'agent-tasks-new "agent-tasks" nil t)
```

Insert two lines into the Tools column of `agent-menu`, after
`("s" "run skill" agent-run-skill)`:

```elisp
    ("j" "task ledger" agent-tasks)
    ("J" "new task" agent-tasks-new)
```

Insert lines; do not retype the column.  The composer and skill-bundles
plans insert into the same column, and retyping it would drop whichever
of their entries landed first.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test`
Expected: `0 unexpected`, and the total rises by exactly the number of `ert-deftest` forms this task adds (count them in the diff).

- [ ] **Step 5: Verify the build lists**

```bash
git diff --stat Makefile
grep -c '^SRC += agent-tasks\.el$' Makefile
grep -c '^TEST_FILES += test/agent-tasks-test\.el$' Makefile
```

Expected: `1` from each.  Two separate anchored checks, not one loose
`grep -c 'agent-tasks.el'`: that returns **1**, not the 2 revision 1
expected, because `test/agent-tasks-test.el` does not contain the
literal `agent-tasks.el` — verified against the planned Makefile lines.

Then assert that every module and test file in the repository is named
in the build, which is what catches a list that a later plan replaced:

```bash
for f in *.el; do grep -q "$f" Makefile || echo "NOT IN SRC: $f"; done
for f in test/*.el; do grep -q "$(basename "$f")" Makefile || echo "NOT IN TEST_FILES: $f"; done
```

Expected: at most `NOT IN SRC: agent-forge.el`, which predates all
these plans and is out of scope here.  Anything else — in particular
`agent-attention.el`, `agent-queue.el`, `agent-context.el`,
`agent-skill.el`, or `agent-learn.el` — means a Makefile list was
replaced after those plans landed.  Fix the Makefile before continuing.

- [ ] **Step 6: Byte-compile and commit**

```bash
make compile
git add agent.el test/agent-test.el
git commit -m "feat(tasks): add the task ledger to the agent menu"
```

---

### Task 13: Manual

**Files:**
- Modify: `README.org`
- Modify: `agent.texi` (regenerated export)
- Test: none (documentation)

**Interfaces:**
- Consumes: everything above.
- Produces: a "Task ledger" section.

- [ ] **Step 1: Find where the section goes**

```bash
grep -n "^\*\* " README.org | head -40
```

Place "Task ledger" after the attention/queue and composer sections
that landed before this plan, and before any appendix or
troubleshooting section.

- [ ] **Step 2: Write the section**

Add to `README.org`, adapting the heading level to its neighbours:

```org
** Task ledger

=agent-tasks.el= is a small durable ledger of work you have asked an
agent to do.  The ledger owns task state; Claude Code and Codex do the
work.  Loading the module installs nothing; =M-x agent-tasks= opens the
list, and =agent-menu= reaches it with =j= (=J= files a new task).

*** What it does not do

It is a ledger, not a worker runtime.  Nothing in it starts work by
itself, retries work by itself, or decides that work finished:

- Every transition into =RUNNING= comes from a command you ran.
- A run that ended ambiguously becomes =UNKNOWN= with a recorded
  reason and stays there until you decide what to do.  It is never
  retried automatically.
- *A finished turn is not a finished task.*  When the bound session
  stops talking, the ledger writes a log line and leaves the state
  alone.  Only you close a task.  This makes =RUNNING= sticky, which
  is the point: a board that reports finished work nobody checked is
  worse than one that makes you check.

Dependencies gate a dispatch you initiate and do nothing else.  There
is no scheduler; nothing starts when a dependency clears.

*** The file

One Org file, =agent-tasks-file=, default
=~/.emacs.d/agent/tasks.org=, covering every project.  It declares its
own keywords, so it reads correctly anywhere with no configuration:

#+begin_example
#+TODO: PENDING RUNNING BLOCKED UNKNOWN | DONE CANCELLED
#+end_example

Each task is a level-1 heading.  The heading's keyword is the single
authority for its state — there is no =:STATE:= property, because two
places holding one fact is how they come to disagree.  Properties hold
the scalar fields (id, timestamps, backend, account, directory,
repository, instance, native session id, attempt, dependencies, blocked
reason, outcome, and the source of an imported TODO).  The body holds
the instruction.  Four fixed sub-headings hold =Result=, =Evidence=,
=Comments=, and =Log=.

Everything except =Log= is parsed and round-tripped.  =Log= is
append-only prose: the ledger writes it and never reads it back for a
decision, which is why the transition and attempt history can be
complete and legible without being a second source of truth.

You can edit the file by hand.  A heading the ledger cannot read — no
id, an unrecognised keyword, a duplicate id — becomes a *problem row*
in the list, named and explained, and is never dispatched and never
rewritten.

Every write refuses when a buffer is visiting the file with unsaved
changes, refuses when the file changed on disk since the list was read
(press =g= and retry), and replaces the file atomically, keeping its
original line endings.

*** The six states

| =PENDING=   | recorded, never dispatched                             |
| =RUNNING=   | dispatched into a bound session, no outcome recorded   |
| =BLOCKED=   | the session needs you, or you marked it blocked        |
| =UNKNOWN=   | the run ended ambiguously                              |
| =DONE=      | closed by you, with outcome =succeeded= or =failed=    |
| =CANCELLED= | closed by you without being run to an outcome          |

=CANCELLED= exists so that abandoning work does not have to be
recorded as finishing it.

*** Bindings and what they prove

A task is bound to a session only when the identity is proven: either
the ledger started that session, or you picked it.  One session holds
at most one task; a second is refused, because two tasks in one session
would make every later event ambiguous.

The binding is held twice.  In memory, buffer to task — this dies with
Emacs, correctly, because a buffer reference means nothing afterwards.
On disk, the backend, account, directory, instance, and native session
id — which is what survives, and what lets =o= open the run's
transcript through Agent Log.

*** Dispatching

=d= in the list.  In order: the dependency gate, the target (an
existing session or a new one), a readiness check, the message preview,
then the ledger write, then the send.  The order of the last two is
deliberate:

- A ledger that cannot record the run stops it, rather than starting
  untracked work.
- A send that does not complete moves the task to =UNKNOWN=, never back
  to =PENDING=: text may have reached the CLI before the failure, and
  =PENDING= would invite a second send of work that may already be
  running.
- If Emacs dies between the two, the task is =RUNNING= on disk with no
  live session, which is exactly what reconciliation turns into
  =UNKNOWN=.

A session that cannot take a turn is refused by name.  The ledger never
queues on your behalf; queue text by hand with =agent-queue-prompt= if
that is what you want.  An unknown state asks before proceeding, and a
target that changed state between the question and the send is refused.

Two more refusals protect an existing session:

- *Unsent input.*  Before submitting, the ledger asks the backend
  whether the session's prompt is clean, and refuses unless the answer
  is a definite yes.  Half-typed text you left in a prompt is never
  swallowed into a task's turn, and a transport that cannot be
  inspected refuses too — "cannot verify" is not "clean".
- *A task already bound elsewhere.*  A fresh attempt never steals a
  binding.  Unbind it with =u=, or attach it deliberately with =R=.

The message goes out through the backend's literal submitter, so it is
one isolated turn rather than text appended to the prompt.  A backend
that offers no literal submitter cannot receive a task dispatch into an
existing session; dispatch into a new one instead.

The dispatched message is the task's instruction plus a footer telling
the model that Emacs records the state and will not infer completion.
=Result= and =Evidence= are never sent: they are your record of an
outcome, not input to a run.  What the next attempt should know goes in
the instruction, which you edit with =e=.

*** After a crash

Two mechanisms cover the two ways a run ends without an outcome.

When Emacs is alive and the session buffer is torn down, the bound task
becomes =UNKNOWN= with a reason, and an attention item is filed.
=agent-restart= is the exception: the binding follows the restart when
the resumed native session id is the one it was detached from, and
otherwise the task becomes =UNKNOWN=.

When Emacs died, no teardown ran, so opening the list reconciles: every
task recorded =RUNNING= or =BLOCKED= with no live binding is checked
against the live sessions.  It is re-bound only when a session proves
the recorded identity *including the native session id* — matching on
project and instance alone would happily re-bind the task to a
different session running in the same directory.  Everything else
becomes =UNKNOWN=, once, with a logged reason and a summary line.
Reconciliation never produces =RUNNING= from =UNKNOWN= and never
re-dispatches.

*** Keys

| =RET= | show the full record        | =b= | mark blocked      |
| =n=   | new task                    | =k= | mark done         |
| =d=   | dispatch                    | =x= | cancel            |
| =s=   | switch to the session       | =R= | resume            |
| =o=   | open the transcript         | =O= | reopen            |
| =u=   | unbind from its session     | =c= | add a comment     |
| =e=   | edit in the ledger file     | =t= | visit the source TODO |
| =F=   | filter by project           | =g= | refresh           |

=R= offers exactly three things: dispatch a fresh attempt, attach to a
session you pick (sending nothing), or unbind and leave it pending.
There is no automatic option.

*** agent-tasks-mode

The global minor mode owns every hook the ledger installs: the session
event consumer, the native-session-id consumer, and the restart hooks.
With it off the list, the detail view, and manual state changes all
work, but *dispatch refuses*, because a dispatch with nothing watching
the session would produce a =RUNNING= task that no evidence could ever
move.  The list's header line says when the mode is off.

*** Importing Org TODOs

=agent-tasks-import-org-todos= creates one =PENDING= task per
unfinished TODO in the region, the narrowed subtree, or the buffer —
the same scope rule =agent-claude-batch-todos= uses — recording the
file and the literal heading line so =t= can jump back.  Re-importing
skips headings already imported and says how many.

=agent-claude-batch-todos= is unchanged.  It is a batch runner over
=claude -p=, which is a different operation from recording durable
work; the ledger offers a seam, not a replacement.

*** Chief of staff

=agent-tasks-chief-context= returns a compact summary of open tasks,
suitable for =agent-chief-context-functions=.  It is read-only and
starts nothing.  Adding it is your choice:

#+begin_src emacs-lisp
(add-hook 'agent-chief-context-functions #'agent-tasks-chief-context)
#+end_src

*** Attention items

The ledger files an attention item for exactly one thing: a task that
became =UNKNOWN= while its session buffer still existed.  Blocked
sessions, session errors, and completed turns already produce their own
items from =agent-attention-mode=; a second one would be noise about
the same fact.  Without that module, the fallback is a message.
```

- [ ] **Step 3: Regenerate the texi export**

Follow whatever the repository already does for `agent.texi`:

```bash
git log --oneline -5 -- agent.texi
```

Use the same method the most recent of those commits used, then:

```bash
git diff --stat agent.texi
```

Expected: only the new section's lines.

- [ ] **Step 4: Commit**

```bash
git add README.org agent.texi
git commit -m "docs(tasks): document the durable task ledger"
```

---

### Task 14: Full checks and live verification

**Files:**
- No source changes expected; fix anything the checks surface, with a
  test for each fix.

- [ ] **Step 1: Full automated suite**

```bash
make test
make compile
```

Expected: `0 unexpected`, and no byte-compile warnings.  The final
count is the baseline recorded before Task 1 plus the number of
`ert-deftest` forms this plan added:

```bash
grep -c '^(ert-deftest' test/agent-tasks-test.el
git diff --stat main -- test/agent-test.el
```

The pre-existing tests must all still pass unchanged: no existing test
may have been edited to accommodate this work.

```bash
git diff --stat main -- test/agent-test.el
```

Expected: additions only.

- [ ] **Step 2: Prove the module installs nothing at load time**

```bash
emacs --batch -L . --eval '(progn (require (quote agent-tasks)) (message "id-hook=%S event-hook=%S mode=%S" agent-session-id-functions (bound-and-true-p agent-session-event-functions) agent-tasks-mode))'
```

Expected: both hooks empty (or holding only what other modules put
there) and `mode=nil`.  A module that installed a hook at load would
observe sessions for a person who only loaded it.

- [ ] **Step 3: Start a dedicated verification Emacs**

The checks run against live backends, and the ledger's observers are
**process-global**: the binding table, the attention item list and its
counter, and the session-event subscriptions are shared with every real
session in the Emacs that runs them.  Revision 3 tried to isolate that
by swapping globals inside the running Emacs, which cannot cover the
attention inbox and leaves any mistake sitting in the person's working
session.

Run the checks in a **separate Emacs**, so there is nothing to isolate:
it has no real sessions, no real inbox, and no configured real ledger.
But it must still be able to *start* Claude and Codex, so it loads the
same package builds the test suite does — `-Q` for the user's init, not
for the load path.

Save this as `scripts/live-verify.sh` in the worktree (it is scratch
tooling for this step; do not commit it):

```bash
#!/usr/bin/env bash
# Live-verification harness for the task ledger.  Usage:
#   ./scripts/live-verify.sh start | finish
set -u

state_dir="${TMPDIR:-/tmp}/agent-tasks-live"
id_file="$state_dir/current"

# Remove this run's state, and its pointer only when the pointer still
# names this run.  Callers must have confirmed the process is stopped.
release() {
  local id="$1" state="$2"
  [ -n "$state" ] && { trash "$state" 2>/dev/null || rm -rf "$state"; }
  if [ "$(cat "$id_file" 2>/dev/null)" = "$id" ]; then rm -f "$id_file"; fi
}

# Stop the Emacs whose pid is $1, politely then firmly, and report
# whether it is gone.  Never called with an unauthenticated pid.
stop_emacs() {
  local id="$1" target="$2" i
  [ -n "$target" ] || return 0
  kill -0 "$target" 2>/dev/null || return 0
  EMACS_SOCKET_NAME="$id" emacsclient -s "$id" --eval '(kill-emacs)' >/dev/null 2>&1
  for i in $(seq 1 20); do kill -0 "$target" 2>/dev/null || return 0; sleep 0.5; done
  kill "$target" 2>/dev/null
  for i in $(seq 1 10); do kill -0 "$target" 2>/dev/null || return 0; sleep 0.5; done
  return 1
}

start() {
  mkdir -p "$state_dir"
  id="agent-tasks-live-$$-$(date +%s)"
  state="$state_dir/$id"

  # Claim the run atomically, before anything else exists to clean up.
  # `noclobber' makes `>' fail when the file is already there, so two
  # starts cannot both believe they own the harness.
  if ! (set -o noclobber; printf '%s\n' "$id" > "$id_file") 2>/dev/null; then
    echo "a harness is already recorded ($(cat "$id_file" 2>/dev/null)); run finish first" >&2
    exit 1
  fi

  # Installed immediately after the claim, on EXIT so that *every* way
  # out -- a failing command under `set -e', an explicit `exit 1' from
  # one of the checks below, or an interrupt -- is covered.  An ERR trap
  # alone would miss the explicit exits.  The signal traps exit with
  # 128+signal so an interrupt cannot be reported as success.
  setup_ok=no
  server_pid=
  launcher_pid=
  cleanup_start() {
    local rc=$?
    set +e                     # a failing kill must not abort cleanup
    trap - EXIT INT TERM
    [ "$setup_ok" = yes ] && exit "$rc"
    echo "setup failed ($rc); cleaning up" >&2
    if stop_emacs "$id" "${server_pid:-}"; then
      [ -n "${launcher_pid:-}" ] && kill "$launcher_pid" 2>/dev/null
      release "$id" "$state"
    else
      echo "FAIL: could not stop the verification Emacs (${server_pid:-unknown});" >&2
      echo "      state retained: $state" >&2
      rc=1
    fi
    exit "$rc"
  }
  trap cleanup_start EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  set -e
  mkdir "$state"

  # Same profile resolution the Makefile uses, so the backends load.
  profile=$(emacsclient -e 'init-current-profile' 2>/dev/null | tr -d '"')
  [ -n "$profile" ] || { echo "cannot resolve the active Emacs profile" >&2; exit 1; }
  elpaca="$HOME/.config/emacs-profiles/$profile/elpaca"
  [ -d "$elpaca/builds" ] || { echo "no package builds at $elpaca" >&2; exit 1; }

  # The real Emacs executable, asked of the running one.  `emacs' on
  # PATH may be a shell wrapper that does not `exec' -- this machine has
  # one -- in which case `$!' is the wrapper and never matches the pid
  # Emacs reports.  Prefer the binary; the nonce check below is what
  # makes the harness correct even when this falls back.
  emacs_bin=$(emacsclient -e '(expand-file-name invocation-name invocation-directory)' \
                2>/dev/null | tr -d '"')
  [ -x "$emacs_bin" ] || emacs_bin=emacs

  # The real ledger of that profile, and the account definitions, read
  # out of the live Emacs -- never hard-coded, never written back.
  real=$(emacsclient -e '(if (boundp (quote agent-tasks-file))
                             (expand-file-name agent-tasks-file) "")' \
           2>/dev/null | tr -d '"')
  [ -n "$real" ] || real="$HOME/.config/emacs-profiles/$profile/agent/tasks.org"
  accounts=$(emacsclient -e '(format "%S"
                               (list (cons (quote claude) agent-claude-accounts)
                                     (cons (quote codex) agent-codex-accounts)
                                     (cons (quote claude-current)
                                           (agent-account-current (quote claude-code)))
                                     (cons (quote codex-current)
                                           (agent-account-current (quote codex)))))' \
              2>/dev/null | sed -e 's/^"//' -e 's/"$//' -e 's/\\"/"/g')
  [ -n "$accounts" ] || { echo "cannot read account definitions" >&2; exit 1; }

  root=$(mktemp -d "$state/root.XXXXXX")
  mkdir -p "$root/project"
  git -C "$root/project" init -q
  git -C "$root/project" commit -q --allow-empty -m baseline

  # Presence *and* content, recorded outside the scratch root.
  if [ -f "$real" ]; then
    printf 'present\n' > "$state/real-presence"
    shasum -a 256 "$real" | awk '{print $1}' > "$state/real-hash"
  else
    printf 'absent\n' > "$state/real-presence"
    : > "$state/real-hash"
  fi

  # A per-run secret the server echoes back.  This, not the process
  # name, is what proves the answering Emacs is the one this run
  # started: a stale server cannot know it.
  nonce=$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')
  printf '%s\n' "$nonce" > "$state/nonce"

  # EMACS_SOCKET_NAME points every `emacsclient' the CLIs run -- the
  # Claude notification hook among them -- at THIS server.  Without it
  # the hook contacts the person's real Emacs and the ledger sees no
  # lifecycle events at all.
  EMACS_SOCKET_NAME="$id" \
  "$emacs_bin" -Q --name "$id" \
    --eval "(progn
              (defvar agent-tasks-live-nonce \"$nonce\")
              (setq server-name \"$id\")
              (dolist (dir (file-expand-wildcards \"$elpaca/builds/*/\"))
                (add-to-list 'load-path dir))
              (add-to-list 'load-path \"$PWD\")
              (require 'agent) (require 'agent-claude) (require 'agent-codex)
              (require 'agent-tasks)
              (when (locate-library \"agent-attention\") (require 'agent-attention))
              (setenv \"EMACS_SOCKET_NAME\" \"$id\")
              (let ((imported '$accounts))
                (setq agent-claude-accounts (alist-get 'claude imported))
                (setq agent-codex-accounts (alist-get 'codex imported))
                ;; Select in memory only: \`agent-account-set' would write
                ;; the profile's account file and change the person's
                ;; selection.
                (when-let* ((a (alist-get 'claude-current imported)))
                  (puthash 'claude-code a agent-account--current))
                (when-let* ((a (alist-get 'codex-current imported)))
                  (puthash 'codex a agent-account--current)))
              ;; The backend modes own every lifecycle hook and advice;
              ;; without them no session event ever reaches the ledger.
              (agent-claude-mode 1)
              (agent-codex-mode 1)
              (setq agent-tasks-file \"$root/project/tasks.org\")
              (agent-tasks-mode 1)
              (when (fboundp 'agent-attention-mode) (agent-attention-mode 1))
              (server-start))" &
  launcher_pid=$!
  printf '%s\n' "$root" > "$state/root"
  printf '%s\n' "$real" > "$state/real-path"

  # Ready means: the server answers with THIS run's nonce, and both
  # backend modes are on.  The pid it reports is the one recorded and
  # managed -- `$launcher_pid' may be a wrapper rather than Emacs
  # itself.  The connection is *expected* to fail while the server
  # starts, so the assignment must not trip `set -e' -- hence
  # `|| reported='.
  ready=no
  for _ in $(seq 1 60); do
    reported=$(EMACS_SOCKET_NAME="$id" emacsclient -s "$id" \
                 --eval '(list agent-tasks-live-nonce (emacs-pid)
                               (featurep (quote agent-tasks))
                               agent-claude-mode agent-codex-mode)' 2>/dev/null) \
      || reported=
    case "$reported" in
      "(\"$nonce\" "*" t t t)")
        server_pid=$(printf '%s' "$reported" | sed -e 's/^("[^"]*" //' -e 's/ t t t)$//')
        case "$server_pid" in
          ''|*[!0-9]*) server_pid= ;;
          *) kill -0 "$server_pid" 2>/dev/null && ready=yes ;;
        esac
        ;;
    esac
    [ "$ready" = yes ] && break
    kill -0 "$launcher_pid" 2>/dev/null || break
    sleep 0.5
  done
  if [ "$ready" != yes ]; then
    echo "verification Emacs did not become ready (or a stale server answered)" >&2
    exit 1     # the trap stops the child, then releases state and pointer
  fi
  printf '%s\n' "$server_pid" > "$state/pid"
  setup_ok=yes
  echo "ready: id $id, emacs pid $server_pid, root $root"
  echo "run the checks with: EMACS_SOCKET_NAME=$id emacsclient -s $id -c"
}

finish() {
  rc=0
  id=$(cat "$id_file" 2>/dev/null) || { echo "no harness state" >&2; exit 1; }
  state="$state_dir/$id"
  root=$(cat "$state/root" 2>/dev/null) || { echo "state is incomplete: $state" >&2; exit 1; }
  pid=$(cat "$state/pid" 2>/dev/null || true)
  nonce=$(cat "$state/nonce" 2>/dev/null || true)
  real=$(cat "$state/real-path")
  stopped=no

  # 1. Stop the process first, so nothing it writes at shutdown escapes
  #    the ledger comparison.  A recorded pid may have been reused, so
  #    it is signalled ONLY after the server echoes this run's nonce
  #    from that same pid -- never on the strength of the number alone.
  if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
    stopped=yes                # already gone; nothing to signal
  else
    reported=$(EMACS_SOCKET_NAME="$id" emacsclient -s "$id" \
                 --eval '(list agent-tasks-live-nonce (emacs-pid))' 2>/dev/null) || reported=
    if [ "$reported" = "(\"$nonce\" $pid)" ]; then
      if stop_emacs "$id" "$pid"; then
        stopped=yes
      else
        echo "FAIL: verification Emacs $pid did not stop" >&2
        rc=1
      fi
    else
      echo "FAIL: pid $pid is alive but did not echo this run's nonce" >&2
      echo "      (reported: ${reported:-no answer}); refusing to signal it" >&2
      rc=1
    fi
  fi

  # 2. Only now compare the real ledger.
  before=$(cat "$state/real-presence")
  if [ -f "$real" ]; then now=present; else now=absent; fi
  if [ "$before" != "$now" ]; then
    echo "FAIL: real ledger presence changed ($before -> $now): $real" >&2
    rc=1
  elif [ "$now" = present ] &&
       [ "$(shasum -a 256 "$real" | awk '{print $1}')" != "$(cat "$state/real-hash")" ]; then
    echo "FAIL: the real ledger changed: $real" >&2
    rc=1
  fi

  # 3. Release only after confirmed termination and a clean comparison;
  #    otherwise keep everything so the run can be investigated and
  #    re-finished.
  if [ $rc -ne 0 ] || [ "$stopped" != yes ]; then
    echo "state retained for investigation: $state" >&2
    return 1
  fi
  trash "$root" 2>/dev/null || true
  if [ -e "$root" ]; then
    echo "FAIL: scratch root not removed: $root" >&2
    echo "state retained for investigation: $state" >&2
    return 1
  fi
  release "$id" "$state"
  echo "clean"
}

case "${1:-}" in
  start) start ;;
  finish) finish ;;
  *) echo "usage: $0 start|finish" >&2; exit 2 ;;
esac
```

Then:

```bash
chmod +x scripts/live-verify.sh
./scripts/live-verify.sh start
```

What the isolated process needs beyond a load path, each of which the
previous revision left out and any of which makes the checks impossible
rather than merely awkward:

- **Both backend modes enabled.**  `agent-claude-mode` and
  `agent-codex-mode` own every hook and advice their backends install
  (`agent-claude.el:2482`, `agent-codex.el:887`); nothing is installed
  at load time.  Without them the ledger observes no lifecycle events
  at all, so checks 2, 3 and 4 could not fail even if the feature were
  broken.
- **Account definitions imported, selection in memory only.**
  `agent-account-list` resolves the backend's `:accounts` slot through
  `agent-claude-accounts`/`agent-codex-accounts`
  (`agent-claude.el:227`, `agent-codex.el:154`), which `-Q` leaves at
  their defaults, so no configured account could start.  The harness
  copies those alists and the current selections out of the live Emacs
  and sets the selection with `puthash` into `agent-account--current`
  — **not** `agent-account-set`, which would write the profile's
  account file and change the person's selection.  (Use
  `agent-account-select` inside the verification Emacs only if you want
  to switch accounts *there*; it persists, so prefer the import.)
- **`EMACS_SOCKET_NAME` set to this server.**  `hooks/notify-emacs-notification.sh`
  invokes plain `emacsclient`, which contacts the *default* server —
  the person's real Emacs — and the verification process would see
  nothing.  It is exported for the Emacs process and set inside it, so
  child CLIs inherit it.

Every step below runs in that Emacs.  Task instructions stay inert —
"Reply with the words `task received` and do nothing else." — because
every claim under test is about state transitions and bindings, and
none needs an agent that changes a file.

Two shell helpers for the checks that compare bytes:

```bash
state="${TMPDIR:-/tmp}/agent-tasks-live/$(cat "${TMPDIR:-/tmp}/agent-tasks-live/current")"
root=$(cat "$state/root")
baseline() { git -C "$root/project" add -- tasks.org &&
             git -C "$root/project" commit -q --allow-empty -m "baseline: $1"; }
ledger_diff() { git -C "$root/project" diff -- tasks.org; }
```

- [ ] **Step 4: Live verification, both backends**

Run each of these for Claude Code and for Codex, recording the result.

1. **Dispatch into a new session.**  Create a task in
   `$root/project`, dispatch it choosing "new session", confirm from
   the conversation that the instruction arrived exactly once, and
   confirm the ledger shows `RUNNING`, the binding, and — once the
   backend reports one — `SESSION_ID` plus a `Log` line recording the
   identity confirmation.
2. **A finished turn does not close the task.**  **First move focus
   away from the session** — select another window, or another frame —
   because `agent-attention-mode` deliberately files no completion item
   for a buffer the person is reading, and watching the session would
   fail the second half of this check for a reason unrelated to the
   ledger.  Then let the turn complete.  Confirm the task is still
   `RUNNING`, that its `Log` gained one line naming the completed turn,
   and that the ledger filed **no** attention item of its own while
   `agent-attention-mode`'s own completion item is present.  This is
   the design's central claim and the one most likely to be
   implemented wrong.
3. **Blocked and unblocked.**  Provoke a real permission prompt in the
   bound session.  Confirm the task becomes `BLOCKED` with a reason
   taken from what the backend reported (not a synthesized one), and
   that answering it returns the task to `RUNNING`.
4. **Session death.**  Kill the session buffer.  Confirm the task
   becomes `UNKNOWN` with a reason, that an attention item was filed,
   and that nothing was re-dispatched.
5. **Crash recovery, twice.**  With a `RUNNING` task written into the
   scratch ledger naming a session that does not exist, and no binding
   for it:

   ```elisp
   (setq agent-tasks--reconciled nil)
   ```

   Open the list.  Confirm the summary reports one task reconciled to
   `UNKNOWN`, that the `Log` records the reason, and that nothing was
   re-bound.  Then lose a *second* session the same way **without**
   resetting the flag and press `g`: it must be reported too.  That is
   the once-per-Emacs guard not applying to an explicit refresh.
6. **Restart.**  `agent-restart` a session holding a `RUNNING` task.
   Confirm the binding follows the resumed session, the state is
   unchanged, and the `Log` records the re-attachment — and that the
   task is *not* `UNKNOWN`, which is what a finalizer firing
   mid-startup would have produced.
7. **Dependency gate.**  Dispatch a task whose dependency is not `DONE`
   and confirm the refusal names the dependency and its state; close
   the dependency as `succeeded` and confirm the dispatch proceeds and
   the `Log` records nothing about an override.
8. **Busy target.**  Dispatch into a session mid-turn.  Confirm the
   refusal names the session, mentions `agent-queue-prompt`, and that
   the running turn is unaffected.
9. **Closing honestly.**  Run `baseline closing`, then close one task
   with outcome `succeeded`, a result and evidence, and cancel another
   with a reason.  Run `ledger_diff` and confirm the only changed bytes
   are the keyword, `UPDATED`, `OUTCOME`, and the new
   `Result`/`Evidence`/`Log` lines.  Confirm both tasks' sessions are
   no longer bound.
10. **Prompt isolation.**  Run `baseline isolation` **first** — check 9
    left its closing changes uncommitted, and without a fresh baseline
    this check's "ledger unchanged" assertion would be reading check
    9's diff.  Then, with `agent-tasks-dispatch-confirm` bound to nil,
    type some text into an idle session's prompt **without** submitting
    it and dispatch a task there.  The dispatch must refuse, naming the
    pending input; the typed text must still be sitting unsent in the
    prompt; the task must still be `PENDING` with attempt 0 and no
    binding; and `ledger_diff` must print nothing at all.

- [ ] **Step 5: Import and chief context, against copies only**

Copy two or three Org TODOs into `$root/project/notes.org` — never
point the import at a real notes file — and confirm: the scope rules
for region, narrowed subtree, and whole buffer; that `t` jumps back to
the right heading, including when a heading differing only in case sits
above it; and that a re-import creates nothing and reports the skipped
count.

Call `agent-tasks-chief-context` and read its output, checking each
line carries an age.  Do **not** add it to
`agent-chief-context-functions`: the chief is a live loop that contacts
the person, and a verification step has no business changing what it
says.

- [ ] **Step 6: Dispose of the verification Emacs**

```bash
./scripts/live-verify.sh finish
```

Run it as the **last command in the block**, so the block's status is
`finish`'s.  Do not append anything after it — neither `|| echo ...`,
which swallows the failure into a successful `echo`, nor a trailing
`echo "$?"`, which reports the status while *returning* the echo's own
success.  If the surrounding script must do more afterwards, capture
and re-exit:

```bash
./scripts/live-verify.sh finish; status=$?
# ... anything else ...
exit $status
```

This status is a verification result, not a cleanup nuisance: a
non-zero exit fails the verification.

`finish` works in the order the failure modes require: it stops the
exact process id it recorded — confirming through the server that the
pid answering is the one it started — **and only then** compares the
real ledger's presence and hash, because a shutting-down Emacs can
still write, and a comparison made first would miss exactly that.  It
trashes the scratch root last, and **keeps all of its state** when any
check failed, so a failed run can be investigated and re-finished
rather than losing its own evidence.  Run it however the run ended,
including after an aborted or crashed session.

- [ ] **Step 7: Record the outcome**

Write the result of each of the ten checks, for each backend, into
`logs/task-ledger-live-verification.md`.  Anything that did not behave
as specified is a defect to fix with a regression test, not a note to
file — in particular check 2, which is the whole feature, and check 10,
which is the one a person cannot recover from by hand.

- [ ] **Step 8: Final commit**

```bash
make test && make compile
```

Stage **only** the verification record, plus any file you actually
changed while fixing a defect this step found, each by explicit path.
`git add -A` would sweep in whatever else happens to be in the working
tree, including `scripts/live-verify.sh`, which is scratch tooling and
is not committed.  If fixing a defect changed the module, that fix
belongs to its own task's commit with its own regression test, not to
this one.

---

## Self-review notes

Checked against the spec, section by section:

- Spec §1 (store) → Tasks 1 and 2.
- Spec §2 (states) → Tasks 4 and 6, plus the exhaustive invariant test.
- Spec §3 (correlation) → Tasks 5, 7 and 9.
- Spec §4 (dependencies) → Task 3 (validation) and Task 8 (the gate).
- Spec §5 (dispatch) → Task 8.
- Spec §6 (crash recovery) → Tasks 5, 7 and 9.
- Spec §7 (evidence) → Task 6.
- Spec §8 (commands and UI) → Tasks 4, 9 and 10.
- Spec §9 (integration boundaries) → Task 11 (import, chief), Task 5
  (attention), Task 10 (agent-log), and the explicit non-integration
  with the queue and composer, enforced by Task 8's refusal message.
- Spec §10 (menu and manual) → Tasks 12 and 13.
- Spec §11 (migration) → Task 1 (version parsing), Task 2 (the write
  gate), Task 12 (autoloads only).
- Spec §13 (verification) → the per-task tests and Task 14.

Two spec points are worth restating because they are easy to
"simplify" away during implementation, and both have tests:

1. The ledger writes **before** it sends, and a failed send goes to
   `UNKNOWN`, not `PENDING`.
2. Reconciliation requires a matching **native session id**; a
   directory-and-instance match is not proof.
