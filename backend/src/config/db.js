const { Pool } = require("pg");

// Cloud Postgres (Neon, Render, Supabase, etc.) hand out a single
// DATABASE_URL connection string and require SSL. If it's present we use it;
// otherwise we fall back to the local discrete settings (unchanged for dev).
const pool = process.env.DATABASE_URL
  ? new Pool({
      connectionString: process.env.DATABASE_URL,
      ssl: { rejectUnauthorized: false },
    })
  : new Pool({
      host: process.env.DB_HOST || "localhost",
      port: Number(process.env.DB_PORT || 5432),
      database: process.env.DB_NAME || "logistics_db",
      user: process.env.DB_USER || "postgres",
      password: process.env.DB_PASSWORD,
    });

module.exports = pool;
