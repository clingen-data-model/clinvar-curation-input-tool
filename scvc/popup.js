const spreadsheet_id = '1HVQgZ_uGkzaazgIgz86h-5H-oEfHFFllwqT5jJbw6Do'; // copy of production

function setClinVarData(data) {

    // Save the data to local storage for use by async functions
    chrome.storage.local.set({
        'vcvdata': JSON.stringify(data)
    });

    document.getElementById('vcv').value = data.vcv;
    document.getElementById('vcv_interp').value = data.vcv_interp;
    document.getElementById('vcv_review').value = data.vcv_review;
    document.getElementById('vcv_eval_date').value = data.vcv_eval_date;
    document.getElementById('vcvid').textContent = data.vcv;
    document.getElementById('name').textContent = data.name;
    document.getElementById('variant_name').value = data.name;
    document.getElementById('variation_id').value = data.variation_id;
    document.getElementById('spreadsheet').value = data.spreadsheet;
    document.getElementById('scv_range').value = data.scv_range;
    document.getElementById('vcv_range').value = data.vcv_range;

    function truncateString(str, num) {
        if (str.length <= num) {
            return str
        }
        return str.slice(0, num) + '...'
    }

    var scvselect = document.getElementById("scvselect");

    //loop through scvs and add to scvselector
    data.row.forEach( addOptions );

    function addOptions(row, index) {
        var option = document.createElement("option");
        option.text = row.scv + " (" + row.interp + ") " + truncateString(row.submitter, 15);
        option.value = index;
        scvselect.add(option);
    }
};

function extractAnnotation() { 
    const data = {
        spreadsheet: document.getElementById("spreadsheet").value,
        scv_range: document.getElementById("scv_range").value,
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
        vcv_interp: document.getElementById("vcv_interp").value,
        review_status: document.getElementById("review").value
      }

      if (!data.scv) {
        return {success: false, error: "An SCV selection is required."};
      }

      if (!data.action) {
        return {success: false, error: "An action is required."};
      }

      if (data.action != "No Change" && !data.reason) {
        return {success: false, error: `A reason is required for a '{data.action}' annotation.`};
      }

      return {success: true, data: data};
}

document.addEventListener("DOMContentLoaded", async () => {

    // Save button functionality
    const saveButton = document.getElementById("save-annotation");
    saveButton.addEventListener("click", async (event) => {
        // prevent form default behavior which will refresh the page and prevent the script from completing (window.close() will not get run)
        event.preventDefault();

        const result = extractAnnotation();
        
        if (!result.success) {
            alert(`${result.error}`);
            return;
        }
       
        // send message to background.js
        chrome.runtime.sendMessage(
            {
                from: 'popup',
                subject: 'saveAnnotation',
                data: result.data
            },
            (response) => {
                if (response && response.success) {
                    console.log('===== POPUP.js saveAnnotation response successful:', response, new Date().getTime());
                    window.close();
                }
                else {
                    console.error('===== POPUP.js saveAnnotation response unsuccessful:', (response ? response.message : "Unknown error"), new Date().getTime());
                    alert(`Failed to save annotation: ${response.message}`);
                }
            }
        );
    });

    const scvPicker = document.getElementById("scvselect");
    scvPicker.addEventListener("change", () => {
        // console.log('=====POPUP.JS scvselect event listener:', new Date().getTime())
        chrome.storage.local.get("vcvdata", (result) => {
            data = JSON.parse(result.vcvdata);

            var selectedRow = {
                submitter: "<i>no submitter selected</i>",
                scv: "",
                subm_date: "",
                submitter_id: "",
                origin: "<i>origin</i>",
                review: "<i>rev stat</i>",
                method: "<i>method</i>",
                interp: "<i>interp</i>",
                eval_date: "<i>eval dt</i>",
                vcv_interp: "<i>interp</i>",
                vcv_eval_date: "<i>eval dt</i>",
                vcv_review: "<i>vcv rev stat</i>"
            };

            var selectedVal = document.getElementById("scvselect").value;

            if (!selectedVal) {
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
                let scvRow = data.row[parseInt(selectedVal)];
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

    const actionPicker = document.getElementById("action");
    actionPicker.addEventListener("change", () => {

        var flaggingCandidateReasonOptions = {
            'Submission errors': [
                'New submission from submitter that appears to have been intended to update this older submission',
                'Other submission error'],
            'Unnecessary Conflicting or Case-level Interpretation Submissions': [
                'Clinical significance appears to be a case-level interpretation inconsistent with variant classification',
                'Unnecessary conflicting claim for distinct condition when other classifications are more relevant'],
            'Old/Outlier/Unsupported Submissions': [
                'Older and outlier claim with insufficient supporting evidence',
                'Older claim that does not account for recent evidence',
                'Claim with insufficient supporting evidence',
                'Outlier claim with insufficient supporting evidence',
                'Conflicts with expert reviewed submission without evidence to support different classification',
                'P/LP classification for a variant in a gene with insufficient evidence for a gene-disease relationship']
        };
        var flaggedSubmissionReasonOptions = {
            '': [
                'Other SCVs submitted for VCV record',
                'Gene-disease relationship classification has changed',
                'Discussion with submitter',
                'Curation error'
            ]
        };
        var reasonsByAction = {
            'Flagging Candidate': flaggingCandidateReasonOptions,
            'Remove Flagged Submission': flaggedSubmissionReasonOptions,
        };

        function setReasonsByAction(action) {
            var reason = document.getElementById('reason');

            // reset
            reason.innerHTML = "";
            var opt1 = document.createElement("option");
            opt1.text = 'Choose...';
            opt1.value = "";
            opt1.selected = true;
            reason.add(opt1);

            //loop through reasonsByAction and add options reason selector
            if (reasonsByAction[action])
                Object.entries(reasonsByAction[action]).forEach(addOptGroup);

            // add "other"
            var opt2 = document.createElement("option");
            opt2.text = "Other";
            opt2.value = "Other";
            reason.add(opt2);

            function addOptGroup(grp, index) {
                var optgroup;

                if (grp[0]) {
                    optgroup = document.createElement("optgroup");
                    optgroup.label = grp[0];
                    reason.add(optgroup);
                }

                for (let i = 0; i < grp[1].length; i++) {
                    var option = document.createElement("option");
                    option.text = grp[1][i];
                    option.value = grp[1][i];
                    if (optgroup)
                        optgroup.appendChild(option);
                    else
                        reason.add(option);
                }
            }
        }

        var selectedVal = document.getElementById("action").value;

        /* populate reason list according to action */
        setReasonsByAction(selectedVal);

        if (selectedVal != "") {
            document.getElementById('reason').disabled = false;
        } else {
            document.getElementById('reason').disabled = true;
            document.getElementById('reason').value = "";
        }
        return true;
    });

    // // ...query for the active tab...
    const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
    chrome.tabs.sendMessage(
        tab.id,
        {
            from: "popup",
            subject: "initializePopup"
        },
        (response) => {
            if (chrome.runtime.lastError) {
                console.log('===== POPUP.js initializePopup response unsuccessful:', chrome.runtime.lastError.message, new Date().getTime());
                return;
            }

            if (response) {
                setClinVarData(response);
            }
            else {
                console.error('===== POPUP.js initializePopup response missing!', new Date().getTime());
            }
        }    
    );
});

