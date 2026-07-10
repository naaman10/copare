-- Assignee can propose an alternative on decline; creator then approves or rejects it.

ALTER TYPE conversation_action_status ADD VALUE IF NOT EXISTS 'alternative_pending';
