#!/usr/bin/env sh
# Test-only runner: execute the Docker-resident chat script directly in the test container.
set -eu
exec sbcl --noinform --load scripts/chat.lisp
