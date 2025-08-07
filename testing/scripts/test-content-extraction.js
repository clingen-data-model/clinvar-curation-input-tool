/**
 * Unit tests for scvc/content.js extraction functions
 * This script tests the actual content.js functions against real ClinVar HTML samples
 */

const fs = require('fs');
const path = require('path');
const { JSDOM } = require('jsdom');

// Import the actual content.js functions
const contentScript = require('../../scvc/content.js');
const { getMatch, extractClinVarData, SPREADSHEET_ID, SCV_RANGE } = contentScript;

/**
 * Load HTML file and set up DOM environment for testing
 * @param {string} htmlFilePath - Path to HTML file
 * @returns {object} - JSDOM window and document objects
 */
function setupDOMEnvironment(htmlFilePath) {
    const htmlContent = fs.readFileSync(htmlFilePath, 'utf8');
    const dom = new JSDOM(htmlContent);
    
    // Set up global DOM environment for content.js
    global.document = dom.window.document;
    global.XPathResult = dom.window.XPathResult;
    
    return {
        window: dom.window,
        document: dom.window.document,
        cleanup: () => {
            delete global.document;
            delete global.XPathResult;
        }
    };
}

/**
 * Test the getMatch utility function
 */
function testGetMatch() {
    console.log('\n=== Testing getMatch function ===');
    
    // Test cases for getMatch function
    const testCases = [
        {
            name: 'VCV Accession Match',
            text: 'Accession: VCV000590935.4',
            regex: /Accession:.*?(VCV\d+\.\d+)/is,
            group: 1,
            expected: 'VCV000590935.4'
        },
        {
            name: 'Variation ID Match', 
            text: 'Variation ID: 590935',
            regex: /Variation ID:.*?(\d+)/is,
            group: 1,
            expected: '590935'
        },
        {
            name: 'No Match Case',
            text: 'Random text without pattern',
            regex: /NotFound:.*?(\d+)/is,
            group: 1,
            expected: ''
        }
    ];
    
    let passed = 0;
    let total = testCases.length;
    
    testCases.forEach(testCase => {
        const result = getMatch(testCase.text, testCase.regex, testCase.group);
        const success = result === testCase.expected;
        
        console.log(`  ${success ? '✅' : '❌'} ${testCase.name}: ${success ? 'PASS' : 'FAIL'}`);
        if (!success) {
            console.log(`    Expected: "${testCase.expected}", Got: "${result}"`);
        }
        
        if (success) passed++;
    });
    
    console.log(`\\ngetMatch Tests: ${passed}/${total} passed`);
    return passed === total;
}

/**
 * Test extractClinVarData function against HTML sample
 * @param {string} htmlFilePath - Path to HTML file
 * @param {string} testName - Name of the test
 */
function testExtractClinVarData(htmlFilePath, testName) {
    console.log(`\\n=== Testing: ${testName} ===`);
    console.log(`File: ${htmlFilePath}`);
    
    const { cleanup } = setupDOMEnvironment(htmlFilePath);
    
    try {
        console.log('\\n--- Calling extractClinVarData() ---');
        const result = extractClinVarData();
        
        console.log('\\n--- Extraction Results ---');
        console.log(`VCV: ${result.vcv}`);
        console.log(`Variation ID: ${result.variation_id}`);
        console.log(`Name: ${result.name}`);
        console.log(`VCV Interpretation: ${result.vcv_interp}`);
        console.log(`VCV Review Status: ${result.vcv_review}`);
        console.log(`Most Recent: ${result.vcv_most_recent}`);
        console.log(`Evaluation Date: ${result.vcv_eval_date}`);
        console.log(`Number of SCVs: ${result.row.length}`);
        
        // Detailed SCV analysis
        if (result.row.length > 0) {
            console.log('\\n--- SCV Details ---');
            result.row.forEach((scv, index) => {
                console.log(`  SCV ${index + 1}:`);
                console.log(`    Accession: ${scv.scv}`);
                console.log(`    Submitter: ${scv.submitter}`);
                console.log(`    Submitter ID: ${scv.submitter_id}`);
                console.log(`    Interpretation: ${scv.interp}`);
                console.log(`    Review Status: ${scv.review}`);
                console.log(`    Method: ${scv.method}`);
                console.log(`    Origin: ${scv.origin}`);
                console.log(`    Submission Date: ${scv.subm_date}`);
                console.log(`    Evaluation Date: ${scv.eval_date}`);
            });
        } else {
            console.log('\\n❌ No SCVs extracted - this indicates parsing issues');
        }
        
        // Validation checks
        console.log('\\n--- Validation Results ---');
        const validations = [
            { name: 'VCV extracted', pass: !!result.vcv, value: result.vcv },
            { name: 'Variation ID extracted', pass: !!result.variation_id, value: result.variation_id },
            { name: 'Name extracted', pass: !!result.name, value: result.name },
            { name: 'VCV interpretation extracted', pass: !!result.vcv_interp, value: result.vcv_interp },
            { name: 'VCV review status extracted', pass: !!result.vcv_review, value: result.vcv_review },
            { name: 'Timeline data extracted', pass: !!result.vcv_most_recent && !!result.vcv_eval_date, value: `${result.vcv_most_recent} / ${result.vcv_eval_date}` },
            { name: 'SCV data extracted', pass: result.row.length > 0, value: `${result.row.length} SCVs` },
        ];
        
        let passed = 0;
        validations.forEach(validation => {
            console.log(`  ${validation.pass ? '✅' : '❌'} ${validation.name}: ${validation.pass ? 'PASS' : 'FAIL'} (${validation.value || 'empty'})`);
            if (validation.pass) passed++;
        });
        
        console.log(`\\nOverall: ${passed}/${validations.length} validations passed`);
        
        return {
            testName,
            result,
            validations: {
                passed,
                total: validations.length,
                success: passed === validations.length
            }
        };
        
    } catch (error) {
        console.error('❌ Test failed with error:', error.message);
        console.error('Stack trace:', error.stack);
        return {
            testName,
            result: null,
            error: error.message,
            validations: { passed: 0, total: 0, success: false }
        };
    } finally {
        cleanup();
    }
}

