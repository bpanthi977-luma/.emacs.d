# Coordinating and messaging agents from an Emacs terminal

You are the **coordinator** when supervising dispatched work. The same protocol
also lets peer agents exchange messages without a parent/worker relationship.
You run in a terminal Emacs owns, and can start other agents, give each one a
task, send agent mail, and block until a reply or report arrives. Your tool is
`emacs-agent`, already on your PATH. Everything it does goes through the Emacs
that owns this terminal, so the human sees every worker you start in the same
dashboard (`M-x bp/agent-sessions-list`), marked as yours.

There is no task table, no dependency graph and no scheduler. **Your context is
the plan.** Keep the list of who is doing what in your head (or in a file you
share with the human) — Emacs only owns what you cannot do yourself: starting a
terminal, addressing a live one, and waiting.

## The loop

```bash
emacs-agent worktrees                     # who is working where
emacs-agent spawn --type claude --worktree ~/dev/luma-core_5 \
  --task "$(cat /tmp/brief.md)" --title "auth rewrite" --model opus
emacs-agent wait --types done,blocked,question,answer --timeout 90
emacs-agent send --to 11588-42 --type answer --subject "Use approach B" --body "..."
emacs-agent send-and-wait --to 11588-42 --subject "Follow-up" --body "..."
emacs-agent list                          # your workers and their live status
```

## 1. Choose where each worker runs — this is the decision that matters

Workers can share a worktree, and for read-only work they should. Several
research, review or audit agents examining different aspects of one codebase all
want the *same* tree, and each writing its findings to its own file costs
nothing. A checkout per worker there would be pure overhead, and would give each
one a subtly different view if the tree is dirty.

Give a worker a worktree to itself when it will:

- **edit files another worker might edit** — concurrent writes to one file lose
  work silently, and neither agent will understand why;
- **write git state**: `add`, `commit`, `checkout`, `rebase`, `stash`. The index
  and HEAD belong to the worktree, not to the process, so co-tenants share them:
  one worker staging its changes stages everyone's half-finished edits, and they
  will trip over each other's `index.lock`;
- **rebuild or regenerate into shared paths**, where two builds clobber each
  other's artifacts.

When you do share a worktree, say so in every brief that shares it: name the
files that worker may write, and tell it to leave git alone. A worker that was
not told will reasonably assume the checkout is its own. (Its launch preamble
already tells it not to touch git unless its task says the worktree is its own —
so if it *does* own one, say that too.)

`emacs-agent worktrees` prints every worktree of your repo with who is in it:

```
repo: ~/dev/luma-core/
2 agents  ~/dev/luma-core         luma-core (main)         dirty  claude(running) codex(idle)
0 agents  ~/dev/luma-core_2       luma-core_2 (PRO-14062)  dirty
0 agents  ~/dev/luma-core_5       luma-core_5 (main)       clean
```

- The count is live agent sessions there right now — the facts, not a verdict.
  Empty does not mean pristine, and occupied does not mean off-limits.
- `dirty` is uncommitted work in that checkout. For a writer, that is work you
  would be handing your worker along with its task; for a reader, it is context
  it will see and may report on.
- If a worker needs a checkout of its own and none is empty, **create the next
  numbered worktree yourself**:

  ```bash
  git -C ~/dev/luma-core worktree add ~/dev/luma-core_11 -b <branch> origin/main
  ```

  Numeric suffix, next unused number, based on the repo default (`origin/main`)
  unless the task is explicitly stacked on other work. This is the one case
  where you allocate a worktree without asking first: normally the human
  allocates them ahead of time, and running out mid-orchestration is exactly
  the situation that rule leaves to you. Say in your reply which worktrees you
  created.
- The directory must exist before you spawn; `spawn` refuses a path that does
  not.

## 2. Write the brief, then spawn

```bash
emacs-agent spawn --type claude|codex --worktree DIR --task TEXT \
  [--title SHORT] [--model NAME]
# --task-file FILE reads the brief from a file, which is easier for long ones
```

