FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install --no-install-recommends --yes \
       sbcl python3 git ca-certificates gh nodejs npm curl \
       cl-drakma cl-yason cl-alexandria cl-trivial-gray-streams cl-quicklisp \
    && rm -rf /var/lib/apt/lists/*

# CLOG's current dependency graph requires newer libraries than Debian Bookworm
# packages provide.  Keep the Quicklisp world isolated so ASDF cannot combine
# those versions with Debian's older source registry at runtime.
RUN CL_SOURCE_REGISTRY='(:source-registry :ignore-inherited-configuration)' \
      sbcl --non-interactive \
        --load /usr/share/common-lisp/source/quicklisp/quicklisp.lisp \
        --eval '(quicklisp-quickstart:install :path "/opt/quicklisp")' \
        --eval '(ql:quickload (list :clog :drakma :yason))'
ENV CL_SOURCE_REGISTRY='(:source-registry :ignore-inherited-configuration)'
RUN printf '%s\n' '(load "/opt/quicklisp/setup.lisp")' > /root/.sbclrc

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

# Headless Chromium (Playwright) for driving the CLOG web UI from inside the
# container (e.g. browser-driven smoke tests / screenshots). Only the
# chromium-headless-shell is installed (--only-shell): the harness launches
# headless only, so the full ~379M chromium bundle is unnecessary.
#
# Version is pinned to match package.json's "playwright" dependency
# (^1.61.1 -> 1.61.1); the browser build number is derived from that version
# (chromium-1228). Bump both together deliberately.
#
# Browsers are installed under /opt/ms-playwright (set via PLAYWRIGHT_BROWSERS_PATH
# below) rather than the XDG default /cache, because bin/container mounts the
# self-improving-agent-harness-cache named volume at /cache at runtime and would
# shadow anything baked there. --with-deps installs the OS shared libraries
# (libnss3, libatk, libcairo, libgbm, ...) in the same apt pass.
ARG PLAYWRIGHT_VERSION=1.61.1
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright
RUN npx --yes playwright@${PLAYWRIGHT_VERSION} install --with-deps --only-shell chromium \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

# Source is mounted read-only at runtime; compiled FASLs live in this named-volume path.
ENV XDG_CACHE_HOME=/cache

ENTRYPOINT ["sbcl"]
CMD ["--noinform"]
