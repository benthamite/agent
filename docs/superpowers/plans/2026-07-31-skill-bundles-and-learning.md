# Skill Bundles and Reviewable Learning Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

Revision 2.  Revision 1 was reviewed and found not implementation-ready
on thirteen counts, three of which were reproduced against this machine
before being fixed here: `git status` rejects an absolute path reached
through the symlinked `~/.claude/skills` root, so provenance reported a
dirty tree as clean; `forward-line -1` from `point-max` skips an
unterminated final line, so a corrupt history tail vanished instead of
being counted; and 4 of the 1137 real learning-candidate files use
heading shapes the parser rejected.  The revision hardens verification
wiring, menu integration, dispatch readiness, record truthfulness,
provenance, bundle validation, history retention, the learning parser
and writer, and the live-verification procedure.  The feature scope is
unchanged.

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
- **No command deletes a file it did not create, and no command
  overwrites one.**  The single exception is a temporary file this
  package wrote moments earlier and is cleaning up after a failed
  atomic replacement.
  Archiving is `rename-file` inside `agent-learn-directory` to a name
  proven unused.  History rotation renames to a timestamped name proven
  unused.  Rewriting a candidate file is a write to a temporary file in
  the same directory followed by `rename-file`, so a crash mid-write
  leaves the original intact.
- **Every claim in a record is one the code checked.**  A `dispatched`
  record is written only after the call that starts the work returned
  without signalling.  Provenance is re-resolved immediately before the
  message is submitted, and a source that changed since the preview
  aborts the dispatch.  Where a claim is narrower than it looks — the
  CLI reads a skill file later still — the manual says so.
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

1. **Readiness policy.**  All three plans refuse to submit into a
   session that cannot start a fresh turn.  The other two can see more
   than this one: the composer adds the `:ready-to-submit-p` backend
   slot and `agent-session-ready-to-submit-p`, and the queue plan adds
   `agent--session-awaiting-reason` so a session sitting at a permission
   dialog — which displays as `waiting` — is not treated as idle.  Its
   contract, quoted from that plan's Task 2, is
   `agent-session-ready-to-submit-p BUFFER &optional BACKEND` returning
   `ready`, `busy`, or `unknown`, and "never `ready` for a session that
   last reported `blocked`".  This plan therefore **defers to it when it
   exists and falls back to the display state when it does not**:
   `agent-ensure-dispatch-target` (Task 6) calls it when it is `fboundp`
   and only otherwise reads `agent-session-display-state`.  Do not add
   the slot or the awaiting-reason machinery here.
2. **`agent-menu` keys.**  This plan uses `b`, `u`, `k` (Tools) and `v`
   (Prompts & learning).  The queue plan takes `Q`, `L`, `I`, `E`
   (Sessions) and the composer takes `C` (Prompts): **`L` belongs to
   `agent-queue-list`, not to this plan.**  Every menu edit in Task 14
   inserts single lines into the existing columns; do not retype a
   column, or you will delete whichever of `C`/`Q`/`L`/`I`/`E` landed
   first.  Task 14's test asserts exact key-to-command mappings and that
   no key in the whole prefix is bound twice.
3. **Makefile lists.**  Both other plans add their own modules and test
   files.  This plan therefore **appends with `+=` on new lines** rather
   than restating `SRC :=`/`TEST_FILES :=`, and Task 2 verifies that no
   entry present in the committed Makefile disappeared.
4. **Step-at-a-time dispatch** is explicitly deferred to the queue
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
7. **Review state is read only from the contiguous managed block
   directly after a candidate heading.**  A `**Review:**` line anywhere
   else in a candidate is not authority over that candidate's state —
   the file is written by a model, and a model-authored line must not be
   able to mark itself approved.  A stray one is reported as a problem
   row instead.
8. **The learning parser accepts `##` and `###` headings, with or
   without a candidate number.**  Measured against the real corpus:
   1133 of 1137 files use `## Candidate N:`, and the rest use `###
   Candidate N:` or `## Candidate:`.  Files with no candidate section at
   all — one free-prose file in that corpus — become a named problem
   row, never a silently empty result.
9. **Provenance is re-resolved immediately before submission and
   compared with the preview.**  Hashing at preview time and submitting
   a path minutes later would claim more than the code checked.  The
   alternative, dispatching an immutable snapshot, would mean copying
   skill trees; that is a bigger change than this feature justifies.
10. **History rotation writes a timestamped file and the reader reads
    rotations too.**  A single overwritten `.1` contradicts the
    no-deletion rule and makes the history buffer silently lie about
    what happened; rotations are part of the history, so the reader
    walks them newest-first until it has enough records.
11. **The live per-session skill list is owned by `agent-skill-mode`,
    fed by every session-mode record.**  Populating it from the bundle
    command alone would have missed before-exit skills, and the
    describe command would have reported a session as having loaded no
    instructions when it had.

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
    ;; This stub calls back synchronously, so the outcome record is
    ;; emitted before the dispatch record.  Records are correlated by
    ;; `:id', never by order, and the assertions say so.
    (let ((dispatched (cl-find 'dispatched records
                               :key (lambda (r) (plist-get r :outcome))))
          (outcome (cl-find 'ok records
                            :key (lambda (r) (plist-get r :outcome)))))
      (should (= 2 (length records)))
      (should dispatched)
      (should outcome)
      (should (eq 'run-skill (plist-get dispatched :origin)))
      (should (eq 'batch (plist-get dispatched :mode)))
      (should (equal "--accept" (plist-get dispatched :args)))
      (should (equal "/skills/demo/SKILL.md" (plist-get dispatched :path)))
      (should (equal (plist-get dispatched :id) (plist-get outcome :id))))))

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
    (let ((outcome (cl-find 'error records
                            :key (lambda (r) (plist-get r :outcome)))))
      (should outcome)
      (should (equal "exit 1" (plist-get outcome :error))))))

(ert-deftest agent-test-run-skill-records-nothing-when-startup-signals ()
  "Claim no dispatch when the backend signals before starting work."
  (let* ((agent-backends nil)
         (records nil)
         (agent-skill-invocation-functions
          (list (lambda (record) (push record records)))))
    (apply #'agent-register-backend
           'stub
           (agent-test--backend
            :run-prompt (lambda (&rest _) (error "codex not found"))))
    (should-error (agent--run-skill 'stub (list :name "demo" :style 'file)
                                    nil))
    (should-not records)))

(ert-deftest agent-test-run-skill-preserves-source-identity ()
  "Carry the discovered root and style into the record, not just the path."
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
               (ignore directory callback)
               nil))))
    (agent--run-skill 'stub
                      (list :name "demo" :style 'slash
                            :path "/s/demo/SKILL.md" :root "/s")
                      nil)
    (let ((record (car records)))
      (should (equal "/s" (plist-get record :root)))
      (should (eq 'slash (plist-get record :style))))))

(ert-deftest agent-test-before-exit-record-carries-the-skill-path ()
  "Resolve the before-exit skill so its record names a source file."
  (let* ((agent-backends nil)
         (records nil)
         (agent-skill-invocation-functions
          (list (lambda (record) (push record records)))))
    (apply #'agent-register-backend
           'stub
           (agent-test--backend
            :buffer-p (lambda (_buffer) t)
            :submit (lambda (&rest _) nil)
            :skill-command-prefix "/"))
    (cl-letf (((symbol-function 'agent-discover-skills)
               (lambda (_backend)
                 (list (list :name "update-log" :path "/s/update-log/SKILL.md"
                             :style 'slash :root "/s"))))
              ((symbol-function 'agent--buffer-directory)
               (lambda (&rest _) "/tmp/")))
      (with-temp-buffer
        (setq-local agent--before-exit (list :queue '("update-log")))
        (agent--before-exit-submit-next (current-buffer))))
    (let ((record (car records)))
      (should (eq 'before-exit (plist-get record :origin)))
      (should (eq 'session (plist-get record :mode)))
      (should (equal "/s/update-log/SKILL.md" (plist-get record :path)))
      (should (equal "/s" (plist-get record :root))))))

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
`:path', `:root' and `:style' (the skill file and the discovery root
and style it came from), `:source' (a resolved provenance plist),
`:bundle' with `:step' and `:steps', `:outcome' and `:error'.

`:outcome' is one of:

  `dispatched'  the work was started: for `session' mode the text was
                submitted at the session prompt, for `batch' mode the
                backend`s run-prompt call returned without signalling.
  `ok'/`error'  a batch run finished, reported by a second record
                carrying the same `:id'.
  `skipped'     a bundle step that was not run, with `:skipped-reason'.

An emitter must not report `dispatched' before the call that starts the
work has returned.  A backend `run-prompt' either signals before doing
anything or returns after the work has started and calls its callback
later; a backend that instead called back synchronously would emit its
outcome record first, which readers tolerate because records correlate
by `:id', not by order.

Consumers are observers: they must not submit session input, and their
return values are ignored.  A consumer that signals is reported with
`display-warning' and does not disturb the dispatch that produced the
record.  `agent-skill.el' subscribes to this hook to write the durable
usage history and to track what each live session was given."
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
         (id (agent--skill-invocation-id))
         (facts (list :id id :skill name :origin 'run-skill :mode 'batch
                      :backend backend :args arguments
                      :path (plist-get skill :path)
                      :root (plist-get skill :root)
                      :style (plist-get skill :style)
                      :directory default-directory)))
    (message "Running skill %s..." name)
    (prog1
        (funcall run (agent--skill-prompt skill arguments)
                 :directory default-directory
                 :callback
                 (cl-function
                  (lambda (text &key error)
                    (agent-note-skill-invocation
                     (append facts (list :outcome (if error 'error 'ok)
                                         :error error)))
                    (agent--display-skill-result name text error))))
      ;; Only now is a dispatch a fact: a backend that cannot start the
      ;; work signals out of the call above, and nothing is recorded.
      (agent-note-skill-invocation
       (append facts (list :outcome 'dispatched))))))
```

The `prog1` is what orders this correctly: the dispatch record is
written after `run` returns, and the id is generated up front so the
outcome record can carry it even when the callback runs first.

- [ ] **Step 6: Emit from the audit runner**

In `agent--audit-run-next`, add a `facts` binding after `run` and wrap
the call the same way, so a backend that cannot start records nothing:

```elisp
           (facts (list :id (agent--skill-invocation-id)
                        :skill name :origin 'audit :mode 'batch
                        :backend backend :args "--accept"
                        :path (plist-get skill :path)
                        :root (plist-get skill :root)
                        :style (plist-get skill :style)
                        :directory (plist-get state :dir))))
      (message "Running audit %s..." name)
      (prog1
          (funcall run (agent--skill-prompt skill "--accept")
                   :directory (plist-get state :dir)
                   :callback
                   (cl-function
                    (lambda (text &key error)
                      (agent-note-skill-invocation
                       (append facts (list :outcome (if error 'error 'ok)
                                           :error error)))
                      (plist-put state :results
                                 (cons (list :skill name :text text
                                             :error error)
                                       (plist-get state :results)))
                      (plist-put state :queue (cdr queue))
                      (unless error
                        (ignore-errors
                          (agent--audit-commit-changes
                           (plist-get state :dir) name)))
                      (agent--audit-run-next state))))
        (agent-note-skill-invocation
         (append facts (list :outcome 'dispatched)))))))
```

