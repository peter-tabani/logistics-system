-- Phase 5: rider self-registration with admin approval.
--
-- Existing riders default to 'approved' so nothing changes for them; new
-- signups are created 'pending' and cannot work until an admin approves.

ALTER TABLE driver_profiles
  ADD COLUMN IF NOT EXISTS approval_status VARCHAR(20) NOT NULL DEFAULT 'approved',
  ADD COLUMN IF NOT EXISTS approval_note TEXT;
