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

(ert-deftest agent-slack-test-resume-session-id-is-parsed ()
  "Find the session id in a Claude Code resume command."
  (should (equal (agent-slack--resume-session-id
                  "needs you\nResume: `claude --resume 0e4735ae-23ff-4f00-8dc9-bd349a863723`")
                 "0e4735ae-23ff-4f00-8dc9-bd349a863723"))
  (should-not (agent-slack--resume-session-id
               "session 0e4735ae-23ff-4f00-8dc9-bd349a863723 failed"))
  (should-not (agent-slack--resume-session-id nil)))

(ert-deftest agent-slack-test-resume-message-names-the-session ()
  "A message with a resume command answers with a resume context."
  (let (context)
    (cl-letf (((symbol-function 'agent-slack--with-message-context)
               (lambda (callback)
                 (funcall callback
                          '(:text "claude --resume 0e4735ae-23ff-4f00-8dc9-bd349a863723"
                            :url "https://slack/x"))))
              ((symbol-function 'agent-claude-cli-session-directory)
               (lambda (id)
                 (should (equal id "0e4735ae-23ff-4f00-8dc9-bd349a863723"))
                 "/work/proj")))
      (agent-slack-context (lambda (c) (setq context c))))
    (should (equal context
                   '(:resume-id "0e4735ae-23ff-4f00-8dc9-bd349a863723"
                     :backend claude-code
                     :directory "/work/proj")))))

(ert-deftest agent-slack-test-resume-without-transcript-errors ()
  "A resume command whose transcript is missing signals a user error."
  (cl-letf (((symbol-function 'agent-claude-cli-session-directory)
             #'ignore))
    (should-error (agent-slack--resume-context
                   "0e4735ae-23ff-4f00-8dc9-bd349a863723")
                  :type 'user-error)))

(provide 'agent-slack-test)
;;; agent-slack-test.el ends here
