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

(require 'seq)
(require 'subr-x)

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

;;;; JSONL transcripts

(defun agent-util-jsonl-history (file bytes before after entry-messages)
  "Return the conversation in at most BYTES bytes of JSONL transcript FILE.
The stretch read ends at byte offset BEFORE, or at the end of FILE, and
starts no earlier than offset AFTER.  FILE is never read whole, however
long.  Only complete lines count, so a line cut by either end of the
stretch, or still being written, is left out, and one longer than BYTES
is never shown.

Return a plist.  `:messages' lists the conversation oldest first, each a
plist of `:role' (\"user\", \"assistant\" or \"tool\"), `:text' and
`:time'.  `:before' is the offset to pass as BEFORE for the preceding
stretch, 0 once the start of FILE is reached.  `:after' is the offset to
pass as AFTER for what follows.  `:size' is FILE's size in bytes.
`:gap' is non-nil when more than BYTES bytes followed AFTER, so the
lines between AFTER and this stretch were not read.

ENTRY-MESSAGES is called with each line parsed as a plist, JSON null
and false as nil, and returns the messages that line records.  A line
that does not parse, or on which ENTRY-MESSAGES signals, is skipped.
Each run of consecutive tool messages is merged into one."
  (let* ((truename (file-truename file))
         (size (file-attribute-size (file-attributes truename)))
         (end (min (or before size) size))
         (floor (min (or after 0) end))
         (start (max floor (- end bytes))))
    (with-temp-buffer
      (set-buffer-multibyte nil)
      (insert-file-contents-literally truename nil start end)
      (let* ((last (agent-util--last-line-end))
             (first (agent-util--first-line-start last (> start floor))))
        (list :messages (agent-util--merge-tool-messages
                         (agent-util--parse-jsonl-text
                          (decode-coding-string
                           (buffer-substring-no-properties first last)
                           'utf-8-unix t)
                          entry-messages))
              :before (if (= first last) start (+ start first -1))
              :after (+ start last -1)
              :size size
              :gap (and after (> start floor)))))))

(defun agent-util--last-line-end ()
  "Return the position just past the last newline, or `point-min' if none."
  (goto-char (point-max))
  (if (search-backward "\n" nil t)
      (1+ (point))
    (point-min)))

(defun agent-util--first-line-start (last cut)
  "Return the position where the first complete line before LAST starts.
CUT non-nil means the buffer may open in the middle of a line, which is
skipped.  Return LAST when no complete line remains."
  (goto-char (point-min))
  (cond ((not cut) (point-min))
        ((and (search-forward "\n" last t) (< (point) last)) (point))
        (t last)))

(defun agent-util--parse-jsonl-text (text entry-messages)
  "Return the messages recorded in the JSONL lines of TEXT, oldest first.
ENTRY-MESSAGES returns the messages of one parsed line.  A line that
does not parse, which includes invalid UTF-8, or that has a shape
ENTRY-MESSAGES does not expect, is skipped."
  (with-temp-buffer
    (insert text)
    (goto-char (point-min))
    (let (messages)
      (while (not (eobp))
        (let ((start (point)))
          (dolist (message (condition-case nil
                               (funcall entry-messages
                                         (json-parse-buffer :object-type 'plist
                                                            :null-object nil
                                                            :false-object nil))
                             (error nil)))
            (push message messages))
          (goto-char start)
          (forward-line 1)))
      (nreverse messages))))

(defun agent-util--merge-tool-messages (messages)
  "Return MESSAGES with each run of tool calls merged into one line."
  (let (merged run)
    (dolist (message messages)
      (if (equal (plist-get message :role) "tool")
          (push message run)
        (when run
          (push (agent-util--tool-run-message (nreverse run)) merged)
          (setq run nil))
        (push message merged)))
    (when run
      (push (agent-util--tool-run-message (nreverse run)) merged))
    (nreverse merged)))

(defun agent-util--tool-run-message (run)
  "Return one tool message summing up RUN, a list of tool messages.
Its text names each tool once, in order of first use, with a count when
it was called more than once."
  (let* ((names (mapcar (lambda (message) (plist-get message :text)) run))
         (summary (mapcar (lambda (name)
                            (let ((count (seq-count (lambda (other)
                                                      (equal other name))
                                                    names)))
                              (if (> count 1)
                                  (format "%s ×%d" name count)
                                name)))
                          (seq-uniq names))))
    (list :role "tool"
          :text (string-join summary ", ")
          :time (plist-get (car run) :time))))

(provide 'agent-util)
;;; agent-util.el ends here
