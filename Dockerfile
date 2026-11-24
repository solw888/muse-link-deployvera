# Muse Link WeChat bridge (official v0.4.0-rc.5) on DeployVera free plan.
#
# What this is:
#   A Docker image that runs the official Muse Link bridge (Meta Muse <-> WeChat)
#   on DeployVera's permanent free plan (1 app, 0.5 vCPU, 512 MB RAM, 2 GB disk).
#
# Why a proxy is required:
#   The bridge binds ONLY to loopback by design (config validation rejects any
#   non-loopback listen host: see src/config.mjs). DeployVera requires the app
#   to listen on 0.0.0.0:$PORT. So a tiny proxy (proxy.mjs, Node built-ins only)
#   listens on 0.0.0.0:$PORT and reverse-proxies the bridge API, serves the
#   WeChat login QR image, and answers health checks.
#
# Source:
#   The bridge source is the official v0.4.0-rc.5 clean-install zip from the
#   upstream repo (release "three-versions-20261029"):
#   packages/muse-link-v0.4.0-rc.5-clean-install.zip. The upstream repo ships
#   the bridge as a zip, not as source in git (the old commit
#   2d026ef89745c5820ad5b50406653bdb8a781df4 no longer exists upstream — the
#   repo now has a single commit ab04fe39). This is the CLEAN official rc.5
#   (inbound media yes, inbound files no). The local file-support patch was
#   applied AFTER install as file modifications, so no local patched files
#   are used.
#
# Persistence caveat (read README.md):
#   DeployVera documents NO persistent volume for a Dockerfile app on the free
#   plan. Bridge state (WeChat login + SQLite) lives in the writable container
#   layer and MAY BE LOST when the container is replaced (redeploy/restart).
#   The test proves whether it survives; re-login via the /qr page is the
#   recovery path.

FROM node:24-slim

# unzip (extract the bridge zip) + ca-certificates (TLS) + curl (health checks + download).
# No native build tools needed: the bridge deps (qrcode, silk-wasm, undici)
# are pure JS / WASM, no compiled addons.
RUN apt-get update \
    && apt-get install -y --no-install-recommends unzip ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Download the official rc.5 clean-install zip and extract it, then install
# production dependencies. Verify the version so a wrong file fails loudly.
# The zip contains package-lock.json, so "npm ci" works.
RUN curl -fsSL -o /tmp/muse-link.zip https://raw.githubusercontent.com/xianjia95-oss/muse-wechat-clawbot/three-versions-20261029/packages/muse-link-v0.4.0-rc.5-clean-install.zip \
    && mkdir -p /app/muse-link \
    && unzip -q /tmp/muse-link.zip -d /app/muse-link \
    && rm -f /tmp/muse-link.zip \
    && grep -q '"version": "0.4.0-rc.5"' /app/muse-link/package.json \
    && cd /app/muse-link && npm ci --omit=dev --no-fund --no-audit \
    && npm cache clean --force

# Runtime data lives under /data (writable container layer; see persistence note).
# /data itself is world-writable so the container works whether it runs as root
# or as an arbitrary UID; the entrypoint creates the subdirs with 0700.
RUN mkdir -p /data && chmod 0777 /data

# Proxy (public front door) + entrypoint (orchestrates config -> login -> daemon).
COPY proxy.mjs entrypoint.sh /app/
RUN chmod 0755 /app/entrypoint.sh

ENV NODE_ENV=production
ENV HOME=/data
ENV MUSE_LINK_HOME=/app/muse-link
ENV MUSE_LINK_CONFIG=/data/config/config.json
ENV MUSE_LINK_STATE_DIR=/data/state
ENV MUSE_LINK_QR_DIR=/data/qr
ENV MUSE_LINK_MEDIA_ROOT=/data/workspace
# PORT is set by DeployVera at runtime; 3000 is only a local fallback.
# Enter the same port (3000) in the DeployVera panel when creating the app.
ENV PORT=3000

EXPOSE 3000

CMD ["/app/entrypoint.sh"]
