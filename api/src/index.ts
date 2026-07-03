import { serve } from '@hono/node-server';
import { createNodeWebSocket } from '@hono/node-ws';
import { Hono } from 'hono';
import { cors } from 'hono/cors';
import { jwtVerify, createRemoteJWKSet } from 'jose';
import { loadEnv } from './env.js';
import { authMiddleware } from './middleware/auth.js';
import { groupsRoutes } from './routes/groups.js';
import { conversationsRoutes } from './routes/conversations.js';
import { messagesRoutes } from './routes/messages.js';
import { devicesRoutes } from './routes/devices.js';
import { wsHub } from './ws/hub.js';

const env = loadEnv();
const jwksUrl = new URL('/.well-known/jwks.json', env.NEON_AUTH_BASE_URL);
const JWKS = createRemoteJWKSet(jwksUrl);
const issuer = new URL(env.NEON_AUTH_BASE_URL).origin;

const app = new Hono();

app.use('*', cors());

app.get('/health', (c) => c.json({ status: 'ok' }));

const api = new Hono();
api.use('*', authMiddleware);
api.route('/groups', groupsRoutes);
api.route('/', conversationsRoutes);
api.route('/', messagesRoutes);
api.route('/', devicesRoutes);

app.route('/v1', api);

const { injectWebSocket, upgradeWebSocket } = createNodeWebSocket({ app });

app.get(
  '/ws',
  upgradeWebSocket(async (c) => {
    const token = c.req.query('token');
    if (!token) {
      return { onOpen: (_e, ws) => ws.close(4401, 'Missing token') };
    }

    let userId: string;
    try {
      const { payload } = await jwtVerify(token, JWKS, { issuer });
      if (!payload.sub) throw new Error('no sub');
      userId = payload.sub;
    } catch {
      return { onOpen: (_e, ws) => ws.close(4401, 'Invalid token') };
    }

    return {
      onOpen: (_e, ws) => {
        wsHub.add(userId, ws);
        ws.send(JSON.stringify({ type: 'connected', userId }));
      },
      onClose: (_e, ws) => {
        wsHub.remove(userId, ws);
      },
      onMessage: (e, ws) => {
        if (e.data === 'ping') ws.send('pong');
      },
    };
  }),
);

const server = serve({ fetch: app.fetch, port: env.PORT }, (info) => {
  console.log(`Copare API listening on http://localhost:${info.port}`);
});

injectWebSocket(server);

process.on('SIGTERM', () => {
  console.log('SIGTERM received, shutting down…');
  server.close(() => process.exit(0));
});
