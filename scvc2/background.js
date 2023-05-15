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
chrome.runtime.onInstalled.addListener(() => {
  // Overrride the rules to replace them with kMatchRule.
  chrome.declarativeContent.onPageChanged.removeRules(undefined, () => {
    chrome.declarativeContent.onPageChanged.addRules([kMatchRule]);
  });
});

// Listen for messages from popup.js
chrome.runtime.onMessage.addListener(
  function(request, sender, sendResponse) {

    // verify that the request originated from the chrome-extension popup.html form
    if (!sender.url.includes("chrome-extension")) return false;

    // Get the users email
    chrome.identity.getProfileUserInfo(function(userinfo){
      if (!userinfo.email) {
        alert("No email captured. Please set your browser profile to sync with your google account to bypass this message in the future.");
      }
      else {
        request.user_email=userinfo.email;
      }
    });

    // Get the token
    chrome.identity.getAuthToken({interactive: true}, function(token) {
      console.log(token);
    });
    
  });


