# Attention Inbox and Busy-Input Handling — Design

Revision 2.  Revision 1 was reviewed and its event/completion contract and
queue protocol were found not implementation-ready; this revision reworks
both (canonical completions, evidence-based draining, transactional
preservation, request-identity for approvals, non-reentrant delivery) and
keeps the approved architecture: capability-gated queue/steer/interrupt,
backend-owned approval policy, a separate inbox module, and no invented
backend detail.

## Problem

`agent.el` reduces every backend signal to one of four lifecycle states, so
"waiting for permission", "asking a question", "turn finished while you were
elsewhere", and "turn died on a rate limit" are indistinguishable once the
moment passes, and there is no durable in-Emacs place to see which sessions
need attention or why.  Input typed while a session is busy is equally
undifferentiated: queueing a follow-up turn, steering the current turn, and
interrupting are three different operations with different backend support,
and the UI must not conflate them or silently substitute one for another.

## Verified backend capabilities

Everything below was verified against the installed packages (codex.el at
`benthamite/codex`, claude-code.el 0.4.5 at `stevemolitor/claude-code.el`,
monet 0.0.3) and the Claude Code 2.1.220 binary.  The design exposes only
these capabilities.

| Capability | Claude Code | Codex terminal (eat/vterm) | Codex app-server |
|---|---|---|---|
| Turn end signal | `Stop` hook event | `Stop` hook event | `turn/completed` JSON-RPC + `Stop` hook event (two channels, one turn) |
| Turn start signal | none (statusline `prompt_id` poll) | none | `turn/started` JSON-RPC, with turn id |
| Steer (same turn) | **none** — mid-turn input is queued by the TUI (`inputSource:"queued"`), never injected | TUI Enter = "inject mid-turn" per codex.el (`codex-inject-mid-turn`); protocol-unverified | `turn/steer` with `expectedTurnId`; this is what mid-turn submission already does |
| Interrupt | `claude-code-send-escape` (public) | `codex-send-escape` (public) | `codex-send-escape` → `turn/interrupt` (authoritative) |
| Permission request detail | `Notification`/`permission_prompt`: constant message, ~6 s delay.  `PermissionRequest` hook (not yet configured): `tool_name`, `tool_input` | `PermissionRequest` hook event, opaque JSON | structured server requests with JSON-RPC ids (command, file-change, permission-grant, elicitation, user-input) — currently answered by a modal minibuffer inside codex.el, invisible to outer packages |
| Programmatic respond | none that is safe (TUI keystrokes only; monet has no permission API — its `openDiff` accept/reject already handles Edit/Write approvals when active) | none | possible via codex.el's response encoding, once codex.el exposes it |
| Turn errors | `StopFailure` hook (not yet configured): error enum | none | `error` notifications, `thread/status/changed` → `systemError` |
| Native queue | none | TUI Tab (`codex-queue-followup`) | full queue, flushed one item per `turn/completed` **before** any outer observer runs |

Two approved upstream moves extend this surface:

1. **codex.el** (this user's package) gains small public extension points
   (specified in §6).
2. **Claude settings hooks**: `agent-claude-setup-config` additionally
   installs `PermissionRequest` and `StopFailure` hook entries (observers,
   fire-and-forget; never a decision channel).  claude-code.el itself is not
   modified.

## Design constraints carried into everything below

- Never implement steer by interrupting and resubmitting; never downgrade
  one operation into another silently.
- The backend remains the authority for approval policy and execution; no
  LLM-based approval, no bypass of a native permission mechanism.
- Do not invent details a backend did not report; keep "definitively false"
  distinct from "not known".
- Claude inbox items never get remote approve/deny actions: the only channel
  would be blind keystrokes into a dialog whose option order Emacs cannot
  see.  Their action is "jump to the session".
- All per-session resources (timers, hooks, watchers) register through
  `agent--teardown-functions`.

## 1. Structured session events (core, `agent.el`)

### Event payloads and the public hook

`agent-session-event` grows an optional third argument:

```elisp
(agent-session-event BUFFER EVENT &optional PAYLOAD)
```

PAYLOAD is a plist of backend-reported facts (e.g. `:kind permission`,
`:tool "Bash"`, `:message "..."`, `:error "rate_limit"`, `:request-id 42`,
`:turn-id "..."`, `:source claude-hook`).  Core copies it verbatim; it never
synthesizes backend facts.  After the existing state handling (whose
ownership is unchanged), core runs a new public abnormal hook:

```elisp
agent-session-event-functions  ; called with (BUFFER EVENT-PLIST)
```

EVENT-PLIST is `(:type EVENT :time FLOAT-TIME :source SOURCE :redundant
BOOL :payload PAYLOAD)`; `:source` is taken from PAYLOAD's `:source` (nil
when the producer named none).  The hook runs for every delivered event —
including a `submit` the busy-state guard ignored and a redundant
completion — so consumers see the raw stream and filter by flags.
Existing two-argument callers keep working.

