// Admin rider management: review self-registered riders, verify their
// document checklist, and approve/reject the account.

const pool = require("../config/db");

const DOCUMENT_TYPES = [
  "license",
  "insurance",
  "plates",
  "good_conduct",
  "national_id",
  "ntsa",
  "psv",
  "inspection",
];

function formatDocument(row) {
  return {
    docType: row.doc_type,
    docNumber: row.doc_number,
    status: row.status,
    expiryDate: row.expiry_date,
    updatedAt: row.updated_at,
  };
}

async function listRiders(req, res) {
  const result = await pool.query(`
    SELECT
      dp.id AS driver_id,
      dp.approval_status,
      dp.approval_note,
      dp.status AS availability,
      u.full_name,
      u.phone,
      u.email,
      u.place_of_birth,
      u.place_of_residence,
      u.created_at,
      v.plate_number,
      v.vehicle_type,
      COALESCE(docs.verified, 0) AS docs_verified,
      COALESCE(docs.pending, 0) AS docs_pending,
      COALESCE(docs.total, 0) AS docs_total
    FROM driver_profiles dp
    JOIN users u ON u.id = dp.user_id
    LEFT JOIN vehicles v ON v.id = dp.vehicle_id
    LEFT JOIN LATERAL (
      SELECT
        COUNT(*) FILTER (WHERE status = 'verified') AS verified,
        COUNT(*) FILTER (WHERE status = 'pending') AS pending,
        COUNT(*) AS total
      FROM driver_documents
      WHERE driver_id = dp.id
    ) docs ON TRUE
    ORDER BY
      CASE dp.approval_status WHEN 'pending' THEN 0 WHEN 'rejected' THEN 2 ELSE 1 END,
      u.created_at DESC
  `);

  return res.json({
    riders: result.rows.map((row) => ({
      driverId: row.driver_id,
      fullName: row.full_name,
      phone: row.phone,
      email: row.email,
      placeOfBirth: row.place_of_birth,
      placeOfResidence: row.place_of_residence,
      plateNumber: row.plate_number,
      vehicleType: row.vehicle_type,
      approvalStatus: row.approval_status,
      approvalNote: row.approval_note,
      availability: row.availability,
      documents: {
        verified: Number(row.docs_verified),
        pending: Number(row.docs_pending),
        total: Number(row.docs_total),
      },
      joinedAt: row.created_at,
    })),
  });
}

async function getRider(req, res) {
  const driverId = Number(req.params.driverId);

  if (!Number.isInteger(driverId) || driverId <= 0) {
    return res.status(400).json({ message: "A valid rider is required." });
  }

  const riderResult = await pool.query(
    `
      SELECT dp.id AS driver_id, dp.approval_status, dp.approval_note,
             u.full_name, u.phone, u.email, u.place_of_birth, u.place_of_residence,
             v.plate_number, v.vehicle_type
      FROM driver_profiles dp
      JOIN users u ON u.id = dp.user_id
      LEFT JOIN vehicles v ON v.id = dp.vehicle_id
      WHERE dp.id = $1
      LIMIT 1
    `,
    [driverId]
  );

  if (!riderResult.rows[0]) {
    return res.status(404).json({ message: "Rider not found." });
  }

  const documentsResult = await pool.query(
    `SELECT doc_type, doc_number, status, expiry_date, updated_at
       FROM driver_documents WHERE driver_id = $1`,
    [driverId]
  );

  const byType = new Map(documentsResult.rows.map((row) => [row.doc_type, row]));
  const documents = DOCUMENT_TYPES.map((type) => {
    const row = byType.get(type);
    return row
      ? formatDocument(row)
      : { docType: type, docNumber: null, status: "missing", expiryDate: null, updatedAt: null };
  });

  const rider = riderResult.rows[0];

  return res.json({
    rider: {
      driverId: rider.driver_id,
      fullName: rider.full_name,
      phone: rider.phone,
      email: rider.email,
      placeOfBirth: rider.place_of_birth,
      placeOfResidence: rider.place_of_residence,
      plateNumber: rider.plate_number,
      vehicleType: rider.vehicle_type,
      approvalStatus: rider.approval_status,
      approvalNote: rider.approval_note,
    },
    documents,
  });
}

async function setRiderApproval(req, res) {
  const driverId = Number(req.params.driverId);
  const status = String(req.body.status || "").trim();
  const note = String(req.body.note || "").trim() || null;

  if (!Number.isInteger(driverId) || driverId <= 0) {
    return res.status(400).json({ message: "A valid rider is required." });
  }

  if (!["approved", "rejected", "pending"].includes(status)) {
    return res.status(400).json({ message: "Status must be approved, rejected, or pending." });
  }

  const result = await pool.query(
    `
      UPDATE driver_profiles
         SET approval_status = $1, approval_note = $2
       WHERE id = $3
       RETURNING id, approval_status
    `,
    [status, note, driverId]
  );

  if (!result.rows[0]) {
    return res.status(404).json({ message: "Rider not found." });
  }

  return res.json({
    message:
      status === "approved"
        ? "Rider approved — they can now take deliveries."
        : status === "rejected"
          ? "Rider application rejected."
          : "Rider set back to pending review.",
    approvalStatus: result.rows[0].approval_status,
  });
}

async function setDocumentStatus(req, res) {
  const driverId = Number(req.params.driverId);
  const docType = String(req.params.docType || "").trim();
  const status = String(req.body.status || "").trim();

  if (!Number.isInteger(driverId) || driverId <= 0) {
    return res.status(400).json({ message: "A valid rider is required." });
  }

  if (!DOCUMENT_TYPES.includes(docType)) {
    return res.status(400).json({ message: "Unknown document type." });
  }

  if (!["verified", "pending", "expired", "rejected"].includes(status)) {
    return res.status(400).json({
      message: "Status must be verified, pending, expired, or rejected.",
    });
  }

  const result = await pool.query(
    `
      UPDATE driver_documents
         SET status = $1, updated_at = NOW()
       WHERE driver_id = $2 AND doc_type = $3
       RETURNING doc_type, doc_number, status, expiry_date, updated_at
    `,
    [status, driverId, docType]
  );

  if (!result.rows[0]) {
    return res.status(404).json({ message: "That document has not been submitted." });
  }

  return res.json({
    message: "Document updated.",
    document: formatDocument(result.rows[0]),
  });
}

module.exports = {
  listRiders,
  getRider,
  setRiderApproval,
  setDocumentStatus,
};
