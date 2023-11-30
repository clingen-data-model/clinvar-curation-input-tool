// Update the relevant fields with the new data.

function setDOMInfo(info) {

  chrome.storage.local.set({'vcvdata': JSON.stringify(info)});

  document.getElementById('vcv').value = info.vcv;
  document.getElementById('vcv_interp').value = info.vcv_interp;
  document.getElementById('vcv_review').value = info.vcv_review;
  document.getElementById('vcv_eval_date').value = info.vcv_eval_date;
  document.getElementById('vcvid').innerText = info.vcv;
  document.getElementById('name').innerText = info.name;
  document.getElementById('variant_name').value = info.name;
  document.getElementById('variation_id').value = info.variation_id;
  document.getElementById('spreadsheet').value = info.spreadsheet;
  document.getElementById('scv_range').value = info.scv_range;
  document.getElementById('vcv_range').value = info.vcv_range;
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
        scv_range: document.getElementById("scv_range").value,
        vcv_range: document.getElementById("vcv_range").value,
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
        vcv_interp: document.getElementById("vcv_interp").value
      }

      if (!data.scv) {
        alert("An SCV selection is required. Please select one from the dropdown before submitting.");
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

      var selectedRow = {
        submitter : "<i>no submitter selected</i>",
        scv       : "",
        subm_date : "",
        submitter_id : "",
        origin    : "<i>origin</i>",
        review    : "<i>rev stat</i>",
        method    : "<i>method</i>",
        interp    : "<i>interp</i>",
        eval_date : "<i>eval dt</i>",
        vcv_interp    : "<i>interp</i>",
        vcv_eval_date : "<i>eval dt</i>",
        vcv_review    : "<i>vcv rev stat</i>"
      };

      var selectedVal = document.getElementById("scvselect").value;

      if ( !selectedVal ) {
        document.getElementById('scvdisplay').classList.add("text-muted");
        document.getElementById('scvdisplay').classList.remove("d-none");
        document.getElementById('vcvdisplay').classList.add("text-muted");
        document.getElementById('vcvdisplay').classList.add("d-none");
        document.getElementById('action').disabled = true;
        document.getElementById('action').value = "";
        document.getElementById('reason').disabled = true;
        document.getElementById('reason').value = "";
        document.getElementById('notes').readOnly = true;
        document.getElementById('notes').value = "";
        document.getElementById('non-contrib-opt').disabled = false;
      }
      else {
        let scvRow = domInfo.row[parseInt(selectedVal)];
        selectedRow.submitter = scvRow.submitter;
        selectedRow.scv = scvRow.scv;
        selectedRow.subm_date = scvRow.subm_date;
        selectedRow.submitter_id = scvRow.submitter_id;
        selectedRow.origin = scvRow.origin;
        selectedRow.review = scvRow.review;
        selectedRow.method = scvRow.method;
        selectedRow.interp = scvRow.interp;
        selectedRow.eval_date = scvRow.eval_date;
        document.getElementById('scvdisplay').classList.remove("text-muted");
        document.getElementById('scvdisplay').classList.remove("d-none");
        document.getElementById('vcvdisplay').classList.add("text-muted");
        document.getElementById('vcvdisplay').classList.add("d-none");
        document.getElementById('action').disabled = false;
        document.getElementById('action').value = "";
        document.getElementById('reason').disabled = true;
        document.getElementById('reason').value = "";
        document.getElementById('notes').readOnly = false;
        document.getElementById('notes').value = "";
        document.getElementById('non-contrib-opt').disabled = false;
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
      document.getElementById('vcv_interp').value = selectedRow.vcv_interp;
      document.getElementById('vcv_interp_ro').innerHTML = selectedRow.vcv_interp;
      document.getElementById('vcv_review').value = selectedRow.vcv_review;
      document.getElementById('vcv_review_ro').innerHTML = selectedRow.vcv_review;
      document.getElementById('vcv_eval_date').value = selectedRow.vcv_eval_date;
      document.getElementById('vcv_eval_date_ro').innerHTML = selectedRow.vcv_eval_date;
    });
  });

  document.getElementById("action").addEventListener("change", function() {

    var nonContribtoryReasonOptions = {
      'Submission errors': [
        'New submission from submitter that appears to have been intended to update this older submission',
        'Other submission error'],
      'Unnecessary Conflicting or Case-level Interpretation Submissions': [
        'Clinical significance appears to be a case-level interpretation inconsistent with variant classification',
        'Unnecessary conflicting claim for distinct condition when other classifications are more relevant'],
      'Old/Outlier/Unsupported Submissions': [
        'Older claim that does not account for recent evidence',
        'Claim with insufficient supporting evidence',
        'Outlier claim with insufficient supporting evidence',
        'Conflicts with expert reviewed submission without evidence to support different classification']
    };
    var reasonsByAction = {
      'Flagging Candidate': nonContribtoryReasonOptions
    };

    function setReasonsByAction(action) {
      var reason = document.getElementById('reason');

      // reset
      reason.innerHTML = "";
      var opt1 = document.createElement("option");
      opt1.text = 'Choose...';
      opt1.value = "";
      opt1.selected = true;
      reason.add( opt1 );

      //loop through reasonsByAction and add options reason selector
      if (reasonsByAction[action])
        Object.entries(reasonsByAction[action]).forEach( addOptGroup );

      // add "other"
      var opt2 = document.createElement("option");
      opt2.text = "Other";
      opt2.value = "Other";
      reason.add( opt2 );

      function addOptGroup(grp, index) {
        var optgroup;

        if (grp[0]) {
          optgroup = document.createElement("optgroup");
          optgroup.label = grp[0];
          reason.add( optgroup );
        }

        for (let i = 0; i < grp[1].length; i++) {
          var option = document.createElement("option");
          option.text = grp[1][i];
          option.value = grp[1][i];
          if (optgroup)
            optgroup.appendChild( option );
          else
            reason.add( option );
        }
      }
    }

    var selectedVal = document.getElementById("action").value;

    /* populate reason list according to action */
    setReasonsByAction(selectedVal);

    if ( selectedVal != "" ) {
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
            alert("reload tab, connection lost\n"+chrome.runtime.lastError.message);
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
