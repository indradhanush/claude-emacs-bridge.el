# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

An Emacs package that sends a file location (absolute path + inclusive line
range) and a typed instruction to another local Claude Code session. The
selected source text is never sent, only its coordinates.

## Commands

Run the full ERT suite in an isolated Emacs:

```
emacs -Q --batch -L . -L tests -l ert -l tests/claude-emacs-bridge-tests.el -f ert-run-tests-batch-and-exit
```

Run one test by name (regexp selector):

```
emacs -Q --batch -L . -L tests -l ert -l tests/claude-emacs-bridge-tests.el --eval '(ert-run-tests-batch-and-exit "line-range")'
```

There is no Makefile, build step, or package manager config. The suite must
also pass inside the running Doom Emacs instance (via `emacsclient`), because
`persp-mode` only exists there.

## Architecture

Everything lives in `claude-emacs-bridge.el`. A few mechanics are worth
knowing before editing.

### The receipt socket

Delivery is one-way to the target's inbox socket, so the bridge binds its own
socket to hear back about failures. `claude-emacs-bridge--ensure-receipt-socket`
binds it once, named with the Emacs PID (`emacs-bridge-<pid>.sock`) under
`claude-emacs-bridge-socket-directory`, and keeps it for the life of the
Emacs session — a socket that only lived for one send would miss a drop frame
that arrives batched, seconds later.

Every send is remembered in `claude-emacs-bridge--sends`, keyed by a message
id, for `claude-emacs-bridge--send-record-ttl` seconds after it stops
waiting. A failure frame that names an id still in that table is matched back
to the file and lines it concerns; a frame naming nothing there is logged
verbatim as uncorrelated evidence of a failure nobody has seen yet.

### Confirming delivery

Nothing is written back on the socket connection itself, so a send cannot
learn from the connection whether the target queued it. Confirmation instead
comes from watching the target's own transcript file for the
`queue-operation`/`enqueue` entry it writes once a message clears its accept,
duplicate, and rate guards (`claude-emacs-bridge--await-enqueue`), bounded by
`claude-emacs-bridge-confirm-timeout`. The transcript path is resolved from
the session's working directory and id, with a wildcard fallback for when
`claude-emacs-bridge-projects-directory` has been overridden; a transcript
that still can't be found is not treated as a failure, since persistence can
simply be off.

### Reporting the outcome

`claude-emacs-bridge--send-outcome` decides `delivered`, `unconfirmed`, or
`failed` from two independent signals: whether a receipt frame arrived on the
socket above, and whether the transcript confirmed queueing. A frame is
checked first because it carries the recipient's own reason, and the two are
never both true in practice — a message that was held or dropped was never
queued. A `duplicate` drop is reported as ordinary, not a failure: it is the
expected result of resending the same instruction about the same lines within
the recipient's own duplicate window.

### Session discovery and routing

Targets come from `claude-emacs-bridge-registry-directory`, where Claude Code
writes one JSON file per session. `claude-emacs-bridge--registry-row` keeps a
row only when it can actually be delivered to and located later: it must name
an inbox socket that still exists on disk (the socket going away is the
cheapest sign the session that wrote the row has too), and carry a name, a
PID, a session id, and a working directory.

Each Emacs context gets one remembered target, held in the in-memory
`claude-emacs-bridge--targets` hash table. Associations do not survive an Emacs
restart. The context key is the first of these that resolves, as a
`(type . value)` cons:

1. `project` – Emacs project root
2. `workspace` – persp-mode perspective name
3. `git` – `vc-root-dir`
4. `directory` – `default-directory`

A stored target is a `(pid . startedAt)` pair, not a name. A session that no
longer appears in the registry is stale, and the next send prompts for a
replacement.

### Line ranges

`claude-emacs-bridge--line-range` returns an inclusive range. Two rules matter:
a region ending at the start of a line must not include that line (hence the
`(1- end)`), and `line-number-at-pos` is called with `ABSOLUTE` non-nil so
narrowing does not shift the reported numbers.

## Conventions

- Public symbols use the `claude-emacs-bridge-` prefix. Internal ones use
  `claude-emacs-bridge--`.
- External functions are declared with `declare-function`, not required at load
  time, so the package byte-compiles without `persp-mode` present.
- Every helper has a direct ERT test. Tests fake collaborators with `cl-letf`
  over `symbol-function`; nothing in the suite spawns a real process, aside
  from the opt-in `claude-emacs-bridge-live-test`, skipped unless explicitly
  enabled.
- Plans live under `plans/` as org files and record acceptance criteria and
  verified facts. Update the relevant plan when behavior changes.
