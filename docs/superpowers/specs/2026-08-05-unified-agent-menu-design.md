# A Unified, Model-Agnostic `agent-menu`

## Problem

`agent-menu` ends in two headings named after backends.  The first group is
four static columns — Sessions/Buffer, Tools/Alerts, Prompts, Options — all
already backend-agnostic.  The second is dynamic: `agent-menu--backend-children`
builds one column per registered backend out of that backend's
`:menu-suffixes` slot, titled with its `:label`.

Those two columns are lopsided.  Claude Code contributes eight entries,
Codex three:

    Claude Code                       Codex
    B  switch branch                  R  codex resume
    N  new branch                     F  codex fork
    b  batch todos                    -x codex account
    t  send todo at point
    u  start status polling
    U  stop status polling
    -c claude account
    -w warn kill with branches

The split does not describe two different kinds of work.  It records which
file each command happened to be written in.  Branch switching, batch todos,
and todo-at-point are ordinary session workflows that live in
`agent-claude.el` because Claude came first; resume and fork are ordinary
session workflows that live in `agent-codex.el` for the same reason.  A user
who runs a Codex session cannot batch todos through it, and a user who runs a
Claude session sees no resume entry, though `agent-start-session` has taken
`:resume-id` since the architecture refactor.

The goal: one model-agnostic command list, where every command works with
both backends, and no per-backend heading at all.

## Boundary

`codex.el` (github.com/benthamite/codex) is the user's package and may be
changed to close the gap.  `claude-code.el` is not, and is read-only here.
`agent-log` is a separate package that `agent` never requires; the menu's
`l` entry keeps delegating to it through a soft require, and nothing in this
work adds a dependency in either direction.

## Design

### The menu

The second transient group is deleted.  `agent-menu` becomes a single static
group of four columns:

    Sessions              Tools                 Prompts             Options
    e start or switch     s run skill           p capture prompt    -A alert on ready
    w jump to waiting     n new CR task         i insert prompt     -p protect buffers
    R resume              c post-push CI        b batch todos       -t sync theme
    N new branch          a audit project       t send todo         -c account
    B switch branch       d debug backtrace                         -w warn kill w/ branches
    h handoff             m act on Slack message
    x exit session        g act on Forge notification
    r restart
    l history             Alerts
                          T toggle alert
    Buffer
    K setup kill on exit
    f fix rendering
    S disable scrollback

Keys are chosen to preserve muscle memory: `B`, `N`, `b`, `t`, `-c` and `-w`
keep their current meaning, and `R` keeps Codex's resume key while gaining
Claude.  Nothing collides with the static columns.  Codex's `F` folds into
`N`, and `-x` into `-c`.

The vocabulary stays "branch" rather than the CLIs' "fork", because that is
what the existing Claude commands are called and what the user reads today.
The underlying operation is a fork in both CLIs, and the Elisp names say
branch: `agent-create-branch`, `agent-switch-branch`.

Two entries leave the menu.  `agent-claude-start-status-polling` and
`agent-claude-stop-status-polling` stay interactive and reachable through
`M-x`, but they are session plumbing — polling already starts from
`agent-claude--start-hook-functions` on every session start — and Codex has
no honest twin, since it learns turn state from the app-server's JSON-RPC
stream.  A model-agnostic list is the wrong home for them.

### Command by command

**`R` `agent-resume`.**  New backend slot `:resume`, a function of one
argument, the raw prefix arg.  Claude registers `claude-code-resume`, Codex
registers `codex-resume`; both already exist and both interpret a prefix arg
as "most recent".  `agent-resume` picks the backend with the existing
`agent--resolve-backend` — the current buffer's backend when in a session,
the only registered backend when there is one, otherwise a prompt — and calls
the slot.  Delegating to each backend's native picker is deliberate: Claude's
`--resume` opens the CLI's own picker, and Codex's app-server path lists
threads over `thread/list`.  Reimplementing one Emacs-side picker would
duplicate `agent-log`, which the `l` entry already reaches.

