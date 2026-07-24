# Direct Claude SDK model comparison

This optional local diagnostic compares one official TypeScript Agent SDK Messages request with the Common Lisp `claude-sdk` request for the **same exact model**. It is intended to investigate a success/429 divergence without turning a capture proxy into a runtime dependency.

## Safety contract

The proxy addon persists reviewed, redacted manifests only. It excludes authorization values, cookies, API keys, credential-like payload fields, prompts, tool-result content, and model output. It retains **every other request/response header value** and a complete redacted payload view: model/configuration/metadata/tool-schema values are literal, while textual content is replaced by length markers.

Recorded evidence therefore includes method/host/path, requested model, all non-sensitive headers, names of redacted headers, complete JSON key/type shapes, full non-content configuration and tool definitions, HTTP status, response headers, and response content type.

## Run

```sh
CLAUDE_COMPARE_MODEL=claude-sonnet-5 \
  sg docker -c './tools/claude-sdk/compare-typescript-and-lisp.sh'
```

The command requires a repository-root `.env` containing the runtime OAuth token and Docker access. It creates a disposable private Docker network, a local mitmproxy instance, and a temporary capture directory. It deletes the capture directory on exit after printing its two sanitized manifests.

## Interpretation

Compare the two manifests at the same model. In particular, inspect payload shape, beta metadata, tool schema shape, retry/timeout headers, and response status/content type. A TypeScript `200 text/event-stream` versus Lisp `429 application/json` is evidence of request-contract or routing divergence; it does not by itself prove subscription exhaustion.

Do not commit local captures. Use a reviewed structural fixture only when an offline regression needs it.
