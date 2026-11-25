// Sill relay: claude.ai's connector on one side, your Mac on the other.
//
//   claude.ai ──HTTPS (MCP + OAuth)──▶ relay ◀──WebSocket── sill-mcp --relay (your Mac) ──▶ Sill
//
// claude.ai calls connectors from Anthropic's cloud, so it needs an address on
// the internet. Your Mac dials out to this relay and keeps the line open; the
// relay hands each MCP message down the line and the answer back up. The tools
// themselves live in sill-mcp, the same ones Claude Code gets.
//
// Security:
// - Only a bridge holding RELAY_SECRET can attach as your Mac.
// - claude.ai signs in with OAuth 2.1 (PKCE, dynamic client registration). The
//   sign-in only finishes after you click Allow in a dialog Sill shows on your
//   Mac, naming the site that asked.
// - Nothing is stored: clients, codes and tokens are signed with a key derived
//   from RELAY_SECRET. Change RELAY_SECRET to sign every client out.
// - Tool arguments and page contents pass through and are never logged.
//
// Env: RELAY_SECRET (required, 32+ chars), PORT, PUBLIC_URL (else Railway's domain or the Host header).

import http from "node:http";
import crypto from "node:crypto";
import fs from "node:fs";
import { WebSocketServer } from "ws";

const SECRET = process.env.RELAY_SECRET ?? "";
if (SECRET.length < 32) {
  console.error("RELAY_SECRET must be set to at least 32 characters (e.g. `openssl rand -hex 32`).");
  process.exit(1);
}
const PORT = Number(process.env.PORT ?? 8787);
// The relay's own address: PUBLIC_URL if set, else the address each request came to,
// so it answers correctly under every address it has (its Railway one, a custom domain).
const FIXED_BASE = process.env.PUBLIC_URL?.replace(/\/+$/, "") || null;

const ACCESS_TTL = 60 * 60;              // 1 hour
const REFRESH_TTL = 60 * 60 * 24 * 60;   // 60 days
const CODE_TTL = 5 * 60;
const APPROVAL_TIMEOUT = 120_000;
const CALL_TIMEOUT = 180_000;
const SCOPE = "sill";

// Sill's own icon: what claude.ai shows beside the connector (as favicon, and declared over MCP).
const ICONS = Object.fromEntries(["icon.png", "favicon.png", "favicon-96.png", "favicon-192.png", "apple-touch-icon.png"].map((name) => {
  try { return [name, fs.readFileSync(new URL(`./public/${name}`, import.meta.url))]; } catch { return [name, null]; }
}));

// MARK: - Signed values (no database)

const tokenKey = crypto.createHmac("sha256", SECRET).update("sill-relay/tokens/v1").digest();
const b64 = (buffer) => Buffer.from(buffer).toString("base64url");
const now = () => Math.floor(Date.now() / 1000);

function sign(kind, payload) {
  const body = b64(JSON.stringify({ ...payload, k: kind }));
  const mac = b64(crypto.createHmac("sha256", tokenKey).update(`${kind}.${body}`).digest());
  return `${kind}.${body}.${mac}`;
}

function verify(kind, token) {
  if (typeof token !== "string") return null;
  const [k, body, mac] = token.split(".");
  if (k !== kind || !body || !mac) return null;
  const expected = crypto.createHmac("sha256", tokenKey).update(`${kind}.${body}`).digest();
  const given = Buffer.from(mac, "base64url");
  if (given.length !== expected.length || !crypto.timingSafeEqual(given, expected)) return null;
  try {
    const payload = JSON.parse(Buffer.from(body, "base64url").toString("utf8"));
    if (payload.k !== kind) return null;
    if (payload.exp && payload.exp < now()) return null;
    return payload;
  } catch { return null; }
}

function sameSecret(given) {
  const a = crypto.createHash("sha256").update(String(given)).digest();
  const b = crypto.createHash("sha256").update(SECRET).digest();
  return crypto.timingSafeEqual(a, b);
}

