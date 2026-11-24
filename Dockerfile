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
#   The bridge source is cloned from the official repo at the exact commit the
#   v0.4.0-rc.5 release was built from (source-commit.txt in the local install):
#   commit 2d026ef89745c5820ad5b50406653bdb8a781df4, release
#   "three-versions-20261029". The local file-support patch was applied AFTER
#   install as file modifications, so this commit is the CLEAN official rc.5
#   (inbound media yes, inbound files no). No local patched files are used.
#
# Persistence caveat (read README.md):
#   DeployVera documents NO persistent volume for a Dockerfile app on the free
#   plan. Bridge state (WeChat login + SQLite) lives in the writable container
#   layer and MAY BE LOST when the container is replaced (redeploy/restart).
#   The test proves whether it survives; re-login via the /qr page is the
#   recovery path.

FROM node:24-slim

# git (clone the bridge source) + ca-certificates (TLS) + curl (health checks).
# No native build tools needed: the bridge deps (qrcode, silk-wasm, undici)
# are pure JS / WASM, no compiled addons.
RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Clone the official repo and check out the exact rc.5 commit, then install
# production dependencies. Verify the version so a wrong checkout fails loudly.
RUN git clone https://github.com/xianjia95-oss/muse-wechat-clawbot.git /app/muse-link \
    && git -C /app/muse-link checkout 2d026ef89745c5820ad5b50406653bdb8a781df4 \
    && git -C /app/muse-link rev-parse HEAD \
    && grep -q '"version": "0.4.0-rc.5"' /app/muse-link/package.json \
    && cd /app/muse-link && npm ci --omit=dev --no-fund --no-audit \
    && npm cache clean --force \
    && rm -rf /app/muse-link/.git

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
