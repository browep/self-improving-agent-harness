# What Common Lisp unlocks for a self-modifying LLM harness

This document describes research directions enabled by implementing the harness
in Common Lisp. It is a roadmap for **controlled, evidence-driven** experiments,
not a design for unbounded autonomous deployment.

The current harness already provides the first pieces of this substrate:

- provider-neutral completion dispatch through the `complete` generic function;
- versioned experiment, candidate, run, evaluation, and decision records;
- a persistent tool-using chat worker that can use `reload_harness` after an
  edit; and
- an isolated-worktree supervisor that independently records Git and verification
  evidence without merging or promoting a candidate.

## The Common Lisp advantage

The advantage is not merely that an LLM can write Lisp. In Common Lisp, the
harness's executable control logic, its mutation representation, and its
runtime all share a representation based on forms and symbols. That makes a
candidate change inspectable and transformable as structured data rather than
an opaque textual patch.

### Structured, form-level candidate changes

A candidate can be represented as data such as:

```lisp
(:change :replace-function-body
 :target "choose-next-action"
 :body (choose-action-from-evaluator-state state))
```

or:

```lisp
(:change :wrap-tool
 :tool run-shell
 :with (:retry-on :transient-network-error :max-attempts 2))
```

The harness can validate the operation and target, materialize it in an
isolated candidate, compile/load it, and evaluate it against held-out tasks.
This is more reproducible than asking a model to apply arbitrary textual diffs.
The existing `:replace-function-body` source-mutation prototype is the narrow
starting point for this direction.

### Live adaptation inside a disposable candidate worker

Common Lisp permits a running worker to redefine functions and methods, then
continue the same session. The current `reload_harness` tool demonstrates this
mechanism. A candidate worker can alter a bounded behavior—for example tool
result summarization, a retry policy, or a workflow stage—and immediately
exercise that change on a fresh task.

The parent supervisor must remain outside that mutable runtime. It owns the
worktree lifecycle, task split, budgets, evaluator, report, and retain/reject
decision. A candidate's self-report is never evaluation evidence.

### Executable workflow declarations

Macros can turn agent orchestration into a compact, analyzable declaration:

```lisp
(defworkflow repair-loop
  (:budget (:max-calls 12 :max-cost-usd 0.50 :max-wall-seconds 600))
  (:tools run-shell reload-harness)
  (:stages inspect hypothesize patch verify diagnose retry-or-escalate))
```

A macro can expand that declaration into tool schemas, trace instrumentation,
budget checks, experiment registration, and executable control flow. The same
workflow can therefore be run, inspected, structurally mutated, serialized,
and tested with scripted backends.

### Composable policies through generic functions

CLOS generic functions provide narrow seams for candidate behavior. Instead of
rewriting one global agent loop, candidates can specialize discrete policies:

```lisp
(defgeneric propose-next-action (strategy state))
(defgeneric evaluate-candidate (evaluator candidate task))
(defgeneric summarize-observation (memory-policy observation))
```

Useful independently measurable dimensions include planning, tool-result
compression, model routing, retry behavior, context retrieval, task
decomposition, and evaluator ensembles. Candidate lineage can record small
method/configuration deltas rather than a large, unstructured rewrite.

### Recovery is a first-class, testable policy

Common Lisp's condition and restart system can make recoverable harness events
explicit. A provider rate limit, oversized tool result, or inconclusive
evaluation can expose a finite set of named recovery paths:

- retry with a smaller context;
- summarize an observation;
- switch a model;
- fork a candidate;
- request a human decision; or
- mark the run inconclusive.

A candidate may optimize the selection of an existing recovery path, while the
trusted harness controls which recovery paths exist and records which one ran.
This is more auditable than implicit exception handling or an unbounded retry
loop.

## Implementation bets

The following three slices build on the existing architecture while preserving
its independent-evaluation boundary.

### A. Form-level behavior-mutation DSL

Extend the fixture-scale source-mutation prototype with a deliberately small,
validated language for behavior changes:

- replace a named function or method body;
- add a method at an approved generic-function seam;
- wrap an approved tool or function;
- set a declared tunable parameter; and
- change a declared workflow stage or prompt template.

Each operation should have explicit target validation, candidate workspace
materialization, compilation/load evidence, and deterministic offline fixtures
before provider-backed experiments. It should not become a generic arbitrary
source editor.

### B. Isolated candidate image with live reload

Run each mutation-capable candidate in a disposable worker process/image while
the parent supervisor remains trusted. Allow the candidate to use
`reload_harness` for bounded source changes and continue the session; after
each turn the parent independently captures Git state and runs the pinned
verification command. Candidate mutation must never rewrite the parent
supervisor, evaluator, budget ledger, task split, or promotion rule during the
same run.

### C. Trace-to-workflow induction

Use successful, independently verified supervised sessions as inputs to propose
a parameterized workflow declaration. The LLM can suggest an abstraction, but a
validator must restrict it to known stage and tool vocabulary. Evaluate the
induced workflow on held-out related tasks against its source traces and a
baseline. The goal is a library of reusable, tested agent procedures rather
than repeatedly rediscovering the same shell/tool sequences.

## Experimental invariant

Every self-modifying experiment needs an outer trusted fixed point:

```text
trusted parent
  task split + evaluator + budgets + retention rule
        |
        v
mutable candidate
  prompt + workflow + tools + selected source/method mutations
        |
        v
candidate execution -> independently evaluated evidence -> retain/reject/queue
```

A candidate may edit code, but it must not supply the evaluator or decide its
own promotion for the same experiment. Changes to the evaluator or promotion
policy require a separate meta-experiment with a separately pinned parent
evaluator and held-out task set.

## Near-term success criteria

These bets should be judged by measured improvement, not novelty. A retained
candidate needs reproducible evidence of improved acceptance outcomes, cost,
wall time, reliability, or a declared trade-off on a held-out task suite. The
result remains a candidate: retention is not an automatic merge, deployment, or
expansion of production authority.
