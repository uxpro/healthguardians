# Health Guardians website and dashboards

Static website of Health Guardians (HG Group) plus two dashboards for the browser:

- **Customer dashboard** (role `user`): one customer, its humanoids and their events.
  - **Central Clinic** (`cc@hg.com`): fall detection, 4 humanoids. A decoy: its events are simulated in the browser by a timer
    and are never stored.
  - **North Clinic** (`nc@hg.com`): conversation support, 3 OEM B humanoids. The live demo: `Roha2212` (photo in `assets/img/Roha2212.jpeg`) is linked
    to `Demo_Patient_UUID` and to the `nc@hg.com` account. Events are real database rows, fetched by polling with the JWT.
- **Health Guardian Logistics Dashboard** (role `admin`, `admin@hg.com`): the whole fleet, availability and logistics only.
  It never sees patient IDs, use cases or event payloads.

Plain HTML, CSS and JavaScript modules: no build step, no dependencies. GitHub Pages serves the folder as it is.

## How the live sync works

```
HealthGuardians phone app (signed in as nc@hg.com) ─┐
Robotic face in the North Clinic dashboard ─────────┼─► public.hg_events ─┐
Demo injection buttons (North Clinic) ──────► public.hg_robot_events ─────┼─► hg_feed() ◄── polled every 3 s by both dashboards
                                                                          ┘
```

- The phone app keeps writing `public.hg_events` exactly as before. The events of the account linked to a humanoid
  (`nc@hg.com` → `Roha2212`) are shown as that humanoid's events, with an event code:

| Check-in step and answer | Code | Type |
|---|---|---|
| session started / completed | 1 / 6 | Keep alive |
| mood good / okay | 2 / 3 | Keep alive |
| medication yes | 4 | Keep alive |
| exercise demo | 5 | Keep alive |
| mood "not so good" | 200 | Emergency |
| no answer within 20 s | 201 | Emergency |
| medication "no" | 202 | Emergency |

- Event codes: 0-63 keep alive, 64-127 environment variable alarm, 128-191 fall detected, 192-255 emergency
  (`public.hg_event_codes`).
- Customers see the payload of their events; the logistics dashboard gets every event without its payload (enforced in
  the database, not only in the page).

## What is implemented and what is a mock-up

| Feature | Status |
|---|---|
| Sign in / sign out with Supabase Auth, JWT refresh | implemented |
| Event feed by polling, event animation widget, events today, robot log, alerts | implemented |
| Robotic virtual face running the check-in (writes `hg_events`) | implemented (North Clinic) |
| Demo data injection | implemented (North Clinic) |
| Account details (display name, phone) | implemented |
| Export events (CSV for Excel) | implemented |
| Audit log of all dashboard actions (admins only) | implemented |
| Fleet by customer / by OEM, per-instance panel, integrity indicators | implemented (data from the database) |
| Central Clinic events, room climate, reliability plot | simulated in the browser |
| Rental extension, support ticket, deploy, maintenance (4 s technician timer), part requests | mock-ups: the view works, nothing is sent; the action is written to the audit log |
| Warehouse availability, spare parts lists | static mock-up data |
| Humanoid pictures | placeholders until the model photos arrive |

## Set up (once)

1. **Accounts.** In the production Supabase project (the one in `assets/js/config.js`, same as the app):
   Authentication → Users → Add user → Create new user, three times: `cc@hg.com`, `nc@hg.com`, `admin@hg.com`, each
   with the agreed demo password and **Auto Confirm User** ticked. No metadata is needed.
2. **Database.** SQL Editor → New query → paste [`db/hg_dashboards.sql`](db/hg_dashboards.sql) → Run. It first
   creates `hg_events` (the app's event log) if it is missing, then the dashboards in one transaction; it can be run
   again. The last line shows which demo accounts were linked; if an account was created later, run
   `select public.hg_link_demo_accounts();`.
   It adds only `hg_*` tables and functions and does not change any existing table, role or policy.
   To check the setup and see the latest app events, run [`db/check.sql`](db/check.sql).
3. **Phone app (optional).** Sign in to the HealthGuardians app with `nc@hg.com`: its check-ins now appear on both
   dashboards as events of Roha2212.

## Publish on GitHub Pages

The site lives in `website/`, but Pages only serves the repository root or `/docs`, so publish the folder to a
`gh-pages` branch:

```powershell
cd E:\projects\healthguardians
git subtree push --prefix website origin gh-pages
```

Then on GitHub: Settings → Pages → Build and deployment → Deploy from a branch → `gh-pages` / `(root)`.
The site is at `https://uxpro.github.io/healthguardians/`. Run the same `git subtree push` after each change.

## Demo script

1. Open the logistics dashboard as `admin@hg.com` in one window and the North Clinic dashboard as `nc@hg.com` in another.
2. North Clinic: **Start check-in**, answer "Not so good" and "No". Within about 3 s both dashboards show the
   emergencies; the logistics side shows them without the answers.
3. North Clinic: press **Fall detected** in Demo data injection. The event animation widget flashes on both.
4. Logistics: pick the humanoid, open **Time to failure plot** and **Components list**, schedule a maintenance (the
   technician accepts after 4 s), then open the **Audit log**.
5. Central Clinic (`cc@hg.com`): simulated events arrive every 7-16 s, with room climate and reminders.

## Files

```
index.html … 404.html          public pages (about, business model, use cases, partners, stories, careers, FAQ,
                                rental terms, privacy, cookies, contact), login.html, dashboard.html
assets/css/hg.css              design system (neo-brutalism: cream, charcoal, emerald)
assets/js/site.js              header, footer, cookie notice, accessibility widget
assets/js/api.js, session.js   Supabase Auth + REST with the JWT (no library)
assets/js/dashboard.js         both dashboards
assets/js/face.js              robotic face and check-in
assets/js/sim.js, data.js      Central Clinic simulation, reliability model, mock-up data
assets/js/charts.js, robot-art.js, format.js
db/hg_dashboards.sql           complete setup: app event log, tables, functions, demo data (production)
db/check.sql                   is everything in place? latest app events
db/test_hg_dashboards.sql      database tests; db/run-tests.sh runs them
tests/unit.test.js             unit tests (node --test)
tests/e2e.py                   browser tests against the real SQL on a local Postgres
```

## Tests

```bash
cd website
npm test                                  # 21 unit tests, Node 20+ (no packages to install)
PROD_DB_REPO=<clone of the repository that owns the production migrations> ./db/run-tests.sh
python3 tests/e2e.py                      # needs Playwright, Chrome, psql and a local server; see the file header
```

The database tests replay the production migrations on a throwaway local Postgres, apply `hg_dashboards.sql` twice and
check access per role (anonymous, outsider, banned, user, admin), the event mapping, injection limits and deletion.
The end-to-end test signs in as each account and checks the pages, the check-in, the sync between dashboards, the
mock-ups, the export, the audit log and that nothing on the public pages mentions another company.

## Security notes

- Only the publishable key is in the code; access is decided by the database functions with the JWT.
- `hg_*` tables have Row Level Security on and no direct grants; the functions check membership, role and customer.
- Banned accounts and accounts without a Health Guardian membership get nothing.
- Injection and audit logging are rate-limited per account (20 and 60 per minute).
- No password is stored in this repository.
