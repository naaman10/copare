import { createMiddleware } from 'hono/factory';
import { createRemoteJWKSet, jwtVerify } from 'jose';
import { loadEnv } from '../env.js';

export type AuthVariables = {
  userId: string;
};

const env = loadEnv();
const jwksUrl = new URL('/.well-known/jwks.json', env.NEON_AUTH_BASE_URL);
const JWKS = createRemoteJWKSet(jwksUrl);
const issuer = new URL(env.NEON_AUTH_BASE_URL).origin;

export const authMiddleware = createMiddleware<{ Variables: AuthVariables }>(
  async (c, next) => {
    const header = c.req.header('Authorization');
    if (!header?.startsWith('Bearer ')) {
      return c.json({ error: 'Unauthorized' }, 401);
    }

    const token = header.slice('Bearer '.length);
    try {
      const { payload } = await jwtVerify(token, JWKS, { issuer });
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
