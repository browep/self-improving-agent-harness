# Self-Improving Agent Harness

A Common Lisp research harness for running, observing, judging, and iteratively improving agent workflows. The harness includes OpenRouter and Synthetic OpenAI-compatible API adapters, while preserving a provider-neutral core so providers can be replaced without changing orchestration.

> **Status:** design and exploration. The project starts with a small, dependency-free protocol and a portable Docker runtime rather than a committed agent architecture.

## Goals

- Define a small, swappable backend protocol for model providers.
- Implement explicit, swappable API-key backends.
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
experiment/task -> harness -> backend protocol -> OpenRouter / Synthetic
                      |              |
                      |              +-> future providers / local inference
                      +-> trace store, tool boundary, evaluator, improvement policy
```

The core protocol is introduced in `src/backend.lisp`. It separates a request
from the backend used to complete it. OpenRouter and Synthetic share the
non-streaming OpenAI-compatible Chat Completions and harness-owned tool-loop
contract, but retain distinct provider identities, base URLs, credentials, and
error/accounting evidence. Persistence, tool execution, and the evaluation loop
remain separate workstreams.

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
[What Common Lisp unlocks for a self-modifying LLM harness](docs/common-lisp-harness-roadmap.md)
describes the form-level mutation, live-reload, and workflow-induction research
roadmap built on those boundaries.

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

For real API-backed requests, place provider keys in an untracked `.env` file or
explicitly export them before invoking Docker-backed live smoke commands:

```bash
cp .env.example .env
# Set OPENROUTER_API_KEY and/or SYNTHETIC_API_KEY in .env; do not commit them.
```

The repo-root `.env` is bind-mounted at `/workspace/.env`. Beyond
`OPENROUTER_API_KEY` and `SYNTHETIC_API_KEY`, put any other runtime secrets there (for example
`GITHUB_TOKEN` for `git`/`gh` inside `run_shell`), one `KEY=value` per line: at
startup `bin/chat`'s Lisp process reads the file and sets each variable into its
own process environment, which the agent's shell commands inherit. Values are
never logged, only the names that were set. See `docs/runtime.md` for details.

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

## Synthetic OpenAI-compatible backend (issue #22)

Synthetic is a distinct API-key-backed provider, not an OpenRouter fallback and
not an Anthropic/Claude subscription route. Select it with the normal harness
tool loop, which continues to own the system prompt, `run_shell`,
`reload_harness`, tool schema, and tool-result continuation:

```bash
./bin/chat --backend synthetic --model syn:large:text --prompt 'Summarize this repository.'
make live-synthetic-smoke
make live-synthetic-tool-smoke
```

The live commands use `SYNTHETIC_API_KEY` from the untracked repository `.env`
or exported environment and are intentionally excluded from `make test`.
They require an active Synthetic subscription or usage credits; a configured key
without credits is rejected by the provider with HTTP 402.
Synthetic aliases such as `syn:large:text` can rotate; use the Synthetic Models
API to select and record an exact returned model ID for reproducible experiments.
Prove the exact selected model's tool behavior with the tool smoke before using
it in a mutation-capable harness experiment. See `docs/runtime.md` for the
credential/runtime boundary.

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

## Codex ChatGPT subscription backend (opt-in, issue #18)

An opt-in backend runs turns through the existing ChatGPT/Codex subscription via
the official local `codex app-server` (JSON-RPC over stdio). The image installs
a pinned `@openai/codex` CLI; no credentials are baked in and the harness never
reads, stores, or logs OAuth tokens. It requires `account.type == "chatgpt"` and
never falls back to `OPENAI_API_KEY` / OpenAI Platform billing. There is **no**
`openai-backend` / `api.openai.com` adapter in this harness: OpenAI-model usage
on this path is subscription-only.

The default OpenRouter path is unchanged. Select the subscription backend with
CLI flags (preferred over env vars):

```bash
./bin/chat --backend codex --codex-home .codex-home --model gpt-5-codex
# or construct make-codex-app-server-backend directly
```

`--backend openai` / `HARNESS_BACKEND=openai` is a hard error (Platform API-key
billing is out of scope). Prove a working subscription session after a human
Codex login:

```
HARNESS_LIVE_CODEX_SMOKE=1 bin/verify-codex-chatgpt-auth   # subscription turn; not in make test
```

See `docs/codex-subscription-backend.md` (decision record + verified protocol
facts) and `docs/runtime.md` (credential/`CODEX_HOME` policy).

## Chat CLI

`bin/chat` runs the harness `run_shell` tool inside its Docker container. It has
three deliberately distinct modes:

```bash
# Interactive multi-turn chat (terminal stdin and stdout; /exit, /quit, Ctrl-C, or EOF ends it).
# A supervisor may supply a nonempty correlation ID; otherwise bin/chat generates one locally.
./bin/chat --model openai/gpt-4.1-mini --session-id supervisor-session-16

