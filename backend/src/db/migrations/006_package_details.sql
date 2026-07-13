-- Customer app v2: package size on bookings (small | medium | large).
-- Cancellation reuses the status column (status = 'cancelled'), no schema
-- change needed for it.

ALTER TABLE deliveries
  ADD COLUMN IF NOT EXISTS package_size VARCHAR(20);
