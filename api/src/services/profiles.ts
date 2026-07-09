import type pg from 'pg';

/** Ensure a profiles row exists. Display name is set explicitly via upsertProfile. */
export async function ensureProfileFromAuth(
  client: pg.PoolClient,
  userId: string,
): Promise<void> {
  await client.query(
    `INSERT INTO profiles (user_id, display_name)
     VALUES ($1, '')
     ON CONFLICT (user_id) DO NOTHING`,
    [userId],
  );
}

export async function upsertProfile(
  client: pg.PoolClient,
  userId: string,
  displayName: string,
): Promise<void> {
  await client.query(
    `INSERT INTO profiles (user_id, display_name)
     VALUES ($1, $2)
     ON CONFLICT (user_id)
     DO UPDATE SET display_name = EXCLUDED.display_name, updated_at = now()`,
    [userId, displayName.trim()],
  );
}
