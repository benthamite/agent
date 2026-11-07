;;; agent-capture-test.el --- Tests for agent-capture -*- lexical-binding: t -*-

;; Tests for the prompt capture helpers in agent-capture.el.

;;; Code:

(require 'ert)
(require 'agent-test-helper
         (expand-file-name "agent-test-helper"
                           (file-name-directory (or load-file-name buffer-file-name))))
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

(ert-deftest agent-capture-test-open-file-leaves-point-below-new-heading ()
  "A capture buffer already shown in a window ends below the new heading."
  (let* ((file (make-temp-file "agent-capture" nil ".org"))
         (agent-prompt-capture-auto-save-delay nil))
    (unwind-protect
        (cl-letf (((symbol-function 'agent-display-name) (lambda (_) "test")))
          (save-window-excursion
            (delete-other-windows)
            (let ((session (current-buffer))
                  (capture-window (split-window-right)))
              (agent-capture--open-file file 'one session)
              (insert "First prompt")
              (set-window-point capture-window (point-min))
              (select-window (next-window capture-window))
              (switch-to-buffer session)
              (agent-capture--open-file file 'one session)
              (should (eq (selected-window) capture-window)))
            (should (= (window-point (selected-window)) (point-max)))
            (should (= (point) (point-max)))
            (should (save-excursion
                      (forward-line -2)
                      (looking-at-p ":END:")))))
      (when-let* ((buffer (find-buffer-visiting file)))
        (with-current-buffer buffer (set-buffer-modified-p nil))
        (kill-buffer buffer))
      (delete-file file))))

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

(defmacro agent-capture-test--with-session (prompts &rest body)
  "Run BODY with `buf' a session whose capture file holds PROMPTS.
PROMPTS is a list of (TITLE . TEXT).  `sent' collects what is sent."
  (declare (indent 1) (debug t))
  `(let ((agent-backends nil)
         (agent-prompt-capture-directory (make-temp-file "agent-prompts" t))
         (agent-prompt-capture-auto-save-delay nil)
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
                 (dolist (prompt ,prompts)
                   (insert "* " (car prompt) "\n:PROPERTIES:\n:CREATED: x\n:END:\n\n"
                           (cdr prompt) "\n")))
               ,@body)))
       (dolist (buffer (buffer-list))
         (when (and (buffer-file-name buffer)
                    (string-prefix-p agent-prompt-capture-directory
                                     (buffer-file-name buffer)))
           (with-current-buffer buffer (set-buffer-modified-p nil))
           (kill-buffer buffer)))
       (delete-directory agent-prompt-capture-directory t))))

(ert-deftest agent-capture-test-insert-all-sends-numbered-list ()
  "Insert every pending prompt as one numbered message and clear them."
  (agent-capture-test--with-session '(("Prompt A" . "Alpha\nsecond line")
                                      ("Prompt B" . "Beta"))
    (agent-insert-all-captured-prompts buf)
    (should (equal sent (list "1. Alpha\n   second line\n\n2. Beta" buf)))
    (should-not (agent-capture--prompts 'one buf t))))

(ert-deftest agent-capture-test-insert-all-single-prompt-is-plain ()
  "A single pending prompt is inserted without a number."
  (agent-capture-test--with-session '(("Prompt A" . "Alpha"))
    (agent-insert-all-captured-prompts buf)
    (should (equal sent (list "Alpha" buf)))))

(ert-deftest agent-capture-test-insert-all-uses-selected-headings ()
  "From a capture file, an active region limits the prompts to its headings."
  (agent-capture-test--with-session '(("Prompt A" . "Alpha")
                                      ("Prompt B" . "Beta")
                                      ("Prompt C" . "Gamma"))
    (let ((session buf))
      (with-current-buffer (find-file-noselect (agent-capture--file 'one session))
        (org-mode)
        (agent-prompt-capture-mode 1)
        (transient-mark-mode 1)
        (goto-char (point-min))
        (search-forward "* Prompt B")
        (beginning-of-line)
        (push-mark (point) t t)
        (search-forward "Gamma")
        (cl-letf (((symbol-function 'pop-to-buffer) #'ignore))
          (agent-insert-all-captured-prompts))
        (should (equal sent (list "1. Beta\n\n2. Gamma" session)))
        (should (equal (mapcar (lambda (p) (plist-get p :text))
                               (agent-capture--prompts 'one session t))
                       '("Alpha")))))))

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
