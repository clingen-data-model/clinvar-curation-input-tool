// scv-sections.js — the "seam registry": the single source of truth for the
// DOM locations of ClinVar's three SCV submission sections (germline, somatic
// clinical impact, somatic oncogenicity) plus the global config of which are
// annotatable. Consumed by BOTH scrape.js (row extraction) and content.js
// (in-page badge injection) so those two stay in lock-step.
//
// Dual-mode: `window.*`/`self.*` global in the browser (content script + popup),
// `module.exports` under Node/tests — matching the sibling modules.

// Ordered registry. `rowSelector` selects a section's SCV rows; `injectCell` is
// the row-cell index the in-page `+ Annotate`/`CvC N` badges are injected into.
// All three sections use the SAME submitter cell (index 3) for injection and
// share the same cell layout (only the cell CONTENT formats differ) — see
// scrape.js for the per-section field extraction.
var SCV_SECTIONS = [
  {
    key: 'germline',
    rowSelector: '.submissions-germline-list tbody tr.germline-sub-col',
    injectCell: 3
  },
  {
    key: 'somatic-clinical-impact',
    rowSelector: '#submissions-somatic-list-clinical-impact-tbody tr.somatic-sub-col',
    injectCell: 3
  },
  {
    key: 'somatic-oncogenicity',
    rowSelector: '#submissions-somatic-list-oncogenicity-tbody tr.somatic-sub-col',
    injectCell: 3
  }
];

// Global config: which sections a curator may annotate. Default: all three. A
// curator/deploy can trim this to any subset (e.g. ['germline']); a de-configured
// section is still SCRAPED (so its rows appear in data.row) but gets NO in-page
// badge and is not offered in the popup SCV picker. Mutate in place (e.g.
// `ANNOTATABLE_SCV_SECTIONS.length = 0; ANNOTATABLE_SCV_SECTIONS.push('germline')`)
// so `annotatableSections()`, which closes over this array, reflects the change.
var ANNOTATABLE_SCV_SECTIONS = ['germline', 'somatic-clinical-impact', 'somatic-oncogenicity'];

// The registry entries whose key is in the current ANNOTATABLE_SCV_SECTIONS
// config, preserving registry order.
function annotatableSections() {
  return SCV_SECTIONS.filter(function (s) {
    return ANNOTATABLE_SCV_SECTIONS.indexOf(s.key) !== -1;
  });
}

(function (root) {
  if (root) {
    root.SCV_SECTIONS = SCV_SECTIONS;
    root.ANNOTATABLE_SCV_SECTIONS = ANNOTATABLE_SCV_SECTIONS;
    root.annotatableSections = annotatableSections;
  }
})(typeof self !== 'undefined' ? self : (typeof window !== 'undefined' ? window : null));
if (typeof module !== 'undefined' && module.exports) {
  module.exports = { SCV_SECTIONS, ANNOTATABLE_SCV_SECTIONS, annotatableSections };
}
