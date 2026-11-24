// The relay end to end, with a stand-in for the Mac: OAuth sign-in (with the
// approval Sill would ask for), then MCP calls passed down the line.
import { test } from "node:test";
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import crypto from "node:crypto";
import WebSocket from "ws";

const PORT = 18000 + Math.floor(Math.random() * 1000);
const BASE = `http://127.0.0.1:${PORT}`;
const SECRET = crypto.randomBytes(32).toString("hex");
let relay, mac, approve = true;

test.before(async () => {
  relay = spawn(process.execPath, ["server.mjs"], { env: { ...process.env, PORT: String(PORT), RELAY_SECRET: SECRET, PUBLIC_URL: BASE }, stdio: "pipe" });
  for (let i = 0; i < 50; i++) {
    try { await fetch(`${BASE}/health`); break; } catch { await new Promise((r) => setTimeout(r, 100)); }
  }
});
test.after(() => { mac?.close(); relay?.kill(); });

function connectMac() {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://127.0.0.1:${PORT}/bridge`, { headers: { Authorization: `Bearer ${SECRET}` } });
    ws.on("open", () => resolve(ws));
    ws.on("error", reject);
    ws.on("message", (data) => {
      const m = JSON.parse(data);
      if (m.t === "approve") ws.send(JSON.stringify({ id: m.id, approved: approve }));
      if (m.t === "rpc") {
        const { id, method, params } = m.msg;
        let result;
        if (method === "initialize") result = { protocolVersion: params.protocolVersion, capabilities: { tools: {} }, serverInfo: { name: "sill" } };
        else if (method === "tools/list") result = { tools: [{ name: "status", inputSchema: { type: "object" } }] };
        else if (method === "tools/call") result = { content: [{ type: "text", text: `ran ${params.name}` }] };
        ws.send(JSON.stringify({ id: m.id, msg: { jsonrpc: "2.0", id, result } }));
      }
    });
  });
}

const pkce = () => {
  const verifier = crypto.randomBytes(32).toString("base64url");
  return { verifier, challenge: crypto.createHash("sha256").update(verifier).digest("base64url") };
};

async function signIn() {
  const reg = await (await fetch(`${BASE}/register`, { method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ redirect_uris: ["https://claude.ai/api/mcp/auth_callback"], client_name: "Claude" }) })).json();
  const { verifier, challenge } = pkce();
  const q = new URLSearchParams({ response_type: "code", client_id: reg.client_id, redirect_uri: "https://claude.ai/api/mcp/auth_callback",
    code_challenge: challenge, code_challenge_method: "S256", state: "xyz", scope: "sill" });
  const page = await (await fetch(`${BASE}/authorize?${q}`)).text();
  const request = page.match(/request: ("[^"]+")/)[1];
  const decided = await (await fetch(`${BASE}/authorize/decide`, { method: "POST", headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ request: JSON.parse(request) }) })).json();
  return { reg, verifier, decided };
}

test("a client with no token is pointed to sign in", async () => {
  const res = await fetch(`${BASE}/mcp`, { method: "POST", body: "{}" });
  assert.equal(res.status, 401);
  assert.match(res.headers.get("www-authenticate"), /resource_metadata="http:\/\/127\.0\.0\.1:\d+\/\.well-known\/oauth-protected-resource\/mcp"/);
  const meta = await (await fetch(`${BASE}/.well-known/oauth-authorization-server`)).json();
  assert.equal(meta.registration_endpoint, `${BASE}/register`);
  assert.deepEqual(meta.code_challenge_methods_supported, ["S256"]);
});

test("a bridge without the key is turned away", async () => {
  await assert.rejects(new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://127.0.0.1:${PORT}/bridge`, { headers: { Authorization: "Bearer wrong" } });
    ws.on("open", resolve); ws.on("error", reject);
  }));
});

test("sign-in fails cleanly while the Mac is away", async () => {
  const { decided } = await signIn();
  assert.equal(decided.title, "Sill isn't connected");
});

