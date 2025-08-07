const SPREADSHEET_ID = '1dUnmBZSnz3aeB948b7pIq0iT7_FuCDvtv6FXaVsNcOo'; // production
const SCV_RANGE = 'SCVs';

// Only run Chrome extension code in browser environment
if (typeof chrome !== 'undefined' && chrome.runtime) {
    // Inform the background page that
    // this tab should have a page-action.
    chrome.runtime.sendMessage({
        from: 'content',
        subject: 'showPageAction',
    });
}

function getMatch(text, re, grp) {
    var result;
    result = text.match(re);
    if (result === null) {
        return "";
    }
    return result[grp];
}

function extractClinVarData() {

    // Collect the necessary data.
    var cond_origin_re = /\W*Allele origin:.*?(\w+([\,\s]+\w+)*)/is;
    var review_method_re = /(practice guideline|reviewed by expert panel|no assertion provided|no interpretation for the single variant|criteria provided, multiple submitters, no conflicts|criteria provided, single submitter|criteria provided, conflicting interpretations|no assertion criteria provided|no classification provided|Flagged submission).*?Method:.*?([\w\,\s]+)*/is;
    var subm_scv_re = /\W*\/clinvar\/submitters\/(\d+)\/".*?>(.+?)<\/a>.*?Accession:.*?(SCV\d+\.\d+).*?First in ClinVar:\W(\w+\s\d+\,\s\d+).*?Last updated:.*?(\w+\s\d+\,\s\d+)/is;
    var interp_re = /\W*<div.*?<div.*?(\w+([\s\/\-\,]*\w+)*).*?\(([\w\s\,\-]+)\)/is;

    var vcv_accession_re = /Accession:.*?(VCV\d+\.\d+)/is;
    var vcv_variation_id_re = /Variation ID:.*?(\d+)/is;

    var clinvarData = {
        spreadsheet: SPREADSHEET_ID,
        scv_range: SCV_RANGE,
        vcv: "",
        name: "",
        variation_id: "",
        vcv_interp: "",
        vcv_review: "",
        vcv_most_recent: "",
        vcv_eval_date: "",
        row: []
    };

    var vcvClassificationText = document.evaluate("//div[@class='germline-section']//div[@class='single-item-value']/text()", document, null, XPathResult.STRING_TYPE, null).stringValue.trim();
    var vcvReviewStatus = document.evaluate("//div[@class='germline-section']//div[@id='germline-stars-icon']/p/text()", document, null, XPathResult.STRING_TYPE, null).stringValue.trim();
    vcvReviewStatus = vcvReviewStatus.replace(/\.$/g, '');

    var variantBox = document.evaluate("//div[@id='new-variant-details']//dl", document, null, XPathResult.ANY_TYPE, null );
    var variantBoxHTML = variantBox.iterateNext().innerHTML;

    // Extract variant name with fallback logic
    console.log('\n=== Extracting Variant Name ===');
    var nameElements = document.querySelectorAll('#variant-details-table div div dl dd p');
    console.log(`Name selector found ${nameElements.length} elements`);
    
    if (nameElements.length > 0) {
        clinvarData.name = nameElements[0].innerText || nameElements[0].textContent || "";
        console.log(`Extracted name from element 0: "${clinvarData.name}"`);
        
        // If first element is empty, try other elements
        if (!clinvarData.name && nameElements.length > 1) {
            for (let i = 1; i < nameElements.length; i++) {
                const altName = nameElements[i].innerText || nameElements[i].textContent || "";
                if (altName.trim()) {
                    clinvarData.name = altName.trim();
                    console.log(`Found name in element ${i}: "${clinvarData.name}"`);
                    break;
                }
            }
        }
    } else {
        // Try alternative name extraction
        console.log('Attempting alternative name extraction...');
        
        // Try the blue box title
        var titleElement = document.querySelector('.usa-color-primary-darker h2');
        if (titleElement) {
            clinvarData.name = titleElement.innerText || titleElement.textContent || "";
            console.log(`Alternative name found in title: "${clinvarData.name}"`);
        }
        
        // Try variant identifiers section
        if (!clinvarData.name) {
            var identifierElements = document.querySelectorAll('#variant-details-table dd p');
            if (identifierElements.length > 0) {
                clinvarData.name = identifierElements[0].innerText || identifierElements[0].textContent || "";
                console.log(`Alternative name found in identifiers: "${clinvarData.name}"`);
            }
        }
    }
    
    console.log(`Final extracted name: "${clinvarData.name}"`);
    clinvarData.vcv             = getMatch(variantBoxHTML, vcv_accession_re, 1);
    clinvarData.variation_id    = getMatch(variantBoxHTML, vcv_variation_id_re, 1);
    clinvarData.vcv_review      = vcvReviewStatus;
    clinvarData.vcv_interp      = vcvClassificationText;

    var timelineArray = document.querySelectorAll('table.timeline-table tbody tr td');
    clinvarData.vcv_most_recent = timelineArray.length > 2 ? timelineArray[2].innerHTML : "";
    clinvarData.vcv_eval_date   = timelineArray.length > 3 ? timelineArray[3].innerHTML : "";
    

    var scvarray = document.querySelectorAll('.submissions-germline-list tbody tr.germline-sub-col');
    scvarray.forEach(myFunction);

    function myFunction(value, index, array) {
        console.log(`\n=== Processing SCV Row ${index + 1} ===`);
        
        // Log cell structure for debugging
        console.log(`Row has ${value.cells.length} cells`);
        for (let i = 0; i < value.cells.length; i++) {
            const cellPreview = value.cells[i].innerHTML.substring(0, 150);
            console.log(`Cell ${i}: ${cellPreview}...`);
        }
        
        var interp_match = value.cells[0].innerHTML.match(interp_re);
        var review_method_match = value.cells[1].innerHTML.match(review_method_re);
        var cond_origin_match = value.cells[2].innerHTML.match(cond_origin_re);
        var subm_scv_match = value.cells[3].innerHTML.match(subm_scv_re);

        console.log(`Regex match results:`);
        console.log(`  interp_match: ${interp_match ? 'FOUND' : 'MISSING'}`);
        console.log(`  review_method_match: ${review_method_match ? 'FOUND' : 'MISSING'}`);
        console.log(`  cond_origin_match: ${cond_origin_match ? 'FOUND' : 'MISSING'}`);
        console.log(`  subm_scv_match: ${subm_scv_match ? 'FOUND' : 'MISSING'}`);

        // Extract data with fallback logic
        var extractedData = {
            submitter_id: "",
            submitter: "",
            scv: "",
            subm_date: "",
            origin: "",
            review: "",
            method: "",
            interp: "",
            eval_date: ""
        };

        // Extract interpretation data
        if (interp_match) {
            extractedData.interp = interp_match[1] || "";
            extractedData.eval_date = interp_match[3] || "";
            console.log(`  Extracted interp: "${extractedData.interp}", eval_date: "${extractedData.eval_date}"`);
        } else {
            // Try alternative extraction for interpretation
            console.log(`  Attempting alternative interpretation extraction...`);
            var altInterpMatch = value.cells[0].innerHTML.match(/<div[^>]*>([^<(]+)/i);
            if (altInterpMatch) {
                extractedData.interp = altInterpMatch[1].trim();
                console.log(`  Alternative interp found: "${extractedData.interp}"`);
            }
            
            // Try to find evaluation date in different format
            var dateMatch = value.cells[0].innerHTML.match(/\(([^)]+)\)/);
            if (dateMatch) {
                extractedData.eval_date = dateMatch[1];
                console.log(`  Alternative eval_date found: "${extractedData.eval_date}"`);
            }
        }

        // Extract review status and method
        if (review_method_match) {
            extractedData.review = review_method_match[1] || "";
            extractedData.method = review_method_match[2] || "";
            console.log(`  Extracted review: "${extractedData.review}", method: "${extractedData.method}"`);
        } else {
            // Try alternative extraction for review status
            console.log(`  Attempting alternative review status extraction...`);
            
            // Look for review status in stars-description div
            var starsDescMatch = value.cells[1].innerHTML.match(/stars-description[^>]*>([^<]+)</);
            if (starsDescMatch) {
                extractedData.review = starsDescMatch[1].trim();
                console.log(`  Alternative review found: "${extractedData.review}"`);
            }
            
            // Method field may not exist in new HTML - set to empty as requested
            extractedData.method = "";
            console.log(`  Method set to empty string (not found in new HTML)`);
        }

        // Extract condition/origin data
        if (cond_origin_match) {
            extractedData.origin = cond_origin_match[1] || "";
            console.log(`  Extracted origin: "${extractedData.origin}"`);
        } else {
            // Try alternative extraction for origin
            console.log(`  Attempting alternative origin extraction...`);
            var altOriginMatch = value.cells[2].innerHTML.match(/Allele origin:[^>]*>([^<]+)/i);
            if (altOriginMatch) {
                extractedData.origin = altOriginMatch[1].trim();
                console.log(`  Alternative origin found: "${extractedData.origin}"`);
            }
        }

        // Extract submitter and SCV data
        if (subm_scv_match) {
            extractedData.submitter_id = subm_scv_match[1] || "";
            extractedData.submitter = subm_scv_match[2] || "";
            extractedData.scv = subm_scv_match[3] || "";
            extractedData.subm_date = subm_scv_match[5] || "";
            console.log(`  Extracted submitter_id: "${extractedData.submitter_id}", submitter: "${extractedData.submitter}", scv: "${extractedData.scv}"`);
        } else {
            // Try alternative extraction for submitter data
            console.log(`  Attempting alternative submitter extraction...`);
            
            // Look for submitter link
            var submitterMatch = value.cells[3].innerHTML.match(/href="\/clinvar\/submitters\/(\d+)\/[^>]*>([^<]+)<\/a>/);
            if (submitterMatch) {
                extractedData.submitter_id = submitterMatch[1];
                extractedData.submitter = submitterMatch[2];
                console.log(`  Alternative submitter found: ID="${extractedData.submitter_id}", name="${extractedData.submitter}"`);
            }
            
            // Look for SCV accession
            var scvMatch = value.cells[3].innerHTML.match(/Accession:\s*(SCV\d+\.\d+)/);
            if (scvMatch) {
                extractedData.scv = scvMatch[1];
                console.log(`  Alternative SCV found: "${extractedData.scv}"`);
            }
            
            // Look for submission date
            var dateMatch = value.cells[3].innerHTML.match(/Last updated:\s*([^<\n]+)/);
            if (dateMatch) {
                extractedData.subm_date = dateMatch[1].trim();
                console.log(`  Alternative subm_date found: "${extractedData.subm_date}"`);
            }
        }

        // Always add the row with whatever data we could extract
        clinvarData.row.push({
            submitter_id: extractedData.submitter_id,
            submitter: extractedData.submitter,
            scv: extractedData.scv,
            subm_date: extractedData.subm_date,
            origin: extractedData.origin,
            review: extractedData.review,
            method: extractedData.method,
            interp: extractedData.interp,
            eval_date: extractedData.eval_date
        });
        
        console.log(`✅ Added SCV row ${index + 1} with SCV: "${extractedData.scv}"`);
    }

    return clinvarData;
}

// Chrome extension message handler - only run in browser environment
if (typeof chrome !== 'undefined' && chrome.runtime) {
    chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
        console.log('===== CONTENT.js event recieved: msg:', message, new Date().getTime())
        if (message.from === "popup" && message.subject === "initializePopup") {
            const data = extractClinVarData();
            console.log('===== CONTENT.js event pre-sendResponse: ', message, data, new Date().getTime())
            sendResponse(data);
        }
        return true; // Required for async responses
    });
}

// Export functions for testing (Node.js environment)
if (typeof module !== 'undefined' && module.exports) {
    module.exports = {
        getMatch,
        extractClinVarData,
        SPREADSHEET_ID,
        SCV_RANGE
    };
}