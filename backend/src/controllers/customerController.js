// Customer-facing endpoints: fare quotes, booking a delivery (optionally via
// a collection point), and tracking parcels the customer sends or receives.

const pool = require("../config/db");

// Simple distance-based pricing. The owner can tune these via env vars; the
// final tariff decision is tracked in docs/NEEDS_FROM_OWNER.md.
const FARE_BASE_KSH = Number(process.env.FARE_BASE_KSH || 150);
const FARE_PER_KM_KSH = Number(process.env.FARE_PER_KM_KSH || 40);

function isValidLatitude(value) {
  return Number.isFinite(value) && value >= -90 && value <= 90;
}

function isValidLongitude(value) {
  return Number.isFinite(value) && value >= -180 && value <= 180;
}

function distanceKm(a, b) {
  const earthRadiusKm = 6371;
  const dLat = ((b.latitude - a.latitude) * Math.PI) / 180;
  const dLng = ((b.longitude - a.longitude) * Math.PI) / 180;
  const lat1 = (a.latitude * Math.PI) / 180;
  const lat2 = (b.latitude * Math.PI) / 180;

  const h =
    Math.sin(dLat / 2) * Math.sin(dLat / 2) +
    Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLng / 2) * Math.sin(dLng / 2);

  return earthRadiusKm * 2 * Math.atan2(Math.sqrt(h), Math.sqrt(1 - h));
}

// Fare over the actual route: pickup -> collection point -> dropoff when a
// point is used, otherwise pickup -> dropoff. Rounded up to the nearest 10.
function computeFare(stops) {
  let km = 0;
  for (let i = 1; i < stops.length; i += 1) {
    km += distanceKm(stops[i - 1], stops[i]);
  }
  const raw = FARE_BASE_KSH + km * FARE_PER_KM_KSH;
  return { fare: Math.ceil(raw / 10) * 10, distanceKm: Math.round(km * 10) / 10 };
}

function generateDeliveryPin() {
  return String(Math.floor(1000 + Math.random() * 9000));
}

async function loadCollectionPoint(collectionPointId) {
  const result = await pool.query(
    `SELECT id, name, address, latitude, longitude
       FROM collection_points
      WHERE id = $1 AND is_active = TRUE
      LIMIT 1`,
    [collectionPointId]
  );
  return result.rows[0] || null;
}

function parseStops(query) {
  const pickup = {
    latitude: Number(query.pickupLatitude),
    longitude: Number(query.pickupLongitude),
  };
  const dropoff = {
    latitude: Number(query.dropoffLatitude),
    longitude: Number(query.dropoffLongitude),
  };

  if (
    !isValidLatitude(pickup.latitude) ||
    !isValidLongitude(pickup.longitude) ||
    !isValidLatitude(dropoff.latitude) ||
    !isValidLongitude(dropoff.longitude)
  ) {
    return null;
  }

  return { pickup, dropoff };
}

async function quoteFare(req, res) {
  const stops = parseStops(req.query);

  if (!stops) {
    return res.status(400).json({ message: "Valid pickup and dropoff coordinates are required." });
  }

  const route = [stops.pickup];

  if (req.query.collectionPointId) {
    const point = await loadCollectionPoint(Number(req.query.collectionPointId));
    if (!point) {
      return res.status(404).json({ message: "Collection point not found or inactive." });
    }
    route.push({ latitude: Number(point.latitude), longitude: Number(point.longitude) });
  }

  route.push(stops.dropoff);

  const { fare, distanceKm: km } = computeFare(route);

  return res.json({
    fare,
    distanceKm: km,
    baseFare: FARE_BASE_KSH,
    perKm: FARE_PER_KM_KSH,
  });
}

async function listActiveCollectionPoints(req, res) {
  const result = await pool.query(
    `SELECT id, name, address, latitude, longitude
       FROM collection_points
      WHERE is_active = TRUE
      ORDER BY name`
  );

  return res.json({
    collectionPoints: result.rows.map((row) => ({
      id: row.id,
      name: row.name,
      address: row.address,
      latitude: Number(row.latitude),
      longitude: Number(row.longitude),
    })),
  });
}

