# Session Summaries in the Session Switcher

## Problem

`agent-start-or-switch` shows a transient menu of live sessions: a home-row
key, a backend icon, and a display name derived from the project directory
("Epoch", "claude-tag", "staff-data", "agent").  The name says where a session
is running, never what it is doing.  With five or more sessions open across
two accounts, the menu cannot answer the question the user actually asks it —
"which of these is the one I want?" — without switching into each buffer and
reading.

Agent Log already stores exactly the missing text.  Its rendered index keeps a
`:summary-oneline` for nearly every session it has seen (6581 of 6584 entries
at the time of writing), keyed by native session ID, and `agent` now records
that ID in `agent-session-id` for live buffers.  The two halves have never
been joined.

## Boundary

The existing split holds and this feature must not erode it:

- `agent` owns live control and the switcher UI.  It does not require
  `agent-log` and does not know that summaries exist.
- `agent-log` owns the durable archive, including summaries.
- The optional bridge `agent-log-agent.el`, shipped with `agent-log` and
  loaded only when both packages are present, connects them.

This mirrors `agent-log-live-session-info-function`, which `agent-log` defines
and the bridge fills in from `agent`.  The new hook points the other way:
`agent` defines it, the bridge fills it in from `agent-log`.

## Design

### The annotation contract (`agent`)

`agent-session-annotation-function` — a defvar, nil by default — is called
with a live session buffer and returns a short single-line string, or nil.
`agent` renders whatever it receives.  The name is deliberately generic: the
switcher has no concept of a summary, only of an annotation.  Setting the
variable back to nil disables the feature with no other configuration.

Two further additions on the `agent` side:

- Face `agent-session-summary`, inheriting `shadow`.
- Defcustom `agent-session-annotation-max-width`: an integer column cap, or
  nil meaning "fit the available width of the switcher window".

### Rendering (`agent`)

Building the switcher becomes two passes, because alignment needs a width
that is only known after every label exists:

1. Collect the live buffers from `agent--session-keys`, and compute each
   one's base label — icon plus display name — through a new
   `agent--session-label-base` helper extracted from the current spec
   builder.
2. Take the widest base label as the pad width, then build the suffix specs.

`agent--session-suffix-spec` gains a pad-width argument.  When a buffer has an
annotation, its label becomes the base label padded to that width, followed by
the annotation propertized with `agent-session-summary` and truncated with an
ellipsis.  When it has none, the label is exactly what it is today.  Padding
is computed across all account groups, so summaries start at one column for
the whole menu, not one column per group.

State faces continue to work.  Transient applies a suffix's `:face` with
`add-face-text-property` in append mode (transient.el:5041), so a face already
carried by the string wins for the attributes it sets.  A waiting session
keeps `agent-waiting` on its name while the summary stays dim.

### The one-liner lookup (`agent-log`)

- `agent-log-session-oneline SESSION-ID` (public) returns the stored one-liner
  for SESSION-ID, or nil.  It reads an in-memory map, never the disk.  The
  `"(no conversation)"` sentinel maps to nil, so empty sessions render blank
  rather than announcing their emptiness.
- `agent-log-refresh-session-onelines` (public) re-reads `_index.el` and
  rebuilds that map.  The map holds one-liners only, not whole index entries:
  a few hundred kilobytes rather than the 6 MB index.

### Wiring (`agent-log-agent.el`)

The bridge sets `agent-session-annotation-function` to a function that maps
buffer → `agent-session-id` → `agent-log-session-oneline`, and starts a
repeating idle timer that calls `agent-log-refresh-session-onelines` when the
index file's mtime or size has changed since the last refresh.  Nothing in the
switcher path touches the filesystem.  The timer also primes the map: the
bridge does no work at load time, and the first idle moment after Emacs starts
fills the cache, which is long before a session exists to switch to.

## Decisions and their costs

**Stored summaries only; no summarization on demand.**  Opening the switcher
performs no LLM call and costs nothing.  The consequence is staleness.  Agent
Log's summary sweep deliberately skips sessions it believes are live, and live
sessions get summarized only because the background sweep worker runs in a
separate Emacs that has never loaded `agent` and so cannot tell.  Measured on
four live sessions, stored summaries were between 10 minutes and 3 hours
behind the transcript.  This is adequate for "which session was this?" and
wrong for "what is it doing right now."

**Nothing shown when there is no summary.**  A session started minutes ago,
or one whose native ID `agent` has not yet learned, renders exactly as it does
today.  An empty slot therefore means "not summarized yet", with no fallback
text standing in for a summary it does not have.

**Idle-refreshed cache rather than read-on-demand.**  Reading and parsing
`_index.el` costs about 90 ms, and auto-sync rewrites the file often enough
that a read-on-demand cache keyed by mtime would miss on most invocations.
Refreshing on idle keeps the menu instantaneous; the cost is that a summary
written seconds ago may not appear until the next idle moment.

## Risks

The frame-fitting branch of `agent-session-annotation-max-width` needs the
width available to the Sessions column, which depends on how transient lays
the Actions column out beside it.  This will be measured in a live Emacs.  If
it cannot be measured robustly, the frame-fitting path is dropped and the
defcustom takes a fixed default.

## Testing

Unit tests on the `agent` side: no annotation when
`agent-session-annotation-function` is nil; padding aligns across account
groups; truncation applies the cap and the ellipsis; a nil annotation leaves
the label byte-identical to today's.

Unit tests on the `agent-log` side: the sentinel maps to nil; the map is
rebuilt when the index file's mtime or size changes and reused when it does
not.

Live verification in a real Emacs against the user's own sessions, because the
column-width question cannot be settled by a test.
