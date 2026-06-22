// Uber-style driver features for Stan: profile, documents, availability,
// wallet/earnings, and payment collection.
//
// PAYMENTS ARE DEMO/MOCK ONLY — no Daraja API, no real money. The M-Pesa
// STK-push flow is simulated. See CLAUDE.md.

const pool = require("../config/db");

const STAN_SERVICE_FEE_RATE = 0.15; // Stan's demo platform fee on each fare.

const DOCUMENT_TYPES = ["license", "ntsa", "psv", "insurance", "inspection"];

async function getDriverProfile(userId) {
  const result = await pool.query(
    `SELECT id FROM driver_profiles WHERE user_id = $1 LIMIT 1`,
    [userId]
  );
  return result.rows[0];
}

function toNumber(value) {
  return value === null || value === undefined ? 0 : Number(value);
}

function round2(value) {
  return Math.round(value * 100) / 100;
}

// DEMO M-Pesa receipt code, e.g. "QGT4AB9KD1". Not a real Safaricom receipt.
function demoMpesaReference() {
  const letters = "ABCDEFGHJKLMNPQRSTUVWXYZ";
  const digits = "0123456789";
  let code = "";
  for (let i = 0; i < 10; i += 1) {
    const pool = i % 2 === 0 ? letters : digits;
    code += pool[Math.floor(Math.random() * pool.length)];
  }
  return code;
}

function proTier(completedTrips) {
  if (completedTrips >= 60) return "Platinum";
  if (completedTrips >= 30) return "Gold";
  if (completedTrips >= 10) return "Silver";
  return "Bronze";
}

async function walletBalance(driverId) {
  const result = await pool.query(
    `SELECT COALESCE(SUM(amount), 0) AS balance
       FROM wallet_transactions
      WHERE driver_id = $1 AND status = 'completed'`,
    [driverId]
  );
  return round2(toNumber(result.rows[0].balance));
}

/* ------------------------------- Profile -------------------------------- */

async function getProfile(req, res) {
  const driver = await getDriverProfile(req.user.userId);
  if (!driver) return res.status(404).json({ message: "Driver profile not found." });

  const result = await pool.query(
    `
      SELECT
        u.full_name, u.phone, u.email, u.created_at AS member_since,
        dp.status, dp.rating, dp.bio, dp.license_number,
        v.plate_number, v.vehicle_type,
        (SELECT COUNT(*) FROM deliveries d
          WHERE d.driver_id = dp.id AND d.status = 'delivered') AS completed_trips,
        (SELECT COUNT(*) FROM deliveries d
          WHERE d.driver_id = dp.id AND d.status <> 'delivered') AS active_trips
      FROM driver_profiles dp
      JOIN users u ON u.id = dp.user_id
      LEFT JOIN vehicles v ON v.id = dp.vehicle_id
      WHERE dp.id = $1
    `,
    [driver.id]
  );

  const row = result.rows[0];
  const completedTrips = Number(row.completed_trips);

  return res.json({
    profile: {
      fullName: row.full_name,
      phone: row.phone,
      email: row.email,
      memberSince: row.member_since,
      availability: row.status,
      rating: toNumber(row.rating),
      bio: row.bio,
      licenseNumber: row.license_number,
      completedTrips,
      activeTrips: Number(row.active_trips),
      tier: proTier(completedTrips),
      vehicle: row.plate_number
        ? { plateNumber: row.plate_number, vehicleType: row.vehicle_type }
        : null,
    },
  });
}

async function updateProfile(req, res) {
  const driver = await getDriverProfile(req.user.userId);
  if (!driver) return res.status(404).json({ message: "Driver profile not found." });

  const bio = typeof req.body.bio === "string" ? req.body.bio.trim().slice(0, 400) : null;

  await pool.query(`UPDATE driver_profiles SET bio = $1 WHERE id = $2`, [bio, driver.id]);
  return res.json({ message: "Profile updated.", bio });
}

