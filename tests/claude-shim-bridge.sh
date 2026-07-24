#!/usr/bin/env sh
# Offline Docker framing test for the official Node bridge.  The fake SDK is
# injected via ESM module path, so no provider request or credential is used.
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
payload='{"schema":"claude-shim/v1","type":"request","model":"fake-model","prompt":"test"}'
printf '%s' "$payload" | docker run --rm --network none -i --user 1000:1000 --entrypoint node \
  --env CLAUDE_SHIM_SDK_MODULE=file:///workspace/tests/fixtures/claude-shim-fake-sdk.mjs \
  --volume "$repo_root:/workspace:ro" --workdir /workspace self-improving-agent-harness:dev \
  /workspace/tools/claude-shim/bridge.mjs | python3 -c '
import json, sys
x=json.load(sys.stdin)
assert x["schema"] == "claude-shim/v1"
assert x["text"] == "fake-final"
e=x["native_tool_events"]
assert len(e) == 1
assert e[0]["tool_call_id"] == "call-1"
assert e[0]["tool_name"] == "mcp__harness__run_shell"
assert e[0]["result"] == "bridge_ok"
assert e[0]["status"] == "completed"
print("Claude shim Docker fake-SDK framing test passed.")
'
