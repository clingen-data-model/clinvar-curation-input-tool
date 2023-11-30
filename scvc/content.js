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
    var cond_origin_re = /\W*Allele origin:.*?(\w+([\,\s]+\w+)*)/is;
    var review_method_re = /(practice guideline|reviewed by expert panel|no assertion provided|no interpretation for the single variant|criteria provided, multiple submitters, no conflicts|criteria provided, single submitter|criteria provided, conflicting interpretations|no assertion criteria provided|Flagged submission)\s(Method:\s([\w\,\s]+))*/is;
    var subm_scv_re = /\W*"https:\/\/www\.ncbi\.nlm\.nih\.gov\/\/clinvar\/submitters\/(\d+)\/">(.+)\<.*?Accession:.*?(SCV\d+\.\d+).*?First in ClinVar:\W(\w+\s\d+\,\s\d+).*?Last updated:.*?(\w+\s\d+\,\s\d+)/is;
    var interp_re = /\W*(\w+([\s\/\-\,]*\w+)*).*?\(([\w\s\,\-]+)\)/is;
    
    var vcv_interp_re = /Interpretation:.*?<dd.*?>.*?(\w+([\s\/\-\,]*\w+)*)/is;
    var vcv_revstat_re = /Review status:.*?(<[^>]+>[^<]*?)*?(\w+([\,\s]+\w+)*)/is;
    var vcv_most_recent_re = /Most recent Submission:.*?(\w+\s\d+\,\s\d+)/is;
    var vcv_last_eval_re = /Last evaluated:.*?(\w+\s\d+\,\s\d+)/is;
    var vcv_accession_re = /Accession:.*?(VCV\d+\.\d+)/is;
    var vcv_variation_id_re = /Variation ID:.*?(\d+)/is;

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
    domInfo.vcv_review      = getMatch(variantBoxHTML, vcv_revstat_re, 2);
    domInfo.vcv_most_recent = getMatch(variantBoxHTML, vcv_most_recent_re, 1);
    domInfo.vcv_eval_date   = getMatch(variantBoxHTML, vcv_last_eval_re, 1);
    domInfo.variation_id    = getMatch(variantBoxHTML, vcv_variation_id_re, 1);
    domInfo.vcv_interp      = getMatch(variantBoxHTML, vcv_interp_re, 1);

    domInfo.name = document.querySelectorAll('#id_first h4')[0].innerText;
    var scvarray = document.querySelectorAll('#assertion-list tbody tr');
    
    scvarray.forEach(myFunction);

    function myFunction(value, index, array) {
      var interp_match = value.cells[0].innerHTML.match(interp_re);
      var review_method_match = value.cells[1].innerText.match(review_method_re);
      var cond_origin_match = value.cells[2].innerHTML.match(cond_origin_re);
      var subm_scv_match = value.cells[3].innerHTML.match(subm_scv_re);

      domInfo.row.push({
        submitter_id: subm_scv_match[1],
        submitter: subm_scv_match[2],
        scv: subm_scv_match[3],
        subm_date: subm_scv_match[5],
        origin: cond_origin_match[1],
        review: review_method_match[1],
        method: review_method_match[3] == undefined ? "" : review_method_match[3],
        interp: interp_match[1],
        eval_date: interp_match[3]
      });
    }
    // Directly respond to the sender (popup),
    // through the specified callback.
    response(domInfo);
  }
});
