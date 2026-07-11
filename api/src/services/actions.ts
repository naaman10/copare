import type pg from 'pg';
import { wsHub } from '../ws/hub.js';
import { HttpError } from '../lib/errors.js';
import { assertGroupMember, getGroupMemberIds } from './groups.js';
import {
  createActionReceipts,
  createMessageReceipts,
  logActionEvent,
  logMessageEvent,
} from './audit.js';
import { profileDisplayName } from '../lib/display-names.js';
import { getProfileDisplayName } from './display-names.js';

const ACTION_SELECT = `
  SELECT ca.id, ca.conversation_id, ca.group_id,
         ca.action_type::text, ca.status::text,
         ca.statement, ca.response_note, ca.alternative_statement, ca.accepted_statement,
         ca.resolution_text, ca.mediator_thread_root_id,
         ca.parent_a_approved_at, ca.parent_b_approved_at,
         ca.created_by, ca.assigned_to, ca.resolved_by,
         ca.created_at, ca.resolved_at,
         MAX(${profileDisplayName('creator')}) AS created_by_display_name,
         MAX(${profileDisplayName('assignee')}) AS assigned_to_display_name,
         MAX(${profileDisplayName('resolver')}) AS resolved_by_display_name,
         COALESCE(
           (
             SELECT json_agg(
               json_build_object(
                 'userId', ar.user_id,
                 'displayName', ${profileDisplayName('rp')},
                 'deliveredAt', ar.delivered_at,
                 'readAt', ar.read_at
               )
               ORDER BY ${profileDisplayName('rp')}
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

export async function assertMediatorMember(
  client: pg.PoolClient,
  groupId: string,
  userId: string,
): Promise<'mediator_a' | 'mediator_b'> {
  const { rows } = await client.query<{ role: string }>(
    `SELECT role::text FROM group_members WHERE group_id = $1 AND user_id = $2`,
    [groupId, userId],
  );
  const role = rows[0]?.role;
  if (role !== 'mediator_a' && role !== 'mediator_b') {
    throw new HttpError(403, 'Only mediators can perform this action');
  }
  return role;
}

async function getMemberRole(
  client: pg.PoolClient,
  groupId: string,
  userId: string,
): Promise<string> {
  const { rows } = await client.query<{ role: string }>(
    `SELECT role::text FROM group_members WHERE group_id = $1 AND user_id = $2`,
    [groupId, userId],
  );
  const role = rows[0]?.role;
  if (!role) throw new HttpError(403, 'Not a group member');
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

export async function listOutstandingActions(
  client: pg.PoolClient,
  userId: string,
  limit = 20,
): Promise<unknown[]> {
  const select = ACTION_SELECT.replace(
    ') AS receipts\n  FROM conversation_actions ca',
    `) AS receipts,
         MAX(conv.title) AS conversation_title,
         CASE
           WHEN ca.status = 'pending' AND ca.assigned_to = $1
                AND ca.action_type = 'confirmation_request'
             THEN 'Confirm or decline'
           WHEN ca.status = 'pending' AND ca.assigned_to = $1
                AND ca.action_type = 'mediation_request'
             THEN 'Respond to mediation topic'
           WHEN ca.status = 'alternative_pending' AND ca.created_by = $1
             THEN 'Approve or decline alternative'
           WHEN ca.status = 'mediation_in_progress'
                AND MAX(gm.role::text) IN ('mediator_a', 'mediator_b')
             THEN 'Mediate and propose resolution'
           WHEN ca.status = 'parent_approval_pending'
                AND MAX(gm.role::text) = 'parent_a'
                AND ca.parent_a_approved_at IS NULL
             THEN 'Approve or decline resolution'
           WHEN ca.status = 'parent_approval_pending'
                AND MAX(gm.role::text) = 'parent_b'
                AND ca.parent_b_approved_at IS NULL
             THEN 'Approve or decline resolution'
           ELSE 'Action required'
         END AS next_step
  FROM conversation_actions ca`,
  );

  const { rows } = await client.query<Record<string, unknown>>(
    `${select}
     JOIN conversations conv ON conv.id = ca.conversation_id
     JOIN groups g ON g.id = ca.group_id
     JOIN group_members gm ON gm.group_id = ca.group_id AND gm.user_id = $1
     WHERE g.status = 'active'
       AND (
         (ca.status = 'pending' AND ca.assigned_to = $1)
         OR (ca.status = 'alternative_pending' AND ca.created_by = $1)
         OR (
           ca.action_type = 'mediation_request'
           AND ca.status = 'mediation_in_progress'
           AND gm.role IN ('mediator_a', 'mediator_b')
         )
         OR (
           ca.action_type = 'mediation_request'
           AND ca.status = 'parent_approval_pending'
           AND (
             (gm.role = 'parent_a' AND ca.parent_a_approved_at IS NULL)
             OR (gm.role = 'parent_b' AND ca.parent_b_approved_at IS NULL)
           )
         )
       )
     GROUP BY ca.id
     ORDER BY ca.created_at DESC
     LIMIT $2`,
    [userId, limit],
  );

  return rows.map((row) => {
    const {
      conversation_title: conversationTitle,
      next_step: nextStep,
      ...action
    } = row;
    return {
      action,
      conversationTitle,
      nextStep,
    };
  });
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

  const creatorDisplayName = (await getProfileDisplayName(client, userId)) ?? 'Someone';

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
  reason: string,
  alternativeStatement?: string,
): Promise<unknown> {
  const trimmedReason = reason.trim();
  if (!trimmedReason) {
    throw new HttpError(400, 'Decline reason is required');
  }

  const trimmedAlternative = alternativeStatement?.trim() || null;

  return resolveAction(client, actionId, userId, 'declined', {
    responseNote: trimmedReason,
    alternativeStatement: trimmedAlternative,
  });
}

async function resolveAction(
  client: pg.PoolClient,
  actionId: string,
  userId: string,
  status: 'confirmed' | 'declined',
  decline?: { responseNote: string; alternativeStatement: string | null },
): Promise<unknown> {
  const { rows: actionRows } = await client.query<{
    conversation_id: string;
    group_id: string;
    created_by: string;
    assigned_to: string;
    status: string;
  }>(
    `SELECT conversation_id, group_id, created_by, assigned_to, status::text
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

  if (status === 'declined') {
    if (!decline?.responseNote) {
      throw new HttpError(400, 'Decline reason is required');
    }

    const hasAlternative = Boolean(decline.alternativeStatement);
    const nextStatus = hasAlternative ? 'alternative_pending' : 'declined';

    if (hasAlternative) {
      await client.query(
        `UPDATE conversation_actions
         SET status = $1, response_note = $2, alternative_statement = $3,
             resolved_by = NULL, resolved_at = NULL
         WHERE id = $4`,
        [nextStatus, decline.responseNote, decline.alternativeStatement, actionId],
      );
      await logActionEvent(client, actionId, 'alternative_proposed', userId, {
        responseNote: decline.responseNote,
        alternativeStatement: decline.alternativeStatement,
      });
      await client.query(
        `UPDATE action_receipts SET read_at = NULL WHERE action_id = $1 AND user_id = $2`,
        [actionId, existing.created_by],
      );

      const creatorDisplayName =
        (await getProfileDisplayName(client, userId)) ?? 'Someone';
      await client.query(
        `INSERT INTO notification_outbox (user_id, payload) VALUES ($1, $2)`,
        [
          existing.created_by,
          JSON.stringify({
            type: 'action.new',
            conversationId: existing.conversation_id,
            actionId,
            createdBy: userId,
            createdByDisplayName: creatorDisplayName,
            preview: decline.alternativeStatement!.slice(0, 120),
          }),
        ],
      );
    } else {
      await client.query(
        `UPDATE conversation_actions
         SET status = $1, resolved_at = now(), resolved_by = $2,
             response_note = $3, alternative_statement = NULL
         WHERE id = $4`,
        [nextStatus, userId, decline.responseNote, actionId],
      );
      await logActionEvent(client, actionId, status, userId, {
        responseNote: decline.responseNote,
      });
    }
  } else {
    await client.query(
      `UPDATE conversation_actions
       SET status = $1, resolved_at = now(), resolved_by = $2,
           response_note = NULL, alternative_statement = NULL
       WHERE id = $3`,
      [status, userId, actionId],
    );
    await logActionEvent(client, actionId, status, userId, {});
  }

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

