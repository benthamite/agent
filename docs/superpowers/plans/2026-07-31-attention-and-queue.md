# Attention Inbox and Busy-Input Handling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `agent` a durable attention inbox and three separate,
capability-gated busy-session operations — queue, steer, interrupt — per
`docs/superpowers/specs/2026-07-30-attention-and-queue-design.md`.

**Architecture:** `agent.el` grows a structured session-event contract
(payload plists, a public observer hook, an `error` event, canonical
completions) plus three capability slots and a session-annotation hook.
Two new modules consume that contract: `agent-attention.el` (records,
lifecycle, inbox buffer) and `agent-queue.el` (per-session follow-up
queue, evidence-based draining, durable preservation).  The backends
translate real CLI/protocol signals into payload-bearing events and
register only the capabilities they actually have; `codex.el` (sibling
repo) gains three small public extension points so Agent can observe
app-server notifications, route app-server requests, and read turn state
honestly.

**Tech Stack:** Emacs Lisp 30, `cl-defstruct`, `tabulated-list-mode`,
`transient`, ERT.

## Global Constraints

These apply to every task.  They restate the spec's non-negotiables.

- **Never modify `claude-code.el`.**  The only upstream changes are the
  three `codex.el` additions in Task 10, made in the sibling repo
  `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/codex`.
- **Queue, steer, and interrupt stay separate.**  Never implement steer
  by interrupting and resubmitting.  Never downgrade one operation into
  another silently: if the requested operation is unavailable, signal a
  `user-error` naming what is unavailable and what the alternative is.
- **The backend owns approval policy.**  Agent may present a request and
  route the user's answer back through the backend's own response
  encoding.  Agent never decides an approval, never derives one from a
  model, and never bypasses a native permission mechanism.
- **Never invent backend facts.**  A payload carries only what the
  backend reported.  "Definitively false" and "not known" stay distinct:
  absent detail is absent, not defaulted.  Unknown session state keeps
  rendering as `unknown`.
- **Claude inbox items never get remote approve/deny actions.**  The only
  channel would be blind keystrokes into a dialog whose option order
  Emacs cannot see.  Their action is "jump to the session".
- **All per-session resources register through
  `agent--teardown-functions`** (timers, hooks, watchers, stash
  invalidation).
- **Delivery is non-reentrant.**  No consumer of
  `agent-session-event-functions` may send session input synchronously.
  The queue defers every drain to a zero-delay timer.
- **At-most-once dispatch, enforced by the state machine.**  Only an
  item in the `queued` state is ever dispatched, and **no automatic path
  returns an item to `queued` once it has been sent** — not a failure,
  not a stall, not a resume, not a restart.  Putting an unproven
  delivery back in line is one explicit, confirmed user command.
- **Never submit into a dialog.**  A session that reported `blocked` is
  waiting at a permission or input prompt even though its lifecycle
  state is `awaiting-input`.  Nothing automatic may send text to it.
  The queue checks this itself rather than trusting a backend probe.
- **Bookkeeping before side effects.**  A completion updates the
  deduplication state before running anything that can submit, because
  the before-exit chain submits synchronously and its nested `submit`
  event must not be overwritten by the completion that triggered it.
- **Nothing is lost.**  Queued prompts survive teardown, restart failure,
  and capture-write failure: on any teardown they move to a global stash
  outside the dying buffer and are written to the session's capture file;
  a failed write keeps them stashed in memory, files an error attention
  item, and warns.  Nothing is cleared by elapsed time.
- Defcustom defaults: `agent-queue-stall-seconds` 30,
  `agent-queue-poll-interval` 10.  The spec's `agent-queue-debounce` (2)
  does not exist; deviation 8 explains why.
- **One correlation contract, and it is not a clock.**  Whether a
  completion reports a new turn end is decided once, in
  `agent-session-event`, from facts the backends supply — the turn id
  when there is one, observed work, and otherwise which channel is
  reporting.  Every consumer reads the answer from the delivered
  `:redundant` flag; no consumer re-derives it, and nothing anywhere
  attributes a completion by elapsed time.
- **Events are delivered in the order they happened.**  No side effect
  of delivering an event may deliver another event synchronously: the
  queue drain and the before-exit chain both submit from a zero-delay
  timer, so every consumer sees a completion before it sees anything
  that completion caused.
- All 362+ existing tests keep passing; `make compile` stays
  warning-free in both repos.
- Commit after every task with a single-purpose message.

Run tests with `make test` from the repo root (loads every test file).
Byte-compile with `make compile`.  Both must be clean before each
commit.

## Relationship to the context-composer plan

`docs/superpowers/plans/2026-07-30-context-composer.md` is a separate,
already-converged plan that has **not** been implemented yet (no
`agent-context.el` exists).  The two plans touch three of the same
places.  Do not edit the composer plan; instead follow these rules:

1. **`agent-backend` slots.**  The composer plan adds eight slots,
   including `:ready-to-submit-p` with the contract "function of BUFFER
   returning one of the symbols `ready`, `busy`, `unknown`; `busy` must
   cover every state in which a submission would not start a fresh
   turn".  This plan needs exactly that probe for the queue gate, so it
   defines the **same slot with the same name and the same contract**.
   In Task 2: if `ready-to-submit-p` is already a slot of the
   `agent-backend` struct (composer landed first), do not add it again —
   add only `interrupt`, `steer`, and `steer-p`, and skip the
   `agent-session-ready-to-submit-p` helper only if it also already
   exists.  Task 13 does the opposite for the Codex *registration*, and
   says why: the composer's version answers `busy` for every terminal
   Codex buffer, which would permanently block the queue there.
2. **`agent-session-event`.**  The composer plan adds a `submit-failed`
   event that rolls state back to `awaiting-input`.  This plan adds an
   optional PAYLOAD argument, an `error` event, and completion
   deduplication.  Whichever lands second adds only its own part.  If
   `submit-failed` already exists when Task 1 runs, keep its `pcase`
   branch untouched and treat it as a progress event in
   `agent--session-note-progress` (it means a submission was attempted),
   and add it to the docstring's event list.
3. **`codex-app-server-ready-for-turn-p`.**  The composer plan adds this
   boolean to `codex-app-server.el`.  Task 12 adds
   `codex-app-server-turn-state`, a richer read-only probe.  If
   `codex-app-server-ready-for-turn-p` already exists, leave it exactly
   as it is: do not rewrite it in terms of `turn-state`, do not delete
   it.  The two coexist; `turn-state` is what Agent's queue gate and
   `agent-codex--waiting-p` read, and `ready-for-turn-p` is what the
   composer's `:ready-to-submit-p` registration reads.

## Deliberate deviations from the spec

Each is a design decision made while planning; each is called out here so
the implementer does not "fix" it back.

1. **The Codex app-server request handler is installed by
   `agent-codex-mode`, not by `agent-attention-mode`** (spec §6 says the
   attention mode installs it).  Installing a codex.el-specific handler
   from the generic attention module would invert the module
   dependencies.  Instead `agent-codex-mode` saves the previously
   installed handler and installs one that routes to the inbox **only
   while `agent-attention-mode` is on**, and otherwise delegates to
   codex.el's modal handler.  The user-visible behaviour is exactly what
   the spec describes: no inbox routing without the attention mode, and
   disabling restores the saved value rather than the modal default.
2. **`codex-app-server-turn-state` reports three keys beyond the spec's
   four**: `:process-live`, `:thread-id`, and `:pending-submissions`
   (spec §6 lists `:active`, `:start-pending`, `:queued`, `:turn-id`).
   Without the first two, a dead app-server process and a thread that
   has not started yet are indistinguishable from an idle ready session,
   and every caller reads them as ready.  The third covers the three
   further states in which codex.el defers a submission —
   reasoning-held, reasoning-waiting, and pre-thread-start startup
   submissions.  All three report real state rather than inventing it,
   and the queue gate, the steer precondition, and the before-exit check
   are each wrong without them.  Task 12 amends the spec in the same
   commit.
3. **`:steer-p` returns `t` for "available now", or a reason string, or
   nil.**  The spec only says "non-nil when steering is available".  An
   explicit `t` is required so a backend can hand the command an honest
   refusal reason without the reason itself reading as approval.
4. **A `blocked` event whose payload carries no `:kind` creates no
   attention item.**  Claude's `notify-emacs-state.sh` channel emits bare
   `blocked` events that report *that* the session is waiting but not
   *why*.  Filing an item would require guessing a kind.  The session
   still displays as waiting in the switcher, which is today's
   behaviour.  Documented in the manual as a known gap.
5. **Consumers of `agent-session-event-functions` and
   `agent-session-annotation-functions` run inside `condition-case` and a
   signal is reported with `display-warning`.**  The producers are
   backend CLI hook handlers; a broken observer must not strand the
   backend's own bookkeeping.  This is failure reporting, not a silent
   fallback.
6. **Two explicit commands replace the spec's single "pause" state.**
   The spec forbids *auto*-redispatch but leaves no way back, which
   would strand a prompt forever.  `agent-queue-resume` clears the pause
   and re-arms nothing; `agent-queue-requeue` puts one unproven prompt
   back in line after confirming, naming the risk that it may already
   have been delivered.  Both are user actions, never timers, and
   neither is reachable from an event handler.
7. **A backend-reported `error` event pauses the queue immediately**,
   rather than leaving the dispatched item unresolved until the stall
   timer notices 30 seconds later.  The spec's rule is that a blocked or
   failed session must not receive automatic input; pausing at the
   moment the backend says the turn died reports the actual reason
   instead of a generic stall, and still sends nothing.
8. **Channel identity replaces the spec's `agent-queue-debounce` (2 s),
   which is dropped entirely.**  The spec puts the duplicate guard in
   the queue and sizes it in seconds, but no threshold can work: a
   delayed `idle_prompt` for a turn that ended and the prompt `Stop` of
   a turn that started and finished quickly can arrive at any interval,
   so every value is wrong in one direction or the other — too small and
   duplicates advance the before-exit chain twice, too large and short
   turns are lost.  The same ambiguity governs the before-exit chain,
   which the spec gives no guard at all.  So the question is answered
   once, in `agent-session-event`, from a fact the backends actually
   supply: which channel is reporting.  Each channel reports each turn
   at most once, so a report from a channel that already described the
   recorded turn end is a new turn, and a first report from a second
   channel is the turn the first already described.  No timing is
   involved anywhere, and backends with turn ids short-circuit even
   that.  The residual case is narrow and nameable: a channel wired up
   twice in `settings.json` would report one turn twice and look like
   two turns.  `agent-claude--ensure-hook` already refuses to add a
   command that is present, and the manual says so.
9. **The queue checks for a blocked dialog itself.**  `blocked` leaves
   a session in `awaiting-input`, so the fallback readiness path —
   Claude and terminal Codex, neither of which can see a dialog — would
   report `ready` for a session sitting at a permission prompt, and both
   the drain and the safety-net poll would type the queued prompt into
   it.  Core therefore records *why* a session is waiting
   (`agent--session-awaiting-reason`), `agent-session-ready-to-submit-p`
   never returns `ready` while that reason is `blocked`, and the queue
   gate repeats the check rather than delegating the one condition whose
   failure would put words in the user's mouth.
10. **Codex steering gets its own upstream entry point**
    (`codex-app-server-steer`), beyond the three additions the spec's §6
    lists.  The ordinary submission path dispatches a leading `/` or `!`
    locally, holds text behind pending reasoning, starts a new turn when
    none is running, and re-queues a failed `turn/steer` as a follow-up.
    Reusing it would make "steer" silently become one of four other
    operations, which the spec's own constraint forbids.  The new entry
    point sends literal text to the running turn, refuses every
    ambiguous state, and reports failure through
    `codex-app-server-steer-failed-functions` instead of queueing.
11. **The Codex request handler is called with the JSON-RPC id**
    (five arguments, not four).  It is the only thing that distinguishes
    two outstanding approvals of the same method, which the spec
    explicitly requires to coexist as separate items; keying on the
    method would merge them.
12. **Attention items carry a `fallback`, and disabling the mode uses
    it.**  The spec does not say what happens to a Codex request the
    inbox already accepted responsibility for when the inbox is
    switched off.  Dropping it leaves the session waiting forever, so
    each routed item carries codex.el's own way of asking, and mode
    disable runs it.  An item with no fallback is invalidated with an
    explanation rather than silently abandoned.
13. **A dispatch that produces no turn stalls on elapsed time alone.**
    The spec's stall condition also requires the session to look idle
    ("state stays `awaiting-input`, probes idle"), but a dispatch marks
    the session busy through its own `submit` event, so a session that
    swallowed a submission without starting a turn never looks idle
    again.  Keeping that condition would mean the stall never fires and
    the prompt is stranded silently — the outcome the stall exists to
    prevent.  The check is therefore simply: this item was sent, and no
    backend has reported a turn for it since.
14. **Queue items have five states, not the spec's four.**  `failed` is
    added for a submission call that signaled: like `stalled`, delivery
    is unproven, and the difference from `queued` is what makes
    at-most-once delivery actually hold — no automatic path returns a
    sent item to `queued`, so nothing can resend it.

---

### Task 1: Structured session events

**Files:**
- Modify: `agent.el` (state variables ~line 660; session state machine
  ~lines 1166-1212)
- Test: `test/agent-test.el` (new `;;;; Session event contract` section)

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `agent-session-event BUFFER EVENT &optional PAYLOAD` — the existing
    entry point, now accepting a plist of backend-reported facts.
  - `agent-session-event-functions` — abnormal hook called with
    `(BUFFER EVENT-PLIST)` where EVENT-PLIST is
    `(:type EVENT :time FLOAT :source SYMBOL-or-nil :redundant BOOL
    :payload PLIST-or-nil)`.
  - The `error` event symbol.
  - `agent--session-completion-canonical-p BUFFER PAYLOAD` — the single
    correlation contract; every at-most-once consumer reads its verdict
    through the delivered `:redundant` flag rather than re-deriving it.
  - `agent--before-exit-submit-next-deferred BUFFER` — the chain's
    submission, moved out of event delivery.
  - `agent--session-turn-observed`, `agent--session-completion-sources`,
    `agent--session-completed-turn-id`, `agent--session-awaiting-reason`
    (buffer-local, private).
  - `agent-session-fresh-turn-evidence-p BUFFER` (added in Task 2, but
    fed by the awaiting reason this task records).

- [ ] **Step 1: Write the failing tests**

Add to `test/agent-test.el`, at the end of the file before the final
`(provide ...)` line if there is one, otherwise at the end:

```elisp
;;;; Session event contract

(defun agent-test--event-buffer ()
  "Return a temp buffer set up as a minimal session buffer."
  (let ((buffer (generate-new-buffer " *agent-test-session*")))
    (with-current-buffer buffer
      (setq-local agent--session
                  (agent-session-create :backend 'test
                                        :directory "~/project/")))
    buffer))

(defvar agent-test--clock 1000.0
  "Value `float-time' returns inside `agent-test--with-event-buffer'.")

(defun agent-test--tick (seconds)
  "Advance the test clock by SECONDS."
  (setq agent-test--clock (+ agent-test--clock seconds)))

