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

;;;; Resuming a session named in the message

(ert-deftest agent-slack-test-resume-context-names-the-session ()
  "A message with a resume command answers with a resume context."
  (let (context)
    (cl-letf (((symbol-function 'agent-slack--message-at-point)
               (lambda ()
                 '(:text "Needs you.\nResume: `claude --resume 0e4735ae-23ff-4f00-8dc9-bd349a863723`")))
              ((symbol-function 'agent-claude-cli-session-directory)
               (lambda (id)
                 (should (equal id "0e4735ae-23ff-4f00-8dc9-bd349a863723"))
                 "/work/proj")))
      (agent-slack-resume-context (lambda (c) (setq context c))))
    (should (equal context
                   '(:resume-id "0e4735ae-23ff-4f00-8dc9-bd349a863723"
                     :backend claude-code
                     :directory "/work/proj")))))

(ert-deftest agent-slack-test-resume-without-transcript-errors ()
  "A resume command whose transcript is missing signals a user error."
  (cl-letf (((symbol-function 'agent-slack--message-at-point)
             (lambda () '(:text "claude --resume 0e4735ae-23ff-4f00-8dc9-bd349a863723")))
            ((symbol-function 'agent-claude-cli-session-directory) #'ignore))
    (should-error (agent-slack-resume-context #'ignore) :type 'user-error)))

(provide 'agent-slack-test)
;;; agent-slack-test.el ends here