async function updateAccount(req, res) {
  const phone = typeof req.body.phone === "string" ? req.body.phone.trim() : null;
  const email = typeof req.body.email === "string" ? req.body.email.trim() : null;

  if (phone && phone.length < 7) {
    return res.status(400).json({ message: "Enter a valid phone number." });
  }

  try {
    const result = await pool.query(
      `
        UPDATE users
           SET phone = COALESCE($1, phone),
               email = COALESCE($2, email),
               updated_at = NOW()
         WHERE id = $3
         RETURNING phone, email
      `,
      [phone, email, req.user.userId]
    );
    return res.json({ message: "Account updated.", account: result.rows[0] });
  } catch (error) {
    // Unique violation on phone/email
    if (error.code === "23505") {
      return res.status(409).json({ message: "That phone or email is already in use." });
    }
    throw error;
  }
}

async function updateAvailability(req, res) {
  const allowed = new Set(["online", "offline", "break"]);
  const status = String(req.body.status || "").trim();

  if (!allowed.has(status)) {
    return res.status(400).json({ message: "Status must be online, offline, or break." });
  }

  const driver = await getDriverProfile(req.user.userId);
  if (!driver) return res.status(404).json({ message: "Driver profile not found." });

  await pool.query(`UPDATE driver_profiles SET status = $1 WHERE id = $2`, [status, driver.id]);
  return res.json({ message: "Availability updated.", availability: status });
}

/* ------------------------------ Documents ------------------------------- */

async function getDocuments(req, res) {
  const driver = await getDriverProfile(req.user.userId);
  if (!driver) return res.status(404).json({ message: "Driver profile not found." });

  const result = await pool.query(
    `
      SELECT doc_type, doc_number, status, expiry_date, updated_at
        FROM driver_documents
       WHERE driver_id = $1
    `,
    [driver.id]
  );

  const byType = new Map(result.rows.map((row) => [row.doc_type, row]));
  const documents = DOCUMENT_TYPES.map((type) => {
    const row = byType.get(type);
    return {
      docType: type,
      docNumber: row ? row.doc_number : null,
      status: row ? row.status : "missing",
      expiryDate: row ? row.expiry_date : null,
      updatedAt: row ? row.updated_at : null,
    };
  });

  return res.json({ documents });
}

async function updateDocument(req, res) {
  const docType = String(req.params.docType || "").trim();
  if (!DOCUMENT_TYPES.includes(docType)) {
    return res.status(400).json({ message: "Unknown document type." });
  }

  const driver = await getDriverProfile(req.user.userId);
  if (!driver) return res.status(404).json({ message: "Driver profile not found." });

  const docNumber = typeof req.body.docNumber === "string" ? req.body.docNumber.trim() : null;
  const expiryDate = req.body.expiryDate || null;

  if (!docNumber) {
    return res.status(400).json({ message: "A document number is required." });
  }

  // DEMO: submitting a document number auto-marks it verified.
  const result = await pool.query(
    `
      INSERT INTO driver_documents (driver_id, doc_type, doc_number, status, expiry_date, updated_at)
      VALUES ($1, $2, $3, 'verified', $4, NOW())
      ON CONFLICT (driver_id, doc_type)
      DO UPDATE SET doc_number = EXCLUDED.doc_number,
                    status = 'verified',
                    expiry_date = EXCLUDED.expiry_date,
                    updated_at = NOW()
      RETURNING doc_type, doc_number, status, expiry_date, updated_at
    `,
    [driver.id, docType, docNumber, expiryDate]
  );

  return res.json({ message: "Document submitted (demo auto-verified).", document: result.rows[0] });
}

/* --------------------------- Wallet & earnings -------------------------- */

function formatTransaction(row) {
  return {
    id: row.id,
    type: row.type,
    amount: toNumber(row.amount),
    deliveryId: row.delivery_id,
    method: row.method,
    status: row.status,
    reference: row.reference,
    description: row.description,
    createdAt: row.created_at,
  };
}

