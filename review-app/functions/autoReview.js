// autoReview.js — pure port of the Apps Script auto-review rules engine
// (Review&Submit/Code.js appendNewToReviews). Given a v4 annotation row + the
// reviewers allow-list, returns { status, note, auto } exactly as the legacy
// sheet pipeline assigns a DEFAULT review status on refresh. `status === ''`
// means "needs manual review"; `auto` marks an auto-assigned status.
//
// The if/else-if ORDER is load-bearing:
//   deleted > superseded(not-latest) > reclassified(outdated+classif-change) >
//   no-change(auto-OK) > flag-on-already-flagged > remove-on-not-flagged >
//   invalid-action > outdated(no classif change) > reviewer(auto-OK) > manual.
//
// Input `row` (normalized from cvc_annotations(v4); the caller maps columns):
//   action                (string) — e.g. "no change" / "flagging candidate"
//   clinvarReviewStatus   (string) — e.g. "flagged submission"
//   curator               (string)
//   isDeletedScv          (bool)   — is_deleted_scv
//   isLatestAnnotation    (bool)   — is_latest_annotation
//   isOutdatedScv         (bool)   — is_outdated_scv
//   classificationChanged (bool)   — latest_scv_classification != classif_type (when outdated)
// `reviewers` — array of curator strings (cvc_review_config.reviewers).

const ACTION_NO_CHANGE = 'no change';
const ACTION_FLAGGING_CANDIDATE = 'flagging candidate';
const ACTION_REMOVE_FLAGGED_SUBMISSION = 'remove flagged submission';
const REVSTAT_FLAGGED_SUBMISSION = 'flagged submission';
const VALID_ACTIONS = [ACTION_NO_CHANGE, ACTION_FLAGGING_CANDIDATE, ACTION_REMOVE_FLAGGED_SUBMISSION];

function autoReview(row, reviewers) {
  const action = String((row && row.action) || '').trim().toLowerCase();
  const revstat = String((row && row.clinvarReviewStatus) || '').trim().toLowerCase();
  const curator = row && row.curator;
  const isDeleted = !!(row && row.isDeletedScv);
  const isLatest = !!(row && row.isLatestAnnotation);
  const isOutdated = !!(row && row.isOutdatedScv);
  const classifChanged = !!(row && row.classificationChanged);
  const revList = reviewers || [];

  let status = '';
  let note = '';
  if (isDeleted) {
    status = 'Archive';
    note = 'SCV has been deleted by submitter.';
  } else if (!isLatest) {
    note = 'A newer annotation for this SCV takes precedence. Please verify that it is intentional.';
  } else if (isOutdated && classifChanged) {
    note = 'Re-curation needed. SCV classification has been updated by submitter.';
  } else if (action === ACTION_NO_CHANGE) {
    status = 'OK';
    note = `Latest '${ACTION_NO_CHANGE}' actions auto reviewed for all curators, even if outdated as long as SCV has no classification change.`;
  } else if (action === ACTION_FLAGGING_CANDIDATE && revstat === REVSTAT_FLAGGED_SUBMISSION) {
    note = `Review needed. This '${ACTION_FLAGGING_CANDIDATE}' is on an SCV that is already a '${REVSTAT_FLAGGED_SUBMISSION}'.`;
  } else if (action === ACTION_REMOVE_FLAGGED_SUBMISSION && revstat !== REVSTAT_FLAGGED_SUBMISSION) {
    note = `Review needed. This '${ACTION_REMOVE_FLAGGED_SUBMISSION}' is on an SCV that is NOT a '${REVSTAT_FLAGGED_SUBMISSION}'.`;
  } else if (!VALID_ACTIONS.includes(action)) {
    note = 'Error: Invalid or missing action. Inform development team.';
  } else if (isOutdated) {
    note = 'Re-curation needed. SCV has been updated by submitter with no classification change.';
  } else if (revList.includes(curator)) {
    status = 'OK';
    note = "Curator's annotation does not require manual review.";
  } else {
    note = "Review needed. Curator's annotation requires manual review.";
  }
  return { status, note, auto: status !== '' };
}

module.exports = {
  autoReview,
  ACTION_NO_CHANGE, ACTION_FLAGGING_CANDIDATE, ACTION_REMOVE_FLAGGED_SUBMISSION,
  REVSTAT_FLAGGED_SUBMISSION, VALID_ACTIONS
};
