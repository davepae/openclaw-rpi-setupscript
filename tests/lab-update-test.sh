#!/usr/bin/env bash
# Unit tests for lab/update-node.sh. A fake `openclaw` models the node (version, busy state database,
# the credential-migration message) and npm is a set of file:// fixtures. Needs bash, jq and curl only.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; repo="$here/.."
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

eng='>=24.16.0 <25 || >=26.1.0'
reg="$work/reg/openclaw"; mkdir -p "$reg"
for v in 2026.10.9 2026.11.5 2026.11.6; do printf '{"version":"%s","engines":{"node":"%s"}}\n' "$v" "$eng" > "$reg/$v"; done
printf '{"version":"2027.1.1","engines":{"node":">=26.1.0"}}\n' > "$reg/2027.1.1"      # needs a newer Node than the settings say

# mk <name> <running version> [pin in settings.env]
mk() {
  local b="$work/$1"; mkdir -p "$b"/{lab,lib,bin,config,state}
  cp "$repo/lab/update-node.sh" "$b/lab/"; cp "$repo/lib/versions.sh" "$b/lib/"
  sed -i '/^require_root$/d' "$b/lab/update-node.sh"                                   # EUID can't be faked
  printf 'LAB_USER="oclab"\nLAB_DESKTOP_NODE_NAME="lab-desktop"\nOPENCLAW_VERSION="%s"          # note\nNODE_VERSION="24.22.1"\n' "${3:-2026.11.5}" > "$b/config/settings.env"
  # a minimal stand-in for lib/common.sh: logging, confirm, and as_user that runs the node commands against the fake
  cat > "$b/lib/common.sh" <<EOF
set -Eeuo pipefail
BUNDLE_DIR="$b"
source "\$BUNDLE_DIR/config/settings.env"
log() { echo "==> \$*"; }; ok() { echo " ok \$*"; }; warn() { echo " !! \$*" >&2; }; die() { echo "ERR \$*" >&2; exit 1; }
confirm() { local a; read -r -p "\$1 [y/N] " a; [[ "\$a" =~ ^[Yy]$ ]]; }
as_user() { shift
  case "\$*" in
    "curl -fsSL"*) [[ -n "\${INSTALL_WRONG:-}" ]] && v="2026.0.0" || v="\$(sed -E "s/.*--version '([^']*)'.*/\\1/" <<<"\$*")"
                   echo "\$v" > "$b/state/version"; echo "installed \$v" >> "$b/state/log" ;;
    docker*) [[ -n "\${HAS_DESKTOP:-}" ]] && echo lab-desktop || true ;;
    *) PATH="$b/bin:\$PATH" bash -c "\$*" ;;
  esac; }
EOF
  echo "$2" > "$b/state/version"; echo 0 > "$b/state/busy"; : > "$b/state/log"
  cat > "$b/bin/openclaw" <<EOF
#!/bin/sh
s="$b/state"
case "\$1 \$2" in
  "--version "*) echo "OpenClaw \$(cat \$s/version) (abc1234)" ;;
  "node stop"|"node start") echo "\$1 \$2" >> \$s/log ;;
  "doctor --fix") echo doctor >> \$s/log; rm -f \$s/needs_doctor ;;
  "approvals get")
     n=\$(cat \$s/busy)
     if [ "\$n" -gt 0 ]; then echo \$((n-1)) > \$s/busy; echo "Cannot admit exec.approvals.get: state database is busy"; exit 1; fi
     if [ -f \$s/needs_doctor ]; then echo "Client credential migration is incomplete or stale; run openclaw doctor --fix"; exit 1; fi
     printf '| Defaults | security=allowlist, ask=on-miss |\n| Allowlist       | 6 |\n' ;;
esac
EOF
  chmod +x "$b/bin/openclaw"
  printf '#!/bin/sh\nexit 0\n' > "$b/bin/sleep"; chmod +x "$b/bin/sleep"      # polls run instantly
}
# run <name> [args]   (stdin from $ANSWER, default n)
run() { local n="$1"; shift
  PATH="$work/$n/bin:$PATH" OC_REGISTRY="file://$reg" OC_WAIT_STEP=5 OC_WAIT_MAX=15 \
    bash "$work/$n/lab/update-node.sh" "$@" <<<"${ANSWER:-n}" >"$work/$n/out" 2>&1; }
out()  { cat "$work/$1/out"; }
pin()  { sed -n -E 's/^OPENCLAW_VERSION="([^"]*)".*/\1/p' "$work/$1/config/settings.env"; }
ver()  { cat "$work/$1/state/version"; }
slog() { tr '\n' ' ' < "$work/$1/state/log"; }

