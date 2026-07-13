const bcrypt = require("bcrypt");
require("dotenv").config();

const pool = require("../config/db");

async function upsertUser({ fullName, phone, email, password, role }) {
  const passwordHash = await bcrypt.hash(password, 10);

  const result = await pool.query(
    `
      INSERT INTO users (full_name, phone, email, password_hash, role)
      VALUES ($1, $2, $3, $4, $5)
      ON CONFLICT (phone)
      DO UPDATE SET
        full_name = EXCLUDED.full_name,
        email = EXCLUDED.email,
        password_hash = EXCLUDED.password_hash,
        role = EXCLUDED.role,
        is_active = TRUE,
        updated_at = NOW()
      RETURNING id
    `,
    [fullName, phone, email, passwordHash, role]
  );

  return result.rows[0].id;
}

async function seed() {
  await upsertUser({
    fullName: "System Admin",
    phone: "0700000000",
    email: "admin@example.com",
    password: "admin123",
    role: "admin",
  });

  const driverUserId = await upsertUser({
    fullName: "Demo Driver",
    phone: "0711111111",
    email: "driver@example.com",
    password: "driver123",
    role: "driver",
  });

  await upsertUser({
    fullName: "Demo Customer",
    phone: "0722222222",
    email: "customer@example.com",
    password: "customer123",
    role: "customer",
  });

  const vehicleResult = await pool.query(
    `
      INSERT INTO vehicles (plate_number, vehicle_type)
      VALUES ($1, $2)
      ON CONFLICT (plate_number)
      DO UPDATE SET vehicle_type = EXCLUDED.vehicle_type
      RETURNING id
    `,
    ["KDA 001A", "Van"]
  );

  await pool.query(
    `
      INSERT INTO driver_profiles (user_id, vehicle_id, license_number)
      VALUES ($1, $2, $3)
      ON CONFLICT (user_id)
      DO UPDATE SET
        vehicle_id = EXCLUDED.vehicle_id,
        license_number = EXCLUDED.license_number
    `,
    [driverUserId, vehicleResult.rows[0].id, "DEMO-LICENSE-001"]
  );

  await pool.end();

  console.log("Seed data created successfully.");
  console.log("Admin login: 0700000000 / admin123");
  console.log("Driver login: 0711111111 / driver123");
  console.log("Customer login: 0722222222 / customer123");
}

seed().catch(async (error) => {
  console.error("Database seed failed:", error.message);
  await pool.end();
  process.exit(1);
});