(defmacro agent-test--with-event-buffer (var &rest body)
  "Bind VAR to a disposable session buffer and run BODY.
Time is frozen and advanced only by `agent-test--tick'.  The completion
contract deliberately does not depend on elapsed time, and the clock is
here to prove it: a test can jump an hour and assert the verdict did
not change."
  (declare (indent 1))
  `(let ((,var (agent-test--event-buffer))
         (agent-test--clock 1000.0))
     (cl-letf (((symbol-function 'float-time)
                (lambda (&optional _time) agent-test--clock)))
       (unwind-protect (progn ,@body)
         (kill-buffer ,var)))))

(ert-deftest agent-test-session-event/legacy-two-argument-calls-work ()
  "A two-argument call still drives the state machine."
  (agent-test--with-event-buffer buf
    (agent-session-event buf 'submit)
    (should (eq (buffer-local-value 'agent--session-state buf) 'busy))
    (agent-session-event buf 'stop)
    (should (eq (buffer-local-value 'agent--session-state buf)
                'awaiting-input))))

(ert-deftest agent-test-session-event/hook-sees-payload-and-source ()
  "The observer hook receives the verbatim payload and its source."
  (agent-test--with-event-buffer buf
    (let* ((seen nil)
           (agent-session-event-functions
            (list (lambda (buffer plist) (push (cons buffer plist) seen)))))
      (agent-session-event buf 'blocked
                           (list :kind 'permission :tool "Bash"
                                 :source 'claude-hook))
      (should (= (length seen) 1))
      (let ((plist (cdr (car seen))))
        (should (eq (car (car seen)) buf))
        (should (eq (plist-get plist :type) 'blocked))
        (should (eq (plist-get plist :source) 'claude-hook))
        (should (numberp (plist-get plist :time)))
        (should (equal (plist-get (plist-get plist :payload) :tool) "Bash"))
        (should (eq (plist-get (plist-get plist :payload) :kind)
                    'permission))))))

(ert-deftest agent-test-session-event/hook-runs-for-ignored-submit ()
  "A `submit' the busy guard ignores is still delivered to the hook."
  (agent-test--with-event-buffer buf
    (let* ((count 0)
           (agent-session-event-functions
            (list (lambda (_buffer plist)
                    (when (eq (plist-get plist :type) 'submit)
                      (cl-incf count))))))
      (agent-session-event buf 'submit)
      (agent-session-event buf 'submit)
      (should (= count 2)))))

(defun agent-test--completion-flags (buf &rest events)
  "Deliver EVENTS to BUF and return the `:redundant' flag of each completion.
Each entry of EVENTS is (TYPE . PAYLOAD)."
  (let* ((flags nil)
         (agent-session-event-functions
          (list (lambda (_buffer plist)
                  (when (memq (plist-get plist :type) '(stop idle-prompt))
                    (push (plist-get plist :redundant) flags))))))
    (dolist (event events)
      (agent-session-event buf (car event) (cdr event)))
    (nreverse flags)))

(ert-deftest agent-test-session-event/second-channel-is-redundant ()
  "Claude's `Stop' hook and its `idle_prompt' describe one turn end."
  (agent-test--with-event-buffer buf
    (should (equal (agent-test--completion-flags
                    buf
                    '(submit)
                    '(stop . (:source claude-stop-hook))
                    '(idle-prompt . (:source claude-idle-notification)))
                   '(nil t)))))

(ert-deftest agent-test-session-event/same-channel-again-is-a-new-turn ()
  "A repeat from the SAME channel can only be a further turn ending.
This is the case a timing rule gets wrong in both directions: a short
turn's own `Stop' can arrive sooner than a delayed duplicate, so no
threshold separates them.  The channel does."
  (agent-test--with-event-buffer buf
    (should (equal (agent-test--completion-flags
                    buf
                    '(submit)
                    '(stop . (:source claude-stop-hook))
                    '(idle-prompt . (:source claude-idle-notification))
                    ;; Second turn, however soon it ends.
                    '(stop . (:source claude-stop-hook))
                    '(idle-prompt . (:source claude-idle-notification))
                    ;; Third turn.
                    '(stop . (:source claude-stop-hook)))
                   '(nil t nil t nil)))))

(ert-deftest agent-test-session-event/late-duplicate-stays-redundant ()
  "An arbitrarily late duplicate is still a duplicate.
The delay is irrelevant: only a report from a channel that has already
described this turn end, or observed work, opens a new turn."
  (agent-test--with-event-buffer buf
    (should (equal (agent-test--completion-flags
                    buf
                    '(submit)
                    '(stop . (:source claude-stop-hook)))
                   '(nil)))
    (agent-test--tick 3600)
    (should (equal (agent-test--completion-flags
                    buf '(idle-prompt . (:source claude-idle-notification)))
                   '(t)))))

(ert-deftest agent-test-session-event/short-turn-is-canonical-immediately ()
  "A turn too short for the status poll to see is reported at once.
Claude suppresses its poll `activity' when a turn starts and ends
between polls, so no observed work exists; the turn's own `Stop' is
nonetheless a report from a channel that already described the previous
turn, which is exactly what makes it canonical."
  (agent-test--with-event-buffer buf
    (should (equal (agent-test--completion-flags
                    buf
                    '(stop . (:source claude-stop-hook))
                    '(idle-prompt . (:source claude-idle-notification))
                    '(submit)
                    ;; The queued turn runs and ends in well under a second.
                    '(stop . (:source claude-stop-hook)))
                   '(nil t nil)))))

(ert-deftest agent-test-session-event/turn-ids-win-outright ()
  "A transport with turn ids correlates without channel or timing rules."
  (agent-test--with-event-buffer buf
    (should (equal (agent-test--completion-flags
                    buf
                    '(submit)
                    '(idle-prompt . (:turn-id "t1" :source codex-app-server))
                    '(stop . (:turn-id "t1" :source codex-stop-hook))
                    '(submit)
                    '(idle-prompt . (:turn-id "t2" :source codex-app-server)))
                   '(nil t nil)))))

(ert-deftest agent-test-session-event/untagged-completions-are-canonical ()
  "A producer that names no channel gets no cross-channel deduplication."
  (agent-test--with-event-buffer buf
    (should (equal (agent-test--completion-flags
                    buf '(stop) '(stop) '(stop))
                   '(nil nil nil)))))

(ert-deftest agent-test-session-event/observed-work-clears-the-channels ()
  "Observed work makes the next report from any channel a new turn."
  (agent-test--with-event-buffer buf
    (should (equal (agent-test--completion-flags
                    buf
                    '(stop . (:source claude-stop-hook))
                    '(activity)
                    ;; A different channel would be redundant without the
                    ;; observed work in between.
                    '(idle-prompt . (:source claude-idle-notification))
                    '(blocked . (:kind permission))
                    '(idle-prompt . (:source claude-idle-notification)))
                   '(nil nil nil)))))

(ert-deftest agent-test-session-event/redundant-completion-keeps-alerts ()
  "A redundant `idle-prompt' still fires the ready alert."
  (agent-test--with-event-buffer buf
    (let ((alerts 0))
      (cl-letf (((symbol-function 'agent--session-notify-ready)
                 (lambda (_buffer) (cl-incf alerts)))
                ((symbol-function 'agent--scroll-to-bottom) #'ignore)
                ((symbol-function 'agent--refresh-display-names-deferred)
                 #'ignore))
        (agent-session-event buf 'submit)
        (agent-session-event buf 'stop '(:source claude-stop-hook))
        (agent-session-event buf 'idle-prompt
                             '(:source claude-idle-notification))
        ;; The notification is redundant, yet it is the alert carrier.
        (should (= alerts 1))))))

(ert-deftest agent-test-session-event/redundant-completion-skips-before-exit ()
  "A redundant completion does not advance the before-exit chain."
  (agent-test--with-event-buffer buf
    (let ((steps 0))
      (cl-letf (((symbol-function 'agent--before-exit-transition)
                 (lambda (_buffer event)
                   (when (eq event 'step) (cl-incf steps))
                   nil))
                ((symbol-function 'agent--scroll-to-bottom) #'ignore)
                ((symbol-function 'agent--refresh-display-names-deferred)
                 #'ignore))
        (agent-session-event buf 'submit)
        (agent-session-event buf 'stop '(:source claude-stop-hook))
        (agent-session-event buf 'idle-prompt
                             '(:source claude-idle-notification))
        (should (= steps 1))))))

(ert-deftest agent-test-session-event/error-waits-without-alert ()
  "An `error' event waits for input, alerts nothing, advances nothing."
  (agent-test--with-event-buffer buf
    (let ((alerts 0) (steps 0))
      (cl-letf (((symbol-function 'agent--session-notify-ready)
                 (lambda (_buffer) (cl-incf alerts)))
                ((symbol-function 'agent--before-exit-transition)
                 (lambda (_buffer event)
                   (when (eq event 'step) (cl-incf steps))
                   nil))
                ((symbol-function 'agent--scroll-to-bottom) #'ignore)
                ((symbol-function 'agent--refresh-display-names-deferred)
                 #'ignore))
        (agent-session-event buf 'submit)
        (agent-session-event buf 'error '(:error "rate_limit"))
        (should (eq (buffer-local-value 'agent--session-state buf)
                    'awaiting-input))
        (should (= alerts 0))
        (should (= steps 0))))))

(ert-deftest agent-test-session-event/error-is-terminal ()
  "A completion following an `error' duplicates a turn already reported.
Claude's `StopFailure' and `Stop' are different channels reporting the
same turn ending, so the second is redundant."
  (agent-test--with-event-buffer buf
    (should (equal (agent-test--completion-flags
                    buf
                    '(submit)
                    '(error . (:error "rate_limit"
                                      :source claude-stop-failure-hook))
                    '(stop . (:source claude-stop-hook)))
                   '(t)))))

(ert-deftest agent-test-session-event/records-the-awaiting-reason ()
  "The reason a session is waiting is recorded and cleared by progress."
  (agent-test--with-event-buffer buf
    (agent-session-event buf 'blocked '(:kind permission))
    (should (eq (buffer-local-value 'agent--session-awaiting-reason buf)
                'blocked))
    (agent-session-event buf 'stop)
    (should (eq (buffer-local-value 'agent--session-awaiting-reason buf)
                'stop))
    (agent-session-event buf 'submit)
    (should (null (buffer-local-value 'agent--session-awaiting-reason buf)))))

(ert-deftest agent-test-session-event/redundant-completion-keeps-the-reason ()
  "A duplicate completion cannot overwrite an `error' as the reason.
Otherwise the delayed `idle_prompt' of the very turn that died would
read as fresh evidence that a new turn may start."
  (agent-test--with-event-buffer buf
    (agent-session-event buf 'submit)
    (agent-session-event buf 'error
                         '(:error "rate_limit"
                                  :source claude-stop-failure-hook))
    (agent-session-event buf 'stop '(:source claude-stop-hook))
    (should (eq (buffer-local-value 'agent--session-awaiting-reason buf)
                'error))
    (should-not (agent-session-fresh-turn-evidence-p buf))))

(defmacro agent-test--with-before-exit-chain (buf skills submitted &rest body)
  "Run BODY with BUF driving a before-exit chain over SKILLS.
Each submitted command is pushed onto SUBMITTED, newest first.  Timers
run immediately, because the chain now submits from one."
  (declare (indent 3))
  `(let ((agent-backends nil))
     (apply #'agent-register-backend 'test
            (agent-test--backend
             :buffer-p (lambda (b) (eq b ,buf))
             :skill-command-prefix "/"
             :submit (lambda (text _b) (push text ,submitted))))
     (with-current-buffer ,buf (setq-local agent--backend 'test))
     (cl-letf (((symbol-function 'agent--scroll-to-bottom) #'ignore)
               ((symbol-function 'agent--refresh-display-names-deferred)
                #'ignore)
               ((symbol-function 'agent--session-notify-ready) #'ignore)
               ((symbol-function 'agent--before-exit-skill-queue)
                (lambda (&rest _) ,skills))
               ((symbol-function 'run-at-time)
                (lambda (_secs _rep fn &rest args) (apply fn args) nil))
               ((symbol-function 'message) #'ignore))
       ,@body)))

(ert-deftest agent-test-session-event/before-exit-chain-advances-per-turn ()
  "Each skill's own turn ending advances the chain exactly once."
  (agent-test--with-event-buffer buf
    (let ((submitted nil))
      (agent-test--with-before-exit-chain buf '("first" "second") submitted
        (agent-session-event buf 'submit)
        ;; Starting the chain submits the first skill and delays the exit,
        ;; so the command returns nil.
        (should-not (agent-run-skill-before-exit 'test buf))
        (agent-session-event buf 'stop '(:source claude-stop-hook))
        (agent-session-event buf 'stop '(:source claude-stop-hook)))
      (should (equal (nreverse submitted) '("/first" "/second")))
      (should (eq (buffer-local-value 'agent--session-state buf) 'closing)))))

(ert-deftest agent-test-session-event/before-exit-ignores-a-late-duplicate ()
  "A duplicate cannot advance the before-exit chain a second time.
The first completion advances the chain, which submits the next skill.
Claude's `idle_prompt' for the turn that just ended arrives afterwards
-- at any delay whatsoever -- and must not be read as that new skill's
completion, or the chain would skip a skill and close early."
  (agent-test--with-event-buffer buf
    (let ((submitted nil))
      (agent-test--with-before-exit-chain buf '("first" "second" "third")
          submitted
        (agent-session-event buf 'submit)
        (should-not (agent-run-skill-before-exit 'test buf))
        ;; The first skill's turn ends; the chain submits the second.
        (agent-session-event buf 'stop '(:source claude-stop-hook))
        ;; The notification for that same turn arrives an hour later.
        (agent-test--tick 3600)
        (agent-session-event buf 'idle-prompt
                             '(:source claude-idle-notification)))
      (should (equal (nreverse submitted) '("/first" "/second")))
      (should-not (eq (buffer-local-value 'agent--session-state buf)
                      'closing)))))

(ert-deftest agent-test-session-event/before-exit-submits-after-delivery ()
  "The completion reaches every observer before the chain's submission.
The chain used to submit synchronously from inside completion delivery,
so observers saw the nested `submit' before the completion that caused
it -- and a consumer that acts on completions could act on a session
state the completion had not yet been applied to."
  (agent-test--with-event-buffer buf
    (let ((submitted nil)
          (seen nil)
          (pending nil))
      (let ((agent-session-event-functions
             (list (lambda (_b plist) (push (plist-get plist :type) seen)))))
        (agent-test--with-before-exit-chain buf '("first" "second") submitted
          (cl-letf (((symbol-function 'run-at-time)
                     (lambda (_secs _rep fn &rest args)
                       (push (cons fn args) pending) nil)))
            (agent-session-event buf 'submit)
            (should-not (agent-run-skill-before-exit 'test buf))
            (setq seen nil)
            (setq pending nil)
            (agent-session-event buf 'stop '(:source claude-stop-hook))
            ;; The completion has been delivered and nothing was submitted.
            (should (equal seen '(stop)))
            (should (= (length submitted) 1))
            ;; Only now does the deferred submission run.
            (dolist (job (nreverse pending)) (apply (car job) (cdr job)))
            (should (equal (nreverse seen) '(stop submit)))
            (should (= (length submitted) 2))))))))

(ert-deftest agent-test-session-event/consumer-signal-does-not-stop-others ()
  "A signaling consumer is reported and the rest still run."
  (agent-test--with-event-buffer buf
    (let* ((reached nil)
           (agent-session-event-functions
            (list (lambda (_b _p) (error "boom"))
                  (lambda (_b _p) (setq reached t)))))
      (cl-letf (((symbol-function 'display-warning) #'ignore))
        (agent-session-event buf 'stop))
      (should reached))))

(ert-deftest agent-test-session-event/unknown-event-still-signals ()
  "An unknown event symbol is still an error."
  (agent-test--with-event-buffer buf
    (should-error (agent-session-event buf 'bogus))))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test`
Expected: the new tests fail — `agent-session-event` takes two
arguments, `agent-session-event-functions` is void, and `error` is an
unknown event.

- [ ] **Step 3: Implement the contract**

In `agent.el`, add next to the other state variables (after
`agent--session-state-changed-at`, ~line 668):

```elisp
(defvar-local agent--session-turn-observed nil
  "Non-nil when work was observed since this session's last turn ended.
Set by `activity' and `blocked' events, cleared by a canonical
completion or an `error'.  Only `agent-session-event' may set this
variable.")

(defvar-local agent--session-completion-sources nil
  "Channels that have already reported the current turn's end.
Each backend channel that can report a turn ending names itself in its
payload's `:source', and each reports any one turn at most once: Claude
Code's `Stop' hook fires once per turn and its `idle_prompt'
notification fires once per turn, and the same holds for the Codex
app-server's `turn/completed' and the Codex CLI's `Stop' hook.  A
second channel reporting while this list is non-empty is therefore
describing the turn already recorded, while the SAME channel reporting
again can only mean a further turn has ended.

That is what replaces guessing from elapsed time.  Cleared by observed
work -- `activity' or `blocked' -- because a turn that demonstrably
started makes the next report from any channel a new one.  Only
`agent-session-event' may set this variable.")

(defvar-local agent--session-completed-turn-id nil
  "Turn id of this session's last canonical completion, or nil.
Lets a transport that reports turn ids recognize a repeat of the same
turn without any timing at all.  Only `agent-session-event' may set
this variable.")

(defvar-local agent--session-awaiting-reason nil
  "Why this session is waiting on the user, or nil when it is not.
One of the symbols `stop', `idle-prompt', `blocked', and `error', set
whenever the session transitions to `awaiting-input'.  `awaiting-input'
alone cannot distinguish a CLI back at a fresh prompt from one sitting
in a permission dialog, and text sent into the second case answers the
dialog instead of starting a turn.  Only `agent-session-event' may set
this variable.")
```

Add the public hook next to `agent-session-id-functions` (~line 452) or
in the customization block — put it immediately before the session state
machine section so it reads next to its documentation:

```elisp
(defcustom agent-session-event-functions nil
  "Abnormal hook run for every delivered session event.
Each function is called with two arguments: the session BUFFER and an
EVENT-PLIST with these keys:

  `:type'       the event symbol (`stop', `idle-prompt', `blocked',
                `submit', `activity', `error', `exit-request').
  `:time'       `float-time' when the event was delivered.
  `:source'     the producer named in the event payload's `:source',
                or nil when the producer named none.
  `:redundant'  non-nil for a completion event delivered with no
                `submit', `activity', `blocked', or `error' observed
                since the previous completion.  Consumers that must
                act at most once per turn ignore these.
  `:payload'    the backend-reported payload plist, verbatim, or nil.

The hook runs after core has applied the event to the session state,
for every delivered event -- including a `submit' the busy-state guard
ignored and a redundant completion -- so consumers see the raw stream
and filter on the flags themselves.

Delivery is non-reentrant: a consumer must not send session input
synchronously, because the resulting nested `submit' event would make
correctness depend on hook order.  Defer such work to a zero-delay
timer.  A consumer that signals is reported with `display-warning' and
does not prevent the remaining consumers from running."
  :type 'hook
  :group 'agent)
```

Replace `agent-session-event` and `agent--session-event-awaiting-input`
(lines 1168-1206) with:

```elisp
(defun agent-session-event (buffer event &optional payload)
  "Apply session EVENT to BUFFER's state machine.
EVENT is one of the symbols `stop', `idle-prompt', `blocked', `submit',
`activity', `error', and `exit-request'.  A `blocked' event marks the
session as waiting on the user without firing a ready alert, for cases
where the backend has already alerted, such as a permission or input
dialog.  An `error' event reports that a turn ended abnormally: like
`blocked' it leaves the CLI back at its prompt and fires no ready
alert.  An `activity' event marks the session busy on evidence that it
is working, for backends whose CLI reports no turn start.

PAYLOAD is an optional plist of backend-reported facts, such as
\(:kind permission :tool \"Bash\" :message MSG :error CODE :request-id
ID :turn-id ID :source SOURCE).  Core copies it verbatim and never
synthesizes backend facts.  After the state transition, core runs
`agent-session-event-functions' with BUFFER and an event plist built
from EVENT, PAYLOAD, and the redundancy flag.

This function is the single owner of `agent--session-state'; backends
translate raw CLI events into calls to it and never set session state
directly.  A `submit' event delivered while BUFFER is already busy is
ignored by the state machine, because backend submission hooks can fire
multiple times per submission and on submissions that start no turn;
the observer hook still sees it."
  (when (buffer-live-p buffer)
    (let ((redundant (agent--session-event-redundant-p buffer event payload)))
      ;; Bookkeeping first, side effects second, and no side effect may
      ;; deliver another event: the before-exit chain now defers its
      ;; submission to a zero-delay timer (see
      ;; `agent--before-exit-submit-next-deferred'), so every consumer
      ;; sees this completion before it sees anything the completion
      ;; caused.  Events are therefore delivered in the order they
      ;; happened, never nested.
      (agent--session-note-progress buffer event payload redundant)
      (pcase event
        ((or 'stop 'idle-prompt 'blocked 'error)
         (agent--session-event-awaiting-input buffer event redundant))
        ((or 'submit 'activity)
         (with-current-buffer buffer (setq agent--session-awaiting-reason nil))
         (unless (eq (buffer-local-value 'agent--session-state buffer) 'busy)
           (agent--session-set-state buffer 'busy)))
        ('exit-request
         (agent--session-set-state buffer 'closing))
        (_ (error "Unknown agent session event: %s" event)))
      (agent--run-session-event-functions
       buffer
       (list :type event
             :time (float-time)
             :source (plist-get payload :source)
             :redundant redundant
             :payload payload)))))

(defun agent--session-event-redundant-p (buffer event payload)
  "Return non-nil when EVENT is a completion BUFFER already reported.
See `agent--session-completion-canonical-p' for the contract."
  (and (memq event '(stop idle-prompt))
       (not (agent--session-completion-canonical-p buffer payload))))

(defun agent--session-completion-canonical-p (buffer payload)
  "Return non-nil when a completion with PAYLOAD reports a new turn end.
This is the single correlation contract every at-most-once consumer
depends on.  One finished turn can produce several completion events --
Claude's `Stop' hook followed by an `idle_prompt' notification seconds
later, or the Codex app-server's `turn/completed' followed by the CLI
`Stop' hook -- and a completion that merely repeats a turn already
reported must not advance the before-exit chain or resolve a queued
prompt a second time.  In order:

1. A completion carrying a turn id is canonical when that id differs
   from the last one completed.  This is authoritative: only Codex
   app-server supplies it.
2. Otherwise, observed work since the last canonical completion --
   `activity' or `blocked' -- proves a new turn ran, so its end is
   canonical.
3. Otherwise the verdict comes from which CHANNEL is reporting, not
   from how long ago anything happened.  A completion is canonical when
   its `:source' has already reported the recorded turn end, or when no
   channel has reported it yet; it is redundant when a different
   channel reported first.  Each channel reports each turn at most
   once, so a repeat from the same channel can only be a further turn,
   and a first report from a second channel can only be the turn the
   first channel already reported.

Rule 3 is deliberately not a clock.  Elapsed time cannot separate
Claude's delayed `idle_prompt' for a turn that already ended from the
prompt `Stop' of a turn that started and finished quickly -- both can
arrive at any interval -- so any threshold is wrong in one direction or
the other.  The channel identity is a fact the backends actually
supply, and it separates the two exactly.

Claude's statusline `prompt_id' is deliberately NOT used as a
completion's turn id.  The poll reports the id current at poll time,
not the id of the turn a given completion is describing, so stamping
completions with it would misattribute precisely the delayed-duplicate
case this contract exists to catch.

A producer that names no `:source' is treated as its own channel, so
untagged completions are always canonical: no channel identity means no
cross-channel deduplication.  Every adapter in this package names one,
and Tasks 13 and 14 fix the names."
  (let ((turn (plist-get payload :turn-id))
        (source (plist-get payload :source)))
    (with-current-buffer buffer
      (cond
       (turn (not (equal turn agent--session-completed-turn-id)))
       (agent--session-turn-observed t)
       ((null agent--session-completion-sources) t)
       ((member source agent--session-completion-sources) t)
       (t nil)))))

(defun agent--session-note-progress (buffer event payload redundant)
  "Record EVENT and PAYLOAD in BUFFER's completion-correlation state.
REDUNDANT is the verdict already computed for EVENT, passed in rather
than recomputed so the recorded state and the delivered flag can never
disagree.
`activity' and `blocked' are observed work: they prove a turn is
running, so the next report from any channel is a new one and the
recorded channel list is cleared.  `submit' records nothing at all --
the spec is explicit that a submission may duplicate another or start
no turn, so it is not evidence about turns.

A canonical completion or an `error' ends a turn: it clears the
observed flag, records the completed turn id, and makes the reporting
channel the only one credited with that turn.  A redundant completion
adds its channel to the list instead, so a third channel reporting the
same turn is redundant too, and a repeat from any of them is a new
turn."
  (with-current-buffer buffer
    (pcase event
      ((or 'activity 'blocked)
       (setq agent--session-turn-observed t)
       (setq agent--session-completion-sources nil))
      ('submit nil)
      ((or 'stop 'idle-prompt 'error)
       (if redundant
           (cl-pushnew (plist-get payload :source)
                       agent--session-completion-sources :test #'equal)
         (setq agent--session-turn-observed nil)
         (setq agent--session-completion-sources
               (list (plist-get payload :source)))
         (setq agent--session-completed-turn-id
               (plist-get payload :turn-id)))))))

(defun agent--run-session-event-functions (buffer event-plist)
  "Run `agent-session-event-functions' with BUFFER and EVENT-PLIST.
Each consumer runs inside its own `condition-case', because the
producers are backend CLI hook handlers and a broken observer must not
strand the backend's own bookkeeping."
  (run-hook-wrapped
   'agent-session-event-functions
   (lambda (fn)
     (condition-case err
         (funcall fn buffer event-plist)
       (error
        (display-warning
         'agent
         (format "session event consumer %S signaled: %S" fn err)
         :warning)))
     nil)))

(defun agent--session-event-awaiting-input (buffer event redundant)
  "Transition BUFFER to `awaiting-input' and run the ready side effects.
EVENT is `stop', `idle-prompt', `blocked', or `error'.  A canonical
completion advances the before-exit chain first; when the chain
consumes the event, the ready alert, scrolling, and display-name
refresh are suppressed.  REDUNDANT non-nil means the completion
duplicates one already reported for the same turn, so it must not
advance the chain a second time; the ready alert, scrolling, and
display-name refresh still run, because the Claude `idle_prompt'
channel is by design the alert carrier and may legitimately repeat.
`blocked' and `error' events never advance the chain, and the ready
alert fires only for `idle-prompt'.

EVENT is also recorded as BUFFER's awaiting reason, because
`awaiting-input' alone does not say whether the CLI is back at a fresh
prompt or sitting in a permission dialog, and callers that are about to
send text need to tell those apart."
  (agent--session-set-state buffer 'awaiting-input)
  (with-current-buffer buffer
    ;; A redundant completion must not overwrite the reason: if the turn
    ;; ended with `error', the delayed duplicate of that same turn would
    ;; otherwise look like fresh evidence that a new turn may start.
    (unless (and (memq event '(stop idle-prompt)) redundant)
      (setq agent--session-awaiting-reason event)))
  (unless (and (memq event '(stop idle-prompt))
               (not redundant)
               (agent--before-exit-transition buffer 'step))
    (when (eq event 'idle-prompt)
      (agent--session-notify-ready buffer))
    (agent--scroll-to-bottom buffer)
    (agent--refresh-display-names-deferred)))
```

If the composer plan's `submit-failed` branch is already present, keep
it in the `pcase`, add `submit-failed` to the docstring's event list,
and give it the same no-op branch in `agent--session-note-progress`
that `submit` has.

Finally, stop the before-exit chain from submitting from inside event
delivery.  In `agent--before-exit-step` (agent.el ~line 1626), replace
the synchronous submit-or-close with a deferred one:

```elisp
(defun agent--before-exit-step (buffer)
  "Advance BUFFER's running before-exit chain on a completion event.
Returns non-nil when the chain consumed the event.  The next skill is
submitted from a zero-delay timer rather than here, so the completion
that advanced the chain reaches every session-event consumer before the
submission delivers its own `submit' event; nesting the two reversed
their order for every observer."
  (when (eq (plist-get agent--before-exit :state) 'running)
    (let ((backend (agent--detect-backend buffer)))
      (when (agent--before-exit-ready-to-close-p backend buffer)
        (if (plist-get agent--before-exit :queue)
            (progn
              (agent--before-exit-restart-watchdog buffer)
              (run-at-time 0 nil #'agent--before-exit-submit-next-deferred
                           buffer)
              t)
          (agent--before-exit-close buffer backend))))))

(defun agent--before-exit-submit-next-deferred (buffer)
  "Submit BUFFER's next before-exit skill, or close when none remains.
Runs from the timer `agent--before-exit-step' scheduled.  Re-checks the
chain state, because the session may have been torn down or the chain
abandoned in between."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and agent--before-exit
                 (eq (plist-get agent--before-exit :state) 'running))
        (unless (agent--before-exit-submit-next buffer)
          (agent--before-exit-close buffer (agent--detect-backend buffer)))))))
```

The queue already defers its drain the same way, so after this change
no consumer of `agent-session-event-functions` can observe a nested
event, and the deferral rule is uniform rather than a queue-only
convention.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test` — every test passes, including all pre-existing ones.
Run: `make compile` — no warnings.

- [ ] **Step 5: Commit**

```bash
git add agent.el test/agent-test.el
git commit -m "agent: add structured session events and canonical completions"
```

---

### Task 2: Capability slots, readiness probe, and session annotations

**Files:**
- Modify: `agent.el` (`agent-backend` defstruct ~line 123;
  `agent--session-suffix-spec` ~line 971; a new
  `agent-session-ready-to-submit-p` next to `agent-session-display-state`
  ~line 1000)
- Test: `test/agent-test.el`

**Interfaces:**
- Consumes: Task 1's event contract (not directly).
- Produces:
  - New optional `agent-backend` slots and accessors:
    `agent-backend-interrupt` (BUFFER), `agent-backend-steer`
    (TEXT BUFFER), `agent-backend-steer-p` (BUFFER),
    `agent-backend-ready-to-submit-p` (BUFFER).
  - `agent-session-ready-to-submit-p BUFFER &optional BACKEND` →
    `ready` | `busy` | `unknown`.  Never `ready` for a session that last
    reported `blocked`.
  - `agent--session-dialog-blocked-p BUFFER` → non-nil while the session
    last reported `blocked`.
  - `agent-session-fresh-turn-evidence-p BUFFER` → non-nil only after a
    canonical `stop` or `idle-prompt`.
  - `agent-session-can-start-turn-p BUFFER &optional BACKEND` → the
    positive gate every automatic sender must pass.
  - `agent--backend-reports-readiness-p BACKEND` → non-nil when the
    backend registers a protocol readiness probe.
  - `agent-session-annotation-functions` — abnormal hook, BUFFER →
    string or nil.
  - `agent--backend-label BACKEND` → string.

- [ ] **Step 1: Write the failing tests**

Add to `test/agent-test.el`:

```elisp
;;;; Capability slots and annotations

(ert-deftest agent-test-backend/accepts-capability-slots ()
  "Registration accepts the interrupt, steer, and readiness slots."
  (let ((agent-backends nil))
    (apply #'agent-register-backend 'cap
           (agent-test--backend
            :interrupt #'ignore
            :steer #'ignore
            :steer-p #'ignore
            :ready-to-submit-p #'ignore))
    (let ((struct (agent-backend 'cap)))
      (should (agent-backend-interrupt struct))
      (should (agent-backend-steer struct))
      (should (agent-backend-steer-p struct))
      (should (agent-backend-ready-to-submit-p struct)))))

(ert-deftest agent-test-ready-to-submit/prefers-the-backend-probe ()
  "A registered probe wins over the state machine."
  (agent-test--with-event-buffer buf
    (let ((agent-backends nil))
      (apply #'agent-register-backend 'probe
             (agent-test--backend
              :buffer-p (lambda (b) (eq b buf))
              :ready-to-submit-p (lambda (_b) 'busy)))
      (agent-session-event buf 'stop)
      (should (eq (agent-session-ready-to-submit-p buf 'probe) 'busy)))))

(ert-deftest agent-test-ready-to-submit/falls-back-to-state ()
  "Without a probe, an awaiting-input session is ready."
  (agent-test--with-event-buffer buf
    (let ((agent-backends nil))
      (apply #'agent-register-backend 'plain
             (agent-test--backend :buffer-p (lambda (b) (eq b buf))))
      (should (eq (agent-session-ready-to-submit-p buf 'plain) 'unknown))
      (agent-session-event buf 'stop)
      (should (eq (agent-session-ready-to-submit-p buf 'plain) 'ready))
      (agent-session-event buf 'submit)
      (should (eq (agent-session-ready-to-submit-p buf 'plain) 'unknown)))))

(ert-deftest agent-test-ready-to-submit/busy-p-reports-busy ()
  "A backend reporting busy work is not ready even when awaiting input."
  (agent-test--with-event-buffer buf
    (let ((agent-backends nil))
      (apply #'agent-register-backend 'busybackend
             (agent-test--backend
              :buffer-p (lambda (b) (eq b buf))
              :busy-p (lambda (_b) t)))
      (agent-session-event buf 'stop)
      (should (eq (agent-session-ready-to-submit-p buf 'busybackend)
                  'busy)))))

(ert-deftest agent-test-ready-to-submit/blocked-is-never-ready ()
  "A session sitting in a permission dialog is never ready to submit."
  (agent-test--with-event-buffer buf
    (let ((agent-backends nil))
      (apply #'agent-register-backend 'dialog
             (agent-test--backend :buffer-p (lambda (b) (eq b buf))))
      (agent-session-event buf 'blocked '(:kind permission))
      ;; `blocked' transitions to `awaiting-input', which the fallback
      ;; path would otherwise read as ready.
      (should (eq (buffer-local-value 'agent--session-state buf)
                  'awaiting-input))
      (should (eq (agent-session-ready-to-submit-p buf 'dialog) 'busy))
      (agent-session-event buf 'stop)
      (should (eq (agent-session-ready-to-submit-p buf 'dialog) 'ready)))))

(ert-deftest agent-test-ready-to-submit/blocked-overrides-a-backend-probe ()
  "A blocked session is busy even when the backend probe says ready."
  (agent-test--with-event-buffer buf
    (let ((agent-backends nil))
      (apply #'agent-register-backend 'optimistic
             (agent-test--backend
              :buffer-p (lambda (b) (eq b buf))
              :ready-to-submit-p (lambda (_b) 'ready)))
      (agent-session-event buf 'blocked '(:kind question))
      (should (eq (agent-session-ready-to-submit-p buf 'optimistic) 'busy)))))

(ert-deftest agent-test-can-start-turn/needs-positive-evidence ()
  "Without a protocol probe, only a canonical completion opens the gate."
  (agent-test--with-event-buffer buf
    (let ((agent-backends nil))
      (apply #'agent-register-backend 'unprobed
             (agent-test--backend :buffer-p (lambda (b) (eq b buf))))
      ;; Nothing reported yet: no evidence, so no automatic send.
      (should-not (agent-session-can-start-turn-p buf 'unprobed))
      (agent-session-event buf 'stop)
      (should (agent-session-can-start-turn-p buf 'unprobed))
      ;; A failed turn leaves the session in `awaiting-input', which the
      ;; fallback readiness path reads as ready -- the evidence clause is
      ;; what refuses it.
      (agent-session-event buf 'error
                           '(:error "rate_limit"
                                    :source claude-stop-failure-hook))
      (should (eq (agent-session-ready-to-submit-p buf 'unprobed) 'ready))
      (should-not (agent-session-can-start-turn-p buf 'unprobed))
      ;; The duplicate of that dead turn, from the other channel, is not
      ;; new evidence however late it arrives.
      (agent-test--tick 3600)
      (agent-session-event buf 'stop '(:source claude-stop-hook))
      (should-not (agent-session-can-start-turn-p buf 'unprobed)))))

(ert-deftest agent-test-can-start-turn/protocol-probe-is-evidence ()
  "A backend that answers from a protocol probe needs no event history."
  (agent-test--with-event-buffer buf
    (let ((agent-backends nil))
      (apply #'agent-register-backend 'probed
             (agent-test--backend
              :buffer-p (lambda (b) (eq b buf))
              :ready-to-submit-p (lambda (_b) 'ready)))
      (should (agent-session-can-start-turn-p buf 'probed))
      (agent-session-event buf 'blocked '(:kind permission))
      (should-not (agent-session-can-start-turn-p buf 'probed)))))

(ert-deftest agent-test-annotations/concatenates-every-result ()
  "All non-nil annotations appear after the label, space-separated."
  (agent-test--with-event-buffer buf
    (let* ((agent-backends nil)
           (agent-session-annotation-functions
            (list (lambda (_b) "!")
                  (lambda (_b) nil)
                  (lambda (_b) "3"))))
      (apply #'agent-register-backend 'ann
             (agent-test--backend :buffer-p (lambda (b) (eq b buf))))
      (cl-letf (((symbol-function 'agent-display-name)
                 (lambda (&optional _b) "project"))
                ((symbol-function 'agent-backend-icon-string)
                 (lambda (&rest _) "")))
        (let ((spec (agent--session-suffix-spec buf "a")))
          (should (equal (nth 1 spec) "project ! 3")))))))

(ert-deftest agent-test-annotations/signaling-function-is-skipped ()
  "A signaling annotation function does not break the label."
  (agent-test--with-event-buffer buf
    (let* ((agent-backends nil)
           (agent-session-annotation-functions
            (list (lambda (_b) (error "boom"))
                  (lambda (_b) "•"))))
      (apply #'agent-register-backend 'ann2
             (agent-test--backend :buffer-p (lambda (b) (eq b buf))))
      (cl-letf (((symbol-function 'agent-display-name)
                 (lambda (&optional _b) "project"))
                ((symbol-function 'agent-backend-icon-string)
                 (lambda (&rest _) ""))
                ((symbol-function 'display-warning) #'ignore))
        (should (equal (nth 1 (agent--session-suffix-spec buf "a"))
                       "project •"))))))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test`
Expected: failures — unknown slot keywords, void
`agent-session-ready-to-submit-p`, void
`agent-session-annotation-functions`.

- [ ] **Step 3: Implement the slots, probe, and annotations**

Extend the `agent-backend` defstruct slot list (line 127-137) by adding
one line before `before-exit-ready-to-close-p`:

```elisp
  interrupt steer steer-p ready-to-submit-p
```

If `ready-to-submit-p` is already present from the composer work, add
only `interrupt steer steer-p`.

Extend the `agent-register-backend` docstring with a paragraph:

```
Backends that expose busy-session operations provide the optional
capability keys.  `:interrupt' is a function of BUFFER performing the
backend's authoritative native interrupt; it stops the current turn and
does nothing else.  `:steer' is a function of TEXT and BUFFER
performing native same-turn steering, and `:steer-p' is a function of
BUFFER returning t when steering is available for that buffer right
now, a string explaining why it is not, or nil for an unexplained
refusal; a backend with no steering operation registers neither slot.
`:ready-to-submit-p' is a function of BUFFER returning one of the
symbols `ready', `busy', and `unknown'; `busy' must cover every state
in which a submission would not start a fresh turn, including an active
turn, a pending turn start, and queued input the backend will flush
first.
```

Add after `agent--backend-background-tasks-p` (~line 1049):

```elisp
(defun agent--backend-label (backend)
  "Return BACKEND's human-readable label.
Falls back to BACKEND's symbol name, then to \"Session\"."
  (or (when-let* ((struct (and backend (agent-backend backend))))
        (agent-backend-label struct))
      (and backend (symbol-name backend))
      "Session"))

(defun agent-session-ready-to-submit-p (buffer &optional backend)
  "Return whether a submission to BUFFER would start a fresh turn.
The result is one of the symbols `ready', `busy', and `unknown'.
BACKEND defaults to the detected backend.

A session that last reported `blocked' is never `ready', whatever any
probe says: `awaiting-input' covers both a CLI back at a fresh prompt
and a CLI sitting in a permission dialog, and text sent into the second
case answers the dialog instead of starting a turn.  This check comes
first because the fallback path -- Claude and terminal Codex, neither
of which can see a dialog -- would otherwise report `ready' for exactly
that state.

Otherwise, backends that observe a protocol answer authoritatively
through `:ready-to-submit-p', and that answer wins; a probe returning
anything else is treated as `unknown'.  Failing that, a backend
reporting `:busy-p' is `busy', a session the state machine has seen
stop is `ready', and a session whose state was never observed stays
`unknown' rather than being guessed at."
  (let* ((backend (or backend (agent--detect-backend buffer)))
         (struct (and backend (agent-backend backend)))
         (probe (and struct (agent-backend-ready-to-submit-p struct))))
    (cond
     ((agent--session-dialog-blocked-p buffer) 'busy)
     (probe (let ((verdict (funcall probe buffer)))
              (if (memq verdict '(ready busy unknown)) verdict 'unknown)))
     ((agent--backend-busy-p buffer backend) 'busy)
     ((eq (buffer-local-value 'agent--session-state buffer) 'awaiting-input)
      'ready)
     (t 'unknown))))

(defun agent--session-dialog-blocked-p (buffer)
  "Return non-nil when BUFFER last reported it is waiting on the user.
A `blocked' report means the CLI is not at a fresh prompt: it is
showing a permission or input dialog, and anything typed answers that
dialog.  The flag clears as soon as the session reports progress or a
canonical completion, so a dialog the user answers in the terminal
releases it at the next turn boundary.  A session whose dialog is never
resolved simply keeps refusing automatic input, which is the safe
direction."
  (eq (buffer-local-value 'agent--session-awaiting-reason buffer) 'blocked))

(defun agent-session-fresh-turn-evidence-p (buffer)
  "Return non-nil when BUFFER positively reported that a turn ended well.
True only after a canonical `stop' or `idle-prompt'.  Nil after
`blocked' and after `error', and nil in a session that has reported no
lifecycle event at all -- absence of evidence is not evidence, and a
duplicate completion never overwrites the reason that identified it as
a duplicate."
  (memq (buffer-local-value 'agent--session-awaiting-reason buffer)
        '(stop idle-prompt)))

(defun agent-session-can-start-turn-p (buffer &optional backend)
  "Return non-nil when text sent to BUFFER now would start a fresh turn.
This is the gate any automatic sender must pass, and it demands
positive evidence rather than the absence of a reason to refuse.  The
readiness probe must say `ready', and on top of that one of:

- the backend registers `:ready-to-submit-p', in which case its verdict
  is protocol evidence in its own right -- it saw the process, the
  thread, the turn, and the backend's own queue; or
- the session itself reported a canonical `stop' or `idle-prompt' as
  the last thing that happened to it.

Without that second clause a session whose turn died -- `error', with
the CLI back at its prompt and the lifecycle state back at
`awaiting-input' -- reads as ready on every transport that has no
protocol probe, and so does a session that has never reported anything
at all.  Requiring the evidence rather than the absence of an objection
is what keeps a prompt queued after a failure from being sent into the
session that just failed."
  (let ((backend (or backend (agent--detect-backend buffer))))
    (and (eq (agent-session-ready-to-submit-p buffer backend) 'ready)
         (or (agent--backend-reports-readiness-p backend)
             (agent-session-fresh-turn-evidence-p buffer)))))

(defun agent--backend-reports-readiness-p (backend)
  "Return non-nil when BACKEND answers readiness from a protocol probe."
  (when-let* ((struct (and backend (agent-backend backend))))
    (and (agent-backend-ready-to-submit-p struct) t)))
```

Add the annotation hook immediately before `agent--session-suffix-spec`:

```elisp
(defcustom agent-session-annotation-functions nil
  "Abnormal hook contributing annotations to session switcher labels.
Each function is called with a session BUFFER and returns a short
string, or nil when it has nothing to say.  `agent--session-suffix-spec'
appends every non-nil result after the session label, space-separated,
so several consumers can annotate the same session without competing
for a single result.  A function that signals is reported with
`display-warning' and contributes nothing."
  :type 'hook
  :group 'agent)

(defun agent--session-annotations (buffer)
  "Return the annotation strings contributed for session BUFFER."
  (let (annotations)
    (run-hook-wrapped
     'agent-session-annotation-functions
     (lambda (fn)
       (condition-case err
           (let ((text (funcall fn buffer)))
             (when (and (stringp text) (not (string-empty-p text)))
               (push text annotations)))
         (error
          (display-warning
           'agent
           (format "session annotation %S signaled: %S" fn err)
           :warning)))
       nil))
    (nreverse annotations)))
```

Replace the `label` binding in `agent--session-suffix-spec`:

```elisp
(defun agent--session-suffix-spec (buf key)
  "Build a transient suffix spec for BUF bound to KEY."
  (let* ((backend (agent--detect-backend buf))
         (icon (when backend (agent-backend-icon-string backend)))
         (name (agent-display-name buf))
         (label (string-join
                 (delq nil
                       (append
                        (list (and icon (not (string-empty-p icon)) icon)
                              name)
                        (agent--session-annotations buf)))
                 " "))
         (state (agent-session-display-state buf backend))
         (cmd (make-symbol (format "ai-switch-%s" key)))
         (spec (list key label cmd)))
    (when-let* ((face (agent--session-state-face state)))
      (setq spec (append spec (list :face face))))
    (fset cmd (lambda () (interactive) (switch-to-buffer buf)))
    spec))
```

Note `(and icon (not (string-empty-p icon)) icon)` yields nil or the
icon, which `delq nil` then filters — matching the previous behaviour of
omitting an empty icon.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test` and `make compile` — both clean.

- [ ] **Step 5: Commit**

```bash
git add agent.el test/agent-test.el
git commit -m "agent: add capability slots, readiness probe, and session annotations"
```

---

### Task 3: `agent-interrupt` and `agent-steer`

**Files:**
- Modify: `agent.el` (new `;;;; Busy-session operations` section
  immediately after the "Core send wrappers" section, ~line 1493)
- Test: `test/agent-test.el`

**Interfaces:**
- Consumes: Task 2's `:interrupt`, `:steer`, `:steer-p` slots and
  `agent--backend-label`.
- Produces: the interactive commands `agent-interrupt` and
  `agent-steer`.

- [ ] **Step 1: Write the failing tests**

```elisp
;;;; Busy-session operations

(ert-deftest agent-test-interrupt/dispatches-to-the-slot ()
  "`agent-interrupt' calls the backend's interrupt with the buffer."
  (agent-test--with-event-buffer buf
    (let* ((agent-backends nil)
           (calls nil))
      (apply #'agent-register-backend 'ir
             (agent-test--backend
              :buffer-p (lambda (b) (eq b buf))
              :interrupt (lambda (b) (push b calls))))
      (agent-interrupt buf)
      (should (equal calls (list buf))))))

(ert-deftest agent-test-interrupt/refuses-without-a-slot ()
  "A backend with no interrupt operation refuses clearly."
  (agent-test--with-event-buffer buf
    (let ((agent-backends nil))
      (apply #'agent-register-backend 'noir
             (agent-test--backend :buffer-p (lambda (b) (eq b buf))))
      (should-error (agent-interrupt buf) :type 'user-error))))

(ert-deftest agent-test-steer/refuses-when-the-backend-cannot-steer ()
  "A backend registering no steer slots names the alternative."
  (agent-test--with-event-buffer buf
    (let ((agent-backends nil))
      (apply #'agent-register-backend 'nosteer
             (agent-test--backend
              :buffer-p (lambda (b) (eq b buf))
              :label "Claude Code"))
      (let ((err (should-error (agent-steer buf) :type 'user-error)))
        (should (string-match-p "Claude Code" (cadr err)))
        (should (string-match-p "queued input" (cadr err)))))))

(ert-deftest agent-test-steer/refuses-with-the-backend-reason ()
  "A `:steer-p' reason string is reported verbatim, and nothing is sent."
  (agent-test--with-event-buffer buf
    (let* ((agent-backends nil)
           (sent nil))
      (apply #'agent-register-backend 'idlesteer
             (agent-test--backend
              :buffer-p (lambda (b) (eq b buf))
              :label "Codex"
              :steer (lambda (text _b) (push text sent))
              :steer-p (lambda (_b) "no turn is running")))
      (let ((err (should-error (agent-steer buf) :type 'user-error)))
        (should (string-match-p "no turn is running" (cadr err))))
      (should (null sent)))))

(ert-deftest agent-test-steer/sends-when-available ()
  "With `:steer-p' returning t the text reaches the steer slot."
  (agent-test--with-event-buffer buf
    (let* ((agent-backends nil)
           (sent nil))
      (apply #'agent-register-backend 'oksteer
             (agent-test--backend
              :buffer-p (lambda (b) (eq b buf))
              :steer (lambda (text b) (push (cons text b) sent))
              :steer-p (lambda (_b) t)))
      (cl-letf (((symbol-function 'read-string)
                 (lambda (&rest _) "focus on the tests")))
        (agent-steer buf))
      (should (equal sent (list (cons "focus on the tests" buf)))))))

(ert-deftest agent-test-steer/refuses-empty-text ()
  "Empty steering text is refused before the backend is called."
  (agent-test--with-event-buffer buf
    (let* ((agent-backends nil)
           (sent nil))
      (apply #'agent-register-backend 'emptysteer
             (agent-test--backend
              :buffer-p (lambda (b) (eq b buf))
              :steer (lambda (text _b) (push text sent))
              :steer-p (lambda (_b) t)))
      (cl-letf (((symbol-function 'read-string) (lambda (&rest _) "   ")))
        (should-error (agent-steer buf) :type 'user-error))
      (should (null sent)))))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test` — `agent-interrupt` and `agent-steer` are void.

- [ ] **Step 3: Implement the commands**

Add a new section after the "Core send wrappers" section in `agent.el`:

```elisp
;;;; Busy-session operations

;;;###autoload
(defun agent-interrupt (&optional buffer)
  "Interrupt the turn currently running in session BUFFER.
BUFFER defaults to the current session buffer, prompting for one when
the current buffer is not a session.  Dispatches the backend's
authoritative native interrupt and does nothing else: it never submits
replacement text, never queues, and never steers.

On Claude Code the native interrupt is the escape key, and escape while
a permission dialog is showing answers that dialog rather than stopping
the turn -- that is the CLI's own behaviour, and Emacs cannot see which
dialog is on screen."
  (interactive)
  (let* ((buf (agent--resolve-session-buffer buffer))
         (backend (agent--detect-backend buf))
         (fn (when-let* ((struct (and backend (agent-backend backend))))
               (agent-backend-interrupt struct))))
    (unless fn
      (user-error "%s registers no interrupt operation"
                  (agent--backend-label backend)))
    (funcall fn buf)))

;;;###autoload
(defun agent-steer (&optional buffer)
  "Steer the turn currently running in session BUFFER.
BUFFER defaults to the current session buffer, prompting for one when
the current buffer is not a session.  Steering adds instructions to the
turn already in flight; it is a distinct operation from queueing a
follow-up turn (`agent-queue-prompt') and from interrupting
\(`agent-interrupt'), and this command never substitutes one for
another.  Backends that cannot steer refuse and say so."
  (interactive)
  (let* ((buf (agent--resolve-session-buffer buffer))
         (backend (agent--detect-backend buf))
         (struct (and backend (agent-backend backend)))
         (steer (and struct (agent-backend-steer struct)))
         (steer-p (and struct (agent-backend-steer-p struct)))
         (label (agent--backend-label backend)))
    (unless (and steer steer-p)
      (user-error
       "%s has no steering operation; queued input becomes the next turn"
       label))
    (let ((verdict (funcall steer-p buf)))
      (unless (eq verdict t)
        (user-error "%s cannot steer this session now%s" label
                    (if (stringp verdict) (format ": %s" verdict) ""))))
    (let ((text (read-string (format "Steer %s: " label))))
      (when (string-empty-p (string-trim text))
        (user-error "Nothing to steer with"))
      (funcall steer text buf))))
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test` and `make compile` — both clean.

- [ ] **Step 5: Commit**

```bash
git add agent.el test/agent-test.el
git commit -m "agent: add separate interrupt and steer commands"
```

---

### Task 4: Durable capture API for dead sessions

**Files:**
- Modify: `agent-capture.el` (`agent-capture--session-identity` ~line 129;
  `agent-capture--ensure-header` ~line 153;
  `agent-capture--append-entry` ~line 160; new public API at the end of
  the prompt-capture section)
- Test: `test/agent-capture-test.el`

**Interfaces:**
- Consumes: `agent-session` accessors from `agent.el`.
- Produces:
  - `agent-capture-store-prompt SESSION LABEL TEXT &optional TAG` →
    prompt handle plist `(:file :title :created :inserted :text)`,
    the same shape `agent-capture--prompts` returns, so
    `agent-capture--delete-prompt` accepts it.  Signals `error` when the
    write cannot be confirmed on disk, and in that case the file is byte
    for byte what it was before the call: the append is all-or-nothing
    over the FILE, not only over the buffer.
  - `agent-capture-session-file SESSION` → absolute capture file path
    for a session struct, live buffer or not.
  - `agent-capture--file-bytes FILE` → FILE's exact bytes, or nil.
  - `agent-capture--rollback-append START WAS-MODIFIED FILE EXISTED
    PREVIOUS` → restores both the shared buffer and the file.

- [ ] **Step 1: Write the failing tests**

Add to `test/agent-capture-test.el`:

```elisp
(defmacro agent-capture-test--with-directory (&rest body)
  "Run BODY with a disposable prompt capture directory."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "agent-capture-test" t))
          (agent-prompt-capture-directory (file-name-as-directory dir)))
     (unwind-protect (progn ,@body)
       (delete-directory dir t))))

(ert-deftest agent-capture-test-session-file/matches-the-buffer-path ()
  "The session-struct path equals the path computed from a live buffer."
  (agent-capture-test--with-directory
    (let ((session (agent-session-create :backend 'codex
                                         :account "personal"
                                         :directory "~/project/"
                                         :instance nil))
          (buffer (generate-new-buffer " *agent-capture-test*")))
      (unwind-protect
          (progn
            (with-current-buffer buffer (setq-local agent--session session))
            (should (equal (agent-capture-session-file session)
                           (agent-capture--file 'codex buffer))))
        (kill-buffer buffer)))))

(ert-deftest agent-capture-test-store-prompt/writes-and-returns-handle ()
  "Storing a prompt writes it to disk and returns a usable handle."
  (agent-capture-test--with-directory
    (let* ((session (agent-session-create :backend 'codex
                                          :directory "~/project/"))
           (handle (agent-capture-store-prompt
                    session "project" "run the tests" "queued-abc")))
      (should (file-exists-p (plist-get handle :file)))
      (should (equal (plist-get handle :text) "run the tests"))
      (should (string-match-p "queued-abc" (plist-get handle :title)))
      (let ((prompts (agent-capture--read-prompts
                      (plist-get handle :file) t)))
        (should (= (length prompts) 1))
        (should (equal (plist-get (car prompts) :text) "run the tests"))))))

(ert-deftest agent-capture-test-store-prompt/handle-round-trips-delete ()
  "The returned handle deletes exactly its own entry."
  (agent-capture-test--with-directory
    (let* ((session (agent-session-create :backend 'codex
                                          :directory "~/project/"))
           (first (agent-capture-store-prompt session "p" "one" "q1"))
           (_second (agent-capture-store-prompt session "p" "two" "q2")))
      (agent-capture--delete-prompt first)
      (let ((texts (mapcar (lambda (p) (plist-get p :text))
                           (agent-capture--read-prompts
                            (plist-get first :file) t))))
        (should (equal texts '("two")))))))

(defun agent-capture-test--texts (file)
  "Return the texts of FILE's entries, read from disk."
  (mapcar (lambda (prompt) (plist-get prompt :text))
          (agent-capture--read-prompts file t)))

(ert-deftest agent-capture-test-store-prompt/failed-append-leaves-no-trace ()
  "A failed append cannot be flushed to disk by the next successful one.
Success, failure, success: the file must end up holding exactly the two
successful entries, and the handles must name exactly those."
  (agent-capture-test--with-directory
    (let* ((session (agent-session-create :backend 'codex
                                          :directory "~/project/"))
           (file (agent-capture-session-file session))
           (first (agent-capture-store-prompt session "p" "one" "q1"))
           (calls 0))
      (cl-letf* ((real (symbol-function 'save-buffer))
                 ((symbol-function 'save-buffer)
                  (lambda (&rest args)
                    (cl-incf calls)
                    (if (= calls 1)
                        (error "disk full")
                      (apply real args)))))
        (should-error (agent-capture-store-prompt session "p" "two" "q2")))
      (let ((third (agent-capture-store-prompt session "p" "three" "q3")))
        (should (equal (agent-capture-test--texts file) '("one" "three")))
        (should (equal (plist-get first :text) "one"))
        (should (equal (plist-get third :text) "three"))
        ;; Both handles still delete exactly their own entry.
        (agent-capture--delete-prompt first)
        (should (equal (agent-capture-test--texts file) '("three")))))))

(ert-deftest agent-capture-test-store-prompt/write-then-signal-is-undone ()
  "A save that writes the file and THEN signals leaves no orphan entry.
This is the `after-save-hook' case: the bytes really did reach the disk
before the error, so undoing the buffer edit is not enough -- the file
itself has to go back to what it was."
  (agent-capture-test--with-directory
    (let* ((session (agent-session-create :backend 'codex
                                          :directory "~/project/"))
           (file (agent-capture-session-file session))
           (calls 0))
      (agent-capture-store-prompt session "p" "one" "q1")
      (cl-letf* ((real (symbol-function 'save-buffer))
                 ((symbol-function 'save-buffer)
                  (lambda (&rest args)
                    (cl-incf calls)
                    (apply real args)
                    (when (= calls 1) (error "after-save-hook failed")))))
        (should-error (agent-capture-store-prompt session "p" "two" "q2"))
        ;; The write happened; the rollback undid it.
        (should (= calls 1))
        (should (equal (agent-capture-test--texts file) '("one"))))
      (let ((third (agent-capture-store-prompt session "p" "three" "q3")))
        (should (equal (agent-capture-test--texts file) '("one" "three")))
        (should (equal (plist-get third :text) "three"))
        ;; The live buffer agrees with the file, so nothing stale can be
        ;; flushed by a later save.
        (with-current-buffer (find-file-noselect file)
          (should-not (buffer-modified-p))
          (should-not (string-match-p "two" (buffer-string))))))))

(ert-deftest agent-capture-test-store-prompt/unconfirmed-write-is-undone ()
  "A write that lands but cannot be confirmed is rolled back, not kept.
An entry the confirmation cannot see is an entry no handle names."
  (agent-capture-test--with-directory
    (let* ((session (agent-session-create :backend 'codex
                                          :directory "~/project/"))
           (file (agent-capture-session-file session))
           (calls 0))
      (agent-capture-store-prompt session "p" "one" "q1")
      (cl-letf* ((real (symbol-function 'agent-capture--stored-prompt))
                 ((symbol-function 'agent-capture--stored-prompt)
                  (lambda (&rest args)
                    (cl-incf calls)
                    (if (= calls 1) nil (apply real args)))))
        (should-error (agent-capture-store-prompt session "p" "two" "q2")))
      (should (equal (agent-capture-test--texts file) '("one"))))))

(ert-deftest agent-capture-test-store-prompt/first-append-failure-removes-the-file ()
  "When the file did not exist before, a failed first append leaves none."
  (agent-capture-test--with-directory
    (let* ((session (agent-session-create :backend 'codex
                                          :directory "~/project/"))
           (file (agent-capture-session-file session)))
      (cl-letf* ((real (symbol-function 'save-buffer))
                 ((symbol-function 'save-buffer)
                  (lambda (&rest args)
                    (apply real args)
                    (error "after-save-hook failed"))))
        (should-error (agent-capture-store-prompt session "p" "one" "q1")))
      (should-not (file-exists-p file)))))

(ert-deftest agent-capture-test-store-prompt/signals-when-unconfirmed ()
  "A write that cannot be confirmed on disk signals."
  (agent-capture-test--with-directory
    (let ((session (agent-session-create :backend 'codex
                                         :directory "~/project/")))
      (cl-letf (((symbol-function 'agent-capture--read-prompts)
                 (lambda (&rest _) nil)))
        (should-error
         (agent-capture-store-prompt session "p" "lost" "q3"))))))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test` — `agent-capture-session-file` and
`agent-capture-store-prompt` are void.

- [ ] **Step 3: Implement the API**

In `agent-capture.el`, add a session-struct identity function next to
`agent-capture--session-identity` and leave that function unchanged, so
existing slugs never move:

```elisp
(defun agent-capture--session-struct-identity (session)
  "Return the prompt capture identity for SESSION.
SESSION is an `agent-session' struct, so this works for sessions whose
buffer is gone.  Produces the same string as
`agent-capture--session-identity' does for a live buffer holding the
same identity."
  (prin1-to-string
   (list (agent-session-backend session)
         (agent-session-account session)
         (if-let* ((directory (agent-session-directory session)))
             (file-name-as-directory (file-truename directory))
           "")
         (agent-session-instance session))))

(defun agent-capture-session-file (session)
  "Return the Org capture file for SESSION.
SESSION is an `agent-session' struct; no session buffer need exist."
  (expand-file-name
   (format "%s-%s.org"
           (agent-session-backend session)
           (secure-hash 'sha1 (agent-capture--session-struct-identity
                               session)))
   agent-prompt-capture-directory))
```

Change `agent-capture--ensure-header` to take the display label directly
so both callers can use it:

```elisp
(defun agent-capture--ensure-header (backend label)
  "Insert the prompt capture file header for BACKEND session LABEL."
  (when (zerop (buffer-size))
    (insert "#+title: Agent prompt captures\n")
    (insert "#+agent_backend: " (symbol-name backend) "\n")
    (insert "#+agent_session: " (or label "") "\n\n")))
```

and update its caller in `agent-capture--open-file`:

```elisp
      (agent-capture--ensure-header backend (agent-display-name buffer))
```

Give `agent-capture--append-entry` an optional tag so stored entries are
individually identifiable:

```elisp
(defun agent-capture--append-entry (&optional tag)
  "Append a new prompt capture entry at the end of the current buffer.
TAG, when non-nil, is appended to the heading so the entry can be told
apart from others created in the same minute with the same text."
  (goto-char (point-max))
  (unless (bolp) (insert "\n"))
  (insert "* Prompt " (format-time-string "%Y-%m-%d %H:%M")
          (if tag (format " [%s]" tag) "") "\n")
  (insert ":PROPERTIES:\n")
  (insert ":CREATED: " (format-time-string "[%Y-%m-%d %a %H:%M]") "\n")
  (insert ":END:\n\n")
  (point))
```

Add the public store function at the end of the prompt-capture section:

```elisp
(defun agent-capture-store-prompt (session label text &optional tag)
  "Store TEXT as a captured prompt for SESSION and return its handle.
SESSION is an `agent-session' struct, so this works for sessions whose
buffer has already died; LABEL is the display name written into the
file header; TAG, when non-nil, is appended to the entry heading so the
entry can be matched unambiguously later.

This is the noninteractive, durability-confirming counterpart to
`agent-capture-prompt': it appends the entry, saves the file
synchronously, and re-reads it from disk to confirm the entry landed.
Return the prompt handle plist -- the same shape `agent-capture--prompts'
returns, accepted by `agent-capture--delete-prompt'.  Signal an error
when the write cannot be confirmed, so callers can keep the text
somewhere else instead of assuming it is safe.

The append is a transaction over the FILE, not merely over the buffer.
`save-buffer' can write the file completely and then signal -- an
`after-save-hook' that fails is enough -- so undoing the buffer edit
and reloading would only pull the orphan back in: an entry on disk that
no caller holds a handle for, invisible to code that believes the write
failed, and unreachable by the handle-based cleanup.  The previous
bytes are therefore snapshotted before the append and written back on
any failure, which also covers the case where the write succeeded but
the confirming re-read did not find the entry.  The capture file has a
single writer -- this Emacs -- so restoring it cannot discard anyone
else's work."
  (require 'org)
  (let* ((file (agent-capture-session-file session))
         (trimmed (string-trim text)))
    (when (string-empty-p trimmed)
      (error "Refusing to store an empty prompt"))
    (make-directory (file-name-directory file) t)
    (let ((buffer (find-file-noselect file))
          (existed (file-exists-p file))
          (previous (agent-capture--file-bytes file)))
      (with-current-buffer buffer
        (org-mode)
        (let ((start (point-max))
              (was-modified (buffer-modified-p)))
          (condition-case err
              (progn
                (agent-capture--ensure-header
                 (agent-session-backend session) label)
                (goto-char (agent-capture--append-entry tag))
                (insert trimmed "\n")
                (save-buffer)
                (unless (agent-capture--stored-prompt file trimmed tag)
                  (error "Could not confirm the captured prompt in %s" file)))
            (error
             (agent-capture--rollback-append start was-modified
                                             file existed previous)
             (signal (car err) (cdr err)))))))
    (agent-capture--stored-prompt file trimmed tag)))

(defun agent-capture--file-bytes (file)
  "Return FILE's exact bytes as a unibyte string, or nil when absent."
  (when (file-exists-p file)
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally file)
      (buffer-string))))

(defun agent-capture--rollback-append (start was-modified file existed
                                             previous)
  "Undo a failed capture append and put FILE back as it was.
START is where the append began in the current buffer and WAS-MODIFIED
its modified flag beforehand; EXISTED and PREVIOUS are FILE's presence
and exact bytes from before the attempt.

The file is restored, not just the buffer.  `save-buffer' can write the
file and then signal -- an `after-save-hook' failure is the ordinary
way -- and the confirming re-read can fail after a successful write, so
undoing only the buffer would leave a complete entry on disk that no
caller holds a handle for.  Writing the previous bytes back is what
makes the append all-or-nothing; a file that did not exist before is
deleted.  Rollback never signals: it runs while another error is
already propagating."
  (ignore-errors
    (let ((inhibit-read-only t))
      (delete-region (min start (point-max)) (point-max)))
    (unless was-modified
      (set-buffer-modified-p nil))
    (if existed
        (let ((coding-system-for-write 'no-conversion))
          (write-region previous nil file nil 'silent))
      (when (file-exists-p file) (delete-file file)))
    (if (file-exists-p file)
        (revert-buffer :ignore-auto :noconfirm :preserve-modes)
      (erase-buffer)
      (set-buffer-modified-p nil))))

(defun agent-capture--stored-prompt (file text tag)
  "Return the entry in FILE matching TEXT and TAG, re-read from disk."
  (when (file-exists-p file)
    (car (last (seq-filter
                (lambda (prompt)
                  (and (equal (plist-get prompt :text) text)
                       (or (null tag)
                           (string-match-p (regexp-quote tag)
                                           (or (plist-get prompt :title) "")))))
                (agent-capture--read-prompts file t))))))
```

`agent-capture--read-prompts` reads FILE from disk into a temp buffer,
so the confirmation genuinely checks what was written, not the live
buffer's contents.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test` and `make compile` — both clean.  Confirm the existing
capture tests still pass: the slug function was not touched and
`agent-capture--ensure-header`'s only caller was updated.

- [ ] **Step 5: Commit**

```bash
git add agent-capture.el test/agent-capture-test.el
git commit -m "agent: add a durability-confirming capture store API"
```

---

### Task 5: Attention records and lifecycle

**Files:**
- Create: `agent-attention.el`
- Create: `test/agent-attention-test.el`
- Modify: `Makefile` (`SRC` and `TEST_FILES`)
- Modify: `agent.el` (split-module autoloads block, ~line 43)

**Interfaces:**
- Consumes: `agent-session-event-functions`,
  `agent-session-annotation-functions`, `agent--teardown-functions`,
  `agent-display-name`, `agent--backend-label`, `agent-session`,
  `agent-session-display-state`.
- Produces (used by Tasks 6, 7, 9, 11, 12, 13):
  - `agent-attention-mode` — global minor mode owning every hook.
  - `cl-defstruct agent-attention-item` with accessors
    `agent-attention-item-id`, `-buffer`, `-session-label`, `-kind`,
    `-title`, `-detail`, `-created-at`, `-updated-at`, `-state`,
    `-request-key`, `-fidelity`, `-actions`, `-invalid-reason`.
  - `agent-attention-items ()` → the current item list, newest first.
  - `agent-attention-file KIND ARGS...` → the public producer:
    `(agent-attention-file BUFFER &rest KEYS)` with keys `:kind`,
    `:title`, `:detail`, `:request-key`, `:fidelity`, `:actions`,
    `:fallback`.  Returns the item.
  - `agent-attention-resolve ITEM &optional REASON` — clear a
    request-keyed item because it was answered.
  - `agent-attention-invalidate-buffer BUFFER REASON` — invalidate every
    request-keyed item of BUFFER.
  - `agent-attention--hand-back-requests ()` — on mode disable, run each
    outstanding routed request's `:fallback` so the backend answers it.
  - `agent-attention-invoke ITEM ACTION` — three explicit outcomes:
    answered, invalidated, response-failed.
  - `agent-attention-pending-count ()` → integer.
  - `agent-attention-mark-seen ITEM`, `agent-attention-delete ITEM`.

- [ ] **Step 1: Write the failing tests**

Create `test/agent-attention-test.el`:

```elisp
;;; agent-attention-test.el --- Tests for agent-attention -*- lexical-binding: t -*-

;; Tests for the attention record store and its lifecycle.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'agent)
(require 'agent-attention)

(defun agent-attention-test--buffer (&optional name)
  "Return a disposable session buffer called NAME."
  (let ((buffer (generate-new-buffer (or name " *agent-attention-test*"))))
    (with-current-buffer buffer
      (setq-local agent--session
                  (agent-session-create :backend 'test
                                        :account "personal"
                                        :directory "~/project/")))
    buffer))

(defmacro agent-attention-test--with-store (&rest body)
  "Run BODY with an empty attention store and a stubbed display name."
  (declare (indent 0))
  `(let ((agent-attention--items nil))
     (cl-letf (((symbol-function 'agent-display-name)
                (lambda (&optional _b) "project"))
               ((symbol-function 'agent--backend-label)
                (lambda (_backend) "Test")))
       ,@body)))

(ert-deftest agent-attention-test-file/creates-a-pending-item ()
  "Filing a permission report creates one pending item."
  (agent-attention-test--with-store
    (let ((buffer (agent-attention-test--buffer)))
      (unwind-protect
          (progn
            (agent-attention-file buffer :kind 'permission
                                  :title "Bash" :detail "rm -rf"
                                  :fidelity 'rich)
            (should (= (length (agent-attention-items)) 1))
            (let ((item (car (agent-attention-items))))
              (should (eq (agent-attention-item-kind item) 'permission))
              (should (eq (agent-attention-item-state item) 'pending))
              (should (equal (agent-attention-item-detail item) "rm -rf"))
              (should (equal (plist-get
                              (agent-attention-item-session-label item)
                              :name)
                             "project"))))
        (kill-buffer buffer)))))

(ert-deftest agent-attention-test-file/coarse-report-merges-into-rich ()
  "A coarse report refreshes a rich item without overwriting its detail."
  (agent-attention-test--with-store
    (let ((buffer (agent-attention-test--buffer)))
      (unwind-protect
          (progn
            (agent-attention-file buffer :kind 'permission
                                  :title "Bash" :detail "rm -rf"
                                  :fidelity 'rich)
            (agent-attention-file buffer :kind 'permission
                                  :title "Claude needs permission"
                                  :detail nil :fidelity 'coarse)
            (should (= (length (agent-attention-items)) 1))
            (let ((item (car (agent-attention-items))))
              (should (equal (agent-attention-item-detail item) "rm -rf"))
              (should (equal (agent-attention-item-title item) "Bash"))
              (should (eq (agent-attention-item-fidelity item) 'rich))))
        (kill-buffer buffer)))))

(ert-deftest agent-attention-test-file/rich-report-upgrades-coarse ()
  "A rich report replaces the detail of a coarse item."
  (agent-attention-test--with-store
    (let ((buffer (agent-attention-test--buffer)))
      (unwind-protect
          (progn
            (agent-attention-file buffer :kind 'permission
                                  :title "needs permission" :fidelity 'coarse)
            (agent-attention-file buffer :kind 'permission
                                  :title "Bash" :detail "ls -l"
                                  :fidelity 'rich)
            (should (= (length (agent-attention-items)) 1))
            (should (equal (agent-attention-item-detail
                            (car (agent-attention-items)))
                           "ls -l")))
        (kill-buffer buffer)))))

(ert-deftest agent-attention-test-file/request-keys-coexist ()
  "Two outstanding request-keyed items keep their own records."
  (agent-attention-test--with-store
    (let ((buffer (agent-attention-test--buffer)))
      (unwind-protect
          (progn
            (agent-attention-file buffer :kind 'permission :title "one"
                                  :request-key 41 :fidelity 'rich)
            (agent-attention-file buffer :kind 'permission :title "two"
                                  :request-key 42 :fidelity 'rich)
            (should (= (length (agent-attention-items)) 2)))
        (kill-buffer buffer)))))

(ert-deftest agent-attention-test-progress/clears-unkeyed-items-at-any-fidelity ()
  "Progress clears unkeyed items rich and coarse alike, keeping keyed ones.
Claude's rich `PermissionRequest' items carry no request key, so a
fidelity-based rule would leave them listed forever."
  (agent-attention-test--with-store
    (let ((buffer (agent-attention-test--buffer)))
      (unwind-protect
          (progn
            (agent-attention-file buffer :kind 'permission :title "coarse"
                                  :fidelity 'coarse)
            (agent-attention-file buffer :kind 'question :title "rich"
                                  :fidelity 'rich)
            (agent-attention-file buffer :kind 'permission :title "keyed"
                                  :request-key 7 :fidelity 'rich)
            (agent-attention--note-progress buffer)
            (should (= (length (agent-attention-items)) 1))
            (should (equal (agent-attention-item-title
                            (car (agent-attention-items)))
                           "keyed")))
        (kill-buffer buffer)))))

(ert-deftest agent-attention-test-unkeyed/retires-on-completion-error-teardown ()
  "A rich unkeyed dialog item dies with the turn, not only on progress.
Claude's `PermissionRequest' items are rich AND unkeyed, so a rule that
retired only coarse ones, or only on progress, would leave them listed
for the rest of the session."
  (dolist (ending '(stop error teardown))
    (agent-attention-test--with-store
      (let ((buffer (agent-attention-test--buffer)))
        (unwind-protect
            (cl-letf (((symbol-function 'agent-attention--being-read-p)
                       (lambda (_b) t)))
              (agent-attention-file buffer :kind 'permission :title "Bash"
                                    :detail "rm -rf" :fidelity 'rich)
              (agent-attention-file buffer :kind 'question :title "which?"
                                    :fidelity 'coarse)
              (should (= (length (agent-attention-items)) 2))
              (pcase ending
                ('stop (agent-attention--on-event
                        buffer '(:type stop :redundant nil :payload nil)))
                ('error (agent-attention--on-event
                         buffer '(:type error :redundant nil
                                        :payload (:error "boom"))))
                ('teardown (with-current-buffer buffer
                             (agent-attention--teardown-current))))
              (should (null (seq-filter
                             (lambda (item)
                               (memq (agent-attention-item-kind item)
                                     '(permission question)))
                             (agent-attention-items)))))
          (kill-buffer buffer))))))

(ert-deftest agent-attention-test-unkeyed/redundant-completion-retires-nothing ()
  "A duplicate completion is not a turn end, so it retires nothing."
  (agent-attention-test--with-store
    (let ((buffer (agent-attention-test--buffer)))
      (unwind-protect
          (progn
            (agent-attention-file buffer :kind 'permission :title "Bash"
                                  :fidelity 'rich)
            (agent-attention--on-event
             buffer '(:type stop :redundant t :payload nil))
            (should (= (length (agent-attention-items)) 1)))
        (kill-buffer buffer)))))

(ert-deftest agent-attention-test-error/invalidates-outstanding-requests ()
  "An abnormal turn end disarms the requests that turn was waiting on."
  (agent-attention-test--with-store
    (let ((buffer (agent-attention-test--buffer)))
      (unwind-protect
          (let ((item (agent-attention-file
                       buffer :kind 'permission :title "keyed"
                       :request-key 11 :fidelity 'rich
                       :actions (list (cons "a" (cons "Allow" #'ignore))))))
            (agent-attention--on-event
             buffer '(:type error :redundant nil :payload (:error "boom")))
            (should (null (agent-attention-item-actions item)))
            (should (eq (agent-attention-item-state item) 'seen)))
        (kill-buffer buffer)))))

(ert-deftest agent-attention-test-actions/failed-response-stays-answerable ()
  "A response closure that signals leaves the item answerable."
  (agent-attention-test--with-store
    (let ((buffer (agent-attention-test--buffer))
          (attempts 0))
      (unwind-protect
          (let* ((item (agent-attention-file
                        buffer :kind 'permission :title "keyed"
                        :request-key 12 :fidelity 'rich
                        :actions (list (cons "a"
                                             (cons "Allow"
                                                   (lambda ()
                                                     (cl-incf attempts)
                                                     (when (= attempts 1)
                                                       (error "pipe closed"))))))))
                 (action (car (agent-attention-item-actions item))))
            (cl-letf (((symbol-function 'message) #'ignore))
              (agent-attention-invoke item action))
            (should (agent-attention-item-actions item))
            (should-not (gethash (agent-attention-item-id item)
                                 agent-attention--invoked))
            (agent-attention-invoke item action)
            (should (= attempts 2))
            (should (gethash (agent-attention-item-id item)
                             agent-attention--invoked)))
        (kill-buffer buffer)))))

(ert-deftest agent-attention-test-mode/disabling-hands-requests-back ()
  "Disabling the mode returns routed requests to their backend."
  (let ((agent-attention--items nil)
        (agent-attention--invoked (make-hash-table :test #'equal))
        (agent-session-event-functions nil)
        (agent-session-annotation-functions nil)
        (window-selection-change-functions nil)
        (handed 0))
    (cl-letf (((symbol-function 'agent-display-name)
               (lambda (&optional _b) "project"))
              ((symbol-function 'agent--backend-label) (lambda (_b) "Test")))
      (let ((buffer (agent-attention-test--buffer)))
        (unwind-protect
            (progn
              (agent-attention-mode 1)
              (agent-attention-file
               buffer :kind 'permission :title "keyed" :request-key 13
               :fidelity 'rich
               :actions (list (cons "a" (cons "Allow" #'ignore)))
               :fallback (lambda () (cl-incf handed)))
              (agent-attention-mode -1)
              (should (= handed 1))
              (should (null (agent-attention-items))))
          (when agent-attention-mode (agent-attention-mode -1))
          (kill-buffer buffer))))))

(ert-deftest agent-attention-test-mode/failed-hand-back-keeps-the-request ()
  "A fallback that signals leaves the request open and answerable."
  (let ((agent-attention--items nil)
        (agent-attention--invoked (make-hash-table :test #'equal))
        (agent-session-event-functions nil)
        (agent-session-annotation-functions nil)
        (window-selection-change-functions nil))
    (cl-letf (((symbol-function 'agent-display-name)
               (lambda (&optional _b) "project"))
              ((symbol-function 'agent--backend-label) (lambda (_b) "Test"))
              ((symbol-function 'display-warning) #'ignore))
      (let ((buffer (agent-attention-test--buffer)))
        (unwind-protect
            (progn
              (agent-attention-mode 1)
              (let ((item (agent-attention-file
                           buffer :kind 'permission :title "keyed"
                           :request-key 15 :fidelity 'rich
                           :actions (list (cons "a" (cons "Allow" #'ignore)))
                           :fallback (lambda () (error "process gone")))))
                (agent-attention-mode -1)
                (should (memq item (agent-attention-items)))
                (should (eq (agent-attention-item-state item) 'pending))
                (should (agent-attention-item-actions item))
                (should-not (gethash (agent-attention-item-id item)
                                     agent-attention--invoked))
                (should (string-match-p "failed"
                                        (agent-attention-item-invalid-reason
                                         item)))))
          (when agent-attention-mode (agent-attention-mode -1))
          (kill-buffer buffer))))))

(ert-deftest agent-attention-test-mode/disabling-invalidates-without-a-fallback ()
  "A routed request with no fallback is invalidated, not silently dropped."
  (let ((agent-attention--items nil)
        (agent-attention--invoked (make-hash-table :test #'equal))
        (agent-session-event-functions nil)
        (agent-session-annotation-functions nil)
        (window-selection-change-functions nil))
    (cl-letf (((symbol-function 'agent-display-name)
               (lambda (&optional _b) "project"))
              ((symbol-function 'agent--backend-label) (lambda (_b) "Test")))
      (let ((buffer (agent-attention-test--buffer)))
        (unwind-protect
            (progn
              (agent-attention-mode 1)
              (let ((item (agent-attention-file
                           buffer :kind 'permission :title "keyed"
                           :request-key 14 :fidelity 'rich
                           :actions (list (cons "a" (cons "Allow" #'ignore))))))
                (agent-attention-mode -1)
                (should (null (agent-attention-item-actions item)))
                (should (agent-attention-item-invalid-reason item))))
          (when agent-attention-mode (agent-attention-mode -1))
          (kill-buffer buffer))))))

(ert-deftest agent-attention-test-completion/skips-a-buffer-being-read ()
  "No completion item is filed while the buffer is selected and focused."
  (agent-attention-test--with-store
    (let ((buffer (agent-attention-test--buffer)))
      (unwind-protect
          (cl-letf (((symbol-function 'agent-attention--being-read-p)
                     (lambda (_b) t)))
            (agent-attention--note-completion buffer)
            (should (null (agent-attention-items))))
        (kill-buffer buffer)))))

(ert-deftest agent-attention-test-completion/files-when-not-being-read ()
  "A completion in an unselected window still files one item."
  (agent-attention-test--with-store
    (let ((buffer (agent-attention-test--buffer)))
      (unwind-protect
          (cl-letf (((symbol-function 'agent-attention--being-read-p)
                     (lambda (_b) nil)))
            (agent-attention--note-completion buffer)
            (agent-attention--note-completion buffer)
            (should (= (length (agent-attention-items)) 1))
            (should (eq (agent-attention-item-kind
                         (car (agent-attention-items)))
                        'completion)))
        (kill-buffer buffer)))))

(ert-deftest agent-attention-test-invalidate/disables-actions ()
  "Invalidation marks the item seen, notes why, and disarms its actions."
  (agent-attention-test--with-store
    (let ((buffer (agent-attention-test--buffer))
          (fired 0))
      (unwind-protect
          (let ((item (agent-attention-file
                       buffer :kind 'permission :title "keyed"
                       :request-key 9 :fidelity 'rich
                       :actions (list (cons "a" (cons "Allow"
                                                      (lambda ()
                                                        (cl-incf fired))))))))
            (agent-attention-invalidate-buffer buffer "the turn ended")
            (should (eq (agent-attention-item-state item) 'seen))
            (should (equal (agent-attention-item-invalid-reason item)
                           "the turn ended"))
            (should (null (agent-attention-item-actions item)))
            (should (= fired 0)))
        (kill-buffer buffer)))))

(ert-deftest agent-attention-test-actions/respond-closures-are-one-shot ()
  "An action runs once; a second invocation reports and does nothing."
  (agent-attention-test--with-store
    (let ((buffer (agent-attention-test--buffer))
          (fired 0))
      (unwind-protect
          (let* ((item (agent-attention-file
                        buffer :kind 'permission :title "keyed"
                        :request-key 3 :fidelity 'rich
                        :actions (list (cons "a"
                                             (cons "Allow"
                                                   (lambda ()
                                                     (cl-incf fired)))))))
                 (action (car (agent-attention-item-actions item))))
            (agent-attention-invoke item action)
            (agent-attention-invoke item action)
            (should (= fired 1)))
        (kill-buffer buffer)))))

(ert-deftest agent-attention-test-dead-buffer/item-survives-with-label ()
  "An item outlives its buffer and keeps the snapshotted label."
  (agent-attention-test--with-store
    (let ((buffer (agent-attention-test--buffer)))
      (agent-attention-file buffer :kind 'error :title "rate_limit"
                            :fidelity 'rich)
      (kill-buffer buffer)
      (let ((item (car (agent-attention-items))))
        (should (equal (plist-get (agent-attention-item-session-label item)
                                  :name)
                       "project"))
        (should (not (buffer-live-p (agent-attention-item-buffer item))))))))

(ert-deftest agent-attention-test-events/producers-map-payloads ()
  "The event consumer maps payloads to the documented item kinds."
  (agent-attention-test--with-store
    (let ((buffer (agent-attention-test--buffer)))
      (unwind-protect
          (cl-letf (((symbol-function 'agent-attention--being-read-p)
                     (lambda (_b) nil)))
            (agent-attention--on-event
             buffer '(:type blocked :redundant nil
                            :payload (:kind question :message "which?")))
            (agent-attention--on-event
             buffer '(:type error :redundant nil
                            :payload (:error "rate_limit")))
            (should (equal (mapcar #'agent-attention-item-kind
                                   (agent-attention-items))
                           '(error question))))
        (kill-buffer buffer)))))

(ert-deftest agent-attention-test-events/blocked-without-kind-files-nothing ()
  "A `blocked' event that reports no kind creates no item."
  (agent-attention-test--with-store
    (let ((buffer (agent-attention-test--buffer)))
      (unwind-protect
          (progn
            (agent-attention--on-event
             buffer '(:type blocked :redundant nil :payload nil))
            (should (null (agent-attention-items))))
        (kill-buffer buffer)))))

(ert-deftest agent-attention-test-events/redundant-completion-files-nothing ()
  "A redundant completion does not create a second completion item."
  (agent-attention-test--with-store
    (let ((buffer (agent-attention-test--buffer)))
      (unwind-protect
          (cl-letf (((symbol-function 'agent-attention--being-read-p)
                     (lambda (_b) nil)))
            (agent-attention--on-event
             buffer '(:type stop :redundant nil :payload nil))
            (agent-attention--on-event
             buffer '(:type idle-prompt :redundant t :payload nil))
            (should (= (length (agent-attention-items)) 1)))
        (kill-buffer buffer)))))

(ert-deftest agent-attention-test-annotation/reports-the-strongest-marker ()
  "Pending action items annotate with `!', unread completions with a dot."
  (agent-attention-test--with-store
    (let ((buffer (agent-attention-test--buffer)))
      (unwind-protect
          (cl-letf (((symbol-function 'agent-attention--being-read-p)
                     (lambda (_b) nil)))
            (should (null (agent-attention--annotation buffer)))
            (agent-attention--note-completion buffer)
            (should (equal (agent-attention--annotation buffer) "•"))
            (agent-attention-file buffer :kind 'permission :title "x"
                                  :fidelity 'coarse)
            (should (equal (agent-attention--annotation buffer) "!")))
        (kill-buffer buffer)))))

(ert-deftest agent-attention-test-mode/off-means-no-hooks ()
  "Disabling the mode removes every hook it installed."
  (let ((agent-session-event-functions nil)
        (agent-session-annotation-functions nil)
        (window-selection-change-functions nil))
    (agent-attention-mode 1)
    (should (memq #'agent-attention--on-event agent-session-event-functions))
    (agent-attention-mode -1)
    (should-not (memq #'agent-attention--on-event
                      agent-session-event-functions))
    (should-not (memq #'agent-attention--annotation
                      agent-session-annotation-functions))))

(provide 'agent-attention-test)
;;; agent-attention-test.el ends here
```

- [ ] **Step 2: Run the tests to verify they fail**

First add the file to the Makefile (Step 3 covers it), then run
`make test`.  Expected: `agent-attention` cannot be required.

- [ ] **Step 3: Implement the module**

Create `agent-attention.el`:

```elisp
;;; agent-attention.el --- Attention inbox for AI sessions -*- lexical-binding: t -*-

;; Copyright (C) 2026

;; Author: Pablo Stafforini
;; URL: https://github.com/benthamite/agent
;; Version: 0.1
;; Package-Requires: ((emacs "30.0") (agent "0.1"))

;; This file is NOT part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; A durable, in-Emacs record of everything an AI session needs the user
;; for: permission requests, questions, turn completions the user was not
;; watching, abnormal turn endings, and queue failures.  Records outlive
;; their session buffers, carry only what the backend actually reported,
;; and are cleared by evidence rather than by elapsed time.
;;
;; Loading this file installs nothing.  `agent-attention-mode' owns every
;; hook the module installs.

;;; Code:

(require 'agent)
(require 'cl-lib)
(require 'subr-x)

;;;; Customization

(defgroup agent-attention ()
  "Attention inbox for AI coding sessions."
  :group 'agent)

(defcustom agent-attention-detail-width 80
  "Maximum width of the detail column in the attention inbox."
  :type 'natnum
  :group 'agent-attention)

;;;; Record

(cl-defstruct (agent-attention-item
               (:constructor agent-attention-item--create)
               (:copier nil))
  "One thing an AI session needs the user for.
BUFFER may be dead; SESSION-LABEL is snapshotted at creation so the
record still identifies its session afterwards."
  (id nil :documentation "Unique id string.")
  (buffer nil :documentation "Session buffer, possibly dead.")
  (session-label nil :documentation "Plist (:name :backend :account),
snapshotted at creation.")
  (kind nil :documentation "One of `permission', `question',
`completion', `error', `queue-failure', and `info'.")
  (title nil :documentation "Short backend-reported summary.")
  (detail nil :documentation "Backend-reported detail text, or nil.")
  (created-at nil :documentation "`float-time' when first reported.")
  (updated-at nil :documentation "`float-time' of the last report.")
  (state nil :documentation "`pending' or `seen'.")
  (request-key nil :documentation "Backend request identity, or nil.")
  (fidelity nil :documentation "`rich' or `coarse', per producer.")
  (actions nil :documentation "Alist of (KEY LABEL . CLOSURE) respond
actions, nil when the backend exposes no safe respond path.")
  (fallback nil :documentation "Closure answering this item's request
the way the backend itself would, or nil.  Run when the inbox stops
being able to present the request -- the mode is disabled -- so an
outstanding request is handed back to the backend instead of being
stranded unanswered.")
  (invalid-reason nil :documentation "Why this item cannot be acted on
as usual: either why its actions were disarmed, or -- when the actions
are still present -- what went wrong the last time answering it was
attempted."))

(defconst agent-attention--action-kinds '(permission question error
                                                     queue-failure)
  "Item kinds that mean the session is waiting on the user.")

(defvar agent-attention--items nil
  "All attention items, newest first.")

(defvar agent-attention--counter 0
  "Counter backing `agent-attention--next-id'.")

(defvar agent-attention--invoked (make-hash-table :test #'equal)
  "Ids of items whose request was answered.
Keyed by item id rather than by action, because answering a request
retires every action of that item, and recorded only after the response
closure returned normally.")

(defun agent-attention--next-id ()
  "Return a fresh attention item id."
  (format "att-%d" (cl-incf agent-attention--counter)))

(defun agent-attention-items ()
  "Return every attention item, newest first."
  agent-attention--items)

(defun agent-attention-pending-count ()
  "Return the number of items still needing the user."
  (seq-count (lambda (item) (eq (agent-attention-item-state item) 'pending))
             agent-attention--items))

;;;; Session identity snapshot

(defun agent-attention--session-label (buffer)
  "Return the snapshotted identity plist for session BUFFER."
  (let* ((backend (agent--detect-backend buffer))
         (session (agent-session buffer)))
    (list :name (if (buffer-live-p buffer)
                    (agent-display-name buffer)
                  (buffer-name buffer))
          :backend (agent--backend-label backend)
          :account (and session (agent-session-account session)))))

;;;; Filing

(cl-defun agent-attention-file (buffer &key kind title detail request-key
                                       fidelity actions fallback)
  "File an attention report for session BUFFER and return its item.
KIND is one of `permission', `question', `completion', `error',
`queue-failure', and `info'.  TITLE and DETAIL carry only what the
producer was told; nil DETAIL stays nil rather than being invented.
REQUEST-KEY is the backend's own request identity when it has one, so
distinct outstanding requests keep distinct items.  FIDELITY is `rich'
or `coarse' and decides which producer's detail survives a merge.
ACTIONS is an alist of (KEY LABEL . CLOSURE) respond actions; pass nil
when the backend exposes no safe respond path.  FALLBACK, for
request-keyed items, is a closure answering the request the way the
backend would; it runs if the inbox stops being able to present it."
  (let ((existing (agent-attention--existing buffer kind request-key)))
    (if existing
        (agent-attention--merge existing title detail fidelity actions)
      (agent-attention--add buffer kind title detail request-key
                            fidelity actions fallback))))

(defun agent-attention--existing (buffer kind request-key)
  "Return the item BUFFER's KIND/REQUEST-KEY report should merge into."
  (cond
   (request-key
    (seq-find (lambda (item)
                (and (eq (agent-attention-item-buffer item) buffer)
                     (equal (agent-attention-item-request-key item)
                            request-key)))
              agent-attention--items))
   ((eq kind 'completion)
    (seq-find (lambda (item)
                (and (eq (agent-attention-item-buffer item) buffer)
                     (eq (agent-attention-item-kind item) 'completion)))
              agent-attention--items))
   ((memq kind '(permission question))
    (seq-find (lambda (item)
                (and (eq (agent-attention-item-buffer item) buffer)
                     (eq (agent-attention-item-kind item) kind)
                     (null (agent-attention-item-request-key item))
                     (eq (agent-attention-item-state item) 'pending)))
              agent-attention--items))))

(defun agent-attention--add (buffer kind title detail request-key
                                    fidelity actions fallback)
  "Create and store a new attention item; return it."
  (let ((item (agent-attention-item--create
               :id (agent-attention--next-id)
               :buffer buffer
               :session-label (agent-attention--session-label buffer)
               :kind kind
               :title title
               :detail detail
               :created-at (float-time)
               :updated-at (float-time)
               :state 'pending
               :request-key request-key
               :fidelity (or fidelity 'coarse)
               :actions actions
               :fallback fallback)))
    (push item agent-attention--items)
    (agent-attention--watch buffer)
    (agent-attention--refresh-display)
    item))

(defun agent-attention--merge (item title detail fidelity actions)
  "Refresh ITEM from a new report and return it.
Detail and title are kept from the highest-fidelity producer, so a
coarse report arriving after a rich one refreshes the timestamps
without discarding what the rich producer knew."
  (setf (agent-attention-item-updated-at item) (float-time))
  (setf (agent-attention-item-state item) 'pending)
  (when (or (eq fidelity 'rich)
            (not (eq (agent-attention-item-fidelity item) 'rich)))
    (when title (setf (agent-attention-item-title item) title))
    (when detail (setf (agent-attention-item-detail item) detail))
    (when fidelity (setf (agent-attention-item-fidelity item) fidelity)))
  (when actions
    (setf (agent-attention-item-actions item) actions)
    (setf (agent-attention-item-invalid-reason item) nil))
  (agent-attention--refresh-display)
  item)

;;;; Producers

(defun agent-attention--on-event (buffer event-plist)
  "Turn a delivered session EVENT-PLIST for BUFFER into inbox records.
Member of `agent-session-event-functions'.  Sends no session input, so
delivery stays non-reentrant."
  (let ((payload (plist-get event-plist :payload)))
    (pcase (plist-get event-plist :type)
      ('blocked
       (pcase (plist-get payload :kind)
         ('permission (agent-attention--file-from-payload
                       buffer 'permission payload))
         ('question (agent-attention--file-from-payload
                     buffer 'question payload))
         ;; A backend that reported no kind reported only that the
         ;; session is waiting.  Filing an item would require guessing
         ;; why, so nothing is filed; the switcher still shows waiting.
         (_ nil)))
      ('error
       (agent-attention-file
        buffer :kind 'error
        :title (or (plist-get payload :error) "turn ended abnormally")
        :detail (plist-get payload :message)
        :fidelity (or (plist-get payload :fidelity) 'coarse))
       ;; An abnormal end is a turn end: the dialogs that turn was
       ;; waiting on are gone, and outstanding requests belonging to it
       ;; can no longer be answered.
       (agent-attention--retire-unkeyed buffer)
       (agent-attention-invalidate-buffer
        buffer "the turn ended abnormally before this request was answered"))
      ((or 'stop 'idle-prompt)
       (unless (plist-get event-plist :redundant)
         (agent-attention--note-completion buffer)
         (agent-attention--retire-unkeyed buffer)
         (agent-attention-invalidate-buffer
          buffer "the turn ended before this request was answered")))
      ((or 'submit 'activity)
       (agent-attention--note-progress buffer)))))

(defun agent-attention--file-from-payload (buffer kind payload)
  "File a KIND item for BUFFER from a blocked-event PAYLOAD."
  (agent-attention-file
   buffer :kind kind
   :title (or (plist-get payload :tool)
              (plist-get payload :message)
              (symbol-name kind))
   :detail (plist-get payload :detail)
   :request-key (plist-get payload :request-id)
   :fidelity (or (plist-get payload :fidelity) 'coarse)))

(defun agent-attention--note-completion (buffer)
  "File a completion item for BUFFER unless it is being read right now."
  (unless (agent-attention--being-read-p buffer)
    (agent-attention-file buffer :kind 'completion
                          :title "turn finished" :fidelity 'rich)))

(defun agent-attention--note-progress (buffer)
  "Clear the items BUFFER's own progress disproves.
Pending completion items go, and so do pending permission and question
items that carry no request key -- at whatever fidelity.  A session that
demonstrably moved on is no longer waiting on the dialog those items
described, and Claude's rich `PermissionRequest' items carry no request
key either, so keeping only the coarse ones would leave the rich ones
listed forever.  Fidelity decides which producer's text survives a
merge; it never decides whether an item still applies.

Request-keyed items are untouched: they clear only when their own
request is answered or invalidated."
  (agent-attention--drop
   (lambda (item)
     (and (eq (agent-attention-item-buffer item) buffer)
          (eq (agent-attention-item-state item) 'pending)
          (null (agent-attention-item-request-key item))
          (memq (agent-attention-item-kind item)
                '(completion permission question))))))

(defun agent-attention--retire-unkeyed (buffer)
  "Retire BUFFER's pending permission and question items with no request key.
A dialog reported without a request identity -- every Claude one, and
Codex's terminal hook -- can only be tracked by the session's own
lifecycle, because nothing identifies the dialog itself.  Whatever the
fidelity of the report, once the turn has ended, ended abnormally, or
the session has been torn down, that dialog is gone: the item must go
with it, or a rich Claude permission item stays listed for the rest of
the session.  Fidelity decides which producer's text survives a merge;
it never decides whether an item still applies.

Completion items are deliberately not retired here: they are what the
user has not read yet, and they clear by being read or by the session
moving on."
  (agent-attention--drop
   (lambda (item)
     (and (eq (agent-attention-item-buffer item) buffer)
          (eq (agent-attention-item-state item) 'pending)
          (null (agent-attention-item-request-key item))
          (memq (agent-attention-item-kind item) '(permission question))))))

;;;; Clearing and invalidation

(defun agent-attention--drop (predicate)
  "Remove every item satisfying PREDICATE."
  (let ((before (length agent-attention--items)))
    (setq agent-attention--items
          (seq-remove predicate agent-attention--items))
    (unless (= before (length agent-attention--items))
      (agent-attention--refresh-display))))

(defun agent-attention-mark-seen (item)
  "Mark ITEM as seen."
  (setf (agent-attention-item-state item) 'seen)
  (agent-attention--refresh-display)
  item)

(defun agent-attention-delete (item)
  "Remove ITEM from the inbox."
  (agent-attention--drop (lambda (other) (eq other item))))

(defun agent-attention-resolve (item &optional reason)
  "Remove ITEM because its request was answered.
REASON is recorded for the message the inbox shows."
  (setf (agent-attention-item-invalid-reason item) reason)
  (agent-attention-delete item))

(defun agent-attention--hand-back-requests ()
  "Hand every outstanding routed request back to its backend.
Called when `agent-attention-mode' is disabled.  A request the inbox
accepted responsibility for is still outstanding at the backend, and
dropping the inbox would leave the session waiting forever, so each
item's FALLBACK -- the backend's own way of asking -- runs instead.
Items whose backend supplied no fallback are invalidated with an
explanation rather than silently abandoned."
  (dolist (item (copy-sequence agent-attention--items))
    (when (and (agent-attention-item-request-key item)
               (agent-attention-item-actions item)
               (not (gethash (agent-attention-item-id item)
                             agent-attention--invoked)))
      (if-let* ((fallback (agent-attention-item-fallback item)))
          (condition-case err
              (progn
                (funcall fallback)
                (puthash (agent-attention-item-id item) t
                         agent-attention--invoked)
                (agent-attention-resolve item "handed back to the backend"))
            (error
             ;; The hand-back failed, so the request is still open.
             ;; Resolving it here would erase the only record that
             ;; something is still waiting on an answer.  The item stays
             ;; pending with its actions intact and says what happened.
             (setf (agent-attention-item-invalid-reason item)
                   (format "handing this request back to its backend failed \
\(%s); re-enable `agent-attention-mode' to answer it"
                           (error-message-string err)))
             (display-warning
              'agent
              (format "could not hand a request back to its backend: %s"
                      (error-message-string err))
              :warning)))
        (setf (agent-attention-item-actions item) nil)
        (setf (agent-attention-item-invalid-reason item)
              "the attention inbox was disabled while this request was open")
        (setf (agent-attention-item-state item) 'seen))))
  (agent-attention--refresh-display))

(defun agent-attention-invalidate-buffer (buffer reason)
  "Invalidate BUFFER's request-keyed items because of REASON.
Their response closures are disarmed and the items are marked seen with
an explanatory note, because the backend can no longer accept an
answer.  Items without a request key are untouched."
  (dolist (item agent-attention--items)
    (when (and (eq (agent-attention-item-buffer item) buffer)
               (agent-attention-item-request-key item)
               (agent-attention-item-actions item))
      (setf (agent-attention-item-actions item) nil)
      (setf (agent-attention-item-invalid-reason item) reason)
      (setf (agent-attention-item-state item) 'seen)))
  (agent-attention--refresh-display))

(defun agent-attention-invoke (item action)
  "Run ACTION of ITEM once.
ACTION is one (KEY LABEL . CLOSURE) entry of ITEM's actions.  There are
exactly three outcomes, and each is explicit:

- ANSWERED: the closure returns normally.  Only then is the item
  recorded as invoked, so a response that never reached the backend
  never counts as an answer.  Every action of the item is retired
  together, because the request itself has been answered.
- INVALIDATED: the item's actions were already disarmed, so the action
  reports why instead of sending a stale response.
- RESPONSE-FAILED: the closure signals.  The item keeps its actions and
  stays answerable, a queue-independent message names the failure, and
  nothing is marked invoked.  Retrying is safe: the backend's own
  responder is one-shot, so a response that did get through is dropped
  on the second attempt rather than duplicated."
  (let ((key (agent-attention-item-id item)))
    (cond
     ((gethash key agent-attention--invoked)
      (message "agent: this request was already answered"))
     ((null (agent-attention-item-actions item))
      (message "agent: %s"
               (or (agent-attention-item-invalid-reason item)
                   "this request can no longer be answered")))
     (t
      (condition-case err
          (progn
            (funcall (cddr action))
            (puthash key t agent-attention--invoked))
        (error
         (message "agent: sending that response failed: %s"
                  (error-message-string err))))))))

;;;; Reading detection

(defun agent-attention--being-read-p (buffer)
  "Return non-nil when the user is looking at BUFFER right now.
True only when the selected window of a focused frame shows BUFFER: a
buffer merely visible in an unselected split, or in an unfocused frame,
is not being read.  A frame whose focus state Emacs cannot report is
treated as focused, so an unreportable terminal frame does not fill the
inbox with items the user was in fact watching."
  (and (buffer-live-p buffer)
       (seq-some
        (lambda (frame)
          (and (not (null (frame-focus-state frame)))
               (eq (window-buffer (frame-selected-window frame)) buffer)))
        (frame-list))))

(defun agent-attention--on-window-selection-change (frame)
  "Mark FRAME's newly selected session buffer's completions as seen."
  (when (and agent-attention-mode
             (frame-live-p frame)
             (not (null (frame-focus-state frame))))
    (let ((buffer (window-buffer (frame-selected-window frame))))
      (dolist (item agent-attention--items)
        (when (and (eq (agent-attention-item-buffer item) buffer)
                   (eq (agent-attention-item-kind item) 'completion))
          (setf (agent-attention-item-state item) 'seen)))
      (agent-attention--refresh-display))))

;;;; Per-session teardown

(defun agent-attention--watch (buffer)
  "Arrange for BUFFER's request-keyed items to be invalidated on teardown."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (cl-pushnew #'agent-attention--teardown-current
                  agent--teardown-functions))))

(defun agent-attention--teardown-current ()
  "Retire and invalidate the current session buffer's open items.
Dialogs reported without a request identity die with the session, so
they are retired; requests that carry one are invalidated with an
explanation, because their record is worth keeping even though no
answer can reach the backend any more."
  (agent-attention--retire-unkeyed (current-buffer))
  (agent-attention-invalidate-buffer
   (current-buffer) "the session was torn down"))

;;;; Switcher annotation

(defun agent-attention--annotation (buffer)
  "Return the switcher annotation for session BUFFER, or nil."
  (let (action unread)
    (dolist (item agent-attention--items)
      (when (and (eq (agent-attention-item-buffer item) buffer)
                 (eq (agent-attention-item-state item) 'pending))
        (if (memq (agent-attention-item-kind item)
                  agent-attention--action-kinds)
            (setq action t)
          (when (eq (agent-attention-item-kind item) 'completion)
            (setq unread t)))))
    (cond (action "!") (unread "•"))))

;;;; Display refresh

(declare-function agent-attention--refresh-buffer "agent-attention" ())

(defun agent-attention--refresh-display ()
  "Refresh the inbox buffer when one is showing.
`agent-attention--refresh-buffer' is defined in the UI section below;
the forward declaration keeps byte-compilation warning-free while the
lifecycle code stays in its own section."
  (when (fboundp 'agent-attention--refresh-buffer)
    (agent-attention--refresh-buffer)))

;;;; Minor mode

(defvar agent-attention-backend-setup-functions nil
  "Functions run with no arguments when `agent-attention-mode' turns on.
Backends add routing that must exist only while the inbox is live.")

(defvar agent-attention-backend-teardown-functions nil
  "Functions run with no arguments when `agent-attention-mode' turns off.")

;;;###autoload
(define-minor-mode agent-attention-mode
  "Global minor mode recording what AI sessions need the user for.
Owns every hook the attention module installs; loading the file
installs nothing.  Inbox commands invoked while the mode is off say so
instead of showing stale data."
  :global t
  :group 'agent-attention
  (if agent-attention-mode
      (progn
        (add-hook 'agent-session-event-functions #'agent-attention--on-event)
        (add-hook 'agent-session-annotation-functions
                  #'agent-attention--annotation)
        (add-hook 'window-selection-change-functions
                  #'agent-attention--on-window-selection-change)
        (run-hooks 'agent-attention-backend-setup-functions))
    (remove-hook 'agent-session-event-functions #'agent-attention--on-event)
    (remove-hook 'agent-session-annotation-functions
                 #'agent-attention--annotation)
    (remove-hook 'window-selection-change-functions
                 #'agent-attention--on-window-selection-change)
    (run-hooks 'agent-attention-backend-teardown-functions)
    ;; Backend teardown stops new requests reaching the inbox; this
    ;; returns the ones already routed, so none is stranded.
    (agent-attention--hand-back-requests)))

;;;; Provide

(provide 'agent-attention)
;;; agent-attention.el ends here
```

Note `window-selection-change-functions` is called with the frame whose
window selection changed, which is what
`agent-attention--on-window-selection-change` takes.

Update the `Makefile`:

```make
SRC := agent.el agent-account.el agent-capture.el agent-slack.el agent-snippet.el agent-claude-cli.el agent-claude.el agent-codex.el agent-chief.el agent-attention.el
TEST_FILES := test/agent-test.el test/agent-account-test.el test/agent-capture-test.el test/agent-slack-test.el test/agent-snippet-test.el test/agent-claude-cli-test.el test/agent-claude-test.el test/agent-codex-test.el test/agent-chief-test.el test/agent-attention-test.el
```

Add to `agent.el`'s split-module autoload block:

```elisp
(autoload 'agent-attention "agent-attention" nil t)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test` and `make compile` — both clean.  (The `agent-attention`
autoload points at a command Task 6 defines; byte-compiling an
`autoload` form for a not-yet-defined command is not a warning, but if
the compiler complains, move the autoload line to Task 6.)

- [ ] **Step 5: Commit**

```bash
git add agent-attention.el test/agent-attention-test.el Makefile agent.el
git commit -m "agent: add attention records and their lifecycle"
```

---

### Task 6: The attention inbox buffer

**Files:**
- Modify: `agent-attention.el` (new `;;;; Inbox UI` section before the
  minor mode)
- Test: `test/agent-attention-test.el`

**Interfaces:**
- Consumes: everything Task 5 produced.
- Produces: the interactive command `agent-attention`, the major mode
  `agent-attention-list-mode`, and the buffer `*agent-attention*`.

- [ ] **Step 1: Write the failing tests**

```elisp
(ert-deftest agent-attention-test-sort/action-items-come-first ()
  "Pending action items sort before unread completions and seen items."
  (agent-attention-test--with-store
    (let ((buffer (agent-attention-test--buffer)))
      (unwind-protect
          (cl-letf (((symbol-function 'agent-attention--being-read-p)
                     (lambda (_b) nil)))
            (agent-attention--note-completion buffer)
            (agent-attention-file buffer :kind 'info :title "stashed"
                                  :fidelity 'rich)
            (agent-attention-mark-seen
             (car (last (agent-attention-items))))
            (agent-attention-file buffer :kind 'permission :title "Bash"
                                  :fidelity 'rich)
            (should (equal (mapcar #'agent-attention-item-kind
                                   (agent-attention--sorted-items))
                           '(permission completion info))))
        (kill-buffer buffer)))))

(ert-deftest agent-attention-test-entries/render-every-column ()
  "Each row renders session, backend, account, state, kind, detail, age."
  (agent-attention-test--with-store
    (let ((buffer (agent-attention-test--buffer)))
      (unwind-protect
          (cl-letf (((symbol-function 'agent-session-display-state)
                     (lambda (&rest _) 'unknown)))
            (agent-attention-file buffer :kind 'permission :title "Bash"
                                  :detail "ls -l" :fidelity 'rich)
            (let* ((entry (car (agent-attention--entries)))
                   (columns (append (cadr entry) nil)))
              (should (= (length columns) 7))
              (should (equal (nth 0 columns) "project"))
              (should (equal (nth 1 columns) "Test"))
              (should (equal (nth 2 columns) "personal"))
              (should (equal (nth 3 columns) "unknown"))
              (should (equal (nth 4 columns) "permission"))
              (should (string-match-p "ls -l" (nth 5 columns)))))
        (kill-buffer buffer)))))

(ert-deftest agent-attention-test-entries/show-the-queued-count ()
  "The session column reports queued prompts when the queue module is on."
  (agent-attention-test--with-store
    (let ((buffer (agent-attention-test--buffer)))
      (unwind-protect
          (cl-letf (((symbol-function 'agent-queue-count) (lambda (_b) 2))
                    ((symbol-function 'agent-session-display-state)
                     (lambda (&rest _) 'busy)))
            (agent-attention-file buffer :kind 'permission :title "Bash"
                                  :fidelity 'rich)
            (should (equal (aref (cadr (car (agent-attention--entries))) 0)
                           "project q2")))
        (kill-buffer buffer)))))

(ert-deftest agent-attention-test-inbox/refuses-while-the-mode-is-off ()
  "Opening the inbox with the mode off says so instead of showing data."
  (let ((agent-attention-mode nil))
    (should-error (agent-attention) :type 'user-error)))

(ert-deftest agent-attention-test-visit/reports-a-dead-session ()
  "Visiting an item whose buffer is gone reports it instead of erroring."
  (agent-attention-test--with-store
    (let ((buffer (agent-attention-test--buffer)))
      (agent-attention-file buffer :kind 'error :title "gone"
                            :fidelity 'rich)
      (kill-buffer buffer)
      (let ((messages nil))
        (cl-letf (((symbol-function 'message)
                   (lambda (fmt &rest args)
                     (push (apply #'format fmt args) messages))))
          (agent-attention--visit (car (agent-attention-items))))
        (should (seq-some (lambda (m) (string-match-p "no longer" m))
                          messages))))))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test` — `agent-attention--sorted-items`,
`agent-attention--entries`, `agent-attention--visit`, and
`agent-attention` are void.

- [ ] **Step 3: Implement the inbox**

Add to `agent-attention.el` before the minor-mode section:

```elisp
;;;; Inbox UI

(defconst agent-attention--buffer-name "*agent-attention*"
  "Name of the attention inbox buffer.")

(defvar agent-attention-list-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'agent-attention-visit)
    (define-key map (kbd "r") #'agent-attention-respond)
    (define-key map (kbd "m") #'agent-attention-mark-seen-at-point)
    (define-key map (kbd "d") #'agent-attention-delete-at-point)
    (define-key map (kbd "C") #'agent-attention-clear-seen)
    (define-key map (kbd "g") #'agent-attention-refresh)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `agent-attention-list-mode'.")

(define-derived-mode agent-attention-list-mode tabulated-list-mode
  "Agent Attention"
  "Major mode listing what AI sessions need the user for."
  (setq tabulated-list-format
        (vector '("Session" 18 nil)
                '("Backend" 12 nil)
                '("Account" 10 nil)
                '("State" 10 nil)
                '("Kind" 13 nil)
                (list "Detail" agent-attention-detail-width nil)
                '("Age" 8 nil)))
  ;; Rows are pre-sorted by `agent-attention--sorted-items'; leaving the
  ;; sort key nil keeps that order instead of re-sorting alphabetically.
  (setq tabulated-list-sort-key nil)
  (tabulated-list-init-header))

(defun agent-attention--group-rank (item)
  "Return the sort group of ITEM: lower sorts earlier."
  (cond
   ((and (eq (agent-attention-item-state item) 'pending)
         (memq (agent-attention-item-kind item)
               agent-attention--action-kinds))
    0)
   ((eq (agent-attention-item-state item) 'pending) 1)
   (t 2)))

(defun agent-attention--sorted-items ()
  "Return every item, pending action items first, recent first within."
  (sort (copy-sequence agent-attention--items)
        (lambda (a b)
          (let ((ra (agent-attention--group-rank a))
                (rb (agent-attention--group-rank b)))
            (if (= ra rb)
                (> (agent-attention-item-updated-at a)
                   (agent-attention-item-updated-at b))
              (< ra rb))))))

(defun agent-attention--age (item)
  "Return a compact age string for ITEM."
  (let ((seconds (max 0 (floor (- (float-time)
                                  (agent-attention-item-updated-at item))))))
    (cond ((< seconds 60) (format "%ds" seconds))
          ((< seconds 3600) (format "%dm" (/ seconds 60)))
          ((< seconds 86400) (format "%dh" (/ seconds 3600)))
          (t (format "%dd" (/ seconds 86400))))))

(defun agent-attention--detail-text (item)
  "Return the single-line detail rendering for ITEM."
  (let* ((parts (delq nil (list (agent-attention-item-title item)
                                (agent-attention-item-detail item)
                                (agent-attention-item-invalid-reason item))))
         (text (string-join parts " — ")))
    (replace-regexp-in-string "[ \t\n\r]+" " " text)))

(declare-function agent-queue-count "agent-queue" (buffer))

(defun agent-attention--session-column (item)
  "Return the session column for ITEM, with its queued count when any.
The count comes from `agent-queue' when that module is loaded; the
inbox never requires it."
  (let ((name (or (plist-get (agent-attention-item-session-label item) :name)
                  "?"))
        (buffer (agent-attention-item-buffer item)))
    (if-let* (((fboundp 'agent-queue-count))
              ((buffer-live-p buffer))
              (count (agent-queue-count buffer))
              ((> count 0)))
        (format "%s q%d" name count)
      name)))

(defun agent-attention--entries ()
  "Return `tabulated-list-entries' rows for the current items."
  (mapcar
   (lambda (item)
     (let ((label (agent-attention-item-session-label item))
           (buffer (agent-attention-item-buffer item)))
       (list item
             (vector (agent-attention--session-column item)
                     (or (plist-get label :backend) "?")
                     (or (plist-get label :account) "")
                     (if (buffer-live-p buffer)
                         (symbol-name (agent-session-display-state buffer))
                       "gone")
                     (symbol-name (agent-attention-item-kind item))
                     (agent-attention--detail-text item)
                     (agent-attention--age item)))))
   (agent-attention--sorted-items)))

(defun agent-attention--refresh-buffer ()
  "Repopulate the inbox buffer if it exists."
  (when-let* ((buffer (get-buffer agent-attention--buffer-name)))
    (with-current-buffer buffer
      (let ((point (point)))
        (setq tabulated-list-entries (agent-attention--entries))
        (tabulated-list-print t)
        (goto-char (min point (point-max)))))))

(setq agent-attention--refresh-function #'agent-attention--refresh-buffer)

(defun agent-attention--item-at-point ()
  "Return the item on the current line, or signal."
  (or (tabulated-list-get-id)
      (user-error "No attention item on this line")))

;;;###autoload
(defun agent-attention ()
  "Show the attention inbox for AI sessions."
  (interactive)
  (unless agent-attention-mode
    (user-error "Enable `agent-attention-mode' to record attention items"))
  (let ((buffer (get-buffer-create agent-attention--buffer-name)))
    (with-current-buffer buffer
      (agent-attention-list-mode)
      (setq tabulated-list-entries (agent-attention--entries))
      (tabulated-list-print))
    (pop-to-buffer buffer)))

(defun agent-attention-refresh ()
  "Refresh the inbox."
  (interactive)
  (agent-attention--refresh-buffer))

(defun agent-attention--visit (item)
  "Switch to ITEM's session buffer, or report that it is gone."
  (let ((buffer (agent-attention-item-buffer item)))
    (if (buffer-live-p buffer)
        (progn (agent-attention-mark-seen item)
               (pop-to-buffer buffer))
      (message "agent: that session is no longer live (%s)"
               (plist-get (agent-attention-item-session-label item) :name)))))

(defun agent-attention-visit ()
  "Switch to the session of the item at point."
  (interactive)
  (agent-attention--visit (agent-attention--item-at-point)))

(defun agent-attention-respond ()
  "Answer the request of the item at point.
Only items whose backend exposed a safe public respond action for that
exact request offer any choice; anything else explains why it cannot be
answered from here."
  (interactive)
  (let* ((item (agent-attention--item-at-point))
         (actions (agent-attention-item-actions item)))
    (cond
     ((null actions)
      (message "agent: %s"
               (or (agent-attention-item-invalid-reason item)
                   "this backend exposes no safe way to answer from Emacs")))
     (t
      (let* ((labels (mapcar (lambda (action)
                               (cons (cadr action) action))
                             actions))
             (choice (completing-read "Respond: " (mapcar #'car labels)
                                      nil t)))
        (agent-attention-invoke item (cdr (assoc choice labels))))))))

(defun agent-attention-mark-seen-at-point ()
  "Mark the item at point as seen."
  (interactive)
  (agent-attention-mark-seen (agent-attention--item-at-point))
  (agent-attention--refresh-buffer))

(defun agent-attention-delete-at-point ()
  "Delete the item at point."
  (interactive)
  (agent-attention-delete (agent-attention--item-at-point))
  (agent-attention--refresh-buffer))

(defun agent-attention-clear-seen ()
  "Delete every item already marked seen."
  (interactive)
  (agent-attention--drop
   (lambda (item) (eq (agent-attention-item-state item) 'seen)))
  (agent-attention--refresh-buffer))
```

Now that `agent-attention--refresh-buffer` exists, drop the `fboundp`
guard inside `agent-attention--refresh-display`, keeping the
`declare-function` above it:

```elisp
(defun agent-attention--refresh-display ()
  "Refresh the inbox buffer when one is showing."
  (agent-attention--refresh-buffer))
```

An action entry is `(KEY LABEL . CLOSURE)`, so `(cadr action)` is the
label and `(cddr action)` the closure — matching `agent-attention-invoke`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test` and `make compile` — both clean.

- [ ] **Step 5: Commit**

```bash
git add agent-attention.el test/agent-attention-test.el
git commit -m "agent: add the attention inbox buffer"
```

---


### Task 7: Queue data model and editing

**Files:**
- Create: `agent-queue.el`
- Create: `test/agent-queue-test.el`
- Modify: `Makefile` (`SRC` and `TEST_FILES`)
- Modify: `agent.el` (split-module autoloads block)

This task builds the queue as a data structure only: items, their
evidence states, the editing operations, the switcher annotation, and
the mode that owns the annotation.  Nothing is dispatched yet, so the
whole task can be reviewed as one state machine before any prompt can
reach a backend.

**Interfaces:**
- Consumes: `agent-session-annotation-functions`,
  `agent-session-ready-to-submit-p`, `agent--teardown-functions`.
- Produces (used by Tasks 8-11, 15):
  - `agent-queue-mode` — global minor mode.
  - `agent-queue-items BUFFER` → list of item plists, in dispatch order.
    Item plist: `(:id STRING :text STRING :created-at FLOAT
    :state SYMBOL :dispatched-at FLOAT-or-nil :turn-id STRING-or-nil)`.
  - The five item states, which every later task depends on:
    - `queued` — never sent.  The **only** state that may be dispatched,
      and the only state anything may re-arm automatically.
    - `dispatched` — `agent-submit` was called for it.  Delivery is
      unproven.
    - `started` — the backend reported a turn for it.
    - `stalled` — dispatched, then no turn was ever observed.  Delivery
      is unproven and it is never retried automatically.
    - `failed` — the submission itself signaled.  Delivery is unproven
      and it is never retried automatically.
  - `agent-queue-count BUFFER`, `agent-queue--next-item BUFFER`,
    `agent-queue--dispatched-item BUFFER`.
  - `agent-queue-add BUFFER TEXT`, `agent-queue-remove BUFFER ID`,
    `agent-queue-set-text BUFFER ID TEXT`, `agent-queue-move BUFFER ID
    DELTA`.
  - `agent-queue-prompt` (command),
    `agent-queue-confirm-no-pending BUFFER ACTION`,
    `agent-queue--annotation BUFFER`.

- [ ] **Step 1: Write the failing tests**

Create `test/agent-queue-test.el`:

```elisp
;;; agent-queue-test.el --- Tests for agent-queue -*- lexical-binding: t -*-

;; Tests for the follow-up queue: the item state machine, editing, the
;; drain gate, evidence handling, failure handling, and preservation.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'agent)
(require 'agent-attention)
(require 'agent-queue)

(defvar agent-queue-test--submissions nil
  "Submissions captured by the stubbed `agent-submit'.")

(defmacro agent-queue-test--with-session (var &rest body)
  "Bind VAR to a session buffer with no protocol probe, and run BODY.
The stub backend deliberately registers no `:ready-to-submit-p', so
these tests exercise the strict path Claude and terminal Codex take:
the queue may dispatch only on recorded evidence that a turn ended
well.  `agent-submit' is captured into `agent-queue-test--submissions',
and time is frozen so a test can jump forward to show that a delay
changes no verdict, and so the stall window can be reached without
waiting.  `agent-test--tick' comes from `agent-test.el', which
`make test' loads first."
  (declare (indent 1))
  `(let ((agent-backends nil)
         (agent-attention--items nil)
         (agent-queue-test--submissions nil)
         (agent-test--clock 1000.0)
         (,var (generate-new-buffer " *agent-queue-test*")))
     (with-current-buffer ,var
       (setq-local agent--session
                   (agent-session-create :backend 'stub
                                         :directory "~/project/")))
     (apply #'agent-register-backend 'stub
            (list :buffer-p (lambda (b) (eq b ,var))
                  :find-all-buffers (lambda () (list ,var))
                  :start-session #'ignore
                  :label "Stub"))
     (unwind-protect
         (cl-letf (((symbol-function 'float-time)
                    (lambda (&optional _time) agent-test--clock))
                   ((symbol-function 'agent-submit)
                    (lambda (text &optional buffer)
                      (push (cons text buffer)
                            agent-queue-test--submissions)))
                   ((symbol-function 'agent-display-name)
                    (lambda (&optional _b) "project")))
           ,@body)
       (kill-buffer ,var))))

(defmacro agent-queue-test--with-probed-session (var &rest body)
  "Like `agent-queue-test--with-session' but with a protocol probe.
Exercises the Codex app-server path, where the backend's own readiness
verdict is evidence in its own right."
  (declare (indent 1))
  `(agent-queue-test--with-session ,var
     (apply #'agent-register-backend 'stub
            (list :buffer-p (lambda (b) (eq b ,var))
                  :find-all-buffers (lambda () (list ,var))
                  :start-session #'ignore
                  :label "Stub"
                  :ready-to-submit-p (lambda (_b) 'ready)))
     ,@body))

(ert-deftest agent-queue-test-add/keeps-order-and-counts ()
  "Items are appended in order and counted."
  (agent-queue-test--with-session buffer
    (agent-queue-add buffer "one")
    (agent-queue-add buffer "two")
    (should (equal (mapcar (lambda (i) (plist-get i :text))
                           (agent-queue-items buffer))
                   '("one" "two")))
    (should (= (agent-queue-count buffer) 2))
    (should (equal (plist-get (agent-queue--next-item buffer) :text) "one"))))

(ert-deftest agent-queue-test-edit/updates-deletes-and-reorders ()
  "Editing, deleting, and reordering act on the identified item."
  (agent-queue-test--with-session buffer
    (let ((first (agent-queue-add buffer "one")))
      (agent-queue-add buffer "two")
      (agent-queue-set-text buffer (plist-get first :id) "ONE")
      (agent-queue-move buffer (plist-get first :id) 1)
      (should (equal (mapcar (lambda (i) (plist-get i :text))
                             (agent-queue-items buffer))
                     '("two" "ONE")))
      (agent-queue-remove buffer (plist-get first :id))
      (should (equal (mapcar (lambda (i) (plist-get i :text))
                             (agent-queue-items buffer))
                     '("two"))))))

(ert-deftest agent-queue-test-edit/refuses-a-sent-item ()
  "Text and position of an item already sent cannot be changed."
  (agent-queue-test--with-session buffer
    (let ((item (agent-queue-add buffer "one")))
      (plist-put item :state 'dispatched)
      (should-error (agent-queue-set-text buffer (plist-get item :id) "x")
                    :type 'user-error)
      (should-error (agent-queue-move buffer (plist-get item :id) 1)
                    :type 'user-error))))

(ert-deftest agent-queue-test-next-item/skips-unsendable-states ()
  "Only never-dispatched items are candidates for dispatch."
  (agent-queue-test--with-session buffer
    (let ((stalled (agent-queue-add buffer "stalled"))
          (failed (agent-queue-add buffer "failed")))
      (agent-queue-add buffer "fresh")
      (plist-put stalled :state 'stalled)
      (plist-put failed :state 'failed)
      (should (equal (plist-get (agent-queue--next-item buffer) :text)
                     "fresh")))))

(ert-deftest agent-queue-test-annotation/reports-the-count ()
  "The switcher annotation reports the number of held prompts."
  (agent-queue-test--with-session buffer
    (should (null (agent-queue--annotation buffer)))
    (agent-queue-add buffer "one")
    (should (equal (agent-queue--annotation buffer) "q1"))
    (with-current-buffer buffer (setq agent-queue--paused "stalled"))
    (should (equal (agent-queue--annotation buffer) "q1*"))))

(ert-deftest agent-queue-test-mode/commands-refuse-while-off ()
  "Queueing with the mode off refuses instead of accepting the prompt."
  (agent-queue-test--with-session buffer
    (let ((agent-queue-mode nil))
      (should-error (agent-queue-prompt buffer) :type 'user-error))))

(ert-deftest agent-queue-test-confirm/asks-before-exiting ()
  "Exit-style actions confirm when queued prompts would be demoted."
  (agent-queue-test--with-session buffer
    (agent-queue-add buffer "keep me")
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
      (should-not (agent-queue-confirm-no-pending buffer "Exit")))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
      (should (agent-queue-confirm-no-pending buffer "Exit")))))

(provide 'agent-queue-test)
;;; agent-queue-test.el ends here
```

- [ ] **Step 2: Run the tests to verify they fail**

Add the files to the Makefile first (Step 3), then run `make test`.
Expected: `agent-queue` cannot be required.

- [ ] **Step 3: Implement the data model**

Create `agent-queue.el`:

```elisp
;;; agent-queue.el --- Follow-up prompt queue for AI sessions -*- lexical-binding: t -*-

;; Copyright (C) 2026

;; Author: Pablo Stafforini
;; URL: https://github.com/benthamite/agent
;; Version: 0.1
;; Package-Requires: ((emacs "30.0") (agent "0.1"))

;; This file is NOT part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; A per-session queue of follow-up prompts, submitted one at a time
;; after the session's current turn ends.  Queueing is a distinct
;; operation from steering the running turn (`agent-steer') and from
;; interrupting it (`agent-interrupt'), and this module never
;; substitutes one for another.
;;
;; The queue coexists with Codex's own Tab-queue, which stays fully
;; functional and always drains first: the readiness gate refuses to
;; dispatch while the backend reports queued input of its own.
;;
;; Delivery is at-most-once by construction.  An item is dispatched only
;; from the `queued' state, and no code path returns an item to `queued'
;; once it has been sent; a prompt whose delivery is unproven waits for
;; an explicit human decision instead.
;;
;; Loading this file installs nothing.  `agent-queue-mode' owns the
;; module's hooks; per-session timers register for teardown.

;;; Code:

(require 'agent)
(require 'agent-attention)
(require 'agent-capture)
(require 'cl-lib)
(require 'subr-x)

;;;; Customization

(defgroup agent-queue ()
  "Follow-up prompt queue for AI coding sessions."
  :group 'agent)

;; There is deliberately no queue-local debounce, and no clock of any
;; kind.  Telling a duplicate completion from a new turn's completion is
;; `agent--session-completion-canonical-p''s job, decided once in
;; `agent-session-event' from the reporting channel and delivered to
;; every consumer as the `:redundant' flag.  A second rule here would
;; let the queue and the before-exit chain disagree about which turn
;; ended, which is exactly the class of bug the single correlation
;; contract exists to remove.

(defcustom agent-queue-stall-seconds 30
  "Seconds a dispatched item may produce no observable turn before pausing.
When the window elapses with the session still idle, the queue pauses
and files an attention item.  Nothing is ever auto-redispatched."
  :type 'number
  :group 'agent-queue)

(defcustom agent-queue-poll-interval 10
  "Seconds between safety-net re-evaluations of a non-empty queue's gate.
The poll re-reads the same gate the event path uses and invents no
state; it exists so a missed or coalesced backend event delays a drain
rather than stranding it."
  :type 'number
  :group 'agent-queue)

;;;; State

(defvar-local agent-queue--items nil
  "Follow-up items for this session, in dispatch order.
Each item is a plist with `:id', `:text', `:created-at', `:state',
`:dispatched-at', and `:turn-id'.  `:state' is one of:

  `queued'      never sent.  The only dispatchable state, and the only
                state any automatic path may put an item back into.
  `dispatched'  `agent-submit' was called for it; delivery is unproven.
  `started'     the backend reported that its turn began.
  `stalled'     dispatched, but no turn was ever observed.
  `failed'      the submission call itself signaled.

`stalled' and `failed' items keep their place in the list as records of
what may already have been delivered.  Nothing re-sends them without an
explicit human decision (`agent-queue-requeue').")

(defvar-local agent-queue--paused nil
  "Non-nil, a reason string, when this session's queue is paused.")

(defvar-local agent-queue--timer nil
  "Safety-net poll timer for this session's queue, or nil.")

(defvar agent-queue--counter 0
  "Counter backing `agent-queue--new-id'.")

(defun agent-queue--new-id ()
  "Return a fresh queue item id."
  (format "q%d-%d" (cl-incf agent-queue--counter)
          (mod (floor (* 1000 (float-time))) 1000000)))

;;;; Reading the queue

(defun agent-queue-items (buffer)
  "Return session BUFFER's queue items, in dispatch order."
  (and (buffer-live-p buffer)
       (buffer-local-value 'agent-queue--items buffer)))

(defun agent-queue-count (buffer)
  "Return how many follow-up items session BUFFER still holds.
Counts records of unproven deliveries too, because those are prompts
the user has not finished deciding about."
  (length (agent-queue-items buffer)))

(defun agent-queue--item (buffer id)
  "Return session BUFFER's item with ID, or nil."
  (seq-find (lambda (item) (equal (plist-get item :id) id))
            (agent-queue-items buffer)))

(defun agent-queue--next-item (buffer)
  "Return the first item of session BUFFER that may be dispatched.
Only `queued' items qualify: an item that was already sent is never a
candidate again, whatever became of it."
  (seq-find (lambda (item) (eq (plist-get item :state) 'queued))
            (agent-queue-items buffer)))

(defun agent-queue--dispatched-item (buffer)
  "Return session BUFFER's unresolved in-flight item, or nil."
  (seq-find (lambda (item)
              (memq (plist-get item :state) '(dispatched started)))
            (agent-queue-items buffer)))

;;;; Editing the queue

(defun agent-queue--require-queued (item)
  "Signal unless ITEM has never been sent."
  (unless (eq (plist-get item :state) 'queued)
    (user-error
     "That prompt was already sent to the backend; its text and position are fixed")))

(defun agent-queue-add (buffer text)
  "Append TEXT to session BUFFER's queue and return the new item."
  (let ((item (list :id (agent-queue--new-id)
                    :text text
                    :created-at (float-time)
                    :state 'queued
                    :dispatched-at nil
                    :turn-id nil)))
    (with-current-buffer buffer
      (setq agent-queue--items (append agent-queue--items (list item))))
    (agent-queue--watch buffer)
    (agent-queue--ensure-timer buffer)
    (agent-queue--refresh-display buffer)
    item))

(defun agent-queue-remove (buffer id)
  "Remove the item with ID from session BUFFER's queue.
Removing a sent item discards the record of it; it does not undo a
delivery, and the docstring of `agent-queue--items' explains why such
records exist."
  (with-current-buffer buffer
    (setq agent-queue--items
          (seq-remove (lambda (item) (equal (plist-get item :id) id))
                      agent-queue--items))
    (unless agent-queue--items (agent-queue--cancel-timer buffer)))
  (agent-queue--refresh-display buffer))

(defun agent-queue-set-text (buffer id text)
  "Replace the text of session BUFFER's item ID with TEXT."
  (let ((item (or (agent-queue--item buffer id)
                  (user-error "No such queue item: %s" id))))
    (agent-queue--require-queued item)
    (plist-put item :text text)
    (agent-queue--refresh-display buffer)
    item))

(defun agent-queue-move (buffer id delta)
  "Move session BUFFER's item ID by DELTA positions."
  (let ((item (or (agent-queue--item buffer id)
                  (user-error "No such queue item: %s" id))))
    (agent-queue--require-queued item)
    (with-current-buffer buffer
      (let* ((items agent-queue--items)
             (index (seq-position items item #'eq))
             (target (max 0 (min (1- (length items)) (+ index delta))))
             (rest (append (seq-take items index)
                           (seq-drop items (1+ index)))))
        (setq agent-queue--items
              (append (seq-take rest target)
                      (list item)
                      (seq-drop rest target)))))
    (agent-queue--refresh-display buffer)))

;;;; Per-session resources

(defun agent-queue--watch (buffer)
  "Register queue teardown for session BUFFER."
  (with-current-buffer buffer
    (cl-pushnew #'agent-queue--teardown-current agent--teardown-functions)))

(defun agent-queue--teardown-current ()
  "Release the current session buffer's queue resources.
Task 10 extends this to preserve any remaining items first."
  (agent-queue--cancel-timer (current-buffer)))

(defun agent-queue--ensure-timer (buffer)
  "Start session BUFFER's safety-net poll timer when it has items."
  (with-current-buffer buffer
    (when (and agent-queue--items (null agent-queue--timer))
      (setq agent-queue--timer
            (run-at-time agent-queue-poll-interval agent-queue-poll-interval
                         #'agent-queue--poll buffer)))))

(defun agent-queue--cancel-timer (buffer)
  "Cancel session BUFFER's safety-net poll timer."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (timerp agent-queue--timer)
        (cancel-timer agent-queue--timer))
      (setq agent-queue--timer nil))))

;;;; Commands

(defun agent-queue--require-mode ()
  "Signal unless `agent-queue-mode' is on."
  (unless agent-queue-mode
    (user-error
     "Enable `agent-queue-mode' before queueing: nothing would drain it")))

;;;###autoload
(defun agent-queue-prompt (&optional buffer)
  "Add a follow-up prompt to session BUFFER's queue.
BUFFER defaults to the current session buffer, prompting for one when
the current buffer is not a session.  Queueing adds a prompt submitted
as its own turn after the current one ends; it does not steer the
running turn and does not interrupt it.  When the session is not busy,
offer to submit the prompt immediately instead."
  (interactive)
  (agent-queue--require-mode)
  (let* ((buf (agent--resolve-session-buffer buffer))
         (text (string-trim (read-string "Queue prompt: "))))
    (when (string-empty-p text)
      (user-error "Nothing to queue"))
    (if (and (eq (agent-session-ready-to-submit-p buf) 'ready)
             (y-or-n-p "Session is idle; submit now instead of queueing? "))
        (agent-submit text buf)
      (agent-queue-add buf text)
      (message "agent: queued (%d held)" (agent-queue-count buf)))))

(defun agent-queue-confirm-no-pending (buffer action)
  "Confirm ACTION for session BUFFER when it holds queued prompts.
Return non-nil when ACTION may proceed."
  (let ((count (agent-queue-count buffer)))
    (or (zerop count)
        (yes-or-no-p
         (format "%s has %d queued prompt%s.  %s anyway? "
                 (agent-display-name buffer) count
                 (if (= count 1) "" "s") action)))))

;;;; Switcher annotation

(defun agent-queue--annotation (buffer)
  "Return the switcher annotation for session BUFFER's queue, or nil.
The count is the number of follow-up prompts still held; a trailing
asterisk means the queue is paused and will dispatch nothing until
`agent-queue-resume'."
  (let ((count (agent-queue-count buffer)))
    (unless (zerop count)
      (format "q%d%s" count
              (if (buffer-local-value 'agent-queue--paused buffer) "*" "")))))

;;;; Display refresh

(declare-function agent-queue--refresh-buffer "agent-queue" (buffer))

(defun agent-queue--refresh-display (buffer)
  "Refresh session BUFFER's queue list buffer when one is showing."
  (when (fboundp 'agent-queue--refresh-buffer)
    (agent-queue--refresh-buffer buffer)))

;;;; Safety-net poll

(declare-function agent-queue--poll "agent-queue" (buffer))

;;;; Minor mode

;;;###autoload
(define-minor-mode agent-queue-mode
  "Global minor mode holding per-session follow-up prompt queues.
Owns the module's switcher annotation and, from Task 8, its event
subscription; loading the file installs nothing.  Queue commands
invoked while the mode is off signal instead of accepting a prompt into
a queue that nothing would drain."
  :global t
  :group 'agent-queue
  (if agent-queue-mode
      (add-hook 'agent-session-annotation-functions #'agent-queue--annotation)
    (remove-hook 'agent-session-annotation-functions
                 #'agent-queue--annotation)
    (dolist (buffer (agent-session-buffers))
      (agent-queue--cancel-timer buffer))))

;;;; Provide

(provide 'agent-queue)
;;; agent-queue.el ends here
```

`agent-queue--poll` is defined by Task 8; the forward declaration keeps
byte-compilation warning-free until then, and the timer that references
it only exists once items are added — Task 8 lands in the same series,
so no released state has a timer without its callback.

Update the `Makefile` to append `agent-queue.el` to `SRC` and
`test/agent-queue-test.el` to `TEST_FILES`, and add two lines to
`agent.el`'s split-module autoload block:

```elisp
(autoload 'agent-queue-prompt "agent-queue" nil t)
(autoload 'agent-queue-list "agent-queue" nil t)
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test` and `make compile` — both clean.

- [ ] **Step 5: Commit**

Stage `agent-queue.el`, `test/agent-queue-test.el`, `Makefile`, and
`agent.el`; commit with the message
`agent: add the follow-up queue data model`.

---

### Task 8: Drain, evidence, and failure handling

**Files:**
- Modify: `agent-queue.el` (new `;;;; The drain gate`, `;;;; Draining`,
  `;;;; Evidence from session events`, and `;;;; Pausing and stalling`
  sections; extend the minor mode and the commands section)
- Test: `test/agent-queue-test.el`

**Interfaces:**
- Consumes: Task 1's correlation contract, delivered as the `:redundant`
  flag — the queue keeps no clock of its own and never re-derives that
  verdict; Task 2's `agent-session-can-start-turn-p` and
  `agent--session-dialog-blocked-p`; Task 7's item states.
- Produces: `agent-queue--on-event`, `agent-queue--drain`,
  `agent-queue--drain-ready-p`, `agent-queue--resolve-completion`,
  `agent-queue--poll`, `agent-queue-resume` (command),
  `agent-queue-requeue` (command).

- [ ] **Step 1: Write the failing tests**

Add to `test/agent-queue-test.el`:

```elisp
(ert-deftest agent-queue-test-gate/refuses-while-the-backend-is-busy ()
  "A backend reporting busy blocks the drain."
  (agent-queue-test--with-session buffer
    (agent-queue-add buffer "one")
    (agent-session-event buffer 'stop)
    (cl-letf (((symbol-function 'agent-session-ready-to-submit-p)
               (lambda (&rest _) 'busy)))
      (agent-queue--drain buffer))
    (should (null agent-queue-test--submissions))))

(ert-deftest agent-queue-test-gate/refuses-on-unknown-readiness ()
  "An unknown readiness verdict blocks the drain."
  (agent-queue-test--with-session buffer
    (agent-queue-add buffer "one")
    (agent-session-event buffer 'stop)
    (cl-letf (((symbol-function 'agent-session-ready-to-submit-p)
               (lambda (&rest _) 'unknown)))
      (agent-queue--drain buffer))
    (should (null agent-queue-test--submissions))))

(ert-deftest agent-queue-test-gate/never-submits-into-a-dialog ()
  "A session blocked on a permission dialog receives nothing.
This is the case a display-state check cannot catch: `blocked' leaves
the session in `awaiting-input', so without explicit evidence the drain
and the safety-net poll would type the queued prompt into the dialog."
  (agent-queue-test--with-session buffer
    (agent-queue-add buffer "one")
    (agent-session-event buffer 'blocked '(:kind permission))
    (should-not (agent-queue--drain-ready-p buffer))
    (agent-queue--drain buffer)
    (agent-queue--poll buffer)
    (should (null agent-queue-test--submissions))
    ;; Answering the dialog ends the turn, which releases the gate.
    (agent-session-event buffer 'stop)
    (agent-queue--drain buffer)
    (should (= (length agent-queue-test--submissions) 1))))

(ert-deftest agent-queue-test-gate/dialog-check-does-not-trust-the-probe ()
  "Even a backend probe claiming ready cannot open a blocked dialog."
  (agent-queue-test--with-session buffer
    (agent-queue-add buffer "one")
    (agent-session-event buffer 'blocked '(:kind permission))
    (cl-letf (((symbol-function 'agent-session-ready-to-submit-p)
               (lambda (&rest _) 'ready)))
      (should-not (agent-queue--drain-ready-p buffer))
      (agent-queue--drain buffer))
    (should (null agent-queue-test--submissions))))

(ert-deftest agent-queue-test-drain/dispatches-one-item ()
  "A ready session receives exactly the head item."
  (agent-queue-test--with-session buffer
    (agent-queue-add buffer "one")
    (agent-queue-add buffer "two")
    (agent-session-event buffer 'stop)
    (agent-queue--drain buffer)
    (should (equal agent-queue-test--submissions
                   (list (cons "one" buffer))))
    (should (eq (plist-get (car (agent-queue-items buffer)) :state)
                'dispatched))))

(ert-deftest agent-queue-test-drain/never-dispatches-twice ()
  "An unresolved in-flight item blocks any further dispatch."
  (agent-queue-test--with-session buffer
    (agent-queue-add buffer "one")
    (agent-queue-add buffer "two")
    (agent-session-event buffer 'stop)
    (agent-queue--drain buffer)
    (agent-queue--drain buffer)
    (agent-queue--drain buffer)
    (should (= (length agent-queue-test--submissions) 1))))

(ert-deftest agent-queue-test-events/one-completion-schedules-one-drain ()
  "Resolving an item and resolving nothing both schedule exactly one drain.
`agent-queue--complete' deliberately does not schedule, so a completion
that resolves an item cannot enqueue a second drain alongside the
event handler's."
  (agent-queue-test--with-session buffer
    (agent-queue-add buffer "one")
    (agent-queue-add buffer "two")
    (agent-session-event buffer 'stop)
    (let ((scheduled 0))
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (_secs _rep fn &rest args)
                   (cl-incf scheduled) (apply fn args) nil)))
        ;; Nothing in flight: one drain.
        (agent-queue--on-event buffer '(:type idle-prompt :redundant nil))
        (should (= scheduled 1))
        ;; An item in flight resolves: still one drain.
        (setq scheduled 0)
        (agent-queue--on-event buffer '(:type idle-prompt :redundant nil))
        (should (= scheduled 1))))))

(ert-deftest agent-queue-test-events/duplicate-stop-drains-once ()
  "A `turn/completed' plus CLI `Stop' pair drains exactly one item."
  (agent-queue-test--with-session buffer
    (agent-queue-add buffer "one")
    (agent-queue-add buffer "two")
    (agent-session-event buffer 'stop)
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (_secs _rep fn &rest args) (apply fn args) nil)))
      (agent-queue--on-event buffer '(:type idle-prompt :redundant nil))
      (agent-queue--on-event buffer '(:type stop :redundant t)))
    (should (= (length agent-queue-test--submissions) 1))))

(ert-deftest agent-queue-test-events/no-drain-on-blocked-or-error ()
  "A blocked or failed session never receives automatic input."
  (agent-queue-test--with-session buffer
    (agent-queue-add buffer "one")
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (_secs _rep fn &rest args) (apply fn args) nil)))
      (agent-queue--on-event buffer '(:type blocked :redundant nil
                                            :payload (:kind permission)))
      (agent-queue--on-event buffer '(:type error :redundant nil
                                            :payload (:error "rate_limit"))))
    (should (null agent-queue-test--submissions))
    (should (buffer-local-value 'agent-queue--paused buffer))))

(ert-deftest agent-queue-test-correlation/matching-turn-id-completes ()
  "On a correlated transport only the matching turn id resolves an item."
  (agent-queue-test--with-session buffer
    (agent-queue-add buffer "one")
    (agent-queue-add buffer "two")
    (agent-session-event buffer 'stop)
    (agent-queue--drain buffer)
    (agent-queue--on-event buffer '(:type activity :redundant nil
                                          :payload (:turn-id "t1")))
    (should (eq (plist-get (car (agent-queue-items buffer)) :state) 'started))
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (_secs _rep fn &rest args) (apply fn args) nil)))
      (agent-queue--on-event buffer '(:type idle-prompt :redundant nil
                                            :payload (:turn-id "other")))
      (should (= (length agent-queue-test--submissions) 1))
      (agent-queue--on-event buffer '(:type idle-prompt :redundant nil
                                            :payload (:turn-id "t1"))))
    (should (equal (mapcar (lambda (i) (plist-get i :text))
                           (agent-queue-items buffer))
                   '("two")))
    (should (= (length agent-queue-test--submissions) 2))))

(ert-deftest agent-queue-test-short-turn/resolves-without-any-activity ()
  "A short Claude turn resolves without any `activity' event at all.
Claude's status poll suppresses `activity' when a turn starts and ends
between two polls, so the queue must not depend on it.  The queued
turn's own `Stop' comes from the channel that already reported the
previous turn, which is what makes it canonical -- immediately, whatever
the interval.  The whole sequence runs through `agent-session-event',
so this exercises the real correlation contract rather than a
hand-written `:redundant' flag."
  (agent-queue-test--with-session buffer
    (agent-queue-add buffer "one")
    (agent-queue-add buffer "two")
    (agent-session-event buffer 'stop '(:source claude-stop-hook))
    (agent-session-event buffer 'idle-prompt
                         '(:source claude-idle-notification))
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (_secs _rep fn &rest args) (apply fn args) nil)))
      (let ((agent-session-event-functions (list #'agent-queue--on-event)))
        (agent-queue--drain buffer)
        (should (= (length agent-queue-test--submissions) 1))
        ;; The dispatched turn starts and ends between two polls, so no
        ;; `activity' is ever reported.  Its `Stop' still resolves it.
        (agent-session-event buffer 'stop '(:source claude-stop-hook))))
    (should (equal (mapcar (lambda (i) (plist-get i :text))
                           (agent-queue-items buffer))
                   '("two")))
    (should (= (length agent-queue-test--submissions) 2))))

(ert-deftest agent-queue-test-duplicate/late-report-resolves-nothing ()
  "A duplicate of the previous turn does not resolve the new item.
Core flags it redundant from its channel, so the queue never sees it as
a turn end -- however long after the dispatch it arrives."
  (agent-queue-test--with-session buffer
    (agent-queue-add buffer "one")
    (agent-queue-add buffer "two")
    (agent-session-event buffer 'stop '(:source claude-stop-hook))
    (cl-letf (((symbol-function 'run-at-time)
               (lambda (_secs _rep fn &rest args) (apply fn args) nil)))
      (let ((agent-session-event-functions (list #'agent-queue--on-event)))
        (agent-queue--drain buffer)
        ;; The previous turn's `idle_prompt', an hour after the dispatch.
        (agent-test--tick 3600)
        (agent-session-event buffer 'idle-prompt
                             '(:source claude-idle-notification))))
    (should (= (length agent-queue-test--submissions) 1))
    (should (= (length (agent-queue-items buffer)) 2))))

(ert-deftest agent-queue-test-error/an-item-added-later-is-not-sent ()
  "A prompt queued after a failed turn is not dispatched by the poll.
The error arrives while the queue is empty, so nothing is paused; the
duplicate of that dead turn arrives next and must not be read as fresh
evidence; only then is a prompt queued.  Without a positive fresh-turn
requirement the safety-net poll would submit it into the session that
just failed."
  (agent-queue-test--with-session buffer
    (agent-session-event buffer 'submit)
    (agent-session-event buffer 'error
                         '(:error "rate_limit"
                                  :source claude-stop-failure-hook))
    (agent-session-event buffer 'stop '(:source claude-stop-hook))
    (agent-queue-add buffer "please continue")
    (should-not (agent-queue--drain-ready-p buffer))
    (agent-queue--drain buffer)
    (agent-queue--poll buffer)
    (should (null agent-queue-test--submissions))
    ;; A genuinely new turn ending re-opens the gate.
    (agent-session-event buffer 'activity)
    (agent-session-event buffer 'stop '(:source claude-stop-hook))
    (agent-queue--drain buffer)
    (should (= (length agent-queue-test--submissions) 1))))

(ert-deftest agent-queue-test-failure/never-auto-retries ()
  "A signaling submission is recorded as failed and never resent."
  (agent-queue-test--with-session buffer
    (agent-queue-add buffer "one")
    (agent-session-event buffer 'stop)
    (cl-letf (((symbol-function 'agent-submit)
               (lambda (&rest _) (error "no route to host"))))
      (agent-queue--drain buffer))
    (should (equal (mapcar (lambda (i) (plist-get i :state))
                           (agent-queue-items buffer))
                   '(failed)))
    (should (buffer-local-value 'agent-queue--paused buffer))
    (should (seq-find (lambda (item)
                        (eq (agent-attention-item-kind item) 'queue-failure))
                      (agent-attention-items)))
    ;; Resuming un-pauses but does not resend an unproven delivery.
    (agent-queue-resume buffer)
    (agent-queue--drain buffer)
    (agent-queue--poll buffer)
    (should (null agent-queue-test--submissions))
    (should (eq (plist-get (car (agent-queue-items buffer)) :state) 'failed))))

(ert-deftest agent-queue-test-stall/pauses-and-stays-unsent ()
  "A dispatch that produces no observable turn pauses and is never resent."
  (agent-queue-test--with-session buffer
    (agent-queue-add buffer "one")
    (agent-queue-add buffer "two")
    (agent-session-event buffer 'stop)
    (agent-queue--drain buffer)
    (plist-put (car (agent-queue-items buffer)) :dispatched-at
               (- (float-time) (* 2 agent-queue-stall-seconds)))
    (agent-queue--poll buffer)
    (should (buffer-local-value 'agent-queue--paused buffer))
    (should (eq (plist-get (car (agent-queue-items buffer)) :state) 'stalled))
    (should (seq-find (lambda (item)
                        (eq (agent-attention-item-kind item) 'queue-failure))
                      (agent-attention-items)))
    (agent-queue-resume buffer)
    (agent-queue--drain buffer)
    (should (= (length agent-queue-test--submissions) 2))
    (should (eq (plist-get (car (agent-queue-items buffer)) :state) 'stalled))))

(ert-deftest agent-queue-test-requeue/needs-an-explicit-decision ()
  "Re-arming an unproven delivery is explicit and confirmed."
  (agent-queue-test--with-session buffer
    (let ((item (agent-queue-add buffer "one")))
      (plist-put item :state 'stalled)
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
        (should-error (agent-queue-requeue buffer (plist-get item :id))
                      :type 'user-error))
      (should (eq (plist-get item :state) 'stalled))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
        (agent-queue-requeue buffer (plist-get item :id)))
      (should (eq (plist-get item :state) 'queued))
      (should (null (plist-get item :dispatched-at))))))

(ert-deftest agent-queue-test-order-independence/consumers-agree ()
  "Registering the queue and inbox consumers in either order agrees."
  (dolist (order '(queue-first attention-first))
    (agent-queue-test--with-session buffer
      (let ((agent-session-event-functions
             (if (eq order 'queue-first)
                 (list #'agent-queue--on-event #'agent-attention--on-event)
               (list #'agent-attention--on-event #'agent-queue--on-event))))
        (agent-queue-add buffer "one")
        (cl-letf (((symbol-function 'run-at-time)
                   (lambda (_secs _rep fn &rest args) (apply fn args) nil))
                  ((symbol-function 'agent-attention--being-read-p)
                   (lambda (_b) nil)))
          (agent-session-event buffer 'submit)
          (agent-session-event buffer 'stop '(:source claude-stop-hook)))
        (should (= (length agent-queue-test--submissions) 1))
        (should (= (length (agent-attention-items)) 1))))))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test` — `agent-queue--drain` and friends are void.

- [ ] **Step 3: Implement draining**

Add to `agent-queue.el`, after the per-session resources section:

```elisp
;;;; The drain gate

(defun agent-queue--drain-ready-p (buffer)
  "Return non-nil when session BUFFER may receive its next queued item.
Every condition is re-read here, at the moment of dispatch:

1. an item that has never been sent is waiting;
2. the queue is not paused;
3. nothing is already in flight;
4. the session did not last report `blocked' -- a session showing a
   permission or input dialog is in `awaiting-input' like any finished
   turn, and text sent now answers the dialog instead of starting a
   turn.  This is checked here and not left to the backend probe on
   purpose: the queue does not delegate the one condition whose failure
   would put words in the user's mouth;
5. `agent-session-can-start-turn-p' holds.  That is the positive
   evidence requirement, and it is what the older readiness check
   lacked: `ready' alone is satisfied by a session whose turn died, by
   a session that has reported nothing at all, and by any session whose
   backend cannot see a dialog.  It demands either a protocol probe or
   a recorded canonical `stop'/`idle-prompt'.

There is no timing condition left in the gate.  A dispatch is now
allowed only when the last thing the session reported was a turn ending
well, and the correlation contract in `agent-session-event' has already
decided which completions count.  Duplicate reports never reach here as
canonical events, so the queue needs no clock of its own."
  (with-current-buffer buffer
    (and (agent-queue--next-item buffer)
         (null agent-queue--paused)
         (null (agent-queue--dispatched-item buffer))
         (not (agent--session-dialog-blocked-p buffer))
         (agent-session-can-start-turn-p buffer))))

;;;; Draining

(defun agent-queue--schedule-drain (buffer)
  "Schedule a drain of session BUFFER outside event delivery.
Consumers of `agent-session-event-functions' must not send session
input synchronously, so every drain runs from a zero-delay timer."
  (run-at-time 0 nil #'agent-queue--drain buffer))

(defun agent-queue--drain (buffer)
  "Dispatch session BUFFER's next queued item when the gate allows.
Between the gate check and the `agent-submit' call this function
yields to no process output, so the gate cannot be invalidated
mid-dispatch.  The item leaves the `queued' state before the call and
never returns to it: if the submission signals, the item is recorded as
`failed' and the queue pauses, because whether the text reached the
backend is unknown and resending it would risk delivering it twice."
  (when (and (buffer-live-p buffer) (agent-queue--drain-ready-p buffer))
    (let ((item (agent-queue--next-item buffer)))
      (plist-put item :state 'dispatched)
      (plist-put item :dispatched-at (float-time))
      (condition-case err
          (agent-submit (plist-get item :text) buffer)
        (error
         (plist-put item :state 'failed)
         (agent-queue--pause
          buffer
          (format "submitting a queued prompt failed: %s.  \
Whether it reached the backend is unknown, so it was not resent"
                  (error-message-string err))))))
    (agent-queue--refresh-display buffer)))

(defun agent-queue--complete (buffer item)
  "Remove ITEM from session BUFFER's queue.
Deliberately does not schedule the next drain.  Exactly one place
schedules a drain per completion -- `agent-queue--on-event' -- so that
resolving an item and finding nothing to resolve lead to the same
single scheduling, and a completion can never enqueue two drains."
  (with-current-buffer buffer
    (setq agent-queue--items (delq item agent-queue--items))
    (unless agent-queue--items (agent-queue--cancel-timer buffer)))
  (agent-queue--refresh-display buffer))

;;;; Evidence from session events

(defun agent-queue--on-event (buffer event-plist)
  "Advance session BUFFER's queue from a delivered EVENT-PLIST.
Member of `agent-session-event-functions'.  Sends nothing
synchronously: every dispatch goes through a zero-delay timer.  A
`blocked' event is ignored and an `error' event pauses the queue,
because a blocked or failed session must never receive automatic
input."
  (when (agent-queue-items buffer)
    (let ((payload (plist-get event-plist :payload)))
      (pcase (plist-get event-plist :type)
        ('activity (agent-queue--note-start buffer payload))
        ('error
         (agent-queue--pause
          buffer
          (format "the backend reported the turn ended abnormally%s"
                  (if-let* ((code (plist-get payload :error)))
                      (format " (%s)" code) ""))))
        ((or 'stop 'idle-prompt)
         (unless (plist-get event-plist :redundant)
           (agent-queue--resolve-completion buffer payload)
           (agent-queue--schedule-drain buffer)))
        (_ nil)))))

(defun agent-queue--note-start (buffer payload)
  "Record backend evidence that session BUFFER's dispatched item started."
  (when-let* ((item (agent-queue--dispatched-item buffer)))
    (when (eq (plist-get item :state) 'dispatched)
      (plist-put item :state 'started)
      (when-let* ((turn (plist-get payload :turn-id)))
        (plist-put item :turn-id turn))
      (agent-queue--refresh-display buffer))))

(defun agent-queue--resolve-completion (buffer payload)
  "Resolve session BUFFER's in-flight item when PAYLOAD proves it ended.
Only canonical completions reach here -- the caller filters on the
`:redundant' flag -- so the timing question has already been decided by
`agent--session-completion-canonical-p'.  What remains is the one thing
core cannot decide: whether a completion that names a turn names THIS
item's turn.  When both sides name a turn, only a match resolves the
item; otherwise a canonical completion is this item's, because a
canonical completion means a turn ended and this item's is the only one
in flight."
  (when-let* ((item (agent-queue--dispatched-item buffer)))
    (let ((reported (plist-get payload :turn-id))
          (recorded (plist-get item :turn-id)))
      (if (and recorded reported)
          (when (equal recorded reported)
            (agent-queue--complete buffer item))
        (agent-queue--complete buffer item)))))

;;;; Pausing and stalling

(defun agent-queue--pause (buffer reason)
  "Pause session BUFFER's queue for REASON and file an attention item."
  (unless (buffer-local-value 'agent-queue--paused buffer)
    (with-current-buffer buffer (setq agent-queue--paused reason))
    (agent-queue--file-failure buffer reason)
    (agent-queue--refresh-display buffer)))

(defun agent-queue--file-failure (buffer reason)
  "File a queue-failure attention item for session BUFFER with REASON."
  (agent-attention-file buffer :kind 'queue-failure
                        :title "queued prompt not delivered"
                        :detail reason :fidelity 'rich))

(defun agent-queue--poll (buffer)
  "Re-evaluate session BUFFER's queue from the safety-net timer.
Re-reads the same gate the event path uses and invents no state.  The
stall check applies only to an item still in `dispatched': once the
backend confirmed a turn started, a long turn is a long turn, not a
stall.

The stall check asks nothing about readiness.  A dispatch marks the
session busy through its own `submit' event, so a session that swallowed
a submission without starting a turn never looks idle again, and a
readiness condition here would mean the stall never fires and the item
is stranded silently -- the exact outcome the stall exists to prevent.
The honest statement is the simple one: this item was sent, and after
`agent-queue-stall-seconds' no backend has reported a turn for it."
  (if (not (buffer-live-p buffer))
      (agent--report-leak "queue timer" "poll timer outlived %s" buffer)
    (let ((item (agent-queue--dispatched-item buffer)))
      (cond
       ((and item
             (eq (plist-get item :state) 'dispatched)
             (> (- (float-time) (or (plist-get item :dispatched-at) 0))
                agent-queue-stall-seconds))
        (plist-put item :state 'stalled)
        (agent-queue--pause
         buffer
         "the submission produced no observable turn.  It may or may not \
have been delivered, so it was not resent"))
       ((agent-queue--drain-ready-p buffer)
        (agent-queue--schedule-drain buffer))))))
```

Add the two commands to the commands section:

```elisp
;;;###autoload
(defun agent-queue-resume (&optional buffer)
  "Resume session BUFFER's paused queue.
Clears the pause so items that were never sent can be dispatched
again.  It re-arms nothing: an item recorded as `stalled' or `failed'
may already have reached the backend, and only
`agent-queue-requeue' -- an explicit, confirmed decision -- puts such an
item back in line."
  (interactive)
  (let ((buf (agent--resolve-session-buffer buffer)))
    (with-current-buffer buf (setq agent-queue--paused nil))
    (agent-queue--refresh-display buf)
    (let ((unproven (seq-count (lambda (item)
                                 (memq (plist-get item :state)
                                       '(stalled failed)))
                               (agent-queue-items buf))))
      (message "agent: queue resumed (%d never sent, %d unproven)"
               (seq-count (lambda (item)
                            (eq (plist-get item :state) 'queued))
                          (agent-queue-items buf))
               unproven))))

(defun agent-queue-requeue (buffer id)
  "Put session BUFFER's stalled or failed item ID back in line.
Ask first, naming the risk: the prompt may already have reached the
backend, so re-arming it can deliver the same text twice.  This is the
only path from an unproven delivery back to `queued', and it is never
taken by a timer or an event."
  (interactive (list (agent--resolve-session-buffer nil)
                     (read-string "Queue item id: ")))
  (let ((item (or (agent-queue--item buffer id)
                  (user-error "No such queue item: %s" id))))
    (unless (memq (plist-get item :state) '(stalled failed))
      (user-error "Only a stalled or failed item can be queued again"))
    (unless (yes-or-no-p
             (format "%S may already have been delivered.  Queue it again? "
                     (truncate-string-to-width (plist-get item :text) 60
                                               nil nil "...")))
      (user-error "Left as is"))
    (plist-put item :state 'queued)
    (plist-put item :dispatched-at nil)
    (plist-put item :turn-id nil)
    (agent-queue--refresh-display buffer)
    item))
```

Extend the minor mode to subscribe to events:

```elisp
  (if agent-queue-mode
      (progn
        (add-hook 'agent-session-event-functions #'agent-queue--on-event)
        (add-hook 'agent-session-annotation-functions
                  #'agent-queue--annotation))
    (remove-hook 'agent-session-event-functions #'agent-queue--on-event)
    (remove-hook 'agent-session-annotation-functions
                 #'agent-queue--annotation)
    (dolist (buffer (agent-session-buffers))
      (agent-queue--cancel-timer buffer)))
```

and delete the `(declare-function agent-queue--poll ...)` placeholder
from Task 7 now that the function exists above its use.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test` and `make compile` — both clean.

- [ ] **Step 5: Commit**

Stage `agent-queue.el` and `test/agent-queue-test.el`; commit with the
message `agent: drain the follow-up queue on backend evidence`.

---

### Task 9: The queue list and edit buffers

**Files:**
- Modify: `agent-queue.el` (new `;;;; Queue list UI` section before the
  minor mode)
- Test: `test/agent-queue-test.el`

**Interfaces:**
- Consumes: Tasks 7 and 8's editing and requeue functions.
- Produces: `agent-queue-list` (command), `agent-queue-list-mode`,
  `agent-queue-edit-mode`, `agent-queue--entries BUFFER`,
  `agent-queue--edit-buffer SESSION ID`,
  `agent-queue--refresh-buffer BUFFER`.

- [ ] **Step 1: Write the failing tests**

```elisp
(ert-deftest agent-queue-test-list/renders-position-state-and-text ()
  "Each row shows the position, the evidence state, and the text."
  (agent-queue-test--with-session buffer
    (agent-queue-add buffer "first thing")
    (agent-queue-add buffer "second thing")
    (let* ((entries (agent-queue--entries buffer))
           (columns (append (cadr (car entries)) nil)))
      (should (= (length entries) 2))
      (should (equal (nth 0 columns) "1"))
      (should (equal (nth 1 columns) "queued"))
      (should (string-match-p "first thing" (nth 2 columns))))))

(ert-deftest agent-queue-test-edit/saving-replaces-the-text ()
  "Saving the edit buffer writes the new text back to the item."
  (agent-queue-test--with-session buffer
    (let* ((item (agent-queue-add buffer "before"))
           (edit (agent-queue--edit-buffer buffer (plist-get item :id))))
      (unwind-protect
          (with-current-buffer edit
            (erase-buffer)
            (insert "after")
            (cl-letf (((symbol-function 'quit-window) #'ignore))
              (agent-queue-edit-save))
            (should (equal (plist-get (car (agent-queue-items buffer)) :text)
                           "after")))
        (when (buffer-live-p edit) (kill-buffer edit))))))

(ert-deftest agent-queue-test-edit/refuses-a-sent-item ()
  "Opening an edit buffer for an item already sent is refused."
  (agent-queue-test--with-session buffer
    (let ((item (agent-queue-add buffer "one")))
      (agent-session-event buffer 'stop)
      (agent-queue--drain buffer)
      (should-error (agent-queue--edit-buffer buffer (plist-get item :id))
                    :type 'user-error))))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test` — `agent-queue--entries` and `agent-queue--edit-buffer`
are void.

- [ ] **Step 3: Implement the list buffer**

Add to `agent-queue.el` before the minor-mode section:

```elisp
;;;; Queue list UI

(defvar-local agent-queue--list-session nil
  "Session buffer whose queue this list buffer shows.")

(defvar-local agent-queue--edit-session nil
  "Session buffer whose queue item this edit buffer holds.")

(defvar-local agent-queue--edit-id nil
  "Id of the queue item this edit buffer holds.")

(defvar agent-queue-list-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "a") #'agent-queue-list-add)
    (define-key map (kbd "e") #'agent-queue-list-edit)
    (define-key map (kbd "d") #'agent-queue-list-delete)
    (define-key map (kbd "M-<up>") #'agent-queue-list-move-up)
    (define-key map (kbd "M-<down>") #'agent-queue-list-move-down)
    (define-key map (kbd "RET") #'agent-queue-list-show)
    (define-key map (kbd "R") #'agent-queue-list-resume)
    (define-key map (kbd "!") #'agent-queue-list-requeue)
    (define-key map (kbd "g") #'agent-queue-list-refresh)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for `agent-queue-list-mode'.")

(define-derived-mode agent-queue-list-mode tabulated-list-mode "Agent Queue"
  "Major mode listing one session's queued follow-up prompts."
  (setq tabulated-list-format
        (vector '("#" 3 nil) '("State" 11 nil) '("Prompt" 0 nil)))
  ;; Rows are already in dispatch order; leaving the sort key nil keeps
  ;; that order instead of sorting alphabetically.
  (setq tabulated-list-sort-key nil)
  (tabulated-list-init-header))

(defun agent-queue--list-buffer-name (buffer)
  "Return the queue list buffer name for session BUFFER."
  (format "*agent-queue: %s*" (agent-display-name buffer)))

(defun agent-queue--entries (buffer)
  "Return `tabulated-list-entries' rows for session BUFFER's queue."
  (let ((index 0))
    (mapcar
     (lambda (item)
       (cl-incf index)
       (list (plist-get item :id)
             (vector (number-to-string index)
                     (symbol-name (plist-get item :state))
                     (replace-regexp-in-string
                      "[ \t\n\r]+" " " (plist-get item :text)))))
     (agent-queue-items buffer))))

(defun agent-queue--refresh-buffer (buffer)
  "Repopulate session BUFFER's queue list buffer if it exists."
  (when-let* ((list-buffer (get-buffer
                            (agent-queue--list-buffer-name buffer))))
    (with-current-buffer list-buffer
      (let ((position (point)))
        (setq tabulated-list-entries (agent-queue--entries buffer))
        (tabulated-list-print t)
        (goto-char (min position (point-max)))))))

;;;###autoload
(defun agent-queue-list (&optional buffer)
  "Show session BUFFER's queued follow-up prompts."
  (interactive)
  (agent-queue--require-mode)
  (let* ((session (agent--resolve-session-buffer buffer))
         (list-buffer (get-buffer-create
                       (agent-queue--list-buffer-name session))))
    (with-current-buffer list-buffer
      (agent-queue-list-mode)
      (setq agent-queue--list-session session)
      (setq tabulated-list-entries (agent-queue--entries session))
      (tabulated-list-print))
    (pop-to-buffer list-buffer)))

(defun agent-queue--list-session ()
  "Return this list buffer's session, or signal."
  (or (and (buffer-live-p agent-queue--list-session)
           agent-queue--list-session)
      (user-error "That session is no longer live")))

(defun agent-queue--list-id ()
  "Return the queue item id on the current line, or signal."
  (or (tabulated-list-get-id)
      (user-error "No queue item on this line")))

(defun agent-queue-list-refresh ()
  "Refresh the queue list."
  (interactive)
  (agent-queue--refresh-buffer (agent-queue--list-session)))

(defun agent-queue-list-add ()
  "Add a prompt to this session's queue."
  (interactive)
  (let ((session (agent-queue--list-session))
        (text (string-trim (read-string "Queue prompt: "))))
    (when (string-empty-p text)
      (user-error "Nothing to queue"))
    (agent-queue-add session text)))

(defun agent-queue-list-delete ()
  "Delete the queue item at point."
  (interactive)
  (agent-queue-remove (agent-queue--list-session) (agent-queue--list-id)))

(defun agent-queue-list-move-up ()
  "Move the queue item at point one position earlier."
  (interactive)
  (agent-queue-move (agent-queue--list-session) (agent-queue--list-id) -1))

(defun agent-queue-list-move-down ()
  "Move the queue item at point one position later."
  (interactive)
  (agent-queue-move (agent-queue--list-session) (agent-queue--list-id) 1))

(defun agent-queue-list-resume ()
  "Resume this session's paused queue."
  (interactive)
  (agent-queue-resume (agent-queue--list-session)))

(defun agent-queue-list-requeue ()
  "Queue the stalled or failed item at point again, after confirming."
  (interactive)
  (agent-queue-requeue (agent-queue--list-session) (agent-queue--list-id)))

(defun agent-queue-list-show ()
  "Show the full text of the queue item at point."
  (interactive)
  (let* ((session (agent-queue--list-session))
         (item (agent-queue--item session (agent-queue--list-id))))
    (message "%s" (plist-get item :text))))

(defvar agent-queue-edit-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'agent-queue-edit-save)
    (define-key map (kbd "C-c C-k") #'agent-queue-edit-cancel)
    map)
  "Keymap for `agent-queue-edit-mode'.")

(define-minor-mode agent-queue-edit-mode
  "Minor mode for editing one queued follow-up prompt.
\\<agent-queue-edit-mode-map>\\[agent-queue-edit-save] saves the text
back to the queue; \\[agent-queue-edit-cancel] discards it."
  :lighter " AgentQueueEdit"
  :keymap agent-queue-edit-mode-map)

(defun agent-queue--edit-buffer (session id)
  "Return an edit buffer holding SESSION's queue item ID.
Signal when the item was already sent: its text is with the backend."
  (let* ((item (or (agent-queue--item session id)
                   (user-error "No such queue item: %s" id)))
         (buffer (get-buffer-create (format "*agent-queue-edit: %s*" id))))
    (agent-queue--require-queued item)
    (with-current-buffer buffer
      (erase-buffer)
      (insert (plist-get item :text))
      (text-mode)
      (agent-queue-edit-mode 1)
      (setq agent-queue--edit-session session)
      (setq agent-queue--edit-id id)
      (goto-char (point-min)))
    buffer))

(defun agent-queue-list-edit ()
  "Edit the queue item at point in its own buffer."
  (interactive)
  (pop-to-buffer (agent-queue--edit-buffer (agent-queue--list-session)
                                           (agent-queue--list-id))))

(defun agent-queue-edit-save ()
  "Save this edit buffer's text back to its queue item."
  (interactive)
  (let ((session agent-queue--edit-session)
        (id agent-queue--edit-id)
        (text (string-trim (buffer-string)))
        (buffer (current-buffer)))
    (when (string-empty-p text)
      (user-error "Refusing to save an empty prompt"))
    (agent-queue-set-text session id text)
    (quit-window nil (get-buffer-window buffer))
    (kill-buffer buffer)))

(defun agent-queue-edit-cancel ()
  "Discard this edit buffer without changing the queue."
  (interactive)
  (kill-buffer (current-buffer)))
```

Now that `agent-queue--refresh-buffer` exists, drop the `fboundp` guard
in `agent-queue--refresh-display`, keeping the `declare-function` above
it so byte-compilation stays warning-free:

```elisp
(defun agent-queue--refresh-display (buffer)
  "Refresh session BUFFER's queue list buffer when one is showing."
  (agent-queue--refresh-buffer buffer))
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test` and `make compile` — both clean.

- [ ] **Step 5: Commit**

Stage `agent-queue.el` and `test/agent-queue-test.el`; commit with the
message `agent: add the queue list and edit buffers`.

---

### Task 10: Durable preservation of queued prompts

**Files:**
- Modify: `agent-queue.el` (new `;;;; Preservation` section; extend
  `agent-queue--teardown-current`)
- Test: `test/agent-queue-test.el`

**Interfaces:**
- Consumes: `agent-capture-store-prompt`, `agent-attention-file`.
- Produces: `agent-queue-stash ()`,
  `agent-queue--preserve BUFFER REASON &optional EXPECTED-ID`,
  `agent-queue--persist ENTRY BUFFER`, `agent-queue--copy-session`.
  Stash entry plist: `(:id :session :label :reason :items :expected-id
  :handles :unwritten :notice)`.

- [ ] **Step 1: Write the failing tests**

```elisp
(defmacro agent-queue-test--with-capture (&rest body)
  "Run BODY with a disposable capture directory and an empty stash."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "agent-queue-test" t))
          (agent-prompt-capture-directory (file-name-as-directory dir))
          (agent-queue--stash nil))
     (unwind-protect (progn ,@body)
       (delete-directory dir t))))

(ert-deftest agent-queue-test-preserve/stashes-before-clearing ()
  "The stash entry exists before the buffer's queue is emptied.
A failure between the two must not be able to drop the items."
  (agent-queue-test--with-capture
    (agent-queue-test--with-session buffer
      (agent-queue-add buffer "keep me")
      (let ((seen nil))
        (cl-letf (((symbol-function 'agent-capture-store-prompt)
                   (lambda (&rest _)
                     (setq seen (list :stashed (length agent-queue--stash)
                                      :buffer (agent-queue-count buffer)))
                     (error "stop here"))))
          (cl-letf (((symbol-function 'display-warning) #'ignore))
            (agent-queue--preserve buffer 'teardown)))
        (should (equal (plist-get seen :stashed) 1))))))

(ert-deftest agent-queue-test-preserve/writes-items-and-files-a-notice ()
  "Teardown moves items to the stash, writes them, and says where."
  (agent-queue-test--with-capture
    (agent-queue-test--with-session buffer
      (agent-queue-add buffer "keep me")
      (agent-queue--preserve buffer 'teardown)
      (should (null (agent-queue-items buffer)))
      (let ((entry (car (agent-queue-stash))))
        (should (= (length (plist-get entry :items)) 1))
        (should (= (length (plist-get entry :handles)) 1))
        (should (null (plist-get entry :unwritten)))
        (should (file-exists-p
                 (plist-get (car (plist-get entry :handles)) :file))))
      (should (seq-find (lambda (item)
                          (eq (agent-attention-item-kind item) 'info))
                        (agent-attention-items))))))

(ert-deftest agent-queue-test-preserve/partial-write-keeps-what-succeeded ()
  "A write that fails partway keeps the handles it already earned."
  (agent-queue-test--with-capture
    (agent-queue-test--with-session buffer
      (agent-queue-add buffer "first")
      (agent-queue-add buffer "second")
      (let ((calls 0)
            (real (symbol-function 'agent-capture-store-prompt))
            (warned nil))
        (cl-letf (((symbol-function 'agent-capture-store-prompt)
                   (lambda (&rest args)
                     (cl-incf calls)
                     (if (= calls 2)
                         (error "disk full")
                       (apply real args))))
                  ((symbol-function 'display-warning)
                   (lambda (&rest _) (setq warned t))))
          (agent-queue--preserve buffer 'teardown))
        (should warned))
      (let ((entry (car (agent-queue-stash))))
        (should (= (length (plist-get entry :items)) 2))
        (should (= (length (plist-get entry :handles)) 1))
        (should (= (length (plist-get entry :unwritten)) 1))
        (should (equal (plist-get (car (plist-get entry :unwritten)) :text)
                       "second")))
      (should (seq-find (lambda (item)
                          (eq (agent-attention-item-kind item) 'error))
                        (agent-attention-items))))))

(ert-deftest agent-queue-test-preserve/total-write-failure-keeps-items ()
  "A capture write that fails outright keeps the items and warns."
  (agent-queue-test--with-capture
    (agent-queue-test--with-session buffer
      (agent-queue-add buffer "keep me")
      (let ((warned nil))
        (cl-letf (((symbol-function 'agent-capture-store-prompt)
                   (lambda (&rest _) (error "disk full")))
                  ((symbol-function 'display-warning)
                   (lambda (&rest _) (setq warned t))))
          (agent-queue--preserve buffer 'teardown))
        (should warned))
      (let ((entry (car (agent-queue-stash))))
        (should (= (length (plist-get entry :items)) 1))
        (should (null (plist-get entry :handles)))
        (should (= (length (plist-get entry :unwritten)) 1))))))

(ert-deftest agent-queue-test-preserve/records-what-may-have-been-sent ()
  "Only never-sent items are marked re-armable."
  (agent-queue-test--with-capture
    (agent-queue-test--with-session buffer
      (let ((sent (agent-queue-add buffer "sent")))
        (agent-queue-add buffer "fresh")
        (plist-put sent :state 'started))
      (agent-queue--preserve buffer 'restart "session-1")
      (let ((items (plist-get (car (agent-queue-stash)) :items)))
        (should (equal (mapcar (lambda (i) (plist-get i :rearmable)) items)
                       '(nil t)))))))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test` — the preservation functions are void.

- [ ] **Step 3: Implement preservation**

Add a `;;;; Preservation` section to `agent-queue.el` before the
commands section:

```elisp
;;;; Preservation

(defvar agent-queue--stash nil
  "Orphaned queue entries held outside any session buffer.
Each entry is a plist with `:id', `:session' (an `agent-session' copy),
`:label', `:reason', `:items', `:expected-id', `:handles' (the capture
entries successfully written), `:unwritten' (the items no capture entry
exists for), and `:notice' (the attention item naming where they went).
The stash lives here rather than in the session buffer so no failure
path can lose items with the dying buffer.")

(defun agent-queue-stash ()
  "Return the orphaned queue entries."
  agent-queue--stash)

(defun agent-queue--copy-session (session)
  "Return an independent copy of SESSION.
`agent-session' is defined with no copier, so the copy is built slot by
slot."
  (agent-session-create :backend (agent-session-backend session)
                        :account (agent-session-account session)
                        :directory (agent-session-directory session)
                        :instance (agent-session-instance session)
                        :id (agent-session-id session)))

(defun agent-queue--preserve (buffer reason &optional expected-id)
  "Move session BUFFER's queue items into the orphan stash.
REASON records why (`teardown' or `restart').  EXPECTED-ID, for a
restart, is the native session id whose reappearance would prove the
items may be re-attached.

Each item is tagged `:rearmable' according to whether it was ever sent:
only a `queued' item may later return to a session automatically, so an
item that was dispatched, started, stalled, or failed is preserved as a
record and a draft but is never re-armed by any automatic path.

The stash entry is built and pushed BEFORE the buffer's queue is
cleared, so a failure anywhere in this function leaves the items
reachable rather than lost with the dying buffer.  Every item is then
written to the session's capture file; failures are recorded per item
and never discard what already succeeded.  Return the stash entry, or
nil when there was nothing to preserve."
  (when-let* ((items (agent-queue-items buffer))
              (session (agent-session buffer)))
    (dolist (item items)
      (plist-put item :rearmable (eq (plist-get item :state) 'queued)))
    (let ((entry (list :id (agent-queue--new-id)
                       :session (agent-queue--copy-session session)
                       :label (agent-display-name buffer)
                       :reason reason
                       :items items
                       :expected-id expected-id
                       :handles nil
                       :unwritten nil
                       :notice nil)))
      (push entry agent-queue--stash)
      (with-current-buffer buffer
        (setq agent-queue--items nil)
        (setq agent-queue--paused nil))
      (agent-queue--cancel-timer buffer)
      (agent-queue--persist entry buffer)
      entry)))

(defun agent-queue--persist (entry buffer)
  "Write ENTRY's items to their capture file and report where they went.
BUFFER is the session buffer the items came from; it may already be
dead, in which case the attention item still identifies the session
from ENTRY's snapshot.

Items are written one at a time, so a failure partway keeps every
handle already earned and records only the remainder as unwritten.  A
partial or total failure files an error attention item and warns; it
never drops an item from the stash."
  (let (handles unwritten)
    (dolist (item (plist-get entry :items))
      (condition-case err
          (push (agent-capture-store-prompt
                 (plist-get entry :session)
                 (plist-get entry :label)
                 (plist-get item :text)
                 (format "queued-%s" (plist-get item :id)))
                handles)
        (error
         (push (list :item item :error (error-message-string err))
               unwritten))))
    (plist-put entry :handles (nreverse handles))
    (plist-put entry :unwritten
               (mapcar (lambda (failure)
                         (append (plist-get failure :item)
                                 (list :write-error
                                       (plist-get failure :error))))
                       (nreverse unwritten)))
    (if (plist-get entry :unwritten)
        (agent-queue--persist-report-failure entry buffer)
      (plist-put entry :notice
                 (agent-attention-file
                  buffer :kind 'info
                  :title (format "%d queued prompt%s saved as drafts"
                                 (length (plist-get entry :handles))
                                 (if (= (length (plist-get entry :handles)) 1)
                                     "" "s"))
                  :detail (plist-get (car (plist-get entry :handles)) :file)
                  :fidelity 'rich)))))

(defun agent-queue--persist-report-failure (entry buffer)
  "File and warn about ENTRY's unwritten items, from session BUFFER."
  (let ((written (length (plist-get entry :handles)))
        (lost (length (plist-get entry :unwritten))))
    (plist-put entry :notice
               (agent-attention-file
                buffer :kind 'error
                :title (format "%d queued prompt%s could not be saved"
                               lost (if (= lost 1) "" "s"))
                :detail (format "%d saved as drafts; %d held in memory \
until Emacs exits (%s)"
                                written lost
                                (or (plist-get (car (plist-get entry :unwritten))
                                               :write-error)
                                    "unknown error"))
                :fidelity 'rich))
    (display-warning
     'agent
     (format "could not save %d of %d queued prompt(s) for %s"
             lost (+ written lost) (plist-get entry :label))
     :warning)))
```

and replace `agent-queue--teardown-current`:

```elisp
(defun agent-queue--teardown-current ()
  "Preserve and release the current session buffer's queue."
  (agent-queue--preserve (current-buffer) 'teardown)
  (agent-queue--cancel-timer (current-buffer)))
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test` and `make compile` — both clean.

- [ ] **Step 5: Commit**

Stage `agent-queue.el` and `test/agent-queue-test.el`; commit with the
message `agent: preserve queued prompts durably on teardown`.

---

### Task 11: Restart attachment

**Files:**
- Modify: `agent.el` (forward declarations ~line 686;
  `agent--run-before-exit-functions` ~line 1568;
  `agent--confirm-no-captured-prompts` ~line 1576; `agent-handoff`
  ~line 1912; `agent-restart` ~line 2595)
- Modify: `agent-queue.el` (`agent-queue--before-restart`,
  `agent-queue--after-restart`, minor mode)
- Test: `test/agent-queue-test.el`, `test/agent-test.el`

**Interfaces:**
- Consumes: Task 10's stash.
- Produces:
  - `agent-before-restart-functions` — abnormal hook, called with
    `(BUFFER SESSION-ID)` before the old buffer is killed.
  - `agent-after-restart-functions` — abnormal hook, called with
    `(NEW-BUFFER SESSION-ID)` after `agent-start-session` returns.
  - `agent--confirm-no-pending-prompts BACKEND BUFFER ACTION` (renamed
    from `agent--confirm-no-captured-prompts`).
  - `agent-queue--before-restart`, `agent-queue--after-restart`.

- [ ] **Step 1: Write the failing tests**

Add to `test/agent-queue-test.el`:

```elisp
(ert-deftest agent-queue-test-restart/reattaches-only-never-sent-items ()
  "A matching resume re-arms the never-sent items and only those.
An item that was in flight when the restart happened may already have
reached the old session, so it comes back as a draft, not as something
the queue will send again."
  (agent-queue-test--with-capture
    (agent-queue-test--with-session buffer
      (let ((sent (agent-queue-add buffer "sent")))
        (agent-queue-add buffer "fresh")
        (plist-put sent :state 'started))
      (agent-queue--before-restart buffer "session-1")
      (should (null (agent-queue-items buffer)))
      (let ((new (generate-new-buffer " *agent-queue-test-new*"))
            (handles (plist-get (car (agent-queue-stash)) :handles)))
        (unwind-protect
            (progn
              (with-current-buffer new
                (setq-local agent--session
                            (agent-session-create :backend 'stub
                                                  :directory "~/project/"
                                                  :id "session-1")))
              (agent-queue--after-restart new "session-1")
              (should (equal (mapcar (lambda (i) (plist-get i :text))
                                     (agent-queue-items new))
                             '("fresh")))
              (should (equal (mapcar (lambda (i) (plist-get i :state))
                                     (agent-queue-items new))
                             '(queued)))
              ;; The re-armed item's draft is gone; the in-flight one's
              ;; draft remains, and so does its stash record.
              (should (= (length (agent-queue-stash)) 1))
              (let ((remaining (car (agent-queue-stash))))
                (should (= (length (plist-get remaining :items)) 1))
                (should (equal (plist-get (car (plist-get remaining :items))
                                          :text)
                               "sent")))
              (should (= (length handles) 2)))
          (kill-buffer new))))))

(ert-deftest agent-queue-test-restart/keeps-the-stash-on-a-different-id ()
  "A fork or mismatched id leaves the items durable and unsent."
  (agent-queue-test--with-capture
    (agent-queue-test--with-session buffer
      (agent-queue-add buffer "keep me")
      (agent-queue--before-restart buffer "session-1")
      (let ((new (generate-new-buffer " *agent-queue-test-new*")))
        (unwind-protect
            (progn
              (with-current-buffer new
                (setq-local agent--session
                            (agent-session-create :backend 'stub
                                                  :directory "~/project/"
                                                  :id "session-2")))
              (agent-queue--after-restart new "session-1")
              (should (null (agent-queue-items new)))
              (should (= (length (agent-queue-stash)) 1)))
          (kill-buffer new))))))

(ert-deftest agent-queue-test-restart/startup-failure-keeps-the-stash ()
  "When startup signals after the detach, the items stay stashed and durable."
  (agent-queue-test--with-capture
    (agent-queue-test--with-session buffer
      (agent-queue-add buffer "keep me")
      (agent-queue--before-restart buffer "session-1")
      ;; `agent-restart' signals before it can run the after hook.
      (should (= (length (agent-queue-stash)) 1))
      (should (plist-get (car (agent-queue-stash)) :handles))
      (should (file-exists-p
               (plist-get (car (plist-get (car (agent-queue-stash))
                                          :handles))
                          :file))))))
```

Add to `test/agent-test.el`:

```elisp
(ert-deftest agent-test-restart/runs-the-detach-and-reattach-hooks ()
  "`agent-restart' detaches before the kill and re-attaches after start."
  (agent-test--with-event-buffer buf
    (let* ((agent-backends nil)
           (new (generate-new-buffer " *agent-test-restarted*"))
           (calls nil)
           (agent-before-restart-functions
            (list (lambda (buffer id) (push (list 'before buffer id) calls))))
           (agent-after-restart-functions
            (list (lambda (buffer id) (push (list 'after buffer id) calls)))))
      (unwind-protect
          (progn
            (apply #'agent-register-backend 'restartable
                   (agent-test--backend
                    :buffer-p (lambda (b) (eq b buf))
                    :session-identity (lambda (_b) "session-1")
                    :start-session (lambda (&rest _) new)))
            (cl-letf (((symbol-function 'agent--confirm-no-pending-prompts)
                       (lambda (&rest _) t))
                      ((symbol-function 'agent--force-kill-buffer) #'ignore)
                      ((symbol-function 'agent-restart--account)
                       (lambda (&rest _) nil)))
              (with-current-buffer buf (agent-restart)))
            (should (equal (nreverse calls)
                           (list (list 'before buf "session-1")
                                 (list 'after new "session-1")))))
        (kill-buffer new)))))

(ert-deftest agent-test-restart/skips-the-reattach-hook-on-failure ()
  "A session that fails to start never gets detached state attached."
  (agent-test--with-event-buffer buf
    (let* ((agent-backends nil)
           (calls nil)
           (agent-after-restart-functions
            (list (lambda (&rest _) (push 'after calls)))))
      (apply #'agent-register-backend 'restartable
             (agent-test--backend
              :buffer-p (lambda (b) (eq b buf))
              :session-identity (lambda (_b) "session-1")
              :start-session (lambda (&rest _) (error "no process"))))
      (cl-letf (((symbol-function 'agent--confirm-no-pending-prompts)
                 (lambda (&rest _) t))
                ((symbol-function 'agent--force-kill-buffer) #'ignore)
                ((symbol-function 'agent-restart--account)
                 (lambda (&rest _) nil)))
        (with-current-buffer buf
          (should-error (agent-restart))))
      (should (null calls)))))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test` — the restart hooks are void.

- [ ] **Step 3: Implement restart attachment**

In `agent.el`, add the restart hooks immediately before `agent-restart`:

```elisp
(defcustom agent-before-restart-functions nil
  "Abnormal hook run before `agent-restart' kills a session buffer.
Each function is called with two arguments: the session BUFFER about to
be killed and the native SESSION-ID the restart will resume.  This is
the point at which per-session state that must survive the kill can be
detached, before teardown runs."
  :type 'hook
  :group 'agent)

(defcustom agent-after-restart-functions nil
  "Abnormal hook run after `agent-restart' resumed a session.
Each function is called with two arguments: the new session BUFFER and
the SESSION-ID that was resumed.  It does not run when session startup
signaled, so state detached by `agent-before-restart-functions' stays
detached rather than being attached to a session that never started."
  :type 'hook
  :group 'agent)
```

Replace the tail of `agent-restart`:

```elisp
        (setf (agent-session-account session) account)
        (run-hook-with-args 'agent-before-restart-functions buffer session-id)
        (agent--force-kill-buffer buffer)
        (let ((new-buffer (apply #'agent-start-session session
                                 :resume-id session-id extra-options)))
          (run-hook-with-args 'agent-after-restart-functions
                              new-buffer session-id)
          new-buffer)
```

Rename `agent--confirm-no-captured-prompts` and extend it:

```elisp
(defun agent--confirm-no-pending-prompts (backend buffer action)
  "Confirm ACTION for BACKEND session BUFFER when prompts are pending.
Return non-nil when ACTION may proceed.  Consults `agent-capture' for
captured drafts and `agent-queue' for armed follow-up prompts; a module
that is not installed can be holding nothing, so its check passes."
  (and (if (require 'agent-capture nil t)
           (agent-capture-confirm-no-pending backend buffer action)
         t)
       (if (require 'agent-queue nil t)
           (agent-queue-confirm-no-pending buffer action)
         t)))
```

Add the forward declaration next to the existing `agent-capture` one:

```elisp
(declare-function agent-queue-confirm-no-pending "agent-queue"
                  (buffer action))
```

Update the three call sites to the new name:
`agent--run-before-exit-functions` (~line 1570), `agent-handoff`
(~line 1912), and `agent-restart` (~line 2607).

In `agent-queue.el`, add to the preservation section:

```elisp
(defun agent-queue--before-restart (buffer session-id)
  "Detach session BUFFER's queue before a restart kills it.
Member of `agent-before-restart-functions'.  Detaching first means
teardown finds an empty queue and does nothing, so the items are
preserved exactly once."
  (agent-queue--preserve buffer 'restart session-id))

(defun agent-queue--after-restart (buffer session-id)
  "Re-attach a detached queue to BUFFER when SESSION-ID proves identity.
Member of `agent-after-restart-functions'.  Only a non-fork resume
seeds the new session's id, so a match is the one case in which the
items provably belong to this session.

Even then, only items marked `:rearmable' -- those that had never been
sent -- return to the queue, and only their capture drafts are deleted.
An item that was in flight when the restart happened may already have
reached the old session; it stays in the stash as a draft, and an info
item says so.  A mismatched id, a fork, or a failed startup leaves the
whole entry alone: durable in the capture file, visible in the inbox,
and never sent anywhere."
  (when-let* ((entry (seq-find
                      (lambda (candidate)
                        (equal (plist-get candidate :expected-id) session-id))
                      agent-queue--stash))
              (session (agent-session buffer))
              (new-id (agent-session-id session))
              ((equal new-id session-id)))
    (let* ((all (plist-get entry :items))
           (rearmable (seq-filter (lambda (item) (plist-get item :rearmable))
                                  all))
           (kept (seq-remove (lambda (item) (plist-get item :rearmable)) all)))
      (when rearmable
        (dolist (item rearmable)
          (plist-put item :dispatched-at nil)
          (plist-put item :turn-id nil))
        (with-current-buffer buffer
          (setq agent-queue--items rearmable))
        (agent-queue--watch buffer)
        (agent-queue--ensure-timer buffer)
        (agent-queue--delete-drafts entry rearmable))
      (if kept
          (progn
            (plist-put entry :items kept)
            (agent-attention-file
             buffer :kind 'info
             :title (format "%d queued prompt%s kept as drafts"
                            (length kept) (if (= (length kept) 1) "" "s"))
             :detail "they may already have reached the previous session, \
so they were not queued again"
             :fidelity 'rich))
        (when-let* ((notice (plist-get entry :notice)))
          (agent-attention-delete notice))
        (setq agent-queue--stash (delq entry agent-queue--stash)))
      (agent-queue--refresh-display buffer))))

(defun agent-queue--delete-drafts (entry items)
  "Delete ENTRY's capture drafts for ITEMS, keeping the rest."
  (dolist (item items)
    (when-let* ((tag (format "queued-%s" (plist-get item :id)))
                (handle (seq-find
                         (lambda (candidate)
                           (string-match-p (regexp-quote tag)
                                           (or (plist-get candidate :title) "")))
                         (plist-get entry :handles))))
      (condition-case err
          (progn (agent-capture--delete-prompt handle)
                 (plist-put entry :handles
                            (delq handle (plist-get entry :handles))))
        (error
         (display-warning
          'agent
          (format "could not remove a re-armed queue draft: %s"
                  (error-message-string err))
          :warning))))))
```

Register the restart hooks in the minor mode:

```elisp
  (if agent-queue-mode
      (progn
        (add-hook 'agent-session-event-functions #'agent-queue--on-event)
        (add-hook 'agent-session-annotation-functions
                  #'agent-queue--annotation)
        (add-hook 'agent-before-restart-functions
                  #'agent-queue--before-restart)
        (add-hook 'agent-after-restart-functions #'agent-queue--after-restart))
    (remove-hook 'agent-session-event-functions #'agent-queue--on-event)
    (remove-hook 'agent-session-annotation-functions
                 #'agent-queue--annotation)
    (remove-hook 'agent-before-restart-functions
                 #'agent-queue--before-restart)
    (remove-hook 'agent-after-restart-functions #'agent-queue--after-restart)
    (dolist (buffer (agent-session-buffers))
      (agent-queue--cancel-timer buffer)))
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test` and `make compile` — both clean.

- [ ] **Step 5: Commit**

Stage `agent.el`, `agent-queue.el`, `test/agent-queue-test.el`, and
`test/agent-test.el`; commit with the message
`agent: re-arm only never-sent prompts across a restart`.

---

### Task 12: Upstream codex.el extension points

**Files (sibling repo `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/codex`):**
- Modify: `codex-app-server.el` (notification dispatch
  `codex--app-server-handle-notification`, ~line 620; server-request
  handling `codex--app-server-handle-server-request` and
  `codex--app-server-answer-server-request`, ~line 3711; approval
  helpers ~lines 3733-3945; the turn functions ~line 2252; the send
  paths ~line 4179)
- Modify: `README.org` (public API section) and regenerate whatever
  export that repo keeps beside it
- Test: `codex-test.el`
- Modify: `docs/superpowers/specs/2026-07-30-attention-and-queue-design.md`
  in the **agent** repo, §6 (commit it with the agent-side Task 13
  rather than in the codex repo)

**Interfaces:**
- Produces, all public in codex.el:
  - `codex-app-server-notification-functions` — abnormal hook run with
    `(BUFFER METHOD PARAMS)` after codex.el's own handling of every
    app-server notification.  Read-only; return values ignored.
  - `codex-app-server-request-handler` — defcustom function called with
    `(BUFFER ID METHOD PARAMS RESPOND)`.  ID is the JSON-RPC request id,
    passed explicitly so an outer package can tell two outstanding
    requests of the same method apart.  RESPOND takes `(RESULT &optional
    ERROR)`; ERROR is `(CODE . MESSAGE)`.  It is one-shot and no-ops with
    a message on reuse.  Default:
    `codex-app-server-modal-request-handler`, byte-for-byte today's
    behaviour.
  - `codex-app-server-request-choices METHOD PARAMS` → list of
    `(KEY LABEL HELP RESULT)` where RESULT is the complete response body,
    or nil for requests needing free-form input.
  - `codex-app-server-turn-state &optional BUFFER` → plist
    `(:process-live BOOL :thread-id STRING-or-nil :active BOOL
    :start-pending BOOL :queued COUNT :pending-submissions COUNT
    :turn-id STRING-or-nil)`, nil for non-app-server buffers.
  - `codex-app-server-steer TEXT &optional BUFFER` — send TEXT as
    literal steering input to the running turn.
  - `codex-app-server-steer-failed-functions` — abnormal hook run with
    `(BUFFER TEXT ERROR)` when a steer request fails.

**Why steering needs its own entry point.**  The ordinary submission
path cannot be reused: `codex--app-server-submit-command` dispatches a
leading `/` to a local command and a leading `!` to a shell command
(codex-app-server.el:4079), and `codex--app-server-send-turn-input`
holds the text when reasoning steps are pending, enqueues it when a
turn start is pending, and starts a *new* turn when none is active
(codex-app-server.el:4129).  `codex--app-server-send-turn-steer` then
enqueues the text as a follow-up when `turn/steer` fails
(codex-app-server.el:4179).  Each of those is a different operation
than the one the user asked for, and three of them are silent.  The new
entry point sends literal text to the running turn, refuses every state
in which it could become something else, and reports failure instead of
converting it into a queued follow-up.

- [ ] **Step 1: Write the failing tests**

Add to `codex-test.el`, following that file's existing conventions:

```elisp
(ert-deftest codex-test-app-server-notification-functions ()
  "Observers see every notification after codex.el handled it."
  (with-temp-buffer
    (setq-local codex-terminal-backend 'app-server)
    (setq-local codex--app-server-thread-id "thread-1")
    (let* ((seen nil)
           (codex-app-server-notification-functions
            (list (lambda (buffer method params)
                    (push (list buffer method params) seen)))))
      (cl-letf (((symbol-function 'codex--app-server-turn-started) #'ignore))
        (codex--app-server-handle-notification
         '((method . "turn/started")
           (params . ((threadId . "thread-1")
                      (turn . ((id . "turn-1"))))))))
      (should (= (length seen) 1))
      (should (equal (nth 1 (car seen)) "turn/started")))))

(ert-deftest codex-test-app-server-notification-observer-error-is-contained ()
  "A signaling observer does not stop the remaining observers."
  (with-temp-buffer
    (setq-local codex-terminal-backend 'app-server)
    (let* ((reached nil)
           (codex-app-server-notification-functions
            (list (lambda (&rest _) (error "boom"))
                  (lambda (&rest _) (setq reached t)))))
      (cl-letf (((symbol-function 'message) #'ignore))
        (codex--app-server-handle-notification
         '((method . "thread/compacted") (params . nil))))
      (should reached))))

(ert-deftest codex-test-app-server-request-handler-receives-the-id ()
  "The handler is told which request it is answering."
  (with-temp-buffer
    (let* ((seen nil)
           (sent nil)
           (codex-app-server-request-handler
            (lambda (_buffer id method _params respond)
              (push (cons id method) seen)
              (funcall respond '((decision . "accept"))))))
      (cl-letf (((symbol-function 'codex--app-server-send-response)
                 (lambda (id result) (push (cons id result) sent))))
        (codex--app-server-answer-server-request
         (current-buffer)
         '((id . 7) (method . "item/fileChange/requestApproval")
           (params . nil)))
        (codex--app-server-answer-server-request
         (current-buffer)
         '((id . 8) (method . "item/fileChange/requestApproval")
           (params . nil))))
      ;; Two requests of the same method stay distinguishable.
      (should (equal (mapcar #'car seen) '(8 7)))
      (should (equal (mapcar #'car sent) '(8 7))))))

(ert-deftest codex-test-app-server-responder-is-one-shot ()
  "Answering the same request twice sends one response."
  (with-temp-buffer
    (let ((sent nil))
      (cl-letf (((symbol-function 'codex--app-server-send-response)
                 (lambda (id result) (push (cons id result) sent)))
                ((symbol-function 'message) #'ignore))
        (let ((respond (codex--app-server-make-responder (current-buffer) 3)))
          (funcall respond '((decision . "accept")))
          (funcall respond '((decision . "cancel")))))
      (should (= (length sent) 1)))))

(ert-deftest codex-test-app-server-responder-retries-after-a-failed-send ()
  "A send that fails leaves the request answerable, and the retry sends.
Marking the responder answered before the write would swallow the retry
and let the caller record an unsent request as answered."
  (with-temp-buffer
    (let ((sent nil)
          (attempts 0))
      (cl-letf (((symbol-function 'codex--app-server-send-response)
                 (lambda (id result)
                   (cl-incf attempts)
                   (when (= attempts 1) (error "process is not running"))
                   (push (cons id result) sent)))
                ((symbol-function 'message) #'ignore))
        (let ((respond (codex--app-server-make-responder (current-buffer) 5)))
          (should-error (funcall respond '((decision . "accept"))))
          (should (null sent))
          (funcall respond '((decision . "accept")))
          (should (equal sent '((5 . ((decision . "accept"))))))
          ;; Now it really is answered, so a third call sends nothing.
          (funcall respond '((decision . "cancel")))
          (should (= (length sent) 1)))))))

(ert-deftest codex-test-app-server-responder-signals-for-a-dead-buffer ()
  "Answering into a dead session signals instead of silently succeeding."
  (let ((buffer (generate-new-buffer " *codex-test-dead*")))
    (kill-buffer buffer)
    (let ((respond (codex--app-server-make-responder buffer 6)))
      (should-error (funcall respond '((decision . "accept")))))))

(ert-deftest codex-test-app-server-request-choices-encode-responses ()
  "Choice tables carry the complete response body for each choice."
  (let ((choices (codex-app-server-request-choices
                  "item/fileChange/requestApproval" nil)))
    (should choices)
    (should (equal (nth 3 (car choices)) '((decision . "accept"))))
    (should (cl-every (lambda (choice) (= (length choice) 4)) choices))))

(ert-deftest codex-test-app-server-request-choices-refuse-free-form ()
  "Requests needing free-form input expose no choice table."
  (should-not (codex-app-server-request-choices
               "item/tool/requestUserInput" nil))
  (should-not (codex-app-server-request-choices
               "mcpServer/elicitation/request"
               '((requestedSchema . ((properties . ((name . nil))))))))
  (should (codex-app-server-request-choices
           "mcpServer/elicitation/request" '((requestedSchema . nil)))))

(ert-deftest codex-test-app-server-turn-state-reports-real-state ()
  "The probe reports process and thread readiness and every held state."
  (with-temp-buffer
    (should-not (codex-app-server-turn-state))
    (setq-local codex-terminal-backend 'app-server)
    (setq-local codex--app-server-process nil)
    (setq-local codex--app-server-thread-id nil)
    (setq-local codex--app-server-turn-active-p nil)
    (setq-local codex--app-server-turn-start-pending-p nil)
    (setq-local codex--app-server-queued-turn-inputs nil)
    (setq-local codex--app-server-pending-reasoning-steps nil)
    (setq-local codex--app-server-reasoning-waiting-submissions nil)
    (setq-local codex--app-server-startup-submissions nil)
    (setq-local codex--app-server-current-turn-id nil)
    (let ((state (codex-app-server-turn-state)))
      ;; A dead process and an unstarted thread are reported, not
      ;; silently indistinguishable from an idle ready session.
      (should-not (plist-get state :process-live))
      (should-not (plist-get state :thread-id))
      (should (= (plist-get state :queued) 0))
      (should (= (plist-get state :pending-submissions) 0)))
    (setq-local codex--app-server-queued-turn-inputs '((:text "a")))
    (setq-local codex--app-server-startup-submissions '((:text "b")))
    (setq-local codex--app-server-current-turn-id "turn-9")
    (setq-local codex--app-server-turn-active-p t)
    (let ((state (codex-app-server-turn-state)))
      (should (plist-get state :active))
      (should (= (plist-get state :queued) 1))
      (should (= (plist-get state :pending-submissions) 1))
      (should (equal (plist-get state :turn-id) "turn-9")))))

(ert-deftest codex-test-app-server-steer-sends-literal-text ()
  "Steering sends the text verbatim with the running turn's id."
  (with-temp-buffer
    (setq-local codex-terminal-backend 'app-server)
    (setq-local codex--app-server-thread-id "thread-1")
    (let ((requests nil))
      (cl-letf (((symbol-function 'codex-app-server-turn-state)
                 (lambda (&rest _)
                   '(:process-live t :thread-id "thread-1" :active t
                                   :start-pending nil :queued 0
                                   :pending-submissions 0 :turn-id "turn-1")))
                ((symbol-function 'codex--app-server-send-request)
                 (lambda (method params _callback)
                   (push (cons method params) requests) 1))
                ((symbol-function 'codex--app-server-insert-message) #'ignore)
                ((symbol-function 'codex--app-server-ensure-trailing-newline)
                 #'ignore))
        ;; A leading slash must NOT be dispatched as a local command.
        (codex-app-server-steer "/compact the plan instead"))
      (let ((params (cdr (car requests))))
        (should (equal (car (car requests)) "turn/steer"))
        (should (equal (alist-get 'expectedTurnId params) "turn-1"))
        (should (equal (alist-get 'text (aref (alist-get 'input params) 0))
                       "/compact the plan instead"))))))

(ert-deftest codex-test-app-server-steer-refuses-deferring-states ()
  "Steering refuses every state in which it would become another operation."
  (with-temp-buffer
    (dolist (state '(nil
                     (:process-live nil :thread-id "t" :active t
                                    :pending-submissions 0 :turn-id "turn-1")
                     (:process-live t :thread-id nil :active nil
                                    :pending-submissions 0 :turn-id nil)
                     (:process-live t :thread-id "t" :active nil
                                    :pending-submissions 0 :turn-id nil)
                     (:process-live t :thread-id "t" :active t
                                    :pending-submissions 1 :turn-id "turn-1")))
      (cl-letf (((symbol-function 'codex-app-server-turn-state)
                 (lambda (&rest _) state))
                ((symbol-function 'codex--app-server-send-request)
                 (lambda (&rest _) (error "must not be reached"))))
        (should-error (codex-app-server-steer "go left") :type 'user-error)))))

(ert-deftest codex-test-app-server-steer-failure-never-queues ()
  "A failed steer reports and leaves the native queue untouched."
  (with-temp-buffer
    (setq-local codex-terminal-backend 'app-server)
    (setq-local codex--app-server-thread-id "thread-1")
    (setq-local codex--app-server-queued-turn-inputs nil)
    (let ((failures nil))
      (let ((codex-app-server-steer-failed-functions
             (list (lambda (buffer text error)
                     (push (list buffer text error) failures)))))
        (cl-letf (((symbol-function 'codex-app-server-turn-state)
                   (lambda (&rest _)
                     '(:process-live t :thread-id "thread-1" :active t
                                     :start-pending nil :queued 0
                                     :pending-submissions 0
                                     :turn-id "turn-1")))
                  ((symbol-function 'codex--app-server-send-request)
                   (lambda (_method _params callback)
                     (funcall callback nil '((message . "turn ended"))) 1))
                  ((symbol-function 'codex--app-server-insert-message) #'ignore)
                  ((symbol-function 'codex--app-server-insert-status) #'ignore)
                  ((symbol-function 'codex--app-server-ensure-trailing-newline)
                   #'ignore))
          (codex-app-server-steer "go left")))
      (should (= (length failures) 1))
      (should (equal (nth 1 (car failures)) "go left"))
      (should (null codex--app-server-queued-turn-inputs)))))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run, in the codex repo: `make test`
Expected: the new symbols are void.

- [ ] **Step 3: Implement the extension points**

In `codex-app-server.el`, add the observer hook next to the other
app-server customization:

```elisp
(defvar codex-app-server-notification-functions nil
  "Abnormal hook run after this package handled an app-server notification.
Each function is called with three arguments: the session BUFFER, the
JSON-RPC METHOD string, and the decoded PARAMS alist.  It runs after
this package's own handling, so turn state and the native queue flush
have already settled when an observer reads them.

The hook is read-only: return values are ignored, and observers must
not submit input from it.  A function that signals is reported and does
not stop the remaining functions.")
```

Run it at the end of `codex--app-server-handle-notification`, inside the
current-thread guard:

```elisp
    (when (codex--app-server-current-thread-notification-p params)
      (pcase method
        ;; ... unchanged ...
        (_ nil))
      (codex--app-server-run-notification-functions method params))))

(defun codex--app-server-run-notification-functions (method params)
  "Run `codex-app-server-notification-functions' for METHOD and PARAMS."
  (let ((buffer (current-buffer)))
    (run-hook-wrapped
     'codex-app-server-notification-functions
     (lambda (fn)
       (condition-case err
           (funcall fn buffer method params)
         (error
          (message "codex: notification observer %S signaled: %S" fn err)))
       nil))))
```

Replace the server-request handling.
`codex--app-server-handle-server-request` is unchanged (it still defers
to a zero-delay timer); `codex--app-server-answer-server-request`
becomes:

```elisp
(defcustom codex-app-server-request-handler
  #'codex-app-server-modal-request-handler
  "Function answering app-server server-initiated requests.
Called with five arguments: the session BUFFER, the JSON-RPC request
ID, the METHOD string, the decoded PARAMS alist, and RESPOND.

ID is passed explicitly because it is the only thing that tells two
outstanding requests apart: the server can have several approvals of
the same method in flight, and a handler that keyed on the method would
merge them.

RESPOND takes (RESULT &optional ERROR).  With ERROR nil it sends RESULT
as the request's response; ERROR, a cons (CODE . MESSAGE), sends a
JSON-RPC error instead.  It is one-shot: a second call reports and
sends nothing, because a request can be answered only once.

The handler owns the request and must eventually call RESPOND.  The
default asks in the minibuffer exactly as this package always has.
Outer packages presenting requests elsewhere should build their
responses with `codex-app-server-request-choices' rather than
re-encoding the protocol, and must fall back to
`codex-app-server-modal-request-handler' for requests it does not
cover."
  :type 'function
  :group 'codex)

(defun codex--app-server-answer-server-request (buffer message)
  "Route app-server MESSAGE in BUFFER to `codex-app-server-request-handler'."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let* ((id (alist-get 'id message))
             (method (alist-get 'method message nil nil #'equal))
             (params (alist-get 'params message))
             (respond (codex--app-server-make-responder buffer id)))
        (funcall codex-app-server-request-handler
                 buffer id method params respond)))))

(defun codex--app-server-make-responder (buffer id)
  "Return a one-shot function answering request ID in BUFFER.
See `codex-app-server-request-handler' for the calling convention.

The one-shot flag is set only after the response has actually been
written to the process.  Setting it first would make a send that failed
-- a dead process, a closed pipe -- indistinguishable from a send that
succeeded: the caller's retry would be silently swallowed, and a caller
that treats a normal return as delivery would record the request as
answered when nothing was sent.  A failed send therefore signals and
leaves the request answerable; a dead buffer signals for the same
reason."
  (let ((answered nil))
    (lambda (result &optional error)
      (if answered
          (message "codex: app-server request %s was already answered" id)
        (unless (buffer-live-p buffer)
          (error "Codex session is gone; request %s cannot be answered" id))
        (with-current-buffer buffer
          (if error
              (codex--app-server-send-error id (car error) (cdr error))
            (codex--app-server-send-response id result)))
        (setq answered t)))))

(defun codex-app-server-modal-request-handler (buffer id method params respond)
  "Ask about METHOD and PARAMS in the minibuffer and answer with RESPOND.
BUFFER is the session buffer and ID the JSON-RPC request id, accepted
for the handler contract.  This is this package's own behaviour and the
default value of `codex-app-server-request-handler'."
  (ignore id)
  (with-current-buffer buffer
    (if-let* ((spec (codex--app-server-approval-spec method params)))
        (funcall respond (codex--app-server-read-approval spec))
      (funcall respond nil
               (cons -32601
                     (format "Unsupported app-server request: %s" method))))))
```

Change `codex--app-server-approval-spec` to take METHOD and PARAMS
directly instead of a MESSAGE alist (its body already destructures those
two values; delete the two `alist-get` bindings and take them as
arguments).

Add the public choice table beside the approval helpers:

```elisp
(defun codex-app-server-request-choices (method params)
  "Return the CLI-worded choices for app-server request METHOD and PARAMS.
Each entry is (KEY LABEL HELP RESULT), where KEY is the character the
CLI uses, LABEL and HELP are its wording, and RESULT is the complete
response body to hand to the request's RESPOND function -- so callers
reuse this package's response encoding instead of duplicating protocol
knowledge.

Return nil for requests that need free-form input rather than a choice:
`item/tool/requestUserInput', and an MCP elicitation whose
`requestedSchema' declares properties to fill in.  Callers must fall
back to `codex-app-server-modal-request-handler' for those."
  (pcase method
    ((or "item/commandExecution/requestApproval" "execCommandApproval")
     (codex--app-server-decision-choices
      (codex--app-server-command-approval-choices params method)))
    ((or "item/fileChange/requestApproval" "applyPatchApproval")
     (codex--app-server-decision-choices
      (codex--app-server-file-approval-choices method)))
    ("mcpServer/elicitation/request"
     (unless (codex--app-server-elicitation-schema-p params)
       (mapcar (lambda (choice)
                 (list (nth 0 choice) (nth 1 choice) (nth 2 choice)
                       (codex--app-server-elicitation-response
                        (nth 3 choice))))
               (codex--app-server-elicitation-choices))))
    ("item/permissions/requestApproval"
     (mapcar (lambda (entry)
               (list (nth 0 entry) (nth 1 entry) (nth 1 entry)
                     (codex--app-server-permission-response params entry)))
             codex--app-server-permission-choices))
    (_ nil)))

(defun codex--app-server-decision-choices (choices)
  "Wrap CHOICES' decision values in the `decision' response body."
  (mapcar (lambda (choice)
            (list (nth 0 choice) (nth 1 choice) (nth 2 choice)
                  `((decision . ,(nth 3 choice)))))
          choices))

(defun codex--app-server-elicitation-schema-p (params)
  "Return non-nil when PARAMS' elicitation declares fields to fill in.
This package sends no content with an elicitation reply, so a schema
with properties needs form input it cannot provide."
  (let ((schema (alist-get 'requestedSchema params)))
    (and schema (alist-get 'properties schema) t)))
```

Split the permission response body out of the modal prompt so both
paths encode it the same way:

```elisp
(defun codex--app-server-permission-response (params entry)
  "Return the permission-grant reply body for choice ENTRY and PARAMS.
ENTRY is one entry of `codex--app-server-permission-choices'.  Granting
echoes back exactly the permissions that were asked for; denying returns
an empty profile."
  (let ((scope (nth 2 entry))
        (strict (nth 3 entry)))
    (append
     `((permissions . ,(if scope (alist-get 'permissions params) '())))
     (when scope `((scope . ,(symbol-name scope))))
     (when strict '((strictAutoReview . t))))))
```

and rewrite the tail of `codex--app-server-grant-permissions` to call it:

```elisp
  (let* ((chosen (read-multiple-choice
                  (codex--app-server-permission-prompt params)
                  (mapcar (lambda (c) (list (nth 0 c) (nth 1 c)))
                          codex--app-server-permission-choices)))
         (entry (assq (car chosen) codex--app-server-permission-choices)))
    (codex--app-server-permission-response params entry))
```

Add the public turn-state probe near the other turn functions:

```elisp
(defun codex-app-server-turn-state (&optional buffer)
  "Return BUFFER's app-server turn state, or nil for other backends.
BUFFER defaults to the current buffer.  The result is a plist:

  `:process-live'        non-nil while the app-server process is alive.
  `:thread-id'           the thread id, or nil before the thread starts.
  `:active'              non-nil while a turn is running.
  `:start-pending'       non-nil while a `turn/start' has been sent and
                         not yet answered.
  `:queued'              how many Tab-queued inputs are waiting.  One of
                         these is flushed inside `turn/completed', before
                         any notification observer runs.
  `:pending-submissions' how many submissions are held for another
                         reason: reasoning steps in flight,
                         reasoning-waiting submissions, and submissions
                         captured before the thread started.
  `:turn-id'             the running turn's id, or nil.

A submission starts a fresh turn only when the process is live, a
thread exists, both flags are nil, and both counts are zero.  The
process and thread keys matter as much as the rest: without them an
unstarted or dead session is indistinguishable from an idle one, and
callers would read it as ready."
  (with-current-buffer (or buffer (current-buffer))
    (when (eq codex-terminal-backend 'app-server)
      (list :process-live (and (process-live-p codex--app-server-process) t)
            :thread-id codex--app-server-thread-id
            :active codex--app-server-turn-active-p
            :start-pending codex--app-server-turn-start-pending-p
            :queued (length codex--app-server-queued-turn-inputs)
            :pending-submissions
            (+ (length codex--app-server-pending-reasoning-steps)
               (length codex--app-server-reasoning-waiting-submissions)
               (length codex--app-server-startup-submissions))
            :turn-id codex--app-server-current-turn-id))))
```

If the composer work already added `codex-app-server-ready-for-turn-p`,
leave it exactly as it is.

Add the steering entry point beside the other send paths:

```elisp
(defvar codex-app-server-steer-failed-functions nil
  "Abnormal hook run when a `codex-app-server-steer' request fails.
Each function is called with three arguments: the session BUFFER, the
steering TEXT, and the failure -- a JSON-RPC error object or a Lisp
error.  The text is deliberately not queued and not retried: sending it
as a follow-up turn would be a different operation than the steer that
was asked for, and doing that silently is what this entry point exists
to avoid.")

(defun codex-app-server-steer (text &optional buffer)
  "Send TEXT as literal steering input to BUFFER's running turn.
BUFFER defaults to the current buffer.

Signal a `user-error' unless BUFFER is an app-server session whose
process is live, whose thread has started, that has a running turn, and
that is holding no submissions.  In every other state the ordinary
submission path would queue the text, hold it behind pending reasoning,
or start a new turn -- all different operations, and all silent.

TEXT is sent verbatim: it is never parsed as a slash command or a shell
command, and it never consumes the composer's pending images or
mentions.  On failure the text is not queued and not retried;
`codex-app-server-steer-failed-functions' runs instead, so the caller
can report the failure and decide what to do."
  (let ((buffer (or buffer (current-buffer))))
    (with-current-buffer buffer
      (let ((state (codex-app-server-turn-state)))
        (unless state
          (user-error "Steering needs a Codex app-server session"))
        (unless (plist-get state :process-live)
          (user-error "The Codex app server is not running"))
        (unless (plist-get state :thread-id)
          (user-error "This Codex thread has not started yet"))
        (unless (and (plist-get state :active) (plist-get state :turn-id))
          (user-error "No Codex turn is running to steer"))
        (unless (zerop (plist-get state :pending-submissions))
          (user-error
           "Codex is holding submissions; steering would be deferred"))
        (codex--app-server-insert-message
         codex--app-server-user-prefix text)
        (codex--app-server-ensure-trailing-newline)
        (condition-case err
            (codex--app-server-send-request
             "turn/steer"
             `((threadId . ,(plist-get state :thread-id))
               (input . ,(codex--app-server-user-input-vector
                          (list :text text)))
               (expectedTurnId . ,(plist-get state :turn-id)))
             (lambda (_result error)
               (when error
                 (codex--app-server-insert-status
                  (format "Codex steering failed: %S" error))
                 (codex--app-server-run-steer-failed-functions
                  buffer text error))))
          (error
           (codex--app-server-run-steer-failed-functions buffer text err)
           (signal (car err) (cdr err))))))))

(defun codex--app-server-run-steer-failed-functions (buffer text error)
  "Run `codex-app-server-steer-failed-functions' for BUFFER, TEXT, ERROR."
  (run-hook-wrapped
   'codex-app-server-steer-failed-functions
   (lambda (fn)
     (condition-case err
         (funcall fn buffer text error)
       (error (message "codex: steer-failure observer %S signaled: %S"
                       fn err)))
     nil)))
```

`codex--app-server-user-input-vector` is given an already-captured
submission plist, not a string, so it does not take the composer's
pending attachments — which is what keeps a steer from stealing an
image the user attached for their next turn.

`codex-app-server-steer` deliberately does not run
`codex--run-command-submitted-hook`: steering does not start a turn,
and reporting it as a submission would tell observers a turn began.

Document all six additions in the codex repo's `README.org` public API
section, in that manual's style, and regenerate its export if the repo
keeps one.

- [ ] **Step 4: Run the tests to verify they pass**

Run, in the codex repo: `make test` and `make compile` — both clean.
Then confirm from the agent repo that the symbols are visible to a batch
Emacs:

```bash
emacs --batch -L ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/codex \
  -l codex-app-server --eval '(prin1 (list (boundp (quote codex-app-server-notification-functions)) (boundp (quote codex-app-server-request-handler)) (fboundp (quote codex-app-server-request-choices)) (fboundp (quote codex-app-server-turn-state)) (fboundp (quote codex-app-server-steer)) (boundp (quote codex-app-server-steer-failed-functions))))'
```
Expected: `(t t t t t t)`.

- [ ] **Step 5: Commit (in the codex repo)**

Stage `codex-app-server.el`, `codex-test.el`, and `README.org`; commit
with the message
`codex: expose app-server notification, request, turn-state, and steer APIs`.

---

### Task 13: Codex backend integration

**Files:**
- Modify: `agent-codex.el` (backend registration ~line 138; forward
  declarations ~line 107; `agent-codex-before-exit-ready-to-close-p`
  ~line 196; `agent-codex--waiting-p` ~line 478;
  `agent-codex--handle-notification` ~line 511; new
  `;;;;; Turn state and capabilities` and `;;;;; App-server integration`
  sections; minor mode ~line 899)
- Modify: `docs/superpowers/specs/2026-07-30-attention-and-queue-design.md`
  (§6, see Step 3)
- Test: `test/agent-codex-test.el`

**Interfaces:**
- Consumes: Task 12's codex.el API, Task 2's slots, Task 5's
  `agent-attention-file` / `agent-attention-resolve`.
- Produces: `agent-codex--turn-state`,
  `agent-codex--turn-state-idle-p`, `agent-codex--ready-to-submit-p`,
  `agent-codex--steer-available-p`, `agent-codex--steer`,
  `agent-codex--interrupt`, `agent-codex--app-server-notification`,
  `agent-codex--app-server-request-handler`,
  `agent-codex--steer-failed`.

- [ ] **Step 1: Write the failing tests**

Add to `test/agent-codex-test.el`:

```elisp
(defconst agent-codex-test--idle-state
  '(:process-live t :thread-id "thread-1" :active nil :start-pending nil
                  :queued 0 :pending-submissions 0 :turn-id nil)
  "A turn state in which a submission would start a fresh turn.")

(ert-deftest agent-codex-test-turn-state/upgrades-waiting-p ()
  "With the turn-state probe, idle means neither active nor pending."
  (with-temp-buffer
    (cl-letf (((symbol-function 'agent-codex--turn-state)
               (lambda (_b) agent-codex-test--idle-state))
              ((symbol-function 'agent-codex--app-server-live-p)
               (lambda () t)))
      (should (agent-codex--waiting-p (current-buffer))))
    (cl-letf (((symbol-function 'agent-codex--turn-state)
               (lambda (_b) (plist-put (copy-sequence
                                        agent-codex-test--idle-state)
                                       :start-pending t)))
              ((symbol-function 'agent-codex--app-server-live-p)
               (lambda () t)))
      (should-not (agent-codex--waiting-p (current-buffer))))))

(ert-deftest agent-codex-test-ready/every-deferring-state-is-busy ()
  "Dead processes, unstarted threads, queued input, and holds are busy."
  (with-temp-buffer
    (dolist (override '((:process-live nil)
                        (:thread-id nil)
                        (:active t)
                        (:start-pending t)
                        (:queued 1)
                        (:pending-submissions 2)))
      (let ((state (append override agent-codex-test--idle-state)))
        (cl-letf (((symbol-function 'agent-codex--turn-state)
                   (lambda (_b) state)))
          (should (eq (agent-codex--ready-to-submit-p (current-buffer))
                      'busy)))))
    (cl-letf (((symbol-function 'agent-codex--turn-state)
               (lambda (_b) agent-codex-test--idle-state)))
      (should (eq (agent-codex--ready-to-submit-p (current-buffer))
                  'ready)))))

(ert-deftest agent-codex-test-before-exit/waits-for-queued-and-pending ()
  "The before-exit check refuses while codex.el is still holding input."
  (with-temp-buffer
    (cl-letf (((symbol-function 'agent-codex--target-buffer)
               (lambda (_b) (current-buffer)))
              ((symbol-function 'codex-prompt-input) (lambda (&rest _) nil)))
      (cl-letf (((symbol-function 'agent-codex--turn-state)
                 (lambda (_b) agent-codex-test--idle-state)))
        (should (agent-codex-before-exit-ready-to-close-p (current-buffer))))
      (dolist (override '((:queued 1) (:start-pending t)
                          (:pending-submissions 1)))
        (let ((state (append override agent-codex-test--idle-state)))
          (cl-letf (((symbol-function 'agent-codex--turn-state)
                     (lambda (_b) state)))
            (should-not (agent-codex-before-exit-ready-to-close-p
                         (current-buffer)))))))))

(ert-deftest agent-codex-test-steer/refuses-terminal-and-idle-sessions ()
  "Steering is refused with a reason for terminal and idle sessions."
  (with-temp-buffer
    (cl-letf (((symbol-function 'agent-codex--turn-state) (lambda (_b) nil)))
      (should (stringp (agent-codex--steer-available-p (current-buffer)))))
    (cl-letf (((symbol-function 'agent-codex--turn-state)
               (lambda (_b) agent-codex-test--idle-state)))
      (should (stringp (agent-codex--steer-available-p (current-buffer)))))
    (cl-letf (((symbol-function 'agent-codex--turn-state)
               (lambda (_b) (append '(:active t :turn-id "t1")
                                    agent-codex-test--idle-state))))
      (should (eq (agent-codex--steer-available-p (current-buffer)) t)))))

(ert-deftest agent-codex-test-steer/uses-the-dedicated-api ()
  "Steering goes through codex.el's steer entry point, not submission."
  (with-temp-buffer
    (let ((steered nil))
      (cl-letf (((symbol-function 'codex-app-server-steer)
                 (lambda (text buffer) (push (cons text buffer) steered)))
                ((symbol-function 'agent-codex-submit-command)
                 (lambda (&rest _) (error "must not submit"))))
        (agent-codex--steer "go left" (current-buffer)))
      (should (equal steered (list (cons "go left" (current-buffer))))))))

(ert-deftest agent-codex-test-steer/failure-becomes-an-attention-item ()
  "An asynchronous steer failure is reported, not silently queued."
  (with-temp-buffer
    (let ((agent-attention--items nil))
      (cl-letf (((symbol-function 'agent-display-name)
                 (lambda (&optional _b) "project"))
                ((symbol-function 'agent--backend-label) (lambda (_b) "Codex")))
        (agent-codex--steer-failed (current-buffer) "go left"
                                   '((message . "turn ended")))
        (let ((item (car (agent-attention-items))))
          (should (eq (agent-attention-item-kind item) 'error))
          (should (string-match-p "go left"
                                  (agent-attention-item-detail item))))))))

(ert-deftest agent-codex-test-notification/turn-events-become-session-events ()
  "turn/started and turn/completed carry their turn ids into core."
  (with-temp-buffer
    (let ((events nil))
      (cl-letf (((symbol-function 'agent-session-event)
                 (lambda (_buffer event &optional payload)
                   (push (list event (plist-get payload :turn-id)) events))))
        (agent-codex--app-server-notification
         (current-buffer) "turn/started" '((turn . ((id . "t1")))))
        (agent-codex--app-server-notification
         (current-buffer) "turn/completed" '((turn . ((id . "t1")))))
        (agent-codex--app-server-notification
         (current-buffer) "thread/status/changed"
         '((status . ((type . "systemError"))))))
      (should (equal (nreverse events)
                     '((activity "t1") (idle-prompt "t1") (error nil)))))))

(ert-deftest agent-codex-test-notification/stop-is-dropped-for-app-server ()
  "With the app-server hooks live, the CLI Stop hook is not translated."
  (with-temp-buffer
    (rename-buffer "*codex:test*" t)
    (let ((events nil))
      (cl-letf (((symbol-function 'agent-session-event)
                 (lambda (_buffer event &optional _payload)
                   (push event events)))
                ((symbol-function 'agent-codex--note-session-id) #'ignore)
                ((symbol-function 'agent-codex--app-server-observed-p)
                 (lambda (_b) t)))
        (agent-codex--handle-notification
         (list :type "Stop" :buffer-name (buffer-name))))
      (should (null events)))))

(ert-deftest agent-codex-test-notification/permission-request-carries-kind ()
  "A terminal PermissionRequest becomes a coarse blocked event."
  (with-temp-buffer
    (rename-buffer "*codex:test2*" t)
    (let ((payloads nil))
      (cl-letf (((symbol-function 'agent-session-event)
                 (lambda (_buffer event &optional payload)
                   (push (cons event payload) payloads)))
                ((symbol-function 'agent-codex--note-session-id) #'ignore)
                ((symbol-function 'agent-codex-notify) #'ignore))
        (agent-codex--handle-notification
         (list :type "PermissionRequest" :buffer-name (buffer-name)
               :json-data "{\"tool_name\":\"shell\"}")))
      (let ((payload (cdr (car payloads))))
        (should (eq (car (car payloads)) 'blocked))
        (should (eq (plist-get payload :kind) 'permission))
        (should (eq (plist-get payload :fidelity) 'coarse))))))

(ert-deftest agent-codex-test-request-handler/same-method-requests-coexist ()
  "Two outstanding approvals of one method keep separate items.
They are told apart by the JSON-RPC id, which is why the handler is
given it."
  (with-temp-buffer
    (let ((agent-attention--items nil)
          (agent-attention-mode t)
          (responses nil))
      (cl-letf (((symbol-function 'agent-display-name)
                 (lambda (&optional _b) "project"))
                ((symbol-function 'agent--backend-label) (lambda (_b) "Codex"))
                ((symbol-function 'agent-codex-notify) #'ignore)
                ((symbol-function 'codex-app-server-request-choices)
                 (lambda (&rest _)
                   '((?y "yes" "apply once" ((decision . "accept")))
                     (?n "no" "decline" ((decision . "decline")))))))
        (agent-codex--app-server-request-handler
         (current-buffer) 41 "item/fileChange/requestApproval" nil
         (lambda (result &optional _error) (push (cons 41 result) responses)))
        (agent-codex--app-server-request-handler
         (current-buffer) 42 "item/fileChange/requestApproval" nil
         (lambda (result &optional _error) (push (cons 42 result) responses)))
        (should (= (length (agent-attention-items)) 2))
        (should (equal (sort (mapcar #'agent-attention-item-request-key
                                     (agent-attention-items))
                             #'<)
                       '(41 42)))
        (let ((item (seq-find (lambda (i)
                                (equal (agent-attention-item-request-key i) 41))
                              (agent-attention-items))))
          (agent-attention-invoke
           item (car (agent-attention-item-actions item)))
          (should (equal responses '((41 . ((decision . "accept")))))))))))

(ert-deftest agent-codex-test-request-handler/failed-send-keeps-the-item ()
  "A response that fails to send leaves the item open and retryable.
Together with codex.el's responder, which marks itself answered only
after the write succeeds, this is what stops a failed send from being
recorded as an answer."
  (with-temp-buffer
    (let ((agent-attention--items nil)
          (agent-attention--invoked (make-hash-table :test #'equal))
          (agent-attention-mode t)
          (attempts 0)
          (sent nil))
      (cl-letf (((symbol-function 'agent-display-name)
                 (lambda (&optional _b) "project"))
                ((symbol-function 'agent--backend-label) (lambda (_b) "Codex"))
                ((symbol-function 'agent-codex-notify) #'ignore)
                ((symbol-function 'message) #'ignore)
                ((symbol-function 'codex-app-server-request-choices)
                 (lambda (&rest _)
                   '((?y "yes" "apply once" ((decision . "accept")))))))
        (agent-codex--app-server-request-handler
         (current-buffer) 46 "item/fileChange/requestApproval" nil
         (lambda (result &optional _error)
           (cl-incf attempts)
           (when (= attempts 1) (error "process is not running"))
           (push result sent)))
        (let* ((item (car (agent-attention-items)))
               (action (car (agent-attention-item-actions item))))
          (agent-attention-invoke item action)
          (should (null sent))
          (should (memq item (agent-attention-items)))
          (should (agent-attention-item-actions item))
          (should-not (gethash (agent-attention-item-id item)
                               agent-attention--invoked))
          ;; The retry goes through and only then is the item resolved.
          (agent-attention-invoke item action)
          (should (equal sent '(((decision . "accept")))))
          (should (null (agent-attention-items))))))))

(ert-deftest agent-codex-test-request-handler/delegates-free-form-requests ()
  "A request with no choice table falls back to the modal handler."
  (with-temp-buffer
    (let ((agent-attention--items nil)
          (agent-attention-mode t)
          (delegated nil))
      (cl-letf (((symbol-function 'codex-app-server-request-choices)
                 (lambda (&rest _) nil))
                ((symbol-function 'codex-app-server-modal-request-handler)
                 (lambda (&rest _) (setq delegated t))))
        (agent-codex--app-server-request-handler
         (current-buffer) 43 "item/tool/requestUserInput" nil #'ignore))
      (should delegated)
      (should (null (agent-attention-items))))))

(ert-deftest agent-codex-test-request-handler/off-mode-delegates ()
  "With the inbox off, every request goes to the modal handler."
  (with-temp-buffer
    (let ((agent-attention-mode nil)
          (delegated nil))
      (cl-letf (((symbol-function 'codex-app-server-modal-request-handler)
                 (lambda (&rest _) (setq delegated t))))
        (agent-codex--app-server-request-handler
         (current-buffer) 44 "item/fileChange/requestApproval" nil #'ignore))
      (should delegated))))

(ert-deftest agent-codex-test-request-handler/supplies-a-modal-fallback ()
  "A routed item carries the backend's own way of asking, for hand-back."
  (with-temp-buffer
    (let ((agent-attention--items nil)
          (agent-attention-mode t)
          (delegated nil))
      (cl-letf (((symbol-function 'agent-display-name)
                 (lambda (&optional _b) "project"))
                ((symbol-function 'agent--backend-label) (lambda (_b) "Codex"))
                ((symbol-function 'agent-codex-notify) #'ignore)
                ((symbol-function 'codex-app-server-request-choices)
                 (lambda (&rest _)
                   '((?y "yes" "apply once" ((decision . "accept"))))))
                ((symbol-function 'codex-app-server-modal-request-handler)
                 (lambda (&rest _) (setq delegated t))))
        (agent-codex--app-server-request-handler
         (current-buffer) 45 "item/fileChange/requestApproval" nil #'ignore)
        (funcall (agent-attention-item-fallback
                  (car (agent-attention-items))))
        (should delegated)))))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test` — the new agent-codex functions are void.

- [ ] **Step 3: Implement the integration**

Add forward declarations next to the existing ones in `agent-codex.el`:

```elisp
(defvar codex--app-server-turn-start-pending-p)
(defvar codex-app-server-notification-functions)
(defvar codex-app-server-request-handler)
(defvar codex-app-server-steer-failed-functions)
(defvar agent-attention-mode)
(declare-function codex-app-server-turn-state "codex-app-server"
                  (&optional buffer))
(declare-function codex-app-server-request-choices "codex-app-server"
                  (method params))
(declare-function codex-app-server-modal-request-handler "codex-app-server"
                  (buffer id method params respond))
(declare-function codex-app-server-steer "codex-app-server"
                  (text &optional buffer))
(declare-function codex-send-escape "codex" ())
(declare-function agent-attention-file "agent-attention" (buffer &rest keys))
(declare-function agent-attention-resolve "agent-attention"
                  (item &optional reason))
```

Add to the backend registration:

```elisp
  :interrupt #'agent-codex--interrupt
  :steer #'agent-codex--steer
  :steer-p #'agent-codex--steer-available-p
  :ready-to-submit-p #'agent-codex--ready-to-submit-p
```

If the composer work already registered `:ready-to-submit-p` for Codex,
**replace** its function with `agent-codex--ready-to-submit-p`: the
composer's version is built on `codex-app-server-ready-for-turn-p`,
which reads app-server buffer-locals and therefore answers `busy` for
every terminal Codex buffer.  That would permanently block the queue on
terminal sessions.  `agent-codex--ready-to-submit-p` answers correctly
for both transports, and the composer's own safety does not depend on
the probe refusing terminal buffers — it refuses them at
`:dispatchable-p`/`:submit-literal`.

Add a new `;;;;; Turn state and capabilities` section:

```elisp
(defun agent-codex--turn-state (&optional buffer)
  "Return codex.el's app-server turn state for BUFFER, or nil.
Nil means either that codex.el is too old to report it or that BUFFER
is not an app-server session; callers fall back to the narrower signals
they had before, and the reduced visibility is documented rather than
guessed around."
  (when (fboundp 'codex-app-server-turn-state)
    (codex-app-server-turn-state (or buffer (current-buffer)))))

(defun agent-codex--turn-state-idle-p (state)
  "Return non-nil when STATE means a submission would start a fresh turn.
Every condition matters: a dead process or an unstarted thread accepts
nothing, an active or pending turn would make the text steer or queue,
and codex.el's own queued and held submissions go first."
  (and (plist-get state :process-live)
       (plist-get state :thread-id)
       (not (plist-get state :active))
       (not (plist-get state :start-pending))
       (zerop (plist-get state :queued))
       (zerop (plist-get state :pending-submissions))))

(defun agent-codex--ready-to-submit-p (&optional buffer)
  "Return `ready', `busy', or `unknown' for Codex session BUFFER.
App-server sessions answer from codex.el's turn state, which sees the
process, the thread, the native Tab-queue, and held submissions that
the older signals could not.  Terminal sessions have no protocol
signal, so they fall back to the scraped busy indicator and the session
state machine, and a session whose state was never observed stays
`unknown'."
  (let* ((buf (or buffer (current-buffer)))
         (state (agent-codex--turn-state buf)))
    (cond
     (state (if (agent-codex--turn-state-idle-p state) 'ready 'busy))
     ((agent-codex--busy-p buf) 'busy)
     ((eq (buffer-local-value 'agent--session-state buf) 'awaiting-input)
      'ready)
     (t 'unknown))))

(defun agent-codex--interrupt (buffer)
  "Interrupt the turn running in Codex session BUFFER.
Dispatches `codex-send-escape', which on app-server sessions is the
authoritative `turn/interrupt' request and on terminal sessions is the
TUI's own escape key."
  (with-current-buffer buffer
    (codex-send-escape)))

(defun agent-codex--steer-available-p (&optional buffer)
  "Return t when Codex session BUFFER can be steered right now.
Otherwise return a string explaining why not.  Only app-server sessions
with a live process, a started thread, a running turn, and nothing held
can steer: in any other state codex.el would queue the text, hold it,
or start a new turn.  Terminal Codex is refused because mid-turn Enter
injection is unverified at the protocol level, and a steer that
silently became a queued follow-up would be a different operation than
the one asked for."
  (let ((state (agent-codex--turn-state (or buffer (current-buffer)))))
    (cond
     ((null state)
      "steering needs an app-server session; terminal Codex mid-turn \
injection is unverified")
     ((not (plist-get state :process-live)) "the app server is not running")
     ((not (plist-get state :thread-id)) "the thread has not started")
     ((not (and (plist-get state :active) (plist-get state :turn-id)))
      "no turn is running")
     ((not (zerop (plist-get state :pending-submissions)))
      "Codex is holding submissions, so steering would be deferred")
     (t t))))

(defun agent-codex--steer (text buffer)
  "Steer BUFFER's running turn with TEXT.
Goes through `codex-app-server-steer', codex.el's dedicated steering
entry point: it sends TEXT verbatim as `turn/steer' with the running
turn's `expectedTurnId', never parses it as a slash or shell command,
and never converts a failure into a queued follow-up.  The ordinary
submission path does all three of those things, which is why it is not
used here."
  (codex-app-server-steer text buffer))

(defun agent-codex--steer-failed (buffer text error)
  "Report that steering BUFFER with TEXT failed with ERROR.
Member of `codex-app-server-steer-failed-functions'.  The text was not
delivered and was not queued; the inbox says so and keeps the text, so
the user can decide whether to steer again, queue it, or drop it."
  (agent-attention-file
   buffer :kind 'error
   :title "steering was not delivered"
   :detail (format "%S was not sent (%s); it was not queued either"
                   text
                   (or (alist-get 'message error)
                       (format "%S" error)))
   :fidelity 'rich))
```

Replace `agent-codex-before-exit-ready-to-close-p`:

```elisp
(defun agent-codex-before-exit-ready-to-close-p (&optional buffer)
  "Return non-nil when BUFFER holds no pending Codex input of any kind.
Besides an unsent composer prompt, this refuses while codex.el is still
holding input of its own: a pending `turn/start', Tab-queued follow-ups,
or submissions held behind reasoning.  Without those checks the
before-exit chain could read a turn that has not started yet as a turn
that finished, and close the session on top of input the user queued."
  (when-let* ((codex-buffer (agent-codex--target-buffer buffer)))
    (and (not (codex-prompt-input codex-buffer))
         (if-let* ((state (agent-codex--turn-state codex-buffer)))
             (and (not (plist-get state :start-pending))
                  (zerop (plist-get state :queued))
                  (zerop (plist-get state :pending-submissions)))
           t))))
```

Replace `agent-codex--waiting-p`:

```elisp
(defun agent-codex--waiting-p (&optional buffer)
  "Return non-nil when Codex session BUFFER is blocked on user input.
App-server sessions learn turn boundaries from the JSON-RPC stream, so
an inactive turn with no pending start means Codex has finished and
will not proceed until the user submits something.  Being able to queue
text mid-turn is not waiting, and does not count here.

With codex.el's turn-state probe available this also sees a pending
`turn/start'; with an older codex.el only the active-turn flag is
visible, and that narrower visibility is a documented limitation.

Terminal sessions have no protocol signal and return nil, leaving the
decision to `agent--session-state' and `agent-codex--busy-p'."
  (let ((buf (or buffer (current-buffer))))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (and (agent-codex--app-server-live-p)
             (if-let* ((state (agent-codex--turn-state buf)))
                 (and (not (plist-get state :active))
                      (not (plist-get state :start-pending)))
               (not codex--app-server-turn-active-p)))))))
```

Add the app-server observer and request handler in a new
`;;;;; App-server integration` section:

```elisp
(defun agent-codex--app-server-observed-p (buffer)
  "Return non-nil when BUFFER's turns are observed through the app server.
When they are, `turn/completed' is the canonical completion and the
CLI `Stop' hook for the same turn must not be translated a second
time."
  (and (boundp 'codex-app-server-notification-functions)
       (memq #'agent-codex--app-server-notification
             codex-app-server-notification-functions)
       (agent-codex--turn-state buffer)
       t))

(defun agent-codex--app-server-notification (buffer method params)
  "Translate app-server METHOD and PARAMS for BUFFER into session events.
Member of `codex-app-server-notification-functions', so it runs after
codex.el settled its turn state and flushed its native queue.
`turn/completed' is delivered as the canonical completion for the turn,
carrying its id, which moves the ready alert to this authoritative,
earlier channel."
  (pcase method
    ("turn/started"
     (agent-session-event buffer 'activity
                          (list :turn-id (agent-codex--turn-id params)
                                :source 'codex-app-server)))
    ("turn/completed"
     (agent-session-event buffer 'idle-prompt
                          (list :turn-id (agent-codex--turn-id params)
                                :source 'codex-app-server)))
    ("thread/status/changed"
     (when (equal (alist-get 'type (alist-get 'status params)) "systemError")
       (agent-session-event buffer 'error
                            (list :error "systemError"
                                  :fidelity 'rich
                                  :source 'codex-app-server))))))

(defun agent-codex--turn-id (params)
  "Return the turn id reported in app-server PARAMS, or nil."
  (or (alist-get 'id (alist-get 'turn params))
      (alist-get 'turnId params)))

(defun agent-codex--app-server-request-handler (buffer id method params respond)
  "Route an app-server request to the attention inbox when it is live.
BUFFER, ID, METHOD, PARAMS, and RESPOND are codex.el's request-handler
arguments.  Requests whose choice table codex.el does not expose --
free-form user input and schema-bearing elicitations -- and every
request at all while `agent-attention-mode' is off go to codex.el's own
modal handler unchanged.

The item is keyed by ID, so two outstanding approvals of the same
method stay separate records with separate responses.  It also carries
a fallback that runs codex.el's modal handler, so a request already
routed here is handed back rather than stranded if the inbox is
switched off.

Agent never decides an approval: the item's actions send back exactly
the response bodies codex.el encoded, and RESPOND is codex.el's own
one-shot responder."
  (let ((choices (and (bound-and-true-p agent-attention-mode)
                      (codex-app-server-request-choices method params))))
    (if (null choices)
        (codex-app-server-modal-request-handler buffer id method params
                                                respond)
      (let ((item nil))
        (setq item
              (agent-attention-file
               buffer
               :kind (agent-codex--request-kind method)
               :title (agent-codex--request-title method)
               :detail (agent-codex--request-detail method params)
               :request-key id
               :fidelity 'rich
               :fallback (lambda ()
                           (codex-app-server-modal-request-handler
                            buffer id method params respond))
               :actions
               (mapcar
                (lambda (choice)
                  (cons (char-to-string (nth 0 choice))
                        (cons (nth 1 choice)
                              (lambda ()
                                (funcall respond (nth 3 choice))
                                (agent-attention-resolve item "answered")))))
                choices)))
        (agent-codex-notify
         (format "%s needs approval"
                 (agent-backend-label (agent-backend 'codex)))
         (format "%s: %s" (agent--buffer-session-name buffer)
                 (agent-codex--request-title method)))
        item))))

(defun agent-codex--request-kind (method)
  "Return the attention kind for app-server request METHOD."
  (if (string-match-p "elicitation" method) 'question 'permission))

(defun agent-codex--request-title (method)
  "Return a short title for app-server request METHOD."
  (pcase method
    ((or "item/commandExecution/requestApproval" "execCommandApproval")
     "run a command")
    ((or "item/fileChange/requestApproval" "applyPatchApproval")
     "apply file changes")
    ("item/permissions/requestApproval" "grant permissions")
    ("mcpServer/elicitation/request" "MCP server request")
    (_ method)))

(defun agent-codex--request-detail (method params)
  "Return the backend-reported detail for request METHOD and PARAMS, or nil.
Only fields the server actually sent are shown."
  (pcase method
    ((or "item/commandExecution/requestApproval" "execCommandApproval")
     (alist-get 'command params))
    ((or "item/fileChange/requestApproval" "applyPatchApproval")
     (alist-get 'reason params))
    ("item/permissions/requestApproval" (alist-get 'reason params))
    ("mcpServer/elicitation/request" (alist-get 'message params))
    (_ nil)))
```

The `let`/`setq` pair around `item` lets each response action resolve
the very item it belongs to.

Update `agent-codex--handle-notification` so an app-server session's CLI
`Stop` hook is not translated, and so `PermissionRequest` carries a
payload:

```elisp
        (pcase hook-type
          ("Stop"
           (unless (agent-codex--app-server-observed-p buf)
             (agent-session-event buf 'idle-prompt
                                  (list :source 'codex-stop-hook))))
          ("PermissionRequest"
           (agent-session-event
            buf 'blocked
            (append (list :kind 'permission :fidelity 'coarse
                          :source 'codex-stop-hook)
                    (agent-codex--permission-fields
                     (plist-get message :json-data))))
           (agent-codex-notify
            (format "%s needs approval"
                    (agent-backend-label (agent-backend 'codex)))
            (format "%s: permission request pending"
                    (agent--buffer-session-name buf))))
          ("Notification"
           (agent-notify
            (agent-backend-label (agent-backend 'codex))
            (format "%s: needs your attention"
                    (agent--buffer-session-name buf)))))
```

with a defensive parser that shows only fields that are present:

```elisp
(defun agent-codex--permission-fields (json-str)
  "Return payload fields parsed from a Codex PermissionRequest JSON-STR.
The hook payload is opaque, so every field is optional and a parse
failure yields no fields rather than invented ones."
  (when-let* ((data (condition-case nil
                        (and (stringp json-str)
                             (json-parse-string json-str :object-type 'alist))
                      (error nil))))
    (let ((tool (alist-get 'tool_name data))
          (detail (or (alist-get 'command data)
                      (alist-get 'reason data))))
      (append (when (stringp tool) (list :tool tool))
              (when (stringp detail) (list :detail detail))))))
```

Wire the observer, the steer-failure hook, and the request handler into
`agent-codex-mode`:

```elisp
(defvar agent-codex--saved-request-handler nil
  "Value of `codex-app-server-request-handler' before enabling the mode.")
```

in `agent-codex--mode-enable`:

```elisp
  (when (boundp 'codex-app-server-notification-functions)
    (add-hook 'codex-app-server-notification-functions
              #'agent-codex--app-server-notification))
  (when (boundp 'codex-app-server-steer-failed-functions)
    (add-hook 'codex-app-server-steer-failed-functions
              #'agent-codex--steer-failed))
  (when (boundp 'codex-app-server-request-handler)
    (setq agent-codex--saved-request-handler codex-app-server-request-handler)
    (setq codex-app-server-request-handler
          #'agent-codex--app-server-request-handler))
```

and in `agent-codex--mode-disable`:

```elisp
  (when (boundp 'codex-app-server-notification-functions)
    (remove-hook 'codex-app-server-notification-functions
                 #'agent-codex--app-server-notification))
  (when (boundp 'codex-app-server-steer-failed-functions)
    (remove-hook 'codex-app-server-steer-failed-functions
                 #'agent-codex--steer-failed))
  (when (and (boundp 'codex-app-server-request-handler)
             agent-codex--saved-request-handler)
    (setq codex-app-server-request-handler
          agent-codex--saved-request-handler)
    (setq agent-codex--saved-request-handler nil))
```

Restoring the **saved** value rather than the modal default mirrors
`agent-codex--saved-notification-function`.

Amend the spec (`docs/superpowers/specs/2026-07-30-attention-and-queue-design.md`)
in this same commit:

- §6's `codex-app-server-turn-state` description gains `:process-live`,
  `:thread-id`, and `:pending-submissions`, with the reason each is
  needed.
- §6's upstream list gains `codex-app-server-steer` and
  `codex-app-server-steer-failed-functions`, and §4's steer bullet
  records that Codex steering goes through that entry point rather than
  the ordinary submit path, because the submit path dispatches `/` and
  `!` locally, defers behind pending reasoning, and re-queues a failed
  steer.
- §6's request-handler bullet records the explicit request id, the
  fallback closure, and that `agent-codex-mode` installs the handler
  while `agent-attention-mode` gates whether it routes to the inbox.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test` and `make compile` — both clean.

- [ ] **Step 5: Commit**

Stage `agent-codex.el`, `test/agent-codex-test.el`, and the spec; commit
with the message
`agent: wire Codex turn state, steering, and app-server requests`.

---

### Task 14: Claude backend integration

**Files:**
- Modify: `agent-claude.el` (backend registration ~line 215;
  `agent-claude--handle-notification` ~line 1166; new hook-event
  handlers after it; `agent-claude-setup-config` ~line 1901 and the
  hook-command helpers ~line 2057; minor mode ~line 2493)
- Test: `test/agent-claude-test.el`

**Interfaces:**
- Consumes: Task 1's payload argument, Task 2's `:interrupt` slot.
- Produces: `agent-claude--handle-permission-request`,
  `agent-claude--handle-stop-failure`,
  `agent-claude-ensure-permission-request-hook-config`,
  `agent-claude-ensure-stop-failure-hook-config`,
  `agent-claude--interrupt`.

- [ ] **Step 1: Write the failing tests**

Add to `test/agent-claude-test.el`:

```elisp
(ert-deftest agent-claude-test-notification/carries-kind-and-fidelity ()
  "Permission and elicitation notifications carry coarse payloads."
  (with-temp-buffer
    (rename-buffer "*claude:test*" t)
    (let ((payloads nil))
      (cl-letf (((symbol-function 'agent-session-event)
                 (lambda (_buffer event &optional payload)
                   (push (cons event payload) payloads)))
                ((symbol-function 'agent-claude-notify) #'ignore))
        (agent-claude--handle-notification
         (list :type 'notification :buffer-name (buffer-name)
               :json-data "{\"notification_type\":\"permission_prompt\"}"))
        (agent-claude--handle-notification
         (list :type 'notification :buffer-name (buffer-name)
               :json-data "{\"notification_type\":\"elicitation_dialog\"}")))
      (let ((kinds (mapcar (lambda (entry)
                             (plist-get (cdr entry) :kind))
                           (nreverse payloads))))
        (should (equal kinds '(permission question)))))))

(ert-deftest agent-claude-test-permission-request/is-a-rich-observer ()
  "The PermissionRequest hook reports the tool and returns nil."
  (with-temp-buffer
    (rename-buffer "*claude:test2*" t)
    (let ((payloads nil))
      (cl-letf (((symbol-function 'agent-session-event)
                 (lambda (_buffer event &optional payload)
                   (push (cons event payload) payloads))))
        (should-not
         (agent-claude--handle-permission-request
          (list :type 'permission-request :buffer-name (buffer-name)
                :json-data
                "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls -l\"}}"))))
      (let ((payload (cdr (car payloads))))
        (should (eq (car (car payloads)) 'blocked))
        (should (eq (plist-get payload :kind) 'permission))
        (should (equal (plist-get payload :tool) "Bash"))
        (should (string-match-p "ls -l" (plist-get payload :detail)))
        (should (eq (plist-get payload :fidelity) 'rich))))))

(ert-deftest agent-claude-test-permission-request/survives-bad-json ()
  "Unparseable hook data reports the kind and invents no fields."
  (with-temp-buffer
    (rename-buffer "*claude:test3*" t)
    (let ((payloads nil))
      (cl-letf (((symbol-function 'agent-session-event)
                 (lambda (_buffer _event &optional payload)
                   (push payload payloads))))
        (agent-claude--handle-permission-request
         (list :type 'permission-request :buffer-name (buffer-name)
               :json-data "not json")))
      (should (null (plist-get (car payloads) :tool)))
      (should (null (plist-get (car payloads) :detail))))))

(ert-deftest agent-claude-test-stop-failure/becomes-an-error-event ()
  "The StopFailure hook reports the error code and last message."
  (with-temp-buffer
    (rename-buffer "*claude:test4*" t)
    (let ((payloads nil))
      (cl-letf (((symbol-function 'agent-session-event)
                 (lambda (_buffer event &optional payload)
                   (push (cons event payload) payloads))))
        (should-not
         (agent-claude--handle-stop-failure
          (list :type 'stop-failure :buffer-name (buffer-name)
                :json-data
                "{\"error\":\"rate_limit\",\"last_assistant_message\":\"hi\"}"))))
      (should (eq (car (car payloads)) 'error))
      (should (equal (plist-get (cdr (car payloads)) :error) "rate_limit")))))

(ert-deftest agent-claude-test-setup/adds-both-observer-hooks ()
  "Setup writes fire-and-forget PermissionRequest and StopFailure hooks."
  (let ((file (make-temp-file "agent-claude-settings" nil ".json")))
    (unwind-protect
        (cl-letf (((symbol-function 'agent-claude--require-executable)
                   (lambda (f) (or f "/bin/true"))))
          (agent-claude-ensure-permission-request-hook-config file)
          (agent-claude-ensure-stop-failure-hook-config file)
          (let* ((settings (agent-claude--read-json-object file))
                 (hooks (gethash "hooks" settings)))
            (should (gethash "PermissionRequest" hooks))
            (should (gethash "StopFailure" hooks))
            (let ((command
                   (gethash "command"
                            (aref (gethash "hooks"
                                           (aref (gethash "PermissionRequest"
                                                          hooks)
                                                 0))
                                  0))))
              (should (string-match-p "fire-and-forget" command))
              (should (string-match-p "permission-request" command)))))
      (delete-file file))))

(ert-deftest agent-claude-test-interrupt/sends-escape-in-the-buffer ()
  "The interrupt slot sends escape with the target buffer current."
  (with-temp-buffer
    (let ((seen nil)
          (target (current-buffer)))
      (cl-letf (((symbol-function 'claude-code-send-escape)
                 (lambda () (setq seen (current-buffer)))))
        (agent-claude--interrupt target))
      (should (eq seen target)))))
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test` — the new handlers and setup commands are void.

- [ ] **Step 3: Implement the integration**

Add to the Claude backend registration:

```elisp
  :interrupt #'agent-claude--interrupt
```

and no steer slots at all — Claude Code has no steering operation, and
`agent-steer` says so.

Add a shared JSON parser and the interrupt next to the notification
helpers:

```elisp
(defun agent-claude--parse-hook-json (json-str)
  "Return JSON-STR parsed as an alist, or nil when it cannot be parsed."
  (when (stringp json-str)
    (condition-case nil
        (json-parse-string json-str :object-type 'alist)
      (error nil))))

(defun agent-claude--notification-message (json-str)
  "Return the message reported in notification JSON-STR, or nil."
  (when-let* ((data (agent-claude--parse-hook-json json-str)))
    (let ((message (alist-get 'message data)))
      (and (stringp message) message))))

(defun agent-claude--interrupt (buffer)
  "Interrupt the turn running in Claude session BUFFER.
Sends the CLI's escape key with BUFFER current.  Escape while a
permission dialog is showing answers that dialog instead of stopping
the turn; that is the TUI's behaviour, and Emacs cannot see which
dialog is on screen."
  (with-current-buffer buffer
    (claude-code-send-escape)))
```

Give the notification handler payloads:

```elisp
        (pcase ntype
          ("idle_prompt"
           (agent-session-event buf 'idle-prompt
                                (list :source 'claude-idle-notification)))
          ("permission_prompt"
           (agent-session-event
            buf 'blocked
            (list :kind 'permission
                  :message (agent-claude--notification-message
                            (plist-get message :json-data))
                  :fidelity 'coarse
                  :source 'claude-idle-notification))
           (agent-claude-notify
            (format "%s needs approval" label)
            (format "%s: permission request pending" name)))
          ("elicitation_dialog"
           (agent-session-event
            buf 'blocked
            (list :kind 'question
                  :message (agent-claude--notification-message
                            (plist-get message :json-data))
                  :fidelity 'coarse
                  :source 'claude-idle-notification))
           (agent-claude-notify
            (format "%s needs input" label)
            (format "%s: waiting for your input" name)))
          (_
           (agent-claude-notify
            label
            (format "%s: needs your attention" name))))
```

Name the `Stop` hook's channel too, in `agent-claude--handle-stop`
(agent-claude.el ~line 1242), which currently passes no payload at all:

```elisp
      (agent-session-event buf 'stop (list :source 'claude-stop-hook))
```

Every channel that can report a turn ending must name itself, and no
two channels may share a name: that is the whole basis of
`agent--session-completion-canonical-p`'s rule 3.  Claude's four are
`claude-stop-hook`, `claude-idle-notification`,
`claude-stop-failure-hook`, and `claude-permission-request-hook`; Codex
uses `codex-app-server` and `codex-stop-hook`.  A channel that reports
turn endings and shares a name with another would make one turn look
like two.

Add the two new hook-event handlers after it:

```elisp
(defun agent-claude--handle-permission-request (message)
  "Translate a Claude `PermissionRequest' hook event into a session event.
MESSAGE is a plist with `:type', `:buffer-name', `:json-data', and
`:args'.  This is an observer: it always returns nil, so it never wins
`run-hook-with-args-until-success' and never answers the CLI.  Claude
Code owns the decision; Agent only records that one is pending, which
is also what stops the queue from typing into the dialog."
  (when (eq (plist-get message :type) 'permission-request)
    (when-let* ((buf (get-buffer (plist-get message :buffer-name))))
      (let* ((data (agent-claude--parse-hook-json
                    (plist-get message :json-data)))
             (tool (alist-get 'tool_name data))
             (input (alist-get 'tool_input data)))
        (agent-session-event
         buf 'blocked
         (append (list :kind 'permission :fidelity 'rich
                       :source 'claude-permission-request-hook)
                 (when (stringp tool) (list :tool tool))
                 (when-let* ((detail (agent-claude--tool-input-summary
                                      input)))
                   (list :detail detail)))))))
  nil)

(defun agent-claude--tool-input-summary (input)
  "Return one line describing tool INPUT, or nil.
Shows only fields the CLI actually reported: the command for shell
tools, the path for file tools, the URL for fetches, and otherwise the
raw JSON.  Nothing is inferred from the tool name."
  (when (consp input)
    (let ((text (or (alist-get 'command input)
                    (alist-get 'file_path input)
                    (alist-get 'path input)
                    (alist-get 'url input)
                    (ignore-errors (json-encode input)))))
      (when (stringp text)
        (truncate-string-to-width
         (replace-regexp-in-string "[ \t\n\r]+" " " text)
         120 nil nil "...")))))

(defun agent-claude--handle-stop-failure (message)
  "Translate a Claude `StopFailure' hook event into an `error' event.
MESSAGE is a plist with `:type', `:buffer-name', `:json-data', and
`:args'.  An observer: it always returns nil.  Only the reported error
and last assistant message are carried; nothing else is inferred."
  (when (eq (plist-get message :type) 'stop-failure)
    (when-let* ((buf (get-buffer (plist-get message :buffer-name))))
      (let* ((data (agent-claude--parse-hook-json
                    (plist-get message :json-data)))
             (code (alist-get 'error data))
             (last (alist-get 'last_assistant_message data)))
        (agent-session-event
         buf 'error
         (append (list :fidelity 'rich :source 'claude-stop-failure-hook)
                 (when (stringp code) (list :error code))
                 (when (stringp last) (list :message last)))))))
  nil)
```

Extend setup:

```elisp
(defun agent-claude-setup-config ()
  "Ensure Claude Code settings contain agent statusline and hooks."
  (interactive)
  (agent-claude-ensure-statusline-config)
  (agent-claude-ensure-stop-hook-config)
  (agent-claude-ensure-notification-hook-config)
  (agent-claude-ensure-permission-request-hook-config)
  (agent-claude-ensure-stop-failure-hook-config)
  (message "agent-claude: updated %s" agent-claude-settings-file))

(defun agent-claude-ensure-permission-request-hook-config (&optional file)
  "Ensure FILE has a Claude Code `PermissionRequest' hook.
FILE defaults to `agent-claude-settings-file'.  The entry is an
observer: it runs fire-and-forget, so it can neither block the CLI nor
return a decision."
  (interactive)
  (agent-claude--update-settings
   (or file agent-claude-settings-file)
   #'agent-claude--ensure-permission-request-hook))

(defun agent-claude-ensure-stop-failure-hook-config (&optional file)
  "Ensure FILE has a Claude Code `StopFailure' hook.
FILE defaults to `agent-claude-settings-file'.  The entry is an
observer, run fire-and-forget."
  (interactive)
  (agent-claude--update-settings
   (or file agent-claude-settings-file)
   #'agent-claude--ensure-stop-failure-hook))

(defun agent-claude--ensure-permission-request-hook (settings)
  "Ensure SETTINGS has the agent PermissionRequest hook."
  (agent-claude--ensure-hook
   settings "PermissionRequest"
   (agent-claude--observer-hook-command "permission-request") 5))

(defun agent-claude--ensure-stop-failure-hook (settings)
  "Ensure SETTINGS has the agent StopFailure hook."
  (agent-claude--ensure-hook
   settings "StopFailure"
   (agent-claude--observer-hook-command "stop-failure") 5))

(defun agent-claude--observer-hook-command (hook-type)
  "Return the settings.json command forwarding HOOK-TYPE to Emacs.
Wrapping the claude-code hook wrapper in `fire-and-forget.sh' means the
hook can neither block the CLI nor return output, so these entries are
observers and never a decision channel."
  (let ((fire-and-forget (expand-file-name "fire-and-forget.sh"
                                           agent-claude--hooks-directory)))
    (agent-claude--require-executable fire-and-forget)
    (format "%s %s %s"
            (shell-quote-argument fire-and-forget)
            (shell-quote-argument (agent-claude--hook-wrapper))
            (shell-quote-argument hook-type))))
```

Register the handlers in `agent-claude--mode-enable`:

```elisp
  (add-hook 'claude-code-event-hook #'agent-claude--handle-permission-request)
  (add-hook 'claude-code-event-hook #'agent-claude--handle-stop-failure)
```

and remove them in `agent-claude--mode-disable`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test` and `make compile` — both clean.

- [ ] **Step 5: Commit**

Stage `agent-claude.el` and `test/agent-claude-test.el`; commit with the
message
`agent: report Claude permission and failure detail, and interrupt`.

---

### Task 15: Menu integration

**Files:**
- Modify: `agent.el` (`agent-menu` ~line 2676; forward declarations)
- Test: `test/agent-test.el`

**Interfaces:**
- Consumes: Tasks 3, 6, 7, 8, 9's commands.
- Produces: the `agent-menu` "Attention" group and
  `agent-menu--attention-description`.

- [ ] **Step 1: Write the failing tests**

```elisp
(ert-deftest agent-test-menu/attention-description-counts-pending ()
  "The menu description reports the pending count without any I/O."
  (cl-letf (((symbol-function 'agent-attention-pending-count) (lambda () 3)))
    (should (equal (agent-menu--attention-description) "attention (3)")))
  (let ((count-fn (symbol-function 'agent-attention-pending-count)))
    (unwind-protect
        (progn
          (fmakunbound 'agent-attention-pending-count)
          (should (equal (agent-menu--attention-description) "attention")))
      (fset 'agent-attention-pending-count count-fn))))

(ert-deftest agent-test-menu/keys-are-unique ()
  "No two menu suffix keys collide."
  (let ((keys '("e" "w" "h" "x" "r" "l" "A" "Q" "L" "I" "E"
                "K" "f" "S" "s" "n" "c" "a" "d" "m" "g" "T" "p" "i")))
    (should (= (length keys) (length (delete-dups (copy-sequence keys)))))))
```

The second test is a guard rail: it fails loudly if a later change
introduces a duplicate key in the shared columns.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `make test` — `agent-menu--attention-description` is void.

- [ ] **Step 3: Implement the menu entries**

Add to `agent.el`'s split-module autoload block:

```elisp
(autoload 'agent-attention "agent-attention" nil t)
(autoload 'agent-queue-prompt "agent-queue" nil t)
(autoload 'agent-queue-list "agent-queue" nil t)
```

(keeping whichever of these Tasks 5 and 7 already added), plus the
forward declaration:

```elisp
(declare-function agent-attention-pending-count "agent-attention" ())
```

Add the description helper next to the menu:

```elisp
(defun agent-menu--attention-description ()
  "Return the menu description for the attention inbox.
Reads the in-memory item list, so opening the menu performs no I/O.
Says just \"attention\" when the module is not loaded."
  (if (fboundp 'agent-attention-pending-count)
      (format "attention (%d)" (agent-attention-pending-count))
    "attention"))
```

Extend the Sessions column of `agent-menu`:

```elisp
  [["Sessions"
    ("e" "start or switch" agent-start-or-switch)
    ("w" "jump to waiting" agent-jump-to-waiting)
    ("h" "handoff" agent-handoff)
    ("x" "exit session" agent-exit)
    ("r" "restart" agent-restart)
    ("l" "history" agent-history)
    ""
    "Attention"
    ("A" agent-menu--attention-description agent-attention)
    ("Q" "queue prompt" agent-queue-prompt)
    ("L" "queue list" agent-queue-list)
    ("I" "interrupt turn" agent-interrupt)
    ("E" "steer turn" agent-steer)
    ""
    "Buffer"
    ("K" "setup kill on exit" agent-setup-kill-on-exit)
    ("f" "fix rendering" agent-fix-rendering)
    ("S" "disable scrollback" agent-disable-scrollback-truncation)]
```

Transient accepts a function symbol in the description position and
calls it when the menu is drawn.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test` and `make compile` — both clean.  Open `agent-menu`
interactively once and confirm the new group renders and no key was
stolen from an existing entry.

- [ ] **Step 5: Commit**

Stage `agent.el` and `test/agent-test.el`; commit with the message
`agent: add attention and busy-session entries to the menu`.

---

### Task 16: Manual

**Files:**
- Modify: `README.org` (new "Attention and busy sessions" section after
  the Commands section; command entries in the shared-commands section;
  user-option entries in the shared session behavior section)
- Modify: `agent.texi` (regenerated)

- [ ] **Step 1: Write the manual section**

Add to `README.org` an `* Attention and busy sessions` section covering,
in prose matching the manual's existing style:

- **The three operations and what supports each.**  Queueing
  (`agent-queue-prompt`) adds a prompt submitted as its own turn after
  the current one ends; steering (`agent-steer`) adds instructions to
  the turn already running; interrupting (`agent-interrupt`) stops the
  current turn and does nothing else.  They are never substituted for
  one another.  Claude Code has no steering operation at all — text
  typed mid-turn is queued by its TUI as the next prompt — so
  `agent-steer` refuses on Claude sessions and says so.  Codex steers
  only on app-server sessions with a live process, a started thread, a
  running turn, and nothing held, through codex.el's dedicated
  `codex-app-server-steer`, which sends the text verbatim as
  `turn/steer` with the running turn's id.  Explain why that entry point
  exists rather than the ordinary submit path: the submit path treats a
  leading `/` or `!` as a command, defers text behind pending reasoning,
  starts a new turn when none is running, and re-queues a failed steer
  as a follow-up — four ways for a steer to silently become something
  else.  A steer that fails is reported in the inbox and is *not*
  queued.  Terminal Codex is refused because mid-turn injection is
  unverified at the protocol level.  Interrupting is
  `claude-code-send-escape` on Claude and `codex-send-escape` on Codex,
  which on app-server sessions is `turn/interrupt`.  On Claude, escape
  while a permission dialog is showing answers that dialog rather than
  stopping the turn: that is the CLI's behaviour and Emacs cannot see
  which dialog is on screen.
- **The inbox.**  `agent-attention-mode` records items;
  `agent-attention` opens `*agent-attention*`.  Kinds: permission,
  question, completion, error, queue-failure, info.  How items are
  created (backend reports), merged (one pending permission and one
  pending question per session for reports with no request identity;
  request-keyed items each keep their own record, so two outstanding
  Codex approvals of the same kind stay separate; the highest-fidelity
  producer's text survives a merge, so Claude's coarse notification
  arriving after the rich `PermissionRequest` hook refreshes the item
  without overwriting the tool name), cleared (progress in the session
  clears completions and every permission or question item that carries
  no request key, whatever its fidelity — fidelity decides which text
  survives a merge, never whether an item still applies; selecting a
  window showing the session in a focused frame marks completions seen;
  request-keyed items clear when answered), and invalidated (turn end,
  abnormal turn end, session teardown: the response actions are
  disarmed and the item explains why).  Completion items are only
  created when the session was not being read — a buffer visible in an
  unselected split or an unfocused frame still gets one.  Items whose
  buffer died stay listed with their snapshotted label.  Nothing is
  cleared by elapsed time.  Unknown session state renders as unknown.
- **Answering a request has exactly three outcomes**, and the inbox
  distinguishes them: answered (the response reached the backend and the
  item clears), invalidated (the request can no longer be answered, and
  the action explains that instead of sending), and response-failed (the
  send itself signaled, so the item stays answerable and nothing is
  recorded as answered).  Disabling `agent-attention-mode` while a Codex
  request is open hands that request back to codex.el's own minibuffer
  prompt rather than stranding the session waiting.
- **Where responding is possible, and where it is not.**  Only Codex
  app-server requests get respond actions, built from codex.el's own
  choice tables so the responses are the CLI's own encodings; Agent
  never decides an approval.  Requests needing free-form input
  (`item/tool/requestUserInput`, schema-bearing elicitations) still use
  codex.el's minibuffer prompt.  Claude items never get remote
  approve/deny actions: the only channel would be blind keystrokes into
  a dialog whose option order Emacs cannot see, so their action is
  "jump to the session".
- **Known gap.**  A `blocked` report that names no kind — Claude's
  ordinary state-hook channel — files no inbox item, because filing one
  would mean guessing why the session is waiting.  The session still
  shows as waiting in the switcher, and the queue still refuses to
  submit into it.
- **The queue lifecycle.**  `agent-queue-mode` must be on or queueing
  refuses.  `agent-queue-prompt` adds; `agent-queue-list` shows the
  per-session queue with add (=a=), edit (=e=, `C-c C-c` to save),
  delete (=d=), reorder (=M-<up>=/=M-<down>=), show (=RET=), resume
  (=R=), queue-again (=!=), refresh (=g=), quit (=q=).  Document the
  five item states — queued, dispatched, started, stalled, failed —
  and the rule that binds them: **only a `queued` item is ever
  dispatched, and nothing automatic ever returns an item to `queued`.**
  A submission event is never treated as proof a turn started.
- **What counts as permission to send.**  A finished turn, a dialog
  waiting for an answer, and a turn that died all leave the session in
  the same lifecycle state, so the queue does not ask whether the
  session looks idle — it asks for positive evidence that a turn ended
  well.  That evidence is either the backend's own protocol probe (Codex
  app-server, which can see the process, the thread, the turn, and its
  own queue) or a recorded canonical `stop`/`idle-prompt` from the
  session itself.  A session showing a permission dialog, a session
  whose turn failed, and a session that has reported nothing at all are
  all refused, and a delayed duplicate of a dead turn does not count as
  new evidence.  The dialog check is additionally made by the queue
  itself rather than delegated, because that is the one condition whose
  failure would type the user's queued prompt into an approval prompt.
- **When a completion counts.**  Deciding which completion reports which
  turn is done once, for every consumer, and it is not a matter of
  timing.  A completion is a new turn's end when it carries a turn id
  the last one did not (Codex app-server), when work was observed since
  the last one, or — for the transports with no ids — when it comes from
  a channel that has already described the recorded turn end.  Each
  channel reports each turn at most once: Claude's `Stop` hook fires
  once per turn and its `idle_prompt` notification fires once per turn,
  so a second `Stop` is a second turn while a first `idle_prompt` after
  a `Stop` is the same turn.  That holds however long the delay, which
  is why no threshold is used: a delayed duplicate and a very short turn
  cannot be told apart by elapsed time, and are told apart exactly by
  channel.  Claude's statusline `prompt_id` is not used to stamp
  completions, because the poll reports the id current at poll time
  rather than the id of the turn a given completion describes.  The one
  configuration that defeats this is the same hook wired into
  `settings.json` twice, which `agent-claude-setup-config` will not
  create.
- **The delivery guarantees, stated honestly.**  On Codex app-server:
  exactly-once.  Dispatch happens only into a live process with a
  started thread, an idle turn, an empty native queue and nothing held;
  `turn/started` correlation attributes the turn, and the matching
  `turn/completed` resolves the item.  Attribution can be off only if a
  human submits by hand into the same idle gap; the item is still
  dispatched exactly once.  On Claude and terminal Codex: at-most-once
  dispatch, best-effort exactly-once turn placement.  No correlation ids
  exist, so if one reporting channel were wired up twice it would report
  a single turn twice, which could let the *next* item be dispatched
  while the previous queued turn still runs — in which case the CLI's own
  mid-turn handling applies (Claude queues it as the next prompt).  That
  is the only remaining way to get there, and it takes a duplicated hook
  entry that `agent-claude-setup-config` does not create.
- **Coexistence with Codex's own queue.**  Codex's Tab-queue stays fully
  functional and always drains first: the readiness gate refuses while
  codex.el reports queued input of its own.
- **Failure behaviour.**  A submission that signals leaves the prompt in
  the `failed` state and pauses the queue: whether the text reached the
  backend is unknown, so it is never resent automatically.  A dispatch
  that produces no observable turn for `agent-queue-stall-seconds`
  becomes `stalled` and pauses the queue the same way; a
  backend-reported turn error pauses it too.  `agent-queue-resume`
  clears the pause so never-sent prompts can go out again; it re-arms
  nothing.  Putting an unproven prompt back in line is
  `agent-queue-requeue` (=!=), which asks first and says plainly that
  the text may already have been delivered.  A safety-net timer
  (`agent-queue-poll-interval`) re-reads the same gate so a missed
  backend event delays a drain rather than stranding it.
- **Preservation.**  On any teardown, queued prompts move to a stash
  outside the dying buffer — created before the buffer's queue is
  cleared, so no failure in between can lose them — and are written to
  the session's capture file as ordinary drafts, one at a time.  Each
  append is a transaction: one that fails is rolled back out of the
  shared capture buffer and the buffer re-read from disk, so a later
  successful append cannot flush the failed one to the file as a side
  effect and leave an entry no handle points at.  A write that fails
  partway keeps every draft it already wrote and reports how
  many are held only in memory; an info item names the file on success,
  an error item and a warning describe any shortfall.  Restart is the
  one case where prompts can come back: the queue is detached before the
  kill, and re-attaches only when the resumed session's native id
  matches — which only a non-fork resume proves — and even then only the
  prompts that had never been sent.  A prompt that was in flight when
  the restart happened stays a draft, because it may already have
  reached the old session.  A fork, a mismatched id, or a failed startup
  leaves everything durable in the capture file and visible in the
  inbox, never sent anywhere.  Handoff never migrates a queue, because
  it starts a new native session.  `agent-exit`, `agent-restart`, and
  `agent-handoff` confirm before demoting queued prompts.  A captured
  draft and an armed queue item stay different things: demotion to draft
  is the only automatic conversion, never the reverse.
- **Switcher and menu.**  Sessions with a pending action item are marked
  `!`, sessions with only an unread completion `•`, and sessions holding
  queued prompts `qN` (with a trailing `*` when the queue is paused).
  The `agent-menu` "Attention" group holds the inbox (with its pending
  count), queue prompt, queue list, interrupt, and steer.
- **Setup.**  `agent-claude-setup-config` now also installs
  `PermissionRequest` and `StopFailure` hook entries in `settings.json`,
  both run through the bundled `fire-and-forget.sh` so they can never
  block the CLI or return output: they are observers, never a decision
  channel.  Setup remains explicit; nothing installs at load or
  mode-enable time.

Also add the new commands (`agent-attention`, `agent-queue-prompt`,
`agent-queue-list`, `agent-queue-resume`, `agent-queue-requeue`,
`agent-interrupt`, `agent-steer`,
`agent-claude-ensure-permission-request-hook-config`,
`agent-claude-ensure-stop-failure-hook-config`) to the commands section,
the new modes (`agent-attention-mode`, `agent-queue-mode`) to the
backend-minor-modes section, and the new user options
(`agent-queue-stall-seconds`,
`agent-queue-poll-interval`, `agent-attention-detail-width`,
`agent-session-event-functions`, `agent-session-annotation-functions`,
`agent-before-restart-functions`, `agent-after-restart-functions`) to the
user-options section.

- [ ] **Step 2: Regenerate the texi export**

The repo's `.dir-locals.el` regenerates `agent.texi` on save from
`README.org`.  If you edited the file outside that Emacs, regenerate it
explicitly:

```bash
emacs --batch README.org -f org-texinfo-export-to-texinfo && mv README.texi agent.texi
```

Then diff `agent.texi` and confirm the change is the new section plus
menu updates only.

- [ ] **Step 3: Commit**

Stage `README.org` and `agent.texi`; commit with the message
`agent: document the attention inbox and busy-session operations`.

---

### Task 17: Full checks and live verification

- [ ] **Step 1: Full suites in both repos**

In the agent repo: `make compile && make test` — compile warning-free,
every test passes (362 pre-existing plus the new ones).
In the codex repo: `make compile && make test` — same.

- [ ] **Step 2: Enable the modes in the running Emacs**

```elisp
(progn (agent-attention-mode 1) (agent-queue-mode 1))
```

and run `agent-claude-setup-config` once, then confirm the two new
entries landed in `~/.claude/settings.json` and that a Claude session
started afterwards still works normally.

- [ ] **Step 3: Live verification checklist**

Perform these against real sessions and report each result honestly,
including anything that did not work.  Automated tests cannot prove any
of them: each depends on a real CLI's timing, protocol, or UI.

1. **Codex app-server, queue during a real turn.**  Start a long turn,
   `agent-queue-prompt` a follow-up, confirm from the transcript that
   the running turn was unaffected, that the follow-up was submitted
   exactly once after the turn completed, and that it was inspectable in
   `agent-queue-list` until then.
2. **Claude, queue during a real turn.**  Same, and additionally confirm
   the follow-up did not appear in the CLI's own mid-turn queue before
   the turn ended.
3. **Queue never types into a dialog (Claude).**  Queue a follow-up,
   then trigger a real permission prompt.  Leave it on screen for longer
   than `agent-queue-poll-interval` and confirm from the CLI that
   nothing was typed into the dialog and that the queued prompt is still
   listed.  Answer the dialog and confirm the follow-up goes out after
   that turn ends.  Repeat on a terminal Codex session.
4. **Queue editing.**  Add three prompts, edit one, reorder them, delete
   one; confirm the surviving two are submitted in the shown order.
5. **Short turn.**  Queue a prompt whose answer is one line ("reply OK
   and stop"), on Claude, so the turn starts and ends within a couple of
   seconds.  Confirm the item resolves and the next one is dispatched
   rather than sitting in `started`.
6. **Codex app-server steering is same-turn.**  With a turn running,
   `agent-steer` with a distinguishable instruction; confirm from the
   transcript that the *running* turn changed course rather than a new
   turn starting.  This is the empirical check the spec asks for.
7. **Steering with a leading slash.**  Steer with text beginning `/` and
   confirm it reaches the model as text rather than being executed as a
   local Codex command.
8. **Forced steer failure.**  Steer, and interrupt the turn in the same
   moment (or steer with a stale turn by scripting
   `codex-app-server-steer` against a turn id that has just ended).
   Confirm the failure appears in the inbox, the text was NOT queued as
   a follow-up, and codex.el's native queue is still empty.
9. **Terminal Codex steering refusal.**  On an eat/vterm Codex session,
   `agent-steer` refuses with the transport reason.  If you separately
   verify that `codex-inject-mid-turn` really injects same-turn, record
   the evidence; until then the refusal stands.
10. **Claude steering refusal.**  `agent-steer` on a Claude session
    refuses with the "no steering operation" message and sends nothing.
11. **Interrupt.**  On both backends, `agent-interrupt` during a turn
    stops it and submits no replacement text.
12. **Two same-method Codex approvals at once.**  Provoke two file-change
    or two command approvals in flight together (a turn that edits two
    files with approvals on).  Confirm the inbox shows two separate
    items, that answering one leaves the other outstanding, and that
    each answer reaches the request it belongs to.
13. **Request invalidation.**  Trigger an approval, then interrupt the
    turn; confirm the item is marked seen with an explanation and that
    `r` refuses instead of sending a stale response.
14. **Hand-back on mode disable.**  Trigger a Codex approval, then
    disable `agent-attention-mode` while it is outstanding.  Confirm
    codex.el's own minibuffer prompt appears and that answering it
    unblocks the session.
15. **App-server process death.**  With a queued prompt waiting, kill the
    `codex app-server` process.  Confirm nothing is dispatched
    afterwards, the queued prompt is preserved, and any outstanding
    request item stops offering to respond.
16. **Claude permission request.**  Trigger one; confirm the inbox item
    names the tool (from the `PermissionRequest` hook) before the coarse
    `Notification` arrives ~6 s later, that the later notification does
    not overwrite the tool name, that the item offers only "jump to the
    session", and that the item clears once the session moves on.
17. **Claude turn error.**  Induce a `StopFailure` (a rate limit is the
    realistic case; otherwise report this step as unverified rather than
    faking it) and confirm the error item carries the reported code and
    that the queue pauses instead of feeding the failed session.
18. **Unread and seen.**  Leave a session in the background through a
    completed turn; confirm an unread completion item and the `•`
    marker appear.  Repeat with the session visible in an unselected
    split — an item should still appear.  Repeat with the session
    selected and focused — no item.  Then select the session and confirm
    the item flips to seen.
19. **Duplicate completions and a multi-step before-exit chain.**  With
    two before-exit skills configured, run `agent-exit` on a Codex
    app-server session.  Confirm both skills run in order and the
    session closes — the case where a mis-ordered completion contract
    strands the chain after the first skill — and that the queue drained
    once, not twice.
19b. **The same chain on Claude, where the duplicate is real.**  Repeat
    check 19 on a Claude session with three before-exit skills.  This is
    the sequence the channel rule exists for: each skill's `Stop` hook is
    followed seconds later by an `idle_prompt` for the same turn, and
    that duplicate must not advance the chain.  Confirm all three skills
    run, in order, one per turn, and that the session closes after the
    third rather than after the second.  Deliberately include one skill
    that finishes in under a second and one that takes minutes: both
    must advance the chain as soon as their own `Stop` arrives, with no
    added delay.  Confirm from the session log that each skill was
    submitted after the previous completion was recorded, not before.
19c. **A short queued turn on Claude.**  Queue a prompt whose whole
    answer is one line, so the turn starts and ends between two status
    polls and no `activity` is ever reported.  Confirm the item resolves
    and the next one goes out — the case where relying on a turn-start
    event would strand the queue.
20. **Restart with a non-empty queue.**  Queue two prompts, run
    `agent-restart`, confirm both return to the new session's queue,
    that their capture drafts were removed, and that nothing was
    submitted during the restart.
21. **Restart during an in-flight queued turn.**  Queue two prompts, let
    the first be dispatched, and restart while its turn is still
    running.  Confirm the in-flight prompt comes back as a capture draft
    with the explanatory inbox item — not as a queued prompt — and that
    the never-sent one is re-armed.
22. **Buffer kill with a non-empty queue.**  Queue two prompts, kill the
    buffer, confirm the info item names the capture file and that the
    file really contains both prompts.  Then confirm no prompt ever
    reached a different session.
23. **Partial persistence failure.**  Queue two prompts, make the
    capture directory unwritable (`chmod 500`), and kill the buffer.
    Confirm the warning and the error inbox item name how many prompts
    could not be saved, that the stash still holds all of them, and that
    restoring the permissions and re-running preservation is not needed
    for the surviving Emacs session to still show them.
23b. **Persistence failure between two successes.**  With three prompts
    queued, arrange for only the second append to fail (make the file
    read-only for one write, or advise `save-buffer` to signal once).
    Then read the capture file on disk and confirm it holds exactly the
    first and third prompts — no orphan copy of the second, which is
    what a failed append left in the shared buffer would produce once
    the third save flushed it.
23d. **Failure after the bytes reached the disk.**  Repeat 23b with an
    `after-save-hook` that signals for one save, so the write itself
    succeeds and the error arrives afterwards.  Confirm the capture file
    on disk still holds only the first and third prompts, that the live
    capture buffer shows the same, and that the inbox reports the
    second as unwritten.  This is the case a buffer-only rollback
    cannot reach.
23c. **A dialog left open across a queue poll.**  Covered by check 3;
    re-run it here after the queue has already dispatched and resolved
    one item, so the session has a completion history and the gate is
    relying on the awaiting reason rather than on never having seen a
    turn.
24. **Fork resume.**  Queue a prompt, fork the session; confirm the
    prompts stayed in the stash and the capture file, and that the
    forked session's queue is empty.

- [ ] **Step 4: Report**

Write up which checks passed, which failed, and which could not be
performed, without rounding any of them up.  If check 6 shows Codex
app-server steering is *not* same-turn, or check 9's terminal injection
turns out to be verifiable, update the spec and
`agent-codex--steer-available-p` accordingly in a follow-up commit
rather than leaving the manual's claim standing.

- [ ] **Step 5: Commit any fixes**

Commit fixes individually, each with its own single-purpose message.
