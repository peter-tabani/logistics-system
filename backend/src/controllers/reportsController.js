// Admin reports: trips per rider, collections, rider locations, and
// customer (sender/receiver) summaries. All computed on the fly over the
// core tables; date ranges are inclusive YYYY-MM-DD (default last 30 days).

const pool = require("../config/db");

const DATE_PATTERN = /^\d{4}-\d{2}-\d{2}$/;

function parseRange(query) {
  const today = new Date().toISOString().slice(0, 10);
  const monthAgo = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000)
    .toISOString()
    .slice(0, 10);

  const from = query.from && DATE_PATTERN.test(query.from) ? query.from : monthAgo;
  const to = query.to && DATE_PATTERN.test(query.to) ? query.to : today;

  return { from, to };
}

function toNumber(value) {
  return value === null || value === undefined ? 0 : Number(value);
}

// Trips per rider: totals, per-leg counts, delivered, and money moved.
async function tripsPerRider(req, res) {
  const { from, to } = parseRange(req.query);

  const result = await pool.query(
    `
      SELECT
        dp.id AS driver_id,
        u.full_name,
        u.phone,
        u.place_of_birth,
        u.place_of_residence,
        v.plate_number,
        (SELECT COUNT(*) FROM deliveries d
          WHERE (d.driver_id = dp.id OR d.leg1_driver_id = dp.id OR d.leg2_driver_id = dp.id)
            AND d.status <> 'cancelled'
            AND d.created_at::date BETWEEN $1 AND $2) AS trips_total,
        (SELECT COUNT(*) FROM deliveries d
          WHERE d.driver_id = dp.id AND d.status = 'delivered'
            AND d.updated_at::date BETWEEN $1 AND $2) AS trips_delivered,
        (SELECT COUNT(*) FROM deliveries d
          WHERE d.leg1_driver_id = dp.id AND d.collection_point_id IS NOT NULL
            AND d.created_at::date BETWEEN $1 AND $2) AS leg1_trips,
        (SELECT COUNT(*) FROM deliveries d
          WHERE d.leg2_driver_id = dp.id
            AND d.created_at::date BETWEEN $1 AND $2) AS leg2_trips,
        (SELECT COALESCE(SUM(d.fare_amount + d.tip_amount), 0) FROM deliveries d
          WHERE d.driver_id = dp.id AND d.payment_status = 'paid'
            AND d.updated_at::date BETWEEN $1 AND $2) AS gross_collected,
        (SELECT COALESCE(SUM(wt.amount), 0) FROM wallet_transactions wt
          WHERE wt.driver_id = dp.id AND wt.type IN ('earning', 'tip')
            AND wt.created_at::date BETWEEN $1 AND $2) AS net_earnings
      FROM driver_profiles dp
      JOIN users u ON u.id = dp.user_id
      LEFT JOIN vehicles v ON v.id = dp.vehicle_id
      ORDER BY trips_delivered DESC, trips_total DESC
    `,
    [from, to]
  );

  return res.json({
    from,
    to,
    rows: result.rows.map((row) => ({
      rider: row.full_name,
      phone: row.phone,
      plate: row.plate_number,
      tripsTotal: toNumber(row.trips_total),
      tripsDelivered: toNumber(row.trips_delivered),
      leg1Trips: toNumber(row.leg1_trips),
      leg2Trips: toNumber(row.leg2_trips),
      grossCollected: toNumber(row.gross_collected),
      netEarnings: toNumber(row.net_earnings),
    })),
  });
}

// Total amount collected: successful payments by day, method, and payer.
async function collections(req, res) {
  const { from, to } = parseRange(req.query);

  const [byDay, byMethod, byPayer, grand] = await Promise.all([
    pool.query(
      `
        SELECT created_at::date AS day, COUNT(*) AS count, COALESCE(SUM(amount), 0) AS total
        FROM payments
        WHERE status = 'success' AND created_at::date BETWEEN $1 AND $2
        GROUP BY day
        ORDER BY day
      `,
      [from, to]
    ),
    pool.query(
      `
        SELECT method, COUNT(*) AS count, COALESCE(SUM(amount), 0) AS total
        FROM payments
        WHERE status = 'success' AND created_at::date BETWEEN $1 AND $2
        GROUP BY method
        ORDER BY total DESC
      `,
      [from, to]
    ),
    pool.query(
      `
        SELECT payer_role, COUNT(*) AS count, COALESCE(SUM(amount), 0) AS total
        FROM payments
        WHERE status = 'success' AND created_at::date BETWEEN $1 AND $2
        GROUP BY payer_role
      `,
      [from, to]
    ),
    pool.query(
      `
        SELECT COUNT(*) AS count, COALESCE(SUM(amount), 0) AS total
        FROM payments
        WHERE status = 'success' AND created_at::date BETWEEN $1 AND $2
      `,
      [from, to]
    ),
  ]);

  return res.json({
    from,
    to,
    grandTotal: toNumber(grand.rows[0].total),
    paymentCount: toNumber(grand.rows[0].count),
    byMethod: byMethod.rows.map((row) => ({
      method: row.method,
      count: toNumber(row.count),
      total: toNumber(row.total),
    })),
    byPayer: byPayer.rows.map((row) => ({
      payer: row.payer_role,
      count: toNumber(row.count),
      total: toNumber(row.total),
    })),
    rows: byDay.rows.map((row) => ({
      day: row.day instanceof Date ? row.day.toISOString().slice(0, 10) : String(row.day),
      payments: toNumber(row.count),
      total: toNumber(row.total),
    })),
  });
}

