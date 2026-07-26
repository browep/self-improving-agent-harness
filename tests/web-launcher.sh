#!/usr/bin/env sh
# Contract tests for bin/web without launching Docker.
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/scripts"
cp "$repo_root/bin/web" "$tmp/bin/web"
: > "$tmp/scripts/web.lisp"
cat > "$tmp/bin/container" <<'SH'
#!/usr/bin/env sh
printf '%s\n' "$@" > "${WEB_LAUNCHER_ARGS:?}"
SH
chmod +x "$tmp/bin/container" "$tmp/bin/web"

export WEB_LAUNCHER_ARGS="$tmp/args"
export HARNESS_BACKEND=claude-sdk
export HARNESS_CHAT_MAX_TOKENS=16384

# Public is the only supported exposure mode: loopback requests must be rejected
# before Docker/container execution.
if "$tmp/bin/web" --loopback >"$tmp/loopback.out" 2>"$tmp/loopback.err"; then
  echo 'bin/web accepted --loopback; Web UI must always publish externally' >&2
  exit 1
fi
grep -F -- '--loopback is not supported' "$tmp/loopback.err"

"$tmp/bin/web" --port 17881
args=$(cat "$tmp/args")
printf '%s\n' "$args" | grep -Fx -- '--publish-any'
printf '%s\n' "$args" | grep -Fx -- '17881:18080'
printf '%s\n' "$args" | grep -Fx -- 'HARNESS_BACKEND'
printf '%s\n' "$args" | grep -Fx -- 'HARNESS_CHAT_MAX_TOKENS'

echo 'web launcher tests passed.'
