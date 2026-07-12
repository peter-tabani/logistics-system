// Collection points: real locations a parcel routes through between the
// sender leg and the receiver leg. Managed by admin; riders and customers
// read them through their own endpoints.

const pool = require("../config/db");

function formatCollectionPoint(row) {
  return {
    id: row.id,
    name: row.name,
    address: row.address,
    latitude: Number(row.latitude),
    longitude: Number(row.longitude),
    isActive: row.is_active,
    createdAt: row.created_at,
  };
}

function isValidLatitude(value) {
  return Number.isFinite(value) && value >= -90 && value <= 90;
}

function isValidLongitude(value) {
  return Number.isFinite(value) && value >= -180 && value <= 180;
}

async function listCollectionPoints(req, res) {
  const activeOnly = req.query.active === "true";
  const result = await pool.query(
    `
      SELECT id, name, address, latitude, longitude, is_active, created_at
      FROM collection_points
      ${activeOnly ? "WHERE is_active = TRUE" : ""}
      ORDER BY name
    `
  );

  return res.json({ collectionPoints: result.rows.map(formatCollectionPoint) });
}

async function createCollectionPoint(req, res) {
  const name = String(req.body.name || "").trim();
  const address = String(req.body.address || "").trim();
  const latitude = Number(req.body.latitude);
  const longitude = Number(req.body.longitude);

  if (!name || !address) {
    return res.status(400).json({ message: "Name and address are required." });
  }

  if (!isValidLatitude(latitude) || !isValidLongitude(longitude)) {
    return res.status(400).json({ message: "Valid coordinates are required." });
  }

  const result = await pool.query(
    `
      INSERT INTO collection_points (name, address, latitude, longitude)
      VALUES ($1, $2, $3, $4)
      RETURNING id, name, address, latitude, longitude, is_active, created_at
    `,
    [name, address, latitude, longitude]
  );

  return res.status(201).json({
    message: "Collection point created.",
    collectionPoint: formatCollectionPoint(result.rows[0]),
  });
}

async function updateCollectionPoint(req, res) {
  const id = Number(req.params.id);
  if (!Number.isInteger(id) || id <= 0) {
    return res.status(400).json({ message: "A valid collection point is required." });
  }

  const name = req.body.name !== undefined ? String(req.body.name).trim() : null;
  const address = req.body.address !== undefined ? String(req.body.address).trim() : null;
  const latitude = req.body.latitude !== undefined ? Number(req.body.latitude) : null;
  const longitude = req.body.longitude !== undefined ? Number(req.body.longitude) : null;
  const isActive = typeof req.body.isActive === "boolean" ? req.body.isActive : null;

  if (latitude !== null && !isValidLatitude(latitude)) {
    return res.status(400).json({ message: "Latitude is invalid." });
  }

  if (longitude !== null && !isValidLongitude(longitude)) {
    return res.status(400).json({ message: "Longitude is invalid." });
  }

  const result = await pool.query(
    `
      UPDATE collection_points
         SET name = COALESCE($1, name),
             address = COALESCE($2, address),
             latitude = COALESCE($3, latitude),
             longitude = COALESCE($4, longitude),
             is_active = COALESCE($5, is_active)
       WHERE id = $6
       RETURNING id, name, address, latitude, longitude, is_active, created_at
    `,
    [name || null, address || null, latitude, longitude, isActive, id]
  );

  if (!result.rows[0]) {
    return res.status(404).json({ message: "Collection point not found." });
  }

  return res.json({
    message: "Collection point updated.",
    collectionPoint: formatCollectionPoint(result.rows[0]),
  });
}

module.exports = {
  listCollectionPoints,
  createCollectionPoint,
  updateCollectionPoint,
  formatCollectionPoint,
};
