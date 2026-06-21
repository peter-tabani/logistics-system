const express = require("express");

const adminController = require("../controllers/adminController");
const { authenticate, requireRole } = require("../middleware/authMiddleware");

const router = express.Router();

router.get(
  "/driver-locations",
  authenticate,
  requireRole("admin"),
  adminController.getLatestDriverLocations
);
router.get("/tracking-alerts", authenticate, requireRole("admin"), adminController.getTrackingAlerts);
router.get("/tracking-events", authenticate, requireRole("admin"), adminController.getTrackingEvents);
router.get("/deliveries", authenticate, requireRole("admin"), adminController.getDeliveries);
router.post("/deliveries", authenticate, requireRole("admin"), adminController.createDelivery);

module.exports = router;
