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

  return res.json({
    token,
    user: {
      id: user.id,
      fullName: user.full_name,
      phone: user.phone,
      role: user.role,
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

module.exports = {
  login,
  registerCustomer,
  isValidPhone,
  buildToken,
};
