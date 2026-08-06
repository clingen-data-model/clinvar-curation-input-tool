/**
 * Maps a selected scraped SCV row + VCV context + curator action/reason/notes +
 * verified email into the v4 annotation document, and centralizes validation.
 * Pure module: no DOM, no chrome.*.
 *
 * Field names mirror the legacy sheet columns so migrated history stays uniform.
 */

function buildAnnotation(scvRow, vcv, input, userEmail) {
  const created_at = new Date();
  return {
    variation_id: vcv.variation_id,
    vcv: vcv.vcv,
    name: vcv.name,
    scv: scvRow.scv,
    submitter: scvRow.submitter,
    submitter_id: scvRow.submitter_id,
    interp: scvRow.interp,
    review_status: scvRow.review,
    action: input.action,
    reason: input.reason,
    notes: input.notes,
    user_email: userEmail,
    created_at,
    annotation_id: String(created_at.getTime())
  };
}

function validateAnnotation(data) {
  if (!data.scv) {
    return 'An SCV selection is required.';
  }

  if (!data.action) {
    return 'An action is required.';
  }

  if (data.action !== 'No Change' && !data.reason) {
    return `A reason is required for a '${data.action}' annotation.`;
  }

  return null;
}

// Excludes created_at and name: name is derived from variation_id, and keeping
// it out of the hash avoids a variant-rename creating a false non-duplicate.
const DEDUP_FIELDS = ['variation_id', 'vcv', 'scv', 'submitter', 'submitter_id', 'interp',
  'review_status', 'action', 'reason', 'notes', 'user_email'];

async function annotationDocId(doc) {
  const canonical = JSON.stringify(DEDUP_FIELDS.map(f => String(doc[f] ?? '')));
  const bytes = new TextEncoder().encode(canonical);
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return Array.from(new Uint8Array(digest)).map(b => b.toString(16).padStart(2, '0')).join('');
}

if (typeof window !== 'undefined') {
  window.buildAnnotation = buildAnnotation;
  window.validateAnnotation = validateAnnotation;
  window.annotationDocId = annotationDocId;
}
if (typeof module !== 'undefined' && module.exports) {
  module.exports = { buildAnnotation, validateAnnotation, annotationDocId };
}
