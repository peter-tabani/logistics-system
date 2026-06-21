# Google Maps Setup (Stan)

Stan can render maps two ways:

- **Google Maps** — used automatically **when an API key is configured** (best
  Nairobi detail, place names, and road-following routes).
- **OpenStreetMap (free, no key)** — the automatic **fallback** when no key is
  set, so the app and dashboard always show a map.

You only need this guide if you want the Google Maps look. Nothing here is
required for the basic demo — without a key everything still works on OSM.

> ⚠️ Pricing note: Google changed Maps Platform pricing in 2025. Confirm the
> current free-tier allowance and rates on Google's official pricing page before
> enabling billing. At Stan's scale (a handful of drivers + one dashboard) usage
> is tiny, but a billing account with a card on file is still required.

---

## 1. Create the key in Google Cloud Console

1. Go to <https://console.cloud.google.com/> and create (or pick) a project.
2. Enable **billing** on the project (required even within the free tier).
3. Under **APIs & Services → Library**, enable:
   - **Maps JavaScript API**  (dashboard)
   - **Maps SDK for Android**  (driver app)
   - **Directions API**  (road-following routes, both)
4. Under **APIs & Services → Credentials → Create credentials → API key**,
   create a key. (You can make one key for everything, or one per platform.)

### Restricting the key (recommended)

- **Dashboard key** → Application restriction: **HTTP referrers**, add your
  dashboard domain (e.g. `http://localhost:5173/*` for local, plus the real
  domain later). API restriction: Maps JavaScript API + Directions API.
- **Android key** → Application restriction: **Android apps**, add package name
  `com.example.driver_app` with your signing **SHA-1**. API restriction:
  Maps SDK for Android (+ Directions API if you want mobile road routes — see
  the caveat below).

---

## 2. Dashboard (web)

1. In `dashboard/`, copy `.env.example` to `.env`.
2. Set the key:
   ```
   VITE_GOOGLE_MAPS_API_KEY=AIzaSy...your-key...
   ```
3. Restart `npm run dev` (or rebuild). The dashboard map switches to Google with
   road-following routes automatically. Remove the value to go back to OSM.

`.env` is gitignored — never commit the real key.

---

## 3. Driver app (Android)

The native Maps SDK reads the key from the **Android manifest**, which we inject
from `android/local.properties` (gitignored).

1. Open `driver_app/android/local.properties` and add a line:
   ```
   MAPS_API_KEY=AIzaSy...your-key...
   ```
2. Build the app passing the **same key** as a dart-define (this is the switch
   that turns Google Maps on in the Dart code):
   ```powershell
   flutter build apk --release ^
     --dart-define=API_BASE_URL=http://10.0.2.2:5000 ^
     --dart-define=GOOGLE_MAPS_API_KEY=AIzaSy...your-key...
   ```
   (Use your real-phone API URL instead of `10.0.2.2` for a physical device.)
3. Without `MAPS_API_KEY` + `GOOGLE_MAPS_API_KEY`, the app uses the OSM map.

> The key lives in two files only because Android needs it natively (manifest)
> while Dart needs to know whether to switch maps on. Both are gitignored /
> build-time — the key is never committed.

### Caveat: mobile road-following routes

The driver app fetches road routes from the **Directions API** directly from the
phone. Google's **Android-app** key restriction does **not** cover web-service
calls like Directions, so:

- If your Android key is locked to the app (package + SHA-1) **only**, the
  Directions call is rejected and the app **gracefully falls back to a straight
  line** between pickup and dropoff. The map tiles/markers still work.
- To get road-following routes on the phone too, either add an **API
  restriction** that includes Directions without an app restriction, or use a
  separate, API-restricted key for Directions. Weigh this against key exposure
  on the client.

The **dashboard** road routes are unaffected by this caveat (referrer-restricted
keys work fine with the JS Directions service).

---

## 4. Quick verification

- Dashboard: open it; the map should look like Google Maps and draw a route line
  along roads between pickup and dropoff for the active delivery.
- Driver app: open an active delivery; the map should be Google with pickup
  (green), dropoff (red), and your position (blue) markers.
- If you still see OSM tiles, the key isn't being picked up — recheck `.env` /
  `local.properties` and that you passed `--dart-define=GOOGLE_MAPS_API_KEY`.
