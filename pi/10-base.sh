#!/usr/bin/env bash
# Phase 1 — OS baseline and the unprivileged agent account.
#  * updates, timezone, base packages
#  * openclaw_user: no sudo, no password login, linger on, 65,536 subordinate IDs
#  * systemd user cgroup delegation (CPU/IO/memory/pids caps for rootless containers)
#  * disables services the design doesn't use
source "$(dirname "$0")/../lib/common.sh"
require_root

log "Updating OS"
export DEBIAN_FRONTEND=noninteractive
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get -y full-upgrade
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  ca-certificates curl git jq openssl uidmap dbus-user-session \
  iptables unattended-upgrades acl
timedatectl set-timezone "$TIMEZONE"
ok "timezone $TIMEZONE"

log "Automatic security updates"
dpkg-reconfigure -f noninteractive unattended-upgrades

log "Agent account $OC_USER"
if ! id "$OC_USER" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "OpenClaw agent" "$OC_USER"
  ok "created $OC_USER"
fi
passwd -l "$OC_USER" >/dev/null                 # no password login
for g in sudo adm docker; do
  if id -nG "$OC_USER" | tr ' ' '\n' | grep -qx "$g"; then gpasswd -d "$OC_USER" "$g"; fi
done
[[ -e /etc/sudoers.d/"$OC_USER" ]] && die "/etc/sudoers.d/$OC_USER exists — remove it; the agent account must have no sudo"
sudo -l -U "$OC_USER" 2>/dev/null | grep -q 'may run' && die "$OC_USER has sudo rights — remove them"
ok "$OC_USER has no sudo, no docker group, locked password"

# Subordinate IDs for rootless Docker (>= 65,536 each)
# (Debian's adduser normally assigns these; if not, take the next free range.)
next_free() { awk -F: 'BEGIN{m=100000} {e=$2+$3; if(e>m)m=e} END{print m}' "$1"; }
if ! grep -q "^$OC_USER:" /etc/subuid; then
  s="$(next_free /etc/subuid)"; usermod --add-subuids "$s-$((s+65535))" "$OC_USER"
fi
if ! grep -q "^$OC_USER:" /etc/subgid; then
  s="$(next_free /etc/subgid)"; usermod --add-subgids "$s-$((s+65535))" "$OC_USER"
fi
for f in /etc/subuid /etc/subgid; do
  cnt="$(awk -F: -v u="$OC_USER" '$1==u{s+=$3} END{print s+0}' "$f")"
  (( cnt >= 65536 )) || die "$f gives $OC_USER only $cnt IDs (need 65536)"
done
ok "subordinate IDs present"

loginctl enable-linger "$OC_USER"
ok "linger enabled (user services start at boot)"

oc_home="$(user_home "$OC_USER")"
chmod 750 "$oc_home"
for d in workspace reader lab worktrees; do
  install -d -m 750 -o "$OC_USER" -g "$OC_USER" "$oc_home/$d"
done
ok "workspace dirs under $oc_home"

log "cgroup delegation for systemd user sessions"
write_file /etc/systemd/system/user@.service.d/delegate.conf 0644 root:root <<'EOF'
[Service]
Delegate=cpu cpuset io memory pids
EOF
systemctl daemon-reload

log "Disabling unused services"
for s in bluetooth.service cups.service cups-browsed.service avahi-daemon.service avahi-daemon.socket; do
  if systemctl cat "$s" >/dev/null 2>&1; then
    systemctl disable --now "$s" >/dev/null 2>&1 && ok "disabled $s" || true
  fi
done

log "SSH: key-only login"
write_file /etc/ssh/sshd_config.d/10-openclaw-hardening.conf 0644 root:root <<EOF
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
DenyUsers $OC_USER
EOF
if sshd -t; then systemctl reload ssh; ok "sshd reloaded"; else die "sshd config test failed"; fi
warn "Make sure your SSH key for $ADMIN_USER works in a second terminal before closing this one."

stamp 10-base
ok "base done — reboot now if the kernel or cmdline changed (sudo reboot)"