The audit's fallback skill plist (`(list :name name :style 'slash)`,
used when the name is not discoverable) carries no `:path` or `:root`,
so its records honestly say the source is unknown.

- [ ] **Step 7: Emit from the before-exit chain**

A before-exit entry is only a name, so resolve it against the backend's
skills to give the record a source.  Add this helper next to
`agent--before-exit-skill-command`:

```elisp
(defun agent--before-exit-skill-source (backend name)
  "Return the (:path :root :style) facts of skill NAME for BACKEND.
Return nil when discovery fails or the skill is not found: a record
that names no source is honest, and session exit must not break because
a skill root was unreadable."
  (when-let* ((skill (condition-case nil
                         (cl-find name (agent-discover-skills backend)
                                  :key (lambda (s) (plist-get s :name))
                                  :test #'equal)
                       (error nil))))
    (list :path (plist-get skill :path)
          :root (plist-get skill :root)
          :style (plist-get skill :style))))
```

Then, in `agent--before-exit-submit-next`, after the successful
`(agent-submit command buffer)`:

```elisp
        (when command
          (agent-submit command buffer)
          (let ((name (agent--before-exit-skill-entry-name entry)))
            (agent-note-skill-invocation
             (append
              (list :skill name
                    :origin 'before-exit :mode 'session
                    :backend backend
                    :args (agent--before-exit-skill-entry-args entry)
                    :buffer buffer
                    :directory (agent--buffer-directory backend buffer)
                    :outcome 'dispatched)
              (agent--before-exit-skill-source backend name))))
          (message "Started %s; this session will close when the before-exit skills finish"
                   command)
          (setq sent t))
```

- [ ] **Step 8: Run the tests**

Run: `make test 2>&1 | tail -10`
Expected: all tests pass, count up by 9.

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
- Modify: `Makefile` (append, never restate, the two lists)

**Interfaces:**
- Consumes: `agent-discover-skills` plists (`:name`, `:path`, `:style`,
  `:root`).
- Produces:
  - `agent-skill-provenance (SKILL)` → plist `(:path :truename :root
    :style :content-sha1 :repo :relative-path :commit :dirty)`.
  - `agent-skill-record-git-provenance` — defcustom boolean, default t.

- [ ] **Step 1: Register the new test file in the Makefile**

Do this **before** writing the test, so the RED step below actually
runs it.  Append two lines directly after the existing `TEST_FILES :=`
line — do not retype either list, because the attention/queue and
composer plans append their own modules to the same lists:

```make
SRC += agent-skill.el
TEST_FILES += test/agent-skill-test.el
```

Verify nothing was lost:

```bash
git show HEAD:Makefile | sed -n 's/^SRC :=//p' | tr ' ' '\n' | sed '/^$/d' | sort -u > /tmp/agent-src-before
sed -n 's/^SRC [:+]=//p' Makefile | tr ' ' '\n' | sed '/^$/d' | sort -u > /tmp/agent-src-after
comm -23 /tmp/agent-src-before /tmp/agent-src-after
git show HEAD:Makefile | sed -n 's/^TEST_FILES :=//p' | tr ' ' '\n' | sed '/^$/d' | sort -u > /tmp/agent-tests-before
sed -n 's/^TEST_FILES [:+]=//p' Makefile | tr ' ' '\n' | sed '/^$/d' | sort -u > /tmp/agent-tests-after
comm -23 /tmp/agent-tests-before /tmp/agent-tests-after
```

Expected: both `comm` invocations print nothing.  Any line printed is an
entry that disappeared; restore it before continuing.

- [ ] **Step 2: Write the failing tests**

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
    (let* ((agent-skill-record-git-provenance t)
           (repo (file-truename (plist-get skill :root)))
           (relative "demo"))
      (cl-letf (((symbol-function 'process-file)
                 (agent-skill-test--stub-git
                  `((("rev-parse" "--show-toplevel") . (0 . ,repo))
                    (("rev-parse" "HEAD") . (0 . "abc123\n"))
                    (("status" "--porcelain" "--" ,relative) . (0 . ""))))))
        (let ((prov (agent-skill-provenance skill)))
          (should (equal (file-name-as-directory repo)
                         (plist-get prov :repo)))
          (should (equal "abc123" (plist-get prov :commit)))
          (should (equal relative (plist-get prov :relative-path)))
          (should-not (plist-get prov :dirty)))))))

