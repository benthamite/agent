# Live Verification: Unified Agent Menu

Replaces Task 13 of `2026-08-05-unified-agent-menu.md`, which was written before
we learned what it costs to evaluate things in a running Emacs.

## Why the original was wrong

Task 13 told the verifier to call `agent-codex--session-headers` and friends
through `emacsclient`. Every such call blocks the editor for as long as it
runs, and nothing outside Emacs can interrupt it: a client killed after one
second leaves the daemon busy, as measured — a follow-up probe timed out three
seconds later. An unbounded Codex scan took ~1.9s per call, and a separate
15-second reload defect in `elpaca-extras` compounded it. The lesson is not
"avoid live verification"; it is that **what you send to a live Emacs must be
bounded by construction**.

Baseline responsiveness for reference: a trivial `emacsclient -e` round trip is
21ms. Anything an order of magnitude beyond that is a freeze the user feels.

## Tiers

Each check states who runs it and what it costs. A check that cannot be made
cheap belongs in a tier where its cost is expected and consented to.

### Tier 1 — instant introspection (agent runs, no user involvement)

Pure reads of loaded state. Nothing touches the filesystem or spawns a process.
Each is a single `emacsclient -e` costing ~20ms.

- [ ] **Menu shape.** Walk `(get 'agent-menu 'transient--layout)` and collect
  every `:key`. Expect exactly: Sessions `e w R N B h x r l`, Buffer `K f S`,
  Tools `s n c a d m g`, Alerts `T`, Prompts `p i b t`, Options
  `-A -p -t -c -w`. Expect no group titled "Claude Code" or "Codex", and no
  `u`, `U`, `F`, or `-x`.
  Note: `fboundp` on a deleted function is NOT a valid check in a live session —
  Emacs keeps the old binding until restart. The batch test covers deletion.
- [ ] **Struct slot removed.** `menu-suffixes` absent from
  `(cl-struct-slot-info 'agent-backend)`.
- [ ] **Commands defined.** `agent-resume`, `agent-create-branch`,
  `agent-switch-branch`, `agent-batch-todos`, `agent-send-todo-at-point`.
- [ ] **Slots registered.** Both backends answer non-nil for `resume`,
  `session-headers`, `session-prompt`, `exec-prompt`; Claude alone for
  `prepare-fork`.
- [ ] **Obsolete aliases resolve.** `agent-claude-switch-branch`,
  `agent-claude-create-branch`, `agent-claude-batch-todos`,
  `agent-claude-send-todo-at-point` are `fboundp`; setting
  `agent-claude-warn-kill-with-branches` changes `agent-warn-kill-with-branches`.
- [ ] **Account summary.** `(agent--account-summary)` names every backend with
  its current account, and the infix renders it without surrounding quotes.
- [ ] **Every suffix is a command.** `(interactive-form 'SYM)` non-nil for all
  22 suffix symbols in the layout. Transient defers this to keypress, so this
  is the only cheap way to catch a non-interactive suffix.

### Tier 2 — bounded work (agent runs, cost measured and stated)

Real work against real data, each bounded by construction. Time every call and
report the number; anything over ~200ms in this tier is a finding, not a pass.

- [ ] **Codex family lookup.** For a live Codex session, the family lookup
  reads only its ancestry plus rollouts started after the family root. Report
  elapsed time and files touched. Expect well under 200ms.
- [ ] **Codex kill-time bound.** `session-headers` called with a session id
  returns only that session's descendants. Report elapsed time.
- [ ] **Claude family scan.** Claude's scan is per-project and reads first
  lines only; report elapsed time for a live Claude session.
- [ ] **Session resolution.** `agent--session-buffer-for-project` returns the
  sole session for a project directory, and signals a `user-error` naming the
  directory when none is running.

### Tier 3 — real workflows (agent runs; creates and destroys real sessions)

These spawn processes and open buffers in the user's Emacs. They are the only
way to verify the feature actually works, and they are cheap per call now that
the scans are bounded. Run them in a scratch project directory, and kill every
session created. Announce before starting and report after finishing.

- [ ] **Claude branch round trip.** From a Claude session: `agent-create-branch`
  opens a new buffer resuming the parent's conversation with a *different*
  session id; `agent-switch-branch` from the parent lists both, marks the
  current one, and switching to the child selects its live buffer rather than
  resuming a second copy.
- [ ] **Codex branch round trip, both terminal backends.** The same, once with
  `codex-terminal-backend` set to `app-server` and once with the default. The
  forked Codex buffer must show the parent's history — an empty fork means the
  `:fork` path is broken, not an acceptable difference.
- [ ] **Isolated branch.** `agent-create-branch` with a prefix argument creates
  a worktree under `agent-branch-worktree-directory` on branch
  `agent-branch-HHMMSS` and runs the fork inside it, for both backends. This is
  the path most likely to fail for Codex, where the session was recorded under a
  different `cwd`. Remove every worktree and branch created.
- [ ] **Kill warning.** With `agent-warn-kill-with-branches` non-nil, killing a
  branched session prompts and names the branch count; with it nil, no prompt.
  The second half is the behavior the option never actually had before this work.
- [ ] **TODO workflows against Codex.** `agent-send-todo-at-point` delivers the
  heading to a running Codex session and advances the TODO state;
  `agent-batch-todos` over a two-entry region produces `*Agent Batch Results*`
  with an em dash in the cost column rather than an arithmetic error.

### Tier 4 — the user's own eyes (cannot be delegated)

- [ ] **Open `agent-menu` and look at it.** Column balance, description
  wording, and whether the account line reads well at a glance are judgments
  about a thing on screen. The agent can assert the layout's contents; only
  the user can say whether the menu is good.
- [ ] **Press `R` in each backend.** Resume opens each CLI's own picker, which
  is an interactive UI the agent cannot meaningfully drive: Claude's is a TUI
  inside the terminal buffer and Codex's lists threads over its app-server.
  Confirm each opens its own picker with no backend prompt.
- [ ] **Press `-c` from three places.** Inside a Claude session (no backend
  prompt), inside a Codex session (no backend prompt), and from an unrelated
  buffer (prompts for the backend first).

## Rules for anything sent to the live Emacs

1. No unbounded iteration over the filesystem. Bound by construction, never by
   hope.
2. No form whose runtime you have not measured in batch first.
3. Never print a large object — extract counts or specific slots.
4. Time every Tier 2 call and report the number, so a regression shows up as a
   number rather than as the user complaining.
5. If a check needs more than a second of the user's editor, it belongs in
   Tier 3 with an announcement, or in batch.
