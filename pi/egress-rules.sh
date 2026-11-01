#!/usr/bin/env bash
# Applies owner-match egress rules for one local user. Idempotent; run at boot by
# openclaw-egress.service. Usage: egress-rules.sh <user> "<dns ips>" "<allow ips>"
# Blocks the user's own sockets (and therefore rootless-Docker container traffic,
# which leaves through that user's network helper — flagged #8, verify with test 3)
# from reaching private, CGNAT/tailnet and link-local ranges, except DNS and allowlisted hosts.
set -euo pipefail
user="$1"; dns="${2:-}"; allow="${3:-}"
chain=OC_EGRESS

apply() { # apply <iptables|ip6tables> <family>
  local ipt="$1" fam="$2"
  $ipt -w -N "$chain" 2>/dev/null || $ipt -w -F "$chain"
  $ipt -w -C OUTPUT -m owner --uid-owner "$user" -j "$chain" 2>/dev/null \
    || $ipt -w -I OUTPUT 1 -m owner --uid-owner "$user" -j "$chain"
  $ipt -w -A "$chain" -o lo -j RETURN
  $ipt -w -A "$chain" -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
  for ip in $dns; do
    [[ "$ip" == *:* && "$fam" == 4 ]] && continue; [[ "$ip" != *:* && "$fam" == 6 ]] && continue
    $ipt -w -A "$chain" -d "$ip" -p udp --dport 53 -j RETURN
    $ipt -w -A "$chain" -d "$ip" -p tcp --dport 53 -j RETURN
  done
  # Allow entries: "a.b.c.d:port" (IPv4, TCP to that port only — preferred) or a bare address
  # (all ports; IPv4 or IPv6). Every openclaw_user socket shares this rule, including
  # builder's containers, so open only the ports the Gateway's tools actually need.
  local e ip port
  for e in $allow; do
    if [[ "$e" =~ ^([0-9]{1,3}(\.[0-9]{1,3}){3}):([0-9]{1,5})$ ]]; then
      ip="${BASH_REMATCH[1]}"; port="${BASH_REMATCH[3]}"
      [[ "$fam" == 4 ]] || continue
      $ipt -w -A "$chain" -d "$ip" -p tcp --dport "$port" -j RETURN
    else
      ip="$e"
      [[ "$ip" == *:* && "$fam" == 4 ]] && continue; [[ "$ip" != *:* && "$fam" == 6 ]] && continue
      $ipt -w -A "$chain" -d "$ip" -j RETURN
    fi
  done
  if [[ "$fam" == 4 ]]; then
    for net in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 100.64.0.0/10 169.254.0.0/16 0.0.0.0/8 224.0.0.0/4; do
      $ipt -w -A "$chain" -d "$net" -j REJECT
    done
  else
    for net in fc00::/7 fe80::/10 ff00::/8; do
      $ipt -w -A "$chain" -d "$net" -j REJECT
    done
  fi
  $ipt -w -A "$chain" -j RETURN
}

# Tailscale MagicDNS resolver lives in 100.64.0.0/10; allow DNS to it if it's in use.
grep -q '^nameserver 100.100.100.100' /etc/resolv.conf 2>/dev/null && dns="$dns 100.100.100.100"
grep -q '^nameserver fd7a:115c:a1e0::53' /etc/resolv.conf 2>/dev/null && dns="$dns fd7a:115c:a1e0::53"

apply iptables 4
command -v ip6tables >/dev/null && apply ip6tables 6
echo "egress rules applied for $user"
