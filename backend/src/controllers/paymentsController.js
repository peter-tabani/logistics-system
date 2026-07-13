// Payment endpoints: Safaricom callbacks (STK + Paybill C2B), payment status
// polling, the sender pay-now flow, and payment config for the apps.
//
// Real-ready, not live: with no Daraja credentials configured everything runs
// in simulate mode (see services/daraja.js). Callback routes are public —
// Safaricom calls them — but they only act on payments/deliveries they match.

const pool = require("../config/db");
const daraja = require("../services/daraja");
const { creditEarningOnce } = require("../services/wallet");

async function loadDelivery(deliveryId) {
  const result = await pool.query(`SELECT * FROM deliveries WHERE id = $1 LIMIT 1`, [deliveryId]);
  return result.rows[0] || null;
}

// Marks a payment successful, flips the delivery to paid, and credits the
// assigned rider (if any — prepaid bookings credit later at delivered).
async function settleSuccessfulPayment(payment, { receipt, rawCallback } = {}) {
  await pool.query(
    `
      UPDATE payments
         SET status = 'success',
             mpesa_receipt = COALESCE($1, mpesa_receipt),
             raw_callback = COALESCE($2, raw_callback),
             updated_at = NOW()
       WHERE id = $3
    `,
    [receipt || null, rawCallback ? JSON.stringify(rawCallback) : null, payment.id]
  );

  if (!payment.delivery_id) return;

  const method = payment.method === "cash" ? "cash" : "mpesa";
  await pool.query(
    `
      UPDATE deliveries
         SET payment_method = $1, payment_status = 'paid', updated_at = NOW()
       WHERE id = $2
    `,
    [method, payment.delivery_id]
  );

  const delivery = await loadDelivery(payment.delivery_id);
  if (delivery && delivery.driver_id) {
    await creditEarningOnce(delivery.driver_id, delivery, method, receipt || null);
  }
}

async function markPaymentFailed(payment, reason, rawCallback) {
  await pool.query(
    `
      UPDATE payments
         SET status = 'failed',
             failure_reason = $1,
             raw_callback = COALESCE($2, raw_callback),
             updated_at = NOW()
       WHERE id = $3
    `,
    [reason || "Payment failed.", rawCallback ? JSON.stringify(rawCallback) : null, payment.id]
  );

  if (payment.delivery_id) {
    await pool.query(
      `UPDATE deliveries SET payment_status = 'failed', updated_at = NOW() WHERE id = $1 AND payment_status <> 'paid'`,
      [payment.delivery_id]
    );
  }
}

/* ------------------------- Safaricom callbacks -------------------------- */

// POST /payments/mpesa/stk-callback — Lipa na M-Pesa Online result.
async function stkCallback(req, res) {
  // Always answer 200 so Safaricom does not retry forever; log what we skip.
  try {
    const callback = req.body?.Body?.stkCallback;
    if (!callback || !callback.CheckoutRequestID) {
      return res.json({ ResultCode: 0, ResultDesc: "Accepted" });
    }

    const paymentResult = await pool.query(
      `SELECT * FROM payments WHERE checkout_request_id = $1 ORDER BY id DESC LIMIT 1`,
      [callback.CheckoutRequestID]
    );
    const payment = paymentResult.rows[0];

    if (!payment || payment.status !== "pending") {
      return res.json({ ResultCode: 0, ResultDesc: "Accepted" });
    }

    if (Number(callback.ResultCode) === 0) {
      const items = callback.CallbackMetadata?.Item || [];
      const receipt = items.find((item) => item.Name === "MpesaReceiptNumber")?.Value;
      await settleSuccessfulPayment(payment, {
        receipt: receipt ? String(receipt) : null,
        rawCallback: req.body,
      });
    } else {
      await markPaymentFailed(payment, callback.ResultDesc, req.body);
    }
  } catch (error) {
    console.error(`STK callback error: ${error.message}`);
  }

  return res.json({ ResultCode: 0, ResultDesc: "Accepted" });
}

// POST /payments/mpesa/c2b-validation — pre-payment check for Paybill.
async function c2bValidation(req, res) {
  // Accept everything; unmatched references are reconciled by the owner.
  return res.json({ ResultCode: 0, ResultDesc: "Accepted" });
}

