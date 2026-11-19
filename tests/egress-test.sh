#!/usr/bin/env bash
# Unit tests for pi/egress-rules.sh. Stubs iptables/ip6tables (they only record their arguments), so it
# needs no root and touches no firewall. Run it anywhere with bash and grep.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../pi/egress-rules.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

# run <name> <resolv.conf text> <tailscale installed: 1|0> <dns list> <allow list>
# Leaves the recorded v4 rules in $work/$name/iptables.log and v6 in ip6tables.log.
run() {
  local name="$1" resolv="$2" ts="$3" dns="$4" allow="$5" d="$work/$1"
  mkdir -p "$d/bin"
  for t in iptables ip6tables; do
    # -C (does the jump exist?) fails so the script inserts it; everything else succeeds and is logged
    printf '#!/bin/sh\n[ "$2" = "-C" ] && exit 1\necho "$*" >> "%s/%s.log"\n' "$d" "$t" > "$d/bin/$t"
    chmod +x "$d/bin/$t"
  done
  ln -s "$(command -v grep)" "$d/bin/grep"
  if [[ "$ts" == 1 ]]; then printf '#!/bin/sh\nexit 0\n' > "$d/bin/tailscale"; chmod +x "$d/bin/tailscale"; fi
  printf '%s' "$resolv" > "$d/resolv.conf"
  : > "$d/iptables.log"; : > "$d/ip6tables.log"
  PATH="$d/bin" OC_RESOLV_CONF="$d/resolv.conf" "$(command -v bash)" "$script" oclab "$dns" "$allow" > "$d/out" 2>&1 \
    || { bad "$name: script exited non-zero: $(cat "$d/out")"; return 1; }
}
has()   { grep -q -- "$2" "$work/$1/$3.log"; }                       # has <case> <pattern> <iptables|ip6tables>
count() { grep -c -- "$2" "$work/$1/$3.log" || true; }
magic4='-d 100.100.100.100 -p udp --dport 53 -j RETURN'
magic6='-d fd7a:115c:a1e0::53 -p udp --dport 53 -j RETURN'

# 1. resolv.conf names MagicDNS, Tailscale not installed: allowed (the original behavior)
if run a $'nameserver 100.100.100.100\nnameserver fd7a:115c:a1e0::53\n' 0 "10.0.0.1" ""; then
  has a "$magic4" iptables  && ok || bad "1: v4 MagicDNS rule missing when resolv.conf names it"
  has a "$magic6" ip6tables && ok || bad "1: v6 MagicDNS rule missing when resolv.conf names it"
fi

# 2. resolv.conf does not name MagicDNS yet (boot race) but Tailscale is installed: still allowed
if run b $'nameserver 10.0.0.1\n' 1 "10.0.0.1" ""; then
  has b "$magic4" iptables  && ok || bad "2: v4 MagicDNS rule missing with Tailscale installed"
  has b "$magic6" ip6tables && ok || bad "2: v6 MagicDNS rule missing with Tailscale installed"
fi

# 3. Neither: no MagicDNS rule, and the explicit resolver is still there
if run c $'nameserver 10.0.0.1\n' 0 "10.0.0.1" ""; then
  has c "100.100.100.100" iptables && bad "3: MagicDNS allowed with no Tailscale and no resolv.conf entry" || ok
  has c "fd7a:115c:a1e0::53" ip6tables && bad "3: v6 MagicDNS allowed with neither" || ok
  has c '-d 10.0.0.1 -p udp --dport 53 -j RETURN' iptables && ok || bad "3: explicit resolver rule missing"
fi

# 4. Explicit entry plus the automatic one: each rule written once
if run d $'nameserver 100.100.100.100\n' 1 "10.0.0.1 100.100.100.100" ""; then
  [[ "$(count d "$magic4" iptables)" == 1 ]] && ok || bad "4: duplicate v4 MagicDNS rule ($(count d "$magic4" iptables))"
  [[ "$(count d '-d 100.100.100.100 -p tcp --dport 53' iptables)" == 1 ]] && ok || bad "4: duplicate v4 tcp MagicDNS rule"
fi

# 5. A v4 address is never written to the v6 chain and the reverse
if run e $'nameserver 10.0.0.1\n' 1 "10.0.0.1" ""; then
  has e "10.0.0.1" ip6tables && bad "5: v4 resolver leaked into ip6tables" || ok
  has e "fd7a:115c:a1e0::53" iptables && bad "5: v6 resolver leaked into iptables" || ok
fi

# 6. DNS rules come before the tailnet reject, or they would never match
if run f $'nameserver 10.0.0.1\n' 1 "10.0.0.1" ""; then
  dnsln="$(grep -n -- "$magic4" "$work/f/iptables.log" | head -1 | cut -d: -f1)"
  rejln="$(grep -n -- '-d 100.64.0.0/10 -j REJECT' "$work/f/iptables.log" | head -1 | cut -d: -f1)"
  [[ -n "$dnsln" && -n "$rejln" && "$dnsln" -lt "$rejln" ]] && ok || bad "6: MagicDNS rule (line ${dnsln:-none}) not before the 100.64/10 reject (line ${rejln:-none})"
fi

# 7. ip:port allow entries still open only that TCP port, and the rest of the private ranges stay rejected
if run g $'nameserver 10.0.0.1\n' 0 "10.0.0.1" "100.73.244.94:443"; then
  has g '-d 100.73.244.94 -p tcp --dport 443 -j RETURN' iptables && ok || bad "7: ip:port allow rule missing"
  for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10; do
    has g "-d $net -j REJECT" iptables && ok || bad "7: $net no longer rejected"
  done
fi

printf '%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
