// Update the relevant fields with the new data.

const setDOMInfo = info => {
  chrome.storage.local.set({'vcvdata': JSON.stringify(info)});

  document.getElementById('vcv').value = info.vcv;
  document.getElementById('vcvid').innerText = info.vcv;
  document.getElementById('name').innerText = info.name;
  document.getElementById('variant_name').value = info.name;
  document.getElementById('variation_id').value = info.variation_id;
  document.getElementById('spreadsheet').value = info.spreadsheet;
  document.getElementById('sheet').value = info.sheet;
  document.getElementById('gsheetlink').href = "https://docs.google.com/spreadsheets/d/"+info.spreadsheet+"/";

  function truncateString(str, num) {
    if (str.length <= num) {
      return str
    }
    return str.slice(0, num) + '...'
  }

  var scvselect = document.getElementById("scvselect");

  //loop through scvs and add to scvselector
  info.row.forEach( addOptions );

  function addOptions(row, index) {
    var option = document.createElement("option");
    option.text = row.scv + " (" +row.interp + ") " + truncateString(row.submitter, 15);
    option.value = index;
    scvselect.add(option);
  }
};

// Once the DOM is ready...
window.addEventListener('DOMContentLoaded', () => {
  document.getElementById("annotations").addEventListener("submit", function() {

      var data = {
        spreadsheet: document.getElementById("spreadsheet").value,
        sheet: document.getElementById("sheet").value,
        vcv: document.getElementById("vcv").value,
        name: document.getElementById("variant_name").value,
        variation_id: document.getElementById("variation_id").value,
        scv: document.getElementById("scv").value,
        submitter: document.getElementById("submitter").value,
        submitter_id: document.getElementById("submitter_id").value,
        interp: document.getElementById("interp").value,
        action: document.getElementById("action").value,
        reason: document.getElementById("reason").value,
        notes: document.getElementById("notes").value,
        user_email: ""
      }
      chrome.runtime.sendMessage(data, function(response) {
        console.log('response', response);
      });
      window.close();
  });

  document.getElementById("scvselect").addEventListener("change", function() {

    chrome.storage.local.get("vcvdata", function(result) {
      domInfo = JSON.parse(result.vcvdata);

      var selectedRow;
      var selectedVal = document.getElementById("scvselect").value;
      if ( selectedVal != "" ) {
        selectedRow = domInfo.row[parseInt(selectedVal)];
        document.getElementById('scvdisplay').classList.remove("text-muted");
        document.getElementById('action').disabled = false;
        document.getElementById('reason').disabled = false;
        document.getElementById('notes').readOnly = false;
      }
      else {
        selectedRow = { submitter : "<i>none selected</i>", scv    : "", subm_date : "", condition : "",
          origin : "<i>origin</i>", review : "<i>rev stat</i>", method : "<i>method</i>", interp : "<i>interp</i>", eval_date : "<i>eval dt</i>" };
        document.getElementById('scvdisplay').classList.add("text-muted");
        document.getElementById('action').disabled = true;
        document.getElementById('reason').disabled = true;
        document.getElementById('notes').readOnly = true;
      }
      document.getElementById('scv').value = selectedRow.scv;
      document.getElementById('interp').value = selectedRow.interp;
      document.getElementById('interp_ro').innerHTML = selectedRow.interp;
      document.getElementById('review').value = selectedRow.review;
      document.getElementById('review_ro').innerHTML = selectedRow.review;
      document.getElementById('submitter').value = selectedRow.submitter;
      document.getElementById('submitter_id').value = selectedRow.submitter_id;
      document.getElementById('submitter_ro').innerHTML = selectedRow.submitter;
      document.getElementById('origin').value = selectedRow.origin;
      document.getElementById('origin_ro').innerHTML = selectedRow.origin;
      document.getElementById('method').value = selectedRow.method;
      document.getElementById('method_ro').innerHTML = selectedRow.method;
      document.getElementById('eval_date').value = selectedRow.eval_date;
      document.getElementById('eval_date_ro').innerHTML = selectedRow.eval_date;
    });
  });

  // ...query for the active tab...
  chrome.tabs.query({
    active: true,
    currentWindow: true
  }, tabs => {
    // ...and send a request for the DOM info...
    chrome.tabs.sendMessage(
        tabs[0].id,
        {from: 'popup', subject: 'DOMInfo'},
        // ...also specifying a callback to be called
        //    from the receiving end (content script).
        setDOMInfo);
  });


});
