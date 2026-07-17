# Portable Docker runtime

## Decision

All project Common Lisp code runs in the repository's Docker environment. The host supplies Docker Engine only; it is not a supported runtime for SBCL, ASDF, tests, scripts, or the harness.

## Runtime contract

`Dockerfile` builds a Debian Bookworm image with SBCL and ASDF. The source tree is not copied into the image. Wrappers mount the checked-out repository read-only at `/workspace` by default, so tests and ordinary harness runs cannot write source, test fixtures, or documentation through the project mount. `bin/chat` is the deliberate exception: it mounts `/workspace` read-write because its `run_shell` tool is intended to let the chat agent modify the checked-out workspace.

Compiled FASLs and ASDF cache data are written to the Docker named volume `self-improving-agent-harness-cache`. This makes the runtime portable while preserving compilation performance between invocations.

## Commands

- `make test` / `./bin/test`: build the image and execute `asdf:test-system`. The container has no network.
- `make run` / `./bin/run`: build the image and execute the harness readiness entry point. This permits network access but does not make a provider request.
- `make repl` / `./bin/container --noinform`: build the image and start an interactive SBCL session.
- `make live-smoke`: make one minimal live OpenRouter chat-completions request.
- `make live-tool-smoke`: make a live tool-capable OpenRouter request using the deterministic `echo` handler.
- `./bin/chat [--model MODEL] [--max-rounds N] [--session-id ID] [--prompt TEXT]`: with `--prompt`, run one user prompt through the OpenRouter tool loop. With no prompt and terminal stdin/stdout, start the persistent interactive chat session; `/exit`, `/quit`, Ctrl-C, or EOF ends it. Piped stdin is a documented one-shot prompt, never an interactive transcript. The command completes each turn only after the model returns a final response with no tool calls. Its workspace mount is read-write for `run_shell`; the caller is responsible for reviewing and committing any source changes it makes.

The wrapper rebuilds before every command, relying on Docker layer caching when inputs are unchanged. Set `HARNESS_IMAGE` to use an alternative local tag.

## Credential handling

`OPENROUTER_API_KEY` is runtime configuration only. `bin/container` optionally forwards it from an untracked repository `.env` file or an explicitly exported host environment variable. It does not echo the value, write it into a trace, or bake it into the image.

`.dockerignore` excludes `.env`, Git metadata, and local artifacts from the Docker build context. It is still the caller's responsibility to never pass credentials on a command line or commit them.

## Interaction logs

Every `bin/container` run mounts the named Docker volume
`self-improving-agent-harness-logs` at `/logs`. `bin/chat` appends UTF-8 JSON
lines to `/logs/chat.log` for session lifecycle, user turns, completed assistant
turns, tool invocations, and safe failure messages. A nonzero `run_shell`
command is returned to the model as a tool result with its exit status and
combined output, so the model can explain or correct it without aborting the
turn. It does not log the
OpenRouter API key or raw tool output, but prompts, assistant responses, and
tool commands can themselves be sensitive.

## Chat session correlation events

Pass `--session-id ID` when a supervisor supplies the correlation identifier.
`ID` must be nonempty and is forwarded as `HARNESS_CHAT_SESSION_ID`. When it is
omitted, `bin/chat` generates `chat-<UTC timestamp>-<process id>` locally. The
generated value is non-secret, stable for that invocation, and intended only to
correlate its console and diagnostic-log records; it is not a resume token.

In interactive mode stderr includes one JSON object per machine event, alongside
the existing human prompt/diagnostics. Each event has `event` and `session_id`;
submitted input is numbered from one and includes `turn`. The lifecycle and turn
event values are `session-started`, `session-exited`, `turn-submitted`,
`turn-completed`, `turn-failed`, and `turn-empty`. `session-exited.reason`
distinguishes `local-exit`, `eof`, and `interrupted`. Empty input emits
`turn-empty` and makes no provider request; a failed turn emits `turn-failed`,
retains the previous conversation history, and leaves the interactive session
running. Final assistant text remains stdout-only.

The shared append-only `chat.log` is diagnostic data, not a per-session
transcript. Its chat interaction records include the available `session_id` and
`turn` context. It does not record credentials or raw successful tool output,
but prompts, assistant text, commands, and failures can still be sensitive.

Inspect the latest entries from the host:

```bash
sg docker -c "docker run --rm --entrypoint /bin/sh \\
  --volume self-improving-agent-harness-logs:/logs \\
  self-improving-agent-harness:dev \\
  -lc 'tail -n 200 /logs/chat.log'"
```

## Current boundary

`bin/run` remains a readiness check: it verifies that the actual harness entry
point, rather than a host-only script, can load and construct its configured
backend. The OpenRouter non-streaming chat-completions adapter and sequential
tool-call loop are implemented. `bin/chat` provides both a one-prompt CLI and
a terminal-only persistent interactive chat session. The interactive session
keeps its ordered system/user/assistant/tool history in memory, executes
`run_shell` inside the container, sends matching results back to the model, and
prints final assistant content. It does not provide streaming/SSE, persistent
transcripts, cross-process resume, or a policy/sandbox layer. `make repl`
remains the raw Docker SBCL REPL; it is not the model-chat interface.
