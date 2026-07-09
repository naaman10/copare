-- Backfill profiles for auth users in groups who have no profiles row yet.

INSERT INTO profiles (user_id, display_name)
SELECT u.id, COALESCE(NULLIF(TRIM(u.name), ''), u.email)
FROM neon_auth."user" u
WHERE EXISTS (SELECT 1 FROM group_members gm WHERE gm.user_id = u.id)
  AND NOT EXISTS (SELECT 1 FROM profiles p WHERE p.user_id = u.id);
