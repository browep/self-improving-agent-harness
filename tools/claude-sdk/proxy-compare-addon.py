#!/usr/bin/env python3
"""Expanded manifest-only Anthropic Messages comparison capture.
Never writes credential values, cookies, raw bodies, prompts, or model output.
"""
import json, os
from pathlib import Path
from mitmproxy import ctx, http

OUT = Path(os.environ.get('COMPARE_OUT', '/capture/manifest.json'))
SENSITIVE = ('authorization', 'cookie', 'token', 'secret', 'credential', 'api-key')
SAFE_RESPONSE_HEADERS = {'content-type', 'retry-after', 'anthropic-ratelimit-requests-limit', 'anthropic-ratelimit-requests-remaining', 'anthropic-ratelimit-requests-reset', 'anthropic-ratelimit-tokens-limit', 'anthropic-ratelimit-tokens-remaining', 'anthropic-ratelimit-tokens-reset', 'request-id'}

def shape(value):
    if isinstance(value, dict): return {'object': {str(k): shape(v) for k, v in sorted(value.items())}}
    if isinstance(value, list): return {'array': shape(value[0]) if value else 'unknown'}
    if isinstance(value, bool): return 'boolean'
    if isinstance(value, (int, float)): return 'number'
    if value is None: return 'null'
    return 'string'

def response(flow: http.HTTPFlow):
    request = flow.request
    if OUT.exists() or request.host.lower() != 'api.anthropic.com' or request.path.split('?', 1)[0] != '/v1/messages' or request.method != 'POST': return
    try: payload = json.loads(request.get_text(strict=False))
    except Exception: return
    headers, redacted = {}, []
    for key, value in request.headers.items(multi=False):
        key = key.lower()
        if any(marker in key for marker in SENSITIVE): redacted.append(key)
        else: headers[key] = value.strip()
    response_headers = {key.lower(): value.strip() for key, value in flow.response.headers.items(multi=False) if key.lower() in SAFE_RESPONSE_HEADERS}
    result = {'method': 'POST', 'host': 'api.anthropic.com', 'path': '/v1/messages', 'status': flow.response.status_code, 'requested_model': payload.get('model') if isinstance(payload.get('model'), str) else None, 'request_headers': headers, 'redacted_request_header_names': sorted(set(redacted)), 'payload_shape': shape(payload), 'response_headers': response_headers, 'response_content_type': flow.response.headers.get('content-type', '')}
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(result, sort_keys=True, indent=2) + '\n')
    ctx.log.info('SAFE_EXPANDED_COMPARE_MANIFEST_WRITTEN')
