# Attention Inbox and Busy-Input Handling — Design

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
| Turn end signal | `Stop` hook event | `Stop` hook event | `turn/completed` JSON-RPC + `Stop` hook event |
| Turn start signal | none (statusline `prompt_id` poll) | none | `turn/started` JSON-RPC |
| Steer (same turn) | **none** — mid-turn input is queued by the TUI (`inputSource:"queued"`), never injected | TUI Enter = "inject mid-turn" per codex.el (`codex-inject-mid-turn`); protocol-unverified | `turn/steer` with `expectedTurnId`; this is what mid-turn submission already does |
| Interrupt | `claude-code-send-escape` (public) | `codex-send-escape` (public) | `codex-send-escape` → `turn/interrupt` (authoritative) |
| Permission request detail | `Notification`/`permission_prompt`: constant message, ~6 s delay.  `PermissionRequest` hook (not yet configured): `tool_name`, `tool_input` | `PermissionRequest` hook event, opaque JSON | structured server requests (command, file-change, permission-grant, elicitation, user-input) — currently answered by a modal minibuffer inside codex.el, invisible to outer packages |
| Programmatic respond | none that is safe (TUI keystrokes only; monet has no permission API — its `openDiff` accept/reject already handles Edit/Write approvals when active) | none | possible via codex.el's response encoding, once codex.el exposes it |
| Turn errors | `StopFailure` hook (not yet configured): error enum | none | `error` notifications, `thread/status/changed` → `systemError` |
| Native queue | none | TUI Tab (`codex-queue-followup`) | full queue, flushed one item per `turn/completed` |

Two approved upstream moves extend this surface:

1. **codex.el** (this user's package) gains small public extension points:
   an observation hook for app-server notifications and a pluggable
   app-server request handler whose default preserves today's modal prompt.
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

`agent-session-event` grows an optional third argument:

```elisp
(agent-session-event BUFFER EVENT &optional PAYLOAD)
```

PAYLOAD is a plist of backend-reported facts (e.g. `:kind permission`,
`:tool "Bash"`, `:message "..."`, `:error "rate_limit"`, `:source
claude-hook`).  Core copies it verbatim; it never synthesizes fields.  After
the existing state handling (whose ownership is unchanged), core runs a new
public abnormal hook:

```elisp
agent-session-event-functions  ; called with (BUFFER EVENT-PLIST)
```

where EVENT-PLIST is `(:type EVENT :time FLOAT-TIME :source SOURCE :payload
PAYLOAD)`; `:source` is taken from PAYLOAD's `:source` (nil when the
producer named none).  The hook runs for every delivered event, including a
`submit` that the busy-state guard ignored, so consumers see the raw stream.
Existing two-argument callers keep working.

One new event type is added to the vocabulary: `error` — the backend
reported that a turn ended abnormally.  It transitions to `awaiting-input`
like `blocked` (the CLI is back at its prompt) and never fires the ready
alert.  All other events keep their semantics; `blocked` events now carry
`:kind` (`permission` or `question`) and whatever detail the backend gave.

New optional backend slots on `agent-backend`:

- `:interrupt` — function of BUFFER; authoritative native interrupt.
- `:steer` — function of TEXT and BUFFER; native same-turn steering.
- `:steer-p` — function of BUFFER; non-nil when steering is available for
  this buffer *right now* (transport supports it and a turn is active).

## 2. Attention records and inbox (`agent-attention.el`, new module)

A global minor mode `agent-attention-mode` owns every hook the module
installs (event subscription, `window-selection-change-functions`, the
Codex app-server request routing).  Loading the file installs nothing.

### Record

`agent-attention-item` struct: `id`, `buffer` (may be dead), `session-label`
(display name + backend label + account, snapshotted so items survive buffer
death), `kind` (`permission`, `question`, `completion`, `error`,
`queue-failure`, `info`), `title`, `detail` (backend-reported text only),
`created-at`, `state` (`pending` or `seen`), `actions` (alist of
`(KEY LABEL . CLOSURE)` respond actions, nil when the backend exposes no
safe respond path).

### Producers (via `agent-session-event-functions`)

- `blocked` with `:kind permission` → permission item; replaces any pending
  permission item for the same buffer (the newer request supersedes).
- `blocked` with `:kind question` → question item, same replacement rule.
- `stop` / `idle-prompt` → completion item, created **only when no window
  shows the buffer**; it represents "turn completed that you have not yet
  seen".  A buffer has at most one completion item: the `idle-prompt` that
  follows a `stop` for the same completion refreshes it rather than adding
  a second.
- `error` → error item with the reported code/message.
- `submit` / `activity` → clears pending permission, question, and
  completion items for that buffer (the session demonstrably moved on).
