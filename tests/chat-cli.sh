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

stdin_output=$(printf 'stdin prompt' | OPENROUTER_API_KEY=test-key HARNESS_CHAT_RUNNER="$runner" "$repo_root/bin/chat")
case "$stdin_output" in
  *'mode=one-shot prompt=stdin prompt model=openai/gpt-4.1-mini max-rounds=8'*) ;;
  *) printf 'Test failed: stdin prompt did not reach the driver\n' >&2; exit 1 ;;
esac

help_output=$($repo_root/bin/chat --help)
case "$help_output" in
  *'Usage: bin/chat'*'OpenRouter model ID'*) ;;
  *) printf 'Test failed: help output missing model-ID guidance\n' >&2; exit 1 ;;
esac

expect_error 2 'must be a positive integer' \
  env OPENROUTER_API_KEY=test-key HARNESS_CHAT_RUNNER="$runner" "$repo_root/bin/chat" --max-rounds nope --prompt x
expect_error 2 'model must not be empty' \
  env OPENROUTER_API_KEY=test-key HARNESS_CHAT_RUNNER="$runner" "$repo_root/bin/chat" --model '' --prompt x
expect_error 2 'prompt must not be empty' \
  env OPENROUTER_API_KEY=test-key HARNESS_CHAT_RUNNER="$runner" "$repo_root/bin/chat" --prompt ''
expect_error 2 'OPENROUTER_API_KEY must be exported' \
  env -u OPENROUTER_API_KEY HARNESS_CHAT_RUNNER="$runner" "$repo_root/bin/chat" --prompt x
expect_error 17 'driver failure propagates' \
  env OPENROUTER_API_KEY=test-key HARNESS_CHAT_RUNNER="$runner" HARNESS_FAKE_CONTAINER_STATUS=17 "$repo_root/bin/chat" --prompt x

printf 'Chat CLI argument and exit-path tests passed.\n'
