// Shared wallet crediting: used by the driver payment-collection flow and by
// the M-Pesa callback handlers (STK + Paybill C2B).

const pool = require("../config/db");

const STAN_SERVICE_FEE_RATE = 0.15; // Stan's platform fee on each fare.

function toNumber(value) {
  return value === null || value === undefined ? 0 : Number(value);
}

function round2(value) {
  return Math.round(value * 100) / 100;
}

// Credits a delivery's fare (net of the service fee) and tip to a rider's
// wallet. Skips silently when the delivery has already been credited so the
// callback and the delivered-status paths can both call it safely.
async function creditEarningOnce(driverId, delivery, method, reference) {
  if (!driverId) return false;

  const existing = await pool.query(
    `SELECT id FROM wallet_transactions
      WHERE delivery_id = $1 AND type = 'earning'
      LIMIT 1`,
    [delivery.id]
  );

  if (existing.rows[0]) return false;

  const gross = toNumber(delivery.fare_amount);
  const fee = round2(gross * STAN_SERVICE_FEE_RATE);
  const net = round2(gross - fee);
  const tip = toNumber(delivery.tip_amount);

  await pool.query(
    `
      INSERT INTO wallet_transactions (driver_id, type, amount, delivery_id, method, status, reference, description)
      VALUES ($1, 'earning', $2, $3, $4, 'completed', $5, $6)
    `,
    [
      driverId,
      net,
      delivery.id,
      method,
      reference,
      `Delivery #${delivery.id} fare (gross ${gross}, fee ${fee})`,
    ]
  );

  if (tip > 0) {
    await pool.query(
      `
        INSERT INTO wallet_transactions (driver_id, type, amount, delivery_id, method, status, description)
        VALUES ($1, 'tip', $2, $3, $4, 'completed', $5)
      `,
      [driverId, tip, delivery.id, method, `Delivery #${delivery.id} tip`]
    );
  }

  return true;
}

module.exports = {
  STAN_SERVICE_FEE_RATE,
  creditEarningOnce,
  round2,
  toNumber,
};
