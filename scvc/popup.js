function setDOMInfo(info) {

    // console.log('=====POPUP.JS setDOMInfo DOMInfo:', info, new Date().getTime())
    chrome.storage.local.set({
        'vcvdata': JSON.stringify(info)
    });

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
    document.getElementById('gsheetlink').href = "https://docs.google.com/spreadsheets/d/" + info.spreadsheet + "/";

    function truncateString(str, num) {
        if (str.length <= num) {
            return str
        }
        return str.slice(0, num) + '...'
    }

    var scvselect = document.getElementById("scvselect");

    //loop through scvs and add to scvselector
    info.row.forEach(addOptions);

    // // add the vcv to the end of the scvselector to support the "no change" VCV annotation
    // var vcvOpt = document.createElement("option");
    // vcvOpt.text = info.vcv + " (" + info.vcv_interp + ")"
    // vcvOpt.value = info.row.length // this should be the last
    // scvselect.add(vcvOpt)

    function addOptions(row, index) {
        var option = document.createElement("option");
        option.text = row.scv + " (" + row.interp + ") " + truncateString(row.submitter, 15);
        option.value = index;
        scvselect.add(option);
    }
};

// Once the DOM is ready...
window.addEventListener('DOMContentLoaded', () => {
    // console.log('=====POPUP.JS DOMContentLoded window listener:', new Date().getTime())
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
            // override_field: document.getElementById("override-field").value,
            // override_value: document.getElementById("override-value").value,
            vcv_interp: document.getElementById("vcv_interp").value
        }

        // ensure that user has selected a vcv or an scv
        if (!document.getElementById("scvselect").value) {
            alert("An SCV/VCV selection is required. Please select one from the dropdown before submitting.");
            // document.getElementById('message').innerText = "SCV must be selected first.";
            return;
        }

        chrome.runtime.sendMessage(data, function(response) {
            if (response.success == false) {
                console.error("Spreadsheet update failed: " + response.message);
                alert("Spreadsheet update failed: " + response.message);
            } else {
                console.log("Spreadsheet update successful: " + response.message);
            }
        });



        // chrome.runtime.sendMessage(data, function(response) {
        //     if (response.success == false) {
        //         console.log("Spreadsheet update failed: " + response.message);
        //         alert("Spreadsheet update failed: " + response.message);
        //     } else {
        //         console.log("Spreadsheet update successful: " + response.message);
        //     }
        // });

        // chrome.runtime.sendMessage(data)
        //     .then((response) => {
        //         if (response.success == false) {
        //             alert("Spreadsheet update failed: " + response.message)
        //         }
        //     });

        // this is the equivalent of window.close().
        // window.close() works when stepping through with the debugger.
        // window.close() does not work when not in the debugger.
        // open(location, '_self').close();
        // setTimeoout(window.close, 2000);
    });

    document.getElementById("scvselect").addEventListener("change", function() {
        // console.log('=====POPUP.JS scvselect event listener:', new Date().getTime())
        chrome.storage.local.get("vcvdata", function(result) {
            domInfo = JSON.parse(result.vcvdata);

            var selectedRow = {
                submitter: "<i>no submitter selected</i>",
                scv: "",
                subm_date: "",
                submitter_id: "",
                condition: "",
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
            var lastSelectVal = document.querySelector('#scvselect option:last-child').value;

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
                // document.getElementById('override-opt').disabled = false;
            // } else if (selectedVal === lastSelectVal) {
            //     selectedRow.vcv_interp = domInfo.vcv_interp;
            //     selectedRow.vcv_eval_date = domInfo.vcv_eval_date;
            //     selectedRow.vcv_review = domInfo.vcv_review;
            //     document.getElementById('scvdisplay').classList.add("text-muted");
            //     document.getElementById('scvdisplay').classList.add("d-none");
            //     document.getElementById('vcvdisplay').classList.remove("text-muted");
            //     document.getElementById('vcvdisplay').classList.remove("d-none");
            //     document.getElementById('action').disabled = false;
            //     document.getElementById('action').value = "";
            //     document.getElementById('reason').disabled = true;
            //     document.getElementById('reason').value = "";
            //     document.getElementById('notes').readOnly = false;
            //     document.getElementById('notes').value = "";
            //     document.getElementById('non-contrib-opt').disabled = true;
            //     // document.getElementById('override-opt').disabled = true;
            } else {
                let scvRow = domInfo.row[parseInt(selectedVal)];
                selectedRow.submitter = scvRow.submitter;
                selectedRow.scv = scvRow.scv;
                selectedRow.subm_date = scvRow.subm_date;
                selectedRow.submitter_id = scvRow.submitter_id;
                selectedRow.condition = scvRow.condition;
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
                // document.getElementById('override-opt').disabled = false;
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
        return true;
    });

    document.getElementById("action").addEventListener("change", function() {
        // console.log('=====POPUP.JS action event listener:', new Date().getTime())
        var nonContribtoryReasonOptions = {
            'Submission errors': [
                'New submission from submitter that appears to have been intended to update this older submission',
                'Other submission error'
            ],
            'Inappropriate submissions': [
                'Clinical significance appears to be a case-level interpretation inconsistent with variant classification'
            ],
            'Unnecessary conflicting submissions': [
                'Unnecessary conflicting claim for distinct condition when other classifications are more relevant'
            ],
            'Lack of contradictory evidence when other submissions show valid evidence': [
                'Older claim that does not account for recent evidence',
                'Claim with insufficient supporting evidence',
                'Outlier claim with insufficient supporting evidence',
                'Conflicts with expert reviewed submission without evidence to support different classification'
            ]
        };
        // var followUpReasonOptions = {
        //     '': [
        //         'Send for submitter review',
        //         'Send for another curator to review',
        //         'Send for VCEP triage',
        //         'Send for VCEP full review'
        //     ]
        // };
        var reasonsByAction = {
            'Non-contributory': nonContribtoryReasonOptions
            // ,
            // 'Follow Up': followUpReasonOptions
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

        // NOTE: commenting out the Override option per rel 1.9.6
        // if ( selectedVal == "Override" ) {
        //   document.getElementById('override-field').disabled = false;
        //   document.getElementById('override-value').disabled = false;
        // }
        // else {
        //   document.getElementById('override-field').disabled = true;
        //   document.getElementById('override-field').value = "";
        //   document.getElementById('override-value').disabled = true;
        //   document.getElementById('override-value').value = "";
        // }

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

    function initializeContent(tabs) {
        tabId = tabs[0].id;
        chrome.tabs.sendMessage(
            tabs[0].id, {
                from: 'popup',
                subject: 'DOMInfo'
            },
            (domInfo) => {
                // console.log('=====POPUP.JS initializeContent DOMInfo:', domInfo, new Date().getTime())
                if (!chrome.runtime.lastError) {
                    // do you work, that's it. No more unchecked error
                    setDOMInfo(domInfo);
                } else {
                    alert("reload tab, connection lost\n" + chrome.runtime.lastError.message);
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
