/**
 * Pure ClinVar page scraper, ported from scvc/content.js's extractClinVarData().
 *
 * Behavior-preserving refactor: same regexes/XPath, same fallback logic, same
 * scraped-content shape (vcv, variation_id, vcv_interp, vcv_review,
 * vcv_eval_date, vcv_most_recent, name, row[]) — minus the dead Sheets-only
 * fields (spreadsheet, scv_range, vcv_range) which belonged to the retired
 * Google Sheets persistence path.
 *
 * Takes `doc` (the Document) as a parameter instead of relying on a global,
 * so it is testable under jsdom without any browser/extension APIs.
 */

const DEBUG = false;

function debug(...args) {
  if (DEBUG) console.log(...args);
}

function getMatch(text, re, grp) {
  var result;
  result = text.match(re);
  if (result === null) {
    return "";
  }
  return result[grp];
}

// --- Regexes (ported from scvc/content.js; allele-origin capture dropped) ---
var review_method_re = /(practice guideline|reviewed by expert panel|no assertion provided|no interpretation for the single variant|criteria provided, multiple submitters, no conflicts|criteria provided, single submitter|criteria provided, conflicting interpretations|no assertion criteria provided|no classification provided|Flagged submission).*?Method:.*?([\w\,\s]+)*/is;
var subm_scv_re = /\W*\/clinvar\/submitters\/(\d+)\/".*?>(.+?)<\/a>.*?Accession:.*?(SCV\d+\.\d+).*?First in ClinVar:\W(\w+\s\d+\,\s\d+).*?Last updated:.*?(\w+\s\d+\,\s\d+)/is;
var interp_re = /\W*<div.*?<div.*?(\w+([\s\/\-\,]*\w+)*).*?\(([\w\s\,\-]+)\)/is;

var vcv_accession_re = /Accession:.*?(VCV\d+\.\d+)/is;
var vcv_variation_id_re = /Variation ID:.*?(\d+)/is;

// Relaxed review-status extractor for the somatic sections. Reuses the leading
// standard review-status phrase alternation from review_method_re but DROPS the
// `.*?Method:...` tail, because somatic cell[1] carries no "Method:" (e.g.
// "criteria provided, single submitter (AMP/ASCO/CAP Guidelines, 2017)").
var review_status_re = /(practice guideline|reviewed by expert panel|no assertion provided|no interpretation for the single variant|criteria provided, multiple submitters, no conflicts|criteria provided, single submitter|criteria provided, conflicting interpretations|no assertion criteria provided|no classification provided|Flagged submission)/is;

// The trailing "(<eval date>)" in a somatic classification cell, e.g.
// "(Jul 11, 2023)" / "(Mar 04, 2025)". Requires a month token so it never
// mistakes a parenthetical qualifier like "(Strong)" for the date.
var somatic_eval_date_re = /\(([A-Z][a-z]{2,}\.?\s+\d{1,2},\s*\d{4})\)/;

// Resolve the shared section registry. In the browser, scv-sections.js is
// loaded (content script) BEFORE scrape.js and exposes window/self globals;
// under Node/tests we require it. Returns [] if unavailable so scraping never
// throws (best-effort, like the rest of the scraper).
function getScvSections() {
  var root = (typeof self !== 'undefined') ? self : (typeof window !== 'undefined' ? window : null);
  if (root && root.SCV_SECTIONS) return root.SCV_SECTIONS;
  if (typeof require === 'function') {
    try { return require('./scv-sections.js').SCV_SECTIONS; } catch (e) { /* fall through */ }
  }
  return [];
}

/**
 * Extract the VCV-level header fields: vcv, variation_id, name, vcv_interp,
 * vcv_review, vcv_most_recent, vcv_eval_date.
 */
