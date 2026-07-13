const pool = require("../config/db");
const { creditEarningOnce } = require("../services/wallet");

const allowedDeliveryStatuses = new Set([
  "picked_up",
  "in_transit",
  "delivered",
  "at_collection_point",
]);
const allowedTrackingEventSeverities = new Set(["info", "warning", "critical"]);

function toCoord(value) {
  return value === null || value === undefined ? null : Number(value);
}

function formatDelivery(row) {
  const viaCollectionPoint = Boolean(row.collection_point_id);
  const currentLeg = viaCollectionPoint ? Number(row.current_leg || 1) : 1;
  const collectionPoint = viaCollectionPoint
    ? {
        id: row.collection_point_id,
        name: row.collection_point_name || null,
        address: row.collection_point_address || null,
        latitude: toCoord(row.collection_point_latitude),
        longitude: toCoord(row.collection_point_longitude),
      }
    : null;

  // The rider sees the route for their current leg: leg 1 ends at the
  // collection point, leg 2 starts from it. Direct deliveries are untouched.
  let pickup = {
    address: row.pickup_address,
    latitude: toCoord(row.pickup_latitude),
    longitude: toCoord(row.pickup_longitude),
  };
  let dropoff = {
    address: row.dropoff_address,
    latitude: toCoord(row.dropoff_latitude),
    longitude: toCoord(row.dropoff_longitude),
  };

  if (collectionPoint && collectionPoint.latitude !== null) {
    const cpStop = {
      address: collectionPoint.name
        ? `${collectionPoint.name} (collection point)`
        : "Collection point",
      latitude: collectionPoint.latitude,
      longitude: collectionPoint.longitude,
    };
    if (currentLeg === 1) {
      dropoff = cpStop;
    } else {
      pickup = cpStop;
    }
  }

  return {
    id: row.id,
    customerName: row.customer_name,
    pickupAddress: pickup.address,
    pickupLatitude: pickup.latitude,
    pickupLongitude: pickup.longitude,
    dropoffAddress: dropoff.address,
    dropoffLatitude: dropoff.latitude,
    dropoffLongitude: dropoff.longitude,
    status: row.status,
    viaCollectionPoint,
    currentLeg,
    collectionPoint,
    fareAmount: row.fare_amount === undefined ? 0 : Number(row.fare_amount),
    tipAmount: row.tip_amount === undefined ? 0 : Number(row.tip_amount),
    paymentMethod: row.payment_method || "unpaid",
    paymentStatus: row.payment_status || "pending",
    // DEMO: the handover PIN is surfaced to the app as a demo hint. In
    // production the customer alone would hold this code.
    deliveryPin: row.delivery_pin || null,
    trackingCode: row.tracking_code || null,
    payer: row.payer || "receiver",
    receiverName: row.receiver_name || null,
    receiverPhone: row.receiver_phone || null,
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
        d.id,
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
        d.payer,
        d.receiver_name,
        d.receiver_phone,
        d.collection_point_id,
        d.current_leg,
        cp.name AS collection_point_name,
        cp.address AS collection_point_address,
        cp.latitude AS collection_point_latitude,
        cp.longitude AS collection_point_longitude,
        d.created_at,
        d.updated_at
      FROM deliveries d
      LEFT JOIN collection_points cp ON cp.id = d.collection_point_id
      WHERE d.driver_id = $1
      ORDER BY
        CASE WHEN d.status = 'delivered' THEN 1 ELSE 0 END,
        d.created_at DESC
    `,
    [driver.id]
  );

  return res.json({
    deliveries: result.rows.map(formatDelivery),
  });
}

async function loadFormattedDelivery(deliveryId) {
  const result = await pool.query(
    `
      SELECT
        d.*,
        cp.name AS collection_point_name,
        cp.address AS collection_point_address,
        cp.latitude AS collection_point_latitude,
        cp.longitude AS collection_point_longitude
      FROM deliveries d
      LEFT JOIN collection_points cp ON cp.id = d.collection_point_id
      WHERE d.id = $1
      LIMIT 1
    `,
    [deliveryId]
  );

  return result.rows[0] ? formatDelivery(result.rows[0]) : null;
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
      message: "Status must be picked_up, in_transit, at_collection_point, or delivered.",
    });
  }

  const driver = await getDriverProfile(req.user.userId);

  if (!driver) {
    return res.status(404).json({
      message: "Driver profile was not found.",
    });
  }

  const currentResult = await pool.query(
    `
      SELECT id, status, delivery_pin, collection_point_id, current_leg
      FROM deliveries
      WHERE id = $1 AND driver_id = $2
      LIMIT 1
    `,
    [deliveryId, driver.id]
  );
  const current = currentResult.rows[0];

  if (!current) {
    return res.status(404).json({
      message: "Delivery was not found for this driver.",
    });
  }

  const viaCollectionPoint = Boolean(current.collection_point_id);
  const currentLeg = Number(current.current_leg || 1);

  if (status === "at_collection_point") {
    if (!viaCollectionPoint) {
      return res.status(400).json({
        message: "This delivery does not route through a collection point.",
      });
    }
    if (currentLeg !== 1) {
      return res.status(400).json({
        message: "This delivery has already left the collection point.",
      });
    }
  }

  if (status === "delivered") {
    if (viaCollectionPoint && currentLeg === 1) {
      return res.status(400).json({
        message: "Leg 1 ends at the collection point — drop the parcel there first.",
      });
    }

    // Proof-of-delivery PIN: completing a delivery requires the customer's
    // PIN when one is set on the delivery.
    if (current.delivery_pin) {
      const providedPin = String(req.body.pin || "").trim();
      if (providedPin !== current.delivery_pin) {
        return res.status(400).json({
          message: "Incorrect delivery PIN. Ask the customer for their handover code.",
        });
      }
    }
  }

  // Marking at_collection_point ends leg 1: release the rider so the parcel
  // waits at the point until dispatch assigns leg 2 (same or another rider).
  if (status === "at_collection_point") {
    await pool.query(
      `
        UPDATE deliveries
        SET status = 'at_collection_point', driver_id = NULL, updated_at = NOW()
        WHERE id = $1 AND driver_id = $2
      `,
      [deliveryId, driver.id]
    );
  } else {
    await pool.query(
      `
        UPDATE deliveries
        SET status = $1, updated_at = NOW()
        WHERE id = $2 AND driver_id = $3
      `,
      [status, deliveryId, driver.id]
    );
  }

  // Prepaid bookings (e.g. sender paid at booking, before a rider existed)
  // credit the delivering rider now. No-op when already credited.
  if (status === "delivered") {
    const paidResult = await pool.query(`SELECT * FROM deliveries WHERE id = $1 LIMIT 1`, [
      deliveryId,
    ]);
    const paidRow = paidResult.rows[0];
    if (paidRow && paidRow.payment_status === "paid") {
      await creditEarningOnce(
        driver.id,
        paidRow,
        paidRow.payment_method === "cash" ? "cash" : "mpesa",
        null
      );
    }
  }

  const delivery = await loadFormattedDelivery(deliveryId);

  return res.json({
    message:
      status === "at_collection_point"
        ? "Parcel logged at the collection point. Dispatch will send it out for delivery."
        : "Delivery status updated.",
    delivery,
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