/**
 * Run all tests
 */
function runAllTests() {
    console.log('ClinVar Content.js Unit Tests');
    console.log('=============================');
    console.log(`Testing actual functions from: ${path.resolve(__dirname, '../../scvc/content.js')}`);
    
    // Test utility functions
    const getMatchSuccess = testGetMatch();
    
    // Test HTML extraction
    const htmlSamplesDir = path.join(__dirname, '../html-samples');
    
    if (!fs.existsSync(htmlSamplesDir)) {
        console.log(`\\n❌ No HTML samples directory found: ${htmlSamplesDir}`);
        console.log('Please add HTML files to test against.');
        return;
    }
    
    const htmlFiles = fs.readdirSync(htmlSamplesDir).filter(file => file.endsWith('.html'));
    
    if (htmlFiles.length === 0) {
        console.log(`\\n❌ No HTML files found in: ${htmlSamplesDir}`);
        console.log('Please add ClinVar HTML files to test against.');
        return;
    }
    
    console.log(`\\nFound ${htmlFiles.length} HTML sample(s) to test:\\n`);
    
    const results = [];
    
    htmlFiles.forEach(file => {
        const filePath = path.join(htmlSamplesDir, file);
        const testName = file.replace('.html', '');
        const result = testExtractClinVarData(filePath, testName);
        results.push(result);
    });
    
    // Overall summary
    console.log('\\n\\n=== TEST SUMMARY ===');
    console.log(`getMatch function: ${getMatchSuccess ? 'PASS' : 'FAIL'}`);
    
    let totalValidationsPassed = 0;
    let totalValidations = 0;
    let successfulTests = 0;
    
    results.forEach(result => {
        const status = result.error ? 'ERROR' : 
                      result.validations.success ? 'PASS' : 'PARTIAL';
        
        console.log(`${result.testName}: ${status} (${result.validations.passed}/${result.validations.total} validations)`);
        
        totalValidationsPassed += result.validations.passed;
        totalValidations += result.validations.total;
        
        if (result.validations.success) successfulTests++;
        
        if (result.error) {
            console.log(`  Error: ${result.error}`);
        }
    });
    
    console.log('\\n--- Overall Results ---');
    console.log(`Tests passed: ${successfulTests}/${results.length}`);
    console.log(`Validations passed: ${totalValidationsPassed}/${totalValidations}`);
    console.log(`Success rate: ${totalValidations > 0 ? Math.round((totalValidationsPassed/totalValidations) * 100) : 0}%`);
    
    if (successfulTests === results.length && getMatchSuccess) {
        console.log('\\n🎉 All tests passed!');
    } else {
        console.log('\\n⚠️  Some tests failed - check content.js implementation');
    }
}

// Export for potential use by other test files
module.exports = {
    testGetMatch,
    testExtractClinVarData,
    runAllTests,
    setupDOMEnvironment
};

// Run tests if this script is executed directly
if (require.main === module) {
    runAllTests();
}