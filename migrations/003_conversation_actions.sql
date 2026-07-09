-- Conversation actions (v1: confirmation requests)

CREATE TYPE conversation_action_type AS ENUM ('confirmation_request');
CREATE TYPE conversation_action_status AS ENUM ('pending', 'confirmed', 'declined');

CREATE TABLE conversation_actions (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  conversation_id UUID NOT NULL REFERENCES conversations(id),
  group_id        UUID NOT NULL REFERENCES groups(id),
  created_by      UUID NOT NULL REFERENCES neon_auth."user"(id),
  assigned_to     UUID NOT NULL REFERENCES neon_auth."user"(id),
  action_type     conversation_action_type NOT NULL,
  status          conversation_action_status NOT NULL DEFAULT 'pending',
  statement       TEXT NOT NULL,
  response_note   TEXT,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  resolved_at     TIMESTAMPTZ,
  resolved_by     UUID REFERENCES neon_auth."user"(id)
);

CREATE INDEX idx_conversation_actions_conversation
  ON conversation_actions (conversation_id, created_at ASC);
