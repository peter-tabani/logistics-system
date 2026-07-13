// Safaricom Daraja (M-Pesa) client: OAuth token, Lipa na M-Pesa Online (STK
// push), and C2B (Paybill) URL registration.
//
// REAL-READY, NOT LIVE. When the owner supplies credentials via .env the
// client talks to the Daraja sandbox or production APIs. Until then it runs
// in SIMULATE mode: no network calls, deterministic fake identifiers, and the
// apps drive the simulated confirmation flows. No credentials are committed —
// see docs/NEEDS_FROM_OWNER.md for exactly what the owner must provide.
//
// Env:
//   MPESA_ENV                sandbox | production (anything else => simulate)
//   MPESA_CONSUMER_KEY       Daraja app consumer key
//   MPESA_CONSUMER_SECRET    Daraja app consumer secret
//   MPESA_SHORTCODE          Paybill/Till business short code
//   MPESA_PASSKEY            Lipa na M-Pesa Online passkey
//   MPESA_CALLBACK_BASE_URL  public HTTPS base URL Safaricom can reach

const BASE_URLS = {
  sandbox: "https://sandbox.safaricom.co.ke",
  production: "https://api.safaricom.co.ke",
};

let cachedToken = null;
let cachedTokenExpiresAt = 0;

function config() {
  return {
    env: (process.env.MPESA_ENV || "").trim().toLowerCase(),
    consumerKey: (process.env.MPESA_CONSUMER_KEY || "").trim(),
    consumerSecret: (process.env.MPESA_CONSUMER_SECRET || "").trim(),
    shortcode: (process.env.MPESA_SHORTCODE || "").trim(),
    passkey: (process.env.MPESA_PASSKEY || "").trim(),
    callbackBaseUrl: (process.env.MPESA_CALLBACK_BASE_URL || "").trim().replace(/\/$/, ""),
  };
}

// simulate unless a real environment is selected AND every credential exists.
function mode() {
  const c = config();
  const wantsReal = c.env === "sandbox" || c.env === "production";
  const hasCredentials =
    c.consumerKey && c.consumerSecret && c.shortcode && c.passkey && c.callbackBaseUrl;

  return wantsReal && hasCredentials ? c.env : "simulate";
}

function isSimulated() {
  return mode() === "simulate";
}

// The Paybill number shown to customers ("pay to Paybill X, account <code>").
function paybillShortcode() {
  const c = config();
  return c.shortcode || "000000";
}

// 07XXXXXXXX / +2547XXXXXXXX / 2547XXXXXXXX -> 2547XXXXXXXX
function normalizeMsisdn(phone) {
  const digits = String(phone || "").replace(/\D/g, "");
  if (digits.startsWith("254")) return digits;
  if (digits.startsWith("0")) return `254${digits.slice(1)}`;
  return digits;
}

function timestamp() {
  const now = new Date();
  const pad = (n) => String(n).padStart(2, "0");
  return (
    `${now.getFullYear()}${pad(now.getMonth() + 1)}${pad(now.getDate())}` +
    `${pad(now.getHours())}${pad(now.getMinutes())}${pad(now.getSeconds())}`
  );
}

async function getAccessToken() {
  const c = config();
  const now = Date.now();

  if (cachedToken && now < cachedTokenExpiresAt - 60000) {
    return cachedToken;
  }

  const credentials = Buffer.from(`${c.consumerKey}:${c.consumerSecret}`).toString("base64");
  const response = await fetch(
    `${BASE_URLS[mode()]}/oauth/v1/generate?grant_type=client_credentials`,
    { headers: { Authorization: `Basic ${credentials}` } }
  );

  if (!response.ok) {
    throw new Error(`Daraja OAuth failed (${response.status}).`);
  }

  const data = await response.json();
  cachedToken = data.access_token;
  cachedTokenExpiresAt = now + Number(data.expires_in || 3599) * 1000;

  return cachedToken;
}

// Initiate an STK push. In simulate mode this returns fake identifiers and
// the caller drives the simulated confirmation instead.
async function stkPush({ phone, amount, accountReference, description }) {
  const currentMode = mode();

  if (currentMode === "simulate") {
    return {
      mode: "simulate",
      checkoutRequestId: `ws_CO_DEMO_${Date.now()}`,
      merchantRequestId: null,
      responseDescription: "Simulated STK push (no Daraja credentials configured).",
    };
  }

  const c = config();
  const stamp = timestamp();
  const password = Buffer.from(`${c.shortcode}${c.passkey}${stamp}`).toString("base64");
  const token = await getAccessToken();

  const response = await fetch(`${BASE_URLS[currentMode]}/mpesa/stkpush/v1/processrequest`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
    },
    body: JSON.stringify({
      BusinessShortCode: c.shortcode,
      Password: password,
      Timestamp: stamp,
      TransactionType: "CustomerPayBillOnline",
      Amount: Math.max(1, Math.round(Number(amount))),
      PartyA: normalizeMsisdn(phone),
      PartyB: c.shortcode,
      PhoneNumber: normalizeMsisdn(phone),
      CallBackURL: `${c.callbackBaseUrl}/payments/mpesa/stk-callback`,
      AccountReference: String(accountReference || "STAN").slice(0, 12),
      TransactionDesc: String(description || "Stan delivery").slice(0, 13),
    }),
  });

  const data = await response.json();

  if (!response.ok || String(data.ResponseCode) !== "0") {
    throw new Error(data.errorMessage || data.ResponseDescription || "STK push failed.");
  }

  return {
    mode: currentMode,
    checkoutRequestId: data.CheckoutRequestID,
    merchantRequestId: data.MerchantRequestID,
    responseDescription: data.ResponseDescription,
  };
}

// One-time C2B URL registration so Paybill payments hit our callbacks. The
// owner runs this (via the admin endpoint) once credentials are configured.
async function registerC2bUrls() {
  const currentMode = mode();

  if (currentMode === "simulate") {
    return {
      mode: "simulate",
      message: "Simulate mode — nothing registered. Configure Daraja credentials first.",
    };
  }

  const c = config();
  const token = await getAccessToken();

  const response = await fetch(`${BASE_URLS[currentMode]}/mpesa/c2b/v1/registerurl`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${token}`,
    },
    body: JSON.stringify({
      ShortCode: c.shortcode,
      ResponseType: "Completed",
      ConfirmationURL: `${c.callbackBaseUrl}/payments/mpesa/c2b-confirmation`,
      ValidationURL: `${c.callbackBaseUrl}/payments/mpesa/c2b-validation`,
    }),
  });

  const data = await response.json();

  if (!response.ok) {
    throw new Error(data.errorMessage || "C2B URL registration failed.");
  }

  return { mode: currentMode, response: data };
}

// DEMO M-Pesa receipt code for simulate mode, e.g. "QGT4AB9KD1".
function simulatedReceipt() {
  const letters = "ABCDEFGHJKLMNPQRSTUVWXYZ";
  const digits = "0123456789";
  let code = "";
  for (let i = 0; i < 10; i += 1) {
    const source = i % 2 === 0 ? letters : digits;
    code += source[Math.floor(Math.random() * source.length)];
  }
  return code;
}

module.exports = {
  mode,
  isSimulated,
  paybillShortcode,
  normalizeMsisdn,
  stkPush,
  registerC2bUrls,
  simulatedReceipt,
};