**`N` `agent-create-branch`.**  Generalizes `agent-claude-create-branch`.  The
command reads the current session's id through the existing
`:session-identity` slot, then calls `agent-start-session` with `:resume-id`
and `:fork t`, exactly as the Claude version does.  With a prefix argument it
first creates a git worktree on a fresh branch under a renamed
`agent-branch-worktree-directory` and starts the fork there; that code
(`--git-toplevel`, `--make-fork-worktree`, `--git-worktree-add`) is plain git
and moves to `agent.el` unchanged.

One step in the isolated path is genuinely backend-specific.  Claude stores
transcripts per project directory, so forking into a worktree requires
`agent-claude-cli-link-session-into-project` to link the parent session into
the new project directory before the fork starts.  Codex stores sessions
globally under `~/.codex/sessions` and needs nothing.  That becomes an
optional slot, `:prepare-fork`, called with (SESSION-ID FROM-DIR TO-DIR) and
registered only by Claude.  A nil slot means "nothing to prepare", not
"unsupported".

**`B` `agent-switch-branch`.**  The tree machinery in `agent-claude.el` is
already generic: `agent-claude--find-branch-root`,
`--build-children-map`, `--collect-tree-members`, `--format-branch-tree`,
`--format-branch-subtree` and `--format-branch-timestamp` operate on a hash
table of session id → plist with `:session-id`, `:forked-from`, `:timestamp`
and `:first-prompt`.  Nothing in them knows about Claude.  They move to
`agent.el` under `agent--branch-*` names.

What stays per-backend is the scan that produces that hash, split in two so
the cheap half can run alone:

- `:session-headers`, called with a session buffer, returns the hash of
  header plists (`:session-id`, `:forked-from`, `:timestamp`) for every
  session that could be in the buffer's branch family.
- `:session-prompt`, called with one header plist, returns it enriched with
  `:first-prompt` (and a corrected `:timestamp` where the header's is
  approximate).

`agent-switch-branch` scans headers, walks to the branch root, collects the
tree members, enriches only those members, renders the tree, and reads a
selection.  Selecting the current session says so; selecting a session that
already has a live buffer switches to it; anything else resumes it in a new
buffer named `branch-<8 chars of id>`.

Finding the live buffer for a session id becomes general too.
`agent-claude--find-buffer-for-session` parses Claude status files; the
replacement walks `agent-session-buffers` and compares `agent-session-id`,
which both backends now keep current (Claude from status polls, Codex from
hook events and submissions).

**`b` `agent-batch-todos` and `t` `agent-send-todo-at-point`.**  Both move,
with their supporting machinery, into a new file `agent-todo.el`.

`agent-send-todo-at-point` is already backend-agnostic apart from session
lookup: it collects the org entry at point, formats it, and calls
`agent-submit`.  `agent-claude--resolve-session-for-file` is replaced by a
general resolver that asks every registered backend's `find-buffers-for-dir`
slot for the current project directory, uses the sole match when there is
one, and prompts when there are several or none.

`agent-batch-todos` needs the backend's non-interactive runner, and the
normalized `run-prompt` slot is the wrong one: its callback receives only
(TEXT &key ERROR), while batch processing writes each entry's raw output to a
timestamped JSON log and reports per-entry duration and cost.  Both backends
already have a private runner with a richer, and identically shaped, result
plist — `agent-claude--run-prompt` and `agent-codex--run-prompt`, each
returning `:exit-code`, `:duration`, `:text` and `:raw`, with Claude adding
`:cost` and `:session-id`.  A new slot `:exec-prompt` exposes exactly that
contract: called with (PROMPT &key dir callback), the callback receives the
plist, in which `:exit-code`, `:duration`, `:text` and `:raw` are required
and `:cost` and `:session-id` are optional.  `codex exec` reports no cost, so
Codex batch summaries show a blank cost column rather than a fabricated zero.

The customizations move with the code and keep working under their old names:
`agent-claude-log-directory` → `agent-todo-log-directory`,
`agent-claude-org-todo-in-progress-keyword` → `agent-todo-in-progress-keyword`,
`agent-claude-fork-worktree-directory` → `agent-branch-worktree-directory`,
each with a `define-obsolete-variable-alias`.

