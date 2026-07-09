/**
 * Notification outbox worker — polls notification_outbox and sends APNs push notifications.
 */
import { getPool } from '../db/pool.js';
import {
  getApnsClient,
  isApnsConfigured,
  isInvalidDeviceTokenError,
  parsePushPayload,
  sendPush,
} from '../lib/apns.js';

const POLL_INTERVAL_MS = 5_000;
const BATCH_SIZE = 50;

async function processBatch(): Promise<number> {
  if (!isApnsConfigured()) {
    console.warn('[notifications] APNs not configured — set APNS_* env vars on the worker');
    return 0;
  }

  getApnsClient();

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
        const pushPayload = parsePushPayload(row.payload);
        if (!pushPayload) {
          throw new Error('Unsupported notification payload');
        }

        const { rows: tokens } = await client.query<{ token: string }>(
          `SELECT token FROM device_tokens WHERE user_id = $1`,
          [row.user_id],
        );

        if (tokens.length === 0) {
          await client.query(
            `UPDATE notification_outbox SET status = 'sent', sent_at = now() WHERE id = $1`,
            [row.id],
          );
          continue;
        }

        let delivered = false;
        for (const { token } of tokens) {
          try {
            await sendPush(token, pushPayload);
            delivered = true;
          } catch (err) {
            if (isInvalidDeviceTokenError(err)) {
              await client.query(`DELETE FROM device_tokens WHERE token = $1`, [token]);
              console.warn('[notifications] removed invalid device token', token.slice(0, 8));
              continue;
            }
            throw err;
          }
        }

        if (!delivered) {
          throw new Error('No valid device tokens for user');
        }

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
  console.log('[notifications] worker started', {
    apns: isApnsConfigured() ? 'configured' : 'missing APNS_* env',
    sandbox: process.env.APNS_USE_SANDBOX === 'true',
  });

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
