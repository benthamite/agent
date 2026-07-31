# Skill Bundles and Reviewable Learning — Design

## Problem

`agent` discovers skills across both backends and runs exactly one at a
time (`agent-run-skill`).  Everything else about a skill's life is
invisible:

- Nothing records which skill instructions a session actually loaded,
  from which file, at which revision, so a later review of a session
  cannot say what policy the model was following.
- Nothing validates the discovered set.  `agent-discover-skills` lets a
  later root silently shadow an earlier one, drops any `SKILL.md` whose
  frontmatter fails to parse, and reports neither.
- Nothing remembers that a skill ever ran.
- Named multi-skill workflows exist only as two hard-coded special
  cases — `agent-audit-skills` (batch, auto-commit between steps) and
  `agent-before-exit-skill-names` (submitted into the dying session) —
  neither of which the user can name, reuse, or point at a live session.

Separately, agent-authored learning candidates already accumulate.  The
`session-learning-capture` skill writes Markdown candidate files into a
central inbox after sessions, deliberately as proposals rather than
durable memory; that inbox currently holds 1136 files.  The second
stage — reviewing candidates, approving or rejecting them, and handing
approved ones to an implementation session — has no implementation at
all, in Emacs or anywhere else.  The skill's own documentation names a
`session-retro` skill that does not exist.

## What this design deliberately does not do

**No automatic persistent memory injection.**  Nothing here makes a
model-authored learning active by itself.  Approval is a recorded human
decision, not an installation step; approved candidates reach a target
artifact only through an ordinary agent session the user starts on
purpose, and the change lands through that session's normal review.  No
command in this design edits `CLAUDE.md`, `AGENTS.md`, a skill file, a
hook, or any other target artifact, and no command applies a proposed
patch.

## Verified capabilities this design rests on

Verified by reading the installed tree, not assumed.

| Fact | Where |
|---|---|
| Skill discovery returns plists with `:name`, `:description`, `:path`, `:style`, argument metadata; later roots shadow earlier ones | `agent-discover-skills`, `agent.el:2101` |
| Both backends register `:skill-roots` and a `:skill-command-prefix` (`/` for Claude, `$` for Codex); Claude has `slash` and `file` roots, Codex only `file` | `agent-claude-skill-roots`, `agent-codex-skill-roots` |
| `run-prompt` is a **batch** channel (`claude -p`, `codex exec`) with a completion callback, not the live session | `agent--run-skill`, `agent-claude-run-prompt`, `agent-codex-run-prompt` |
| `agent-submit` puts text into the live session and submits it; `agent-start-session` accepts `:initial-prompt` | `agent.el:1457`, `agent.el:311` |
| `agent-session-display-state` returns `busy`, `waiting`, `background-waiting`, `unknown`, and `unknown` is never guessed away | `agent.el:1000` |
| Skills live in a git repository in practice (`~/.claude/skills` → `~/My Drive/dotfiles/claude/skills`), so commit provenance is obtainable | verified with `git rev-parse --show-toplevel` |
| The learning inbox format is a Markdown file with a header block and `## Candidate N: TITLE` sections of `**Field:** value` lines | `~/.claude/skills/session-learning-capture/SKILL.md`, and the 1136 existing files |

**No new `agent-backend` slot is required.**  Everything below dispatches
through slots that already exist.  That is a deliberate result, not an
accident: the backend-neutral contract for this feature is the existing
one.

## Boundary and module layout

Two new optional modules, each in the mould of `agent-capture.el`:
loading one installs no hooks and changes no keymaps; only its commands
do anything.

- **`agent-skill.el`** — bundles, provenance, usage history, health
  checks.  Requires `agent`.
- **`agent-learn.el`** — the learning-candidate review inbox.  Requires
  `agent`.  Independent of `agent-skill.el`.

`agent.el` gains one hook and one function (§3) and four menu entries.
`agent-log` is untouched: it owns the durable transcript archive, this
owns "which instructions were in force".  The two modules never read or
write each other's stores.

## 1. Bundles

### Data format

```elisp
(defcustom agent-skill-bundles nil
  "Named ordered groups of skills.")
```

An alist.  Each entry is `(NAME . PLIST)` where NAME is a string and
PLIST accepts:

| Key | Type | Meaning |
|---|---|---|
| `:description` | string | shown in completion annotation and previews |
| `:skills` | list | ordered; each element is a skill-name string or `(NAME :args STRING :optional BOOL)` |
| `:instruction` | string | prose prepended to the rendered message |
| `:backends` | list of symbols | backends this bundle is valid for; nil means any |

