const express = require("express");
const cors = require("cors");
require("dotenv").config();

const pool = require("./config/db");
const { runMigrations } = require("./db/migrate");
const adminRoutes = require("./routes/adminRoutes");
const authRoutes = require("./routes/authRoutes");
const driverRoutes = require("./routes/driverRoutes");

const app = express();

app.use(cors());
app.use(express.json());

app.use("/admin", adminRoutes);
app.use("/auth", authRoutes);
app.use("/driver", driverRoutes);

app.get("/", (req, res) => {
  res.send("Logistics API Running");
});

app.get("/health", (req, res) => {
  res.json({
    status: "ok",
    service: "logistics-api",
  });
});

app.get("/db-health", async (req, res) => {
  try {
    const result = await pool.query("SELECT NOW() AS current_time");

    res.json({
      status: "ok",
      database: "connected",
      currentTime: result.rows[0].current_time,
    });
  } catch (error) {
    res.status(500).json({
      status: "error",
      database: "not connected",
      message: error.message,
    });
  }
});

const PORT = process.env.PORT || 5000;

// Apply pending schema migrations at boot so deploys stay in sync. The server
// still starts if the database is unreachable — /db-health will report it.
runMigrations(pool)
  .then((result) => {
    if (result.appliedNow > 0) {
      console.log(`Applied ${result.appliedNow} schema migration(s) at boot.`);
    }
  })
  .catch((error) => {
    console.error(`Migrations failed at boot: ${error.message}`);
  });

app.listen(PORT, () => {
  console.log(`Server running on port ${PORT}`);
});
