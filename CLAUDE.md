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
`vterm` and `persp-mode` only exist there.

## Architecture

Everything lives in `claude-emacs-bridge.el`. Three concerns are worth knowing
before editing.

### The coordinator is a vterm running Claude Code

`claude-emacs-bridge-start` opens a vterm named `*claude-emacs-server*` and
types a startup command into it. That session runs under the name
`emacs-server` and is started with `env -u DO_NOT_TRACK`, because Claude Code
disables cross-session messaging when `DO_NOT_TRACK` is set and Emacs sets it
globally.

Emacs cannot call `SendMessage` itself. That tool belongs to the model. So the
bridge writes a natural-language prompt into the coordinator's vterm, and the
coordinator model relays the payload to the target session. The prompt wraps
the payload in `BEGIN TARGET MESSAGE` / `END TARGET MESSAGE` markers and tells
the coordinator not to act on it. Changing that wording changes runtime
behavior — treat `claude-emacs-bridge--format-prompt` as protocol, not text.

The buffer-local `claude-emacs-bridge--coordinator-p` flag marks a vterm the
package created. A buffer with the right name but without the flag is a name
collision and is rejected, never reused or killed.

### Submitting a paste is a race

Emacs pastes the prompt and then sends RET. Claude Code needs a moment to turn a
bracketed paste into its pending-input widget, and a RET that arrives first is
swallowed, leaving the message unsent as `[5 lines pasted]` in the input box.
Byte ordering is not the problem: `Fvterm_update` flushes to the pty
synchronously (`vterm-module.c:900`), so RET cannot overtake the paste.

`claude-emacs-bridge--await-submit` recovers from this. It watches the tail of
the coordinator buffer for the paste placeholder and resends RET while the
placeholder is still there, bounded by
`claude-emacs-bridge-submit-max-resends`. There is no fixed delay anywhere, on
purpose: no published delay value is known to work.

- Only the last `claude-emacs-bridge--paste-tail-window` characters are
  searched. A wider search picks up placeholders in the scrollback from
  messages that were already sent.
- `claude-emacs-bridge-paste-placeholder-regexp` matches third-party UI text and
  is a user option for that reason. If sends start going missing again with
  nothing in the log buffer, check this first: a wording change in Claude Code
  turns the detector into a no-op.

A send now reports success only when the input box actually cleared. Otherwise
it logs `may not have been submitted` to the log buffer.

### Session discovery and routing

Targets come from `claude agents --json`, parsed into alists. The coordinator
is excluded by comparing the JSON `pid` against the vterm subprocess PID.
Filtering by name is not reliable: Claude Code renames sessions when names
collide.

Only rows whose `kind` is `interactive` are kept. Interactive sessions are the
only ones that bind an inbox socket in `/tmp/cc-socks/`, so they are the only
ones the coordinator can deliver to. The same listing also returns background
agents, which carry a name and sometimes a live pid, and a pid-and-name test
cannot tell the two apart. A row that does not say it is interactive is
dropped, so a change to the listing shape empties the picker instead of
offering a target that silently goes nowhere.

Each Emacs context gets one remembered target, held in the in-memory
`claude-emacs-bridge--targets` hash table. Associations do not survive an Emacs
restart. The context key is the first of these that resolves, as a
`(type . value)` cons:

1. `project` – Emacs project root
2. `workspace` – persp-mode perspective name
3. `git` – `vc-root-dir`
4. `directory` – `default-directory`

A stored target is a `(pid . startedAt)` pair, not a name. A session that no
longer appears in discovery is stale, and the next send prompts for a
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
  time, so the package byte-compiles without `vterm` or `persp-mode` present.
- Every helper has a direct ERT test. Tests fake collaborators with `cl-letf`
  over `symbol-function`; nothing in the suite spawns a real process or vterm.
- Plans live under `plans/` as org files and record acceptance criteria and
  verified facts. Update the relevant plan when behavior changes.
