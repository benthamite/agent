;;; agent-doom-modeline-test.el --- Tests for agent-doom-modeline -*- lexical-binding: t -*-

;;; Code:

(require 'ert)
(require 'agent-test-helper
         (expand-file-name "agent-test-helper"
                           (file-name-directory (or load-file-name buffer-file-name))))
(require 'cl-lib)
(require 'agent)

(defmacro agent-doom-modeline-test--with-session (backend &rest body)
  "Run BODY in a buffer that counts as a session of BACKEND named \"proj\"."
  (declare (indent 1))
  `(with-temp-buffer
     (cl-letf (((symbol-function 'agent--detect-backend)
                (lambda (&rest _) ,backend))
               ((symbol-function 'agent-backend-icon-string)
                (lambda (&rest _) ""))
               ((symbol-function 'agent-display-name)
                (lambda (&rest _) "proj"))
               ((symbol-function 'agent-session) #'ignore)
               ((symbol-function 'agent-session-state-summary)
                (lambda (&rest _) "50% done")))
       ,@body)))

(ert-deftest agent-doom-modeline-test-loaded-with-doom-modeline ()
  "Loading `doom-modeline' defines the `ai-session' modeline."
  (skip-unless (require 'doom-modeline nil t))
  (should (featurep 'agent-doom-modeline))
  (should (fboundp 'doom-modeline-format--ai-session)))

(ert-deftest agent-doom-modeline-test-session-status ()
  "The status holds the name, model, effort and published status."
  (skip-unless (require 'doom-modeline nil t))
  (agent-doom-modeline-test--with-session 'codex
    (cl-letf (((symbol-function 'agent-codex-status-model)
               (lambda () "gpt"))
              ((symbol-function 'agent-codex-status-effort)
               (lambda () "high")))
      (should (equal (substring-no-properties
                      (agent-doom-modeline-session-status))
                     " proj | gpt | high | 50%% done ")))))

(ert-deftest agent-doom-modeline-test-session-status-omits-unknown-fields ()
  "A field with no value is left out together with its separator."
  (skip-unless (require 'doom-modeline nil t))
  (agent-doom-modeline-test--with-session 'codex
    (cl-letf (((symbol-function 'agent-codex-status-model) #'ignore)
              ((symbol-function 'agent-codex-status-effort) #'ignore)
              ((symbol-function 'agent-session-state-summary) #'ignore))
      (should (equal (substring-no-properties
                      (agent-doom-modeline-session-status))
                     " proj ")))))

(ert-deftest agent-doom-modeline-test-no-status-outside-session ()
  "A buffer that is not a session has no status."
  (skip-unless (require 'doom-modeline nil t))
  (with-temp-buffer
    (cl-letf (((symbol-function 'agent--detect-backend) #'ignore))
      (should-not (agent-doom-modeline-session-status)))))

(provide 'agent-doom-modeline-test)
;;; agent-doom-modeline-test.el ends here
