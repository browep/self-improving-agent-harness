#!/usr/bin/env sh
# Exercise bin/chat parsing and exit behavior inside the Docker test runtime.
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
runner="$repo_root/tests/fake-chat-container.sh"

expect_success() {
  expected=$1
  shift
  output=$(OPENROUTER_API_KEY=test-key HARNESS_CHAT_RUNNER="$runner" "$@")
  case "$output" in
    *"$expected"*) ;;
    *) printf 'Test failed: expected %s in %s\n' "$expected" "$output" >&2; exit 1 ;;
  esac
}

expect_error() {
  expected_status=$1
  expected_text=$2
  shift 2
  set +e
  output=$("$@" 2>&1)
  status=$?
  set -e
  [ "$status" -eq "$expected_status" ] || {
    printf 'Test failed: expected exit %s, got %s\n' "$expected_status" "$status" >&2
    exit 1
  }
  case "$output" in
    *"$expected_text"*) ;;
    *) printf 'Test failed: expected %s in %s\n' "$expected_text" "$output" >&2; exit 1 ;;
  esac
}

expect_success 'mode=one-shot prompt=flag prompt model=test/model max-rounds=3' \
  "$repo_root/bin/chat" --model test/model --max-rounds 3 --prompt 'flag prompt'

# Default --session-id is an ISO-8601 UTC timestamp (...T...Z).
generated_session_output=$(OPENROUTER_API_KEY=test-key HARNESS_CHAT_RUNNER="$runner" \
  "$repo_root/bin/chat" --prompt 'generated correlation check')
case "$generated_session_output" in
  *'session-id='[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T*[Zz]*) ;;
  *) printf 'Test failed: expected ISO timestamp session-id in %s\n' "$generated_session_output" >&2; exit 1 ;;
esac

expect_success 'session-id=supervisor-session-16' \
  "$repo_root/bin/chat" --session-id supervisor-session-16 --prompt 'correlation check'

workspace_output=$(OPENROUTER_API_KEY=test-key HARNESS_CHAT_RUNNER="$runner" \
  "$repo_root/bin/chat" --prompt 'workspace check')
case "$workspace_output" in
  *'args=--writable-workspace --env HARNESS_CHAT_MODE'*) ;;
  *) printf 'Test failed: chat did not request a writable workspace\n' >&2; exit 1 ;;
esac

stdin_output=$(printf 'stdin prompt' | OPENROUTER_API_KEY=test-key HARNESS_CHAT_RUNNER="$runner" "$repo_root/bin/chat")
case "$stdin_output" in
  *'mode=one-shot prompt=stdin prompt model=openai/gpt-4.1-mini max-rounds=60'*) ;;
  *) printf 'Test failed: stdin prompt did not reach the driver\n' >&2; exit 1 ;;
esac

help_output=$($repo_root/bin/chat --help)
case "$help_output" in
  *'Usage: bin/chat'*'--session-id ID'*'OpenRouter model ID'*) ;;
  *) printf 'Test failed: help output missing session-ID or model-ID guidance\n' >&2; exit 1 ;;
esac

expect_error 2 'must be a positive integer' \
  env OPENROUTER_API_KEY=test-key HARNESS_CHAT_RUNNER="$runner" "$repo_root/bin/chat" --max-rounds nope --prompt x
expect_error 2 'model must not be empty' \
  env OPENROUTER_API_KEY=test-key HARNESS_CHAT_RUNNER="$runner" "$repo_root/bin/chat" --model '' --prompt x
expect_error 2 'prompt must not be empty' \
  env OPENROUTER_API_KEY=test-key HARNESS_CHAT_RUNNER="$runner" "$repo_root/bin/chat" --prompt ''
expect_error 2 'session ID must not be empty' \
  env OPENROUTER_API_KEY=test-key HARNESS_CHAT_RUNNER="$runner" "$repo_root/bin/chat" --session-id '' --prompt x
expect_error 2 'OPENROUTER_API_KEY must be exported' \
  env -u OPENROUTER_API_KEY HARNESS_CHAT_RUNNER="$runner" "$repo_root/bin/chat" --prompt x
expect_error 17 'driver failure propagates' \
  env OPENROUTER_API_KEY=test-key HARNESS_CHAT_RUNNER="$runner" HARNESS_FAKE_CONTAINER_STATUS=17 "$repo_root/bin/chat" --prompt x

# -c / --continue sets HARNESS_CHAT_RESUME and leaves the session id empty so the
# Lisp side can adopt the most recent snapshot's id.
expect_success 'resume=1' \
  "$repo_root/bin/chat" -c --prompt 'resume flag check'
resume_output=$(OPENROUTER_API_KEY=test-key HARNESS_CHAT_RUNNER="$runner" \
  "$repo_root/bin/chat" --continue --prompt 'resume long flag')
case "$resume_output" in
  *'session-id= resume=1'*) ;;
  *) printf 'Test failed: -c should leave session-id empty and set resume=1: %s\n' "$resume_output" >&2; exit 1 ;;
esac

# --help documents -c/--continue.
case "$help_output" in
  *'--continue'*) ;;
  *) printf 'Test failed: help output missing --continue guidance\n' >&2; exit 1 ;;
esac

printf 'Chat CLI argument and exit-path tests passed.\n'
