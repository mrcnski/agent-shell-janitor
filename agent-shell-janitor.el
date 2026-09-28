;;; agent-shell-janitor.el --- List and clean up idle agent shells -*- lexical-binding: t; -*-

;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (agent-shell "0.76.1"))
;; Keywords: tools, convenience
;; SPDX-License-Identifier: GPL-3.0-or-later

;;; Commentary:

;; `agent-shell-janitor-list' lists agent shells in ibuffer, with orphans
;; marked for deletion.  `agent-shell-janitor-kill-stale' kills orphans that
;; have been idle for `agent-shell-janitor-stale-age'; put it on
;; `midnight-hook' to run it daily.
;;
;; An orphan is an idle shell that no live window and no eyebrowse workspace
;; shows.  Idle time comes from agent-shell's last-activity time rather than
;; `buffer-display-time', which eyebrowse resets for every buffer in a
;; workspace on each switch.
;;
;; Workspace awareness needs `eyebrowse-buffer-slots', from the fork at
;; https://github.com/mrcnski/eyebrowse.  With an eyebrowse that lacks it, no
;; shell counts as orphaned, so none are marked or killed.

;;; Code:

(require 'ibuffer)
(require 'ibuf-ext)
(require 'ibuf-macs)
(require 'map)
(require 'seq)
(require 'cl-lib)

(defvar agent-shell--state)
(defvar shell-maker-prompt-before-killing-buffer)
(declare-function shell-maker-busy "shell-maker")
(declare-function eyebrowse-buffer-slots "eyebrowse")

(defgroup agent-shell-janitor nil
  "List and clean up idle agent shells."
  :group 'agent-shell)

(defcustom agent-shell-janitor-stale-age (* 24 60 60)
  "Seconds an orphaned shell must be idle before it counts as stale."
  :type 'natnum)

(defcustom agent-shell-janitor-ibuffer-format
  '(mark modified " "
         (name :width :width :left)
         " " (size 8 -1 :right)
         " " (agent-shell-janitor-idle 4 -1 :right)
         " " (agent-shell-janitor-workspaces 5 -1 :left)
         " " filename-and-process)
  "Line format for `agent-shell-janitor-list', as in `ibuffer-formats'.
Each `:width' is replaced with the length of the longest shell name."
  :type 'sexp)

(defun agent-shell-janitor--shells ()
  "Return the live agent shell buffers."
  (seq-filter (lambda (buffer)
                (with-current-buffer buffer
                  (derived-mode-p 'agent-shell-mode)))
              (buffer-list)))

(defun agent-shell-janitor--age-string (time &optional now)
  "Format the time from TIME to NOW as a short age, e.g. \"5m\".
TIME nil gives \"\".  NOW defaults to the current time."
  (if (null time)
      ""
    (let* ((secs (float-time (time-subtract now time)))
           (mins (floor secs 60))
           (hrs (floor secs 3600))
           (days (floor secs 86400)))
      (cond ((< mins 1) "<1m")
            ((< hrs 1) (format "%dm" mins))
            ((< days 1) (format "%dh" hrs))
            ((< days 7) (format "%dd" days))
            (t (format "%dw" (floor days 7)))))))

(defun agent-shell-janitor-last-activity (buffer)
  "Time of the last prompt or agent message in shell BUFFER, or nil.
Reads agent-shell's internal state; there is no public accessor."
  (map-elt (buffer-local-value 'agent-shell--state buffer)
           :last-activity-time))

(defun agent-shell-janitor--workspaces-known-p ()
  "Non-nil unless eyebrowse is loaded without `eyebrowse-buffer-slots'."
  (or (not (featurep 'eyebrowse))
      (fboundp 'eyebrowse-buffer-slots)))

(defun agent-shell-janitor-workspace-slots (buffer)
  "Eyebrowse slots, on any frame, whose layout shows BUFFER."
  (when (and (featurep 'eyebrowse)
             (fboundp 'eyebrowse-buffer-slots))
    (sort (seq-uniq (mapcan (lambda (frame)
                              (eyebrowse-buffer-slots buffer frame))
                            (frame-list)))
          #'<)))

(defun agent-shell-janitor-orphaned-p (buffer)
  "Non-nil if BUFFER is an idle agent shell no window or workspace shows."
  (with-current-buffer buffer
    (and (derived-mode-p 'agent-shell-mode)
         (not (shell-maker-busy))
         (not (get-buffer-window buffer t))
         (agent-shell-janitor--workspaces-known-p)
         (null (agent-shell-janitor-workspace-slots buffer)))))

(defun agent-shell-janitor-stale-p (buffer)
  "Non-nil if BUFFER is orphaned and idle for `agent-shell-janitor-stale-age'."
  (and (agent-shell-janitor-orphaned-p buffer)
       (when-let* ((time (agent-shell-janitor-last-activity buffer)))
         (> (float-time (time-since time)) agent-shell-janitor-stale-age))))

(define-ibuffer-column agent-shell-janitor-idle
  (:name "Idle" :inline t)
  (agent-shell-janitor--age-string (agent-shell-janitor-last-activity buffer)))

(define-ibuffer-column agent-shell-janitor-workspaces
  (:name "WS" :inline t)
  (if (agent-shell-janitor--workspaces-known-p)
      (mapconcat #'number-to-string
                 (agent-shell-janitor-workspace-slots buffer) ",")
    "?"))

;;;###autoload
(defun agent-shell-janitor-list ()
  "List agent shells in ibuffer, with orphans marked for deletion.
The Idle column is time since the shell last changed.  WS lists the
eyebrowse workspaces that show it."
  (interactive)
  (let* ((shells (agent-shell-janitor--shells))
         (width (apply #'max 16 (mapcar (lambda (buffer)
                                          (length (buffer-name buffer)))
                                        shells)))
         ;; Decided before ibuffer takes over the selected window, which may
         ;; be showing a shell.
         (orphans (seq-filter #'agent-shell-janitor-orphaned-p shells)))
    (ibuffer nil "*Agent Shells*" '((derived-mode . agent-shell-mode))
             nil nil nil
             (list (cl-subst width :width agent-shell-janitor-ibuffer-format)))
    (ibuffer-mark-on-buffer (lambda (buffer) (memq buffer orphans))
                            ibuffer-deletion-char)))

;;;###autoload
(defun agent-shell-janitor-kill-stale ()
  "Kill orphaned agent shells idle for `agent-shell-janitor-stale-age'."
  (interactive)
  (dolist (buffer (agent-shell-janitor--shells))
    (when (and (buffer-live-p buffer)
               (agent-shell-janitor-stale-p buffer))
      ;; shell-maker would otherwise ask to save its own transcript.
      (let ((shell-maker-prompt-before-killing-buffer nil))
        (message "[%s] killing stale shell `%s'"
                 (format-time-string "%F %T") (buffer-name buffer))
        (kill-buffer buffer)))))

(provide 'agent-shell-janitor)
;;; agent-shell-janitor.el ends here
