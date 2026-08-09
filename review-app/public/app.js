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

  function renderQueue(rows) {
    const tb = $('queue').querySelector('tbody');
    tb.textContent = '';
    rows.forEach((r) => {
      const tr = document.createElement('tr');
      if (r.fresh) tr.classList.add('fresh');
      tr.appendChild(cell(`${r.scv_id}.${r.scv_ver}${r.fresh ? '  🆕' : ''}`));
      tr.appendChild(cell(`${r.vcv_id} (var ${r.variation_id})`));
      tr.appendChild(cell(r.submitter_name || r.submitter_id));
      tr.appendChild(cell(r.action));
      tr.appendChild(cell(r.reason));
      tr.appendChild(cell(flags(r)));
      const auto = cell(r.auto_status ? `${r.auto_status}` : 'manual');
      auto.title = r.auto_note || ''; auto.className = 'auto';
      tr.appendChild(auto);

      // status select (prefilled with the current review status, else the suggestion)
      const stTd = document.createElement('td');
      const sel = document.createElement('select');
      STATUSES.forEach((s) => { const o = document.createElement('option'); o.value = s; o.textContent = s || '(none)'; sel.appendChild(o); });
      sel.value = r.rs_review_status || r.auto_status || '';
      stTd.appendChild(sel); tr.appendChild(stTd);

      // review notes
      const noteTd = document.createElement('td');
      const note = document.createElement('input'); note.type = 'text'; note.value = r.rs_notes || '';
      noteTd.appendChild(note); tr.appendChild(noteTd);

      // Save (review)
      const saveTd = document.createElement('td');
      const save = document.createElement('button'); save.textContent = 'Save';
      save.addEventListener('click', async () => {
        save.disabled = true;
        try {
          await api('/review', 'POST', { annotationId: r.annotation_id, scvId: r.scv_id, scvVer: r.scv_ver, status: sel.value, notes: note.value });
          save.textContent = 'Saved';
          await loadQueue(); // reflect the saved status + refresh assign eligibility
        } catch (e) { save.textContent = 'Save'; err(e); } finally { save.disabled = false; }
      });
      saveTd.appendChild(save); tr.appendChild(saveTd);

      // Assign / Unassign to next batch. Only OK + flag/remove + enriched rows
      // are assignable; otherwise the button is disabled with the reason, so the
      // rule is visible (and there's no silent backend refusal).
      const batchTd = document.createElement('td');
      const assigned = r.rs_batch_id === nextBatchId;
      const ACTIONABLE = ['flagging candidate', 'remove flagged submission'];
      const savedOk = r.rs_review_status === 'OK';
      const actionable = ACTIONABLE.includes(String(r.action || '').toLowerCase());
      const btn = document.createElement('button');
      if (assigned) {
        btn.textContent = 'Unassign';
        btn.addEventListener('click', async () => {
          btn.disabled = true;
          try { await api('/unassign', 'POST', { annotationId: r.annotation_id, batchId: nextBatchId }); await loadQueue(); }
          catch (e) { btn.disabled = false; err(e); }
        });
      } else {
        btn.textContent = `+ Batch ${nextBatchId}`;
        let reason = '';
        if (!actionable) reason = 'only Flagging Candidate / Remove Flagged Submission can be batched';
        else if (!savedOk) reason = 'set status OK and Save first';
        else if (r.fresh) reason = 'awaiting enrichment — refresh from capture, then assign';
        btn.disabled = !!reason;
        if (reason) btn.title = reason;
        btn.addEventListener('click', async () => {
          btn.disabled = true;
          try {
            const out = await api('/assign', 'POST', { annotationId: r.annotation_id, batchId: nextBatchId });
            if (!out.eligible) $('status').textContent = 'Not assignable (must be reviewed OK, a flag/remove action, and enriched).';
            await loadQueue();
          } catch (e) { btn.disabled = false; err(e); }
        });
      }
      batchTd.appendChild(btn); tr.appendChild(batchTd);

      tb.appendChild(tr);
    });
  }

  // --- batch actions ---------------------------------------------------------
  $('reload').addEventListener('click', loadQueue);
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
