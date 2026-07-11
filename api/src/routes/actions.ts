import { Hono } from 'hono';
import { z } from 'zod';
import { getPool, withTransaction } from '../db/pool.js';
import type { AuthVariables } from '../middleware/auth.js';
import {
  approveMediationResolution,
  confirmAction,
  confirmAlternative,
  createConfirmationRequest,
  createMediationRequest,
  declineAction,
  declineAlternative,
  declineMediationResolution,
  listConversationActions,
  listMediationMessages,
  listOutstandingActions,
  markActionDelivered,
  resolveMediation,
  respondToMediation,
  sendMediationMessage,
} from '../services/actions.js';
import { HttpError, jsonError } from '../lib/errors.js';
import { wsHub } from '../ws/hub.js';

export const actionsRoutes = new Hono<{ Variables: AuthVariables }>();

actionsRoutes.get('/actions/outstanding', async (c) => {
  const userId = c.get('userId');
  const limit = Math.min(Number(c.req.query('limit') ?? 20), 50);

  try {
    const actions = await withTransaction((client) =>
      listOutstandingActions(client, userId, limit),
    );
    return c.json({ actions });
  } catch (err) {
    if (err instanceof HttpError) return jsonError(c, err);
    throw err;
  }
});

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
    .discriminatedUnion('actionType', [
      z.object({
        actionType: z.literal('confirmation_request'),
        statement: z.string().min(1).max(2000),
      }),
      z.object({
        actionType: z.literal('mediation_request'),
        topic: z.string().min(1).max(2000),
      }),
    ])
    .parse(await c.req.json());

  try {
    const action = await withTransaction((client) => {
      if (body.actionType === 'confirmation_request') {
        return createConfirmationRequest(client, conversationId, userId, body.statement);
      }
      return createMediationRequest(client, conversationId, userId, body.topic);
    });
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

actionsRoutes.post('/actions/:actionId/mediation/respond', async (c) => {
  const userId = c.get('userId');
  const actionId = c.req.param('actionId');
  const body = z
    .object({ response: z.string().min(1).max(2000) })
    .parse(await c.req.json());

  try {
    const action = await withTransaction((client) =>
      respondToMediation(client, actionId, userId, body.response),
    );
    return c.json({ action });
  } catch (err) {
    if (err instanceof HttpError) return jsonError(c, err);
    throw err;
  }
});

actionsRoutes.get('/actions/:actionId/mediation/messages', async (c) => {
  const userId = c.get('userId');
  const actionId = c.req.param('actionId');

  try {
    const messages = await withTransaction((client) =>
      listMediationMessages(client, actionId, userId),
    );
    return c.json({ messages });
  } catch (err) {
    if (err instanceof HttpError) return jsonError(c, err);
    throw err;
  }
});

actionsRoutes.post('/actions/:actionId/mediation/messages', async (c) => {
  const userId = c.get('userId');
  const actionId = c.req.param('actionId');
  const body = z
    .object({
      body: z.string().min(1).max(10000),
      clientId: z.string().uuid(),
    })
    .parse(await c.req.json());

  try {
    const message = await withTransaction((client) =>
      sendMediationMessage(client, actionId, userId, body.body, body.clientId),
    );
    return c.json({ message }, 201);
  } catch (err) {
    if (err instanceof HttpError) return jsonError(c, err);
    throw err;
  }
});

actionsRoutes.post('/actions/:actionId/mediation/resolve', async (c) => {
  const userId = c.get('userId');
  const actionId = c.req.param('actionId');
  const body = z
    .object({ resolution: z.string().min(1).max(2000) })
    .parse(await c.req.json());

  try {
    const action = await withTransaction((client) =>
      resolveMediation(client, actionId, userId, body.resolution),
    );
    return c.json({ action });
  } catch (err) {
    if (err instanceof HttpError) return jsonError(c, err);
    throw err;
  }
});

actionsRoutes.post('/actions/:actionId/mediation/approve', async (c) => {
  const userId = c.get('userId');
  const actionId = c.req.param('actionId');

  try {
    const action = await withTransaction((client) =>
      approveMediationResolution(client, actionId, userId),
    );
    return c.json({ action });
  } catch (err) {
    if (err instanceof HttpError) return jsonError(c, err);
    throw err;
  }
});

actionsRoutes.post('/actions/:actionId/mediation/decline', async (c) => {
  const userId = c.get('userId');
  const actionId = c.req.param('actionId');
  const body = z
    .object({ reason: z.string().min(1).max(500) })
    .parse(await c.req.json());

  try {
    const action = await withTransaction((client) =>
      declineMediationResolution(client, actionId, userId, body.reason),
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