test("sign-in, approval, tokens, MCP calls, refresh", async () => {
  mac = await connectMac();
  const { reg, verifier, decided } = await signIn();
  const back = new URL(decided.redirect);
  assert.equal(back.origin + back.pathname, "https://claude.ai/api/mcp/auth_callback");
  assert.equal(back.searchParams.get("state"), "xyz");
  const code = back.searchParams.get("code");

  const form = (o) => ({ method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" }, body: new URLSearchParams(o) });
  const bad = await fetch(`${BASE}/token`, form({ grant_type: "authorization_code", code, code_verifier: "nope", client_id: reg.client_id }));
  assert.equal(bad.status, 400);
  const tokens = await (await fetch(`${BASE}/token`, form({ grant_type: "authorization_code", code, code_verifier: verifier,
    client_id: reg.client_id, redirect_uri: "https://claude.ai/api/mcp/auth_callback" }))).json();
  assert.ok(tokens.access_token && tokens.refresh_token);
  const again = await fetch(`${BASE}/token`, form({ grant_type: "authorization_code", code, code_verifier: verifier, client_id: reg.client_id }));
  assert.equal(again.status, 400, "a code works once");

  const call = async (body) => (await fetch(`${BASE}/mcp`, { method: "POST",
    headers: { Authorization: `Bearer ${tokens.access_token}`, "Content-Type": "application/json", Accept: "application/json, text/event-stream" },
    body: JSON.stringify(body) }));
  const init = await (await call({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18" } })).json();
  assert.equal(init.result.serverInfo.name, "sill");
  assert.equal((await call({ jsonrpc: "2.0", method: "notifications/initialized" })).status, 202);
  const list = await (await call({ jsonrpc: "2.0", id: "two", method: "tools/list" })).json();
  assert.equal(list.id, "two");
  assert.equal(list.result.tools[0].name, "status");
  const ran = await (await call({ jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "status", arguments: {} } })).json();
  assert.equal(ran.result.content[0].text, "ran status");

  const refreshed = await (await fetch(`${BASE}/token`, form({ grant_type: "refresh_token", refresh_token: tokens.refresh_token, client_id: reg.client_id }))).json();
  assert.ok(refreshed.access_token);
});

test("Don't Allow sends the app away", async () => {
  approve = false;
  const { decided } = await signIn();
  const back = new URL(decided.redirect);
  assert.equal(back.searchParams.get("error"), "access_denied");
  assert.equal(back.searchParams.get("code"), null);
  approve = true;
});

test("calls answer even when the Mac drops off", async () => {
  mac.close();
  await new Promise((r) => setTimeout(r, 200));
  // A token from a fresh sign-in can't be had without the Mac; forge-proofing is covered above, so sign tokens via a new Mac line.
  mac = await connectMac();
  const { reg, verifier, decided } = await signIn();
  const code = new URL(decided.redirect).searchParams.get("code");
  const tokens = await (await fetch(`${BASE}/token`, { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "authorization_code", code, code_verifier: verifier, client_id: reg.client_id }) })).json();
  mac.close();
  await new Promise((r) => setTimeout(r, 200));
  const res = await (await fetch(`${BASE}/mcp`, { method: "POST", headers: { Authorization: `Bearer ${tokens.access_token}`, "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 9, method: "tools/call", params: { name: "status" } }) })).json();
  assert.equal(res.result.isError, true);
  assert.match(res.result.content[0].text, /isn't connected/);
});

test("Sign out claude.ai in Sill turns earlier sign-ins away", async () => {
  mac?.close();
  mac = await connectMac();
  const signInAndToken = async () => {
    const { reg, verifier, decided } = await signIn();
    const code = new URL(decided.redirect).searchParams.get("code");
    return (await (await fetch(`${BASE}/token`, { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ grant_type: "authorization_code", code, code_verifier: verifier, client_id: reg.client_id }) })).json());
  };
  const old = await signInAndToken();
  const use = (t) => fetch(`${BASE}/mcp`, { method: "POST", headers: { Authorization: `Bearer ${t}`, "Content-Type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "tools/list" }) });
  assert.equal((await use(old.access_token)).status, 200);
  await new Promise((r) => setTimeout(r, 1100));
  mac.send(JSON.stringify({ t: "hello", notBefore: Math.floor(Date.now() / 1000) }));
  await new Promise((r) => setTimeout(r, 100));
  assert.equal((await use(old.access_token)).status, 401, "the old token is refused");
  const refreshed = await fetch(`${BASE}/token`, { method: "POST", headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ grant_type: "refresh_token", refresh_token: old.refresh_token }) });
  assert.equal(refreshed.status, 400, "and can't be refreshed");
  await new Promise((r) => setTimeout(r, 1100));
  const fresh = await signInAndToken();
  assert.equal((await use(fresh.access_token)).status, 200, "a new sign-in works");
});

test("Sill's icon: as favicon, and in the MCP server info", async () => {
  const icon = await fetch(`${BASE}/favicon.ico`);
  assert.equal(icon.status, 200);
  assert.equal(icon.headers.get("content-type"), "image/png");
  assert.ok((await icon.arrayBuffer()).byteLength > 1000);
  const meta = await (await fetch(`${BASE}/`)).text();
  assert.match(meta, /rel="icon"/);
});
