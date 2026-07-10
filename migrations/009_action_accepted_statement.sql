-- Preserve original request when an alternative is approved; store agreed wording separately.

ALTER TABLE conversation_actions
  ADD COLUMN IF NOT EXISTS accepted_statement TEXT;