// Last known position of every rider.
async function riderLocations(req, res) {
  const result = await pool.query(`
    SELECT
      dp.id AS driver_id,
      u.full_name,
      u.phone,
      dp.status,
      v.plate_number,
      latest.latitude,
      latest.longitude,
      latest.recorded_at
    FROM driver_profiles dp
    JOIN users u ON u.id = dp.user_id
    LEFT JOIN vehicles v ON v.id = dp.vehicle_id
    LEFT JOIN LATERAL (
      SELECT latitude, longitude, recorded_at
      FROM driver_locations
      WHERE driver_id = dp.id
      ORDER BY recorded_at DESC
      LIMIT 1
    ) latest ON TRUE
    ORDER BY latest.recorded_at DESC NULLS LAST
  `);

  const now = Date.now();

  return res.json({
    rows: result.rows.map((row) => ({
      rider: row.full_name,
      phone: row.phone,
      plate: row.plate_number,
      availability: row.status,
      latitude: row.latitude === null ? null : Number(row.latitude),
      longitude: row.longitude === null ? null : Number(row.longitude),
      lastSeen: row.recorded_at,
      minutesAgo: row.recorded_at
        ? Math.floor((now - new Date(row.recorded_at).getTime()) / 60000)
        : null,
    })),
  });
}

// Customer summaries. role=sender lists booking customers; role=receiver
// lists parcel receivers (linked to an account when one matches). Both
// include place of birth / place of residence where known.
async function customers(req, res) {
  const { from, to } = parseRange(req.query);
  const role = req.query.role === "receiver" ? "receiver" : "sender";

  if (role === "sender") {
    const result = await pool.query(
      `
        SELECT
          u.full_name,
          u.phone,
          u.email,
          u.place_of_birth,
          u.place_of_residence,
          COUNT(d.id) AS deliveries_sent,
          COUNT(d.id) FILTER (WHERE d.status = 'delivered') AS delivered,
          COALESCE(SUM(d.fare_amount) FILTER (WHERE d.payment_status = 'paid'), 0) AS paid_value
        FROM users u
        LEFT JOIN deliveries d
          ON d.sender_id = u.id AND d.created_at::date BETWEEN $1 AND $2
        WHERE u.role = 'customer'
        GROUP BY u.id
        ORDER BY deliveries_sent DESC, u.full_name
      `,
      [from, to]
    );

    return res.json({
      from,
      to,
      role,
      rows: result.rows.map((row) => ({
        customer: row.full_name,
        phone: row.phone,
        email: row.email,
        placeOfBirth: row.place_of_birth,
        placeOfResidence: row.place_of_residence,
        deliveriesSent: toNumber(row.deliveries_sent),
        delivered: toNumber(row.delivered),
        paidValue: toNumber(row.paid_value),
      })),
    });
  }

  const result = await pool.query(
    `
      SELECT
        COALESCE(account.full_name, d.receiver_name) AS full_name,
        COALESCE(account.phone, d.receiver_phone) AS phone,
        account.place_of_birth,
        account.place_of_residence,
        COUNT(*) AS deliveries_received,
        COUNT(*) FILTER (WHERE d.status = 'delivered') AS delivered
      FROM deliveries d
      LEFT JOIN LATERAL (
        SELECT full_name, phone, place_of_birth, place_of_residence
        FROM users
        WHERE role = 'customer'
          AND (id = d.receiver_id OR phone = d.receiver_phone)
        LIMIT 1
      ) account ON TRUE
      WHERE (d.receiver_id IS NOT NULL OR d.receiver_name IS NOT NULL OR d.receiver_phone IS NOT NULL)
        AND d.created_at::date BETWEEN $1 AND $2
      GROUP BY 1, 2, 3, 4
      ORDER BY deliveries_received DESC, full_name
    `,
    [from, to]
  );

  return res.json({
    from,
    to,
    role,
    rows: result.rows.map((row) => ({
      customer: row.full_name,
      phone: row.phone,
      placeOfBirth: row.place_of_birth,
      placeOfResidence: row.place_of_residence,
      deliveriesReceived: toNumber(row.deliveries_received),
      delivered: toNumber(row.delivered),
    })),
  });
}

module.exports = {
  tripsPerRider,
  collections,
  riderLocations,
  customers,
};
