//const SPREADSHEET_ID = '1pzuWR409vSmoFX9inmoU6el6vjG0SniB1KrxWLeVpaA';
const SPREADSHEET_ID = '1dUnmBZSnz3aeB948b7pIq0iT7_FuCDvtv6FXaVsNcOo';
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
    var review_method_re = /(practice guideline|reviewed by expert panel|no assertion provided|no interpretation for the single variant|criteria provided, multiple submitters, no conflicts|criteria provided, single submitter|criteria provided, conflicting interpretations|no assertion criteria provided|no classification provided|Flagged submission).*?Method:.*?([\w\,\s]+)*/is;
    var subm_scv_re = /\W*\/clinvar\/submitters\/(\d+)\/".*?>(.+?)<\/a>.*?Accession:.*?(SCV\d+\.\d+).*?First in ClinVar:\W(\w+\s\d+\,\s\d+).*?Last updated:.*?(\w+\s\d+\,\s\d+)/is;
    var interp_re = /\W*<div.*?<div.*?(\w+([\s\/\-\,]*\w+)*).*?\(([\w\s\,\-]+)\)/is;
    
    var vcv_accession_re = /Accession:.*?(VCV\d+\.\d+)/is;
    var vcv_variation_id_re = /Variation ID:.*?(\d+)/is;

    var domInfo = {
        spreadsheet: SPREADSHEET_ID,
        scv_range: SCV_RANGE,
        vcv_range: VCV_RANGE,
        vcv: "",
        name: "",
        variation_id: "",
        vcv_interp: "",
        vcv_review: "",
        vcv_most_recent: "",
        vcv_eval_date: "",
        row: []
    };
    
    var variantBox = document.evaluate("//div[@id='new-variant-details']//dl", document, null, XPathResult.ANY_TYPE, null );
    var variantBoxHTML = variantBox.iterateNext().innerHTML;

    // for 3 and 4 start vcvs the review status and classification are found with the following
    var vcvClassificationText = document.evaluate("//div[@class='germline-section']//div[@class='classi-text']", document, null, XPathResult.ANY_TYPE, null );  
    var vcvReviewStatus = document.evaluate("//div[@class='germline-section']//div[@class='review-text']", document, null, XPathResult.ANY_TYPE, null );

    var vcvClassificationTextNode = vcvClassificationText.iterateNext();
    var vcvReviewStatusNode = vcvReviewStatus.iterateNext();

    if (!vcvClassificationTextNode) {
      // for 2 star and below the vcvs review status and classifiction are found with the following
      vcvClassificationText = document.evaluate("//div[@class='germline-section']//div[@class='single-item-value']", document, null, XPathResult.ANY_TYPE, null );
      vcvReviewStatus = document.evaluate("//div[@class='germline-section']//div[@class='section-cnt']//span", document, null, XPathResult.ANY_TYPE, null );  
      vcvClassificationTextNode = vcvClassificationText.iterateNext();
      vcvReviewStatusNode = vcvReviewStatus.iterateNext();
    }
    
    if (!vcvClassificationTextNode) {
      // for vcv with no germline scvs there is no classification and review status
      vcvClassificationText = document.evaluate("//div[@class='germline-section']/p[@class='without-classification']", document, null, XPathResult.ANY_TYPE, null );
      vcvReviewStatus = document.evaluate("//div[@class='germline-section']/p[@class='without-classification']", document, null, XPathResult.ANY_TYPE, null );  
      vcvClassificationTextNode = vcvClassificationText.iterateNext();
      vcvReviewStatusNode = vcvReviewStatus.iterateNext();
    }

    domInfo.name            = document.querySelectorAll('#variant-details-table div div dl dd p')[0].innerText;
    domInfo.vcv             = getMatch(variantBoxHTML, vcv_accession_re, 1);
    domInfo.variation_id    = getMatch(variantBoxHTML, vcv_variation_id_re, 1);
    domInfo.vcv_review      = vcvReviewStatusNode.textContent.trim();
    domInfo.vcv_interp      = vcvClassificationTextNode.textContent.trim();

    var timelineArray = document.querySelectorAll('table.timeline-table tbody tr td');
    domInfo.vcv_most_recent = timelineArray[2].innerHTML;
    domInfo.vcv_eval_date   = timelineArray[3].innerHTML;
    
    var scvarray = document.querySelectorAll('#new-submission-germline table tbody tr');
    scvarray.forEach(myFunction);

    function myFunction(value, index, array) {
      var interp_match = value.cells[0].innerHTML.match(interp_re);
      var review_method_match = value.cells[1].innerHTML.match(review_method_re);

      var cond_origin_match = value.cells[2].innerHTML.match(cond_origin_re);      // alert(value.cells[3].innerHTML);
      var subm_scv_match = value.cells[3].innerHTML.match(subm_scv_re);

      domInfo.row.push({
        submitter_id: subm_scv_match[1],
        submitter: subm_scv_match[2],
        scv: subm_scv_match[3],
        subm_date: subm_scv_match[5],
        origin: cond_origin_match[1],
        review: review_method_match[1],
        method: review_method_match[2],
        interp: interp_match[1],
        eval_date: interp_match[3]
      });
    }
    // Directly respond to the sender (popup),
    // through the specified callback.
    response(domInfo);
  }
});
