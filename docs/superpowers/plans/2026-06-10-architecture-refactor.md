# Agent Package Architecture Refactor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate the structural causes of the package's recurring bug families (stale state, account/session identity confusion, restart/resume breakage, TUI-scraping fragility, duplicated per-backend orchestration) by giving session identity, session state, accounts, and resource lifecycles each a single owner, and by pushing the backend abstraction boundary down to small primitives.

**Architecture:** A canonical `agent-session` identity struct captured once at session start replaces buffer-name parsing and five-way account storage. A struct-based backend registry (`agent-backend`) replaces the plist registry, with orchestration workflows (handoff, restart, exit, skills, audit, debug, Slack) written once in core against ~10 backend primitives. Session readiness becomes an event-driven state machine (`agent-session-event`) fed by backend event translators, replacing push-flags cleared by advice on upstream internals. The user-owned upstream `codex.el` gains a real public API (`codex-start-session`, `codex-command-submitted-hook`, `codex-prompt-input`, `codex-session-identity`) so `cl-letf` monkey-patching and glyph scraping disappear; third-party `claude-code.el` hacks are wrapped in exactly one place. Lifecycles get owners via global minor modes and a single session-teardown path; core slims down by extracting capture/Slack/snippet/CLI-convention modules.

**Tech Stack:** Emacs Lisp (Emacs 30), cl-lib structs, ERT, transient, Elpaca source checkouts.

**Repos:**

| Repo | Path | Notes |
|---|---|---|
| agent | `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/` | primary target (resolve the live profile with `~/My\ Drive/dotfiles/bin/elpaca-package-path agent` if the profile has moved) |
| codex | `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/codex/` | user-owned upstream; Phase 2 adds public API here |
| claude-code | `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/claude-code/` | THIRD-PARTY — never edit; wrap its privates once |
| dotfiles | `~/My Drive/dotfiles/` | small `emacs/config.org` wiring updates in Phases 5, 7, 8; tangle with `emacsclient -e '(init-build-profile (file-name-directory user-init-file))'` and commit there |

**Execution rules:**

1. Phases are strictly ordered (0 → 8); each phase leaves the package working and fully tested. Do not start a phase until the previous phase's final verification step passed.
2. Line numbers throughout were taken from commit `1c5766c` (agent) and drift as tasks land. Locate code by the quoted verbatim snippets and `grep -n` anchors, never by line number alone.
3. One commit per task, message format `<scope>: <description>` (lowercase imperative). Codex-repo tasks commit in the codex repo; dotfiles tasks in the dotfiles repo.
4. Verification commands: `~/My\ Drive/dotfiles/claude/bin/batch-test.sh agent` (load check) and `~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/<file>.el [TEST-NAME]` (always pass `agent` as the package argument for all four agent test files; pass `codex` for codex-repo tests). Baseline at plan time: 187 tests passing (agent 42, claude 74, codex 51, chief 20).
5. Elisp style (hook-enforced in this environment): atomic small functions; helpers AFTER their callers; no blank lines inside a function; docstrings document every argument in caps, first line a single sentence, filled to 80 columns; error messages do not end with a period.
6. The running Emacs session must never receive ERT suites or blocking expressions via emacsclient; use `emacs --batch` paths above. Live smoke checks are listed in the final task only.

**Locked architecture contract (all phases code against these exact names):**

```elisp
;; Phase 1 — identity + registry
(cl-defstruct (agent-session (:constructor agent-session-create) (:copier nil))
  (backend nil) (account nil) (directory nil) (instance nil) (id nil))
(defvar-local agent--session nil)
(defun agent-session (&optional buffer))           ; struct or nil; legacy-name backfill during migration
(defun agent-session-buffer-name (session))        ; derive buffer name from identity
(defun agent--set-session (buffer session))

(cl-defstruct (agent-backend (:constructor agent-backend--create) (:copier nil))
  name label icon program
  buffer-p find-all-buffers find-buffers-for-dir
  start-session session-identity
  send-string send-return submit target-buffer
  waiting-p busy-p background-tasks-p duration-ms display-name-suffix
  account-env-var accounts account-file shared-config-items account-init
  ;; canonical-home is added by Phase 5 (Task 5.3)
  run-prompt skill-roots skill-command-prefix
  sync-theme modeline-status menu-suffixes
  before-exit-ready-to-close-p before-kill-check
  ;; transitional slots, deleted by Phase 6:
  start start-new extract-directory extract-instance-name account
  send-command submit-command discover-skills handoff run-skill
  audit-project debug-backtrace act-on-slack-message setup-kill-on-exit
  exit restart)
(defun agent-register-backend (name &rest slots))  ; keyword API
(defun agent-backend (name))                       ; -> struct
(defun agent--backend-get (backend key))           ; keyword->slot shim, deleted in Phase 8

;; Phase 2 — start primitive + upstream codex API
(defun agent-start-session (session &key initial-prompt resume-id))  ; core dispatcher
;; codex.el: codex-start-session, codex-command-submitted-hook,
;;           codex-prompt-input, codex-session-identity

;; Phase 3 — state machine
(defvar-local agent--session-state 'busy)          ; busy | awaiting-input | closing
(defvar-local agent--session-state-changed-at nil)
(defun agent-session-event (buffer event))         ; stop | idle-prompt | submit | exit-request
(defun agent-send-string (string &optional buffer))
(defun agent-submit (string &optional buffer))
(defun agent-send-return (&optional buffer))

;; Phase 4 — before-exit chain
(defvar-local agent--before-exit nil)              ; (:queue E :state idle|running|closing :started-at F)
(defcustom agent-before-exit-timeout 600 ...)

;; Phase 5 — accounts (agent-account.el)
;; agent-account-current/set/select/resolve/env/home/sync/init, all keyed by backend;
;; agent-account-env is PURE; one dynamic `agent-account--starting' replaces
;; per-backend pending vars; session account lives in the agent-session struct.

;; Phase 6 — unified commands
;; agent-handoff, agent-restart, agent-exit, agent-run-skill, agent-discover-skills,
;; agent-audit-project, agent-debug-backtrace, agent-act-on-slack-message,
;; agent--add-process-exit-hook (buffer fn); run-prompt slot signature
;; (prompt &key directory callback), callback receives (text &key error).

;; Phase 7 — lifecycles + menus
;; global minor modes agent-claude-mode / agent-codex-mode own all hooks/advice/timers;
;; agent--session-teardown + buffer-local agent--teardown-functions; agent-menu
;; backend rows built dynamically from the menu-suffixes slot.

;; Phase 8 — slimming
;; new files agent-capture.el, agent-slack.el, agent-snippet.el, agent-claude-cli.el;
;; codex TOML helpers; chief structured-channel heartbeats; shim removal; docs.
```

---

## Phase 0 — Baseline and dead-code purge

All line numbers below refer to commit `1c5766c` on branch `main` of `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/`. Lines shift as tasks land; always locate code by the quoted text, not the line number. All commits go to this repo (branch `main`) unless a step says otherwise.

Recorded baseline (verified 2026-06-10 at commit `1c5766c`): package loads cleanly; `test/agent-test.el` 42 tests, `test/agent-claude-test.el` 74, `test/agent-codex-test.el` 51, `test/agent-chief-test.el` 20 — all passing, 187 total.

### Task 0.1: Establish verification baseline and add Makefile

**Files:**
- Create: `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/Makefile`

- [ ] **Step 1: Run the load check and record the result.**
  ```bash
  cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent
  ~/My\ Drive/dotfiles/claude/bin/batch-test.sh agent
  ```
  Expected last line: `agent loaded successfully`.
- [ ] **Step 2: Run all four ERT files and record the results.** Always pass `agent` as the package argument so `elpaca/sources/agent` is pushed to the front of `load-path` (the other package names have no `sources/` directory of their own).
  ```bash
  cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent
  ~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-test.el
  ~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-claude-test.el
  ~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-codex-test.el
  ~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-chief-test.el
  ```
  Expected: `Ran 42 tests ... 0 unexpected`, `Ran 74 tests ... 0 unexpected`, `Ran 51 tests ... 0 unexpected`, `Ran 20 tests ... 0 unexpected`. Record the four counts in your executor notes; later tasks state expected counts relative to this baseline.
- [ ] **Step 3: Handle any pre-existing failure (conditional).** If any test fails, stop: for each failing test, add one remediation step — either fix the test/code, or delete the test with a one-line justification recorded in the commit message (`agent: delete broken test <name>; <reason>`). Commit each remediation separately. Do not start Task 0.2 until all four files are green.
- [ ] **Step 4: Create the Makefile.** Write exactly this content to `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/Makefile` (recipe lines must start with a TAB). The `compile` target deletes the `.elc` files afterwards so stale byte-code never shadows the canonical sources; a running Emacs session is required (profile detection uses `emacsclient`, same as the helper scripts).
  ```makefile
  EMACS ?= emacs
  PROFILE := $(shell emacsclient -e 'init-current-profile' 2>/dev/null | tr -d '"')
  ELPACA := $(HOME)/.config/emacs-profiles/$(PROFILE)/elpaca
  LOAD_PATH := --eval '(dolist (dir (file-expand-wildcards "$(ELPACA)/builds/*/")) (add-to-list (quote load-path) dir))' --eval '(push default-directory load-path)'
  SRC := agent.el agent-claude.el agent-codex.el agent-chief.el
  TEST_FILES := test/agent-test.el test/agent-claude-test.el test/agent-codex-test.el test/agent-chief-test.el

  .PHONY: compile test clean

  compile:
  	$(EMACS) --batch $(LOAD_PATH) -f batch-byte-compile $(SRC)
  	rm -f *.elc

  test:
  	$(EMACS) --batch $(LOAD_PATH) --eval '(require (quote ert))' $(foreach f,$(TEST_FILES),-l $(f)) -f ert-run-tests-batch-and-exit

  clean:
  	rm -f *.elc test/*.elc
  ```
- [ ] **Step 5: Run `make compile` and record warnings.**
  ```bash
  cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent && make compile
  ```
  Expected: exit 0, with pre-existing warnings (verified present at baseline; do NOT fix them in this phase, just record them): "Alias for `agent-claude-act-on-slack-message-model'/`-backend' should be declared before its referent" (agent-claude.el:2480/2490, agent-codex.el:154/164), "Unused lexical variable `gptel-include-reasoning'" (agent-claude.el:2531, agent-codex.el:1158), "reference to/assignment to free variable `server-eval-args-left'" (agent-claude.el:2651-2652).
- [ ] **Step 6: Run `make test`.**
  ```bash
  cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent && make test
  ```
  Expected: `Ran 187 tests, 187 results as expected, 0 unexpected`.
- [ ] **Step 7: Commit.**
  ```bash
  cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent && git add Makefile && git commit -m "repo: add Makefile with compile and test targets"
  ```

### Task 0.2: Remove dead defensive code in agent.el

**Files:**
- Modify: `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/agent.el` (lines ~616-617, ~1672-1673)

- [ ] **Step 1: Confirm `agent--start-new-session` is referenced nowhere.**
  ```bash
  cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent && grep -rn "agent--start-new-session" *.el test/*.el
  grep -n "agent--start-new-session" ~/My\ Drive/dotfiles/emacs/config.org
  ```
  Expected: only the `fmakunbound` block itself in agent.el; no hits in config.org.
- [ ] **Step 2: Delete the fmakunbound guard.** In `agent.el`, delete this block (between `agent-start-new-session` and `agent--session-switcher`), leaving one blank line between the surrounding forms:
  ```elisp
  (when (fboundp 'agent--start-new-session)
    (fmakunbound 'agent--start-new-session))
  ```
- [ ] **Step 3: Remove the duplicated autoload cookie.** In `agent.el` (~line 1672), replace:
  ```elisp
  ;;;###autoload
  ;;;###autoload
  (defun agent-post-push-ci (&optional commit)
  ```
  with:
  ```elisp
  ;;;###autoload
  (defun agent-post-push-ci (&optional commit)
  ```
- [ ] **Step 4: Verify.**
  ```bash
  cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent
  ~/My\ Drive/dotfiles/claude/bin/batch-test.sh agent && make test
  ```
  Expected: `agent loaded successfully`; `Ran 187 tests ... 0 unexpected`.
- [ ] **Step 5: Commit.**
  ```bash
  cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent && git add agent.el && git commit -m "agent: remove dead fmakunbound guard and duplicate autoload cookie"
  ```

### Task 0.3: Remove dead buffer/terminal helpers from agent-claude.el

These are leftovers from extracting core into agent.el; the live twins are `agent-protect-buffer` (agent.el:746), `agent-fix-rendering`/`agent--send-sigwinch-after-delay`/`agent--send-sigwinch` (agent.el:867-883), and `agent-disable-scrollback-truncation` (agent.el:886+). The hooks already use the core twins (`add-hook 'kill-buffer-query-functions #'agent-protect-buffer` at agent-claude.el:2594; `agent-disable-scrollback-truncation` at agent-claude.el:2603).

**Files:**
- Modify: `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/agent-claude.el` (lines ~331-346, ~397-415, ~2418-2423)

- [ ] **Step 1: Confirm zero references for every symbol being deleted.**
  ```bash
  cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent
  for s in agent-claude-protect-buffer agent-claude-fix-rendering agent-claude--send-sigwinch-after-delay agent-claude--send-sigwinch agent-claude-disable-scrollback-truncation; do echo "== $s"; grep -rn "$s" *.el test/*.el; grep -n "$s" ~/My\ Drive/dotfiles/emacs/config.org ~/My\ Drive/dotfiles/emacs/extras/*.el; done
  ```
  Expected: each symbol appears only inside its own definition or inside another symbol in this deletion set (the three sigwinch functions reference each other). No hits in config.org or extras. If any external hit appears, stop and report instead of deleting.
- [ ] **Step 2: Delete the empty "Snippet insertion" section.** Replace (header followed by four blank lines):
  ```elisp
  ;;;;; Snippet insertion




  ;;;;; Buffer protection
  ```
  with:
  ```elisp
  ;;;;; Buffer protection
  ```
- [ ] **Step 3: Delete `agent-claude-protect-buffer`.** Remove this entire defun (the `;;;;; Buffer protection` header stays — `agent-claude--confirm-kill-branches` and `agent-claude-setup-kill-on-exit` remain in that section):
  ```elisp
  (defun agent-claude-protect-buffer ()
    "Prompt for confirmation before killing claude-code buffers.
  Returns t if the buffer should be killed, nil otherwise.  Skips
  the prompt when the session process has already exited (e.g. via
  /exit).  Intended for use in `kill-buffer-query-functions'."
    (or (not agent-protect-buffers)
        (not (claude-code--buffer-p (current-buffer)))
        (not (process-live-p (get-buffer-process (current-buffer))))
        (yes-or-no-p "Kill claude-code buffer? ")))
  ```
- [ ] **Step 4: Delete the rendering-fix trio.** Remove all three defuns between the end of `agent-claude-setup-kill-on-exit` and the `;;;;; Smart start` header, leaving one blank line:
  ```elisp
  (defun agent-claude-fix-rendering ()
    "Send SIGWINCH to fix terminal rendering after startup.
  Works around a race condition where Claude Code's TUI queries
  terminal dimensions before the terminal window is fully laid out,
  resulting in a garbled banner."
    (interactive)
    (when-let* ((proc (get-buffer-process (current-buffer))))
      (agent-claude--send-sigwinch-after-delay (current-buffer))))

  (defun agent-claude--send-sigwinch-after-delay (buffer)
    "Send SIGWINCH to the process in BUFFER after a short delay."
    (run-at-time agent-sigwinch-delay nil
                 #'agent-claude--send-sigwinch buffer))

  (defun agent-claude--send-sigwinch (buffer)
    "Send SIGWINCH to the process in BUFFER."
    (when (buffer-live-p buffer)
      (when-let* ((proc (get-buffer-process buffer)))
        (signal-process proc 'SIGWINCH))))
  ```
- [ ] **Step 5: Delete `agent-claude-disable-scrollback-truncation`.** Remove (leaving one blank line between the `claude-code--window-widths` hashtable form and the `;; Fix upstream scroll function.` comment):
  ```elisp
  (defun agent-claude-disable-scrollback-truncation ()
    "Disable eat scrollback truncation in Claude Code buffers.
  The default `eat-term-scrollback-size' of 131072 characters causes the
  buffer to be truncated, losing earlier output."
    (interactive)
    (setq-local eat-term-scrollback-size nil))
  ```
- [ ] **Step 6: Verify.**
  ```bash
  cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent
  ~/My\ Drive/dotfiles/claude/bin/batch-test.sh agent-claude && make test
  ```
  Expected: `agent-claude loaded successfully`; `Ran 187 tests ... 0 unexpected`.
- [ ] **Step 7: Commit.**
  ```bash
  cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent && git add agent-claude.el && git commit -m "agent-claude: remove dead buffer and terminal helpers"
  ```

### Task 0.4: Remove dead session-UI duplicates from agent-claude.el

Live core twins: `agent--display-name-cache` (agent.el:387), `agent--session-keys`/`agent--home-row-keys` (agent.el:370/385), `agent-display-name` (agent.el:539), `agent-jump-to-waiting` (agent.el:822, bound in the session switcher), `agent-toggle-alert`/`agent-alert-indicator` (agent.el:839/846; the modeline calls the core names — `doom-modeline-extras.el:199/265`).

**Files:**
- Modify: `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/agent-claude.el` (lines ~178-190, ~742-757, ~1287-1298, ~1338-1347)
- Modify: `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/test/agent-claude-test.el` (lines ~415-447)
- Modify: `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/test/agent-test.el` (`;;;; Alerts` section, ~line 753)
- Modify: `~/My Drive/dotfiles/emacs/extras/doom-modeline-extras.el` (line 160), `~/My Drive/dotfiles/emacs/extras/doc/doom-modeline-extras.org` (line 183), `~/My Drive/dotfiles/emacs/extras/doc/doom-modeline-extras.texi` (line 253)

- [ ] **Step 1: Confirm reference status.**
  ```bash
  cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent
  for s in agent-claude--display-name-cache agent-claude--session-keys agent-claude--home-row-keys agent-claude-display-name agent-claude-jump-to-waiting agent-claude-toggle-alert agent-claude-alert-indicator; do echo "== $s"; grep -rn "$s" *.el test/*.el; grep -rn "$s" ~/My\ Drive/dotfiles/emacs/config.org ~/My\ Drive/dotfiles/emacs/extras; done
  ```
  Expected hits beyond the definitions themselves, all handled below: `agent-claude-display-name` in test/agent-claude-test.el:446 and a stale `declare-function` in dotfiles doom-modeline-extras.el:160; `agent-claude-alert-indicator` in test/agent-claude-test.el:419/424/429 and in the doom-modeline-extras org/texi docs. Anything else: stop and report.
- [ ] **Step 2: Delete the dead variable and aliases.** In `agent-claude.el`, delete both blocks:
  ```elisp
  (defvar-local agent-claude--display-name-cache nil
    "Cached display name for the modeline.
  Updated by `agent--refresh-display-names'.")
  ```
  ```elisp
  ;; Home-row keys and session key map are now managed by agent.
  (defvar agent-claude--session-keys agent--session-keys
    "Alias for `agent--session-keys' for backward compatibility.")
  (defconst agent-claude--home-row-keys agent--home-row-keys
    "Alias for `agent--home-row-keys'.")
  ```
- [ ] **Step 3: Delete `agent-claude-display-name` and collapse the blank-line run.** After `(transient-setup 'agent--session-switcher)))` there are ten blank lines, then this defun, then two blank lines before `agent-claude--branch-suffix`. Delete the defun and reduce to a single blank line on each side:
  ```elisp
  (defun agent-claude-display-name (&optional buffer)
    "Return the display name for BUFFER's modeline.
  Delegates to `agent-display-name', which appends branch suffixes
  through the Claude backend registration."
    (agent-display-name (or buffer (current-buffer))))
  ```
- [ ] **Step 4: Repoint the display-name test at the core function.** In `test/agent-claude-test.el` (~line 446), replace:
  ```elisp
        (should (equal (agent-claude-display-name (current-buffer))
                       "unique-claude-display-test:branched")))))
  ```
  with:
  ```elisp
        (should (equal (agent-display-name (current-buffer))
                       "unique-claude-display-test:branched")))))
  ```
- [ ] **Step 5: Delete `agent-claude-jump-to-waiting`.**
  ```elisp
  (defun agent-claude-jump-to-waiting ()
    "Switch to the Claude session that most recently started waiting for input."
    (interactive)
    (let (best-buf best-time)
      (dolist (buf (claude-code--find-all-claude-buffers))
        (when (buffer-live-p buf)
          (let ((ts (buffer-local-value 'agent--waiting-for-input buf)))
            (when (and ts (or (null best-time) (time-less-p best-time ts)))
              (setq best-buf buf best-time ts)))))
      (if best-buf
          (switch-to-buffer best-buf)
        (message "No sessions waiting for input"))))
  ```
- [ ] **Step 6: Delete `agent-claude-toggle-alert` and `agent-claude-alert-indicator`.**
  ```elisp
  (defun agent-claude-toggle-alert ()
    "Toggle OS notifications for the current Claude session."
    (interactive)
    (setq agent-alert-on-ready (not agent-alert-on-ready))
    (message "Claude alert notifications %s"
             (if agent-alert-on-ready "enabled" "disabled")))

  (defun agent-claude-alert-indicator ()
    "Return a bell icon reflecting the current alert state."
    (if agent-alert-on-ready "🔔" "🔕"))
  ```
- [ ] **Step 7: Port alert-indicator coverage to core.** In `test/agent-claude-test.el`, delete the `;;;; Alert indicator` section header and all three tests `agent-claude-test-alert-indicator-active`, `agent-claude-test-alert-indicator-inactive`, `agent-claude-test-alert-indicator-uses-shared-state`. In `test/agent-test.el`, add to the existing `;;;; Alerts` section (after `agent-test-alert-sound-error-is-nonfatal`):
  ```elisp
  (ert-deftest agent-test-alert-indicator-active ()
    "Return the bell-on icon when alerts are enabled."
    (let ((agent-alert-on-ready t))
      (should (equal (agent-alert-indicator) "🔔"))))

  (ert-deftest agent-test-alert-indicator-inactive ()
    "Return the bell-off icon when alerts are disabled."
    (let ((agent-alert-on-ready nil))
      (should (equal (agent-alert-indicator) "🔕"))))
  ```
- [ ] **Step 8: Clean up stale dotfiles references.** In `~/My Drive/dotfiles/emacs/extras/doom-modeline-extras.el`, delete line 160 (`agent-claude-buffer-account` on line 161 is still used at line 221 — keep it):
  ```elisp
  (declare-function agent-claude-display-name "agent-claude")
  ```
  In `~/My Drive/dotfiles/emacs/extras/doc/doom-modeline-extras.org` line 183, replace `~agent-claude-alert-indicator~` with `~agent-alert-indicator~`; in `doc/doom-modeline-extras.texi` line 253, replace `@code{agent-claude-alert-indicator}` with `@code{agent-alert-indicator}` (this matches the actual call at doom-modeline-extras.el:265).
- [ ] **Step 9: Verify.**
  ```bash
  cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent
  ~/My\ Drive/dotfiles/claude/bin/batch-test.sh agent-claude
  ~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-test.el
  ~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-claude-test.el
  ~/My\ Drive/dotfiles/claude/bin/batch-test.sh doom-modeline-extras
  ```
  Expected: loads succeed; agent-test.el `Ran 44 tests ... 0 unexpected`; agent-claude-test.el `Ran 71 tests ... 0 unexpected`.
- [ ] **Step 10: Commit (two repos).**
  ```bash
  cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent && git add agent-claude.el test/agent-claude-test.el test/agent-test.el && git commit -m "agent-claude: remove dead session-UI duplicates of core helpers"
  cd ~/My\ Drive/dotfiles && git add emacs/extras/doom-modeline-extras.el emacs/extras/doc/doom-modeline-extras.org emacs/extras/doc/doom-modeline-extras.texi && git commit -m "doom-modeline-extras: drop stale agent-claude references"
  ```

### Task 0.5: Migrate remaining callers off duplicated helpers, then delete them

Three near-duplicates of core code still have internal callers: `agent-claude--scroll-to-bottom`/`--scroll-windows-to` (called once, from `agent-claude--handle-stop`; core twin `agent--scroll-to-bottom` at agent.el:852 — agent-codex.el:742 already uses it), `agent-claude--session-name` (called once, from `agent-claude--handle-notification`; divergent duplicate of `agent--session-name` at agent.el:231 — behavioral equivalence on all five existing test cases was verified at baseline), and `agent-claude--parse-skill-frontmatter` (pure delegation to `agent-parse-skill-frontmatter`, agent.el:1522; three internal callers).

**Files:**
- Modify: `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/agent-claude.el` (~1244, ~1300-1336, ~1830-1836, ~1863/1871/1881)
- Modify: `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/test/agent-claude-test.el` (lines ~66-96)
- Modify: `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/test/agent-test.el` (after `agent-test-session-name-handles-directory-without-trailing-slash`, ~line 135)

- [ ] **Step 1: Confirm external reference status.**
  ```bash
  cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent
  for s in agent-claude--scroll-to-bottom agent-claude--scroll-windows-to agent-claude--session-name agent-claude--parse-skill-frontmatter; do echo "== $s"; grep -rn "$s" *.el test/*.el; grep -n "$s" ~/My\ Drive/dotfiles/emacs/config.org; done
  ```
  Expected: only the definitions plus the internal callers named above plus five `agent-claude--session-name` tests; nothing in config.org.
- [ ] **Step 2: Port the five session-name tests to core.** In `test/agent-test.el`, insert after `agent-test-session-name-handles-directory-without-trailing-slash`:
  ```elisp
  (ert-deftest agent-test-session-name-standard ()
    "Extract the project name from a standard session buffer name."
    (should (equal (agent--session-name "*claude:~/path/to/project/:default*")
                   "project")))

  (ert-deftest agent-test-session-name-named-instance ()
    "Extract the project name regardless of instance name."
    (should (equal (agent--session-name "*claude:~/repos/my-app/:worktree-1*")
                   "my-app")))

  (ert-deftest agent-test-session-name-deep-path ()
    "Extract the project name from a deeply nested path."
    (should (equal (agent--session-name
                    "*claude:~/My Drive/repos/org/subdir/:main*")
                   "subdir")))

  (ert-deftest agent-test-session-name-non-matching ()
    "Return the buffer name unchanged when it does not match the pattern."
    (should (equal (agent--session-name "*scratch*") "*scratch*")))

  (ert-deftest agent-test-session-name-no-trailing-star ()
    "Return the buffer name unchanged when the trailing asterisk is missing."
    (should (equal (agent--session-name "*claude:~/path/to/project/:default")
                   "*claude:~/path/to/project/:default")))
  ```
  Run them; all five must pass against the existing core function (verified at baseline):
  ```bash
  cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent && ~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-test.el
  ```
  Expected: `Ran 49 tests ... 0 unexpected`.
- [ ] **Step 3: Migrate the two internal callers.** In `agent-claude--handle-notification` (~line 1244), replace:
  ```elisp
          (let* ((name (agent-claude--session-name (buffer-name)))
  ```
  with:
  ```elisp
          (let* ((name (agent--session-name (buffer-name)))
  ```
  In `agent-claude--handle-stop` (~line 1308), replace:
  ```elisp
            (agent-claude--scroll-to-bottom buf)))))
  ```
  with:
  ```elisp
            (agent--scroll-to-bottom buf)))))
  ```
- [ ] **Step 4: Delete the three superseded definitions.** Remove `agent-claude--scroll-to-bottom` and `agent-claude--scroll-windows-to`:
  ```elisp
  (defun agent-claude--scroll-to-bottom (buffer)
    "Scroll BUFFER and its windows to the terminal cursor.
  Move point and all windows showing BUFFER to the eat terminal
  cursor, keeping the cursor line at the bottom of each window."
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when (bound-and-true-p eat-terminal)
          (let ((cursor-pos (eat-term-display-cursor eat-terminal)))
            (goto-char cursor-pos)
            (agent-claude--scroll-windows-to cursor-pos))))))

  (defun agent-claude--scroll-windows-to (pos)
    "Set `window-point' to POS and recenter in all windows showing this buffer."
    (dolist (window (get-buffer-window-list nil nil t))
      (set-window-point window pos)
      (with-selected-window window
        (goto-char pos)
        (recenter -1))))
  ```
  and `agent-claude--session-name`:
  ```elisp
  (defun agent-claude--session-name (buffer-name)
    "Extract the project name from BUFFER-NAME.
  Given \"*claude:~/path/to/project/:default*\", return
  \"project\"."
    (if (string-match "/\\([^/]+\\)/:[^*]+\\*\\'" buffer-name)
        (match-string 1 buffer-name)
      buffer-name))
  ```
- [ ] **Step 5: Inline the frontmatter delegation.** In `agent-claude--discover-skills`, replace all three occurrences (use replace-all):
  ```elisp
  (when-let* ((meta (agent-claude--parse-skill-frontmatter file))
  ```
  with:
  ```elisp
  (when-let* ((meta (agent-parse-skill-frontmatter file))
  ```
  Then delete the wrapper:
  ```elisp
  (defun agent-claude--parse-skill-frontmatter (file)
    "Parse YAML frontmatter from skill FILE and return a plist.
  Returns a plist with keys :name, :description, :argument-hint,
  :argument-source, :argument-choices, :argument-default,
  :argument-multiple, :user-invocable, or nil if FILE has no
  frontmatter."
    (agent-parse-skill-frontmatter file))
  ```
- [ ] **Step 6: Delete the five old claude tests.** In `test/agent-claude-test.el`, delete the `;;;; Session name extraction` section header and the five tests `agent-claude-test-session-name-standard`, `-named-instance`, `-deep-path`, `-non-matching`, `-no-trailing-star` (they now live in agent-test.el against the core function).
- [ ] **Step 7: Verify.**
  ```bash
  cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent
  ~/My\ Drive/dotfiles/claude/bin/batch-test.sh agent-claude && make test
  ```
  Expected: load succeeds; `Ran 186 tests, 186 results as expected, 0 unexpected` (49 + 66 + 51 + 20).
- [ ] **Step 8: Commit.**
  ```bash
  cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent && git add agent-claude.el test/agent-claude-test.el test/agent-test.el && git commit -m "agent-claude: migrate callers off duplicated core helpers and delete them"
  ```

## Phase 1 — Session identity struct + registry struct

### Task 1.1: Add the `agent-session` identity struct (TDD)

**Files:**
- Modify: `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/test/agent-test.el` (insert before `(provide 'agent-test)`)
- Modify: `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/agent.el` (new section between the end of `agent--buffer-name-instance-separator` and `;;;; Customization`, ~line 270)

- [ ] **Step 1: Write the failing tests.** In `test/agent-test.el`, insert immediately before `(provide 'agent-test)`:
  ```elisp
  ;;;; Session identity

  (ert-deftest agent-test-session-buffer-name-claude-directory-only ()
    "Derive a Claude buffer name from a session without an instance."
    (should (equal (agent-session-buffer-name
                    (agent-session-create :backend 'claude-code
                                          :directory "~/repos/proj/"))
                   "*claude:~/repos/proj/*")))

  (ert-deftest agent-test-session-buffer-name-claude-with-instance ()
    "Derive a Claude buffer name from a session with an instance."
    (should (equal (agent-session-buffer-name
                    (agent-session-create :backend 'claude-code
                                          :directory "~/repos/proj/"
                                          :instance "tests"))
                   "*claude:~/repos/proj/:tests*")))

  (ert-deftest agent-test-session-buffer-name-codex-directory-only ()
    "Derive a Codex buffer name from a session without an instance."
    (should (equal (agent-session-buffer-name
                    (agent-session-create :backend 'codex
                                          :directory "~/repos/proj/"))
                   "*codex:~/repos/proj/*")))

  (ert-deftest agent-test-session-buffer-name-codex-with-instance ()
    "Derive a Codex buffer name from a session with an instance."
    (should (equal (agent-session-buffer-name
                    (agent-session-create :backend 'codex
                                          :directory "~/repos/proj/"
                                          :instance "tests"))
                   "*codex:~/repos/proj/:tests*")))

  (ert-deftest agent-test-session-lazily-backfills-from-buffer-name ()
    "Backfill a session struct by parsing a legacy buffer name."
    (let ((agent-backends nil))
      (with-temp-buffer
        (rename-buffer "*one:~/repo/backfill-proj/:tests*" t)
        (let ((buf (current-buffer)))
          (agent-register-backend
           'one
           (agent-test--backend
            :buffer-p (lambda (candidate) (eq candidate buf))
            :extract-instance-name
            (lambda (name)
              (when (string-match ":\\([^:/*]+\\)\\*\\'" name)
                (match-string 1 name)))
            :account (lambda (_buffer) "work")))
          (let ((session (agent-session buf)))
            (should session)
            (should (eq (agent-session-backend session) 'one))
            (should (equal (agent-session-directory session)
                           "~/repo/backfill-proj/"))
            (should (equal (agent-session-instance session) "tests"))
            (should (equal (agent-session-account session) "work"))
            (should (eq (buffer-local-value 'agent--session buf) session))
            (should (eq (buffer-local-value 'agent--backend buf) 'one)))))))

  (ert-deftest agent-test-session-returns-nil-for-non-session-buffer ()
    "Return nil for buffers that belong to no registered backend."
    (let ((agent-backends nil))
      (with-temp-buffer
        (should-not (agent-session (current-buffer))))))
  ```
- [ ] **Step 2: Run the new tests, expecting failure.**
  ```bash
  cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent && ~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-test.el
  ```
  Expected: the six new tests fail with `void-function agent-session-create` / `agent-session`; the other 49 pass.
- [ ] **Step 3: Implement.** In `agent.el`, insert a new section between the last line of `agent--buffer-name-instance-separator` (`    separator))`) and the `;;;; Customization` header:
  ```elisp
  ;;;; Session identity

  (cl-defstruct (agent-session (:constructor agent-session-create) (:copier nil))
    "Canonical identity of one AI agent session."
    (backend nil :documentation "Backend symbol: `claude-code' or `codex'.")
    (account nil :documentation "Account name string, or nil for default.")
    (directory nil :documentation "Abbreviated absolute project directory,
  with a trailing slash.")
    (instance nil :documentation "Instance name string, or nil for default.")
    (id nil :documentation "CLI session id string, or nil until known."))

  (defvar-local agent--session nil
    "The `agent-session' struct for this buffer, or nil.")

  (defun agent-session (&optional buffer)
    "Return the `agent-session' struct for BUFFER, or nil.
  BUFFER defaults to the current buffer.  When BUFFER has no stored
  struct yet, lazily backfill one with `agent--capture-session' so
  sessions created before the struct existed keep working during
  the migration."
    (let ((buf (or buffer (current-buffer))))
      (when (buffer-live-p buf)
        (or (buffer-local-value 'agent--session buf)
            (agent--capture-session buf)))))

  (defun agent--capture-session (buffer)
    "Construct, store, and return the `agent-session' struct for BUFFER.
  Derive the backend with `agent--detect-backend', the directory
  and instance by parsing BUFFER's name, and the account from the
  backend's account function.  Return nil when BUFFER belongs to no
  registered backend or its name encodes no directory."
    (when-let* ((backend (agent--detect-backend buffer))
                (name (buffer-name buffer))
                (directory (agent--session-directory-from-buffer-name name)))
      (let* ((instance-fn (agent--backend-get backend :extract-instance-name))
             (instance (when instance-fn (funcall instance-fn name)))
             (account-fn (agent--backend-get backend :account))
             (account (when account-fn (funcall account-fn buffer))))
        (agent--set-session
         buffer
         (agent-session-create :backend backend
                               :account account
                               :directory directory
                               :instance instance)))))

  (defun agent-session-buffer-name (session)
    "Return the buffer name encoding SESSION's identity.
  SESSION is an `agent-session' struct.  Follows the CLI packages'
  naming convention: \"*claude:DIR*\" or \"*claude:DIR:INSTANCE*\"
  for the `claude-code' backend, and \"*codex:DIR*\" or
  \"*codex:DIR:INSTANCE*\" for the `codex' backend."
    (let ((prefix (pcase (agent-session-backend session)
                    ('claude-code "claude")
                    (backend (symbol-name backend))))
          (instance (agent-session-instance session)))
      (format "*%s:%s%s*" prefix (agent-session-directory session)
              (if instance (format ":%s" instance) ""))))

  (defun agent--set-session (buffer session)
    "Store SESSION as BUFFER's `agent--session' and return SESSION.
  Also cache SESSION's backend symbol in `agent--backend'."
    (with-current-buffer buffer
      (setq agent--session session)
      (setq agent--backend (agent-session-backend session))
      session))
  ```
  Note: `agent--capture-session` is also the start-hook capture entry point wired in Task 1.4.
- [ ] **Step 4: Run tests expecting success, plus full verification.**
  ```bash
  cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent
  ~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-test.el
  ~/My\ Drive/dotfiles/claude/bin/batch-test.sh agent && make test && make compile
  ```
  Expected: agent-test.el `Ran 55 tests ... 0 unexpected`; `make test` `Ran 192 tests ... 0 unexpected`; compile exits 0 with only the baseline warnings.
- [ ] **Step 5: Commit.**
  ```bash
  cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent && git add agent.el test/agent-test.el && git commit -m "agent: add agent-session identity struct"
  ```

### Task 1.2: Convert the backend registry to the `agent-backend` struct (TDD)

This task replaces the plist registry (agent.el:113-196) with a struct, keeps `agent--backend-get` as a keyword→slot shim, and transitionally lets `agent-register-backend` also accept a single plist argument so the two registration call sites (migrated in Task 1.3) and the ~36 test registrations keep working — every commit stays green. Two keywords in current registrations have no struct slot and are fixed here: `:has-background-tasks-p` is renamed to `:background-tasks-p` (slot name in the locked contract), and `:directory` is dropped (its single consumer, `agent--buffer-directory`, is migrated to the session struct; equivalence holds because buffer names are built from `(abbreviate-file-name (file-truename dir))`, so `file-truename` of the parsed directory equals `file-truename` of the backend's directory function, keeping prompt-capture file slugs stable).

**Files:**
- Modify: `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/agent.el` (registry block ~113-196; consumers at ~227, ~472, ~605-614, ~700, ~726-727, ~1306-1307, ~1496-1500, ~1581; face docstring ~364)
- Modify: `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/agent-claude.el` (registration ~233-265)
- Modify: `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/agent-codex.el` (registration ~215-249)
- Modify: `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/test/agent-test.el` (~line 199; new tests before `(provide 'agent-test)`)

- [ ] **Step 1: Write the new tests.** In `test/agent-test.el`, insert before `(provide 'agent-test)`:
  ```elisp
  ;;;; Backend struct registry

  (ert-deftest agent-test-register-backend-rejects-unknown-keyword ()
    "Signal an error when registering a backend with an unknown keyword."
    (let ((agent-backends nil))
      (should-error
       (agent-register-backend
        'bad
        (agent-test--backend :bogus-slot #'ignore)))))

  (ert-deftest agent-test-registered-backend-is-struct ()
    "Store registrations as `agent-backend' structs keyed by name."
    (let ((agent-backends nil))
      (agent-register-backend 'one (agent-test--backend))
      (let ((struct (agent-backend 'one)))
        (should (agent-backend-p struct))
        (should (eq (agent-backend-name struct) 'one))
        (should (equal (agent-backend-label struct) "Test")))))

  (ert-deftest agent-test-backend-get-maps-keywords-to-slots ()
    "Map legacy keyword lookups onto struct slots."
    (let ((agent-backends nil))
      (agent-register-backend 'one (agent-test--backend :program "one-cli"))
      (should (equal (agent--backend-get 'one :program) "one-cli"))
      (should (equal (agent--backend-get 'one :label) "Test"))
      (should-not (agent--backend-get 'unregistered :label))))

  (ert-deftest agent-test-detect-backend-resolves-with-struct-registry ()
    "Resolve a buffer's backend through struct-based registrations."
    (let ((agent-backends nil))
      (with-temp-buffer
        (let ((buf (current-buffer)))
          (agent-register-backend
           'one
           (agent-test--backend
            :buffer-p (lambda (candidate) (eq candidate buf))))
          (should (eq (agent--detect-backend buf) 'one))))))
  ```
- [ ] **Step 2: Run them, expecting two failures.**
  ```bash
  cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent && ~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-test.el
  ```
  Expected: `agent-test-register-backend-rejects-unknown-keyword` and `agent-test-registered-backend-is-struct` fail (old code accepts unknown keys; `agent-backend`/`agent-backend-p` are void). The other two are regression guards and already pass.
- [ ] **Step 3: Replace the registry block.** In `agent.el`, replace everything from `(defvar agent-backends nil` (line 113) through the closing line of the old `agent--backend-get` (`  (plist-get (alist-get backend agent-backends) key))`, line 196) with:
  ```elisp
  (cl-defstruct (agent-backend (:constructor agent-backend--create) (:copier nil))
    "Static description of one registered AI agent backend.
  Slots listed after the transitional marker mirror legacy plist
  keys and are deleted as later refactoring phases migrate their
  call sites."
    name label icon program
    buffer-p find-all-buffers find-buffers-for-dir
    start-session session-identity
    send-string send-return submit target-buffer
    waiting-p busy-p background-tasks-p duration-ms display-name-suffix
    account-env-var accounts account-file shared-config-items account-init
    run-prompt skill-roots skill-command-prefix
    sync-theme modeline-status menu-suffixes
    before-exit-ready-to-close-p
    ;; Transitional slots, deleted in later phases:
    start start-new extract-directory extract-instance-name account
    send-command submit-command discover-skills handoff run-skill
    audit-project debug-backtrace act-on-slack-message setup-kill-on-exit
    exit restart)

  (defvar agent-backends nil
    "Alist of registered AI backends.
  Each entry is (NAME . STRUCT) where NAME is the backend symbol
  and STRUCT is an `agent-backend'.")

  (defvar-local agent--backend nil
    "Cached backend symbol for this buffer.")

  (defconst agent--required-backend-keys
    '(:buffer-p :find-all-buffers :extract-instance-name :start-new)
    "Backend slots required by the shared session layer.")

  (defconst agent--backend-slot-names
    (mapcar #'car (cdr (cl-struct-slot-info 'agent-backend)))
    "Slot names accepted by `agent-register-backend'.")

  (defun agent-register-backend (name &rest slots)
    "Register NAME as an AI agent backend built from SLOTS.
  SLOTS is a keyword-value list whose keywords match `agent-backend'
  slot names, e.g. (:buffer-p #\\='fn :label \"Codex\").  During the
  struct migration, a single plist argument is also accepted.
  Signal an error when SLOTS contains an unknown keyword or lacks a
  key in `agent--required-backend-keys'."
    (let ((plist (if (and (= (length slots) 1) (listp (car slots)))
                     (car slots)
                   slots)))
      (agent--validate-backend name plist)
      (setf (alist-get name agent-backends)
            (apply #'agent-backend--create :name name plist))))

  (defun agent--validate-backend (name plist)
    "Signal an error if backend NAME's PLIST is invalid.
  PLIST must contain only keywords naming `agent-backend' slots and
  must include every key in `agent--required-backend-keys'."
    (let ((rest plist))
      (while rest
        (let ((key (car rest)))
          (unless (and (keywordp key)
                       (memq (agent--backend-keyword-slot key)
                             agent--backend-slot-names))
            (error "AI backend `%s' has unknown slot keyword `%S'" name key))
          (setq rest (cddr rest)))))
    (dolist (key agent--required-backend-keys)
      (unless (plist-get plist key)
        (error "AI backend `%s' is missing required key `%s'" name key))))

  (defun agent-backend (name)
    "Return the registered `agent-backend' struct for NAME, or nil."
    (alist-get name agent-backends))

  (defun agent--detect-backend (&optional buffer)
    "Detect which AI backend BUFFER belongs to.
  Try each registered backend's buffer predicate.  Return the
  backend name symbol or nil."
    (let ((buf (or buffer (current-buffer))))
      (or (buffer-local-value 'agent--backend buf)
          (let ((found (cl-find-if
                        (lambda (entry)
                          (funcall (agent-backend-buffer-p (cdr entry)) buf))
                        agent-backends)))
            (when found
              (with-current-buffer buf
                (setq agent--backend (car found)))
              (car found))))))

  (defun agent--backend-get (backend key)
    "Return the slot named by keyword KEY in BACKEND's struct.
  BACKEND is a backend name symbol.  KEY is a keyword whose name,
  minus the leading colon, matches an `agent-backend' slot name.
  This is a compatibility shim during the struct migration; new
  code should call `agent-backend' slot accessors directly.
  Return nil when BACKEND is not registered."
    (when-let* ((struct (agent-backend backend)))
      (cl-struct-slot-value 'agent-backend
                            (agent--backend-keyword-slot key)
                            struct)))

  (defun agent--backend-keyword-slot (key)
    "Return the `agent-backend' slot symbol named by keyword KEY."
    (intern (substring (symbol-name key) 1)))
  ```
- [ ] **Step 4: Migrate the remaining direct plist consumers.** Same mechanical pattern everywhere: `(plist-get (cdr E) :KEY)` becomes `(agent-backend-KEY (cdr E))`. Fully worked example — in `agent--find-all-buffers` (~line 227), replace:
  ```elisp
        (let ((bufs (funcall (plist-get (cdr entry) :find-all-buffers))))
  ```
  with:
  ```elisp
        (let ((bufs (funcall (agent-backend-find-all-buffers (cdr entry)))))
  ```
  Apply the same pattern at each remaining site:

  | Location (function) | Old expression | New expression |
  |---|---|---|
  | `agent--do-sync-theme` ~472 | `(plist-get (cdr entry) :sync-theme)` | `(agent-backend-sync-theme (cdr entry))` |
  | `agent-start-new-session` ~605 | `(plist-get (cdar backends) :start-new)` | `(agent-backend-start-new (cdar backends))` |
  | `agent-start-new-session` ~608 and `agent--resolve-backend` ~1306 (identical text; replace both) | `(plist-get (cdr e) :label)` | `(agent-backend-label (cdr e))` |
  | `agent--accountless-labels` ~726 | `(plist-get (cdr entry) :account)` | `(agent-backend-account (cdr entry))` |
  | `agent--accountless-labels` ~727 | `(plist-get (cdr entry) :label)` | `(agent-backend-label (cdr entry))` |
  | `agent--discover-all-skills` ~1581 | `(plist-get (cdr entry) :discover-skills)` | `(agent-backend-discover-skills (cdr entry))` |
- [ ] **Step 5: Rename `:has-background-tasks-p` to `:background-tasks-p` everywhere.** Four code sites plus two doc mentions:
  - `agent.el` ~699-700, replace `(agent--backend-get
                            backend :has-background-tasks-p)` with `(agent--backend-get
                            backend :background-tasks-p)` (keep the line break).
  - `agent-claude.el` registration: `:has-background-tasks-p #'agent-claude--has-background-tasks-p` → `:background-tasks-p #'agent-claude--has-background-tasks-p`.
  - `agent-codex.el` registration: `:has-background-tasks-p #'agent-codex--has-background-tasks-p` → `:background-tasks-p #'agent-codex--has-background-tasks-p`.
  - `test/agent-test.el` ~199: `:has-background-tasks-p (lambda (_buffer) t)))` → `:background-tasks-p (lambda (_buffer) t)))`.
  - `agent.el` ~364 (face `agent-waiting-with-background` docstring): replace `` `:has-background-tasks-p' `` with `` `:background-tasks-p' ``.
- [ ] **Step 6: Drop `:directory` and migrate its one consumer.** Delete from the `agent-claude.el` registration the line:
  ```elisp
        :directory (lambda (buf) (with-current-buffer buf (claude-code--directory)))
  ```
  and from the `agent-codex.el` registration the line:
  ```elisp
        :directory (lambda (buf) (with-current-buffer buf (codex--directory)))
  ```
  In `agent.el`, replace `agent--buffer-directory` (~1495-1500):
  ```elisp
  (defun agent--buffer-directory (backend buffer)
    "Return the normalized directory for BACKEND session BUFFER."
    (when-let* ((directory-fn (agent--backend-get backend :directory))
                (directory (funcall directory-fn buffer)))
      (file-name-as-directory (file-truename directory))))
  ```
  with:
  ```elisp
  (defun agent--buffer-directory (_backend buffer)
    "Return the normalized directory for BUFFER's session.
  _BACKEND is unused; the directory comes from BUFFER's
  `agent-session' struct."
    (when-let* ((session (agent-session buffer))
                (directory (agent-session-directory session)))
      (file-name-as-directory (file-truename directory))))
  ```
- [ ] **Step 7: Full verification.**
  ```bash
  cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent
  ~/My\ Drive/dotfiles/claude/bin/batch-test.sh agent
  ~/My\ Drive/dotfiles/claude/bin/batch-test.sh agent-claude
  ~/My\ Drive/dotfiles/claude/bin/batch-test.sh agent-codex
  make test && make compile
  ```
  Expected: all loads succeed (the claude/codex registrations still use the transitional plist form); `Ran 196 tests, 196 results as expected, 0 unexpected`; compile clean apart from baseline warnings.
- [ ] **Step 8: Commit.**
  ```bash
  cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent && git add agent.el agent-claude.el agent-codex.el test/agent-test.el && git commit -m "agent: convert backend registry to agent-backend struct"
  ```

### Task 1.3: Migrate registration call sites to the keyword API

**Files:**
- Modify: `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/agent-claude.el` (registration form, starts `(agent-register-backend 'claude-code`)
- Modify: `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/agent-codex.el` (registration form, starts `(agent-register-backend 'codex`)
- Modify: `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/test/agent-test.el`, `test/agent-chief-test.el` (mechanical: every `agent-register-backend` call)
- Modify: `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/agent.el` (remove transitional plist acceptance)
- Modify: `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/README.org` (line ~355)

- [ ] **Step 1: Replace the Claude registration.** In `agent-claude.el`, replace the entire `(agent-register-backend 'claude-code (list ...))` form (as it stands after Task 1.2: no `:directory`, `:background-tasks-p` renamed) with:
  ```elisp
  (agent-register-backend 'claude-code
    :buffer-p #'claude-code--buffer-p
    :find-all-buffers #'claude-code--find-all-claude-buffers
    :find-buffers-for-dir #'claude-code--find-claude-buffers-for-directory
    :extract-directory #'claude-code--extract-directory-from-buffer-name
    :extract-instance-name #'claude-code--extract-instance-name-from-buffer-name
    :send-command #'agent-claude-send-command
    :submit-command #'agent-claude-submit-command
    :start #'claude-code--start
    :start-new #'agent-claude--start-with-account
    :program "claude"
    :send-return #'agent-claude-send-return
    :icon (lambda (&optional face)
            (let ((svg (agent-svg-icon agent-claude-icon-svg face)))
              (if (string-empty-p svg) "CC" svg)))
    :account (lambda (buf)
               (buffer-local-value 'agent-claude--buffer-account buf))
    :background-tasks-p #'agent-claude--has-background-tasks-p
    :duration-ms (lambda (buf)
                   (with-current-buffer buf
                     (agent-claude-status-duration-ms)))
    :display-name-suffix #'agent-claude--branch-suffix
    :label "Claude Code"
    :discover-skills #'agent-claude--discover-skills
    :handoff #'agent-claude-handoff
    :run-skill #'agent-claude-run-skill
    :audit-project #'agent-claude-audit-project
    :debug-backtrace #'agent-claude-debug-backtrace
    :act-on-slack-message #'agent-claude-act-on-slack-message
    :setup-kill-on-exit #'agent-claude-setup-kill-on-exit
    :exit #'agent-claude-exit
    :restart #'agent-claude-restart
    :sync-theme #'agent-claude--sync-theme)
  ```
- [ ] **Step 2: Replace the Codex registration.** In `agent-codex.el`, replace the entire `(agent-register-backend 'codex (list ...))` form with:
  ```elisp
  (agent-register-backend 'codex
    :buffer-p #'codex--buffer-p
    :find-all-buffers #'codex--find-all-codex-buffers
    :find-buffers-for-dir #'codex--find-codex-buffers-for-directory
    :extract-directory #'codex--extract-directory-from-buffer-name
    :extract-instance-name #'codex--extract-instance-name-from-buffer-name
    :send-command #'agent-codex-send-command
    :send-return #'agent-codex-send-return
    :submit-command #'agent-codex-submit-command
    :before-exit-ready-to-close-p #'agent-codex-before-exit-ready-to-close-p
    :duration-ms (lambda (buf)
                   (with-current-buffer buf
                     (agent-codex-status-duration-ms)))
    :start #'codex--start
    :start-new #'agent-codex--start-with-account
    :program "codex"
    :icon (lambda (&optional face)
            (let ((svg (agent-svg-icon agent-codex-icon-svg face)))
              (if (string-empty-p svg) "CX" svg)))
    :account (lambda (buf)
               (buffer-local-value 'agent-codex--buffer-account buf))
    :waiting-p #'agent-codex--waiting-p
    :background-tasks-p #'agent-codex--has-background-tasks-p
    :busy-p #'agent-codex--busy-p
    :label "Codex"
    :discover-skills #'agent-codex--discover-skills
    :handoff #'agent-codex-handoff
    :run-skill #'agent-codex-run-skill
    :audit-project #'agent-codex-audit-project
    :debug-backtrace #'agent-codex-debug-backtrace
    :act-on-slack-message #'agent-codex-act-on-slack-message
    :setup-kill-on-exit #'agent-codex-setup-kill-on-exit
    :exit #'agent-codex-exit
    :restart #'agent-codex-restart
    :sync-theme #'agent-codex--sync-theme)
  ```
- [ ] **Step 3: Convert all test registrations mechanically.** Every test call passes a constructed list, so spreading it with `apply` is the entire migration. Pattern — `(agent-register-backend 'one (agent-test--backend ...))` becomes `(apply #'agent-register-backend 'one (agent-test--backend ...))`; one fully worked example, from `agent-test-register-backend-requires-session-keys`:
  ```elisp
  (should-error
   (apply #'agent-register-backend 'bad (list :buffer-p #'ignore)))
  ```
  Apply to every occurrence in both files with:
  ```bash
  cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent
  sed -i '' "s/(agent-register-backend/(apply #'agent-register-backend/g" test/agent-test.el test/agent-chief-test.el
  grep -c "apply #'agent-register-backend" test/agent-test.el test/agent-chief-test.el
  ```
  Expected counts: 36 in `test/agent-test.el` (33 pre-existing + 3 added by Tasks 1.1/1.2), 3 in `test/agent-chief-test.el`. (`test/agent-claude-test.el` and `test/agent-codex-test.el` contain none.)
- [ ] **Step 4: Remove the transitional plist acceptance.** In `agent.el`, replace in `agent-register-backend`:
  ```elisp
    SLOTS is a keyword-value list whose keywords match `agent-backend'
  slot names, e.g. (:buffer-p #\\='fn :label \"Codex\").  During the
  struct migration, a single plist argument is also accepted.
  Signal an error when SLOTS contains an unknown keyword or lacks a
  key in `agent--required-backend-keys'."
    (let ((plist (if (and (= (length slots) 1) (listp (car slots)))
                     (car slots)
                   slots)))
      (agent--validate-backend name plist)
      (setf (alist-get name agent-backends)
            (apply #'agent-backend--create :name name plist))))
  ```
  with:
  ```elisp
    SLOTS is a keyword-value list whose keywords match `agent-backend'
  slot names, e.g. (:buffer-p #\\='fn :label \"Codex\").  Signal an
  error when SLOTS contains an unknown keyword or lacks a key in
  `agent--required-backend-keys'."
    (agent--validate-backend name slots)
    (setf (alist-get name agent-backends)
          (apply #'agent-backend--create :name name slots)))
  ```
- [ ] **Step 5: Update README.org.** At line ~355, replace the sentence describing the plist API:
  ```
  The function ~agent-register-backend~ registers an AI tool by associating a backend symbol with a property list of buffer predicates, session discovery functions, command senders, and optional command handlers. Backend modules call it at load time. Required keys are validated so the shared session layer can rely on a consistent interface.
  ```
  with:
  ```
  The function ~agent-register-backend~ registers an AI tool by constructing an ~agent-backend~ struct from keyword arguments: buffer predicates, session discovery functions, command senders, and optional command handlers. Backend modules call it at load time. Keywords are validated against the struct's slot names, and required slots are checked so the shared session layer can rely on a consistent interface.
  ```
- [ ] **Step 6: Full verification.**
  ```bash
  cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent
  ~/My\ Drive/dotfiles/claude/bin/batch-test.sh agent-claude
  ~/My\ Drive/dotfiles/claude/bin/batch-test.sh agent-codex
  make test && make compile
  ```
  Expected: loads succeed; `Ran 196 tests, 196 results as expected, 0 unexpected`; baseline-only warnings.
- [ ] **Step 7: Commit.**
  ```bash
  cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent && git add agent.el agent-claude.el agent-codex.el test/agent-test.el test/agent-chief-test.el README.org && git commit -m "agent: migrate backend registrations to keyword API"
  ```

### Task 1.4: Populate `agent--session` at session start

Sessions get their account captured today via `claude-code-start-hook` → `agent-claude--capture-buffer-account` (agent-claude.el, hooked at line ~2597) and `codex-start-hook` → `agent-codex--capture-buffer-account` (hooked inside `agent-codex--install-hooks`). Extend both capture functions to also build the session struct via core `agent--capture-session` (added in Task 1.1). The account must be stored before `agent--capture-session` runs, because the backend's `:account` function reads the buffer-local variable; this also intentionally overwrites any accountless struct that lazy backfill may have stored earlier in the hook sequence (codex runs `agent--refresh-display-names` before its capture hook).

**Files:**
- Modify: `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/test/agent-test.el` (before `(provide 'agent-test)`)
- Modify: `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/test/agent-claude-test.el`, `test/agent-codex-test.el` (one integration test each, appended before each file's `provide`/footer)
- Modify: `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/agent-claude.el` (`agent-claude--capture-buffer-account`, ~1363)
- Modify: `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/agent-codex.el` (`agent-codex--capture-buffer-account`, ~515)

- [ ] **Step 1: Write the failing tests.** In `test/agent-test.el`, add to the `;;;; Session identity` section:
  ```elisp
  (ert-deftest agent-test-capture-session-replaces-stale-struct ()
    "Re-capture session identity over an earlier accountless struct."
    (let ((agent-backends nil))
      (with-temp-buffer
        (rename-buffer "*one:~/repo/recapture-proj/:tests*" t)
        (let ((buf (current-buffer)))
          (apply #'agent-register-backend
                 'one
                 (agent-test--backend
                  :buffer-p (lambda (candidate) (eq candidate buf))
                  :extract-instance-name
                  (lambda (name)
                    (when (string-match ":\\([^:/*]+\\)\\*\\'" name)
                      (match-string 1 name)))
                  :account (lambda (_buffer) "work")))
          (agent--set-session
           buf
           (agent-session-create :backend 'one
                                 :directory "~/repo/recapture-proj/"))
          (let ((session (agent--capture-session buf)))
            (should (equal (agent-session-account session) "work"))
            (should (eq (buffer-local-value 'agent--session buf) session)))))))
  ```
  In `test/agent-claude-test.el`, append before its footer:
  ```elisp
  ;;;; Session capture

  (ert-deftest agent-claude-test-capture-buffer-account-stores-session ()
    "Store the session struct when capturing the buffer account."
    (with-temp-buffer
      (rename-buffer "*claude:~/repo/claude-capture-session-test/:default*" t)
      (let ((agent-claude--pending-account "personal"))
        (agent-claude--capture-buffer-account)
        (let ((session (agent-session (current-buffer))))
          (should session)
          (should (eq (agent-session-backend session) 'claude-code))
          (should (equal (agent-session-account session) "personal"))
          (should (equal (agent-session-directory session)
                         "~/repo/claude-capture-session-test/"))
          (should (equal (agent-session-instance session) "default"))))))
  ```
  In `test/agent-codex-test.el`, append before its footer:
  ```elisp
  ;;;; Session capture

  (ert-deftest agent-codex-test-capture-buffer-account-stores-session ()
    "Store the session struct when capturing the buffer account."
    (with-temp-buffer
      (rename-buffer "*codex:~/repo/codex-capture-session-test/:default*" t)
      (let ((agent-codex--pending-account "personal"))
        (agent-codex--capture-buffer-account)
        (let ((session (agent-session (current-buffer))))
          (should session)
          (should (eq (agent-session-backend session) 'codex))
          (should (equal (agent-session-account session) "personal"))
          (should (equal (agent-session-directory session)
                         "~/repo/codex-capture-session-test/"))
          (should (equal (agent-session-instance session) "default"))))))
  ```
- [ ] **Step 2: Run, expecting targeted failures.**
  ```bash
  cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent
  ~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-test.el agent-test-capture-session-replaces-stale-struct
  ~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-claude-test.el agent-claude-test-capture-buffer-account-stores-session
  ~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-codex-test.el agent-codex-test-capture-buffer-account-stores-session
  ```
  Expected: the core test passes already (capture semantics exist since Task 1.1 — it is a regression guard); the claude and codex tests fail on the account assertion, because the capture functions do not yet build the struct after storing the account (lazy backfill ran with a nil buffer-local account, or no struct is stored at all if backfill never triggered — either way the `agent-session-account` assertion fails). If the claude/codex tests unexpectedly pass, re-check that `agent-claude--capture-buffer-account` has not already been migrated, then continue.
- [ ] **Step 3: Implement the Claude side.** In `agent-claude.el`, replace `agent-claude--capture-buffer-account`:
  ```elisp
  (defun agent-claude--capture-buffer-account ()
    "Store the account name as a buffer-local variable.
  Called from `claude-code-start-hook'.  Uses the dynamically bound
  `agent-claude--pending-account' when available (set by
  `agent-claude--start-with-account'), otherwise falls back to
  `agent-claude--resolve-account' so that sessions started via
  other code paths (e.g. `agent-log-resume-session') also get an account."
    (setq agent-claude--buffer-account
          (or agent-claude--pending-account
              (agent-claude--resolve-account))))
  ```
  with:
  ```elisp
  (defun agent-claude--capture-buffer-account ()
    "Store the account name and session identity for the new buffer.
  Called from `claude-code-start-hook'.  Uses the dynamically bound
  `agent-claude--pending-account' when available (set by
  `agent-claude--start-with-account'), otherwise falls back to
  `agent-claude--resolve-account' so that sessions started via
  other code paths (e.g. `agent-log-resume-session') also get an
  account.  Then constructs and stores the buffer's `agent-session'
  struct via `agent--capture-session'."
    (setq agent-claude--buffer-account
          (or agent-claude--pending-account
              (agent-claude--resolve-account)))
    (agent--capture-session (current-buffer)))
  ```
- [ ] **Step 4: Implement the Codex side.** In `agent-codex.el`, replace `agent-codex--capture-buffer-account`:
  ```elisp
  (defun agent-codex--capture-buffer-account ()
    "Store the account name as a buffer-local variable."
    (setq agent-codex--buffer-account
          (or agent-codex--pending-account
              (agent-codex--resolve-account))))
  ```
  with:
  ```elisp
  (defun agent-codex--capture-buffer-account ()
    "Store the account name and session identity for the new buffer.
  Called from `codex-start-hook'.  Then constructs and stores the
  buffer's `agent-session' struct via `agent--capture-session'."
    (setq agent-codex--buffer-account
          (or agent-codex--pending-account
              (agent-codex--resolve-account)))
    (agent--capture-session (current-buffer)))
  ```
- [ ] **Step 5: Run expecting success, plus full verification.**
  ```bash
  cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent && make test && make compile
  ```
  Expected: `Ran 200 tests, 200 results as expected, 0 unexpected` (agent 60, claude 67, codex 52, chief 20... totals: 60+67+52+20 = 199; if your count differs by the one regression-guard test, confirm all files individually report `0 unexpected` — that is the acceptance criterion); baseline-only warnings.
- [ ] **Step 6: Commit.**
  ```bash
  cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent && git add agent-claude.el agent-codex.el test/agent-test.el test/agent-claude-test.el test/agent-codex-test.el && git commit -m "agent: capture session identity at session start"
  ```

### Task 1.5: Prefer the session struct in display names and the session switcher

Migrate the highest-value read sites — `agent--buffer-session-name` and `agent--qualified-session-name` (display names, agent.el:521-582) and `agent--session-group-key` (switcher grouping, agent.el:647-656) — to read `agent-session` fields, falling back to buffer-name parsing for buffers without a struct. `agent--qualified-session-name` has exactly one caller (`agent--compute-display-name`, ~line 559), so its argument changes from a buffer-name string to a buffer.

**Files:**
- Modify: `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/test/agent-test.el` (before `(provide 'agent-test)`)
- Modify: `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/agent.el` (~523-537, ~559, ~647-656)

- [ ] **Step 1: Write the failing tests.** In `test/agent-test.el`, add to the `;;;; Session identity` section:
  ```elisp
  (ert-deftest agent-test-display-name-prefers-session-struct ()
    "Use the stored session identity instead of buffer-name parsing."
    (let ((agent-backends nil))
      (with-temp-buffer
        (let ((buf (current-buffer)))
          (apply #'agent-register-backend
                 'one
                 (agent-test--backend
                  :buffer-p (lambda (candidate) (eq candidate buf))
                  :find-all-buffers (lambda () (list buf))))
          (agent--set-session
           buf
           (agent-session-create :backend 'one
                                 :directory "~/repo/struct-name-wins/"))
          (should (equal (agent-display-name buf) "struct-name-wins"))))))

  (ert-deftest agent-test-session-group-key-prefers-struct-account ()
    "Group sessions by the account stored in the session struct."
    (let ((agent-backends nil))
      (with-temp-buffer
        (let ((buf (current-buffer)))
          (apply #'agent-register-backend
                 'one
                 (agent-test--backend
                  :buffer-p (lambda (candidate) (eq candidate buf))
                  :account (lambda (_buffer) "fallback-account")))
          (agent--set-session
           buf
           (agent-session-create :backend 'one
                                 :account "struct-account"
                                 :directory "~/repo/a/"))
          (should (equal (agent--session-group-key buf) "struct-account"))))))
  ```
  (Both use temp buffers whose names cannot be parsed as session names, so passing proves the struct path is used.)
- [ ] **Step 2: Run, expecting both to fail.**
  ```bash
  cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent && ~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-test.el agent-test-display-name-prefers-session-struct
  cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent && ~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-test.el agent-test-session-group-key-prefers-struct-account
  ```
  Expected: the first fails (display name falls back to the raw temp-buffer name); the second fails with `"fallback-account"` instead of `"struct-account"`.
- [ ] **Step 3: Rewrite the display-name readers.** In `agent.el`, replace:
  ```elisp
  (defun agent--buffer-session-name (buffer)
    "Return the session name for BUFFER."
    (agent--session-name (buffer-name buffer)))

  (defun agent--qualified-session-name (buffer-name)
    "Return a qualified session name from BUFFER-NAME.
  Includes instance name when present for disambiguation."
    (let* ((backend (agent--detect-backend (get-buffer buffer-name)))
           (project (agent--session-name buffer-name))
           (instance (when backend
                       (funcall (agent--backend-get backend :extract-instance-name)
                                buffer-name))))
      (if instance
          (format "%s:%s" project instance)
        project)))
  ```
  with:
  ```elisp
  (defun agent--buffer-session-name (buffer)
    "Return the session name for BUFFER.
  Prefers the directory stored in BUFFER's `agent-session' struct,
  falling back to parsing the buffer name."
    (if-let* ((session (agent-session buffer))
              (directory (agent-session-directory session)))
        (agent--directory-project-name directory)
      (agent--session-name (buffer-name buffer))))

  (defun agent--directory-project-name (directory)
    "Return the project name for DIRECTORY, its last path component."
    (let ((name (file-name-nondirectory (directory-file-name directory))))
      (if (string-empty-p name) directory name)))

  (defun agent--qualified-session-name (buffer)
    "Return a qualified session name for BUFFER.
  Includes the instance name when present for disambiguation.
  Prefers BUFFER's `agent-session' fields, falling back to
  buffer-name parsing."
    (let* ((session (agent-session buffer))
           (project (agent--buffer-session-name buffer))
           (instance
            (if session
                (agent-session-instance session)
              (when-let* ((backend (agent--detect-backend buffer)))
                (funcall (agent--backend-get backend :extract-instance-name)
                         (buffer-name buffer))))))
      (if instance
          (format "%s:%s" project instance)
        project)))
  ```
- [ ] **Step 4: Update the single caller.** In `agent--compute-display-name` (~line 559), replace:
  ```elisp
           (base (if (member name sibling-names)
                     (agent--qualified-session-name (buffer-name buffer))
                   name)))
  ```
  with:
  ```elisp
           (base (if (member name sibling-names)
                     (agent--qualified-session-name buffer)
                   name)))
  ```
- [ ] **Step 5: Rewrite the switcher group key.** In `agent.el`, replace:
  ```elisp
  (defun agent--session-group-key (buffer)
    "Return the group key for BUFFER in the session switcher.
  Uses the backend's :account function if available, falling back
  to the backend's :label or symbol name."
    (let ((backend (agent--detect-backend buffer)))
      (or (when-let* ((account-fn (agent--backend-get backend :account)))
            (funcall account-fn buffer))
          (agent--backend-get backend :label)
          (and backend (symbol-name backend))
          "Sessions")))
  ```
  with:
  ```elisp
  (defun agent--session-group-key (buffer)
    "Return the group key for BUFFER in the session switcher.
  Prefers the account stored in BUFFER's `agent-session', then the
  backend's :account function, then the backend's :label or symbol
  name."
    (let ((backend (agent--detect-backend buffer)))
      (or (when-let* ((session (agent-session buffer)))
            (agent-session-account session))
          (when-let* ((account-fn (agent--backend-get backend :account)))
            (funcall account-fn buffer))
          (agent--backend-get backend :label)
          (and backend (symbol-name backend))
          "Sessions")))
  ```
- [ ] **Step 6: Run expecting success, plus full verification.**
  ```bash
  cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent
  ~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-test.el
  make test && make compile
  ```
  Expected: agent-test.el reports `0 unexpected` (all earlier display-name and group-key tests still pass — they exercise the struct path through lazy backfill now); `make test` reports two more tests than after Task 1.4 with `0 unexpected`; baseline-only warnings.
- [ ] **Step 7: Commit.**
  ```bash
  cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent && git add agent.el test/agent-test.el && git commit -m "agent: prefer session struct in display names and switcher"
  ```

---

Notes for the orchestrator (not part of the task text): baseline was re-verified live today at commit `1c5766c` — all 187 tests pass and `make`-equivalent compile/test invocations were trial-run successfully before being written into Task 0.1. Two deviations from the brief's "verified unreferenced" list were found and handled: `agent-claude--scroll-to-bottom` and `agent-claude--session-name` each have one live internal caller plus tests (handled by migration in Task 0.5 rather than blind deletion), and `agent-claude-display-name`/`agent-claude-alert-indicator` have test/dotfiles references (handled in Task 0.4). The locked struct contract omits a `directory` slot and uses `background-tasks-p` while the live code uses `:directory`/`:has-background-tasks-p`; Task 1.2 resolves both explicitly. A transitional both-forms `agent-register-backend` keeps every commit green between the registry conversion (1.2) and the call-site migration (1.3), where it is removed.

## Phase 2 — Parameterized session start and upstream Codex API

**Repos touched:**

| Repo | Path | Commits scoped |
|---|---|---|
| codex (upstream, benthamite/codex) | `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/codex/` | `codex: …` |
| agent | `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/` | `agent: …`, `agent-claude: …`, `agent-codex: …`, `agent-chief: …` |

**Do NOT edit** `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/claude-code/` (third-party). Its private functions are wrapped, never modified.

**Preconditions (Phase 1 must already be merged in the agent repo).** Verify before starting:

```bash
cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent
grep -n "cl-defstruct agent-session" agent.el        # struct with backend account directory instance id
grep -n "defun agent--set-session" agent.el          # (agent--set-session buffer session)
grep -n "defun agent-session " agent.el              # (agent-session &optional buffer) accessor
grep -n "agent--backend-get" agent.el                # keyword shim
```

If any of these is missing, STOP and report; do not improvise the Phase 1 contract.

**Line numbers** below are valid at agent commit `1c5766c` and codex commit `7848362`. If files have drifted, re-locate anchors with the quoted code, which is verbatim.

**Test commands** (run from each repo root; `elisp-ert` resolves the package source via Elpaca):

```bash
# codex repo
cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/codex
trash codex.elc codex-eat.elc codex-vterm.elc 2>/dev/null || true   # stale .elc shadows edited .el
~/My\ Drive/dotfiles/claude/bin/elisp-ert codex codex-test.el

# agent repo
cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent
~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-codex-test.el
~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-claude-test.el
~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-test.el

# load checks
~/My\ Drive/dotfiles/claude/bin/batch-test.sh codex
~/My\ Drive/dotfiles/claude/bin/batch-test.sh agent
```

A passing ERT run ends with `Ran N tests, N results as expected` (no `unexpected` line). Always delete the stale `.elc` files in the codex source dir before running codex tests; otherwise `(require 'codex)` loads the old compiled code.

**Intentional behavior changes shipped in this phase** (flag these in commit messages where noted):

1. `agent-codex-restart` now reuses the session's **buffer-local** terminal backend instead of `(default-value 'codex-terminal-backend)` (locked design decision; the test `agent-codex-test-restart-uses-default-backend-option` is rewritten accordingly in Task 2.9).
2. Codex sessions started with an initial prompt under the `app-server` backend now submit the prompt through the app-server queue instead of appending it to the `codex app-server` CLI switches (the old path passed the prompt as a CLI switch, which the app-server ignores; this was latent breakage in `agent-codex--debug-start-session` and `agent-codex-handoff` when `codex-terminal-backend` is `app-server`, the default).
3. The Codex prompt-glyph regexp is now single-sourced from `codex--prompt-marker-regexp` (`[›❯>]`), which also recognizes the legacy `>` glyph that agent's private copy (`[›❯]`) had drifted from.

**Extension to the locked backend signature.** The locked `start-session` signature `(session &key initial-prompt resume-id)` is extended with two additive, backend-specific keywords needed for behavior parity at existing call sites: `:fork` (Claude Code, for `--fork-session` in `agent-claude-create-branch`) and `:terminal-backend` (Codex, for restart). `agent-start-session` passes unknown keywords through to the backend.

---

### Task 2.1: `codex-start-session` — public parameterized entry point (codex repo)

**Files:**
- Modify `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/codex/codex.el` (lines ~837–845 `codex--buffer-name`, ~1060–1063 `codex--buffer-name-for-directory`, ~999–1037 `codex--start`/`codex--start-subcommand` area; insert new code after `codex--start-subcommand`)
- Modify `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/codex/codex-test.el` (append tests)

- [ ] **Step 1: Write failing tests.** Append to `codex-test.el` (after the `codex-test-app-server-subcommands-error` test, ~line 2790):

```elisp
(ert-deftest codex-test-start-session-uses-explicit-parameters ()
  "Start sessions from explicit directory, instance, and backend."
  (let (captured)
    (cl-letf (((symbol-function 'codex--launch-session)
               (lambda (dir backend buffer-name instance-name _switches
                            switch-after)
                 (setq captured (list dir backend buffer-name instance-name
                                      switch-after))
                 (generate-new-buffer " *codex-test-session*"))))
      (let ((buffer (codex-start-session :directory "/tmp/project"
                                         :instance-name "tests"
                                         :terminal-backend 'eat)))
        (unwind-protect
            (progn
              (should (equal (nth 0 captured) "/tmp/project/"))
              (should (eq (nth 1 captured) 'eat))
              (should (equal (nth 2 captured)
                             (format "*codex:%s:tests*"
                                     (abbreviate-file-name
                                      (file-truename "/tmp/project/")))))
              (should (equal (nth 3 captured) "tests"))
              (should (eq (nth 4 captured) t))
              (should (buffer-live-p buffer)))
          (kill-buffer buffer))))))

(ert-deftest codex-test-start-session-resume-uses-terminal-subcommand ()
  "Resume by id through `codex resume <id>' on terminal backends."
  (let ((codex-program-switches '("--search"))
        (codex-use-alt-screen t)
        (codex-model nil)
        (codex-profile nil)
        (codex-reasoning-effort nil)
        (codex-full-auto nil)
        (codex-sandbox-mode nil)
        (codex-approval-policy nil)
        (codex-default-images nil)
        (codex-disable-terminal-resize-reflow nil)
        captured-switches)
    (cl-letf (((symbol-function 'codex--launch-session)
               (lambda (_dir _backend _buffer-name _instance switches _switch)
                 (setq captured-switches switches)
                 (generate-new-buffer " *codex-test-session*"))))
      (kill-buffer (codex-start-session :directory "/tmp/project"
                                        :instance-name "default"
                                        :terminal-backend 'eat
                                        :resume-id "abc123")))
    (should (equal captured-switches '("--search" "resume" "abc123")))))

(ert-deftest codex-test-start-session-initial-prompt-is-cli-arg-on-eat ()
  "Pass the initial prompt as a CLI argument on terminal backends."
  (let ((codex-program-switches nil)
        (codex-use-alt-screen t)
        (codex-model nil)
        (codex-profile nil)
        (codex-reasoning-effort nil)
        (codex-full-auto nil)
        (codex-sandbox-mode nil)
        (codex-approval-policy nil)
        (codex-default-images nil)
        (codex-disable-terminal-resize-reflow nil)
        captured-switches sent)
    (cl-letf (((symbol-function 'codex--launch-session)
               (lambda (_dir _backend _buffer-name _instance switches _switch)
                 (setq captured-switches switches)
                 (generate-new-buffer " *codex-test-session*")))
              ((symbol-function 'codex--send-command-to-buffer)
               (lambda (cmd buffer) (setq sent cmd) buffer)))
      (kill-buffer (codex-start-session :directory "/tmp/project"
                                        :instance-name "default"
                                        :terminal-backend 'eat
                                        :initial-prompt "fix the bug")))
    (should (equal captured-switches '("fix the bug")))
    (should-not sent)))

(ert-deftest codex-test-start-session-app-server-submits-initial-prompt ()
  "Submit the initial prompt through the app-server queue after launch."
  (let (sent)
    (cl-letf (((symbol-function 'codex--launch-session)
               (lambda (&rest _)
                 (generate-new-buffer " *codex-test-session*")))
              ((symbol-function 'codex--send-command-to-buffer)
               (lambda (cmd buffer) (setq sent cmd) buffer)))
      (kill-buffer (codex-start-session :directory "/tmp/project"
                                        :instance-name "default"
                                        :terminal-backend 'app-server
                                        :initial-prompt "hello")))
    (should (equal sent "hello"))))

(ert-deftest codex-test-start-session-app-server-resume-sets-pending-startup ()
  "Resume app-server sessions through the pending startup variables."
  (let (captured-action captured-id)
    (cl-letf (((symbol-function 'codex--launch-session)
               (lambda (&rest _)
                 (setq captured-action codex--app-server-pending-startup-action)
                 (setq captured-id
                       codex--app-server-pending-startup-session-id)
                 (generate-new-buffer " *codex-test-session*"))))
      (kill-buffer (codex-start-session :directory "/tmp/project"
                                        :instance-name "default"
                                        :terminal-backend 'app-server
                                        :resume-id "abc123")))
    (should (eq captured-action 'resume-session))
    (should (equal captured-id "abc123"))))
```

Run and confirm they fail with `void-function codex-start-session`:

```bash
cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/codex
trash codex.elc codex-eat.elc codex-vterm.elc 2>/dev/null || true
~/My\ Drive/dotfiles/claude/bin/elisp-ert codex codex-test.el codex-test-start-session-uses-explicit-parameters
```

- [ ] **Step 2: Make `codex--buffer-name-for-directory` use its DIR argument directly.** Today it re-derives the directory through ambient `codex--directory`, which is exactly why callers had to `cl-letf` it. Replace (codex.el ~1060):

```elisp
(defun codex--buffer-name-for-directory (dir instance-name)
  "Return the Codex buffer name for DIR and INSTANCE-NAME."
  (let ((default-directory dir))
    (codex--buffer-name instance-name)))
```

with:

```elisp
(defun codex--buffer-name-for-directory (dir instance-name)
  "Return the Codex buffer name for DIR and INSTANCE-NAME."
  (let ((truename (abbreviate-file-name (file-truename dir))))
    (if instance-name
        (format "*codex:%s:%s*" truename instance-name)
      (format "*codex:%s*" truename))))
```

Then make `codex--buffer-name` (codex.el ~837) delegate so there is one formatter. Replace:

```elisp
(defun codex--buffer-name (&optional instance-name)
  "Generate the Codex buffer name based on project or current buffer file.
If INSTANCE-NAME is provided, include it in the buffer name."
  (let ((dir (codex--directory)))
    (if dir
        (if instance-name
            (format "*codex:%s:%s*" (abbreviate-file-name (file-truename dir)) instance-name)
          (format "*codex:%s*" (abbreviate-file-name (file-truename dir))))
      (error "Cannot determine Codex directory - no `default-directory'!"))))
```

with:

```elisp
(defun codex--buffer-name (&optional instance-name)
  "Generate the Codex buffer name based on project or current buffer file.
If INSTANCE-NAME is provided, include it in the buffer name."
  (let ((dir (codex--directory)))
    (unless dir
      (error "Cannot determine Codex directory - no `default-directory'!"))
    (codex--buffer-name-for-directory dir instance-name)))
```

- [ ] **Step 3: Add `codex-start-session` and its worker.** Insert immediately after the closing paren of `codex--start-subcommand` (codex.el ~1037), before `codex--build-backend-switches`:

```elisp
;;;###autoload
(cl-defun codex-start-session (&key directory instance-name initial-prompt
                                    resume-id terminal-backend)
  "Start a Codex session from explicit parameters and return its buffer.
DIRECTORY is the project directory, defaulting to `codex--directory'.
INSTANCE-NAME names the session instance; when nil, derive one the way
`codex' does, prompting only when instances already exist in DIRECTORY.
INITIAL-PROMPT is submitted as the first user message.  RESUME-ID
resumes the session with that id instead of starting fresh.
TERMINAL-BACKEND overrides `codex-terminal-backend' for this session;
because that variable is buffer-local in session buffers, calling this
function from inside a session buffer reuses that session's backend."
  (let* ((dir (file-name-as-directory
               (expand-file-name (or directory (codex--directory)))))
         (backend (or terminal-backend codex-terminal-backend))
         (instance (or instance-name (codex--session-instance-name dir))))
    (codex--start-session-buffer dir backend instance nil resume-id
                                 initial-prompt t)))

(defun codex--start-session-buffer (dir backend instance extra-switches
                                        resume-id initial-prompt switch-after)
  "Launch a Codex session and return its buffer.
DIR, BACKEND, and INSTANCE identify the session.  EXTRA-SWITCHES are
appended CLI switches.  RESUME-ID resumes that session id.
INITIAL-PROMPT is the opening user message.  SWITCH-AFTER non-nil pops
to the new buffer."
  (let* ((buffer-name (codex--buffer-name-for-directory dir instance))
         (prompt-arg (and initial-prompt
                          (not resume-id)
                          (not (eq backend 'app-server))))
         (switches (codex--start-session-switches
                    backend extra-switches resume-id
                    (and prompt-arg initial-prompt)))
         (codex--app-server-pending-startup-action
          (if (and resume-id (eq backend 'app-server))
              'resume-session
            codex--app-server-pending-startup-action))
         (codex--app-server-pending-startup-session-id
          (if (and resume-id (eq backend 'app-server))
              resume-id
            codex--app-server-pending-startup-session-id))
         (buffer (codex--launch-session dir backend buffer-name instance
                                        switches switch-after)))
    (when (and initial-prompt (not prompt-arg))
      (codex--send-command-to-buffer initial-prompt buffer))
    buffer))

(defun codex--start-session-switches (backend extra-switches resume-id
                                              initial-prompt)
  "Return CLI switches for BACKEND, EXTRA-SWITCHES, RESUME-ID, INITIAL-PROMPT."
  (cond
   ((eq backend 'app-server)
    (codex--build-backend-switches 'app-server extra-switches))
   (resume-id
    (append codex-program-switches
            (codex--build-cli-args)
            (list "resume" resume-id)
            extra-switches))
   (t
    (codex--build-backend-switches
     backend
     (append extra-switches
             (when initial-prompt (list initial-prompt)))))))
```

- [ ] **Step 4: Route `codex--start` through the same worker.** Replace the body of `codex--start` (codex.el ~999), keeping its signature and docstring:

```elisp
(defun codex--start (arg extra-switches &optional force-prompt force-switch-to-buffer)
  "Start Codex with given command-line EXTRA-SWITCHES.
ARG is the prefix argument controlling directory and buffer switching.
EXTRA-SWITCHES is a list of additional command-line switches.
If FORCE-PROMPT is non-nil, always prompt for instance name.
If FORCE-SWITCH-TO-BUFFER is non-nil, always switch to the Codex buffer."
  (let* ((dir (if (equal arg '(16))
                  (read-directory-name "Project directory: ")
                (codex--directory)))
         (switch-after (or (equal arg '(4)) force-switch-to-buffer))
         (instance-name (codex--session-instance-name dir force-prompt)))
    (codex--start-session-buffer dir codex-terminal-backend instance-name
                                 extra-switches nil nil switch-after)))
```

- [ ] **Step 5: Add forward declarations.** After the existing `(defvar codex-app-server-program-switches)` at codex.el line 61, add:

```elisp
(defvar codex--app-server-pending-startup-action)
(defvar codex--app-server-pending-startup-session-id)
```

(Both are defined in codex-app-server.el, which codex.el `require`s at the end of the file; the declarations make the `let*` bindings in `codex--start-session-buffer` compile as special bindings.)

- [ ] **Step 6: Verify.**

```bash
cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/codex
trash codex.elc codex-eat.elc codex-vterm.elc 2>/dev/null || true
~/My\ Drive/dotfiles/claude/bin/elisp-ert codex codex-test.el
~/My\ Drive/dotfiles/claude/bin/batch-test.sh codex
```

All tests (existing + 5 new) pass; load check clean. The pre-existing tests `codex-test-start-propagates-font-to-eat-faces` and `codex-test-start-subcommand-includes-cli-options` must still pass — they exercise the refactored `codex--start` and untouched `codex--start-subcommand`.

- [ ] **Step 7: Commit (codex repo).**

```bash
cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/codex
git add codex.el codex-test.el
git commit -m "codex: add parameterized codex-start-session entry point"
```

---

### Task 2.2: `codex-command-submitted-hook` (codex repo)

**Files:**
- Modify `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/codex/codex.el` (defcustom near line 286; `codex--terminal-send-return` ~618; `codex--send-command-to-buffer` ~929; `codex--send-tui-action` ~1447)
- Modify `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/codex/codex-test.el` (append tests)

Submission flows funnel through exactly three chokepoints (verified by reading all backends): `codex--send-command-to-buffer` (all programmatic sends, including `codex--do-send-command`), `codex--terminal-send-return` (interactive Return in eat/vterm/app-server keymaps), and `codex--send-tui-action` with a `:return` action (TUI shortcut table). The eat backend's deferred `codex--schedule-submit-returns` re-enters `codex--terminal-send-return`, so a programmatic submit on eat may run the hook more than once; consumers must be idempotent (the agent consumer is).

- [ ] **Step 1: Write failing tests.** Append to codex-test.el:

```elisp
(ert-deftest codex-test-command-submitted-hook-runs-on-buffer-submit ()
  "Run the submitted hook with the target buffer on programmatic sends."
  (let ((buf (generate-new-buffer "*codex:/tmp/project/*"))
        observed)
    (unwind-protect
        (cl-letf (((symbol-function 'codex--term-submit-command)
                   (lambda (&rest _) nil))
                  ((symbol-function 'get-buffer-window)
                   (lambda (&rest _) nil))
                  ((symbol-function 'display-buffer)
                   (lambda (&rest _) nil)))
          (let ((codex-command-submitted-hook
                 (list (lambda (buffer) (push buffer observed)))))
            (codex--send-command-to-buffer "hello" buf))
          (should (equal observed (list buf))))
      (kill-buffer buf))))

(ert-deftest codex-test-command-submitted-hook-runs-on-return-actions ()
  "Run the submitted hook on Return and :return TUI actions only."
  (with-temp-buffer
    (let (observed)
      (cl-letf (((symbol-function 'codex--term-send-action)
                 (lambda (&rest _) nil)))
        (let ((codex-command-submitted-hook
               (list (lambda (_buffer) (push t observed)))))
          (codex--terminal-send-return)
          (codex--send-tui-action :return)
          (codex--send-tui-action :tab)))
      (should (= (length observed) 2)))))
```

Run; both fail (`void-variable codex-command-submitted-hook`).

- [ ] **Step 2: Define the hook.** Insert after the `codex-start-hook` defcustom (codex.el ~286–290):

```elisp
(defcustom codex-command-submitted-hook nil
  "Abnormal hook run after input is submitted to a Codex session.
Each function is called with one argument, the session buffer, with
that buffer current.  The hook runs for programmatic submissions via
`codex--send-command-to-buffer', for interactive Return presses via
`codex--terminal-send-return', and for `:return' TUI actions.  On the
eat backend a programmatic submission may run the hook more than once
because Return events are also scheduled; hook functions must be
idempotent."
  :type 'hook
  :group 'codex)
```

- [ ] **Step 3: Fire the hook at the three chokepoints.**

Replace `codex--terminal-send-return` (codex.el ~618):

```elisp
(defun codex--terminal-send-return ()
  "Send Return to the current Codex terminal buffer."
  (interactive)
  (codex--run-command-submitted-hook)
  (codex--term-send-action codex-terminal-backend :return))
```

Replace `codex--send-command-to-buffer` (codex.el ~929):

```elisp
(defun codex--send-command-to-buffer (cmd buffer)
  "Send command CMD to Codex BUFFER and submit it."
  (when (buffer-live-p buffer)
    (codex--run-command-submitted-hook buffer)
    (let ((window (or (get-buffer-window buffer)
                      (display-buffer buffer))))
      (if window
          (with-selected-window window
            (with-current-buffer buffer
              (codex--term-submit-command codex-terminal-backend cmd)))
        (with-current-buffer buffer
          (codex--term-submit-command codex-terminal-backend cmd))))
    buffer))
```

Replace `codex--send-tui-action` (codex.el ~1447):

```elisp
(defun codex--send-tui-action (action)
  "Send one TUI ACTION in the current Codex buffer.
ACTION is either a keyword or a list of the form (KEYWORD PAYLOAD)."
  (when (eq (if (listp action) (car action) action) :return)
    (codex--run-command-submitted-hook))
  (if (listp action)
      (codex--term-send-action codex-terminal-backend (car action) (cadr action))
    (codex--term-send-action codex-terminal-backend action)))
```

Add the runner immediately after `codex--send-command-to-buffer` (helpers after callers):

```elisp
(defun codex--run-command-submitted-hook (&optional buffer)
  "Run `codex-command-submitted-hook' for BUFFER or the current buffer."
  (let ((target (or buffer (current-buffer))))
    (when (buffer-live-p target)
      (with-current-buffer target
        (run-hook-with-args 'codex-command-submitted-hook target)))))
```

`codex--terminal-send-return` at line 618 is defined before `codex--run-command-submitted-hook`; this is a same-file forward reference, fine at runtime and compile time.

- [ ] **Step 4: Verify and commit.**

```bash
cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/codex
trash *.elc 2>/dev/null || true
~/My\ Drive/dotfiles/claude/bin/elisp-ert codex codex-test.el
~/My\ Drive/dotfiles/claude/bin/batch-test.sh codex
git add codex.el codex-test.el
git commit -m "codex: add codex-command-submitted-hook"
```

---

### Task 2.3: `codex-prompt-input` — public prompt accessor (codex repo)

**Files:**
- Modify `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/codex/codex-eat.el` (insert after `codex--known-prompt-autosuggestion-p`, ~line 803)
- Modify `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/codex/codex-app-server.el` (insert after `codex--app-server-input-text`, ~line 875)
- Modify `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/codex/codex.el` (public dispatcher + declares)
- Modify `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/codex/codex-test.el` (append tests)

The single glyph regexp in the world remains `codex--prompt-marker-regexp` (`"[›❯>]"`, codex-eat.el:687). Dispatch is content-driven: a live app-server input marker wins; otherwise the terminal prompt line is parsed. This also makes the function behave sensibly in plain buffers (used heavily by agent tests).

- [ ] **Step 1: Write failing tests.** Append to codex-test.el:

```elisp
(ert-deftest codex-test-prompt-input-terminal-pending-text ()
  "Report pending terminal prompt input."
  (let ((buf (generate-new-buffer "*codex:/tmp/project/*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (insert "› fix the failing test\n\n  gpt-5.5 medium · /tmp"))
          (should (equal (codex-prompt-input buf) "fix the failing test")))
      (kill-buffer buf))))

(ert-deftest codex-test-prompt-input-terminal-empty-prompt ()
  "Return nil for an empty terminal prompt."
  (let ((buf (generate-new-buffer "*codex:/tmp/project/*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (insert "› \n\n  gpt-5.5 medium · /tmp"))
          (should-not (codex-prompt-input buf)))
      (kill-buffer buf))))

(ert-deftest codex-test-prompt-input-matches-heavy-and-legacy-glyphs ()
  "Recognize the `❯' and legacy `>' prompt glyphs."
  (let ((buf (generate-new-buffer "*codex:/tmp/project/*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (insert "❯ git status"))
          (should (equal (codex-prompt-input buf) "git status"))
          (with-current-buffer buf
            (erase-buffer)
            (insert "> legacy input"))
          (should (equal (codex-prompt-input buf) "legacy input")))
      (kill-buffer buf))))

(ert-deftest codex-test-prompt-input-ignores-placeholder ()
  "Return nil when the prompt shows placeholder autosuggestion text."
  (let ((buf (generate-new-buffer "*codex:/tmp/project/*")))
    (unwind-protect
        (cl-letf (((symbol-function 'codex--known-prompt-autosuggestion-p)
                   (lambda (input)
                     (string= input "Summarize recent commits"))))
          (with-current-buffer buf
            (insert "› Summarize recent commits"))
          (should-not (codex-prompt-input buf)))
      (kill-buffer buf))))

(ert-deftest codex-test-prompt-input-app-server-input-region ()
  "Report pending app-server input after the input marker."
  (let ((buf (generate-new-buffer "*codex:/tmp/project/*")))
    (unwind-protect
        (with-current-buffer buf
          (insert "› earlier message\n")
          (setq-local codex--app-server-input-marker (copy-marker (point)))
          (insert "queued reply")
          (should (equal (codex-prompt-input buf) "queued reply")))
      (kill-buffer buf))))
```

- [ ] **Step 2: Terminal-side implementation in codex-eat.el.** Insert after `codex--known-prompt-autosuggestion-p` (~line 803), before `codex--prompt-autosuggestion-history`:

```elisp
(defun codex--terminal-prompt-input ()
  "Return pending prompt input in the current terminal buffer, or nil."
  (if-let* ((cursor (codex--terminal-cursor-position)))
      (codex--prompt-input-at-position cursor)
    (codex--last-visible-prompt-input)))

(defun codex--prompt-input-at-position (position)
  "Return meaningful prompt input on the line containing POSITION."
  (save-excursion
    (goto-char position)
    (let* ((line-beg (line-beginning-position))
           (line-end (line-end-position))
           (input-start (codex--prompt-input-start line-beg line-end)))
      (when input-start
        (codex--meaningful-prompt-input
         (buffer-substring-no-properties input-start line-end))))))

(defun codex--last-visible-prompt-input ()
  "Return meaningful input from the last visible prompt line, or nil."
  (save-excursion
    (goto-char (point-max))
    (when (re-search-backward (codex--prompt-line-regexp) nil t)
      (codex--meaningful-prompt-input (match-string-no-properties 1)))))

(defun codex--prompt-line-regexp ()
  "Return a regexp matching a prompt line, capturing its input."
  (format "^[%s]*%s[%s]*\\([^\n]*\\)$"
          codex--prompt-leading-space-chars
          codex--prompt-marker-regexp
          codex--prompt-leading-space-chars))

(defun codex--meaningful-prompt-input (input)
  "Return trimmed INPUT unless it is empty or placeholder text."
  (let ((trimmed (string-trim input)))
    (unless (or (string-empty-p trimmed)
                (codex--known-prompt-autosuggestion-p trimmed))
      trimmed)))
```

- [ ] **Step 3: App-server-side helpers in codex-app-server.el.** Insert after `codex--app-server-input-text` (~line 875), before `codex--app-server-clear-input`:

```elisp
(defun codex--app-server-prompt-input ()
  "Return meaningful pending input in the app-server buffer, or nil."
  (let ((text (string-trim (codex--app-server-input-text))))
    (unless (string-empty-p text)
      text)))

(defun codex--app-server-input-active-p ()
  "Return non-nil when this buffer has a live app-server input region."
  (and (markerp codex--app-server-input-marker)
       (marker-position codex--app-server-input-marker)))
```

- [ ] **Step 4: Public dispatcher in codex.el.** Insert after `codex--run-command-submitted-hook` (added in Task 2.2):

```elisp
(defun codex-prompt-input (&optional buffer)
  "Return pending prompt input text in BUFFER, or nil when empty.
BUFFER defaults to the current buffer.  App-server buffers report the
text after the input marker; terminal buffers parse the prompt line
using `codex--prompt-marker-regexp'.  Placeholder autosuggestion text
counts as empty."
  (let ((target (or buffer (current-buffer))))
    (when (buffer-live-p target)
      (with-current-buffer target
        (if (codex--app-server-input-active-p)
            (codex--app-server-prompt-input)
          (codex--terminal-prompt-input))))))
```

Add declarations after the two `defvar` lines from Task 2.1 Step 5 (codex.el ~line 63):

```elisp
(declare-function codex--app-server-input-active-p "codex-app-server" ())
(declare-function codex--app-server-prompt-input "codex-app-server" ())
(declare-function codex--terminal-prompt-input "codex-eat" ())
```

- [ ] **Step 5: Verify and commit.**

```bash
cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/codex
trash *.elc 2>/dev/null || true
~/My\ Drive/dotfiles/claude/bin/elisp-ert codex codex-test.el
~/My\ Drive/dotfiles/claude/bin/batch-test.sh codex
git add codex.el codex-eat.el codex-app-server.el codex-test.el
git commit -m "codex: add public codex-prompt-input accessor"
```

---

### Task 2.4: `codex-session-identity` — public identity accessor (codex repo)

**Files:**
- Modify `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/codex/codex.el` (insert after `codex-prompt-input`)
- Modify `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/codex/codex-test.el` (append tests)
- Modify `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/codex/README.org` (document the four new public symbols from Tasks 2.1–2.4)

- [ ] **Step 1: Write failing tests.** Append to codex-test.el:

```elisp
(ert-deftest codex-test-session-identity-reads-buffer-locals ()
  "Build session identity from buffer-local state, not name scraping."
  (let ((buf (generate-new-buffer "*codex:/tmp/project/:tests*")))
    (unwind-protect
        (with-current-buffer buf
          (setq-local codex--buffer-directory "/tmp/project/")
          (setq-local codex--buffer-instance-name "tests")
          (setq-local codex-terminal-backend 'eat)
          (cl-letf (((symbol-function 'codex--current-session-identity)
                     (lambda () '(:id "abc123" :transcript-file nil))))
            (should (equal (codex-session-identity buf)
                           '(:directory "/tmp/project/"
                             :instance "tests"
                             :session-id "abc123"
                             :terminal-backend eat)))))
      (kill-buffer buf))))

(ert-deftest codex-test-session-identity-nil-session-id-allowed ()
  "Report identity with a nil session id before the id is known."
  (let ((buf (generate-new-buffer "*codex:/tmp/project/:tests*")))
    (unwind-protect
        (with-current-buffer buf
          (cl-letf (((symbol-function 'codex--current-session-identity)
                     (lambda () nil)))
            (should-not (plist-get (codex-session-identity buf) :session-id))
            (should (equal (plist-get (codex-session-identity buf) :instance)
                           "tests"))))
      (kill-buffer buf))))

(ert-deftest codex-test-session-identity-nil-for-non-codex-buffer ()
  "Return nil for buffers that are not Codex sessions."
  (with-temp-buffer
    (should-not (codex-session-identity (current-buffer)))))
```

- [ ] **Step 2: Implement.** Insert in codex.el immediately after `codex-prompt-input`:

```elisp
(defun codex-session-identity (&optional buffer)
  "Return session identity for BUFFER as a plist, or nil.
BUFFER defaults to the current buffer and must be a Codex session
buffer.  The plist has keys `:directory', `:instance', `:session-id',
and `:terminal-backend'.  `:session-id' is nil until the session id is
known.  Directory and instance come from the buffer-local values set by
`codex--initialize-terminal-buffer', falling back to buffer-name
parsing only when those are unset."
  (let ((target (or buffer (current-buffer))))
    (when (and (buffer-live-p target) (codex--buffer-p target))
      (with-current-buffer target
        (list :directory (codex--buffer-directory-for target)
              :instance (codex--buffer-instance-name-for target)
              :session-id (plist-get (codex--current-session-identity) :id)
              :terminal-backend codex-terminal-backend)))))
```

- [ ] **Step 3: Document the new public API.** In `README.org`, locate the section documenting commands/hooks (search for `codex-start-hook`) and add brief entries for `codex-start-session`, `codex-command-submitted-hook`, `codex-prompt-input`, and `codex-session-identity`, one sentence each, matching the surrounding style.

- [ ] **Step 4: Verify and commit.**

```bash
cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/codex
trash *.elc 2>/dev/null || true
~/My\ Drive/dotfiles/claude/bin/elisp-ert codex codex-test.el
~/My\ Drive/dotfiles/claude/bin/batch-test.sh codex
git add codex.el codex-test.el README.org
git commit -m "codex: add public codex-session-identity accessor"
```

Upstream work is now complete. Everything below is in the **agent repo** and depends on the four codex commits being loadable (they are, since `elisp-ert agent …` puts the codex source dir on `load-path` via the Elpaca builds; if the running Emacs needs the new functions, the agent test harness loads codex from source).

---

### Task 2.5: `agent-start-session` core dispatcher (agent repo)

**Files:**
- Modify `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/agent.el` (insert after `agent--backend-get`)
- Modify `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/test/agent-test.el` (append tests)

- [ ] **Step 1: Write failing tests.** Append to test/agent-test.el:

```elisp
(ert-deftest agent-test-start-session-dispatches-to-backend ()
  "Dispatch session starts to the backend's start-session function."
  (let* ((buffer (generate-new-buffer " *agent-test-session*"))
         (session (agent-session-create :backend 'codex :directory "/tmp/"))
         captured)
    (unwind-protect
        (cl-letf (((symbol-function 'agent--backend-get)
                   (lambda (_backend key)
                     (when (eq key :start-session)
                       (lambda (sess &rest options)
                         (setq captured (cons sess options))
                         buffer)))))
          (should (eq (agent-start-session session :resume-id "abc") buffer))
          (should (eq (car captured) session))
          (should (equal (plist-get (cdr captured) :resume-id) "abc")))
      (kill-buffer buffer))))

(ert-deftest agent-test-start-session-rejects-unsupported-backend ()
  "Signal a user error for backends without start-session support."
  (let ((session (agent-session-create :backend 'codex :directory "/tmp/")))
    (cl-letf (((symbol-function 'agent--backend-get)
               (lambda (_backend _key) nil)))
      (should-error (agent-start-session session) :type 'user-error))))
```

- [ ] **Step 2: Implement.** Insert in agent.el immediately after `agent--backend-get`:

```elisp
(cl-defun agent-start-session (session &rest options
                                       &key initial-prompt resume-id
                                       &allow-other-keys)
  "Start SESSION through its backend's `start-session' function.
SESSION is an `agent-session' whose backend, account, directory, and
instance slots parameterize the new session; nil slots fall back to the
backend's ambient defaults.  INITIAL-PROMPT is submitted as the first
user message.  RESUME-ID resumes that session id instead of starting
fresh.  Remaining OPTIONS are passed through to the backend, which may
support extras such as `:fork' (Claude Code) or `:terminal-backend'
\(Codex).  Return the new session buffer."
  (ignore initial-prompt resume-id)
  (let ((start (agent--backend-get (agent-session-backend session)
                                   :start-session)))
    (unless start
      (user-error "Backend `%s' does not support parameterized session start"
                  (agent-session-backend session)))
    (apply start session options)))
```

If the Phase 1 `agent-backend` struct documents its slots, add to the `start-session` slot doc: "function (session &rest options &key initial-prompt resume-id) -> buffer" and to `session-identity`: "function (buffer) -> agent-session or nil".

- [ ] **Step 3: Verify and commit.**

```bash
cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent
~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-test.el
~/My\ Drive/dotfiles/claude/bin/batch-test.sh agent
git add agent.el test/agent-test.el
git commit -m "agent: add agent-start-session dispatcher"
```

---

### Task 2.6: Claude backend `start-session` and `session-identity` (agent repo)

**Files:**
- Modify `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/agent-claude.el` (new functions after `agent-claude-buffer-account`, ~line 1376; registration form at ~line 233–265)
- Modify `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/test/agent-claude-test.el` (append test)

- [ ] **Step 1: Write failing test.** Append to test/agent-claude-test.el:

```elisp
(ert-deftest agent-claude-test-start-session-injects-parameters ()
  "Route directory, instance, account, and switches through the wrapper."
  (let ((buffer (generate-new-buffer " *claude-test-session*"))
        captured-dir captured-instance captured-switches captured-account)
    (unwind-protect
        (cl-letf (((symbol-function 'agent-claude--resolve-account)
                   (lambda () nil))
                  ((symbol-function 'claude-code--start)
                   (lambda (_arg switches &optional _force-prompt _force-switch)
                     (setq captured-dir (claude-code--directory))
                     (setq captured-instance
                           (claude-code--prompt-for-instance-name
                            "/elsewhere/" nil))
                     (setq captured-switches switches)
                     (setq captured-account agent-claude--pending-account)
                     buffer)))
          (let ((session (agent-session-create
                          :backend 'claude-code
                          :account "work"
                          :directory "/tmp/project/"
                          :instance "fix")))
            (should (eq (agent-claude--start-session
                         session :resume-id "abc" :fork t
                         :initial-prompt "continue")
                        buffer))
            (should (equal captured-dir "/tmp/project/"))
            (should (equal captured-instance "fix"))
            (should (equal captured-switches
                           '("--resume" "abc" "--fork-session" "continue")))
            (should (equal captured-account "work"))
            (should (eq (agent-session buffer) session))))
      (kill-buffer buffer))))
```

- [ ] **Step 2: Implement.** Insert in agent-claude.el after `agent-claude-buffer-account` (the defun ending at ~line 1376):

```elisp
;;;;; Parameterized session start

(cl-defun agent-claude--start-session (session &key initial-prompt resume-id
                                               fork)
  "Start the Claude Code session described by SESSION; return its buffer.
SESSION is an `agent-session'.  INITIAL-PROMPT is passed to the Claude
CLI as the opening user message.  RESUME-ID resumes that session id.
FORK non-nil adds `--fork-session' to a resume.  The session account
\(or the resolved active account) is bound as the pending account so
`agent-claude-account-env' sees it."
  (let* ((agent-claude--pending-account
          (or (agent-session-account session)
              (agent-claude--resolve-account)))
         (switches (append (when resume-id (list "--resume" resume-id))
                           (when fork (list "--fork-session"))
                           (when initial-prompt (list initial-prompt))))
         (buffer (agent-claude--start-with-overrides
                  (agent-session-directory session)
                  (agent-session-instance session)
                  switches)))
    (agent--set-session buffer session)
    buffer))

(defun agent-claude--start-with-overrides (dir instance switches)
  "Run `claude-code--start' with DIR and INSTANCE injected.
SWITCHES are extra CLI switches.  A nil DIR or INSTANCE keeps the
upstream ambient behavior for that value.  This is the ONLY place that
rebinds the private `claude-code--directory' and
`claude-code--prompt-for-instance-name'; never add new `cl-letf' calls
against claude-code.el elsewhere."
  (let ((orig-directory (symbol-function 'claude-code--directory))
        (orig-prompt (symbol-function 'claude-code--prompt-for-instance-name)))
    (cl-letf (((symbol-function 'claude-code--directory)
               (lambda () (or dir (funcall orig-directory))))
              ((symbol-function 'claude-code--prompt-for-instance-name)
               (lambda (prompt-dir existing &optional force-prompt)
                 (or instance
                     (funcall orig-prompt prompt-dir existing force-prompt)))))
      (claude-code--start nil switches nil t))))

(defun agent-claude--session-identity (buffer)
  "Return BUFFER's session identity as an `agent-session', or nil."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (agent-session-create
       :backend 'claude-code
       :account agent-claude--buffer-account
       :directory (claude-code--extract-directory-from-buffer-name
                   (buffer-name))
       :instance (claude-code--extract-instance-name-from-buffer-name
                  (buffer-name))
       :id (plist-get (agent-claude--parse-status-file) :session_id)))))
```

Ensure these declarations exist near the other `declare-function` forms (~line 210); add any that are missing:

```elisp
(declare-function claude-code--directory "claude-code" ())
(declare-function claude-code--prompt-for-instance-name
                  "claude-code" (dir existing-instance-names &optional force-prompt))
```

- [ ] **Step 3: Register the slots.** In the `agent-register-backend 'claude-code` form (~line 233), after the line `:restart #'agent-claude-restart`, add:

```elisp
        :start-session #'agent-claude--start-session
        :session-identity #'agent-claude--session-identity
```

(The form may be plist-style or keyword-arg style depending on Phase 1's final shape; either way, add the two keyword/value pairs in the same style as the surrounding entries.)

- [ ] **Step 4: Verify and commit.**

```bash
cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent
~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-claude-test.el
~/My\ Drive/dotfiles/claude/bin/batch-test.sh agent
git add agent-claude.el test/agent-claude-test.el
git commit -m "agent-claude: add parameterized start-session backend"
```

---

### Task 2.7: Codex backend `start-session` and `session-identity` (agent repo)

**Files:**
- Modify `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/agent-codex.el` (declares ~line 176–179; new functions after `agent-codex-buffer-account`, ~line 523; registration form ~line 215–249)
- Modify `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/test/agent-codex-test.el` (append test)

- [ ] **Step 1: Write failing test.** Append to test/agent-codex-test.el:

```elisp
(ert-deftest agent-codex-test-start-session-binds-account-and-records-session ()
  "Bind the pending account and attach the session to the new buffer."
  (let ((buffer (generate-new-buffer " *codex-test-session*"))
        captured)
    (unwind-protect
        (cl-letf (((symbol-function 'agent-codex--install-hooks) #'ignore)
                  ((symbol-function 'agent-codex--resolve-account)
                   (lambda () nil))
                  ((symbol-function 'codex-start-session)
                   (lambda (&rest keys)
                     (setq captured
                           (append keys
                                   (list :account
                                         agent-codex--pending-account)))
                     buffer)))
          (let ((session (agent-session-create
                          :backend 'codex
                          :account "work"
                          :directory "/tmp/project/"
                          :instance "fix")))
            (should (eq (agent-codex--start-session session :resume-id "abc")
                        buffer))
            (should (equal (plist-get captured :directory) "/tmp/project/"))
            (should (equal (plist-get captured :instance-name) "fix"))
            (should (equal (plist-get captured :resume-id) "abc"))
            (should (equal (plist-get captured :account) "work"))
            (should (eq (agent-session buffer) session))))
      (kill-buffer buffer))))
```

- [ ] **Step 2: Implement.** Insert in agent-codex.el after `agent-codex-buffer-account` (defun ending ~line 523):

```elisp
;;;;; Parameterized session start

(cl-defun agent-codex--start-session (session &key initial-prompt resume-id
                                              terminal-backend)
  "Start the Codex session described by SESSION; return its buffer.
SESSION is an `agent-session'.  INITIAL-PROMPT is submitted as the
first user message.  RESUME-ID resumes that session id.
TERMINAL-BACKEND overrides `codex-terminal-backend' for this session.
The session account (or the resolved active account) is bound as the
pending account so `agent-codex-account-env' sees it."
  (agent-codex--install-hooks)
  (let* ((agent-codex--pending-account
          (or (agent-session-account session)
              (agent-codex--resolve-account)))
         (buffer (codex-start-session
                  :directory (agent-session-directory session)
                  :instance-name (agent-session-instance session)
                  :initial-prompt initial-prompt
                  :resume-id resume-id
                  :terminal-backend terminal-backend)))
    (agent--set-session buffer session)
    buffer))

(defun agent-codex--session-identity (buffer)
  "Return BUFFER's session identity as an `agent-session', or nil."
  (when-let* ((identity (codex-session-identity buffer)))
    (agent-session-create
     :backend 'codex
     :account (buffer-local-value 'agent-codex--buffer-account buffer)
     :directory (plist-get identity :directory)
     :instance (plist-get identity :instance)
     :id (plist-get identity :session-id))))
```

Add declarations next to the existing ones at ~line 176–179:

```elisp
(declare-function codex-start-session "codex")
(declare-function codex-session-identity "codex" (&optional buffer))
(declare-function codex-prompt-input "codex" (&optional buffer))
```

- [ ] **Step 3: Register the slots.** In the `agent-register-backend 'codex` form (~line 215), after the line `:restart #'agent-codex-restart`, add:

```elisp
        :start-session #'agent-codex--start-session
        :session-identity #'agent-codex--session-identity
```

- [ ] **Step 4: Verify and commit.**

```bash
cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent
~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-codex-test.el
~/My\ Drive/dotfiles/claude/bin/batch-test.sh agent
git add agent-codex.el test/agent-codex-test.el
git commit -m "agent-codex: add parameterized start-session backend"
```

---

### Reference: the 12 `cl-letf` sites and their session parameters

| # | File:line | Function | `agent-session-create` args | Extra keys |
|---|---|---|---|---|
| 1 | agent-claude.el:2551 | `agent-claude--debug-start-session` | `:backend 'claude-code :directory dir` | `:initial-prompt prompt` |
| 2 | agent-claude.el:2575 | `agent-claude--act-on-slack-message-start-session` | `:backend 'claude-code :directory dir` | — (send URL after) |
| 3 | agent-claude.el:2625 | `agent-claude-handoff` | `:backend 'claude-code :directory dir` | `:initial-prompt prompt` |
| 4 | agent-claude.el:2683 | `agent-claude-restart` | `:backend 'claude-code :account account :directory dir :instance instance-name` | `:resume-id session-id` |
| 5 | agent-claude.el:2987 | `agent-claude--resume-session` | `:backend 'claude-code :directory default-directory :instance "branch-…"` | `:resume-id session-id` |
| 6 | agent-claude.el:2997 | `agent-claude-create-branch` | `:backend 'claude-code :directory (or worktree default-directory) :instance "fork-…"` | `:resume-id session-id :fork t` |
| 7 | agent-codex.el:1176 | `agent-codex--debug-start-session` | `:backend 'codex :directory dir` | `:initial-prompt prompt` |
| 8 | agent-codex.el:1199 | `agent-codex--act-on-slack-message-start-session` | `:backend 'codex :directory dir` | — (send URL after) |
| 9 | agent-codex.el:1219 | `agent-codex-handoff` | `:backend 'codex :account account :directory dir` | `:initial-prompt prompt` |
| 10 | agent-codex.el:1300 | `agent-codex-restart` | `:backend 'codex :account account :directory (plist-get identity :directory) :instance (plist-get identity :instance)` | `:resume-id … :terminal-backend …` |
| 11 | agent-chief.el:380 | `agent-chief--call-codex-start` | collapsed into `agent-chief--call-backend-start` | — |
| 12 | agent-chief.el:391 | `agent-chief--call-claude-start` | collapsed into `agent-chief--call-backend-start` | — |

---

### Task 2.8: Migrate the six Claude sites (agent repo)

**Files:**
- Modify `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/agent-claude.el` (sites 1–6 above)

After this task, `grep -n "cl-letf" agent-claude.el` must return nothing.

- [ ] **Step 1: Worked pattern — site 1 (`agent-claude--debug-start-session`, ~2551).** Replace the whole function with:

```elisp
(defun agent-claude--debug-start-session (package backtrace-file)
  "Start a Claude Code session for PACKAGE with BACKTRACE-FILE.
Find the elpaca source directory for PACKAGE, start Claude Code
there with the backtrace prompt passed as a CLI argument."
  (let* ((dir (or (agent--package-source-directory package)
                  (user-error "Package `%s' not found" package)))
         (prompt (format "Read the backtrace at %s. Identify the bug, fix it, and commit the fix."
                         backtrace-file)))
    (message "Starting Claude Code for `%s' in %s..." package dir)
    (agent-start-session
     (agent-session-create :backend 'claude-code :directory dir)
     :initial-prompt prompt)))
```

Keep the `(declare-function claude-code--start "claude-code")` line above it (still used by the Task 2.6 wrapper, which lives in this file).

- [ ] **Step 2: Site 2 (`agent-claude--act-on-slack-message-start-session`, ~2575).** Replace with:

```elisp
(defun agent-claude--act-on-slack-message-start-session (project slack-url)
  "Start a Claude Code session for PROJECT with SLACK-URL."
  (let ((dir (file-name-as-directory
              (expand-file-name (plist-get project :directory)))))
    (message "Starting Claude Code for `%s' in %s..."
             (plist-get project :id) dir)
    (let ((buffer (agent-start-session
                   (agent-session-create :backend 'claude-code
                                         :directory dir))))
      (agent-claude-send-command slack-url buffer))))
```

- [ ] **Step 3: Site 3 (`agent-claude-handoff`, ~2625).** Replace only the final `cl-letf` form (the last two lines of the function):

```elisp
    (cl-letf (((symbol-function 'claude-code--directory) (lambda () dir)))
      (claude-code--start nil (list prompt) nil t))))
```

with:

```elisp
    (agent-start-session
     (agent-session-create :backend 'claude-code :directory dir)
     :initial-prompt prompt)))
```

- [ ] **Step 4: Site 4 (`agent-claude-restart`, ~2683).** Replace the whole function with:

```elisp
;;;###autoload
(defun agent-claude-restart ()
  "Kill the current Claude session and resume it in place.
Useful when a setting change requires relaunching Claude.  Preserves the
session's directory and instance name, and uses the currently active
account (from `agent-claude-accounts'), so the result is
equivalent to manually closing the session and reopening it."
  (interactive)
  (unless (claude-code--buffer-p (current-buffer))
    (user-error "Not in a Claude buffer"))
  (let* ((account (agent-claude--resolve-account))
         (session-id (agent-claude--current-session-id))
         (dir default-directory)
         (instance-name (claude-code--extract-instance-name-from-buffer-name
                         (buffer-name))))
    (when account
      (agent-claude--sync-account-config account))
    (agent--force-kill-buffer (current-buffer))
    (agent-start-session
     (agent-session-create :backend 'claude-code
                           :account account
                           :directory dir
                           :instance instance-name)
     :resume-id session-id)))
```

- [ ] **Step 5: Site 5 (`agent-claude--resume-session`, ~2987).** Replace with:

```elisp
(defun agent-claude--resume-session (session-id)
  "Resume SESSION-ID in a new Claude buffer.
Auto-generates an instance name from the session ID to avoid the
interactive instance-name prompt."
  (agent-start-session
   (agent-session-create
    :backend 'claude-code
    :directory default-directory
    :instance (format "branch-%s" (substring session-id 0 8)))
   :resume-id session-id))
```

(Directory is now the calling Claude buffer's `default-directory` instead of whatever ambient `claude-code--directory` would compute; for a Claude session buffer these are the same directory the session was started in.)

- [ ] **Step 6: Site 6 (`agent-claude-create-branch`, ~2997).** Replace only this form inside the function:

```elisp
    (cl-letf (((symbol-function 'claude-code--prompt-for-instance-name)
               (lambda (_dir _existing _force)
                 (format "fork-%s" fork-id))))
      (let ((default-directory (or (car worktree) default-directory)))
        (claude-code--start nil
                            (list "--resume" session-id "--fork-session")
                            nil t)))
```

with:

```elisp
    (agent-start-session
     (agent-session-create
      :backend 'claude-code
      :directory (or (car worktree) default-directory)
      :instance (format "fork-%s" fork-id))
     :resume-id session-id
     :fork t)
```

- [ ] **Step 7: Verify and commit.**

```bash
cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent
grep -n "cl-letf" agent-claude.el          # expect no output
~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-claude-test.el
~/My\ Drive/dotfiles/claude/bin/batch-test.sh agent
git add agent-claude.el
git commit -m "agent-claude: route session starts through agent-start-session"
```

---

### Task 2.9: Migrate the four Codex sites and update their tests (agent repo)

**Files:**
- Modify `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/agent-codex.el` (sites 7–10; delete `agent-codex--resume-session` ~1323–1327; declare cleanup ~177)
- Modify `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/test/agent-codex-test.el` (restart suite ~156–330, handoff test ~332, slack test ~441)

After this task, `grep -n "cl-letf.*codex--directory\|codex--start\b" agent-codex.el` must return nothing.

- [ ] **Step 1: Worked pattern — site 7 (`agent-codex--debug-start-session`, ~1176).** Replace with:

```elisp
(defun agent-codex--debug-start-session (package backtrace-file)
  "Start a Codex session for PACKAGE with BACKTRACE-FILE."
  (let* ((dir (or (agent--package-source-directory package)
                  (user-error "Package `%s' not found" package)))
         (prompt (format "Read the backtrace at %s. Identify the bug, fix it, and commit the fix."
                         backtrace-file)))
    (message "Starting Codex for `%s' in %s..." package dir)
    (agent-start-session
     (agent-session-create :backend 'codex :directory dir)
     :initial-prompt prompt)))
```

(`agent-codex--install-hooks` is no longer called here; `agent-codex--start-session` does it.)

- [ ] **Step 2: Site 8 (`agent-codex--act-on-slack-message-start-session`, ~1199).** Replace with:

```elisp
(defun agent-codex--act-on-slack-message-start-session (project slack-url)
  "Start a Codex session for PROJECT with SLACK-URL."
  (let ((dir (file-name-as-directory
              (expand-file-name (plist-get project :directory)))))
    (message "Starting Codex for `%s' in %s..."
             (plist-get project :id) dir)
    (let ((buffer (agent-start-session
                   (agent-session-create :backend 'codex :directory dir))))
      (agent-codex-send-command slack-url buffer))))
```

- [ ] **Step 3: Site 9 (`agent-codex-handoff`, ~1219).** Replace only the tail of the function, from `(agent-codex--kill-handoff-source source-buffer dir)` to the end:

```elisp
    (agent-codex--kill-handoff-source source-buffer dir)
    (let ((agent-codex--pending-account
           (or account (agent-codex--resolve-account))))
      (agent-codex--install-hooks)
      (cl-letf (((symbol-function 'codex--directory) (lambda () dir)))
        (codex--start nil (list prompt) nil t)))))
```

becomes:

```elisp
    (agent-codex--kill-handoff-source source-buffer dir)
    (agent-start-session
     (agent-session-create :backend 'codex :account account :directory dir)
     :initial-prompt prompt)))
```

- [ ] **Step 4: Site 10 (`agent-codex-restart`, ~1300) and delete `agent-codex--resume-session`.** Replace the whole `agent-codex-restart` with:

```elisp
;;;###autoload
(defun agent-codex-restart ()
  "Kill the current Codex session and resume it in place.
Useful when a setting change requires relaunching Codex.  Preserves the
session's directory, instance name, and terminal backend.  If the
active account differs from the session account, prompt for which
account to use."
  (interactive)
  (unless (codex--buffer-p (current-buffer))
    (user-error "Not in a Codex buffer"))
  (let* ((identity (codex-session-identity))
         (session-id (or (plist-get identity :session-id)
                         (user-error "Current Codex buffer has no session id")))
         (account (agent-codex--restart-account agent-codex--buffer-account))
         (session (agent-session-create
                   :backend 'codex
                   :account account
                   :directory (plist-get identity :directory)
                   :instance (plist-get identity :instance))))
    (agent--force-kill-buffer (current-buffer))
    (agent-start-session session
                         :resume-id session-id
                         :terminal-backend
                         (plist-get identity :terminal-backend))))
```

Delete the now-unused `agent-codex--resume-session` (the defun immediately following restart, ~1323–1327). Remove the now-unused declaration at ~line 177:

```elisp
(declare-function codex--current-session-identity "codex" ())
```

- [ ] **Step 5: Rewrite the affected tests.** In test/agent-codex-test.el, the six restart tests, the handoff test, and the slack test stub the old private entry points. Rewrite them to stub `codex-start-session` instead. The worked rewrite for the first one:

```elisp
(ert-deftest agent-codex-test-restart-preserves-buffer-account ()
  "Restart Codex with the account attached to the current session."
  (let ((dir (make-temp-file "codex-restart" t))
        captured-account)
    (unwind-protect
        (with-temp-buffer
          (rename-buffer "*codex:~/project/:default*" t)
          (setq-local codex--session-id "019ea295-c3df-70b0-a8e5-a8ffe9df220a")
          (setq-local agent-codex--buffer-account "work")
          (let ((agent-codex-accounts
                 `(("work" . ,(expand-file-name "work" dir))))
                (agent-codex--current-account nil)
                (agent-codex-account-file (expand-file-name "current" dir)))
            (cl-letf (((symbol-function 'codex--buffer-p) (lambda (_buffer) t))
                      ((symbol-function 'agent--force-kill-buffer) #'ignore)
                      ((symbol-function 'agent-codex--install-hooks) #'ignore)
                      ((symbol-function 'agent-codex--resolve-account)
                       (lambda () (error "should not resolve active account")))
                      ((symbol-function 'codex-start-session)
                       (lambda (&rest _keys)
                         (setq captured-account agent-codex--pending-account)
                         (generate-new-buffer " *codex-restart-target*"))))
              (kill-buffer (agent-codex-restart)))))
      (delete-directory dir t))
    (should (equal captured-account "work"))))
```

Apply the same mechanical changes to the remaining tests:

| Test (current name) | Change |
|---|---|
| `agent-codex-test-restart-prompts-when-active-account-differs` | Replace the `codex--app-server-launch-resume-session` stub with a `codex-start-session` stub `(lambda (&rest keys) (setq captured-account agent-codex--pending-account) (setq captured-session-id (plist-get keys :resume-id)) (generate-new-buffer " *codex-restart-target*"))`; add `agent-codex--install-hooks` → `#'ignore` stub; drop the `codex--directory` stub; wrap the call as `(kill-buffer (agent-codex-restart))`. Assertions unchanged. |
| `agent-codex-test-restart-fails-when-active-account-is-missing` | Replace the launch stub with `codex-start-session` → `(lambda (&rest _args) (setq started t) (generate-new-buffer " *codex-restart-target*"))`. Assertions unchanged. |
| `agent-codex-test-restart-resumes-current-session-id-with-app-server` | Rename to `agent-codex-test-restart-resumes-current-session-id`. Stub `codex-start-session` capturing `(plist-get keys :resume-id)` and `(plist-get keys :instance-name)`; add `agent-codex--install-hooks` stub; drop `codex--directory` stub; `(kill-buffer (agent-codex-restart))`. Assertions unchanged (id and `"default"`). |
| `agent-codex-test-restart-uses-codex-session-identity` | Keep the `codex--current-session-identity` stub (the new path reaches it through `codex-session-identity`); replace the launch stub with a `codex-start-session` stub capturing `:resume-id`; add install-hooks stub; `(kill-buffer (agent-codex-restart))`. Assertion unchanged. |
| `agent-codex-test-restart-without-session-identity-does-not-kill` | Replace the launch stub with a `codex-start-session` stub setting `started`. Assertions unchanged. |
| `agent-codex-test-restart-uses-default-backend-option` | Replace entirely (behavior change #1) with: |

```elisp
(ert-deftest agent-codex-test-restart-uses-session-backend ()
  "Restart preserves the session's buffer-local terminal backend."
  (let (captured-backend)
    (with-temp-buffer
      (rename-buffer "*codex:~/project/:default*" t)
      (setq-local codex-terminal-backend 'eat)
      (setq-local codex--session-id "019ea295-c3df-70b0-a8e5-a8ffe9df220a")
      (cl-letf (((symbol-function 'codex--buffer-p) (lambda (_buffer) t))
                ((symbol-function 'agent--force-kill-buffer) #'ignore)
                ((symbol-function 'agent-codex--install-hooks) #'ignore)
                ((symbol-function 'agent-codex--resolve-account)
                 (lambda () nil))
                ((symbol-function 'codex-start-session)
                 (lambda (&rest keys)
                   (setq captured-backend
                         (plist-get keys :terminal-backend))
                   (generate-new-buffer " *codex-restart-target*"))))
        (kill-buffer (agent-codex-restart))))
    (should (eq captured-backend 'eat))))
```

| Test | Change |
|---|---|
| `agent-codex-test-handoff-kills-single-existing-buffer-when-source-missing` | Replace the `codex--start` stub with `((symbol-function 'codex-start-session) (lambda (&rest _args) (setq started t) (generate-new-buffer " *codex-handoff-target*")))` and change the call to `(kill-buffer (agent-codex-handoff))`. Other stubs and assertions unchanged. |
| `agent-codex-test-act-on-slack-message-inserts-url-for-review` | Replace the `codex--start` stub with `((symbol-function 'codex-start-session) (lambda (&rest keys) (setq started keys) buffer))`; drop the `launch-directory` capture and its assertion; assert `(should (equal (plist-get started :directory) "/tmp/project/"))` and `(should-not (plist-get started :initial-prompt))`; keep the `agent-codex-send-command` stub and the return-value assertion. |

- [ ] **Step 6: Verify and commit.**

```bash
cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent
grep -n "cl-letf" agent-codex.el            # expect no output
grep -n "codex--start\b" agent-codex.el     # expect only the :start registry line, if any
~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-codex-test.el
~/My\ Drive/dotfiles/claude/bin/batch-test.sh agent
git add agent-codex.el test/agent-codex-test.el
git commit -m "agent-codex: route session starts through agent-start-session"
```

---

### Task 2.10: Collapse `agent-chief--call-backend-start` (agent repo)

**Files:**
- Modify `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/agent-chief.el` (lines 374–400; declares at lines 41–46)

- [ ] **Step 1: Replace the three functions** `agent-chief--call-backend-start`, `agent-chief--call-codex-start`, and `agent-chief--call-claude-start` (lines 374–400) with one body, no `pcase`:

```elisp
(defun agent-chief--call-backend-start ()
  "Start a backend session in `agent-chief-directory' with chief instance."
  (agent-start-session
   (agent-session-create
    :backend agent-chief-backend
    :directory (file-name-as-directory
                (file-truename
                 (expand-file-name agent-chief-directory)))
    :instance agent-chief-session-instance-name)))
```

- [ ] **Step 2: Remove the dead declarations** at lines 41–46:

```elisp
(declare-function claude-code--directory "claude-code" ())
(declare-function claude-code--prompt-for-instance-name
                  "claude-code" (dir existing-instance-names &optional force-prompt))
(declare-function codex--directory "codex" ())
(declare-function codex--prompt-for-instance-name
                  "codex" (dir existing-instance-names &optional force-prompt))
```

- [ ] **Step 3: Verify and commit.**

```bash
cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent
grep -n "cl-letf" agent-chief.el            # expect no output
~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-chief-test.el
~/My\ Drive/dotfiles/claude/bin/batch-test.sh agent
git add agent-chief.el
git commit -m "agent-chief: start chief sessions through agent-start-session"
```

---

### Task 2.11: Use upstream `codex-prompt-input` and `codex-command-submitted-hook` (agent repo)

**Files:**
- Modify `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/agent-codex.el` (prompt-input family lines 276–320; declare line 178; advice block lines 1408–1434)
- Modify `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/test/agent-codex-test.el` (one test rewritten)

- [ ] **Step 1: Replace the prompt-input family.** Replace `agent-codex-before-exit-ready-to-close-p` and delete the six private helpers (`agent-codex--current-prompt-input`, `agent-codex--prompt-input-at-cursor`, `agent-codex--last-prompt-input`, `agent-codex--prompt-input-on-current-line`, `agent-codex--nonempty-prompt-input`, `agent-codex--prompt-autosuggestion-p`, lines 282–320). The whole region from line 276 to 320 becomes:

```elisp
(defun agent-codex-before-exit-ready-to-close-p (&optional buffer)
  "Return non-nil when BUFFER has no pending Codex prompt input."
  (when-let* ((codex-buffer (agent-codex--target-buffer buffer)))
    (not (codex-prompt-input codex-buffer))))
```

Delete the declaration at line 178:

```elisp
(declare-function codex--terminal-cursor-position "codex" ())
```

(`codex-prompt-input` was declared in Task 2.7.) The existing before-exit tests (`agent-codex-test-before-exit-ready-*`, ~lines 472–530) continue to pass unmodified: they exercise the same glyph parsing, now via upstream's single regexp, and their `codex--terminal-cursor-position` / `codex--known-prompt-autosuggestion-p` stubs are still on the call path.

- [ ] **Step 2: Replace the four submission advices with one hook function.** In `agent-codex--install-hooks` (lines 1389–1423), replace this block:

```elisp
  (unless (advice-member-p #'agent--clear-waiting-for-input
                           'codex--do-send-command)
    (advice-add 'codex--do-send-command :before
                #'agent--clear-waiting-for-input))
  (unless (advice-member-p #'agent-codex--clear-waiting-before-send-command-to-buffer
                           'codex--send-command-to-buffer)
    (advice-add 'codex--send-command-to-buffer :before
                #'agent-codex--clear-waiting-before-send-command-to-buffer))
  (unless (advice-member-p #'agent--clear-waiting-for-input
                           'codex--terminal-send-return)
    (advice-add 'codex--terminal-send-return :before
                #'agent--clear-waiting-for-input))
  (unless (advice-member-p #'agent-codex--clear-waiting-before-tui-action
                           'codex--send-tui-action)
    (advice-add 'codex--send-tui-action :before
                #'agent-codex--clear-waiting-before-tui-action)))
```

with:

```elisp
  (add-hook 'codex-command-submitted-hook #'agent-codex--on-command-submitted))
```

Then replace the two now-obsolete helper functions immediately below (`agent-codex--clear-waiting-before-send-command-to-buffer` and `agent-codex--clear-waiting-before-tui-action`, lines 1425–1434) with:

```elisp
(defun agent-codex--on-command-submitted (buffer)
  "Clear stale waiting state after input is submitted in BUFFER."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (agent--clear-waiting-for-input))))
```

Keep the trailing `(agent-codex--install-hooks)` top-level call (line 1436) as is. Phase 3 owns richer state-machine behavior; this stays mechanical.

- [ ] **Step 3: Rewrite the one test that called a deleted helper.** Replace `agent-codex-test-target-buffer-submit-clears-waiting-flag` (test/agent-codex-test.el ~line 431) with:

```elisp
(ert-deftest agent-codex-test-on-command-submitted-clears-waiting-flag ()
  "Clear stale waiting state in the buffer that received a submission."
  (with-temp-buffer
    (let ((buf (current-buffer)))
      (setq-local agent--waiting-for-input (current-time))
      (agent-codex--on-command-submitted buf)
      (should-not agent--waiting-for-input))))

(ert-deftest agent-codex-test-install-hooks-registers-submitted-hook ()
  "Register the waiting-state consumer on the upstream submitted hook."
  (agent-codex--install-hooks)
  (should (memq #'agent-codex--on-command-submitted
                codex-command-submitted-hook)))
```

- [ ] **Step 4: Verify end-to-end and commit.**

```bash
cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent
grep -n "›\|❯" agent-codex.el               # expect no output: zero private glyph regexps remain
grep -rn "advice-add 'codex--" agent-codex.el   # expect no output
~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-codex-test.el
~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-claude-test.el
~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-test.el
~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-chief-test.el
~/My\ Drive/dotfiles/claude/bin/batch-test.sh agent
~/My\ Drive/dotfiles/claude/bin/batch-test.sh codex
git add agent-codex.el test/agent-codex-test.el
git commit -m "agent-codex: use upstream prompt input and submitted hook"
```

- [ ] **Step 5: Update the agent README.** In `~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/README.org`, find the backend-registry documentation (search for `:restart`) and add one-line descriptions of the `:start-session` and `:session-identity` slots and of `agent-start-session`. Commit as `agent: document start-session backend slots` in the agent repo.

---

### Phase 2 exit criteria

1. `grep -rn "cl-letf" agent.el agent-claude.el agent-codex.el agent-chief.el` in the agent repo returns **zero** hits outside `agent-claude--start-with-overrides` (the single sanctioned claude-code.el wrapper).
2. `grep -rn "codex--directory\|codex--prompt-for-instance-name\|codex--start\b\|codex--start-subcommand\|codex--app-server-launch-resume-session\|codex--current-session-identity" agent-codex.el agent-chief.el` returns at most the registry `:start #'codex--start` legacy entry (untouched in this phase).
3. Both ERT suites pass; both `batch-test.sh` load checks pass.
4. Not verified end-to-end in this plan: live session starts against the real `codex`/`claude` CLIs (restart, handoff, branch fork) — the executing agent should note this in its final report and, if a live Emacs session is available, smoke-test `agent-codex-restart` and `agent-claude-handoff` in a scratch project before declaring Phase 2 done.

## Phase 3 — Event-driven session state machine

**Repo:** `/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/`
**Prerequisites (from Phases 1–2, assumed merged):** `agent-session` struct + `agent--session`; struct-based registry with keyword `agent-register-backend` and the `agent--backend-get` keyword shim; `codex.el` provides `codex-command-submitted-hook` (run with the session buffer on every submission path) and `codex-prompt-input (&optional buffer)`; agent-codex's four submission advices are already collapsed into one function on `codex-command-submitted-hook` whose body currently calls `agent--clear-waiting-for-input`.

**Line-number caveat:** all line numbers below were taken before Phases 1–2 landed and may have drifted. Treat them as anchors; always relocate the quoted code with the given `grep` command before editing. Quoted "current code" blocks are verbatim as of plan writing; if an exact-match edit fails, re-read the surrounding region — the logic will be unchanged even if lines moved.

**Verification commands (used throughout; run from the repo root):**

```bash
cd "/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent"
~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-test.el            # core suite
~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-claude-test.el
~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-codex-test.el
~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-chief-test.el
~/My\ Drive/dotfiles/claude/bin/batch-test.sh agent                           # load check
```

Expected output for a passing suite: ERT batch output ending `Ran N tests, N results as expected` and exit code 0. The load check must print no `Cannot open load file` / void-symbol errors and exit 0.

**Behavior notes locked for this phase (intentional, do not "fix"):**

- Claude sessions now enter `awaiting-input` on CLI Stop (today the flag is set only on `idle_prompt`). This is the intended improvement.
- Codex's CLI `"Stop"` hook event is translated to the core `idle-prompt` event, because for Codex it means "back at the prompt"; this is what preserves Codex's ready alert. Claude's CLI Stop maps to core `stop` (no alert), and claude's `idle_prompt` maps to `idle-prompt` (alert) — exactly today's alert behavior.
- Claude's ready-alert title changes from `"Claude ready"` to `"Claude Code ready"` (title is now derived from the backend label). Accepted wording change.
- The codex amber feature (app-server session active but accepting steering input shows as background-waiting in the switcher) must keep working; Task 3.5 has a dedicated test for it.

### Task 3.1: Core state machine — `agent-session-event` (tests first)

**Files:**
- `/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/agent.el` (vars near line 390; new section after `agent--clear-waiting-for-input`, lines 816–819; `agent-exit` at lines 1989–2000)
- `/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/test/agent-test.el` (append new section at end, before any final comment)

- [ ] Step 1 — add the tests. Append this section to `test/agent-test.el`:

```elisp
;;;; Session state machine

(ert-deftest agent-test-session-event-stop-marks-awaiting-input ()
  "Transition sessions to awaiting-input on stop events."
  (let ((agent-backends nil)
        (agent-alert-on-ready nil))
    (with-temp-buffer
      (agent-session-event (current-buffer) 'stop)
      (should (eq agent--session-state 'awaiting-input))
      (should (floatp agent--session-state-changed-at)))))

(ert-deftest agent-test-session-event-idle-prompt-alerts ()
  "Fire the ready alert on idle-prompt events."
  (let ((agent-backends nil)
        notified)
    (with-temp-buffer
      (rename-buffer "*one:~/repo/project/:default*" t)
      (cl-letf (((symbol-function 'agent-notify)
                 (lambda (title message)
                   (setq notified (list title message)))))
        (agent-session-event (current-buffer) 'idle-prompt))
      (should (eq agent--session-state 'awaiting-input))
      (should (equal notified
                     '("Session ready"
                       "project: waiting for your response"))))))

(ert-deftest agent-test-session-event-stop-does-not-alert ()
  "Do not fire the ready alert on bare stop events."
  (let ((agent-backends nil)
        notified)
    (with-temp-buffer
      (cl-letf (((symbol-function 'agent-notify)
                 (lambda (&rest args) (setq notified args))))
        (agent-session-event (current-buffer) 'stop))
      (should-not notified))))

(ert-deftest agent-test-session-event-submit-marks-busy ()
  "Return sessions to busy when input is submitted while awaiting input."
  (with-temp-buffer
    (setq-local agent--session-state 'awaiting-input)
    (agent-session-event (current-buffer) 'submit)
    (should (eq agent--session-state 'busy))))

(ert-deftest agent-test-session-event-exit-request-marks-closing ()
  "Mark sessions closing on exit-request events."
  (with-temp-buffer
    (agent-session-event (current-buffer) 'exit-request)
    (should (eq agent--session-state 'closing))))

(ert-deftest agent-test-session-event-records-transition-times ()
  "Record a fresh timestamp on every session event."
  (let ((agent-backends nil)
        (agent-alert-on-ready nil))
    (with-temp-buffer
      (agent-session-event (current-buffer) 'stop)
      (let ((first agent--session-state-changed-at))
        (should (floatp first))
        (agent-session-event (current-buffer) 'submit)
        (should (>= agent--session-state-changed-at first))))))

(ert-deftest agent-test-session-event-rejects-unknown-events ()
  "Signal an error for unknown session events."
  (with-temp-buffer
    (should-error (agent-session-event (current-buffer) 'bogus))))

(ert-deftest agent-test-session-event-ignores-dead-buffers ()
  "Ignore session events delivered for killed buffers."
  (let ((buf (generate-new-buffer "agent-dead-test")))
    (kill-buffer buf)
    (should-not (agent-session-event buf 'stop))))

(ert-deftest agent-test-session-event-chain-suppresses-ready-alert ()
  "Suppress the ready alert when the before-exit chain consumes the event."
  (let ((agent-backends nil)
        notified)
    (with-temp-buffer
      (cl-letf (((symbol-function 'agent-notify)
                 (lambda (&rest args) (setq notified args)))
                ((symbol-function 'agent-exit-after-before-exit-skill)
                 (lambda (_backend _buffer) t)))
        (agent-session-event (current-buffer) 'idle-prompt))
      (should (eq agent--session-state 'awaiting-input))
      (should-not notified))))
```

- [ ] Step 2 — run the new tests and confirm they fail for the right reason:

```bash
cd "/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent"
~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-test.el agent-test-session-event-stop-marks-awaiting-input
```

Expected: FAILED with `(void-function agent-session-event)`.

- [ ] Step 3 — add the state variables. In `agent.el`, locate `agent--waiting-for-input` (`grep -n "defvar-local agent--waiting-for-input" agent.el`, line ~390) and insert immediately AFTER its closing paren:

```elisp
(defvar-local agent--session-state 'busy
  "Lifecycle state of this AI session buffer.
One of the symbols `busy', `awaiting-input', and `closing'.
Only `agent-session-event' may set this variable.")

(defvar-local agent--session-state-changed-at nil
  "Value of `float-time' at this session's last state transition.")
```

- [ ] Step 4 — add the transition function. Locate `agent--clear-waiting-for-input` (`grep -n "defun agent--clear-waiting-for-input" agent.el`, line ~816) and insert this new top-level section immediately after that function:

```elisp
;;;; Session state machine

(defun agent-session-event (buffer event)
  "Apply session EVENT to BUFFER's state machine.
EVENT is one of the symbols `stop', `idle-prompt', `submit', and
`exit-request'.  This function is the single owner of
`agent--session-state'; backends translate raw CLI events into
calls to it and never set session state directly."
  (when (buffer-live-p buffer)
    (pcase event
      ((or 'stop 'idle-prompt)
       (agent--session-event-awaiting-input buffer event))
      ('submit
       (agent--session-set-state buffer 'busy))
      ('exit-request
       (agent--session-set-state buffer 'closing))
      (_ (error "Unknown agent session event: %s" event)))))

(defun agent--session-event-awaiting-input (buffer event)
  "Transition BUFFER to `awaiting-input' and run the ready side effects.
EVENT is `stop' or `idle-prompt'.  The before-exit chain is
advanced first; when it consumes the event, the ready alert,
scrolling, and display-name refresh are suppressed.  The ready
alert fires only for `idle-prompt' events."
  (agent--session-set-state buffer 'awaiting-input)
  (unless (agent-exit-after-before-exit-skill
           (agent--detect-backend buffer) buffer)
    (when (eq event 'idle-prompt)
      (agent--session-notify-ready buffer))
    (agent--scroll-to-bottom buffer)
    (agent--refresh-display-names-deferred)))

(defun agent--session-set-state (buffer state)
  "Set BUFFER's session state to STATE and record the transition time."
  (with-current-buffer buffer
    (setq agent--session-state state)
    (setq agent--session-state-changed-at (float-time))))

(defun agent--session-notify-ready (buffer)
  "Fire the ready alert for session BUFFER via `agent-notify'."
  (let* ((backend (agent--detect-backend buffer))
         (label (or (and backend (agent--backend-get backend :label))
                    "Session"))
         (name (agent--session-name (buffer-name buffer))))
    (agent-notify
     (format "%s ready" label)
             (format "%s: waiting for your response" name))))
```

Note: in Phase 4, Task 4.1 replaces the `agent-exit-after-before-exit-skill` call in `agent--session-event-awaiting-input` with `agent--before-exit-transition`. Leave it as written here for now.

- [ ] Step 5 — emit `exit-request` from `agent-exit`. Locate it (`grep -n "defun agent-exit " agent.el`, line ~1989). Current code, verbatim:

```elisp
    (when (agent--run-before-exit-functions backend buffer)
      (call-interactively fn))))
```

Replace with:

```elisp
    (when (agent--run-before-exit-functions backend buffer)
      (agent-session-event buffer 'exit-request)
      (call-interactively fn))))
```

- [ ] Step 6 — document the new optional backend key. Find where backend keys are documented (`grep -n ":waiting-p" agent.el` — pre-refactor this is the `agent-backends` doc at lines 113–139; post-Phase-1 it may be the struct docstring). Next to the `:waiting-p` entry add:

```
  :notify                function (title message)
                           (ready-alert dispatcher; defaults to
                            `agent-notify')
```

- [ ] Step 7 — verify:

```bash
cd "/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent"
~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-test.el
~/My\ Drive/dotfiles/claude/bin/batch-test.sh agent
```

Expected: all tests pass (`N results as expected`), load check clean.

- [ ] Step 8 — commit:

```bash
git -C "/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent" add agent.el test/agent-test.el
git -C "/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent" commit -m "agent: add event-driven session state machine"
```

### Task 3.2: Core send wrappers and caller migration (tests first)

**Files:**
- `/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/agent.el` (new wrappers near the prompt-capture section, lines ~1010–1049; `agent--before-exit-skill-send-next` at lines 1404–1423)
- `/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/agent-chief.el` (lines 402–410)
- `/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/agent-claude.el` (lines 1540–1541, 2584)
- `/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/agent-codex.el` (line 1209)
- `/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/test/agent-test.el`, `test/agent-claude-test.el` (~line 53), `test/agent-codex-test.el` (~line 459)

**Caller migration table** (every internal caller of per-backend send functions or send slots; confirm completeness with `grep -n "agent-claude-send-command\|agent-claude-submit-command\|agent-claude-send-return\|agent-codex-send-command\|agent-codex-submit-command\|agent-codex-send-return\|:send-command\|:submit-command\|:send-return" *.el`):

| # | Caller | Location (pre-refactor) | Old call | New call |
|---|--------|------------------------|----------|----------|
| 1 | `agent-insert-captured-prompt` | agent.el:1038–1049 | `:send-command` slot via `send-fn` | `agent-send-string` |
| 2 | `agent--before-exit-skill-send-next` | agent.el:1404–1423 | `:submit-command` or `:send-command`+`:send-return` slots | `agent-submit` (interim; Task 4.1 rewrites this function entirely) |
| 3 | `agent-chief--submit-to-session` | agent-chief.el:402–410 | `:submit-command` slot | `agent-submit` (plus backend-cache seeding, see Step 5) |
| 4 | `agent-claude-send-todo-at-point` | agent-claude.el:1540–1541 | `(claude-code--do-send-command prompt)` | `(agent-submit prompt buf)` |
| 5 | `agent-claude--act-on-slack-message-start-session` | agent-claude.el:2584 | `(agent-claude-send-command slack-url buffer)` | `(agent-send-string slack-url buffer)` |
| 6 | `agent-codex--act-on-slack-message-start-session` | agent-codex.el:1209 | `(agent-codex-send-command slack-url buffer)` | `(agent-send-string slack-url buffer)` |
| 7 | `agent-claude-exit` | agent-claude.el:311 | `(claude-code--do-send-command "/exit")` | unchanged — the CLI must process `/exit` itself; `agent-exit` already emits `exit-request` |
| 8 | `agent-claude-submit-command` internals | agent-claude.el:288–291 | `agent-claude-send-command` + `agent-claude-send-return` | unchanged — backend-internal composition behind the `:submit-command` slot |

- [ ] Step 1 — add the tests. Append to `test/agent-test.el`:

```elisp
;;;; Core send wrappers

(ert-deftest agent-test-send-string-emits-submit-and-dispatches ()
  "Emit a submit event, then dispatch to the backend send slot."
  (let ((agent-backends nil)
        events)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :send-command (lambda (cmd &optional buffer)
                          (push (list cmd buffer agent--session-state)
                                events))))
        (setq-local agent--session-state 'awaiting-input)
        (agent-send-string "hello" buf)
        (should (equal events (list (list "hello" buf 'busy))))))))

(ert-deftest agent-test-submit-prefers-atomic-submit-command ()
  "Dispatch through the backend's atomic submit slot when present."
  (let ((agent-backends nil)
        events)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :submit-command (lambda (cmd &optional _buffer)
                            (push (list 'submit cmd) events))
          :send-command (lambda (cmd &optional _buffer)
                          (push (list 'command cmd) events))))
        (agent-submit "/retro" buf)
        (should (equal events '((submit "/retro"))))))))

(ert-deftest agent-test-submit-falls-back-to-send-and-return ()
  "Compose send-command and send-return when no atomic submit exists."
  (let ((agent-backends nil)
        events)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :send-command (lambda (cmd &optional _buffer)
                          (push (list 'command cmd) events))
          :send-return (lambda (&optional _buffer) (push 'return events))))
        (agent-submit "/retro" buf)
        (should (equal (nreverse events) '((command "/retro") return)))))))

(ert-deftest agent-test-send-return-emits-submit-event ()
  "Return sessions to busy when the pending prompt is submitted."
  (let ((agent-backends nil)
        sent)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :send-return (lambda (&optional _buffer) (setq sent t))))
        (setq-local agent--session-state 'awaiting-input)
        (agent-send-return buf)
        (should sent)
        (should (eq agent--session-state 'busy))))))

(ert-deftest agent-test-send-string-rejects-slotless-backends ()
  "Signal a user error when the backend lacks the send slot."
  (let ((agent-backends nil))
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))))
        (should-error (agent-send-string "hello" buf) :type 'user-error)))))
```

Run `~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-test.el agent-test-send-string-emits-submit-and-dispatches` — expect FAILED, `(void-function agent-send-string)`.

- [ ] Step 2 — implement the wrappers. In `agent.el`, insert a new section immediately before `;;;; Prompt capture` (`grep -n ";;;; Prompt capture" agent.el`, line ~1012):

```elisp
;;;; Core send wrappers

(defun agent-send-string (string &optional buffer)
  "Insert STRING into session BUFFER's prompt without submitting it.
BUFFER defaults to the current session buffer, prompting for one
when the current buffer is not a session.  Emits a `submit'
session event before dispatching so stale waiting state clears."
  (agent--dispatch-send :send-command (list string) buffer))

(defun agent-submit (string &optional buffer)
  "Insert STRING into session BUFFER's prompt and submit it.
BUFFER defaults to the current session buffer.  Prefer the
backend's atomic `:submit-command'; fall back to `:send-command'
followed by `:send-return' when the backend registers none."
  (let* ((buf (agent--resolve-session-buffer buffer))
         (backend (agent--detect-backend buf)))
    (if (agent--backend-get backend :submit-command)
        (agent--dispatch-send :submit-command (list string) buf)
      (agent--dispatch-send :send-command (list string) buf)
      (when-let* ((send-return-fn (agent--backend-get backend :send-return)))
        (funcall send-return-fn buf)))))

(defun agent-send-return (&optional buffer)
  "Submit the pending prompt in session BUFFER.
BUFFER defaults to the current session buffer.  Emits a `submit'
session event before dispatching to the backend's `:send-return'."
  (agent--dispatch-send :send-return nil buffer))

(defun agent--dispatch-send (slot args buffer)
  "Emit a `submit' event for BUFFER and call its backend SLOT with ARGS.
SLOT is one of `:send-command', `:submit-command', and
`:send-return'.  BUFFER is resolved with
`agent--resolve-session-buffer' and appended to ARGS."
  (let* ((buf (agent--resolve-session-buffer buffer))
         (backend (agent--detect-backend buf))
         (fn (and backend (agent--backend-get backend slot))))
    (unless fn
      (user-error "Backend `%s' does not support `%s'" backend slot))
    (agent-session-event buf 'submit)
    (apply fn (append args (list buf)))))
```

(`agent--resolve-session-buffer` already exists at agent.el:1051; it is defined after this insertion point, which is fine at runtime and for the byte compiler since both live in the same file.)

- [ ] Step 3 — migrate caller 1. Current code, verbatim (agent.el:1038–1049):

```elisp
  (let* ((session-buffer (agent--resolve-session-buffer buffer))
         (backend (agent--detect-backend session-buffer))
         (send-fn (agent--backend-get backend :send-command))
         (prompts (agent--captured-prompts
                   backend session-buffer include-inserted)))
    (unless send-fn
      (user-error "Backend `%s' does not support prompt insertion" backend))
    (unless prompts
      (user-error "No captured prompts for this session"))
    (let ((prompt (agent--select-captured-prompt prompts)))
      (funcall send-fn (plist-get prompt :text) session-buffer)
      (agent--delete-captured-prompt prompt))))
```

Replace with:

```elisp
  (let* ((session-buffer (agent--resolve-session-buffer buffer))
         (backend (agent--detect-backend session-buffer))
         (prompts (agent--captured-prompts
                   backend session-buffer include-inserted)))
    (unless (agent--backend-get backend :send-command)
      (user-error "Backend `%s' does not support prompt insertion" backend))
    (unless prompts
      (user-error "No captured prompts for this session"))
    (let ((prompt (agent--select-captured-prompt prompts)))
      (agent-send-string (plist-get prompt :text) session-buffer)
      (agent--delete-captured-prompt prompt))))
```

- [ ] Step 4 — migrate caller 2 (worked example). Current code, verbatim (agent.el:1404–1423):

```elisp
(defun agent--before-exit-skill-send-next (backend buffer)
  "Submit the next queued before-exit skill in BUFFER for BACKEND.
Skip entries that yield no command, and return non-nil when one is submitted."
  (with-current-buffer buffer
    (let (sent)
      (while (and (not sent) agent--before-exit-skill-remaining)
        (let* ((entry (pop agent--before-exit-skill-remaining))
               (command (agent--before-exit-skill-command backend entry))
               (submit-command-fn (agent--backend-get backend :submit-command))
               (send-command-fn (agent--backend-get backend :send-command)))
          (when (and command (or submit-command-fn send-command-fn))
            (if submit-command-fn
                (funcall submit-command-fn command buffer)
              (funcall send-command-fn command buffer)
              (when-let* ((send-return-fn (agent--backend-get backend :send-return)))
                (funcall send-return-fn buffer)))
            (message "Started %s; this session will close when the before-exit skills finish"
                     command)
            (setq sent t))))
      sent)))
```

Replace with:

```elisp
(defun agent--before-exit-skill-send-next (backend buffer)
  "Submit the next queued before-exit skill in BUFFER for BACKEND.
Skip entries that yield no command, and return non-nil when one is submitted."
  (with-current-buffer buffer
    (let (sent)
      (while (and (not sent) agent--before-exit-skill-remaining)
        (let* ((entry (pop agent--before-exit-skill-remaining))
               (command (agent--before-exit-skill-command backend entry)))
          (when (and command
                     (or (agent--backend-get backend :submit-command)
                         (agent--backend-get backend :send-command)))
            (agent-submit command buffer)
            (message "Started %s; this session will close when the before-exit skills finish"
                     command)
            (setq sent t))))
      sent)))
```

- [ ] Step 5 — migrate caller 3. Current code, verbatim (agent-chief.el:402–410):

```elisp
(defun agent-chief--submit-to-session (prompt &optional buffer)
  "Submit PROMPT to the chief-of-staff session BUFFER."
  (let* ((target (or buffer (agent-chief--session-buffer)
                     (agent-chief--ensure-session)))
         (backend (buffer-local-value 'agent-chief--session-backend target))
         (submit (agent--backend-get backend :submit-command)))
    (unless submit
      (user-error "Backend %S cannot submit chief prompts" backend))
    (funcall submit prompt target)))
```

Replace with (the `setq agent--backend` seeds the detection cache, since chief buffers track their backend in `agent-chief--session-backend` rather than via `:buffer-p`):

```elisp
(defun agent-chief--submit-to-session (prompt &optional buffer)
  "Submit PROMPT to the chief-of-staff session BUFFER."
  (let* ((target (or buffer (agent-chief--session-buffer)
                     (agent-chief--ensure-session)))
         (backend (buffer-local-value 'agent-chief--session-backend target)))
    (unless (agent--backend-get backend :submit-command)
      (user-error "Backend %S cannot submit chief prompts" backend))
    (with-current-buffer target
      (setq agent--backend backend))
    (agent-submit prompt target)))
```

- [ ] Step 6 — migrate callers 4–6.
  - agent-claude.el:1540–1541: replace `(with-current-buffer buf\n      (claude-code--do-send-command prompt))` with `(agent-submit prompt buf)` (drop the now-unneeded `with-current-buffer` wrapper; keep the surrounding `let*` and the lines after it unchanged).
  - agent-claude.el:2584: replace `(agent-claude-send-command slack-url buffer)` with `(agent-send-string slack-url buffer)`.
  - agent-codex.el:1209: replace `(agent-codex-send-command slack-url buffer)` with `(agent-send-string slack-url buffer)`.

- [ ] Step 7 — update the two Slack-routing tests that stub the old entry points.
  - `test/agent-claude-test.el` ~line 53: change `((symbol-function 'agent-claude-send-command)` to `((symbol-function 'agent-send-string)` (stub body unchanged: it records `(cmd target)` and returns `target`).
  - `test/agent-codex-test.el` ~line 459: change `((symbol-function 'agent-codex-send-command)` to `((symbol-function 'agent-send-string)` (stub body unchanged).

- [ ] Step 8 — verify all four suites plus the load check (commands in the preamble). All pass.

- [ ] Step 9 — commit:

```bash
git -C "/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent" add agent.el agent-chief.el agent-claude.el agent-codex.el test/agent-test.el test/agent-claude-test.el test/agent-codex-test.el
git -C "/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent" commit -m "agent: route all prompt sends through core wrappers"
```

### Task 3.3: Claude backend — event translation (tests first)

**Files:**
- `/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/agent-claude.el` (handlers at lines 1236–1309; scroll helper at 1311; advices at 2609–2614; registration `:label "Claude Code"` at line ~255)
- `/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/test/agent-claude-test.el`

Note: between this task and Task 3.5, the waiting indicator in the switcher is degraded for claude (writers stop setting `agent--waiting-for-input` before readers switch to the new state). Tasks 3.3, 3.4, and 3.5 must all land in the same sitting.

- [ ] Step 1 — add tests to `test/agent-claude-test.el` (append near the prompt-submission section):

```elisp
;;;; Session event translation

(ert-deftest agent-claude-test-handle-stop-marks-awaiting-input ()
  "Mark Claude sessions awaiting input on CLI stop events."
  (let ((buf (generate-new-buffer "*claude:~/repo/project/:default*"))
        (agent-alert-on-ready nil))
    (unwind-protect
        (progn
          (agent-claude--handle-stop
           (list :type 'stop :buffer-name (buffer-name buf)))
          (should (eq (buffer-local-value 'agent--session-state buf)
                      'awaiting-input)))
      (kill-buffer buf))))

(ert-deftest agent-claude-test-idle-prompt-emits-idle-prompt-event ()
  "Translate idle_prompt notifications into idle-prompt session events."
  (let ((buf (generate-new-buffer "*claude:~/repo/project/:default*"))
        emitted)
    (unwind-protect
        (cl-letf (((symbol-function 'agent-session-event)
                   (lambda (buffer event) (setq emitted (list buffer event)))))
          (agent-claude--handle-notification
           (list :type 'notification
                 :buffer-name (buffer-name buf)
                 :json-data "{\"notification_type\":\"idle_prompt\"}"))
          (should (equal emitted (list buf 'idle-prompt))))
      (kill-buffer buf))))

(ert-deftest agent-claude-test-note-submission-emits-submit-event ()
  "Return Claude sessions to busy when a prompt is sent."
  (with-temp-buffer
    (let ((buf (current-buffer)))
      (setq-local agent--session-state 'awaiting-input)
      (cl-letf (((symbol-function 'claude-code--buffer-p)
                 (lambda (candidate) (eq candidate buf))))
        (agent-claude--note-submission))
      (should (eq agent--session-state 'busy)))))

(ert-deftest agent-claude-test-note-submission-ignores-other-buffers ()
  "Do not emit submit events from non-Claude buffers."
  (with-temp-buffer
    (setq-local agent--session-state 'awaiting-input)
    (cl-letf (((symbol-function 'claude-code--buffer-p)
               (lambda (_candidate) nil)))
      (agent-claude--note-submission))
    (should (eq agent--session-state 'awaiting-input))))
```

Run `~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-claude-test.el agent-claude-test-note-submission-emits-submit-event` — expect FAILED, `(void-function agent-claude--note-submission)`.

- [ ] Step 2 — shrink the notification handler. Current code, verbatim (agent-claude.el:1236–1266):

```elisp
(defun agent-claude--handle-notification (message)
  "Handle a notification event from the Claude Code CLI.
MESSAGE is a plist with :type, :buffer-name, :json-data, and
:args.  Fires OS alerts for idle_prompt, permission_prompt, and
elicitation_dialog notifications."
  (when (eq (plist-get message :type) 'notification)
    (when-let* ((buf (get-buffer (plist-get message :buffer-name))))
      (with-current-buffer buf
        (let* ((name (agent-claude--session-name (buffer-name)))
               (ntype (agent-claude--notification-type
                       (plist-get message :json-data))))
          (pcase ntype
            ("idle_prompt"
             (setq agent--waiting-for-input (current-time))
             (unless (agent-exit-after-before-exit-skill 'claude-code buf)
               (agent-claude-notify
                "Claude ready"
                (format "%s: waiting for your response" name))))
            ("permission_prompt"
             (agent-claude-notify
              "Claude needs approval"
              (format "%s: permission request pending" name)))
            ("elicitation_dialog"
             (agent-claude-notify
              "Claude needs input"
              (format "%s: waiting for your input" name)))
            (_
             (agent-claude-notify
              "Claude Code"
              (format "%s: needs your attention" name))))))))
  nil)
```

Replace with:

```elisp
(defun agent-claude--handle-notification (message)
  "Handle a notification event from the Claude Code CLI.
MESSAGE is a plist with :type, :buffer-name, :json-data, and
:args.  Translates idle_prompt into a session event and fires OS
alerts for permission_prompt and elicitation_dialog notifications."
  (when (eq (plist-get message :type) 'notification)
    (when-let* ((buf (get-buffer (plist-get message :buffer-name))))
      (let ((name (agent-claude--session-name (buffer-name buf)))
            (ntype (agent-claude--notification-type
                    (plist-get message :json-data))))
        (pcase ntype
          ("idle_prompt"
           (agent-session-event buf 'idle-prompt))
          ("permission_prompt"
           (agent-claude-notify
            "Claude needs approval"
            (format "%s: permission request pending" name)))
          ("elicitation_dialog"
           (agent-claude-notify
            "Claude needs input"
            (format "%s: waiting for your input" name)))
          (_
           (agent-claude-notify
            "Claude Code"
            (format "%s: needs your attention" name)))))))
  nil)
```

- [ ] Step 3 — shrink the stop handler. Current code, verbatim (agent-claude.el:1300–1309):

```elisp
(defun agent-claude--handle-stop (message)
  "Handle a stop event from the Claude Code CLI.
MESSAGE is a plist with :type, :buffer-name, :json-data, and
:args.  Scrolls the corresponding terminal buffer to bottom."
  (when (eq (plist-get message :type) 'stop)
    (when-let* ((buf (get-buffer (plist-get message :buffer-name))))
      (with-current-buffer buf
        (unless (agent-exit-after-before-exit-skill 'claude-code buf)
          (agent-claude--scroll-to-bottom buf)))))
  nil)
```

Replace with:

```elisp
(defun agent-claude--handle-stop (message)
  "Handle a stop event from the Claude Code CLI.
MESSAGE is a plist with :type, :buffer-name, :json-data, and
:args.  Translates the event into a `stop' session event."
  (when (eq (plist-get message :type) 'stop)
    (when-let* ((buf (get-buffer (plist-get message :buffer-name))))
      (agent-session-event buf 'stop)))
  nil)
```

Then delete `agent-claude--scroll-to-bottom` (defined immediately below, line 1311; core's `agent--scroll-to-bottom` is an exact duplicate and is now called from `agent--session-event-awaiting-input`). First confirm it has no other callers: `grep -n "agent-claude--scroll-to-bottom" agent-claude.el test/agent-claude-test.el` must show only the definition.

- [ ] Step 4 — replace the advice cluster. Current code, verbatim (agent-claude.el:2609–2614):

```elisp
(advice-add 'claude-code--eat-send-return :before
            #'agent--clear-waiting-for-input)
(advice-add 'claude-code--vterm-send-return :before
            #'agent--clear-waiting-for-input)
(advice-add 'claude-code--do-send-command :before
            #'agent--clear-waiting-for-input)
```

Replace with:

```elisp
(advice-add 'claude-code--eat-send-return :before
            #'agent-claude--note-submission)
(advice-add 'claude-code--vterm-send-return :before
            #'agent-claude--note-submission)
(advice-add 'claude-code--do-send-command :before
            #'agent-claude--note-submission)
```

and define the advice function near the other alert/handler functions (insert directly before `agent-claude--handle-notification`):

```elisp
(defun agent-claude--note-submission (&rest _)
  "Emit a `submit' session event for the current Claude buffer.
Installed as advice on claude-code.el's send paths because that
package is third-party and exposes no submission hook.  Phase 7
moves the installation into a minor mode."
  (when (claude-code--buffer-p (current-buffer))
    (agent-session-event (current-buffer) 'submit)))
```

- [ ] Step 5 — add the `:notify` slot. In the `agent-register-backend 'claude-code` form (`grep -n "agent-register-backend 'claude-code" agent-claude.el`), add directly after the `:label "Claude Code"` entry:

```elisp
        :notify #'agent-claude-notify
```

- [ ] Step 6 — rewrite `agent-claude-jump-to-waiting` (agent-claude.el:1287–1298) to read the new state. Replace its body's `let*` binding `(ts (buffer-local-value 'agent--waiting-for-input buf))` flow with:

```elisp
(defun agent-claude-jump-to-waiting ()
  "Switch to the Claude session that most recently started waiting for input."
  (interactive)
  (let (best-buf best-time)
    (dolist (buf (claude-code--find-all-claude-buffers))
      (when (buffer-live-p buf)
        (let ((ts (and (eq (buffer-local-value 'agent--session-state buf)
                           'awaiting-input)
                       (buffer-local-value 'agent--session-state-changed-at
                                           buf))))
          (when (and ts (or (null best-time) (> ts best-time)))
            (setq best-buf buf best-time ts)))))
    (if best-buf
        (switch-to-buffer best-buf)
      (message "No sessions waiting for input"))))
```

- [ ] Step 7 — verify (`elisp-ert agent test/agent-claude-test.el`, then full `agent` suite, then `batch-test.sh agent`). All pass; `grep -n "agent--waiting-for-input\|agent--clear-waiting-for-input" agent-claude.el` returns nothing.

- [ ] Step 8 — commit:

```bash
git -C "/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent" add agent-claude.el test/agent-claude-test.el
git -C "/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent" commit -m "agent-claude: translate CLI events into session events"
```

### Task 3.4: Codex backend — event translation (tests first)

**Files:**
- `/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/agent-codex.el` (handler at lines 726–747; `agent-codex-send-return` at 261–269; the Phase-2 `codex-command-submitted-hook` function — locate with `grep -n "codex-command-submitted-hook" agent-codex.el`)
- `/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/test/agent-codex-test.el` (lines 408–415, 431–437; new tests)

- [ ] Step 1 — add tests to `test/agent-codex-test.el`:

```elisp
;;;; Session event translation

(ert-deftest agent-codex-test-stop-marks-awaiting-input-and-alerts ()
  "Mark Codex sessions awaiting input and alert on CLI Stop events."
  (let ((buf (generate-new-buffer "*codex:/tmp/project/:default*"))
        notified)
    (unwind-protect
        (cl-letf (((symbol-function 'agent-notify)
                   (lambda (title message)
                     (setq notified (list title message)))))
          (with-current-buffer buf
            (setq-local agent--backend 'codex))
          (agent-codex--handle-notification
           (list :type "Stop" :buffer-name (buffer-name buf)))
          (should (eq (buffer-local-value 'agent--session-state buf)
                      'awaiting-input))
          (should (equal notified
                         '("Codex ready"
                           "project: waiting for your response"))))
      (kill-buffer buf))))

(ert-deftest agent-codex-test-submitted-hook-emits-submit-event ()
  "Return Codex sessions to busy when a command is submitted."
  (with-temp-buffer
    (let ((buf (current-buffer)))
      (setq-local agent--session-state 'awaiting-input)
      (agent-codex--note-submission buf)
      (should (eq (buffer-local-value 'agent--session-state buf) 'busy)))))
```

Naming caveat: `agent-codex--note-submission` is the canonical name for the Phase-2 function on `codex-command-submitted-hook`. If Phase 2 named it differently (check with `grep -n "codex-command-submitted-hook" agent-codex.el`), use the existing name in both the test and Step 3, or rename the existing function to `agent-codex--note-submission` (updating the `add-hook` site) — renaming is preferred for consistency with `agent-claude--note-submission`.

Run the second test — expect failure (either void function or, if Phase 2's function exists under this name, an assertion failure because it still only clears the old flag).

- [ ] Step 2 — replace the Stop handler. Current code, verbatim (agent-codex.el:726–747):

```elisp
(defun agent-codex--handle-notification (message)
  "Handle a notification event from Codex CLI.
MESSAGE is a plist with :type, :buffer-name, :json-data, and :args.
The :type field is a string from the hook wrapper (e.g. \"Stop\")."
  (let ((hook-type (plist-get message :type)))
    (when (member hook-type '("Stop" "Notification" "SessionStart"))
      (when-let* ((buf (get-buffer (plist-get message :buffer-name))))
        (with-current-buffer buf
          (let ((name (agent--session-name (buffer-name))))
            (pcase hook-type
              ("Stop"
               (setq agent--waiting-for-input (current-time))
               (unless (agent-exit-after-before-exit-skill 'codex buf)
                 (agent-notify
                  "Codex ready"
                  (format "%s: waiting for your response" name))
                 (agent--scroll-to-bottom buf)))
              ("Notification"
               (agent-notify
                "Codex"
                (format "%s: needs your attention" name)))))))))
  nil)
```

Replace with (Codex's CLI Stop means "back at the prompt", hence the `idle-prompt` translation, which preserves the ready alert and scroll via core):

```elisp
(defun agent-codex--handle-notification (message)
  "Handle a notification event from Codex CLI.
MESSAGE is a plist with :type, :buffer-name, :json-data, and :args.
The :type field is a string from the hook wrapper (e.g. \"Stop\").
Codex's Stop fires when the CLI is back at its prompt, so it is
translated into an `idle-prompt' session event."
  (let ((hook-type (plist-get message :type)))
    (when (member hook-type '("Stop" "Notification" "SessionStart"))
      (when-let* ((buf (get-buffer (plist-get message :buffer-name))))
        (pcase hook-type
          ("Stop"
           (agent-session-event buf 'idle-prompt))
          ("Notification"
           (agent-notify
            "Codex"
            (format "%s: needs your attention"
                    (agent--session-name (buffer-name buf)))))))))
  nil)
```

- [ ] Step 3 — rewrite the submitted-hook function body. The Phase-2 function currently calls `agent--clear-waiting-for-input`; replace it entirely with:

```elisp
(defun agent-codex--note-submission (buffer)
  "Emit a `submit' session event for Codex session BUFFER.
Runs on `codex-command-submitted-hook' for every submission path."
  (agent-session-event buffer 'submit))
```

Keep its existing `add-hook` site (Phase 7 moves installation into a minor mode).

- [ ] Step 4 — remove the inline clear in `agent-codex-send-return`. Current code, verbatim (agent-codex.el:261–269):

```elisp
(defun agent-codex-send-return (&optional buffer)
  "Submit the active prompt in BUFFER's Codex session."
  (when-let* ((codex-buffer (agent-codex--target-buffer buffer)))
    (with-current-buffer codex-buffer
      (sit-for 0.1)
      (agent--clear-waiting-for-input)
      (codex--term-send-action codex-terminal-backend :return)
      (display-buffer codex-buffer))
    codex-buffer))
```

Replace with:

```elisp
(defun agent-codex-send-return (&optional buffer)
  "Submit the active prompt in BUFFER's Codex session."
  (when-let* ((codex-buffer (agent-codex--target-buffer buffer)))
    (with-current-buffer codex-buffer
      (sit-for 0.1)
      (codex--term-send-action codex-terminal-backend :return)
      (display-buffer codex-buffer))
    codex-buffer))
```

- [ ] Step 5 — sweep leftovers. Run `grep -n "agent--clear-waiting-for-input\|agent-codex--clear-waiting-before" agent-codex.el`. Phase 2 should already have removed the lazy advices (pre-Phase-2 lines 1408–1423) and the helpers `agent-codex--clear-waiting-before-send-command-to-buffer` / `agent-codex--clear-waiting-before-tui-action` (1425–1434). Delete any that remain.

- [ ] Step 6 — update the two stale tests:
  - `test/agent-codex-test.el:408–415` (`agent-codex-test-send-return-clears-waiting-flag`): replace entirely with:

```elisp
(ert-deftest agent-codex-test-send-return-sends-return-action ()
  "Send the Codex return action when submitting the current prompt."
  (let (actions)
    (with-temp-buffer
      (cl-letf (((symbol-function 'codex--term-send-action)
                 (lambda (_backend action &optional _payload)
                   (push action actions)))
                ((symbol-function 'display-buffer) #'ignore))
        (agent-codex-send-return (current-buffer))))
    (should (equal actions '(:return)))))
```

  - `test/agent-codex-test.el:431–437` (`agent-codex-test-target-buffer-submit-clears-waiting-flag`): delete (its subject was removed with the Phase-2 advice collapse; the new `agent-codex-test-submitted-hook-emits-submit-event` covers the replacement).

- [ ] Step 7 — verify: `elisp-ert agent test/agent-codex-test.el` and `batch-test.sh agent`. Note: the tests at lines ~581–612 (`working-status-is-not-waiting`, `app-server-active-turn-is-not-waiting`, `app-server-active-prompt-is-background-waiting`) still pass here because they set `agent--waiting-for-input` manually and the readers are unchanged until Task 3.5.

- [ ] Step 8 — commit:

```bash
git -C "/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent" add agent-codex.el test/agent-codex-test.el
git -C "/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent" commit -m "agent-codex: translate CLI events into session events"
```

### Task 3.5: Display-state derivation; delete the old waiting flag (tests first)

**Files:**
- `/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/agent.el` (var at 390–393; `agent--session-suffix-spec`/`agent--session-waiting-p`/`agent--backend-waiting-p`/`agent--waiting-face` at 658–703; `agent--clear-waiting-for-input` at 816–819; `agent-jump-to-waiting` at 821–836)
- `/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/test/agent-test.el` (lines 189–201; new tests)
- `/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/test/agent-codex-test.el` (lines 581–623)

- [ ] Step 1 — add display-state tests to `test/agent-test.el`:

```elisp
;;;; Display state

(ert-deftest agent-test-display-state-busy-by-default ()
  "Report busy for sessions without waiting state."
  (let ((agent-backends nil))
    (with-temp-buffer
      (should (eq (agent-session-display-state (current-buffer)) 'busy)))))

(ert-deftest agent-test-display-state-waiting-after-awaiting-input ()
  "Report waiting once the session state machine awaits input."
  (let ((agent-backends nil))
    (with-temp-buffer
      (setq-local agent--session-state 'awaiting-input)
      (should (eq (agent-session-display-state (current-buffer)) 'waiting)))))

(ert-deftest agent-test-display-state-busy-backend-suppresses-stale-waiting ()
  "Suppress stale waiting state while the backend reports busy."
  (let ((agent-backends nil))
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :busy-p (lambda (_buffer) t)))
        (setq-local agent--session-state 'awaiting-input)
        (should (eq (agent-session-display-state buf) 'busy))))))

(ert-deftest agent-test-display-state-background-tasks-mark-amber ()
  "Report background-waiting for waiting sessions with background work."
  (let ((agent-backends nil))
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :background-tasks-p (lambda (_buffer) t)))
        (setq-local agent--session-state 'awaiting-input)
        (should (eq (agent-session-display-state buf)
                    'background-waiting))))))

(ert-deftest agent-test-display-state-steering-overrides-busy ()
  "Report background-waiting for busy sessions accepting steering input."
  (let ((agent-backends nil))
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :waiting-p (lambda (_buffer) t)
          :busy-p (lambda (_buffer) t)
          :background-tasks-p (lambda (_buffer) t)))
        (should (eq (agent-session-display-state buf)
                    'background-waiting))))))

(ert-deftest agent-test-jump-to-waiting-picks-most-recent ()
  "Jump to the session that most recently started waiting."
  (let ((agent-backends nil)
        (a (generate-new-buffer "agent-wait-a"))
        (b (generate-new-buffer "agent-wait-b"))
        switched)
    (unwind-protect
        (progn
          (agent-register-backend
           'one
           (agent-test--backend
            :buffer-p (lambda (candidate) (memq candidate (list a b)))
            :find-all-buffers (lambda () (list a b))))
          (with-current-buffer a
            (setq-local agent--session-state 'awaiting-input)
            (setq-local agent--session-state-changed-at 100.0))
          (with-current-buffer b
            (setq-local agent--session-state 'awaiting-input)
            (setq-local agent--session-state-changed-at 200.0))
          (cl-letf (((symbol-function 'switch-to-buffer)
                     (lambda (buffer) (setq switched buffer))))
            (agent-jump-to-waiting))
          (should (eq switched b)))
      (kill-buffer a)
      (kill-buffer b))))
```

Run one of them — expect FAILED with `(void-function agent-session-display-state)`.

- [ ] Step 2 — replace the readers. Current code, verbatim (agent.el:674–703):

```elisp
(defun agent--session-waiting-p (buffer backend)
  "Return non-nil when BUFFER is waiting for input.
BACKEND may provide `:busy-p' to suppress a stale waiting flag
while the session is actively responding.  BACKEND may provide
`:waiting-p' to report input readiness directly."
  (let ((backend-waiting (agent--backend-waiting-p buffer backend)))
    (and (or backend-waiting
             (buffer-local-value 'agent--waiting-for-input buffer))
         (or backend-waiting
             (not (and backend
                       (when-let* ((fn (agent--backend-get backend :busy-p)))
                         (funcall fn buffer))))))))

(defun agent--backend-waiting-p (buffer backend)
  "Return non-nil when BACKEND reports BUFFER is accepting input."
  (and backend
       (when-let* ((fn (agent--backend-get backend :waiting-p)))
         (funcall fn buffer))))

(defun agent--waiting-face (buffer backend)
  "Return the face for BUFFER's waiting indicator.
Uses `agent-waiting-with-background' when BACKEND reports
that BUFFER has active background tasks, `agent-waiting'
otherwise."
  (if (and backend
           (when-let* ((fn (agent--backend-get
                            backend :background-tasks-p)))
             (funcall fn buffer)))
      'agent-waiting-with-background
    'agent-waiting))
```

Replace the whole block with:

```elisp
(defun agent--session-waiting-p (buffer &optional backend)
  "Return non-nil when BUFFER is waiting for input.
BACKEND defaults to the detected backend."
  (not (eq (agent-session-display-state buffer backend) 'busy)))

(defun agent-session-display-state (buffer &optional backend)
  "Return the switcher display state for session BUFFER.
BACKEND defaults to the detected backend.  The result is one of
the symbols `busy', `waiting', and `background-waiting'.  A
session counts as waiting when its backend reports an input
prompt directly via `:waiting-p' (an active turn that accepts
steering input), or when `agent--session-state' is
`awaiting-input' and the backend's `:busy-p' does not veto it as
stale.  Waiting sessions whose backend reports work via
`:background-tasks-p' display as `background-waiting'."
  (let* ((backend (or backend (agent--detect-backend buffer)))
         (backend-waiting (agent--backend-waiting-p buffer backend))
         (awaiting (eq (buffer-local-value 'agent--session-state buffer)
                       'awaiting-input)))
    (cond
     ((and (not backend-waiting)
           (or (not awaiting)
               (agent--backend-busy-p buffer backend)))
      'busy)
     ((agent--backend-background-tasks-p buffer backend)
      'background-waiting)
     (t 'waiting))))

(defun agent--backend-waiting-p (buffer backend)
  "Return non-nil when BACKEND reports BUFFER is accepting input."
  (and backend
       (when-let* ((fn (agent--backend-get backend :waiting-p)))
         (funcall fn buffer))))

(defun agent--backend-busy-p (buffer backend)
  "Return non-nil when BACKEND reports BUFFER is actively responding."
  (and backend
       (when-let* ((fn (agent--backend-get backend :busy-p)))
         (funcall fn buffer))))

(defun agent--backend-background-tasks-p (buffer backend)
  "Return non-nil when BACKEND reports background work in BUFFER."
  (and backend
       (when-let* ((fn (agent--backend-get backend :background-tasks-p)))
         (funcall fn buffer))))
```

(`agent--waiting-face` is deleted; the equivalence proof: today's waiting condition is `backend-waiting OR (flag AND NOT busy-p)` and the amber face applies iff `has-background-tasks-p`; the `cond` above reproduces exactly that truth table with `agent--session-state = awaiting-input` standing in for the flag.)

- [ ] Step 3 — rewrite the suffix spec. Current code, verbatim (agent.el:658–672):

```elisp
(defun agent--session-suffix-spec (buf key)
  "Build a transient suffix spec for BUF bound to KEY."
  (let* ((backend (agent--detect-backend buf))
         (icon (when backend (agent-backend-icon backend)))
         (name (agent-display-name buf))
         (label (if (and icon (not (string-empty-p icon)))
                    (format "%s %s" icon name) name))
         (waiting (agent--session-waiting-p buf backend))
         (cmd (make-symbol (format "ai-switch-%s" key)))
         (spec (list key label cmd)))
    (when waiting
      (setq spec (append spec
                         (list :face (agent--waiting-face buf backend)))))
    (fset cmd (lambda () (interactive) (switch-to-buffer buf)))
    spec))
```

Replace with:

```elisp
(defun agent--session-suffix-spec (buf key)
  "Build a transient suffix spec for BUF bound to KEY."
  (let* ((backend (agent--detect-backend buf))
         (icon (when backend (agent-backend-icon backend)))
         (name (agent-display-name buf))
         (label (if (and icon (not (string-empty-p icon)))
                    (format "%s %s" icon name) name))
         (state (agent-session-display-state buf backend))
         (cmd (make-symbol (format "ai-switch-%s" key)))
         (spec (list key label cmd)))
    (unless (eq state 'busy)
      (setq spec (append spec
                         (list :face (if (eq state 'background-waiting)
                                         'agent-waiting-with-background
                                       'agent-waiting)))))
    (fset cmd (lambda () (interactive) (switch-to-buffer buf)))
    spec))
```

- [ ] Step 4 — rewrite `agent-jump-to-waiting`. Current code, verbatim (agent.el:821–836):

```elisp
;;;###autoload
(defun agent-jump-to-waiting ()
  "Switch to the AI session that most recently started waiting for input."
  (interactive)
  (let (best-buf best-time)
    (dolist (buf (agent--find-all-buffers))
      (when (buffer-live-p buf)
        (let* ((backend (agent--detect-backend buf))
               (ts (and backend
                        (agent--session-waiting-p buf backend)
                        (buffer-local-value 'agent--waiting-for-input buf))))
          (when (and ts (or (null best-time) (time-less-p best-time ts)))
            (setq best-buf buf best-time ts)))))
    (if best-buf
        (switch-to-buffer best-buf)
      (message "No sessions waiting for input"))))
```

Replace with:

```elisp
;;;###autoload
(defun agent-jump-to-waiting ()
  "Switch to the AI session that most recently started waiting for input."
  (interactive)
  (let (best-buf best-time)
    (dolist (buf (agent--find-all-buffers))
      (when (buffer-live-p buf)
        (let ((ts (and (agent--session-waiting-p buf)
                       (buffer-local-value 'agent--session-state-changed-at
                                           buf))))
          (when (and ts (or (null best-time) (> ts best-time)))
            (setq best-buf buf best-time ts)))))
    (if best-buf
        (switch-to-buffer best-buf)
      (message "No sessions waiting for input"))))
```

- [ ] Step 5 — delete the old flag and its clearer:
  - Delete the `agent--waiting-for-input` defvar-local (agent.el:390–393).
  - Delete `agent--clear-waiting-for-input` (agent.el:816–819).

- [ ] Step 6 — update the affected tests.
  - `test/agent-test.el:189–201` (`agent-test-waiting-face-detects-background-work`): replace entirely with:

```elisp
(ert-deftest agent-test-waiting-with-background-work-displays-amber ()
  "Use the background-waiting state when the backend reports work."
  (let ((agent-backends nil))
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :find-all-buffers (lambda () (list buf))
          :background-tasks-p (lambda (_buffer) t)))
        (setq-local agent--session-state 'awaiting-input)
        (should (eq (agent-session-display-state buf 'one)
                    'background-waiting))))))
```

  - `test/agent-codex-test.el:581–623`: replace the four tests with:

```elisp
(ert-deftest agent-codex-test-working-status-is-not-waiting ()
  "Do not display stale Codex waiting state while Codex is working."
  (let ((buf (generate-new-buffer "*codex-test*")))
    (unwind-protect
        (with-current-buffer buf
          (setq-local agent--session-state 'awaiting-input)
          (insert "• Working (20m 58s • esc to interrupt)\n")
          (should (eq (agent-session-display-state buf 'codex) 'busy)))
      (kill-buffer buf))))

(ert-deftest agent-codex-test-app-server-active-turn-is-not-waiting ()
  "Do not display stale Codex waiting state during app-server turns."
  (let ((buf (generate-new-buffer "*codex-test*")))
    (unwind-protect
        (with-current-buffer buf
          (setq-local agent--session-state 'awaiting-input)
          (setq-local codex--app-server-turn-active-p t)
          (should (eq (agent-session-display-state buf 'codex) 'busy)))
      (kill-buffer buf))))

(ert-deftest agent-codex-test-app-server-active-prompt-is-background-waiting ()
  "Show app-server turns with an available prompt as background waiting."
  (let ((buf (generate-new-buffer "*codex-test*")))
    (unwind-protect
        (with-current-buffer buf
          (insert "❯ ")
          (setq-local codex--app-server-turn-active-p t)
          (setq-local codex--app-server-input-marker
                      (copy-marker (point-max) nil))
          (should (eq (agent-session-display-state buf 'codex)
                      'background-waiting)))
      (kill-buffer buf))))

(ert-deftest agent-codex-test-waiting-with-background-work-is-amber ()
  "Show waiting Codex sessions with background work as background waiting."
  (let ((buf (generate-new-buffer "*codex-test*")))
    (unwind-protect
        (with-current-buffer buf
          (setq-local agent--session-state 'awaiting-input)
          (insert "  · 2 background terminals running\n")
          (should (eq (agent-session-display-state buf 'codex)
                      'background-waiting)))
      (kill-buffer buf))))
```

(In the last test the buffer text deliberately contains no `• Working` line: that would also match `agent-codex--working-regexp`, making `:busy-p` true and the state `busy`.)

- [ ] Step 7 — verify everything:

```bash
cd "/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent"
grep -rn "agent--waiting-for-input\|agent--clear-waiting-for-input\|agent--waiting-face" *.el test/*.el
```

Expected: zero hits. Then run all four test suites and `batch-test.sh agent`; all pass.

- [ ] Step 8 — commit:

```bash
git -C "/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent" add agent.el test/agent-test.el test/agent-codex-test.el
git -C "/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent" commit -m "agent: derive waiting display from session state machine"
```

**Phase 3 definition of done:** all four ERT suites pass; load check passes; the grep in Task 3.5 Step 7 is empty; `agent--session-state` is written only inside `agent--session-set-state`; the codex amber test (`agent-codex-test-app-server-active-prompt-is-background-waiting`) passes. Not verified end-to-end here: live CLI Stop/idle_prompt delivery in a running Emacs session — flag this in the phase wrap-up.

## Phase 4 — Single-plist before-exit chain with watchdog

### Task 4.1: Replace the four flags with `agent--before-exit` and a transition function (tests first)

**Files:**
- `/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/agent.el` (vars at 97–104; defcustom slot near 82–88; chain at 1368–1431; hook block at 2083–2084; the chain call inside `agent--session-event-awaiting-input` added in Task 3.1)
- `/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/test/agent-test.el` (before-exit tests, pre-refactor lines 375–642, plus the Task 3.1 test `agent-test-session-event-chain-suppresses-ready-alert`)

**Flag-reference migration table** (every reference to the four flags, from `grep -n "before-exit-skill-started\|before-exit-skill-remaining\|before-exit-skill-exit-pending\|before-exit-skill-inhibit" *.el test/*.el`):

| # | Reference | Location (pre-refactor) | Disposition |
|---|-----------|------------------------|-------------|
| 1 | defvar-locals `agent--before-exit-skill-started` / `-remaining` / `-exit-pending` | agent.el:97–104 | deleted; replaced by single `agent--before-exit` plist |
| 2 | `agent-before-exit-skill-inhibit` defvar-local | agent.el:106–109 | KEPT verbatim (public opt-out) |
| 3 | reads/writes in `agent-run-skill-before-exit` | agent.el:1374–1386 | rewritten (this task, Step 4) |
| 4 | reads/writes in `agent-exit-after-before-exit-skill` | agent.el:1392–1402 | function deleted; replaced by `agent--before-exit-transition` |
| 5 | pop in `agent--before-exit-skill-send-next` | agent.el:1409–1410 | function deleted; replaced by `agent--before-exit-submit-next` |
| 6 | `(setq-local agent-before-exit-skill-inhibit t)` in claude handoff | agent-claude.el:2641 | unchanged (inhibit kept) |
| 7 | `(setq-local agent-before-exit-skill-inhibit t)` in codex handoff | agent-codex.el:1252 | unchanged (inhibit kept) |
| 8 | flag assertions in test/agent-test.el (lines 396–397, 495–496, 506, 513–514, 581–642) | rewritten in Step 1 |
| 9 | flag write in test/agent-codex-test.el:544 | rewritten in Task 4.2 |

Worked example (#4): every call site of `agent-exit-after-before-exit-skill` is now the single call inside `agent--session-event-awaiting-input` (Tasks 3.3/3.4 removed the backend-file call sites). That one call becomes `(agent--before-exit-transition buffer 'step)` — see Step 5.

- [ ] Step 1 — rewrite and extend the tests in `test/agent-test.el`. Replace the block of before-exit tests (every `ert-deftest` from `agent-test-run-skill-before-exit-submits-codex-skill` through `agent-test-exit-after-before-exit-skill-advances-to-next-skill`, pre-refactor lines 375–642) with the following. Tests that only check directory/duration/prefix routing keep their current bodies except where noted.

```elisp
(ert-deftest agent-test-run-skill-before-exit-submits-codex-skill ()
  "Submit a Codex skill and abort the first exit globally by default."
  (let ((agent-backends nil)
        (agent-before-exit-skill-name "session-retro")
        (agent-before-exit-skill-directories nil)
        events)
    (with-temp-buffer
      (let* ((dir (file-name-as-directory default-directory))
             (buf (current-buffer)))
        (agent-register-backend
         'codex
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :directory (lambda (_buffer) dir)
          :send-command (lambda (cmd &optional _buffer)
                          (push (list 'command cmd) events))
          :send-return (lambda (&optional _buffer) (push 'return events))))
        (should-not (agent-run-skill-before-exit 'codex buf))
        (should (equal (nreverse events)
                       '((command "$session-retro") return)))
        (should (eq (plist-get agent--before-exit :state) 'running))
        (should-not (plist-get agent--before-exit :queue))
        (should (numberp (plist-get agent--before-exit :started-at)))
        (should (agent-run-skill-before-exit 'codex buf))))))

(ert-deftest agent-test-before-exit-chain-advances-on-stop-events ()
  "Advance a two-skill chain across stop events, then close."
  (let ((agent-backends nil)
        (agent-before-exit-skill-names '("update-log" "session-retro"))
        (agent-before-exit-skill-name nil)
        (agent-before-exit-skill-directories nil)
        (agent-skill-command-prefix-alist '((codex . "$")))
        (events nil)
        exited)
    (with-temp-buffer
      (let* ((dir (file-name-as-directory default-directory))
             (buf (current-buffer)))
        (agent-register-backend
         'codex
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :directory (lambda (_buffer) dir)
          :submit-command (lambda (cmd &optional _buffer) (push cmd events))
          :exit (lambda () (interactive) (setq exited t))))
        (cl-letf (((symbol-function 'agent--before-exit-start-watchdog)
                   (lambda (_buffer) nil))
                  ((symbol-function 'run-at-time)
                   (lambda (_time _repeat function &rest args)
                     (apply function args))))
          (should-not (agent-run-skill-before-exit 'codex buf))
          (should (equal events '("$update-log")))
          (should-not exited)
          (should (agent--before-exit-transition buf 'step))
          (should (equal events '("$session-retro" "$update-log")))
          (should-not exited)
          (should (agent--before-exit-transition buf 'step))
          (should exited)
          (should (eq (plist-get agent--before-exit :state) 'closing)))))))

(ert-deftest agent-test-before-exit-veto-defers-exactly-one-stop ()
  "Defer chain advance while the backend vetoes, then proceed."
  (let ((agent-backends nil)
        (agent-before-exit-skill-name "session-retro")
        (agent-before-exit-skill-directories nil)
        (ready nil)
        exited)
    (with-temp-buffer
      (let* ((dir (file-name-as-directory default-directory))
             (buf (current-buffer)))
        (agent-register-backend
         'codex
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :directory (lambda (_buffer) dir)
          :submit-command (lambda (_cmd &optional _buffer))
          :before-exit-ready-to-close-p (lambda (_buffer) ready)
          :exit (lambda () (interactive) (setq exited t))))
        (cl-letf (((symbol-function 'agent--before-exit-start-watchdog)
                   (lambda (_buffer) nil))
                  ((symbol-function 'run-at-time)
                   (lambda (_time _repeat function &rest args)
                     (apply function args))))
          (should-not (agent-run-skill-before-exit 'codex buf))
          (should-not (agent--before-exit-transition buf 'step))
          (should-not exited)
          (should (eq (plist-get agent--before-exit :state) 'running))
          (setq ready t)
          (should (agent--before-exit-transition buf 'step))
          (should exited))))))

(ert-deftest agent-test-before-exit-timeout-aborts-and-warns ()
  "Reset the chain and warn when the watchdog expires."
  (let ((agent-backends nil)
        (agent-before-exit-skill-name "session-retro")
        (agent-before-exit-skill-directories nil)
        (agent-before-exit-timeout 600)
        watchdog
        messages
        exited)
    (with-temp-buffer
      (let* ((dir (file-name-as-directory default-directory))
             (buf (current-buffer)))
        (agent-register-backend
         'codex
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :directory (lambda (_buffer) dir)
          :submit-command (lambda (_cmd &optional _buffer))
          :exit (lambda () (interactive) (setq exited t))))
        (cl-letf (((symbol-function 'run-at-time)
                   (lambda (time _repeat function &rest args)
                     (when (equal time agent-before-exit-timeout)
                       (setq watchdog (cons function args)))
                     'agent-test-timer))
                  ((symbol-function 'cancel-timer) #'ignore)
                  ((symbol-function 'message)
                   (lambda (fmt &rest args)
                     (push (apply #'format fmt args) messages))))
          (should-not (agent-run-skill-before-exit 'codex buf))
          (should watchdog)
          (apply (car watchdog) (cdr watchdog))
          (should-not agent--before-exit)
          (should-not exited)
          (should (cl-some (lambda (m) (string-match-p "timed out" m))
                           messages)))))))

(ert-deftest agent-test-run-skill-before-exit-honors-buffer-local-inhibit ()
  "Do not submit before-exit skills when the session inhibits them."
  (let ((agent-backends nil)
        (agent-before-exit-skill-name "session-retro")
        (agent-before-exit-skill-directories nil)
        called)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (setq-local agent-before-exit-skill-inhibit t)
        (agent-register-backend
         'codex
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :send-command (lambda (&rest _args) (setq called t))))
        (should (agent-run-skill-before-exit 'codex buf))
        (should-not called)
        (should-not agent--before-exit)))))

(ert-deftest agent-test-run-skill-before-exit-skips-short-sessions ()
  "Do not submit before-exit skills before the minimum duration."
  (let ((agent-backends nil)
        (agent-before-exit-skill-name "session-retro")
        (agent-before-exit-skill-directories nil)
        (agent-before-exit-skill-min-duration-seconds 60)
        called)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (agent-register-backend
         'codex
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :duration-ms (lambda (_buffer) 30000)
          :send-command (lambda (&rest _args) (setq called t))))
        (should (agent-run-skill-before-exit 'codex buf))
        (should-not called)
        (should-not agent--before-exit)))))

(ert-deftest agent-test-before-exit-step-closes-pending-session ()
  "Exit a session when its before-exit chain has drained."
  (let ((agent-backends nil)
        ran)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :exit (lambda () (interactive) (setq ran t))))
        (setq-local agent--before-exit '(:queue nil :state running))
        (cl-letf (((symbol-function 'run-at-time)
                   (lambda (_time _repeat function &rest args)
                     (apply function args))))
          (should (agent--before-exit-transition buf 'step))
          (should ran)
          (should (eq (plist-get agent--before-exit :state) 'closing)))))))

(ert-deftest agent-test-before-exit-step-ignores-idle-sessions ()
  "Do not consume stop events in sessions without a running chain."
  (let ((agent-backends nil)
        ran)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :exit (lambda () (interactive) (setq ran t))))
        (should-not (agent--before-exit-transition buf 'step))
        (should-not ran)))))

(ert-deftest agent-test-before-exit-step-honors-backend-veto ()
  "Do not close while a backend reports unaccepted prompt input."
  (let ((agent-backends nil)
        ran)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :before-exit-ready-to-close-p (lambda (_buffer) nil)
          :exit (lambda () (interactive) (setq ran t))))
        (setq-local agent--before-exit '(:queue nil :state running))
        (should-not (agent--before-exit-transition buf 'step))
        (should-not ran)
        (should (eq (plist-get agent--before-exit :state) 'running))))))

(ert-deftest agent-test-before-exit-step-advances-to-next-skill ()
  "Submit the next queued skill instead of exiting while the chain has more."
  (let ((agent-backends nil)
        (agent-skill-command-prefix-alist '((one . "/")))
        (events nil)
        ran)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :submit-command (lambda (cmd &optional _buffer) (push cmd events))
          :exit (lambda () (interactive) (setq ran t))))
        (setq-local agent--before-exit
                    '(:queue (("update-log" :args "--auto")) :state running))
        (should (agent--before-exit-transition buf 'step))
        (should (equal events '("/update-log --auto")))
        (should-not ran)
        (should-not (plist-get agent--before-exit :queue))
        (should (eq (plist-get agent--before-exit :state) 'running))))))
```

Keep these five tests from the old block with only mechanical edits: `agent-test-run-skill-before-exit-submits-in-matching-directory`, `-prefers-submit-command`, `-uses-claude-slash`, `-skips-other-directories`, `-allows-long-sessions`, `-matches-expanded-directory`, `-skips-unknown-backends` — their bodies contain no flag references and remain valid verbatim, EXCEPT that any backend registration lacking a `:buffer-p` that matches `buf` must gain `:buffer-p (lambda (candidate) (eq candidate buf))` (the new chain detects the backend from the buffer; `agent-run-skill-before-exit` also seeds the cache, so tests calling only that entry point work either way).

Also update the Phase 3 test `agent-test-session-event-chain-suppresses-ready-alert`: change its stub from

```elisp
                ((symbol-function 'agent-exit-after-before-exit-skill)
                 (lambda (_backend _buffer) t)))
```

to

```elisp
                ((symbol-function 'agent--before-exit-transition)
                 (lambda (_buffer _event) t)))
```

Run `~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-test.el agent-test-before-exit-chain-advances-on-stop-events` — expect FAILED, `(void-function agent--before-exit-transition)`.

- [ ] Step 2 — replace the variables. Current code, verbatim (agent.el:97–104):

```elisp
(defvar-local agent--before-exit-skill-started nil
  "Non-nil once the before-exit skill chain has begun in this buffer.")

(defvar-local agent--before-exit-skill-remaining nil
  "Before-exit skill entries not yet submitted in this buffer.")

(defvar-local agent--before-exit-skill-exit-pending nil
  "Non-nil when BUFFER should exit after its before-exit skills finish.")
```

Replace with:

```elisp
(defvar-local agent--before-exit nil
  "State of the before-exit skill chain in this session buffer.
Nil when no chain has started.  Otherwise a plist with keys
`:queue' (skill entries not yet submitted), `:state' (`running'
or `closing'), `:started-at' (`float-time' when the chain
started), and `:timer' (the watchdog timer, or nil).  Only
`agent--before-exit-transition' may set this variable.")
```

Leave `agent-before-exit-skill-inhibit` (lines 106–109) untouched. Add the timeout option directly after `agent-before-exit-skill-min-duration-seconds` (lines 82–88):

```elisp
(defcustom agent-before-exit-timeout 600
  "Seconds before an unfinished before-exit skill chain is abandoned.
When a session's chain has run this long without reaching its
exit, the watchdog resets the chain state, warns, and leaves the
session open."
  :type 'number
  :group 'agent)
```

- [ ] Step 3 — replace the chain. Delete these three functions wholesale (locate with `grep -n "defun agent-run-skill-before-exit\|defun agent-exit-after-before-exit-skill\|defun agent--before-exit-skill-send-next" agent.el`; pre-refactor lines 1368–1423, where `agent--before-exit-skill-send-next` carries the Task 3.2 interim body) and insert in their place:

```elisp
(defun agent-run-skill-before-exit (backend buffer)
  "Submit the before-exit skills for BUFFER before BACKEND exits it.
Member of `agent-before-exit-functions'.  Return nil to delay the
exit while the chain runs, and t when there is nothing to run."
  (with-current-buffer buffer
    (setq agent--backend backend))
  (not (agent--before-exit-transition buffer 'start)))

(defun agent--before-exit-transition (buffer event)
  "Advance the before-exit chain in BUFFER for EVENT.
EVENT is one of the symbols `start', `step', and `abort'.  This
function is the only writer of `agent--before-exit'.  Return
non-nil when the chain consumed the event."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (pcase event
        ('start (agent--before-exit-start buffer))
        ('step (agent--before-exit-step buffer))
        ('abort (agent--before-exit-abort buffer))
        (_ (error "Unknown before-exit event: %s" event))))))

(defun agent--before-exit-start (buffer)
  "Start the before-exit skill chain in BUFFER.
Return non-nil when a chain started and the exit must wait.
Return nil when a chain is already running, the buffer inhibits
the chain, no skill applies, or nothing could be submitted."
  (unless (or agent--before-exit agent-before-exit-skill-inhibit)
    (let* ((backend (agent--detect-backend buffer))
           (queue (agent--before-exit-skill-queue backend buffer)))
      (when queue
        (setq agent--before-exit
              (list :queue queue
                    :state 'running
                    :started-at (float-time)
                    :timer (agent--before-exit-start-watchdog buffer)))
        (if (agent--before-exit-submit-next buffer)
            t
          (agent--before-exit-reset)
          nil)))))

(defun agent--before-exit-step (buffer)
  "Advance BUFFER's running before-exit chain on a stop event.
Submit the next queued skill, or schedule the exit once the queue
is drained.  When the backend's readiness veto applies, leave the
chain untouched so it is re-checked on the next stop event.
Return non-nil when the chain consumed the event."
  (when (eq (plist-get agent--before-exit :state) 'running)
    (let ((backend (agent--detect-backend buffer)))
      (when (agent--before-exit-ready-to-close-p backend buffer)
        (if (and (plist-get agent--before-exit :queue)
                 (agent--before-exit-submit-next buffer))
            t
          (agent--before-exit-close buffer backend))))))

(defun agent--before-exit-abort (buffer)
  "Abandon BUFFER's before-exit chain, leaving the session open."
  (when agent--before-exit
    (agent--before-exit-reset)
    (message "agent: before-exit skills timed out in %s; leaving session open"
             (buffer-name buffer))
    t))

(defun agent--before-exit-close (buffer backend)
  "Mark BUFFER's chain as closing and schedule BACKEND's exit."
  (agent--before-exit-cancel-watchdog)
  (setq agent--before-exit (plist-put agent--before-exit :state 'closing))
  (agent-session-event buffer 'exit-request)
  (run-at-time 0 nil #'agent--exit-after-before-exit-skill backend buffer)
  t)

(defun agent--before-exit-submit-next (buffer)
  "Submit the next queued before-exit skill in BUFFER.
Skip entries that yield no command, and return non-nil when one
is submitted."
  (let ((backend (agent--detect-backend buffer))
        sent)
    (while (and (not sent) (plist-get agent--before-exit :queue))
      (let* ((queue (plist-get agent--before-exit :queue))
             (entry (car queue))
             (command (agent--before-exit-skill-command backend entry)))
        (setq agent--before-exit
              (plist-put agent--before-exit :queue (cdr queue)))
        (when (and command
                   (or (agent--backend-get backend :submit-command)
                       (agent--backend-get backend :send-command)))
          (agent-submit command buffer)
          (message "Started %s; this session will close when the before-exit skills finish"
                   command)
          (setq sent t))))
    sent))

(defun agent--before-exit-reset ()
  "Clear the current buffer's chain state and watchdog."
  (agent--before-exit-cancel-watchdog)
  (setq agent--before-exit nil))

(defun agent--before-exit-start-watchdog (buffer)
  "Return a timer that aborts BUFFER's chain after the timeout."
  (run-at-time agent-before-exit-timeout nil
               #'agent--before-exit-watchdog-fire buffer))

(defun agent--before-exit-watchdog-fire (buffer)
  "Abort the before-exit chain in BUFFER when the watchdog expires."
  (when (buffer-live-p buffer)
    (agent--before-exit-transition buffer 'abort)))

(defun agent--before-exit-cancel-watchdog ()
  "Cancel the current buffer's before-exit watchdog timer, if any."
  (when-let* ((timer (plist-get agent--before-exit :timer)))
    (cancel-timer timer)
    (setq agent--before-exit (plist-put agent--before-exit :timer nil))))

(defun agent--before-exit-teardown ()
  "Cancel the before-exit watchdog when a session buffer is killed."
  (agent--before-exit-cancel-watchdog))
```

Keep `agent--before-exit-ready-to-close-p` (agent.el:1425–1431), `agent--exit-after-before-exit-skill` (1433–1438), and all the queue/entry/command helpers (1440–1507) unchanged.

- [ ] Step 4 — swap the call inside `agent--session-event-awaiting-input` (added in Task 3.1). Change

```elisp
  (unless (agent-exit-after-before-exit-skill
           (agent--detect-backend buffer) buffer)
```

to

```elisp
  (unless (agent--before-exit-transition buffer 'step)
```

- [ ] Step 5 — register the kill-buffer teardown. At the hook block at the bottom of `agent.el` (`grep -n "add-hook 'agent-before-exit-functions" agent.el`, line ~2084), add directly after it:

```elisp
;; Phase 7 moves this into the agent minor mode's teardown.
(add-hook 'kill-buffer-hook #'agent--before-exit-teardown)
```

- [ ] Step 6 — confirm no stale symbols remain:

```bash
cd "/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent"
grep -rn "before-exit-skill-started\|before-exit-skill-remaining\|before-exit-skill-exit-pending\|agent-exit-after-before-exit-skill\|agent--before-exit-skill-send-next" *.el test/agent-test.el test/agent-claude-test.el test/agent-chief-test.el
```

Expected: zero hits (test/agent-codex-test.el still has one stale reference at ~line 544; it is rewritten in Task 4.2, so the codex suite is expected to fail until then).

- [ ] Step 7 — verify: `elisp-ert agent test/agent-test.el`, `elisp-ert agent test/agent-claude-test.el`, `elisp-ert agent test/agent-chief-test.el`, `batch-test.sh agent` — all pass.

- [ ] Step 8 — commit:

```bash
git -C "/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent" add agent.el test/agent-test.el
git -C "/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent" commit -m "agent: replace before-exit flags with chain state machine"
```

### Task 4.2: Codex readiness veto via public `codex-prompt-input` (tests first)

**Files:**
- `/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/agent-codex.el` (lines 276–320)
- `/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/test/agent-codex-test.el` (lines 472–552)

- [ ] Step 1 — rewrite the readiness tests. Replace the six glyph-based tests (`agent-codex-test-before-exit-ready-vetoes-pending-prompt` through `agent-codex-test-before-exit-ready-ignores-stale-heavy-prompt-echo`, lines 472–529) with two stub-based tests (the glyph parsing now lives upstream in `codex-prompt-input`, which codex.el's own suite covers):

```elisp
(ert-deftest agent-codex-test-before-exit-ready-vetoes-pending-prompt ()
  "Do not auto-close while Codex still has prompt input."
  (with-temp-buffer
    (cl-letf (((symbol-function 'codex-prompt-input)
               (lambda (&optional _buffer) "git status")))
      (should-not (agent-codex-before-exit-ready-to-close-p
                   (current-buffer))))))

(ert-deftest agent-codex-test-before-exit-ready-allows-empty-prompt ()
  "Allow auto-close when Codex is back at an empty prompt."
  (with-temp-buffer
    (cl-letf (((symbol-function 'codex-prompt-input)
               (lambda (&optional _buffer) nil)))
      (should (agent-codex-before-exit-ready-to-close-p
               (current-buffer))))))
```

Then replace `agent-codex-test-stop-closes-after-submitted-before-exit-skill` (lines 531–552) with:

```elisp
(ert-deftest agent-codex-test-stop-closes-after-submitted-before-exit-skill ()
  "Close a pending before-exit session when the submitted skill finishes."
  (let ((buf (generate-new-buffer "*codex:/tmp/project/*"))
        ran)
    (unwind-protect
        (cl-letf (((symbol-function 'codex-prompt-input)
                   (lambda (&optional _buffer) nil))
                  ((symbol-function 'run-at-time)
                   (lambda (_time _repeat function &rest args)
                     (apply function args)))
                  ((symbol-function 'agent-codex-exit)
                   (lambda () (interactive) (setq ran t))))
          (with-current-buffer buf
            (setq-local agent--backend 'codex)
            (setq-local agent--before-exit '(:queue nil :state running)))
          (agent-codex--handle-notification
           (list :type "Stop" :buffer-name (buffer-name buf)))
          (should ran)
          (with-current-buffer buf
            (should (eq (plist-get agent--before-exit :state) 'closing))))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))
```

Run the first test — it currently passes by accident only if the glyph path agrees; after Step 2 it must pass via the stub. Run the third — expect FAILED before Step 2 only if `codex-prompt-input` stubbing diverges; in any case all three must pass after Step 2.

- [ ] Step 2 — rewrite the veto and delete the glyph helpers. Current code, verbatim (agent-codex.el:276–320):

```elisp
(defun agent-codex-before-exit-ready-to-close-p (&optional buffer)
  "Return non-nil when BUFFER has no pending Codex prompt input."
  (when-let* ((codex-buffer (agent-codex--target-buffer buffer)))
    (with-current-buffer codex-buffer
      (not (agent-codex--current-prompt-input)))))
```

Replace with:

```elisp
(defun agent-codex-before-exit-ready-to-close-p (&optional buffer)
  "Return non-nil when BUFFER has no pending Codex prompt input."
  (when-let* ((codex-buffer (agent-codex--target-buffer buffer)))
    (not (codex-prompt-input codex-buffer))))
```

Then delete these six helpers entirely (lines 282–320): `agent-codex--current-prompt-input`, `agent-codex--prompt-input-at-cursor`, `agent-codex--last-prompt-input`, `agent-codex--prompt-input-on-current-line`, `agent-codex--nonempty-prompt-input`, `agent-codex--prompt-autosuggestion-p`. Confirm they have no other callers first: `grep -n "agent-codex--current-prompt-input\|agent-codex--prompt-input\|agent-codex--nonempty-prompt-input\|agent-codex--prompt-autosuggestion-p\|agent-codex--last-prompt-input" agent-codex.el test/agent-codex-test.el` must show only the definitions and the tests rewritten in Step 1.

- [ ] Step 3 — verify: `elisp-ert agent test/agent-codex-test.el` and `batch-test.sh agent`. All pass. Also confirm the four-flag grep is now globally clean:

```bash
grep -rn "before-exit-skill-started\|before-exit-skill-remaining\|before-exit-skill-exit-pending" "/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent" --include="*.el"
```

Expected: zero hits.

- [ ] Step 4 — commit:

```bash
git -C "/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent" add agent-codex.el test/agent-codex-test.el
git -C "/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent" commit -m "agent-codex: read before-exit readiness from codex-prompt-input"
```

### Task 4.3: Final sweep, full verification, and documentation

**Files:**
- `/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/README.org` (before-exit section, lines ~210–244)
- all source and test files (greps only)

- [ ] Step 1 — global stale-symbol sweep; every command must return nothing:

```bash
cd "/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent"
grep -rn "agent--waiting-for-input" --include="*.el" .
grep -rn "agent--clear-waiting-for-input" --include="*.el" .
grep -rn "agent--waiting-face" --include="*.el" .
grep -rn "before-exit-skill-started\|before-exit-skill-remaining\|before-exit-skill-exit-pending" --include="*.el" .
grep -rn "agent-exit-after-before-exit-skill\|agent--before-exit-skill-send-next" --include="*.el" .
grep -rn "agent-claude--scroll-to-bottom\|agent-codex--current-prompt-input" --include="*.el" .
```

- [ ] Step 2 — run the complete verification matrix:

```bash
cd "/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent"
~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-test.el
~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-claude-test.el
~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-codex-test.el
~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-chief-test.el
~/My\ Drive/dotfiles/claude/bin/batch-test.sh agent
```

All suites: `Ran N tests, N results as expected`, exit 0.

- [ ] Step 3 — update README.org. In the before-exit section (lines ~210–244), after the paragraph describing `agent-before-exit-skill-min-duration-seconds`, add:

```org
The chain is driven by session stop events and guarded by a watchdog:
if the skills have not finished within ~agent-before-exit-timeout~
seconds (default 600), the chain is abandoned with a warning and the
session is left open instead of being stranded.
```

Also fix any README sentence that names the removed flag variables (search the file for `before-exit-skill-started`, `exit-pending`; pre-refactor none are documented, so this is likely a no-op).

- [ ] Step 4 — commit:

```bash
git -C "/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent" add README.org
git -C "/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent" commit -m "agent: document before-exit watchdog timeout"
```

**Phase 4 definition of done:** all four ERT suites and the load check pass; all Step 1 greps in Task 4.3 are empty; the four legacy flags exist nowhere except `agent-before-exit-skill-inhibit` (kept as the public opt-out, still set by both handoff flows at agent-claude.el:2641 and agent-codex.el:1252); `agent--before-exit` is written only inside `agent--before-exit-transition` and its helpers; the watchdog timer is cancelled on chain close, on abort, and from `kill-buffer-hook`. Not verified end-to-end: a live exit through a real Codex/Claude session running actual before-exit skills, and a real watchdog expiry after 600 s — both require an interactive session and should be smoke-tested manually after the phase lands (start a session, run `agent-exit` with `agent-before-exit-skill-name` set, watch the chain submit, close, and clean up).

## Phase 5 — Unified account module

**Goal.** Collapse the five-way duplication of account identity (global cache, pending dynamic, buffer-local, persisted file, live env var) into one module, `agent-account.el`, with a single resolution order, a single symlink-healing policy (the codex one), pure env hooks, and one transient infix class. All per-backend copies of the machinery are deleted from `agent-claude.el` and `agent-codex.el`.

**Package root (all paths absolute):** `/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/`

**Dotfiles repo (Task 5.7 only):** `/Users/pablostafforini/My Drive/dotfiles/`

**Verification commands (used throughout):**

```bash
# Load check (byte-compile/load all package files):
~/My\ Drive/dotfiles/claude/bin/batch-test.sh agent
# Run a test file (optionally a single test NAME):
~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-account-test.el
~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-test.el
~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-claude-test.el
~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-codex-test.el
```

**Conventions (apply to every task):** atomic small functions; helpers after callers; no blank lines inside function bodies; docstrings document arguments in CAPS, first line is one sentence, filled to 80 columns; error messages do not end with a period. One commit per task, message format `<scope>: <description>` (lowercase imperative).

### Phase 5 preamble — pin down the Phase 1–4 API names (do this before every task)

This plan is written against the locked Phase 1–4 contract. Code quoted as "current code" below was read verbatim from the pre-refactor tree; Phases 1–4 do not touch the account machinery itself, but line numbers may have drifted — **always locate edits by the quoted code or function name, never by line number alone.** Run these greps once and record the answers; if a name differs from the expectation in parentheses, substitute it consistently everywhere in this phase — do not redesign:

```bash
cd "/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent"
grep -n "cl-defstruct (agent-session" agent.el      # constructor (expect make-agent-session); slots: backend account directory instance id
grep -n "(defun agent-session " agent.el            # buffer accessor (expect (agent-session &optional buffer))
grep -n "agent--session\b" agent.el | head -5       # buffer-local session variable name (expect agent--session)
grep -n "agent-start-session" agent.el              # core start entry (expect (agent-start-session session &key initial-prompt resume-id))
grep -n "agent--capture-session" agent.el           # Phase 1 session capture hook
grep -n "cl-defstruct (agent-backend" agent.el      # backend struct; confirm slots account-env-var accounts account-file shared-config-items account-init exist
grep -n "defun agent--backend-get" agent.el         # keyword shim (expect (agent--backend-get BACKEND KEY) resolving keywords to struct slots)
grep -n "defvar agent-backends" agent.el            # registry alist of (SYMBOL . backend)
grep -n "start-session" agent-claude.el agent-codex.el  # backend start-session implementations (Phase 2-4)
```

Two contract notes used below:

1. **`canonical-home` slot.** The Phase 1 slot list (`account-env-var`, `accounts`, `account-file`, `shared-config-items`, `account-init`) has no home for the canonical shared directory (`~/.claude/` vs `~/.codex/`), which the symlink farm needs. Phase 5 adds **one** slot, `canonical-home`, to the `agent-backend` struct (Task 5.3, step 1). This is a deliberate, minimal extension of the locked slot list.
2. **Slot indirection.** Tests and users let-bind `agent-claude-accounts`, `agent-codex-account-file`, etc. So the backend registrations populate `accounts`/`account-file`/`shared-config-items` with **symbols naming the live variables**, and `agent-account.el` resolves indirections (symbol → `symbol-value`, function → `funcall`) at read time via `agent-account--backend-value`. This honors the "list or function" contract for `accounts` and keeps the defcustoms authoritative.

---

### Task 5.1: Write the test suite for the new module (TDD)

**Files:** `/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/test/agent-account-test.el` (new)

- [ ] Create `test/agent-account-test.el` with exactly this content:

```elisp
;;; agent-account-test.el --- Tests for agent-account -*- lexical-binding: t -*-

;; Tests for the unified multi-account module.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'agent)
(require 'agent-account)

(defvar agent-account-test--accounts nil
  "Accounts alist bound by indirection tests.")

(defmacro agent-account-test--with-backend (spec &rest body)
  "Run BODY with `agent--backend-get' serving SPEC for backend `stub'.
SPEC is an expression evaluating to a plist of backend slot keywords.
Also isolates the account cache and the starting binding."
  (declare (indent 1))
  `(let ((agent-account-test--spec ,spec)
         (agent-account--current (make-hash-table :test #'eq))
         (agent-account--starting nil))
     (cl-letf (((symbol-function 'agent--backend-get)
                (lambda (_backend key)
                  (plist-get agent-account-test--spec key))))
       ,@body)))

;;;; Resolution order

(ert-deftest agent-account-test-resolve-prefers-starting-binding ()
  "Prefer the in-flight start binding over the persisted account."
  (agent-account-test--with-backend
      (list :accounts '(("work" . "/tmp/w") ("personal" . "/tmp/p")))
    (puthash 'stub "personal" agent-account--current)
    (let ((agent-account--starting '(stub . "work")))
      (should (equal (agent-account-resolve 'stub) "work")))))

(ert-deftest agent-account-test-resolve-ignores-foreign-starting-binding ()
  "Ignore a starting binding that belongs to another backend."
  (agent-account-test--with-backend
      (list :accounts '(("work" . "/tmp/w") ("personal" . "/tmp/p")))
    (puthash 'stub "personal" agent-account--current)
    (let ((agent-account--starting '(other . "work")))
      (should (equal (agent-account-resolve 'stub) "personal")))))

(ert-deftest agent-account-test-resolve-loads-persisted-account ()
  "Load the persisted account from the account file on first use."
  (let ((file (make-temp-file "agent-account")))
    (unwind-protect
        (agent-account-test--with-backend
            (list :accounts '(("work" . "/tmp/w") ("personal" . "/tmp/p"))
                  :account-file file)
          (with-temp-file file
            (insert "work\n"))
          (should (equal (agent-account-resolve 'stub) "work")))
      (delete-file file))))

(ert-deftest agent-account-test-load-ignores-stale-selection ()
  "Ignore account-file contents not present in configured accounts."
  (let ((file (make-temp-file "agent-account")))
    (unwind-protect
        (agent-account-test--with-backend
            (list :accounts '(("work" . "/tmp/w") ("personal" . "/tmp/p"))
                  :account-file file)
          (with-temp-file file
            (insert "missing\n"))
          (should-not (agent-account-current 'stub)))
      (delete-file file))))

(ert-deftest agent-account-test-resolve-does-not-prompt-by-default ()
  "Never prompt when PROMPT-P is nil."
  (agent-account-test--with-backend
      (list :accounts '(("work" . "/tmp/w") ("personal" . "/tmp/p")))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) (error "should not prompt"))))
      (should-not (agent-account-resolve 'stub)))))

(ert-deftest agent-account-test-resolve-prompts-and-persists-when-allowed ()
  "Prompt when PROMPT-P is non-nil and persist the chosen account."
  (let ((file (make-temp-file "agent-account")))
    (unwind-protect
        (agent-account-test--with-backend
            (list :accounts '(("work" . "/tmp/w") ("personal" . "/tmp/p"))
                  :account-file file)
          (delete-file file)
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (&rest _) "personal")))
            (should (equal (agent-account-resolve 'stub t) "personal")))
          (should (equal (agent-account-current 'stub) "personal"))
          (should (string-match-p "personal"
                                  (with-temp-buffer
                                    (insert-file-contents file)
                                    (buffer-string)))))
      (when (file-exists-p file)
        (delete-file file)))))

(ert-deftest agent-account-test-resolve-nil-without-accounts ()
  "Return nil when the backend has no accounts configured."
  (agent-account-test--with-backend (list :accounts nil)
    (should-not (agent-account-resolve 'stub t))))

(ert-deftest agent-account-test-prompt-skips-single-account ()
  "Return the single configured account without prompting."
  (agent-account-test--with-backend
      (list :accounts '(("work" . "/tmp/w")))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) (error "should not prompt"))))
      (should (equal (agent-account-resolve 'stub t) "work")))))

(ert-deftest agent-account-test-set-updates-cache-and-file ()
  "Update both the cache and the account file from `agent-account-set'."
  (let ((file (make-temp-file "agent-account")))
    (unwind-protect
        (agent-account-test--with-backend
            (list :accounts '(("work" . "/tmp/w") ("personal" . "/tmp/p"))
                  :account-file file)
          (agent-account-set 'stub "work")
          (should (equal (agent-account-current 'stub) "work"))
          (should (string-match-p "work"
                                  (with-temp-buffer
                                    (insert-file-contents file)
                                    (buffer-string)))))
      (delete-file file))))

(ert-deftest agent-account-test-accounts-slot-symbol-indirection ()
  "Resolve an accounts slot holding a symbol naming a live variable."
  (let ((agent-account-test--accounts '(("work" . "/tmp/w"))))
    (agent-account-test--with-backend
        (list :accounts 'agent-account-test--accounts)
      (should (equal (agent-account-home 'stub "work") "/tmp/w")))))

;;;; Env purity

(ert-deftest agent-account-test-env-returns-var-and-home ()
  "Format the backend env var with the account's expanded home."
  (agent-account-test--with-backend
      (list :accounts '(("work" . "/tmp/w"))
            :account-env-var "STUB_HOME")
    (should (equal (agent-account-env 'stub "work")
                   '("STUB_HOME=/tmp/w")))))

(ert-deftest agent-account-test-env-nil-for-unknown-account ()
  "Return nil for accounts that are not configured."
  (agent-account-test--with-backend
      (list :accounts '(("work" . "/tmp/w"))
            :account-env-var "STUB_HOME")
    (should-not (agent-account-env 'stub "missing"))))

(ert-deftest agent-account-test-env-never-touches-filesystem ()
  "Never mutate the filesystem from `agent-account-env'."
  (agent-account-test--with-backend
      (list :accounts '(("work" . "/tmp/w"))
            :account-env-var "STUB_HOME")
    (let (calls)
      (cl-letf (((symbol-function 'make-symbolic-link)
                 (lambda (&rest _) (push 'make-symbolic-link calls)))
                ((symbol-function 'rename-file)
                 (lambda (&rest _) (push 'rename-file calls)))
                ((symbol-function 'delete-file)
                 (lambda (&rest _) (push 'delete-file calls)))
                ((symbol-function 'delete-directory)
                 (lambda (&rest _) (push 'delete-directory calls)))
                ((symbol-function 'make-directory)
                 (lambda (&rest _) (push 'make-directory calls)))
                ((symbol-function 'write-region)
                 (lambda (&rest _) (push 'write-region calls))))
        (should (equal (agent-account-env 'stub "work")
                       '("STUB_HOME=/tmp/w")))
        (should-not calls)))))

;;;; Symlink healing policy

(defmacro agent-account-test--with-homes (&rest body)
  "Run BODY with temp CANONICAL and HOME dirs and a stub backend."
  (declare (indent 0))
  `(let* ((dir (make-temp-file "agent-account" t))
          (canonical (expand-file-name "canonical" dir))
          (home (expand-file-name "work" dir)))
     (unwind-protect
         (agent-account-test--with-backend
             (list :accounts `(("work" . ,home))
                   :canonical-home canonical
                   :shared-config-items '("config.toml" "skills"))
           (make-directory (expand-file-name "skills" canonical) t)
           (with-temp-file (expand-file-name "config.toml" canonical)
             (insert "model = \"gpt\"\n"))
           ,@body)
       (delete-directory dir t))))

(ert-deftest agent-account-test-sync-creates-missing-symlinks ()
  "Symlink shared items from the canonical home into the account home."
  (agent-account-test--with-homes
    (agent-account-sync 'stub "work")
    (dolist (item '("config.toml" "skills"))
      (let ((target (expand-file-name item home)))
        (should (file-symlink-p target))
        (should (equal (file-truename target)
                       (file-truename (expand-file-name item canonical))))))))

(ert-deftest agent-account-test-sync-repoints-wrong-symlink ()
  "Back up and re-point a symlink that targets the wrong location."
  (agent-account-test--with-homes
    (make-directory home t)
    (with-temp-file (expand-file-name "elsewhere" dir)
      (insert "other\n"))
    (make-symbolic-link (expand-file-name "elsewhere" dir)
                        (expand-file-name "config.toml" home))
    (agent-account-sync 'stub "work")
    (let ((target (expand-file-name "config.toml" home)))
      (should (equal (file-truename target)
                     (file-truename (expand-file-name "config.toml" canonical))))
      (should (= 1 (length (file-expand-wildcards
                            (expand-file-name
                             "config.toml.agent-backup-*" home))))))))

(ert-deftest agent-account-test-sync-replaces-virgin-file-without-backup ()
  "Replace empty or placeholder files with symlinks, without backups."
  (agent-account-test--with-homes
    (make-directory home t)
    (with-temp-file (expand-file-name "config.toml" home)
      (insert "{}"))
    (agent-account-sync 'stub "work")
    (should (file-symlink-p (expand-file-name "config.toml" home)))
    (should-not (file-expand-wildcards
                 (expand-file-name "config.toml.agent-backup-*" home)))))

(ert-deftest agent-account-test-sync-backs-up-real-content ()
  "Back up files with real content to a timestamped sibling, then link."
  (agent-account-test--with-homes
    (make-directory home t)
    (with-temp-file (expand-file-name "config.toml" home)
      (insert "model = \"account-local-override\"\n"))
    (agent-account-sync 'stub "work")
    (let ((backups (file-expand-wildcards
                    (expand-file-name "config.toml.agent-backup-*" home))))
      (should (file-symlink-p (expand-file-name "config.toml" home)))
      (should (= 1 (length backups)))
      (with-temp-buffer
        (insert-file-contents (car backups))
        (should (string-match-p "account-local-override" (buffer-string)))))))

(ert-deftest agent-account-test-sync-leaves-correct-symlink-alone ()
  "Do nothing for symlinks that already point at the canonical item."
  (agent-account-test--with-homes
    (make-directory home t)
    (make-symbolic-link (expand-file-name "config.toml" canonical)
                        (expand-file-name "config.toml" home))
    (agent-account-sync 'stub "work")
    (should (file-symlink-p (expand-file-name "config.toml" home)))
    (should-not (file-expand-wildcards
                 (expand-file-name "config.toml.agent-backup-*" home)))))

(ert-deftest agent-account-test-sync-runs-account-init ()
  "Run the backend's account-init step after creating the home."
  (let* ((dir (make-temp-file "agent-account" t))
         (home (expand-file-name "work" dir))
         init-args)
    (unwind-protect
        (agent-account-test--with-backend
            (list :accounts `(("work" . ,home))
                  :canonical-home dir
                  :shared-config-items nil
                  :account-init (lambda (account) (push account init-args)))
          (agent-account-sync 'stub "work")
          (should (file-directory-p home))
          (should (equal init-args '("work"))))
      (delete-directory dir t))))

;;;; Selection

(ert-deftest agent-account-test-select-persists-and-syncs ()
  "Persist the chosen account and sync its home on selection."
  (let ((file (make-temp-file "agent-account"))
        synced)
    (unwind-protect
        (agent-account-test--with-backend
            (list :accounts '(("work" . "/tmp/w") ("personal" . "/tmp/p"))
                  :account-file file)
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (&rest _) "personal"))
                    ((symbol-function 'agent-account-sync)
                     (lambda (backend account)
                       (setq synced (cons backend account)))))
            (agent-account-select 'stub))
          (should (equal (agent-account-current 'stub) "personal"))
          (should (equal synced '(stub . "personal"))))
      (delete-file file))))

(provide 'agent-account-test)
;;; agent-account-test.el ends here
```

- [ ] Run the suite and confirm it fails only because the module does not exist yet:

```bash
~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-account-test.el
```

Expected output: a load error of the form `Cannot open load file: ... agent-account`. Do **not** commit yet; the commit lands with the module in Task 5.2.

### Task 5.2: Implement `agent-account.el`

**Files:** `/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/agent-account.el` (new); `test/agent-account-test.el` (from Task 5.1)

- [ ] Create `agent-account.el` with exactly this content (header mirrors `agent-codex.el`):

```elisp
;;; agent-account.el --- Unified account handling for agent backends -*- lexical-binding: t -*-

;; Copyright (C) 2026

;; Author: Pablo Stafforini
;; URL: https://github.com/benthamite/agent
;; Version: 0.1
;; Package-Requires: ((emacs "29.1") (transient "0.9"))

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

;; Single home for multi-account state shared by all agent backends.
;; Account identity lives in exactly two places: the persisted current
;; account (file-backed, cached in `agent-account--current') and the
;; per-session account recorded in the `agent-session' struct.  The
;; only dynamic variable is `agent-account--starting', let-bound by
;; `agent-start-session' around the backend start call so that
;; process-environment hooks see the session's account at spawn time.
;;
;; `agent-account-env' is pure: filesystem syncing of per-account
;; config homes happens only in `agent-account-sync', called from
;; account selection, account initialization, and the defensive sync
;; in `agent-start-session' -- never from process-environment hooks.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'transient)

(defvar agent-backends)
(declare-function agent--backend-get "agent" (backend key))

;;;; Variables

(defvar agent-account--starting nil
  "Backend and account of the session currently being started.
A cons of (BACKEND . ACCOUNT) let-bound by `agent-start-session'
around the backend start call.  Process-environment hooks that run
during process spawn consult this before the persisted current
account, so the spawned process gets the session's account even
when it differs from the global selection.  This is the only
account-related dynamic variable in the package.")

(defvar agent-account--current (make-hash-table :test #'eq)
  "Cache of the current account per backend symbol.
Values are account name strings, or the symbol `none' when the
backend's account file held no valid selection.  Backed by each
backend's account file; see `agent-account-current' and
`agent-account-set'.")

;;;; Commands

;;;###autoload
(defun agent-account-select (backend)
  "Interactively switch BACKEND's current account.
Prompts for an account, persists the selection, and syncs the
account's config home.  New sessions will use this account.
Returns the account name, or nil when the prompt was quit."
  (interactive (list (agent-account--read-backend)))
  (unless (agent-account-list backend)
    (user-error "No accounts configured for backend `%s'" backend))
  (when-let* ((account (agent-account--prompt backend)))
    (agent-account-set backend account)
    (agent-account-sync backend account)
    (message "Switched %s to account: %s" backend account)
    account))

;;;###autoload
(defun agent-account-init (backend account)
  "Create or repair ACCOUNT's config home for BACKEND.
Creates the home directory, installs the shared symlinks, and runs
the backend's optional account-init step.  Safe to call on an
already-initialized account.  Does not change the persisted
current account."
  (interactive
   (let ((backend (agent-account--read-backend)))
     (list backend
           (completing-read "Initialize account: "
                            (mapcar #'car (agent-account-list backend))
                            nil t))))
  (unless (agent-account-home backend account)
    (user-error "Account %S is not configured for backend `%s'"
                account backend))
  (agent-account-sync backend account)
  (message "Initialized %s account: %s" backend account))

(defun agent-account--read-backend ()
  "Prompt for a registered backend that has accounts configured."
  (let ((candidates (cl-remove-if-not #'agent-account-list
                                      (mapcar #'car agent-backends))))
    (pcase candidates
      ('nil (user-error "No backend has accounts configured"))
      (`(,only) only)
      (_ (intern (completing-read "Backend: "
                                  (mapcar #'symbol-name candidates)
                                  nil t))))))

;;;; Resolution

(defun agent-account-resolve (backend &optional prompt-p)
  "Return the account to use for BACKEND, or nil.
Resolution order: the in-flight `agent-account--starting' binding
when it belongs to BACKEND, then the persisted current account,
then -- only when PROMPT-P is non-nil -- an interactive prompt
whose choice is persisted.  Returns nil when BACKEND has no
accounts configured."
  (when (agent-account-list backend)
    (or (and (eq (car-safe agent-account--starting) backend)
             (cdr agent-account--starting))
        (agent-account-current backend)
        (when prompt-p
          (when-let* ((account (agent-account--prompt backend)))
            (agent-account-set backend account))))))

(defun agent-account-current (backend)
  "Return the account used for new BACKEND sessions, or nil.
Loads the persisted selection from the backend's account file on
first use and caches it; `agent-account-set' updates both."
  (let ((cached (gethash backend agent-account--current 'unset)))
    (when (eq cached 'unset)
      (setq cached (or (agent-account--load backend) 'none))
      (puthash backend cached agent-account--current))
    (unless (eq cached 'none)
      cached)))

(defun agent-account-set (backend account)
  "Persist ACCOUNT as the current account for BACKEND.
Updates the in-memory cache and the backend's account file.
Returns ACCOUNT."
  (puthash backend account agent-account--current)
  (agent-account--save backend account)
  account)

(defun agent-account--prompt (backend)
  "Prompt for one of BACKEND's accounts and return its name, or nil.
Returns the single account without prompting when only one exists."
  (when-let* ((names (mapcar #'car (agent-account-list backend))))
    (if (= (length names) 1)
        (car names)
      (completing-read (format "%s account: " backend) names nil t))))

(defun agent-account--load (backend)
  "Read BACKEND's persisted account name from its account file.
Return nil when the file is missing or names an account that is
not configured."
  (when-let* ((file (agent-account--file backend)))
    (when (file-exists-p file)
      (let ((name (string-trim
                   (with-temp-buffer
                     (insert-file-contents file)
                     (buffer-string)))))
        (when (alist-get name (agent-account-list backend) nil nil #'string=)
          name)))))

(defun agent-account--save (backend account)
  "Write ACCOUNT to BACKEND's account file."
  (when-let* ((file (agent-account--file backend)))
    (with-temp-file file
      (insert account "\n"))))

(defun agent-account--file (backend)
  "Return BACKEND's account persistence file, or nil."
  (agent-account--backend-value backend :account-file))

;;;; Environment

(defun agent-account-env (backend account)
  "Return process environment entries for BACKEND running as ACCOUNT.
The result is a list of \"VAR=VALUE\" strings, or nil when ACCOUNT
has no configured home.  This function is pure: it never touches
the filesystem.  Config-home syncing happens in
`agent-account-sync', which runs from selection, initialization,
and `agent-start-session' -- never from process-environment hooks."
  (when-let* ((var (agent--backend-get backend :account-env-var))
              (home (agent-account-home backend account)))
    (list (format "%s=%s" var home))))

(defun agent-account-home (backend account)
  "Return the expanded config home directory for BACKEND's ACCOUNT.
Return nil when ACCOUNT is nil or not configured."
  (when-let* ((dir (alist-get account (agent-account-list backend)
                              nil nil #'string=)))
    (expand-file-name dir)))

(defun agent-account-list (backend)
  "Return the accounts alist for BACKEND.
Each entry is (NAME . HOME-DIRECTORY).  The backend's accounts
slot may hold an alist, a function returning one, or a symbol
naming a variable holding one."
  (agent-account--backend-value backend :accounts))

(defun agent-account--backend-value (backend key)
  "Return BACKEND's KEY slot value, resolving indirections.
Bound symbols are dereferenced and functions are called, so
backend registrations can point at live defcustoms."
  (let ((value (agent--backend-get backend key)))
    (cond
     ((and value (symbolp value) (boundp value)) (symbol-value value))
     ((functionp value) (funcall value))
     (t value))))

;;;; Config-home sync

(defun agent-account-sync (backend account)
  "Sync shared state into BACKEND ACCOUNT's config home.
Creates the home directory, ensures each item in the backend's
shared-config-items slot is a symlink to the canonical home, and
runs the backend's optional account-init function.  Errors are
demoted to messages so session startup never aborts on a sync
failure."
  (when-let* ((home (agent-account-home backend account)))
    (make-directory home t)
    (condition-case err
        (progn
          (agent-account--ensure-shared-symlinks backend home)
          (when-let* ((fn (agent--backend-get backend :account-init)))
            (funcall fn account)))
      (error
       (message "agent-account: failed to sync %s account %s: %S"
                backend account err)))))

(defun agent-account--ensure-shared-symlinks (backend home)
  "Ensure shared config symlinks exist in BACKEND's account HOME."
  (when-let* ((canonical (agent-account--canonical-home backend)))
    (dolist (item (agent-account--backend-value backend :shared-config-items))
      (agent-account--ensure-shared-symlink
       (expand-file-name item canonical)
       (expand-file-name item home)))))

(defun agent-account--canonical-home (backend)
  "Return BACKEND's canonical config home directory, or nil."
  (when-let* ((dir (agent-account--backend-value backend :canonical-home)))
    (expand-file-name dir)))

(defun agent-account--ensure-shared-symlink (source target)
  "Ensure TARGET is a symlink pointing at SOURCE.
Create the symlink when TARGET is missing.  Back up and re-point
TARGET when it is a symlink to somewhere else.  Replace TARGET
when it is a virgin-state file or empty directory.  Back TARGET up
to a timestamped sibling before linking when it has real content."
  (when (file-exists-p source)
    (cond
     ((file-symlink-p target)
      (unless (equal (file-truename target) (file-truename source))
        (agent-account--backup-item target)
        (make-symbolic-link source target)
        (message "agent-account: replaced %s with symlink to %s"
                 target source)))
     ((not (file-exists-p target))
      (make-symbolic-link source target)
      (message "agent-account: symlinked %s -> %s" target source))
     ((agent-account--item-virgin-p target)
      (agent-account--delete-item target)
      (make-symbolic-link source target)
      (message "agent-account: replaced virgin %s with symlink to %s"
               target source))
     (t
      (agent-account--backup-item target)
      (make-symbolic-link source target)
      (message "agent-account: backed up and symlinked %s -> %s"
               target source)))))

(defun agent-account--item-virgin-p (path)
  "Return non-nil if PATH is a virgin-state file or empty directory.
An empty directory is virgin.  A zero-byte file is virgin.  A small
JSON file containing only `{}' or `[]' is virgin."
  (cond
   ((file-directory-p path)
    (null (directory-files path nil directory-files-no-dot-files-regexp)))
   ((file-regular-p path)
    (agent-account--file-virgin-p path))))

(defun agent-account--file-virgin-p (path)
  "Return non-nil if regular file PATH has empty or placeholder content."
  (let ((size (file-attribute-size (file-attributes path))))
    (or (zerop size)
        (and (< size 16)
             (member (string-trim
                      (with-temp-buffer
                        (insert-file-contents path)
                        (buffer-string)))
                     '("" "{}" "[]"))))))

(defun agent-account--delete-item (path)
  "Delete PATH, whether it is a file or a directory."
  (if (file-directory-p path)
      (delete-directory path t)
    (delete-file path)))

(defun agent-account--backup-item (path)
  "Move PATH to a timestamped backup path."
  (let* ((timestamp (format-time-string "%Y%m%d%H%M%S"))
         (backup (format "%s.agent-backup-%s" path timestamp))
         (candidate backup)
         (counter 0))
    (while (file-exists-p candidate)
      (setq counter (1+ counter)
            candidate (format "%s.%d" backup counter)))
    (rename-file path candidate)
    (message "agent-account: backed up %s to %s" path candidate)))

;;;; Transient infix

(eval-and-compile
  (defclass agent-account-variable (transient-lisp-variable)
    ((backend :initarg :backend)
     (variable :initform nil))
    "An infix that displays and selects a backend's current account.
The `backend' slot names the registered backend symbol."))

(cl-defmethod transient-infix-read ((obj agent-account-variable))
  "Prompt for one of the backend's accounts."
  (agent-account--prompt (oref obj backend)))

(cl-defmethod transient-infix-set ((obj agent-account-variable) value)
  "Persist VALUE as the backend's current account and sync its home."
  (oset obj value value)
  (when value
    (agent-account-set (oref obj backend) value)
    (agent-account-sync (oref obj backend) value)))

(cl-defmethod transient-init-value ((obj agent-account-variable))
  "Initialize OBJ's value from the persisted current account."
  (oset obj value (agent-account-current (oref obj backend))))

(provide 'agent-account)
;;; agent-account.el ends here
```

Note the symlink-healing policy is the **codex** policy copied verbatim (the four `cond` branches, `--item-virgin-p`, `--file-virgin-p`, `--delete-item`, `--backup-item` from `agent-codex.el:388-452`, prefix-renamed). The claude warn-and-skip variant is intentionally dropped.

- [ ] Run the module tests; all must pass:

```bash
~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-account-test.el
```

- [ ] Run the load check: `~/My\ Drive/dotfiles/claude/bin/batch-test.sh agent` (must report no errors; warnings about the not-yet-populated slots are not expected because the module only reads slots at runtime).
- [ ] Commit both files:

```bash
cd "/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent"
git add agent-account.el test/agent-account-test.el
git commit -m "agent-account: add unified account module"
```

### Task 5.3: Thread accounts through the core (`agent.el`)

**Files:** `/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/agent.el` (struct slot, `agent-start-session`, `agent--capture-session`, switcher sites ~647-656, candidate label ~1080-1087, prompt identity ~1101-1108, accountless labels ~720-728, registry docstring ~125-160); `test/agent-test.el` (~172-187, ~660-678)

- [ ] **Struct slot.** Confirm via the preamble grep that `agent-backend` has slots `account-env-var`, `accounts`, `account-file`, `shared-config-items`, `account-init`. Add a `canonical-home` slot to the `cl-defstruct (agent-backend ...)` definition (same style as the neighboring slots, default nil) if absent. If `agent-register-backend` validates known keywords, add `:canonical-home` to the accepted set.
- [ ] **Require the module.** Add `(require 'agent-account)` to `agent.el`'s require block (after `(require 'transient)` or equivalent). `agent-account.el` deliberately does not require `agent`, so this is not circular.
- [ ] **Defensive sync + single dynamic in `agent-start-session`.** Locate `agent-start-session` (preamble grep). Immediately before the call into the backend's `start-session` implementation, insert the sync and wrap the backend call in the binding:

```elisp
(let* ((backend (agent-session-backend session))
       (account (agent-session-account session)))
  (when account
    (agent-account-sync backend account))
  (let ((agent-account--starting (and account (cons backend account))))
    ;; existing backend start-session invocation goes here, unchanged
    ...))
```

If Phases 2–4 left per-backend `--pending-account` let-bindings inside the backend `start-session` implementations (grep `pending-account` in `agent-claude.el`/`agent-codex.el` start-session code), delete those bindings now — the core binding replaces them. This binding is what `agent-account-env` consults at spawn time; it is **not** set for `codex exec` batch runs, which therefore never sync or prompt.

- [ ] **Capture the account into the session struct.** Locate `agent--capture-session` (Phase 1). Where it constructs or completes the buffer's session struct, populate the account slot from the starting binding when the backend matches, falling back to the persisted account:

```elisp
;; inside agent--capture-session, when filling the session's account slot:
(or (and (eq (car-safe agent-account--starting) backend)
         (cdr agent-account--starting))
    (agent-account-current backend))
```

- [ ] **Migrate the switcher group key.** Replace the current function (quoted verbatim from the pre-refactor tree at `agent.el:647-656`):

```elisp
(defun agent--session-group-key (buffer)
  "Return the group key for BUFFER in the session switcher.
Uses the backend's :account function if available, falling back
to the backend's :label or symbol name."
  (let ((backend (agent--detect-backend buffer)))
    (or (when-let* ((account-fn (agent--backend-get backend :account)))
          (funcall account-fn buffer))
        (agent--backend-get backend :label)
        (and backend (symbol-name backend))
        "Sessions")))
```

with:

```elisp
(defun agent--session-group-key (buffer)
  "Return the group key for BUFFER in the session switcher.
Uses the account recorded in the buffer's session, falling back to
the backend's :label or symbol name."
  (let ((backend (agent--detect-backend buffer)))
    (or (when-let* ((session (agent-session buffer)))
          (agent-session-account session))
        (agent--backend-get backend :label)
        (and backend (symbol-name backend))
        "Sessions")))
```

- [ ] **Migrate the two other `:account` readers** using the same pattern. In `agent--session-candidate-label` (~1080) and `agent--prompt-session-identity` (~1101), replace this form (it appears verbatim in both):

```elisp
         (account (when-let* ((fn (agent--backend-get backend :account)))
                    (funcall fn buffer)))
```

with:

```elisp
         (account (when-let* ((session (agent-session buffer)))
                    (agent-session-account session)))
```

- [ ] **Migrate accountless-label detection.** Replace (current code at ~720-728):

```elisp
(defun agent--accountless-labels ()
  "Return labels for backends without an :account function.
These backends don't support multi-account grouping, so their
sessions appear without a heading."
  (let (labels)
    (dolist (entry agent-backends labels)
      (unless (plist-get (cdr entry) :account)
        (when-let* ((label (plist-get (cdr entry) :label)))
          (push label labels))))))
```

with:

```elisp
(defun agent--accountless-labels ()
  "Return labels for backends without configured accounts.
These backends don't support multi-account grouping, so their
sessions appear without a heading."
  (let (labels)
    (dolist (entry agent-backends labels)
      (unless (agent-account-list (car entry))
        (when-let* ((label (agent--backend-get (car entry) :label)))
          (push label labels))))))
```

- [ ] **Registry docstring.** In the registry documentation block (pre-refactor `agent.el:~137`), delete the `:account` entry ("`:account function (buffer) -> string or nil (account name for session grouping)`") and add, under the optional keys, entries for `:account-env-var`, `:accounts`, `:account-file`, `:shared-config-items`, `:canonical-home`, and `:account-init`, noting that `accounts`/`account-file`/`shared-config-items`/`canonical-home` may be a value, a function, or a symbol naming a variable (resolved by `agent-account--backend-value`).
- [ ] **Migrate `test/agent-test.el` stubs.** Two tests register stub backends with `:account` lambdas. Worked example — replace (verbatim current code at ~172-187):

```elisp
(ert-deftest agent-test-session-groups-use-account-key ()
  "Group session switcher suffixes by backend account."
  (let ((agent-backends nil)
        (agent--session-keys (make-hash-table :test 'eq)))
    (with-temp-buffer
      (rename-buffer "*one:~/repo/a/:default*" t)
      (let ((buf (current-buffer)))
        (agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :find-all-buffers (lambda () (list buf))
          :account (lambda (_buffer) "work")))
        (puthash buf "a" agent--session-keys)
        (should (equal (mapcar #'car (agent--group-sessions-by-account))
                       '("work")))))))
```

with:

```elisp
(ert-deftest agent-test-session-groups-use-account-key ()
  "Group session switcher suffixes by session account."
  (let ((agent-backends nil)
        (agent--session-keys (make-hash-table :test 'eq)))
    (with-temp-buffer
      (rename-buffer "*one:~/repo/a/:default*" t)
      (let ((buf (current-buffer)))
        (agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :find-all-buffers (lambda () (list buf))))
        (setq-local agent--session
                    (make-agent-session :backend 'one :account "work"))
        (puthash buf "a" agent--session-keys)
        (should (equal (mapcar #'car (agent--group-sessions-by-account))
                       '("work")))))))
```

(Substitute the Phase 1 buffer-local variable name and constructor recorded in the preamble if they differ.) Apply the identical transformation to `agent-test-prompt-capture-file-is-session-specific` (~660-678): delete its `:account (lambda (_buffer) "work")` line and add the same `setq-local` before the `should`.

- [ ] **Add the threading test** to `test/agent-test.el`:

```elisp
(ert-deftest agent-test-start-session-binds-starting-account ()
  "Bind `agent-account--starting' and sync before the backend start call."
  (let ((agent-backends nil)
        (events nil))
    (agent-register-backend
     'one
     (agent-test--backend
      :buffer-p #'ignore
      :find-all-buffers #'ignore
      :start-session (lambda (_session &rest _)
                       (push (cons 'start agent-account--starting) events))))
    (cl-letf (((symbol-function 'agent-account-sync)
               (lambda (backend account)
                 (push (cons 'sync (cons backend account)) events))))
      (agent-start-session
       (make-agent-session :backend 'one :account "work")))
    (should (equal (nreverse events)
                   '((sync . (one . "work"))
                     (start . (one . "work")))))))
```

Adapt the stub registration keywords to whatever `agent-test--backend` and the Phase 1 registration require (the helper already exists in the file); the assertion content — sync first, then start with `agent-account--starting` bound to `(one . "work")` — is the contract and must not change.

- [ ] Verify: `~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-test.el` and `batch-test.sh agent` pass.
- [ ] Commit: `git add agent.el test/agent-test.el && git commit -m "agent: thread session accounts through the core start path"`

### Task 5.4: Migrate `agent-claude.el`

**Files:** `/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/agent-claude.el`; `test/agent-claude-test.el` (~606-622)

Migration table (every reader of the deleted machinery, located by quoted code; pre-refactor line numbers in parentheses):

| # | Site (pre-refactor location) | Current code | Replacement |
|---|---|---|---|
| 1 | defvars (123-136) | `agent-claude--current-account`, `agent-claude--pending-account`, `agent-claude--buffer-account` | delete all three defvar forms |
| 2 | registration (243, 248-249) | `:start-new #'agent-claude--start-with-account` and `:account (lambda (buf) (buffer-local-value 'agent-claude--buffer-account buf))` | `:start-new #'agent-claude--start-new`; delete the `:account` entry; add account slots (step 2 below) |
| 3 | `agent-claude-account-env` (419-433) | pending-or-resolve + alist lookup | pure two-liner (step 3) |
| 4 | `agent-claude--sync-account-config` (452-505) | symlinks + JSON merge | rename to `agent-claude--sync-account-json`, JSON merge only (step 4) |
| 5 | symlink farm (533-593) | `--ensure-shared-symlinks`, `--ensure-shared-symlink`, `--item-virgin-p`, `--file-virgin-p`, `--delete-item` | delete all five functions (now in agent-account, codex policy) |
| 6 | `--load-account`/`--save-account`/`--prompt-account`/`--resolve-account` (648-686) | | delete all four functions |
| 7 | `agent-claude-select-account` (689-700) | inline prompt/save/sync | thin wrapper over `agent-account-select` (step 5) |
| 8 | `agent-claude-init-account` (703-720) | inline | thin wrapper over `agent-account-init` (step 5) |
| 9 | `agent-claude--start-with-account` (722-729) + caller in `agent-claude-start-or-switch` (738) | resolve + pending binding + sync + `(claude-code)` | `agent-claude--start-new` via `agent-start-session` (step 6) |
| 10 | `agent-claude--active-accounts` (1058-1067) | `agent-claude--buffer-account` buffer read | `(agent-claude--session-account buf)` (step 7) |
| 11 | `agent-claude--usage-for-buffer` (1182-1185) | `(gethash agent-claude--buffer-account ...)` | `(gethash (agent-claude--session-account) ...)` |
| 12 | `agent-claude--capture-buffer-account` (1363-1372) + `agent-claude-buffer-account` (1374-1376) + hook add at 2597 | | delete both functions and the `add-hook` line; Phase 1's `agent--capture-session` (edited in Task 5.3) replaces them |
| 13 | `agent-claude--batch-process-environment` (1815-1826) | resolve + alist | `agent-account-resolve`/`agent-account-env` (step 8) |
| 14 | `agent-claude-restart` (2683-2704) | resolve + pending binding + sync | step 9 |
| 15 | transient class + infix (3112-3138) | `agent-claude--account-variable` EIEIO class + methods | delete class and three methods; redefine the infix on `agent-account-variable` (step 10) |
| 16 | env-hook registration | currently only in user dotfiles | package self-registers (step 11) |

Steps:

- [ ] **1. Delete the three defvar forms** at pre-refactor lines 123-136 (locate by `(defvar agent-claude--current-account`, `(defvar agent-claude--pending-account`, `(defvar-local agent-claude--buffer-account`).
- [ ] **2. Registration.** In the `agent-register-backend 'claude-code` form: change `:start-new #'agent-claude--start-with-account` to `:start-new #'agent-claude--start-new`; delete the two `:account (lambda (buf) ...)` lines; add (adapting to the keyword registration shape Phase 1 left):

```elisp
        :account-env-var "CLAUDE_CONFIG_DIR"
        :accounts 'agent-claude-accounts
        :account-file 'agent-claude-account-file
        :shared-config-items 'agent-claude--shared-config-items
        :canonical-home "~/.claude/"
        :account-init #'agent-claude--sync-account-json
```

Also add `(require 'agent-account)` next to the file's existing `(eval-and-compile (require 'agent))`.

- [ ] **3. Pure env hook.** Replace the whole of `agent-claude-account-env` (419-433) with:

```elisp
(defun agent-claude-account-env (_buffer-name _dir)
  "Return `CLAUDE_CONFIG_DIR' for the Claude session being started.
Resolves the account via `agent-account-resolve' (the in-flight
start binding first, then the persisted selection) and never
prompts or touches the filesystem."
  (when-let* ((account (agent-account-resolve 'claude-code)))
    (agent-account-env 'claude-code account)))
```

- [ ] **4. JSON merge becomes the account-init step.** Rename `agent-claude--sync-account-config` to `agent-claude--sync-account-json` and remove the two lines that the unified sync now owns — i.e. delete:

```elisp
    (make-directory (expand-file-name config-dir) t)
    (agent-claude--ensure-shared-symlinks (expand-file-name config-dir))
```

and update the docstring's last paragraph of responsibilities accordingly ("Directory creation and shared symlinks are handled by `agent-account-sync', which calls this function as the backend's account-init step."). Everything else in the function body (the `condition-case` JSON merging) stays byte-identical. Keep `agent-claude--merge-mcp-servers`, `--deep-merge-env`, `--read-claude-json`, `--collect-all-projects`, `--all-claude-json-paths`, `--merge-project`, `--write-claude-json` unchanged.

- [ ] **5. Wrappers.** Replace `agent-claude-select-account` (689-700) and `agent-claude-init-account` (703-720) with:

```elisp
;;;###autoload
(defun agent-claude-select-account ()
  "Switch the active Claude account.
Prompts for an account from `agent-claude-accounts', persists the
selection, and syncs the account's config directory.  New sessions
will use this account."
  (interactive)
  (agent-account-select 'claude-code))

;;;###autoload
(defun agent-claude-init-account (account)
  "Initialize ACCOUNT's config directory without switching to it.
Creates the config directory and all shared symlinks pointing at
`~/.claude/', then merges shared `.claude.json' state.  Safe to
call on an already-initialized account.  Does not change the
persisted active account."
  (interactive
   (list (completing-read "Initialize account: "
                          (mapcar #'car agent-claude-accounts)
                          nil t)))
  (agent-account-init 'claude-code account))
```

- [ ] **6. New-session entry.** Replace `agent-claude--start-with-account` (722-729) with:

```elisp
(defun agent-claude--start-new ()
  "Start a new Claude session using the current account."
  (interactive)
  (agent-start-session
   (make-agent-session :backend 'claude-code
                       :account (agent-account-resolve 'claude-code t))))
```

and change the call in `agent-claude-start-or-switch` (738) from `(agent-claude--start-with-account)` to `(agent-claude--start-new)`. (Substitute the session constructor name from the preamble.) The explicit sync the old function did is now performed by `agent-start-session`'s defensive sync.

- [ ] **7. Session-account helper + usage readers.** Add (near the usage section, before `agent-claude--active-accounts`):

```elisp
(defun agent-claude--session-account (&optional buffer)
  "Return the account recorded for BUFFER's Claude session, or nil."
  (when-let* ((session (agent-session buffer)))
    (agent-session-account session)))
```

Replace in `agent-claude--active-accounts` (1058-1067) the form `(cl-pushnew agent-claude--buffer-account accounts :test #'equal)` — and its enclosing `(with-current-buffer buf ...)`, which is no longer needed — with `(cl-pushnew (agent-claude--session-account buf) accounts :test #'equal)`. Replace `agent-claude--usage-for-buffer`'s body with `(gethash (agent-claude--session-account) agent-claude--usage-data)`.

- [ ] **8. Batch env.** Replace `agent-claude--batch-process-environment` (1815-1826) with:

```elisp
(defun agent-claude--batch-process-environment ()
  "Return the process environment for non-interactive Claude runs."
  (if-let* ((account (agent-account-resolve 'claude-code))
            (env (agent-account-env 'claude-code account)))
      (append env
              (cl-remove-if
               (lambda (s)
                 (or (string-prefix-p "CLAUDE_CODE" s)
                     (string-prefix-p "ANTHROPIC_API_KEY=" s)))
               process-environment))
    process-environment))
```

- [ ] **9. Restart.** If Phases 2–4 already route `agent-claude-restart` through `agent-start-session` (check: does its body call `agent-start-session`?), simply ensure the session passed in carries `(agent-claude--session-account)` or the freshly resolved account, and delete any pending-account binding. Otherwise (body still matches the pre-refactor code that binds `agent-claude--pending-account` and calls `claude-code--start`), replace the `let*` portion of `agent-claude-restart` (2689-2704) with:

```elisp
  (let* ((account (agent-account-resolve 'claude-code t))
         (session-id (agent-claude--current-session-id))
         (dir default-directory)
         (instance-name (claude-code--extract-instance-name-from-buffer-name
                         (buffer-name))))
    (when account
      (agent-account-sync 'claude-code account))
    (agent--force-kill-buffer (current-buffer))
    (let ((agent-account--starting (and account (cons 'claude-code account))))
      (cl-letf (((symbol-function 'claude-code--directory) (lambda () dir))
                ((symbol-function 'claude-code--prompt-for-instance-name)
                 (lambda (_dir _existing _force) instance-name)))
        (claude-code--start nil (list "--resume" session-id) nil t))))
```

The explicit `agent-account-sync` here is required because this path bypasses `agent-start-session` and the env hook no longer syncs.

- [ ] **10. Transient infix.** Delete the `eval-and-compile` defclass `agent-claude--account-variable` and its three `cl-defmethod`s (3112-3132). Replace the infix definition (3134-3138) with:

```elisp
(transient-define-infix agent-claude--infix-account ()
  "Select the active Claude account."
  :class 'agent-account-variable
  :backend 'claude-code
  :description "claude account")
```

The menu wiring in `agent-claude--append-menu-suffixes`/`--remove-menu-suffixes` keeps referencing `agent-claude--infix-account` and needs no change.

- [ ] **11. Package-owned env hook.** Next to the existing hook block, after the line

```elisp
(add-hook 'claude-code-process-environment-functions
          #'agent-claude--sync-theme-before-start)
```

add:

```elisp
(add-hook 'claude-code-process-environment-functions
          #'agent-claude-account-env)
```

(`add-hook` is idempotent, so the user's dotfiles line — removed in Task 5.7 — causes no double registration in the interim.) Also delete the line `(add-hook 'claude-code-start-hook #'agent-claude--capture-buffer-account)` (2597).

- [ ] **12. Tests.** In `test/agent-claude-test.el`, migrate the two batch-env tests (606-622). Worked example for the cache-binding pattern — replace:

```elisp
(ert-deftest agent-claude-test-batch-env-strips-api-key-with-account ()
  "Strip conflicting auth when `CLAUDE_CONFIG_DIR' is set."
  (let ((process-environment '("ANTHROPIC_API_KEY=key" "CLAUDE_CODE=1"))
        (agent-claude-accounts '(("work" . "/tmp/claude-work")))
        (agent-claude--current-account "work"))
    (let ((env (agent-claude--batch-process-environment)))
      (should (member "CLAUDE_CONFIG_DIR=/tmp/claude-work" env))
      (should-not (member "ANTHROPIC_API_KEY=key" env))
      (should-not (member "CLAUDE_CODE=1" env)))))
```

with:

```elisp
(ert-deftest agent-claude-test-batch-env-strips-api-key-with-account ()
  "Strip conflicting auth when `CLAUDE_CONFIG_DIR' is set."
  (let ((process-environment '("ANTHROPIC_API_KEY=key" "CLAUDE_CODE=1"))
        (agent-claude-accounts '(("work" . "/tmp/claude-work")))
        (agent-account--current (make-hash-table :test #'eq)))
    (puthash 'claude-code "work" agent-account--current)
    (let ((env (agent-claude--batch-process-environment)))
      (should (member "CLAUDE_CONFIG_DIR=/tmp/claude-work" env))
      (should-not (member "ANTHROPIC_API_KEY=key" env))
      (should-not (member "CLAUDE_CODE=1" env)))))
```

In the sibling test (606-612), replace the binding `(agent-claude--current-account nil)` with `(agent-account--current (make-hash-table :test #'eq))` (no `puthash`). Add `(require 'agent-account)` to the test file's requires.

- [ ] Verify: `elisp-ert agent test/agent-claude-test.el`, `elisp-ert agent test/agent-account-test.el`, `batch-test.sh agent` all pass, and this grep over `agent-claude.el` returns nothing:

```bash
grep -n -E -- "pending-account|buffer-account|current-account|--load-account|--save-account|--prompt-account|--resolve-account|--capture-buffer-account|--ensure-shared-symlink|--item-virgin-p|--file-virgin-p|--delete-item|--sync-account-config|--account-variable" agent-claude.el
```

- [ ] Commit: `git add agent-claude.el test/agent-claude-test.el && git commit -m "agent-claude: migrate account handling to agent-account"`

### Task 5.5: Migrate `agent-codex.el`

**Files:** `/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/agent-codex.el`; `test/agent-codex-test.el`

Migration table:

| # | Site (pre-refactor location) | Current code | Replacement |
|---|---|---|---|
| 1 | defvars (181-194) | `agent-codex--current-account`, `--pending-account`, `--buffer-account` | delete all three |
| 2 | registration (230, 234-235) | `:start-new #'agent-codex--start-with-account`, `:account` lambda | `:start-new #'agent-codex--start-new`; delete `:account`; add account slots (step 2) |
| 3 | `agent-codex-account-env` (330-341) | pending-or-resolve + **sync inside env hook** | pure two-liner (step 3) — this deletes the filesystem mutation on every spawn, including `codex exec` |
| 4 | `agent-codex--account-home` (343-347) | alist lookup | delete; callers use `(agent-account-home 'codex account)` |
| 5 | `agent-codex--selected-account-no-prompt` (349-353) | pending → current → load | delete; callers use `(agent-account-resolve 'codex)` |
| 6 | `agent-codex--effective-codex-home` (355-363) | uses #5 | step 4 |
| 7 | `agent-codex--config-file` (365-369) | uses #4 | step 4 |
| 8 | `agent-codex--sync-account-home` + symlink farm (371-452) | | delete all seven functions (policy now lives in agent-account) |
| 9 | `--load/--save/--prompt/--resolve-account` (454-492) | | delete all four |
| 10 | `agent-codex-select-account` (495-505) | save only, **no sync** (the drift) | wrapper over `agent-account-select` — gains the sync, fixing the drift (step 5) |
| 11 | `agent-codex--start-with-account` (507-513) | resolve + pending binding | `agent-codex--start-new` (step 6) |
| 12 | `--capture-buffer-account` (515-519) + `agent-codex-buffer-account` (521-523) + hook add (1399) | | delete both functions and the hook line |
| 13 | model/effort readers (595, 600) | `agent-codex--buffer-account` | `(agent-codex--session-account)` (step 7) |
| 14 | theme sync (618-627) | pending→buffer order + sync call | step 8 |
| 15 | handoff (1229-1240) | buffer-local read + pending binding | step 9 |
| 16 | restart (1309-1321) + `--restart-account` cluster (1329-1354) | | step 10 |
| 17 | transient class + infix (1480-1505) | `agent-codex--account-variable` | shared class (step 11) |

Steps:

- [ ] **1. Delete the three defvars** (181-194).
- [ ] **2. Registration.** In `agent-register-backend 'codex`: change `:start-new` to `#'agent-codex--start-new`; delete the `:account` lambda; add:

```elisp
        :account-env-var "CODEX_HOME"
        :accounts 'agent-codex-accounts
        :account-file 'agent-codex-account-file
        :shared-config-items 'agent-codex--shared-config-items
        :canonical-home "~/.codex/"
```

(no `:account-init` — codex has no JSON-merge step). Add `(require 'agent-account)` next to the existing `(eval-and-compile (require 'agent))`. Keep `agent-codex--shared-config-items` (196-206) unchanged.

- [ ] **3. Pure env hook.** Replace `agent-codex-account-env` (330-341) with:

```elisp
(defun agent-codex-account-env (_buffer-name _dir)
  "Return `CODEX_HOME' for the Codex session being started.
Resolves the account via `agent-account-resolve' (the in-flight
start binding first, then the persisted selection) and never
prompts or touches the filesystem.  Config-home syncing happens in
`agent-account-sync' from selection, initialization, and
`agent-start-session' -- in particular, `codex exec' batch runs
never trigger filesystem mutation."
  (when-let* ((account (agent-account-resolve 'codex)))
    (agent-account-env 'codex account)))
```

The hook registrations at 1402-1403 stay as they are.

- [ ] **4. Home/config readers.** Replace `agent-codex--effective-codex-home` (355-363) and `agent-codex--config-file` (365-369) with:

```elisp
(defun agent-codex--effective-codex-home ()
  "Return the Codex home for noninteractive helper discovery.
Prefer the resolved account home.  Fall back to `CODEX_HOME' and
then the ordinary `~/.codex' home.  This function never prompts."
  (expand-file-name
   (or (when-let* ((account (agent-account-resolve 'codex)))
         (agent-account-home 'codex account))
       (getenv "CODEX_HOME")
       "~/.codex")))

(defun agent-codex--config-file (&optional account)
  "Return the config.toml path for ACCOUNT or the default Codex config."
  (if-let* ((home (and account (agent-account-home 'codex account))))
      (expand-file-name "config.toml" home)
    (expand-file-name codex-hooks-config-path)))
```

Then delete `agent-codex--account-home`, `agent-codex--selected-account-no-prompt`, `agent-codex--sync-account-home`, `agent-codex--ensure-shared-symlinks`, `agent-codex--ensure-shared-symlink`, `agent-codex--item-virgin-p`, `agent-codex--file-virgin-p`, `agent-codex--delete-item`, `agent-codex--backup-item`, `agent-codex--load-account`, `agent-codex--save-account`, `agent-codex--prompt-account`, `agent-codex--resolve-account` (343-353, 371-492).

- [ ] **5. Select wrapper** (replaces 495-505; this is where codex gains the on-switch sync that fixes the behavioral drift):

```elisp
;;;###autoload
(defun agent-codex-select-account ()
  "Switch the active Codex account.
Prompts for an account from `agent-codex-accounts', persists the
selection, and syncs the account's home.  New sessions will use
this account."
  (interactive)
  (agent-account-select 'codex))
```

- [ ] **6. New-session entry** (replaces 507-513):

```elisp
(defun agent-codex--start-new ()
  "Start a new Codex session using the current account."
  (interactive)
  (agent-codex--install-hooks)
  (agent-start-session
   (make-agent-session :backend 'codex
                       :account (agent-account-resolve 'codex t))))
```

Update the caller in `agent-codex-start-or-switch` (1365) from `(agent-codex--start-with-account)` to `(agent-codex--start-new)`.

- [ ] **7. Session-account helper + readers.** Add after `agent-codex--config-file`:

```elisp
(defun agent-codex--session-account (&optional buffer)
  "Return the account recorded for BUFFER's Codex session, or nil."
  (when-let* ((session (agent-session buffer)))
    (agent-session-account session)))
```

In `agent-codex-status-model` (595) and `agent-codex-status-effort` (600), replace the argument `agent-codex--buffer-account` with `(agent-codex--session-account)`.

- [ ] **8. Theme sync.** In `agent-codex--sync-theme-to-config` (618-631), replace:

```elisp
  (let* ((theme (or theme (agent--theme)))
         (account (or agent-codex--pending-account
                      agent-codex--buffer-account))
         (_ (when account
              (agent-codex--sync-account-home account)))
         (config-file (agent-codex--config-file account))
```

with:

```elisp
  (let* ((theme (or theme (agent--theme)))
         (account (or (and (eq (car-safe agent-account--starting) 'codex)
                           (cdr agent-account--starting))
                      (agent-codex--session-account)))
         (config-file (agent-codex--config-file account))
```

This removes the third resolution order and the filesystem sync from the env-hook path. (Edge case, accepted: if theme sync ever writes `config.toml` before the account home was first synced, it creates a real file that the codex-policy healer backs up and replaces on the next sync — self-healing.)

- [ ] **9. Handoff.** In `agent-codex-handoff` (1219-1240), replace the `account` binding and the pending-account `let`:

```elisp
         (account (when source-buffer
                    (buffer-local-value 'agent-codex--buffer-account
                                        source-buffer)))
...
    (let ((agent-codex--pending-account
           (or account (agent-codex--resolve-account))))
```

with:

```elisp
         (account (when source-buffer
                    (agent-codex--session-account source-buffer)))
...
    (let* ((start-account (or account (agent-account-resolve 'codex t)))
           (agent-account--starting (and start-account
                                         (cons 'codex start-account))))
      (when start-account
        (agent-account-sync 'codex start-account))
```

(keeping the subsequent `(agent-codex--install-hooks)` and `cl-letf` body unchanged). As with claude restart: if Phases 2–4 already route handoff through `agent-start-session`, pass the account in the session instead and add no sync/binding here.

- [ ] **10. Restart.** In `agent-codex-restart` (1300-1321), replace `(session-account agent-codex--buffer-account)` with `(session-account (agent-codex--session-account))`, and replace `(let ((agent-codex--pending-account account))` with:

```elisp
    (when account
      (agent-account-sync 'codex account))
    (let ((agent-account--starting (and account (cons 'codex account))))
```

In `agent-codex--restart-account` (1329-1341): replace `(agent-codex--selected-account-no-prompt)` with `(agent-account-resolve 'codex)` and `(agent-codex--resolve-account)` with `(agent-account-resolve 'codex t)`. In `agent-codex--ensure-restart-account` (1350-1354), replace `(agent-codex--account-home account)` with `(agent-account-home 'codex account)`.

- [ ] **11. Transient infix.** Delete the defclass `agent-codex--account-variable` and its three methods (1480-1499); replace the infix (1501-1505) with:

```elisp
(transient-define-infix agent-codex--infix-account ()
  "Select the active Codex account."
  :class 'agent-account-variable
  :backend 'codex
  :description "codex account")
```

Menu append/remove code and `agent-codex--account-menu-location` are unchanged. Note this also fixes the second drift: the codex menu infix now syncs on selection (via the shared `transient-infix-set`), like select-account.

- [ ] **12. Hook removal.** Delete the line `(add-hook 'codex-start-hook #'agent-codex--capture-buffer-account)` (1399) in `agent-codex--install-hooks`.
- [ ] **13. Tests.** In `test/agent-codex-test.el`: add `(require 'agent-account)`; then apply these patterns (one worked example each; apply to every occurrence found by the grep in the verification step):
  - **Pattern A — pending-account let-binding** (lines 30, 48, 73, 716, 790, 827): replace `(agent-codex--pending-account "work")` with `(agent-account--starting '(codex . "work"))`.
  - **Pattern B — buffer-local account** (164, 190, 223): replace `(setq-local agent-codex--buffer-account "work")` with `(setq-local agent--session (make-agent-session :backend 'codex :account "work"))` (Phase 1 names from the preamble).
  - **Pattern C — current-account binding** (167, 194, 226): replace `(agent-codex--current-account nil)` with `(agent-account--current (make-hash-table :test #'eq))`; for `(agent-codex--current-account "personal")`, bind the fresh hash table the same way and add `(puthash 'codex "personal" agent-account--current)` as the first body form inside the `let`.
  - **Pattern D — stubbed resolver** (171-172, 245, 265, 286, 315, 349, 372): replace `((symbol-function 'agent-codex--resolve-account) (lambda () ...))` with `((symbol-function 'agent-account-resolve) (lambda (_backend &optional _prompt) ...))` (same return value; for 171-172 keep the `(error "should not resolve active account")` body).
  - **Pattern E — captured pending account** (177, 205-206): replace reads of `agent-codex--pending-account` inside stubs with `(cdr-safe agent-account--starting)`.
  - **Pattern F — env-hook mutation tests**: delete `agent-codex-test-account-env-symlinks-shared-state` (40-63) and `agent-codex-test-account-env-backs-up-conflicting-state` (65-92) outright — the env hook is now pure by design and the symlink behavior is covered by `test/agent-account-test.el`. Rewrite `agent-codex-test-account-env-uses-pending-account` (22-38) to assert purity instead:

```elisp
(ert-deftest agent-codex-test-account-env-uses-starting-account ()
  "Set CODEX_HOME from the in-flight start binding, without syncing."
  (let* ((dir (make-temp-file "codex-account" t))
         (home (expand-file-name "work" dir))
         (agent-codex-accounts `(("work" . ,home)))
         (agent-account--current (make-hash-table :test #'eq))
         (agent-account--starting '(codex . "work")))
    (unwind-protect
        (cl-letf (((symbol-function 'make-symbolic-link)
                   (lambda (&rest _) (error "env hook must not sync"))))
          (should (equal (agent-codex-account-env "*codex*" dir)
                         (list (format "CODEX_HOME=%s" home)))))
      (delete-directory dir t))))
```

  - Delete `agent-codex-test-load-account-ignores-stale-selection` (94-105) — superseded by `agent-account-test-load-ignores-stale-selection`.
  - In the theme test `agent-codex-test-sync-theme-uses-pending-account-home` (706-729), apply Pattern A, rename to `...uses-starting-account-home`, and replace the `(should (file-symlink-p config))` assertion with a prior explicit `(agent-account-sync 'codex "work")` call before `(agent-codex--sync-theme "dark")` (theme sync itself no longer creates the symlink); keep the content assertion.
  - In the discover-skills tests (790, 827), Pattern A applies.
- [ ] Verify: `elisp-ert agent test/agent-codex-test.el`, `batch-test.sh agent`, plus the file-local grep below must be empty:

```bash
grep -n -E -- "pending-account|buffer-account|current-account|--load-account|--save-account|--prompt-account|--resolve-account|--selected-account-no-prompt|--capture-buffer-account|--sync-account-home|--ensure-shared-symlink|--item-virgin-p|--file-virgin-p|--delete-item|--backup-item|agent-codex--account-home|agent-codex--account-variable" agent-codex.el
```

- [ ] Commit: `git add agent-codex.el test/agent-codex-test.el && git commit -m "agent-codex: migrate account handling to agent-account"`

### Task 5.6: Documentation and exhaustive verification sweep

**Files:** `README.org`, `agent.texi`, all `*.el` and `test/*.el` in the package root

- [ ] **Exhaustive grep — must print nothing** (run from the package root; this is the completion gate for the deleted-symbol migration):

```bash
cd "/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent"
grep -rn -E -- "--pending-account|--buffer-account|agent-claude--current-account|agent-codex--current-account|--load-account|--save-account|--prompt-account|--resolve-account|--selected-account-no-prompt|--capture-buffer-account|--sync-account-home|--sync-account-config|agent-claude--ensure-shared-symlink|agent-codex--ensure-shared-symlink|agent-claude--item-virgin-p|agent-codex--item-virgin-p|agent-claude--file-virgin-p|agent-codex--file-virgin-p|agent-claude--delete-item|agent-codex--delete-item|agent-codex--backup-item|agent-claude--account-variable|agent-codex--account-variable|agent-claude-buffer-account|agent-codex-buffer-account|agent-codex--account-home" \
  *.el test/*.el
```

If anything matches, return to the owning task and migrate it before proceeding.

- [ ] **Full suite + load check:**

```bash
~/My\ Drive/dotfiles/claude/bin/batch-test.sh agent
for f in test/agent-account-test.el test/agent-test.el test/agent-claude-test.el test/agent-codex-test.el test/agent-chief-test.el; do
  ~/My\ Drive/dotfiles/claude/bin/elisp-ert agent "$f" || break
done
```

All must pass with zero failures.

- [ ] **README.org** updates (then regenerate `agent.texi` the same way the repo currently does — check `git log --oneline -- agent.texi` for the export convention; if it is exported from README.org via `org-texinfo-export-to-texinfo`, re-export; otherwise mirror the edits manually):
  - Line ~22: in the module description, change "=agent-claude.el= integrates =claude-code.el= with Claude-specific account switching, ..." to mention that account handling is shared: add a sentence "=agent-account.el= implements multi-account support (selection, persistence, per-account config homes, and symlinked shared state) once for all backends."
  - Line ~97 and ~125: after the existing sentences about `agent-*-select-account`, add: "Both commands are thin wrappers around ~agent-account-select~, which persists the choice and syncs the account's config home; ~agent-account-init~ prepares or repairs any backend's account home."
  - Line ~125 (codex paragraph): the claim that shared state is symlinked applies to both backends now; note that conflicting account-local files are backed up to timestamped =*.agent-backup-*= siblings before linking (this replaces the old Claude warn-and-skip behavior).
  - Line ~387 (menu paragraph): unchanged keys, but note both account infixes now share one implementation and both sync on selection.
- [ ] Commit: `git add README.org agent.texi && git commit -m "agent: document unified account module"`
- [ ] **Manual smoke check (flag for the user, do not skip silently):** the transient infixes and live session spawning cannot be fully verified in batch. State in the task report: "Not verified end-to-end: live `agent-menu` account infix and a real `claude`/`codex` spawn under a non-default account; recommend switching accounts via `-c`/`-x` in `agent-menu` and starting one session per backend after the Emacs restart."

### Task 5.7: Remove the manual env wiring from the user's dotfiles

**Files:** `/Users/pablostafforini/My Drive/dotfiles/emacs/config.org` (lines 9045-9047)

This is a separate repo and a separate commit. The package now registers `agent-claude-account-env` itself (Task 5.4 step 11), so the user-level hook line is redundant.

- [ ] In `config.org`, locate the `use-package claude-code` block ending (current lines 9045-9047):

```elisp
  :hook
  (claude-code-process-environment-functions . monet-start-server-function)
  (claude-code-process-environment-functions . agent-claude-account-env))
```

and replace with:

```elisp
  :hook
  (claude-code-process-environment-functions . monet-start-server-function))
```

(i.e. delete the `agent-claude-account-env` hook line and move the closing paren to the `monet-start-server-function` line).

- [ ] Retangle the config:

```bash
emacsclient -e '(init-build-profile (file-name-directory user-init-file))'
```

Wait for it to return without error.

- [ ] Commit in the dotfiles repo:

```bash
cd "/Users/pablostafforini/My Drive/dotfiles"
git add emacs/config.org
git commit -m "emacs: drop manual agent account env wiring"
```

(Per dotfiles conventions, also confirm `git status` shows no unrelated staged changes before committing; the pre-existing `config.toml` modification must not be swept into this commit.)

---

**Phase 5 exit criteria.** (1) `test/agent-account-test.el` green, covering resolution order, env purity, all four symlink-healing branches, account-init, and selection persistence; (2) threading test in `test/agent-test.el` green (sync before spawn, `agent-account--starting` bound during the backend call); (3) the Task 5.6 exhaustive grep over `*.el test/*.el` is empty; (4) `batch-test.sh agent` and all five test files pass; (5) six commits in the package repo plus one in dotfiles, as specified per task; (6) the per-account-homes-with-shared-symlinks model is preserved — at no point may the plan be "simplified" into a single shared home, and concurrent sessions on different accounts must keep working (this is what `agent-account--starting` plus per-session account capture guarantees).

## Phase 6 — Single-implementation orchestration

**Goal.** `agent-claude.el` and `agent-codex.el` each implement the same orchestration workflows (handoff, restart, exit, skills, audit, debug-backtrace, Slack routing) with confirmed drift. This phase rewrites each workflow ONCE in `agent.el` against backend primitives, registers the two genuinely backend-specific batch runners under a normalized `run-prompt` slot, and deletes the transitional command slots from the `agent-backend` struct.

**Package root (all paths below are under it):**
`/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/`

**Ground rules for every task in this phase:**

- Phases 1–5 are done. You can rely on: `agent-session` struct (slots `backend account directory instance id`) and `(agent-session &optional BUFFER)`; the `agent-backend` struct registry with keyword-style `agent-register-backend` and the `(agent--backend-get BACKEND KEY)` shim; `(agent-start-session SESSION &key initial-prompt resume-id)`; `agent-session-event`; core send wrappers `agent-send-string` / `agent-submit` / `agent-send-return`; the before-exit plist chain in agent.el; `agent-account.el` (`agent-account-current/set/select/resolve/env/home/sync`); upstream codex.el `codex-start-session`, `codex-command-submitted-hook`, `codex-prompt-input`, `codex-session-identity`.
- **Line numbers cited below are from the pre-Phase-6 tree.** Earlier phases will have shifted them. Always locate code by symbol name (`grep -n "defun SYMBOL" FILE`), and treat the quoted "current code" blocks as the behavioral reference: if Phases 1–5 already renamed a primitive inside them (e.g. `agent-claude--resolve-account` → `agent-account-resolve`), use the renamed form.
- Before writing any code that calls `agent-account-*`, `agent-start-session`, or `agent-session-event`, **read their definitions in agent.el / agent-account.el first** and match the real signatures.
- Style: small atomic functions; helpers AFTER their callers; no blank lines inside a function; docstrings name args in CAPS, first line one sentence, fill to 80 columns; error messages do not end with a period.
- Tests: run with
  `~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-test.el [NAME]`
  (same for `test/agent-claude-test.el`, `test/agent-codex-test.el`, `test/agent-chief-test.el`). Expected output ends with `Ran N tests ... 0 unexpected`. Load check: `~/My\ Drive/dotfiles/claude/bin/batch-test.sh agent` (expect no `Error`/`Cannot open load file` lines).
- One commit per task, message format `<scope>: <description>` (lowercase imperative). Obsolete markers in this phase use version string `"0.2"`.
- This is an Elpaca source checkout with its own git repo; commit there, not in dotfiles.

---

### Task 6.1: Normalize `run-prompt` and collapse agent-chief dispatch

**Files:**
- `agent-claude.el` (`agent-claude--run-prompt`, pre-phase ~1750–1813; registration form, pre-phase ~233–265)
- `agent-codex.el` (`agent-codex--run-prompt`, pre-phase ~984–1016; registration form, pre-phase ~215–249)
- `agent-chief.el` (declare-functions ~20–21, `agent-chief--require-backend` ~330–335, `agent-chief--run-backend` ~584–603, `agent-chief--handle-result` ~605–617)
- `test/agent-chief-test.el` (~130–142), new tests in `test/agent-claude-test.el`, `test/agent-codex-test.el`

**Current divergence (read both before editing):**

`agent-claude--run-prompt (prompt &rest kwargs)` accepts `:dir :callback :allowed-tools :system-prompt :model :max-turns`, runs `claude -p --output-format stream-json`, and calls back with a rich plist `(:exit-code :duration :cost :text :session-id :raw)`. `agent-codex--run-prompt (prompt &rest kwargs)` accepts only `:dir :callback`, runs `codex exec`, and calls back with `(:exit-code :duration :text :raw)`. `agent-chief--run-backend` hand-dispatches with `pcase` and passes claude an extra `:max-turns agent-chief-max-turns`.

**Decisions:**
- Both inner runners STAY backend-specific (genuinely different CLIs) and keep their rich plists for backend-internal callers (claude's org-TODO batch machinery keeps calling `agent-claude--run-prompt` directly).
- The registered slot uses the locked normalized signature `(prompt &key directory callback)`, callback `(text &key error)`. Cost/duration/session-id metadata is not exposed through the slot (contract).
- Chief's per-call `:max-turns` is dropped: `agent-claude--build-cli-args` already defaults to `agent-claude-batch-max-turns`, so the knob survives as that defcustom; `agent-chief-max-turns` is marked obsolete.

**Steps:**

- [ ] TDD: add to `test/agent-claude-test.el` (after the existing `agent-claude-test-batch-env-*` tests):

  ```elisp
  (ert-deftest agent-claude-test-run-prompt-slot-normalizes-success ()
    "Translate the rich claude result plist into the normalized callback."
    (let (got)
      (cl-letf (((symbol-function 'agent-claude--run-prompt)
                 (lambda (_prompt &rest kwargs)
                   (funcall (plist-get kwargs :callback)
                            '(:exit-code 0 :duration 1.0 :cost 0.01
                              :text "done" :session-id "sid" :raw "")))))
        (agent-claude-run-prompt "p" :directory "/tmp/"
                                 :callback (cl-function
                                            (lambda (text &key error)
                                              (setq got (list text error)))))
        (should (equal got '("done" nil))))))

  (ert-deftest agent-claude-test-run-prompt-slot-reports-error ()
    "Pass a non-nil :error to the normalized callback on failure."
    (let (got)
      (cl-letf (((symbol-function 'agent-claude--run-prompt)
                 (lambda (_prompt &rest kwargs)
                   (funcall (plist-get kwargs :callback)
                            '(:exit-code 2 :duration 1.0 :cost 0
                              :text "boom" :session-id nil :raw "")))))
        (agent-claude-run-prompt "p"
                                 :callback (cl-function
                                            (lambda (text &key error)
                                              (setq got (list text error)))))
        (should (equal (car got) "boom"))
        (should (string-match-p "exit code 2" (cadr got))))))
  ```

  Add the codex twins to `test/agent-codex-test.el` (same shape, stubbing `agent-codex--run-prompt`, function under test `agent-codex-run-prompt`). Run them; they must FAIL (void-function) before the next step.

- [ ] Add to `agent-claude.el`, immediately after `agent-claude--run-prompt`:

  ```elisp
  (cl-defun agent-claude-run-prompt (prompt &key directory callback)
    "Run PROMPT through `claude -p' with the normalized agent signature.
  DIRECTORY is the working directory; it defaults to
  `default-directory'.  CALLBACK is called as (TEXT &key ERROR),
  where ERROR is nil on success or a short failure description.
  This is the `run-prompt' backend slot implementation."
    (agent-claude--run-prompt
     prompt
     :dir (or directory default-directory)
     :callback
     (lambda (result)
       (let ((code (plist-get result :exit-code)))
         (funcall callback (plist-get result :text)
                  :error (unless (eq code 0)
                           (format "claude exited with exit code %s" code)))))))
  ```

- [ ] Add to `agent-codex.el`, immediately after `agent-codex--run-prompt`:

  ```elisp
  (cl-defun agent-codex-run-prompt (prompt &key directory callback)
    "Run PROMPT through `codex exec' with the normalized agent signature.
  DIRECTORY is the working directory; it defaults to
  `default-directory'.  CALLBACK is called as (TEXT &key ERROR),
  where ERROR is nil on success or a short failure description.
  This is the `run-prompt' backend slot implementation."
    (agent-codex--run-prompt
     prompt
     :dir (or directory default-directory)
     :callback
     (lambda (result)
       (let ((code (plist-get result :exit-code)))
         (funcall callback (plist-get result :text)
                  :error (unless (eq code 0)
                           (format "codex exited with exit code %s" code)))))))
  ```

- [ ] In both `agent-register-backend` forms add the slot entry `:run-prompt #'agent-claude-run-prompt` / `:run-prompt #'agent-codex-run-prompt` (keyword style per the Phase-1 registration syntax — copy the surrounding entries' exact syntax).

- [ ] In `agent-chief.el`: delete the two declare-function lines for `agent-claude--run-prompt` / `agent-codex--run-prompt`, and replace `agent-chief--run-backend` (current body is the `pcase` over `'codex`/`'claude-code` shown at pre-phase 584–603) with:

  ```elisp
  (defun agent-chief--run-backend (prompt callback)
    "Run PROMPT through `agent-chief-backend' and call CALLBACK.
  CALLBACK is called as (TEXT &key ERROR) per the normalized
  `run-prompt' backend slot contract."
    (agent-chief--require-backend)
    (let ((run (agent--backend-get agent-chief-backend :run-prompt)))
      (unless run
        (setq agent-chief--running nil)
        (user-error "Backend `%s' does not register a run-prompt slot"
                    agent-chief-backend))
      (funcall run prompt
               :directory agent-chief-directory
               :callback callback)))
  ```

  Keep `agent-chief--require-backend` (it loads the backend feature so registration runs) but simplify its `pcase` to `(require (intern (format "agent-%s" (if (eq agent-chief-backend 'claude-code) "claude" "codex"))))` only if the existing pcase is otherwise unchanged — otherwise leave it as is; it is not duplicated logic.

- [ ] Rewrite `agent-chief--handle-result` callers/signature. Find every `agent-chief--run-backend` call site (grep `agent-chief--run-backend` and `agent-chief--handle-result`); the tick currently passes `#'agent-chief--handle-result` expecting a plist. New version:

  ```elisp
  (cl-defun agent-chief--handle-result (text &key error)
    "Handle normalized backend TEXT and ERROR from one chief tick."
    (setq agent-chief--last-result (list :text text :error error))
    (if error
        (message "Agent chief backend failed: %s (%s)"
                 (or text "(no output)") error)
      (condition-case err
          (agent-chief--handle-decision
           (agent-chief--parse-decision text))
        (error
         (message "Agent chief could not parse backend output: %s"
                  (error-message-string err))))))
  ```

  Pass `(cl-function (lambda (text &key error) (agent-chief--handle-result text :error error)))` at the call site, or pass `#'agent-chief--handle-result` directly (a `cl-defun` with `&key` accepts that calling convention). Check any other reader of `agent-chief--last-result` (grep) and adapt it to the `(:text :error)` shape.

- [ ] Mark the chief knob obsolete, next to its defcustom:

  ```elisp
  (make-obsolete-variable 'agent-chief-max-turns
                          'agent-claude-batch-max-turns "0.2")
  ```

- [ ] Rewrite `agent-chief-test-run-backend-dispatches-to-codex` in `test/agent-chief-test.el`:

  ```elisp
  (ert-deftest agent-chief-test-run-backend-dispatches-to-codex ()
    "Dispatch a chief tick through the codex run-prompt slot."
    (let ((agent-chief-backend 'codex)
          (agent-chief-directory "/tmp/")
          called)
      (cl-letf (((symbol-function 'require) #'ignore)
                ((symbol-function 'agent--backend-get)
                 (lambda (_backend key)
                   (when (eq key :run-prompt)
                     (cl-function
                      (lambda (prompt &key directory callback)
                        (setq called (list prompt directory callback))))))))
        (agent-chief--run-backend "Prompt" #'ignore)
        (should (equal (car called) "Prompt"))
        (should (equal (cadr called) "/tmp/")))))
  ```

- [ ] Run: `~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-claude-test.el`, `... test/agent-codex-test.el`, `... test/agent-chief-test.el`, then `~/My\ Drive/dotfiles/claude/bin/batch-test.sh agent`. All green.
- [ ] Commit: `agent: normalize run-prompt slot and collapse chief dispatch`

---

### Task 6.2: One sentinel-composition helper; unified exit and kill-on-exit; `before-kill-check` slot

**Files:**
- `agent.el` (`agent-exit` ~1989–2000, `agent-setup-kill-on-exit` ~1983–1986, `agent--exit-after-before-exit-skill` ~1433–1438)
- `agent-claude.el` (`agent-claude-exit` ~305–311, `agent-claude-protect-buffer` ~338–346, `agent-claude--confirm-kill-branches` ~348–373, `agent-claude-setup-kill-on-exit` ~375–395, hook line `(add-hook 'claude-code-start-hook #'agent-claude-setup-kill-on-exit)` ~2595)
- `agent-codex.el` (`agent-codex-exit` ~1441–1446, `agent-codex--intercept-exit` ~1448–1457, `agent-codex-setup-kill-on-exit` ~1459–1473, hook/advice lines ~1475–1476)
- `test/agent-test.el` (exit tests ~253–344), `test/agent-codex-test.el` (~531–552 stubs `agent-codex-exit`)

**Current divergence and decisions:**

| Divergence | Claude today | Codex today | Winner / rationale |
|---|---|---|---|
| Exit mechanism | submits `/exit`; CLI terminates; sentinel kills buffer | `agent-kill-session-buffer` (SIGHUP + kill) | Claude's `/exit` submit is the core path (graceful CLI shutdown, CLI-side SessionEnd hooks run). Codex keeps its existing `/exit` intercept that converts the submit into a kill, extended to cover the core submit path. |
| Sentinel wrapping | hand-rolled closure over `process-sentinel` | same, drifted copy | Neither: replace both with `add-function`-based `agent--add-process-exit-hook` so multiple wraps compose and the original sentinel is never lost. |
| Kill guard | prompts when the session has branches (`agent-claude--confirm-kill-branches`) | none | Claude wins; becomes the `before-kill-check` slot (function BUFFER → non-nil allows kill). Codex registers no check. |
| Buffer protection | `agent-claude-protect-buffer` duplicates core `agent-protect-buffer` | uses core | Core wins; delete the claude copy (the hooks at ~2594 already add the core one). |

**Steps:**

- [ ] TDD in `test/agent-test.el` (place after `agent-test-force-kill-buffer-ignores-query-functions`):

  ```elisp
  (ert-deftest agent-test-add-process-exit-hook-composes-with-sentinel ()
    "Run both the original sentinel and the exit hook on process exit."
    (let* ((buf (generate-new-buffer " *agent-exit-hook*"))
           (events nil)
           (proc (make-process :name "agent-exit-hook-test" :buffer buf
                               :command '("true") :connection-type 'pipe)))
      (unwind-protect
          (progn
            (set-process-sentinel proc (lambda (_p _e) (push 'orig events)))
            (agent--add-process-exit-hook
             buf (lambda (_buffer) (push 'hook events)))
            (while (process-live-p proc)
              (accept-process-output proc 0.1))
            (with-timeout (2 (ert-fail "sentinel never ran"))
              (while (< (length events) 2)
                (sit-for 0.05)))
            (should (memq 'orig events))
            (should (memq 'hook events)))
        (when (buffer-live-p buf) (kill-buffer buf)))))

  (ert-deftest agent-test-setup-kill-on-exit-honors-before-kill-check ()
    "Do not kill the buffer when the backend before-kill-check vetoes."
    (let ((agent-backends nil)
          (hook-fn nil))
      (with-temp-buffer
        (let ((buf (current-buffer)))
          (agent-register-backend
           'one
           (agent-test--backend
            :buffer-p (lambda (candidate) (eq candidate buf))
            :before-kill-check (lambda (_buffer) nil)))
          (cl-letf (((symbol-function 'get-buffer-process)
                     (lambda (_b) 'fake-proc))
                    ((symbol-function 'agent--add-process-exit-hook)
                     (lambda (_buffer fn) (setq hook-fn fn))))
            (agent-setup-kill-on-exit))
          (funcall hook-fn buf)
          (should (buffer-live-p buf))))))
  ```

  Adjust `agent-test--backend` keyword syntax to whatever Phase 1 made it (read the helper at the top of `test/agent-test.el` first). Run; both must fail.

- [ ] In `agent.el`, replace the dispatcher bodies of `agent-setup-kill-on-exit` and `agent-exit` (currently `(agent--dispatch :setup-kill-on-exit)` and the `:exit`-slot lookup shown at pre-phase 1989–2000) with:

  ```elisp
  ;;;###autoload
  (defun agent-setup-kill-on-exit ()
    "Arrange for the buffer to be killed when the session process exits.
  Consults the backend's `before-kill-check' slot, which may veto or
  prompt before the buffer is killed."
    (interactive)
    (when-let* ((session (agent-session))
                (backend (agent-session-backend session))
                ((get-buffer-process (current-buffer))))
      (agent--add-process-exit-hook
       (current-buffer)
       (lambda (buffer)
         (when (and (buffer-live-p buffer)
                    (agent--before-kill-allowed-p backend buffer))
           (ignore-errors (kill-buffer buffer)))))))

  (defun agent--before-kill-allowed-p (backend buffer)
    "Return non-nil when BACKEND allows killing session BUFFER."
    (let ((check (agent--backend-get backend :before-kill-check)))
      (or (null check)
          (with-current-buffer buffer
            (funcall check buffer)))))

  (defun agent--add-process-exit-hook (buffer fn)
    "Call FN with BUFFER after the process in BUFFER exits.
  Composes with any existing sentinel via `add-function', so
  repeated calls and pre-existing sentinels all run."
    (when-let* ((proc (get-buffer-process buffer)))
      (unless (process-sentinel proc)
        (set-process-sentinel proc #'ignore))
      (add-function :after (process-sentinel proc)
                    (lambda (process _event)
                      (when (memq (process-status process) '(exit signal))
                        (funcall fn buffer))))))

  ;;;###autoload
  (defun agent-exit ()
    "Exit the current AI session and kill its buffer.
  Runs the before-exit chain, then submits `/exit'.  Claude Code
  handles `/exit' natively; the codex backend intercepts it and
  kills the session, since the Codex CLI has no `/exit'."
    (interactive)
    (let* ((session (or (agent-session)
                        (user-error "Not in an AI session buffer")))
           (backend (agent-session-backend session))
           (buffer (current-buffer)))
      (when (agent--run-before-exit-functions backend buffer)
        (agent--exit-session buffer))))

  (defun agent--exit-session (buffer)
    "Submit `/exit' to session BUFFER without re-running before-exit hooks."
    (agent-submit "/exit" buffer))
  ```

  Then change `agent--exit-after-before-exit-skill` (pre-phase 1433–1438) to call `(agent--exit-session buffer)` instead of looking up the `:exit` slot.

- [ ] In `agent-codex.el`, extend the intercept so `/exit` arriving via the core submit path is also handled. Read which upstream function `agent-submit`'s codex `submit` slot calls (pre-phase it is `codex--send-command-to-buffer`); add alongside the existing advice:

  ```elisp
  (defun agent-codex--intercept-exit-to-buffer (orig-fn cmd buffer)
    "Intercept `/exit' submitted to BUFFER and kill the session instead.
  ORIG-FN is `codex--send-command-to-buffer'.  CMD is the command
  string.  Codex CLI does not recognize `/exit', so it is handled on
  the Emacs side to match Claude Code's behavior."
    (if (string= (string-trim cmd) "/exit")
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (agent-kill-session-buffer)))
      (funcall orig-fn cmd buffer)))

  (advice-add 'codex--send-command-to-buffer :around
              #'agent-codex--intercept-exit-to-buffer)
  ```

  Keep the existing `agent-codex--intercept-exit` advice on `codex--do-send-command` unchanged.

- [ ] Delete `agent-claude-setup-kill-on-exit`, `agent-codex-setup-kill-on-exit`, `agent-claude-exit`, `agent-codex-exit`, and `agent-claude-protect-buffer`. Update the hook lines: `(add-hook 'claude-code-start-hook #'agent-claude-setup-kill-on-exit)` → `#'agent-setup-kill-on-exit`; in `agent-codex--install-hooks`-adjacent code, `(add-hook 'codex-start-hook #'agent-codex-setup-kill-on-exit)` → `#'agent-setup-kill-on-exit`. Keep `agent-claude--confirm-kill-branches` and register it: add `:before-kill-check (lambda (_buffer) (agent-claude--confirm-kill-branches))` to the claude registration (it reads buffer-local status, hence the `with-current-buffer` in the core helper). Codex registers nothing for this slot. Add compatibility aliases next to each deletion site:

  ```elisp
  (define-obsolete-function-alias 'agent-claude-exit #'agent-exit "0.2")
  (define-obsolete-function-alias 'agent-claude-setup-kill-on-exit #'agent-setup-kill-on-exit "0.2")
  (define-obsolete-function-alias 'agent-codex-exit #'agent-exit "0.2")
  (define-obsolete-function-alias 'agent-codex-setup-kill-on-exit #'agent-setup-kill-on-exit "0.2")
  ```

- [ ] Rewrite tests that referenced the deleted commands:
  - `test/agent-test.el` `agent-test-exit-runs-before-exit-functions`, `...-proceeds-after-...`, `...-confirms-when-captured-prompts-pending`, `...-skips-capture-confirmation-without-prompts`: these register an `:exit` slot lambda and assert it ran. Rewrite each to stub the new primitive instead — replace `:exit (lambda () (interactive) (setq ran t))` in the backend registration with nothing, and wrap the `(agent-exit)` call in `(cl-letf (((symbol-function 'agent--exit-session) (lambda (_buffer) (setq ran t)))) ...)`. One worked example (first test):

    ```elisp
    (ert-deftest agent-test-exit-runs-before-exit-functions ()
      "Abort exit when a before-exit function returns nil."
      (let ((agent-backends nil)
            (agent-before-exit-functions nil)
            ran
            seen)
        (with-temp-buffer
          (let ((buf (current-buffer)))
            (agent-register-backend
             'one
             (agent-test--backend
              :buffer-p (lambda (candidate) (eq candidate buf))))
            (add-hook 'agent-before-exit-functions
                      (lambda (backend buffer)
                        (setq seen (list backend buffer))
                        nil))
            (cl-letf (((symbol-function 'agent--exit-session)
                       (lambda (_buffer) (setq ran t))))
              (agent-exit))
            (should (equal seen (list 'one buf)))
            (should-not ran)))))
    ```

    Apply the same mechanical change to the other three.
  - `test/agent-codex-test.el` `agent-codex-test-stop-closes-after-submitted-before-exit-skill` (~531): change the stub `((symbol-function 'agent-codex-exit) (lambda () (interactive) (setq ran t)))` to `((symbol-function 'agent--exit-session) (lambda (_buffer) (setq ran t)))`.

- [ ] Run all four test files + `batch-test.sh agent`.
- [ ] Commit: `agent: unify exit and kill-on-exit via sentinel hook and before-kill-check`

---

### Task 6.3: Unified `agent-restart`

**Files:**
- `agent.el` (`agent-restart` ~2003–2008)
- `agent-claude.el` (`agent-claude-restart` ~2683–2704, `agent-claude--current-session-id` ~3095–3102)
- `agent-codex.el` (`agent-codex-restart` ~1300–1354 incl. `--resume-session`, `--restart-account`, `--prompt-restart-account`, `--ensure-restart-account`)
- `test/agent-codex-test.el` (~156–330), `test/agent-test.el` (~346–373)

**Current divergence and decisions:**

| Divergence | Claude today | Codex today | Winner / rationale |
|---|---|---|---|
| Session id source | polls status file (`agent-claude--current-session-id`) | `codex--current-session-identity` plist | Pattern: codex. Both become the backend `session-identity` slot (function BUFFER → id string or nil); claude's slot implementation keeps reading the status file because that is its only source. |
| Account choice | ignores the buffer's account; silently uses the currently active account | prompts when buffer account ≠ selected account; validates configured | Codex: never silently move a session between accounts. |
| Missing session id | user-error from status read (before kill, incidentally) | explicit user-error before kill | Codex: refuse to kill explicitly. |
| Resume launch | `claude-code--start ... ("--resume" id)` with `cl-letf` over directory/instance prompts | backend-specific resume subcommand | Both collapse into `agent-start-session SESSION :resume-id ID`, which Phase 2 already routes per backend. |

**Steps:**

- [ ] Verify the `session-identity` slot registrations Phase 2/5 left behind (`grep -n "session-identity" agent.el agent-claude.el agent-codex.el`). Required shape: claude registers a function returning `(agent-claude--current-session-id)` (string or user-error), codex a function returning `(plist-get (codex--current-session-identity) :id)`-equivalent via upstream `codex-session-identity`. If the slot currently returns a plist, normalize HERE to "function BUFFER → id string or nil" and fix the registrations; document in the commit message.

- [ ] TDD in `test/agent-test.el`:

  ```elisp
  (ert-deftest agent-test-restart-resumes-with-session-identity ()
    "Restart kills the buffer and resumes the exact session id."
    (let ((agent-backends nil)
          killed resumed)
      (with-temp-buffer
        (let ((buf (current-buffer)))
          (agent-register-backend
           'one
           (agent-test--backend
            :buffer-p (lambda (candidate) (eq candidate buf))
            :session-identity (lambda (_buffer) "sid-123")))
          (cl-letf (((symbol-function 'agent--force-kill-buffer)
                     (lambda (_buffer) (setq killed t)))
                    ((symbol-function 'agent-restart--account)
                     (lambda (_backend _account) nil))
                    ((symbol-function 'agent-start-session)
                     (cl-function
                      (lambda (session &key initial-prompt resume-id)
                        (ignore initial-prompt)
                        (setq resumed (list (agent-session-backend session)
                                            resume-id))))))
            (agent-restart))
          (should killed)
          (should (equal resumed '(one "sid-123")))))))

  (ert-deftest agent-test-restart-without-identity-does-not-kill ()
    "Restart refuses to kill the buffer when no session id exists."
    (let ((agent-backends nil)
          killed)
      (with-temp-buffer
        (let ((buf (current-buffer)))
          (agent-register-backend
           'one
           (agent-test--backend
            :buffer-p (lambda (candidate) (eq candidate buf))
            :session-identity (lambda (_buffer) nil)))
          (cl-letf (((symbol-function 'agent--force-kill-buffer)
                     (lambda (_buffer) (setq killed t))))
            (should-error (agent-restart) :type 'user-error))
          (should-not killed)))))
  ```

- [ ] Replace `agent-restart` in `agent.el` (current body: `(agent--dispatch-with-captured-prompt-confirmation :restart "Restart")`) with:

  ```elisp
  ;;;###autoload
  (defun agent-restart ()
    "Kill the current AI session and resume it in place.
  Useful when a setting change requires relaunching the CLI.
  Preserves the session's directory, instance name, and account; if
  the active account differs from the session account, prompt for
  which one to use."
    (interactive)
    (let* ((session (or (agent-session)
                        (user-error "Not in an AI session buffer")))
           (backend (agent-session-backend session))
           (buffer (current-buffer)))
      (when (agent--confirm-no-captured-prompts backend buffer "Restart")
        (let* ((identity-fn (agent--backend-get backend :session-identity))
               (session-id (or (and identity-fn (funcall identity-fn buffer))
                               (user-error "Current session has no session id")))
               (account (agent-restart--account
                         backend (agent-session-account session))))
          (setf (agent-session-account session) account)
          (agent--force-kill-buffer buffer)
          (agent-start-session session :resume-id session-id)))))

  (defun agent-restart--account (backend session-account)
    "Return the account to restart a BACKEND session with.
  SESSION-ACCOUNT is the account recorded on the session.  Prompt
  when it differs from the currently selected account."
    (let ((selected (agent-account-current backend)))
      (agent-restart--ensure-account backend selected)
      (cond
       ((and session-account selected
             (not (equal session-account selected)))
        (agent-restart--ensure-account
         backend
         (completing-read "Restart with account: "
                          (list selected session-account)
                          nil t nil nil selected)))
       (selected)
       (session-account
        (agent-restart--ensure-account backend session-account))
       (t
        (agent-restart--ensure-account
         backend (agent-account-resolve backend))))))

  (defun agent-restart--ensure-account (backend account)
    "Return ACCOUNT after checking it is configured for BACKEND."
    (when (and account (not (agent-account-home backend account)))
      (user-error "Account `%s' is not configured" account))
    account)
  ```

  Match `agent-account-current` / `agent-account-resolve` / `agent-account-home` to the real Phase-4 signatures (read `agent-account.el` first; if `agent-account-current` prompts, find the no-prompt variant — codex's old `agent-codex--selected-account-no-prompt` shows the required semantics: selected account WITHOUT prompting).

- [ ] Delete `agent-claude-restart`, `agent-codex-restart`, `agent-codex--resume-session`, `agent-codex--restart-account`, `agent-codex--prompt-restart-account`, `agent-codex--ensure-restart-account`. Keep `agent-claude--current-session-id` (slot impl). Add aliases:

  ```elisp
  (define-obsolete-function-alias 'agent-claude-restart #'agent-restart "0.2")
  (define-obsolete-function-alias 'agent-codex-restart #'agent-restart "0.2")
  ```

- [ ] Rewrite `test/agent-codex-test.el` restart tests. Worked example for `agent-codex-test-restart-prompts-when-active-account-differs`: call `(agent-restart)` instead of `(agent-codex-restart)`, stub `codex--buffer-p` as before (so `agent-session` detects the codex backend), and replace the `agent-codex--pending-account` capture with whatever Phase-4 mechanism `agent-start-session` uses to carry the account — assert on the session struct instead, by stubbing `agent-start-session`:

  ```elisp
  (ert-deftest agent-codex-test-restart-prompts-when-active-account-differs ()
    "Restart Codex with the selected account when the user chooses it."
    (let (captured prompt-choices)
      (with-temp-buffer
        (rename-buffer "*codex:~/project/:default*" t)
        (setq-local codex--session-id "019ea295-c3df-70b0-a8e5-a8ffe9df220a")
        (setq-local agent-codex--buffer-account "work")
        (cl-letf (((symbol-function 'codex--buffer-p) (lambda (_buffer) t))
                  ((symbol-function 'agent--force-kill-buffer) #'ignore)
                  ((symbol-function 'agent-account-current)
                   (lambda (_backend) "personal"))
                  ((symbol-function 'agent-account-home)
                   (lambda (_backend _account) "/tmp/home"))
                  ((symbol-function 'completing-read)
                   (lambda (_prompt choices &rest _args)
                     (setq prompt-choices choices)
                     "personal"))
                  ((symbol-function 'agent-start-session)
                   (cl-function
                    (lambda (session &key resume-id &allow-other-keys)
                      (setq captured (list (agent-session-account session)
                                           resume-id))))))
          (agent-restart)))
      (should (equal prompt-choices '("personal" "work")))
      (should (equal captured
                     '("personal" "019ea295-c3df-70b0-a8e5-a8ffe9df220a")))))
  ```

  Remaining restart tests, same mechanical treatment:

  | Test | Change |
  |---|---|
  | `...-restart-preserves-buffer-account` | call `agent-restart`; assert `(agent-session-account session)` = "work" via stubbed `agent-start-session` |
  | `...-restart-fails-when-active-account-is-missing` | stub `agent-account-home` → nil for "personal"; expect `user-error`, no kill/start |
  | `...-restart-resumes-current-session-id-with-app-server` | assert `:resume-id` via stubbed `agent-start-session`; drop instance-name assertion or assert `(agent-session-instance session)` |
  | `...-restart-uses-codex-session-identity` | keep `codex--current-session-identity` stub; assert `:resume-id` |
  | `...-restart-without-session-identity-does-not-kill` | call `agent-restart`; unchanged assertions |
  | `...-restart-uses-default-backend-option` | this tested `agent-codex--resume-session` backend choice, which Phase 2's `agent-start-session` now owns; MOVE the assertion to whatever codex `start-session` slot function handles resume (read it), or delete the test if Phase 2's suite already covers it — check `grep -n "app-server-launch-resume" test/ agent-codex.el` and say which in the commit message |

  Update `test/agent-test.el` `agent-test-restart-confirms-when-captured-prompts-pending`: drop the `:restart` slot from the registration; assert instead that a stubbed `agent--force-kill-buffer` was NOT called after declining.

- [ ] Run all test files + load check.
- [ ] Commit: `agent: unify restart on session identity with account-mismatch prompt`

---

### Task 6.4: Unified `agent-handoff`

**Files:**
- `agent.el` (`agent-handoff` ~1609–1613)
- `agent-claude.el` (~2616–2678: `agent-claude-handoff-file`, `agent-claude-handoff`, `agent-claude-handoff-from-emacsclient`, `agent-claude--read-handoff-file`, `agent-claude--handoff-source-buffer`, `agent-claude--handoff-directory`)
- `agent-codex.el` (~38–63 handoff-file constants/defcustom; ~1219–1295: `agent-codex-handoff`, `agent-codex--kill-handoff-source`, `agent-codex--single-existing-buffer-for-handoff`, `agent-codex-handoff-from-emacsclient`, `agent-codex--handoff-source-buffer`, `agent-codex--handoff-directory`)
- `test/agent-codex-test.el` (~13–15, ~332–366)

**Current divergence and decisions:**

| Divergence | Claude today | Codex today | Winner / rationale |
|---|---|---|---|
| Account carry-over | none (new session may land on wrong account) | reads buffer account, sets pending account | Codex; with `agent-start-session` it comes free from the session struct. |
| Hook install before start | no | `agent-codex--install-hooks` | Moot: `agent-start-session` owns hook wiring since Phase 2. |
| Source-buffer fallback | none (start prompts for instance name; breaks unattended loops) | single-existing-buffer-for-dir fallback with ambiguity error | Codex. |
| emacsclient entry point | has one | has one (duplicate) | One core `agent-handoff-from-emacsclient`. |
| Handoff file default | `(expand-file-name "claude-code-handoff.md" temporary-file-directory)` — wrong on macOS where `temporary-file-directory` is not `/tmp` but the skill writes `/tmp/...` | literal `"/tmp/"` (already migrated off the legacy default) | Codex's literal `/tmp/` convention; claude inherits the fix. |
| Empty-file message | `"Handoff file is empty — run /handoff first"` | `"Handoff file is empty"` | Claude (more actionable). |

**Steps:**

- [ ] TDD in `test/agent-test.el`:

  ```elisp
  (ert-deftest agent-test-handoff-carries-source-session ()
    "Start the handoff session with the source buffer's account and directory."
    (let* ((agent-backends nil)
           (dir (file-name-as-directory (make-temp-file "agent-handoff" t)))
           (handoff-file (expand-file-name "handoff.md" dir))
           killed started)
      (unwind-protect
          (with-temp-buffer
            (let ((buf (current-buffer)))
              (setq default-directory dir)
              (agent-register-backend
               'one
               (agent-test--backend
                :buffer-p (lambda (candidate) (eq candidate buf))))
              (with-temp-file handoff-file (insert "continue\n"))
              (let ((agent-handoff-files '((one . "handoff.md"))))
                (cl-letf (((symbol-function 'agent--handoff-file)
                           (lambda (_backend) handoff-file))
                          ((symbol-function 'agent-session)
                           (lambda (&optional _buffer)
                             (agent-session-make :backend 'one :account "work"
                                                 :directory dir)))
                          ((symbol-function 'agent--force-kill-buffer)
                           (lambda (buffer) (setq killed buffer)))
                          ((symbol-function 'agent-start-session)
                           (cl-function
                            (lambda (session &key initial-prompt &allow-other-keys)
                              (setq started (list (agent-session-account session)
                                                  (agent-session-directory session)
                                                  initial-prompt))))))
                  (agent-handoff)))
              (should (eq killed buf))
              (should (equal started (list "work" dir "continue")))))
        (delete-directory dir t))))
  ```

  Replace `agent-session-make` with the real Phase-1 constructor name (read the `cl-defstruct agent-session` form; it is `make-agent-session` unless a `:constructor` option renamed it).

- [ ] In `agent.el`, replace `agent-handoff`'s dispatcher body and add helpers (place the defcustom with the other core defcustoms; functions after the existing `agent-handoff` position):

  ```elisp
  (defcustom agent-handoff-files
    '((claude-code . "/tmp/claude-code-handoff.md")
      (codex . "/tmp/codex-handoff.md"))
    "Alist mapping backend symbols to handoff files written by /handoff."
    :type '(alist :key-type symbol :value-type file)
    :group 'agent)

  ;;;###autoload
  (defun agent-handoff (&optional buffer-name)
    "Close the current session and start a new one with the handoff prompt.
  The /handoff skill must have been run first to write the handoff
  file.  BUFFER-NAME optionally names the source session buffer; it
  defaults to the current buffer.  The new session starts in the
  same directory with the same account and the handoff contents
  passed as the initial prompt."
    (interactive)
    (let* ((source (agent--handoff-source-buffer buffer-name))
           (session (agent--handoff-session source))
           (backend (agent-session-backend session))
           (prompt (agent--read-handoff-file (agent--handoff-file backend))))
      (when (and source
                 (not (agent--confirm-no-captured-prompts
                       backend source "Handoff")))
        (user-error "Handoff aborted"))
      (agent--kill-handoff-source backend source
                                  (agent-session-directory session))
      (agent-start-session session :initial-prompt prompt)))

  (defun agent--handoff-source-buffer (buffer-name)
    "Return the session buffer named BUFFER-NAME, or the current buffer.
  Return nil when neither names a live session buffer."
    (cond
     ((and buffer-name (not (string-empty-p buffer-name)))
      (let ((buffer (get-buffer buffer-name)))
        (unless buffer
          (user-error "No session buffer named `%s'" buffer-name))
        (unless (agent--detect-backend buffer)
          (user-error "Buffer `%s' is not an AI session" buffer-name))
        buffer))
     ((agent--detect-backend (current-buffer))
      (current-buffer))))

  (defun agent--handoff-session (source)
    "Return the session to hand off to, derived from SOURCE.
  Without a SOURCE buffer, build a session for a prompted backend in
  `default-directory'."
    (if source
        (agent-session source)
      (make-agent-session :backend (agent--resolve-backend)
                          :directory default-directory)))

  (defun agent--handoff-file (backend)
    "Return the handoff file configured for BACKEND."
    (or (alist-get backend agent-handoff-files)
        (user-error "No handoff file configured for backend `%s'" backend)))

  (defun agent--read-handoff-file (file)
    "Return the trimmed contents of handoff FILE, validating it."
    (unless (file-exists-p file)
      (user-error "No handoff file at %s — run /handoff first" file))
    (let ((prompt (with-temp-buffer
                    (insert-file-contents file)
                    (string-trim (buffer-string)))))
      (when (string-empty-p prompt)
        (user-error "Handoff file is empty — run /handoff first"))
      prompt))

  (defun agent--kill-handoff-source (backend source dir)
    "Kill SOURCE, or the single existing BACKEND buffer in DIR.
  The fallback handles emacsclient invocations that reach Emacs
  without the requesting buffer name; leaving that buffer alive
  would trigger an instance-name prompt and break unattended loops."
    (when-let* ((target (or source
                            (agent--single-session-buffer-for-dir backend dir))))
      (with-current-buffer target
        (setq-local agent-before-exit-skill-inhibit t))
      (agent--force-kill-buffer target)))

  (defun agent--single-session-buffer-for-dir (backend dir)
    "Return the only BACKEND session buffer for DIR, or signal on ambiguity."
    (let* ((find-fn (agent--backend-get backend :find-buffers-for-dir))
           (buffers (and find-fn (funcall find-fn dir))))
      (pcase buffers
        ('nil nil)
        (`(,buffer) buffer)
        (_ (user-error "Multiple sessions already exist for %s"
                       (abbreviate-file-name dir))))))

  ;;;###autoload
  (defun agent-handoff-from-emacsclient ()
    "Run `agent-handoff' for the client-provided buffer name.
  The first value in `server-eval-args-left' is treated as the
  session buffer that requested the handoff."
    (interactive)
    (let ((buffer-name (car server-eval-args-left)))
      (setq server-eval-args-left nil)
      (agent-handoff buffer-name)))
  ```

  Note the captured-prompt confirmation moved inline (the old core `agent-handoff` got it from `agent--dispatch-with-captured-prompt-confirmation`).

- [ ] Delete the per-backend handoff implementations listed under **Files** (both files), including `agent-claude-handoff-file` and the codex handoff-file defcustom plus its two `defconst`s and migration `when` form. Add:

  ```elisp
  (define-obsolete-function-alias 'agent-claude-handoff #'agent-handoff "0.2")
  (define-obsolete-function-alias 'agent-claude-handoff-from-emacsclient #'agent-handoff-from-emacsclient "0.2")
  (make-obsolete-variable 'agent-claude-handoff-file 'agent-handoff-files "0.2")
  (define-obsolete-function-alias 'agent-codex-handoff #'agent-handoff "0.2")
  (define-obsolete-function-alias 'agent-codex-handoff-from-emacsclient #'agent-handoff-from-emacsclient "0.2")
  (make-obsolete-variable 'agent-codex-handoff-file 'agent-handoff-files "0.2")
  ```

  (`make-obsolete-variable` rather than alias because two old variables collapse into one alist.) Check the user's handoff skills for hardcoded function names: `grep -rn "handoff-from-emacsclient" ~/My\ Drive/dotfiles/` — the aliases keep those invocations working; list any hits in your final report.

- [ ] Rewrite `test/agent-codex-test.el`:
  - `agent-codex-test-handoff-file-default-matches-skill` → assert `(equal (alist-get 'codex agent-handoff-files) "/tmp/codex-handoff.md")` and add the claude twin in `test/agent-claude-test.el` for `"/tmp/claude-code-handoff.md"`.
  - `agent-codex-test-handoff-kills-single-existing-buffer-when-source-missing` → call `(agent-handoff)`; stub `agent--handoff-source-buffer` → nil, `agent--resolve-backend` → `'codex`, register/stub the `:find-buffers-for-dir` slot via `codex--find-codex-buffers-for-directory` as before, stub `agent-start-session` for the `started` flag, and bind `agent-handoff-files` to the temp file.

- [ ] Run all test files + load check.
- [ ] Commit: `agent: unify handoff with account carry-over and source fallback`

---

### Task 6.5: Unified skill discovery and runner (`skill-roots`, `skill-command-prefix`)

**Files:**
- `agent.el` (`agent-run-skill` ~1616–1670, `agent--discover-all-skills` ~1575–1588, `agent-post-push-ci` ~1674–1685, `agent--before-exit-skill-command` ~1501–1507, `agent-skill-command-prefix-alist` defcustom ~90–96; frontmatter parsing 1522–1573 already core)
- `agent-claude.el` (~1828–2036: `--parse-skill-frontmatter`, `--discover-skills`, `--skill-display-result`, `agent-claude-run-skill`, `--skill-prompt`; defcustoms `agent-claude-programmatic-skill-directories` ~43, `agent-claude-run-skill-model` ~1419)
- `agent-codex.el` (~749–1043 minus the exec/run-prompt parts kept in 6.1: `--codex-plugin-list`, `--codex-plugin-entry-skill-root`, `--codex-plugin-root-orphaned-p`, `--codex-plugin-skill-roots`, `--discover-skills`, `--parse-skill-frontmatter`, `--find-skill`, `--skill-prompt`, `--slash-invocation`, `--display-result`, `agent-codex-run-skill`; defcustoms `agent-codex-skill-directories` ~90, `agent-codex-programmatic-skill-directories` ~96)
- Tests: `test/agent-test.el` ~205–239, `test/agent-codex-test.el` ~733–903, `test/agent-claude-test.el` ~508–534

**Current divergence and decisions:**

| Divergence | Claude today | Codex today | Winner / rationale |
|---|---|---|---|
| Roots | `~/.claude/skills`, project `.claude/skills`, project `.claude/programmatic-skills`, custom programmatic dirs | account-home `skills`, project `.agent/skills`/`.codex/skills`/`.codex/programmatic-skills`, enabled plugin roots, two custom lists | Both keep their root lists, moved into per-backend `skill-roots` slot functions (genuinely backend-specific, esp. codex plugin probing). |
| Prompt style | slash invocation for global/project skills; file-pointing prompt for programmatic | file-pointing whenever metadata found; slash fallback | Encode per root: `skill-roots` returns `(DIR . STYLE)` conses, STYLE ∈ `slash`/`file`. Claude's native roots get `slash` (claude CLI expands slash commands in `-p` mode); everything codex gets `file` (codex exec has no slash expansion). Preserves both behaviors with one core prompt builder. |
| Non-invocable skills | discoverable, hidden from completion only | filtered out at discovery | Claude: discovery returns everything; only interactive completion filters. Programmatic invocation of `user-invocable: false` skills keeps working. |
| Per-skill `:model` frontmatter / `agent-claude-run-skill-model` | supported (`--model` flag) | n/a | **Dropped** — the locked `run-prompt` signature has no model parameter. `agent-claude-batch-model` still applies inside the claude runner. Mark `agent-claude-run-skill-model` obsolete. This is an accepted feature regression; record it in the commit message. |
| Result buffer | `*Claude Skill: N*` with cost/session-id | `*Codex Skill: N*` with exit code | Unified `*Agent skill: N*`, org-mode, text plus error line (metadata not available through normalized callback). |
| Skill prefix for before-exit commands | `agent-skill-command-prefix-alist` defcustom in core | same | Becomes the `skill-command-prefix` backend slot (`"/"` claude, `"$"` codex); delete the defcustom. |

**Steps:**

- [ ] TDD: rewrite `agent-test-run-skill-distinguishes-backends` first (it currently registers `:discover-skills`/`:run-skill` slots):

  ```elisp
  (ert-deftest agent-test-run-skill-distinguishes-backends ()
    "Run the selected backend skill when names collide."
    (let* ((agent-backends nil)
           (dir-one (make-temp-file "agent-skills-one" t))
           (dir-two (make-temp-file "agent-skills-two" t))
           ran)
      (unwind-protect
          (progn
            (dolist (dir (list dir-one dir-two))
              (make-directory (expand-file-name "audit" dir) t)
              (with-temp-file (expand-file-name "audit/SKILL.md" dir)
                (insert "---\nname: audit\n---\nAudit.\n")))
            (agent-register-backend
             'one
             (agent-test--backend
              :label "One"
              :skill-roots (lambda () (list (cons dir-one 'file)))
              :run-prompt (cl-function
                           (lambda (prompt &key directory callback)
                             (ignore directory callback)
                             (setq ran (list 'one prompt))))))
            (agent-register-backend
             'two
             (agent-test--backend
              :label "Two"
              :skill-roots (lambda () (list (cons dir-two 'file)))
              :run-prompt (cl-function
                           (lambda (prompt &key directory callback)
                             (ignore directory callback)
                             (setq ran (list 'two prompt))))))
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (&rest _args) "audit [Two]")))
              (agent-run-skill)
              (should (eq (car ran) 'two))
              (should (string-match-p "audit" (cadr ran)))))
        (delete-directory dir-one t)
        (delete-directory dir-two t))))
  ```

- [ ] In `agent.el`, add the unified discovery/runner. Keep the existing interactive UI of `agent-run-skill` (annotation/argument prompting code at 1621–1666 is reused verbatim); change only the discovery source and the final dispatch:

  ```elisp
  ;; In agent-run-skill, replace:
  ;;   (run-fn (agent--backend-get backend :run-skill)))
  ;;   (unless run-fn
  ;;     (user-error "Backend `%s' does not support `:run-skill'" backend))
  ;;   (funcall run-fn (plist-get skill :name) args)
  ;; with:
       (agent--run-skill backend skill args)

  (defun agent--run-skill (backend skill arguments)
    "Run SKILL plist with ARGUMENTS through BACKEND's run-prompt slot."
    (let ((run (or (agent--backend-get backend :run-prompt)
                   (user-error "Backend `%s' does not register run-prompt"
                               backend)))
          (name (plist-get skill :name)))
      (message "Running skill %s..." name)
      (funcall run (agent--skill-prompt skill arguments)
               :directory default-directory
               :callback
               (cl-function
                (lambda (text &key error)
                  (agent--display-skill-result name text error))))))

  (defun agent--skill-prompt (skill arguments)
    "Return the CLI prompt for SKILL plist with ARGUMENTS.
  Skills from `slash' roots use the backend CLI's native slash
  expansion; skills from `file' roots point the CLI at the skill
  file directly."
    (let ((name (plist-get skill :name))
          (args (and arguments (not (string-empty-p arguments)) arguments)))
      (if (eq (plist-get skill :style) 'slash)
          (if args (format "/%s %s" name args) (format "/%s" name))
        (format (string-join
                 '("Run the skill `%s`%s."
                   ""
                   "Skill file: %s"
                   ""
                   "Read the skill file first and follow its instructions exactly."
                   "Resolve relative paths mentioned by the skill relative to the skill file's directory.%s")
                 "\n")
                name
                (if args (format " with these arguments: %s" args) "")
                (plist-get skill :path)
                (if args (format "\n\nArguments: %s" args) "")))))

  (defun agent--display-skill-result (name text error)
    "Display skill NAME output TEXT, noting ERROR when non-nil."
    (let ((buf (get-buffer-create (format "*Agent skill: %s*" name))))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (format "#+title: %s — %s\n" name
                          (format-time-string "%Y-%m-%d %H:%M:%S")))
          (when error
            (insert (format "#+error: %s\n" error)))
          (insert "\n")
          (insert (or text "(no output)"))
          (unless (string-suffix-p "\n" (or text "")) (insert "\n")))
        (org-mode)
        (goto-char (point-min)))
      (pop-to-buffer buf)
      (message "Skill %s %s" name (if error (format "failed: %s" error) "complete"))))

  (defun agent-discover-skills (backend)
    "Discover all skills for BACKEND from its registered skill roots.
  Return a list of skill plists with :name, :description, :path,
  :style, and the argument metadata recognized by
  `agent-parse-skill-frontmatter'.  Later roots shadow earlier ones."
    (let ((roots-fn (agent--backend-get backend :skill-roots))
          (skills (make-hash-table :test #'equal)))
      (dolist (root (and roots-fn (funcall roots-fn)))
        (let ((dir (car root))
              (style (cdr root)))
          (when (file-directory-p dir)
            (dolist (file (file-expand-wildcards
                           (expand-file-name "*/SKILL.md" dir)))
              (when-let* ((meta (agent-parse-skill-frontmatter file))
                          (name (plist-get meta :name)))
                (puthash name (append meta (list :path file :style style))
                         skills))))))
      (let (result)
        (maphash (lambda (_name skill) (push skill result)) skills)
        (sort result (lambda (a b)
                       (string< (plist-get a :name) (plist-get b :name)))))))
  ```

  Then update `agent--discover-all-skills` to call `(agent-discover-skills (car entry))` instead of the `:discover-skills` slot (keep its user-invocable filtering exactly as is), and update `agent-post-push-ci` to look the skill up by name and call `agent--run-skill`:

  ```elisp
  ;;;###autoload
  (defun agent-post-push-ci (&optional commit)
    "Run the post-push CI closeout skill for COMMIT.
  When COMMIT is nil, use the current Git HEAD."
    (interactive)
    (let* ((backend (agent--resolve-backend))
           (skill (or (cl-find "post-push-ci" (agent-discover-skills backend)
                               :key (lambda (s) (plist-get s :name))
                               :test #'equal)
                      (user-error "Skill `post-push-ci' not found for `%s'"
                                  backend)))
           (sha (or commit (agent--git-head))))
      (agent--run-skill backend skill
                        (format "--no-push --commit %s" sha))))
  ```

- [ ] In `agent-claude.el`, replace `agent-claude--discover-skills` with a roots function (everything else in 1828–2036 listed above is deleted):

  ```elisp
  (defun agent-claude-skill-roots ()
    "Return Claude skill roots as (DIRECTORY . STYLE) conses.
  Global and project skills run via native slash expansion;
  programmatic directories are pointed at by file."
    (let* ((project-root (or (when-let* ((proj (project-current)))
                               (project-root proj))
                             (locate-dominating-file default-directory ".claude")
                             (locate-dominating-file default-directory ".git"))))
      (append
       (list (cons (expand-file-name "~/.claude/skills") 'slash))
       (when project-root
         (list (cons (expand-file-name ".claude/skills" project-root) 'slash)
               (cons (expand-file-name ".claude/programmatic-skills"
                                       project-root)
                     'file)))
       (mapcar (lambda (dir) (cons dir 'file))
               agent-claude-programmatic-skill-directories))))
  ```

- [ ] In `agent-codex.el`, replace `agent-codex--discover-skills` with (keep the four `--codex-plugin-*` helpers, which it calls):

  ```elisp
  (defun agent-codex-skill-roots ()
    "Return Codex skill roots as (DIRECTORY . STYLE) conses.
  Codex exec has no slash expansion, so every root is file-style."
    (let* ((codex-home (agent-codex--effective-codex-home))
           (project-root (or (when-let* ((proj (project-current)))
                               (project-root proj))
                             (locate-dominating-file default-directory ".codex")
                             (locate-dominating-file default-directory ".git"))))
      (mapcar (lambda (dir) (cons dir 'file))
              (append
               (list (expand-file-name "skills" codex-home))
               (when project-root
                 (list (expand-file-name ".agent/skills" project-root)
                       (expand-file-name ".codex/skills" project-root)
                       (expand-file-name ".codex/programmatic-skills"
                                         project-root)))
               (agent-codex--codex-plugin-skill-roots codex-home)
               agent-codex-skill-directories
               agent-codex-programmatic-skill-directories))))
  ```

  If Phase 4 renamed `agent-codex--effective-codex-home` into `agent-account.el`, use the renamed accessor.

- [ ] Register in both backends: `:skill-roots #'agent-claude-skill-roots` + `:skill-command-prefix "/"`; `:skill-roots #'agent-codex-skill-roots` + `:skill-command-prefix "$"`. Update `agent--before-exit-skill-command` to use the slot, and delete the `agent-skill-command-prefix-alist` defcustom:

  ```elisp
  (defun agent--before-exit-skill-command (backend entry)
    "Return the interactive command string for before-exit ENTRY on BACKEND.
  Append ENTRY's `:args' when present."
    (when-let* ((prefix (agent--backend-get backend :skill-command-prefix)))
      (let ((args (agent--before-exit-skill-entry-args entry)))
        (concat prefix (agent--before-exit-skill-entry-name entry)
                (and args (concat " " args))))))
  ```

- [ ] Delete `agent-claude-run-skill`, `agent-codex-run-skill`, `agent-claude--skill-prompt`, `agent-codex--skill-prompt`, `agent-codex--slash-invocation`, `agent-codex--find-skill`, `agent-claude--skill-display-result`, `agent-codex--display-result`, `agent-claude--parse-skill-frontmatter`, `agent-codex--parse-skill-frontmatter` (the last two are one-line shims around the core parser). Add aliases and obsolescence:

  ```elisp
  (define-obsolete-function-alias 'agent-claude-run-skill #'agent-run-skill "0.2")
  (make-obsolete-variable 'agent-claude-run-skill-model 'agent-claude-batch-model "0.2")
  (define-obsolete-function-alias 'agent-codex-run-skill #'agent-run-skill "0.2")
  ```

- [ ] Rewrite the affected tests:

  | Test | Change |
  |---|---|
  | `agent-test-run-skill-distinguishes-backends` | already rewritten (TDD step) |
  | `agent-test-post-push-ci-runs-skill-for-head` | create a temp `post-push-ci/SKILL.md` root, register `:skill-roots` + capture via `:run-prompt`; assert the prompt mentions the skill file and `--no-push --commit abc123` |
  | `agent-test-discover-all-skills-skips-non-invocable` (~644) | keep; it now exercises core discovery — register `:skill-roots` over a temp dir containing one `user-invocable: false` skill instead of a `:discover-skills` lambda |
  | `agent-codex-test-run-skill-uses-codex-exec` (~879) | stub `agent-codex-run-prompt` (the slot fn) instead of `agent-codex--run-prompt`; call `(agent--run-skill 'codex skill "file.org")` with `skill` from `(agent-discover-skills 'codex)` under `agent-codex-skill-directories`; same two prompt assertions |
  | `agent-codex-test-discover-skills-skips-non-invocable` (~752) | behavior changed deliberately: assert the skill IS returned by `(agent-discover-skills 'codex)` and that `agent--discover-all-skills` excludes it |
  | `agent-codex-test-discover-skills-uses-selected-account-home` (~779), `...-includes-current-plugin-roots` (~810) | replace `agent-codex--discover-skills` calls with `(agent-discover-skills 'codex)`; root-construction stubs unchanged |
  | `agent-claude-test-skill-result-does-not-modify-new-user-buffer` (~508) | port to `agent--display-skill-result` in `test/agent-test.el`; assert output lands in `*Agent skill: NAME*` |

- [ ] Run all test files + load check.
- [ ] Commit: `agent: unify skill discovery and runner on skill-roots slot`

---

### Task 6.6: Unified `agent-audit-project`

**Files:**
- `agent.el` (`agent-audit-project` ~1695–1698)
- `agent-claude.el` (~2082–2116: `agent-claude-audit-project`, `--read-audit-project-directory`; `--ensure-clean-worktree` ~1604–1617, `--batch-commit-changes` ~1666–1678; defcustoms `agent-claude-audit-skills` ~1432, `agent-claude-audit-project-directories` ~1440)
- `agent-codex.el` (~1047–1133: `agent-codex-audit-project`, `--audit-run-next`, `--audit-finish`, `--read-audit-directory`; defcustoms ~103–113)

**Current divergence and decisions:**

| Divergence | Claude today | Codex today | Winner / rationale |
|---|---|---|---|
| Auto-commit after each skill | yes, with clean-worktree precheck | no | Claude: backend-agnostic git behavior, keep in core (it operates on the project dir, not the CLI). |
| Raw stream-json log files | yes (`agent-claude-log-directory`) | no | Dropped in the unified audit: raw output is not exposed by the normalized callback. Claude's org-TODO batch path (which keeps logs) is untouched. Record in commit message. |
| Cost reporting | yes | no | Dropped (same reason). |
| Skill prompt | slash entries `"/code-audit --accept"` via batch prompt | file-pointing prompt via `--find-skill` | Core `agent--skill-prompt` from Task 6.5, so each backend keeps its natural style. |

**Steps:**

- [ ] Add core defcustoms (variable aliases FIRST so saved customizations migrate):

  ```elisp
  (define-obsolete-variable-alias 'agent-claude-audit-skills 'agent-audit-skills "0.2")
  (defcustom agent-audit-skills '("code-audit" "design-audit" "interpretability-audit")
    "Skills to run when performing an integral project audit.
  Each entry is a skill name without prefix; each is invoked with
  `--accept'."
    :type '(repeat string)
    :group 'agent)

  (define-obsolete-variable-alias 'agent-claude-audit-project-directories
    'agent-audit-project-directories "0.2")
  (define-obsolete-variable-alias 'agent-codex-audit-project-directories
    'agent-audit-project-directories "0.2")
  (defcustom agent-audit-project-directories nil
    "Directories available for selection in `agent-audit-project'.
  New directories entered by the user are automatically added."
    :type '(repeat directory)
    :group 'agent)
  ```

  Only ONE `define-obsolete-variable-alias` may target `agent-audit-skills` (claude's; codex's `agent-codex-audit-skills` gets `make-obsolete-variable 'agent-codex-audit-skills 'agent-audit-skills "0.2"` instead — two aliases to one variable are not supported for saved-value migration; prefer claude's, whose default the core keeps modulo prefix). Note the names lose the leading `/` — `agent--skill-prompt` adds the prefix or file pointer.

- [ ] Replace `agent-audit-project`'s dispatcher body in `agent.el`:

  ```elisp
  ;;;###autoload
  (defun agent-audit-project ()
    "Run a comprehensive project audit via the selected backend.
  Sequentially runs each skill in `agent-audit-skills' with
  `--accept' through the backend's run-prompt slot, auto-committing
  after each successful skill, and displays a summary when done."
    (interactive)
    (let* ((backend (agent--resolve-backend))
           (dir (agent--read-audit-directory)))
      (when (yes-or-no-p
             (format "Run %d audit(s) on %s?" (length agent-audit-skills) dir))
        (agent--audit-ensure-clean-worktree dir)
        (agent--audit-run-next
         (list :backend backend :queue agent-audit-skills :results nil
               :dir dir :start-time (current-time))))))

  (defun agent--audit-run-next (state)
    "Run the next audit skill in STATE, or finish."
    (if (null (plist-get state :queue))
        (agent--audit-finish state)
      (let* ((backend (plist-get state :backend))
             (queue (plist-get state :queue))
             (name (car queue))
             (skill (or (cl-find name (agent-discover-skills backend)
                                 :key (lambda (s) (plist-get s :name))
                                 :test #'equal)
                        (list :name name :style 'slash)))
             (run (agent--backend-get backend :run-prompt)))
        (message "Running audit %s..." name)
        (funcall run (agent--skill-prompt skill "--accept")
                 :directory (plist-get state :dir)
                 :callback
                 (cl-function
                  (lambda (text &key error)
                    (plist-put state :results
                               (cons (list :skill name :text text :error error)
                                     (plist-get state :results)))
                    (plist-put state :queue (cdr queue))
                    (unless error
                      (ignore-errors
                        (agent--audit-commit-changes (plist-get state :dir) name)))
                    (agent--audit-run-next state)))))))
  ```

  Port `agent--audit-finish` from `agent-codex--audit-finish` (pre-phase 1082–1118) verbatim apart from: buffer name `*Agent audit results*`, success counted as `(null (plist-get result :error))`, per-result property drawer `:ERROR:` instead of `:EXIT_CODE:`. Port `agent--read-audit-directory` from `agent-codex--read-audit-directory` (1120–1133) switching the variable to `agent-audit-project-directories`. Port `agent--audit-ensure-clean-worktree` from `agent-claude--ensure-clean-worktree` (1604–1617) and `agent--audit-commit-changes (dir title)` from `agent-claude--batch-commit-changes` (1666–1678), parameterizing `default-directory` by `dir` instead of the state plist.

- [ ] Delete `agent-claude-audit-project`, `agent-claude--read-audit-project-directory`, `agent-codex-audit-project`, `agent-codex--audit-run-next`, `agent-codex--audit-finish`, `agent-codex--read-audit-directory`, and the codex defcustoms (after the `make-obsolete-variable` markers). Keep `agent-claude--ensure-clean-worktree` and `agent-claude--batch-commit-changes` ONLY if the org-TODO batch path still calls them (it does — `agent-claude--batch-start`); the core gets its own ports as above (acceptable: the claude pair stays plist-coupled to batch state and is scheduled for review when batch processing is revisited; note this in the commit message). Aliases:

  ```elisp
  (define-obsolete-function-alias 'agent-claude-audit-project #'agent-audit-project "0.2")
  (define-obsolete-function-alias 'agent-codex-audit-project #'agent-audit-project "0.2")
  ```

- [ ] Add a core test:

  ```elisp
  (ert-deftest agent-test-audit-commits-after-successful-skill ()
    "Auto-commit after each successful audit skill and not after failures."
    (let ((agent-backends nil)
          (agent-audit-skills '("a" "b"))
          commits)
      (agent-register-backend
       'one
       (agent-test--backend
        :skill-roots (lambda () nil)
        :run-prompt (cl-function
                     (lambda (prompt &key directory callback)
                       (ignore directory)
                       (funcall callback "out"
                                :error (when (string-match-p "/b" prompt)
                                         "exit code 1"))))))
      (cl-letf (((symbol-function 'agent--audit-commit-changes)
                 (lambda (_dir title) (push title commits)))
                ((symbol-function 'agent--audit-finish) #'ignore))
        (agent--audit-run-next (list :backend 'one :queue agent-audit-skills
                                     :results nil :dir "/tmp/"
                                     :start-time (current-time))))
      (should (equal commits '("a")))))
  ```

- [ ] Run all test files + load check.
- [ ] Commit: `agent: unify project audit on run-prompt slot with auto-commit`

---

### Task 6.7: Unified `agent-debug-backtrace`

**Files:**
- `agent.el` (`agent-debug-backtrace` ~1701–1704; `agent--gptel-response-text`, `agent--package-source-directory`, `agent-save-backtrace` already core)
- `agent-claude.el` (~2463–2471 defcustoms; ~2500–2561 command + helpers)
- `agent-codex.el` (~137–146 defcustoms; ~1138–1185 command + helpers)

**Current divergence and decisions:** the two implementations are near-verbatim copies. Claude's gptel system prompt includes the example sentence ("For example: ...") — keep claude's richer prompt. Codex installs hooks before starting — moot under `agent-start-session`. Session launch goes through `agent-start-session` with `:initial-prompt`.

**Steps:**

- [ ] In `agent.el`, add ONE defcustom pair with aliases before them (codex's get `make-obsolete-variable`, claude's get the alias, same single-alias rule as Task 6.6):

  ```elisp
  (define-obsolete-variable-alias 'agent-claude-debug-backtrace-model
    'agent-debug-backtrace-model "0.2")
  (defcustom agent-debug-backtrace-model 'gemini-flash-lite-latest
    "GPtel model for identifying candidate packages from a backtrace."
    :type 'symbol
    :group 'agent)

  (define-obsolete-variable-alias 'agent-claude-debug-backtrace-backend
    'agent-debug-backtrace-backend "0.2")
  (defcustom agent-debug-backtrace-backend "Gemini"
    "GPtel backend name for backtrace analysis."
    :type 'string
    :group 'agent)

  (make-obsolete-variable 'agent-codex-debug-backtrace-model
                          'agent-debug-backtrace-model "0.2")
  (make-obsolete-variable 'agent-codex-debug-backtrace-backend
                          'agent-debug-backtrace-backend "0.2")
  ```

- [ ] Replace `agent-debug-backtrace`'s dispatcher body. Port `agent-claude--debug-identify-package` (2515–2547) verbatim as `agent--debug-identify-package (backend backtrace-file)` substituting the unified defcustoms and threading BACKEND through to the start helper; the backend is resolved up front because the backtrace buffer is not a session buffer:

  ```elisp
  ;;;###autoload
  (defun agent-debug-backtrace ()
    "Save the backtrace, choose the offending package, and open a session.
  Save the current backtrace to `agent-backtrace-file', ask `gptel'
  to list implicated packages, let the user pick one, then start an
  interactive session in that package's source directory with the
  backtrace file path as the initial prompt."
    (interactive)
    (let ((backend (agent--resolve-backend))
          (backtrace-file (expand-file-name agent-backtrace-file)))
      (run-with-timer 0 nil #'agent--debug-identify-package
                      backend backtrace-file)
      (agent-save-backtrace)))
  ```

  (Keep the timer indirection and its comment about `agent-save-backtrace` unwinding the recursive edit.) The start helper:

  ```elisp
  (defun agent--debug-start-session (backend package backtrace-file)
    "Start a BACKEND session for PACKAGE with BACKTRACE-FILE."
    (let* ((dir (or (agent--package-source-directory package)
                    (user-error "Package `%s' not found" package)))
           (prompt (format "Read the backtrace at %s. Identify the bug, fix it, and commit the fix."
                           backtrace-file)))
      (message "Starting %s for `%s' in %s..."
               (agent--backend-get backend :label) package dir)
      (agent-start-session
       (make-agent-session :backend backend :directory dir)
       :initial-prompt prompt)))
  ```

- [ ] Delete both per-backend command trios and their defcustoms (after the obsolescence markers above are in core). Aliases:

  ```elisp
  (define-obsolete-function-alias 'agent-claude-debug-backtrace #'agent-debug-backtrace "0.2")
  (define-obsolete-function-alias 'agent-codex-debug-backtrace #'agent-debug-backtrace "0.2")
  ```

- [ ] Run all test files + load check (no existing tests cover these commands; the gptel half stays untested as today).
- [ ] Commit: `agent: unify debug-backtrace with single gptel defcustom pair`

---

### Task 6.8: Unified `agent-act-on-slack-message`

**Files:**
- `agent.el` (`agent-act-on-slack-message` ~1707–1710; the gptel/Slack routing helpers ~1768–1980 are already core)
- `agent-claude.el` (defcustoms ~2473–2491; command + start helper ~2564–2589)
- `agent-codex.el` (defcustoms ~147–165; command + start helper ~1188–1214)

**Current divergence:** none of substance — both insert (not submit) the URL into a fresh session for review; codex additionally installs hooks (moot). Unify mechanically. This lands in `agent.el` for now; Phase 8 moves it to `agent-slack.el`.

**Steps:**

- [ ] Add the unified defcustom pair (same alias pattern: claude's two get `define-obsolete-variable-alias`, codex's two get `make-obsolete-variable`): `agent-act-on-slack-message-model` (default `'gemini-flash-lite-latest`) and `agent-act-on-slack-message-backend` (default `"Gemini"`), `:group 'agent`. The pre-existing `agent-claude-debug-slack-message-*`/`agent-codex-debug-slack-message-*` obsolete aliases keep chaining correctly; leave them where they are in the backend files only if those files still define the intermediate variable, otherwise move the chain endpoint to the new core names.

- [ ] Replace the dispatcher body:

  ```elisp
  ;;;###autoload
  (defun agent-act-on-slack-message ()
    "Route the Slack message at point to an Epoch project session.
  Identifies the project with `gptel', starts a session in the
  project directory, and inserts the Slack message URL into the
  prompt for review without submitting it."
    (interactive)
    (let ((backend (agent--resolve-backend)))
      (agent--act-on-slack-message
       agent-act-on-slack-message-model
       agent-act-on-slack-message-backend
       (lambda (project slack-url)
         (agent--act-on-slack-start-session backend project slack-url)))))

  (defun agent--act-on-slack-start-session (backend project slack-url)
    "Start a BACKEND session for PROJECT and insert SLACK-URL."
    (let ((dir (file-name-as-directory
                (expand-file-name (plist-get project :directory)))))
      (message "Starting %s for `%s' in %s..."
               (agent--backend-get backend :label)
               (plist-get project :id) dir)
      (let ((buffer (agent-start-session
                     (make-agent-session :backend backend :directory dir))))
        (agent-send-string slack-url buffer)
        buffer)))
  ```

  Confirm `agent-start-session` returns the session buffer (read it); if it does not, capture the buffer via the backend `target-buffer`/`find-buffers-for-dir` slot and say so in the commit message.

- [ ] Delete both per-backend commands, start helpers, defcustoms, and their `define-obsolete-function-alias` stubs for `*-debug-slack-message*` (re-point those old names at the core command). Add:

  ```elisp
  (define-obsolete-function-alias 'agent-claude-act-on-slack-message #'agent-act-on-slack-message "0.2")
  (define-obsolete-function-alias 'agent-codex-act-on-slack-message #'agent-act-on-slack-message "0.2")
  ```

- [ ] Rewrite the two backend tests (`agent-claude-test-act-on-slack-message-inserts-url-for-review` ~36–66, `agent-codex-test-...` ~441–471) as ONE core test in `test/agent-test.el`: stub backend with `agent-test--backend`, stub `agent-start-session` to return a buffer and `agent-send-string` to capture `(cmd target)`; assert the URL is inserted into the returned buffer and that nothing submits (no `agent-submit`/`agent-send-return` stub gets called — bind them to lambdas that `ert-fail`). Delete the two originals. Update `agent-test-act-on-slack-message-dispatches-new-backend-key` (~61–72): the `:act-on-slack-message` slot no longer exists; rewrite it to stub `agent--act-on-slack-message` and assert it is reached with the unified defcustom values.

- [ ] Run all test files + load check.
- [ ] Commit: `agent: unify slack-message routing with single defcustom pair`

---

### Task 6.9: Hoist notification-handler residue into core

**Files:**
- `agent-claude.el` (`agent-claude-notify` ~1213–1221, `agent-claude--handle-notification` ~1236–1266, `agent-claude--handle-stop` ~1300–1309, `agent-claude--scroll-to-bottom` ~1311–1320, `agent-claude--scroll-windows-to` ~1322–1328, `agent-claude--session-name` ~1330–1336, `agent-claude-jump-to-waiting` ~1287–1298, `agent-claude-toggle-alert` ~1338–1343, `agent-claude-alert-indicator` ~1345–1347, `agent-claude-fix-rendering` + `--send-sigwinch*` ~397–415)
- `agent-codex.el` (`agent-codex-notify` ~673–681, `agent-codex--handle-notification` ~726–747)
- `agent.el` (`agent-notify` ~778, `agent--scroll-to-bottom` ~852, `agent--session-name` ~231, `agent-jump-to-waiting` ~822, `agent-toggle-alert` ~839, `agent-alert-indicator` ~846, `agent-fix-rendering` ~867)

**Finding (verified in source):** the codex handler already uses core helpers; the claude handler still uses private near-verbatim copies. Per-event alert titles are hardcoded per backend.

**Steps:**

- [ ] In `agent-claude--handle-notification` and `agent-claude--handle-stop`, substitute core helpers: `agent-claude--session-name` → `agent--session-name`, `agent-claude--scroll-to-bottom` → `agent--scroll-to-bottom`. Check what Phase 3 did to these handlers first (`grep -n "agent-session-event" agent-claude.el agent-codex.el`); if events already route through `agent-session-event`, apply the substitutions inside the translator instead. Keep claude's three distinct event types (`idle_prompt`, `permission_prompt`, `elicitation_dialog`) — claude wins on granularity; codex has no equivalent CLI events to gain.
- [ ] Unify alert titles through the backend label: replace the literal `"Claude ready"` / `"Codex ready"` with `(format "%s ready" (agent--backend-get BACKEND :label))`, and likewise `"Claude Code"`/`"Codex"` fallback titles with the label. One formatting site per handler; behavior-identical strings for the ready case modulo "Claude" → "Claude Code" (acceptable; label wins for consistency with the rest of the UI).
- [ ] Reduce the two notify functions to shared routing: both become `(BACKEND-default-notification title message)` followed by `(agent--alert-route title message)`; add to `agent.el`:

  ```elisp
  (defun agent--alert-route (title message)
    "Fire the configured visual/sound alert for TITLE and MESSAGE."
    (when agent-alert-on-ready
      (agent--alert-visual title message)
      (agent--alert-sound)))
  ```

  and use it from `agent-notify` too (its body currently duplicates the same three lines).
- [ ] Delete the pure duplicates with aliases:

  ```elisp
  (define-obsolete-function-alias 'agent-claude-jump-to-waiting #'agent-jump-to-waiting "0.2")
  (define-obsolete-function-alias 'agent-claude-toggle-alert #'agent-toggle-alert "0.2")
  (define-obsolete-function-alias 'agent-claude-alert-indicator #'agent-alert-indicator "0.2")
  (define-obsolete-function-alias 'agent-claude-fix-rendering #'agent-fix-rendering "0.2")
  ```

  Delete `agent-claude--scroll-to-bottom`, `agent-claude--scroll-windows-to`, `agent-claude--session-name`, `agent-claude--send-sigwinch-after-delay`, `agent-claude--send-sigwinch` (core owns all five). `grep -n "agent-claude--session-name\|agent-claude--scroll\|agent-claude--send-sigwinch\|agent-claude-fix-rendering" agent-claude.el agent.el` must return only the alias lines; fix any other callers (e.g. modeline code) to core names. Behavior check on session-name: claude's regexp version returned `buffer-name` unchanged for non-matching names, and so does `agent--session-name` — verified equivalent for the four patterns covered by `agent-claude-test-session-name-*`; MOVE those four tests to `test/agent-test.el` against `agent--session-name` (if duplicates already exist there from Phase 3, just delete the claude copies).
- [ ] Run all test files + load check.
- [ ] Commit: `agent-claude: hoist notification residue into core helpers`

---

### Task 6.10: Confirm `sync-theme` slot consistency (no unification)

**Files:** `agent-claude.el` (`agent-claude--sync-theme` ~2120 ff.), `agent-codex.el` (`agent-codex--sync-theme` ~612 ff.), registrations in both.

The two implementations stay backend-specific (JSON settings files vs TOML config) — this is by design; only the registration is checked.

- [ ] Verify both registrations carry the slot: `grep -n "sync-theme" agent-claude.el agent-codex.el agent.el`. Expect `:sync-theme #'agent-claude--sync-theme` and `:sync-theme #'agent-codex--sync-theme` in the registration forms, and core `agent--do-sync-theme` iterating the registry. Both slot functions must keep the signature `(theme)` with THEME `"light"`/`"dark"`.
- [ ] Run the theme tests: `~/My\ Drive/dotfiles/claude/bin/elisp-ert agent test/agent-test.el agent-test-sync-theme-dispatches-to-backends` plus the `sync-theme` tests in both backend test files. Green = done; no commit if no changes were needed. If a registration is missing the slot, add it and commit `agent: ensure sync-theme slot registered for both backends`.

---

### Task 6.11: Delete transitional slots, registrations, and wrappers; final sweep

**Files:** `agent.el` (struct definition + any remaining `agent--dispatch*` helpers), `agent-claude.el` and `agent-codex.el` (registration forms), all four test files, `README.org`.

**Steps:**

- [ ] Remove these slots from the `cl-defstruct agent-backend` definition in `agent.el`, from BOTH registration forms, and from any validation/required-keys list:

  `handoff` `run-skill` `audit-project` `debug-backtrace` `act-on-slack-message` `setup-kill-on-exit` `exit` `restart` `discover-skills` `send-command` `submit-command` `start` `start-new` `extract-directory` `extract-instance-name` `account`

  The struct after this step must contain exactly: `name label icon program buffer-p find-all-buffers find-buffers-for-dir start-session session-identity send-string send-return submit target-buffer waiting-p busy-p background-tasks-p duration-ms display-name-suffix account-env-var accounts account-file shared-config-items canonical-home account-init run-prompt skill-roots skill-command-prefix sync-theme modeline-status menu-suffixes before-exit-ready-to-close-p before-kill-check` (`canonical-home` was added by Phase 5, Task 5.3).

- [ ] For each removed slot, find and fix every remaining reader:

  ```bash
  cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent
  grep -n -E ":(handoff|run-skill|audit-project|debug-backtrace|act-on-slack-message|setup-kill-on-exit|exit|restart|discover-skills|send-command|submit-command|start|start-new|extract-directory|extract-instance-name|account)[) ]" agent*.el test/*.el
  ```

  Known pre-phase readers and their fixes (some were already fixed by earlier tasks/phases — verify each):

  | Reader | Fix |
  |---|---|
  | `agent--dispatch`, `agent--dispatch-with-captured-prompt-confirmation` | delete both (Tasks 6.2–6.8 removed all callers) |
  | `agent--before-exit-skill-send-next` (`:submit-command`/`:send-command`/`:send-return`) | use core `agent-submit` (preferred) with `agent-send-string`+`agent-send-return` fallback removed — Phase 3's send wrappers subsume it; simplify to `(agent-submit command buffer)` |
  | `agent--exit-after-before-exit-skill` (`:exit`) | done in Task 6.2 |
  | session-switcher/group code reading `:account`, `:extract-instance-name`, `:extract-directory`, `:start-new`, `:start` (pre-phase lines 533, 554, 614, 652, 1084, 1104–1106) | these read session metadata; Phases 1–2 should already route them through `agent-session` / `start-session`. Any survivor switches to the session struct (`(agent-session-account (agent-session buf))` etc.) |
  | `agent--discover-all-skills` (`:discover-skills`) | done in Task 6.5 |

- [ ] Delete any per-backend wrappers still standing that exist only to fill deleted slots (verify each is no longer referenced, then remove): `agent-claude-send-command`, `agent-claude-submit-command`, `agent-claude-send-return`, `agent-codex-send-command`, `agent-codex-submit-command`, `agent-codex-send-return` — ONLY if Phase 3's send wrappers re-registered them under `send-string`/`submit`/`send-return` slots with new names; if the same functions back the new slots, keep them and just confirm the old keyword entries are gone.

- [ ] Compatibility alias audit. All old interactive commands must resolve. Expected complete alias set after this phase (each `define-obsolete-function-alias ... "0.2"`, living next to the deletion sites in the respective backend file):

  | Old command | New command |
  |---|---|
  | `agent-claude-handoff`, `agent-codex-handoff` | `agent-handoff` |
  | `agent-claude-handoff-from-emacsclient`, `agent-codex-handoff-from-emacsclient` | `agent-handoff-from-emacsclient` |
  | `agent-claude-restart`, `agent-codex-restart` | `agent-restart` |
  | `agent-claude-exit`, `agent-codex-exit` | `agent-exit` |
  | `agent-claude-setup-kill-on-exit`, `agent-codex-setup-kill-on-exit` | `agent-setup-kill-on-exit` |
  | `agent-claude-run-skill`, `agent-codex-run-skill` | `agent-run-skill` |
  | `agent-claude-audit-project`, `agent-codex-audit-project` | `agent-audit-project` |
  | `agent-claude-debug-backtrace`, `agent-codex-debug-backtrace` | `agent-debug-backtrace` |
  | `agent-claude-act-on-slack-message`, `agent-codex-act-on-slack-message` | `agent-act-on-slack-message` |

  (`agent-claude-jump-to-waiting`, `agent-claude-toggle-alert`, `agent-claude-alert-indicator`, and `agent-claude-fix-rendering` get NO aliases: Phase 0 deleted them outright after verifying no external references.)

  Verify in a scratch Emacs after the load check: `(progn (require 'agent-claude) (require 'agent-codex) (cl-every #'fboundp '(agent-claude-handoff agent-codex-restart agent-claude-exit agent-codex-run-skill)))` → `t`. User keybindings live in dotfiles; confirm coverage with `grep -rn -E "agent-(claude|codex)-(handoff|restart|exit|run-skill|audit-project|debug-backtrace|act-on-slack-message|setup-kill-on-exit|jump-to-waiting|toggle-alert)" ~/My\ Drive/dotfiles/emacs/` and list the hits in your final report (do not edit dotfiles; the aliases keep them working).

- [ ] Final reference sweep — all must return nothing (aliases and obsolete markers excepted; filter those visually):

  ```bash
  cd ~/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent
  grep -n "agent--dispatch\b" agent*.el test/*.el
  grep -rn -E "agent-(claude|codex)-(handoff|restart|setup-kill-on-exit|run-skill|audit-project|debug-backtrace|act-on-slack-message)\b" agent*.el test/*.el | grep -v obsolete
  grep -n "agent-skill-command-prefix-alist" agent*.el test/*.el
  ```

- [ ] Update `README.org`: the command tables/sections that list `agent-claude-*`/`agent-codex-*` orchestration commands now name the unified `agent-*` commands; the backend-slot documentation lists the final slot set. Regenerate/adjust `agent.texi` only if it is generated from README.org (check for an export header); otherwise edit the matching nodes.
- [ ] Full verification: run all four test files, then `~/My\ Drive/dotfiles/claude/bin/batch-test.sh agent`. Every file must report `0 unexpected`.
- [ ] Commit: `agent: delete transitional backend slots and per-backend wrappers`

---

**Phase exit criteria.** (1) `grep -c "defun agent-claude-" agent-claude.el` and `defun agent-codex-` counts drop by ~25 combined and no orchestration workflow has two implementations; (2) the `agent-backend` struct contains exactly the 29 contract slots; (3) all old interactive command names still `fboundp` via obsolete aliases; (4) full ERT suite and batch load check green. Not verifiable in batch: live handoff/restart against real CLIs — flag `agent-handoff` and `agent-restart` for an end-to-end session check after the phase lands.

## Phase 7 — Owned lifecycles and registry-driven menus

**Repo:** `/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/` (a git repo; all agent commits happen here). Dotfiles edits happen in `/Users/pablostafforini/My Drive/dotfiles/` and are committed there.

**Drift warning for executors.** All line numbers below are from the pre-refactor source. Phases 1–6 have already changed these files (struct registry, `agent-session`, agent-account.el, unified commands, `agent--add-process-exit-hook`, normalized `run-prompt`). Always locate code by the `grep` commands given in each task, not by line number. Quoted "current code" blocks are verbatim from the pre-refactor tree; if a quoted block differs at execution time, apply the task's *criterion* (stated in each task) to the code you actually find.

**Before starting any Phase 7 task**, confirm the Phase 1–6 contract symbols exist and record the real accessor names (you will substitute them if they differ):

```bash
cd "/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent"
grep -n "cl-defstruct agent-backend" agent.el
grep -n "cl-defstruct (agent-session\|cl-defstruct agent-session" agent.el
grep -n "defun agent--add-process-exit-hook" agent.el
grep -n "defvar agent-backends" agent.el
```

Expected: a struct `agent-backend` with slots including `label`, `menu-suffixes`, `run-prompt`; `agent-backends` as an alist of `(SYMBOL . STRUCT)`; `agent--add-process-exit-hook (buffer fn)`. If `agent-backends` has a different shape (e.g., plain list of structs), adapt the enumeration code in Task 7.4 accordingly and note the adaptation in your report.

**Verification commands used throughout** (run from the package directory):

```bash
"/Users/pablostafforini/My Drive/dotfiles/claude/bin/batch-test.sh" agent
"/Users/pablostafforini/My Drive/dotfiles/claude/bin/elisp-ert" agent test/agent-test.el
"/Users/pablostafforini/My Drive/dotfiles/claude/bin/elisp-ert" agent-claude test/agent-claude-test.el
"/Users/pablostafforini/My Drive/dotfiles/claude/bin/elisp-ert" agent-codex test/agent-codex-test.el
"/Users/pablostafforini/My Drive/dotfiles/claude/bin/elisp-ert" agent-chief test/agent-chief-test.el
```

Expected output for batch-test: `agent loaded successfully`. Expected for elisp-ert: `Ran N tests, N results as expected`.

---

### Task 7.1: Core session-teardown engine in agent.el

**Files:** `/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/agent.el` (session-key section, currently ~485–520), `/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/test/agent-test.el`

- [ ] Locate the session-key section: `grep -n "agent--purge-dead-session-keys\|agent--release-session-key" agent.el`.
- [ ] Add the teardown engine immediately after the `agent--session-keys` defvar (helpers after callers, per style):

```elisp
;;;; Session teardown

(defvar-local agent--teardown-functions nil
  "Functions run once when this session buffer is torn down.
Backends push closures onto this list at session start.  Each
closure is called with no arguments, inside the session buffer,
by `agent--session-teardown'.")

(defvar-local agent--teardown-done nil
  "Non-nil once `agent--session-teardown' has run for this buffer.")

(defun agent--install-session-teardown (&optional buffer)
  "Arrange for session BUFFER to be torn down exactly once.
BUFFER defaults to the current buffer.  Installs a buffer-local
`kill-buffer-hook' entry and a process-exit hook so teardown runs
whether the buffer is killed first or the CLI process exits first."
  (let ((buf (or buffer (current-buffer))))
    (with-current-buffer buf
      (add-hook 'kill-buffer-hook #'agent--session-teardown-current nil t))
    (agent--add-process-exit-hook buf (lambda () (agent--session-teardown buf)))))

(defun agent--session-teardown-current ()
  "Run `agent--session-teardown' for the current buffer."
  (agent--session-teardown (current-buffer)))

(defun agent--session-teardown (buffer)
  "Release every per-session resource owned by session BUFFER.
Runs BUFFER's `agent--teardown-functions', releases its session
key, and schedules a display-name refresh.  Idempotent: only the
first call has any effect."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (unless agent--teardown-done
        (setq agent--teardown-done t)
        (dolist (fn agent--teardown-functions)
          (condition-case err
              (funcall fn)
            (error
             (agent--report-leak "teardown function" "%S signaled: %S" fn err))))
        (setq agent--teardown-functions nil)
        (remhash buffer agent--session-keys)
        (agent--refresh-display-names-deferred)))))

(defun agent--report-leak (kind format &rest args)
  "Report a leaked KIND resource described by FORMAT and ARGS.
Primary cleanup is owned by `agent--session-teardown'; safety
nets call this so escaping resources surface as warnings instead
of being silently mopped up."
  (display-warning
   'agent (format "leaked %s: %s" kind (apply #'format format args))
   :warning))
```

- [ ] Replace `agent--purge-dead-session-keys` (currently agent.el:485–491) so it reports leaks instead of silently mopping. Current verbatim body to replace:

```elisp
(defun agent--purge-dead-session-keys ()
  "Remove entries for buffers that are no longer live."
  (let (dead)
    (maphash (lambda (buf _) (unless (buffer-live-p buf) (push buf dead)))
             agent--session-keys)
    (dolist (buf dead)
      (remhash buf agent--session-keys))))
```

New definition:

```elisp
(defun agent--purge-dead-session-keys ()
  "Drop dead buffers from `agent--session-keys', reporting each as a leak.
`agent--session-teardown' owns key release; a dead entry here
means a session escaped teardown."
  (let (dead)
    (maphash (lambda (buf _) (unless (buffer-live-p buf) (push buf dead)))
             agent--session-keys)
    (dolist (buf dead)
      (agent--report-leak "session key" "dead buffer %s still held a key" buf)
      (remhash buf agent--session-keys))))
```

- [ ] If a Phase 1–6 session-capture function exists (`grep -n "defun agent--capture-session\|defun agent--set-session" agent.el`), add `(agent--install-session-teardown)` to the start-path capture function so any session captured by core gets teardown even if a backend forgets. If only `agent--set-session (buffer session)` exists, add `(agent--install-session-teardown buffer)` at its end.
- [ ] Append to `test/agent-test.el`:

```elisp
(ert-deftest agent-test-session-teardown-runs-once ()
  "Teardown runs registered closures exactly once and releases the key."
  (let ((calls 0))
    (with-temp-buffer
      (push (lambda () (setq calls (1+ calls))) agent--teardown-functions)
      (puthash (current-buffer) "a" agent--session-keys)
      (agent--session-teardown (current-buffer))
      (agent--session-teardown (current-buffer))
      (should (= calls 1))
      (should-not (gethash (current-buffer) agent--session-keys)))))

(ert-deftest agent-test-session-teardown-survives-erroring-closure ()
  "An erroring closure does not abort the rest of teardown."
  (let ((ran nil))
    (with-temp-buffer
      (push (lambda () (setq ran t)) agent--teardown-functions)
      (push (lambda () (error "boom")) agent--teardown-functions)
      (let ((warning-minimum-log-level :emergency))
        (agent--session-teardown (current-buffer)))
      (should ran))))
```

- [ ] Run: `"/Users/pablostafforini/My Drive/dotfiles/claude/bin/elisp-ert" agent test/agent-test.el` (all pass) and `batch-test.sh agent`.
- [ ] Commit: `agent: add owned session teardown engine`

---

### Task 7.2: `agent-claude-mode` — Claude lifecycle ownership

**Files:** `/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/agent-claude.el` (load-time block currently 2591–2614; escape advice 328–329; monet block 865–870; status polling 773–787, 872–939; usage polling 1099–1119), `test/agent-claude-test.el`

**Criterion:** after this task, loading `agent-claude.el` executes NO `add-hook`, `advice-add`, `setq` of a user-visible variable, or `run-with-timer` at top level. The only top-level side effect that remains is `agent-register-backend` (pure data).

- [ ] Locate and delete the load-time block. Current verbatim code at 2591–2614 (delete all of it; the line `(setq claude-code-notification-function #'claude-code-default-notification)` is the user-customization clobber called out in the design):

```elisp
(setq claude-code-notification-function #'claude-code-default-notification)
(add-hook 'claude-code-event-hook #'agent-claude--handle-notification)
(add-hook 'claude-code-event-hook #'agent-claude--handle-stop)
(add-hook 'kill-buffer-query-functions #'agent-protect-buffer)
(add-hook 'claude-code-start-hook #'agent-claude-setup-kill-on-exit)
(add-hook 'claude-code-start-hook #'agent-claude-start-status-polling)
(add-hook 'claude-code-start-hook #'agent-claude--capture-buffer-account)
(add-hook 'claude-code-start-hook #'agent-claude-set-modeline)
(add-hook 'claude-code-start-hook #'agent--refresh-display-names)
(add-hook 'kill-buffer-hook #'agent-claude-stop-status-polling)
(add-hook 'kill-buffer-hook #'agent--refresh-display-names-deferred)
(add-hook 'kill-buffer-hook #'agent-claude--cleanup-monet-session)
(add-hook 'claude-code-start-hook #'agent-disable-scrollback-truncation)
(add-hook 'claude-code-start-hook #'agent-setup-snippet-keys)
(add-hook 'claude-code-start-hook #'agent--assign-session-key)
(add-hook 'claude-code-process-environment-functions
          #'agent-claude--sync-theme-before-start)
(add-hook 'kill-buffer-hook #'agent--release-session-key)
(advice-add 'claude-code--eat-send-return :before
            #'agent--clear-waiting-for-input)
(advice-add 'claude-code--vterm-send-return :before
            #'agent--clear-waiting-for-input)
(advice-add 'claude-code--do-send-command :before
            #'agent--clear-waiting-for-input)
```

- [ ] Delete the load-time escape advice (currently 328–329):

```elisp
(advice-add 'claude-code-send-escape :around
            #'agent-claude--send-escape-in-current-buffer)
```

- [ ] Replace the monet `with-eval-after-load` block (currently 865–870). Current verbatim code to delete:

```elisp
(with-eval-after-load 'monet
  (advice-add 'monet-start-server-in-directory :around
              #'agent-claude--monet-cleanup-before-start)
  (advice-add 'monet--display-diff-buffer :override
              #'agent-claude--display-diff-buffer)
  (run-with-timer 60 60 #'agent-claude--monet-gc-orphaned-servers))
```

New code (place near `agent-claude--monet-gc-orphaned-servers`):

```elisp
(defvar agent-claude--monet-gc-timer nil
  "Repeating timer that reports and reaps leaked monet servers.
Owned by `agent-claude-mode': started on enable, cancelled on
disable.")

(defun agent-claude--monet-install ()
  "Install monet advice and the leak-reporting GC timer.
Idempotent, so deferred installs after re-enables are safe."
  (advice-add 'monet-start-server-in-directory :around
              #'agent-claude--monet-cleanup-before-start)
  (advice-add 'monet--display-diff-buffer :override
              #'agent-claude--display-diff-buffer)
  (unless agent-claude--monet-gc-timer
    (setq agent-claude--monet-gc-timer
          (run-with-timer 60 60 #'agent-claude--monet-gc-orphaned-servers))))

(defun agent-claude--monet-remove ()
  "Remove monet advice and cancel the GC timer."
  (advice-remove 'monet-start-server-in-directory
                 #'agent-claude--monet-cleanup-before-start)
  (advice-remove 'monet--display-diff-buffer
                 #'agent-claude--display-diff-buffer)
  (when agent-claude--monet-gc-timer
    (cancel-timer agent-claude--monet-gc-timer)
    (setq agent-claude--monet-gc-timer nil)))
```

- [ ] Make the monet GC function report leaks (primary cleanup is now teardown). In `agent-claude--monet-gc-orphaned-servers`, change the final `dolist` body from `(delete-process p)` to:

```elisp
          (agent--report-leak "monet server" "%s escaped session teardown"
                              (process-name p))
          (delete-process p)
```

- [ ] Rewrite `agent-claude--read-status` so the dead-buffer branch is a leak assertion (single registration: teardown owns cancellation; the cell is now only a safety net). Replace its `(cancel-timer (car timer-cell))` branch:

```elisp
  (if (not (buffer-live-p buffer))
      (progn
        (agent--report-leak "status timer" "poll timer outlived %s" buffer)
        (cancel-timer (car timer-cell)))
```

- [ ] Add teardown registration and usage refcounting (place after `agent-claude-stop-usage-polling`):

```elisp
(defun agent-claude--register-session-teardown ()
  "Register per-session cleanup for a freshly started Claude session.
Pushes one closure that cancels the status timer, deletes the
status file, stops the monet session, and stops usage polling
when this was the last live Claude session.  Also ensures the
account-wide usage poller is running."
  (when (claude-code--buffer-p (current-buffer))
    (agent--install-session-teardown)
    (let ((buffer (current-buffer)))
      (push (lambda ()
              (when agent-claude--status-timer
                (cancel-timer agent-claude--status-timer)
                (setq agent-claude--status-timer nil))
              (agent-claude--cleanup-status-file)
              (agent-claude--cleanup-monet-session)
              (agent-claude--maybe-stop-usage-polling buffer))
            agent--teardown-functions))
    (agent-claude-start-usage-polling)))

(defun agent-claude--maybe-stop-usage-polling (buffer)
  "Stop usage polling when BUFFER was the last live Claude session."
  (when (null (cl-remove buffer
                         (cl-remove-if-not #'buffer-live-p
                                           (claude-code--find-all-claude-buffers))))
    (agent-claude-stop-usage-polling)))
```

- [ ] Define the mode at the end of the file, just before `(provide 'agent-claude)`:

```elisp
;;;; Minor mode

(defvar agent-claude--saved-notification-function nil
  "Value of `claude-code-notification-function' before enabling the mode.")

(defconst agent-claude--start-hook-functions
  '(agent-claude-setup-kill-on-exit
    agent-claude-start-status-polling
    agent-claude--capture-buffer-account
    agent-claude-set-modeline
    agent--refresh-display-names
    agent-disable-scrollback-truncation
    agent-setup-snippet-keys
    agent--assign-session-key
    agent-claude--register-session-teardown)
  "Functions `agent-claude-mode' adds to `claude-code-start-hook'.")

;;;###autoload
(define-minor-mode agent-claude-mode
  "Global minor mode wiring `claude-code' sessions into agent.
Owns every hook, advice, and timer the Claude backend installs;
nothing is installed at load time.  Disabling removes them
symmetrically and restores `claude-code-notification-function'."
  :global t
  :group 'agent-claude
  (if agent-claude-mode
      (agent-claude--mode-enable)
    (agent-claude--mode-disable)))

(defun agent-claude--mode-enable ()
  "Install Claude backend hooks, advice, and timers."
  (setq agent-claude--saved-notification-function
        claude-code-notification-function)
  (setq claude-code-notification-function #'claude-code-default-notification)
  (add-hook 'claude-code-event-hook #'agent-claude--handle-notification)
  (add-hook 'claude-code-event-hook #'agent-claude--handle-stop)
  (add-hook 'kill-buffer-query-functions #'agent-protect-buffer)
  (dolist (fn agent-claude--start-hook-functions)
    (add-hook 'claude-code-start-hook fn))
  (add-hook 'claude-code-process-environment-functions
            #'agent-claude-account-env)
  (add-hook 'claude-code-process-environment-functions
            #'agent-claude--sync-theme-before-start)
  (advice-add 'claude-code--eat-send-return :before
              #'agent--clear-waiting-for-input)
  (advice-add 'claude-code--vterm-send-return :before
              #'agent--clear-waiting-for-input)
  (advice-add 'claude-code--do-send-command :before
              #'agent--clear-waiting-for-input)
  (advice-add 'claude-code-send-escape :around
              #'agent-claude--send-escape-in-current-buffer)
  (if (featurep 'monet)
      (agent-claude--monet-install)
    (with-eval-after-load 'monet
      (when agent-claude-mode (agent-claude--monet-install)))))

(defun agent-claude--mode-disable ()
  "Remove Claude backend hooks, advice, and timers."
  (setq claude-code-notification-function
        agent-claude--saved-notification-function)
  (remove-hook 'claude-code-event-hook #'agent-claude--handle-notification)
  (remove-hook 'claude-code-event-hook #'agent-claude--handle-stop)
  (unless (bound-and-true-p agent-codex-mode)
    (remove-hook 'kill-buffer-query-functions #'agent-protect-buffer))
  (dolist (fn agent-claude--start-hook-functions)
    (remove-hook 'claude-code-start-hook fn))
  (remove-hook 'claude-code-process-environment-functions
               #'agent-claude-account-env)
  (remove-hook 'claude-code-process-environment-functions
               #'agent-claude--sync-theme-before-start)
  (advice-remove 'claude-code--eat-send-return #'agent--clear-waiting-for-input)
  (advice-remove 'claude-code--vterm-send-return #'agent--clear-waiting-for-input)
  (advice-remove 'claude-code--do-send-command #'agent--clear-waiting-for-input)
  (advice-remove 'claude-code-send-escape
                 #'agent-claude--send-escape-in-current-buffer)
  (agent-claude--monet-remove)
  (agent-claude-stop-usage-polling))
```

Note: if Phase 5 moved `agent-claude-account-env` installation into agent-account.el, check with `grep -rn "agent-claude-account-env" agent*.el` and do not double-install; the mode is the single owner — delete any other installation site.

- [ ] Add `(defvar agent-codex-mode)` near the other forward declarations in agent-claude.el (it is referenced before agent-codex loads).
- [ ] Append to `test/agent-claude-test.el`:

```elisp
(ert-deftest agent-claude-test-mode-symmetric ()
  "Enabling then disabling the mode leaves global state untouched."
  (let ((claude-code-notification-function #'ignore)
        (claude-code-start-hook nil)
        (claude-code-event-hook nil)
        (kill-buffer-query-functions kill-buffer-query-functions))
    (agent-claude-mode 1)
    (should (memq #'agent-claude--handle-stop claude-code-event-hook))
    (should (eq claude-code-notification-function
                #'claude-code-default-notification))
    (agent-claude-mode -1)
    (should-not (memq #'agent-claude--handle-stop claude-code-event-hook))
    (should-not claude-code-start-hook)
    (should (eq claude-code-notification-function #'ignore))
    (should-not agent-claude--monet-gc-timer)))
```

- [ ] Run `batch-test.sh agent-claude` and the claude ERT file; also verify nothing loads at file load:

```bash
"/Users/pablostafforini/My Drive/dotfiles/claude/bin/batch-test.sh" agent-claude \
  '(progn (message "start-hook: %S" claude-code-start-hook) (message "event-hook: %S" claude-code-event-hook))'
```

Expected: both print `nil` (or only entries installed by other packages, none starting with `agent-`).
- [ ] Commit: `agent-claude: own lifecycle in agent-claude-mode`

---

### Task 7.3: `agent-codex-mode` — Codex lifecycle ownership

**Files:** `/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent/agent-codex.el` (install-hooks 1389–1436; duplicate registrations 1475–1476; defensive call sites at 510, 1183, 1206, 1238, 1318, 1376, 1384), `test/agent-codex-test.el`

**Criterion:** identical to Task 7.2, for `agent-codex.el`.

- [ ] Find every call site: `grep -n "agent-codex--install-hooks" agent-codex.el`. Delete the bare call at every site (currently 7 call sites plus the top-level `(agent-codex--install-hooks)` at 1436), then delete the `agent-codex--install-hooks` defun itself. Keep `agent-codex--clear-waiting-before-send-command-to-buffer` and `agent-codex--clear-waiting-before-tui-action` (they are advice bodies, still used).
- [ ] Delete the duplicate load-time registrations (currently 1475–1476), verbatim:

```elisp
(add-hook 'codex-start-hook #'agent-codex-setup-kill-on-exit)
(advice-add 'codex--do-send-command :around #'agent-codex--intercept-exit)
```

- [ ] Add teardown registration (after `agent-codex-setup-kill-on-exit`):

```elisp
(defun agent-codex--register-session-teardown ()
  "Register core session teardown for a freshly started Codex session."
  (when (codex--buffer-p (current-buffer))
    (agent--install-session-teardown)))
```

- [ ] Define the mode at the end of the file, before `(provide 'agent-codex)`:

```elisp
;;;; Minor mode

(defvar agent-codex--saved-notification-function nil
  "Value of `codex-notification-function' before enabling the mode.")

(defconst agent-codex--start-hook-functions
  '(agent--assign-session-key
    agent--refresh-display-names
    agent-disable-scrollback-truncation
    agent-setup-snippet-keys
    agent-fix-rendering
    agent-codex--capture-buffer-account
    agent-codex--record-start-time
    agent-codex-set-modeline
    agent-codex-setup-kill-on-exit
    agent-codex--register-session-teardown)
  "Functions `agent-codex-mode' adds to `codex-start-hook'.")

;;;###autoload
(define-minor-mode agent-codex-mode
  "Global minor mode wiring `codex' sessions into agent.
Owns every hook, advice, and notification handler the Codex
backend installs; nothing is installed at load time.  Disabling
removes them symmetrically and restores
`codex-notification-function'."
  :global t
  :group 'agent-codex
  (if agent-codex-mode
      (agent-codex--mode-enable)
    (agent-codex--mode-disable)))

(defun agent-codex--mode-enable ()
  "Install Codex backend hooks and advice."
  (setq agent-codex--saved-notification-function codex-notification-function)
  (setq codex-notification-function #'agent-codex-notify)
  (add-hook 'codex-event-hook #'agent-codex--handle-notification)
  (add-hook 'kill-buffer-query-functions #'agent-protect-buffer)
  (dolist (fn agent-codex--start-hook-functions)
    (add-hook 'codex-start-hook fn))
  (add-hook 'codex-process-environment-functions #'agent-codex-account-env)
  (add-hook 'codex-process-environment-functions
            #'agent-codex--sync-theme-before-start)
  (advice-add 'codex--do-send-command :before #'agent--clear-waiting-for-input)
  (advice-add 'codex--send-command-to-buffer :before
              #'agent-codex--clear-waiting-before-send-command-to-buffer)
  (advice-add 'codex--terminal-send-return :before
              #'agent--clear-waiting-for-input)
  (advice-add 'codex--send-tui-action :before
              #'agent-codex--clear-waiting-before-tui-action)
  (advice-add 'codex--do-send-command :around #'agent-codex--intercept-exit))

(defun agent-codex--mode-disable ()
  "Remove Codex backend hooks and advice."
  (setq codex-notification-function agent-codex--saved-notification-function)
  (remove-hook 'codex-event-hook #'agent-codex--handle-notification)
  (unless (bound-and-true-p agent-claude-mode)
    (remove-hook 'kill-buffer-query-functions #'agent-protect-buffer))
  (dolist (fn agent-codex--start-hook-functions)
    (remove-hook 'codex-start-hook fn))
  (remove-hook 'codex-process-environment-functions #'agent-codex-account-env)
  (remove-hook 'codex-process-environment-functions
               #'agent-codex--sync-theme-before-start)
  (advice-remove 'codex--do-send-command #'agent--clear-waiting-for-input)
  (advice-remove 'codex--send-command-to-buffer
                 #'agent-codex--clear-waiting-before-send-command-to-buffer)
  (advice-remove 'codex--terminal-send-return #'agent--clear-waiting-for-input)
  (advice-remove 'codex--send-tui-action
                 #'agent-codex--clear-waiting-before-tui-action)
  (advice-remove 'codex--do-send-command #'agent-codex--intercept-exit))
```

- [ ] Add `(defvar agent-claude-mode)` and `(defvar codex-notification-function)` to the forward-declaration block in agent-codex.el if not already declared.
- [ ] Append a symmetric enable/disable ERT test to `test/agent-codex-test.el`, mirroring `agent-claude-test-mode-symmetric` (let-bind `codex-notification-function`, `codex-start-hook`, `codex-event-hook`; assert installation after enable and full removal plus notification restore after disable).
- [ ] Run `batch-test.sh agent-codex '(message "start-hook: %S" codex-start-hook)'` — expect `nil` — and the codex ERT file.
- [ ] Commit: `agent-codex: own lifecycle in agent-codex-mode`

---

### Task 7.4: Registry-driven `agent-menu` backend sections

**Files:** `agent.el` (menu, currently 2024–2052; session-switcher pattern at 619–633), `agent-claude.el` (suffix surgery 3147–3191), `agent-codex.el` (suffix surgery 1509–1546), `test/agent-test.el`

- [ ] Read the dynamic-children pattern already in agent.el (currently 619–633: `agent--session-switcher` + `agent--session-switcher-children`); reuse it. Append a dynamic backends group to `agent-menu` by adding one group vector after the existing `["Sessions"...]["Tools"...]["Prompts"...]["Options"...]` columns block:

```elisp
;;;###autoload (autoload 'agent-menu "agent" nil t)
(transient-define-prefix agent-menu ()
  "Dispatch AI session commands."
  [["Sessions" ...unchanged...]
   ...unchanged columns...]
  [:class transient-columns
   :setup-children agent-menu--backend-children])
```

(Keep the existing static groups byte-for-byte; only append the new bottom group.)

- [ ] Add the children builder after `agent-menu` (adjust accessor names to the real `agent-backend` struct accessors recorded in the preamble check):

```elisp
(defun agent-menu--backend-children (_)
  "Build one menu column per registered backend from its menu-suffixes slot."
  (transient-parse-suffixes
   'agent-menu
   (apply #'vector
          (delq nil (mapcar (lambda (entry)
                              (agent-menu--backend-column (cdr entry)))
                            agent-backends)))))

(defun agent-menu--backend-column (backend)
  "Return a transient column vector for BACKEND, or nil when it has no suffixes."
  (when-let* ((fn (agent-backend-menu-suffixes backend))
              (specs (funcall fn)))
    (apply #'vector (agent-backend-label backend) specs)))
```

- [ ] In agent-claude.el, delete `agent-claude--remove-menu-suffixes`, `agent-claude--append-menu-suffixes`, and `(with-eval-after-load 'agent (agent-claude--append-menu-suffixes))` (currently 3147–3191). Replace with a pure suffix-spec function reproducing the appended suffixes exactly (keys, descriptions, commands from the deleted block):

```elisp
(defun agent-claude--menu-suffixes ()
  "Return Claude Code suffix specs for the unified agent menu."
  '(("B" "switch branch" agent-claude-switch-branch)
    ("N" "new branch" agent-claude-create-branch)
    ("b" "batch todos" agent-claude-batch-todos)
    ("t" "send todo at point" agent-claude-send-todo-at-point)
    ("l" "logs" agent-claude-agent-log-menu)
    ("u" "start status polling" agent-claude-start-status-polling)
    ("U" "stop status polling" agent-claude-stop-status-polling)
    ("-c" agent-claude--infix-account)
    ("-w" agent-claude--infix-warn-kill-with-branches)))
```

Then set `:menu-suffixes #'agent-claude--menu-suffixes` in the `agent-register-backend` call for `claude-code`. Phase 5 unified the account infix class as `agent-account-variable`; run `grep -n "infix-account" agent-claude.el agent-codex.el` and use the current infix command names if they were renamed.

- [ ] In agent-codex.el, delete `agent-codex--remove-menu-suffixes`, `agent-codex--account-menu-location`, `agent-codex--append-menu-suffixes`, and BOTH trailing blocks `(with-eval-after-load 'agent ...)` and `(with-eval-after-load 'agent-claude ...)` (currently 1509–1546). Replace with:

```elisp
(defun agent-codex--menu-suffixes ()
  "Return Codex suffix specs for the unified agent menu."
  '(("R" "codex resume" agent-codex-resume)
    ("F" "codex fork" agent-codex-fork)
    ("-x" agent-codex--infix-account)))
```

and `:menu-suffixes #'agent-codex--menu-suffixes` in the codex registration.
- [ ] Append to `test/agent-test.el` (loads both backends; run with the agent-claude runner so dependencies resolve):

```elisp
(ert-deftest agent-test-menu-backend-children ()
  "Backend menu sections are built from registry slots."
  (require 'agent-claude)
  (require 'agent-codex)
  (let ((children (agent-menu--backend-children nil)))
    (should children)
    (should (= (length children) 2))))
```

- [ ] Run the ERT suites. Then verify every suffix command is interactive (repo convention after transient changes) — run each of these and confirm a non-nil result:

```bash
for sym in agent-claude-switch-branch agent-claude-create-branch agent-claude-batch-todos \
           agent-claude-send-todo-at-point agent-claude-agent-log-menu \
           agent-claude-start-status-polling agent-claude-stop-status-polling \
           agent-claude--infix-account agent-claude--infix-warn-kill-with-branches \
           agent-codex-resume agent-codex-fork agent-codex--infix-account; do
  echo -n "$sym: "; emacsclient -e "(progn (require 'agent-claude) (require 'agent-codex) (and (interactive-form '$sym) t))"
done
```

Expected: `t` for every symbol.
- [ ] Live check: `emacsclient -e "(agent-menu)"` from a running session context is not possible in batch; instead open Emacs and press the `agent-menu` binding (`H-e`); confirm the bottom row shows a "Claude Code" column and a "Codex" column with the keys above, and that pressing `-c`/`-x` prompts for accounts.
- [ ] Commit: `agent: build backend menu sections from the registry`

---

### Task 7.5: Enable the modes from dotfiles

**Files:** `/Users/pablostafforini/My Drive/dotfiles/emacs/config.org` (use-package `agent` block at ~9058; use-package `claude-code` `:hook` block just above ~9047)

- [ ] Locate: `grep -n "(use-package agent$\|(use-package agent " "/Users/pablostafforini/My Drive/dotfiles/emacs/config.org"` (block currently begins at line 9058). In its first `:config` section, change:

```elisp
  :config
  (require 'agent-claude)
  (require 'agent-codex)
  (require 'agent-chief)
```

to:

```elisp
  :config
  (require 'agent-claude)
  (require 'agent-codex)
  (require 'agent-chief)
  (agent-claude-mode 1)
  (agent-codex-mode 1)
```

- [ ] In the `claude-code` use-package block (ends near line 9047), the hook line `(claude-code-process-environment-functions . agent-claude-account-env)` is now redundant — `agent-claude-mode` owns it. Delete that one hook line; keep `(claude-code-process-environment-functions . monet-start-server-function)`.
- [ ] Retangle: `emacsclient -e '(init-build-profile (file-name-directory user-init-file))'`. Expected: returns without error; the tangled init file under the active profile updates.
- [ ] Commit in the dotfiles repo:

```bash
cd "/Users/pablostafforini/My Drive/dotfiles" && git add emacs/config.org && git commit -m "emacs: enable agent backend minor modes"
```

---

### Task 7.6: Phase 7 verification gate

**Files:** none (verification only)

- [ ] From the package dir, run all four ERT files and both batch loads (`batch-test.sh agent`, `batch-test.sh agent-claude`, `batch-test.sh agent-codex`). All must pass.
- [ ] Lifecycle round-trip in batch:

```bash
"/Users/pablostafforini/My Drive/dotfiles/claude/bin/batch-test.sh" agent-codex \
  '(progn (require (quote agent-claude)) (agent-claude-mode 1) (agent-codex-mode 1) (agent-codex-mode -1) (agent-claude-mode -1) (message "hooks after disable: %S %S" claude-code-start-hook codex-start-hook))'
```

Expected: `hooks after disable: nil nil`.
- [ ] Live restart check (the real user-visible behavior): in the running Emacs, `M-x agent-claude-mode` twice (off, on), then start a Claude session via `H-e e`; confirm modeline status appears (status polling alive), kill the session with `agent-exit`, and confirm `M-: (hash-table-count agent--session-keys)` returns the pre-session count and no `*Warnings*` leak entries appear.

---

## Phase 8 — Module slimming, CLI isolation, chief, and docs

Same repo paths, drift rules, and verification commands as Phase 7. Phase 8 assumes Phase 7 is committed.

### Task 8.1: Split agent.el into agent-capture.el, agent-slack.el, agent-snippet.el

**Files:** `agent.el` (capture 1012–1296 plus defcustoms 322–332, defvars 398–402; Slack/Epoch 1743–1981 plus defcustoms/defconst 306–320; snippets 897–998), new `agent-capture.el`, `agent-slack.el`, `agent-snippet.el`, new `test/agent-capture-test.el`, `test/agent-slack-test.el`, `test/agent-snippet-test.el`

**Naming rule for the whole task:** public symbols keep their names (`agent-capture-prompt`, `agent-insert-captured-prompt`, `agent-prompt-capture-mode`, `agent-setup-snippet-keys`, `agent-snippet-tab`, `agent-act-on-slack-message`, `agent-epoch-project-candidates`, and all moved defcustoms). Internal `agent--` helpers are renamed to the new file's `--` prefix.

- [ ] **agent-capture.el.** Create with the standard header (Author/URL/Version/license boilerplate copied from agent.el, `Package-Requires: ((emacs "30.0") (agent "0.1"))`), `(require 'agent)`, `(require 'org)` deferred as today. Move from agent.el:
  - defcustoms `agent-prompt-capture-directory`, `agent-prompt-capture-auto-save-delay`; defvar-local `agent--prompt-capture-save-timer`; defconst `agent--captured-prompt-preview-width`; the org/outline `declare-function`s and `(defvar org-heading-regexp)`.
  - the whole region from `(defun agent-capture-prompt ...)` through `(defun agent--captured-prompt-match-p ...)` (currently 1014–1296), including `agent--resolve-session-buffer`, `agent--read-session-buffer`, `agent--session-candidate-label`, and `agent-prompt-capture-mode`.
  - Renames (apply with global replace inside agent-capture.el AND at any remaining reference in other files; verify with `grep -rn "agent--prompt\|agent--captured\|agent--resolve-session-buffer\|agent--read-session-buffer\|agent--session-candidate-label" *.el test/*.el`):

| old | new |
|---|---|
| `agent--prompt-capture-save-timer` | `agent-capture--save-timer` |
| `agent--captured-prompt-preview-width` | `agent-capture--preview-width` |
| `agent--resolve-session-buffer` | `agent-capture--resolve-session-buffer` |
| `agent--read-session-buffer` | `agent-capture--read-session-buffer` |
| `agent--session-candidate-label` | `agent-capture--session-candidate-label` |
| `agent--prompt-capture-file` | `agent-capture--file` |
| `agent--prompt-session-slug` | `agent-capture--session-slug` |
| `agent--prompt-session-identity` | `agent-capture--session-identity` |
| `agent--open-prompt-capture-file` | `agent-capture--open-file` |
| `agent--ensure-prompt-capture-header` | `agent-capture--ensure-header` |
| `agent--append-prompt-capture-entry` | `agent-capture--append-entry` |
| `agent--prompt-capture-after-change` | `agent-capture--after-change` |
| `agent--cancel-prompt-capture-save` | `agent-capture--cancel-save` |
| `agent--save-prompt-capture-buffer` | `agent-capture--save-buffer` |
| `agent--captured-prompts` | `agent-capture--prompts` |
| `agent--read-captured-prompts` | `agent-capture--read-prompts` |
| `agent--captured-prompt-at-point` | `agent-capture--prompt-at-point` |
| `agent--captured-prompt-body-start` | `agent-capture--prompt-body-start` |
| `agent--select-captured-prompt` | `agent-capture--select-prompt` |
| `agent--captured-prompt-candidate` | `agent-capture--prompt-candidate` |
| `agent--captured-prompt-candidate-label` | `agent-capture--prompt-candidate-label` |
| `agent--captured-prompt-preview` | `agent-capture--prompt-preview` |
| `agent--delete-captured-prompt` | `agent-capture--delete-prompt` |
| `agent--find-captured-prompt` | `agent-capture--find-prompt` |
| `agent--captured-prompt-match-p` | `agent-capture--prompt-match-p` |

  - Add `;;;###autoload` cookies to `agent-capture-prompt` and `agent-insert-captured-prompt` (they already carry them; keep them in the new file). End with `(provide 'agent-capture)`.
  - In agent-capture.el, add the public confirmation entry point used by core close paths:

```elisp
(defun agent-capture-confirm-no-pending (backend buffer action)
  "Confirm ACTION for BACKEND session BUFFER when captures are pending.
Return non-nil when ACTION may proceed."
  (let ((count (length (agent-capture--prompts backend buffer))))
    (or (zerop count)
        (yes-or-no-p
         (format "%s has %d captured prompt%s.  %s anyway? "
                 (agent-display-name buffer) count
                 (if (= count 1) "" "s") action)))))
```

  - In agent.el, replace the body of `agent--confirm-no-captured-prompts` (keep the function in core; exit/restart/handoff call it) with a soft, on-demand load — this is the "load on demand" point, not a top-level require:

```elisp
(defun agent--confirm-no-captured-prompts (backend buffer action)
  "Confirm ACTION for BUFFER when it has pending captured prompts."
  (if (require 'agent-capture nil t)
      (agent-capture-confirm-no-pending backend buffer action)
    t))
```

- [ ] **agent-slack.el.** Create with the same header pattern, `(require 'agent)`. Move from agent.el: the gptel/slack `defvar`/`declare-function` block (currently 1743–1759), everything from `agent--gptel-response-text` through `agent--json-list` (1761–1981), the unified `agent-act-on-slack-message` command and its obsolete alias `agent-debug-slack-message` (Phase 6 moved the command into core; `grep -n "agent-act-on-slack-message" agent.el` to find its current form), and `agent--slot-value`. Internal renames: every moved `agent--X` becomes `agent-slack--X` except the public `agent-act-on-slack-message` and `agent-epoch-project-candidates`. Add `;;;###autoload` to `agent-act-on-slack-message`. `(provide 'agent-slack)`.
- [ ] **Epoch paths become opt-in defcustoms** in agent-slack.el. Delete from agent.el the defconst and both defcustoms (currently 306–320), verbatim:

```elisp
(defconst agent--epoch-project-registry-file-default
  "/Users/pablostafforini/My Drive/Epoch/projects/shared/project-registry.json"
  "Default canonical Epoch project registry file.")

(defcustom agent-epoch-project-registry-file
  agent--epoch-project-registry-file-default
  "JSON registry of canonical Epoch projects."
  :type 'file
  :group 'agent)

(defcustom agent-epoch-projects-root
  "/Users/pablostafforini/My Drive/Epoch/projects/"
  "Root directory containing canonical Epoch automation project files."
  :type 'directory
  :group 'agent)
```

In agent-slack.el define instead:

```elisp
(defcustom agent-epoch-project-registry-file nil
  "JSON registry of canonical Epoch projects.
When nil, Slack message routing is unavailable until configured."
  :type '(choice (const :tag "Unconfigured" nil) file)
  :group 'agent)

(defcustom agent-epoch-projects-root nil
  "Root directory containing canonical Epoch automation project files.
When nil, registry entries with relative paths cannot be resolved."
  :type '(choice (const :tag "Unconfigured" nil) directory)
  :group 'agent)
```

and guard the code paths:

```elisp
(defun agent-epoch-project-candidates ()
  "Return canonical Epoch project candidates from the registry file."
  (unless agent-epoch-project-registry-file
    (user-error "Set `agent-epoch-project-registry-file' to your registry JSON"))
  (unless (file-exists-p agent-epoch-project-registry-file)
    (user-error "Epoch project registry not found: %s"
                agent-epoch-project-registry-file))
  ...)
```

and in `agent-slack--epoch-project-path` / `agent-slack--epoch-project-directory-from-paths`, signal `(user-error "Set `agent-epoch-projects-root' to your Epoch projects directory")` when `agent-epoch-projects-root` is nil and a relative path needs it (the `(t agent-epoch-projects-root)` fallback branch must also raise when nil).
- [ ] **agent-snippet.el.** Create with the same header pattern, `(require 'agent)`. Move the region currently at 897–998 (`agent--expand-snippet-to-text` through `agent-setup-snippet-keys`, including the `with-eval-after-load 'consult-yasnippet` advice block and `agent--snippet-keys-mode` + keymap), plus the yasnippet/consult-yasnippet `declare-function`/`defvar` block and `(declare-function map-values "map")`. Keep `(defvar eat-terminal)` declared in both files (core still uses eat). Renames: `agent--expand-snippet-to-text` → `agent-snippet--expand-to-text`, `agent--consult-yasnippet` → `agent-snippet--consult-yasnippet`, `agent--try-expand-snippet-at-prompt` → `agent-snippet--try-expand-at-prompt`, `agent--snippet-keys-mode-map` → `agent-snippet--keys-mode-map`, `agent--snippet-keys-mode` → `agent-snippet--keys-mode`. Add `;;;###autoload` to `agent-setup-snippet-keys` (both backend modes put it on start hooks, so it must autoload this file). `(provide 'agent-snippet)`.
- [ ] agent.el must NOT `(require ...)` any of the three new files. Confirm the remaining references in agent.el are only: `agent--confirm-no-captured-prompts` (soft require above), menu entries `agent-capture-prompt` / `agent-insert-captured-prompt` / `agent-act-on-slack-message` (autoloaded commands), and hook symbol `agent-setup-snippet-keys` referenced from the backend mode lists (autoloaded). Run `grep -n "capture\|slack\|snippet\|epoch" agent.el` and resolve every remaining hit per this rule.
- [ ] Create the three test files. Template (repeat per module with the module-specific behavior test):

```elisp
;;; agent-capture-test.el --- Tests for agent-capture -*- lexical-binding: t -*-
;;; Commentary:
;; Tests for agent-capture.
;;; Code:
(require 'ert)
(require 'agent-capture)

(ert-deftest agent-capture-test-loads ()
  (should (featurep 'agent-capture)))

(ert-deftest agent-capture-test-read-prompts ()
  "Reading a capture file returns nonempty prompt entries."
  (let ((file (make-temp-file "agent-capture-test" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "#+title: t\n\n* Prompt 2026-06-10 10:00\n"
                    ":PROPERTIES:\n:CREATED: [2026-06-10 Wed 10:00]\n:END:\n\n"
                    "Hello prompt\n"))
          (let ((prompts (agent-capture--read-prompts file)))
            (should (= (length prompts) 1))
            (should (equal (plist-get (car prompts) :text) "Hello prompt"))))
      (delete-file file))))

(provide 'agent-capture-test)
;;; agent-capture-test.el ends here
```

For agent-slack-test.el the behavior tests are: `(should-error (agent-epoch-project-candidates) :type 'user-error)` with `agent-epoch-project-registry-file` let-bound to nil, and a registry-parse test writing a temp JSON `{"projects":[{"id":"p1","title":"T","repo_paths":["r/"],"project_doc_paths":[],"slack_channels":[],"aliases":[],"browser_keywords":[]}]}` with both defcustoms let-bound (root to a temp dir) asserting `:id` equals `"p1"`. For agent-snippet-test.el: load test plus `(should (eq (lookup-key agent-snippet--keys-mode-map (kbd "TAB")) #'agent-snippet-tab))`.
- [ ] Rebuild so elpaca picks up the new files and autoloads: `emacsclient -e "(elpaca-rebuild 'agent)"`. Expected: rebuild finishes without error.
- [ ] Run: all three new ERT files via `elisp-ert agent test/agent-<module>-test.el`, plus `batch-test.sh agent` and the four pre-existing ERT files (regressions).
- [ ] **Dotfiles:** in the `use-package agent` `:custom` block (config.org ~9067), add:

```elisp
  (agent-epoch-project-registry-file
   "/Users/pablostafforini/My Drive/Epoch/projects/shared/project-registry.json")
  (agent-epoch-projects-root "/Users/pablostafforini/My Drive/Epoch/projects/")
```

Retangle with `emacsclient -e '(init-build-profile (file-name-directory user-init-file))'`, then commit in dotfiles: `emacs: configure agent epoch project paths`.
- [ ] Commit in the agent repo: `agent: split capture, slack, and snippet modules`

---

### Task 8.2: Create agent-claude-cli.el — quarantine CLI conventions

**Files:** new `agent-claude-cli.el`, `agent-claude.el` (merge engine 444–646; usage endpoint 964–974; keychain 1069–1097; transcript JSONL 2710–2830; projects-dir 3067–3093), new `test/agent-claude-cli-test.el`

- [ ] Record the CLI version for the convention comments: run `claude --version` and substitute its output for `<VERSION>` below.
- [ ] Create `agent-claude-cli.el` (header pattern as before; `Package-Requires: ((emacs "30.0"))`; requires only `json`, `subr-x`, `url` — deliberately NOT agent-claude, so it stays a leaf). Add the warn-once machinery first:

```elisp
(defvar agent-claude-cli--warned nil
  "Keys already reported by `agent-claude-cli--warn-once'.")

(defun agent-claude-cli--warn-once (key format &rest args)
  "Warn once per KEY with FORMAT and ARGS, then stay silent.
Replaces the silent nil-on-failure behavior of the CLI-convention
helpers so breakage after a CLI update surfaces exactly once."
  (unless (member key agent-claude-cli--warned)
    (push key agent-claude-cli--warned)
    (display-warning 'agent-claude-cli (apply #'format format args) :warning)))
```

- [ ] Move the following groups, each prefixed by a convention header comment of the form:

```elisp
;; CLI convention: <description of the undocumented behavior relied on>.
;; Last verified against Claude Code <VERSION> on 2026-06-10.
```

Move table (old name in agent-claude.el → new name in agent-claude-cli.el; bodies are moved verbatim except for the warn-once edits listed afterward). The keychain/oauth pair takes the account *config dir* (a path) instead of an account name, so the CLI file does not depend on `agent-claude-accounts`:

| group | old | new |
|---|---|---|
| keychain | `agent-claude--keychain-service` | `agent-claude-cli-keychain-service (config-dir)` — when CONFIG-DIR nil return `"Claude Code-credentials"`, else the sha256-prefix form |
| keychain | `agent-claude--get-oauth-token` | `agent-claude-cli-oauth-token (config-dir)` |
| usage API | URL literal + headers inside `agent-claude--url-retrieve-usage` | `agent-claude-cli-usage-endpoint` defconst (`"https://api.anthropic.com/api/oauth/usage"`), `agent-claude-cli-usage-beta-header` defconst (`"oauth-2025-04-20"`), and `agent-claude-cli-fetch-usage (token callback cbargs)` wrapping `url-retrieve` with the same `url-*` bindings |
| projects dir | `agent-claude--encode-project-cwd` | `agent-claude-cli-encode-project-cwd` |
| projects dir | `agent-claude--project-dir-for` | `agent-claude-cli-project-dir` |
| projects dir | `agent-claude--link-session-into-project` | `agent-claude-cli-link-session-into-project` |
| transcripts | `agent-claude--read-session-header` | `agent-claude-cli-read-session-header` |
| transcripts | `agent-claude--read-session-prompt` | `agent-claude-cli-read-session-prompt` |
| transcripts | `agent-claude--user-message-prompt-p` | `agent-claude-cli--user-message-prompt-p` |
| transcripts | `agent-claude--root-prompt` | `agent-claude-cli--root-prompt` |
| transcripts | `agent-claude--branch-prompt` | `agent-claude-cli--branch-prompt` |
| transcripts | `agent-claude--parse-jsonl-line` | `agent-claude-cli--parse-jsonl-line` |
| transcripts | `agent-claude--meta-from-json` | `agent-claude-cli--meta-from-json` |
| transcripts | `agent-claude--truncate-prompt` | `agent-claude-cli--truncate-prompt` |
| transcripts | `agent-claude--scan-session-headers` | `agent-claude-cli-scan-session-headers` |
| .claude.json | `agent-claude--shared-claude-json-keys` | `agent-claude-cli-shared-claude-json-keys` |
| .claude.json | `agent-claude--read-claude-json` | `agent-claude-cli-read-claude-json` |
| .claude.json | `agent-claude--write-claude-json` | `agent-claude-cli-write-claude-json` |
| .claude.json | `agent-claude--merge-mcp-servers` | `agent-claude-cli-merge-mcp-servers` |
| .claude.json | `agent-claude--deep-merge-env` | `agent-claude-cli--deep-merge-env` |
| .claude.json | `agent-claude--merge-project` | `agent-claude-cli-merge-project` |

The orchestration functions (`agent-claude--sync-account-config`, `--collect-all-projects`, `--all-claude-json-paths`, symlink helpers) STAY in agent-claude.el (or in agent-account integration if Phase 5 moved them — check `grep -n "sync-account-config" agent-claude.el agent-account.el`) and now call the `agent-claude-cli-` names. `(require 'agent-claude-cli)` at the top of agent-claude.el.
- [ ] Worked example of the keychain signature change (callers pass the resolved config dir):

```elisp
;; agent-claude.el, in agent-claude--fetch-usage-for-account:
(when-let* ((config-dir (alist-get account agent-claude-accounts nil nil #'string=))
            (token (agent-claude-cli-oauth-token (expand-file-name config-dir))))
  ...)
;; default account (no multi-account): (agent-claude-cli-oauth-token nil)
```

Find every caller with `grep -n "keychain-service\|get-oauth-token" agent-claude.el` and migrate each the same way.
- [ ] Warn-once edits (replace silent nil branches):
  - `agent-claude-cli-read-claude-json`: the `(error nil)` handler becomes `(error (agent-claude-cli--warn-once (list 'claude-json path) "unreadable or invalid JSON at %s" path) nil)`.
  - `agent-claude-cli-oauth-token`: when the `security` call yields no parseable JSON or no `:claudeAiOauth`, call `(agent-claude-cli--warn-once (list 'oauth service) "no OAuth credentials in Keychain service %s" service)` before returning nil.
  - `agent-claude-cli-read-session-header`: `(error nil)` → warn-once keyed by `(list 'session-header jsonl-file)` with message `"unparseable session header in %s"`, then nil.
- [ ] Tests (`test/agent-claude-cli-test.el`): load test; `(should (equal (agent-claude-cli-encode-project-cwd "/a/b c/d") "-a-b-c-d"))`; keychain determinism `(should (string-prefix-p "Claude Code-credentials-" (agent-claude-cli-keychain-service "/tmp/x")))` and `(should (equal (agent-claude-cli-keychain-service nil) "Claude Code-credentials"))`; warn-once memo (call twice with same key, assert `agent-claude-cli--warned` has one entry); session-header round-trip from a temp `.jsonl` whose first line is `{"sessionId":"s1","forkedFrom":{"sessionId":"s0","messageUuid":"u0"}}`.
- [ ] `emacsclient -e "(elpaca-rebuild 'agent)"`, run the new ERT file plus `elisp-ert agent test/agent-claude-test.el` and `batch-test.sh agent-claude`.
- [ ] Commit: `agent-claude: isolate CLI conventions in agent-claude-cli`

---

### Task 8.3: Status-file identity via per-process UUID

**Files:** `agent-claude.el` (status file naming, currently 918–939), `etc/claude-code-statusline.sh`, `test/agent-claude-test.el`

- [ ] In agent-claude.el, add near the status-polling section:

```elisp
(defvar agent-claude--pending-status-uuid nil
  "Status UUID for the Claude process currently being started.
Set by `agent-claude--status-uuid-env' on the environment hook and
consumed by `agent-claude--capture-status-uuid' on the start hook.")

(defvar-local agent-claude--status-uuid nil
  "Per-process UUID keying this session's statusline file.
Restarted sessions reuse buffer names, so files keyed by buffer
name would be inherited from dead processes; the UUID is unique
per CLI process.")

(defun agent-claude--status-uuid-env (_buffer-name _dir)
  "Return the AGENT_SESSION_UUID environment entry for a new session."
  (setq agent-claude--pending-status-uuid (agent-claude--generate-uuid))
  (list (format "AGENT_SESSION_UUID=%s" agent-claude--pending-status-uuid)))

(defun agent-claude--capture-status-uuid ()
  "Store the pending status UUID buffer-locally at session start."
  (when (claude-code--buffer-p (current-buffer))
    (setq agent-claude--status-uuid agent-claude--pending-status-uuid)
    (setq agent-claude--pending-status-uuid nil)))

(defun agent-claude--generate-uuid ()
  "Return a random UUID-shaped string for status-file identity."
  (format "%08x-%04x-%04x-%04x-%012x"
          (random (expt 2 32)) (random (expt 2 16)) (random (expt 2 16))
          (random (expt 2 16)) (random (expt 2 48))))
```

- [ ] Rekey the status file. Replace `agent-claude--status-file` / `agent-claude--status-file-name` (current code hashes `(buffer-name)`):

```elisp
(defun agent-claude--status-file ()
  "Return the status file path for the current buffer.
Keyed by the per-process UUID when available; falls back to the
buffer name for sessions started before the UUID existed."
  (expand-file-name
   (concat (secure-hash 'sha256 (or agent-claude--status-uuid (buffer-name)))
           ".json")
   agent-claude-status-directory))
```

Delete `agent-claude--status-file-name` and migrate its other callers (`grep -n "status-file-name" agent-claude.el`).
- [ ] Add the startup sweep:

```elisp
(defconst agent-claude--status-file-max-age (* 7 24 60 60)
  "Seconds after which an unclaimed status file is considered stale.")

(defun agent-claude--sweep-stale-status-files ()
  "Delete status files older than `agent-claude--status-file-max-age'."
  (when (file-directory-p agent-claude-status-directory)
    (dolist (file (directory-files agent-claude-status-directory t "\\.json\\'"))
      (when-let* ((mtime (file-attribute-modification-time
                          (file-attributes file))))
        (when (> (float-time (time-subtract (current-time) mtime))
                 agent-claude--status-file-max-age)
          (delete-file file))))))
```

- [ ] Wire into `agent-claude-mode`: in `agent-claude--mode-enable`, add `(agent-claude--sweep-stale-status-files)` and `(add-hook 'claude-code-process-environment-functions #'agent-claude--status-uuid-env)`; add `agent-claude--capture-status-uuid` to `agent-claude--start-hook-functions` (place it before `agent-claude-start-status-polling` in the list). Mirror the removals in `agent-claude--mode-disable`. Deletion of the file at session end already flows through the Phase 7 teardown closure (`agent-claude--cleanup-status-file` uses `agent-claude--status-file`, which now reads the buffer-local UUID).
- [ ] Replace `etc/claude-code-statusline.sh` with this full revised script:

```bash
#!/bin/bash
# Claude Code statusline script.
# Reads JSON from stdin and writes it to a temp file for Emacs polling.
# The file is keyed by AGENT_SESSION_UUID, set per CLI process by
# agent-claude, so a restarted session that reuses a buffer name does
# not inherit a dead process's status file.  Falls back to
# CLAUDE_BUFFER_NAME for sessions started without the UUID.
# Requires: shasum or sha256sum

input=$(cat)
KEY=${AGENT_SESSION_UUID:-$CLAUDE_BUFFER_NAME}
if command -v shasum >/dev/null 2>&1; then
    SAFE_NAME=$(printf '%s' "$KEY" | shasum -a 256 | awk '{print $1}')
elif command -v sha256sum >/dev/null 2>&1; then
    SAFE_NAME=$(printf '%s' "$KEY" | sha256sum | awk '{print $1}')
else
    echo "agent: neither shasum nor sha256sum is available" >&2
    exit 1
fi
STATUS_DIR=${AGENT_CLAUDE_STATUS_DIR:-${TMPDIR:-/tmp}/claude-code-status}
mkdir -p "$STATUS_DIR"
printf '%s' "$input" > "$STATUS_DIR/${SAFE_NAME}.json"
```

- [ ] Tests in `test/agent-claude-test.el`:

```elisp
(ert-deftest agent-claude-test-status-file-keyed-by-uuid ()
  "Two buffers with the same name but different UUIDs get distinct files."
  (with-temp-buffer
    (setq-local agent-claude--status-uuid "uuid-a")
    (let ((a (agent-claude--status-file)))
      (setq-local agent-claude--status-uuid "uuid-b")
      (should-not (equal a (agent-claude--status-file))))))

(ert-deftest agent-claude-test-status-uuid-env-shape ()
  "The env hook returns one AGENT_SESSION_UUID entry."
  (let ((entries (agent-claude--status-uuid-env "buf" "/tmp/")))
    (should (= (length entries) 1))
    (should (string-prefix-p "AGENT_SESSION_UUID=" (car entries)))))
```

- [ ] Shell-level check of the script:

```bash
cd "/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent"
echo '{"k":1}' | AGENT_SESSION_UUID=test-uuid AGENT_CLAUDE_STATUS_DIR=/tmp/agent-status-test bash etc/claude-code-statusline.sh
ls /tmp/agent-status-test/   # expect one <sha256-of-test-uuid>.json
python3 -c "import hashlib;print(hashlib.sha256(b'test-uuid').hexdigest())"  # must match the filename
rm -rf /tmp/agent-status-test
```

- [ ] Run claude ERT + batch-test. Commit: `agent-claude: key status files by per-process uuid`

---

### Task 8.4: Codex TOML helpers with per-file cache

**Files:** `agent-codex.el` (modeline read 525–608; theme write 610–656), `test/agent-codex-test.el`

- [ ] Delete `agent-codex--config-model-cache`, `agent-codex--parse-config-value`, `agent-codex--parse-config-model`, `agent-codex--parse-config-effort`, `agent-codex--read-config-field` (the single-slot cache that thrashes across accounts), and the body of `agent-codex--sync-theme-to-config`.
- [ ] Add the shared helpers (place in a new `;;;;; TOML helpers` section before the modeline section):

```elisp
(defvar agent-codex--toml-cache (make-hash-table :test #'equal)
  "Map from config file path to (MTIME . VALUES) for TOML reads.
VALUES maps (KEY . SECTION) cons keys to string values, so reads
for different account config files never evict each other.")

(defun agent-codex--toml-get (file key &optional section)
  "Return the string value of KEY in TOML FILE, or nil.
With SECTION, look KEY up inside the [SECTION] table; otherwise
look it up in the top-level table before the first section
header.  Results are cached per FILE keyed by modification time."
  (when-let* ((mtime (file-attribute-modification-time
                      (file-attributes file))))
    (let* ((entry (gethash file agent-codex--toml-cache))
           (values (if (and entry (equal (car entry) mtime))
                       (cdr entry)
                     (cdr (puthash file
                                   (cons mtime (make-hash-table :test #'equal))
                                   agent-codex--toml-cache))))
           (cache-key (cons key section))
           (cached (gethash cache-key values 'agent-codex--toml-miss)))
      (if (eq cached 'agent-codex--toml-miss)
          (puthash cache-key (agent-codex--toml-read-value file key section)
                   values)
        cached))))

(defun agent-codex--toml-read-value (file key section)
  "Read KEY from TOML FILE inside SECTION, without caching."
  (with-temp-buffer
    (insert-file-contents file)
    (goto-char (point-min))
    (pcase-let ((`(,beg . ,end) (agent-codex--toml-region section)))
      (when beg
        (goto-char beg)
        (when (re-search-forward
               (format "^%s *= *\"\\([^\"]*\\)\"" (regexp-quote key)) end t)
          (match-string 1))))))

(defun agent-codex--toml-region (section)
  "Return the (BEG . END) region for SECTION in the current buffer.
A nil SECTION means the top-level table: point-min up to the
first section header.  Returns (nil . nil) when SECTION is absent."
  (goto-char (point-min))
  (if (null section)
      (cons (point-min)
            (if (re-search-forward "^\\[" nil t)
                (line-beginning-position)
              (point-max)))
    (if (re-search-forward (format "^\\[%s\\]" (regexp-quote section)) nil t)
        (cons (point)
              (if (re-search-forward "^\\[" nil t)
                  (line-beginning-position)
                (point-max)))
      (cons nil nil))))

(defun agent-codex--toml-set (file key value &optional section)
  "Set KEY to string VALUE in TOML FILE, inside [SECTION] when given.
Create the file and the section as needed.  Write only when the
content changes; return non-nil in that case.  Invalidates the
read cache for FILE."
  (make-directory (file-name-directory file) t)
  (with-temp-buffer
    (when (file-exists-p file)
      (insert-file-contents file))
    (let ((original (buffer-string))
          (new-line (format "%s = \"%s\"" key value)))
      (pcase-let ((`(,beg . ,end) (agent-codex--toml-region section)))
        (cond
         ((and beg (progn (goto-char beg)
                          (re-search-forward
                           (format "^%s *= *\"[^\"]*\"" (regexp-quote key))
                           end t)))
          (replace-match new-line t t))
         (beg
          (goto-char beg)
          (if section
              (insert "\n" new-line)
            (goto-char end)
            (insert new-line "\n")))
         (t
          (goto-char (point-max))
          (unless (or (bobp) (bolp)) (insert "\n"))
          (unless (bobp) (insert "\n"))
          (insert (format "[%s]\n" section) new-line "\n"))))
      (unless (equal original (buffer-string))
        (write-region (point-min) (point-max) file nil 'silent)
        (remhash file agent-codex--toml-cache)
        t))))
```

- [ ] Rebuild the consumers on top:

```elisp
(defun agent-codex--read-config-model (&optional account)
  "Return the model declared in ACCOUNT's Codex config, or nil."
  (agent-codex--toml-get (agent-codex--config-file account) "model"))

(defun agent-codex--read-config-effort (&optional account)
  "Return the reasoning effort declared in ACCOUNT's Codex config, or nil."
  (agent-codex--toml-get (agent-codex--config-file account)
                         "model_reasoning_effort"))
```

and `agent-codex--sync-theme-to-config` becomes:

```elisp
(defun agent-codex--sync-theme-to-config (&optional theme)
  "Update `tui.theme' in the active Codex config to THEME.
When THEME is nil, use the current Emacs AI theme.  Return
non-nil when the file changed."
  (let* ((theme (or theme (agent--theme)))
         (account (or agent-codex--pending-account
                      agent-codex--buffer-account))
         (_ (when account
              (agent-codex--sync-account-home account)))
         (config-file (agent-codex--config-file account)))
    (agent-codex--toml-set config-file "theme" theme "tui")))
```

Behavior note (intended fix): the old top-level regex could match a `model = ...` line inside a section; the new top-level lookup is bounded to the region before the first `[`.
- [ ] Tests in `test/agent-codex-test.el`:

```elisp
(ert-deftest agent-codex-test-toml-roundtrip ()
  "toml-set writes values that toml-get reads back, per section."
  (let ((file (make-temp-file "agent-codex-toml" nil ".toml")))
    (unwind-protect
        (progn
          (should (agent-codex--toml-set file "model" "gpt-5.2" nil))
          (should (agent-codex--toml-set file "theme" "dark" "tui"))
          (should (equal (agent-codex--toml-get file "model") "gpt-5.2"))
          (should (equal (agent-codex--toml-get file "theme" "tui") "dark"))
          (should-not (agent-codex--toml-get file "theme"))
          (should-not (agent-codex--toml-set file "theme" "dark" "tui")))
      (delete-file file))))

(ert-deftest agent-codex-test-toml-cache-per-file ()
  "Reads from two files do not evict each other."
  (let ((a (make-temp-file "agent-codex-a" nil ".toml"))
        (b (make-temp-file "agent-codex-b" nil ".toml")))
    (unwind-protect
        (progn
          (agent-codex--toml-set a "model" "model-a" nil)
          (agent-codex--toml-set b "model" "model-b" nil)
          (agent-codex--toml-get a "model")
          (agent-codex--toml-get b "model")
          (should (equal (agent-codex--toml-get a "model") "model-a"))
          (should (= (hash-table-count agent-codex--toml-cache) 2)))
      (delete-file a) (delete-file b))))
```

- [ ] Run codex ERT + batch-test. Commit: `agent-codex: read and write config.toml through shared helpers`

---

### Task 8.5: agent-chief — structured heartbeats, single state variable

**Files:** `agent-chief.el` (state vars 154–182; commands 200–261; session handlers 438–504; bottom hooks 721–725), `test/agent-chief-test.el`

- [ ] Read the current file fully first (`agent-chief.el` is ~730 lines pre-refactor; Phase 6 already moved its backend `pcase` dispatch to registry slots — `grep -n "pcase agent-chief-backend" agent-chief.el` to see what remains).
- [ ] **Delete** (verbatim symbols, after confirming no other references with `grep -n "<symbol>" agent-chief.el test/agent-chief-test.el`): `agent-chief--running`, `agent-chief--session-start-marker`, `agent-chief--session-awaiting-heartbeat`, `agent-chief--clear-session-heartbeat-state`, `agent-chief--session-response-text`, `agent-chief--extract-session-reply`, `agent-chief--last-match-position`, `agent-chief--handle-backend-event`, `agent-chief--handle-session-ready`, and the two bottom blocks:

```elisp
(with-eval-after-load 'agent-codex
  (add-hook 'codex-event-hook #'agent-chief--handle-backend-event))

(with-eval-after-load 'agent-claude
  (add-hook 'claude-code-event-hook #'agent-chief--handle-backend-event))
```

(These were the terminal-scraping channel; the structured channel below replaces them. They were also agent-chief's only load-time hooks, so the file now matches the Phase 7 no-load-time-effects criterion.)
- [ ] **Add** the single state variable and the structured heartbeat path:

```elisp
(defvar-local agent-chief--heartbeat-state nil
  "Heartbeat state for the chief session buffer: nil or `in-flight'.")

(defvar agent-chief--stateless-in-flight nil
  "Non-nil while a stateless chief tick is in progress.")
```

Rewrite `agent-chief-session-heartbeat`:

```elisp
;;;###autoload
(defun agent-chief-session-heartbeat ()
  "Run one heartbeat for the interactive chief-of-staff session.
The heartbeat runs out-of-band through the backend's run-prompt
slot, so the live session buffer stays reserved for conversation."
  (interactive)
  (let ((buffer (agent-chief--ensure-session)))
    (if (buffer-local-value 'agent-chief--heartbeat-state buffer)
        (message "Agent chief heartbeat skipped; previous heartbeat still running")
      (with-current-buffer buffer
        (setq agent-chief--heartbeat-state 'in-flight))
      (agent-chief--run-backend
       (agent-chief--session-heartbeat-prompt)
       (lambda (result)
         (agent-chief--handle-heartbeat-result buffer result))))))

(defun agent-chief--handle-heartbeat-result (buffer result)
  "Apply heartbeat RESULT and clear BUFFER's in-flight state."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (setq agent-chief--heartbeat-state nil)))
  (if (not (zerop (or (plist-get result :exit-code) 1)))
      (message "Agent chief heartbeat failed: %s"
               (or (plist-get result :text) "(no output)"))
    (let ((reply (agent-chief--parse-heartbeat-reply
                  (or (plist-get result :text) ""))))
      (setq agent-chief--last-session-response reply)
      (pcase (car reply)
        ('no-nudge nil)
        ('nudge (funcall agent-chief-notify-function "Chief of staff"
                         (cdr reply)))
        (_ (funcall agent-chief-notify-function "Chief of staff"
                    (agent-chief--truncate-message (cdr reply))))))))

(defun agent-chief--parse-heartbeat-reply (text)
  "Return a cons describing the structured heartbeat reply in TEXT."
  (let ((trimmed (string-trim text)))
    (cond
     ((string-match "^Nudge:[ \t]*\\(.+\\)" trimmed)
      (cons 'nudge (string-trim (match-string 1 trimmed))))
     ((string-match-p "^No nudge\\.?$" trimmed)
      (cons 'no-nudge nil))
     (t (cons 'unknown trimmed)))))
```

- [ ] Update `agent-chief--session-heartbeat-prompt`: the heartbeat no longer shares the session's conversation, so delete the line `"Review the current day plan, explicit state, and this conversation."` and replace with `"Review the current day plan and explicit state."`, and change the no-nudge instruction line to `"If no nudge is warranted, respond exactly \`No nudge.\`"` (unchanged) — the nudge/no-nudge contract is now the structured channel.
- [ ] Route `agent-chief--run-backend` through the registry `run-prompt` slot (Phase 6 normalized the signature to `(prompt &key directory callback)`; if Phase 6 already rewrote this function, just confirm it matches):

```elisp
(defun agent-chief--run-backend (prompt callback)
  "Run PROMPT through `agent-chief-backend' and call CALLBACK with the result."
  (agent-chief--require-backend)
  (let ((run (agent-backend-run-prompt
              (cdr (assq agent-chief-backend agent-backends)))))
    (unless run
      (user-error "Backend %S does not support run-prompt" agent-chief-backend))
    (funcall run prompt :directory agent-chief-directory :callback callback)))
```

- [ ] Update remaining users of the deleted state: in `agent-chief-stateless-tick`, replace `agent-chief--running` with `agent-chief--stateless-in-flight` (both the guard and the two `setq` sites, including the one inside the callback). In `agent-chief-stop`, replace the `--clear-session-heartbeat-state` call with:

```elisp
  (setq agent-chief--stateless-in-flight nil)
  (when-let* ((buffer (agent-chief--session-buffer)))
    (with-current-buffer buffer
      (setq agent-chief--heartbeat-state nil)))
```

In `agent-chief-start-session`, delete the `(agent-chief--clear-session-heartbeat-state buffer)` line. In the old `agent-chief--run-backend` error branch, the `(setq agent-chief--running nil)` disappears with the rewrite.
- [ ] `agent-chief--submit-to-session` stays (introduction, notes, and day-plan messages still go to the live buffer); migrate its `agent--backend-get backend :submit-command` lookup to the core wrapper `(agent-submit prompt target)` per the Phase 1–6 contract.
- [ ] Tests in `test/agent-chief-test.el`:

```elisp
(ert-deftest agent-chief-test-parse-heartbeat-reply ()
  (should (equal (agent-chief--parse-heartbeat-reply "No nudge.")
                 '(no-nudge . nil)))
  (should (equal (agent-chief--parse-heartbeat-reply "Nudge: drink water")
                 '(nudge . "drink water")))
  (should (eq (car (agent-chief--parse-heartbeat-reply "something else"))
              'unknown)))

(ert-deftest agent-chief-test-heartbeat-result-clears-state ()
  (with-temp-buffer
    (setq-local agent-chief--heartbeat-state 'in-flight)
    (let ((agent-chief-notify-function #'ignore))
      (agent-chief--handle-heartbeat-result
       (current-buffer) '(:exit-code 0 :text "No nudge.")))
    (should-not agent-chief--heartbeat-state)))
```

- [ ] Run `elisp-ert agent test/agent-chief-test.el` and `batch-test.sh agent-chief`. Commit: `agent-chief: run heartbeats through run-prompt`

---

### Task 8.6: Delete the `agent--backend-get` shim and dead transitional code; compile gate

**Files:** all `*.el` and `test/*.el` in the package

- [ ] Enumerate surviving shim callers: `grep -rn "agent--backend-get" *.el test/*.el`. (Pre-refactor there were ~35 sites in agent.el plus 5 in agent-chief.el; Phases 1–6 and earlier Phase 7/8 tasks removed most. Migrate whatever remains.) Migration mapping from plist key to the locked contract:

| plist key | replacement |
|---|---|
| `:buffer-p` | `(agent-backend-buffer-p BACKEND-STRUCT)` |
| `:find-all-buffers` | `(agent-backend-find-all-buffers ...)` |
| `:find-buffers-for-dir` | `(agent-backend-find-buffers-for-dir ...)` |
| `:label` / `:icon` / `:program` | `(agent-backend-label ...)` etc. |
| `:directory` | `(agent-session-directory (agent-session BUFFER))` |
| `:extract-instance-name` | `(agent-backend-session-identity ...)` or `(agent-session-instance (agent-session BUFFER))` |
| `:account` | `(agent-session-account (agent-session BUFFER))` |
| `:send-command` / `:submit-command` / `:send-return` | core wrappers `agent-send-string` / `agent-submit` / `agent-send-return` |
| `:start` / `:start-new` | `(agent-start-session SESSION ...)` / `(agent-backend-start-session ...)` |
| `:waiting-p` / `:busy-p` / `:background-tasks-p` / `:duration-ms` | `(agent-backend-waiting-p ...)` etc. (`:background-tasks-p` → `background-tasks-p` slot) |
| `:exit` / `:restart` / `:handoff` / `:run-skill` / `:audit-project` / `:debug-backtrace` | unified core commands (`agent-exit`, `agent-restart`, `agent-handoff`, `agent-run-skill`, ...) |
| `:sync-theme` / `:before-exit-ready-to-close-p` / `:discover-skills` | `sync-theme` / `before-exit-ready-to-close-p` / `skill-roots` slots |

Worked example (agent-chief.el, pre-refactor 346–352):

```elisp
;; before
(defun agent-chief--backend-buffers ()
  "Return buffers for `agent-chief-backend' in `agent-chief-directory'."
  (when-let* ((fn (agent--backend-get agent-chief-backend
                                      :find-buffers-for-dir)))
    (funcall fn (file-name-as-directory
                 (file-truename
                  (expand-file-name agent-chief-directory))))))
;; after
(defun agent-chief--backend-buffers ()
  "Return buffers for `agent-chief-backend' in `agent-chief-directory'."
  (when-let* ((backend (cdr (assq agent-chief-backend agent-backends)))
              (fn (agent-backend-find-buffers-for-dir backend)))
    (funcall fn (file-name-as-directory
                 (file-truename
                  (expand-file-name agent-chief-directory))))))
```

- [ ] After zero grep hits remain, delete the `agent--backend-get` defun from agent.el.
- [ ] Delete dead transitional code — verify each is unused (`grep -rn "<name>" *.el test/*.el` returns only the definition) before deleting: `agent-claude--session-keys` and `agent-claude--home-row-keys` compatibility aliases (agent-claude.el 187–190); the `(when (fboundp 'agent--start-new-session) (fmakunbound 'agent--start-new-session))` form (agent.el 616–617); `agent-claude--send-sigwinch-after-delay` / `agent-claude--send-sigwinch` / `agent-claude-fix-rendering` if they merely duplicate the core `agent-fix-rendering` path (migrate any caller to the core functions first); `agent-claude--sanitize-buffer-name` (orphaned by Task 8.3); `agent-claude--refresh-display-names` (trivial wrapper); `agent-chief--legacy-json-system-prompt` and `agent-chief--normalize-system-prompt` if the legacy value no longer appears in any user config you control (check the dotfiles grep: `grep -rn "chief" "/Users/pablostafforini/My Drive/dotfiles/emacs/config.org"`; if uncertain, keep and note). Keep `define-obsolete-*` aliases — they are public API.
- [ ] **Byte-compile gate.** If Phases 1–6 added a Makefile (`ls Makefile`), run `make compile`. Otherwise run:

```bash
cd "/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent"
emacs --batch \
  --eval "(dolist (dir (file-expand-wildcards \"$HOME/.config/emacs-profiles/8.3.0-dev/elpaca/builds/*/\")) (add-to-list 'load-path dir))" \
  --eval "(push default-directory load-path)" \
  --eval "(setq byte-compile-error-on-warn t)" \
  -f batch-byte-compile \
  agent.el agent-capture.el agent-slack.el agent-snippet.el \
  agent-claude-cli.el agent-claude.el agent-codex.el agent-chief.el
echo "exit: $?"
rm -f *.elc
```

Expected: `exit: 0` with no warnings. Fix every warning (missing `declare-function`, unused lexical vars, docstring widths) — do not suppress with `with-suppressed-warnings` unless the warning is a false positive, and say so in a comment.
- [ ] **Checkdoc pass:**

```bash
emacs --batch --eval "(require 'checkdoc)" \
  --eval '(dolist (f (list "agent.el" "agent-capture.el" "agent-slack.el" "agent-snippet.el" "agent-claude-cli.el" "agent-claude.el" "agent-codex.el" "agent-chief.el")) (checkdoc-file f))' 2>&1
```

Expected: no output. Fix all notes.
- [ ] Run all seven ERT files + `batch-test.sh` for agent, agent-claude, agent-codex, agent-chief. Commit: `agent: drop agent--backend-get shim and dead code`

---

### Task 8.7: Documentation, final verification, live smoke checklist

**Files:** `README.org`, `README.md`, `agent.texi` (generated), `CLAUDE.md`/`AGENTS.md` latest-session note per repo convention

- [ ] `agent.texi` is generated from `README.org` by the `.dir-locals.el` after-save hook (`org-texinfo-export-to-texinfo`); there is no separate texi source. Update `README.org`:
  - **Overview / modules table** (new or updated section): `agent.el` core (registry, sessions, teardown, menu, alerts, theme), `agent-capture.el` (Org prompt capture), `agent-slack.el` (Slack-to-project routing), `agent-snippet.el` (eat/yasnippet TAB), `agent-claude.el` + `agent-claude-cli.el` (backend + quarantined CLI conventions), `agent-codex.el`, `agent-chief.el`, `agent-account.el` (if present from Phase 5).
  - **Backend contract**: document the `agent-backend` struct slots (the locked list from the architecture contract) and `agent-register-backend`.
  - **Session lifecycle**: `agent-session` struct, `agent-session-event` state machine, `agent--session-teardown` ownership, the leak-warning policy.
  - **Account model**: accounts alists, persisted selection files, env vars (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`), shared-symlink sync.
  - **Minor modes**: `agent-claude-mode` / `agent-codex-mode` must be enabled explicitly; loading the files installs nothing. Include the use-package snippet from Task 7.5.
  - New user options: `agent-epoch-project-registry-file` / `agent-epoch-projects-root` (nil defaults), removed/renamed internals do not need doc entries.
- [ ] Regenerate `agent.texi`: save README.org inside Emacs (dir-locals hook fires), or run:

```bash
emacs --batch README.org --eval "(require 'ox-texinfo)" -f org-texinfo-export-to-texinfo
```

Confirm `git diff --stat agent.texi` shows the regeneration.
- [ ] `README.md` is the GitHub-facing summary derived from README.org (generate-readme convention). Update its prose to name the new module split (capture/slack/snippet/claude-cli) and the requirement to enable the two minor modes; keep it concise.
- [ ] Update the `CLAUDE.md`/`AGENTS.md` "Latest session" note and `logs/<date>.md` per repo convention.
- [ ] Commit: `agent: document the refactored architecture`
- [ ] **Full verification suite** (all must pass; report any failure instead of claiming done):

```bash
cd "/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent"
for t in agent agent-capture agent-slack agent-snippet agent-claude-cli; do
  "/Users/pablostafforini/My Drive/dotfiles/claude/bin/elisp-ert" agent "test/${t}-test.el" || exit 1
done
"/Users/pablostafforini/My Drive/dotfiles/claude/bin/elisp-ert" agent-claude test/agent-claude-test.el
"/Users/pablostafforini/My Drive/dotfiles/claude/bin/elisp-ert" agent-codex test/agent-codex-test.el
"/Users/pablostafforini/My Drive/dotfiles/claude/bin/elisp-ert" agent-chief test/agent-chief-test.el
"/Users/pablostafforini/My Drive/dotfiles/claude/bin/batch-test.sh" agent
emacsclient -e "(elpaca-rebuild 'agent)"
```

plus the byte-compile gate from Task 8.6 rerun once more after the doc commit.
- [ ] **Live smoke checklist** — perform in the running Emacs (each item: action, then what to observe). Restart Emacs (or `M-x elpaca-rebuild agent` + re-enable both modes) first so the new code is live.
  1. **Start Claude session**: `H-e e`, choose Claude Code. Observe: session buffer opens; modeline shows model/effort within ~10 s (status polling via UUID-keyed file); `ls ${TMPDIR}claude-code-status/` gains one new `.json`.
  2. **Start Codex session**: `H-e e`, choose Codex. Observe: buffer opens, modeline shows model from `config.toml` (TOML helper path); with two accounts configured, modeline values stay correct when switching between buffers of different accounts (per-file cache, no thrash).
  3. **Switch account**: `H-e -c` (Claude) and `H-e -x` (Codex). Observe: prompt lists accounts; selection persists (`cat ~/.claude-current-account`, `cat ~/.codex-current-account`).
  4. **Restart session**: in the Claude buffer, `H-e r`, confirm any captured-prompt prompt. Observe: buffer is replaced by a resumed session; the OLD status file disappears from the status directory and a NEW one appears (UUID fix — this is the user-visible regression test); no `*Warnings*` leak entries.
  5. **Run a skill**: `H-e s`, pick any skill. Observe: command inserted and submitted in the right backend buffer.
  6. **Handoff**: in a session that has run `/handoff`, `H-e h`. Observe: old buffer killed without the before-exit skill chain (inhibited), new session starts with the handoff prompt.
  7. **Before-exit chain**: in a >60 s session in a configured directory, `H-e x`. Observe: `session-learning-capture` then `update-log --auto` submit in order, then the buffer closes; `M-: (hash-table-count agent--session-keys)` drops by one.
  8. **Chief heartbeat**: `M-x agent-chief-start-session`, give a plan, then `M-x agent-chief-session-heartbeat`. Observe: the live chief buffer does NOT receive the heartbeat text (it runs via `codex exec` out of band); within the exec runtime either nothing happens (`No nudge.`) or an alert titled "Chief of staff" fires; `M-: agent-chief--last-session-response` shows the parsed cons; a second immediate heartbeat while one is in flight prints the "skipped" message.
  9. **Mode teardown**: `M-x agent-claude-mode` and `M-x agent-codex-mode` to disable both. Observe: existing sessions keep running, but `claude-code-notification-function` returns to its pre-enable value (`M-: claude-code-notification-function`), and `M-: (timerp agent-claude--monet-gc-timer)` is nil. Re-enable both afterwards.
- [ ] Close with a status report: list every commit made (agent repo and dotfiles), every verification command run with its result, and explicitly name anything from the smoke checklist that could not be performed and why.
