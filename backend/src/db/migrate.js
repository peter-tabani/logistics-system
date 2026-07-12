// Additive, migration-safe schema management for Stan.
//
// How it works:
// - schema.sql is the frozen baseline (fully idempotent); it is applied first
//   so a fresh database gets the complete base schema. On an existing database
//   it is a no-op.
// - Numbered .sql files in ./migrations run once each, in filename order,
//   inside a transaction, and are recorded in schema_migrations.
// - Migrations must be ADDITIVE only: no DROP TABLE, TRUNCATE, or destructive
//   changes against existing data (see CLAUDE.md working agreement).

const fs = require("fs");
const path = require("path");

const MIGRATIONS_DIR = path.join(__dirname, "migrations");

async function runMigrations(pool) {
  const baseline = fs.readFileSync(path.join(__dirname, "schema.sql"), "utf8");
  await pool.query(baseline);

  await pool.query(`
    CREATE TABLE IF NOT EXISTS schema_migrations (
      name VARCHAR(200) PRIMARY KEY,
      applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
    )
  `);

  const files = fs.existsSync(MIGRATIONS_DIR)
    ? fs
        .readdirSync(MIGRATIONS_DIR)
        .filter((file) => file.endsWith(".sql"))
        .sort()
    : [];

  const appliedResult = await pool.query(`SELECT name FROM schema_migrations`);
  const applied = new Set(appliedResult.rows.map((row) => row.name));
  const pending = files.filter((file) => !applied.has(file));

  for (const file of pending) {
    const sql = fs.readFileSync(path.join(MIGRATIONS_DIR, file), "utf8");
    const client = await pool.connect();

    try {
      await client.query("BEGIN");
      await client.query(sql);
      await client.query(`INSERT INTO schema_migrations (name) VALUES ($1)`, [file]);
      await client.query("COMMIT");
      console.log(`Migration applied: ${file}`);
    } catch (error) {
      await client.query("ROLLBACK");
      throw new Error(`Migration ${file} failed: ${error.message}`);
    } finally {
      client.release();
    }
  }

  return { appliedNow: pending.length, total: files.length };
}

module.exports = { runMigrations };

if (require.main === module) {
  require("dotenv").config();
  const pool = require("../config/db");

  runMigrations(pool)
    .then(async (result) => {
      console.log(
        `Migrations up to date (${result.appliedNow} applied this run, ${result.total} known).`
      );
      await pool.end();
    })
    .catch(async (error) => {
      console.error(error.message);
      await pool.end();
      process.exit(1);
    });
}
