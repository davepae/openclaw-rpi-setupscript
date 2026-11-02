#!/usr/bin/env bash
# Lab exec node (tier 3): OpenClaw node host as a user service for the lab user.
# Order matters: local approvals are written BEFORE the join URL is redeemed, because local exec
# approvals default to security "full" / ask "off" and an admin-minted join code approves the
# first declared surface (including system.run) automatically.
#   On the Pi:  sudo pi/80-nodes.sh join        -> copy the URL (valid ~10 min, single use)
#   Here:       sudo lab/20-exec-node.sh            (prompts for the URL; keeps it out of argv)
#   On the Pi:  sudo pi/80-nodes.sh finish
source "$(dirname "$0")/../lib/common.sh"
require_root
JOIN_URL="${1:-}"
[[ -n "$JOIN_URL" ]] || { read -r -s -p "Paste the join URL from 'sudo pi/80-nodes.sh join': " JOIN_URL; echo; }
[[ -n "$JOIN_URL" ]] || die "empty join URL"
home="$(user_home "$LAB_USER")"

log "Installing OpenClaw $OPENCLAW_VERSION for $LAB_USER (rootless install-cli.sh)"
as_user "$LAB_USER" "curl -fsSL --proto '=https' --tlsv1.2 https://openclaw.ai/install-cli.sh \
  | bash -s -- --prefix \"\$HOME/.openclaw\" --version '$OPENCLAW_VERSION' --node-version '$NODE_VERSION' --no-onboard"

log "Local approvals first (allowlist + ask on-miss + deny on no answer)"
install -m 600 -o "$LAB_USER" -g "$LAB_USER" "$BUNDLE_DIR/config/approvals-lab-exec.json5" "$home/.cache-approvals.json5"
as_user "$LAB_USER" "openclaw approvals set --file \$HOME/.cache-approvals.json5 && openclaw approvals get"
rm -f "$home/.cache-approvals.json5"

# Headless nodes self-update by default (docs/nodes/node-host.md); keep the lab on the pinned
# version and update it by hand alongside the Pi.
as_user "$LAB_USER" "openclaw config set nodeHost.autoUpdate.enabled false"

log "Redeeming the join URL and installing the node service"
extra=""
if [[ "${LAB_SESSION_HOST:-0}" == "1" ]]; then
  # Session hosting runs whole agent sessions here. In 2026.10.8 there is no folder restriction key
  # (nodeHost.workerRuns.folders is not in the schema); isolate worker sessions in containers instead.
  as_user "$LAB_USER" "openclaw config set nodeHost.workerRuns.isolation container"
  extra="--session-host"
fi
tf="$home/.openclaw-join-url"; install -m 600 -o "$LAB_USER" -g "$LAB_USER" /dev/null "$tf"
printf '%s\n' "$JOIN_URL" >"$tf"   # --target-file reads and removes it (keeps the URL out of ps/argv)
as_user "$LAB_USER" "openclaw connect --target-file '$tf' --service --display-name '$LAB_EXEC_NODE_NAME' $extra"
sleep 5
as_user "$LAB_USER" "openclaw node status"
ok "lab exec node enrolled. Now on the Pi: sudo pi/80-nodes.sh finish"
stamp lab-20-exec-node
