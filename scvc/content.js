const SPREADSHEET_ID = '1pzuWR409vSmoFX9inmoU6el6vjG0SniB1KrxWLeVpaA';
const SCV_RANGE = 'SCVs';
const VCV_RANGE = 'VCVs';

// Inform the background page that
// this tab should have a page-action.
chrome.runtime.sendMessage({
  from: 'content',
  subject: 'showPageAction',
});

// Listen for messages from the popup.
chrome.runtime.onMessage.addListener((msg, sender, response) => {

  // First, validate the message's structure.
  if ((msg.from === 'popup') && (msg.subject === 'DOMInfo')) {
    function getMatch(text, re, grp) {
      var result;
      result = text.match(re);
      if (result === null) {
          return "";
      }
      return result[grp];
    }
    // Collect the necessary data.
    var cond_origin_re = /(.*)\nAllele origin: (.*)/i;
    var review_method_re = /(.*)\n.*\n*Method: (.*)/i;
    var subm_scv_re = /(.*)(\n.*)*\nAccession: (.*)\nFirst in ClinVar: (.*)\nLast updated: (.*)/i;
    var interp_re = /(.*)\n\((.*)\)/i;
    var subm_id_re = /\/clinvar\/submitters\/([0-9]*)\//i;

    var vcv_interp_re = /<dt>Interpretation:<\/dt>\s*<dd.*>\s*(.*)[\x200B]*\s*<p>/i
    var vcv_revstat_re = /<dt>Review status:<\/dt>\s*<dd>.*(practice guideline|reviewed by expert panel|no assertion provided|no interpretation for the single variant|criteria provided, multiple submitters, no conflicts|criteria provided, single submitter|criteria provided, conflicting interpretations|no assertion criteria provided).*\<\/dd>\s*/is
    var vcv_most_recent_re = /<dt>Most recent Submission:<\/dt>\s*<dd>\s*(\w{3} \d+\, \d{4})\s*<\/dd>/i
    var vcv_last_eval_re = /<dt>Last evaluated:<\/dt>\s*<dd>\s*(\w{3} \d+\,\d{4})\s*<\/dd>\s*/i
    var vcv_accession_re = /<dt>Accession:<\/dt>\s*<dd>\s*(VCV[0-9]*\.[0-9]*)\s*<\/dd>\s*/i
    var vcv_variation_id_re = /<dt>Variation ID:<\/dt>\s*<dd>\s*(\d+)\s*<\/dd>\s*/i

    var domInfo = {
      spreadsheet: SPREADSHEET_ID,
      scv_range: SCV_RANGE,
      vcv_range: VCV_RANGE,
      vcv : "",
      name : "",
      variation_id : "",
      vcv_interp : "",
      vcv_review : "",
      vcv_most_recent : "",
      vcv_eval_date : "",
      row: []
    };

    var variantBox = document.evaluate(".//div[contains(concat(' ', @class, ' '),' variant-box ')]/dl", document, null, XPathResult.ANY_TYPE, null );
    var variantBoxHTML = variantBox.iterateNext().innerHTML;
    domInfo.vcv             = getMatch(variantBoxHTML, vcv_accession_re, 1);
    domInfo.vcv_review      = getMatch(variantBoxHTML, vcv_revstat_re, 1);
    domInfo.vcv_most_recent = getMatch(variantBoxHTML, vcv_most_recent_re, 1);
    domInfo.vcv_eval_date   = getMatch(variantBoxHTML, vcv_last_eval_re, 1);
    domInfo.variation_id    = getMatch(variantBoxHTML, vcv_variation_id_re, 1);
    domInfo.vcv_interp      = getMatch(variantBoxHTML, vcv_interp_re, 1);

    domInfo.name = document.querySelectorAll('#id_first h4')[0].innerText;
    var scvarray = document.querySelectorAll('#assertion-list tbody tr');
    scvarray.forEach(myFunction);
    function myFunction(value, index, array) {
        var interp_match = value.cells[0].innerText.match(interp_re);
        var review_method_match = value.cells[1].innerText.match(review_method_re);
        var cond_origin_match = value.cells[2].innerText.match(cond_origin_re);
        var subm_scv_match = value.cells[3].innerText.match(subm_scv_re);
        var subm_id = value.cells[3].innerHTML.match(subm_id_re)[1];

        domInfo.row.push({
            submitter : subm_scv_match[1],
            scv    : subm_scv_match[3],
            submitter_id : subm_id,
            subm_date : subm_scv_match[5],
            condition : cond_origin_match[1],
            origin : cond_origin_match[2],
            review : review_method_match[1],
            method : review_method_match[2],
            interp : interp_match[1],
            eval_date : interp_match[2]
        });
    }
    // Directly respond to the sender (popup),
    // through the specified callback.
    response(domInfo);
  }
});
