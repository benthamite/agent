# A Small Durable Task Ledger — Design

Revision 3.  Revision 2 was reviewed and eleven blockers remained; this
revision closes them, again without changing the feature.  Four were
reproduced in batch first:

- Reading the decoded text and the conflict token in two passes lets a
  rename between them pair old content with a new token.  A single
  raw-byte read plus `detect-coding-string`/`decode-coding-string`
  reproduces `insert-file-contents`' text and coding exactly and
  round-trips bytes, so the snapshot is now one read.
- `re-search-forward` is **case-insensitive by default**
  (`case-fold-search` is `t`), so the anchored source lookup matched
  `* TODO ship` for `* TODO Ship`.
- A zero-delay timer **does** fire while a command yields in `sit-for`,
  so revision 2's restart finalizer could mark a *successful* restart
  `UNKNOWN` mid-startup.  A one-shot `post-command-hook` finalizer does
  not fire mid-command.
- The context-composer project — a prerequisite — already defines
  `:pending-input-p` and `:submit-literal`
  (`plans/2026-07-30-context-composer.md`).  Revision 2 claimed Emacs
  could not inspect a session's prompt and settled for a warning; that
  is no longer true, and this revision consumes both slots.

The rest: locked first-creation, a per-entry token so a cancel-and-reopen
cannot pass the dispatch snapshot check, bijection preflighted for a new
session too, reconciliation routed through the transition API,
`waiting` treated as ambiguous in the readiness fallback, and a live
harness that is actually executable and isolated.

Revision 2.  Revision 1 was reviewed and found not implementation-ready
on thirteen counts; this revision closes them without changing the
feature.  Three were reproduced in batch before being fixed: the body
escape/unescape pair was **not** injective (a line beginning
`" * text"` came back as `"* text"`, so a dispatched prompt could
differ from the stored instruction); `grep -c 'agent-tasks.el'` over the
planned Makefile returns 1, not the 2 the verification step expected;
and `write-region` with `'excl` does give an atomic exclusive create
that signals `file-already-exists`, which is what the new interprocess
lock rests on.  The rest tighten write atomicity across processes,
duplicate-id handling, the transition matrix, dispatch commit-time
revalidation, binding bijection, new-session identity, the restart
failure path, event evidence, refresh semantics, the required UI
fields, task order, and live-verification isolation.

## Problem

`agent` has three places where "a piece of work an agent should do" is
represented, and none of them survives a restart as a piece of work:

- **Chief scheduling** keeps a day plan and manual notes in an Org state
  file (`agent-chief-state-file`, `agent-chief.el:84`) that the model
  reads as prose.  Nothing in it is a record with a state; the chief can
  nudge, but nothing says which work is running, which is stuck, and
  which finished.
- **Claude TODO batching** (`agent-claude-batch-todos`,
  `agent-claude.el:1416`) collects Org TODOs into an in-memory plist
  queue (`agent-claude--batch-start`, `agent-claude.el:1501`) and runs
  them through `claude -p`.  If Emacs dies mid-batch, the queue is gone;
  the only trace is whatever JSON reached the log directory.  Nothing
  records that entry 7 of 12 was in flight.
- **Live sessions** are the practical unit of work today, and they are
  buffers.  A session buffer that dies takes with it every fact about
  what it had been asked to do.

So the questions a person actually asks — *what did I ask an agent to
do, which of those are still running, which stopped without an answer,
and which of the ones marked finished were actually verified* — have no
answer anywhere in the package, and cannot have one, because there is no
durable record whose subject is the task rather than the session.

## What this design deliberately does not do

**It is a ledger, not a worker runtime.**  Nothing here starts work on
its own, retries work on its own, schedules work, or decides that work
finished.  There is no dependency-driven scheduler: dependencies gate a
*human-initiated* dispatch and nothing else.  There is no parallel
worker pool, no delegation protocol, and no second event loop.  Every
transition into `running` is caused by an interactive command, and there
is exactly one such command path.

**It never infers that a task is done.**  A turn ending is not a task
ending.  A backend `stop` event means the model stopped talking; it says
nothing about whether the work is complete or correct.  The ledger
records that a turn completed and **leaves the task `running`**.  (It
files no attention item for it: `agent-attention-mode` already files one
for the session event, and a second would be noise.)  Only a person closes a
task.  This makes `running` sticky and slightly annoying, which is the
correct trade: the alternative is a board that reports finished work
that was never checked.

**It never silently retries.**  After an ambiguous end — Emacs died, the
session buffer vanished, a submission signalled — the task becomes
`unknown` with a recorded reason, and stays there until a person decides
what to do.  `unknown` is a state the code can enter automatically;
`running` is not.

## Verified capabilities this design rests on

Verified by reading the installed tree and by running the checks named,
not assumed.

| Fact | Where |
|---|---|
| `agent-session` is a struct with `backend`, `account`, `directory`, `instance`, and `id` slots | `agent.el:302` |
| `agent-session-id-functions` runs with the session buffer whenever a native session id is recorded or changes | `agent.el:452`, `agent--note-session-id` at `agent.el:460` |
| `agent--teardown-functions` is the buffer-local registration point for per-session resources, run exactly once by `agent--session-teardown` | `agent.el:730`, `agent.el:753` |
| `agent-session-display-state` returns `busy`, `waiting`, `background-waiting`, or `unknown`, and never guesses `unknown` away | `agent.el:1000` |
| `agent-submit` puts text into a live session and submits it; `agent-start-session` accepts `:initial-prompt` and returns the new buffer | `agent.el:1457`, `agent.el:311` |
| `agent-display-name` gives a stable human label for a live session buffer | `agent.el:848` |
| A soft-require delegation command already exists as a pattern (`agent-history` → `agent-log-menu`) | `agent.el:2665` |
| `agent-log-open-session SESSION-ID` is an autoloaded command that opens a native session's transcript by id | `agent-log/agent-log.el:865` |
| An Org file that carries its own `#+TODO:` line parses those keywords in a plain temp buffer after `(org-mode)`, with no user configuration | verified in batch: `org-todo-keywords-1` → `("PENDING" "RUNNING" "BLOCKED" "UNKNOWN" "DONE" "CANCELLED")`, `org-done-keywords` → `("DONE" "CANCELLED")` |
| A heading whose keyword is not declared parses as **no** keyword, and the word is absorbed into the heading text | verified in batch: `* WAITING Mangled` → state `nil`, heading `"WAITING Mangled"` |
| `org-find-property` locates a heading by property value; `org-set-property` and `org-todo` edit that heading and leave the rest of the buffer alone | verified in batch |
| `org-inhibit-logging` bound to `t` suppresses `org-log-done`, so a machine write never inserts a `CLOSED` stamp and never prompts for a note — with `org-log-done` set to `note`, the write completed silently in batch | verified in batch |
| Properties do not leak from a parent heading to a child by default: a `** Log` sub-heading returned `nil` for the parent's `AGENT_TASK_ID` | verified in batch |
| `org-inhibit-startup` bound to `t` does **not** disturb in-file `#+TODO:` parsing, so a machine write can skip Org's startup work | verified in batch |
| `org-todo "PENDING"` on a heading that has no keyword adds one rather than failing | verified in batch |
| `^` in `replace-regexp-in-string` matches after every newline, so a line-oriented body codec can be written as two regexp replacements | verified in batch |
| The revision-1 codec (`^\*+` / `^ \*+`) is **not** injective: `" * a bullet"` decodes to `"* a bullet"`. The revision-2 pair (`^ *\*` / `^ +\*`) round-trips `"* x"`, `" * x"`, `"   ** x"`, `"  *bold* start"`, `"plain"` and `" plain"` exactly | verified in batch |
| `write-region` with the `'excl` flag is an atomic exclusive create: the second caller signals `file-already-exists`, which is what the interprocess lock rests on | verified in batch |
| `insert-file-contents` sets `buffer-file-coding-system` even in a non-visiting temp buffer (`undecided-dos` for a CRLF file), and writing back with that value reproduces CRLF and encodes UTF-8 correctly | verified in batch |
| `agent--dispatch-send` emits the `submit` session event **before** calling the backend's send function, so `submit` cannot be evidence that anything was delivered | `agent.el:1492`-`agent.el:1493` |
| `agent-claude-submit-command` inserts text into the CLI prompt and then sends return, so a non-empty prompt is submitted along with it, and no backend slot exposes the prompt's contents | `agent-claude.el:269`-`agent-claude.el:272` |
| `^\*\{1,2\} ` matches `** x` and does **not** match `*** x`, so a third-level heading inside `Comments` is not mistaken for a section boundary | verified in batch |
| `make-temp-file` accepts an absolute prefix, so the replacement temp file can be created in the ledger's own directory (required for `rename-file` to be atomic) | verified in batch |
| `agent-capture` already stores durable per-session state as Org files and reads them back with `org-entry-get` | `agent-capture.el:117`–`agent-capture.el:259` |
| The current suite is 362 tests, all passing, and `make compile` is clean | `make test` run at planning time |

**No new `agent-backend` slot is required, and no new core hook.**
Everything below consumes contracts that either exist today or are
produced by the attention/queue project.  That is a result, not an
aspiration: if a task in the plan appears to need a new backend slot,
the design is wrong.

