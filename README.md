# GoStatement

Bus terminal settlement portal — operator login, admin daily entry (manual + Excel import),
itemized deductions/additions, reconciliation, PDF statement generation, and multi-admin accounts.

This deployment starts with **no seed data** — sign in as admin (see below) and either:
- **Import from Excel** on the Daily Entry page (recommended for real settlement files), or
- **Import data snapshot** on the Admins page, using a JSON backup exported from another
  instance of this app.

Everything is stored in the visiting browser's local storage only — there is no shared
backend yet, so different browsers/devices will not see each other's data automatically.
Use Export/Import on the Admins page to move a snapshot between devices.

Default admin login: `admin` / `Admin@2026` — change this immediately after first login
(sidebar → Password).
