#!/usr/bin/env bash
# Disposable same-model TypeScript Agent SDK vs direct Lisp comparison.
set -euo pipefail
repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
image=${HARNESS_IMAGE:-self-improving-agent-harness:dev}
model=${CLAUDE_COMPARE_MODEL:-claude-sonnet-5}
work=$(mktemp -d /tmp/claude-sdk-compare.XXXXXX)
net=claude-sdk-compare-$$
proxy=claude-sdk-compare-proxy-$$
cleanup() { docker rm -f "$proxy" >/dev/null 2>&1 || true; docker network rm "$net" >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT
[ -f "$repo/.env" ] || { echo 'comparison requires runtime .env' >&2; exit 2; }
docker network create "$net" >/dev/null
start_proxy() { docker run -d --name "$proxy" --network "$net" -v "$repo/tools/claude-sdk/proxy-compare-addon.py:/addon.py:ro" -v "$work:/capture" -e COMPARE_OUT=/capture/manifest.json mitmproxy/mitmproxy:11.1.2 mitmdump --quiet --set confdir=/capture -s /addon.py >/dev/null; }
start_proxy
for _ in $(seq 1 30); do [ -s "$work/mitmproxy-ca-cert.pem" ] && break; sleep 1; done
[ -s "$work/mitmproxy-ca-cert.pem" ] || { echo 'proxy CA unavailable' >&2; exit 1; }
docker run --rm --init --network "$net" --env-file "$repo/.env" --env CLAUDE_TEST_MODEL="$model" --env HTTPS_PROXY=http://"$proxy":8080 --env HTTP_PROXY=http://"$proxy":8080 --env NODE_EXTRA_CA_CERTS=/capture/mitmproxy-ca-cert.pem -v "$work:/capture:ro" -v "$repo/tools/claude-sdk/typescript-model-control.mjs:/work/control.mjs:ro" -w /work --entrypoint /bin/sh "$image" -lc 'npm install --no-save --no-fund --no-audit @anthropic-ai/claude-agent-sdk >/dev/null && node control.mjs >/dev/null'
[ -s "$work/manifest.json" ] || { echo 'TypeScript manifest missing' >&2; exit 1; }
mv "$work/manifest.json" "$work/typescript-sdk.json"
mv "$work/all-manifests.json" "$work/typescript-sdk-all.json"
docker rm -f "$proxy" >/dev/null
start_proxy
set +e
docker run --rm --init --network "$net" --env-file "$repo/.env" --env HARNESS_BACKEND=claude-sdk --env HARNESS_CHAT_MODE=one-shot --env HARNESS_CHAT_MODEL="$model" --env HARNESS_CHAT_MAX_ROUNDS=1 --env HARNESS_CHAT_SESSION_ID=proxy-compare --env HARNESS_CHAT_PROMPT=DIRECT_SSE_OK --env CLAUDE_SDK_PROXY="$proxy":8080 --env HTTPS_PROXY=http://"$proxy":8080 --env HTTP_PROXY=http://"$proxy":8080 -v "$work:/capture:ro" -v "$repo:/workspace:ro" -v self-improving-agent-harness-cache:/cache -v self-improving-agent-harness-logs:/logs -w /workspace --entrypoint /bin/sh "$image" -lc 'cp /capture/mitmproxy-ca-cert.pem /usr/local/share/ca-certificates/compare.crt && update-ca-certificates >/dev/null && exec sbcl --noinform --load scripts/chat.lisp -- --backend claude-sdk --model "$HARNESS_CHAT_MODEL" --prompt "Return exactly: DIRECT_SSE_OK" --max-rounds 1' >/tmp/claude-sdk-proxy-lisp-diagnostic.txt 2>&1
set -e
[ -s "$work/manifest.json" ] || { tail -n 40 /tmp/claude-sdk-proxy-lisp-diagnostic.txt >&2; exit 1; }
mv "$work/manifest.json" "$work/lisp-sdk.json"
mv "$work/all-manifests.json" "$work/lisp-sdk-all.json"
python3 - "$work" <<'PY'
import json, sys
for name in ('typescript-sdk-all.json', 'lisp-sdk-all.json'):
    flows = json.load(open(f'{sys.argv[1]}/{name}'))
    matching = [flow for flow in flows if flow['requested_model'] == 'claude-sonnet-5']
    print(json.dumps({'capture': name, 'matching_sonnet5_flows': matching}, sort_keys=True))
PY
