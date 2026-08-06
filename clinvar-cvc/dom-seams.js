// dom-seams.js — the ClinVar page's DOM "seams": every location the scraper
// (scrape.js) reaches into for data, named, each with a lightweight probe. When
// ClinVar changes its markup, `inspectSeams(doc)` produces a per-seam health
// report that pinpoints WHICH location broke, instead of the scraper silently
// returning blanks and leaving you to guess.
//
// These MIRROR scrape.js's locators; dom-seams.test.js keeps them honest by
// cross-checking inspectSeams() against a real extractClinVarData() run over the
// fixtures. SCV-row seams reuse the scv-sections.js registry directly (shared
// source of truth — no second copy of those selectors). Probes are deliberately
// LOOSE presence/shape checks: the inspector answers "is this location shaped as
// the scraper expects?", not "extract the exact value" (that's scrape.js's job),
// so it stays robust to incidental markup changes and only fires on real drift.
//
// Dual-mode: `window`/`self` global in the browser, `module.exports` under
// Node/tests — matching the sibling modules.

var _SECTIONS = (typeof require === 'function')
  ? require('./scv-sections.js').SCV_SECTIONS
  : (typeof self !== 'undefined' ? self.SCV_SECTIONS
     : (typeof window !== 'undefined' ? window.SCV_SECTIONS : []));

function _xpathString(doc, expr) {
  try { return doc.evaluate(expr, doc, null, XPathResult.STRING_TYPE, null).stringValue.trim(); }
  catch (e) { return ''; }
}
function _variantBoxHTML(doc) {
  try {
    var n = doc.evaluate("//div[@id='new-variant-details']//dl", doc, null, XPathResult.ANY_TYPE, null).iterateNext();
    return n ? n.innerHTML : '';
  } catch (e) { return ''; }
}

// VCV-header seams — every variation page has these, so all are `required`.
var HEADER_SEAMS = [
  { key: 'variant-details-box', required: true, probe: function (doc) {
      var html = _variantBoxHTML(doc);
      return { ok: !!html, detail: html ? 'new-variant-details <dl> present'
                                        : 'MISSING //div[@id="new-variant-details"]//dl' };
  } },
  { key: 'vcv-accession', required: true, probe: function (doc) {
      var m = /VCV\d+\.\d+/.exec(_variantBoxHTML(doc));
      return { ok: !!m, detail: m ? m[0] : 'no VCV accession in variant box' };
  } },
  { key: 'vcv-variation-id', required: true, probe: function (doc) {
      var m = /Variation ID:\s*(\d+)/.exec(_variantBoxHTML(doc));
      return { ok: !!m, detail: m ? ('Variation ID ' + m[1]) : 'no "Variation ID:" in variant box' };
  } },
  { key: 'variant-name', required: true, probe: function (doc) {
      var els = doc.querySelectorAll('#variant-details-table div div dl dd p');
      var name = els.length ? ((els[0].textContent || '').trim()) : '';
      if (!name) { var t = doc.querySelector('.usa-color-primary-darker h2'); name = t ? (t.textContent || '').trim() : ''; }
      return { ok: !!name, detail: name || 'no name via "#variant-details-table … dd p" nor ".usa-color-primary-darker h2"' };
  } },
  { key: 'vcv-classification', required: true, probe: function (doc) {
      var v = _xpathString(doc, "//div[@class='germline-section']//div[@class='single-item-value']/text()");
      return { ok: !!v, detail: v || 'empty germline-section single-item-value' };
  } },
  { key: 'vcv-review-status', required: true, probe: function (doc) {
      var v = _xpathString(doc, "//div[@class='germline-section']//div[@id='germline-stars-icon']/p/text()");
      return { ok: !!v, detail: v || 'empty germline-stars-icon' };
  } },
  { key: 'timeline', required: true, probe: function (doc) {
      var td = doc.querySelectorAll('table.timeline-table tbody tr td');
      return { ok: td.length > 3, detail: td.length + ' timeline cells (scraper needs > 3)' };
  } }
];

// One seam per registered SCV section. Germline is `required` (every variation
// has a germline submission list); the two somatic sections are optional — a
// page with no somatic SCVs legitimately lacks those containers, which is
// healthy (ok), NOT drift. A section that IS present but whose inject cell has
// lost its SCV accession is drift (ok:false) regardless of required.
function _scvSeam(section) {
  var required = section.key === 'germline';
  return {
    key: 'scv:' + section.key,
    required: required,
    probe: function (doc) {
      var rows = doc.querySelectorAll(section.rowSelector);
      if (!rows.length) {
        return { ok: !required, present: false, count: 0,
                 detail: required ? ('MISSING germline rows: ' + section.rowSelector)
                                  : ('absent — no ' + section.key + ' SCVs on this page') };
      }
      var cell = rows[0].cells ? rows[0].cells[section.injectCell] : null;
      var shapeOk = !!(cell && /SCV\d+\.\d+/.test(cell.innerHTML));
      return { ok: shapeOk, present: true, count: rows.length,
               detail: rows.length + ' rows; cell[' + section.injectCell + '] '
                       + (shapeOk ? 'has an SCV accession' : 'MISSING SCV accession (cell-layout drift)') };
    }
  };
}

function seamDefs() {
  return HEADER_SEAMS.concat((_SECTIONS || []).map(_scvSeam));
}

// Run every seam's probe. Returns { ok, seams: [{ key, required, ok, detail,
// present?, count? }] }. Top-level `ok` is true when every seam is healthy —
// each seam's own `ok` already encodes "resolved, or legitimately absent-optional".
function inspectSeams(doc) {
  var results = seamDefs().map(function (s) {
    var r = s.probe(doc);
    var out = { key: s.key, required: s.required, ok: r.ok, detail: r.detail };
    if (r.present !== undefined) { out.present = r.present; out.count = r.count; }
    return out;
  });
  return { ok: results.every(function (r) { return r.ok; }), seams: results };
}

// Human-readable one-line-per-seam report (for console diagnostics).
function formatSeams(report) {
  return report.seams.map(function (r) {
    return (r.ok ? '  ok  ' : ' DRIFT') + ' ' + r.key + (r.required ? '' : ' (optional)') + ' — ' + r.detail;
  }).join('\n');
}

(function (root) {
  if (root) {
    root.inspectSeams = inspectSeams;
    root.formatSeams = formatSeams;
    root.seamDefs = seamDefs;
  }
})(typeof self !== 'undefined' ? self : (typeof window !== 'undefined' ? window : null));
if (typeof module !== 'undefined' && module.exports) {
  module.exports = { inspectSeams, formatSeams, seamDefs };
}
