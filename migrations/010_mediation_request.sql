-- Mediation request: parent topic → opposing parent response → mediator discussion → resolution → both parents approve.

ALTER TYPE conversation_action_type ADD VALUE IF NOT EXISTS 'mediation_request';

ALTER TYPE conversation_action_status ADD VALUE IF NOT EXISTS 'mediation_in_progress';
ALTER TYPE conversation_action_status ADD VALUE IF NOT EXISTS 'parent_approval_pending';

ALTER TABLE conversation_actions
  ADD COLUMN IF NOT EXISTS resolution_text TEXT,
  ADD COLUMN IF NOT EXISTS mediator_thread_root_id UUID REFERENCES messages(id),
  ADD COLUMN IF NOT EXISTS parent_a_approved_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS parent_b_approved_at TIMESTAMPTZ;
