import { DurableObject } from "cloudflare:workers";
import { SignalingRoom } from "./signaling";

export { SignalingRoom };

interface Env {
  ROOMS: DurableObjectNamespace<RendezvousRoom>;
  SIGNALS: DurableObjectNamespace<SignalingRoom>;
}

/** Reject obviously-oversized request bodies before parsing (anti-DoS). */
const MAX_BODY_BYTES = 4 * 1024;

/** base64 (std + url-safe), used to sanity-check the public key field. */
const BASE64_RE = /^[A-Za-z0-9+/=_-]+$/;

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

/**
 * A pairing room. Up to two peers connect to the same room (keyed by a shared
 * pairing code) and the room relays every message from one to the other. It is
 * payload-agnostic: it forwards the apps' length-prefixed frame bytes (binary)
 * and JSON sync messages (binary or text) without interpreting them.
 *
 * The relay injects its own control frames as JSON text of the shape
 * `{"type":"peer-joined"|"peer-left"}` so a client can tell when its peer is
 * actually present. Send peer media/sync payloads as BINARY so they never
 * collide with these text control frames.
 */
export class RendezvousRoom extends DurableObject<Env> {
  async fetch(request: Request): Promise<Response> {
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return new Response("Expected a WebSocket upgrade", { status: 426 });
    }
    // Two peers per room; reject a third so a leaked code can't snoop a pair.
    if (this.ctx.getWebSockets().length >= 2) {
      return new Response("Room is full", { status: 409 });
    }

    const { 0: client, 1: server } = new WebSocketPair();
    // Hibernatable accept: the DO can evict from memory while sockets idle and
    // is re-created to run webSocketMessage/Close/Error.
    this.ctx.acceptWebSocket(server);

    // Once both peers are present, tell each the pair is complete.
    if (this.ctx.getWebSockets().length === 2) {
      this.broadcastControl({ type: "peer-joined" });
    }

    return new Response(null, { status: 101, webSocket: client });
  }

  webSocketMessage(sender: WebSocket, message: ArrayBuffer | string): void {
    for (const ws of this.ctx.getWebSockets()) {
      if (ws === sender) continue;
      try {
        ws.send(message);
      } catch {
        // Peer vanished mid-send; its own close handler cleans up.
      }
    }
  }

  webSocketClose(sender: WebSocket): void {
    for (const ws of this.ctx.getWebSockets()) {
      if (ws === sender) continue;
      try {
        ws.send(JSON.stringify({ type: "peer-left" }));
      } catch {
        // ignore
      }
    }
  }

  webSocketError(sender: WebSocket): void {
    this.webSocketClose(sender);
  }

  private broadcastControl(message: Record<string, unknown>): void {
    const text = JSON.stringify(message);
    for (const ws of this.ctx.getWebSockets()) {
      try {
        ws.send(text);
      } catch {
        // ignore
      }
    }
  }
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/healthz") {
      return new Response("ok\n", { headers: { "content-type": "text/plain" } });
    }

    // --- Signaling / rendezvous for UDP hole punching (issue #51) ---------
    if (url.pathname === "/register" && request.method === "POST") {
      return handleRegister(request, env);
    }
    if (url.pathname === "/get-peer" && request.method === "GET") {
      return handleGetPeer(url, env);
    }

    // Pairing code from /room/<code> or ?room=<code>.
    const segments = url.pathname.split("/").filter(Boolean);
    const code =
      url.searchParams.get("room") ??
      (segments[0] === "room" ? segments[1] : undefined);

    if (!code) {
      return new Response("Missing room code. Use wss://<host>/room/<code>\n", {
        status: 400,
      });
    }

    // Same code -> same Durable Object instance -> the two peers meet.
    const id = env.ROOMS.idFromName(code);
    return env.ROOMS.get(id).fetch(request);
  },
} satisfies ExportedHandler<Env>;

/** Route a token to its dedicated signaling Durable Object instance. */
function signalingStub(env: Env, token: string) {
  return env.SIGNALS.get(env.SIGNALS.idFromName(token));
}

/**
 * POST /register
 * Body: { token, publicKey (base64), port }
 * Records { publicKey, ip (observed), port } under the token. The peer's IP is
 * taken from CF-Connecting-IP, never trusted from the body.
 */
async function handleRegister(request: Request, env: Env): Promise<Response> {
  const length = Number(request.headers.get("content-length") ?? "0");
  if (length > MAX_BODY_BYTES) {
    return json({ error: "body too large" }, 413);
  }

  let raw: string;
  try {
    raw = await request.text();
  } catch {
    return json({ error: "unreadable body" }, 400);
  }
  if (raw.length > MAX_BODY_BYTES) {
    return json({ error: "body too large" }, 413);
  }

  let body: unknown;
  try {
    body = JSON.parse(raw);
  } catch {
    return json({ error: "invalid JSON" }, 400);
  }

  if (typeof body !== "object" || body === null) {
    return json({ error: "expected JSON object" }, 400);
  }
  const { token, publicKey, port } = body as Record<string, unknown>;

  if (typeof token !== "string" || token.length === 0 || token.length > 256) {
    return json({ error: "invalid token" }, 400);
  }
  if (
    typeof publicKey !== "string" ||
    publicKey.length === 0 ||
    publicKey.length > 256 ||
    !BASE64_RE.test(publicKey)
  ) {
    return json({ error: "invalid publicKey" }, 400);
  }
  if (
    typeof port !== "number" ||
    !Number.isInteger(port) ||
    port < 1 ||
    port > 65535
  ) {
    return json({ error: "invalid port" }, 400);
  }

  // The edge observes the real source IP; the device cannot spoof its endpoint.
  const ip =
    request.headers.get("CF-Connecting-IP") ??
    request.headers.get("x-real-ip") ??
    "";

  const peer = await signalingStub(env, token).register({ publicKey, ip, port });
  if (peer === null) {
    return json({ error: "token pair is full" }, 409);
  }

  return json({ publicKey: peer.publicKey, ip: peer.ip, port: peer.port });
}

/**
 * GET /get-peer?token=&publicKey=
 * Returns { publicKey, ip, port } of the OTHER peer in the token's pair, or
 * 204 No Content until that peer has registered.
 */
async function handleGetPeer(url: URL, env: Env): Promise<Response> {
  const token = url.searchParams.get("token") ?? "";
  const publicKey = url.searchParams.get("publicKey") ?? "";

  if (token.length === 0 || token.length > 256) {
    return json({ error: "invalid token" }, 400);
  }
  if (
    publicKey.length === 0 ||
    publicKey.length > 256 ||
    !BASE64_RE.test(publicKey)
  ) {
    return json({ error: "invalid publicKey" }, 400);
  }

  const peer = await signalingStub(env, token).getPeer(publicKey);
  if (peer === null) {
    return new Response(null, { status: 204 });
  }

  return json({ publicKey: peer.publicKey, ip: peer.ip, port: peer.port });
}
