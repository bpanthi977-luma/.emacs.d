;;; agent-sessions-lock-test.el --- Tests for emacs-lock  -*- lexical-binding: t; -*-

;; These drive the real `bin/emacs-lock' against a database the real schema
;; code created, because the CLI and Emacs meet only at the table layout: a
;; test of either side alone would not notice the two drifting apart.

(require 'ert)
(require 'agent-sessions)

(defvar bp/lock-test--db nil "The temp database file of the running test.")

(defmacro bp/lock-test-with-db (&rest body)
  "Run BODY against a fresh database created by the schema code."
  (declare (indent 0) (debug t))
  `(let* ((db-file (make-temp-file "agent-locks-test-" nil ".db"))
          (bp/lock-test--db db-file)
          (bp/agent-sessions-db-file db-file)
          (bp/agent-sessions--db nil)
          (bp/agent-locks--held nil)
          (bp/agent-locks--waiters nil)
          (bp/agent-locks--loaded-p nil))
     (unwind-protect
         (progn (bp/agent-sessions--db) ,@body)
       (when (sqlitep bp/agent-sessions--db)
         (sqlite-close bp/agent-sessions--db))
       (dolist (path (list db-file (concat db-file "-wal") (concat db-file "-shm")))
         (when (file-exists-p path) (delete-file path))))))

(defun bp/lock-test--env (who &optional extra)
  "An environment for running as holder WHO (nil for no identity) plus EXTRA.
Every inherited agent identity is dropped, and the dashboard poke goes to
`true', so a test can never reach the user's Emacs."
  (append extra
          (and who (list (concat "CLAUDE_CODE_SESSION_ID=" who)))
          (list (concat "EMACS_AGENT_SESSIONS_DB=" bp/lock-test--db)
                "EMACS_LOCK_EMACSCLIENT=true")
          (seq-remove (lambda (entry)
                        (string-match-p
                         "\\`\\(CLAUDE_CODE_SESSION_ID\\|CLAUDE_PID\\|CODEX_THREAD_ID\\|CODEX_SESSION_ID\\|EMACS_AGENT_SESSION_ID\\|EMACS_AGENT_SESSIONS_DB\\)="
                         entry))
                      process-environment)))

(defun bp/lock-test--cli ()
  (expand-file-name "emacs-lock" bp/agent-sessions--bin-dir))

