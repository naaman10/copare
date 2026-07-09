-- Per-member delivery/read receipts and audit events for actions.
-- Extends conversation read cursors; backfills sender message receipts for audit completeness.

CREATE TABLE action_receipts (
  action_id    UUID NOT NULL REFERENCES conversation_actions(id),
  user_id      UUID NOT NULL REFERENCES neon_auth."user"(id),
  delivered_at TIMESTAMPTZ,
  read_at      TIMESTAMPTZ,
  PRIMARY KEY (action_id, user_id)
);

CREATE TABLE action_events (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  action_id   UUID NOT NULL REFERENCES conversation_actions(id),
  event_type  TEXT NOT NULL,
  actor_id    UUID REFERENCES neon_auth."user"(id),
  metadata    JSONB,
  occurred_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX idx_action_events_action ON action_events (action_id, occurred_at);

ALTER TABLE conversation_read_cursors
  ADD COLUMN last_read_action_id UUID REFERENCES conversation_actions(id);

-- Sender saw their own message at send time.
INSERT INTO message_receipts (message_id, user_id, delivered_at, read_at)
SELECT m.id, m.sender_id, m.created_at, m.created_at
FROM messages m
WHERE NOT EXISTS (
  SELECT 1 FROM message_receipts mr
  WHERE mr.message_id = m.id AND mr.user_id = m.sender_id
);
