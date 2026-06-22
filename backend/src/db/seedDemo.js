// Demo seed for owner walkthroughs.
//
// Creates a repeatable demo data set for the Stan dashboard + driver app:
//   - one ACTIVE delivery (in_transit) with a fare + handover PIN + live location
//   - several COMPLETED + PAID deliveries (this week) so earnings show real totals
//   - wallet transactions (earnings + an M-Pesa cash-out) — DEMO payments only
//   - driver documents (licence, NTSA, PSV, insurance, inspection)
//   - driver rating + bio + a tracking event
//
// Safe + repeatable: it only removes rows it created itself for the demo driver
// before re-inserting. It never truncates tables or touches real deliveries.
//
// PAYMENTS ARE DEMO/MOCK ONLY — see CLAUDE.md.
//
// Run base accounts first if needed:  npm run db:seed
// Then:                               npm run db:seed:demo

require("dotenv").config();

const pool = require("../config/db");

const DEMO_DRIVER_PHONE = "0711111111";
const DEMO_EVENT_MARKER = "demo_seed";
const SERVICE_FEE_RATE = 0.15;

// Active delivery: in transit, fare due, handover PIN 4827.
const ACTIVE_DELIVERY = {
  customerName: "Westgate Pharmacy",
  pickupAddress: "Kilimani, Nairobi",
  pickupLatitude: -1.308611,
  pickupLongitude: 36.851111,
  dropoffAddress: "Westgate Mall, Westlands",
  dropoffLatitude: -1.2575,
  dropoffLongitude: 36.8039,
  status: "in_transit",
  fare: 850,
  pin: "4827",
};

const ACTIVE_DRIVER_LOCATION = {
  latitude: -1.283,
  longitude: 36.823,
  accuracyMeters: 12.5,
};

// Completed + paid deliveries (this week) — power the earnings tracker.
const COMPLETED_DELIVERIES = [
  {
    customerName: "Sarit Centre Retail",
    pickupAddress: "Industrial Area, Nairobi",
    pickupLatitude: -1.308611,
    pickupLongitude: 36.851111,
    dropoffAddress: "Sarit Centre, Westlands",
    dropoffLatitude: -1.2625,
    dropoffLongitude: 36.8022,
    fare: 1200,
    tip: 100,
    method: "mpesa",
    daysAgo: 0,
  },
  {
    customerName: "Junction Mall Pharmacy",
    pickupAddress: "Lavington, Nairobi",
    pickupLatitude: -1.308611,
    pickupLongitude: 36.851111,
    dropoffAddress: "Junction Mall, Ngong Road",
    dropoffLatitude: -1.2989,
    dropoffLongitude: 36.7689,
    fare: 600,
    tip: 0,
    method: "cash",
    daysAgo: 1,
  },
  {
    customerName: "Garden City Electronics",
    pickupAddress: "Parklands, Nairobi",
    pickupLatitude: -1.308611,
    pickupLongitude: 36.851111,
    dropoffAddress: "Garden City Mall, Thika Road",
    dropoffLatitude: -1.2317,
    dropoffLongitude: 36.8783,
    fare: 1500,
    tip: 0,
    method: "mpesa",
    daysAgo: 2,
  },
];

const ALL_DEMO_CUSTOMERS = [
  ACTIVE_DELIVERY.customerName,
  ...COMPLETED_DELIVERIES.map((d) => d.customerName),
];

const DOCUMENTS = [
  { type: "license", number: "DL-2291045", status: "verified", expiry: "2027-04-30" },
  { type: "ntsa", number: "NTSA-CLR-88210", status: "verified", expiry: "2026-12-31" },
  { type: "psv", number: "PSV-553120", status: "verified", expiry: "2026-09-15" },
  { type: "insurance", number: "INS-AKI-770914", status: "verified", expiry: "2026-08-01" },
  { type: "inspection", number: null, status: "pending", expiry: null },
];

function demoRef() {
  const letters = "ABCDEFGHJKLMNPQRSTUVWXYZ";
  const digits = "0123456789";
  let code = "";
  for (let i = 0; i < 10; i += 1) {
    code += (i % 2 === 0 ? letters : digits)[
      Math.floor(Math.random() * (i % 2 === 0 ? letters.length : digits.length))
    ];
  }
  return code;
}

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

async function insertCompletedDelivery(driverId, delivery) {
  const result = await pool.query(
    `
      INSERT INTO deliveries (
        driver_id, customer_name,
        pickup_address, pickup_latitude, pickup_longitude,
        dropoff_address, dropoff_latitude, dropoff_longitude,
        status, fare_amount, tip_amount, payment_method, payment_status,
        created_at, updated_at
      )
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 'delivered', $9, $10, $11, 'paid',
              NOW() - ($12 * INTERVAL '1 day'), NOW() - ($12 * INTERVAL '1 day'))
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
      delivery.fare,
      delivery.tip,
      delivery.method,
      delivery.daysAgo,
    ]
  );
  return result.rows[0].id;
}

async function creditWallet(driverId, deliveryId, delivery) {
  const gross = delivery.fare;
  const fee = Math.round(gross * SERVICE_FEE_RATE * 100) / 100;
  const net = Math.round((gross - fee) * 100) / 100;
  const ref = delivery.method === "mpesa" ? demoRef() : null;

  await pool.query(
    `
      INSERT INTO wallet_transactions
        (driver_id, type, amount, delivery_id, method, status, reference, description, created_at)
      VALUES ($1, 'earning', $2, $3, $4, 'completed', $5, $6, NOW() - ($7 * INTERVAL '1 day'))
    `,
    [
      driverId,
      net,
      deliveryId,
      delivery.method,
      ref,
      `Delivery #${deliveryId} fare (gross ${gross}, fee ${fee})`,
      delivery.daysAgo,
    ]
  );

  if (delivery.tip > 0) {
    await pool.query(
      `
        INSERT INTO wallet_transactions
          (driver_id, type, amount, delivery_id, method, status, description, created_at)
        VALUES ($1, 'tip', $2, $3, $4, 'completed', $5, NOW() - ($6 * INTERVAL '1 day'))
      `,
      [driverId, delivery.tip, deliveryId, delivery.method, `Delivery #${deliveryId} tip`, delivery.daysAgo]
    );
  }
}

