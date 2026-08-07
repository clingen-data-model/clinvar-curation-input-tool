import { describe, it, expect } from 'vitest';
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { buildNdjson } = require('../ndjson.js');
const { buildGenerateSql, makeGenerateHandler } = require('../generate.js');

describe('buildNdjson', () => {
  it('joins TO_JSON_STRING rows, each followed by a newline (matches Generate.js)', () => {
    expect(buildNdjson(['{"a":1}', '{"b":true}'])).toBe('{"a":1}\n{"b":true}\n');
  });
  it('preserves JSON booleans/null verbatim (never Yes/No)', () => {
    const line = '{"Is Annotation Outdated":false,"SCV Deleted Release Date":null}';
    expect(buildNdjson([line])).toBe(line + '\n');
  });
  it('empty input → empty string', () => {
    expect(buildNdjson([])).toBe('');
    expect(buildNdjson(null)).toBe('');
  });
});

describe('buildGenerateSql', () => {
  const sql = buildGenerateSql({ dataset: 'clinvar_curator_v4_dev', batchId: '136' });
  it('projects the 13 submission fields (SUBMISSION_FILE_SPEC headers)', () => {
    ['`Variation ID`', 'VCV', '`SCV ID`', '`Submitter ID`', 'Action', 'Reason', 'Notes',
     '`Timestamp`', '`Date Created`', '`ClinVar Release Date`', '`Is Annotation Outdated`',
     '`Is Annotated SCV Deleted`', '`SCV Deleted Release Date`'].forEach((h) => {
      expect(sql, h).toContain(h);
    });
  });
  it('reads cvc_annotations("unreviewed") joined to cvc_review_state on the batch', () => {
    expect(sql).toContain('`clingen-dev.clinvar_curator_v4_dev.cvc_annotations`("unreviewed")');
    expect(sql).toContain('`clingen-dev.clinvar_curator_v4_dev.cvc_review_state` rs ON rs.annotation_id = cvc.annotation_id');
    expect(sql).toContain('WHERE rs.batch_id = "136"');
  });
  it('selects booleans RAW + wraps in TO_JSON_STRING (so JSON emits true/false)', () => {
    expect(sql).toContain('cvc.is_outdated_scv AS `Is Annotation Outdated`');
    expect(sql).toContain('SELECT TO_JSON_STRING(x) AS js FROM x');
  });
  it('never references legacy clinvar_curator + rejects a non-numeric batchId', () => {
    expect(/`clingen-dev\.clinvar_curator\./.test(sql)).toBe(false);
    expect(() => buildGenerateSql({ dataset: 'clinvar_curator_v4_dev', batchId: '1;DROP' })).toThrow(/numeric/);
    expect(() => buildGenerateSql({ dataset: 'clinvar_curator', batchId: '1' })).toThrow(/not an allowed v4/);
  });
});

describe('makeGenerateHandler', () => {
  const config = { dataset: 'clinvar_curator_v4_dev', driveFolderId: 'DEVFOLDER', env: 'dev',
                   recipients: ['a@x.org'], cc: [] };
  it('writes NDJSON to Drive and returns count + link + mailto when rows exist', async () => {
    const calls = {};
    const runQuery = async (sql) => { calls.sql = sql; return [{ js: '{"a":1}' }, { js: '{"a":2}' }]; };
    const writeNdjson = async (args) => { calls.write = args; return { id: 'F', link: 'https://drive/F' }; };
    const out = await makeGenerateHandler({ runQuery, writeNdjson, config })({ batchId: '136', date: '20260807' });
    expect(out.count).toBe(2);
    expect(out.filename).toBe('v4-DEV-clinvar-annotation-submission-136-20260807.json');
    expect(out.link).toBe('https://drive/F');
    expect(calls.write.content).toBe('{"a":1}\n{"a":2}\n');
    expect(out.mailto).toMatch(/^mailto:a@x\.org\?/);
  });
  it('writes nothing and returns count 0 when the batch is empty', async () => {
    let wrote = false;
    const out = await makeGenerateHandler({
      runQuery: async () => [], writeNdjson: async () => { wrote = true; return {}; }, config
    })({ batchId: '999', date: '20260807' });
    expect(out.count).toBe(0);
    expect(out.link).toBeNull();
    expect(wrote).toBe(false);
  });
});
