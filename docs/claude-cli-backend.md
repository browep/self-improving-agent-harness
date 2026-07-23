# Claude Code CLI backend decision record

## Scope

The `claude` harness backend is a **Claude Code binary-only** adapter. It runs
the pinned `claude` executable with `-p --output-format json`; it does not call
the Anthropic Messages API and does not accept an Anthropic API key.

Authentication is a long-lived Claude subscription OAuth access token generated
outside the container with:

```bash
claude setup-token
```

At runtime the token is supplied only as `CLAUDE_CODE_OAUTH_TOKEN` in the Claude
child environment. It must not appear in argv, logs, snapshots, test fixtures,
Docker build arguments, or image layers.

## Structured result and session contract

Claude Code documents `--output-format json` as structured output containing a
text `result`, `session_id`, and request metadata. The harness maps:

| Claude CLI JSON | Harness completion response |
| --- | --- |
| `result` | `text` |
| `model` (when present) | `model` |
| `session_id` | `provider-request-id` and backend session state |
| authoritative `usage.input_tokens` / `usage.output_tokens` | token accounting |
| `total_cost_usd` (when present) | cost accounting |

The backend persists its non-secret provider session ID alongside the ordinary
harness history snapshot. Later CLI resume uses `claude -p --resume <session-id>`
rather than directory-scoped `--continue`.

## Tool-loop decision

The Claude Code CLI owns its normal agent tools. The harness must not infer
native tool calls from assistant text/XML. The current adapter invokes
`--tools ""`, which disables Claude-native tools and keeps the backend
**tool-free**. It returns no fabricated `tool_calls` to the harness loop.

It deliberately does **not** use `--bare`: current Claude Code documentation
says bare mode bypasses OAuth/keychain reads and requires API-key/helper auth,
which conflicts with this setup-token OAuth-only backend.

Official CLI documentation describes `--output-format stream-json` as
newline-delimited streaming events, but this implementation does not treat that
as sufficient proof of a stable external tool-mediation contract. Enable
harness-owned tools only after a pinned Claude CLI version is live-tested to
show structured call identifiers, names, JSON arguments, completion boundaries,
and safe tool-result continuation semantics.

## Live verification

The opt-in verification is intentionally billable and excluded from `make test`:

```bash
HARNESS_LIVE_CLAUDE_SMOKE=1 bin/verify-claude-oauth
```

It requires the pinned binary plus `CLAUDE_CODE_OAUTH_TOKEN`, runs two real
turns, and verifies structured JSON, session capture, and exact-session resume.
Only sanitized evidence is emitted.
