#!/usr/bin/env node
// 网关代理的行为测试：不依赖 cc-switch 二进制，用一个假上游代替后端。
// 覆盖：前缀剥离、静态托管、/api 透传、Set-Cookie Path 收窄、WebSocket 升级、/healthz、前缀外 404。
import http from "node:http";
import net from "node:net";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import crypto from "node:crypto";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
const GATEWAY = path.join(HERE, "..", "pkg", "app", "gateway-proxy.mjs");
const PREFIX = "/app/t-app";

let failures = 0;
function check(name, cond, detail = "") {
  if (cond) {
    console.log(`  ok   ${name}`);
  } else {
    failures++;
    console.log(`  FAIL ${name}${detail ? ` — ${detail}` : ""}`);
  }
}

function freePort() {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.unref();
    srv.on("error", reject);
    srv.listen(0, "127.0.0.1", () => {
      const { port } = srv.address();
      srv.close(() => resolve(port));
    });
  });
}

// 假上游：模拟 cc-switch-web 的 HTTP + WS 行为
function startUpstream() {
  return new Promise((resolve) => {
    const srv = http.createServer((req, res) => {
      if (req.url === "/api/ping") {
        res.writeHead(200, { "content-type": "application/json" });
        res.end(JSON.stringify({ pong: true, path: req.url }));
        return;
      }
      if (req.url === "/api/invoke") {
        let body = "";
        req.on("data", (c) => (body += c));
        req.on("end", () => {
          res.writeHead(200, { "content-type": "application/json" });
          res.end(JSON.stringify({ echoed: JSON.parse(body || "{}"), upstream: true }));
        });
        return;
      }
      if (req.url === "/api/cookie") {
        res.writeHead(200, {
          "set-cookie": [
            "cc-switch-session=abc; Path=/; HttpOnly; SameSite=Strict",
            "other=1; Path=/api; HttpOnly",
          ],
          "content-type": "text/plain",
        });
        res.end("cookie");
        return;
      }
      res.writeHead(404).end("upstream-404");
    });
    srv.on("upgrade", (req, socket) => {
      const accept = crypto
        .createHash("sha1")
        .update(`${req.headers["sec-websocket-key"]}258EAFA5-E914-47DA-95CA-C5AB0DC85B11`)
        .digest("base64");
      socket.write(
        "HTTP/1.1 101 Switching Protocols\r\n" +
          "Upgrade: websocket\r\n" +
          "Connection: Upgrade\r\n" +
          `Sec-WebSocket-Accept: ${accept}\r\n\r\n`,
      );
      socket.end();
    });
    srv.listen(0, "127.0.0.1", () => resolve({ srv, port: srv.address().port }));
  });
}

function req(socketPath, { method = "GET", path: p = "/", headers = {}, body } = {}) {
  return new Promise((resolve, reject) => {
    const r = http.request({ socketPath, method, path: p, headers }, (res) => {
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () =>
        resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks).toString() }),
      );
    });
    r.on("error", reject);
    if (body !== undefined) r.write(body);
    r.end();
  });
}

function wsUpgrade(socketPath, p) {
  return new Promise((resolve, reject) => {
    const r = http.request({
      socketPath,
      path: p,
      headers: {
        Connection: "Upgrade",
        Upgrade: "websocket",
        "Sec-WebSocket-Version": "13",
        "Sec-WebSocket-Key": crypto.randomBytes(16).toString("base64"),
      },
    });
    r.on("upgrade", (res) => {
      res.socket.destroy();
      resolve({ status: res.statusCode, headers: res.headers });
    });
    r.on("response", (res) => {
      res.resume();
      resolve({ status: res.statusCode, headers: res.headers });
    });
    r.on("error", reject);
    r.end();
  });
}

