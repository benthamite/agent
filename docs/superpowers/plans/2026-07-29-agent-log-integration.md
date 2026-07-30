# Agent Live-Identity Contract Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `agent` the authority on live-session native IDs and add a
shared history command, per
`docs/superpowers/specs/2026-07-29-agent-log-integration-design.md`.

**Architecture:** A private core helper records native session IDs on the
existing `agent-session` struct and runs a new public abnormal hook; the
Claude status poll and the Codex event handler feed it; `agent-start-session`
seeds non-fork resumes.  A new `agent-history` command in the shared menu
delegates to Agent Log via soft require.

**Tech Stack:** Emacs Lisp, `cl-defstruct`, transient, ERT.

## Global Constraints

- Loading `agent` must not require `agent-log`.
- No transient in this package may read a historical catalog during
  construction or opening.
- Never modify `codex.el` or `claude-code.el`.
- All 354+ existing tests keep passing; byte compilation stays warning-free.

---

### Task 1: Core identity recording

**Files:**
- Modify: `agent.el` (Session identity section, after `agent-session-buffer-name`, ~line 430)
- Modify: `agent.el` (`agent-start-session`, lines 311-341)
- Test: `test/agent-test.el`

**Interfaces:**
- Produces: `agent--note-session-id BUFFER ID`,
  `agent-session-id-functions` (abnormal hook, arg BUFFER),
  `agent-session-buffers` () → list of live session buffers.
  Later tasks and the agent-log bridge rely on these exact names.

- [ ] **Step 1: Write the failing tests**

Add to `test/agent-test.el` (new section `;;;; Session id recording`):

```elisp
(ert-deftest agent-test-note-session-id/records-and-fires-hook-once ()
  "Recording a new id sets the struct slot and fires the hook once."
  (with-temp-buffer
    (setq-local agent--session (agent-session-create
                                :backend 'claude-code
                                :directory "~/project/"))
    (let* ((fired 0)
           (agent-session-id-functions
            (list (lambda (_buffer) (cl-incf fired)))))
      (agent--note-session-id (current-buffer) "abc-123")
      (agent--note-session-id (current-buffer) "abc-123")
      (should (equal (agent-session-id (agent-session)) "abc-123"))
      (should (= fired 1)))))

(ert-deftest agent-test-note-session-id/updates-on-change ()
  "A changed id (Claude branch switch) is recorded and re-fires the hook."
  (with-temp-buffer
    (setq-local agent--session (agent-session-create
                                :backend 'claude-code
                                :directory "~/project/"))
    (let* ((fired 0)
           (agent-session-id-functions
            (list (lambda (_buffer) (cl-incf fired)))))
      (agent--note-session-id (current-buffer) "abc-123")
      (agent--note-session-id (current-buffer) "def-456")
      (should (equal (agent-session-id (agent-session)) "def-456"))
      (should (= fired 2)))))

(ert-deftest agent-test-note-session-id/ignores-nil-and-empty ()
  "Nil and empty ids are ignored."
  (with-temp-buffer
    (setq-local agent--session (agent-session-create
                                :backend 'claude-code
                                :directory "~/project/"))
    (agent--note-session-id (current-buffer) nil)
    (agent--note-session-id (current-buffer) "")
    (should (null (agent-session-id (agent-session))))))

(ert-deftest agent-test-start-session/seeds-resume-id ()
  "A non-fork resume seeds the session id; a fork leaves it nil."
  (let (started
        (agent-backends nil))
    (cl-letf (((symbol-function 'agent-account-resolve) (lambda (&rest _) nil))
              ((symbol-function 'agent-account-sync) #'ignore))
      (agent-register-backend
       'stub
       :buffer-p #'ignore
       :find-all-buffers (lambda () nil)
       :start-session (lambda (session &rest _)
                        (setq started session)
                        (generate-new-buffer " *stub*")))
      (agent-start-session (agent-session-create :backend 'stub)
                           :resume-id "res-1")
      (should (equal (agent-session-id started) "res-1"))
      (agent-start-session (agent-session-create :backend 'stub)
                           :resume-id "res-2" :fork t)
      (should (null (agent-session-id started))))))

(ert-deftest agent-test-session-buffers/returns-backend-buffers ()
  "`agent-session-buffers' returns each backend's live buffers."
  (let ((buf (generate-new-buffer " *agent-test-session*"))
        (agent-backends nil))
    (unwind-protect
        (progn
          (agent-register-backend
           'stub
           :buffer-p #'ignore
           :find-all-buffers (lambda () (list buf))
           :start-session #'ignore)
          (should (equal (agent-session-buffers) (list buf))))
      (kill-buffer buf))))