## Dependencies on the other projects

This is the last of the five areas and it is the only one with a **hard
functional prerequisite**.

- **Attention/queue (area 2) is required.**  Its `agent-session-event-functions`
  hook is the ledger's only evidence channel for "the bound session
  became blocked", "the bound session completed a turn", and "the bound
  session reported an error"; and its `agent-session-ready-to-submit-p`
  is the only source that can tell a session stopped at a permission
  dialog (which displays as `waiting`) from one that can take a turn.
  Without area 2 the ledger would have to guess, and guessing is the one
  thing it may not do.  `agent-attention-file` is used through
  `fboundp`, because the inbox module is optional even after the project
  lands.
- **Context composer (area 3)** and **skill bundles (area 4)** are
  ordering-only dependencies: the Makefile lists and `agent-menu` keys.
- **agent-log (area 1)** is consumed read-only and optionally, through
  `agent-log-open-session`, exactly as `agent-history` does.

## Boundary and module layout

One new optional module, in the mould of `agent-capture.el`: loading it
installs no hook, no timer, and no keymap entry.

- **`agent-tasks.el`** — the ledger store, its state machine, the list
  UI, and the dispatcher.  Requires `agent` and `org`.

`agent.el` gains **two menu entries and their autoloads, and nothing
else.**  `agent-chief.el`, `agent-claude.el`, `agent-attention.el`,
`agent-queue.el`, `agent-context.el`, `agent-skill.el`, `agent-learn.el`
and `agent-log` are **not modified**.  Every integration with them is
one-directional and initiated from `agent-tasks.el` behind an `fboundp`
or `boundp` guard.

A global minor mode `agent-tasks-mode` owns every hook the module
installs.  With the mode off, the list, the detail view, and manual
state changes still work; **dispatch does not**, and says so, because a
dispatch with nothing observing the session would produce a `running`
task that no evidence could ever move.

## 1. The store

### File and format

`agent-tasks-file`, default
`(expand-file-name "agent/tasks.org" user-emacs-directory)`.  One global
ledger across projects — a control plane that is per-project is not a
control plane.  Filtering by project happens in the UI.

Org, because the three requirements pull the same way: the record must
survive a restart, a person must be able to read and fix it without
Emacs Lisp, and the package already stores durable per-session state as
Org (`agent-capture.el`).  A JSON Lines event log would be more
crash-proof and completely illegible; the ledger holds tens of records,
not millions, so the atomic-replace cost is irrelevant and legibility
wins.

The file carries its own keyword declaration, so it needs no user
configuration and behaves identically in a scratch fixture and in the
real ledger:

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
:SOURCE_FILE: ~/notes/todo.org
:SOURCE_HEADING: * TODO Port the reconciliation pass
:END:

Write the pass that turns orphaned running tasks into unknown ones.
Do not add a retry path.

** Result

** Evidence

** Comments

** Log
- [2026-07-31 Fri 14:25] pending → running (dispatch attempt 1: claude-code personal ~/repos/agent/ default)
- [2026-07-31 Fri 14:58] running → unknown (session ended without a recorded outcome)
- [2026-07-31 Fri 15:01] unknown → running (re-armed by user, attempt 2: "resumed after the crash")
```

### What is parsed and what is only written

This split is the rule that keeps the format simple, and it is stated in
the manual:

- **Parsed** (authoritative, round-tripped): the TODO keyword, the
  heading text, every property in the table below, the body text between
  the property drawer and the first sub-heading, and the four fixed
  sub-headings `Result`, `Evidence`, `Comments`, `Log` matched by their
  literal heading text.
- **Written only** (append-only prose, never read back for a decision):
  the contents of `Log`.  The ledger appends one timestamped line per
  transition and per attempt and never parses one.  Attempt history is
  therefore complete and legible without being a second source of truth
  that could disagree with the properties.

`Comments` is written by the ledger (via a command) and freely edited by
the person; it is displayed but never interpreted.

### The body codec

An instruction may legitimately begin a line with `*`, which Org would
read as a heading and which would split the entry.  The ledger therefore
encodes the body on write and decodes it on read, and **the pair must be
injective** — the decoded instruction is what gets dispatched, so a
codec that is merely "usually right" sends a prompt that differs from
what the person wrote.

- **Encode:** prepend one space to every line matching `^ *\*` — any
  line whose first non-blank character is `*`, at any indentation.
- **Decode:** remove one leading space from every line matching
  `^ +\*`.
- **Decode only runs on bodies this package encoded.**  A task written
  by `agent-tasks-create` carries `:BODY_ENCODED: t`; an entry without
  that property has its body returned verbatim.

Both halves are needed, and revision 1 had neither right.

Its pair (`^\*+` encode, `^ \*+` decode) was **not injective**: a line
the person indented themselves, `" * a bullet"`, did not match the
encoder and so was written unchanged, then matched the decoder and came
back as `"* a bullet"`.  Verified in batch.  The pair above round-trips
`"* x"`, `" * x"`, `"  * x"`, `"   ** deep"`, `"  *bold* start"`,
`"plain"`, `" plain"` and `""` exactly, no two of those inputs share an
encoding, and no encoded line begins with `*` at column zero — so Org
can never read one as a heading.

The `BODY_ENCODED` gate closes the other half.  *Any* prefix-based
escape is ambiguous when applied to text it did not produce: after
encoding, `"* x"` and the person's hand-typed `" * x"` are the same
bytes on disk, so decoding a hand-written body would silently remove a
space the person meant.  Recording that the ledger encoded this body
removes the ambiguity, and it costs one property.  A hand-written body
cannot contain a column-zero `*` anyway — Org would have made it a
heading and split the entry — so verbatim is the right reading for one.

Two further contract points, stated so they cannot be mistaken for
losses:

- **The body is stored once, at creation, and never rewritten.**  Every
  later write edits a property, the heading keyword, or a section — never
  the body.  So the person's bytes in the file are theirs; the codec
  only has to survive read-back.
- **The parsed instruction is the body with outer whitespace trimmed.**
  Interior blank lines and indentation are preserved exactly; leading
  and trailing blank lines are not part of an instruction and are not
  reproduced.  Read → dispatch is therefore stable, and read → write →
  read is idempotent.

### State lives in exactly one place

The heading's TODO keyword is the state.  There is deliberately **no**
`:STATE:` property: two places holding the same fact is how they come to
disagree.

A level-1 heading that has an `AGENT_TASK_ID` but no recognised keyword
is a **problem row**, not a task: it is listed, named, and explained
("heading has no ledger state keyword"), it is never dispatched, and it
is never rewritten.  This case is real rather than theoretical — a
person editing the file who types `* WAITING …` produces a heading whose
state is `nil` and whose title silently becomes `"WAITING …"`.

### Every problem class, and what "problem" costs a record

A problem row is not a task.  It never appears in `agent-tasks-find`,
never satisfies a dependency, is never dispatched, and is never
rewritten.  The classes:

| Class | Detected as |
|---|---|
| no task id | level-1 heading without `AGENT_TASK_ID` |
| no ledger state | keyword absent or not one of the six |
| duplicate task id | the id appears on more than one heading |
| malformed attempt | `ATTEMPT` present and not a non-negative integer |
| blocked without a reason | state `BLOCKED` and no `BLOCKED_REASON` |
| done without an outcome | state `DONE` and `OUTCOME` not `succeeded`/`failed` |

**Duplicate ids reject every occurrence, not just the later ones.**
Revision 1 kept the first heading as a usable task and reported only the
rest, which is exactly backwards: `org-find-property` returns the first
match, so a write aimed at the id would silently edit one of two
headings a person cannot tell apart, and a dispatch would run the
instruction of whichever came first in the file.  Parsing therefore
counts ids in a first pass and, for any id seen more than once, emits a
problem row per occurrence and no task at all.  The person resolves the
duplication by hand; nothing in the ledger guesses which one was meant.

The malformed-attempt, blocked-without-reason and done-without-outcome
classes exist because the alternative is silent coercion: reading
`ATTEMPT: two` as `0` would renumber a real attempt history, and
accepting a `DONE` record with no outcome would present unverified work
as characterised.

Separately, a file whose `#+agent_ledger_version:` is newer than this
code understands is displayed read-only in full, and every write is
refused by name.

### Properties

| Property | Meaning |
|---|---|
| `AGENT_TASK_ID` | `t-<UTC timestamp>-<4 random hex>`; assigned once, never reused, never rewritten |
| `CREATED`, `UPDATED` | inactive Org timestamps |
| `BACKEND` | backend symbol name the task is bound to, or absent |
| `ACCOUNT` | account name recorded at binding, or absent |
| `DIRECTORY` | the working directory / worktree the task acts in |
| `REPOSITORY` | git top level of `DIRECTORY`, resolved once when the field is set, absent when not a repository |
| `INSTANCE` | session instance name, or absent |
| `SESSION_ID` | native session id of the current attempt, once the backend reports one |
| `ATTEMPT` | integer, starts at 1 on the first dispatch |
| `DEPENDS` | space-separated task ids |
| `BLOCKED_REASON` | why a `BLOCKED` task is blocked; required whenever the state is `BLOCKED` |
| `OUTCOME` | `succeeded` or `failed`; required whenever the state is `DONE` |
| `SOURCE_FILE`, `SOURCE_HEADING` | provenance of an imported Org TODO: the file, and the heading line **verbatim** |
| `BODY_ENCODED` | `t` when this package wrote the body through the codec; absent means the body is read verbatim |

