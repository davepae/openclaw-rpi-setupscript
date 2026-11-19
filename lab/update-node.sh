#!/usr/bin/env bash
# Lab VM: update the lab exec node in place and keep this VM's config/settings.env in step.
# Keeps the pairing, device ID and approvals, so no join URL is needed.
#
#   sudo lab/update-node.sh                  update to the OPENCLAW_VERSION already in settings.env
#   sudo lab/update-node.sh --to 2026.11.6   update to that version, then write it into settings.env
#
# This VM's settings.env is its own file (git doesn't touch it, and pi/bump-version.sh on the Pi
# can't reach it), so the pin is written here, and only after the update has worked: a failed
# update never leaves the pin ahead of what runs. Before changing anything it checks the release's
# Node "engines" range against NODE_VERSION. Run it from the repository on the lab VM.
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/versions.sh"
require_root

target="$OPENCLAW_VERSION"; write_pin=0
case "${1:-}" in
  --to) target="${2:-}"; [[ -n "$target" ]] || die "--to needs a version"; write_pin=1 ;;
  "") ;;
  *) die "usage: sudo lab/update-node.sh [--to <version>]" ;;
esac
settings="$BUNDLE_DIR/config/settings.env"
step="${OC_WAIT_STEP:-5}"; max="${OC_WAIT_MAX:-120}"
oc() { as_user "$LAB_USER" "openclaw $*"; }

log "Looking up $target"
doc="$(npm_doc "$target")" || true
[[ "$(jq -r '.version // empty' <<<"$doc" 2>/dev/null)" == "$target" ]] || die "npm has no OpenClaw $target (typo, or offline)"
engines="$(jq -r '.engines.node // empty' <<<"$doc")"
if [[ -n "$engines" ]]; then
  semver_satisfies "$NODE_VERSION" "$engines" && rc=0 || rc=$?   # errexit is on: capture the status
  case "$rc" in
    0) ok "NODE_VERSION $NODE_VERSION satisfies: $engines" ;;
    1) die "NODE_VERSION $NODE_VERSION does not satisfy $target's engines ($engines). Set NODE_VERSION in $settings first" ;;
    *) warn "could not evaluate '$engines' here; compare it with NODE_VERSION $NODE_VERSION yourself" ;;
  esac
fi

running="$(ver_extract "$(oc --version 2>/dev/null | head -1)")"
sync_pin() {
  (( write_pin )) || return 0
  if [[ "$(settings_value "$settings" OPENCLAW_VERSION)" == "$target" ]]; then ok "OPENCLAW_VERSION is already $target in $settings"
  else settings_set "$settings" OPENCLAW_VERSION "$target" && ok "OPENCLAW_VERSION is now $target in $settings" \
    || warn "updated, but could not rewrite OPENCLAW_VERSION in $settings; set it to $target yourself"; fi
}
if [[ "$running" == "$target" ]]; then ok "the node already runs $target"; sync_pin; exit 0; fi

log "Updating the lab node ${running:+from $running }to $target"
oc node stop || warn "could not stop the node service (was it running?)"
as_user "$LAB_USER" "curl -fsSL --proto '=https' --tlsv1.2 https://openclaw.ai/install-cli.sh \
  | bash -s -- --prefix \"\$HOME/.openclaw\" --version '$target' --node-version '$NODE_VERSION' --no-onboard"
oc node start

# The node's own startup maintenance holds the state database for a short while; client commands
# fail with "busy" until it finishes, and with a migration message if a credential import is due.
asked_doctor=0
settled() { # settled: succeeds once `approvals get` answers properly; sets $last
  last="$(oc approvals get 2>&1)"
  grep -q 'Defaults' <<<"$last" && ! grep -qE 'Cannot admit|migration is incomplete|state database is busy' <<<"$last"
}
log "Waiting for the node to settle (up to ${max}s)"
waited=0
until settled; do
  if grep -q 'migration is incomplete' <<<"$last" && (( ! asked_doctor )); then
    asked_doctor=1
    warn "client commands say the credential migration is incomplete. 'openclaw doctor --fix' imports it (run as $LAB_USER with the node stopped); it also refreshes the plugin registry and disables skills that can't run here"
    confirm "Run 'openclaw doctor --fix' now?" || die "left as is. Run doctor --fix as $LAB_USER yourself, then 'openclaw node start'"
    oc node stop || true
    oc doctor --fix || warn "doctor --fix reported a problem; read the output above"
    oc node start
    waited=0; continue
  fi
  (( waited >= max )) && { printf '%s\n' "$last" | tail -5; die "the node didn't settle within ${max}s; see the last output above"; }
  sleep "$step"; waited=$(( waited + step ))
done
ok "node answers; approvals intact:"
grep -E 'Defaults|Allowlist ' <<<"$last"

now="$(ver_extract "$(oc --version 2>/dev/null | head -1)")"
[[ "$now" == "$target" ]] || die "after the install the lab user runs '${now:-unknown}', not $target; the pin was NOT changed"
ok "the lab node runs $target"
sync_pin

echo
log "Next, on the Pi:  sudo pi/80-nodes.sh status    (lab-exec connected, same device ID, nothing pending)"
log "                  sudo pi/99-verify.sh          (no version warnings)"
if as_user "$LAB_USER" "docker ps -a --format '{{.Names}}'" 2>/dev/null | grep -qx "$LAB_DESKTOP_NODE_NAME"; then
  warn "the desktop node container exists and still runs the old version. Rebuild it: sudo lab/30-desktop-node.sh"
fi
