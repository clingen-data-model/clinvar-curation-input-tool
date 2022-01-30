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
    // Collect the necessary data.
    var cond_origin_re = /(.*)\nAllele origin: (.*)/i;
    var review_method_re = /(.*)\n.*\n*Method: (.*)/i;
    var subm_scv_re = /(.*)(\n.*)*\nAccession: (.*)\nSubmitted: \((.*)\)/i;
    var interp_re = /(.*)\n\((.*)\)/i;
    var subm_id_re = /\/clinvar\/submitters\/([0-9]*)\//i;
    var vcv_interp_re = /\s*(.*)[\x200B]*\s*/i;
    var vcv_review_re = /\s*(.*)\s*/i;

    var domInfo = {
      spreadsheet: SPREADSHEET_ID,
      scv_range: SCV_RANGE,
      vcv_range: VCV_RANGE,
      vcv : "",
      name : "",
      variation_id : "",
      vcv_interp : "",
      vcv_review : "",
      vcv_eval_date : "",
      row: []
    };
    domInfo.vcv  = document.querySelectorAll('.variant-box dd')[4].innerText;
    domInfo.name = document.querySelectorAll('#id_first h4')[0].innerText;
    domInfo.variation_id = document.querySelectorAll('.variant-box dd')[5].innerText;
    domInfo.vcv_interp = document.querySelectorAll('.variant-box dd')[0].innerText.match(vcv_interp_re)[1];
    domInfo.vcv_review = document.querySelectorAll('.variant-box dd')[1].innerText.match(vcv_review_re)[1];
    domInfo.vcv_eval_date = document.querySelectorAll('.variant-box dd')[3].innerText;
    var scvarray = document.querySelectorAll('#assertion-list tbody tr')
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
            subm_date : subm_scv_match[4],
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
