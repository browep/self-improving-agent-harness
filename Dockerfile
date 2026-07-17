FROM debian:bookworm-slim

RUN apt-get update \
    && apt-get install --no-install-recommends --yes \
       sbcl python3 git ca-certificates \
       cl-drakma cl-yason cl-alexandria cl-trivial-gray-streams \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace

# Source is mounted read-only at runtime; compiled FASLs live in this named-volume path.
ENV XDG_CACHE_HOME=/cache

ENTRYPOINT ["sbcl"]
CMD ["--noinform"]
