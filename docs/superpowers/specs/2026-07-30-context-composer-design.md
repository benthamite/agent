# Context Composer — Design

## Problem

Attaching context to a live session today means remembering backend-specific
commands and one-off workflows (`claude-code-send-region`,
`codex-send-buffer-file`, manual copy-paste of diffs and diagnostics).
Emacs already knows the region, buffers, project files, Git state,
diagnostics, compilation output, images, and saved prompts.  There is no
single workflow that gathers several such sources, shows exactly what will
be sent, lets the user prune and reorder it, and dispatches to either
backend.

## Verified backend capabilities

Verified against the installed packages (codex.el at `benthamite/codex`,
claude-code.el 0.4.5) and existing in-tree usage.  The design exposes only
these channels.

| Channel | Claude Code | Codex terminal (eat/vterm) | Codex app-server |
|---|---|---|---|
| Multi-line inline text | established upstream path (`claude-code-send-region`, this repo's `agent-claude-send-todo-at-point`) via `agent-submit` | same (`codex-send-region`) | programmatic JSON-RPC submit; no TUI involved |
| File reference (native mention) | `@/abs/path` token in submitted text; the CLI expands it (this is how upstream `claude-code-send-file` works) | `@/abs/path` token, same convention | structured mention items; `@` text is **not** parsed.  `codex-app-server-attach-mention` exists but is interactive-only — a small public API is needed (below, approved) |
| Image attachment | write file + `@path` token — exactly upstream's own `yank-media` image-paste implementation | `@path` token (`codex-send-image`) | native `localImage` items via public `codex-app-server-attach-image PATH` |
| Busy/idle knowledge | session state machine; no authoritative probe | same | authoritative turn state |

There is **no queue, steer, or interrupt integration available in this
worktree** (that project is design-only); the composer therefore requires
an idle target and enforces it (§6).  If a capability-aware queue lands
later, the composer integrates through its public contract; nothing here
duplicates it.

Claude/codex-terminal image delivery rests on the CLIs' @-mention handling
(the same assumption upstream ships); live verification confirms the model
receives an image, and if a backend fails that check its image capability
is removed rather than papered over.

## 1. Item model (`agent-context-item` struct)

`id`; `kind` (`region`, `buffer`, `file`, `diff`, `commit`, `diagnostics`,
`compilation`, `url`, `image`, `capture`); `label`; `provenance` (plist of
backend-neutral facts: `:path`, `:buffer-name`, `:lines`, `:repo`, `:rev`,
`:url`, `:resolved-url`, `:fetched-at`, `:captured-at`); `transport`
(`inline`, `mention`, `media`); `content` (string, snapshots only);
`size` (`(:bytes N :exact BOOL)`); `note` (user-visible caveat: truncated,
empty body, skipped entries…).  Order is list position in the draft.

One rule keeps previews truthful with no per-item special cases:

- **`inline` ⇒ snapshot.**  Content is captured when the item is added (or
  refreshed), size is exact, and the preview shows the very bytes that
  will be sent.
- **`mention`/`media` ⇒ resolved at send.**  The CLI reads the file when
  the message is submitted; size is the file's current size, labeled
  estimated ("read at send").

A directory or project subtree is not an item: adding one **expands at add
time** into individual file items (mention transport by default, per the
approved decision), after the safety filter (§7), with an expansion report
("added 12, skipped 3 binary, 1 secret-path, 2 oversize, 1 symlink
escape").  This keeps the preview per-file truthful and reorderable.

Kind availability by capability, never downgraded silently: `mention` is
offered only when the target backend registers the file-reference slot
(§8); `media` only when it registers the media slot; toggling a file item
to `inline` snapshots it immediately (and back discards the snapshot).

## 2. Sources

- **Region / buffer** — snapshot of the active region or whole buffer,
  provenance records file/buffer and line range.
- **Files** — one or more via `read-file-name`/completing-read; a Dired
  convenience command adds the marked files.  Default transport `mention`.
- **Directory / project subtree** — expansion per §1; inside a project the
  file list comes from `project-files` (Git-aware: `.git`, ignored build
  products, and caches are excluded by the VCS itself — the "existing
  abstraction" the requirements ask for); outside a project,
  `directory-files-recursively` filtered by `agent-context-exclude-regexps`
  (defaults: `.git/`, `node_modules/`, `elpaca/`/`elpa/` builds, `.cache/`,
  `build/`, `dist/`, `target/`).
- **Git** — working-tree diff, staged diff, or selected recent commits
  (completing-read over `git log --oneline`, content via `git show`), run
  with `process-file` in the composer's originating directory; provenance
  records repo root and revisions.  Inline snapshots (refreshable).
- **Diagnostics** — flymake diagnostics for a chosen buffer (flycheck used
  when it is active there), rendered one per line
  (`file:line severity message`).  Inline snapshot.
- **Compilation / other buffer** — contents of a chosen
  `compilation-mode`-derived buffer, or of any explicitly selected buffer.
  Inline snapshot.
- **Image / clipboard media** — an image file, or clipboard image written
  to a private temp file (0600, under the composer's temp directory).
  Transport `media`.
- **URL** — explicit fetch at add time (§7); inline snapshot with URL
  provenance.
- **Captured prompt** — an entry from the target session's `agent-capture`
  file (reusing its reader); on successful dispatch the entry is removed
  from the capture file, matching `agent-insert-captured-prompt`.

Refresh (`r` on an item) re-resolves a snapshot from its provenance (re-run
the diff, re-read the region if its buffer lives, re-fetch the URL after
confirmation); items whose source is gone report that instead of guessing.

## 3. Deterministic rendering

The dispatched message is: the instruction, then each item in draft order.

- Inline items render as a heading `### Context N: LABEL`, one provenance
  line (`Source: PATH lines A–B, snapshot taken HH:MM` / `Source: git diff
  (working tree) at REV` / `Source: URL, fetched HH:MM, resolved to
  FINAL-URL`), then a fenced code block whose fence is one backtick longer
  than the longest backtick run in the content (deterministic, collision
  free), tagged with the language inferred from the mode or extension.
- Mention items render as exactly the token the adapter returns (for
  Claude/codex-terminal an `@/abs/path` line; for app-server a `$name`
  line while the mention item rides out of band) — one representation per
  item, never both attached and inlined.
- Media items render as the adapter's token line (`@path` where the CLI
  attaches from the token; a plain `(image attached: NAME)` line where the
  attachment is protocol-native).

The renderer is a pure function of the draft and is covered by fixture
tests, including fence-collision content and multi-kind combinations.

## 4. Composer UI (approved: dedicated buffer)

`agent-context-compose` (autoloaded) selects a target session (the current
session buffer when invoked from one; otherwise the existing session
picker with display names and accounts) and pops the single draft buffer
`*Agent context*` in `agent-context-mode` (derived from `special-mode`;
re-invoking pops to the existing draft).  Layout: a target header; an
editable instruction field (markers delimit the only writable region);
the item table (label, transport, size with exact/estimated tag, notes);
a totals footer (textual bytes, mention/media counts, warnings).

Keys: `a` add-source transient (region, buffer, file, directory/project,
git, diagnostics, compilation, other buffer, image/clipboard, URL,
captured prompt); `p`/`RET` preview the item's exact content (or, for
deferred items, the current file content clearly titled "as of now;
re-read at send"); `P` preview the fully rendered outgoing message; `d`
delete; `M-<up>`/`M-<down>` reorder; `t` toggle inline/mention; `r`
refresh; `T` retarget; `C-c C-c` dispatch; `C-c C-k` cancel (confirms,
then cleans owned temp files); `q` bury (draft persists).

Convenience commands, all funneling into the same draft:
`agent-context-add-region` (from any buffer; starts a draft if none) and
`agent-context-add-dired-files`.  No keymaps outside the composer buffer
are touched; nothing installs at load time.

## 5. Preview truthfulness

The buffer itself is the preview contract: target session and backend;
every item in dispatch order; per item its source, snapshot-vs-resolved
status, and byte/character size tagged `exact` or `est.`; totals for
textual content and native attachments; and per-item notes for anything
truncated, transformed (URL HTML rendered to text), skipped during
expansion, or rejected.  Sizes are reported in **bytes/characters only**
— no token counts, because no authoritative tokenizer for the target
model is available, and the manual says exactly that.

## 6. Dispatch

On `C-c C-c`, in order, with the draft preserved on every failure path:

1. **Re-validate the target.**  Dead buffer or vanished backend → offer to
   retarget; nothing sent.
2. **Busy policy.**  `agent-session-display-state`: `busy` → `user-error`
   naming the state (no queue exists in this worktree, and the composer
   must not steer or queue through a side effect); `unknown` → explicit
   confirmation ("state unknown — send anyway?"); waiting states proceed.
3. **Resolve and re-check deferred items**: mention/media files must still
   exist, be readable, and pass the §7 checks (re-applied at dispatch);
   a violation names the item and aborts before anything is sent.
4. **Size gate** on the rendered text: confirm above
   `agent-context-warn-bytes` (default 65536); refuse above
   `agent-context-max-bytes` (default 262144).
5. **Attach out-of-band items** through the backend slots.  Each
   attachment returns an undo closure; if a later step fails, the undo
   closures run (app-server pending attachments are detached via the new
   upstream API) so no orphaned attachment rides the user's next manual
   message.
6. **Submit once** via `agent-submit` inside `condition-case`; any signal
   runs the undo closures, messages the error, and leaves the draft
   buffer untouched and retryable.
7. **Success**: the message reads "Dispatched to SESSION: instruction +
   N items (…)" — and the manual is explicit that for terminal transports
   "dispatched" means the text was inserted and submitted at the TUI
   prompt, which is all those transports can attest.  The draft buffer is
   killed; the item list is retained in `agent-context--last` and
   `agent-context-recompose` rebuilds a draft from it (post-dispatch
   regret insurance).  Capture-sourced entries are deleted from their
   capture file only on success.  Codex.el's own async restore machinery
   covers the app-server case where a `turn/start` later fails: it
   returns the submission, attachments included, to that session's
   composer — documented, not reimplemented.

## 7. Safety rules

Applied when items are added **and re-applied at dispatch** for deferred
items:

- **Secret paths**: `agent-context-secret-path-regexps` (defaults:
  `~/.ssh/`, `~/.aws/`, `~/.gnupg/`, `.netrc`, `.authinfo` and
  `.authinfo.gpg`, `.env` and `.env.*`, `*.pem`, `*.key`, `id_rsa*`,
  `credential`/`secret` path components, `.password-store/`).  Rejected
  for every transport — an @-mention makes the CLI read the file, so
  mentions are just as gated as inlining.  Rejection messages name the
  path only; contents never appear in messages, warnings, or previews.
- **Binary files**: NUL byte in the first 8 KiB → rejected for `inline`;
  recognized image types route to the `media` kind; other binaries are
  rejected for every transport (a mention would only make the CLI choke
  on them).
- **Symlinks**: during directory/project expansion, entries whose
  `file-truename` escapes the selected root are skipped and counted in
  the expansion report.  An explicitly chosen single file may be a
  symlink; its truename is displayed.
- **Limits** (defcustoms): `agent-context-max-files` per expansion
  (default 40), `agent-context-max-file-bytes` for inline content
  (default 131072), and the total-size warn/refuse gates of §6.
- Inside projects, traversal exclusions come from the VCS via
  `project-files` rather than an ad hoc blacklist; the regexp excludes
  apply to non-project directories.

## 8. Backend integration

Two new **optional** `agent-backend` slots — generic dispatch contracts,
keeping protocol knowledge in the adapters:

- `:attach-file-reference` — function of PATH and BUFFER; performs any
  out-of-band attachment and returns `(TOKEN . UNDO)` where TOKEN is the
  text placed in the message and UNDO is nil or a closure removing the
  out-of-band attachment.
- `:attach-media` — same contract for images/media.

Registrations:

- **Claude**: file reference → `("@PATH " . nil)`; media → the same (the
  CLI attaches @-mentioned images; identical to upstream's own image
  paste).  Registered only for image types.
- **Codex terminal**: same two registrations with the Codex `@` token.
- **Codex app-server**: file reference → call the new programmatic
  mention API and return `("$NAME" . DETACH)`; media →
  `codex-app-server-attach-image` and `("(image attached: NAME)" .
  DETACH)`.

### Upstream codex.el change (approved; implemented in that repo)

Make `codex-app-server-attach-mention` accept a PATH argument
programmatically (mirroring `codex-app-server-attach-image`'s shape), have
both attach functions return a handle for the pending entry, and add
`codex-app-server-detach (HANDLE)` which removes the entry if it is still
pending.  The detach half is what makes dispatch-failure cleanup possible
(§6 step 5) — without it a failed submit would leave our attachments
riding the user's next manual message.  No other codex.el changes;
claude-code.el is not modified at all.

## 9. Module boundaries and ownership

Everything lives in `agent-context.el` except: the two backend slots
(core struct), the per-backend registrations (each adapter), and one
`agent-menu` entry in the Prompts column (`C`, "compose context",
autoloaded like the capture entries).  Loading the module installs no
global hooks and alters no keymaps.  Owned resources: clipboard/temp
image files (0600, module temp directory) are deleted when their item is
removed or the draft is cancelled, and are *kept* after dispatch (the CLI
may read them asynchronously; the manual says so); the draft buffer's
`kill-buffer-hook` cleans undispatched temp files; URL fetches are
synchronous with a timeout, so no processes or timers outlive commands.

## 10. URL handling

Fetching is explicit (the user picks the URL source and confirms
re-fetches).  `url-retrieve-synchronously` with
`agent-context-url-timeout` (default 10 s) and
`agent-context-url-max-bytes` (default 524288): network errors and HTTP
status ≥ 400 are user-errors naming the failure (nothing added); a 2xx
empty body **is added**, with an explicit "empty body (0 bytes)" note —
failure and emptiness stay distinguishable.  Redirects are followed by
url.el; provenance records both the requested and final URL.  When libxml
is available and the content is HTML, the body is rendered to text with
`shr` (built-in, no new dependency) and the item is marked transformed;
otherwise the raw body is kept.  The manual describes URL content as
untrusted external input that the user should preview before sending.

## 11. Manual

README.org (and the texi export) gains a "Composing context" section:
composing and previewing mixed context; the snapshot-vs-resolved rule
(inline = snapshot, mention/media = read at send); the deterministic
rendering and the one-representation rule; backend capability differences
(Claude and terminal Codex use `@` mentions, app-server uses native
mention/image items, images require live-verified support); size limits,
binary handling, secret-path protection, symlink behavior, and URL trust;
and exactly what happens on failure (draft preserved, undo of
attachments, retry) and on a busy or unknown-state target.

## 12. Out of scope

Historical browsing/transcripts/`agent-log`; the attention/queue/steer/
interrupt project (no integration — nothing of it exists in the worktree);
automatic or background context collection; LLM-based summarization,
chunking, retrieval, or relevance guessing; a file manager, scraper, or
project index; task boards, schedulers, memory; reimplementing backend
attachment protocols in the shared core; modifying claude-code.el.

## 13. Verification

ERT (deterministic, stubbed backends and `process-file`):

- Item construction for every kind; ordering; reorder/delete/toggle.
- Snapshot vs deferred: inline items keep their bytes when the source
  changes; mention items re-resolve and re-check at dispatch.
- Renderer fixtures: multi-kind combinations, fence-collision content,
  provenance lines, exact/estimated size labels, byte-only size wording.
- Native attachments are not also inlined; unsupported media on a stub
  backend without the slot yields an honest error and an intact draft.
- Safety: binary rejection, secret-path rejection for both inline and
  mention, symlink-escape skipping, per-expansion file limit, per-file
  and total size limits, oversize refusal, warn-gate confirmation.
- Dispatch: busy target refused; unknown state requires confirmation;
  dead target offers retarget; target killed between add and dispatch;
  submission failure runs undo closures and preserves the draft; success
  clears the draft, retains `agent-context--last`, and deletes
  capture-sourced entries.
- URL: success, HTTP error, network error, empty-body distinction, size
  cap, redirect provenance — all against a stubbed
  `url-retrieve-synchronously`, no network.

`make test` and `make compile` clean in both `agent` and `codex` repos.

Live, both backends: send a region plus instruction, a selected file
(mention), and a Git diff, and verify from the conversation that the
agent received each source exactly once with the intended content; a real
image attachment per backend where supported, verifying the model
received an image rather than a path string (removing the capability for
any backend that fails this); preview, removal, reordering, cancellation,
and retry after an induced submission failure; and the busy policy —
composing at a busy session must not alter the running turn.
