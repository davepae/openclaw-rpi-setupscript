#!/usr/bin/env bash
# Unit tests for lib/versions.sh and pi/bump-version.sh. The script runs against file:// fixtures, so
# there is no network, no root and no OpenClaw install. Needs bash, curl, jq and diff.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/versions.sh
source "$here/../lib/versions.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
eq()  { [[ "$2" == "$3" ]] && ok || bad "$1: got '$2', want '$3'"; }

# ---- ver_extract
eq "extract plain"       "$(ver_extract 'OpenClaw 2026.11.5 (e13cf15) — banner')" "2026.11.5"
eq "extract prerelease"  "$(ver_extract 'v 2026.11.10-beta.1 x')"                 "2026.11.10-beta.1"
eq "extract none"        "$(ver_extract 'no version here')"                       ""
eq "extract ignores hash" "$(ver_extract '(e13cf15)')"                            ""

# ---- ver_cmp
eq "older"               "$(ver_cmp 2026.11.5 2026.11.6)"           "-1"
eq "equal"               "$(ver_cmp 2026.11.5 2026.11.5)"           "0"
eq "newer"               "$(ver_cmp 2026.11.6 2026.11.5)"           "1"
eq "numeric not text"    "$(ver_cmp 2026.11.10 2026.11.9)"          "1"
eq "month rolls"         "$(ver_cmp 2026.12.1 2026.11.30)"          "1"
eq "release > prerelease" "$(ver_cmp 2026.11.10 2026.11.10-beta.1)" "1"
eq "prerelease < release" "$(ver_cmp 2026.11.10-beta.1 2026.11.10)" "-1"
eq "beta.2 > beta.1"     "$(ver_cmp 2026.11.10-beta.2 2026.11.10-beta.1)" "1"
eq "beta of next > prior release" "$(ver_cmp 2026.11.10-beta.1 2026.11.6)" "1"
eq "missing part is 0"   "$(ver_cmp 25 25.0.0)"                     "0"

# ---- semver_satisfies (the real engines range of 2026.11.5 and 2026.11.6)
eng='>=24.16.0 <25 || >=26.1.0'
sat() { semver_satisfies "$2" "$3"; local rc=$?; [[ "$rc" == "$4" ]] && ok || bad "$1: $2 vs '$3' returned $rc, want $4"; }
sat "24.22.1 in range"     24.22.1 "$eng" 0
sat "24.16.0 lower bound"  24.16.0 "$eng" 0
sat "24.15.9 too old"      24.15.9 "$eng" 1
sat "25.0.0 in the gap"    25.0.0  "$eng" 1
sat "25.9.9 in the gap"    25.9.9  "$eng" 1
sat "26.0.9 below second"  26.0.9  "$eng" 1
sat "26.1.0 second group"  26.1.0  "$eng" 0
sat "27.0.0 second group"  27.0.0  "$eng" 0
sat "single clause ok"     22.1.0  ">=22" 0
sat "caret not evaluated"  24.22.1 "^24.16.0" 2
sat "tilde not evaluated"  24.22.1 "~24.16.0" 2
sat "x-range not evaluated" 24.22.1 "24.x" 2
sat "partial = not evaluated" 25.1.0 "=25" 2
sat "empty range"          24.22.1 "" 2
sat "empty version"        ""      "$eng" 2

# ---- settings_value
printf 'OPENCLAW_VERSION="2026.11.5"          # npm version\nNODE_VERSION="24.22.1"  # x\nOTHER=""\n' > "$work/s.env"
eq "settings value quoted"  "$(settings_value "$work/s.env" OPENCLAW_VERSION)" "2026.11.5"
eq "settings value node"    "$(settings_value "$work/s.env" NODE_VERSION)"     "24.22.1"
eq "settings value empty"   "$(settings_value "$work/s.env" OTHER)"            ""
eq "settings value missing" "$(settings_value "$work/s.env" NOPE)"             ""

# ---- node_versions_tsv
# 1. the real `nodes list --json` entry from the Pi on 2026-11-19 (fields trimmed to the ones used)
real='{"pending":[],"paired":[{"nodeId":"628f57c7","displayName":"lab-exec","connected":true,"platform":"linux","version":"2026.11.5","coreVersion":null,"uiVersion":null}]}'
eq "node: real lab-exec output falls back to version" "$(node_versions_tsv "$real")" $'lab-exec\t2026.11.5'
eq "node: coreVersion wins when present" \
  "$(node_versions_tsv '{"paired":[{"displayName":"a","connected":true,"platform":"linux","version":"1.0.0","coreVersion":"2026.11.6"}]}')" $'a\t2026.11.6'
eq "node: disconnected node skipped" \
  "$(node_versions_tsv '{"paired":[{"displayName":"a","connected":false,"platform":"linux","version":"2026.10.8"}]}')" ""
eq "node: phone's version is a UI version, not core" \
  "$(node_versions_tsv '{"paired":[{"displayName":"phone","connected":true,"platform":"ios","version":"3.4.1"}]}')" $'phone\t'
eq "node: name falls back to nodeId" \
  "$(node_versions_tsv '{"paired":[{"nodeId":"abc","connected":true,"platform":"Linux","version":"2026.11.5"}]}')" $'abc\t2026.11.5'
eq "node: two nodes" \
  "$(node_versions_tsv '{"paired":[{"displayName":"a","connected":true,"platform":"linux","version":"2026.11.5"},{"displayName":"b","connected":true,"platform":"darwin","coreVersion":"2026.10.9"}]}' | tr '\n' ';')" $'a\t2026.11.5;b\t2026.10.9;'
