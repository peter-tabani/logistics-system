# Logistics System Demo Runbook

## Phase 1 Demo Goal

Show the owner a stable working flow before branding and release packaging:

1. Backend API is running.
2. Admin dashboard opens in the browser.
3. Driver app opens on Android emulator.
4. Admin can assign/view deliveries.
5. Driver can log in and send location.
6. Dashboard can show live tracking data.

## Your Responsibilities Before Demo

- Keep PostgreSQL running.
- Keep the laptop connected to reliable internet for map tiles.
- Keep the Android emulator open, or connect a real Android phone before the demo.
- Do not close the terminal windows running backend, dashboard, or Flutter.
- If using a real phone later, keep phone and laptop on the same Wi-Fi network.
- Have backup screenshots ready before presenting to the owner.

## Test Accounts

Admin dashboard:

```text
0700000000 / admin123
```

Driver app:

```text
0711111111 / driver123
```

## Start Backend

Run from the backend folder:

```powershell
npm run dev
```

Expected success:

```text
Server running on port 5000
```

Health checks:

```powershell
Invoke-RestMethod http://localhost:5000/health
Invoke-RestMethod http://localhost:5000/db-health
```

## Start Dashboard

Run from the dashboard folder:

```powershell
npm run dev -- --host 0.0.0.0
```

Open:

```text
http://localhost:5173
```

## Start Android Emulator

Run from the driver app folder:

```powershell
flutter emulators --launch logistics_phone
```

Verify emulator:

```powershell
flutter devices
```

Expected Android device:

```text
emulator-5554
```

## Run Driver App On Emulator

Run from the driver app folder:

```powershell
flutter run -d emulator-5554 --dart-define=API_BASE_URL=http://10.0.2.2:5000
```

Use `10.0.2.2` only for the Android emulator.

## Run Driver App On Real Phone Later

Find laptop IP address on Wi-Fi, then run:

```powershell
flutter run -d <device-id> --dart-define=API_BASE_URL=http://YOUR_PC_WIFI_IP:5000
```

Example:

```powershell
flutter run -d <device-id> --dart-define=API_BASE_URL=http://192.168.0.104:5000
```

## Owner Demo Flow

1. Open dashboard at `http://localhost:5173`.
2. Login as admin.
3. Show map and monitoring dashboard.
4. Open Android driver app.
5. Login as driver.
6. Open assigned delivery.
7. Tap send/show location.
8. Refresh dashboard and show driver location.
9. Change delivery status in driver app.
10. Show dashboard updates and tracking timeline.

## Current Verified Status

- Node, npm, and Flutter are installed.
- Backend dependencies are installed.
- Dashboard dependencies are installed.
- Backend `.env` exists.
- PostgreSQL connection works.
- Backend `/health` works.
- Backend `/db-health` works.
- Dashboard serves on `http://localhost:5173`.
- Android emulator `logistics_phone` launches as `emulator-5554`.
- Driver app builds and runs on the emulator.
- Admin and driver logins work through the backend.

## Common Failure Fixes

### Backend says database error

- Start PostgreSQL.
- Check backend `.env` database password and database name.
- Run database init/seed only if tables or accounts are missing.

### Driver app cannot connect

- Emulator must use `http://10.0.2.2:5000`.
- Real phone must use laptop Wi-Fi IP, not localhost.
- Backend must be running before opening the app.

### Dashboard is blank or cannot login

- Backend must be running on port `5000`.
- Dashboard must be running on port `5173`.
- Use admin account, not driver account.

### GPS does not work in emulator

- Set emulator location from Android Emulator controls.
- Approve location permission inside the driver app.
- Keep location services enabled.