function extractVcvHeader(doc) {
  var header = {
    vcv: "",
    name: "",
    variation_id: "",
    vcv_interp: "",
    vcv_review: "",
    vcv_most_recent: "",
    vcv_eval_date: ""
  };

  var vcvClassificationText = doc.evaluate("//div[@class='germline-section']//div[@class='single-item-value']/text()", doc, null, XPathResult.STRING_TYPE, null).stringValue.trim();
  var vcvReviewStatus = doc.evaluate("//div[@class='germline-section']//div[@id='germline-stars-icon']/p/text()", doc, null, XPathResult.STRING_TYPE, null).stringValue.trim();
  vcvReviewStatus = vcvReviewStatus.replace(/\.$/g, '');

  var variantBox = doc.evaluate("//div[@id='new-variant-details']//dl", doc, null, XPathResult.ANY_TYPE, null);
  var variantBoxHTML = variantBox.iterateNext().innerHTML;

  // Extract variant name with fallback logic
  debug('\n=== Extracting Variant Name ===');
  var nameElements = doc.querySelectorAll('#variant-details-table div div dl dd p');
  debug(`Name selector found ${nameElements.length} elements`);

  if (nameElements.length > 0) {
    header.name = nameElements[0].innerText || nameElements[0].textContent || "";
    debug(`Extracted name from element 0: "${header.name}"`);

    // If first element is empty, try other elements
    if (!header.name && nameElements.length > 1) {
      for (let i = 1; i < nameElements.length; i++) {
        const altName = nameElements[i].innerText || nameElements[i].textContent || "";
        if (altName.trim()) {
          header.name = altName.trim();
          debug(`Found name in element ${i}: "${header.name}"`);
          break;
        }
      }
    }
  } else {
    // Try alternative name extraction
    debug('Attempting alternative name extraction...');

    // Try the blue box title
    var titleElement = doc.querySelector('.usa-color-primary-darker h2');
    if (titleElement) {
      header.name = titleElement.innerText || titleElement.textContent || "";
      debug(`Alternative name found in title: "${header.name}"`);
    }

    // Try variant identifiers section
    if (!header.name) {
      var identifierElements = doc.querySelectorAll('#variant-details-table dd p');
      if (identifierElements.length > 0) {
        header.name = identifierElements[0].innerText || identifierElements[0].textContent || "";
        debug(`Alternative name found in identifiers: "${header.name}"`);
      }
    }
  }

  debug(`Final extracted name: "${header.name}"`);
  header.vcv = getMatch(variantBoxHTML, vcv_accession_re, 1);
  header.variation_id = getMatch(variantBoxHTML, vcv_variation_id_re, 1);
  header.vcv_review = vcvReviewStatus;
  header.vcv_interp = vcvClassificationText;

  var timelineArray = doc.querySelectorAll('table.timeline-table tbody tr td');
  header.vcv_most_recent = timelineArray.length > 2 ? timelineArray[2].innerHTML : "";
  header.vcv_eval_date = timelineArray.length > 3 ? timelineArray[3].innerHTML : "";

  return header;
}

/**
 * Parse a single `.submissions-germline-list tbody tr.germline-sub-col` row
 * element into `{submitter_id, submitter, scv, subm_date, review, interp,
 * eval_date}`. (Allele origin and assertion method are intentionally NOT
 * captured — they are unused by the v4 annotation.)
 */
