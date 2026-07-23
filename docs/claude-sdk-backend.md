# Claude Agent SDK direct backend seam (issue #67)

## Scope

`claude-sdk` registers a selectable backend that is intentionally **separate**
from the CLI-spawning `claude` backend (`docs/claude-cli-backend.md`). It is a
narrow seam for a possible future *direct* Claude Agent SDK / Anthropic
transport, added ahead of that transport so selection, identity, and
credential boundaries can be proven now.

Today `claude-sdk`:

- Registers in CLI/backend selection (`--backend claude-sdk`,
  `HARNESS_BACKEND=claude-sdk`, case-insensitively), help text, and runtime
  documentation, exactly like every other backend.
- Never spawns the `claude` binary and never opens a network connection.
- Requires `CLAUDE_CODE_OAUTH_TOKEN` — the same runtime-only setup-token
  credential used by `claude` — but only at completion time, not at backend
  construction or CLI argument parsing.
- Never reads or falls back to `ANTHROPIC_API_KEY` under any circumstance.
  `src/claude-sdk-backend.lisp` never mentions that variable at all, and an
  offline test asserts that fact directly against the source text.
- Deliberately refuses to make a live call once a token is present: `complete`
  always signals `claude-sdk-backend-error` reporting that no direct transport
  is implemented yet, rather than guessing an undocumented wire protocol.

## Non-goals (this issue)

This backend intentionally does **not** implement, in this change:

- Tool calls, native or recovered.
- Streaming.
- Session/resume state (it carries no session id).
- Any CLOG web-session wiring beyond the same generic backend-name dispatch
  every other backend already goes through.
- Any Anthropic Messages HTTP client code.

## Relationship to issue #66

A real transport implementation depends on a captured, sanitized
request/response contract from a known-working official client turn (issue
#66's opt-in proxy-capture workflow). `claude-sdk` does not read, depend on, or
assume the existence of any manifest issue #66 produces; it lands independent
of and ahead of that capture, and the not-implemented error explicitly points
at issue #66 as the blocking prerequisite for a real implementation.

## Testing

`tests/claude-sdk-backend.lisp` proves, entirely offline:

- Backend identity: `make-claude-sdk-backend` returns a distinct
  `claude-sdk-backend`, never a `claude-backend`, with provider name
  `"claude-sdk"`.
- A missing or blank `CLAUDE_CODE_OAUTH_TOKEN` fails at completion time with a
  safe, actionable message that never echoes a planted `ANTHROPIC_API_KEY`
  fixture.
- A present token still fails, with a distinct not-implemented message that
  names the missing captured contract and never echoes the token fixture.
- The backend source text never contains the substring `ANTHROPIC_API_KEY`.

`tests/backend-selection.lisp` proves `HARNESS_BACKEND=claude-sdk` (and
`CLAUDE-SDK`) selects this backend without requiring a token merely to
construct it, and that it is never mistaken for the `claude` CLI backend.
`tests/chat-cli.sh` proves `bin/chat --backend claude-sdk` (and
`CLAUDE-SDK`) is accepted without an OpenRouter key, and that `--help` and the
unknown-backend error both mention it.

All of the above run under `bin/test`'s `--no-network` Docker container, so no
test in this suite can reach a live provider even by accident.