One new event type joins the vocabulary: `error` — the backend reported
that a turn ended abnormally.  It transitions to `awaiting-input` like
`blocked` (the CLI is back at its prompt) and never fires the ready alert.
`blocked` events now carry `:kind` (`permission` or `question`) plus
whatever detail the backend gave.

### Canonical completions: one per turn

`stop` and `idle-prompt` are *completion events*, and one finished turn can
produce several (Claude: `Stop` hook then a later `idle_prompt`
notification; Codex app-server: `turn/completed` then the CLI `Stop` hook).
Consumers that must act at most once per turn — the before-exit chain,
queue draining, attention completion items — need one canonical completion.
Deduplication happens at two levels:

1. **Adapter level, where the duplicate pair is known.**  For app-server
   buffers with the new codex.el hooks available, `turn/completed` emits
   the canonical completion (as `idle-prompt`, carrying `:turn-id`, so the
   ready alert moves to the authoritative, earlier channel), and the CLI
   `Stop` hook event is not translated at all for those buffers.  Without
   the new hooks, behavior is unchanged.
2. **Core level, generically.**  Core tracks per buffer whether anything —
   `submit`, `activity`, `blocked`, or `error` — has been observed since
   the last delivered completion.  A completion arriving with nothing
   observed in between is delivered with `:redundant t`.  Redundant
   completions do not advance the before-exit chain and are ignored by
   at-most-once consumers; ready alerts, scrolling, and display-name
   refresh keep their current behavior, because the Claude `idle_prompt`
   channel is by design the alert carrier and may legitimately repeat.

This closes the existing hazard where a delayed second completion could
advance the before-exit chain twice (a regression test delivers the
`turn/completed` + CLI `Stop` pair and asserts single advancement), while
keeping every raw event observable on the hook.

### Delivery is non-reentrant

Consumers of `agent-session-event-functions` must not synchronously send
session input (which would nest a `submit` event inside the outer
delivery and make correctness depend on hook order).  Core documents this
contract on the hook; `agent-queue` obeys it by deferring its drain to a
zero-delay timer (§3).  A test registers the queue and attention consumers
in both orders and asserts identical outcomes.

### New backend slots and annotations

New optional `agent-backend` slots:

- `:interrupt` — function of BUFFER; authoritative native interrupt.
- `:steer` — function of TEXT and BUFFER; native same-turn steering.
- `:steer-p` — function of BUFFER; non-nil when steering is available for
  this buffer *right now* (transport supports it and a turn is active).

Core also gains `agent-session-annotation-functions` (BUFFER → string or
nil).  `agent--session-suffix-spec` concatenates **all** non-nil results,
space-separated, after the session label, so the attention marker and the
queue count never compete for a single result.

## 2. Attention records and inbox (`agent-attention.el`, new module)

A global minor mode `agent-attention-mode` owns every hook the module
installs (event subscription, `window-selection-change-functions`, the
Codex app-server request routing).  Loading the file installs nothing;
inbox commands invoked while the mode is off say so instead of showing
stale data.

### Record

`agent-attention-item` struct: `id`, `buffer` (may be dead), `session-label`
(display name + backend label + account, snapshotted so items survive buffer
death), `kind` (`permission`, `question`, `completion`, `error`,
`queue-failure`, `info`), `title`, `detail` (backend-reported text only),
`created-at`, `state` (`pending` or `seen`), `request-key` (backend request
identity when supplied, e.g. the app-server JSON-RPC id; nil otherwise),
`fidelity` (`rich` or `coarse`, per producer), `actions` (alist of
`(KEY LABEL . CLOSURE)` respond actions, nil when the backend exposes no
safe respond path).

### Identity, merging, and replacement

- Items carrying a `request-key` are keyed by `(BUFFER . REQUEST-KEY)`.
  Distinct outstanding requests each keep their own item; codex.el
  establishes no single-outstanding-request invariant, so neither does the
  inbox.
