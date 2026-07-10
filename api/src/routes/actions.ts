import { Hono } from 'hono';
import { z } from 'zod';
import { getPool, withTransaction } from '../db/pool.js';
import type { AuthVariables } from '../middleware/auth.js';
import {
  confirmAction,
  confirmAlternative,
  createConfirmationRequest,
  declineAction,
  declineAlternative,
  listConversationActions,
  markActionDelivered,
} from '../services/actions.js';
import { HttpError, jsonError } from '../lib/errors.js';
import { wsHub } from '../ws/hub.js';

export const actionsRoutes = new Hono<{ Variables: AuthVariables }>();

actionsRoutes.get('/conversations/:conversationId/actions', async (c) => {
  const userId = c.get('userId');
  const conversationId = c.req.param('conversationId');

  try {
    const actions = await withTransaction((client) =>
      listConversationActions(client, conversationId, userId),
    );
    return c.json({ actions });
  } catch (err) {
    if (err instanceof HttpError) return jsonError(c, err);
    throw err;
  }
});

actionsRoutes.post('/conversations/:conversationId/actions', async (c) => {
  const userId = c.get('userId');
  const conversationId = c.req.param('conversationId');
  const body = z
    .object({
      actionType: z.literal('confirmation_request'),
      statement: z.string().min(1).max(2000),
    })
    .parse(await c.req.json());

  try {
    const action = await withTransaction((client) =>
      createConfirmationRequest(client, conversationId, userId, body.statement),
    );
    return c.json({ action }, 201);
  } catch (err) {
    if (err instanceof HttpError) return jsonError(c, err);
    throw err;
  }
});

actionsRoutes.post('/actions/:actionId/confirm', async (c) => {
  const userId = c.get('userId');
  const actionId = c.req.param('actionId');

  try {
    const action = await withTransaction((client) =>
      confirmAction(client, actionId, userId),
    );
    return c.json({ action });
  } catch (err) {
    if (err instanceof HttpError) return jsonError(c, err);
    throw err;
  }
});

actionsRoutes.post('/actions/:actionId/decline', async (c) => {
  const userId = c.get('userId');
  const actionId = c.req.param('actionId');
  const body = z
    .object({
      reason: z.string().min(1).max(500),
      alternativeStatement: z.string().max(2000).optional(),
    })
    .parse(await c.req.json());

  try {
    const action = await withTransaction((client) =>
      declineAction(
        client,
        actionId,
        userId,
        body.reason,
        body.alternativeStatement,
      ),
    );
    return c.json({ action });
  } catch (err) {
    if (err instanceof HttpError) return jsonError(c, err);
    throw err;
  }
});

actionsRoutes.post('/actions/:actionId/alternative/confirm', async (c) => {
  const userId = c.get('userId');
  const actionId = c.req.param('actionId');

  try {
    const action = await withTransaction((client) =>
      confirmAlternative(client, actionId, userId),
    );
    return c.json({ action });
  } catch (err) {
    if (err instanceof HttpError) return jsonError(c, err);
    throw err;
  }
});

actionsRoutes.post('/actions/:actionId/alternative/decline', async (c) => {
  const userId = c.get('userId');
  const actionId = c.req.param('actionId');

  try {
    const action = await withTransaction((client) =>
      declineAlternative(client, actionId, userId),
    );
    return c.json({ action });
  } catch (err) {
    if (err instanceof HttpError) return jsonError(c, err);
    throw err;
  }
});

actionsRoutes.post('/actions/:actionId/delivered', async (c) => {
  const userId = c.get('userId');
  const actionId = c.req.param('actionId');

  const result = await withTransaction((client) =>
    markActionDelivered(client, actionId, userId),
  );

  if (result.deliveredAt) {
    const { rows: members } = await getPool().query<{ user_id: string }>(
      `SELECT user_id FROM group_members WHERE group_id = $1`,
      [result.groupId],
    );
    wsHub.sendToUsers(
      members.map((m) => m.user_id).filter((id) => id !== userId),
      { type: 'action.delivered', actionId, userId, at: result.deliveredAt },
    );
  }

  return c.json({ deliveredAt: result.deliveredAt });
});