The worker starts with **your brief as its entire context**. It has never seen
this conversation, does not know the plan, and cannot ask the human. A brief that
works has all of:

- what to change, in terms of files or behaviour, not in terms of "continue";
- what *done* means — the check it should run, the output you want;
- what it owns: the files it may write, and whether the worktree is its own or
  shared (and so whether git operations are its to run);
- the constraints it must not break, and what it must not touch;
- anything it would otherwise have to guess: branch, ticket, prior decisions.

`spawn` prints the worker's id (e.g. `11588-42`), the worktree, and the path of
the brief file it wrote — that file is the record of what the worker was told,
and re-running its command by hand reproduces the launch.

The worker is launched with the protocol prepended to your task, so it already
knows to send exactly one `done`, to use `ask` instead of any interactive prompt,
and to stop when it is finished. You do not need to repeat that.

`--type` is any agent type configured in
`bp/agent-orchestration-launch-commands` (`claude` and `codex` out of the box —
adding one is a one-line defcustom edit the human can make).

## 3. Choose the model, when the task has an opinion about it

`--model NAME` launches that worker on a specific model instead of the human's
default. `NAME` is whatever the agent's own CLI accepts — for `claude`, an alias
like `opus`, `sonnet`, `haiku` or `fable`, or a full model id; for `codex`, one
of its model names. Nothing here validates the name (a list would be stale
within a release), so spell it the way that CLI does.

Match the model to the work, not to your own:

- **a big or subtle task** — design, a tricky bug, code whose correctness you
  cannot cheaply verify yourself — wants the strongest model. This is also the
  case where a weaker model costs you *more* than it saves: you pay for the run
  and then for reading a report you cannot trust.
- **mechanical, verifiable, or wide work** — a rename across files, collecting
  facts, running a check and reporting what it printed, one summary per file —
  runs fine on a smaller, faster model, and that is what makes spawning ten of
  them reasonable.
- **omit it** when you have no reason to prefer one. The default is the human's
  own configured model, which is the right thing to inherit by default.

Say which model you gave each worker when you report, so the human can read a
thin result as "wrong model for it" rather than as "the worker failed".

A model name the CLI does not recognise is not caught here: the worker dies on
its own error message and never reports. `spawn` echoes the model it launched
with (`Spawned 11588-42 (claude, opus) in …`) — if a worker goes silent
immediately, that line is where to check the spelling.

## 4. Wait, and keep waiting

```bash
emacs-agent wait --types done,blocked,question,answer --timeout 90
```

- Reads and prints every message as it arrives. `--types` only controls which
  message ends the wait: a `status` update is consumed and shown before polling
  continues, while `done`, `blocked`, `question`, or `answer` returns control.
  Keep `answer` in this stop filter because follow-up work after a worker's
  original `done` reports its result that way.
- On timeout it prints `messages: 0 (no matching message after 90s; call wait
  again …)`.
  **That is a checkpoint, not a failure.** Real tasks run 15–60 minutes. Call
  `wait` again; use `emacs-agent list` if you want to see that a worker is still
  alive. Do not re-dispatch or kill a worker for being slow.
- Set your own tool's timeout above `--timeout`, or the tool call is killed
  before the wait returns.
- `wait` consumes everything it prints. If several workers may finish together,
  keep waiting until you have heard from each one you are expecting.
- `emacs-agent check` reads mail without waiting. Unlike `wait`, its `--types`
  filters which messages are read; `check --peek` leaves them unread.

Mail also reaches you when you are not waiting. Questions, answers, blocked
reports, and done reports are queued into a running Codex conversation and can
steer it at a safe boundary; plain status updates do not steer on their own.
Codex mail always uses its native session queue, so it cannot absorb a human's
partially written terminal prompt. When another agent type is idle, Emacs types
pending `$orca (/orca)` mail into its terminal and submits it as new input. Read
it and continue the coordination or conversation.

## 5. Answer questions, then synthesize

