;;; janitor-tests.el --- Janitor behavior tests -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'agent-shell-janitor)

(defvar asj-test-busy nil
  "Shells reported busy by the stubbed `shell-maker-busy'.")

(defvar-local agent-shell--state nil)

(cl-defun agent-shell-last-activity-time (&key shell-buffer)
  "Stub of agent-shell's accessor, reading SHELL-BUFFER's state."
  (alist-get :last-activity-time
             (buffer-local-value 'agent-shell--state shell-buffer)))

(defun asj-test-make-shell (name &optional idle-seconds)
  "Return a fake agent shell NAME last active IDLE-SECONDS ago.
IDLE-SECONDS nil means the shell has no recorded activity."
  (with-current-buffer (generate-new-buffer name)
    (setq major-mode 'agent-shell-mode)
    (setq-local agent-shell--state
                (list (cons :last-activity-time
                            (and idle-seconds
                                 (time-subtract nil idle-seconds)))))
    (current-buffer)))

(defmacro asj-test-with-shells (bindings &rest body)
  "Bind fake shells per BINDINGS, run BODY, then kill them.
Each binding is (VAR NAME [IDLE-SECONDS])."
  (declare (indent 1) (debug t))
  `(let* ((asj-test-busy nil)
          ,@(mapcar (lambda (binding)
                      `(,(car binding) (asj-test-make-shell ,@(cdr binding))))
                    bindings))
     (cl-letf (((symbol-function 'shell-maker-busy)
                (lambda (&rest _) (memq (current-buffer) asj-test-busy))))
       (unwind-protect
           (progn ,@body)
         (dolist (buffer (list ,@(mapcar #'car bindings)))
           (when (buffer-live-p buffer)
             (kill-buffer buffer)))))))

(defmacro asj-test-with-eyebrowse (&rest body)
  "Run BODY with the `eyebrowse' feature provided, but nothing defined."
  (declare (indent 0) (debug t))
  `(let ((saved-features features))
     (provide 'eyebrowse)
     (unwind-protect
         (progn ,@body)
       (setq features saved-features))))

(defmacro asj-test-with-workspaces (slots &rest body)
  "Run BODY with eyebrowse stubbed to have SLOTS, an alist (SLOT . NAMES).
NAMES are the buffer names each slot's layout shows, on every frame."
  (declare (indent 1) (debug t))
  `(asj-test-with-eyebrowse
     (cl-letf (((symbol-function 'eyebrowse-buffer-slots)
                (lambda (buffer &optional _frame)
                  (sort (mapcar #'car
                                (seq-filter (lambda (slot)
                                              (member (buffer-name buffer)
                                                      (cdr slot)))
                                            ,slots))
                        #'<))))
       ,@body)))

(ert-deftest asj-age-string ()
  (let ((now (current-time)))
    (should (equal (agent-shell-janitor--age-string nil now) ""))
    (should (equal (agent-shell-janitor--age-string (time-subtract now 30) now)
                   "<1m"))
    (should (equal (agent-shell-janitor--age-string (time-subtract now 300) now)
                   "5m"))
    (should (equal (agent-shell-janitor--age-string (time-subtract now 7200) now)
                   "2h"))
    (should (equal (agent-shell-janitor--age-string
                    (time-subtract now (* 3 86400)) now)
                   "3d"))
    (should (equal (agent-shell-janitor--age-string
                    (time-subtract now (* 15 86400)) now)
                   "2w"))))

(ert-deftest asj-last-activity ()
  (asj-test-with-shells ((active "active" 60)
                         (fresh "fresh"))
    (should (< 59 (float-time (time-since
                               (agent-shell-janitor-last-activity active)))
               61))
    (should-not (agent-shell-janitor-last-activity fresh))))

(ert-deftest asj-orphaned-p ()
  (asj-test-with-shells ((idle "idle" 60)
                         (busy "busy" 60)
                         (shown "shown" 60))
    (push busy asj-test-busy)
    (save-window-excursion
      (set-window-buffer (selected-window) shown)
      (should (agent-shell-janitor-orphaned-p idle))
      (should-not (agent-shell-janitor-orphaned-p busy))
      (should-not (agent-shell-janitor-orphaned-p shown)))
    (with-temp-buffer
      (should-not (agent-shell-janitor-orphaned-p (current-buffer))))))

(ert-deftest asj-workspace-slots ()
  (asj-test-with-shells ((shell "shell" 60)
                         (other "other" 60))
    (should-not (agent-shell-janitor-workspace-slots shell))
    (asj-test-with-workspaces '((3 "shell") (1 "shell" "other") (2 "x"))
      (should (equal (agent-shell-janitor-workspace-slots shell) '(1 3)))
      (should (equal (agent-shell-janitor-workspace-slots other) '(1)))
      (should-not (agent-shell-janitor-orphaned-p shell)))))

(ert-deftest asj-workspace-slots-merge-frames ()
  (asj-test-with-shells ((shell "shell" 60))
    (asj-test-with-workspaces '((3 "shell") (1 "shell"))
      (cl-letf (((symbol-function 'frame-list) (lambda () '(one two))))
        (should (equal (agent-shell-janitor-workspace-slots shell) '(1 3)))))))

(ert-deftest asj-eyebrowse-without-buffer-slots-kills-nothing ()
  (let ((agent-shell-janitor-stale-age 3600)
        (inhibit-message t))
    (asj-test-with-shells ((old "old" 7200))
      (asj-test-with-eyebrowse
        (should-not (fboundp 'eyebrowse-buffer-slots))
        (should-not (agent-shell-janitor-workspace-slots old))
        (should-not (agent-shell-janitor-orphaned-p old))
        (agent-shell-janitor-kill-stale)
        (should (buffer-live-p old))))))

(ert-deftest asj-stale-p ()
  (let ((agent-shell-janitor-stale-age 3600))
    (asj-test-with-shells ((old "old" 7200)
                           (recent "recent" 60)
                           (unknown "unknown")
                           (old-busy "old-busy" 7200))
      (push old-busy asj-test-busy)
      (should (agent-shell-janitor-stale-p old))
      (should-not (agent-shell-janitor-stale-p recent))
      (should-not (agent-shell-janitor-stale-p unknown))
      (should-not (agent-shell-janitor-stale-p old-busy)))))

(ert-deftest asj-kill-stale ()
  (let ((agent-shell-janitor-stale-age 3600)
        (inhibit-message t))
    (asj-test-with-shells ((old "old" 7200)
                           (recent "recent" 60)
                           (old-shown "old-shown" 7200))
      (with-temp-buffer
        (let ((bystander (current-buffer)))
          (setq major-mode 'fundamental-mode)
          (save-window-excursion
            (set-window-buffer (selected-window) old-shown)
            (agent-shell-janitor-kill-stale))
          (should-not (buffer-live-p old))
          (should (buffer-live-p recent))
          (should (buffer-live-p old-shown))
          (should (buffer-live-p bystander)))))))

(ert-deftest asj-list-marks-orphans ()
  (asj-test-with-shells ((orphan "orphan" 60)
                         (shown "shown" 60))
    (save-window-excursion
      ;; Listing from SHOWN's own window must not count SHOWN as orphaned
      ;; once ibuffer replaces it there.
      (set-window-buffer (selected-window) shown)
      (agent-shell-janitor-list)
      (unwind-protect
          (with-current-buffer "*Agent Shells*"
            (should (equal (ibuffer-buffer-names-with-mark
                            ibuffer-deletion-char)
                           '("orphan")))
            (dolist (name '("orphan" "shown"))
              (goto-char (point-min))
              (should (search-forward name nil t))))
        (kill-buffer "*Agent Shells*")))))

;;; janitor-tests.el ends here
