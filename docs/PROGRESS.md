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

## Driver features (Uber-style) — Done

- Wallet & Earnings, payment collection (Cash + M-Pesa STK) and cash-out —
  all DEMO/MOCK (see CLAUDE.md), proof-of-delivery PIN, profile suite
  (rating/tier/bio, documents, vehicle, account), WhatsApp-style Messages inbox.
- "Stan" stripped from labels (tracking code is `TRK-`, tiers are `Pro`, etc.);
  kept only as the app name on splash/login.

## Liquid-glass visual pass — Done (performance-first)

A reusable glass design system (`GlassPanel`, `GlassSheen`, `glassEnabled()`):
- **Real frosted blur** (`BackdropFilter`) only where the background is static:
  the **login card** floats as frosted glass over the navy backdrop.
- **Floating nav island**: the bottom navigation is a rounded floating island
  (refracting edge + sheen + soft shadow). Built as a **solid premium surface,
  not live blur**, because it sits over scrolling lists on every tab — the exact
  place live blur risks jank/ANR. (Adapts the spec's "floating tab bar".)
- **Light-refracting edges + sheen** on the navy gradient cards (wallet balance,
  Pro card, promo) — the glass "light-catching" look without blur cost.
- **Performance-adaptive fallback**: `glassEnabled()` returns false under
  "remove animations" (reduce-motion), so panels render as solid premium
  surfaces; a `_forceSolidSurfaces` kill-switch is available.
- **iOS-only ideas adapted**: lock-screen/MagSafe/album-art etc. have no app
  equivalent and were not copied; the underlying "frosted, layered, light-
  catching" language was applied to our panels/nav/cards instead.

Deliberately conservative (solid, no live blur) for performance / stability:
- The **map workflow sheet and map chrome** — large/continuously-moving map
  underneath is the worst case for `BackdropFilter`; kept as premium solid
  surfaces.
- Light list screens (Shipments, Documents, Messages, Profile body) keep clean
  bordered cards (frosting over a light background adds little and costs frames).

Screen to watch on a real phone: the **map/tracking screen** (live map + Google
Maps SDK is the heaviest); glass there is intentionally solid to stay smooth.

## Next Recommended Step

- Get the real-phone API URL from the owner and rebuild the APK for the demo
  (see `docs/NEEDS_FROM_OWNER.md`).
- Optionally carry the navy + glass styling into the web dashboard for parity.

