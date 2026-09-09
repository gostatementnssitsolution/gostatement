/* GoStatement Live — Supabase adapter
   Load this AFTER the Supabase client library (supabase-js) and config.js:

     <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
     <script src="./config.js"></script>
     <script src="./supabase-adapter.js"></script>

   Exposes window.GoStatementLive — the full backend API used to replace
   the old localStorage-based STATE with real Postgres + Auth + Realtime.

   Schema (see gostatement-schema.sql):
     terminals(id, code, name)
     operators(id, terminal_id, company, email, active, must_change_password)
     profiles(id -> auth.users, full_name, role[admin|operator], operator_id, active)
     settlement_entries(id, terminal_id, operator_id, entry_date,
       sales, std_charge, manual_charge, undersales, final_amount,
       items jsonb, adjustments jsonb, note, status[draft|prefinalized|finalized],
       created_by, updated_by, created_at, updated_at)
     audit_logs(...)
*/
(function () {
  const cfg = window.GOSTATEMENT_CONFIG || {};
  if (!cfg.supabaseUrl || cfg.supabaseUrl.startsWith("YOUR_")) {
    console.warn("GoStatement Live: Supabase configuration not set yet.");
    return;
  }
  if (!window.supabase) {
    console.error("GoStatement Live: Supabase library is not loaded.");
    return;
  }

  const db = window.supabase.createClient(cfg.supabaseUrl, cfg.supabaseAnonKey);
  window.GoStatementDB = db;

  /* ---------------- Auth ---------------- */

  async function signIn(email, password) {
    const { data, error } = await db.auth.signInWithPassword({ email, password });
    if (error) throw error;
    return data;
  }

  async function signOut() {
    const { error } = await db.auth.signOut();
    if (error) throw error;
  }

  async function getSession() {
    const { data, error } = await db.auth.getSession();
    if (error) throw error;
    return data.session;
  }

  // Sends a password-reset email. redirectTo should point at a page in this
  // app that calls completePasswordReset() once the user lands with a recovery
  // token in the URL (Supabase appends #access_token=...&type=recovery).
  async function requestPasswordReset(email, redirectTo) {
    const { error } = await db.auth.resetPasswordForEmail(email, {
      redirectTo: redirectTo || window.location.origin + window.location.pathname
    });
    if (error) throw error;
  }

  // Call after the user follows the reset-password link and enters a new password.
  async function completePasswordReset(newPassword) {
    const { data, error } = await db.auth.updateUser({ password: newPassword });
    if (error) throw error;
    return data;
  }

  async function getMyProfile() {
    const { data: { user } } = await db.auth.getUser();
    if (!user) return null;
    const { data, error } = await db
      .from("profiles")
      .select("id, full_name, role, active, operator_id, operators(id, terminal_id, company, email, terminals(code, name))")
      .eq("id", user.id)
      .single();
    if (error) throw error;
    return data;
  }

  /* ---------------- Reference data ---------------- */

  async function loadTerminals() {
    const { data, error } = await db.from("terminals").select("*").order("code");
    if (error) throw error;
    return data;
  }

  async function loadOperators(filters = {}) {
    let q = db.from("operators").select("*, terminals(code, name)").order("company");
    if (filters.terminalCode) q = q.eq("terminals.code", filters.terminalCode);
    if (filters.activeOnly) q = q.eq("active", true);
    const { data, error } = await q;
    if (error) throw error;
    return data;
  }

  async function createOperator({ terminalCode, company, email }) {
    const { data: terminal, error: tErr } = await db
      .from("terminals").select("id").eq("code", terminalCode).single();
    if (tErr) throw tErr;
    const { data, error } = await db
      .from("operators")
      .insert({ terminal_id: terminal.id, company, email })
      .select().single();
    if (error) throw error;
    return data;
  }

  async function updateOperator(id, patch) {
    const { data, error } = await db.from("operators").update(patch).eq("id", id).select().single();
    if (error) throw error;
    return data;
  }

  // Creates a REAL Supabase Auth login for an operator (works from any
  // device, unlike the old local-only temp password) via a service-role
  // edge function, and links it to the operator's directory record.
  // Returns { login_email, password } to show the admin once.
  async function provisionOperatorLogin({ operatorId, company, terminalCode, email }) {
    const { data, error } = await db.functions.invoke("create-operator-account", {
      body: { operator_id: operatorId, company, terminal_code: terminalCode, email },
    });
    if (error) {
      // Edge functions return non-2xx as a FunctionsHttpError — try to read the real message.
      let msg = error.message || "Could not create login.";
      try { const body = await error.context.json(); if (body && body.error) msg = body.error; } catch (_) {}
      throw new Error(msg);
    }
    if (data && data.error) throw new Error(data.error);
    return data; // { login_email, password }
  }

  /* ---------------- Admins (multi-admin via profiles) ---------------- */

  async function listAdmins() {
    const { data, error } = await db
      .from("profiles").select("*").eq("role", "admin").order("created_at");
    if (error) throw error;
    return data;
  }

  // Admin accounts are created via Supabase Auth sign-up + an admin profile row.
  // (Requires email confirmation to be handled by Supabase's own flow, or an
  // existing admin approving via the dashboard — no service_role key is used
  // client-side.)
  async function inviteAdmin(email, fullName) {
    const { data, error } = await db.auth.signUp({
      email,
      password: crypto.randomUUID(), // temp — the invitee resets it via email
      options: { data: { full_name: fullName, role: "admin" } }
    });
    if (error) throw error;
    if (data.user) {
      await db.from("profiles").insert({
        id: data.user.id, full_name: fullName, role: "admin", active: true
      });
      await requestPasswordReset(email);
    }
    return data;
  }

  async function setAdminActive(profileId, active) {
    const { data, error } = await db
      .from("profiles").update({ active }).eq("id", profileId).select().single();
    if (error) throw error;
    return data;
  }

  /* ---------------- Settlement entries ---------------- */

  // filters: { terminalCode, operatorId, dateFrom, dateTo, status }
  async function loadEntries(filters = {}) {
    let q = db
      .from("settlement_entries")
      .select("*, terminals(code, name), operators(company, email)")
      .order("entry_date", { ascending: false });
    if (filters.terminalCode) q = q.eq("terminals.code", filters.terminalCode);
    if (filters.operatorId) q = q.eq("operator_id", filters.operatorId);
    if (filters.dateFrom) q = q.gte("entry_date", filters.dateFrom);
    if (filters.dateTo) q = q.lte("entry_date", filters.dateTo);
    if (filters.status) q = q.eq("status", filters.status);
    const { data, error } = await q;
    if (error) throw error;
    return data;
  }

  async function getEntry(terminalCode, company, entryDate) {
    const { data, error } = await db
      .from("settlement_entries")
      .select("*, terminals!inner(code), operators!inner(company)")
      .eq("terminals.code", terminalCode)
      .eq("operators.company", company)
      .eq("entry_date", entryDate)
      .maybeSingle();
    if (error) throw error;
    return data;
  }

  // row: { terminalCode, operatorId, entryDate, sales, stdCharge, manualCharge,
  //        undersales, finalAmount, items, adjustments, note, status }
  async function saveEntry(row) {
    const { data: { user } } = await db.auth.getUser();
    const payload = {
      id: row.id || undefined,
      terminal_id: row.terminalId,
      operator_id: row.operatorId,
      entry_date: row.entryDate,
      sales: Number(row.sales || 0),
      std_charge: Number(row.stdCharge || 0),
      manual_charge: Number(row.manualCharge || 0),
      undersales: Number(row.undersales || 0),
      final_amount: Number(row.finalAmount || 0),
      items: row.items || {},
      adjustments: row.adjustments || [],
      note: row.note || null,
      status: row.status || "draft",
      updated_by: user ? user.id : null
    };
    if (!row.id) payload.created_by = user ? user.id : null;
    const { data, error } = await db
      .from("settlement_entries")
      .upsert(payload, { onConflict: "terminal_id,operator_id,entry_date" })
      .select().single();
    if (error) throw error;
    return data;
  }

  async function setEntryStatus(id, status) {
    const { data: { user } } = await db.auth.getUser();
    const { data, error } = await db
      .from("settlement_entries")
      .update({ status, updated_by: user ? user.id : null })
      .eq("id", id).select().single();
    if (error) throw error;
    return data;
  }

  async function bulkSetStatus(ids, status) {
    const { data: { user } } = await db.auth.getUser();
    const { data, error } = await db
      .from("settlement_entries")
      .update({ status, updated_by: user ? user.id : null })
      .in("id", ids).select();
    if (error) throw error;
    return data;
  }

  async function deleteEntry(id) {
    const { error } = await db.from("settlement_entries").delete().eq("id", id);
    if (error) throw error;
  }

  /* ---------------- Manual invoice + manual trip list ---------------- */

  // filters: { terminalId, operatorId, periodFrom, periodTo }
  async function loadManualInvoices(filters = {}) {
    let q = db
      .from("manual_invoices")
      .select("*, terminals(code, name), operators(company, email, invoice_seq)")
      .order("period_to", { ascending: false });
    if (filters.terminalId) q = q.eq("terminal_id", filters.terminalId);
    if (filters.operatorId) q = q.eq("operator_id", filters.operatorId);
    if (filters.periodFrom) q = q.eq("period_from", filters.periodFrom);
    if (filters.periodTo) q = q.eq("period_to", filters.periodTo);
    const { data, error } = await q;
    if (error) throw error;
    return data;
  }

  async function loadManualTripEntries(invoiceId) {
    const { data, error } = await db
      .from("manual_trip_entries")
      .select("*")
      .eq("invoice_id", invoiceId)
      .order("trip_no");
    if (error) throw error;
    return data;
  }

  // row: { id?, terminalId, operatorId, invoiceNo, invoiceDate, periodFrom, periodTo,
  //        rate, quantity, amount, rounding, grandTotal, status }
  async function saveManualInvoice(row) {
    const { data: { user } } = await db.auth.getUser();
    const payload = {
      id: row.id || undefined,
      terminal_id: row.terminalId,
      operator_id: row.operatorId,
      invoice_no: row.invoiceNo,
      invoice_date: row.invoiceDate,
      period_from: row.periodFrom,
      period_to: row.periodTo,
      rate: Number(row.rate || 0),
      quantity: Number(row.quantity || 0),
      amount: Number(row.amount || 0),
      rounding: Number(row.rounding || 0),
      grand_total: Number(row.grandTotal || 0),
      bill_to_name: row.billToName || null,
      bill_to_address: row.billToAddress || null,
      status: row.status || "draft",
      updated_by: user ? user.id : null
    };
    if (!row.id) payload.created_by = user ? user.id : null;
    const { data, error } = await db
      .from("manual_invoices")
      .upsert(payload, { onConflict: "terminal_id,operator_id,period_from,period_to" })
      .select().single();
    if (error) throw error;
    return data;
  }

  // trips: [{ tripNo, tripDate, enter, exit, plate, destination }]
  async function saveManualTripEntries(invoiceId, trips) {
    const { error: delErr } = await db.from("manual_trip_entries").delete().eq("invoice_id", invoiceId);
    if (delErr) throw delErr;
    if (!trips.length) return [];
    const payload = trips.map(t => ({
      invoice_id: invoiceId,
      trip_no: t.tripNo,
      trip_date: t.tripDate,
      enter_time: t.enter || null,
      exit_time: t.exit || null,
      plate_no: t.plate || null,
      destination: t.destination || null
    }));
    const { data, error } = await db.from("manual_trip_entries").insert(payload).select();
    if (error) throw error;
    return data;
  }

  async function deleteManualInvoice(id) {
    const { error } = await db.from("manual_invoices").delete().eq("id", id);
    if (error) throw error;
  }

  /* ---------------- Realtime ---------------- */

  // onChange(payload) fires on every INSERT/UPDATE/DELETE to settlement_entries,
  // operators, manual_invoices or manual_trip_entries — call this once after
  // login and re-render/reload from it.
  function subscribeToChanges(onChange) {
    return db
      .channel("gostatement-live")
      .on("postgres_changes", { event: "*", schema: "public", table: "settlement_entries" }, onChange)
      .on("postgres_changes", { event: "*", schema: "public", table: "operators" }, onChange)
      .on("postgres_changes", { event: "*", schema: "public", table: "manual_invoices" }, onChange)
      .on("postgres_changes", { event: "*", schema: "public", table: "manual_trip_entries" }, onChange)
      .subscribe();
  }

  function unsubscribe(channel) {
    if (channel) db.removeChannel(channel);
  }

  window.GoStatementLive = {
    db,
    // auth
    signIn, signOut, getSession, getMyProfile,
    requestPasswordReset, completePasswordReset,
    // reference data
    loadTerminals, loadOperators, createOperator, updateOperator, provisionOperatorLogin,
    // admins
    listAdmins, inviteAdmin, setAdminActive,
    // entries
    loadEntries, getEntry, saveEntry, setEntryStatus, bulkSetStatus, deleteEntry,
    // manual invoice + trip list
    loadManualInvoices, loadManualTripEntries, saveManualInvoice, saveManualTripEntries, deleteManualInvoice,
    // realtime
    subscribeToChanges, unsubscribe
  };
})();
