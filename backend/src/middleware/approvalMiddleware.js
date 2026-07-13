const pool = require("../config/db");

// Blocks delivery work for riders who have not been approved yet. Pending
// riders can still sign in, view their profile, and manage documents.
async function requireApprovedDriver(req, res, next) {
  const result = await pool.query(
    `SELECT approval_status FROM driver_profiles WHERE user_id = $1 LIMIT 1`,
    [req.user.userId]
  );
  const profile = result.rows[0];

  if (!profile) {
    return res.status(404).json({ message: "Driver profile was not found." });
  }

  if (profile.approval_status !== "approved") {
    return res.status(403).json({
      message:
        profile.approval_status === "rejected"
          ? "Your rider application was rejected. Contact Stan support."
          : "Your rider account is awaiting admin approval.",
      approvalStatus: profile.approval_status,
    });
  }

  return next();
}

module.exports = { requireApprovedDriver };
