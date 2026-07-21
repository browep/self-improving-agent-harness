# How the self-modifying harness works

This repository is a **research harness for evidence-driven agent improvement**.
It is not an unbounded autonomous code-deployment system. Its current loops turn
candidate changes into explicit, reproducible experiments:

```text
choose task + criteria
        ↓
generate candidate change
        ↓
run candidate with explicit budget
        ↓
persist trace, artifacts, accounting, and evaluator evidence
        ↓
retain / reject / queue with a recorded rationale
```

The important distinction is between **producing a candidate change** and
**promoting it**. A candidate may modify configuration or materialize isolated
source, but a pinned evaluator and retention decision supply the evidence used
to judge it.

## What can change today

### 1. Agent configuration candidates

The production-ready improvement surface is configuration-level mutation. The
`candidate-generator` protocol creates candidates from an explicit mutation
space. The initial deterministic generator supports these dimensions:

| Dimension | Example | Effect |
|---|---|---|
| Model ID | `offline/baseline-v1` | Selects the model/backend identity used by the candidate. |
| Prompt-template version | `repair-v2` | Selects a versioned prompt strategy. |
| Maximum rounds | `8` | Caps tool/model-loop rounds for the candidate. |
| Tool/workflow strategy | `:plan-then-act` | Selects the candidate's tool-use workflow. |

Each generated candidate has:

- a canonical configuration;
- a stable configuration hash;
- a parent candidate ID, normally the baseline;
- the same explicit wall-time, provider-call, total-token, and cost caps as
  the baseline.

Run the deterministic offline comparison:

```sh
sg docker -c 'make configuration-comparison'
```

It writes ignored artifacts at:

- `reports/configuration-comparison-v1/run.json`
- `reports/configuration-comparison-v1/run.html`

The comparison records baseline and candidate evaluator evidence, actual
provider-call/token/cost accounting, outcomes, lineage, hashes, and the
retention rationale. Retention is computed from persisted evaluator results,
not from a candidate claiming it improved itself.

### 2. Workspace edits through the chat tool

`bin/chat` exposes a `run_shell` tool in a writable workspace. A model can use
that tool to inspect, edit, test, and run code in the mounted repository when a
chat request grants it that task. This is the broadest current code-change
mechanism.

```sh
./bin/chat --model <exact-openrouter-model-id> \
  --prompt 'Inspect the repository, make the requested change, and run tests.'
```

This tool path is **not itself an automatic improvement loop**. It makes a
workspace change; a normal engineering workflow still needs to inspect the
diff, run the relevant Docker-backed verification, commit, and decide whether
to merge it. The harness's default product posture is allow-all: it does not
add a policy gate that prevents an agent from changing code. Experiment
promotion is kept separate so the evidence remains meaningful.

### 3. Structured Common Lisp source-mutation candidates

The repository also contains a deliberately narrow source-mutation prototype.
It is a candidate generator, not a general source editor. Its current mutation
language has one operation:

```lisp
(:operation :replace-function-body
 :target "fixture-score"
 :body (+ value 2))
```

The prototype:

1. reads one data-only form with reader evaluation disabled;
2. validates the operation, nonempty named target, and replacement form before
   writing a candidate;
3. locates a top-level named `DEFUN` and replaces only its body;
4. pretty-prints the resulting forms into an isolated generated candidate
   workspace;
5. writes a unified diff between the original fixture and candidate;
6. compiles and loads the generated candidate in the Docker SBCL runtime;
7. evaluates it with the pinned `pinned-offline-evaluator-v1` against a held-out
   fixture; and
8. records the mutation, validation, compilation, evaluator identity, outcome,
   and fixed decision in paired JSON/HTML report artifacts.

Run the prototype:

```sh
sg docker -c './bin/source-mutation'
```

It writes ignored artifacts at:

- `reports/source-mutation-v1/candidate/fixture.diff`
- `reports/source-mutation-v1/run.json`
- `reports/source-mutation-v1/run.html`

The current conclusion is intentionally conservative: retain this mechanism as
a fixture-scale research path only. Ordinary repository patches remain the
preferred way to make general code changes until repeated experiments establish
a measurable advantage.

## What is intentionally not self-modified during a run

For an experiment to mean anything, the candidate being measured does not
supply the evaluator or its own promotion decision for that same run. In the
current configuration and source-mutation experiments, these are pinned outside
the candidate:

- task fixture and acceptance criteria;
- evaluator identity and evaluator evidence format;
- budgets and stop conditions;
- retention/rejection rule.

This is an experimental-design rule, not a claim that the system cannot edit
those files. A normal repository patch or a separately designed meta-experiment
can change the evaluator or policy, but it must be assessed by a separately
pinned parent evaluator and held-out task set.

## Boundaries and portability

- **Docker-only runtime:** use the project wrappers; do not run host Lisp for
  project code or tests.
- **Secrets:** credentials and raw tool/provider output must not enter traces or
  reports. Accounting fields, including input/output tokens and actual cost,
  remain available for comparison.
- **Common Lisp source mutation:** form reading, printing, package creation, and
  the limited `DEFUN` transformation use ANSI Common Lisp facilities. The
  verified compile/load behavior is SBCL-specific. The prototype deliberately
  has no MOP dependency; future class/generic-function mutation would need an
  explicitly selected, implementation-specific MOP strategy.
- **No automatic deployment:** successful experimental retention is evidence for
  a candidate, not automatic production deployment or an automatic merge.

## Related implementation docs

- [Experiment model and DSL](experiment-model.md)
- [Baseline fixture and evaluator](baseline-fixture.md)
- [Structured source-mutation prototype](source-mutations.md)
- [What Common Lisp unlocks for a self-modifying LLM harness](common-lisp-harness-roadmap.md)
- [Runtime contract](runtime.md)