async function seedDemo() {
  const driverId = await getDemoDriverProfileId();

  if (!driverId) {
    throw new Error(
      `Demo driver (${DEMO_DRIVER_PHONE}) was not found. Run "npm run db:seed" first.`
    );
  }

  // Remove only this driver's demo rows so the seed is repeatable.
  await pool.query(
    `DELETE FROM deliveries WHERE driver_id = $1 AND customer_name = ANY($2::text[])`,
    [driverId, ALL_DEMO_CUSTOMERS]
  );
  await pool.query(`DELETE FROM wallet_transactions WHERE driver_id = $1`, [driverId]);
  await pool.query(`DELETE FROM driver_documents WHERE driver_id = $1`, [driverId]);
  await pool.query(
    `DELETE FROM driver_tracking_events WHERE driver_id = $1 AND metadata ->> 'source' = $2`,
    [driverId, DEMO_EVENT_MARKER]
  );

  // 1. Active (in-transit) delivery with fare + handover PIN.
  const activeResult = await pool.query(
    `
      INSERT INTO deliveries (
        driver_id, customer_name,
        pickup_address, pickup_latitude, pickup_longitude,
        dropoff_address, dropoff_latitude, dropoff_longitude,
        status, fare_amount, payment_method, payment_status, delivery_pin
      )
      VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, 'unpaid', 'pending', $11)
      RETURNING id
    `,
    [
      driverId,
      ACTIVE_DELIVERY.customerName,
      ACTIVE_DELIVERY.pickupAddress,
      ACTIVE_DELIVERY.pickupLatitude,
      ACTIVE_DELIVERY.pickupLongitude,
      ACTIVE_DELIVERY.dropoffAddress,
      ACTIVE_DELIVERY.dropoffLatitude,
      ACTIVE_DELIVERY.dropoffLongitude,
      ACTIVE_DELIVERY.status,
      ACTIVE_DELIVERY.fare,
      ACTIVE_DELIVERY.pin,
    ]
  );
  const activeDeliveryId = activeResult.rows[0].id;

  // 2. Completed + paid deliveries this week, each crediting the wallet.
  for (const delivery of COMPLETED_DELIVERIES) {
    const id = await insertCompletedDelivery(driverId, delivery);
    await creditWallet(driverId, id, delivery);
  }

  // 3. A previous M-Pesa cash-out so the wallet has a payout in its history.
  await pool.query(
    `
      INSERT INTO wallet_transactions
        (driver_id, type, amount, method, status, reference, description, created_at)
      VALUES ($1, 'payout', $2, 'mpesa', 'completed', $3, 'M-Pesa cash-out (DEMO)', NOW() - INTERVAL '1 day')
    `,
    [driverId, -1500, demoRef()]
  );

  // 4. Live location so the driver shows on the map as active.
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

  // 5. Driver rating, bio, online status.
  await pool.query(
    `
      UPDATE driver_profiles
         SET status = 'online',
             rating = 4.90,
             bio = 'Reliable Nairobi rider. 3 years moving parcels across the city with Stan.'
       WHERE id = $1
    `,
    [driverId]
  );

  // 6. Compliance documents.
  for (const doc of DOCUMENTS) {
    await pool.query(
      `
        INSERT INTO driver_documents (driver_id, doc_type, doc_number, status, expiry_date, updated_at)
        VALUES ($1, $2, $3, $4, $5, NOW())
        ON CONFLICT (driver_id, doc_type)
        DO UPDATE SET doc_number = EXCLUDED.doc_number,
                      status = EXCLUDED.status,
                      expiry_date = EXCLUDED.expiry_date,
                      updated_at = NOW()
      `,
      [driverId, doc.type, doc.number, doc.status, doc.expiry]
    );
  }

  // 7. A tracking event on the active delivery.
  await pool.query(
    `
      INSERT INTO driver_tracking_events
        (driver_id, delivery_id, event_type, severity, message, metadata, recorded_at)
      VALUES ($1, $2, 'arrived_pickup', 'info', $3, $4, NOW())
    `,
    [
      driverId,
      activeDeliveryId,
      "Driver collected the parcel and is en route to Westgate Mall.",
      JSON.stringify({ source: DEMO_EVENT_MARKER, distanceMeters: 35 }),
    ]
  );

  await pool.end();

  console.log("Demo data seeded successfully.");
  console.log(`Active delivery #${activeDeliveryId} (in_transit) - fare ${ACTIVE_DELIVERY.fare}, handover PIN ${ACTIVE_DELIVERY.pin}`);
  console.log(`${COMPLETED_DELIVERIES.length} completed + paid deliveries this week (earnings + wallet history).`);
  console.log("Documents, rating, bio, live location, and a tracking event added.");
}

seedDemo().catch(async (error) => {
  console.error("Demo seed failed:", error.message);
  await pool.end();
  process.exit(1);
});
