#!/usr/bin/env node
// fnOS gateway bridge for cc-switch-web.
//
//   browser --/app/<app>/*--> this process (unix socket app.sock) --/api/*--> 127.0.0.1:<port>
//
// Responsibilities (see fnos-dsh adaptation.md):
//  1. strip the /app/<app> prefix that fnOS' gateway already matched
//  2. serve the rebuilt SPA whose API base is /app/<app>/api
//  3. proxy /api and /api/ws (WebSocket upgrade) to the backend
//  4. narrow cookie Path=/ down to the mount prefix
//  5. keep SSE/WS alive, strip hop-by-hop headers
//  6. answer /healthz for cmd/main status without touching the backend

import http from "node:http";
import fs from "node:fs";
import fsp from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const env = process.env;
const APPNAME = env.APPNAME || "fn-ccswitch";
const PREFIX = (env.PREFIX || `/app/${APPNAME}`).replace(/\/+$/, "");
const SOCKET_PATH = env.SOCKET_PATH || "";
const HOST = env.UPSTREAM_HOST || "127.0.0.1";
const PORT = Number(env.UPSTREAM_PORT || 17666);
const WEB_ROOT = env.WEB_ROOT || path.join(path.dirname(fileURLToPath(import.meta.url)), "web");
const IDLE_TIMEOUT_MS = Number(env.IDLE_TIMEOUT_MS || 180000);

const HOP_BY_HOP = new Set([
  "connection",
  "keep-alive",
  "proxy-authenticate",
  "proxy-authorization",
  "te",
  "trailer",
  "transfer-encoding",
  "upgrade",
]);

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".map": "application/json; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
  ".ico": "image/x-icon",
  ".woff": "font/woff",
  ".woff2": "font/woff2",
  ".ttf": "font/ttf",
  ".txt": "text/plain; charset=utf-8",
  ".wasm": "application/wasm",
};

function log(...args) {
  process.stdout.write(`[gateway ${new Date().toISOString()}] ${args.join(" ")}\n`);
}

function stripPrefix(url) {
  if (!url.startsWith(PREFIX)) return null;
  const rest = url.slice(PREFIX.length);
  if (rest === "" || rest.startsWith("/") || rest.startsWith("?")) return rest || "/";
  return null;
}

function cleanHeaders(headers) {
  const out = {};
  for (const [k, v] of Object.entries(headers)) {
    const key = k.toLowerCase();
    if (HOP_BY_HOP.has(key)) continue;
    if (key === "cookie") {
      out[key] = narrowCookiePaths(v);
      continue;
    }
    out[key] = v;
  }
  return out;
}

