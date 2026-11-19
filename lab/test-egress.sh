#!/usr/bin/env bash
# Lab VM: test the egress firewall for the lab user. Run on the lab VM, with sudo.
#
#   sudo lab/test-egress.sh                 check the live rules and what the lab user can reach
#   sudo lab/test-egress.sh --reboot-test   prove the rules still allow MagicDNS after a reboot
#
# --reboot-test is two runs of the same command. The first rebuilds the firewall service with ONLY
# the first resolver in LAB_DNS_SERVERS (so a MagicDNS allowance can't come from the settings), then
# offers to reboot. After the reboot, run `sudo lab/test-egress.sh` again: it sees the pending test,
# checks, then puts the firewall back to your settings and prints the result.
# Changes nothing else; needs the checkout to have the MagicDNS change (git pull).
source "$(dirname "$0")/../lib/common.sh"
require_root
trap - ERR; set +e; set +o pipefail   # pipefail off: 'iptables -S | grep -q' must not fail on SIGPIPE

state="${OC_TEST_STATE_DIR:-/var/lib/openclaw-egress-test}"
pending="$state/pending"
chain=OC_EGRESS
pass=0; fail=0
t() { # t "name" command [hint]   (passes when the command succeeds)
  if eval "$2" >/dev/null 2>&1; then ok "PASS  $1"; pass=$((pass+1)); else warn "FAIL  $1${3:+  -> $3}"; fail=$((fail+1)); fi
}
rules() { iptables -S "$chain" 2>/dev/null; }
have_ts() { command -v tailscale >/dev/null 2>&1; }
apply_firewall() { "$BUNDLE_DIR/pi/20-egress.sh" "$LAB_USER" "$1" "$PI_TAILNET_IP:443"; }

[[ -n "${LAB_USER:-}" && -n "${LAB_DNS_SERVERS:-}" && -n "${PI_TAILNET_IP:-}" ]] \
  || die "set LAB_USER, LAB_DNS_SERVERS and PI_TAILNET_IP in config/settings.env"
grep -q 'command -v tailscale' "$BUNDLE_DIR/pi/egress-rules.sh" \
  || die "this checkout lacks the MagicDNS change in pi/egress-rules.sh. Run: git pull"

case "${1:-}" in
  --reboot-test)
    first="${LAB_DNS_SERVERS%% *}"
    log "Rebuilding the firewall service with only '$first' as its resolver"
    apply_firewall "$first" || die "could not apply the firewall; see above"
    install -d -m 700 "$state"; date +%s >"$pending"
    log "Ready. Reboot, then run again: sudo lab/test-egress.sh"
    if confirm "Reboot now?"; then systemctl reboot; else echo "Reboot when you're ready, then run: sudo lab/test-egress.sh"; fi
    exit 0 ;;
  "") ;;
  *) die "usage: sudo lab/test-egress.sh [--reboot-test]" ;;
esac

after_reboot=0
if [[ -f "$pending" ]]; then
  boot="${OC_BOOT_EPOCH:-$(( $(date +%s) - $(cut -d. -f1 /proc/uptime) ))}"
  (( boot >= $(cat "$pending") )) \
    || die "a reboot test is waiting, but this machine hasn't rebooted since it was set up. Reboot, then rerun this"
  after_reboot=1
  log "Checking AFTER the reboot test (the service was given only the first resolver)"
else
  log "Checking the live firewall for $LAB_USER"
fi

gw="$(ip -4 route show default | awk '{print $3; exit}')"
t "egress service is active"  "systemctl is-active openclaw-egress.service"
t "egress service is enabled" "systemctl is-enabled openclaw-egress.service"
for ip in $LAB_DNS_SERVERS; do
  [[ "$ip" == *:* ]] && continue
  t "DNS allowed to $ip"      "rules | grep -q -- '-d $ip/32 -p udp -m udp --dport 53 -j RETURN'"
done
if have_ts; then
  t "MagicDNS 100.100.100.100 allowed (port 53)" "rules | grep -q -- '-d 100.100.100.100/32 -p udp -m udp --dport 53 -j RETURN'" "restart: sudo systemctl restart openclaw-egress"
  if command -v ip6tables >/dev/null 2>&1; then
    t "MagicDNS IPv6 resolver allowed (port 53)" "ip6tables -S $chain | grep -qE 'fd7a:115c:a1e0::53.*--dport 53 -j RETURN'"
  fi
fi
t "DNS rules sit before the tailnet reject" \
  "d=\$(rules | grep -n -- '--dport 53 -j RETURN' | head -1 | cut -d: -f1); r=\$(rules | grep -n -- '-d 100.64.0.0/10 -j REJECT' | head -1 | cut -d: -f1); [[ -n \$d && -n \$r && \$d -lt \$r ]]"
t "Pi tailnet IP allowed on 443"  "rules | grep -q -- '-d $PI_TAILNET_IP/32 -p tcp -m tcp --dport 443 -j RETURN'"
t "$LAB_USER resolves openclaw.ai"            "sudo -u $LAB_USER getent hosts openclaw.ai" "DNS is blocked for $LAB_USER"
t "$LAB_USER reaches openclaw.ai over https"  "sudo -u $LAB_USER curl -s -m 10 -o /dev/null https://openclaw.ai/"
[[ -n "${PI_TAILNET_NAME:-}" ]] && \
  t "$LAB_USER reaches the Pi Gateway ($PI_TAILNET_NAME)" "sudo -u $LAB_USER curl -s -m 10 -o /dev/null https://$PI_TAILNET_NAME/"
t "LAN gateway $gw blocked for $LAB_USER"     "! sudo -u $LAB_USER curl -s -m 5 -o /dev/null http://$gw/"
t "MagicDNS not reachable over http for $LAB_USER" "! sudo -u $LAB_USER curl -s -m 5 -o /dev/null http://100.100.100.100/"
if (( after_reboot )); then
  t "the service's own resolver list does not name MagicDNS (so the allowance came from the script)" \
    "! systemctl cat openclaw-egress.service | grep ExecStart | grep -q 100.100.100.100"
fi

echo
if (( after_reboot )); then
  log "Restoring the firewall to your settings (LAB_DNS_SERVERS=\"$LAB_DNS_SERVERS\")"
  if apply_firewall "$LAB_DNS_SERVERS" >/dev/null; then rm -f "$pending"; ok "restored; reboot test cleared"
  else warn "could not restore; run: sudo pi/20-egress.sh $LAB_USER \"$LAB_DNS_SERVERS\" \"$PI_TAILNET_IP:443\""; fi
fi
log "Result: $pass passed, $fail failed"
(( after_reboot )) && { (( fail == 0 )) && ok "MagicDNS survived the reboot with no explicit entry" || warn "the reboot test FAILED; see the lines above"; }
[[ "$fail" -eq 0 ]]
