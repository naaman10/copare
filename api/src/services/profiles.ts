import type pg from 'pg';

/** Ensure every auth user has a profiles row (display name from sign-up / Neon Auth). */
export async function ensureProfileFromAuth(
  client: pg.PoolClient,
  userId: string,
): Promise<void> {
  await client.query(
    `INSERT INTO profiles (user_id, display_name)
     SELECT u.id, COALESCE(NULLIF(TRIM(u.name), ''), u.email)
     FROM neon_auth."user" u
     WHERE u.id = $1
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
