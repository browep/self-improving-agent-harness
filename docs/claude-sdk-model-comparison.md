# Direct Claude SDK model comparison

This optional local diagnostic compares one official TypeScript Agent SDK Messages request with the Common Lisp `claude-sdk` request for the **same exact model**. It is intended to investigate a success/429 divergence without turning a capture proxy into a runtime dependency.

## Safety contract

The runner accepts `CLAUDE_CODE_OAUTH_TOKEN` only through the normal Docker runtime environment. It never prints or stores its value. The proxy addon persists manifests only, and excludes authorization values, cookies, API keys, request/response bodies, prompts, and model output.

Recorded evidence is limited to method/host/path, requested model, non-sensitive headers, names of redacted headers, JSON key/type shapes, HTTP status, response content type, and safe rate-limit/request metadata.

## Run

```sh
CLAUDE_COMPARE_MODEL=claude-sonnet-5 \
  sg docker -c './tools/claude-sdk/compare-typescript-and-lisp.sh'
```

The command requires a repository-root `.env` containing the runtime OAuth token and Docker access. It creates a disposable private Docker network, a local mitmproxy instance, and a temporary capture directory. It deletes the capture directory on exit after printing its two sanitized manifests.

## Interpretation

Compare the two manifests at the same model. In particular, inspect payload shape, beta metadata, tool schema shape, retry/timeout headers, and response status/content type. A TypeScript `200 text/event-stream` versus Lisp `429 application/json` is evidence of request-contract or routing divergence; it does not by itself prove subscription exhaustion.

Do not commit local captures. Use a reviewed structural fixture only when an offline regression needs it.
