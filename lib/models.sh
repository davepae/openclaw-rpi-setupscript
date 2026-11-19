#!/usr/bin/env bash
# Model registration helpers for the custom provider (AUTH_CHOICE=custom).
# Sourced by pi/70-configure.sh and pi/99-verify.sh after lib/common.sh. Callers define oc(), which
# runs `openclaw <args>` as the agent user. The pure helpers (no openclaw calls) are unit-tested
# in tests/models-test.sh.
#
# Why this exists: onboarding is the only thing that registers a model on the provider, and reruns
# use --auth-choice skip (see pi/50-openclaw.sh), so a changed CUSTOM_MODEL_ID was never registered
# while pi/70 still pointed agents.defaults.model.primary at it. Refs are "<provider>/<local id>";
# local ids can contain slashes themselves (OpenRouter's "vendor/model").

# model_local_id <provider> <ref>: strip one leading "<provider>/" if present. Accepts either form.
model_local_id() { local p="$1" r="$2"; printf '%s\n' "${r#"$p"/}"; }

# model_on_provider <provider> <ref>: true when the ref names a model on that provider.
model_on_provider() { [[ "$2" == "$1"/* ]]; }

# models_required_ids <ref>...: provider-local ids the custom provider must define, one per line.
# CUSTOM_MODEL_ID is always required and may be given with or without the provider prefix.
# Other refs count only when they are on the custom provider; refs on other providers are not ours.
models_required_ids() {
  local p="$CUSTOM_PROVIDER_ID" ref
  {
    model_local_id "$p" "$CUSTOM_MODEL_ID"
    for ref in "$@"; do
      if model_on_provider "$p" "$ref"; then model_local_id "$p" "$ref"; fi
    done
  } | awk 'NF && !seen[$0]++'
}

# oc_json <openclaw args>: run a command and print only its JSON document, dropping any banner or
# log lines before the first line that starts with [ or {.
oc_json() { oc "$1" 2>/dev/null | awk 'f || /^[[{]/ { f = 1; print }'; }

# models_registered_json: the provider's models array as compact JSON ([] when absent or unreadable).
models_registered_json() {
  local out
  out="$(oc_json "config get models.providers.$CUSTOM_PROVIDER_ID.models --json" \
    | jq -c 'if type == "array" then . else [] end' 2>/dev/null || true)"
  printf '%s\n' "${out:-[]}"
}

# models_merge <registered-array-json>: print the array to write back. Keeps every existing entry
# and field, sets contextWindow on the CUSTOM_MODEL_ID entry when CUSTOM_CONTEXT_WINDOW is set, and
# adds CUSTOM_MODEL_ID if it is missing. Fails (jq error) when a new entry would have no context
# window. New entries are text-only unless CUSTOM_IMAGE_INPUT=1 and are not marked as reasoning
# models; edit them afterwards if the model needs that.
models_merge() {
  local custom; custom="$(model_local_id "$CUSTOM_PROVIDER_ID" "$CUSTOM_MODEL_ID")"
  jq -c --arg custom "$custom" --arg ctx "${CUSTOM_CONTEXT_WINDOW:-}" --arg img "${CUSTOM_IMAGE_INPUT:-0}" '
    ($ctx | if . == "" then null else tonumber end) as $c
    | map(if .id == $custom and $c != null then .contextWindow = $c else . end) as $have
    | if any($have[]; .id == $custom) then $have
      elif $c == null then error("CUSTOM_CONTEXT_WINDOW is required to register a new model")
      else $have + [{
        id: $custom, name: $custom, reasoning: false,
        input: (if $img == "1" then ["text", "image"] else ["text"] end),
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
        contextWindow: $c }]
      end' <<<"$1"
}

# models_check <ref>...: succeed when every required id is registered on the provider. Prints one
# warning per missing id. Only covers refs on the custom provider.
models_check() {
  [[ "$AUTH_CHOICE" == custom ]] || return 0
  local reg id bad=0; reg="$(models_registered_json)"
  while read -r id; do
    [[ -n "$id" ]] || continue
    if ! jq -e --arg id "$id" 'any(.[]; .id == $id)' <<<"$reg" >/dev/null 2>&1; then
      warn "model '$id' is not registered on provider '$CUSTOM_PROVIDER_ID' (agents would use an unregistered model)"
      bad=1
    fi
  done < <(models_required_ids "$@")
  return "$bad"
}

# models_context_check: the registered contextWindow of CUSTOM_MODEL_ID equals CUSTOM_CONTEXT_WINDOW.
# Succeeds when the setting is empty (nothing to compare).
models_context_check() {
  [[ "$AUTH_CHOICE" == custom && -n "${CUSTOM_CONTEXT_WINDOW:-}" ]] || return 0
  local id; id="$(model_local_id "$CUSTOM_PROVIDER_ID" "$CUSTOM_MODEL_ID")"
  jq -e --arg id "$id" --argjson c "$CUSTOM_CONTEXT_WINDOW" 'any(.[]; .id == $id and .contextWindow == $c)' \
    <<<"$(models_registered_json)" >/dev/null 2>&1
}

# models_register: make the provider's model list match the settings, then verify the result.
# Dry-runs the patch first. Does nothing unless AUTH_CHOICE=custom.
models_register() {
  [[ "$AUTH_CHOICE" == custom ]] || return 0
  local prov reg merged patch
  prov="$(oc_json "config get models.providers.$CUSTOM_PROVIDER_ID --json" | jq -c 'if type == "object" then . else empty end' 2>/dev/null || true)"
  [[ -n "$prov" ]] || die "provider '$CUSTOM_PROVIDER_ID' is not in the config; run pi/50-openclaw.sh (onboarding creates the provider) before this script"
  reg="$(models_registered_json)"
  merged="$(models_merge "$reg")" || die "could not build the model list; if the message above says CUSTOM_CONTEXT_WINDOW, set it in config/settings.env"
  if [[ "$merged" == "$reg" ]]; then
    ok "provider '$CUSTOM_PROVIDER_ID' already lists the configured model(s)"
  else
    patch="{ models: { providers: { \"$CUSTOM_PROVIDER_ID\": { models: $merged } } } }"
    log "Registering models on provider '$CUSTOM_PROVIDER_ID'"
    as_user "$OC_USER" "openclaw config patch --stdin --dry-run" <<<"$patch"
    as_user "$OC_USER" "openclaw config patch --stdin" <<<"$patch"
  fi
  models_check "$PRIMARY_MODEL" "$PDF_MODEL" \
    || die "PRIMARY_MODEL or PDF_MODEL is on provider '$CUSTOM_PROVIDER_ID' but not registered. Set CUSTOM_MODEL_ID to it, or add it to models.providers.$CUSTOM_PROVIDER_ID.models by hand"
  models_context_check || die "registered contextWindow for $CUSTOM_MODEL_ID does not match CUSTOM_CONTEXT_WINDOW=$CUSTOM_CONTEXT_WINDOW"
}

# auth_inactive_profiles: print any auth profile lines left in a setup_inactive state (or named
# "<provider>:setup-<uuid>") by an earlier onboarding rerun. Reports only; never deletes.
auth_inactive_profiles() {
  oc "models auth list" 2>&1 | grep -iE 'setup_inactive|:setup-[0-9a-f]{8}-' || true
}
