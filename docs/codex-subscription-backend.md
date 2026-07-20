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
