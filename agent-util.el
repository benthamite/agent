;;; agent-util.el --- File helpers shared by agent backends -*- lexical-binding: t -*-

;; Copyright (C) 2026

;; Author: Pablo Stafforini
;; URL: https://github.com/benthamite/agent
;; Version: 0.1
;; Package-Requires: ((emacs "30.0"))

;; This file is NOT part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; File helpers that more than one backend needs.  This file depends
;; on nothing else in the package, so any module can require it.

;;; Code:

(defconst agent-util--first-line-chunk-size 65536
  "Bytes read at a time when fetching a file's first line.
A first line longer than one chunk costs another read rather than
being truncated.")

(defun agent-util-read-first-line (file)
  "Return the first line of FILE as a string, or nil when it is empty.
The file is read a chunk at a time and stops at the first newline,
because session transcripts run to megabytes but only their opening
record is needed to identify the session.  That record has no length
bound: a Claude transcript's first line can embed a whole queued
prompt.  Chunks are read as bytes and decoded once, so a chunk
boundary cannot split a character."
  (with-temp-buffer
    (set-buffer-multibyte nil)
    (let ((start 0)
          (line nil)
          (exhausted nil))
      (while (and (null line) (not exhausted))
        (goto-char (point-max))
        (let* ((end (+ start agent-util--first-line-chunk-size))
               (bytes (cadr (insert-file-contents-literally
                             file nil start end))))
          (setq start end
                exhausted (< bytes agent-util--first-line-chunk-size))
          (goto-char (point-min))
          (cond ((search-forward "\n" nil t)
                 (setq line (buffer-substring-no-properties
                             (point-min) (1- (point)))))
                (exhausted
                 (setq line (buffer-substring-no-properties
                             (point-min) (point-max)))))))
      (unless (or (null line) (string-empty-p line))
        (decode-coding-string line 'utf-8)))))

(provide 'agent-util)
;;; agent-util.el ends here
