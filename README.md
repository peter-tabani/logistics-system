# Logistics System

MVP logistics tracking system for a small fleet.

## Project Folders

- `backend` - Node.js/Express API
- `driver_app` - Flutter Android driver app
- `dashboard` - Future admin web dashboard
- `docs` - Notes, requirements, and planning

## Run Backend

```powershell
cd backend
npm run dev
```

Open:

```text
http://localhost:5000
http://localhost:5000/health
```

## Run Driver App

```powershell
cd driver_app
flutter run
```

Before Android running works, fix the Android toolchain items from:

```powershell
flutter doctor
```

## First MVP Features

1. Admin can create driver accounts.
2. Driver can log in on Android.
3. Driver app asks for GPS permission.
4. Driver app sends location to backend.
5. Admin dashboard shows driver locations on a map.
