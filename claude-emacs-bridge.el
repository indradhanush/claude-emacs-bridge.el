;;; claude-emacs-bridge.el --- Send file locations between Claude sessions -*- lexical-binding: t; -*-

;; Version: 0.1.0
;; Keywords: tools, convenience

;;; Commentary:

;; Send file locations and instructions to local Claude Code sessions over
;; their inbox sockets.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'org)
(require 'project)
(require 'subr-x)
(require 'url-util)

(defgroup claude-emacs-bridge nil
  "Send file locations to a Claude Code session."
  :group 'tools)

(defcustom claude-emacs-bridge-log-buffer-name
  "*Claude Emacs Bridge Log*"
  "Name of the buffer that records messages sent through the bridge."
  :type 'string
  :group 'claude-emacs-bridge)

(defcustom claude-emacs-bridge-projects-directory
  (expand-file-name "~/.claude/projects/")
  "Directory holding the per-session transcripts Claude Code writes.
A session records a queue entry here when a message is admitted, and that
entry is how a send is confirmed."
  :type 'directory
  :group 'claude-emacs-bridge)

(defcustom claude-emacs-bridge-confirm-timeout 0.5
  "Seconds to wait for a target to record that it queued a message.
Plan 04 measured the entry appearing within milliseconds, with the writer
flushing on its own interval.  This is several times that."
  :type 'number
  :group 'claude-emacs-bridge)

(defcustom claude-emacs-bridge-confirm-poll-interval 0.05
  "Seconds between reads of a target's transcript while confirming a send."
  :type 'number
  :group 'claude-emacs-bridge)

(defcustom claude-emacs-bridge-socket-directory "/tmp/cc-socks/"
  "Directory holding Claude Code's inbox sockets.
The bridge binds its own receipt socket here.  A recipient checks that a
reach-back address lives in this directory before connecting to it, so the
socket cannot be put anywhere more private.  The filename is ours to choose."
  :type 'directory
  :group 'claude-emacs-bridge)

(defcustom claude-emacs-bridge-registry-directory
  (expand-file-name "~/.claude/sessions/")
  "Directory holding the per-session registry files Claude Code writes.
Each file describes one session and carries the fields the socket mode
needs: the inbox socket path, and the session id and working directory a
transcript is found from."
  :type 'directory
  :group 'claude-emacs-bridge)

(defcustom claude-emacs-bridge-log-frames nil
  "Whether to log the exact bytes written to a target's socket.
A rendered summary of a frame is built from the same values the frame was,
so it cannot show a field serialised wrongly, a missing newline, or an
encoding fault.  The frame itself can.  Worth keeping on while the socket
mode is new.  The frame holds the file path and the instruction, both of
which the log already records."
  :type 'boolean
  :group 'claude-emacs-bridge)

(defcustom claude-emacs-bridge-log-file
  (expand-file-name "claude-emacs-bridge.log" user-emacs-directory)
  "File the log is appended to, or nil to keep it in the buffer alone.
A buffer dies with Emacs and cannot answer \"it was working yesterday\".
This is the same content the log buffer already holds, so setting it
changes how long that content lives rather than what is exposed.  Setting
it to nil restores the buffer-only behaviour exactly."
  :type '(choice (const :tag "Buffer only" nil) file)
  :group 'claude-emacs-bridge)

(defvar claude-emacs-bridge-queue-mode nil
  "Non-nil when `claude-emacs-bridge-send' queues instead of sending.
Orthogonal to the delivery mode: this decides when a send happens, not how
it is delivered.  Toggle with `claude-emacs-bridge-toggle-queue-mode'.")

(defvar claude-emacs-bridge--queue nil
  "Queued entries awaiting `claude-emacs-bridge-send-queue', oldest first.
Each entry is a plist with :file :start-line :end-line :start-col :end-col
:instruction :lines.  :lines is the snippet text captured at queue time, kept
only so `claude-emacs-bridge-show-queue' has something to display; it is
never part of what a flush sends.")

(defvar claude-emacs-bridge--targets (make-hash-table :test 'equal)
  "Active Claude process identity associated with each Emacs context key.")

(defvar persp-mode nil)

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

(defun claude-emacs-bridge--registry-row (file)
  "Return the session alist in registry FILE, or nil when it is unusable."
  (condition-case nil
      (with-temp-buffer
        (insert-file-contents file)
        (let* ((row (json-parse-string (buffer-string)
                                       :object-type 'alist
                                       :array-type 'list
                                       :null-object nil
                                       :false-object nil))
               (socket (alist-get 'messagingSocketPath row))
               (name (alist-get 'name row))
               (pid (alist-get 'pid row)))
          (when (and (stringp socket)
                     (not (string-empty-p socket))
                     ;; A row outlives the session that wrote it.  The socket
                     ;; going away is the cheapest sign the session has too.
                     (file-exists-p socket)
                     (stringp name)
                     (not (string-empty-p name))
                     (integerp pid)
                     (stringp (alist-get 'sessionId row))
                     (stringp (alist-get 'cwd row)))
            row)))
    (error nil)))

(defun claude-emacs-bridge--registry-sessions ()
  "Return the sessions in `claude-emacs-bridge-registry-directory'.
A row is kept only when it can actually be delivered to and located later:
it must name an inbox socket that exists, and carry a name, a PID, a session
id and a working directory.  A session with no socket is dropped for the same
reason the CLI path drops background agents."
  (when (file-directory-p claude-emacs-bridge-registry-directory)
    (delq nil
          (mapcar #'claude-emacs-bridge--registry-row
                  (directory-files
                   claude-emacs-bridge-registry-directory t "\\.json\\'" t)))))

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
         (sessions (claude-emacs-bridge--registry-sessions))
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

(defun claude-emacs-bridge--missing-resource (missing)
  "Signal that MISSING is unavailable."
  (user-error "%s is unavailable" missing))

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

(defun claude-emacs-bridge--column-range (beg end)
  "Return the 0-indexed column range from BEG to END.
The target needs this to place a one-line selection inside its line, and to
know where a multi-line selection starts and ends on its first and last
lines.  `claude-emacs-bridge--line-range' only carries whole line numbers, so
a partial-line selection would otherwise read as spanning the full line."
  (cons (save-excursion (goto-char beg) (current-column))
        (save-excursion (goto-char end) (current-column))))

(defconst claude-emacs-bridge--send-record-ttl 60
  "Seconds a send is remembered for, so a late frame can still name it.
Plan 04 measured the recipient reporting further drops in a sixty-second
window, batched about five seconds behind.  Nothing is expected after that.")

(defvar claude-emacs-bridge--sends (make-hash-table :test 'equal)
  "Sends this Emacs has made, keyed by message id.
A failure can be reported seconds after a send gave up waiting, so the record
outlives the send and lets a late frame name the file and lines it concerns
instead of only an id.")

(defvar claude-emacs-bridge--receipts (make-hash-table :test 'equal)
  "Frames that arrived while their send was still waiting for one.")

(defvar claude-emacs-bridge--receipt-process nil
  "The listening socket failures are reported back on, or nil.")

(defun claude-emacs-bridge--receipt-socket-path ()
  "Return the path this Emacs listens for failure reports on.
The name carries the Emacs PID, so a file already at this path was left by a
process that is gone and can be replaced without asking."
  (expand-file-name (format "emacs-bridge-%d.sock" (emacs-pid))
                    claude-emacs-bridge-socket-directory))

(defun claude-emacs-bridge--receipt-filter (process output)
  "Handle OUTPUT arriving on the receipt socket PROCESS.
Frames are newline-delimited, and a read can split one, so a partial line is
kept until its newline arrives."
  (let ((buffered (concat (or (process-get process 'partial) "") output)))
    (while (string-match "\\`\\([^\n]*\\)\n" buffered)
      (let ((line (match-string 1 buffered)))
        (setq buffered (substring buffered (match-end 0)))
        (when-let ((frame (claude-emacs-bridge--parse-receipt line)))
          (claude-emacs-bridge--handle-receipt frame))))
    (process-put process 'partial buffered)))

(defun claude-emacs-bridge--ensure-receipt-socket ()
  "Return the receipt socket path, binding the socket when it is not up yet.
Bound once and kept for the life of this Emacs.  A socket that only lived for
one send would miss the batched drop frame entirely, which does not merely
lose a report: it makes that failure unobservable."
  (unless (process-live-p claude-emacs-bridge--receipt-process)
    (let ((path (claude-emacs-bridge--receipt-socket-path)))
      ;; The directory belongs to Claude Code.  Creating it would fabricate a
      ;; namespace nothing is listening in, and an empty picker would be the
      ;; only symptom.  A missing directory is its own problem, so say so.
      (unless (file-directory-p claude-emacs-bridge-socket-directory)
        (claude-emacs-bridge--missing-resource
         claude-emacs-bridge-socket-directory))
      (when (file-exists-p path)
        (ignore-errors (delete-file path)))
      (setq claude-emacs-bridge--receipt-process
            (make-network-process
             :name "claude-emacs-bridge-receipts"
             :server t
             :family 'local
             :service path
             :coding 'utf-8-unix
             :noquery t
             :filter #'claude-emacs-bridge--receipt-filter
             :log (lambda (&rest _) nil)))
      (add-hook 'kill-emacs-hook
                #'claude-emacs-bridge--release-receipt-socket)))
  (claude-emacs-bridge--receipt-socket-path))

(defun claude-emacs-bridge--release-receipt-socket ()
  "Stop listening for failure reports and remove the socket file."
  (when claude-emacs-bridge--receipt-process
    (ignore-errors (delete-process claude-emacs-bridge--receipt-process))
    (setq claude-emacs-bridge--receipt-process nil))
  (let ((path (claude-emacs-bridge--receipt-socket-path)))
    (when (file-exists-p path)
      (ignore-errors (delete-file path)))))

(defun claude-emacs-bridge--prune-sends ()
  "Forget sends older than `claude-emacs-bridge--send-record-ttl'."
  (let ((cutoff (- (float-time) claude-emacs-bridge--send-record-ttl)))
    (maphash (lambda (id record)
               (when (< (or (alist-get 'time record) 0) cutoff)
                 (remhash id claude-emacs-bridge--sends)))
             claude-emacs-bridge--sends)))

(defun claude-emacs-bridge--remember-send (id record)
  "Remember RECORD under send ID so a late frame can name what it concerns."
  (claude-emacs-bridge--prune-sends)
  (puthash id (cons (cons 'time (float-time)) record)
           claude-emacs-bridge--sends))

(defun claude-emacs-bridge--finish-send (id)
  "Mark send ID as no longer waiting for a report of its own.
A report arriving after this is late, and says so."
  (when-let ((record (gethash id claude-emacs-bridge--sends)))
    (puthash id (assq-delete-all 'pending record) claude-emacs-bridge--sends)))

(defun claude-emacs-bridge--parse-receipt (line)
  "Return LINE parsed as a status frame, or nil when it is not one."
  (when (and (stringp line) (not (string-empty-p (string-trim line))))
    (condition-case nil
        (let ((frame (json-parse-string line
                                        :object-type 'alist
                                        :array-type 'list
                                        :null-object nil
                                        :false-object nil)))
          ;; A JSON array parses to a list of scalars, so an object is
          ;; recognised by its first element being a key and value pair.
          (and (consp frame)
               (consp (car frame))
               (stringp (alist-get 'status frame))
               frame))
      (error nil))))

(defun claude-emacs-bridge--receipt-reason (frame)
  "Return the text FRAME gives for what happened, written for a human."
  (or (alist-get 'reason frame)
      (alist-get 'status_detail frame)
      (alist-get 'drop_reason frame)
      (alist-get 'status frame)))

(defun claude-emacs-bridge--handle-receipt (frame)
  "Record FRAME, and say so when it arrives too late for its send to report it."
  (let* ((id (alist-get 'orig_msg_id frame))
         (record (and id (gethash id claude-emacs-bridge--sends))))
    (cond
     ;; Still waiting: the send reports this itself, in its own outcome.
     ((alist-get 'pending record)
      (puthash id frame claude-emacs-bridge--receipts))
     (record
      (claude-emacs-bridge--log-event
       'receipt
       :id id
       :late "yes"
       :status (alist-get 'status frame)
       :status_detail (alist-get 'status_detail frame)
       :drop_reason (alist-get 'drop_reason frame)
       :target (alist-get 'target record)
       :file (alist-get 'file record)
       :lines (alist-get 'lines record)
       :reason (alist-get 'reason frame))
      ;; A send that already said unconfirmed has no other way to correct
      ;; itself, so this is worth one line in the echo area.
      (message "Bridge: %s %s lines %s: %s"
               (alist-get 'status frame)
               (alist-get 'file record)
               (alist-get 'lines record)
               (claude-emacs-bridge--receipt-reason frame)))
     (t
      ;; An unknown frame is the evidence for a failure nobody has seen yet.
      (claude-emacs-bridge--log-event
       'receipt
       :uncorrelated "yes"
       :id id
       :status (alist-get 'status frame)
       :frame (json-encode frame))))))

(defun claude-emacs-bridge--combined-entries-body (entries &optional instruction-fn)
  "Return ENTRIES rendered as numbered \"Entry N\" blocks, one flush's body.
Each block reuses `claude-emacs-bridge--socket-content' for its own field
formatting, so this only adds the heading and the blank-line separation
between entries.  INSTRUCTION-FN, when given, transforms each entry's
instruction before it is formatted; `claude-emacs-bridge--combined-socket-content'
passes none."
  (let ((index 0))
    (mapconcat
     (lambda (entry)
       (setq index (1+ index))
       (format "Entry %d\n%s"
               index
               (claude-emacs-bridge--socket-content
                (plist-get entry :file)
                (cons (plist-get entry :start-line) (plist-get entry :end-line))
                (cons (plist-get entry :start-col) (plist-get entry :end-col))
                (if instruction-fn
                    (funcall instruction-fn (plist-get entry :instruction))
                  (plist-get entry :instruction)))))
     entries "\n\n")))

(defun claude-emacs-bridge--combined-socket-content (entries)
  "Return the combined socket content for ENTRIES, one queue flush's payload."
  (claude-emacs-bridge--combined-entries-body entries))

(defun claude-emacs-bridge--socket-content (file start-end col-range instruction)
  "Return the text a target receives for FILE over START-END, with INSTRUCTION.
COL-RANGE gives the 0-indexed columns the selection starts and ends at on
those lines.  Nothing wraps it; a socket message is delivered by address, so
it carries only what the target needs to act on."
  (format "File: %s\nLines: %d-%d\nColumns: %d-%d\nInstruction: %s"
          file (car start-end) (cdr start-end)
          (car col-range) (cdr col-range)
          instruction))

(defun claude-emacs-bridge--uds-address (socket)
  "Return the address a recipient can reach back on, for SOCKET."
  (concat "uds:" (url-hexify-string socket)))

(defun claude-emacs-bridge--socket-frame (content msg-id from)
  "Return the frame carrying CONTENT, tagged MSG-ID and answerable at FROM.
The wire format is newline-delimited JSON, so this is one object and one
newline.  FROM is optional: without it the recipient has nowhere to report a
failure, and the send can only ever be confirmed from the target's transcript."
  (concat
   (json-encode
    (append
     `((type . "user")
       (msgV . 1)
       (msg_id . ,msg-id))
     (when from `((from . ,from)))
     `((message . ((content . ,content))))))
   "\n"))

(defun claude-emacs-bridge-list-sessions ()
  "Display active local Claude sessions that can receive bridge messages."
  (interactive)
  (let ((sessions (claude-emacs-bridge--registry-sessions))
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
           (claude-emacs-bridge--registry-sessions))))
    (puthash key
             (cons (alist-get 'pid session) (alist-get 'startedAt session))
             claude-emacs-bridge--targets)
    (message "Claude target for %s: %s"
             key (claude-emacs-bridge--session-label session))
    session))

(defun claude-emacs-bridge--uuid ()
  "Return a random version 4 UUID as a string."
  (format "%08x-%04x-4%03x-%x%03x-%08x%04x"
          (random (expt 16 8))
          (random (expt 16 4))
          (random (expt 16 3))
          (+ 8 (random 4))
          (random (expt 16 3))
          (random (expt 16 8))
          (random (expt 16 4))))

(defun claude-emacs-bridge--log-value (value)
  "Render VALUE as one log field value.
Anything holding whitespace or a quote is written as a quoted string, so a
multi-line payload stays on the single line its event occupies."
  (let ((text (if (stringp value) value (format "%s" value))))
    (if (string-match-p "\\`[^ \t\n\"\\\\]+\\'" text)
        text
      ;; `prin1-to-string' leaves a newline as a newline, which would split
      ;; the entry across lines.  Escape them so the event stays on one.
      (concat "\""
              (replace-regexp-in-string
               "[\\\\\"\n\t]"
               (lambda (match)
                 (pcase match
                   ("\\" "\\\\")
                   ("\"" "\\\"")
                   ("\n" "\\n")
                   ("\t" "\\t")
                   (_ match)))
               text t t)
              "\""))))

(defun claude-emacs-bridge--log-event (event &rest fields)
  "Append EVENT to the bridge log with FIELDS, a plist of keys and values.
One event is one line, so every entry for a send can be found with a single
search.  A field whose value is nil is left out rather than logged empty."
  (let* ((rendered
          (let ((parts '())
                (rest fields))
            (while rest
              (let ((key (pop rest))
                    (value (pop rest)))
                (when value
                  (push (format " %s=%s"
                                (substring (symbol-name key) 1)
                                (claude-emacs-bridge--log-value value))
                        parts))))
            (apply #'concat (nreverse parts))))
         (line (concat (format-time-string "%Y-%m-%dT%H:%M:%S%z")
                       " " (symbol-name event) rendered "\n"))
         (buffer (get-buffer-create claude-emacs-bridge-log-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (goto-char (point-max))
        (insert line))
      (unless (derived-mode-p 'special-mode)
        (special-mode)))
    (when claude-emacs-bridge-log-file
      (condition-case nil
          (write-region line nil claude-emacs-bridge-log-file t 'silent)
        (file-error nil)))
    buffer))

(defun claude-emacs-bridge--log-send
    (id transport session file range content socket frame)
  "Record that a message went out, under send ID over TRANSPORT.
SESSION names the target, FILE and RANGE the location, and CONTENT the bytes
actually sent rather than the ones intended.  SOCKET and FRAME belong to the
socket path and are omitted elsewhere.  FRAME is logged only when
`claude-emacs-bridge-log-frames' asks for it."
  (claude-emacs-bridge--log-event
   'send
   :id id
   :transport transport
   :target (alist-get 'name session)
   :pid (alist-get 'pid session)
   :file file
   :lines (format "%d-%d" (car range) (cdr range))
   :socket socket
   :content content
   :frame (and claude-emacs-bridge-log-frames frame)))

(defun claude-emacs-bridge--log-outcome (id result &optional reason)
  "Record RESULT for send ID, with REASON when there is one to give."
  (claude-emacs-bridge--log-event 'outcome :id id :result result :reason reason))

(defun claude-emacs-bridge--log-status (status)
  "Append STATUS to the bridge log as its own event."
  (claude-emacs-bridge--log-event 'status :text status))

(defun claude-emacs-bridge-show-log ()
  "Show the bridge log."
  (interactive)
  (let ((buffer (get-buffer-create claude-emacs-bridge-log-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'special-mode)
        (special-mode)))
    (pop-to-buffer buffer)))

(defun claude-emacs-bridge-toggle-queue-mode ()
  "Toggle whether `claude-emacs-bridge-send' queues instead of sending.
Disabling never touches `claude-emacs-bridge--queue'.  Enabling while the
queue already holds entries asks whether to clear them first; either answer
still completes the toggle, the question only decides whether the queue is
emptied before the mode goes on."
  (interactive)
  (if claude-emacs-bridge-queue-mode
      (setq claude-emacs-bridge-queue-mode nil)
    (when (and claude-emacs-bridge--queue
               (y-or-n-p "Queue mode has queued entries; clear them? "))
      (setq claude-emacs-bridge--queue nil))
    (setq claude-emacs-bridge-queue-mode t))
  (message "Queue mode is now %s (%d queued)"
           (if claude-emacs-bridge-queue-mode "on" "off")
           (length claude-emacs-bridge--queue)))

(defconst claude-emacs-bridge--language-alist
  '(("el" . "emacs-lisp") ("py" . "python") ("go" . "go")
    ("js" . "js") ("jsx" . "js")
    ("ts" . "typescript") ("tsx" . "typescript")
    ("sh" . "bash") ("rb" . "ruby") ("rs" . "rust")
    ("c" . "C") ("h" . "C"))
  "Maps a file extension, without its dot, to a Babel source block language.
Used by `claude-emacs-bridge-show-queue' to pick the language a queued
entry's snippet is rendered under.")

(defun claude-emacs-bridge--babel-language (file)
  "Return the Babel language for FILE's extension, or \"text\" when unknown."
  (or (cdr (assoc (downcase (or (file-name-extension file) ""))
                   claude-emacs-bridge--language-alist))
      "text"))

(defun claude-emacs-bridge--truncate-lines (lines start-line)
  "Return LINES, captured starting at START-LINE, as numbered rows to display.
LINES is a list of strings, as `claude-emacs-bridge--capture-lines' returns.
Each row is a cons of an absolute line number and its text.  Ten lines or
fewer are all returned.  More than ten returns the first five and the last
five, with a marker row (a nil line number) between them naming how many
lines were omitted.  Never more than ten content rows come back, regardless
of how many LINES holds."
  (let* ((count (length lines))
         (numbered (let ((n (1- start-line)))
                     (mapcar (lambda (line) (cons (setq n (1+ n)) line)) lines))))
    (if (<= count 10)
        numbered
      (append (cl-subseq numbered 0 5)
              (list (cons nil (format "... (%d lines omitted) ..." (- count 10))))
              (cl-subseq numbered (- count 5) count)))))

(defun claude-emacs-bridge--capture-lines (start-line end-line)
  "Return the current buffer's text from START-LINE through END-LINE.
Result is a list of strings, one per line, for `claude-emacs-bridge-show-queue'
to display later.  Absolute line numbers are used, via widening, so a
narrowed buffer does not shift what is captured."
  (save-excursion
    (save-restriction
      (widen)
      (goto-char (point-min))
      (forward-line (1- start-line))
      (let ((beg (point)))
        (goto-char (point-min))
        (forward-line (1- end-line))
        (end-of-line)
        (split-string (buffer-substring-no-properties beg (point)) "\n")))))

(defun claude-emacs-bridge--read-file-range (file start-line end-line)
  "Return FILE's text from START-LINE through END-LINE, read fresh from disk.
Returns the same shape `claude-emacs-bridge--capture-lines' returns for the
current buffer, but FILE is always read from disk, never from any buffer
already visiting it.  Returns nil when FILE cannot be read (deleted, moved,
permission denied) rather than signalling; a caller distinguishes
\"unreadable\" from \"legitimately empty\" by checking `file-readable-p'
first, not by nil alone, since a legitimately empty range is also nil."
  (when (file-readable-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (claude-emacs-bridge--capture-lines start-line end-line))))

(defun claude-emacs-bridge--entry-staleness (entry)
  "Return how ENTRY's captured `:lines' compares to FILE's content now.
Returns nil when ENTRY's file was read and its content at :start-line
through :end-line matches :lines exactly, `stale' when the read succeeded
but the content differs, or `missing' when the file cannot be read at all.
Pure aside from the one file read `claude-emacs-bridge--read-file-range'
performs."
  (let ((file (plist-get entry :file)))
    (if (not (file-readable-p file))
        'missing
      (let ((current (claude-emacs-bridge--read-file-range
                       file
                       (plist-get entry :start-line)
                       (plist-get entry :end-line))))
        (if (equal current (plist-get entry :lines))
            nil
          'stale)))))

(defun claude-emacs-bridge--enqueue-send (range col-range file instruction)
  "Push a queue entry for FILE covered by RANGE and COL-RANGE, with INSTRUCTION.
RANGE and COL-RANGE are inclusive line and 0-indexed column conses, as
`claude-emacs-bridge--line-range' and `claude-emacs-bridge--column-range'
return.  Operates on the current buffer, to capture its snippet text for
`claude-emacs-bridge-show-queue'.  No target is resolved here; that stays
deferred to `claude-emacs-bridge-send-queue'."
  (let ((entry (list :file file
                      :start-line (car range)
                      :end-line (cdr range)
                      :start-col (car col-range)
                      :end-col (cdr col-range)
                      :instruction instruction
                      :lines (claude-emacs-bridge--capture-lines
                              (car range) (cdr range)))))
    (setq claude-emacs-bridge--queue
          (append claude-emacs-bridge--queue (list entry)))
    (message "Queued (%d): %s lines %d-%d"
             (length claude-emacs-bridge--queue)
             file (car range) (cdr range))
    entry))

(defun claude-emacs-bridge--format-queue-entry (entry)
  "Return the org text rendering one queue ENTRY.
Emits a :PROPERTIES: drawer carrying SOURCE-FILE, START-LINE, END-LINE,
START-COL, END-COL, and LINES, so `claude-emacs-bridge-queue-buffer-commit'
can rebuild ENTRY losslessly later.  The property is named SOURCE-FILE, not
FILE, because \"FILE\" is one of org's special properties (it always reads
back as `buffer-file-name', never a drawer value); see `org-special-properties'.
LINES holds `prin1-to-string' of the entry's full,
untruncated captured lines, read back with `(read (org-entry-get pos
\"LINES\"))'; it is never derived from the visible (possibly truncated) src
block.  The heading text and the src block's line numbers are for reading
only, and are never parsed back.

The heading also carries a staleness marker, \" [STALE]\" or \" [FILE NOT
FOUND]\", from `claude-emacs-bridge--entry-staleness', when ENTRY's file on
disk no longer matches what was captured.  The marker is decorative text in
the heading, not data: `claude-emacs-bridge-queue-buffer-commit' never parses
it back.

Everything in the result except the instruction's typed text carries the
`read-only' text property (with the sticky properties needed at its edges),
so a caller that inserts this string verbatim gets an editable instruction
and a protected heading, drawer, and src block for free."
  (let* ((file (plist-get entry :file))
         (start-line (plist-get entry :start-line))
         (end-line (plist-get entry :end-line))
         (start-col (plist-get entry :start-col))
         (end-col (plist-get entry :end-col))
         (instruction (plist-get entry :instruction))
         (lines (plist-get entry :lines))
         (rows (claude-emacs-bridge--truncate-lines lines start-line))
         (staleness (claude-emacs-bridge--entry-staleness entry))
         (heading (format "* %s (lines %d-%d, cols %d-%d)%s\n"
                           (file-name-nondirectory file)
                           start-line end-line start-col end-col
                           (pcase staleness
                             ('stale " [STALE]")
                             ('missing " [FILE NOT FOUND]")
                             (_ ""))))
         (drawer (concat
                  ":PROPERTIES:\n"
                  (format ":SOURCE-FILE: %s\n" file)
                  (format ":START-LINE: %d\n" start-line)
                  (format ":END-LINE: %d\n" end-line)
                  (format ":START-COL: %d\n" start-col)
                  (format ":END-COL: %d\n" end-col)
                  (format ":LINES: %s\n"
                          (let ((print-escape-newlines t))
                            (prin1-to-string lines)))
                  ":END:\n"))
         ;; `copy-sequence' so `put-text-property' below never mutates a
         ;; shared byte-compiled string constant.
         (label (copy-sequence "Instruction: "))
         ;; Two newlines: the first ends the instruction line, the second is
         ;; the blank line's own terminator.  Both are read-only, which is
         ;; enough on its own to block `backward-delete-char' from merging
         ;; the blank line into the instruction.  No `front-sticky': that
         ;; would also block inserting new text at the end of the
         ;; instruction, which is exactly where a user normally types to
         ;; extend it.
         (blank (copy-sequence "\n\n"))
         (src (concat
               (format "#+begin_src %s\n" (claude-emacs-bridge--babel-language file))
               (mapconcat
                (lambda (row)
                  (if (car row) (format "%d: %s" (car row) (cdr row)) (cdr row)))
                rows "\n")
               "\n#+end_src\n")))
    (put-text-property 0 (length heading) 'read-only t heading)
    (put-text-property 0 (length drawer) 'read-only t drawer)
    (put-text-property 0 (length label) 'read-only t label)
    (put-text-property (1- (length label)) (length label) 'rear-nonsticky t label)
    (put-text-property 0 (length blank) 'read-only t blank)
    (put-text-property 0 (length src) 'read-only t src)
    (concat heading drawer label instruction blank src)))

(defvar claude-emacs-bridge-queue-buffer-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'claude-emacs-bridge-queue-buffer-commit)
    map)
  "Keymap layered over the queue buffer's `org-mode-map'.
Only adds `claude-emacs-bridge-queue-buffer-commit' on \\`C-c C-c'; every
other binding still comes from `org-mode-map' via its parent keymap.")

(defun claude-emacs-bridge--required-property (heading prop)
  "Return PROP for the entry at point, or signal `user-error' naming HEADING.
PROP is read with `org-entry-get'; a missing or empty value is treated as
absent."
  (let ((value (org-entry-get (point) prop)))
    (if (and value (not (string-empty-p value)))
        value
      (user-error "Queued entry %S is missing the %s property" heading prop))))

(defun claude-emacs-bridge--queue-entry-at-point ()
  "Parse the queue entry plist for the heading at point.
Reads SOURCE-FILE, START-LINE, END-LINE, START-COL, END-COL, and LINES from
the entry's properties drawer via `org-entry-get', never from the heading
text or the (possibly truncated) src block.  The instruction is the rest of
the `Instruction: ' line found in the entry's body.  Signals `user-error'
naming the heading and the missing property or line when the entry is
incomplete."
  (let* ((heading (org-get-heading t t t t))
         (file (claude-emacs-bridge--required-property heading "SOURCE-FILE"))
         (start-line (string-to-number
                      (claude-emacs-bridge--required-property heading "START-LINE")))
         (end-line (string-to-number
                    (claude-emacs-bridge--required-property heading "END-LINE")))
         (start-col (string-to-number
                     (claude-emacs-bridge--required-property heading "START-COL")))
         (end-col (string-to-number
                   (claude-emacs-bridge--required-property heading "END-COL")))
         (lines (read (claude-emacs-bridge--required-property heading "LINES")))
         (subtree-end (save-excursion (org-end-of-subtree t t) (point)))
         (instruction
          (save-excursion
            (if (re-search-forward "^Instruction: \\(.*\\)$" subtree-end t)
                (match-string-no-properties 1)
              (user-error "Queued entry %S is missing its Instruction line"
                          heading)))))
    (list :file file
          :start-line start-line
          :end-line end-line
          :start-col start-col
          :end-col end-col
          :instruction instruction
          :lines lines)))

(defun claude-emacs-bridge-queue-buffer-commit ()
  "Rebuild `claude-emacs-bridge--queue' from the current queue buffer.
Walks every heading in order and replaces the queue outright with what it
finds; nothing from the previous list is reused or patched in by position or
id.  A heading whose block was deleted from the buffer is simply absent from
the rebuilt queue, and deleting every block commits an empty queue.

A drawer missing a required property, or an entry missing its `Instruction: '
line, signals `user-error' naming the heading and what is missing, and
commits nothing for this call; `claude-emacs-bridge--queue' is left
unchanged."
  (interactive)
  (let ((entries (org-map-entries #'claude-emacs-bridge--queue-entry-at-point)))
    (setq claude-emacs-bridge--queue entries)
    (message "Committed %d queued entr%s"
             (length entries) (if (= (length entries) 1) "y" "ies"))))

(defun claude-emacs-bridge-show-queue ()
  "Display the queued entries in an org-mode buffer.
Each entry is rendered as its own heading, with the snippet captured at queue
time shown in a source block, truncated by `claude-emacs-bridge--truncate-lines'.
Everything but each entry's instruction text is read-only; edit the
instruction and commit with `claude-emacs-bridge-queue-buffer-commit' (bound
to \\`C-c C-c') to write the changes back to `claude-emacs-bridge--queue'.
An empty queue reports so in the echo area instead of showing a buffer."
  (interactive)
  (if (null claude-emacs-bridge--queue)
      (progn (message "Queue is empty") nil)
    (let ((buffer (get-buffer-create "*Claude Bridge Queue*")))
      (with-current-buffer buffer
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert (mapconcat #'claude-emacs-bridge--format-queue-entry
                              claude-emacs-bridge--queue "\n")))
        (org-mode)
        (use-local-map
         (make-composed-keymap claude-emacs-bridge-queue-buffer-map
                                (current-local-map))))
      (pop-to-buffer buffer)
      buffer)))

(defun claude-emacs-bridge--send-prompt ()
  "Return the minibuffer prompt for `claude-emacs-bridge-send'.
Prefixed with \"(QueueMode) \" when `claude-emacs-bridge-queue-mode' is on, so
the prompt itself shows whether this instruction will queue or send
immediately."
  (concat (if claude-emacs-bridge-queue-mode "(QueueMode) " "")
          "Instruction for Claude target: "))

(defun claude-emacs-bridge-send (beg end instruction)
  "Send the file location from BEG to END to the target Claude Code session.
Equal endpoints send their current line.  INSTRUCTION tells the target Claude
Code session what to do.  Source text is not sent.

When `claude-emacs-bridge-queue-mode' is on, the location and instruction are
queued instead of being sent; flush the queue with
`claude-emacs-bridge-send-queue'."
  (interactive
   (progn
     (unless buffer-file-name
       (user-error "The current buffer is not visiting a file"))
     (list (if (use-region-p) (region-beginning) (point))
           (if (use-region-p) (region-end) (point))
           (read-string (claude-emacs-bridge--send-prompt)))))
  (unless buffer-file-name
    (user-error "The current buffer is not visiting a file"))
  (when (or (not (stringp instruction))
            (string-empty-p (string-trim instruction)))
    (user-error "Instruction cannot be empty"))
  (let* ((range (claude-emacs-bridge--line-range beg end))
         (col-range (claude-emacs-bridge--column-range beg end))
         (file (expand-file-name buffer-file-name))
         (source-buffer (current-buffer)))
    (if claude-emacs-bridge-queue-mode
        (claude-emacs-bridge--enqueue-send range col-range file instruction)
      (claude-emacs-bridge--send-via-socket
       range col-range file source-buffer instruction))))

(defun claude-emacs-bridge--transcript-slug (cwd)
  "Return the directory name Claude Code files CWD's transcripts under."
  (replace-regexp-in-string "[^A-Za-z0-9]" "-" cwd))

(defun claude-emacs-bridge--transcript-path (session)
  "Return the transcript file for SESSION, or nil when it cannot be found.
Tries the slug of the session's working directory first, then looks for the
session id anywhere under the projects directory, since that directory can be
overridden.  When neither resolves, both attempts are logged: absence of a
transcript is not a failed delivery, and someone checking by hand needs to
know where it was looked for."
  (let* ((id (alist-get 'sessionId session))
         (cwd (alist-get 'cwd session))
         (slug (and cwd (claude-emacs-bridge--transcript-slug cwd)))
         (direct (and id slug
                      (expand-file-name
                       (concat slug "/" id ".jsonl")
                       claude-emacs-bridge-projects-directory))))
    (cond
     ((and direct (file-readable-p direct)) direct)
     ((and id
           (car (file-expand-wildcards
                 (expand-file-name (concat "*/" id ".jsonl")
                                   claude-emacs-bridge-projects-directory))))))))

(defun claude-emacs-bridge--log-unresolved-transcript (session)
  "Record that SESSION's transcript could not be found, and where it was sought.
Absence of a transcript is not a failed delivery, so this reads as a thing to
check by hand rather than as an error."
  (let* ((id (alist-get 'sessionId session))
         (cwd (alist-get 'cwd session))
         (slug (and cwd (claude-emacs-bridge--transcript-slug cwd))))
    (claude-emacs-bridge--log-event
     'transcript
     :resolved "no"
     :sessionId id
     :slug slug
     :direct (and id slug
                  (expand-file-name (concat slug "/" id ".jsonl")
                                    claude-emacs-bridge-projects-directory))
     :searched (expand-file-name
                (concat "*/" (or id "") ".jsonl")
                claude-emacs-bridge-projects-directory))))

(defun claude-emacs-bridge--transcript-offset (path)
  "Return the size of PATH now, so only what is written after it is read.
An older identical send further up the same transcript is not this one."
  (or (and path (file-readable-p path) (file-attribute-size (file-attributes path)))
      0))

(defun claude-emacs-bridge--enqueue-line-p (line content)
  "Return non-nil for a LINE recording CONTENT as queued by its recipient.
The record carries no message id, so exact content is the only correlation
available.  Its presence means the message cleared the accept gate and the
duplicate, rate and queue guards."
  (condition-case nil
      (let ((entry (json-parse-string line
                                      :object-type 'alist
                                      :array-type 'list
                                      :null-object nil
                                      :false-object nil)))
        (and (consp entry)
             (consp (car entry))
             (equal (alist-get 'type entry) "queue-operation")
             (equal (alist-get 'operation entry) "enqueue")
             (equal (alist-get 'content entry) content)))
    (error nil)))

(defun claude-emacs-bridge--await-enqueue (session path offset content)
  "Watch SESSION's transcript from OFFSET for the entry recording CONTENT.
PATH is where it was before the send, or nil when there was nothing there.
Return non-nil once the entry appears.

The path is looked for again on every pass while it is nil.  A session that
has never been prompted has no transcript until a message lands, so the first
send to a fresh session would otherwise never be confirmed.

Absence is not failure: a transcript can also be missing because persistence
is off, so the caller reports unconfirmed rather than failed."
  (let ((deadline (+ (float-time) claude-emacs-bridge-confirm-timeout)))
    (catch 'confirmed
      (while t
        (unless path
          (setq path (claude-emacs-bridge--transcript-path session)))
        (when (and path (file-readable-p path))
          (let ((size (file-attribute-size (file-attributes path))))
            (when (and size (> size offset))
              (with-temp-buffer
                (insert-file-contents path nil offset size)
                ;; A read can land mid-write, so drop a trailing partial line.
                (goto-char (point-max))
                (unless (bolp)
                  (delete-region (line-beginning-position) (point-max)))
                (goto-char (point-min))
                (while (not (eobp))
                  (when (claude-emacs-bridge--enqueue-line-p
                         (buffer-substring-no-properties
                          (line-beginning-position) (line-end-position))
                         content)
                    (throw 'confirmed t))
                  (forward-line 1))))))
        (when (>= (float-time) deadline)
          (throw 'confirmed nil))
        (sleep-for claude-emacs-bridge-confirm-poll-interval)))))

(defun claude-emacs-bridge--write-frame (socket frame)
  "Write FRAME to SOCKET and close.
Signals a `file-error' when the socket cannot be reached, which plan 04 notes
is the one failure a sender can detect on the connection itself."
  (let ((process (make-network-process
                  :name "claude-emacs-bridge-send"
                  :family 'local
                  :service socket
                  :coding 'utf-8-unix
                  :noquery t)))
    (unwind-protect
        (progn
          (process-send-string process frame)
          (process-send-eof process))
      (ignore-errors (delete-process process)))))

(defun claude-emacs-bridge--send-outcome (frame confirmed target file lines)
  "Return the outcome of a send as a cons of a result and the text for it.
FRAME is a report from the recipient, if one arrived.  CONFIRMED says whether
the recipient recorded queueing the message.  TARGET, FILE and LINES describe
what was sent.

A report is checked first because it carries the recipient's own reason.  The
two cannot both be true in practice: a message that was held or dropped was
never queued."
  (cond
   (frame
    (let ((status (alist-get 'status frame))
          (drop (alist-get 'drop_reason frame))
          (reason (claude-emacs-bridge--receipt-reason frame)))
      (cons 'failed
            (if (equal drop "duplicate")
                ;; Ordinary to hit: the same instruction about the same lines
                ;; within the recipient's duplicate window.  Neither success
                ;; nor a bug here, and it must not read as either.
                (format
                 (concat "%s already had this exact message recently and did "
                         "not receive it again (duplicate). %s lines %s")
                 target file lines)
              (format "%s did not receive %s lines %s: %s (%s)"
                      target file lines reason status)))))
   (confirmed
    (cons 'delivered (format "Delivered to %s: %s lines %s" target file lines)))
   (t
    (cons 'unconfirmed
          (format "Sent to %s: %s lines %s (unconfirmed)" target file lines)))))

(defun claude-emacs-bridge--send-via-socket (range col-range file
                                                   source-buffer instruction)
  "Deliver the location in FILE covered by RANGE to a target's inbox socket.
COL-RANGE gives the 0-indexed columns the selection starts and ends at.
SOURCE-BUFFER is where the target is resolved.  INSTRUCTION tells the target
what to do.  The send is reported as unconfirmed: nothing is written back on
the connection, so confirmation has to come from elsewhere."
  (let* ((session (with-current-buffer source-buffer
                    (claude-emacs-bridge--resolve-target)))
         (socket (alist-get 'messagingSocketPath session))
         (target (alist-get 'name session))
         (lines (format "%d-%d" (car range) (cdr range)))
         (receipt (claude-emacs-bridge--ensure-receipt-socket))
         (id (claude-emacs-bridge--uuid))
         (content (claude-emacs-bridge--socket-content
                   file range col-range instruction))
         (frame (claude-emacs-bridge--socket-frame
                 content id (claude-emacs-bridge--uds-address receipt))))
    (claude-emacs-bridge--log-send
     id 'socket session file range content socket frame)
    (claude-emacs-bridge--remember-send
     id `((transport . socket)
          (target . ,target)
          (pid . ,(alist-get 'pid session))
          (file . ,file)
          (lines . ,lines)
          (socket . ,socket)
          (pending . t)))
    (condition-case err
        (let* ((transcript (claude-emacs-bridge--transcript-path session))
               (offset (claude-emacs-bridge--transcript-offset transcript)))
          (claude-emacs-bridge--write-frame socket frame)
          (let* ((confirmed (claude-emacs-bridge--await-enqueue
                             session transcript offset content))
                 (report (gethash id claude-emacs-bridge--receipts))
                 (outcome (claude-emacs-bridge--send-outcome
                           report confirmed target file lines)))
            ;; Stop waiting only once the report has been collected, or a
            ;; frame arriving mid-wait would be logged as late as well.
            (claude-emacs-bridge--finish-send id)
            (remhash id claude-emacs-bridge--receipts)
            (unless (or confirmed report
                        (claude-emacs-bridge--transcript-path session))
              (claude-emacs-bridge--log-unresolved-transcript session))
            (claude-emacs-bridge--log-outcome id (car outcome) (cdr outcome))
            (claude-emacs-bridge--log-status (cdr outcome))
            (message "%s" (cdr outcome))))
      (file-error
       (claude-emacs-bridge--finish-send id)
       (claude-emacs-bridge--log-outcome
        id 'failed (error-message-string err))
       ;; Nothing arrives for this one, so the log entry is the only artifact.
       (claude-emacs-bridge--log-event
        'failure
        :id id
        :socket socket
        :target target
        :pid (alist-get 'pid session)
        :error (error-message-string err))
       (message "Could not reach %s at %s: %s"
                target socket (error-message-string err))))))

(defun claude-emacs-bridge--send-combined-via-socket (session entries)
  "Deliver ENTRIES to SESSION's inbox socket as one combined message.
Mirrors `claude-emacs-bridge--send-via-socket', but for the combined content
`claude-emacs-bridge--combined-socket-content' builds from all of ENTRIES.
Returns non-nil once `claude-emacs-bridge--write-frame' returns without
signalling (the frame left this Emacs), nil when it catches a `file-error'
\(the socket was unreachable, so nothing was sent)."
  (let* ((socket (alist-get 'messagingSocketPath session))
         (target (alist-get 'name session))
         (receipt (claude-emacs-bridge--ensure-receipt-socket))
         (id (claude-emacs-bridge--uuid))
         (content (claude-emacs-bridge--combined-socket-content entries))
         (frame (claude-emacs-bridge--socket-frame
                 content id (claude-emacs-bridge--uds-address receipt))))
    (claude-emacs-bridge--log-event
     'send :id id :transport 'socket :target target
     :pid (alist-get 'pid session) :entries (length entries)
     :content content :socket socket
     :frame (and claude-emacs-bridge-log-frames frame))
    (condition-case err
        (progn
          (claude-emacs-bridge--write-frame socket frame)
          (claude-emacs-bridge--log-outcome id 'sent)
          (message "Sent %d queued entries to %s" (length entries) target)
          t)
      (file-error
       (claude-emacs-bridge--log-outcome id 'failed (error-message-string err))
       (message "Could not reach %s at %s: %s"
                target socket (error-message-string err))
       nil))))

(defun claude-emacs-bridge-send-queue ()
  "Send every queued entry to one target as a single combined message.
Signals a `user-error' when the queue is empty.  Otherwise resolves one
target the same way `claude-emacs-bridge-send' does, dispatches the
combined content over the socket, and clears the queue only once the
dispatch function reports the message actually went out (a truthy return
value), never merely because the call returned without signalling.  An
exception propagating out of the dispatch call is not caught here: the
queue was never confirmed sent, so it survives untouched for a retry, and
the error still reaches the caller normally."
  (interactive)
  (unless claude-emacs-bridge--queue
    (user-error "Queue is empty"))
  (let* ((entries claude-emacs-bridge--queue)
         (session (claude-emacs-bridge--resolve-target))
         (sent (claude-emacs-bridge--send-combined-via-socket
                session entries)))
    (when sent
      (setq claude-emacs-bridge--queue nil))))

(provide 'claude-emacs-bridge)
;;; claude-emacs-bridge.el ends here