`DIRECTORY` is an abbreviated absolute directory with a trailing slash,
normalised exactly as `agent-session--normalize-directory` does, so a
recorded directory and a live session's directory compare with `equal`.

`SOURCE_HEADING` stores the literal heading line rather than a
reconstructed one, for the same reason `agent-learn` records literal
headings: any other key fails to find the heading again once the person
edits it, and the failure is silent.

**Property values are written byte-for-byte**, with exactly one
exception: a value containing a newline is refused with an error naming
the property, because an Org property drawer cannot represent one and
silently substituting a space would corrupt the value.  Revision 1
collapsed interior whitespace on every property, which contradicted
`SOURCE_HEADING`'s verbatim contract — a heading with two spaces between
words was stored with one, and the lookup that searches for it then
failed.  (Org itself trims leading and trailing whitespace from a
property value on read; that is Org's behaviour, not a transformation
this package makes, and the manual says so.)

The source lookup is likewise **anchored**: the heading is matched as a
whole line, `^<heading>[ \t]*$`, not as a substring.  An unanchored
search finds `* TODO Ship` inside `* TODO Ship the second thing` and
sends the person to the wrong heading.

### Writing

Every write is one function, `agent-tasks--update-task`, and **the whole
of it runs while holding an interprocess lock**:

0. **Acquire the lock.**  `agent-tasks-file` plus `.lock` is created
   with `write-region`'s `'excl` flag, which is an atomic exclusive
   create that signals `file-already-exists` when another process holds
   it — verified in batch.  The lock file records the pid, the host, and
   the time.  Acquisition retries for `agent-tasks-lock-timeout`
   (default 5 seconds) and then signals a `user-error` naming the lock
   file and its contents.  **A stale lock is never broken
   automatically**: `agent-tasks-break-lock` is an explicit command that
   shows the contents first.  Silently breaking a lock would reintroduce
   exactly the race the lock exists to close.
1. Refuse if a buffer visits `agent-tasks-file` with unsaved changes,
   naming the buffer.  The person's edits are never saved as a side
   effect of a machine write.
2. Take **one snapshot** — a single raw-byte read — and derive the
   token, the decoded text, and the coding system from it.  Compare the
   token with the one recorded when the task list was parsed.  A
   mismatch is a conflict: the write is refused with "the ledger
   changed on disk since it was read; refresh and retry".

   One read, not two.  Revision 2 read the decoded text and then read
   again for the token, so a rename landing between the two paired the
   old content with the new file's token — the check would pass and the
   write would resurrect stale content.

   The coding system is chosen by applying **Emacs's own precedence**
   to that one byte string: `coding-system-for-read`, then
   `set-auto-coding` (which reads a `-*- coding: -*-` cookie), then
   `find-operation-coding-system` (which consults
   `file-coding-system-alist`), and only then content detection.  The
   **cookie outranks the alist** — verified in batch, where a cookie
   saying `iso-8859-1` beat an alist entry saying `utf-8-unix`; revision
   4 had those two the other way round.

   The **end-of-line variant comes from the same bytes**.  A cookie
   names a character set and says nothing about line endings, so the
   coding it yields has an unspecified eol type, and writing back with
   it uses the platform default — which silently **rewrites a CRLF
   ledger as LF**.  Detection over the same snapshot supplies the eol
   type and pins it.

   Revision 3 used content detection alone, which disagrees with
   `insert-file-contents` whenever any earlier step applies: for a
   ledger whose cookie says `iso-8859-1` while its bytes are valid
   UTF-8, detection returns `utf-8` and decodes to different text.
   With both corrections, every case — cookie, cookie plus CRLF, plain
   CRLF, plain LF, alist entry, read override, and a cookie-versus-alist
   conflict — yields the same coding system as `insert-file-contents`,
   decodes to the same text, and round-trips to identical bytes.
3. Apply the edit in a temp buffer holding the file's contents, in
   `org-mode`, with `org-mode-hook` bound to nil (the person's org hooks
   have no business running inside a machine write),
   `org-inhibit-logging` bound to `t`, and
   `org-after-todo-state-change-hook` bound to nil.  Without
   `org-inhibit-logging`, a user with `org-log-done` set to `note` would
   have every machine state change prompt them for a note — verified in
   batch, where binding it made the write silent.
4. Write the temp buffer to a temporary file **in the same directory**
   and `rename-file` it over the original, with the coding system Emacs
   detected when reading, so an interrupted write cannot truncate the
   ledger and a CRLF file stays CRLF.
5. Release the lock, then revert a clean visiting buffer, so an open
   ledger window shows the truth.

Steps 0 and 2 are two different guards against two different races, and
revision 1 had only the second:

- **The hash alone does not make concurrent writers safe.**  Two Emacs
  processes can both read the same bytes, both compute the same token,
  both find it matches, and both rename — the later rename wins and the
  earlier writer's change is gone with no error anywhere.  The hash
  detects *a change that already landed*; only the lock prevents an
  interleaving that produces one.  With the lock, the second writer
  reaches step 2 after the first has renamed, sees a different token,
  and is refused — which is the intended outcome: one succeeds, one is
  told to refresh, and nothing is lost.
- **The token hashes raw bytes, not decoded text.**  A decoded hash
  cannot distinguish a CRLF file from its LF twin, nor two byte
  sequences that decode alike under a lenient coding system, so a real
  concurrent change could pass the check.

**Creating the file is part of the same protocol, and so is the first
task's id.**  `agent-tasks-file` is created inside the lock, through
the same temp-file-plus-rename path.  Two further rules close the
first-creation race that survived revision 2:

- A snapshot taken when the file was **absent** carries a nil token.
  If the file *exists* when the lock is taken, that is a conflict, not
  a licence to append: another process published a ledger in between,
  and its version and contents were never validated against this
  snapshot.
- The new task's id is checked for uniqueness **against the ledger
  re-parsed under the lock**, not against the unlocked snapshot that
  suggested it.  Ids embed a one-second timestamp and 16 random bits,
  so two creators in the same second collide with probability 1/65536 —
  small, and a duplicate id makes *both* tasks unusable (§"Every problem
  class"), so it is not a risk worth carrying when the fix is one
  re-check inside a lock that is already held.

Failure at any step is a `user-error`, changes nothing, and releases the
lock through `unwind-protect`.  Because dispatch writes before it sends
(§5), an unwritable ledger stops the dispatch instead of starting
untracked work.

## 2. States and transitions

Six states.  The Hermes note listed five; `CANCELLED` is added because
without it the only way to close abandoned work is to mark it `DONE`,
which records something untrue in the one artifact whose whole purpose
is to be true.

| State | Meaning |
|---|---|
| `PENDING` | recorded, never dispatched (or explicitly re-armed) |
| `RUNNING` | dispatched into a bound session; no outcome recorded |
| `BLOCKED` | the bound session needs a person, or a person marked it blocked; `BLOCKED_REASON` says why |
| `UNKNOWN` | the run ended ambiguously; what happened is not known |
| `DONE` | closed by a person, with `OUTCOME` `succeeded` or `failed` |
| `CANCELLED` | closed by a person without being run to an outcome; the reason is logged |

Every transition, its trigger, and **who may cause it**:

| From | To | Trigger | Actor |
|---|---|---|---|
| `PENDING` | `RUNNING` | `agent-tasks-dispatch` | person |
| `RUNNING` | `BLOCKED` | bound session reported `blocked` (`:kind permission`/`question`) | evidence |
| `RUNNING`/`BLOCKED` | `BLOCKED` | `agent-tasks-mark-blocked` (reason required) | person |
| `BLOCKED` | `RUNNING` | bound session reported `activity` after the block | evidence |
| `RUNNING`/`BLOCKED` | `UNKNOWN` | bound session torn down with no outcome recorded; or reconciliation found no live session; or the dispatch submission signalled; or an `error` event | evidence |
| any open state | `DONE` | `agent-tasks-mark-done` (outcome required) | person |
| any open state | `CANCELLED` | `agent-tasks-cancel` (reason required) | person |
| `UNKNOWN`/`BLOCKED` | `RUNNING` | `agent-tasks-resume` → re-dispatch, or attach to a session the person picks | person |
| `UNKNOWN`/`BLOCKED` | `PENDING` | `agent-tasks-resume` → "unbind and leave pending" | person |
| `DONE`/`CANCELLED` | `PENDING` | `agent-tasks-reopen` (confirmation required) | person |

`PENDING` → `BLOCKED` is **not** in the table and is not offered.
Revision 1's `agent-tasks-mark-blocked` accepted it, which contradicted
this table; a task that has never run and cannot start is either still
pending or cancelled, and "blocked" is reserved for a run that started
and stopped needing a person.

### The matrix is enforced in one place

`agent-tasks-transition` is the only function that changes a state, and
it validates **every** call against a single constant matrix — the table
above, transcribed — rather than trusting each caller to pass a correct
source-state list.  Revision 1 checked only an optional `:only-when`
argument the caller supplied, so a caller that forgot it could write any
transition at all, and the table was documentation rather than a rule.

It also validates **destination invariants** after the caller's
property-setting thunk has run and before the write is committed:

| Destination | Invariant |
|---|---|
| `BLOCKED` | `BLOCKED_REASON` is a non-empty string |
| `DONE` | `OUTCOME` is `succeeded` or `failed` |
| anything else | `BLOCKED_REASON` and `OUTCOME` are absent |

A violation is an error and the write does not happen, so the ledger
cannot hold a `DONE` record nobody characterised or a `BLOCKED` record
that does not say why — the same two conditions the parser reports as
problem rows, checked on the way in as well as on the way out.

Two more rules make the centrality real rather than nominal:

- **Every transition supplies a non-blank reason.**  `CANCELLED` in
  particular records why, and revision 2 enforced that only in the
  command, so a caller reaching the transition API directly could
  cancel a task with an empty reason.  The check belongs where the
  matrix check is.
- **Reconciliation goes through the transition API too.**  Revision 2
  called the low-level state setter directly, which bypassed both the
  matrix and the destination invariants — so an orphaned `BLOCKED` task
  kept its now-meaningless `BLOCKED_REASON` after becoming `UNKNOWN`.
  There is exactly one way to change a state, and reconciliation is not
  an exception to it.

The two rules that matter more than the table:

- **No evidence transition ever produces `RUNNING` from `UNKNOWN`, and
  no evidence transition ever produces `DONE`.**  The only evidence
  transition into `RUNNING` is `BLOCKED` → `RUNNING`, which is a
  correction of the ledger's own earlier evidence about the same live
  binding, not a restart of anything.
- **A completion event never changes state.**  A non-redundant
  `stop`/`idle-prompt` on a bound session appends a `Log` line ("bound
  session completed a turn").  The state stays as it was, and no
  attention item is filed — the attention module already files one for
  the underlying session event.

## 3. Task–session correlation

A binding is claimed only when the identity is **proven**, never
inferred from a directory:

- **New session**: `agent-tasks-dispatch` calls `agent-start-session`
  and binds the returned buffer.  That buffer is the session, by
  construction.
- **Existing session**: the person picks it from the session picker.
  Their choice is the proof.

The binding is held two ways at once, and the difference is deliberate:

- **In memory**, `agent-tasks--bindings` maps a live session buffer to a
  task id.  This is what the event consumer uses; it dies with Emacs,
  which is correct, because a buffer reference means nothing after a
  restart.
- **On disk**, the `BACKEND`/`ACCOUNT`/`DIRECTORY`/`INSTANCE` properties
  plus `SESSION_ID`.  This is what survives, what reconciliation matches
  against, and what lets `agent-tasks-open-transcript` hand a session id
  to `agent-log-open-session`.

`SESSION_ID` is filled by `agent-tasks-mode`'s `agent-session-id-functions`
consumer, when the backend reports an id for a bound buffer — the same
contract `agent-log`'s bridge already consumes.  A task dispatched into
a brand-new session has no `SESSION_ID` for a moment, and the record
says so rather than inventing one.

### The binding is a bijection, and it is checked before anything is sent

One session holds at most one task **and one task is bound to at most
one session**.  Revision 1 checked only the first half, so a task could
be attached to a second buffer while still bound to the first, and both
buffers' events would then be attributed to it.  Both directions are
checked.

The check happens **before the message is sent**, not after.  Revision 1
bound the buffer after `agent-submit` returned, so a dispatch into a
session that already held another task delivered the prompt and *then*
signalled — the worst possible order, because the wrong session had
already been given work.  The bijection is therefore verified twice: once
while preparing the dispatch, and again in the non-interactive commit
block immediately before the send.

**Both directions are preflighted for both kinds of target.**  Revision
2 checked the pairing only when an *existing* session was chosen, so a
task that still held a stale binding could be re-dispatched into a
brand-new session: `agent-start-session` delivered the initial prompt
and only then did the bind signal.  The task → buffer direction is
therefore checked for a new session too, before anything starts.

A fresh attempt never transfers a binding silently.  A task that is
still bound is refused by name, and the person unbinds it (`u`) or
attaches it deliberately (`R`).  Automatically stealing a binding would
mean the ledger deciding that an earlier run is over, which is exactly
the judgement it refuses to make everywhere else.

Closing a task releases its binding.  `agent-tasks-mark-done` and
`agent-tasks-cancel` unbind **after** the durable write succeeds, so a
session freed by closing a task can immediately take another, and a
failed close leaves the binding exactly as it was.

### Prompt isolation, through the composer's slots

`agent-submit` inserts text into the CLI's prompt and submits it, so
anything the person had already typed there goes out with the task's
message.  Revision 2 concluded Emacs could not detect this and settled
for a warning in the confirmation buffer.  That was wrong: the
context-composer project, which lands before this one, adds two backend
slots for exactly this problem
(`plans/2026-07-30-context-composer.md`):

- `:pending-input-p` `(BUFFER)` → nil when the session is verifiably
  clean, a truthy description when something is pending, or `unknown`
  when the transport cannot be inspected.
- `:submit-literal` `(TEXT BUFFER)` → submits TEXT as one literal,
  isolated turn, signalling before anything is sent when its
  preconditions fail.

The ledger consumes both:

- Dispatch into an **existing** session calls the pending-input probe
  immediately before submitting and **refuses anything but nil** —
  including `unknown`, because a blind append is exactly the outcome
  the check exists to prevent.  The refusal names what is pending, or
  says the transport cannot be inspected.
- The send itself goes through `:submit-literal`, not `agent-submit`,
  so the task's message is one isolated turn.  A backend registering
  neither slot cannot receive a dispatch into an existing session, and
  says so.

This replaces the warning entirely.  A refusal that only appears when
`agent-tasks-dispatch-confirm` is non-nil — which is what a
confirmation-text warning amounts to — is not a safeguard, because the
person who turned confirmation off is precisely the one who will not
see it.  Dispatch into a new session is unaffected: the session is
created for the task, so there is nothing to collide with.

## 4. Dependencies

`DEPENDS` lists task ids.  It does exactly two things and nothing else:

- **Dispatch gate.**  A task with an unsatisfied dependency (any
  dependency not `DONE` with `OUTCOME` `succeeded`) is refused, naming
  each unsatisfied dependency and its state.  A prefix argument
  overrides after an explicit confirmation, and the override is logged.
- **Display.**  The list shows a blocked-by marker and the detail view
  names the dependencies.

There is no scheduler.  Nothing starts when a dependency clears.

Validation, run whenever the ledger is parsed, reports as problem rows:
a dependency id that names no task, and a dependency cycle (detected
with an explicit depth-first walk, reporting the cycle's members — an
undetected cycle would otherwise make the gate permanently unsatisfiable
with no explanation).  A self-dependency is a cycle of one.

## 5. Dispatch

`agent-tasks-dispatch` (from the list, or with completion over open
tasks):

1. Require `agent-tasks-mode`; otherwise `user-error` naming it.
2. Require state `PENDING`, or `UNKNOWN`/`BLOCKED` reached through
   `agent-tasks-resume`.  A `RUNNING` task is refused: it is already
   dispatched.
3. Check the dependency gate (§4).
4. Resolve the target: an existing live session (picker) or a new one.
   For a new session, the backend, the directory, and the account are
   read the way `agent-start-new-session` reads them, with the task's
   recorded `DIRECTORY`/`BACKEND`/`ACCOUNT` as the defaults.  A task
   with no recorded directory prompts for one; the directory decides
   which project an agent will act in, so it is never defaulted
   silently.
5. Check the directory still exists, and refuse by name if not.
6. Check the target can take a turn, from the most authoritative source
   available: `agent-session-ready-to-submit-p` (attention/queue
   project), else the backend `:ready-to-submit-p` slot (composer
   project), else `agent-session-display-state`.  Not ready → a
   `user-error` naming the session and the state, and mentioning
   `agent-queue-prompt` for a person who wants to queue text by hand.
   `unknown` → explicit confirmation.  The answer is carried forward
   with the prepared dispatch, so the non-interactive re-check
   immediately before the send accepts `unknown` only when it is the
   same `unknown` the person already agreed to.

   **In the display-state fallback, `waiting` maps to `unknown`, not to
   `ready`.**  `waiting` means the session stopped and is not
   proceeding, which covers both "at a fresh prompt" and "stopped at a
   permission dialog"; only the two authoritative sources can tell them
   apart, and this branch runs precisely when neither is available.
   Calling it `ready` would send a task into a dialog.  `busy` maps to
   `busy` and everything else to `unknown`.
7. Check the bijection (§3) in **both** directions and for **both**
   kinds of target: the task is bound to no other buffer, and an
   existing target holds no other task.
8. Show the rendered message and confirm
   (`agent-tasks-dispatch-confirm`, default `t`).
9. For an existing session, check `:pending-input-p` and refuse
   anything but nil (§3).  **This precedes the durable write**: a
   refusal here must leave the task exactly as it was — same bytes,
   same state, same attempt, still unbound — and writing `RUNNING`
   first would leave a task claiming a run that was never sent.
10. **Commit against the reviewed snapshot** and **write the ledger** —
    state `RUNNING`, `ATTEMPT` incremented, binding properties set,
    `Log` line appended — and only then send.
11. Send: `:submit-literal` for an existing session,
    `agent-start-session` with `:initial-prompt` for a new one.
    Register the in-memory binding, then confirm the recorded identity
    against the live session (§"New-session identity" below).

### Committing against the snapshot the person reviewed

Everything the person was shown — the state, the attempt number, the
instruction that became the message, the dependency verdict — came from
one parsed snapshot.  Between the preview and the send, another Emacs,
or the person in another window, can cancel the task, close it, reopen
it, edit the instruction, or add a dependency.  Revision 1 re-read the
ledger independently at commit time and wrote whatever it found, so a
cancelled task could still receive its prompt.

The commit therefore happens **inside the write lock**, and before
changing anything it re-reads and requires that **the task's whole
entry is byte-for-byte the one that was reviewed**, by comparing a
per-entry token: a hash of the entry's text, recorded at parse time and
carried on the task record.  Any difference is a `user-error` naming
the task; nothing is written and nothing is sent.

Comparing a handful of fields, as revision 2 did, is not enough, and
the counter-example is ordinary: cancel a task and reopen it, and its
state, attempt, and instruction are all back to what the preview saw,
while the task has been through two decisions the person dispatching
knows nothing about.  Edits to the recorded target — the directory the
agent will act in, the backend, the account — were not compared at all
and would have been silently overwritten by the commit.  One token over
the whole entry covers every field, present and future, and cannot
drift out of step with the record the way an enumerated list does.

A per-entry token also keeps the check *narrow*: an unrelated task's
event write during the preview does not refuse this dispatch, which a
whole-file token would.

The **dependency verdict is recomputed alongside it**, because that one
fact does not live in this task's entry: reopening a dependency that
was satisfied at preview changes the decision while leaving every byte
of the dispatched task untouched.  The verdict at commit must equal the
verdict the person reviewed — including "no unsatisfied dependencies" —
or nothing is sent.

A dependency override is part of the reviewed decision, so it is
**recorded**: the `Log` line names each dependency that was unsatisfied
and its state at the time.  Revision 1 asked for the override and then
discarded it, leaving no trace that the gate had been bypassed.

Steps 9 and 10 are in that order on purpose, and the failure analysis is
part of the design rather than an afterthought:

- **The write fails** → nothing is sent.  An unwritable ledger must not
  start untracked work.
- **The send signals** → the task moves to `UNKNOWN` with the reason
  "submission signalled; delivery unproven", never back to `PENDING`.
  Text may have reached the CLI before the signal; `PENDING` would
  invite a second send of work that may already be running.
- **Emacs dies between the write and the send** → the task is `RUNNING`
  on disk with no live session, which is exactly the case §6's
  reconciliation turns into `UNKNOWN`.  No extra flag is needed, and one
  was deliberately not added.

### New-session identity

`agent-start-session` fills a nil account from `agent-account-resolve`
and mutates the session struct as it goes, and a backend may choose a
different instance name when one is already taken.  So the identity
known *before* the call is a prediction, and reconciliation (§6)
compares recorded identity for equality — a predicted account or
instance that turns out wrong makes the task unreconcilable.

The dispatch therefore performs a **post-start identity repair** as a
distinct, durable step: after `agent-start-session` returns the buffer,
the backend, account, directory, instance, and native session id are
read from that live buffer and written to the task, with a `Log` line
recording the confirmation.  Revision 1 repaired only the session id.

If the repair write fails, the task keeps its `RUNNING` state and the
failure is reported as a warning naming the task and saying the recorded
identity may not match the live session, so the person can fix it with
`e`.  Reporting the dispatch as failed would be worse: the work is
running.

### The dispatched message (pure, fixture-tested)

`agent-tasks-message` is a pure function of the task:

```
[Agent task t-20260731T142211-8f3a — attempt 2]

