#!/usr/bin/env bash
# Unit tests for lab/test-egress.sh with stubbed iptables, sudo, curl, systemctl and friends.
# Covers the checks and the --reboot-test state machine. Needs bash only; no root, no firewall.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; repo="$here/.."
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

v4_good='-N OC_EGRESS
-A OC_EGRESS -o lo -j RETURN
-A OC_EGRESS -d 172.16.1.2/32 -p udp -m udp --dport 53 -j RETURN
-A OC_EGRESS -d 172.16.1.2/32 -p tcp -m tcp --dport 53 -j RETURN
-A OC_EGRESS -d 100.100.100.100/32 -p udp -m udp --dport 53 -j RETURN
-A OC_EGRESS -d 100.100.100.100/32 -p tcp -m tcp --dport 53 -j RETURN
-A OC_EGRESS -d 100.73.244.94/32 -p tcp -m tcp --dport 443 -j RETURN
-A OC_EGRESS -d 10.0.0.0/8 -j REJECT --reject-with icmp-port-unreachable
-A OC_EGRESS -d 172.16.0.0/12 -j REJECT --reject-with icmp-port-unreachable
-A OC_EGRESS -d 100.64.0.0/10 -j REJECT --reject-with icmp-port-unreachable
-A OC_EGRESS -j RETURN'
v6_good='-N OC_EGRESS
-A OC_EGRESS -d fd7a:115c:a1e0::53/128 -p udp -m udp --dport 53 -j RETURN
-A OC_EGRESS -d fc00::/7 -j REJECT --reject-with icmp6-port-unreachable'
v4_nomagic="$(grep -v '100.100.100.100' <<<"$v4_good")"

# mk <name> [tailscale: 1|0]: a throwaway copy of the bundle with stub commands first on PATH
mk() {
  local b="$work/$1"; mkdir -p "$b"/{lab,lib,pi,config,bin,state}
  cp "$repo/lab/test-egress.sh" "$b/lab/"; sed -i '/^require_root$/d' "$b/lab/test-egress.sh"   # EUID can't be faked
  cp "$repo/lib/common.sh" "$b/lib/"; cp "$repo/pi/egress-rules.sh" "$b/pi/"
  printf 'LAB_USER="oclab"\nLAB_DNS_SERVERS="172.16.1.2 100.100.100.100"\nPI_TAILNET_IP="100.73.244.94"\nPI_TAILNET_NAME="hermes.example.ts.net"\n' > "$b/config/settings.env"
  printf '#!/bin/sh\necho "$@" >> "%s/applied.log"\n' "$b" > "$b/pi/20-egress.sh"; chmod +x "$b/pi/20-egress.sh"
  printf '%s\n' "$v4_good" > "$b/v4"; printf '%s\n' "$v6_good" > "$b/v6"
  printf '[Service]\nExecStart=/usr/local/sbin/openclaw-egress-rules oclab "172.16.1.2" "100.73.244.94:443"\n' > "$b/unit"
  stub() { printf '#!/bin/sh\n%s\n' "$2" > "$b/bin/$1"; chmod +x "$b/bin/$1"; }
  stub sudo   'while [ "$1" = -u ] || [ "$1" = -H ]; do [ "$1" = -u ] && shift; shift; done; exec "$@"'
  stub iptables  "[ \"\$1\" = -S ] && cat \"$b/v4\""
  stub ip6tables "[ \"\$1\" = -S ] && cat \"$b/v6\""
  stub systemctl "case \"\$1\" in cat) cat \"$b/unit\" ;; reboot) echo reboot >> \"$b/applied.log\" ;; *) [ -z \"\$SVC_DOWN\" ] ;; esac"
  stub getent '[ -z "$GETENT_FAIL" ]'
  stub ip     'echo "default via 172.16.1.1 dev eth0"'
  stub curl   'for a in "$@"; do case "$a" in *172.16.1.1*) [ -n "$GW_OPEN" ] && exit 0 || exit 28 ;; *100.100.100.100*) exit 28 ;; esac; done; exit 0'
  [[ "${2:-1}" == 1 ]] && stub tailscale 'exit 0'
  : > "$b/applied.log"
}
# run <name> [args]: runs the script; output in $work/<name>/out, exit status returned
run() { local n="$1"; shift
  PATH="$work/$n/bin:$PATH" OC_TEST_STATE_DIR="$work/$n/state" bash "$work/$n/lab/test-egress.sh" "$@" <<<"n" >"$work/$n/out" 2>&1; }
out() { cat "$work/$1/out"; }

# 1. everything healthy, no reboot test pending
mk a; run a; rc=$?
[[ $rc == 0 ]] && ok || bad "healthy: exit $rc: $(out a | tail -5)"
out a | grep -q "0 failed" && ok || bad "healthy: expected 0 failed"
out a | grep -q "MagicDNS 100.100.100.100 allowed" && ok || bad "healthy: MagicDNS check should run with Tailscale installed"

