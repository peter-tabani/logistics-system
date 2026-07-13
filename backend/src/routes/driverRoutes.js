const express = require("express");

const driverController = require("../controllers/driverController");
const features = require("../controllers/driverFeaturesController");
const messages = require("../controllers/messagesController");
const payments = require("../controllers/paymentsController");
const { authenticate, requireRole } = require("../middleware/authMiddleware");

const router = express.Router();

// Driver-only guard applied to every route below.
router.use(authenticate, requireRole("driver"));

// Core delivery + tracking
router.get("/deliveries", driverController.getAssignedDeliveries);
router.post("/locations", driverController.saveLocation);
router.post("/tracking-events", driverController.saveTrackingEvent);
router.patch("/deliveries/:deliveryId/status", driverController.updateDeliveryStatus);

// Profile, account, availability
router.get("/profile", features.getProfile);
router.patch("/profile", features.updateProfile);
router.patch("/account", features.updateAccount);
router.patch("/availability", features.updateAvailability);

// Documents
router.get("/documents", features.getDocuments);
router.patch("/documents/:docType", features.updateDocument);

// Wallet & earnings (DEMO payments)
router.get("/earnings", features.getEarnings);
router.post("/wallet/cashout", features.cashOut);

// Payment collection at delivery (Daraja-backed; simulate mode without keys)
router.post("/deliveries/:deliveryId/collect-payment", features.collectPayment);
router.post("/deliveries/:deliveryId/mpesa-result", features.mpesaResult);
router.get("/deliveries/:deliveryId/payment-status", payments.driverPaymentStatus);

// Safety
router.post("/sos", features.triggerSos);

// Messaging (WhatsApp-style inbox)
router.get("/conversations", messages.getConversations);
router.get("/conversations/:conversationId/messages", messages.getMessages);
router.post("/conversations/:conversationId/messages", messages.sendMessage);

module.exports = router;
