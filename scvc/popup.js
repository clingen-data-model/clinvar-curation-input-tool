// Update the relevant fields with the new data.

function setDOMInfo(info) {

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
        user_email: "",
        override_field: document.getElementById("override-field").value,
        override_value: document.getElementById("override-value").value
      }

      if (!data.scv) {
        alert("An SCV is required. Please select an SCV before submitting.");
        // document.getElementById('message').innerText = "SCV must be selected first.";
        return;
      }

      chrome.runtime.sendMessage(data, function(response) {
        var lastError = chrome.runtime.lastError;
        if (lastError) {
            alert('error...'+lastError.message);
            // 'Could not establish connection. Receiving end does not exist.'
            return;
        }

        alert("message response..."+JSON.stringify(response));
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
        document.getElementById('notes').readOnly = false;
      }
      else {
        selectedRow = { submitter : "<i>none selected</i>", scv    : "", subm_date : "", condition : "",
          origin : "<i>origin</i>", review : "<i>rev stat</i>", method : "<i>method</i>", interp : "<i>interp</i>", eval_date : "<i>eval dt</i>" };
        document.getElementById('scvdisplay').classList.add("text-muted");
        document.getElementById('action').disabled = true;
        document.getElementById('action').value = "";
        document.getElementById('reason').disabled = true;
        document.getElementById('reason').value = "";
        document.getElementById('notes').readOnly = true;
        document.getElementById('notes').value = "";
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

  document.getElementById("action").addEventListener("change", function() {
    var selectedVal = document.getElementById("action").value;

    if ( selectedVal == "Override" ) {
      document.getElementById('override-field').disabled = false;
      document.getElementById('override-value').disabled = false;
    }
    else {
      document.getElementById('override-field').disabled = true;
      document.getElementById('override-field').value = "";
      document.getElementById('override-value').disabled = true;
      document.getElementById('override-value').value = "";
    }

    if ( selectedVal == "Non-contributory" ) {
      document.getElementById('reason').disabled = false;
    }
    else {
      document.getElementById('reason').disabled = true;
      document.getElementById('reason').value = "";
    }

  });

  function initializeContent(tabs) {
    chrome.tabs.sendMessage(
        tabs[0].id,
        {from: 'popup', subject: 'DOMInfo'},
        (domInfo) => {
          if (!chrome.runtime.lastError) {
            // do you work, that's it. No more unchecked error
            setDOMInfo(domInfo);
          } else {
            alert("reload tab, connection lost");
            window.close();
          }
        });
  }

  // ...query for the active tab...
  chrome.tabs.query({
    active: true,
    currentWindow: true
  }, tabs => {
    // ...and send a request for the DOM info...
    initializeContent(tabs);
  });


});