# Resume the most recent interactive session (restores its full prior history).
./bin/chat -c
./bin/chat --continue

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

`-c` / `--continue` resumes the most recent interactive session. After each successful turn, `bin/chat` writes the full in-memory history (including tool-call and tool-result messages, so replay is lossless) to a per-session snapshot `agent-logs/$SESSION-ID.history.json`. Resuming selects the newest snapshot, restores that history, and adopts its session id, model, and `--max-rounds` (each still overridable on the command line) so resumed turns keep appending to the same session logs. If no snapshot exists (for example a session that predates this feature), `-c` degrades gracefully to a fresh session with a note on stderr.

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

## Browser tooling (issues #37–#43)

The harness exposes a set of `browser_*` tools that let an agent drive a real
headless Chromium through [Playwright](https://playwright.dev/). They are
implemented as a three-layer stack under `src/tooling/browser/`:

- `playwright-bridge.js` — a long-running Node process that wraps the Playwright
  API and speaks line-delimited JSON-RPC over piped stdio. This is the GENERIC
  browser engine layer: no app-specific knowledge.
- `playwright-bridge.lisp` — the Lisp transport. It spawns the Node subprocess,
  frames requests/responses, and exposes `pw-call`/`pw-close` plus a
  `with-playwright-bridge` cleanup macro.
- `browser-tool.lisp` — the agent-facing `browser_*` tool handlers
  (`browser_open`, `browser_click`, `browser_type`, `browser_get_text`,
  `browser_eval`, `browser_screenshot`, `browser_assert`, `browser_close`).
  A persistent bridge is kept in the module-global `*playwright-bridge*` so the
  page stays warm across calls; `browser_open` lazily starts it and
  `browser_close` tears it down. An `sb-ext:*exit-hooks*` entry ensures the
  subprocess is reaped even if the image exits without an explicit close.

The generic layers know nothing about this harness's UI. App-specific tooling
lives in its own subdirectory: `harness-web-ui/` holds the CLOG web UI helpers
(`harness-web-ui-open`, `-start-session`, `-send-prompt`, `-assert-chat-log-contains`,
`-get-run-id`, `-screenshot`, `-close`) plus the `data-testid` selector table
that must stay in sync with the `WEB-MARK` calls in `src/web-app.lisp`.

**To add tooling for a new web app**, create a new subdirectory under
`src/tooling/browser/` (e.g. `src/tooling/browser/my-app/`) with its own
`*-tool.lisp` that imports the generic `browser_*` handlers and supplies the
app's default URL, selectors, and composite verification flows. Add the file to
`self-improving-agent-harness.asd` after `browser-tool`. Keep the generic layers
free of app-specific assumptions.

A few runtime parameters are configurable and reload-friendly (redefine them at
the REPL to change the defaults for subsequent calls): `*browser-default-url*`,
`*browser-default-timeout*` (seconds, forwarded to Playwright as ms), and
`*browser-default-screenshot-path*` (defaults to `./docs-tmp/browser-screenshot.png`). Browser screenshots and videos are saved to `./docs-tmp/` by default; this directory is gitignored and is the expected location for browser-generated artifacts.

### Verification artifact bundle

`tests/tooling/browser/harness-web-ui/harness-web-ui-integration.lisp` is a
STANDALONE integration test (not part of `RUN-TESTS`) that drives the real CLOG
web UI end-to-end and writes a per-run artifact bundle under
`/tmp/browser-verify/<run-id>/`:

- `01-initial-load.png`, `02-after-start-session.png`, `03-after-send.png` —
  full-page screenshots at each step.
- `dom-snapshots.json` — per-step `textContent` of the key `data-testid`
  elements.
- `console.log` — captured browser console / page-error messages.
- `manifest.json` — machine-readable run metadata, steps, assertions,
  screenshots, and console messages (`schema:
  self-improving-agent-harness/browser-verify/v1`).

### Running the integration test

It needs a live CLOG server (start it with `scripts/web.lisp`, serving
`http://localhost:18080/`) and a headless Chromium (baked into the Docker
image). Then:

```bash
sbcl --noinform --non-interactive \
  --load /opt/quicklisp/setup.lisp \
  --eval '(asdf:load-asd "/workspace/self-improving-agent-harness.asd")' \
  --eval '(asdf:load-system :self-improving-agent-harness)' \
  --load tests/tooling/browser/harness-web-ui/harness-web-ui-integration.lisp \
  --eval '(self-improving-agent-harness/tests:run-browser-verification-test)'
```

It returns `(VALUES PASS-P BUNDLE-DIR)`; assertion failures are recorded in the
manifest and reflected in `PASS-P` rather than raised, so a partial run still
yields evidence.

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
