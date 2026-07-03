import { createMiddleware } from 'hono/factory';
import { jwtVerify } from 'jose';
import { neonAuthIssuer, neonAuthJWKS } from '../lib/neon-auth.js';

export type AuthVariables = {
  userId: string;
};

export const authMiddleware = createMiddleware<{ Variables: AuthVariables }>(
  async (c, next) => {
    const header = c.req.header('Authorization');
    if (!header?.startsWith('Bearer ')) {
      return c.json({ error: 'Unauthorized' }, 401);
    }

    const token = header.slice('Bearer '.length);
    try {
      const { payload } = await jwtVerify(token, neonAuthJWKS, { issuer: neonAuthIssuer });
      if (!payload.sub) {
        return c.json({ error: 'Invalid token' }, 401);
      }
      c.set('userId', payload.sub);
      await next();
    } catch {
      return c.json({ error: 'Invalid token' }, 401);
    }
  },
);
