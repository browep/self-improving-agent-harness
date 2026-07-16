# Baseline fixture and evaluator

Issue #12's fixed offline baseline is `fixtures/baseline-answer-v1.lisp`.
The fixture is versioned (`:version "1"`), declares the user input and its
acceptance command, and declares the run budget:

- `:max-wall-seconds` bounds every acceptance command;
- `:max-provider-calls` bounds the backend/tool-loop path;
- `:max-total-tokens` bounds reported completion usage when available; and
- `:max-cost-usd` is explicit (the scripted path has zero cost).

The fixture does not configure its evaluator.  `run-baseline-fixture` owns the
deterministic command evaluator, so candidate configuration cannot replace its
acceptance checks.  The harness otherwise preserves its default allow-all
posture.

## Rerun

From the repository root, using only the Docker Lisp runtime:

```bash
sg docker -c 'make baseline'
```

This is a credential-free scripted end-to-end run.  The scripted backend emits
the normal `submit_candidate` tool call, the existing `run-tool-loop` executes
that handler and continuation, and the evaluator runs the fixture command.
The result prints one sanitized plist.  Evidence includes only check name,
status, and exit code; it intentionally excludes candidate and command output.

Outcomes are `:success`, `:acceptance-failure` (a completed candidate did not
pass an acceptance command), and `:execution-failure` (for example tool-loop
or command-execution/budget failure).  The normalizer has Docker-offline unit
tests for both pass and fail exit codes.
