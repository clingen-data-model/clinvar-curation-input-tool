// submission.js — pure helpers for producing the submission FILE + the
// human-composed submission EMAIL. Chunk 0.5 resolved the "how to email" open
// item as: NO Gmail scope — the app writes the NDJSON to Drive and opens a
// prefilled mailto (the curator attaches the file + sends). So there is no
// Gmail draft here; just pure builders that the backend (file naming) and
// frontend (mailto link) consume. CommonJS; unit-tested.

// Submission filename. Pre-cutover (dev) is prefixed `v4-DEV-` so a test file
// can NEVER collide with, or be mistaken for, a live-pipeline file
// (`clinvar-annotation-submission-*`). At cutover (prod) it matches the legacy
// name exactly, preserving the reviewers' "grab it from the folder" habit.
// The per-batch filename stem (everything before the date) — used both to name a
// file and to LIST all of a batch's generated files in the folder.
function submissionFilePrefix({ batchId, env }) {
  const prefix = env === 'prod' ? '' : 'v4-DEV-';
  return `${prefix}clinvar-annotation-submission-${batchId}-`;
}
function submissionFilename({ batchId, date, env }) {
  return `${submissionFilePrefix({ batchId, env })}${date}.json`;
}

// Build the submission email fields (mirrors Generate.js createDraftEmail
// wording). `recipients`/`cc` come from cvc_review_config (NOT the live sheet's
// named ranges), and pre-cutover are test-only addresses. Because mailto cannot
// attach, the body reminds the curator to attach the generated file.
function buildSubmissionEmail({ count, batchId, generatedDatetime, recipients, cc, fileName }) {
  const subject = `ClinGen's Clinvar annotation submission #${batchId}`;
  let body =
    `Here is our next batch of ${count} ClinGen ClinVar Annotations which we ` +
    `finalized for submission on ${generatedDatetime}.\n\n` +
    `Please let us know if you have any questions or concerns.`;
  if (fileName) {
    body += `\n\n(Please attach the submission file: ${fileName})`;
  }
  return { to: recipients || [], cc: cc || [], subject, body };
}

// Build a mailto: URL from an email-fields object. Recipients go in the path;
// cc/subject/body are query params (encoded). cc omitted when empty.
function mailtoUrl({ to, cc, subject, body }) {
  const params = [];
  if (cc && cc.length) params.push('cc=' + encodeURIComponent(cc.join(',')));
  if (subject) params.push('subject=' + encodeURIComponent(subject));
  if (body) params.push('body=' + encodeURIComponent(body));
  const q = params.length ? '?' + params.join('&') : '';
  return `mailto:${(to || []).join(',')}${q}`;
}

module.exports = { submissionFilePrefix, submissionFilename, buildSubmissionEmail, mailtoUrl };
