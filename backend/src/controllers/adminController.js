const pool = require("../config/db");

const TRACKING_LOST_AFTER_MINUTES = 2;
const STOPPAGE_WINDOW_MINUTES = 5;
const STOPPAGE_RADIUS_METERS = 50;
const RECENT_EVENT_ALERT_WINDOW_MINUTES = 15;

function formatDelivery(row) {
  return {
    id: row.id,
    driverId: row.driver_id,
    driverName: row.driver_name,
    customerName: row.customer_name,
    pickupAddress: row.pickup_address,
    pickupLatitude: toNumberOrNull(row.pickup_latitude),
    pickupLongitude: toNumberOrNull(row.pickup_longitude),
    dropoffAddress: row.dropoff_address,
    dropoffLatitude: toNumberOrNull(row.dropoff_latitude),
    dropoffLongitude: toNumberOrNull(row.dropoff_longitude),
    status: row.status,
    fareAmount: row.fare_amount === undefined ? 0 : Number(row.fare_amount),
    tipAmount: row.tip_amount === undefined ? 0 : Number(row.tip_amount),
    paymentMethod: row.payment_method || "unpaid",
    paymentStatus: row.payment_status || "pending",
    deliveryPin: row.delivery_pin || null,
    trackingCode: row.tracking_code || null,
    senderId: row.sender_id || null,
    senderName: row.sender_name || null,
    receiverId: row.receiver_id || null,
    receiverName: row.receiver_name || null,
    receiverPhone: row.receiver_phone || null,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

function generateDeliveryPin() {
  return String(Math.floor(1000 + Math.random() * 9000));
}

function toNumberOrNull(value) {
  return value === null || value === undefined ? null : Number(value);
}

function isValidLatitude(value) {
  return Number.isFinite(value) && value >= -90 && value <= 90;
}

function isValidLongitude(value) {
  return Number.isFinite(value) && value >= -180 && value <= 180;
}

function calculateDistanceMeters(firstPoint, secondPoint) {
  const earthRadiusMeters = 6371000;
  const firstLatitude = (firstPoint.latitude * Math.PI) / 180;
  const secondLatitude = (secondPoint.latitude * Math.PI) / 180;
  const latitudeDelta = ((secondPoint.latitude - firstPoint.latitude) * Math.PI) / 180;
  const longitudeDelta = ((secondPoint.longitude - firstPoint.longitude) * Math.PI) / 180;

  const a =
    Math.sin(latitudeDelta / 2) * Math.sin(latitudeDelta / 2) +
    Math.cos(firstLatitude) *
      Math.cos(secondLatitude) *
      Math.sin(longitudeDelta / 2) *
      Math.sin(longitudeDelta / 2);
  const c = 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));

  return earthRadiusMeters * c;
}

function buildDriverLocation(row) {
  return {
    driverId: row.driver_id,
    driverName: row.driver_name,
    phone: row.phone,
    status: row.status,
    plateNumber: row.plate_number,
    activeDelivery: row.delivery_id
      ? {
          id: row.delivery_id,
          customerName: row.customer_name,
          status: row.delivery_status,
        pickupLatitude: toNumberOrNull(row.pickup_latitude),
        pickupLongitude: toNumberOrNull(row.pickup_longitude),
        dropoffLatitude: toNumberOrNull(row.dropoff_latitude),
        dropoffLongitude: toNumberOrNull(row.dropoff_longitude),
        }
      : null,
    location: row.latitude
      ? {
          latitude: Number(row.latitude),
          longitude: Number(row.longitude),
          accuracyMeters: toNumberOrNull(row.accuracy_meters),
          recordedAt: row.recorded_at,
        }
      : null,
  };
}

function formatTrackingEvent(row) {
  return {
    id: row.id,
    driverId: row.driver_id,
    driverName: row.driver_name,
    deliveryId: row.delivery_id,
    eventType: row.event_type,
    severity: row.severity,
    message: row.message,
    metadata: row.metadata,
    recordedAt: row.recorded_at,
  };
}

