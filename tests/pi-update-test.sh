#!/usr/bin/env bash
# Unit tests for pi/update.sh. The phase scripts (50, 60, 70, 99) are stubs that log what ran and in what
# order; a fake `openclaw` models the version and the plugin dry run; npm and Dockerfile.common are file://
# fixtures. Needs bash, jq and curl only; no root and no network.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; repo="$here/.."
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

eng='>=24.16.0 <25 || >=26.1.0'
reg="$work/reg/openclaw"; mkdir -p "$reg"
for v in 2026.11.5 2026.11.6 2026.11.7; do printf '{"version":"%s","engines":{"node":"%s"}}\n' "$v" "$eng" > "$reg/$v"; done
printf '{"version":"2027.1.1","engines":{"node":">=26.1.0"}}\n' > "$reg/2027.1.1"
raw="$work/raw"
df() { mkdir -p "$raw/v$1/scripts/docker/sandbox"; printf '%s\n' "$2" > "$raw/v$1/scripts/docker/sandbox/Dockerfile.common"; }
df 2026.11.5 "FROM base"; df 2026.11.6 "FROM base"; df 2026.11.7 "FROM base2"      # 11.5 -> 11.6 unchanged, 11.6 -> 11.7 changed

# mk <name> <running version> [pin in settings.env]
mk() {
  local b="$work/$1"; mkdir -p "$b"/{pi,lib,bin,config,state}
  cp "$repo/pi/update.sh" "$b/pi/"; cp "$repo/lib/versions.sh" "$b/lib/"
  sed -i '/^require_root$/d' "$b/pi/update.sh"                                        # EUID can't be faked
  printf 'OC_USER="openclaw_user"\nOPENCLAW_VERSION="%s"          # note\nNODE_VERSION="24.22.1"\n' "${3:-$2}" > "$b/config/settings.env"
  cat > "$b/lib/common.sh" <<EOF
set -Eeuo pipefail
BUNDLE_DIR="$b"
source "\$BUNDLE_DIR/config/settings.env"
log() { echo "==> \$*"; }; ok() { echo " ok \$*"; }; warn() { echo " !! \$*" >&2; }; die() { echo "ERR \$*" >&2; exit 1; }
confirm() { local a; read -r -p "\$1 [y/N] " a; [[ "\$a" =~ ^[Yy]\$ ]]; }
as_user() { shift
  case "\$*" in
    "systemctl --user stop openclaw-gateway.service")  echo "gateway stop"  >> "$b/state/log" ;;
    "systemctl --user start openclaw-gateway.service") echo "gateway start" >> "$b/state/log"; [[ -z "\${GW_START_FAILS:-}" ]] || return 1 ;;
    *) PATH="$b/bin:\$PATH" bash -c "\$*" ;;
  esac; }
EOF
  echo "$2" > "$b/state/version"; : > "$b/state/log"
  cat > "$b/bin/openclaw" <<EOF
#!/bin/sh
s="$b/state"
case "\$1 \$2 \$3" in
  "--version  ") echo "OpenClaw \$(cat \$s/version) (abc1234)" ;;
  "plugins update --all") [ -f \$s/lag ] && cat \$s/lag; echo "searxng is up to date (2026.11.5)." ;;
  "plugins update "*) echo "plugin \$3" >> \$s/log; [ -f \$s/plugin_fail ] && exit 1; exit 0 ;;
esac
EOF
  printf '#!/bin/sh\nexit 0\n' > "$b/bin/sleep"
  # phase stubs
  cat > "$b/pi/50-openclaw.sh" <<EOF