// cc-switch sets the session cookie with Path=/ which leaks it to every fnOS app.
function narrowCookiePaths(value) {
  return String(value)
    .split(/,(?=[^;]+?=)/)
    .map((c) => c.replace(/;\s*path=\//i, `; Path=${PREFIX}/`))
    .join(",");
}

function upgradeRequest(req, socket, head, target) {
  // Upgrade handshakes must keep Connection/Upgrade and the Sec-WebSocket-* headers:
  // stripping hop-by-hop headers here would turn the handshake into a plain GET.
  const headers = {};
  for (const [k, v] of Object.entries(req.headers)) {
    const key = k.toLowerCase();
    if (key === "proxy-authorization" || key === "te" || key === "trailer") continue;
    headers[key] = v;
  }
  headers["x-forwarded-prefix"] = PREFIX;
  const up = http.request({ host: HOST, port: PORT, method: req.method, path: target, headers });
  up.on("upgrade", (res, upSocket, upHead) => {
    const lines = [`HTTP/1.1 101 Switching Protocols`];
    for (const [k, v] of Object.entries(res.headers)) {
      if (Array.isArray(v)) for (const item of v) lines.push(`${k}: ${item}`);
      else lines.push(`${k}: ${v}`);
    }
    socket.write(lines.join("\r\n") + "\r\n\r\n");
    if (upHead && upHead.length) socket.write(upHead);
    upSocket.pipe(socket).pipe(upSocket);
    upSocket.on("error", () => socket.destroy());
    socket.on("error", () => upSocket.destroy());
    log("ws upgrade ok", target);
  });
  up.on("response", (res) => {
    log("ws upgrade rejected by upstream", res.statusCode, target);
    socket.write(`HTTP/1.1 ${res.statusCode} Bad Gateway\r\nConnection: close\r\n\r\n`);
    socket.destroy();
  });
  up.on("error", (err) => {
    log("ws upstream error", err.message);
    socket.destroy();
  });
  up.end();
}

async function serveStatic(req, res, target) {
  let rel = decodeURIComponent(target.split("?")[0]);
  if (rel.endsWith("/")) rel += "index.html";
  const file = path.join(WEB_ROOT, path.normalize(rel).replace(/^(\.\.[/\\])+/, ""));
  if (!file.startsWith(WEB_ROOT)) {
    res.writeHead(403).end("Forbidden");
    return;
  }
  try {
    const stat = await fsp.stat(file);
    if (stat.isFile()) return sendFile(req, res, file, stat);
  } catch {
    /* fall through */
  }
  if (!path.extname(rel)) {
    const index = path.join(WEB_ROOT, "index.html");
    try {
      const stat = await fsp.stat(index);
      return sendFile(req, res, index, stat);
    } catch {
      /* fall through */
    }
  }
  res.writeHead(404, { "content-type": "text/plain; charset=utf-8" }).end("Not Found");
}

function sendFile(req, res, file, stat) {
  const ext = path.extname(file).toLowerCase();
  const headers = {
    "content-type": MIME[ext] || "application/octet-stream",
    "content-length": stat.size,
    "cache-control": ext === ".html" ? "no-cache" : "public, max-age=31536000, immutable",
  };
  if (req.method === "HEAD") return res.writeHead(200, headers).end();
  res.writeHead(200, headers);
  fs.createReadStream(file).pipe(res);
}

function proxyHttp(req, res, target) {
  const headers = { ...cleanHeaders(req.headers), "x-forwarded-prefix": PREFIX };
  delete headers.host;
  const up = http.request({ host: HOST, port: PORT, method: req.method, path: target, headers }, (upRes) => {
    const out = cleanHeaders(upRes.headers);
    if (out["set-cookie"]) out["set-cookie"] = narrowCookiePaths(out["set-cookie"]);
    res.writeHead(upRes.statusCode || 502, upRes.statusMessage, out);
    upRes.pipe(res);
  });
  up.setTimeout(IDLE_TIMEOUT_MS, () => up.destroy(new Error("upstream timeout")));
  up.on("error", (err) => {
    log("upstream error", target, err.message);
    if (!res.headersSent) {
      res.writeHead(502, { "content-type": "text/html; charset=utf-8" }).end(errorPage(err.message));
    } else res.destroy();
  });
  req.pipe(up);
}

function errorPage(detail) {
  return `<!doctype html><html lang="zh-CN"><meta charset="utf-8"><title>CC Switch 暂时不可用</title>
<body style="font-family:system-ui;margin:0;display:grid;place-items:center;height:100vh;background:#0b0b0d;color:#e6e6e6">
<div style="text-align:center;max-width:34rem"><h2>CC Switch 后端没有响应</h2>
<p style="color:#9ca3af">应用进程可能正在启动或已退出。可到「应用中心 → CC Switch」重启，或查看日志：</p>
<p style="color:#9ca3af;font-size:.85rem">/var/apps/${APPNAME}/var/log/backend.log</p>
<p style="color:#6b7280;font-size:.75rem">${detail}</p></div></body></html>`;
}

const server = http.createServer(async (req, res) => {
  const url = req.url || "/";

  if (url === "/healthz" || url === `${PREFIX}/healthz`) {
    const ok = await new Promise((resolve) => {
      const probe = http.request({ host: HOST, port: PORT, path: "/api/invoke", method: "POST", timeout: 1500,
        headers: { "content-type": "application/json" } },
        (r) => { r.resume(); resolve(true); });
      probe.on("error", () => resolve(false));
      probe.on("timeout", () => { probe.destroy(); resolve(false); });
      probe.end('{"command":"auth.status","payload":{}}');
    });
    return res.writeHead(ok ? 200 : 503, { "content-type": "application/json" })
      .end(JSON.stringify({ status: ok ? "ok" : "down", upstream: `${HOST}:${PORT}` }));
  }

  const stripped = stripPrefix(url);
  if (stripped === null) {
    return res.writeHead(404, { "content-type": "text/plain" }).end("Not Found");
  }

  if (stripped === "/api" || stripped.startsWith("/api/")) {
    return proxyHttp(req, res, stripped);
  }

  if (req.method !== "GET" && req.method !== "HEAD") {
    return res.writeHead(405, { "allow": "GET, HEAD" }).end();
  }
  return serveStatic(req, res, stripped);
});

server.on("upgrade", (req, socket, head) => {
  const stripped = stripPrefix(req.url || "");
  if (stripped === null || !(stripped === "/api/ws" || stripped.startsWith("/api/"))) {
    socket.destroy();
    return;
  }
  upgradeRequest(req, socket, head, stripped);
});

function shutdown(signal) {
  log("received", signal, "shutting down");
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 3000).unref();
}
process.on("SIGTERM", () => shutdown("SIGTERM"));
process.on("SIGINT", () => shutdown("SIGINT"));

if (SOCKET_PATH) {
  try {
    if (fs.existsSync(SOCKET_PATH)) fs.unlinkSync(SOCKET_PATH);
  } catch (err) {
    log("cannot remove stale socket", err.message);
  }
  server.listen(SOCKET_PATH, () => {
    fs.chmodSync(SOCKET_PATH, 0o660);
    log(`listening on unix:${SOCKET_PATH} prefix=${PREFIX} web=${WEB_ROOT} upstream=${HOST}:${PORT}`);
  });
} else {
  const port = Number(env.LISTEN_PORT || 0);
  server.listen(port, "127.0.0.1", () => log(`listening on tcp:${server.address().port} prefix=${PREFIX}`));
}