// POST /payments/mpesa/c2b-confirmation — a customer paid the Paybill
// directly, using the delivery tracking code as the account number.
async function c2bConfirmation(req, res) {
  try {
    const body = req.body || {};
    const reference = String(body.BillRefNumber || "").trim().toUpperCase();
    const amount = Number(body.TransAmount) || 0;
    const receipt = String(body.TransID || "").trim() || null;
    const phone = String(body.MSISDN || "").trim() || null;

    if (reference) {
      const deliveryResult = await pool.query(
        `SELECT * FROM deliveries WHERE UPPER(tracking_code) = $1 LIMIT 1`,
        [reference]
      );
      const delivery = deliveryResult.rows[0];

      if (delivery && delivery.payment_status !== "paid") {
        const paymentResult = await pool.query(
          `
            INSERT INTO payments (delivery_id, payer_role, method, amount, phone, status, mode, mpesa_receipt, account_reference, raw_callback)
            VALUES ($1, $2, 'mpesa_paybill', $3, $4, 'pending', $5, $6, $7, $8)
            RETURNING *
          `,
          [
            delivery.id,
            delivery.payer || "receiver",
            amount || Number(delivery.fare_amount) || 0,
            phone,
            daraja.mode(),
            receipt,
            reference,
            JSON.stringify(body),
          ]
        );

        await settleSuccessfulPayment(paymentResult.rows[0], { receipt });
      }
    }
  } catch (error) {
    console.error(`C2B confirmation error: ${error.message}`);
  }

  return res.json({ ResultCode: 0, ResultDesc: "Accepted" });
}

/* ------------------------------ App-facing ------------------------------ */

// GET /payments/config — how the apps should present M-Pesa options.
async function getConfig(req, res) {
  return res.json({
    mode: daraja.mode(),
    simulated: daraja.isSimulated(),
    paybillShortcode: daraja.paybillShortcode(),
    paybillAccountHint: "Use the delivery tracking code (e.g. STAN-000123) as the account number.",
  });
}

// Shared: latest payment + delivery payment state, for app polling.
async function paymentStatusPayload(deliveryId) {
  const delivery = await loadDelivery(deliveryId);
  if (!delivery) return null;

  const paymentResult = await pool.query(
    `SELECT * FROM payments WHERE delivery_id = $1 ORDER BY id DESC LIMIT 1`,
    [deliveryId]
  );
  const payment = paymentResult.rows[0];

  return {
    paymentStatus: delivery.payment_status,
    paymentMethod: delivery.payment_method,
    payment: payment
      ? {
          id: payment.id,
          method: payment.method,
          status: payment.status,
          mode: payment.mode,
          amount: Number(payment.amount),
          reference: payment.mpesa_receipt,
          failureReason: payment.failure_reason,
        }
      : null,
  };
}

// POST /customer/deliveries/:deliveryId/pay — sender pays now via STK push.
async function customerPayNow(req, res) {
  const deliveryId = Number(req.params.deliveryId);
  const delivery = await loadDelivery(deliveryId);

  if (!delivery || delivery.sender_id !== req.user.userId) {
    return res.status(404).json({ message: "Delivery not found." });
  }

  if (delivery.payment_status === "paid") {
    return res.status(400).json({ message: "This delivery is already paid." });
  }

  const amount = Number(delivery.fare_amount) || 0;
  if (amount <= 0) {
    return res.status(400).json({ message: "This delivery has no fare to pay." });
  }

  const meResult = await pool.query(`SELECT phone FROM users WHERE id = $1 LIMIT 1`, [
    req.user.userId,
  ]);
  const phone = String(req.body.phone || meResult.rows[0]?.phone || "").trim();

  if (phone.length < 9) {
    return res.status(400).json({ message: "A valid M-Pesa phone number is required." });
  }

  let stk;
  try {
    stk = await daraja.stkPush({
      phone,
      amount,
      accountReference: delivery.tracking_code || `STAN-${delivery.id}`,
      description: "Stan delivery",
    });
  } catch (error) {
    return res.status(502).json({ message: `M-Pesa request failed: ${error.message}` });
  }

  const paymentResult = await pool.query(
    `
      INSERT INTO payments (delivery_id, payer_role, method, amount, phone, status, mode, checkout_request_id, merchant_request_id, account_reference)
      VALUES ($1, 'sender', 'mpesa_stk', $2, $3, 'pending', $4, $5, $6, $7)
      RETURNING id
    `,
    [
      delivery.id,
      amount,
      daraja.normalizeMsisdn(phone),
      stk.mode,
      stk.checkoutRequestId,
      stk.merchantRequestId,
      delivery.tracking_code,
    ]
  );

  await pool.query(
    `UPDATE deliveries SET payment_method = 'mpesa', payment_status = 'pending', updated_at = NOW() WHERE id = $1`,
    [delivery.id]
  );

  return res.json({
    message:
      stk.mode === "simulate"
        ? "STK push sent (DEMO — approve in the simulated prompt)."
        : "STK push sent. Ask the payer to enter their M-Pesa PIN.",
    mode: stk.mode,
    simulated: stk.mode === "simulate",
    paymentId: paymentResult.rows[0].id,
    checkoutRequestId: stk.checkoutRequestId,
    paybillShortcode: daraja.paybillShortcode(),
    accountReference: delivery.tracking_code,
  });
}

