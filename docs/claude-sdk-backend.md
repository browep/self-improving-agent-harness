# Claude Agent SDK direct backend (issue #68)

## Scope

`claude-sdk` registers a selectable backend that is intentionally **separate**
from the CLI-spawning `claude` backend (`docs/claude-cli-backend.md`). It
speaks the Anthropic Messages HTTP API directly (`POST
https://api.anthropic.com/v1/messages`) over Drakma, rather than spawning the
`claude` binary.

Today `claude-sdk`:

- Registers in CLI/backend selection (`--backend claude-sdk`,
  `HARNESS_BACKEND=claude-sdk`, case-insensitively), help text, and runtime
  documentation, exactly like every other backend.
- Never spawns the `claude` binary. It performs real HTTPS I/O via an
  injectable `TRANSPORT` seam; every offline test replaces that seam with a
  fake function, so no test in this suite opens a socket.
- Requires `CLAUDE_CODE_OAUTH_TOKEN` — the same runtime-only setup-token
  credential used by `claude` — but only at completion time, not at backend
  construction or CLI argument parsing.
- Never reads or falls back to `ANTHROPIC_API_KEY` under any circumstance.
  `src/claude-sdk-backend.lisp` never mentions that variable at all, and an
  offline test asserts that fact directly against the source text.
- Sends a text-only request: `model`, `messages` (system-role turns are lifted
  into the top-level `system` field; user/assistant turns are forwarded as
  plain text), `max_tokens` (from the request's `:max-tokens` option, a
  per-backend override, or a conservative default, in that priority), and
  `stream: true`. No `tools`, no `tool_choice`, no resume/session field.
- Buffers and decodes the streamed Server-Sent Events response internally and
  normalizes it into exactly one `completion-response` — callers of `complete`
  never see partial deltas, matching every other backend's contract.
- Maps non-2xx HTTP responses and mid-stream `error` SSE frames to a bounded
  `claude-sdk-backend-error` that names the provider's error type/message but
  never echoes the OAuth token, request headers, or an unbounded raw body.

## Non-goals (this issue)

This backend intentionally does **not** implement, in this change:

- Tool calls, native or recovered.
- Session/resume state (it carries no session id and sends no resume field).
- Any CLOG web-session wiring beyond the same generic backend-name dispatch
  every other backend already goes through.
- A real, credential-gated call against `api.anthropic.com`. That live proof
  is a separate opt-in follow-up (issue #70); this change proves the request
  construction, SSE parsing, and response/error normalization entirely
  offline against captured/synthetic fixtures.

## Wire contract

Captured from an authorized local proxy sitting in front of a known-good
official client turn:

- `POST https://api.anthropic.com/v1/messages`
- Headers: `Authorization: Bearer <CLAUDE_CODE_OAUTH_TOKEN>` (never logged),
  `Accept: application/json`, `Content-Type: application/json`,
  `User-Agent: claude-cli/2.1.218 (external, sdk-cli)`,
  `anthropic-version: 2023-06-01`, `x-app: cli`,
  `anthropic-beta: oauth-2025-04-20`.
- The response on success is `text/event-stream` (Server-Sent Events); on
  failure it is a JSON `{"type":"error","error":{"type":...,"message":...}}`
  envelope with a non-2xx HTTP status.

## Testing

`tests/claude-sdk-backend.lisp` proves, entirely offline:

- Backend identity: `make-claude-sdk-backend` returns a distinct
  `claude-sdk-backend`, never a `claude-backend`, with provider name
  `"claude-sdk"`.
- A missing or blank `CLAUDE_CODE_OAUTH_TOKEN` fails at completion time,
  before any transport call, with a safe, actionable message that never
  echoes a planted `ANTHROPIC_API_KEY` fixture.
- The backend source text never contains the substring `ANTHROPIC_API_KEY`.
- Header construction matches the captured contract exactly.
- Payload construction: model/messages/system/max_tokens/stream, system-turn
  extraction and exclusion from `messages`, max-tokens priority (request
  options > backend override > default), and safe degradation of non-string
  message content.
- Wire JSON encoding: snake_case fields, boolean/number encoding, and
  control-character sanitization.
- Server-Sent Events frame parsing: `event:`/`data:` fields, multi-line
  `data:` joining, comment lines, blank-line dispatch boundaries, a missing
  trailing blank line, and CRLF line endings.
- Response normalization from a captured multi-delta trace fixture
  (`tests/fixtures/claude-sdk-messages-basic.sse`): text concatenation,
  model, `stop_reason`, usage (prompt/completion/total tokens), and the
  provider message id as `provider-request-id`.
- Multiple content-block indices concatenate in ascending index order, not
  arrival order; `ping` frames and unrecognized future event types are
  ignored forward-compatibly; a stream missing `message_start` and a
  mid-stream `error` frame both fail clearly rather than silently.
- A full `complete` round trip (success and each of 401/429/529/400 provider
  errors, plus a non-JSON error body) via an injected fake transport, proving
  the OAuth token and raw response bodies never leak into a raised
  `claude-sdk-backend-error`.

`tests/backend-selection.lisp` proves `HARNESS_BACKEND=claude-sdk` (and
`CLAUDE-SDK`) selects this backend without requiring a token merely to
construct it, and that it is never mistaken for the `claude` CLI backend.
`tests/chat-cli.sh` proves `bin/chat --backend claude-sdk` (and
`CLAUDE-SDK`) is accepted without an OpenRouter key, and that `--help` and the
unknown-backend error both mention it.

All of the above run under `bin/test`'s `--no-network` Docker container, so no
test in this suite can reach a live provider even by accident. The
credential-gated live smoke against the real Anthropic API is issue #70.
