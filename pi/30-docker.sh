#!/usr/bin/env bash
# Phase 3 — Docker CE from Docker's Debian repo, then rootless Docker for openclaw_user.
# The rootful daemon is disabled: nobody (agent or admin) uses /var/run/docker.sock.
# Also used on the lab VM (lab/10-lab-host.sh calls it with the lab user).
source "$(dirname "$0")/../lib/common.sh"
require_root
TARGET_USER="${1:-$OC_USER}"

log "Docker apt repository"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
write_file /etc/apt/sources.list.d/docker.sources 0644 root:root <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: $(. /etc/os-release && echo "$VERSION_CODENAME")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin \
  docker-ce-rootless-extras uidmap slirp4netns

log "Disabling the rootful daemon"
systemctl disable --now docker.socket docker.service || true
# The system containerd service is only needed by rootful Docker; rootless dockerd starts its own.
systemctl disable --now containerd.service || true
rm -f /var/run/docker.sock
if getent group docker >/dev/null && [[ -n "$(getent group docker | cut -d: -f4)" ]]; then
  warn "docker group members: $(getent group docker | cut -d: -f4) — membership is root-equivalent; removing"
  for m in $(getent group docker | cut -d: -f4 | tr ',' ' '); do gpasswd -d "$m" docker; done
fi

log "Rootless Docker for $TARGET_USER"
loginctl enable-linger "$TARGET_USER"
uid="$(user_uid "$TARGET_USER")"
for _ in $(seq 1 20); do [[ -d /run/user/$uid ]] && break; sleep 1; done
home="$(user_home "$TARGET_USER")"

install -d -m 700 -o "$TARGET_USER" -g "$TARGET_USER" "$home/.config" "$home/.config/docker"
write_file "$home/.config/docker/daemon.json" 0600 "$TARGET_USER:$TARGET_USER" <<'EOF'
{
  "log-driver": "local",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF

as_user "$TARGET_USER" 'dockerd-rootless-setuptool.sh install'
as_user "$TARGET_USER" 'systemctl --user enable --now docker.service'

# Make the rootless socket the default for login shells of that user.
write_file "$home/.config/environment.d/50-docker.conf" 0644 "$TARGET_USER:$TARGET_USER" <<EOF
DOCKER_HOST=unix:///run/user/$uid/docker.sock
EOF
grep -q DOCKER_HOST "$home/.profile" 2>/dev/null || \
  echo "export DOCKER_HOST=unix:///run/user/$uid/docker.sock" >>"$home/.profile"

log "Verifying"
info="$(as_user "$TARGET_USER" 'docker info --format "{{.SecurityOptions}} {{.CgroupDriver}} {{.CgroupVersion}} {{.Driver}}"')"
echo "  $info"
[[ "$info" == *rootless* ]] || die "daemon is not rootless"
[[ "$info" == *systemd* ]] && ok "cgroup driver systemd" || warn "cgroup driver is not systemd — CPU/memory caps won't apply"
as_user "$TARGET_USER" 'docker info 2>&1 | grep -i "warning" || true'
as_user "$TARGET_USER" 'docker run --rm --memory 64m --cpus 0.5 --pids-limit 32 debian:trixie-slim cat /proc/self/status | grep -E "^(Uid|CapEff)"'
ok "rootless container ran with limits"

stamp "30-docker-$TARGET_USER"
