;;; claude-emacs-bridge-tests.el --- Tests for Claude Emacs bridge -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'ert)
(require 'claude-emacs-bridge)

(ert-deftest claude-emacs-bridge--line-range-test/same-line ()
  "A region contained within one line reports that line at both ends."
  (with-temp-buffer
    (insert "alpha beta\n")
    (should (equal (claude-emacs-bridge--line-range 2 7)
                   '(1 . 1)))))

(ert-deftest claude-emacs-bridge--line-range-test/end-at-next-line-start ()
  "A region ending at the next line's start excludes that unselected line."
  (with-temp-buffer
    (insert "one\ntwo\nthree\n")
    (should (equal (claude-emacs-bridge--line-range 1 9)
                   '(1 . 2)))))

(ert-deftest claude-emacs-bridge--line-range-test/empty-range-uses-current-line ()
  "Equal endpoints report the line at point as a single-line range."
  (with-temp-buffer
    (insert "one\ntwo\nthree\n")
    (goto-char (point-min))
    (forward-line 1)
    (should (equal (claude-emacs-bridge--line-range (point) (point))
                   '(2 . 2)))))

(ert-deftest claude-emacs-bridge--line-range-test/rejects-reversed-range ()
  "A range whose start follows its end is rejected."
  (with-temp-buffer
    (insert "one\ntwo\n")
    (should-error (claude-emacs-bridge--line-range 5 1)
                  :type 'user-error)))

(ert-deftest claude-emacs-bridge--line-range-test/narrowed-buffer-uses-file-lines ()
  "Line numbers remain absolute when the source buffer is narrowed."
  (with-temp-buffer
    (insert "one\ntwo\nthree\nfour\n")
    (goto-char (point-min))
    (forward-line 2)
    (narrow-to-region (point) (point-max))
    (should (equal (claude-emacs-bridge--line-range (point) (point))
                   '(3 . 3)))))

(ert-deftest claude-emacs-bridge--normalize-directory-test/expands-and-adds-slash ()
  "Directory keys are absolute and end with a slash."
  (let ((default-directory "/tmp/"))
    (should
     (equal (claude-emacs-bridge--normalize-directory "example")
            "/tmp/example/"))))

(ert-deftest claude-emacs-bridge--context-key-test/prefers-project-root ()
  "The Emacs project root wins over every fallback."
  (cl-letf (((symbol-function 'project-current) (lambda (&rest _) 'project))
            ((symbol-function 'project-root) (lambda (_) "/tmp/project"))
            ((symbol-function 'get-current-persp) (lambda () 'perspective))
            ((symbol-function 'safe-persp-name) (lambda (_) "workspace"))
            ((symbol-function 'vc-root-dir) (lambda () "/tmp/git")))
    (let ((persp-mode t)
          (default-directory "/tmp/directory/"))
      (should
       (equal (claude-emacs-bridge--context-key)
              '(project . "/tmp/project/"))))))

(ert-deftest claude-emacs-bridge--context-key-test/falls-back-to-perspective ()
  "A perspective name is used when no Emacs project exists."
  (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil))
            ((symbol-function 'get-current-persp) (lambda () 'perspective))
            ((symbol-function 'safe-persp-name) (lambda (_) "workspace"))
            ((symbol-function 'vc-root-dir) (lambda () "/tmp/git")))
    (let ((persp-mode t)
          (default-directory "/tmp/directory/"))
      (should
       (equal (claude-emacs-bridge--context-key)
              '(workspace . "workspace"))))))

(ert-deftest claude-emacs-bridge--context-key-test/falls-back-to-git-root ()
  "The Git root is used without an Emacs project or perspective."
  (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil))
            ((symbol-function 'vc-root-dir) (lambda () "/tmp/git")))
    (let ((persp-mode nil)
          (default-directory "/tmp/directory/"))
      (should
       (equal (claude-emacs-bridge--context-key)
              '(git . "/tmp/git/"))))))

(ert-deftest claude-emacs-bridge--context-key-test/falls-back-to-directory ()
  "The current directory is the final context fallback."
  (cl-letf (((symbol-function 'project-current) (lambda (&rest _) nil))
            ((symbol-function 'vc-root-dir) (lambda () nil)))
    (let ((persp-mode nil)
          (default-directory "/tmp/directory"))
      (should
       (equal (claude-emacs-bridge--context-key)
              '(directory . "/tmp/directory/"))))))

(ert-deftest claude-emacs-bridge--discover-sessions-test/parses-and-excludes-coordinator ()
  "Discovery returns targetable sessions but not the coordinator."
  (cl-letf (((symbol-function 'call-process)
             (lambda (&rest _)
               (insert (concat
                        "[{\"pid\":1,\"cwd\":\"/tmp/one\","
                        "\"kind\":\"interactive\","
                        "\"sessionId\":\"11111111-1111-1111-1111-111111111111\","
                        "\"name\":\"task-1\",\"status\":\"idle\"},"
                        "{\"pid\":2,\"cwd\":\"/tmp/two\","
                        "\"kind\":\"interactive\","
                        "\"sessionId\":\"22222222-2222-2222-2222-222222222222\","
                        "\"name\":\"emacs-server\",\"status\":\"idle\"}]"))
               0)))
    (let ((sessions (claude-emacs-bridge--discover-sessions 2)))
      (should (= (length sessions) 1))
      (should (equal (alist-get 'name (car sessions)) "task-1"))
      (should (= (alist-get 'pid (car sessions)) 1)))))

(ert-deftest claude-emacs-bridge--discover-sessions-test/rejects-cli-failure ()
  "Discovery reports a failed Claude CLI invocation."
  (cl-letf (((symbol-function 'call-process)
             (lambda (&rest _)
               (insert "failure")
               1)))
    (should-error (claude-emacs-bridge--discover-sessions)
                  :type 'user-error)))

(ert-deftest claude-emacs-bridge--session-label-test/includes-disambiguating-pid ()
  "Picker labels contain the name, PID, status, and cwd."
  (should
   (equal
    (claude-emacs-bridge--session-label
     '((name . "task-1")
       (pid . 1234)
       (sessionId . "11111111-1111-1111-1111-111111111111")
       (status . "idle")
       (cwd . "/tmp/project")))
    "task-1 [pid 1234] idle /tmp/project")))

(ert-deftest claude-emacs-bridge--read-session-test/returns-selection ()
  "The picker returns the session matching the selected unique label."
  (let* ((first '((name . "task")
                  (pid . 1)
                  (sessionId . "11111111-1111-1111-1111-111111111111")
                  (status . "idle")
                  (cwd . "/tmp/one")))
         (second '((name . "task")
                   (pid . 2)
                   (sessionId . "22222222-2222-2222-2222-222222222222")
                   (status . "idle")
                   (cwd . "/tmp/two"))))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (_ collection &rest _)
                 (car (cadr collection)))))
      (should
       (eq (claude-emacs-bridge--read-session (list first second))
           second)))))

(ert-deftest claude-emacs-bridge--read-session-test/rejects-empty-list ()
  "The picker reports when no target sessions are active."
  (should-error (claude-emacs-bridge--read-session nil)
                :type 'user-error))

(ert-deftest claude-emacs-bridge--resolve-target-test/reuses-live-association ()
  "A live stored session is returned without opening the picker."
  (let* ((key '(project . "/tmp/project/"))
         (session '((name . "task-1") (pid . 1) (startedAt . 100)))
         (claude-emacs-bridge--targets (make-hash-table :test 'equal)))
    (puthash key '(1 . 100) claude-emacs-bridge--targets)
    (cl-letf (((symbol-function 'claude-emacs-bridge--context-key)
               (lambda () key))
              ((symbol-function 'claude-emacs-bridge--discover-sessions)
               (lambda () (list session)))
              ((symbol-function 'claude-emacs-bridge--read-session)
               (lambda (&rest _)
                 (ert-fail "A live association must not prompt"))))
      (should (eq (claude-emacs-bridge--resolve-target) session)))))

(ert-deftest claude-emacs-bridge--resolve-target-test/selects-first-association ()
  "A context without an association opens the picker and stores its choice."
  (let* ((key '(project . "/tmp/project/"))
         (session '((name . "task-1") (pid . 1) (startedAt . 100)))
         (claude-emacs-bridge--targets (make-hash-table :test 'equal)))
    (cl-letf (((symbol-function 'claude-emacs-bridge--context-key)
               (lambda () key))
              ((symbol-function 'claude-emacs-bridge--discover-sessions)
               (lambda () (list session)))
              ((symbol-function 'claude-emacs-bridge--read-session)
               (lambda (_) session)))
      (should (eq (claude-emacs-bridge--resolve-target) session))
      (should
       (equal (gethash key claude-emacs-bridge--targets)
              '(1 . 100))))))

(ert-deftest claude-emacs-bridge--resolve-target-test/replaces-stale-association ()
  "A missing stored session is replaced through the picker."
  (let* ((key '(project . "/tmp/project/"))
         (replacement '((name . "task-2") (pid . 2) (startedAt . 200)))
         (claude-emacs-bridge--targets (make-hash-table :test 'equal)))
    (puthash key '(99 . 100) claude-emacs-bridge--targets)
    (cl-letf (((symbol-function 'claude-emacs-bridge--context-key)
               (lambda () key))
              ((symbol-function 'claude-emacs-bridge--discover-sessions)
               (lambda () (list replacement)))
              ((symbol-function 'claude-emacs-bridge--read-session)
               (lambda (_) replacement)))
      (should (eq (claude-emacs-bridge--resolve-target) replacement))
      (should
       (equal (gethash key claude-emacs-bridge--targets)
              '(2 . 200))))))

(ert-deftest claude-emacs-bridge-select-session-test/replaces-association ()
  "Explicit selection replaces the current context's stored process identity."
  (let* ((key '(project . "/tmp/project/"))
         (session '((name . "task-2") (pid . 2) (startedAt . 200)))
         (claude-emacs-bridge--targets (make-hash-table :test 'equal)))
    (puthash key '(1 . 100) claude-emacs-bridge--targets)
    (cl-letf (((symbol-function 'claude-emacs-bridge--context-key)
               (lambda () key))
              ((symbol-function 'claude-emacs-bridge--discover-sessions)
               (lambda () (list session)))
              ((symbol-function 'claude-emacs-bridge--read-session)
               (lambda (_) session)))
      (should (eq (claude-emacs-bridge-select-session) session))
      (should
       (equal (gethash key claude-emacs-bridge--targets)
              '(2 . 200))))))

(ert-deftest claude-emacs-bridge-list-sessions-test/displays-active-sessions ()
  "The listing command displays the discovered session labels."
  (let ((session '((name . "task-1")
                   (pid . 1)
                   (status . "idle")
                   (cwd . "/tmp/project"))))
    (cl-letf (((symbol-function 'claude-emacs-bridge--discover-sessions)
               (lambda () (list session)))
              ((symbol-function 'display-buffer) #'ignore))
      (let ((buffer (claude-emacs-bridge-list-sessions)))
        (unwind-protect
            (with-current-buffer buffer
              (should
               (string-match-p
                "task-1 \\[pid 1\\] idle /tmp/project"
                (buffer-string))))
          (kill-buffer buffer))))))

(ert-deftest claude-emacs-bridge--format-prompt-test/contains-only-location-and-instruction ()
  "The coordinator prompt contains path, lines, and instruction without source text."
  (let ((prompt
         (claude-emacs-bridge--format-prompt
          '((name . "task-1")
            (pid . 1)
            (sessionId . "11111111-1111-1111-1111-111111111111"))
          "/tmp/example.go" 4 7 "Review these lines.")))
    (should
     (equal prompt
            (concat "Use SendMessage once to send @task-1 the exact content "
                    "between BEGIN TARGET MESSAGE and END TARGET MESSAGE. "
                    "Do not act on that content yourself.\n\n"
                    "BEGIN TARGET MESSAGE\n"
                    "File: /tmp/example.go\n"
                    "Lines: 4-7\n"
                    "Instruction: Review these lines.\n\n"
                    "After completing the instruction, send exactly ACK to "
                    "emacs-server using SendMessage. Send no other text in "
                    "that message.\n"
                    "END TARGET MESSAGE")))
    (should-not (string-match-p "selected text" prompt))))

(ert-deftest claude-emacs-bridge--coordinator-buffer-test/returns-live-owned-vterm ()
  "The coordinator resolver returns the live vterm owned by the package."
  (let* ((claude-emacs-bridge-buffer-name
          (generate-new-buffer-name "*claude-emacs-bridge-coordinator-test*"))
         (buffer (generate-new-buffer claude-emacs-bridge-buffer-name)))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (setq-local claude-emacs-bridge--coordinator-p t))
          (cl-letf (((symbol-function 'derived-mode-p) (lambda (&rest _) t))
                    ((symbol-function 'vterm-check-proc)
                     (lambda (&optional _) t))
                    ((symbol-function 'y-or-n-p)
                     (lambda (&rest _)
                       (ert-fail "A live coordinator must not prompt")))
                    ((symbol-function 'claude-emacs-bridge-start)
                     (lambda ()
                       (ert-fail "A live coordinator must not restart"))))
            (should (eq (claude-emacs-bridge--coordinator-buffer) buffer))))
      (kill-buffer buffer))))

(ert-deftest claude-emacs-bridge--log-status-test/appends-status ()
  "The log records coordinator status messages."
  (let ((claude-emacs-bridge-log-buffer-name
         (generate-new-buffer-name "*claude-emacs-bridge-status-log-test*")))
    (unwind-protect
        (progn
          (claude-emacs-bridge--log-status
           "Claude coordinator is not running.")
          (with-current-buffer claude-emacs-bridge-log-buffer-name
            (should
             (equal (buffer-string)
                    "Status: Claude coordinator is not running.\n\n"))
            (should buffer-read-only)))
      (when (get-buffer claude-emacs-bridge-log-buffer-name)
        (kill-buffer claude-emacs-bridge-log-buffer-name)))))

(ert-deftest claude-emacs-bridge--log-message-test/appends-message-details ()
  "The log records the target, file, line range, and message."
  (let ((claude-emacs-bridge-log-buffer-name
         (generate-new-buffer-name "*claude-emacs-bridge-log-test*")))
    (unwind-protect
        (progn
          (claude-emacs-bridge--log-message
           '((name . "task-1")) "/tmp/example.go" 4 7 "Review these lines.")
          (with-current-buffer claude-emacs-bridge-log-buffer-name
            (should
             (equal (buffer-string)
                    (concat "Target: task-1\n"
                            "File: /tmp/example.go\n"
                            "Lines: 4:7\n"
                            "Message: Review these lines.\n\n")))
            (should buffer-read-only)))
      (when (get-buffer claude-emacs-bridge-log-buffer-name)
        (kill-buffer claude-emacs-bridge-log-buffer-name)))))

(ert-deftest claude-emacs-bridge-start-test/starts-owned-vterm ()
  "Starting the coordinator creates its vterm and launches the fixed command."
  (let* ((claude-emacs-bridge-buffer-name
          (generate-new-buffer-name "*claude-emacs-bridge-start-test*"))
         (created-buffer nil)
         (sent-string nil)
         (sent-paste-p nil)
         (return-sent nil))
    (unwind-protect
        (cl-letf (((symbol-function 'vterm)
                   (lambda (name)
                     (setq created-buffer (generate-new-buffer name))))
                  ((symbol-function 'vterm-send-string)
                   (lambda (string &optional paste-p)
                     (setq sent-string string
                           sent-paste-p paste-p)))
                  ((symbol-function 'vterm-send-return)
                   (lambda () (setq return-sent t))))
          (should (eq (claude-emacs-bridge-start) created-buffer))
          (should
           (equal sent-string
                  (concat "exec env -u DO_NOT_TRACK claude "
                          "--model claude-haiku-4-5-20251001 "
                          "--name emacs-server")))
          (should-not sent-paste-p)
          (should return-sent)
          (with-current-buffer created-buffer
            (should claude-emacs-bridge--coordinator-p)))
      (when (buffer-live-p created-buffer)
        (kill-buffer created-buffer)))))

(ert-deftest claude-emacs-bridge-start-test/reuses-live-owned-vterm ()
  "Starting again reuses the live owned vterm without launching another command."
  (let* ((claude-emacs-bridge-buffer-name
          "*claude-emacs-bridge-reuse-test*")
         (buffer (generate-new-buffer claude-emacs-bridge-buffer-name))
         (shown-buffer nil))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (setq-local claude-emacs-bridge--coordinator-p t))
          (cl-letf (((symbol-function 'derived-mode-p) (lambda (&rest _) t))
                    ((symbol-function 'vterm-check-proc) (lambda (&optional _) t))
                    ((symbol-function 'pop-to-buffer)
                     (lambda (target &rest _)
                       (setq shown-buffer target)))
                    ((symbol-function 'vterm)
                     (lambda (&rest _)
                       (ert-fail "A live coordinator must not be restarted")))
                    ((symbol-function 'vterm-send-string)
                     (lambda (&rest _)
                       (ert-fail "A live coordinator must not receive a startup command"))))
            (should (eq (claude-emacs-bridge-start) buffer))
            (should (eq shown-buffer buffer))))
      (kill-buffer buffer))))

(ert-deftest claude-emacs-bridge-start-test/rejects-name-collision ()
  "An unrelated buffer using the coordinator name is preserved and rejected."
  (let* ((claude-emacs-bridge-buffer-name
          "*claude-emacs-bridge-collision-test*")
         (buffer (generate-new-buffer claude-emacs-bridge-buffer-name)))
    (unwind-protect
        (should-error (claude-emacs-bridge-start) :type 'user-error)
      (should (buffer-live-p buffer))
      (kill-buffer buffer))))

(ert-deftest claude-emacs-bridge-clear-test/sends-clear-to-coordinator ()
  "Clearing sends one /clear command to the coordinator vterm."
  (let ((coordinator (generate-new-buffer " *claude-emacs-bridge-clear-test*"))
        (sent-string nil)
        (sent-paste-p nil)
        (return-count 0))
    (unwind-protect
        (cl-letf (((symbol-function 'claude-emacs-bridge--coordinator-buffer)
                   (lambda () coordinator))
                  ((symbol-function 'vterm-send-string)
                   (lambda (string &optional paste-p)
                     (setq sent-string string
                           sent-paste-p paste-p)))
                  ((symbol-function 'vterm-send-return)
                   (lambda () (setq return-count (1+ return-count)))))
          (claude-emacs-bridge-clear)
          (should (equal sent-string "/clear"))
          (should-not sent-paste-p)
          (should (= return-count 1)))
      (kill-buffer coordinator))))

(ert-deftest claude-emacs-bridge-clear-test/decline-does-not-send ()
  "Clearing stops without terminal input when coordinator startup is declined."
  (cl-letf (((symbol-function 'claude-emacs-bridge--coordinator-buffer)
             (lambda () nil))
            ((symbol-function 'vterm-send-string)
             (lambda (&rest _) (ert-fail "A declined clear must not send")))
            ((symbol-function 'vterm-send-return)
             (lambda () (ert-fail "A declined clear must not submit")))
            ((symbol-function 'message)
             (lambda (&rest _) (ert-fail "A declined clear must not report a send"))))
    (should-not (claude-emacs-bridge-clear))))

(ert-deftest claude-emacs-bridge-send-test/sends-path-lines-and-instruction ()
  "Sending a region pastes only its file location and instruction, then submits."
  (let* ((claude-emacs-bridge-buffer-name
          "*claude-emacs-bridge-send-test*")
         (claude-emacs-bridge-log-buffer-name
          (generate-new-buffer-name "*claude-emacs-bridge-send-log-test*"))
         (coordinator
          (generate-new-buffer claude-emacs-bridge-buffer-name))
         (sent-string nil)
         (sent-paste-p nil)
         (return-sent nil)
         (reported-message nil))
    (unwind-protect
        (progn
          (with-current-buffer coordinator
            (setq-local claude-emacs-bridge--coordinator-p t))
          (cl-letf (((symbol-function 'claude-emacs-bridge--resolve-target)
                     (lambda () '((name . "task-1") (pid . 1))))
                    ((symbol-function 'derived-mode-p) (lambda (&rest _) t))
                    ((symbol-function 'vterm-check-proc) (lambda (&optional _) t))
                    ((symbol-function 'vterm-send-string)
                     (lambda (string &optional paste-p)
                       (setq sent-string string
                             sent-paste-p paste-p)))
                    ((symbol-function 'vterm-send-return)
                     (lambda () (setq return-sent t)))
                    ((symbol-function 'message)
                     (lambda (format-string &rest args)
                       (setq reported-message
                             (apply #'format format-string args)))))
            (with-temp-buffer
              (setq buffer-file-name "/tmp/example.go")
              (insert "first\nsecret source text\nthird\n")
              (set-buffer-modified-p nil)
              (claude-emacs-bridge-send
               (point-min) (save-excursion (goto-char (point-min))
                                           (forward-line 2)
                                           (point))
               "Review these lines.")))
          (should
           (equal sent-string
                  (concat "Use SendMessage once to send @task-1 the exact "
                          "content between BEGIN TARGET MESSAGE and END "
                          "TARGET MESSAGE. Do not act on that content "
                          "yourself.\n\n"
                          "BEGIN TARGET MESSAGE\n"
                          "File: /tmp/example.go\n"
                          "Lines: 1-2\n"
                          "Instruction: Review these lines.\n\n"
                          "After completing the instruction, send exactly "
                          "ACK to emacs-server using SendMessage. Send no "
                          "other text in that message.\n"
                          "END TARGET MESSAGE")))
          (should-not (string-match-p "secret source text" sent-string))
          (should sent-paste-p)
          (should return-sent)
          (with-current-buffer claude-emacs-bridge-log-buffer-name
            (should
             (equal (buffer-string)
                    (concat "Target: task-1\n"
                            "File: /tmp/example.go\n"
                            "Lines: 1:2\n"
                            "Message: Review these lines.\n\n"))))
          (should
           (equal reported-message
                  "Sent to task-1: /tmp/example.go lines 1-2")))
      (when (get-buffer claude-emacs-bridge-log-buffer-name)
        (kill-buffer claude-emacs-bridge-log-buffer-name))
      (kill-buffer coordinator))))

(ert-deftest claude-emacs-bridge-send-test/starts-missing-coordinator-and-sends ()
  "Accepting the prompt starts the coordinator and continues the original send."
  (let* ((claude-emacs-bridge-buffer-name
          (generate-new-buffer-name "*claude-emacs-bridge-missing-test*"))
         (claude-emacs-bridge-log-buffer-name
          (generate-new-buffer-name "*claude-emacs-bridge-missing-log-test*"))
         (coordinator (generate-new-buffer " *claude-emacs-bridge-started-test*"))
         (prompt-count 0)
         (start-count 0)
         (resolve-count 0)
         (source-buffer nil)
         (sent-string nil))
    (unwind-protect
        (cl-letf (((symbol-function 'y-or-n-p)
                   (lambda (prompt)
                     (should
                      (equal prompt
                             "Claude coordinator is not running; start it now? "))
                     (setq prompt-count (1+ prompt-count))
                     t))
                  ((symbol-function 'claude-emacs-bridge-start)
                   (lambda ()
                     (setq start-count (1+ start-count))
                     (set-buffer coordinator)
                     coordinator))
                  ((symbol-function 'claude-emacs-bridge--resolve-target)
                   (lambda ()
                     (should (eq (current-buffer) source-buffer))
                     (should (equal buffer-file-name "/tmp/example.go"))
                     (setq resolve-count (1+ resolve-count))
                     '((name . "task-1") (pid . 1))))
                  ((symbol-function 'vterm-send-string)
                   (lambda (string &optional _)
                     (setq sent-string string)))
                  ((symbol-function 'vterm-send-return) #'ignore)
                  ((symbol-function 'message) #'ignore))
          (with-temp-buffer
            (setq source-buffer (current-buffer))
            (setq buffer-file-name "/tmp/example.go")
            (insert "line\n")
            (set-buffer-modified-p nil)
            (claude-emacs-bridge-send 1 2 "Review this line."))
          (should (= prompt-count 1))
          (should (= start-count 1))
          (should (= resolve-count 1))
          (should (string-match-p "Instruction: Review this line\\." sent-string))
          (with-current-buffer claude-emacs-bridge-log-buffer-name
            (should
             (string-prefix-p
              "Status: Claude coordinator is not running.\n\n"
              (buffer-string)))
            (should (string-match-p "Message: Review this line\\."
                                    (buffer-string)))))
      (when (get-buffer claude-emacs-bridge-log-buffer-name)
        (kill-buffer claude-emacs-bridge-log-buffer-name))
      (kill-buffer coordinator))))

(ert-deftest claude-emacs-bridge-send-test/declines-missing-coordinator ()
  "Declining the prompt logs the status and stops before target resolution."
  (let ((claude-emacs-bridge-buffer-name
         (generate-new-buffer-name "*claude-emacs-bridge-decline-test*"))
        (claude-emacs-bridge-log-buffer-name
         (generate-new-buffer-name "*claude-emacs-bridge-decline-log-test*")))
    (unwind-protect
        (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil))
                  ((symbol-function 'claude-emacs-bridge-start)
                   (lambda () (ert-fail "A declined prompt must not start")))
                  ((symbol-function 'claude-emacs-bridge--resolve-target)
                   (lambda () (ert-fail "A declined prompt must not resolve")))
                  ((symbol-function 'vterm-send-string)
                   (lambda (&rest _) (ert-fail "A declined prompt must not send")))
                  ((symbol-function 'message) #'ignore))
          (with-temp-buffer
            (setq buffer-file-name "/tmp/example.go")
            (insert "line\n")
            (set-buffer-modified-p nil)
            (should-not
             (claude-emacs-bridge-send 1 2 "Review this line.")))
          (with-current-buffer claude-emacs-bridge-log-buffer-name
            (should
             (equal (buffer-string)
                    "Status: Claude coordinator is not running.\n\n"))))
      (when (get-buffer claude-emacs-bridge-log-buffer-name)
        (kill-buffer claude-emacs-bridge-log-buffer-name)))))

(ert-deftest claude-emacs-bridge-send-test/interactive-rejects-empty-instruction ()
  "Pressing RET on an empty instruction does not resolve or send a target."
  (let* ((claude-emacs-bridge-buffer-name
          (generate-new-buffer-name
           "*claude-emacs-bridge-empty-instruction-test*"))
         (coordinator
          (generate-new-buffer claude-emacs-bridge-buffer-name)))
    (unwind-protect
        (progn
          (with-current-buffer coordinator
            (setq-local claude-emacs-bridge--coordinator-p t))
          (cl-letf (((symbol-function 'derived-mode-p) (lambda (&rest _) t))
                    ((symbol-function 'vterm-check-proc) (lambda (&optional _) t))
                    ((symbol-function 'read-string) (lambda (&rest _) ""))
                    ((symbol-function 'claude-emacs-bridge--resolve-target)
                     (lambda () (ert-fail "Empty input must not resolve a target")))
                    ((symbol-function 'vterm-send-string)
                     (lambda (&rest _) (ert-fail "Empty input must not send"))))
            (with-temp-buffer
              (setq buffer-file-name "/tmp/example.go")
              (insert "line\n")
              (set-buffer-modified-p nil)
              (let ((err
                     (should-error
                      (call-interactively #'claude-emacs-bridge-send)
                      :type 'user-error)))
                (should
                 (equal (error-message-string err)
                        "Instruction cannot be empty"))))))
      (kill-buffer coordinator))))

(ert-deftest claude-emacs-bridge-send-test/interactive-without-region-sends-current-line ()
  "Interactive sending without a region sends the line containing point."
  (let* ((claude-emacs-bridge-buffer-name
          "*claude-emacs-bridge-current-line-test*")
         (claude-emacs-bridge-log-buffer-name
          (generate-new-buffer-name
           "*claude-emacs-bridge-current-line-log-test*"))
         (coordinator
          (generate-new-buffer claude-emacs-bridge-buffer-name))
         (sent-string nil)
         (instruction-prompt nil))
    (unwind-protect
        (progn
          (with-current-buffer coordinator
            (setq-local claude-emacs-bridge--coordinator-p t))
          (cl-letf (((symbol-function 'claude-emacs-bridge--resolve-target)
                     (lambda () '((name . "task-1") (pid . 1))))
                    ((symbol-function 'derived-mode-p) (lambda (&rest _) t))
                    ((symbol-function 'vterm-check-proc) (lambda (&optional _) t))
                    ((symbol-function 'vterm-send-string)
                     (lambda (string &optional _)
                       (setq sent-string string)))
                    ((symbol-function 'vterm-send-return) #'ignore)
                    ((symbol-function 'read-string)
                     (lambda (prompt &rest _)
                       (setq instruction-prompt prompt)
                       "Review this line.")))
            (with-temp-buffer
              (setq buffer-file-name "/tmp/example.go")
              (insert "one\ntwo\nthree\n")
              (set-buffer-modified-p nil)
              (goto-char (point-min))
              (forward-line 1)
              (call-interactively #'claude-emacs-bridge-send)))
          (should (string-match-p "Lines: 2-2" sent-string))
          (should (equal instruction-prompt
                         "Instruction for Claude target: ")))
      (when (get-buffer claude-emacs-bridge-log-buffer-name)
        (kill-buffer claude-emacs-bridge-log-buffer-name))
      (kill-buffer coordinator))))

(ert-deftest claude-emacs-bridge-send-test/interactive-requires-file ()
  "Interactive sending rejects an active region in a non-file buffer."
  (with-temp-buffer
    (insert "line\n")
    (let ((transient-mark-mode t))
      (goto-char (point-min))
      (set-mark (point-max))
      (activate-mark)
      (should-error
       (call-interactively #'claude-emacs-bridge-send)
       :type 'user-error))))

(provide 'claude-emacs-bridge-tests)
;;; claude-emacs-bridge-tests.el ends here