async function main() {
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), "ccsw-gw-"));
  const webRoot = path.join(tmp, "web");
  fs.mkdirSync(path.join(webRoot, "assets"), { recursive: true });
  fs.writeFileSync(path.join(webRoot, "index.html"), "<!doctype html><title>t</title>app-index");
  fs.writeFileSync(path.join(webRoot, "assets", "app.js"), "console.log(1)");
  const sock = path.join(tmp, "app.sock");

  const { srv: upstream, port: upPort } = await startUpstream();

  const gw = spawn(process.execPath, [GATEWAY], {
    env: {
      ...process.env,
      APPNAME: "t-app",
      PREFIX,
      SOCKET_PATH: sock,
      WEB_ROOT: webRoot,
      UPSTREAM_HOST: "127.0.0.1",
      UPSTREAM_PORT: String(upPort),
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  let gwErr = "";
  gw.stderr.on("data", (d) => (gwErr += d));

  // 等 socket 出现
  const deadline = Date.now() + 10000;
  while (!fs.existsSync(sock) && Date.now() < deadline) await new Promise((r) => setTimeout(r, 100));
  if (!fs.existsSync(sock)) {
    console.error("网关未能启动：", gwErr);
    process.exit(1);
  }

  console.log("gateway.test.mjs");

  const index = await req(sock, { path: `${PREFIX}/` });
  check("前缀下的 index.html 返回 200", index.status === 200, `got ${index.status}`);
  check("index.html 内容正确", index.body.includes("app-index"));
  check("index.html 是 text/html", String(index.headers["content-type"]).includes("text/html"));

  const noSlash = await req(sock, { path: PREFIX });
  check("无结尾斜杠也返回 index.html", noSlash.status === 200 && noSlash.body.includes("app-index"), `got ${noSlash.status}`);

  const asset = await req(sock, { path: `${PREFIX}/assets/app.js` });
  check("静态资源 200", asset.status === 200);
  check("js 的 content-type 正确", String(asset.headers["content-type"]).includes("javascript"));

  const missing = await req(sock, { path: `${PREFIX}/assets/none.js` });
  check("不存在的资源 404", missing.status === 404, `got ${missing.status}`);

  const outside = await req(sock, { path: "/app/other-app/" });
  check("前缀外请求 404", outside.status === 404, `got ${outside.status}`);

  const ping = await req(sock, { path: `${PREFIX}/api/ping` });
  check("/api 透传到上游", ping.status === 200 && ping.body.includes('"pong":true'), ping.body.slice(0, 80));
  check("上游看到的路径已剥离前缀", ping.body.includes('"path":"/api/ping"'), ping.body.slice(0, 120));

  const inv = await req(sock, {
    method: "POST",
    path: `${PREFIX}/api/invoke`,
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ command: "auth.status", payload: {} }),
  });
  check("/api/invoke POST 正常", inv.status === 200 && inv.body.includes('"upstream":true'), inv.body.slice(0, 80));

  const cookie = await req(sock, { path: `${PREFIX}/api/cookie` });
  const setCookie = [].concat(cookie.headers["set-cookie"] || []).join("\n");
  check("Set-Cookie 的 Path=/ 被收窄到挂载前缀", setCookie.includes(`Path=${PREFIX}`), setCookie.replace(/\n/g, " | "));
  check("已有具体 Path 的 cookie 不被改写", setCookie.includes("other=1; Path=/api;"), setCookie.replace(/\n/g, " | "));

  const health = await req(sock, { path: "/healthz" });
  check("/healthz 返回 ok", health.status === 200 && health.body.includes('"status":"ok"'), health.body);

  const ws = await wsUpgrade(sock, `${PREFIX}/api/ws`);
  check("WebSocket 升级返回 101", ws.status === 101, `got ${ws.status}`);
  check("返回 Sec-WebSocket-Accept", Boolean(ws.headers["sec-websocket-accept"]));

  gw.kill("SIGTERM");
  upstream.close();
  fs.rmSync(tmp, { recursive: true, force: true });

  console.log(failures === 0 ? "\ngateway: 全部通过" : `\ngateway: ${failures} 项失败`);
  process.exit(failures === 0 ? 0 : 1);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
