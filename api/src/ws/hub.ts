import type { WSContext } from 'hono/ws';

export type WsEvent =
  | { type: 'message.new'; conversationId: string; message: unknown }
  | { type: 'message.delivered'; messageId: string; userId: string; at: string }
  | { type: 'message.read'; messageId: string; userId: string; at: string }
  | { type: 'action.new'; conversationId: string; action: unknown }
  | { type: 'action.updated'; conversationId: string; action: unknown }
  | { type: 'action.delivered'; actionId: string; userId: string; at: string }
  | { type: 'action.read'; actionId: string; userId: string; at: string }
  | { type: 'ping' };

type Client = {
  userId: string;
  ws: WSContext;
};

/** In-memory fan-out. Add Redis pub/sub when scaling beyond one API instance. */
class WsHub {
  private clients = new Map<string, Set<Client>>();

  add(userId: string, ws: WSContext): void {
    const client: Client = { userId, ws };
    let set = this.clients.get(userId);
    if (!set) {
      set = new Set();
      this.clients.set(userId, set);
    }
    set.add(client);
  }

  remove(userId: string, ws: WSContext): void {
    const set = this.clients.get(userId);
    if (!set) return;
    for (const client of set) {
      if (client.ws === ws) set.delete(client);
    }
    if (set.size === 0) this.clients.delete(userId);
  }

  sendToUser(userId: string, event: WsEvent): void {
    const set = this.clients.get(userId);
    if (!set) return;
    const data = JSON.stringify(event);
    for (const { ws } of set) {
      try {
        ws.send(data);
      } catch {
        // client disconnected
      }
    }
  }

  sendToUsers(userIds: string[], event: WsEvent): void {
    for (const userId of userIds) {
      this.sendToUser(userId, event);
    }
  }
}

export const wsHub = new WsHub();
