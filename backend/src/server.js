const express = require("express");
const cors = require("cors");
require("dotenv").config();

const pool = require("./config/db");
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

app.listen(PORT, () => {
  console.log(`Server running on port ${PORT}`);
});