async function bookDelivery(req, res) {
  const pickupAddress = String(req.body.pickupAddress || "").trim();
  const dropoffAddress = String(req.body.dropoffAddress || "").trim();
  const receiverName = String(req.body.receiverName || "").trim();
  const receiverPhone = String(req.body.receiverPhone || "").trim();
  const payer = String(req.body.payer || "receiver").trim();
  const notes = String(req.body.notes || "").trim() || null;
  const collectionPointId = req.body.collectionPointId
    ? Number(req.body.collectionPointId)
    : null;

  const stops = parseStops(req.body);

  if (!pickupAddress || !dropoffAddress) {
    return res.status(400).json({ message: "Pickup and dropoff addresses are required." });
  }

  if (!stops) {
    return res.status(400).json({ message: "Valid pickup and dropoff coordinates are required." });
  }

  if (!receiverName || receiverPhone.length < 7) {
    return res.status(400).json({ message: "Receiver name and a valid phone are required." });
  }

  if (!["sender", "receiver"].includes(payer)) {
    return res.status(400).json({ message: "Payer must be sender or receiver." });
  }

  const senderResult = await pool.query(
    `SELECT id, full_name FROM users WHERE id = $1 LIMIT 1`,
    [req.user.userId]
  );
  const sender = senderResult.rows[0];

  if (!sender) {
    return res.status(404).json({ message: "Your account was not found." });
  }

  const route = [stops.pickup];
  let collectionPoint = null;

  if (collectionPointId !== null) {
    collectionPoint = await loadCollectionPoint(collectionPointId);
    if (!collectionPoint) {
      return res.status(404).json({ message: "Collection point not found or inactive." });
    }
    route.push({
      latitude: Number(collectionPoint.latitude),
      longitude: Number(collectionPoint.longitude),
    });
  }

  route.push(stops.dropoff);
  const { fare } = computeFare(route);

  const receiverResult = await pool.query(
    `SELECT id FROM users WHERE phone = $1 AND role = 'customer' LIMIT 1`,
    [receiverPhone]
  );
  const receiverId = receiverResult.rows[0] ? receiverResult.rows[0].id : null;

  const insertResult = await pool.query(
    `
      INSERT INTO deliveries (
        customer_name,
        pickup_address, pickup_latitude, pickup_longitude,
        dropoff_address, dropoff_latitude, dropoff_longitude,
        status, fare_amount, delivery_pin,
        sender_id, receiver_id, receiver_name, receiver_phone,
        collection_point_id, current_leg, payer, notes
      )
      VALUES ($1, $2, $3, $4, $5, $6, $7, 'pending', $8, $9, $10, $11, $12, $13, $14, 1, $15, $16)
      RETURNING id
    `,
    [
      sender.full_name,
      pickupAddress,
      stops.pickup.latitude,
      stops.pickup.longitude,
      dropoffAddress,
      stops.dropoff.latitude,
      stops.dropoff.longitude,
      fare,
      generateDeliveryPin(),
      sender.id,
      receiverId,
      receiverName,
      receiverPhone,
      collectionPointId,
      payer,
      notes,
    ]
  );

  const deliveryId = insertResult.rows[0].id;

  await pool.query(
    `UPDATE deliveries SET tracking_code = 'STAN-' || LPAD(id::text, 6, '0') WHERE id = $1`,
    [deliveryId]
  );

  const delivery = await loadDeliveryForUser(deliveryId, sender.id);

  return res.status(201).json({
    message: "Delivery booked. Dispatch will assign a rider shortly.",
    delivery,
  });
}