**`-c` account.**  One infix replaces `agent-claude--infix-account` and
`agent-codex--infix-account`.  It displays every registered backend's current
account at once, so the menu answers "which accounts am I on" without being
pressed:

    -c account (claude: work  codex: personal)

Pressing it resolves a backend with `agent--resolve-backend` — no prompt
inside a session buffer, a prompt outside one — then prompts for that
backend's account and applies it through the existing `agent-account-set` and
`agent-account-sync`.  The infix class is a subclass of the existing
`agent-account-variable` whose `backend` slot is unbound until read time,
with a `transient-format-value` method that renders the summary.  The
subclass lives in `agent.el`, not `agent-account.el`: `agent-account.el` sits
below `agent.el` in the dependency order and must not learn about
`agent--resolve-backend`.

**`-w` warn kill with branches.**  `agent-claude-warn-kill-with-branches`
becomes `agent-warn-kill-with-branches` (obsolete alias for the old name),
and `agent-claude--confirm-kill-branches` becomes `agent--confirm-kill-branches`
in `agent.el`, built on the general header scan.  `agent`'s kill path runs it
for any backend that registers `:session-headers`, before consulting the
backend's own `:before-kill-check`, which stays available for other
backend-specific vetoes.  Claude's registration of that slot drops, because
the branch confirmation was its only use.

### Backend struct

Added slots: `resume`, `session-headers`, `session-prompt`, `exec-prompt`,
`prepare-fork`.

Removed slot: `menu-suffixes`, together with `agent-menu--backend-children`,
`agent-menu--backend-column` and `agent-menu--sorted-backends`.  Nothing else
in either package references them; `agent-menu--sorted-backends` exists only
to order the columns being deleted.  Removing the slot is the point of the
exercise: after this change there is no mechanism by which a backend can add
a heading of its own to the menu.  A future backend that needs a command
contributes a slot implementation, and the command lives in `agent.el`.

Every new slot is optional.  A backend that registers none of them still
starts, sends, and exits sessions; it simply reports "backend `x' does not
support …" from the commands that need what it lacks.  Both shipped backends
register all five, except `prepare-fork`, which only Claude needs.

### Codex parity

**`codex.el`.**  `codex-start-session` gains a `:fork` keyword.  For the CLI
terminal backends it produces the switches `("fork" SESSION-ID)` instead of
`("resume" SESSION-ID)`; `codex fork [SESSION_ID] [PROMPT]` is a documented
subcommand of the installed CLI (verified against `codex fork --help`).  For
the app-server backend it adds `codex--app-server-launch-fork-session`, a
near-copy of the existing `codex--app-server-launch-resume-session`: it binds
a new `fork-session` value of `codex--app-server-pending-startup-action` plus
the pending session id, and `codex--app-server-after-initialize` dispatches
that action to `codex--app-server-send-resume` with the `"thread/fork"`
method and the transcript path found by `codex--find-session-transcript`.
That is the same pair of arguments the interactive `fork` action already
sends, minus the thread picker.

**`agent-codex.el`.**  `agent-codex--start-session` accepts `:fork` and
passes it through.  Two new functions implement the header slots.

