;;; agent-snippet-test.el --- Tests for agent-snippet -*- lexical-binding: t -*-

;; Tests for the yasnippet TAB expansion helpers in agent-snippet.el.

;;; Code:

(require 'ert)
(require 'agent-snippet)

;;;; Loading

(ert-deftest agent-snippet-test-loads ()
  "Loading the test file provides the `agent-snippet' feature."
  (should (featurep 'agent-snippet)))

;;;; Keymap

(ert-deftest agent-snippet-test-tab-bound-in-keys-mode-map ()
  "Bind TAB to `agent-snippet-tab' in the snippet keys minor mode map."
  (should (eq (lookup-key agent-snippet--keys-mode-map (kbd "TAB"))
              #'agent-snippet-tab)))

(provide 'agent-snippet-test)
;;; agent-snippet-test.el ends here