export async function confirmAlternative(
  client: pg.PoolClient,
  actionId: string,
  userId: string,
): Promise<unknown> {
  const { rows: actionRows } = await client.query<{
    conversation_id: string;
    group_id: string;
    created_by: string;
    status: string;
    alternative_statement: string | null;
  }>(
    `SELECT conversation_id, group_id, created_by, status::text, alternative_statement
     FROM conversation_actions WHERE id = $1 FOR UPDATE`,
    [actionId],
  );
  const existing = actionRows[0];
  if (!existing) throw new HttpError(404, 'Action not found');

  await assertGroupMember(client, existing.group_id, userId);

  if (existing.created_by !== userId) {
    throw new HttpError(403, 'Only the parent who requested confirmation can approve an alternative');
  }
  if (existing.status !== 'alternative_pending') {
    throw new HttpError(400, 'This action is not awaiting alternative approval');
  }
  if (!existing.alternative_statement?.trim()) {
    throw new HttpError(400, 'No alternative statement to approve');
  }

  await client.query(
    `UPDATE conversation_actions
     SET status = 'confirmed', accepted_statement = $1, resolved_at = now(), resolved_by = $2
     WHERE id = $3`,
    [existing.alternative_statement.trim(), userId, actionId],
  );
  await logActionEvent(client, actionId, 'alternative_confirmed', userId, {
    acceptedStatement: existing.alternative_statement.trim(),
  });

  return broadcastActionUpdate(
    client,
    actionId,
    existing.conversation_id,
    existing.group_id,
    userId,
  );
}