Write the pass that turns orphaned running tasks into unknown ones.
Do not add a retry path.

---
This task is tracked in a durable Emacs ledger that records its state.
The ledger does not infer completion from your turn ending, and nothing
marks this task done on your behalf.  When you stop, say plainly what
you did, what you verified, and what you did not verify.
```

The `Result` and `Evidence` sections are **not** sent: they are the
person's record of the outcome, not input to the run.  A task re-armed
after a failed attempt carries only its instruction; whatever the
person wants the next attempt to know goes in the instruction body,
which they can edit.

## 6. Crash recovery and reconciliation

Two mechanisms, covering the two ways a run can end without an outcome.

**Teardown (Emacs is alive).**  On binding, the ledger pushes a closure
onto the session buffer's `agent--teardown-functions`.  When the buffer
is torn down, that closure moves any `RUNNING`/`BLOCKED` task bound to
it to `UNKNOWN`, reason "session ended without a recorded outcome", and
files an attention item.  `agent-restart` is the one exception: when
`agent-before-restart-functions`/`agent-after-restart-functions` exist
(attention/queue project, guarded with `boundp`), the ledger detaches
the binding before the kill and re-attaches it to the new buffer **only
when the new session's seeded id equals the expected one** — the
non-fork resume case, the only one where identity is proven.  Any other
outcome leaves the task `UNKNOWN`, which is the honest answer for a
session that was replaced rather than resumed.

**A restart that never completes must still finish the task's story.**
If `agent-start-session` signals after the binding was detached, the
after-restart hook never runs, and revision 1 left the task `RUNNING`
with no binding and nothing scheduled to notice — its own test asserted
that abandoned state was acceptable, which was wrong.

Detaching therefore arms a **one-shot `post-command-hook` finalizer**:
when it runs and the detached record is still outstanding (the
after-restart hook clears it on success), the task moves to `UNKNOWN`
with the reason "a restart did not complete".  The guarantee is that a
detach is always followed by either a re-attachment or an `UNKNOWN`, by
the end of the command that started the restart.

It must not be a timer.  Revision 2 used `run-at-time 0`, and a
zero-delay timer **does** fire while a command yields — verified in
batch with a `sit-for` standing in for a backend startup that waits on
process output.  A successful restart that yielded would have been
marked `UNKNOWN` underneath itself.  `post-command-hook` runs after the
whole `agent-restart` command returns, whether it succeeded or
signalled, which is exactly the boundary this needs.

The finalizer also keeps the **original buffer** in its record.  Core
runs every before-restart hook before killing anything, so a *later*
hook signalling aborts the restart with the original session still
alive and running; marking its task `UNKNOWN` would be plainly false.
When the recorded buffer is still live and still reports the session id
the detach expected, the finalizer restores the binding instead.

**Reconciliation (Emacs died).**  Reconciliation runs the first time the
ledger is parsed in an Emacs session, and **unconditionally on every
explicit refresh** — the list's `g` calls it directly rather than
through the once-per-session guard.  Revision 1 routed `g` through the
guard, so a session that died after the first refresh was never noticed
until Emacs restarted, which defeats the point of a refresh key.  Every
task recorded `RUNNING` or `BLOCKED` that has no in-memory binding is
checked against the live session buffers:

- A live buffer whose `agent-session` matches the recorded backend,
  account, directory, and instance, **and** whose native id equals the
  recorded `SESSION_ID` when both are known → re-bind, keep the state,
  log the re-binding.
- Anything else → `UNKNOWN`, reason "no live session found at
  reconciliation", logged.  No attention item: there is no session
  buffer to attach one to, `agent-attention-file`'s behaviour with no
  buffer is not part of its published contract, and the reconciliation
  summary plus the list's sort order already put these tasks in front of
  the person.

Identity matching requires the id when both sides have one.  Matching on
directory alone would happily re-bind a task to a *different* session
that happens to run in the same project, and then attribute that
session's events to it.

Reconciliation writes at most once per task and reports a summary line
("reconciled 4 tasks: 1 re-bound, 3 unknown").  It never produces
`RUNNING` from `UNKNOWN` and never re-dispatches anything.

## 7. Evidence consumption

`agent-tasks-mode` subscribes to `agent-session-event-functions` with a
consumer that is a pure classifier plus a write, and that obeys the
non-reentrancy contract that hook documents: it never sends session
input, so nothing it does can nest a `submit` event inside an outer
delivery.

For an event whose buffer holds a task binding:

| Event | Effect |
|---|---|
| `blocked` (`:kind permission`/`question`) | state → `BLOCKED`, `BLOCKED_REASON` from the backend-reported detail only |
| `activity` while `BLOCKED` | state → `RUNNING`, logged |
| `submit` | nothing |
| `error` | state → `UNKNOWN`, reason = the reported code and message |
| non-redundant `stop`/`idle-prompt` | `Log` line only; state unchanged |
| redundant completion | ignored entirely |

**`submit` is not evidence and does not unblock.**  Core emits it
*before* calling the backend (`agent--dispatch-send`, `agent.el:1492`,
emits the event and then applies the backend function), and core's own
documentation says submissions may duplicate and may start no turn.
Treating it as evidence — which revision 1 did — meant a submission that
failed, or that the CLI ignored, cleared a real `BLOCKED_REASON` and
reported the session as working again.  Only `activity`, which a backend
emits because it observed work, moves a task out of `BLOCKED`.

`BLOCKED_REASON` is copied from what the backend reported and is never
synthesized; when the backend reported nothing beyond "blocked", the
reason says exactly that.

**One owner per attention item.**  Session-level facts — blocked,
errored, completed a turn — belong to `agent-attention-mode`, which
already files an item for each.  The ledger files an item for exactly
one thing that no session event covers: **a task moved to `UNKNOWN` by
its session's teardown**.  In particular the `error` path files no
attention item of its own; it logs and transitions, and the attention
module reports the session error.  Revision 1 filed one on both paths,
which produced two items about one failure.

Ledger writes from the event consumer are best-effort in one specific
sense: a write that fails (conflict, unwritable file) emits a
`display-warning` naming the task and the reason and leaves the ledger
alone.  It never signals into event delivery, because a signalling
consumer would break the other consumers on the hook.  The next
reconciliation re-derives the truth.

## 8. Commands and UI

`agent-tasks` (autoloaded) opens `*Agent tasks*`, a
`tabulated-list-mode` derivative — the same convention as the attention
inbox, the skill history, and the learnings inbox.

Columns, all nine of them required rather than illustrative: **state**,
**title**, **backend**, **account**, **project** (the directory's last
component), **session** (the bound session's display name, or the
recorded identity when it is not live), **attempt**, **age**, and
**deps** rendered as *unsatisfied*/*total* (`1/3`, or empty when the
task has none).  Revision 1's table omitted account and showed a bare
total, which answers neither "which account is this running under" nor
"is this one actually startable" — the two questions the column exists
for.  Sorted: open states first (`BLOCKED`, `UNKNOWN`, `RUNNING`, `PENDING`),
then closed, newest first within a group; the order is total, so the
list does not reshuffle between refreshes.  A header line states how
many tasks and how many problem rows were read from which file, and
whether `agent-tasks-mode` is on — a list that looks live while nothing
is observing sessions would be misleading.

| Key | Action |
|---|---|
| `RET` | detail buffer: full instruction, result, evidence, comments, log, and the resolved session identity |
| `n` | new task (title, instruction, directory, backend, dependencies) |
| `d` | dispatch (§5) |
| `s` | switch to the bound session, or say it is gone |
| `o` | open the bound session's transcript through `agent-log-open-session` |
| `b` | mark blocked (reason required) |
| `k` | mark done (outcome `succeeded`/`failed`, optional result and evidence) |
| `x` | cancel (reason required) |
| `R` | resume: re-dispatch, attach to a session you pick, or unbind and leave pending |
| `O` | reopen a closed task (confirmation) |
| `u` | unbind from its session without changing state |
| `c` | add a comment |
| `e` | edit — open the ledger file at this task's heading |
| `t` | visit the source Org TODO (`SOURCE_FILE`/`SOURCE_HEADING`) |
| `F` | cycle the project filter |
| `g` | refresh (re-parse and reconcile); `q` quit |

Every command that changes a task goes through `agent-tasks--update-task`
(§1), so every one of them gets the visiting-buffer check, the conflict
check, and the atomic replace.

## 9. Integration boundaries

Each of these is one-directional, initiated here, and guarded.  None
modifies another module.

**Claude TODO batching.**  `agent-tasks-import-org-todos` creates one
`PENDING` task per Org TODO in the current buffer, subtree, or region,
inferring the scope the way `agent-claude-batch-todos` does (region if
active, subtree if narrowed, buffer otherwise) and recording
`SOURCE_FILE` and the verbatim `SOURCE_HEADING`.
`agent-tasks-capture-org-todo` does the same for the TODO at point.
Re-importing a file skips headings whose literal heading line is already
recorded on a task, and reports how many were skipped.

`agent-claude-batch-todos` is **not** changed, not deprecated, and not
reimplemented.  It is a batch runner over `claude -p`; this is a ledger.
Making the batch runner write ledger records would mean either coupling
`agent-claude.el` to an optional module or adding a second core observer
hook, and it would produce records for runs the ledger cannot observe or
resume.  Import is the honest seam: the person moves the work into the
ledger and dispatches it from there.

**Chief.**  `agent-tasks-chief-context` is a function suitable for
`agent-chief-context-functions` (`agent-chief.el:92`): it returns a
compact, deterministic summary of open tasks — one line each carrying
**state, title, project, and age**, capped at
`agent-tasks-chief-context-max` (default 20) with a truthful "and N
more" line.  Age is required, not decorative: the chief's whole job is
to notice drift, and "this has been `BLOCKED` for six hours" is the
observation it exists to make.  It performs no write and starts
nothing.  Adding it to the hook is the person's choice; nothing in this
design adds it.  This is the whole of the chief integration, and it is
enough: the chief's job is to notice and nudge, and it cannot notice
what it cannot see.

**Attention inbox.**  The ledger files an attention item through
`agent-attention-file`, when it is `fboundp`, for **exactly one
situation: a task moved to `UNKNOWN` because its session was torn
down**.  Teardown is the one case no session event covers — the
attention module files items for `blocked`, `error` and completion, and
a second item about the same fact would be duplicate noise, so the
`error` path here logs and transitions without filing anything.  The
item is filed against the session buffer, because
`agent-attention-file`'s behaviour with no buffer is not part of its
published contract and this design assumes nothing it did not verify.
Reconciliation, which by definition has no buffer, therefore files no
item and relies on its summary message and the list's sort order.  When
the attention module is absent, the fallback is a `message`, and the
manual says so.

**Queue.**  No integration.  A busy target is refused by name; the error
mentions `agent-queue-prompt` for a person who wants to queue prose.
Automatically queueing a task prompt would create a task that is neither
pending nor running, with no evidence channel that could ever resolve
it.

**Composer.**  No integration.  The composer builds a message from
context and sends it; the ledger sends a task's instruction.  A person
who wants both composes context and sends it into the task's session
after dispatch.

**Skill bundles.**  No integration.  A task's instruction may name a
skill or a bundle in prose, like any other instruction.

**agent-log.**  Read-only and optional, through the autoloaded
`agent-log-open-session`, with the same soft-require pattern as
`agent-history` (`agent.el:2665`).

## 10. Menu and manual

`agent-menu` gains two entries in the Tools column: `j` "task ledger"
(`agent-tasks`) and `J` "new task" (`agent-tasks-new`), both autoloaded
so the menu opens without the module loaded, and neither reading a store
at menu-construction time.

The keys are the free ones, not the mnemonic ones.  Every mnemonic
letter is taken by something that ships before this: the static menu
uses `e w h x r l K f S s n c a d m g T p i`, the per-backend columns
built at open time by `agent-menu--backend-children` generate
`B N b t u U -c -w` and `R F -x`, the attention/queue project takes
`A Q L I E`, the composer takes `C`, and the skill-bundles project takes
`W H k v`.  A test asserts each new key maps to its own command and that
no key in the prefix is bound twice **including the generated backend
columns**, because a test that walks only the static layout cannot see
that collision — the skill-bundles work hit exactly that.

README.org and its texi export gain a "Task ledger" section covering:
the file format and the parsed/written-only split; the six states, who
may cause each transition, and — stated plainly — that the ledger never
infers completion and never retries; what a binding proves and what it
does not; the dispatch order and each of its three failure modes; what
reconciliation does after a crash; the dependency gate and that it is
not a scheduler; the import seam from Org TODOs and that
`agent-claude-batch-todos` is unchanged; the chief context function and
that adding it is opt-in; and that `agent-tasks-mode` must be on to
dispatch.

## 11. Migration and backward compatibility

There is no prior ledger, so there is nothing to migrate.  What the
design owes instead is forward compatibility and non-interference:

- The file is created on first write with the header and the `#+TODO:`
  line.  A missing file is an empty ledger, not an error.