`:optional` marks a step that is skipped, with a note in the preview and
the record, when the skill is not discoverable for the target backend.
Without it a missing skill aborts the dispatch — the default, because a
bundle that silently runs half of itself is worse than one that refuses.

The default value is nil.  Shipping `review-pr`/`implement-plan`/
`release-package` defaults would name skills that a given user may not
have, and the health check (§5) would then report errors about the
package's own defaults.  The manual instead carries copy-pasteable
examples of exactly those three workflows.

### Rendering (pure, deterministic, fixture-tested)

`agent-skill-bundle-message` is a pure function of the bundle and the
resolved skill list.  It produces one message:

```
<instruction, when the bundle sets one>

Run these skills in order.  Do not skip a step and do not reorder them.

1. `pr-audit` — /Users/…/claude/skills/pr-audit/SKILL.md
   Arguments: --accept
2. `code-audit` — /Users/…/claude/skills/code-audit/SKILL.md

Read each skill file before starting that step and follow its
instructions exactly.  Resolve relative paths mentioned by a skill
relative to that skill file's directory.

Bundle: review-pr
```

One rendering, no per-style special case: bundles always reference skill
files by absolute path, including for Claude `slash`-style skills.  A
message cannot carry more than one native slash expansion, so a
style-dependent rendering would work for one-skill bundles and break
silently for the rest.  The trade-off is real and documented: native
`/name` expansion (which on Claude engages the CLI's own skill loading)
remains available through `agent-run-skill`; bundles trade it for
ordering that behaves identically on both backends.

The rendered message is exactly what the session receives, so **the
model-visible skill list is in the session transcript by construction**.
Emacs additionally records it (§4).

### Dispatch

`agent-skill-run-bundle` (autoloaded, interactive):

1. Read the bundle (completion, annotated with description and step
   count).
2. Read the target: an existing session (completion over live sessions,
   labelled as elsewhere) or "new session…".
3. Resolve each step against `agent-discover-skills` for the target
   backend.  A missing non-optional skill is a `user-error` naming the
   skill and the backend; nothing is sent.  A bundle whose `:backends`
   excludes the target is a `user-error`.
4. Collect provenance (§4) for every resolved skill.
5. Show `*Agent bundle: NAME*` — the target, the resolved steps with
   their paths, commits and dirty flags, any skipped optional steps, and
   the exact outgoing message.  Confirm (`agent-skill-bundle-confirm`,
   default t; a nil value skips the buffer and confirms in the
   minibuffer).
6. For an existing target, check `agent-session-display-state`: `busy`
   → `user-error` naming the state; `unknown` → explicit confirmation;
   waiting states proceed.  This is the same policy the context-composer
   design applies, and for the same reason: no queue exists yet.  When
   the attention/queue project lands, this is the one place that changes,
   through its public contract.
7. Dispatch: `agent-submit` for an existing session;
   `agent-start-session` with `:initial-prompt` for a new one (backend,
   account and directory read the same way `agent-start-new-session`
   does, with the directory defaulting to the current project root).
8. Record the activation (§4) and report `"Dispatched bundle NAME (N
   skills) to SESSION"`.  As everywhere else in this package,
   "dispatched" means the text was submitted at the session's prompt,
   which is all a terminal transport can attest.

Failure at any step leaves nothing sent and nothing recorded.

## 2. Where bundles do not go

`agent-audit-project` keeps its own batch runner: it runs skills through
`run-prompt` in a separate process and commits between steps, which is a
different operation from putting instructions into a live session.  It is
not reimplemented as a bundle and not deleted; it gains only the
invocation records of §3.  Likewise `agent-before-exit-skill-names`
keeps its own chain, which is coupled to session teardown.  Unifying the
three runners would mean building a sequential submit-and-wait driver
inside this project, duplicating exactly what the planned
`agent-queue.el` drain does.  Bundles therefore send **one message**;
step-at-a-time dispatch is deferred to the queue project.

## 3. Core contract: invocation records (`agent.el`)

```elisp
(defcustom agent-skill-invocation-functions nil
  "Abnormal hook run with one plist each time a skill is invoked.")

(defun agent-note-skill-invocation (plist) ...)
```

`agent-note-skill-invocation` fills in `:id` (a random invocation id) and
`:time` (float time) when absent, then runs the hook with the completed
plist.  Consumers run inside `condition-case`; a signalling consumer is
reported with `display-warning` and does not disturb the caller, because
the callers are dispatch paths in the middle of starting real work.

Plist keys, all optional except `:skill` and `:origin`:

| Key | Value |
|---|---|
| `:id` | invocation id string |
| `:time` | float time |
| `:skill` | skill name string |
| `:origin` | `run-skill`, `bundle`, `audit`, `before-exit` |
| `:bundle` | bundle name, with `:step` and `:steps` integers |
| `:backend` | backend symbol |
| `:mode` | `session` or `batch` |
| `:args` | argument string or nil |
| `:buffer` | session buffer, when there is one |
| `:directory` | directory the invocation targets |
| `:path` | the skill's `SKILL.md` path, when the emitter knows it |
| `:source` | provenance plist (§4), when the emitter already resolved it |
| `:outcome` | `dispatched`, `ok`, `error` |
| `:error` | error string, when the outcome is `error` |

Four emitters, all in `agent.el` except the last:

- `agent--run-skill` — `:origin run-skill`, `:mode batch`,
  `:outcome dispatched`; its callback emits a second record with the same
  `:id` and `:outcome ok`/`error`.
- `agent--audit-run-next` — `:origin audit`, `:mode batch`, same
  two-record shape.
- `agent--before-exit-submit-next` — `:origin before-exit`,
  `:mode session`, `:outcome dispatched` (a terminal submission attests
  nothing further).
- `agent-skill.el`'s bundle dispatcher — `:origin bundle`, `:mode
  session`, one record per step, all sharing the activation's provenance
  pass.

Core computes no provenance itself.  It reports `:path`, which it knows;
`agent-skill.el` supplies a full `:source` for bundles, and resolves one
from `:path` for the other three origins when it records them.  `agent.el`
gains no git calls.

One further core change supports this: `agent-discover-skills` adds
`:root` (the discovery root the file came from) to each skill plist.  It
is a strict addition to an existing public return value.

## 4. Provenance and usage history (`agent-skill.el`)

### Provenance of one skill

`agent-skill-provenance SKILL` returns a plist:

| Key | Value |
|---|---|
| `:path` | absolute `SKILL.md` path |
| `:root` | the discovery root it came from |
| `:style` | `slash` or `file` |
| `:content-sha1` | SHA-1 of the `SKILL.md` bytes |
| `:repo` | git top level, or nil |
| `:commit` | `HEAD` of that repo, or nil |
| `:dirty` | non-nil when the skill file has uncommitted changes |

The content hash is always available and is the authoritative answer to
"which instructions were these".  The commit locates them in history; the
dirty flag says the commit alone does not describe the file.  Auxiliary
files in the skill directory (references, scripts) are covered by the
commit when the repo is clean and by the dirty flag when it is not; the
manual states that limit rather than implying per-file hashing.

Git calls are made fresh each time and never cached: caching would trade
a bounded cost (three `git` calls per skill) for a class of
stale-provenance bugs in exactly the data whose point is to be
trustworthy.  `agent-skill-record-git-provenance` (default t) turns the
git half off for users on slow or non-git skill trees, leaving path,
style and content hash.

### Usage history

`agent-skill-history-file`, default
`(expand-file-name "agent/skill-history.jsonl" user-emacs-directory)` —
append-only JSON Lines, one object per record, written with
`json-serialize` and a single appending `write-region`.  A record is the
§3 plist with symbols rendered as strings and the buffer rendered as the
session identity (`backend`, `directory`, `instance`, `account`, `id`).

Recording is owned by a global minor mode, `agent-skill-mode`, which
subscribes to `agent-skill-invocation-functions`.  Loading the module
installs nothing.  With the mode off, bundles still work and still show
provenance; only the durable history stops being written, and the
history buffer says the mode is off rather than showing a stale file as
if it were current.

Rotation: when the file exceeds `agent-skill-history-max-bytes` (default
5 MiB) the append renames it to `FILE.1` (replacing any previous `.1`)
and starts a new file — one rollover, no scheme.

Reads: `agent-skill-history-entries (&optional limit)` returns the last
LIMIT records, newest first, skipping malformed lines and counting them.
`agent-skill-history` shows them in a `tabulated-list-mode` buffer —
time, origin, bundle, skill, backend, mode, commit (abbreviated, with a
`*` for dirty), outcome — with `RET` for the full record, `g` to
refresh, and a header line stating how many records were read and how
many lines were unparsable.  Nothing is silently dropped.

### Live session view

`agent-skill.el` keeps a buffer-local list of the records dispatched into
each session buffer.  `agent-skill-describe-session` renders it: what was
sent, when, from which file, at which commit, and whether the file was
dirty at dispatch.  It dies with the buffer by design; the JSONL is the
durable copy, so no teardown registration is needed.

## 5. Health checks (`agent-skill-check`)

An explicit command producing `*Agent skill health*`
(`tabulated-list-mode`: severity, backend, skill, issue, detail).
Checks, over every registered backend's roots and every configured
bundle:

| Severity | Check |
|---|---|
| error | `SKILL.md` present in a root but frontmatter unparsable or `name:` missing |
| error | bundle step naming a skill no backend in `:backends` can discover |
| error | bundle entry malformed (unknown key, non-string name) |
| warning | `name:` differs from the containing directory name |
| warning | same skill name provided by more than one root (names the winner and each shadowed path) |
| warning | `description:` missing or empty |
| warning | `argument-source` glob matching no files |
| warning | `argument-choices` present but empty after parsing |
| info | skill file not in a git repository (no commit provenance) |
| info | skill file has uncommitted changes |

The summary line reports counts by severity.  The command is read-only:
it never edits a skill, a bundle, or a file.

Shadowing deserves the emphasis it gets here.  `agent-discover-skills`
resolves collisions by root order with no report, so a project-level
`SKILL.md` can quietly replace a global one and nothing anywhere says so.
The check is the first place that becomes visible.

## 6. Reviewable learning (`agent-learn.el`)

### Store

`agent-learn-directory` (default
`(expand-file-name "agent/learnings/" user-emacs-directory)`), with
`inbox/` and `archive/YYYY-MM-DD/` beneath it.  That is exactly the
layout the existing dotfiles inbox uses, so setting the option to
`~/My Drive/dotfiles/.agent-learnings/` makes the 1136 existing files
reviewable with no conversion.

### Record format

The existing candidate-file format is the format; this design adds one
line and changes nothing else.  A file has a header block
(`# Session learning candidates: …`, `Source transcript:`, `Working
directory:`, `Captured:`) and one or more `## Candidate N: TITLE`
sections of `**Field:** value` paragraphs.

Review state is written **into the file**, as the first paragraph after
the candidate heading:

```markdown
## Candidate 1: Harden ad hoc zsh repo-audit loops

**Review:** approved 2026-07-31 — worth doing in agent.el

**Origin / trigger:** …
```

States are `approved`, `rejected`, and `archived-unreviewed`; a
candidate with no `**Review:**` line is `pending`.  Rejection requires a
reason, approval takes an optional note.  A dispatch to an
implementation session appends a second line,
`**Dispatched:** 2026-07-31 — SESSION-LABEL`, which is a fact about what
happened, not a fourth state.

Storing state in the file keeps one artifact per capture, survives moving
the directory, needs no database, and is legible outside Emacs — which
matters, because the producer is a CLI skill and the consumer here is
optional.  The writer only ever inserts or replaces the `**Review:**`
and `**Dispatched:**` lines; every other byte of an agent-authored file
is preserved verbatim.

### Parsing and scale

`agent-learn-file-limit` (default 200) bounds how many inbox files are
read, newest first by file name then mtime.  The list buffer's header
line always states "N candidates from M of K files" so a bounded view
never reads as a complete one; `L` re-reads with a different limit.
Unparsable files are listed as a single row naming the file and the
problem instead of being skipped.

### Review UI

`agent-learn` (autoloaded) opens `*Agent learnings*`
(`tabulated-list-mode`): state, value, safety, action, project, title,
captured date.  Sorted pending first, then by `Value` descending, then
newest first.

| Key | Action |
|---|---|
| `RET` | detail buffer with the full candidate text |
| `a` | approve (optional note) |
| `r` | reject (required reason) |
| `e` | edit — open the file at the candidate heading |
| `A` | archive the candidate's whole file to `archive/YYYY-MM-DD/` |
| `i` | implement — dispatch an approved candidate to a session |
| `t` | toggle showing archived files |
| `L` | re-read with a different file limit |
| `g` | refresh; `q` quit |

`A` refuses a file with unresolved candidates unless confirmed, and a
confirmed force marks those candidates `archived-unreviewed` first — a
candidate never leaves the inbox without a recorded decision.
`agent-learn-archive-resolved` archives every listed file whose
candidates are all resolved, after confirming a count.  Both are
`rename-file` within `agent-learn-directory`; nothing is deleted, ever,
by any command in this module.

### Implementing an approved candidate

`i` (`agent-learn-implement`) requires state `approved` and builds a
prompt from the candidate: title, project, summary, why it matters,
proposed action, target artifact, evidence, risk, the source file path,
and the proposed patch when present — the patch clearly labelled as an
unverified suggestion from an earlier session, to be re-derived rather
than applied on faith.  The prompt ends with an instruction not to treat
approval as verification.

Target selection, the busy/unknown policy, and the meaning of
"dispatched" are identical to §1's dispatch, and the two share one
internal helper.  On success the `**Dispatched:**` line is written.
Nothing else in the tree is touched.

## 7. Menu and manual

`agent-menu`: the Tools column gains `b` "run skill bundle", `u` "skill
usage history", and `k` "check skills"; the Prompts column becomes
"Prompts & learning" and gains `L` "review learnings".  No existing key
moves.  Every entry is autoloaded, so the menu still opens without the
new modules loaded, and none of them reads a store while the menu is
being built (the laziness invariant the agent-log work established).

README.org and its texi export gain a "Skill bundles" section and a
"Reviewable learning" section covering: the bundle format and the
worked `review-pr`/`implement-plan`/`release-package` examples; the
one-message dispatch rule and what it trades away; the busy/unknown
policy; what provenance does and does not cover; where the history file
lives, what a record contains, and that `agent-skill-mode` owns writing
it; the health checks and what shadowing means; the candidate file
format with the `**Review:**` line; the review lifecycle; and — stated
plainly — that approval never installs anything.

## 8. Out of scope

Automatic memory injection of any kind; editing target artifacts;
applying proposed patches; a diff or patch UI; generating learning
candidates from Emacs (the capture skill owns that); rewriting or
splitting agent-authored candidate files; a learnings database, search
index, or dedup engine; migrating `agent-audit-skills` or
`agent-before-exit-skill-names` to bundles; step-at-a-time bundle
dispatch (queue project); any change to `claude-code.el`, `codex.el`, or
`agent-log`; new `agent-backend` slots; skill authoring, installation, or
version management.

## 9. Verification

ERT, deterministic, with stubbed backends, stubbed `process-file`, and
temporary directories:

- Bundle resolution: missing skill aborts; `:optional` missing skill is
  skipped and noted; `:backends` mismatch refuses; malformed entry
  refuses.
- Renderer fixtures: multi-step with and without arguments, instruction
  present and absent, skipped optional step, one-step bundle.  The
  message is byte-compared.
- Dispatch: busy target refused by state name; unknown state requires
  confirmation; declined confirmation sends and records nothing; new
  session passes the message as `:initial-prompt`; a signalling submit
  records nothing.
- Invocation records: each of the four origins emits with the right
  `:origin`/`:mode`; batch origins emit a second record correlated by
  `:id`; a signalling consumer warns and does not break dispatch;
  two-record ordering is stable.
- Provenance: content hash matches the file; non-git tree yields nil
  `:repo`/`:commit` without error; dirty flag set from stubbed `git
  status` output; `agent-skill-record-git-provenance` nil skips git
  entirely.
- History: append round-trips through the reader; malformed line counted
  and skipped; rotation at the size limit preserves the old file as
  `.1`; reading a missing file yields empty, not an error; mode off
  writes nothing.
- Health: each check fires on a fixture tree, including two roots
  providing the same name (winner and shadowed paths both reported) and
  a bundle naming an unknown skill.
- Learning parser: header and multi-candidate files; all documented
  fields; a fenced proposed patch containing `**bold**` and blank lines;
  a file with no candidates; an unparsable file becomes a row.
- Learning writer: inserting a `**Review:**` line, replacing an existing
  one, and appending `**Dispatched:**`, each byte-compared against an
  expected file, with every other byte unchanged.
- Archive: resolved-only bulk archive moves the right files; forcing an
  unresolved file marks its candidates `archived-unreviewed` first; no
  command deletes.
- Implement: refuses a non-approved candidate; prompt contains the
  patch under its unverified label; writes `**Dispatched:**` only after
  a successful dispatch.

`make test` and `make compile` clean, with the two new modules and their
two test files added to the Makefile.

Live, both backends: dispatch a two-skill bundle into an idle session and
confirm from the conversation that the model read both skill files in
order; dispatch a bundle into a new session through `:initial-prompt`;
confirm a busy session refuses; check the history file's records against
what was actually sent, including a deliberately dirty skill file;
run the health check against the real skill tree and confirm each
reported shadowing and frontmatter problem by inspection; review real
candidates from the existing 1136-file inbox — approve, reject, edit,
archive, and implement one — and confirm the files are modified only in
the `**Review:**`/`**Dispatched:**` lines.
