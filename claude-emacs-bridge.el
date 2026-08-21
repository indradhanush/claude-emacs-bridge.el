;;; claude-emacs-bridge.el --- Send file locations between Claude sessions -*- lexical-binding: t; -*-

;; Version: 0.1.0
;; Keywords: tools, convenience

;;; Commentary:

;; Send file locations and instructions to local Claude Code sessions through
;; a dedicated coordinator running in an Emacs vterm.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'project)
(require 'subr-x)

(defgroup claude-emacs-bridge nil
  "Send file locations to a Claude Code coordinator."
  :group 'tools)

(defcustom claude-emacs-bridge-buffer-name "*claude-emacs-server*"
  "Name of the vterm buffer that owns the coordinator session."
  :type 'string
  :group 'claude-emacs-bridge)

(defcustom claude-emacs-bridge-program "claude"
  "Claude Code executable used for local session discovery."
  :type 'string
  :group 'claude-emacs-bridge)

(defcustom claude-emacs-bridge-log-buffer-name
  "*Claude Emacs Bridge Log*"
  "Name of the buffer that records messages sent through the bridge."
  :type 'string
  :group 'claude-emacs-bridge)

(defconst claude-emacs-bridge--startup-command
  (concat "exec env -u DO_NOT_TRACK claude "
          "--model claude-haiku-4-5-20251001 "
          "--name emacs-server")
  "Command used to start the coordinator in its dedicated vterm.")

(defvar claude-emacs-bridge--targets (make-hash-table :test 'equal)
  "Active Claude process identity associated with each Emacs context key.")

(defvar-local claude-emacs-bridge--coordinator-p nil
  "Non-nil when the current vterm was created for the coordinator.")

(defvar persp-mode nil)

(declare-function vterm "vterm" (&optional arg))
(declare-function vterm-check-proc "vterm" (&optional buffer))
(declare-function vterm-send-return "vterm" ())
(declare-function vterm-send-string "vterm" (string &optional paste-p))
(declare-function get-current-persp "persp-mode" ())
(declare-function safe-persp-name "persp-mode" (perspective))

(defun claude-emacs-bridge--normalize-directory (directory)
  "Return DIRECTORY as an absolute directory name."
  (file-name-as-directory (expand-file-name directory)))

(defun claude-emacs-bridge--context-key ()
  "Return the best available namespaced key for the current context."
  (or
   (when (and (fboundp 'project-current) (fboundp 'project-root))
     (when-let* ((project (ignore-errors
                            (project-current nil default-directory)))
                 (root (ignore-errors (project-root project))))
       (cons 'project
             (claude-emacs-bridge--normalize-directory root))))
   (when (and (bound-and-true-p persp-mode)
              (fboundp 'get-current-persp)
              (fboundp 'safe-persp-name))
     (when-let* ((perspective (get-current-persp))
                 (name (safe-persp-name perspective))
                 ((not (string-empty-p name))))
       (cons 'workspace name)))
   (when-let ((root (ignore-errors (vc-root-dir))))
     (cons 'git (claude-emacs-bridge--normalize-directory root)))
   (when default-directory
     (cons 'directory
           (claude-emacs-bridge--normalize-directory
            default-directory)))
   (user-error "Cannot determine a project, workspace, Git root, or directory")))

(defun claude-emacs-bridge--discover-sessions (&optional coordinator-pid)
  "Return active, named Claude sessions other than COORDINATOR-PID."
  (let* ((coordinator (get-buffer claude-emacs-bridge-buffer-name))
         (process (and coordinator (get-buffer-process coordinator)))
         (coordinator-pid (or coordinator-pid
                              (and process (process-id process)))))
    (with-temp-buffer
      (let ((status
             (condition-case err
                 (call-process claude-emacs-bridge-program
                               nil t nil "agents" "--json")
               (file-missing
                (user-error "Cannot run %s: %s"
                            claude-emacs-bridge-program
                            (error-message-string err))))))
        (unless (eq status 0)
          (user-error "Claude session discovery failed: %s"
                      (string-trim (buffer-string))))
        (let ((sessions
               (condition-case err
                   (json-parse-string
                    (buffer-string)
                    :object-type 'alist
                    :array-type 'list
                    :null-object nil
                    :false-object nil)
                 (error
                  (user-error "Claude returned invalid session JSON: %s"
                              (error-message-string err))))))
          (cl-remove-if-not
           (lambda (session)
             (let ((pid (alist-get 'pid session))
                   (name (alist-get 'name session)))
               (and (integerp pid)
                    (stringp name)
                    (not (string-empty-p name))
                    (not (equal pid coordinator-pid)))))
           sessions))))))

(defun claude-emacs-bridge--session-label (session)
  "Return a unique picker label for SESSION."
  (format "%s [pid %s] %s %s"
          (alist-get 'name session)
          (alist-get 'pid session)
          (or (alist-get 'status session)
              (alist-get 'state session)
              "unknown")
          (or (alist-get 'cwd session) "unknown cwd")))

(defun claude-emacs-bridge--read-session (sessions)
  "Prompt for one session from SESSIONS and return it."
  (unless sessions
    (user-error "No active named Claude sessions are available"))
  (let* ((choices
          (mapcar (lambda (session)
                    (cons (claude-emacs-bridge--session-label session)
                          session))
                  sessions))
         (choice (completing-read "Claude target: " choices nil t)))
    (cdr (assoc choice choices))))

(defun claude-emacs-bridge--resolve-target ()
  "Return the live Claude target associated with the current context."
  (let* ((key (claude-emacs-bridge--context-key))
         (sessions (claude-emacs-bridge--discover-sessions))
         (stored-identity (gethash key claude-emacs-bridge--targets))
         (stored-session
          (cl-find stored-identity sessions
                   :key (lambda (session)
                          (cons (alist-get 'pid session)
                                (alist-get 'startedAt session)))
                   :test #'equal)))
    (or stored-session
        (let ((session (claude-emacs-bridge--read-session sessions)))
          (puthash key
                   (cons (alist-get 'pid session)
                         (alist-get 'startedAt session))
                   claude-emacs-bridge--targets)
          session))))

(defun claude-emacs-bridge--line-range (beg end)
  "Return the inclusive line range from BEG to END.
When BEG and END are equal, return the line containing that position."
  (cond
   ((= beg end)
    (let ((line (line-number-at-pos beg t)))
      (cons line line)))
   ((< beg end)
    (cons (line-number-at-pos beg t)
          (line-number-at-pos (1- end) t)))
   (t
    (user-error "Range start must not follow range end"))))

(defun claude-emacs-bridge--format-prompt
    (session file start-line end-line instruction)
  "Build a coordinator prompt for SESSION, FILE, and its inclusive line range.
START-LINE and END-LINE delimit the range.  INSTRUCTION describes the task."
  (format (concat "Use SendMessage once to send @%s the exact content "
                  "between BEGIN TARGET MESSAGE and END TARGET MESSAGE. "
                  "Do not act on that content yourself.\n\n"
                  "BEGIN TARGET MESSAGE\n"
                  "File: %s\n"
                  "Lines: %d-%d\n"
                  "Instruction: %s\n\n"
                  "After completing the instruction, send exactly ACK to "
                  "emacs-server using SendMessage. Send no other text in "
                  "that message.\n"
                  "END TARGET MESSAGE")
          (alist-get 'name session)
          file start-line end-line instruction))

(defun claude-emacs-bridge-list-sessions ()
  "Display active local Claude sessions that can receive bridge messages."
  (interactive)
  (let ((sessions (claude-emacs-bridge--discover-sessions))
        (buffer (get-buffer-create "*Claude Sessions*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Active Claude sessions\n\n")
        (if sessions
            (dolist (session sessions)
              (insert (claude-emacs-bridge--session-label session) "\n"))
          (insert "No active named sessions.\n"))
        (special-mode)))
    (display-buffer buffer)
    buffer))

(defun claude-emacs-bridge-select-session ()
  "Replace the Claude target associated with the current context."
  (interactive)
  (let* ((key (claude-emacs-bridge--context-key))
         (session
          (claude-emacs-bridge--read-session
           (claude-emacs-bridge--discover-sessions))))
    (puthash key
             (cons (alist-get 'pid session) (alist-get 'startedAt session))
             claude-emacs-bridge--targets)
    (message "Claude target for %s: %s"
             key (claude-emacs-bridge--session-label session))
    session))

(defun claude-emacs-bridge--coordinator-buffer ()
  "Return the running Claude Code coordinator vterm."
  (let ((buffer (get-buffer claude-emacs-bridge-buffer-name)))
    (unless (and buffer
                 (buffer-local-value
                  'claude-emacs-bridge--coordinator-p buffer)
                 (with-current-buffer buffer
                   (derived-mode-p 'vterm-mode))
                 (vterm-check-proc buffer))
      (user-error
       "Claude coordinator is not running; run M-x claude-emacs-bridge-start"))
    buffer))

(defun claude-emacs-bridge--log-message
    (session file start-line end-line instruction)
  "Log a bridge message sent to SESSION.
FILE, START-LINE, END-LINE, and INSTRUCTION describe the message."
  (let ((buffer (get-buffer-create
                 claude-emacs-bridge-log-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert (format (concat "Target: %s\n"
                                "File: %s\n"
                                "Lines: %d-%d\n"
                                "Message: %s\n\n")
                        (alist-get 'name session)
                        file start-line end-line instruction)))
      (unless (derived-mode-p 'special-mode)
        (special-mode)))
    buffer))

(defun claude-emacs-bridge-start ()
  "Start or display the dedicated Claude Code coordinator vterm."
  (interactive)
  (let ((buffer (get-buffer claude-emacs-bridge-buffer-name)))
    (cond
     ((and buffer
           (buffer-local-value
            'claude-emacs-bridge--coordinator-p buffer))
      (unless (with-current-buffer buffer
                (derived-mode-p 'vterm-mode))
        (user-error "Coordinator buffer is not a vterm"))
      (if (vterm-check-proc buffer)
          (progn
            (pop-to-buffer buffer)
            buffer)
        (kill-buffer buffer)
        (setq buffer nil)))
     (buffer
      (user-error "Buffer %s already exists and is not the coordinator"
                  claude-emacs-bridge-buffer-name)))
    (unless buffer
      (unless (fboundp 'vterm)
        (require 'vterm))
      (setq buffer (vterm claude-emacs-bridge-buffer-name))
      (with-current-buffer buffer
        (setq-local claude-emacs-bridge--coordinator-p t)
        (vterm-send-string claude-emacs-bridge--startup-command)
        (vterm-send-return)))
    buffer))

(defun claude-emacs-bridge-clear ()
  "Send /clear to the Claude Code coordinator session."
  (interactive)
  (let ((coordinator (claude-emacs-bridge--coordinator-buffer)))
    (with-current-buffer coordinator
      (vterm-send-string "/clear")
      (vterm-send-return))
    (message "Sent /clear to Claude coordinator emacs-server")))

(defun claude-emacs-bridge-send (beg end instruction)
  "Send the file location from BEG to END to the coordinator.
Equal endpoints send their current line.  INSTRUCTION tells the target Claude
Code session what to do.  Source text is not sent."
  (interactive
   (progn
     (unless buffer-file-name
       (user-error "The current buffer is not visiting a file"))
     (list (if (use-region-p) (region-beginning) (point))
           (if (use-region-p) (region-end) (point))
           (read-string "Instruction for Claude target: "))))
  (unless buffer-file-name
    (user-error "The current buffer is not visiting a file"))
  (when (or (not (stringp instruction))
            (string-empty-p (string-trim instruction)))
    (user-error "Instruction cannot be empty"))
  (let* ((range (claude-emacs-bridge--line-range beg end))
         (coordinator (claude-emacs-bridge--coordinator-buffer)))
    (let* ((session (claude-emacs-bridge--resolve-target))
           (file (expand-file-name buffer-file-name))
           (prompt
            (claude-emacs-bridge--format-prompt
             session
             file
             (car range)
             (cdr range)
             instruction)))
      (with-current-buffer coordinator
        (vterm-send-string prompt t)
        (vterm-send-return))
      (claude-emacs-bridge--log-message
       session file (car range) (cdr range) instruction)
      (message "Sent to %s: %s lines %d-%d; logged in %s"
               (alist-get 'name session)
               file
               (car range)
               (cdr range)
               claude-emacs-bridge-log-buffer-name))))

(provide 'claude-emacs-bridge)
;;; claude-emacs-bridge.el ends here