- `#+agent_ledger_version:` is written as `1`.  A file whose version is
  absent is treated as version 1 (a person may have hand-written it).  A
  file whose version is **greater** than this code understands is
  displayed read-only, with every write refused by name — a newer Emacs
  may have written fields this code would drop on rewrite.
- Nothing in the package behaves differently when `agent-tasks.el` is
  not loaded.  The two menu entries autoload it; nothing else references
  it.
- `agent-tasks-mode` off changes no behavior except that dispatch
  refuses.
- No existing defcustom changes its default, and no existing command
  changes its behavior.

## 12. Out of scope

An autonomous worker runtime, a scheduler, or anything that starts work
without a person; automatic retry of any kind; parallel task execution;
inferring task completion from backend events; a delegation protocol
between sessions; sub-tasks or a task hierarchy; time tracking,
estimates, or burndown; a Kanban board view with drag-and-drop; syncing
with GitHub issues, Asana, or org-agenda; modifying
`agent-claude-batch-todos`, `agent-chief.el`, `claude-code.el`,
`codex.el`, or `agent-log`; new `agent-backend` slots or new core hooks;
writing back to a source Org TODO automatically; queueing a task prompt
into a busy session; a second transcript renderer.

## 13. Verification

### ERT (deterministic, stubbed backends, temporary ledger files)

