# ClinVar Extension Testing

This directory contains testing utilities for the ClinVar Chrome Extension content extraction functionality.

## Purpose

The Chrome extension frequently breaks when ClinVar updates their HTML structure. This testing framework allows you to:

1. **Save HTML snapshots** of ClinVar pages before and after UI changes
2. **Test content extraction** against different versions of ClinVar HTML
3. **Identify breaking changes** in regex patterns and XPath selectors
4. **Validate fixes** before deploying extension updates

## Directory Structure

```
testing/
├── html-samples/          # Store ClinVar HTML page snapshots here
├── scripts/               # Testing scripts and utilities
├── package.json          # Node.js dependencies for testing
└── README.md             # This file
```

## Setup

1. Install Node.js dependencies:
```bash
cd testing
npm install
```

2. Add ClinVar HTML samples to the `html-samples/` directory

## Usage

### Adding HTML Samples

1. Navigate to a ClinVar variation page (e.g., `https://www.ncbi.nlm.nih.gov/clinvar/variation/12345/`)
2. Save the complete HTML source as `variation-12345-2023-05-20.html` in `html-samples/`
3. Use descriptive filenames with dates: `variation-{id}-{date}.html`

### Running Tests

Test all HTML samples:
```bash
npm test
```

Test a specific file:
```bash
node scripts/test-content-extraction.js
```

### Test Output

The test runner will show:
- **VCV information**: Accession, variation ID, interpretation, review status
- **SCV details**: Number of submissions found and details of first SCV
- **Errors**: Any extraction failures or missing data

Example output:
```
=== Testing: variation-12345-2023-05-20 ===
File: html-samples/variation-12345-2023-05-20.html

--- Extraction Results ---
VCV: VCV000001234.1
Variation ID: 123456
Name: NM_000001.1(GENE1):c.123C>T (p.Arg41Ter)
VCV Interpretation: Pathogenic
VCV Review Status: criteria provided, multiple submitters, no conflicts
Number of SCVs: 2

--- First SCV Details ---
SCV: SCV000001234.1
Submitter: Example Lab
Interpretation: Pathogenic
Review Status: criteria provided, single submitter
```

## Key Extraction Points

The `extractClinVarData()` function from `content.js` relies on these critical selectors:

### XPath Selectors
- `//div[@class='germline-section']//div[@class='single-item-value']/text()` - VCV interpretation
- `//div[@class='germline-section']//div[@id='germline-stars-icon']/p/text()` - VCV review status
- `//div[@id='new-variant-details']//dl` - Variant details box
- `#variant-details-table div div dl dd p` - Variant name
- `table.timeline-table tbody tr td` - Timeline dates
- `.submissions-germline-list tbody tr.germline-sub-col` - SCV submissions

### Regex Patterns
- `subm_scv_re`: Extracts submitter ID, name, SCV accession, and dates
- `interp_re`: Captures interpretation and evaluation date
- `review_method_re`: Matches review status and method
- `vcv_accession_re` & `vcv_variation_id_re`: Extract VCV identifiers

## Common Failure Points

When ClinVar updates their UI, these elements commonly break:

1. **CSS class names** in XPath selectors
2. **HTML structure** around submission tables
3. **Text patterns** in regex expressions (e.g., "no assertion provided" → "no classification provided")
4. **Timeline table structure** for date extraction

## Troubleshooting

### No Data Extracted
- Check if HTML structure matches expected selectors
- Verify CSS classes haven't changed
- Ensure HTML sample is complete (not just partial page)

### Partial Data Missing
- Compare working vs. broken HTML samples
- Check specific regex patterns against new HTML
- Look for changes in ClinVar terminology

### SCV Table Issues
- Verify `.submissions-germline-list` table structure
- Check cell indexing (cells[0], cells[1], etc.)
- Ensure `germline-sub-col` class still exists

## Best Practices

1. **Save HTML before issues occur** - Capture working versions for comparison
2. **Use descriptive filenames** - Include variation ID and date
3. **Test multiple variants** - Different page structures may expose edge cases
4. **Version control samples** - Keep historical HTML for regression testing
5. **Document UI changes** - Note what changed between versions

## Integration with Extension Development

This testing framework helps identify issues before users encounter them:

1. **Before ClinVar updates**: Save current working HTML samples
2. **After UI changes**: Test existing samples to identify breaks  
3. **During fixes**: Validate regex/XPath updates against samples
4. **Before release**: Ensure all samples pass extraction tests