- Queue submission failure (from `agent-queue`) → queue-failure item.
- Session teardown with queued prompts → info item naming the capture file
  the prompts were preserved in.

### Clearing

Completion items are marked seen when the user selects a window showing the
session buffer (via `window-selection-change-functions`) or marks them in
the inbox.  Permission/question items clear when answered (observable
precisely for Codex app-server; inferred from the next `activity`, `submit`,
or `stop` elsewhere), or manually.  Items whose buffer dies stay listed with
their snapshot label until cleared.  Nothing is cleared by elapsed time.

### Inbox UI

`agent-attention` opens `*agent-attention*`, a `tabulated-list-mode`
derivative — the standard Emacs convention for actionable lists; this
package's transients are menus, not inboxes, so a dedicated buffer is
right.  Columns: session, backend, account, current display state
(`agent-session-display-state`, so `unknown` renders as unknown), kind,
detail, age.  Keys:

- `RET` — switch to the live session (or message that it is gone).
- `r` — respond: presents the item's `actions` (only present when a backend
  adapter exposed a safe public action for that exact request).
- `m` — mark seen; `d` — delete item; `C` — clear all seen; `g` — refresh;
  `q` — quit window.

Sorted pending-action items first (permission, question, error,
queue-failure), then unread completions, then seen items; recency within
groups.

### Switcher and menu integration

Core gains a tiny hook, `agent-session-annotation-functions` (BUFFER →
string or nil), consulted by `agent--session-suffix-spec`;
`agent-attention-mode` contributes a compact marker: `!` when the session
has a pending action item, `•` when it only has an unread completion.
Unknown state handling is untouched.  `agent-menu` gets an "attention"
entry in the Sessions column; its description includes the pending count
(computed from the in-memory list — no I/O at menu construction).

## 3. Follow-up queue (`agent-queue.el`, new module)

### Model

Queue items live in a buffer-local list in the session buffer; each item is
`(:id UUID :text STRING :created-at TIME)`.  The queue is owned entirely by
`agent.el`; it coexists with Codex's native Tab-queue (which stays fully
functional and is drained first by codex.el itself — the gate below makes
the two compatible).

### Commands

- `agent-queue-prompt` — add a prompt to a session's queue (from the session
  buffer or with completion over sessions).  While the session is *not*
  busy it offers to submit immediately instead.
- `agent-queue-list` — per-session queue buffer: `e` edit item text in a
  dedicated edit buffer (`C-c C-c` saves), `d` delete, `M-<up>`/`M-<down>`
  reorder, `a` add, `RET` show full text, `q` quit.
- The inbox and switcher annotations show queued counts.

### Draining — exactly once, one item per completion

A single drain function, the only submitter, runs from
`agent-session-event-functions` on `stop`/`idle-prompt` (never on `blocked`
or `error`: a blocked or failed session must not receive automatic input).
Gate, all conditions required:

1. queue non-empty and no unresolved in-flight item;
2. `agent--session-state` is `awaiting-input`;
3. when the backend registers `:waiting-p`, it must return non-nil
   (authoritative — on Codex app-server this is turn state, and it prevents
   the one real hazard: submitting into an active turn *steers* it there);
4. when the backend registers `:busy-p`, it must return nil;
5. for buffers with no authoritative probe (Claude, Codex terminal), the
   event must not arrive within `agent-queue-debounce` (default 1.0 s) of
   the previous drain submission — a duplicate-hook guard, not a state
   guess.

On drain: pop the head, record it in-flight, submit via `agent-submit`
inside `condition-case`.  Success resolves when a later `stop` arrives
after the session was observed busy (the synchronous `submit` event sets
that immediately).  Failure restores the item to the head of the queue and
files a queue-failure attention item; nothing is dropped.

A safety-net repeating timer (10 s, running only while the queue is
non-empty, registered for teardown) re-evaluates the gate so a missed or
coalesced backend event delays a drain rather than stranding it.  The timer
never invents state: it re-reads the same gate.

### Restart, handoff, exit, kill, process death

- **`agent-restart`** is the only flow that migrates a queue live, because
  it alone proves identity: core detaches the queue before killing the old
  buffer and re-attaches it to the new buffer only when the restart resumed
  non-fork with the same native session id (which `agent-start-session`
  seeds).  Core calls the queue module through `fboundp`-guarded optional
  functions (`agent-queue-detach` / `agent-queue-attach`), mirroring the
  existing `agent-capture` soft dependency.