- **Parsing**: a full fixture round-trips every property, the body, and
  the four sub-headings; a missing file yields an empty list; a heading
  with an unrecognised keyword becomes a problem row naming the heading;
  a heading with no `AGENT_TASK_ID` becomes a problem row; sub-heading
  properties do not leak from the parent; a `Log` sub-heading with list
  items is preserved and never parsed into state.
- **Every problem class**: malformed `ATTEMPT`, `BLOCKED` with no
  reason, and `DONE` with no or invalid outcome each become problem rows
  rather than coerced values.
- **Duplicate ids reject every occurrence**: two headings sharing an id
  produce two problem rows and **no** task; `agent-tasks-find` returns
  nil for that id; and dispatch, closing, and commenting all refuse it
  rather than acting on whichever heading came first.
- **The body codec is injective**: `"* x"`, `" * x"`, `"  * x"`,
  `"   ** deep"`, `"  *bold* start"`, `"plain"`, `" plain"` and `""`
  each survive encode-then-decode byte-for-byte, no two of them share an
  encoding, and no encoded line begins with `*` at column zero.  A task
  created through `agent-tasks-create` with a star-heavy instruction
  reads back exactly.
- **The decode gate**: an entry *without* `BODY_ENCODED` has its body
  returned verbatim — a hand-written `" * a bullet"` keeps its space —
  while an entry created by this package round-trips through the codec.
  Interior blank lines and indentation are preserved in both cases;
  outer blank lines are not.
