import type pg from 'pg';
import { randomBytes } from 'node:crypto';
import { wsHub } from '../ws/hub.js';
import { HttpError } from '../lib/errors.js';

export async function assertGroupMember(
  client: pg.PoolClient,
  groupId: string,
  userId: string,
): Promise<void> {
  const { rows } = await client.query(
    `SELECT 1 FROM group_members WHERE group_id = $1 AND user_id = $2`,
    [groupId, userId],
  );
  if (rows.length === 0) {
    throw new HttpError(403, 'Not a group member');
  }
}

export async function getGroupMemberIds(
  client: pg.PoolClient,
  groupId: string,
): Promise<string[]> {
  const { rows } = await client.query<{ user_id: string }>(
    `SELECT user_id FROM group_members WHERE group_id = $1`,
    [groupId],
  );
  return rows.map((r) => r.user_id);
}

export async function createGroup(
  client: pg.PoolClient,
  userId: string,
  displayName: string,
): Promise<{ id: string; status: string }> {
  const { rows } = await client.query<{ id: string; status: string }>(
    `INSERT INTO groups (created_by) VALUES ($1)
     RETURNING id, status::text`,
    [userId],
  );
  const group = rows[0];

  await client.query(
    `INSERT INTO group_members (group_id, user_id, role) VALUES ($1, $2, 'parent_a')`,
    [group.id, userId],
  );

  await client.query(
    `INSERT INTO profiles (user_id, display_name)
     VALUES ($1, $2)
     ON CONFLICT (user_id) DO UPDATE SET display_name = EXCLUDED.display_name, updated_at = now()`,
    [userId, displayName],
  );

  return group;
}

export async function createInvitation(
  client: pg.PoolClient,
  groupId: string,
  invitedBy: string,
  role: 'parent_b' | 'mediator_a' | 'mediator_b',
  email: string,
): Promise<{ id: string; token: string; expiresAt: string }> {
  await assertGroupMember(client, groupId, invitedBy);

  const token = randomBytes(32).toString('hex');
  const { rows } = await client.query<{ id: string; expires_at: Date }>(
    `INSERT INTO invitations (group_id, invited_by, role, email, token, expires_at)
     VALUES ($1, $2, $3, $4, $5, now() + interval '7 days')
     RETURNING id, expires_at`,
    [groupId, invitedBy, role, email.toLowerCase(), token],
  );

  return {
    id: rows[0].id,
    token,
    expiresAt: rows[0].expires_at.toISOString(),
  };
}

export async function acceptInvitation(
  client: pg.PoolClient,
  token: string,
  userId: string,
  displayName: string,
): Promise<{ groupId: string; role: string }> {
  const { rows: invites } = await client.query<{
    id: string;
    group_id: string;
    role: string;
    status: string;
    expires_at: Date;
  }>(
    `SELECT id, group_id, role::text, status::text, expires_at
     FROM invitations WHERE token = $1 FOR UPDATE`,
    [token],
  );

  const invite = invites[0];
  if (!invite) throw new HttpError(404, 'Invitation not found');
  if (invite.status !== 'pending') throw new HttpError(400, 'Invitation already used');
  if (invite.expires_at < new Date()) throw new HttpError(400, 'Invitation expired');

  await client.query(
    `INSERT INTO profiles (user_id, display_name)
     VALUES ($1, $2)
     ON CONFLICT (user_id) DO UPDATE SET display_name = EXCLUDED.display_name, updated_at = now()`,
    [userId, displayName],
  );

  await client.query(
    `INSERT INTO group_members (group_id, user_id, role) VALUES ($1, $2, $3)`,
    [invite.group_id, userId, invite.role],
  );

  await client.query(
    `UPDATE invitations SET status = 'accepted', accepted_at = now() WHERE id = $1`,
    [invite.id],
  );

  return { groupId: invite.group_id, role: invite.role };
}

