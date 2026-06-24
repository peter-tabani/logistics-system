# Making the app connect from anywhere (work / school / home)

**Why it fails now:** the backend runs on your PC, so the phone can only reach
it on the *same Wi-Fi as the PC*. On a different network — or with the PC off —
there's nothing to connect to. The fix is to make the backend reachable over the
**internet**. The app already lets you change the address (login →
**Server settings**), so once you have an internet address, you just paste it —
no rebuild.

There are two ways. Use Option A today; do Option B once for a permanent fix.

---

## Option A — Tunnel (works today, no signup) — PC must be on

This exposes your local backend at a temporary public HTTPS link. Works from any
network while your PC and the tunnel are running.

1. Install Cloudflare Tunnel (one time), in PowerShell:
   ```powershell
   winget install --id Cloudflare.cloudflared
   ```
2. Start your backend as usual (`npm run dev` in `backend/`).
3. In another terminal, run:
   ```powershell
   cloudflared tunnel --url http://localhost:5000
   ```
4. It prints a URL like `https://random-words.trycloudflare.com`. On the phone,
   open Stan → login → **Server settings**, paste that URL, Save.
5. Sign in. It now works on any Wi-Fi or mobile data — as long as the PC + the
   `cloudflared` command stay running.

Note: the free tunnel URL changes each time you restart `cloudflared`; just
paste the new one into Server settings. (A free Cloudflare account can give a
fixed name if you want.)

Limitation: your PC must be on and running both commands. If the PC is off
(e.g. you're at school, PC at home), use Option B.

---

## Option B — Deploy to the cloud (permanent, always-on, no PC)

Host the backend + database online so it's always reachable. ~15 minutes, free
tier. A `render.yaml` blueprint is already in the repo.

1. Push this repo to GitHub.
2. Create a free account at <https://render.com>.
3. **New → Blueprint**, select the repo. Render reads `render.yaml` and creates
   the backend + a free Postgres, wiring `DATABASE_URL` and `JWT_SECRET`
   automatically.
4. When it's live, open the web service's **Shell** and run once:
   ```bash
   npm run db:init && npm run db:seed && npm run db:seed:demo
   ```
5. Copy the service URL (e.g. `https://stan-backend.onrender.com`) and set it in
   the app's **Server settings**. Done — works everywhere, PC off.

The code already supports this: `db.js` uses `DATABASE_URL` + SSL when present.

> Free-tier caveats: Render free web services sleep after ~15 min idle (first
> request wakes them, ~30s), and free Postgres has storage/time limits — fine
> for a demo. For production, a paid plan or a managed DB (e.g. Neon) is better.
> Anything real M-Pesa/Daraja still needs the items in `NEEDS_FROM_OWNER.md`.

---

## Quick decision
- **Just need to demo from another room/office today?** Option A.
- **Want it to always work without touching the PC?** Option B.
