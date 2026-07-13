const express = require("express");

const adminController = require("../controllers/adminController");
const collectionPoints = require("../controllers/collectionPointsController");
const ridersAdmin = require("../controllers/ridersAdminController");
const reports = require("../controllers/reportsController");
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

// Rider onboarding review (self-registered riders + document checklist)
router.get("/riders", authenticate, requireRole("admin"), ridersAdmin.listRiders);
router.get("/riders/:driverId", authenticate, requireRole("admin"), ridersAdmin.getRider);
router.patch("/riders/:driverId/approval", authenticate, requireRole("admin"), ridersAdmin.setRiderApproval);
router.patch(
  "/riders/:driverId/documents/:docType",
  authenticate,
  requireRole("admin"),
  ridersAdmin.setDocumentStatus
);

// Reports
router.get("/reports/trips-per-rider", authenticate, requireRole("admin"), reports.tripsPerRider);
router.get("/reports/collections", authenticate, requireRole("admin"), reports.collections);
router.get("/reports/rider-locations", authenticate, requireRole("admin"), reports.riderLocations);
router.get("/reports/customers", authenticate, requireRole("admin"), reports.customers);

module.exports = router;
