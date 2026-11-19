#!/usr/bin/env bash
# Look at a newer OpenClaw release and, only with --apply, move the pin to it.
#
#   pi/bump-version.sh                    report on npm's `latest` against your pin (changes nothing)
#   pi/bump-version.sh --to 2026.11.6     report on that exact version
#   pi/bump-version.sh --channel beta     use another npm dist-tag (beta, extended-stable)
#   pi/bump-version.sh --apply            also write OPENCLAW_VERSION into config/settings.env
#   pi/bump-version.sh --file PATH        read and write this settings file instead
#   pi/bump-version.sh --apply --force    apply even with warnings (older version, Node mismatch)
#
# The pin only affects fresh installs and rebuilds (pi/50, lab/20, lab/30 and the pi/60 image tag);
# it does not change the running Gateway. The report covers the two things that have broken a bump
# before: the release's Node "engines" range against NODE_VERSION, and what changed in
# Dockerfile.common, which pi/60-images.sh builds from the pinned tag. Release notes still need a
# human read. Needs curl, jq and diff; not root; touches no OpenClaw install.
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/versions.sh
source "$here/../lib/versions.sh"

c_info=$'\e[1;34m'; c_ok=$'\e[1;32m'; c_warn=$'\e[1;33m'; c_err=$'\e[1;31m'; c_off=$'\e[0m'
log()  { printf '%s==>%s %s\n' "$c_info" "$c_off" "$*"; }
ok()   { printf '%s ok%s %s\n'  "$c_ok"   "$c_off" "$*"; }
warn() { printf '%s !!%s %s\n'  "$c_warn" "$c_off" "$*" >&2; }
die()  { printf '%sERR%s %s\n'  "$c_err"  "$c_off" "$*" >&2; exit 1; }

apply=0; to=""; tag="latest"; file="$here/../config/settings.env"; force=0
while (( $# )); do
  case "$1" in
    --apply) apply=1 ;;
    --force) force=1 ;;
    --to) to="${2:-}"; [[ -n "$to" ]] || die "--to needs a version"; shift ;;
    --channel) tag="${2:-}"; [[ -n "$tag" ]] || die "--channel needs a dist-tag"; shift ;;
    --file) file="${2:-}"; [[ -n "$file" ]] || die "--file needs a path"; shift ;;
    -h|--help) sed -n '2,/^[^#]/{/^[^#]/!p}' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
  shift
done

command -v curl >/dev/null && command -v jq >/dev/null && command -v diff >/dev/null || die "needs curl, jq and diff"
[[ -f "$file" ]] || die "no settings file at $file (copy config/settings.env.example to config/settings.env, or pass --file)"
pin="$(settings_value "$file" OPENCLAW_VERSION)"; node="$(settings_value "$file" NODE_VERSION)"
[[ -n "$pin" ]] || die "OPENCLAW_VERSION not found in $file"

want="${to:-$tag}"
log "Looking up $want on npm"
doc="$(npm_doc "$want")" || true
target="$(jq -r '.version // empty' <<<"$doc" 2>/dev/null)"
[[ -n "$target" ]] || die "npm has no OpenClaw '$want' (offline, a typo, or an unknown dist-tag)"
engines="$(jq -r '.engines.node // empty' <<<"$doc" 2>/dev/null)"

printf '\n  pinned in %s : %s\n  target (%s) : %s\n\n' "$(basename "$file")" "$pin" "$want" "$target"

cmp="$(ver_cmp "$target" "$pin")"
blocked=0
case "$cmp" in
  0)  ok "the pin already matches $target"; exit 0 ;;
  -1) warn "$target is OLDER than the pin ($pin)"; blocked=1 ;;
esac

log "Node engines"
if [[ -z "$engines" ]]; then
  warn "the release lists no engines.node; check Node by hand"
elif [[ -z "$node" ]]; then
  warn "NODE_VERSION not found in $file; release needs: $engines"
else
  semver_satisfies "$node" "$engines"; rc=$?
  case "$rc" in
    0) ok "NODE_VERSION $node satisfies: $engines" ;;
    1) warn "NODE_VERSION $node does NOT satisfy: $engines. Set NODE_VERSION to a version that does before installing"; blocked=1 ;;
    *) warn "could not evaluate the range '$engines' here; compare it with NODE_VERSION $node by hand" ;;
  esac
fi

log "Dockerfile.common, v$pin -> v$target (pi/60-images.sh builds this from the pinned tag)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
if dockerfile_common "$pin" >"$tmp/old" && dockerfile_common "$target" >"$tmp/new"; then
  if diff -u --label "v$pin" --label "v$target" "$tmp/old" "$tmp/new" >"$tmp/diff"; then
    ok "unchanged"
  else
    n="$(grep -c -E '^[+-][^+-]' "$tmp/diff" || true)"
    warn "$n changed line(s). Read them for the base image, build args and stages; pi/60 passes BASE_IMAGE itself"
    head -80 "$tmp/diff"
    (( $(wc -l <"$tmp/diff") > 80 )) && echo "   ... (diff truncated; the full file is at $OC_RAW/v$target/scripts/docker/sandbox/Dockerfile.common)"
  fi
else
  warn "could not fetch Dockerfile.common for v$pin or v$target (no such tag, or offline); compare them by hand"
fi

echo
if (( ! apply )); then
  again=""
  [[ -n "$to" ]] && again=" --to $to"
  [[ -z "$to" && "$tag" != latest ]] && again=" --channel $tag"
  log "Report only. To move the pin: pi/bump-version.sh --apply$again"
  exit 0
fi
if (( blocked && ! force )); then
  die "not applying: see the warnings above (--force overrides, at your own risk)"
fi

# Rewrite the one line in place (keeps the file's owner and mode), then check the result.
new="$(sed -E "s/^(OPENCLAW_VERSION=)\"[^\"]*\"/\\1\"$target\"/" "$file")"
[[ "$(grep -c '^OPENCLAW_VERSION=' <<<"$new")" == 1 && "$(grep '^OPENCLAW_VERSION=' <<<"$new")" == OPENCLAW_VERSION=\"$target\"* ]] \
  || die "could not rewrite OPENCLAW_VERSION in $file (is it written as OPENCLAW_VERSION=\"...\"?); no change made"
printf '%s\n' "$new" >"$file"
ok "OPENCLAW_VERSION is now $target in $file"

cat <<EOF

Next, in this order (nothing below has been run):
  Pi, rebuild path:     sudo ./install-pi.sh --from 50      (installs $target, rebuilds the images)
  Pi, already updated:  skip that (for example if you used the Control UI's update button)
  Pi, either way:       sudo pi/70-configure.sh             (re-registers models, re-locks the policy hashes)
                        sudo pi/99-verify.sh
  Lab VM:               update in place (runbook, phase 8, "Updating the lab node in place"),
                        or rerun lab/20-exec-node.sh and lab/30-desktop-node.sh
  Also:                 set the same version in the lab VM's own settings.env; the comment beside
                        NODE_VERSION in config/settings.env.example names the engines range of the
                        previous release and is not changed by this script.
EOF