async function getDriverTrackingRows() {
  const result = await pool.query(`
    SELECT
      dp.id AS driver_id,
      u.full_name AS driver_name,
      u.phone,
      dp.status,
      v.plate_number,
      active_delivery.id AS delivery_id,
      active_delivery.customer_name,
      active_delivery.status AS delivery_status,
      active_delivery.pickup_latitude,
      active_delivery.pickup_longitude,
      active_delivery.dropoff_latitude,
      active_delivery.dropoff_longitude,
      latest_location.latitude,
      latest_location.longitude,
      latest_location.accuracy_meters,
      latest_location.recorded_at
    FROM driver_profiles dp
    JOIN users u ON u.id = dp.user_id
    LEFT JOIN vehicles v ON v.id = dp.vehicle_id
    LEFT JOIN LATERAL (
      SELECT
        id,
        customer_name,
        status,
        pickup_latitude,
        pickup_longitude,
        dropoff_latitude,
        dropoff_longitude
      FROM deliveries
      WHERE driver_id = dp.id AND status <> 'delivered'
      ORDER BY updated_at DESC, created_at DESC
      LIMIT 1
    ) active_delivery ON TRUE
    LEFT JOIN LATERAL (
      SELECT latitude, longitude, accuracy_meters, recorded_at
      FROM driver_locations
      WHERE driver_id = dp.id
      ORDER BY recorded_at DESC
      LIMIT 1
    ) latest_location ON TRUE
    ORDER BY dp.id
  `);

  return result.rows;
}

async function isDriverStopped(driverId, latestLocation) {
  if (!latestLocation) return false;

  const result = await pool.query(
    `
      SELECT latitude, longitude
      FROM driver_locations
      WHERE driver_id = $1
        AND recorded_at >= NOW() - ($2::text || ' minutes')::interval
      ORDER BY recorded_at ASC
    `,
    [driverId, STOPPAGE_WINDOW_MINUTES]
  );

  if (result.rows.length < 2) return false;

  const latestPoint = {
    latitude: Number(latestLocation.latitude),
    longitude: Number(latestLocation.longitude),
  };

  return result.rows.every((row) => {
    const point = {
      latitude: Number(row.latitude),
      longitude: Number(row.longitude),
    };

    return calculateDistanceMeters(point, latestPoint) <= STOPPAGE_RADIUS_METERS;
  });
}

async function buildTrackingAlerts(driverRows) {
  const now = Date.now();
  const alerts = [];

  for (const row of driverRows) {
    if (!row.delivery_id) continue;

    const minutesSinceLastUpdate = row.recorded_at
      ? Math.floor((now - new Date(row.recorded_at).getTime()) / 60000)
      : null;
    const isInTransit = ["picked_up", "in_transit"].includes(row.delivery_status);

    if (!row.recorded_at) {
      alerts.push({
        id: `no-location-${row.driver_id}-${row.delivery_id}`,
        severity: "high",
        type: "no_location",
        title: "No location received",
        message: `${row.driver_name} has an active delivery but has not sent any location yet.`,
        driverId: row.driver_id,
        driverName: row.driver_name,
        deliveryId: row.delivery_id,
        deliveryStatus: row.delivery_status,
        minutesSinceLastUpdate,
      });
      continue;
    }

    if (minutesSinceLastUpdate >= TRACKING_LOST_AFTER_MINUTES) {
      alerts.push({
        id: `tracking-lost-${row.driver_id}-${row.delivery_id}`,
        severity: "high",
        type: "tracking_lost",
        title: "Tracking update missing",
        message: `${row.driver_name} has not sent a location update for ${minutesSinceLastUpdate} minute(s).`,
        driverId: row.driver_id,
        driverName: row.driver_name,
        deliveryId: row.delivery_id,
        deliveryStatus: row.delivery_status,
        minutesSinceLastUpdate,
      });
    }

    if (isInTransit && (await isDriverStopped(row.driver_id, row))) {
      alerts.push({
        id: `stoppage-${row.driver_id}-${row.delivery_id}`,
        severity: "medium",
        type: "stoppage",
        title: "Possible stoppage",
        message: `${row.driver_name} appears to be within ${STOPPAGE_RADIUS_METERS}m for ${STOPPAGE_WINDOW_MINUTES}+ minutes while in transit.`,
        driverId: row.driver_id,
        driverName: row.driver_name,
        deliveryId: row.delivery_id,
        deliveryStatus: row.delivery_status,
        minutesSinceLastUpdate,
      });
    }
  }

  const eventResult = await pool.query(
    `
      SELECT
        e.id,
        e.driver_id,
        u.full_name AS driver_name,
        e.delivery_id,
        e.event_type,
        e.severity,
        e.message,
        e.recorded_at
      FROM driver_tracking_events e
      JOIN driver_profiles dp ON dp.id = e.driver_id
      JOIN users u ON u.id = dp.user_id
      WHERE e.severity IN ('warning', 'critical')
        AND e.recorded_at >= NOW() - ($1::text || ' minutes')::interval
      ORDER BY e.recorded_at DESC
      LIMIT 10
    `,
    [RECENT_EVENT_ALERT_WINDOW_MINUTES]
  );

  eventResult.rows.forEach((event) => {
    alerts.push({
      id: `event-${event.id}`,
      severity: event.severity === "critical" ? "high" : "medium",
      type: event.event_type,
      title: event.severity === "critical" ? "Critical tracking event" : "Tracking event",
      message: `${event.driver_name}: ${event.message}`,
      driverId: event.driver_id,
      driverName: event.driver_name,
      deliveryId: event.delivery_id,
      deliveryStatus: null,
      minutesSinceLastUpdate: null,
      recordedAt: event.recorded_at,
    });
  });

  return alerts;
}

