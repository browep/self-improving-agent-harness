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

## Experiment DSL and lineage

The first-class experiment model in `src/experiment.lisp` provides versioned,
provider-neutral specifications for experiments, candidates, run records,
evaluations, and decisions. `defexperiment` validates and registers complete
declarations without executing a provider. See
[`docs/experiment-model.md`](docs/experiment-model.md) for the public data
model, extension points, and serialization contract.

Run the checked-in, no-provider DSL example in Docker with networking disabled:

```bash
make experiment-example
```

## Baseline fixture and deterministic evaluation

Issue #12 adds a checked-in, versioned fixture at
[`fixtures/baseline-answer-v1.lisp`](fixtures/baseline-answer-v1.lisp).  It has
an explicit task input, acceptance command, and all wall-time, provider-call,
token, and cost limits.  The fixed offline candidate passes through the existing
backend/tool-loop seam, then the evaluator runs the fixture command with a
bounded timeout.  Its evidence retains only check name, pass/fail status, and
exit code—never candidate or command output.

Run it without credentials or network access:

```bash
sg docker -c 'make baseline'
```

A result is `:success`, `:acceptance-failure` (the candidate ran but an
acceptance command failed), or `:execution-failure` (backend/tool-loop,
budget, or evaluator execution failed).  See
[`docs/baseline-fixture.md`](docs/baseline-fixture.md) for the rerun contract.

## Auditable run reports

The deterministic scripted baseline can persist a versioned run trace without
provider credentials or network access:

```bash
sg docker -c 'make report'
```

It writes the paired artifacts to the predictable location
`reports/baseline-answer-v1/run.json` and `reports/baseline-answer-v1/run.html`.
Both artifacts are generated from the same redacted in-memory run record.  The
report records the task and criteria, candidate lineage/configuration, available
and invoked model histories, tool metadata, per-invocation usage and actual
cost, evaluator evidence, outcome, and final decision.  The HTML is
self-contained and places selected/available models before invoked attempts;
invocations are rendered as a table. Credentials and raw tool/provider output
are excluded while input/output token and actual cost accounting is retained.

## Configuration candidates and baseline comparison

Issue #14 adds a provider-neutral `candidate-generator` protocol and a
deterministic generator for explicit mutation spaces. The initial configuration
dimensions are model ID, prompt-template version, max rounds, and tool/workflow
strategy. Generated candidates have canonical configurations, portable stable
configuration hashes, and baseline parent lineage.

Run the checked-in, no-provider comparison in Docker:

```bash
sg docker -c 'make configuration-comparison'
```

This evaluates the baseline and two scripted configuration candidates under the
same wall-time, provider-call, total-token, and cost caps. It writes
`reports/configuration-comparison-v1/run.json` and
`reports/configuration-comparison-v1/run.html`. The paired artifacts share one
redacted record containing baseline/candidate evaluator evidence, actual
provider-call/token/cost accounting, outcomes, configuration hashes and lineage,
and retention rationale. Retention is replayed solely from persisted evaluator
verdicts: the scripted regression is rejected, without candidate self-assessment
or self-promotion. See [how the self-modifying harness works](docs/self-modifying-harness.md)
for the current modification mechanisms, evaluation independence, and limits.

## Docker-first runtime

**Docker is the required Common Lisp runtime.** Do not install or invoke a host Lisp implementation for project code, tests, or harness runs. The project image provides SBCL and ASDF; the repository source is mounted read-only by default, and compiled artifacts live in a named Docker volume. `bin/chat` deliberately mounts its workspace read-write so its `run_shell` tool can make requested workspace changes.

Prerequisite: Docker Engine. No host SBCL, Quicklisp, or system package installation is required.

```bash
# Build the runtime image and run all tests with networking disabled.
make test

# Build the image and run the current harness entry point.
make run

# Start an interactive SBCL REPL in the same container environment.
make repl
```

The equivalent direct commands are `./bin/test`, `./bin/run`, and `./bin/container --noinform`. `bin/container` rebuilds the image before each invocation, mounts the repository at `/workspace:ro` by default, and keeps ASDF's cache in the `self-improving-agent-harness-cache` volume. `bin/chat` invokes it with `--writable-workspace`, mounting the repository at `/workspace` without the read-only flag.

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

For final **opt-in, potentially billable** evidence that the JSONL supervisor
can create an owned worktree and observe a real `run_shell` mutation, run this
only after review:

```bash
export OPENROUTER_API_KEY=... # do not paste or commit the value
make live-chat-supervisor-tool-smoke
```