(ert-deftest agent-skill-test-provenance-reports-a-dirty-auxiliary-file ()
  "Set `:dirty' for a change anywhere in the skill directory.
The skill file itself is untouched here; a modified reference file must
still make the provenance dirty, because the model reads it too."
  (agent-skill-test--with-skill skill
    (let* ((agent-skill-record-git-provenance t)
           (repo (file-truename (plist-get skill :root))))
      (cl-letf (((symbol-function 'process-file)
                 (agent-skill-test--stub-git
                  `((("rev-parse" "--show-toplevel") . (0 . ,repo))
                    (("rev-parse" "HEAD") . (0 . "abc123\n"))
                    (("status" "--porcelain" "--" "demo")
                     . (0 . " M demo/references/notes.md\n"))))))
        (should (plist-get (agent-skill-provenance skill) :dirty))))))

(ert-deftest agent-skill-test-provenance-through-a-symlinked-root ()
  "Ask git about a repository-relative path, not the symlinked one.
Reproduces the real setup: `~/.claude/skills' is a symlink into the
dotfiles repository, and `git status -- ABSOLUTE-SYMLINKED-PATH' fails
with `outside repository', which a naive implementation reads as
`clean'."
  (let* ((real (make-temp-file "agent-skill-real" t))
         (link (make-temp-file "agent-skill-link"))
         (dir (expand-file-name "demo" real))
         (asked nil))
    (unwind-protect
        (progn
          (delete-file link)
          (make-symbolic-link real link)
          (make-directory dir)
          (with-temp-file (expand-file-name "SKILL.md" dir)
            (insert "---\nname: demo\n---\n"))
          (let ((skill (list :name "demo" :style 'file :root link
                             :path (expand-file-name "demo/SKILL.md" link)))
                (agent-skill-record-git-provenance t))
            (cl-letf (((symbol-function 'process-file)
                       (lambda (_program &optional _in dest _display &rest args)
                         (push args asked)
                         (let ((out (pcase args
                                      (`("rev-parse" "--show-toplevel")
                                       (file-truename real))
                                      (`("rev-parse" "HEAD") "abc123")
                                      (_ " M demo/SKILL.md"))))
                           (let ((buffer (if (consp dest) (car dest) dest)))
                             (when (or (eq buffer t) (bufferp buffer))
                               (insert out))))
                         0)))
              (should (plist-get (agent-skill-provenance skill) :dirty))
              (should (member '("status" "--porcelain" "--" "demo") asked))
              (should-not
               (cl-find-if (lambda (args)
                             (cl-find-if (lambda (a)
                                           (and (stringp a)
                                                (string-prefix-p link a)))
                                         args))
                           asked)))))
      (delete-directory real t)
      (delete-file link))))

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

- [ ] **Step 3: Run the tests and watch them fail**

Run: `make test 2>&1 | tail -20`
Expected: the run aborts with `Cannot open load file: agent-skill`.
Because Step 1 registered the test file first, this failure proves the
new tests are actually wired into `make test` — a RED step that passes
because nothing loaded the file would prove nothing.

- [ ] **Step 4: Create the module with provenance**

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

(defun agent-skill--git-provenance (truename)
  "Return the git provenance plist for the skill file at TRUENAME.
TRUENAME must already be symlink-resolved.  Git is asked about the
skill's whole *directory*, addressed relative to the repository root:
the model reads the skill's reference files too, and an absolute path
that reaches the repository through a symlink — which is how
`~/.claude/skills' is set up on the author's machine — makes git fail
with `outside repository', which a caller would otherwise read as a
clean tree."
  (let* ((directory (file-name-directory truename))
         (default-directory directory)
         (repo (agent-skill--git-output "rev-parse" "--show-toplevel")))
    (if (not repo)
        (list :repo nil :relative-path nil :commit nil :dirty nil)
      (let* ((root (file-name-as-directory (file-truename repo)))
             (relative (directory-file-name
                        (file-relative-name directory root))))
        (list :repo root
              :relative-path relative
              :commit (agent-skill--git-output "rev-parse" "HEAD")
              :dirty (and (agent-skill--git-output
                           "status" "--porcelain" "--" relative)
                          t))))))

(defun agent-skill-provenance (skill)
  "Return the provenance plist for SKILL.
SKILL is a plist from `agent-discover-skills'.  The result carries
`:path', `:truename', `:root', `:style', `:content-sha1' and, unless
`agent-skill-record-git-provenance' is nil or the file is unreadable,
`:repo', `:relative-path', `:commit' and `:dirty'.

The content hash covers `SKILL.md' exactly.  The commit locates the
skill's directory in history, and `:dirty' reports uncommitted changes
anywhere in that directory, so a modified reference file is visible even
though only `SKILL.md' is hashed.

The claim is narrower than it looks, and the manual says so: provenance
describes the files as of the moment it was resolved.  The CLI reads
them later still.  `agent-skill-run-bundle' therefore re-resolves and
compares immediately before submitting, and refuses to send when
anything changed since the preview.

Git is re-read on every call: stale provenance would be worse than
none."
  (let* ((path (plist-get skill :path))
         (truename (and path (file-truename path)))
         (base (list :path path
                     :truename truename
                     :root (plist-get skill :root)
                     :style (plist-get skill :style)
                     :content-sha1 (agent-skill--file-sha1 path))))
    (if (and agent-skill-record-git-provenance
             truename
             (file-readable-p truename))
        (append base (agent-skill--git-provenance truename))
      base)))

(defun agent-skill-provenance-changed-p (before after)
  "Return non-nil when provenance AFTER differs materially from BEFORE.
Only the facts that describe the instructions are compared: the content
hash, the commit, and the dirty flag."
  (not (and (equal (plist-get before :content-sha1)
                   (plist-get after :content-sha1))
            (equal (plist-get before :commit) (plist-get after :commit))
            (eq (and (plist-get before :dirty) t)
                (and (plist-get after :dirty) t)))))

;;;; Provide

(provide 'agent-skill)
;;; agent-skill.el ends here
```

- [ ] **Step 5: Run the tests**

Run: `make test 2>&1 | tail -10`
Expected: all pass, including the six new provenance tests.

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

(ert-deftest agent-skill-test-history-counts-an-unterminated-corrupt-tail ()
  "Count a malformed last line that has no trailing newline.
A reader that walks backwards with `forward-line' skips such a line
entirely, so a truncated write would disappear instead of being
reported."
  (agent-skill-test--with-history
    (agent-skill--record (list :id "one" :skill "demo" :origin 'run-skill))
    (write-region "{\"half\":" nil agent-skill-history-file t 'no-message)
    (let ((read (agent-skill-history-read)))
      (should (= 1 (plist-get read :total)))
      (should (= 1 (plist-get read :unparsable))))))

(ert-deftest agent-skill-test-history-rotation-keeps-every-file ()
  "Rotate to a fresh timestamped name each time, overwriting nothing."
  (agent-skill-test--with-history
    (let ((agent-skill-history-max-bytes 10)
          (stamp 0))
      (cl-letf (((symbol-function 'agent-skill--history-stamp)
                 (lambda () (format "2026073100000%d" (cl-incf stamp)))))
        (dotimes (i 3)
          (agent-skill--record (list :id (number-to-string i)
                                     :skill "demo" :origin 'run-skill))))
      (should (= 2 (length (agent-skill--rotated-history-files))))
      (should (file-exists-p agent-skill-history-file)))))

(ert-deftest agent-skill-test-history-read-spans-rotations ()
  "Read rotated files too, newest first, until LIMIT is satisfied."
  (agent-skill-test--with-history
    (let ((agent-skill-history-max-bytes 10)
          (stamp 0))
      (cl-letf (((symbol-function 'agent-skill--history-stamp)
                 (lambda () (format "2026073100000%d" (cl-incf stamp)))))
        (dotimes (i 3)
          (agent-skill--record (list :id (number-to-string i)
                                     :time (float i)
                                     :skill (format "s%d" i)
                                     :origin 'run-skill))))
      (let ((records (plist-get (agent-skill-history-read) :records)))
        (should (equal '("s2" "s1" "s0")
                       (mapcar (lambda (r) (alist-get 'skill r))
                               records)))))))

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
  "Install both consumers on enable and remove them on disable."
  (let ((agent-skill-invocation-functions nil)
        (agent-session-id-functions nil))
    (unwind-protect
        (progn
          (agent-skill-mode 1)
          (should (memq #'agent-skill--record
                        agent-skill-invocation-functions))
          (should (memq #'agent-skill--note-session-id
                        agent-session-id-functions)))
      (agent-skill-mode -1))
    (should-not (memq #'agent-skill--record agent-skill-invocation-functions))
    (should-not (memq #'agent-skill--note-session-id
                      agent-session-id-functions))))

(ert-deftest agent-skill-test-session-records-reach-the-live-list ()
  "Track every session-mode record, whatever emitted it."
  (agent-skill-test--with-history
    (with-temp-buffer
      (let ((session (current-buffer)))
        (agent-skill--record (list :id "one" :skill "update-log"
                                   :origin 'before-exit :mode 'session
                                   :buffer session :outcome 'dispatched))
        (agent-skill--record (list :id "two" :skill "demo"
                                   :origin 'run-skill :mode 'batch
                                   :outcome 'dispatched))
        (should (equal '("update-log")
                       (mapcar (lambda (r) (plist-get r :skill))
                               (buffer-local-value 'agent-skill--applied
                                                   session))))))))

(ert-deftest agent-skill-test-late-session-id-is-correlated ()
  "Append a correlation record once the native session id arrives."
  (agent-skill-test--with-history
    (with-temp-buffer
      (let ((session (current-buffer))
            (identity (agent-session-create :backend 'claude-code
                                            :directory "/tmp/")))
        (setq-local agent--session identity)
        (agent-skill--record (list :id "one" :skill "demo" :origin 'bundle
                                   :mode 'session :buffer session
                                   :outcome 'dispatched))
        (should-not (alist-get 'id (alist-get 'session
                                              (car (plist-get
                                                    (agent-skill-history-read)
                                                    :records)))))
        (setf (agent-session-id identity) "sess-42")
        (agent-skill--note-session-id session)
        (let ((newest (car (plist-get (agent-skill-history-read) :records))))
          (should (equal "session-id" (alist-get 'event newest)))
          (should (equal "one" (alist-get 'id newest)))
          (should (equal "sess-42" (alist-get 'id (alist-get 'session
                                                             newest)))))
        ;; A second notification for the same id appends nothing.
        (agent-skill--note-session-id session)
        (should (= 2 (plist-get (agent-skill-history-read) :total)))))))
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
The oversized file is renamed to `FILE.TIMESTAMP', a name proven
unused; nothing is ever overwritten or removed, and
`agent-skill-history-read' reads rotated files as part of the history.
Set to nil to never roll over."
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
     (list (cons 'event (or (plist-get record :event) "invocation"))
           (cons 'time (format-time-string
                        "%FT%T%z"
                        (seconds-to-time (or (plist-get record :time)
                                             (float-time))))))
     (agent-skill--json-plist
      record
      '((id . :id) (skill . :skill) (origin . :origin) (mode . :mode)
        (backend . :backend) (args . :args) (bundle . :bundle)
        (step . :step) (steps . :steps) (directory . :directory)
        (outcome . :outcome) (skipped_reason . :skipped-reason)
        (error . :error)))
     (list (cons 'session (agent-skill--session-json
                           (plist-get record :buffer)))
           (cons 'source (if source
                             (agent-skill--json-plist
                              source agent-skill--source-json-keys)
                           :null))))))

(defun agent-skill--history-stamp ()
  "Return the timestamp component of a rotated history file name."
  (format-time-string "%Y%m%dT%H%M%S"))

(defun agent-skill--rotated-history-files ()
  "Return the rotated history files, newest first."
  (let* ((file agent-skill-history-file)
         (directory (file-name-directory file))
         (prefix (concat (file-name-nondirectory file) ".")))
    (when (file-directory-p directory)
      (sort (cl-remove-if-not
             (lambda (path)
               (string-prefix-p prefix (file-name-nondirectory path)))
             (directory-files directory t "\\`[^.]"))
            #'string>))))

(defun agent-skill--rotate-history ()
  "Roll `agent-skill-history-file' over when it exceeds its size limit.
Rename it to a timestamped name proven unused.  Nothing is overwritten
and nothing is removed: rotated files stay part of the history."
  (when (and agent-skill-history-max-bytes
             (file-exists-p agent-skill-history-file)
             (> (or (file-attribute-size
                     (file-attributes agent-skill-history-file))
                    0)
                agent-skill-history-max-bytes))
    (let* ((stamp (agent-skill--history-stamp))
           (target (format "%s.%s" agent-skill-history-file stamp))
           (counter 1))
      (while (file-exists-p target)
        (setq target (format "%s.%s-%d" agent-skill-history-file
                             stamp counter)
              counter (1+ counter)))
      (rename-file agent-skill-history-file target))))

(defun agent-skill--append (record)
  "Append RECORD to `agent-skill-history-file'."
  (make-directory (file-name-directory agent-skill-history-file) t)
  (agent-skill--rotate-history)
  (write-region (concat (json-serialize (agent-skill--record-json record))
                        "\n")
                nil agent-skill-history-file t 'no-message))

(defvar-local agent-skill--applied nil
  "Invocation records dispatched into this session buffer, newest last.
Maintained by `agent-skill-mode'.  This dies with the buffer by design;
the durable copy is `agent-skill-history-file'.")

(defun agent-skill--track-in-session (record)
  "Add RECORD to its session buffer's `agent-skill--applied' list."
  (when-let* (((eq 'session (plist-get record :mode)))
              (buffer (plist-get record :buffer))
              ((buffer-live-p buffer)))
    (with-current-buffer buffer
      (setq agent-skill--applied
            (append agent-skill--applied (list record))))))

(defun agent-skill--record (record)
  "Append RECORD to the history and track it against its session.
Member of `agent-skill-invocation-functions' while `agent-skill-mode'
is enabled."
  (agent-skill--append record)
  (agent-skill--track-in-session record))

(defvar-local agent-skill--session-id-noted nil
  "Alist of (INVOCATION-ID . SESSION-ID) already correlated in history.")

(defun agent-skill--note-session-id (buffer)
  "Correlate BUFFER's records with its now-known native session id.
Member of `agent-session-id-functions' while `agent-skill-mode' is
enabled.  A session dispatched into at startup has no native id yet, so
its records name none; when the backend reports one, append a
`session-id' record per invocation rather than rewriting history.  Each
\(invocation, session id) pair is appended once, so a re-reported id
adds nothing and a genuinely changed id — a branch switch, say — adds a
fresh correlation."
  (when-let* (((buffer-live-p buffer))
              (session (agent-session buffer))
              (id (agent-session-id session)))
    (with-current-buffer buffer
      (dolist (record agent-skill--applied)
        (let ((invocation (plist-get record :id)))
          (unless (equal id (cdr (assoc invocation
                                        agent-skill--session-id-noted)))
            (agent-skill--append (list :event "session-id"
                                       :id invocation
                                       :buffer buffer))
            (setf (alist-get invocation agent-skill--session-id-noted
                             nil nil #'equal)
                  id)))))))

;;;###autoload
(define-minor-mode agent-skill-mode
  "Record skill invocations and track what each live session was given.
Bundles, provenance, and the health check work without this mode; the
durable history in `agent-skill-history-file' and
`agent-skill-describe-session' depend on it."
  :global t
  :group 'agent-skill
  (cond
   (agent-skill-mode
    (add-hook 'agent-skill-invocation-functions #'agent-skill--record)
    (add-hook 'agent-session-id-functions #'agent-skill--note-session-id))
   (t
    (remove-hook 'agent-skill-invocation-functions #'agent-skill--record)
    (remove-hook 'agent-session-id-functions
                 #'agent-skill--note-session-id))))
```

- [ ] **Step 4: Implement the reader**

Append to the same section:

```elisp
(defun agent-skill--history-lines (file)
  "Return FILE's non-empty lines in order, or nil.
`split-string' is used rather than a buffer walk because a final line
with no trailing newline — which is exactly what a truncated write
leaves — is skipped by `forward-line' and would silently disappear."
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (split-string (buffer-string) "\n" t "[ \t\r]+"))))

(defun agent-skill-history-read (&optional limit)
  "Return recorded invocations, newest first.
LIMIT bounds how many are returned.  Rotated history files are read
after the current one, newest rotation first, so rotation never hides
history.  The result is a plist with `:records' (alists as stored),
`:total' (records returned), `:unparsable' (lines that were not valid
JSON) and `:files' (the files actually read).  A missing history file
yields an empty result, not an error."
  (let ((records nil)
        (unparsable 0)
        (read-files nil))
    (catch 'done
      (dolist (file (cons agent-skill-history-file
                          (agent-skill--rotated-history-files)))
        (when-let* ((lines (agent-skill--history-lines file)))
          (push file read-files)
          (dolist (line (nreverse lines))
            (condition-case nil
                (push (json-parse-string line
                                         :object-type 'alist
                                         :null-object nil
                                         :false-object nil)
                      records)
              (error (setq unparsable (1+ unparsable))))
            (when (and limit (>= (length records) limit))
              (throw 'done nil))))))
    (list :records (nreverse records)
          :total (length records)
          :unparsable unparsable
          :files (nreverse read-files))))
```

Each file's lines are reversed before being pushed, so within a file the
newest record is pushed first and the final `nreverse` restores
newest-first across the whole result.  A malformed line counts even when
it is an unterminated tail, which is the case a backwards buffer walk
loses.

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

(ert-deftest agent-skill-test-bundle-validator-rejects-bad-shapes ()
  "Refuse unknown keys and wrongly typed fields, naming what is wrong."
  (dolist (bundle '((:skills ("a") :colour "blue")
                    (:skills "a")
                    (:skills ("a") :description 42)
                    (:skills ("a") :backends "claude-code")
                    (:skills (("a" :args 42)))
                    (:skills (("a" :unknown t)))))
      (should-error (agent-skill-validate-bundle "x" bundle)
                    :type 'user-error)))

(ert-deftest agent-skill-test-bundle-validator-accepts-a-good-bundle ()
  "Accept every documented key and shape."
  (should (agent-skill-validate-bundle
           "x" '(:description "d" :instruction "i"
                 :backends (claude-code codex)
                 :skills ("a" ("b" :args "--accept" :optional t))))))

(ert-deftest agent-skill-test-resolve-bundle-validates-first ()
  "Reject a malformed bundle before touching skill discovery."
  (let ((agent-skill-bundles '(("x" :skills ("pr-audit") :colour "blue"))))
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

(defconst agent-skill--bundle-keys
  '(:description :instruction :backends :skills)
  "Keys a bundle plist may carry.")

(defconst agent-skill--bundle-entry-keys '(:args :optional)
  "Keys a bundle skill entry may carry.")

(defun agent-skill--bundle-entry (entry bundle-name)
  "Return ENTRY of bundle BUNDLE-NAME as a (NAME . PLIST) cons.
Signal a `user-error' when ENTRY has no recognized shape."
  (cond
   ((stringp entry) (cons entry nil))
   ((and (consp entry) (stringp (car entry)) (listp (cdr entry)))
    (cons (car entry) (cdr entry)))
   (t (user-error "Bundle `%s' has a malformed skill entry: %S"
                  bundle-name entry))))

(defun agent-skill-validate-bundle (name bundle)
  "Return t when BUNDLE named NAME is well formed, else signal a `user-error'.
Every caller validates through this one function, so the resolver and
the health check cannot disagree about what a valid bundle is.  A
mistyped key is a `user-error' naming the key rather than a bundle that
half works."
  (unless (and (listp bundle) (cl-evenp (length bundle)))
    (user-error "Bundle `%s' is not a plist" name))
  (let ((rest bundle))
    (while rest
      (unless (memq (car rest) agent-skill--bundle-keys)
        (user-error "Bundle `%s' has unknown key `%S' (expected one of %s)"
                    name (car rest)
                    (mapconcat #'symbol-name agent-skill--bundle-keys ", ")))
      (setq rest (cddr rest))))
  (dolist (key '(:description :instruction))
    (let ((value (plist-get bundle key)))
      (when (and value (not (stringp value)))
        (user-error "Bundle `%s' key `%S' must be a string" name key))))
  (let ((backends (plist-get bundle :backends)))
    (unless (and (listp backends) (cl-every #'symbolp backends))
      (user-error "Bundle `%s' key `:backends' must be a list of symbols"
                  name)))
  (let ((skills (plist-get bundle :skills)))
    (unless (and skills (listp skills))
      (user-error "Bundle `%s' must list at least one skill" name))
    (dolist (entry skills)
      (let* ((parsed (agent-skill--bundle-entry entry name))
             (options (cdr parsed))
             (rest options))
        (unless (cl-evenp (length options))
          (user-error "Bundle `%s' entry `%s' has an odd option list"
                      name (car parsed)))
        (while rest
          (unless (memq (car rest) agent-skill--bundle-entry-keys)
            (user-error "Bundle `%s' entry `%s' has unknown option `%S'"
                        name (car parsed) (car rest)))
          (setq rest (cddr rest)))
        (let ((args (plist-get options :args)))
          (when (and args (not (stringp args)))
            (user-error "Bundle `%s' entry `%s' option `:args' must be \
a string"
                        name (car parsed)))))))
  t)

(defun agent-skill--bundle-backend-ok-p (bundle backend)
  "Return non-nil when BUNDLE applies to BACKEND."
  (let ((backends (plist-get bundle :backends)))
    (or (null backends) (memq backend backends))))

(defun agent-skill-resolve-bundle (name backend)
  "Resolve bundle NAME against the skills BACKEND can discover.
Return an ordered list of step plists carrying `:name', `:args',
`:optional', `:skill' (the discovered plist), `:source' (provenance)
and, for an optional step whose skill is missing, `:skipped' (a reason
string).  Signal a `user-error' when the bundle is malformed, when it
does not apply to BACKEND, or when a required skill is not
discoverable — a bundle that runs half of itself is worse than one
that refuses.

Discovery reads project-relative roots, so callers bind
`default-directory' to the target session's directory first."
  (let ((bundle (agent-skill-bundle name)))
    (agent-skill-validate-bundle name bundle)
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

Append to `test/agent-test.el`.  Setting `symbol-function` to nil makes
`fboundp` false, which is how the three fallback tests stay correct
whether or not the composer plan (which defines
`agent-session-ready-to-submit-p`) has landed:

```elisp
;;;; Dispatch helpers

(defmacro agent-test--without-readiness-probe (&rest body)
  "Run BODY with `agent-session-ready-to-submit-p' unbound."
  (declare (indent 0))
  `(cl-letf (((symbol-function 'agent-session-ready-to-submit-p) nil))
     ,@body))

(ert-deftest agent-test-ensure-dispatch-target-refuses-a-busy-session ()
  "Name the busy state instead of submitting into a running turn."
  (with-temp-buffer
    (let ((buffer (current-buffer)))
      (agent-test--without-readiness-probe
        (cl-letf (((symbol-function 'agent-session-display-state)
                   (lambda (&rest _) 'busy))
                  ((symbol-function 'agent-display-name)
                   (lambda (&rest _) "demo")))
          (should-error (agent-ensure-dispatch-target buffer)
                        :type 'user-error))))))

(ert-deftest agent-test-ensure-dispatch-target-confirms-unknown ()
  "Ask before sending to a session whose state is unknown."
  (with-temp-buffer
    (let ((buffer (current-buffer))
          (asked nil))
      (agent-test--without-readiness-probe
        (cl-letf (((symbol-function 'agent-session-display-state)
                   (lambda (&rest _) 'unknown))
                  ((symbol-function 'agent-display-name)
                   (lambda (&rest _) "demo"))
                  ((symbol-function 'yes-or-no-p)
                   (lambda (_prompt) (setq asked t) nil)))
          (should-error (agent-ensure-dispatch-target buffer)
                        :type 'user-error)
          (should asked))))))

(ert-deftest agent-test-ensure-dispatch-target-accepts-a-waiting-session ()
  "Return the buffer when the session is waiting for input."
  (with-temp-buffer
    (let ((buffer (current-buffer)))
      (agent-test--without-readiness-probe
        (cl-letf (((symbol-function 'agent-session-display-state)
                   (lambda (&rest _) 'waiting)))
          (should (eq buffer (agent-ensure-dispatch-target buffer))))))))

(ert-deftest agent-test-ensure-dispatch-target-prefers-the-readiness-probe ()
  "Refuse a session the authoritative probe calls busy, however it displays.
A session stopped at a permission dialog displays as `waiting'; the
queue project's probe is the only thing that knows better, so when it
exists it wins."
  (with-temp-buffer
    (let ((buffer (current-buffer)))
      (cl-letf (((symbol-function 'agent-session-display-state)
                 (lambda (&rest _) 'waiting))
                ((symbol-function 'agent-display-name)
                 (lambda (&rest _) "demo"))
                ((symbol-function 'agent-session-ready-to-submit-p)
                 (lambda (&rest _) 'busy)))
        (should-error (agent-ensure-dispatch-target buffer)
                      :type 'user-error)))))

(ert-deftest agent-test-ensure-dispatch-target-confirms-probe-unknown ()
  "Ask when the authoritative probe reports an unknown state."
  (with-temp-buffer
    (let ((buffer (current-buffer))
          (asked nil))
      (cl-letf (((symbol-function 'agent-session-display-state)
                 (lambda (&rest _) 'waiting))
                ((symbol-function 'agent-display-name)
                 (lambda (&rest _) "demo"))
                ((symbol-function 'agent-session-ready-to-submit-p)
                 (lambda (&rest _) 'unknown))
                ((symbol-function 'yes-or-no-p)
                 (lambda (_prompt) (setq asked t) t)))
        (should (eq buffer (agent-ensure-dispatch-target buffer)))
        (should asked)))))

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
(defun agent--dispatch-readiness (buffer)
  "Return `ready', `busy', or `unknown' for session BUFFER.
Prefer `agent-session-ready-to-submit-p' when it exists: the display
state cannot see a session stopped at a permission dialog, which
displays as `waiting' while a submission would be typed into the
dialog.  Fall back to `agent-session-display-state', whose waiting
states are the best answer available without that probe."
  (if (fboundp 'agent-session-ready-to-submit-p)
      (pcase (agent-session-ready-to-submit-p buffer)
        ('ready 'ready)
        ('unknown 'unknown)
        (_ 'busy))
    (pcase (agent-session-display-state buffer)
      ('busy 'busy)
      ('unknown 'unknown)
      (_ 'ready))))

(defun agent-ensure-dispatch-target (buffer)
  "Return BUFFER after checking it can accept a submitted prompt now.
Signal a `user-error' when the session cannot start a fresh turn: no
queue exists, so a submission mid-turn would land wherever the CLI
happens to put it, and a submission into a permission dialog would put
words in the user's mouth.  An `unknown' state is confirmed explicitly
rather than assumed idle."
  (unless (buffer-live-p buffer)
    (user-error "That session buffer is gone"))
  (pcase (agent--dispatch-readiness buffer)
    ('busy
     (user-error "%s cannot take input right now; wait for it to finish"
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
  "Report the bundle steps dispatched into a session buffer.
The applied list is maintained by `agent-skill-mode', so the mode is on
for this test."
  (agent-skill-test--with-history
    (let ((agent-skill-bundles '(("x" :skills ("pr-audit"))))
          (agent-skill-bundle-confirm nil)
          (agent-skill-invocation-functions nil)
          (agent-session-id-functions nil))
      (with-temp-buffer
        (let ((session (current-buffer)))
          (unwind-protect
              (progn
                (agent-skill-mode 1)
                (agent-skill-test--with-skills agent-skill-test--skills
                  (cl-letf (((symbol-function 'agent--resolve-backend)
                             (lambda () 'claude-code))
                            ((symbol-function 'agent-read-dispatch-target)
                             (lambda (&rest _) session))
                            ((symbol-function 'agent-dispatch-prompt)
                             (lambda (_text target &rest _) target)))
                    (agent-skill-run-bundle "x"))))
            (agent-skill-mode -1))
          (should (= 1 (length (buffer-local-value 'agent-skill--applied
                                                   session)))))))))

(ert-deftest agent-skill-test-run-bundle-resolves-in-the-target-directory ()
  "Discover skills where the target session lives, not where we stand.
A bundle run from a buffer in project A into a session in project B
must see project B's skills."
  (let ((agent-skill-bundles '(("x" :skills ("pr-audit"))))
        (agent-skill-record-git-provenance nil)
        (agent-skill-bundle-confirm nil)
        (seen nil))
    (with-temp-buffer
      (setq-local default-directory "/tmp/project-a/")
      (let ((session (current-buffer)))
        (cl-letf (((symbol-function 'agent-discover-skills)
                   (lambda (_backend)
                     (push default-directory seen)
                     agent-skill-test--skills))
                  ((symbol-function 'agent--detect-backend)
                   (lambda (&rest _) 'claude-code))
                  ((symbol-function 'agent-session)
                   (lambda (&rest _)
                     (agent-session-create :backend 'claude-code
                                           :directory "/tmp/project-b/")))
                  ((symbol-function 'agent-read-dispatch-target)
                   (lambda (&rest _) session))
                  ((symbol-function 'agent-dispatch-prompt)
                   (lambda (_text target &rest _) target)))
          (agent-skill-run-bundle "x"))
        (should (member "/tmp/project-b/" seen))
        (should-not (member "/tmp/project-a/" seen))))))

(ert-deftest agent-skill-test-run-bundle-refuses-a-changed-skill ()
  "Abort when a skill changed between the preview and the submission."
  (agent-skill-test--with-skill skill
    (let ((agent-skill-bundles '(("x" :skills ("demo"))))
          (agent-skill-record-git-provenance nil)
          (agent-skill-bundle-confirm nil)
          (sent nil))
      (cl-letf (((symbol-function 'agent-discover-skills)
                 (lambda (_backend) (list skill)))
                ((symbol-function 'agent--resolve-backend)
                 (lambda () 'claude-code))
                ((symbol-function 'agent-read-dispatch-target)
                 (lambda (&rest _) 'new))
                ((symbol-function 'agent-skill--target-directory)
                 (lambda (&rest _) "/tmp/"))
                ((symbol-function 'y-or-n-p)
                 (lambda (_prompt)
                   ;; Stand in for the user editing the skill while the
                   ;; preview is on screen.
                   (with-temp-file (plist-get skill :path)
                     (insert "---\nname: demo\n---\nEdited\n"))
                   t))
                ((symbol-function 'agent-dispatch-prompt)
                 (lambda (&rest _) (setq sent t) (current-buffer))))
        (should-error (agent-skill-run-bundle "x") :type 'user-error)
        (should-not sent)))))

(ert-deftest agent-skill-test-run-bundle-records-skipped-steps ()
  "Record an optional missing step as `skipped' with a reason."
  (let* ((agent-skill-bundles
          '(("x" :skills ("pr-audit" ("absent" :optional t)))))
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
                ((symbol-function 'agent-skill--target-directory)
                 (lambda (&rest _) "/tmp/"))
                ((symbol-function 'y-or-n-p) (lambda (_prompt) t))
                ((symbol-function 'agent-dispatch-prompt)
                 (lambda (&rest _) (current-buffer))))
        (agent-skill-run-bundle "x")))
    (let ((skipped (cl-find 'skipped (nreverse records)
                            :key (lambda (r) (plist-get r :outcome)))))
      (should skipped)
      (should (equal "absent" (plist-get skipped :skill)))
      (should (stringp (plist-get skipped :skipped-reason))))))
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

(defun agent-skill--target-directory (target)
  "Return the directory bundle resolution and dispatch should use.
For a live TARGET it is that session's directory; for a new session the
user picks one, defaulting to the current project root.  Skill
discovery reads project-relative roots such as `.claude/skills', so
resolving in the caller's directory would offer the caller's project
skills to a session running somewhere else."
  (if (bufferp target)
      (or (when-let* ((session (agent-session target)))
            (agent-session-directory session))
          (buffer-local-value 'default-directory target))
    (read-directory-name
     "Start the new session in: "
     (or (when-let* ((project (project-current))) (project-root project))
         default-directory))))

(defun agent-skill--revalidate (steps)
  "Re-resolve provenance for STEPS and return them updated.
Signal a `user-error' naming the file when a skill changed since it was
previewed: the preview promised particular bytes, and the message is
about to point the CLI at whatever is on disk now."
  (mapcar
   (lambda (step)
     (if (plist-get step :skipped)
         step
       (let* ((before (plist-get step :source))
              (after (agent-skill-provenance (plist-get step :skill))))
         (when (agent-skill-provenance-changed-p before after)
           (user-error "Skill `%s' changed since the preview (%s); \
run the bundle again"
                       (plist-get step :name)
                       (or (plist-get after :path) "unknown path")))
         (plist-put (copy-sequence step) :source after))))
   steps))

(defun agent-skill--note-steps (name steps buffer backend directory)
  "Record one invocation per step of bundle NAME.
STEPS are the resolved steps, BUFFER the session they were sent to,
BACKEND its backend and DIRECTORY the directory they targeted.  Skipped
steps get a record too, with outcome `skipped' and a reason: a bundle
that quietly ran fewer skills than its name implies is exactly what the
history exists to make visible.  `agent-skill-mode' is what turns these
records into history entries and into BUFFER's applied list."
  (let* ((live (agent-skill--bundle-steps steps))
         (total (length live))
         (index 0))
    (dolist (step steps)
      (let ((skipped (plist-get step :skipped)))
        (unless skipped (setq index (1+ index)))
        (agent-note-skill-invocation
         (append
          (list :skill (plist-get step :name)
                :origin 'bundle :mode 'session
                :backend backend
                :bundle name
                :args (plist-get step :args)
                :buffer buffer
                :directory directory
                :path (plist-get (plist-get step :source) :path)
                :root (plist-get (plist-get step :source) :root)
                :style (plist-get (plist-get step :source) :style)
                :source (plist-get step :source))
          (if skipped
              (list :outcome 'skipped :skipped-reason skipped)
            (list :outcome 'dispatched :step index :steps total))))))))

;;;###autoload
(defun agent-skill-run-bundle (&optional name)
  "Dispatch the skills of bundle NAME into one session.
Read NAME and a target when they are not supplied, resolve every step
against the skills the target's own directory makes discoverable, show
what will be sent, re-check that nothing changed while the preview was
up, and submit it as a single message.  Nothing is sent and nothing is
recorded unless every step resolves and the dispatch succeeds."
  (interactive)
  (let* ((name (or name (agent-skill--read-bundle-name)))
         (target (agent-read-dispatch-target
                  (format "Run bundle `%s' in: " name)))
         (backend (if (bufferp target)
                      (agent--detect-backend target)
                    (agent--resolve-backend)))
         (directory (agent-skill--target-directory target))
         (steps (let ((default-directory directory))
                  (agent-skill-resolve-bundle name backend)))
         (count (length (agent-skill--bundle-steps steps)))
         (message-text (agent-skill-bundle-message name steps))
         (preview (when agent-skill-bundle-confirm
                    (agent-skill--preview name steps target message-text))))
    (unwind-protect
        (unless (y-or-n-p (format "Send bundle `%s' (%d skill%s)? "
                                  name count (if (= 1 count) "" "s")))
          (user-error "Aborted"))
      (when (buffer-live-p preview)
        (quit-windows-on preview t)))
    (let* ((checked (let ((default-directory directory))
                      (agent-skill--revalidate steps)))
           (buffer (agent-dispatch-prompt message-text target
                                          :backend backend
                                          :directory directory)))
      (agent-skill--note-steps name checked buffer backend directory)
      (message "Dispatched bundle %s (%d skill%s) to %s"
               name count (if (= 1 count) "" "s")
               (if (buffer-live-p buffer)
                   (agent-display-name buffer)
                 "the new session"))
      buffer)))

;;;###autoload
(defun agent-skill-describe-session (&optional buffer)
  "Show which skills were dispatched into session BUFFER, and from where.
The list is kept by `agent-skill-mode'; with the mode off nothing is
tracked, and this says so rather than reporting an empty session as a
session that was given nothing."
  (interactive)
  (let* ((session (agent--resolve-session-buffer buffer))
         (records (buffer-local-value 'agent-skill--applied session))
         (report (get-buffer-create "*Agent session skills*")))
    (with-current-buffer report
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "Skills dispatched into %s\n\n"
                        (agent-display-name session)))
        (unless agent-skill-mode
          (insert "agent-skill-mode is off; nothing is being tracked.\n\n"))
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

(ert-deftest agent-skill-test-check-reports-an-invalid-bundle ()
  "Report a bundle with an unknown key, even with no backend registered."
  (let ((agent-backends nil)
        (agent-skill-bundles '(("x" :skills ("a") :colour "blue"))))
    (let ((issue (cl-find-if
                  (lambda (i) (string-match-p "invalid" (plist-get i :issue)))
                  (agent-skill-check-issues))))
      (should issue)
      (should (eq 'error (plist-get issue :severity)))
      (should (string-match-p "colour" (plist-get issue :detail))))))

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
  "Return the issues found in `agent-skill-bundles'.
Every bundle is validated once, whether or not any backend is
registered, and then resolved against each backend it claims."
  (let ((issues nil))
    (pcase-dolist (`(,name . ,bundle) agent-skill-bundles)
      (condition-case err
          (progn
            (agent-skill-validate-bundle name bundle)
            (dolist (backend (or (plist-get bundle :backends)
                                 (mapcar #'car agent-backends)))
              (condition-case resolve-err
                  (agent-skill-resolve-bundle name backend)
                (user-error
                 (push (agent-skill--issue
                        'error backend name "bundle cannot be resolved"
                        (error-message-string resolve-err))
                       issues)))))
        (user-error
         (push (agent-skill--issue
                'error nil name "bundle definition is invalid"
                (error-message-string err))
               issues))))
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
                                    (if-let* ((backend (plist-get issue
                                                                  :backend)))
                                        (symbol-name backend)
                                      "—")
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

(ert-deftest agent-learn-test-parse-file-without-candidates-is-an-error ()
  "Report a free-prose capture as a problem, not as an empty file.
The real inbox contains such files; listing them as empty would hide
them forever."
  (let ((file (make-temp-file "agent-learn" nil ".md"
                              "# Some older note\n\nProse only.\n")))
    (unwind-protect
        (let ((parsed (agent-learn-parse-file file)))
          (should (string-match-p "no candidate section"
                                  (plist-get parsed :error))))
      (delete-file file))))

(ert-deftest agent-learn-test-parse-accepts-legacy-heading-shapes ()
  "Accept `### Candidate N:' and unnumbered `## Candidate:' headings.
Both occur in the real corpus."
  (let ((file (make-temp-file
               "agent-learn" nil ".md"
               (concat "# Header\n\n"
                       "### Candidate 1: Numbered h3\n\n"
                       "**Value:** 10/100\n\n"
                       "## Candidate: Unnumbered\n\n"
                       "**Value:** 20/100\n"))))
    (unwind-protect
        (let ((candidates (plist-get (agent-learn-parse-file file)
                                     :candidates)))
          (should (= 2 (length candidates)))
          (should (equal "Numbered h3" (plist-get (nth 0 candidates) :title)))
          (should (= 1 (plist-get (nth 0 candidates) :index)))
          (should (equal "Unnumbered" (plist-get (nth 1 candidates) :title)))
          (should (= 2 (plist-get (nth 1 candidates) :index))))
      (delete-file file))))

(ert-deftest agent-learn-test-parse-ignores-a-heading-inside-a-fence ()
  "Do not split a candidate at a heading quoted inside a patch."
  (let ((file (make-temp-file
               "agent-learn" nil ".md"
               (concat "# Header\n\n"
                       "## Candidate 1: Real\n\n"
                       "**Proposed patch:**\n\n"
                       "```markdown\n"
                       "## Candidate 2: Not real\n"
                       "```\n"))))
    (unwind-protect
        (let ((candidates (plist-get (agent-learn-parse-file file)
                                     :candidates)))
          (should (= 1 (length candidates)))
          (should (equal "Real" (plist-get (car candidates) :title))))
      (delete-file file))))

(ert-deftest agent-learn-test-review-outside-the-managed-block-is-ignored ()
  "Only the block directly after the heading decides the state.
A model-authored `**Review:**' further down must not approve itself."
  (let ((file (make-temp-file
               "agent-learn" nil ".md"
               (concat "# Header\n\n"
                       "## Candidate 1: Sneaky\n\n"
                       "**Summary:** Something.\n\n"
                       "**Review:** approved 2026-07-31 — by myself\n"))))
    (unwind-protect
        (let ((candidate (car (plist-get (agent-learn-parse-file file)
                                         :candidates))))
          (should (eq 'pending (plist-get candidate :state)))
          (should (plist-get candidate :stray-review)))
      (delete-file file))))

(ert-deftest agent-learn-test-only-the-first-review-line-counts ()
  "A duplicate review line later in the candidate changes nothing."
  (let ((file (make-temp-file
               "agent-learn" nil ".md"
               (concat "# Header\n\n"
                       "## Candidate 1: Two reviews\n\n"
                       "**Review:** rejected 2026-07-30 — no\n\n"
                       "**Summary:** Something.\n\n"
                       "**Review:** approved 2026-07-31 — yes\n"))))
    (unwind-protect
        (let ((candidate (car (plist-get (agent-learn-parse-file file)
                                         :candidates))))
          (should (eq 'rejected (plist-get candidate :state)))
          (should (plist-get candidate :stray-review)))
      (delete-file file))))

(ert-deftest agent-learn-test-parses-the-real-corpus-shape ()
  "Parse a real inbox file when one is configured and present.
Read-only: this only proves the parser matches the corpus it was
measured against.  Skipped when no real inbox is configured."
  (let* ((inbox (expand-file-name "inbox" agent-learn-directory))
         (files (and (file-directory-p inbox)
                     (directory-files inbox t "\\.md\\'"))))
    (skip-unless files)
    (let ((parsed (mapcar #'agent-learn-parse-file
                          (take 50 (nreverse (sort files #'string<))))))
      (should (< (cl-count-if (lambda (p) (plist-get p :error)) parsed)
                 (length parsed))))))

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
  "^#\\{2,3\\} Candidate\\(?: \\([0-9]+\\)\\)?: \\(.*\\)$"
  "Regexp matching a candidate heading.
Measured against the real corpus, 1133 of 1137 files use `## Candidate
N:'; the rest use `### Candidate N:' or `## Candidate:' with no number.
All three are accepted, and a file matching none of them becomes a
problem row rather than an empty result.")

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

(defun agent-learn--file-sha1 (file)
  "Return the SHA-1 of FILE's raw bytes, or nil when it cannot be read.
Recorded on every candidate at parse time; the writer compares it before
editing so a file that changed underneath is refused rather than
half-rewritten."
  (when (file-readable-p file)
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally file)
      (secure-hash 'sha1 (buffer-string)))))

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

(defun agent-learn--managed-text (text)
  "Return the managed block at the start of candidate body TEXT.
The managed block is the run of `**Review:**' and `**Dispatched:**'
paragraphs directly after the heading, and it is the only place review
state is read from.  These files are written by a model; a
`**Review:**' line further down must not be able to mark a candidate
approved."
  (let ((lines (split-string text "\n"))
        (kept nil)
        (started nil)
        (done nil))
    (dolist (line lines)
      (unless done
        (cond
         ((string-match agent-learn--field-regexp line)
          (if (member (string-trim (match-string 1 line))
                      agent-learn--managed-fields)
              (progn (setq started t) (push line kept))
            (setq done t)))
         ((string-match-p "^[ \t]*$" line)
          (when started (push line kept)))
         (started (setq done t))
         (t (setq done t)))))
    (string-join (nreverse kept) "\n")))

(defun agent-learn--parse-candidate (file index title heading text file-sha1)
  "Return the candidate plist for section TEXT.
FILE, INDEX, TITLE, and the literal HEADING line identify it.
FILE-SHA1 is the hash of the file as parsed, which the writer compares
before editing so a file that changed underneath is refused instead of
half-rewritten."
  (let* ((fields (agent-learn--parse-fields text))
         (managed (agent-learn--parse-fields
                   (agent-learn--managed-text
                    (substring text (min (length text)
                                         (1+ (or (string-search "\n" text)
                                                 0)))))))
         (review (agent-learn--parse-review (cdr (assoc "Review" managed))))
         (stray (and (assoc "Review" fields)
                     (not (assoc "Review" managed)))))
    (list :file file
          :index index
          :title title
          :heading heading
          :file-sha1 file-sha1
          :fields fields
          :text text
          :state (if (assoc "Review" managed)
                     (plist-get review :state)
                   'pending)
          :state-text (plist-get review :state-text)
          :review-date (plist-get review :date)
          :review-note (plist-get review :note)
          :stray-review stray
          :dispatched (cdr (assoc "Dispatched" managed)))))

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

(defun agent-learn--candidate-starts ()
  "Return (POSITION INDEX TITLE HEADING) for each candidate heading.
HEADING is the literal heading line, which is what the writer searches
for later: the corpus uses three heading shapes, so reconstructing one
from the index and title would not always find it again.
Headings inside fenced blocks are skipped: a proposed patch can quote a
candidate heading, and treating that as a real one would split a
candidate in half."
  (let ((starts nil)
        (in-fence nil)
        (ordinal 0))
    (goto-char (point-min))
    (while (not (eobp))
      (let ((line (buffer-substring-no-properties
                   (line-beginning-position) (line-end-position))))
        (cond
         ((string-match-p agent-learn--fence-regexp line)
          (setq in-fence (not in-fence)))
         ((and (not in-fence)
               (string-match agent-learn--candidate-regexp line))
          (setq ordinal (1+ ordinal))
          (push (list (line-beginning-position)
                      (if (match-string 1 line)
                          (string-to-number (match-string 1 line))
                        ordinal)
                      (string-trim (match-string 2 line))
                      line)
                starts))))
      (forward-line 1))
    (nreverse starts)))

(defun agent-learn-parse-file (file)
  "Return the candidates and header of learning FILE.
The result is a plist with `:file', `:title', `:transcript',
`:directory', `:captured', `:candidates' and, when the file could not
be read or holds no candidate section, `:error'.  A file that parses to
nothing is reported, not silently listed as empty: the inbox holds
older free-prose captures, and they must stay visible."
  (if (not (file-readable-p file))
      (list :file file :error (format "cannot read %s"
                                      (abbreviate-file-name file)))
    (with-temp-buffer
      (let ((coding-system-for-read 'utf-8))
        (insert-file-contents file))
      (let* ((content (buffer-string))
             (file-sha1 (agent-learn--file-sha1 file))
             (starts (agent-learn--candidate-starts))
             (candidates nil))
        (if (null starts)
            (list :file file
                  :error "no candidate section found (not a capture file?)")
          (let ((bounds (append (mapcar #'car (cdr starts))
                                (list (point-max)))))
            (cl-loop for start in starts
                     for end in bounds
                     do (push (agent-learn--parse-candidate
                               file (nth 1 start) (nth 2 start) (nth 3 start)
                               (buffer-substring-no-properties
                                (car start) end)
                               file-sha1)
                              candidates)))
          (append (list :file file :candidates (nreverse candidates))
                  (agent-learn--parse-header
                   (substring content 0 (min (length content) 2000)))))))))

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

(defun agent-learn-test--bytes (file)
  "Return FILE's raw bytes as a unibyte string."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally file)
    (buffer-string)))

(ert-deftest agent-learn-test-set-review-preserves-every-other-byte ()
  "Change nothing but the managed lines, compared byte for byte.
The fixture contains an em dash, so a decoded-string comparison would
pass even if the write re-encoded the file."
  (agent-learn-test--with-file file
    (let ((before (agent-learn-test--bytes file)))
      (cl-letf (((symbol-function 'format-time-string)
                 (lambda (&rest _) "2026-07-31")))
        (agent-learn-set-review (agent-learn-test--candidate file 1)
                                'approved nil))
      (let* ((after (agent-learn-test--bytes file))
             (inserted (encode-coding-string
                        "**Review:** approved 2026-07-31\n\n" 'utf-8))
             (stripped (replace-regexp-in-string
                        (regexp-quote inserted) "" after nil t)))
        (should (equal before stripped))))))

(ert-deftest agent-learn-test-write-detects-a-changed-file ()
  "Refuse to write when the file changed since the candidate was parsed."
  (agent-learn-test--with-file file
    (let ((candidate (agent-learn-test--candidate file 1)))
      (with-temp-file file
        (insert agent-learn-test--file)
        (insert "\n## Candidate 3: Added behind our back\n"))
      (should-error (agent-learn-set-review candidate 'approved nil)
                    :type 'user-error))))

(ert-deftest agent-learn-test-write-leaves-no-temporary-file ()
  "Clean up after an atomic replacement, successful or not."
  (agent-learn-test--with-file file
    (agent-learn-set-review (agent-learn-test--candidate file 1)
                            'approved nil)
    (should-not (directory-files (file-name-directory file) nil
                                 "\\`\\.agent-learn-"))))

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
Match the literal heading line recorded at parse time, so all three
heading shapes in the corpus are found.  Signal a `user-error' when the
heading is gone: the file may have been rewritten since it was parsed."
  (goto-char (point-min))
  (let ((heading (concat "^" (regexp-quote (plist-get candidate :heading))
                         "$")))
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
unmodified one is reverted afterwards.

Three further protections, because the file is someone else's work
product.  The file's hash must still match the one recorded when the
candidate was parsed, so a file that changed underneath is refused
rather than half-rewritten.  The new text is written to a temporary
file in the same directory and renamed over the original, so an
interrupted write cannot truncate it.  Reading and writing both pin
UTF-8, so a round trip cannot re-encode bytes this package did not
touch."
  (let* ((file (plist-get candidate :file))
         (visiting (get-file-buffer file))
         (expected (plist-get candidate :file-sha1))
         (actual (agent-learn--file-sha1 file)))
    (unless actual
      (user-error "%s is gone" (abbreviate-file-name file)))
    (when (and expected (not (equal expected actual)))
      (user-error "%s changed since it was read; refresh and try again"
                  (abbreviate-file-name file)))
    (when (and visiting (buffer-modified-p visiting))
      (user-error "%s has unsaved changes; save or revert it first"
                  (abbreviate-file-name file)))
    (let ((temp (make-temp-file
                 (expand-file-name ".agent-learn-" (file-name-directory file))
                 nil ".md")))
      (unwind-protect
          (progn
            (with-temp-buffer
              (let ((coding-system-for-read 'utf-8))
                (insert-file-contents file))
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
              (let ((coding-system-for-write 'utf-8-unix))
                (write-region (point-min) (point-max) temp nil 'no-message)))
            (set-file-modes temp (file-modes file))
            (rename-file temp file t)
            (setq temp nil))
        (when (and temp (file-exists-p temp))
          (delete-file temp))))
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
  "Return non-nil when candidate A sorts before candidate B.
Pending first, then higher value, then the newer file, then the earlier
candidate within a file — a total order, so the list does not reshuffle
between refreshes."
  (let ((pending-a (eq 'pending (plist-get a :state)))
        (pending-b (eq 'pending (plist-get b :state)))
        (value-a (agent-learn--candidate-number a "Value"))
        (value-b (agent-learn--candidate-number b "Value"))
        (file-a (file-name-nondirectory (plist-get a :file)))
        (file-b (file-name-nondirectory (plist-get b :file))))
    (cond
     ((not (eq pending-a pending-b)) pending-a)
     ((/= value-a value-b) (> value-a value-b))
     ((not (equal file-a file-b)) (string> file-a file-b))
     (t (< (plist-get a :index) (plist-get b :index))))))

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
        (vector (concat (if (eq 'other (plist-get candidate :state))
                            (or (plist-get candidate :state-text) "other")
                          (symbol-name (plist-get candidate :state)))
                        (if (plist-get candidate :stray-review) " (stray)" ""))
                (or (agent-learn-candidate-field candidate "Value") "")
                (or (agent-learn-candidate-field candidate
                                                 "Implementation safety")
                    "")
                (or (agent-learn-candidate-field candidate "Proposed action")
                    "")
                (or (agent-learn-candidate-field candidate "Project") "")
                (or (plist-get candidate :title) "")
                (or (plist-get candidate :captured)
                    (agent-learn--file-date (plist-get candidate :file))
                    ""))))

(defun agent-learn--file-date (file)
  "Return the leading YYYY-MM-DD of FILE's name, or nil."
  (let ((base (file-name-nondirectory file)))
    (when (string-match "\\`\\([0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}\\)" base)
      (match-string 1 base))))

(defun agent-learn--problem-row (problem)
  "Return the tabulated-list entry for a file-level PROBLEM plist.
Problems get their own row rather than a number in the header line: a
file the parser could not read is the one thing a review must not lose
track of."
  (list problem
        (vector "problem" "" "" ""
                (abbreviate-file-name
                 (file-name-directory (plist-get problem :file)))
                (format "%s — %s"
                        (file-name-nondirectory (plist-get problem :file))
                        (plist-get problem :error))
                (or (agent-learn--file-date (plist-get problem :file)) ""))))

(defun agent-learn-refresh ()
  "Re-read the candidate files into the current buffer."
  (interactive nil agent-learn-mode)
  (let ((result (agent-learn-candidates agent-learn--show-archived)))
    (setq tabulated-list-entries
          (append (mapcar #'agent-learn--problem-row
                          (plist-get result :errors))
                  (mapcar #'agent-learn--row
                          (plist-get result :candidates))))
    (setq header-line-format
          (format "%d candidates and %d problem files from %d of %d files%s"
                  (length (plist-get result :candidates))
                  (length (plist-get result :errors))
                  (plist-get result :files)
                  (plist-get result :total)
                  (if agent-learn--show-archived "  (including archive)" "")))
    (tabulated-list-print t)))

(defun agent-learn--candidate-at-point ()
  "Return the candidate at point, or signal.
A problem row is not a candidate: say so rather than acting on a plist
that has no state to change."
  (let ((entry (tabulated-list-get-id)))
    (cond
     ((null entry) (user-error "No candidate at point"))
     ((plist-get entry :error)
      (user-error "That file could not be parsed: %s"
                  (plist-get entry :error)))
     (t entry))))

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

(ert-deftest agent-learn-test-archive-refuses-a-file-without-candidates ()
  "Never treat a file the parser rejected as fully reviewed."
  (agent-learn-test--with-file file
    (let ((prose (expand-file-name "2026-05-14-prose.md"
                                   (file-name-directory file))))
      (with-temp-file prose (insert "# Just prose\n"))
      (should-not (agent-learn--file-resolved-p prose))
      (should-error (agent-learn-archive-file prose t) :type 'user-error)
      (should (file-exists-p prose)))))

(ert-deftest agent-learn-test-archive-refuses-a-modified-visitor ()
  "Refuse to rename a file out from under unsaved edits."
  (agent-learn-test--with-file file
    (dolist (index '(1 2))
      (agent-learn-set-review (agent-learn-test--candidate file index)
                              'approved nil))
    (let ((buffer (find-file-noselect file)))
      (unwind-protect
          (progn
            (with-current-buffer buffer
              (goto-char (point-max))
              (insert "scratch\n"))
            (should-error (agent-learn-archive-file file) :type 'user-error)
            (should (file-exists-p file)))
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer)))))

(ert-deftest agent-learn-test-archive-retargets-a-clean-visitor ()
  "A clean buffer visiting the file follows it into the archive."
  (agent-learn-test--with-file file
    (dolist (index '(1 2))
      (agent-learn-set-review (agent-learn-test--candidate file index)
                              'approved nil))
    (let ((buffer (find-file-noselect file)))
      (unwind-protect
          (let ((target (agent-learn-archive-file file)))
            (should (equal (file-truename target)
                           (file-truename (buffer-file-name buffer)))))
        (kill-buffer buffer)))))

(ert-deftest agent-learn-test-archive-resolved-moves-nothing-on-refusal ()
  "Preflight the whole bulk set: one bad file archives none of them."
  (agent-learn-test--with-file file
    (let ((other (expand-file-name "2026-05-12-codex-b.md"
                                   (file-name-directory file))))
      (with-temp-file other (insert agent-learn-test--file))
      (dolist (target (list file other))
        (dolist (index '(1 2))
          (agent-learn-set-review (agent-learn-test--candidate target index)
                                  'rejected "no")))
      (let ((buffer (find-file-noselect other)))
        (unwind-protect
            (progn
              (with-current-buffer buffer
                (goto-char (point-max))
                (insert "scratch\n"))
              (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_p) t)))
                (should-error (agent-learn-archive-resolved)
                              :type 'user-error))
              (should (file-exists-p file))
              (should (file-exists-p other)))
          (with-current-buffer buffer (set-buffer-modified-p nil))
          (kill-buffer buffer))))))

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
  "Return non-nil when FILE parsed and every candidate in it has a decision.
A file that failed to parse, or that holds no candidates, is never
resolved: `cl-every' over an empty list is true, and that would make
exactly the files needing a human look the ones that got archived
without one."
  (let* ((parsed (agent-learn-parse-file file))
         (candidates (plist-get parsed :candidates)))
    (and (not (plist-get parsed :error))
         candidates
         (cl-every #'agent-learn--resolved-p candidates))))

(defun agent-learn--check-archivable (file)
  "Signal a `user-error' unless FILE may be archived right now.
Return its parsed form.  A visiting buffer with unsaved changes blocks
the move: renaming the file underneath it would strand those edits."
  (let ((parsed (agent-learn-parse-file file))
        (visiting (get-file-buffer file)))
    (when (plist-get parsed :error)
      (user-error "%s: %s" (abbreviate-file-name file)
                  (plist-get parsed :error)))
    (unless (plist-get parsed :candidates)
      (user-error "%s holds no candidates" (abbreviate-file-name file)))
    (when (and visiting (buffer-modified-p visiting))
      (user-error "%s has unsaved changes; save or revert it first"
                  (abbreviate-file-name file)))
    parsed))

(defun agent-learn--retarget-visitor (file target)
  "Point a clean buffer visiting FILE at TARGET after the rename."
  (when-let* ((visiting (get-file-buffer file)))
    (with-current-buffer visiting
      (set-visited-file-name target t t))))

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
Signal a `user-error' when FILE does not parse, holds no candidates, is
visited by a buffer with unsaved changes, or has a candidate with no
recorded decision — the last only unless FORCE is non-nil, in which
case each such candidate is first marked `archived-unreviewed', so
nothing leaves the inbox undecided.  A clean buffer visiting FILE
follows it to the new path.  The file is renamed, never deleted."
  (let* ((parsed (agent-learn--check-archivable file))
         (unresolved (cl-remove-if #'agent-learn--resolved-p
                                   (plist-get parsed :candidates))))
    (when unresolved
      (unless force
        (user-error "%s has %d candidate%s with no decision"
                    (abbreviate-file-name file)
                    (length unresolved)
                    (if (= 1 (length unresolved)) "" "s")))
      (dolist (candidate unresolved)
        (agent-learn-set-review candidate 'archived-unreviewed nil))))
  (let ((target (agent-learn--archive-target file)))
    (rename-file file target)
    (agent-learn--retarget-visitor file target)
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
      ;; Preflight the whole set before moving anything: a refusal
      ;; halfway through would leave the inbox in a state nobody chose.
      (mapc #'agent-learn--check-archivable files)
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

(ert-deftest agent-learn-test-implement-rechecks-approval-on-disk ()
  "Refuse when the file says the candidate is no longer approved."
  (agent-learn-test--with-file file
    (let ((stale (progn (agent-learn-set-review
                         (agent-learn-test--candidate file 1) 'approved "yes")
                        (agent-learn-test--candidate file 1))))
      (agent-learn-set-review stale 'rejected "changed my mind")
      (let ((sent nil))
        (cl-letf (((symbol-function 'agent-dispatch-prompt)
                   (lambda (&rest _) (setq sent t) (current-buffer))))
          (should-error (agent-learn--implement stale) :type 'user-error))
        (should-not sent)))))

(ert-deftest agent-learn-test-implement-preflights-writability ()
  "Refuse before sending when the record could not be written after."
  (agent-learn-test--with-file file
    (agent-learn-set-review (agent-learn-test--candidate file 2)
                            'approved "yes")
    (let ((sent nil))
      (cl-letf (((symbol-function 'file-writable-p) (lambda (_f) nil))
                ((symbol-function 'agent-dispatch-prompt)
                 (lambda (&rest _) (setq sent t) (current-buffer))))
        (should-error (agent-learn--implement
                       (agent-learn-test--candidate file 2))
                      :type 'user-error))
      (should-not sent))))

(ert-deftest agent-learn-test-implement-reports-a-post-send-write-failure ()
  "Say the prompt was sent but not recorded, rather than reporting failure."
  (agent-learn-test--with-file file
    (agent-learn-set-review (agent-learn-test--candidate file 2)
                            'approved "yes")
    (let ((messages nil))
      (cl-letf (((symbol-function 'agent-read-dispatch-target)
                 (lambda (&rest _) 'new))
                ((symbol-function 'agent-dispatch-prompt)
                 (lambda (&rest _) (current-buffer)))
                ((symbol-function 'agent-display-name)
                 (lambda (&rest _) "Claude agent"))
                ((symbol-function 'agent-learn-note-dispatch)
                 (lambda (&rest _) (error "disk full")))
                ((symbol-function 'message)
                 (lambda (fmt &rest args)
                   (push (apply #'format fmt args) messages))))
        (agent-learn--implement (agent-learn-test--candidate file 2)))
      (should (cl-find-if (lambda (m)
                            (and (string-match-p "Handed" m)
                                 (string-match-p "by hand" m)))
                          messages)))))

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

(defun agent-learn--preflight-dispatch (candidate)
  "Return CANDIDATE re-read from disk, ready to be handed to a session.
Signal a `user-error' unless it is still approved and its record can
still be written.  Both checks happen before anything is sent, because
a message cannot be unsent: approving in one Emacs and rejecting in
another must not send, and neither must a candidate whose file has
since become unwritable."
  (let ((fresh (or (agent-learn--reparse candidate)
                   (user-error "Candidate `%s' is no longer in %s"
                               (plist-get candidate :title)
                               (abbreviate-file-name
                                (plist-get candidate :file))))))
    (unless (eq 'approved (plist-get fresh :state))
      (user-error "Candidate `%s' is %s on disk, not approved"
                  (plist-get fresh :title) (plist-get fresh :state)))
    (let ((file (plist-get fresh :file))
          (visiting (get-file-buffer (plist-get fresh :file))))
      (unless (file-writable-p file)
        (user-error "%s is not writable; the dispatch could not be recorded"
                    (abbreviate-file-name file)))
      (when (and visiting (buffer-modified-p visiting))
        (user-error "%s has unsaved changes; save or revert it first"
                    (abbreviate-file-name file))))
    fresh))

(defun agent-learn--implement (candidate)
  "Dispatch CANDIDATE to a session and record the dispatch."
  (let* ((fresh (agent-learn--preflight-dispatch candidate))
         (prompt (agent-learn-implementation-prompt fresh))
         (target (agent-read-dispatch-target
                  (format "Implement `%s' in: " (plist-get fresh :title))))
         (buffer (agent-dispatch-prompt prompt target))
         (label (if (buffer-live-p buffer)
                    (agent-display-name buffer)
                  "a new session")))
    ;; The prompt is already in the session.  A failure to record it is
    ;; reported as exactly that — not as a failed dispatch, which would
    ;; invite a second send of the same prompt.
    (if (condition-case err
            (progn (agent-learn-note-dispatch fresh label) t)
          (error
           (message "Handed `%s' to %s, but could not record it in %s (%s) \
— add the Dispatched line by hand"
                    (plist-get fresh :title) label
                    (abbreviate-file-name (plist-get fresh :file))
                    (error-message-string err))
           nil))
        (message "Handed `%s' to %s" (plist-get fresh :title) label))
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
(defun agent-test--menu-keys (layout)
  "Return every (KEY . COMMAND) pair found in transient LAYOUT."
  (cond
   ((and (listp layout) (plist-member layout :key))
    (list (cons (plist-get layout :key) (plist-get layout :command))))
   ((vectorp layout)
    (mapcan #'agent-test--menu-keys (append layout nil)))
   ((listp layout) (mapcan #'agent-test--menu-keys layout))))

(defun agent-test--menu-bindings ()
  "Return `agent-menu' key-to-command pairs, from its parsed layout."
  (require 'transient)
  (agent-test--menu-keys (get 'agent-menu 'transient--layout)))

(ert-deftest agent-test-menu-binds-the-new-commands-to-their-keys ()
  "Assert the exact key each new command is bound to.
Checking only that a key resolves would pass on whichever suffix
already owned it."
  (let ((bindings (agent-test--menu-bindings)))
    (dolist (pair '(("b" . agent-skill-run-bundle)
                    ("u" . agent-skill-history)
                    ("k" . agent-skill-check)
                    ("v" . agent-learn)))
      (should (equal (cdr pair) (cdr (assoc (car pair) bindings)))))))

(ert-deftest agent-test-menu-keys-are-unique ()
  "No key in `agent-menu' is bound twice.
The queue plan claims `Q', `L', `I' and `E' and the composer claims
`C'; this catches a collision the moment either lands."
  (let* ((keys (mapcar #'car (agent-test--menu-bindings)))
         (duplicates (cl-remove-duplicates
                      (cl-remove-if (lambda (key) (= 1 (cl-count key keys
                                                                 :test #'equal)))
                                    keys)
                      :test #'equal)))
    (should (equal nil duplicates))))

(ert-deftest agent-test-menu-preserves-neighbouring-entries ()
  "Keep the prompt-capture entries this plan's column edits sit beside."
  (let ((bindings (agent-test--menu-bindings)))
    (should (equal 'agent-capture-prompt (cdr (assoc "p" bindings))))
    (should (equal 'agent-insert-captured-prompt
                   (cdr (assoc "i" bindings))))
    (should (equal 'agent-run-skill (cdr (assoc "s" bindings))))))
```

If `transient--layout` turns out to store suffixes in a shape these
helpers do not walk, print it once with
`(pp (get 'agent-menu 'transient--layout))` and adjust
`agent-test--menu-keys` to match; do not weaken the assertions to
`transient-get-suffix`, which succeeds on whatever suffix already owns
the key.

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

- [ ] **Step 4: Extend the menu additively**

Do **not** retype either column.  The queue plan adds `Q`/`L`/`I`/`E`
to Sessions and the composer adds `C` to Prompts; retyping a column
deletes whichever of those landed first.  Insert three lines into the
Tools column, directly after the existing `("s" "run skill" …)` line:

```elisp
    ("b" "run skill bundle" agent-skill-run-bundle)
    ("u" "skill usage history" agent-skill-history)
    ("k" "check skills" agent-skill-check)
```

Insert one line into the Prompts column, after the existing
`("i" "insert prompt" …)` line, and change that column's header string
from `"Prompts"` to `"Prompts & learning"`:

```elisp
    ("v" "review learnings" agent-learn)
```

`v` rather than `L`: `L` belongs to `agent-queue-list` in the
attention/queue plan.  After editing, confirm the diff touches four
added lines and one changed header:

Run: `git diff --stat agent.el`
Expected: 5 insertions, 1 deletion.

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

- [ ] **Step 5: Live — provenance and history, against a scratch skill root**

Do not dirty a real skill: the dotfiles worktree is durable user data,
and a forgotten uncommitted edit there is a real cost.  Build a
throwaway git-backed root instead:

```bash
scratch=$(mktemp -d)
mkdir -p "$scratch/scratch-demo"
printf -- '---\nname: scratch-demo\ndescription: Scratch skill\n---\nSay hello.\n' \
  > "$scratch/scratch-demo/SKILL.md"
git -C "$scratch" init -q && git -C "$scratch" add -A \
  && git -C "$scratch" -c user.email=t@t -c user.name=t commit -qm init
echo "$scratch"
```

Then, in Emacs, add that directory to
`agent-claude-programmatic-skill-directories` (or the Codex equivalent)
for the session, and:

1. Dispatch a one-step bundle naming `scratch-demo` and confirm the
   history record's `content_sha1` matches `shasum -a 1
   "$scratch/scratch-demo/SKILL.md"`.
2. Append a line to a *reference* file in that directory
   (`"$scratch/scratch-demo/notes.md"`), dispatch again, and confirm
   the record is marked dirty even though `SKILL.md` did not change.
3. Confirm the same dirty marker appears in `agent-skill-history` and
   `agent-skill-describe-session`.
4. Run `agent-run-skill` and `agent-audit-project` once each, and
   confirm each produces a dispatched record followed by an outcome
   record with the same id.
5. Remove the scratch root (`rm -rf "$scratch"`) and the defcustom
   entry.

Then verify the symlink case against the real tree **read-only**:
resolve provenance for one skill under `~/.claude/skills` (via
`agent-skill-check`, which reports uncommitted changes as notes) and
confirm it reports the dotfiles repository and a truthful clean/dirty
state rather than treating every skill as clean.

- [ ] **Step 6: Live — health check**

Run `agent-skill-check` against the real skill tree.  Confirm by
inspection every reported shadowing (two roots really do provide that
name) and every frontmatter complaint.  Any false positive is a bug in
the check, not in the tree.

- [ ] **Step 7: Live — learning review, read-only against the real inbox**

Approval is a human decision about the user's own backlog, and
archiving moves their files.  Neither belongs to an implementer
verifying a feature.  So: **read the real inbox, mutate only copies.**

First, read-only against the real directory.  Set
`agent-learn-directory` to `~/My Drive/dotfiles/.agent-learnings/`,
open `agent-learn`, and confirm:

1. The header states how many of the available files were read
   (roughly 200 of 1137 at the default limit).
2. Candidates show real values, safety scores, projects, and captured
   dates — the `Captured` column comes from the parsed `Captured:`
   line, not the file name.
3. Any file the parser rejects appears as its own `problem` row naming
   the file, and the count of those rows is small (the corpus contains
   about four non-conforming files).
4. `RET` renders a candidate in full, including a fenced patch.

Press nothing that writes: no `a`, `r`, `A`, `i`, or `e` in this pass.
Confirm afterwards with `git -C "$HOME/My Drive/dotfiles" status
--porcelain .agent-learnings` that the working tree is unchanged.

Then mutate copies:

```bash
scratch=$(mktemp -d)
mkdir -p "$scratch/inbox"
cd "$HOME/My Drive/dotfiles/.agent-learnings/inbox" \
  && ls *.md | tail -5 | xargs -I{} cp {} "$scratch/inbox/"
echo "$scratch"
```

Point `agent-learn-directory` at `$scratch` and, on the copies:

5. Approve one candidate and reject another with a reason; confirm with
   `diff` against the originals that only `**Review:**` lines differ.
6. Edit a candidate with `e`, save, and confirm the list refreshes.
7. Archive a fully reviewed file; confirm it moved into
   `archive/YYYY-MM-DD/` and nothing was deleted.
8. Hand one approved candidate to a session with `i`; confirm the
   session receives the prompt with the patch marked unverified and
   that `**Dispatched:**` appears only after the dispatch succeeded.
9. Open a copy in a buffer, modify it without saving, and confirm both
   approving and archiving that file are refused by name.
10. Remove the scratch directory (`rm -rf "$scratch"`) and restore
    `agent-learn-directory`.

- [ ] **Step 8: Confirm the tree is clean**

Every task committed its own work, so there should be nothing left.

Run: `git status --porcelain`
Expected: no output.  If anything is uncommitted, it belongs to the task
that produced it — commit it there with that task's message rather than
in a catch-all commit.

The session log under `logs/` and the "Latest session" section of
`CLAUDE.md` are written by the `update-log` skill when the user asks for
it; this plan does not write them.

