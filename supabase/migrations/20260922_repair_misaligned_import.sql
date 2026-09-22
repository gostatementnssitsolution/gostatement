-- Repair of the 2026-09-09 settlement import
-- =========================================================================
-- APPLIED TO THE LIVE PROJECT ON 2026-09-22. Recorded here so the change to
-- production data is in source control and can be audited or rolled back.
-- Do not run it again: the WHERE clauses no longer match anything, and the
-- backup tables it reads are created by the first two statements.
--
-- WHAT HAPPENED
-- -------------
-- One import session (2026-09-09, 08:26-08:47 UTC, 8,873 rows) read a
-- workbook whose columns did not line up with the parser's expectations.
-- Two distinct kinds of damage came out of it, both confined to that
-- session — every later import (09-10, 09-16, 09-21, 09-22) is clean.
--
--   1. Column shifted by one (623 rows).
--      The sheet's Final column landed in `undersales`, and `final_amount`
--      was left holding the sheet's row counter (1, 2, 3, ...) or other
--      junk. Recognisable because `undersales` equals
--      sales + std_charge + manual_charge exactly — which is what Final
--      means — on all 623, and on nothing else in the table.
--
--   2. Blank Final cell (623 rows, a separate population).
--      `extractRecordsFromSheetRows` read the cell as
--      `Number(cell) || 0`, so a blank Final became a recorded net payout
--      of exactly zero. Operators with thousands in sales were recorded as
--      having been paid nothing.
--
-- WHY THE REPAIRS ARE RECONSTRUCTION AND NOT GUESSWORK
-- ----------------------------------------------------
-- Across all 1,262 rows imported in the clean sessions, final_amount equals
-- sales + std_charge + manual_charge + undersales exactly — 1,262 of 1,262,
-- largest discrepancy 0.00. No clean session ever recorded a zero payout
-- against non-zero components. So that identity is the sheet's own rule,
-- and restoring it reproduces the source rather than inventing a figure.
--
-- For damage (1) the true Final was still present in the row, in
-- `undersales`; the repair moves it back. For damage (2) it was absent, and
-- the repair recomputes it from the identity above.
--
-- WHAT WAS DELIBERATELY NOT REPAIRED
-- ----------------------------------
-- 99 rows from the same session still do not satisfy the identity and are
-- left exactly as they are. Their true Final is not recoverable from the
-- row: 76 fit no simple explanation, and among the rest the wrong figure is
-- sometimes the CHARGE rather than the Final (e.g. SAPTAVARNA 2026-04-19,
-- where final 709.30 = sales 192.60 - 19.25 + 535.95, so it is
-- manual_charge that carries the wrong sign). Overwriting final_amount on
-- those would destroy the one correct number in the row. They need the
-- original spreadsheet, and the import preview now flags this shape before
-- it can be committed again.
--
-- EFFECT
-- ------
--   internally consistent rows   8,948  ->  10,194  of 10,293
--   rows recording a false zero  1,138  ->       0
--   misaligned rows                623  ->       0
--   days with a negative payout    857  ->   1,015
--   recorded net payout      RM 5,429,472.30 -> RM 6,204,380.55
--
-- The negative-day count rises because shortfalls that had been hidden
-- behind a false zero are now visible to the undersales carry-forward
-- ledger, which is where they belong.
-- =========================================================================

-- ---------- 1. Back up both populations before touching them -------------
-- Deliberately NOT in `public`: every table there is served by PostgREST,
-- and these hold the same operator financial data the main table does.
create schema if not exists backup;
revoke all on schema backup from anon, authenticated;

create table if not exists backup.settlement_entries_20260922 as
select id, terminal_id, operator_id, entry_date,
       sales, std_charge, manual_charge, undersales, final_amount,
       status, created_at, updated_at, now() as backed_up_at
from public.settlement_entries
where abs(undersales - (sales + std_charge + manual_charge)) < 0.005
  and abs(undersales) > 0.005;

alter table backup.settlement_entries_20260922 enable row level security;
revoke all on backup.settlement_entries_20260922 from anon, authenticated;

create table if not exists backup.settlement_entries_blankfinal_20260922 as
select id, terminal_id, operator_id, entry_date,
       sales, std_charge, manual_charge, undersales, final_amount,
       status, created_at, updated_at, now() as backed_up_at
from public.settlement_entries e
where e.final_amount = 0
  and abs(e.sales + e.std_charge + e.manual_charge + e.undersales) > 0.005
  and not exists (select 1 from backup.settlement_entries_20260922 b where b.id = e.id);

alter table backup.settlement_entries_blankfinal_20260922 enable row level security;
revoke all on backup.settlement_entries_blankfinal_20260922 from anon, authenticated;

-- ---------- 2. Damage (1): move the Final back out of `undersales` -------
-- Joined to the backup by id, and re-checking both values, so it can only
-- touch rows already captured there and only while they are still damaged.
update public.settlement_entries e
set final_amount = b.undersales,
    undersales   = 0,
    updated_at   = now()
from backup.settlement_entries_20260922 b
where e.id = b.id
  and e.undersales = b.undersales
  and e.final_amount = b.final_amount;   -- 623 rows

-- ---------- 3. Damage (2): recompute the Final that was never read -------
update public.settlement_entries e
set final_amount = b.sales + b.std_charge + b.manual_charge + b.undersales,
    updated_at   = now()
from backup.settlement_entries_blankfinal_20260922 b
where e.id = b.id
  and e.final_amount = 0
  and e.sales = b.sales and e.std_charge = b.std_charge
  and e.manual_charge = b.manual_charge and e.undersales = b.undersales;   -- 623 rows

-- ---------- Rollback, if it is ever needed -------------------------------
-- update public.settlement_entries e
-- set final_amount = b.final_amount, undersales = b.undersales
-- from backup.settlement_entries_20260922 b where e.id = b.id;
--
-- update public.settlement_entries e
-- set final_amount = b.final_amount
-- from backup.settlement_entries_blankfinal_20260922 b where e.id = b.id;
