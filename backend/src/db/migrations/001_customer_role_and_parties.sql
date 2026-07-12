-- Phase 1: customer role, profile fields, and sender/receiver parties.

-- Allow the 'customer' role alongside admin/driver.
ALTER TABLE users DROP CONSTRAINT IF EXISTS users_role_check;
ALTER TABLE users ADD CONSTRAINT users_role_check
  CHECK (role IN ('admin', 'driver', 'customer'));

-- Profile fields for both customers and riders (surfaced in reports).
ALTER TABLE users
  ADD COLUMN IF NOT EXISTS place_of_birth VARCHAR(120),
  ADD COLUMN IF NOT EXISTS place_of_residence VARCHAR(120);

-- Sender / receiver parties on deliveries. customer_name stays for
-- back-compat; the receiver may not hold an account, so name/phone are
-- stored directly and receiver_id links when a matching account exists.
ALTER TABLE deliveries
  ADD COLUMN IF NOT EXISTS sender_id INTEGER REFERENCES users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS receiver_id INTEGER REFERENCES users(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS receiver_name VARCHAR(120),
  ADD COLUMN IF NOT EXISTS receiver_phone VARCHAR(30),
  ADD COLUMN IF NOT EXISTS tracking_code VARCHAR(20);

-- Human-readable tracking code (also the Paybill account reference later).
UPDATE deliveries
   SET tracking_code = 'STAN-' || LPAD(id::text, 6, '0')
 WHERE tracking_code IS NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_deliveries_tracking_code
  ON deliveries(tracking_code);
