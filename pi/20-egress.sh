#!/usr/bin/env bash
# Phase 2 — host egress filter for openclaw_user (pfSense VLAN rules are separate; see RUNBOOK).
source "$(dirname "$0")/../lib/common.sh"
require_root
# Optional args (used by the lab VM): <user> "<dns ips>" "<allow ips>"
EG_USER="${1:-$OC_USER}"; EG_DNS="${2:-$DNS_SERVERS}"; EG_ALLOW="${3:-$EGRESS_ALLOW_HOSTS}"

for e in $EG_ALLOW; do
  [[ "$e" == *.*:* ]] || warn "EGRESS_ALLOW_HOSTS entry '$e' has no port: every port on it is open to $EG_USER, including sandbox containers"
done
install -m 0755 "$BUNDLE_DIR/pi/egress-rules.sh" /usr/local/sbin/openclaw-egress-rules
write_file /etc/systemd/system/openclaw-egress.service 0644 root:root <<EOF
[Unit]
Description=Owner-match egress filter for $EG_USER
After=network-pre.target tailscaled.service
Wants=network-pre.target
Before=user@$(user_uid "$EG_USER").service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/openclaw-egress-rules $EG_USER "$EG_DNS" "$EG_ALLOW"

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable openclaw-egress.service
systemctl restart openclaw-egress.service
iptables -S OC_EGRESS

log "Self-test as $EG_USER"
gw="$(ip -4 route show default | awk '{print $3; exit}')"
if sudo -u "$EG_USER" curl -sS -m 5 -o /dev/null "http://$gw/" 2>/dev/null; then
  die "$EG_USER reached the LAN gateway $gw — rules not effective"
else ok "LAN gateway $gw blocked for $EG_USER"; fi
sudo -u "$EG_USER" curl -sS -m 10 -o /dev/null https://deb.debian.org/ && ok "internet reachable for $EG_USER" \
  || warn "internet unreachable for $EG_USER — check DNS ($EG_DNS)"

stamp 20-egress
