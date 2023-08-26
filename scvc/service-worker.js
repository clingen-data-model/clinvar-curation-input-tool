// Create a rule that will show the page action when the conditions are met.
const kMatchRule = {
    // Declare the rule conditions.
    conditions: [new chrome.declarativeContent.PageStateMatcher({
        pageUrl: {
            hostEquals: 'www.ncbi.nlm.nih.gov',
            pathContains: 'variation'
        }
    })],
    // Shows the page action when the condition is met.
    actions: [new chrome.declarativeContent.ShowPageAction()]
}

// Register the runtime.onInstalled event listener.
chrome.runtime.onInstalled.addListener(function() {
    // Overrride the rules to replace them with kMatchRule.
    chrome.declarativeContent.onPageChanged.removeRules(undefined, function() {
        chrome.declarativeContent.onPageChanged.addRules([kMatchRule]);
    });
});

const base_url = 'https://sheets.googleapis.com/v4/spreadsheets'
const options = 'valueInputOption=USER_ENTERED&includeValuesInResponse=true'

// Listen for messages from popup.js
chrome.runtime.onMessage.addListener(
    function(request, sender, sendResponse) {

        // console.log('=====SERVICE-WORKER recieved runtime message BEFORE', sender)
        // verify that the request originated from the chrome-extension popup.html form
        if (!sender.url.includes("chrome-extension")) return false;

        // console.log('=====SERVICE-WORKER recieved runtime message AFTER', sender)

        // Get the users email
        chrome.identity.getProfileUserInfo(function(userinfo) {
            if (!userinfo.email) {
                console.log("No email captured. Please set your browser profile to sync with your google account to bypass this message in the future.");
            } else {
                request.user_email = userinfo.email;
            }
        });

        // Get the token
        chrome.identity.getAuthToken({
            interactive: true
        }, function(token) {

            let body = {};
            let range = "";
            let spreadsheet_id = request.spreadsheet;

            if (request.scv) {
                range = request.scv_range;
                body = {
                    values: [
                        [
                            request.vcv,
                            request.name,
                            request.scv,
                            request.submitter,
                            request.interp,
                            request.action,
                            request.reason,
                            request.notes,
                            new Date(), // Timestamp
                            request.submitter_id,
                            request.variation_id,
                            request.user_email
                            // request.override_field,
                            // request.override_value
                        ]
                    ]
                };
            // } else {
            //     range = request.vcv_range;
            //     body = {
            //         values: [
            //             [
            //                 request.vcv,
            //                 request.name,
            //                 request.vcv_interp,
            //                 request.action,
            //                 request.reason,
            //                 request.notes,
            //                 new Date(), // Timestamp
            //                 request.variation_id,
            //                 request.user_email
            //                 // request.override_field,
            //                 // request.override_value
            //             ]
            //         ]
            //     };
            }

            const url = `${base_url}/${spreadsheet_id}/values/${range}:append?${options}`;
            // console.log("===== URL", url);

            // Manifest V3 migration requires using fetch.
            // Three steps to using fetch.
            // 1. Call fetch with the URL
            // 2. Get the response object returned asynchronously by step 1
            //    as the HTTP response begins to arrive, and when ok, get the
            //    body of the response
            // 3. Get the body that is returned asynchronously and process.
            fetch(url, {
                    method: 'POST',
                    headers: {
                        'Authorization': `Bearer ${token}`,
                        'content-type': 'application/json',
                    },
                    body: JSON.stringify(body)
                }).then(response => {
                    // Here, the response promise may not be fully resolved
                    // it may not have the body, just headers and status
                    // response.ok is truthy when status between 200-299
                    if (response.ok) {
                        return response.json();
                    } else {
                        throw new Error(`Unsuccessful status returned from server: ${response.status}`);
                    }
                }).then(results => {
                    // Here, the response.json() promise is fully resolved
                    var message = `${results.updates.updatedCells} cells appended.`;
                    console.log(message);
                    sendResponse({
                        success: true,
                        messsage: message
                    });
                })
                .catch(error => {
                    console.log('error appending values', error, url)
                    sendResponse({
                        success: false,
                        message: error.message
                    });
                });
        });

        return true;
    });
