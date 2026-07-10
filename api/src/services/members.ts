import type pg from 'pg';
import { profileDisplayName } from '../lib/display-names.js';
import { assertGroupMember } from './groups.js';

export type GroupMemberRow = {
  userId: string;
  role: string;
  displayName: string | null;
  joinedAt: Date;
};

export async function listGroupMembers(
  client: pg.PoolClient,
  groupId: string,
  viewerUserId: string,
): Promise<GroupMemberRow[]> {
  await assertGroupMember(client, groupId, viewerUserId);

  const { rows } = await client.query<{
    user_id: string;
    role: string;
    display_name: string | null;
    joined_at: Date;
  }>(
    `SELECT gm.user_id, gm.role::text AS role, gm.joined_at,
            ${profileDisplayName('p')} AS display_name
     FROM group_members gm
     LEFT JOIN profiles p ON p.user_id = gm.user_id
     WHERE gm.group_id = $1
     ORDER BY gm.role`,
    [groupId],
  );

  return rows.map((row) => ({
    userId: row.user_id,
    role: row.role,
    displayName: row.display_name,
    joinedAt: row.joined_at,
  }));
}
