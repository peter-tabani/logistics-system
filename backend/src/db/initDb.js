const fs = require("fs");
const path = require("path");
require("dotenv").config();

const pool = require("../config/db");

async function initDb() {
  const schemaPath = path.join(__dirname, "schema.sql");
  const schema = fs.readFileSync(schemaPath, "utf8");

  await pool.query(schema);
  await pool.end();

  console.log("Database tables created successfully.");
}

initDb().catch(async (error) => {
  console.error("Database setup failed:", error.message);
  await pool.end();
  process.exit(1);
});
