import type pg from 'pg';
import { profileDisplayName } from '../lib/display-names.js';

export async function getProfileDisplayName(
  client: pg.PoolClient,
  userId: string,
): Promise<string | null> {
  const { rows } = await client.query<{ display_name: string | null }>(
    `SELECT ${profileDisplayName()} AS display_name FROM profiles p WHERE p.user_id = $1`,
    [userId],
  );
  return rows[0]?.display_name ?? null;
}
