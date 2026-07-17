#!/usr/bin/env sh
# Shared isolated Git fixture for deterministic chat-supervisor tests.
# The supervisor must receive a clean primary only to create an owned worktree;
# reports and its ownership ledger live in sibling directories outside it.

supervisor_fixture_create() {
  supervisor_fixture_repo_root=$1
  SUPERVISOR_FIXTURE_TMP=$(mktemp -d)
  SUPERVISOR_FIXTURE_PRIMARY="$SUPERVISOR_FIXTURE_TMP/primary"
  SUPERVISOR_FIXTURE_PARENT="$SUPERVISOR_FIXTURE_TMP/owned"
  SUPERVISOR_FIXTURE_REPORTS="$SUPERVISOR_FIXTURE_TMP/reports"

  mkdir -p "$SUPERVISOR_FIXTURE_PRIMARY" "$SUPERVISOR_FIXTURE_PARENT" "$SUPERVISOR_FIXTURE_REPORTS"
  # bin/chat loads the ASDF system and runtime sources below. Keep this fixture
  # deliberately small, clean, and independent from the caller's checkout.
  cp -R "$supervisor_fixture_repo_root/bin" "$supervisor_fixture_repo_root/scripts" \
    "$supervisor_fixture_repo_root/src" "$SUPERVISOR_FIXTURE_PRIMARY/"
  cp "$supervisor_fixture_repo_root/self-improving-agent-harness.asd" "$SUPERVISOR_FIXTURE_PRIMARY/"
  git -C "$SUPERVISOR_FIXTURE_PRIMARY" init -q
  git -C "$SUPERVISOR_FIXTURE_PRIMARY" config user.email test@example.invalid
  git -C "$SUPERVISOR_FIXTURE_PRIMARY" config user.name test
  git -C "$SUPERVISOR_FIXTURE_PRIMARY" add bin scripts src self-improving-agent-harness.asd
  git -C "$SUPERVISOR_FIXTURE_PRIMARY" commit -qm fixture
  SUPERVISOR_FIXTURE_PRIMARY_COMMIT=$(git -C "$SUPERVISOR_FIXTURE_PRIMARY" rev-parse HEAD)
  export SUPERVISOR_FIXTURE_TMP SUPERVISOR_FIXTURE_PRIMARY SUPERVISOR_FIXTURE_PARENT \
    SUPERVISOR_FIXTURE_REPORTS SUPERVISOR_FIXTURE_PRIMARY_COMMIT
}

supervisor_fixture_cleanup() {
  rm -rf "${SUPERVISOR_FIXTURE_TMP:-}"
}
