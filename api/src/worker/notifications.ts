/**
 * Notification outbox worker — runs as a Render Background Worker.
 * Polls notification_outbox and sends APNs push notifications.
 *
 * APNs integration is stubbed until APNS_* env vars are configured.
 */
import { getPool } from '../db/pool.js';

const POLL_INTERVAL_MS = 5_000;
const BATCH_SIZE = 50;

async function processBatch(): Promise<number> {
  const pool = getPool();
  const client = await pool.connect();

  try {
    await client.query('BEGIN');

    const { rows } = await client.query<{ id: string; user_id: string; payload: unknown }>(
      `SELECT id, user_id, payload
       FROM notification_outbox
       WHERE status = 'pending'
       ORDER BY created_at
       LIMIT $1
       FOR UPDATE SKIP LOCKED`,
      [BATCH_SIZE],
    );

    for (const row of rows) {
      try {
        // TODO: look up device_tokens for row.user_id and send via APNs
        console.log('[notifications] would send push', {
          userId: row.user_id,
          payload: row.payload,
        });

        await client.query(
          `UPDATE notification_outbox SET status = 'sent', sent_at = now() WHERE id = $1`,
          [row.id],
        );
      } catch (err) {
        console.error('[notifications] failed', row.id, err);
        await client.query(
          `UPDATE notification_outbox SET status = 'failed' WHERE id = $1`,
          [row.id],
        );
      }
    }

    await client.query('COMMIT');
    return rows.length;
  } catch (err) {
    await client.query('ROLLBACK');
    throw err;
  } finally {
    client.release();
  }
}

async function main(): Promise<void> {
  console.log('[notifications] worker started');
  // eslint-disable-next-line no-constant-condition
  while (true) {
    try {
      const processed = await processBatch();
      if (processed === 0) {
        await new Promise((r) => setTimeout(r, POLL_INTERVAL_MS));
      }
    } catch (err) {
      console.error('[notifications] batch error, retrying…', err);
      await new Promise((r) => setTimeout(r, POLL_INTERVAL_MS));
    }
  }
}

main().catch((err) => {
  console.error('[notifications] fatal', err);
  process.exit(1);
});
