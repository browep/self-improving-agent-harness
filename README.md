# Self-Improving Agent Harness

A Common Lisp research harness for running, observing, judging, and iteratively improving agent workflows. The first provider adapter will target the OpenRouter API; the harness is designed so providers can be replaced without changing core orchestration.

> **Status:** design and exploration. The project starts with a small, dependency-free protocol and a portable Docker runtime rather than a committed agent architecture.

## Goals

- Define a small, swappable backend protocol for model providers.
- Implement an OpenRouter backend using API-key authentication.
- Run reproducible agent experiments with durable prompts, configuration, traces, outcomes, and costs.
- Evaluate candidate changes against explicit tasks and acceptance criteria.
- Support controlled improvement loops: propose, execute, judge, retain or reject.
- Keep policies and dangerous capabilities explicit and auditable.

## Non-goals (initially)

- Autonomous production deployment or unbounded self-modification.
- A dependency on one model, provider, or agent framework.
- Hiding provider calls, tool execution, or evaluation decisions.

## Architecture direction

```text
experiment/task -> harness -> backend protocol -> OpenRouter (first adapter)
                      |              |
                      |              +-> future providers / local inference
                      +-> trace store, tool boundary, evaluator, improvement policy
```

The core protocol is introduced in `src/backend.lisp`. It separates a request
from the backend used to complete it. The first concrete adapter implements
OpenRouter's non-streaming Chat Completions API with runtime API-key
authentication. Persistence, tool execution, and the evaluation loop remain
separate workstreams.

## Docker-first runtime

**Docker is the required Common Lisp runtime.** Do not install or invoke a host Lisp implementation for project code, tests, or harness runs. The project image provides SBCL and ASDF; the repository source is mounted read-only, and compiled artifacts live in a named Docker volume.

Prerequisite: Docker Engine. No host SBCL, Quicklisp, or system package installation is required.

```bash
# Build the runtime image and run all tests with networking disabled.
make test

# Build the image and run the current harness entry point.
make run

# Start an interactive SBCL REPL in the same container environment.
make repl
```

The equivalent direct commands are `./bin/test`, `./bin/run`, and `./bin/container --noinform`. `bin/container` rebuilds the image before each invocation, mounts the repository at `/workspace:ro`, and keeps ASDF's cache in the `self-improving-agent-harness-cache` volume.

For a real OpenRouter request, place a key in an untracked `.env` file or
explicitly export it before invoking the Docker-backed live smoke command:

```bash
cp .env.example .env
# Set OPENROUTER_API_KEY in .env; do not commit it.
```

Then run:

```bash
make live-smoke
```

The wrapper forwards the variable to the container without printing it or
copying it into the image. Tests run with `--network none`; `make live-smoke`
has network access by design and makes one minimal provider request.

To exercise the OpenRouter tool-call loop with a deterministic `echo` handler,
run:

```bash
make live-tool-smoke
```

It makes a real tool-capable provider interaction and prints only the resolved
model, tool invocation count, and final assistant text.

## Chat CLI

`bin/chat` runs the harness `run_shell` tool inside its Docker container. It has
three deliberately distinct modes:

```bash
# Interactive multi-turn chat (terminal stdin and stdout; /exit, /quit, Ctrl-C, or EOF ends it).
./bin/chat --model openai/gpt-4.1-mini

# One-shot chat.
./bin/chat --model openai/gpt-4.1-mini \
  --prompt "Use run_shell to inspect the repository, then summarize it."

# Piped input is also one-shot, not a multi-line interactive transcript.
printf '%s' 'Summarize the repository.' | ./bin/chat
```

The interactive process retains one ordered in-memory history: its system
message, each completed user/assistant exchange, and tool-call/tool-result
messages. Empty interactive input makes no provider request. A failed turn prints its
safe failure message on stderr, leaves that history untouched, and the session
continues; normal exit after any failed turn is non-zero. Final assistant content
goes to stdout while tool and outcome diagnostics go to stderr. `--prompt`
retains the existing one-shot exit behavior. Run
`./bin/chat --help` for defaults and requirements.

See [`docs/runtime.md`](docs/runtime.md) for runtime guarantees and [`docs/initial-architecture.md`](docs/initial-architecture.md) for design questions.

## Repository layout

- `src/` — Common Lisp packages, backend protocol, and harness entry point.
- `tests/` — dependency-free smoke tests.
- `scripts/` — Lisp load scripts invoked only through the container wrappers.
- `bin/` — Docker-only commands for the harness and test system.
- `docs/` — architecture decisions and research notes.
- `.github/ISSUE_TEMPLATE/` — issues for progress and documentation.

## How we use GitHub Issues

Issues are the project record for research decisions, documentation, experiments, and implementation progress.

- Open an issue before beginning a meaningful workstream.
- Use **research**, **documentation**, **architecture**, **backend**, **experiment**, and **progress** labels.
- Record: hypothesis/goal, scope, result, evidence (commands, traces, or reports), and follow-up work.
- Link commits and pull requests with `Refs #<issue>`; use `Closes #<issue>` only when the stated acceptance criteria are met.
- Keep design decisions in `docs/` and link the corresponding issue.

## License

MIT. See [LICENSE](LICENSE).
