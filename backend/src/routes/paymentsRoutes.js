const express = require("express");

const payments = require("../controllers/paymentsController");
const { authenticate, requireRole } = require("../middleware/authMiddleware");

const router = express.Router();

// Public: Safaricom calls these (they must be reachable without our auth).
router.post("/mpesa/stk-callback", payments.stkCallback);
router.post("/mpesa/c2b-validation", payments.c2bValidation);
router.post("/mpesa/c2b-confirmation", payments.c2bConfirmation);

// App-facing config (any signed-in user).
router.get("/config", authenticate, payments.getConfig);

// Owner action: register the C2B callback URLs with Safaricom (once, after
// credentials are configured).
router.post("/mpesa/register-c2b", authenticate, requireRole("admin"), payments.registerC2b);

module.exports = router;
