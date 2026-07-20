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
- `./bin/chat [-c|--continue] [--model MODEL] [--max-rounds N] [--prompt TEXT]`: with `--prompt`, run one user prompt through the OpenRouter tool loop. With `-c`/`--continue`, resume the most recent interactive session from its per-session history snapshot (see resume note below). With no prompt and terminal stdin/stdout, start the persistent interactive chat session; `/exit`, `/quit`, Ctrl-C, or EOF ends it. Piped stdin is a documented one-shot prompt, never an interactive transcript. The command completes each turn only after the model returns a final response with no tool calls. Its workspace mount is read-write for `run_shell`; the caller is responsible for reviewing and committing any source changes it makes. After editing harness Lisp sources, use the in-process `reload_harness` tool or interactive `/reload` so the running image picks them up; `/max-rounds [N]` changes the live tool-loop limit without restarting.

The wrapper rebuilds before every command, relying on Docker layer caching when inputs are unchanged. Set `HARNESS_IMAGE` to use an alternative local tag.

## Credential handling

`OPENROUTER_API_KEY` is runtime configuration only (OpenRouter path). `bin/container` optionally forwards it, and optional `HARNESS_BACKEND` / `CODEX_HOME`, from an untracked repository `.env` file or an explicitly exported host environment variable. It does not echo values, write them into a trace, or bake them into the image.

`bin/chat --backend openrouter|codex` selects the provider (default openrouter). `--backend codex` pairs with `--codex-home PATH` (mapped into the container as `CODEX_HOME`). The same values can still be supplied via `HARNESS_BACKEND` / `CODEX_HOME` for non-chat entry points. `HARNESS_BACKEND=openai` / `--backend openai` and any `OPENAI_API_KEY` / `api.openai.com` path are unsupported: OpenAI-model usage in this harness is subscription-only through Codex.

Other runtime secrets are supplied through the workspace env file rather than added as new Docker `--env` plumbing. The repository-root `.env` is bind-mounted at `/workspace/.env`; at startup `bin/chat`'s Lisp process reads that file and sets each `KEY=value` into its own process environment, so commands the agent runs through `run_shell` (for example `git`/`gh` needing `GITHUB_TOKEN`) inherit them. Supported line forms are `KEY=value`, an optional leading `export`, and optional matching single/double quotes around the value; blank lines and `#` comments are ignored. Variables already present in the process environment are left untouched, so an explicitly forwarded value wins over the file. Override the path with `HARNESS_ENV_FILE` (a container-visible path; `bin/chat` forwards this variable into the container). The loader logs the file path and the names it set on stderr (`chat: loaded workspace env file <path> ...`) and never the values.

The supervisor live smoke requires an explicitly exported key (it does not load
one from `.env`) and creates a temporary independent clone of the tested branch.
The supervisor then creates its owned child worktree below a temporary parent,
runs one bounded tool-capable session, and the parent requests the pinned
`sg docker -c 'make test'` verification command. It checks only sanitized
provider accounting, Git state, and report consistency; temporary clones,
worktrees, JSONL, and reports are removed on exit. Run it only after review as
final evidence, never as normal CI coverage.

`.dockerignore` excludes `.env`, Git metadata, and local artifacts from the Docker build context. It is still the caller's responsibility to never pass credentials on a command line or commit them.

## Interaction logs

`bin/chat` appends UTF-8 JSON lines to a **per-session** Claude-style diagnostic
file under the workspace bind-mount: `agent-logs/$ISO-TIMESTAMP.jsonl` (container
path `/workspace/agent-logs/...`, host path `$repo_root/agent-logs/...`). That
directory is gitignored so hosts can inspect logs outside Docker without a named
volume. Override with `HARNESS_LOG_DIR` when tests need an isolated temp dir.