- Producers without request identity (Claude notification/hook events,
  Codex terminal `PermissionRequest`) map to at most one pending
  permission item and one pending question item per buffer.  A new report
  **merges** into the existing item: timestamps refresh, and detail is kept
  from the highest-fidelity producer — so the coarse, ~6 s-delayed Claude
  `Notification` arriving after the rich `PermissionRequest` hook event
  refreshes the item without overwriting the tool name.

### Producers (via `agent-session-event-functions`)

- `blocked` with `:kind permission` → permission item (identity rules
  above).
- `blocked` with `:kind question` → question item, same rules.
- Non-redundant `stop`/`idle-prompt` → completion item, created **only
  when the buffer is not being read right now** — that is, unless some
  window of a focused frame is both selected and showing the buffer.  A
  buffer merely visible in an unselected split or an unfocused frame still
  gets an item.  A buffer has at most one completion item; a later
  completion for the same buffer refreshes it.
- `error` → error item with the reported code/message.
- `submit` / `activity` → clears pending completion items (the session
  demonstrably moved on) and pending *coarse* permission/question items;
  request-keyed items clear only through their own lifecycle (below).
- Queue submission failure (from `agent-queue`) → queue-failure item.
- Session teardown with queued prompts → info item naming where the
  prompts were preserved (§3).

### Clearing and action invalidation

Completion items are marked seen when the user selects a window showing
the session buffer in a focused frame (via
`window-selection-change-functions`), or marks them in the inbox.
Request-keyed items clear when their response is sent, and are
*invalidated* — response closures disabled, item marked seen with an
explanatory note — when the request can no longer be answered: the turn
completes or is abandoned, the app-server process dies, or the session is
torn down.  Response closures are one-shot; a second invocation no-ops
with a message (codex.el's RESPOND enforces the same, §6).  Items whose
buffer dies stay listed with their snapshot label until cleared.  Nothing
is cleared by elapsed time.

### Inbox UI

`agent-attention` opens `*agent-attention*`, a `tabulated-list-mode`
derivative — the standard Emacs convention for actionable lists; this
package's transients are menus, not inboxes, so a dedicated buffer is
right.  Columns: session, backend, account, current display state
(`agent-session-display-state`, so `unknown` renders as unknown), kind,
detail, age.  Keys:

- `RET` — switch to the live session (or message that it is gone).
- `r` — respond: presents the item's `actions` (only present when a backend
  adapter exposed a safe public action for that exact request; invalidated
  actions explain themselves instead of firing).
- `m` — mark seen; `d` — delete item; `C` — clear all seen; `g` — refresh;
  `q` — quit window.

Sorted pending-action items first (permission, question, error,
queue-failure), then unread completions, then seen items; recency within
groups.

### Switcher and menu integration

Through `agent-session-annotation-functions`, `agent-attention-mode`
contributes a compact marker: `!` when the session has a pending action
item, `•` when it only has an unread completion.  Unknown state handling
is untouched.  `agent-menu` gets an "attention" entry in the Sessions
column; its description includes the pending count (computed from the
in-memory list — no I/O at menu construction).

## 3. Follow-up queue (`agent-queue.el`, new module)

### Model and activation

Queue items live in a buffer-local list in the session buffer; each item is
`(:id UUID :text STRING :created-at TIME)`.  The queue is owned entirely by
`agent.el` and coexists with Codex's native Tab-queue, which stays fully
functional and always drains first (the readiness probe below defers to
it).

A global minor mode `agent-queue-mode` owns the module's event
subscription and timers, symmetric with the other modes.  Queue commands
invoked while the mode is off signal a `user-error` naming the mode, so a
prompt is never accepted into a queue that nothing will drain.

### Commands

- `agent-queue-prompt` — add a prompt to a session's queue (from the session
  buffer or with completion over sessions).  While the session is *not*
  busy it offers to submit immediately instead.
- `agent-queue-list` — per-session queue buffer: `e` edit item text in a
  dedicated edit buffer (`C-c C-c` saves), `d` delete, `M-<up>`/`M-<down>`
  reorder, `a` add, `RET` show full text, `q` quit.
- The inbox and switcher annotations show queued counts.

### Draining: evidence model and per-transport guarantees

Each queued item moves through explicit evidence states:

- **queued** — in the list, editable.
- **dispatched** — the drain owner called `agent-submit` for it; timestamp
  recorded.  The synchronous `submit` event is *not* treated as proof a
  turn started (core documents that submissions may duplicate or start no
  turn); it only stamps the debounce clock.
