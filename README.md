# Muse Link bridge on DeployVera — test deploy

Test the official Muse Link WeChat bridge (v0.4.0-rc.5) on DeployVera's
permanent free plan. Preparation only: nothing here signs up, deploys, or
touches the running local bridge.

## Files

| File | Purpose |
| --- | --- |
| `Dockerfile` | Builds the image: Node 24, clones the official repo at the rc.5 commit, `npm ci`, copies the proxy + entrypoint. |
| `proxy.mjs` | Public front door on `0.0.0.0:$PORT`. Reverse-proxies the bridge API, serves the WeChat login QR (`/qr`, `/qr.png`), answers `/healthz` and `/`. Node built-ins only. |
| `entrypoint.sh` | Container startup: config from env token → proxy → WeChat login loop (QR via `/qr`) → bridge daemon → supervise both. |
| `.dockerignore` | Keeps `.git` out of the build context. |
| `README.md` | This file. |

## How it works

- The bridge binds **only** to loopback (`127.0.0.1:18791`) — its config
  validation rejects any other listen host. So the bridge can never satisfy
  DeployVera's `0.0.0.0:$PORT` requirement directly. The proxy is mandatory.
- The proxy listens on `0.0.0.0:$PORT` (PORT comes from DeployVera; default
  3000). It forwards `/v1/*` to the bridge, serves the login QR, and answers
  health checks. The bridge enforces its own Bearer `api_token` auth on
  `/v1/*` (only `/healthz` is unauthenticated).
- The bridge source is the **official clean rc.5**: the repo is cloned at
  commit `2d026ef89745c5820ad5b50406653bdb8a781df4` (the commit the v0.4.0-rc.5
  release `three-versions-20261029` was built from). The local file-support
  patch is **not** included — inbound files are not supported in this test,
  only text/image/video/voice as in stock rc.5.
- Node 24 is required (`engines: node >= 24`). No native modules, no ffmpeg:
  the voice codec is WASM (`silk-wasm`), all deps are pure JS / WASM.
- The container runs the bridge as its main workload (no systemd — the
  official `install.sh` needs systemd + root + a service unit, so it is
  **not** used here; the entrypoint replicates only the config + run steps).

## Deployment steps (what the user must do)

### 1. Create a GitHub repo for these files (BLOCKER — needs a GitHub account)

DeployVera deploys from a Git repository (GitHub, GitLab, or a public HTTPS
repo URL). The Dockerfile must sit at the **repo root** (subdirectory builds
may be disabled). The upstream Muse Link repo cannot host our Dockerfile.

- Create a **public** GitHub repo, e.g. `muse-link-deployvera`.
- Push these files to its default branch (e.g. `main`):
  `Dockerfile`, `proxy.mjs`, `entrypoint.sh`, `.dockerignore`, `README.md`.
- The bridge source itself is fetched by the Dockerfile at build time
  (git clone of the official repo at the rc.5 commit), so the repo only
  holds the deployment files — no bridge code, no tokens, no state.

> If the user has no GitHub account, a GitLab repo works the same way.
> There is no documented way to deploy to DeployVera without a Git repo
> (no direct Dockerfile upload). The MCP server also deploys from a Git repo.

### 2. Sign up for DeployVera (free plan, no card)

- Sign up with a verified email only. No card, no payment, no expiry.
- The free plan is 1 app, 0.5 vCPU, 512 MB RAM, 2 GB disk, no idle sleep.

### 3. Create the app in the DeployVera panel

- New application → choose the repo + branch from step 1 → build method
  **Dockerfile** → port **3000** → access mode **Public**.
- Environment variable (required):
  - `MUSE_LINK_API_TOKEN` = a fresh random token, 32–256 printable ASCII
    chars, no spaces. Generate one now (e.g. `openssl rand -hex 32` gives
    64 hex chars) and **keep it** — it is the password for the bridge API.
    Do NOT reuse the local bridge's token, and do NOT commit it to the repo.
    Set it only in the DeployVera panel (or via the MCP `set_env_vars`).
- Start the deployment and watch the build log. The build clones the repo,
  checks out the rc.5 commit, and runs `npm ci`.

### 4. Log in to WeChat (scan the QR)

- Once the app is running, open the DeployVera app URL + `/qr` in a browser.
- Scan the QR code with WeChat. The code refreshes every few minutes;
  refresh the page for a new one if it expires.
- The container logs also print the QR events. The entrypoint retries login
  (up to 6 attempts × 10 min) until the scan succeeds, then starts the daemon.
- If the phone demands a pairing verification code, the login prints a
  `verification_required` event with a `code_file` path. There is currently
  **no remote way to enter that code** (it needs a file write inside the
  container and the `login verify` command). If that happens, the login will
  time out and retry; flag it — a small proxy endpoint for code submission
  can be added if needed.

### 5. Verify the bridge is up

- Open the app URL `/` → status page (bridge up/down, WeChat logged in).
- Open `/healthz` → `{"alive":true,...}` when healthy.
- From a terminal, with the token from step 3:
  - `curl -s https://<app-address>/v1/status -H "Authorization: Bearer <token>"`
    → JSON with `"logged_in":true`.
  - `curl -s "https://<app-address>/v1/muse/tasks?limit=1&lease=30m&wait=5s" -H "Authorization: Bearer <token>"`
    → `{"tasks":[...]}` (empty array when no WeChat messages are waiting).
- Send the bridge a WeChat message from the user's phone, then claim it via
  `/v1/muse/tasks` and reply via `POST /v1/muse/replies` with the
  `event_id` + `lease_token` from the claim. See the local bridge's
  `docs/API.md` for the exact request shapes (same API, remote URL + token).

## Persistence — the open risk

