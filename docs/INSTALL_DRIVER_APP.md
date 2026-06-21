# Stan Driver App — Install Instructions

This guide explains how to install the **Stan** driver app on an Android phone,
and how to (re)build the release APK.

---

## 1. What gets installed

- **App name:** Stan
- **Icon:** white "S" mark on the dark Stan brand background
- **Version:** 1.0.0 (build 1)
- **Package id:** `com.example.driver_app`
- **File:** `stan-driver.apk` (~49 MB)
- **Minimum Android:** 6.0+

The built APK lives at:

```text
driver_app/build/app/outputs/flutter-apk/app-release.apk
```

A copy for the download page is kept at:

```text
website/downloads/stan-driver.apk
```

---

## 2. Install on an Android phone (sideload)

1. Copy `stan-driver.apk` to the phone (USB, email, or the download page), or
   open the **download page** (`website/index.html`) on the phone and tap
   **Download APK**.
2. Tap the downloaded `stan-driver.apk` file.
3. Android will warn that the app is from an unknown source. Tap
   **Settings → Install unknown apps → allow** for the browser/Files app,
   then go back and tap **Install**.
4. Open **Stan** and sign in:
   - Driver: `0711111111` / `driver123`
5. Approve the location permission when asked (required for live GPS tracking).

---

## 3. IMPORTANT — API URL is baked in at build time

The app talks to the backend using an API base URL that is fixed **when the APK
is built** (via `--dart-define=API_BASE_URL=...`). You must build the APK that
matches where the phone will run:

| Phone type | API base URL to build with |
|---|---|
| Android **emulator** on the dev PC | `http://10.0.2.2:5000` |
| **Real phone** on the same Wi-Fi as the PC | `http://<PC_LAN_IP>:5000` |

> The APK currently in `website/downloads/` was built for the **emulator**
> (`10.0.2.2`). For a **real-phone demo** you must rebuild with the PC's Wi-Fi IP
> address — see `docs/NEEDS_FROM_OWNER.md`.

Find the PC Wi-Fi IP (PowerShell):

```powershell
ipconfig | Select-String "IPv4"
```

---

## 4. (Re)build the release APK

From the `driver_app` folder:

```powershell
# Emulator build
flutter build apk --release --dart-define=API_BASE_URL=http://10.0.2.2:5000

# Real-phone build (replace with your PC Wi-Fi IP)
flutter build apk --release --dart-define=API_BASE_URL=http://192.168.0.104:5000
```

Then refresh the download copy:

```powershell
Copy-Item driver_app\build\app\outputs\flutter-apk\app-release.apk website\downloads\stan-driver.apk -Force
```

### Optional: enable Google Maps

By default the app uses the free OpenStreetMap layer. To switch to Google Maps
(better Nairobi detail + road-following routes), add your key in
`android/local.properties` (`MAPS_API_KEY=...`) and add
`--dart-define=GOOGLE_MAPS_API_KEY=...` to the build command. Full steps:
`docs/GOOGLE_MAPS_SETUP.md`.

---

## 5. Signing note

The release build is currently signed with the **debug signing key** (configured
in `android/app/build.gradle.kts`). This is fine for sideloading and demos, but a
**Google Play Store** release needs a proper upload keystore. The owner must
create and supply that keystore — see `docs/NEEDS_FROM_OWNER.md`. Never commit
keystore files or passwords to git.
