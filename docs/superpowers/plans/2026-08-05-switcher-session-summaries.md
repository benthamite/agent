# Session Summaries in the Session Switcher — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show each live session's stored Agent Log one-line summary, dimmed and column-aligned, next to its name in the `agent-start-or-switch` transient.

**Architecture:** `agent` gains a generic annotation hook it renders but never fills; `agent-log` gains a public one-liner lookup backed by an idle-refreshed in-memory cache; the existing bridge `agent-log-agent.el` connects the two. Neither package starts requiring the other.

**Tech Stack:** Emacs Lisp, `transient` (layout measured from `transient--layout`), `ert`.

**Spec:** `docs/superpowers/specs/2026-08-05-switcher-session-summaries-design.md`

## Global Constraints

- Two repositories are touched. `agent`: `/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent`. `agent-log`: `/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/agent-log`. Every path below is relative to the repository named in the task.
- `agent` must acquire no load-time or build-time dependency on `agent-log`: nothing in `agent` may `require` it at load, and no new code may name it. The pre-existing `agent-history` command, which soft-requires `agent-log` on demand and signals a clear error when it is absent (agent.el:2867), is the established exception and is not to be "fixed" to satisfy this rule. `agent-log` may name `agent`, but only inside `agent-log-agent.el`.
- Emacs floors: `agent` requires Emacs 30.0, `agent-log` requires Emacs 29.1.
- No silent fallbacks. If a helper cannot compute its answer, let the error surface; do not substitute a plausible default and carry on.
- Every new function and variable gets a docstring whose first line is a complete sentence in the imperative or declarative style used by its neighbours.
- Verification per repository: `make test` and `make compile` must both pass before any commit. `agent` baseline before this plan: 362 tests, 0 unexpected.
- Commit message prefixes follow each repo's history: `agent: ...` in `agent`, `agent-log: ...` in `agent-log`, `docs: ...` for documentation-only commits.

## Before you start

- **Both repositories work on the branch `switcher-session-summaries`, already created, with `git config branch.switcher-session-summaries.deferDocUpdates true` already set.** The commit guard `require-doc-update.sh` refuses any commit that stages a non-test `.el` file without `README.org`, and it ignores the deferral setting on `main` and `master`. The branch is what makes Task 5's single documentation commit possible. Do not switch either repository back to `main` until Task 7.
- After each commit that changes Elisp, a post-commit hook rebuilds and reloads the package in the running Emacs, and the session's guard requires the changed code path to be exercised there before work continues. Each implementation task therefore ends with an `emacsclient -e` call that exercises what it just added; the dispatching controller names the call for its task.
- `cd` to each repository and run `git status --short`. Both trees must be clean. The unrelated `agent-log` work in progress that existed when this plan was written was committed first, as `06acec6`.
- Run `make test` in both repositories and record the baselines: `agent` 362 tests, `agent-log` 346 tests.

## File Structure

**`agent` repository:**
- `agent.el` — modified. Gains the annotation hook `agent-session-annotation-function`, the face `agent-session-annotation`, the user option `agent-session-annotation-max-width`, four private helpers in the "Session switcher" section, and a two-pass switcher build.
- `test/agent-test.el` — modified. New tests in the session-switcher area, after `agent-test-session-groups-use-account-key`.
- `README.org`, `agent.texi` — modified. Documentation.

**`agent-log` repository:**
- `agent-log.el` — modified. Gains the public `agent-log-session-oneline` and `agent-log-refresh-session-onelines`, plus two cache variables and one file-state helper, all in the "Index file" section.
- `agent-log-agent.el` — modified. Installs the annotation function and the idle refresh timer.
- `agent-log-test.el` — modified. New tests after the index-management tests.
- `Makefile` — modified. The `test-load-order` target also asserts the annotation function is installed.
- `README.org`, `agent-log.texi` — modified. Documentation.

Nothing is created. Both packages already have the sections these additions belong in.

---

### Task 1: Measure the width available for annotations

Pure functions only: nothing renders yet. They answer "how many columns may an annotation occupy?", which the next task needs.

Transient lays the switcher's two columns side by side. Each column is as wide as its widest cell, and the next column starts two columns later (`transient--column-stops`, transient.el:5211). A suffix cell is formatted as `" %k %d"` (the `format` slot of `transient-suffix`, transient.el:1067), so its width is `2 + key + description`. The Sessions column therefore starts at `2 + max("Actions", " w jump to waiting", " e new session")` = `2 + 18` = 20, and each session row spends three more columns on `" k "` before its label.

**Files:**
- Modify: `agent.el` — add a user option beside the other options, and three functions in the "Session switcher" section, immediately before `agent--session-suffix-spec` (currently agent.el:970)
- Test: `test/agent-test.el`

**Interfaces:**
- Produces: `agent-session-annotation-max-width` (user option: integer or nil); `agent--switcher-columns` → list of column vectors; `agent--switcher-column-width` (COLUMN) → integer; `agent--switcher-sessions-column-offset` → integer; `agent--session-annotation-width` (PAD) → integer.

- [ ] **Step 1: Write the failing tests**

Add to `test/agent-test.el`, immediately after `agent-test-session-groups-use-account-key` (currently ends at test/agent-test.el:348):

