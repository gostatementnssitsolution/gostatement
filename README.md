# GoStatement

Bus terminal settlement portal — operator login, admin daily entry (manual + Excel import),
itemized deductions/additions, reconciliation, PDF statement generation, and multi-admin accounts.

## Pages

- **`index.html`** — the public marketing homepage (introduction, features, how it works,
  security). This is what visitors see first at the site root.
- **`app.html`** — the actual settlement portal (login + full app). Every "Log in" / "Get
  started" link on the marketing page points here.
- **`index-v2.html`** — an in-progress redesign of the app shell, not linked from the live site.
  Its sidebar only has working pages for Dashboard, Statements, and Operators — the rest are
  disabled with a "(soon)" label until they're built out.

## Backend

GoStatement is backed by a real Supabase project (Postgres + Auth + Edge Functions), configured
in `config.js` and wired up in `supabase-adapter.js`. The full schema, indexes, and Row Level
Security policies are documented in [`supabase/schema.sql`](supabase/schema.sql) — that file is a
snapshot pulled directly from the live database, not a guess from reading the client code, so it
can be used to review the access-control model or to bootstrap a fresh project.

Multi-tenant isolation (an operator only ever seeing their own settlement data) is enforced by
RLS at the database layer, not by the client: every table has RLS enabled, and access is decided
by two `SECURITY DEFINER` helper functions, `is_admin()` and `my_operator_ids()` (see
`supabase/schema.sql` for their exact definitions). Admin-only writes (creating operators/admins,
finalizing entries, etc.) mostly go through service-role Edge Functions so they can't be forged
from the browser.

**If `config.js` isn't configured** (or Supabase is unreachable), the app falls back to a
local-only mode: data lives in the visiting browser's `localStorage` only, with no shared backend
— different browsers/devices won't see each other's data. A fresh browser in this mode gets a
one-time random admin password (shown once on screen, never a fixed default) instead of seeded
data with a known password. Use Export/Import on the Admins page to move a local-only snapshot
between devices; this doesn't apply once a real Supabase login is in use, since that data already
lives in the shared backend.
