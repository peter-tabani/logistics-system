const express = require("express");

const adminController = require("../controllers/adminController");
const collectionPoints = require("../controllers/collectionPointsController");
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
router.post(
  "/deliveries/:deliveryId/dispatch-leg2",
  authenticate,
  requireRole("admin"),
  adminController.dispatchLeg2
);
router.post(
  "/deliveries/:deliveryId/assign",
  authenticate,
  requireRole("admin"),
  adminController.assignRider
);

// Collection points (two-leg routing)
router.get("/collection-points", authenticate, requireRole("admin"), collectionPoints.listCollectionPoints);
router.post("/collection-points", authenticate, requireRole("admin"), collectionPoints.createCollectionPoint);
router.patch("/collection-points/:id", authenticate, requireRole("admin"), collectionPoints.updateCollectionPoint);

module.exports = router;
