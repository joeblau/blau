import { DurableObject } from "cloudflare:workers";

interface Env {
  ROOMS: DurableObjectNamespace<RendezvousRoom>;
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