// Codes are single use. Remembered only until they'd expire anyway.
const usedCodes = new Map();
function spendCode(jti) {
  const t = now();
  for (const [key, exp] of usedCodes) if (exp < t) usedCodes.delete(key);
  if (usedCodes.has(jti)) return false;
  usedCodes.set(jti, t + CODE_TTL);
  return true;
}

// MARK: - The Mac's line

let bridge = null;          // the connected WebSocket, if any
let bridgeSince = null;
let nextId = 1;
const pending = new Map();  // id → { resolve, reject, timer }
let toolsCache = null;      // last tools/list answer, for when the Mac drops off briefly
let notBefore = 0;          // sign-ins issued before this (seconds) are refused: Sill's "Sign out claude.ai"

function toBridge(message, timeout) {
  return new Promise((resolve, reject) => {
    if (!bridge || bridge.readyState !== 1) return reject(new Offline());
    const id = nextId++;
    const timer = setTimeout(() => {
      pending.delete(id);
      reject(new Error("Sill took too long to answer."));
    }, timeout);
    pending.set(id, { resolve, reject, timer });
    bridge.send(JSON.stringify({ ...message, id }));
  });
}

class Offline extends Error {
  constructor() { super("Sill isn't connected. Open Sill on your Mac and turn on Settings › Agents › “Let claude.ai control Sill”."); }
}

const wss = new WebSocketServer({ noServer: true, maxPayload: 64 * 1024 * 1024 });

wss.on("connection", (socket) => {
  if (bridge && bridge !== socket) bridge.close(4000, "Replaced by a newer connection from your Mac.");
  bridge = socket;
  bridgeSince = new Date();
  socket.isAlive = true;
  console.log("bridge: connected");

  socket.on("pong", () => { socket.isAlive = true; });
  socket.on("message", (data) => {
    let message;
    try { message = JSON.parse(data.toString("utf8")); } catch { return; }
    if (message.t === "hello") {
      notBefore = Math.max(notBefore, Number(message.notBefore) || 0);
      return;
    }
    const waiting = pending.get(message.id);
    if (!waiting) return;
    pending.delete(message.id);
    clearTimeout(waiting.timer);
    waiting.resolve(message);
  });
  socket.on("close", () => {
    if (bridge !== socket) return;
    bridge = null;
    bridgeSince = null;
    console.log("bridge: disconnected");
    for (const [id, waiting] of pending) {
      clearTimeout(waiting.timer);
      waiting.reject(new Offline());
      pending.delete(id);
    }
  });
});

// Keep the line warm through proxies, and notice a Mac that went to sleep.
setInterval(() => {
  for (const socket of wss.clients) {
    if (!socket.isAlive) { socket.terminate(); continue; }
    socket.isAlive = false;
    socket.ping();
  }
}, 20_000).unref();

// MARK: - HTTP plumbing

function baseURL(req) {
  if (FIXED_BASE) return FIXED_BASE;
  const proto = (req.headers["x-forwarded-proto"] ?? "http").split(",")[0].trim();
  const host = String(req.headers["x-forwarded-host"] ?? req.headers.host ?? "").split(",")[0].trim();
  // Only well-formed host names: the address ends up in OAuth metadata and redirects.
  if (!/^[a-z0-9.-]+(:\d+)?$/i.test(host)) return "https://sill-relay-production.up.railway.app";
  return `${proto === "https" || !/^(localhost|127\.0\.0\.1)/.test(host) ? "https" : "http"}://${host}`;
}

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, DELETE, OPTIONS",
  "Access-Control-Allow-Headers": "Authorization, Content-Type, Mcp-Protocol-Version, Mcp-Session-Id, Last-Event-ID",
  "Access-Control-Expose-Headers": "WWW-Authenticate, Mcp-Session-Id",
};

function send(res, status, body, headers = {}) {
  const isJSON = typeof body !== "string";
  res.writeHead(status, {
    ...CORS,
    "Content-Type": isJSON ? "application/json" : "text/html; charset=utf-8",
    "Cache-Control": "no-store",
    ...headers,
  });
  res.end(isJSON ? JSON.stringify(body) : body);
}

