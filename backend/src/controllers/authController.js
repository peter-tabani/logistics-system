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

module.exports = {
  login,
};