- **Property bytes**: a `SOURCE_HEADING` containing runs of internal
  whitespace is stored and read back with those runs intact; a value
  containing a newline is refused by name.
- **Anchored, case-sensitive source lookup**: with headings `* TODO
  Ship`, `* TODO Ship the second thing` and `* TODO ship` in one file,
  the lookup for `* TODO Ship` lands on exactly that line.
  `case-fold-search` defaults to `t`, so an unbound search matches the
  lower-case heading — verified in batch.
- **Version gate**: version 2 parses read-only and every write is
  refused by name; an absent version parses as 1.
- **Writing**: a state change rewrites exactly the keyword and
  `UPDATED`, compared as raw bytes with every other byte unchanged; a
  CRLF ledger stays CRLF; with `org-log-done` bound to `note` the write
  completes without prompting and inserts no `CLOSED` stamp; a modified
  visiting buffer refuses the write by name; a file changed since
  parsing is refused as a conflict; no temporary file survives a write
  (the listing must include dot files, since the temp file is one); an
  interrupted write (fault-injected rename failure) leaves the original
  intact.
- **Concurrency**: the conflict token is computed from raw bytes, so two
  files that decode alike but differ in bytes produce different tokens.
  An **interleaved two-writer test** drives the exact race: writer A
  parses, writer B parses the same bytes, B commits, then A attempts to
  commit — A is refused with a conflict, B's change is intact, and no
  task is lost.  A second test proves the lock serialises the sequence:
  with the lock file already present, a write fails after
  `agent-tasks-lock-timeout` with a message naming the lock, and the
  ledger is unchanged.  Lock release is checked on the success path and
  on a signalling one.
- **Snapshot coding**: a ledger carrying a `-*- coding: -*-` cookie, the
  same one **with CRLF line endings**, a plain CRLF ledger, a plain LF
  one, one matched by a `file-coding-system-alist` entry, one read under
  a `coding-system-for-read` binding, and one where a cookie and an
  alist entry **conflict** each yield the same coding system as
  `insert-file-contents`, decode to the same text, and round-trip to
  identical bytes.  The cookie-plus-CRLF case is the one that fails
  when the eol variant is dropped, and the conflict case is the one
  that fails when the cookie is ranked below the alist.
- **The snapshot is one read**: a fault-injected rename between the two
  reads revision 2 performed is caught, because there are no longer two
  — the test replaces the file between the token read and the text read
  and asserts the commit refuses rather than writing stale content.
  Token, decoded text, and coding all come from one byte string, and a
  CRLF ledger's coding is detected from it correctly.
- **Locked first creation**: two creators that both snapshot an absent
  ledger — the second forced to collide by stubbing the id generator —
  end with one task created and the other refused as a conflict, never
  with a duplicated id or an append onto a ledger the snapshot never
  saw.
- **Transitions are central**: reconciliation's move to `UNKNOWN` goes
  through `agent-tasks-transition` — asserted by stubbing that function
  and observing the call — so an orphaned `BLOCKED` task loses its
  `BLOCKED_REASON`; and a blank reason is refused by the transition API
  itself, not only by the cancel command.
- **State machine**: every allowed transition in the matrix succeeds and
  **every pair absent from the matrix is refused**, including
  `PENDING` → `BLOCKED`, driven as a table rather than a handful of
  examples; destination invariants are enforced (`DONE` without an
  outcome, `BLOCKED` without a reason, and a stale `OUTCOME` or
  `BLOCKED_REASON` surviving a move to another state are each refused);
  `CANCELLED` without a reason refused; reopening a closed task requires
  confirmation, tested with the confirmation both accepted and declined.
- **The event matrix, exactly**: drive the event consumer with every
  event type against a task in every state and assert the **exact**
  resulting state for each of the 36 combinations, from a table written
  out in the test.  Asserting only that the result "is not closed" would
  pass vacuously for the open states and fail for the closed ones.
- **Completion does not close**: a non-redundant `stop` on a bound
  session leaves the state unchanged and appends exactly one `Log` line;
  a redundant completion changes nothing at all.
- **Dependencies**: unsatisfied dependency refuses dispatch naming each
  one; a dependency `DONE` with outcome `failed` does not satisfy the
  gate; the prefix-argument override proceeds and logs; an unknown
  dependency id is a problem row; a two-node cycle and a
  self-dependency are both reported with their members.
- **Dispatch**: not-ready target refused by name, including the case
  where the display state says `waiting` but the readiness probe says
  busy; `unknown` requires confirmation, and a target that *became*
  `unknown` after the confirmation is refused while the confirmed one
  proceeds; declined confirmation sends and records nothing; a ledger
  write failure prevents the send entirely; a signalling `agent-submit`
  leaves the task `UNKNOWN`, never `PENDING`; a new session receives the
  message as `:initial-prompt` and the returned buffer is bound;
  `ATTEMPT` increments once per dispatch.
- **Commit against the reviewed snapshot**: for each of *cancelled*,
  *closed*, *cancelled-then-reopened* (which restores every field
  revision 2 compared), *instruction edited*, *recorded directory
  edited*, and *a new unsatisfied dependency added* between prepare and
  commit, the dispatch is refused naming the task, **nothing is sent**,
  and the ledger is unchanged.  Separately, a dependency that was
  *satisfied* at preview and reopened afterwards refuses too, with
  nothing sent and the ledger unchanged — the dispatched task's own
  bytes never change in that case, so the entry token cannot see it.  A successful override records each
  unsatisfied dependency and its state in the `Log`.
- **Zero-send ownership tests**: dispatching into a session already
  bound to another task sends nothing (the stub submitter records no
  call) and refuses by name; the same for a task already bound to a
  different buffer; and — the case revision 2 missed — the same for an
  already-bound task dispatched into a **new** session, where the
  assertion is that `agent-start-session` was never called.  These
  assert the *absence* of a send, because the defect they guard against
  is a prompt delivered before the error.
- **Prompt isolation**: a target whose `:pending-input-p` reports
  pending text refuses and sends nothing; a target reporting `unknown`
  refuses and sends nothing; a backend registering no probe refuses.
  Each runs with `agent-tasks-dispatch-confirm` **nil**, because a
  safeguard that only works when confirmation is on is not one.  Each
  also asserts the refusal left the ledger's **bytes**, the task's
  state, its attempt, and its unbound status unchanged — asserting only
  that nothing was submitted would pass for an implementation that
  wrote `RUNNING` first and then refused.  The
  send goes through `:submit-literal`, asserted by stubbing it and
  leaving `agent-submit` stubbed to fail the test if called.
- **Readiness precedence**: each of the three sources is tested in
  isolation, with the higher-precedence ones removed via `fmakunbound`
  or an unregistered slot, so the fallback branch is actually reached —
  revision 2's fallback test could not run, because the public helper
  exists once the attention/queue project has landed and always won.
  The fallback maps `busy` to `busy`, `waiting` to **`unknown`**, and
  `unknown` to `unknown`.
- **New-session identity**: a backend that resolves a different account
  than the task recorded, and one that returns a buffer with a
  collision-selected instance name, both end with the task's recorded
  identity matching the live session and a `Log` line noting the
  confirmation; a failing repair write leaves the task `RUNNING` and
  warns rather than reporting the dispatch as failed.
- **Message rendering**: byte-compared fixtures for attempt 1 and a
  re-armed attempt, and a test that `Result` and `Evidence` never appear
  in the message.
- **Correlation**: `agent-session-id-functions` fills `SESSION_ID` for a
  bound buffer and ignores an unbound one; a task dispatched into a new
  session has no `SESSION_ID` until the id arrives.
