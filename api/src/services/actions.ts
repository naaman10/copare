import type pg from 'pg';
import { wsHub } from '../ws/hub.js';
import { HttpError } from '../lib/errors.js';
import { assertGroupMember, getGroupMemberIds } from './groups.js';
import {
  createActionReceipts,
  logActionEvent,
} from './audit.js';

const ACTION_SELECT = `
  SELECT ca.id, ca.conversation_id, ca.group_id,
         ca.action_type::text, ca.status::text,
         ca.statement, ca.response_note,
         ca.created_by, ca.assigned_to, ca.resolved_by,
         ca.created_at, ca.resolved_at,
         MAX(creator.display_name) AS created_by_display_name,
         MAX(assignee.display_name) AS assigned_to_display_name,
         MAX(resolver.display_name) AS resolved_by_display_name,
         COALESCE(
           (
             SELECT json_agg(
               json_build_object(
                 'userId', ar.user_id,
                 'displayName', rp.display_name,
                 'deliveredAt', ar.delivered_at,
                 'readAt', ar.read_at
               )
               ORDER BY rp.display_name
             )
             FROM action_receipts ar
             LEFT JOIN profiles rp ON rp.user_id = ar.user_id
             WHERE ar.action_id = ca.id
           ),
           '[]'
         ) AS receipts
  FROM conversation_actions ca
  LEFT JOIN profiles creator ON creator.user_id = ca.created_by
  LEFT JOIN profiles assignee ON assignee.user_id = ca.assigned_to
  LEFT JOIN profiles resolver ON resolver.user_id = ca.resolved_by`;

export async function assertParentMember(
  client: pg.PoolClient,
  groupId: string,
  userId: string,
): Promise<'parent_a' | 'parent_b'> {
  const { rows } = await client.query<{ role: string }>(
    `SELECT role::text FROM group_members WHERE group_id = $1 AND user_id = $2`,
    [groupId, userId],
  );
  const role = rows[0]?.role;
  if (role !== 'parent_a' && role !== 'parent_b') {
    throw new HttpError(403, 'Only parents can perform this action');
  }
  return role;
}

export async function getCoparentUserId(
  client: pg.PoolClient,
  groupId: string,
  userId: string,
): Promise<string> {
  const role = await assertParentMember(client, groupId, userId);
  const coparentRole = role === 'parent_a' ? 'parent_b' : 'parent_a';

  const { rows } = await client.query<{ user_id: string }>(
    `SELECT user_id FROM group_members WHERE group_id = $1 AND role = $2`,
    [groupId, coparentRole],
  );
  const coparentId = rows[0]?.user_id;
  if (!coparentId) {
    throw new HttpError(409, 'Co-parent has not joined this group yet');
  }
  return coparentId;
}

async function getConversationContext(
  client: pg.PoolClient,
  conversationId: string,
): Promise<{ groupId: string; title: string; status: string }> {
  const { rows } = await client.query<{
    group_id: string;
    title: string;
    status: string;
  }>(
    `SELECT c.group_id, c.title, g.status::text
     FROM conversations c
     JOIN groups g ON g.id = c.group_id
     WHERE c.id = $1`,
    [conversationId],
  );
  const conv = rows[0];
  if (!conv) throw new HttpError(404, 'Conversation not found');
  return { groupId: conv.group_id, title: conv.title, status: conv.status };
}

async function fetchActionById(
  client: pg.PoolClient,
  actionId: string,
): Promise<Record<string, unknown>> {
  const { rows } = await client.query(
    `${ACTION_SELECT} WHERE ca.id = $1 GROUP BY ca.id`,
    [actionId],
  );
  if (!rows[0]) throw new HttpError(404, 'Action not found');
  return rows[0];
}

export async function listConversationActions(
  client: pg.PoolClient,
  conversationId: string,
  userId: string,
): Promise<unknown[]> {
  const conv = await getConversationContext(client, conversationId);
  await assertGroupMember(client, conv.groupId, userId);

  const { rows } = await client.query(
    `${ACTION_SELECT}
     WHERE ca.conversation_id = $1
     GROUP BY ca.id
     ORDER BY ca.created_at ASC`,
    [conversationId],
  );
  return rows;
}

