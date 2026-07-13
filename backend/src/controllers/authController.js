const bcrypt = require("bcrypt");
const jwt = require("jsonwebtoken");

const pool = require("../config/db");

function buildToken(user) {
  return jwt.sign(
    {
      userId: user.id,
      role: user.role,
    },
    process.env.JWT_SECRET,
    { expiresIn: "7d" }
  );
}

async function login(req, res) {
  const { phone, password } = req.body;

  if (!phone || !password) {
    return res.status(400).json({
      message: "Phone and password are required.",
    });
  }

  const result = await pool.query(
    `
      SELECT id, full_name, phone, password_hash, role, is_active
      FROM users
      WHERE phone = $1
      LIMIT 1
    `,
    [phone]
  );

  const user = result.rows[0];

  if (!user || !user.is_active) {
    return res.status(401).json({
      message: "Invalid phone or password.",
    });
  }

  const passwordMatches = await bcrypt.compare(password, user.password_hash);

  if (!passwordMatches) {
    return res.status(401).json({
      message: "Invalid phone or password.",
    });
  }

  const token = buildToken(user);

  // Riders carry their approval state so the app can show the pending
  // screen without an extra round trip.
  let approvalStatus;
  if (user.role === "driver") {
    const profileResult = await pool.query(
      `SELECT approval_status FROM driver_profiles WHERE user_id = $1 LIMIT 1`,
      [user.id]
    );
    approvalStatus = profileResult.rows[0]?.approval_status || "approved";
  }

  return res.json({
    token,
    user: {
      id: user.id,
      fullName: user.full_name,
      phone: user.phone,
      role: user.role,
      ...(approvalStatus ? { approvalStatus } : {}),
    },
  });
}

function isValidPhone(phone) {
  return /^\+?\d{7,15}$/.test(phone);
}

// Customer self-registration. Riders register via /auth/register-rider (with
// the document checklist); admin accounts are seeded only.
async function registerCustomer(req, res) {
  const fullName = String(req.body.fullName || "").trim();
  const phone = String(req.body.phone || "").trim();
  const password = String(req.body.password || "");
  const email = req.body.email ? String(req.body.email).trim() : null;
  const placeOfBirth = req.body.placeOfBirth ? String(req.body.placeOfBirth).trim() : null;
  const placeOfResidence = req.body.placeOfResidence
    ? String(req.body.placeOfResidence).trim()
    : null;

  if (fullName.length < 2) {
    return res.status(400).json({ message: "Your full name is required." });
  }

  if (!isValidPhone(phone)) {
    return res.status(400).json({ message: "Enter a valid phone number." });
  }

  if (password.length < 6) {
    return res.status(400).json({ message: "Password must be at least 6 characters." });
  }

  const passwordHash = await bcrypt.hash(password, 10);

  try {
    const result = await pool.query(
      `
        INSERT INTO users (full_name, phone, email, password_hash, role, place_of_birth, place_of_residence)
        VALUES ($1, $2, $3, $4, 'customer', $5, $6)
        RETURNING id, full_name, phone, role
      `,
      [fullName, phone, email || null, passwordHash, placeOfBirth, placeOfResidence]
    );

    const user = result.rows[0];

    return res.status(201).json({
      token: buildToken(user),
      user: {
        id: user.id,
        fullName: user.full_name,
        phone: user.phone,
        role: user.role,
      },
    });
  } catch (error) {
    if (error.code === "23505") {
      return res.status(409).json({ message: "An account with that phone or email already exists." });
    }
    throw error;
  }
}

// Rider self-registration with the document checklist. The account is
// created PENDING — an admin must approve on the dashboard before the rider
// can take deliveries.
const SIGNUP_DOCUMENT_TYPES = ["license", "insurance", "good_conduct", "national_id"];

