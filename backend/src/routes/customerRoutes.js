const express = require("express");

const customerController = require("../controllers/customerController");
const payments = require("../controllers/paymentsController");
const { authenticate, requireRole } = require("../middleware/authMiddleware");

const router = express.Router();

// Customer-only guard applied to every route below.
router.use(authenticate, requireRole("customer"));

router.get("/collection-points", customerController.listActiveCollectionPoints);
router.get("/fare-quote", customerController.quoteFare);
router.post("/deliveries", customerController.bookDelivery);
router.get("/deliveries", customerController.listMyDeliveries);
router.get("/deliveries/:deliveryId", customerController.getMyDelivery);
router.post("/deliveries/:deliveryId/cancel", customerController.cancelDelivery);
router.patch("/account", customerController.updateAccount);

// Sender pay-now (M-Pesa STK; simulate mode without Daraja keys)
router.post("/deliveries/:deliveryId/pay", payments.customerPayNow);
router.post("/deliveries/:deliveryId/pay/simulate-result", payments.customerSimulateResult);
router.get("/deliveries/:deliveryId/payment-status", payments.customerPaymentStatus);

module.exports = router;
