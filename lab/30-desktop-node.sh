#!/usr/bin/env bash
# Desktop (computer-use) node: build and run the lab-desktop container in the lab user's rootless
# Docker, and enroll it with a single-use join URL.
#   On the Pi:  sudo pi/80-nodes.sh join
#   Here:       sudo lab/30-desktop-node.sh            (prompts for the join URL)
#   On the Pi:  sudo pi/80-nodes.sh status / approve <id> / finish
# Rerun (e.g. after bumping OPENCLAW_VERSION): rebuilds the image and keeps the pairing volume.
# Fresh pairing: sudo lab/30-desktop-node.sh --re-enroll
source "$(dirname "$0")/../lib/common.sh"
require_root
[[ -n "$PI_TAILNET_NAME" && -n "$PI_TAILNET_IP" ]] || die "set PI_TAILNET_NAME and PI_TAILNET_IP in config/settings.env"
home="$(user_home "$LAB_USER")"; ctx="$home/.cache/lab-desktop"
rm -rf "$ctx"; install -d -m 700 -o "$LAB_USER" -g "$LAB_USER" "$ctx"
cp "$BUNDLE_DIR/lab/desktop/"{Dockerfile,entrypoint.sh,session.sh} "$ctx/"
cp "$BUNDLE_DIR/config/approvals-lab-desktop.json5" "$ctx/approvals.json5"
chown -R "$LAB_USER:$LAB_USER" "$ctx"

log "Building lab-desktop:trixie (OpenClaw $OPENCLAW_VERSION)"
as_user "$LAB_USER" "docker build --pull --build-arg OPENCLAW_VERSION='$OPENCLAW_VERSION' --build-arg NODE_VERSION='$NODE_VERSION' -t lab-desktop:trixie '$ctx'"

join=""
if ! as_user "$LAB_USER" "docker volume inspect lab-desktop-state" >/dev/null 2>&1 || [[ "${1:-}" == "--re-enroll" ]]; then
  read -r -s -p "Paste the join URL from 'sudo pi/80-nodes.sh join' (single use, ~10 min): " join; echo
  [[ -n "$join" ]] || die "empty join URL"
  [[ "${1:-}" == "--re-enroll" ]] && as_user "$LAB_USER" "docker rm -f lab-desktop; docker volume rm lab-desktop-state" || true
fi

log "Starting lab-desktop"
as_user "$LAB_USER" "docker rm -f lab-desktop >/dev/null 2>&1 || true"
as_user "$LAB_USER" "docker run -d --name lab-desktop --restart unless-stopped \
  --cap-drop ALL --security-opt no-new-privileges \
  --pids-limit 1024 --memory 4g --memory-swap 4g --cpus 2 --shm-size 1g \
  --add-host '$PI_TAILNET_NAME:$PI_TAILNET_IP' \
  -e NODE_NAME='$LAB_DESKTOP_NODE_NAME' -e ENABLE_VNC=1 ${join:+-e OPENCLAW_JOIN_URL='$join'} \
  -v lab-desktop-state:/home/desktop/.openclaw \
  lab-desktop:trixie"
unset join
sleep 15
as_user "$LAB_USER" "docker logs --tail 40 lab-desktop"
ok "lab-desktop running. On the Pi: sudo pi/80-nodes.sh status, approve any computer.act update, then finish."
warn "The join URL was passed as a container env var on first start; it is single-use and expires in ~10 min."
stamp lab-30-desktop
