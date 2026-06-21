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
