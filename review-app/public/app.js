// app.js — Review & Submit web-app frontend (vanilla JS + Tabulator grid + Pico
// base CSS; still NO build step — both libs load from a CDN). Talks to the
// auth-guarded /api/** backend. DOM/network wiring is verified in the browser
// after deploy; the backend logic it calls is unit-tested.
(function () {
  const $ = (id) => document.getElementById(id);
  const STATUS_VALUES = { '': '(none)', OK: 'OK', Fixed: 'Fixed', Archive: 'Archive', Question: 'Question' };
  const ACTIONABLE = ['flagging candidate', 'remove flagged submission'];
  let nextBatchId = null;
  let table = null;
  let baseline = {}; // annotation_id -> { status, notes } as last SAVED (server) values

  // DEV banner unless pointed at the prod Firebase project.
  try {
    if (((firebase.app().options || {}).projectId) !== 'clingen-cvc') $('dev-banner').hidden = false;
  } catch (e) { /* init.js absent in local preview */ }

  // --- auth + api helper -----------------------------------------------------
  const provider = new firebase.auth.GoogleAuthProvider();
  $('signin').addEventListener('click', () => firebase.auth().signInWithPopup(provider).catch(err));
  $('signout').addEventListener('click', () => firebase.auth().signOut());

  async function api(path, method, body) {
    const user = firebase.auth().currentUser;
    const token = await user.getIdToken();
    const res = await fetch('/api' + path, {
      method: method || 'GET',
      headers: { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json' },
      body: body ? JSON.stringify(body) : undefined
    });
    const json = await res.json().catch(() => ({}));
    if (!res.ok || json.ok === false) throw new Error(json.message || json.error || ('HTTP ' + res.status));
    return json;
  }
  function err(e) { $('status').textContent = 'Error: ' + (e && e.message ? e.message : e); }

  firebase.auth().onAuthStateChanged(async (user) => {
    $('signin').hidden = !!user; $('signout').hidden = !user;
    $('app').hidden = !user;
    if (!user) { $('whoami').textContent = 'Not signed in.'; return; }
    $('whoami').textContent = user.email;
    try {
      await api('/whoami');            // 403 here if not allow-listed
      await loadConfig();
      await loadQueue();
    } catch (e) {
      $('whoami').textContent = user.email + ' — not authorized (contact an admin).';
      $('app').hidden = true;
    }
  });

  async function loadConfig() {
    const c = await api('/config');
    nextBatchId = c.nextBatchId;
    $('next-batch').textContent = nextBatchId || '(unset)';
  }

  // --- row shaping -----------------------------------------------------------
  function flags(r) {
    const f = [];
    if (r.is_deleted_scv) f.push('deleted');
    if (r.is_outdated_scv) f.push('outdated');
    if (!r.is_latest_annotation) f.push('superseded');
    return f.join(', ');
  }
  // Map a queue row to the grid's row object + derived assign/select flags.
  // Eligibility is on the SAVED status (rs_review_status), not the editable
  // `status` cell — the backend gate re-checks it, so a status must be Saved
  // before a row can be added to a batch.
  function toRowData(r) {
    const assigned = r.rs_batch_id != null && String(r.rs_batch_id) === String(nextBatchId);
    const savedOk = r.rs_review_status === 'OK';
    const actionable = ACTIONABLE.includes(String(r.action || '').toLowerCase());
    const eligible = !assigned && savedOk && actionable && !r.fresh;
    let reason = '';
    if (!actionable) reason = 'only Flagging Candidate / Remove Flagged Submission can be batched';
    else if (!savedOk) reason = 'set status OK and Save first';
    else if (r.fresh) reason = 'awaiting enrichment — refresh from capture';
    return {
      id: r.annotation_id, annotation_id: r.annotation_id, scv_id: r.scv_id, scv_ver: r.scv_ver,
      scv: `${r.scv_id}.${r.scv_ver}${r.fresh ? ' 🆕' : ''}`,
      variant: `${r.vcv_id} (var ${r.variation_id})`,
      submitter: r.submitter_name || r.submitter_id,
      action: r.action, vreason: r.reason, flags: flags(r),
      auto: r.auto_status || 'manual', auto_note: r.auto_note || '',
      // Prefill the editable Status with the SAVED status only (blank if
      // unreviewed) so it matches `baseline` and a row is "dirty" only after a
      // real edit. The auto-review suggestion stays visible in the Auto column;
      // it is NOT written into the Status cell (that would make every suggested
      // row look permanently unsaved and would block the bulk batch buttons).
      status: r.rs_review_status || '',
      notes: r.rs_notes || '',
      batch: assigned ? `batch ${nextBatchId}` : (eligible ? 'eligible' : '—'),
      batch_reason: assigned ? '' : reason,
      _assigned: assigned, _eligible: eligible, _selectable: assigned || eligible, _fresh: !!r.fresh
    };
  }
  function isDirty(d) { const b = baseline[d.id]; return !!b && (d.status !== b.status || d.notes !== b.notes); }
  function currentDirty() { return table ? table.getData().filter(isDirty) : []; }

  // --- toolbar state ---------------------------------------------------------
  function refreshDirty() {
    const n = currentDirty().length;
    $('save-all').disabled = n === 0;
    const u = $('unsaved'); u.hidden = n === 0;
    u.textContent = n ? `${n} unsaved change${n > 1 ? 's' : ''}` : '';
  }
  function refreshSelection() {
    const sel = table ? table.getSelectedData() : [];
    $('assign-selected').disabled = !sel.some((d) => d._eligible);
    $('unassign-selected').disabled = !sel.some((d) => d._assigned);
    $('selected-count').textContent = sel.length ? `${sel.length} selected` : '';
  }

  // --- Tabulator grid --------------------------------------------------------
  const COLUMNS = [
    { formatter: 'rowSelection', titleFormatter: 'rowSelection', hozAlign: 'center', headerSort: false, width: 42 },
    { title: 'SCV', field: 'scv', width: 140, headerFilter: 'input' },
    { title: 'Variant', field: 'variant', headerFilter: 'input' },
    { title: 'Submitter', field: 'submitter', headerFilter: 'input' },
    { title: 'Action', field: 'action', width: 170, headerFilter: 'input' },
    { title: 'Reason', field: 'vreason', headerFilter: 'input' },
    { title: 'Flags', field: 'flags', width: 110, headerFilter: 'input' },
    { title: 'Auto', field: 'auto', width: 90, tooltip: (e, cell) => cell.getData().auto_note || '' },
    { title: 'Status', field: 'status', width: 120, editor: 'list', editorParams: { values: STATUS_VALUES }, headerFilter: 'list', headerFilterParams: { values: STATUS_VALUES } },
    { title: 'Review notes', field: 'notes', widthGrow: 2, editor: 'input' },
    { title: 'Batch', field: 'batch', width: 100, tooltip: (e, cell) => cell.getData().batch_reason || '' }
  ];
  function rowFormatter(row) {
    const d = row.getData(); const el = row.getElement();
    el.classList.toggle('fresh', !!d._fresh);
    el.classList.toggle('dirty', isDirty(d));
  }
  // Build once, then replaceData on reload (returns a promise resolved when ready).
  function loadIntoTable(data) {
    return new Promise((resolve) => {
      if (table) { table.replaceData(data).then(() => resolve()); return; }
      table = new Tabulator('#queue', {
        index: 'id', layout: 'fitColumns', height: '64vh', data,
        placeholder: 'Queue is empty — no unreviewed annotations.',
        selectableRows: true, selectableRowsCheck: (row) => row.getData()._selectable,
        columns: COLUMNS, rowFormatter
      });
      // reformat re-runs rowFormatter so the dirty tint tracks the edit
      table.on('cellEdited', (cell) => { cell.getRow().reformat(); refreshDirty(); });
      table.on('rowSelectionChanged', () => refreshSelection());
      table.on('tableBuilt', () => resolve());
    });
  }

  async function loadQueue() {
    $('status').textContent = 'Loading queue…';
    try {
      const { rows } = await api('/queue');
      baseline = {};
      rows.forEach((r) => { baseline[r.annotation_id] = { status: r.rs_review_status || '', notes: r.rs_notes || '' }; });
      const data = rows.map(toRowData);
      $('queue').hidden = false;
      await loadIntoTable(data);
      refreshDirty(); refreshSelection();
      const assigned = data.filter((d) => d._assigned).length;
      $('assigned-count').textContent = `${assigned} assigned to batch ${nextBatchId} · ${rows.length} in queue`;
      $('status').textContent = rows.length ? '' : 'Queue is empty — no unreviewed annotations.';
    } catch (e) { err(e); }
  }

  // --- actions ---------------------------------------------------------------
  $('reload').addEventListener('click', () => {
    if (currentDirty().length && !confirm('Discard unsaved changes and reload?')) return;
    loadQueue();
  });

  // Save every edited row in ONE request (rows without a status can't persist —
  // cvc_review_state requires one — so they're skipped and reported).
  $('save-all').addEventListener('click', async () => {
    const dirty = currentDirty();
    const edits = dirty.filter((d) => d.status !== '').map((d) => ({
      annotationId: d.annotation_id, scvId: d.scv_id, scvVer: d.scv_ver, status: d.status, notes: d.notes
    }));
    if (!edits.length) { $('status').textContent = 'Nothing to save — set a status first.'; return; }
    $('save-all').disabled = true; $('status').textContent = `Saving ${edits.length}…`;
    try {
      const out = await api('/review-bulk', 'POST', { edits });
      const skipped = dirty.length - edits.length;
      $('status').textContent = `Saved ${out.applied} review${out.applied === 1 ? '' : 's'}`
        + (skipped ? ` · ${skipped} skipped (need a status)` : '');
      await loadQueue();
    } catch (e) { err(e); refreshDirty(); }
  });

  $('assign-selected').addEventListener('click', () => bulkBatch('/assign-bulk', (d) => d._eligible, 'assign'));
  $('unassign-selected').addEventListener('click', () => bulkBatch('/unassign-bulk', (d) => d._assigned, 'unassign'));
  async function bulkBatch(path, pick, verb) {
    if (currentDirty().length) { $('status').textContent = 'Save your changes first — unsaved edits would be lost on reload.'; return; }
    const ids = table.getSelectedData().filter(pick).map((d) => d.annotation_id);
    if (!ids.length) { $('status').textContent = `None of the selected rows can be ${verb === 'assign' ? 'added' : 'unassigned'}.`; return; }
    $('assign-selected').disabled = $('unassign-selected').disabled = true;
    $('status').textContent = `${verb === 'assign' ? 'Adding' : 'Unassigning'} ${ids.length}…`;
    try {
      const out = await api(path, 'POST', { annotationIds: ids, batchId: nextBatchId });
      const failed = (out.requested || ids.length) - (out.applied || 0);
      $('status').textContent = `${verb === 'assign' ? 'Added' : 'Unassigned'} ${out.applied}`
        + (failed > 0 ? ` · ${failed} skipped (not eligible)` : '');
      await loadQueue();
    } catch (e) { err(e); refreshSelection(); }
  }

  $('generate').addEventListener('click', async () => {
    $('result').textContent = 'Generating…';
    try { showResult('Generated', await api('/generate', 'POST', { batchId: nextBatchId })); }
    catch (e) { err(e); }
  });
  $('finalize').addEventListener('click', async () => {
    if (!confirm(`Finalize batch ${nextBatchId}? This persists the batch and advances the batch id.`)) return;
    $('result').textContent = 'Finalizing…';
    try {
      showResult('Finalized', await api('/finalize', 'POST', { batchId: nextBatchId }));
      await loadConfig(); await loadQueue();
    } catch (e) { err(e); }
  });
  function showResult(label, out) {
    const r = $('result'); r.textContent = '';
    if (!out.count) { r.textContent = `${label}: nothing to submit (0 annotations).`; return; }
    const line = document.createElement('div');
    line.textContent = `${label}: ${out.count} annotation(s)` + (out.warnings && out.warnings.needsReview ? ` · ${out.warnings.needsReview} still need review` : '');
    r.appendChild(line);
    if (out.link) { const a = document.createElement('a'); a.href = out.link; a.textContent = out.filename || 'submission file'; a.target = '_blank'; r.appendChild(a); }
    if (out.mailto) { const m = document.createElement('a'); m.href = out.mailto; m.textContent = ' — draft submission email'; r.appendChild(m); }
  }

  // Warn before leaving with unsaved status/notes edits.
  window.addEventListener('beforeunload', (e) => {
    if (currentDirty().length) { e.preventDefault(); e.returnValue = ''; }
  });
})();
