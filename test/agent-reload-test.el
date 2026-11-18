;;; agent-reload-test.el --- Tests for loading the package again -*- lexical-binding: t -*-

;; What a running Emacs is left with once the package has been updated
;; and its files loaded again.  A mode's function runs only when the mode
;; is toggled, so what a mode installed used to stay what the version
;; that turned it on installed, however often its file was loaded.
;;
;; Loading every library again changes the Emacs that does it for good,
;; so the scenario runs once, in a batch Emacs of its own, and each test
;; here checks one part of what that Emacs reports.

;;; Code:

(require 'ert)
(require 'agent-test-helper
         (expand-file-name "agent-test-helper"
                           (file-name-directory (or load-file-name buffer-file-name))))
(require 'cl-lib)
(require 'seq)

;;;; What the modes install

(defconst agent-reload-test--hooks
  '((claude-code-event-hook agent-claude--handle-notification)
    (claude-code-event-hook agent-claude--handle-stop)
    (claude-code-event-hook agent-claude--handle-session-state)
    (claude-code-event-hook agent-claude--refresh-status-on-event)
    (kill-buffer-query-functions agent-protect-buffer)
    (claude-code-start-hook agent-setup-kill-on-exit)
    (claude-code-start-hook agent-claude--capture-status-uuid)
    (claude-code-start-hook agent-claude--capture-monet-key)
    (claude-code-start-hook agent-claude-start-status-polling)
    (claude-code-start-hook agent-claude-set-modeline)
    (claude-code-start-hook agent--refresh-display-names)
    (claude-code-start-hook agent-disable-scrollback-truncation)
    (claude-code-start-hook agent-setup-scroll-keys)
    (claude-code-start-hook agent-setup-snippet-keys)
    (claude-code-start-hook agent-setup-session-keys)
    (claude-code-start-hook agent--assign-session-key)
    (claude-code-start-hook agent-claude--register-session-teardown)
    (doom-modeline-mode-hook agent-claude--reapply-modelines)
    (agent-session-derived-status-functions agent-claude--derived-status)
    (claude-code-process-environment-functions agent-claude-account-env)
    (claude-code-process-environment-functions agent-claude--status-uuid-env)
    (claude-code-process-environment-functions agent-claude--server-env)
    (claude-code-process-environment-functions
     agent-claude--sync-theme-before-start)
    (claude-code-process-environment-functions
     agent-claude--parent-session-env)
    (agent-session-event-functions agent-auto--on-event)
    (agent-session-id-functions agent-auto--on-id)
    (agent-delivery-functions agent-auto--record-delivery)
    (agent-recorded-session-functions agent-auto--recorded-session)
    (agent-session-state-change-functions agent-auto--schedule-marks)
    (agent-session-id-functions agent-auto--schedule-marks)
    (kill-buffer-hook agent-auto--session-killed)
    (org-mode-hook agent-auto--schedule-marks)
    (org-agenda-finalize-hook agent-auto--mark-agenda))
  "What the global modes put on hooks, each a list (HOOK FUNCTION).
The functions are on the global value of each hook.")

(defconst agent-reload-test--advice
  '((claude-code--start agent-claude--start-with-session-settings)
    (claude-code-handle-hook agent-claude--route-hook-to-current-name)
    (claude-code--eat-send-return agent-claude--note-user-submission)
    (claude-code--vterm-send-return agent-claude--note-user-submission)
    (claude-code--do-send-command agent-claude--note-submission)
    (claude-code-send-escape agent-claude--send-escape-in-current-buffer)
    (claude-code--eat-synchronize-scroll agent-claude--eat-synchronize-scroll)
    (monet-start-server-in-directory agent-claude--monet-cleanup-before-start)
    (monet--on-close-server agent-claude--monet-close-server-on-disconnect)
    (monet--display-diff-buffer agent-claude--display-diff-buffer))
  "The advice of the global modes, each a list (SYMBOL FUNCTION).
FUNCTION advises the function of SYMBOL.")

(defconst agent-reload-test--inherited-variables
  '(agent-auto--link agent-auto--unattended)
  "What the modes add to `agent-session-inherited-variables'.")

(defconst agent-reload-test--mode-timers
  '(agent-claude--monet-gc-orphaned-servers agent-auto--tick)
  "The functions of the timers the modes run.")

(defconst agent-reload-test--load-timers
  '(agent--refresh-derived-statuses agent--refresh-session-switcher)
  "The functions of the timers the package runs once it is loaded.")

(defconst agent-reload-test--user-maps
  '(agent-session-keys-mode-map)
  "The keymaps of the package in which the scenario binds a key of its own.")

(defconst agent-reload-test--user-key "C-c z"
  "The key the scenario binds in each of `agent-reload-test--user-maps'.")

;;;; The scenario

(defconst agent-reload-test--file (or load-file-name buffer-file-name)
  "This file, which the batch Emacs loads to run the scenario.")

(defvar agent-reload-test--events nil
  "The session events and state changes the scenario saw, newest first.")

(defvar agent-reload-test--report nil
  "What the scenario reported, once it has run.")

(defun agent-reload-test--report ()
  "Return what the scenario reports, running it the first time.
It runs in a batch Emacs of its own, since it loads every library of the
package again and turns every mode on."
  (or agent-reload-test--report
      (setq agent-reload-test--report
            (agent-test-helper-batch-eval
             `(progn (load ,agent-reload-test--file nil t)
                     (agent-reload-test-scenario))))))

(defun agent-reload-test-scenario ()
  "Turn every mode on, load every library again twice, and report.
Call this only in an Emacs started for it, which it changes for good.

Before the first load the Emacs is made to look like one that turned the
modes on with an older version of the package, which installed none of
what `agent-reload-test--hooks' and the lists after it name.  Before the
second it is given a second timer for each mode timer, as a version that
did not cancel the first would have left.

Return a plist.  `:first' and `:second' are what
`agent-reload-test--installed' found after each load, and `:off' what it
found once the modes were turned off again.  `:swept' is non-nil when
turning the modes on deleted the stale files that were there, and
`:files-kept' when the loads left every file of the scenario as it was,
the stale ones planted after that included.  `:server-kept' is non-nil
when the remote-control server is the process it was.  `:saved' lists
the notification functions the two backend modes saved, and `:restored'
the ones in place once the modes were off.  `:sessions' is a cons of what
`agent-reload-test--session-states' found before the loads and after
them, and `:events' lists the session events and state changes seen."
  (let ((directory (file-name-as-directory (make-temp-file "agent-reload" t))))
    (unwind-protect
        (agent-reload-test--run directory)
      (delete-directory directory t))))

(defun agent-reload-test--run (directory)
  "Run the scenario with its files under DIRECTORY and return its report."
  (agent-reload-test--prepare directory)
  (let* ((stale (agent-reload-test--plant-stale-files))
         (swept (progn (agent-reload-test--turn-modes-on)
                       (not (seq-some #'file-exists-p stale))))
         (files (progn (agent-reload-test--plant-stale-files)
                       (agent-reload-test--files directory)))
         (server agent-remote--server)
         (sessions (agent-reload-test--make-sessions))
         (states (agent-reload-test--session-states sessions))
         (first (agent-reload-test--load-after #'agent-reload-test--make-older))
         (second (agent-reload-test--load-after
                  #'agent-reload-test--add-second-timers))
         (report
          (list :swept swept :first first :second second
                :files-kept (equal files (agent-reload-test--files directory))
                :server-kept (and (eq server agent-remote--server)
                                  (process-live-p server)
                                  t)
                :saved (list agent-claude--saved-notification-function
                             agent-codex--saved-notification-function)
                :sessions (cons states
                                (agent-reload-test--session-states sessions))
                :events agent-reload-test--events)))
    (agent-reload-test--turn-modes-off)
    (append report
            (list :off (agent-reload-test--installed)
                  :restored (list claude-code-notification-function
                                  codex-notification-function)))))

(defun agent-reload-test--load-after (change)
  "Call CHANGE, load every library again, and return what is installed.
The value is that of `agent-reload-test--installed'."
  (funcall change)
  (dolist (file (agent-reload-test--libraries))
    (load file nil t))
  (agent-reload-test--installed))

(defun agent-reload-test--libraries ()
  "Return the source file of every library of the package, `agent.el' first.
They are the files beside the directory of this one.  The library that
needs `doom-modeline' is one of them only once that package is loaded."
  (let* ((directory (expand-file-name
                     ".." (file-name-directory agent-reload-test--file)))
         (main (expand-file-name "agent.el" directory))
         (skipped (cons main
                        (unless (featurep 'doom-modeline)
                          (list (expand-file-name "agent-doom-modeline.el"
                                                  directory))))))
    (cons main
          (seq-difference (directory-files directory t "\\`agent.*\\.el\\'")
                          skipped))))

(defun agent-reload-test--prepare (directory)
  "Load the package and keep what its modes do inside DIRECTORY.
Nothing is started for real: usage is never fetched, the remote-control
server listens on a free port of this machine only, and no timer comes
due while the scenario runs.  The user's notification functions and a
key of the user's in each of `agent-reload-test--user-maps' are in
place, as an init file would have left them."
  (require 'doom-modeline nil t)
  (dolist (file (agent-reload-test--libraries))
    (require (intern (file-name-base file)) file))
  (unless (require 'monet nil t)
    (provide 'monet))
  (advice-add 'agent-usage-fetch :override #'ignore)
  (advice-add 'agent-remote--warn-about-app-nap :override #'ignore)
  (setq agent-claude-status-directory (expand-file-name "status/" directory)
        agent-claude-session-settings-directory
        (expand-file-name "settings/" directory)
        claude-code-notification-function
        #'agent-reload-test-claude-notification
        codex-notification-function #'agent-reload-test-codex-notification
        agent-tab-bar-refresh-interval 3600
        agent-auto-interval 3600
        agent-remote-host "127.0.0.1"
        agent-remote-listen-address "127.0.0.1"
        agent-remote-allowed-networks '("127.0.0.0/8")
        agent-remote-port t)
  (dolist (map agent-reload-test--user-maps)
    (keymap-set (symbol-value map) agent-reload-test--user-key
                #'agent-reload-test-user-command)))

(defun agent-reload-test-claude-notification (&rest _)
  "Stand in for the user's own `claude-code-notification-function'."
  nil)

(defun agent-reload-test-codex-notification (&rest _)
  "Stand in for the user's own `codex-notification-function'."
  nil)

(defun agent-reload-test--plant-stale-files ()
  "Write the files that turning `agent-claude-mode' on deletes; return them.
They are a status file and a session settings file last changed a month
ago."
  (let ((files (list (expand-file-name "stale.json"
                                       agent-claude-status-directory)
                     (expand-file-name
                      "claude-session-settings-0123abcd.json"
                      agent-claude-session-settings-directory))))
    (dolist (file files)
      (make-directory (file-name-directory file) t)
      (write-region "{}" nil file nil 'silent)
      (set-file-times file (time-subtract nil (days-to-time 30))))
    files))

(defun agent-reload-test--turn-modes-on ()
  "Turn every global mode of the package on.
`agent-auto-mode' is given the ripgrep it refuses to start without."
  (agent-claude-mode 1)
  (agent-codex-mode 1)
  (agent-tab-bar-mode 1)
  (agent-remote-mode 1)
  (cl-letf (((symbol-function 'executable-find)
             (lambda (command &rest _) command)))
    (agent-auto-mode 1)))

(defun agent-reload-test--turn-modes-off ()
  "Turn every global mode of the package off."
  (agent-auto-mode -1)
  (agent-remote-mode -1)
  (agent-tab-bar-mode -1)
  (agent-codex-mode -1)
  (agent-claude-mode -1))

(defun agent-reload-test--files (directory)
  "Return the name, size and modification time of each file under DIRECTORY."
  (mapcar (lambda (file)
            (let ((attributes (file-attributes file)))
              (list file
                    (file-attribute-size attributes)
                    (float-time
                     (file-attribute-modification-time attributes)))))
          (directory-files-recursively directory "" t)))

(defun agent-reload-test--make-sessions ()
  "Return buffers that pass for sessions, one busy and one waiting each.
They are named as Claude and Codex sessions are and hold the state a
session event would have left; nothing runs in them.  Every session
event and state change from now on is recorded in
`agent-reload-test--events'."
  (let ((sessions
         (mapcar (pcase-lambda (`(,name . ,state))
                   (with-current-buffer (generate-new-buffer name)
                     (setq agent--session-state state
                           agent--session-state-changed-at (float-time))
                     (current-buffer)))
                 '(("*claude:/agent-reload/busy/:default*" . busy)
                   ("*claude:/agent-reload/waiting/:default*" . awaiting-input)
                   ("*codex:/agent-reload/busy/:default*" . busy)
                   ("*codex:/agent-reload/waiting/:default*"
                    . awaiting-input)))))
    (add-hook 'agent-session-event-functions
              (lambda (_buffer event) (push event agent-reload-test--events)))
    (add-hook 'agent-session-state-change-functions
              (lambda (_buffer state) (push state agent-reload-test--events)))
    sessions))

(defun agent-reload-test--session-states (sessions)
  "Return how each of SESSIONS is judged, and the session variables it holds.
Each element is a list of the state the switcher shows for the buffer
and of every buffer-local variable of the package in it, with its value
printed."
  (mapcar (lambda (buffer)
            (list (agent-session-display-state buffer)
                  (sort (mapcar #'prin1-to-string
                                (seq-filter
                                 (lambda (variable)
                                   (string-prefix-p
                                    "agent" (symbol-name (car-safe variable))))
                                 (buffer-local-variables buffer)))
                        #'string<)))
          sessions))

(defun agent-reload-test-user-command ()
  "Stand in for a command the user bound in a keymap of the package."
  (interactive))

(defun agent-reload-test--make-older ()
  "Leave this Emacs as an older version of the package would have.
That version turned the modes on and installed none of what the lists
at the top of this file name."
  (dolist (entry agent-reload-test--hooks)
    (remove-hook (car entry) (cadr entry)))
  (dolist (entry agent-reload-test--advice)
    (advice-remove (car entry) (cadr entry)))
  (setq agent-session-inherited-variables
        (seq-difference agent-session-inherited-variables
                        agent-reload-test--inherited-variables))
  (dolist (function agent-reload-test--mode-timers)
    (cancel-function-timers function)))

(defun agent-reload-test--add-second-timers ()
  "Start a second timer for each function the modes run on a timer."
  (dolist (function agent-reload-test--mode-timers)
    (run-with-timer 3600 3600 function)))

(defun agent-reload-test--installed ()
  "Return how often each thing the package installs is installed now.
The value is a plist of alists, each from an entry of the list of the
same name at the top of this file to a count: `:hooks' how often the
function is on its hook, `:advice' how often it advises the function of
the symbol, `:inherited' how often the variable is in
`agent-session-inherited-variables', `:mode-timers' and `:load-timers'
how many timers run the function.  `:user-keys' is an alist from each
keymap to the command `agent-reload-test--user-key' runs in it."
  (list :hooks
        (mapcar (lambda (entry)
                  (cons entry (agent-reload-test--count
                               (cadr entry)
                               (and (default-boundp (car entry))
                                    (default-value (car entry))))))
                agent-reload-test--hooks)
        :advice
        (mapcar (lambda (entry)
                  (cons entry (agent-reload-test--advice-count
                               (car entry) (cadr entry))))
                agent-reload-test--advice)
        :inherited
        (mapcar (lambda (variable)
                  (cons variable (agent-reload-test--count
                                  variable agent-session-inherited-variables)))
                agent-reload-test--inherited-variables)
        :mode-timers
        (mapcar #'agent-reload-test--timer-count agent-reload-test--mode-timers)
        :load-timers
        (mapcar #'agent-reload-test--timer-count agent-reload-test--load-timers)
        :user-keys
        (mapcar (lambda (map)
                  (cons map (agent-reload-test--binding
                             map agent-reload-test--user-key)))
                agent-reload-test--user-maps)))

(defun agent-reload-test--count (element list)
  "Return how often ELEMENT is in LIST, which need not be a list."
  (seq-count (lambda (other) (eq other element))
             (if (listp list) list (list list))))

(defun agent-reload-test--advice-count (symbol function)
  "Return how often FUNCTION advises the function of SYMBOL."
  (let ((count 0))
    (advice-mapc (lambda (advice _properties)
                   (when (eq advice function)
                     (setq count (1+ count))))
                 symbol)
    count))

(defun agent-reload-test--timer-count (function)
  "Return a cons of FUNCTION and the number of timers that run it."
  (cons function
        (seq-count (lambda (timer) (eq (timer--function timer) function))
                   (append timer-list timer-idle-list))))

(defun agent-reload-test--binding (map key)
  "Return the command KEY runs in the keymap that is the value of MAP.
Return `no-command' when it runs none."
  (let ((binding (lookup-key (symbol-value map) (key-parse key))))
    (if (and binding (symbolp binding)) binding 'no-command)))

;;;; Tests

(defun agent-reload-test--should-all-be (count alist)
  "Fail unless every entry of ALIST has COUNT for its value.
ALIST must have entries, so that a report that lacks them fails too."
  (should alist)
  (dolist (entry alist)
    (should (equal entry (cons (car entry) count)))))

(ert-deftest agent-reload-test-hooks-are-installed-once ()
  "Find each hook function of the modes on its hook once after each load.
A function the version that turned the modes on did not install is there
after the first load, and none is there twice after the second."
  (dolist (load '(:first :second))
    (let ((installed (plist-get (agent-reload-test--report) load)))
      (agent-reload-test--should-all-be 1 (plist-get installed :hooks))
      (agent-reload-test--should-all-be 1 (plist-get installed :inherited)))))

(ert-deftest agent-reload-test-advice-is-installed-once ()
  "Find each advice of the modes on its function once after each load.
An advice the version that turned the modes on did not install is there
after the first load, and none is there twice after the second."
  (dolist (load '(:first :second))
    (agent-reload-test--should-all-be
     1 (plist-get (plist-get (agent-reload-test--report) load) :advice))))

(ert-deftest agent-reload-test-one-timer-runs-each-function ()
  "Find one timer for each function the package runs on a timer.
A timer the version that turned the modes on did not start is running
after the first load, and a second timer for the same function is gone
after the second."
  (dolist (load '(:first :second))
    (let ((installed (plist-get (agent-reload-test--report) load)))
      (agent-reload-test--should-all-be 1 (plist-get installed :mode-timers))
      (agent-reload-test--should-all-be 1 (plist-get installed :load-timers)))))

(ert-deftest agent-reload-test-user-keys-are-kept ()
  "Find the keys the user bound in the keymaps still bound after each load."
  (dolist (load '(:first :second))
    (agent-reload-test--should-all-be
     'agent-reload-test-user-command
     (plist-get (plist-get (agent-reload-test--report) load) :user-keys))))

(ert-deftest agent-reload-test-what-is-done-once-is-not-done-again ()
  "Leave alone what a mode does once when it is turned on.
The stale files a mode deletes when it is turned on are deleted then and
not by loading its file again, which touches no file at all; the server
is not started again; and the notification functions the backend modes
saved are still the user's, not the ones the modes put in their place."
  (let ((report (agent-reload-test--report)))
    (should (plist-get report :swept))
    (should (plist-get report :files-kept))
    (should (plist-get report :server-kept))
    (should (equal (plist-get report :saved)
                   '(agent-reload-test-claude-notification
                     agent-reload-test-codex-notification)))))

(ert-deftest agent-reload-test-sessions-are-left-alone ()
  "Judge each session after the loads as it was judged before them.
No session event or state change is issued, and the session variables
of each buffer hold what they held."
  (let* ((report (agent-reload-test--report))
         (states (plist-get report :sessions)))
    (should (equal (mapcar #'car (car states)) '(busy waiting busy waiting)))
    (should (equal (cdr states) (car states)))
    (should-not (plist-get report :events))))

(ert-deftest agent-reload-test-turning-the-modes-off-removes-everything ()
  "Turn the modes off after the loads and find nothing of theirs left.
Every hook function, advice and timer of the modes is gone, and the
notification functions are the user's again.  The timers the package
runs whenever it is loaded stay."
  (let* ((report (agent-reload-test--report))
         (installed (plist-get report :off)))
    (agent-reload-test--should-all-be 0 (plist-get installed :hooks))
    (agent-reload-test--should-all-be 0 (plist-get installed :advice))
    (agent-reload-test--should-all-be 0 (plist-get installed :inherited))
    (agent-reload-test--should-all-be 0 (plist-get installed :mode-timers))
    (agent-reload-test--should-all-be 1 (plist-get installed :load-timers))
    (should (equal (plist-get report :restored)
                   '(agent-reload-test-claude-notification
                     agent-reload-test-codex-notification)))))

(provide 'agent-reload-test)

;;; agent-reload-test.el ends here
