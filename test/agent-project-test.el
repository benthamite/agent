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

(ert-deftest agent-project-test-character-class-counts-as-a-wildcard ()
  "Expand a `[...]' class rather than reading it as a literal name."
  (agent-project-test--with-tree root '(("alpha" . t) ("beta" . t))
    (let ((labels (mapcar (lambda (c) (plist-get c :label))
                          (agent-project--candidates-from-pattern
                           (expand-file-name "[ab]lpha" root)))))
      (should (equal labels '("alpha"))))))

(ert-deftest agent-project-test-malformed-pattern-spares-the-others ()
  "Drop a pattern that will not compile, keeping the other sources."
  (agent-project-test--with-tree root '(("alpha" . t))
    (let ((agent-project-sources
           (list (cons "" (list (expand-file-name "[unbalanced" root)
                                (expand-file-name "*" root))))))
      (should (equal (mapcar (lambda (c) (plist-get c :label))
                             (agent-project-candidates nil))
                     '("alpha"))))))

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

(defconst agent-project-test--registry-json
  "{\"projects\": [
     {\"id\": \"alpha\", \"title\": \"Alpha\", \"summary\": \"First project\",
      \"project_doc_paths\": [\"alpha/alpha.org\"],
      \"repo_paths\": [\"~/repos/epoch/alpha\"],
      \"slack_channels\": [\"#alpha\"], \"aliases\": []},
     {\"id\": \"beta\", \"title\": \"Beta\", \"project_doc_paths\": [],
      \"repo_paths\": [\"~/repos/epoch/beta\"], \"slack_channels\": [],
      \"aliases\": [\"b\"]}]}"
  "Registry JSON exercising both directory sources and both summaries.
Alpha records a doc path and a repository, so it also exercises which of
the two wins.")

(defconst agent-project-test--null-summary-json
  "{\"projects\": [
     {\"id\": \"gamma\", \"title\": \"Gamma\", \"summary\": null,
      \"project_doc_paths\": [\"gamma/gamma.org\"], \"repo_paths\": null,
      \"slack_channels\": null, \"aliases\": [\"g\"]}]}"
  "Registry JSON whose only entry records an explicit null summary.")

(defconst agent-project-test--bare-entry-json
  "{\"projects\": [
     {\"id\": \"delta\", \"title\": null, \"project_doc_paths\": [],
      \"repo_paths\": []}]}"
  "Registry JSON whose only entry records no title, paths or text.")

(defconst agent-project-test--blank-summary-json
  "{\"projects\": [
     {\"id\": \"epsilon\", \"title\": \"Epsilon\", \"summary\": \"\",
      \"project_doc_paths\": [], \"repo_paths\": [], \"slack_channels\": [],
      \"aliases\": []}]}"
  "Registry JSON whose only entry records an empty summary.")

(defmacro agent-project-test--with-registry (var json &rest body)
  "Run BODY with VAR bound to a temporary registry file holding JSON.
The file is deleted when BODY finishes."
  (declare (indent 2))
  `(let ((,var (agent-project-test--registry-file ,json)))
     (unwind-protect
         (progn ,@body)
       (delete-file ,var))))

(defun agent-project-test--registry-file (&optional json)
  "Return a temporary registry file holding JSON.
JSON defaults to `agent-project-test--registry-json'."
  (let ((file (make-temp-file "agent-project-registry" nil ".json")))
    (with-temp-file file
      (insert (or json agent-project-test--registry-json)))
    file))

(ert-deftest agent-project-test-registry-prefers-the-doc-directory ()
  "Resolve a project to its doc folder even when it records a repository."
  (agent-project-test--with-registry file nil
    (let* ((agent-project-registry-root "/tmp/projects/")
           (alpha (car (agent-project--candidates-from-registry file))))
      (should (equal (plist-get alpha :directory) "/tmp/projects/alpha/")))))

(ert-deftest agent-project-test-registry-falls-back-to-the-repository ()
  "Resolve a project to its repository when it records no doc path."
  (agent-project-test--with-registry file nil
    (let* ((agent-project-registry-root "/tmp/projects/")
           (beta (nth 1 (agent-project--candidates-from-registry file))))
      (should (equal (plist-get beta :directory)
                     (file-name-as-directory
                      (expand-file-name "~/repos/epoch/beta")))))))

(ert-deftest agent-project-test-registry-labels-and-descriptions ()
  "Label a registry project by id and title, and describe it for ranking."
  (agent-project-test--with-registry file nil
    (let* ((agent-project-registry-root "/tmp/projects/")
           (candidates (agent-project--candidates-from-registry file)))
      (should (equal (plist-get (car candidates) :label) "alpha - Alpha"))
      (should (equal (plist-get (car candidates) :description)
                     "First project; channels: #alpha"))
      (should (equal (plist-get (nth 1 candidates) :description)
                     "aliases: b")))))

(ert-deftest agent-project-test-registry-tolerates-a-null-summary ()
  "Fall back to the aliases when an entry records an explicit null summary."
  (agent-project-test--with-registry file agent-project-test--null-summary-json
    (let* ((agent-project-registry-root "/tmp/projects/")
           (gamma (car (agent-project--candidates-from-registry file))))
      (should (equal (plist-get gamma :description) "aliases: g")))))

(ert-deftest agent-project-test-registry-entry-without-paths-uses-the-root ()
  "Resolve an entry recording no paths to the registry root itself.
The root is normalized like every other candidate directory."
  (agent-project-test--with-registry file agent-project-test--bare-entry-json
    (let* ((agent-project-registry-root "~/projects")
           (delta (car (agent-project--candidates-from-registry file))))
      (should (equal (plist-get delta :directory)
                     (file-name-as-directory (expand-file-name "~/projects")))))))

(ert-deftest agent-project-test-registry-entry-without-a-title-drops-it ()
  "Label an entry by its id alone when it records no title."
  (agent-project-test--with-registry file agent-project-test--bare-entry-json
    (let* ((agent-project-registry-root "~/projects")
           (delta (car (agent-project--candidates-from-registry file))))
      (should (equal (plist-get delta :label) "delta")))))

(ert-deftest agent-project-test-registry-entry-without-text-has-no-description ()
  "Describe an entry with nil, not an empty string, when it records no text."
  (agent-project-test--with-registry file agent-project-test--bare-entry-json
    (let* ((agent-project-registry-root "~/projects")
           (delta (car (agent-project--candidates-from-registry file))))
      (should-not (plist-get delta :description)))))

(ert-deftest agent-project-test-json-source-is-read-as-a-registry ()
  "Route a source ending in .json through the registry reader."
  (agent-project-test--with-registry file nil
    (let* ((agent-project-registry-root "/tmp/projects/")
           (agent-project-sources (list (cons "" (list file))))
           (candidates (agent-project-candidates nil)))
      (should (= (length candidates) 2))
      (should (equal (plist-get (car candidates) :description)
                     "First project; channels: #alpha")))))

(ert-deftest agent-project-test-missing-registry-signals ()
  "Signal a user error when a registry source does not exist."
  (let ((agent-project-sources '(("" . ("/nonexistent/registry.json")))))
    (should-error (agent-project-candidates nil) :type 'user-error)))

(ert-deftest agent-project-test-read-skips-ranking-without-descriptions ()
  "Complete directly when no candidate carries a description."
  (agent-project-test--with-tree root '(("alpha" . t))
    (let ((agent-project-sources
           (list (cons "" (list (expand-file-name "*" root)))))
          (ranked nil)
          (chosen nil))
      (cl-letf (((symbol-function 'agent-project--rank)
                 (lambda (&rest _) (setq ranked t)))
                ((symbol-function 'completing-read)
                 (lambda (&rest _) "alpha")))
        (agent-project-read nil "some text" "Project: "
                            (lambda (dir) (setq chosen dir))))
      (should-not ranked)
      (should (equal chosen (file-name-as-directory
                             (expand-file-name "alpha" root)))))))

(ert-deftest agent-project-test-read-skips-ranking-for-a-blank-description ()
  "Complete directly when the only description a candidate carries is blank."
  (agent-project-test--with-registry file agent-project-test--blank-summary-json
    (let ((agent-project-registry-root "/tmp/projects/")
          (agent-project-sources (list (cons "" (list file))))
          (ranked nil))
      (cl-letf (((symbol-function 'agent-project--rank)
                 (lambda (&rest _) (setq ranked t)))
                ((symbol-function 'completing-read)
                 (lambda (&rest _) "epsilon - Epsilon")))
        (agent-project-read nil "some text" "Project: " #'ignore))
      (should-not ranked))))

(ert-deftest agent-project-test-read-ranks-when-descriptions-exist ()
  "Rank candidates when a registry contributed them."
  (agent-project-test--with-registry file nil
    (let ((agent-project-registry-root "/tmp/projects/")
          (agent-project-sources (list (cons "" (list file))))
          (ranked nil))
      (cl-letf (((symbol-function 'agent-project--rank)
                 (lambda (candidates _text callback)
                   (setq ranked t)
                   (funcall callback candidates)))
                ((symbol-function 'completing-read)
                 (lambda (&rest _) "alpha - Alpha")))
        (agent-project-read nil "some text" "Project: " #'ignore))
      (should ranked))))

(ert-deftest agent-project-test-read-without-text-does-not-rank ()
  "Skip ranking when the thing carries no text to rank on."
  (agent-project-test--with-registry file nil
    (let ((agent-project-registry-root "/tmp/projects/")
          (agent-project-sources (list (cons "" (list file))))
          (ranked nil))
      (cl-letf (((symbol-function 'agent-project--rank)
                 (lambda (&rest _) (setq ranked t)))
                ((symbol-function 'completing-read)
                 (lambda (&rest _) "alpha - Alpha")))
        (agent-project-read nil nil "Project: " #'ignore))
      (should-not ranked))))

(ert-deftest agent-project-test-read-with-blank-text-does-not-rank ()
  "Skip ranking when the thing's text is blank."
  (agent-project-test--with-registry file nil
    (let ((agent-project-registry-root "/tmp/projects/")
          (agent-project-sources (list (cons "" (list file))))
          (ranked nil))
      (cl-letf (((symbol-function 'agent-project--rank)
                 (lambda (&rest _) (setq ranked t)))
                ((symbol-function 'completing-read)
                 (lambda (&rest _) "alpha - Alpha")))
        (agent-project-read nil "  \n" "Project: " #'ignore))
      (should-not ranked))))

(ert-deftest agent-project-test-read-without-sources-signals ()
  "Signal a user error when the account has no configured sources."
  (let ((agent-project-sources nil))
    (should-error (agent-project-read nil nil "Project: " #'ignore)
                  :type 'user-error)))

(ert-deftest agent-project-test-ranking-failure-keeps-the-order ()
  "Report a failed ranking request and answer it with the same candidates."
  (let ((candidates (list (list :label "alpha - Alpha")
                          (list :label "beta - Beta")))
        (reported nil))
    (cl-letf (((symbol-function 'message)
               (lambda (format &rest args)
                 (setq reported (apply #'format format args)))))
      (should (eq (agent-project--ranked candidates nil '(:status "error"))
                  candidates)))
    (should (equal reported "Project ranking failed: error"))))

(ert-deftest agent-project-test-ranking-response-orders-the-candidates ()
  "Answer a ranking response with the candidates it names first."
  (let ((candidates (list (list :label "alpha - Alpha")
                          (list :label "beta - Beta"))))
    (should (equal (mapcar (lambda (c) (plist-get c :label))
                           (agent-project--ranked candidates "beta - Beta" nil))
                   '("beta - Beta" "alpha - Alpha")))))

(ert-deftest agent-project-test-ordering-follows-the-response ()
  "Order candidates by the labels the model returned, keeping the rest."
  (let ((candidates (list (list :label "alpha - Alpha")
                          (list :label "beta - Beta")
                          (list :label "gamma - Gamma"))))
    (should (equal (mapcar (lambda (c) (plist-get c :label))
                           (agent-project--ordered candidates "gamma, alpha"))
                   '("gamma - Gamma" "alpha - Alpha" "beta - Beta")))))

(ert-deftest agent-project-test-ordering-ignores-repeats-and-blanks ()
  "Offer each candidate once and ignore an empty name in the response."
  (let ((candidates (list (list :label "alpha - Alpha")
                          (list :label "beta - Beta"))))
    (should (equal (mapcar (lambda (c) (plist-get c :label))
                           (agent-project--ordered candidates "beta, beta, "))
                   '("beta - Beta" "alpha - Alpha")))))

(provide 'agent-project-test)
;;; agent-project-test.el ends here
