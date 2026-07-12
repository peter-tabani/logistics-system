-- Phase 2: collection points + two-leg delivery routing.
--
-- A delivery with collection_point_id set travels in two legs:
--   leg 1: sender -> collection point   (assigned/picked_up/in_transit
--                                        -> at_collection_point)
--   leg 2: collection point -> receiver (assigned/picked_up/in_transit
--                                        -> delivered)
-- driver_id always holds the rider currently responsible; leg1/leg2 columns
-- keep the per-leg history. Deliveries without a collection point keep the
-- original direct flow unchanged.

CREATE TABLE IF NOT EXISTS collection_points (
  id SERIAL PRIMARY KEY,
  name VARCHAR(120) NOT NULL,
  address TEXT NOT NULL,
  latitude DECIMAL(10, 7) NOT NULL,
  longitude DECIMAL(10, 7) NOT NULL,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

ALTER TABLE deliveries
  ADD COLUMN IF NOT EXISTS collection_point_id INTEGER REFERENCES collection_points(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS current_leg SMALLINT NOT NULL DEFAULT 1,
  ADD COLUMN IF NOT EXISTS leg1_driver_id INTEGER REFERENCES driver_profiles(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS leg2_driver_id INTEGER REFERENCES driver_profiles(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_deliveries_collection_point
  ON deliveries(collection_point_id);
