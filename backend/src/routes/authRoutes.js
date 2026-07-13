const express = require("express");

const authController = require("../controllers/authController");

const router = express.Router();

router.post("/login", authController.login);
router.post("/register", authController.registerCustomer);
router.post("/register-rider", authController.registerRider);

module.exports = router;
