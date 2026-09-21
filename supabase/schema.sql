-- GoStatement — Supabase schema + Row Level Security snapshot
--
-- This is a documentation/disaster-recovery snapshot of the schema and RLS
-- policies that already exist on the live GoStatement project (referenced
-- as "gostatement-schema.sql" by supabase-adapter.js, but never previously
-- committed to this repo — so it could not be reviewed or restored from
-- source control). Extracted directly from the live database (tables,
-- columns, indexes, RLS policies, and helper-function source), not
-- reverse-engineered from client code.
--
-- USAGE: written for bootstrapping a FRESH Supabase project (a new
-- environment, or disaster recovery). Running it against a database that
-- already has these objects will fail on the CREATE TABLE / CREATE POLICY
-- statements — it is not designed to be re-applied to the live project.
-- Edge functions (create-operator-account, manage-admin, operator-claim,
-- send-settlement-email) are deployed separately and are not part of this
-- schema file.
--
-- Multi-tenant model: every table has RLS enabled. Two SECURITY DEFINER
-- helper functions decide access — is_admin() (active admin) and
-- my_operator_ids() (the operator(s) the signed-in user is a member of,
-- via operator_members — a real company can run multiple brands/terminals
-- under one login). Everything else is admin-or-mine.

-- ============================================================
-- Extensions
-- ============================================================
create extension if not exists pgcrypto; -- gen_random_uuid()

-- ============================================================
-- Enums
-- ============================================================
create type public.user_role as enum ('admin', 'operator');
create type public.entry_status as enum ('draft', 'prefinalized', 'finalized');
create type public.manual_invoice_status as enum ('draft', 'finalized');
create type public.statement_status as enum ('draft', 'finalized');
create type public.statement_type as enum ('undersales', 'compensation', 'refund', 'other_charges');

-- ============================================================
-- Tables
-- ============================================================

create table public.terminals (
  id uuid primary key default gen_random_uuid(),
  code text not null unique,
  name text not null,
  created_at timestamptz not null default now()
);

create table public.operators (
  id uuid primary key default gen_random_uuid(),
  terminal_id uuid not null references public.terminals(id),
  company text not null,
  email text,
  active boolean not null default true,
  must_change_password boolean not null default true,
  invoice_seq integer,
  default_tos_rate numeric not null default 10,
  company_name text,
  company_address text,
  alt_email text,
  claim_code text,
  notify_email text,
  notify_email_cc text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (terminal_id, company)
);
create index idx_operators_terminal_id on public.operators(terminal_id);
create unique index operators_claim_code_key on public.operators(claim_code) where claim_code is not null;

-- One row per Supabase Auth user. role='admin' rows are administrators;
-- role='operator' rows link back to a single primary operator record
-- (operator_id) — a user with access to MORE than one operator (see
-- operator_members below) still has one profile.
create table public.profiles (
  id uuid primary key references auth.users(id),
  full_name text,
  role public.user_role not null default 'operator',
  operator_id uuid references public.operators(id),
  active boolean not null default true,
  is_super_admin boolean not null default false,
  permissions jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index idx_profiles_operator_id on public.profiles(operator_id);

-- Membership junction: which operator record(s) a signed-in user may act
-- as (the same real company running multiple brands, or the same brand at
-- more than one terminal, shares one login across several operator rows).
create table public.operator_members (
  user_id uuid not null references auth.users(id),
  operator_id uuid not null references public.operators(id),
  created_at timestamptz not null default now(),
  primary key (user_id, operator_id)
);
create index operator_members_operator_id_idx on public.operator_members(operator_id);

create table public.settlement_entries (
  id uuid primary key default gen_random_uuid(),
  terminal_id uuid not null references public.terminals(id),
  operator_id uuid not null references public.operators(id),
  entry_date date not null,
  sales numeric not null default 0,
  std_charge numeric not null default 0,
  manual_charge numeric not null default 0,
  undersales numeric not null default 0,
  final_amount numeric not null default 0,
  items jsonb not null default '{}'::jsonb,
  adjustments jsonb not null default '[]'::jsonb,
  note text,
  status public.entry_status not null default 'draft',
  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),
  email_sent_at timestamptz,
  email_sent_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (terminal_id, operator_id, entry_date)
);
create index idx_settlement_entries_terminal_id on public.settlement_entries(terminal_id);
create index idx_settlement_entries_operator_id on public.settlement_entries(operator_id);
create index idx_settlement_entries_date on public.settlement_entries(entry_date);
create index idx_settlement_entries_created_by on public.settlement_entries(created_by);
create index idx_settlement_entries_updated_by on public.settlement_entries(updated_by);
create index idx_settlement_entries_email_sent_at on public.settlement_entries(email_sent_at);

