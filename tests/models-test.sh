#!/usr/bin/env bash
# shellcheck disable=SC2034  # the settings below are read by the sourced lib/models.sh
# Unit tests for lib/models.sh with a stubbed oc(). Runs anywhere with bash and jq; touches no
# OpenClaw install. Usage: tests/models-test.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
warn() { printf 'warn: %s\n' "$*" >&2; }
die()  { printf 'die: %s\n' "$*" >&2; exit 1; }   # like lib/common.sh: callers run inside a subshell
ok()   { :; }
log()  { :; }
# shellcheck source=../lib/models.sh
source "$here/../lib/models.sh"

pass=0; fail=0
check() { # check "name" expected actual
  if [[ "$2" == "$3" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$1" "$2" "$3"; fi
}
succeeds() { if ( "${@:2}" ) >/dev/null 2>&1; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $1 (expected success)"; fi; }
fails()    { if ( "${@:2}" ) >/dev/null 2>&1; then fail=$((fail + 1)); echo "FAIL $1 (expected failure)"; else pass=$((pass + 1)); fi; }

AUTH_CHOICE=custom; CUSTOM_PROVIDER_ID=strata; CUSTOM_MODEL_ID=qwen-b; CUSTOM_IMAGE_INPUT=0
CUSTOM_CONTEXT_WINDOW=131072; PRIMARY_MODEL=strata/qwen-b; PDF_MODEL=other/vision

# --- pure helpers
check "local id, prefixed"        "qwen-b"         "$(model_local_id strata strata/qwen-b)"
check "local id, bare"            "qwen-b"         "$(model_local_id strata qwen-b)"
check "local id keeps inner slash" "vendor/model"  "$(model_local_id openrouter openrouter/vendor/model)"
check "bare id with slash"        "vendor/model"   "$(model_local_id openrouter vendor/model)"
succeeds "on provider"     model_on_provider strata strata/x
fails    "off provider"    model_on_provider strata other/x
fails    "prefix must be a whole segment" model_on_provider strata stratagem/x

check "required ids: custom + on-provider refs, deduped, off-provider skipped" \
  "qwen-b" "$(models_required_ids strata/qwen-b other/vision | paste -sd, -)"
check "required ids: PDF on provider adds a second id" \
  "qwen-b,vis" "$(models_required_ids strata/qwen-b strata/vis | paste -sd, -)"
CUSTOM_MODEL_ID=strata/qwen-b
check "required ids: CUSTOM_MODEL_ID with prefix normalizes" \
  "qwen-b" "$(models_required_ids strata/qwen-b | paste -sd, -)"
CUSTOM_MODEL_ID=qwen-b

# --- merge
old='[{"id":"qwen-a","name":"qwen-a","contextWindow":128000,"input":["text"],"maxTokens":8000}]'
new="$(models_merge "$old")"
check "merge keeps old entry"        "qwen-a"  "$(jq -r '.[0].id' <<<"$new")"
check "merge keeps old fields"       "8000"    "$(jq -r '.[0].maxTokens' <<<"$new")"
check "merge adds the new model"     "qwen-b"  "$(jq -r '.[1].id' <<<"$new")"
check "new entry gets the setting"   "131072"  "$(jq -r '.[1].contextWindow' <<<"$new")"
check "new entry is text-only"       '["text"]' "$(jq -c '.[1].input' <<<"$new")"
check "merge is idempotent"          "$new"    "$(models_merge "$new")"
fix='[{"id":"qwen-b","name":"qwen-b","contextWindow":128000,"reasoning":true}]'
fixed="$(models_merge "$fix")"
check "existing entry: window corrected" "131072" "$(jq -r '.[0].contextWindow' <<<"$fixed")"
check "existing entry: other fields kept" "true"  "$(jq -r '.[0].reasoning' <<<"$fixed")"
check "merge into empty list"        "1"       "$(models_merge '[]' | jq 'length')"
CUSTOM_IMAGE_INPUT=1
check "vision flag adds image input" '["text","image"]' "$(models_merge '[]' | jq -c '.[0].input')"
CUSTOM_IMAGE_INPUT=0
CUSTOM_CONTEXT_WINDOW=""
fails    "new model without a window is an error" models_merge '[]'
check "existing model without a setting is untouched" "$fix" "$(models_merge "$fix")"
CUSTOM_CONTEXT_WINDOW=131072

# --- oc_json drops banner lines, models_check, context check (oc stubbed)
FIXTURE='[{"id":"qwen-b","contextWindow":131072}]'
oc() { # stub: a banner line, then the fixture
  case "$1" in
    "config get models.providers.strata.models --json") printf 'OpenClaw 2026.11.5 banner\n%s\n' "$FIXTURE" ;;
    "models auth list") printf '%s\n' "$AUTH_OUT" ;;
    *) return 1 ;;
  esac
}
check "oc_json strips the banner"    "$FIXTURE" "$(oc_json 'config get models.providers.strata.models --json')"
check "registered json"              "$FIXTURE" "$(models_registered_json)"
succeeds "check passes when registered"       models_check strata/qwen-b other/vision
fails    "check fails for an unregistered PDF model on the provider" models_check strata/qwen-b strata/vis
FIXTURE='[{"id":"qwen-a","contextWindow":128000}]'
fails    "check fails when the primary is missing (the reported drift)" models_check strata/qwen-b
fails    "context check fails on 128000 vs 131072" models_context_check
FIXTURE='[{"id":"qwen-b","contextWindow":131072}]'
succeeds "context check passes"               models_context_check
CUSTOM_CONTEXT_WINDOW=""
succeeds "context check skipped when unset"   models_context_check
CUSTOM_CONTEXT_WINDOW=131072
FIXTURE='not json at all'
check "unreadable config is treated as empty" "[]" "$(models_registered_json)"
AUTH_CHOICE=anthropic
succeeds "checks skip for non-custom auth"    models_check strata/qwen-b
AUTH_CHOICE=custom

