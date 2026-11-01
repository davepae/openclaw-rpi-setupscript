# lab-desktop: X11 desktop + OpenClaw node host with the experimental cua-computer fulfiller.
# Runs in the lab user's rootless Docker on the lab VM. Nothing worth stealing lives here.
FROM debian:trixie-slim
ARG OPENCLAW_VERSION
ARG NODE_VERSION
ENV DEBIAN_FRONTEND=noninteractive
# Linux CUA prerequisites from OpenClaw's computer-use docs, plus a browser, a VNC server for the
# Control UI Desktop panel (bound to the container's loopback only), and basic fonts.
RUN apt-get update && apt-get install -y --no-install-recommends \
      at-spi2-core dbus-x11 gir1.2-gtk-3.0 jq openbox python3-gi x11-utils xdotool xvfb \
      ca-certificates curl chromium x11vnc fonts-dejavu procps \
  && rm -rf /var/lib/apt/lists/*
RUN useradd --create-home --shell /bin/bash desktop \
  && install -d -o desktop -g desktop /opt/openclaw /home/desktop/.openclaw
USER desktop
# OpenClaw CLI + pinned Node into /opt/openclaw; state stays in /home/desktop/.openclaw (a volume).
RUN curl -fsSL --proto '=https' --tlsv1.2 https://openclaw.ai/install-cli.sh \
    | bash -s -- --prefix /opt/openclaw --version "${OPENCLAW_VERSION}" --node-version "${NODE_VERSION}" --no-onboard \
  && /opt/openclaw/bin/openclaw --version
ENV PATH=/opt/openclaw/bin:$PATH DISPLAY=:99 XDG_SESSION_TYPE=x11
COPY --chown=desktop:desktop approvals.json5 /opt/approvals.json5
COPY --chown=desktop:desktop --chmod=755 entrypoint.sh session.sh /opt/
WORKDIR /home/desktop
ENTRYPOINT ["/opt/entrypoint.sh"]