- **Everything else** (exit, handoff, buffer kill, backend process death)
  goes through the existing teardown owner: a teardown function converts
  remaining items into ordinary entries in the session's `agent-capture`
  Org file — durable, inspectable, *not* armed for automatic submission —
  and files an info attention item saying so.  A captured draft and an
  armed queue item are deliberately different things; demotion to draft is
  the only automatic conversion, never the reverse.
- `agent-exit`, `agent-restart`, and `agent-handoff` extend their existing
  pending-prompt confirmation to also mention queued prompts.

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
  → `blocked` with `(:kind permission :message MSG)`, `elicitation_dialog`
  → `blocked` with `(:kind question :message MSG)`.
- New hook-event handlers on `claude-code-event-hook` (observers returning
  nil, so they never win the first-non-nil-response race or emit a
  decision): `permission-request` → `blocked` with `:kind permission`,
  `:tool tool_name`, and a short rendering of `tool_input`; `stop-failure`
  → `error` with the reported `error` code and `last_assistant_message`.
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
   app-server notification.  Read-only observation; return values ignored.
2. `codex-app-server-request-handler` — defcustom function called with
   `(BUFFER METHOD PARAMS RESPOND)` for server requests codex.el knows how
   to answer; `RESPOND` sends the JSON-RPC response exactly once.  Default
   `codex-app-server-modal-request-handler` preserves today's behavior
   byte-for-byte.  A public `codex-app-server-request-choices (METHOD
   PARAMS)` exposes the existing CLI-worded choice tables as
   `(KEY LABEL HELP RESULT)` entries so outer packages reuse codex.el's
   response encoding instead of duplicating protocol knowledge; it returns
   nil for requests that need free-form input (`item/tool/requestUserInput`,
   schema-bearing elicitations), and any handler must fall back to the
   modal handler for those.

### agent-codex

- `:interrupt` = `codex-send-escape` with the target buffer current.
- `:steer-p` = live app-server process with an active turn (plus terminal
  buffers only if verification confirms); `:steer` submits through the
  existing public submit path.
- Terminal `PermissionRequest` hook events → `blocked` with
  `(:kind permission)` plus defensively-parsed fields from the opaque JSON
  (shown only when present).
- With the upstream hooks available (guarded by `fboundp`, so agent-codex
  keeps working against an older codex.el):
  - `turn/started` → `activity`; `turn/completed` → `stop` (no ready alert
    here — the CLI `Stop` hook still owns `idle-prompt` alerts);
    `thread/status/changed` `systemError` → `error`.
  - `agent-attention-mode` installs an app-server request handler that
    creates a permission/question attention item carrying respond actions
    built from `codex-app-server-request-choices`, fires the same approval
    alert as today, and clears the item when the response is sent.
    Requests with no choice table delegate to the modal handler unchanged.
    Disabling the mode restores the modal handler.

## 7. Manual

README.org (and the texi export) gains an "Attention and busy sessions"
section documenting: the three operations and which backend/transport
supports each (including that Claude cannot steer and why); how attention
items are created and cleared; that unknown state stays unknown; the queue
lifecycle including the exactly-once drain, what happens on restart
(migration only on proven same-session resume), and the demotion of queued
prompts to capture drafts on any other teardown; and the new setup-config
hook entries.

## 8. Out of scope

Historical browsing/transcripts/`agent-log` changes; a transcript renderer;
a task board or scheduler; a context-reference composer; automatic approval
decisions or backend security-policy changes; reimplementing backend
protocols in the core; remote keystroke answering of Claude dialogs;
`item/tool/requestUserInput` form rendering in the inbox; changes to
claude-code.el.

## 9. Verification

ERT (deterministic, stubbed backends): structured event payloads and hook
delivery including legacy two-arg calls; attention item lifecycle
(creation, replacement, seen-on-visit, clear-on-activity, buffer death);
capability dispatch (steer refused for Claude and for idle/terminal Codex,
interrupt routing); queue add/edit/delete/reorder; exactly-once drain under
duplicate stop events, short turns, and poll interference; drain blocked
while `:waiting-p` is nil; submission failure keeps the item and files an
attention item; teardown demotes to capture drafts; restart migrates only
on matching id.  `make test` and `make compile` clean in both `agent` and
`codex` repos.

Live, both backends where applicable: queue a follow-up during a real turn
and verify it does not alter the current turn, submits exactly once after
completion, and is inspectable until then; edit/delete/reorder queued
prompts; verify Codex app-server steering is same-turn (and decide the
terminal-steer question empirically); verify unsupported backends refuse to
steer; produce real permission and elicitation requests and verify inbox
reason, respond actions (Codex app-server), and clearing; leave a session
in the background through a completed turn and verify unread/seen behavior;
exercise restart and buffer kill with a non-empty queue and verify no
prompt reaches a different session.
