CREATE TABLE IF NOT EXISTS users (
  id SERIAL PRIMARY KEY,
  full_name VARCHAR(120) NOT NULL,
  phone VARCHAR(30) UNIQUE NOT NULL,
  email VARCHAR(150) UNIQUE,
  password_hash TEXT NOT NULL,
  role VARCHAR(20) NOT NULL CHECK (role IN ('admin', 'driver')),
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS vehicles (
  id SERIAL PRIMARY KEY,
  plate_number VARCHAR(40) UNIQUE NOT NULL,
  vehicle_type VARCHAR(80),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS driver_profiles (
  id SERIAL PRIMARY KEY,
  user_id INTEGER UNIQUE NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  vehicle_id INTEGER REFERENCES vehicles(id) ON DELETE SET NULL,
  license_number VARCHAR(80),
  status VARCHAR(30) NOT NULL DEFAULT 'offline',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS deliveries (
  id SERIAL PRIMARY KEY,
  driver_id INTEGER REFERENCES driver_profiles(id) ON DELETE SET NULL,
  customer_name VARCHAR(120) NOT NULL,
  pickup_address TEXT NOT NULL,
  pickup_latitude DECIMAL(10, 7),
  pickup_longitude DECIMAL(10, 7),
  dropoff_address TEXT NOT NULL,
  dropoff_latitude DECIMAL(10, 7),
  dropoff_longitude DECIMAL(10, 7),
  status VARCHAR(30) NOT NULL DEFAULT 'pending',
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE deliveries
  ADD COLUMN IF NOT EXISTS pickup_latitude DECIMAL(10, 7),
  ADD COLUMN IF NOT EXISTS pickup_longitude DECIMAL(10, 7),
  ADD COLUMN IF NOT EXISTS dropoff_latitude DECIMAL(10, 7),
  ADD COLUMN IF NOT EXISTS dropoff_longitude DECIMAL(10, 7);

CREATE TABLE IF NOT EXISTS driver_locations (
  id BIGSERIAL PRIMARY KEY,
  driver_id INTEGER NOT NULL REFERENCES driver_profiles(id) ON DELETE CASCADE,
  latitude DECIMAL(10, 7) NOT NULL,
  longitude DECIMAL(10, 7) NOT NULL,
  accuracy_meters DECIMAL(8, 2),
  recorded_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_driver_locations_driver_recorded
  ON driver_locations(driver_id, recorded_at DESC);

CREATE TABLE IF NOT EXISTS driver_tracking_events (
  id BIGSERIAL PRIMARY KEY,
  driver_id INTEGER NOT NULL REFERENCES driver_profiles(id) ON DELETE CASCADE,
  delivery_id INTEGER REFERENCES deliveries(id) ON DELETE SET NULL,
  event_type VARCHAR(60) NOT NULL,
  severity VARCHAR(20) NOT NULL DEFAULT 'info' CHECK (severity IN ('info', 'warning', 'critical')),
  message TEXT NOT NULL,
  metadata JSONB NOT NULL DEFAULT '{}'::jsonb,
  recorded_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_driver_tracking_events_recorded
  ON driver_tracking_events(recorded_at DESC);

CREATE INDEX IF NOT EXISTS idx_driver_tracking_events_driver_recorded
  ON driver_tracking_events(driver_id, recorded_at DESC);

-- ---------------------------------------------------------------------------
-- Driver feature set (Uber-style): payments (DEMO/MOCK only), proof-of-delivery
-- PIN, documents, wallet. All additive and non-destructive.
-- ---------------------------------------------------------------------------

-- Delivery payment + handover PIN (DEMO payments only — see CLAUDE.md).
ALTER TABLE deliveries
  ADD COLUMN IF NOT EXISTS fare_amount DECIMAL(10, 2) NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS tip_amount DECIMAL(10, 2) NOT NULL DEFAULT 0,
  -- payment_method: unpaid | cash | mpesa
  ADD COLUMN IF NOT EXISTS payment_method VARCHAR(20) NOT NULL DEFAULT 'unpaid',
  -- payment_status: pending | paid | failed
  ADD COLUMN IF NOT EXISTS payment_status VARCHAR(20) NOT NULL DEFAULT 'pending',
  ADD COLUMN IF NOT EXISTS delivery_pin VARCHAR(4);

-- Driver profile extras (rating + bio for the Uber-style profile).
ALTER TABLE driver_profiles
  ADD COLUMN IF NOT EXISTS rating DECIMAL(3, 2) NOT NULL DEFAULT 5.00,
  ADD COLUMN IF NOT EXISTS bio TEXT;

-- Compliance documents (driver's licence, NTSA clearance, PSV badge, insurance,
-- vehicle inspection). Metadata only — no real files are stored.
CREATE TABLE IF NOT EXISTS driver_documents (
  id SERIAL PRIMARY KEY,
  driver_id INTEGER NOT NULL REFERENCES driver_profiles(id) ON DELETE CASCADE,
  doc_type VARCHAR(40) NOT NULL,
  doc_number VARCHAR(80),
  -- status: verified | pending | expired | missing
  status VARCHAR(20) NOT NULL DEFAULT 'missing',
  expiry_date DATE,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (driver_id, doc_type)
);

-- Wallet ledger. amount is positive for credits (earning/tip) and negative for
-- payouts (cash-out). reference holds a DEMO M-Pesa receipt code where relevant.
CREATE TABLE IF NOT EXISTS wallet_transactions (
  id BIGSERIAL PRIMARY KEY,
  driver_id INTEGER NOT NULL REFERENCES driver_profiles(id) ON DELETE CASCADE,
  -- type: earning | tip | payout
  type VARCHAR(20) NOT NULL,
  amount DECIMAL(10, 2) NOT NULL,
  delivery_id INTEGER REFERENCES deliveries(id) ON DELETE SET NULL,
  -- method: cash | mpesa
  method VARCHAR(20),
  -- status: completed | pending | failed
  status VARCHAR(20) NOT NULL DEFAULT 'completed',
  reference VARCHAR(60),
  description TEXT,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_wallet_transactions_driver_created
  ON wallet_transactions(driver_id, created_at DESC);

-- ---------------------------------------------------------------------------
-- Messaging (WhatsApp-style inbox): conversations + messages.
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS conversations (
  id SERIAL PRIMARY KEY,
  driver_id INTEGER NOT NULL REFERENCES driver_profiles(id) ON DELETE CASCADE,
  -- party: dispatch | support | customer
  party VARCHAR(40) NOT NULL,
  title VARCHAR(120) NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE (driver_id, party, title)
);

CREATE TABLE IF NOT EXISTS messages (
  id BIGSERIAL PRIMARY KEY,
  conversation_id INTEGER NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
  -- sender: driver | dispatch | support | customer
  sender VARCHAR(20) NOT NULL,
  body TEXT NOT NULL,
  read_by_driver BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_messages_conversation_created
  ON messages(conversation_id, created_at);
