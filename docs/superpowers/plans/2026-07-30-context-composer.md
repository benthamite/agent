# Context Composer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A unified, cross-backend context composer (`agent-context.el`): gather
region/buffer/file/directory/git/diagnostics/compilation/image/URL/captured-prompt
context, preview it truthfully in a dedicated draft buffer, and dispatch it
once to an idle Claude Code or Codex session, per
`docs/superpowers/specs/2026-07-30-context-composer-design.md`.

**Architecture:** A new `agent-context.el` module holds the item model,
sources, safety layer, renderer, composer buffer, and dispatch pipeline.
Core gains two optional backend slots (`:attach-file-reference`,
`:attach-media`) with a `(TOKEN . UNDO)` + dry-run contract; each adapter
registers them.  codex.el (sibling repo) gains a programmatic mention API
with detach handles.

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
- Every dispatch failure path leaves the draft buffer intact and retryable
  and runs collected undo closures.
- Busy targets are refused; unknown state requires explicit confirmation.
  No queue/steer/interrupt integration exists in this worktree; do not add
  one.
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

### Task 1: Core backend attachment slots

**Files:**
- Modify: `agent.el` (the `agent-backend` defstruct, ~line 123)
- Test: `test/agent-test.el`

**Interfaces:**
- Produces: `agent-backend` slots `attach-file-reference` and
  `attach-media` with accessors `agent-backend-attach-file-reference`,
  `agent-backend-attach-media`.  Contract (used by Tasks 9 and 11): each
  slot holds a function `(PATH BUFFER &optional DRY-RUN)` returning
  `(TOKEN . UNDO)`, where TOKEN is the exact string placed in the outgoing
  message, and UNDO is nil or a zero-arg closure removing any out-of-band
  attachment.  With DRY-RUN non-nil the function must be side-effect-free
  and return `(TOKEN . nil)` with the same TOKEN.

- [ ] **Step 1: Write the failing test**

Add to `test/agent-test.el`, new section `;;;; Backend attachment slots`:

```elisp
(ert-deftest agent-test-register-backend-accepts-attachment-slots ()
  "The registry accepts and exposes the two attachment slots."
  (let ((agent-backends nil)
        (ref (lambda (path _buffer &optional _dry-run)
               (cons (format "@%s " path) nil)))
        (media (lambda (path _buffer &optional _dry-run)
                 (cons (format "(image %s)" path) nil))))
    (agent-register-backend
     'stub
     :buffer-p #'ignore
     :find-all-buffers (lambda () nil)
     :start-session #'ignore
     :attach-file-reference ref
     :attach-media media)
    (let ((struct (agent-backend 'stub)))
      (should (eq (agent-backend-attach-file-reference struct) ref))
      (should (eq (agent-backend-attach-media struct) media))
      (should (equal (funcall (agent-backend-attach-file-reference struct)
                              "/tmp/x.el" nil t)
                     '("@/tmp/x.el " . nil))))))
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make test`
Expected: FAIL with "unknown slot keyword `:attach-file-reference'".

- [ ] **Step 3: Implement**

In `agent.el`, extend the struct's send-slot line:

```elisp
  send-string send-return submit
  attach-file-reference attach-media
```

and document the contract in the `agent-register-backend` docstring by
appending:

```
Backends that can reference or attach files provide the optional
`:attach-file-reference' and `:attach-media' keys: functions called
with (PATH BUFFER &optional DRY-RUN) that return a cons (TOKEN . UNDO).
TOKEN is the exact text a composed message embeds for PATH; UNDO is nil
or a closure that removes any out-of-band attachment the call created.
When DRY-RUN is non-nil the function must be free of side effects and
return the same TOKEN with a nil UNDO.
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make test` — all tests pass.

- [ ] **Step 5: Commit**

```bash
git add agent.el test/agent-test.el
git commit -m "agent: add backend attachment slots"
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
               (:constructor agent-context-item-create) (:copier nil))
  "One piece of context in a composition."
  id kind label provenance transport content size note)

(cl-defstruct (agent-context-draft
               (:constructor agent-context-draft-create) (:copier nil))
  "A composition draft: target session plus ordered items."
  target items origin-buffer origin-directory)

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
  "Return an inline snapshot item for BUFFER's region BEG..END."
  (with-current-buffer buffer
    (let ((text (buffer-substring-no-properties beg end))
          (lines (list (line-number-at-pos beg) (line-number-at-pos end))))
      (agent-context-item-create
       :id (agent-context--next-id) :kind 'region
       :label (format "%s:%d-%d" (buffer-name) (car lines) (cadr lines))
       :provenance (list :buffer-name (buffer-name)
                         :path (buffer-file-name)
                         :lines lines
                         :language (agent-context--language-for major-mode)
                         :captured-at (float-time))
       :transport 'inline :content text
       :size (agent-context--exact-size text)))))

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
     :label (abbreviate-file-name path)
     :provenance (list :path path
                       :language (agent-context--language-for path)
                       :captured-at (float-time))
     :transport 'inline :content content
     :size (agent-context--exact-size content))))