// POST /customer/deliveries/:deliveryId/pay/simulate-result — resolves a
// SIMULATED sender STK push (mirrors the driver mpesa-result flow).
async function customerSimulateResult(req, res) {
  const deliveryId = Number(req.params.deliveryId);
  const delivery = await loadDelivery(deliveryId);

  if (!delivery || delivery.sender_id !== req.user.userId) {
    return res.status(404).json({ message: "Delivery not found." });
  }

  const paymentResult = await pool.query(
    `SELECT * FROM payments
      WHERE delivery_id = $1 AND method = 'mpesa_stk' AND status = 'pending'
      ORDER BY id DESC LIMIT 1`,
    [deliveryId]
  );
  const payment = paymentResult.rows[0];

  if (!payment) {
    return res.status(404).json({ message: "No pending M-Pesa payment found." });
  }

  if (payment.mode !== "simulate") {
    return res.status(400).json({
      message: "This payment runs against real Daraja — the result arrives via Safaricom callback.",
    });
  }

  const success = req.body.success !== false;

  if (!success) {
    await markPaymentFailed(payment, "Payer cancelled the simulated prompt.");
    return res.json({ paymentStatus: "failed", message: "Payment cancelled (DEMO)." });
  }

  const receipt = daraja.simulatedReceipt();
  await settleSuccessfulPayment(payment, { receipt });

  return res.json({
    paymentStatus: "paid",
    reference: receipt,
    message: "M-Pesa payment received (DEMO).",
  });
}

// GET /customer/deliveries/:deliveryId/payment-status
async function customerPaymentStatus(req, res) {
  const deliveryId = Number(req.params.deliveryId);
  const delivery = await loadDelivery(deliveryId);

  if (!delivery) {
    return res.status(404).json({ message: "Delivery not found." });
  }

  const meResult = await pool.query(`SELECT phone FROM users WHERE id = $1 LIMIT 1`, [
    req.user.userId,
  ]);
  const myPhone = meResult.rows[0]?.phone;
  const involved =
    delivery.sender_id === req.user.userId ||
    delivery.receiver_id === req.user.userId ||
    (delivery.receiver_phone && delivery.receiver_phone === myPhone);

  if (!involved) {
    return res.status(404).json({ message: "Delivery not found." });
  }

  return res.json(await paymentStatusPayload(deliveryId));
}

// GET /driver/deliveries/:deliveryId/payment-status
async function driverPaymentStatus(req, res) {
  const deliveryId = Number(req.params.deliveryId);
  const driverResult = await pool.query(
    `SELECT id FROM driver_profiles WHERE user_id = $1 LIMIT 1`,
    [req.user.userId]
  );
  const driver = driverResult.rows[0];

  if (!driver) {
    return res.status(404).json({ message: "Driver profile not found." });
  }

  const delivery = await loadDelivery(deliveryId);
  if (!delivery || delivery.driver_id !== driver.id) {
    return res.status(404).json({ message: "Delivery not found." });
  }

  return res.json(await paymentStatusPayload(deliveryId));
}

// POST /payments/mpesa/register-c2b — owner runs this once after configuring
// Daraja credentials so Paybill payments reach our confirmation callback.
async function registerC2b(req, res) {
  try {
    const result = await daraja.registerC2bUrls();
    return res.json(result);
  } catch (error) {
    return res.status(502).json({ message: error.message });
  }
}

module.exports = {
  stkCallback,
  c2bValidation,
  c2bConfirmation,
  getConfig,
  customerPayNow,
  customerSimulateResult,
  customerPaymentStatus,
  driverPaymentStatus,
  registerC2b,
  settleSuccessfulPayment,
  markPaymentFailed,
};
