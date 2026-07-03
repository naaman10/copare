-- Row-Level Security for Neon Data API (optional direct reads from iOS)
-- Copare API uses owner connection + application-level checks; enable RLS for Data API.

ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE groups ENABLE ROW LEVEL SECURITY;
ALTER TABLE group_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE conversations ENABLE ROW LEVEL SECURITY;
ALTER TABLE messages ENABLE ROW LEVEL SECURITY;
ALTER TABLE message_receipts ENABLE ROW LEVEL SECURITY;
ALTER TABLE conversation_read_cursors ENABLE ROW LEVEL SECURITY;
ALTER TABLE device_tokens ENABLE ROW LEVEL SECURITY;

-- Helper: is the current user a member of the group?
CREATE OR REPLACE FUNCTION is_group_member(p_group_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM group_members
    WHERE group_id = p_group_id
      AND user_id = auth.uid()
  );
$$;

-- Profiles: users manage their own profile
CREATE POLICY profiles_select ON profiles
  FOR SELECT TO authenticated
  USING (user_id = auth.uid());

CREATE POLICY profiles_insert ON profiles
  FOR INSERT TO authenticated
  WITH CHECK (user_id = auth.uid());

CREATE POLICY profiles_update ON profiles
  FOR UPDATE TO authenticated
  USING (user_id = auth.uid());

-- Groups: visible to members
CREATE POLICY groups_select ON groups
  FOR SELECT TO authenticated
  USING (is_group_member(id));

-- Group members: visible to fellow members
CREATE POLICY group_members_select ON group_members
  FOR SELECT TO authenticated
  USING (is_group_member(group_id));

-- Conversations
CREATE POLICY conversations_select ON conversations
  FOR SELECT TO authenticated
  USING (is_group_member(group_id));

CREATE POLICY conversations_insert ON conversations
  FOR INSERT TO authenticated
  WITH CHECK (is_group_member(group_id));

-- Messages
CREATE POLICY messages_select ON messages
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM conversations c
      WHERE c.id = messages.conversation_id
        AND is_group_member(c.group_id)
    )
  );

-- Receipts: all group members can see all receipts
CREATE POLICY message_receipts_select ON message_receipts
  FOR SELECT TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM messages m
      JOIN conversations c ON c.id = m.conversation_id
      WHERE m.id = message_receipts.message_id
        AND is_group_member(c.group_id)
    )
  );

-- Read cursors: own rows only
CREATE POLICY read_cursors_all ON conversation_read_cursors
  FOR ALL TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());

-- Device tokens: own rows only
CREATE POLICY device_tokens_all ON device_tokens
  FOR ALL TO authenticated
  USING (user_id = auth.uid())
  WITH CHECK (user_id = auth.uid());
