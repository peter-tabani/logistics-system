-- Phase 3: customer bookings.
--
-- payer: who settles the fare — 'sender' (pay at/after booking) or
-- 'receiver' (pay on delivery). Existing deliveries default to receiver,
-- which matches the current collect-on-delivery flow.

ALTER TABLE deliveries
  ADD COLUMN IF NOT EXISTS payer VARCHAR(20) NOT NULL DEFAULT 'receiver',
  ADD COLUMN IF NOT EXISTS notes TEXT;