(defun bp/lock-test--run (who &rest args)
  "Run emacs-lock ARGS as WHO; return (EXIT-CODE . OUTPUT).
WHO is a session id, nil, or (ID . EXTRA-ENVIRONMENT)."
  (let ((process-environment
         (if (consp who) (bp/lock-test--env (car who) (cdr who))
           (bp/lock-test--env who))))
    (with-temp-buffer
      (let ((code (apply #'call-process (bp/lock-test--cli) nil t nil args)))
        (cons code (buffer-string))))))

(defun bp/lock-test--start (who &rest args)
  "Start emacs-lock ARGS as WHO in the background; return the process."
  (let ((process-environment (bp/lock-test--env who)))
    (make-process :name "emacs-lock-test" :buffer (generate-new-buffer " *lock-test*")
                  :command (cons (bp/lock-test--cli) args)
                  :connection-type 'pipe :noquery t)))

(defun bp/lock-test--wait-exit (proc &optional seconds)
  "Wait up to SECONDS for PROC to exit; return its exit code or nil."
  (let ((deadline (+ (float-time) (or seconds 10))))
    (while (and (process-live-p proc) (< (float-time) deadline))
      (accept-process-output proc 0.1))
    (unless (process-live-p proc) (process-exit-status proc))))

(defun bp/lock-test--rows (sql &rest args)
  (sqlite-select (bp/agent-sessions--db) sql args))

(defun bp/lock-test--new (who name)
  "Have WHO be shown the known names, then create NAME, holding it.
The refusal of an unknown name is what shows them."
  (bp/lock-test--run who "acquire" name)
  (bp/lock-test--run who "acquire" name "--new" (concat name " resource")))

;;; Acquire and release

(ert-deftest bp/lock-acquire-release-round-trip ()
  (bp/lock-test-with-db
    (should (equal 0 (car (bp/lock-test--new "A" "stack"))))
    (should (string-match-p "already held" (cdr (bp/lock-test--run "A" "acquire" "stack"))))
    (let ((held (bp/lock-test--run "B" "acquire" "stack")))
      (should (equal 1 (car held)))
      (should (string-match-p "HELD stack by:\n  stack  held by A" (cdr held))))
    (should (equal 1 (car (bp/lock-test--run "B" "release" "stack"))))
    (should (equal 0 (car (bp/lock-test--run "A" "release" "stack"))))
    (should (equal 1 (car (bp/lock-test--run "A" "release" "stack"))))
    (should (equal 0 (car (bp/lock-test--run "B" "acquire" "stack"))))))

(ert-deftest bp/lock-names-are-normalised ()
  (bp/lock-test-with-db
    (bp/lock-test--new "A" "Local  Dev\tStack")
    (should (equal '(("local-dev-stack")) (bp/lock-test--rows "SELECT name FROM locks")))
    (should (string-match-p "already held"
                            (cdr (bp/lock-test--run "A" "acquire" " LOCAL dev stack "))))))

(ert-deftest bp/lock-refuses-unknown-name-and-lists-recent-ones ()
  (bp/lock-test-with-db
    (bp/lock-test--new "A" "stack")
    (let ((out (bp/lock-test--run "B" "acquire" "db")))
      (should (equal 1 (car out)))
      (should (string-match-p "unknown lock name: db" (cdr out)))
      (should (string-match-p "  stack  stack resource" (cdr out))))
    (should (equal '(("stack")) (bp/lock-test--rows "SELECT name FROM lock_names")))))

(ert-deftest bp/lock-new-name-requires-having-seen-the-newest ()
  "A creates a name; B's creation is refused until B has been shown A's
name, and then succeeds."
  (bp/lock-test-with-db
    (should (equal 0 (car (bp/lock-test--run "A" "acquire" "stack" "--new" "the stack"))))
    (let ((out (bp/lock-test--run "B" "acquire" "db" "--new" "db")))
      (should (equal 1 (car out)))
      (should (string-match-p "names were added since you last looked" (cdr out)))
      (should (string-match-p "  stack  the stack" (cdr out))))
    (should (equal 0 (car (bp/lock-test--run "B" "acquire" "db" "--new" "db"))))
    (should (equal '(("stack") ("db"))
                   (bp/lock-test--rows "SELECT name FROM lock_names ORDER BY id")))))

(ert-deftest bp/lock-directories-conflict-by-containment ()
  (bp/lock-test-with-db
    (let* ((root (file-truename (make-temp-file "lock-dirs-" t)))
           (parent (expand-file-name "a_b" root))
           (child (expand-file-name "c d" parent))
           (sibling (expand-file-name "axb" root))
           (quoted (expand-file-name "x'y" root)))
      (unwind-protect
          (progn
            (dolist (d (list child sibling quoted)) (make-directory d t))
            (should (equal 0 (car (bp/lock-test--run "A" "acquire" parent))))
            ;; Inside, and around, a held directory: both blocked.
            (should (equal 1 (car (bp/lock-test--run "B" "acquire" child))))
            (should (equal 1 (car (bp/lock-test--run "B" "acquire" root))))
            ;; `_' is not a wildcard, and quotes survive.
            (should (equal 0 (car (bp/lock-test--run "B" "acquire" sibling))))
            (should (equal 0 (car (bp/lock-test--run "B" "acquire" quoted))))
            (should (equal (list (list (concat quoted "/")))
                           (bp/lock-test--rows "SELECT name FROM locks WHERE name LIKE '%y/'")))
            ;; Directories never enter the name registry.
            (should (null (bp/lock-test--rows "SELECT * FROM lock_names"))))
        (delete-directory root t)))))

(ert-deftest bp/lock-concurrent-acquires-have-one-winner ()
  (bp/lock-test-with-db
    (bp/lock-test--new "seed" "stack")
    (bp/lock-test--run "seed" "release" "stack")
    (let* ((procs (mapcar (lambda (i) (bp/lock-test--start (format "W%d" i) "acquire" "stack"))
                          (number-sequence 1 8)))
           (codes (mapcar #'bp/lock-test--wait-exit procs)))
      (should (equal 1 (seq-count (lambda (c) (eql c 0)) codes)))
      (should (equal 7 (seq-count (lambda (c) (eql c 1)) codes)))
      (should (equal 1 (caar (bp/lock-test--rows "SELECT count(*) FROM locks")))))))

;;; Listing

(ert-deftest bp/lock-list-shows-held-names-and-queue-length ()
  (bp/lock-test-with-db
    (should (equal "HELD: none\n" (cdr (bp/lock-test--run "A" "list"))))
    (let ((dir (file-truename (make-temp-file "lock-list-" t))))
      (unwind-protect
          (progn
            (bp/lock-test--run "A" "acquire" dir)
            (bp/lock-test--new "A" "stack")
            (sqlite-execute (bp/agent-sessions--db)
                            "INSERT INTO lock_waiters (name, is_dir, waiter_kind, waiter_key, waiter_label, expires_at)
                             VALUES ('stack', 0, 'session', 'B', 'B', ?), ('stack', 0, 'session', 'C', 'C', ?)"
                            (list (+ (bp/agent-sessions--now) 60) (+ (bp/agent-sessions--now) 60)))
            (should (equal (format "HELD:\n%s\nstack (2 waiting)\n" dir)
                           (cdr (bp/lock-test--run "B" "list"))))
            (let ((verbose (cdr (bp/lock-test--run "B" "list" "--verbose"))))
              (should (string-match-p "held by A" verbose))
              (should (string-match-p "^WAITING:\n  stack  queued: B" verbose))))
        (delete-directory dir t)))))

(ert-deftest bp/lock-list-does-not-count-as-seeing-names ()
  "`list' shows no unheld names, so it must not let a later --new through."
  (bp/lock-test-with-db
    (bp/lock-test--new "A" "stack")
    (bp/lock-test--run "A" "release" "stack")
    (bp/lock-test--run "B" "list")
    (let ((out (bp/lock-test--run "B" "acquire" "db" "--new" "a database")))
      (should (equal 1 (car out)))
      (should (string-match-p "  stack  stack resource" (cdr out))))))

;;; Waiting

(ert-deftest bp/lock-wait-is-first-come-first-served ()
  (bp/lock-test-with-db
    (bp/lock-test--new "H" "stack")
    (let ((q1 (bp/lock-test--start "Q1" "wait" "stack" "--interval" "1")))
      (sleep-for 1.5)
      (let ((q2 (bp/lock-test--start "Q2" "wait" "stack" "--interval" "1")))
        (sleep-for 1.5)
        ;; A plain acquire does not jump the queue, even once the lock is free.
        (should (equal 1 (car (bp/lock-test--run "J" "acquire" "stack"))))
        (bp/lock-test--run "H" "release" "stack")
        (should (string-match-p "QUEUED" (cdr (bp/lock-test--run "J" "acquire" "stack"))))
        (should (eql 0 (bp/lock-test--wait-exit q1 5)))
        (should (process-live-p q2))
        (bp/lock-test--run "Q1" "release" "stack")
        (should (eql 0 (bp/lock-test--wait-exit q2 5)))
        (should (equal '(("Q2")) (bp/lock-test--rows "SELECT holder_key FROM locks")))))))

(ert-deftest bp/lock-expired-waiter-does-not-block ()
  (bp/lock-test-with-db
    (bp/lock-test--new "seed" "stack")
    (bp/lock-test--run "seed" "release" "stack")
    (sqlite-execute (bp/agent-sessions--db)
                    "INSERT INTO lock_waiters (name, is_dir, waiter_kind, waiter_key, expires_at)
                     VALUES ('stack', 0, 'session', 'gone', 1)")
    (should (equal 0 (car (bp/lock-test--run "A" "acquire" "stack"))))
    (should (null (bp/lock-test--rows "SELECT * FROM lock_waiters")))))

(ert-deftest bp/lock-wait-timeout-leaves-the-queue ()
  (bp/lock-test-with-db
    (bp/lock-test--new "H" "stack")
    (let ((out (bp/lock-test--run "T" "wait" "stack" "--timeout" "1" "--interval" "1")))
      (should (equal 1 (car out)))
      (should (string-match-p "no longer queued" (cdr out))))
    (should (null (bp/lock-test--rows "SELECT * FROM lock_waiters")))))

(ert-deftest bp/lock-wait-on-unknown-name-fails-at-once ()
  (bp/lock-test-with-db
    (should (equal 1 (car (bp/lock-test--run "A" "wait" "nothing" "--timeout" "5"))))
    (should (null (bp/lock-test--rows "SELECT * FROM lock_waiters")))))

;;; Liveness and environment

(ert-deftest bp/lock-liveness-follows-pid-and-start-time ()
  (bp/lock-test-with-db
    (bp/lock-test--run (list "A" (format "CLAUDE_PID=%d" (emacs-pid)))
                       "acquire" "stack" "--new" "the stack")
    (should (string-match-p "held by A (running)" (cdr (bp/lock-test--run "B" "list" "--verbose"))))
    (bp/agent-locks--reload)
    (should (eq 'running (plist-get (car bp/agent-locks--held) :liveness)))
    ;; Same pid, different start time: a reused pid is not the holder.
    (sqlite-execute (bp/agent-sessions--db) "UPDATE locks SET holder_pid_start = 'then'")
    (should (string-match-p "held by A (not running)" (cdr (bp/lock-test--run "B" "list" "--verbose"))))
    (bp/agent-locks--reload)
    (should (eq 'not-running (plist-get (car bp/agent-locks--held) :liveness)))))

(ert-deftest bp/lock-identity-falls-back-to-the-session-log ()
  (bp/lock-test-with-db
    (sqlite-execute (bp/agent-sessions--db)
                    "INSERT INTO sessions (emacs_sid, agent_type, agent_sid, worktree, title, opened_at)
                     VALUES ('9-1', 'pi', 'pi-sid', '/w', 'Pi worker', 0)")
    (should (equal 0 (car (bp/lock-test--run (list nil "EMACS_AGENT_SESSION_ID=9-1")
                                             "acquire" "stack" "--new" "the stack"))))
    (should (equal '(("session" "pi-sid" "Pi worker"))
                   (bp/lock-test--rows "SELECT holder_kind, holder_key, holder_label FROM locks")))))

(ert-deftest bp/lock-cannot-run-fails-loudly-and-writes-nothing ()
  (bp/lock-test-with-db
    (should (equal 3 (car (bp/lock-test--run nil "acquire" "stack"))))
    (let ((owner (bp/lock-test--run nil "list")))
      ;; Listing needs no identity.
      (should (equal 0 (car owner))))
    (let* ((missing (concat bp/lock-test--db ".missing"))
           (bp/lock-test--db missing))
      (should (equal 3 (car (bp/lock-test--run "A" "list"))))
      (should-not (file-exists-p missing)))
    (let* ((bare (make-temp-file "agent-locks-bare-" nil ".db"))
           (bp/lock-test--db bare))
      (unwind-protect
          (progn
            (call-process "sqlite3" nil nil nil bare "CREATE TABLE meta (key TEXT)")
            (let ((out (bp/lock-test--run "A" "list")))
              (should (equal 3 (car out)))
              (should (string-match-p "no lock tables" (cdr out)))))
        (delete-file bare)))))

(ert-deftest bp/lock-terminal-environment-names-the-database ()
  (let ((bp/agent-sessions-db-file "/tmp/some/agent-sessions.db"))
    (should (member "EMACS_AGENT_SESSIONS_DB=/tmp/some/agent-sessions.db"
                    (bp/agent-sessions--terminal-environment "1-1")))))

;;; Emacs side

(ert-deftest bp/lock-dashboard-shows-held-locks-and-queue ()
  (bp/lock-test-with-db
    (bp/lock-test--new "A" "stack")
    (sqlite-execute (bp/agent-sessions--db)
                    "INSERT INTO lock_waiters (name, is_dir, waiter_kind, waiter_key, waiter_label, expires_at)
                     VALUES ('stack', 0, 'session', 'B', 'Bee', ?)"
                    (list (+ (bp/agent-sessions--now) 60)))
    (should (bp/agent-locks--reload))
    (should-not (bp/agent-locks--reload))
    (with-temp-buffer
      (let ((bp/agent-sessions-buffer-name (buffer-name)))
        (bp/agent-sessions-mode)
        (bp/agent-sessions--refresh)
        ;; Neither A nor B has a session row here, so both show in the
        ;; section, each naming who it is.
        (should (string-match-p
                 (concat "^Locks held outside the sessions below\n"
                         "    🔒 stack  held by A (liveness unknown) for [0-9]+s  ⏳ Bee\n"
                         "    ⏳ stack  Bee waiting\n")
                 (buffer-substring-no-properties (point-min) (point-max))))))))

(ert-deftest bp/lock-session-marker-shows-locks-held-and-queue-places ()
  (let ((bp/agent-locks--held
         (list (list :name "stack" :holder '("session" "H"))
               (list :name "a/" :holder '("session" "M"))
               (list :name "b/" :holder '("session" "M"))))
        (bp/agent-locks--waiters
         (list (list :name "stack" :waiter '("session" "W1"))
               (list :name "stack" :waiter '("session" "W2"))
               (list :name "db" :waiter '("session" "X"))
               (list :name "db" :waiter '("session" "W2"))
               (list :name "db" :waiter '("session" "M")))))
    ;; The count is locks held, not who waits behind them.
    (should (equal "🔒" (bp/agent-locks--session-marker "1" '(:agent-session-id "H"))))
    (should (equal "🔒 (2) ⏳ (3)"
                   (bp/agent-locks--session-marker "2" '(:agent-session-id "M"))))
    (should (equal "⏳ (1)" (bp/agent-locks--session-marker "3" '(:agent-session-id "W1"))))
    ;; One place per queue, in queue order.
    (should (equal "⏳ (2, 2)" (bp/agent-locks--session-marker "4" '(:agent-session-id "W2"))))
    (should (equal "" (bp/agent-locks--session-marker "5" '(:agent-session-id "Y"))))
    ;; Padding is by display width, so rows with and without 🔒 line up.
    (should (= (string-width (bp/agent-locks--pad "🔒" 7))
               (string-width (bp/agent-locks--pad "⏳ (1)" 7))
               (string-width (bp/agent-locks--pad "" 7))))))

(ert-deftest bp/lock-rows-hang-under-their-session ()
  (bp/lock-test-with-db
    (bp/lock-test--run "A" "acquire" "stack" "--new" "the stack" "--why" "e2e run")
    (sqlite-execute (bp/agent-sessions--db)
                    "INSERT INTO lock_waiters (name, is_dir, waiter_kind, waiter_key, waiter_label, why, expires_at)
                     VALUES ('db', 0, 'session', 'A', 'A', 'migrate', ?)"
                    (list (+ (bp/agent-sessions--now) 60)))
    (bp/agent-locks--reload)
    (with-temp-buffer
      (magit-section-mode)
      (let ((inhibit-read-only t))
        (magit-insert-section (bp/agent-sessions-root)
          (bp/agent-locks--insert-session-locks "1-1" '(:agent-session-id "A") "        ")
          (bp/agent-locks--insert-session-locks "1-2" '(:agent-session-id "B") "        ")))
      (should (string-match-p
               "\\`        🔒 stack  [0-9]+s — e2e run\n        ⏳ db  waiting — migrate\n\\'"
               (buffer-substring-no-properties (point-min) (point-max))))
      (goto-char (point-min))
      (should (equal "stack" (plist-get (bp/agent-locks--at-point) :name)))
      (forward-line 1)
      (should-not (bp/agent-locks--at-point)))))

(ert-deftest bp/lock-force-release-files-notice-without-reviving ()
  (bp/lock-test-with-db
    (bp/lock-test--new "A" "stack")
    (bp/agent-locks--reload)
    (let ((lock (car bp/agent-locks--held))
          (revived nil))
      (cl-letf (((symbol-function 'bp/agent-orchestration-send)
                 (lambda (&rest _) (setq revived t)))
                ((symbol-function 'bp/agent-orchestration--revive-recipient)
                 (lambda (&rest _) (setq revived t))))
        (should (bp/agent-locks--force-release lock))
        (should-not (bp/agent-locks--force-release lock)))
      (should-not revived)
      (should (null bp/agent-locks--held))
      (should (equal '(("user" "session" "A" "Lock released by the user: stack" nil))
                     (bp/lock-test--rows
                      "SELECT from_kind, to_kind, to_key, subject, read_at FROM mail"))))))

(ert-deftest bp/lock-force-release-skips-a-lock-that-changed-hands ()
  (bp/lock-test-with-db
    (bp/lock-test--new "A" "stack")
    (bp/agent-locks--reload)
    (let ((seen (car bp/agent-locks--held)))
      (sqlite-execute (bp/agent-sessions--db) "UPDATE locks SET acquired_at = acquired_at + 5")
      (should-not (bp/agent-locks--force-release seen))
      (should (equal 1 (caar (bp/lock-test--rows "SELECT count(*) FROM locks"))))
      (should (null (bp/lock-test--rows "SELECT * FROM mail"))))))

(ert-deftest bp/lock-notice-from-the-dashboard-reads-as-such ()
  (let ((text (bp/agent-orchestration--format-message
               (list :from nil :from-key '("user" "dashboard") :from-label "the user"
                     :type "status" :subject "Lock released by the user: stack"
                     :body "b" :files "" :report ""))))
    (should (string-match-p "from the user (via the agent-sessions dashboard)" text))
    (should (string-match-p "Reply: none needed" text))))

(ert-deftest bp/lock-adopt-points-a-restored-holder-at-its-terminal ()
  (bp/lock-test-with-db
    (bp/lock-test--new "S" "stack")
    (sqlite-execute (bp/agent-sessions--db)
                    "UPDATE locks SET holder_pid = 999999, holder_pid_start = 'long ago'")
    (bp/agent-locks--reload)
    (let* ((buf (generate-new-buffer " *lock-adopt*"))
           (proc (make-process :name "lock-adopt" :buffer buf
                               :command '("sleep" "30") :noquery t))
           (bp/agent-session-id->buffer (make-hash-table :test 'equal)))
      (unwind-protect
          (progn
            (puthash "1-1" buf bp/agent-session-id->buffer)
            (bp/agent-locks--adopt "1-1" "someone-else")
            (should (eq 'not-running (plist-get (car bp/agent-locks--held) :liveness)))
            (bp/agent-locks--adopt "1-1" "S")
            (should (equal (list (list (process-id proc)))
                           (bp/lock-test--rows "SELECT holder_pid FROM locks")))
            (should (eq 'running (plist-get (car bp/agent-locks--held) :liveness))))
        (delete-process proc)
        (kill-buffer buf)))))

;;; agent-sessions-lock-test.el ends here
