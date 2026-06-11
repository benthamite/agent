;;; agent-snippet.el --- Yasnippet expansion in AI session buffers -*- lexical-binding: t -*-

;; Copyright (C) 2026

;; Author: Pablo Stafforini
;; URL: https://github.com/benthamite/agent
;; Version: 0.1
;; Package-Requires: ((emacs "30.0") (agent "0.1"))

;; This file is NOT part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Yasnippet TAB expansion and snippet insertion for eat-based AI
;; session buffers.

;;; Code:

(require 'agent)

;;;; Forward declarations

(defvar eat-terminal)
(declare-function eat-self-input "eat" (n &optional e))
(declare-function eat-term-send-string "eat" (terminal string))

(declare-function consult--read "consult")
(declare-function consult--prefix-group "consult")
(declare-function consult--lookup-cdr "consult")
(declare-function consult-yasnippet--candidates "consult-yasnippet")
(declare-function consult-yasnippet--annotate "consult-yasnippet")

(declare-function yas--template-content "yasnippet")
(declare-function yas--template-expand-env "yasnippet")
(declare-function yas--template-key "yasnippet")
(declare-function yas--all-templates "yasnippet")
(declare-function yas--get-snippet-tables "yasnippet")
(declare-function yas-minor-mode "yasnippet")
(declare-function yas-expand-snippet "yasnippet")
(declare-function yas-active-snippets "yasnippet")
(declare-function yas--commit-snippet "yasnippet")
(declare-function map-values "map")

(defvar yas-minor-mode)
(defvar yas-prompt-functions)
(defvar yas--tables)

;;;; Snippet insertion

(defun agent-snippet--expand-to-text (template)
  "Expand yasnippet TEMPLATE to plain text in a temporary buffer."
  (with-temp-buffer
    (yas-minor-mode 1)
    (let ((yas-prompt-functions '(yas-no-prompt)))
      (yas-expand-snippet (yas--template-content template)
                          nil nil
                          (yas--template-expand-env template)))
    (mapc #'yas--commit-snippet (yas-active-snippets))
    (buffer-string)))

(defun agent-snippet--consult-yasnippet (orig-fn arg)
  "In eat-mode buffers, send snippet content via the terminal.
ORIG-FN is `consult-yasnippet'; ARG is the prefix argument."
  (if (not (derived-mode-p 'eat-mode))
      (funcall orig-fn arg)
    (let* ((candidates
            (consult-yasnippet--candidates
             (if arg
                 (progn (require 'map)
                        (yas--all-templates (map-values yas--tables)))
               (yas--all-templates (yas--get-snippet-tables)))))
           (template
            (consult--read
             candidates
             :prompt "Choose a snippet: "
             :annotate (consult-yasnippet--annotate candidates)
             :lookup 'consult--lookup-cdr
             :require-match t
             :group 'consult--prefix-group
             :category 'yasnippet)))
      (when template
        (let* ((expanded (agent-snippet--expand-to-text template))
               (text (replace-regexp-in-string "\n" "\e\r" expanded)))
          (eat-term-send-string eat-terminal text))))))

(with-eval-after-load 'consult-yasnippet
  (advice-add 'consult-yasnippet :around #'agent-snippet--consult-yasnippet))

(defun agent-snippet--try-expand-at-prompt ()
  "Try to expand a yasnippet key at the eat terminal prompt.
Search backward from `point-max' for a prompt marker, extract the
user's input, and check whether it ends with a snippet key.  If
found, erase the key and send the expanded text.  Return non-nil
if a snippet was expanded."
  (when (and (derived-mode-p 'eat-mode)
             (bound-and-true-p eat-terminal)
             (bound-and-true-p yas-minor-mode))
    (save-excursion
      (goto-char (point-max))
      (when (re-search-backward "^[❯>$][[:space:]]" nil t)
        (let* ((prompt-start (match-end 0))
               (prompt-end (progn (end-of-line) (point)))
               (input (string-trim-right
                       (buffer-substring-no-properties prompt-start prompt-end)))
               (templates (yas--all-templates (yas--get-snippet-tables)))
               (best-match nil)
               (best-key nil))
          (dolist (template templates)
            (let ((key (yas--template-key template)))
              (when (and key
                         (> (length key) 0)
                         (<= (length key) (length input))
                         (string= key (substring input (- (length input) (length key))))
                         (or (null best-key)
                             (> (length key) (length best-key))))
                (setq best-match template
                      best-key key))))
          (when best-match
            (eat-term-send-string eat-terminal
                                  (make-string (length best-key) ?\x7f))
            (let* ((expanded (agent-snippet--expand-to-text best-match))
                   (text (replace-regexp-in-string "\n" "\e\r" expanded)))
              (eat-term-send-string eat-terminal text))
            t))))))

(defun agent-snippet-tab ()
  "Try snippet expansion at prompt, otherwise send TAB to eat."
  (interactive)
  (unless (agent-snippet--try-expand-at-prompt)
    (eat-self-input 1 ?\t)))

(defvar agent-snippet--keys-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "TAB") #'agent-snippet-tab)
    (define-key map [tab] #'agent-snippet-tab)
    map)
  "Keymap for `agent-snippet--keys-mode'.")

(define-minor-mode agent-snippet--keys-mode
  "Minor mode providing yasnippet TAB expansion in AI session buffers."
  :keymap agent-snippet--keys-mode-map)

;;;###autoload
(defun agent-setup-snippet-keys ()
  "Enable yasnippet TAB expansion in the current AI session buffer."
  (when (and (agent--detect-backend (current-buffer))
             (bound-and-true-p eat-terminal)
             (require 'yasnippet nil t))
    (yas-minor-mode 1)
    (agent-snippet--keys-mode 1)))

;;;; Provide

(provide 'agent-snippet)
;;; agent-snippet.el ends here