#!/bin/bash
read -r ans; echo "50 (answer=\$ans)" >> "$b/state/log"
[ -n "\${FAIL50:-}" ] && exit 1
source "$b/config/settings.env"
if [ -n "\${INSTALL_WRONG:-}" ]; then echo 2026.0.0 > "$b/state/version"; else echo "\$OPENCLAW_VERSION" > "$b/state/version"; fi
EOF
  printf '#!/bin/bash\necho "60 $*" >> "%s/state/log"\n[ -n "${FAIL60:-}" ] && exit 1\nexit 0\n' "$b" > "$b/pi/60-images.sh"
  printf '#!/bin/bash\necho "70" >> "%s/state/log"\n[ -n "${FAIL70:-}" ] && exit 1\nexit 0\n' "$b" > "$b/pi/70-configure.sh"
  printf '#!/bin/bash\necho "99" >> "%s/state/log"\necho "==> Automated: 37 passed, 0 failed"\nexit ${VERIFY_RC:-0}\n' "$b" > "$b/pi/99-verify.sh"
  chmod +x "$b/bin/"* "$b/pi/"*.sh
}
# run <name> [args]   (stdin from $ANSWER, default n)
run() { local n="$1"; shift
  PATH="$work/$n/bin:$PATH" OC_REGISTRY="file://$reg" OC_RAW="file://$raw" \
    bash "$work/$n/pi/update.sh" "$@" <<<"${ANSWER:-n}" >"$work/$n/out" 2>&1; }
out()  { cat "$work/$1/out"; }
pin()  { sed -n -E 's/^OPENCLAW_VERSION="([^"]*)".*/\1/p' "$work/$1/config/settings.env"; }
ver()  { cat "$work/$1/state/version"; }
slog() { tr '\n' '|' < "$work/$1/state/log"; }

# 1. --to with unchanged Dockerfile.common (11.5 -> 11.6): 50, 70, 99 in order; no image rebuild, no plugin stop
mk a 2026.11.5; run a --to 2026.11.6 --yes; rc=$?
[[ $rc == 0 ]] && ok || bad "--to: exit $rc: $(out a | tail -5)"
[[ "$(ver a)" == 2026.11.6 && "$(pin a)" == 2026.11.6 ]] && ok || bad "--to: version $(ver a), pin $(pin a)"
[[ "$(slog a)" == "50 (answer=n)|70|99|" ]] && ok || bad "--to: unexpected steps: $(slog a)"
grep -q '# note' "$work/a/config/settings.env" && ok || bad "--to: lost the trailing comment"
out a | grep -q "sudo lab/update-node.sh --to 2026.11.6" && ok || bad "--to: lab next step missing"
out a | grep -q "37 passed" && ok || bad "--to: verify summary missing"

# 2. Dockerfile.common changed (11.6 -> 11.7): images rebuilt between the install and 70
mk b 2026.11.6; run b --to 2026.11.7 --yes
[[ "$(slog b)" == "50 (answer=n)|60 --rebuild|70|99|" ]] && ok || bad "images changed: unexpected steps: $(slog b)"

# 3. no argument: upgrades to the pin already in settings.env
mk c 2026.11.5 2026.11.6; run c --yes; rc=$?
[[ $rc == 0 && "$(ver c)" == 2026.11.6 && "$(pin c)" == 2026.11.6 ]] && ok || bad "no arg: rc $rc, version $(ver c), pin $(pin c)"

# 4. already current: nothing runs, a stale pin is synced
mk d 2026.11.6 2026.11.5; run d --to 2026.11.6 --yes; rc=$?
[[ $rc == 0 && -z "$(slog d)" && "$(pin d)" == 2026.11.6 ]] && ok || bad "already current: rc $rc, steps '$(slog d)', pin $(pin d)"

# 5. a lagging plugin: Gateway stopped, plugin updated, Gateway started, all before 70
mk e 2026.11.5; echo "Would update firecrawl: 2026.11.5 -> 2026.11.6." > "$work/e/state/lag"; run e --to 2026.11.6 --yes; rc=$?
[[ $rc == 0 && "$(slog e)" == "50 (answer=n)|gateway stop|plugin firecrawl|gateway start|70|99|" ]] && ok || bad "plugin lag: rc $rc, steps: $(slog e)"

