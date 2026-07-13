-- Phase 4: payment transactions (M-Pesa STK push, Paybill C2B, cash).
--
-- Every payment attempt gets a row here. mode records whether the attempt
-- ran against real Daraja (sandbox/production) or the built-in simulation
-- (no credentials configured). account_reference carries the delivery
-- tracking code, which is also the Paybill account number customers enter.

CREATE TABLE IF NOT EXISTS payments (
  id BIGSERIAL PRIMARY KEY,
  delivery_id INTEGER REFERENCES deliveries(id) ON DELETE SET NULL,
  payer_role VARCHAR(20) NOT NULL DEFAULT 'receiver',
  -- method: mpesa_stk | mpesa_paybill | cash
  method VARCHAR(30) NOT NULL,
  amount DECIMAL(10, 2) NOT NULL,
  phone VARCHAR(30),
  -- status: pending | success | failed
  status VARCHAR(20) NOT NULL DEFAULT 'pending',
  -- mode: simulate | sandbox | production
  mode VARCHAR(20) NOT NULL DEFAULT 'simulate',
  checkout_request_id VARCHAR(80),
  merchant_request_id VARCHAR(80),
  mpesa_receipt VARCHAR(40),
  account_reference VARCHAR(40),
  failure_reason TEXT,
  raw_callback JSONB,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_payments_delivery ON payments(delivery_id);
CREATE INDEX IF NOT EXISTS idx_payments_checkout ON payments(checkout_request_id);