eq "node: no paired list"  "$(node_versions_tsv '{"pending":[]}')" ""
eq "node: not json"        "$(node_versions_tsv 'not json')" ""
eq "node: empty"           "$(node_versions_tsv '')" ""

# ---- pi/bump-version.sh against fixtures
reg="$work/reg/openclaw"; raw="$work/raw"; mkdir -p "$reg"
doc() { printf '{"name":"openclaw","version":"%s","engines":{"node":"%s"}}\n' "$1" "$2" > "$reg/$3"; }
df()  { mkdir -p "$raw/v$1/scripts/docker/sandbox"; printf '%s\n' "$2" > "$raw/v$1/scripts/docker/sandbox/Dockerfile.common"; }
doc 2026.11.5  "$eng" 2026.11.5
doc 2026.11.6  "$eng" 2026.11.6; cp "$reg/2026.11.6" "$reg/latest"
doc 2026.11.7  "$eng" 2026.11.7
doc 2026.12.1  ">=26.1.0" 2026.12.1       # needs a newer Node than the settings below
doc 2026.12.2  "^24.16.0" 2026.12.2       # range the script cannot evaluate
doc 2026.11.4  "$eng" 2026.11.4
df 2026.11.5 $'FROM base\nRUN a'
df 2026.11.6 $'FROM base\nRUN a'
df 2026.11.7 $'FROM base\nRUN a\nRUN new-step'
df 2026.12.1 $'FROM base\nRUN a'
mk() { printf 'X="1"\nOPENCLAW_VERSION="2026.11.5"          # note\nNODE_VERSION="24.22.1"\nY="2"\n' > "$work/settings.env"; }
bump() { OC_REGISTRY="file://$reg" OC_RAW="file://$raw" bash "$here/../pi/bump-version.sh" --file "$work/settings.env" "$@" 2>&1; }

mk; out="$(bump)"; rc=$?
[[ $rc == 0 ]] && ok || bad "report: exit $rc"
[[ "$out" == *"target (latest)"*"2026.11.6"* ]] && ok || bad "report: wrong target"
[[ "$out" == *"unchanged"* ]] && ok || bad "report: Dockerfile.common should be unchanged 11.5 -> 11.6"
[[ "$out" == *"Report only"* ]] && ok || bad "report: should say report only"
[[ "$(settings_value "$work/settings.env" OPENCLAW_VERSION)" == 2026.11.5 ]] && ok || bad "report: file changed without --apply"

mk; out="$(bump --to 2026.11.7)"
[[ "$out" == *"1 changed line"* && "$out" == *"+RUN new-step"* ]] && ok || bad "diff: expected 1 changed line with the new step"

mk; out="$(bump --apply)"; rc=$?
[[ $rc == 0 ]] && ok || bad "apply: exit $rc"
eq "apply writes the pin" "$(settings_value "$work/settings.env" OPENCLAW_VERSION)" "2026.11.6"
eq "apply leaves other lines alone" "$(grep -v '^OPENCLAW_VERSION' "$work/settings.env" | tr '\n' ' ')" 'X="1" NODE_VERSION="24.22.1" Y="2" '
[[ "$(grep '^OPENCLAW_VERSION' "$work/settings.env")" == *"# note"* ]] && ok || bad "apply: lost the trailing comment"
[[ "$out" == *"install-pi.sh --from 50"* ]] && ok || bad "apply: next steps missing"

mk; out="$(bump --apply)"; out2="$(bump --apply)"; rc=$?
[[ $rc == 0 && "$out2" == *"already matches"* ]] && ok || bad "second apply should say the pin already matches (rc $rc)"

mk; out="$(bump --apply --to 2026.12.1)"; rc=$?
[[ $rc != 0 && "$out" == *"does NOT satisfy"* ]] && ok || bad "node too old: should refuse (rc $rc)"
eq "node too old leaves the file alone" "$(settings_value "$work/settings.env" OPENCLAW_VERSION)" "2026.11.5"

mk; out="$(bump --apply --force --to 2026.12.1)"; rc=$?
[[ $rc == 0 ]] && eq "force overrides the node warning" "$(settings_value "$work/settings.env" OPENCLAW_VERSION)" "2026.12.1" || bad "force: exit $rc"

mk; out="$(bump --apply --to 2026.12.2)"; rc=$?
[[ $rc == 0 && "$out" == *"could not evaluate"* ]] && ok || bad "unevaluable range: should warn and still apply (rc $rc)"

mk; out="$(bump --apply --to 2026.11.4)"; rc=$?
[[ $rc != 0 && "$out" == *"OLDER than the pin"* ]] && ok || bad "downgrade: should refuse (rc $rc)"
eq "downgrade leaves the file alone" "$(settings_value "$work/settings.env" OPENCLAW_VERSION)" "2026.11.5"

mk; out="$(bump --to 2026.99.9)"; rc=$?
[[ $rc != 0 && "$out" == *"no OpenClaw"* ]] && ok || bad "unknown version: should fail (rc $rc)"

mk; out="$(bump --to 2026.11.4 2>&1)"
[[ "$out" == *"could not fetch Dockerfile.common"* ]] && ok || bad "missing tag: should warn about the Dockerfile and carry on"

mk; printf 'NODE_VERSION="24.22.1"\n' > "$work/settings.env"; out="$(bump)"; rc=$?
[[ $rc != 0 && "$out" == *"OPENCLAW_VERSION not found"* ]] && ok || bad "no pin in file: should fail (rc $rc)"

printf '%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
