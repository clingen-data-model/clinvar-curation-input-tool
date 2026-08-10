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
      await loadFiles();
    } catch (e) {
      $('whoami').textContent = user.email + ' — not authorized (contact an admin).';
      $('app').hidden = true;
    }
  });

  let releaseStale = false;
  async function loadConfig() {
    const c = await api('/config');
    nextBatchId = c.nextBatchId;
    $('next-batch').textContent = nextBatchId || '(unset)';
    // Staleness: the queue was enriched against an older ClinVar release than
    // clinvar_ingest now has. Show a banner + block Finalize until re-processed.
    releaseStale = !!c.releaseStale;
    $('release-banner').hidden = !releaseStale;
    if (releaseStale) {
      $('release-msg').textContent =
        `⚠ A newer ClinVar release (${c.currentRelease}) is available; the queue reflects ${c.baseReleaseDate || 'an older release'}. Re-process this review cycle before finalizing.`;
    }
    $('finalize').disabled = releaseStale;
    $('finalize').title = releaseStale ? 'Re-process the queue against the current ClinVar release first' : '';
  }

  // --- row shaping -----------------------------------------------------------
  // BQ DATE/TIMESTAMP params come back as { value: '…' }; unwrap to the scalar.
  const bqval = (v) => (v && typeof v === 'object' && 'value' in v) ? v.value : v;
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
      action: r.action, vreason: r.reason,
      // SCV / annotation context columns (from the cvc_annotations TVF via the
      // materialized base). Booleans are true/false for enriched rows, null for
      // fresh (not-yet-enriched) rows → shown blank.
      scv_review: r.clinvar_review_status || '',
      latest_anno: r.is_latest_annotation, outdated_vcv: r.is_outdated_vcv,
      outdated_scv: r.is_outdated_scv, moved: r.is_moved_scv, deleted: r.is_deleted_scv,
      deleted_rel: bqval(r.deleted_scv_release_date) || '',
      latest_scv_ver: r.latest_scv_ver == null ? '' : r.latest_scv_ver,
      latest_scv_classif: r.latest_scv_classification || '',
      prior_ver: r.has_prior_scv_ver_annotation, prior_submitted: r.has_prior_submission_batch_id,
      prior_any: r.has_prior_scv_id_annotation,   // drives the Phase B history affordance
      auto: r.auto_status || 'manual', auto_status: r.auto_status || '', auto_note: r.auto_note || '',
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
  let headerSelBox = null;
  function refreshSelection() {
    const sel = table ? table.getSelectedData() : [];
    $('assign-selected').disabled = !sel.some((d) => d._eligible);
    $('unassign-selected').disabled = !sel.some((d) => d._assigned);
    $('apply-status').disabled = sel.length === 0;
    $('selected-count').textContent = sel.length ? `${sel.length} selected` : '';
    if (headerSelBox && table) {
      const active = table.getRows('active');
      headerSelBox.checked = active.length > 0 && active.every((r) => r.isSelected());
    }
  }
  // A filter-aware "select all VISIBLE rows" header checkbox. Acts only on the
  // active (filtered) rows; `boxRef` hands the element back so its checked state
  // can be kept in sync. Shared by the review + reflag grids.
  function selectionColumn(getTable, boxRef) {
    return {
      formatter: 'rowSelection', hozAlign: 'center', headerSort: false, width: 42,
      titleFormatter: function () {
        const box = document.createElement('input');
        box.type = 'checkbox'; box.title = 'Select all VISIBLE (filtered) rows';
        box.addEventListener('click', (e) => e.stopPropagation());
        box.addEventListener('change', () => {
          getTable().getRows('active').forEach((r) => (box.checked ? r.select() : r.deselect()));
        });
        boxRef(box);
        return box;
      }
    };
  }
  // Deselect any rows hidden by a filter change, so bulk actions never touch a
  // record the curator can't currently see.
  function deselectHidden(tbl, visibleRows, refreshFn) {
    const active = new Set(visibleRows.map((r) => r.getData().id));
    tbl.getSelectedRows().forEach((r) => { if (!active.has(r.getData().id)) r.deselect(); });
    refreshFn();
  }

  // --- Tabulator grid --------------------------------------------------------
  // Compact boolean flag column: tick when true, blank when false/null (fresh).
  const boolCol = (title, field, tip) => ({
    title, field, width: 62, hozAlign: 'center', headerTooltip: tip,
    formatter: 'tickCross', formatterParams: { crossElement: false, allowTruthy: true }
  });
  const COLUMNS = [
    selectionColumn(() => table, (b) => { headerSelBox = b; }),
    // Workflow-editing columns first (right after the checkbox) …
    { title: 'Status', field: 'status', width: 120, editor: 'list', editorParams: { values: STATUS_VALUES }, headerFilter: 'list', headerFilterParams: { values: STATUS_VALUES } },
    { title: 'Review notes', field: 'notes', width: 220, editor: 'input' },
    { title: 'Auto', field: 'auto', width: 90, tooltip: (e, cell) => cell.getData().auto_note || '' },
    { title: 'Batch', field: 'batch', width: 100, tooltip: (e, cell) => cell.getData().batch_reason || '' },
    // … then the SCV + context columns.
    { title: 'SCV', field: 'scv', width: 140, headerFilter: 'input' },
    { title: 'Variant', field: 'variant', headerFilter: 'input' },
    { title: 'Submitter', field: 'submitter', headerFilter: 'input' },
    { title: 'Action', field: 'action', width: 170, headerFilter: 'input' },
    { title: 'Reason', field: 'vreason', headerFilter: 'input' },
    { title: 'SCV rev status', field: 'scv_review', width: 130, headerFilter: 'input', headerTooltip: 'ClinVar review status of the SCV at annotation time' },
    boolCol('latest anno', 'latest_anno', 'This is the latest annotation for the SCV (blank = superseded)'),
    boolCol('outdated vcv', 'outdated_vcv', 'A newer VCV version exists than at annotation time'),
    boolCol('outdated scv', 'outdated_scv', 'A newer SCV version exists (or the SCV moved variation)'),
    boolCol('moved', 'moved', 'The SCV moved to a different variation'),
    boolCol('deleted', 'deleted', 'The SCV was deleted on/before the annotation release'),
    { title: 'deleted rel date', field: 'deleted_rel', width: 120, headerTooltip: 'Release date the SCV was deleted' },
    { title: 'latest scv ver', field: 'latest_scv_ver', width: 100, hozAlign: 'right', headerTooltip: 'Latest SCV version now' },
    { title: 'latest scv classif', field: 'latest_scv_classif', width: 150, headerFilter: 'input', headerTooltip: 'Latest SCV classification now (compare to the annotated classification)' },
    boolCol('prior same ver', 'prior_ver', 'A prior CvC annotation exists for this exact SCV version'),
    boolCol('prior submitted', 'prior_submitted', 'A prior CvC annotation for this SCV was submitted in a batch'),
    { title: 'Prior hist', field: 'prior_any', width: 96, hozAlign: 'center', headerSort: false,
      headerTooltip: 'Hover to see prior CvC annotations for this SCV',
      formatter: (cell) => (cell.getValue() ? '<span class="hist-link">history ▸</span>' : ''),
      cellMouseEnter: (e, cell) => { if (cell.getData().prior_any) showHistPop(cell); },
      cellMouseLeave: () => scheduleHideHistPop() }
  ];
  function rowFormatter(row) {
    const d = row.getData(); const el = row.getElement();
    el.classList.toggle('fresh', !!d._fresh);
    el.classList.toggle('dirty', isDirty(d));
  }

  // --- prior-annotations history popover -------------------------------------
  // Format one prior annotation like the legacy sheet:
  //   scv-ver  anno-date (curator) action reason [ rev-status (reviewer) *batch-id* ]
  function fmtHistLine(h) {
    const ver = h.scv_ver == null ? '' : h.scv_ver;
    const date = bqval(h.annotated_date) || '';
    const rev = h.review_status
      ? ` [ ${h.review_status}${h.reviewer ? ' (' + h.reviewer + ')' : ''}${h.batch_id ? ' *' + h.batch_id + '*' : ''} ]`
      : '';
    return `.${ver}\t${date} (${h.curator || ''}) ${h.action || ''} ${h.reason || ''}${rev}`;
  }
  // Hover popover (like the extension's CvC badge). Fetches once per SCV (cached),
  // positions near the hovered cell, and stays open while the mouse is over it.
  const histCache = {};
  let histHideTimer = null;
  const escapeHtml = (s) => String(s).replace(/[&<>]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;' }[c]));
  function scheduleHideHistPop() { clearTimeout(histHideTimer); histHideTimer = setTimeout(() => { $('hist-pop').hidden = true; }, 200); }
  async function showHistPop(cell) {
    clearTimeout(histHideTimer);
    const d = cell.getData();
    const pop = $('hist-pop');
    const rect = cell.getElement().getBoundingClientRect();
    const maxLeft = window.scrollX + document.documentElement.clientWidth - 660;
    pop.style.left = Math.max(8, Math.min(rect.left + window.scrollX, maxLeft)) + 'px';
    pop.style.top = (rect.bottom + window.scrollY + 4) + 'px';
    pop.hidden = false;
    pop.innerHTML = `<div class="hist-hd">Prior annotations — ${escapeHtml(d.scv_id)}</div><pre>Loading…</pre>`;
    try {
      let rows = histCache[d.scv_id];
      if (!rows) { const r = await api('/scv-history?scvId=' + encodeURIComponent(d.scv_id)); rows = r.rows || []; histCache[d.scv_id] = rows; }
      if (pop.hidden) return; // moved away before it loaded
      const body = rows.length ? rows.map(fmtHistLine).join('\n') : 'No prior annotations found.';
      pop.innerHTML = `<div class="hist-hd">Prior annotations — ${escapeHtml(d.scv_id)} (${rows.length})</div><pre>${escapeHtml(body)}</pre>`;
    } catch (e) { pop.innerHTML = `<pre>Error: ${escapeHtml(e && e.message ? e.message : String(e))}</pre>`; }
  }
  $('hist-pop').addEventListener('mouseenter', () => clearTimeout(histHideTimer));
  $('hist-pop').addEventListener('mouseleave', scheduleHideHistPop);
  // Build once, then replaceData on reload (returns a promise resolved when ready).
  function loadIntoTable(data) {
    return new Promise((resolve) => {
      if (table) { table.replaceData(data).then(() => resolve()); return; }
      table = new Tabulator('#queue', {
        index: 'id', layout: 'fitDataFill', height: '64vh', data,
        placeholder: 'Queue is empty — no unreviewed annotations.',
        selectableRows: true, // every row selectable (bulk status can touch any row)
        columns: COLUMNS, rowFormatter
      });
      // reformat re-runs rowFormatter so the dirty tint tracks the edit
      table.on('cellEdited', (cell) => { cell.getRow().reformat(); refreshDirty(); });
      table.on('rowSelectionChanged', () => refreshSelection());
      table.on('dataFiltered', (filters, rows) => deselectHidden(table, rows, refreshSelection));
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

  // Re-process: re-enrich the queue against the current ClinVar release, then reload.
  $('reprocess').addEventListener('click', async () => {
    const btn = $('reprocess'); btn.disabled = true; btn.textContent = 'Re-processing…';
    $('status').textContent = 'Re-processing the review cycle against the current ClinVar release…';
    try {
      await api('/reprocess', 'POST', {});
      $('status').textContent = 'Re-processed — queue now reflects the current release.';
      await loadConfig(); await loadQueue(); await loadFiles();
    } catch (e) { err(e); } finally { btn.disabled = false; btn.textContent = 'Re-process now'; }
  });

  // --- generated files panel -------------------------------------------------
  async function loadFiles() {
    if (!nextBatchId) return;
    try {
      const { files } = await api('/files?batchId=' + encodeURIComponent(nextBatchId));
      renderFiles(files || []);
    } catch (e) { /* best-effort — Drive may be unconfigured in some envs */ }
  }
  function renderFiles(files) {
    const ul = $('files-list'); ul.textContent = '';
    $('files-hint').textContent = files.length ? '' : '— none generated for this batch yet';
    files.forEach((f) => {
      const li = document.createElement('li');
      const a = document.createElement('a'); a.href = f.link; a.target = '_blank'; a.textContent = f.name;
      li.appendChild(a);
      if (f.protected) {
        const lock = document.createElement('span'); lock.className = 'lock'; lock.textContent = '🔒 finalized';
        li.appendChild(lock);
      } else {
        const del = document.createElement('button'); del.className = 'secondary del-file'; del.textContent = 'Delete';
        del.addEventListener('click', async () => {
          if (!confirm(`Delete generated file "${f.name}"? (moves it to Drive trash)`)) return;
          del.disabled = true;
          try { await api('/files/delete', 'POST', { fileId: f.id }); await loadFiles(); }
          catch (e) { del.disabled = false; err(e); }
        });
        li.appendChild(del);
      }
      ul.appendChild(li);
    });
  }

  // --- actions ---------------------------------------------------------------
  $('reload').addEventListener('click', () => {
    if (currentDirty().length && !confirm('Discard unsaved changes and reload?')) return;
    loadQueue();
  });

  // Save every edited row in ONE request. A row whose status was set back to
  // (none) is sent with an empty status → the backend clears its review (back to
  // unreviewed); all other edits upsert.
  $('save-all').addEventListener('click', async () => {
    const dirty = currentDirty();
    if (!dirty.length) { $('status').textContent = 'Nothing to save.'; return; }
    const edits = dirty.map((d) => ({
      annotationId: d.annotation_id, scvId: d.scv_id, scvVer: d.scv_ver, status: d.status, notes: d.notes
    }));
    $('save-all').disabled = true; $('status').textContent = `Saving ${edits.length}…`;
    try {
      const out = await api('/review-bulk', 'POST', { edits });
      const cleared = out.cleared || 0;
      $('status').textContent = `Saved ${edits.length} change${edits.length === 1 ? '' : 's'}`
        + (cleared ? ` (incl. ${cleared} cleared to none)` : '');
      await loadQueue();
    } catch (e) { err(e); refreshDirty(); }
  });

  // Fill blank Status cells with their auto-review suggestion (visible/filtered
  // rows only), as real edits — the reviewer adjusts if needed, then Save all.
  // Never clobbers a status the reviewer already set/saved.
  $('apply-auto').addEventListener('click', () => {
    if (!table) return;
    let n = 0;
    table.getRows('active').forEach((row) => {
      const d = row.getData();
      if (d.status === '' && STATUS_VALUES[d.auto_status] && d.auto_status !== '') {
        row.update({ status: d.auto_status }); row.reformat(); n++;
      }
    });
    refreshDirty();
    $('status').textContent = n
      ? `Applied ${n} auto-review suggestion${n > 1 ? 's' : ''} — review, then Save all.`
      : 'No blank rows have an auto-review suggestion to apply.';
  });

  // Set a status on every SELECTED (visible) row at once — a real edit, so the
  // unsaved count updates and Save all persists it.
  $('apply-status').addEventListener('click', () => {
    if (!table) return;
    const v = $('bulk-status').value;
    const sel = table.getSelectedRows();
    if (!sel.length) { $('status').textContent = 'Select rows first (check boxes or the header Select-all).'; return; }
    sel.forEach((r) => { r.update({ status: v }); r.reformat(); });
    refreshDirty();
    $('status').textContent = `Set status "${v || '(none)'}" on ${sel.length} row(s) — review, then Save all.`;
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
    try {
      showResult('Generated', await api('/generate', 'POST', { batchId: nextBatchId }));
      await loadFiles(); // the new draft appears in the persistent list
    } catch (e) { err(e); }
  });
  $('finalize').addEventListener('click', async () => {
    if (!confirm(`Finalize batch ${nextBatchId}? This persists the batch and advances the batch id.`)) return;
    const finalizedBatch = nextBatchId; // capture before loadConfig advances it
    $('result').textContent = 'Finalizing…';
    try {
      const out = await api('/finalize', 'POST', { batchId: nextBatchId });
      showResult('Finalized', out);
      if (out.finalized) addCleanupButton(finalizedBatch, out.filename);
      await loadConfig(); await loadQueue(); await loadFiles();
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
  // Offered after a successful finalize: once the finalized file + email are done,
  // remove the batch's remaining DRAFT files (the finalized file is kept).
  function addCleanupButton(batchId, finalizedName) {
    const wrap = document.createElement('div'); wrap.style.marginTop = '.4rem';
    const btn = document.createElement('button'); btn.className = 'secondary';
    btn.textContent = `Remove draft files for batch ${batchId}`;
    btn.title = `Trashes every generated file for batch ${batchId} except the finalized ${finalizedName || 'file'}`;
    btn.addEventListener('click', async () => {
      if (!confirm(`Remove all DRAFT generated files for batch ${batchId}? The finalized file is kept. (Do this after the submission email is sent.)`)) return;
      btn.disabled = true;
      try {
        const o = await api('/files/delete-drafts', 'POST', { batchId });
        btn.textContent = `Removed ${o.removed} draft file(s); kept ${o.kept}.`;
        await loadFiles();
      } catch (e) { btn.disabled = false; err(e); }
    });
    wrap.appendChild(btn); $('result').appendChild(wrap);
  }

  // Warn before leaving with unsaved status/notes edits.
  window.addEventListener('beforeunload', (e) => {
    if (currentDirty().length) { e.preventDefault(); e.returnValue = ''; }
  });

  // --- Reflag view -----------------------------------------------------------
  let reflagTable = null;
  const dv = (v) => (v && typeof v === 'object' && 'value' in v) ? v.value : v;

  $('nav-review').addEventListener('click', () => showView('review'));
  $('nav-reflag').addEventListener('click', () => showView('reflag'));
  function showView(which) {
    const reflag = which === 'reflag';
    $('view-review').hidden = reflag;
    $('view-reflag').hidden = !reflag;
    $('nav-review').classList.toggle('active', !reflag);
    $('nav-reflag').classList.toggle('active', reflag);
    if (reflag && !reflagTable) loadReflagCandidates();
  }

  let reflagHeaderSelBox = null;
  const REFLAG_COLUMNS = [
    selectionColumn(() => reflagTable, (b) => { reflagHeaderSelBox = b; }),
    { title: '', field: 'is_autoreflag', width: 90, hozAlign: 'center', headerSort: true,
      formatter: (cell) => cell.getValue() ? '<span class="badge-auto">autoreflag</span>' : '' },
    { title: 'SCV', field: 'scv_disp', width: 150, headerFilter: 'input', frozen: true },
    { title: 'Submitter (lab)', field: 'submitter_name', headerFilter: 'input' },
    { title: 'Variant', field: 'variant', headerFilter: 'input' },
    { title: 'Original flag reason', field: 'flagging_reason', widthGrow: 2, headerFilter: 'input' },
    { title: 'Current classification', field: 'current_classification', width: 160, headerFilter: 'input' },
    { title: 'Outcome', field: 'outcome', width: 150, headerFilter: 'input' },
    { title: 'Orig batch', field: 'orig_batch_id', width: 90 },
    { title: 'Bumps', field: 'version_bump_count', width: 74, hozAlign: 'right', headerTooltip: 'Version bumps since the flag was submitted' },
    { title: 'reclassified', field: 'was_reclassified', width: 90, hozAlign: 'center',
      formatter: 'tickCross', formatterParams: { crossElement: false, allowTruthy: true }, headerTooltip: 'Did any substantive field change since the flag?' },
    { title: 'already reflagged', field: 'already_reflagged', width: 110, hozAlign: 'center',
      formatter: 'tickCross', formatterParams: { crossElement: false, allowTruthy: true }, headerTooltip: 'A current-version Flagging Candidate is already captured' }
  ];
  function toReflagRow(c) {
    return {
      id: c.scv_id, scv_id: c.scv_id,
      scv_disp: `${c.scv_id}.${dv(c.current_scv_ver)}`,
      submitter_name: c.submitter_name,
      variant: `${c.vcv_id} (var ${c.variation_id})`,
      flagging_reason: c.flagging_reason, current_classification: c.current_classification,
      outcome: c.outcome, orig_batch_id: c.orig_batch_id, version_bump_count: dv(c.version_bump_count),
      is_autoreflag: !!c.is_autoreflag, was_reclassified: !!c.was_reclassified,
      already_reflagged: !!c.already_reflagged, _already: !!c.already_reflagged
    };
  }
  function refreshReflagSelection() {
    const sel = reflagTable ? reflagTable.getSelectedData() : [];
    $('reflag-selected').disabled = sel.length === 0;
    $('reflag-selected-count').textContent = sel.length ? `${sel.length} selected` : '';
    if (reflagHeaderSelBox && reflagTable) {
      const active = reflagTable.getRows('active').filter((r) => !r.getData()._already);
      reflagHeaderSelBox.checked = active.length > 0 && active.every((r) => r.isSelected());
    }
  }
  async function loadReflagCandidates() {
    $('reflag-status').textContent = 'Loading candidates…';
    try {
      const { candidates } = await api('/reflag-candidates');
      const data = (candidates || []).map(toReflagRow);
      if (!reflagTable) {
        reflagTable = new Tabulator('#reflag-queue', {
          index: 'id', layout: 'fitDataFill', height: '64vh', data,
          placeholder: 'No reflag candidates.',
          // already-reflagged rows can't be selected (dedup would skip them anyway)
          selectableRows: true, selectableRowsCheck: (row) => !row.getData()._already,
          columns: REFLAG_COLUMNS,
          rowFormatter: (row) => row.getElement().classList.toggle('done', !!row.getData()._already)
        });
        reflagTable.on('rowSelectionChanged', refreshReflagSelection);
        reflagTable.on('dataFiltered', (filters, rows) => deselectHidden(reflagTable, rows, refreshReflagSelection));
        reflagTable.on('tableBuilt', () => { refreshReflagSelection(); });
      } else {
        await reflagTable.replaceData(data);
      }
      const auto = data.filter((d) => d.is_autoreflag).length;
      $('reflag-status').textContent = `${data.length} candidate(s) · ${auto} autoreflag · ${data.filter((d) => d._already).length} already reflagged`;
    } catch (e) { $('reflag-status').textContent = 'Error: ' + (e && e.message ? e.message : e); }
  }
  $('reflag-reload').addEventListener('click', loadReflagCandidates);
  $('reflag-selected').addEventListener('click', async () => {
    const sel = reflagTable.getSelectedData().filter((d) => !d._already);
    if (!sel.length) return;
    if (!confirm(`Reflag ${sel.length} SCV(s)? Each becomes a new Flagging Candidate at its current version and enters the review queue.`)) return;
    $('reflag-selected').disabled = true; $('reflag-status').textContent = `Reflagging ${sel.length}…`;
    try {
      const out = await api('/reflag', 'POST', { scvIds: sel.map((d) => d.scv_id) });
      $('reflag-status').textContent = `Reflagged ${out.created}`
        + (out.skipped ? ` · ${out.skipped} skipped (already reflagged)` : '')
        + ' — they enrich into the review queue shortly.';
      await loadReflagCandidates();
    } catch (e) { $('reflag-status').textContent = 'Error: ' + (e && e.message ? e.message : e); refreshReflagSelection(); }
  });
})();
