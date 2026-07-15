# Portable Docker runtime

## Decision

All project Common Lisp code runs in the repository's Docker environment. The host supplies Docker Engine only; it is not a supported runtime for SBCL, ASDF, tests, scripts, or the harness.

## Runtime contract

`Dockerfile` builds a Debian Bookworm image with SBCL and ASDF. The source tree is not copied into the image. Every wrapper mounts the checked-out repository read-only at `/workspace`, so a run cannot write source, test fixtures, or documentation through the project mount.

Compiled FASLs and ASDF cache data are written to the Docker named volume `self-improving-agent-harness-cache`. This makes the runtime portable while preserving compilation performance between invocations.

## Commands

- `make test` / `./bin/test`: build the image and execute `asdf:test-system`. The container has no network.
- `make run` / `./bin/run`: build the image and execute the harness readiness entry point. This permits network access but does not make a provider request.
- `make repl` / `./bin/container --noinform`: build the image and start an interactive SBCL session.
- `make live-smoke`: make one minimal live OpenRouter chat-completions request.
- `make live-tool-smoke`: make a live tool-capable OpenRouter request using the deterministic `echo` handler.
- `./bin/chat [--model MODEL] [--max-rounds N] [--prompt TEXT]`: with `--prompt`, run one user prompt through the OpenRouter tool loop. With no prompt and terminal stdin/stdout, start the persistent interactive chat session; `/exit`, `/quit`, or EOF ends it. Piped stdin is a documented one-shot prompt, never an interactive transcript. The command completes each turn only after the model returns a final response with no tool calls.

The wrapper rebuilds before every command, relying on Docker layer caching when inputs are unchanged. Set `HARNESS_IMAGE` to use an alternative local tag.

## Credential handling

`OPENROUTER_API_KEY` is runtime configuration only. `bin/container` optionally forwards it from an untracked repository `.env` file or an explicitly exported host environment variable. It does not echo the value, write it into a trace, or bake it into the image.

`.dockerignore` excludes `.env`, Git metadata, and local artifacts from the Docker build context. It is still the caller's responsibility to never pass credentials on a command line or commit them.

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