# 1. --to: updates, verifies, and only then writes the pin (keeping the trailing comment)
mk a 2026.10.9 2026.10.9; run a --to 2026.11.6; rc=$?
[[ $rc == 0 ]] && ok || bad "--to: exit $rc: $(out a | tail -4)"
[[ "$(ver a)" == 2026.11.6 && "$(pin a)" == 2026.11.6 ]] && ok || bad "--to: version $(ver a), pin $(pin a)"
grep -q '# note' "$work/a/config/settings.env" && ok || bad "--to: lost the trailing comment"
[[ "$(slog a)" == "node stop installed 2026.11.6 node start " ]] && ok || bad "--to: unexpected step order: $(slog a)"
out a | grep -q "sudo pi/80-nodes.sh status" && ok || bad "--to: next steps missing"

# 2. no argument: updates to the pin already in settings.env and leaves the file alone
mk b 2026.10.9 2026.11.6; run b; rc=$?
[[ $rc == 0 && "$(ver b)" == 2026.11.6 && "$(pin b)" == 2026.11.6 ]] && ok || bad "no arg: rc $rc, version $(ver b), pin $(pin b)"

# 3. already on the target: no reinstall, but --to still syncs a stale pin (the case that prompted this script)
mk c 2026.11.6 2026.10.9; run c --to 2026.11.6; rc=$?
[[ $rc == 0 && "$(pin c)" == 2026.11.6 && -z "$(slog c)" ]] && ok || bad "already current: rc $rc, pin $(pin c), steps '$(slog c)'"
out c | grep -q "already runs" && ok || bad "already current: expected the 'already runs' line"

# 4. the state database is busy for a few polls, then answers
mk d 2026.10.9; echo 2 > "$work/d/state/busy"; run d --to 2026.11.6; rc=$?
[[ $rc == 0 && "$(pin d)" == 2026.11.6 ]] && ok || bad "busy then ok: rc $rc, pin $(pin d)"

# 5. migration message: asks, runs doctor --fix between a stop and a start, then succeeds
mk e 2026.10.9; touch "$work/e/state/needs_doctor"; ANSWER=y run e --to 2026.11.6; rc=$?
[[ $rc == 0 && "$(pin e)" == 2026.11.6 ]] && ok || bad "migration, yes: rc $rc, pin $(pin e): $(out e | tail -4)"
[[ "$(slog e)" == *"node stop doctor node start"* ]] && ok || bad "migration, yes: doctor should run with the node stopped: $(slog e)"

# 6. migration message and you say no: stops, pin untouched
mk f 2026.10.9 2026.10.9; touch "$work/f/state/needs_doctor"; ANSWER=n run f --to 2026.11.6; rc=$?
[[ $rc != 0 && "$(pin f)" == 2026.10.9 ]] && ok || bad "migration, no: rc $rc, pin $(pin f)"
[[ "$(slog f)" != *doctor* ]] && ok || bad "migration, no: doctor must not run"

# 7. never settles: fails, pin untouched
mk g 2026.10.9 2026.10.9; echo 999 > "$work/g/state/busy"; run g --to 2026.11.6; rc=$?
[[ $rc != 0 && "$(pin g)" == 2026.10.9 ]] && out g | grep -q "didn't settle" && ok || bad "never settles: rc $rc, pin $(pin g)"

# 8. the install lands on the wrong version: fails, pin untouched
mk h 2026.10.9 2026.10.9; INSTALL_WRONG=1 run h --to 2026.11.6; rc=$?
[[ $rc != 0 && "$(pin h)" == 2026.10.9 ]] && out h | grep -q "pin was NOT changed" && ok || bad "wrong version after install: rc $rc, pin $(pin h)"

# 9. engines range not satisfied: refuses before touching anything
mk i 2026.10.9 2026.10.9; run i --to 2027.1.1; rc=$?
[[ $rc != 0 && -z "$(slog i)" && "$(ver i)" == 2026.10.9 && "$(pin i)" == 2026.10.9 ]] && out i | grep -q "does not satisfy" && ok || bad "engines: rc $rc, steps '$(slog i)'"

# 10. unknown version, bad argument
mk j 2026.10.9; run j --to 2026.99.9; rc=$?
[[ $rc != 0 && -z "$(slog j)" ]] && out j | grep -q "npm has no OpenClaw" && ok || bad "unknown version: rc $rc"
mk k 2026.10.9; run k --bogus; rc=$?
[[ $rc != 0 ]] && out k | grep -q usage && ok || bad "bad argument: rc $rc"

# 11. the desktop container is flagged for a rebuild
mk l 2026.10.9; HAS_DESKTOP=1 run l --to 2026.11.6
out l | grep -q "desktop node container exists" && ok || bad "desktop container hint missing"

printf '%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