async function getEarnings(req, res) {
  const driver = await getDriverProfile(req.user.userId);
  if (!driver) return res.status(404).json({ message: "Driver profile not found." });

  const balance = await walletBalance(driver.id);

  // Gross fares + tips for paid deliveries, grouped by today / this week.
  const summary = await pool.query(
    `
      SELECT
        COALESCE(SUM(fare_amount) FILTER (WHERE updated_at::date = CURRENT_DATE), 0) AS today_gross,
        COALESCE(SUM(tip_amount)  FILTER (WHERE updated_at::date = CURRENT_DATE), 0) AS today_tips,
        COALESCE(COUNT(*)         FILTER (WHERE updated_at::date = CURRENT_DATE), 0) AS today_trips,
        COALESCE(SUM(fare_amount) FILTER (WHERE updated_at >= date_trunc('week', CURRENT_DATE)), 0) AS week_gross,
        COALESCE(SUM(tip_amount)  FILTER (WHERE updated_at >= date_trunc('week', CURRENT_DATE)), 0) AS week_tips,
        COALESCE(COUNT(*)         FILTER (WHERE updated_at >= date_trunc('week', CURRENT_DATE)), 0) AS week_trips
      FROM deliveries
      WHERE driver_id = $1 AND payment_status = 'paid'
    `,
    [driver.id]
  );

  const s = summary.rows[0];
  const build = (gross, tips, trips) => {
    const g = toNumber(gross);
    const fee = round2(g * STAN_SERVICE_FEE_RATE);
    return {
      gross: round2(g),
      fee,
      tips: round2(toNumber(tips)),
      net: round2(g - fee + toNumber(tips)),
      trips: Number(trips),
    };
  };

  const transactions = await pool.query(
    `
      SELECT id, type, amount, delivery_id, method, status, reference, description, created_at
        FROM wallet_transactions
       WHERE driver_id = $1
       ORDER BY created_at DESC
       LIMIT 30
    `,
    [driver.id]
  );

  return res.json({
    balance,
    serviceFeeRate: STAN_SERVICE_FEE_RATE,
    today: build(s.today_gross, s.today_tips, s.today_trips),
    week: build(s.week_gross, s.week_tips, s.week_trips),
    transactions: transactions.rows.map(formatTransaction),
  });
}

// DEMO M-Pesa cash-out (STK push to the driver's own number is simulated by the
// app; here we just record the payout against the wallet).
async function cashOut(req, res) {
  const driver = await getDriverProfile(req.user.userId);
  if (!driver) return res.status(404).json({ message: "Driver profile not found." });

  const amount = round2(Number(req.body.amount));
  if (!Number.isFinite(amount) || amount <= 0) {
    return res.status(400).json({ message: "Enter a valid amount." });
  }

  const balance = await walletBalance(driver.id);
  if (amount > balance) {
    return res.status(400).json({ message: "Amount exceeds your wallet balance." });
  }

  const reference = demoMpesaReference();
  const result = await pool.query(
    `
      INSERT INTO wallet_transactions (driver_id, type, amount, method, status, reference, description)
      VALUES ($1, 'payout', $2, 'mpesa', 'completed', $3, 'M-Pesa cash-out (DEMO)')
      RETURNING id, type, amount, delivery_id, method, status, reference, description, created_at
    `,
    [driver.id, -amount, reference]
  );

  return res.json({
    message: "Cash-out sent to M-Pesa (DEMO).",
    reference,
    balance: round2(balance - amount),
    transaction: formatTransaction(result.rows[0]),
  });
}

/* --------------------------- Payment collection ------------------------- */

async function loadOwnedDelivery(driverId, deliveryId) {
  const result = await pool.query(
    `
      SELECT id, driver_id, fare_amount, tip_amount, payment_method, payment_status, delivery_pin
        FROM deliveries
       WHERE id = $1 AND driver_id = $2
       LIMIT 1
    `,
    [deliveryId, driverId]
  );
  return result.rows[0];
}

async function creditEarning(driverId, delivery, method, reference) {
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
}