DeployVera's docs say the writable container layer "may disappear when the
container is replaced", and that data on a "correctly mounted persistent
volume" survives redeployment. **But no documented way to mount a persistent
volume exists for a Dockerfile app on the free plan** (no panel setting, no
Dockerfile syntax; the only concrete persistent storage offered is managed
PostgreSQL, which the bridge does not use — it uses SQLite files).

Consequences for this test:
- The WeChat login + SQLite state live in `/data/state` + `/data/config`
  inside the container. They survive as long as the same container instance
  keeps running (the free plan has no idle sleep, so it should stay up).
- A **redeploy, restart, or container replacement may wipe the login**.
  Recovery is re-scanning the QR at `/qr` (the entrypoint handles this
  automatically on the next start).
- This test should explicitly check it: after the bridge is logged in and
  working, trigger a redeploy (or restart) in the panel and see whether
  `logged_in` survives. Expect it NOT to survive; the test result is the
  evidence.
- If persistence is required later, options are: (a) ask DeployVera support
  whether a persistent volume is available on the free plan and how to mount
  it; (b) add a backup/restore path (the bridge has `backup` / `restore`
  commands) that saves state outside the container; (c) accept re-login
  after each redeploy.

## Remote operation — what changes vs the local bridge

- The local `muse-link` CLI talks to a **local** bridge (it builds the URL
  from the local config's loopback listen address). It **cannot** talk to
  the DeployVera bridge directly. Operating the remote bridge means calling
  its HTTP API over the DeployVera public URL with the Bearer token
  (e.g. via `curl`, or a small script). The API is identical to the local
  one — see `docs/API.md` in the bridge repo.
- **Text receive/send works** this way. **Media send-back does not**: the
  bridge only sends files that exist at absolute paths under its
  `media_roots` **on the bridge machine** (the container). The parent's
  media files live on the local VM, not in the container, and DeployVera
  offers no file upload into a running container. Inbound media (images /
  files the user sends on WeChat) is downloaded by the bridge into the
  container; reading it remotely would need the proxy to serve those files
  (not implemented — possible extension).
- The bridge API is now reachable on the public internet (behind the
  Bearer token). The token is the only gate, so keep it secret and rotate
  it if it ever leaks. For the test this is acceptable; for longer use,
  consider restricting access (DeployVera "Internal network only" mode
  would hide it entirely, but then the parent could not reach it either).

## Resource fit

- Free plan: 0.5 vCPU / 512 MB RAM / 2 GB disk / 1 app.
- Bridge state is tiny (local state dir is ~432 KB; node_modules ~5 MB).
  The bridge's own service unit caps memory at 512 MB, and a bridge
  typically uses well under 200 MB. The proxy is a few MB. This fits.
- The bridge's `max_state_bytes` (1 GB) and `max_outbox_bytes` (512 MB)
  are caps, not actual usage; they will not be hit in a test.

## Blockers / gaps found during preparation

1. **GitHub account + public repo required.** DeployVera deploys from a Git
   repo; the Dockerfile must be at the repo root. Someone must create the
   repo and push these files. No GitHub account or repo was created in this
   preparation (needs the user's go-ahead / account).
2. **Release asset URL not re-verified this session.** The GitHub API
   request for the release `three-versions-20261029` returned HTTP 403 in
   this session, so the exact downloadable asset filename was not confirmed
   here. The Dockerfile avoids the problem by cloning the repo at the known
   rc.5 commit (`2d026ef8…`, from the local install's `source-commit.txt`)
   instead of downloading a release asset. If the release asset URL is
   confirmed later, the Dockerfile can switch to it.
3. **No persistent volume on the free plan (as documented).** See
   "Persistence" above. The test will measure the actual behaviour.
4. **WeChat pairing verification code has no remote entry path.** See step 4.
   Only matters if WeChat demands a code during login.
5. **Media send-back from the parent is out of scope.** See "Remote
   operation". Text-only for the test.

## Local validation done in this preparation

- Read the DeployVera docs: free plan, overview, persistence, quickstart,
  plans-and-databases, database-and-worker, MCP.
- Read the local bridge install (read-only): `package.json` (Node ≥ 24,
  entry `node src/cli.mjs run`, deps qrcode/silk-wasm/undici),
  `deploy/muse-link.service.in` (ExecStart), `config.example.json`,
  `src/config.mjs` (loopback-only validation), `src/login.mjs` (QR PNG to
  a file, `onQr` prints the file path), `src/cli.mjs` (`login` / `run` /
  `status` commands), `docs/API.md` (Bearer auth, `/healthz` unauthenticated).
- Confirmed locally (read-only `muse-link status`): status is one compact
  JSON line with top-level `"logged_in":true`; no native `.node` modules
  in `node_modules` (no build tools needed in the image).
- `node --check` on `proxy.mjs` and `bash -n` on `entrypoint.sh` — both pass.
- **Proxy smoke test (passed, against a mock bridge on 127.0.0.1:18792):**
  `GET /healthz` → `{"alive":true,"proxy":true,"logged_in":false}`;
  `GET /` → status page shows "bridge: up" and "WeChat: NOT logged in";
  `GET /qr` → HTML page embedding `/qr.png`; `GET /qr.png` → 200, valid
  1×1 PNG; `GET /v1/muse/tasks` with a Bearer token → `{"tasks":[]}`
  (reverse proxy works); the mock saw the exact Bearer token forwarded;
  `GET /v1/muse/tasks` with no token → 401 (the bridge's own auth is
  enforced through the proxy). Test processes were stopped afterwards and
  both test ports (18099, 18792) are confirmed closed.
- **Docker is not installed on this VM, so no local `docker build` was
  possible.** The Dockerfile is untested by an actual build; the first
  DeployVera build is the real build test. The build log will show whether
  the git checkout + `npm ci` succeed.
