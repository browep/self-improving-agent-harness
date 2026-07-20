FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install --no-install-recommends --yes \
       sbcl python3 git ca-certificates gh nodejs npm curl \
       cl-drakma cl-yason cl-alexandria cl-trivial-gray-streams \
    && rm -rf /var/lib/apt/lists/*

# Route GitHub SSH remotes over HTTPS and use gh as the git credential helper,
# so a GITHUB_TOKEN in the runtime env is sufficient for git push/pull (no SSH key).
# No secret is baked into the image; the token is read from the env at runtime.
RUN git config --system url."https://github.com/".insteadOf "git@github.com:" \
    && git config --system url."https://github.com/".pushInsteadOf "git@github.com:" \
    && git config --system credential."https://github.com".helper '!/usr/bin/gh auth git-credential' \
    && git config --system credential."https://gist.github.com".helper '!/usr/bin/gh auth git-credential'

# Install a pinned official Codex CLI (issue #18). The @openai/codex npm
# package ships a platform binary and a `codex` executable (bin/codex.js).
# Pinned for reproducibility; bump deliberately. NO credentials are baked in --
# ChatGPT/Codex OAuth is completed by a human at runtime and owned by Codex.
#
# The harness talks to `codex app-server` over stdio JSON-RPC. Verified against
# this pinned CLI (0.144.6): `codex app-server` exists and the protocol method
# surface used by the adapter matches `codex app-server generate-json-schema`.
# The launch argv is runtime-overridable via *codex-app-server-command*.
# STILL UNPROVEN here: an actual subscription-billed live turn, which requires a
# human ChatGPT login at runtime and is exercised by bin/verify-codex-chatgpt-auth.
ARG CODEX_CLI_VERSION=0.144.6
RUN npm install --global --no-fund --no-audit "@openai/codex@${CODEX_CLI_VERSION}" \
    && codex --version \
    && npm cache clean --force

WORKDIR /workspace

# Source is mounted read-only at runtime; compiled FASLs live in this named-volume path.
ENV XDG_CACHE_HOME=/cache

ENTRYPOINT ["sbcl"]
CMD ["--noinform"]
