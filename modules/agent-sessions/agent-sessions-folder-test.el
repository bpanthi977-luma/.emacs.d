;;; agent-sessions-folder-test.el --- Folder tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'agent-sessions)

(defmacro bp/agent-sessions-folder-test--with-db (&rest body)
  "Run BODY with an isolated folder database and caches."
  (declare (indent 0))
  `(let* ((bp/agent-sessions-db-file (make-temp-file "agent-folders-"))
          (bp/agent-sessions--db nil)
          (bp/agent-sessions--folders-loaded-p nil)
          (bp/agent-sessions--folders nil)
          (bp/agent-sessions--folder-assignments nil)
          (bp/agent-sessions--order nil))
     (unwind-protect
         (progn ,@body)
       (when (sqlitep bp/agent-sessions--db)
         (sqlite-close bp/agent-sessions--db))
       (dolist (path (list bp/agent-sessions-db-file
                          (concat bp/agent-sessions-db-file "-wal")
                          (concat bp/agent-sessions-db-file "-shm")))
         (when (file-exists-p path) (delete-file path))))))

(ert-deftest bp/agent-sessions-folders-group-across-repos-and-persist ()
  (bp/agent-sessions-folder-test--with-db
    (let* ((root-a (make-temp-file "agent-repo-a-" t))
           (root-b (make-temp-file "agent-repo-b-" t))
           (buf-a (generate-new-buffer " *folder-a*"))
           (buf-b (generate-new-buffer " *folder-b*"))
           (buf-c (generate-new-buffer " *folder-c*")))
      (unwind-protect
          (let* ((folder (bp/agent-sessions--folder-create "Migration cleanup"))
                 (id (plist-get folder :id))
                 (a (list :buffer buf-a :agent-session-id "folder-thread-a"
                          :repo "repo-a" :repo-root root-a
                          :worktree "a" :worktree-path root-a))
                 (b (list :buffer buf-b :agent-session-id "folder-thread-b"
                          :repo "repo-b" :repo-root root-b
                          :worktree "b" :worktree-path root-b))
                 (c (list :buffer buf-c :agent-session-id "folder-thread-c"
                          :repo "repo-a" :repo-root root-a
                          :worktree "a" :worktree-path root-a))
                 (entries (list (list :id "a" :session a)
                                (list :id "b" :session b)
                                (list :id "c" :session c))))
            (bp/agent-sessions--folder-set a id)
            (bp/agent-sessions--folder-set b id)
            (should (= 2 (length (bp/agent-sessions--folder-entries folder entries))))
            (should (= 2 (length (bp/agent-sessions--build-tree
                                  (bp/agent-sessions--folder-entries folder entries)))))
            (should (equal '("c")
                           (mapcar (lambda (e) (plist-get e :id))
                                   (bp/agent-sessions--folder-entries
                                    (list :id nil) entries))))
            (bp/agent-sessions--folder-rename folder "Cross repo")
            (sqlite-close bp/agent-sessions--db)
            (setq bp/agent-sessions--db nil
                  bp/agent-sessions--folders-loaded-p nil
                  bp/agent-sessions--folders nil
                  bp/agent-sessions--folder-assignments nil)
            (should (equal "Cross repo"
                           (plist-get (bp/agent-sessions--folder id) :name)))
            (should (equal id (bp/agent-sessions--folder-for-session a)))
            (bp/agent-sessions--folder-delete (bp/agent-sessions--folder id))
            (should-not (bp/agent-sessions--folder-for-session a))
            (should-not (bp/agent-sessions--folder-for-session b)))
        (mapc #'kill-buffer (list buf-a buf-b buf-c))
        (delete-directory root-a t)
        (delete-directory root-b t)))))

(ert-deftest bp/agent-sessions-folders-follow-a-terminal-into-its-agent-id ()
  (bp/agent-sessions-folder-test--with-db
    (let ((buf (generate-new-buffer " *folder-terminal*")))
      (unwind-protect
          (let* ((id (plist-get (bp/agent-sessions--folder-create "Project") :id))
                 (plain (list :buffer buf))
                 (agent (list :buffer buf :agent-session-id "durable-thread")))
            (bp/agent-sessions--folder-set plain id)
            (should (equal id (bp/agent-sessions--folder-for-session plain)))
            (bp/agent-sessions--folder-hydrate buf "durable-thread")
            (should (equal id (bp/agent-sessions--folder-for-session agent)))
            (with-current-buffer buf (setq-local bp/agent-session--folder-id nil))
            (should (equal id (bp/agent-sessions--folder-for-session agent)))
            (bp/agent-sessions--folder-set agent nil)
            (should-not (bp/agent-sessions--folder-for-session agent)))
        (kill-buffer buf)))))

(ert-deftest bp/agent-sessions-folders-render-both-views ()
  (bp/agent-sessions-folder-test--with-db
    (let* ((root (make-temp-file "agent-folder-render-" t))
           (terminal (generate-new-buffer " *folder-render-terminal*"))
           (dashboard (generate-new-buffer " *folder-render-dashboard*"))
           (bp/agent-sessions--states nil)
           (bp/agent-sessions--notes nil)
           (bp/agent-sessions--shared-files nil)
           (bp/agent-sessions--shared-links nil)
           (bp/agent-sessions-show-all-worktrees nil))
      (unwind-protect
          (let* ((folder (bp/agent-sessions--folder-create "Across repos"))
                 (session (list :buffer terminal :agent-session-id "render-thread"
                                :agent-type "codex" :status 'stopped
                                :repo "sample-repo" :repo-root root
                                :worktree "sample-worktree" :worktree-path root))
                 (entry (list :id "render-terminal" :session session :title "Task")))
            (bp/agent-sessions--folder-set session (plist-get folder :id))
            (with-current-buffer dashboard
              (bp/agent-sessions-mode)
              (cl-letf (((symbol-function 'bp/agent-sessions--live-entries)
                         (lambda () (list entry))))
                (let ((bp/agent-sessions-group-by-folder t))
                  (bp/agent-sessions--refresh)
                  (should (string-match-p
                           "Across repos (1)\n  sample-repo"
                           (buffer-string)))
                  (should (string-match-p "No folder (0)" (buffer-string))))
                (let ((bp/agent-sessions-group-by-folder nil))
                  (bp/agent-sessions--refresh)
                  (should (string-match-p "Task.*\\[Across repos\\]"
                                          (buffer-string)))))))
        (kill-buffer terminal)
        (kill-buffer dashboard)
        (delete-directory root t)))))

;;; agent-sessions-folder-test.el ends here