- **started** — backend evidence the dispatched text became a turn:
  app-server `turn/started` (its turn id is recorded on the item);
  elsewhere an `activity` observation, when one happens to arrive.
- **completed** — backend evidence that turn ended: app-server
  `turn/completed` whose turn id matches the recorded one; on transports
  without ids, the first non-redundant completion arriving later than
  `agent-queue-debounce` (default 2 s) after dispatch.

A single drain owner — the only submitter — runs from a **zero-delay
timer** scheduled by the event consumer on non-redundant
`stop`/`idle-prompt` (never on `blocked` or `error`: a blocked or failed
session must not receive automatic input), so no session input is ever
sent from inside event delivery (§1).  The gate, re-checked at fire time:

1. queue non-empty and no unresolved dispatched item;
2. `agent--session-state` is `awaiting-input`;
3. the backend's readiness probe passes.  For Codex app-server buffers
   this uses the public turn-state API (§6): no active turn, no pending
   `turn/start`, and an **empty native queue** — codex.el flushes its own
   queue inside `turn/completed` before any observer runs, so this
   condition is what prevents Agent from dispatching into (or
   mis-attributing) a native flush.  For other transports it is the
   registered `:busy-p` returning nil;
4. on transports without turn ids, at least `agent-queue-debounce` has
   passed since the previous dispatch (a duplicate-hook guard, not a state
   guess).

Between the gate check and the `agent-submit` call the drain function
yields to no process output (single-threaded, synchronous), so the gate
cannot be invalidated mid-dispatch.

The resulting guarantees, stated honestly and documented in the manual:

- **Codex app-server: exactly-once.**  Dispatch happens only into an idle
  thread with an empty native queue, `turn/started` correlation attributes
  the turn, and the matching `turn/completed` resolves the item and
  permits the next drain.  (Attribution can be off only if a human
  submits into the same idle gap by hand; the item is still dispatched
  exactly once.)
- **Claude and Codex terminal: at-most-once dispatch, best-effort
  exactly-once turn placement.**  No correlation ids exist.  An item is
  never dispatched twice; a duplicate completion delayed beyond the
  debounce could at worst cause the *next* item to be dispatched while the
  previous queued turn still runs, in which case the CLI's own mid-turn
  handling applies (Claude queues it as the next prompt).  This residual
  case requires a duplicated hook configuration plus multi-second delivery
  skew, and the limitation is documented rather than papered over.

If a dispatched item produces no observable turn (state stays
`awaiting-input`, probes idle) for `agent-queue-stall-seconds` (default
30), the queue **pauses**: a queue-failure attention item explains that
the submission produced no observable turn, and nothing is auto-redispatched
— never silently, never twice.  A safety-net repeating timer (10 s, running
only while the queue is non-empty, registered for teardown) re-evaluates
the gate so a missed or coalesced backend event delays a drain rather than
stranding it; it re-reads the same gate and invents no state.

If `agent-submit` itself signals, the item returns to the head of the
queue and a queue-failure attention item is filed; nothing is dropped.

### Preservation: restart, handoff, exit, kill, process death

Preservation has one owner, `agent-queue--preserve`, which operates on a
**global orphan stash** outside any session buffer, so no failure path can
lose items with the dying buffer:

1. Items move from the buffer-local queue into a stash entry carrying a
   snapshot of the session identity (`agent-session` struct copy + display
   name), the reason, and — for restart — the expected native session id.
2. The stash entry is immediately written to the session's `agent-capture`
   Org file through a new noninteractive, durability-confirming API
   (below).  Success records the written entry handles on the stash entry
   and files an info attention item naming the file; failure keeps the
   items in the in-memory stash, files an error attention item, and emits
   a `display-warning` — degraded but never silent, never lost while Emacs
   lives.
3. **Restart only:** `agent-restart` detaches the queue to the stash
   *before* killing the buffer (teardown then finds an empty queue and
   does nothing).  After `agent-start-session` returns, if the new
   buffer's seeded session id equals the expected id (non-fork resume —
   the only case where identity is proven), the items re-attach to the new
   buffer and their capture entries are deleted (the existing
   `agent-capture--delete-prompt` machinery).  If startup signals, or the
   id does not match, the stash entry simply remains: durable in the
   capture file, visible in the inbox, never sent anywhere.

