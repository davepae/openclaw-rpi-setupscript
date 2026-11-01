#!/usr/bin/env bash
# Lab VM (Debian 13; a VM on any x86 or arm64 host with snapshots, ideally on its own VLAN) — host baseline:
#   lab user (no sudo), linger, cgroup delegation, rootless Docker, Tailscale,
#   egress: internet + DNS + the Pi's tailnet IP on 443 only (no LAN, rest of tailnet blocked).
# Copy the whole bundle (with config/settings.env) to the VM and run: sudo lab/10-lab-host.sh
source "$(dirname "$0")/../lib/common.sh"
require_root
[[ -n "$PI_TAILNET_IP" ]] || die "set PI_TAILNET_IP in config/settings.env (from pi/40-tailscale.sh output)"
. /etc/os-release; [[ "$ID" == debian ]] || warn "written for Debian 13; found $PRETTY_NAME"

export DEBIAN_FRONTEND=noninteractive
apt-get update && apt-get -y full-upgrade
apt-get install -y --no-install-recommends ca-certificates curl git jq openssl uidmap dbus-user-session iptables unattended-upgrades
dpkg-reconfigure -f noninteractive unattended-upgrades
timedatectl set-timezone "$TIMEZONE"

if ! id "$LAB_USER" >/dev/null 2>&1; then adduser --disabled-password --gecos "OpenClaw lab" "$LAB_USER"; fi
passwd -l "$LAB_USER" >/dev/null
for g in sudo adm docker; do id -nG "$LAB_USER" | tr ' ' '\n' | grep -qx "$g" && gpasswd -d "$LAB_USER" "$g"; done
next_free() { awk -F: 'BEGIN{m=100000} {e=$2+$3; if(e>m)m=e} END{print m}' "$1"; }
grep -q "^$LAB_USER:" /etc/subuid || { s="$(next_free /etc/subuid)"; usermod --add-subuids "$s-$((s+65535))" "$LAB_USER"; }
grep -q "^$LAB_USER:" /etc/subgid || { s="$(next_free /etc/subgid)"; usermod --add-subgids "$s-$((s+65535))" "$LAB_USER"; }
loginctl enable-linger "$LAB_USER"
install -d -m 750 -o "$LAB_USER" -g "$LAB_USER" "$(user_home "$LAB_USER")/work"
write_file /etc/systemd/system/user@.service.d/delegate.conf 0644 root:root <<'EOF'
[Service]
Delegate=cpu cpuset io memory pids
EOF
systemctl daemon-reload
ok "lab user $LAB_USER ready"

"$BUNDLE_DIR/pi/30-docker.sh" "$LAB_USER"
"$BUNDLE_DIR/pi/40-tailscale.sh" none "$TS_TAG_LAB"      # no Tailscale operator on the lab
"$BUNDLE_DIR/pi/20-egress.sh" "$LAB_USER" "$LAB_DNS_SERVERS" "$PI_TAILNET_IP:443"   # Gateway over Serve only

log "Check: lab user can reach the Pi's Gateway over the tailnet"
if [[ -n "$PI_TAILNET_NAME" ]] && sudo -u "$LAB_USER" curl -s -m 10 -o /dev/null -w '%{http_code}\n' "https://$PI_TAILNET_NAME/"; then
  ok "Pi reachable at https://$PI_TAILNET_NAME/"
else warn "Pi not reachable over Tailscale yet — check tailnet policy (lab VM -> Pi:443 must be allowed)"; fi
warn "Snapshot this VM now (clean baseline). Rebuild from the snapshot when in doubt."
stamp lab-10-host