export async function declineAlternative(
  client: pg.PoolClient,
  actionId: string,
  userId: string,
): Promise<unknown> {
  const { rows: actionRows } = await client.query<{
    conversation_id: string;
    group_id: string;
    created_by: string;
    status: string;
  }>(
    `SELECT conversation_id, group_id, created_by, status::text
     FROM conversation_actions WHERE id = $1 FOR UPDATE`,
    [actionId],
  );
  const existing = actionRows[0];
  if (!existing) throw new HttpError(404, 'Action not found');

  await assertGroupMember(client, existing.group_id, userId);

  if (existing.created_by !== userId) {
    throw new HttpError(403, 'Only the parent who requested confirmation can decline an alternative');
  }
  if (existing.status !== 'alternative_pending') {
    throw new HttpError(400, 'This action is not awaiting alternative approval');
  }

  await client.query(
    `UPDATE conversation_actions
     SET status = 'declined', resolved_at = now(), resolved_by = $1
     WHERE id = $2`,
    [userId, actionId],
  );
  await logActionEvent(client, actionId, 'alternative_declined', userId, {});

  return broadcastActionUpdate(
    client,
    actionId,
    existing.conversation_id,
    existing.group_id,
    userId,
  );
}

async function broadcastActionUpdate(
  client: pg.PoolClient,
  actionId: string,
  conversationId: string,
  groupId: string,
  actorUserId: string,
): Promise<unknown> {
  await client.query(
    `UPDATE action_receipts
     SET read_at = now(), delivered_at = COALESCE(delivered_at, now())
     WHERE action_id = $1 AND user_id = $2`,
    [actionId, actorUserId],
  );
  await client.query(
    `UPDATE action_receipts SET read_at = NULL WHERE action_id = $1 AND user_id != $2`,
    [actionId, actorUserId],
  );

  const action = await fetchActionById(client, actionId);
  const memberIds = await getGroupMemberIds(client, groupId);
  const recipientIds = memberIds.filter((id) => id !== actorUserId);

  wsHub.sendToUsers(recipientIds, {
    type: 'action.updated',
    conversationId,
    action,
  });

  return action;
}

export async function createMediationRequest(
  client: pg.PoolClient,
  conversationId: string,
  userId: string,
  topic: string,
): Promise<unknown> {
  const conv = await getConversationContext(client, conversationId);
  if (conv.status !== 'active') {
    throw new HttpError(403, 'Group is not active');
  }

  await assertParentMember(client, conv.groupId, userId);
  const assignedTo = await getCoparentUserId(client, conv.groupId, userId);
  const creatorDisplayName = (await getProfileDisplayName(client, userId)) ?? 'Someone';

  const { rows: inserted } = await client.query<{ id: string }>(
    `INSERT INTO conversation_actions (
       conversation_id, group_id, created_by, assigned_to,
       action_type, statement
     ) VALUES ($1, $2, $3, $4, 'mediation_request', $5)
     RETURNING id`,
    [conversationId, conv.groupId, userId, assignedTo, topic],
  );

  const actionId = inserted[0].id;
  const memberIds = await getGroupMemberIds(client, conv.groupId);
  await createActionReceipts(client, actionId, memberIds, userId);
  await logActionEvent(client, actionId, 'created', userId, { topic });

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
        preview: topic.slice(0, 120),
      }),
    ],
  );

  return action;
}

