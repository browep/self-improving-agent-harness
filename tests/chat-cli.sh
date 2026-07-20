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
  *'mode=one-shot prompt=stdin prompt model=openai/gpt-4.1-mini max-rounds=60'*'backend=openrouter'*) ;;
  *) printf 'Test failed: stdin prompt did not reach the driver with default backend\n' >&2; exit 1 ;;
esac

help_output=$($repo_root/bin/chat --help)
case "$help_output" in
  *'Usage: bin/chat'*'--backend BACKEND'*'--codex-home PATH'*'--session-id ID'*) ;;
  *) printf 'Test failed: help output missing session-ID/backend/codex-home guidance\n' >&2; exit 1 ;;
esac

expect_error 2 'must be a positive integer' \
  env OPENROUTER_API_KEY=test-key HARNESS_CHAT_RUNNER="$runner" "$repo_root/bin/chat" --max-rounds nope --prompt x
expect_error 2 'model must not be empty' \
  env OPENROUTER_API_KEY=test-key HARNESS_CHAT_RUNNER="$runner" "$repo_root/bin/chat" --model '' --prompt x
expect_error 2 'prompt must not be empty' \
  env OPENROUTER_API_KEY=test-key HARNESS_CHAT_RUNNER="$runner" "$repo_root/bin/chat" --prompt ''
expect_error 2 'session ID must not be empty' \
  env OPENROUTER_API_KEY=test-key HARNESS_CHAT_RUNNER="$runner" "$repo_root/bin/chat" --session-id '' --prompt x
# Point HARNESS_ENV_FILE at a path that does not exist so this exercises the
# "no key exported AND no env file" branch regardless of any local repo .env.
expect_error 2 'OPENROUTER_API_KEY must be exported' \
  env -u OPENROUTER_API_KEY HARNESS_CHAT_RUNNER="$runner" \
      HARNESS_ENV_FILE=/nonexistent/chat-cli-no-env-file "$repo_root/bin/chat" --prompt x
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


# --backend codex + --codex-home map into HARNESS_BACKEND / CODEX_HOME for the container.
expect_success 'backend=codex codex-home=/workspace/.codex-home' \
  "$repo_root/bin/chat" --backend codex --codex-home .codex-home --model gpt-5-codex --prompt 'codex path'
expect_success 'backend=codex codex-home=/workspace/.codex-home' \
  "$repo_root/bin/chat" --backend CODEX --codex-home ./.codex-home --model gpt-5-codex --prompt 'case'
# Absolute repo-relative path maps under /workspace.
repo_abs_home="$repo_root/.codex-home"
expect_success 'backend=codex codex-home=/workspace/.codex-home' \
  "$repo_root/bin/chat" --backend codex --codex-home "$repo_abs_home" --model gpt-5-codex --prompt 'abs'
# Already-container path is preserved.
expect_success 'codex-home=/workspace/custom-codex' \
  "$repo_root/bin/chat" --backend codex --codex-home /workspace/custom-codex --model gpt-5-codex --prompt 'ws'

# Codex path does not require OPENROUTER_API_KEY when no .env is visible.
expect_success 'backend=codex' \
  env -u OPENROUTER_API_KEY HARNESS_CHAT_RUNNER="$runner" \
      HARNESS_ENV_FILE=/nonexistent/chat-cli-no-env-file \
      "$repo_root/bin/chat" --backend codex --codex-home .codex-home --model gpt-5-codex --prompt 'no-or-key'

# Synthetic is a distinct OpenAI-compatible API-key backend. It has no Codex
# home and can run with SYNTHETIC_API_KEY when OpenRouter is absent.
expect_success 'backend=synthetic' \
  env -u OPENROUTER_API_KEY SYNTHETIC_API_KEY=synthetic-test-key HARNESS_CHAT_RUNNER="$runner" \
      HARNESS_ENV_FILE=/nonexistent/chat-cli-no-env-file \
      "$repo_root/bin/chat" --backend SYNTHETIC --model hf:example/model --prompt 'synthetic path'
expect_error 2 'SYNTHETIC_API_KEY must be exported' \
  env -u OPENROUTER_API_KEY -u SYNTHETIC_API_KEY HARNESS_CHAT_RUNNER="$runner" \
      HARNESS_ENV_FILE=/nonexistent/chat-cli-no-env-file \
      "$repo_root/bin/chat" --backend synthetic --prompt x

expect_error 2 'not supported' \
  env OPENROUTER_API_KEY=test-key HARNESS_CHAT_RUNNER="$runner" \
      "$repo_root/bin/chat" --backend openai --prompt x
expect_error 2 'must be openrouter, synthetic, or codex' \
  env OPENROUTER_API_KEY=test-key HARNESS_CHAT_RUNNER="$runner" \
      "$repo_root/bin/chat" --backend nope --prompt x
expect_error 2 'only valid with --backend codex' \
  env OPENROUTER_API_KEY=test-key HARNESS_CHAT_RUNNER="$runner" \
      "$repo_root/bin/chat" --codex-home .codex-home --prompt x
expect_error 2 'only valid with --backend codex' \
  env SYNTHETIC_API_KEY=synthetic-test-key HARNESS_CHAT_RUNNER="$runner" \
      "$repo_root/bin/chat" --backend synthetic --codex-home .codex-home --prompt x
expect_error 2 '--backend requires a value' \
  env OPENROUTER_API_KEY=test-key HARNESS_CHAT_RUNNER="$runner" \
      "$repo_root/bin/chat" --backend
expect_error 2 '--codex-home requires a path' \
  env OPENROUTER_API_KEY=test-key HARNESS_CHAT_RUNNER="$runner" \
      "$repo_root/bin/chat" --backend codex --codex-home
expect_error 2 'must not be empty' \
  env OPENROUTER_API_KEY=test-key HARNESS_CHAT_RUNNER="$runner" \
      "$repo_root/bin/chat" --backend codex --codex-home '' --prompt x

# CLI --backend is forwarded via --env HARNESS_BACKEND.
backend_args=$(OPENROUTER_API_KEY=test-key HARNESS_CHAT_RUNNER="$runner" \
  "$repo_root/bin/chat" --backend codex --codex-home .codex-home --model gpt-5-codex --prompt 'env forward')
case "$backend_args" in
  *'--env HARNESS_BACKEND'*'--env CODEX_HOME'*) ;;
  *) printf 'Test failed: container invocation missing HARNESS_BACKEND/CODEX_HOME env forwards: %s\n' "$backend_args" >&2; exit 1 ;;
esac

printf 'Chat CLI argument and exit-path tests passed.\n'