create table public.manual_invoices (
  id uuid primary key default gen_random_uuid(),
  terminal_id uuid not null references public.terminals(id),
  operator_id uuid not null references public.operators(id),
  invoice_no text not null unique,
  invoice_date date not null,
  period_from date not null,
  period_to date not null,
  rate numeric not null default 10,
  quantity integer not null default 0,
  amount numeric not null default 0,
  rounding numeric not null default 0,
  grand_total numeric not null default 0,
  bill_to_name text,
  bill_to_address text,
  status public.manual_invoice_status not null default 'draft',
  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (terminal_id, operator_id, period_from, period_to)
);
create index idx_manual_invoices_terminal on public.manual_invoices(terminal_id);
create index idx_manual_invoices_operator on public.manual_invoices(operator_id);
create index idx_manual_invoices_period on public.manual_invoices(period_from, period_to);

create table public.manual_trip_entries (
  id uuid primary key default gen_random_uuid(),
  invoice_id uuid not null references public.manual_invoices(id),
  trip_no integer not null,
  trip_date date not null,
  enter_time text,
  exit_time text,
  plate_no text,
  destination text,
  created_at timestamptz not null default now()
);
create index idx_manual_trip_entries_invoice on public.manual_trip_entries(invoice_id);

create table public.statements (
  id uuid primary key default gen_random_uuid(),
  terminal_id uuid not null references public.terminals(id),
  operator_id uuid not null references public.operators(id),
  type public.statement_type not null,
  statement_no text not null unique,
  statement_date date not null default current_date,
  period_from date,
  period_to date,
  amount numeric not null default 0,
  description text,
  status public.statement_status not null default 'draft',
  created_by uuid references auth.users(id),
  updated_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index idx_statements_terminal_id on public.statements(terminal_id);
create index idx_statements_operator_id on public.statements(operator_id);
create index idx_statements_date on public.statements(statement_date);

-- Single editable-content row for the "Daily Settlement Statement" email,
-- shared by the in-app preview and the send-settlement-email Edge Function.
create table public.email_templates (
  id uuid primary key default gen_random_uuid(),
  greeting text not null default 'Dear Sir/Madam,',
  intro_text text not null default 'We are pleased to inform you that this is the Daily Settlement for {terminal} for the date of {date}. Thank you.',
  reminder_text text not null default 'Please ensure any outstanding are settled within two (2) weeks from the settlement date.',
  contact_email text not null default 'finance.nssit@gohub.com.my',
  signature_name text not null default 'FINANCE OPERATION',
  signature_company text not null default 'NSS IT Solution Sdn Bhd',
  signature_image_url text not null default 'https://gostatementnssitsolution.github.io/gostatement/gohub-signature.png',
  disclaimer_text text not null default 'This email and its contents are confidential and intended solely for the recipient. If received in error, please notify the sender and delete it immediately. Any unauthorised use, disclosure, or distribution is prohibited. Views expressed may not represent those of GO HUB CAPITAL BERHAD or its group of companies.',
  updated_by uuid references auth.users(id),
  updated_at timestamptz not null default now()
);

create table public.audit_logs (
  id bigint generated always as identity primary key,
  user_id uuid references auth.users(id),
  action text not null,
  table_name text not null,
  record_id uuid,
  old_data jsonb,
  new_data jsonb,
  created_at timestamptz not null default now()
);
create index idx_audit_logs_user_id on public.audit_logs(user_id);

-- ============================================================
-- RLS helper functions
-- SECURITY DEFINER + `SET search_path TO ''` (blocks search_path
-- hijacking) so these can be called from inside a policy's USING/CHECK
-- clause without needing the caller to have direct SELECT on `profiles`
-- or `operator_members`.
-- ============================================================

create function public.is_admin()
returns boolean
language sql
stable security definer
set search_path to ''
as $$
  select exists (
    select 1 from public.profiles
    where id = auth.uid() and role = 'admin' and active = true
  );
$$;

create function public.is_super_admin()
returns boolean
language sql
stable security definer
set search_path to ''
as $$
  select exists (
    select 1 from public.profiles
    where id = (select auth.uid()) and role = 'admin' and is_super_admin = true and active = true
  );
$$;

create function public.my_operator_id()
returns uuid
language sql
stable security definer
set search_path to ''
as $$
  select operator_id from public.profiles where id = auth.uid();
$$;

-- Every operator row the signed-in user has membership in (see
-- operator_members) — supports one login covering several operator rows.
create function public.my_operator_ids()
returns setof uuid
language sql
stable security definer
set search_path to ''
as $$
  select operator_id from public.operator_members where user_id = (select auth.uid());
$$;

-- ============================================================
-- Row Level Security
-- ============================================================
alter table public.terminals enable row level security;
alter table public.operators enable row level security;
alter table public.profiles enable row level security;
alter table public.operator_members enable row level security;
alter table public.settlement_entries enable row level security;
alter table public.manual_invoices enable row level security;
alter table public.manual_trip_entries enable row level security;
alter table public.statements enable row level security;
alter table public.email_templates enable row level security;
alter table public.audit_logs enable row level security;

-- terminals: readable by anyone signed in; only admins may manage the list.
create policy terminals_read on public.terminals for select to authenticated using (true);
create policy terminals_admin_insert on public.terminals for insert to authenticated with check (is_admin());
create policy terminals_admin_update on public.terminals for update to authenticated using (is_admin()) with check (is_admin());
create policy terminals_admin_delete on public.terminals for delete to authenticated using (is_admin());

-- operators: admins see/manage everyone; an operator sees/updates only the
-- row(s) they're a member of (createOperator/updateOperator/
-- generateClaimCode in supabase-adapter.js write to this table directly
-- from an admin session, so admins need INSERT/UPDATE, not just the
-- service-role edge functions).
create policy operators_read on public.operators for select to authenticated using (is_admin() or id in (select public.my_operator_ids()));
create policy operators_self_update on public.operators for update to authenticated using (id in (select public.my_operator_ids())) with check (id in (select public.my_operator_ids()));
create policy operators_admin_insert on public.operators for insert to authenticated with check (is_admin());
create policy operators_admin_update on public.operators for update to authenticated using (is_admin()) with check (is_admin());
create policy operators_admin_delete on public.operators for delete to authenticated using (is_admin());