export async function sendMessage(
  client: pg.PoolClient,
  conversationId: string,
  senderId: string,
  body: string,
  clientId: string,
  parentId?: string,
  rootId?: string,
): Promise<unknown> {
  const { rows: convRows } = await client.query<{ group_id: string; status: string }>(
    `SELECT c.group_id, g.status::text
     FROM conversations c
     JOIN groups g ON g.id = c.group_id
     WHERE c.id = $1`,
    [conversationId],
  );
  const conv = convRows[0];
  if (!conv) throw new HttpError(404, 'Conversation not found');
  if (conv.status !== 'active') throw new HttpError(403, 'Group is not active');

  await assertGroupMember(client, conv.group_id, senderId);

  const { rows: existing } = await client.query(
    `SELECT id, conversation_id, sender_id, parent_id, root_id, body, client_id,
            deleted_at, created_at, edited_at
     FROM messages
     WHERE conversation_id = $1 AND sender_id = $2 AND client_id = $3`,
    [conversationId, senderId, clientId],
  );
  if (existing[0]) return existing[0];

  const { rows: inserted } = await client.query(
    `INSERT INTO messages (conversation_id, sender_id, parent_id, root_id, body, client_id)
     VALUES ($1, $2, $3, $4, $5, $6)
     RETURNING id, conversation_id, sender_id, parent_id, root_id, body, client_id,
               deleted_at, created_at, edited_at`,
    [conversationId, senderId, parentId ?? null, rootId ?? null, body, clientId],
  );
  const message = inserted[0];

  const memberIds = await getGroupMemberIds(client, conv.group_id);
  const recipientIds = memberIds.filter((id) => id !== senderId);

  for (const recipientId of recipientIds) {
    await client.query(
      `INSERT INTO message_receipts (message_id, user_id) VALUES ($1, $2)`,
      [message.id, recipientId],
    );
    await client.query(
      `INSERT INTO notification_outbox (user_id, payload)
       VALUES ($1, $2)`,
      [
        recipientId,
        JSON.stringify({
          type: 'message.new',
          conversationId,
          messageId: message.id,
          senderId,
          preview: body.slice(0, 120),
        }),
      ],
    );
  }

  await client.query(
    `INSERT INTO message_events (message_id, event_type, actor_id)
     VALUES ($1, 'created', $2)`,
    [message.id, senderId],
  );

  await client.query(
    `UPDATE conversations SET last_message_at = now() WHERE id = $1`,
    [conversationId],
  );

  wsHub.sendToUsers(recipientIds, {
    type: 'message.new',
    conversationId,
    message,
  });

  return message;
}

export async function markConversationRead(
  client: pg.PoolClient,
  conversationId: string,
  userId: string,
  lastMessageId: string,
): Promise<void> {
  const { rows: convRows } = await client.query<{ group_id: string }>(
    `SELECT group_id FROM conversations WHERE id = $1`,
    [conversationId],
  );
  if (!convRows[0]) throw new HttpError(404, 'Conversation not found');
  await assertGroupMember(client, convRows[0].group_id, userId);

  const now = new Date().toISOString();

  await client.query(
    `INSERT INTO conversation_read_cursors (user_id, conversation_id, last_read_message_id, last_read_at)
     VALUES ($1, $2, $3, now())
     ON CONFLICT (user_id, conversation_id)
     DO UPDATE SET last_read_message_id = EXCLUDED.last_read_message_id, last_read_at = now()`,
    [userId, conversationId, lastMessageId],
  );

  const { rows: updated } = await client.query<{ message_id: string }>(
    `UPDATE message_receipts mr
     SET read_at = COALESCE(read_at, now())
     FROM messages m
     WHERE mr.message_id = m.id
       AND m.conversation_id = $1
       AND mr.user_id = $2
       AND mr.read_at IS NULL
       AND m.created_at <= (SELECT created_at FROM messages WHERE id = $3)
     RETURNING mr.message_id`,
    [conversationId, userId, lastMessageId],
  );

  const memberIds = await getGroupMemberIds(client, convRows[0].group_id);
  for (const row of updated) {
    wsHub.sendToUsers(
      memberIds.filter((id) => id !== userId),
      { type: 'message.read', messageId: row.message_id, userId, at: now },
    );
  }
}