`agent-codex--session-headers` scans `codex-transcript-sessions-directory`
for `rollout-*.jsonl` files and reads the first line of each, which is the
`session_meta` record.  From its payload it takes `cwd` (to keep only
sessions from the buffer's project), `timestamp`, and the lineage fields
`forked_from_id` and `parent_thread_id`.  Measured cost of a full scan of
3,185 rollout files on the user's machine: 0.82 seconds, reading a 4 KB
prefix of each file.  Two bounds keep that off the interactive path:
`agent--confirm-kill-branches` only needs sessions that could be *children*
of the session being killed, so it scans files whose mtime is newer than the
parent's start; and results are cached per directory keyed by the newest
file's mtime, so a second `agent-switch-branch` in the same session is free.

Three details of the format matter, all confirmed against the user's real
session files:

- A thread's own id is taken from the file name (`rollout-<ts>-<id>.jsonl`),
  not from the payload's `session_id`.  For multi-agent subagent threads the
  payload's `session_id` is the *parent's* id, so trusting it would collapse
  distinct threads onto one key.
- Records whose `thread_source` is `subagent` are skipped entirely.  Codex
  subagents are forks in the file format, but they are not branches the user
  navigates; including them would bury real branches under dozens of
  machine-made siblings.
- A `forked_from_id` equal to the thread's own id means "not a fork" and is
  read as no parent.

`agent-codex--session-prompt` reads forward through a header's file for the
first `response_item` of type `message` with `role` `user` whose text is not
one of the injected preambles (`# AGENTS.md`, `<environment_context>`,
`<user_instructions>`), and returns it as `:first-prompt`.  Sessions with no
such message render as `(no prompt)`, which is what the existing tree
formatter already does for missing prompts.

### Files

New `agent-todo.el` (batch processing, todo-at-point, their customizations)
and `test/agent-todo-test.el`, both added to `SRC` and `TEST_FILES` in the
`Makefile`.  `agent-forge.el` is missing from `SRC` today and so is never
byte-compiled by `make compile`; it is added in the same edit.

`agent-claude.el` loses roughly 400 lines: the tree helpers, the batch
machinery, todo-at-point, the fork/worktree code, the two infixes and the
menu-suffix function.  What remains there is genuinely Claude-specific —
status-file parsing, monet, the CLI-config merge, and the two header slot
implementations.

`README.org` needs the backend slot list updated (it enumerates every slot in
prose), the menu documentation rewritten for the single command list, and the
renamed customizations described; `agent.texi` is regenerated from it with
`ox-texinfo`, never hand-edited.

## A bug this surfaces

`agent-claude-warn-kill-with-branches` is defined as a defcustom and toggled
by the `-w` infix, but no code reads it: `agent-claude--confirm-kill-branches`
prompts whenever the session has branches, whatever the option says.  The
toggle has never done anything.  The generalized `agent--confirm-kill-branches`
consults the option, so the fix arrives with the move rather than as a
separate change.

## Risks

The two-package rename risk is real and was hit in a previous session.
`agent` calling `codex-start-session` with `:fork` against a `codex.el` that
does not accept the keyword is a `cl-defun` error, not a graceful no-op, so
the `codex.el` half lands and reloads first, and the `agent` half second.

Codex fork-by-id in a git worktree is the least certain path: it depends on
the CLI accepting a session id recorded under one `cwd` while running under
another.  Sessions are stored globally, so it should work, but it is on the
live verification list rather than assumed.

Dropping `:menu-suffixes` removes the only extension point a backend had for
the menu.  That is intended, and the replacement is a slot plus a command in
`agent.el`; it is recorded here because it is a deliberate narrowing, not an
oversight.

## Verification

`make test` and `make compile` clean in `agent` (386 tests today, plus the
new `agent-todo` tests) and in `codex` (its own suite).  New unit tests cover:
the branch tree helpers at their new names; Codex header parsing against
fixture rollout files, including the subagent-skip, filename-id and
self-parent cases; the account infix's summary rendering; the general
session-for-directory resolver; and a menu-layout test replacing
`agent-test-menu-backend-children`, asserting the final key map and that no
backend column exists.

Live verification through `emacsclient`, since a passing test suite is not
evidence that the menu works:

1. `(get 'agent-menu 'transient--layout)` shows four columns and the exact
   key map above, with no backend heading.
2. Fork a live Claude session with `N`, then `B` back to the parent.
3. Fork a live Codex session with `N` under both terminal backends, then `B`
   through the resulting tree.
4. `N` with a prefix argument in each backend, confirming the worktree is
   created and the fork runs inside it.
5. `R` from a Claude buffer and from a Codex buffer.
6. `b` and `t` driven from an org buffer against a Codex session.
7. `-c` from inside a Claude session (no backend prompt), from inside a Codex
   session, and from an unrelated buffer (backend prompt), checking the
   summary display and that the account actually changes.
8. Kill a session with branches under both backends with `-w` on and off.

## Landing

A branch with `git config branch.<name>.deferDocUpdates true`, since the work
spans several commits that each touch a non-test `.el`; the config is unset
after merging back to `main`, and `README.org` and `agent.texi` are updated
before the merge.  The `codex.el` commits are pushed and reloaded before the
`agent` commits that depend on them.