-- profiles: everyone can read their own row; admins can read all. Admins
-- may update OTHER profiles (never their own, to stop an admin silently
-- self-promoting/self-editing through this path — see manage-admin edge
-- function for the real create/delete/permission-change flow) but the
-- role column can never move on self-update.
create policy profiles_read on public.profiles for select to authenticated using (id = (select auth.uid()) or is_admin());
create policy profiles_admin_write on public.profiles for insert to authenticated with check (is_admin());
create policy profiles_admin_update on public.profiles for update to authenticated using (is_admin() and id <> (select auth.uid())) with check (is_admin() and id <> (select auth.uid()));
create policy profiles_self_update_limited on public.profiles for update to authenticated
  using (id = (select auth.uid()))
  with check (id = (select auth.uid()) and role = (select p2.role from public.profiles p2 where p2.id = (select auth.uid())));

-- operator_members: admins manage; a user can see their own memberships
-- (loadMyOperators() reads this as the signed-in operator).
create policy operator_members_read on public.operator_members for select to authenticated using (is_admin() or user_id = (select auth.uid()));
create policy operator_members_admin_insert on public.operator_members for insert to authenticated with check (is_admin());
create policy operator_members_admin_update on public.operator_members for update to authenticated using (is_admin()) with check (is_admin());
create policy operator_members_admin_delete on public.operator_members for delete to authenticated using (is_admin());