async function getLatestDriverLocations(req, res) {
  const driverRows = await getDriverTrackingRows();
  const drivers = driverRows.map(buildDriverLocation);

  return res.json({ drivers });
}

async function getTrackingAlerts(req, res) {
  const driverRows = await getDriverTrackingRows();
  const alerts = await buildTrackingAlerts(driverRows);
  const activeDrivers = driverRows.filter((row) => row.delivery_id).length;
  const driversWithRecentLocation = driverRows.filter((row) => {
    if (!row.delivery_id || !row.recorded_at) return false;

    const minutesSinceLastUpdate = Math.floor(
      (Date.now() - new Date(row.recorded_at).getTime()) / 60000
    );

    return minutesSinceLastUpdate < TRACKING_LOST_AFTER_MINUTES;
  }).length;

  return res.json({
    alerts,
    summary: {
      activeDrivers,
      driversWithRecentLocation,
      alertCount: alerts.length,
      thresholds: {
        trackingLostAfterMinutes: TRACKING_LOST_AFTER_MINUTES,
        stoppageWindowMinutes: STOPPAGE_WINDOW_MINUTES,
        stoppageRadiusMeters: STOPPAGE_RADIUS_METERS,
      },
    },
  });
}

async function getDeliveries(req, res) {
  const result = await pool.query(`
    SELECT
      d.id,
      d.driver_id,
      u.full_name AS driver_name,
      d.customer_name,
      d.pickup_address,
      d.pickup_latitude,
      d.pickup_longitude,
      d.dropoff_address,
      d.dropoff_latitude,
      d.dropoff_longitude,
      d.status,
      d.fare_amount,
      d.tip_amount,
      d.payment_method,
      d.payment_status,
      d.delivery_pin,
      d.tracking_code,
      d.sender_id,
      sender.full_name AS sender_name,
      d.receiver_id,
      d.receiver_name,
      d.receiver_phone,
      d.created_at,
      d.updated_at
    FROM deliveries d
    LEFT JOIN driver_profiles dp ON dp.id = d.driver_id
    LEFT JOIN users u ON u.id = dp.user_id
    LEFT JOIN users sender ON sender.id = d.sender_id
    ORDER BY d.created_at DESC
  `);

  return res.json({
    deliveries: result.rows.map(formatDelivery),
  });
}

