# Stan — Project Guide for Claude Code

## What this is
Stan is a logistics / fleet-tracking system with three parts:
- `backend/`    — Node.js + Express API, runs on port 5000, PostgreSQL database
- `dashboard/`  — React + Vite admin/owner dashboard, runs on port 5173
- `driver_app/` — Flutter Android driver app

## Brand (keep consistent everywhere)
- Product name: **Stan**
- Primary dark (navy): `#0E2140`
- Panel / secondary:    `#17304F`
- App background:       `#EEF2F8`
- Logo: original white stylized "S" mark (vector only — no online or copyrighted images)
- Style: premium logistics app, deep navy blue (not black)

## Test accounts (demo)
- Driver: `0711111111` / `driver123`
- Admin:  system admin account

## API base URL
- Android emulator: `http://10.0.2.2:5000`
- Real phone:       `http://<PC_LAN_IP>:5000` (passed via `--dart-define=API_BASE_URL=...`)

## Payments — REAL-READY, SANDBOX, NO LIVE CREDENTIALS (hard rule)
Payments are built against Safaricom **Daraja** (M-Pesa STK Push + Paybill
C2B) via `backend/src/services/daraja.js`, but the system is **not live**:
- With no credentials configured, everything runs in **simulate mode**: no
  network calls to Safaricom, no real money, flows labelled "DEMO" in the app.
- The owner supplies (never committed, `.env` only): `MPESA_ENV`
  (sandbox|production), `MPESA_CONSUMER_KEY`, `MPESA_CONSUMER_SECRET`,
  `MPESA_SHORTCODE`, `MPESA_PASSKEY`, and a public HTTPS
  `MPESA_CALLBACK_BASE_URL`. See `docs/NEEDS_FROM_OWNER.md`.
- **Never commit real credentials, never enable production mode, and never
  move real money without an explicit task from the owner.**
- Who pays is per-delivery (`payer` = sender pays at booking OR receiver pays
  on delivery); channels are STK Push (primary), Paybill C2B with the
  tracking code as account number (fallback), and cash.

## Working agreement — follow this on EVERY task
1. Work in small, complete steps. After each finished step, commit to git with a clear message.
2. After any change, run the matching validation before moving on:
   - Flutter:   `flutter analyze`  then  `flutter build apk --debug --dart-define=API_BASE_URL=http://10.0.2.2:5000`
   - Dashboard: `npm run build`  (inside `dashboard/`)
   - Backend:   confirm `/health` and `/db-health` respond
   If validation fails, FIX it and re-run before continuing. Never move to the next step on a broken build.
3. Never modify, print, or commit secrets: `.env` files, database credentials, signing keystores.
4. Never run destructive database commands (drop, truncate, or migrations against real data)
   unless that is explicitly the assigned task.
5. Use original vector assets. Do not pull copyrighted images or logos from the internet.
6. Keep going without asking for approval on routine edits, installs, and commands. Only stop for
   something genuinely destructive or irreversible.
7. When all assigned work is done, STOP. Write a short summary of what changed, what you validated,
   and anything you could not do. Do not invent new scope.