Each line is an object with Claude-like envelope fields (`type`, `uuid`,
`parentUuid`, `sessionId`, `timestamp`, `isSidechain`) plus a harness `payload`
that carries only allow-listed metadata: lifecycle event name, compact
model/mode/tool/reason labels, and numeric bounds or exit-status metadata.
Prompts, assistant text, tool commands/results, and arbitrary failure details
are excluded because they can contain credentials or private repository data. A
nonzero `run_shell` command is still returned to the model as a tool result with
its exit status and combined output, so the model can explain or correct it
without aborting the turn. `run_shell` defaults to a 60-second wall-clock
timeout (optional `timeout` argument); timed-out commands are terminated and
reported with a clear timeout message.

`bin/container` still mounts the named Docker volume
`self-improving-agent-harness-logs` at `/logs` for compatibility, but chat no
longer writes session diagnostics there by default.

## Chat session correlation events

Pass `--session-id ID` when a supervisor supplies the correlation identifier.
`ID` must be nonempty and is forwarded as `HARNESS_CHAT_SESSION_ID`. Prefer an
ISO-8601 UTC timestamp so the durable log path is exactly
`agent-logs/$ISO-TIMESTAMP.jsonl`. When omitted, `bin/chat` generates a fresh UTC
timestamp locally. Non-timestamp values remain valid for stderr correlation, but
the log basename is always normalized to an ISO timestamp. The value is
non-secret, stable for that invocation, and is not a resume token.

In normal human interactive mode stderr includes one JSON object per machine
event alongside the existing prompt/diagnostics. In supervised stream mode,
stderr contains only standalone JSONL machine events from the chat process and
stdout contains raw final assistant bytes: no startup prose, prompt, `OUTCOME`,
or human failure text is emitted. Each event has `event` and `session_id`;
submitted input is numbered from one and includes `turn`. The lifecycle and turn
event values are `session-started`, `session-exited`, `turn-submitted`,
`turn-completed`, `turn-failed`, and `turn-empty`. `session-exited.reason`
distinguishes `local-exit`, `eof`, and `interrupted`. Empty input emits
`turn-empty` and makes no provider request; a failed turn emits `turn-failed`,
retains the previous conversation history, and leaves the interactive session
running. Final assistant text remains stdout-only. Every supervised
`turn-completed` event additionally carries a required nonnegative integer
`assistant_bytes`: the exact UTF-8 byte length of that turn's raw stdout text.
It is a framing invariant, not an estimate or character count.

Each append-only `agent-logs/$ISO-TIMESTAMP.jsonl` file is diagnostic data for
one chat process, shaped like a Claude Code session transcript envelope. Records
include `sessionId` / `turn` context plus only allow-listed metadata inside
`payload`. They exclude credentials, prompts, assistant text, commands, tool
results, and arbitrary failure details. There is no shared multi-session
`chat.log`.

## Supervised JSONL slice

`bin/chat-supervisor` is deliberately an initial, non-resuming supervisor
protocol, not a transcript store or a promotion mechanism. Its stdin accepts one
JSON object per line: `{"op":"turn","text":"..."}`, `{"op":"checkpoint"}`,
and `{"op":"exit"}`. Its stdout returns JSONL with separate
`{"type":"assistant",...,"text":"..."}` records and forwarded structured
`{"type":"event",...}` lifecycle/turn records. The matching
`turn-completed` event is emitted first and its required `assistant_bytes` value
delimits the exact raw child stdout bytes used for that assistant record. The
supervisor must continue reading stdout until it has that many bytes even when
stderr delivers the JSON event first; it must not infer completion from a
zero-time readiness check or a delay. For example:

```json
{"type":"event","event":"session-started","session_id":"run-16"}
{"type":"event","event":"turn-completed","session_id":"run-16","turn":1,"assistant_bytes":3}
{"type":"assistant","session_id":"run-16","turn":1,"text":"..."}
```