async function getTrackingEvents(req, res) {
  const limit = Math.min(Number(req.query.limit) || 30, 100);

  const result = await pool.query(
    `
      SELECT
        e.id,
        e.driver_id,
        u.full_name AS driver_name,
        e.delivery_id,
        e.event_type,
        e.severity,
        e.message,
        e.metadata,
        e.recorded_at
      FROM driver_tracking_events e
      JOIN driver_profiles dp ON dp.id = e.driver_id
      JOIN users u ON u.id = dp.user_id
      ORDER BY e.recorded_at DESC
      LIMIT $1
    `,
    [limit]
  );

  return res.json({
    events: result.rows.map(formatTrackingEvent),
  });
}

async function createDelivery(req, res) {
  const driverId = Number(req.body.driverId);
  const customerName = String(req.body.customerName || "").trim();
  const pickupAddress = String(req.body.pickupAddress || "").trim();
  const dropoffAddress = String(req.body.dropoffAddress || "").trim();
  const pickupLatitude = Number(req.body.pickupLatitude);
  const pickupLongitude = Number(req.body.pickupLongitude);
  const dropoffLatitude = Number(req.body.dropoffLatitude);
  const dropoffLongitude = Number(req.body.dropoffLongitude);
  const receiverName = String(req.body.receiverName || "").trim() || null;
  const receiverPhone = String(req.body.receiverPhone || "").trim() || null;
  const fareAmount = Number(req.body.fareAmount) || 0;

  if (fareAmount < 0 || fareAmount > 1000000) {
    return res.status(400).json({
      message: "Fare must be a non-negative amount.",
    });
  }

  if (!Number.isInteger(driverId) || driverId <= 0) {
    return res.status(400).json({
      message: "A valid driver is required.",
    });
  }

  if (!customerName || !pickupAddress || !dropoffAddress) {
    return res.status(400).json({
      message: "Customer name, pickup address, and dropoff address are required.",
    });
  }

  if (
    !isValidLatitude(pickupLatitude) ||
    !isValidLongitude(pickupLongitude) ||
    !isValidLatitude(dropoffLatitude) ||
    !isValidLongitude(dropoffLongitude)
  ) {
    return res.status(400).json({
      message: "Valid pickup and dropoff coordinates are required.",
    });
  }

  const driverResult = await pool.query(
    `
      SELECT id
      FROM driver_profiles
      WHERE id = $1
      LIMIT 1
    `,
    [driverId]
  );

  if (!driverResult.rows[0]) {
    return res.status(404).json({
      message: "Selected driver was not found.",
    });
  }

  // Link the receiver to a customer account when their phone matches one.
  let receiverId = null;
  if (receiverPhone) {
    const receiverResult = await pool.query(
      `SELECT id FROM users WHERE phone = $1 AND role = 'customer' LIMIT 1`,
      [receiverPhone]
    );
    receiverId = receiverResult.rows[0] ? receiverResult.rows[0].id : null;
  }

  const insertResult = await pool.query(
    `
      INSERT INTO deliveries (
        driver_id,
        customer_name,
        pickup_address,
        pickup_latitude,
        pickup_longitude,
        dropoff_address,
        dropoff_latitude,
        dropoff_longitude,
        status,
        fare_amount,
        delivery_pin,
        receiver_id,
        receiver_name,
        receiver_phone
      )
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 'assigned', $9, $10, $11, $12, $13)
      RETURNING id
    `,
    [
      driverId,
      customerName,
      pickupAddress,
      pickupLatitude,
      pickupLongitude,
      dropoffAddress,
      dropoffLatitude,
      dropoffLongitude,
      fareAmount,
      generateDeliveryPin(),
      receiverId,
      receiverName,
      receiverPhone,
    ]
  );

  const deliveryId = insertResult.rows[0].id;

  const result = await pool.query(
    `
      UPDATE deliveries
         SET tracking_code = 'STAN-' || LPAD(id::text, 6, '0')
       WHERE id = $1
       RETURNING *
    `,
    [deliveryId]
  );

  return res.status(201).json({
    message: "Delivery created.",
    delivery: formatDelivery(result.rows[0]),
  });
}

module.exports = {
  createDelivery,
  getDeliveries,
  getLatestDriverLocations,
  getTrackingAlerts,
  getTrackingEvents,
};
