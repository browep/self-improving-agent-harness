#!/usr/bin/env python3
"""Manifest-only mitmproxy addon for the one-off Claude subscription capture.

It deliberately never saves flows or request/response bodies. The only output is
one structurally sanitized contract manifest for a successful Anthropic Messages
request. This is capture tooling, never a harness runtime dependency.
"""
from __future__ import annotations

import json
import os
import re
from datetime import datetime, timezone
from pathlib import Path

from mitmproxy import ctx, http

OUTPUT = Path(os.environ.get("CLAUDE_SDK_CAPTURE_MANIFEST", "/capture/claude-sdk-subscription-contract.v1.json"))
EXPECTED_HOST = "api.anthropic.com"
EXPECTED_PATH = "/v1/messages"
ALLOW_HEADERS = {
    "accept", "content-type", "user-agent", "anthropic-version", "anthropic-beta",
    "x-app", "x-client-version", "x-stainless-lang", "x-stainless-package-version",
    "x-stainless-os", "x-stainless-arch", "x-stainless-runtime", "x-stainless-runtime-version",
}
FORBIDDEN_HEADER_PARTS = ("authorization", "cookie", "token", "secret", "credential", "api-key")
CREDENTIAL_VALUE = re.compile(r"(?i)(bearer\s+|^[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}$)")

class CaptureError(RuntimeError):
    pass

def json_shape(value):
    if isinstance(value, dict):
        return {"kind": "object", "fields": {str(k): json_shape(v) for k, v in sorted(value.items())}}
    if isinstance(value, list):
        # Do not retain scalar content. A single representative shape is enough.
        return {"kind": "array", "items": json_shape(value[0]) if value else {"kind": "unknown"}}
    if isinstance(value, str): return {"kind": "string"}
    if isinstance(value, bool): return {"kind": "boolean"}
    if isinstance(value, (int, float)): return {"kind": "number"}
    if value is None: return {"kind": "null"}
    raise CaptureError("unsupported JSON value in request shape")

def safe_headers(headers):
    result = {}
    for name, value in headers.items(multi=False):
        lowered = name.lower()
        if lowered not in ALLOW_HEADERS:
            continue
        if any(part in lowered for part in FORBIDDEN_HEADER_PARTS):
            continue
        value = value.strip()
        if not value or len(value) > 512 or not value.isprintable() or CREDENTIAL_VALUE.search(value):
            raise CaptureError(f"unsafe allowlisted header value for {lowered}")
        result[lowered] = value
    return result

class ClaudeSdkContractCapture:
    def __init__(self):
        self.candidates = 0
        self.failure = None

    def response(self, flow: http.HTTPFlow):
        try:
            request = flow.request
            if request.host.lower() != EXPECTED_HOST or request.path.split("?", 1)[0] != EXPECTED_PATH:
                return
            if request.method.upper() != "POST":
                raise CaptureError("unexpected method for Anthropic Messages request")
            self.candidates += 1
            # Claude Code can issue a second internal Messages request during a
            # single one-shot turn. Persist only the first successful observed
            # contract; ignore later candidates without retaining their data.
            if self.candidates != 1:
                return
            if flow.response.status_code < 200 or flow.response.status_code >= 300:
                raise CaptureError(f"provider returned non-success status {flow.response.status_code}")
            payload = json.loads(request.get_text(strict=False))
            if not isinstance(payload, dict):
                raise CaptureError("request JSON root is not an object")
            request_headers = safe_headers(request.headers)
            if "user-agent" not in request_headers or "content-type" not in request_headers:
                raise CaptureError("captured request lacks required safe protocol headers")
            response_headers = safe_headers(flow.response.headers)
            manifest = {
                "schema": "self-improving-agent-harness/claude-sdk-contract/v1",
                "provenance": {
                    "official_client": "claude-code",
                    "official_client_version": os.environ.get("CLAUDE_CODE_CAPTURE_VERSION", "unknown"),
                    "capture_date_utc": datetime.now(timezone.utc).date().isoformat(),
                    "capture_procedure": "docs/claude-sdk-capture.md",
                    "network_scope": "ephemeral Docker-only local MITM proxy",
                    "turn_kind": "one minimal text-only subscription turn; observed official client transport may stream",
                },
                "request": {"method": request.method.upper(), "host": EXPECTED_HOST,
                            "path": EXPECTED_PATH, "headers": request_headers,
                            "payload_shape": json_shape(payload)},
                "response": {"status": flow.response.status_code,
                             "headers": {k: v for k, v in response_headers.items() if k == "content-type"}},
            }
            OUTPUT.parent.mkdir(parents=True, exist_ok=True)
            OUTPUT.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
            ctx.log.info("CLAUDE_SDK_CAPTURE manifest-written")
        except Exception as exc:
            self.failure = str(exc)
            ctx.log.error("CLAUDE_SDK_CAPTURE failed: " + self.failure)

addons = [ClaudeSdkContractCapture()]
