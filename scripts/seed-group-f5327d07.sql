-- Seed Parent B, Mediator A, and Mediator B for group f5327d07-da8b-4d9e-b517-44f4504d1b56
--
-- Run in Neon SQL Editor (or: psql $DATABASE_URL -f scripts/seed-group-f5327d07.sql)
--
-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │ STEP 1 — Create Neon Auth accounts (once)                               │
-- │ Password for all test users: CopareTest123!                             │
-- └─────────────────────────────────────────────────────────────────────────┘
--
-- Option A: Sign up in the iOS app with these emails.
--
-- Option B: curl (replace NEON_AUTH_BASE_URL):
--
--   export AUTH="https://YOUR-PROJECT.neonauth.REGION.aws.neon.tech/neondb/auth"
--   export ORIGIN="copare://"
--   for EMAIL NAME in \
--     "parent-b@test.copare.dev:Parent B" \
--     "mediator-a@test.copare.dev:Mediator A" \
--     "mediator-b@test.copare.dev:Mediator B"; do
--     IFS=: read -r E N <<< "$EMAIL"
--     curl -s -X POST "$AUTH/sign-up/email" \
--       -H "Content-Type: application/json" -H "Origin: $ORIGIN" \
--       -d "{\"email\":\"$E\",\"password\":\"CopareTest123!\",\"name\":\"$N\"}"
--     echo
--   done
--
-- ┌─────────────────────────────────────────────────────────────────────────┐
-- │ STEP 2 — Run this script                                                │
-- └─────────────────────────────────────────────────────────────────────────┘

BEGIN;

DO $$
DECLARE
  v_group_id UUID := 'f5327d07-da8b-4d9e-b517-44f4504d1b56';
  v_missing  TEXT[];
BEGIN
  IF NOT EXISTS (SELECT 1 FROM groups WHERE id = v_group_id) THEN
    RAISE EXCEPTION 'Group % not found. Check the group UUID.', v_group_id;
  END IF;

  SELECT array_agg(m.email ORDER BY m.email)
  INTO v_missing
  FROM (
    VALUES
      ('parent-b@test.copare.dev'),
      ('mediator-a@test.copare.dev'),
      ('mediator-b@test.copare.dev')
  ) AS m(email)
  WHERE NOT EXISTS (
    SELECT 1
    FROM neon_auth."user" u
    WHERE lower(u.email) = lower(m.email)
  );

  IF v_missing IS NOT NULL THEN
    RAISE EXCEPTION
      'Neon Auth users not found for: %. Sign up via app or curl first (see script header).',
      array_to_string(v_missing, ', ');
  END IF;
END $$;

-- Profiles
INSERT INTO profiles (user_id, display_name)
SELECT u.id, v.display_name
FROM (
  VALUES
    ('parent-b@test.copare.dev',   'Parent B'),
    ('mediator-a@test.copare.dev', 'Mediator A'),
    ('mediator-b@test.copare.dev', 'Mediator B')
) AS v(email, display_name)
JOIN neon_auth."user" u ON lower(u.email) = lower(v.email)
ON CONFLICT (user_id) DO UPDATE
  SET display_name = EXCLUDED.display_name,
      updated_at   = now();

-- Group membership (trigger activates group when count reaches 4)
INSERT INTO group_members (group_id, user_id, role)
SELECT
  'f5327d07-da8b-4d9e-b517-44f4504d1b56'::uuid,
  u.id,
  v.role::member_role
FROM (
  VALUES
    ('parent-b@test.copare.dev',   'parent_b'),
    ('mediator-a@test.copare.dev', 'mediator_a'),
    ('mediator-b@test.copare.dev', 'mediator_b')
) AS v(email, role)
JOIN neon_auth."user" u ON lower(u.email) = lower(v.email)
ON CONFLICT (group_id, role) DO UPDATE
  SET user_id = EXCLUDED.user_id
WHERE group_members.user_id IS DISTINCT FROM EXCLUDED.user_id;

-- Mark any pending invitations for these roles as accepted
UPDATE invitations i
SET status = 'accepted', accepted_at = now()
FROM neon_auth."user" u
WHERE i.group_id = 'f5327d07-da8b-4d9e-b517-44f4504d1b56'::uuid
  AND i.status = 'pending'
  AND (
    (i.role = 'parent_b'   AND lower(i.email) = 'parent-b@test.copare.dev') OR
    (i.role = 'mediator_a' AND lower(i.email) = 'mediator-a@test.copare.dev') OR
    (i.role = 'mediator_b' AND lower(i.email) = 'mediator-b@test.copare.dev')
  );

COMMIT;

-- Verify
SELECT g.id, g.status::text, g.activated_at, count(gm.*) AS member_count
FROM groups g
LEFT JOIN group_members gm ON gm.group_id = g.id
WHERE g.id = 'f5327d07-da8b-4d9e-b517-44f4504d1b56'
GROUP BY g.id, g.status, g.activated_at;

SELECT gm.role::text, p.display_name, u.email, gm.joined_at
FROM group_members gm
JOIN neon_auth."user" u ON u.id = gm.user_id
LEFT JOIN profiles p ON p.user_id = gm.user_id
WHERE gm.group_id = 'f5327d07-da8b-4d9e-b517-44f4504d1b56'
ORDER BY gm.role;