-- settlement_entries: the core financial data. An operator may only ever
-- READ their own entries — all writes (including status changes) go
-- through admins, matching the app's finalize/reconcile workflow.
create policy entries_read on public.settlement_entries for select to authenticated using (is_admin() or operator_id in (select public.my_operator_ids()));
create policy entries_admin_insert on public.settlement_entries for insert to authenticated with check (is_admin());
create policy entries_admin_update on public.settlement_entries for update to authenticated using (is_admin()) with check (is_admin());
create policy entries_admin_delete on public.settlement_entries for delete to authenticated using (is_admin());

-- manual_invoices / manual_trip_entries: same admin-writes / owner-reads
-- shape as settlement_entries. Trip-entry access follows its parent invoice.
create policy manual_invoices_read on public.manual_invoices for select to authenticated using (is_admin() or operator_id in (select public.my_operator_ids()));
create policy manual_invoices_admin_insert on public.manual_invoices for insert to authenticated with check (is_admin());
create policy manual_invoices_admin_update on public.manual_invoices for update to authenticated using (is_admin()) with check (is_admin());
create policy manual_invoices_admin_delete on public.manual_invoices for delete to authenticated using (is_admin());

create policy manual_trip_entries_read on public.manual_trip_entries for select to authenticated using (
  exists (
    select 1 from public.manual_invoices mi
    where mi.id = manual_trip_entries.invoice_id
      and (is_admin() or mi.operator_id in (select public.my_operator_ids()))
  )
);
create policy manual_trip_entries_admin_insert on public.manual_trip_entries for insert to authenticated with check (is_admin());
create policy manual_trip_entries_admin_update on public.manual_trip_entries for update to authenticated using (is_admin()) with check (is_admin());
create policy manual_trip_entries_admin_delete on public.manual_trip_entries for delete to authenticated using (is_admin());

-- statements (undersales / compensation / refund / other charges): unlike
-- settlement_entries, operators may write their own statements directly
-- (not just admins) — matches saveStatement()/setStatementStatus()/
-- deleteStatement() in supabase-adapter.js being callable from either role.
create policy statements_read on public.statements for select to authenticated using (is_admin() or operator_id in (select public.my_operator_ids()));
create policy statements_insert on public.statements for insert to authenticated with check (is_admin() or operator_id in (select public.my_operator_ids()));
create policy statements_update on public.statements for update to authenticated using (is_admin() or operator_id in (select public.my_operator_ids())) with check (is_admin() or operator_id in (select public.my_operator_ids()));
create policy statements_delete on public.statements for delete to authenticated using (is_admin() or operator_id in (select public.my_operator_ids()));

-- email_templates: admin-only, single shared row.
create policy email_templates_admin_read on public.email_templates for select to authenticated using (is_admin());
create policy email_templates_admin_write on public.email_templates for insert to authenticated with check (is_admin());
create policy email_templates_admin_update on public.email_templates for update to authenticated using (is_admin()) with check (is_admin());

-- audit_logs: admin-read-only; rows are written by edge functions using
-- the service role, which bypasses RLS, so no INSERT policy is needed here.
create policy audit_admin_read on public.audit_logs for select to authenticated using (is_admin());
