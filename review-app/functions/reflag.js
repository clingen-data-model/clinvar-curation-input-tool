// reflag.js — reflagging: re-flag previously-submitted flagging candidates whose
// SCV the submitter version-bumped WITHOUT substantive change (the flag was lost
// or never applied). Candidates come from the historical submission record in the
// v4 shadow (cvc_resubmission_candidates — the broad set — badged with the tight
// cvc_autoreflag_candidates). A reflag is a NEW "Flagging Candidate" v4 annotation
// brought up to the SCV's CURRENT version/classification/review-status, written to
// the Firestore capture so it flows through the normal auto-enrich → review →
// submit pipeline (the v4 equivalent of the legacy Reflag.js). Reads are dataset-
// guarded; writes go to the capture collection via an injected creator.
const { assertReadDataset } = require('./dataset-guard.js');
const { webcrypto } = require('crypto');

const ACTION = 'Flagging Candidate';
// MUST match clinvar-cvc/annotation.js DEDUP_FIELDS so a reflag dedups against an
// identical extension capture (content-hash doc id; created_at/name excluded).
const DEDUP_FIELDS = ['variation_id', 'vcv', 'scv', 'submitter', 'submitter_id', 'interp',
  'review_status', 'action', 'reason', 'notes', 'user_email'];

// Candidate list: the broad resubmission set + an is_autoreflag badge + the
// SCV's CURRENT review_status/classification (for an up-to-date reflag) + an
// already_reflagged flag (a current-version Flagging Candidate is already
// captured). `scvIds` (optional) restricts to a selected subset for the write path.
function buildReflagCandidatesSql({ dataset, scvIds }) {
  const ds = assertReadDataset(dataset);
  const B = `clingen-dev.${ds}`;
  // EXCLUDE any candidate that already has a CURRENT-version CvC annotation
  // (a reflag, or otherwise under review) — an overridden previous submission
  // must not appear once a current annotation exists for its SCV.
  const conds = [
    `NOT EXISTS (SELECT 1 FROM \`${B}.cvc_annotations_native_v4\` n WHERE n.scv_id = r.scv_id || '.' || CAST(r.current_scv_ver AS STRING))`
  ];
  if (scvIds && scvIds.length) conds.push('r.scv_id IN UNNEST(@scvIds)');
  const sql = [
    'SELECT',
    '  r.scv_id, r.variation_id, r.vcv_id, r.submitter_id, r.submitter_name,',
    '  r.batch_id AS orig_batch_id, r.annotation_id AS orig_annotation_id,',
    '  r.flagging_reason, r.outcome, r.resubmission_reason,',
    '  r.current_scv_ver, r.current_vcv_ver, r.current_classification, r.current_classif_type,',
    '  r.had_version_bump, r.was_reclassified, r.is_past_grace_period, r.has_remove_flagged_submission,',
    '  r.version_bump_count, r.latest_bump_date,',
    '  (a.scv_id IS NOT NULL) AS is_autoreflag,',
    '  cs.review_status AS current_review_status,',
    '  cs.submitted_classification AS current_submitted_classification',
    `FROM \`${B}.cvc_resubmission_candidates\` r`,
    `LEFT JOIN (SELECT DISTINCT scv_id FROM \`${B}.cvc_autoreflag_candidates\` WHERE is_autoreflag_candidate) a USING (scv_id)`,
    '  LEFT JOIN `clinvar_ingest.clinvar_scvs` cs ON cs.id = r.scv_id AND cs.version = r.current_scv_ver',
    'WHERE ' + conds.join(' AND '),
    // Exactly ONE reflaggable row per SCV — the latest submission (and collapses
    // any clinvar_scvs join fan-out). If an SCV was overridden multiple times,
    // only its most recent submitted version appears.
    'QUALIFY ROW_NUMBER() OVER (PARTITION BY r.scv_id ORDER BY r.batch_accepted_date DESC, r.submitted_scv_ver DESC) = 1',
    'ORDER BY is_autoreflag DESC, r.submitter_name, r.scv_id'
  ].join('\n');
  return { sql, params: scvIds && scvIds.length ? { scvIds: scvIds.map(String) } : {} };
}

