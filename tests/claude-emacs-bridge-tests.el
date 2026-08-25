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
               0))
            ;; The coordinator's PID now comes from its own vterm process
            ;; rather than from an argument only a test ever supplied.
            ((symbol-function 'claude-emacs-bridge--coordinator-pid)
             (lambda () 2)))
    (let ((sessions (claude-emacs-bridge--discover-sessions-cli)))
      (should (= (length sessions) 1))
      (should (equal (alist-get 'name (car sessions)) "task-1"))
      (should (= (alist-get 'pid (car sessions)) 1)))))

(ert-deftest claude-emacs-bridge--coordinator-pid-test/nil-without-a-coordinator ()
  "With no coordinator buffer there is no PID to exclude."
  (let ((claude-emacs-bridge-buffer-name
         (generate-new-buffer-name "*claude-emacs-bridge-nopid-test*")))
    (should-not (claude-emacs-bridge--coordinator-pid))))

(ert-deftest claude-emacs-bridge--discover-sessions-test/rejects-cli-failure ()
  "Discovery reports a failed Claude CLI invocation."
  (cl-letf (((symbol-function 'call-process)
             (lambda (&rest _)
               (insert "failure")
               1)))
    (should-error (claude-emacs-bridge--discover-sessions-cli)
                  :type 'user-error)))

(ert-deftest claude-emacs-bridge--discover-sessions-test/excludes-background-agents ()
  "A background agent is not offered, even with a live PID and a name.
Background agents have no inbox socket, so the coordinator cannot reach them."
  (cl-letf (((symbol-function 'call-process)
             (lambda (&rest _)
               (insert (concat
                        "[{\"pid\":1,\"cwd\":\"/tmp/one\","
                        "\"kind\":\"interactive\","
                        "\"sessionId\":\"11111111-1111-1111-1111-111111111111\","
                        "\"name\":\"task-1\",\"status\":\"idle\"},"
                        "{\"pid\":55098,\"cwd\":\"/tmp/two\","
                        "\"kind\":\"background\","
                        "\"sessionId\":\"22222222-2222-2222-2222-222222222222\","
                        "\"name\":\"byohctl-ci-integration\",\"status\":\"idle\"}]"))
               0)))
    (let ((sessions (claude-emacs-bridge--discover-sessions-cli)))
      (should (= (length sessions) 1))
      (should (equal (alist-get 'name (car sessions)) "task-1")))))

(ert-deftest claude-emacs-bridge--discover-sessions-test/excludes-rows-without-a-kind ()
  "A row that does not say it is interactive is left out.
An empty picker is a loud failure; offering an unreachable target is a quiet one."
  (cl-letf (((symbol-function 'call-process)
             (lambda (&rest _)
               (insert (concat
                        "[{\"pid\":1,\"cwd\":\"/tmp/one\","
                        "\"sessionId\":\"11111111-1111-1111-1111-111111111111\","
                        "\"name\":\"task-1\",\"status\":\"idle\"}]"))
               0)))
    (should-not (claude-emacs-bridge--discover-sessions-cli))))

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
  (let* ((claude-emacs-bridge--mode 'relay)
         (key '(project . "/tmp/project/"))
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
  (let ((claude-emacs-bridge--mode 'relay)
         (session '((name . "task-1")
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

(ert-deftest claude-emacs-bridge--escape-mentions-test/escapes-a-path ()
  "A path written as an at-mention is escaped so no file is attached."
  (should (equal (claude-emacs-bridge--escape-mentions "inline it into @/tmp/x.sh")
                 "inline it into \\@/tmp/x.sh")))

(ert-deftest claude-emacs-bridge--escape-mentions-test/escapes-every-mention ()
  "Every at-mention in the text is escaped, not only the first."
  (should (equal (claude-emacs-bridge--escape-mentions "@a.txt and @b.txt")
                 "\\@a.txt and \\@b.txt")))

(ert-deftest claude-emacs-bridge--escape-mentions-test/leaves-a-bare-at-sign ()
  "An at sign followed by whitespace cannot start a mention and is left alone."
  (should (equal (claude-emacs-bridge--escape-mentions "priced at @ 5 dollars")
                 "priced at @ 5 dollars")))

(ert-deftest claude-emacs-bridge--escape-mentions-test/leaves-a-trailing-at-sign ()
  "An at sign at the end of the text has nothing to expand."
  (should (equal (claude-emacs-bridge--escape-mentions "ends with @")
                 "ends with @")))

(ert-deftest claude-emacs-bridge--escape-mentions-test/escapes-inside-an-address ()
  "An address is escaped too.
Claude Code decides what a mention is; the bridge does not try to outguess it."
  (should (equal (claude-emacs-bridge--escape-mentions "ask dhanush@example.com")
                 "ask dhanush\\@example.com")))

(ert-deftest claude-emacs-bridge--format-prompt-test/escapes-mentions-in-the-instruction ()
  "An at-mention in the instruction reaches the target without being expanded."
  (let ((prompt (claude-emacs-bridge--format-prompt
                 '((name . "task-1"))
                 "/tmp/example.go" 4 7
                 "inline it into @/tmp/download.sh")))
    (should (string-match-p "Instruction: inline it into \\\\@/tmp/download\\.sh"
                            prompt))))

(ert-deftest claude-emacs-bridge--format-prompt-test/keeps-the-target-mention ()
  "The target's own mention is left intact so the coordinator can still route."
  (let ((prompt (claude-emacs-bridge--format-prompt
                 '((name . "task-1"))
                 "/tmp/example.go" 4 7 "Review these lines.")))
    (should (string-match-p "send @task-1 the exact content" prompt))
    (should-not (string-match-p "send \\\\@task-1" prompt))))

(ert-deftest claude-emacs-bridge-startup-command-test/locks-the-coordinator-down ()
  "The coordinator starts unable to read files.
Claude Code attaches @path contents before the model runs, so a relay that
can read is a relay that leaks whatever a path in an instruction points at."
  (should (string-match-p "--tools SendMessage,ListAgents"
                          claude-emacs-bridge--startup-command))
  (should (string-match-p "--strict-mcp-config"
                          claude-emacs-bridge--startup-command))
  (should (string-match-p "Read(//\\*\\*)"
                          claude-emacs-bridge--startup-command)))

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
                    "Instruction: Review these lines.\n"
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

(ert-deftest claude-emacs-bridge-start-test/starts-owned-vterm ()
  "Starting the coordinator creates its vterm and launches the fixed command."
  (let* ((claude-emacs-bridge--mode 'relay)
         (claude-emacs-bridge-buffer-name
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
          (should (equal sent-string
                         claude-emacs-bridge--startup-command))
          (should-not sent-paste-p)
          (should return-sent)
          (with-current-buffer created-buffer
            (should claude-emacs-bridge--coordinator-p)))
      (when (buffer-live-p created-buffer)
        (kill-buffer created-buffer)))))

(ert-deftest claude-emacs-bridge-start-test/reuses-live-owned-vterm ()
  "Starting again reuses the live owned vterm without launching another command."
  (let* ((claude-emacs-bridge--mode 'relay)
         (claude-emacs-bridge-buffer-name
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
  (let* ((claude-emacs-bridge--mode 'relay)
         (claude-emacs-bridge-buffer-name
          "*claude-emacs-bridge-collision-test*")
         (buffer (generate-new-buffer claude-emacs-bridge-buffer-name)))
    (unwind-protect
        (should-error (claude-emacs-bridge-start) :type 'user-error)
      (should (buffer-live-p buffer))
      (kill-buffer buffer))))

(ert-deftest claude-emacs-bridge-clear-test/sends-clear-to-coordinator ()
  "Clearing sends one /clear command to the coordinator vterm."
  (let ((claude-emacs-bridge--mode 'relay)
         (coordinator (generate-new-buffer " *claude-emacs-bridge-clear-test*"))
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
  (let ((claude-emacs-bridge--mode 'relay))
    (cl-letf (((symbol-function 'claude-emacs-bridge--coordinator-buffer)
             (lambda () nil))
            ((symbol-function 'vterm-send-string)
             (lambda (&rest _) (ert-fail "A declined clear must not send")))
            ((symbol-function 'vterm-send-return)
             (lambda () (ert-fail "A declined clear must not submit")))
            ((symbol-function 'message)
               (lambda (&rest _) (ert-fail "A declined clear must not report a send"))))
      (should-not (claude-emacs-bridge-clear)))))

(ert-deftest claude-emacs-bridge-send-test/sends-path-lines-and-instruction ()
  "Sending a region pastes only its file location and instruction, then submits."
  (let* ((claude-emacs-bridge--mode 'relay)
         (claude-emacs-bridge-buffer-name
          "*claude-emacs-bridge-send-test*")
         (claude-emacs-bridge-log-buffer-name
          (generate-new-buffer-name "*claude-emacs-bridge-send-log-test*"))
         (claude-emacs-bridge-log-file nil)
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
                          "Instruction: Review these lines.\n"
                          "END TARGET MESSAGE")))
          (should-not (string-match-p "secret source text" sent-string))
          (should sent-paste-p)
          (should return-sent)
          (with-current-buffer claude-emacs-bridge-log-buffer-name
            (let ((text (buffer-string)))
              (should (string-match-p " send .*transport=relay" text))
              (should (string-match-p "target=task-1" text))
              (should (string-match-p "file=/tmp/example.go" text))
              (should (string-match-p "lines=1-2" text))
              (should (string-match-p "Review these lines\\." text))
              (should (string-match-p " outcome .*result=submitted" text))))
          (should
           (equal reported-message
                  "Sent to task-1: /tmp/example.go lines 1-2")))
      (when (get-buffer claude-emacs-bridge-log-buffer-name)
        (kill-buffer claude-emacs-bridge-log-buffer-name))
      (kill-buffer coordinator))))

(ert-deftest claude-emacs-bridge-send-test/starts-missing-coordinator-and-sends ()
  "Accepting the prompt starts the coordinator and continues the original send."
  (let* ((claude-emacs-bridge--mode 'relay)
         (claude-emacs-bridge-buffer-name
          (generate-new-buffer-name "*claude-emacs-bridge-missing-test*"))
         (claude-emacs-bridge-log-buffer-name
          (generate-new-buffer-name "*claude-emacs-bridge-missing-log-test*"))
         (claude-emacs-bridge-log-file nil)
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
             (string-match-p
              "status text=\"Claude coordinator is not running\\.\""
              (buffer-string)))
            (should (string-match-p "Review this line\\."
                                    (buffer-string)))))
      (when (get-buffer claude-emacs-bridge-log-buffer-name)
        (kill-buffer claude-emacs-bridge-log-buffer-name))
      (kill-buffer coordinator))))

(ert-deftest claude-emacs-bridge-send-test/declines-missing-coordinator ()
  "Declining the prompt logs the status and stops before target resolution."
  (let ((claude-emacs-bridge--mode 'relay)
         (claude-emacs-bridge-buffer-name
         (generate-new-buffer-name "*claude-emacs-bridge-decline-test*"))
        (claude-emacs-bridge-log-buffer-name
         (generate-new-buffer-name "*claude-emacs-bridge-decline-log-test*"))
        (claude-emacs-bridge-log-file nil))
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
             (string-match-p
              "status text=\"Claude coordinator is not running\\.\""
              (buffer-string)))))
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
  (let* ((claude-emacs-bridge--mode 'relay)
         (claude-emacs-bridge-buffer-name
          "*claude-emacs-bridge-current-line-test*")
         (claude-emacs-bridge-log-buffer-name
          (generate-new-buffer-name
           "*claude-emacs-bridge-current-line-log-test*"))
         (claude-emacs-bridge-log-file nil)
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

;;; Delivery mode

(ert-deftest claude-emacs-bridge--ensure-mode-test/prompts-and-saves-first-time ()
  "With nothing chosen, the first call asks and remembers the answer."
  (let ((claude-emacs-bridge--mode nil)
        (claude-emacs-bridge-preferred-transport nil)
        (saved nil)
        (prompts 0))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) (setq prompts (1+ prompts)) "socket"))
              ((symbol-function 'customize-save-variable)
               (lambda (symbol value) (setq saved (cons symbol value)))))
      (should (eq (claude-emacs-bridge--ensure-mode) 'socket)))
    (should (= prompts 1))
    (should (equal saved '(claude-emacs-bridge-preferred-transport . socket)))
    (should (eq claude-emacs-bridge--mode 'socket))))

(ert-deftest claude-emacs-bridge--ensure-mode-test/saved-preference-does-not-prompt ()
  "A remembered choice is used without asking again."
  (let ((claude-emacs-bridge--mode nil)
        (claude-emacs-bridge-preferred-transport 'relay))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) (error "Should not prompt"))))
      (should (eq (claude-emacs-bridge--ensure-mode) 'relay)))
    (should (eq claude-emacs-bridge--mode 'relay))))

(ert-deftest claude-emacs-bridge--ensure-mode-test/reuses-the-running-mode ()
  "An already active mode is returned without consulting the saved option."
  (let ((claude-emacs-bridge--mode 'socket)
        (claude-emacs-bridge-preferred-transport 'relay))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) (error "Should not prompt"))))
      (should (eq (claude-emacs-bridge--ensure-mode) 'socket)))))

(ert-deftest claude-emacs-bridge--ensure-mode-test/unrecognized-saved-value-prompts ()
  "A hand-edited saved value is treated as unset rather than guessed at."
  (let ((claude-emacs-bridge--mode nil)
        (claude-emacs-bridge-preferred-transport 'telepathy)
        (reported nil)
        (prompts 0))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) (setq prompts (1+ prompts)) "relay"))
              ((symbol-function 'customize-save-variable) (lambda (&rest _) nil))
              ((symbol-function 'message)
               (lambda (format-string &rest args)
                 (setq reported (apply #'format format-string args)))))
      (should (eq (claude-emacs-bridge--ensure-mode) 'relay)))
    (should (= prompts 1))
    (should (string-match-p "telepathy" reported))))

(ert-deftest claude-emacs-bridge--read-transport-test/names-both-modes-and-the-switch ()
  "The prompt says what each mode does, that it is remembered, and how to change it."
  (let ((prompt nil))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (p &rest _) (setq prompt p) "relay")))
      (claude-emacs-bridge--read-transport))
    (should (string-match-p "relay" prompt))
    (should (string-match-p "socket" prompt))
    (should (string-match-p "[Rr]emember" prompt))
    (should (string-match-p "claude-emacs-bridge-switch-transport" prompt))))

(ert-deftest claude-emacs-bridge-send-test/relay-mode-uses-the-relay-path ()
  "A send in relay mode goes through the relay and not the socket."
  (let ((claude-emacs-bridge--mode 'relay)
        (relay-called nil))
    (cl-letf (((symbol-function 'claude-emacs-bridge--send-via-relay)
               (lambda (&rest _) (setq relay-called t)))
              ((symbol-function 'claude-emacs-bridge--send-via-socket)
               (lambda (&rest _) (error "Wrong path"))))
      (with-temp-buffer
        (setq buffer-file-name "/tmp/example.go")
        (insert "one\ntwo\n")
        (set-buffer-modified-p nil)
        (claude-emacs-bridge-send (point-min) (point-min) "Look here.")))
    (should relay-called)))

(ert-deftest claude-emacs-bridge-send-test/socket-mode-uses-the-socket-path ()
  "A send in socket mode goes through the socket and not the relay."
  (let ((claude-emacs-bridge--mode 'socket)
        (socket-args nil))
    (cl-letf (((symbol-function 'claude-emacs-bridge--send-via-socket)
               (lambda (&rest args) (setq socket-args args)))
              ((symbol-function 'claude-emacs-bridge--send-via-relay)
               (lambda (&rest _) (error "Wrong path"))))
      (with-temp-buffer
        (setq buffer-file-name "/tmp/example.go")
        (insert "one\ntwo\n")
        (set-buffer-modified-p nil)
        (claude-emacs-bridge-send (point-min) (point-min) "Look here.")))
    (should socket-args)
    (should (equal (nth 0 socket-args) '(1 . 1)))
    (should (equal (nth 1 socket-args) "/tmp/example.go"))
    (should (equal (nth 3 socket-args) "Look here."))))

(ert-deftest claude-emacs-bridge--send-via-socket-test/is-not-implemented-yet ()
  "The socket path refuses clearly while it is a stub."
  (should-error (claude-emacs-bridge--send-via-socket '(1 . 1) "/tmp/a.go" nil "x")
                :type 'user-error))

(ert-deftest claude-emacs-bridge-start-test/refuses-in-socket-mode ()
  "Starting the coordinator in socket mode names the active mode and the switch."
  (let ((claude-emacs-bridge--mode 'socket))
    (condition-case err
        (progn (claude-emacs-bridge-start) (should nil))
      (user-error
       (let ((text (error-message-string err)))
         (should (string-match-p "socket" text))
         (should (string-match-p "claude-emacs-bridge-switch-transport" text)))))))

(ert-deftest claude-emacs-bridge-clear-test/refuses-in-socket-mode ()
  "Clearing the coordinator in socket mode names the active mode and the switch."
  (let ((claude-emacs-bridge--mode 'socket))
    (condition-case err
        (progn (claude-emacs-bridge-clear) (should nil))
      (user-error
       (let ((text (error-message-string err)))
         (should (string-match-p "socket" text))
         (should (string-match-p "claude-emacs-bridge-switch-transport" text)))))))

(ert-deftest claude-emacs-bridge-start-test/saved-relay-mode-without-vterm-explains ()
  "A remembered mode whose resources are missing says so instead of failing raw."
  (let ((claude-emacs-bridge--mode 'relay)
        (claude-emacs-bridge-buffer-name
         (generate-new-buffer-name "*claude-emacs-bridge-novterm-test*")))
    ;; Unbind vterm rather than assume it is absent: it is loaded in a real
    ;; Emacs and missing in a batch one, and this test must hold in both.
    (cl-letf (((symbol-function 'vterm) nil)
              ((symbol-function 'require)
               (lambda (feature &rest _)
                 (if (eq feature 'vterm)
                     (signal 'file-missing (list "No such file" "vterm"))
                   feature))))
      (condition-case err
          (progn (claude-emacs-bridge-start) (should nil))
        (user-error
         (let ((text (error-message-string err)))
           (should (string-match-p "relay" text))
           (should (string-match-p "vterm" text))
           (should (string-match-p "claude-emacs-bridge-switch-transport" text))))))))

;;; The receipt socket

(defmacro claude-emacs-bridge-tests--with-receipts (&rest body)
  "Run BODY with a clean log, send table and socket directory."
  (declare (indent 0))
  `(let* ((claude-emacs-bridge-log-buffer-name
           (generate-new-buffer-name "*bridge-receipt-log-test*"))
          (claude-emacs-bridge-log-file nil)
          (claude-emacs-bridge-socket-directory
           (file-name-as-directory (make-temp-file "bridge-socks" t)))
          (claude-emacs-bridge--sends (make-hash-table :test 'equal))
          (claude-emacs-bridge--receipts (make-hash-table :test 'equal))
          (claude-emacs-bridge--receipt-process nil))
     (unwind-protect (progn ,@body)
       (claude-emacs-bridge--release-receipt-socket)
       (when (get-buffer claude-emacs-bridge-log-buffer-name)
         (kill-buffer claude-emacs-bridge-log-buffer-name)))))

(defun claude-emacs-bridge-tests--status-frame (id status &rest extra)
  "Return a status frame line for ID with STATUS and EXTRA fields."
  (concat (json-encode
           (append `((type . "control")
                     (action . "peer_message_status")
                     (status . ,status)
                     (orig_msg_id . ,id)
                     (msgV . 1))
                   extra))
          "\n"))

(ert-deftest claude-emacs-bridge--parse-receipt-test/reads-a-held-frame ()
  "A held frame yields its status and the reason written for a human."
  (let ((frame (claude-emacs-bridge--parse-receipt
                (claude-emacs-bridge-tests--status-frame
                 "id-1" "held" '(reason . "waiting for approval")))))
    (should (equal (alist-get 'status frame) "held"))
    (should (equal (alist-get 'orig_msg_id frame) "id-1"))
    (should (equal (alist-get 'reason frame) "waiting for approval"))))

(ert-deftest claude-emacs-bridge--parse-receipt-test/reads-a-refused-frame ()
  "A refusal arrives as expired with the detail saying why."
  (let ((frame (claude-emacs-bridge--parse-receipt
                (claude-emacs-bridge-tests--status-frame
                 "id-2" "expired" '(status_detail . "refused")))))
    (should (equal (alist-get 'status frame) "expired"))
    (should (equal (alist-get 'status_detail frame) "refused"))))

(ert-deftest claude-emacs-bridge--parse-receipt-test/reads-a-dropped-frame ()
  "A drop carries the reason it was dropped for."
  (let ((frame (claude-emacs-bridge--parse-receipt
                (claude-emacs-bridge-tests--status-frame
                 "id-3" "dropped" '(drop_reason . "duplicate")))))
    (should (equal (alist-get 'status frame) "dropped"))
    (should (equal (alist-get 'drop_reason frame) "duplicate"))))

(ert-deftest claude-emacs-bridge--parse-receipt-test/rejects-unparseable-bytes ()
  "Garbage on the socket is not a frame and must not raise."
  (should-not (claude-emacs-bridge--parse-receipt "not json at all"))
  (should-not (claude-emacs-bridge--parse-receipt ""))
  (should-not (claude-emacs-bridge--parse-receipt "[1,2,3]")))

(ert-deftest claude-emacs-bridge--handle-receipt-test/late-frame-names-its-send ()
  "A frame arriving after the send returned names the file and lines it is about."
  (claude-emacs-bridge-tests--with-receipts
    (let ((shown nil))
      (claude-emacs-bridge--remember-send
       "id-4" '((transport . socket) (target . "task-1") (pid . 7)
                (file . "/tmp/example.go") (lines . "4-7")))
      (cl-letf (((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (setq shown (apply #'format format-string args)))))
        (claude-emacs-bridge--handle-receipt
         (claude-emacs-bridge--parse-receipt
          (claude-emacs-bridge-tests--status-frame
           "id-4" "dropped" '(drop_reason . "duplicate")
           '(reason . "the recipient dropped your message")))))
      (with-current-buffer claude-emacs-bridge-log-buffer-name
        (let ((text (buffer-string)))
          (should (string-match-p "receipt" text))
          (should (string-match-p "late=yes" text))
          (should (string-match-p "id=id-4" text))
          (should (string-match-p "status=dropped" text))
          (should (string-match-p "drop_reason=duplicate" text))
          (should (string-match-p "file=/tmp/example.go" text))
          (should (string-match-p "lines=4-7" text))))
      (should shown)
      (should (string-match-p "/tmp/example.go" shown)))))

(ert-deftest claude-emacs-bridge--handle-receipt-test/waiting-send-is-not-late ()
  "A frame that arrives while the send is still waiting is left for it."
  (claude-emacs-bridge-tests--with-receipts
    (claude-emacs-bridge--remember-send
     "id-5" '((transport . socket) (target . "task-1") (pid . 7)
              (file . "/tmp/a.go") (lines . "1-1") (pending . t)))
    (cl-letf (((symbol-function 'message)
               (lambda (&rest _) (ert-fail "A waiting send reports for itself"))))
      (claude-emacs-bridge--handle-receipt
       (claude-emacs-bridge--parse-receipt
        (claude-emacs-bridge-tests--status-frame "id-5" "held"))))
    (should (gethash "id-5" claude-emacs-bridge--receipts))
    ;; Nothing is logged either: the send reports this in its own outcome.
    (should-not (get-buffer claude-emacs-bridge-log-buffer-name))))

(ert-deftest claude-emacs-bridge--handle-receipt-test/unknown-id-is-kept-verbatim ()
  "A frame matching no send is still evidence and is logged in full."
  (claude-emacs-bridge-tests--with-receipts
    (cl-letf (((symbol-function 'message) (lambda (&rest _) nil)))
      (claude-emacs-bridge--handle-receipt
       (claude-emacs-bridge--parse-receipt
        (claude-emacs-bridge-tests--status-frame "id-nobody" "held"))))
    (with-current-buffer claude-emacs-bridge-log-buffer-name
      (let ((text (buffer-string)))
        (should (string-match-p "uncorrelated=yes" text))
        (should (string-match-p "id-nobody" text))))))

(ert-deftest claude-emacs-bridge--prune-sends-test/drops-records-past-the-window ()
  "A record older than the drop-reporting window is forgotten."
  (claude-emacs-bridge-tests--with-receipts
    (claude-emacs-bridge--remember-send "fresh" '((file . "/tmp/a.go")))
    (puthash "stale"
             (cons (cons 'time (- (float-time)
                                  (* 2 claude-emacs-bridge--send-record-ttl)))
                   '((file . "/tmp/b.go")))
             claude-emacs-bridge--sends)
    (claude-emacs-bridge--prune-sends)
    (should (gethash "fresh" claude-emacs-bridge--sends))
    (should-not (gethash "stale" claude-emacs-bridge--sends))))

(ert-deftest claude-emacs-bridge--receipt-socket-test/binds-over-a-stale-file ()
  "A file left at our own path came from a dead Emacs and is replaced."
  (claude-emacs-bridge-tests--with-receipts
    (let ((path (claude-emacs-bridge--receipt-socket-path)))
      (with-temp-file path (insert "left behind"))
      (should (file-exists-p path))
      (should (equal (claude-emacs-bridge--ensure-receipt-socket) path))
      (should (process-live-p claude-emacs-bridge--receipt-process)))))

(ert-deftest claude-emacs-bridge--receipt-socket-test/binds-once-and-releases ()
  "The socket is bound lazily, reused, and cleaned up with its file."
  (claude-emacs-bridge-tests--with-receipts
    (let* ((path (claude-emacs-bridge--ensure-receipt-socket))
           (process claude-emacs-bridge--receipt-process))
      (should (file-exists-p path))
      (should (eq process (progn (claude-emacs-bridge--ensure-receipt-socket)
                                 claude-emacs-bridge--receipt-process)))
      (claude-emacs-bridge--release-receipt-socket)
      (should-not claude-emacs-bridge--receipt-process)
      (should-not (file-exists-p path)))))

(ert-deftest claude-emacs-bridge--receipt-socket-test/path-carries-the-emacs-pid ()
  "The name identifies this Emacs, so a leftover file is provably from a dead one."
  (claude-emacs-bridge-tests--with-receipts
    (should (string-match-p (format "%d" (emacs-pid))
                            (claude-emacs-bridge--receipt-socket-path)))))

;;; The socket message

(ert-deftest claude-emacs-bridge--socket-content-test/is-three-plain-lines ()
  "The socket content carries the location and the instruction, nothing else."
  (should
   (equal (claude-emacs-bridge--socket-content
           "/tmp/example.go" '(12 . 40) "Review these lines.")
          (concat "File: /tmp/example.go\n"
                  "Lines: 12-40\n"
                  "Instruction: Review these lines."))))

(ert-deftest claude-emacs-bridge--socket-content-test/carries-no-relay-wrapper ()
  "Nothing the relay adds for a model to act on is carried over."
  (let ((content (claude-emacs-bridge--socket-content
                  "/tmp/example.go" '(1 . 2) "Do the thing.")))
    (should-not (string-match-p "BEGIN TARGET MESSAGE" content))
    (should-not (string-match-p "END TARGET MESSAGE" content))
    (should-not (string-match-p "SendMessage" content))
    (should-not (string-match-p "@" content))))

(ert-deftest claude-emacs-bridge--socket-content-test/leaves-an-at-path-alone ()
  "An at-mention reaches the target unescaped.
Escaping exists because the relay types into an input box.  Nothing is typed
here, so the two message formats must not quietly converge."
  (let ((content (claude-emacs-bridge--socket-content
                  "/tmp/example.go" '(1 . 2)
                  "inline it into @/tmp/download.sh")))
    (should (string-match-p "inline it into @/tmp/download\\.sh" content))
    (should-not (string-match-p "\\\\@" content))))

(ert-deftest claude-emacs-bridge--uds-address-test/prefixes-and-encodes ()
  "A receipt address is the socket path behind a uds prefix."
  (let ((address (claude-emacs-bridge--uds-address "/tmp/cc-socks/x.sock")))
    (should (string-prefix-p "uds:" address))
    (should (string-match-p "cc-socks" address))))

(ert-deftest claude-emacs-bridge--socket-frame-test/carries-the-required-fields ()
  "The frame is one JSON object with the fields a recipient reads."
  (let* ((frame (claude-emacs-bridge--socket-frame
                 "File: /tmp/a.go\nLines: 1-2\nInstruction: go"
                 "11111111-1111-4111-8111-111111111111"
                 "uds:/tmp/cc-socks/r.sock"))
         (parsed (json-parse-string (string-trim frame)
                                    :object-type 'alist
                                    :array-type 'list
                                    :null-object nil
                                    :false-object nil)))
    (should (equal (alist-get 'type parsed) "user"))
    (should (equal (alist-get 'msgV parsed) 1))
    (should (equal (alist-get 'msg_id parsed)
                   "11111111-1111-4111-8111-111111111111"))
    (should (equal (alist-get 'from parsed) "uds:/tmp/cc-socks/r.sock"))
    (should (equal (alist-get 'content (alist-get 'message parsed))
                   "File: /tmp/a.go\nLines: 1-2\nInstruction: go"))))

(ert-deftest claude-emacs-bridge--socket-frame-test/is-one-newline-terminated-line ()
  "Framing is newline-delimited JSON, so the object holds no raw newline."
  (let ((frame (claude-emacs-bridge--socket-frame
                "one\ntwo" "11111111-1111-4111-8111-111111111111" "uds:/x")))
    (should (string-suffix-p "\n" frame))
    (should (= (cl-count ?\n frame) 1))))

(ert-deftest claude-emacs-bridge--socket-frame-test/omits-an-absent-from ()
  "Without a receipt address the field is left out rather than sent empty."
  (let* ((frame (claude-emacs-bridge--socket-frame
                 "body" "11111111-1111-4111-8111-111111111111" nil))
         (parsed (json-parse-string (string-trim frame)
                                    :object-type 'alist
                                    :array-type 'list
                                    :null-object nil
                                    :false-object nil)))
    (should-not (alist-get 'from parsed))
    (should (equal (alist-get 'type parsed) "user"))))

;;; Registry discovery

(defun claude-emacs-bridge-tests--registry (rows)
  "Write ROWS as registry JSON files into a fresh directory and return it.
Each row is a cons of a basename and a JSON string."
  (let ((dir (file-name-as-directory (make-temp-file "bridge-registry" t))))
    (dolist (row rows)
      (with-temp-file (expand-file-name (car row) dir)
        (insert (cdr row))))
    dir))

(defun claude-emacs-bridge-tests--row (&rest overrides)
  "Return registry JSON for a usable row, with OVERRIDES applied as a plist."
  (let ((fields (list :pid 101 :name "task-1" :socket 'make
                      :sessionId "11111111-1111-1111-1111-111111111111"
                      :cwd "/tmp/one" :status "idle" :startedAt 500)))
    (while overrides
      (let ((key (pop overrides)) (value (pop overrides)))
        (setq fields (plist-put fields key value))))
    (let ((socket (plist-get fields :socket)))
      (when (eq socket 'make)
        (setq socket (make-temp-file "bridge-sock")))
      (json-encode
       (append
        (when (plist-get fields :pid) `((pid . ,(plist-get fields :pid))))
        (when (plist-get fields :name) `((name . ,(plist-get fields :name))))
        (when socket `((messagingSocketPath . ,socket)))
        (when (plist-get fields :sessionId)
          `((sessionId . ,(plist-get fields :sessionId))))
        (when (plist-get fields :cwd) `((cwd . ,(plist-get fields :cwd))))
        `((status . ,(plist-get fields :status))
          (startedAt . ,(plist-get fields :startedAt))))))))

(ert-deftest claude-emacs-bridge--registry-sessions-test/keeps-a-usable-row ()
  "A row with a live socket, a name, a pid, a session id and a cwd is a target."
  (let* ((dir (claude-emacs-bridge-tests--registry
               (list (cons "101.json" (claude-emacs-bridge-tests--row)))))
         (claude-emacs-bridge-registry-directory dir)
         (sessions (claude-emacs-bridge--registry-sessions)))
    (should (= (length sessions) 1))
    (should (equal (alist-get 'name (car sessions)) "task-1"))
    (should (= (alist-get 'pid (car sessions)) 101))
    (should (alist-get 'startedAt (car sessions)))))

(ert-deftest claude-emacs-bridge--registry-sessions-test/drops-a-row-with-no-socket-path ()
  "A row that binds no inbox socket cannot be delivered to.
Same reason the relay path drops background agents."
  (let* ((dir (claude-emacs-bridge-tests--registry
               (list (cons "102.json"
                           (claude-emacs-bridge-tests--row :socket nil)))))
         (claude-emacs-bridge-registry-directory dir))
    (should-not (claude-emacs-bridge--registry-sessions))))

(ert-deftest claude-emacs-bridge--registry-sessions-test/drops-a-row-whose-socket-is-gone ()
  "A session that died leaves its row behind but not its socket."
  (let* ((dir (claude-emacs-bridge-tests--registry
               (list (cons "103.json"
                           (claude-emacs-bridge-tests--row
                            :socket "/tmp/cc-socks/definitely-not-here.sock")))))
         (claude-emacs-bridge-registry-directory dir))
    (should-not (claude-emacs-bridge--registry-sessions))))

(ert-deftest claude-emacs-bridge--registry-sessions-test/drops-a-row-missing-identity ()
  "A row without a session id or a cwd cannot resolve a transcript later."
  (let* ((dir (claude-emacs-bridge-tests--registry
               (list (cons "104.json"
                           (claude-emacs-bridge-tests--row :sessionId nil))
                     (cons "105.json"
                           (claude-emacs-bridge-tests--row :cwd nil))
                     (cons "106.json"
                           (claude-emacs-bridge-tests--row :name ""))
                     (cons "107.json"
                           (claude-emacs-bridge-tests--row :pid nil)))))
         (claude-emacs-bridge-registry-directory dir))
    (should-not (claude-emacs-bridge--registry-sessions))))

(ert-deftest claude-emacs-bridge--registry-sessions-test/survives-unreadable-json ()
  "One corrupt file does not hide every other session."
  (let* ((dir (claude-emacs-bridge-tests--registry
               (list (cons "108.json" "{not json")
                     (cons "109.json" (claude-emacs-bridge-tests--row)))))
         (claude-emacs-bridge-registry-directory dir)
         (sessions (claude-emacs-bridge--registry-sessions)))
    (should (= (length sessions) 1))))

(ert-deftest claude-emacs-bridge--registry-sessions-test/missing-directory-is-empty ()
  "A registry directory that does not exist yields no targets rather than an error."
  (let ((claude-emacs-bridge-registry-directory "/tmp/bridge-no-such-registry/"))
    (should-not (claude-emacs-bridge--registry-sessions))))

(ert-deftest claude-emacs-bridge--discover-sessions-test/dispatches-on-the-mode ()
  "Each mode reads its own source, and no caller passes a session list."
  (let ((claude-emacs-bridge--mode 'relay)
        (called nil))
    (cl-letf (((symbol-function 'claude-emacs-bridge--discover-sessions-cli)
               (lambda () (setq called 'cli) '(cli)))
              ((symbol-function 'claude-emacs-bridge--registry-sessions)
               (lambda () (setq called 'registry) '(registry))))
      (should (equal (claude-emacs-bridge--discover-sessions) '(cli)))
      (should (eq called 'cli))
      (setq claude-emacs-bridge--mode 'socket)
      (should (equal (claude-emacs-bridge--discover-sessions) '(registry)))
      (should (eq called 'registry)))))

(ert-deftest claude-emacs-bridge--discover-sessions-test/takes-no-arguments ()
  "The coordinator pid argument is gone; it belonged to the relay branch."
  (should (equal (func-arity 'claude-emacs-bridge--discover-sessions) '(0 . 0))))

;;; The log

(ert-deftest claude-emacs-bridge--uuid-test/differs-each-call ()
  "Send ids are distinct and shaped like a UUID."
  (let ((a (claude-emacs-bridge--uuid))
        (b (claude-emacs-bridge--uuid)))
    (should-not (equal a b))
    (should (string-match-p
             "\\`[0-9a-f]\\{8\\}-[0-9a-f]\\{4\\}-4[0-9a-f]\\{3\\}-[89ab][0-9a-f]\\{3\\}-[0-9a-f]\\{12\\}\\'"
             a))))

(ert-deftest claude-emacs-bridge--log-event-test/writes-one-searchable-line ()
  "An event is one line of key=value fields after a timestamp and a name."
  (let ((claude-emacs-bridge-log-buffer-name
         (generate-new-buffer-name "*bridge-log-line-test*"))
        (claude-emacs-bridge-log-file nil))
    (unwind-protect
        (progn
          (claude-emacs-bridge--log-event 'send :transport 'relay :pid 42)
          (with-current-buffer claude-emacs-bridge-log-buffer-name
            (let ((text (buffer-string)))
              (should (= (length (split-string (string-trim text) "\n")) 1))
              (should (string-match-p " send " text))
              (should (string-match-p "transport=relay" text))
              (should (string-match-p "pid=42" text)))))
      (when (get-buffer claude-emacs-bridge-log-buffer-name)
        (kill-buffer claude-emacs-bridge-log-buffer-name)))))

(ert-deftest claude-emacs-bridge--log-event-test/quotes-a-multiline-payload ()
  "A payload with newlines stays on one line, quoted."
  (let ((claude-emacs-bridge-log-buffer-name
         (generate-new-buffer-name "*bridge-log-quote-test*"))
        (claude-emacs-bridge-log-file nil))
    (unwind-protect
        (progn
          (claude-emacs-bridge--log-event 'send :content "one\ntwo three")
          (with-current-buffer claude-emacs-bridge-log-buffer-name
            (let ((text (buffer-string)))
              (should (= (length (split-string (string-trim text) "\n")) 1))
              (should (string-match-p "content=\"one\\\\ntwo three\"" text)))))
      (when (get-buffer claude-emacs-bridge-log-buffer-name)
        (kill-buffer claude-emacs-bridge-log-buffer-name)))))

(ert-deftest claude-emacs-bridge--log-event-test/omits-empty-fields ()
  "A field with no value is left out rather than logged as nothing."
  (let ((claude-emacs-bridge-log-buffer-name
         (generate-new-buffer-name "*bridge-log-omit-test*"))
        (claude-emacs-bridge-log-file nil))
    (unwind-protect
        (progn
          (claude-emacs-bridge--log-event 'send :transport 'socket :socket nil)
          (with-current-buffer claude-emacs-bridge-log-buffer-name
            (should-not (string-match-p "socket=" (buffer-string)))))
      (when (get-buffer claude-emacs-bridge-log-buffer-name)
        (kill-buffer claude-emacs-bridge-log-buffer-name)))))

(ert-deftest claude-emacs-bridge--log-event-test/appends-to-the-file-sink ()
  "With a log file set, each event is appended to it."
  (let* ((claude-emacs-bridge-log-buffer-name
          (generate-new-buffer-name "*bridge-log-file-test*"))
         (path (make-temp-file "bridge-log-test"))
         (claude-emacs-bridge-log-file path))
    (unwind-protect
        (progn
          (claude-emacs-bridge--log-event 'send :id "abc")
          (claude-emacs-bridge--log-event 'outcome :id "abc")
          (with-temp-buffer
            (insert-file-contents path)
            (let ((lines (split-string (string-trim (buffer-string)) "\n")))
              (should (= (length lines) 2))
              (should (string-match-p "id=abc" (car lines))))))
      (delete-file path)
      (when (get-buffer claude-emacs-bridge-log-buffer-name)
        (kill-buffer claude-emacs-bridge-log-buffer-name)))))

(ert-deftest claude-emacs-bridge--log-event-test/file-sink-off-writes-nothing ()
  "With no log file set, nothing is written to disk."
  (let* ((claude-emacs-bridge-log-buffer-name
          (generate-new-buffer-name "*bridge-log-nofile-test*"))
         (claude-emacs-bridge-log-file nil)
         (wrote nil))
    (unwind-protect
        (cl-letf (((symbol-function 'write-region)
                   (lambda (&rest _) (setq wrote t))))
          (claude-emacs-bridge--log-event 'send :id "abc")
          (should-not wrote))
      (when (get-buffer claude-emacs-bridge-log-buffer-name)
        (kill-buffer claude-emacs-bridge-log-buffer-name)))))

(ert-deftest claude-emacs-bridge--log-send-test/records-what-was-actually-sent ()
  "The send entry carries the id, transport, target and the bytes that went out."
  (let ((claude-emacs-bridge-log-buffer-name
         (generate-new-buffer-name "*bridge-log-send-test*"))
        (claude-emacs-bridge-log-file nil))
    (unwind-protect
        (progn
          (claude-emacs-bridge--log-send
           "id-1" 'relay '((name . "task-1") (pid . 7))
           "/tmp/example.go" '(4 . 7) "PROMPT BODY" nil nil)
          (with-current-buffer claude-emacs-bridge-log-buffer-name
            (let ((text (buffer-string)))
              (should (string-match-p "id=id-1" text))
              (should (string-match-p "transport=relay" text))
              (should (string-match-p "target=task-1" text))
              (should (string-match-p "pid=7" text))
              (should (string-match-p "file=/tmp/example.go" text))
              (should (string-match-p "lines=4-7" text))
              (should (string-match-p "content=\"PROMPT BODY\"" text)))))
      (when (get-buffer claude-emacs-bridge-log-buffer-name)
        (kill-buffer claude-emacs-bridge-log-buffer-name)))))

(ert-deftest claude-emacs-bridge--log-send-test/frame-option-off-omits-the-frame ()
  "The raw frame is logged only when the option asks for it."
  (let ((claude-emacs-bridge-log-buffer-name
         (generate-new-buffer-name "*bridge-log-frame-test*"))
        (claude-emacs-bridge-log-file nil))
    (unwind-protect
        (progn
          (let ((claude-emacs-bridge-log-frames nil))
            (claude-emacs-bridge--log-send
             "id-2" 'socket '((name . "task-1") (pid . 7))
             "/tmp/a.go" '(1 . 1) "body" "/tmp/cc-socks/7.sock" "{\"type\":\"user\"}"))
          (with-current-buffer claude-emacs-bridge-log-buffer-name
            (should-not (string-match-p "frame=" (buffer-string)))
            (let ((inhibit-read-only t)) (erase-buffer)))
          (let ((claude-emacs-bridge-log-frames t))
            (claude-emacs-bridge--log-send
             "id-3" 'socket '((name . "task-1") (pid . 7))
             "/tmp/a.go" '(1 . 1) "body" "/tmp/cc-socks/7.sock" "{\"type\":\"user\"}"))
          (with-current-buffer claude-emacs-bridge-log-buffer-name
            (let ((text (buffer-string)))
              (should (string-match-p "frame=" text))
              (should (string-match-p "socket=/tmp/cc-socks/7.sock" text)))))
      (when (get-buffer claude-emacs-bridge-log-buffer-name)
        (kill-buffer claude-emacs-bridge-log-buffer-name)))))

(ert-deftest claude-emacs-bridge--log-outcome-test/carries-the-send-id-and-result ()
  "The outcome entry can be found by the same id as its send."
  (let ((claude-emacs-bridge-log-buffer-name
         (generate-new-buffer-name "*bridge-log-outcome-test*"))
        (claude-emacs-bridge-log-file nil))
    (unwind-protect
        (progn
          (claude-emacs-bridge--log-outcome "id-9" 'unconfirmed "no reply came")
          (with-current-buffer claude-emacs-bridge-log-buffer-name
            (let ((text (buffer-string)))
              (should (string-match-p "id=id-9" text))
              (should (string-match-p "result=unconfirmed" text))
              (should (string-match-p "reason=\"no reply came\"" text)))))
      (when (get-buffer claude-emacs-bridge-log-buffer-name)
        (kill-buffer claude-emacs-bridge-log-buffer-name)))))

(ert-deftest claude-emacs-bridge--log-status-test/is-one-event-line ()
  "Status entries share the one-line format so the buffer stays searchable."
  (let ((claude-emacs-bridge-log-buffer-name
         (generate-new-buffer-name "*bridge-log-status-test*"))
        (claude-emacs-bridge-log-file nil))
    (unwind-protect
        (progn
          (claude-emacs-bridge--log-status "Coordinator is not running")
          (with-current-buffer claude-emacs-bridge-log-buffer-name
            (let ((text (string-trim (buffer-string))))
              (should (= (length (split-string text "\n")) 1))
              (should (string-match-p " status " text))
              (should (string-match-p "Coordinator is not running" text)))))
      (when (get-buffer claude-emacs-bridge-log-buffer-name)
        (kill-buffer claude-emacs-bridge-log-buffer-name)))))

(ert-deftest claude-emacs-bridge-show-log-test/pops-to-the-log ()
  "The log has a command of its own instead of only appearing after a send."
  (let ((claude-emacs-bridge-log-buffer-name
         (generate-new-buffer-name "*bridge-show-log-test*"))
        (claude-emacs-bridge-log-file nil)
        (popped nil))
    (unwind-protect
        (cl-letf (((symbol-function 'pop-to-buffer)
                   (lambda (buffer &rest _) (setq popped buffer) buffer)))
          (claude-emacs-bridge-show-log)
          (should (bufferp popped))
          (should (equal (buffer-name popped)
                         claude-emacs-bridge-log-buffer-name)))
      (when (get-buffer claude-emacs-bridge-log-buffer-name)
        (kill-buffer claude-emacs-bridge-log-buffer-name)))))

;;; Paste submission recovery

(ert-deftest claude-emacs-bridge--pending-paste-test/detects-collapsed-paste ()
  "An input box holding a collapsed paste reports a pending paste."
  (with-temp-buffer
    (insert "> [5 lines pasted]\n")
    (should (claude-emacs-bridge--pending-paste-p (current-buffer)))))

(ert-deftest claude-emacs-bridge--pending-paste-test/detects-alternate-wording ()
  "Detection does not depend on Claude Code's exact placeholder wording."
  (with-temp-buffer
    (insert "> [Pasted text #1 +11 lines]\n")
    (should (claude-emacs-bridge--pending-paste-p (current-buffer)))))

(ert-deftest claude-emacs-bridge--pending-paste-test/ignores-submitted-input ()
  "A cleared input box reports no pending paste."
  (with-temp-buffer
    (insert "> \n")
    (should-not (claude-emacs-bridge--pending-paste-p (current-buffer)))))

(ert-deftest claude-emacs-bridge--pending-paste-test/ignores-old-scrollback ()
  "A placeholder scrolled out of the input box does not count as pending."
  (with-temp-buffer
    (insert "> [5 lines pasted]\n")
    (insert (make-string (* 4 claude-emacs-bridge--paste-tail-window) ?x))
    (insert "\n> \n")
    (should-not (claude-emacs-bridge--pending-paste-p (current-buffer)))))

(ert-deftest claude-emacs-bridge--wait-for-paste-clear-test/returns-immediately ()
  "Waiting returns at once when the input box is already clear."
  (with-temp-buffer
    (insert "> \n")
    (let ((claude-emacs-bridge-submit-resend-interval 5.0)
          (start (float-time)))
      (should (claude-emacs-bridge--wait-for-paste-clear (current-buffer)))
      (should (< (- (float-time) start) 1.0)))))

(ert-deftest claude-emacs-bridge--wait-for-paste-clear-test/gives-up-after-interval ()
  "Waiting stops after one resend interval while the paste is still pending."
  (with-temp-buffer
    (insert "> [5 lines pasted]\n")
    (let ((claude-emacs-bridge-submit-resend-interval 0.15)
          (claude-emacs-bridge-submit-poll-interval 0.01))
      (should-not (claude-emacs-bridge--wait-for-paste-clear (current-buffer))))))

(ert-deftest claude-emacs-bridge--await-submit-test/no-resend-when-already-submitted ()
  "A carriage return that landed is not followed by another one."
  (with-temp-buffer
    (insert "> \n")
    (let ((resends 0))
      (cl-letf (((symbol-function 'vterm-send-return)
                 (lambda () (setq resends (1+ resends)))))
        (should (claude-emacs-bridge--await-submit (current-buffer))))
      (should (= resends 0)))))

(ert-deftest claude-emacs-bridge--await-submit-test/resends-until-input-clears ()
  "A swallowed carriage return is resent until the input box clears."
  (with-temp-buffer
    (insert "> [5 lines pasted]\n")
    (let ((resends 0)
          (buffer (current-buffer))
          (claude-emacs-bridge-submit-resend-interval 0.05)
          (claude-emacs-bridge-submit-poll-interval 0.01))
      (cl-letf (((symbol-function 'vterm-send-return)
                 (lambda ()
                   (setq resends (1+ resends))
                   ;; The second carriage return is the one Claude Code takes.
                   (when (= resends 2)
                     (with-current-buffer buffer
                       (erase-buffer)
                       (insert "> \n"))))))
        (should (claude-emacs-bridge--await-submit buffer)))
      (should (= resends 2)))))

(ert-deftest claude-emacs-bridge--await-submit-test/gives-up-after-max-resends ()
  "Resending is bounded so a stuck coordinator is not flooded."
  (with-temp-buffer
    (insert "> [5 lines pasted]\n")
    (let ((resends 0)
          (claude-emacs-bridge-submit-resend-interval 0.02)
          (claude-emacs-bridge-submit-poll-interval 0.01)
          (claude-emacs-bridge-submit-max-resends 3))
      (cl-letf (((symbol-function 'vterm-send-return)
                 (lambda () (setq resends (1+ resends)))))
        (should-not (claude-emacs-bridge--await-submit (current-buffer))))
      (should (= resends 3)))))

(ert-deftest claude-emacs-bridge-send-test/resends-return-when-paste-is-not-submitted ()
  "A send whose carriage return is swallowed resends it and still reports success."
  (let* ((claude-emacs-bridge--mode 'relay)
         (claude-emacs-bridge-buffer-name
          (generate-new-buffer-name "*claude-emacs-bridge-resend-test*"))
         (claude-emacs-bridge-log-buffer-name
          (generate-new-buffer-name "*claude-emacs-bridge-resend-log-test*"))
         (claude-emacs-bridge-log-file nil)
         (claude-emacs-bridge-submit-resend-interval 0.05)
         (claude-emacs-bridge-submit-poll-interval 0.01)
         (coordinator
          (generate-new-buffer claude-emacs-bridge-buffer-name))
         (returns 0)
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
                     (lambda (_string &optional _paste-p)
                       ;; Claude Code collapses the paste but does not submit it.
                       (with-current-buffer coordinator
                         (erase-buffer)
                         (insert "> [5 lines pasted]\n"))))
                    ((symbol-function 'vterm-send-return)
                     (lambda ()
                       (setq returns (1+ returns))
                       (when (= returns 2)
                         (with-current-buffer coordinator
                           (erase-buffer)
                           (insert "> \n")))))
                    ((symbol-function 'message)
                     (lambda (format-string &rest args)
                       (setq reported-message
                             (apply #'format format-string args)))))
            (with-temp-buffer
              (setq buffer-file-name "/tmp/example.go")
              (insert "one\ntwo\n")
              (set-buffer-modified-p nil)
              (claude-emacs-bridge-send (point-min) (point-min) "Look here.")))
          (should (= returns 2))
          (should
           (equal reported-message
                  "Sent to task-1: /tmp/example.go lines 1-1"))
          (with-current-buffer claude-emacs-bridge-log-buffer-name
            (should-not (string-match-p "may not have been submitted"
                                        (buffer-string)))))
      (when (get-buffer claude-emacs-bridge-log-buffer-name)
        (kill-buffer claude-emacs-bridge-log-buffer-name))
      (kill-buffer coordinator))))

(ert-deftest claude-emacs-bridge-send-test/logs-status-when-submit-never-lands ()
  "A send that never submits logs the failure instead of reporting success."
  (let* ((claude-emacs-bridge--mode 'relay)
         (claude-emacs-bridge-buffer-name
          (generate-new-buffer-name "*claude-emacs-bridge-stuck-test*"))
         (claude-emacs-bridge-log-buffer-name
          (generate-new-buffer-name "*claude-emacs-bridge-stuck-log-test*"))
         (claude-emacs-bridge-log-file nil)
         (claude-emacs-bridge-submit-resend-interval 0.02)
         (claude-emacs-bridge-submit-poll-interval 0.01)
         (coordinator
          (generate-new-buffer claude-emacs-bridge-buffer-name))
         (reported-message nil))
    (unwind-protect
        (progn
          (with-current-buffer coordinator
            (setq-local claude-emacs-bridge--coordinator-p t)
            (insert "> [5 lines pasted]\n"))
          (cl-letf (((symbol-function 'claude-emacs-bridge--resolve-target)
                     (lambda () '((name . "task-1") (pid . 1))))
                    ((symbol-function 'derived-mode-p) (lambda (&rest _) t))
                    ((symbol-function 'vterm-check-proc) (lambda (&optional _) t))
                    ((symbol-function 'vterm-send-string)
                     (lambda (_string &optional _paste-p) nil))
                    ((symbol-function 'vterm-send-return) (lambda () nil))
                    ((symbol-function 'message)
                     (lambda (format-string &rest args)
                       (setq reported-message
                             (apply #'format format-string args)))))
            (with-temp-buffer
              (setq buffer-file-name "/tmp/example.go")
              (insert "one\ntwo\n")
              (set-buffer-modified-p nil)
              (claude-emacs-bridge-send (point-min) (point-min) "Look here.")))
          (with-current-buffer claude-emacs-bridge-log-buffer-name
            (should (string-match-p "may not have been submitted"
                                    (buffer-string))))
          (should (string-match-p "may not have been submitted"
                                  reported-message)))
      (when (get-buffer claude-emacs-bridge-log-buffer-name)
        (kill-buffer claude-emacs-bridge-log-buffer-name))
      (kill-buffer coordinator))))

(provide 'claude-emacs-bridge-tests)
;;; claude-emacs-bridge-tests.el ends here
