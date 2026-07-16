# Experiment model and DSL

Issue #11 defines the first provider-independent experiment boundary.  It turns
experiment setup into inspectable data; it does **not** start a provider, run an
agent, evaluate a candidate, or promote a change.

## Public model

`experiment` is a complete immutable-by-convention specification containing:

- a stable `id`;
- `task-fixture` and `acceptance-criteria` owned by the task;
- `agent-configuration` owned by the candidate/agent execution path;
- an `evaluator` descriptor owned independently by evaluation code; and
- an explicit `budget` descriptor.

`candidate` has an explicitly supplied stable `id`, the owning experiment ID,
optional `parent-id`, and candidate configuration.  Use
`materialize-candidate` to guarantee parent candidates remain in the same
experiment.  Explicit IDs avoid hidden randomness and make lineage joinable by
later trace/report stores.

`run-record` holds execution facts (outcome, trace reference, usage, and cost).
`evaluation` holds an evaluator-owned verdict and evidence.  `decision` holds a
retention/queue/rejection action, rationale, and optional evaluation reference.
These are deliberately separate types: a candidate cannot redefine its
evaluator or promotion decision merely by changing agent configuration.

## DSL

Use `defexperiment` for checked-in declarations:

```lisp
(defexperiment offline-summary-example
  :id "offline-summary-example"
  :task-fixture '(:kind :inline :input "Summarize this fixture.")
  :acceptance-criteria '((:kind :contains :value "summary"))
  :agent-configuration '(:backend :scripted :model "offline/example")
  :evaluator '(:kind :deterministic :id "offline-summary-check")
  :budget '(:max-runs 1 :max-provider-calls 0 :max-cost-usd 0))
```

The macro binds the named variable, then calls `register-experiment`.
Registration calls `validate-experiment`, so a missing required field signals
before any provider/agent execution API is involved.  The complete runnable
example is [`examples/offline-summary.lisp`](../examples/offline-summary.lisp).

## Serialization and extension points

`serialize-domain-object` is the stable integration boundary.  It returns a
provider-neutral plist with `:schema-version` currently set to `"1"` and a
string `:type` (`"experiment"`, `"candidate"`, `"run-record"`,
`"evaluation"`, or `"decision"`).  Future JSON, trace, and report adapters
must preserve those two fields and add a new schema version rather than silently
changing their meaning.

Task fixture formats, criterion kinds, agent configuration keys, evaluator
implementations, budget dimensions, trace stores, and decision policies are
extension points represented as data by this model.  No provider is prescribed
by this boundary.  Evaluators and promotion policies should consume serialized
records rather than being embedded in agent configuration.

## Run offline

No credential or provider call is needed:

```bash
make experiment-example
```

The command uses the Docker runtime with networking disabled and prints the
versioned serialized experiment specification.
