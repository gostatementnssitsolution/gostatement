# GoStatement

Bus terminal settlement portal — operator login, admin daily entry (manual + Excel import),
itemized deductions/additions, reconciliation, PDF statement generation, and multi-admin accounts.

## Pages

- **`index.html`** — the public marketing homepage (introduction, features, how it works,
  security). This is what visitors see first at the site root.
- **`app.html`** — the actual settlement portal (login + full app). Every "Log in" / "Get
  started" link on the marketing page points here.
- **`index-v2.html`** — an in-progress redesign of the app shell, not linked from the live site.

This deployment starts with **no seed data** — sign in as admin (see below) and either:
- **Import from Excel** on the Daily Entry page (recommended for real settlement files), or
- **Import data snapshot** on the Admins page, using a JSON backup exported from another
  instance of this app.

Everything is stored in the visiting browser's local storage only — there is no shared
backend yet, so different browsers/devices will not see each other's data automatically.
Use Export/Import on the Admins page to move a snapshot between devices.


