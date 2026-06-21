# Logistics System Progress

## Current Status

The MVP skeleton is working locally.

Completed:

- Backend API with Express
- PostgreSQL connection to `logistics_db`
- Login with JWT tokens
- Driver Android app login
- Driver GPS send button
- Driver start/stop tracking toggle
- Admin dashboard login
- Admin map with latest driver location
- Admin delivery assignment
- Driver delivery list
- Driver delivery status updates
- Dashboard auto-refresh

## Test Accounts

Admin:

```text
0700000000 / admin123
```

Driver:

```text
0711111111 / driver123
```

## Restart Commands

Backend:

```powershell
cd backend
npm run dev
```

Dashboard:

```powershell
cd dashboard
npm run dev
```

Driver app:

```powershell
cd driver_app
flutter emulators --launch logistics_phone
flutter run -d emulator-5554
```

## Local URLs

Backend:

```text
http://localhost:5000
```

Dashboard:

```text
http://localhost:5173
```

## Demo Prep (Phases 4–6) — Done

Phase 4 — polish:

- Premium dark Stan dashboard (map-first, metrics, alerts, tracking timeline)
- Premium driver app (splash, login, map workflow, status updates)
- Removed copyrighted online avatar; uses original vector assets only

Phase 5 — release packaging:

- App name "Stan", original vector launcher icon, version 1.0.0+1
- Release APK built (debug-signed for sideload) — `npm`-free build command in
  `docs/INSTALL_DRIVER_APP.md`
- Download website at `website/index.html` (+ `website/downloads/stan-driver.apk`)
- Install instructions: `docs/INSTALL_DRIVER_APP.md`

Phase 6 — demo content:

- Demo seed script: `backend/src/db/seedDemo.js` (`npm run db:seed:demo`) —
  one active (in_transit) + one completed delivery, live driver location, and a
  tracking event. Repeatable and non-destructive.
- Presenter walkthrough: `docs/DEMO_SCRIPT.md`

Owner action items (real-phone URL, keystore, hosting, screenshots):
`docs/NEEDS_FROM_OWNER.md`

## Next Recommended Step

- Get the real-phone API URL from the owner and rebuild the APK for the demo
  (see `docs/NEEDS_FROM_OWNER.md`).
- Optionally host the download page publicly.

