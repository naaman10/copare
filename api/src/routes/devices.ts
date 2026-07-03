import { Hono } from 'hono';
import { z } from 'zod';
import { getPool } from '../db/pool.js';
import type { AuthVariables } from '../middleware/auth.js';

export const devicesRoutes = new Hono<{ Variables: AuthVariables }>();

devicesRoutes.post('/devices', async (c) => {
  const userId = c.get('userId');
  const body = z
    .object({
      token: z.string().min(1),
      platform: z.enum(['ios']).default('ios'),
    })
    .parse(await c.req.json());

  await getPool().query(
    `INSERT INTO device_tokens (user_id, token, platform, updated_at)
     VALUES ($1, $2, $3, now())
     ON CONFLICT (user_id, token)
     DO UPDATE SET updated_at = now()`,
    [userId, body.token, body.platform],
  );

  return c.json({ ok: true }, 201);
});

devicesRoutes.delete('/devices/:token', async (c) => {
  const userId = c.get('userId');
  const token = c.req.param('token');

  await getPool().query(
    `DELETE FROM device_tokens WHERE user_id = $1 AND token = $2`,
    [userId, token],
  );

  return c.json({ ok: true });
});