It exits with code `77` and a clear skip message if the key is not exported.
It is intentionally excluded from `make test`: it is final human/supervisor
verification, not ordinary deterministic coverage. The smoke clones the current
tested branch into a disposable primary checkout, asks the supervisor to make
its own child worktree, verifies the child diff and pinned parent-side test
command, and removes all temporary artifacts afterwards.

## Chat CLI

`bin/chat` runs the harness `run_shell` tool inside its Docker container. It has
three deliberately distinct modes:

```bash
# Interactive multi-turn chat (terminal stdin and stdout; /exit, /quit, Ctrl-C, or EOF ends it).
# A supervisor may supply a nonempty correlation ID; otherwise bin/chat generates one locally.
./bin/chat --model openai/gpt-4.1-mini --session-id supervisor-session-16

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
goes to stdout while tool and outcome diagnostics go to stderr. A nonzero
`run_shell` command returns its exit status and combined output to the model as a
tool result, allowing it to explain or correct the command rather than aborting
the chat. Commands default to a 60-second wall-clock timeout (override with the
optional `timeout` argument); timed-out commands are terminated and reported with
a clear timeout message. `--prompt` retains the existing one-shot exit behavior. Run
`./bin/chat --help` for defaults and requirements.

### Supervised chat adapter (#16 lifecycle/evidence slice)

`bin/chat-supervisor` now has an explicit `--create-worktree` mode that creates
a clean, dedicated branch/worktree below a configured parent from a supplied
repository, base ref, and unique run ID. It refuses unsafe primary checkouts,
dirty starts, parent escapes, and duplicate run IDs. It neither merges nor
deletes anything. Every turn/checkpoint has independently captured sanitized
Git status/diff-check/diff-stat and named verification outcome. External
structured evaluator feedback can be linked to the next turn; worker text never
creates evaluator evidence or a promotion decision. On exit, it writes paired
versioned JSON and self-contained HTML from one redacted in-memory session
report in the explicit report directory. Accounting remains `unavailable`
unless supplied authoritatively; this is not experiment promotion or provider
cost evidence.

See [`docs/chat-supervisor-protocol.md`](docs/chat-supervisor-protocol.md) for
the exact JSONL schema, validation limits, safe pre-created-worktree contract,
and a complete invocation. `--fake` remains an offline deterministic test-only
backend with no provider call.

For interactive supervision, `--session-id ID` forwards a nonempty caller-owned
correlation ID (prefer a UUID). Otherwise `bin/chat` generates a fresh UUID for
that invocation. Stderr emits JSONL lifecycle/turn events (`session-started`,
`turn-submitted`, `turn-completed`, `turn-failed`, `turn-empty`, and
`session-exited`) with that ID; submitted turns are monotonically numbered. They
are correlation diagnostics, not provider per-invocation token or cost
accounting. Durable diagnostics are written per session to `agent-logs/$ISO-TIMESTAMP.jsonl`
in a Claude-style JSONL envelope and exclude credentials, prompts, assistant
text, and raw tool output.

See [`docs/runtime.md`](docs/runtime.md) for runtime guarantees and [`docs/initial-architecture.md`](docs/initial-architecture.md) for design questions. For a supervising agent that drives persistent `bin/chat` as an isolated, evidence-backed feedback-loop worker, use the in-repo [Harness Chat Feedback Loop skill](skills/autonomous-ai-agents/harness-chat-feedback-loop/SKILL.md).

## Selecting a chat model

`--model` is passed directly to OpenRouter. Supply the exact `id` field from
OpenRouter's Models API (for example, `openai/gpt-4.1-mini`), not the human
`name` shown in the model picker. The chat always exposes the `run_shell` tool,
so select a text-output model whose `supported_parameters` includes `tools`.

- Browse and filter models interactively: <https://openrouter.ai/models>
- API reference and current model metadata: <https://openrouter.ai/docs/guides/overview/models>

List tool-capable text models and their request IDs from the public API:

```bash
curl -fsSL 'https://openrouter.ai/api/v1/models?supported_parameters=tools' |
  python3 -c '
import json, sys
for model in json.load(sys.stdin)["data"]:
    if "text" in model.get("architecture", {}).get("output_modalities", []):
        print("{}\t{}\tcontext={}".format(model["id"], model["name"], model["context_length"]))
'
```

The first column is the value to pass to `--model`. Verify an individual ID,
including its tool capability and deprecation metadata, before using it:

```bash
curl -fsSL 'https://openrouter.ai/api/v1/model/openai/gpt-4.1-mini'
```

Model availability, price, and capability metadata change over time; query the
API instead of copying an old display name or relying on an alias. Then run:

```bash
./bin/chat --model openai/gpt-4.1-mini
```

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
