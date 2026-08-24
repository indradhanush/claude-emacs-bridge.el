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

(defcustom claude-emacs-bridge-paste-placeholder-regexp
  "\\[[^]\n]*pasted[^]\n]*\\]"
  "Regexp matching the collapsed paste Claude Code shows for unsent input.
Claude Code renders a multi-line paste as a placeholder such as
\"[5 lines pasted]\" until the message is submitted.  The wording belongs to
Claude Code, so this is a user option rather than a constant."
  :type 'regexp
  :group 'claude-emacs-bridge)

(defcustom claude-emacs-bridge-submit-resend-interval 0.4
  "Seconds to wait for a pasted message to be submitted before resending RET."
  :type 'number
  :group 'claude-emacs-bridge)

(defcustom claude-emacs-bridge-submit-poll-interval 0.05
  "Seconds between checks of the coordinator's input box while waiting."
  :type 'number
  :group 'claude-emacs-bridge)

(defcustom claude-emacs-bridge-submit-max-resends 3
  "How many extra carriage returns a stuck paste may be given.
Bounded so a coordinator that is wedged for some other reason is not flooded."
  :type 'integer
  :group 'claude-emacs-bridge)

(defconst claude-emacs-bridge--paste-tail-window 1000
  "Characters at the end of the coordinator buffer that hold its input box.
Searching only this window keeps an old placeholder in the scrollback from
being mistaken for input that is still waiting to be sent.")

(defconst claude-emacs-bridge--startup-command
  (concat "exec env -u DO_NOT_TRACK claude "
          "--model claude-haiku-4-5-20251001 "
          "--tools SendMessage,ListAgents "
          "--strict-mcp-config "
          "--settings '{\"permissions\":{\"deny\":"
          "[\"Read(//**)\",\"Glob\",\"Grep\",\"Bash\"]}}' "
          "--name emacs-server")
  "Command used to start the coordinator in its dedicated vterm.
The coordinator only relays messages, so it is started without the tools to do
anything else.  The deny rules matter separately from the tool list: Claude Code
attaches the contents of an @path before the model runs, and a Read deny is what
stops that.  Without it a path inside an instruction meant for another session
would be read here.  Deny beats allow from every scope, so this holds whatever
the user's own settings say.")

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
  "Return reachable, named Claude sessions other than COORDINATOR-PID.
Only interactive sessions are returned.  Claude Code also lists background
agents, which carry a name and sometimes a live PID but have no inbox socket,
so the coordinator cannot deliver anything to them."
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
                   (name (alist-get 'name session))
                   (kind (alist-get 'kind session)))
               (and (equal kind "interactive")
                    (integerp pid)
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

(defun claude-emacs-bridge--escape-mentions (text)
  "Return TEXT with each at-mention escaped.
Claude Code expands @path into an attached file at input time, before the model
runs, so an unescaped path in an instruction is read by the coordinator instead
of being passed along.  A backslash stops the expansion and leaves the path
readable, which is what the target needs.

Only the instruction is escaped.  The target's own @<name> elsewhere in the
prompt is what routes the message and is left alone."
  (replace-regexp-in-string "@\\([^[:space:]]\\)" "\\\\@\\1" text t))

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
                  "Instruction: %s\n"
                  "END TARGET MESSAGE")
          (alist-get 'name session)
          file start-line end-line
          (claude-emacs-bridge--escape-mentions instruction)))

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
  "Return the running Claude Code coordinator vterm.
Offer to start it when it is not running, returning nil when declined."
  (let ((buffer (get-buffer claude-emacs-bridge-buffer-name)))
    (if (and buffer
             (buffer-local-value
              'claude-emacs-bridge--coordinator-p buffer)
             (with-current-buffer buffer
               (derived-mode-p 'vterm-mode))
             (vterm-check-proc buffer))
        buffer
      (claude-emacs-bridge--log-status
       "Claude coordinator is not running.")
      (when (y-or-n-p "Claude coordinator is not running; start it now? ")
        (claude-emacs-bridge-start)))))

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
                                "Lines: %d:%d\n"
                                "Message: %s\n\n")
                        (alist-get 'name session)
                        file start-line end-line instruction)))
      (unless (derived-mode-p 'special-mode)
        (special-mode)))
    buffer))

(defun claude-emacs-bridge--log-status (status)
  "Append STATUS to the bridge log."
  (let ((buffer (get-buffer-create
                 claude-emacs-bridge-log-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert (format "Status: %s\n\n" status)))
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
  (when-let ((coordinator (claude-emacs-bridge--coordinator-buffer)))
    (with-current-buffer coordinator
      (vterm-send-string "/clear")
      (vterm-send-return))
    (message "Sent /clear to Claude coordinator emacs-server")))

(defun claude-emacs-bridge--pending-paste-p (buffer)
  "Return non-nil for an unsubmitted paste still in BUFFER's input box."
  (with-current-buffer buffer
    (let ((case-fold-search t)
          (start (max (point-min)
                      (- (point-max)
                         claude-emacs-bridge--paste-tail-window))))
      (string-match-p claude-emacs-bridge-paste-placeholder-regexp
                      (buffer-substring-no-properties start (point-max))))))

(defun claude-emacs-bridge--wait-for-paste-clear (buffer)
  "Watch BUFFER for one resend interval.
Return non-nil as soon as its pasted input is submitted."
  (let ((deadline (+ (float-time)
                     claude-emacs-bridge-submit-resend-interval)))
    (catch 'cleared
      (while t
        (unless (claude-emacs-bridge--pending-paste-p buffer)
          (throw 'cleared t))
        (when (>= (float-time) deadline)
          (throw 'cleared nil))
        (sleep-for claude-emacs-bridge-submit-poll-interval)))))

(defun claude-emacs-bridge--await-submit (buffer)
  "Resend RET to BUFFER until its pasted message is submitted.
Return non-nil once the input box clears.  Claude Code ignores a carriage
return that arrives before it has turned a bracketed paste into pending
input, which leaves the message sitting unsent in the input box."
  (with-current-buffer buffer
    (let ((resends 0)
          (submitted nil))
      (while (and (not submitted)
                  (<= resends claude-emacs-bridge-submit-max-resends))
        (setq submitted (claude-emacs-bridge--wait-for-paste-clear buffer))
        (unless submitted
          (setq resends (1+ resends))
          (when (<= resends claude-emacs-bridge-submit-max-resends)
            (vterm-send-return))))
      submitted)))

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
  (let ((range (claude-emacs-bridge--line-range beg end))
        (file (expand-file-name buffer-file-name))
        (source-buffer (current-buffer)))
    (when-let ((coordinator (claude-emacs-bridge--coordinator-buffer)))
      (let* ((session
              (with-current-buffer source-buffer
                (claude-emacs-bridge--resolve-target)))
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
        (if (claude-emacs-bridge--await-submit coordinator)
            (message "Sent to %s: %s lines %d-%d"
                     (alist-get 'name session)
                     file
                     (car range)
                     (cdr range))
          (let ((warning
                 (format "Message to %s may not have been submitted; check %s"
                         (alist-get 'name session)
                         claude-emacs-bridge-buffer-name)))
            (claude-emacs-bridge--log-status warning)
            (message "%s" warning)))))))

(provide 'claude-emacs-bridge)
;;; claude-emacs-bridge.el ends here