(defun agent-context--mention-file-item (path)
  "Return a deferred mention item for PATH."
  (agent-context-item-create
   :id (agent-context--next-id) :kind 'file
   :label (abbreviate-file-name path)
   :provenance (list :path path)
   :transport 'mention :content nil
   :size (agent-context--file-size path)))

(defun agent-context--media-item (path &optional temp)
  "Return a media item for image PATH.
TEMP non-nil marks PATH as a composer-owned temp file."
  (agent-context--assert-safe-path path)
  (agent-context-item-create
   :id (agent-context--next-id) :kind 'image
   :label (abbreviate-file-name path)
   :provenance (append (list :path path) (when temp (list :temp-file t)))
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
          (make-symbolic-link outside (expand-file-name "escape.txt" root))
          (let* ((agent-context-max-files 2)
                 (result (agent-context--directory-items root))
                 (items (car result))
                 (report (cdr result)))
            (should (= (length items) 2))
            (should (cl-every (lambda (i)
                                (eq (agent-context-item-transport i) 'mention))
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
  "Return non-nil when PATH matches a secret-path regexp."
  (let ((expanded (expand-file-name path)))
    (cl-some (lambda (re) (string-match-p re expanded))
             agent-context-secret-path-regexps)))

(defun agent-context--assert-safe-path (path)
  "Signal a `user-error' when PATH must not be sent.  Return t.
The message names the path only; file contents are never read here."
  (when (agent-context--secret-path-p path)
    (user-error "agent-context: refusing to send secret-looking path %s"
                (abbreviate-file-name path)))
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
  "Expand DIR into mention file items.
Return (ITEMS . REPORT) where REPORT is a human-readable summary of
skipped entries: secret paths, binaries, oversize files, symlinks that
escape DIR, and entries over `agent-context-max-files'."
  (let* ((root (file-truename (file-name-as-directory dir)))
         (secret 0) (binary 0) (oversize 0) (symlink 0) (over 0)
         items)
    (dolist (path (agent-context--candidate-files root))
      (let ((path (expand-file-name path)))
        (cond
         ((not (string-prefix-p root (file-truename path)))
          (cl-incf symlink))
         ((agent-context--secret-path-p path) (cl-incf secret))
         ((not (file-readable-p path)) (cl-incf binary))
         ((agent-context--binary-file-p path) (cl-incf binary))
         ((> (or (file-attribute-size (file-attributes path)) 0)
             agent-context-max-file-bytes)
          (cl-incf oversize))
         ((>= (length items) agent-context-max-files) (cl-incf over))
         (t (push (agent-context--mention-file-item path) items)))))
    (cons (nreverse items)
          (agent-context--expansion-report
           (length items) secret binary oversize symlink over))))

(defun agent-context--expansion-report (added secret binary oversize
                                              symlink over)
  "Return the expansion summary string for the given counts."
  (string-join
   (delq nil
         (list (format "added %d" added)
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
        (("rev-parse" "--show-toplevel") . "/tmp/repo\n"))
    (let ((item (agent-context--diff-item "/tmp/repo/")))
      (should (eq (agent-context-item-kind item) 'diff))
      (should (eq (agent-context-item-transport item) 'inline))
      (should (string-match-p "\\+new" (agent-context-item-content item)))
      (should (equal (plist-get (agent-context-item-provenance item) :repo)
                     "/tmp/repo")))))

(ert-deftest agent-context-test-empty-diff-notes-emptiness ()
  "An empty diff is added with an explicit note, not dropped."
  (agent-context-test--with-git
      '((("diff" "--cached") . "")
        (("rev-parse" "--show-toplevel") . "/tmp/repo\n"))
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
STAGED non-nil takes the index diff instead of the working tree."
  (let* ((content (apply #'agent-context--git-output dir
                         (if staged '("diff" "--cached") '("diff"))))
         (label (if staged "staged diff" "working-tree diff")))
    (agent-context-item-create
     :id (agent-context--next-id) :kind 'diff :label label
     :provenance (list :repo (agent-context--git-toplevel dir)
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

(defun agent-context--diagnostics-item (buffer)
  "Return an inline item for BUFFER's flymake diagnostics."
  (with-current-buffer buffer
    (unless (bound-and-true-p flymake-mode)
      (user-error "agent-context: no flymake diagnostics in %s"
                  (buffer-name)))
    (require 'flymake)
    (let* ((lines (mapcar #'agent-context--diagnostic-line
                          (flymake-diagnostics)))
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
A nil STATUS simulates a network failure (nil return)."
  (declare (indent 3))
  `(cl-letf (((symbol-function 'url-retrieve-synchronously)
              (lambda (&rest _)
                (when ,status
                  (let ((buf (generate-new-buffer " *ctx-url*")))
                    (with-current-buffer buf
                      (insert "HTTP/1.1 " (number-to-string ,status) " X\r\n"
                              "Content-Type: text/plain\r\n\r\n" ,body)
                      (goto-char (point-min))
                      (setq-local url-http-response-status ,status)
                      (setq-local url-http-end-of-headers
                                  (progn (search-forward "\r\n\r\n")
                                         (match-beginning 0)))
                      (setq-local url-http-target-url
                                  (url-generic-parse-url ,final)))
                    buf)))))
     ,@test-body))

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
                    :html (string-match-p "\\`\\s-*<" body)))))
      (kill-buffer buffer))))

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
      ('diff (format "Source: git %s in %s, snapshot taken %s"
                     (if (plist-get prov :staged) "diff --cached" "diff")
                     (plist-get prov :repo) stamp))
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
   (should (string-match-p "stub-proj"
                           (buffer-substring-no-properties
                            (point-min) (point-max))))))

