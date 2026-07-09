-- Backfill per-member receipts for actions created before audit migration.

INSERT INTO action_receipts (action_id, user_id, delivered_at, read_at)
SELECT ca.id, gm.user_id, ca.created_at, ca.created_at
FROM conversation_actions ca
JOIN group_members gm ON gm.group_id = ca.group_id
WHERE gm.user_id = ca.created_by
  AND NOT EXISTS (
    SELECT 1 FROM action_receipts ar
    WHERE ar.action_id = ca.id AND ar.user_id = gm.user_id
  );

INSERT INTO action_receipts (action_id, user_id)
SELECT ca.id, gm.user_id
FROM conversation_actions ca
JOIN group_members gm ON gm.group_id = ca.group_id
WHERE gm.user_id != ca.created_by
  AND NOT EXISTS (
    SELECT 1 FROM action_receipts ar
    WHERE ar.action_id = ca.id AND ar.user_id = gm.user_id
  );
