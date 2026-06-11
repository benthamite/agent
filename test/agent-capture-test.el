;;; agent-capture-test.el --- Tests for agent-capture -*- lexical-binding: t -*-

;; Tests for the prompt capture helpers in agent-capture.el.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'agent-capture)

(defun agent-capture-test--backend (&rest keys)
  "Return a minimal valid backend plist extended with KEYS."
  (append
   keys
   (list :buffer-p (lambda (_buffer) nil)
         :find-all-buffers (lambda () nil)
         :start-session #'ignore
         :label "Test")))

;;;; Loading

(ert-deftest agent-capture-test-loads ()
  "Loading the test file provides the `agent-capture' feature."
  (should (featurep 'agent-capture)))

;;;; Prompt capture

(ert-deftest agent-capture-test-prompt-capture-file-is-session-specific ()
  "Build prompt capture paths from stable session identity."
  (let ((agent-backends nil)
        (agent-prompt-capture-directory temporary-file-directory))
    (with-temp-buffer
      (rename-buffer "*one:~/repo/project/:default*" t)
      (let ((buf (current-buffer)))
        (apply #'agent-register-backend
         'one
         (agent-capture-test--backend
          :buffer-p (lambda (candidate) (eq candidate buf))))
        (setq-local agent--session
                    (agent-session-create :backend 'one :account "work"))
        (should
         (string-prefix-p
          (expand-file-name "one-" temporary-file-directory)
          (agent-capture--file 'one buf)))))))

(ert-deftest agent-capture-test-read-captured-prompts-skips-empty-and-inserted ()
  "Read pending nonempty Org prompt capture entries."
  (let ((file (make-temp-file "agent-prompts" nil ".org")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "* Empty\n")
            (insert ":PROPERTIES:\n:CREATED: [2026-05-17 Sun 10:00]\n:END:\n\n")
            (insert "* Inserted\n")
            (insert ":PROPERTIES:\n")
            (insert ":CREATED: [2026-05-17 Sun 10:01]\n")
            (insert ":INSERTED: [2026-05-17 Sun 10:02]\n")
            (insert ":END:\n\n")
            (insert "Already used\n")
            (insert "* Use this\n")
            (insert ":PROPERTIES:\n:CREATED: [2026-05-17 Sun 10:03]\n:END:\n\n")
            (insert "First line\nSecond line\n"))
          (let ((prompts (agent-capture--read-prompts file)))
            (should (= (length prompts) 1))
            (should (equal (plist-get (car prompts) :title) "Use this"))
            (should (equal (plist-get (car prompts) :text)
                           "First line\nSecond line"))))
      (delete-file file))))

(ert-deftest agent-capture-test-insert-captured-prompt-sends-selected-text ()
  "Insert the selected persisted prompt into the session."
  (let ((agent-backends nil)
        (agent-prompt-capture-directory
         (make-temp-file "agent-prompts" t))
        sent)
    (unwind-protect
        (with-temp-buffer
          (rename-buffer "*one:~/repo/project/:default*" t)
          (let ((buf (current-buffer)))
            (apply #'agent-register-backend
             'one
             (agent-capture-test--backend
              :buffer-p (lambda (candidate) (eq candidate buf))
              :find-all-buffers (lambda () (list buf))
              :send-string (lambda (text target)
                              (setq sent (list text target)))))
            (let ((file (agent-capture--file 'one buf)))
              (make-directory (file-name-directory file) t)
              (with-temp-file file
                (insert "* Prompt A\n\nAlpha\n")
                (insert "* Prompt B\n\nBeta\n")))
            (cl-letf (((symbol-function 'completing-read)
                       (lambda (_prompt candidates &rest _)
                         (cadr candidates))))
              (agent-insert-captured-prompt buf)
              (should (equal sent (list "Beta" buf)))
              (let ((pending (agent-capture--prompts 'one buf)))
                (should (= (length pending) 1))
                (should (equal (plist-get (car pending) :text) "Alpha")))
              (let ((all (agent-capture--prompts 'one buf t)))
                (should (= (length all) 1))
                (should (equal (plist-get (car all) :text) "Alpha"))))))
      (delete-directory agent-prompt-capture-directory t))))

(ert-deftest agent-capture-test-captured-prompt-candidate-previews-body ()
  "Show a truncated prompt body preview in completion candidates."
  (let* ((text (concat "First line\nSecond line with extra spacing "
                       (make-string 120 ?x)))
         (prompt (list :title "Prompt A"
                       :created "[2026-05-17 Sun 10:03]"
                       :text text))
         (candidate (agent-capture--prompt-candidate prompt)))
    (should (string-prefix-p
             "[2026-05-17 Sun 10:03] Prompt A: First line Second line"
             candidate))
    (should (string-suffix-p "..." candidate))
    (should (eq (get-text-property 0 'agent-prompt candidate) prompt))))

(provide 'agent-capture-test)
;;; agent-capture-test.el ends here