```elisp
;;;; Switcher annotation width

(ert-deftest agent-test-switcher-column-width-counts-key-and-description ()
  "Measure a transient column as its widest formatted cell.
Transient formats a suffix as \" %k %d\", so a cell is two columns
wider than its key and description together."
  (let ((column (vector 'transient-column
                        '(:description "Actions")
                        '((transient-suffix :key "w"
                                            :description "jump to waiting"
                                            :command ignore)
                          (transient-suffix :key "e"
                                            :description "new session"
                                            :command ignore)))))
    (should (= (agent--switcher-column-width column)
               (+ 2 1 (length "jump to waiting"))))))

(ert-deftest agent-test-switcher-column-width-uses-heading-when-widest ()
  "Fall back to the column heading when it is wider than every cell."
  (let ((column (vector 'transient-column
                        '(:description "A very wide heading")
                        '((transient-suffix :key "w"
                                            :description "x"
                                            :command ignore)))))
    (should (= (agent--switcher-column-width column)
               (length "A very wide heading")))))

(ert-deftest agent-test-switcher-sessions-column-offset-clears-actions ()
  "Start the Sessions column two columns past the Actions column.
The expected value is derived from the Actions column's own contents,
so renaming an action updates this test's expectation with it, while a
change in transient's layout representation breaks it loudly."
  (should (= (agent--switcher-sessions-column-offset)
             (+ 2 (max (length "Actions")
                       (+ 2 1 (length "jump to waiting"))
                       (+ 2 1 (length "new session")))))))

(ert-deftest agent-test-annotation-width-honors-max-width ()
  "Cap annotations at `agent-session-annotation-max-width' when set."
  (let ((agent-session-annotation-max-width 12))
    (should (= (agent--session-annotation-width 30) 12))))

