# Docker-first Common Lisp workflow. No host Lisp runtime is required.

.PHONY: image test run experiment-example baseline report configuration-comparison live-smoke live-tool-smoke chat repl clean

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

live-smoke:
	./bin/live-smoke

live-tool-smoke:
	./bin/live-tool-smoke

chat:
	./bin/chat

repl:
	./bin/container --noinform

clean:
	docker volume rm self-improving-agent-harness-cache 2>/dev/null || true
