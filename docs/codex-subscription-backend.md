# Codex subscription backend (ChatGPT/Codex via Codex app-server)

Status: PROPOSED. Tracks issue #18. This document is the decision record
that the issue asked for; it becomes durable only after an accepted
experiment / review.

## Decision

Model usage for this workstream MUST be sourced from the existing
ChatGPT/Codex subscription, authenticated through **Codex-managed ChatGPT
OAuth** (`chatgpt` or `chatgptDeviceCode`) behind the **official local Codex
app-server**. The harness communicates with that app-server over local
JSON-RPC. The harness does not call an undocumented ChatGPT endpoint and does
not receive, store, or replay ChatGPT OAuth credentials.

## Rejected alternative: direct OpenAI API-key billing

A direct `api.openai.com` adapter using `OPENAI_API_KEY` / OpenAI Platform
credits is **out of scope and is not an acceptable fallback**. The whole
purpose of this backend is the subsidized subscription path. Therefore:

- Missing/invalid Codex subscription auth MUST cause a hard failure.
- The implementation MUST NOT fall back to `OPENAI_API_KEY`, `api.openai.com`,
  or OpenAI Platform billing under any condition.
- `authMode: apiKey` (or any non-`chatgpt` mode) from Codex is a rejection,
  not a success.

## Token ownership boundary

Codex owns OAuth token storage and refresh. Codex caches login details either
in the OS keyring or in a plaintext `$CODEX_HOME/auth.json` depending on the
`cli_auth_credentials_store` setting (`keyring` / `file` / `auto`). The harness:

- never extracts, proxies, or replays access/refresh tokens;
- never writes any OAuth secret to `.env`, logs, reports, or prompts;
- retains only non-secret metadata (auth mode, plan type when present, safe
  capability/rate-limit info, model id, timestamps).

If Docker is used, Codex credential storage must live outside any reporting
path; host `~/.codex` is not mounted by default.

## Accounting

A subscription session is unlikely to return authoritative token/cost data.
The existing `provider-accounting-summary` convention is preserved: token and
cost fields are reported as `unavailable` with a reason unless Codex supplies
authoritative numeric values. Partial data is never summed into a total.

## Capability boundary

Codex-native command/filesystem tools stay disabled initially, and the harness
`run_shell` tool loop is not enabled in the initial Codex session, so the
existing harness-controlled worktree/evaluator boundary remains authoritative.

## References

- Codex Authentication: https://learn.chatgpt.com/docs/auth
- Codex App Server: https://learn.chatgpt.com/docs/app-server
- Codex SDK: https://learn.chatgpt.com/docs/codex-sdk

The exact JSON-RPC method surface (`account/read`, `account/login/start`,
`account/login/completed`, minimal read-only turn) is doc-derived and MUST be
validated against a pinned real Codex binary before adapter behavior is trusted.

## Verification CLI (acceptance proof)

After a human completes Codex-managed ChatGPT login, run the opt-in, billable
proof:

```
HARNESS_LIVE_CODEX_SMOKE=1 bin/verify-codex-chatgpt-auth
```

- Starts the official local `codex app-server`, reads the non-secret account
  state, and requires `authMode: chatgpt`. Missing auth, `apiKey` auth, or any
  other mode is a failure; there is no `OPENAI_API_KEY` fallback.
- Runs one bounded, tool-free turn through the same session. A completed login
  notification alone is insufficient; the turn proves the session is usable.
- Exits `0` only when both the verified auth mode and the turn succeed; non-zero
  with a redacted, actionable reason otherwise; `77` when opt-in is unset.
- Prints and persists only sanitized evidence (Codex version, timestamp, auth
  mode, non-secret plan/model, turn outcome). OAuth credentials, device codes,
  prompts, and raw provider events are never emitted or persisted. Cost/token
  fields stay `unavailable` unless Codex reports them authoritatively.
- Deliberately excluded from `make test`; exposed as `make verify-codex-chatgpt-auth`.

Deterministic coverage: `tests/codex-verify-cli.sh` (opt-in gating, Docker-free)
and `tests/codex-backend.lisp` (success/failure/redaction of the verify routine).

## Verified protocol facts (@openai/codex 0.144.6, pinned)

Validated against the pinned Codex CLI in the runtime image using
`codex app-server generate-json-schema --out <dir>` (authoritative, not doc-derived):

- `codex app-server` exists (marked experimental) and defaults to `stdio://`
  transport — matching the harness's stdio JSON-RPC supervisor.
- Handshake/account/login method strings: `initialize`, `account/read`,
  `account/login/start`, and the `account/login/completed` server notification.
  Login supports `type: "chatgpt"` and `type: "chatgptDeviceCode"`.
- `account/read` returns `{ requiresOpenaiAuth, account: { type, planType, email, ... } }`.
  The auth discriminator is `account.type` (`"chatgpt"` | `"apiKey"` | ...), NOT
  a top-level `authMode`. The harness requires `account.type == "chatgpt"` and
  drops `email` (PII) from retained evidence.
- A turn is `thread/start` (returns `{ thread: { id } }`) followed by
  `turn/start` (`{ threadId, input: [{type:"text", text}], approvalPolicy,
  sandboxPolicy }`). The harness sends `approvalPolicy: "never"` and
  `sandboxPolicy: { type: "readOnly" }` to stay tool-free and read-only.
- Assistant text streams via `item/agentMessage/delta` `{delta}` notifications
  and the turn ends at a `turn/completed` `{turn:{status,...}}` notification.
  `turn/completed` with `status: "failed"` is treated as a turn failure.

Corrected in the implementation accordingly (earlier commits used the
doc-derived `thread/runTurn` / top-level `authMode`, which are wrong).

STILL UNPROVEN and owned by an independent evaluator/human: an actual
subscription-billed live turn (`bin/verify-codex-chatgpt-auth` after a real
ChatGPT login), and confirmation that a read-only tool-free turn is accepted by
a live subscription session. The deterministic tests exercise these code paths
against a fake server shaped to the pinned schema, not a live account.

## Live app-server findings (validated by running @openai/codex 0.144.6)

Running the real `codex app-server` (installed in the image) surfaced two facts
that earlier assumptions got wrong, both now corrected and the cause of a
`verify-codex-chatgpt-auth` hang:

1. **Framing is newline-delimited JSON, not LSP Content-Length.** The app-server
   emits/accepts one compact JSON object per line over stdio; a Content-Length
   frame is rejected with "Failed to deserialize JSONRPCMessage", after which our
   reader blocked forever. `codex-encode/read-jsonrpc-message` now use
   newline-delimited framing.
2. **`params` is required even for argument-less methods.** `account/read` with
   no `params` field is rejected with `-32600 missing field \`params\``.
   `codex-jsonrpc-request` now always includes `params` (empty object default).

A per-read timeout (`*codex-request-timeout-seconds*`, default 60s) additionally
bounds the single blocking read so any future protocol mismatch surfaces a
diagnosable `CODEX-APP-SERVER-ERROR` instead of hanging.

End-to-end against the live app-server (not logged in), `verify-codex-chatgpt-auth`
now completes in seconds and fails cleanly with
`no Codex ChatGPT session; run the managed login first (authMode is unset)` --
no hang, no timeout, no OPENAI_API_KEY fallback. A real ChatGPT login is still
required to prove the authenticated turn (acceptance criterion #1).
