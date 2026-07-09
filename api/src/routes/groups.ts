import { Hono } from 'hono';
import { z } from 'zod';
import { getPool, withTransaction } from '../db/pool.js';
import type { AuthVariables } from '../middleware/auth.js';
import {
  acceptInvitation,
  createGroup,
  createInvitation,
} from '../services/groups.js';
import { ensureProfileFromAuth, upsertProfile } from '../services/profiles.js';
import { profileDisplayName } from '../lib/display-names.js';
import { HttpError, jsonError } from '../lib/errors.js';

export const groupsRoutes = new Hono<{ Variables: AuthVariables }>();

groupsRoutes.post('/', async (c) => {
  const userId = c.get('userId');
  const body = z.object({ displayName: z.string().min(1).max(100) }).parse(await c.req.json());

  const group = await withTransaction(async (client) => {
    await upsertProfile(client, userId, body.displayName);
    return createGroup(client, userId, body.displayName);
  });

  return c.json({ group }, 201);
});

groupsRoutes.get('/', async (c) => {
  const userId = c.get('userId');

  await withTransaction((client) => ensureProfileFromAuth(client, userId));

  const { rows } = await getPool().query(
    `SELECT g.id, g.status, g.created_at, g.activated_at,
            json_agg(json_build_object(
              'userId', gm.user_id,
              'role', gm.role,
              'displayName', ${profileDisplayName('p')},
              'joinedAt', gm.joined_at
            ) ORDER BY gm.role) AS members
     FROM groups g
     JOIN group_members gm ON gm.group_id = g.id
     LEFT JOIN profiles p ON p.user_id = gm.user_id
     WHERE g.id IN (SELECT group_id FROM group_members WHERE user_id = $1)
     GROUP BY g.id
     ORDER BY g.created_at DESC`,
    [userId],
  );
  return c.json({ groups: rows });
});

groupsRoutes.post('/:groupId/invitations', async (c) => {
  const userId = c.get('userId');
  const groupId = c.req.param('groupId');
  const body = z
    .object({
      role: z.enum(['parent_b', 'mediator_a', 'mediator_b']),
      email: z.string().email(),
    })
    .parse(await c.req.json());

  const invitation = await withTransaction((client) =>
    createInvitation(client, groupId, userId, body.role, body.email),
  );

  // TODO: send invitation email with deep link containing token
  return c.json({ invitation }, 201);
});

groupsRoutes.post('/invitations/:token/accept', async (c) => {
  const userId = c.get('userId');
  const token = c.req.param('token');
  const body = z.object({ displayName: z.string().min(1).max(100) }).parse(await c.req.json());

  try {
    const result = await withTransaction((client) =>
      acceptInvitation(client, token, userId, body.displayName),
    );
    return c.json(result);
  } catch (err) {
    if (err instanceof HttpError) return jsonError(c, err);
    throw err;
  }
});
