#!/usr/bin/env bash
# Pi: upgrade OpenClaw in place, start to finish. Run from your admin account.
#
#   sudo pi/update.sh --to 2026.11.6     upgrade to that version (and write it into config/settings.env)
#   sudo pi/update.sh                    upgrade to the OPENCLAW_VERSION already in settings.env
#   add --yes to skip the "this restarts the Gateway" question
#
# What it runs, in order (the same steps as README, "Upgrading OpenClaw"):
#   1. looks the version up on npm and checks its Node "engines" range against NODE_VERSION
#   2. compares Dockerfile.common between the running and the target release
#   3. pi/50-openclaw.sh    reinstalls OpenClaw at the target (onboarding skipped: the answer is "n")
#   4. updates installed plugins that lag (Firecrawl, SearXNG): this needs the Gateway stopped, so it
#      stops it, updates, and starts it again
#   5. pi/60-images.sh --rebuild, only when Dockerfile.common changed (or couldn't be compared)
#   6. pi/70-configure.sh   re-registers models, re-locks the policy hashes, restarts the Gateway
#   7. pi/99-verify.sh
# Phase 50 reads the pin from settings.env, so the pin is written first and put back if the install
# fails or lands on the wrong version. The lab VM is separate: sudo lab/update-node.sh --to <version>.
# Rollback is not scripted; 70-configure.sh saves a config backup each run (~openclaw_user/backups/config/).
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/versions.sh"
require_root

settings="$BUNDLE_DIR/config/settings.env"
old_pin="$OPENCLAW_VERSION"; target="$OPENCLAW_VERSION"; assume_yes=0
while (( $# )); do
  case "$1" in
    --to)  [[ -n "${2:-}" ]] || die "--to needs a version"; target="$2"; shift 2 ;;
    --yes) assume_yes=1; shift ;;
    *) die "usage: sudo pi/update.sh [--to <version>] [--yes]" ;;
  esac
done
oc() { as_user "$OC_USER" "openclaw $*"; }
cur_version() { local out; out="$(oc --version 2>/dev/null | head -1)" || true; ver_extract "$out" || true; }
gateway() { as_user "$OC_USER" "systemctl --user $1 openclaw-gateway.service"; }
problems=()

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

running="$(cur_version)"
if [[ "$running" == "$target" ]]; then
  ok "the Pi already runs $target"
  if [[ "$old_pin" != "$target" ]]; then
    settings_set "$settings" OPENCLAW_VERSION "$target" && ok "OPENCLAW_VERSION is now $target in $settings" \
      || warn "could not rewrite OPENCLAW_VERSION in $settings; set it to $target yourself"
  fi
  log "Nothing to upgrade. Check it with: sudo pi/99-verify.sh"
  exit 0
fi

need_images=1
if [[ -n "$running" ]]; then
  old_df="$(dockerfile_common "$running")" || old_df=""
  new_df="$(dockerfile_common "$target")" || new_df=""
  if [[ -z "$old_df" || -z "$new_df" ]]; then warn "couldn't fetch Dockerfile.common to compare; the sandbox images will be rebuilt to be safe"
  elif [[ "$old_df" != "$new_df" ]]; then log "Dockerfile.common changed between $running and $target; the sandbox images will be rebuilt"
  else need_images=0; ok "Dockerfile.common is unchanged; the images are not rebuilt (the weekly timer rebuilds them anyway)"; fi
fi

log "Upgrading the Pi ${running:+from $running }to $target"
(( assume_yes )) || confirm "This reinstalls OpenClaw and restarts the Gateway (agent turns in progress are interrupted). Continue?" \
  || die "stopped; nothing was changed"

restore_pin() {
  [[ "$old_pin" == "$target" ]] && return 0
  settings_set "$settings" OPENCLAW_VERSION "$old_pin" && warn "put OPENCLAW_VERSION back to $old_pin" \
    || warn "couldn't put OPENCLAW_VERSION back; set it to $old_pin in $settings yourself"
}
settings_set "$settings" OPENCLAW_VERSION "$target" || die "could not write OPENCLAW_VERSION in $settings"

log "Phase 50: installing OpenClaw $target (onboarding skipped)"
if ! printf 'n\n' | "$BUNDLE_DIR/pi/50-openclaw.sh"; then
  restore_pin; die "phase 50 failed; the Gateway was not restarted. Fix the error above and rerun"
fi
now="$(cur_version)"
if [[ "$now" != "$target" ]]; then
  restore_pin; die "after the install the Pi runs '${now:-unknown}', not $target"
fi
ok "OpenClaw $target is installed"

# `plugins update` is offline-only: it refuses while the Gateway is running.
lagging="$(oc plugins update --all --dry-run 2>&1 | sed -nE 's/^Would update ([^:]+):.*/\1/p')" || lagging=""
if [[ -n "$lagging" ]]; then
  log "Plugins behind $target: $(tr '\n' ' ' <<<"$lagging")"
  gateway stop || warn "couldn't stop the Gateway; the plugin update will probably refuse"
  sleep 5
  for id in $lagging; do
    oc plugins update "$id" || { warn "plugin update failed for $id"; problems+=("plugin $id not updated"); }
  done
  gateway start || { warn "couldn't start the Gateway"; problems+=("Gateway not started"); }
else
  ok "no installed plugin needs updating"
fi

if (( need_images )); then
  log "Phase 60: rebuilding the sandbox images"
  "$BUNDLE_DIR/pi/60-images.sh" --rebuild || { warn "image rebuild failed"; problems+=("images not rebuilt (run: sudo pi/60-images.sh --rebuild)"); }
fi

log "Phase 70: re-locking the policy and restarting the Gateway"
"$BUNDLE_DIR/pi/70-configure.sh" || { warn "70-configure failed"; problems+=("70-configure failed (rerun: sudo pi/70-configure.sh)"); }

log "Phase 99: verify"
vout="$(mktemp)"; trap 'rm -f "$vout"' EXIT
if "$BUNDLE_DIR/pi/99-verify.sh" 2>&1 | tee "$vout"; then :; else problems+=("99-verify reported failures"); fi
summary="$(grep -E 'Automated:' "$vout" | tail -1 || true)"

echo
if (( ${#problems[@]} )); then
  warn "upgraded to $target, with problems:"; printf '  - %s\n' "${problems[@]}" >&2
else
  ok "upgraded to $target. ${summary#*==> }"
fi
log "Next, on the lab VM:  sudo lab/update-node.sh --to $target     (and sudo lab/30-desktop-node.sh if you built the desktop node)"
log "Then on the Pi:       sudo pi/80-nodes.sh status    and ask an agent for a page fetch"
if (( ${#problems[@]} )); then exit 1; fi
