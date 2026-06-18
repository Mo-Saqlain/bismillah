# Supabase setup

Bismillah's cloud sync is **optional**. The app is fully functional
without it — local SQLite remains the source of truth and atomic file
backups still run regardless. Supabase adds:

- Off-device durability (your data survives losing or wiping the phone).
- Multi-device use (your second phone / tablet sees the same data).

## One-time setup

1. **Create a Supabase project** at https://supabase.com/dashboard
   (Free tier is enough for a single operator).

2. **Apply the schema.** Open the SQL Editor in the dashboard and paste
   the contents of [`migrations/0001_initial.sql`](migrations/0001_initial.sql).
   This creates 10 tables, the bump-on-update triggers, and open RLS
   policies. On an **existing** project, also apply any later numbered
   files in [`migrations/`](migrations/) in order
   (e.g. `0002_material_quantity_optional.sql`) — fresh projects get
   those changes from `0001_initial.sql` already.

3. **Get your project's URL and anon key** from
   Project Settings → API. The URL looks like
   `https://<project-ref>.supabase.co`. The anon key is a long string
   starting with `sb_publishable_…` (new format) or `eyJ…` (JWT,
   older projects).

4. **Build the APK with the credentials baked in** via `--dart-define`:

   ```bash
   flutter build apk --release \
     --dart-define=SUPABASE_URL=https://<project-ref>.supabase.co \
     --dart-define=SUPABASE_ANON_KEY=sb_publishable_xxx
   ```

   The build script reads these via `String.fromEnvironment`. **Do not**
   commit them to the repo — keep them in CI secrets or a local
   `.env` file.

5. **First launch** — the app generates a `tenant_id` UUID on first
   sync and stores it in `app_settings`. From that point every row
   pushed up is tagged with that id, and pulls filter on it.

## Adding a second device

1. Build the second device's APK with the **same `SUPABASE_URL` and
   `SUPABASE_ANON_KEY`**.
2. On the first device, go to **Settings → Cloud Sync → Tenant ID →
   Copy**. Share the UUID securely.
3. On the second device, before any data is written: **Settings →
   Cloud Sync → Tenant ID → Edit** and paste in the same UUID.
4. Tap **Sync now** on the second device. Every row from device 1
   pulls down. Going forward, writes on each device push to the
   shared dataset; the other device pulls them in.

## Conflict policy

Every device's own writes are **never** overwritten by pulls.

- New rows (different `id`) on either device propagate normally.
- A row that exists on both devices stays as whatever each device
  last wrote it to be — the local copy is authoritative on that
  device. The cloud row reflects whichever device last pushed.
- Soft-deletes (the `is_deleted = 1` flag) propagate as ordinary
  writes — both devices see the deletion.

This is the safest setting for accounting data: there is no scenario
where a local write you can see disappears because of a sync.

## Security model

- The anon key is the only credential.
- RLS is open within the project — anyone with the anon key + the
  project URL can read everything in this project.
- There is no Supabase Auth, no per-user JWT.
- Therefore: **keep the anon key out of public source code**. Pass it
  via `--dart-define` at build time, not in the repo.

This is the explicit trade-off chosen for a single-operator
construction app — no login screens, no role system, fast and
offline-friendly. If you ever want hardened multi-tenancy, replace
the open RLS policy with a JWT-claim check and add Supabase Auth
sign-in.

## Disabling cloud sync

Settings → Cloud Sync → toggle off. The app keeps writing locally
and the local file backups continue. Re-enable any time; the next
push will catch up everything that changed while it was off.
