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

## Next Recommended Step

Improve the UI after the workflow is confirmed:

- Better driver app layout
- Better admin dashboard layout
- App name and branding
- Cleaner delivery cards
- Cleaner map-first dashboard

