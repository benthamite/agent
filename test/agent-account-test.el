;;; agent-account-test.el --- Tests for agent-account -*- lexical-binding: t -*-

;; Tests for the unified multi-account module.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'agent)
(require 'agent-account)
(require 'agent-usage)

(defvar agent-account-test--accounts nil
  "Accounts alist bound by indirection tests.")

(defvar native-comp-enable-subr-trampolines)

(defmacro agent-account-test--with-backend (spec &rest body)
  "Run BODY with backend `stub' registered from SPEC.
SPEC is an expression evaluating to a plist of `agent-backend' slot
keywords, passed to the struct constructor.  Also isolates the
account cache and the starting binding."
  (declare (indent 1))
  `(let ((agent-backends
          (list (cons 'stub
                      (apply #'agent-backend--create :name 'stub ,spec))))
         (agent-account--current (make-hash-table :test #'eq))
         (agent-account--starting nil))
     ,@body))

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
    (let ((native-comp-enable-subr-trampolines nil)
          calls)
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

(ert-deftest agent-account-test-sync-propagates-account-init-errors ()
  "Do not start with stale configuration after account initialization fails."
  (let* ((dir (make-temp-file "agent-account" t))
         (home (expand-file-name "work" dir)))
    (unwind-protect
        (agent-account-test--with-backend
            (list :accounts `(("work" . ,home))
                  :canonical-home dir
                  :shared-config-items nil
                  :account-init (lambda (_account) (error "sync failed")))
          (should-error (agent-account-sync 'stub "work")
                        :type 'error))
      (delete-directory dir t))))

;;;; Credentials and login

(ert-deftest agent-account-test-logged-in-without-credential-file ()
  "Assume logged in when the backend declares no credential file."
  (agent-account-test--with-backend
      (list :accounts '(("work" . "/tmp/w")))
    (should (agent-account-logged-in-p 'stub "work"))))

(ert-deftest agent-account-test-logged-in-detects-missing-credentials ()
  "Report logged out when the declared credential file is missing."
  (let* ((home (make-temp-file "agent-account" t)))
    (unwind-protect
        (agent-account-test--with-backend
            (list :accounts `(("work" . ,home))
                  :credential-file "auth.json")
          (should-not (agent-account-logged-in-p 'stub "work")))
      (delete-directory home t))))

(ert-deftest agent-account-test-logged-in-detects-present-credentials ()
  "Report logged in when the declared credential file exists."
  (let* ((home (make-temp-file "agent-account" t)))
    (unwind-protect
        (agent-account-test--with-backend
            (list :accounts `(("work" . ,home))
                  :credential-file "auth.json")
          (with-temp-file (expand-file-name "auth.json" home)
            (insert "{\"token\": \"x\"}"))
          (should (agent-account-logged-in-p 'stub "work")))
      (delete-directory home t))))

(ert-deftest agent-account-test-login-rejects-unsupported-backend ()
  "Signal a user error for backends without a login command."
  (agent-account-test--with-backend
      (list :accounts '(("work" . "/tmp/w")))
    (should-error (agent-account-login 'stub "work") :type 'user-error)))

(ert-deftest agent-account-test-login-spawns-with-account-env ()
  "Run the login command with the account's environment after syncing."
  (agent-account-test--with-backend
      (list :accounts '(("work" . "/tmp/w"))
            :account-env-var "STUB_HOME"
            :program "stub-cli"
            :login-args '("login"))
    (let (captured-command captured-env synced)
      (cl-letf (((symbol-function 'agent-account-sync)
                 (lambda (backend account)
                   (setq synced (cons backend account))))
                ((symbol-function 'display-buffer) #'ignore)
                ((symbol-function 'make-process)
                 (lambda (&rest args)
                   (setq captured-command (plist-get args :command)
                         captured-env process-environment)
                   'stub-process)))
        (unwind-protect
            (progn
              (should (eq (agent-account-login 'stub "work") 'stub-process))
              (should (equal synced '(stub . "work")))
              (should (equal captured-command '("stub-cli" "login")))
              (should (member "STUB_HOME=/tmp/w" captured-env)))
          (when-let* ((buffer (get-buffer "*agent-login: stub/work*")))
            (kill-buffer buffer)))))))

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


;;;; Pools

(defconst agent-account-test--pooled
  '(("solo" . "/tmp/solo")
    ("e1" :home "/tmp/e1" :pool "epoch")
    ("e2" :home "/tmp/e2" :pool "epoch" :chrome-profile "Work"))
  "Accounts mixing a bare entry with two pool members.")

(defmacro agent-account-test--with-usage (readings &rest body)
  "Run BODY with an isolated usage store holding READINGS.
READINGS is a list of (ACCOUNT . PLIST) recorded for backend `stub';
the routing memory is cleared and pool refreshes are stubbed out."
  (declare (indent 1))
  `(let ((agent-usage--data (make-hash-table :test #'equal))
         (agent-usage-cache-file (make-temp-file "agent-usage"))
         (agent-account--routed (make-hash-table :test #'equal))
         (inhibit-message t))
     (unwind-protect
         (cl-letf (((symbol-function 'agent-usage-refresh-pool) #'ignore))
           (dolist (reading ,readings)
             (agent-usage-record 'stub (car reading) (cdr reading)))
           ,@body)
       (delete-file agent-usage-cache-file))))

(ert-deftest agent-account-test-home-reads-both-entry-shapes ()
  "Read the home from a dotted pair and from a plist entry."
  (agent-account-test--with-backend
      (list :accounts agent-account-test--pooled)
    (should (equal (agent-account-home 'stub "solo") "/tmp/solo"))
    (should (equal (agent-account-home 'stub "e1") "/tmp/e1"))
    (should-not (agent-account-home 'stub "epoch"))
    (should-not (agent-account-home 'stub nil))))

(ert-deftest agent-account-test-property-reads-plist-keys ()
  "Expose extra plist keys; a dotted pair has only `:home'."
  (agent-account-test--with-backend
      (list :accounts agent-account-test--pooled)
    (should (equal (agent-account-property 'stub "e2" :chrome-profile) "Work"))
    (should-not (agent-account-property 'stub "solo" :chrome-profile))
    (should (equal (agent-account-property 'stub "solo" :home) "/tmp/solo"))))

(ert-deftest agent-account-test-pools-and-members ()
  "List pools in declaration order and members per pool."
  (agent-account-test--with-backend
      (list :accounts agent-account-test--pooled)
    (should (equal (agent-account-pools 'stub) '("epoch")))
    (should (agent-account-pool-p 'stub "epoch"))
    (should-not (agent-account-pool-p 'stub "e1"))
    (should (equal (agent-account-pool-members 'stub "epoch") '("e1" "e2")))
    (should (equal (agent-account-pool 'stub "e2") "epoch"))
    (should-not (agent-account-pool 'stub "solo"))))

(ert-deftest agent-account-test-selection-names-lists-pools-first ()
  "Offer pools before accounts when selecting."
  (agent-account-test--with-backend
      (list :accounts agent-account-test--pooled)
    (should (equal (agent-account-selection-names 'stub)
                   '("epoch" "solo" "e1" "e2")))))

(ert-deftest agent-account-test-pool-name-shadows-account-name ()
  "List a name shared by a pool and an account once, and resolve it as the pool."
  (agent-account-test--with-backend
      (list :accounts '(("epoch" :home "/tmp/e1" :pool "epoch")
                        ("epoch2" :home "/tmp/e2" :pool "epoch")))
    (should (equal (agent-account-selection-names 'stub) '("epoch" "epoch2")))
    (agent-account-test--with-usage '(("epoch" :weekly-pct 100.0)
                                      ("epoch2" :weekly-pct 5.0))
      (puthash 'stub "epoch" agent-account--current)
      (should (equal (agent-account-resolve 'stub) "epoch2")))))

(ert-deftest agent-account-test-load-accepts-pool-name ()
  "Accept a persisted selection naming a pool."
  (let ((file (make-temp-file "agent-account")))
    (unwind-protect
        (agent-account-test--with-backend
            (list :accounts agent-account-test--pooled :account-file file)
          (with-temp-file file (insert "epoch\n"))
          (should (equal (agent-account-current 'stub) "epoch")))
      (delete-file file))))

(ert-deftest agent-account-test-resolve-routes-pool-to-member ()
  "Resolve a pool selection to a concrete member."
  (agent-account-test--with-backend
      (list :accounts agent-account-test--pooled)
    (agent-account-test--with-usage nil
      (puthash 'stub "epoch" agent-account--current)
      (should (equal (agent-account-resolve 'stub) "e1")))))

(ert-deftest agent-account-test-route-skips-logged-out-member ()
  "Skip a pool member whose credentials file is missing."
  (agent-account-test--with-backend
      (list :accounts agent-account-test--pooled :credential-file "auth.json")
    (agent-account-test--with-usage nil
      (cl-letf (((symbol-function 'file-exists-p)
                 (lambda (path) (string-prefix-p "/tmp/e2" path))))
        (should (equal (agent-account-route 'stub "epoch") "e2"))))))

(ert-deftest agent-account-test-route-falls-back-to-first-member ()
  "Return the first member when no member is logged in."
  (agent-account-test--with-backend
      (list :accounts agent-account-test--pooled :credential-file "auth.json")
    (agent-account-test--with-usage nil
      (cl-letf (((symbol-function 'file-exists-p) #'ignore))
        (should (equal (agent-account-route 'stub "epoch") "e1"))))))

(ert-deftest agent-account-test-route-prefers-lowest-usage ()
  "Route to the member with the lowest usage score."
  (agent-account-test--with-backend
      (list :accounts agent-account-test--pooled)
    (agent-account-test--with-usage
        '(("e1" :weekly-pct 80.0 :session-pct 10.0)
          ("e2" :weekly-pct 30.0 :session-pct 50.0))
      (should (equal (agent-account-route 'stub "epoch") "e2")))))

(ert-deftest agent-account-test-route-excludes-limited-member ()
  "Set aside a member that is limited or has exhausted a window."
  (agent-account-test--with-backend
      (list :accounts agent-account-test--pooled)
    (agent-account-test--with-usage
        '(("e1" :weekly-pct 5.0 :limited t)
          ("e2" :weekly-pct 90.0))
      (should (equal (agent-account-route 'stub "epoch") "e2")))
    (agent-account-test--with-usage
        '(("e1" :weekly-pct 100.0)
          ("e2" :weekly-pct 90.0))
      (should (equal (agent-account-route 'stub "epoch") "e2")))))

(ert-deftest agent-account-test-route-ignores-stale-limit ()
  "Treat a stale limited reading as unknown rather than limited."
  (agent-account-test--with-backend
      (list :accounts agent-account-test--pooled)
    (agent-account-test--with-usage
        '(("e1" :weekly-pct 100.0 :limited t :fetched-at 1.0)
          ("e2" :weekly-pct 90.0))
      (should (equal (agent-account-route 'stub "epoch") "e2"))
      (should-not (agent-account--limited-p 'stub "e1")))))

(ert-deftest agent-account-test-route-ranks-unknown-last ()
  "Prefer a member with a known score over one without."
  (agent-account-test--with-backend
      (list :accounts agent-account-test--pooled)
    (agent-account-test--with-usage '(("e2" :weekly-pct 95.0))
      (should (equal (agent-account-route 'stub "epoch") "e2")))))

(ert-deftest agent-account-test-route-keeps-current-within-hysteresis ()
  "Keep the last routed member unless a sibling is clearly better."
  (agent-account-test--with-backend
      (list :accounts agent-account-test--pooled)
    (agent-account-test--with-usage
        '(("e1" :weekly-pct 50.0) ("e2" :weekly-pct 45.0))
      (puthash '(stub . "epoch") "e1" agent-account--routed)
      (should (equal (agent-account-route 'stub "epoch") "e1")))
    (agent-account-test--with-usage
        '(("e1" :weekly-pct 50.0) ("e2" :weekly-pct 20.0))
      (puthash '(stub . "epoch") "e1" agent-account--routed)
      (should (equal (agent-account-route 'stub "epoch") "e2")))))

(ert-deftest agent-account-test-route-does-not-keep-unknown-over-known ()
  "Drop a current member without a score when a sibling has one."
  (agent-account-test--with-backend
      (list :accounts agent-account-test--pooled)
    (agent-account-test--with-usage '(("e2" :weekly-pct 60.0))
      (puthash '(stub . "epoch") "e1" agent-account--routed)
      (should (equal (agent-account-route 'stub "epoch") "e2")))))

(ert-deftest agent-account-test-route-all-limited-picks-soonest-reset ()
  "Fall back to the member whose limit lifts soonest when all are limited."
  (agent-account-test--with-backend
      (list :accounts agent-account-test--pooled)
    (agent-account-test--with-usage
        '(("e1" :weekly-pct 100.0 :weekly-reset 2000.0)
          ("e2" :weekly-pct 100.0 :weekly-reset 1000.0 :session-reset 3000.0))
      (should (equal (agent-account-route 'stub "epoch") "e2")))))

(ert-deftest agent-account-test-route-records-choice-and-refreshes ()
  "Remember the routed member and refresh the pool's usage."
  (agent-account-test--with-backend
      (list :accounts agent-account-test--pooled)
    (agent-account-test--with-usage nil
      (let (refreshed)
        (cl-letf (((symbol-function 'agent-usage-refresh-pool)
                   (lambda (backend pool) (setq refreshed (list backend pool)))))
          (agent-account-route 'stub "epoch")
          (should (equal refreshed '(stub "epoch")))
          (should (equal (gethash '(stub . "epoch") agent-account--routed)
                         "e1")))))))

(ert-deftest agent-account-test-route-announces-only-on-change ()
  "Announce a route when it changes hands, not on every resolution."
  (agent-account-test--with-backend
      (list :accounts agent-account-test--pooled)
    (agent-account-test--with-usage
        '(("e1" :weekly-pct 10.0) ("e2" :weekly-pct 50.0))
      (let (announced)
        (cl-letf (((symbol-function 'agent-account--announce-route)
                   (lambda (_backend _pool account _all-limited)
                     (push account announced))))
          (agent-account-route 'stub "epoch")
          (agent-account-route 'stub "epoch")
          (should (equal announced '("e1")))
          (agent-usage-record 'stub "e1" '(:weekly-pct 90.0))
          (agent-account-route 'stub "epoch")
          (should (equal announced '("e2" "e1"))))))))

(ert-deftest agent-account-test-usage-score ()
  "Score by the fuller window, with the weekly share breaking ties."
  (agent-account-test--with-backend
      (list :accounts agent-account-test--pooled)
    (agent-account-test--with-usage
        '(("e1" :weekly-pct 40.0 :session-pct 70.0)
          ("e2" :weekly-pct 70.0 :session-pct 10.0))
      (should (< (agent-account-usage-score 'stub "e1")
                 (agent-account-usage-score 'stub "e2")))
      (should-not (agent-account-usage-score 'stub "solo")))))

(ert-deftest agent-account-test-resolve-keeps-plain-account ()
  "Return a non-pool selection unchanged."
  (agent-account-test--with-backend
      (list :accounts agent-account-test--pooled)
    (puthash 'stub "solo" agent-account--current)
    (should (equal (agent-account-resolve 'stub) "solo"))))

(ert-deftest agent-account-test-sync-selection-syncs-every-member ()
  "Sync each member home when the selection is a pool."
  (agent-account-test--with-backend
      (list :accounts agent-account-test--pooled)
    (let (synced)
      (cl-letf (((symbol-function 'agent-account-sync)
                 (lambda (_backend account) (push account synced))))
        (agent-account-sync-selection 'stub "epoch")
        (should (equal (nreverse synced) '("e1" "e2")))
        (setq synced nil)
        (agent-account-sync-selection 'stub "solo")
        (should (equal synced '("solo")))))))

(provide 'agent-account-test)
;;; agent-account-test.el ends here