async function collectPayment(req, res) {
  const driver = await getDriverProfile(req.user.userId);
  if (!driver) return res.status(404).json({ message: "Driver profile not found." });

  const deliveryId = Number(req.params.deliveryId);
  const method = String(req.body.method || "").trim(); // cash | mpesa
  const tipAmount = round2(Number(req.body.tipAmount) || 0);

  if (!["cash", "mpesa"].includes(method)) {
    return res.status(400).json({ message: "Payment method must be cash or mpesa." });
  }

  const delivery = await loadOwnedDelivery(driver.id, deliveryId);
  if (!delivery) return res.status(404).json({ message: "Delivery not found." });
  if (delivery.payment_status === "paid") {
    return res.status(400).json({ message: "This delivery is already paid." });
  }

  if (tipAmount > 0) {
    await pool.query(`UPDATE deliveries SET tip_amount = $1 WHERE id = $2`, [tipAmount, deliveryId]);
    delivery.tip_amount = tipAmount;
  }

  if (method === "cash") {
    await pool.query(
      `UPDATE deliveries SET payment_method = 'cash', payment_status = 'paid', updated_at = NOW() WHERE id = $1`,
      [deliveryId]
    );
    await creditEarning(driver.id, delivery, "cash", null);
    return res.json({ message: "Cash payment recorded.", paymentStatus: "paid", method: "cash" });
  }

  // M-Pesa: simulate an STK push. Mark pending; the app calls /mpesa-result
  // after the (simulated) customer prompt. DEMO ONLY — no Daraja call here.
  const checkoutRequestId = `ws_CO_DEMO_${Date.now()}`;
  await pool.query(
    `UPDATE deliveries SET payment_method = 'mpesa', payment_status = 'pending', updated_at = NOW() WHERE id = $1`,
    [deliveryId]
  );

  return res.json({
    message: "STK push sent to customer (DEMO).",
    paymentStatus: "pending",
    method: "mpesa",
    checkoutRequestId,
    demo: true,
  });
}

async function mpesaResult(req, res) {
  const driver = await getDriverProfile(req.user.userId);
  if (!driver) return res.status(404).json({ message: "Driver profile not found." });

  const deliveryId = Number(req.params.deliveryId);
  const success = req.body.success !== false; // default to success in demo

  const delivery = await loadOwnedDelivery(driver.id, deliveryId);
  if (!delivery) return res.status(404).json({ message: "Delivery not found." });
  if (delivery.payment_status === "paid") {
    return res.json({ message: "Already paid.", paymentStatus: "paid" });
  }

  if (!success) {
    await pool.query(
      `UPDATE deliveries SET payment_status = 'failed', updated_at = NOW() WHERE id = $1`,
      [deliveryId]
    );
    return res.json({ message: "Customer cancelled the M-Pesa prompt (DEMO).", paymentStatus: "failed" });
  }

  const reference = demoMpesaReference();
  await pool.query(
    `UPDATE deliveries SET payment_status = 'paid', updated_at = NOW() WHERE id = $1`,
    [deliveryId]
  );
  await creditEarning(driver.id, delivery, "mpesa", reference);

  return res.json({
    message: "M-Pesa payment received (DEMO).",
    paymentStatus: "paid",
    method: "mpesa",
    reference,
  });
}

/* --------------------------------- SOS ---------------------------------- */

async function triggerSos(req, res) {
  const driver = await getDriverProfile(req.user.userId);
  if (!driver) return res.status(404).json({ message: "Driver profile not found." });

  const lat = req.body.latitude;
  const lng = req.body.longitude;

  await pool.query(
    `
      INSERT INTO driver_tracking_events (driver_id, event_type, severity, message, metadata)
      VALUES ($1, 'sos', 'critical', 'Driver triggered the SOS emergency button.', $2)
    `,
    [
      driver.id,
      JSON.stringify({
        latitude: lat ?? null,
        longitude: lng ?? null,
        source: "sos_button",
      }),
    ]
  );

  return res.status(201).json({ message: "SOS alert sent to dispatch." });
}

module.exports = {
  getProfile,
  updateProfile,
  updateAccount,
  updateAvailability,
  getDocuments,
  updateDocument,
  getEarnings,
  cashOut,
  collectPayment,
  mpesaResult,
  triggerSos,
};
