#!/usr/bin/env bash
# Phase 7 — apply the design's openclaw.json, the Gateway host approvals document, and the
# drift policy; then run the built-in gates. Run with sudo. Safe to rerun.
source "$(dirname "$0")/../lib/common.sh"
source "$(dirname "$0")/../lib/models.sh"
source "$(dirname "$0")/../lib/policy.sh"
require_root
home="$(user_home "$OC_USER")"
stage="$home/.cache/openclaw-config"; install -d -m 700 -o "$OC_USER" -g "$OC_USER" "$stage"

export OC_HOME="$home"
render "$BUNDLE_DIR/config/openclaw.patch.json5" >"$stage/openclaw.patch.json5"
for f in approvals-gateway.json5 elevated.patch.json5 computer.patch.json5 policy.jsonc; do
  cp "$BUNDLE_DIR/config/$f" "$stage/$f"
done
chown -R "$OC_USER:$OC_USER" "$stage"; chmod 600 "$stage"/*

oc() { as_user "$OC_USER" "openclaw $*"; }

log "Backing up current config"
# Without --output, OpenClaw writes the archive to the current folder (the agent user's home).
# Keep these config-only snapshots apart from the nightly full backups in ~/backups.
install -d -m 700 -o "$OC_USER" -g "$OC_USER" "$(user_home "$OC_USER")/backups" "$(user_home "$OC_USER")/backups/config"
oc "backup create --only-config --verify --output \$HOME/backups/config" || warn "config backup failed (continuing)"

# Onboarding reruns use --auth-choice skip, which skips model registration. Make the provider's model
# list match the settings before the patch below points agents at PRIMARY_MODEL / PDF_MODEL.
models_register

log "Config patch (dry run, then apply)"
oc "config patch --file '$stage/openclaw.patch.json5' --dry-run"
oc "config patch --file '$stage/openclaw.patch.json5'"
oc "config validate"

if [[ "${ENABLE_ELEVATED:-0}" == "1" ]]; then
  warn "ENABLE_ELEVATED=1: applying tools.elevated.allowFrom.webchat=[\"*\"] (security audit: CRITICAL by design; see RUNBOOK)"
  oc "config patch --file '$stage/elevated.patch.json5'"
fi

log "Restarting the Gateway"
as_user "$OC_USER" "systemctl --user restart openclaw-gateway.service"
for _ in $(seq 1 30); do oc "gateway status --require-rpc" >/dev/null 2>&1 && break; sleep 2; done
oc "gateway status --deep --require-rpc"

log "Gateway host approvals: allowlist + ask always + deny on no answer"
oc "approvals set --gateway --file '$stage/approvals-gateway.json5'"
oc "approvals get --gateway"

log "Drift policy (bundled Policy plugin)"
install -m 600 -o "$OC_USER" -g "$OC_USER" "$stage/policy.jsonc" "$home/workspace/policy.jsonc"
# Enabling an already-enabled plugin makes the Gateway swap in a new plugin generation, which waits for
# any agent turn (for example an open Control UI session) that holds the old one and fails after 60 s.
# So only enable it the first time.
if [[ "$(oc 'config get plugins.entries.policy.enabled' 2>/dev/null | tail -1 || true)" == true ]]; then
  ok "policy plugin already enabled"
else
  oc "plugins enable policy"
fi
as_user "$OC_USER" "openclaw config patch --stdin" <<'EOF'
{ plugins: { entries: { policy: { enabled: true, config: { enabled: true, path: "policy.jsonc", workspaceRepairs: false } } } } }
EOF
as_user "$OC_USER" "systemctl --user restart openclaw-gateway.service"; sleep 8
check="$(as_user "$OC_USER" "openclaw policy check --agent main --json" 2>/dev/null || true)"
okv="$(jq -r '.ok' <<<"$check" 2>/dev/null || echo false)"
# A config change or an upgrade changes the attestation, so the old accepted hashes stop matching and the
# check fails on that alone. If the hash mismatch is the only finding, drop the stale locks and check again;
# the lock is re-applied below. Any other finding still stops the script.
if [[ "$okv" != "true" ]] && policy_only_stale_hashes "$check"; then
  warn "accepted policy hashes are stale (config change or upgrade); clearing them and checking again. Old attestation: $(oc 'config get plugins.entries.policy.config.expectedAttestationHash' 2>/dev/null | tail -1 | tr -d '"')"
  as_user "$OC_USER" "openclaw config unset plugins.entries.policy.config.expectedHash" || true
  as_user "$OC_USER" "openclaw config unset plugins.entries.policy.config.expectedAttestationHash" || true
  check="$(as_user "$OC_USER" "openclaw policy check --agent main --json" 2>/dev/null || true)"
  okv="$(jq -r '.ok' <<<"$check" 2>/dev/null || echo false)"
fi
if [[ "$okv" == "true" ]]; then
  ph="$(jq -r '.attestation.policy.hash' <<<"$check")"; ah="$(jq -r '.attestation.attestationHash' <<<"$check")"
  as_user "$OC_USER" "openclaw config patch --stdin" <<EOF
{ plugins: { entries: { policy: { config: { expectedHash: "$ph", expectedAttestationHash: "$ah" } } } } }
EOF
  ok "policy clean; hash-locked policy=$ph attestation=$ah"
  as_user "$OC_USER" "openclaw policy watch --agent main --once --json" >/dev/null && ok "policy watch: no drift" \
    || warn "policy watch reports drift right after locking — rerun 'openclaw policy check --agent main --json' and re-lock"
else
  warn "policy check not clean — fix findings, then rerun this script:"; echo "$check" | jq '.findings' 2>/dev/null || echo "$check"
fi

log "Gates"
for a in main builder reader lab; do echo "--- sandbox explain --agent $a"; oc "sandbox explain --agent $a" || true; done
oc "exec-policy show --verbose" || true
oc "security audit --deep" || true
warn "Expected audit findings: tools.elevated.allowFrom.webchat.wildcard (only if ENABLE_ELEVATED=1)."
warn "Fix anything else the audit reports before step 8 (exposure). 'openclaw security audit --fix' tightens permissions."

stamp 70-configure
