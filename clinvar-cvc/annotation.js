/**
 * Maps a selected scraped SCV row + VCV context + curator action/reason/notes +
 * verified email into the v4 annotation document, and centralizes validation.
 * Pure module: no DOM, no chrome.*.
 *
 * Field names mirror the legacy sheet columns so migrated history stays uniform.
 */

function buildAnnotation(scvRow, vcv, input, userEmail) {
  return {
    variation_id: vcv.variation_id,
    vcv: vcv.vcv,
    scv: scvRow.scv,
    submitter: scvRow.submitter,
    submitter_id: scvRow.submitter_id,
    interp: scvRow.interp,
    review_status: scvRow.review,
    action: input.action,
    reason: input.reason,
    notes: input.notes,
    user_email: userEmail,
    created_at: new Date()
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

const DEDUP_FIELDS = ['variation_id', 'vcv', 'scv', 'submitter', 'submitter_id', 'interp',
  'review_status', 'action', 'reason', 'notes', 'user_email']; // excludes created_at

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
