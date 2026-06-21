const express = require("express");

const driverController = require("../controllers/driverController");
const { authenticate, requireRole } = require("../middleware/authMiddleware");

const router = express.Router();

router.get("/deliveries", authenticate, requireRole("driver"), driverController.getAssignedDeliveries);
router.post("/locations", authenticate, requireRole("driver"), driverController.saveLocation);
router.post("/tracking-events", authenticate, requireRole("driver"), driverController.saveTrackingEvent);
router.patch(
  "/deliveries/:deliveryId/status",
  authenticate,
  requireRole("driver"),
  driverController.updateDeliveryStatus
);

module.exports = router;
