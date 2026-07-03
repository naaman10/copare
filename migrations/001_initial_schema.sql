-- Copare initial schema
-- Prerequisites: Neon Auth enabled (neon_auth."user" table exists)

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------

CREATE TYPE group_status AS ENUM ('forming', 'active', 'archived');
CREATE TYPE member_role AS ENUM ('parent_a', 'parent_b', 'mediator_a', 'mediator_b');
CREATE TYPE invitation_status AS ENUM ('pending', 'accepted', 'expired', 'revoked');
CREATE TYPE mediator_action_status AS ENUM ('pending', 'completed', 'dismissed');
CREATE TYPE mediator_action_type AS ENUM (
  'review_message',
  'approve_message',
  'intervene',
  'escalate'
);

-- ---------------------------------------------------------------------------
-- Profiles (extends neon_auth identity)
-- ---------------------------------------------------------------------------

CREATE TABLE profiles (
  user_id      UUID PRIMARY KEY REFERENCES neon_auth."user"(id) ON DELETE CASCADE,
  display_name TEXT NOT NULL,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Groups & membership
-- ---------------------------------------------------------------------------

CREATE TABLE groups (
  id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  status       group_status NOT NULL DEFAULT 'forming',
  created_by   UUID NOT NULL REFERENCES neon_auth."user"(id),
  activated_at TIMESTAMPTZ,
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE group_members (
  id        UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id  UUID NOT NULL REFERENCES groups(id),
  user_id   UUID NOT NULL REFERENCES neon_auth."user"(id),
  role      member_role NOT NULL,
  joined_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (group_id, role),
  UNIQUE (group_id, user_id)
);

CREATE INDEX idx_group_members_user ON group_members (user_id);

-- ---------------------------------------------------------------------------
-- Invitations
-- ---------------------------------------------------------------------------

CREATE TABLE invitations (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id    UUID NOT NULL REFERENCES groups(id),
  invited_by  UUID NOT NULL REFERENCES neon_auth."user"(id),
  role        member_role NOT NULL,
  email       TEXT NOT NULL,
  token       TEXT NOT NULL UNIQUE,
  status      invitation_status NOT NULL DEFAULT 'pending',
  expires_at  TIMESTAMPTZ NOT NULL,
  accepted_at TIMESTAMPTZ,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX idx_invitations_pending_role
  ON invitations (group_id, role)
  WHERE status = 'pending';

-- ---------------------------------------------------------------------------
-- Conversations & messages
-- ---------------------------------------------------------------------------

CREATE TABLE conversations (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id        UUID NOT NULL REFERENCES groups(id),
  title           TEXT NOT NULL,
  created_by      UUID NOT NULL REFERENCES neon_auth."user"(id),
  last_message_at TIMESTAMPTZ,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_conversations_group ON conversations (group_id, last_message_at DESC NULLS LAST);

CREATE TABLE messages (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id UUID NOT NULL REFERENCES conversations(id),
  sender_id       UUID NOT NULL REFERENCES neon_auth."user"(id),
  parent_id       UUID REFERENCES messages(id),
  root_id         UUID REFERENCES messages(id),
  body            TEXT NOT NULL,
  client_id       TEXT NOT NULL,
  deleted_at      TIMESTAMPTZ,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  edited_at       TIMESTAMPTZ,
  UNIQUE (conversation_id, sender_id, client_id)
);

CREATE INDEX idx_messages_conversation_top_level
  ON messages (conversation_id, created_at DESC)
  WHERE deleted_at IS NULL AND root_id IS NULL;

CREATE INDEX idx_messages_subthread
  ON messages (root_id, created_at ASC)
  WHERE deleted_at IS NULL;

-- ---------------------------------------------------------------------------
-- Receipts & read cursors
-- ---------------------------------------------------------------------------

CREATE TABLE message_receipts (
  message_id   UUID NOT NULL REFERENCES messages(id),
  user_id      UUID NOT NULL REFERENCES neon_auth."user"(id),
  delivered_at TIMESTAMPTZ,
  read_at      TIMESTAMPTZ,
  PRIMARY KEY (message_id, user_id)
);

CREATE TABLE conversation_read_cursors (
  user_id              UUID NOT NULL REFERENCES neon_auth."user"(id),
  conversation_id      UUID NOT NULL REFERENCES conversations(id),
  last_read_message_id UUID REFERENCES messages(id),
  last_read_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, conversation_id)
);

-- ---------------------------------------------------------------------------
-- Permanent archive
-- ---------------------------------------------------------------------------

CREATE TABLE message_revisions (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  message_id UUID NOT NULL REFERENCES messages(id),
  body       TEXT NOT NULL,
  revised_by UUID NOT NULL REFERENCES neon_auth."user"(id),
  revised_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE message_events (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  message_id  UUID NOT NULL REFERENCES messages(id),
  event_type  TEXT NOT NULL,
  actor_id    UUID REFERENCES neon_auth."user"(id),
  metadata    JSONB,
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_message_events_message ON message_events (message_id, occurred_at);

-- Block hard deletes on messages (permanent archive)
CREATE OR REPLACE FUNCTION prevent_message_delete()
RETURNS TRIGGER AS $$
BEGIN
  RAISE EXCEPTION 'Messages cannot be deleted; use soft delete (deleted_at)';
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_prevent_message_delete
  BEFORE DELETE ON messages
  FOR EACH ROW EXECUTE FUNCTION prevent_message_delete();

-- ---------------------------------------------------------------------------
-- Future mediator actions (v1: table only)
-- ---------------------------------------------------------------------------

CREATE TABLE mediator_actions (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  group_id        UUID NOT NULL REFERENCES groups(id),
  message_id      UUID REFERENCES messages(id),
  conversation_id UUID REFERENCES conversations(id),
  assigned_to     UUID NOT NULL REFERENCES neon_auth."user"(id),
  action_type     mediator_action_type NOT NULL,
  status          mediator_action_status NOT NULL DEFAULT 'pending',
  notes           TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at    TIMESTAMPTZ
);

-- ---------------------------------------------------------------------------
-- Push notifications
-- ---------------------------------------------------------------------------

CREATE TABLE device_tokens (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    UUID NOT NULL REFERENCES neon_auth."user"(id),
  token      TEXT NOT NULL,
  platform   TEXT NOT NULL DEFAULT 'ios',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (user_id, token)
);

CREATE TABLE notification_outbox (
  id         UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id    UUID NOT NULL REFERENCES neon_auth."user"(id),
  payload    JSONB NOT NULL,
  status     TEXT NOT NULL DEFAULT 'pending',
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  sent_at    TIMESTAMPTZ
);

CREATE INDEX idx_notification_outbox_pending
  ON notification_outbox (created_at)
  WHERE status = 'pending';

-- ---------------------------------------------------------------------------
-- Group activation trigger
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION check_group_activation()
RETURNS TRIGGER AS $$
DECLARE
  member_count INT;
BEGIN
  SELECT COUNT(*) INTO member_count FROM group_members WHERE group_id = NEW.group_id;
  IF member_count = 4 THEN
    UPDATE groups
    SET status = 'active', activated_at = COALESCE(activated_at, now())
    WHERE id = NEW.group_id AND status = 'forming';
  END IF;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_group_activation
  AFTER INSERT ON group_members
  FOR EACH ROW EXECUTE FUNCTION check_group_activation();