async function registerRider(req, res) {
  const fullName = String(req.body.fullName || "").trim();
  const phone = String(req.body.phone || "").trim();
  const password = String(req.body.password || "");
  const email = req.body.email ? String(req.body.email).trim() : null;
  const placeOfBirth = req.body.placeOfBirth ? String(req.body.placeOfBirth).trim() : null;
  const placeOfResidence = req.body.placeOfResidence
    ? String(req.body.placeOfResidence).trim()
    : null;
  const vehicleType = String(req.body.vehicleType || "").trim() || null;
  const plateNumber = String(req.body.plateNumber || "").trim().toUpperCase();
  const documents = req.body.documents && typeof req.body.documents === "object"
    ? req.body.documents
    : {};

  if (fullName.length < 2) {
    return res.status(400).json({ message: "Your full name is required." });
  }

  if (!isValidPhone(phone)) {
    return res.status(400).json({ message: "Enter a valid phone number." });
  }

  if (password.length < 6) {
    return res.status(400).json({ message: "Password must be at least 6 characters." });
  }

  if (!plateNumber) {
    return res.status(400).json({ message: "Your vehicle number plate is required." });
  }

  const missing = SIGNUP_DOCUMENT_TYPES.filter((type) => {
    const doc = documents[type];
    return !doc || !String(doc.docNumber || "").trim();
  });

  if (missing.length) {
    return res.status(400).json({
      message: `Document number required for: ${missing.join(", ").replaceAll("_", " ")}.`,
    });
  }

  const passwordHash = await bcrypt.hash(password, 10);
  const client = await pool.connect();

  try {
    await client.query("BEGIN");

    const userResult = await client.query(
      `
        INSERT INTO users (full_name, phone, email, password_hash, role, place_of_birth, place_of_residence)
        VALUES ($1, $2, $3, $4, 'driver', $5, $6)
        RETURNING id, full_name, phone, role
      `,
      [fullName, phone, email || null, passwordHash, placeOfBirth, placeOfResidence]
    );
    const user = userResult.rows[0];

    const vehicleResult = await client.query(
      `
        INSERT INTO vehicles (plate_number, vehicle_type)
        VALUES ($1, $2)
        ON CONFLICT (plate_number)
        DO UPDATE SET vehicle_type = COALESCE(EXCLUDED.vehicle_type, vehicles.vehicle_type)
        RETURNING id
      `,
      [plateNumber, vehicleType]
    );

    const licenseNumber = String(documents.license?.docNumber || "").trim() || null;

    const profileResult = await client.query(
      `
        INSERT INTO driver_profiles (user_id, vehicle_id, license_number, status, approval_status)
        VALUES ($1, $2, $3, 'offline', 'pending')
        RETURNING id
      `,
      [user.id, vehicleResult.rows[0].id, licenseNumber]
    );
    const driverId = profileResult.rows[0].id;

    // Checklist documents (all pending admin verification). The number plate
    // is linked into the checklist as its own entry.
    const docEntries = [
      ...SIGNUP_DOCUMENT_TYPES.map((type) => ({
        type,
        number: String(documents[type]?.docNumber || "").trim(),
        expiry: documents[type]?.expiryDate || null,
      })),
      { type: "plates", number: plateNumber, expiry: null },
    ];

    for (const entry of docEntries) {
      await client.query(
        `
          INSERT INTO driver_documents (driver_id, doc_type, doc_number, status, expiry_date, updated_at)
          VALUES ($1, $2, $3, 'pending', $4, NOW())
          ON CONFLICT (driver_id, doc_type)
          DO UPDATE SET doc_number = EXCLUDED.doc_number,
                        status = 'pending',
                        expiry_date = EXCLUDED.expiry_date,
                        updated_at = NOW()
        `,
        [driverId, entry.type, entry.number, entry.expiry]
      );
    }

    await client.query("COMMIT");

    return res.status(201).json({
      token: buildToken(user),
      user: {
        id: user.id,
        fullName: user.full_name,
        phone: user.phone,
        role: user.role,
        approvalStatus: "pending",
      },
      message:
        "Rider account created. An admin will review your documents and approve your account.",
    });
  } catch (error) {
    await client.query("ROLLBACK");
    if (error.code === "23505") {
      return res.status(409).json({ message: "An account with that phone or email already exists." });
    }
    throw error;
  } finally {
    client.release();
  }
}

module.exports = {
  login,
  registerCustomer,
  registerRider,
  isValidPhone,
  buildToken,
};
