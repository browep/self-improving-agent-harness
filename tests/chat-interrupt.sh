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
}
trap cleanup EXIT HUP INT TERM

# Keep stdin open while the chat waits at its prompt; no provider request is made.
sleep 30 | env \
  OPENROUTER_API_KEY=test-key \
  HARNESS_CHAT_MODE=interactive \
  HARNESS_CHAT_MODEL=test/model \
  HARNESS_CHAT_MAX_ROUNDS=1 \
  sbcl --noinform --load scripts/chat.lisp >"$output" 2>&1 &
chat_pid=$!

# Give SBCL time to load and block in READ-LINE, then simulate terminal Ctrl-C.
sleep 1
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