(ert-deftest agent-context-test-instruction-survives-refresh ()
  "Typed instruction text survives an item-list refresh."
  (agent-context-test--with-composer
   (goto-char agent-context--instr-start)
   (insert "please explain")
   (agent-context--add-item (agent-context-test--mk-inline "x" "y"))
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
   (text-property-search-forward 'agent-context-item)
   (should (agent-context-item-p
            (get-text-property (point) 'agent-context-item)))))

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
  "Move point to the Nth item line in the composer buffer."
  (goto-char (point-min))
  (dotimes (_ n)
    (text-property-search-forward 'agent-context-item))
  (beginning-of-line))
```

(This helper is production code — implement it in `agent-context.el`, not
in the test file; the reorder commands use the same property search.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test` — FAIL, `agent-context-compose` undefined.

- [ ] **Step 3: Implement the composer buffer**

```elisp
(defconst agent-context-buffer-name "*Agent context*"
  "Name of the single composition draft buffer.")

(defvar-local agent-context--instr-start nil
  "Marker at the start of the editable instruction field.")
(defvar-local agent-context--instr-end nil
  "Marker at the end of the editable instruction field.")

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
  "Keymap active on read-only composer lines.")

(define-derived-mode agent-context-mode nil "AgentCtx"
  "Major mode for the agent context composition draft."
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
  "Return the propertized composer line for ITEM at position N."
  (propertize
   (format "%2d. %-12s %-40s %s%s\n"
           n (agent-context-item-kind item)
           (truncate-string-to-width (agent-context-item-label item) 40
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
    (setq agent-context--instr-start (point-marker))
    (set-marker-insertion-type agent-context--instr-start nil)
    (insert instr)
    (setq agent-context--instr-end (point-marker))
    (set-marker-insertion-type agent-context--instr-end t)
    (insert (agent-context--protected
             (concat "\n\nItems (dispatch order):\n"
                     (if items
                         (let ((n 0))
                           (mapconcat (lambda (item)
                                        (agent-context--item-line
                                         (cl-incf n) item))
                                      items ""))
                       "  (none — press a to add)\n")
                     "\n" (agent-context--totals-line items) "\n\n"
                     "a add · p preview · P message preview · d delete · "
                     "t toggle · r refresh · M-↑/↓ move\n"
                     "C-c C-c send · C-c C-k cancel · q bury\n")))
    (goto-char agent-context--instr-end)))

(defun agent-context--protected (string)
  "Return STRING propertized read-only with the item-line keymap.
`rear-nonsticky' keeps text typed at the instruction-field start from
inheriting the read-only property; `front-sticky' is deliberately
absent so typing at the field end stays editable too."
  (propertize string
              'read-only t 'rear-nonsticky t
              'keymap agent-context--item-line-map))

(defun agent-context--instruction ()
  "Return the instruction text currently in the composer."
  (with-current-buffer agent-context-buffer-name
    (string-trim (buffer-substring-no-properties
                  agent-context--instr-start agent-context--instr-end))))
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

(defun agent-context-toggle-transport ()
  "Toggle the file item at point between mention and inline."
  (interactive)
  (let* ((item (agent-context--item-at-point))
         (path (plist-get (agent-context-item-provenance item) :path)))
    (unless (and (eq (agent-context-item-kind item) 'file) path)
      (user-error "Only file items toggle between mention and inline"))
    (let* ((target-transport
            (if (eq (agent-context-item-transport item) 'mention)
                'inline 'mention))
           (replacement (agent-context--file-item path target-transport))
           (items (agent-context-draft-items agent-context--current)))
      (setcar (nthcdr (agent-context--item-index item) items) replacement))
    (agent-context--refresh)))

(defun agent-context-refresh-item ()
  "Re-resolve the snapshot item at point from its provenance."
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
            ('region
             ;; Line positions may have shifted; refusing beats guessing.
             (user-error
              "Region items cannot be refreshed; delete and re-add"))
            ('buffer
             (let ((buf (get-buffer (plist-get prov :buffer-name))))
               (unless (buffer-live-p buf)
                 (user-error "Source buffer %s is gone"
                             (plist-get prov :buffer-name)))
               (agent-context--buffer-item buf)))
            ('url (when (yes-or-no-p "Re-fetch URL? ")
                    (agent-context--url-item (plist-get prov :url))))
            (_ (user-error "This item kind cannot be refreshed")))))
    (when replacement
      (setcar (nthcdr (agent-context--item-index item)
                      (agent-context-draft-items agent-context--current))
              replacement)
      (agent-context--refresh))))

(defun agent-context-retarget ()
  "Choose a different target session for the draft."
  (interactive)
  (setf (agent-context-draft-target agent-context--current)
        (agent--read-session-buffer))
  (agent-context--refresh))

(defun agent-context-preview-item ()
  "Show the exact content of the item at point.
Deferred items show the file's content as of now, clearly titled."
  (interactive)
  (let* ((item (agent-context--item-at-point))
         (deferred (not (eq (agent-context-item-transport item) 'inline)))
         (path (plist-get (agent-context-item-provenance item) :path))
         (buf (get-buffer-create "*Agent context preview*")))
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
  "Show the fully rendered outgoing message (dry run, no side effects)."
  (interactive)
  (let* ((draft agent-context--current)
         (msg (agent-context--render
               (agent-context--instruction)
               (agent-context-draft-items draft)
               (lambda (item)
                 (car (agent-context--token item nil t)))))
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
      (agent-context--delete-item-temp item))
    (setq agent-context--current nil)))
```

`agent-context--token` is defined in Task 9; for this task add a
forward stub so `P` works once dispatch lands:

```elisp
(defun agent-context--token (item _backend-struct dry-run)
  "Placeholder until dispatch lands; returns a plain path token."
  (ignore dry-run)
  (cons (format "@%s " (plist-get (agent-context-item-provenance item)
                                  :path))
        nil))

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
  "Add the active region (of the origin or current buffer) to the draft.
Callable from any buffer: starts a draft when none exists."
  (interactive)
  (let ((source (if agent-context--current
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
  "Add the file at PATH to the draft (native mention transport)."
  (interactive "fContext file: ")
  (agent-context--add-item (agent-context--file-item path))
  (agent-context--refresh))

(defun agent-context-add-directory (dir)
  "Expand DIR into mention items, reporting skips."
  (interactive "DContext directory: ")
  (pcase-let ((`(,items . ,report) (agent-context--directory-items dir)))
    (dolist (item items) (agent-context--add-item item))
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
  "Add the image file at PATH as a native attachment."
  (interactive "fImage file: ")
  (unless (agent-context--image-file-p path)
    (user-error "agent-context: %s is not a recognized image type" path))
  (agent-context--add-item (agent-context--media-item path))
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
  "Write the clipboard image to a private temp file and attach it."
  (interactive)
  (let ((data (or (gui-get-selection 'CLIPBOARD 'image/png)
                  (user-error "No image on the clipboard"))))
    (let* ((path (make-temp-file
                  (expand-file-name "clip-" (agent-context--temp-directory))
                  nil ".png"))
           (coding-system-for-write 'binary))
      (with-temp-file path (insert data))
      (set-file-modes path #o600)
      (agent-context--add-item (agent-context--media-item path t))))
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
- Consumes: `agent-submit`, `agent-session-display-state`,
  `agent--detect-backend`, `agent-backend`,
  `agent-backend-attach-file-reference`, `agent-backend-attach-media`
  (Task 1 contract); `agent-capture--delete-prompt` (Task 6).
- Produces: `agent-context-dispatch` (real implementation);
  `agent-context--token (item backend-struct target dry-run)` →
  `(TOKEN . UNDO)`; `agent-context-recompose` (autoloaded);
  `agent-context--last` populated on success.

Note: Task 8's temporary `agent-context--token` had no TARGET argument;
this task replaces it with the four-argument version below and updates
`agent-context-preview-message` to call
`(agent-context--token item backend-struct target t)` with the draft's
backend struct and target.

- [ ] **Step 1: Write the failing tests**

```elisp
(defmacro agent-context-test--with-dispatch-env (state &rest body)
  "Set up a stub backend and composer whose target reports STATE.
Binds SUBMITTED (list of submitted strings), ATTACHED and UNDONE
(counters) in BODY's scope."
  (declare (indent 1))
  `(let* ((agent-backends nil)
          (submitted nil) (attached 0) (undone 0)
          (target (generate-new-buffer " *ctx-target*")))
     (ignore attached undone)
     (agent-register-backend
      'stub
      :buffer-p (lambda (buf) (eq buf target))
      :find-all-buffers (lambda () (list target))
      :start-session #'ignore
      :label "Stub"
      :submit (lambda (text _buf) (push text submitted))
      :attach-file-reference
      (lambda (path _buf &optional dry-run)
        (if dry-run
            (cons (format "@%s " path) nil)
          (cl-incf attached)
          (cons (format "@%s " path)
                (lambda () (cl-incf undone)))))
      :attach-media
      (lambda (path _buf &optional dry-run)
        (if dry-run
            (cons (format "(img %s)" path) nil)
          (cl-incf attached)
          (cons (format "(img %s)" path)
                (lambda () (cl-incf undone))))))
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
         (kill-buffer target)))))

(ert-deftest agent-context-test-dispatch-refuses-busy-target ()
  "A busy target is refused and the draft survives."
  (agent-context-test--with-dispatch-env 'busy
    (agent-context--add-item (agent-context-test--mk-inline "x" "y"))
    (should-error (agent-context-dispatch) :type 'user-error)
    (should (null submitted))
    (should agent-context--current)
    (should (= 1 (length (agent-context-draft-items
                          agent-context--current))))))

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
    (agent-context--add-item (agent-context--mention-file-item "/tmp/f.el"))
    (agent-context-dispatch)
    (should (= 1 (length submitted)))
    (should (string-match-p "do it" (car submitted)))
    (should (string-match-p "abc" (car submitted)))
    (should (string-match-p "@/tmp/f\\.el" (car submitted)))
    (should (null agent-context--current))
    (should (plist-get agent-context--last :items))))

(ert-deftest agent-context-test-dispatch-failure-preserves-and-undoes ()
  "A failing submit runs undo closures and keeps the draft."
  (agent-context-test--with-dispatch-env 'awaiting-input
    (agent-context--add-item (agent-context--mention-file-item "/tmp/f.el"))
    (cl-letf (((symbol-function 'agent-submit)
               (lambda (&rest _) (error "boom"))))
      (agent-context-dispatch))          ; must not signal
    (should agent-context--current)
    (should (= attached 1))
    (should (= undone 1))))

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

(ert-deftest agent-context-test-dispatch-media-unsupported-honest-error ()
  "A media item without a backend media slot errors without loss."
  (agent-context-test--with-dispatch-env 'awaiting-input
    (setf (agent-backend-attach-media (agent-backend 'stub)) nil)
    (agent-context--add-item (agent-context--media-item "/tmp/x.png"))
    (should-error (agent-context-dispatch) :type 'user-error)
    (should (null submitted))
    (should (= 1 (length (agent-context-draft-items
                          agent-context--current))))))

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
        (cl-letf (((symbol-function 'agent-submit)
                   (lambda (&rest _) (error "boom"))))
          (agent-context-dispatch))
        (should (null deleted))
        (agent-context-dispatch)
        (should (equal deleted (list prompt)))))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test` — FAIL ("Dispatch not implemented yet").

- [ ] **Step 3: Implement**

Replace the Task 8 stubs:

```elisp
(defun agent-context--token (item backend-struct target dry-run)
  "Return (TOKEN . UNDO) for mention/media ITEM against TARGET.
BACKEND-STRUCT supplies the attachment slots.  DRY-RUN must be free of
side effects (used by previews and the size gate)."
  (let* ((path (plist-get (agent-context-item-provenance item) :path))
         (media (eq (agent-context-item-transport item) 'media))
         (fn (if media
                 (and backend-struct
                      (agent-backend-attach-media backend-struct))
               (and backend-struct
                    (agent-backend-attach-file-reference backend-struct)))))
    (unless fn
      (user-error
       "agent-context: the target backend does not support %s attachments"
       (if media "image" "file-reference")))
    (funcall fn path target dry-run)))

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
  "Enforce the busy policy for TARGET."
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

(defun agent-context--recheck-deferred (items)
  "Re-apply safety checks to deferred ITEMS at dispatch time."
  (dolist (item items)
    (unless (eq (agent-context-item-transport item) 'inline)
      (let ((path (plist-get (agent-context-item-provenance item) :path)))
        (unless (and path (file-readable-p path))
          (user-error "agent-context: %s is no longer readable"
                      (or path (agent-context-item-label item))))
        (agent-context--assert-safe-path path)))))

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
Every failure path leaves the draft intact and retryable and undoes
any out-of-band attachment already made."
  (interactive)
  (unless agent-context--current
    (user-error "No context draft"))
  (let* ((draft agent-context--current)
         (items (agent-context-draft-items draft))
         (instruction (agent-context--instruction))
         (target (agent-context--validated-target))
         (backend (agent--detect-backend target))
         (struct (agent-backend backend)))
    (when (and (string-empty-p instruction) (null items))
      (user-error "agent-context: nothing to send"))
    (agent-context--check-target-ready target)
    (agent-context--recheck-deferred items)
    ;; Truthful size gate on a dry-run render (identical tokens).
    (agent-context--size-gate
     (agent-context--render instruction items
                            (lambda (item)
                              (car (agent-context--token
                                    item struct target t)))))
    ;; Effectful attach + single submit, with undo on any failure.
    (let (undos)
      (condition-case err
          (let ((message-text
                 (agent-context--render
                  instruction items
                  (lambda (item)
                    (pcase-let ((`(,token . ,undo)
                                 (agent-context--token
                                  item struct target nil)))
                      (when undo (push undo undos))
                      token)))))
            (agent-submit message-text target)
            (agent-context--finish draft instruction))
        (error
         (mapc #'funcall undos)
         (message "agent-context: dispatch failed (%s); draft preserved"
                  (error-message-string err)))))))

(defun agent-context--finish (draft instruction)
  "Record success for DRAFT with INSTRUCTION and clean up."
  (dolist (item (agent-context-draft-items draft))
    (when-let* (((eq (agent-context-item-kind item) 'capture))
                (plist (plist-get (agent-context-item-provenance item)
                                  :capture-plist)))
      (require 'agent-capture)
      (agent-capture--delete-prompt plist)))
  (setq agent-context--last
        (list :instruction instruction
              :items (agent-context-draft-items draft)))
  (setq agent-context--current nil)
  (agent-context--finish-buffer)
  (message "agent-context: dispatched to %s (%d items)"
           (agent-display-name (agent-context-draft-target draft))
           (length (agent-context-draft-items draft))))

(defun agent-context--finish-buffer ()
  "Kill the composer buffer after a successful dispatch."
  (when (get-buffer agent-context-buffer-name)
    (kill-buffer agent-context-buffer-name)))

;;;###autoload
(defun agent-context-recompose ()
  "Rebuild a draft from the last successfully dispatched composition."
  (interactive)
  (unless agent-context--last
    (user-error "No previous composition"))
  (when agent-context--current
    (user-error "A draft already exists; finish or cancel it first"))
  (agent-context-compose)
  (setf (agent-context-draft-items agent-context--current)
        (plist-get agent-context--last :items))
  (with-current-buffer agent-context-buffer-name
    (agent-context--refresh)
    (save-excursion
      (goto-char agent-context--instr-start)
      (insert (plist-get agent-context--last :instruction)))))
```

Also update `agent-context-preview-message` (Task 8) to pass the real
backend struct and target:

```elisp
(defun agent-context-preview-message ()
  "Show the fully rendered outgoing message (dry run, no side effects)."
  (interactive)
  (let* ((draft agent-context--current)
         (target (agent-context-draft-target draft))
         (struct (when-let* ((backend (and (buffer-live-p target)
                                           (agent--detect-backend target))))
                   (agent-backend backend)))
         (msg (agent-context--render
               (agent-context--instruction)
               (agent-context-draft-items draft)
               (lambda (item)
                 (car (agent-context--token item struct target t)))))
         (buf (get-buffer-create "*Agent context preview*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert msg))
      (special-mode)
      (goto-char (point-min)))
    (pop-to-buffer buf)))
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
  - `codex-app-server-attach-mention (path)` — now takes PATH (interactive
    spec `"fMention file: "`), buffer-local effect on the current buffer,
    returns a handle.
  - `codex-app-server-attach-image (path)` — unchanged signature, now
    returns a handle.
  - `codex-app-server-detach (handle)` — removes the pending entry if not
    yet consumed; returns non-nil when something was removed.

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
(defun codex-app-server-attach-mention (path)
  "Attach a file mention for PATH to the next app-server turn input.
Operates on the current buffer's pending mentions.  Return a handle
accepted by `codex-app-server-detach'."
  (interactive "fMention file: ")
  (let* ((path (expand-file-name path))
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
```

(For the image test to pass, note `memq`/`delq` operate on the *same
string object* stored in the handle, so two equal paths do not collide.)

Update the codex manual (README.org API section) with the three functions,
regenerate its texi per that repo's convention, and run its full checks.

- [ ] **Step 4: Run codex tests and compile**

Run (codex repo): `make test && make compile` — clean.

- [ ] **Step 5: Commit (codex repo)**

```bash
git add codex-app-server.el codex-test.el README.org codex.texi
git commit -m "codex-app-server: add programmatic mention and detach API"
```

---

### Task 11: Backend adapter registrations

**Files:**
- Modify: `agent-claude.el` (backend registration, ~line 215)
- Modify: `agent-codex.el` (backend registration, ~line 138)
- Test: `test/agent-claude-test.el`, `test/agent-codex-test.el`

**Interfaces:**
- Consumes: Task 1 slot contract; Task 10 codex API (guarded by
  `(fboundp 'codex-app-server-detach)` so agent-codex still works against
  an older codex.el).  Note: the Makefile's LOAD_PATH prefers elpaca
  *builds*; after Task 10, rebuild the codex package (or verify the
  build directory picked up the new functions) before expecting the
  `skip-unless` test to run rather than skip.
- Produces: `agent-claude--attach-file-reference`,
  `agent-claude--attach-media`, `agent-codex--attach-file-reference`,
  `agent-codex--attach-media`, registered under `:attach-file-reference`
  and `:attach-media` for both backends.

- [ ] **Step 1: Write the failing tests**

In `test/agent-claude-test.el`:

```elisp
(ert-deftest agent-claude-test-attach-file-reference-token ()
  "Claude file references are @-mention tokens with no undo."
  (should (equal (agent-claude--attach-file-reference "/tmp/a.el" nil)
                 '("@/tmp/a.el " . nil)))
  (should (equal (agent-claude--attach-file-reference "/tmp/a.el" nil t)
                 '("@/tmp/a.el " . nil))))

(ert-deftest agent-claude-test-registers-attachment-slots ()
  "The claude-code backend registers both attachment slots."
  (let ((struct (agent-backend 'claude-code)))
    (should (agent-backend-attach-file-reference struct))
    (should (agent-backend-attach-media struct))))
```

In `test/agent-codex-test.el`:

```elisp
(ert-deftest agent-codex-test-attach-file-reference-terminal-token ()
  "Terminal Codex sessions use the @-mention token with no undo."
  (with-temp-buffer                    ; no app-server here
    (should (equal (agent-codex--attach-file-reference
                    "/tmp/a.el" (current-buffer))
                   '("@/tmp/a.el " . nil)))))

(ert-deftest agent-codex-test-attach-file-reference-app-server ()
  "App-server sessions attach a native mention and return a detach undo."
  (skip-unless (fboundp 'codex-app-server-detach))
  (with-temp-buffer
    (setq-local codex--app-server-pending-mentions nil)
    (setq-local codex--app-server-process
                (start-process "ctx-stub" nil "cat"))
    (unwind-protect
        (progn
          ;; Dry run: token only, no side effect.
          (pcase-let ((`(,token . ,undo)
                       (agent-codex--attach-file-reference
                        "/tmp/a.el" (current-buffer) t)))
            (should (equal token "$a.el"))
            (should (null undo))
            (should (null codex--app-server-pending-mentions)))
          ;; Real run: pending mention plus a working undo.
          (pcase-let ((`(,token . ,undo)
                       (agent-codex--attach-file-reference
                        "/tmp/a.el" (current-buffer))))
            (should (equal token "$a.el"))
            (should (= 1 (length codex--app-server-pending-mentions)))
            (funcall undo)
            (should (null codex--app-server-pending-mentions))))
      (delete-process codex--app-server-process))))
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test` — FAIL, functions undefined.

- [ ] **Step 3: Implement**

`agent-claude.el` — add near the other send helpers and register in the
`agent-register-backend` form (`:attach-file-reference
#'agent-claude--attach-file-reference :attach-media
#'agent-claude--attach-media`):

```elisp
(defun agent-claude--attach-file-reference (path _buffer &optional _dry-run)
  "Return the Claude @-mention token for PATH.
The Claude CLI expands @-mentions in submitted text; there is no
out-of-band attachment, so the undo slot is always nil."
  (cons (format "@%s " (expand-file-name path)) nil))

(defun agent-claude--attach-media (path buffer &optional dry-run)
  "Return the Claude image token for PATH.
Identical to the file-reference channel: the CLI attaches @-mentioned
images, exactly as upstream's own image paste does."
  (agent-claude--attach-file-reference path buffer dry-run))
```

`agent-codex.el` — add and register likewise:

```elisp
(declare-function codex-app-server-attach-mention "codex-app-server" (path))
(declare-function codex-app-server-attach-image "codex-app-server" (path))
(declare-function codex-app-server-detach "codex-app-server" (handle))

(defun agent-codex--app-server-attachments-available-p (buffer)
  "Return non-nil when BUFFER can take native app-server attachments."
  (and (fboundp 'codex-app-server-detach)
       (buffer-live-p buffer)
       (with-current-buffer buffer
         (agent-codex--app-server-live-p))))

(defun agent-codex--attach-file-reference (path buffer &optional dry-run)
  "Return (TOKEN . UNDO) referencing PATH in Codex session BUFFER.
Terminal sessions embed an @-mention the CLI expands; app-server
sessions attach a native mention item and embed its $NAME token."
  (let ((path (expand-file-name path)))
    (if (not (agent-codex--app-server-attachments-available-p buffer))
        (cons (format "@%s " path) nil)
      (let ((token (format "$%s" (file-name-nondirectory path))))
        (if dry-run
            (cons token nil)
          (let ((handle (with-current-buffer buffer
                          (codex-app-server-attach-mention path))))
            (cons token (agent-codex--detach-closure buffer handle))))))))

(defun agent-codex--attach-media (path buffer &optional dry-run)
  "Return (TOKEN . UNDO) attaching image PATH in Codex session BUFFER."
  (let ((path (expand-file-name path)))
    (if (not (agent-codex--app-server-attachments-available-p buffer))
        (cons (format "@%s " path) nil)
      (let ((token (format "(image attached: %s)"
                           (file-name-nondirectory path))))
        (if dry-run
            (cons token nil)
          (let ((handle (with-current-buffer buffer
                          (codex-app-server-attach-image path))))
            (cons token (agent-codex--detach-closure buffer handle))))))))

(defun agent-codex--detach-closure (buffer handle)
  "Return a closure detaching HANDLE from BUFFER if still pending."
  (lambda ()
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (codex-app-server-detach handle)))))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test` — all pass.

- [ ] **Step 5: Commit**

```bash
git add agent-claude.el agent-codex.el test/agent-claude-test.el test/agent-codex-test.el
git commit -m "agent: register attachment slots for both backends"
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
      (agent-context--add-item (agent-context--file-item file)))
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
refused, unknown state confirmed, every failure preserves the draft and
undoes out-of-band attachments, "dispatched" for terminal transports
means inserted-and-submitted at the TUI prompt,
`agent-context-recompose` rebuilds the last sent composition).

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

1. Claude session: compose region + instruction; verify from the
   conversation that the agent received the region exactly once.
2. Claude session: compose a file (mention) and a working-tree diff;
   verify contents and single receipt.
3. Codex app-server session: same three sources; verify the mention
   arrived as a native mention item.
4. Codex terminal session: region + instruction.
5. Images: Claude and Codex (app-server at minimum) — verify the model
   describes the image content, proving it arrived as an image, not a
   path string.  Remove the media registration for any backend that
   fails this and re-run the media tests.
6. Preview (`p` and `P`), delete, reorder, toggle, cancel.
7. Induce a dispatch failure (e.g. kill the target between compose and
   dispatch); verify the draft survives and retry succeeds after
   retargeting.
8. Busy policy: dispatch at a mid-turn session; verify refusal and that
   the running turn is unaffected.

- [ ] **Step 3: Commit any fixes discovered live, one logical change each**
