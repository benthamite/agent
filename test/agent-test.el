;;; agent-test.el --- Tests for agent -*- lexical-binding: t -*-

;; Tests for pure and near-pure helper functions in agent.el.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'agent)
(require 'agent-capture)

(defun agent-test--backend (&rest keys)
  "Return a minimal valid backend plist extended with KEYS."
  (append
   keys
   (list :buffer-p (lambda (_buffer) nil)
         :find-all-buffers (lambda () nil)
         :start-session #'ignore
         :label "Test")))

(defun agent-test--terminal-page-up ()
  "Simulate a terminal mode PageUp binding."
  (interactive))

(defun agent-test--terminal-page-down ()
  "Simulate a terminal mode PageDown binding."
  (interactive))

(defvar agent-test--terminal-navigation-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map [prior] #'agent-test--terminal-page-up)
    (define-key map [next] #'agent-test--terminal-page-down)
    map)
  "Keymap simulating terminal navigation bindings.")

(define-minor-mode agent-test--terminal-navigation-mode
  "Minor mode simulating terminal navigation key capture."
  :keymap agent-test--terminal-navigation-mode-map)

;;;; Theme sync

(ert-deftest agent-test-sync-theme-dispatches-to-backends ()
  "Dispatch theme sync to all registered backend handlers."
  (let ((agent-backends nil)
        (seen nil))
    (apply #'agent-register-backend
     'one
     (agent-test--backend
      :sync-theme (lambda (theme) (push (cons 'one theme) seen))))
    (apply #'agent-register-backend
     'two
     (agent-test--backend
      :sync-theme (lambda (theme) (push (cons 'two theme) seen))))
    (cl-letf (((symbol-function 'frame-parameter)
               (lambda (_frame param)
                 (when (eq param 'background-mode) 'dark))))
      (agent--do-sync-theme t)
      (should (equal (sort seen (lambda (a b)
                                  (string< (symbol-name (car a))
                                           (symbol-name (car b)))))
                     '((one . "dark") (two . "dark")))))))

(ert-deftest agent-test-sync-theme-before-start-respects-toggle ()
  "Do not sync immediately when `agent-sync-theme' is disabled."
  (let ((agent-sync-theme nil)
        (called nil))
    (cl-letf (((symbol-function 'agent--do-sync-theme)
               (lambda () (setq called t))))
      (agent-sync-theme-now)
      (should-not called))))

;;;; Backend registration

(ert-deftest agent-test-register-backend-requires-session-keys ()
  "Reject backend registrations that are missing required keys."
  (let ((agent-backends nil))
    (should-error
     (apply #'agent-register-backend 'bad (list :buffer-p #'ignore)))))

;;;; gptel response handling

(ert-deftest agent-test-gptel-response-text-accepts-final-response ()
  "Return final gptel response text unchanged."
  (should (equal (agent--gptel-response-text "agent, gptel") "agent, gptel")))

(ert-deftest agent-test-gptel-response-text-ignores-reasoning-event ()
  "Ignore gptel reasoning events sent before final response text."
  (should-not (agent--gptel-response-text '(reasoning . "thinking"))))

;;;; Backtrace debugging

(ert-deftest agent-test-debug-backtrace-excerpt-truncates-long-lines ()
  "Truncate oversized backtrace lines while keeping the frame names."
  (let* ((long (concat "  json-serialize(" (make-string 10000 ?x) ")"))
         (excerpt (agent--debug-backtrace-excerpt (concat "short\n" long))))
    (should (string-prefix-p "short\n  json-serialize(" excerpt))
    (should (< (length excerpt) 1000))))

(ert-deftest agent-test-debug-backtrace-excerpt-keeps-short-content ()
  "Return short backtrace content unchanged."
  (should (equal (agent--debug-backtrace-excerpt "a\nb") "a\nb")))

(ert-deftest agent-test-debug-backtrace-excerpt-caps-total-size ()
  "Cap the total excerpt size for backtraces with many lines."
  (let* ((line (make-string 200 ?y))
         (contents (mapconcat #'identity (make-list 5000 line) "\n")))
    (should (<= (length (agent--debug-backtrace-excerpt contents))
                agent--debug-backtrace-size-limit))))

;;;; Page scrolling

(ert-deftest agent-test-setup-scroll-keys-overrides-terminal-navigation ()
  "Make PageUp and PageDown scroll instead of reaching terminal keymaps."
  (let ((minor-mode-overriding-map-alist nil))
    (with-temp-buffer
      (setq-local eat-terminal 'terminal)
      (agent-test--terminal-navigation-mode 1)
      (cl-letf (((symbol-function 'agent--detect-backend)
                 (lambda (_buffer) 'claude-code)))
        (agent-setup-scroll-keys))
      (should agent-scroll-keys-mode)
      (should (assq 'agent-scroll-keys-mode
                    minor-mode-overriding-map-alist))
      (should (eq (key-binding (kbd "<prior>") t)
                  #'agent-scroll-page-up))
      (should (eq (key-binding (kbd "<next>") t)
                  #'agent-scroll-page-down))
      (should (eq (key-binding (kbd "<kp-prior>") t)
                  #'agent-scroll-page-up))
      (should (eq (key-binding (kbd "<kp-next>") t)
                  #'agent-scroll-page-down)))))

(ert-deftest agent-test-setup-scroll-keys-ignores-non-eat-sessions ()
  "Leave non-Eat session buffers alone."
  (with-temp-buffer
    (cl-letf (((symbol-function 'agent--detect-backend)
               (lambda (_buffer) 'codex)))
      (agent-setup-scroll-keys))
    (should-not agent-scroll-keys-mode)))

(ert-deftest agent-test-setup-scroll-keys-updates-existing-buffers ()
  "Apply PageUp and PageDown scrolling to existing terminal buffers."
  (let ((eat-buffer (generate-new-buffer " *agent-eat*"))
        (other-buffer (generate-new-buffer " *agent-other*")))
    (unwind-protect
        (cl-letf (((symbol-function 'agent--find-all-buffers)
                   (lambda () (list eat-buffer other-buffer)))
                  ((symbol-function 'agent--detect-backend)
                   (lambda (buffer)
                     (and (eq buffer eat-buffer) 'claude-code))))
          (with-current-buffer eat-buffer
            (setq-local eat-terminal 'terminal))
          (agent-setup-scroll-keys-in-existing-buffers)
          (with-current-buffer eat-buffer
            (should agent-scroll-keys-mode)
            (should (eq (key-binding (kbd "<prior>") t)
                        #'agent-scroll-page-up))
            (should (eq (key-binding (kbd "<next>") t)
                        #'agent-scroll-page-down)))
          (with-current-buffer other-buffer
            (should-not agent-scroll-keys-mode)))
      (kill-buffer eat-buffer)
      (kill-buffer other-buffer))))

(ert-deftest agent-test-scroll-page-keys-send-terminal-wheel-events ()
  "PageUp and PageDown drive the terminal mouse-wheel path."
  (let ((agent-scroll-wheel-events 8)
        events)
    (with-temp-buffer
      (setq-local eat-terminal 'terminal)
      (cl-letf (((symbol-function 'eat-self-input)
                 (lambda (count event)
                   (push (list count (event-basic-type event)) events))))
        (agent-scroll-page-up)
        (agent-scroll-page-down)))
    (should (equal (nreverse events)
                   '((8 wheel-up) (8 wheel-down))))))

(ert-deftest agent-test-global-scroll-mode-preserves-nonterminal-page-keys ()
  "Keep PageUp and PageDown local to a selected nonterminal buffer."
  (let ((agent-scroll-keys-global-mode t))
    (with-temp-buffer
      (agent-test--terminal-navigation-mode 1)
      (should (eq (key-binding (kbd "<prior>") t)
                  #'agent-test--terminal-page-up))
      (should (eq (key-binding (kbd "<next>") t)
                  #'agent-test--terminal-page-down)))))

(ert-deftest agent-test-clear-global-scroll-keymap-removes-legacy-state ()
  "Remove global PageUp bindings left behind by a package reload."
  (let* ((map (make-sparse-keymap))
         (agent-scroll-keys-global-mode-map map)
         (minor-mode-map-alist
          (cons (cons 'agent-scroll-keys-global-mode map)
                minor-mode-map-alist)))
    (define-key map [prior] #'agent-scroll-page-up)
    (agent--clear-global-scroll-keymap)
    (should-not agent-scroll-keys-global-mode-map)
    (should-not (assq 'agent-scroll-keys-global-mode
                      minor-mode-map-alist))))

(ert-deftest agent-test-scroll-commands-ignore-visible-unselected-terminal ()
  "Keep scroll commands in the selected nonterminal window."
  (let ((terminal-buffer (generate-new-buffer " *agent-visible-eat*"))
        (other-buffer (generate-new-buffer " *agent-visible-other*"))
        events
        originals)
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (switch-to-buffer other-buffer)
          (let ((terminal-window (split-window-right)))
            (set-window-buffer terminal-window terminal-buffer)
            (with-current-buffer terminal-buffer
              (setq-local eat-terminal 'terminal))
            (cl-letf (((symbol-function 'agent--detect-backend)
                       (lambda (buffer)
                         (and (eq buffer terminal-buffer) 'claude-code)))
                      ((symbol-function 'agent--send-terminal-wheel)
                       (lambda (&rest args) (push args events))))
              (agent--scroll-down-command
               (lambda () (push 'down originals)))
              (agent--scroll-up-command
               (lambda () (push 'up originals)))))
          (should-not events)
          (should (equal (nreverse originals) '(down up))))
      (kill-buffer terminal-buffer)
      (kill-buffer other-buffer))))

(ert-deftest agent-test-scroll-down-command-redirects-in-terminals ()
  "Redirect `scroll-down-command' itself in agent terminal buffers."
  (let (events)
    (with-temp-buffer
      (setq-local eat-terminal 'terminal)
      (save-window-excursion
        (switch-to-buffer (current-buffer))
        (cl-letf (((symbol-function 'agent--detect-backend)
                   (lambda (_buffer) 'claude-code))
                  ((symbol-function 'agent--send-terminal-wheel)
                   (lambda (event window)
                     (push (list event (eq window (selected-window)))
                           events))))
          (agent--scroll-down-command #'ignore)
          (agent--scroll-up-command #'ignore))))
    (should (equal (nreverse events)
                   '((wheel-up t) (wheel-down t))))))

(ert-deftest agent-test-scroll-command-advice-installs-symmetrically ()
  "Enable and disable scroll command advice with global scroll mode."
  (let ((agent-scroll-keys-global-mode nil))
    (unwind-protect
        (progn
          (agent-scroll-keys-global-mode 1)
          (should (advice-member-p #'agent--scroll-down-command
                                   'scroll-down-command))
          (should (advice-member-p #'agent--scroll-up-command
                                   'scroll-up-command))
          (agent-scroll-keys-global-mode -1)
          (should-not (advice-member-p #'agent--scroll-down-command
                                       'scroll-down-command))
          (should-not (advice-member-p #'agent--scroll-up-command
                                       'scroll-up-command)))
      (agent-scroll-keys-global-mode -1))))

;;;; Session keys and display names

(ert-deftest agent-test-session-name-handles-directory-without-trailing-slash ()
  "Extract the project name when the buffer directory lacks a trailing slash."
  (should (equal (agent--session-name
                  "*codex:~/My Drive/Epoch/projects/ai-access-management:default*")
                 "ai-access-management")))

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

(ert-deftest agent-test-ensure-session-keys-assigns-home-row-keys ()
  "Assign home-row keys to all active backend buffers."
  (let ((agent-backends nil)
        (agent--session-keys (make-hash-table :test 'eq)))
    (with-temp-buffer
      (rename-buffer "*one:~/repo/a/:default*" t)
      (let ((one (current-buffer)))
        (with-temp-buffer
          (rename-buffer "*one:~/repo/b/:default*" t)
          (let ((two (current-buffer)))
            (apply #'agent-register-backend
             'one
             (agent-test--backend
              :buffer-p (lambda (buf)
                          (string-prefix-p "*one:" (buffer-name buf)))
              :find-all-buffers (lambda () (list one two))))
            (agent--ensure-all-session-keys)
            (should (equal (gethash one agent--session-keys) "a"))
            (should (equal (gethash two agent--session-keys) "s"))))))))

(ert-deftest agent-test-display-name-appends-backend-suffix ()
  "Append backend display suffixes after the shared base name."
  (let ((agent-backends nil)
        (agent--session-keys (make-hash-table :test 'eq)))
    (with-temp-buffer
      (rename-buffer "*one:~/repo/project/:default*" t)
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :find-all-buffers (lambda () (list buf))
          :display-name-suffix (lambda (_buffer) "branch")))
        (should (equal (agent-display-name buf) "project:branch"))))))

(ert-deftest agent-test-session-groups-use-account-key ()
  "Group session switcher suffixes by session account."
  (let ((agent-backends nil)
        (agent--session-keys (make-hash-table :test 'eq)))
    (with-temp-buffer
      (rename-buffer "*one:~/repo/a/:default*" t)
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :find-all-buffers (lambda () (list buf))))
        (setq-local agent--session
                    (agent-session-create :backend 'one :account "work"))
        (puthash buf "a" agent--session-keys)
        (should (equal (mapcar #'car (agent--group-sessions-by-account))
                       '("work")))))))

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

(ert-deftest agent-test-switcher-column-width-measures-childless-column ()
  "Measure a column with no children as the width of its heading.
The switcher's own Sessions column is childless in the static layout:
its suffixes are added at setup time."
  (let ((column (vector 'transient-column '(:description "Sessions") nil)))
    (should (= (agent--switcher-column-width column) (length "Sessions")))))

(ert-deftest agent-test-switcher-column-width-rejects-computed-heading ()
  "Signal when a column heading is present but not a string.
Transient permits a function there, whose width this arithmetic cannot
measure; treating it as zero would understate the column."
  (let ((column (vector 'transient-column
                        '(:description ignore)
                        '((transient-suffix :key "w"
                                            :description "x"
                                            :command ignore)))))
    (should-error (agent--switcher-column-width column))))

(ert-deftest agent-test-switcher-sessions-column-offset-clears-actions ()
  "Start the Sessions column two columns past the Actions column.
The expected value is derived from the Actions column's own contents,
so renaming an action updates this test's expectation with it, while a
change in transient's layout representation breaks it loudly."
  (should (= (agent--switcher-sessions-column-offset)
             (+ 2 (max (length "Actions")
                       (+ 2 1 (length "jump to waiting"))
                       (+ 2 1 (length "new session")))))))

(ert-deftest agent-test-switcher-sessions-column-offset-requires-a-sessions-column ()
  "Signal when no column of the layout is headed \"Sessions\".
Summing every column instead would yield a plausible but wrong offset,
and annotations narrower than the frame allows."
  (cl-letf (((symbol-function 'agent--switcher-columns)
             (lambda ()
               (list (vector 'transient-column
                             '(:description "Actions")
                             '((transient-suffix :key "w"
                                                 :description "jump to waiting"
                                                 :command ignore)))))))
    (should-error (agent--switcher-sessions-column-offset))))

(ert-deftest agent-test-annotation-width-honors-max-width ()
  "Cap annotations at `agent-session-annotation-max-width' when set."
  (let ((agent-session-annotation-max-width 12))
    (should (= (agent--session-annotation-width 30) 12))))

(ert-deftest agent-test-annotation-width-fits-the-frame ()
  "Fit annotations to the frame when no maximum width is set.
The switcher window spans the frame, so the room left over is the
frame width minus the Sessions column offset, the three columns
transient spends on \" k \", the padded label, the one column of the
separator space before the annotation, and two trailing columns."
  (let ((agent-session-annotation-max-width nil))
    (cl-letf (((symbol-function 'frame-width) (lambda (&optional _) 100)))
      (should (= (agent--session-annotation-width 20)
                 (- 100 (agent--switcher-sessions-column-offset)
                    3 20 1 2))))))

(ert-deftest agent-test-annotation-width-caps-rather-than-overrides ()
  "Never let `agent-session-annotation-max-width' widen an annotation.
The option is a maximum, so a value larger than the frame fits yields
the frame fit."
  (let ((agent-session-annotation-max-width 500))
    (cl-letf (((symbol-function 'frame-width) (lambda (&optional _) 100)))
      (should (= (agent--session-annotation-width 20)
                 (- 100 (agent--switcher-sessions-column-offset)
                    3 20 1 2))))))

(ert-deftest agent-test-annotation-width-has-a-floor ()
  "Never return a width below 20 columns, however narrow the frame."
  (let ((agent-session-annotation-max-width nil))
    (cl-letf (((symbol-function 'frame-width) (lambda (&optional _) 30)))
      (should (= (agent--session-annotation-width 20) 20)))))

;;;; Switcher annotations

(defun agent-test--switcher-label (buffer)
  "Return the switcher label BUFFER would render with, unpadded."
  (nth 1 (agent--session-suffix-spec buffer "a")))

(defun agent-test--annotation-column (label)
  "Return the display column LABEL's \"summary\" annotation starts at.
Measured in columns rather than characters, since those differ for a
double-width name and only the column is what lines up on screen."
  (string-width (substring label 0 (string-search "summary" label))))

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
  (let ((agent-session-annotation-functions nil))
    (agent-test--with-session-buffer "*one:~/repo/project/:default*"
      (should (equal (agent-test--switcher-label buf) "project")))))

(ert-deftest agent-test-session-label-appends-annotation ()
  "Append the annotation after the session name."
  (let ((agent-session-annotation-functions
         (list (lambda (_buffer) "Fix the parser"))))
    (agent-test--with-session-buffer "*one:~/repo/project/:default*"
      (let ((label (agent-test--switcher-label buf)))
        (should (string-prefix-p "project" label))
        (should (string-suffix-p "Fix the parser" label))))))

(ert-deftest agent-test-session-annotation-is-dimmed ()
  "Carry `agent-session-annotation' on the annotation, not the name."
  (let ((agent-session-annotation-functions
         (list (lambda (_buffer) "Fix the parser"))))
    (agent-test--with-session-buffer "*one:~/repo/project/:default*"
      (let* ((label (agent-test--switcher-label buf))
             (start (string-search "Fix" label)))
        (should (eq (get-text-property start 'face label)
                    'agent-session-annotation))
        (should-not (get-text-property 0 'face label))))))

(ert-deftest agent-test-session-annotation-collapses-whitespace ()
  "Collapse a multi-line annotation into a single line.
Form feed and vertical tab count as whitespace here too.  Emacs
displays them as ^L and ^K, so letting them through would put control
characters in the menu, which is the layout damage collapsing
whitespace exists to prevent."
  (let ((agent-session-annotation-functions
         (list (lambda (_buffer) "Fix the\n  parser\n"))))
    (agent-test--with-session-buffer "*one:~/repo/project/:default*"
      (should (string-suffix-p "Fix the parser"
                               (agent-test--switcher-label buf)))))
  (let ((agent-session-annotation-functions
         (list (lambda (_buffer) "Fix the\f \vparser"))))
    (agent-test--with-session-buffer "*one:~/repo/project/:default*"
      (should (string-suffix-p "Fix the parser"
                               (agent-test--switcher-label buf))))))

(ert-deftest agent-test-session-annotation-lets-errors-surface ()
  "Let an error from the annotation function reach the caller.
Catching it would leave the switcher quietly unannotated, hiding a
broken integration rather than reporting it."
  (let ((agent-session-annotation-functions
         (list (lambda (_buffer) (error "Annotation function failed")))))
    (agent-test--with-session-buffer "*one:~/repo/project/:default*"
      (should-error (agent-test--switcher-label buf)))))

(ert-deftest agent-test-session-annotation-takes-the-first-answer ()
  "Take the first non-nil answer, passing over functions that decline.
The hook exists so several sources can offer an annotation; a function
that returns nil must leave the session to the ones after it rather
than settling it as unannotated."
  (let ((agent-session-annotation-functions
         (list (lambda (_buffer) nil)
               (lambda (_buffer) "second answer")
               (lambda (_buffer) "third answer"))))
    (agent-test--with-session-buffer "*one:~/repo/project/:default*"
      (should (string-suffix-p "second answer"
                               (agent-test--switcher-label buf))))))

(ert-deftest agent-test-session-annotation-stops-at-the-first-answer ()
  "Leave later functions uncalled once one has answered.
`run-hook-with-args-until-success' stops at the first non-nil answer,
so a costly provider installed behind a cheap one is not paid for."
  (let* ((called nil)
         (agent-session-annotation-functions
          (list (lambda (_buffer) "first answer")
                (lambda (_buffer) (setq called t) "second answer"))))
    (agent-test--with-session-buffer "*one:~/repo/project/:default*"
      (should (string-suffix-p "first answer"
                               (agent-test--switcher-label buf)))
      (should-not called))))

(ert-deftest agent-test-blank-annotation-counts-as-none ()
  "Treat a blank annotation as no annotation, leaving the label plain."
  (let ((agent-session-annotation-functions
         (list (lambda (_buffer) "   "))))
    (agent-test--with-session-buffer "*one:~/repo/project/:default*"
      (should (equal (agent-test--switcher-label buf) "project")))))

(ert-deftest agent-test-session-annotation-is-truncated ()
  "Truncate an annotation that exceeds the available width."
  (let ((agent-session-annotation-functions
         (list (lambda (_buffer) "A very long annotation that will not fit")))
        (agent-session-annotation-max-width 10))
    (agent-test--with-session-buffer "*one:~/repo/project/:default*"
      (let* ((label (agent-test--switcher-label buf))
             (annotation (substring label (1+ (length "project")))))
        (should (<= (string-width annotation) 10))
        (should (string-suffix-p (truncate-string-ellipsis) annotation))))))

(ert-deftest agent-test-zero-width-cap-leaves-the-label-bare ()
  "Render the bare label when the width cap leaves no room at all.
A cap of zero is a legal `natnum', and spending padding and a
separator on an empty annotation would render a label with trailing
whitespace and nothing after it."
  (let ((agent-session-annotation-functions
         (list (lambda (_buffer) "A summary with nowhere to go")))
        (agent-session-annotation-max-width 0))
    (agent-test--with-session-buffer "*one:~/repo/project/:default*"
      (should (equal (agent--session-label buf 20) "project")))))

(ert-deftest agent-test-session-annotations-align-across-accounts ()
  "Start every annotation at one column, across all account groups."
  (let ((agent-backends nil)
        (agent--session-keys (make-hash-table :test 'eq))
        (agent-session-annotation-functions
         (list (lambda (_buffer) "summary"))))
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

(ert-deftest agent-test-session-annotations-align-on-display-columns ()
  "Start annotations at one display column, not one character index.
A double-width name fills more columns than it has characters, so
padding it by character count leaves its annotation further right than
everyone else's.  Measure the display width of the text before each
annotation: a character index would agree across these two labels even
when the columns they land on do not."
  (let ((agent-backends nil)
        (agent--session-keys (make-hash-table :test 'eq))
        (agent-session-annotation-functions
         (list (lambda (_buffer) "summary"))))
    (with-temp-buffer
      (rename-buffer "*one:~/repo/ab/:default*" t)
      (let ((narrow (current-buffer)))
        (with-temp-buffer
          (rename-buffer "*one:~/repo/日本語/:default*" t)
          (let ((wide (current-buffer)))
            (apply #'agent-register-backend
                   'one
                   (agent-test--backend
                    :buffer-p (lambda (candidate)
                                (memq candidate (list narrow wide)))
                    :find-all-buffers (lambda () (list narrow wide))))
            (puthash narrow "a" agent--session-keys)
            (puthash wide "s" agent--session-keys)
            ;; Guard the premise: without double-width characters this
            ;; test would pass whatever the padding counted.
            (should (= (string-width "日本語") 6))
            (let* ((groups (agent--group-sessions-by-account
                            (agent--session-label-pad)))
                   (columns
                    (mapcar (lambda (spec)
                              (agent-test--annotation-column (nth 1 spec)))
                            (apply #'append (mapcar #'cdr groups)))))
              (should (= (length columns) 2))
              (should (apply #'= columns)))))))))

(ert-deftest agent-test-menu-mixes-annotated-and-plain-sessions ()
  "Clear every name in the menu, including the ones with no annotation.
The plain session's name is the longest here, so the column the other
two annotations share has to start beyond it.  The plain label itself
is still bare: the pad decides where annotations start, not how a
label without one ends."
  (let* ((agent-backends nil)
         (agent--session-keys (make-hash-table :test 'eq))
         (agent-session-annotation-functions
          (list (lambda (buffer)
                  (unless (string-match-p "plain" (buffer-name buffer))
                    "summary"))))
         (buffers (mapcar #'generate-new-buffer
                          '("*one:~/repo/ab/:default*"
                            "*one:~/repo/longer/:default*"
                            "*one:~/repo/plain-and-much-longer/:default*"
                            "*one:~/repo/plain-short/:default*"))))
    (unwind-protect
        (progn
          (apply #'agent-register-backend
                 'one
                 (agent-test--backend
                  :buffer-p (lambda (candidate) (memq candidate buffers))
                  :find-all-buffers (lambda () buffers)))
          (cl-loop for buf in buffers
                   for key in '("a" "s" "d" "f")
                   do (puthash buf key agent--session-keys))
          (let* ((groups (agent--group-sessions-by-account
                          (agent--session-label-pad)))
                 (labels (mapcar (lambda (spec) (nth 1 spec))
                                 (apply #'append (mapcar #'cdr groups))))
                 (annotated (seq-filter (lambda (label)
                                          (string-search "summary" label))
                                        labels))
                 (columns (mapcar #'agent-test--annotation-column
                                  annotated)))
            (should (= (length labels) 4))
            (should (= (length annotated) 2))
            ;; Each plain label is exactly its name: no padding, no
            ;; separator, no trailing whitespace.  The short one is
            ;; what makes this bite -- padding the longest name in the
            ;; menu adds nothing, so it would pass either way.
            (should (member "plain-and-much-longer" labels))
            (should (member "plain-short" labels))
            (should (apply #'= columns))
            ;; The shared column clears every name in the menu, the
            ;; unannotated ones included.
            (should (> (car columns)
                       (string-width "plain-and-much-longer")))))
      (mapc #'kill-buffer buffers))))

(ert-deftest agent-test-session-label-pad-counts-unannotated-sessions ()
  "Pad for every session, annotated or not.
The annotations share one column, and it has to clear every name in
the menu: a name measured out of the pad would run past that column
and leave the name list ragged.  So a session with nothing after it
still widens the pad, even though it is not itself padded."
  (let ((agent-session-annotation-functions
         (list (lambda (_buffer) nil))))
    (agent-test--with-session-buffer "*one:~/repo/much-longer-name/:default*"
      (should (= (agent--session-label-pad)
                 (string-width "much-longer-name"))))))

;;;; Display state

(ert-deftest agent-test-display-state-unknown-before-any-event ()
  "Report unknown for sessions that have never seen a session event.
Reporting busy here would present the `defvar-local' initializer as an
observation."
  (let ((agent-backends nil))
    (with-temp-buffer
      (should (eq (agent-session-display-state (current-buffer)) 'unknown)))))

(ert-deftest agent-test-display-state-busy-after-submit ()
  "Report busy once a submit event has been observed."
  (let ((agent-backends nil))
    (with-temp-buffer
      (agent-session-event (current-buffer) 'submit)
      (should (eq (agent-session-display-state (current-buffer)) 'busy)))))

(ert-deftest agent-test-unknown-session-is-not-waiting ()
  "Do not offer unknown sessions to `agent-jump-to-waiting'."
  (let ((agent-backends nil))
    (with-temp-buffer
      (should-not (agent--session-waiting-p (current-buffer))))))

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
        (apply #'agent-register-backend
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
        (apply #'agent-register-backend
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
        (apply #'agent-register-backend
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
          (apply #'agent-register-backend
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

(ert-deftest agent-test-waiting-with-background-work-displays-amber ()
  "Use the background-waiting state when the backend reports work."
  (let ((agent-backends nil))
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :find-all-buffers (lambda () (list buf))
          :background-tasks-p (lambda (_buffer) t)))
        (setq-local agent--session-state 'awaiting-input)
        (should (eq (agent-session-display-state buf 'one)
                    'background-waiting))))))

;;;; Skills

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
          (apply #'agent-register-backend
           'one
           (agent-test--backend
            :label "One"
            :skill-roots (lambda () (list (cons dir-one 'file)))
            :run-prompt (cl-function
                         (lambda (prompt &key directory callback)
                           (ignore directory callback)
                           (setq ran (list 'one prompt))))))
          (apply #'agent-register-backend
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

(ert-deftest agent-test-post-push-ci-runs-skill-for-head ()
  "Run post-push CI through the selected backend with the current HEAD."
  (let* ((agent-backends nil)
         (root (make-temp-file "agent-skills" t))
         (skill-file (expand-file-name "post-push-ci/SKILL.md" root))
         ran)
    (unwind-protect
        (progn
          (make-directory (file-name-directory skill-file) t)
          (with-temp-file skill-file
            (insert "---\nname: post-push-ci\n---\nClose the loop.\n"))
          (apply #'agent-register-backend
           'one
           (agent-test--backend
            :skill-roots (lambda () (list (cons root 'file)))
            :run-prompt (cl-function
                         (lambda (prompt &key directory callback)
                           (ignore directory callback)
                           (setq ran prompt)))))
          (cl-letf (((symbol-function 'process-file)
                     (lambda (&rest _args)
                       (insert "abc123\n")
                       0)))
            (agent-post-push-ci)
            (should (string-match-p (regexp-quote skill-file) ran))
            (should (string-match-p "--no-push --commit abc123" ran))))
      (delete-directory root t))))

(ert-deftest agent-test-trajectory-new-task-uses-origin-main ()
  "Create a Trajectory reasoning-tasks task from origin/main."
  (let* ((root (file-name-as-directory
         (make-temp-file "agent-trajectory" t)))
         (agent-trajectory-reasoning-tasks-root root)
         (agent-trajectory-sync-worktree-script
          (expand-file-name "missing-sync.sh" root))
         (slug "model-spec-inclusion")
         (target (expand-file-name slug root))
         (calls nil)
         opened)
    (unwind-protect
        (progn
          (make-directory (expand-file-name "main" root))
          (cl-letf (((symbol-function 'process-file)
                     (lambda (program _infile buffer _display &rest args)
                       (push (cons program args) calls)
                       (when buffer
                         (with-current-buffer buffer
                           (insert "ok\n")))
                       0))
                    ((symbol-function 'dired)
                     (lambda (dir) (setq opened dir))))
            (agent-trajectory-new-task slug)
            (should (equal (reverse calls)
                           `(("git" "fetch" "origin" "main")
                             ("git" "worktree" "add" ,target
                              "-b" ,(concat "pablo/" slug)
                              "origin/main")
                             ("git" "sparse-checkout" "set"
                              ".claude" "meta" "platform"))))
            (should (equal opened target))
            (should (file-directory-p (expand-file-name ".claude" target)))
            (should (file-symlink-p (expand-file-name ".claude/.env" target)))
            (should (equal
                     (file-symlink-p (expand-file-name ".claude/.env" target))
                     (expand-file-name
                      "reasoning-tasks-cr-studio/.claude/.env" root)))))
      (delete-directory root t))))

(ert-deftest agent-test-trajectory-new-task-runs-sync-script ()
  "Delegate worktree overlay setup to the sync hook script."
  (let* ((root (file-name-as-directory
                (make-temp-file "agent-trajectory" t)))
         (script (make-temp-file "agent-sync-script"))
         (agent-trajectory-reasoning-tasks-root root)
         (agent-trajectory-sync-worktree-script script)
         (slug "ai-race-information-hazards")
         (target (expand-file-name slug root))
         sync-call)
    (unwind-protect
        (progn
          (make-directory (expand-file-name "main" root))
          (cl-letf (((symbol-function 'process-file)
                     (lambda (program _infile buffer _display &rest args)
                       (when (equal program "bash")
                         (setq sync-call (list default-directory args
                                               process-environment)))
                       (when buffer
                         (with-current-buffer buffer
                           (insert "ok\n")))
                       0))
                    ((symbol-function 'dired) #'ignore))
            (agent-trajectory-new-task slug)
            (should (equal (nth 0 sync-call)
                           (file-name-as-directory target)))
            (should (equal (nth 1 sync-call) (list script)))
            (should (member "SYNC_REASONING_TASKS_SKIP_FETCH=1"
                            (nth 2 sync-call)))
            (should (member (concat "CLAUDE_PROJECT_DIR=" target)
                            (nth 2 sync-call)))))
      (delete-directory root t)
      (delete-file script))))

(ert-deftest agent-test-trajectory-new-task-rejects-path-slugs ()
  "Reject task slugs that are not a single path component."
  (should-error (agent-trajectory-new-task "../bad") :type 'user-error)
  (should-error (agent-trajectory-new-task "nested/task") :type 'user-error))

(ert-deftest agent-test-skill-result-does-not-modify-new-user-buffer ()
  "Display skill output in a result buffer, not an unrelated new buffer."
  (let ((unrelated (get-buffer-create "*agent-unrelated*"))
        (result-buffer "*Agent skill: proofread*"))
    (unwind-protect
        (progn
          (with-current-buffer unrelated
            (erase-buffer)
            (insert "#+title: User buffer\nBody\n"))
          (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
            (agent--display-skill-result "proofread" "ok" nil))
          (with-current-buffer unrelated
            (should (equal (buffer-string) "#+title: User buffer\nBody\n")))
          (should (get-buffer result-buffer)))
      (when (buffer-live-p unrelated)
        (kill-buffer unrelated))
      (when-let* ((buf (get-buffer result-buffer)))
        (kill-buffer buf)))))

;;;; Project audit

(ert-deftest agent-test-audit-commits-after-successful-skill ()
  "Auto-commit after each successful audit skill and not after failures."
  (let ((agent-backends nil)
        (agent-audit-skills '("a" "b"))
        commits)
    (apply #'agent-register-backend
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

(ert-deftest agent-test-audit-strips-leading-slash-from-skill-names ()
  "Resolve legacy slash-format audit skill names like plain names."
  (let ((agent-backends nil)
        prompts)
    (apply #'agent-register-backend
     'one
     (agent-test--backend
      :skill-roots (lambda () nil)
      :run-prompt (cl-function
                   (lambda (prompt &key directory callback)
                     (ignore directory)
                     (push prompt prompts)
                     (funcall callback "out" :error nil)))))
    (cl-letf (((symbol-function 'agent--audit-commit-changes) #'ignore)
              ((symbol-function 'agent--audit-finish) #'ignore))
      (dolist (queue '(("/code-audit") ("code-audit")))
        (agent--audit-run-next (list :backend 'one :queue queue
                                     :results nil :dir "/tmp/"
                                     :start-time (current-time)))))
    (should (equal prompts
                   '("/code-audit --accept" "/code-audit --accept")))))

(ert-deftest agent-test-force-kill-buffer-ignores-query-functions ()
  "Kill buffers even when unrelated query functions would veto it."
  (let ((buf (generate-new-buffer "agent-force-kill-test")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (add-hook 'kill-buffer-query-functions (lambda () nil) nil t))
          (agent--force-kill-buffer buf)
          (should-not (buffer-live-p buf)))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest agent-test-add-process-exit-hook-composes-with-sentinel ()
  "Run the original sentinel and stacked exit hooks once each on exit."
  (let* ((buf (generate-new-buffer " *agent-exit-hook*"))
         (events nil)
         (proc (make-process :name "agent-exit-hook-test" :buffer buf
                             :command '("true") :connection-type 'pipe)))
    (unwind-protect
        (progn
          (set-process-sentinel proc (lambda (_p _e) (push 'orig events)))
          (agent--add-process-exit-hook
           buf (lambda (_buffer) (push 'hook events)))
          (agent--add-process-exit-hook
           buf (lambda (_buffer) (push 'hook2 events)))
          (while (process-live-p proc)
            (accept-process-output proc 0.1))
          (with-timeout (2 (ert-fail "sentinel never ran"))
            (while (< (length events) 3)
              (sit-for 0.05)))
          (should (= (length events) 3))
          (should (memq 'orig events))
          (should (memq 'hook events))
          (should (memq 'hook2 events)))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest agent-test-setup-kill-on-exit-honors-before-kill-check ()
  "Do not kill the buffer when the backend before-kill-check vetoes."
  (let ((agent-backends nil)
        (hook-fn nil))
    (with-temp-buffer
      (rename-buffer "*one:~/repo/project/:default*" t)
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
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

(ert-deftest agent-test-exit-runs-before-exit-functions ()
  "Abort exit when a before-exit function returns nil."
  (let ((agent-backends nil)
        (agent-before-exit-functions nil)
        ran
        seen)
    (with-temp-buffer
      (rename-buffer "*one:~/repo/project/:default*" t)
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
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

(ert-deftest agent-test-exit-proceeds-after-before-exit-functions ()
  "Exit when every before-exit function returns non-nil."
  (let ((agent-backends nil)
        (agent-before-exit-functions nil)
        ran)
    (with-temp-buffer
      (rename-buffer "*one:~/repo/project/:default*" t)
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))))
        (add-hook 'agent-before-exit-functions (lambda (_backend _buffer) t))
        (cl-letf (((symbol-function 'agent--exit-session)
                   (lambda (_buffer) (setq ran t))))
          (agent-exit))
        (should ran)))))

(ert-deftest agent-test-exit-confirms-when-captured-prompts-pending ()
  "Abort exit when pending captured prompts exist and confirmation is declined."
  (let ((agent-backends nil)
        (agent-before-exit-functions nil)
        (agent-prompt-capture-directory (make-temp-file "agent-prompts" t))
        prompted
        ran)
    (unwind-protect
        (with-temp-buffer
          (rename-buffer "*one:~/repo/project/:default*" t)
          (let ((buf (current-buffer)))
            (apply #'agent-register-backend
             'one
             (agent-test--backend
              :buffer-p (lambda (candidate) (eq candidate buf))))
            (let ((file (agent-capture--file 'one buf)))
              (make-directory (file-name-directory file) t)
              (with-temp-file file
                (insert "* Prompt A\n\nAlpha\n")))
            (cl-letf (((symbol-function 'yes-or-no-p)
                       (lambda (prompt)
                         (setq prompted prompt)
                         nil))
                      ((symbol-function 'agent--exit-session)
                       (lambda (_buffer) (setq ran t))))
              (agent-exit))
            (should (string-match-p "1 captured prompt" prompted))
            (should-not ran)))
      (delete-directory agent-prompt-capture-directory t))))

(ert-deftest agent-test-exit-skips-capture-confirmation-without-prompts ()
  "Do not prompt for capture confirmation when no captured prompts exist."
  (let ((agent-backends nil)
        (agent-before-exit-functions nil)
        (agent-prompt-capture-directory (make-temp-file "agent-prompts" t))
        prompted
        ran)
    (unwind-protect
        (with-temp-buffer
          (rename-buffer "*one:~/repo/project/:default*" t)
          (let ((buf (current-buffer)))
            (apply #'agent-register-backend
             'one
             (agent-test--backend
              :buffer-p (lambda (candidate) (eq candidate buf))))
            (cl-letf (((symbol-function 'yes-or-no-p)
                       (lambda (_prompt)
                         (setq prompted t)
                         nil))
                      ((symbol-function 'agent--exit-session)
                       (lambda (_buffer) (setq ran t))))
              (agent-exit))
            (should-not prompted)
            (should ran)))
      (delete-directory agent-prompt-capture-directory t))))

(ert-deftest agent-test-restart-confirms-when-captured-prompts-pending ()
  "Abort restart when pending captures exist and confirmation is declined."
  (let ((agent-backends nil)
        (agent-prompt-capture-directory (make-temp-file "agent-prompts" t))
        prompted
        killed)
    (unwind-protect
        (with-temp-buffer
          (rename-buffer "*one:~/repo/project/:default*" t)
          (let ((buf (current-buffer)))
            (apply #'agent-register-backend
             'one
             (agent-test--backend
              :buffer-p (lambda (candidate) (eq candidate buf))
              :session-identity (lambda (_buffer) "sid-123")))
            (let ((file (agent-capture--file 'one buf)))
              (make-directory (file-name-directory file) t)
              (with-temp-file file
                (insert "* Prompt A\n\nAlpha\n")))
            (cl-letf (((symbol-function 'yes-or-no-p)
                       (lambda (prompt)
                         (setq prompted prompt)
                         nil))
                      ((symbol-function 'agent--force-kill-buffer)
                       (lambda (_buffer) (setq killed t))))
              (agent-restart))
            (should (string-match-p "1 captured prompt" prompted))
            (should-not killed)))
      (delete-directory agent-prompt-capture-directory t))))

(ert-deftest agent-test-restart-resumes-with-session-identity ()
  "Restart kills the buffer and resumes the exact session id."
  (let ((agent-backends nil)
        (agent-prompt-capture-directory (make-temp-file "agent-prompts" t))
        killed
        resumed)
    (unwind-protect
        (with-temp-buffer
          (rename-buffer "*one:~/repo/project/:default*" t)
          (let ((buf (current-buffer)))
            (apply #'agent-register-backend
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
            (should (equal resumed '(one "sid-123")))))
      (delete-directory agent-prompt-capture-directory t))))

(ert-deftest agent-test-restart-without-identity-does-not-kill ()
  "Restart refuses to kill the buffer when no session id exists."
  (let ((agent-backends nil)
        (agent-prompt-capture-directory (make-temp-file "agent-prompts" t))
        killed)
    (unwind-protect
        (with-temp-buffer
          (rename-buffer "*one:~/repo/project/:default*" t)
          (let ((buf (current-buffer)))
            (apply #'agent-register-backend
             'one
             (agent-test--backend
              :buffer-p (lambda (candidate) (eq candidate buf))
              :session-identity (lambda (_buffer) nil)))
            (cl-letf (((symbol-function 'agent--force-kill-buffer)
                       (lambda (_buffer) (setq killed t))))
              (should-error (agent-restart) :type 'user-error))
            (should-not killed)))
      (delete-directory agent-prompt-capture-directory t))))

(ert-deftest agent-test-restart-without-restart-options-omits-extras ()
  "Restart backends lacking restart-options with only the resume id."
  (let ((agent-backends nil)
        (agent-prompt-capture-directory (make-temp-file "agent-prompts" t))
        (captured 'unset))
    (unwind-protect
        (with-temp-buffer
          (rename-buffer "*one:~/repo/project/:default*" t)
          (let ((buf (current-buffer)))
            (apply #'agent-register-backend
             'one
             (agent-test--backend
              :buffer-p (lambda (candidate) (eq candidate buf))
              :session-identity (lambda (_buffer) "sid-123")))
            (cl-letf (((symbol-function 'agent--force-kill-buffer) #'ignore)
                      ((symbol-function 'agent-restart--account)
                       (lambda (_backend _account) nil))
                      ((symbol-function 'agent-start-session)
                       (lambda (_session &rest options)
                         (setq captured options))))
              (agent-restart))
            (should (equal captured '(:resume-id "sid-123")))))
      (delete-directory agent-prompt-capture-directory t))))

(ert-deftest agent-test-handoff-carries-source-session ()
  "Start the handoff session with the source buffer's account and directory."
  (let* ((agent-backends nil)
         (agent-prompt-capture-directory (make-temp-file "agent-prompts" t))
         (dir (file-name-as-directory (make-temp-file "agent-handoff" t)))
         (handoff-file (expand-file-name "handoff.md" dir))
         killed started)
    (unwind-protect
        (with-temp-buffer
          (let ((buf (current-buffer)))
            (setq default-directory dir)
            (apply #'agent-register-backend
             'one
             (agent-test--backend
              :buffer-p (lambda (candidate) (eq candidate buf))))
            (with-temp-file handoff-file (insert "continue\n"))
            (let ((agent-handoff-files '((one . "handoff.md"))))
              (cl-letf (((symbol-function 'agent--handoff-file)
                         (lambda (_backend) handoff-file))
                        ((symbol-function 'agent-session)
                         (lambda (&optional _buffer)
                           (agent-session-create :backend 'one :account "work"
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
      (delete-directory agent-prompt-capture-directory t)
      (delete-directory dir t))))

(ert-deftest agent-test-run-skill-before-exit-submits-codex-skill ()
  "Submit a Codex skill and abort the first exit globally by default."
  (let ((agent-backends nil)
        (agent-before-exit-skill-name "session-retro")
        (agent-before-exit-skill-directories nil)
        events)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'codex
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :skill-command-prefix "$"
          :send-string (lambda (cmd &optional _buffer)
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
        (events nil)
        exited)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'codex
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :skill-command-prefix "$"
          :submit (lambda (cmd &optional _buffer) (push cmd events))))
        (cl-letf (((symbol-function 'agent--before-exit-start-watchdog)
                   (lambda (_buffer) nil))
                  ((symbol-function 'agent--exit-session)
                   (lambda (_buffer) (setq exited t)))
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

(ert-deftest agent-test-before-exit-progress-renews-timeout-and-kills-buffer ()
  "Give each progressing skill a full timeout before killing the buffer."
  (let ((agent-backends nil)
        (agent-before-exit-skill-names '("first" "second"))
        (agent-before-exit-skill-name nil)
        (agent-before-exit-skill-directories nil)
        (agent-before-exit-timeout 600)
        canceled
        timers
        (timer-count 0))
    (let ((buf (generate-new-buffer " *agent-progressing-exit*")))
      (unwind-protect
          (progn
            (apply #'agent-register-backend
             'one
             (agent-test--backend
              :buffer-p (lambda (candidate) (eq candidate buf))
              :skill-command-prefix "/"
              :submit (lambda (command &optional _buffer)
                        (when (equal command "/exit")
                          (kill-buffer buf)))))
            (cl-letf (((symbol-function 'run-at-time)
                       (lambda (time _repeat function &rest args)
                         (if (zerop time)
                             (apply function args)
                           (let ((timer (list 'watchdog
                                              (cl-incf timer-count))))
                             (push (list timer function args) timers)
                             timer))))
                      ((symbol-function 'cancel-timer)
                       (lambda (timer) (push timer canceled))))
              (with-current-buffer buf
                (should-not (agent-run-skill-before-exit 'one buf)))
              (let* ((state (buffer-local-value 'agent--before-exit buf))
                     (first-watchdog (plist-get state :timer)))
                (should (agent--before-exit-transition buf 'step))
                (unless (member first-watchdog canceled)
                  (let ((timer (cl-find first-watchdog timers
                                        :key #'car :test #'equal)))
                    (apply (nth 1 timer) (nth 2 timer))))
                (agent--before-exit-transition buf 'step)
                (should-not (buffer-live-p buf)))))
        (when (buffer-live-p buf)
          (kill-buffer buf))))))

(ert-deftest agent-test-before-exit-veto-defers-exactly-one-stop ()
  "Defer chain advance while the backend vetoes, then proceed."
  (let ((agent-backends nil)
        (agent-before-exit-skill-name "session-retro")
        (agent-before-exit-skill-directories nil)
        (ready nil)
        exited)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'codex
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :skill-command-prefix "$"
          :submit (lambda (_cmd &optional _buffer))
          :before-exit-ready-to-close-p (lambda (_buffer) ready)))
        (cl-letf (((symbol-function 'agent--before-exit-start-watchdog)
                   (lambda (_buffer) nil))
                  ((symbol-function 'agent--exit-session)
                   (lambda (_buffer) (setq exited t)))
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
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'codex
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :skill-command-prefix "$"
          :submit (lambda (_cmd &optional _buffer))))
        (cl-letf (((symbol-function 'agent--exit-session)
                   (lambda (_buffer) (setq exited t)))
                  ((symbol-function 'run-at-time)
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

(ert-deftest agent-test-run-skill-before-exit-submits-in-matching-directory ()
  "Submit a Codex skill in explicitly configured directories."
  (let ((agent-backends nil)
        (agent-before-exit-skill-name "session-retro")
        (events nil))
    (with-temp-buffer
      (let* ((dir (file-name-as-directory default-directory))
             (buf (current-buffer))
             (agent-before-exit-skill-directories (list dir)))
        (apply #'agent-register-backend
         'codex
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :skill-command-prefix "$"
          :send-string (lambda (cmd &optional _buffer)
                          (push (list 'command cmd) events))
          :send-return (lambda (&optional _buffer) (push 'return events))))
        (agent--set-session
         buf (agent-session-create :backend 'codex :directory dir))
        (should-not (agent-run-skill-before-exit 'codex buf))
        (should (equal (nreverse events)
                       '((command "$session-retro") return)))))))

(ert-deftest agent-test-run-skill-before-exit-prefers-submit-command ()
  "Submit before-exit skills through a backend's atomic submit function."
  (let ((agent-backends nil)
        (agent-before-exit-skill-name "session-retro")
        events)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'codex
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :skill-command-prefix "$"
          :submit (lambda (cmd &optional _buffer)
                            (push (list 'submit cmd) events))
          :send-string (lambda (cmd &optional _buffer)
                          (push (list 'command cmd) events))
          :send-return (lambda (&optional _buffer) (push 'return events))))
        (should-not (agent-run-skill-before-exit 'codex buf))
        (should (equal (nreverse events)
                       '((submit "$session-retro"))))))))

(ert-deftest agent-test-run-skill-before-exit-uses-claude-slash ()
  "Submit Claude skills with slash syntax."
  (let ((agent-backends nil)
        (agent-before-exit-skill-name "session-retro")
        (events nil))
    (with-temp-buffer
      (let* ((dir (file-name-as-directory default-directory))
             (buf (current-buffer))
             (agent-before-exit-skill-directories (list dir)))
        (apply #'agent-register-backend
         'claude-code
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :skill-command-prefix "/"
          :send-string (lambda (cmd &optional _buffer)
                          (push (list 'command cmd) events))
          :send-return (lambda (&optional _buffer) (push 'return events))))
        (agent--set-session
         buf (agent-session-create :backend 'claude-code :directory dir))
        (should-not (agent-run-skill-before-exit 'claude-code buf))
        (should (equal (nreverse events)
                       '((command "/session-retro") return)))))))

(ert-deftest agent-test-run-skill-before-exit-skips-other-directories ()
  "Do not submit before-exit skills outside configured directories."
  (let ((agent-backends nil)
        (agent-before-exit-skill-name "session-retro")
        (agent-before-exit-skill-directories '("/tmp/not-this-repo/"))
        called)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'codex
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :send-string (lambda (&rest _args) (setq called t))))
        (agent--set-session
         buf (agent-session-create :backend 'codex
                                   :directory default-directory))
        (should (agent-run-skill-before-exit 'codex buf))
        (should-not called)))))

(ert-deftest agent-test-run-skill-before-exit-skips-short-sessions ()
  "Do not submit before-exit skills before the minimum duration."
  (let ((agent-backends nil)
        (agent-before-exit-skill-name "session-retro")
        (agent-before-exit-skill-directories nil)
        (agent-before-exit-skill-min-duration-seconds 60)
        called)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'codex
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :duration-ms (lambda (_buffer) 30000)
          :send-string (lambda (&rest _args) (setq called t))))
        (should (agent-run-skill-before-exit 'codex buf))
        (should-not called)
        (should-not agent--before-exit)))))

(ert-deftest agent-test-run-skill-before-exit-honors-buffer-local-inhibit ()
  "Do not submit before-exit skills when the session inhibits them."
  (let ((agent-backends nil)
        (agent-before-exit-skill-name "session-retro")
        (agent-before-exit-skill-directories nil)
        called)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (setq-local agent-before-exit-skill-inhibit t)
        (apply #'agent-register-backend
         'codex
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :send-string (lambda (&rest _args) (setq called t))))
        (should (agent-run-skill-before-exit 'codex buf))
        (should-not called)
        (should-not agent--before-exit)))))

(ert-deftest agent-test-run-skill-before-exit-allows-long-sessions ()
  "Submit before-exit skills after the minimum duration."
  (let ((agent-backends nil)
        (agent-before-exit-skill-name "session-retro")
        (agent-before-exit-skill-directories nil)
        (agent-before-exit-skill-min-duration-seconds 60)
        events)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'codex
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :skill-command-prefix "$"
          :duration-ms (lambda (_buffer) 60000)
          :send-string (lambda (cmd &optional _buffer)
                          (push (list 'command cmd) events))
          :send-return (lambda (&optional _buffer) (push 'return events))))
        (should-not (agent-run-skill-before-exit 'codex buf))
        (should (equal (nreverse events)
                       '((command "$session-retro") return)))))))

(ert-deftest agent-test-run-skill-before-exit-matches-expanded-directory ()
  "Match sessions under configured directories that use `~'."
  (let ((agent-backends nil)
        (agent-before-exit-skill-name "session-retro")
        (events nil))
    (with-temp-buffer
      (let* ((dir (expand-file-name "~/tmp/agent-before-exit-test/"))
             (buf (current-buffer))
             (agent-before-exit-skill-directories '("~/tmp/")))
        (apply #'agent-register-backend
         'codex
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :skill-command-prefix "$"
          :send-string (lambda (cmd &optional _buffer)
                          (push (list 'command cmd) events))
          :send-return (lambda (&optional _buffer) (push 'return events))))
        (agent--set-session
         buf (agent-session-create :backend 'codex :directory dir))
        (should-not (agent-run-skill-before-exit 'codex buf))
        (should (equal (nreverse events)
                       '((command "$session-retro") return)))))))

(ert-deftest agent-test-run-skill-before-exit-skips-unknown-backends ()
  "Do not abort exit when BACKEND has no skill command prefix."
  (let ((agent-backends nil)
        (agent-before-exit-skill-name "session-retro")
        called)
    (with-temp-buffer
      (let* ((dir (file-name-as-directory default-directory))
             (buf (current-buffer))
             (agent-before-exit-skill-directories (list dir)))
        (apply #'agent-register-backend
         'other
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :send-string (lambda (&rest _args) (setq called t))))
        (agent--set-session
         buf (agent-session-create :backend 'other :directory dir))
        (should (agent-run-skill-before-exit 'other buf))
        (should-not called)))))

(ert-deftest agent-test-before-exit-step-closes-pending-session ()
  "Exit a session when its before-exit chain has drained."
  (let ((agent-backends nil)
        ran)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))))
        (setq-local agent--before-exit (list :queue nil :state 'running))
        (cl-letf (((symbol-function 'agent--exit-session)
                   (lambda (_buffer) (setq ran t)))
                  ((symbol-function 'run-at-time)
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
        (apply #'agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))))
        (cl-letf (((symbol-function 'agent--exit-session)
                   (lambda (_buffer) (setq ran t))))
          (should-not (agent--before-exit-transition buf 'step)))
        (should-not ran)))))

(ert-deftest agent-test-before-exit-step-honors-backend-veto ()
  "Do not close while a backend reports unaccepted prompt input."
  (let ((agent-backends nil)
        ran)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :before-exit-ready-to-close-p (lambda (_buffer) nil)))
        (setq-local agent--before-exit '(:queue nil :state running))
        (cl-letf (((symbol-function 'agent--exit-session)
                   (lambda (_buffer) (setq ran t))))
          (should-not (agent--before-exit-transition buf 'step)))
        (should-not ran)
        (should (eq (plist-get agent--before-exit :state) 'running))))))

(ert-deftest agent-test-blocked-event-does-not-advance-before-exit-chain ()
  "Mark the session blocked without treating the event as skill completion."
  (let ((agent-backends nil)
        submitted)
    (with-temp-buffer
      (let ((buf (current-buffer))
            (queue '("second")))
        (apply #'agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :skill-command-prefix "/"
          :submit (lambda (command &optional _buffer)
                    (push command submitted))))
        (setq-local agent--before-exit
                    (list :queue queue :state 'running :timer nil))
        (agent-session-event buf 'blocked)
        (should (eq agent--session-state 'awaiting-input))
        (should (equal (plist-get agent--before-exit :queue) queue))
        (should (eq (plist-get agent--before-exit :state) 'running))
        (should-not submitted)))))

(ert-deftest agent-test-before-exit-step-advances-to-next-skill ()
  "Submit the next queued skill instead of exiting while the chain has more."
  (let ((agent-backends nil)
        (events nil)
        ran)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :skill-command-prefix "/"
          :submit (lambda (cmd &optional _buffer) (push cmd events))))
        (setq-local agent--before-exit
                    (list :queue (list (list "update-log" :args "--auto"))
                          :state 'running))
        (cl-letf (((symbol-function 'agent--exit-session)
                   (lambda (_buffer) (setq ran t))))
          (should (agent--before-exit-transition buf 'step)))
        (should (equal events '("/update-log --auto")))
        (should-not ran)
        (should-not (plist-get agent--before-exit :queue))
        (should (eq (plist-get agent--before-exit :state) 'running))))))

(ert-deftest agent-test-discover-all-skills-skips-non-invocable ()
  "Do not expose skills marked `user-invocable: false' interactively."
  (let* ((agent-backends nil)
         (root (make-temp-file "agent-skills" t)))
    (unwind-protect
        (progn
          (make-directory (expand-file-name "visible" root) t)
          (with-temp-file (expand-file-name "visible/SKILL.md" root)
            (insert "---\nname: visible\n---\n"))
          (make-directory (expand-file-name "hidden" root) t)
          (with-temp-file (expand-file-name "hidden/SKILL.md" root)
            (insert "---\nname: hidden\nuser-invocable: false\n---\n"))
          (apply #'agent-register-backend
           'one
           (agent-test--backend
            :skill-roots (lambda () (list (cons root 'file)))))
          (should (equal (mapcar (lambda (skill) (plist-get skill :name))
                                 (agent-discover-skills 'one))
                         '("hidden" "visible")))
          (should (equal (mapcar (lambda (skill) (plist-get skill :name))
                                 (agent--discover-all-skills))
                         '("visible"))))
      (delete-directory root t))))

;;;; Alerts

(ert-deftest agent-test-alert-sound-error-is-nonfatal ()
  "Report sound playback errors without signaling."
  (let ((sound-file (make-temp-file "agent-test-sound" nil ".aiff"))
        messages)
    (unwind-protect
        (let ((agent-alert-style 'sound)
              (agent-alert-sound sound-file))
          (cl-letf (((symbol-function 'play-sound-file)
                     (lambda (_file) (error "no sound support")))
                    ((symbol-function 'message)
                     (lambda (format-string &rest args)
                       (push (apply #'format format-string args) messages))))
            (should (condition-case nil
                        (progn
                          (agent--alert-sound)
                          t)
                      (error nil)))
            (should (member "AI alert sound failed: no sound support" messages))))
      (delete-file sound-file))))

(ert-deftest agent-test-alert-indicator-active ()
  "Return the bell-on icon when alerts are enabled."
  (let ((agent-alert-on-ready t))
    (should (equal (agent-alert-indicator) "🔔"))))

(ert-deftest agent-test-alert-indicator-inactive ()
  "Return the bell-off icon when alerts are disabled."
  (let ((agent-alert-on-ready nil))
    (should (equal (agent-alert-indicator) "🔕"))))

(ert-deftest agent-test-parse-skill-frontmatter-argument-metadata ()
  "Parse shared skill argument metadata from frontmatter."
  (let ((file (make-temp-file "skill" nil ".md")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "---\n")
            (insert "name: convert\n")
            (insert "description: Convert citations\n")
            (insert "argument-hint: FILE\n")
            (insert "argument-choices: a, b\n")
            (insert "argument-default: a\n")
            (insert "argument-multiple: false\n")
            (insert "user-invocable: false\n")
            (insert "model: gpt-5.5\n")
            (insert "---\n"))
          (let ((meta (agent-parse-skill-frontmatter file)))
            (should (equal (plist-get meta :name) "convert"))
            (should (equal (plist-get meta :argument-choices) '("a" "b")))
            (should (equal (plist-get meta :argument-default) "a"))
            (should-not (plist-get meta :argument-multiple))
            (should-not (plist-get meta :user-invocable))
            (should (equal (plist-get meta :model) "gpt-5.5"))))
      (delete-file file))))

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
        (apply #'agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))))
        (let* ((agent-account--starting '(one . "work"))
               (session (agent-session buf)))
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

(ert-deftest agent-test-session-round-trips-native-buffer-name ()
  "Round-trip a native session buffer name through the session struct."
  (let ((agent-backends nil))
    (with-temp-buffer
      (rename-buffer "*claude:~/repo/roundtrip-proj/:tests*" t)
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'claude-code
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))))
        (should (equal (agent-session-buffer-name (agent-session buf))
                       (buffer-name buf)))))))

(ert-deftest agent-test-session-prefers-explicitly-set-struct ()
  "Return the explicitly stored struct instead of re-deriving one."
  (with-temp-buffer
    (let ((session (agent-session-create :backend 'codex
                                         :directory "~/repos/proj/")))
      (agent--set-session (current-buffer) session)
      (should (eq (agent-session (current-buffer)) session)))))

(ert-deftest agent-test-session-buffer-name-normalizes-directory ()
  "Normalize raw session directories when deriving the buffer name."
  (let ((directory "/tmp/agent-test-dir"))
    (make-directory directory t)
    (unwind-protect
        (should (equal (agent-session-buffer-name
                        (agent-session-create :backend 'codex
                                              :directory directory))
                       (format "*codex:%s*"
                               (file-name-as-directory
                                (file-truename directory)))))
      (delete-directory directory))))

(ert-deftest agent-test-capture-session-replaces-stale-struct ()
  "Re-capture session identity over an earlier accountless struct."
  (let ((agent-backends nil))
    (with-temp-buffer
      (rename-buffer "*one:~/repo/recapture-proj/:tests*" t)
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
               'one
               (agent-test--backend
                :buffer-p (lambda (candidate) (eq candidate buf))))
        (agent--set-session
         buf
         (agent-session-create :backend 'one
                               :directory "~/repo/recapture-proj/"))
        (let* ((agent-account--starting '(one . "work"))
               (session (agent--capture-session buf)))
          (should (equal (agent-session-account session) "work"))
          (should (eq (buffer-local-value 'agent--session buf) session)))))))

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
                :buffer-p (lambda (candidate) (eq candidate buf))))
        (agent--set-session
         buf
         (agent-session-create :backend 'one
                               :account "struct-account"
                               :directory "~/repo/a/"))
        (should (equal (agent--session-group-key buf) "struct-account"))))))

;;;; Session id recording

(ert-deftest agent-test-note-session-id-records-and-fires-hook-once ()
  "Record a new id on the struct and fire the hook exactly once."
  (with-temp-buffer
    (agent--set-session (current-buffer)
                        (agent-session-create :backend 'claude-code
                                              :directory "~/project/"))
    (let* ((fired 0)
           (agent-session-id-functions
            (list (lambda (_buffer) (cl-incf fired)))))
      (agent--note-session-id (current-buffer) "abc-123")
      (agent--note-session-id (current-buffer) "abc-123")
      (should (equal (agent-session-id (agent-session)) "abc-123"))
      (should (= fired 1)))))

(ert-deftest agent-test-note-session-id-updates-on-change ()
  "Record a changed id, as on a Claude branch switch, and re-fire the hook."
  (with-temp-buffer
    (agent--set-session (current-buffer)
                        (agent-session-create :backend 'claude-code
                                              :directory "~/project/"))
    (let* ((fired 0)
           (agent-session-id-functions
            (list (lambda (_buffer) (cl-incf fired)))))
      (agent--note-session-id (current-buffer) "abc-123")
      (agent--note-session-id (current-buffer) "def-456")
      (should (equal (agent-session-id (agent-session)) "def-456"))
      (should (= fired 2)))))

(ert-deftest agent-test-note-session-id-ignores-nil-and-empty ()
  "Ignore nil and empty ids."
  (with-temp-buffer
    (agent--set-session (current-buffer)
                        (agent-session-create :backend 'claude-code
                                              :directory "~/project/"))
    (agent--note-session-id (current-buffer) nil)
    (agent--note-session-id (current-buffer) "")
    (should (null (agent-session-id (agent-session))))))

(ert-deftest agent-test-start-session-seeds-resume-id ()
  "Seed the session id on a non-fork resume and leave it nil on a fork."
  (let (started
        (agent-backends nil))
    (cl-letf (((symbol-function 'agent-account-resolve) (lambda (&rest _) nil))
              ((symbol-function 'agent-account-sync) #'ignore))
      (apply #'agent-register-backend
             'one
             (agent-test--backend
              :start-session (lambda (session &rest _)
                               (setq started session)
                               (current-buffer))))
      (agent-start-session (agent-session-create :backend 'one)
                           :resume-id "res-1")
      (should (equal (agent-session-id started) "res-1"))
      (agent-start-session (agent-session-create :backend 'one)
                           :resume-id "res-2" :fork t)
      (should (null (agent-session-id started))))))

(ert-deftest agent-test-history-errors-without-agent-log ()
  "Signal a clear `user-error' when the agent-log package is missing."
  (let ((real-require (symbol-function 'require)))
    (cl-letf (((symbol-function 'require)
               (lambda (feature &optional filename noerror)
                 (if (eq feature 'agent-log)
                     nil
                   (funcall real-require feature filename noerror)))))
      (should-error (agent-history) :type 'user-error))))

(ert-deftest agent-test-session-buffers-returns-backend-buffers ()
  "Return each backend's live buffers from `agent-session-buffers'."
  (with-temp-buffer
    (let ((buf (current-buffer))
          (agent-backends nil))
      (apply #'agent-register-backend
             'one
             (agent-test--backend
              :find-all-buffers (lambda () (list buf))))
      (should (equal (agent-session-buffers) (list buf))))))

;;;; Backend struct registry

(ert-deftest agent-test-register-backend-rejects-unknown-keyword ()
  "Signal an error when registering a backend with an unknown keyword."
  (let ((agent-backends nil))
    (should-error
     (apply #'agent-register-backend
      'bad
      (agent-test--backend :bogus-slot #'ignore)))))

(ert-deftest agent-test-registered-backend-is-struct ()
  "Store registrations as `agent-backend' structs keyed by name."
  (let ((agent-backends nil))
    (apply #'agent-register-backend 'one (agent-test--backend))
    (let ((struct (agent-backend 'one)))
      (should (agent-backend-p struct))
      (should (eq (agent-backend-name struct) 'one))
      (should (equal (agent-backend-label struct) "Test")))))

(ert-deftest agent-test-register-backend-accepts-keyword-spread ()
  "Register a backend from spread keyword arguments."
  (let ((agent-backends nil))
    (agent-register-backend
     'kwspread
     :buffer-p (lambda (_buffer) nil)
     :find-all-buffers (lambda () nil)
     :start-session #'ignore
     :label "Spread")
    (let ((struct (agent-backend 'kwspread)))
      (should (agent-backend-p struct))
      (should (eq (agent-backend-name struct) 'kwspread))
      (should (equal (agent-backend-label struct) "Spread"))
      (should (eq (agent-backend-start-session struct) #'ignore)))))

(ert-deftest agent-test-backend-lookup-returns-nil-when-unregistered ()
  "Return nil from `agent-backend' for unregistered backend names."
  (let ((agent-backends nil))
    (apply #'agent-register-backend 'one (agent-test--backend :program "one-cli"))
    (should (equal (agent-backend-program (agent-backend 'one)) "one-cli"))
    (should-not (agent-backend 'unregistered))))

(ert-deftest agent-test-detect-backend-resolves-with-struct-registry ()
  "Resolve a buffer's backend through struct-based registrations."
  (let ((agent-backends nil))
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))))
        (should (eq (agent--detect-backend buf) 'one))))))

(ert-deftest agent-test-backend-accepts-the-new-capability-slots ()
  "Register a backend that supplies every slot the unified menu dispatches on."
  (let ((agent-backends nil))
    (agent-register-backend
     'stub
     :buffer-p #'ignore
     :find-all-buffers #'ignore
     :start-session #'ignore
     :resume #'ignore
     :session-headers #'ignore
     :session-prompt #'ignore
     :exec-prompt #'ignore
     :prepare-fork #'ignore)
    (let ((struct (agent-backend 'stub)))
      (should (agent-backend-resume struct))
      (should (agent-backend-session-headers struct))
      (should (agent-backend-session-prompt struct))
      (should (agent-backend-exec-prompt struct))
      (should (agent-backend-prepare-fork struct)))))

(ert-deftest agent-test-backend-capability-slots-are-optional ()
  "A backend that supplies none of the new slots still registers."
  (let ((agent-backends nil))
    (agent-register-backend
     'stub :buffer-p #'ignore :find-all-buffers #'ignore
     :start-session #'ignore)
    (let ((struct (agent-backend 'stub)))
      (should-not (agent-backend-resume struct))
      (should-not (agent-backend-session-headers struct)))))

(ert-deftest agent-test-start-session-dispatches-to-backend ()
  "Dispatch session starts to the backend's start-session function."
  (let* ((agent-backends nil)
         (buffer (generate-new-buffer " *agent-test-session*"))
         (session (agent-session-create :backend 'one :directory "/tmp/"))
         captured)
    (unwind-protect
        (progn
          (apply #'agent-register-backend
           'one
           (agent-test--backend
            :start-session (lambda (sess &rest options)
                             (setq captured (cons sess options))
                             buffer)))
          (should (eq (agent-start-session session :resume-id "abc") buffer))
          (should (eq (car captured) session))
          (should (equal (plist-get (cdr captured) :resume-id) "abc")))
      (kill-buffer buffer))))

(ert-deftest agent-test-start-session-rejects-unsupported-backend ()
  "Signal a user error for backends without start-session support."
  (let ((agent-backends nil)
        (session (agent-session-create :backend 'codex :directory "/tmp/")))
    (should-error (agent-start-session session) :type 'user-error)))

(ert-deftest agent-test-start-session-binds-starting-account ()
  "Bind `agent-account--starting' and sync before the backend start call."
  (let ((agent-backends nil)
        (events nil))
    (apply #'agent-register-backend
     'one
     (agent-test--backend
      :start-session (lambda (_session &rest _)
                       (push (cons 'start agent-account--starting) events))))
    (cl-letf (((symbol-function 'agent-account-sync)
               (lambda (backend account)
                 (push (cons 'sync (cons backend account)) events))))
      (agent-start-session
       (agent-session-create :backend 'one :account "work")))
    (should (equal (nreverse events)
                   '((sync . (one . "work"))
                     (start . (one . "work")))))))

(ert-deftest agent-test-start-session-backfills-account-from-current ()
  "Fill an accountless session's account slot from the active account."
  (let ((agent-backends nil)
        (agent-account--current (make-hash-table :test #'eq))
        (events nil)
        captured-account captured-starting)
    (puthash 'one "work" agent-account--current)
    (apply #'agent-register-backend
     'one
     (agent-test--backend
      :accounts '(("work" . "/tmp/agent-test-work/"))
      :start-session (lambda (session &rest _)
                       (setq captured-account (agent-session-account session)
                             captured-starting agent-account--starting))))
    (cl-letf (((symbol-function 'agent-account-sync)
               (lambda (backend account)
                 (push (cons backend account) events))))
      (let ((session (agent-session-create :backend 'one)))
        (agent-start-session session)
        (should (equal (agent-session-account session) "work"))))
    (should (equal captured-account "work"))
    (should (equal captured-starting '(one . "work")))
    (should (equal events '((one . "work"))))))

(ert-deftest agent-test-account-sync-reads-backend-account-slots ()
  "Sync shared symlinks through the real backend registry slots."
  (let* ((root (make-temp-file "agent-account-sync" t))
         (canonical (expand-file-name "canonical/" root))
         (home (expand-file-name "home/" root))
         (agent-backends nil)
         (inits nil))
    (unwind-protect
        (progn
          (make-directory canonical t)
          (with-temp-file (expand-file-name "settings.json" canonical)
            (insert "{\"shared\": true}"))
          (apply #'agent-register-backend
           'throwaway
           (agent-test--backend
            :accounts `(("work" . ,home))
            :canonical-home canonical
            :shared-config-items '("settings.json")
            :account-init (lambda (account) (push account inits))))
          (agent-account-sync 'throwaway "work")
          (let ((link (expand-file-name "settings.json" home)))
            (should (file-symlink-p link))
            (should (equal (file-truename link)
                           (file-truename
                            (expand-file-name "settings.json" canonical)))))
          (should (equal inits '("work"))))
      (delete-directory root t))))

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

(ert-deftest agent-test-notify-ready-dispatches-backend-notify ()
  "Dispatch the ready alert through the backend's notify slot."
  (let ((agent-backends nil)
        notified fallback)
    (with-temp-buffer
      (rename-buffer "*one:~/repo/project/:default*" t)
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :notify (lambda (title message)
                    (setq notified (list title message)))))
        (cl-letf (((symbol-function 'agent-notify)
                   (lambda (&rest args) (setq fallback args))))
          (agent--session-notify-ready buf))
        (should (equal notified
                       '("Test ready"
                         "project: waiting for your response")))
        (should-not fallback)))))

(ert-deftest agent-test-notify-ready-falls-back-to-agent-notify ()
  "Fall back to `agent-notify' when the backend lacks a notify slot."
  (let ((agent-backends nil)
        notified)
    (with-temp-buffer
      (rename-buffer "*one:~/repo/project/:default*" t)
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))))
        (cl-letf (((symbol-function 'agent-notify)
                   (lambda (title message)
                     (setq notified (list title message)))))
          (agent--session-notify-ready buf))
        (should (equal notified
                       '("Test ready"
                         "project: waiting for your response")))))))

(ert-deftest agent-test-notify-ready-prefers-struct-name ()
  "Derive the ready-alert project name from the session struct.
A uniquified buffer name defeats buffer-name parsing, but the
stored struct still yields the project name."
  (let ((agent-backends nil)
        notified)
    (with-temp-buffer
      (rename-buffer "*claude:~/x/:a*<2>" t)
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))))
        (setq-local agent--session
                    (agent-session-create :backend 'one
                                          :directory "~/repo/project/"
                                          :instance "a"))
        (cl-letf (((symbol-function 'agent-notify)
                   (lambda (title message)
                     (setq notified (list title message)))))
          (agent--session-notify-ready buf))
        (should (equal notified
                       '("Test ready"
                         "project: waiting for your response")))))))

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
                ((symbol-function 'agent--before-exit-transition)
                 (lambda (_buffer _event) t)))
        (agent-session-event (current-buffer) 'idle-prompt))
      (should (eq agent--session-state 'awaiting-input))
      (should-not notified))))

(ert-deftest agent-test-session-event-submit-when-busy-is-noop ()
  "Ignore submit events when the session is already busy.
Backend submission hooks can multi-fire and fire on no-turn
submissions; a redundant submit must not refresh the transition
timestamp."
  (with-temp-buffer
    (setq-local agent--session-state 'busy)
    (agent-session-event (current-buffer) 'submit)
    (should (eq agent--session-state 'busy))
    (should-not agent--session-state-changed-at)))

;;;; Core send wrappers

(ert-deftest agent-test-send-string-emits-submit-and-dispatches ()
  "Emit a submit event, then dispatch to the backend send slot."
  (let ((agent-backends nil)
        events)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :send-string (lambda (cmd &optional buffer)
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
        (apply #'agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :submit (lambda (cmd &optional _buffer)
                            (push (list 'submit cmd) events))
          :send-string (lambda (cmd &optional _buffer)
                          (push (list 'command cmd) events))))
        (agent-submit "/retro" buf)
        (should (equal events '((submit "/retro"))))))))

(ert-deftest agent-test-submit-falls-back-to-send-and-return ()
  "Compose send-command and send-return when no atomic submit exists."
  (let ((agent-backends nil)
        events)
    (with-temp-buffer
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))
          :send-string (lambda (cmd &optional _buffer)
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
        (apply #'agent-register-backend
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
        (apply #'agent-register-backend
         'one
         (agent-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))))
        (should-error (agent-send-string "hello" buf) :type 'user-error)))))

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

(ert-deftest agent-test-menu-backend-children ()
  "Backend menu sections are built from registry slots."
  (require 'agent-claude)
  (require 'agent-codex)
  (let ((children (agent-menu--backend-children nil)))
    (should children)
    (should (= (length children) 2))))

(ert-deftest agent-test-menu-slack-command-is-autoloaded ()
  "Source-loaded core menu references an available Slack command."
  (should (fboundp 'agent-act-on-slack-message)))

(ert-deftest agent-test-main-file-declares-backend-dependencies ()
  "Package metadata declares the backends the split modules hard-require.
Elpaca byte-compiles the package with only the main file's declared
dependencies on the load path, so an undeclared backend silently fails
byte-compilation of the module that requires it."
  (let ((requires (with-temp-buffer
                    (insert-file-contents (locate-library "agent.el" t))
                    (require 'lisp-mnt)
                    (lm-header "package-requires"))))
    (should requires)
    (dolist (backend '(claude-code codex))
      (should (assq backend (car (read-from-string requires)))))))

;;;; Branch navigation

(defun agent-test--branch-sessions (specs)
  "Return a session hash table from SPECS, a list of (ID PARENT TIMESTAMP)."
  (let ((table (make-hash-table :test #'equal)))
    (dolist (spec specs table)
      (puthash (nth 0 spec)
               (list :session-id (nth 0 spec)
                     :forked-from (nth 1 spec)
                     :timestamp (nth 2 spec))
               table))))

(ert-deftest agent-test-branch-root-follows-the-fork-chain ()
  "Walk up the fork chain to the session that has no recorded parent."
  (let ((sessions (agent-test--branch-sessions
                   '(("a" nil "2026-08-01T10:00:00Z")
                     ("b" "a" "2026-08-01T11:00:00Z")
                     ("c" "b" "2026-08-01T12:00:00Z")))))
    (should (equal (agent--branch-root "c" sessions) "a"))
    (should (equal (agent--branch-root "a" sessions) "a"))))

(ert-deftest agent-test-branch-root-stops-on-an-unknown-parent ()
  "Treat a parent outside the scanned set as the top of the chain."
  (let ((sessions (agent-test--branch-sessions '(("b" "missing" nil)))))
    (should (equal (agent--branch-root "b" sessions) "b"))))

(ert-deftest agent-test-branch-children-are-sorted-by-timestamp ()
  "Order each parent's children oldest first."
  (let* ((sessions (agent-test--branch-sessions
                    '(("a" nil "2026-08-01T10:00:00Z")
                      ("c" "a" "2026-08-01T12:00:00Z")
                      ("b" "a" "2026-08-01T11:00:00Z"))))
         (map (agent--branch-children-map sessions)))
    (should (equal (gethash "a" map) '("b" "c")))))

(ert-deftest agent-test-branch-tree-members-collect-every-descendant ()
  "Collect the root and everything reachable from it."
  (let* ((sessions (agent-test--branch-sessions
                    '(("a" nil nil) ("b" "a" nil) ("c" "b" nil))))
         (members (agent--branch-tree-members
                   "a" (agent--branch-children-map sessions))))
    (should (= (hash-table-count members) 3))
    (should (gethash "c" members))))

(ert-deftest agent-test-branch-format-tree-marks-the-current-session ()
  "Draw the tree with connectors and a marker on the current session."
  (let* ((sessions (make-hash-table :test #'equal)))
    (puthash "a" '(:session-id "a" :forked-from nil :first-prompt "root"
                   :timestamp nil)
             sessions)
    (puthash "b" '(:session-id "b" :forked-from "a" :first-prompt "child"
                   :timestamp nil)
             sessions)
    (let* ((tree (agent--branch-format-tree
                  "a" sessions (agent--branch-children-map sessions) "b")))
      (should (equal (mapcar #'cdr tree) '("a" "b")))
      (should (string-match-p "\\`root" (car (nth 0 tree))))
      (should (string-match-p "└─ child" (car (nth 1 tree))))
      (should (string-suffix-p " *" (car (nth 1 tree)))))))

(ert-deftest agent-test-branch-enrich-sessions-uses-the-backend-slot ()
  "Enrich only the tree members, through the backend's session-prompt slot."
  (let ((agent-backends nil)
        (headers (agent-test--branch-sessions '(("a" nil nil) ("b" "a" nil))))
        (members (make-hash-table :test #'equal)))
    (puthash "a" t members)
    (agent-register-backend
     'stub :buffer-p #'ignore :find-all-buffers #'ignore
     :start-session #'ignore
     :session-prompt (lambda (header)
                       (append (list :first-prompt "enriched") header)))
    (let ((enriched (agent--branch-enrich-sessions 'stub headers members)))
      (should (= (hash-table-count enriched) 1))
      (should (equal (plist-get (gethash "a" enriched) :first-prompt)
                     "enriched"))
      (should (equal (plist-get (gethash "a" enriched) :session-id) "a")))))

(provide 'agent-test)
;;; agent-test.el ends here
