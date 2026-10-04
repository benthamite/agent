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
         (agent-usage--timer nil))
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

(ert-deftest agent-usage-test-fetch-records-success ()
  "Record a successful fetch, clearing an earlier error."
  (agent-usage-test--with-store
    (agent-usage-test--with-backend
        (list :usage-fetch (lambda (_account callback)
                             (funcall callback '(:weekly-pct 1.0))))
      (puthash '(stub . "a") '(:error "HTTP 500" :backoff 300)
               (agent-usage--table))
      (should (agent-usage-fetch 'stub "a"))
      (let ((usage (agent-usage-get 'stub "a")))
        (should (equal (plist-get usage :weekly-pct) 1.0))
        (should-not (plist-get usage :error))
        (should-not (plist-get usage :retry-at))))))

(ert-deftest agent-usage-test-fetch-failure-keeps-reading-and-records-error ()
  "Keep the previous reading and record why the fetch failed."
  (agent-usage-test--with-store
    (agent-usage-test--with-backend
        (list :usage-fetch (lambda (_account callback)
                             (funcall callback
                                      (agent-usage-failure "HTTP 500"))))
      (let ((agent-usage-interval 100)
            (fetched-at (plist-get (agent-usage-record
                                    'stub "a" '(:weekly-pct 1.0))
                                   :fetched-at))
            reported)
        (agent-usage-fetch 'stub "a" (lambda (u) (setq reported (list u))))
        (should (equal reported '(nil)))
        (let ((usage (agent-usage-get 'stub "a")))
          (should (equal (plist-get usage :weekly-pct) 1.0))
          (should (= (plist-get usage :fetched-at) fetched-at))
          (should (equal (plist-get usage :error) "HTTP 500"))
          (should (= (plist-get usage :backoff) 100)))))))

(ert-deftest agent-usage-test-failure-backoff-is-per-account-and-capped ()
  "Double one account's wait on each failure up to the maximum."
  (agent-usage-test--with-store
    (let ((agent-usage-interval 100)
          (agent-usage-max-interval 300))
      (dolist (expected '(100 200 300 300))
        (agent-usage--record-failure 'stub "a" nil 1000.0)
        (should (= (plist-get (agent-usage-get 'stub "a") :backoff) expected))
        (should (= (plist-get (agent-usage-get 'stub "a") :retry-at)
                   (+ 1000.0 expected))))
      (should-not (agent-usage-get 'stub "b")))))

(ert-deftest agent-usage-test-retry-after-overrides-backoff ()
  "Wait as long as the server's Retry-After, even beyond the maximum."
  (agent-usage-test--with-store
    (let ((agent-usage-max-interval 300))
      (agent-usage--record-failure
       'stub "a" (agent-usage-failure "rate-limited (HTTP 429)" 3329) 1000.0)
      (should (= (plist-get (agent-usage-get 'stub "a") :retry-at) 4329.0)))))

(ert-deftest agent-usage-test-fetch-skips-account-until-retry-time ()
  "Do not fetch an account before its retry time, but do afterwards."
  (agent-usage-test--with-store
    (let ((calls 0) reported)
      (agent-usage-test--with-backend
          (list :usage-fetch (lambda (_account callback)
                               (cl-incf calls)
                               (funcall callback '(:weekly-pct 1.0))))
        (puthash '(stub . "a") (list :retry-at (+ (float-time) 3600))
                 (agent-usage--table))
        (should (agent-usage-fetch 'stub "a" (lambda (u) (push u reported))))
        (should (= calls 0))
        (should (equal reported '(nil)))
        (puthash '(stub . "a") (list :retry-at (+ (float-time) 10))
                 (agent-usage--table))
        (agent-usage-fetch 'stub "a")
        (should (= calls 1))))))

(ert-deftest agent-usage-test-response-result-reads-retry-after ()
  "Turn an HTTP 429 response into a failure carrying Retry-After."
  (with-temp-buffer
    (insert "HTTP/1.1 429 Too Many Requests\nretry-after: 3329\n\n{}")
    (setq-local url-http-end-of-headers (point))
    (setq-local url-http-response-status 429)
    (should (equal (agent-usage-response-result
                    '(:error (error http 429)) #'identity)
                   '(:error "rate-limited (HTTP 429)" :retry-after 3329)))))

(ert-deftest agent-usage-test-response-result-network-failure ()
  "Treat a request that got no HTTP answer as a network failure."
  (with-temp-buffer
    (should (plist-get (agent-usage-response-result
                        '(:error (error connection-failed "refused"))
                        #'identity)
                       :network))
    (should (plist-get (agent-usage-response-result nil #'identity)
                       :network))))

(ert-deftest agent-usage-test-network-failure-retries-next-poll-quietly ()
  "Record a network failure without backoff, retry time, or message."
  (agent-usage-test--with-store
    (let ((messages nil))
      (cl-letf (((symbol-function 'message)
                 (lambda (&rest args) (push args messages))))
        (agent-usage--record-failure
         'stub "a" (agent-usage-failure "HTTP 500") 1000.0)
        (setq messages nil)
        (agent-usage--record-failure
         'stub "a" (agent-usage-network-failure) 2000.0))
      (let ((usage (agent-usage-get 'stub "a")))
        (should-not messages)
        (should (plist-get usage :network))
        (should-not (plist-get usage :retry-at))
        (should-not (plist-get usage :backoff))
        (should-not (agent-usage--deferred-p usage))
        (should (string-prefix-p "network error at "
                                 (agent-usage--status usage)))
        (should (eq (get-text-property 0 'face (agent-usage--status usage))
                    'shadow))))))

(ert-deftest agent-usage-test-force-overrides-backoff-not-retry-after ()
  "Let a manual refresh skip backoff but never a server-requested wait."
  (agent-usage-test--with-store
    (agent-usage--record-failure
     'stub "a" (agent-usage-failure "HTTP 500") (float-time))
    (agent-usage--record-failure
     'stub "b" (agent-usage-failure "rate-limited (HTTP 429)" 3600)
     (float-time))
    (should (agent-usage--deferred-p (agent-usage-get 'stub "a")))
    (should-not (agent-usage--deferred-p (agent-usage-get 'stub "a") nil t))
    (should (agent-usage--deferred-p (agent-usage-get 'stub "b") nil t))))

(ert-deftest agent-usage-test-response-result-normalizes-body ()
  "Pass a successful response's JSON body to the normalizer."
  (with-temp-buffer
    (insert "HTTP/1.1 200 OK\n\n{\"a\":1}")
    (goto-char (point-min))
    (search-forward "\n\n")
    (setq-local url-http-end-of-headers (point))
    (should (equal (agent-usage-response-result nil #'identity) '(:a 1)))))

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

(ert-deftest agent-usage-test-entry-marks-stale-reading-and-error ()
  "Fade a stale reading, drop windows that have reset, and show the error."
  (agent-usage-test--with-store
    (agent-usage-test--with-backend (list)
      (let ((now (float-time)))
        (puthash '(stub . "a")
                 (list :session-pct 0.0 :session-reset (+ now 3600)
                       :weekly-pct 97.0 :weekly-reset (- now 3600)
                       :fetched-at (- now 86400)
                       :error "rate-limited (HTTP 429)"
                       :retry-at (+ now 1800))
                 (agent-usage--table))
        (let ((row (cadr (agent-usage--entry 'stub "a"))))
          (should (equal (aref row 3) "0%"))
          (should (eq (get-text-property 0 'face (aref row 3)) 'shadow))
          (should (equal (aref row 4) "-"))
          (should (equal (aref row 5) ""))
          (should (equal (aref row 7) "1d"))
          (should (eq (get-text-property 0 'face (aref row 7)) 'warning))
          (should (string-prefix-p "rate-limited (HTTP 429); retry "
                                   (aref row 8))))))))

(ert-deftest agent-usage-test-age-buckets ()
  "Format ages in minutes, hours, and days."
  (let ((now (float-time)))
    (should (equal (agent-usage--age (list :fetched-at (- now 120))) "2m"))
    (should (equal (agent-usage--age (list :fetched-at (- now 7200))) "2h"))
    (should (equal (agent-usage--age (list :fetched-at (- now 172800))) "2d"))))

(provide 'agent-usage-test)
;;; agent-usage-test.el ends here
