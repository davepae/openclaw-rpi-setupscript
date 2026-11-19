#!/usr/bin/env bash
# Unit tests for lib/policy.sh. Runs anywhere with bash and jq; touches no OpenClaw install.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/policy.sh
source "$here/../lib/policy.sh"
pass=0; fail=0
yes() { if policy_only_stale_hashes "$2"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $1 (expected yes)"; fi; }
no()  { if policy_only_stale_hashes "$2"; then fail=$((fail + 1)); echo "FAIL $1 (expected no)"; else pass=$((pass + 1)); fi; }

yes "attestation mismatch only"  '{"ok":false,"findings":[{"checkId":"policy/attestation-hash-mismatch"}]}'
yes "both hash mismatches"       '{"ok":false,"findings":[{"checkId":"policy/attestation-hash-mismatch"},{"checkId":"policy/policy-hash-mismatch"}]}'
no  "mismatch plus a real finding" '{"ok":false,"findings":[{"checkId":"policy/attestation-hash-mismatch"},{"checkId":"policy/channel-denied"}]}'
no  "real finding only"          '{"ok":false,"findings":[{"checkId":"policy/channel-denied"}]}'
no  "clean check"                '{"ok":true,"findings":[]}'
no  "failed with no findings"    '{"ok":false,"findings":[]}'
no  "not json"                   'not json'
no  "empty"                      ''
printf '%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
