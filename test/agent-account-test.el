;;; agent-account-test.el --- Tests for agent-account -*- lexical-binding: t -*-

;; Tests for the unified multi-account module.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'agent)
(require 'agent-account)

(defvar agent-account-test--accounts nil
  "Accounts alist bound by indirection tests.")

(defvar native-comp-enable-subr-trampolines)

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