function parseScvRow(rowEl, index) {
  debug(`\n=== Processing SCV Row ${index + 1} ===`);

  // Log cell structure for debugging
  debug(`Row has ${rowEl.cells.length} cells`);
  for (let i = 0; i < rowEl.cells.length; i++) {
    const cellPreview = rowEl.cells[i].innerHTML.substring(0, 150);
    debug(`Cell ${i}: ${cellPreview}...`);
  }

  var interp_match = rowEl.cells[0].innerHTML.match(interp_re);
  var review_method_match = rowEl.cells[1].innerHTML.match(review_method_re);
  var subm_scv_match = rowEl.cells[3].innerHTML.match(subm_scv_re);

  debug(`Regex match results:`);
  debug(`  interp_match: ${interp_match ? 'FOUND' : 'MISSING'}`);
  debug(`  review_method_match: ${review_method_match ? 'FOUND' : 'MISSING'}`);
  debug(`  subm_scv_match: ${subm_scv_match ? 'FOUND' : 'MISSING'}`);

  // Extract data with fallback logic
  var extractedData = {
    submitter_id: "",
    submitter: "",
    scv: "",
    subm_date: "",
    review: "",
    interp: "",
    eval_date: ""
  };

  // Extract interpretation data
  if (interp_match) {
    extractedData.interp = interp_match[1] || "";
    extractedData.eval_date = interp_match[3] || "";
    debug(`  Extracted interp: "${extractedData.interp}", eval_date: "${extractedData.eval_date}"`);
  } else {
    // Try alternative extraction for interpretation
    debug(`  Attempting alternative interpretation extraction...`);
    var altInterpMatch = rowEl.cells[0].innerHTML.match(/<div[^>]*>([^<(]+)/i);
    if (altInterpMatch) {
      extractedData.interp = altInterpMatch[1].trim();
      debug(`  Alternative interp found: "${extractedData.interp}"`);
    }

    // Try to find evaluation date in different format
    var dateMatch = rowEl.cells[0].innerHTML.match(/\(([^)]+)\)/);
    if (dateMatch) {
      extractedData.eval_date = dateMatch[1];
      debug(`  Alternative eval_date found: "${extractedData.eval_date}"`);
    }
  }

  // Extract review status (group 1 of review_method_re). The assertion method
  // in group 2 is intentionally not captured.
  if (review_method_match) {
    extractedData.review = review_method_match[1] || "";
    debug(`  Extracted review: "${extractedData.review}"`);
  } else {
    // Try alternative extraction for review status
    debug(`  Attempting alternative review status extraction...`);

    // Look for review status in stars-description div
    var starsDescMatch = rowEl.cells[1].innerHTML.match(/stars-description[^>]*>([^<]+)</);
    if (starsDescMatch) {
      extractedData.review = starsDescMatch[1].trim();
      debug(`  Alternative review found: "${extractedData.review}"`);
    }
  }

  // Extract submitter and SCV data
  if (subm_scv_match) {
    extractedData.submitter_id = subm_scv_match[1] || "";
    extractedData.submitter = subm_scv_match[2] || "";
    extractedData.scv = subm_scv_match[3] || "";
    extractedData.subm_date = subm_scv_match[5] || "";
    debug(`  Extracted submitter_id: "${extractedData.submitter_id}", submitter: "${extractedData.submitter}", scv: "${extractedData.scv}"`);
  } else {
    // Try alternative extraction for submitter data
    debug(`  Attempting alternative submitter extraction...`);

    // Look for submitter link
    var submitterMatch = rowEl.cells[3].innerHTML.match(/href="\/clinvar\/submitters\/(\d+)\/[^>]*>([^<]+)<\/a>/);
    if (submitterMatch) {
      extractedData.submitter_id = submitterMatch[1];
      extractedData.submitter = submitterMatch[2];
      debug(`  Alternative submitter found: ID="${extractedData.submitter_id}", name="${extractedData.submitter}"`);
    }

    // Look for SCV accession
    var scvMatch = rowEl.cells[3].innerHTML.match(/Accession:\s*(SCV\d+\.\d+)/);
    if (scvMatch) {
      extractedData.scv = scvMatch[1];
      debug(`  Alternative SCV found: "${extractedData.scv}"`);
    }

    // Look for submission date
    var dateMatch = rowEl.cells[3].innerHTML.match(/Last updated:\s*([^<\n]+)/);
    if (dateMatch) {
      extractedData.subm_date = dateMatch[1].trim();
      debug(`  Alternative subm_date found: "${extractedData.subm_date}"`);
    }
  }

  debug(`Added SCV row ${index + 1} with SCV: "${extractedData.scv}"`);

  return {
    submitter_id: extractedData.submitter_id,
    submitter: extractedData.submitter,
    scv: extractedData.scv,
    subm_date: extractedData.subm_date,
    review: extractedData.review,
    interp: extractedData.interp,
    eval_date: extractedData.eval_date
  };
}

/**
 * Extract the classification (`interp`) + `eval_date` from a somatic section's
 * cell[0]. Unlike germline (which carries interp_re-matchable markup), somatic
 * cells render the classification as plain visible text followed by a
 * "(<eval date>)" — e.g. "Tier I (Strong) - Diagnostic - supports diagnosis
 * (Jul 11, 2023)" (clinical impact) or "Oncogenic (Mar 04, 2025)"
 * (oncogenicity). We capture the FULL classification phrase (everything before
 * the trailing date paren, whitespace-collapsed) so the whole "Tier … - …"
 * string is preserved; anything after the date (e.g. the "Contributing to
 * aggregate classification" badge text) is dropped.
 */
function extractSomaticClassification(cellEl) {
  var text = ((cellEl && (cellEl.textContent || '')) || '').replace(/\s+/g, ' ').trim();
  var m = text.match(somatic_eval_date_re);
  if (m) {
    return { interp: text.slice(0, m.index).trim(), eval_date: m[1] };
  }
  return { interp: text, eval_date: '' };
}

/**
 * Parse a single somatic (clinical-impact or oncogenicity)
 * `tr.somatic-sub-col` row into the SAME field shape as parseScvRow:
 * {submitter_id, submitter, scv, subm_date, review, interp, eval_date}. Somatic
 * rows share germline's cell layout (cell[0]=classification, cell[1]=review,
 * cell[3]=submitter/accession) but different content formats, so the submitter
 * uses the same subm_scv_re while the classification/review use the somatic
 * helpers above. Downstream (annotation.buildAnnotation) is therefore unchanged.
 */
function parseSomaticRow(rowEl, index) {
  var extractedData = {
    submitter_id: "", submitter: "", scv: "", subm_date: "", review: "", interp: "", eval_date: ""
  };

  if (rowEl.cells[0]) {
    var cls = extractSomaticClassification(rowEl.cells[0]);
    extractedData.interp = cls.interp;
    extractedData.eval_date = cls.eval_date;
  }

  if (rowEl.cells[1]) {
    var review_match = rowEl.cells[1].innerHTML.match(review_status_re);
    if (review_match) { extractedData.review = review_match[1] || ""; }
  }

  if (rowEl.cells[3]) {
    var subm_scv_match = rowEl.cells[3].innerHTML.match(subm_scv_re);
    if (subm_scv_match) {
      extractedData.submitter_id = subm_scv_match[1] || "";
      extractedData.submitter = subm_scv_match[2] || "";
      extractedData.scv = subm_scv_match[3] || "";
      extractedData.subm_date = subm_scv_match[5] || "";
    }
  }

  return {
    submitter_id: extractedData.submitter_id,
    submitter: extractedData.submitter,
    scv: extractedData.scv,
    subm_date: extractedData.subm_date,
    review: extractedData.review,
    interp: extractedData.interp,
    eval_date: extractedData.eval_date
  };
}

/**
 * Extract the row[] array — one entry per SCV submission row, across ALL
 * registered sections (germline + both somatic). Each row is tagged with its
 * `section` key. Germline extraction is byte-identical to before (same
 * parseScvRow, same regexes/fields); the only germline change is the added
 * `section: 'germline'` metadata tag. Sections are scraped regardless of the
 * ANNOTATABLE_SCV_SECTIONS config — config gating happens in the UI layers
 * (content.js badges, popup.js picker), not here.
 */
function extractScvRows(doc) {
  var sections = getScvSections();
  var rows = [];
  sections.forEach(function (section) {
    var els = doc.querySelectorAll(section.rowSelector);
    els.forEach(function (value, index) {
      var row = (section.key === 'germline')
        ? parseScvRow(value, index)
        : parseSomaticRow(value, index);
      row.section = section.key;
      rows.push(row);
    });
  });
  return rows;
}

/**
 * Extract the full scraped-content shape from a ClinVar variation page
 * document: { vcv, name, variation_id, vcv_interp, vcv_review,
 * vcv_most_recent, vcv_eval_date, row[] }.
 */
function extractClinVarData(doc) {
  var header = extractVcvHeader(doc);
  var row = extractScvRows(doc);

  return {
    vcv: header.vcv,
    name: header.name,
    variation_id: header.variation_id,
    vcv_interp: header.vcv_interp,
    vcv_review: header.vcv_review,
    vcv_most_recent: header.vcv_most_recent,
    vcv_eval_date: header.vcv_eval_date,
    row: row
  };
}

if (typeof window !== 'undefined') { window.extractClinVarData = extractClinVarData; }
if (typeof module !== 'undefined' && module.exports) {
  module.exports = { extractClinVarData, extractVcvHeader, extractScvRows, parseScvRow, parseSomaticRow, extractSomaticClassification, getMatch };
}
