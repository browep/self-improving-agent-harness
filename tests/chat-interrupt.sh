#!/usr/bin/env sh
# Verify SIGINT leaves the interactive chat process without entering SBCL's debugger.
set -eu

output=$(mktemp)
input_pid=
chat_pid=
cleanup() {
  [ -z "$chat_pid" ] || kill "$chat_pid" 2>/dev/null || true
  [ -z "$input_pid" ] || kill "$input_pid" 2>/dev/null || true
  rm -f "$output"
  [ -z "${fifo:-}" ] || rm -f "$fifo"
}
trap cleanup EXIT HUP INT TERM

# Keep stdin open while the chat waits at its prompt; no provider request is made.
# Use a FIFO fed by a tracked background `sleep` rather than an anonymous pipe:
# an anonymous `sleep 30 | ...` writer inherits the child's stdout pipe and, once
# the chat exits early on SIGINT (the whole point of this test), lingers for the
# full sleep holding that pipe open. That blocks readers of run-tests.lisp's
# captured output and hangs `make test`. Tracking the holder's PID lets cleanup
# release it immediately.
fifo=$(mktemp -u)
mkfifo "$fifo"
( sleep 30 >"$fifo" 2>/dev/null || true ) &
input_pid=$!
env \
  OPENROUTER_API_KEY=test-key \
  HARNESS_CHAT_MODE=interactive \
  HARNESS_CHAT_MODEL=test/model \
  HARNESS_CHAT_MAX_ROUNDS=1 \
  HARNESS_CHAT_SESSION_ID=interrupt-session-test \
  sbcl --noinform --load scripts/chat.lisp <"$fifo" >"$output" 2>&1 &
chat_pid=$!

# Wait until the script has loaded and is blocked in READ-LINE before SIGINT.
ready=false
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30; do
  if grep -F ' >>>' "$output" >/dev/null 2>&1; then
    ready=true
    break
  fi
  if ! kill -0 "$chat_pid" 2>/dev/null; then
    break
  fi
  sleep 0.1
done
if [ "$ready" = false ]; then
  wait "$chat_pid" 2>/dev/null || true
  printf '%s\n' 'Test failed: interactive chat never reached its prompt.' >&2
  exit 1
fi
kill -INT "$chat_pid"

exited=false
for _ in 1 2 3 4 5 6 7 8 9 10; do
  if ! kill -0 "$chat_pid" 2>/dev/null; then
    exited=true
    break
  fi
  sleep 0.1
done

if [ "$exited" = false ]; then
  kill -TERM "$chat_pid" 2>/dev/null || true
  wait "$chat_pid" 2>/dev/null || true
  printf '%s\n' 'Test failed: Ctrl-C did not end the interactive chat process.' >&2
  exit 1
fi

set +e
wait "$chat_pid"
status=$?
set -e
[ "$status" -eq 0 ] || {
  printf 'Test failed: expected Ctrl-C exit status 0, got %s\n' "$status" >&2
  exit 1
}

grep -F 'Interrupted; leaving interactive chat.' "$output" >/dev/null || {
  printf '%s\n' 'Test failed: Ctrl-C exit message missing.' >&2
  exit 1
}
if grep -F 'debugger invoked' "$output" >/dev/null; then
  printf '%s\n' 'Test failed: Ctrl-C entered the SBCL debugger.' >&2
  exit 1
fi

printf 'Interactive Ctrl-C exit test passed.\n'
