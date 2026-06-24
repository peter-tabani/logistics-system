# Needs From Owner

Things I could **not** do safely on my own (they need a password, a real device,
a live account, or a decision only you can make). Everything else in the
demo-prep build is done and validated.

---

## 0a. Real payments (M-Pesa / Daraja)  ·  BLOCKER before charging real money

All payments in Stan are currently **DEMO / MOCK** — the wallet, driver
cash-out, and customer payment collection (Cash + M-Pesa) simulate the flows but
move **no real money**. The M-Pesa STK push is faked in the app. To make
payments real you must provide / set up:

- **Safaricom Daraja account** (https://developer.safaricom.co.ke) with:
  - Consumer **Key** and **Secret** (sandbox first, then production)
  - **Business Short Code** (Paybill/Till) + **Passkey** for Lipa na M-Pesa Online (STK push)
  - A registered, HTTPS **callback URL** Safaricom can reach (the backend must be
    publicly hosted with TLS — localhost won't work)
- **Go-Live approval** from Safaricom (production access requires their review).
- A **settlement/float** arrangement and KYC for the paybill.
- Decisions only you can make: the **Stan service-fee %** (demo uses 15%), who
  bears transaction costs, refund/dispute handling, and payout schedule.

What I'd build once the above exists: replace the simulated
`collect-payment` / `mpesa-result` / `wallet/cashout` with real Daraja STK-push
+ B2C calls, store credentials in `.env` (never committed), and verify
Safaricom callbacks. I will **not** add real payment credentials or move real
money without an explicit task + your live Daraja details.

---

## 0b. Google Maps API key  ·  optional (app works on free OpenStreetMap without it)

You asked for Google Maps. It's now wired into both the dashboard and the driver
app — but Google requires **your own API key + a billing account** (card on file,
even within the free tier). Until you provide a key, both surfaces automatically
fall back to the free OpenStreetMap map, so the demo still works today.

**What I need from you:**
- A Google Cloud project with **billing enabled** and these APIs on: Maps
  JavaScript API, Maps SDK for Android, Directions API.
- An API key (or two — one referrer-restricted for the dashboard, one
  Android-restricted for the app).

**Where it goes** (full steps in `docs/GOOGLE_MAPS_SETUP.md`):
- Dashboard: `dashboard/.env` → `VITE_GOOGLE_MAPS_API_KEY=...`
- Driver app: `driver_app/android/local.properties` → `MAPS_API_KEY=...`, and
  rebuild with `--dart-define=GOOGLE_MAPS_API_KEY=...`

I will not create a Google billing account, add a card, or generate keys on your
behalf — and keys are gitignored, never committed.

---

## 0c. Always-on backend so the app works from any network  ·  recommended

The backend currently runs on the PC, so the phone only connects on the **same
Wi-Fi as the PC**. To use the app from work / school / home (or with the PC
off), the backend must be reachable over the internet. Full steps in
`docs/CONNECT_FROM_ANYWHERE.md`. The code is ready (`db.js` supports a cloud
`DATABASE_URL`; a `render.yaml` blueprint is included; the app's URL is editable
in **Server settings**, so no rebuild is needed once it's hosted).

**What I need from you (pick one):**
- *Today, temporary:* run the Cloudflare tunnel command (no signup) — Option A.
- *Permanent:* a free **GitHub** repo + free **Render** account, then deploy the
  blueprint — Option B. I won't create accounts or commit credentials for you.

---

## 1. Real-phone API URL for the distributable APK  ·  BLOCKER for real-phone demo

The driver app's backend URL is fixed **when the APK is built**. The APK I built
and put on the download page targets the **Android emulator** (`http://10.0.2.2:5000`),
which will **not** work on a physical phone.

**What I need:** confirm how the phone will reach the backend during the demo:
- Same Wi-Fi as the PC → give me the PC's Wi-Fi IPv4 (e.g. `192.168.0.104`), **or**
- A public/hosted backend URL if the backend will be deployed.

I'll then rebuild with:
```powershell
flutter build apk --release --dart-define=API_BASE_URL=http://<THAT_URL>:5000
```
(Command and copy step are in `docs/INSTALL_DRIVER_APP.md`.)

---

## 2. Release signing keystore  ·  needed only for Google Play, not for the demo

The release APK is currently signed with the **debug key**. That's fine for
sideloading and the pilot demo, but **Google Play** requires a real upload
keystore.

**What I need (only if/when you want to publish to Play):**
- A keystore file + its passwords, **or** permission for you to generate one
  yourself (it must never be committed to git or shared in chat).

I will not create, store, or commit any keystore or password.

---

## 3. Public website hosting  ·  needed only to share the download page online

The download page is built and works locally at `website/index.html` with the
APK at `website/downloads/stan-driver.apk`. To make it a real public link
(e.g. `download.stan.co.ke`), it needs to be hosted.

**What I need (if you want it public):**
- The hosting account / domain (Netlify, Vercel, cPanel, etc.) and your go-ahead.
  I won't log into hosting or buy a domain on your behalf.
- For local demos no action is needed — just open `website/index.html` in a browser.

---

## 4. Real-device screenshots for the runbook  ·  optional polish

The runbook suggests keeping backup screenshots. I can't capture screenshots
from a physical phone.

**What I need (optional):**
- A few screenshots from a real device (login, home, live map, completed delivery)
  if you want them in the docs. The emulator screenshots already in
  `driver_app/` cover the basics.

---

_Nothing above blocks the local emulator demo. Items 1–4 are only required for a
real-phone demo, a Play Store release, or a public website._