async function getMediationAction(
  client: pg.PoolClient,
  actionId: string,
): Promise<{
  conversation_id: string;
  group_id: string;
  created_by: string;
  assigned_to: string;
  status: string;
  action_type: string;
  statement: string;
  mediator_thread_root_id: string | null;
}> {
  const { rows } = await client.query(
    `SELECT conversation_id, group_id, created_by, assigned_to, status::text,
            action_type::text, statement, mediator_thread_root_id
     FROM conversation_actions WHERE id = $1 FOR UPDATE`,
    [actionId],
  );
  const action = rows[0];
  if (!action) throw new HttpError(404, 'Action not found');
  if (action.action_type !== 'mediation_request') {
    throw new HttpError(400, 'This is not a mediation request');
  }
  return action;
}

async function createMediationThreadRoot(
  client: pg.PoolClient,
  conversationId: string,
  groupId: string,
  actorId: string,
  topic: string,
): Promise<string> {
  const clientId = crypto.randomUUID();
  const seedBody = `Mediation discussion started: ${topic}`;

  const { rows } = await client.query<{ id: string }>(
    `INSERT INTO messages (conversation_id, sender_id, body, client_id)
     VALUES ($1, $2, $3, $4)
     RETURNING id`,
    [conversationId, actorId, seedBody, clientId],
  );
  const rootId = rows[0].id;

  await client.query(`UPDATE messages SET root_id = $1 WHERE id = $1`, [rootId]);

  const memberIds = await getGroupMemberIds(client, groupId);
  await createMessageReceipts(client, rootId, memberIds, actorId);
  await logMessageEvent(client, rootId, 'mediation_thread_started', actorId, { topic });

  return rootId;
}

export async function respondToMediation(
  client: pg.PoolClient,
  actionId: string,
  userId: string,
  response: string,
): Promise<unknown> {
  const trimmed = response.trim();
  if (!trimmed) throw new HttpError(400, 'Response is required');

  const existing = await getMediationAction(client, actionId);
  await assertGroupMember(client, existing.group_id, userId);

  if (existing.assigned_to !== userId) {
    throw new HttpError(403, 'Only the assigned co-parent can respond to this mediation request');
  }
  if (existing.status !== 'pending') {
    throw new HttpError(400, 'This mediation request has already moved forward');
  }

  const rootId = await createMediationThreadRoot(
    client,
    existing.conversation_id,
    existing.group_id,
    userId,
    existing.statement,
  );

  await client.query(
    `UPDATE conversation_actions
     SET status = 'mediation_in_progress', response_note = $1, mediator_thread_root_id = $2
     WHERE id = $3`,
    [trimmed, rootId, actionId],
  );
  await logActionEvent(client, actionId, 'parent_responded', userId, { response: trimmed });

  await client.query(
    `UPDATE action_receipts SET read_at = NULL WHERE action_id = $1`,
    [actionId],
  );
  await client.query(
    `UPDATE action_receipts
     SET read_at = now(), delivered_at = COALESCE(delivered_at, now())
     WHERE action_id = $1 AND user_id = $2`,
    [actionId, userId],
  );

  const { rows: mediators } = await client.query<{ user_id: string }>(
    `SELECT user_id FROM group_members
     WHERE group_id = $1 AND role IN ('mediator_a', 'mediator_b')`,
    [existing.group_id],
  );
  const responderName = (await getProfileDisplayName(client, userId)) ?? 'Someone';
  for (const mediator of mediators) {
    await client.query(
      `INSERT INTO notification_outbox (user_id, payload) VALUES ($1, $2)`,
      [
        mediator.user_id,
        JSON.stringify({
          type: 'action.new',
          conversationId: existing.conversation_id,
          actionId,
          createdBy: userId,
          createdByDisplayName: responderName,
          preview: `Mediation ready: ${existing.statement.slice(0, 80)}`,
        }),
      ],
    );
  }

  return broadcastActionUpdate(
    client,
    actionId,
    existing.conversation_id,
    existing.group_id,
    userId,
  );
}

