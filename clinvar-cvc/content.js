// Content script: on an initializePopup message, scrape the current ClinVar page.
// scrape.js is loaded FIRST in the manifest content_scripts, exposing the
// window.extractClinVarData global; under Node/tests we require it instead.

function handleInitializePopup(message, doc) {
  if (message && message.from === 'popup' && message.subject === 'initializePopup') {
    const extract = (typeof window !== 'undefined' && window.extractClinVarData) ||
                    require('./scrape.js').extractClinVarData;
    return extract(doc);
  }
  return null;
}

// Browser wiring (skipped under Node/tests where chrome is a mock without a real page).
if (typeof chrome !== 'undefined' && chrome.runtime && chrome.runtime.onMessage) {
  chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
    const data = handleInitializePopup(message, document);
    if (data !== null) {
      sendResponse(data);
      return true; // async response handled
    }
    return false; // not our message; let other listeners respond
  });
}

if (typeof module !== 'undefined' && module.exports) { module.exports = { handleInitializePopup }; }