A captured draft and an armed queue item stay deliberately different
things; demotion to draft is the only automatic conversion, never the
reverse.  Handoff never migrates (new native session).  `agent-exit`,
`agent-restart`, and `agent-handoff` extend their existing pending-prompt
confirmation to also mention queued prompts.

**New agent-capture API:** `agent-capture-store-prompt (SESSION LABEL
TEXT)` — noninteractive; SESSION is an `agent-session` struct (so it works
for dead buffers), LABEL the display name for the file header.  Appends an
entry, saves the file synchronously, returns the entry handle on confirmed
write, signals on failure.  Fault-injection tests cover: capture write
failure during teardown (items stay stashed + warning), and restart
startup failure after detach (items stay stashed and durable).

## 4. Capability commands

- `agent-queue-prompt` — both backends, shared core (above).
- `agent-interrupt` — dispatches `:interrupt`: `claude-code-send-escape`
  for Claude, `codex-send-escape` for Codex (which is `turn/interrupt` on
  app-server).  It stops the current turn and does nothing else; it never
  submits replacement text.  On Claude, ESC while a permission dialog is
  showing answers that dialog (TUI semantics); the docstring says so.
- `agent-steer` — reads text and dispatches `:steer` only when `:steer-p`
  approves.  Codex app-server: submit through the existing public path
  while the turn is active, which is `turn/steer` with `expectedTurnId`;
  on steer failure codex.el already re-queues at the front.  Codex
  terminal: exposed via `codex-inject-mid-turn` **only if live
  verification confirms same-turn injection**; otherwise `:steer-p` returns
  nil for terminal buffers and the command explains why.  Claude registers
  neither slot; `agent-steer` on a Claude session signals a clear error
  ("Claude Code has no steering operation; queued input becomes the next
  turn"), and nothing is downgraded silently.

## 5. Claude backend integration (`agent-claude.el`)

- `agent-claude--handle-notification` passes payloads: `permission_prompt`
  → `blocked` with `(:kind permission :message MSG :fidelity coarse)`,
  `elicitation_dialog` → `blocked` with `(:kind question :message MSG
  :fidelity coarse)`.
- New hook-event handlers on `claude-code-event-hook` (observers returning
  nil, so they never win the first-non-nil-response race or emit a
  decision): `permission-request` → `blocked` with `:kind permission`,
  `:tool tool_name`, a short rendering of `tool_input`, `:fidelity rich`;
  `stop-failure` → `error` with the reported `error` code and
  `last_assistant_message`.
- `agent-claude-setup-config` additionally ensures `PermissionRequest` and
  `StopFailure` entries in `settings.json`, both run through the bundled
  `fire-and-forget.sh` so they can never block the CLI or return output.
  Setup remains explicit; nothing installs at load or mode-enable time.
- `:interrupt` = `claude-code-send-escape` with the target buffer current.
  No `:steer`/`:steer-p`.

## 6. Codex backend integration (`agent-codex.el` + upstream codex.el)

### Upstream codex.el additions (implemented in that repo, its conventions)

1. `codex-app-server-notification-functions` — abnormal hook run with
   `(BUFFER METHOD PARAMS)` after codex.el's own handling of every
   app-server notification (so turn state and the native queue flush are
   already settled when observers read them).  Read-only; return values
   ignored.
2. `codex-app-server-request-handler` — defcustom function called with
   `(BUFFER METHOD PARAMS RESPOND)` for server requests codex.el knows how
   to answer.  RESPOND sends the JSON-RPC response for that request id;
   it is one-shot and no-ops with a message on reuse.  Default
   `codex-app-server-modal-request-handler` preserves today's behavior
   byte-for-byte.  A public `codex-app-server-request-choices (METHOD
   PARAMS)` exposes the existing CLI-worded choice tables as
   `(KEY LABEL HELP RESULT)` entries so outer packages reuse codex.el's
   response encoding instead of duplicating protocol knowledge; it returns
   nil for requests that need free-form input (`item/tool/requestUserInput`,
   schema-bearing elicitations), and any handler must fall back to the
   modal handler for those.
3. `codex-app-server-turn-state (&optional buffer)` — public read-only
   probe returning `(:active BOOL :start-pending BOOL :queued COUNT
   :turn-id STRING-or-nil)`, nil for non-app-server buffers.  This is what
   makes Agent's readiness gate honest about `turn/start`-pending and the
   native queue, which the current `agent-codex--waiting-p` cannot see.

### agent-codex

- `:interrupt` = `codex-send-escape` with the target buffer current.
- `:steer-p` / `:steer`: app-server buffers with an active turn per
  `codex-app-server-turn-state` (plus terminal buffers only if
  verification confirms); `:steer` submits through the existing public
  submit path.
- `agent-codex--waiting-p` upgrades to the turn-state probe when available
  (idle means neither active nor start-pending); with an older codex.el it
  keeps reading `codex--app-server-turn-active-p` as today, and the
  narrower visibility is a documented limitation.
- Terminal `PermissionRequest` hook events → `blocked` with
  `(:kind permission :fidelity coarse)` plus defensively-parsed fields
  from the opaque JSON (shown only when present).
- With the upstream hooks available (guarded by `fboundp`, so agent-codex
  keeps working against an older codex.el):
  - `turn/started` → `activity` with `:turn-id`; `turn/completed` →
    canonical completion (`idle-prompt` with `:turn-id`; ready alert moves
    to this channel) and the CLI `Stop` hook event is not translated for
    app-server buffers; `thread/status/changed` `systemError` → `error`.
  - `agent-attention-mode` installs an app-server request handler that
    creates a permission/question attention item keyed by the request id,
    carrying respond actions built from
    `codex-app-server-request-choices`, fires the same approval alert as
    today, and clears or invalidates the item per §2.  Requests with no
    choice table delegate to the modal handler unchanged.  Enabling the
    mode saves the previously installed handler and disabling restores
    **that saved value**, not the modal default (the
    `agent-codex--saved-notification-function` pattern).

## 7. Manual

README.org (and the texi export) gains an "Attention and busy sessions"
section documenting: the three operations and which backend/transport
supports each (including that Claude cannot steer and why); how attention
items are created, merged, cleared, and invalidated; that unknown state
stays unknown; the queue lifecycle including the evidence model, the
per-transport delivery guarantees stated above, what happens on restart
(migration only on proven same-session resume), the demotion of queued
prompts to capture drafts on any other teardown, and the pause-plus-inbox
behavior on failures; and the new setup-config hook entries.

## 8. Out of scope

Historical browsing/transcripts/`agent-log` changes; a transcript renderer;
a task board or scheduler; a context-reference composer; automatic approval
decisions or backend security-policy changes; reimplementing backend
protocols in the core; remote keystroke answering of Claude dialogs;
`item/tool/requestUserInput` form rendering in the inbox; changes to
claude-code.el.

## 9. Verification

ERT (deterministic, stubbed backends):

- Structured event payloads and hook delivery, including legacy two-arg
  calls and redundant-completion flagging.
- Regression: deliver the app-server `turn/completed` + CLI `Stop` pair
  and assert the before-exit chain advances once and the queue drains
  once.
- Consumer-order independence: register the queue and attention consumers
  in both orders; identical outcomes.
- Attention lifecycle: creation, request-key identity (two outstanding
  requests coexist), coarse-after-rich merge keeps the tool name,
  seen-on-selected-focused-visit, visible-but-unselected still creates an
  item, clear-on-activity for coarse items, invalidation of response
  closures on turn end/process death/teardown, one-shot respond.
- Capability dispatch: steer refused for Claude and for idle/terminal
  Codex; interrupt routing.
- Queue: add/edit/delete/reorder; drain blocked while turn-state reports
  active, start-pending, or a non-empty native queue; duplicate stop
  events, short turns, and poll interference cause no double dispatch;
  debounce behavior; stall pauses the queue with an attention item;
  submission failure keeps the item and files an attention item.
- Preservation: teardown demotes to capture drafts through the durable
  API; capture write failure keeps items stashed and warns (fault
  injection); restart migrates only on matching id; restart startup
  failure after detach keeps items stashed and durable (fault injection).

`make test` and `make compile` clean in both `agent` and `codex` repos.

Live, both backends where applicable: queue a follow-up during a real turn
and verify it does not alter the current turn, submits exactly once after
completion, and is inspectable until then; edit/delete/reorder queued
prompts; verify Codex app-server steering is same-turn (and decide the
terminal-steer question empirically); verify unsupported backends refuse to
steer; produce real permission and elicitation requests and verify inbox
reason, respond actions (Codex app-server), and clearing; leave a session
in the background through a completed turn and verify unread/seen behavior
including a visible-but-unselected window; exercise restart and buffer kill
with a non-empty queue and verify no prompt reaches a different session.
