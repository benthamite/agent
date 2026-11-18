;;; agent-reload-test.el --- Tests for loading the package again -*- lexical-binding: t -*-

;; What a running Emacs is left with once the package has been updated
;; and its files loaded again.  A mode's function runs only when the mode
;; is toggled, and a `defvar' keeps the keymap its first load built, so
;; what a mode installed and the keys of a keymap used to stay those of
;; the version loaded first, however often the files were loaded.
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
    (codex-event-hook agent-codex--handle-notification)
    (codex-app-server-turn-completed-hook
     agent-codex--handle-app-server-turn-completed)
    (codex-app-server-notification-functions agent-codex--follow-notification)
    (agent-session-derived-status-functions agent-codex--derived-status)
    (codex-start-hook agent-setup-kill-on-exit)
    (codex-start-hook agent-codex-set-modeline)
    (codex-start-hook agent--refresh-display-names)
    (codex-start-hook agent-disable-scrollback-truncation)
    (codex-start-hook agent-setup-scroll-keys)
    (codex-start-hook agent-setup-snippet-keys)
    (codex-start-hook agent-setup-session-keys)
    (codex-start-hook agent-fix-rendering)
    (codex-start-hook agent--assign-session-key)
    (codex-start-hook agent-codex--record-start-time)
    (codex-start-hook agent-codex--register-session-teardown)
    (doom-modeline-mode-hook agent-codex--reapply-modelines)
    (codex-process-environment-functions agent-codex-account-env)
    (codex-process-environment-functions agent-codex--sync-theme-before-start)
    (codex-command-submitted-hook agent-codex--note-submission)
    (window-selection-change-functions agent--tab-bar-selection-changed)
    (window-buffer-change-functions agent--tab-bar-selection-changed)
    (agent-session-event-functions agent-auto--on-event)
    (agent-session-id-functions agent-auto--on-id)
    (agent-before-delivery-functions agent-auto--confirm-delivery)
    (agent-delivery-functions agent-auto--record-delivery)
    (agent-recorded-session-functions agent-auto--recorded-session)
    (agent-session-state-change-functions agent-auto--schedule-marks)
    (agent-session-id-functions agent-auto--schedule-marks)
    (agent-before-exit-step-functions agent-auto--handover-step)
    (after-save-hook agent-auto--after-save)
    (kill-buffer-hook agent-auto--session-killed)
    (org-mode-hook agent-auto--schedule-marks)
    (org-agenda-finalize-hook agent-auto--mark-agenda))
  "What the global modes put on hooks, each a list (HOOK FUNCTION).
The functions are on the global value of each hook.")

(defconst agent-reload-test--local-hooks
  '((after-change-functions agent-capture--after-change))
  "What `agent-prompt-capture-mode' puts on hooks, as (HOOK FUNCTION).
The functions are on the value each hook has in a buffer of the mode.")

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
    (monet--display-diff-buffer agent-claude--display-diff-buffer)
    (codex--do-send-command agent-codex--intercept-exit)
    (codex--dispatch-hook-message agent-codex--route-hook-to-current-name)
    (codex--send-command-to-buffer agent-codex--intercept-exit-to-buffer)
    (scroll-down-command agent--scroll-down-command)
    (scroll-up-command agent--scroll-up-command))
  "The advice of the global modes, each a list (SYMBOL FUNCTION).
FUNCTION advises the function of SYMBOL.")

(defconst agent-reload-test--inherited-variables
  '(agent-auto--link agent-auto--unattended)
  "What the modes add to `agent-session-inherited-variables'.")

(defconst agent-reload-test--mode-timers
  '(agent-claude--monet-gc-orphaned-servers agent--tab-bar-refresh
    agent-auto--tick agent-auto--run-flush)
  "The functions of the timers the modes run.
The last runs once, when something waits to be written on a task, as the
handover receipt of the scenario does.")

(defconst agent-reload-test--load-timers
  '(agent--refresh-derived-statuses agent--refresh-session-switcher)
  "The functions of the timers the package runs once it is loaded.")

