import type pg from 'pg';
import { profileDisplayName } from '../lib/display-names.js';

export async function listRecentConversations(
  client: pg.PoolClient,
  userId: string,
  limit = 20,
): Promise<unknown[]> {
  const { rows } = await client.query(
    `WITH user_conversations AS (
       SELECT c.id, c.group_id, c.title, c.created_by, c.created_at
       FROM conversations c
       JOIN group_members gm ON gm.group_id = c.group_id AND gm.user_id = $1
       JOIN groups g ON g.id = c.group_id
       WHERE g.status = 'active'
     ),
     unread_counts AS (
       SELECT uc.id AS conversation_id,
              COUNT(m.id)::int AS unread_count
       FROM user_conversations uc
       LEFT JOIN conversation_read_cursors crc
         ON crc.conversation_id = uc.id AND crc.user_id = $1
       LEFT JOIN messages last_read ON last_read.id = crc.last_read_message_id
       LEFT JOIN messages m
         ON m.conversation_id = uc.id
        AND m.deleted_at IS NULL
        AND m.root_id IS NULL
        AND m.sender_id != $1
        AND (last_read.id IS NULL OR m.created_at > last_read.created_at)
       GROUP BY uc.id
     ),
     last_messages AS (
       SELECT DISTINCT ON (m.conversation_id)
              m.conversation_id,
              m.created_at AS last_message_at,
              m.sender_id AS last_message_sender_id,
              ${profileDisplayName('p')} AS last_message_sender_display_name
       FROM messages m
       LEFT JOIN profiles p ON p.user_id = m.sender_id
       WHERE m.deleted_at IS NULL
         AND m.root_id IS NULL
       ORDER BY m.conversation_id, m.created_at DESC
     )
     SELECT uc.id, uc.group_id, uc.title, uc.created_by, uc.created_at,
            lm.last_message_at,
            lm.last_message_sender_display_name,
            COALESCE(ucnt.unread_count, 0) AS unread_count
     FROM user_conversations uc
     LEFT JOIN unread_counts ucnt ON ucnt.conversation_id = uc.id
     LEFT JOIN last_messages lm ON lm.conversation_id = uc.id
     ORDER BY
       CASE WHEN COALESCE(ucnt.unread_count, 0) > 0 THEN 0 ELSE 1 END,
       lm.last_message_at DESC NULLS LAST,
       uc.created_at DESC
     LIMIT $2`,
    [userId, limit],
  );
  return rows;
}
