;;; agent-mu4e-test.el --- Tests for agent-mu4e -*- lexical-binding: t -*-

;; Tests for routing the email at point.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'agent-mu4e)

;;;; Helpers

(defmacro agent-mu4e-test--with-fields (fields &rest body)
  "Evaluate BODY with the mu4e message at point reporting FIELDS.
FIELDS is a message plist shaped as mu4e returns one: address fields are
lists of (:email EMAIL :name NAME) plists whose name may be absent.  mu4e
is reported as loaded, so the `require' in `agent-mu4e-context' is a
no-op that cannot replace the stand-in installed here, and these tests
run whether or not mu4e is installed.  `features' is not a special
variable, so a `let' would bind it lexically and leave the global list
untouched; the value cell has to be bound instead."
  (declare (indent 1) (debug (form body)))
  `(cl-letf (((symbol-value 'features) (cons 'mu4e features))
             ((symbol-function 'mu4e-message-field-at-point)
              (lambda (field) (plist-get ,fields field))))
     ,@body))

;;;; Loading

(ert-deftest agent-mu4e-test-loads ()
  "Loading the test file provides the `agent-mu4e' feature."
  (should (featurep 'agent-mu4e)))

;;;; Context

(ert-deftest agent-mu4e-test-context-carries-the-path-unsubmitted ()
  "Describe an email by its maildir path, unsubmitted and unanchored."
  (let ((path (make-temp-file "agent-mu4e-test-message"))
        (context nil))
    (unwind-protect
        (progn
          (agent-mu4e-test--with-fields
              (list :path path
                    :subject "Quarterly numbers"
                    :from '((:email "ada@example.com" :name "Ada")))
            (agent-mu4e-context (lambda (c) (setq context c))))
          (should (equal (plist-get context :payload) path))
          (should-not (plist-get context :submit))
          (should-not (plist-get context :directory))
          (should (string-match-p "Subject: Quarterly numbers"
                                  (plist-get context :text)))
          (should (string-match-p "From: Ada <ada@example\\.com>"
                                  (plist-get context :text))))
      (delete-file path))))

(ert-deftest agent-mu4e-test-context-without-mu4e-signals ()
  "Name the missing package when mu4e cannot be loaded."
  (cl-letf (((symbol-function 'require) (lambda (&rest _) nil)))
    (should (string-match-p
             "Package .mu4e. is required"
             (error-message-string
              (should-error (agent-mu4e-context #'ignore) :type 'user-error))))))

(ert-deftest agent-mu4e-test-context-without-a-path-signals ()
  "Signal a user error when the message records no path."
  (agent-mu4e-test--with-fields nil
    (should (string-match-p
             "records no file path"
             (error-message-string
              (should-error (agent-mu4e-context #'ignore) :type 'user-error))))))

(ert-deftest agent-mu4e-test-context-with-an-empty-path-signals ()
  "Signal a user error when the path is the empty string.
`mu4e-message-field' sanitizes a missing string field to \"\", so that
is how a message without a path arrives."
  (agent-mu4e-test--with-fields '(:path "" :subject "No path")
    (should (string-match-p
             "records no file path"
             (error-message-string
              (should-error (agent-mu4e-context #'ignore) :type 'user-error))))))

(ert-deftest agent-mu4e-test-context-with-an-unreadable-path-signals ()
  "Signal a user error when the recorded file cannot be read.
A maildir file name encodes the message's flags, so mu's index can name
a path that has since been renamed away."
  (let ((path (make-temp-file "agent-mu4e-test-message")))
    (delete-file path)
    (agent-mu4e-test--with-fields (list :path path :subject "Renamed away")
      (should (string-match-p
               "is not readable"
               (error-message-string
                (should-error (agent-mu4e-context #'ignore)
                              :type 'user-error)))))))

(ert-deftest agent-mu4e-test-context-names-a-sender-without-a-name ()
  "Name a sender that gave no display name by its address alone."
  (let ((path (make-temp-file "agent-mu4e-test-message"))
        (context nil))
    (unwind-protect
        (progn
          (agent-mu4e-test--with-fields
              (list :path path :subject "Build failed"
                    :from '((:email "ops@example.com")))
            (agent-mu4e-context (lambda (c) (setq context c))))
          (should (string-match-p "From: ops@example\\.com$"
                                  (plist-get context :text))))
      (delete-file path))))

(ert-deftest agent-mu4e-test-context-names-every-sender ()
  "Name every sender when the message records more than one."
  (let ((path (make-temp-file "agent-mu4e-test-message"))
        (context nil))
    (unwind-protect
        (progn
          (agent-mu4e-test--with-fields
              (list :path path :subject "Two of us"
                    :from '((:email "ada@example.com" :name "Ada")
                            (:email "bo@example.com" :name "Bo")))
            (agent-mu4e-context (lambda (c) (setq context c))))
          (should (string-match-p
                   "From: Ada <ada@example\\.com>, Bo <bo@example\\.com>$"
                   (plist-get context :text))))
      (delete-file path))))

(provide 'agent-mu4e-test)
;;; agent-mu4e-test.el ends here
