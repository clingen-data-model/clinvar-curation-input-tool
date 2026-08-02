// Shared annotation vocabulary: actions and reason-by-action.
// Source of truth: scvc/popup.js (~lines 196-222). Copied verbatim.

var ACTIONS = ['No Change', 'Flagging Candidate', 'Remove Flagged Submission'];

var flaggingCandidateReasonOptions = {
    'Submission errors': [
        'New submission from submitter that appears to have been intended to update this older submission',
        'Other submission error'],
    'Unnecessary Conflicting or Case-level Interpretation Submissions': [
        'Clinical significance appears to be a case-level interpretation inconsistent with variant classification',
        'Unnecessary conflicting claim for distinct condition when other classifications are more relevant'],
    'Old/Outlier/Unsupported Submissions': [
        'Older and outlier claim with insufficient supporting evidence',
        'Older claim that does not account for recent evidence',
        'Claim with insufficient supporting evidence',
        'Outlier claim with insufficient supporting evidence',
        'Conflicts with expert reviewed submission without evidence to support different classification',
        'P/LP classification for a variant in a gene with insufficient evidence for a gene-disease relationship'],
    'Miscellaneous': [
        'This phenotype is not a monogenic disease. The terms P/LP are not appropriate.',
        'Other']
};
var flaggedSubmissionReasonOptions = {
    '': [
        'Other SCVs submitted for VCV record',
        'Gene-disease relationship classification has changed',
        'Discussion with submitter',
        'Curation error',
        'Other'
    ]
};
var reasonsByAction = {
    'Flagging Candidate': flaggingCandidateReasonOptions,
    'Remove Flagged Submission': flaggedSubmissionReasonOptions,
};

function reasonsForAction(action) {
    return reasonsByAction[action] || {};
}

if (typeof window !== 'undefined') { window.ACTIONS = ACTIONS; window.reasonsForAction = reasonsForAction; }
if (typeof module !== 'undefined' && module.exports) { module.exports = { ACTIONS, reasonsForAction }; }
