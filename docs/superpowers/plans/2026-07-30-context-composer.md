# Context Composer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A unified, cross-backend context composer (`agent-context.el`): gather
region/buffer/file/directory/git/diagnostics/compilation/image/URL/captured-prompt
context, preview it truthfully in a dedicated draft buffer, and dispatch it
once to an idle **Codex app-server** session — the only transport that can
prove literal, isolated, atomic submission in v1.  Claude and terminal
Codex targets are compose-and-preview only until their backends provide
the required submission contracts.  Per
`docs/superpowers/specs/2026-07-30-context-composer-design.md` as amended
by Task 1.

**Architecture:** A new `agent-context.el` module holds the item model,
sources, safety layer, renderer, composer buffer, and dispatch pipeline.
Core gains seven optional backend slots — pure token renderers
(`:file-reference-token`, `:media-token`), effectful attachers returning
undo closures (`:attach-file-reference`, `:attach-media`), an
authoritative `:ready-to-submit-p` probe, a `:pending-input-p` isolation
probe, and a `:submit-literal` submitter — plus a `submit-failed`
rollback event.  codex.el (sibling repo) gains a programmatic mention API with
detach handles and a public turn-readiness predicate.

**Plan revision 5 (dispatch transports):** `:submit-literal` is
registered ONLY for Codex app-server in this plan.  Claude (every
terminal backend) and Codex terminal sessions are refused honestly:
a terminal write has no acknowledgment, so no ownership boundary can
distinguish "Return failed before delivery" from "delivered", and the
prompt scanners cannot positively verify emptiness.  Supporting them
later requires upstream contracts — a presence-aware (tristate)
prompt-empty probe and an acknowledged or safely recoverable
submission API — in claude-code.el/codex.el respectively.  Claude
keeps its pure token slots (preview-complete, dispatch-ready for the
day that API exists); the composer warns at compose/retarget time and
refuses at dispatch.

**Plan revision 2** (after Codex review): pure/effectful slot split
(replaces the DRY-RUN contract; Task 1 amends spec §8 accordingly), a
final readiness gate so dispatch can never queue or steer, a commit
boundary at literal submission with isolated post-submit cleanup, core state
rollback on synchronous submit failure, `/mention` compatibility and a
mandatory codex rebuild, transport detection from
`codex-terminal-backend` with no silent downgrade, complete deferred
re-validation, spec-complete refresh/flycheck/rev/special-mode/transport-
column coverage, and repaired or added tests throughout.

**Tech Stack:** Emacs Lisp 30, `cl-defstruct`, `transient`, `project`,
`url.el`, `shr`, ERT.

## Global Constraints

- Never modify `claude-code.el`.  codex.el changes are exactly those in
  Task 10, in the sibling repo `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/codex`.
- Loading `agent-context.el` installs no global hooks and alters no keymaps
  outside its own buffers.
- The inline⇒snapshot / mention-media⇒resolved-at-send rule is invariant.
- Sizes are reported in bytes/characters only; never call them tokens.
- Secret-path rejections name the path only; secret contents never appear
  in any message, warning, or preview.
- Every PRE-submit dispatch failure (including `quit`) leaves the draft
  intact and retryable, runs every collected undo closure independently,
  and rolls the target's session state back with `submit-failed`.  The
  commit boundary is the successful return of `:submit-literal`, defined
  as OWNERSHIP TRANSFER: the backend has accepted delivery, including
  any backend-side failure recovery (Codex app-server restores a failed
  turn into its own composer — exactly one retry surface).  After it,
  the draft is disarmed first and no failure may restore it or run
  undos.
- Busy targets are refused; unknown *lifecycle* display state requires
  explicit confirmation (that gate concerns session state, not prompt
  isolation — unknown *prompt* state always refuses, per the
  `:pending-input-p` bullet above); and immediately before
  attachment/submission the backend's `:ready-to-submit-p` probe is
  consulted, treating pending turn starts, queued input, and
  reasoning-held submissions as busy — dispatch must never queue or
  steer through a backend side effect.  No queue/steer/interrupt
  integration exists in this worktree; do not add one.
- Transport support is decided from the buffer's actual configuration
  (`codex-terminal-backend`), never by API-presence fallbacks; an
  unsupported transport is an honest refusal, not a silent downgrade.
- Submission must be a literal, isolated, atomic model turn: dispatch
  goes through the backend's `:submit-literal` slot only (never
  `agent-submit`), which owns the backend's ordinary submission
  bookkeeping (hooks/advice-visible events) so state and session-id
  tracking see the turn.  In this plan ONLY Codex app-server registers
  the slot: terminal transports (all Claude backends, Codex eat/vterm)
  have no submission acknowledgment and no positively verifiable
  prompt-empty probe, so they are refused honestly until those
  upstream contracts exist.  Before attaching, the `:pending-input-p`
  probe must report the session verifiably clean — unsent prompt text,
  foreign pending attachments, and UNINSPECTABLE (`unknown`)
  transports all refuse dispatch.
- At the commit boundary the live draft is disarmed FIRST
  (`agent-context--current` set nil before any copy creation, capture
  deletion, or buffer kill), so no post-submit cleanup failure can
  leave a resendable draft.
- Defcustom defaults exactly as specified: `agent-context-max-files` 40,
  `agent-context-max-file-bytes` 131072, `agent-context-warn-bytes` 65536,
  `agent-context-max-bytes` 262144, `agent-context-url-timeout` 10,
  `agent-context-url-max-bytes` 524288.
- All 362+ existing tests keep passing; `make compile` stays warning-free
  in both repos.
- Commit after every task with a single-purpose message.

Run tests with `make test` from the repo root (loads every test file).
Byte-compile with `make compile`.

---

### Task 1: Core contracts — attachment slots, readiness probe, submit rollback

**Files:**
- Modify: `agent.el` (the `agent-backend` defstruct ~line 123;
  `agent-session-event` ~line 1168)
- Modify: `docs/superpowers/specs/2026-07-30-context-composer-design.md`
  — every section this plan's contracts changed, in the same commit, so
  the spec stays the source of truth:
  - §6 (dispatch): the commit boundary at successful literal submission
    (failure preservation applies only before it; afterwards the draft
    is disarmed first and cleanup failures warn but never resend), the
    `:ready-to-submit-p` readiness gate, the `:pending-input-p`
    isolation check, and dispatch via `:submit-literal` instead of
    `agent-submit`.
  - §8 (backend integration): the full slot roster — pure token slots,
    effectful attach slots, `:ready-to-submit-p`, `:pending-input-p`,
    `:submit-literal` — replacing the two-slot `(TOKEN . UNDO)`
    contract; the `submit-failed` rollback event.
  - §8 Codex upstream subsection: replace "No other codex.el changes"
    with the actual approved API set (programmatic `attach-mention`,
    attach handles, `codex-app-server-detach`,
    `codex-app-server-ready-for-turn-p`,
    `codex-app-server-submit-literal`,
    `codex-app-server-pending-attachments-p`).
  - §1/§2 (item model/sources): region provenance keeps live markers
    plus the display line range; refresh reproduces the exact region
    for live drafts.  Recomposed drafts are the documented exception:
    retained copies deliberately share no marker objects (a cancelled
    recompose must not invalidate `agent-context--last`), so
    refreshing a recomposed region item honestly reports its markers
    as released instead of re-reading.
  - §4 (composer UI): the instruction field is bounded by a text
    property, not markers ("markers delimit the only writable region"
    is superseded).
  - §7 (safety): secret checks apply to both the chosen path spelling
    and its truename, at add, preview, and dispatch; explicitly chosen
    symlinks display their truename and never bypass secret protection.
  - §9 (module boundaries): "the two backend slots" becomes the full
    seven-slot roster, matching §8.
  - Problem/overview wording and §13 (verification): v1 dispatches only
    to Codex app-server sessions; Claude and terminal Codex targets are
    compose-and-preview only (token slots keep previews complete), the
    composer warns at compose/retarget and refuses at dispatch, and the
    live-verification list matches Task 14 (dispatch workflows on
    app-server; honest-refusal checks for the others).  The "send to
    either backend" promise is explicitly deferred to the day
    claude-code.el/codex.el provide a tristate prompt-empty probe and
    an acknowledged or safely recoverable submission API.
- Test: `test/agent-test.el`

