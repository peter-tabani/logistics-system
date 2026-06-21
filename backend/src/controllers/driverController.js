const pool = require("../config/db");

const allowedDeliveryStatuses = new Set(["picked_up", "in_transit", "delivered"]);
const allowedTrackingEventSeverities = new Set(["info", "warning", "critical"]);

function formatDelivery(row) {
  return {
    id: row.id,
    customerName: row.customer_name,
    pickupAddress: row.pickup_address,
    pickupLatitude: row.pickup_latitude === null ? null : Number(row.pickup_latitude),
    pickupLongitude: row.pickup_longitude === null ? null : Number(row.pickup_longitude),
    dropoffAddress: row.dropoff_address,
    dropoffLatitude: row.dropoff_latitude === null ? null : Number(row.dropoff_latitude),
    dropoffLongitude: row.dropoff_longitude === null ? null : Number(row.dropoff_longitude),
    status: row.status,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

async function getDriverProfile(userId) {
  const result = await pool.query(
    `
      SELECT id
      FROM driver_profiles
      WHERE user_id = $1
      LIMIT 1
    `,
    [userId]
  );

  return result.rows[0];
}

function isValidLatitude(value) {
  return Number.isFinite(value) && value >= -90 && value <= 90;
}

function isValidLongitude(value) {
  return Number.isFinite(value) && value >= -180 && value <= 180;
}

async function saveLocation(req, res) {
  const latitude = Number(req.body.latitude);
  const longitude = Number(req.body.longitude);
  const accuracyMeters = req.body.accuracyMeters === undefined ? null : Number(req.body.accuracyMeters);

  if (!isValidLatitude(latitude) || !isValidLongitude(longitude)) {
    return res.status(400).json({
      message: "Valid latitude and longitude are required.",
    });
  }

  if (accuracyMeters !== null && (!Number.isFinite(accuracyMeters) || accuracyMeters < 0)) {
    return res.status(400).json({
      message: "Accuracy must be a positive number.",
    });
  }

  const driver = await getDriverProfile(req.user.userId);

  if (!driver) {
    return res.status(404).json({
      message: "Driver profile was not found.",
    });
  }

  const locationResult = await pool.query(
    `
      INSERT INTO driver_locations (driver_id, latitude, longitude, accuracy_meters)
      VALUES ($1, $2, $3, $4)
      RETURNING id, latitude, longitude, accuracy_meters, recorded_at
    `,
    [driver.id, latitude, longitude, accuracyMeters]
  );

  await pool.query(
    `
      UPDATE driver_profiles
      SET status = 'online'
      WHERE id = $1
    `,
    [driver.id]
  );

  const location = locationResult.rows[0];

  return res.status(201).json({
    message: "Location saved.",
    location: {
      id: location.id,
      latitude: Number(location.latitude),
      longitude: Number(location.longitude),
      accuracyMeters: location.accuracy_meters === null ? null : Number(location.accuracy_meters),
      recordedAt: location.recorded_at,
    },
  });
}

async function getAssignedDeliveries(req, res) {
  const driver = await getDriverProfile(req.user.userId);

  if (!driver) {
    return res.status(404).json({
      message: "Driver profile was not found.",
    });
  }

  const result = await pool.query(
    `
      SELECT
        id,
        customer_name,
        pickup_address,
        pickup_latitude,
        pickup_longitude,
        dropoff_address,
        dropoff_latitude,
        dropoff_longitude,
        status,
        created_at,
        updated_at
      FROM deliveries
      WHERE driver_id = $1
      ORDER BY
        CASE WHEN status = 'delivered' THEN 1 ELSE 0 END,
        created_at DESC
    `,
    [driver.id]
  );

  return res.json({
    deliveries: result.rows.map(formatDelivery),
  });
}

async function updateDeliveryStatus(req, res) {
  const deliveryId = Number(req.params.deliveryId);
  const status = String(req.body.status || "").trim();

  if (!Number.isInteger(deliveryId) || deliveryId <= 0) {
    return res.status(400).json({
      message: "A valid delivery is required.",
    });
  }

  if (!allowedDeliveryStatuses.has(status)) {
    return res.status(400).json({
      message: "Status must be picked_up, in_transit, or delivered.",
    });
  }

  const driver = await getDriverProfile(req.user.userId);

  if (!driver) {
    return res.status(404).json({
      message: "Driver profile was not found.",
    });
  }

  const result = await pool.query(
    `
      UPDATE deliveries
      SET status = $1, updated_at = NOW()
      WHERE id = $2 AND driver_id = $3
      RETURNING
        id,
        customer_name,
        pickup_address,
        pickup_latitude,
        pickup_longitude,
        dropoff_address,
        dropoff_latitude,
        dropoff_longitude,
        status,
        created_at,
        updated_at
    `,
    [status, deliveryId, driver.id]
  );

  const delivery = result.rows[0];

  if (!delivery) {
    return res.status(404).json({
      message: "Delivery was not found for this driver.",
    });
  }

  return res.json({
    message: "Delivery status updated.",
    delivery: formatDelivery(delivery),
  });
}

async function saveTrackingEvent(req, res) {
  const eventType = String(req.body.eventType || "").trim();
  const severity = String(req.body.severity || "info").trim();
  const message = String(req.body.message || "").trim();
  const deliveryId = req.body.deliveryId === undefined || req.body.deliveryId === null
    ? null
    : Number(req.body.deliveryId);
  const metadata = req.body.metadata && typeof req.body.metadata === "object" ? req.body.metadata : {};

  if (!eventType || eventType.length > 60) {
    return res.status(400).json({
      message: "A valid tracking event type is required.",
    });
  }

  if (!allowedTrackingEventSeverities.has(severity)) {
    return res.status(400).json({
      message: "Severity must be info, warning, or critical.",
    });
  }

  if (!message) {
    return res.status(400).json({
      message: "A tracking event message is required.",
    });
  }

  if (deliveryId !== null && (!Number.isInteger(deliveryId) || deliveryId <= 0)) {
    return res.status(400).json({
      message: "Delivery id must be valid when provided.",
    });
  }

  const driver = await getDriverProfile(req.user.userId);

  if (!driver) {
    return res.status(404).json({
      message: "Driver profile was not found.",
    });
  }

  const result = await pool.query(
    `
      INSERT INTO driver_tracking_events (driver_id, delivery_id, event_type, severity, message, metadata)
      VALUES ($1, $2, $3, $4, $5, $6)
      RETURNING id, driver_id, delivery_id, event_type, severity, message, metadata, recorded_at
    `,
    [driver.id, deliveryId, eventType, severity, message, metadata]
  );

  const event = result.rows[0];

  return res.status(201).json({
    message: "Tracking event saved.",
    event: {
      id: event.id,
      driverId: event.driver_id,
      deliveryId: event.delivery_id,
      eventType: event.event_type,
      severity: event.severity,
      message: event.message,
      metadata: event.metadata,
      recordedAt: event.recorded_at,
    },
  });
}

module.exports = {
  getAssignedDeliveries,
  saveLocation,
  saveTrackingEvent,
  updateDeliveryStatus,
};
