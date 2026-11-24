// proxy.mjs — public front door for the Muse Link bridge on DeployVera.
//
// The bridge binds ONLY to loopback (127.0.0.1:18791) by design; its config
// validation rejects any other listen host. DeployVera requires the app to
// listen on 0.0.0.0:$PORT, so this process does that and:
//   - GET  /        -> small HTML status page (bridge up/down, logged in, links)
//   - GET  /healthz -> bridge liveness (200 when the bridge answers, else 503)
//   - GET  /qr      -> HTML page showing the latest WeChat login QR image
//   - GET  /qr.png  -> the latest WeChat login QR PNG (raw image)
//   - anything else -> reverse-proxy to the bridge API (127.0.0.1:18791),
//                      preserving method, path, headers and body. The bridge
//                      enforces its own Bearer api_token auth on /v1/*; this
//                      proxy adds no auth of its own and never logs tokens.
//
// Node.js built-ins only (no dependencies). The api_token is read from the
// MUSE_LINK_API_TOKEN env var (set in the DeployVera panel) and is used only
// to ask the bridge for /v1/status so / and /qr can report "logged in".
// It is never written to a log or a response.

import http from 'node:http';
import { createReadStream, readdirSync, statSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { join, basename, resolve, sep } from 'node:path';

const PORT = Number(process.env.PORT || 3000);
const BRIDGE_HOST = '127.0.0.1';
// Overridable for local testing (MUSE_LINK_BRIDGE_PORT); default is the
// bridge's fixed loopback port. The bridge itself never listens elsewhere.
const BRIDGE_PORT = Number(process.env.MUSE_LINK_BRIDGE_PORT || 18791);
const BRIDGE = `http://${BRIDGE_HOST}:${BRIDGE_PORT}`;
const QR_DIR = process.env.MUSE_LINK_QR_DIR || '/data/qr';
const MEDIA_ROOT = process.env.MUSE_LINK_MEDIA_ROOT || '/data/workspace';
const DATA_DIR = process.env.MUSE_LINK_DATA_DIR || '/data';
const API_TOKEN = process.env.MUSE_LINK_API_TOKEN || '';

const log = (event, fields = {}) =>
  console.log(JSON.stringify({ time: new Date().toISOString(), component: 'proxy', event, ...fields }));

// --- small helpers -------------------------------------------------------

function fetchJson(path, { timeoutMs = 3000, auth = false } = {}) {
  return new Promise((resolve) => {
    const req = http.request(
      `${BRIDGE}${path}`,
      { method: 'GET', signal: AbortSignal.timeout(timeoutMs), headers: auth && API_TOKEN ? { Authorization: `Bearer ${API_TOKEN}` } : {} },
      (res) => {
        let body = '';
        res.on('data', (c) => { body += c; });
        res.on('end', () => {
          try { resolve({ ok: res.statusCode >= 200 && res.statusCode < 300, status: res.statusCode, json: JSON.parse(body) }); }
          catch { resolve({ ok: false, status: res.statusCode, json: null }); }
        });
      },
    );
    req.on('error', () => resolve({ ok: false, status: 0, json: null }));
    req.on('timeout', () => req.destroy());
    req.end();
  });
}

async function bridgeStatus() {
  const health = await fetchJson('/healthz', { timeoutMs: 2000 });
  const up = health.ok && health.json && health.json.alive === true;
  let loggedIn = null;
  if (up && API_TOKEN) {
    const st = await fetchJson('/v1/status', { timeoutMs: 3000, auth: true });
    if (st.ok && st.json && typeof st.json.logged_in === 'boolean') loggedIn = st.json.logged_in;
  }
  return { up, loggedIn };
}

function latestQrFile() {
  let files;
  try { files = readdirSync(QR_DIR).filter((f) => f.startsWith('muse-link-qr-') && f.endsWith('.png')); }
  catch { return null; }
  if (!files.length) return null;
  let best = null;
  let bestMtime = -1;
  for (const f of files) {
    try {
      const mtime = statSync(join(QR_DIR, f)).mtimeMs;
      if (mtime > bestMtime) { bestMtime = mtime; best = f; }
    } catch { /* ignore unreadable entries */ }
  }
  return best ? join(QR_DIR, best) : null;
}

function send(res, status, contentType, body) {
  res.writeHead(status, { 'content-type': contentType, 'cache-control': 'no-store' });
  res.end(body);
}

function statusPage({ up, loggedIn }) {
  const bridgeLine = up ? 'bridge: up (listening on 127.0.0.1:18791)' : 'bridge: DOWN (daemon not answering yet)';
  const loginLine =
    loggedIn === true ? 'WeChat: logged in' :
    loggedIn === false ? 'WeChat: NOT logged in — open /qr and scan the code' :
    'WeChat: login state unknown (bridge down or token not set)';
  return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Muse Link bridge</title></head><body style="font-family:system-ui,sans-serif;max-width:640px;margin:2em auto;padding:0 1em;line-height:1.6"><h1>Muse Link bridge (DeployVera test)</h1><p>${bridgeLine}</p><p>${loginLine}</p><ul><li><a href="/qr">WeChat login QR code</a></li><li><a href="/healthz">health check (JSON)</a></li></ul><p style="color:#666">The bridge API is proxied under /v1/* and requires the Bearer api_token. Media: POST /upload (Bearer) to put a file in the bridge's media root, GET /media/&lt;path&gt; (Bearer) to fetch a file the bridge stored.</p></body></html>`;
}

function qrPage({ loggedIn, hasQr }) {
  if (loggedIn === true) {
    return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>QR — already logged in</title></head><body style="font-family:system-ui,sans-serif;max-width:640px;margin:2em auto;padding:0 1em;line-height:1.6"><h1>Already logged in</h1><p>The bridge is already logged in to WeChat, so there is no QR code to scan.</p><p><a href="/">Back to status</a></p></body></html>`;
  }
  if (!hasQr) {
    return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>QR — not ready</title></head><body style="font-family:system-ui,sans-serif;max-width:640px;margin:2em auto;padding:0 1em;line-height:1.6"><h1>No QR code yet</h1><p>The bridge is still starting or has not begun login. Refresh this page in a few seconds.</p><p><a href="/">Back to status</a></p></body></html>`;
  }
  return `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>WeChat login QR</title></head><body style="font-family:system-ui,sans-serif;max-width:640px;margin:2em auto;padding:0 1em;line-height:1.6"><h1>Scan with WeChat to log in</h1><p><img src="/qr.png" alt="WeChat login QR code" style="width:320px;height:320px;image-rendering:pixelated;border:1px solid #ccc"></p><p>The code refreshes every few minutes. If this one does not scan, refresh the page for a new code.</p><p><a href="/">Back to status</a></p></body></html>`;
}

// --- media upload / download ---------------------------------------------
// POST /upload?filename=<name> — save raw file bytes (Content-Type:
// application/octet-stream) under MEDIA_ROOT/uploads/ and return the
// absolute container path, which the bridge can then send via its media
// reply. GET /media/<relpath> — serve a file from under DATA_DIR (used to
// fetch inbound media the bridge downloaded, e.g. a photo the user sent).
// Both require the Bearer api_token, the same token the bridge API uses.

function checkAuth(req) {
  if (!API_TOKEN) return false;
  const h = req.headers.authorization || '';
  return h === `Bearer ${API_TOKEN}`;
}

const MIME_BY_EXT = {
  '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg',
  '.gif': 'image/gif', '.webp': 'image/webp', '.bmp': 'image/bmp',
  '.mp4': 'video/mp4', '.mov': 'video/quicktime', '.webm': 'video/webm',
  '.mp3': 'audio/mpeg', '.wav': 'audio/wav', '.ogg': 'audio/ogg',
  '.pdf': 'application/pdf', '.txt': 'text/plain; charset=utf-8',
  '.json': 'application/json', '.zip': 'application/zip',
};

function mimeFor(filePath) {
  const dot = filePath.lastIndexOf('.');
  const ext = dot >= 0 ? filePath.slice(dot).toLowerCase() : '';
  return MIME_BY_EXT[ext] || 'application/octet-stream';
}

function handleUpload(req, res, url) {
  if (!checkAuth(req)) { send(res, 401, 'application/json', JSON.stringify({ error: 'unauthorized' })); return; }
  const rawName = url.searchParams.get('filename') || '';
  // Sanitize: basename only, no path separators, no leading dot, must have a name.
  const name = basename(rawName).replace(/[^A-Za-z0-9._-]/g, '_');
  if (!name || name === '.' || name === '..' || name.startsWith('.')) {
    send(res, 400, 'application/json', JSON.stringify({ error: 'invalid_filename' }));
    return;
  }
  const chunks = [];
  let total = 0;
  const MAX_BYTES = 50 * 1024 * 1024; // 50 MiB, the bridge's file limit
  req.on('data', (c) => {
    total += c.length;
    if (total > MAX_BYTES) { req.destroy(); return; }
    chunks.push(c);
  });
  req.on('end', () => {
    if (total > MAX_BYTES) {
      if (!res.headersSent) send(res, 413, 'application/json', JSON.stringify({ error: 'file_too_large', max_bytes: MAX_BYTES }));
      return;
    }
    try {
      const dir = join(MEDIA_ROOT, 'uploads');
      mkdirSync(dir, { recursive: true });
      // Unique name to avoid overwriting an earlier upload.
      let dest = join(dir, name);
      if (existsSync(dest)) {
        const dot = name.lastIndexOf('.');
        const stem = dot > 0 ? name.slice(0, dot) : name;
        const ext = dot > 0 ? name.slice(dot) : '';
        dest = join(dir, `${stem}-${Date.now()}${ext}`);
      }
      writeFileSync(dest, Buffer.concat(chunks));
      log('upload_saved', { path: dest, bytes: total });
      send(res, 200, 'application/json', JSON.stringify({ ok: true, path: dest, bytes: total }));
    } catch (err) {
      log('upload_error', { message: String(err && err.message ? err.message : err) });
      if (!res.headersSent) send(res, 500, 'application/json', JSON.stringify({ error: 'upload_failed' }));
    }
  });
  req.on('error', () => {
    if (!res.headersSent) send(res, 500, 'application/json', JSON.stringify({ error: 'upload_failed' }));
  });
}

function handleMediaDownload(req, res, url) {
  if (!checkAuth(req)) { send(res, 401, 'application/json', JSON.stringify({ error: 'unauthorized' })); return; }
  const rel = decodeURIComponent(url.pathname.slice('/media/'.length));
  // Resolve under DATA_DIR and reject any escape (no .. traversal).
  const resolved = resolve(DATA_DIR, rel);
  if (resolved !== DATA_DIR && !resolved.startsWith(DATA_DIR + sep)) {
    send(res, 400, 'application/json', JSON.stringify({ error: 'invalid_path' }));
    return;
  }
  let st;
  try { st = statSync(resolved); } catch { st = null; }
  if (!st || !st.isFile()) { send(res, 404, 'application/json', JSON.stringify({ error: 'not_found' })); return; }
  res.writeHead(200, { 'content-type': mimeFor(resolved), 'content-length': st.size, 'cache-control': 'no-store' });
  createReadStream(resolved).on('error', () => {
    if (!res.headersSent) send(res, 500, 'text/plain; charset=utf-8', 'Could not read the file.');
    else res.end();
  }).pipe(res);
}

// --- reverse proxy -------------------------------------------------------

const HOP_BY_HOP = new Set([
  'connection', 'keep-alive', 'proxy-authenticate', 'proxy-authorization',
  'te', 'trailer', 'transfer-encoding', 'upgrade', 'host',
]);

function proxyToBridge(req, res) {
  const headers = {};
  for (const [k, v] of Object.entries(req.headers)) {
    if (!HOP_BY_HOP.has(k.toLowerCase())) headers[k] = v;
  }
  const upstream = http.request(
    { host: BRIDGE_HOST, port: BRIDGE_PORT, method: req.method, path: req.url, headers },
    (upRes) => {
      const outHeaders = {};
      for (const [k, v] of Object.entries(upRes.headers)) {
        if (!HOP_BY_HOP.has(k.toLowerCase())) outHeaders[k] = v;
      }
      res.writeHead(upRes.statusCode, outHeaders);
      upRes.pipe(res);
    },
  );
  upstream.on('error', () => {
    if (!res.headersSent) send(res, 502, 'application/json', JSON.stringify({ error: 'bridge_unavailable', hint: 'the bridge daemon is not answering on 127.0.0.1:18791 yet' }));
    else res.end();
  });
  req.pipe(upstream);
}

// --- server ---------------------------------------------------------------

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url || '/', `http://${req.headers.host || 'localhost'}`);
  const path = url.pathname;
  try {
    if (req.method === 'GET' && path === '/') {
      const st = await bridgeStatus();
      send(res, 200, 'text/html; charset=utf-8', statusPage(st));
      return;
    }
    if (req.method === 'GET' && path === '/healthz') {
      const st = await bridgeStatus();
      if (st.up) send(res, 200, 'application/json', JSON.stringify({ alive: true, proxy: true, logged_in: st.loggedIn }));
      else send(res, 503, 'application/json', JSON.stringify({ alive: false, proxy: true }));
      return;
    }
    if (req.method === 'GET' && path === '/qr') {
      const st = await bridgeStatus();
      const qr = st.loggedIn === true ? null : latestQrFile();
      send(res, 200, 'text/html; charset=utf-8', qrPage({ loggedIn: st.loggedIn, hasQr: Boolean(qr) }));
      return;
    }
    if (req.method === 'GET' && path === '/qr.png') {
      const st = await bridgeStatus();
      if (st.loggedIn === true) { send(res, 410, 'text/plain; charset=utf-8', 'Already logged in — no QR code.'); return; }
      const qr = latestQrFile();
      if (!qr) { send(res, 404, 'text/plain; charset=utf-8', 'No QR code yet.'); return; }
      res.writeHead(200, { 'content-type': 'image/png', 'cache-control': 'no-store' });
      createReadStream(qr).on('error', () => {
        if (!res.headersSent) send(res, 500, 'text/plain; charset=utf-8', 'Could not read the QR file.');
        else res.end();
      }).pipe(res);
      return;
    }
    if (req.method === 'POST' && path === '/upload') {
      handleUpload(req, res, url);
      return;
    }
    if (req.method === 'GET' && path.startsWith('/media/')) {
      handleMediaDownload(req, res, url);
      return;
    }
    // Everything else: the bridge API (auth enforced by the bridge itself).
    proxyToBridge(req, res);
  } catch (err) {
    log('proxy_error', { path, message: String(err && err.message ? err.message : err) });
    if (!res.headersSent) send(res, 500, 'application/json', JSON.stringify({ error: 'proxy_error' }));
    else res.end();
  }
});

server.listen(PORT, '0.0.0.0', () => {
  log('listening', { address: `0.0.0.0:${PORT}`, bridge: BRIDGE, qr_dir: QR_DIR });
});
process.on('SIGTERM', () => { log('shutdown', {}); server.close(() => process.exit(0)); });
process.on('SIGINT', () => { log('shutdown', {}); server.close(() => process.exit(0)); });
