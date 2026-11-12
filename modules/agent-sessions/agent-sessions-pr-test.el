;;; agent-sessions-pr-test.el --- Tests for dashboard PR state  -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'agent-sessions)
(require 'agent-sessions-test)

(defmacro bp/agent-sessions-pr-test--isolated (&rest body)
  "Run BODY with fresh PR state and no PR timers or processes."
  (declare (indent 0) (debug t))
  `(let ((bp/agent-sessions--pr-states (make-hash-table :test 'equal))
         (bp/agent-sessions--pr-urls nil)
         (bp/agent-sessions--pr-process nil)
         (bp/agent-sessions--pr-poll-timer nil)
         (bp/agent-sessions--pr-kick-timer nil))
     ,@body))

(defun bp/agent-sessions-pr-test--node (&rest props)
  "A GraphQL pullRequest node with PROPS and checks state :checks."
  (let ((checks (plist-get props :checks)))
    (append (list :isDraft (plist-get props :isDraft)
                  :state (or (plist-get props :state) "OPEN")
                  :reviewDecision (plist-get props :reviewDecision)
                  :isInMergeQueue (plist-get props :isInMergeQueue)
                  :commits (list :nodes
                                 (list (list :commit
                                             (list :statusCheckRollup
                                                   (and checks
                                                        (list :state checks))))))))))

(defun bp/agent-sessions-pr-test--faces (text)
  "The distinct `font-lock-face' values on TEXT, in order of appearance."
  (let (faces)
    (dotimes (i (length text))
      (let ((face (get-text-property i 'font-lock-face text)))
        (when (and face (not (member face faces)))
          (push face faces))))
    (nreverse faces)))

(ert-deftest bp/agent-sessions-pr-state-from-node-orders-lifecycle ()
  (let ((cases
         `(((:state "MERGED" :isDraft t :checks "FAILURE") merged)
           ((:state "CLOSED" :checks "PENDING") closed)
           ((:isDraft t :isInMergeQueue t :checks "PENDING") draft)
           ((:isInMergeQueue t :checks "PENDING") queue)
           ((:checks "PENDING") checks)
           ((:checks "EXPECTED") checks)
           ((:checks "FAILURE") failed)
           ((:checks "ERROR") failed)
           ((:checks "SUCCESS") open)
           (() open))))
    (pcase-dolist (`(,props ,life) cases)
      (should (eq life (plist-get (bp/agent-sessions--pr-state-from-node
                                   (apply #'bp/agent-sessions-pr-test--node
                                          props))
                                  :life))))))

(ert-deftest bp/agent-sessions-pr-state-from-node-reads-review ()
  (dolist (case '(("APPROVED" approved)
                  ("CHANGES_REQUESTED" changes-requested)
                  ("REVIEW_REQUIRED" nil)
                  (nil nil)))
    (should (eq (cadr case)
                (plist-get (bp/agent-sessions--pr-state-from-node
                            (bp/agent-sessions-pr-test--node
                             :reviewDecision (car case)))
                           :review)))))

(ert-deftest bp/agent-sessions-pr-url-parts-accepts-only-github-prs ()
  (should (equal '("example-org" "example-repo" 26425)
                 (bp/agent-sessions--pr-url-parts
                  "https://github.com/example-org/example-repo/pull/26425")))
  (should (equal '("o" "r" 7)
                 (bp/agent-sessions--pr-url-parts
                  "https://github.com/o/r/pull/7/files")))
  (should-not (bp/agent-sessions--pr-url-parts
               "https://github.com/o/r/issues/7"))
  (should-not (bp/agent-sessions--pr-url-parts
               "https://gitlab.com/o/r/pull/7"))
  (should-not (bp/agent-sessions--pr-url-parts
               "https://github.com/o\"x/r/pull/7")))

(ert-deftest bp/agent-sessions-pr-query-aliases-each-url-in-order ()
  (let ((query (bp/agent-sessions--pr-query
                '("https://github.com/a/b/pull/1"
                  "https://github.com/c/d/pull/2"))))
    (should (string-match-p
             "p0:repository(owner:\"a\",name:\"b\"){pullRequest(number:1)"
             query))
    (should (string-match-p
             "p1:repository(owner:\"c\",name:\"d\"){pullRequest(number:2)"
             query))))

(ert-deftest bp/agent-sessions-pr-apply-response-keeps-good-prs-beside-errors ()
  (bp/agent-sessions-pr-test--isolated
    (let ((good "https://github.com/a/b/pull/1")
          (bad "https://github.com/a/nope/pull/2")
          (silent "https://github.com/a/b/pull/3"))
      (bp/agent-sessions--pr-apply-response
       (list good bad silent)
       (list :data (list :p0 (list :pullRequest
                                   (bp/agent-sessions-pr-test--node
                                    :reviewDecision "APPROVED"
                                    :checks "PENDING"))
                         :p1 nil
                         :p2 nil)
             :errors (list (list :path '("p1")
                                 :message "Could not resolve to a Repository"))))
      (should (equal '(:life checks :review approved)
                     (gethash good bp/agent-sessions--pr-states)))
      (should (equal '(:error "Could not resolve to a Repository")
                     (gethash bad bp/agent-sessions--pr-states)))
      (should (equal '(:error "PR not found")
                     (gethash silent bp/agent-sessions--pr-states))))))

(ert-deftest bp/agent-sessions-pr-failure-keeps-the-last-good-state ()
  (bp/agent-sessions-pr-test--isolated
    (let ((known "https://github.com/a/b/pull/1")
          (failed "https://github.com/a/b/pull/2")
          (new "https://github.com/a/b/pull/3"))
      (puthash known '(:life open :review nil) bp/agent-sessions--pr-states)
      (puthash failed '(:error "old") bp/agent-sessions--pr-states)
      (bp/agent-sessions--pr-record-failure (list known failed new) "offline")
      (should (equal '(:life open :review nil)
                     (gethash known bp/agent-sessions--pr-states)))
      (should (equal '(:error "offline")
                     (gethash failed bp/agent-sessions--pr-states)))
      (should (equal '(:error "offline")
                     (gethash new bp/agent-sessions--pr-states))))))

(ert-deftest bp/agent-sessions-pr-glyphs-and-words-show-each-state ()
  (bp/agent-sessions-pr-test--isolated
    (let ((url "https://github.com/a/b/pull/1"))
      (should (equal "…" (bp/agent-sessions--pr-glyphs url)))
      (should (equal "fetching…" (bp/agent-sessions--pr-words url)))
      (puthash url '(:life checks :review approved) bp/agent-sessions--pr-states)
      (let ((glyphs (bp/agent-sessions--pr-glyphs url))
            (words (bp/agent-sessions--pr-words url)))
        (should (equal "◔ ✓" glyphs))
        (should (equal '(bp/agent-session-pr-checks bp/agent-session-pr-approved)
                       (bp/agent-sessions-pr-test--faces glyphs)))
        (should (equal "checks running · approved" words)))
      (puthash url '(:life failed :review changes-requested)
               bp/agent-sessions--pr-states)
      (should (equal "◔ ✗" (bp/agent-sessions--pr-glyphs url)))
      (should (equal '(bp/agent-session-pr-failed
                       bp/agent-session-pr-changes-requested)
                     (bp/agent-sessions-pr-test--faces
                      (bp/agent-sessions--pr-glyphs url))))
      (should (equal "checks failed · changes requested"
                     (bp/agent-sessions--pr-words url)))
      (puthash url '(:life merged :review nil) bp/agent-sessions--pr-states)
      (should (equal "◉" (bp/agent-sessions--pr-glyphs url)))
      (should (equal "merged" (bp/agent-sessions--pr-words url)))
      (puthash url '(:error "Bad credentials") bp/agent-sessions--pr-states)
      (should (equal "?" (bp/agent-sessions--pr-glyphs url)))
      (should (equal "Bad credentials" (bp/agent-sessions--pr-words url))))
    (should (equal "" (bp/agent-sessions--pr-glyphs "https://example.com/pr/1")))
    (should (equal "not a GitHub PR URL"
                   (bp/agent-sessions--pr-words "https://example.com/pr/1")))))

(ert-deftest bp/agent-sessions-pr-single-link-speaks-for-the-session ()
  (bp/agent-sessions-test--with-temp-db
    (let ((one (list :agent-session-id "thread-one"))
          (two (list :agent-session-id "thread-two")))
      (bp/agent-sessions--share-link
       one "linear" "https://linear.app/issue/ABC-1" "ABC-1")
      (bp/agent-sessions--share-link
       one "pr" "https://github.com/a/b/pull/1" "PR 1")
      (should (equal "https://github.com/a/b/pull/1"
                     (plist-get (bp/agent-sessions--session-pr-link one) :url)))
      (bp/agent-sessions--share-link
       two "pr" "https://github.com/a/b/pull/2" "PR 2")
      (bp/agent-sessions--share-link
       two "pr" "https://github.com/a/b/pull/3" "PR 3")
      (should-not (bp/agent-sessions--session-pr-link two))
      (should (equal '("https://github.com/a/b/pull/1"
                       "https://github.com/a/b/pull/2"
                       "https://github.com/a/b/pull/3")
                     (bp/agent-sessions--pr-urls-of
                      (list (list :session one) (list :session two)
                            (list :session one))))))))

(ert-deftest bp/agent-sessions-pr-row-puts-glyphs-after-state ()
  (bp/agent-sessions-test--with-temp-db
    (bp/agent-sessions-pr-test--isolated
      (let ((session (list :agent-session-id "thread-one"))
            (url "https://github.com/a/b/pull/1"))
        (bp/agent-sessions--share-link session "pr" url "PR 1")
        (puthash url '(:life queue :review approved) bp/agent-sessions--pr-states)
        (with-temp-buffer
          (setq bp/agent-sessions--pr-column-width
                bp/agent-sessions--pr-marks-width)
          (let* ((marks (bp/agent-sessions--pr-marks session))
                 (row (bp/agent-sessions--row-text
                       "    " "REVIEW" "Title\n"
                       'bp/agent-session-needs-attention marks))
                 (start (+ 4 (bp/agent-sessions--state-column-width))))
            (should (equal "◕ ✓  " marks))
            (should (equal "◕ ✓  Title\n" (substring row start)))
            ;; The glyph keeps its colour and the row keeps its highlight.
            (should (equal '(bp/agent-session-pr-queue
                             bp/agent-session-needs-attention)
                           (get-text-property start 'font-lock-face row)))
            (should (eq 'bp/agent-session-needs-attention
                        (get-text-property (1+ start) 'font-lock-face row)))))
        (with-temp-buffer
          (setq bp/agent-sessions--pr-column-width 0)
          (should (equal "" (bp/agent-sessions--pr-marks session))))))))

(ert-deftest bp/agent-sessions-pr-link-row-ends-with-words ()
  (bp/agent-sessions-test--with-temp-db
    (bp/agent-sessions-pr-test--isolated
      (let ((session (list :agent-session-id "thread-one"))
            (pr "https://github.com/a/b/pull/1"))
        (bp/agent-sessions--share-link
         session "linear" "https://linear.app/issue/ABC-1" "ABC-1")
        (bp/agent-sessions--share-link session "pr" pr "PR #1")
        (puthash pr '(:life open :review changes-requested)
                 bp/agent-sessions--pr-states)
        (with-temp-buffer
          (bp/agent-sessions-mode)
          (let ((inhibit-read-only t)
                (bp/agent-sessions--row-status nil))
            (bp/agent-sessions--insert-links session "  ")
            (let ((lines (split-string (buffer-string) "\n" t)))
              (should (string-suffix-p "ABC-1" (car lines)))
              (should (string-suffix-p "PR #1   open · changes requested"
                                       (cadr lines))))))))))

(defun bp/agent-sessions-pr-test--fake-gh (stdout stderr status)
  "Write a fake `gh' printing STDOUT and STDERR, exiting STATUS; return its path."
  (let ((script (make-temp-file "fake-gh-")))
    (with-temp-file script
      (insert "#!/bin/sh\n"
              (format "printf '%%s' %s\n" (shell-quote-argument stdout))
              (format "printf '%%s\\n' %s >&2\n" (shell-quote-argument stderr))
              (format "exit %d\n" status)))
    (set-file-modes script #o755)
    script))

(defun bp/agent-sessions-pr-test--fetch-with (gh urls)
  "Fetch URLS through the fake GH and wait for it to finish."
  (setq bp/agent-sessions--pr-urls urls)
  (cl-letf (((symbol-function 'executable-find)
             (lambda (name &rest _) (and (equal name "gh") gh)))
            ((symbol-function 'bp/agent-sessions--refresh-if-visible) #'ignore))
    (bp/agent-sessions--pr-fetch)
    (let ((proc bp/agent-sessions--pr-process))
      (should proc)
      (while (process-live-p proc)
        (accept-process-output proc 0.1))
      ;; The sentinel runs after the process dies; give it its turn.
      (let ((deadline (+ (float-time) 5)))
        (while (and bp/agent-sessions--pr-process (< (float-time) deadline))
          (accept-process-output nil 0.05))))))

(ert-deftest bp/agent-sessions-pr-fetch-reads-partial-answers-from-gh ()
  (bp/agent-sessions-pr-test--isolated
    (let* ((good "https://github.com/a/b/pull/1")
           (bad "https://github.com/a/nope/pull/2")
           (gh (bp/agent-sessions-pr-test--fake-gh
                (concat "{\"data\":{\"p0\":{\"pullRequest\":{\"isDraft\":true,"
                        "\"state\":\"OPEN\",\"reviewDecision\":null,"
                        "\"isInMergeQueue\":false,\"commits\":{\"nodes\":[]}}},"
                        "\"p1\":null},\"errors\":[{\"path\":[\"p1\"],"
                        "\"message\":\"Could not resolve\"}]}")
                "gh: Could not resolve" 1)))
      (unwind-protect
          (progn
            (bp/agent-sessions-pr-test--fetch-with gh (list good bad))
            (should (equal '(:life draft :review nil)
                           (gethash good bp/agent-sessions--pr-states)))
            (should (equal '(:error "Could not resolve")
                           (gethash bad bp/agent-sessions--pr-states))))
        (delete-file gh)))))

(ert-deftest bp/agent-sessions-pr-fetch-reports-a-whole-failure ()
  (bp/agent-sessions-pr-test--isolated
    (let* ((known "https://github.com/a/b/pull/1")
           (new "https://github.com/a/b/pull/2")
           (gh (bp/agent-sessions-pr-test--fake-gh
                "" "gh: error connecting to api.github.com\nmore detail" 1)))
      (puthash known '(:life open :review nil) bp/agent-sessions--pr-states)
      (unwind-protect
          (progn
            (bp/agent-sessions-pr-test--fetch-with gh (list known new))
            (should (equal '(:life open :review nil)
                           (gethash known bp/agent-sessions--pr-states)))
            (should (equal '(:error "error connecting to api.github.com")
                           (gethash new bp/agent-sessions--pr-states))))
        (delete-file gh)))))

(ert-deftest bp/agent-sessions-pr-fetch-skips-final-prs-unless-forced ()
  (bp/agent-sessions-pr-test--isolated
    (let ((merged "https://github.com/a/b/pull/1")
          (started nil))
      (puthash merged '(:life merged :review approved)
               bp/agent-sessions--pr-states)
      (setq bp/agent-sessions--pr-urls (list merged "https://example.com/x"))
      (cl-letf (((symbol-function 'executable-find) (lambda (&rest _) "/bin/gh"))
                ((symbol-function 'make-process)
                 (lambda (&rest args) (setq started args) nil))
                ((symbol-function 'process-put) #'ignore)
                ((symbol-function 'set-process-sentinel) #'ignore)
                ((symbol-function 'run-with-timer) #'ignore))
        (bp/agent-sessions--pr-fetch)
        (should-not started)
        (bp/agent-sessions--pr-fetch t)
        (should started)
        (let ((command (plist-get started :command)))
          (delete-file (nth 5 command))
          (should (string-match-p "pullRequest(number:1)" (nth 4 command))))))))

(ert-deftest bp/agent-sessions-pr-fetch-without-gh-records-why ()
  (bp/agent-sessions-pr-test--isolated
    (let ((url "https://github.com/a/b/pull/1"))
      (setq bp/agent-sessions--pr-urls (list url))
      (cl-letf (((symbol-function 'executable-find) #'ignore)
                ((symbol-function 'bp/agent-sessions--refresh-if-visible)
                 #'ignore))
        (bp/agent-sessions--pr-fetch))
      (should (equal '(:error "gh not found")
                     (gethash url bp/agent-sessions--pr-states))))))

(ert-deftest bp/agent-sessions-pr-note-shown-arms-timers-only ()
  (bp/agent-sessions-pr-test--isolated
    (let (timers)
      (cl-letf (((symbol-function 'run-with-timer)
                 (lambda (secs repeat fn) (push (list secs repeat fn) timers)
                   (list 'timer secs)))
                ((symbol-function 'make-process)
                 (lambda (&rest _) (error "The render must not start a process"))))
        (bp/agent-sessions--pr-note-shown nil)
        (should-not timers)
        (bp/agent-sessions--pr-note-shown '("https://github.com/a/b/pull/1"))
        ;; The poll, and a near-immediate fetch for the never-fetched PR.
        (should (= 2 (length timers)))
        (should (equal '(0.5 nil) (butlast (car timers))))
        (setq timers nil)
        (bp/agent-sessions--pr-note-shown '("https://github.com/a/b/pull/1"))
        ;; Both already armed.
        (should-not timers)))))

(provide 'agent-sessions-pr-test)
;;; agent-sessions-pr-test.el ends here
