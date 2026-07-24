#!/usr/bin/env sh
# Offline Docker framing test for the official Node bridge. The fake SDK is
# injected via ESM module path, so no provider request or credential is used.
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
run() {
  prompt=$1
  printf '{"schema":"claude-shim/v1","type":"request","model":"fake-model","prompt":"%s"}' "$prompt" |
    docker run --rm --network none -i --user 1000:1000 --entrypoint node \
      --env CLAUDE_SHIM_SDK_MODULE=file:///workspace/tests/fixtures/claude-shim-fake-sdk.mjs \
      --volume "$repo_root:/workspace:ro" --workdir /workspace self-improving-agent-harness:dev \
      /workspace/tools/claude-shim/bridge.mjs
}
run one | python3 -c '
import json,sys
x=json.load(sys.stdin); e=x["native_tool_events"]
assert x["text"] == "fake-final" and len(e) == 1
assert e[0]["tool_call_id"] == "call-1" and e[0]["result"] == "bridge_ok" and e[0]["status"] == "completed"
'
run no-tool | python3 -c 'import json,sys; assert json.load(sys.stdin)["native_tool_events"] == []'
run sequential | python3 -c '
import json,sys
x=json.load(sys.stdin)["native_tool_events"]
assert [(e["tool_call_id"],e["result"],e["status"]) for e in x] == [("call-1","first","completed"),("call-2","second","completed")]
'
run failed | python3 -c '
import json,sys
e=json.load(sys.stdin)["native_tool_events"][0]
assert e["tool_call_id"] == "call-1" and e["result"] == "exit 9" and e["status"] == "failed"
'
if run malformed >/tmp/claude-shim-malformed.stdout 2>/tmp/claude-shim-malformed.stderr; then
  echo 'malformed SDK event unexpectedly succeeded' >&2; exit 1
fi
grep -q 'malformed SDK message content' /tmp/claude-shim-malformed.stderr
printf '%s\n' 'Claude shim Docker fake-SDK framing tests passed.'
