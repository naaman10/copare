import { Hono } from 'hono';
import { z } from 'zod';
import { getPool, withTransaction } from '../db/pool.js';
import type { AuthVariables } from '../middleware/auth.js';
import {
  assertGroupMember,
  markConversationRead,
  markMessageDelivered,
  sendMessage,
} from '../services/groups.js';
import { HttpError, jsonError } from '../lib/errors.js';
import { wsHub } from '../ws/hub.js';

export const messagesRoutes = new Hono<{ Variables: AuthVariables }>();

messagesRoutes.get('/conversations/:conversationId/messages', async (c) => {
  const userId = c.get('userId');
  const conversationId = c.req.param('conversationId');
  const limit = Math.min(Number(c.req.query('limit') ?? 50), 100);
  const before = c.req.query('before');
  const rootId = c.req.query('rootId');

  try {
    await withTransaction(async (client) => {
      const { rows } = await client.query<{ group_id: string }>(
        `SELECT group_id FROM conversations WHERE id = $1`,
        [conversationId],
      );
      if (!rows[0]) throw new HttpError(404, 'Conversation not found');
      await assertGroupMember(client, rows[0].group_id, userId);
    });
  } catch (err) {
    if (err instanceof HttpError) return jsonError(c, err);
    throw err;
  }

  const params: unknown[] = [conversationId];
  let sql = `
    SELECT m.id, m.conversation_id, m.sender_id, m.parent_id, m.root_id,
           m.body, m.client_id, m.deleted_at, m.created_at, m.edited_at,
           MAX(COALESCE(NULLIF(TRIM(p.display_name), ''), NULLIF(TRIM(sender_auth.name), ''), sender_auth.email)) AS sender_display_name,
           COALESCE(
             (
               SELECT json_agg(
                 json_build_object(
                   'userId', mr.user_id,
                   'displayName', COALESCE(NULLIF(TRIM(rp.display_name), ''), NULLIF(TRIM(ru.name), ''), ru.email),
                   'deliveredAt', mr.delivered_at,
                   'readAt', mr.read_at
                 )
                 ORDER BY rp.display_name
               )
               FROM message_receipts mr
               LEFT JOIN profiles rp ON rp.user_id = mr.user_id
               LEFT JOIN neon_auth."user" ru ON ru.id = mr.user_id
               WHERE mr.message_id = m.id
             ),
             '[]'
           ) AS receipts
    FROM messages m
    LEFT JOIN profiles p ON p.user_id = m.sender_id
    LEFT JOIN neon_auth."user" sender_auth ON sender_auth.id = m.sender_id
    WHERE m.conversation_id = $1 AND m.deleted_at IS NULL`;

  if (rootId) {
    params.push(rootId);
    sql += ` AND m.root_id = $${params.length}`;
  } else {
    sql += ` AND m.root_id IS NULL`;
  }

  if (before) {
    params.push(before);
    sql += ` AND m.created_at < $${params.length}::timestamptz`;
  }

  params.push(limit);
  sql += `
    GROUP BY m.id
    ORDER BY m.created_at DESC
    LIMIT $${params.length}`;

  const { rows } = await getPool().query(sql, params);
  return c.json({ messages: rows });
});

messagesRoutes.post('/conversations/:conversationId/messages', async (c) => {
  const userId = c.get('userId');
  const conversationId = c.req.param('conversationId');
  const body = z
    .object({
      body: z.string().min(1).max(10000),
      clientId: z.string().uuid(),
      parentId: z.string().uuid().optional(),
      rootId: z.string().uuid().optional(),
    })
    .parse(await c.req.json());

  try {
    const message = await withTransaction((client) =>
      sendMessage(
        client,
        conversationId,
        userId,
        body.body,
        body.clientId,
        body.parentId,
        body.rootId,
      ),
    );
    return c.json({ message }, 201);
  } catch (err) {
    if (err instanceof HttpError) return jsonError(c, err);
    throw err;
  }
});

messagesRoutes.put('/conversations/:conversationId/read', async (c) => {
  const userId = c.get('userId');
  const conversationId = c.req.param('conversationId');
  const body = z
    .object({
      lastMessageId: z.string().uuid().optional(),
      lastActionId: z.string().uuid().optional(),
    })
    .refine((data) => data.lastMessageId || data.lastActionId, {
      message: 'Provide lastMessageId and/or lastActionId',
    })
    .parse(await c.req.json());

  try {
    await withTransaction((client) =>
      markConversationRead(
        client,
        conversationId,
        userId,
        body.lastMessageId,
        body.lastActionId,
      ),
    );
    return c.json({ ok: true });
  } catch (err) {
    if (err instanceof HttpError) return jsonError(c, err);
    throw err;
  }
});

messagesRoutes.post('/messages/:messageId/delivered', async (c) => {
  const userId = c.get('userId');
  const messageId = c.req.param('messageId');

  const result = await withTransaction((client) =>
    markMessageDelivered(client, messageId, userId),
  );

  if (result.deliveredAt) {
    const { rows: members } = await getPool().query<{ user_id: string }>(
      `SELECT user_id FROM group_members WHERE group_id = $1`,
      [result.groupId],
    );
    wsHub.sendToUsers(
      members.map((m) => m.user_id).filter((id) => id !== userId),
      { type: 'message.delivered', messageId, userId, at: result.deliveredAt },
    );
  }

  return c.json({ deliveredAt: result.deliveredAt });
});
