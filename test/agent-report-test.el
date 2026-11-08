;;; agent-report-test.el --- Tests for agent-report -*- lexical-binding: t -*-

;; Tests for filing a bug report or feature idea as a GitHub issue.

;;; Code:

(require 'ert)
(require 'agent-test-helper
         (expand-file-name "agent-test-helper"
                           (file-name-directory (or load-file-name buffer-file-name))))
(require 'agent-report)

(defmacro agent-report-test--with-gh (script &rest body)
  "Run BODY with `agent-report-gh-program' a shell script running SCRIPT.
The script's arguments and standard input are saved, and BODY sees
their file names as `args-file' and `stdin-file'."
  (declare (indent 1))
  `(let* ((dir (make-temp-file "agent-report-gh" t))
          (args-file (expand-file-name "args" dir))
          (stdin-file (expand-file-name "stdin" dir))
          (agent-report-gh-program (expand-file-name "gh" dir)))
     (unwind-protect
         (progn
           (with-temp-file agent-report-gh-program
             (insert "#!/bin/sh\n"
                     (format "printf '%%s\\n' \"$@\" > '%s'\n" args-file)
                     (format "cat > '%s'\n" stdin-file)
                     ,script "\n"))
           (set-file-modes agent-report-gh-program #o755)
           ,@body)
       (delete-directory dir t))))

(defun agent-report-test--file (text)
  "File TEXT and wait; return (success URL) or (failure MESSAGE)."
  (let (result)
    (agent-report-file text "Emacs"
                       (lambda (url) (setq result (list 'success url)))
                       (lambda (failure) (setq result (list 'failure failure))))
    (with-timeout (10 (error "The GitHub CLI never finished"))
      (while (not result)
        (accept-process-output nil 0.05)))
    result))

(ert-deftest agent-report-test-files-issue ()
  "Filing runs `gh issue create' on the repository and returns its URL."
  (agent-report-test--with-gh
      "echo 'Creating issue'; echo https://github.com/o/r/issues/7"
    (let ((agent-report-repository "o/r"))
      (should (equal (agent-report-test--file "The list flickers\nwhen sorted")
                     '(success "https://github.com/o/r/issues/7")))
      (should (equal (with-temp-buffer
                       (insert-file-contents args-file)
                       (split-string (buffer-string) "\n" t))
                     '("issue" "create" "--repo" "o/r"
                       "--title" "The list flickers" "--body-file" "-")))
      (let ((body (with-temp-buffer
                    (insert-file-contents stdin-file)
                    (buffer-string))))
        (should (string-prefix-p "The list flickers\nwhen sorted\n" body))
        (should (string-search "Reported from Emacs" body))
        (should (string-search emacs-version body))))))

(ert-deftest agent-report-test-failure-carries-gh-error ()
  "A failing GitHub CLI reports its error and how to log in."
  (agent-report-test--with-gh "echo 'not logged in' >&2; exit 1"
    (pcase-let ((`(,outcome ,message) (agent-report-test--file "x")))
      (should (eq outcome 'failure))
      (should (string-search "not logged in" message))
      (should (string-search "gh auth login" message)))))

(ert-deftest agent-report-test-missing-gh-fails-at-once ()
  "Without the GitHub CLI, filing fails with how to install it."
  (let ((agent-report-gh-program "agent-report-test-no-such-program"))
    (pcase-let ((`(,outcome ,message) (agent-report-test--file "x")))
      (should (eq outcome 'failure))
      (should (string-search "cli.github.com" message)))))

(ert-deftest agent-report-test-title-is-first-line-shortened ()
  "The title is the report's first line, cut to the title length."
  (should (equal (agent-report-title "  Short\nmore") "Short"))
  (should (= (length (agent-report-title (make-string 200 ?a)))
             agent-report--title-length)))

(ert-deftest agent-report-test-send-keeps-buffer-on-failure ()
  "A report that is not filed stays in its buffer."
  (agent-report-test--with-gh "exit 1"
    (agent-report)
    (insert "Keep me")
    (agent-report-send)
    (with-timeout (10 (error "The GitHub CLI never finished"))
      (while (get-process "agent-report-gh")
        (accept-process-output nil 0.05)))
    (should (equal (with-current-buffer agent-report--buffer-name
                     (buffer-string))
                   "Keep me"))
    (kill-buffer agent-report--buffer-name)))

(ert-deftest agent-report-test-send-refuses-empty-description ()
  "Sending an empty description is refused."
  (with-temp-buffer
    (insert "  \n")
    (should-error (agent-report-send) :type 'user-error)))

(provide 'agent-report-test)

;;; agent-report-test.el ends here