An initial `checkpoint` runs `git status --short`, `git diff --check`, and the
caller-supplied **trusted** verification argv in the supplied worktree. It
returns only status/count/exit-code summaries and no Git paths, command output,
or diagnostic-log content. The verification command is tokenized and executed
without a shell; callers must still supply a safe project verification command
(normally `sg docker -c 'make test'`). Provider usage and cost are explicitly
`unavailable` in this slice; the adapter does not estimate them. It never merges,
deploys, or reads `agent-logs/$ISO-TIMESTAMP.jsonl` as sanitized evidence.

Inspect the latest entries from the host (workspace bind-mount, no Docker shell
required):

```bash
ls -1 agent-logs
tail -n 200 agent-logs/*.jsonl
```

## Current boundary

`bin/run` remains a readiness check: it verifies that the actual harness entry
point, rather than a host-only script, can load and construct its configured
backend. The OpenRouter non-streaming chat-completions adapter and sequential
tool-call loop are implemented. `bin/chat` provides both a one-prompt CLI and
a terminal-only persistent interactive chat session. The interactive session
keeps its ordered system/user/assistant/tool history in memory, executes
`run_shell` and in-process `reload_harness` inside the container, sends matching results back to the model, and
prints final assistant content. Interactive sessions also accept `/reload` and
`/max-rounds [N]` without a provider round-trip. It does not provide streaming/SSE,
persistent transcripts, or a policy/sandbox layer. `make repl`
remains the raw Docker SBCL REPL; it is not the model-chat interface.

## Cross-process resume (`bin/chat -c`)

Cross-process resume is implemented. After each successful interactive turn,
the harness atomically writes the full in-memory chat history (including
`tool_calls`/`tool_call_id` message parts, so replay is lossless) to a
per-session snapshot `agent-logs/$SESSION-ID.history.json`, alongside the
session model and tool-loop round limit. Passing `-c`/`--continue` to `bin/chat`
selects the most recent `.history.json` (session basenames are ISO-8601 UTC
timestamps, so the lexically-greatest name is newest), restores its message
history, and adopts the prior session id so the resumed turns keep appending to
the same JSONL/text logs. It also inherits the snapshot's model and max-rounds
unless overridden on the command line. When no snapshot exists (or it is
missing/malformed), resume degrades gracefully to a fresh session with a stderr
note. Round-trip, most-recent-selection, and missing/malformed cases are covered
by `tests/resume.lisp`.

Status: the resume implementation currently lives in the working tree and is not
yet committed. Only sessions that ended after the snapshot writer was added have
a `.history.json` to resume from; earlier sessions logged only diagnostic JSONL
(truncated tool traffic, no first-class tool results) and cannot be replayed
losslessly.

## Codex ChatGPT subscription backend (opt-in, issue #18)

The image includes a pinned official Codex CLI (`@openai/codex`, see the
Dockerfile `CODEX_CLI_VERSION` arg). This enables an opt-in, subscription-backed
backend that runs turns through `codex app-server` over local JSON-RPC.
Select it with `bin/chat --backend codex --codex-home PATH` (or
`make-codex-app-server-backend` / `HARNESS_BACKEND=codex` for non-chat entry
points). There is no OpenAI Platform API-key adapter; `--backend openai` errors.

- No credentials are baked into the image. ChatGPT/Codex OAuth is completed by a
  human at runtime and owned by Codex (keyring or `$CODEX_HOME/auth.json`).
- The harness never reads, stores, logs, or reports OAuth tokens; only redacted,
  non-secret metadata is retained. `auth.json` must be treated as a password.
- Credential storage location: set `CODEX_HOME` to a dedicated, non-reporting,
  writable path. Do NOT mount the host `~/.codex` into the container by default,
  and keep any Codex credential volume out of report/log mounts.
- Networking is required for the live path (Codex talks to its upstream), so it
  is exercised via `bin/verify-codex-chatgpt-auth` (network on), never under
  `make test` (which runs with `--no-network`).

Prove a working subscription session after login:

```
HARNESS_LIVE_CODEX_SMOKE=1 CODEX_HOME=/some/writable/codex-home bin/verify-codex-chatgpt-auth
```
