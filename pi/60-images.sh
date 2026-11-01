#!/usr/bin/env bash
# Phase 6 — build the sandbox images in openclaw_user's rootless Docker.
#   openclaw-sandbox:trixie-slim         base (OpenClaw docs' inline Dockerfile)
#   openclaw-sandbox-common:trixie-slim  OpenClaw's Dockerfile.common from your installed tag
#   openclaw-sandbox-dev:trixie-slim     + toolchains and Office/PDF tools (images/Dockerfile.dev)
#   openclaw-sandbox-browser:*           optional, BUILD_BROWSER_IMAGE=1 (source checkout)
# Note: release tags up to v2026.10.9 still default to *:bookworm-slim and Dockerfile.common's
# BASE_IMAGE defaults to openclaw-sandbox:bookworm-slim, so BASE_IMAGE is passed explicitly here.
# Rerun weekly (the timer from 90-timers.sh calls this with --rebuild).
source "$(dirname "$0")/../lib/common.sh"
REBUILD=0; [[ "${1:-}" == "--rebuild" ]] && REBUILD=1

if [[ $EUID -eq 0 ]]; then
  # Re-exec as openclaw_user with a proper rootless Docker environment.
  install -d -m 755 -o "$OC_USER" -g "$OC_USER" "$(user_home "$OC_USER")/.cache/openclaw-images"
  rm -rf "$(user_home "$OC_USER")/.cache/openclaw-images/bundle"
  cp -r "$BUNDLE_DIR" "$(user_home "$OC_USER")/.cache/openclaw-images/bundle"
  chown -R "$OC_USER:$OC_USER" "$(user_home "$OC_USER")/.cache/openclaw-images/bundle"
  as_user "$OC_USER" "\$HOME/.cache/openclaw-images/bundle/pi/60-images.sh ${1:-}"
  stamp 60-images; exit 0
fi
[[ "$(id -un)" == "$OC_USER" ]] || die "run as root (sudo) or as $OC_USER"
export DOCKER_HOST="${DOCKER_HOST:-unix:///run/user/$(id -u)/docker.sock}"
docker info --format '{{.SecurityOptions}}' | grep -q rootless || die "not talking to rootless Docker ($DOCKER_HOST)"

tag="v${OPENCLAW_VERSION}"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
# --pull only for the base (debian:trixie-slim); later stages build FROM local images.
pull=(); nocache=(); (( REBUILD )) && { pull=(--pull); nocache=(--no-cache); }

log "Base image openclaw-sandbox:trixie-slim"
docker build "${pull[@]}" "${nocache[@]}" -t openclaw-sandbox:trixie-slim - <<'DOCKERFILE'
FROM debian:trixie-slim
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
  bash ca-certificates curl git jq python3 ripgrep \
  && rm -rf /var/lib/apt/lists/*
RUN useradd --create-home --shell /bin/bash sandbox
USER sandbox
WORKDIR /home/sandbox
CMD ["sleep", "infinity"]
DOCKERFILE

log "Common image from OpenClaw $tag (Dockerfile.common + package.json)"
raw="https://raw.githubusercontent.com/openclaw/openclaw/$tag"
mkdir -p "$work/common"
curl -fsSL "$raw/scripts/docker/sandbox/Dockerfile.common" -o "$work/common/Dockerfile.common"
curl -fsSL "$raw/package.json" -o "$work/common/package.json"
# INSTALL_BREW=0: Homebrew on Linux/arm64 is slow to build and not needed by this design.
( cd "$work/common" && docker build "${nocache[@]}" \
    --build-arg BASE_IMAGE=openclaw-sandbox:trixie-slim \
    --build-arg INSTALL_BREW=0 \
    -t openclaw-sandbox-common:trixie-slim -f Dockerfile.common . )

log "Dev image openclaw-sandbox-dev:trixie-slim"
docker build "${nocache[@]}" \
  --build-arg BASE=openclaw-sandbox-common:trixie-slim \
  -t openclaw-sandbox-dev:trixie-slim -f "$BUNDLE_DIR/images/Dockerfile.dev" "$BUNDLE_DIR/images"

if [[ "${BUILD_BROWSER_IMAGE:-0}" == "1" ]]; then
  log "Sandbox browser image from a $tag source checkout (flagged #4: arm64 + rootless untested)"
  git clone -q --depth 1 --branch "$tag" "$OPENCLAW_REPO" "$work/src"
  ( cd "$work/src" && bash scripts/sandbox-browser-setup.sh )
  docker image ls --format '{{.Repository}}:{{.Tag}}' | grep sandbox-browser
  warn "Set agents.defaults.sandbox.browser.image to the tag printed above before enabling the browser."
fi

log "Smoke tests"
ws="$work/ws"; mkdir -p "$ws"
docker run --rm --read-only --tmpfs /tmp --tmpfs /var/tmp --tmpfs /run --network none --cap-drop ALL \
  --user 0:0 -v "$ws:/workspace" -w /workspace \
  openclaw-sandbox-dev:trixie-slim bash -c '
    set -e; id; node --version; pnpm --version; python3 -c "import docx, openpyxl, pypdf, pptx; print(\"office libs ok\")"
    printf "a,b\n1,2\n" > t.csv && office --convert-to xlsx --outdir /workspace t.csv >/dev/null && ls -la t.xlsx
    pdftotext -v 2>&1 | head -1; pandoc --version | head -1'
owner="$(stat -c %U "$ws/t.xlsx")"
[[ "$owner" == "$(id -un)" ]] && ok "workspace write lands as $(id -un) on the host (flagged #2 settled)" \
  || die "workspace file owned by '$owner', expected $(id -un) — check sandbox user mapping"
docker image ls --format '{{.Repository}}:{{.Tag}}\t{{.Size}}' | grep openclaw-sandbox
docker image prune -f >/dev/null
ok "images ready"
