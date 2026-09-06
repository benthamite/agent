;;; agent-directory-test.el --- Session source routing tests -*- lexical-binding: t -*-

;;; Code:

(require 'ert)
(require 'elpaca)
(require 'agent-codex)
(require 'agent-claude)

(ert-deftest agent-directory-test-launches-both-backends-in-registered-source ()
  "Resolve explicit and ambient build paths before either backend launches."
  (let* ((root (make-temp-file "agent-directory-" t))
         (build (expand-file-name "builds/package/" root))
         (source (expand-file-name "sources/shared-repository/" root))
         (entry (elpaca<--create :id 'package :build-dir build
                                :source-dir source))
         captured)
    (unwind-protect
        (progn
          (make-directory source t)
          (cl-letf (((symbol-function 'elpaca--queued)
                     (lambda () (list (cons 'package entry))))
                    ((symbol-function 'elpaca-source-dir)
                     (lambda (package)
                       (should (eq package entry))
                       source))
                    ((symbol-function 'codex--directory) (lambda () build))
                    ((symbol-function 'claude-code--directory) (lambda () build))
                    ((symbol-function 'codex-start-session)
                     (lambda (&rest keys)
                       (setq captured (plist-get keys :directory))
                       (current-buffer)))
                    ((symbol-function 'claude-code--start)
                     (lambda (&rest _)
                       (setq captured (claude-code--directory))
                       (current-buffer)))
                    ((symbol-function 'agent--set-session) #'ignore))
            (dolist (backend '(codex claude-code))
              (dolist (directory (list nil build (concat build "lisp/")
                                      "/ordinary/project/"))
                (let* ((session (agent-session-create
                                 :backend backend :directory directory))
                       (expected (if (equal directory "/ordinary/project/")
                                     directory source)))
                  (funcall (if (eq backend 'codex)
                               #'agent-codex--start-session
                             #'agent-claude--start-session)
                           session)
                  (should (equal captured expected))
                  (should (equal (agent-session-directory session) expected)))))
            (should (equal (agent--session-source-directory
                            (concat (directory-file-name build) "-other/"))
                           (concat (directory-file-name build) "-other/")))
            (delete-directory source)
            (should-error (agent--session-source-directory build)
                          :type 'user-error)))
      (delete-directory root t))))

(provide 'agent-directory-test)
;;; agent-directory-test.el ends here
