;;; agent-usage-test.el --- Tests for agent-usage -*- lexical-binding: t -*-

;; Tests for the shared account usage store and poller.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'agent)
(require 'agent-account)
(require 'agent-usage)

(defmacro agent-usage-test--with-store (&rest body)
  "Run BODY with an empty usage store backed by a temporary cache file."
  (declare (indent 0))
  `(let ((agent-usage--data (make-hash-table :test #'equal))
         (agent-usage-cache-file (make-temp-file "agent-usage"))
         (agent-usage--timer nil)
         (agent-usage--current-interval nil))
     (unwind-protect
         (progn ,@body)
       (when agent-usage--timer
         (cancel-timer agent-usage--timer))
       (delete-file agent-usage-cache-file))))

(defmacro agent-usage-test--with-backend (spec &rest body)
  "Run BODY with backend `stub' registered from SPEC."
  (declare (indent 1))
  `(let ((agent-backends
          (list (cons 'stub
                      (apply #'agent-backend--create :name 'stub ,spec)))))
     ,@body))

;;;; Store

(ert-deftest agent-usage-test-record-stamps-and-persists ()
  "Stamp `:fetched-at' on a recording and reload it from the cache file."
  (agent-usage-test--with-store
    (let ((stored (agent-usage-record 'stub "a" '(:weekly-pct 10.0))))
      (should (numberp (plist-get stored :fetched-at)))
      (should (eq (agent-usage-get 'stub "a") stored))
      (setq agent-usage--data nil)
      (should (equal (plist-get (agent-usage-get 'stub "a") :weekly-pct)
                     10.0)))))

(ert-deftest agent-usage-test-load-ignores-corrupt-cache ()
  "Start from an empty table when the cache file does not parse."
  (agent-usage-test--with-store
    (with-temp-file agent-usage-cache-file (insert "(((stub . \"a\"))"))
    (setq agent-usage--data nil)
    (should (zerop (hash-table-count (agent-usage--table))))))

(ert-deftest agent-usage-test-fresh-p ()
  "Treat a reading as fresh only within `agent-usage-stale-after'."
  (let ((agent-usage-stale-after 100))
    (should (agent-usage-fresh-p '(:fetched-at 1000.0) 1050.0))
    (should-not (agent-usage-fresh-p '(:fetched-at 1000.0) 1200.0))
    (should-not (agent-usage-fresh-p nil 1200.0))))

(ert-deftest agent-usage-test-window-coerces-times ()
  "Coerce ISO strings and Unix timestamps to float seconds."
  (should (equal (agent-usage-window 5 1787423929) '(5.0 . 1787423929.0)))
  (should (equal (agent-usage-window 5 "2026-08-22T18:38:49Z")
                 '(5.0 . 1787423929.0)))
  (should (equal (agent-usage-window 5 nil) '(5.0 . nil)))
  (should-not (agent-usage-window nil 1787423929)))

;;;; Fetching

(ert-deftest agent-usage-test-fetch-records-and-resets-interval ()
  "Record a successful fetch and reset the poll interval."
  (agent-usage-test--with-store
    (agent-usage-test--with-backend
        (list :usage-fetch (lambda (_account callback)
                             (funcall callback '(:weekly-pct 1.0))))
      (let (reset)
        (cl-letf (((symbol-function 'agent-usage--reset-interval)
                   (lambda () (setq reset t))))
          (should (agent-usage-fetch 'stub "a"))
          (should reset)
          (should (equal (plist-get (agent-usage-get 'stub "a") :weekly-pct)
                         1.0)))))))

(ert-deftest agent-usage-test-fetch-failure-backs-off-and-keeps-old ()
  "Back off on a failed fetch and keep the previous reading."
  (agent-usage-test--with-store
    (agent-usage-test--with-backend
        (list :usage-fetch (lambda (_account callback)
                             (funcall callback nil)))
      (agent-usage-record 'stub "a" '(:weekly-pct 1.0))
      (let (backed reported)
        (cl-letf (((symbol-function 'agent-usage-backoff)
                   (lambda () (setq backed t))))
          (agent-usage-fetch 'stub "a" (lambda (u) (setq reported (list u))))
          (should backed)
          (should (equal reported '(nil)))
          (should (equal (plist-get (agent-usage-get 'stub "a") :weekly-pct)
                         1.0)))))))

(ert-deftest agent-usage-test-fetch-without-fetcher-is-noop ()
  "Return nil for a backend that declares no usage fetcher."
  (agent-usage-test--with-store
    (agent-usage-test--with-backend (list)
      (should-not (agent-usage-fetch 'stub "a")))))

;;;; Polling

(ert-deftest agent-usage-test-tracked-accounts-union-sessions-and-pools ()
  "Poll live-session accounts plus every pool member, once each."
  (let ((buf (generate-new-buffer " *usage-stub*")))
    (unwind-protect
        (agent-usage-test--with-backend
            (list :accounts '(("solo" . "/tmp/s")
                              ("e1" :home "/tmp/e1" :pool "p")
                              ("e2" :home "/tmp/e2" :pool "p"))
                  :buffer-p (lambda (candidate) (eq candidate buf))
                  :find-all-buffers (lambda () (list buf)))
          (agent--set-session
           buf (agent-session-create :backend 'stub :account "e1"
                                     :directory "~/r/"))
          (should (equal (sort (agent-usage--tracked-accounts 'stub) #'string<)
                         '("e1" "e2"))))
      (kill-buffer buf))))

(ert-deftest agent-usage-test-tracked-accounts-default-home ()
  "Poll the default home when sessions exist but no accounts are configured."
  (let ((buf (generate-new-buffer " *usage-stub*")))
    (unwind-protect
        (agent-usage-test--with-backend
            (list :buffer-p (lambda (candidate) (eq candidate buf))
                  :find-all-buffers (lambda () (list buf)))
          (should (equal (agent-usage--tracked-accounts 'stub) '(nil))))
      (kill-buffer buf))))

(ert-deftest agent-usage-test-backoff-doubles-and-caps ()
  "Double the interval on backoff up to the maximum, then reset."
  (agent-usage-test--with-store
    (let ((agent-usage-interval 100)
          (agent-usage-max-interval 300))
      (cl-letf (((symbol-function 'agent-usage--poll) #'ignore))
        (agent-usage-start-polling)
        (agent-usage-backoff)
        (should (= agent-usage--current-interval 200))
        (agent-usage-backoff)
        (should (= agent-usage--current-interval 300))
        (agent-usage--reset-interval)
        (should (= agent-usage--current-interval 100))
        (agent-usage-stop-polling)
        (should-not agent-usage--timer)))))

(ert-deftest agent-usage-test-maybe-stop-considers-all-backends ()
  "Keep polling while any backend other than the torn-down one is live."
  (agent-usage-test--with-store
    (let ((buf (generate-new-buffer " *usage-other*")))
      (unwind-protect
          (let ((agent-backends
                 (list (cons 'one (agent-backend--create
                                   :name 'one :find-all-buffers #'ignore))
                       (cons 'two (agent-backend--create
                                   :name 'two
                                   :find-all-buffers (lambda () (list buf)))))))
            (cl-letf (((symbol-function 'agent-usage--poll) #'ignore))
              (agent-usage-start-polling)
              (agent-usage-maybe-stop-polling (current-buffer))
              (should agent-usage--timer)
              (agent-usage-maybe-stop-polling buf)
              (should-not agent-usage--timer)))
        (kill-buffer buf)))))

;;;; Usage buffer

(ert-deftest agent-usage-test-view-refreshes-idle-configured-accounts ()
  "Display and refresh idle configured accounts without background polling."
  (agent-usage-test--with-store
    (let (fetched
          (agent-usage--pending-refresh 0)
          (agent-usage-buffer-name " *usage-test-view*"))
      (agent-usage-test--with-backend
          (list :accounts '(("solo" . "/tmp/solo"))
                :usage-fetch (lambda (account callback)
                               (push account fetched)
                               (funcall callback '(:weekly-pct 23.0))))
        (should-not (agent-usage--tracked-accounts 'stub))
        (agent-usage-refresh)
        (should (equal fetched '("solo")))
        (should (zerop agent-usage--pending-refresh))
        (with-temp-buffer
          (agent-usage-mode)
          (agent-usage--render)
          (should (string-match-p "solo.*23%" (buffer-string))))))))

(ert-deftest agent-usage-test-display-default-without-sessions ()
  "Include the default account even without a live session."
  (agent-usage-test--with-backend (list)
    (should (equal (agent-usage--display-accounts 'stub) '(nil)))))

(ert-deftest agent-usage-test-display-deduplicates-active-accounts ()
  "Keep configured and tracked accounts without duplicating shared names."
  (agent-usage-test--with-backend
      (list :accounts '(("solo" . "/tmp/solo")
                        ("pool" :home "/tmp/pool" :pool "p")))
    (cl-letf (((symbol-function 'agent-usage--active-accounts)
               (lambda (_backend) '("solo" nil))))
      (should (equal (agent-usage--display-accounts 'stub)
                     '("solo" "pool" nil))))))

(ert-deftest agent-usage-test-entry-formats-reading ()
  "Render a reading's percentages, limit flag, and age."
  (agent-usage-test--with-store
    (agent-usage-test--with-backend
        (list :accounts '(("e1" :home "/tmp/e1" :pool "p")))
      (agent-usage-record 'stub "e1" '(:session-pct 12.4 :weekly-pct 100.0
                                       :limited t))
      (let ((row (cadr (agent-usage--entry 'stub "e1"))))
        (should (equal (aref row 0) "stub"))
        (should (equal (aref row 1) "e1"))
        (should (equal (aref row 2) "p"))
        (should (equal (aref row 3) "12%"))
        (should (equal (aref row 4) "100%"))
        (should (equal (aref row 6) "yes"))
        (should (equal (aref row 7) "now"))))))

(ert-deftest agent-usage-test-entry-without-reading ()
  "Render dashes for an account that has never been polled."
  (agent-usage-test--with-store
    (agent-usage-test--with-backend (list)
      (let ((row (cadr (agent-usage--entry 'stub nil))))
        (should (equal (aref row 1) "default"))
        (should (equal (aref row 3) "-"))
        (should (equal (aref row 6) ""))
        (should (equal (aref row 7) "-"))))))

(ert-deftest agent-usage-test-age-buckets ()
  "Format ages in minutes, hours, and days."
  (let ((now (float-time)))
    (should (equal (agent-usage--age (list :fetched-at (- now 120))) "2m"))
    (should (equal (agent-usage--age (list :fetched-at (- now 7200))) "2h"))
    (should (equal (agent-usage--age (list :fetched-at (- now 172800))) "2d"))))

(provide 'agent-usage-test)
;;; agent-usage-test.el ends here
