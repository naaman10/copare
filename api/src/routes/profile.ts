import { Hono } from 'hono';
import { z } from 'zod';
import { getPool, withTransaction } from '../db/pool.js';
import type { AuthVariables } from '../middleware/auth.js';
import { ensureProfileFromAuth, upsertProfile } from '../services/profiles.js';
import { profileDisplayName } from '../lib/display-names.js';

export const profileRoutes = new Hono<{ Variables: AuthVariables }>();

profileRoutes.get('/profile', async (c) => {
  const userId = c.get('userId');

  const profile = await withTransaction(async (client) => {
    await ensureProfileFromAuth(client, userId);
    const { rows } = await client.query<{ display_name: string | null }>(
      `SELECT ${profileDisplayName()} AS display_name
       FROM profiles p
       WHERE p.user_id = $1`,
      [userId],
    );
    return rows[0];
  });

  return c.json({
    displayName: profile?.display_name ?? null,
  });
});

profileRoutes.put('/profile', async (c) => {
  const userId = c.get('userId');
  const body = z.object({ displayName: z.string().min(1).max(100) }).parse(await c.req.json());

  await withTransaction((client) => upsertProfile(client, userId, body.displayName));

  return c.json({ displayName: body.displayName.trim() });
});