```

- [ ] **Step 2: Run the tests and verify they fail**

Run:

```sh
make test 2>&1 | grep -A2 "agent-test-note-session-id\|agent-test-start-session/seeds\|agent-test-session-buffers"
```

Expected: the five new tests FAIL (`agent--note-session-id`,
`agent-session-id-functions`, `agent-session-buffers` undefined; seeding
absent).

- [ ] **Step 3: Implement**

In `agent.el`, after `agent-session-buffer-name` (end of the Session
identity section):

```elisp
(defcustom agent-session-id-functions nil
  "Abnormal hook run when a live session's native id is recorded or changes.
Each function is called with the session buffer, after the `id' slot of
the buffer's `agent-session' struct has been updated.  Read the new
value with (agent-session-id (agent-session BUFFER))."
  :type 'hook
  :group 'agent)

(defun agent--note-session-id (buffer id)
  "Record ID as the native session id of the session in BUFFER.
Do nothing unless BUFFER is live, belongs to a session, and ID is a
non-empty string that differs from the recorded id.  Run
`agent-session-id-functions' with BUFFER after recording, so optional
integrations can observe identity changes without reading private
variables."
  (when (and (buffer-live-p buffer)
             (stringp id)
             (not (string-empty-p id)))
    (when-let* ((session (agent-session buffer)))
      (unless (equal (agent-session-id session) id)
        (setf (agent-session-id session) id)
        (run-hook-with-args 'agent-session-id-functions buffer)))))

(defun agent-session-buffers ()
  "Return all live AI session buffers across registered backends."
  (agent--find-all-buffers))
```

In `agent-start-session`, replace `(ignore initial-prompt resume-id)` with
`(ignore initial-prompt)` and add the seeding after the `start` binding is
validated (before the account sync), plus a docstring sentence:

```elisp
    (when (and resume-id (not (plist-get options :fork)))
      (setf (agent-session-id session) resume-id))
```

Docstring addition: "A non-fork RESUME-ID also seeds the session's `id'
slot, because that identity is already known; a fork acquires a fresh id
that only the backend can report."

- [ ] **Step 4: Run the tests and verify they pass**

Run: `make test`
Expected: all tests pass, including the five new ones.

- [ ] **Step 5: Commit**

```sh
git add agent.el test/agent-test.el
git commit -m "agent: record native session ids on the session struct"
```

### Task 2: Claude and Codex id wiring

**Files:**
- Modify: `agent-claude.el` (`agent-claude--read-status`, lines 719-732)
- Modify: `agent-codex.el` (`agent-codex--handle-notification`, lines 511-537)
- Test: `test/agent-claude-test.el`, `test/agent-codex-test.el`

**Interfaces:**
- Consumes: `agent--note-session-id` from Task 1.
- Produces: live Claude buffers carry their status-file `:session_id`;
  live Codex buffers carry `codex-session-identity`'s `:session-id`.

- [ ] **Step 1: Write the failing tests**

In `test/agent-claude-test.el`:

```elisp
(ert-deftest agent-claude-test-read-status/notes-session-id ()
  "Status polling records the native session id on the session struct."
  (with-temp-buffer
    (setq-local agent--session (agent-session-create
                                :backend 'claude-code
                                :directory "~/project/"))
    (cl-letf (((symbol-function 'agent-claude--parse-status-file)
               (lambda () '(:session_id "sid-1" :prompt_id "p1"))))
      (agent-claude--read-status (cons nil nil) (current-buffer))
      (should (equal (agent-session-id (agent-session)) "sid-1")))))
```

In `test/agent-codex-test.el`:

```elisp
(ert-deftest agent-codex-test-handle-notification/notes-session-id ()
  "Codex events record the native session id on the session struct."
  (let ((buf (generate-new-buffer "*codex-test-session*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (setq-local agent--session (agent-session-create
                                        :backend 'codex
                                        :directory "~/project/")))
          (cl-letf (((symbol-function 'codex-session-identity)
                     (lambda (&optional _buffer)
                       '(:session-id "codex-sid-1")))
                    ((symbol-function 'agent-session-event) #'ignore))
            (agent-codex--handle-notification
             (list :type "SessionStart" :buffer-name (buffer-name buf)))
            (should (equal (agent-session-id (agent-session buf))
                           "codex-sid-1"))))
      (kill-buffer buf))))
```

- [ ] **Step 2: Run the tests and verify they fail**

Run: `make test`
Expected: the two new tests FAIL (id never recorded).

- [ ] **Step 3: Implement**

In `agent-claude--read-status`, after `(agent-claude--detect-branch data)`:

```elisp
        (agent--note-session-id buffer (plist-get data :session_id))
```

In `agent-codex--handle-notification`, inside the `when-let*` for `buf`,
before the `pcase`:

```elisp
        (agent--note-session-id
         buf (plist-get (codex-session-identity buf) :session-id))
```

(`codex-session-identity` is already declared at `agent-codex.el:116`.)

- [ ] **Step 4: Run the tests and verify they pass**

Run: `make test` and `make compile`
Expected: all tests pass; compilation is clean.

- [ ] **Step 5: Commit**

```sh
git add agent-claude.el agent-codex.el test/agent-claude-test.el test/agent-codex-test.el
git commit -m "agent: feed backend session ids into the identity contract"
```

### Task 3: Shared history command

**Files:**
- Modify: `agent.el` (forward declarations ~line 641; `agent-menu`, lines 2632-2664)
- Modify: `agent-claude.el` (remove `agent-claude-agent-log-menu`, lines 2448-2453; its `"l"` suffix, line 2461; the `agent-log-menu' declare-function, line 204)
- Test: `test/agent-test.el`

**Interfaces:**
- Produces: interactive command `agent-history`, bound to "l" in the
  Sessions column of `agent-menu`.

- [ ] **Step 1: Write the failing test**

```elisp
(ert-deftest agent-test-history/errors-without-agent-log ()
  "`agent-history' signals a clear error when agent-log is missing."
  (let ((real-require (symbol-function 'require)))
    (cl-letf (((symbol-function 'require)
               (lambda (feature &optional filename noerror)
                 (if (eq feature 'agent-log)
                     nil
                   (funcall real-require feature filename noerror)))))
      (should-error (agent-history) :type 'user-error))))
```

- [ ] **Step 2: Run the test and verify it fails**

Run: `make test`
Expected: FAIL, `agent-history` not defined.

- [ ] **Step 3: Implement**

In `agent.el` forward declarations:

```elisp
(declare-function agent-log-menu "agent-log" ())
```

Near `agent-menu` (before the transient definition):

```elisp
;;;###autoload
(defun agent-history ()
  "Browse and act on historical sessions with the optional Agent Log package."
  (interactive)
  (unless (require 'agent-log nil t)
    (user-error "Package `agent-log' is required for history browsing"))
  (call-interactively #'agent-log-menu))
```

In `agent-menu`'s Sessions group, after `("r" "restart" agent-restart)`:

```elisp
    ("l" "history" agent-history)
```

In `agent-claude.el`: delete `agent-claude-agent-log-menu`, delete
`("l" "logs" agent-claude-agent-log-menu)` from
`agent-claude--menu-suffixes`, delete the now-unused
`(declare-function agent-log-menu "agent-log" ())` at line 204.

- [ ] **Step 4: Run the tests and verify they pass**

Run: `make test` and `make compile`
Expected: all pass; no byte-compile warning about `agent-log-menu`.

- [ ] **Step 5: Commit**

```sh
git add agent.el agent-claude.el test/agent-test.el
git commit -m "agent: move history browsing into the shared menu"
```

### Task 4: Documentation

**Files:**
- Modify: `README.org` (session model section: describe id maintenance,
  `agent-session-id-functions`, `agent-session-buffers`; menu section:
  document "l history" and the Agent Log delegation; note the optional
  integration and that agent-log is not required)
- Regenerate: `agent.texi` via ox-texinfo

- [ ] **Step 1: Update README.org**

Document, in the existing prose style: the identity contract (id populated
from the Claude status poll / Codex events, seeded on non-fork resume), the
public observation surface (`agent-session-id`, `agent-session-buffers`,
`agent-session-display-state`, `agent-session-id-functions`), and the
`agent-history` menu command with its soft dependency on `agent-log`.

- [ ] **Step 2: Regenerate the texinfo manual**

Run:

```sh
emacs -Q --batch README.org --eval '(progn (require (quote ox-texinfo)) (org-texinfo-export-to-texinfo))'
```

Expected: `agent.texi` regenerated with the new sections.

- [ ] **Step 3: Full verification**

Run: `make test` and `make compile`
Expected: everything passes.

- [ ] **Step 4: Commit**

```sh
git add README.org agent.texi
git commit -m "agent: document the live-identity contract"
```
