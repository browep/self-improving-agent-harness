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
- `./bin/chat [--model MODEL] [--max-rounds N] [--prompt TEXT]`: run one user prompt through the OpenRouter tool loop. Omit `--prompt` to read stdin. The command completes only after the model returns a final response with no tool calls.

The wrapper rebuilds before every command, relying on Docker layer caching when inputs are unchanged. Set `HARNESS_IMAGE` to use an alternative local tag.

## Credential handling

`OPENROUTER_API_KEY` is runtime configuration only. `bin/container` optionally forwards it from an untracked repository `.env` file or an explicitly exported host environment variable. It does not echo the value, write it into a trace, or bake it into the image.

`.dockerignore` excludes `.env`, Git metadata, and local artifacts from the Docker build context. It is still the caller's responsibility to never pass credentials on a command line or commit them.

## Current boundary

`bin/run` remains a readiness check: it verifies that the actual harness entry
point, rather than a host-only script, can load and construct its configured
backend. The OpenRouter non-streaming chat-completions adapter and sequential
tool-call loop are implemented. `bin/chat` supplies the current single-prompt
CLI: it registers `run_shell`, executes the requested command inside the
container, sends the result back to the model, and prints the final assistant
response. It does not provide a persistent multi-turn REPL, streaming/SSE, or
a policy/sandbox layer.
