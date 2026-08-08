# One command that acts on the thing at point

## Problem

Four menu entries did the same kind of work: take whatever is under point,
figure out which project it belongs to, and hand it to a session.

    d  debug backtrace              *Backtrace* buffer  -> new session
    m  act on Slack message         Slack room buffer   -> new session
    g  act on Forge notification    Forge/Magit buffer  -> new session
    t  send todo at point           org TODO heading    -> existing session

The user always knows what they are looking at, so choosing among four keys is
work the menu could do itself.  Nothing else distinguishes them: each command
already errors when its own context is absent, and no two contexts can hold at
once — a buffer is a backtrace, or a Slack room, or a Forge list, or an org
file.  Four keys encoded a fact the buffer already carries.

## Design

`agent-act-on-thing-at-point`, bound to `.` in the menu's Tools column, walks
`agent-at-point-actions` and calls the first command whose predicate matches:

| Predicate | Matches when | Command |
|---|---|---|
| `agent--backtrace-at-point-p` | buffer name contains `*Backtrace*` | `agent-debug-backtrace` |
| `agent--slack-message-at-point-p` | `slack-current-buffer` is non-nil | `agent-act-on-slack-message` |
| `agent--forge-topic-at-point-p` | Magit-derived mode and a topic at point | `agent-act-on-forge-notification` |
| `agent--org-todo-at-point-p` | org-mode buffer, point on a TODO state | `agent-send-todo-at-point` |

When nothing matches, the command signals a `user-error` naming the four kinds
it recognizes.  It does not fall back to a prompt: every handler needs context
that only the buffer can supply, so a chosen action would fail immediately.

### Predicates answer from the buffer alone

The table is ordered and lives in `agent.el`, but its predicates never call
into the modules that own the commands.  They read a buffer name, a
buffer-local variable that `slack` sets, the major mode, and the org TODO
state.  This matters because the four commands are autoloaded: a predicate
that had to load `forge` or `slack` to answer "is it you?" would load every
module on every invocation until one matched.  The Forge case is the only one
needing a function call, and the major-mode gate keeps that call inside
buffers where `forge` is already loaded.

`agent-at-point-actions` is a `defvar`, not a `defcustom`.  The dispatch order
should be visible and editable, but a customization interface for it would be
shape without a user.

### The four commands survive

They stay interactive and keep their names, so anything that binds
`agent-act-on-forge-notification` in `forge-notifications-mode` keeps working.
Only the menu collapses, freeing `d`, `m`, `g`, and `t`.

## Testing

`test/agent-test.el` covers `agent--action-at-point` per context: a renamed
temp buffer for the backtrace, a bound `slack-current-buffer` for Slack, a
`magit-mode` buffer with stubbed Forge lookups, and a real org TODO heading.
Negative cases assert that an org heading without a TODO state and a Forge
buffer without a topic both fall through, that `forge` is never consulted
outside a Magit-derived buffer, that the first matching entry wins, and that
an unrecognized buffer signals `user-error`.