const MEDIATION_MESSAGE_SELECT = `
  SELECT m.id, m.conversation_id, m.sender_id, m.parent_id, m.root_id,
         m.body, m.client_id, m.deleted_at, m.created_at, m.edited_at,
         MAX(${profileDisplayName('p')}) AS sender_display_name
  FROM messages m
  LEFT JOIN profiles p ON p.user_id = m.sender_id`;

export async function listMediationMessages(
  client: pg.PoolClient,
  actionId: string,
  userId: string,
): Promise<unknown[]> {
  const { rows: actionRows } = await client.query<{
    group_id: string;
    mediator_thread_root_id: string | null;
    action_type: string;
  }>(
    `SELECT group_id, mediator_thread_root_id, action_type::text
     FROM conversation_actions WHERE id = $1`,
    [actionId],
  );
  const action = actionRows[0];
  if (!action) throw new HttpError(404, 'Action not found');
  if (action.action_type !== 'mediation_request') {
    throw new HttpError(400, 'This is not a mediation request');
  }
  if (!action.mediator_thread_root_id) {
    return [];
  }

  await assertGroupMember(client, action.group_id, userId);

  const { rows } = await client.query(
    `${MEDIATION_MESSAGE_SELECT}
     WHERE m.root_id = $1 AND m.deleted_at IS NULL
     GROUP BY m.id
     ORDER BY m.created_at ASC`,
    [action.mediator_thread_root_id],
  );
  return rows;
}

export async function sendMediationMessage(
  client: pg.PoolClient,
  actionId: string,
  userId: string,
  body: string,
  clientId: string,
): Promise<unknown> {
  const trimmed = body.trim();
  if (!trimmed) throw new HttpError(400, 'Message body is required');

  const existing = await getMediationAction(client, actionId);
  await assertMediatorMember(client, existing.group_id, userId);

  if (existing.status !== 'mediation_in_progress') {
    throw new HttpError(400, 'Mediation discussion is not open');
  }
  if (!existing.mediator_thread_root_id) {
    throw new HttpError(409, 'Mediation thread has not been started');
  }

  const { rows: existingMsg } = await client.query(
    `SELECT id, conversation_id, sender_id, parent_id, root_id, body, client_id,
            deleted_at, created_at, edited_at
     FROM messages
     WHERE conversation_id = $1 AND sender_id = $2 AND client_id = $3`,
    [existing.conversation_id, userId, clientId],
  );
  if (existingMsg[0]) {
    const senderDisplayName = await getProfileDisplayName(client, userId);
    return { ...existingMsg[0], sender_display_name: senderDisplayName };
  }

  const senderDisplayName = await getProfileDisplayName(client, userId);
  const { rows: inserted } = await client.query(
    `INSERT INTO messages (conversation_id, sender_id, root_id, body, client_id)
     VALUES ($1, $2, $3, $4, $5)
     RETURNING id, conversation_id, sender_id, parent_id, root_id, body, client_id,
               deleted_at, created_at, edited_at`,
    [existing.conversation_id, userId, existing.mediator_thread_root_id, trimmed, clientId],
  );
  const message = {
    ...inserted[0],
    sender_display_name: senderDisplayName,
  };

  const memberIds = await getGroupMemberIds(client, existing.group_id);
  await createMessageReceipts(client, message.id, memberIds, userId);
  await logMessageEvent(client, message.id, 'created', userId, { mediationActionId: actionId });

  const recipientIds = memberIds.filter((id) => id !== userId);
  wsHub.sendToUsers(recipientIds, {
    type: 'message.new',
    conversationId: existing.conversation_id,
    message,
  });

  return message;
}