- **Binding lifecycle**: the bijection is enforced in both directions;
  closing a task with `agent-tasks-mark-done` or `agent-tasks-cancel`
  releases its binding, while a *failed* close leaves the binding in
  place; `agent-tasks--attach` refuses a task whose state is not
  `UNKNOWN` or `BLOCKED`; attaching clears the previous attempt's
  `SESSION_ID` before recording the new session's.
- **Teardown and reconciliation**: teardown of a bound buffer moves the
  task to `UNKNOWN` with a reason and files exactly one attention item;
  reconciliation re-binds a task whose recorded identity and session id
  match a live buffer; it refuses to re-bind when the ids differ while
  both are known; it refuses to re-bind on a directory match alone;
  everything else becomes `UNKNOWN` once, with a `Log` line and one
  summary message; reconciliation run twice writes only on the first
  pass.
- **Refresh always reconciles**: after a first refresh, a bound session
  buffer is killed *without* its teardown running (the binding table is
  manipulated directly, simulating a lost hook); the next explicit
  refresh moves the task to `UNKNOWN`.  A test that only called the
  once-per-session guard would pass while the feature was broken.
- **Restart**: with `agent-before-restart-functions` present, a matching
  resumed id re-attaches the binding and keeps the state; a mismatched
  id leaves it `UNKNOWN`; with the hooks absent, teardown's `UNKNOWN`
  path applies.  Both paths are driven through a **stand-in for the
  whole `agent-restart` command** — before-hook, kill, start, after-hook,
  then `post-command-hook` — rather than by calling the handlers in a
  hand-picked order:
  - a startup that **yields** (`sit-for`) and then succeeds ends
    `RUNNING` and re-bound, proving the finalizer cannot fire
    mid-command (a zero-delay timer here does, verified in batch);
  - a startup that **signals after the old buffer was killed** ends
    `UNKNOWN` once `post-command-hook` runs, never `RUNNING` and
    unbound;
  - a **later before-restart hook signalling before any kill** leaves
    the original session alive, so the task stays `RUNNING` and its
    binding is restored — not marked `UNKNOWN`.
- **Event write failures**: a conflicting ledger during event handling
  warns and does not signal into hook delivery, and the other consumers
  on the hook still run.
- **Import**: scope inference for region, narrowed buffer, and whole
  buffer; the verbatim heading is recorded; a re-import skips already
  imported headings and reports the count; importing from a non-Org
  buffer is refused.
- **Chief context**: deterministic output that includes each task's
  **age**, the cap honoured with a truthful "and N more", no writes, and
  an empty ledger yielding nil rather than an empty heading.
- **List columns**: a rendered row carries the task's account and a
  deps cell reading *unsatisfied*/*total*; a task with one satisfied and
  two unsatisfied dependencies renders `2/3`; a task with none renders
  an empty cell.
- **Mode**: with `agent-tasks-mode` off, dispatch is refused naming the
  mode, the list still renders, and the header says the mode is off;
  enabling and disabling the mode installs and removes every hook it
  owns (asserted by comparing hook values before and after).
- **Menu**: the layout walker is proved against three bindings that
  exist today (`s`, and `b`/`u` from the generated Claude column) before
  it is trusted; then `j` and `J` map to their own commands, and no key
  in the prefix is bound twice across the declared layout *and* the
  generated columns.

`make test` and `make compile` clean, with `agent-tasks.el` and
`test/agent-tasks-test.el` **appended** to the Makefile lists with `+=`,
the addition diffed against the committed lists to prove nothing
disappeared, and the test file registered before the failing-test step
that exercises it.

### Live verification (mutates nothing durable)

The checks run in a live Emacs, so isolation is a design problem, not a
formality.  Revision 1 got several parts of it wrong — a fixed `/tmp`
path two runs would share, `setq` on the ledger variable, `clrhash` on
the shared binding table, and a scratch git repository that did not
contain the ledger whose diff the checks were supposed to read.  The
rules:

The ledger's observers are **process-global** — the binding table, the
attention item list and its counter, the session-event subscriptions —
and they are shared with every real session in the Emacs that runs
them.  Revision 2 tried to isolate that from inside the running Emacs;
revision 3 improved the bookkeeping but could not cover the attention
inbox, and any mistake still landed in the person's working session.

The checks therefore run in a **dedicated `emacs -Q` process**, started
for the verification and killed after it:

- **Nothing to isolate.**  That process has no real session buffers, no
  attention items, and no configured real ledger — `agent-tasks-file`
  in it points only at a generated scratch root.  No global is saved or
  restored, because none of the person's globals is ever touched.
- **It can still start the backends.**  `-Q` suppresses the person's
  init, not the load path: the harness resolves the active profile and
  its package builds exactly as the Makefile does, requires `agent`,
  both backend modules, `agent-tasks` and — when present —
  `agent-attention`, and the account is selected inside that process
  before the first check.  A process that cannot start Claude or Codex
  cannot run any of these checks.
- **The real ledger's path is resolved from the running profile**, not
  written into the procedure, and its **presence and hash are recorded
  outside the scratch root** so cleanup cannot destroy the evidence
  before it is compared.  A change in either — content differing, or a
  ledger appearing where there was none — fails the verification with a
  non-zero status.
- **One generated root per run**, created with `mktemp -d`, containing
  a `git init`-ed repository with the **ledger file inside it**, which
  is what makes the byte-level `git diff` checks possible at all.  Every
  step uses that root; no step names a path of its own.
- **A fresh baseline commit before every check that reads a diff**, so
  one check's changes cannot be mistaken for the next one's.
- **Disposal is checked, not assumed.**  Setup runs under a failure
  trap: any failing step kills whatever process it started and removes
  the root rather than leaving both behind, and it polls for the
  process to become ready instead of sleeping a guessed interval.
  Teardown compares the real ledger first, then kills **the exact
  process id setup recorded** and confirms it is gone, then trashes the
  root and confirms it is gone, exiting non-zero if any check fails.
  It runs however the run ended, including after a crash.
- Task instructions are inert: "Reply with the words `task received` and
  do nothing else."  Every claim under test is about state transitions
  and bindings; none needs an agent that changes a file.

Both backends:

1. Create a task, dispatch it into a new session, and confirm from the
   conversation that the instruction arrived once; confirm the ledger
   shows `RUNNING`, the binding, and — after the backend reports one —
   `SESSION_ID`.
2. **Move focus to another frame or select a non-session window before
   the turn ends**, then let it complete.  Confirm the task is **still**
   `RUNNING` and that a `Log` line records the completion.  Confirm the
   ledger filed no attention item of its own for it, while the attention
   module's own completion item is present.  The focus step is not
   optional: `agent-attention-mode` deliberately files no completion
   item for a buffer the person is reading right now, so watching the
   session would make the second half of this check fail for a reason
   that has nothing to do with the ledger.  This is the design's central
   claim and the one most likely to have been implemented wrong.
3. Trigger a real permission prompt in the bound session and confirm the
   task becomes `BLOCKED` with a reason taken from what the backend
   reported; answer it and confirm the task returns to `RUNNING`.
4. Kill the session buffer and confirm the task becomes `UNKNOWN` with a
   reason, and that nothing is re-dispatched.
5. Simulate a crash without killing Emacs: with a `RUNNING` task written
   to the scratch ledger naming a session that does not exist, and the
   *scratch* binding table holding no entry for it, open the list and
   confirm reconciliation reports it `UNKNOWN` once, logs the reason,
   and re-binds nothing.  Then, still in the same Emacs, confirm that a
   **second** explicit refresh after another session is lost also
   reports it — the once-per-session guard must not apply to `g`.
6. `agent-restart` a session holding a running task and confirm the
   binding follows the resumed session (id matched) and that the state
   is unchanged.
7. Dispatch a task whose dependency is not `DONE` and confirm the
   refusal names the dependency; satisfy it and confirm the dispatch
   proceeds.
8. Dispatch into a mid-turn session and confirm the refusal names the
   session and does not alter the running turn.
9. Commit a fresh baseline, then close a task with an outcome and
   evidence and cancel another with a reason.  Confirm both
   records read truthfully with every other byte unchanged — `git diff`
   inside the scratch repository, which works because the ledger lives
   there and each check commits its own baseline.  Confirm the closed
   tasks' sessions are no longer bound.
10. **Commit a fresh baseline first** — check 9 left its closing
    changes uncommitted, and without one this check would be reading
    check 9's diff — then confirm prompt isolation for real: type some
    text into an idle session's prompt without submitting it, and
    dispatch a task there.  The dispatch must **refuse** naming the
    pending input; the typed text must still be sitting unsent in the
    prompt; the task must still be `PENDING` with attempt 0 and no
    binding; and the diff must be empty.  Run it with
    `agent-tasks-dispatch-confirm` bound to nil, because that is the
    configuration in which a confirmation-buffer warning would have
    protected nobody.

Import is verified against a **copy** of a few Org TODOs inside the
scratch repository, never against a real notes file.  The chief context
function is verified by calling it and reading its output; it is never
added to `agent-chief-context-functions` in a real Emacs during the
check.
