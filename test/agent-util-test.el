;;; agent-util-test.el --- Tests for agent-util -*- lexical-binding: t -*-

;;; Commentary:

;; Tests for the file helpers in agent-util.el.

;;; Code:

(require 'ert)
(require 'agent-util)

(defmacro agent-util-test--with-file (contents &rest body)
  "Bind `file' to a temporary file holding CONTENTS and run BODY."
  (declare (indent 1))
  `(let ((file (make-temp-file "agent-util-test" nil nil ,contents)))
     (unwind-protect (progn ,@body)
       (delete-file file))))

(ert-deftest agent-util-test-read-first-line-stops-at-newline ()
  "Return only the text before the first newline."
  (agent-util-test--with-file "one\ntwo\n"
    (should (equal (agent-util-read-first-line file) "one"))))

(ert-deftest agent-util-test-read-first-line-spans-chunks ()
  "Read a first line longer than one chunk whole.
The multibyte character straddles the chunk boundary, so decoding each
chunk separately would corrupt it."
  (let ((line (concat (make-string (1- agent-util--first-line-chunk-size) ?x)
                      "é" (make-string 10 ?y))))
    (agent-util-test--with-file (encode-coding-string
                                 (concat line "\nnext\n") 'utf-8)
      (should (equal (agent-util-read-first-line file) line)))))

(ert-deftest agent-util-test-read-first-line-without-newline ()
  "Return the whole file when it has no newline."
  (agent-util-test--with-file "only"
    (should (equal (agent-util-read-first-line file) "only"))))

(ert-deftest agent-util-test-read-first-line-empty ()
  "Return nil for an empty file or an empty first line."
  (agent-util-test--with-file ""
    (should-not (agent-util-read-first-line file)))
  (agent-util-test--with-file "\nsecond\n"
    (should-not (agent-util-read-first-line file))))

(provide 'agent-util-test)
;;; agent-util-test.el ends here
