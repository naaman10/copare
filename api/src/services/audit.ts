import type pg from 'pg';

export async function logMessageEvent(
  client: pg.PoolClient,
  messageId: string,
  eventType: string,
  actorId: string,
  metadata?: Record<string, unknown>,
): Promise<void> {
  await client.query(
    `INSERT INTO message_events (message_id, event_type, actor_id, metadata)
     VALUES ($1, $2, $3, $4)`,
    [messageId, eventType, actorId, metadata ? JSON.stringify(metadata) : null],
  );
}

export async function logActionEvent(
  client: pg.PoolClient,
  actionId: string,
  eventType: string,
  actorId: string,
  metadata?: Record<string, unknown>,
): Promise<void> {
  await client.query(
    `INSERT INTO action_events (action_id, event_type, actor_id, metadata)
     VALUES ($1, $2, $3, $4)`,
    [actionId, eventType, actorId, metadata ? JSON.stringify(metadata) : null],
  );
}

/** Create receipt rows for every group member; author gets immediate delivered/read timestamps. */
export async function createMessageReceipts(
  client: pg.PoolClient,
  messageId: string,
  memberIds: string[],
  authorId: string,
): Promise<void> {
  for (const memberId of memberIds) {
    if (memberId === authorId) {
      await client.query(
        `INSERT INTO message_receipts (message_id, user_id, delivered_at, read_at)
         VALUES ($1, $2, now(), now())`,
        [messageId, memberId],
      );
    } else {
      await client.query(
        `INSERT INTO message_receipts (message_id, user_id) VALUES ($1, $2)`,
        [messageId, memberId],
      );
    }
  }
}

export async function createActionReceipts(
  client: pg.PoolClient,
  actionId: string,
  memberIds: string[],
  authorId: string,
): Promise<void> {
  for (const memberId of memberIds) {
    if (memberId === authorId) {
      await client.query(
        `INSERT INTO action_receipts (action_id, user_id, delivered_at, read_at)
         VALUES ($1, $2, now(), now())`,
        [actionId, memberId],
      );
    } else {
      await client.query(
        `INSERT INTO action_receipts (action_id, user_id) VALUES ($1, $2)`,
        [actionId, memberId],
      );
    }
  }
}
