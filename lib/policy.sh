#!/usr/bin/env bash
# Drift-policy helpers. Sourced by pi/70-configure.sh. The pure helper is unit-tested in tests/policy-test.sh.

# policy_only_stale_hashes <policy-check-json>: succeed when the check failed, has findings, and every
# finding is a hash-lock mismatch (for example policy/attestation-hash-mismatch). That is the normal state
# after a config change or an OpenClaw upgrade: the accepted hashes no longer match, and the check can't go
# clean until they're cleared. Any other finding means a real policy violation, so this fails.
policy_only_stale_hashes() {
  jq -e '(.ok != true) and ([.findings[]?.checkId] as $ids
         | ($ids | length) > 0 and all($ids[]; test("hash-mismatch$")))' <<<"$1" >/dev/null 2>&1
}
