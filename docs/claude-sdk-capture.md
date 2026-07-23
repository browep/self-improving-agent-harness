# Claude SDK subscription contract capture

`bin/capture-claude-sdk-contract` is a one-off prerequisite for the direct `claude-sdk` backend. It runs a known pinned official Claude Code client through an ephemeral local mitmproxy container and writes **only** a sanitized contract manifest. It is not part of normal harness runtime or `make test`.

## Safety boundary

- Requires explicit `HARNESS_CAPTURE_CLAUDE_SDK=1` and a runtime-only `CLAUDE_CODE_OAUTH_TOKEN` from the untracked repository-root `.env`.
- The proxy CA is trusted only in a disposable client container. It never modifies the host trust store and exposes no host port.
- The addon never writes flows, HARs, PCAPs, request bodies, response bodies, prompts, response text, authorization, cookies, or token-like header values.
- Temporary files live under ignored `.capture/` and are removed in the wrapper's exit trap. The wrapper prints only the final sanitized manifest.

## Run

```sh
HARNESS_CAPTURE_CLAUDE_SDK=1 sg docker -c './bin/capture-claude-sdk-contract'
```

This executes exactly one minimal text-only official-client turn and can incur subscription usage. Save the displayed manifest only after reviewing it for protocol values and absence of sensitive data, then place it at `tests/fixtures/claude-sdk-subscription-contract.v1.json` for the direct backend's offline conformance tests.

A successful capture is observed Claude Code compatibility evidence, **not** a claim that OAuth is a documented Anthropic API-key replacement.