(ert-deftest agent-test-annotation-width-fits-the-frame ()
  "Fit annotations to the frame when no maximum width is set.
The switcher window spans the frame, so the room left over is the
frame width minus the Sessions column offset, the three columns
transient spends on \" k \", the padded label, and one trailing
column."
  (let ((agent-session-annotation-max-width nil))
    (cl-letf (((symbol-function 'frame-width) (lambda (&optional _) 100)))
      (should (= (agent--session-annotation-width 20)
                 (- 100 (agent--switcher-sessions-column-offset) 3 20 2))))))

(ert-deftest agent-test-annotation-width-has-a-floor ()
  "Never return a width below 20 columns, however narrow the frame."
  (let ((agent-session-annotation-max-width nil))
    (cl-letf (((symbol-function 'frame-width) (lambda (&optional _) 30)))
      (should (= (agent--session-annotation-width 20) 20)))))
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `make test 2>&1 | tail -20`
Expected: failures reporting `void-function agent--switcher-column-width`, `void-function agent--switcher-sessions-column-offset`, `void-function agent--session-annotation-width`, and `void-variable agent-session-annotation-max-width`.

- [ ] **Step 3: Add the user option**

In `agent.el`, in the "Customization" section, immediately after the `agent-sigwinch-delay` option (currently agent.el:611):

```elisp
(defcustom agent-session-annotation-max-width nil
  "Maximum display width of session annotations in the session switcher.
An integer caps annotations at that many columns.  Nil fits them to the
switcher window, which is as wide as the frame.  Annotations longer
than the available width are truncated with an ellipsis."
  :type '(choice (const :tag "Fit the frame" nil)
                 (integer :tag "Columns"))
  :group 'agent)
```

- [ ] **Step 4: Add the width helpers**

In `agent.el`, in the "Session switcher" section, immediately before `agent--session-suffix-spec`:

```elisp
(defconst agent--switcher-suffix-padding 2
  "Columns a transient suffix spends beyond its key and description.
Transient formats a suffix as \" %k %d\": one leading space and one
separator.")

(defconst agent--switcher-column-padding 2
  "Columns transient leaves between adjacent menu columns.
Matches the padding `transient--column-stops' adds between columns.")

(defconst agent--switcher-session-key-width 1
  "Display width of a session key in the switcher.
Every key in `agent--session-key-pool' is one character wide.")

(defun agent--switcher-columns ()
  "Return the column vectors of the session switcher's layout."
  (let ((columns (car (aref (get 'agent--session-switcher 'transient--layout)
                            2))))
    (aref columns 2)))

(defun agent--switcher-column-width (column)
  "Return the display width of COLUMN in the switcher's layout.
A transient column is as wide as its widest cell: its heading, or one
of its suffixes formatted as \" KEY DESCRIPTION\"."
  (let ((heading (plist-get (aref column 1) :description)))
    (apply #'max
           (if (stringp heading) (string-width heading) 0)
           (mapcar (lambda (suffix)
                     (+ agent--switcher-suffix-padding
                        (string-width (or (plist-get (cdr suffix) :key) ""))
                        (string-width (or (plist-get (cdr suffix) :description)
                                          ""))))
                   (aref column 2)))))

(defun agent--switcher-sessions-column-offset ()
  "Return the column at which the switcher's Sessions column starts.
Transient places each column two columns past the widest cell of the
one before it, so the room left for annotations depends on the columns
to the left of Sessions.  Measuring the prefix's own layout keeps that
number correct when an action is added or renamed."
  (let ((offset 0))
    (cl-dolist (column (agent--switcher-columns) offset)
      (when (equal (plist-get (aref column 1) :description) "Sessions")
        (cl-return offset))
      (setq offset (+ offset
                      agent--switcher-column-padding
                      (agent--switcher-column-width column))))))

(defun agent--session-annotation-width (pad)
  "Return the display width available to a session annotation.
PAD is the width session labels are padded to.  Honor
`agent-session-annotation-max-width' when it is an integer; otherwise
fit the switcher window, which spans the frame.  Never return less
than 20 columns, so a narrow frame yields a short annotation rather
than none."
  (or agent-session-annotation-max-width
      (max 20 (- (frame-width)
                 (agent--switcher-sessions-column-offset)
                 agent--switcher-suffix-padding
                 agent--switcher-session-key-width
                 pad
                 2))))
```

- [ ] **Step 5: Run the tests and watch them pass**

Run: `make test 2>&1 | tail -5`
Expected: `Ran 368 tests, 368 results as expected, 0 unexpected`.

- [ ] **Step 6: Byte-compile clean**

Run: `make compile 2>&1 | tail -20`
Expected: no output other than the compilation banner; no warnings.

- [ ] **Step 7: Commit**

```bash
git add agent.el test/agent-test.el
git commit -m "agent: measure the width available for switcher annotations"
```

---

### Task 2: Render annotations in the switcher

**Files:**
- Modify: `agent.el` — the annotation hook next to `agent-session-id-functions` (agent.el:452), the face next to `agent-unknown` (agent.el:631), and the switcher build (agent.el:940-982)
- Test: `test/agent-test.el`

**Interfaces:**
- Consumes: `agent--session-annotation-width` (PAD) from Task 1.
- Produces: `agent-session-annotation-function` (variable, nil by default, called with a buffer, returns a string or nil); `agent--session-label-base` (BUFFER) → string; `agent--session-annotation` (BUFFER) → string or nil; `agent--session-label` (BUFFER PAD) → string; `agent--session-label-pad` → integer; `agent--session-suffix-spec` (BUF KEY &optional PAD); `agent--group-sessions-by-account` (&optional PAD).

- [ ] **Step 1: Write the failing tests**

Add to `test/agent-test.el`, after the tests from Task 1:

```elisp
;;;; Switcher annotations

(defun agent-test--switcher-label (buffer)
  "Return the switcher label BUFFER would render with, unpadded."
  (nth 1 (agent--session-suffix-spec buffer "a")))

(defmacro agent-test--with-session-buffer (name &rest body)
  "Run BODY with a registered single-session backend buffer named NAME.
The buffer is bound to `buf' and holds session key \"a\"."
  (declare (indent 1) (debug t))
  `(let ((agent-backends nil)
         (agent--session-keys (make-hash-table :test 'eq)))
     (with-temp-buffer
       (rename-buffer ,name t)
       (let ((buf (current-buffer)))
         (apply #'agent-register-backend
                'one
                (agent-test--backend
                 :buffer-p (lambda (candidate) (eq candidate buf))
                 :find-all-buffers (lambda () (list buf))))
         (puthash buf "a" agent--session-keys)
         ,@body))))

(ert-deftest agent-test-session-label-is-plain-without-annotation-function ()
  "Render session labels exactly as before when nothing annotates them."
  (let ((agent-session-annotation-function nil))
    (agent-test--with-session-buffer "*one:~/repo/project/:default*"
      (should (equal (agent-test--switcher-label buf) "project")))))

(ert-deftest agent-test-session-label-appends-annotation ()
  "Append the annotation after the session name."
  (let ((agent-session-annotation-function
         (lambda (_buffer) "Fix the parser")))
    (agent-test--with-session-buffer "*one:~/repo/project/:default*"
      (let ((label (agent-test--switcher-label buf)))
        (should (string-prefix-p "project" label))
        (should (string-suffix-p "Fix the parser" label))))))

(ert-deftest agent-test-session-annotation-is-dimmed ()
  "Carry `agent-session-annotation' on the annotation, not the name."
  (let ((agent-session-annotation-function
         (lambda (_buffer) "Fix the parser")))
    (agent-test--with-session-buffer "*one:~/repo/project/:default*"
      (let* ((label (agent-test--switcher-label buf))
             (start (string-search "Fix" label)))
        (should (eq (get-text-property start 'face label)
                    'agent-session-annotation))
        (should-not (get-text-property 0 'face label))))))

(ert-deftest agent-test-session-annotation-collapses-whitespace ()
  "Collapse a multi-line annotation into a single line."
  (let ((agent-session-annotation-function
         (lambda (_buffer) "Fix the\n  parser\n")))
    (agent-test--with-session-buffer "*one:~/repo/project/:default*"
      (should (string-suffix-p "Fix the parser"
                               (agent-test--switcher-label buf))))))

(ert-deftest agent-test-blank-annotation-counts-as-none ()
  "Treat a blank annotation as no annotation, leaving the label plain."
  (let ((agent-session-annotation-function (lambda (_buffer) "   ")))
    (agent-test--with-session-buffer "*one:~/repo/project/:default*"
      (should (equal (agent-test--switcher-label buf) "project")))))

(ert-deftest agent-test-session-annotation-is-truncated ()
  "Truncate an annotation that exceeds the available width."
  (let ((agent-session-annotation-function
         (lambda (_buffer) "A very long annotation that will not fit"))
        (agent-session-annotation-max-width 10))
    (agent-test--with-session-buffer "*one:~/repo/project/:default*"
      (let* ((label (agent-test--switcher-label buf))
             (annotation (substring label (1+ (length "project")))))
        (should (<= (string-width annotation) 10))
        (should (string-suffix-p (truncate-string-ellipsis) annotation))))))

(ert-deftest agent-test-session-annotations-align-across-accounts ()
  "Start every annotation at one column, across all account groups."
  (let ((agent-backends nil)
        (agent--session-keys (make-hash-table :test 'eq))
        (agent-session-annotation-function (lambda (_buffer) "summary")))
    (with-temp-buffer
      (rename-buffer "*one:~/repo/a/:default*" t)
      (let ((short (current-buffer)))
        (with-temp-buffer
          (rename-buffer "*one:~/repo/much-longer-name/:default*" t)
          (let ((long (current-buffer)))
            (apply #'agent-register-backend
                   'one
                   (agent-test--backend
                    :buffer-p (lambda (candidate)
                                (memq candidate (list short long)))
                    :find-all-buffers (lambda () (list short long))))
            (with-current-buffer short
              (setq-local agent--session
                          (agent-session-create :backend 'one
                                                :account "work")))
            (with-current-buffer long
              (setq-local agent--session
                          (agent-session-create :backend 'one
                                                :account "home")))
            (puthash short "a" agent--session-keys)
            (puthash long "s" agent--session-keys)
            (let* ((groups (agent--group-sessions-by-account
                            (agent--session-label-pad)))
                   (labels (mapcar (lambda (spec) (nth 1 spec))
                                   (apply #'append (mapcar #'cdr groups)))))
              (should (= (length labels) 2))
              (should (apply #'= (mapcar (lambda (label)
                                           (string-search "summary" label))
                                         labels))))))))))

(ert-deftest agent-test-session-label-pad-ignores-unannotated-sessions ()
  "Pad only for sessions that have an annotation to line up.
A long name with nothing after it needs no padding, and letting it
widen the column would push every annotation to the right for nothing."
  (let ((agent-session-annotation-function (lambda (_buffer) nil)))
    (agent-test--with-session-buffer "*one:~/repo/much-longer-name/:default*"
      (should (= (agent--session-label-pad) 0)))))
```

- [ ] **Step 2: Run the tests and watch them fail**

Run: `make test 2>&1 | tail -20`
Expected: failures reporting `void-variable agent-session-annotation-function` and `void-function agent--session-label-pad`.

- [ ] **Step 3: Add the annotation hook and the face**

In `agent.el`, immediately after `agent-session-id-functions` (currently agent.el:452-458):

```elisp
(defvar agent-session-annotation-function nil
  "Function returning a short annotation for a live session buffer.
Called with the session buffer; returns a single-line string to show
after the session name in the session switcher, or nil for no
annotation.  Whitespace is collapsed and long annotations are
truncated, so the function may return whatever text it has.

Nil, the default, shows session names alone.  Optional integrations
install a function here; `agent' renders whatever it returns and never
depends on where the text comes from.")
```

In `agent.el`, in the "Faces" section, immediately after `agent-unknown` (currently agent.el:631-636):

```elisp
(defface agent-session-annotation
  '((t :inherit shadow))
  "Face for session annotations in the session switcher.
Applied to the text `agent-session-annotation-function' returns, so
that a session's name stays the prominent part of its entry.
Transient adds a suffix's own face behind the faces a string already
carries, so annotations stay dim even next to a name colored by
`agent-waiting'."
  :group 'agent)
```

- [ ] **Step 4: Replace the label construction**

In `agent.el`, replace `agent--session-suffix-spec` (currently agent.el:970-982) with the following, and add the three helpers before it:

```elisp
(defun agent--session-label-base (buffer)
  "Return BUFFER's switcher label without any annotation."
  (let* ((backend (agent--detect-backend buffer))
         (icon (when backend (agent-backend-icon-string backend)))
         (name (agent-display-name buffer)))
    (if (and icon (not (string-empty-p icon)))
        (format "%s %s" icon name)
      name)))

(defun agent--session-annotation (buffer)
  "Return the annotation for session BUFFER, or nil for none.
The text comes from `agent-session-annotation-function'.  Whitespace
is collapsed to single spaces so a multi-line answer cannot break the
menu's layout, and an answer that is blank or not a string counts as
no annotation."
  (when agent-session-annotation-function
    (let ((text (funcall agent-session-annotation-function buffer)))
      (when (stringp text)
        (let ((line (string-trim
                     (replace-regexp-in-string "[ \t\n\r]+" " " text))))
          (unless (string-empty-p line) line))))))

(defun agent--session-label (buffer pad)
  "Return BUFFER's switcher label, annotated and padded to PAD columns.
Sessions without an annotation keep the bare label they had before
annotations existed, with no trailing padding."
  (let ((base (agent--session-label-base buffer))
        (annotation (agent--session-annotation buffer)))
    (if (not annotation)
        base
      (concat (string-pad base pad)
              " "
              (propertize (truncate-string-to-width
                           annotation
                           (agent--session-annotation-width pad)
                           nil nil t)
                          'face 'agent-session-annotation)))))

(defun agent--session-label-pad ()
  "Return the width to pad session labels to in the switcher.
The widest label among sessions that have an annotation, so their
annotations start at one column across every account group.  Zero when
no session has one, which leaves every label unpadded."
  (let ((widths (list 0)))
    (maphash (lambda (buf _key)
               (when (and (buffer-live-p buf)
                          (agent--session-annotation buf))
                 (push (string-width (agent--session-label-base buf))
                       widths)))
             agent--session-keys)
    (apply #'max widths)))

(defun agent--session-suffix-spec (buf key &optional pad)
  "Build a transient suffix spec for BUF bound to KEY.
PAD is the width to pad the session label to, so that annotations line
up across the switcher; nil pads nothing."
  (let* ((backend (agent--detect-backend buf))
         (label (agent--session-label buf (or pad 0)))
         (state (agent-session-display-state buf backend))
         (cmd (make-symbol (format "ai-switch-%s" key)))
         (spec (list key label cmd)))
    (when-let* ((face (agent--session-state-face state)))
      (setq spec (append spec (list :face face))))
    (fset cmd (lambda () (interactive) (switch-to-buffer buf)))
    spec))
```

- [ ] **Step 5: Thread the pad through the switcher build**

In `agent.el`, replace `agent--session-switcher-children` and `agent--group-sessions-by-account` (currently agent.el:940-957) with:

```elisp
(defun agent--session-switcher-children (_)
  "Build transient suffixes for the session switcher, grouped by account.
Labels are built in two passes, because aligning annotations needs the
widest label, which is only known once every label exists."
  (let* ((pad (agent--session-label-pad))
         (groups (agent--group-sessions-by-account pad)))
    (transient-parse-suffixes
     'agent--session-switcher
     (apply #'vector (agent--interleave-group-headers groups)))))

(defun agent--group-sessions-by-account (&optional pad)
  "Return an alist of (ACCOUNT . SPECS) sorted by account name.
Each SPECS is a list of suffix specs sorted by home-row key.  PAD is
the width to pad session labels to; nil pads nothing."
  (let ((groups (make-hash-table :test 'equal)))
    (maphash
     (lambda (buf key)
       (when (buffer-live-p buf)
         (push (agent--session-suffix-spec buf key pad)
               (gethash (agent--session-group-key buf) groups))))
     agent--session-keys)
    (agent--hash-to-sorted-alist groups)))
```

- [ ] **Step 6: Run the tests and watch them pass**

Run: `make test 2>&1 | tail -5`
Expected: `Ran 376 tests, 376 results as expected, 0 unexpected`.

- [ ] **Step 7: Byte-compile clean**

Run: `make compile 2>&1 | tail -20`
Expected: no warnings.

- [ ] **Step 8: Commit**

```bash
git add agent.el test/agent-test.el
git commit -m "agent: annotate switcher sessions through a rendering hook"
```

---

### Task 3: One-liner lookup and cache in Agent Log

**Files:**
- Modify: `agent-log.el` — the "Index file" section, after `agent-log--index-update` (currently agent-log.el:1159-1162)
- Test: `agent-log-test.el` — after the index-management tests (currently ends near agent-log-test.el:614)

**Interfaces:**
- Produces: `agent-log-session-oneline` (SESSION-ID) → string or nil; `agent-log-refresh-session-onelines` (&optional FORCE) → non-nil when rebuilt; `agent-log--session-oneline-cache`; `agent-log--session-oneline-cache-state`; `agent-log--index-file-state` → cons or nil.

- [ ] **Step 1: Write the failing tests**

Add to `agent-log-test.el`, after `agent-log-test-write-and-read-index/roundtrip`:

```elisp
;;;;; Session one-liners

(defun agent-log-test--write-oneline-index (entries)
  "Write ENTRIES, an alist of (SESSION-ID . ONELINE), as the index."
  (let ((index (make-hash-table :test #'equal)))
    (dolist (entry entries)
      (puthash (car entry) (list :summary-oneline (cdr entry)) index))
    (agent-log--write-index index)))

(ert-deftest agent-log-test-session-oneline/returns-stored-summary ()
  "Return the stored one-line summary for a session id."
  (agent-log-test--with-temp-dir
    (let ((agent-log-rendered-directory agent-log-test--dir)
          (agent-log--session-oneline-cache nil)
          (agent-log--session-oneline-cache-state nil))
      (agent-log-test--write-oneline-index '(("s1" . "Fix the parser")))
      (should (agent-log-refresh-session-onelines))
      (should (equal (agent-log-session-oneline "s1") "Fix the parser")))))

(ert-deftest agent-log-test-session-oneline/unknown-session-is-nil ()
  "Return nil for a session the index has never seen."
  (agent-log-test--with-temp-dir
    (let ((agent-log-rendered-directory agent-log-test--dir)
          (agent-log--session-oneline-cache nil)
          (agent-log--session-oneline-cache-state nil))
      (agent-log-test--write-oneline-index '(("s1" . "Fix the parser")))
      (agent-log-refresh-session-onelines)
      (should-not (agent-log-session-oneline "s2")))))

(ert-deftest agent-log-test-session-oneline/sentinel-is-nil ()
  "Report a session with nothing to summarize as having no summary.
The sentinel means \"already processed, empty\"; showing it in a menu
would announce the emptiness instead of staying quiet about it."
  (agent-log-test--with-temp-dir
    (let ((agent-log-rendered-directory agent-log-test--dir)
          (agent-log--session-oneline-cache nil)
          (agent-log--session-oneline-cache-state nil))
      (agent-log-test--write-oneline-index
       (list (cons "s1" agent-log--no-conversation-sentinel)))
      (agent-log-refresh-session-onelines)
      (should-not (agent-log-session-oneline "s1")))))

(ert-deftest agent-log-test-session-oneline/empty-cache-is-nil ()
  "Return nil before the cache has ever been filled."
  (let ((agent-log--session-oneline-cache nil))
    (should-not (agent-log-session-oneline "s1"))))

(ert-deftest agent-log-test-refresh-onelines/skips-unchanged-index ()
  "Do not reread the index when its size and mtime are unchanged."
  (agent-log-test--with-temp-dir
    (let ((agent-log-rendered-directory agent-log-test--dir)
          (agent-log--session-oneline-cache nil)
          (agent-log--session-oneline-cache-state nil)
          (reads 0))
      (agent-log-test--write-oneline-index '(("s1" . "Fix the parser")))
      (let ((real (symbol-function 'agent-log--read-index)))
        (cl-letf (((symbol-function 'agent-log--read-index)
                   (lambda () (cl-incf reads) (funcall real))))
          (should (agent-log-refresh-session-onelines))
          (should-not (agent-log-refresh-session-onelines))
          (should (= reads 1))
          (should (agent-log-refresh-session-onelines t))
          (should (= reads 2)))))))

(ert-deftest agent-log-test-refresh-onelines/rebuilds-on-change ()
  "Reread the index once its file state changes."
  (agent-log-test--with-temp-dir
    (let ((agent-log-rendered-directory agent-log-test--dir)
          (agent-log--session-oneline-cache nil)
          (agent-log--session-oneline-cache-state nil))
      (agent-log-test--write-oneline-index '(("s1" . "Fix the parser")))
      (agent-log-refresh-session-onelines)
      (agent-log-test--write-oneline-index
       '(("s1" . "Fix the parser and the printer")))
      (should (agent-log-refresh-session-onelines))
      (should (equal (agent-log-session-oneline "s1")
                     "Fix the parser and the printer")))))

(ert-deftest agent-log-test-refresh-onelines/missing-index-keeps-cache ()
  "Leave the cache alone when the index file does not exist."
  (agent-log-test--with-temp-dir
    (let* ((agent-log-rendered-directory agent-log-test--dir)
           (cache (make-hash-table :test #'equal))
           (agent-log--session-oneline-cache cache)
           (agent-log--session-oneline-cache-state '(1 . (0 0))))
      (puthash "s1" "Fix the parser" cache)
      (should-not (agent-log-refresh-session-onelines))
      (should (equal (agent-log-session-oneline "s1") "Fix the parser")))))
```

The rebuild test writes the index twice in quick succession. `agent-log--write-index` renames a fresh temp file into place, so the size differs even when the timestamp does not; the second entry is deliberately longer than the first for that reason.

- [ ] **Step 2: Run the tests and watch them fail**

Run: `make test 2>&1 | tail -20`
Expected: failures reporting `void-function agent-log-refresh-session-onelines` and `void-variable agent-log--session-oneline-cache`.

- [ ] **Step 3: Implement the cache and the lookup**

In `agent-log.el`, immediately after `agent-log--index-update`:

```elisp
;;;;; Session one-liners

(defvar agent-log--session-oneline-cache nil
  "Hash table mapping a session id to its stored one-line summary.
Nil until `agent-log-refresh-session-onelines' first fills it.  Holds
only the one-line summaries, not whole index entries, so consumers that
want a label do not carry the entire index in memory.")

(defvar agent-log--session-oneline-cache-state nil
  "File state the one-line summary cache was built from.
A cons (SIZE . MTIME) of the index file, or nil when the cache has
never been filled.")

(defun agent-log--index-file-state ()
  "Return (SIZE . MTIME) for the index file, or nil when it is absent."
  (when-let* ((attributes (file-attributes (agent-log--index-file))))
    (cons (file-attribute-size attributes)
          (file-attribute-modification-time attributes))))

(defun agent-log-session-oneline (session-id)
  "Return the stored one-line summary for SESSION-ID, or nil.
Read the in-memory cache filled by
`agent-log-refresh-session-onelines' and never touch the disk, so
callers on interactive paths pay nothing for the answer.  A session
with no conversation to summarize returns nil rather than the stored
sentinel, and so does a session the cache has not seen."
  (when (and agent-log--session-oneline-cache (stringp session-id))
    (let ((oneline (gethash session-id agent-log--session-oneline-cache)))
      (and (stringp oneline)
           (not (equal oneline agent-log--no-conversation-sentinel))
           oneline))))

(defun agent-log-refresh-session-onelines (&optional force)
  "Rebuild the one-line summary cache from the rendered index.
Do nothing when the index file's size and modification time are
unchanged since the last rebuild, unless FORCE is non-nil, and nothing
when the index file does not exist.  Return non-nil when the cache was
rebuilt."
  (when-let* ((state (agent-log--index-file-state)))
    (when (or force
              (not (equal state agent-log--session-oneline-cache-state)))
      (let ((cache (make-hash-table :test #'equal)))
        (maphash (lambda (session-id entry)
                   (when-let* ((oneline (plist-get entry :summary-oneline)))
                     (puthash session-id oneline cache)))
                 (agent-log--read-index))
        (setq agent-log--session-oneline-cache cache
              agent-log--session-oneline-cache-state state)
        t))))
```

- [ ] **Step 4: Run the tests and watch them pass**

Run: `make test 2>&1 | tail -5`
Expected: all tests pass, seven more than the baseline recorded before you started.

- [ ] **Step 5: Byte-compile clean**

Run: `make compile 2>&1 | tail -20`
Expected: no warnings. The target sets `byte-compile-error-on-warn`, so a warning fails the build.

- [ ] **Step 6: Commit**

```bash
git add agent-log.el agent-log-test.el
git commit -m "agent-log: expose stored session one-liners through a cache"
```

---

### Task 4: Wire the bridge

**Files:**
- Modify: `agent-log-agent.el` — the commentary's API list, and a new section after "Live-session identity"
- Modify: `Makefile` — the `test-load-order` target

**Interfaces:**
- Consumes: `agent-session-annotation-function` from Task 2; `agent-log-session-oneline` and `agent-log-refresh-session-onelines` from Task 3.
- Produces: `agent-log-agent--session-annotation` (BUFFER) → string or nil; `agent-log-agent--oneline-refresh-timer`.

- [ ] **Step 1: Add the annotation provider and the refresh timer**

In `agent-log-agent.el`, after the `setq` that installs the live-session info functions (the form ending `#'agent-log-agent--session-info-table`):

```elisp
;;;; Switcher annotations

(defcustom agent-log-oneline-refresh-idle-delay 5
  "Seconds of idleness before refreshing the session one-line cache.
The session switcher reads that cache, so it never waits on the index
file.  The cost of a shorter delay is one `file-attributes' call per
firing; the cost of a longer one is that a summary written moments ago
shows up later."
  :type 'number
  :group 'agent-log)

(defvar agent-log-agent--oneline-refresh-timer nil
  "Idle timer refreshing the session one-line summary cache.")

(defun agent-log-agent--session-annotation (buffer)
  "Return the stored one-line summary of BUFFER's session, or nil.
Live sessions are summarized by the background sweep, which does not
know they are live, so the text can lag the conversation by hours.  A
session too new to have been summarized has no annotation at all."
  (when-let* ((session (agent-session buffer))
              (session-id (agent-session-id session)))
    (agent-log-session-oneline session-id)))

(setq agent-session-annotation-function
      #'agent-log-agent--session-annotation)

(unless (timerp agent-log-agent--oneline-refresh-timer)
  (setq agent-log-agent--oneline-refresh-timer
        (run-with-idle-timer agent-log-oneline-refresh-idle-delay t
                             #'agent-log-refresh-session-onelines)))
```

The timer also primes the cache: the bridge reads nothing at load time, and the first idle moment fills it, long before a live session exists to switch to.

- [ ] **Step 2: Extend the commentary's API list**

In `agent-log-agent.el`, in the Commentary, the sentence listing the public `agent` API this file uses currently ends `and `agent-start-session'.`  Add the new name so the list stays accurate:

```elisp
;; used: `agent-session', `agent-session-id', `agent-session-backend',
;; `agent-session-buffers', `agent-session-display-state',
;; `agent-backend', `agent-session-create', `agent-start-session', and
;; the `agent-session-annotation-function' rendering hook.
```

- [ ] **Step 3: Assert the wiring in the load-order check**

In `Makefile`, in the `test-load-order` target, extend the first `--eval` form's final check so it also asserts the annotation function is installed. Replace that line with:

```make
	$(EMACS) -Q --batch $(LOAD_PATH) \
	  --eval "(progn (require 'agent) (require 'agent-log) (unless (and (featurep 'agent) (featurep 'agent-log) (featurep 'agent-log-agent)) (error \"Agent Log bridge features are not loaded\")) (unless (eq agent-session-annotation-function #'agent-log-agent--session-annotation) (error \"Agent Log bridge did not install the switcher annotation function\")))"
```

- [ ] **Step 4: Run the load-order check**

Run: `make test-load-order`
Expected: no output and exit status 0. A failure prints the error message from the check that failed.

- [ ] **Step 5: Run the full suite and byte-compile**

Run: `make test 2>&1 | tail -5 && make compile 2>&1 | tail -20`
Expected: all tests pass; no compilation warnings. `make compile` includes `agent-log-agent.el`, so a wrong function name or an unknown variable fails here.

- [ ] **Step 6: Commit**

```bash
git add agent-log-agent.el Makefile
git commit -m "agent-log: annotate live switcher sessions with their summaries"
```

---

### Task 5: Documentation

Both manuals are Org files exported to Texinfo, so `README.org` is the source and the `.texi` file is regenerated, never hand-edited.

**Files:**
- Modify: `agent` repository — `README.org`, `agent.texi`
- Modify: `agent-log` repository — `README.org`, `agent-log.texi`

- [ ] **Step 1: Document the annotation hook in `agent`**

In the `agent` repository, in `README.org`, in the paragraph describing `agent-start-or-switch` (currently README.org:272), after the sentence ending "display backend icons next to their labels.", add:

```org
Sessions can also carry a one-line annotation after their name, shown in the ~agent-session-annotation~ face and aligned into a column across every account group.  The text comes from ~agent-session-annotation-function~, which is called with a session buffer and returns a string or ~nil~; ~agent~ renders whatever it returns and knows nothing about where the text comes from.  Sessions without an annotation render exactly as they did before.  Annotations are truncated with an ellipsis to ~agent-session-annotation-max-width~ when that option is an integer, and to the room left in the frame when it is ~nil~, the default.  Agent Log installs an annotation function that supplies each session's stored summary ([[https://github.com/benthamite/agent-log][agent-log]]); with no such integration loaded, the hook stays ~nil~ and the switcher looks unchanged.
```

- [ ] **Step 2: Regenerate `agent.texi`**

Run, from the `agent` repository root:

```bash
emacs -Q --batch -l ox-texinfo README.org -f org-texinfo-export-to-texinfo
```

Expected: `agent.texi` is rewritten. Check with `git diff --stat agent.texi` that only the expected paragraph changed; if unrelated hunks appear, the exporter version differs from the one that produced the committed file — stop and report rather than committing wholesale churn.

- [ ] **Step 3: Document the lookup and the cache in `agent-log`**

In the `agent-log` repository, in `README.org`, in the integration section that describes the live-state extension points (currently README.org:458), add a new bullet after it:

```org
- The bridge annotates the =agent= session switcher with each live session's stored one-line summary, through ~agent-session-annotation-function~.  Summaries come from ~agent-log-session-oneline~, which reads an in-memory cache rather than the rendered index, so opening the switcher never waits on a 6 MB file.  ~agent-log-refresh-session-onelines~ rebuilds that cache, and the bridge calls it from an idle timer whose delay is ~agent-log-oneline-refresh-idle-delay~ (default 5 seconds); the rebuild is skipped unless the index file's size or modification time changed.  Sessions whose stored summary is the empty-session sentinel, and sessions the archive has not summarized yet, get no annotation.  Because the summary sweep skips sessions it believes are live, a live session's annotation can lag its conversation.
```

- [ ] **Step 4: Regenerate `agent-log.texi`**

Run, from the `agent-log` repository root:

```bash
emacs -Q --batch -l ox-texinfo README.org -f org-texinfo-export-to-texinfo
```

Expected: `agent-log.texi` is rewritten with the matching bullet.

- [ ] **Step 5: Commit, one repository at a time**

```bash
# in the agent repository
git add README.org agent.texi
git commit -m "docs: document switcher session annotations"
```

```bash
# in the agent-log repository
git add README.org agent-log.texi
git commit -m "docs: document the switcher annotation bridge"
```

---

### Task 6: Live verification

Tests cannot settle whether the column looks right in a real frame. This task runs the feature in the user's running Emacs and reports what was seen. Do not claim the feature works before this task passes.

**Files:** none.

- [ ] **Step 1: Load the changed files into the running Emacs**

Load by absolute path. The running Emacs has the Elpaca *builds* on its `load-path`, so `(load "agent")` would load the stale byte-compiled copy instead of the edited source:

```bash
emacsclient -e '(let ((src "/Users/pablostafforini/.config/emacs-profiles/8.3.0-dev/elpaca/sources/")) (load (concat src "agent/agent.el") nil t) (load (concat src "agent-log/agent-log.el") nil t) (load (concat src "agent-log/agent-log-agent.el") nil t) t)'
```

Expected: `t`. An error here means a form failed to evaluate; fix it before continuing. Loading source over a byte-compiled build is fine for verification; `M-x elpaca-rebuild agent` and `M-x elpaca-rebuild agent-log` make the change permanent for the next session.

- [ ] **Step 2: Fill the cache without waiting for the idle timer**

```bash
emacsclient -e '(progn (agent-log-refresh-session-onelines t) (hash-table-count agent-log--session-oneline-cache))'
```

Expected: an integer in the thousands. Zero means the index path is wrong.

- [ ] **Step 3: Check the annotation each live session would get**

```bash
emacsclient -e '(mapcar (lambda (b) (cons (buffer-name b) (agent--session-annotation b))) (agent-session-buffers))'
```

Expected: a session buffer name paired with a summary string for most sessions, and `nil` for any session started too recently to have been summarized. `nil` for every session means `agent-session-id` is not populated — check `(agent-session-id (agent-session BUFFER))` before looking anywhere else.

- [ ] **Step 4: Inspect the rendered labels**

```bash
emacsclient -e '(mapcar (lambda (spec) (nth 1 spec)) (apply (function append) (mapcar (function cdr) (agent--group-sessions-by-account (agent--session-label-pad)))))'
```

Expected: labels whose annotations all begin at the same column, none longer than the frame width. Compare the longest label's width against `(frame-width)`:

```bash
emacsclient -e '(cons (frame-width) (apply (function max) (mapcar (lambda (spec) (+ 3 (string-width (nth 1 spec)))) (apply (function append) (mapcar (function cdr) (agent--group-sessions-by-account (agent--session-label-pad)))))))'
```

Expected: the second number, plus `(agent--switcher-sessions-column-offset)`, is at most the first. If it exceeds the frame width the menu will wrap, and the width computation in Task 1 needs its reserve adjusted.

- [ ] **Step 5: Open the switcher and look at it**

Ask the user to run `M-x agent-start-or-switch` and confirm three things: summaries appear next to the sessions that have them, the summary column lines up, and a waiting session still shows its state color on the name while its summary stays dim. This is the only step that needs the user; everything before it is self-serve.

- [ ] **Step 6: Report**

State plainly what was verified and what was not: which sessions showed summaries, whether any label wrapped, and whether the state faces survived. If a session showed no summary, say whether it was because the archive has none for it or because its id was unknown.

---

### Task 7: Land the branches

**Files:** none.

- [ ] **Step 1: Merge each repository's branch into `main`**

In each repository, with a clean tree and the whole plan committed:

```bash
git checkout main
git merge --no-ff switcher-session-summaries -m "agent: show session summaries in the session switcher"
```

Use `agent-log:` as the prefix in the `agent-log` repository. The merge itself is exempt from the documentation guard, and by this point Task 5 has committed the manuals on the branch anyway.

- [ ] **Step 2: Remove the deferral setting**

```bash
git config --unset branch.switcher-session-summaries.deferDocUpdates
git branch -d switcher-session-summaries
```

Run both in each repository. Leaving the setting behind would silently exempt a future branch of the same name from the documentation guard.

- [ ] **Step 3: Confirm both repositories are on `main` and clean**

```bash
git branch --show-current && git status --short
```

Expected: `main`, and no output from `git status`.

---

## Notes on decisions this plan makes

**The face is `agent-session-annotation`, not `agent-session-summary`.** The spec named the face after summaries, but `agent` deliberately has no concept of a summary — it renders annotations from a hook. Naming the face for the mechanism keeps the package honest about what it knows. The spec has been amended to match.

**Errors from the annotation function are not caught.** A third-party function that signals will break the switcher loudly rather than silently rendering unannotated sessions, per the project's rule against unlabelled fallbacks.

**`agent--session-annotation` is called twice per buffer per switcher build** — once to compute the pad, once to build the label. Both calls hit an in-memory hash table, and threading a precomputed table through three functions to save them would cost more clarity than it buys.