# 6. the plugin update fails: the Gateway is still started, the run continues and ends non-zero
mk f 2026.11.5; echo "Would update firecrawl: 2026.11.5 -> 2026.11.6." > "$work/f/state/lag"; touch "$work/f/state/plugin_fail"
run f --to 2026.11.6 --yes; rc=$?
[[ $rc != 0 && "$(slog f)" == *"gateway start|70|99|"* ]] && ok || bad "plugin failure: rc $rc, steps: $(slog f)"
out f | grep -q "plugin firecrawl not updated" && ok || bad "plugin failure: problem not reported"

# 7. phase 50 fails: pin put back, nothing after it runs
mk g 2026.11.5; FAIL50=1 run g --to 2026.11.6 --yes; rc=$?
[[ $rc != 0 && "$(pin g)" == 2026.11.5 && "$(slog g)" == "50 (answer=n)|" ]] && ok || bad "50 fails: rc $rc, pin $(pin g), steps: $(slog g)"

# 8. the install lands on the wrong version: pin put back, no 70
mk h 2026.11.5; INSTALL_WRONG=1 run h --to 2026.11.6 --yes; rc=$?
[[ $rc != 0 && "$(pin h)" == 2026.11.5 && "$(slog h)" == "50 (answer=n)|" ]] && ok || bad "wrong version: rc $rc, pin $(pin h), steps: $(slog h)"

# 9. engines range not satisfied: refuses before touching anything
mk i 2026.11.5; run i --to 2027.1.1 --yes; rc=$?
[[ $rc != 0 && -z "$(slog i)" && "$(pin i)" == 2026.11.5 ]] && out i | grep -q "does not satisfy" && ok || bad "engines: rc $rc, steps '$(slog i)'"

# 10. unknown version, bad argument
mk j 2026.11.5; run j --to 2026.99.9 --yes; rc=$?
[[ $rc != 0 && -z "$(slog j)" ]] && out j | grep -q "npm has no OpenClaw" && ok || bad "unknown version: rc $rc"
mk k 2026.11.5; run k --bogus; rc=$?
[[ $rc != 0 ]] && out k | grep -q usage && ok || bad "bad argument: rc $rc"

# 11. declining the confirmation changes nothing; accepting it proceeds
mk l 2026.11.5; ANSWER=n run l --to 2026.11.6; rc=$?
[[ $rc != 0 && -z "$(slog l)" && "$(pin l)" == 2026.11.5 ]] && ok || bad "declined: rc $rc, steps '$(slog l)', pin $(pin l)"
mk m 2026.11.5; ANSWER=y run m --to 2026.11.6; rc=$?
[[ $rc == 0 && "$(ver m)" == 2026.11.6 ]] && ok || bad "accepted: rc $rc, version $(ver m)"

# 12. 70 or 99 failing is reported and ends non-zero, and the pin stays at the new version
mk n 2026.11.5; FAIL70=1 run n --to 2026.11.6 --yes; rc=$?
[[ $rc != 0 && "$(pin n)" == 2026.11.6 && "$(slog n)" == "50 (answer=n)|70|99|" ]] && out n | grep -q "70-configure failed" && ok || bad "70 fails: rc $rc, steps: $(slog n)"
mk o 2026.11.5; VERIFY_RC=1 run o --to 2026.11.6 --yes; rc=$?
[[ $rc != 0 ]] && out o | grep -q "99-verify reported failures" && ok || bad "99 fails: rc $rc"

# 13. the image rebuild fails: reported, the run still re-locks the policy
mk p 2026.11.6; FAIL60=1 run p --to 2026.11.7 --yes; rc=$?
[[ $rc != 0 && "$(slog p)" == "50 (answer=n)|60 --rebuild|70|99|" ]] && ok || bad "60 fails: rc $rc, steps: $(slog p)"

# 14. the Gateway can't be started after the plugin update: reported
mk q 2026.11.5; echo "Would update firecrawl: 2026.11.5 -> 2026.11.6." > "$work/q/state/lag"; GW_START_FAILS=1 run q --to 2026.11.6 --yes; rc=$?
[[ $rc != 0 ]] && out q | grep -q "Gateway not started" && ok || bad "gateway start fails: rc $rc"

printf '%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
