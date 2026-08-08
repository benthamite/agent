;;; agent-mu4e-test.el --- Tests for agent-mu4e -*- lexical-binding: t -*-

;; Tests for routing the email at point.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'agent-mu4e)

;;;; Loading

(ert-deftest agent-mu4e-test-loads ()
  "Loading the test file provides the `agent-mu4e' feature."
  (should (featurep 'agent-mu4e)))

;;;; Context

(ert-deftest agent-mu4e-test-context-carries-the-path-unsubmitted ()
  "Describe an email by its maildir path, unsubmitted and unanchored."
  (let ((context nil))
    (cl-letf (((symbol-function 'mu4e-message-field-at-point)
               (agent-mu4e-test--fields
                '(:path "/Mail/Inbox/cur/1786193068"
                        :subject "Quarterly numbers"
                        :from ((:email "ada@example.com" :name "Ada"))))))
      (agent-mu4e-context (lambda (c) (setq context c))))
    (should (equal (plist-get context :payload) "/Mail/Inbox/cur/1786193068"))
    (should-not (plist-get context :submit))
    (should-not (plist-get context :directory))
    (should (string-match-p "Quarterly numbers" (plist-get context :text)))
    (should (string-match-p "Ada <ada@example.com>" (plist-get context :text)))))

(ert-deftest agent-mu4e-test-context-without-a-path-signals ()
  "Signal a user error when the message records no path."
  (cl-letf (((symbol-function 'mu4e-message-field-at-point) (lambda (_) nil)))
    (should-error (agent-mu4e-context #'ignore) :type 'user-error)))

(ert-deftest agent-mu4e-test-context-with-an-empty-path-signals ()
  "Signal a user error when the path is the empty string.
`mu4e-message-field' sanitizes a missing string field to \"\", so that
is how a message without a path arrives."
  (cl-letf (((symbol-function 'mu4e-message-field-at-point)
             (agent-mu4e-test--fields '(:path "" :subject "No path"))))
    (should-error (agent-mu4e-context #'ignore) :type 'user-error)))

(ert-deftest agent-mu4e-test-context-names-a-sender-without-a-name ()
  "Name a sender that gave no display name by its address alone."
  (let ((context nil))
    (cl-letf (((symbol-function 'mu4e-message-field-at-point)
               (agent-mu4e-test--fields
                '(:path "/Mail/Inbox/cur/1" :subject "Build failed"
                        :from ((:email "ops@example.com"))))))
      (agent-mu4e-context (lambda (c) (setq context c))))
    (should (string-match-p "ops@example.com" (plist-get context :text)))
    (should-not (string-match-p "<" (plist-get context :text)))))

(ert-deftest agent-mu4e-test-context-names-every-sender ()
  "Name every sender when the message records more than one."
  (let ((context nil))
    (cl-letf (((symbol-function 'mu4e-message-field-at-point)
               (agent-mu4e-test--fields
                '(:path "/Mail/Inbox/cur/2" :subject "Two of us"
                        :from ((:email "ada@example.com" :name "Ada")
                               (:email "bo@example.com" :name "Bo"))))))
      (agent-mu4e-context (lambda (c) (setq context c))))
    (should (string-match-p "Ada <ada@example.com>" (plist-get context :text)))
    (should (string-match-p "Bo <bo@example.com>" (plist-get context :text)))))

(defun agent-mu4e-test--fields (fields)
  "Return a `mu4e-message-field-at-point' stand-in reading FIELDS.
FIELDS is a message plist shaped as mu 1.14 returns one: address fields
are lists of (:email EMAIL :name NAME) plists whose name may be absent."
  (lambda (field) (plist-get fields field)))

(provide 'agent-mu4e-test)
;;; agent-mu4e-test.el ends here
