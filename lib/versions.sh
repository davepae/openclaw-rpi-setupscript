#!/usr/bin/env bash
# Version helpers for pi/bump-version.sh and pi/99-verify.sh. Sourced, never run directly.
# Plain functions: no settings file, no root, and the network only through the two URL bases below,
# which tests point at file:// fixtures.

OC_REGISTRY="${OC_REGISTRY:-https://registry.npmjs.org/openclaw}"
OC_RAW="${OC_RAW:-https://raw.githubusercontent.com/openclaw/openclaw}"

# ver_extract <text>: the first OpenClaw-style version in the text (2026.11.5 or 2026.11.10-beta.1).
ver_extract() { grep -oE '[0-9]{4}\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?' <<<"$1" | head -1 || true; }

# ver_cmp <a> <b>: prints -1, 0 or 1. Dotted parts compare as numbers, missing parts count as 0,
# and a release outranks its own prerelease (2026.11.10 > 2026.11.10-beta.1).
ver_cmp() {
  local a="$1" b="$2" ac bc ap="" bp=""
  ac="${a%%-*}"; bc="${b%%-*}"
  [[ "$a" == *-* ]] && ap="${a#*-}"
  [[ "$b" == *-* ]] && bp="${b#*-}"
  local -a x y
  IFS=. read -ra x <<<"$ac"
  IFS=. read -ra y <<<"$bc"
  local i n=${#x[@]} p q
  (( ${#y[@]} > n )) && n=${#y[@]}
  for (( i = 0; i < n; i++ )); do
    p=$(( 10#${x[i]:-0} )); q=$(( 10#${y[i]:-0} ))
    if (( p < q )); then echo -1; return; fi
    if (( p > q )); then echo 1; return; fi
  done
  if [[ -z "$ap" && -z "$bp" ]]; then echo 0
  elif [[ -z "$ap" ]]; then echo 1
  elif [[ -z "$bp" ]]; then echo -1
  elif [[ "$ap" == "$bp" ]]; then echo 0
  elif [[ "$(printf '%s\n%s\n' "$ap" "$bp" | sort -V | head -1)" == "$ap" ]]; then echo -1
  else echo 1
  fi
}

# semver_satisfies <version> <range>: exit 0 if it satisfies, 1 if not, 2 if the range uses syntax this
# function does not evaluate (caret, tilde, x-ranges, hyphen ranges, partial "=" versions). It never
# guesses: callers should tell the person to check by hand on 2. Handles what package "engines" fields
# use here: space-separated comparators (>=, >, <=, <, =) joined by AND, groups joined by ||.
semver_satisfies() {
  local v="$1" range="$2" clause tok op rv any=1 unsupported=0 clause_ok
  [[ -n "$v" && -n "$range" ]] || return 2
  local -a clauses
  IFS='|' read -ra clauses <<<"${range//||/|}"
  for clause in "${clauses[@]}"; do
    clause_ok=1
    # shellcheck disable=SC2086  # a clause is a space-separated list of comparators on purpose
    for tok in $clause; do
      case "$tok" in
        '>='*) op=">="; rv="${tok#>=}" ;;
        '<='*) op="<="; rv="${tok#<=}" ;;
        '>'*)  op=">";  rv="${tok#>}" ;;
        '<'*)  op="<";  rv="${tok#<}" ;;
        '='*)  op="=";  rv="${tok#=}" ;;
        *)     op="=";  rv="$tok" ;;
      esac
      if [[ ! "$rv" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then unsupported=1; continue; fi
      # a partial version with = (or none) is an x-range in npm ("=25" means 25.x.x); don't guess
      if [[ "$op" == "=" && ! "$rv" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then unsupported=1; continue; fi
      case "$op:$(ver_cmp "$v" "$rv")" in
        '>=:1'|'>=:0'|'>:1'|'<=:-1'|'<=:0'|'<:-1'|'=:0') ;;
        *) clause_ok=0 ;;
      esac
    done
    (( clause_ok )) && any=0
  done
  (( unsupported )) && return 2
  return "$any"
}

# npm_doc <version-or-dist-tag>: the registry's JSON document for it; empty (and non-zero) on failure.
npm_doc() { curl -fsSL -m "${OC_NET_TIMEOUT:-10}" "$OC_REGISTRY/$1" 2>/dev/null; }

# dockerfile_common <version>: OpenClaw's sandbox Dockerfile.common at that release tag.
dockerfile_common() { curl -fsSL -m "${OC_NET_TIMEOUT:-20}" "$OC_RAW/v$1/scripts/docker/sandbox/Dockerfile.common" 2>/dev/null; }

# node_versions_tsv <json from 'nodes list --json'>: one "name<TAB>version" line per node that is connected
# right now. The version is coreVersion, or the plain version field on linux, darwin and win32 nodes when
# coreVersion is empty (the CLI's own `nodes status` falls back the same way; seen on a real lab-exec node,
# 2026-11-19: coreVersion null, version "2026.11.5"). A disconnected node is skipped: its last-known
# version can be stale. Phone and other non-desktop nodes report a UI version in `version`, so they give "".
node_versions_tsv() {
  jq -r '.paired[]? | select(.connected == true)
    | [ (.displayName // .nodeId // "?"),
        ( .coreVersion
          // ( ((.platform // "") | ascii_downcase) as $p
               | if ($p == "linux" or $p == "darwin" or $p == "win32" or $p == "windows") then .version else null end )
          // "" ) ]
    | @tsv' <<<"$1" 2>/dev/null
}

# settings_value <file> <KEY>: the value of KEY="..." in a settings file, read without sourcing it.
settings_value() { sed -n -E "s/^$2=\"?([^\"# ]*)\"?.*/\\1/p" "$1" | head -1; }