# 2. Tailscale installed but the MagicDNS rule is missing: the exact fault this test exists for
mk b; printf '%s\n' "$v4_nomagic" > "$work/b/v4"; run b; rc=$?
[[ $rc != 0 ]] && out b | grep -q "FAIL  MagicDNS 100.100.100.100 allowed" && ok || bad "missing MagicDNS rule should fail (rc $rc)"

# 3. no Tailscale on the box: the MagicDNS checks don't apply
mk c 0; run c; rc=$?
[[ $rc == 0 ]] && ok || bad "no tailscale: exit $rc"
out c | grep -q "allowed (port 53)" && grep -q "MagicDNS 100.100.100.100 allowed" "$work/c/out" && bad "no tailscale: the MagicDNS-allowed check should not run" || ok

# 4. the lab user can't resolve names
mk d; GETENT_FAIL=1 run d; rc=$?
[[ $rc != 0 ]] && out d | grep -q "FAIL  oclab resolves openclaw.ai" && ok || bad "dns broken should fail (rc $rc)"

# 5. the LAN gateway is reachable from the lab user: firewall not effective
mk e; GW_OPEN=1 run e; rc=$?
[[ $rc != 0 ]] && out e | grep -q "FAIL  LAN gateway" && ok || bad "open LAN gateway should fail (rc $rc)"

# 6. service down
mk f; SVC_DOWN=1 run f; rc=$?
[[ $rc != 0 ]] && out f | grep -q "FAIL  egress service is active" && ok || bad "service down should fail (rc $rc)"

# 7. --reboot-test applies ONLY the first resolver, records a pending test, and doesn't reboot on "n"
mk g; run g --reboot-test; rc=$?
[[ $rc == 0 ]] && ok || bad "reboot-test: exit $rc: $(out g)"
grep -qx 'oclab 172.16.1.2 100.73.244.94:443' "$work/g/applied.log" && ok || bad "reboot-test: should apply only the first resolver: $(cat "$work/g/applied.log")"
[[ -f "$work/g/state/pending" ]] && ok || bad "reboot-test: no pending marker"
grep -q '^reboot$' "$work/g/applied.log" && bad "reboot-test: rebooted although the answer was n" || ok

# 8. a pending test but no reboot yet: refuse to give a false result
mk h; date +%s > "$work/h/state/pending"; OC_BOOT_EPOCH=1 run h; rc=$?
[[ $rc != 0 ]] && out h | grep -q "hasn't rebooted" && ok || bad "not rebooted: should refuse (rc $rc)"
[[ -f "$work/h/state/pending" ]] && ok || bad "not rebooted: pending marker should stay"

# 9. after the reboot, all good: passes, restores the full settings, clears the marker
mk i; date +%s > "$work/i/state/pending"; OC_BOOT_EPOCH=$(( $(date +%s) + 60 )) run i; rc=$?
[[ $rc == 0 ]] && ok || bad "after reboot: exit $rc: $(out i | tail -6)"
grep -qx 'oclab 172.16.1.2 100.100.100.100 100.73.244.94:443' "$work/i/applied.log" && ok || bad "after reboot: should restore the settings: $(cat "$work/i/applied.log")"
[[ ! -f "$work/i/state/pending" ]] && ok || bad "after reboot: marker should be cleared"
out i | grep -q "survived the reboot" && ok || bad "after reboot: expected the success line"

# 10. after the reboot, MagicDNS missing: fails, but still restores the firewall and clears the marker
mk j; date +%s > "$work/j/state/pending"; printf '%s\n' "$v4_nomagic" > "$work/j/v4"; OC_BOOT_EPOCH=$(( $(date +%s) + 60 )) run j; rc=$?
[[ $rc != 0 ]] && out j | grep -q "reboot test FAILED" && ok || bad "after reboot, no MagicDNS: should fail (rc $rc)"
[[ ! -f "$work/j/state/pending" ]] && grep -qx 'oclab 172.16.1.2 100.100.100.100 100.73.244.94:443' "$work/j/applied.log" && ok || bad "after failed reboot test: should still restore and clear"

# 11. after the reboot, but the service's list names MagicDNS itself: the test would prove nothing
mk k; date +%s > "$work/k/state/pending"
printf '[Service]\nExecStart=/usr/local/sbin/openclaw-egress-rules oclab "172.16.1.2 100.100.100.100" "100.73.244.94:443"\n' > "$work/k/unit"
OC_BOOT_EPOCH=$(( $(date +%s) + 60 )) run k; rc=$?
[[ $rc != 0 ]] && out k | grep -q "FAIL  the service's own resolver list" && ok || bad "explicit MagicDNS in the unit should fail the reboot test (rc $rc)"

# 12. a checkout without the MagicDNS change stops early and says how to fix it
mk l; sed -i 's/command -v tailscale/command -v something-else/g' "$work/l/pi/egress-rules.sh"; run l; rc=$?
[[ $rc != 0 ]] && out l | grep -q "git pull" && ok || bad "stale checkout: should say git pull (rc $rc)"

# 13. bad argument
mk m; run m --nope; rc=$?
[[ $rc != 0 ]] && out m | grep -q "usage" && ok || bad "bad argument: should print usage (rc $rc)"

printf '%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
