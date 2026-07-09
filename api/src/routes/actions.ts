import { Hono } from 'hono';
import { z } from 'zod';
import { withTransaction } from '../db/pool.js';
import type { AuthVariables } from '../middleware/auth.js';
import {
  confirmAction,
  createConfirmationRequest,
  declineAction,
  listConversationActions,
} from '../services/actions.js';
import { HttpError, jsonError } from '../lib/errors.js';

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
      responseNote: z.string().max(500).optional(),
    })
    .parse(await c.req.json().catch(() => ({})));

  try {
    const action = await withTransaction((client) =>
      declineAction(client, actionId, userId, body.responseNote),
    );
    return c.json({ action });
  } catch (err) {
    if (err instanceof HttpError) return jsonError(c, err);
    throw err;
  }
});