For a conversational request whose result you need in the current turn, send
it and wait for the reply in one command:

```bash
emacs-agent send-and-wait --to <address> --subject "<topic>" --body "<question>" \
  --timeout 90
```

It defaults to an outgoing `question` and stops on an incoming `answer`.
`--type` overrides the outgoing message type; `--types` overrides the
comma-separated message types that stop the wait. Status messages are still
printed while polling continues. Delivery completes before polling starts, so
the same durable-address routing and revival behavior as `send` applies. If the
current response does not need the reply, use `send` alone and yield normally.

A `question` from a worker is blocking — it is sitting in `emacs-agent ask` until
you reply, so reply promptly:

```bash
emacs-agent send --to <worker-id> --type answer --subject "<the decision>" --body "<why, briefly>"
```

A `blocked` message is not blocking: the worker gave up and stopped. Decide
whether to respawn with a better brief, take the work yourself, or ask the human.

`send` also accepts the old terminal id of a killed resumable session. If that
conversation is already live under a new id, the message is routed there. If it
is still dead, Emacs resumes it in a new worker terminal, nests it under the
sending agent in the dashboard, and supplies the message as the first prompt;
the success response names the new terminal id. A terminal that never started
an agent has no durable conversation and cannot be revived.

The `--to` address may also be the agent's durable session id or a complete
`agent-session:AGENT::SESSION-ID::WORKTREE` link copied from Org. Prefer one of
those when it is available: `emacs-agent` resolves a running conversation to its
current terminal and can revive a stopped one without the caller translating
the durable identity into an ephemeral terminal id.

When everything is in, do the part only you can do: reconcile the reports, say
what actually landed and where, and name what is still open. A worker's `done`
summary is its own account of its work — if the result matters, verify it rather
than repeating the claim.

## What the human sees, and what they can do

- Every worker is a row in the dashboard, titled with the `--title` you gave it
  (or the first line of the task). The dashboard groups rows by repo and
  worktree, so a worker in *your* worktree is indented under your row, while one
  in another worktree appears under that worktree with `↳ from <you>`.
- `✉N` on a row means that agent has N unread messages waiting.
- The human can jump into any worker's terminal (`RET`) and talk to it directly.
  So a worker may have been redirected by them without telling you — if a report
  contradicts your brief, believe the report.
- Killing a worker's terminal is the human's call, not yours. There is no kill
  verb: when you are finished with a worker, leave it idle and say so.

## Limits worth knowing

- Mail is stored, so a crash does not lose a report you had not read yet. It
  comes back attached to the *conversation*, not the terminal: when the human
  restores a session (`R` in the dashboard), its unread mail is waiting. Mail to
  a terminal that never started an agent is the exception — there is nothing to
  restore it to.
- Terminal ids (`11588-42`) are live routing addresses. Agent session ids and
  `agent-session:` links are durable addresses. Any form routes to the current
  terminal when one exists; a recovered conversation is attached as the
  sending agent's child.
- A worker that never fires an agent hook (a bare shell, a crashed launch) still
  appears in the dashboard, but with no agent status. If a spawn produces a row
  that never leaves `idle`, look at its terminal — the launch command failed.
- **A directory the agent has never run in is gated behind a trust prompt**
  ("Do you trust the contents of this directory?"), and a worker stopped there
  never reads your brief. `spawn` registers the directory as trusted before
  launching, so this normally just works — when it does something, it tells you
  (`Note: pre-trusted … for codex`). Two cases still bite: the human turned that
  off (`bp/agent-orchestration-trust-new-worktrees`), or the type is one they
  added themselves, where Emacs does not know where trust lives. If a fresh
  worker goes quiet immediately and `spawn` printed no such note, assume it is
  sitting at a prompt: say so in your reply rather than waiting for a report
  that cannot come.
- Nothing here reaches outside this machine's Emacs. Slack, GitHub and Linear are
  not part of the protocol; use your own tools for those, and only for the human.
