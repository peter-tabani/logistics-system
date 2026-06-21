// Demo seed for owner walkthroughs.
//
// Creates a repeatable demo data set for the Stan dashboard + driver app:
//   - one ACTIVE delivery (in_transit) with a recent live driver location
//   - one COMPLETED delivery (delivered)
//   - one tracking event on the active delivery
//
// Safe + repeatable: it only removes rows it created itself (matched by the
// demo customer names and the demo tracking-event marker) before re-inserting.
// It never truncates tables or touches real deliveries.
//
// Run base accounts first if needed:  npm run db:seed
// Then:                               npm run db:seed:demo

require("dotenv").config();

const pool = require("../config/db");

const DEMO_DRIVER_PHONE = "0711111111";

// Active delivery: in transit from the Stan hub toward Westlands.
const ACTIVE_DELIVERY = {
  customerName: "Westgate Pharmacy",
  pickupAddress: "Stan Hub - Industrial Area, Nairobi",
  pickupLatitude: -1.308611,
  pickupLongitude: 36.851111,
  dropoffAddress: "Westgate Mall, Westlands",
  dropoffLatitude: -1.257500,
  dropoffLongitude: 36.803900,
  status: "in_transit",
};

// A point roughly mid-route, used as the driver's latest live location.
const ACTIVE_DRIVER_LOCATION = {
  latitude: -1.283000,
  longitude: 36.823000,
  accuracyMeters: 12.5,
};

// Completed delivery from earlier today.
const COMPLETED_DELIVERY = {
  customerName: "Sarit Centre Retail",
  pickupAddress: "Stan Hub - Industrial Area, Nairobi",
  pickupLatitude: -1.308611,
  pickupLongitude: 36.851111,
  dropoffAddress: "Sarit Centre, Westlands",
  dropoffLatitude: -1.262500,
  dropoffLongitude: 36.802200,
  status: "delivered",
};

const DEMO_EVENT_MARKER = "demo_seed";

async function getDemoDriverProfileId() {
  const result = await pool.query(
    `
      SELECT dp.id
      FROM driver_profiles dp
      JOIN users u ON u.id = dp.user_id
      WHERE u.phone = $1
      LIMIT 1
    `,
    [DEMO_DRIVER_PHONE]
  );

  return result.rows[0] ? result.rows[0].id : null;
}

async function insertDelivery(driverId, delivery) {
  const result = await pool.query(
    `
      INSERT INTO deliveries (
        driver_id, customer_name,
        pickup_address, pickup_latitude, pickup_longitude,
        dropoff_address, dropoff_latitude, dropoff_longitude,
        status
      )
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
      RETURNING id
    `,
    [
      driverId,
      delivery.customerName,
      delivery.pickupAddress,
      delivery.pickupLatitude,
      delivery.pickupLongitude,
      delivery.dropoffAddress,
      delivery.dropoffLatitude,
      delivery.dropoffLongitude,
      delivery.status,
    ]
  );

  return result.rows[0].id;
}

async function seedDemo() {
  const driverId = await getDemoDriverProfileId();

  if (!driverId) {
    throw new Error(
      `Demo driver (${DEMO_DRIVER_PHONE}) was not found. Run "npm run db:seed" first.`
    );
  }

  // Remove only the rows this script previously created, so it is repeatable.
  await pool.query(
    `
      DELETE FROM deliveries
      WHERE driver_id = $1 AND customer_name = ANY($2::text[])
    `,
    [driverId, [ACTIVE_DELIVERY.customerName, COMPLETED_DELIVERY.customerName]]
  );

  await pool.query(
    `
      DELETE FROM driver_tracking_events
      WHERE driver_id = $1 AND metadata ->> 'source' = $2
    `,
    [driverId, DEMO_EVENT_MARKER]
  );

  // 1. Active (in-transit) delivery.
  const activeDeliveryId = await insertDelivery(driverId, ACTIVE_DELIVERY);

  // 2. Completed delivery.
  await insertDelivery(driverId, COMPLETED_DELIVERY);

  // 3. A recent live location so the driver shows on the map as active.
  await pool.query(
    `
      INSERT INTO driver_locations (driver_id, latitude, longitude, accuracy_meters, recorded_at)
      VALUES ($1, $2, $3, $4, NOW())
    `,
    [
      driverId,
      ACTIVE_DRIVER_LOCATION.latitude,
      ACTIVE_DRIVER_LOCATION.longitude,
      ACTIVE_DRIVER_LOCATION.accuracyMeters,
    ]
  );

  await pool.query(
    `
      UPDATE driver_profiles
      SET status = 'online'
      WHERE id = $1
    `,
    [driverId]
  );

  // 4. A tracking event on the active delivery (shows in the timeline).
  await pool.query(
    `
      INSERT INTO driver_tracking_events
        (driver_id, delivery_id, event_type, severity, message, metadata, recorded_at)
      VALUES ($1, $2, $3, $4, $5, $6, NOW())
    `,
    [
      driverId,
      activeDeliveryId,
      "arrived_pickup",
      "info",
      "Driver collected the parcel and is en route to Westgate Mall.",
      JSON.stringify({ source: DEMO_EVENT_MARKER, distanceMeters: 35 }),
    ]
  );

  await pool.end();

  console.log("Demo data seeded successfully.");
  console.log(`Active delivery:    #${activeDeliveryId} - ${ACTIVE_DELIVERY.customerName} (in_transit)`);
  console.log(`Completed delivery: ${COMPLETED_DELIVERY.customerName} (delivered)`);
  console.log("Live driver location + 1 tracking event added for the demo driver.");
}

seedDemo().catch(async (error) => {
  console.error("Demo seed failed:", error.message);
  await pool.end();
  process.exit(1);
});