(defconst agent-reload-test--keys
  '((agent-report-mode-map "C-c C-c" agent-report-send)
    (agent-report-mode-map "C-c C-k" agent-report-cancel)
    (agent-usage-mode-map "g" agent-usage-refresh)
    (agent-task-keys-mode-map "S" agent-link-session)
    (agent-snippet--keys-mode-map "TAB" agent-snippet-tab)
    (agent-snippet--keys-mode-map "<tab>" agent-snippet-tab)
    (agent-scroll-keys-mode-map "<prior>" agent-scroll-page-up)
    (agent-scroll-keys-mode-map "<next>" agent-scroll-page-down)
    (agent-scroll-keys-mode-map "<kp-prior>" agent-scroll-page-up)
    (agent-scroll-keys-mode-map "<kp-next>" agent-scroll-page-down)
    (agent-scroll-keys-mode-map "<remap> <scroll-down-command>"
                                agent-scroll-page-up)
    (agent-scroll-keys-mode-map "<remap> <scroll-up-command>"
                                agent-scroll-page-down))
  "The keys the package binds in its keymaps, each a list (MAP KEY COMMAND).
MAP is the variable that holds the keymap.")

(defconst agent-reload-test--maps
  '(agent-report-mode-map agent-usage-mode-map agent-snippet--keys-mode-map
    agent-scroll-keys-mode-map agent-task-keys-mode-map
    agent-session-keys-mode-map)
  "The keymaps of the package, in each of which the user binds a key.
The last is the user's own, in which the package binds nothing.")

(defconst agent-reload-test--user-key "C-c z"
  "The key the scenario binds in each of `agent-reload-test--maps'.")

;;;; The scenario

(defconst agent-reload-test--file (or load-file-name buffer-file-name)
  "This file, which the batch Emacs loads to run the scenario.")

