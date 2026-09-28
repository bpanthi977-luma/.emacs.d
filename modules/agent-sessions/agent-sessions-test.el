;;; agent-sessions-test.el --- Tests for agent-sessions  -*- lexical-binding: t; -*-

(require 'ert)
(require 'agent-sessions)

(defun bp/agent-orchestration-test--message (type subject)
  (list :id (concat "test-" subject) :from "sender" :from-label "sender"
        :type type :subject subject :body "" :files "" :report "" :read nil))

(ert-deftest bp/agent-orchestration-status-alone-does-not-steer-running-codex ()
  (let* ((id "terminal")
         (message (bp/agent-orchestration-test--message "status" "progress"))
         (session (list :status 'running :agent-type "codex"
                        :agent-session-id "thread"))
         (bp/agent-orchestration--mail (make-hash-table :test 'equal))
         queued consumed)
    (puthash id (list message) bp/agent-orchestration--mail)
    (cl-letf (((symbol-function 'bp/agent-sessions--session-for-id)
               (lambda (_) session))
              ((symbol-function 'bp/agent-orchestration--codex-queue)
               (lambda (_ messages) (setq queued messages) t))
              ((symbol-function 'bp/agent-orchestration--consume)
               (lambda (messages) (setq consumed messages))))
      (should-not (bp/agent-orchestration-deliver id))
      (should-not queued)
      (should-not consumed)
      (should-not (plist-get message :read)))))

(ert-deftest bp/agent-orchestration-actionable-mail-steers-with-earlier-status ()
  (let* ((id "terminal")
         (status (bp/agent-orchestration-test--message "status" "progress"))
         (question (bp/agent-orchestration-test--message "question" "decision"))
         (pending (list status question))
         (session (list :status 'running :agent-type 'codex
                        :agent-session-id "thread"))
         (bp/agent-orchestration--mail (make-hash-table :test 'equal))
         queued consumed refreshed)
    (puthash id pending bp/agent-orchestration--mail)
    (cl-letf (((symbol-function 'bp/agent-sessions--session-for-id)
               (lambda (_) session))
              ((symbol-function 'bp/agent-orchestration--codex-queue)
               (lambda (_ messages) (setq queued messages) t))
              ((symbol-function 'bp/agent-orchestration--consume)
               (lambda (messages) (setq consumed messages)))
              ((symbol-function 'bp/agent-sessions--refresh-if-visible)
               (lambda () (setq refreshed t))))
      (should (eq 'queued (bp/agent-orchestration-deliver id)))
      (should (equal pending queued))
      (should (equal pending consumed))
      (should refreshed))))

(ert-deftest bp/agent-orchestration-failed-native-queue-leaves-mail-unread ()
  (let* ((id "terminal")
         (question (bp/agent-orchestration-test--message "question" "decision"))
         (session (list :status 'running :agent-type "codex"
                        :agent-session-id "thread"))
         (bp/agent-orchestration--mail (make-hash-table :test 'equal))
         consumed)
    (puthash id (list question) bp/agent-orchestration--mail)
    (cl-letf (((symbol-function 'bp/agent-sessions--session-for-id)
               (lambda (_) session))
              ((symbol-function 'bp/agent-orchestration--codex-queue)
               (lambda (&rest _) nil))
              ((symbol-function 'bp/agent-orchestration--consume)
               (lambda (messages) (setq consumed messages))))
      (should-not (bp/agent-orchestration-deliver id))
      (should-not consumed)
      (should-not (plist-get question :read)))))

(ert-deftest bp/agent-orchestration-generic-idle-delivery-still-pastes-all-mail ()
  (let* ((id "terminal")
         (buffer (generate-new-buffer " *agent-delivery-test*"))
         (message (bp/agent-orchestration-test--message "status" "progress"))
         (session (list :status 'stopped :agent-type "other" :buffer buffer))
         (bp/agent-orchestration--mail (make-hash-table :test 'equal))
         pasted consumed)
    (unwind-protect
        (progn
          (puthash id (list message) bp/agent-orchestration--mail)
          (cl-letf (((symbol-function 'bp/agent-sessions--session-for-id)
                     (lambda (_) session))
                    ((symbol-function 'bp/agent-orchestration--receptive-p)
                     (lambda (_) t))
                    ((symbol-function 'bp/agent-orchestration--paste)
                     (lambda (_ text) (setq pasted text)))
                    ((symbol-function 'bp/agent-orchestration--consume)
                     (lambda (messages) (setq consumed messages)))
                    ((symbol-function 'bp/agent-sessions--refresh-if-visible)
                     #'ignore))
            (should (eq 'delivered (bp/agent-orchestration-deliver id)))
            (should (equal (list message) consumed))
            (should (string-match-p "while you were idle" pasted))))
      (kill-buffer buffer))))

(ert-deftest bp/agent-orchestration-status-mail-queues-at-empty-running-claude ()
  (let* ((id "terminal")
         (buffer (generate-new-buffer " *claude-delivery-test*"))
         (message (bp/agent-orchestration-test--message "status" "progress"))
         (session (list :status 'running :agent-type "claude" :buffer buffer))
         (bp/agent-orchestration--mail (make-hash-table :test 'equal))
         queued consumed)
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (insert "────────────────\n❯\u00a0\n────────────────\n  Opus"))
          (puthash id (list message) bp/agent-orchestration--mail)
          (cl-letf (((symbol-function 'bp/agent-sessions--session-for-id)
                     (lambda (_) session))
                    ((symbol-function 'bp/agent-sessions--foreground-command)
                     (lambda (_) "claude"))
                    ((symbol-function 'bp/agent-orchestration--claude-queue)
                     (lambda (_ messages) (setq queued messages) t))
                    ((symbol-function 'bp/agent-orchestration--consume)
                     (lambda (messages) (setq consumed messages)))
                    ((symbol-function 'bp/agent-sessions--refresh-if-visible)
                     #'ignore))
            (should (eq 'queued (bp/agent-orchestration-deliver id)))
            (should (equal (list message) queued))
            (should (equal (list message) consumed))))
      (kill-buffer buffer))))

(ert-deftest bp/agent-orchestration-actionable-mail-queues-after-retained-claude-prompt ()
  (let* ((id "terminal")
         (buffer (generate-new-buffer " *claude-delivery-test*"))
         (message (bp/agent-orchestration-test--message "answer" "decision"))
         (session (list :status 'running :agent-type 'claude :buffer buffer
                        :submitted-prompt "previous request"))
         (bp/agent-orchestration--mail (make-hash-table :test 'equal))
         queued consumed)
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (insert "────────────────\n❯\u00a0previous request\n"
                    "────────────────\n  Opus"))
          (puthash id (list message) bp/agent-orchestration--mail)
          (cl-letf (((symbol-function 'bp/agent-sessions--session-for-id)
                     (lambda (_) session))
                    ((symbol-function 'bp/agent-sessions--foreground-command)
                     (lambda (_) "claude"))
                    ((symbol-function 'bp/agent-orchestration--claude-queue)
                     (lambda (_ messages) (setq queued messages) t))
                    ((symbol-function 'bp/agent-orchestration--consume)
                     (lambda (messages) (setq consumed messages)))
                    ((symbol-function 'bp/agent-sessions--refresh-if-visible)
                     #'ignore))
            (should (eq 'queued (bp/agent-orchestration-deliver id)))
            (should (equal (list message) queued))
            (should (equal (list message) consumed))))
      (kill-buffer buffer))))

(ert-deftest bp/agent-orchestration-claude-draft-withholds-actionable-mail ()
  (let* ((id "terminal")
         (buffer (generate-new-buffer " *claude-draft-delivery-test*"))
         (message (bp/agent-orchestration-test--message "answer" "decision"))
         (session (list :status 'stopped :agent-type 'claude :buffer buffer))
         (bp/agent-orchestration--mail (make-hash-table :test 'equal))
         queued consumed)
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (insert "────────────────\n❯\u00a0my unfinished message\n"
                    "────────────────\n  Opus"))
          (puthash id (list message) bp/agent-orchestration--mail)
          (cl-letf (((symbol-function 'bp/agent-sessions--session-for-id)
                     (lambda (_) session))
                    ((symbol-function 'bp/agent-sessions--foreground-command)
                     (lambda (_) "claude"))
                    ((symbol-function 'bp/agent-orchestration--claude-queue)
                     (lambda (_ messages) (setq queued messages) t))
                    ((symbol-function 'bp/agent-orchestration--consume)
                     (lambda (messages) (setq consumed messages))))
            (should-not (bp/agent-orchestration-deliver id))
            (should-not queued)
            (should-not consumed)
            (should-not (plist-get message :read))))
      (kill-buffer buffer))))

(ert-deftest bp/agent-orchestration-claude-submit-releases-withheld-mail ()
  (let* ((id "terminal")
         (buffer (generate-new-buffer " *claude-submit-delivery-test*"))
         (message (bp/agent-orchestration-test--message "status" "progress"))
         (session (list :status 'running :agent-type 'claude :buffer buffer))
         (bp/agent-orchestration--mail (make-hash-table :test 'equal))
         queued consumed)
    (unwind-protect
        (progn
          ;; Keep the old draft visible to prove the hook, rather than a
          ;; screen redraw race, is the authority that it was submitted.
          (with-current-buffer buffer
            (insert "────────────────\n❯\u00a0my submitted message\n"
                    "────────────────\n  Opus"))
          (puthash id (list message) bp/agent-orchestration--mail)
          (cl-letf (((symbol-function 'bp/agent-sessions--session-for-id)
                     (lambda (_) session))
                    ((symbol-function 'bp/agent-sessions--foreground-command)
                     (lambda (_) "claude"))
                    ((symbol-function 'bp/agent-orchestration--claude-queue)
                     (lambda (_ messages) (setq queued messages) t))
                    ((symbol-function 'bp/agent-orchestration--consume)
                     (lambda (messages) (setq consumed messages)))
                    ((symbol-function 'bp/agent-sessions--refresh-if-visible)
                     #'ignore))
            (should (eq 'queued (bp/agent-orchestration-deliver id t)))
            (should (equal (list message) queued))
            (should (equal (list message) consumed))))
      (kill-buffer buffer))))

(ert-deftest bp/agent-orchestration-claude-composer-detection-is-conservative ()
  (let* ((buffer (generate-new-buffer " *claude-composer-test*"))
         (session (list :agent-type "claude" :buffer buffer)))
    (unwind-protect
        (with-current-buffer buffer
          (insert "────────────────\n❯\u00a0\n────────────────\n  Opus")
          (should (bp/agent-orchestration--claude-receptive-composer-p session))
          (erase-buffer)
          (insert "────────────────\n❯\u00a0first line\n  wrapped line\n"
                  "────────────────\n  Opus")
          (should-not
           (bp/agent-orchestration--claude-receptive-composer-p session))
          ;; Claude can retain the submitted prompt in the composer after the
          ;; hook fires.  Visual hard wrapping must not turn that into a draft.
          (setq session
                (plist-put session :submitted-prompt "first line wrapped line"))
          (should (bp/agent-orchestration--claude-receptive-composer-p session))
          (erase-buffer)
          (insert "────────────────\n❯\u00a0a genuinely new draft\n"
                  "────────────────\n  Opus")
          (should-not
           (bp/agent-orchestration--claude-receptive-composer-p session))
          (erase-buffer)
          (insert "────────────────\n❯\u00a0")
          (let ((start (point)))
            (insert "suggested completion")
            (add-text-properties
             start (point)
             '(font-lock-face (:inherit (eat-term-faint eat-term-font-0)))))
          (insert "\n────────────────\n  Opus")
          (should (bp/agent-orchestration--claude-receptive-composer-p session))
          (erase-buffer)
          (insert "────────────────\n❯\u00a0typed prefix ")
          (let ((start (point)))
            (insert "suggested remainder")
            (add-text-properties
             start (point)
             '(font-lock-face (:inherit (eat-term-faint eat-term-font-0)))))
          (insert "\n────────────────\n  Opus")
          (should-not
           (bp/agent-orchestration--claude-receptive-composer-p session))
          (erase-buffer)
          (insert "Claude output without a recognizable composer")
          (should-not
           (bp/agent-orchestration--claude-receptive-composer-p session)))
      (kill-buffer buffer))))

(ert-deftest bp/agent-orchestration-claude-queue-only-pastes-and-submits ()
  (let* ((buffer (generate-new-buffer " *claude-queue-test*"))
         (session (list :agent-type "claude" :buffer buffer))
         (message (bp/agent-orchestration-test--message "answer" "result"))
         events)
    (unwind-protect
        (cl-letf (((symbol-function 'bp/agent-orchestration--terminal-input)
                   (lambda (_ input) (push (list 'input input) events)))
                  ((symbol-function 'bp/agent-sessions--terminal-paste)
                   (lambda (_ text) (push (list 'paste text) events)))
                  ((symbol-function 'run-at-time)
                   (lambda (_ _ function &rest args) (apply function args))))
          (should (bp/agent-orchestration--claude-queue session (list message)))
          (setq events (nreverse events))
          (should (equal (mapcar #'car events) '(paste input)))
          (should (equal (cadr (nth 1 events))
                         bp/agent-orchestration-claude-queue-submit-key))
          (should (string-match-p "Subject: result" (cadr (nth 0 events)))))
      (kill-buffer buffer))))

(ert-deftest bp/agent-orchestration-idle-codex-uses-native-queue-not-composer ()
  (let* ((id "terminal")
         (message (bp/agent-orchestration-test--message "status" "progress"))
         (session (list :status 'stopped :agent-type "codex"
                        :agent-session-id "thread"))
         (bp/agent-orchestration--mail (make-hash-table :test 'equal))
         queued consumed pasted)
    (puthash id (list message) bp/agent-orchestration--mail)
    (cl-letf (((symbol-function 'bp/agent-sessions--session-for-id)
               (lambda (_) session))
              ((symbol-function 'bp/agent-orchestration--codex-queue)
               (lambda (_ messages) (setq queued messages) t))
              ((symbol-function 'bp/agent-orchestration--consume)
               (lambda (messages) (setq consumed messages)))
              ((symbol-function 'bp/agent-orchestration--paste)
               (lambda (&rest _) (setq pasted t)))
              ((symbol-function 'bp/agent-sessions--refresh-if-visible)
               #'ignore))
      (should (eq 'queued (bp/agent-orchestration-deliver id)))
      (should (equal (list message) queued))
      (should (equal (list message) consumed))
      (should-not pasted))))

(ert-deftest bp/agent-orchestration-interrupted-codex-empty-prompt-delivers-directly ()
  (let* ((id "terminal")
         (buffer (generate-new-buffer " *codex-interrupted-delivery-test*"))
         (message (bp/agent-orchestration-test--message "answer" "decision"))
         ;; Codex does not fire Stop for an interrupted turn, so this stale
         ;; status is the live failure mode this regression covers.
         (session (list :status 'running :agent-type "codex"
                        :agent-session-id "thread" :buffer buffer))
         (bp/agent-orchestration--mail (make-hash-table :test 'equal))
         queued consumed pasted)
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (insert "■ Conversation interrupted - tell the model what to do differently.\n"
                    "\n› Ask Codex to do anything\n\n"
                    "  gpt-5.6-sol medium · Context 31% used"))
          (puthash id (list message) bp/agent-orchestration--mail)
          (cl-letf (((symbol-function 'bp/agent-sessions--session-for-id)
                     (lambda (_) session))
                    ((symbol-function 'bp/agent-orchestration--codex-queue)
                     (lambda (_ messages) (setq queued messages) t))
                    ((symbol-function 'bp/agent-orchestration--paste)
                     (lambda (_ text) (setq pasted text)))
                    ((symbol-function 'bp/agent-orchestration--consume)
                     (lambda (messages) (setq consumed messages)))
                    ((symbol-function 'bp/agent-sessions--refresh-if-visible)
                     #'ignore))
            (should (eq 'delivered (bp/agent-orchestration-deliver id)))
            (should (equal (list message) consumed))
            (should (string-match-p "Subject: decision" pasted))
            (should-not queued)))
      (kill-buffer buffer))))

(ert-deftest bp/agent-orchestration-codex-draft-still-uses-native-queue ()
  (let* ((id "terminal")
         (buffer (generate-new-buffer " *codex-draft-delivery-test*"))
         (message (bp/agent-orchestration-test--message "answer" "decision"))
         (session (list :status 'stopped :agent-type "codex"
                        :agent-session-id "thread" :buffer buffer))
         (bp/agent-orchestration--mail (make-hash-table :test 'equal))
         queued consumed pasted)
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (insert "› Keep this human draft intact\n\n"
                    "  gpt-5.6-sol medium · Context 31% used"))
          (puthash id (list message) bp/agent-orchestration--mail)
          (cl-letf (((symbol-function 'bp/agent-sessions--session-for-id)
                     (lambda (_) session))
                    ((symbol-function 'bp/agent-orchestration--codex-queue)
                     (lambda (_ messages) (setq queued messages) t))
                    ((symbol-function 'bp/agent-orchestration--paste)
                     (lambda (&rest _) (setq pasted t)))
                    ((symbol-function 'bp/agent-orchestration--consume)
                     (lambda (messages) (setq consumed messages)))
                    ((symbol-function 'bp/agent-sessions--refresh-if-visible)
                     #'ignore))
            (should (eq 'queued (bp/agent-orchestration-deliver id)))
            (should (equal (list message) queued))
            (should (equal (list message) consumed))
            (should-not pasted)))
      (kill-buffer buffer))))

(ert-deftest bp/agent-orchestration-native-codex-queue-uses-durable-thread-id ()
  (let ((session (list :agent-session-id "thread-uuid"))
        (message (bp/agent-orchestration-test--message "answer" "result"))
        invocation)
    (cl-letf (((symbol-function 'executable-find) (lambda (_) "/bin/codex"))
              ((symbol-function 'bp/agent-orchestration--call-with-timeout)
               (lambda (program args timeout)
                 (setq invocation (list program args timeout))
                 0)))
      (should (bp/agent-orchestration--codex-queue session (list message)))
      (should (equal (car invocation) "/bin/codex"))
      (should (equal (seq-take (cadr invocation) 4)
                     '("queue" "--thread" "thread-uuid" "--message")))
      (should (string-match-p "Subject: result" (nth 4 (cadr invocation))))
      (should (= (nth 2 invocation)
                 bp/agent-orchestration--native-queue-timeout)))))

(ert-deftest bp/agent-sessions-show-file-diff-opens-latest-commit-then-reads ()
  (let ((path "/repo/docs/plan.md")
        events)
    (cl-letf (((symbol-function 'bp/agent-sessions--file-at-point)
               (lambda () (list 'session path (list :path path))))
              ((symbol-function 'magit-toplevel)
               (lambda (_) "/repo/"))
              ((symbol-function 'magit-git-string)
               (lambda (&rest args)
                 (push (list 'git default-directory args) events)
                 "abc123"))
              ((symbol-function 'magit-show-commit--arguments)
               (lambda () '(("--stat") nil)))
              ((symbol-function 'magit-show-commit)
               (lambda (commit args files &optional _module)
                 (push (list 'show default-directory commit args files) events)))
              ((symbol-function 'bp/agent-sessions--set-visited)
               (lambda (match-fn visitedp)
                 (push (list 'visited
                             (funcall match-fn (list :path path))
                             visitedp)
                       events)
                 t))
              ((symbol-function 'bp/agent-sessions--refresh-if-visible)
               (lambda () (push '(refresh) events))))
      (bp/agent-sessions-show-file-diff)
      (should
       (equal (nreverse events)
              '((git "/repo/"
                     ("log" "-1" "--format=%H" "--follow" "--"
                      "docs/plan.md"))
                (show "/repo/" "abc123" ("--stat") ("docs/plan.md"))
                (visited t t)
                (refresh)))))))

(ert-deftest bp/agent-sessions-show-file-diff-keeps-uncommitted-file-unread ()
  (let ((path "/repo/docs/plan.md")
        shown visited)
    (cl-letf (((symbol-function 'bp/agent-sessions--file-at-point)
               (lambda () (list 'session path (list :path path))))
              ((symbol-function 'magit-toplevel)
               (lambda (_) "/repo/"))
              ((symbol-function 'magit-git-string)
               (lambda (&rest _) nil))
              ((symbol-function 'magit-show-commit)
               (lambda (&rest _) (setq shown t)))
              ((symbol-function 'bp/agent-sessions--set-visited)
               (lambda (&rest _) (setq visited t))))
      (should-error (bp/agent-sessions-show-file-diff) :type 'user-error)
      (should-not shown)
      (should-not visited))))

(defmacro bp/agent-sessions-test--with-temp-db (&rest body)
  "Run BODY with an isolated agent-sessions database."
  (declare (indent 0) (debug t))
  `(let* ((db-file (make-temp-file "agent-sessions-test-"))
          (snapshot-directory
           (make-temp-file "agent-sessions-snapshots-test-" t))
          (bp/agent-sessions-db-file db-file)
          (bp/agent-sessions-file-snapshot-directory snapshot-directory)
          (bp/agent-sessions--db nil)
          (bp/agent-sessions--shared-files nil)
          (bp/agent-sessions--shared-paths nil)
          (bp/agent-sessions--shared-links nil))
     (unwind-protect
         (progn ,@body)
       (when (sqlitep bp/agent-sessions--db)
         (sqlite-close bp/agent-sessions--db))
       (dolist (path (list db-file (concat db-file "-wal")
                           (concat db-file "-shm")))
         (when (file-exists-p path)
           (delete-file path)))
       (delete-directory snapshot-directory t))))

(defun bp/agent-sessions-test--write-file (path contents)
  "Replace PATH with CONTENTS for a shared-file test."
  (with-temp-file path
    (insert contents)))

(ert-deftest bp/agent-sessions-share-file-keeps-latest-two-submissions ()
  (bp/agent-sessions-test--with-temp-db
    (let* ((source (make-temp-file "agent-shared-file-" nil ".md"))
           (session (list :agent-session-id "thread-1"))
           (key '("session" "thread-1")))
      (unwind-protect
          (progn
            (bp/agent-sessions-test--write-file source "first\n")
            (let ((first (bp/agent-sessions--share-file session source nil)))
              (should (equal source (plist-get first :path))))
            (let ((snapshot (bp/agent-sessions--file-snapshot-row
                             (list key) source)))
              (should-not (plist-get snapshot :previous-path))
              (should (equal "first\n"
                             (with-temp-buffer
                               (insert-file-contents
                                (plist-get snapshot :current-path))
                               (buffer-string)))))
            (bp/agent-sessions-test--write-file source "second\n")
            (bp/agent-sessions--share-file session source nil)
            (bp/agent-sessions-test--write-file source "third\n")
            (bp/agent-sessions--share-file session source nil)
            (let ((snapshot (bp/agent-sessions--file-snapshot-row
                             (list key) source)))
              (should (equal "second\n"
                             (with-temp-buffer
                               (insert-file-contents
                                (plist-get snapshot :previous-path))
                               (buffer-string))))
              (should (equal "third\n"
                             (with-temp-buffer
                               (insert-file-contents
                                (plist-get snapshot :current-path))
                               (buffer-string)))))
            (should
             (equal '((1))
                    (sqlite-select
                     (bp/agent-sessions--db)
                     "SELECT COUNT(*) FROM shared_file_snapshots"))))
        (delete-file source)))))

(ert-deftest bp/agent-sessions-file-snapshots-follow-durable-session-id ()
  (bp/agent-sessions-test--with-temp-db
    (let ((source (make-temp-file "agent-shared-file-"))
          (buffer (generate-new-buffer "agent-snapshot-terminal")))
      (unwind-protect
          (let ((terminal-session (list :buffer buffer)))
            (bp/agent-sessions-test--write-file source "before id\n")
            (bp/agent-sessions--share-file terminal-session source nil)
            (bp/agent-sessions-test--write-file source "after id\n")
            (let* ((durable-session
                    (list :buffer buffer :agent-session-id "thread-2"))
                   (durable-key '("session" "thread-2")))
              (bp/agent-sessions--share-file durable-session source nil)
              (let ((snapshot (bp/agent-sessions--file-snapshot-row
                               (list durable-key) source)))
                (should (equal "before id\n"
                               (with-temp-buffer
                                 (insert-file-contents
                                  (plist-get snapshot :previous-path))
                                 (buffer-string))))
                (should (equal "after id\n"
                               (with-temp-buffer
                                 (insert-file-contents
                                  (plist-get snapshot :current-path))
                                 (buffer-string)))))
              (should
               (equal '((0))
                      (sqlite-select
                       (bp/agent-sessions--db)
                       "SELECT COUNT(*) FROM shared_file_snapshots
                         WHERE kind = 'session' AND key = ?"
                       (list (buffer-name buffer)))))))
        (kill-buffer buffer)
        (delete-file source)))))

(ert-deftest bp/agent-sessions-show-submission-diff-compares-cache-then-reads ()
  (let* ((path "/outside-git/plan.md")
         (previous (make-temp-file "previous--plan-"))
         (current (make-temp-file "current--plan-"))
         (session (list :agent-session-id "thread-1"))
         (buffer (get-buffer-create "*Agent submission diff: plan.md*"))
         events)
    (unwind-protect
        (cl-letf (((symbol-function 'bp/agent-sessions--file-at-point)
                   (lambda () (list session path (list :path path))))
                  ((symbol-function 'bp/agent-sessions--file-snapshot-row)
                   (lambda (keys candidate)
                     (push (list 'snapshot keys candidate) events)
                     (list :previous-path previous :current-path current)))
                  ((symbol-function 'diff-no-select)
                   (lambda (old new switches no-async destination)
                     (push (list 'diff old new switches no-async destination)
                           events)
                     buffer))
                  ((symbol-function 'bp/agent-sessions--set-visited)
                   (lambda (match-fn visitedp)
                     (push (list 'visited
                                 (funcall match-fn (list :path path))
                                 visitedp)
                           events)
                     t))
                  ((symbol-function 'bp/agent-sessions--refresh-if-visible)
                   (lambda () (push '(refresh) events)))
                  ((symbol-function 'pop-to-buffer)
                   (lambda (shown) (push (list 'pop shown) events))))
          (bp/agent-sessions-show-file-submission-diff)
          (should
           (equal
            (nreverse events)
            `((snapshot (("session" "thread-1")) ,path)
              (diff ,previous ,current "-u" t ,buffer)
              (visited t t)
              (refresh)
              (pop ,buffer)))))
      (kill-buffer buffer)
      (delete-file previous)
      (delete-file current))))

(ert-deftest bp/agent-sessions-show-submission-diff-needs-two-versions ()
  (let ((path "/outside-git/plan.md")
        visited)
    (cl-letf (((symbol-function 'bp/agent-sessions--file-at-point)
               (lambda ()
                 (list (list :agent-session-id "thread-1") path
                       (list :path path))))
              ((symbol-function 'bp/agent-sessions--file-snapshot-row)
               (lambda (&rest _)
                 (list :current-path "/cache/current--plan.md")))
              ((symbol-function 'bp/agent-sessions--set-visited)
               (lambda (&rest _) (setq visited t))))
      (should-error (bp/agent-sessions-show-file-submission-diff)
                    :type 'user-error)
      (should-not visited))))

(ert-deftest bp/agent-sessions-capital-d-initializes-missing-snapshot ()
  (bp/agent-sessions-test--with-temp-db
    (let* ((path (make-temp-file "agent-shared-file-"))
           (session (list :agent-session-id "thread-1"))
           (key '("session" "thread-1"))
           visited message-text)
      (unwind-protect
          (progn
            (bp/agent-sessions-test--write-file path "current contents\n")
            (cl-letf (((symbol-function 'bp/agent-sessions--file-at-point)
                       (lambda () (list session path (list :path path))))
                      ((symbol-function 'bp/agent-sessions--set-visited)
                       (lambda (&rest _) (setq visited t)))
                      ((symbol-function 'message)
                       (lambda (format-string &rest args)
                         (setq message-text
                               (apply #'format format-string args)))))
              (bp/agent-sessions-show-file-submission-diff))
            (let ((snapshot (bp/agent-sessions--file-snapshot-row
                             (list key) path)))
              (should snapshot)
              (should-not (plist-get snapshot :previous-path))
              (should
               (equal "current contents\n"
                      (with-temp-buffer
                        (insert-file-contents
                         (plist-get snapshot :current-path))
                        (buffer-string)))))
            (should (equal message-text
                           "Saved current file as its first submitted snapshot"))
            (should-not visited))
        (delete-file path)))))

(ert-deftest bp/agent-sessions-capital-d-is-contextual ()
  (let (action file-at-point)
    (cl-letf (((symbol-function 'bp/agent-sessions--file-at-point)
               (lambda () file-at-point))
              ((symbol-function 'bp/agent-sessions-show-file-submission-diff)
               (lambda () (setq action 'diff)))
              ((symbol-function 'bp/agent-sessions-detach-parent)
               (lambda () (setq action 'detach))))
      (setq file-at-point '(session path file))
      (bp/agent-sessions-submission-diff-or-detach-parent)
      (should (eq action 'diff))
      (setq action nil file-at-point nil)
      (bp/agent-sessions-submission-diff-or-detach-parent)
      (should (eq action 'detach)))))

(ert-deftest bp/agent-sessions-shared-link-is-idempotent-and-current-per-kind ()
  (bp/agent-sessions-test--with-temp-db
    (let* ((session (list :agent-session-id "thread-1"))
           (first (bp/agent-sessions--share-link
                   session "linear" "https://linear.app/issue/ABC-1" "ABC-1"))
           (shared-at (plist-get first :shared-at)))
      (should-not (plist-get first :visited-at))
      (should (bp/agent-sessions--set-link-visited
               (lambda (link) (equal (plist-get link :kind) "linear")) t))
      (let ((same (bp/agent-sessions--share-link
                   session "linear" "https://linear.app/issue/ABC-1" "ABC-1")))
        (should (plist-get same :visited-at))
        (should (= shared-at (plist-get same :shared-at))))
      (let ((changed (bp/agent-sessions--share-link
                      session "linear" "https://linear.app/issue/ABC-2" "ABC-2")))
        (should-not (plist-get changed :visited-at))
        (should (= shared-at (plist-get changed :shared-at)))
        (should (equal "https://linear.app/issue/ABC-2"
                       (plist-get changed :url))))
      (should (equal '((1))
                     (sqlite-select
                      (bp/agent-sessions--db)
                      "SELECT COUNT(*) FROM shared_links
                        WHERE owner_kind = 'session'
                          AND owner_key = 'thread-1'
                          AND link_kind = 'linear'"))))))

(ert-deftest bp/agent-sessions-share-link-validates-kind-and-url ()
  (let ((session (list :agent-session-id "thread-1"))
        refreshed)
    (cl-letf (((symbol-function 'bp/agent-sessions--session-for-id)
               (lambda (_) session))
              ((symbol-function 'bp/agent-sessions--refresh-if-visible)
               (lambda () (setq refreshed t))))
      (should (string-prefix-p
               "Unknown link kind"
               (bp/agent-sessions-share-link
                "terminal" "ticket" "https://example.com/1")))
      (should (string-prefix-p
               "Invalid link URL"
               (bp/agent-sessions-share-link
                "terminal" "linear" "file:///tmp/issue")))
      (should-not refreshed))))

(ert-deftest bp/agent-sessions-open-link-marks-read-before-browsing ()
  (let* ((link (list :kind "pr" :url "https://github.com/org/repo/pull/1"))
         events)
    (cl-letf (((symbol-function 'bp/agent-sessions--link-at-point)
               (lambda () (list 'session "pr" link)))
              ((symbol-function 'bp/agent-sessions--set-link-visited)
               (lambda (match-fn visitedp)
                 (push (list 'visited (funcall match-fn link) visitedp) events)
                 t))
              ((symbol-function 'bp/agent-sessions--refresh-if-visible)
               (lambda () (push '(refresh) events)))
              ((symbol-function 'browse-url)
               (lambda (url) (push (list 'browse url) events))))
      (bp/agent-sessions--open-link-at-point)
      (should
       (equal (nreverse events)
              '((visited t t)
                (refresh)
                (browse "https://github.com/org/repo/pull/1")))))))

(provide 'agent-sessions-test)
;;; agent-sessions-test.el ends here