export async function resolveMediation(
  client: pg.PoolClient,
  actionId: string,
  userId: string,
  resolution: string,
): Promise<unknown> {
  const trimmed = resolution.trim();
  if (!trimmed) throw new HttpError(400, 'Resolution is required');

  const existing = await getMediationAction(client, actionId);
  await assertMediatorMember(client, existing.group_id, userId);

  if (existing.status !== 'mediation_in_progress') {
    throw new HttpError(400, 'Mediation is not in progress');
  }

  await client.query(
    `UPDATE conversation_actions
     SET status = 'parent_approval_pending',
         resolution_text = $1,
         resolved_by = $2,
         parent_a_approved_at = NULL,
         parent_b_approved_at = NULL
     WHERE id = $3`,
    [trimmed, userId, actionId],
  );
  await logActionEvent(client, actionId, 'mediation_resolved', userId, { resolution: trimmed });

  await client.query(
    `UPDATE action_receipts SET read_at = NULL WHERE action_id = $1`,
    [actionId],
  );
  await client.query(
    `UPDATE action_receipts
     SET read_at = now(), delivered_at = COALESCE(delivered_at, now())
     WHERE action_id = $1 AND user_id = $2`,
    [actionId, userId],
  );

  const { rows: parents } = await client.query<{ user_id: string }>(
    `SELECT user_id FROM group_members
     WHERE group_id = $1 AND role IN ('parent_a', 'parent_b')`,
    [existing.group_id],
  );
  const resolverName = (await getProfileDisplayName(client, userId)) ?? 'A mediator';
  for (const parent of parents) {
    await client.query(
      `INSERT INTO notification_outbox (user_id, payload) VALUES ($1, $2)`,
      [
        parent.user_id,
        JSON.stringify({
          type: 'action.new',
          conversationId: existing.conversation_id,
          actionId,
          createdBy: userId,
          createdByDisplayName: resolverName,
          preview: `Resolution proposed: ${trimmed.slice(0, 80)}`,
        }),
      ],
    );
  }

  return broadcastActionUpdate(
    client,
    actionId,
    existing.conversation_id,
    existing.group_id,
    userId,
  );
}

export async function approveMediationResolution(
  client: pg.PoolClient,
  actionId: string,
  userId: string,
): Promise<unknown> {
  const existing = await getMediationAction(client, actionId);
  const role = await getMemberRole(client, existing.group_id, userId);

  if (role !== 'parent_a' && role !== 'parent_b') {
    throw new HttpError(403, 'Only parents can approve a mediation resolution');
  }
  if (existing.status !== 'parent_approval_pending') {
    throw new HttpError(400, 'This mediation is not awaiting parent approval');
  }

  const approvalColumn = role === 'parent_a' ? 'parent_a_approved_at' : 'parent_b_approved_at';
  await client.query(
    `UPDATE conversation_actions SET ${approvalColumn} = now() WHERE id = $1`,
    [actionId],
  );
  await logActionEvent(client, actionId, 'parent_approved_resolution', userId, { role });

  const { rows: updated } = await client.query<{
    parent_a_approved_at: Date | null;
    parent_b_approved_at: Date | null;
  }>(
    `SELECT parent_a_approved_at, parent_b_approved_at
     FROM conversation_actions WHERE id = $1`,
    [actionId],
  );
  const approvals = updated[0];

  if (approvals?.parent_a_approved_at && approvals?.parent_b_approved_at) {
    await client.query(
      `UPDATE conversation_actions
       SET status = 'confirmed', resolved_at = now()
       WHERE id = $1`,
      [actionId],
    );
    await logActionEvent(client, actionId, 'confirmed', userId, {});
  }

  await client.query(
    `UPDATE action_receipts
     SET read_at = now(), delivered_at = COALESCE(delivered_at, now())
     WHERE action_id = $1 AND user_id = $2`,
    [actionId, userId],
  );
  await client.query(
    `UPDATE action_receipts SET read_at = NULL WHERE action_id = $1 AND user_id != $2`,
    [actionId, userId],
  );

  return broadcastActionUpdate(
    client,
    actionId,
    existing.conversation_id,
    existing.group_id,
    userId,
  );
}

export async function declineMediationResolution(
  client: pg.PoolClient,
  actionId: string,
  userId: string,
  reason: string,
): Promise<unknown> {
  const trimmed = reason.trim();
  if (!trimmed) throw new HttpError(400, 'Decline reason is required');

  const existing = await getMediationAction(client, actionId);
  await assertParentMember(client, existing.group_id, userId);

  if (existing.status !== 'parent_approval_pending') {
    throw new HttpError(400, 'This mediation is not awaiting parent approval');
  }

  await client.query(
    `UPDATE conversation_actions
     SET status = 'declined', resolved_at = now(), resolved_by = $1,
         response_note = COALESCE(response_note, '') || E'\\n\\nResolution declined: ' || $2
     WHERE id = $3`,
    [userId, trimmed, actionId],
  );
  await logActionEvent(client, actionId, 'resolution_declined', userId, { reason: trimmed });

  return broadcastActionUpdate(
    client,
    actionId,
    existing.conversation_id,
    existing.group_id,
    userId,
  );
}
