#!/usr/bin/env python3
"""Expanded, redacted Anthropic Messages comparison capture.

The manifest preserves all non-secret request and response header values plus
all non-content payload values. It redacts credentials, cookies, secret-like
payload fields, prompts, tool-result content, and provider output.
"""
import json
import os
from pathlib import Path

from mitmproxy import ctx, http

OUT = Path(os.environ.get("COMPARE_OUT", "/capture/manifest.json"))
SENSITIVE = ("authorization", "cookie", "token", "secret", "credential", "api-key", "api_key", "password")
CONTENT_SAFE_KEYS = {"type", "name", "id", "tool_use_id", "tool-use-id", "cache_control"}


def shape(value):
    if isinstance(value, dict):
        return {"object": {str(k): shape(v) for k, v in sorted(value.items())}}
    if isinstance(value, list):
        return {"array": shape(value[0]) if value else "unknown"}
    if isinstance(value, bool):
        return "boolean"
    if isinstance(value, (int, float)):
        return "number"
    if value is None:
        return "null"
    return "string"


def is_sensitive_name(name):
    normalized = str(name).lower().replace("-", "_")
    if normalized in {"max_tokens", "thinking_token_count"}:
        return False
    return any(marker in normalized for marker in SENSITIVE)


def header_items(headers):
    """Support both mitmproxy Headers and ordinary mappings in offline tests."""
    try:
        return headers.items(multi=False)
    except TypeError:
        return headers.items()


def sanitize_headers(headers):
    """Keep every header value except credential/cookie-like headers."""
    kept, redacted = {}, []
    for key, value in header_items(headers):
        key = str(key).lower()
        if is_sensitive_name(key):
            redacted.append(key)
        else:
            kept[key] = str(value).strip()
    return kept, sorted(set(redacted))


def redacted_text(value):
    if isinstance(value, str):
        return f"<redacted:{len(value)}-chars>"
    if isinstance(value, list):
        return [redacted_text(item) for item in value]
    if isinstance(value, dict):
        return {
            str(key): (value if str(key) in CONTENT_SAFE_KEYS else redacted_text(value))
            for key, value in value.items()
        }
    return value


def sanitize_payload(value):
    """Retain a complete non-content payload view without retaining raw bodies.

    The top-level Messages `system` and `messages[*].content` fields can carry
    prompts or tool outputs, so textual values below those fields are replaced
    with bounded length markers. Tool definitions and non-content configuration
    retain their literal values for protocol comparison.
    """
    if isinstance(value, list):
        return [sanitize_payload(item) for item in value]
    if not isinstance(value, dict):
        return value

    sanitized = {}
    for key, child in value.items():
        key = str(key)
        if is_sensitive_name(key):
            sanitized[key] = "<redacted>"
        elif key == "system":
            sanitized[key] = redacted_text(child)
        elif key == "messages" and isinstance(child, list):
            sanitized[key] = [
                {
                    str(message_key): (
                        redacted_text(message_value)
                        if str(message_key) == "content"
                        else sanitize_payload(message_value)
                    )
                    for message_key, message_value in message.items()
                }
                if isinstance(message, dict) else sanitize_payload(message)
                for message in child
            ]
        else:
            sanitized[key] = sanitize_payload(child)
    return sanitized


def safe_payload_metadata(payload):
    """Small stable summary retained alongside the complete redacted payload."""
    def object_value(value, key):
        return value.get(key) if isinstance(value, dict) else None

    output = {
        "system_content_kind": (
            "array" if isinstance(payload.get("system"), list)
            else "string" if isinstance(payload.get("system"), str)
            else "absent"
        ),
        "message_content_kinds": sorted({
            "array" if isinstance(item.get("content"), list)
            else "string" if isinstance(item.get("content"), str)
            else "other"
            for item in payload.get("messages", [])
            if isinstance(item, dict)
        }),
    }
    for source, key in (("thinking", "type"), ("output_config", "effort")):
        value = object_value(payload.get(source), key)
        if isinstance(value, (str, bool, int, float)) or value is None:
            output[f"{source}_{key}"] = value
    return output


def response(flow: http.HTTPFlow):
    request = flow.request
    if (
        request.host.lower() != "api.anthropic.com"
        or request.path.split("?", 1)[0] != "/v1/messages"
        or request.method != "POST"
    ):
        return
    try:
        payload = json.loads(request.get_text(strict=False))
    except Exception:
        return

    request_headers, redacted_request_headers = sanitize_headers(request.headers)
    response_headers, redacted_response_headers = sanitize_headers(flow.response.headers)
    result = {
        "method": "POST",
        "host": "api.anthropic.com",
        "path": "/v1/messages",
        "status": flow.response.status_code,
        "requested_model": payload.get("model") if isinstance(payload.get("model"), str) else None,
        "request_headers": request_headers,
        "redacted_request_header_names": redacted_request_headers,
        "payload": sanitize_payload(payload),
        "payload_shape": shape(payload),
        "safe_payload_metadata": safe_payload_metadata(payload),
        "response_headers": response_headers,
        "redacted_response_header_names": redacted_response_headers,
        "response_content_type": flow.response.headers.get("content-type", ""),
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    all_out = OUT.with_name("all-manifests.json")
    try:
        captured = json.loads(all_out.read_text()) if all_out.exists() else []
    except Exception:
        captured = []
    captured.append(result)
    all_out.write_text(json.dumps(captured, sort_keys=True, indent=2) + "\n")
    if not OUT.exists():
        OUT.write_text(json.dumps(result, sort_keys=True, indent=2) + "\n")
    ctx.log.info("REDACTED_FULL_COMPARE_MANIFEST_WRITTEN")
