;;; agent-slack-test.el --- Tests for agent-slack -*- lexical-binding: t -*-

;; Tests for the Slack message routing helpers in agent-slack.el.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'agent-slack)

;;;; Loading

(ert-deftest agent-slack-test-loads ()
  "Loading the test file provides the `agent-slack' feature."
  (should (featurep 'agent-slack)))

;;;; Context

(ert-deftest agent-slack-test-context-is-unanchored ()
  "Describe a Slack message by its text and permalink, unsubmitted."
  (let ((context nil))
    (cl-letf (((symbol-function 'agent-slack--with-message-context)
               (lambda (callback)
                 (funcall callback '(:text "ship it" :url "https://slack/x")))))
      (agent-slack-context (lambda (c) (setq context c))))
    (should (equal (plist-get context :text) "ship it"))
    (should (equal (plist-get context :payload) "https://slack/x"))
    (should-not (plist-get context :directory))
    (should-not (plist-get context :submit))))

(provide 'agent-slack-test)
;;; agent-slack-test.el ends here