// A customer sees deliveries they send and deliveries addressed to them
// (linked by account or matched by their phone number).
function formatCustomerDelivery(row, userId) {
  const isSender = row.sender_id === userId;
  const isReceiver = !isSender;

  return {
    id: row.id,
    role: isSender ? "sender" : "receiver",
    trackingCode: row.tracking_code || null,
    status: row.status,
    pickupAddress: row.pickup_address,
    dropoffAddress: row.dropoff_address,
    receiverName: row.receiver_name || null,
    receiverPhone: row.receiver_phone || null,
    senderName: row.sender_name || row.customer_name || null,
    viaCollectionPoint: Boolean(row.collection_point_id),
    collectionPointName: row.collection_point_name || null,
    currentLeg: row.collection_point_id ? Number(row.current_leg || 1) : 1,
    fareAmount: Number(row.fare_amount || 0),
    payer: row.payer || "receiver",
    paymentMethod: row.payment_method || "unpaid",
    paymentStatus: row.payment_status || "pending",
    // The handover PIN belongs to the receiver — they read it to the rider.
    deliveryPin: isReceiver && row.status !== "delivered" ? row.delivery_pin : null,
    riderName: row.rider_name || null,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

const CUSTOMER_DELIVERY_SELECT = `
  SELECT
    d.*,
    cp.name AS collection_point_name,
    sender.full_name AS sender_name,
    rider.full_name AS rider_name
  FROM deliveries d
  LEFT JOIN collection_points cp ON cp.id = d.collection_point_id
  LEFT JOIN users sender ON sender.id = d.sender_id
  LEFT JOIN driver_profiles dp ON dp.id = d.driver_id
  LEFT JOIN users rider ON rider.id = dp.user_id
`;

async function listMyDeliveries(req, res) {
  const meResult = await pool.query(`SELECT id, phone FROM users WHERE id = $1 LIMIT 1`, [
    req.user.userId,
  ]);
  const me = meResult.rows[0];

  if (!me) {
    return res.status(404).json({ message: "Your account was not found." });
  }

  const result = await pool.query(
    `
      ${CUSTOMER_DELIVERY_SELECT}
      WHERE d.sender_id = $1
         OR d.receiver_id = $1
         OR (d.receiver_phone IS NOT NULL AND d.receiver_phone = $2)
      ORDER BY d.created_at DESC
      LIMIT 100
    `,
    [me.id, me.phone]
  );

  return res.json({
    deliveries: result.rows.map((row) => formatCustomerDelivery(row, me.id)),
  });
}

async function loadDeliveryForUser(deliveryId, userId) {
  const meResult = await pool.query(`SELECT id, phone FROM users WHERE id = $1 LIMIT 1`, [userId]);
  const me = meResult.rows[0];
  if (!me) return null;

  const result = await pool.query(
    `
      ${CUSTOMER_DELIVERY_SELECT}
      WHERE d.id = $3
        AND (
          d.sender_id = $1
          OR d.receiver_id = $1
          OR (d.receiver_phone IS NOT NULL AND d.receiver_phone = $2)
        )
      LIMIT 1
    `,
    [me.id, me.phone, deliveryId]
  );

  return result.rows[0] ? formatCustomerDelivery(result.rows[0], me.id) : null;
}

async function getMyDelivery(req, res) {
  const deliveryId = Number(req.params.deliveryId);

  if (!Number.isInteger(deliveryId) || deliveryId <= 0) {
    return res.status(400).json({ message: "A valid delivery is required." });
  }

  const delivery = await loadDeliveryForUser(deliveryId, req.user.userId);

  if (!delivery) {
    return res.status(404).json({ message: "Delivery not found." });
  }

  // Live rider position (when a rider is on the parcel) for the tracking view.
  const locationResult = await pool.query(
    `
      SELECT dl.latitude, dl.longitude, dl.recorded_at
        FROM deliveries d
        JOIN driver_locations dl ON dl.driver_id = d.driver_id
       WHERE d.id = $1 AND d.driver_id IS NOT NULL
       ORDER BY dl.recorded_at DESC
       LIMIT 1
    `,
    [deliveryId]
  );

  const location = locationResult.rows[0];

  return res.json({
    delivery,
    riderLocation: location
      ? {
          latitude: Number(location.latitude),
          longitude: Number(location.longitude),
          recordedAt: location.recorded_at,
        }
      : null,
  });
}

module.exports = {
  quoteFare,
  listActiveCollectionPoints,
  bookDelivery,
  listMyDeliveries,
  getMyDelivery,
};
