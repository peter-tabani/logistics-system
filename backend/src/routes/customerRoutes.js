const express = require("express");

const customerController = require("../controllers/customerController");
const { authenticate, requireRole } = require("../middleware/authMiddleware");

const router = express.Router();

// Customer-only guard applied to every route below.
router.use(authenticate, requireRole("customer"));

router.get("/collection-points", customerController.listActiveCollectionPoints);
router.get("/fare-quote", customerController.quoteFare);
router.post("/deliveries", customerController.bookDelivery);
router.get("/deliveries", customerController.listMyDeliveries);
router.get("/deliveries/:deliveryId", customerController.getMyDelivery);

module.exports = router;