const dval = (v) => (v && typeof v === 'object' && 'value' in v) ? v.value : v;

// Build the v4 "Flagging Candidate" reflag doc from a candidate row, brought up
// to the SCV's current version/classification/review-status. `now` is a Date.
function buildReflagDoc(c, userEmail, now) {
  const scv = `${c.scv_id}.${dval(c.current_scv_ver)}`;
  const vcv = c.current_vcv_ver != null ? `${c.vcv_id}.${dval(c.current_vcv_ver)}` : String(c.vcv_id || '');
  const notes = `[Reflag of ${c.scv_id} → v${dval(c.current_scv_ver)}`
    + (c.orig_batch_id ? `, orig batch ${c.orig_batch_id}` : '')
    + '; submitter version-bumped without substantive change]';
  return {
    variation_id: String(c.variation_id), vcv, name: '', scv,
    submitter: c.submitter_name || '', submitter_id: String(c.submitter_id || ''),
    // clean current classification text (e.g. "Likely pathogenic"), not the
    // formatted label ("P, 1★, …"); fall back to the label if absent.
    interp: c.current_submitted_classification || c.current_classification || '',
    review_status: c.current_review_status || '',
    action: ACTION, reason: c.flagging_reason || '', notes,
    user_email: userEmail, created_at: now, annotation_id: String(now.getTime())
  };
}

// Content-hash doc id (SHA-256 over DEDUP_FIELDS) — mirrors annotationDocId so a
// reflag identical to an existing capture collides (create() → ALREADY_EXISTS).
async function reflagDocId(doc) {
  const canonical = JSON.stringify(DEDUP_FIELDS.map((f) => String(doc[f] == null ? '' : doc[f])));
  const digest = await webcrypto.subtle.digest('SHA-256', new TextEncoder().encode(canonical));
  return Array.from(new Uint8Array(digest)).map((b) => b.toString(16).padStart(2, '0')).join('');
}

// deps: runQuery(sql, params) -> rows; createCaptureDoc(docId, doc) -> creates the
// Firestore capture doc, THROWS on ALREADY_EXISTS; now() -> Date.
function makeReflagHandler({ runQuery, dataset, createCaptureDoc, now }) {
  const clock = now || (() => new Date());
  return {
    async candidates() {
      const { sql, params } = buildReflagCandidatesSql({ dataset });
      return { candidates: (await runQuery(sql, params)) || [] };
    },
    // Re-fetch the selected candidates server-side (never trust client fields),
    // build reflag docs, create them (content-hash dedup). Returns per-scv result.
    async reflag({ scvIds, userEmail }) {
      const ids = (scvIds || []).map(String);
      if (!ids.length) return { created: 0, skipped: 0, results: [] };
      const { sql, params } = buildReflagCandidatesSql({ dataset, scvIds: ids });
      const rows = (await runQuery(sql, params)) || [];
      let created = 0, skipped = 0;
      const results = [];
      for (const c of rows) {
        const doc = buildReflagDoc(c, userEmail, clock());
        const id = await reflagDocId(doc);
        try {
          await createCaptureDoc(id, doc);
          created++; results.push({ scv: doc.scv, status: 'reflagged' });
        } catch (e) {
          skipped++;
          const already = /ALREADY_EXISTS|already exists/i.test(e && e.message || '');
          results.push({ scv: doc.scv, status: already ? 'already-reflagged' : 'error', message: already ? undefined : (e && e.message) });
        }
      }
      return { created, skipped, results };
    }
  };
}

module.exports = { ACTION, DEDUP_FIELDS, buildReflagCandidatesSql, buildReflagDoc, reflagDocId, makeReflagHandler };
