;;; agent-project-test.el --- Tests for agent-project -*- lexical-binding: t -*-

;; Tests for project source enumeration.

;;; Code:

(require 'ert)
(require 'agent-project)

(defmacro agent-project-test--with-tree (var specs &rest body)
  "Run BODY with VAR bound to a temporary directory built from SPECS.
The directory and everything under it are deleted when BODY finishes."
  (declare (indent 2))
  `(let ((,var (agent-project-test--make-tree ,specs)))
     (unwind-protect
         (progn ,@body)
       (delete-directory ,var t))))

(defun agent-project-test--make-tree (specs)
  "Return a temporary directory populated from SPECS.
Each spec is a cons of a relative directory name and a flag saying
whether that directory is a git repository."
  (let ((root (make-temp-file "agent-project-test" t)))
    (dolist (spec specs root)
      (let ((dir (expand-file-name (car spec) root)))
        (make-directory dir t)
        (when (cdr spec)
          (make-directory (expand-file-name ".git" dir) t))))))

(ert-deftest agent-project-test-wildcard-keeps-only-repositories ()
  "Expand a wildcard one level and drop directories without git."
  (agent-project-test--with-tree root '(("alpha" . t) ("beta" . t)
                                        ("container" . nil))
    (let ((labels (mapcar (lambda (c) (plist-get c :label))
                          (agent-project--candidates-from-pattern
                           (expand-file-name "*" root)))))
      (should (equal (sort labels #'string<) '("alpha" "beta"))))))

(ert-deftest agent-project-test-wildcard-does-not-recurse ()
  "Match one level only, leaving nested repositories out."
  (agent-project-test--with-tree root '(("outer" . t) ("outer/inner" . t))
    (let ((labels (mapcar (lambda (c) (plist-get c :label))
                          (agent-project--candidates-from-pattern
                           (expand-file-name "*" root)))))
      (should (equal labels '("outer"))))))

(ert-deftest agent-project-test-plain-path-needs-no-repository ()
  "Keep a wildcard-free path whether or not it is a repository."
  (agent-project-test--with-tree root '(("notes" . nil))
    (let* ((dir (expand-file-name "notes" root))
           (candidates (agent-project--candidates-from-pattern dir)))
      (should (= (length candidates) 1))
      (should (equal (plist-get (car candidates) :label) "notes"))
      (should (equal (plist-get (car candidates) :directory)
                     (file-name-as-directory dir))))))

(ert-deftest agent-project-test-plain-path-that-is-missing-is-dropped ()
  "Contribute nothing for a path that does not exist."
  (should-not (agent-project--candidates-from-pattern "/nonexistent/xyzzy")))

(ert-deftest agent-project-test-account-lookup-takes-the-first-match ()
  "Return the sources of the first regexp that matches the account."
  (let ((agent-project-sources '(("epoch" . ("/a")) ("" . ("/b")))))
    (should (equal (agent-project--sources-for-account "epoch") '("/a")))
    (should (equal (agent-project--sources-for-account "personal") '("/b")))
    (should (equal (agent-project--sources-for-account nil) '("/b")))))

(ert-deftest agent-project-test-candidates-are-deduplicated ()
  "Keep one candidate per true directory across sources."
  (agent-project-test--with-tree root '(("alpha" . t))
    (let* ((dir (expand-file-name "alpha" root))
           (link (expand-file-name "link" root))
           (agent-project-sources
            (list (cons "" (list dir link (expand-file-name "*" root))))))
      (make-symbolic-link dir link)
      (should (= (length (agent-project-candidates nil)) 1)))))

(ert-deftest agent-project-test-repeated-labels-become-directories ()
  "Replace a label shared by two candidates with its directory."
  (agent-project-test--with-tree one '(("notes" . t))
    (agent-project-test--with-tree two '(("notes" . t))
      (let* ((agent-project-sources
              (list (cons "" (list (expand-file-name "*" one)
                                   (expand-file-name "*" two)))))
             (labels (mapcar (lambda (c) (plist-get c :label))
                             (agent-project-candidates nil))))
        (should-not (member "notes" labels))
        (should (= (length labels) 2))))))

(provide 'agent-project-test)
;;; agent-project-test.el ends here
