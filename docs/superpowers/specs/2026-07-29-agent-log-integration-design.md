# Agent / Agent Log Integration — Agent Side

## Problem

`agent` owns live sessions and `agent-log` owns the durable archive, but the
two packages do not share session identity.  The `agent-session` struct has an
`id` slot that nothing populates; each backend's native session ID is fetched
on demand from private state (the Claude statusline file, Codex buffer
locals).  Agent Log guesses which transcript belongs to a live buffer through
heuristics, two of which are dead: it reads `claude-code-extras--status-data`,
a variable that stopped existing when that package was renamed to `agent`, and
it looks for statusline files keyed by sanitized buffer name, while `agent`
now keys them by a per-process UUID hash.  Resuming a session from Agent Log
bypasses `agent` entirely, so the resumed process gets no account handling,
lifecycle registration, session key, or teardown, and resuming a session that
is already live silently starts a duplicate process.

## Boundary

- `agent-log` owns the durable archive: catalogs, transcripts, rendering,
  summaries, search, and historical browsing.
- `agent` owns live control: buffers, accounts, lifecycle state, attention,
  teardown, and start/resume/fork/worktree actions.
- An optional bridge (shipped with `agent-log`, active only when both
  packages are loaded) connects them.  Neither package requires the other.

## Design: the live-identity contract

`agent` becomes the single authority on which native session ID a live buffer
is running.

**Populate `agent-session-id`.**  A private core helper,
`agent--note-session-id BUFFER ID`, sets the session struct's `id` slot when
ID is non-nil and differs from the current value, then runs the new public
abnormal hook `agent-session-id-functions` with BUFFER.  Backends feed it:

- *Claude:* `agent-claude--read-status` calls it with the parsed status
  plist's `:session_id` on every poll.  The first successful poll populates
  the ID; a branch switch (which changes the ID) updates it and fires the
  hook again.
- *Codex:* `agent-codex--handle-notification` calls it with
  `(plist-get (codex-session-identity buf) :session-id)` for every handled
  event type, covering SessionStart and later events for both terminal and
  app-server sessions.
- *Seeding:* `agent-start-session` seeds the slot with RESUME-ID when
  resuming, except when the `:fork' option is set, because a forked resume
  acquires a fresh ID that only the backend can report.

**Expose the identity.**  Consumers use only public API:

- `agent-session BUFFER` → struct; `agent-session-id` accessor (existing).
- `agent-session-buffers` (new) → all live session buffers across backends,
  a public wrapper over the private buffer enumeration.
- `agent-session-display-state BUFFER` (existing, public) → one of `busy',
  `waiting', `background-waiting', `unknown'.
- `agent-session-id-functions` (new abnormal hook, run with the buffer after
  its ID is recorded or changes).

Agent Log's backend keys (`claude-code', `codex') already equal `agent`'s
backend symbols, so the contract needs no key mapping.

## Design: shared history command

New command `agent-history` in `agent.el`: soft-`require` `agent-log`, signal
a clear `user-error` ("Package `agent-log' is required for history browsing")
when it is missing, otherwise call `agent-log-menu`.  Bound to "l" in the
shared Sessions column of `agent-menu`.  The Claude-only
`agent-claude-agent-log-menu` command and its "l" binding in the Claude
column are removed as duplicates.

Laziness invariant: neither `agent-menu` nor `agent--session-switcher` may
read any historical catalog while being constructed or opened.  `agent-history`
merely opens Agent Log's own transient; catalog reads (including the
multi-second Codex app-server `thread/list`) happen only when an explicit
Agent Log action needs them.

## Out of scope

Tags, aliases, archive state, export formats, annotations databases; a
transcript renderer inside `agent`; a transient listing historical sessions;
the attention inbox and queued input; changes to `codex.el` or
`claude-code.el`.  `agent` must not infer archive membership from transcript
files.

## Verification

- ERT: ID population and hook firing for both backends (stubbed status data /
  `codex-session-identity`), including ID change on branch switch and no
  refiring on unchanged IDs; RESUME-ID seeding honors `:fork'; `agent-history`
  signals `user-error` when `agent-log' is unavailable;
  `agent-session-buffers` returns live session buffers.
- Full suite (`make test`) and byte compilation (`make compile`) stay clean.
- Live: fresh Claude and Codex sessions acquire their correct native IDs
  (compared against the CLI's own records); opening the current log through
  Agent Log resolves to that same session; opening `agent-menu` and the
  session switcher spawns no Codex app-server catalog process.

The Agent Log side of the bridge is specified in the sibling repository:
`agent-log/docs/superpowers/specs/2026-07-29-agent-integration-design.md`.