# --- inactive auth profiles
AUTH_OUT=$'strata:default  api_key  active\nstrata:setup-3f2a9c1e-1111-2222-3333-444455556666  api_key  setup_inactive'
check "inactive profile reported" "1" "$(auth_inactive_profiles | wc -l | tr -d ' ')"
AUTH_OUT='strata:default  api_key  active'
check "no inactive profile"       "0" "$(auth_inactive_profiles | wc -l | tr -d ' ')"

# --- models_register end to end (as_user stubbed: records calls, applies the patch to FIXTURE)
OC_USER=openclaw_user; CALLS=""; PROVIDER_JSON='{"baseUrl":"http://x","models":[]}'
as_user() { # as_user <user> <command>
  local body; body="$(cat)"; CALLS+="$2"$'\n'
  if [[ "$2" == *"config patch --stdin" && "$2" != *"--dry-run"* ]]; then
    FIXTURE="$(jq -c '.models.providers.strata.models' <<<"$(printf '%s' "$body" | sed -E 's/([{,] *)([A-Za-z]+):/\1"\2":/g')")"
  fi
}
oc() {
  case "$1" in
    "config get models.providers.strata.models --json") printf '%s\n' "$FIXTURE" ;;
    "config get models.providers.strata --json") printf '%s\n' "$PROVIDER_JSON" ;;
    *) return 1 ;;
  esac
}
FIXTURE='[{"id":"qwen-a","contextWindow":128000}]'; PRIMARY_MODEL=strata/qwen-b; PDF_MODEL=other/vision; CALLS=""
succeeds "register fixes the reported drift" models_register
models_register >/dev/null 2>&1   # run once more in this shell so FIXTURE and CALLS are updated here
check "after register: both models listed" "qwen-a,qwen-b" "$(jq -r 'map(.id)|join(",")' <<<"$FIXTURE")"
check "after register: window set" "131072" "$(jq -r '.[]|select(.id=="qwen-b").contextWindow' <<<"$FIXTURE")"
check "dry run comes before the apply" "1" "$(grep -c -- '--dry-run' <<<"$CALLS")"
CALLS=""; models_register >/dev/null 2>&1
check "second run changes nothing"  "0" "$(grep -c 'config patch' <<<"$CALLS")"
PROVIDER_JSON=''
fails "register refuses when the provider is missing" models_register
PROVIDER_JSON='{"baseUrl":"http://x"}'; FIXTURE='[]'; PDF_MODEL=strata/vis
fails "register stops when PDF_MODEL is on the provider but unregistered" models_register

printf '%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