export async function createConfirmationRequest(
  client: pg.PoolClient,
  conversationId: string,
  userId: string,
  statement: string,
): Promise<unknown> {
  const conv = await getConversationContext(client, conversationId);
  if (conv.status !== 'active') {
    throw new HttpError(403, 'Group is not active');
  }

  await assertParentMember(client, conv.groupId, userId);
  const assignedTo = await getCoparentUserId(client, conv.groupId, userId);

  const { rows: creatorRows } = await client.query<{ display_name: string }>(
    `SELECT display_name FROM profiles WHERE user_id = $1`,
    [userId],
  );
  const creatorDisplayName = creatorRows[0]?.display_name ?? 'Someone';

  const { rows: inserted } = await client.query<{ id: string }>(
    `INSERT INTO conversation_actions (
       conversation_id, group_id, created_by, assigned_to,
       action_type, statement
     ) VALUES ($1, $2, $3, $4, 'confirmation_request', $5)
     RETURNING id`,
    [conversationId, conv.groupId, userId, assignedTo, statement],
  );

  const actionId = inserted[0].id;
  const memberIds = await getGroupMemberIds(client, conv.groupId);
  await createActionReceipts(client, actionId, memberIds, userId);
  await logActionEvent(client, actionId, 'created', userId, { statement });

  const action = await fetchActionById(client, actionId);
  const recipientIds = memberIds.filter((id) => id !== userId);

  wsHub.sendToUsers(recipientIds, {
    type: 'action.new',
    conversationId,
    action,
  });

  await client.query(
    `INSERT INTO notification_outbox (user_id, payload) VALUES ($1, $2)`,
    [
      assignedTo,
      JSON.stringify({
        type: 'action.new',
        conversationId,
        conversationTitle: conv.title,
        actionId,
        createdBy: userId,
        createdByDisplayName: creatorDisplayName,
        preview: statement.slice(0, 120),
      }),
    ],
  );

  return action;
}

export async function markActionDelivered(
  client: pg.PoolClient,
  actionId: string,
  userId: string,
): Promise<{ deliveredAt: string | null; groupId: string }> {
  const { rows: actionRows } = await client.query<{
    group_id: string;
    conversation_id: string;
  }>(
    `SELECT group_id, conversation_id FROM conversation_actions WHERE id = $1`,
    [actionId],
  );
  if (!actionRows[0]) throw new HttpError(404, 'Action not found');

  await assertGroupMember(client, actionRows[0].group_id, userId);

  const { rows } = await client.query<{ delivered_at: Date }>(
    `UPDATE action_receipts
     SET delivered_at = COALESCE(delivered_at, now())
     WHERE action_id = $1 AND user_id = $2
     RETURNING delivered_at`,
    [actionId, userId],
  );

  const deliveredAt = rows[0]?.delivered_at?.toISOString() ?? null;
  if (deliveredAt) {
    await logActionEvent(client, actionId, 'delivered', userId, { at: deliveredAt });
  }

  return { deliveredAt, groupId: actionRows[0].group_id };
}

export async function confirmAction(
  client: pg.PoolClient,
  actionId: string,
  userId: string,
): Promise<unknown> {
  return resolveAction(client, actionId, userId, 'confirmed');
}

export async function declineAction(
  client: pg.PoolClient,
  actionId: string,
  userId: string,
  responseNote?: string,
): Promise<unknown> {
  return resolveAction(client, actionId, userId, 'declined', responseNote);
}

async function resolveAction(
  client: pg.PoolClient,
  actionId: string,
  userId: string,
  status: 'confirmed' | 'declined',
  responseNote?: string,
): Promise<unknown> {
  const { rows: actionRows } = await client.query<{
    conversation_id: string;
    group_id: string;
    assigned_to: string;
    status: string;
  }>(
    `SELECT conversation_id, group_id, assigned_to, status::text
     FROM conversation_actions WHERE id = $1 FOR UPDATE`,
    [actionId],
  );
  const existing = actionRows[0];
  if (!existing) throw new HttpError(404, 'Action not found');

  await assertGroupMember(client, existing.group_id, userId);

  if (existing.assigned_to !== userId) {
    throw new HttpError(403, 'Only the assigned co-parent can respond to this request');
  }
  if (existing.status !== 'pending') {
    throw new HttpError(400, 'This request has already been resolved');
  }

  await client.query(
    `UPDATE conversation_actions
     SET status = $1, resolved_at = now(), resolved_by = $2, response_note = $3
     WHERE id = $4`,
    [status, userId, responseNote ?? null, actionId],
  );

  await logActionEvent(client, actionId, status, userId, {
    responseNote: responseNote ?? null,
  });

  // Resolver has seen the outcome; others must re-read the updated action.
  await client.query(
    `UPDATE action_receipts
     SET read_at = now(), delivered_at = COALESCE(delivered_at, now())
     WHERE action_id = $1 AND user_id = $2`,
    [actionId, userId],
  );
  await client.query(
    `UPDATE action_receipts
     SET read_at = NULL
     WHERE action_id = $1 AND user_id != $2`,
    [actionId, userId],
  );

  const action = await fetchActionById(client, actionId);
  const memberIds = await getGroupMemberIds(client, existing.group_id);
  const recipientIds = memberIds.filter((id) => id !== userId);

  wsHub.sendToUsers(recipientIds, {
    type: 'action.updated',
    conversationId: existing.conversation_id,
    action,
  });

  return action;
}
