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

if (typeof window !== 'undefined') { window.buildAnnotation = buildAnnotation; window.validateAnnotation = validateAnnotation; }
if (typeof module !== 'undefined' && module.exports) { module.exports = { buildAnnotation, validateAnnotation }; }