**Interfaces:**
- Produces seven optional `agent-backend` slots with accessors
  `agent-backend-file-reference-token`, `agent-backend-media-token`,
  `agent-backend-attach-file-reference`, `agent-backend-attach-media`,
  `agent-backend-ready-to-submit-p`, `agent-backend-pending-input-p`,
  `agent-backend-submit-literal`.  Contract (used by Tasks 8, 9, 11):
  - `:file-reference-token` / `:media-token` — `(PATH BUFFER)` → TOKEN
    string, **pure** (no side effects; safe for previews and size gates),
    or nil when that transport is unsupported for BUFFER right now.
  - `:attach-file-reference` / `:attach-media` — `(PATH BUFFER)` →
    UNDO closure or nil; performs the out-of-band attachment whose text
    representation the token slot already rendered.  A backend whose
    token is the whole mechanism (Claude `@` mentions) registers no
    attach function.
  - `:ready-to-submit-p` — `(BUFFER)` → one of the symbols `ready`,
    `busy`, `unknown`.  `busy` must cover every state in which a
    submission would not start a fresh turn (active turn, pending
    `turn/start`, queued input, reasoning-held submissions).
  - `:pending-input-p` — `(BUFFER)` → nil when the session is
    verifiably clean (no unsent prompt text, no foreign pending
    attachments), a non-nil truthy description when something is
    pending, or the symbol `unknown` when the transport cannot be
    inspected.  The composer refuses dispatch for anything but nil —
    `unknown` refuses too (a blind append would violate isolation);
    it exists only so the refusal message can say "cannot verify".
  - `:submit-literal` — `(TEXT BUFFER)`; submits TEXT as one literal,
    isolated model turn.  Contract: preconditions signal a
    `user-error` before anything is sent; the channel must be
    structurally literal (no CLI command parsing) or reject
    command-parseable TEXT; the function performs the backend's
    ordinary submission bookkeeping — the same hooks/advice-visible
    events as interactive submission — so session state and session-id
    tracking observe the turn; and returning normally transfers
    OWNERSHIP of delivery, including backend-side failure recovery
    with failure-state notification, resolved exactly once across
    synchronous errors, quits, and asynchronous responses (a Codex
    app-server turn that fails to start is restored into that
    session's own composer AND announced through the upstream failure
    hook, which agent-codex translates into a `submit-failed' event —
    one retry surface, no stuck-busy session).  In this plan ONLY the
    Codex app-server adapter can meet the contract and registers the
    slot.  Terminal transports register nothing: a terminal write has
    no acknowledgment, so no ownership boundary can distinguish
    "Return failed before delivery" (draft must survive) from
    "delivered" (draft must be disarmed), and their prompt scanners
    cannot positively verify emptiness.  They stay unsupported until
    the backend provides a tristate prompt-empty probe and an
    acknowledged or safely recoverable submission API; the composer
    refuses them honestly.
- Produces the `submit-failed` session event: rolls the state set by a
  `submit` event back to `awaiting-input` with **no** ready alert, no
  before-exit-chain advancement, no scrolling — for callers whose backend
  dispatch signaled synchronously after `submit` fired.

- [ ] **Step 1: Write the failing tests**

Add to `test/agent-test.el`, new section `;;;; Backend attachment and readiness slots`:

```elisp
(ert-deftest agent-test-register-backend-accepts-attachment-slots ()
  "The registry accepts and exposes the attachment and readiness slots."
  (let ((agent-backends nil)
        (token (lambda (path _buffer) (format "@%s " path)))
        (attach (lambda (_path _buffer) (lambda () 'undone)))
        (ready (lambda (_buffer) 'ready)))
    (agent-register-backend
     'stub
     :buffer-p #'ignore
     :find-all-buffers (lambda () nil)
     :start-session #'ignore
     :file-reference-token token
     :media-token token
     :attach-file-reference attach
     :attach-media attach
     :ready-to-submit-p ready
     :pending-input-p (lambda (_buffer) nil)
     :submit-literal (lambda (_text _buffer) t))
    (let ((struct (agent-backend 'stub)))
      (should (eq (agent-backend-file-reference-token struct) token))
      (should (eq (agent-backend-media-token struct) token))
      (should (eq (agent-backend-attach-file-reference struct) attach))
      (should (eq (agent-backend-attach-media struct) attach))
      (should (eq (funcall (agent-backend-ready-to-submit-p struct) nil)
                  'ready))
      (should (agent-backend-pending-input-p struct))
      (should (agent-backend-submit-literal struct))
      (should (equal (funcall (agent-backend-file-reference-token struct)
                              "/tmp/x.el" nil)
                     "@/tmp/x.el ")))))

(ert-deftest agent-test-submit-failed-rolls-state-back-quietly ()
  "`submit-failed' restores awaiting-input without ready side effects."
  (let ((agent-backends nil)
        (alerts 0))
    (with-temp-buffer
      (cl-letf (((symbol-function 'agent--session-notify-ready)
                 (lambda (&rest _) (cl-incf alerts))))
        (agent-session-event (current-buffer) 'stop)
        (agent-session-event (current-buffer) 'submit)
        (should (eq (agent-session-display-state (current-buffer)) 'busy))
        (agent-session-event (current-buffer) 'submit-failed)
        (should (eq (agent-session-display-state (current-buffer))
                    'waiting))
        ;; No alert fired for the rollback (stop fires none either).
        (should (= alerts 0))
        ;; The rollback never advances a before-exit chain.
        (should (null agent--before-exit))))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test`
Expected: FAIL with "unknown slot keyword `:file-reference-token'" and
"Unknown agent session event: submit-failed".

- [ ] **Step 3: Implement**

In `agent.el`, extend the struct's send-slot line:

```elisp
  send-string send-return submit
  file-reference-token media-token attach-file-reference attach-media
  ready-to-submit-p pending-input-p submit-literal
```

Append to the `agent-register-backend` docstring (also covering the
`:pending-input-p` and `:submit-literal` contracts exactly as stated in
this task's Interfaces block):

```
Backends that can reference or attach files provide the optional
attachment keys.  `:file-reference-token' and `:media-token' are pure
functions of (PATH BUFFER) returning the exact text a composed message
embeds for PATH, or nil when that transport is unsupported for BUFFER;
they must be free of side effects so previews and size checks can call
them.  `:attach-file-reference' and `:attach-media' are functions of
(PATH BUFFER) performing the matching out-of-band attachment and
returning nil or an undo closure that removes it; backends whose token
is the whole mechanism register no attach function.
`:ready-to-submit-p' is a function of BUFFER returning one of the
symbols `ready', `busy', and `unknown'; `busy' must cover every state
in which a submission would not start a fresh turn.
```

In `agent-session-event`, add the event to the docstring list and the
dispatch:

```elisp
      ('submit-failed
       (agent--session-set-state buffer 'awaiting-input))
```

with this docstring addition:

```
A `submit-failed' event rolls back the state a `submit' event set when
the backend dispatch then signaled synchronously: the session returns
to `awaiting-input' with no ready alert, no before-exit-chain
advancement, and no scrolling, because nothing new happened in the
session itself.
```

Amend the spec in the same commit, covering every section listed in this
task's Files block — §6, §8 (both the slot roster and the Codex upstream
subsection), §1/§2, and §7 — so the spec and plan describe the same
contracts.

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test` — all tests pass.

- [ ] **Step 5: Commit**

```bash
git add agent.el test/agent-test.el docs/superpowers/specs/2026-07-30-context-composer-design.md
git commit -m "agent: add attachment, readiness, and rollback contracts"
```

---

### Task 2: Module scaffold — item model, draft, region/buffer/file sources

**Files:**
- Create: `agent-context.el`
- Modify: `Makefile` (SRC and TEST_FILES)
- Test: `test/agent-context-test.el` (create)

**Interfaces:**
- Produces:
  - `agent-context-item` struct: slots `id kind label provenance transport
    content size note`; constructor `agent-context-item-create`.
  - `agent-context-draft` struct: slots `target items origin-buffer
    origin-directory`; constructor `agent-context-draft-create`.
  - `agent-context--current` (defvar, the live draft or nil),
    `agent-context--last` (plist `(:instruction STR :items LIST)` after a
    successful dispatch).
  - `agent-context--exact-size (string)` → `(:bytes N :exact t)`;
    `agent-context--file-size (path)` → `(:bytes N :exact nil)`.
  - `agent-context--add-item (item)` (appends to the current draft),
    `agent-context--region-item (buffer beg end)`,
    `agent-context--buffer-item (buffer)`,
    `agent-context--file-item (path &optional transport)` (safety checks
    stubbed until Task 3 via `agent-context--assert-safe-path`, which this
    task defines as a no-op returning t),
    `agent-context--inline-file-item (path)`,
    `agent-context--mention-file-item (path)`,
    `agent-context--media-item (path &optional temp)`,
    `agent-context--image-file-p (path)`,
    `agent-context--language-for (path-or-mode)`.

- [ ] **Step 1: Register the new files in the Makefile**

In `Makefile`, append ` agent-context.el` to `SRC` and
` test/agent-context-test.el` to `TEST_FILES`.

- [ ] **Step 2: Write the failing tests**

Create `test/agent-context-test.el`:

```elisp
;;; agent-context-test.el --- Tests for agent-context -*- lexical-binding: t -*-
;;; Commentary:
;; Deterministic tests for the context composer.  No network, no live CLIs.
;;; Code:

(require 'ert)
(require 'agent-context)

(defmacro agent-context-test--with-draft (&rest body)
  "Run BODY with a fresh draft targeting a stub session buffer."
  `(let* ((target (generate-new-buffer " *ctx-target*"))
          (agent-context--current
           (agent-context-draft-create
            :target target :items nil
            :origin-buffer (current-buffer)
            :origin-directory default-directory)))
     (unwind-protect (progn ,@body)
       (kill-buffer target))))

(ert-deftest agent-context-test-region-item-snapshots-content ()
  "A region item snapshots exact bytes with an exact size."
  (with-temp-buffer
    (insert "alpha\nbeta\ngamma\n")
    (let ((item (agent-context--region-item (current-buffer) 7 11)))
      (should (eq (agent-context-item-kind item) 'region))
      (should (eq (agent-context-item-transport item) 'inline))
      (should (equal (agent-context-item-content item) "beta"))
      (should (equal (agent-context-item-size item) '(:bytes 4 :exact t)))
      (should (equal (plist-get (agent-context-item-provenance item) :lines)
                     '(2 2)))
      ;; Later buffer edits do not alter the snapshot.
      (erase-buffer)
      (should (equal (agent-context-item-content item) "beta")))))

(ert-deftest agent-context-test-add-item-appends-in-order ()
  "Items keep insertion order; order is dispatch order."
  (agent-context-test--with-draft
   (with-temp-buffer
     (insert "one two")
     (agent-context--add-item (agent-context--region-item (current-buffer) 1 4))
     (agent-context--add-item (agent-context--region-item (current-buffer) 5 8)))
   (should (equal (mapcar #'agent-context-item-content
                          (agent-context-draft-items agent-context--current))
                  '("one" "two")))))

(ert-deftest agent-context-test-file-item-defaults-to-mention ()
  "A text file becomes a deferred mention item with estimated size."
  (let ((file (make-temp-file "ctx" nil ".el" ";; hello\n")))
    (unwind-protect
        (let ((item (agent-context--file-item file)))
          (should (eq (agent-context-item-kind item) 'file))
          (should (eq (agent-context-item-transport item) 'mention))
          (should (null (agent-context-item-content item)))
          (should (equal (agent-context-item-size item)
                         (list :bytes 9 :exact nil)))
          (should (equal (plist-get (agent-context-item-provenance item) :path)
                         file)))
      (delete-file file))))

(ert-deftest agent-context-test-inline-file-item-snapshots ()
  "Toggling a file to inline snapshots its current content exactly."
  (let ((file (make-temp-file "ctx" nil ".txt" "content-v1")))
    (unwind-protect
        (let ((item (agent-context--file-item file 'inline)))
          (should (eq (agent-context-item-transport item) 'inline))
          (should (equal (agent-context-item-content item) "content-v1"))
          (should (equal (agent-context-item-size item) '(:bytes 10 :exact t)))
          (with-temp-file file (insert "content-v2-changed"))
          (should (equal (agent-context-item-content item) "content-v1")))
      (delete-file file))))

(ert-deftest agent-context-test-image-file-routes-to-media ()
  "An image path becomes a media item, not an inline or mention item."
  (let ((file (make-temp-file "ctx" nil ".png" "fake")))
    (unwind-protect
        (let ((item (agent-context--file-item file)))
          (should (eq (agent-context-item-kind item) 'image))
          (should (eq (agent-context-item-transport item) 'media)))
      (delete-file file))))

(provide 'agent-context-test)
;;; agent-context-test.el ends here
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `make test`
Expected: FAIL — `agent-context` cannot be loaded.

- [ ] **Step 4: Implement the scaffold**

Create `agent-context.el` (standard header/license/commentary matching the
other modules, `Package-Requires: ((emacs "30.0") (agent "0.1"))`):

```elisp
(require 'agent)
(require 'cl-lib)
(require 'subr-x)
(require 'text-property-search)
(eval-and-compile (require 'transient))

(defgroup agent-context ()
  "Cross-backend context composer for AI sessions."
  :group 'agent)

;;;; Item and draft model

(cl-defstruct (agent-context-item
               (:constructor agent-context-item-create)
               (:copier agent-context-item-copy))
  "One piece of context in a composition.
The copier exists so `agent-context--last' can retain deep copies that
later drafts cannot mutate."
  id kind label provenance transport content size note)

(cl-defstruct (agent-context-draft
               (:constructor agent-context-draft-create) (:copier nil))
  "A composition draft: target session plus ordered items.
NOTICES are retained warnings (e.g. directory-expansion skip reports)
rendered in the composer footer until the draft ends."
  target items origin-buffer origin-directory notices)

(defvar agent-context--current nil
  "The live `agent-context-draft', or nil.")

(defvar agent-context--last nil
  "Plist (:instruction STR :items LIST) of the last dispatched draft.")

(defvar agent-context--id-counter 0)

(defun agent-context--next-id ()
  "Return a fresh item id."
  (format "ctx-%d" (cl-incf agent-context--id-counter)))

(defun agent-context--exact-size (string)
  "Return the exact size plist for snapshot STRING."
  (list :bytes (string-bytes string) :exact t))

(defun agent-context--file-size (path)
  "Return the estimated (current) size plist for PATH."
  (list :bytes (or (file-attribute-size (file-attributes path)) 0)
        :exact nil))

(defun agent-context--add-item (item)
  "Append ITEM to the current draft."
  (unless agent-context--current
    (user-error "No context draft; run `agent-context-compose' first"))
  (setf (agent-context-draft-items agent-context--current)
        (append (agent-context-draft-items agent-context--current)
                (list item))))

;;;; Region, buffer, and file sources

(defun agent-context--region-item (buffer beg end)
  "Return an inline snapshot item for BUFFER's region BEG..END.
Provenance keeps the live BUFFER object and a pair of markers (begin
marker advances with insertions before it; end marker with insertions
at it), so refresh reproduces the exact — possibly partial-line —
region even after edits or a buffer rename.  The line range is kept
for display only."
  (with-current-buffer buffer
    (let ((text (buffer-substring-no-properties beg end))
          (lines (list (line-number-at-pos beg) (line-number-at-pos end)))
          (beg-marker (copy-marker beg nil))
          (end-marker (copy-marker end t)))
      (agent-context-item-create
       :id (agent-context--next-id) :kind 'region
       :label (format "%s:%d-%d" (buffer-name) (car lines) (cadr lines))
       :provenance (list :buffer buffer
                         :buffer-name (buffer-name)
                         :path (buffer-file-name)
                         :lines lines
                         :beg-marker beg-marker
                         :end-marker end-marker
                         :language (agent-context--language-for major-mode)
                         :captured-at (float-time))
       :transport 'inline :content text
       :size (agent-context--exact-size text)))))

(defun agent-context--release-item (item)
  "Release ITEM's per-buffer resources (region markers).
Called when an item is deleted and when a draft ends; markers left
pointing into source buffers would otherwise linger there."
  (let ((prov (agent-context-item-provenance item)))
    (dolist (key '(:beg-marker :end-marker))
      (when-let* ((marker (plist-get prov key)))
        (set-marker marker nil)))))

(defun agent-context--buffer-item (buffer)
  "Return an inline snapshot item for all of BUFFER."
  (with-current-buffer buffer
    (let ((item (agent-context--region-item buffer (point-min) (point-max))))
      (setf (agent-context-item-kind item) 'buffer
            (agent-context-item-label item) (buffer-name))
      item)))

(defconst agent-context--image-extensions
  '("png" "jpg" "jpeg" "gif" "webp" "bmp")
  "File extensions treated as attachable images.")

(defun agent-context--image-file-p (path)
  "Return non-nil when PATH names a recognized image type."
  (member (downcase (or (file-name-extension path) ""))
          agent-context--image-extensions))

(defun agent-context--assert-safe-path (path)
  "Signal a `user-error' when PATH must not be sent.  Return t."
  (ignore path)                         ; real checks arrive with the
  t)                                    ; safety layer

(defun agent-context--file-item (path &optional transport)
  "Return a context item for PATH.
TRANSPORT is `mention' (default) or `inline'.  Images become media
items; non-image binaries are rejected."
  (let ((path (expand-file-name path)))
    (unless (file-readable-p path)
      (user-error "agent-context: cannot read %s" path))
    (agent-context--assert-safe-path path)
    (cond
     ((agent-context--image-file-p path) (agent-context--media-item path))
     ((agent-context--binary-file-p path)
      (user-error "agent-context: %s looks binary; only images can be attached"
                  path))
     ((eq transport 'inline) (agent-context--inline-file-item path))
     (t (agent-context--mention-file-item path)))))

(defun agent-context--binary-file-p (path)
  "Return non-nil when PATH's first 8 KiB contain a NUL byte."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (insert-file-contents-literally path nil 0 8192)
    (goto-char (point-min))
    (search-forward "\0" nil t)))

(defun agent-context--inline-file-item (path)
  "Return an inline snapshot item for PATH."
  (let ((content (with-temp-buffer
                   (insert-file-contents path)
                   (buffer-string))))
    (when (> (string-bytes content) agent-context-max-file-bytes)
      (user-error "agent-context: %s exceeds `agent-context-max-file-bytes'"
                  path))
    (agent-context-item-create
     :id (agent-context--next-id) :kind 'file
     :label (agent-context--file-label path)
     :provenance (list :path path
                       :language (agent-context--language-for path)
                       :captured-at (float-time))
     :transport 'inline :content content
     :size (agent-context--exact-size content))))

(defun agent-context--file-label (path)
  "Return PATH's display label, showing the truename for symlinks.
An explicitly chosen symlink is followed, but what will actually be
read must be visible in the composer and previews."
  (let ((truename (ignore-errors (file-truename path))))
    (if (and truename (not (equal truename (expand-file-name path))))
        (format "%s → %s" (abbreviate-file-name path)
                (abbreviate-file-name truename))
      (abbreviate-file-name path))))

(defun agent-context--mention-file-item (path &optional root)
  "Return a deferred mention item for PATH.
ROOT, when non-nil, records the directory-expansion root so dispatch
can re-verify that PATH's truename still lies under it."
  (agent-context-item-create
   :id (agent-context--next-id) :kind 'file
   :label (agent-context--file-label path)
   :provenance (append (list :path path) (when root (list :root root)))
   :transport 'mention :content nil
   :size (agent-context--file-size path)))

(defun agent-context--media-item (path &optional temp root)
  "Return a media item for image PATH.
TEMP non-nil marks PATH as a composer-owned temp file.  ROOT records
the directory-expansion root, as in `agent-context--mention-file-item'."
  (agent-context--assert-safe-path path)
  (agent-context-item-create
   :id (agent-context--next-id) :kind 'image
   :label (agent-context--file-label path)
   :provenance (append (list :path path)
                       (when temp (list :temp-file t))
                       (when root (list :root root)))
   :transport 'media :content nil
   :size (agent-context--file-size path)))

(defun agent-context--language-for (path-or-mode)
  "Return a Markdown fence language for PATH-OR-MODE, or \"\"."
  (cond
   ((symbolp path-or-mode)
    (string-remove-suffix "-mode" (symbol-name path-or-mode)))
   ((stringp path-or-mode)
    (or (file-name-extension path-or-mode) ""))
   (t "")))
```

Also define (needed by `agent-context--inline-file-item` above) the size
defcustoms in this task, exactly:

```elisp
(defcustom agent-context-max-file-bytes 131072
  "Maximum size of a single file inlined as text, in bytes."
  :type 'natnum :group 'agent-context)

(defcustom agent-context-max-files 40
  "Maximum number of files one directory expansion may add."
  :type 'natnum :group 'agent-context)

(defcustom agent-context-warn-bytes 65536
  "Ask for confirmation before dispatching more textual bytes than this."
  :type 'natnum :group 'agent-context)

(defcustom agent-context-max-bytes 262144
  "Refuse to dispatch more textual bytes than this."
  :type 'natnum :group 'agent-context)
```

End the file with `(provide 'agent-context)` and the standard footer.

- [ ] **Step 5: Run tests to verify they pass**

Run: `make test` — all pass.

- [ ] **Step 6: Commit**

```bash
git add agent-context.el test/agent-context-test.el Makefile
git commit -m "agent-context: add item model and basic sources"
```

---

### Task 3: Safety layer and directory/project expansion

**Files:**
- Modify: `agent-context.el`
- Test: `test/agent-context-test.el`

**Interfaces:**
- Produces: `agent-context-secret-path-regexps`,
  `agent-context-exclude-regexps` (defcustoms);
  `agent-context--secret-path-p (path)`;
  `agent-context--assert-safe-path (path)` (replaces the Task 2 stub;
  signals on secret paths, message names the path only);
  `agent-context--directory-items (dir)` → `(ITEMS . REPORT-STRING)` where
  ITEMS are mention file items and REPORT-STRING summarizes skips;
  `agent-context--candidate-files (root)`.

- [ ] **Step 1: Write the failing tests**

```elisp
(ert-deftest agent-context-test-secret-paths-rejected-everywhere ()
  "Secret-looking paths are rejected; the error names the path only."
  (let ((file (expand-file-name "id_rsa" temporary-file-directory)))
    (with-temp-file file (insert "SECRETKEYMATERIAL"))
    (unwind-protect
        (dolist (transport '(mention inline))
          (let ((err (should-error (agent-context--file-item file transport)
                                   :type 'user-error)))
            (should (string-match-p "id_rsa" (cadr err)))
            (should-not (string-match-p "SECRETKEYMATERIAL" (cadr err)))))
      (delete-file file))))

(ert-deftest agent-context-test-symlink-to-secret-rejected ()
  "An innocently named symlink to a secret path is refused, and the
error names the truename without printing contents."
  (let* ((secret (expand-file-name "ctx-credential-store"
                                   temporary-file-directory))
         (link (expand-file-name "innocent.txt" temporary-file-directory)))
    (with-temp-file secret (insert "HUNTER2"))
    (make-symbolic-link secret link t)
    (unwind-protect
        (dolist (transport '(mention inline))
          (let ((err (should-error (agent-context--file-item link transport)
                                   :type 'user-error)))
            (should (string-match-p "ctx-credential-store" (cadr err)))
            (should-not (string-match-p "HUNTER2" (cadr err)))))
      (delete-file link)
      (delete-file secret))))

(ert-deftest agent-context-test-symlink-retargeted-after-add-refused ()
  "A symlink repointed at a secret between add and dispatch is caught
by the deferred re-check."
  (let* ((safe (make-temp-file "ctx-safe" nil ".txt" "ok"))
         (secret (expand-file-name "ctx-secret-key"
                                   temporary-file-directory))
         (link (expand-file-name "swap.txt" temporary-file-directory)))
    (with-temp-file secret (insert "HUNTER2"))
    (make-symbolic-link safe link t)
    (unwind-protect
        (progn
          ;; Safe at add time.
          (should (agent-context--file-item link 'mention))
          ;; Repointed afterwards: the same safety primitive that the
          ;; dispatch-time re-check calls must now refuse it.
          (delete-file link)
          (make-symbolic-link secret link t)
          (should-error (agent-context--assert-safe-path link)
                        :type 'user-error))
      (delete-file link)
      (delete-file secret)
      (delete-file safe))))

(ert-deftest agent-context-test-binary-file-rejected-inline-and-mention ()
  "A NUL-bearing non-image file is rejected for every transport."
  (let ((file (make-temp-file "ctx" nil ".bin")))
    (with-temp-file file
      (set-buffer-multibyte nil)
      (insert "ab\0cd"))
    (unwind-protect
        (progn
          (should-error (agent-context--file-item file 'inline)
                        :type 'user-error)
          (should-error (agent-context--file-item file 'mention)
                        :type 'user-error))
      (delete-file file))))

(ert-deftest agent-context-test-directory-expansion-limits-and-symlinks ()
  "Expansion honors the file limit, skips secrets, binaries, and
symlinks that escape the root, and reports what it skipped."
  (let* ((root (make-temp-file "ctx-dir" t))
         (outside (make-temp-file "ctx-outside" nil ".txt" "outside")))
    (unwind-protect
        (progn
          (dotimes (i 3)
            (with-temp-file (expand-file-name (format "f%d.txt" i) root)
              (insert (format "file %d" i))))
          (with-temp-file (expand-file-name ".env" root) (insert "K=v"))
          (with-temp-file (expand-file-name "blob.bin" root)
            (set-buffer-multibyte nil) (insert "x\0y"))
          ;; Named to sort before f0-f2 so the limit hits f2, not the
          ;; image (directory-files-recursively returns sorted paths).
          (with-temp-file (expand-file-name "a-shot.png" root)
            (insert "fake image"))
          (make-symbolic-link outside (expand-file-name "escape.txt" root))
          (let* ((agent-context-max-files 3)
                 (result (agent-context--directory-items root))
                 (items (car result))
                 (report (cdr result)))
            ;; Walk order: .env (secret), a-shot.png (media), blob.bin
            ;; (binary), escape.txt (symlink), f0 f1 (mentions), f2
            ;; (over the 3-item limit).
            (should (= (length items) 3))
            (should (= 1 (cl-count 'media items
                                   :key #'agent-context-item-transport)))
            (should (= 2 (cl-count 'mention items
                                   :key #'agent-context-item-transport)))
            ;; Every expansion item records the root for dispatch re-checks.
            (should (cl-every
                     (lambda (item)
                       (equal (plist-get (agent-context-item-provenance item)
                                         :root)
                              (file-truename (file-name-as-directory root))))
                     items))
            (should (string-match-p "1 secret" report))
            (should (string-match-p "1 binary" report))
            (should (string-match-p "1 symlink" report))
            (should (string-match-p "1 over the file limit" report))))
      (delete-directory root t)
      (delete-file outside))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test`
Expected: FAIL — secret path accepted; `agent-context--directory-items`
undefined.

- [ ] **Step 3: Implement**

```elisp
(defcustom agent-context-secret-path-regexps
  (list (rx "/.ssh/") (rx "/.aws/") (rx "/.gnupg/")
        (rx "/.password-store/")
        (rx "/" (or ".netrc" ".authinfo" ".authinfo.gpg") eos)
        (rx "/.env" (opt "." (+ (not "/"))) eos)
        (rx "id_rsa" (opt ".pub") eos)
        (rx "." (or "pem" "key") eos)
        (rx (or "credential" "secret")))
  "Path regexps whose matches must never be sent as context.
Applies to every transport: an @-mention makes the CLI read the file,
so mentions are gated exactly like inlining."
  :type '(repeat regexp) :group 'agent-context)

(defcustom agent-context-exclude-regexps
  (list (rx "/.git/") (rx "/node_modules/") (rx "/elpaca/") (rx "/elpa/")
        (rx "/.cache/") (rx "/build/") (rx "/dist/") (rx "/target/"))
  "Directory regexps excluded from non-project directory expansion.
Inside projects, `project-files' (VCS ignore rules) governs instead."
  :type '(repeat regexp) :group 'agent-context)

(defun agent-context--secret-path-p (path)
  "Return non-nil when PATH matches a secret-path regexp.
Both the chosen spelling and the truename are checked, so an
innocently named symlink to a secret file never slips through."
  (let ((spellings (delete-dups
                    (list (expand-file-name path)
                          (ignore-errors (file-truename path))))))
    (cl-some (lambda (spelling)
               (and spelling
                    (cl-some (lambda (re) (string-match-p re spelling))
                             agent-context-secret-path-regexps)))
             spellings)))

(defun agent-context--assert-safe-path (path)
  "Signal a `user-error' when PATH must not be sent.  Return t.
The message names the path (and its truename when they differ) only;
file contents are never read here."
  (when (agent-context--secret-path-p path)
    (let ((truename (ignore-errors (file-truename path))))
      (user-error
       "agent-context: refusing to send secret-looking path %s%s"
       (abbreviate-file-name path)
       (if (and truename (not (equal truename (expand-file-name path))))
           (format " (resolves to %s)" (abbreviate-file-name truename))
         ""))))
  t)
```

(Replace the Task 2 stub of `agent-context--assert-safe-path`.  Also make
`agent-context--mention-file-item` reject non-image binaries by moving the
binary check ahead of the transport dispatch in `agent-context--file-item`
— the Task 2 code already has that shape; verify it.)

```elisp
(defun agent-context--candidate-files (root)
  "Return candidate file paths under ROOT.
Inside a project, `project-files' provides the list (VCS-aware);
otherwise walk the tree, pruning `agent-context-exclude-regexps'."
  (if-let* ((project (project-current nil root)))
      (project-files project (list root))
    (directory-files-recursively
     root ".*" nil
     (lambda (dir)
       (not (cl-some (lambda (re) (string-match-p re (concat dir "/")))
                     agent-context-exclude-regexps))))))

(defun agent-context--directory-items (dir)
  "Expand DIR into mention file items and media items for images.
Return (ITEMS . REPORT) where REPORT is a human-readable summary of
skipped entries: secret paths, binaries, oversize files, symlinks that
escape DIR, and entries over `agent-context-max-files'.  Every produced
item records DIR's truename under provenance key `:root' so dispatch
can re-verify containment."
  (let* ((root (file-truename (file-name-as-directory dir)))
         (secret 0) (binary 0) (oversize 0) (symlink 0) (over 0)
         (images 0)
         items)
    (dolist (path (agent-context--candidate-files root))
      (let ((path (expand-file-name path)))
        (cond
         ((not (string-prefix-p root (file-truename path)))
          (cl-incf symlink))
         ((agent-context--secret-path-p path) (cl-incf secret))
         ((not (file-readable-p path)) (cl-incf binary))
         ((> (or (file-attribute-size (file-attributes path)) 0)
             agent-context-max-file-bytes)
          (cl-incf oversize))
         ((>= (length items) agent-context-max-files) (cl-incf over))
         ((agent-context--image-file-p path)
          ;; Recognized images are attachable media, not binary rejects.
          (cl-incf images)
          (push (agent-context--media-item path nil root) items))
         ((agent-context--binary-file-p path) (cl-incf binary))
         (t (push (agent-context--mention-file-item path root) items)))))
    (cons (nreverse items)
          (agent-context--expansion-report
           (length items) images secret binary oversize symlink over))))

(defun agent-context--expansion-report (added images secret binary
                                              oversize symlink over)
  "Return the expansion summary string for the given counts."
  (string-join
   (delq nil
         (list (format "added %d" added)
               (unless (zerop images) (format "%d image" images))
               (unless (zerop secret) (format "%d secret-path" secret))
               (unless (zerop binary) (format "%d binary" binary))
               (unless (zerop oversize) (format "%d oversize" oversize))
               (unless (zerop symlink) (format "%d symlink escape" symlink))
               (unless (zerop over)
                 (format "%d over the file limit" over))))
   ", "))
```

Note the test expects the substrings "1 secret", "1 binary", "1 symlink",
"1 over the file limit" — the report format above produces them.

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test` — all pass.

- [ ] **Step 5: Commit**

```bash
git add agent-context.el test/agent-context-test.el
git commit -m "agent-context: add safety layer and directory expansion"
```

---

### Task 4: Git, diagnostics, and buffer-content sources

**Files:**
- Modify: `agent-context.el`
- Test: `test/agent-context-test.el`

**Interfaces:**
- Produces: `agent-context--git-output (dir &rest args)`;
  `agent-context--diff-item (dir &optional staged)`;
  `agent-context--commit-items (dir revs)` (one item per rev, content from
  `git show REV`); `agent-context--read-commits (dir)` (interactive
  helper); `agent-context--diagnostics-item (buffer)`;
  `agent-context--buffer-content-item (buffer)` (kind `compilation` for
  compilation-derived buffers, else `buffer`).

- [ ] **Step 1: Write the failing tests**

```elisp
(defmacro agent-context-test--with-git (args-output &rest body)
  "Stub `process-file' for git.  ARGS-OUTPUT is an alist of
(ARGS-LIST . OUTPUT-STRING); unlisted calls fail."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'process-file)
              (lambda (_prog _in _dest _display &rest args)
                (if-let* ((entry (assoc args ,args-output)))
                    (progn (insert (cdr entry)) 0)
                  1))))
     ,@body))

(ert-deftest agent-context-test-diff-item-snapshots-git-output ()
  "A diff item snapshots git output with repo provenance."
  (agent-context-test--with-git
      '((("diff") . "diff --git a/f b/f\n+new\n")
        (("rev-parse" "--show-toplevel") . "/tmp/repo\n")
        (("rev-parse" "--short" "HEAD") . "abc1234\n"))
    (let ((item (agent-context--diff-item "/tmp/repo/")))
      (should (eq (agent-context-item-kind item) 'diff))
      (should (eq (agent-context-item-transport item) 'inline))
      (should (string-match-p "\\+new" (agent-context-item-content item)))
      (should (equal (plist-get (agent-context-item-provenance item) :repo)
                     "/tmp/repo"))
      ;; Working and staged diffs record the revision they were taken at.
      (should (equal (plist-get (agent-context-item-provenance item) :rev)
                     "abc1234")))))

(ert-deftest agent-context-test-empty-diff-notes-emptiness ()
  "An empty diff is added with an explicit note, not dropped."
  (agent-context-test--with-git
      '((("diff" "--cached") . "")
        (("rev-parse" "--show-toplevel") . "/tmp/repo\n")
        (("rev-parse" "--short" "HEAD") . "abc1234\n"))
    (let ((item (agent-context--diff-item "/tmp/repo/" t)))
      (should (equal (agent-context-item-note item) "empty diff"))
      (should (string-match-p "staged" (agent-context-item-label item))))))

(ert-deftest agent-context-test-diagnostics-item-uses-flymake ()
  "Diagnostics render one line per flymake diagnostic."
  (with-temp-buffer
    (rename-buffer "ctx-diag-test" t)
    (setq-local flymake-mode t)
    (cl-letf (((symbol-function 'flymake-diagnostics)
               (lambda (&rest _)
                 (list (flymake-make-diagnostic (current-buffer) 1 3
                                                :error "bad thing")))))
      (let ((item (agent-context--diagnostics-item (current-buffer))))
        (should (eq (agent-context-item-kind item) 'diagnostics))
        (should (string-match-p "bad thing"
                                (agent-context-item-content item)))
        (should (string-match-p ":error:"
                                (agent-context-item-content item)))))))

(ert-deftest agent-context-test-diagnostics-item-prefers-active-flycheck ()
  "When flycheck is active in the buffer, its errors are used."
  (with-temp-buffer
    (rename-buffer "ctx-flycheck-test" t)
    (setq-local flycheck-mode t)
    (cl-letf (((symbol-function 'flycheck-error-line) (lambda (_) 7))
              ((symbol-function 'flycheck-error-level) (lambda (_) 'warning))
              ((symbol-function 'flycheck-error-message)
               (lambda (_) "unused var")))
      (defvar flycheck-current-errors)
      (let ((flycheck-current-errors (list 'stub-error)))
        (let ((item (agent-context--diagnostics-item (current-buffer))))
          (should (string-match-p "7:warning: unused var"
                                  (agent-context-item-content item))))))))

(ert-deftest agent-context-test-buffer-content-item-detects-compilation ()
  "A compilation-derived buffer yields kind `compilation'."
  (with-temp-buffer
    (compilation-mode)
    (let ((inhibit-read-only t)) (insert "make: *** error 2"))
    (let ((item (agent-context--buffer-content-item (current-buffer))))
      (should (eq (agent-context-item-kind item) 'compilation))
      (should (string-match-p "error 2" (agent-context-item-content item))))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test` — FAIL, functions undefined.

- [ ] **Step 3: Implement**

```elisp
(defun agent-context--git-output (dir &rest args)
  "Run git ARGS in DIR and return stdout; `user-error' on failure."
  (with-temp-buffer
    (let ((default-directory (file-name-as-directory dir)))
      (unless (zerop (apply #'process-file "git" nil t nil args))
        (user-error "agent-context: git %s failed in %s"
                    (string-join args " ") (abbreviate-file-name dir))))
    (buffer-string)))

(defun agent-context--git-toplevel (dir)
  "Return DIR's repository toplevel."
  (string-trim (agent-context--git-output dir "rev-parse" "--show-toplevel")))

(defun agent-context--diff-item (dir &optional staged)
  "Return an inline snapshot item for DIR's diff.
STAGED non-nil takes the index diff instead of the working tree.  The
provenance records the repository toplevel and the current short HEAD
revision, so a stale snapshot is attributable."
  (let* ((content (apply #'agent-context--git-output dir
                         (if staged '("diff" "--cached") '("diff"))))
         (label (if staged "staged diff" "working-tree diff")))
    (agent-context-item-create
     :id (agent-context--next-id) :kind 'diff :label label
     :provenance (list :repo (agent-context--git-toplevel dir)
                       :rev (string-trim (agent-context--git-output
                                          dir "rev-parse" "--short" "HEAD"))
                       :staged (and staged t)
                       :language "diff"
                       :captured-at (float-time))
     :transport 'inline :content content
     :size (agent-context--exact-size content)
     :note (when (string-empty-p (string-trim content)) "empty diff"))))

(defun agent-context--commit-items (dir revs)
  "Return one inline item per commit rev in REVS, via git show in DIR."
  (mapcar
   (lambda (rev)
     (let ((content (agent-context--git-output dir "show" rev)))
       (agent-context-item-create
        :id (agent-context--next-id) :kind 'commit
        :label (format "commit %s" rev)
        :provenance (list :repo (agent-context--git-toplevel dir)
                          :rev rev :language "diff"
                          :captured-at (float-time))
        :transport 'inline :content content
        :size (agent-context--exact-size content))))
   revs))

(defun agent-context--read-commits (dir)
  "Read recent commit revs in DIR with completion; return rev strings."
  (let* ((lines (split-string
                 (agent-context--git-output dir "log" "--oneline" "-20")
                 "\n" t))
         (chosen (completing-read-multiple "Commits: " lines nil t)))
    (mapcar (lambda (line) (car (split-string line " "))) chosen)))

(declare-function flymake-diagnostics "flymake")
(declare-function flymake-diagnostic-beg "flymake")
(declare-function flymake-diagnostic-type "flymake")
(declare-function flymake-diagnostic-text "flymake")

(declare-function flycheck-error-line "flycheck")
(declare-function flycheck-error-level "flycheck")
(declare-function flycheck-error-message "flycheck")
(defvar flycheck-current-errors)

(defun agent-context--diagnostics-item (buffer)
  "Return an inline item for BUFFER's diagnostics.
Uses flycheck when it is active in BUFFER, flymake otherwise."
  (with-current-buffer buffer
    (unless (or (bound-and-true-p flycheck-mode)
                (bound-and-true-p flymake-mode))
      (user-error "agent-context: no flymake or flycheck diagnostics in %s"
                  (buffer-name)))
    (let* ((lines (if (bound-and-true-p flycheck-mode)
                      (mapcar #'agent-context--flycheck-line
                              flycheck-current-errors)
                    (require 'flymake)
                    (mapcar #'agent-context--diagnostic-line
                            (flymake-diagnostics))))
           (content (string-join lines "\n")))
      (agent-context-item-create
       :id (agent-context--next-id) :kind 'diagnostics
       :label (format "diagnostics: %s" (buffer-name))
       :provenance (list :buffer-name (buffer-name)
                         :path (buffer-file-name)
                         :captured-at (float-time))
       :transport 'inline :content content
       :size (agent-context--exact-size content)
       :note (when (null lines) "no diagnostics")))))

(defun agent-context--diagnostic-line (diag)
  "Render flymake DIAG as \"file:line:type: text\"."
  (format "%s:%d:%s: %s"
          (buffer-name) (line-number-at-pos (flymake-diagnostic-beg diag))
          (flymake-diagnostic-type diag) (flymake-diagnostic-text diag)))

(defun agent-context--flycheck-line (err)
  "Render flycheck ERR as \"buffer:line:level: message\"."
  (format "%s:%d:%s: %s"
          (buffer-name) (flycheck-error-line err)
          (flycheck-error-level err) (flycheck-error-message err)))

(defun agent-context--buffer-content-item (buffer)
  "Return an inline item for BUFFER's full contents.
Compilation-derived buffers get kind `compilation'."
  (with-current-buffer buffer
    (let ((item (agent-context--buffer-item buffer)))
      (when (derived-mode-p 'compilation-mode)
        (setf (agent-context-item-kind item) 'compilation))
      item)))
```

Note: `agent-context--diagnostic-line` runs inside BUFFER via the caller;
`line-number-at-pos` needs the diagnostic's buffer current — the
`with-current-buffer buffer` in `agent-context--diagnostics-item` covers
it.

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test` — all pass.

- [ ] **Step 5: Commit**

```bash
git add agent-context.el test/agent-context-test.el
git commit -m "agent-context: add git, diagnostics, and buffer sources"
```

---

### Task 5: URL source

**Files:**
- Modify: `agent-context.el`
- Test: `test/agent-context-test.el`

**Interfaces:**
- Produces: `agent-context-url-timeout` (default 10),
  `agent-context-url-max-bytes` (default 524288) defcustoms;
  `agent-context--fetch-url (url)` → plist
  `(:body STR :final-url STR :html BOOL)`, signaling `user-error` on
  network failure, HTTP ≥ 400, or oversize;
  `agent-context--url-item (url)`.

- [ ] **Step 1: Write the failing tests**

```elisp
(defmacro agent-context-test--with-url (status body final &rest test-body)
  "Stub `url-retrieve-synchronously' with STATUS, BODY, FINAL url.
A nil STATUS simulates a network failure (nil return).  Bind
`agent-context-test--url-content-type' around TEST-BODY to control the
response Content-Type (default text/plain)."
  (declare (indent 3))
  `(cl-letf (((symbol-function 'url-retrieve-synchronously)
              (lambda (&rest _)
                (when ,status
                  (let ((buf (generate-new-buffer " *ctx-url*")))
                    (with-current-buffer buf
                      (insert "HTTP/1.1 " (number-to-string ,status) " X\r\n"
                              "Content-Type: "
                              agent-context-test--url-content-type
                              "\r\n\r\n" ,body)
                      (goto-char (point-min))
                      (setq-local url-http-response-status ,status)
                      (setq-local url-http-end-of-headers
                                  (progn (search-forward "\r\n\r\n")
                                         (match-beginning 0)))
                      (setq-local url-http-target-url
                                  (url-generic-parse-url ,final)))
                    buf)))))
     ,@test-body))

(defvar agent-context-test--url-content-type "text/plain")

(ert-deftest agent-context-test-url-fetch-success-records-final-url ()
  "A fetched URL snapshots the body and both URLs."
  (agent-context-test--with-url 200 "hello body" "https://x.test/final"
    (let ((item (agent-context--url-item "https://x.test/start")))
      (should (eq (agent-context-item-kind item) 'url))
      (should (string-match-p "hello body" (agent-context-item-content item)))
      (should (equal (plist-get (agent-context-item-provenance item) :url)
                     "https://x.test/start"))
      (should (equal (plist-get (agent-context-item-provenance item)
                                :resolved-url)
                     "https://x.test/final")))))

(ert-deftest agent-context-test-url-http-error-is-refused ()
  "An HTTP error adds nothing and names the status."
  (agent-context-test--with-url 404 "not found" "https://x.test/a"
    (let ((err (should-error (agent-context--url-item "https://x.test/a")
                             :type 'user-error)))
      (should (string-match-p "404" (cadr err))))))

(ert-deftest agent-context-test-url-network-failure-distinct-from-empty ()
  "A network failure signals; a 200 empty body is added with a note."
  (agent-context-test--with-url nil "" "https://x.test/a"
    (should-error (agent-context--url-item "https://x.test/a")
                  :type 'user-error))
  (agent-context-test--with-url 200 "" "https://x.test/a"
    (let ((item (agent-context--url-item "https://x.test/a")))
      (should (equal (agent-context-item-note item) "empty body (0 bytes)"))
      (should (equal (agent-context-item-content item) "")))))

(ert-deftest agent-context-test-url-size-cap-refuses ()
  "A body over the byte cap is refused."
  (agent-context-test--with-url 200 (make-string 64 ?x) "https://x.test/a"
    (let ((agent-context-url-max-bytes 10))
      (should-error (agent-context--url-item "https://x.test/a")
                    :type 'user-error))))

(ert-deftest agent-context-test-url-html-decided-by-content-type ()
  "HTML conversion keys off Content-Type, not the body's first byte."
  ;; text/plain that merely starts with `<' is never transformed.
  (agent-context-test--with-url 200 "<not html, just text" "https://x.test/a"
    (let ((item (agent-context--url-item "https://x.test/a")))
      (should (equal (agent-context-item-content item)
                     "<not html, just text"))
      (should (null (agent-context-item-note item)))))
  ;; text/html is rendered to text when libxml is available.
  (skip-unless (libxml-available-p))
  (let ((agent-context-test--url-content-type "text/html"))
    (agent-context-test--with-url 200 "<p>hi <b>there</b></p>"
        "https://x.test/a"
      (let ((item (agent-context--url-item "https://x.test/a")))
        (should (string-match-p "hi there"
                                (agent-context-item-content item)))
        (should (equal (agent-context-item-note item)
                       "HTML rendered to text"))))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test` — FAIL, functions undefined.

- [ ] **Step 3: Implement**

```elisp
(defcustom agent-context-url-timeout 10
  "Seconds before a URL fetch is abandoned."
  :type 'natnum :group 'agent-context)

(defcustom agent-context-url-max-bytes 524288
  "Refuse URL bodies larger than this many bytes."
  :type 'natnum :group 'agent-context)

(defvar url-http-response-status)
(defvar url-http-end-of-headers)
(defvar url-http-target-url)

(defun agent-context--fetch-url (url)
  "Fetch URL synchronously.
Return (:body STR :final-url STR :html BOOL).  Signal a `user-error'
on network failure, HTTP status >= 400, or an oversize body, so a
failed fetch is never mistaken for an empty page."
  (require 'url)
  (let ((buffer (url-retrieve-synchronously url t nil
                                            agent-context-url-timeout)))
    (unless buffer
      (user-error "agent-context: fetching %s failed" url))
    (unwind-protect
        (with-current-buffer buffer
          (let ((status (bound-and-true-p url-http-response-status)))
            (when (or (null status) (>= status 400))
              (user-error "agent-context: %s returned HTTP %s" url
                          (or status "no response")))
            (let ((body (buffer-substring-no-properties
                         (agent-context--body-start) (point-max))))
              (when (> (string-bytes body) agent-context-url-max-bytes)
                (user-error
                 "agent-context: %s body exceeds `agent-context-url-max-bytes'"
                 url))
              (list :body body
                    :final-url (if (bound-and-true-p url-http-target-url)
                                   (url-recreate-url url-http-target-url)
                                 url)
                    :html (equal (agent-context--response-content-type)
                                 "text/html")))))
      (kill-buffer buffer))))

(defun agent-context--response-content-type ()
  "Return the lowercased media type of the response, or nil.
Reads the Content-Type header of the current url-retrieve buffer;
the body's first byte is deliberately not consulted."
  (save-excursion
    (goto-char (point-min))
    (when (re-search-forward "^Content-Type:[ \t]*\\([^;\r\n]+\\)"
                             url-http-end-of-headers t)
      (downcase (string-trim (match-string 1))))))

(defun agent-context--url-item (url)
  "Fetch URL and return an inline snapshot item for it."
  (let* ((fetched (agent-context--fetch-url url))
         (raw (plist-get fetched :body))
         (rendered (if (and (plist-get fetched :html) (libxml-available-p))
                       (agent-context--html-to-text raw)
                     raw))
         (transformed (not (eq rendered raw))))
    (agent-context-item-create
     :id (agent-context--next-id) :kind 'url :label url
     :provenance (list :url url
                       :resolved-url (plist-get fetched :final-url)
                       :fetched-at (float-time))
     :transport 'inline :content rendered
     :size (agent-context--exact-size rendered)
     :note (cond ((string-empty-p rendered) "empty body (0 bytes)")
                 (transformed "HTML rendered to text")))))

(defun agent-context--html-to-text (html)
  "Render HTML to plain text with shr."
  (require 'shr)
  (with-temp-buffer
    (insert html)
    (let ((dom (libxml-parse-html-region (point-min) (point-max))))
      (erase-buffer)
      (shr-insert-document dom)
      (buffer-substring-no-properties (point-min) (point-max)))))
```

`agent-context--body-start` makes the stub and real url.el buffers agree
regardless of whether `url-http-end-of-headers` points at the start of or
after the `\r\n\r\n` separator:

```elisp
(defun agent-context--body-start ()
  "Return the response body start in a url-retrieve buffer."
  (save-excursion
    (goto-char url-http-end-of-headers)
    (skip-chars-forward "\r\n")
    (point)))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test` — all pass.

- [ ] **Step 5: Commit**

```bash
git add agent-context.el test/agent-context-test.el
git commit -m "agent-context: add explicit URL fetching"
```

---

### Task 6: Captured-prompt source

**Files:**
- Modify: `agent-context.el`
- Test: `test/agent-context-test.el`

**Interfaces:**
- Consumes: `agent-capture--prompts (backend buffer)` and
  `agent-capture--delete-prompt (plist)` from `agent-capture.el` (same
  package; the cross-module private use follows the existing
  `agent.el`→`agent-capture` pattern via `declare-function`).
- Produces: `agent-context--capture-item (prompt)` where PROMPT is an
  agent-capture plist (`:file :title :created :text`); the item stores the
  full plist under provenance key `:capture-plist` so dispatch success can
  delete the entry; `agent-context--read-capture-prompt (backend buffer)`.

- [ ] **Step 1: Write the failing test**

```elisp
(ert-deftest agent-context-test-capture-item-carries-deletion-plist ()
  "A captured prompt becomes an inline item keeping its origin plist."
  (let* ((prompt (list :file "/tmp/cap.org" :title "Prompt 1"
                       :created "[2026-07-30]" :inserted nil
                       :text "do the thing"))
         (item (agent-context--capture-item prompt)))
    (should (eq (agent-context-item-kind item) 'capture))
    (should (equal (agent-context-item-content item) "do the thing"))
    (should (eq (plist-get (agent-context-item-provenance item)
                           :capture-plist)
                prompt))))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test` — FAIL, function undefined.

- [ ] **Step 3: Implement**

```elisp
(declare-function agent-capture--prompts "agent-capture"
                  (backend buffer &optional include-inserted))
(declare-function agent-capture--delete-prompt "agent-capture" (prompt))
(declare-function agent-capture--select-prompt "agent-capture" (prompts))

(defun agent-context--capture-item (prompt)
  "Return an inline item for agent-capture PROMPT plist."
  (let ((text (plist-get prompt :text)))
    (agent-context-item-create
     :id (agent-context--next-id) :kind 'capture
     :label (format "captured: %s" (plist-get prompt :title))
     :provenance (list :capture-plist prompt
                       :captured-at (float-time))
     :transport 'inline :content text
     :size (agent-context--exact-size text))))

(defun agent-context--read-capture-prompt (backend buffer)
  "Select one of BACKEND session BUFFER's captured prompts."
  (require 'agent-capture)
  (let ((prompts (agent-capture--prompts backend buffer)))
    (unless prompts
      (user-error "agent-context: no captured prompts for this session"))
    (agent-capture--select-prompt prompts)))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make test` — all pass.

- [ ] **Step 5: Commit**

```bash
git add agent-context.el test/agent-context-test.el
git commit -m "agent-context: add captured-prompt source"
```

---

### Task 7: Deterministic renderer

**Files:**
- Modify: `agent-context.el`
- Test: `test/agent-context-test.el`

**Interfaces:**
- Produces: `agent-context--render (instruction items tokenize)` → string.
  TOKENIZE is `(ITEM)` → token string for mention/media items; inline
  items never reach it.  Also `agent-context--fence-for (content)`,
  `agent-context--provenance-line (item)`.

- [ ] **Step 1: Write the failing tests**

```elisp
(defun agent-context-test--mk-inline (label content &optional prov lang)
  (agent-context-item-create
   :id "x" :kind 'region :label label
   :provenance (append prov (list :buffer-name "test" :lines '(1 1)
                                  :language (or lang "")
                                  :captured-at 0.0))
   :transport 'inline :content content
   :size (agent-context--exact-size content)))

(ert-deftest agent-context-test-render-orders-and-fences ()
  "Rendering keeps order, numbers items, and fences content."
  (let* ((items (list (agent-context-test--mk-inline "first" "aaa")
                      (agent-context-test--mk-inline "second" "bbb")))
         (msg (agent-context--render "Do X." items #'ignore)))
    (should (string-prefix-p "Do X." msg))
    (should (< (string-match "### Context 1: first" msg)
               (string-match "### Context 2: second" msg)))
    (should (string-match-p "```\naaa\n```" msg))))

(ert-deftest agent-context-test-render-extends-fences-past-backticks ()
  "Content containing backtick fences gets a longer fence."
  (let* ((content "x\n````\ny")
         (item (agent-context-test--mk-inline "tricky" content))
         (msg (agent-context--render "" (list item) #'ignore)))
    (should (string-match-p "^`````\n" msg))
    (should-not (string-match-p "^````x" msg))))

(ert-deftest agent-context-test-render-mention-uses-token-only ()
  "Mention items appear exactly once, as their token, never inlined."
  (let* ((mention (agent-context--mention-file-item "/tmp/whatever.el"))
         (msg (agent-context--render
               "Look."
               (list mention)
               (lambda (_item) "@/tmp/whatever.el "))))
    (should (string-match-p "@/tmp/whatever\\.el" msg))
    (should-not (string-match-p "### Context" msg))
    (should (= 1 (with-temp-buffer
                   (insert msg)
                   (count-matches "whatever\\.el" (point-min) (point-max)))))))

(ert-deftest agent-context-test-render-mixed-kinds-in-order ()
  "A mixed composition renders instruction, inline, and token in order."
  (let* ((inline (agent-context-test--mk-inline "diff" "-old\n+new" nil "diff"))
         (mention (agent-context--mention-file-item "/tmp/f.el"))
         (msg (agent-context--render "Fix it." (list inline mention)
                                     (lambda (_i) "@/tmp/f.el "))))
    (should (< (string-match "Fix it\\." msg)
               (string-match "### Context 1: diff" msg)))
    (should (< (string-match "\\+new" msg)
               (string-match "@/tmp/f\\.el" msg)))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test` — FAIL, `agent-context--render` undefined.

- [ ] **Step 3: Implement**

```elisp
(defun agent-context--fence-for (content)
  "Return a fence longer than any backtick run in CONTENT."
  (let ((longest 0) (start 0))
    (while (string-match "`+" content start)
      (setq longest (max longest (- (match-end 0) (match-beginning 0)))
            start (match-end 0)))
    (make-string (max 3 (1+ longest)) ?`)))

(defun agent-context--provenance-line (item)
  "Return the one-line provenance description for inline ITEM."
  (let* ((prov (agent-context-item-provenance item))
         (when (plist-get prov :captured-at))
         (stamp (format-time-string "%H:%M" when)))
    (pcase (agent-context-item-kind item)
      ('region (format "Source: %s lines %d-%d, snapshot taken %s"
                       (or (plist-get prov :path)
                           (plist-get prov :buffer-name))
                       (car (plist-get prov :lines))
                       (cadr (plist-get prov :lines)) stamp))
      ((or 'buffer 'compilation 'diagnostics)
       (format "Source: buffer %s, snapshot taken %s"
               (plist-get prov :buffer-name) stamp))
      ('file (format "Source: %s, snapshot taken %s"
                     (plist-get prov :path) stamp))
      ('diff (format "Source: git %s in %s at %s, snapshot taken %s"
                     (if (plist-get prov :staged) "diff --cached" "diff")
                     (plist-get prov :repo)
                     (or (plist-get prov :rev) "?") stamp))
      ('commit (format "Source: git show %s in %s"
                       (plist-get prov :rev) (plist-get prov :repo)))
      ('url (format "Source: %s, fetched %s, resolved to %s"
                    (plist-get prov :url) stamp
                    (plist-get prov :resolved-url)))
      ('capture (format "Source: captured prompt, %s" stamp))
      (_ (format "Source: %s" (agent-context-item-label item))))))

(defun agent-context--render-inline (n item)
  "Render inline ITEM as context block number N."
  (let* ((content (agent-context-item-content item))
         (fence (agent-context--fence-for content))
         (lang (or (plist-get (agent-context-item-provenance item)
                              :language)
                   "")))
    (format "### Context %d: %s\n%s\n%s%s\n%s\n%s"
            n (agent-context-item-label item)
            (agent-context--provenance-line item)
            fence lang content fence)))

(defun agent-context--render (instruction items tokenize)
  "Return the outgoing message for INSTRUCTION and ITEMS.
TOKENIZE is called with each mention/media item and returns its token
string; inline items render as provenance-labeled fenced blocks.  The
result is a pure function of its inputs."
  (let ((n 0)
        (parts (if (string-empty-p (string-trim instruction))
                   nil
                 (list (string-trim instruction)))))
    (dolist (item items)
      (push (if (eq (agent-context-item-transport item) 'inline)
                (agent-context--render-inline (cl-incf n) item)
              (string-trim-right (funcall tokenize item)))
            parts))
    (string-join (nreverse parts) "\n\n")))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test` — all pass.

- [ ] **Step 5: Commit**

```bash
git add agent-context.el test/agent-context-test.el
git commit -m "agent-context: add deterministic renderer"
```

---

### Task 8: Composer buffer UI

**Files:**
- Modify: `agent-context.el`
- Test: `test/agent-context-test.el`

**Interfaces:**
- Consumes: `agent--read-session-buffer`, `agent--detect-backend`,
  `agent-display-name`, `agent-backend-label`, `agent-session`,
  `agent-session-account` (core, same package).
- Produces: `agent-context-compose` (autoloaded command);
  `agent-context-mode`; `agent-context-buffer-name` (const,
  `"*Agent context*"`); `agent-context--refresh`;
  `agent-context--instruction` → string; item-line text property
  `agent-context-item`; commands `agent-context-add` (transient),
  `agent-context-add-region`, `agent-context-add-buffer`,
  `agent-context-add-file`, `agent-context-add-directory`,
  `agent-context-add-other-buffer`, `agent-context-add-diff`,
  `agent-context-add-staged-diff`, `agent-context-add-commits`,
  `agent-context-add-diagnostics`, `agent-context-add-compilation`,
  `agent-context-add-image`, `agent-context-add-clipboard-image`,
  `agent-context-add-url`, `agent-context-add-captured`,
  `agent-context-preview-item`, `agent-context-preview-message`,
  `agent-context-delete-item`, `agent-context-move-item-up`,
  `agent-context-move-item-down`, `agent-context-toggle-transport`,
  `agent-context-refresh-item`, `agent-context-retarget`,
  `agent-context-cancel`.  (`agent-context-dispatch` arrives in Task 9;
  bind it now with a stub that signals "not implemented".)

- [ ] **Step 1: Write the failing tests**

```elisp
(defmacro agent-context-test--with-composer (&rest body)
  "Open a composer for a stub target and run BODY in its buffer."
  `(let* ((target (generate-new-buffer " *ctx-target*"))
          (agent-context--current nil))
     (unwind-protect
         (progn
           (cl-letf (((symbol-function 'agent--read-session-buffer)
                      (lambda () target))
                     ((symbol-function 'agent--detect-backend)
                      (lambda (&optional buf)
                        (when (eq (or buf (current-buffer)) target) 'stub)))
                     ((symbol-function 'agent-display-name)
                      (lambda (&optional _) "stub-proj")))
             (agent-context-compose))
           (with-current-buffer agent-context-buffer-name ,@body))
       (when (get-buffer agent-context-buffer-name)
         (kill-buffer agent-context-buffer-name))
       (kill-buffer target))))

(ert-deftest agent-context-test-compose-creates-draft-and-buffer ()
  "Composing opens the draft buffer with a target header."
  (agent-context-test--with-composer
   (should agent-context--current)
   (should (derived-mode-p 'agent-context-mode))
   (should (derived-mode-p 'special-mode))
   (should (string-match-p "stub-proj"
                           (buffer-substring-no-properties
                            (point-min) (point-max))))))

(ert-deftest agent-context-test-field-types-item-lines-command ()
  "Letters self-insert in the instruction field but act on item lines."
  (agent-context-test--with-composer
   (agent-context--add-item (agent-context-test--mk-inline "x" "y"))
   (agent-context--refresh)
   ;; In the field: plain letters must reach self-insert despite the
   ;; special-mode parent map.
   (goto-char (agent-context--field-start))
   (should (eq (key-binding "g") #'self-insert-command))
   ;; On an item line: the item keymap wins.
   (agent-context--goto-item-line 1)
   (should (eq (key-binding "d") #'agent-context-delete-item))
   (should (eq (key-binding "q") #'quit-window))))

(ert-deftest agent-context-test-item-line-shows-transport-column ()
  "Item lines display the transport alongside kind, size, and notes."
  (agent-context-test--with-composer
   (agent-context--add-item (agent-context--mention-file-item "/tmp/f.el"))
   (agent-context--refresh)
   (agent-context--goto-item-line 1)
   (let ((line (buffer-substring-no-properties (point)
                                               (line-end-position))))
     (should (string-match-p "mention" line)))))

(ert-deftest agent-context-test-region-refresh-exact-and-rename-proof ()
  "Region refresh reproduces the exact partial-line region via its
markers, and survives a source-buffer rename."
  (agent-context-test--with-composer
   (let ((src (generate-new-buffer "ctx-region-refresh")))
     (unwind-protect
         (progn
           (with-current-buffer src (insert "alpha beta gamma"))
           ;; Partial-line region: "beta".
           (agent-context--add-item (agent-context--region-item src 7 11))
           ;; Unrelated edit before the region, then a rename.
           (with-current-buffer src
             (goto-char (point-min)) (insert "XX ")
             (rename-buffer "ctx-region-renamed" t)
             ;; Change the region content itself (between b and e).
             (goto-char 11) (insert "!"))
           (agent-context--refresh)
           (agent-context--goto-item-line 1)
           (agent-context-refresh-item)
           (let ((item (car (agent-context-draft-items
                             agent-context--current))))
             ;; Markers tracked both edits: still the same region,
             ;; now containing the mutation, not a whole line.
             (should (equal (agent-context-item-content item) "b!eta"))))
       (kill-buffer (or (get-buffer "ctx-region-renamed") src))))))

(ert-deftest agent-context-test-refresh-releases-replaced-markers ()
  "Replacing a region item on refresh releases the old item's markers."
  (agent-context-test--with-composer
   (let ((src (generate-new-buffer "ctx-release")))
     (unwind-protect
         (progn
           (with-current-buffer src (insert "abcdef"))
           (agent-context--add-item (agent-context--region-item src 2 4))
           (let ((old-marker (plist-get
                              (agent-context-item-provenance
                               (car (agent-context-draft-items
                                     agent-context--current)))
                              :beg-marker)))
             (agent-context--refresh)
             (agent-context--goto-item-line 1)
             (agent-context-refresh-item)
             (should (null (marker-position old-marker)))))
       (kill-buffer src)))))

(ert-deftest agent-context-test-refresh-reports-gone-source ()
  "Refreshing an item whose source buffer died errors; the item stays."
  (agent-context-test--with-composer
   (let ((src (generate-new-buffer "ctx-gone")))
     (with-current-buffer src (insert "text"))
     (agent-context--add-item (agent-context--buffer-item src))
     (kill-buffer src))
   (agent-context--refresh)
   (agent-context--goto-item-line 1)
   (should-error (agent-context-refresh-item) :type 'user-error)
   (should (= 1 (length (agent-context-draft-items
                         agent-context--current))))))

(ert-deftest agent-context-test-instruction-survives-refresh ()
  "Typed instruction text survives an item-list refresh."
  (agent-context-test--with-composer
   (goto-char (agent-context--field-start))
   ;; Plain `insert' never inherits text properties; real typing
   ;; (self-insert-command) inherits via stickiness, and
   ;; `insert-and-inherit' is its programmatic equivalent.
   (insert-and-inherit "please explain")
   (agent-context--add-item (agent-context-test--mk-inline "x" "y"))
   (agent-context--refresh)
   (should (equal (agent-context--instruction) "please explain"))
   ;; The field is bounded: a second refresh with a populated item
   ;; table must not leak table or footer text into the instruction.
   (agent-context--refresh)
   (should (equal (agent-context--instruction) "please explain"))
   (should (string-match-p "x .*1 B exact\\|x.*exact"
                           (buffer-substring-no-properties
                            (point-min) (point-max))))))

(ert-deftest agent-context-test-item-lines-carry-items-and-sizes ()
  "Item lines expose their struct and an exact/estimated size tag."
  (agent-context-test--with-composer
   (agent-context--add-item (agent-context-test--mk-inline "snap" "abc"))
   (agent-context--add-item (agent-context--mention-file-item "/tmp/f.el"))
   (agent-context--refresh)
   (let ((text (buffer-substring-no-properties (point-min) (point-max))))
     (should (string-match-p "exact" text))
     (should (string-match-p "read at send" text)))
   (goto-char (point-min))
   (let ((match (text-property-search-forward 'agent-context-item)))
     ;; Point now sits at the match END, where the property is absent;
     ;; read through the match object instead.
     (should match)
     (should (agent-context-item-p
              (get-text-property (prop-match-beginning match)
                                 'agent-context-item))))))

(ert-deftest agent-context-test-delete-and-reorder ()
  "Deleting and reordering items updates the draft order."
  (agent-context-test--with-composer
   (agent-context--add-item (agent-context-test--mk-inline "one" "1"))
   (agent-context--add-item (agent-context-test--mk-inline "two" "2"))
   (agent-context--add-item (agent-context-test--mk-inline "three" "3"))
   (agent-context--refresh)
   (agent-context--goto-item-line 2)     ; "two"
   (agent-context-move-item-up)
   (should (equal (mapcar #'agent-context-item-label
                          (agent-context-draft-items agent-context--current))
                  '("two" "one" "three")))
   (agent-context--goto-item-line 3)     ; now "three"
   (agent-context-delete-item)
   (should (equal (mapcar #'agent-context-item-label
                          (agent-context-draft-items agent-context--current))
                  '("two" "one")))))

(ert-deftest agent-context-test-toggle-transport-snapshots-file ()
  "Toggling a mention item to inline snapshots its content."
  (let ((file (make-temp-file "ctx" nil ".txt" "tog")))
    (unwind-protect
        (agent-context-test--with-composer
         (agent-context--add-item (agent-context--mention-file-item file))
         (agent-context--refresh)
         (agent-context--goto-item-line 1)
         (agent-context-toggle-transport)
         (let ((item (car (agent-context-draft-items
                           agent-context--current))))
           (should (eq (agent-context-item-transport item) 'inline))
           (should (equal (agent-context-item-content item) "tog"))))
      (delete-file file))))
```

Add the test helper used above:

```elisp
(defun agent-context--goto-item-line (n)
  "Move point to the start of the Nth item line in the composer buffer.
Each search leaves point after the matched run (which includes the
trailing newline), so the landing position must come from the match's
beginning, not from `beginning-of-line'."
  (goto-char (point-min))
  (let (match)
    (dotimes (_ n)
      (setq match (text-property-search-forward 'agent-context-item)))
    (unless match
      (user-error "No item %d" n))
    (goto-char (prop-match-beginning match))))
```

(This helper is production code — implement it in `agent-context.el`, not
in the test file; the reorder commands use the same property search.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test` — FAIL, `agent-context-compose` undefined.

- [ ] **Step 3: Implement the composer buffer**

```elisp
(defconst agent-context-buffer-name "*Agent context*"
  "Name of the single composition draft buffer.")

;; The editable instruction field is bounded by the text property
;; `agent-context-field', not by markers: an end marker would advance
;; through everything `agent-context--refresh' inserts at its position
;; (item table, footer), corrupting instruction extraction.  Text typed
;; in the field inherits the property from the preceding field character
;; (default rear-stickiness) or, in an empty field, from the following
;; protected terminator via `front-sticky'.

(defvar agent-context-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'agent-context-dispatch)
    (define-key map (kbd "C-c C-k") #'agent-context-cancel)
    (define-key map (kbd "M-<up>") #'agent-context-move-item-up)
    (define-key map (kbd "M-<down>") #'agent-context-move-item-down)
    map)
  "Keymap for `agent-context-mode'.")

(defvar agent-context--item-line-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'agent-context-preview-item)
    (define-key map (kbd "p") #'agent-context-preview-item)
    (define-key map (kbd "P") #'agent-context-preview-message)
    (define-key map (kbd "a") #'agent-context-add)
    (define-key map (kbd "d") #'agent-context-delete-item)
    (define-key map (kbd "t") #'agent-context-toggle-transport)
    (define-key map (kbd "r") #'agent-context-refresh-item)
    (define-key map (kbd "T") #'agent-context-retarget)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap active on read-only composer lines (a `keymap' text property).")

(defvar agent-context--field-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map global-map)
    (define-key map (kbd "C-c C-c") #'agent-context-dispatch)
    (define-key map (kbd "C-c C-k") #'agent-context-cancel)
    map)
  "Keymap for the editable instruction field.
Installed as a `keymap' text property over the field, parented to the
global map, so ordinary typing works even though the mode derives from
`special-mode' (whose mode map binds plain letters to commands).")

(define-derived-mode agent-context-mode special-mode "AgentCtx"
  "Major mode for the agent context composition draft.
Derives from `special-mode' for its conventions, but the buffer itself
is writable: everything except the instruction field is protected by
read-only text properties, the instruction field carries
`agent-context--field-map' so letters self-insert there, and the
protected lines carry `agent-context--item-line-map'."
  (setq buffer-read-only nil)
  (setq-local truncate-lines t))

;;;###autoload
(defun agent-context-compose ()
  "Open (or pop to) the context composition draft.
When invoked from a live session buffer, that session is the target;
otherwise the session picker chooses one."
  (interactive)
  (if (and agent-context--current
           (get-buffer agent-context-buffer-name))
      (pop-to-buffer agent-context-buffer-name)
    (let ((target (if (agent--detect-backend (current-buffer))
                      (current-buffer)
                    (agent--read-session-buffer))))
      (setq agent-context--current
            (agent-context-draft-create
             :target target :items nil
             :origin-buffer (current-buffer)
             :origin-directory default-directory))
      (agent-context--warn-undispatchable target)
      (with-current-buffer (get-buffer-create agent-context-buffer-name)
        (agent-context-mode)
        (add-hook 'kill-buffer-hook #'agent-context--on-kill nil t)
        (agent-context--refresh))
      (pop-to-buffer agent-context-buffer-name))))

(defun agent-context--target-line ()
  "Return the target description line."
  (let* ((draft agent-context--current)
         (target (agent-context-draft-target draft))
         (backend (and (buffer-live-p target)
                       (agent--detect-backend target)))
         (label (or (when-let* ((struct (and backend
                                             (agent-backend backend))))
                      (agent-backend-label struct))
                    (and backend (symbol-name backend))
                    "?"))
         (account (when-let* (((buffer-live-p target))
                              (session (agent-session target)))
                    (agent-session-account session))))
    (if (buffer-live-p target)
        (format "%s · %s%s" label (agent-display-name target)
                (if account (format " · %s" account) ""))
      "(target session is gone — press T to retarget)")))

(defun agent-context--size-string (size)
  "Render SIZE plist as a short human-readable tag."
  (format "%s %s"
          (file-size-human-readable (plist-get size :bytes))
          (if (plist-get size :exact) "exact" "est., read at send")))

(defun agent-context--item-line (n item)
  "Return the propertized composer line for ITEM at position N.
The line shows kind, transport, label, size (exact or estimated), and
any retained warning note."
  (propertize
   (format "%2d. %-12s %-8s %-36s %s%s\n"
           n (agent-context-item-kind item)
           (agent-context-item-transport item)
           (truncate-string-to-width (agent-context-item-label item) 36
                                     nil nil "…")
           (agent-context--size-string (agent-context-item-size item))
           (if-let* ((note (agent-context-item-note item)))
               (format "  [%s]" note)
             ""))
   'agent-context-item item))

(defun agent-context--totals-line (items)
  "Return the totals footer line for ITEMS."
  (let ((text 0) (mentions 0) (media 0))
    (dolist (item items)
      (pcase (agent-context-item-transport item)
        ('inline (cl-incf text (plist-get (agent-context-item-size item)
                                          :bytes)))
        ('mention (cl-incf mentions))
        ('media (cl-incf media))))
    (format "Total: %s textual (exact) · %d mention%s · %d attachment%s"
            (file-size-human-readable text)
            mentions (if (= mentions 1) "" "s")
            media (if (= media 1) "" "s"))))

(defun agent-context--refresh ()
  "Rebuild the composer buffer, preserving the instruction text."
  (let ((instr (or (ignore-errors (agent-context--instruction)) ""))
        (inhibit-read-only t)
        (items (agent-context-draft-items agent-context--current)))
    (erase-buffer)
    (insert (agent-context--protected
             (format "Target: %s   [T retarget]\n\nInstruction (type below):\n"
                     (agent-context--target-line))))
    ;; Field text carries the bounding property and the field keymap.
    (insert (propertize instr
                        'agent-context-field t
                        'keymap agent-context--field-map))
    ;; Protected terminator: it must itself CARRY the field property
    ;; and keymap (a character only front-propagates properties it
    ;; has), declared front-sticky so text typed into an empty field
    ;; inherits them.  Inheritance applies to `self-insert-command'
    ;; and `insert-and-inherit'; plain `insert' never inherits, so
    ;; programmatic insertions into the field must use the latter or
    ;; add the properties explicitly (as `agent-context-recompose'
    ;; does).  It is read-only, and extraction strips it: the
    ;; instruction is the field run minus read-only characters.
    (insert (propertize "\n"
                        'agent-context-field t
                        'read-only t 'rear-nonsticky t
                        'keymap agent-context--field-map
                        'front-sticky '(keymap agent-context-field)))
    (insert (agent-context--protected
             (concat "\nItems (dispatch order):\n"
                     (if items
                         (let ((n 0))
                           (mapconcat (lambda (item)
                                        (agent-context--item-line
                                         (cl-incf n) item))
                                      items ""))
                       "  (none — press a to add)\n")
                     "\n" (agent-context--totals-line items) "\n"
                     (mapconcat (lambda (notice) (concat "! " notice "\n"))
                                (agent-context-draft-notices
                                 agent-context--current)
                                "")
                     "\n"
                     "a add · p preview · P message preview · d delete · "
                     "t toggle · r refresh · M-↑/↓ move\n"
                     "C-c C-c send · C-c C-k cancel · q bury\n")))
    (goto-char (agent-context--field-end))))

(defun agent-context--field-bounds ()
  "Return (START . END) of the instruction field run, or signal."
  (save-excursion
    (goto-char (point-min))
    (let ((match (text-property-search-forward 'agent-context-field)))
      (unless match
        (error "agent-context: no instruction field in %s" (buffer-name)))
      (cons (prop-match-beginning match) (prop-match-end match)))))

(defun agent-context--field-start ()
  "Return the start of the editable instruction field."
  (car (agent-context--field-bounds)))

(defun agent-context--field-end ()
  "Return the position just before the field's read-only terminator."
  (let ((bounds (agent-context--field-bounds)))
    ;; The terminator is the read-only tail of the field run.
    (let ((end (cdr bounds)))
      (while (and (> end (car bounds))
                  (get-text-property (1- end) 'read-only))
        (setq end (1- end)))
      end)))

(defun agent-context--protected (string)
  "Return STRING propertized read-only with the item-line keymap.
`rear-nonsticky' keeps text typed at the instruction-field start from
inheriting the read-only property; `front-sticky' is deliberately
absent so typing at the field end stays editable too."
  (propertize string
              'read-only t 'rear-nonsticky t
              'keymap agent-context--item-line-map))

(defun agent-context--instruction ()
  "Return the instruction text currently in the composer.
The field is located by its text property, and its read-only
terminator is excluded, so item-table and footer text can never leak
into the instruction."
  (with-current-buffer agent-context-buffer-name
    (string-trim (buffer-substring-no-properties
                  (agent-context--field-start)
                  (agent-context--field-end)))))
```

Item commands (all `interactive`, all ending in
`(agent-context--refresh)` where they change the draft):

```elisp
(defun agent-context--item-at-point ()
  "Return the item on the current composer line, or signal."
  (or (get-text-property (line-beginning-position) 'agent-context-item)
      (get-text-property (point) 'agent-context-item)
      (user-error "No context item on this line")))

(defun agent-context--item-index (item)
  "Return ITEM's position in the draft."
  (cl-position item (agent-context-draft-items agent-context--current)))

(defun agent-context-delete-item ()
  "Remove the item at point from the draft.
Deletes any composer-owned temp file backing it."
  (interactive)
  (let ((item (agent-context--item-at-point)))
    (agent-context--delete-item-temp item)
    (agent-context--release-item item)
    (setf (agent-context-draft-items agent-context--current)
          (delq item (agent-context-draft-items agent-context--current)))
    (agent-context--refresh)))

(defun agent-context--delete-item-temp (item)
  "Delete ITEM's composer-owned temp file, if any."
  (when-let* ((prov (agent-context-item-provenance item))
              ((plist-get prov :temp-file))
              (path (plist-get prov :path)))
    (when (file-exists-p path)
      (ignore-errors (delete-file path)))))

(defun agent-context--move-item (offset)
  "Move the item at point by OFFSET within the draft."
  (let* ((item (agent-context--item-at-point))
         (items (agent-context-draft-items agent-context--current))
         (index (agent-context--item-index item))
         (new (+ index offset)))
    (when (and (>= new 0) (< new (length items)))
      (let ((without (delq item (copy-sequence items))))
        (setf (agent-context-draft-items agent-context--current)
              (append (seq-take without new) (list item)
                      (seq-drop without new))))
      (agent-context--refresh)
      (agent-context--goto-item-line (1+ new)))))

(defun agent-context-move-item-up ()
  "Move the item at point one position earlier."
  (interactive)
  (agent-context--move-item -1))

(defun agent-context-move-item-down ()
  "Move the item at point one position later."
  (interactive)
  (agent-context--move-item 1))

(defun agent-context--transport-supported-p (transport path)
  "Return non-nil when TRANSPORT works for PATH on the draft's target.
Consults the pure token slot; a nil token or a missing slot means the
transport is unsupported for that session right now."
  (let* ((target (agent-context-draft-target agent-context--current))
         (backend (and (buffer-live-p target)
                       (agent--detect-backend target)))
         (struct (and backend (agent-backend backend)))
         (fn (and struct
                  (pcase transport
                    ('mention (agent-backend-file-reference-token struct))
                    ('media (agent-backend-media-token struct))))))
    (and fn (funcall fn path target) t)))

(defun agent-context--gate-new-item (item)
  "Return ITEM adjusted to the target's capabilities, or signal.
A mention item whose transport is unsupported degrades to an inline
snapshot with a message (never silently); an unsupported media item is
an honest error."
  (pcase (agent-context-item-transport item)
    ('mention
     (let ((path (plist-get (agent-context-item-provenance item) :path)))
       (if (agent-context--transport-supported-p 'mention path)
           item
         (message "agent-context: target lacks file mentions; inlining %s"
                  (agent-context-item-label item))
         (agent-context--file-item path 'inline))))
    ('media
     (let ((path (plist-get (agent-context-item-provenance item) :path)))
       (unless (agent-context--transport-supported-p 'media path)
         (user-error
          "agent-context: the target session does not support image items"))
       item))
    (_ item)))

(defun agent-context-toggle-transport ()
  "Toggle the file item at point between mention and inline.
Toggling to mention is refused when the target does not support it."
  (interactive)
  (let* ((item (agent-context--item-at-point))
         (path (plist-get (agent-context-item-provenance item) :path)))
    (unless (and (eq (agent-context-item-kind item) 'file) path)
      (user-error "Only file items toggle between mention and inline"))
    (let ((target-transport
           (if (eq (agent-context-item-transport item) 'mention)
               'inline 'mention)))
      (when (and (eq target-transport 'mention)
                 (not (agent-context--transport-supported-p 'mention path)))
        (user-error
         "agent-context: the target session does not support file mentions"))
      (let ((replacement (agent-context--file-item path target-transport))
            (items (agent-context-draft-items agent-context--current)))
        (setcar (nthcdr (agent-context--item-index item) items)
                replacement)))
    (agent-context--refresh)))

(defun agent-context-refresh-item ()
  "Re-resolve the snapshot item at point from its provenance.
Every snapshot kind has a resolver; an item whose source is gone
reports that and stays in the draft unchanged."
  (interactive)
  (let* ((item (agent-context--item-at-point))
         (prov (agent-context-item-provenance item))
         (replacement
          (pcase (agent-context-item-kind item)
            ('diff (agent-context--diff-item
                    (plist-get prov :repo) (plist-get prov :staged)))
            ('commit (car (agent-context--commit-items
                           (plist-get prov :repo)
                           (list (plist-get prov :rev)))))
            ('region (agent-context--refresh-region prov))
            ((or 'buffer 'compilation)
             (agent-context--buffer-content-item
              (agent-context--live-source-buffer prov)))
            ('diagnostics
             (agent-context--diagnostics-item
              (agent-context--live-source-buffer prov)))
            ('file                       ; inline snapshot of a file
             (agent-context--inline-file-item (plist-get prov :path)))
            ('capture (agent-context--refresh-capture prov))
            ('url (when (yes-or-no-p "Re-fetch URL? ")
                    (agent-context--url-item (plist-get prov :url))))
            (_ (user-error "This item kind cannot be refreshed")))))
    (when replacement
      (agent-context--release-item item)
      (setcar (nthcdr (agent-context--item-index item)
                      (agent-context-draft-items agent-context--current))
              replacement)
      (agent-context--refresh))))

(defun agent-context--live-source-buffer (prov)
  "Return PROV's source buffer, or signal when it is gone.
Prefers the stored buffer object (rename-proof); falls back to the
recorded name for provenance kinds that never stored the object."
  (let ((buf (or (let ((stored (plist-get prov :buffer)))
                   (and (buffer-live-p stored) stored))
                 (get-buffer (plist-get prov :buffer-name)))))
    (unless (buffer-live-p buf)
      (user-error "Source buffer %s is gone" (plist-get prov :buffer-name)))
    buf))

(defun agent-context--refresh-region (prov)
  "Re-read PROV's exact marker-bounded region from its source buffer.
Markers survive edits and buffer renames, so an unchanged source
reproduces the original — possibly partial-line — region exactly.
Signals honestly when the buffer or the markers are gone."
  (let ((buf (plist-get prov :buffer))
        (beg (plist-get prov :beg-marker))
        (end (plist-get prov :end-marker)))
    (unless (buffer-live-p buf)
      (user-error "Source buffer %s is gone"
                  (plist-get prov :buffer-name)))
    (unless (and (marker-position beg) (marker-position end))
      (user-error "The region's markers were released; delete and re-add"))
    (agent-context--region-item buf (marker-position beg)
                                (marker-position end))))

(defun agent-context--refresh-capture (prov)
  "Re-read PROV's capture entry from its Org file."
  (require 'agent-capture)
  (let* ((old (plist-get prov :capture-plist))
         (prompts (agent-capture--read-prompts (plist-get old :file) t))
         (match (cl-find-if
                 (lambda (p)
                   (and (equal (plist-get p :title) (plist-get old :title))
                        (equal (plist-get p :created)
                               (plist-get old :created))))
                 prompts)))
    (unless match
      (user-error "Captured prompt %S is gone from its file"
                  (plist-get old :title)))
    (agent-context--capture-item match)))

(declare-function agent-capture--read-prompts "agent-capture"
                  (file &optional include-inserted))

(defun agent-context--warn-undispatchable (target)
  "Message when TARGET's backend registers no `:submit-literal'.
Composing is still allowed (preview, copy), but dispatch will refuse."
  (let* ((backend (agent--detect-backend target))
         (struct (and backend (agent-backend backend))))
    (unless (and struct (agent-backend-submit-literal struct))
      (message
       "agent-context: %s cannot be dispatched to yet (no literal submission); draft will be preview-only"
       (agent-display-name target)))))

(defun agent-context-retarget ()
  "Choose a different target session for the draft.
Mention and media items the new target cannot take are marked with an
`unsupported by target' note; dispatch re-gates them authoritatively."
  (interactive)
  (setf (agent-context-draft-target agent-context--current)
        (agent--read-session-buffer))
  (agent-context--warn-undispatchable
   (agent-context-draft-target agent-context--current))
  (dolist (item (agent-context-draft-items agent-context--current))
    (let ((transport (agent-context-item-transport item))
          (path (plist-get (agent-context-item-provenance item) :path)))
      (when (memq transport '(mention media))
        (setf (agent-context-item-note item)
              (unless (agent-context--transport-supported-p transport path)
                "unsupported by target")))))
  (agent-context--refresh))

(defun agent-context-preview-item ()
  "Show the exact content of the item at point.
Deferred items are re-validated (readability, secret paths including
truename, type class) BEFORE their file is read, then show the content
as of now, clearly titled."
  (interactive)
  (let* ((item (agent-context--item-at-point))
         (deferred (not (eq (agent-context-item-transport item) 'inline)))
         (path (plist-get (agent-context-item-provenance item) :path))
         (buf (get-buffer-create "*Agent context preview*")))
    (when deferred
      (unless (and path (file-readable-p path))
        (user-error "agent-context: %s is no longer readable"
                    (or path (agent-context-item-label item))))
      (agent-context--assert-safe-path path))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "%s — %s\n\n" (agent-context-item-label item)
                        (if deferred
                            "as of now; re-read by the CLI at send"
                          "exact snapshot to be sent")))
        (insert (if deferred
                    (if (agent-context--image-file-p (or path ""))
                        (format "(image file: %s)" path)
                      (with-temp-buffer
                        (insert-file-contents path)
                        (buffer-string)))
                  (agent-context-item-content item))))
      (special-mode)
      (goto-char (point-min)))
    (pop-to-buffer buf)))

(defun agent-context-preview-message ()
  "Show the fully rendered outgoing message.
Uses the pure token slots only, so previewing never attaches anything."
  (interactive)
  (let* ((draft agent-context--current)
         (target (agent-context-draft-target draft))
         (msg (agent-context--render
               (agent-context--instruction)
               (agent-context-draft-items draft)
               (lambda (item) (agent-context--token-for item target))))
         (buf (get-buffer-create "*Agent context preview*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert msg))
      (special-mode)
      (goto-char (point-min)))
    (pop-to-buffer buf)))

(defun agent-context-cancel ()
  "Discard the draft after confirmation, cleaning owned temp files."
  (interactive)
  (when (yes-or-no-p "Discard this context draft? ")
    (kill-buffer agent-context-buffer-name)))

(defun agent-context--on-kill ()
  "Clean up when the composer buffer dies without a successful dispatch."
  (when agent-context--current
    (dolist (item (agent-context-draft-items agent-context--current))
      (agent-context--delete-item-temp item)
      (agent-context--release-item item))
    (setq agent-context--current nil)))
```

`agent-context--token-for` is defined in Task 9; for this task add a
forward stub so `P` works once dispatch lands:

```elisp
(defun agent-context--token-for (item _target)
  "Placeholder until dispatch lands; returns a plain path token."
  (format "@%s " (plist-get (agent-context-item-provenance item) :path)))

(defun agent-context-dispatch ()
  "Dispatch the draft (implemented in the dispatch task)."
  (interactive)
  (user-error "Dispatch not implemented yet"))
```

Add-source commands and the transient:

```elisp
(transient-define-prefix agent-context-add ()
  "Add a context source to the draft."
  [["Editor"
    ("r" "region (origin buffer)" agent-context-add-region)
    ("b" "origin buffer" agent-context-add-buffer)
    ("o" "other buffer" agent-context-add-other-buffer)
    ("x" "diagnostics" agent-context-add-diagnostics)
    ("m" "compilation" agent-context-add-compilation)]
   ["Files"
    ("f" "file" agent-context-add-file)
    ("D" "directory/project" agent-context-add-directory)
    ("i" "image file" agent-context-add-image)
    ("y" "clipboard image" agent-context-add-clipboard-image)]
   ["Git and net"
    ("g" "working-tree diff" agent-context-add-diff)
    ("G" "staged diff" agent-context-add-staged-diff)
    ("l" "commits" agent-context-add-commits)
    ("u" "URL" agent-context-add-url)
    ("c" "captured prompt" agent-context-add-captured)]])

(defun agent-context--origin ()
  "Return the draft's origin buffer, erroring when it is gone."
  (let ((buf (agent-context-draft-origin-buffer agent-context--current)))
    (unless (buffer-live-p buf)
      (user-error "The originating buffer is gone"))
    buf))

;;;###autoload
(defun agent-context-add-region ()
  "Add the active region of the buffer this command is invoked in.
From the composer buffer itself (the add transient), the draft's
originating buffer supplies the region.  Callable from any buffer:
starts a draft when none exists."
  (interactive)
  (let ((source (if (eq (current-buffer)
                        (get-buffer agent-context-buffer-name))
                    (agent-context--origin)
                  (current-buffer))))
    (unless agent-context--current
      (agent-context-compose))
    (with-current-buffer source
      (unless (use-region-p)
        (user-error "No active region in %s" (buffer-name)))
      (agent-context--add-item
       (agent-context--region-item source (region-beginning) (region-end))))
    (with-current-buffer agent-context-buffer-name
      (agent-context--refresh))))

(defun agent-context-add-buffer ()
  "Add the origin buffer's full contents to the draft."
  (interactive)
  (agent-context--add-item (agent-context--buffer-item
                            (agent-context--origin)))
  (agent-context--refresh))

(defun agent-context-add-other-buffer (buffer)
  "Add BUFFER's contents to the draft."
  (interactive (list (read-buffer "Buffer: " nil t)))
  (agent-context--add-item
   (agent-context--buffer-content-item (get-buffer buffer)))
  (agent-context--refresh))

(defun agent-context-add-file (path)
  "Add one or more files at PATH to the draft.
PATH may contain wildcards, so a single prompt can add several files.
Each defaults to the native mention transport when the target supports
it; otherwise it inlines with a message (capability-gated at add
time)."
  (interactive "FContext file(s), wildcards allowed: ")
  (let ((paths (or (file-expand-wildcards (expand-file-name path))
                   (user-error "agent-context: no file matches %s" path))))
    (dolist (file paths)
      (agent-context--add-item
       (agent-context--gate-new-item (agent-context--file-item file)))))
  (agent-context--refresh))

(defun agent-context-add-directory (dir)
  "Expand DIR into mention/media items, reporting skips.
Each produced item passes the same capability gate as a single add."
  (interactive "DContext directory: ")
  (pcase-let ((`(,items . ,report) (agent-context--directory-items dir)))
    (dolist (item items)
      (agent-context--add-item (agent-context--gate-new-item item)))
    ;; Retain the skip report where the preview shows it, not only in
    ;; the transient echo area.
    (setf (agent-context-draft-notices agent-context--current)
          (append (agent-context-draft-notices agent-context--current)
                  (list (format "%s: %s" (abbreviate-file-name dir)
                                report))))
    (agent-context--refresh)
    (message "agent-context: %s" report)))

(defun agent-context--origin-directory ()
  "Return the directory git sources operate in."
  (agent-context-draft-origin-directory agent-context--current))

(defun agent-context-add-diff ()
  "Add the working-tree diff of the originating directory."
  (interactive)
  (agent-context--add-item
   (agent-context--diff-item (agent-context--origin-directory)))
  (agent-context--refresh))

(defun agent-context-add-staged-diff ()
  "Add the staged diff of the originating directory."
  (interactive)
  (agent-context--add-item
   (agent-context--diff-item (agent-context--origin-directory) t))
  (agent-context--refresh))

(defun agent-context-add-commits ()
  "Add selected recent commits from the originating directory."
  (interactive)
  (let ((dir (agent-context--origin-directory)))
    (dolist (item (agent-context--commit-items
                   dir (agent-context--read-commits dir)))
      (agent-context--add-item item)))
  (agent-context--refresh))

(defun agent-context-add-diagnostics (buffer)
  "Add BUFFER's diagnostics to the draft."
  (interactive (list (read-buffer "Diagnostics buffer: "
                                  (agent-context-draft-origin-buffer
                                   agent-context--current)
                                  t)))
  (agent-context--add-item
   (agent-context--diagnostics-item (get-buffer buffer)))
  (agent-context--refresh))

(defun agent-context-add-compilation ()
  "Add a compilation buffer's contents to the draft."
  (interactive)
  (let ((candidates (cl-remove-if-not
                     (lambda (buf)
                       (with-current-buffer buf
                         (derived-mode-p 'compilation-mode)))
                     (buffer-list))))
    (unless candidates (user-error "No compilation buffers"))
    (agent-context--add-item
     (agent-context--buffer-content-item
      (get-buffer (completing-read "Compilation buffer: "
                                   (mapcar #'buffer-name candidates)
                                   nil t)))))
  (agent-context--refresh))

(defun agent-context-add-image (path)
  "Add the image file at PATH as a native attachment.
Refused with an honest error when the target cannot take images."
  (interactive "fImage file: ")
  (unless (agent-context--image-file-p path)
    (user-error "agent-context: %s is not a recognized image type" path))
  (agent-context--add-item
   (agent-context--gate-new-item (agent-context--media-item path)))
  (agent-context--refresh))

(defvar agent-context--temp-directory nil)

(defun agent-context--temp-directory ()
  "Return (creating) the composer's private temp directory."
  (unless (and agent-context--temp-directory
               (file-directory-p agent-context--temp-directory))
    (setq agent-context--temp-directory
          (make-temp-file "agent-context-" t)))
  agent-context--temp-directory)

(defun agent-context-add-clipboard-image ()
  "Write the clipboard image to a private temp file and attach it.
The file is composer-owned: deleted when its item is removed or the
draft is cancelled, kept after a successful dispatch (the CLI may read
it asynchronously)."
  (interactive)
  (let ((data (or (gui-get-selection 'CLIPBOARD 'image/png)
                  (user-error "No image on the clipboard"))))
    (let* ((path (make-temp-file
                  (expand-file-name "clip-" (agent-context--temp-directory))
                  nil ".png"))
           (coding-system-for-write 'binary))
      (with-temp-file path (insert data))
      (set-file-modes path #o600)
      (agent-context--add-item
       (agent-context--gate-new-item (agent-context--media-item path t)))))
  (agent-context--refresh))

(defun agent-context-add-url (url)
  "Fetch URL explicitly and add its content."
  (interactive "sURL: ")
  (agent-context--add-item (agent-context--url-item url))
  (agent-context--refresh))

(defun agent-context-add-captured ()
  "Add one of the target session's captured prompts."
  (interactive)
  (let* ((target (agent-context-draft-target agent-context--current))
         (backend (agent--detect-backend target)))
    (agent-context--add-item
     (agent-context--capture-item
      (agent-context--read-capture-prompt backend target))))
  (agent-context--refresh))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test` — all pass.

- [ ] **Step 5: Commit**

```bash
git add agent-context.el test/agent-context-test.el
git commit -m "agent-context: add the composer buffer UI"
```

---

### Task 9: Dispatch pipeline

**Files:**
- Modify: `agent-context.el` (replace the Task 8 dispatch/token stubs)
- Test: `test/agent-context-test.el`

**Interfaces:**
- Consumes: the `:submit-literal`/`:pending-input-p` slots (Task 1),
  `agent-session-event` (`submit-failed`),
  `agent-session-display-state`, `agent--detect-backend`,
  `agent-backend`, the five Task 1 slots; `agent-capture--delete-prompt`
  (Task 6); `agent-context-item-copy` (Task 2).
- Produces: `agent-context-dispatch` (replacing the Task 8 stub);
  `agent-context--token-for (item target)` → TOKEN string or honest
  `user-error` (pure; replaces the Task 8 stub);
  `agent-context--attach (item target)` → UNDO or nil;
  `agent-context--run-undos (undos)`; `agent-context--recheck-deferred
  (items target)`; `agent-context--final-readiness-check (target)`;
  `agent-context--submit-literal-fn (target)` (slot lookup with honest
  refusal); `agent-context--check-pending-input (target)`;
  `agent-context--finish (draft instruction target)` (never signals;
  disarms the draft first);
  `agent-context--detached-copies (items)`; `agent-context-recompose`
  (autoloaded); `agent-context--last` populated on success.

Transaction contract implemented here (mirrors the Global Constraints):

1. Validation, deferred re-checks, and the size gate run first and may
   signal freely — nothing has been attached yet.
2. `agent-context--final-readiness-check` and the `:pending-input-p`
   isolation check run immediately before the attach phase;
   `:ready-to-submit-p` returning `busy` refuses, and anything but a
   verifiably clean `:pending-input-p` — pending input, foreign
   attachments, or `unknown` — refuses.  Between these checks, the
   attach loop, and the `:submit-literal` call there are no Elisp
   yields (the app-server submitter is a synchronous JSON-RPC write),
   so the gate cannot be invalidated by asynchronous events.
3. The attach loop plus the single `:submit-literal` call form the
   guarded region: any `error` **or `quit`** there runs every collected
   undo independently, emits `submit-failed` at the live target so the
   session is retryable, and preserves the draft.  Dispatch never goes
   through `agent-submit`: literal submission (no slash/shell command
   parsing) is part of the slot's contract, and a backend without the
   slot is refused honestly.
4. The commit boundary is `:submit-literal` returning.  The FIRST
   post-submit action is disarming the draft (`agent-context--current`
   set nil); only then do detached-copy creation, capture deletion, and
   buffer kill run, each isolated — any of them failing warns but can
   never restore the draft, run undos, or permit a resend.

- [ ] **Step 1: Write the failing tests**

```elisp
(defmacro agent-context-test--with-dispatch-env (state &rest body)
  "Set up a stub backend and composer whose target reports STATE.
Binds in BODY's scope: SUBMITTED (list of submitted strings), ATTACHED
and UNDONE (counters), READY (settable symbol consulted by the
`:ready-to-submit-p' probe, initially `ready'), and MENTION-FILE (a
real readable temp file for deferred items — dispatch re-validation
requires real files)."
  (declare (indent 1))
  `(let* ((agent-backends nil)
          (submitted nil) (attached 0) (undone 0) (ready 'ready)
          (mention-file (make-temp-file "ctx-dispatch" nil ".el" ";; x\n"))
          (target (generate-new-buffer " *ctx-target*")))
     (ignore attached undone ready mention-file)
     (agent-register-backend
      'stub
      :buffer-p (lambda (buf) (eq buf target))
      :find-all-buffers (lambda () (list target))
      :start-session #'ignore
      :label "Stub"
      :submit-literal (lambda (text _buf) (push text submitted))
      :pending-input-p (lambda (_buf) nil)
      :file-reference-token (lambda (path _buf) (format "@%s " path))
      :media-token (lambda (path _buf) (format "(img %s)" path))
      :attach-file-reference
      (lambda (_path _buf)
        (cl-incf attached)
        (lambda () (cl-incf undone)))
      :attach-media
      (lambda (_path _buf)
        (cl-incf attached)
        (lambda () (cl-incf undone)))
      :ready-to-submit-p (lambda (_buf) ready))
     (let ((agent-context--current
            (agent-context-draft-create
             :target target :items nil
             :origin-buffer (current-buffer)
             :origin-directory default-directory)))
       (with-current-buffer target
         (setq-local agent--session-state ,state))
       (unwind-protect
           (cl-letf (((symbol-function 'agent-context--instruction)
                      (lambda () "do it"))
                     ((symbol-function 'agent-context--finish-buffer)
                      #'ignore))
             ,@body)
         (kill-buffer target)
         (when (file-exists-p mention-file)
           (delete-file mention-file))))))

(ert-deftest agent-context-test-dispatch-refuses-busy-target ()
  "A busy target is refused and the draft survives."
  (agent-context-test--with-dispatch-env 'busy
    (agent-context--add-item (agent-context-test--mk-inline "x" "y"))
    (should-error (agent-context-dispatch) :type 'user-error)
    (should (null submitted))
    (should agent-context--current)
    (should (= 1 (length (agent-context-draft-items
                          agent-context--current))))))

(ert-deftest agent-context-test-dispatch-readiness-probe-blocks-submit ()
  "Regression: a target whose backend probe says busy is refused even
while its display state says waiting — dispatch must never reach a
backend that would queue or steer the submission."
  (agent-context-test--with-dispatch-env 'awaiting-input
    (setq ready 'busy)                  ; e.g. pending turn/start
    (agent-context--add-item
     (agent-context--mention-file-item mention-file))
    (should-error (agent-context-dispatch) :type 'user-error)
    (should (null submitted))
    (should (= attached 0))             ; refused BEFORE any attachment
    (should agent-context--current)))

(ert-deftest agent-context-test-dispatch-unknown-state-needs-confirm ()
  "Unknown state dispatches only after explicit confirmation."
  (agent-context-test--with-dispatch-env 'unknown
    (agent-context--add-item (agent-context-test--mk-inline "x" "y"))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) nil)))
      (should-error (agent-context-dispatch) :type 'user-error)
      (should (null submitted)))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) t)))
      (agent-context-dispatch)
      (should (= 1 (length submitted))))))

(ert-deftest agent-context-test-dispatch-submits-once-and-finishes ()
  "A successful dispatch submits one rendered message and records it."
  (agent-context-test--with-dispatch-env 'awaiting-input
    (agent-context--add-item (agent-context-test--mk-inline "snap" "abc"))
    (agent-context--add-item
     (agent-context--mention-file-item mention-file))
    (agent-context-dispatch)
    (should (= 1 (length submitted)))
    (should (string-match-p "do it" (car submitted)))
    (should (string-match-p "abc" (car submitted)))
    (should (string-match-p (regexp-quote mention-file) (car submitted)))
    (should (null agent-context--current))
    (should (plist-get agent-context--last :items))))

(ert-deftest agent-context-test-dispatch-failure-rolls-back-and-retries ()
  "A synchronously failing `:submit-literal' undoes attachments, rolls
the target's state back so it is not stuck busy, and a retry through
the same registered slot then succeeds."
  (agent-context-test--with-dispatch-env 'awaiting-input
    (agent-context--add-item
     (agent-context--mention-file-item mention-file))
    (let ((fail t))
      ;; Fail through the REGISTERED slot, emitting the submit event
      ;; mid-way exactly as backend submission hooks do.
      (setf (agent-backend-submit-literal (agent-backend 'stub))
            (lambda (text buf)
              (agent-session-event buf 'submit)
              (if fail (error "boom") (push text submitted))))
      (agent-context-dispatch)          ; must not signal
      (should agent-context--current)
      (should (= attached 1))
      (should (= undone 1))
      ;; The submit event marked the target busy; the rollback event
      ;; must have restored it, or retry would be refused forever.
      (should-not (eq (agent-session-display-state
                       (agent-context-draft-target
                        agent-context--current))
                      'busy))
      (setq fail nil)
      (agent-context-dispatch)
      (should (= 1 (length submitted)))
      (should (null agent-context--current)))))

(ert-deftest agent-context-test-dispatch-refuses-without-submit-literal ()
  "A backend without `:submit-literal' is refused honestly."
  (agent-context-test--with-dispatch-env 'awaiting-input
    (setf (agent-backend-submit-literal (agent-backend 'stub)) nil)
    (agent-context--add-item (agent-context-test--mk-inline "x" "y"))
    (should-error (agent-context-dispatch) :type 'user-error)
    (should (null submitted))
    (should (= attached 0))
    (should agent-context--current)))

(ert-deftest agent-context-test-dispatch-pending-input-always-refuses ()
  "Both pending input and uninspectable transports refuse dispatch."
  (agent-context-test--with-dispatch-env 'awaiting-input
    (agent-context--add-item (agent-context-test--mk-inline "x" "y"))
    ;; Verifiably pending: refuse before any attachment.
    (setf (agent-backend-pending-input-p (agent-backend 'stub))
          (lambda (_buf) "half-typed prompt"))
    (should-error (agent-context-dispatch) :type 'user-error)
    (should (null submitted))
    ;; Unverifiable: refuse too — a blind append violates isolation.
    (setf (agent-backend-pending-input-p (agent-backend 'stub))
          (lambda (_buf) 'unknown))
    (should-error (agent-context-dispatch) :type 'user-error)
    (should (null submitted))
    (should (= attached 0))))

(ert-deftest agent-context-test-dispatch-quit-treated-as-failure ()
  "C-g during submission runs undos and preserves the draft."
  (agent-context-test--with-dispatch-env 'awaiting-input
    (agent-context--add-item
     (agent-context--mention-file-item mention-file))
    (setf (agent-backend-submit-literal (agent-backend 'stub))
          (lambda (_text _buf) (signal 'quit nil)))
    (agent-context-dispatch)            ; must not re-signal quit
    (should agent-context--current)
    (should (= undone 1))))

(ert-deftest agent-context-test-dispatch-undos-run-independently ()
  "Every undo closure runs even when an earlier one fails."
  (agent-context-test--with-dispatch-env 'awaiting-input
    (let ((second-ran nil) (calls 0))
      (setf (agent-backend-attach-file-reference (agent-backend 'stub))
            (lambda (_path _buf)
              (cl-incf calls)
              (if (= calls 1)
                  (lambda () (error "undo one broke"))
                (lambda () (setq second-ran t)))))
      (agent-context--add-item
       (agent-context--mention-file-item mention-file))
      (agent-context--add-item
       (agent-context--mention-file-item mention-file))
      (setf (agent-backend-submit-literal (agent-backend 'stub))
            (lambda (_text _buf) (error "boom")))
      (agent-context-dispatch)
      (should second-ran)
      (should agent-context--current))))

(ert-deftest agent-context-test-dispatch-post-submit-cleanup-isolated ()
  "A cleanup failure after a successful submit cannot cause a resend."
  (agent-context-test--with-dispatch-env 'awaiting-input
    (require 'agent-capture)
    (let ((prompt (list :file "/tmp/cap.org" :title "P" :created "c"
                        :text "captured text")))
      (cl-letf (((symbol-function 'agent-capture--delete-prompt)
                 (lambda (_p) (error "capture file locked"))))
        (agent-context--add-item (agent-context--capture-item prompt))
        (agent-context-dispatch)))      ; must not signal
    ;; Sent exactly once; draft gone; no undo ran; retry impossible.
    (should (= 1 (length submitted)))
    (should (null agent-context--current))
    (should (= undone 0))
    (should-error (agent-context-dispatch) :type 'user-error)
    (should (= 1 (length submitted)))))

(ert-deftest agent-context-test-dispatch-items-only-draft ()
  "A draft with items but no instruction dispatches; the message may
legitimately begin with a mention token."
  (agent-context-test--with-dispatch-env 'awaiting-input
    (cl-letf (((symbol-function 'agent-context--instruction)
               (lambda () "")))
      (agent-context--add-item
       (agent-context--mention-file-item mention-file))
      (agent-context-dispatch)
      (should (= 1 (length submitted)))
      (should (string-prefix-p "@" (car submitted))))))

(ert-deftest agent-context-test-dispatch-dead-target-keeps-draft ()
  "A dead target aborts before submitting; the draft is intact."
  (agent-context-test--with-dispatch-env 'awaiting-input
    (agent-context--add-item (agent-context-test--mk-inline "x" "y"))
    (kill-buffer (agent-context-draft-target agent-context--current))
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (_) nil)))
      (should-error (agent-context-dispatch) :type 'user-error))
    (should agent-context--current)))

(ert-deftest agent-context-test-dispatch-hard-size-limit-refuses ()
  "Rendered text over the hard byte limit is refused."
  (agent-context-test--with-dispatch-env 'awaiting-input
    (agent-context--add-item
     (agent-context-test--mk-inline "big" (make-string 64 ?x)))
    (let ((agent-context-max-bytes 10))
      (should-error (agent-context-dispatch) :type 'user-error)
      (should (null submitted)))))

(ert-deftest agent-context-test-dispatch-warn-gate-asks-first ()
  "Above the warn threshold, refusal cancels and consent sends."
  (agent-context-test--with-dispatch-env 'awaiting-input
    (agent-context--add-item
     (agent-context-test--mk-inline "biggish" (make-string 64 ?x)))
    (let ((agent-context-warn-bytes 10))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) nil)))
        (should-error (agent-context-dispatch) :type 'user-error)
        (should (null submitted)))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_) t)))
        (agent-context-dispatch)
        (should (= 1 (length submitted)))))))

(ert-deftest agent-context-test-dispatch-media-unsupported-honest-error ()
  "A media item whose token slot reports unsupported errors without loss."
  (agent-context-test--with-dispatch-env 'awaiting-input
    (setf (agent-backend-media-token (agent-backend 'stub))
          (lambda (_path _buf) nil))    ; unsupported for this buffer
    (let ((image (make-temp-file "ctx" nil ".png" "fake")))
      (unwind-protect
          (progn
            (agent-context--add-item (agent-context--media-item image))
            (should-error (agent-context-dispatch) :type 'user-error)
            (should (null submitted))
            (should (= 1 (length (agent-context-draft-items
                                  agent-context--current)))))
        (delete-file image)))))

(ert-deftest agent-context-test-dispatch-rechecks-mutated-deferred-file ()
  "A mention file replaced by binary content is refused at dispatch."
  (agent-context-test--with-dispatch-env 'awaiting-input
    (agent-context--add-item
     (agent-context--mention-file-item mention-file))
    (with-temp-file mention-file
      (set-buffer-multibyte nil)
      (insert "now\0binary"))
    (should-error (agent-context-dispatch) :type 'user-error)
    (should (null submitted))
    (should agent-context--current)))

(ert-deftest agent-context-test-dispatch-deletes-capture-on-success-only ()
  "Capture entries are removed exactly on success."
  (agent-context-test--with-dispatch-env 'awaiting-input
    (require 'agent-capture)            ; load BEFORE stubbing, so the
    (let ((deleted nil)                 ; later `require' in --finish
          (prompt (list :file "/tmp/cap.org" :title "P" :created "c"
                        :text "captured text")))
      (cl-letf (((symbol-function 'agent-capture--delete-prompt)
                 (lambda (p) (push p deleted))))
        (agent-context--add-item (agent-context--capture-item prompt))
        (let ((good (agent-backend-submit-literal (agent-backend 'stub))))
          (setf (agent-backend-submit-literal (agent-backend 'stub))
                (lambda (text buf)
                  (agent-session-event buf 'submit)
                  (error "boom") (ignore text)))
          (agent-context-dispatch)
          (should (null deleted))
          (setf (agent-backend-submit-literal (agent-backend 'stub)) good))
        (agent-context-dispatch)
        (should (equal deleted (list prompt)))))))

(ert-deftest agent-context-test-dispatch-copy-failure-cannot-resend ()
  "Fault injection at detached-copy creation: the draft is already
disarmed, so the failure warns but can never cause a resend."
  (agent-context-test--with-dispatch-env 'awaiting-input
    (agent-context--add-item (agent-context-test--mk-inline "x" "y"))
    (cl-letf (((symbol-function 'agent-context--detached-copies)
               (lambda (_items) (error "copy exploded"))))
      (agent-context-dispatch))         ; must not signal
    (should (= 1 (length submitted)))
    (should (null agent-context--current))
    (should (null agent-context--last))
    (should (= undone 0))
    (should-error (agent-context-dispatch) :type 'user-error)
    (should (= 1 (length submitted)))))

(ert-deftest agent-context-test-detached-copies-share-no-markers ()
  "Retained copies carry no marker objects; cancelling a recomposed
draft therefore cannot invalidate `agent-context--last'."
  (agent-context-test--with-dispatch-env 'awaiting-input
    (let ((src (generate-new-buffer "ctx-markers")))
      (unwind-protect
          (progn
            (with-current-buffer src (insert "some region text"))
            (agent-context--add-item (agent-context--region-item src 6 12))
            (agent-context-dispatch)
            (let ((kept (car (plist-get agent-context--last :items))))
              (should (null (plist-get (agent-context-item-provenance kept)
                                       :beg-marker)))
              (should (null (plist-get (agent-context-item-provenance kept)
                                       :end-marker)))))
        (kill-buffer src)))))

(ert-deftest agent-context-test-last-items-are-detached-copies ()
  "`agent-context--last' holds deep copies with temp ownership dropped."
  (agent-context-test--with-dispatch-env 'awaiting-input
    (let ((image (make-temp-file "ctx" nil ".png" "fake")))
      (unwind-protect
          (let ((item (agent-context--media-item image t)))
            (agent-context--add-item item)
            (agent-context-dispatch)
            (let ((kept (car (plist-get agent-context--last :items))))
              (should-not (eq kept item))
              ;; Ownership dropped: a recomposed draft must never delete
              ;; a file the dispatched message may still be read from.
              (should-not (plist-get (agent-context-item-provenance kept)
                                     :temp-file))
              ;; Mutating the kept copy cannot touch the original.
              (setf (agent-context-item-label kept) "mutated")
              (should-not (equal (agent-context-item-label item)
                                 "mutated"))))
        (delete-file image)))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test` — FAIL ("Dispatch not implemented yet").

- [ ] **Step 3: Implement**

Replace the Task 8 stubs:

```elisp
(defun agent-context--token-for (item target)
  "Return ITEM's token string for TARGET, or signal an honest error.
Pure: consults only the token slots, so previews and size gates can
call it freely.  A missing slot means the backend never supports the
transport; a nil token means this particular session cannot take it —
neither is ever silently downgraded."
  (let* ((backend (agent--detect-backend target))
         (struct (and backend (agent-backend backend)))
         (path (plist-get (agent-context-item-provenance item) :path))
         (media (eq (agent-context-item-transport item) 'media))
         (fn (and struct (if media
                             (agent-backend-media-token struct)
                           (agent-backend-file-reference-token struct)))))
    (unless fn
      (user-error "agent-context: %s does not support %s items"
                  (or (and struct (agent-backend-label struct)) backend)
                  (if media "image" "file-mention")))
    (or (funcall fn path target)
        (user-error
         "agent-context: %s items are unsupported for this session%s"
         (if media "image" "file-mention")
         (if media "" "; toggle the item to inline instead")))))

(defun agent-context--attach (item target)
  "Perform ITEM's out-of-band attachment for TARGET.
Return an undo closure, or nil when the token is the whole mechanism."
  (let* ((struct (agent-backend (agent--detect-backend target)))
         (path (plist-get (agent-context-item-provenance item) :path))
         (fn (if (eq (agent-context-item-transport item) 'media)
                 (agent-backend-attach-media struct)
               (agent-backend-attach-file-reference struct))))
    (when fn (funcall fn path target))))

(defun agent-context--run-undos (undos)
  "Run every undo closure in UNDOS, isolating failures.
One failing undo must not prevent the others from running."
  (dolist (undo undos)
    (condition-case undo-err
        (funcall undo)
      ((error quit)
       (display-warning
        'agent-context
        (format "attachment undo failed: %s"
                (error-message-string undo-err))
        :warning)))))

(defun agent-context--validated-target ()
  "Return the draft's target buffer, or signal with the draft intact."
  (let ((target (agent-context-draft-target agent-context--current)))
    (unless (and (buffer-live-p target) (agent--detect-backend target))
      (if (y-or-n-p "Target session is gone.  Choose another? ")
          (progn (agent-context-retarget)
                 (agent-context-draft-target agent-context--current))
        (user-error "agent-context: no live target; draft preserved")))
    (agent-context-draft-target agent-context--current)))

(defun agent-context--check-target-ready (target)
  "Enforce the display-state busy policy for TARGET."
  (pcase (agent-session-display-state target)
    ('busy
     (user-error
      "agent-context: %s is busy; dispatch requires an idle session"
      (agent-display-name target)))
    ('unknown
     (unless (yes-or-no-p
              (format "State of %s is unknown — send anyway? "
                      (agent-display-name target)))
       (user-error "agent-context: dispatch cancelled")))
    (_ t)))

(defun agent-context--final-readiness-check (target)
  "Authoritative last-moment gate before attachment and submission.
Consults the backend's `:ready-to-submit-p' probe; `busy' refuses.
On Codex app-server this covers states the display never shows —
pending `turn/start', queued input, reasoning-held submissions — where
submitting would queue or steer instead of starting a fresh turn."
  (when-let* ((backend (agent--detect-backend target))
              (struct (agent-backend backend))
              (fn (agent-backend-ready-to-submit-p struct)))
    (when (eq (funcall fn target) 'busy)
      (user-error
       "agent-context: %s is not ready for a new turn; try again when idle"
       (agent-display-name target)))))

(defun agent-context--recheck-deferred (items target)
  "Re-apply every safety and capability check to deferred ITEMS.
Covers readability, secret paths, type class (media must still be an
image, a mention must not have become binary), symlink containment for
expansion-produced items, and — via the token lookup — transport
support on the (possibly retargeted) TARGET."
  (dolist (item items)
    (unless (eq (agent-context-item-transport item) 'inline)
      (let* ((prov (agent-context-item-provenance item))
             (path (plist-get prov :path))
             (media (eq (agent-context-item-transport item) 'media)))
        (unless (and path (file-readable-p path))
          (user-error "agent-context: %s is no longer readable"
                      (or path (agent-context-item-label item))))
        (agent-context--assert-safe-path path)
        (if media
            (unless (agent-context--image-file-p path)
              (user-error "agent-context: %s is no longer an image" path))
          (when (agent-context--binary-file-p path)
            (user-error "agent-context: %s became binary" path)))
        (when-let* ((root (plist-get prov :root)))
          (unless (string-prefix-p root (file-truename path))
            (user-error "agent-context: %s now resolves outside %s"
                        path (abbreviate-file-name root))))
        (agent-context--token-for item target)))))

(defun agent-context--size-gate (text)
  "Apply the warn/refuse byte gates to the rendered TEXT."
  (let ((bytes (string-bytes text)))
    (when (> bytes agent-context-max-bytes)
      (user-error
       "agent-context: %s exceeds `agent-context-max-bytes' (%s); refusing"
       (file-size-human-readable bytes)
       (file-size-human-readable agent-context-max-bytes)))
    (when (and (> bytes agent-context-warn-bytes)
               (not (yes-or-no-p
                     (format "Send %s of textual context? "
                             (file-size-human-readable bytes)))))
      (user-error "agent-context: dispatch cancelled"))))

(defun agent-context-dispatch ()
  "Validate, render, and submit the draft exactly once.
Pre-submit failures (including quit) leave the draft intact, run every
undo closure, and roll the target's state back with `submit-failed'.
The commit boundary is the `:submit-literal' call returning: after it,
the draft is disarmed first and no failure restores it or runs undos."
  (interactive)
  (unless agent-context--current
    (user-error "No context draft"))
  (let* ((draft agent-context--current)
         (items (agent-context-draft-items draft))
         (instruction (agent-context--instruction))
         (target (agent-context--validated-target)))
    (when (and (string-empty-p instruction) (null items))
      (user-error "agent-context: nothing to send"))
    ;; Capability first: an undispatchable transport should say so,
    ;; not fail a later prompt-verification check confusingly.
    (agent-context--submit-literal-fn target)
    (agent-context--check-target-ready target)
    (agent-context--recheck-deferred items target)
    ;; Tokens are pure and deterministic, so this render is byte-equal
    ;; to the submitted message; gating it is truthful.
    (let ((message-text
           (agent-context--render
            instruction items
            (lambda (item) (agent-context--token-for item target)))))
      (agent-context--size-gate message-text)
      ;; Authoritative readiness and isolation, then attach, then one
      ;; literal submit.  No Elisp yields separate the checks from the
      ;; attach loop.
      (agent-context--final-readiness-check target)
      (agent-context--check-pending-input target)
      (let ((submit-fn (agent-context--submit-literal-fn target))
            undos sent)
        (condition-case err
            (progn
              (dolist (item items)
                (unless (eq (agent-context-item-transport item) 'inline)
                  (when-let* ((undo (agent-context--attach item target)))
                    (push undo undos))))
              (funcall submit-fn message-text target)
              (setq sent t))
          ((error quit)
           (agent-context--run-undos undos)
           (when (buffer-live-p target)
             (agent-session-event target 'submit-failed))
           (message "agent-context: dispatch failed (%s); draft preserved"
                    (if (eq (car-safe err) 'quit) "quit"
                      (error-message-string err)))))
        (when sent
          (agent-context--finish draft instruction target))))))

(defun agent-context--submit-literal-fn (target)
  "Return TARGET's `:submit-literal' function, or refuse honestly.
The composer never falls back to `agent-submit': without the literal
contract a message could be parsed as a slash or shell command or be
concatenated with unsent prompt text."
  (let* ((backend (agent--detect-backend target))
         (struct (and backend (agent-backend backend)))
         (fn (and struct (agent-backend-submit-literal struct))))
    (or fn
        (user-error
         "agent-context: %s provides no literal submission; cannot dispatch"
         (or (and struct (agent-backend-label struct)) backend)))))

(defun agent-context--check-pending-input (target)
  "Refuse dispatch unless TARGET is verifiably clean.
nil from the probe means verifiably clean; anything else refuses:
a truthy value names what is pending (dispatching would swallow or
ride it), and `unknown' — including a backend without the probe —
means the transport cannot be inspected, so a literal, isolated
submission cannot be guaranteed."
  (let* ((backend (agent--detect-backend target))
         (struct (and backend (agent-backend backend)))
         (fn (and struct (agent-backend-pending-input-p struct)))
         (state (if fn (funcall fn target) 'unknown)))
    (cond
     ((null state) t)
     ((eq state 'unknown)
      (user-error
       "agent-context: cannot verify %s's prompt is empty; %s"
       (agent-display-name target)
       "this transport does not support literal dispatch"))
     (t (user-error
         "agent-context: %s has unsent input or pending attachments; %s"
         (agent-display-name target)
         "clear or submit them first")))))

(defun agent-context--finish (draft instruction target)
  "Commit success bookkeeping for DRAFT; never signals.
Runs only after `:submit-literal' returned: the message is sent, so no
failure here may restore the draft, run undos, or permit a resend.
The VERY FIRST action disarms the live draft; everything that can
signal — detached-copy creation included — runs after it, isolated."
  (setq agent-context--current nil)
  (condition-case copy-err
      (setq agent-context--last
            (list :instruction instruction
                  :items (agent-context--detached-copies
                          (agent-context-draft-items draft))))
    ((error quit)
     (setq agent-context--last nil)
     (display-warning
      'agent-context
      (format "sent, but retaining the composition failed: %s"
              (error-message-string copy-err))
      :warning)))
  ;; The retained copies share no markers, so the originals' can be
  ;; released now instead of lingering in source buffers.
  (dolist (item (agent-context-draft-items draft))
    (agent-context--release-item item))
  (dolist (item (agent-context-draft-items draft))
    (when-let* (((eq (agent-context-item-kind item) 'capture))
                (plist (plist-get (agent-context-item-provenance item)
                                  :capture-plist)))
      (condition-case cap-err
          (progn (require 'agent-capture)
                 (agent-capture--delete-prompt plist))
        ((error quit)
         (display-warning
          'agent-context
          (format "sent, but removing the capture entry failed: %s"
                  (error-message-string cap-err))
          :warning)))))
  (condition-case nil (agent-context--finish-buffer) ((error quit) nil))
  (message "agent-context: dispatched to %s (%d items)"
           (if (buffer-live-p target) (agent-display-name target) "session")
           (length (agent-context-draft-items draft))))

(defun agent-context--detached-copies (items)
  "Return deep copies of ITEMS with per-buffer resources dropped.
`agent-context--last' must not share structure with live drafts: a
recomposed draft must never delete a media file the dispatched message
may still be read from (`:temp-file' dropped), and it must not share
marker objects whose release elsewhere would invalidate the retained
copy (`:beg-marker'/`:end-marker' dropped — refreshing a recomposed
region item reports the markers as released, honestly)."
  (mapcar (lambda (item)
            (let* ((copy (agent-context-item-copy item))
                   (prov (copy-sequence
                          (agent-context-item-provenance copy))))
              (dolist (key '(:temp-file :beg-marker :end-marker))
                (setq prov (plist-put prov key nil)))
              (setf (agent-context-item-provenance copy) prov)
              copy))
          items))

(defun agent-context--finish-buffer ()
  "Kill the composer buffer after a successful dispatch."
  (when (get-buffer agent-context-buffer-name)
    (kill-buffer agent-context-buffer-name)))

;;;###autoload
(defun agent-context-recompose ()
  "Rebuild a draft from the last successfully dispatched composition.
The new draft gets fresh copies, so editing it never mutates the
retained record (and vice versa)."
  (interactive)
  (unless agent-context--last
    (user-error "No previous composition"))
  (when agent-context--current
    (user-error "A draft already exists; finish or cancel it first"))
  (agent-context-compose)
  (setf (agent-context-draft-items agent-context--current)
        (agent-context--detached-copies
         (plist-get agent-context--last :items)))
  (with-current-buffer agent-context-buffer-name
    (agent-context--refresh)
    (save-excursion
      (goto-char (agent-context--field-start))
      (insert (propertize (plist-get agent-context--last :instruction)
                          'agent-context-field t
                          'keymap agent-context--field-map)))))
```

Note `agent-context--on-kill` (Task 8) clears `agent-context--current`
when the buffer dies; `agent-context--finish` clears it *before* killing
the buffer, so the kill hook's temp-file cleanup must not run for
dispatched media (their files must outlive dispatch for the CLI to read).
The ordering above already guarantees that: `agent-context--current` is
nil by the time `agent-context--finish-buffer` kills the buffer, and
`agent-context--on-kill` no-ops.  Add a comment to `agent-context--on-kill`
saying exactly this.

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test` — all pass.

- [ ] **Step 5: Commit**

```bash
git add agent-context.el test/agent-context-test.el
git commit -m "agent-context: add the dispatch pipeline"
```

---

### Task 10: Upstream codex.el — programmatic mentions and detach handles

**Files (sibling repo `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/codex`):**
- Modify: `codex-app-server.el` (`codex-app-server-attach-mention` ~line
  1837, `codex-app-server-attach-image` ~line 4270)
- Test: `codex-test.el`

Read that repo's `AGENTS.md` first and follow its conventions.  No
TUI-parity claim is involved (these are extension-point changes), so no
ground-truth capture is required, but say so in the commit message if the
repo's checklist asks.

**Interfaces:**
- Produces (consumed by agent-codex in Task 11):
  - `codex-app-server-attach-mention (&optional path)` — PATH may now be
    passed programmatically; called with no argument (interactively or by
    the existing `/mention` slash-command path) it prompts exactly as
    before.  Buffer-local effect on the current buffer; returns a handle.
  - `codex-app-server-attach-image (path)` — unchanged signature, now
    returns a handle.
  - `codex-app-server-detach (handle)` — removes the pending entry if not
    yet consumed; returns non-nil when something was removed.
  - `codex-app-server-ready-for-turn-p (&optional buffer)` — non-nil only
    when BUFFER can start a fresh turn immediately: live process, thread
    started, no active turn, no pending `turn/start`, no queued inputs,
    no reasoning-held or startup submissions.
  - `codex-app-server-pending-attachments-p (&optional buffer)` — non-nil
    when pending mentions or images exist in BUFFER.
  - `codex-app-server-submit-literal (text)` — submits TEXT verbatim as
    a FRESH turn, never parsing slash (`/`) or shell (`!`) prefixes and
    never delegating to the general dispatcher (whose branches can
    hold, queue, or steer): it performs its own authoritative
    `codex-app-server-ready-for-turn-p' check and then invokes only
    the fresh `turn/start' path.  Signals a `user-error' for
    precondition failures — unsent composer input, or a session not
    ready for a fresh turn (including no started thread: there is NO
    startup-queue fallback).  Runs `codex-command-submitted-hook',
    records input history, and echoes the message like an interactive
    submission; pending attachments are consumed into this turn (the
    composer guarantees they are its own via the pending-attachments
    check before it attaches).  Returning normally means OWNERSHIP
    TRANSFERRED: a send that fails afterwards — synchronously,
    asynchronously, or via quit — is restored into the session's own
    composer (attachments included) and announced through
    `codex-app-server-turn-start-failed-functions', so the caller
    keeps no retry copy and can roll its own state back.
  - `codex-app-server-turn-start-failed-functions` — abnormal hook run
    with the session buffer whenever a started submission fails to
    become a turn (synchronous send error, quit, or asynchronous
    `turn/start' error response), after the submission has been
    restored to the composer.
  - `codex--app-server-send-turn-start` is reworked around an
    EXACTLY-ONCE resolver shared by its synchronous handler and its
    response callback, and its whole body runs under `inhibit-quit`,
    so the JSON-RPC write is UNINTERRUPTIBLE.  There is no
    "delivered but restored locally" state: either the write signals
    synchronously (nothing delivered — restored exactly once, failure
    hook run) or the write completes (possibly/definitely delivered —
    ownership is the response callback's, the submission is NOT
    locally retryable, and a C-g pressed during the write is consumed
    with a message because there is nothing left to abort).  Quit can
    therefore only ever fire BEFORE the send, where restoring is
    unambiguous.  Interactive submissions gain the same protection and
    failure reporting.

Before writing code, `grep -n "attach-mention" codex-app-server.el
codex.el` and note every caller — the `/mention` slash dispatcher and any
keymap binding call it with **no arguments**, and must keep working.

- [ ] **Step 1: Write the failing tests** (in `codex-test.el`, following
  its local conventions for naming and fixtures)

```elisp
(ert-deftest codex-test-app-server-attach-mention-programmatic ()
  "Attach-mention accepts PATH and returns a detachable handle."
  (with-temp-buffer
    (setq-local codex--app-server-pending-mentions nil)
    (let ((handle (codex-app-server-attach-mention "/tmp/file.el")))
      (should (equal codex--app-server-pending-mentions
                     '(("file.el" . "/tmp/file.el"))))
      (should (codex-app-server-detach handle))
      (should (null codex--app-server-pending-mentions))
      ;; A second detach of the same handle is a no-op.
      (should-not (codex-app-server-detach handle)))))

(ert-deftest codex-test-app-server-attach-mention-no-arg-still-prompts ()
  "/mention regression: a no-argument call prompts as before."
  (with-temp-buffer
    (setq-local codex--app-server-pending-mentions nil)
    (cl-letf (((symbol-function 'read-file-name)
               (lambda (&rest _) "/tmp/prompted.el")))
      (codex-app-server-attach-mention)
      (should (equal codex--app-server-pending-mentions
                     '(("prompted.el" . "/tmp/prompted.el")))))))

(ert-deftest codex-test-app-server-submit-literal-fresh-turn-only ()
  "Literal submission checks readiness itself and invokes only the
fresh `turn/start' path — never the general dispatcher, which can
hold, queue, or steer."
  (with-temp-buffer
    (let (started dispatched (hook-runs 0))
      (cl-letf (((symbol-function 'codex--app-server-send-turn-start)
                 (lambda (submission) (push submission started)))
                ((symbol-function 'codex--app-server-send-turn-input)
                 (lambda (submission) (push submission dispatched)))
                ((symbol-function 'codex--run-command-submitted-hook)
                 (lambda () (cl-incf hook-runs)))
                ((symbol-function 'codex-prompt-input)
                 (lambda (&optional _) nil))
                ((symbol-function 'codex-app-server-ready-for-turn-p)
                 (lambda (&optional _) t))
                ((symbol-function 'codex--app-server-insert-message)
                 #'ignore)
                ((symbol-function 'codex--app-server-ensure-trailing-newline)
                 #'ignore))
        (setq-local codex--app-server-pending-images nil)
        (setq-local codex--app-server-pending-mentions nil)
        (codex-app-server-submit-literal "/exit")
        ;; Sent as a fresh turn, not dispatched as a slash command or
        ;; through the queue/steer-capable dispatcher; the submission
        ;; hook ran so session tracking observes it.
        (should (= 1 (length started)))
        (should (null dispatched))
        (should (equal (plist-get (car started) :text) "/exit"))
        (should (= hook-runs 1)))
      ;; Unsent composer input refuses.
      (cl-letf (((symbol-function 'codex-prompt-input)
                 (lambda (&optional _) "half-typed")))
        (should-error (codex-app-server-submit-literal "hello")
                      :type 'user-error))
      ;; Not ready (e.g. no thread, pending start, queued input):
      ;; refuse — there is no startup-queue fallback.
      (cl-letf (((symbol-function 'codex-prompt-input)
                 (lambda (&optional _) nil))
                ((symbol-function 'codex-app-server-ready-for-turn-p)
                 (lambda (&optional _) nil)))
        (should-error (codex-app-server-submit-literal "hello")
                      :type 'user-error)))))

(defmacro codex-test--with-literal-env (&rest body)
  "Bind the literal-submission stubs; expose RESTORED, STATUSES,
HOOK-BUFFERS, LATE-CALLBACK, and SEND-BEHAVIOR (a function called in
place of the request write) to BODY."
  (declare (indent 0))
  `(with-temp-buffer
     (let (restored statuses hook-buffers late-callback
           (send-behavior #'ignore))
       (ignore restored statuses hook-buffers late-callback)
       (cl-letf (((symbol-function 'codex-prompt-input)
                  (lambda (&optional _) nil))
                 ((symbol-function 'codex-app-server-ready-for-turn-p)
                  (lambda (&optional _) t))
                 ((symbol-function 'codex--app-server-insert-message)
                  #'ignore)
                 ((symbol-function 'codex--app-server-ensure-trailing-newline)
                  #'ignore)
                 ((symbol-function 'codex--app-server-accept-submission)
                  #'ignore)
                 ((symbol-function 'codex--app-server-turn-started)
                  #'ignore)
                 ((symbol-function 'codex--app-server-insert-status)
                  (lambda (text) (push text statuses)))
                 ((symbol-function 'codex--app-server-restore-submission)
                  (lambda (submission) (push submission restored)))
                 ((symbol-function 'codex--app-server-send-request)
                  (lambda (_method _params callback)
                    ;; The request layer registers its callback and
                    ;; then attempts the write.
                    (setq late-callback callback)
                    (funcall send-behavior))))
         (let ((codex-app-server-turn-start-failed-functions
                (list (lambda (buffer) (push buffer hook-buffers)))))
           (setq-local codex--app-server-pending-images nil)
           (setq-local codex--app-server-pending-mentions nil)
           (setq-local codex--app-server-thread-id "t1")
           ,@body)))))

(ert-deftest codex-test-app-server-submit-literal-sync-error-owned ()
  "A synchronous write error is recovered codex-side exactly once:
restored, failure hook run, pending flag cleared, the retained
callback dead, and no signal to the caller."
  (codex-test--with-literal-env
    (setq send-behavior (lambda () (error "socket closed")))
    (codex-app-server-submit-literal "hello")   ; must NOT signal
    (should (= 1 (length restored)))
    (should (equal hook-buffers (list (current-buffer))))
    (should-not codex--app-server-turn-start-pending-p)
    ;; A late response must not act on the restored submission.
    (funcall late-callback nil '((code . -32000)))
    (should (= 1 (length restored)))
    (should (= 1 (length hook-buffers)))
    (should (cl-some (lambda (line) (string-match-p "restored" line))
                     statuses))))

(ert-deftest codex-test-app-server-quit-during-write-not-retryable ()
  "A C-g during the uninterruptible write is consumed: nothing is
restored, the submission is NOT locally retryable, and a late SUCCESS
response completes the turn normally — no `delivered but restored'
state can exist."
  (codex-test--with-literal-env
    (setq send-behavior (lambda () (setq quit-flag t)))  ; C-g mid-write
    (codex-app-server-submit-literal "hello")   ; must NOT signal
    (should-not quit-flag)                      ; consumed, with message
    (should (null restored))
    (should (null hook-buffers))
    ;; The turn is in flight; the callback still owns the outcome.
    (should codex--app-server-turn-start-pending-p)
    (funcall late-callback '((turn . ((id . "t-1")))) nil)
    (should-not codex--app-server-turn-start-pending-p)
    (should (null restored))
    (should (null hook-buffers))))

(ert-deftest codex-test-app-server-quit-before-send-restores-once ()
  "A quit that fires before the write (the only place quit can now
fire) restores exactly once and runs the failure hook."
  (codex-test--with-literal-env
    (cl-letf (((symbol-function 'codex--app-server-send-turn-start)
               (lambda (_submission) (signal 'quit nil))))
      (codex-app-server-submit-literal "hello"))  ; must NOT signal
    (should (= 1 (length restored)))
    (should (equal hook-buffers (list (current-buffer))))
    (should (cl-some (lambda (line)
                       (string-match-p "quit before sending" line))
                     statuses))))

(ert-deftest codex-test-app-server-pending-attachments-p ()
  "The predicate sees both pending mentions and pending images."
  (with-temp-buffer
    (setq-local codex--app-server-pending-images nil)
    (setq-local codex--app-server-pending-mentions nil)
    (should-not (codex-app-server-pending-attachments-p))
    (setq-local codex--app-server-pending-mentions '(("a" . "/a")))
    (should (codex-app-server-pending-attachments-p))
    (setq-local codex--app-server-pending-mentions nil)
    (setq-local codex--app-server-pending-images '("/b.png"))
    (should (codex-app-server-pending-attachments-p))))

(ert-deftest codex-test-app-server-ready-for-turn-p-blocking-states ()
  "Each pending state independently blocks turn readiness."
  (with-temp-buffer
    (setq-local codex--app-server-process
                (start-process "codex-test-stub" nil "cat"))
    (unwind-protect
        (progn
          (setq-local codex--app-server-thread-id "t1")
          (setq-local codex--app-server-turn-active-p nil)
          (setq-local codex--app-server-turn-start-pending-p nil)
          (setq-local codex--app-server-queued-turn-inputs nil)
          (setq-local codex--app-server-pending-reasoning-steps nil)
          (setq-local codex--app-server-reasoning-waiting-submissions nil)
          (setq-local codex--app-server-startup-submissions nil)
          (should (codex-app-server-ready-for-turn-p))
          (dolist (blocker '(codex--app-server-turn-active-p
                             codex--app-server-turn-start-pending-p
                             codex--app-server-queued-turn-inputs
                             codex--app-server-pending-reasoning-steps
                             codex--app-server-reasoning-waiting-submissions
                             codex--app-server-startup-submissions))
            (set blocker '(t))
            (should-not (codex-app-server-ready-for-turn-p))
            (set blocker nil))
          (setq-local codex--app-server-thread-id nil)
          (should-not (codex-app-server-ready-for-turn-p)))
      (delete-process codex--app-server-process))))

(ert-deftest codex-test-app-server-attach-image-returns-handle ()
  "Attach-image returns a handle that removes exactly its entry."
  (with-temp-buffer
    (setq-local codex--app-server-pending-images nil)
    (let ((h1 (codex-app-server-attach-image "/tmp/a.png"))
          (_h2 (codex-app-server-attach-image "/tmp/a.png")))
      (should (= 2 (length codex--app-server-pending-images)))
      (should (codex-app-server-detach h1))
      ;; Only one of the two identical paths was removed.
      (should (= 1 (length codex--app-server-pending-images))))))
```

- [ ] **Step 2: Run the codex test suite to verify failure**

Run (in the codex repo): `make test`
Expected: FAIL — attach-mention takes no argument; detach undefined.

- [ ] **Step 3: Implement**

```elisp
(defun codex-app-server-attach-mention (&optional path)
  "Attach a file mention for PATH to the next app-server turn input.
With no PATH — interactively, or from the `/mention' slash command —
prompt for the file exactly as before.  Operates on the current
buffer's pending mentions.  Return a handle accepted by
`codex-app-server-detach'."
  (interactive)
  (let* ((path (expand-file-name
                (or path (read-file-name "Mention file: "))))
         (entry (cons (file-name-nondirectory path) path)))
    (setq codex--app-server-pending-mentions
          (append codex--app-server-pending-mentions (list entry)))
    (message "File mentioned for next Codex turn: %s" path)
    (list 'mention entry)))

(defun codex-app-server-attach-image (path)
  "Attach image at PATH to the next app-server turn input.
Return a handle accepted by `codex-app-server-detach'."
  (interactive "fAttach image: ")
  (let ((path (expand-file-name path)))
    (setq codex--app-server-pending-images
          (append codex--app-server-pending-images (list path)))
    (message "Image attached for next Codex turn: %s" path)
    (list 'image path)))

(defun codex-app-server-detach (handle)
  "Remove pending attachment HANDLE if it has not been consumed yet.
HANDLE comes from `codex-app-server-attach-mention' or
`codex-app-server-attach-image'.  Return non-nil when an entry was
removed.  Removal is by object identity, so duplicate paths are safe."
  (pcase handle
    (`(mention ,entry)
     (when (memq entry codex--app-server-pending-mentions)
       (setq codex--app-server-pending-mentions
             (delq entry codex--app-server-pending-mentions))
       t))
    (`(image ,path)
     (when (memq path codex--app-server-pending-images)
       (setq codex--app-server-pending-images
             (delq path codex--app-server-pending-images))
       t))))

(defun codex-app-server-ready-for-turn-p (&optional buffer)
  "Return non-nil when BUFFER can start a fresh turn immediately.
Nil while the app-server process is dead, the thread has not started,
a turn is active, a `turn/start' is pending, queued inputs exist, or
reasoning-held or startup submissions are waiting — in those states a
new submission would be queued or would steer the running turn."
  (with-current-buffer (or buffer (current-buffer))
    (and (process-live-p codex--app-server-process)
         codex--app-server-thread-id
         (not codex--app-server-turn-active-p)
         (not codex--app-server-turn-start-pending-p)
         (null codex--app-server-queued-turn-inputs)
         (null codex--app-server-pending-reasoning-steps)
         (null codex--app-server-reasoning-waiting-submissions)
         (null codex--app-server-startup-submissions)
         t)))

(defun codex-app-server-pending-attachments-p (&optional buffer)
  "Return non-nil when BUFFER has pending mentions or images."
  (with-current-buffer (or buffer (current-buffer))
    (or codex--app-server-pending-mentions
        codex--app-server-pending-images)))

(defvar codex-app-server-turn-start-failed-functions nil
  "Abnormal hook run with the buffer when a submission fails to start.
Runs after the submission has been restored to the composer, for
synchronous send errors, asynchronous `turn/start' error responses,
and quits during a literal submission.")

(defun codex-app-server-submit-literal (text)
  "Submit TEXT verbatim as a fresh turn in the current buffer.
TEXT is never parsed for slash or shell prefixes, and this function
never delegates to `codex--app-server-send-turn-input', whose branches
can hold, queue, or steer: it checks
`codex-app-server-ready-for-turn-p' itself and invokes only the fresh
`turn/start' path.  Precondition failures signal a `user-error':
unsent composer input, or a session that is not ready for a fresh
turn.  Returning normally transfers ownership: a send that fails
afterwards is restored into this session's composer and announced on
`codex-app-server-turn-start-failed-functions'."
  (when (codex-prompt-input)
    (user-error "Codex composer has unsent input"))
  (unless (codex-app-server-ready-for-turn-p)
    (user-error "Codex session is not ready for a fresh turn"))
  (codex--run-command-submitted-hook)
  (codex--app-server-record-input text)
  (codex--app-server-insert-message codex--app-server-user-prefix text)
  (codex--app-server-ensure-trailing-newline)
  (let ((submission (codex--app-server-take-submission text)))
    (condition-case err
        (codex--app-server-send-turn-start submission)
      (quit
       ;; Quit cannot escape `send-turn-start' (its body inhibits
       ;; quits), so this quit fired BEFORE the write: nothing was
       ;; delivered and nothing was restored yet.  Restore here,
       ;; exactly once.
       (codex--app-server-restore-submission submission)
       (run-hook-with-args 'codex-app-server-turn-start-failed-functions
                           (current-buffer))
       (codex--app-server-insert-status
        "Literal submission quit before sending; input restored"))
      (error
       ;; `send-turn-start' already resolved pending state, restored,
       ;; and ran the failure hook; swallow the re-signal so the
       ;; caller keeps no second retry copy.
       (codex--app-server-insert-status
        (format "Literal submission failed to start; input restored (%s)"
                (error-message-string err)))))))
```

Rework `codex--app-server-send-turn-start' (currently ~line 4152)
around an exactly-once resolver.  Behavior for the success path is
unchanged; the failure paths — synchronous error, quit, and the
asynchronous error response — all resolve the pending flag once, run
the failure hook once, and can never double-act:

```elisp
(defun codex--app-server-send-turn-start (submission)
  "Send captured SUBMISSION as a new app-server turn.
The whole body runs with quits inhibited, so the JSON-RPC write is
uninterruptible: either it signals synchronously (nothing delivered;
SUBMISSION is restored exactly once and the failure hook runs) or it
completes, at which point ownership belongs to the response callback
and SUBMISSION is not locally retryable — a C-g pressed during the
write is consumed with a message, because there is nothing left to
abort.  The pending flag and the response callback are resolved
exactly once: whichever of the synchronous failure handler and the
asynchronous response runs first wins; the other is a no-op."
  (let ((buffer (current-buffer))
        (resolved nil)
        (inhibit-quit t))
    (setq codex--app-server-turn-start-pending-p t)
    (cl-flet ((resolve-once ()
                (unless resolved
                  (setq resolved t)
                  (when (buffer-live-p buffer)
                    (with-current-buffer buffer
                      (setq codex--app-server-turn-start-pending-p nil)))
                  t))
              (report-failure ()
                (when (buffer-live-p buffer)
                  (with-current-buffer buffer
                    (codex--app-server-restore-submission submission)
                    (run-hook-with-args
                     'codex-app-server-turn-start-failed-functions
                     buffer)))))
      (condition-case err
          (codex--app-server-send-request
           "turn/start"
           `((threadId . ,codex--app-server-thread-id)
             (input . ,(codex--app-server-user-input-vector submission))
             (cwd . ,codex--buffer-directory)
             (approvalPolicy . ,(codex--app-server-approval-policy))
             (effort . ,codex-reasoning-effort))
           (lambda (result error)
             (when (resolve-once)
               (if error
                   (progn
                     (report-failure)
                     (codex--app-server-insert-status
                      (format "Codex turn failed to start: %S" error)))
                 (with-current-buffer buffer
                   (codex--app-server-accept-submission submission)
                   (codex--app-server-turn-started
                    `((threadId . ,codex--app-server-thread-id)
                      (turn . ,(alist-get 'turn result)))))))))
        ;; With quits inhibited, only `error' can reach this handler.
        (error
         (when (resolve-once)
           (report-failure))
         (signal (car err) (cdr err))))
      ;; A C-g pressed while the write was in flight is moot now: the
      ;; request was delivered (a failed write signaled above).  Consume
      ;; it so it cannot unwind callers into draft-restoring paths.
      (when quit-flag
        (setq quit-flag nil)
        (message "Quit ignored: the Codex turn was already sent")))))
```

(For the image test to pass, note `memq`/`delq` operate on the *same
string object* stored in the handle, so two equal paths do not collide.
If grep in Step 0 found `/mention` callers passing arguments, adjust
them to the new optional signature and extend the regression test.)

Update the codex manual (README.org API section) with the four functions,
regenerate its texi per that repo's convention, and run its full checks.

- [ ] **Step 4: Run codex tests and compile**

Run (codex repo): `make test && make compile` — clean.

- [ ] **Step 5: Commit (codex repo)**

```bash
git add codex-app-server.el codex-test.el README.org codex.texi
git commit -m "codex-app-server: add programmatic attachment and readiness API"
```

- [ ] **Step 6: Rebuild the active Elpaca codex build (mandatory)**

The agent repo's Makefile resolves `codex` from the Elpaca *builds*
directory, not the source checkout.  Rebuild and verify before Task 11:

```bash
emacsclient -e "(elpaca-rebuild 'codex)"
```

then confirm the build actually exposes the new API:

```bash
cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent
emacs --batch --eval '(dolist (dir (file-expand-wildcards "~/.config/emacs-profiles/8.3.0-dev/elpaca/builds/*/")) (add-to-list (quote load-path) dir))' \
  -l codex-app-server --eval '(prin1 (list (fboundp (quote codex-app-server-detach)) (fboundp (quote codex-app-server-ready-for-turn-p)) (fboundp (quote codex-app-server-submit-literal)) (fboundp (quote codex-app-server-pending-attachments-p)) (boundp (quote codex-app-server-turn-start-failed-functions))))'
```

Expected output: `(t t t t t)`.  Do not proceed to Task 11 until it is.

---

### Task 11: Backend adapter registrations

**Files:**
- Modify: `agent-claude.el` (backend registration, ~line 215)
- Modify: `agent-codex.el` (backend registration, ~line 138)
- Test: `test/agent-claude-test.el`, `test/agent-codex-test.el`

**Interfaces:**
- Consumes: Task 1 slot contract; Task 10 codex API.  Task 10 Step 6
  (Elpaca rebuild + verification) is a hard prerequisite: the
  integration tests below assert `fboundp` and **fail**, not skip, when
  the API is absent.
- Produces:
  - Claude: `agent-claude--file-reference-token`,
    `agent-claude--media-token` (pure `@` tokens; no attach functions —
    the token is the whole mechanism).
  - Codex: `agent-codex--session-transport`,
    `agent-codex--mention-api-available-p` (indirection so tests can
    simulate an older codex.el), `agent-codex--file-reference-token`,
    `agent-codex--media-token`, `agent-codex--attach-file-reference`,
    `agent-codex--attach-media`, `agent-codex--detach-closure`,
    `agent-codex--ready-to-submit-p`.
  - Claude registers NO dispatch slots (`:pending-input-p',
    `:submit-literal').  Terminal writes have no acknowledgment and
    the input box cannot be positively verified empty, so Claude
    targets are compose-and-preview only: the composer warns at
    compose/retarget and refuses at dispatch.  The pure token slots
    stay registered so previews are complete and dispatch support can
    land the day claude-code.el provides a tristate prompt probe and
    an acknowledged (or safely recoverable) submission API.
  - Codex also: `agent-codex--pending-input-p` (`unknown' for every
    terminal transport — `codex-prompt-input''s terminal parser cannot
    distinguish empty from unlocatable, so nil proves nothing; the
    composer refuses `unknown'), `agent-codex--submit-literal`
    (app-server ONLY: upstream literal API — authoritative fresh-turn
    check, no prefix check, ownership transferred on return; every
    terminal transport refuses until a presence-aware prompt probe
    exists upstream), and `agent-codex--note-turn-start-failure`
    (on `codex-app-server-turn-start-failed-functions', added by
    `agent-codex--mode-enable` and removed symmetrically on disable,
    guarded by `boundp`; emits `submit-failed' so a failed literal
    submission never leaves the session stuck busy).
  - Registrations: Claude gets `:file-reference-token` and
    `:media-token` ONLY (no attach, no dispatch slots); Codex gets all
    four token/attach slots, `:ready-to-submit-p`, `:pending-input-p`,
    and `:submit-literal`.

- [ ] **Step 1: Write the failing tests**

In `test/agent-claude-test.el`:

```elisp
(ert-deftest agent-claude-test-file-reference-token ()
  "Claude file references are pure @-mention tokens."
  (should (equal (agent-claude--file-reference-token "/tmp/a.el" nil)
                 "@/tmp/a.el "))
  (should (equal (agent-claude--media-token "/tmp/a.png" nil)
                 "@/tmp/a.png ")))

(ert-deftest agent-claude-test-registers-token-slots-only ()
  "Claude registers pure tokens and no attach or dispatch slots.
Terminal writes have no acknowledgment, so until claude-code.el grows
a tristate prompt probe and an acknowledged submission API, Claude
targets are compose-and-preview only and dispatch refuses them."
  (let ((struct (agent-backend 'claude-code)))
    (should (agent-backend-file-reference-token struct))
    (should (agent-backend-media-token struct))
    (should (null (agent-backend-attach-file-reference struct)))
    (should (null (agent-backend-attach-media struct)))
    (should (null (agent-backend-pending-input-p struct)))
    (should (null (agent-backend-submit-literal struct)))))
```

In `test/agent-codex-test.el`:

```elisp
(ert-deftest agent-codex-test-new-codex-api-present ()
  "Hard prerequisite: the rebuilt codex build exposes the Task 10 API.
This test FAILS (never skips) when the API is missing — rerun Task 10
Step 6 in that case."
  (should (fboundp 'codex-app-server-detach))
  (should (fboundp 'codex-app-server-ready-for-turn-p))
  (should (fboundp 'codex-app-server-submit-literal))
  (should (fboundp 'codex-app-server-pending-attachments-p)))

(ert-deftest agent-codex-test-submit-literal-app-server-only ()
  "App-server text is structurally literal — a file-only draft may
begin with a $NAME mention token — and every terminal transport is
refused: without a presence-aware prompt probe, isolation cannot be
verified there."
  (with-temp-buffer
    (setq-local codex-terminal-backend 'app-server)
    (let (sent)
      (cl-letf (((symbol-function 'codex-app-server-submit-literal)
                 (lambda (text) (push text sent))))
        (agent-codex--submit-literal "$a.el and nothing else"
                                     (current-buffer))
        (should (equal sent '("$a.el and nothing else"))))))
  (dolist (backend '(eat vterm))
    (with-temp-buffer
      (setq-local codex-terminal-backend backend)
      (should-error (agent-codex--submit-literal "hello" (current-buffer))
                    :type 'user-error))))

(ert-deftest agent-codex-test-turn-start-failure-rolls-back-state ()
  "The upstream failure hook translates into `submit-failed', so a
failed literal submission never leaves the session stuck busy."
  (with-temp-buffer
    (agent-session-event (current-buffer) 'submit)
    (should (eq (agent-session-display-state (current-buffer)) 'busy))
    (agent-codex--note-turn-start-failure (current-buffer))
    (should-not (eq (agent-session-display-state (current-buffer))
                    'busy))))

(ert-deftest agent-codex-test-terminal-submit-literal-checks-prompt ()
  "Terminal literal submission refuses when unsent input is pending."
  (with-temp-buffer
    (setq-local codex-terminal-backend 'eat)
    (cl-letf (((symbol-function 'codex-prompt-input)
               (lambda (&optional _) "half-typed")))
      (should-error (agent-codex--submit-literal "hi" (current-buffer))
                    :type 'user-error))))

(ert-deftest agent-codex-test-pending-input-p-app-server ()
  "App-server pending state covers prompt text and attachments."
  (with-temp-buffer
    (setq-local codex-terminal-backend 'app-server)
    (cl-letf (((symbol-function 'codex-prompt-input)
               (lambda (&optional _) nil))
              ((symbol-function 'codex-app-server-pending-attachments-p)
               (lambda (&optional _) '(("a" . "/a")))))
      (should (agent-codex--pending-input-p (current-buffer))))
    (cl-letf (((symbol-function 'codex-prompt-input)
               (lambda (&optional _) nil))
              ((symbol-function 'codex-app-server-pending-attachments-p)
               (lambda (&optional _) nil)))
      (should-not (agent-codex--pending-input-p (current-buffer)))))
  ;; Terminal transports are never verifiable, whatever the parser says.
  (with-temp-buffer
    (setq-local codex-terminal-backend 'eat)
    (should (eq (agent-codex--pending-input-p (current-buffer))
                'unknown))))

(ert-deftest agent-codex-test-terminal-transport-uses-at-token ()
  "eat/vterm sessions get the CLI's @-mention token; no attach, no undo."
  (with-temp-buffer
    (setq-local codex-terminal-backend 'eat)
    (should (equal (agent-codex--file-reference-token
                    "/tmp/a.el" (current-buffer))
                   "@/tmp/a.el "))
    (should (null (agent-codex--attach-file-reference
                   "/tmp/a.el" (current-buffer))))))

(ert-deftest agent-codex-test-app-server-without-api-is-unsupported ()
  "An app-server session on an old codex.el reports unsupported (nil
token) — it must never silently downgrade to an @ token the app-server
does not parse."
  (with-temp-buffer
    (setq-local codex-terminal-backend 'app-server)
    (cl-letf (((symbol-function 'agent-codex--mention-api-available-p)
               (lambda () nil)))
      (should (null (agent-codex--file-reference-token
                     "/tmp/a.el" (current-buffer))))
      (should (null (agent-codex--media-token
                     "/tmp/a.png" (current-buffer)))))))

(ert-deftest agent-codex-test-app-server-mention-token-and-attach ()
  "App-server sessions get $NAME tokens and a detachable attachment."
  (with-temp-buffer
    (setq-local codex-terminal-backend 'app-server)
    (setq-local codex--app-server-pending-mentions nil)
    ;; Pure token: no side effect.
    (should (equal (agent-codex--file-reference-token
                    "/tmp/a.el" (current-buffer))
                   "$a.el"))
    (should (null codex--app-server-pending-mentions))
    ;; Effectful attach: pending mention plus a working undo.
    (let ((undo (agent-codex--attach-file-reference
                 "/tmp/a.el" (current-buffer))))
      (should (functionp undo))
      (should (= 1 (length codex--app-server-pending-mentions)))
      (funcall undo)
      (should (null codex--app-server-pending-mentions)))))

(ert-deftest agent-codex-test-ready-to-submit-probe ()
  "The readiness slot maps the codex predicate to ready/busy/unknown."
  (with-temp-buffer
    (setq-local codex-terminal-backend 'app-server)
    (cl-letf (((symbol-function 'codex-app-server-ready-for-turn-p)
               (lambda (&optional _) nil)))
      (should (eq (agent-codex--ready-to-submit-p (current-buffer))
                  'busy)))
    (cl-letf (((symbol-function 'codex-app-server-ready-for-turn-p)
               (lambda (&optional _) t)))
      (should (eq (agent-codex--ready-to-submit-p (current-buffer))
                  'ready))))
  (with-temp-buffer                     ; terminal: no protocol signal
    (setq-local codex-terminal-backend 'eat)
    (should (eq (agent-codex--ready-to-submit-p (current-buffer))
                'unknown))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test` — FAIL, functions undefined.

- [ ] **Step 3: Implement**

`agent-claude.el` — add near the other send helpers and register in the
`agent-register-backend` form (`:file-reference-token
#'agent-claude--file-reference-token :media-token
#'agent-claude--media-token`; no attach slots and — deliberately — no
dispatch slots):

```elisp
(defun agent-claude--file-reference-token (path _buffer)
  "Return the Claude @-mention token for PATH.
The Claude CLI expands @-mentions in submitted text; there is no
out-of-band attachment, so no attach function is registered."
  (format "@%s " (expand-file-name path)))

(defun agent-claude--media-token (path buffer)
  "Return the Claude image token for PATH.
Identical to the file-reference channel: the CLI attaches @-mentioned
images, exactly as upstream's own image paste does."
  (agent-claude--file-reference-token path buffer))

;; Claude registers no dispatch slots: see the Interfaces note.  The
;; token functions above are the whole Claude registration surface.
```

`agent-codex.el` — add and register (`:file-reference-token
#'agent-codex--file-reference-token :media-token
#'agent-codex--media-token :attach-file-reference
#'agent-codex--attach-file-reference :attach-media
#'agent-codex--attach-media :ready-to-submit-p
#'agent-codex--ready-to-submit-p :pending-input-p
#'agent-codex--pending-input-p :submit-literal
#'agent-codex--submit-literal`):

```elisp
(declare-function codex-app-server-attach-mention "codex-app-server"
                  (&optional path))
(declare-function codex-app-server-attach-image "codex-app-server" (path))
(declare-function codex-app-server-detach "codex-app-server" (handle))
(declare-function codex-app-server-ready-for-turn-p "codex-app-server"
                  (&optional buffer))

(defun agent-codex--session-transport (buffer)
  "Return `app-server' or `terminal' for Codex session BUFFER.
Decided by the buffer's own terminal-backend configuration, never by
which codex.el APIs happen to be available."
  (with-current-buffer buffer
    (if (eq (bound-and-true-p codex-terminal-backend) 'app-server)
        'app-server
      'terminal)))

(defun agent-codex--mention-api-available-p ()
  "Return non-nil when codex.el provides the programmatic mention API."
  (fboundp 'codex-app-server-detach))

(defun agent-codex--file-reference-token (path buffer)
  "Return the mention token for PATH in BUFFER, or nil when unsupported.
Terminal sessions use the CLI's @-mention expansion.  App-server
sessions never parse @ tokens, so without the codex mention API the
transport is honestly unsupported (nil), never a silent downgrade."
  (pcase (agent-codex--session-transport buffer)
    ('terminal (format "@%s " (expand-file-name path)))
    ('app-server
     (when (agent-codex--mention-api-available-p)
       (format "$%s" (file-name-nondirectory (expand-file-name path)))))))

(defun agent-codex--media-token (path buffer)
  "Return the image token for PATH in BUFFER, or nil when unsupported."
  (pcase (agent-codex--session-transport buffer)
    ('terminal (format "@%s " (expand-file-name path)))
    ('app-server
     (when (agent-codex--mention-api-available-p)
       (format "(image attached: %s)"
               (file-name-nondirectory (expand-file-name path)))))))

(defun agent-codex--attach-file-reference (path buffer)
  "Attach PATH as a native mention when BUFFER is app-server.
Return an undo closure, or nil for terminal sessions (their token is
the whole mechanism)."
  (when (and (eq (agent-codex--session-transport buffer) 'app-server)
             (agent-codex--mention-api-available-p))
    (let ((handle (with-current-buffer buffer
                    (codex-app-server-attach-mention
                     (expand-file-name path)))))
      (agent-codex--detach-closure buffer handle))))

(defun agent-codex--attach-media (path buffer)
  "Attach image PATH natively when BUFFER is app-server; return undo."
  (when (and (eq (agent-codex--session-transport buffer) 'app-server)
             (agent-codex--mention-api-available-p))
    (let ((handle (with-current-buffer buffer
                    (codex-app-server-attach-image
                     (expand-file-name path)))))
      (agent-codex--detach-closure buffer handle))))

(defun agent-codex--detach-closure (buffer handle)
  "Return a closure detaching HANDLE from BUFFER if still pending."
  (lambda ()
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (codex-app-server-detach handle)))))

(defun agent-codex--ready-to-submit-p (buffer)
  "Authoritative turn-readiness for Codex session BUFFER.
App-server sessions answer `ready' or `busy' from the protocol state
(`busy' covers active turns, pending starts, queued inputs, and
reasoning-held submissions); terminal sessions have no protocol signal
and answer `unknown'."
  (if (and (eq (agent-codex--session-transport buffer) 'app-server)
           (fboundp 'codex-app-server-ready-for-turn-p))
      (if (codex-app-server-ready-for-turn-p buffer) 'ready 'busy)
    'unknown))

(declare-function codex-app-server-submit-literal "codex-app-server" (text))
(declare-function codex-app-server-pending-attachments-p "codex-app-server"
                  (&optional buffer))

(defun agent-codex--pending-input-p (buffer)
  "Return nil when BUFFER is verifiably clean of unsent input.
App-server sessions check the composer text (marker-based, reliable)
and pending attachments.  Every terminal session yields `unknown':
`codex-prompt-input''s terminal parser returns nil both for an empty
prompt and for a prompt it could not locate, so nil there proves
nothing — a presence-aware upstream probe is required before terminal
sessions can be verified."
  (pcase (agent-codex--session-transport buffer)
    ('app-server
     (or (codex-prompt-input buffer)
         (and (fboundp 'codex-app-server-pending-attachments-p)
              (codex-app-server-pending-attachments-p buffer))))
    ('terminal 'unknown)))

(defun agent-codex--submit-literal (text buffer)
  "Submit TEXT to Codex session BUFFER as one literal turn.
Only app-server sessions are supported: the upstream literal API is
structurally literal (no slash/shell parsing, so no prefix check — a
file-only draft may legitimately begin with a $NAME mention token),
performs its own authoritative fresh-turn and unsent-input checks,
and transfers ownership on return (a turn that fails to start —
synchronously, asynchronously, or via quit — is restored into the
session's own composer and announced through the upstream failure
hook).  Terminal sessions are refused: without a presence-aware
prompt probe upstream, an empty prompt cannot be distinguished from
an unlocatable one, and appending blindly would violate isolation."
  (pcase (agent-codex--session-transport buffer)
    ('app-server
     (unless (fboundp 'codex-app-server-submit-literal)
       (user-error "agent-codex: codex.el lacks the literal submission API"))
     (with-current-buffer buffer
       (codex-app-server-submit-literal text)))
    ('terminal
     (user-error
      "agent-codex: literal dispatch supports only app-server sessions"))))

(defun agent-codex--note-turn-start-failure (buffer)
  "Translate an app-server turn-start failure into Agent state rollback.
On `codex-app-server-turn-start-failed-functions'; the submission
bookkeeping already marked BUFFER busy, and the input now lives back
in the Codex composer, so the session must not stay stuck busy."
  (agent-session-event buffer 'submit-failed))
```

Wire the handler through the existing mode owner —
`agent-codex--mode-enable` gains:

```elisp
(when (boundp 'codex-app-server-turn-start-failed-functions)
  (add-hook 'codex-app-server-turn-start-failed-functions
            #'agent-codex--note-turn-start-failure))
```

and `agent-codex--mode-disable` removes it symmetrically.

```elisp
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test` — all pass.

- [ ] **Step 5: Commit**

```bash
git add agent-claude.el agent-codex.el test/agent-claude-test.el test/agent-codex-test.el
git commit -m "agent: register composer capability slots per backend"
```

---

### Task 12: Menu entry and Dired convenience

**Files:**
- Modify: `agent.el` (autoloads section ~line 43; `agent-menu` Prompts
  column ~line 2702)
- Modify: `agent-context.el` (Dired command)
- Test: `test/agent-test.el`, `test/agent-context-test.el`

**Interfaces:**
- Produces: `agent-menu` Prompts entry `("C" "compose context"
  agent-context-compose)`; `agent-context-add-dired-files` (autoloaded).

- [ ] **Step 1: Write the failing tests**

In `test/agent-test.el`:

```elisp
(ert-deftest agent-test-menu-includes-context-composer ()
  "The unified menu binds C to the context composer."
  (let ((layout (get 'agent-menu 'transient--layout)))
    (should (string-match-p "agent-context-compose"
                            (format "%S" layout)))))
```

In `test/agent-context-test.el`:

```elisp
(ert-deftest agent-context-test-add-region-uses-invoking-buffer ()
  "`agent-context-add-region' reads the buffer it is invoked in."
  (agent-context-test--with-composer
   (let ((other (generate-new-buffer "ctx-region-src")))
     (unwind-protect
         (progn
           (with-current-buffer other
             (insert "from the invoking buffer")
             (set-mark (point-min))
             (goto-char (point-max))
             (activate-mark)
             (agent-context-add-region))
           (let ((item (car (agent-context-draft-items
                             agent-context--current))))
             (should (equal (agent-context-item-content item)
                            "from the invoking buffer"))
             (should (equal (plist-get
                             (agent-context-item-provenance item)
                             :buffer-name)
                            "ctx-region-src"))))
       (kill-buffer other)))))

(ert-deftest agent-context-test-dired-files-become-items ()
  "Dired marked files become file items in the draft."
  (let ((f1 (make-temp-file "ctx" nil ".el" "a"))
        (f2 (make-temp-file "ctx" nil ".el" "b")))
    (unwind-protect
        (agent-context-test--with-composer
         (cl-letf (((symbol-function 'dired-get-marked-files)
                    (lambda (&rest _) (list f1 f2))))
           (agent-context-add-dired-files))
         (should (= 2 (length (agent-context-draft-items
                               agent-context--current)))))
      (delete-file f1) (delete-file f2))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test` — FAIL.

- [ ] **Step 3: Implement**

`agent.el` autoloads section:

```elisp
(autoload 'agent-context-compose "agent-context" nil t)
```

`agent-menu` Prompts column becomes:

```elisp
   ["Prompts"
    ("p" "capture prompt" agent-capture-prompt)
    ("i" "insert prompt" agent-insert-captured-prompt)
    ("C" "compose context" agent-context-compose)]
```

`agent-context.el`:

```elisp
(declare-function dired-get-marked-files "dired"
                  (&optional localp arg filter distinguish-one-marked error))

;;;###autoload
(defun agent-context-add-dired-files ()
  "Add the marked Dired files to the context draft.
Starts a draft when none exists."
  (interactive)
  (let ((files (dired-get-marked-files)))
    (unless files (user-error "No marked files"))
    (unless agent-context--current (agent-context-compose))
    (dolist (file files)
      (agent-context--add-item
       (agent-context--gate-new-item (agent-context--file-item file))))
    (with-current-buffer agent-context-buffer-name
      (agent-context--refresh))))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test` — all pass.

- [ ] **Step 5: Commit**

```bash
git add agent.el agent-context.el test/agent-test.el test/agent-context-test.el
git commit -m "agent: add the context composer to the menu and Dired"
```

---

### Task 13: Manual

**Files:**
- Modify: `README.org` (new "Composing context" section after the
  Commands section; option indexes for the new defcustoms)
- Modify: `agent.texi` (regenerated)

- [ ] **Step 1: Write the manual section**

Add to `README.org` a `* Composing context` section covering, in prose
matching the manual's existing style: the composer workflow
(`agent-context-compose`, the draft buffer, add/preview/delete/reorder/
toggle/refresh/retarget keys, `agent-context-add-region` and
`agent-context-add-dired-files`, the `agent-menu` =C= entry); the
snapshot-versus-resolved rule (inline items snapshot exact bytes when
added; mention and media items are read by the CLI at send and display
estimated sizes); the deterministic rendering format and the
one-representation rule; backend differences (Claude and terminal Codex
use the CLIs' =@= mention expansion for files and images; app-server Codex
uses native mention and image items via codex.el's programmatic API; a
backend without a media slot refuses image items with the draft intact);
sizes reported in bytes only, never tokens; the safety rules
(secret-path regexps applied to every transport, NUL-based binary
rejection, symlink-escape skipping, `agent-context-max-files`,
`agent-context-max-file-bytes`, warn/refuse byte gates) with all six
defcustom defaults; URL fetching (explicit, `agent-context-url-timeout`,
`agent-context-url-max-bytes`, redirects recorded, HTML rendered via shr
when libxml is available, fetch failure distinct from an empty body, URL
content treated as untrusted); and failure behavior (busy targets
refused; unknown state confirmed; the authoritative readiness gate —
Codex app-server sessions with an active or pending turn, queued input,
or reasoning in flight refuse dispatch, so composition can never queue
or steer; every pre-submit failure, quit included, preserves the draft,
undoes out-of-band attachments, and rolls the session state back; after
a successful submit, cleanup failures warn but never resend;
only Codex app-server sessions can be dispatched to in this version —
Claude and terminal Codex targets are compose-and-preview only, with
the composer warning at compose time and refusing at dispatch, until
those backends provide a positively verifiable prompt-empty probe and
an acknowledged or safely recoverable submission API;
`agent-context-recompose` rebuilds the last sent composition from
independent copies).  Also document the two upstream
behaviors the composer relies on rather than reimplements: codex.el's
asynchronous restoration (a `turn/start` that later fails returns the
submission, attachments included, to that session's own composer), and
composer-owned temp-file lifetime (clipboard images live in a private
0600 directory, are deleted when their item is removed or the draft is
cancelled, and are deliberately kept after dispatch because the CLI may
read them asynchronously).

- [ ] **Step 2: Regenerate the texi export**

Run:
```bash
emacs --batch README.org -f org-texinfo-export-to-texinfo && mv README.texi agent.texi
```
Then `git diff agent.texi` and confirm the diff is the new section plus
menu updates only.

- [ ] **Step 3: Commit**

```bash
git add README.org agent.texi
git commit -m "agent: document the context composer"
```

---

### Task 14: Full checks and live verification

- [ ] **Step 1: Full suites**

Run in the agent repo: `make compile && make test` — compile warning-free,
all tests pass.  Run in the codex repo: `make compile && make test` —
same.

- [ ] **Step 2: Live verification checklist** (performed in the running
  Emacs with real sessions; report results honestly, per the spec's §13)

1. Codex app-server session: compose region + instruction; verify from
   the conversation that the agent received the region exactly once.
2. Codex app-server session: compose a file (native mention item) and
   a working-tree diff; verify contents and single receipt.
3. Claude session: verify compose warns "preview-only" and dispatch
   refuses with the honest no-literal-submission message; verify `P`
   still renders a complete preview including `@` tokens.
4. Codex terminal session: verify the composer refuses dispatch with
   the honest transport message (no literal-isolation support there
   yet).
5. Image, Codex app-server (native item): verify the model describes
   the image content, proving it arrived as an image, not a path
   string.  Remove the media registration if this fails and re-run the
   media tests.
6. Preview (`p` and `P`), delete, reorder, toggle, cancel.
7. Attachment rollback and retry, with a LIVE target: compose a file
   mention at an idle app-server session, then induce a submission
   failure after attachment with NAMED advice inside `unwind-protect`
   so it is reliably removed:

   ```elisp
   (defun agent-context-live-fail (&rest _) (error "induced"))
   (unwind-protect
       (progn (advice-add 'agent-codex--submit-literal :before
                          #'agent-context-live-fail)
              (agent-context-dispatch))
     (advice-remove 'agent-codex--submit-literal
                    #'agent-context-live-fail))
   ```

   Verify the pending mention was detached (the next manual message
   carries no stray attachment), the draft survived, and retry then
   succeeds with the agent receiving the file once.
8. Dead-target validation, separately: kill the target between compose
   and dispatch; verify the retarget offer and that the draft survives.
9. Busy policy: dispatch at a mid-turn session; verify refusal and that
   the running turn is unaffected.  On app-server, also dispatch in the
   instant after submitting a prompt by hand (turn/start pending):
   verify the readiness gate refuses rather than queueing or steering.

- [ ] **Step 3: Commit any fixes discovered live, one logical change each**
