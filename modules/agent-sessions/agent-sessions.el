;; Dashboard for Claude/Codex/Pi sessions running in vterm buffers.
;;
;; Every vterm buffer gets a unique id injected into its shell environment
;; (EMACS_AGENT_SESSION_ID) at creation time, with no special launcher command
;; needed. Hook scripts for Claude Code / Codex, and a Pi extension, forward
;; their event payloads to `bp/agent-hook-notify' via emacsclient, keyed by
;; that id, so sessions sharing a worktree still resolve to the right buffer.

(require 'cl-lib)
(require 'seq)
(require 'json)
(require 'server)
(require 'diff)
;; Not autoloaded: `with-sqlite-transaction' is a macro in sqlite.el, so
;; without this the persistent store's writes fail at *call* time, long after
;; the file has loaded cleanly.
(require 'sqlite)
(require 'magit)
(require 'magit-section)
(require 'project)
(require 'org)
;; Not autoloaded: `format-spec' renders the launch templates in
;; `bp/agent-orchestration-launch-commands', and a spawn is the first thing
;; that would notice it missing — long after this file loaded cleanly.
(require 'format-spec)

(defconst bp/agent-sessions--dir
  (file-name-directory (or load-file-name buffer-file-name
                           (locate-library "agent-sessions") default-directory))
  "Directory this package lives in; its hook forwarder scripts sit beside it.")

(defconst bp/agent-sessions--bin-dir
  (expand-file-name "bin" bp/agent-sessions--dir)
  "Directory of the commands an agent may run from inside a session terminal.
Placed on the PATH of every session terminal, so `emacs-share' is simply there
— nothing for the user to install and nothing for the agent to locate.")

(defvar bp/agent-sessions--extra-terminal-env nil
  "Extra `VAR=VALUE' strings to inject into the next terminal created.
Bound around a terminal-creating call.  It exists because the environment is
assembled by the vterm/eat advice, deep inside those packages' own internals,
so there is no argument to thread through: see `bp/agent-orchestration-spawn',
the only binder.  A worker learns its role and its coordinator from the
environment rather than from its launch command because the id it is addressed
by is minted by that same advice, and so is not known to the caller yet.")

(defun bp/agent-sessions--terminal-environment (id)
  "Environment entries to inject into a session terminal identified by ID.
The PATH entry is built from the PATH the terminal was going to inherit anyway
\(`process-environment' is what the subprocess gets), so this is strictly
additive.  Assembling one from anywhere else could silently *shrink* the
shell's PATH, which is the failure mode worth designing away here."
  (append (list (format "EMACS_AGENT_SESSION_ID=%s" id)
                (format "PATH=%s%s%s" bp/agent-sessions--bin-dir path-separator
                        (or (getenv "PATH") "")))
          bp/agent-sessions--extra-terminal-env))

(defvar bp/agent-session-id->buffer (make-hash-table :test 'equal)
  "Session id -> vterm buffer, populated for every vterm buffer at creation.")

(defvar bp/agent-sessions (make-hash-table :test 'equal)
  "Session id -> plist of live agent state and its terminal buffer.
Includes agent identity, hook status, repo/worktree, and Claude's most recently
submitted prompt when its `UserPromptSubmit' hook provided one.
Populated lazily: an entry only exists once a hook event has fired for it.")

(defvar bp/agent-session-counter 0)

(defconst bp/agent-orchestration-message-types
  '("status" "done" "blocked" "question" "answer")
  "The types an inter-agent message may carry.
Deliberately short: `done' is the one an orchestrator waits on, `blocked' and
`question' are the two ways a worker stops short of it, `answer' closes a
question or replies to later mail delivered to a resting worker, and `status'
is everything else.  A larger vocabulary would have to earn itself by changing
what some command *does*, not just what a row says.")

(defconst bp/agent-orchestration-actionable-message-types
  '("done" "blocked" "question" "answer")
  "Mail types important enough to steer a running Codex turn.
Plain `status' mail waits for the recipient to become idle, unless actionable
mail is queued with it, so progress chatter cannot repeatedly steer active
work and earlier context still stays ordered with the actionable message.")

(defvar bp/agent-orchestration--mail (make-hash-table :test 'equal)
  "Recipient terminal id -> list of message plists, oldest first.
A message is (:id :from :from-key :from-label :to :to-key :type :subject :body
:files :report :sent-at :read).

This is the working copy, keyed the way mail is *addressed* at runtime; the
record is the `mail' table, keyed by durable identity.  Both exist because they
answer different questions: the render path reads this one (it must never touch
the database), and a session that outlives this Emacs is found again through the
other.  Filled from the database by `bp/agent-orchestration--hydrate' when a
session's identity becomes known, and dropped for a terminal when it is killed
\(`bp/agent-session--cleanup') — dropping the working copy, never the record.")

(defvar bp/agent-orchestration--counter 0
  "Source of message and brief ids within this Emacs.")

(defvar-local bp/agent-orchestration-coordinator nil
  "Terminal id of the agent that spawned this one, when it was spawned by one.
Set on the worker's buffer at spawn, which is what `emacs-agent list' reads to
answer \"whose workers are these\" without consulting the message log.")

(defvar-local bp/agent-session-id nil
  "Unique id injected into this vterm buffer's shell environment, if any.")

(defvar-local bp/agent-session--created-at nil
  "When this terminal buffer was created; the dashboard's stable sort key.
Lives on the buffer rather than in the session plist because the plist is
rebuilt from scratch on every hook event, and because plain terminals that
have never fired a hook need the same key.  See
`bp/agent-sessions--sort-tree-stable'.")

(defvar-local bp/agent-session--viewed-at nil
  "When the user most recently selected this terminal buffer.
Used to order the agent picker shown by `bp/agent-sessions-send-region'.")

(defvar bp/agent-sessions--last-focused-buffer nil
  "Buffer seen by the previous focus-hook run.
This distinguishes actually selecting a terminal from hook runs caused by
output arriving in a terminal that was already selected.")

(defvar-local bp/agent-session--resuming-session-id nil
  "Agent session id this terminal was opened to resume.
This bridges startup until the agent's first hook confirms its identity, so a
message addressed through an older terminal can find this live replacement.")

(defvar-local bp/agent-session--folder-id nil
  "Folder chosen for this terminal before or between agent session ids.")

(defconst bp/agent-sessions-buffer-name "*Agent Sessions*")

(defcustom bp/agent-sessions-terminal 'vterm
  "Terminal emulator backend used for agent sessions.
Either `vterm' or `eat'.  Only the selected package needs to be installed;
it is loaded lazily the first time a session terminal is created."
  :type '(choice (const :tag "vterm" vterm)
                 (const :tag "eat" eat)))

(defcustom bp/agent-sessions-show-all-worktrees nil
  "When non-nil, list every worktree of a repo, even those with no session.
This makes it easy to spin up a new session in an idle worktree with the
`+' key (`bp/agent-sessions-new-vterm').  Only repos that already have at
least one session are shown; the option controls whether their empty
worktrees are listed too."
  :type 'boolean)

(defcustom bp/agent-session-notify-on-attention t
  "When non-nil, show a desktop notification when a session needs attention.
The notification fires only on the transition into `needs-attention'/`error',
not on every hook event, so a session that stays waiting is announced once."
  :type 'boolean)

(defvar bp/agent-sessions-sort-by-activity nil
  "When non-nil, sort repos, worktrees, and sessions by most recent activity.
Off by default because `:updated-at' changes on every hook event, so two
sessions running at once continually swap places in the dashboard.  The
default is the stable order of `bp/agent-sessions--sort-tree-stable'.
Toggle with `s' \(`bp/agent-sessions-toggle-sort').")

(defvar bp/agent-sessions-group-by-folder nil
  "When non-nil, display folder → repo → worktree → session.
Toggle with `f'; the regular view groups by repo and worktree.")

(defconst bp/agent-session-status-alist
  '((claude . ((Stop . needs-attention)
               (StopFailure . error)
               (PermissionRequest . needs-attention)
               (TeammateIdle . needs-attention)
               (UserPromptSubmit . running)))
    (codex . ((Stop . needs-attention)
              (PermissionRequest . needs-attention)
              (UserPromptSubmit . running)
              (agent-turn-complete . needs-attention)))
    (pi . ((Stop . needs-attention)
           (StopFailure . error)
           (UserPromptSubmit . running))))
  "Per-agent hook/notify event name -> status.
Events not listed here (PreToolUse, PostToolUse, SubagentStart/Stop, etc.)
leave a session's existing status unchanged rather than resetting it — hook
invocations are independent async processes with no delivery ordering
guarantee, so an informational event can arrive after Stop/PermissionRequest
and must not clobber the needs-attention state those set.")

(defun bp/agent-session--status-for (agent-type event-name)
  "Return the status EVENT-NAME maps to, or nil if it shouldn't change status."
  (cdr (assq (intern event-name)
             (alist-get (intern agent-type) bp/agent-session-status-alist))))

(defun bp/agent-sessions--canonical-path (path)
  "Return PATH canonicalized to a directory name for use as a hash-table key."
  (and path (file-name-as-directory (file-truename path))))

(defun bp/agent-sessions--worktree-label (path branch)
  "Return the display label for the worktree at PATH on BRANCH.
Shows the worktree directory name and, when known, its branch as
`<dir> (<branch>)' so sessions sharing a repo but on different worktrees are
easy to tell apart.  Falls back to just the directory name when BRANCH is nil
(detached HEAD)."
  (let ((dir (file-name-nondirectory (directory-file-name path))))
    (if branch
        (format "%s (%s)" dir branch)
      dir)))

(defun bp/agent-session--repo-info (dir)
  "Return session repo/worktree info for the git repo containing DIR.
The plist has :repo NAME, :repo-root ROOT (the main worktree's directory),
:worktree LABEL, and :worktree-path DIR."
  (let* ((default-directory dir)
         (toplevel (ignore-errors (magit-toplevel))))
    (if (not toplevel)
        (list :repo nil :repo-root nil :worktree nil :worktree-path nil)
      (let* ((common-dir (ignore-errors
                            (let ((default-directory toplevel))
                              (magit-git-string "rev-parse" "--path-format=absolute"
                                                 "--git-common-dir"))))
             (main-root (if common-dir
                            (file-name-as-directory (expand-file-name ".." common-dir))
                          toplevel))
             (repo-name (file-name-nondirectory (directory-file-name main-root)))
             (branch (ignore-errors (let ((default-directory toplevel))
                                       (magit-get-current-branch))))
             (worktree-label (bp/agent-sessions--worktree-label toplevel branch)))
        (list :repo repo-name
              :repo-root (file-name-as-directory main-root)
              :worktree worktree-label
              :worktree-path (file-name-as-directory toplevel))))))

(defun bp/agent-sessions--compute-worktrees (root)
  "Return (:label L :path P) for every non-bare worktree of the repo at ROOT.
Runs git; use `bp/agent-sessions--all-worktrees' for the cached version."
  (ignore-errors
    (let ((default-directory root))
      (delq nil
            (mapcar
             (lambda (wt)
               ;; (PATH COMMIT BRANCH BARE DETACHED LOCKED PRUNABLE)
               (unless (nth 3 wt)
                 (let* ((path (car wt))
                        (branch (nth 2 wt))
                        (label (bp/agent-sessions--worktree-label path branch)))
                   (list :label label :path (file-name-as-directory path)))))
             (magit-list-worktrees))))))

(defvar bp/agent-sessions--worktrees-cache (make-hash-table :test 'equal)
  "Cache of repo ROOT -> git worktree list, to keep refreshes cheap.
`magit-list-worktrees' spawns a git subprocess per repo, which made
re-rendering (e.g. toggling the sort with `s') slow.  Invalidated by
`bp/agent-sessions-refresh' (\\`g'), which re-reads git.")

(defun bp/agent-sessions--all-worktrees (root)
  "Return the cached git worktree list for the repo at ROOT.
Populates the cache on first use; `bp/agent-sessions-refresh' clears it."
  (let ((cached (gethash root bp/agent-sessions--worktrees-cache 'miss)))
    (if (eq cached 'miss)
        (puthash root (bp/agent-sessions--compute-worktrees root)
                 bp/agent-sessions--worktrees-cache)
      cached)))

(defun bp/agent-session--cleanup ()
  (when bp/agent-session-id
    (when (eq bp/agent-sessions--last-focused-buffer (current-buffer))
      (setq bp/agent-sessions--last-focused-buffer nil))
    (bp/agent-sessions--log-close-buffer)
    (remhash bp/agent-session-id bp/agent-session-id->buffer)
    (remhash bp/agent-session-id bp/agent-sessions)
    (remhash bp/agent-session-id bp/agent-orchestration--mail)
    (bp/agent-sessions--refresh-if-visible)))

(defun bp/agent-sessions--vterm-advice (orig-fun pop-to-buf-fun &optional arg)
  (let* ((id (format "%d-%d" (emacs-pid) (cl-incf bp/agent-session-counter)))
         (vterm-environment (append (bp/agent-sessions--terminal-environment id)
                                    vterm-environment))
         (buf (funcall orig-fun pop-to-buf-fun arg)))
    (when (buffer-live-p buf)
      (puthash id buf bp/agent-session-id->buffer)
      (with-current-buffer buf
        (setq-local bp/agent-session-id id)
        (setq-local bp/agent-session--created-at (current-time))
        (add-hook 'kill-buffer-hook #'bp/agent-session--cleanup nil t))
      (bp/agent-sessions--log-open buf)
      (bp/agent-sessions--refresh-if-visible))
    buf))

(defvar-local bp/agent-session-title nil
  "Terminal title most recently set by this vterm's process (OSC escape), if any.
Agents typically set this to something like the current task/session summary.")

(defvar-local bp/agent-session-title-override nil
  "A user-chosen title for this session, set via the dashboard's `SPC' command.
When non-nil it takes precedence over `bp/agent-session-title' everywhere the
session is labelled, so the agent's OSC title updates don't clobber it.")

(defvar-local bp/agent-session--branched-from nil
  "When non-nil, a cons (PARENT-SID . LABEL) recording the session this one was
branched/forked from.  Set on a freshly branched terminal (by the `b' command
or `bp/agent-sessions-mark-parent') so its agent session records the parentage
once its first hook fires, and preserved across subsequent hook events.")

(defvar-local bp/agent-session--parent-detached-p nil
  "Non-nil when this session was explicitly detached from its fork parent.
This prevents fork auto-detection from restoring a relationship removed with
`bp/agent-sessions-detach-parent'.")

(defvar-local bp/agent-session--marked-unread nil
  "When non-nil, the user marked this session as needing attention (`u').
Kept on the buffer rather than in `bp/agent-sessions' so it works for a plain
terminal that has no registry entry yet, and so a later hook event's status
computation (which honours the *previous* status) can't be skewed by it.  The
flag only overrides the status at display time, and is cleared the same way a
real needs-attention is: by looking at the session.")

(defun bp/agent-sessions--capture-title (title)
  (setq-local bp/agent-session-title title))

(defun bp/agent-sessions--eat-advice (orig-fun program arg display-fn)
  "Give eat sessions the same id injection/registration as vterm.
Injects EMACS_AGENT_SESSION_ID and the agent command directory via
`process-environment' (which `eat-exec' inherits when it spawns the shell) and
registers the resulting buffer."
  (let* ((id (format "%d-%d" (emacs-pid) (cl-incf bp/agent-session-counter)))
         (process-environment
          (append (bp/agent-sessions--terminal-environment id)
                  process-environment))
         (buf (funcall orig-fun program arg display-fn)))
    (when (buffer-live-p buf)
      (puthash id buf bp/agent-session-id->buffer)
      (with-current-buffer buf
        (setq-local bp/agent-session-id id)
        (setq-local bp/agent-session--created-at (current-time))
        (add-hook 'kill-buffer-hook #'bp/agent-session--cleanup nil t))
      (bp/agent-sessions--log-open buf)
      (bp/agent-sessions--refresh-if-visible))
    buf))

;; eat's default title handler is `ignore', so instead capture the title by
;; advising the emulator's title setter, which runs with the eat buffer
;; current (same idea as the `vterm--set-title' advice above).
(defun bp/agent-sessions--eat-capture-title (title &rest _)
  (setq-local bp/agent-session-title title))

(defun bp/agent-session--clear-attention-on-focus ()
  "Downgrade needs-attention to `stopped' for the session in the selected window.
A needs-attention session has stopped and is waiting for the user; once the
user looks at it the highlight should clear, but the agent is still idle, so
the status becomes `stopped' rather than `running' (which would wrongly imply
it is thinking/outputting).

Deliberately does not rely on `current-buffer' here: vterm's process filter
briefly makes its buffer current while inserting output even when it isn't
the buffer the user is actually looking at, which would clear the flag
spuriously."
  (let* ((buf (window-buffer (selected-window)))
         (id (and (buffer-live-p buf) (buffer-local-value 'bp/agent-session-id buf)))
         (changed nil))
    (unless (eq buf bp/agent-sessions--last-focused-buffer)
      (setq bp/agent-sessions--last-focused-buffer buf)
      (when id
        (with-current-buffer buf
          (setq-local bp/agent-session--viewed-at (current-time)))))
    (when id
      (let ((session (gethash id bp/agent-sessions)))
        ;; A user-set unread mark clears the same way, and for the same reason:
        ;; the user has now looked at the session.
        (when (buffer-local-value 'bp/agent-session--marked-unread buf)
          (with-current-buffer buf (setq-local bp/agent-session--marked-unread nil))
          (setq changed t))
        (when (and session (eq (plist-get session :status) 'needs-attention))
          (puthash id (plist-put session :status 'stopped) bp/agent-sessions)
          (setq changed t))))
    ;; A shared file stops nagging once it has been read, however it was
    ;; opened — `RET' in the dashboard is the common way, but a file the agent
    ;; also mentioned by path and you jumped to yourself has still been read.
    ;; Gated on the database being open, which it is whenever a terminal has
    ;; ever been created, so an Emacs with no sessions pays nothing for this
    ;; on a hook that runs at every buffer switch.
    (when (and (buffer-live-p buf) (sqlitep bp/agent-sessions--db))
      (let ((truename (buffer-local-value 'buffer-file-truename buf)))
        (when (and truename
                   (bp/agent-sessions--shared-path-p truename)
                   (bp/agent-sessions--set-visited
                    (lambda (f) (equal (file-truename (plist-get f :path))
                                       truename))
                    t))
          (setq changed t))))
    (when changed
      (bp/agent-sessions--refresh-if-visible))))

(defun bp/agent-session--desktop-notify (title body)
  "Show a desktop notification with TITLE and BODY.
Uses `osascript' on macOS, D-Bus `notifications-notify' where available, and
falls back to the echo area otherwise.  Always non-blocking."
  (cond
   ((eq system-type 'darwin)
    (call-process "osascript" nil 0 nil
                  "-e" (format "display notification %S with title %S"
                               body title)))
   ((fboundp 'notifications-notify)
    (notifications-notify :title title :body body))
   (t (message "%s: %s" title body))))

(defun bp/agent-session--notify-attention (buf agent-type info status)
  "Notify that BUF's AGENT-TYPE session needs attention.
INFO is the repo plist from `bp/agent-session--repo-info'; STATUS is the new
\(attention-worthy) status.  The notification title is `<repo> - <worktree>';
the body names the agent type, state, and its terminal title (task summary)."
  (let* ((repo (plist-get info :repo))
         (wt (plist-get info :worktree))
         (where (cond ((and repo wt) (format "%s - %s" repo wt))
                      (wt wt)
                      (repo repo)
                      (t (buffer-name buf))))
         (title (or (buffer-local-value 'bp/agent-session-title buf)
                    (buffer-name buf))))
    (bp/agent-session--desktop-notify
     where
     (format "%s %s: %s"
             agent-type
             (if (eq status 'error) "error" "needs attention")
             title))))

(defun bp/agent-sessions--hook-buffer (transport-id agent-type payload)
  "Resolve a hook PAYLOAD to its terminal buffer.
TRANSPORT-ID is the `EMACS_AGENT_SESSION_ID' inherited by the hook process.
Normally it names the terminal directly.  A shared agent daemon can retain an
older terminal's environment, however, so prefer an already-known agent
session id and reject a direct buffer that belongs to a different session.
As a final fallback, return the unique unresolved AGENT-TYPE terminal whose
directory matches PAYLOAD's `cwd'; return nil rather than guess if ambiguous."
  (let* ((agent-sid (or (and payload (gethash "session_id" payload))
                        (and payload (gethash "conversation_id" payload))
                        (and payload (gethash "thread_id" payload))))
         (cwd (and payload (gethash "cwd" payload)))
         (canonical-cwd (and cwd (ignore-errors
                                   (bp/agent-sessions--canonical-path cwd))))
         (direct (gethash transport-id bp/agent-session-id->buffer))
         (known
          (and agent-sid
               (catch 'found
                 (maphash
                  (lambda (_id session)
                    (when (equal agent-sid
                                 (plist-get session :agent-session-id))
                      (let ((buf (plist-get session :buffer)))
                        (when (buffer-live-p buf)
                          (throw 'found buf)))))
                  bp/agent-sessions)
                 nil))))
    (or known
        (and (buffer-live-p direct)
             (let ((existing (gethash transport-id bp/agent-sessions)))
               (and (or (null agent-sid)
                        (null (plist-get existing :agent-session-id))
                        (equal agent-sid
                               (plist-get existing :agent-session-id)))
                    (or (null canonical-cwd)
                        (equal canonical-cwd
                               (ignore-errors
                                 (bp/agent-sessions--canonical-path
                                  (buffer-local-value 'default-directory
                                                      direct)))))
                    direct)))
        (and canonical-cwd
             (let (candidates)
               (maphash
                (lambda (id buf)
                  (when (buffer-live-p buf)
                    (let ((existing (gethash id bp/agent-sessions)))
                      (when (and
                             ;; A terminal already owned by another durable
                             ;; session cannot be this hook's origin.
                             (or (null (plist-get existing :agent-session-id))
                                 (equal agent-sid
                                        (plist-get existing :agent-session-id)))
                             (equal canonical-cwd
                                    (ignore-errors
                                      (bp/agent-sessions--canonical-path
                                       (buffer-local-value 'default-directory
                                                           buf))))
                             (equal agent-type
                                    (or (plist-get existing :agent-type)
                                        (bp/agent-sessions--foreground-command
                                         buf))))
                        (push buf candidates)))))
                bp/agent-session-id->buffer)
               (and (= (length candidates) 1) (car candidates)))))))

(defun bp/agent-hook-notify (session-id agent-type payload-file)
  "Entry point called via emacsclient from the Claude/Codex hook scripts.
SESSION-ID is the terminal id inherited by the hook process.  The payload's
agent session id and working directory can reroute a stale daemon environment
to the terminal that actually owns the event."
  (let* ((payload (unwind-protect
                      (ignore-errors
                        (json-parse-string (with-temp-buffer
                                              (insert-file-contents payload-file)
                                              (buffer-string))))
                    (ignore-errors (delete-file payload-file))))
         (buf (bp/agent-sessions--hook-buffer session-id agent-type payload))
         ;; From here onward SESSION-ID must mean the actual terminal being
         ;; updated, not the possibly stale environment value the hook used.
         (session-id (or (and (buffer-live-p buf)
                              (buffer-local-value 'bp/agent-session-id buf))
                         session-id))
         (event-name (or (and payload (gethash "hook_event_name" payload))
                         (and payload (gethash "type" payload))
                         "unknown"))
         (existing (gethash session-id bp/agent-sessions))
         (status (or (bp/agent-session--status-for agent-type event-name)
                     (and existing (plist-get existing :status))
                     'running))
         ;; The agent's *own* session id (a UUID), as opposed to our
         ;; per-buffer EMACS_AGENT_SESSION_ID. This is what `claude --resume'
         ;; / `codex resume' need. Not every event carries it, so fall back
         ;; to the previously captured value.
         (agent-session-id (or (and payload (gethash "session_id" payload))
                               (and payload (gethash "conversation_id" payload))
                               (and payload (gethash "thread_id" payload))
                               (and existing (plist-get existing :agent-session-id))))
         ;; Path to this session's transcript (Claude includes it on every
         ;; hook, notably SessionStart). Used to auto-detect fork parentage.
         (transcript-path (or (and payload (gethash "transcript_path" payload))
                              (and existing (plist-get existing :transcript-path))))
         ;; Claude leaves the submitted text rendered in its composer while a
         ;; turn starts and sometimes after it stops.  Remember the hook's
         ;; authoritative value so that retained text is not mistaken for a
         ;; new human draft.  Other events preserve the last submitted value.
         (submitted-prompt
          (or (and (equal event-name "UserPromptSubmit")
                   payload
                   (gethash "user_prompt" payload))
              (and existing (plist-get existing :submitted-prompt)))))
    (when (buffer-live-p buf)
      (let* ((info (bp/agent-session--repo-info (buffer-local-value 'default-directory buf)))
             ;; Parentage, in priority order: what a previous event already
             ;; recorded; the marker a fresh `b'-branch left on the buffer; or,
             ;; the first time we see this session, an auto-detected fork parent
             ;; (a manual `claude … --fork-session' shares the parent's history).
             (branched-from (or (and existing (plist-get existing :branched-from))
                                (buffer-local-value 'bp/agent-session--branched-from buf)
                                (and (not existing)
                                     (not (buffer-local-value
                                           'bp/agent-session--parent-detached-p buf))
                                     (equal agent-type "claude")
                                     transcript-path
                                     (bp/agent-sessions--detect-parent
                                      agent-session-id transcript-path session-id)))))
        (puthash session-id
                 (list :buffer buf
                       :agent-type agent-type
                       :agent-session-id agent-session-id
                       :transcript-path transcript-path
                       :submitted-prompt submitted-prompt
                       :status status
                       :last-event event-name
                       :updated-at (current-time)
                       :repo (plist-get info :repo)
                       :repo-root (plist-get info :repo-root)
                       :worktree (plist-get info :worktree)
                       :worktree-path (plist-get info :worktree-path)
                       :branched-from branched-from)
                 bp/agent-sessions)
        (bp/agent-sessions--folder-hydrate buf agent-session-id)
        ;; Keep the restore log in step.  `SessionEnd' is the agent telling us
        ;; it is going away while its terminal stays; every other event just
        ;; describes a session that is still running.  Note this deliberately
        ;; does not appear in `bp/agent-session-status-alist': ending is not a
        ;; status a straggler event should be able to undo.
        (if (equal event-name "SessionEnd")
            (bp/agent-sessions--log-end buf)
          (bp/agent-sessions--log-update buf agent-type agent-session-id))
        ;; Notify only on the transition *into* an attention state, so a
        ;; session that stays waiting isn't re-announced on every later event.
        (when (and bp/agent-session-notify-on-attention
                   (bp/agent-sessions--attention-p status)
                   (not (bp/agent-sessions--attention-p
                         (and existing (plist-get existing :status)))))
          (bp/agent-session--notify-attention buf agent-type info status))
        ;; This event is where a session's durable identity becomes known, so
        ;; it is also where mail stored for it under that identity — by a
        ;; previous Emacs, or before this terminal had an agent id — is picked
        ;; up.  Then deliver: Codex has a session-aware native queue, while an
        ;; agent without one may have been waiting for this event to make a
        ;; terminal paste safe.
        (bp/agent-orchestration--hydrate session-id)
        (bp/agent-orchestration-deliver
         session-id (equal event-name "UserPromptSubmit"))))
    (bp/agent-sessions--refresh-if-visible))
  nil)

(defvar-local bp/agent-sessions--repo-info-cache nil
  "Cons of (DIRECTORY . REPO-INFO-PLIST) cached per terminal buffer.
Computing repo info shells out to git, so cache it per buffer and only
recompute when the buffer's `default-directory' changes (e.g. after a `cd').")

(defun bp/agent-sessions--buffer-repo-info (buf)
  "Return `bp/agent-session--repo-info' for BUF, cached on its directory."
  (with-current-buffer buf
    (let ((dir default-directory))
      (if (and bp/agent-sessions--repo-info-cache
               (equal (car bp/agent-sessions--repo-info-cache) dir))
          (cdr bp/agent-sessions--repo-info-cache)
        (cdr (setq bp/agent-sessions--repo-info-cache
                   (cons dir (bp/agent-session--repo-info dir))))))))

(defun bp/agent-sessions--buffer-terminal-type (buf)
  "Return a symbol naming BUF's terminal backend (`vterm', `eat', or `term')."
  (pcase (buffer-local-value 'major-mode buf)
    ('vterm-mode 'vterm)
    ('eat-mode 'eat)
    (_ 'term)))

(defvar-local bp/agent-sessions--foreground-cache nil
  "Cache for `bp/agent-sessions--foreground-command': (TPGID . NAME).")

(defun bp/agent-sessions--foreground-command (buf)
  "Name of the command running in the foreground of BUF's terminal, or nil.
Nil means BUF's own shell is in the foreground — nothing is running — so the
caller should fall back to naming the terminal backend.

Reads the pty's foreground process *group* (`tpgid') straight out of Emacs's
native process table: two `process-attributes' calls, no subprocess and no
walk of the process list.  When a command is in the foreground the kernel
points `tpgid' at that job's leader; when it exits, `tpgid' returns to the
shell's own `pgrp', so a row tracks start and finish with no bookkeeping and
nothing to keep in sync.

The name comes from `args', not `comm': Claude's executable lives in a
version-numbered directory, so its `comm' reads \"2.1.231\".  Platforms whose
`process-attributes' omits `tpgid' just get nil, and rows read as before.

The foreground group is re-read on every call, and only the *name* is cached,
reused while that group is unchanged.  That test is exact rather than a
heuristic — the same foreground group is the same job, so its name cannot have
changed — which is why there is no time-based reuse here.  A timed cache was
tried and removed: reading the group for 12 terminals costs ~3.6ms against a
~22ms refresh, and skipping that check bought back only those 3.6ms in
exchange for a label that could be up to a third of a second out of date.  For
a display whose whole purpose is showing what is running now, that is the
wrong side of the trade; `g' already costs ~1.4s, so this is not the expensive
thing on the path.  What the cache does save is real: reading a *command line*
is the costly half, and a job that sits there never pays it twice."
  (with-current-buffer buf
    (let* ((proc (get-buffer-process buf))
           (attrs (and proc (process-live-p proc)
                       (ignore-errors (process-attributes (process-id proc)))))
           (tpgid (cdr (assq 'tpgid attrs)))
           (pgrp (cdr (assq 'pgrp attrs)))
           ;; Non-nil only when some job other than the shell holds the
           ;; terminal, i.e. a command is actually running.
           (fg (and (integerp tpgid) (> tpgid 0) (not (eql tpgid pgrp)) tpgid))
           (cache bp/agent-sessions--foreground-cache))
      (cond
       ((null fg)
        (setq-local bp/agent-sessions--foreground-cache nil)
        nil)
       ((and cache (eql fg (car cache)))
        (cdr cache))
       (t
        (let* ((args (cdr (assq 'args (ignore-errors (process-attributes fg)))))
               (name (and (stringp args) (not (string-empty-p args))
                          (file-name-nondirectory
                           (car (split-string args nil t))))))
          (setq-local bp/agent-sessions--foreground-cache (cons fg name))
          name))))))

(defun bp/agent-sessions--terminal-session (buf)
  "Synthesize a session plist for a plain terminal BUF with no agent session.
These fill in for vterm/eat buffers that have not (yet) fired an agent hook,
so idle terminals still appear in the dashboard tree."
  (let ((info (bp/agent-sessions--buffer-repo-info buf)))
    (list :buffer buf
          :agent-session-id
          (buffer-local-value 'bp/agent-session--resuming-session-id buf)
          ;; Whatever is running right now, agent or not; the backend name only
          ;; when the terminal is sitting at its shell prompt.
          :agent-type (or (bp/agent-sessions--foreground-command buf)
                          (bp/agent-sessions--buffer-terminal-type buf))
          :status 'idle
          :last-event nil
          :updated-at nil
          ;; What the buffer already knows about its parentage, so a terminal
          ;; that was just branched or spawned nests under the session that
          ;; created it straight away rather than only once its first hook
          ;; event promotes the marker into a registry entry.
          :branched-from (buffer-local-value 'bp/agent-session--branched-from buf)
          :repo (plist-get info :repo)
          :repo-root (plist-get info :repo-root)
          :worktree (plist-get info :worktree)
          :worktree-path (plist-get info :worktree-path))))

(defun bp/agent-sessions--session-for-id (id)
  "Return the session plist for ID.
Prefers a real agent session (`bp/agent-sessions'); falls back to a
synthesized terminal session for a plain terminal buffer that has no
agent hook yet, or nil if no live buffer is registered for ID."
  (or (gethash id bp/agent-sessions)
      (let ((buf (gethash id bp/agent-session-id->buffer)))
        (and (buffer-live-p buf)
             (bp/agent-sessions--terminal-session buf)))))

(defun bp/agent-sessions--session-for-agent-id (agent-session-id)
  "Return the live session whose durable id is AGENT-SESSION-ID.
Unlike a terminal id, this identity belongs to the Claude or Codex session and
therefore remains trustworthy when a shared agent daemon has retained an older
terminal's environment."
  (catch 'found
    (maphash
     (lambda (_id session)
       (when (and (equal agent-session-id
                         (plist-get session :agent-session-id))
                  (buffer-live-p (plist-get session :buffer)))
         (throw 'found session)))
     bp/agent-sessions)
    nil))

(defun bp/agent-sessions--session-for-share (terminal-id agent-session-id)
  "Resolve a share command's TERMINAL-ID and AGENT-SESSION-ID.
Prefer a supplied durable agent identity.  If it is unknown, return nil rather
than fall back to TERMINAL-ID: a stale daemon environment can name a different
live terminal, and attaching work to that session would be worse than failing."
  (if (and agent-session-id (not (string-empty-p agent-session-id)))
      (bp/agent-sessions--session-for-agent-id agent-session-id)
    (bp/agent-sessions--session-for-id terminal-id)))

(defun bp/agent-sessions--session-title (session)
  "The title for SESSION's buffer: the user override if any, else the OSC title."
  (let ((buf (plist-get session :buffer)))
    (and (buffer-live-p buf)
         (or (buffer-local-value 'bp/agent-session-title-override buf)
             (buffer-local-value 'bp/agent-session-title buf)))))

(defun bp/agent-sessions--session-short-label (session)
  "A concise human label for SESSION: its terminal title, else worktree, else id."
  (or (bp/agent-sessions--session-title session)
      (plist-get session :worktree)
      (plist-get session :agent-session-id)
      "?"))

(defun bp/agent-sessions--session-label (session)
  "A disambiguating label for SESSION: `<worktree> [<agent>] <title>'.
Used when prompting the user to pick a session."
  (format "%s [%s] %s"
          (or (plist-get session :worktree) "?")
          (plist-get session :agent-type)
          (or (bp/agent-sessions--session-title session)
              (plist-get session :agent-session-id)
              "")))

(defcustom bp/agent-session-auto-detect-branches t
  "When non-nil, auto-detect that a Claude session was forked from another.
A fork (`claude --resume … --fork-session', or Claude's own fork feature)
copies the parent's transcript verbatim, so the child's message uuids include
the parent's, sharing the same root uuid.  On the child's first hook we scan
tracked sessions and record the best-matching parent as `:branched-from', the
same field the `b' command and `bp/agent-sessions-mark-parent' set by hand."
  :type 'boolean)

(defvar bp/agent-sessions--uuid-cache (make-hash-table :test 'equal)
  "Transcript PATH -> (MTIME ROOT-UUID . UUID-HASHSET).
Caches the message uuids of a JSONL transcript, keyed on file mtime so a
grown transcript is re-read but an unchanged one is not.")

(defun bp/agent-sessions--transcript-uuids (path)
  "Return (ROOT-UUID . SET) of message uuids in the JSONL transcript at PATH.
ROOT-UUID is the first message uuid (the conversation root, shared by every
fork of a lineage); SET is a hash-set of all message uuids.  Cached by mtime.
Returns nil when PATH is unreadable or has no message uuids."
  (when (and path (file-readable-p path))
    (let* ((mtime (file-attribute-modification-time (file-attributes path)))
           (cached (gethash path bp/agent-sessions--uuid-cache)))
      (if (and cached (equal (car cached) mtime))
          (cdr cached)
        (let ((set (make-hash-table :test 'equal))
              (root nil))
          (with-temp-buffer
            (insert-file-contents path)
            (goto-char (point-min))
            (while (re-search-forward
                    "\"uuid\"[[:space:]]*:[[:space:]]*\"\\([0-9a-fA-F-]+\\)\"" nil t)
              (let ((u (match-string 1)))
                (unless root (setq root u))
                (puthash u t set))))
          (if (zerop (hash-table-count set))
              (progn (puthash path (cons mtime nil) bp/agent-sessions--uuid-cache) nil)
            (cdr (puthash path (cons mtime (cons root set))
                          bp/agent-sessions--uuid-cache))))))))

(defun bp/agent-sessions--detect-parent (child-sid child-transcript self-id)
  "Return (PARENT-SID . LABEL) if CHILD-TRANSCRIPT looks like a fork, else nil.
CHILD-SID is the child's own agent session id and SELF-ID its EMACS session id
\(both used to avoid matching the child against itself).  A fork copies its
parent's messages verbatim, so among tracked Claude sessions sharing the
child's root uuid, the parent is the one whose uuids are (almost) fully
contained in the child's; the largest such match is the immediate parent."
  (when bp/agent-session-auto-detect-branches
    (let ((child (bp/agent-sessions--transcript-uuids child-transcript)))
      (when (and child (cdr child) (> (hash-table-count (cdr child)) 1))
        (let ((child-root (car child))
              (child-set (cdr child))
              (best nil) (best-overlap 0))
          (maphash
           (lambda (id session)
             (let ((p-path (plist-get session :transcript-path))
                   (p-sid (plist-get session :agent-session-id)))
               (when (and p-path
                          (equal (plist-get session :agent-type) "claude")
                          (not (equal id self-id))
                          (not (and child-sid p-sid (equal p-sid child-sid)))
                          (not (equal p-path child-transcript)))
                 (let ((p (bp/agent-sessions--transcript-uuids p-path)))
                   (when (and p (cdr p) (equal (car p) child-root))
                     (let ((p-set (cdr p)) (p-size 0) (overlap 0))
                       (maphash (lambda (u _)
                                  (cl-incf p-size)
                                  (when (gethash u child-set) (cl-incf overlap)))
                                p-set)
                       ;; Parent must be (nearly) wholly contained in the child
                       ;; and smaller than it; pick the most-contained match.
                       (when (and (> p-size 0)
                                  (>= overlap 2)
                                  (< p-size (hash-table-count child-set))
                                  (>= (/ (float overlap) p-size) 0.85)
                                  (> overlap best-overlap))
                         (setq best session best-overlap overlap))))))))
           bp/agent-sessions)
          (when best
            (cons (plist-get best :agent-session-id)
                  (bp/agent-sessions--session-short-label best))))))))

(defun bp/agent-sessions--unread-status (session buf)
  "SESSION with its status forced to `needs-attention' if BUF is marked unread.
Returns a *copy* — the registry plist must not be mutated, or the mark would
leak into the status a later hook event inherits.  An `error' status outranks
the mark and is left alone."
  (if (and (buffer-live-p buf)
           (buffer-local-value 'bp/agent-session--marked-unread buf)
           (not (memq (plist-get session :status) '(needs-attention error))))
      (plist-put (copy-sequence session) :status 'needs-attention)
    session))

(defun bp/agent-sessions--live-entries ()
  "Return (:id ID :session PLIST :title TITLE) for each live terminal buffer.
Includes both real agent sessions (those a hook event has fired for) and
plain vterm/eat buffers with no agent session yet, so idle terminals still
show up in the dashboard.  Opportunistically drops registry entries whose
buffer has been killed, since `kill-buffer-hook' cleanup can be missed (e.g.
buffer killed without running local hooks)."
  (let (entries)
    ;; Real agent sessions: a hook event has fired for these.
    (maphash
     (lambda (id session)
       (let ((buf (plist-get session :buffer)))
         (if (buffer-live-p buf)
             (push (list :id id
                         :session (bp/agent-sessions--unread-status session buf)
                         :title (or (buffer-local-value 'bp/agent-session-title-override buf)
                                    (buffer-local-value 'bp/agent-session-title buf)))
                   entries)
           (remhash id bp/agent-sessions)
           (remhash id bp/agent-session-id->buffer))))
     bp/agent-sessions)
    ;; Plain terminal buffers with no agent session yet.
    (maphash
     (lambda (id buf)
       (cond ((not (buffer-live-p buf))
              (remhash id bp/agent-session-id->buffer))
             ((not (gethash id bp/agent-sessions))
              (push (list :id id
                          :session (bp/agent-sessions--unread-status
                                    (bp/agent-sessions--terminal-session buf) buf)
                          :title (or (buffer-local-value 'bp/agent-session-title-override buf)
                                    (buffer-local-value 'bp/agent-session-title buf)))
                    entries))))
     bp/agent-session-id->buffer)
    (nreverse entries)))

(defface bp/agent-session-needs-attention
  '((t :inherit warning :weight bold :extend t
       :background "#4a3b00" :foreground "#ffd75f"))
  "Face for a session row that needs attention (spans the full row).")

(defface bp/agent-session-error
  '((t :inherit error :weight bold :extend t
       :background "#4a1010" :foreground "#ff8f8f"))
  "Face for a session row in the error state (spans the full row).")

(defun bp/agent-sessions--face-for (status)
  (pcase status
    ('needs-attention 'bp/agent-session-needs-attention)
    ('error 'bp/agent-session-error)
    (_ 'default)))

(defvar-local bp/agent-sessions--row-status nil
  "Alist of (LINE-POS . STATUS) for the rows as last rendered, in buffer order.
Filled by the render path and consumed by `N'/`P'.  It exists because the
status a row *shows* is not the one in the registry — `bp/agent-sessions--
unread-status' overlays the `u' mark onto a copy at display time — so a
navigation command that re-derives status from the registry silently skips
every manually marked row.  Record what was drawn; don't derive it twice.")

(defun bp/agent-orchestration--messages (id)
  (gethash id bp/agent-orchestration--mail))

(defun bp/agent-orchestration--pending (id &optional types)
  "Unread messages for ID, optionally filtered to TYPES (a list of strings)."
  (seq-filter (lambda (m)
                (and (not (plist-get m :read))
                     (or (null types) (member (plist-get m :type) types))))
              (bp/agent-orchestration--messages id)))

(defun bp/agent-orchestration--pending-count (id)
  (length (bp/agent-orchestration--pending id)))

(defun bp/agent-orchestration--consume (messages)
  "Mark MESSAGES read, in memory and in the database.
Each plist carries `:read' from birth so this mutates the stored plist rather
than a copy.  The database write is what stops a message being delivered twice
across a restart; a failure to record it is reported rather than raised, since
an agent reading its inbox must not fail because the database is busy."
  (let ((now (bp/agent-sessions--now)))
    (dolist (m messages)
      (plist-put m :read t)
      (condition-case err
          (sqlite-execute (bp/agent-sessions--db)
                          "UPDATE mail SET read_at = ? WHERE id = ?"
                          (list now (plist-get m :id)))
        (error (message "agent-sessions: could not mark mail read (%s)"
                        (error-message-string err)))))))

(defun bp/agent-orchestration--row-badge (id)
  "The dashboard suffix announcing unread mail for ID, or an empty string."
  (let ((n (bp/agent-orchestration--pending-count id)))
    (if (> n 0) (format "  ✉%d" n) "")))

(defun bp/agent-sessions--state-column-width ()
  "Width of the state column: the widest state, plus a separating space.
Computed rather than fixed so a state added to `bp/agent-sessions-states' does
not push the titles of stated rows out of line with unstated ones."
  (1+ (apply #'max 0 (mapcar #'length bp/agent-sessions-states))))

(defun bp/agent-sessions--row-text (prefix state suffix face)
  "Build a session row: PREFIX, STATE in its own column, then SUFFIX.
FACE dresses the whole row (it is what spans an attention highlight across it),
and the state's own face is *merged* on top rather than replacing it — merged,
because the state faces set a foreground and the row face sets a background, and
either replacing the row face or letting it win would lose one of the two."
  (let* ((column (format (format "%%-%ds" (bp/agent-sessions--state-column-width))
                         (or state "")))
         (row (propertize (concat prefix column suffix) 'font-lock-face face))
         (state-face (and state (bp/agent-sessions--state-face state))))
    (when state-face
      ;; A *list* of faces on `font-lock-face', not `add-face-text-property':
      ;; that function merges into `face', which these rows do not use (magit
      ;; buffers run font-lock, which owns `face'), so the merge was silently
      ;; ignored.  Earlier faces in the list win per attribute, which is
      ;; exactly the split wanted here — the state's foreground over the row's
      ;; background.
      (put-text-property (length prefix)
                         (+ (length prefix) (length state))
                         'font-lock-face (list state-face face)
                         row))
    row))

(defun bp/agent-sessions--insert-session (entry &optional depth suppress-parent-note)
  "Insert a session row for ENTRY.
DEPTH indents the row (children of a branched-from parent are rendered one
level deeper).  When SUPPRESS-PARENT-NOTE is non-nil the `↳ from …' suffix is
omitted — used when the row is already nested under its parent, where the
indentation conveys the relationship."
  (let* ((id (plist-get entry :id))
         (session (plist-get entry :session))
         (status (plist-get session :status))
         (face (bp/agent-sessions--face-for status))
         (marker (pcase status
                   ('needs-attention "● ")
                   ('error "✖ ")
                   (_ "  ")))
         (title (or (plist-get entry :title) ""))
         (branched-from (plist-get session :branched-from))
         (indent (make-string (* 2 (or depth 0)) ?\s))
         (base (if bp/agent-sessions-group-by-folder "      " "    "))
         (folder (and (not bp/agent-sessions-group-by-folder)
                      (bp/agent-sessions--folder
                       (bp/agent-sessions--folder-for-session session)))))
    ;; Record what this row *shows*, for `N'/`P' (see the variable's docstring).
    (push (cons (line-beginning-position) status) bp/agent-sessions--row-status)
    (magit-insert-section (bp/agent-session-row id)
      ;; A heading rather than a plain insert so the row's note becomes its
      ;; collapsible body; with no note the body is empty and magit shows no
      ;; fold indicator.
      (magit-insert-heading
        (bp/agent-sessions--row-text
         (concat base indent marker
                 (format "%-7s %-16s " (plist-get session :agent-type) status))
         (bp/agent-sessions--session-state session)
         (format "%s%s%s%s\n"
                 title
                 (bp/agent-orchestration--row-badge id)
                 (if folder (format "  [%s]" (plist-get folder :name)) "")
                 (if (and branched-from (not suppress-parent-note))
                     (format "  ↳ from %s" (cdr branched-from))
                   ""))
         face))
      (bp/agent-sessions--insert-note
       (bp/agent-sessions--session-note-keys session)
       (concat base indent "    "))
      (bp/agent-sessions--insert-links session (concat base indent "    "))
      (bp/agent-sessions--insert-files session (concat base indent "    ")))))

(defun bp/agent-sessions--insert-entries (entries)
  "Insert ENTRIES, nesting any branched session under its parent when present.
A session whose `:branched-from' parent id matches another entry in ENTRIES is
rendered indented directly beneath that parent (one extra level per hop);
entries whose parent isn't in this list render at the top level.

The parent/child graph is built and walked by unique entry `:id' (never by
the shared agent session id) and a session is never made its own parent, so
duplicate session ids and reference cycles cannot cause infinite recursion; a
visited set and a final safety-net pass guarantee each entry renders exactly
once."
  (let ((by-sid (make-hash-table :test 'equal))    ; agent-session-id -> entries
        (children (make-hash-table :test 'equal))  ; parent entry :id -> child entries
        (parent-of (make-hash-table :test 'equal)) ; entry :id -> t when it has a parent
        (roots nil))
    ;; Index sid -> list of entries (a session id can appear in more than one
    ;; terminal — notably a just-forked child briefly shares its parent's id
    ;; until the fork mints a new one).
    (dolist (e entries)
      (let ((sid (plist-get (plist-get e :session) :agent-session-id)))
        (when sid (push e (gethash sid by-sid)))))
    (maphash (lambda (sid es) (puthash sid (nreverse es) by-sid)) by-sid)
    ;; Resolve each entry's parent from its recorded parent session id.  Match a
    ;; *different* entry carrying that id: a fork can transiently share its
    ;; parent's session id, so `sid = psid' is fine as long as it's another
    ;; terminal.  The visited set below is what actually prevents cycles.
    (dolist (e entries)
      (let* ((psid (car (plist-get (plist-get e :session) :branched-from)))
             (parent (and psid
                          (seq-find (lambda (c) (not (eq c e)))
                                    (gethash psid by-sid)))))
        (when parent
          (puthash (plist-get e :id) t parent-of)
          (push e (gethash (plist-get parent :id) children)))))
    (dolist (e entries)
      (unless (gethash (plist-get e :id) parent-of)
        (push e roots)))
    (setq roots (nreverse roots))
    (let ((visited (make-hash-table :test 'equal)))
      (cl-labels ((emit (e depth nested)
                    (unless (gethash (plist-get e :id) visited)
                      (puthash (plist-get e :id) t visited)
                      (bp/agent-sessions--insert-session e depth nested)
                      (dolist (c (reverse (gethash (plist-get e :id) children)))
                        (emit c (1+ depth) t)))))
        (dolist (r roots) (emit r 0 nil))
        ;; Safety net: any entry not reached from a root (e.g. a mutual cycle)
        ;; still renders, at top level.
        (dolist (e entries) (emit e 0 nil))))))

(defun bp/agent-sessions--worktrees-for (root session-groups)
  "Return the ordered worktree plists to render for a repo.
SESSION-GROUPS is an alist of (CANONICAL-PATH . ENTRIES).  When
`bp/agent-sessions-show-all-worktrees' is set and ROOT is known, every
git worktree is listed (in git order), merging in any sessions; otherwise
only the worktrees that actually have sessions are returned.
Each element is (:label L :path P :entries ENTRIES)."
  (let (result seen)
    (when (and bp/agent-sessions-show-all-worktrees root)
      (dolist (wt (bp/agent-sessions--all-worktrees root))
        (let* ((path (plist-get wt :path))
               (canon (bp/agent-sessions--canonical-path path)))
          (push canon seen)
          (push (list :label (plist-get wt :label)
                      :path path
                      :entries (cdr (assoc canon session-groups)))
                result))))
    (dolist (sg session-groups)
      (unless (member (car sg) seen)
        (let ((session (plist-get (car (cdr sg)) :session)))
          (push (list :label (or (plist-get session :worktree) "?")
                      ;; Fall back to the live buffer's directory so `+' works
                      ;; even for sessions registered before :worktree-path
                      ;; was tracked (stale registry entries).
                      :path (or (plist-get session :worktree-path)
                                (let ((buf (plist-get session :buffer)))
                                  (and (buffer-live-p buf)
                                       (buffer-local-value 'default-directory buf))))
                      :entries (cdr sg))
                result))))
    (nreverse result)))

(defun bp/agent-sessions--entry-time (entry)
  "The :updated-at time of ENTRY's session, or nil."
  (plist-get (plist-get entry :session) :updated-at))

(defun bp/agent-sessions--entries-time (entries)
  "The most recent :updated-at among ENTRIES, or nil when none have one."
  (let (best)
    (dolist (e entries best)
      (let ((tm (bp/agent-sessions--entry-time e)))
        (when (and tm (or (null best) (time-less-p best tm)))
          (setq best tm))))))

(defun bp/agent-sessions--by-recency (time-fn items)
  "Return ITEMS sorted most-recent-first by (TIME-FN item).
Items whose TIME-FN returns nil (no activity, e.g. empty worktrees) sort last."
  (sort (copy-sequence items)
        (lambda (a b)
          (let ((ta (funcall time-fn a))
                (tb (funcall time-fn b)))
            (cond ((and ta tb) (time-less-p tb ta))
                  (ta t)
                  (t nil))))))

(defun bp/agent-sessions--sort-tree (repos)
  "Sort REPOS, each repo's worktrees, and each worktree's sessions by recency."
  (bp/agent-sessions--by-recency
   (lambda (repo)
     (bp/agent-sessions--entries-time
      (mapcan (lambda (wt) (copy-sequence (plist-get wt :entries)))
              (plist-get repo :worktrees))))
   (mapcar
    (lambda (repo)
      (plist-put
       repo :worktrees
       (bp/agent-sessions--by-recency
        (lambda (wt) (bp/agent-sessions--entries-time (plist-get wt :entries)))
        (mapcar
         (lambda (wt)
           (plist-put wt :entries
                      (bp/agent-sessions--by-recency
                       #'bp/agent-sessions--entry-time
                       (plist-get wt :entries))))
         (plist-get repo :worktrees)))))
    repos)))

(defconst bp/agent-sessions--status-rank
  '((error . 0) (needs-attention . 1) (running . 2))
  "Sort rank per status; anything unlisted (stopped, idle, nil) ranks last.
Only these coarse buckets participate in ordering: a status change is a rare,
meaningful event (a session started waiting on you), so a row moving between
buckets carries information, whereas a row moving because a tool ran does not.")

(defun bp/agent-sessions--entry-rank (entry)
  (or (alist-get (plist-get (plist-get entry :session) :status)
                 bp/agent-sessions--status-rank)
      (length bp/agent-sessions--status-rank)))

(defun bp/agent-sessions--entry-created (entry)
  "ENTRY's buffer creation time, or nil for a buffer registered before the
`bp/agent-session--created-at' stamp existed."
  (let ((buf (plist-get (plist-get entry :session) :buffer)))
    (and (buffer-live-p buf)
         (buffer-local-value 'bp/agent-session--created-at buf))))

(defun bp/agent-sessions--session-buffer-name (session)
  (let ((buf (plist-get session :buffer)))
    (or (and (buffer-live-p buf) (buffer-name buf)) "")))

(defun bp/agent-sessions--entry-buffer-name (entry)
  (bp/agent-sessions--session-buffer-name (plist-get entry :session)))

(defun bp/agent-sessions--sort-entries (entries)
  "Sort ENTRIES by attention bucket, then oldest-first, then buffer name.
Every key is stable under ordinary activity: unlike `:updated-at', none of
them changes when a session merely runs a tool, so two busy sessions keep
their positions instead of trading places on each hook event.  The buffer name
is the final tie-break so the order never depends on hash-table iteration
order (e.g. for buffers with no creation stamp)."
  (sort (copy-sequence entries)
        (lambda (a b)
          (let ((ra (bp/agent-sessions--entry-rank a))
                (rb (bp/agent-sessions--entry-rank b)))
            (if (/= ra rb)
                (< ra rb)
              (let ((ca (bp/agent-sessions--entry-created a))
                    (cb (bp/agent-sessions--entry-created b)))
                (cond ((and ca cb (not (time-equal-p ca cb))) (time-less-p ca cb))
                      ;; Unstamped buffers sort after stamped ones.
                      ((and ca (not cb)) t)
                      ((and cb (not ca)) nil)
                      (t (string< (bp/agent-sessions--entry-buffer-name a)
                                  (bp/agent-sessions--entry-buffer-name b))))))))))

;;; Persisted user intent ---------------------------------------------------
;;
;; Everything else in this file is rebuilt from live buffers, but the manual
;; order (below) and the notes (further down) record decisions the *user* made,
;; not observed session state, so they are written to disk (see CLAUDE.md).
;; All three live in one SQLite file: the notes, the manual order, and the
;; session log that `R' and `bp/agent-sessions-restore-previous' read.  The log
;; is what forced a database — it is append-heavy, queried by recency, and
;; grows without bound, so the old rewrite-the-whole-file-per-change approach
;; was never going to fit it.  Notes and order moved in alongside so there is
;; exactly one persistent thing to back up, inspect, or delete.
;;
;; Both of those are still cached in a hash table and read from it: the render
;; path must never touch the database.  The database is read once on first use
;; and written only when something actually changes.

(defcustom bp/agent-sessions-db-file
  (expand-file-name "agent-sessions.db" user-emacs-directory)
  "SQLite file holding the notes, the manual order, and the session log."
  :type 'file)

(defconst bp/agent-sessions--schema-version 2)

(defvar bp/agent-sessions--db nil
  "Open SQLite handle, or nil before the database is first used.")

(defvar bp/agent-sessions--heartbeat-timer nil
  "Timer stamping `meta.last_seen'; see `bp/agent-sessions--db-heartbeat'.")

(defconst bp/agent-sessions--db-schema
  '("CREATE TABLE IF NOT EXISTS meta (
       key   TEXT PRIMARY KEY,
       value TEXT NOT NULL)"

    ;; One row per agent session — not per terminal.  A terminal you run
    ;; `claude' in twice produces two rows, so either can be restored.
    "CREATE TABLE IF NOT EXISTS sessions (
       id           INTEGER PRIMARY KEY,
       emacs_sid    TEXT    NOT NULL,
       agent_type   TEXT,
       agent_sid    TEXT,
       worktree     TEXT    NOT NULL,
       repo         TEXT,
       label        TEXT,
       title        TEXT,
       opened_at    INTEGER NOT NULL,
       closed_at    INTEGER,
       close_reason TEXT)"
    "CREATE INDEX IF NOT EXISTS sessions_recent ON sessions (closed_at DESC)"
    "CREATE INDEX IF NOT EXISTS sessions_open
       ON sessions (emacs_sid) WHERE closed_at IS NULL"
    "CREATE INDEX IF NOT EXISTS sessions_agent ON sessions (agent_sid)"

    "CREATE TABLE IF NOT EXISTS folders (
       id   INTEGER PRIMARY KEY,
       name TEXT NOT NULL UNIQUE COLLATE NOCASE)"
    "CREATE TABLE IF NOT EXISTS session_folders (
       agent_sid TEXT PRIMARY KEY,
       folder_id INTEGER NOT NULL)"

    "CREATE TABLE IF NOT EXISTS notes (
       kind       TEXT NOT NULL,
       key        TEXT NOT NULL,
       note       TEXT NOT NULL,
       updated_at INTEGER NOT NULL,
       PRIMARY KEY (kind, key))"

    ;; The scope columns default to '' rather than NULL on purpose: SQLite
    ;; treats NULLs as distinct from each other in a primary key, so a NULL
    ;; scope would make every write insert a duplicate instead of replacing.
    ;; The workflow state a session is in (`t' in the dashboard).  Keyed like a
    ;; note, because it is the same kind of thing: something the user chose
    ;; about a session, which would be useless if it evaporated on restart.
    "CREATE TABLE IF NOT EXISTS session_states (
       kind       TEXT NOT NULL,
       key        TEXT NOT NULL,
       state      TEXT NOT NULL,
       updated_at INTEGER NOT NULL,
       PRIMARY KEY (kind, key))"

    "CREATE TABLE IF NOT EXISTS order_entries (
       kind           TEXT    NOT NULL,
       scope_repo     TEXT    NOT NULL DEFAULT '',
       scope_worktree TEXT    NOT NULL DEFAULT '',
       member         TEXT    NOT NULL,
       position       INTEGER NOT NULL,
       PRIMARY KEY (kind, scope_repo, scope_worktree, member))"
    "CREATE INDEX IF NOT EXISTS order_group
       ON order_entries (kind, scope_repo, scope_worktree, position)"

    ;; Files an agent handed the user to look at, keyed by the same identity a
    ;; session's note uses.  Two timestamps, not one: `shared_at' is the first
    ;; time a path was shared and is what orders the list, while `updated_at'
    ;; is the latest, so an agent re-sharing a changed file can light its row
    ;; up again without the row moving out from under the cursor.
    ;; Mail between agents.  Filed under the same durable identity a note or a
    ;; shared file uses, never under the terminal id it was addressed to at
    ;; runtime: terminal ids carry this Emacs's pid and die with it, while the
    ;; agent session id is what `R' resumes, so mail filed under it comes back
    ;; attached to the conversation it belongs to.  Read messages are kept
    ;; rather than deleted, the way `sessions' keeps closed rows: what the
    ;; workers reported is the record of the run.
    "CREATE TABLE IF NOT EXISTS mail (
       id         TEXT PRIMARY KEY,
       from_kind  TEXT NOT NULL,
       from_key   TEXT NOT NULL,
       from_label TEXT,
       to_kind    TEXT NOT NULL,
       to_key     TEXT NOT NULL,
       type       TEXT NOT NULL,
       subject    TEXT NOT NULL,
       body       TEXT,
       files      TEXT,
       report     TEXT,
       sent_at    INTEGER NOT NULL,
       read_at    INTEGER)"
    "CREATE INDEX IF NOT EXISTS mail_inbox ON mail (to_kind, to_key, read_at)"

    "CREATE TABLE IF NOT EXISTS shared_files (
       kind       TEXT    NOT NULL,
       key        TEXT    NOT NULL,
       path       TEXT    NOT NULL,
       label      TEXT,
       shared_at  INTEGER NOT NULL,
       updated_at INTEGER NOT NULL,
       visited_at INTEGER,
       PRIMARY KEY (kind, key, path))"

    ;; The two most recent copies made when an agent shared a file.  The
    ;; contents live outside SQLite in `bp/agent-sessions-file-snapshot-directory';
    ;; this table only follows the same durable owner identity as the file row.
    "CREATE TABLE IF NOT EXISTS shared_file_snapshots (
       kind          TEXT    NOT NULL,
       key           TEXT    NOT NULL,
       path          TEXT    NOT NULL,
       previous_path TEXT,
       current_path  TEXT    NOT NULL,
       updated_at    INTEGER NOT NULL,
       PRIMARY KEY (kind, key, path))"

    ;; External work items an agent wants to keep visible beside its shared
    ;; files.  Each URL has its own row; retrying a registration is idempotent.
    "CREATE TABLE IF NOT EXISTS shared_links (
       owner_kind TEXT    NOT NULL,
       owner_key  TEXT    NOT NULL,
       link_kind  TEXT    NOT NULL,
       url        TEXT    NOT NULL,
       label      TEXT,
       shared_at  INTEGER NOT NULL,
       updated_at INTEGER NOT NULL,
       visited_at INTEGER,
       PRIMARY KEY (owner_kind, owner_key, url))")
  "Statements that bring an empty or existing database up to date.
Schema version 2 changes the key of `shared_links'; see `bp/agent-sessions--db-migrate'.")

(defun bp/agent-sessions--db-migrate (db)
  "Migrate existing tables in DB after the additive schema is installed."
  (when (< (string-to-number (or (caar (sqlite-select db
                                                "SELECT value FROM meta WHERE key = 'schema_version'"))
                                 "0")) 2)
    (sqlite-execute db "CREATE TABLE shared_links_v2 (
       owner_kind TEXT NOT NULL, owner_key TEXT NOT NULL,
       link_kind TEXT NOT NULL, url TEXT NOT NULL, label TEXT,
       shared_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
       visited_at INTEGER, PRIMARY KEY (owner_kind, owner_key, url))")
    (sqlite-execute db "INSERT INTO shared_links_v2 SELECT * FROM shared_links")
    ;; Existing manual-order keys were link kinds.  Each kind had one URL.
    (sqlite-execute db "UPDATE order_entries SET member = (
       SELECT url FROM shared_links
        WHERE owner_key = order_entries.scope_repo
          AND link_kind = order_entries.member)
       WHERE kind = 'links' AND EXISTS (
       SELECT 1 FROM shared_links
        WHERE owner_key = order_entries.scope_repo
          AND link_kind = order_entries.member)")
    (sqlite-execute db "DROP TABLE shared_links")
    (sqlite-execute db "ALTER TABLE shared_links_v2 RENAME TO shared_links")
    (sqlite-execute db "UPDATE meta SET value = '2' WHERE key = 'schema_version'")
    (when (boundp 'bp/agent-sessions--order)
      (setq bp/agent-sessions--order nil))))

(defun bp/agent-sessions--now () (truncate (float-time)))

(defun bp/agent-sessions--db ()
  "Return the open database handle, creating the file on first use.
Opening also reaps (see `bp/agent-sessions--db-reap'), which is why every
caller goes through here rather than touching `bp/agent-sessions--db'."
  (if (sqlitep bp/agent-sessions--db)
      bp/agent-sessions--db
    (let ((db (sqlite-open bp/agent-sessions-db-file)))
      ;; WAL so a second Emacs reading the file can't block this one; the
      ;; timeout so that if one does write, we wait rather than signalling.
      (sqlite-execute db "PRAGMA journal_mode=WAL")
      (sqlite-execute db "PRAGMA busy_timeout=3000")
      (with-sqlite-transaction db
        (dolist (stmt bp/agent-sessions--db-schema)
          (sqlite-execute db stmt))
        (sqlite-execute db "INSERT OR IGNORE INTO meta VALUES ('schema_version', ?)"
                        (list (number-to-string bp/agent-sessions--schema-version)))
        (bp/agent-sessions--db-migrate db))
      (setq bp/agent-sessions--db db)
      (bp/agent-sessions--db-reap db)
      db)))

;; Re-run the schema against an already-open handle, so *loading* this file
;; picks up a schema addition.  `--db' migrates only when it opens the file,
;; and the handle is cached for the life of the Emacs — so without this the
;; documented way to develop this package (reload into the running server)
;; leaves the new code querying a table the old connection never created,
;; which is a flood of "no such table" rather than a clean failure.  Every
;; statement is `IF NOT EXISTS', so re-running them costs nothing.
(when (sqlitep bp/agent-sessions--db)
  (with-sqlite-transaction bp/agent-sessions--db
    (dolist (stmt bp/agent-sessions--db-schema)
      (sqlite-execute bp/agent-sessions--db stmt))
    (bp/agent-sessions--db-migrate bp/agent-sessions--db)))

(defun bp/agent-sessions--meta-get (db key)
  (caar (sqlite-select db "SELECT value FROM meta WHERE key = ?" (list key))))

(defun bp/agent-sessions--meta-set (db key value)
  (sqlite-execute db "INSERT INTO meta VALUES (?, ?)
                      ON CONFLICT(key) DO UPDATE SET value = excluded.value"
                  (list key (format "%s" value))))

(defun bp/agent-sessions--db-reap (db)
  "Close session rows that a previous Emacs left open by dying.
This is the whole crash-detection scheme, and it works because there is only
ever one Emacs: a freshly started one has no sessions of its own yet, so any
row still marked open must belong to an Emacs that never ran its
`kill-emacs-hook'.  The heartbeat in `meta' dates the death; without one we
fall back to when the session opened."
  (let ((seen (bp/agent-sessions--meta-get db "last_seen")))
    (sqlite-execute db
                    "UPDATE sessions
                        SET closed_at = COALESCE(?, opened_at),
                            close_reason = 'crash'
                      WHERE closed_at IS NULL"
                    (list (and seen (string-to-number seen))))))

(defun bp/agent-sessions--db-heartbeat ()
  "Record that Emacs was alive just now, so a crash can be dated.
Deliberately a no-op until the database has been opened for some other
reason — an Emacs with no agent sessions has nothing to date."
  (when (sqlitep bp/agent-sessions--db)
    (bp/agent-sessions--meta-set bp/agent-sessions--db
                                 "last_seen" (bp/agent-sessions--now))))

;;; Session log -------------------------------------------------------------
;;
;; A history of every agent session that has run, so one can be brought back
;; after it is gone: `R' for one you ended yourself, and
;; `bp/agent-sessions-restore-previous' for the lot that went down with Emacs.
;;
;; This is the one thing here that records *observed session state* rather than
;; something the user chose, which the ephemerality rule in CLAUDE.md otherwise
;; forbids.  It earns the exception by never feeding the dashboard: rows still
;; come only from live buffers, so nothing here can make a dead session look
;; alive.  It is a record of what happened, including the dying.
;;
;; How a session's ending is classified, and why it can be:
;;
;;   killed      `kill-buffer-hook' fired — `k' in the dashboard, `C-x k' on
;;               the terminal, or the shell exiting under it.
;;   agent-exit  the agent reported `SessionEnd' but the terminal lives on.
;;   superseded  a different agent session id appeared in the same terminal,
;;               so the previous one had ended without us hearing.
;;   emacs-exit  `kill-emacs-hook' fired: Emacs quit with this still running.
;;   crash       no hook fired at all; found still-open at the next startup.
;;
;; The first three mean "you ended it" and are what `R' offers; the last two
;; mean "it was taken from you" and are what restore-previous offers.  Emacs
;; runs `kill-emacs-hook' but *not* `kill-buffer-hook' when it exits, and that
;; asymmetry is the only reason the two can be told apart at all.

(defvar-local bp/agent-session--log-row nil
  "Row id in the `sessions' table for this terminal's current agent session.
On the buffer rather than looked up, because a terminal can run several agent
sessions in turn and each gets its own row.")

(defvar-local bp/agent-session--log-state nil
  "Last (AGENT-SID AGENT-TYPE TITLE) written for `bp/agent-session--log-row'.
Compared before every write so a busy session touches the database once per
agent session instead of once per hook event.  The dashboard re-renders on
every event; the database must stay off that path.")

(defvar-local bp/agent-session--log-ended-sid nil
  "Agent session id this terminal has already logged the end of.
Hook events have no delivery-order guarantee, so an informational event can
land after `SessionEnd'.  Without this, such a straggler would open a fresh
row and resurrect a session that has already finished.")

(defun bp/agent-sessions--log-open (buf)
  "Insert a session-log row for BUF and remember its id on the buffer."
  (with-current-buffer buf
    (let* ((info (bp/agent-sessions--buffer-repo-info buf))
           (db (bp/agent-sessions--db)))
      (sqlite-execute
       db "INSERT INTO sessions (emacs_sid, worktree, repo, label, opened_at)
           VALUES (?, ?, ?, ?, ?)"
       (list bp/agent-session-id
             (or (plist-get info :worktree-path)
                 (bp/agent-sessions--canonical-path default-directory))
             (plist-get info :repo-root)
             (plist-get info :worktree)
             (bp/agent-sessions--now)))
      (setq-local bp/agent-session--log-state nil)
      (setq-local bp/agent-session--log-row
                  (caar (sqlite-select db "SELECT last_insert_rowid()"))))))

(defun bp/agent-sessions--log-close-row (row reason)
  "Close session-log ROW with REASON, if it is still open."
  (sqlite-execute (bp/agent-sessions--db)
                  "UPDATE sessions SET closed_at = ?, close_reason = ?
                    WHERE id = ? AND closed_at IS NULL"
                  (list (bp/agent-sessions--now) reason row)))

(defun bp/agent-sessions--log-supersede (row)
  "Retire ROW, whose terminal has started a *different* agent session.
Usually that means the previous agent exited without us hearing, and the row
is closed.  The exception is the fork transient: at `SessionStart' a
`--fork-session' child reports its parent's id before minting its own, so ROW
may be a copy of a session still open in another terminal.  Such a row is an
artifact of the fork rather than a session that ever ran here, so it is
deleted instead of being offered by `R' as a resumable duplicate.

Note this reads the *log*, never the fork-detection state — see CLAUDE.md on
why a `sid == parent-sid' test must not go anywhere near that logic."
  (let ((db (bp/agent-sessions--db)))
    (if (sqlite-select db
                       "SELECT 1 FROM sessions a
                         WHERE a.id = ?
                           AND EXISTS (SELECT 1 FROM sessions b
                                        WHERE b.agent_sid = a.agent_sid
                                          AND b.id <> a.id
                                          AND b.closed_at IS NULL)"
                       (list row))
        (sqlite-execute db "DELETE FROM sessions WHERE id = ?" (list row))
      (bp/agent-sessions--log-close-row row "superseded"))))

(defun bp/agent-sessions--log-update (buf agent-type agent-sid)
  "Bring BUF's session-log row in line with the hook event just processed."
  (with-current-buffer buf
    (let* ((title (or bp/agent-session-title-override bp/agent-session-title))
           (state (list agent-sid agent-type title)))
      (unless (or (equal state bp/agent-session--log-state)
                  (and agent-sid
                       (equal agent-sid bp/agent-session--log-ended-sid)))
        (let ((prev-sid (car bp/agent-session--log-state)))
          (when (and bp/agent-session--log-row prev-sid agent-sid
                     (not (equal prev-sid agent-sid)))
            (bp/agent-sessions--log-supersede bp/agent-session--log-row)
            (setq-local bp/agent-session--log-row nil))
          (unless bp/agent-session--log-row
            (bp/agent-sessions--log-open buf))
          (sqlite-execute (bp/agent-sessions--db)
                          "UPDATE sessions
                              SET agent_type = ?, agent_sid = ?, title = ?
                            WHERE id = ?"
                          (list agent-type agent-sid title
                                bp/agent-session--log-row))
          (setq-local bp/agent-session--log-state state))))))

(defun bp/agent-sessions--log-end (buf)
  "Close BUF's current log row: its agent reported that it is exiting.
The terminal itself lives on, and running an agent in it again opens a fresh
row rather than reviving this one."
  (with-current-buffer buf
    (when bp/agent-session--log-row
      (bp/agent-sessions--log-close-row bp/agent-session--log-row "agent-exit")
      (setq-local bp/agent-session--log-ended-sid
                  (car bp/agent-session--log-state))
      (setq-local bp/agent-session--log-row nil)
      (setq-local bp/agent-session--log-state nil))))

(defun bp/agent-sessions--log-close-buffer ()
  "Close the log rows of the terminal being killed, from `kill-buffer-hook'.
Covers both `k' in the dashboard (which is a plain `kill-buffer') and `C-x k'
on the terminal.  Does nothing when the database was never opened, which means
this Emacs logged no sessions and so has none to close."
  (when (and bp/agent-session-id (sqlitep bp/agent-sessions--db))
    (sqlite-execute bp/agent-sessions--db
                    "UPDATE sessions SET closed_at = ?, close_reason = 'killed'
                      WHERE emacs_sid = ? AND closed_at IS NULL"
                    (list (bp/agent-sessions--now) bp/agent-session-id))))

(defun bp/agent-sessions--log-close-all ()
  "Mark every still-open session as ended by Emacs exiting.
Runs from `kill-emacs-hook'.  Also stamps the heartbeat, so that if this Emacs
is *killed* mid-exit the reap still has a recent time to date the crash from."
  (when (sqlitep bp/agent-sessions--db)
    (bp/agent-sessions--db-heartbeat)
    (sqlite-execute bp/agent-sessions--db
                    "UPDATE sessions
                        SET closed_at = ?, close_reason = 'emacs-exit'
                      WHERE closed_at IS NULL"
                    (list (bp/agent-sessions--now)))))

;;; Manual order ------------------------------------------------------------
;;
;; `M-n' / `M-p' nudge the thing at point within its group, overriding the
;; automatic order of `--sort-tree-stable' for that group only.

(defvar bp/agent-sessions--order nil
  "Hash table SCOPE -> ordered list of item keys, or nil before first load.
One scope per group that can be reordered: the repo list, one per repo's
worktrees, one per worktree's sessions.  A scope is a list — (\"worktrees\"
REPO-KEY) and friends — rather than a joined string, so no separator character
can ever appear inside a path component and blur two scopes together.

Item keys are stable identities rather than display labels, which change with
a branch checkout: a canonical repo root, a canonical worktree path, and — for
a session — its buffer name, the only session-level identity that can outlive
a restart.  Backed by the `order_entries' table.")

(defconst bp/agent-sessions--repos-scope '("repos"))

(defun bp/agent-sessions--worktrees-scope (repo-key)
  (list "worktrees" repo-key))

(defun bp/agent-sessions--sessions-scope (repo-key worktree-key)
  (list "sessions" repo-key worktree-key))

(defun bp/agent-sessions--repo-key (repo)
  "Manual-order key for REPO: its canonical root, else its display name."
  (or (bp/agent-sessions--canonical-path (plist-get repo :root))
      (plist-get repo :name)
      "?"))

(defun bp/agent-sessions--worktree-key (wt)
  "Manual-order key for worktree WT: its canonical path, else its label.
Only ever compared within one repo's scope, so the label fallback can't
collide with a like-named worktree of another repo."
  (or (bp/agent-sessions--canonical-path (plist-get wt :path))
      (plist-get wt :label)
      "?"))

(defun bp/agent-sessions--order-scope-row (scope)
  "Return (KIND SCOPE-REPO SCOPE-WORKTREE) for SCOPE, for use as query values.
Absent scope components become the empty string, never NULL — see the
`order_entries' schema for why."
  (list (car scope) (or (nth 1 scope) "") (or (nth 2 scope) "")))

(defun bp/agent-sessions--order-table ()
  "Return the manual-order table, loading it from the database once.
An empty table just means the user hasn't reordered anything."
  (or bp/agent-sessions--order
      (setq bp/agent-sessions--order
            (let ((table (make-hash-table :test 'equal)))
              (pcase-dolist (`(,kind ,repo ,wt ,member)
                             (sqlite-select
                              (bp/agent-sessions--db)
                              "SELECT kind, scope_repo, scope_worktree, member
                                 FROM order_entries ORDER BY position"))
                (let ((scope (cond ((string-empty-p repo) (list kind))
                                   ((string-empty-p wt) (list kind repo))
                                   (t (list kind repo wt)))))
                  (puthash scope
                           (append (gethash scope table) (list member))
                           table)))
              table))))

(defun bp/agent-sessions--order-write-group (scope old new)
  "Persist NEW as SCOPE's member order, writing only the rows that moved.
`M-n' / `M-p' transpose one item with its neighbour, and
`bp/agent-sessions--merge-order' turns that into a NEW list differing from OLD
in exactly two slots — so this normally issues exactly two UPDATEs no matter
how large the group is, and touches no other group at all.

A member NEW has but OLD doesn't is one being placed for the first time (it
had been keeping the automatic order), and is inserted at its new slot; one
OLD has but NEW doesn't is gone and is deleted."
  (let ((row (bp/agent-sessions--order-scope-row scope))
        (db (bp/agent-sessions--db))
        (i 0))
    (with-sqlite-transaction db
      (dolist (member new)
        (unless (eql (seq-position old member) i)
          (sqlite-execute
           db "INSERT INTO order_entries
                 (kind, scope_repo, scope_worktree, member, position)
               VALUES (?, ?, ?, ?, ?)
               ON CONFLICT(kind, scope_repo, scope_worktree, member)
               DO UPDATE SET position = excluded.position"
           (append row (list member i))))
        (setq i (1+ i)))
      (dolist (member old)
        (unless (member member new)
          (sqlite-execute
           db "DELETE FROM order_entries
                WHERE kind = ? AND scope_repo = ? AND scope_worktree = ?
                  AND member = ?"
           (append row (list member))))))))

(defun bp/agent-sessions--order-delete-group (scope)
  "Forget SCOPE's manual order entirely."
  (sqlite-execute (bp/agent-sessions--db)
                  "DELETE FROM order_entries
                    WHERE kind = ? AND scope_repo = ? AND scope_worktree = ?"
                  (bp/agent-sessions--order-scope-row scope)))

(defun bp/agent-sessions--order-delete-all ()
  "Forget every group's manual order."
  (sqlite-execute (bp/agent-sessions--db) "DELETE FROM order_entries"))

(defun bp/agent-sessions--apply-manual-order (scope key-fn items)
  "Return ITEMS reordered to match the manual order recorded for SCOPE.
KEY-FN maps an item to its manual-order key.  Items with no recorded key keep
their incoming (automatic) order and follow the ones that have, so a session
or worktree that appears after a reorder lands at the end of its group rather
than displacing anything the user placed deliberately."
  (let ((order (gethash scope (bp/agent-sessions--order-table))))
    (if (null order)
        items
      (let (ranked rest)
        (dolist (item items)
          (let ((pos (seq-position order (funcall key-fn item))))
            (if pos (push (cons pos item) ranked) (push item rest))))
        (append (mapcar #'cdr (sort (nreverse ranked)
                                    (lambda (a b) (< (car a) (car b)))))
                (nreverse rest))))))

(defun bp/agent-sessions--sort-tree-stable (repos)
  "Order REPOS alphabetically, their worktrees alphabetically, rows by attention,
then apply any manual order (`M-n' / `M-p') on top at each level.
The automatic tree skeleton is deliberately *not* ordered by activity or
attention: a fixed repo/worktree layout is what makes the dashboard navigable
from memory.  Urgency surfaces within a worktree instead, via `--sort-entries'.
A manually placed group overrides that for the items the user positioned; the
rest keep the automatic order after them."
  (bp/agent-sessions--apply-manual-order
   bp/agent-sessions--repos-scope
   #'bp/agent-sessions--repo-key
   (sort (mapcar
          (lambda (repo)
            (let ((rkey (bp/agent-sessions--repo-key repo)))
              (plist-put
               repo :worktrees
               (bp/agent-sessions--apply-manual-order
                (bp/agent-sessions--worktrees-scope rkey)
                #'bp/agent-sessions--worktree-key
                (sort (mapcar
                       (lambda (wt)
                         (plist-put
                          wt :entries
                          (bp/agent-sessions--apply-manual-order
                           (bp/agent-sessions--sessions-scope
                            rkey (bp/agent-sessions--worktree-key wt))
                           #'bp/agent-sessions--entry-buffer-name
                           (bp/agent-sessions--sort-entries
                            (plist-get wt :entries)))))
                       (plist-get repo :worktrees))
                      (lambda (a b) (string< (or (plist-get a :label) "")
                                             (or (plist-get b :label) ""))))))))
          repos)
         (lambda (a b) (string< (or (plist-get a :name) "")
                                (or (plist-get b :name) ""))))))

;;; Notes -------------------------------------------------------------------
;;
;; `e' attaches a free-form, multi-line note to the repo, worktree, or session
;; at point; it renders under that thing's heading.  Persisted for the same
;; reason as the manual order: it is something the user wrote, not session
;; state, so it has to outlive both the session and Emacs.

(defvar bp/agent-sessions--states nil
  "Hash of (KIND KEY) -> workflow state string, or nil before first use.
Loaded from `session_states' once and written through on change, like the
notes table: the render path reads it on every row and must never query the
database.")

(defvar bp/agent-sessions--notes nil
  "Hash table KEY -> note string, or nil before the notes are first read.
A KEY is (\"repo\" REPO-KEY), (\"worktree\" WORKTREE-KEY) or (\"session\" ID),
reusing the stable identities of the manual order.  The type tag is not
decoration: a repo's *main* worktree has the same canonical path as the repo
itself, so an untagged key would make those two share one note.

For a session, ID is the agent's own session id when it has one — that
survives renaming the terminal buffer — and the buffer name otherwise, which is
all a plain terminal has to be identified by.  See
`bp/agent-sessions--session-note-keys'.")

(defun bp/agent-sessions--notes-table ()
  "Return the notes table, loading it from the database once."
  (or bp/agent-sessions--notes
      (setq bp/agent-sessions--notes
            (let ((table (make-hash-table :test 'equal)))
              (pcase-dolist (`(,kind ,key ,note)
                             (sqlite-select (bp/agent-sessions--db)
                                            "SELECT kind, key, note FROM notes"))
                (puthash (list kind key) note table))
              table))))

(defun bp/agent-sessions--repo-note-key (repo)
  "Note key for REPO, a plist with :root/:name (a repo section's value)."
  (list "repo" (bp/agent-sessions--repo-key repo)))

(defun bp/agent-sessions--worktree-note-key (wt)
  "Note key for worktree WT, a plist with :path/:label."
  (list "worktree" (bp/agent-sessions--worktree-key wt)))

(defun bp/agent-sessions--session-note-keys (session)
  "Note keys to try for SESSION, most durable identity first.
An agent session is keyed by the agent's own session id, so renaming its
terminal buffer keeps the note; a plain terminal has no such id and falls back
to its buffer name.  Both keys are consulted when reading, so a note written on
a bare terminal is still found once `claude'/`codex' starts in it and the
session gains an id — at which point `bp/agent-sessions--note-set' moves it to
the id key."
  (let ((sid (plist-get session :agent-session-id))
        (name (bp/agent-sessions--session-buffer-name session)))
    (delq nil (list (and sid (list "session" sid))
                    (and (not (string-empty-p name)) (list "session" name))))))

;;; Folders -----------------------------------------------------------------
;; Folder names and durable session assignments are user choices.  A plain
;; terminal keeps its choice on the buffer until an agent supplies an id.

(defvar bp/agent-sessions--folders-loaded-p nil)
(defvar bp/agent-sessions--folders nil
  "List of (:id ID :name NAME) folders, loaded once from SQLite.")
(defvar bp/agent-sessions--folder-assignments nil
  "Hash of agent session id to folder id, loaded with the folder list.")

(defun bp/agent-sessions--load-folders ()
  "Load folder choices once; subsequent dashboard renders use memory only."
  (unless bp/agent-sessions--folders-loaded-p
    (let ((db (bp/agent-sessions--db))
          (assignments (make-hash-table :test 'equal)))
      (setq bp/agent-sessions--folders
            (mapcar (lambda (row) (list :id (car row) :name (cadr row)))
                    (sqlite-select db "SELECT id, name FROM folders ORDER BY name COLLATE NOCASE")))
      (pcase-dolist (`(,sid ,folder-id)
                     (sqlite-select db "SELECT agent_sid, folder_id FROM session_folders"))
        (puthash sid folder-id assignments))
      (setq bp/agent-sessions--folder-assignments assignments
            bp/agent-sessions--folders-loaded-p t))))

(defun bp/agent-sessions--folder (id)
  "Return the saved folder with ID, or nil."
  (bp/agent-sessions--load-folders)
  (seq-find (lambda (folder) (equal id (plist-get folder :id)))
            bp/agent-sessions--folders))

(defun bp/agent-sessions--folder-session-id (session)
  "Return SESSION's durable id, including an in-progress resume."
  (or (plist-get session :agent-session-id)
      (let ((buf (plist-get session :buffer)))
        (and (buffer-live-p buf)
             (buffer-local-value 'bp/agent-session--resuming-session-id buf)))))

(defun bp/agent-sessions--folder-for-session (session)
  "Return the folder id assigned to SESSION, if any."
  (bp/agent-sessions--load-folders)
  (let* ((buf (plist-get session :buffer))
         (sid (bp/agent-sessions--folder-session-id session))
         (saved (and sid (gethash sid bp/agent-sessions--folder-assignments))))
    (or (and (bp/agent-sessions--folder saved) saved)
        (and (buffer-live-p buf)
             (bp/agent-sessions--folder
              (buffer-local-value 'bp/agent-session--folder-id buf))
             (buffer-local-value 'bp/agent-session--folder-id buf)))))

(defun bp/agent-sessions--folder-set (session folder-id)
  "Assign SESSION to FOLDER-ID, or clear its assignment when nil."
  (bp/agent-sessions--load-folders)
  (when (and folder-id (not (bp/agent-sessions--folder folder-id)))
    (user-error "Folder no longer exists"))
  (let ((sid (bp/agent-sessions--folder-session-id session))
        (buf (plist-get session :buffer)))
    (when sid
      (if folder-id
          (progn
            (sqlite-execute
             (bp/agent-sessions--db)
             "INSERT INTO session_folders (agent_sid, folder_id) VALUES (?, ?)
                ON CONFLICT(agent_sid) DO UPDATE SET folder_id = excluded.folder_id"
             (list sid folder-id))
            (puthash sid folder-id bp/agent-sessions--folder-assignments))
        (sqlite-execute (bp/agent-sessions--db)
                        "DELETE FROM session_folders WHERE agent_sid = ?" (list sid))
        (remhash sid bp/agent-sessions--folder-assignments)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (setq-local bp/agent-session--folder-id folder-id)))))

(defun bp/agent-sessions--folder-hydrate (buf agent-sid)
  "Carry BUF's folder choice to AGENT-SID, or restore its saved folder."
  (when (and agent-sid (buffer-live-p buf))
    (bp/agent-sessions--load-folders)
    (let ((saved (gethash agent-sid bp/agent-sessions--folder-assignments))
          (local (buffer-local-value 'bp/agent-session--folder-id buf)))
      (cond
       ((bp/agent-sessions--folder saved)
        (with-current-buffer buf
          (setq-local bp/agent-session--folder-id saved)))
       ((bp/agent-sessions--folder local)
        (bp/agent-sessions--folder-set
         (list :buffer buf :agent-session-id agent-sid) local))))))

(defun bp/agent-sessions--folder-create (name)
  "Create and return a global folder named NAME."
  (bp/agent-sessions--load-folders)
  (setq name (string-trim name))
  (when (or (string-empty-p name)
            (member (downcase name) '("no folder" "create new folder...")))
    (user-error "Choose a different folder name"))
  (when (seq-find (lambda (folder)
                    (string-equal-ignore-case name (plist-get folder :name)))
                  bp/agent-sessions--folders)
    (user-error "Folder already exists: %s" name))
  (let ((db (bp/agent-sessions--db)))
    (sqlite-execute db "INSERT INTO folders (name) VALUES (?)" (list name))
    (let ((folder (list :id (caar (sqlite-select db "SELECT last_insert_rowid()"))
                        :name name)))
      (push folder bp/agent-sessions--folders)
      folder)))

(defun bp/agent-sessions--folder-rename (folder name)
  "Rename FOLDER to NAME."
  (setq name (string-trim name))
  (when (or (string-empty-p name)
            (member (downcase name) '("no folder" "create new folder...")))
    (user-error "Choose a different folder name"))
  (when (seq-find (lambda (other)
                    (and (not (equal (plist-get other :id) (plist-get folder :id)))
                         (string-equal-ignore-case name (plist-get other :name))))
                  bp/agent-sessions--folders)
    (user-error "Folder already exists: %s" name))
  (sqlite-execute (bp/agent-sessions--db)
                  "UPDATE folders SET name = ? WHERE id = ?"
                  (list name (plist-get folder :id)))
  (plist-put folder :name name))

(defun bp/agent-sessions--folder-delete (folder)
  "Delete FOLDER and move its sessions to No folder."
  (let ((id (plist-get folder :id))
        (db (bp/agent-sessions--db)))
    (with-sqlite-transaction db
      (sqlite-execute db "DELETE FROM session_folders WHERE folder_id = ?" (list id))
      (sqlite-execute db "DELETE FROM folders WHERE id = ?" (list id)))
    (let (removed)
      (maphash (lambda (sid folder-id)
                 (when (equal folder-id id) (push sid removed)))
               bp/agent-sessions--folder-assignments)
      (dolist (sid removed)
        (remhash sid bp/agent-sessions--folder-assignments)))
    (setq bp/agent-sessions--folders (delq folder bp/agent-sessions--folders))
    (dolist (buf (buffer-list))
      (when (equal (buffer-local-value 'bp/agent-session--folder-id buf) id)
        (with-current-buffer buf
          (setq-local bp/agent-session--folder-id nil))))))

(defun bp/agent-sessions--note-find (keys)
  "Return (KEY . NOTE) for the first of KEYS carrying a note, or nil."
  (let ((table (bp/agent-sessions--notes-table)))
    (seq-some (lambda (key)
                (let ((note (gethash key table)))
                  (and (stringp note) (not (string-empty-p note))
                       (cons key note))))
              keys)))

(defun bp/agent-sessions--note-set (keys note)
  "Store NOTE under the first of KEYS and save; an empty NOTE removes it.
Notes under the remaining (less durable) KEYS are dropped, so a session that
gains an agent session id ends up with its note under that id alone rather than
one note per identity it has had."
  (let ((table (bp/agent-sessions--notes-table))
        (db (bp/agent-sessions--db)))
    (with-sqlite-transaction db
      (dolist (key (cdr keys))
        (remhash key table)
        (sqlite-execute db "DELETE FROM notes WHERE kind = ? AND key = ?" key))
      (if (and note (not (string-empty-p note)))
          (progn
            (puthash (car keys) note table)
            (sqlite-execute db "INSERT INTO notes VALUES (?, ?, ?, ?)
                                ON CONFLICT(kind, key) DO UPDATE
                                  SET note = excluded.note,
                                      updated_at = excluded.updated_at"
                            (append (car keys)
                                    (list note (bp/agent-sessions--now)))))
        (remhash (car keys) table)
        (sqlite-execute db "DELETE FROM notes WHERE kind = ? AND key = ?"
                        (car keys))))))

(defcustom bp/agent-sessions-states '("TODO" "BLOCKED" "DONE" "REVIEW" "LEARN")
  "Workflow states a session can be in, in the order `t' cycles them.
`t' moves a session to the next one and off the end back to no state, so the
order is the only thing that decides how many presses a given state costs.  No
state is a state — a session nobody has triaged should not have to claim to be
anything."
  :type '(repeat string))

(defface bp/agent-session-state-todo '((t :inherit org-todo))
  "Face for the TODO state, borrowed from Org so it matches the agenda.")

(defface bp/agent-session-state-done '((t :inherit org-done))
  "Face for the DONE state, borrowed from Org so it matches the agenda.")

(defface bp/agent-session-state-review '((t :inherit bold :foreground "#7aa2f7"))
  "Face for the REVIEW state: waiting on someone else to look.")

(defface bp/agent-session-state-learn '((t :inherit bold :foreground "#bb9af7"))
  "Face for the LEARN state: finished, but there is something here to take away.")

(defun bp/agent-sessions--state-face (state)
  "Face for STATE, or nil for one this package has no opinion about.
Looked up by name rather than by position in `bp/agent-sessions-states' so a
reordered or extended list keeps its colours; a state added by the user simply
renders unstyled until they define `bp/agent-session-state-<name>'."
  (let ((face (intern (format "bp/agent-session-state-%s" (downcase state)))))
    (and (facep face) face)))

(defun bp/agent-sessions--states-table ()
  "Return the workflow-state table, loading it from the database once."
  (or bp/agent-sessions--states
      (setq bp/agent-sessions--states
            (let ((table (make-hash-table :test 'equal)))
              (pcase-dolist (`(,kind ,key ,state)
                             (sqlite-select (bp/agent-sessions--db)
                                            "SELECT kind, key, state FROM session_states"))
                (puthash (list kind key) state table))
              table))))

(defun bp/agent-sessions--session-state (session)
  "The workflow state recorded for SESSION, or nil.
Every identity the session has held is consulted, like a note, so a state set
on a bare terminal is still shown once `claude'/`codex' starts in it."
  (let ((table (bp/agent-sessions--states-table)))
    (seq-some (lambda (key) (gethash key table))
              (bp/agent-sessions--session-note-keys session))))

(defun bp/agent-sessions--state-set (keys state)
  "Record STATE under the first of KEYS; a nil or empty STATE clears it.
Collapses the less durable KEYS onto the first exactly as `bp/agent-sessions--
note-set' does, so a session that gains an agent session id carries one state
under that id rather than one per identity it has had."
  (let ((table (bp/agent-sessions--states-table))
        (db (bp/agent-sessions--db)))
    (with-sqlite-transaction db
      (dolist (key (cdr keys))
        (remhash key table)
        (sqlite-execute db "DELETE FROM session_states WHERE kind = ? AND key = ?" key))
      (if (and state (not (string-empty-p state)))
          (progn
            (puthash (car keys) state table)
            (sqlite-execute db "INSERT INTO session_states VALUES (?, ?, ?, ?)
                                ON CONFLICT(kind, key) DO UPDATE
                                  SET state      = excluded.state,
                                      updated_at = excluded.updated_at"
                            (append (car keys)
                                    (list state (bp/agent-sessions--now)))))
        (remhash (car keys) table)
        (sqlite-execute db "DELETE FROM session_states WHERE kind = ? AND key = ?"
                        (car keys))))))

(defun bp/agent-sessions--next-state (state)
  "The state after STATE in `bp/agent-sessions-states', wrapping through nil."
  (let ((states bp/agent-sessions-states))
    (cond ((null state) (car states))
          ((member state states)
           ;; Off the end is nil rather than the first state: the cycle has to
           ;; pass through "no state" or there would be no way back to it.
           (nth (1+ (seq-position states state)) states))
          (t (car states)))))

(defface bp/agent-session-note
  '((t :inherit font-lock-comment-face))
  "Face for a note attached to a repo, worktree, or session row.")

(defun bp/agent-sessions--insert-note (keys indent)
  "Insert the note for KEYS, if any, as a section indented by INDENT.
The note's first line is the section heading and the rest its body, so TAB
collapses a long note to one line and expands it again.  Fold state survives
the dashboard's re-render because magit caches it per section identity, and a
note's identity is its key — not its position or text."
  (when-let ((found (bp/agent-sessions--note-find keys)))
    (let ((lines (split-string (cdr found) "\n")))
      (magit-insert-section (bp/agent-session-note (car found))
        (magit-insert-heading
          (propertize (concat indent "· " (car lines))
                      'font-lock-face 'bp/agent-session-note))
        (dolist (line (cdr lines))
          (insert (propertize (concat indent "  " line "\n")
                              'font-lock-face 'bp/agent-session-note)))))))

(defun bp/agent-sessions--note-target-at-point ()
  "Return (KEYS . LABEL) for the note-bearing thing at point, or nil.
Point may be on a repo heading, a worktree heading or a session row — or inside
a note already rendered under one of those, which resolves to its parent so `e'
re-edits the note point is sitting in."
  (let ((section (magit-current-section)))
    (when (and section (eq (oref section type) 'bp/agent-session-note))
      (setq section (oref section parent)))
    (pcase (and section (oref section type))
      ('bp/agent-session-repo
       (let ((value (oref section value)))
         (cons (list (bp/agent-sessions--repo-note-key value))
               (or (plist-get value :name) "repo"))))
      ('bp/agent-session-worktree
       (let ((value (oref section value)))
         (cons (list (bp/agent-sessions--worktree-note-key value))
               (or (plist-get value :label) "worktree"))))
      ('bp/agent-session-file
       (let ((path (oref section value)))
         (cons (list (bp/agent-sessions--file-note-key path))
               (file-name-nondirectory (directory-file-name path)))))
      ('bp/agent-session-link
       (when-let* ((row (bp/agent-sessions--enclosing-section
                         'bp/agent-session-row))
                   (session (bp/agent-sessions--session-for-id
                             (oref row value)))
                   (link (seq-find
                          (lambda (candidate)
                            (equal (plist-get candidate :url)
                                   (oref section value)))
                          (bp/agent-sessions--session-links session))))
         (cons (list (bp/agent-sessions--link-note-key
                      (plist-get link :url)))
               (or (plist-get link :label) (plist-get link :url)))))
      ('bp/agent-session-row
       (when-let* ((session (bp/agent-sessions--session-for-id
                             (oref section value)))
                   ;; No id and no buffer name means nothing durable to hang a
                   ;; note on (a registry entry whose buffer is already gone).
                   (keys (bp/agent-sessions--session-note-keys session)))
         (cons keys (bp/agent-sessions--session-short-label session)))))))

(defun bp/agent-sessions-note-newline ()
  "Insert a line break into the note being read in the minibuffer."
  (interactive)
  (insert "\n"))

(defvar bp/agent-sessions-note-minibuffer-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map minibuffer-local-map)
    (define-key map (kbd "C-j") #'bp/agent-sessions-note-newline)
    map)
  "Keymap used while reading a note with `bp/agent-sessions-edit-note'.
Notes are multi-line, but `minibuffer-local-map' binds \\`C-j' to
`exit-minibuffer' just like \\`RET', so it has to be rebound here; \\`RET'
still accepts the note.")

(defun bp/agent-sessions-edit-note (&optional remove)
  "Attach or edit a note on the repo, worktree, or session at point.
The note is free-form text shown under that thing's heading, foldable with TAB,
and persisted in `bp/agent-sessions-db-file'.  Insert a line break with
\\<bp/agent-sessions-note-minibuffer-map>\\[bp/agent-sessions-note-newline] and
accept with \\[exit-minibuffer]; an empty note removes it.  With a prefix
argument (REMOVE), delete the note without prompting — emptying a many-line
note by hand is tedious, since \\[kill-line] only kills the line point is on."
  (interactive "P")
  (pcase (bp/agent-sessions--note-target-at-point)
    (`(,keys . ,label)
     (let* ((existing (cdr (bp/agent-sessions--note-find keys)))
            (note (if remove
                      ""
                    (string-trim
                     (read-from-minibuffer
                      (format "Note for %s (C-j for newline): " label)
                      existing bp/agent-sessions-note-minibuffer-map)))))
       (bp/agent-sessions--note-set keys note)
       (bp/agent-sessions--refresh)
       (message (if (string-empty-p note)
                    "Note cleared for %s."
                  "Note saved for %s.")
                label)))
    (_ (message "Point is not on a repo, worktree, session, file, or link."))))

;;; Shared files ------------------------------------------------------------
;;
;; An agent that wants the user to read something runs `emacs-share file FILE
;; ["why"]' (`bin/emacs-share-file' remains a compatibility symlink); the
;; file then hangs under that agent's row in the dashboard, highlighted until
;; the user opens it.  It exists because a terminal is a bad inbox: "look at
;; /tmp/plan.md" scrolls away, and is only seen at all if you are already in
;; that buffer.
;;
;; This is persisted for the same reason notes and the manual order are — it is
;; something someone *chose* to put there, not observed session state — and it
;; obeys the same rules: loaded into a hash table once, written on change, and
;; never queried from the render path.
;;
;; Two design points worth keeping:
;;
;; - **A file is attached to the session's most durable identity, not to its
;;   terminal.**  It reuses `bp/agent-sessions--session-note-keys' verbatim: the
;;   agent's own session id when it has one, the buffer name otherwise, reading
;;   both and collapsing onto the first on write.  So renaming a terminal keeps
;;   its files, a file shared into a bare shell survives `claude' starting in
;;   it, and a session brought back with `R' comes back with its files.  The
;;   caller passes the *terminal* id (that is what the shell env has), and this
;;   layer resolves it — the same split the hook path makes.
;;
;; - **Re-sharing a path means "I changed it, look again", not "add it twice".**
;;   The row's `visited_at' is cleared so it lights up exactly as it did the
;;   first time, but its `shared_at' — and therefore its position — is left
;;   alone.  That follows the ordering rule the dashboard already lives by: a
;;   row may move when something meaningful changes, and a re-share is not that;
;;   a row jumping to the bottom of the list is the thing the user is trying to
;;   aim at moving out from under them.
;;
;; - **Every share snapshots the file before returning to the agent.**  The
;;   cache retains the two most recently submitted contents for that session
;;   and path, independent of Git.  This is deliberately done in the share
;;   path rather than when `D' is pressed: by then the live file may have been
;;   edited again, and would no longer be the version the agent handed over.

(defcustom bp/agent-sessions-file-snapshot-directory
  (expand-file-name ".cache/agent-sessions-file-snapshots/"
                    user-emacs-directory)
  "Directory containing the latest two submitted versions of shared files."
  :type 'directory)

(defvar bp/agent-sessions--shared-files nil
  "Hash table KEY -> list of shared-file plists, or nil before first load.
A KEY is (\"session\" ID), exactly as in `bp/agent-sessions--notes'.  Each
plist is (:path P :label L :shared-at TS :updated-at TS :visited-at TS-or-nil);
`:visited-at' nil is what makes a row render highlighted.  Backed by the
`shared_files' table.")

(defvar bp/agent-sessions--shared-paths nil
  "Hash set of `file-truename's of every shared file, or nil when it is stale.
Consulted by the focus hook on every buffer switch, so it has to be a set
lookup rather than a scan; `bp/agent-sessions--shared-paths-invalidate' drops
it whenever the file table changes.")

(defun bp/agent-sessions--shared-files-table ()
  "Return the shared-files table, loading it from the database once."
  (or bp/agent-sessions--shared-files
      (setq bp/agent-sessions--shared-files
            (let ((table (make-hash-table :test 'equal)))
              (pcase-dolist (`(,kind ,key ,path ,label ,shared ,updated ,visited)
                             (sqlite-select
                              (bp/agent-sessions--db)
                              "SELECT kind, key, path, label, shared_at,
                                      updated_at, visited_at
                                 FROM shared_files ORDER BY shared_at, path"))
                (let ((k (list kind key)))
                  (puthash k
                           (append (gethash k table)
                                   (list (list :path path :label label
                                               :shared-at shared
                                               :updated-at updated
                                               :visited-at visited)))
                           table)))
              table))))

(defun bp/agent-sessions--shared-paths-invalidate ()
  "Drop the cached truename set; it is rebuilt on the next lookup."
  (setq bp/agent-sessions--shared-paths nil))

(defun bp/agent-sessions--shared-path-p (truename)
  "Non-nil when TRUENAME is the true name of some shared file."
  (and truename
       (gethash truename
                (or bp/agent-sessions--shared-paths
                    (setq bp/agent-sessions--shared-paths
                          (let ((set (make-hash-table :test 'equal)))
                            (maphash
                             (lambda (_key files)
                               (dolist (f files)
                                 (puthash (file-truename (plist-get f :path))
                                          t set)))
                             (bp/agent-sessions--shared-files-table))
                            set))))))

(defun bp/agent-sessions--file-note-key (path)
  "Note key for the shared file at PATH.
Keyed on the path alone, not on path-plus-session: the note is about the file,
and the same file handed to two sessions is still one thing to say something
about."
  (list "file" path))

(defun bp/agent-sessions--files-scope (session)
  "Manual-order scope for SESSION's shared files.
Packed into the existing two scope columns as (\"files\" SESSION-KEY) rather
than needing a third: `kind' already separates it from every other scope, and
adding a column would mean a real migration, which `CREATE TABLE IF NOT
EXISTS' cannot do.  SESSION-KEY is the same durable identity the files
themselves are stored under, so an arrangement survives a terminal rename."
  (list "files" (or (cadr (car (bp/agent-sessions--session-note-keys session)))
                    "?")))

(defun bp/agent-sessions--session-files (session)
  "Files shared with SESSION, in display order.
First-shared first, with any manual order (`M-n' / `M-p') applied on top.
Every identity the session has had is read, not just the current one, so a
file attached before `claude' started in the terminal is not invisible in the
window between that and the next write (which collapses them)."
  (let ((table (bp/agent-sessions--shared-files-table))
        files)
    (dolist (key (bp/agent-sessions--session-note-keys session))
      ;; `append' shares the tail of its last argument, and `sort' is
      ;; destructive — without the copy this would reorder the stored list.
      (setq files (append files (copy-sequence (gethash key table)))))
    (bp/agent-sessions--apply-manual-order
     (bp/agent-sessions--files-scope session)
     (lambda (f) (plist-get f :path))
     (sort files (lambda (a b) (< (plist-get a :shared-at)
                                  (plist-get b :shared-at)))))))

(defun bp/agent-sessions--shared-file-write (key file)
  "Upsert FILE under KEY in the database."
  (sqlite-execute
   (bp/agent-sessions--db)
   "INSERT INTO shared_files
      (kind, key, path, label, shared_at, updated_at, visited_at)
    VALUES (?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(kind, key, path) DO UPDATE
      SET label      = excluded.label,
          updated_at = excluded.updated_at,
          visited_at = excluded.visited_at"
   (append key (list (plist-get file :path)
                     (plist-get file :label)
                     (plist-get file :shared-at)
                     (plist-get file :updated-at)
                     (plist-get file :visited-at)))))

(defun bp/agent-sessions--file-snapshot-row (keys path)
  "Return the first snapshot row for PATH owned by one of KEYS.
KEYS are ordered from most to least durable.  The result is a plist containing
`:key', `:previous-path', `:current-path', and `:updated-at'."
  (let ((db (bp/agent-sessions--db)))
    (seq-some
     (lambda (key)
       (when-let ((row
                   (car (sqlite-select
                         db
                         "SELECT previous_path, current_path, updated_at
                            FROM shared_file_snapshots
                           WHERE kind = ? AND key = ? AND path = ?"
                         (append key (list path))))))
         (list :key key
               :previous-path (nth 0 row)
               :current-path (nth 1 row)
               :updated-at (nth 2 row))))
     keys)))

(defun bp/agent-sessions--file-snapshots-collapse (keys)
  "Move snapshot rows stored under the less durable KEYS onto (car KEYS).
An existing row under the primary key wins, matching the shared-file collapse
rule.  Snapshot files themselves need not move because their paths are stored
in the database."
  (when-let ((primary (car keys)))
    (let ((db (bp/agent-sessions--db)))
      (dolist (key (cdr keys))
        (sqlite-execute
         db
         "INSERT OR IGNORE INTO shared_file_snapshots
            (kind, key, path, previous_path, current_path, updated_at)
          SELECT ?, ?, path, previous_path, current_path, updated_at
            FROM shared_file_snapshots WHERE kind = ? AND key = ?"
         (append primary key))
        (sqlite-execute
         db "DELETE FROM shared_file_snapshots WHERE kind = ? AND key = ?"
         key)))))

(defun bp/agent-sessions--file-snapshot-cache-directory (key path)
  "Return the private cache directory for the shared PATH owned by KEY."
  (expand-file-name
   (secure-hash 'sha256 (prin1-to-string (append key (list path))))
   bp/agent-sessions-file-snapshot-directory))

(defun bp/agent-sessions--snapshot-file (key path)
  "Save PATH as the current submitted version owned by KEY.
The formerly current copy becomes the previous copy.  Return the new snapshot
row plist.  A missing cache file is treated like a first share, since a cache
may be cleared independently of the database."
  (let* ((existing (bp/agent-sessions--file-snapshot-row (list key) path))
         (old-current (plist-get existing :current-path))
         (directory (bp/agent-sessions--file-snapshot-cache-directory key path))
         (basename (file-name-nondirectory path))
         (previous (expand-file-name (concat "previous--" basename) directory))
         (current (expand-file-name (concat "current--" basename) directory))
         incoming)
    (make-directory directory t)
    (set-file-modes directory #o700)
    (unwind-protect
        (progn
          ;; Copy the new contents before rotating the old pair.  If this
          ;; fails, the last successful submission remains intact.
          (setq incoming
                (make-temp-file (expand-file-name ".incoming-" directory)))
          (copy-file path incoming t)
          (set-file-modes incoming #o600)
          (if (and old-current (file-exists-p old-current))
              (progn
                (copy-file old-current previous t)
                (set-file-modes previous #o600))
            (setq previous nil))
          (rename-file incoming current t)
          (setq incoming nil)
          (let ((now (bp/agent-sessions--now)))
            (sqlite-execute
             (bp/agent-sessions--db)
             "INSERT INTO shared_file_snapshots
                (kind, key, path, previous_path, current_path, updated_at)
              VALUES (?, ?, ?, ?, ?, ?)
              ON CONFLICT(kind, key, path) DO UPDATE
                SET previous_path = excluded.previous_path,
                    current_path  = excluded.current_path,
                    updated_at    = excluded.updated_at"
             (append key (list path previous current now)))
            (list :key key :previous-path previous :current-path current
                  :updated-at now)))
      (when (and incoming (file-exists-p incoming))
        (delete-file incoming)))))

(defun bp/agent-sessions--files-collapse (keys)
  "Move file rows stored under the less durable KEYS onto (car KEYS).
The same tidying `bp/agent-sessions--note-set' does, and for the same reason: a
session that gains an agent session id should end up with one file list under
that id rather than one per identity it has held.  A path already present under
the primary key wins, so this can never undo a newer share."
  (let* ((table (bp/agent-sessions--shared-files-table))
         (primary (car keys))
         (db (bp/agent-sessions--db))
         (kept (gethash primary table))
         (moved nil))
    (bp/agent-sessions--file-snapshots-collapse keys)
    (dolist (key (cdr keys))
      (when-let ((files (gethash key table)))
        (dolist (f files)
          (unless (seq-find (lambda (k) (equal (plist-get k :path)
                                               (plist-get f :path)))
                            kept)
            (push f moved)))
        (remhash key table)
        (sqlite-execute db "DELETE FROM shared_files WHERE kind = ? AND key = ?"
                        key)))
    (when moved
      (setq moved (nreverse moved))
      (puthash primary (append kept moved) table)
      (dolist (f moved)
        (bp/agent-sessions--shared-file-write primary f)))))

(defun bp/agent-sessions--share-file (session path label)
  "Attach PATH to SESSION with LABEL, unvisited.  Return the file plist.
Re-sharing a path already attached updates it in place rather than adding a
second row: the label is refreshed (an empty LABEL keeps the old one, since an
agent re-sharing may have nothing to add beyond \"changed\"), `:visited-at' is
cleared so the row highlights again, and `:shared-at' — the sort key — is left
at the original share so the row does not move."
  (let ((keys (bp/agent-sessions--session-note-keys session))
        (path (expand-file-name path))
        (now (bp/agent-sessions--now)))
    (unless keys
      (error "Session has no durable identity to attach a file to"))
    (bp/agent-sessions--files-collapse keys)
    (bp/agent-sessions--snapshot-file (car keys) path)
    (let* ((table (bp/agent-sessions--shared-files-table))
           (primary (car keys))
           (files (gethash primary table))
           (existing (seq-find (lambda (f) (equal (plist-get f :path) path))
                               files))
           (file (list :path path
                       :label (or (and label (not (string-empty-p label)) label)
                                  (and existing (plist-get existing :label)))
                       :shared-at (or (and existing (plist-get existing :shared-at))
                                      now)
                       :updated-at now
                       :visited-at nil)))
      (puthash primary
               (if existing
                   (mapcar (lambda (f) (if (eq f existing) file f)) files)
                 (append files (list file)))
               table)
      (bp/agent-sessions--shared-file-write primary file)
      (bp/agent-sessions--shared-paths-invalidate)
      file)))

(defun bp/agent-sessions--detach-file (session path)
  "Remove PATH from SESSION's shared files; return non-nil if it was attached.
The file on disk is never touched — this drops the pointer to it, nothing more."
  (let ((table (bp/agent-sessions--shared-files-table))
        (db (bp/agent-sessions--db))
        (removed nil))
    (dolist (key (bp/agent-sessions--session-note-keys session))
      (let ((files (gethash key table)))
        (when (seq-find (lambda (f) (equal (plist-get f :path) path)) files)
          (puthash key
                   (seq-remove (lambda (f) (equal (plist-get f :path) path))
                               files)
                   table)
          (sqlite-execute db "DELETE FROM shared_files
                               WHERE kind = ? AND key = ? AND path = ?"
                          (append key (list path)))
          (setq removed t))))
    (when removed (bp/agent-sessions--shared-paths-invalidate))
    removed))

(defun bp/agent-sessions--set-visited (match-fn visitedp)
  "Set the visited state of every shared file MATCH-FN accepts.
Returns non-nil when something actually changed, so callers can skip a render.
Matching is by predicate rather than by (session, path) because the two callers
want different tests — a dashboard command knows the exact stored path, while
the focus hook only knows the true name of a buffer's file — and because a file
shared with two sessions should stop nagging from both once it has been read."
  (let ((db (bp/agent-sessions--db))
        (stamp (and visitedp (bp/agent-sessions--now)))
        (changed nil))
    (maphash
     (lambda (key files)
       (dolist (f files)
         (when (and (funcall match-fn f)
                    (not (eq (null (plist-get f :visited-at)) (null stamp))))
           (plist-put f :visited-at stamp)
           (sqlite-execute db "UPDATE shared_files SET visited_at = ?
                                WHERE kind = ? AND key = ? AND path = ?"
                           (list stamp (car key) (cadr key)
                                 (plist-get f :path)))
           (setq changed t))))
     (bp/agent-sessions--shared-files-table))
    changed))

(defun bp/agent-sessions--revert-shared-file-buffer (path)
  "Refresh an unmodified buffer already visiting PATH from disk.
Do not create a buffer for PATH, and never replace unsaved buffer changes."
  (when-let ((buffer (find-buffer-visiting path)))
    (with-current-buffer buffer
      (unless (buffer-modified-p)
        (revert-buffer t t)))))

;;;###autoload
(defun bp/agent-sessions-share-file (session-id path &optional label
                                                agent-session-id)
  "Attach PATH to the agent session running in terminal SESSION-ID.
The `emacs-share file' entry point calls over emacsclient, so SESSION-ID is
the terminal's EMACS_AGENT_SESSION_ID — the id the shell has.  When
AGENT-SESSION-ID is supplied, it is the agent's durable thread identity and
takes precedence because a shared daemon can retain another terminal's id.
If an unmodified buffer already visits PATH, refresh it from disk; modified
buffers are left alone so sharing can never discard unsaved work.
Returns a string for the caller to print: emacsclient is the agent's only
channel back, so a failure has to be reported in the value, not signalled."
  (let ((session (bp/agent-sessions--session-for-share
                  session-id agent-session-id)))
    (cond
     ((null session)
      (if (and agent-session-id (not (string-empty-p agent-session-id)))
          (format "No Emacs agent session registered for agent id %s"
                  agent-session-id)
        (format "No Emacs terminal registered for session id %s" session-id)))
     ((not (file-exists-p path))
      (format "No such file: %s" path))
     (t
      (bp/agent-sessions--revert-shared-file-buffer path)
      (bp/agent-sessions--share-file session path label)
      (bp/agent-sessions--refresh-if-visible)
      (format "Shared %s" (abbreviate-file-name (expand-file-name path)))))))

;;; Shared links ------------------------------------------------------------

(defconst bp/agent-sessions--link-kind-labels
  '(("linear" . "Linear")
    ("pr" . "PR"))
  "Supported external link kinds and their dashboard labels.")

(defvar bp/agent-sessions--shared-links nil
  "Hash table KEY -> list of shared-link plists, or nil before first load.
A KEY is the same durable session identity used by notes and shared files.
Each plist is (:kind K :url U :label L :shared-at TS :updated-at TS
:visited-at TS-or-nil).  A session can have multiple links of each kind;
the data is backed by the `shared_links' table.")

(defun bp/agent-sessions--shared-links-table ()
  "Return the shared-links table, loading it from the database once."
  (or bp/agent-sessions--shared-links
      (setq bp/agent-sessions--shared-links
            (let ((table (make-hash-table :test 'equal)))
              (pcase-dolist
                  (`(,owner-kind ,owner-key ,link-kind ,url ,label
                                  ,shared ,updated ,visited)
                   (sqlite-select
                    (bp/agent-sessions--db)
                    "SELECT owner_kind, owner_key, link_kind, url, label,
                            shared_at, updated_at, visited_at
                       FROM shared_links ORDER BY shared_at, link_kind"))
                (let ((key (list owner-kind owner-key)))
                  (puthash key
                           (append (gethash key table)
                                   (list (list :kind link-kind :url url
                                               :label label :shared-at shared
                                               :updated-at updated
                                               :visited-at visited)))
                           table)))
              table))))

(defun bp/agent-sessions--link-note-key (url)
  "Note key for the shared external link at URL."
  (list "link" url))

(defun bp/agent-sessions--links-scope (session)
  "Manual-order scope for SESSION's shared external links."
  (list "links" (or (cadr (car (bp/agent-sessions--session-note-keys session)))
                    "?")))

(defun bp/agent-sessions--session-links (session)
  "External links shared with SESSION, in display order."
  (let ((table (bp/agent-sessions--shared-links-table))
        links)
    (dolist (key (bp/agent-sessions--session-note-keys session))
      (setq links (append links (copy-sequence (gethash key table)))))
    (bp/agent-sessions--apply-manual-order
     (bp/agent-sessions--links-scope session)
     (lambda (link) (plist-get link :url))
     (sort links (lambda (a b) (< (plist-get a :shared-at)
                                  (plist-get b :shared-at)))))))

(defun bp/agent-sessions--shared-link-write (key link)
  "Upsert LINK under durable session identity KEY in the database."
  (sqlite-execute
   (bp/agent-sessions--db)
   "INSERT INTO shared_links
      (owner_kind, owner_key, link_kind, url, label,
       shared_at, updated_at, visited_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(owner_kind, owner_key, url) DO UPDATE
      SET link_kind  = excluded.link_kind,
          label      = excluded.label,
          updated_at = excluded.updated_at,
          visited_at = excluded.visited_at"
   (append key (list (plist-get link :kind)
                     (plist-get link :url)
                     (plist-get link :label)
                     (plist-get link :shared-at)
                     (plist-get link :updated-at)
                     (plist-get link :visited-at)))))

(defun bp/agent-sessions--links-collapse (keys)
  "Move links stored under the less durable KEYS onto (car KEYS)."
  (let* ((table (bp/agent-sessions--shared-links-table))
         (primary (car keys))
         (db (bp/agent-sessions--db))
         (kept (gethash primary table))
         moved)
    (dolist (key (cdr keys))
      (when-let ((links (gethash key table)))
        (dolist (link links)
          (unless (seq-find
                   (lambda (candidate)
                     (equal (plist-get candidate :url)
                            (plist-get link :url)))
                   (append kept moved))
            (push link moved)))
        (remhash key table)
        (sqlite-execute
         db "DELETE FROM shared_links WHERE owner_kind = ? AND owner_key = ?"
         key)))
    (when moved
      (setq moved (nreverse moved))
      (puthash primary (append kept moved) table)
      (dolist (link moved)
        (bp/agent-sessions--shared-link-write primary link)))))

(defun bp/agent-sessions--share-link (session kind url label)
  "Attach KIND link URL with LABEL to SESSION.
An identical registration is a no-op, including preserving its visited state.
Changing the label updates that URL and marks it unvisited, while preserving
its original display position."
  (let ((keys (bp/agent-sessions--session-note-keys session))
        (now (bp/agent-sessions--now)))
    (unless keys
      (error "Session has no durable identity to attach a link to"))
    (bp/agent-sessions--links-collapse keys)
    (let* ((table (bp/agent-sessions--shared-links-table))
           (primary (car keys))
           (links (gethash primary table))
           (existing (seq-find
                      (lambda (link) (equal (plist-get link :url) url))
                      links))
           (label (or (and label (not (string-empty-p label)) label)
                      (and existing (plist-get existing :label)))))
      (if (and existing
               (equal kind (plist-get existing :kind))
               (equal label (plist-get existing :label)))
          existing
        (let ((link (list :kind kind :url url :label label
                          :shared-at (or (and existing
                                               (plist-get existing :shared-at))
                                         now)
                          :updated-at now
                          :visited-at nil)))
          (puthash primary
                   (if existing
                       (mapcar (lambda (candidate)
                                 (if (eq candidate existing) link candidate))
                               links)
                     (append links (list link)))
                   table)
          (bp/agent-sessions--shared-link-write primary link)
          link)))))

(defun bp/agent-sessions--detach-link (session url)
  "Remove the link at URL from SESSION; return non-nil if attached."
  (let ((table (bp/agent-sessions--shared-links-table))
        (db (bp/agent-sessions--db))
        removed)
    (dolist (key (bp/agent-sessions--session-note-keys session))
      (let ((links (gethash key table)))
        (when (seq-find (lambda (link) (equal (plist-get link :url) url))
                        links)
          (puthash key
                   (seq-remove
                    (lambda (link) (equal (plist-get link :url) url))
                    links)
                   table)
          (sqlite-execute
           db
           "DELETE FROM shared_links
             WHERE owner_kind = ? AND owner_key = ? AND url = ?"
           (append key (list url)))
          (setq removed t))))
    removed))

(defun bp/agent-sessions--set-link-visited (match-fn visitedp)
  "Set visited state of every shared link accepted by MATCH-FN."
  (let ((db (bp/agent-sessions--db))
        (stamp (and visitedp (bp/agent-sessions--now)))
        changed)
    (maphash
     (lambda (key links)
       (dolist (link links)
         (when (and (funcall match-fn link)
                    (not (eq (null (plist-get link :visited-at))
                             (null stamp))))
           (plist-put link :visited-at stamp)
           (sqlite-execute
            db
            "UPDATE shared_links SET visited_at = ?
              WHERE owner_kind = ? AND owner_key = ? AND url = ?"
            (list stamp (car key) (cadr key) (plist-get link :url)))
           (setq changed t))))
     (bp/agent-sessions--shared-links-table))
    changed))

;;;###autoload
(defun bp/agent-sessions-share-link (session-id kind url &optional label
                                                agent-session-id)
  "Attach a typed external link to the session in terminal SESSION-ID.
KIND is `linear' or `pr'; URL must be HTTP(S).  Re-registering the same value
is idempotent.  AGENT-SESSION-ID, when supplied, is the durable agent thread
identity and takes precedence over SESSION-ID.  Returns a printable status
string for `emacs-share link'."
  (let ((session (bp/agent-sessions--session-for-share
                  session-id agent-session-id)))
    (cond
     ((null session)
      (if (and agent-session-id (not (string-empty-p agent-session-id)))
          (format "No Emacs agent session registered for agent id %s"
                  agent-session-id)
        (format "No Emacs terminal registered for session id %s" session-id)))
     ((not (assoc kind bp/agent-sessions--link-kind-labels))
      (format "Unknown link kind `%s'; expected linear or pr" kind))
     ((not (string-match-p "\\`https?://[^[:space:]]+\\'" url))
      (format "Invalid link URL: %s" url))
     (t
      (bp/agent-sessions--share-link session kind url label)
      (bp/agent-sessions--refresh-if-visible)
      (format "Linked %s: %s" kind url)))))

(defun bp/agent-sessions--file-at-point ()
  "Return (SESSION PATH FILE) for the shared-file row at point, or nil.
Point may be on the row itself or inside a note rendered under it, which
resolves to the file the note is about — the same courtesy
`bp/agent-sessions--note-target-at-point' extends."
  (let ((section (magit-current-section)))
    (when (and section (eq (oref section type) 'bp/agent-session-note))
      (setq section (oref section parent)))
    (when (and section (eq (oref section type) 'bp/agent-session-file))
      (let* ((path (oref section value))
             (row (bp/agent-sessions--enclosing-section 'bp/agent-session-row))
             (session (and row (bp/agent-sessions--session-for-id
                                (oref row value)))))
        (when session
          (list session path
                (seq-find (lambda (f) (equal (plist-get f :path) path))
                          (bp/agent-sessions--session-files session))))))))

(defun bp/agent-sessions--link-at-point ()
  "Return (SESSION KIND LINK) for the shared-link row at point, or nil.
Point may be on the link row or inside its note."
  (let ((section (magit-current-section)))
    (when (and section (eq (oref section type) 'bp/agent-session-note))
      (setq section (oref section parent)))
    (when (and section (eq (oref section type) 'bp/agent-session-link))
      (let* ((url (oref section value))
             (row (bp/agent-sessions--enclosing-section 'bp/agent-session-row))
             (session (and row (bp/agent-sessions--session-for-id
                                (oref row value)))))
        (when session
          (list session url
                (seq-find (lambda (link)
                            (equal (plist-get link :url) url))
                          (bp/agent-sessions--session-links session))))))))

(defun bp/agent-sessions--open-link-at-point ()
  "Open the shared external link at point and clear its highlight."
  (pcase (bp/agent-sessions--link-at-point)
    (`(,_session ,_kind ,link)
     (let ((url (plist-get link :url)))
       (when (bp/agent-sessions--set-link-visited
              (lambda (candidate)
                (equal (plist-get candidate :url) url))
              t)
         (bp/agent-sessions--refresh-if-visible))
       (browse-url url)))))

(defun bp/agent-sessions--open-file-at-point (display-fn)
  "Open the shared file at point with DISPLAY-FN, clearing its highlight.
The refresh happens before DISPLAY-FN runs so the dashboard's point
restoration is not competing with whatever DISPLAY-FN does to the windows."
  (pcase (bp/agent-sessions--file-at-point)
    (`(,_session ,path ,_file)
     (if (not (file-exists-p path))
         (message "File no longer exists: %s" (abbreviate-file-name path))
       (when (bp/agent-sessions--set-visited
              (lambda (f) (equal (plist-get f :path) path)) t)
         (bp/agent-sessions--refresh-if-visible))
       (funcall display-fn (find-file-noselect path))))))

(defun bp/agent-sessions-show-file-diff ()
  "Show the latest committed diff for the shared file at point, then mark it read.
The Magit revision buffer is limited to that file.  If the file is outside a
Git repository or has no committed history, leave its unread state unchanged."
  (interactive)
  (pcase (bp/agent-sessions--file-at-point)
    (`(,_session ,path ,_file)
     (let* ((root (magit-toplevel (file-name-directory path)))
            (relative (and root (file-relative-name path root)))
            (default-directory (or root default-directory))
            (commit (and root
                         (magit-git-string "log" "-1" "--format=%H"
                                           "--follow" "--" relative))))
       (unless root
         (user-error "File is not in a Git repository"))
       (unless commit
         (user-error "File has no committed diff"))
       (magit-show-commit commit (car (magit-show-commit--arguments))
                          (list relative))
       (when (bp/agent-sessions--set-visited
              (lambda (file) (equal (plist-get file :path) path)) t)
         (bp/agent-sessions--refresh-if-visible))))
    (_ (message "No shared file at point."))))

(defun bp/agent-sessions-show-file-submission-diff ()
  "Show the diff between the latest two submissions of the file at point.
Unlike `bp/agent-sessions-show-file-diff', this compares cached copies made at
share time and therefore works without Git and across uncommitted edits.  If
the file predates snapshot support, save its current contents as the first
snapshot instead.  Mark the file read only after a diff is successfully
produced."
  (interactive)
  (pcase (bp/agent-sessions--file-at-point)
    (`(,session ,path ,_file)
     (let* ((keys (bp/agent-sessions--session-note-keys session))
            (snapshot (bp/agent-sessions--file-snapshot-row keys path)))
       (if (not snapshot)
           (progn
             (unless (file-exists-p path)
               (user-error "File no longer exists: %s"
                           (abbreviate-file-name path)))
             (bp/agent-sessions--snapshot-file (car keys) path)
             (message "Saved current file as its first submitted snapshot"))
         (let ((previous (plist-get snapshot :previous-path))
               (current (plist-get snapshot :current-path)))
           (unless previous
             (user-error "File has only one submitted version"))
           (unless (and (file-exists-p previous) (file-exists-p current))
             (user-error "Submitted-version cache is incomplete"))
           (let* ((name (file-name-nondirectory path))
                  (buffer-name (format "*Agent submission diff: %s*" name))
                  (buffer (diff-no-select previous current "-u" t
                                          (get-buffer-create buffer-name))))
             (with-current-buffer buffer
               (setq-local header-line-format
                           (format "Submitted versions of %s"
                                   (abbreviate-file-name path))))
             (when (bp/agent-sessions--set-visited
                    (lambda (file) (equal (plist-get file :path) path)) t)
               (bp/agent-sessions--refresh-if-visible))
             (pop-to-buffer buffer))))))
    (_ (message "No shared file at point."))))

(defface bp/agent-session-file-unvisited
  '((t :inherit bp/agent-session-needs-attention))
  "Face for a shared file not opened since the agent last shared it.
Inherits the needs-attention face deliberately: an unread file and a waiting
session are the same claim on the user's attention, and the dashboard should
not make them learn two highlights for it.")

(defface bp/agent-session-file
  '((t :inherit default))
  "Face for a shared file the user has already opened.")

(defface bp/agent-session-link-unvisited
  '((t :inherit bp/agent-session-needs-attention))
  "Face for an external link not opened since the agent registered it.")

(defface bp/agent-session-link
  '((t :inherit link))
  "Face for an external link the user has already opened.")

(defun bp/agent-sessions--insert-link (link indent)
  "Insert a row for shared external LINK, indented by INDENT."
  (let* ((kind (plist-get link :kind))
         (url (plist-get link :url))
         (unvisited (null (plist-get link :visited-at)))
         (kind-label (or (cdr (assoc kind bp/agent-sessions--link-kind-labels))
                         kind)))
    (push (cons (line-beginning-position)
                (if unvisited 'needs-attention 'idle))
          bp/agent-sessions--row-status)
    (magit-insert-section (bp/agent-session-link url)
      (magit-insert-heading
       (propertize
        (concat indent (if unvisited "● " "  ")
                (format "%-28s %s\n" kind-label
                        (or (plist-get link :label) url)))
        'font-lock-face (if unvisited
                            'bp/agent-session-link-unvisited
                          'bp/agent-session-link)))
      (bp/agent-sessions--insert-note
       (list (bp/agent-sessions--link-note-key url))
       (concat indent "    ")))))

(defun bp/agent-sessions--insert-links (session indent)
  "Insert every external link shared with SESSION, indented by INDENT."
  (dolist (link (bp/agent-sessions--session-links session))
    (bp/agent-sessions--insert-link link indent)))

(defun bp/agent-sessions--insert-file (file indent)
  "Insert a row for shared FILE, indented by INDENT.
INDENT puts the row at the same depth as the session's note — one level in
from the session row — so it reads as hanging off that session rather than as
another row beside it.  Its section value is the path:
stable across renders, unique within a session, and disambiguated from the
same path under another session by magit's parent chain."
  (let* ((path (plist-get file :path))
         (unvisited (null (plist-get file :visited-at)))
         ;; One stat per file per render.  Affordable at the scale this holds
         ;; (a handful of paths, all local) and worth it: a file an agent
         ;; wrote to /tmp and the reaper has since removed should say so
         ;; rather than fail on RET.
         (missing (not (file-exists-p path))))
    ;; Record what this row *shows*, for `N'/`P' — see the docstring of
    ;; `bp/agent-sessions--row-status'.  An unopened file is reachable by the
    ;; attention keys for the same reason it is highlighted like one.
    (push (cons (line-beginning-position)
                (if unvisited 'needs-attention 'idle))
          bp/agent-sessions--row-status)
    (magit-insert-section (bp/agent-session-file path)
      (magit-insert-heading
       (propertize
        (concat indent (if unvisited "● " "  ")
                (format "%-28s %s"
                        (file-name-nondirectory (directory-file-name path))
                        (or (plist-get file :label)
                            (abbreviate-file-name path)))
                (if missing "  (missing)" "")
                "\n")
        'font-lock-face (if unvisited
                            'bp/agent-session-file-unvisited
                          'bp/agent-session-file)))
      (bp/agent-sessions--insert-note
       (list (bp/agent-sessions--file-note-key path))
       (concat indent "    ")))))

(defun bp/agent-sessions--insert-files (session indent)
  "Insert a row for every file shared with SESSION, indented by INDENT."
  (dolist (file (bp/agent-sessions--session-files session))
    (bp/agent-sessions--insert-file file indent)))

(defun bp/agent-sessions--build-tree (entries)
  "Group live ENTRIES into a list of repo plists for rendering.
Each element is (:name NAME :root ROOT :worktrees (WORKTREE ...)).
When `bp/agent-sessions-sort-by-activity' is set, every level is ordered
most-recently-active first; otherwise the stable order of
`bp/agent-sessions--sort-tree-stable' is used."
  (let ((repos
         (mapcar
          (lambda (rg)
            (let* ((rentries (cdr rg))
                   (session (plist-get (car rentries) :session))
                   (root (plist-get session :repo-root))
                   (session-groups
                    (seq-group-by
                     (lambda (e) (bp/agent-sessions--canonical-path
                                  (plist-get (plist-get e :session) :worktree-path)))
                     rentries)))
              (list :name (or (plist-get session :repo) "?")
                    :root root
                    :worktrees (bp/agent-sessions--worktrees-for root session-groups))))
          (seq-group-by
           (lambda (e) (bp/agent-sessions--canonical-path
                        (plist-get (plist-get e :session) :repo-root)))
           entries))))
    (if bp/agent-sessions-sort-by-activity
        (bp/agent-sessions--sort-tree repos)
      (bp/agent-sessions--sort-tree-stable repos))))

(defun bp/agent-sessions--insert-worktree (wt)
  (let ((entries (plist-get wt :entries)))
    (magit-insert-section (bp/agent-session-worktree
                           (list :label (plist-get wt :label)
                                 :path (plist-get wt :path)))
      (magit-insert-heading (format "%s%s"
                                    (if bp/agent-sessions-group-by-folder "    " "  ")
                                    (plist-get wt :label)))
      (bp/agent-sessions--insert-note
       (list (bp/agent-sessions--worktree-note-key wt))
       (if bp/agent-sessions-group-by-folder "      " "    "))
      (bp/agent-sessions--insert-entries entries))))

(defun bp/agent-sessions--insert-repo (repo)
  (magit-insert-section (bp/agent-session-repo
                         (list :name (plist-get repo :name)
                               :root (plist-get repo :root)))
    (magit-insert-heading
      (propertize (concat (if bp/agent-sessions-group-by-folder "  " "")
                          (plist-get repo :name)) 'face 'bold))
    (bp/agent-sessions--insert-note
     (list (bp/agent-sessions--repo-note-key repo))
     (if bp/agent-sessions-group-by-folder "    " "  "))
    (dolist (wt (plist-get repo :worktrees))
      (bp/agent-sessions--insert-worktree wt))
    (insert "\n")))

(defun bp/agent-sessions--folder-entries (folder entries)
  "Return live ENTRIES assigned to FOLDER, including No folder."
  (seq-filter (lambda (entry)
                (equal (plist-get folder :id)
                       (bp/agent-sessions--folder-for-session
                        (plist-get entry :session))))
              entries))

(defun bp/agent-sessions--insert-folder (folder entries)
  "Render FOLDER containing live ENTRIES across repositories."
  (let* ((id (plist-get folder :id))
         (members (bp/agent-sessions--folder-entries folder entries))
         ;; Empty worktrees belong to the repo view, where `+' can target them.
         (bp/agent-sessions-show-all-worktrees nil))
    (magit-insert-section (bp/agent-session-folder id)
      (magit-insert-heading
        (propertize (format "%s (%d)"
                            (or (plist-get folder :name) "No folder")
                            (length members))
                    'face 'bold))
      (dolist (repo (bp/agent-sessions--build-tree members))
        (bp/agent-sessions--insert-repo repo))
      (insert "\n"))))

(defun bp/agent-sessions--refresh ()
  (interactive)
  (bp/agent-sessions--load-folders)
  (let* ((inhibit-read-only t)
         (win (get-buffer-window (current-buffer)))
         (saved-point (if win (window-point win) (point)))
         (section (save-excursion
                    (goto-char saved-point)
                    (magit-current-section)))
         ;; Remember the section at point by its stable identity, not by
         ;; absolute position: erase-buffer + rebuild (and sorting) shift and
         ;; reorder everything, so a char offset is meaningless.
         (ident (and section (magit-section-ident section)))
         ;; Keep point's position within that section as well.  Restoring only
         ;; IDENT puts point at the section's first column on every hook-driven
         ;; refresh, undoing ordinary horizontal motion such as `C-f'/`C-b'.
         (line-offset
          (and section
               (save-excursion
                 (goto-char saved-point)
                 (count-lines (oref section start) (line-beginning-position)))))
         (column (save-excursion
                   (goto-char saved-point)
                   (current-column)))
         (wstart (and win (window-start win))))
    (erase-buffer)
    (setq bp/agent-sessions--row-status nil)
    (magit-insert-section (bp/agent-sessions-root)
      (let ((entries (bp/agent-sessions--live-entries)))
        (if bp/agent-sessions-group-by-folder
            (progn
              (dolist (folder (sort (copy-sequence bp/agent-sessions--folders)
                                    (lambda (a b)
                                      (string-lessp (downcase (plist-get a :name))
                                                    (downcase (plist-get b :name))))))
                (bp/agent-sessions--insert-folder folder entries))
              (bp/agent-sessions--insert-folder
               (list :id nil :name "No folder") entries))
          (let ((repos (bp/agent-sessions--build-tree entries)))
            (if (null repos)
                (insert "No active sessions.\n")
              (dolist (repo repos)
                (bp/agent-sessions--insert-repo repo)))))))
    (setq bp/agent-sessions--row-status (nreverse bp/agent-sessions--row-status))
    ;; Freshly inserted sections carry the visibility magit cached for them
    ;; (e.g. a note folded with TAB) in their `hidden' slot, but nothing has
    ;; applied it to the new text yet; this pass does, exactly as
    ;; `magit-refresh-buffer' does after its own inserters run.  Rebind the
    ;; cache off so re-showing doesn't record the state it is restoring.
    (let ((magit-section-cache-visibility nil))
      (magit-section-show magit-root-section))
    (let ((target (and ident (magit-get-section ident))))
      (if (not target)
          (goto-char (point-min))
        (let ((start (oref target start))
              (end (oref target end)))
          (goto-char start)
          (forward-line line-offset)
          ;; The section may have become shorter during the refresh.  In that
          ;; case use its last line instead of wandering into the next section.
          (when (>= (point) end)
            (goto-char (max start (1- end)))
            (beginning-of-line))
          (move-to-column column))))
    (when win
      (set-window-point win (point))
      (when wstart
        (set-window-start win (min wstart (point-max)) t)))))

(defun bp/agent-sessions--reread-repo-info ()
  "Re-read repo/branch info from disk for every live session buffer.
The per-buffer `bp/agent-sessions--repo-info-cache' is keyed only on the
buffer's directory, so it never notices a branch checkout in the same
directory; and a real agent session's `:worktree' label is frozen at its first
hook.  Both go stale when the branch changes.  Clear the per-buffer caches and
refresh each registered session's repo/worktree fields so `g' reflects the
current branch."
  (dolist (buf (buffer-list))
    (when (buffer-local-value 'bp/agent-sessions--repo-info-cache buf)
      (with-current-buffer buf
        (setq bp/agent-sessions--repo-info-cache nil))))
  (maphash
   (lambda (id session)
     (let ((buf (plist-get session :buffer)))
       (when (buffer-live-p buf)
         (let ((info (bp/agent-sessions--buffer-repo-info buf)))
           ;; Only overwrite when the buffer is still in a repo; a session that
           ;; has cd'd out keeps its last-known labels rather than going blank.
           (when (plist-get info :repo-root)
             (puthash id
                      (plist-put
                       (plist-put
                        (plist-put
                         (plist-put session :repo (plist-get info :repo))
                         :repo-root (plist-get info :repo-root))
                        :worktree (plist-get info :worktree))
                       :worktree-path (plist-get info :worktree-path))
                      bp/agent-sessions))))))
   bp/agent-sessions))

(defun bp/agent-sessions-refresh ()
  "Refresh the dashboard, re-reading git worktrees and branches from disk.
Unlike the internal re-render used by hooks and the sort toggle, this
invalidates the worktree cache and re-reads each session's repo/branch info."
  (interactive)
  (clrhash bp/agent-sessions--worktrees-cache)
  (bp/agent-sessions--reread-repo-info)
  (bp/agent-sessions--refresh))

(defun bp/agent-sessions--refresh-if-visible ()
  (let ((buf (get-buffer bp/agent-sessions-buffer-name)))
    (when buf
      (with-current-buffer buf
        (bp/agent-sessions--refresh)))))

(defun bp/agent-sessions--session-at-point ()
  (let ((section (magit-current-section)))
    (and section (eq (oref section type) 'bp/agent-session-row)
         (bp/agent-sessions--session-for-id (oref section value)))))

(defun bp/agent-sessions--switch-project-read-command ()
  "Read one key from the `project-switch-commands' menu and return its command.
Returns `ignore' for anything unrecognised, so the menu closes instead of
re-prompting.  Built from project.el's own pieces (`project-prefix-map',
`project-switch-commands', `project--menu-prompt') so a user's customisation
of the dispatch menu still applies; the deprecated (KEY COMMAND LABEL) row
format is normalised the same way `project--switch-project-command' does."
  (let* ((menu (mapcar (lambda (row) (if (characterp (car row)) (reverse row) row))
                       project-switch-commands))
         (map (let ((temp (make-sparse-keymap)))
                (set-keymap-parent temp project-prefix-map)
                (dolist (row menu temp)
                  (when-let ((cmd (nth 0 row))
                             (keychar (nth 2 row)))
                    (define-key temp (vector keychar) cmd)))))
         (choice (let ((overriding-local-map map))
                   (read-key-sequence (concat "Choose: " (project--menu-prompt)))))
         (command (lookup-key map choice)))
    (message nil)
    (if (and (commandp command)
             (or project-switch-use-entire-map (assq command menu)))
        command
      #'ignore)))

(defun bp/agent-sessions--switch-project (dir)
  "`project-switch-project' in DIR, but dismissed by any unrecognised key.
`project--switch-project-command' loops until it reads a key it knows, so the
dispatch menu behaves like a mode you have to escape from.  Here RET on a
heading is a glance at what's available, so a stray key should just close the
menu rather than trap you in it.  The override is scoped to this call — the
looping behaviour everywhere else in Emacs is left alone."
  (cl-letf (((symbol-function 'project--switch-project-command)
             #'bp/agent-sessions--switch-project-read-command))
    (project-switch-project dir)))

(defun bp/agent-sessions-jump ()
  "Act on the thing at point.
On a session row, pop to its terminal.  Open a shared file or external link
and clear its highlight.  On a worktree or repo heading, open project.el's
dispatch menu in that directory (see `bp/agent-sessions--switch-project')."
  (interactive)
  (cond
   ((bp/agent-sessions--link-at-point)
    (bp/agent-sessions--open-link-at-point))
   ((bp/agent-sessions--file-at-point)
    (bp/agent-sessions--open-file-at-point #'pop-to-buffer))
   (t
    (let ((section (magit-current-section)))
      (pcase (and section (oref section type))
        ('bp/agent-session-row
         (let* ((session (bp/agent-sessions--session-for-id (oref section value)))
                (buf (and session (plist-get session :buffer))))
           (if (buffer-live-p buf)
               (pop-to-buffer buf)
             (message "No session at point."))))
        ((or 'bp/agent-session-worktree 'bp/agent-session-repo)
         (let* ((value (oref section value))
                (dir (or (plist-get value :path) (plist-get value :root))))
           (if (and dir (file-directory-p dir))
               (bp/agent-sessions--switch-project dir)
             (message "No worktree directory at point."))))
        (_ (message "Nothing to do here.")))))))

(defun bp/agent-sessions-display ()
  "Display or open the session attachment at point without selecting a terminal.
Files and sessions use another window; external links open in the browser."
  (interactive)
  ;; inhibit-same-window: never reuse/replace the dashboard's own window.
  (cond
   ((bp/agent-sessions--link-at-point)
    (bp/agent-sessions--open-link-at-point))
   ((bp/agent-sessions--file-at-point)
    (bp/agent-sessions--open-file-at-point
     (lambda (buf) (display-buffer buf '(nil (inhibit-same-window . t))))))
   (t
    (let* ((session (bp/agent-sessions--session-at-point))
           (buf (and session (plist-get session :buffer))))
      (if (buffer-live-p buf)
          (display-buffer buf '(nil (inhibit-same-window . t)))
        (message "No session at point."))))))

(defun bp/agent-sessions-display-or-browse ()
  "Display the thing at point, browsing links and shared HTML files.
For every other shared file or dashboard row, behave exactly like
`bp/agent-sessions-display'."
  (interactive)
  (if (bp/agent-sessions--link-at-point)
      (bp/agent-sessions--open-link-at-point)
    (pcase (bp/agent-sessions--file-at-point)
      (`(,_session ,path ,_file)
       (if (not (string-equal (downcase (or (file-name-extension path) ""))
                              "html"))
           (bp/agent-sessions-display)
         (if (not (file-exists-p path))
             (message "File no longer exists: %s" (abbreviate-file-name path))
           (when (bp/agent-sessions--set-visited
                  (lambda (file) (equal (plist-get file :path) path)) t)
             (bp/agent-sessions--refresh-if-visible))
           (browse-url-of-file path))))
      (_ (bp/agent-sessions-display)))))

(defun bp/agent-sessions-copy-attachment ()
  "Copy the shared file path or external URL at point to the kill ring."
  (interactive)
  (let ((value (or (when-let ((link (bp/agent-sessions--link-at-point)))
                     (plist-get (nth 2 link) :url))
                   (nth 1 (bp/agent-sessions--file-at-point)))))
    (if value
        (progn
          (kill-new value)
          (message "Copied %s" value))
      (message "No shared file or link at point."))))

(defun bp/agent-sessions--row-locations ()
  "Return (POSITION . ID) for each session row, in buffer order."
  (let (rows last-start)
    (save-excursion
      (goto-char (point-min))
      (while (not (eobp))
        (let ((section (magit-current-section)))
          (when (and section
                     (eq (oref section type) 'bp/agent-session-row)
                     (/= (oref section start) (or last-start -1)))
            (setq last-start (oref section start))
            (push (cons last-start (oref section value)) rows)))
        (forward-line 1)))
    (nreverse rows)))

(defun bp/agent-sessions--nearby-session-id ()
  "Return the id of a session row next to the row at point.
Prefer the following row; when point is on the final row, return the previous
one.  Return nil when point is not on a session row or no other row exists."
  (let ((section (magit-current-section)))
    (when (and section (eq (oref section type) 'bp/agent-session-row))
      (let* ((start (oref section start))
             (rows (bp/agent-sessions--row-locations))
             (next (seq-find (lambda (row) (> (car row) start)) rows))
             (previous (seq-find (lambda (row) (< (car row) start))
                                 (reverse rows))))
        (cdr (or next previous))))))

(defun bp/agent-sessions--goto-session-id (id)
  "Move point to the dashboard row for session ID and return non-nil.
Return nil without moving point when ID is no longer displayed."
  (let ((row (seq-find (lambda (candidate) (equal (cdr candidate) id))
                       (bp/agent-sessions--row-locations))))
    (when row
      (goto-char (car row))
      t)))

(defun bp/agent-sessions--neighbour-ident (section)
  "Return the ident of the section to put point on once SECTION is gone.
The next sibling of the same type, else the previous one, else the parent — so
detaching a file lands on the next file, the last remaining file, or the
session they hang off, never back at the top of the buffer.

An *ident* rather than a position or a section object because the buffer is
erased and rebuilt in between, which is the same reason
`bp/agent-sessions--refresh' restores point by ident; and the reason this is
needed at all is that the refresh's own restoration cannot help here — the
section point was on is precisely the one that no longer exists."
  (when-let* ((parent (and section (oref section parent)))
              (type (oref section type))
              (siblings (seq-filter (lambda (c) (eq (oref c type) type))
                                    (oref parent children)))
              (pos (seq-position siblings section)))
    (magit-section-ident (or (nth (1+ pos) siblings)
                             (and (> pos 0) (nth (1- pos) siblings))
                             parent))))

(defun bp/agent-sessions--goto-ident (ident)
  "Move point to the section identified by IDENT, if it is still displayed."
  (when-let ((target (and ident (magit-get-section ident))))
    (goto-char (oref target start))
    t))

(defun bp/agent-sessions--next-file-ident-at-point ()
  "Return the next shared-file section's identity within this session.
Return nil on the last file.  Point may be inside a file's note."
  (let ((section (magit-current-section)))
    (when (and section (eq (oref section type) 'bp/agent-session-note))
      (setq section (oref section parent)))
    (when (and section (eq (oref section type) 'bp/agent-session-file))
      (let* ((siblings (seq-filter
                        (lambda (child)
                          (eq (oref child type) 'bp/agent-session-file))
                        (oref (oref section parent) children)))
             (next (nth (1+ (seq-position siblings section)) siblings)))
        (and next (magit-section-ident next))))))

(defun bp/agent-sessions-kill ()
  "Kill the session at point, or detach its shared file or link.
Detaching drops only the dashboard pointer; files on disk and external targets
are untouched."
  (interactive)
  (pcase (bp/agent-sessions--link-at-point)
    (`(,session ,url ,link)
     (let ((ident (bp/agent-sessions--neighbour-ident
                   (bp/agent-sessions--enclosing-section
                    'bp/agent-session-link))))
       (if (bp/agent-sessions--detach-link session url)
           (progn
             (bp/agent-sessions--refresh)
             (bp/agent-sessions--goto-ident ident)
             (message "Detached %s link."
                      (or (plist-get link :label) (plist-get link :url))))
         (message "Not attached to this session."))))
    (_
     (pcase (bp/agent-sessions--file-at-point)
       (`(,session ,path ,_file)
        ;; Resolve the neighbour *before* detaching, while the row is still on
        ;; screen to have neighbours at all.
        (let ((ident (bp/agent-sessions--neighbour-ident
                      (bp/agent-sessions--enclosing-section
                       'bp/agent-session-file))))
          (if (bp/agent-sessions--detach-file session path)
              (progn
                (bp/agent-sessions--refresh)
                (bp/agent-sessions--goto-ident ident)
                (message "Detached %s (the file on disk is untouched)."
                         (file-name-nondirectory (directory-file-name path))))
            (message "Not attached to this session."))))
       (_ (bp/agent-sessions--kill-session))))))

(defun bp/agent-sessions--kill-session ()
  "Kill the session at point and move to a neighboring session row."
  (let* ((session (bp/agent-sessions--session-at-point))
         (buf (and session (plist-get session :buffer)))
         (nearby-id (and (buffer-live-p buf)
                         (bp/agent-sessions--nearby-session-id))))
    (if (not (buffer-live-p buf))
        (message "No session at point.")
      (when (kill-buffer buf)
        ;; The terminal's kill-buffer hook refreshes the dashboard once, but
        ;; the deleted section cannot be restored and that refresh lands at
        ;; point-min.  Re-render defensively (for terminals without the hook),
        ;; then select the adjacent surviving row by its stable session id.
        (bp/agent-sessions--refresh)
        (when nearby-id
          (bp/agent-sessions--goto-session-id nearby-id))))))

(defun bp/agent-sessions-mark-unread (&optional unmark)
  "Mark the session at point as unread — i.e. needing attention.
Gives the row the same highlight, `●' marker, sort priority and `N'/`P'
reachability a hook-reported needs-attention has, for sessions you want to
come back to yourself.  With a prefix argument (UNMARK), clear the mark.
The mark also clears on its own once you focus the session's buffer.

On a shared-file or external-link row this toggles the unopened highlight
instead.  After marking an unread file read, move to the next file in the
same session if there is one.  UNMARK always clears."
  (interactive "P")
  (pcase (bp/agent-sessions--link-at-point)
    (`(,_session ,_kind ,link)
     (let ((visited (or (and unmark t) (null (plist-get link :visited-at))))
           (url (plist-get link :url)))
       (bp/agent-sessions--set-link-visited
        (lambda (candidate) (equal (plist-get candidate :url) url)) visited)
       (bp/agent-sessions--refresh)
       (message (if visited "Marked as read." "Marked as unread."))))
    (_
     (pcase (bp/agent-sessions--file-at-point)
       (`(,_session ,path ,file)
        (let ((visited (or (and unmark t)
                           (null (plist-get file :visited-at))))
              (next-ident (bp/agent-sessions--next-file-ident-at-point)))
          (let ((changed (bp/agent-sessions--set-visited
                          (lambda (f) (equal (plist-get f :path) path))
                          visited)))
            (bp/agent-sessions--refresh)
            (when (and changed visited next-ident)
              (bp/agent-sessions--goto-ident next-ident)))
          (message (if visited "Marked as read." "Marked as unread."))))
       (_ (bp/agent-sessions--mark-session-unread unmark))))))

(defun bp/agent-sessions--mark-session-unread (unmark)
  "Set or clear the unread mark on the session row at point."
  (let* ((session (bp/agent-sessions--session-at-point))
         (buf (and session (plist-get session :buffer))))
    (if (not (buffer-live-p buf))
        (message "No session at point.")
      (with-current-buffer buf
        (setq-local bp/agent-session--marked-unread (not unmark)))
      (bp/agent-sessions--refresh)
      (message (if unmark "Unread mark cleared." "Marked as needing attention.")))))

(defun bp/agent-sessions-branch ()
  "Branch (fork) the agent session at point into a new session.
Opens a new terminal in the same worktree and forks the conversation, so the
new session shares its parent's history but gets its own session id
\(`claude --fork-session' / `codex fork').  The new session is tagged as
branched from the one at point, shown as `↳ from …' in the dashboard."
  (interactive)
  (let* ((session (bp/agent-sessions--session-at-point))
         (agent (and session (plist-get session :agent-type)))
         (sid (and session (plist-get session :agent-session-id)))
         (path (and session
                    (or (plist-get session :worktree-path)
                        (let ((buf (plist-get session :buffer)))
                          (and (buffer-live-p buf)
                               (buffer-local-value 'default-directory buf)))))))
    (cond
     ((null session) (message "No session at point."))
     ((null sid) (message "Session at point has no resumable session id yet."))
     ((null path) (message "Session at point has no worktree to branch in."))
     (t (bp/agent-session--spawn
         path agent sid bp/agent-session-branch-commands
         (cons sid (bp/agent-sessions--session-short-label session)))))))

(defun bp/agent-sessions-mark-parent ()
  "Record that the session at point was branched from another session.
Prompts for the parent among the live sessions.  Use this to track a fork you
made outside the `b' command (e.g. running `claude --resume … --fork-session'
or `codex fork' by hand)."
  (interactive)
  (let* ((section (magit-current-section))
         (id (and section (eq (oref section type) 'bp/agent-session-row)
                  (oref section value)))
         (session (and id (bp/agent-sessions--session-for-id id))))
    (if (null session)
        (message "Point is not on a session row.")
      (let* ((self-sid (plist-get session :agent-session-id))
             (cands
              (delq nil
                    (mapcar (lambda (e)
                              (let ((es (plist-get e :session)))
                                ;; Exclude the target itself and any terminal
                                ;; running the *same* session (same conversation
                                ;; can't be its own parent — that would cycle).
                                (unless (or (equal (plist-get e :id) id)
                                            (and self-sid
                                                 (equal (plist-get es :agent-session-id)
                                                        self-sid)))
                                  (cons (bp/agent-sessions--session-label es) es))))
                            (bp/agent-sessions--live-entries))))
             (choice (and cands
                          (completing-read "Branched from: "
                                           (mapcar #'car cands) nil t)))
             (parent (and choice (cdr (assoc choice cands)))))
        (cond
         ((null cands) (message "No other sessions to branch from."))
         ((null parent) (message "No parent selected."))
         (t
          (let ((bf (cons (plist-get parent :agent-session-id)
                          (bp/agent-sessions--session-short-label parent)))
                (buf (plist-get session :buffer))
                (real (gethash id bp/agent-sessions)))
            ;; Set on the buffer so it survives future hook rebuilds, and on the
            ;; live registry entry (if any) so it shows immediately.
            (when (buffer-live-p buf)
              (with-current-buffer buf
                (setq-local bp/agent-session--branched-from bf)))
            (when real
              (puthash id (plist-put real :branched-from bf) bp/agent-sessions))
            (bp/agent-sessions--refresh)
            (message "Marked as branched from %s" (cdr bf)))))))))

(defun bp/agent-sessions-detach-parent ()
  "Detach the child session at point from its recorded fork parent."
  (interactive)
  (let* ((session (bp/agent-sessions--session-at-point))
         (parent (and session (plist-get session :branched-from)))
         (buf (and session (plist-get session :buffer)))
         (id (and (buffer-live-p buf)
                  (buffer-local-value 'bp/agent-session-id buf)))
         (real (and id (gethash id bp/agent-sessions))))
    (cond
     ((null session) (message "Point is not on a session row."))
     ((null parent) (message "Session is not attached to a parent."))
     ((not (buffer-live-p buf)) (message "Session has no live buffer."))
     (t
      (with-current-buffer buf
        (setq-local bp/agent-session--branched-from nil)
        (setq-local bp/agent-session--parent-detached-p t))
      (when real
        (puthash id (plist-put (copy-sequence real) :branched-from nil)
                 bp/agent-sessions))
      (bp/agent-sessions--refresh)
      (message "Detached from %s." (cdr parent))))))

(defun bp/agent-sessions-submission-diff-or-detach-parent ()
  "Diff submitted file versions at point, or detach a session's fork parent.
This keeps `D' contextual: file rows use the submitted-version history, while
the existing session-row action remains available on every other row."
  (interactive)
  (if (bp/agent-sessions--file-at-point)
      (bp/agent-sessions-show-file-submission-diff)
    (bp/agent-sessions-detach-parent)))

(defun bp/agent-sessions-edit-title ()
  "Edit the title of the session at point.
The chosen title is stored as a user override on the session's buffer, so it
takes precedence over — and survives — the agent's own OSC title updates.
Clearing it (entering an empty string) restores the agent's live title."
  (interactive)
  (let* ((session (bp/agent-sessions--session-at-point))
         (buf (and session (plist-get session :buffer))))
    (if (not (buffer-live-p buf))
        (message "No session at point.")
      (let* ((initial (with-current-buffer buf
                        (or bp/agent-session-title-override
                            bp/agent-session-title)))
             (new (string-trim (read-string "Session title: " initial))))
        (with-current-buffer buf
          (setq-local bp/agent-session-title-override
                      (unless (string-empty-p new) new)))
        (bp/agent-sessions--refresh)
        (message (if (string-empty-p new)
                     "Title override cleared."
                   (format "Title set to %s" new)))))))

(defun bp/agent-sessions-cycle-state ()
  "Move the session at point to the next workflow state.
Cycles through `bp/agent-sessions-states' and off the end back to no state.
With a prefix argument, pick a state directly instead — with five of them, a
cycle is a poor way to reach a particular one."
  (interactive)
  (let* ((session (bp/agent-sessions--session-at-point))
         (keys (and session (bp/agent-sessions--session-note-keys session))))
    (if (not keys)
        (message "No session at point.")
      (let* ((current (bp/agent-sessions--session-state session))
             (new (if current-prefix-arg
                      (let ((choice (completing-read
                                     "State (empty to clear): "
                                     bp/agent-sessions-states nil t)))
                        (and (not (string-empty-p choice)) choice))
                    (bp/agent-sessions--next-state current))))
        (bp/agent-sessions--state-set keys new)
        (bp/agent-sessions--refresh)
        (message (if new
                     (format "State: %s" new)
                   "State cleared."))))))

(defun bp/agent-sessions--context-at-point ()
  "Return (:path DIR :name NAME) for the worktree/repo enclosing point, or nil.
Walks up from the section at point so it works whether point is on a
worktree heading, a repo heading, or an individual session row."
  (let ((section (magit-current-section)))
    (catch 'found
      (while section
        (let ((value (oref section value)))
          (pcase (oref section type)
            ('bp/agent-session-worktree
             (throw 'found (list :path (plist-get value :path)
                                 :name (plist-get value :label))))
            ('bp/agent-session-repo
             (throw 'found (list :path (plist-get value :root)
                                 :name (plist-get value :name))))))
        (setq section (oref section parent)))
      nil)))

(defun bp/agent-sessions-toggle-folder-view ()
  "Toggle between worktree and global folder grouping."
  (interactive)
  (setq bp/agent-sessions-group-by-folder
        (not bp/agent-sessions-group-by-folder))
  (bp/agent-sessions--refresh)
  (message "Grouping by %s"
           (if bp/agent-sessions-group-by-folder "folder" "repo and worktree")))

(defun bp/agent-sessions-folder-action ()
  "Move the session at point, manage a folder heading, or create a folder."
  (interactive)
  (bp/agent-sessions--load-folders)
  (let* ((row (bp/agent-sessions--enclosing-section 'bp/agent-session-row))
         (session (and row (bp/agent-sessions--session-for-id
                            (oref row value))))
         (section (magit-current-section))
         (folder (and section
                      (eq (oref section type) 'bp/agent-session-folder)
                      (bp/agent-sessions--folder (oref section value)))))
    (cond
     (session
      (let* ((names (mapcar (lambda (item) (plist-get item :name))
                            bp/agent-sessions--folders))
             (choice (completing-read
                      "Move session to folder: "
                      (append names '("No folder" "Create new folder..."))
                      nil t))
             (destination
              (cond ((equal choice "No folder") nil)
                    ((equal choice "Create new folder...")
                     (bp/agent-sessions--folder-create
                      (read-string "New folder name: ")))
                    (t (seq-find (lambda (item)
                                   (equal choice (plist-get item :name)))
                                 bp/agent-sessions--folders)))))
        (bp/agent-sessions--folder-set session (plist-get destination :id))
        (bp/agent-sessions--refresh)))
     (folder
      (pcase (completing-read
              (format "%s: " (plist-get folder :name))
              '("Rename folder" "Delete folder") nil t)
        ("Rename folder"
         (bp/agent-sessions--folder-rename
          folder (read-string "Folder name: " (plist-get folder :name)))
         (bp/agent-sessions--refresh))
        ("Delete folder"
         (when (yes-or-no-p
                (format "Delete folder %s and unassign its sessions? "
                        (plist-get folder :name)))
           (bp/agent-sessions--folder-delete folder)
           (bp/agent-sessions--refresh)))))
     (t
      (bp/agent-sessions--folder-create (read-string "New folder name: "))
      (bp/agent-sessions--refresh)))))

(defun bp/agent-sessions--terminal-open (dir bufname)
  "Open the configured terminal in DIR in another window; return the buffer.
BUFNAME is the desired buffer name.  Loads the backend package lazily."
  (let ((default-directory (file-name-as-directory dir)))
    (pcase bp/agent-sessions-terminal
      ('vterm (require 'vterm) (vterm-other-window bufname))
      ('eat (require 'eat)
            (let ((eat-buffer-name bufname))
              ;; arg non-nil, non-number => eat--1 uses `generate-new-buffer'.
              (eat-other-window nil t)))
      (_ (error "Unknown `bp/agent-sessions-terminal': %S"
                bp/agent-sessions-terminal)))))

(defun bp/agent-sessions--terminal-send (buf string)
  "Send STRING followed by Enter to the terminal in BUF."
  (with-current-buffer buf
    (pcase bp/agent-sessions-terminal
      ('vterm (vterm-send-string string) (vterm-send-return))
      ('eat (eat-term-send-string eat-terminal string)
            (eat-term-send-string eat-terminal "\r")))))

(defun bp/agent-sessions--terminal-paste (buf string)
  "Bracket-paste STRING into the terminal in BUF without submitting it."
  (with-current-buffer buf
    (cond
     ((derived-mode-p 'vterm-mode) (vterm-send-string string t))
     ((derived-mode-p 'eat-mode)
      (eat-term-send-string-as-yank eat-terminal string))
     (t (user-error "Current buffer is not an Eat or vterm terminal")))))

(defun bp/agent-session-insert-org-link ()
  "Prompt for an Org link and paste it into the current terminal input."
  (interactive)
  (let ((terminal (current-buffer))
        (link (with-temp-buffer
                (org-mode)
                (call-interactively #'org-insert-link)
                (buffer-substring-no-properties (point-min) (point-max)))))
    (bp/agent-sessions--terminal-paste terminal link)))

(defun bp/agent-sessions--create-terminal (dir &optional name)
  "Open a new terminal in DIR named <NAME>-<backend>.
NAME defaults to DIR's basename (typically the worktree name).  The backend
is `bp/agent-sessions-terminal'."
  (let* ((base (or name (file-name-nondirectory (directory-file-name dir))))
         (bufname (format "%s-%s" base bp/agent-sessions-terminal)))
    (bp/agent-sessions--terminal-open dir bufname)))

(defun bp/agent-sessions--goto-terminal-row (buf)
  "Move the dashboard's point to the row for terminal BUF, if it has one.
Creating a terminal re-renders the dashboard, and that render restores point
to the section it was on — the worktree or repo heading `+' was pressed on —
so a row that did not exist before it has to be sought out afterwards.  The
window points are set explicitly because the dashboard is no longer the
selected buffer by then (the new terminal is), and an unselected window
displays its own point, not the buffer's."
  (when-let* ((id (and (buffer-live-p buf)
                       (buffer-local-value 'bp/agent-session-id buf)))
              (dashboard (get-buffer bp/agent-sessions-buffer-name)))
    (with-current-buffer dashboard
      (when (bp/agent-sessions--goto-session-id id)
        (dolist (win (get-buffer-window-list dashboard nil t))
          (set-window-point win (point)))))))

(defun bp/agent-sessions-new-vterm ()
  "Create a new vterm in the worktree at point, named after that worktree.
Leaves the dashboard's point on the new terminal's row, so the thing just
created is what `k', `t', `e' and `n'/`p' act from.  A second `+' still opens
a terminal in the same worktree, since `bp/agent-sessions--context-at-point'
walks up from a session row to the worktree containing it."
  (interactive)
  (let* ((ctx (bp/agent-sessions--context-at-point))
         (dir (plist-get ctx :path))
         (folder-section (and bp/agent-sessions-group-by-folder
                              (bp/agent-sessions--enclosing-section
                               'bp/agent-session-folder)))
         (folder-id (and folder-section (oref folder-section value))))
    (if (or (null dir) (not (file-directory-p dir)))
        (message "No worktree at point.")
      (let ((buf (bp/agent-sessions--create-terminal dir (plist-get ctx :name))))
        (when folder-id
          (bp/agent-sessions--folder-set (list :buffer buf) folder-id)
          (bp/agent-sessions--refresh-if-visible))
        (bp/agent-sessions--goto-terminal-row buf)))))

;;;###autoload
(defun bp/agent-session-switch-or-new ()
  "Switch to an agent session of the current project, or start a new one.
Prompts to pick among the sessions running in the current project's
worktree; choosing nothing (empty input) opens a new vterm in the project
root, like `+' in the dashboard.  With no sessions at all, goes straight to
creating one."
  (interactive)
  (let* ((root (or (ignore-errors (project-root (project-current)))
                   default-directory))
         (sessions
          (seq-filter
           (lambda (entry)
             (let* ((s (plist-get entry :session))
                    (wp (or (plist-get s :worktree-path)
                            (let ((b (plist-get s :buffer)))
                              (and (buffer-live-p b)
                                   (buffer-local-value 'default-directory b))))))
               (and wp (file-equal-p wp root))))
           (bp/agent-sessions--live-entries)))
         (cands
          (mapcar (lambda (entry)
                    (let* ((s (plist-get entry :session))
                           (buf (plist-get s :buffer)))
                      (cons (format "%s [%s %s]"
                                    (buffer-name buf)
                                    (plist-get s :agent-type)
                                    (plist-get s :status))
                            buf)))
                  sessions))
         (choice (and cands
                      (completing-read
                       (format "Agent session in %s (empty for new): "
                               (file-name-nondirectory (directory-file-name root)))
                       (mapcar #'car cands) nil nil)))
         (buf (and choice (cdr (assoc choice cands)))))
    (if (buffer-live-p buf)
        (pop-to-buffer buf)
      (bp/agent-sessions--create-terminal
       root (plist-get (bp/agent-session--repo-info root) :worktree)))))

(defun bp/agent-sessions--rows ()
  "Return (LINE-POS . STATUS) for each session and attachment row, in order.
This is what the last render drew (`bp/agent-sessions--row-status'), never a
fresh lookup: only the render path knows the displayed status."
  bp/agent-sessions--row-status)

(defun bp/agent-sessions--hidden-file-row-p (row)
  "Return non-nil when ROW belongs to a hidden file or external-link section."
  (let ((position (car row)))
    (and (invisible-p position)
         (save-excursion
           (goto-char position)
           (let ((section (magit-current-section)))
             (and section
                  (memq (oref section type)
                        '(bp/agent-session-file bp/agent-session-link))))))))

(defun bp/agent-sessions--goto-row (direction predicate)
  "Move point to the next/previous row (DIRECTION is `next' or `prev').
When PREDICATE is non-nil, only rows whose status satisfies it are considered.
Hidden attachment rows are excluded from filtered navigation; hidden session
rows remain candidates."
  (let* ((cur (line-beginning-position))
         (positions (mapcar #'car
                            (if predicate
                                (seq-filter (lambda (r)
                                              (and (funcall predicate (cdr r))
                                                   (not (bp/agent-sessions--hidden-file-row-p
                                                         r))))
                                            (bp/agent-sessions--rows))
                              (bp/agent-sessions--rows))))
         (target (pcase direction
                   ('next (seq-find (lambda (p) (> p cur)) positions))
                   ('prev (seq-find (lambda (p) (< p cur)) (reverse positions))))))
    (cond (target (goto-char target))
          ((null positions) (message "No matching row."))
          (t (message "No %s row." (if (eq direction 'next) "next" "previous"))))))

(defun bp/agent-sessions-next ()
  "Move to the next session row."
  (interactive)
  (bp/agent-sessions--goto-row 'next nil))

(defun bp/agent-sessions-prev ()
  "Move to the previous session row."
  (interactive)
  (bp/agent-sessions--goto-row 'prev nil))

(defun bp/agent-sessions-toggle-sort ()
  "Toggle the dashboard between activity order and the stable order.
Activity order reorders on every hook event, so concurrently busy sessions
trade places constantly; the stable order is the default for that reason."
  (interactive)
  (setq bp/agent-sessions-sort-by-activity
        (not bp/agent-sessions-sort-by-activity))
  (bp/agent-sessions--refresh)
  (message "Sorting by %s"
           (if bp/agent-sessions-sort-by-activity
               "most recent activity"
             "attention, then session age")))

(defun bp/agent-sessions--attention-p (status)
  (memq status '(needs-attention error)))

(defun bp/agent-sessions-next-attention ()
  "Move to the next session or visible attachment that needs attention."
  (interactive)
  (bp/agent-sessions--goto-row 'next #'bp/agent-sessions--attention-p))

(defun bp/agent-sessions-prev-attention ()
  "Move to the previous session or visible attachment that needs attention."
  (interactive)
  (bp/agent-sessions--goto-row 'prev #'bp/agent-sessions--attention-p))

(defun bp/agent-sessions--enclosing-section (type)
  "Return the innermost section of TYPE at or above point, or nil."
  (let ((section (magit-current-section)))
    (while (and section (not (eq (oref section type) type)))
      (setq section (oref section parent)))
    section))

(defun bp/agent-sessions--group-at-point ()
  "Return (SCOPE KEYS KEY) for the reorderable thing at point, or nil.
SCOPE is its manual-order scope, KEYS the manual-order keys of every sibling
in its group in current display order, and KEY its own key.  The group is
re-derived from the live tree rather than scraped from the buffer, so the keys
are exactly what the next render will order."
  (let* ((section (magit-current-section))
         (repos (bp/agent-sessions--build-tree (bp/agent-sessions--live-entries)))
         (repo-sec (bp/agent-sessions--enclosing-section 'bp/agent-session-repo))
         (rkey (and repo-sec (bp/agent-sessions--repo-key (oref repo-sec value))))
         (repo (and rkey (seq-find (lambda (r)
                                     (equal rkey (bp/agent-sessions--repo-key r)))
                                   repos))))
    (pcase (and section (oref section type))
      ('bp/agent-session-repo
       (list bp/agent-sessions--repos-scope
             (mapcar #'bp/agent-sessions--repo-key repos)
             rkey))
      ('bp/agent-session-worktree
       (when repo
         (list (bp/agent-sessions--worktrees-scope rkey)
               (mapcar #'bp/agent-sessions--worktree-key
                       (plist-get repo :worktrees))
               (bp/agent-sessions--worktree-key (oref section value)))))
      ('bp/agent-session-row
       (let* ((wt-sec (bp/agent-sessions--enclosing-section
                       'bp/agent-session-worktree))
              (wkey (and wt-sec repo
                         (bp/agent-sessions--worktree-key (oref wt-sec value))))
              (wt (and wkey
                       (seq-find (lambda (w)
                                   (equal wkey
                                          (bp/agent-sessions--worktree-key w)))
                                 (plist-get repo :worktrees))))
              (session (bp/agent-sessions--session-for-id (oref section value))))
         (when (and wt session)
           (list (bp/agent-sessions--sessions-scope rkey wkey)
                 (mapcar #'bp/agent-sessions--entry-buffer-name
                         (plist-get wt :entries))
                 (bp/agent-sessions--session-buffer-name session)))))
      ('bp/agent-session-file
       (let* ((row (bp/agent-sessions--enclosing-section 'bp/agent-session-row))
              (session (and row (bp/agent-sessions--session-for-id
                                 (oref row value)))))
         (when session
           (list (bp/agent-sessions--files-scope session)
                 (mapcar (lambda (f) (plist-get f :path))
                         (bp/agent-sessions--session-files session))
                 (oref section value)))))
      ('bp/agent-session-link
       (let* ((row (bp/agent-sessions--enclosing-section 'bp/agent-session-row))
              (session (and row (bp/agent-sessions--session-for-id
                                 (oref row value)))))
         (when session
           (list (bp/agent-sessions--links-scope session)
                 (mapcar (lambda (link) (plist-get link :url))
                         (bp/agent-sessions--session-links session))
                 (oref section value))))))))

(defun bp/agent-sessions--merge-order (saved visible)
  "Splice the VISIBLE key order into SAVED, keeping absent keys in place.
Each slot in SAVED held by a currently visible key is refilled from VISIBLE in
order, and visible keys SAVED doesn't know about are appended.  Rewriting a
group therefore never discards the remembered slot of a repo, worktree, or
session that simply isn't on screen right now (all its terminals closed, say)."
  (let ((queue visible)
        (vis (let ((h (make-hash-table :test 'equal)))
               (dolist (k visible) (puthash k t h))
               h))
        result)
    (dolist (k saved)
      (if (gethash k vis)
          (when queue (push (pop queue) result))
        (push k result)))
    (append (nreverse result) queue)))

(defun bp/agent-sessions--persist-move (scope keys key delta)
  "Record KEY shifted by DELTA among KEYS within SCOPE, and save.
Returns non-nil when the order changed; messages and returns nil when KEY is
already at the end it is being moved towards."
  (let* ((pos (seq-position keys key))
         (dest (and pos (+ pos delta))))
    (cond
     ((null pos) (message "Nothing to reorder at point.") nil)
     ((or (< dest 0) (>= dest (length keys)))
      (message "Already %s in its group." (if (< delta 0) "first" "last"))
      nil)
     (t
      (let* ((swapped (copy-sequence keys))
             (table (bp/agent-sessions--order-table))
             (old (gethash scope table))
             new)
        (setf (nth pos swapped) (nth dest keys)
              (nth dest swapped) key)
        (setq new (bp/agent-sessions--merge-order old swapped))
        (puthash scope new table)
        ;; Hand both lists over so only the rows that actually moved are
        ;; written — for a transposition that is two of them.
        (bp/agent-sessions--order-write-group scope old new)
        t)))))

(defun bp/agent-sessions--move (delta)
  "Move the repo, worktree, or session row at point by DELTA within its group."
  (if bp/agent-sessions-group-by-folder
      (message "Manual order is available in the repo view (press `f').")
    (if bp/agent-sessions-sort-by-activity
      (message "Manual order is ignored while sorting by activity (press `s').")
      (pcase (bp/agent-sessions--group-at-point)
        (`(,scope ,keys ,key)
         (when (bp/agent-sessions--persist-move scope keys key delta)
           (bp/agent-sessions--refresh)))
        (_ (message "Nothing to reorder at point."))))))

(defun bp/agent-sessions-move-down ()
  "Move the repo, worktree, or session at point one place down its group.
Only the enclosing group is affected: a session moves among the sessions of
its worktree, a worktree among its repo's worktrees, a repo among the repos.
The chosen order is written to `bp/agent-sessions-db-file', so it survives
both the session and Emacs itself; a session is remembered by its buffer name,
so renaming one forgets its place.  Unavailable while sorting by activity
\(`s'), which reorders by recency on every event.  `C-c C-o' clears it again."
  (interactive)
  (bp/agent-sessions--move 1))

(defun bp/agent-sessions-move-up ()
  "Move the repo, worktree, or session at point one place up its group.
See `bp/agent-sessions-move-down'."
  (interactive)
  (bp/agent-sessions--move -1))

(defun bp/agent-sessions-clear-manual-order ()
  "Forget the manual order (`M-n' / `M-p') and return to the automatic one.
With point inside a repo, worktree, or on a session row, clears just that
item's group; with a prefix argument, clears every group."
  (interactive)
  (if bp/agent-sessions-group-by-folder
      (message "Manual order is available in the repo view (press `f').")
    (let ((table (bp/agent-sessions--order-table)))
      (if current-prefix-arg
          (progn (clrhash table)
                 (bp/agent-sessions--order-delete-all)
                 (bp/agent-sessions--refresh)
                 (message "Manual order cleared everywhere."))
        (pcase (bp/agent-sessions--group-at-point)
          (`(,scope ,_ ,_)
           (remhash scope table)
           (bp/agent-sessions--order-delete-group scope)
           (bp/agent-sessions--refresh)
           (message "Manual order cleared for this group."))
          (_ (message "Point is not in a reorderable group.")))))))

;;;###autoload
(defun bp/agent-session-rename-to-title ()
  "Rename the current vterm buffer to its agent session title.
The title captured from the terminal (`bp/agent-session-title') is offered
as the editable default so it can be tweaked before confirming."
  (interactive)
  (let* ((initial (or bp/agent-session-title (buffer-name)))
         (new (string-trim (read-string "Rename buffer to: " initial))))
    (unless (string-empty-p new)
      (rename-buffer new t)
      (message "Renamed to %s" new))))

(defcustom bp/agent-session-resume-commands
  '((claude . "claude --resume %s")
    (codex  . "codex resume %s")
    (pi     . "pi --session %s"))
  "Alist mapping AGENT-TYPE symbol to a shell command that resumes a session.
The %s is replaced with the agent's own session id."
  :type '(alist :key-type symbol :value-type string))

(defcustom bp/agent-session-branch-commands
  '((claude . "claude --resume %s --fork-session")
    (codex  . "codex fork %s")
    (pi     . "pi --fork %s"))
  "Alist mapping AGENT-TYPE symbol to a shell command that branches a session.
Branching forks the conversation into a new session that shares the parent's
history but gets its own session id (`claude --fork-session' / `codex fork').
The %s is replaced with the parent's own session id."
  :type '(alist :key-type symbol :value-type string))

(defun bp/agent-session--spawn (worktree-path agent-type session-id commands
                                              &optional branched-from initial-prompt)
  "Open a terminal in WORKTREE-PATH and run COMMANDS's template for AGENT-TYPE.
COMMANDS is an alist like `bp/agent-session-resume-commands'; its template's
%s is filled with SESSION-ID.  When BRANCHED-FROM is non-nil (a cons
\(PARENT-SID . LABEL)), tag the new terminal so the session it starts records
that it was branched from that parent.  When INITIAL-PROMPT is non-nil, append
it as a shell-quoted argument to the launch command.  Returns the new terminal
buffer."
  (let* ((agent (if (symbolp agent-type) agent-type (intern agent-type)))
         (template (alist-get agent commands))
         (default-directory (file-name-as-directory worktree-path)))
    (unless template
      (error "No command configured for agent type `%s'" agent))
    (unless (file-directory-p default-directory)
      (error "Worktree no longer exists: %s" worktree-path))
    (let ((buf (bp/agent-sessions--create-terminal
                default-directory
                (plist-get (bp/agent-session--repo-info default-directory) :worktree))))
      (when (and branched-from (buffer-live-p buf))
        (with-current-buffer buf
          (setq-local bp/agent-session--branched-from branched-from)))
      (bp/agent-sessions--terminal-send
       buf (concat (format template session-id)
                   (if initial-prompt
                       (concat " " (shell-quote-argument initial-prompt))
                     "")))
      buf)))

;;;###autoload
(defun bp/agent-session-start (worktree-path agent-type session-id
                                             &optional initial-prompt)
  "Open a vterm in WORKTREE-PATH and resume AGENT-TYPE's SESSION-ID.
AGENT-TYPE is a symbol such as `claude' or `codex'.  This is the target of
the `elisp:' links produced by `org-store-link' on a session row.  When
INITIAL-PROMPT is non-nil, submit it as the resumed session's first prompt."
  (let ((buf (bp/agent-session--spawn
              worktree-path agent-type session-id
              bp/agent-session-resume-commands nil initial-prompt)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (setq-local bp/agent-session--resuming-session-id session-id)))
    buf))

(defun bp/agent-sessions--buffer-for-agent-session (session-id)
  "Return the live buffer running the agent session SESSION-ID, or nil.
Prefer an identity confirmed by an agent hook in `bp/agent-sessions'.  During
startup, before Codex's first hook, also recognize the resume identity recorded
on its terminal buffer in `bp/agent-session--resuming-session-id'."
  (catch 'found
    (maphash
     (lambda (_id session)
       (when (equal (plist-get session :agent-session-id) session-id)
         (let ((buf (plist-get session :buffer)))
           (when (buffer-live-p buf)
             (throw 'found buf)))))
     bp/agent-sessions)
    (maphash
     (lambda (_id buf)
       (when (and (buffer-live-p buf)
                  (equal (buffer-local-value
                          'bp/agent-session--resuming-session-id buf)
                         session-id))
         (throw 'found buf)))
     bp/agent-session-id->buffer)
    nil))

;;;###autoload
(defun bp/agent-session-open (worktree-path agent-type session-id)
  "Jump to the running AGENT-TYPE session SESSION-ID, or resume it if not open.
If a live terminal is already running SESSION-ID (matched by the agent's own
session id), switch to it; otherwise open a new terminal in WORKTREE-PATH and
resume it via `bp/agent-session-start'.  This is the target of the
`agent-session' `elisp:' links produced by `org-store-link'."
  (let ((buf (bp/agent-sessions--buffer-for-agent-session session-id)))
    (if (buffer-live-p buf)
        (pop-to-buffer buf)
      (bp/agent-session-start worktree-path agent-type session-id))))

;;; Restoring sessions from the log -----------------------------------------

(defun bp/agent-sessions--log-rows (where &optional args)
  "Return session-log rows matching WHERE as plists, newest ending first.
Deduplicated by agent session id, keeping each id's most recent row: the fork
transient can leave a second row carrying a parent's id, and one entry per
resumable session is what the caller wants either way.  Rows with no agent
session id are skipped — a bare terminal has nothing to resume, and `+' opens
one anyway."
  (mapcar
   (lambda (r)
     (pcase-let ((`(,sid ,type ,worktree ,label ,title ,closed ,reason) r))
       (list :agent-sid sid :agent-type type :worktree worktree
             :label label :title title :closed-at closed :reason reason)))
   (sqlite-select
    (bp/agent-sessions--db)
    (concat "SELECT agent_sid, agent_type, worktree, label, title,
                    MAX(closed_at) AS closed_at, close_reason
               FROM sessions
              WHERE agent_sid IS NOT NULL AND agent_type IS NOT NULL AND "
            where
            " GROUP BY agent_sid ORDER BY closed_at DESC")
    args)))

(defun bp/agent-sessions--log-describe (row)
  "A one-line label for session-log ROW, for completion or confirmation."
  (format "%-28s %-7s %s"
          (or (plist-get row :label) "?")
          (or (plist-get row :agent-type) "?")
          (or (plist-get row :title)
              (substring (or (plist-get row :agent-sid) "?") 0 8))))

(defun bp/agent-sessions--log-annotate (row)
  "The trailing annotation for session-log ROW: when it ended, and how."
  (let ((at (plist-get row :closed-at)))
    (format "  %s, %s"
            (if at
                (format-time-string "%b %e %H:%M" (seconds-to-time at))
              "?")
            (pcase (plist-get row :reason)
              ("killed" "you closed it")
              ("agent-exit" "agent exited")
              ("superseded" "replaced in its terminal")
              ("emacs-exit" "Emacs quit")
              ("crash" "Emacs died")
              (other (or other "?"))))))

(defun bp/agent-sessions--restore-title (buf row)
  "Restore session-log ROW's saved title as a user override on BUF.
The log records the title that labelled the old terminal.  Making it an
override preserves that label when the resumed agent emits fresh OSC titles."
  (when (buffer-live-p buf)
    (when-let ((title (plist-get row :title)))
      (with-current-buffer buf
        (setq-local bp/agent-session-title-override title))
      (bp/agent-sessions--refresh-if-visible)))
  buf)

(defun bp/agent-sessions--restore-row (row)
  "Resume the session described by ROW, or jump to it if it is already open."
  (let* ((wt (plist-get row :worktree))
         (sid (plist-get row :agent-sid))
         (type (intern (plist-get row :agent-type)))
         (live (bp/agent-sessions--buffer-for-agent-session sid)))
    (cond
     (live
      (bp/agent-sessions--restore-title live row)
      (pop-to-buffer live)
      (message "That session is already open."))
     ((not (file-directory-p wt))
      (message "Worktree is gone: %s" wt))
     (t
      (bp/agent-sessions--restore-title
       (bp/agent-session-start wt type sid) row)))))

;;;###autoload
(defun bp/agent-sessions-restore ()
  "Resume a session that has ended, picked from the log.
Lists every session the log knows the end of, most recently ended first,
annotated with when and how it ended.  A session whose terminal is somehow
still open is switched to rather than resumed twice, and one whose worktree
has since been deleted says so instead of failing in a shell."
  (interactive)
  (let ((rows (bp/agent-sessions--log-rows "closed_at IS NOT NULL")))
    (if (null rows)
        (message "No ended sessions in the log yet.")
      (let* ((table (mapcar (lambda (r)
                              (cons (bp/agent-sessions--log-describe r) r))
                            rows))
             (completion-extra-properties
              (list :annotation-function
                    (lambda (k)
                      (bp/agent-sessions--log-annotate (cdr (assoc k table))))))
             (choice (completing-read "Restore session: " table nil t)))
        (when-let ((row (cdr (assoc choice table))))
          (bp/agent-sessions--restore-row row))))))

;;;###autoload
(defun bp/agent-sessions-restore-previous ()
  "Reopen the sessions that were running when Emacs last stopped.
Covers both an Emacs that crashed and one that was quit while sessions were
still going — from here those are the same thing, and each closes its batch of
rows with a single timestamp, which is how the last batch is identified.

Deliberately not bound to a key: it is a recovery command, wanted rarely and
never by accident.  Sessions already open are skipped, as are worktrees that
no longer exist, and what is left is shown for confirmation before anything
is spawned."
  (interactive)
  (let* ((rows (bp/agent-sessions--log-rows
                "close_reason IN ('crash', 'emacs-exit')
                 AND closed_at = (SELECT MAX(closed_at) FROM sessions
                                   WHERE close_reason IN ('crash', 'emacs-exit'))"))
         (live (seq-filter (lambda (r)
                             (bp/agent-sessions--buffer-for-agent-session
                              (plist-get r :agent-sid)))
                           rows))
         (gone (seq-filter (lambda (r)
                             (not (file-directory-p (plist-get r :worktree))))
                           rows))
         (todo (seq-difference rows (append live gone))))
    (cond
     ((null rows) (message "No sessions were lost — nothing to restore."))
     ((null todo)
      (message "Nothing to restore: %d already open, %d worktree(s) gone."
               (length live) (length gone)))
     (t
      (with-output-to-temp-buffer "*Agent Sessions Restore*"
        (princ (format "Sessions from the last Emacs (%s):\n\n"
                       (bp/agent-sessions--log-annotate (car todo))))
        (dolist (r todo)
          (princ (concat "  " (bp/agent-sessions--log-describe r) "\n")))
        (when live
          (princ (format "\nAlready open, will be skipped: %d\n" (length live))))
        (dolist (r gone)
          (princ (format "\nWorktree gone, cannot restore: %s\n"
                         (plist-get r :worktree)))))
      (when (yes-or-no-p (format "Restore %d session(s)? " (length todo)))
        ;; Staggered: each spawns a terminal and types into it, and firing them
        ;; all in one go leaves the shells racing their own startup.
        (let ((n 0))
          (dolist (row todo)
            (run-at-time (* n 1.0) nil
                         (lambda (r)
                           (condition-case err
                               (save-window-excursion
                                 (bp/agent-sessions--restore-row r))
                             (error (message "agent-sessions: %s"
                                             (error-message-string err)))))
                         row)
            (setq n (1+ n))))
        (message "Restoring %d session(s)…" (length todo)))))))

(defun bp/agent-sessions--store-link-for (session)
  "Store an `elisp:' resume link for SESSION via `org-link-store-props'.
Return non-nil on success, nil when SESSION lacks the info to build a link."
  (when session
    (let* ((path (or (plist-get session :worktree-path)
                     (let ((buf (plist-get session :buffer)))
                       (and (buffer-live-p buf)
                            (buffer-local-value 'default-directory buf)))))
           (agent (plist-get session :agent-type))
           (sid (plist-get session :agent-session-id))
           (branch (and path
                        (ignore-errors
                          (let ((default-directory path))
                            (magit-get-current-branch)))))
           (title (bp/agent-sessions--session-title session)))
      (when (and path sid)
        (org-link-store-props
         :type "agent-session"
         :link (format "agent-session:%s::%s::%s"
                       agent sid (file-name-as-directory path))
         :description (if branch
                          (format "%s %s %s" branch agent (or title sid))
                        (format "%s %s" agent (or title sid))))
        t))))

(defun bp/agent-sessions--store-file-link (path)
  "Store an Org `file:' link to PATH, described by its bare file name.
Return non-nil on success.  A shared-file row is a pointer to a file, so the
useful link is the ordinary one any other buffer would produce — not something
that goes through this package.  The description is the file name alone,
extension included: the row already sits under the session that shared it, and
the path it came from is rarely what the surrounding prose wants to read."
  (when (and path (not (string-empty-p path)))
    (org-link-store-props
     :type "file"
     :link (concat "file:" (abbreviate-file-name path))
     :description (file-name-nondirectory (directory-file-name path)))
    t))

(defun bp/agent-sessions--store-external-link (link)
  "Store shared external LINK as an ordinary HTTP(S) Org link."
  (let ((url (plist-get link :url)))
    (when (and url (not (string-empty-p url)))
      (org-link-store-props
       :type (if (string-prefix-p "https://" url) "https" "http")
       :link url
       :description (or (plist-get link :label) url))
      t)))

(defun bp/agent-sessions--parse-session-link (link)
  "Return (AGENT SESSION-ID WORKTREE) parsed from LINK, or nil.
LINK may include the `agent-session:' prefix or only its Org handler payload."
  (let ((payload (if (string-prefix-p "agent-session:" link)
                     (substring link (length "agent-session:"))
                   link)))
    (when (string-match "\\`\\([^:]+\\)::\\([^:]+\\)::\\(.*\\)\\'" payload)
      (list (match-string 1 payload)
            (match-string 2 payload)
            (match-string 3 payload)))))

(defun bp/agent-sessions--org-follow-link (link &optional _arg)
  "Follow an `agent-session:' LINK, jumping to or resuming the session.
LINK is AGENT::SESSION-ID::WORKTREE-PATH, as produced by the `:store'
handler.  Using a dedicated link type (rather than an `elisp:' link) avoids
the confirmation prompt Org shows before running arbitrary elisp."
  (pcase (bp/agent-sessions--parse-session-link link)
    (`(,agent ,session-id ,worktree)
     (bp/agent-session-open worktree agent session-id))
    (_ (error "Malformed agent-session link: %s" link))))

(defun bp/agent-sessions--org-store-link (&optional _interactive)
  "Store a link for the dashboard row at point, or for the session around point.
A shared file or external URL stores its ordinary link; a session row (or a
terminal buffer with a live session) stores an `agent-session:' resume link."
  (cond
   ((and (derived-mode-p 'bp/agent-sessions-mode)
         (bp/agent-sessions--link-at-point))
    (bp/agent-sessions--store-external-link
     (nth 2 (bp/agent-sessions--link-at-point))))
   ((and (derived-mode-p 'bp/agent-sessions-mode)
         (bp/agent-sessions--file-at-point))
    ;; Attachments are nested inside a session row, so resolve them first.
    (bp/agent-sessions--store-file-link
     (nth 1 (bp/agent-sessions--file-at-point))))
   (t
    (bp/agent-sessions--store-link-for
     (cond ((derived-mode-p 'bp/agent-sessions-mode)
            (bp/agent-sessions--session-at-point))
           (bp/agent-session-id
            (gethash bp/agent-session-id bp/agent-sessions)))))))

(defun bp/agent-sessions--sync-default-directory ()
  "Track the worktree/repo at point in `default-directory'.
This makes `C-x p' project commands (and anything else keyed off
`default-directory') operate on the worktree under the cursor."
  (let* ((ctx (bp/agent-sessions--context-at-point))
         (dir (and ctx (plist-get ctx :path))))
    (when (and dir (file-directory-p dir))
      (setq default-directory (file-name-as-directory dir)))))

(define-derived-mode bp/agent-sessions-mode magit-section-mode "Agent-Sessions"
  "Major mode listing Claude/Codex sessions running in vterm, as a
repo > worktree > session tree, or a folder-first tree with `f'.
Sections fold with TAB; `F' manages folders and session assignments."
  (add-hook 'post-command-hook
            #'bp/agent-sessions--sync-default-directory nil t))

;; `define-derived-mode' sets the parent keymap only when the map has none, and
;; the map itself is a `defvar' that survives reloading this file.  An Emacs
;; that loaded a version of this mode deriving from something else therefore
;; keeps that old parent forever — which cost us TAB: `tabulated-list-mode-map'
;; inherits `button-buffer-map', whose `forward-button' shadowed
;; `magit-section-toggle' ("No button").  Re-point it on every load.
(set-keymap-parent bp/agent-sessions-mode-map magit-section-mode-map)


;;; Orchestration ------------------------------------------------------------
;;
;; An agent spawning other agents and talking to them.  Everything here is
;; reached from `bin/emacs-agent' over emacsclient, so every entry point
;; *returns* its failures as a string: emacsclient's printed value is the
;; agent's only channel back, exactly as for `bp/agent-sessions-share-file'.
;;
;; What this deliberately is not: there are no task rows, no dependency graph
;; and no scheduler.  The orchestrator is an agent with a context window; that
;; context *is* the plan, and duplicating it in a table would mean keeping two
;; plans honest.  What Emacs owns is the part an agent cannot do for itself —
;; starting a terminal, addressing another live one, and blocking until it
;; answers.

(defcustom bp/agent-orchestration-launch-commands
  '((claude . "claude %m \"$(cat %b)\"")
    (codex  . "codex %m \"$(cat %b)\"")
    (pi     . "pi %m \"$(cat %b)\""))
  "Shell command per agent type that starts a worker on a task brief.
Rendered with `format-spec':

  %b  path of the brief file `bp/agent-orchestration-spawn' wrote, quoted
  %m  the model flag for this spawn, or nothing when it named no model
      (spelled by `bp/agent-orchestration-model-flags')

The brief is read by the shell instead of being passed as a literal argument
because it is a two-kilobyte multi-line prompt, and typing that into a terminal
as one quoted argument is exactly the sort of line a TUI mangles.  `cat' keeps
the typed line short whichever agent is launched, and passing the task at
launch avoids the race that sending it afterwards would have: a TUI that is
still starting silently drops input.

A template written before `%m' existed — one bare `%s' for the brief — still
launches; it just has nowhere to put a model, so a spawn that names one against
that type is refused rather than quietly run on the default model."
  :type '(alist :key-type symbol :value-type string))

(defcustom bp/agent-orchestration-model-flags
  '((claude . "--model %s")
    (codex  . "--model %s")
    (pi     . "--model %s"))
  "How each agent type spells \"run on this model\", with %s for the model name.
This is what `%m' in `bp/agent-orchestration-launch-commands' expands to when a
spawn names a model.  A type with no entry here takes no model, and a spawn
naming one for it is refused: guessing a flag for a CLI we know nothing about
would produce a worker that dies on its own usage message, which reaches the
orchestrator as a worker that simply never reports.

Model *names* are passed through unchecked — they are the agent CLI\='s
vocabulary, not ours, and a list here would be wrong within a release."
  :type '(alist :key-type symbol :value-type string))

(defcustom bp/agent-orchestration-push-when-idle t
  "When non-nil, automatically hand queued mail to a recipient agent.
Codex mail uses its native session queue, whether the conversation is running
or resting, so it never shares the human's terminal composer.  Claude mail uses
Claude Code's queue-submit action only when its composer is known to be safe.
Mail that arrives while the human is drafting stays unread until the human
submits that prompt, then queues behind it.  Claude's composer safety decides
delivery regardless of message type or stale hook status; Codex retains its
native-queue steering policy.  `emacs-agent wait' remains the explicit way for
an agent to collect its own mail."
  :type 'boolean)

(defcustom bp/agent-orchestration-claude-queue-submit-key "\C-x\r"
  "Terminal bytes bound to Claude Code's `chat:queueSubmit' action.
The default is Claude Code's default Ctrl+X Enter chord.  Keep this synchronized
with `~/.claude/keybindings.json' if that action is rebound."
  :type 'string)

(defconst bp/agent-orchestration--submit-delay 0.5
  "Seconds between pasting a message into a TUI and pressing Enter.
The pasted block only becomes the TUI's composed input after it has processed
it; submitting in the same breath submits an empty prompt.")

(defconst bp/agent-orchestration--native-queue-timeout 5
  "Seconds to wait for an agent's native queue command to acknowledge mail.")

(defcustom bp/agent-orchestration-codex-empty-prompt-regexp
  "^›[[:blank:]]+Ask Codex to do anything[[:blank:]]*$"
  "Regexp matching Codex's empty idle composer.
This is the one terminal state where delivering mail through the composer is
safe even when the last hook still says the session is running.  In
particular, Codex does not emit a Stop hook when a turn is interrupted, and
its native queue deliberately leaves messages pending while the thread has
that internal state."
  :type 'regexp)

(defvar bp/agent-orchestration--brief-dir
  (expand-file-name "emacs-agent-briefs/" temporary-file-directory)
  "Where task briefs are written.  Kept after the worker starts, on purpose:
it is the only record of what a worker was actually told, and it is what makes
a launch reproducible by hand (`claude \"$(cat …)\"').")

;;;; Ids and labels

(defun bp/agent-orchestration--next-id (prefix)
  "An id unique across Emacs restarts, not just within one.
The pid is in it for the same reason it is in a terminal id: stored mail
outlives the Emacs that minted its ids, and a fresh counter would otherwise
hand a new message the id of a stored one."
  (format "%s-%d-%d" prefix (emacs-pid) (cl-incf bp/agent-orchestration--counter)))

(defun bp/agent-orchestration--task-title (task)
  "A short label for TASK: its first line, truncated."
  (let* ((line (car (split-string (string-trim task) "\n" t)))
         (line (or line "task")))
    (if (> (length line) 48) (concat (substring line 0 45) "…") line)))

(defun bp/agent-orchestration--mail-key (id session)
  "The durable identity mail for SESSION in terminal ID is filed under.
The agent's own session id when it has one: that is what `R' resumes, so mail
filed under it comes back attached to the conversation it belongs to.  Failing
that the terminal id, which carries this Emacs's pid — unique for the life of
the terminal and never minted again, so a bare terminal's mail can never be
inherited by an unrelated one that happens to reuse its buffer name.  (Which is
also why mail under a terminal key is not restorable: nothing can resume a bare
shell, so there would be nothing to restore it to.)"
  (let ((sid (plist-get session :agent-session-id)))
    (if sid (list "session" sid) (list "terminal" id))))

(defun bp/agent-orchestration--mail-insert (msg)
  "Record MSG in the database.  Reported, not raised, on failure: a message
already queued in memory should still be delivered when the record fails."
  (condition-case err
      (sqlite-execute
       (bp/agent-sessions--db)
       "INSERT OR REPLACE INTO mail
          (id, from_kind, from_key, from_label, to_kind, to_key,
           type, subject, body, files, report, sent_at, read_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, NULL)"
       (append (list (plist-get msg :id))
               (plist-get msg :from-key)
               (list (plist-get msg :from-label))
               (plist-get msg :to-key)
               (list (plist-get msg :type)
                     (plist-get msg :subject)
                     (plist-get msg :body)
                     (plist-get msg :files)
                     (plist-get msg :report)
                     (plist-get msg :sent-at))))
    (error (message "agent-sessions: could not record mail (%s)"
                    (error-message-string err)))))

(defun bp/agent-orchestration--hydrate (id)
  "Load ID's unread mail from the database into its in-memory inbox.
Called when a session's identity becomes known (a hook event) and when an agent
reads its inbox — never from the render path, which must not query the
database.  Safe to call repeatedly: messages already present are skipped by id,
and ids carry the pid of the Emacs that minted them, so one restored from a
previous run cannot collide with one from this one."
  (let* ((session (bp/agent-sessions--session-for-id id))
         (key (and session (bp/agent-orchestration--mail-key id session))))
    (when key
      (condition-case err
          (let* ((existing (bp/agent-orchestration--messages id))
                 (known (mapcar (lambda (m) (plist-get m :id)) existing))
                 (rows (sqlite-select
                        (bp/agent-sessions--db)
                        "SELECT id, from_kind, from_key, from_label, type, subject,
                                body, files, report, sent_at
                           FROM mail
                          WHERE to_kind = ? AND to_key = ? AND read_at IS NULL
                          ORDER BY sent_at, rowid"
                        key))
                 (fresh nil))
            (pcase-dolist (`(,mid ,fkind ,fkey ,flabel ,type ,subject
                                  ,body ,files ,report ,sent)
                           rows)
              (unless (member mid known)
                (push (list :id mid
                            ;; No `:from': the terminal that sent this belonged
                            ;; to a previous Emacs.  `:from-key' is how a live
                            ;; one is found again, if it was restored too.
                            :from nil :from-key (list fkind fkey) :from-label flabel
                            :to id :to-key key :type type :subject subject
                            :body body :files files :report report
                            :sent-at sent :read nil)
                      fresh)))
            (when fresh
              (puthash id (append existing (nreverse fresh))
                       bp/agent-orchestration--mail)))
        (error (message "agent-sessions: could not read stored mail (%s)"
                        (error-message-string err)))))))

(defun bp/agent-orchestration--live-id-for-key (key)
  "Terminal id of the live session filed under durable KEY, or nil.
How a restored conversation is found again: the id it had when it sent a
message is gone, but the identity it was filed under is not."
  (seq-some (lambda (entry)
              (let ((eid (plist-get entry :id)))
                (and (equal key (bp/agent-orchestration--mail-key
                                 eid (plist-get entry :session)))
                     eid)))
            (bp/agent-sessions--live-entries)))

(defun bp/agent-orchestration--sender-terminal (msg)
  "The live terminal id MSG can be answered at, or nil when its sender is gone."
  (let ((from (plist-get msg :from))
        (key (plist-get msg :from-key)))
    (cond ((and from (bp/agent-sessions--session-for-id from)) from)
          (key (bp/agent-orchestration--live-id-for-key key)))))

(defun bp/agent-orchestration--sender-address (msg)
  "The durable address for replying to MSG, or its live terminal id."
  (pcase (plist-get msg :from-key)
    (`("session" ,session-id) session-id)
    (_ (bp/agent-orchestration--sender-terminal msg))))

;;;; Message rendering

(defun bp/agent-orchestration--describe-sender (id)
  "How a message from ID is introduced: its agent type and worktree, if live."
  (let ((session (bp/agent-sessions--session-for-id id)))
    (if (null session)
        " (terminal gone)"
      (format " (%s%s)"
              (plist-get session :agent-type)
              (let ((wt (plist-get session :worktree)))
                (if wt (concat ", " wt) ""))))))

(defun bp/agent-orchestration--format-message (msg)
  "Render MSG for an agent to read, ending with the command that answers it.
A message restored from the database may have outlived the terminal that sent
it, so the sender is resolved through its durable key: answerable when that
conversation is live again, named but not addressable when it is not."
  (let* ((live (bp/agent-orchestration--sender-terminal msg))
         (reply-to (bp/agent-orchestration--sender-address msg))
         (label (or (plist-get msg :from-label) (plist-get msg :from) "unknown")))
    (concat (format "--- $orca (/orca) message from %s%s [%s]\n"
                    (or live label)
                    (if live
                        (bp/agent-orchestration--describe-sender live)
                      (format " (%s — that terminal is gone)" label))
                    (plist-get msg :type))
            (format "Subject: %s\n" (plist-get msg :subject))
            (let ((body (plist-get msg :body)))
              (if (and body (not (string-empty-p body))) (concat body "\n") ""))
            (let ((files (plist-get msg :files)))
              (if (and files (not (string-empty-p files)))
                  (format "Files: %s\n" files) ""))
            (let ((report (plist-get msg :report)))
              (if (and report (not (string-empty-p report)))
                  (format "Report: %s\n" report) ""))
            (if reply-to
                (format "Reply: emacs-agent send --to %s --type answer --subject \"...\"\n"
                        reply-to)
              "Reply: the sender's terminal is not live here; nothing to reply to.\n"))))

(defun bp/agent-orchestration--format-messages (messages)
  (concat (format "messages: %d\n" (length messages))
          (mapconcat #'bp/agent-orchestration--format-message messages "\n")))

;;;; Delivery into a resting terminal

(defun bp/agent-orchestration--receptive-p (session)
  "Non-nil when SESSION can be handed a message right now.

Two conditions, and both are stated as what they exclude, because the
alternative — enumerating the states that are fine — has already been wrong
once: `needs-attention' becomes `stopped' as soon as the user looks at the
terminal (`bp/agent-session--clear-attention-on-focus'), which silently ended
delivery to exactly the session an orchestrator is most likely to be watching.

- Not mid-turn.  `running' is the only status that means a turn is in progress;
  anything else is an agent sitting at its prompt, however it got there.
- Something holds the terminal's foreground.  Nil there means the shell's own
  prompt is in front, and a paste plus Enter would not reach a TUI at all — the
  *shell* would run the message as a command line.  That is not merely untidy:
  a message body is written by another agent, and executing it is a hazard the
  queue does not have.  Mail for a bare shell therefore stays queued for
  `emacs-agent check', which is the right way to read it anyway."
  (let ((buf (plist-get session :buffer)))
    (and (not (eq (plist-get session :status) 'running))
         (buffer-live-p buf)
         (bp/agent-sessions--foreground-command buf)
         t)))

(defun bp/agent-orchestration--codex-session-p (session)
  "Non-nil when SESSION is a Codex conversation with a durable id."
  (and (equal (downcase (format "%s" (plist-get session :agent-type))) "codex")
       (let ((sid (plist-get session :agent-session-id)))
         (and (stringp sid) (not (string-empty-p sid))))))

(defun bp/agent-orchestration--codex-empty-prompt-p (session)
  "Non-nil when SESSION visibly has Codex's empty idle composer.
Only inspect the bottom four buffer lines.  An older prompt in terminal
scrollback must not make a running conversation look receptive, and a nonempty
human draft deliberately does not match."
  (let ((buf (plist-get session :buffer)))
    (and (buffer-live-p buf)
         (with-current-buffer buf
           (save-restriction
             (widen)
             (goto-char (point-max))
             (when (re-search-backward
                    bp/agent-orchestration-codex-empty-prompt-regexp nil t)
               (<= (count-lines (line-beginning-position) (point-max)) 4)))))))

(defun bp/agent-orchestration--claude-session-p (session)
  "Non-nil when SESSION is a Claude conversation."
  (equal (downcase (format "%s" (plist-get session :agent-type))) "claude"))

(defun bp/agent-orchestration--claude-normalize-prompt (text)
  "Normalize Claude prompt TEXT for rendered-versus-submitted comparison."
  (string-trim
   (replace-regexp-in-string "[[:space:]\u00a0]+" " " text)))

(defun bp/agent-orchestration--face-inherits-p (face parent)
  "Non-nil when FACE names or inherits from PARENT."
  (cond
   ((eq face parent) t)
   ((and (listp face) (keywordp (car face)))
    (bp/agent-orchestration--face-inherits-p
     (plist-get face :inherit) parent))
   ((listp face)
    (seq-some (lambda (item)
                (bp/agent-orchestration--face-inherits-p item parent))
              face))))

(defun bp/agent-orchestration--claude-ghost-completion-p (text)
  "Non-nil when every non-whitespace character in TEXT is Claude ghost text.
Claude renders its Tab completion with the terminal's ANSI faint face.  A
typed prefix is not faint, so a partially accepted or edited completion remains
a real draft rather than becoming eligible for mail delivery."
  (let ((pos 0)
        (end (length text))
        saw-text
        (all-faint t))
    (while (and all-faint (< pos end))
      (let* ((next (next-property-change pos text end))
             (chunk (substring-no-properties text pos next)))
        (unless (string-match-p "\\`[[:space:]\u00a0]*\\'" chunk)
          (setq saw-text t)
          (unless (or (bp/agent-orchestration--face-inherits-p
                       (get-text-property pos 'face text) 'eat-term-faint)
                      (bp/agent-orchestration--face-inherits-p
                       (get-text-property pos 'font-lock-face text)
                       'eat-term-faint))
            (setq all-faint nil)))
        (setq pos next)))
    (and saw-text all-faint)))

(defun bp/agent-orchestration--claude-composer-text (session)
  "Return SESSION's visibly rendered Claude composer text, or nil if unknown.
Claude renders the current input between a line beginning with its `❯' prompt
and a horizontal separator.  Inspect only the most recent prompt near the end
of the terminal buffer."
  (let ((buf (plist-get session :buffer)))
    (and (buffer-live-p buf)
         (with-current-buffer buf
           (save-restriction
             (widen)
             (goto-char (point-max))
             (when (re-search-backward
                    "^❯[ \t\u00a0]*" (max (point-min) (- (point-max) 4000)) t)
               (let ((input-start (match-end 0)))
                 (and (re-search-forward "^─+[ \t]*$" nil t)
                      ;; Preserve terminal faces: Claude's inline completion is
                      ;; distinguishable from typed input by its ANSI faint
                      ;; styling even though both occupy the composer visually.
                      (buffer-substring
                       input-start (match-beginning 0))))))))))

(defun bp/agent-orchestration--claude-receptive-composer-p (session)
  "Non-nil when SESSION's Claude composer can safely receive agent mail.
An empty composer is receptive, as is an all-faint inline completion that has
not been accepted.  Claude also retains the last submitted text in the input
box during redraws and sometimes after a turn; that exact text is receptive too
because `UserPromptSubmit' proves it is no longer a draft.  Anything
unrecognized, non-faint, or changed from the submitted prompt is treated as a
live human draft and left untouched."
  (let* ((visible (bp/agent-orchestration--claude-composer-text session))
         (submitted (plist-get session :submitted-prompt))
         (normalized-visible
          (and (stringp visible)
               (bp/agent-orchestration--claude-normalize-prompt visible))))
    (and normalized-visible
         (or (string-empty-p normalized-visible)
             (bp/agent-orchestration--claude-ghost-completion-p visible)
             (and (stringp submitted)
                  (equal normalized-visible
                         (bp/agent-orchestration--claude-normalize-prompt
                          submitted)))))))

(defun bp/agent-orchestration--terminal-input (buf string)
  "Send raw terminal input STRING to BUF without paste handling or Enter."
  (with-current-buffer buf
    (cond
     ((derived-mode-p 'vterm-mode) (vterm-send-string string))
     ((derived-mode-p 'eat-mode) (eat-term-send-string eat-terminal string))
     (t (user-error "Current buffer is not an Eat or vterm terminal")))))

(defun bp/agent-orchestration--call-with-timeout (program args timeout)
  "Run PROGRAM with ARGS, returning its exit status within TIMEOUT seconds.
Process output goes to the current buffer.  Return nil after an error or
timeout, inserting the diagnostic into that buffer.  Unlike `process-file',
this cannot freeze Emacs indefinitely if a native queue client gets stuck."
  (let (process timed-out)
    (condition-case err
        (unwind-protect
            (progn
              (setq process
                    (make-process
                     :name (generate-new-buffer-name "agent-sessions-native-queue")
                     :buffer (current-buffer)
                     :command (cons program args)
                     :connection-type 'pipe
                     :noquery t))
              (let ((deadline (+ (float-time) timeout)))
                (while (and (process-live-p process)
                            (< (float-time) deadline))
                  (accept-process-output
                   process (min 0.1 (max 0 (- deadline (float-time))))))
                (when (process-live-p process)
                  (setq timed-out t)
                  (delete-process process)))
              (if timed-out
                  (progn (insert (format "timed out after %ss" timeout)) nil)
                (process-exit-status process)))
          (when (and process (process-live-p process))
            (delete-process process)))
      (error
       (insert (error-message-string err))
       nil))))

(defun bp/agent-orchestration--codex-queue (session messages)
  "Queue MESSAGES into running Codex SESSION; return non-nil when accepted.
Use Codex's session-aware command rather than writing into a busy terminal.
Failure deliberately leaves the messages unread for idle delivery or an
explicit inbox check."
  (let ((program (executable-find "codex"))
        (sid (plist-get session :agent-session-id)))
    (when (and program sid)
      (with-temp-buffer
        (let* ((text
                (concat "$orca (/orca) agent mail arrived.\n\n"
                        (bp/agent-orchestration--format-messages messages)))
               (status
                (bp/agent-orchestration--call-with-timeout
                 program (list "queue" "--thread" sid "--message" text)
                 bp/agent-orchestration--native-queue-timeout)))
          (if (and (integerp status) (zerop status))
              t
            (message "agent-sessions: could not queue Codex mail for %s%s"
                     sid
                     (let ((detail (string-trim (buffer-string))))
                       (if (string-empty-p detail) "" (format " (%s)" detail))))
            nil))))))

(defun bp/agent-orchestration--claude-submit-mail (buf)
  "Queue the prepared agent-mail prompt in Claude BUF."
  (when (buffer-live-p buf)
    (bp/agent-orchestration--terminal-input
     buf bp/agent-orchestration-claude-queue-submit-key)))

(defun bp/agent-orchestration--claude-paste-mail (buf text)
  "Paste agent-mail TEXT into the now-empty composer in Claude BUF."
  (when (buffer-live-p buf)
    (bp/agent-sessions--terminal-paste buf text)
    (run-at-time bp/agent-orchestration--submit-delay nil
                 #'bp/agent-orchestration--claude-submit-mail buf)))

(defun bp/agent-orchestration--claude-queue (session messages)
  "Queue MESSAGES in Claude SESSION after its composer becomes available.
Claude Code has no session-addressed queue command.  The caller must establish
that the composer is empty, or that `UserPromptSubmit' has just reported the
human's draft submitted.  Delay the paste once so Claude can clear a freshly
submitted prompt, then use its `chat:queueSubmit' action."
  (let ((buf (plist-get session :buffer)))
    (when (buffer-live-p buf)
      (run-at-time
       bp/agent-orchestration--submit-delay nil
       #'bp/agent-orchestration--claude-paste-mail buf
       (concat "$orca (/orca) agent mail arrived.\n\n"
               (bp/agent-orchestration--format-messages messages)))
      t)))

(defun bp/agent-orchestration--paste (buf text)
  "Paste TEXT into BUF's terminal as one bracketed paste, then submit it.
Bracketed paste rather than plain input because a TUI submits on every newline
it is *typed*, which would fire the agent's turn on the message's first line and
feed it the rest as separate prompts."
  (bp/agent-sessions--terminal-paste buf text)
  ;; The buffer travels as a timer argument, not in a closure: this file is
  ;; loaded with dynamic binding, so a lambda over `buf' would find it void
  ;; when the timer fires (the same reason `bp/agent-sessions-restore' passes
  ;; its row this way).
  (run-at-time
   bp/agent-orchestration--submit-delay nil
   (lambda (target)
     (when (buffer-live-p target)
       (with-current-buffer target
         (pcase bp/agent-sessions-terminal
           ('vterm (vterm-send-return))
           ('eat (eat-term-send-string eat-terminal "\r"))))))
   buf))

;;; Sending selected text to an agent

(defun bp/agent-sessions--prompt-agent-p (entry)
  "Non-nil when ENTRY names a live Claude or Codex terminal.
The foreground-process check is important: a registry row survives an agent
exiting back to its shell, where submitting prose would execute it as a shell
command instead of sending it to an agent."
  (let* ((session (plist-get entry :session))
         (buf (plist-get session :buffer))
         (agent (downcase (format "%s" (plist-get session :agent-type))))
         (foreground (and (buffer-live-p buf)
                          (bp/agent-sessions--foreground-command buf))))
    (and foreground
         (not (equal (plist-get session :last-event) "SessionEnd"))
         (or (member agent '("claude" "codex" "pi"))
             (member (downcase foreground) '("claude" "codex" "pi"))))))

(defun bp/agent-sessions--prompt-entry-viewed-at (entry)
  "Return when ENTRY's terminal was most recently selected, or nil."
  (let ((buf (plist-get (plist-get entry :session) :buffer)))
    (and (buffer-live-p buf)
         (buffer-local-value 'bp/agent-session--viewed-at buf))))

(defun bp/agent-sessions--sort-prompt-entries (entries)
  "Return promptable ENTRIES ordered by most recently viewed terminal."
  (sort (copy-sequence entries)
        (lambda (a b)
          (let ((ta (bp/agent-sessions--prompt-entry-viewed-at a))
                (tb (bp/agent-sessions--prompt-entry-viewed-at b)))
            (cond ((and ta tb (not (time-equal-p ta tb))) (time-less-p tb ta))
                  (ta t)
                  ((bp/agent-sessions--entry-created a)
                   (if (bp/agent-sessions--entry-created b)
                       (time-less-p (bp/agent-sessions--entry-created b)
                                    (bp/agent-sessions--entry-created a))
                     t))
                  ((bp/agent-sessions--entry-created b) nil)
                  (t (string< (bp/agent-sessions--entry-buffer-name a)
                              (bp/agent-sessions--entry-buffer-name b))))))))

(defun bp/agent-sessions--entry-shared-file (entry truename)
  "Return ENTRY's shared-file record for TRUENAME, or nil."
  (seq-find
   (lambda (file)
     (equal (ignore-errors (file-truename (plist-get file :path))) truename))
   (bp/agent-sessions--session-files (plist-get entry :session))))

(defun bp/agent-sessions--prompt-entries (source-file)
  "Return live agent entries in picker order for SOURCE-FILE.
The agent that most recently shared SOURCE-FILE comes first.  Every remaining
agent is ordered by when the user last viewed its terminal."
  (let* ((entries (bp/agent-sessions--sort-prompt-entries
                   (seq-filter #'bp/agent-sessions--prompt-agent-p
                               (bp/agent-sessions--live-entries))))
         (truename (and source-file (file-truename source-file)))
         owner owner-updated)
    (when truename
      (dolist (entry entries)
        (when-let ((file (bp/agent-sessions--entry-shared-file entry truename)))
          (let ((updated (plist-get file :updated-at)))
            (when (or (null owner)
                      (> (or updated 0) (or owner-updated 0)))
              (setq owner entry owner-updated updated))))))
    (if owner
        (cons owner (delq owner entries))
      entries)))

(defun bp/agent-sessions--prompt-entry-label (entry)
  "Return a unique, human-readable completion label for ENTRY."
  (let* ((session (plist-get entry :session))
         (buf (plist-get session :buffer)))
    (format "%s — %s"
            (buffer-name buf)
            (bp/agent-sessions--session-label session))))

(defun bp/agent-sessions--region-prompt (remark selection source beg end)
  "Combine REMARK and SELECTION with their SOURCE location.
BEG and END are the selected buffer positions."
  (let ((where (if source
                   (format "%s, lines %d-%d"
                           (abbreviate-file-name source)
                           (line-number-at-pos beg)
                           (line-number-at-pos (max beg (1- end))))
                 (format "buffer %s, lines %d-%d"
                         (buffer-name)
                         (line-number-at-pos beg)
                         (line-number-at-pos (max beg (1- end)))))))
    (concat (unless (string-empty-p remark) (concat remark "\n\n"))
            (format "Selected text from %s:\n\n" where)
            selection)))

;;;###autoload
(defun bp/agent-sessions-send-region (beg end)
  "Prompt for a remark and send it with the active region to an agent.
When the current file was shared through the agent dashboard, its sharing
agent is the default choice.  Other live Claude/Codex agents are offered in
most-recently-viewed order."
  (interactive
   (if (use-region-p)
       (list (region-beginning) (region-end))
     (user-error "Select some text first")))
  (let* ((source buffer-file-name)
         (selection (buffer-substring-no-properties beg end))
         (entries (bp/agent-sessions--prompt-entries source)))
    (unless entries
      (user-error "No live Claude or Codex agents are available"))
    (let* ((candidates
            (mapcar (lambda (entry)
                      (cons (bp/agent-sessions--prompt-entry-label entry) entry))
                    entries))
           ;; Keep the ownership/recency ordering in completion UIs that honor
           ;; standard completion metadata.
           (completion-extra-properties
            '(:display-sort-function identity :cycle-sort-function identity))
           (choice (completing-read "Send region to agent: "
                                    (mapcar #'car candidates) nil t nil nil
                                    (caar candidates)))
           (entry (cdr (assoc choice candidates)))
           (remark (read-string "Question or remark: "))
           (text (bp/agent-sessions--region-prompt
                  remark selection source beg end))
           (buf (plist-get (plist-get entry :session) :buffer)))
      (unless (and (buffer-live-p buf)
                   (bp/agent-sessions--foreground-command buf))
        (user-error "The selected agent is no longer running"))
      (bp/agent-orchestration--paste buf text)
      (message "Sent selected text to %s" (buffer-name buf)))))

(defun bp/agent-orchestration-deliver (id &optional user-prompt-submitted)
  "Hand ID's pending mail to its agent when safe; return the delivery method.
The result is `delivered' for a generic idle-terminal paste, `queued' for an
agent-specific queue, and nil when mail remains unread.  Called both on arrival
and from the hook path.  USER-PROMPT-SUBMITTED means this call handles a
`UserPromptSubmit' event, so Claude mail withheld behind a human draft can now
be queued.  Terminal delivery consumes before its asynchronous keystrokes to
stay idempotent; Codex consumes only after its CLI acknowledges ownership."
  (when bp/agent-orchestration-push-when-idle
    (let* ((session (bp/agent-sessions--session-for-id id))
           (buf (and session (plist-get session :buffer)))
           (pending (and session (bp/agent-orchestration--pending id))))
      (cond
       ;; An interrupted Codex turn does not fire Stop, so our hook status can
       ;; still say `running' while the TUI is visibly back at its empty prompt.
       ;; Codex accepts native queue writes in that state but intentionally does
       ;; not dispatch them.  Bypass the native queue only for the empty
       ;; composer: a human draft must remain untouched.
       ((and pending
             (bp/agent-orchestration--codex-session-p session)
             (bp/agent-orchestration--codex-empty-prompt-p session))
        (bp/agent-orchestration--consume pending)
        (bp/agent-orchestration--paste
         buf (concat "$orca (/orca) agent mail arrived while you were idle.\n\n"
                     (bp/agent-orchestration--format-messages pending)))
        (bp/agent-sessions--refresh-if-visible)
        'delivered)
       ((and pending
             (bp/agent-orchestration--codex-session-p session)
             (or (not (eq (plist-get session :status) 'running))
                 (seq-some
                  (lambda (message)
                    (member (plist-get message :type)
                            bp/agent-orchestration-actionable-message-types))
                  pending)))
        ;; This branch owns Codex delivery even when the command fails.  Do not
        ;; fall through to terminal paste: preserving the human's draft is more
        ;; important than immediate delivery, and the unread record is safe.
        (when (bp/agent-orchestration--codex-queue session pending)
          (bp/agent-orchestration--consume pending)
          (bp/agent-sessions--refresh-if-visible)
          'queued))
       ((and pending
             (bp/agent-orchestration--claude-session-p session)
             (buffer-live-p buf)
             (bp/agent-sessions--foreground-command buf))
        ;; This branch owns Claude delivery even when it deliberately waits,
        ;; preventing the generic idle paste below from absorbing a draft.
        (when (and
               (or user-prompt-submitted
                   (bp/agent-orchestration--claude-receptive-composer-p session))
               (bp/agent-orchestration--claude-queue session pending))
          (bp/agent-orchestration--consume pending)
          (bp/agent-sessions--refresh-if-visible)
          'queued))
       ((and pending (buffer-live-p buf)
             (bp/agent-orchestration--receptive-p session))
        (bp/agent-orchestration--consume pending)
        (bp/agent-orchestration--paste
         buf (concat "$orca (/orca) agent mail arrived while you were idle.\n\n"
                     (bp/agent-orchestration--format-messages pending)))
        (bp/agent-sessions--refresh-if-visible)
        'delivered)))))

;;;; The worker brief

(defun bp/agent-orchestration--worker-preamble (coordinator-id task)
  "The protocol a spawned worker is launched with, followed by TASK."
  (format "You are a worker agent in an Emacs-managed terminal, dispatched by another
agent — your coordinator.  You were started with this file as your prompt.

  Your terminal id   $EMACS_AGENT_SESSION_ID   (`emacs-agent' reads it for you)
  Your coordinator   %s                        (also $EMACS_AGENT_COORDINATOR)
  Your worktree      the directory this shell started in

=== HOW YOU REPORT ===

`emacs-agent' is on your PATH; `emacs-agent guide' prints the full reference.
It is your only channel to the coordinator — do not try to reach a human
through Slack, a PR comment, or anything else during the run.

  # REQUIRED when you finish, including when you fail or give up.  Send it
  # exactly once.  --summary is three sentences: what you did, what you found,
  # what is left.
  emacs-agent done --summary \"...\" [--files a.el,b.el] [--report path/to/notes.md]

  # Blocked on a decision only the coordinator can make.  Blocks until it
  # answers and prints the answer.
  emacs-agent ask --question \"...\" [--timeout 600]

  # A progress note, when there is something worth knowing mid-task.  Optional.
  emacs-agent send --type status --subject \"...\" --body \"...\"

RULES

- Never ask a question through an interactive prompt (no AskUserQuestion, no
  reading stdin).  Your coordinator is another agent and cannot see a TUI
  prompt; your turn would hang until a human noticed.  Use `emacs-agent ask'.
- Failure is still a `done', with a subject that says so.  Never exit silently.
- After `done', end your turn and sit at your prompt.  Do not poll for more
  work and do not start something unrelated; further work arrives as new input.
  Reply to that later mail with the `Reply:' command it includes, which sends an
  `answer' rather than a second `done'.
- You may be sharing this worktree with other workers.  Touch only the files
  your task names, and leave git state alone — no `git add', `commit',
  `checkout', `rebase' or `stash' — unless the task says this worktree is
  yours.  The index and HEAD are shared by everyone in a worktree, so staging
  anything would clobber a co-tenant's work in progress.
- `emacs-share file FILE \"why\"' hands a file to the human in the dashboard.
  That is for the human, and is not a substitute for reporting `done'.

=== YOUR TASK ===

%s"
          coordinator-id (string-trim task)))

(defun bp/agent-orchestration--write-brief (coordinator-id task)
  "Write the brief for TASK to a file and return its path."
  (make-directory bp/agent-orchestration--brief-dir t)
  (let ((path (expand-file-name
               (format "%s-%s.md" coordinator-id
                       (bp/agent-orchestration--next-id "brief"))
               bp/agent-orchestration--brief-dir)))
    (with-temp-file path
      (insert (bp/agent-orchestration--worker-preamble coordinator-id task)))
    path))

;;;; Entry points (called from `bin/emacs-agent')

(defcustom bp/agent-orchestration-trust-new-worktrees t
  "When non-nil, register a spawn's directory as trusted with the agent first.
Both agent CLIs stop at an interactive trust prompt the first time they run in
a directory they have not seen (\"Do you trust the contents of this
directory?\"), and a worker stopped there never reads its brief — so an
orchestrator spawning into a worktree it just created would sit waiting for a
report that cannot come.  Registering the directory up front is what makes an
unattended spawn possible.

The cost is real and worth stating: any directory an orchestrator spawns into
becomes trusted for that agent from then on.  Set this to nil to leave both
configs alone and approve each new directory by hand instead — `spawn' then
says which worker is waiting on you."
  :type 'boolean)

(defcustom bp/agent-orchestration-claude-config-file
  (expand-file-name "~/.claude.json")
  "Claude Code's own config, where per-directory trust is recorded."
  :type 'file)

(defcustom bp/agent-orchestration-codex-config-file
  (expand-file-name "~/.codex/config.toml")
  "Codex's config, where per-directory trust is recorded."
  :type 'file)

(defun bp/agent-orchestration--trust-claude (dir)
  "Record DIR as trusted in Claude Code's config; nil when it already was.
Reads and rewrites through this package's own JSON helpers, so everything else
in that file (it holds the user's whole Claude state) round-trips untouched and
a `.bak' is left behind.  Only written when something actually changes: live
Claude sessions rewrite this file themselves, and every needless write of ours
is another chance to land between one of their reads and writes."
  (let* ((file bp/agent-orchestration-claude-config-file)
         (config (bp/agent-sessions--read-json file))
         (projects (or (gethash "projects" config) (make-hash-table :test 'equal)))
         (entry (or (gethash dir projects) (make-hash-table :test 'equal))))
    (unless (eq (gethash "hasTrustDialogAccepted" entry) t)
      (puthash "hasTrustDialogAccepted" t entry)
      (puthash dir entry projects)
      (puthash "projects" projects config)
      (bp/agent-sessions--write-json file config)
      (format "pre-trusted %s for claude" (abbreviate-file-name dir)))))

(defun bp/agent-orchestration--trust-codex (dir)
  "Record DIR as trusted in Codex's config; nil when it already had an entry.
Appends a `[projects.\"DIR\"]' table rather than parsing the file: a new table
header is always a legal thing to add at the end of a TOML file, and there is
no TOML reader here that could round-trip the rest of it safely.  An existing
entry is left exactly as it is, even if it says untrusted — that would be the
user's own decision about this directory."
  (let* ((file bp/agent-orchestration-codex-config-file)
         (header (format "[projects.\"%s\"]" dir))
         (existing (and (file-exists-p file)
                        (with-temp-buffer
                          (insert-file-contents file)
                          (buffer-string)))))
    (unless (and existing (string-search header existing))
      (when (file-exists-p file) (copy-file file (concat file ".bak") t))
      (make-directory (file-name-directory file) t)
      (with-temp-buffer
        (when existing
          (insert existing)
          (unless (string-suffix-p "\n" existing) (insert "\n")))
        (insert (format "\n%s\ntrust_level = \"trusted\"\n" header))
        (write-region (point-min) (point-max) file nil 'quiet))
      (format "pre-trusted %s for codex" (abbreviate-file-name dir)))))

(defun bp/agent-orchestration--ensure-trusted (agent dir)
  "Make AGENT trust DIR before it is launched there.  Returns a note or nil.
The path is canonicalised because that is what the agent's own process will
see: on macOS a spawn into `/tmp/x' runs in `/private/tmp/x', and a trust entry
under the other spelling would not match.  A config we cannot read is reported
rather than raised: a spawn that works and warns beats a spawn that fails."
  (when bp/agent-orchestration-trust-new-worktrees
    (let ((path (directory-file-name (file-truename dir))))
      (condition-case err
          (pcase agent
            ('claude (bp/agent-orchestration--trust-claude path))
            ('codex (bp/agent-orchestration--trust-codex path))
            ;; A type the user added themselves: we have no idea where it keeps
            ;; trust, so say nothing rather than guess.
            (_ nil))
        (error (format "could not pre-trust %s for %s (%s) — the worker may be sitting at a trust prompt"
                       (abbreviate-file-name path) agent
                       (error-message-string err)))))))

(defcustom bp/agent-orchestration-claude-skills-dir
  (expand-file-name "~/.claude/skills/")
  "Where Claude Code looks for personal skills."
  :type 'directory)

(defcustom bp/agent-orchestration-codex-skills-dir
  (expand-file-name "~/.codex/skills/")
  "Where Codex looks for skills, in the same `<name>/SKILL.md' layout Claude uses."
  :type 'directory)

(defcustom bp/agent-orchestration-codex-prompts-dir
  (expand-file-name "~/.codex/prompts/")
  "Where Codex looks for custom prompts, each usable as `/<name>'."
  :type 'directory)

(defconst bp/agent-orchestration--skill-name "orca"
  "Name the skill is invoked by: `/orca', or `/orca --main' to coordinate.")

(defun bp/agent-orchestration--skill-dir ()
  (expand-file-name (format "skills/%s/" bp/agent-orchestration--skill-name)
                    bp/agent-sessions--dir))

(defun bp/agent-orchestration--link (target link)
  "Point LINK at TARGET, returning a string describing what happened.
Symlinks rather than copies so editing the guide in this package takes effect
at the agent's next invocation; and refuses to replace anything that is not
already our own link, because both directories belong to the user."
  (cond
   ((and (file-symlink-p link)
         (equal (file-truename link) (file-truename target)))
    (format "%s already linked" (abbreviate-file-name link)))
   ((or (file-exists-p link) (file-symlink-p link))
    (if (file-symlink-p link)
        (progn (delete-file link)
               (make-symbolic-link target link)
               (format "%s relinked" (abbreviate-file-name link)))
      (format "%s exists and is not a symlink — left alone"
              (abbreviate-file-name link))))
   (t
    (make-directory (file-name-directory link) t)
    (make-symbolic-link target link)
    (format "%s linked" (abbreviate-file-name link)))))

;;;###autoload
(defun bp/agent-orchestration-install-skill ()
  "Make the orchestration skill loadable by Claude Code and Codex as `/orca'.
Links this package's `skills/orca' into every directory the two tools read:
both skill directories, and Codex's prompts directory so `/orca' works there
as a slash command too.  The guides themselves are served by `emacs-agent
guide', so what is installed is a stub that cannot go stale.  Idempotent."
  (interactive)
  (let* ((dir (bp/agent-orchestration--skill-dir))
         (results
          (list
           (bp/agent-orchestration--link
            (directory-file-name dir)
            (expand-file-name bp/agent-orchestration--skill-name
                              bp/agent-orchestration-claude-skills-dir))
           (bp/agent-orchestration--link
            (directory-file-name dir)
            (expand-file-name bp/agent-orchestration--skill-name
                              bp/agent-orchestration-codex-skills-dir))
           (bp/agent-orchestration--link
            (expand-file-name "orca-prompt.md" dir)
            (expand-file-name (format "%s.md" bp/agent-orchestration--skill-name)
                              bp/agent-orchestration-codex-prompts-dir)))))
    (unless (file-directory-p dir)
      (error "agent-sessions: missing skill directory %s" dir))
    (unless (server-running-p) (server-start))
    (message "agent-sessions: %s" (string-join results "; "))))

(defun bp/agent-orchestration--model-flag (agent model)
  "Render MODEL as AGENT's model flag, nil when MODEL is empty.
Returns the symbol `unsupported' when a model was asked for and AGENT has no
spelling for one — the caller refuses the spawn rather than launching a worker
on a model nobody chose."
  (let ((model (string-trim (or model ""))))
    (cond
     ((string-empty-p model) nil)
     ((alist-get agent bp/agent-orchestration-model-flags)
      (format (alist-get agent bp/agent-orchestration-model-flags)
              (shell-quote-argument model)))
     (t 'unsupported))))

(defun bp/agent-orchestration--launch-command (template brief model-flag)
  "Render TEMPLATE into the shell line that launches a worker on BRIEF.
MODEL-FLAG is the already-spelled flag or nil.  A template carrying neither
`%b' nor `%m' is the pre-model single-`%s' form and is rendered as such, so an
old customisation keeps working."
  (let ((quoted (shell-quote-argument brief)))
    (if (string-match-p "%[bm]" template)
        (format-spec template `((?b . ,quoted) (?m . ,(or model-flag ""))))
      (format template quoted))))

(defun bp/agent-orchestration--mark-worker (buf coordinator-id coordinator title)
  "Attach BUF to COORDINATOR-ID as a worker and give it TITLE."
  (let ((parent-sid (plist-get coordinator :agent-session-id)))
    (with-current-buffer buf
      (when parent-sid
        (setq-local bp/agent-session--branched-from
                    (cons parent-sid
                          (bp/agent-sessions--session-short-label coordinator))))
      (setq-local bp/agent-orchestration-coordinator coordinator-id)
      (when (and title (not (string-empty-p title)))
        (setq-local bp/agent-session-title-override title)))))

(defun bp/agent-orchestration-spawn (coordinator-id type worktree task
                                                    &optional title model)
  "Start a TYPE agent in WORKTREE on TASK, dispatched by COORDINATOR-ID.
MODEL, when given, is the model name to launch that agent on, spelled into its
command line by `bp/agent-orchestration-model-flags'.
Returns a string to print.  WORKTREE must already exist: allocating checkouts
is the orchestrator's job, not this package's, so that nothing here can leave a
stray worktree or branch behind."
  (let* ((coordinator (bp/agent-sessions--session-for-id coordinator-id))
         (agent (and type (not (string-empty-p type)) (intern type)))
         (template (and agent (alist-get agent bp/agent-orchestration-launch-commands)))
         (model (string-trim (or model "")))
         (model-flag (and agent (bp/agent-orchestration--model-flag agent model)))
         (dir (and worktree (not (string-empty-p worktree))
                   (file-name-as-directory (expand-file-name worktree)))))
    (cond
     ((null coordinator)
      (format "No Emacs terminal registered for session id %s" coordinator-id))
     ((null template)
      (format "Unknown agent type `%s'; known types: %s" type
              (mapconcat (lambda (cell) (symbol-name (car cell)))
                         bp/agent-orchestration-launch-commands ", ")))
     ((eq model-flag 'unsupported)
      (format "Agent type `%s' has no --model flag configured; types that take one: %s"
              type
              (if bp/agent-orchestration-model-flags
                  (mapconcat (lambda (cell) (symbol-name (car cell)))
                             bp/agent-orchestration-model-flags ", ")
                "none")))
     ((and model-flag (not (string-match-p "%m" template)))
      (format "The launch command for `%s' has no `%%m' for a model flag: %s"
              type template))
     ((or (null dir) (not (file-directory-p dir)))
      (format "No such worktree directory: %s (create it first, or pass one from `emacs-agent worktrees')"
              (or worktree "")))
     ((string-empty-p (string-trim (or task "")))
      "Refusing to spawn a worker with an empty --task")
     (t
      (let* ((trust-note (bp/agent-orchestration--ensure-trusted agent dir))
             (brief (bp/agent-orchestration--write-brief coordinator-id task))
             (label (if (and title (not (string-empty-p (string-trim title))))
                        (string-trim title)
                      (bp/agent-orchestration--task-title task)))
             ;; `--create-terminal' shows the new terminal in another window,
             ;; which is right when the user pressed `+' and wrong when an agent
             ;; spawned three workers in a row: the layout the user is reading
             ;; must not be rearranged by a background action.  The buffer and
             ;; its process outlive the restored configuration.
             (buf (save-window-excursion
                    (let ((bp/agent-sessions--extra-terminal-env
                           (list "EMACS_AGENT_ROLE=worker"
                                 (format "EMACS_AGENT_COORDINATOR=%s" coordinator-id)
                                 (format "EMACS_AGENT_TASK_BRIEF=%s" brief))))
                      (bp/agent-sessions--create-terminal
                       dir (plist-get (bp/agent-session--repo-info dir) :worktree))))))
        (if (not (buffer-live-p buf))
            "Could not create a terminal for the worker"
          (let ((worker-id (buffer-local-value 'bp/agent-session-id buf)))
            (bp/agent-orchestration--mark-worker
             buf coordinator-id coordinator label)
            (bp/agent-sessions--terminal-send
             buf (bp/agent-orchestration--launch-command template brief model-flag))
            (bp/agent-sessions--refresh-if-visible)
            (format "Spawned %s (%s) in %s\nTask: %s\nBrief: %s%s"
                    worker-id
                    (if (string-empty-p model) type (format "%s, %s" type model))
                    (abbreviate-file-name dir) label brief
                    (if trust-note (concat "\nNote: " trust-note) "")))))))))

(defun bp/agent-orchestration--logged-recipient (value &optional by-agent-session)
  "Return the most recent resumable session matching VALUE.
Match an agent session id when BY-AGENT-SESSION is non-nil, otherwise a
terminal id."
  (when-let ((row (car (sqlite-select
                        (bp/agent-sessions--db)
                        (concat
                         "SELECT agent_type, agent_sid, worktree, title
                           FROM sessions
                          WHERE " (if by-agent-session "agent_sid" "emacs_sid") " = ?
                            AND agent_type IS NOT NULL
                            AND agent_sid IS NOT NULL
                          ORDER BY opened_at DESC, id DESC
                          LIMIT 1")
                        (list value)))))
    (pcase-let ((`(,agent-type ,agent-sid ,worktree ,title) row))
      (list :agent-type agent-type :agent-session-id agent-sid
            :worktree worktree :worktree-path worktree :title title))))

(defun bp/agent-orchestration--link-recipient (address)
  "Return resumable session metadata encoded by agent-session ADDRESS."
  (when (string-prefix-p "agent-session:" address)
    (pcase (bp/agent-sessions--parse-session-link address)
      (`(,agent ,session-id ,worktree)
       (list :agent-type agent :agent-session-id session-id
             :worktree worktree :worktree-path worktree)))))

(defun bp/agent-orchestration--live-session-recipient (session-id)
  "Resolve agent SESSION-ID to (TERMINAL-ID SESSION nil), or nil."
  (when-let* ((buf (bp/agent-sessions--buffer-for-agent-session session-id))
              (id (buffer-local-value 'bp/agent-session-id buf))
              (session (bp/agent-sessions--session-for-id id)))
    (list id session nil)))

(defun bp/agent-orchestration--resumable-recipient (address recipient)
  "Resolve RECIPIENT metadata to a live terminal or revival from ADDRESS."
  (when recipient
    (let ((key (bp/agent-orchestration--mail-key address recipient)))
      (if-let ((current (bp/agent-orchestration--live-id-for-key key)))
          (list current (bp/agent-sessions--session-for-id current) nil)
        (list address recipient t)))))

(defun bp/agent-orchestration--resolve-recipient (address)
  "Resolve ADDRESS to (CURRENT-ID SESSION REVIVE-P), or nil.
ADDRESS may be a terminal id, raw agent session id, or `agent-session:' link."
  (or (when-let ((session (bp/agent-sessions--session-for-id address)))
        (list address session nil))
      (when-let ((link (bp/agent-orchestration--link-recipient address)))
        (or (bp/agent-orchestration--live-session-recipient
             (plist-get link :agent-session-id))
            (bp/agent-orchestration--resumable-recipient address link)))
      (bp/agent-orchestration--live-session-recipient address)
      (bp/agent-orchestration--resumable-recipient
       address (bp/agent-orchestration--logged-recipient address))
      (bp/agent-orchestration--resumable-recipient
       address (bp/agent-orchestration--logged-recipient address t))))

(defun bp/agent-orchestration--revive-recipient
    (coordinator-id coordinator recipient message)
  "Resume RECIPIENT as COORDINATOR-ID's child and submit MESSAGE.
Return the new terminal id."
  (let* ((prompt (concat "$orca (/orca) agent mail revived this session.\n\n"
                         (bp/agent-orchestration--format-message message)))
         (buf (save-window-excursion
                (let ((bp/agent-sessions--extra-terminal-env
                       (list "EMACS_AGENT_ROLE=worker"
                             (format "EMACS_AGENT_COORDINATOR=%s"
                                     coordinator-id))))
                  (bp/agent-session-start
                   (plist-get recipient :worktree-path)
                   (plist-get recipient :agent-type)
                   (plist-get recipient :agent-session-id)
                   prompt))))
         (id (and (buffer-live-p buf)
                  (buffer-local-value 'bp/agent-session-id buf)))
         (title (plist-get recipient :title)))
    (unless id
      (error "Could not create a terminal for the revived session"))
    (bp/agent-orchestration--mark-worker
     buf coordinator-id coordinator title)
    id))

(defun bp/agent-orchestration--store-message (id message)
  "Record MESSAGE in terminal ID's in-memory and durable mailboxes."
  (plist-put message :to id)
  (bp/agent-orchestration--mail-insert message)
  (puthash id (append (bp/agent-orchestration--messages id) (list message))
           bp/agent-orchestration--mail))

(defun bp/agent-orchestration-send (from-id to type subject body files report)
  "Send a message from FROM-ID to TO, reviving a killed recipient if needed."
  (let ((type (if (or (null type) (string-empty-p type)) "status" type))
        (sender (bp/agent-sessions--session-for-id from-id)))
    (cond
     ((null sender)
      (format "No Emacs terminal registered for session id %s" from-id))
     ((not (member type bp/agent-orchestration-message-types))
      (format "Unknown message type `%s'; known types: %s" type
              (string-join bp/agent-orchestration-message-types ", ")))
     ((or (null to) (string-empty-p to))
      "A message needs a --to (an Emacs terminal id)")
     ((or (null subject) (string-empty-p (string-trim subject)))
      "A message needs a --subject")
     (t
      (if-let ((resolved (bp/agent-orchestration--resolve-recipient to)))
          (pcase-let* ((`(,current-id ,recipient ,revive-p) resolved)
                       (msg (list :id (bp/agent-orchestration--next-id "msg")
                                  :from from-id
                                  :from-key (bp/agent-orchestration--mail-key
                                             from-id sender)
                                  :from-label (bp/agent-sessions--session-short-label
                                               sender)
                                  :to current-id
                                  :to-key (bp/agent-orchestration--mail-key
                                           current-id recipient)
                                  :type type :subject (string-trim subject)
                                  :body (or body "") :files (or files "")
                                  :report (or report "")
                                  :sent-at (bp/agent-sessions--now) :read nil)))
            (condition-case err
                (progn
                  (when revive-p
                    (setq current-id
                          (bp/agent-orchestration--revive-recipient
                           from-id sender recipient msg)))
                  (bp/agent-orchestration--store-message current-id msg)
                  (let ((delivery
                         (if revive-p
                             (progn
                               (bp/agent-orchestration--consume (list msg))
                               'revived)
                           (bp/agent-orchestration-deliver current-id))))
                    (bp/agent-sessions--refresh-if-visible)
                    (concat
                     (format "Sent %s to %s" type to)
                     (let ((details nil))
                       (when revive-p
                         (push (format "revived as %s" current-id) details))
                       (when (and (not revive-p) (not (equal current-id to)))
                         (push (format "routed to %s" current-id) details))
                       (pcase delivery
                         ('queued (push "queued into agent" details))
                         ('delivered (push "delivered to idle agent" details)))
                       (if details
                           (format " (%s)" (string-join (nreverse details) "; "))
                         "")))))
              (error (format "Could not send to recipient %s%s: %s"
                             to (if revive-p " while reviving it" "")
                             (error-message-string err)))))
        (format "No live or resumable agent session for recipient %s" to))))))

(defun bp/agent-orchestration-check (id types consume)
  "Return ID's unread mail, marking it read unless CONSUME is nil.
TYPES is a comma-separated filter or nil."
  (if (null (bp/agent-sessions--session-for-id id))
      (format "No Emacs terminal registered for session id %s" id)
    (bp/agent-orchestration--hydrate id)
    (let* ((filter (and types (not (string-empty-p types))
                        (split-string types "," t "[ \t]+")))
           (unknown (seq-remove
                     (lambda (candidate)
                       (member candidate bp/agent-orchestration-message-types))
                     (or filter '()))))
      (if unknown
          (format "Unknown message type(s) in --types: %s" (string-join unknown ", "))
        (let ((pending (bp/agent-orchestration--pending id filter)))
          (when consume (bp/agent-orchestration--consume pending))
          (when pending (bp/agent-sessions--refresh-if-visible))
          (bp/agent-orchestration--format-messages pending))))))

(defun bp/agent-orchestration-wait-check (id types)
  "Consume and return all of ID's mail, stopping on TYPES.
The first output line is `wait: stop', `wait: continue', or `wait: error'.
TYPES only controls the stop decision; every pending message is returned and
consumed in the same snapshot so progress cannot become stale or race a later
terminal message."
  (if (null (bp/agent-sessions--session-for-id id))
      (format "wait: error\nNo Emacs terminal registered for session id %s" id)
    (bp/agent-orchestration--hydrate id)
    (let* ((filter (and types (not (string-empty-p types))
                        (split-string types "," t "[ \t]+")))
           (unknown (seq-remove
                     (lambda (candidate)
                       (member candidate bp/agent-orchestration-message-types))
                     (or filter '())))
           (pending (bp/agent-orchestration--pending id)))
      (if unknown
          (format "wait: error\nUnknown message type(s) in --types: %s"
                  (string-join unknown ", "))
        (let ((stop (and pending
                         (or (null filter)
                             (seq-some (lambda (message)
                                         (member (plist-get message :type) filter))
                                       pending)))))
          (bp/agent-orchestration--consume pending)
          (when pending (bp/agent-sessions--refresh-if-visible))
          (concat (if stop "wait: stop\n" "wait: continue\n")
                  (bp/agent-orchestration--format-messages pending)))))))

(defun bp/agent-orchestration-list (id)
  "Describe the workers ID spawned, and ID's own coordinator if it has one."
  (if (null (bp/agent-sessions--session-for-id id))
      (format "No Emacs terminal registered for session id %s" id)
    (let* ((entries (bp/agent-sessions--live-entries))
           (mine (seq-filter
                  (lambda (entry)
                    (let ((buf (plist-get (plist-get entry :session) :buffer)))
                      (and (buffer-live-p buf)
                           (equal id (buffer-local-value
                                      'bp/agent-orchestration-coordinator buf)))))
                  entries))
           (buf (plist-get (bp/agent-sessions--session-for-id id) :buffer))
           (my-coordinator (and (buffer-live-p buf)
                                (buffer-local-value
                                 'bp/agent-orchestration-coordinator buf))))
      (concat
       (if my-coordinator (format "your coordinator: %s\n" my-coordinator) "")
       (format "workers: %d\n" (length mine))
       (mapconcat
        (lambda (entry)
          (let* ((wid (plist-get entry :id))
                 (session (plist-get entry :session))
                 (unread (bp/agent-orchestration--pending-count wid)))
            (format "%s  %-7s %-15s %s%s\n"
                    wid
                    (plist-get session :agent-type)
                    (plist-get session :status)
                    (or (plist-get entry :title) "")
                    (if (> unread 0) (format "  (%d unread for it)" unread) ""))))
        mine "")))))

(defun bp/agent-orchestration-worktrees (id)
  "List the worktrees of ID's repo with what is running in each.
Reads git rather than the render path's cache: the caller is about to allocate
a worktree, and a cache that predates the last `git worktree add' would hand
out one that is already taken — or hide one that just became available."
  (let ((session (bp/agent-sessions--session-for-id id)))
    (if (null session)
        (format "No Emacs terminal registered for session id %s" id)
      (let* ((root (or (plist-get session :repo-root)
                       (let ((buf (plist-get session :buffer)))
                         (and (buffer-live-p buf)
                              (plist-get (bp/agent-sessions--buffer-repo-info buf)
                                         :repo-root)))))
             (worktrees (and root (bp/agent-sessions--compute-worktrees root)))
             (entries (bp/agent-sessions--live-entries)))
        (if (null worktrees)
            "Not inside a git repository Emacs knows about"
          (concat
           (format "repo: %s\n" (abbreviate-file-name root))
           (mapconcat
            (lambda (wt)
              (let* ((path (plist-get wt :path))
                     (canon (bp/agent-sessions--canonical-path path))
                     (busy (seq-filter
                            (lambda (entry)
                              (equal canon (bp/agent-sessions--canonical-path
                                            (plist-get (plist-get entry :session)
                                                       :worktree-path))))
                            entries))
                     (dirty (let ((default-directory path))
                              (ignore-errors (magit-anything-modified-p)))))
                ;; A count rather than free/busy: several agents can share a
                ;; worktree when their writes do not overlap, so what the
                ;; caller needs is who is there, not our verdict on whether it
                ;; may use the place.
                (format "%-9s %-40s %-28s %-6s%s\n"
                        (format "%d agent%s" (length busy)
                                (if (= (length busy) 1) "" "s"))
                        (abbreviate-file-name path)
                        (plist-get wt :label)
                        (if dirty "dirty" "clean")
                        (if busy
                            (concat "  "
                                    (mapconcat
                                     (lambda (entry)
                                       (format "%s(%s)"
                                               (plist-get (plist-get entry :session) :agent-type)
                                               (plist-get (plist-get entry :session) :status)))
                                     busy " "))
                          ""))))
            worktrees "")))))))

(define-key bp/agent-sessions-mode-map (kbd "RET") #'bp/agent-sessions-jump)
(define-key bp/agent-sessions-mode-map (kbd "d") #'bp/agent-sessions-show-file-diff)
(define-key bp/agent-sessions-mode-map (kbd "v") #'bp/agent-sessions-display)
(define-key bp/agent-sessions-mode-map (kbd "V") #'bp/agent-sessions-display-or-browse)
(define-key bp/agent-sessions-mode-map (kbd "w") #'bp/agent-sessions-copy-attachment)
(define-key bp/agent-sessions-mode-map (kbd "k") #'bp/agent-sessions-kill)
(define-key bp/agent-sessions-mode-map (kbd "b") #'bp/agent-sessions-branch)
(define-key bp/agent-sessions-mode-map (kbd "B") #'bp/agent-sessions-mark-parent)
(define-key bp/agent-sessions-mode-map (kbd "D")
  #'bp/agent-sessions-submission-diff-or-detach-parent)
(define-key bp/agent-sessions-mode-map (kbd "t") #'bp/agent-sessions-cycle-state)
(define-key bp/agent-sessions-mode-map (kbd "SPC") #'bp/agent-sessions-edit-title)
(define-key bp/agent-sessions-mode-map (kbd "u") #'bp/agent-sessions-mark-unread)
(define-key bp/agent-sessions-mode-map (kbd "m") #'bp/agent-sessions-mark-unread)
(define-key bp/agent-sessions-mode-map (kbd "e") #'bp/agent-sessions-edit-note)
(define-key bp/agent-sessions-mode-map (kbd "R") #'bp/agent-sessions-restore)
(define-key bp/agent-sessions-mode-map (kbd "g") #'bp/agent-sessions-refresh)
(define-key bp/agent-sessions-mode-map (kbd "s") #'bp/agent-sessions-toggle-sort)
(define-key bp/agent-sessions-mode-map (kbd "f") #'bp/agent-sessions-toggle-folder-view)
(define-key bp/agent-sessions-mode-map (kbd "F") #'bp/agent-sessions-folder-action)
(define-key bp/agent-sessions-mode-map (kbd "+") #'bp/agent-sessions-new-vterm)
(define-key bp/agent-sessions-mode-map (kbd "n") #'bp/agent-sessions-next)
(define-key bp/agent-sessions-mode-map (kbd "p") #'bp/agent-sessions-prev)
(define-key bp/agent-sessions-mode-map (kbd "N") #'bp/agent-sessions-next-attention)
(define-key bp/agent-sessions-mode-map (kbd "P") #'bp/agent-sessions-prev-attention)
(define-key bp/agent-sessions-mode-map (kbd "M-n") #'bp/agent-sessions-move-down)
(define-key bp/agent-sessions-mode-map (kbd "M-p") #'bp/agent-sessions-move-up)
(define-key bp/agent-sessions-mode-map (kbd "C-c C-o") #'bp/agent-sessions-clear-manual-order)

;;; Wiring our hooks into Claude Code / Codex ------------------------------
;;
;; Both agents read a `{"hooks": {EVENT: [GROUP ...]}}' JSON config; each GROUP
;; is `{"hooks": [{"type":"command","command":SCRIPT,...}], ["matcher":M]}'.  We
;; own exactly the groups whose command runs one of our forwarder scripts (by
;; filename), so we can add/remove them idempotently while leaving every other
;; hook (orca's, the user's) untouched.

(defcustom bp/agent-sessions-claude-settings-file
  (expand-file-name "~/.claude/settings.json")
  "Claude Code user settings file that `bp/agent-sessions-install' wires."
  :type 'file)

(defcustom bp/agent-sessions-codex-hooks-file
  (expand-file-name "~/.codex/hooks.json")
  "Codex hooks file that `bp/agent-sessions-install' wires."
  :type 'file)

(defcustom bp/agent-sessions-pi-extension-file
  (expand-file-name "~/.pi/agent/extensions/agent-sessions-pi-hook.ts")
  "Where `bp/agent-sessions-install' installs the Pi event forwarder.
Pi has no hooks.json — extensions are plain files in this directory — so
installation is a copy, and uninstallation a delete."
  :type 'file)

(defcustom bp/agent-sessions-claude-hook-events
  '("SessionStart" "SessionEnd" "UserPromptSubmit" "Stop" "StopFailure"
    "SubagentStop" "TeammateIdle"
    ("PreToolUse" . "*") ("PostToolUse" . "*") ("PermissionRequest" . "*"))
  "Claude hook events to forward to the dashboard.
Each item is either an event name, or (EVENT . MATCHER) for tool-scoped events.
`SessionEnd' earns its place by closing the session's log row the moment the
agent exits, so `R' can offer it back while its terminal is still sitting
there at a shell prompt.  Codex has no equivalent event; there the end is
noticed when the terminal dies or another session starts in it."
  :type '(repeat (choice string (cons string string))))

(defcustom bp/agent-sessions-codex-hook-events
  '("SessionStart" "UserPromptSubmit" "PreToolUse" "PostToolUse"
    "PermissionRequest" "Stop")
  "Codex hook events to forward to the dashboard."
  :type '(repeat (choice string (cons string string))))

(defconst bp/agent-sessions--claude-hook-script "agent-sessions-claude-hook.sh")
(defconst bp/agent-sessions--codex-hook-script "agent-sessions-codex-hook.sh")
(defconst bp/agent-sessions--pi-hook-script "agent-sessions-pi-hook.ts")

(defun bp/agent-sessions--read-json (file)
  "Parse FILE as JSON into hash-tables + lists, or an empty object if absent.
Signals a `user-error' (rather than clobbering) if FILE holds invalid JSON."
  (if (file-exists-p file)
      (condition-case err
          (with-temp-buffer
            (insert-file-contents file)
            (goto-char (point-min))
            ;; Arrays as vectors (not lists): native `json-serialize' treats a
            ;; Lisp list as an alist/plist object, so JSON arrays must round-trip
            ;; as vectors to come back out as arrays.
            (json-parse-buffer :object-type 'hash-table :array-type 'array
                               :null-object :null :false-object :false))
        (error (user-error "agent-sessions: %s is not valid JSON (%s); left untouched"
                           file (error-message-string err))))
    (make-hash-table :test 'equal)))

(defun bp/agent-sessions--write-json (file obj)
  "Write OBJ to FILE as pretty-printed JSON, backing up any existing FILE.
`json-serialize' returns a *unibyte* string of UTF-8 bytes.  Inserted as-is,
every non-ASCII character becomes a run of raw bytes, and `json-pretty-print-
buffer' then re-encodes each of those as literal `\\302\\267' escape text —
so a round-trip silently rewrites `·' as four visible characters, and does it
to every em dash and accent in the file.  Decoding first is what makes the
round-trip lossless."
  (make-directory (file-name-directory file) t)
  (when (file-exists-p file)
    (copy-file file (concat file ".bak") t))
  (let ((coding-system-for-write 'utf-8))
    (with-temp-file file
      (insert (decode-coding-string
               (json-serialize obj :null-object :null :false-object :false)
               'utf-8))
      (json-pretty-print-buffer))))

(defun bp/agent-sessions--our-group-p (group script)
  "Non-nil if hook GROUP runs our SCRIPT (matched by basename)."
  (let ((cmds (and (hash-table-p group) (gethash "hooks" group))))
    (and (vectorp cmds)
         (seq-some (lambda (h)
                     (let ((c (and (hash-table-p h) (gethash "command" h))))
                       (and (stringp c) (string-match-p (regexp-quote script) c))))
                   cmds))))

(defun bp/agent-sessions--make-group (script matcher)
  "Build a hook GROUP hash-table running SCRIPT, with optional MATCHER."
  (let ((cmd (make-hash-table :test 'equal))
        (grp (make-hash-table :test 'equal)))
    (puthash "type" "command" cmd)
    (puthash "command" script cmd)
    (puthash "timeout" 10 cmd)
    (when matcher (puthash "matcher" matcher grp))
    (puthash "hooks" (vector cmd) grp)
    grp))

(defun bp/agent-sessions--strip-hooks (events-map script)
  "Remove our SCRIPT groups from EVENTS-MAP, dropping events left empty.
Returns t when anything was removed."
  (let (changed drop)
    (maphash
     (lambda (event groups)
       (let* ((orig (if (vectorp groups) (append groups nil) nil))
              (kept (seq-remove (lambda (g) (bp/agent-sessions--our-group-p g script))
                                orig)))
         (unless (= (length kept) (length orig)) (setq changed t))
         (if kept (puthash event (vconcat kept) events-map)
           (push event drop))))
     events-map)
    (dolist (event drop) (remhash event events-map))
    changed))

(defun bp/agent-sessions--wire (file events script)
  "Add SCRIPT hook groups for EVENTS into FILE's `hooks' map, idempotently.
Strips any stale groups of ours first (so re-running after moving the package
or editing the event list self-heals), then appends fresh ones."
  (let* ((root (bp/agent-sessions--read-json file))
         (hooks (let ((h (gethash "hooks" root)))
                  (if (hash-table-p h) h (make-hash-table :test 'equal)))))
    (bp/agent-sessions--strip-hooks hooks script)
    (dolist (ev events)
      (let* ((event (if (consp ev) (car ev) ev))
             (matcher (and (consp ev) (cdr ev)))
             (existing (gethash event hooks))
             (base (if (vectorp existing) existing [])))
        (puthash event
                 (vconcat base (vector (bp/agent-sessions--make-group script matcher)))
                 hooks)))
    (puthash "hooks" hooks root)
    (bp/agent-sessions--write-json file root)))

(defun bp/agent-sessions--unwire (file script)
  "Remove our SCRIPT hook groups from FILE, leaving other hooks intact.
Returns t if FILE was changed."
  (when (file-exists-p file)
    (let* ((root (bp/agent-sessions--read-json file))
           (hooks (gethash "hooks" root)))
      (when (and (hash-table-p hooks)
                 (bp/agent-sessions--strip-hooks hooks script))
        (if (zerop (hash-table-count hooks))
            (remhash "hooks" root)
          (puthash "hooks" hooks root))
        (bp/agent-sessions--write-json file root)
        t))))

(defun bp/agent-sessions--wire-pi (script)
  "Install the Pi extension SCRIPT into `bp/agent-sessions-pi-extension-file'.
Pi has no hooks config to edit; extensions are whole files in
`~/.pi/agent/extensions/', so wiring is a fresh copy — re-running after
editing the source self-heals."
  (make-directory (file-name-directory bp/agent-sessions-pi-extension-file) t)
  (copy-file script bp/agent-sessions-pi-extension-file t))

(defun bp/agent-sessions--unwire-pi ()
  "Remove the installed Pi extension.  Returns t if anything was removed."
  (let ((file bp/agent-sessions-pi-extension-file))
    (when (file-exists-p file)
      (delete-file file)
      t)))

;;;###autoload
(defun bp/agent-sessions-install (&optional force)
  "Wire this package's hooks into Claude Code, Codex, and Pi.
So a `claude'/`codex'/`pi' run in any Emacs terminal reports to the dashboard,
without depending on any external tool (e.g. orca).  Idempotent — re-run any
time: after installing a second agent, moving this package, changing the hook
event lists, or removing orca.  Only touches hook entries pointing at this
package's own forwarder scripts; other hooks are left as-is.

Wires Claude when `~/.claude' exists, Codex when `~/.codex' exists, and Pi
when `~/.pi' exists; with a prefix arg (FORCE) wires all regardless,
creating the config as needed.  Also starts the Emacs server, which the
hooks need to reach us."
  (interactive "P")
  (let ((claude-script (expand-file-name bp/agent-sessions--claude-hook-script
                                         bp/agent-sessions--dir))
        (codex-script (expand-file-name bp/agent-sessions--codex-hook-script
                                        bp/agent-sessions--dir))
        (pi-script (expand-file-name bp/agent-sessions--pi-hook-script
                                     bp/agent-sessions--dir))
        done)
    (dolist (s (list claude-script codex-script pi-script))
      (if (file-exists-p s)
          (set-file-modes s #o755)
        (error "agent-sessions: missing hook script %s" s)))
    (when (or force (file-directory-p
                     (file-name-directory bp/agent-sessions-claude-settings-file)))
      (bp/agent-sessions--wire bp/agent-sessions-claude-settings-file
                               bp/agent-sessions-claude-hook-events claude-script)
      (push "Claude" done))
    (when (or force (file-directory-p
                     (file-name-directory bp/agent-sessions-codex-hooks-file)))
      (bp/agent-sessions--wire bp/agent-sessions-codex-hooks-file
                               bp/agent-sessions-codex-hook-events codex-script)
      (push "Codex" done))
    (when (or force (file-directory-p "~/.pi"))
      (bp/agent-sessions--wire-pi pi-script)
      (push "Pi" done))
    (unless (server-running-p) (server-start))
    (if done
        (message "agent-sessions: wired %s (server running)"
                 (string-join (nreverse done) " + "))
      (message "agent-sessions: neither ~/.claude, ~/.codex, nor ~/.pi found; use `C-u M-x bp/agent-sessions-install' to force"))))

;;;###autoload
(defun bp/agent-sessions-uninstall ()
  "Remove this package's hooks from Claude Code, Codex, and Pi config.
Leaves every other hook (orca's, yours) intact, and leaves the forwarder
scripts on disk.  Safe to run whether or not `bp/agent-sessions-install' ran."
  (interactive)
  (let ((changed (delq nil
                       (list (and (bp/agent-sessions--unwire
                                   bp/agent-sessions-claude-settings-file
                                   bp/agent-sessions--claude-hook-script)
                                  "Claude")
                             (and (bp/agent-sessions--unwire
                                   bp/agent-sessions-codex-hooks-file
                                   bp/agent-sessions--codex-hook-script)
                                  "Codex")
                             (and (bp/agent-sessions--unwire-pi)
                                  "Pi")))))
    (message (if changed
                 (format "agent-sessions: unhooked from %s" (string-join changed " + "))
               "agent-sessions: nothing to remove"))))

;;;###autoload
(defun bp/agent-session-setup ()
  "Install all side effects this package makes on systems outside itself.
Namely: the vterm/eat advice (session-id injection + terminal-title capture),
the focus hook that clears the needs-attention highlight, the `agent-session'
Org link type, the `C-x p a' project binding, and starting the Emacs server
\(hook scripts reach us via emacsclient).  Idempotent; call from init/config."
  ;; vterm: inject EMACS_AGENT_SESSION_ID and capture the terminal title.
  (with-eval-after-load 'vterm
    (unless (advice-member-p #'bp/agent-sessions--vterm-advice 'vterm--internal)
      (advice-add 'vterm--internal :around #'bp/agent-sessions--vterm-advice))
    (unless (advice-member-p #'bp/agent-sessions--capture-title 'vterm--set-title)
      (advice-add 'vterm--set-title :before #'bp/agent-sessions--capture-title)))
  ;; eat: the same id injection and title capture.
  (with-eval-after-load 'eat
    (unless (advice-member-p #'bp/agent-sessions--eat-advice 'eat--1)
      (advice-add 'eat--1 :around #'bp/agent-sessions--eat-advice))
    (unless (advice-member-p #'bp/agent-sessions--eat-capture-title 'eat--t-set-title)
      (advice-add 'eat--t-set-title :after #'bp/agent-sessions--eat-capture-title)))
  ;; Clear a session's needs-attention highlight once the user focuses it.
  (add-hook 'buffer-list-update-hook #'bp/agent-session--clear-attention-on-focus)
  ;; Record that sessions still running at exit were *not* closed by the user.
  ;; This is the half of the close-detection scheme that runs when Emacs goes
  ;; away in an orderly fashion; `kill-buffer-hook' covers the other half, and
  ;; the fact that Emacs runs one but not the other is what distinguishes them.
  (add-hook 'kill-emacs-hook #'bp/agent-sessions--log-close-all)
  ;; A periodic heartbeat so a session lost to a *crash* can still be dated:
  ;; nothing runs at that point, so the last time we know Emacs was alive is
  ;; the best available answer.
  (unless bp/agent-sessions--heartbeat-timer
    (setq bp/agent-sessions--heartbeat-timer
          (run-with-timer 60 60 #'bp/agent-sessions--db-heartbeat)))
  ;; `agent-session:' Org links that resume/jump to a session.
  (with-eval-after-load 'ol
    (org-link-set-parameters "agent-session"
                             :follow #'bp/agent-sessions--org-follow-link
                             :store #'bp/agent-sessions--org-store-link))
  ;; C-x p a: switch between / create agent sessions for the current project.
  (with-eval-after-load 'project
    (define-key project-prefix-map (kbd "a") #'bp/agent-session-switch-or-new))
  ;; Hook scripts forward events via emacsclient, so the server must be up.
  (unless (server-running-p)
    (server-start)))

;;;###autoload
(defun bp/agent-sessions-list ()
  "Open the dashboard of Claude/Codex sessions running in vterm."
  (interactive)
  (let ((buf (get-buffer-create bp/agent-sessions-buffer-name)))
    (with-current-buffer buf
      (unless (derived-mode-p 'bp/agent-sessions-mode)
        (bp/agent-sessions-mode))
      (bp/agent-sessions--refresh))
    (pop-to-buffer buf)))

(provide 'agent-sessions)