(defconst agent-reload-test--capture-buffer " *agent-reload-test-capture*"
  "Name of the buffer in which the scenario turns the capture mode on.")

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
`:files-kept' when the loads left every file of the scenario as it was:
the stale ones written after the modes were turned on, the status files
of a session, and a handover receipt with the Org file of its task.
`:handovers' lists how many receipts `agent-auto' held after the second
load and after the first.  `:server-kept' is non-nil when the remote-control
server is the process it was, and `:server-functions' lists its filter,
its sentinel and its log function, each the symbol it is or
`not-a-symbol'.  `:saved' lists the notification functions the two
backend modes saved, and `:restored' the ones in place once the modes
were off.  `:tab-bar' lists `tab-bar-format' after the loads, before
them and before the modes were turned on, and `:tab-bar-off' is what it
was once they were off again.  `:maps-kept' is an alist from each of
`agent-reload-test--maps' to whether it holds the keymap it held before
the loads.  `:sessions' is a cons of what
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
         (tab-bar (list tab-bar-format))
         (swept (progn (agent-reload-test--turn-modes-on)
                       (not (seq-some #'file-exists-p stale))))
         (files (progn (agent-reload-test--plant-stale-files)
                       (agent-reload-test--plant-session-files)
                       (agent-reload-test--plant-handover directory)
                       (agent-reload-test--files directory)))
         (server agent-remote--server)
         (maps (mapcar #'symbol-value agent-reload-test--maps))
         (tab-bar (cons tab-bar-format tab-bar))
         (sessions (agent-reload-test--make-sessions))
         (states (agent-reload-test--session-states sessions))
         (first (agent-reload-test--load-after #'agent-reload-test--make-older))
         (handovers (list (length agent-auto--handovers)))
         (second (agent-reload-test--load-after
                  #'agent-reload-test--add-second-timers))
         (handovers (cons (length agent-auto--handovers) handovers))
         (report
          (list :swept swept :first first :second second
                :handovers handovers
                :files-kept (equal files (agent-reload-test--files directory))
                :server-kept (and (eq server agent-remote--server)
                                  (process-live-p server)
                                  t)
                :server-functions
                (mapcar (lambda (function)
                          (if (symbolp function) function 'not-a-symbol))
                        (list (process-filter server)
                              (process-sentinel server)
                              (process-contact server :log)))
                :saved (list agent-claude--saved-notification-function
                             agent-codex--saved-notification-function)
                :tab-bar (cons tab-bar-format tab-bar)
                :maps-kept (cl-mapcar (lambda (map keymap)
                                        (cons map (eq (symbol-value map) keymap)))
                                      agent-reload-test--maps maps)
                :sessions (cons states
                                (agent-reload-test--session-states sessions))
                :events agent-reload-test--events)))
    (agent-reload-test--turn-modes-off)
    (append report
            (list :off (agent-reload-test--installed)
                  :restored (list claude-code-notification-function
                                  codex-notification-function)
                  :tab-bar-off tab-bar-format))))

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
key of the user's in each of `agent-reload-test--maps' are in place, as
an init file would have left them."
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
        agent-auto-handover-directory (expand-file-name "handovers/" directory)
        agent-remote-host "127.0.0.1"
        agent-remote-listen-address "127.0.0.1"
        agent-remote-allowed-networks '("127.0.0.0/8")
        agent-remote-port t)
  (dolist (map agent-reload-test--maps)
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

(defun agent-reload-test--plant-session-files ()
  "Write status files as a running Claude session keeps them."
  (dolist (extension '("json" "state" "sid"))
    (write-region "{}" nil
                  (expand-file-name (concat "0123-abcd." extension)
                                    agent-claude-status-directory)
                  nil 'silent)))

(defun agent-reload-test--plant-handover (directory)
  "Write under DIRECTORY a handover receipt that waits for its task's buffer.
The task is in an Org file whose buffer is left with an unsaved edit, so
the receipt cannot be written on it and nothing of the scenario's files
changes while it waits."
  (let ((tasks (expand-file-name "tasks.org" directory))
        (receipt (expand-file-name "20261118T083000000000-0a1b.json"
                                   agent-auto-handover-directory)))
    (write-region "* TODO Task\n:PROPERTIES:\n:AGENT_SESSION: sid-0\n:END:\n"
                  nil tasks nil 'silent)
    (with-current-buffer (find-file-noselect tasks)
      (goto-char (point-max))
      (insert "Unsaved.\n"))
    (make-directory agent-auto-handover-directory t)
    (write-region
     (json-serialize (list :id "20261118T083000000000-0a1b" :file tasks
                           :session "sid-0" :state "interrupted"
                           :summary "Half done"))
     nil receipt nil 'silent)))

(defun agent-reload-test--turn-modes-on ()
  "Turn every global mode of the package on, and the capture mode in a buffer.
`agent-auto-mode' is given the ripgrep it refuses to start without."
  (agent-claude-mode 1)
  (agent-codex-mode 1)
  (agent-tab-bar-mode 1)
  (agent-remote-mode 1)
  (cl-letf (((symbol-function 'executable-find)
             (lambda (command &rest _) command)))
    (agent-auto-mode 1))
  (with-current-buffer (get-buffer-create agent-reload-test--capture-buffer)
    (agent-prompt-capture-mode 1)))

(defun agent-reload-test--turn-modes-off ()
  "Turn every mode `agent-reload-test--turn-modes-on' turned on off."
  (with-current-buffer agent-reload-test--capture-buffer
    (agent-prompt-capture-mode -1))
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
  (with-current-buffer agent-reload-test--capture-buffer
    (dolist (entry agent-reload-test--local-hooks)
      (remove-hook (car entry) (cadr entry) t)))
  (dolist (entry agent-reload-test--advice)
    (advice-remove (car entry) (cadr entry)))
  (setq agent-session-inherited-variables
        (seq-difference agent-session-inherited-variables
                        agent-reload-test--inherited-variables))
  (dolist (function agent-reload-test--mode-timers)
    (cancel-function-timers function))
  (pcase-dolist (`(,map ,key ,_command) agent-reload-test--keys)
    (keymap-unset (symbol-value map) key t)))

(defun agent-reload-test--add-second-timers ()
  "Start a second timer for each function the modes run on a timer."
  (dolist (function agent-reload-test--mode-timers)
    (run-with-timer 3600 3600 function)))

(defun agent-reload-test--installed ()
  "Return how often each thing the package installs is installed now.
The value is a plist of alists, each from an entry of the list of the
same name at the top of this file to a count: `:hooks' how often the
function is on its hook, `:local-hooks' how often it is on the hook in
the capture buffer, `:advice' how often it advises the function of
the symbol, `:inherited' how often the variable is in
`agent-session-inherited-variables', `:mode-timers' and `:load-timers'
how many timers run the function.  `:keys' is an alist from each entry
of `agent-reload-test--keys' to the command its key runs, and
`:user-keys' one from each keymap to the command
`agent-reload-test--user-key' runs in it."
  (list :hooks
        (mapcar (lambda (entry)
                  (cons entry (agent-reload-test--count
                               (cadr entry)
                               (and (default-boundp (car entry))
                                    (default-value (car entry))))))
                agent-reload-test--hooks)
        :local-hooks
        (mapcar (lambda (entry)
                  (cons entry (agent-reload-test--count
                               (cadr entry)
                               (buffer-local-value
                                (car entry)
                                (get-buffer agent-reload-test--capture-buffer)))))
                agent-reload-test--local-hooks)
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
        :keys
        (mapcar (lambda (entry)
                  (cons entry (agent-reload-test--binding
                               (car entry) (cadr entry))))
                agent-reload-test--keys)
        :user-keys
        (mapcar (lambda (map)
                  (cons map (agent-reload-test--binding
                             map agent-reload-test--user-key)))
                agent-reload-test--maps)))

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
      (agent-reload-test--should-all-be 1 (plist-get installed :local-hooks))
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

(ert-deftest agent-reload-test-declared-keys-are-bound ()
  "Find each key the package declares bound to its command after each load.
A key the version loaded first did not bind is bound after the first
load: a `defvar' keeps the keymap that version built."
  (dolist (load '(:first :second))
    (let ((keys (plist-get (plist-get (agent-reload-test--report) load) :keys)))
      (should keys)
      (pcase-dolist (`(,entry . ,command) keys)
        (should (equal (cons entry command) (cons entry (nth 2 entry))))))))

(ert-deftest agent-reload-test-user-keys-are-kept ()
  "Find the keys the user bound in the keymaps still bound after each load.
Each keymap is the one it was, since session buffers and
`minor-mode-map-alist' hold it."
  (dolist (load '(:first :second))
    (agent-reload-test--should-all-be
     'agent-reload-test-user-command
     (plist-get (plist-get (agent-reload-test--report) load) :user-keys)))
  (agent-reload-test--should-all-be
   t (plist-get (agent-reload-test--report) :maps-kept)))

(ert-deftest agent-reload-test-handover-receipts-are-read-once ()
  "Hold a receipt left on disk once after each load, and leave its file.
Loading `agent-auto.el' again reads the receipts again, as turning the
mode on does, and a receipt read twice must not be held twice."
  (let ((report (agent-reload-test--report)))
    (should (equal (plist-get report :handovers) '(1 1)))
    (should (plist-get report :files-kept))))

(ert-deftest agent-reload-test-what-is-done-once-is-not-done-again ()
  "Leave alone what a mode does once when it is turned on.
The stale files a mode deletes when it is turned on are deleted then and
not by loading its file again, which touches no file at all, a session's
status files included; the server is not started again, and needs no
starting to run the code just loaded, since it calls its functions by
name; the tab bar keeps the one sessions segment it was given; and the
notification functions the backend modes saved are still the user's,
not the ones the modes put in their place."
  (let ((report (agent-reload-test--report)))
    (should (plist-get report :swept))
    (should (plist-get report :files-kept))
    (should (plist-get report :server-kept))
    (should (equal (plist-get report :server-functions)
                   '(agent-remote--filter agent-remote--sentinel
                     agent-remote--log)))
    (pcase-let ((`(,after ,before ,_original) (plist-get report :tab-bar)))
      (should (memq 'agent-tab-bar-format-sessions before))
      (should (equal after before)))
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
notification functions and the tab bar are the user's again.  The timers
the package runs whenever it is loaded stay."
  (let* ((report (agent-reload-test--report))
         (installed (plist-get report :off)))
    (agent-reload-test--should-all-be 0 (plist-get installed :hooks))
    (agent-reload-test--should-all-be 0 (plist-get installed :local-hooks))
    (agent-reload-test--should-all-be 0 (plist-get installed :advice))
    (agent-reload-test--should-all-be 0 (plist-get installed :inherited))
    (agent-reload-test--should-all-be 0 (plist-get installed :mode-timers))
    (agent-reload-test--should-all-be 1 (plist-get installed :load-timers))
    (should (equal (plist-get report :restored)
                   '(agent-reload-test-claude-notification
                     agent-reload-test-codex-notification)))
    (should (equal (plist-get report :tab-bar-off)
                   (nth 2 (plist-get report :tab-bar))))))

(provide 'agent-reload-test)

;;; agent-reload-test.el ends here
