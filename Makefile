# Docker-first Common Lisp workflow. No host Lisp runtime is required.

.PHONY: image test run experiment-example baseline report configuration-comparison source-mutation live-smoke live-tool-smoke live-synthetic-smoke live-synthetic-tool-smoke live-chat-supervisor-tool-smoke verify-codex-chatgpt-auth chat web repl clean

image:
	docker build --tag self-improving-agent-harness:dev .

test:
	./bin/test

run:
	./bin/run

experiment-example:
	./bin/experiment-example

baseline:
	./bin/baseline

report:
	./bin/report

configuration-comparison:
	./bin/configuration-comparison

source-mutation:
	./bin/source-mutation

live-smoke:
	./bin/live-smoke

live-tool-smoke:
	./bin/live-tool-smoke

# Opt-in paid Synthetic evidence; deliberately not a dependency of test.
live-synthetic-smoke:
	./bin/live-synthetic-smoke

live-synthetic-tool-smoke:
	./bin/live-synthetic-tool-smoke

# Opt-in paid OpenRouter evidence; deliberately not a dependency of test.
live-chat-supervisor-tool-smoke:
	./tests/chat-supervisor-live-tool-smoke.sh

# Opt-in, billable Codex ChatGPT subscription verification; NOT a dependency of
# test. Requires HARNESS_LIVE_CODEX_SMOKE=1 and a completed Codex ChatGPT login.
verify-codex-chatgpt-auth:
	./bin/verify-codex-chatgpt-auth

chat:
	./bin/chat

web:
	./bin/web

repl:
	./bin/container --noinform

clean:
	docker volume rm self-improving-agent-harness-cache 2>/dev/null || true