async function readBody(req, limit = 4 * 1024 * 1024) {
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > limit) throw new Error("Request too large.");
    chunks.push(chunk);
  }
  return Buffer.concat(chunks).toString("utf8");
}

async function readForm(req) {
  const text = await readBody(req);
  if ((req.headers["content-type"] ?? "").includes("application/json")) {
    try { return JSON.parse(text); } catch { return {}; }
  }
  return Object.fromEntries(new URLSearchParams(text));
}

const escapeHTML = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);

function page(title, body, script = "") {
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>${escapeHTML(title)}</title>
<link rel="icon" type="image/png" sizes="96x96" href="/favicon-96.png"><link rel="icon" type="image/png" sizes="192x192" href="/favicon-192.png"><link rel="icon" type="image/png" sizes="64x64" href="/favicon.png"><link rel="apple-touch-icon" href="/apple-touch-icon.png">
<style>
:root{color-scheme:light dark}
body{font:15px/1.45 -apple-system,BlinkMacSystemFont,system-ui,sans-serif;margin:0;min-height:100vh;display:grid;place-items:center;background:Canvas;color:CanvasText}
main{max-width:380px;padding:32px;text-align:center}
h1{font-size:20px;font-weight:600;margin:0 0 8px}
p{margin:0 0 6px;opacity:.75}
.host{font-weight:600;opacity:1}
.spin{width:22px;height:22px;margin:20px auto 0;border:2.5px solid color-mix(in srgb,CanvasText 18%,transparent);border-top-color:CanvasText;border-radius:50%;animation:s .8s linear infinite}
@keyframes s{to{transform:rotate(1turn)}}
</style></head><body><main>${body}</main>${script ? `<script>${script}</script>` : ""}</body></html>`;
}

// MARK: - OAuth

function resourceMetadata(base) {
  return {
    resource: `${base}/mcp`,
    authorization_servers: [base],
    scopes_supported: [SCOPE],
    bearer_methods_supported: ["header"],
    resource_name: "Sill",
  };
}

function authServerMetadata(base) {
  return {
    issuer: base,
    authorization_endpoint: `${base}/authorize`,
    token_endpoint: `${base}/token`,
    registration_endpoint: `${base}/register`,
    response_types_supported: ["code"],
    grant_types_supported: ["authorization_code", "refresh_token"],
    code_challenge_methods_supported: ["S256"],
    token_endpoint_auth_methods_supported: ["none"],
    scopes_supported: [SCOPE],
  };
}

function okRedirect(uri) {
  try {
    const url = new URL(uri);
    if (url.hash) return false;
    if (url.protocol === "https:") return true;
    return url.protocol === "http:" && ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname);
  } catch { return false; }
}

async function register(req, res) {
  const body = await readForm(req);
  const uris = Array.isArray(body.redirect_uris) ? body.redirect_uris.filter((u) => typeof u === "string") : [];
  if (!uris.length || !uris.every(okRedirect)) {
    return send(res, 400, { error: "invalid_redirect_uri", error_description: "redirect_uris must be https (or http on localhost)." });
  }
  const name = typeof body.client_name === "string" ? body.client_name.slice(0, 80) : "";
  const issued = now();
  const clientId = sign("client", { r: uris, n: name, iat: issued });
  send(res, 201, {
    client_id: clientId,
    client_id_issued_at: issued,
    client_name: name || undefined,
    redirect_uris: uris,
    grant_types: ["authorization_code", "refresh_token"],
    response_types: ["code"],
    token_endpoint_auth_method: "none",
    scope: SCOPE,
  });
}

function authorizeError(res, title, detail) {
  send(res, 400, page(title, `<h1>${escapeHTML(title)}</h1><p>${escapeHTML(detail)}</p>`));
}

function authorize(req, res, url) {
  const q = Object.fromEntries(url.searchParams);
  const client = verify("client", q.client_id);
  if (!client) return authorizeError(res, "Unknown app", "This app isn't registered with your Sill relay. Remove the connector and add it again.");
  if (!q.redirect_uri || !client.r.includes(q.redirect_uri)) return authorizeError(res, "Wrong return address", "The app asked to return somewhere it didn't register.");
  if (q.response_type !== "code") return redirectError(res, q, "unsupported_response_type");
  if (!q.code_challenge || (q.code_challenge_method ?? "plain") !== "S256") return redirectError(res, q, "invalid_request", "PKCE with S256 is required.");

  const host = new URL(q.redirect_uri).host;
  const request = sign("ask", {
    c: q.client_id, r: q.redirect_uri, s: q.state ?? null, p: q.code_challenge,
    sc: q.scope ?? SCOPE, rs: q.resource ?? null, h: host, n: client.n || host, exp: now() + 10 * 60,
  });
  const body = `<h1 id="t">Allow in Sill</h1>
<p id="d"><span class="host">${escapeHTML(host)}</span> wants to control Sill.<br>Click <b>Allow</b> in the dialog on your Mac.</p>
<div class="spin" id="s"></div>`;
  const script = `
fetch(location.pathname + "/decide", {method: "POST", headers: {"Content-Type": "application/json"}, body: JSON.stringify({request: ${JSON.stringify(request)}})})
  .then(r => r.json()).then(a => {
    if (a.redirect) { location.replace(a.redirect); return; }
    document.getElementById("t").textContent = a.title || "Couldn't connect";
    document.getElementById("d").textContent = a.detail || "";
    document.getElementById("s").remove();
  }).catch(() => { document.getElementById("t").textContent = "Couldn't reach the relay"; document.getElementById("s").remove(); });`;
  send(res, 200, page("Allow in Sill", body, script), {
    "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'",
    "X-Frame-Options": "DENY",
  });
}

function redirectError(res, q, error, description) {
  const to = new URL(q.redirect_uri);
  to.searchParams.set("error", error);
  if (description) to.searchParams.set("error_description", description);
  if (q.state) to.searchParams.set("state", q.state);
  res.writeHead(302, { Location: to.toString() });
  res.end();
}

async function decide(req, res) {
  const body = await readForm(req);
  const ask = verify("ask", body.request);
  if (!ask) return send(res, 400, { title: "This sign-in expired", detail: "Start again from claude.ai." });

  let approved = false;
  try {
    const answer = await toBridge({ t: "approve", host: ask.h, client: ask.n }, APPROVAL_TIMEOUT);
    approved = answer.approved === true;
  } catch (error) {
    const offline = error instanceof Offline;
    return send(res, 200, {
      title: offline ? "Sill isn't connected" : "No answer from Sill",
      detail: offline ? "Open Sill on your Mac, turn on Settings › Agents › “Let claude.ai control Sill”, then try again."
                      : "Nobody clicked Allow on your Mac in time. Try again.",
    });
  }

  const to = new URL(ask.r);
  if (ask.s) to.searchParams.set("state", ask.s);
  if (!approved) {
    to.searchParams.set("error", "access_denied");
    to.searchParams.set("error_description", "Not allowed in Sill.");
  } else {
    const code = sign("code", { c: ask.c, r: ask.r, p: ask.p, sc: ask.sc, rs: ask.rs, j: crypto.randomUUID(), exp: now() + CODE_TTL });
    to.searchParams.set("code", code);
  }
  console.log(`authorize: ${ask.h} ${approved ? "allowed" : "denied"}`);
  send(res, 200, { redirect: to.toString() });
}

function issueTokens(clientId, scope, resource) {
  const access = sign("at", { c: clientId, sc: scope, rs: resource, iat: now(), exp: now() + ACCESS_TTL });
  const refresh = sign("rt", { c: clientId, sc: scope, rs: resource, j: crypto.randomUUID(), iat: now(), exp: now() + REFRESH_TTL });
  return { access_token: access, token_type: "Bearer", expires_in: ACCESS_TTL, refresh_token: refresh, scope };
}

async function token(req, res) {
  const body = await readForm(req);
  const fail = (error, description) => send(res, 400, { error, error_description: description });

  if (body.grant_type === "authorization_code") {
    const code = verify("code", body.code);
    if (!code) return fail("invalid_grant", "The code is invalid or expired.");
    if (body.client_id && body.client_id !== code.c) return fail("invalid_grant", "The code was issued to another client.");
    if (body.redirect_uri && body.redirect_uri !== code.r) return fail("invalid_grant", "redirect_uri doesn't match.");
    if (typeof body.code_verifier !== "string") return fail("invalid_request", "code_verifier is required.");
    const challenge = b64(crypto.createHash("sha256").update(body.code_verifier).digest());
    if (challenge !== code.p) return fail("invalid_grant", "PKCE check failed.");
    if (!spendCode(code.j)) return fail("invalid_grant", "The code was already used.");
    return send(res, 200, issueTokens(code.c, code.sc, code.rs));
  }

  if (body.grant_type === "refresh_token") {
    const refresh = verify("rt", body.refresh_token);
    if (!refresh || (refresh.iat ?? 0) < notBefore) return fail("invalid_grant", "The refresh token is invalid, expired or signed out.");
    if (body.client_id && body.client_id !== refresh.c) return fail("invalid_grant", "The token was issued to another client.");
    if (!verify("client", refresh.c)) return fail("invalid_client", "Unknown client.");
    return send(res, 200, issueTokens(refresh.c, refresh.sc, refresh.rs));
  }

  fail("unsupported_grant_type", "Use authorization_code or refresh_token.");
}

// MARK: - MCP (Streamable HTTP, JSON answers)

function unauthorized(req, res, description) {
  const meta = `${baseURL(req)}/.well-known/oauth-protected-resource/mcp`;
  send(res, 401, { error: "invalid_token", error_description: description }, {
    "WWW-Authenticate": `Bearer resource_metadata="${meta}", scope="${SCOPE}"`,
  });
}

function serverIdentity(base) {
  return { name: "sill", title: "Sill", websiteUrl: base,
           icons: [{ src: `${base}/icon.png`, mimeType: "image/png", sizes: ["512x512"] }] };
}

const fallbackInitialize = (params, base) => ({
  protocolVersion: params?.protocolVersion ?? "2025-06-18",
  capabilities: { tools: { listChanged: false } },
  serverInfo: { ...serverIdentity(base), version: "relay" },
  instructions: "Drives the Sill web browser on the user's Mac. Sill isn't connected right now: ask the user to open Sill.",
});

async function rpc(message, base) {
  const { id, method } = message;
  const isRequest = id !== undefined && id !== null;
  if (!isRequest) return null; // notifications: nothing to forward or answer

  try {
    const answer = await toBridge({ t: "rpc", msg: message }, CALL_TIMEOUT);
    const response = answer.msg ?? { jsonrpc: "2.0", id, error: { code: -32603, message: "Sill gave no answer." } };
    if (method === "tools/list" && response.result) toolsCache = response.result;
    if (method === "initialize" && response.result?.serverInfo) {
      response.result.serverInfo = { ...response.result.serverInfo, ...serverIdentity(base) };
    }
    if (method === "tools/call") console.log(`call: ${message.params?.name ?? "?"}${response.result?.isError ? " (error)" : ""}`);
    return { ...response, id };
  } catch (error) {
    const text = error.message;
    if (method === "initialize") return { jsonrpc: "2.0", id, result: fallbackInitialize(message.params, base) };
    if (method === "ping") return { jsonrpc: "2.0", id, result: {} };
    if (method === "tools/list" && toolsCache) return { jsonrpc: "2.0", id, result: toolsCache };
    if (method === "tools/call") return { jsonrpc: "2.0", id, result: { content: [{ type: "text", text }], isError: true } };
    return { jsonrpc: "2.0", id, error: { code: -32000, message: text } };
  }
}

async function mcp(req, res) {
  const auth = req.headers.authorization ?? "";
  const bearer = auth.startsWith("Bearer ") ? auth.slice(7).trim() : null;
  if (!bearer) return unauthorized(req, res, "Sign in first.");
  const access = verify("at", bearer);
  if (!access || !verify("client", access.c)) return unauthorized(req, res, "The token is invalid or expired.");
  if ((access.iat ?? 0) < notBefore) return unauthorized(req, res, "Signed out in Sill. Connect again.");

  if (req.method === "GET") return send(res, 405, { error: "This server answers POST requests with JSON; it has no event stream." }, { Allow: "POST" });
  if (req.method === "DELETE") return send(res, 405, { error: "No sessions to end." }, { Allow: "POST" });
  if (req.method !== "POST") return send(res, 405, { error: "POST only." }, { Allow: "POST" });

  let payload;
  try { payload = JSON.parse(await readBody(req)); } catch {
    return send(res, 400, { jsonrpc: "2.0", id: null, error: { code: -32700, message: "Parse error" } });
  }
  if (Array.isArray(payload)) {
    const base = baseURL(req);
    const answers = (await Promise.all(payload.map((m) => rpc(m, base)))).filter(Boolean);
    return answers.length ? send(res, 200, answers) : (res.writeHead(202, CORS), res.end());
  }
  const answer = await rpc(payload, baseURL(req));
  if (!answer) { res.writeHead(202, CORS); return res.end(); }
  send(res, 200, answer);
}

// MARK: - Routes

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, "http://relay");
  const path = url.pathname.replace(/\/+$/, "") || "/";
  try {
    if (req.method === "OPTIONS") { res.writeHead(204, CORS); return res.end(); }
    const base = baseURL(req);

    if (path.startsWith("/.well-known/oauth-protected-resource")) return send(res, 200, resourceMetadata(base));
    if (path.startsWith("/.well-known/oauth-authorization-server") || path.startsWith("/.well-known/openid-configuration")) {
      return send(res, 200, authServerMetadata(base));
    }
    if (path === "/register" && req.method === "POST") return await register(req, res);
    if (path === "/authorize" && req.method === "GET") return authorize(req, res, url);
    if (path === "/authorize/decide" && req.method === "POST") return await decide(req, res);
    if (path === "/token" && req.method === "POST") return await token(req, res);
    if (path === "/mcp") return await mcp(req, res);
    if (path === "/health") return send(res, 200, { ok: true, mac: Boolean(bridge) });
    // Google's favicon service (which claude.ai draws connector icons from) wants a size that's a multiple of 48.
    const icon = { "/favicon.ico": "favicon-96.png", "/favicon.png": "favicon.png", "/favicon-96.png": "favicon-96.png",
                   "/favicon-192.png": "favicon-192.png", "/icon.png": "icon.png",
                   "/apple-touch-icon.png": "apple-touch-icon.png" }[path];
    if (icon && ICONS[icon]) {
      res.writeHead(200, { ...CORS, "Content-Type": "image/png", "Cache-Control": "public, max-age=86400" });
      return res.end(ICONS[icon]);
    }
    if (path === "/robots.txt") {
      res.writeHead(200, { "Content-Type": "text/plain" });
      return res.end("User-agent: *\nAllow: /\n");
    }
    if (path === "/") {
      const state = bridge ? `Your Mac is connected (since ${bridgeSince.toISOString().slice(11, 16)} UTC).` : "Your Mac isn't connected.";
      return send(res, 200, page("Sill relay", `<h1>Sill relay</h1><p>${state}</p><p>Add <span class="host">${escapeHTML(base)}/mcp</span> as a custom connector in claude.ai.</p>`));
    }
    send(res, 404, { error: "Not found" });
  } catch (error) {
    console.error(`${req.method} ${path}: ${error.message}`);
    if (!res.headersSent) send(res, 500, { error: "server_error" });
  }
});

server.on("upgrade", (req, socket, head) => {
  const url = new URL(req.url, "http://relay");
  const auth = req.headers.authorization ?? "";
  if (url.pathname !== "/bridge" || !auth.startsWith("Bearer ") || !sameSecret(auth.slice(7).trim())) {
    socket.write("HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n");
    return socket.destroy();
  }
  wss.handleUpgrade(req, socket, head, (ws) => wss.emit("connection", ws, req));
});

server.headersTimeout = 30_000;
server.requestTimeout = CALL_TIMEOUT + 10_000;
server.listen(PORT, () => console.log(`sill relay on :${PORT}${FIXED_BASE ? ` as ${FIXED_BASE}` : ""}`));
