# Stan — Owner Demo Script

A tight, repeatable walkthrough to show the owner the full Stan flow:
dashboard monitoring + driver app + live tracking. Plan for **~8 minutes**.

> Full start/stop commands and troubleshooting live in `docs/DEMO_RUNBOOK.md`.
> This file is the **talk track** — what to click and what to say.

---

## 0. Before they arrive (5 min setup)

1. Start PostgreSQL.
2. Start the backend (`cd backend; npm run dev`) and confirm:
   - `http://localhost:5000/health` → `{"status":"ok"}`
   - `http://localhost:5000/db-health` → `{"database":"connected"}`
3. Load fresh demo data (active + completed delivery, live location, event):
   ```powershell
   cd backend
   npm run db:seed:demo
   ```
   Re-run this any time to reset the demo to a clean state.
4. Start the dashboard (`cd dashboard; npm run dev`) → open `http://localhost:5173`.
5. Start the driver app on the emulator (or a real phone — see runbook).
6. Have the backup screenshots ready in case of network issues.

**Accounts**
- Admin (dashboard): `0700000000` / `admin123`
- Driver (app):      `0711111111` / `driver123`

---

## 1. Open on the command center (1 min)

- Open the dashboard at `http://localhost:5173` and sign in as admin.
- **Say:** "This is the Stan command center — one premium console for the whole fleet."
- Point at the three hero metrics: **Active drivers**, **Open deliveries**, **Tracking alerts**.
- **Say:** "Right now we have one driver active, an in-transit delivery to Westgate, and one already completed today."

## 2. Live map + tracking panel (1.5 min)

- Point at the **Live Nairobi Map** — the demo driver shows mid-route between the Industrial Area hub and Westlands.
- On the right **Live Tracking** panel, show the **Tracking Timeline**.
- **Say:** "Every meaningful event is logged — here the driver collected the parcel and is en route. GPS-off, app-backgrounded, and stoppage events all land here too."

## 3. The driver experience (2 min)

- Switch to the driver app (emulator/phone), already signed in as the demo driver.
- Show the home screen: welcome, active shipment card, transport types.
- Open the **in-transit delivery** → show the route map with pickup (green) and dropoff (red) pins and the live route line.
- **Say:** "The driver sees their route, and the app sends live GPS automatically every few seconds while a delivery is active."

## 4. Live status update — the money moment (2 min)

- In the driver app, advance the delivery status (e.g. tap to mark **delivered**), or drive the emulator location to the dropoff to trigger auto-complete.
- Switch back to the dashboard (auto-refreshes every 10s, or hit **Refresh**).
- **Say:** "Notice the dashboard updated on its own — the completed delivery moves over, the metrics change, and the timeline gets a new event. No phone calls, no spreadsheets."

## 5. Assign a new delivery (1 min)

- In the dashboard **Assign Delivery** form, pick the driver, keep the prefilled Nairobi coordinates, and click **Assign**.
- **Say:** "Dispatch assigns a job here; it appears on the driver's phone instantly and tracking starts the moment they open it."

## 6. Wrap (30 sec)

- Return to the hero metrics.
- **Say:** "That's the full loop — dispatch, drive, track, complete — all on Stan. The driver app installs straight from our download page; no Play Store needed for the pilot."

---

## Reset between runs

To put everything back to a clean demo state, just re-run:

```powershell
cd backend
npm run db:seed:demo
```

## If something breaks

See **`docs/DEMO_RUNBOOK.md` → Common Failure Fixes**. Quick hits:
- Dashboard blank / can't log in → backend not running on port 5000.
- Driver app can't connect → emulator must use `10.0.2.2`; real phone must use the PC Wi-Fi IP baked into the APK.
- No driver on the map → re-run `npm run db:seed:demo` (its location is timestamped to "now").
