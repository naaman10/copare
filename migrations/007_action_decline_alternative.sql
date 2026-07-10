-- Decline flow: required reason (response_note) + optional alternative wording.

ALTER TABLE conversation_actions
  ADD COLUMN IF NOT EXISTS alternative_statement TEXT;
