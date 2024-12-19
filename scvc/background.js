// Register the runtime.onInstalled event listener.
chrome.runtime.onInstalled.addListener(function() {
  // Overrride the rules to replace them with kMatchRule.
  chrome.declarativeContent.onPageChanged.removeRules(undefined, () => {
      chrome.declarativeContent.onPageChanged.addRules([
        // Create a rule that will show the page action when the conditions are met.
        {
            // Declare the rule conditions.
            conditions: [new chrome.declarativeContent.PageStateMatcher({
                pageUrl: {
                    hostEquals: 'www.ncbi.nlm.nih.gov',
                    pathContains: 'variation'
                }
            })],
            // Shows the page action when the condition is met.
            actions: [new chrome.declarativeContent.ShowAction()]      
        }
    ]);
  });
});

const base_url = 'https://sheets.googleapis.com/v4/spreadsheets'
const options = 'valueInputOption=USER_ENTERED&includeValuesInResponse=true'

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {

    console.log('===== BACKGROUND.js event recieved:', message, new Date().getTime());

    if (message.from === "popup" && message.subject === "saveAnnotation") {

        const data = message.data;

        // do a sanity validation and fail if the data is not available
        if (!data || !data.scv) {
            sendResponse({ success: false, message: "Annotation data was not available or no SCV was selected." });
            return;
        }

        // Get the users email
        chrome.identity.getProfileUserInfo( (userinfo) =>{
            if (!userinfo.email) {
                const msg = "No email captured. Please set your browser profile to sync with your google account to save annotations.";
                console.log('===== BACKGROUND.js event pre-sendResponse on user email not available.', msg, new Date().getTime());
                sendResponse({ success: false, message: msg });
                return;
            }
            else {
                data.user_email = userinfo.email;
            }
        });

        try {
            chrome.identity.getAuthToken({ interactive: true }, (token) => {
                if (chrome.runtime.lastError) {
                    console.log('===== BACKGROUND.js event pre-sendResponse on lastError: msg:', chrome.runtime.lastError.message, new Date().getTime());
                    sendResponse({ success: false, message: chrome.runtime.lastError.message });
                    return;
                }
                const url = `${base_url}/${data.spreadsheet}/values/${data.scv_range}:append?${options}`;
                const body = {
                    values: [[
                        data.vcv,
                        data.name,
                        data.scv,
                        data.submitter,
                        data.interp,
                        data.action,
                        data.reason,
                        data.notes,
                        new Date(), // Timestamp
                        data.submitter_id,
                        data.variation_id,
                        data.user_email,
                        data.review_status
                    ]]
                };

                fetch(url, {
                    method: 'POST',
                    headers: {
                        'Authorization': `Bearer ${token}`,
                        'Content-Type': 'application/json'
                    },
                    body: JSON.stringify(body)
                }).then(response => {
                    if (response.ok) {
                        return response.json();
                    } else {
                        throw new Error(`Server error: ${response.status}`);
                    }
                }).then(results => {
                    console.log('===== BACKGROUND.js event pre-sendResponse on url fetch success.', new Date().getTime());
                    sendResponse({ success: true, message: `${results.updates.updatedCells} cells appended.` });
                }).catch(error => {
                    console.log('===== BACKGROUND.js event pre-sendResponse on url fetch failure:', error.message, new Date().getTime());
                    sendResponse({ success: false, message: error.message });
                });
            });
        } catch (error) {
            console.log('===== BACKGROUND.js event pre-sendResponse on error getting auth token', error.message, new Date().getTime());
            sendResponse({ success: false, message: error.message });
        }

        console.log('===== BACKGROUND.js event indicate async response', new Date().getTime());
        return true; // Indicate async response

    }
});


