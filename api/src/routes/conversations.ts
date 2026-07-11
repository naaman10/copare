import { Hono } from 'hono';
import { z } from 'zod';
import { getPool, withTransaction } from '../db/pool.js';
import type { AuthVariables } from '../middleware/auth.js';
import { assertGroupMember } from '../services/groups.js';
import { listRecentConversations } from '../services/conversations.js';
import { HttpError, jsonError } from '../lib/errors.js';

export const conversationsRoutes = new Hono<{ Variables: AuthVariables }>();

conversationsRoutes.get('/conversations/recent', async (c) => {
  const userId = c.get('userId');
  const limit = Math.min(Number(c.req.query('limit') ?? 20), 50);

  const conversations = await withTransaction((client) =>
    listRecentConversations(client, userId, limit),
  );

  return c.json({ conversations });
});

conversationsRoutes.get('/groups/:groupId/conversations', async (c) => {
  const userId = c.get('userId');
  const groupId = c.req.param('groupId');

  await withTransaction(async (client) => {
    await assertGroupMember(client, groupId, userId);
  });

  const { rows } = await getPool().query(
    `SELECT id, group_id, title, created_by, last_message_at, created_at
     FROM conversations
     WHERE group_id = $1
     ORDER BY last_message_at DESC NULLS LAST, created_at DESC`,
    [groupId],
  );

  return c.json({ conversations: rows });
});

conversationsRoutes.post('/groups/:groupId/conversations', async (c) => {
  const userId = c.get('userId');
  const groupId = c.req.param('groupId');
  const body = z.object({ title: z.string().min(1).max(200) }).parse(await c.req.json());

  const conversation = await withTransaction(async (client) => {
    await assertGroupMember(client, groupId, userId);

    const { rows: groupRows } = await client.query<{ status: string }>(
      `SELECT status::text FROM groups WHERE id = $1`,
      [groupId],
    );
    if (groupRows[0]?.status !== 'active') {
      throw new HttpError(403, 'Group must be active to create conversations');
    }

    const { rows } = await client.query(
      `INSERT INTO conversations (group_id, title, created_by)
       VALUES ($1, $2, $3)
       RETURNING id, group_id, title, created_by, last_message_at, created_at`,
      [groupId, body.title, userId],
    );
    return rows[0];
  });

  return c.json({ conversation }, 201);
});
