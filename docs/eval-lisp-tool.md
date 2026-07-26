# `eval_lisp`: an in-process Lisp REPL tool (issue #96)

## Scope

`eval_lisp` lets the chat agent (and subagents, see below) evaluate Lisp forms
directly in the running harness Lisp image — the same process already serving
the chat session — instead of only inspecting/editing files through
`run_shell`. It is implemented in `src/repl-tool.lisp`.

This is deliberately **not** a new capability boundary. `reload_harness`
already lets a chat session `LOAD` every harness source file and redefine any
function or parameter in this same image; `eval_lisp` runs at that identical
trust level, just for a single submitted form (or a short sequence of forms)
instead of a whole file. Anything `eval_lisp` can do, an agent could already
approximate by writing a throwaway `.lisp` file with `run_shell` and asking
`reload_harness` to load it — `eval_lisp` is the direct, lower-latency path for
the same trust level, not an escalation of it.

## Contract

The tool takes:

- `code` (string, required) — one or more Lisp forms, read and evaluated in
  order, exactly as if typed at a REPL.
- `timeout` (number, optional, default 30 seconds) — a wall-clock bound on the
  whole read+eval pass.

It evaluates in the `self-improving-agent-harness` package (bound via
`*package*`), so bare `DEFUN`/`DEFPARAMETER`/`DEFVAR`/`DEFMETHOD` forms and
existing harness symbols resolve without qualification — matching how
`reload_harness` loads harness source files into this same image.

The returned string is captured `*standard-output*`/`*error-output*` text
produced during evaluation, followed by `=> ` and the printed return value(s)
of the *last* form only (matching ordinary REPL behavior: earlier forms in the
same call are still evaluated for effect, but their return values are not
individually reported).

Reader forms are read with `*read-eval*` bound to `nil`, so a `#.` reader
macro embedded in submitted code cannot execute at read time; it can still run
through ordinary `eval` of the forms themselves, the same as `LOAD`ing a
source file that contains such a form.

## Error and timeout handling

`eval_lisp` never signals an unhandled condition back to the tool loop:

- A reader (syntax) error or an evaluation error is caught and returned as a
  plain string prefixed `eval_lisp failed: ...`, matching `run_shell`'s
  contract of always returning a tool-facing string rather than aborting the
  turn.
- A form that runs past the timeout is interrupted via `sb-ext:with-timeout`
  (the same mechanism already used by `subagent.lisp`, `codex-app-server.lisp`,
  and `claude-backend.lisp` for other in-process wall-clock bounds) and reports
  a timeout message telling the model to raise the `timeout` argument if
  needed. Because evaluation runs in-process rather than as an OS subprocess,
  this cannot use the `timeout`-wrapped `/bin/sh` approach `run_shell` uses.

Tool-call/tool-result logging (JSONL and the human-readable text log) uses the
same `log-interaction` events and `scrub-interaction-log-text` secret
scrubbing as every other tool.

## What `eval_lisp` does not do

`eval_lisp` does not read or write any file. A form such as:

```lisp
(defparameter *chat-max-tokens* 8192)
```

takes effect immediately in the live image — the very next tool-loop round
sees the new value — but is **not** written back to `src/chat-cli.lisp`. That
in-memory-only redefinition is lost the next time the process restarts, and is
silently overwritten the next time `reload_harness` reloads the on-disk source
(which still defines `*chat-max-tokens*` as `16384`). If a change made through
`eval_lisp` should persist, it must be made durable explicitly: edit the
source file with `run_shell`, then call `reload_harness` if the on-disk version
should also be reloaded into the image. `eval_lisp` and `reload_harness`
therefore compose (evaluate/experiment quickly in-memory, then commit the
result to source), but neither implies the other.

## Availability

`eval_lisp` is registered in `chat-tool-definitions` / `chat-handlers`
(`src/chat-cli.lisp`) alongside `run_shell`, `web_search`, `reload_harness`,
and `run_subagent`. Because the Claude MCP bridge
(`claude-mcp-tool-specifications` in `src/claude-mcp.lisp`) projects its tool
schema directly from `chat-tool-definitions`, `eval_lisp` is automatically
available over MCP to the `claude` backend too — there is no separate MCP
tool registry to keep in sync.

Subagents (`src/subagent.lisp`, `run_subagent`) also receive `eval_lisp`
alongside `run_shell`. This does not grant a subagent any new capability
relative to `run_shell` alone (a subagent's process is already fully mutable
by `run_shell`); it grants the same convenience the primary chat session has.
Subagents still structurally lack `run_subagent` (no recursion) and
`reload_harness` (only the primary session and its `/reload` command can
reload harness sources).

## Tests

`tests/repl-tool.lisp` (`run-eval-lisp-tests`) covers: return-value reporting,
multi-form evaluation (only the last form's value is reported), captured
standard output, evaluation in the harness package, persistence of
definitions across separate tool calls within the same image, reader/eval
error strings, timeout handling for a hanging form, `#.` read-time-eval
suppression, rejection of a missing `code` argument, and registration in
`chat-tool-definitions`/`chat-handlers`/`subagent-tool-definitions`/
`subagent-tool-handlers`.
