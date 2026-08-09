// app.js — Review & Submit web-app frontend (vanilla JS, no build). Talks to the
// auth-guarded /api/** backend (Chunks 0–5). DOM/network wiring — verified in
// the browser after deploy; the backend logic it calls is unit-tested.
(function () {
  const $ = (id) => document.getElementById(id);
  const STATUSES = ['', 'OK', 'Fixed', 'Archive', 'Question'];
  let nextBatchId = null;

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
    if (!res.ok || json.ok === false) {
      throw new Error(json.message || json.error || ('HTTP ' + res.status));
    }
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

  // --- data ------------------------------------------------------------------
  async function loadConfig() {
    const c = await api('/config');
    nextBatchId = c.nextBatchId;
    $('next-batch').textContent = nextBatchId || '(unset)';
  }

  async function loadQueue() {
    $('status').textContent = 'Loading queue…';
    $('queue').hidden = true;
    try {
      const { rows } = await api('/queue');
      renderQueue(rows || []);
      const assigned = (rows || []).filter((r) => r.rs_batch_id === nextBatchId).length;
      $('assigned-count').textContent = `${assigned} assigned to batch ${nextBatchId} · ${rows.length} in queue`;
      $('status').textContent = rows.length ? '' : 'Queue is empty — no unreviewed annotations.';
      $('queue').hidden = rows.length === 0;
    } catch (e) { err(e); }
  }

  // --- render ----------------------------------------------------------------
  function cell(text) { const td = document.createElement('td'); td.textContent = text == null ? '' : String(text); return td; }
  function flags(r) {
    const f = [];
    if (r.is_deleted_scv) f.push('deleted');
    if (r.is_outdated_scv) f.push('outdated');
    if (!r.is_latest_annotation) f.push('superseded');
    return f.join(', ');
  }

  const ACTIONABLE = ['flagging candidate', 'remove flagged submission'];
  // Per-row control handles, rebuilt on each render. `base` is the SERVER-SAVED
  // status/notes; a row is "dirty" when its live control value differs from base
  // (so an auto-review suggestion prefilled but not yet saved reads as unsaved).
  let rowCtls = [];

  function isDirty(c) { return c.sel.value !== c.base.status || c.note.value !== c.base.notes; }
  function dirtyRows() { return rowCtls.filter(isDirty); }
  function selectedCtls() { return rowCtls.filter((c) => !c.cb.disabled && c.cb.checked); }

  function refreshDirty() {
    let n = 0;
    rowCtls.forEach((c) => { const d = isDirty(c); c.tr.classList.toggle('dirty', d); if (d) n++; });
    $('save-all').disabled = n === 0;
    const u = $('unsaved'); u.hidden = n === 0;
    u.textContent = n ? `${n} unsaved change${n > 1 ? 's' : ''}` : '';
  }
  function refreshSelection() {
    const sel = selectedCtls();
    $('assign-selected').disabled = !sel.some((c) => c.eligible);
    $('unassign-selected').disabled = !sel.some((c) => c.assigned);
    $('selected-count').textContent = sel.length ? `${sel.length} selected` : '';
    const eligibleCbs = rowCtls.filter((c) => !c.cb.disabled);
    $('select-all').checked = eligibleCbs.length > 0 && eligibleCbs.every((c) => c.cb.checked);
  }

  function renderQueue(rows) {
    const tb = $('queue').querySelector('tbody');
    tb.textContent = '';
    rowCtls = [];
    rows.forEach((r) => {
      const tr = document.createElement('tr');
      if (r.fresh) tr.classList.add('fresh');

      const assigned = r.rs_batch_id === nextBatchId;
      const savedOk = r.rs_review_status === 'OK';
      const actionable = ACTIONABLE.includes(String(r.action || '').toLowerCase());
      // Assign gate is on the SAVED status (not the unsaved select) — the backend
      // gate re-checks it anyway, so a status must be Saved before assigning.
      const eligible = !assigned && savedOk && actionable && !r.fresh;
      let reason = '';
      if (!actionable) reason = 'only Flagging Candidate / Remove Flagged Submission can be batched';
      else if (!savedOk) reason = 'set status OK and Save first';
      else if (r.fresh) reason = 'awaiting enrichment — refresh from capture';

      // selection checkbox — enabled when the row can be assigned or unassigned
      const cbTd = document.createElement('td'); cbTd.className = 'sel';
      const cb = document.createElement('input'); cb.type = 'checkbox';
      cb.disabled = !(assigned || eligible);
      if (cb.disabled && reason) cb.title = reason;
      cb.addEventListener('change', refreshSelection);
      cbTd.appendChild(cb); tr.appendChild(cbTd);

      tr.appendChild(cell(`${r.scv_id}.${r.scv_ver}${r.fresh ? '  🆕' : ''}`));
      tr.appendChild(cell(`${r.vcv_id} (var ${r.variation_id})`));
      tr.appendChild(cell(r.submitter_name || r.submitter_id));
      tr.appendChild(cell(r.action));
      tr.appendChild(cell(r.reason));
      tr.appendChild(cell(flags(r)));
      const auto = cell(r.auto_status ? `${r.auto_status}` : 'manual');
      auto.title = r.auto_note || ''; auto.className = 'auto';
      tr.appendChild(auto);

      // status select (prefilled with the saved status, else the auto suggestion)
      const stTd = document.createElement('td');
      const sel = document.createElement('select');
      STATUSES.forEach((s) => { const o = document.createElement('option'); o.value = s; o.textContent = s || '(none)'; sel.appendChild(o); });
      sel.value = r.rs_review_status || r.auto_status || '';
      sel.addEventListener('change', refreshDirty);
      stTd.appendChild(sel); tr.appendChild(stTd);

      // review notes
      const noteTd = document.createElement('td');
      const note = document.createElement('input'); note.type = 'text'; note.value = r.rs_notes || '';
      note.addEventListener('input', refreshDirty);
      noteTd.appendChild(note); tr.appendChild(noteTd);

      // batch status (read-only; assignment is via the checkbox + bulk buttons)
      const batchTd = document.createElement('td');
      if (assigned) { batchTd.textContent = `batch ${nextBatchId}`; batchTd.className = 'assigned'; }
      else if (eligible) { batchTd.textContent = 'eligible'; batchTd.className = 'eligible'; }
      else { batchTd.textContent = '—'; batchTd.title = reason; }
      tr.appendChild(batchTd);

      tb.appendChild(tr);
      rowCtls.push({ r, tr, sel, note, cb, assigned, eligible, base: { status: r.rs_review_status || '', notes: r.rs_notes || '' } });
    });
    refreshDirty();
    refreshSelection();
  }

  // --- batch actions ---------------------------------------------------------
  $('reload').addEventListener('click', () => {
    if (dirtyRows().length && !confirm('Discard unsaved changes and reload?')) return;
    loadQueue();
  });

  // Select-all toggles every enabled checkbox.
  $('select-all').addEventListener('change', (e) => {
    rowCtls.forEach((c) => { if (!c.cb.disabled) c.cb.checked = e.target.checked; });
    refreshSelection();
  });

  // Save all edited rows in ONE request (rows without a status can't persist —
  // cvc_review_state requires one — so they're skipped and reported).
  $('save-all').addEventListener('click', async () => {
    const dirty = dirtyRows();
    const edits = dirty.filter((c) => c.sel.value !== '').map((c) => ({
      annotationId: c.r.annotation_id, scvId: c.r.scv_id, scvVer: c.r.scv_ver, status: c.sel.value, notes: c.note.value
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

  $('assign-selected').addEventListener('click', () => bulkBatch('/assign-bulk', (c) => c.eligible, 'assign'));
  $('unassign-selected').addEventListener('click', () => bulkBatch('/unassign-bulk', (c) => c.assigned, 'unassign'));

  async function bulkBatch(path, pick, verb) {
    if (dirtyRows().length) { $('status').textContent = 'Save your changes first — unsaved edits would be lost on reload.'; return; }
    const ids = selectedCtls().filter(pick).map((c) => c.r.annotation_id);
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

  // Warn before leaving with unsaved status/notes edits.
  window.addEventListener('beforeunload', (e) => {
    if (dirtyRows().length) { e.preventDefault(); e.returnValue = ''; }
  });
  $('generate').addEventListener('click', async () => {
    $('result').textContent = 'Generating…';
    try {
      const out = await api('/generate', 'POST', { batchId: nextBatchId });
      showResult('Generated', out);
    } catch (e) { err(e); }
  });
  $('finalize').addEventListener('click', async () => {
    if (!confirm(`Finalize batch ${nextBatchId}? This persists the batch and advances the batch id.`)) return;
    $('result').textContent = 'Finalizing…';
    try {
      const out = await api('/finalize', 'POST', { batchId: nextBatchId });
      showResult('Finalized', out);
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
})();
