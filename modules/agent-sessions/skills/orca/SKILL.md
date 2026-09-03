---
name: orca
description: >-
  Coordinate other agents from an Emacs-managed terminal: start a claude/codex
  worker in another git worktree, give it a task, and receive its report either
  by waiting in the current turn or automatically after yielding.
  Use when the user says "/orca", "/orca --main", "orchestrate this", "spawn a
  subagent", "run these in parallel", "dispatch this to another agent", or asks
  you to supervise, wait for, or coordinate other agents. Also use when you find
  yourself running as someone's worker (EMACS_AGENT_ROLE=worker) and need the
  reporting protocol.
---

# Orca — agent orchestration through Emacs

The full, version-matched guide is printed by the `emacs-agent` command itself,
so it cannot drift from the tool it documents. Load it now, then follow it:

- **Coordinating others** — you were asked to orchestrate, the invocation
  included `--main`, or you are about to spawn a worker:

  ```bash
  emacs-agent guide --main
  ```

- **Working for a coordinator** — `$EMACS_AGENT_ROLE` is `worker`, or you were
  handed a task brief that names a coordinator:

  ```bash
  emacs-agent guide
  ```

Read whichever applies before running any other `emacs-agent` verb. If both
apply (you are a worker that needs to spawn workers of its own), read both.

Worker mail is queued immediately, but it is not injected while the recipient
is running a turn. After spawning a worker, choose based on what the current
turn needs:

- If you need the worker's result before responding, use `emacs-agent wait`.
  It polls the mailbox and returns the message as command output; it does not
  depend on idle-terminal delivery.
- Otherwise, yield normally instead of polling. Once you are idle, Emacs
  injects pending questions, blocked reports, and done reports as new input and
  starts another turn.

You may continue unrelated work in the current turn, but worker mail will not
interrupt it. A worker that sent a question remains blocked until you collect
the message with `wait` or finish the turn and let Emacs deliver it.

Terminal addresses remain usable after their terminal is killed when they
belonged to a resumable agent session. Sending to such an address restores the
conversation in a new worker terminal, attaches it as a child of the sender in
the dashboard, and submits the mail as its first prompt. If the conversation
was already restored, the mail is routed to that live terminal instead. The
command reports the new/current terminal id; a killed bare shell has no
conversation to restore and still fails.

`emacs-agent` only exists inside a terminal Emacs manages, and needs that Emacs
running with its server started. If the command is missing, say so plainly —
there is nothing to orchestrate from here, and the user's dashboard is where this
feature lives (`M-x bp/agent-sessions-list`, `M-x bp/agent-orchestration-install-skill`).
