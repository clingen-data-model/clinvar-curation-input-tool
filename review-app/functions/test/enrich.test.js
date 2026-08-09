import { describe, it, expect } from 'vitest';
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { snapshotSql, reshapeSql, stampReleaseSql, debounceTaskId, makeEnricher } = require('../enrich.js');

const DS = 'clinvar_curator_v4_dev';

describe('enrich pure builders', () => {
  it('snapshotSql reads the capture annotations view, dropping document_id', () => {
    const sql = snapshotSql({ captureProject: 'clingen-cvc-dev' });
    expect(sql).toContain('EXCEPT(document_id)');
    expect(sql).toContain('`clingen-cvc-dev.clinvar_cvc_ext.annotations`');
  });
  it('snapshotSql rejects a bad capture project', () => {
    expect(() => snapshotSql({ captureProject: "x`; DROP" })).toThrow(/bad captureProject/);
  });
  it('reshapeSql writes native_v4 (dataset-guarded) from the raw load', () => {
    const sql = reshapeSql({ dataset: DS });
    expect(sql).toContain(`CREATE OR REPLACE TABLE \`clingen-dev.${DS}.cvc_annotations_native_v4\``);
    expect(sql).toContain(`FROM \`clingen-dev.${DS}._annotations_v4_raw\``);
    expect(() => reshapeSql({ dataset: 'clinvar_curator' })).toThrow();
  });
  it('stampReleaseSql sets base_release_date to the current clinvar_ingest release', () => {
    const sql = stampReleaseSql({ dataset: DS });
    expect(sql).toContain('SET base_release_date = (SELECT release_date FROM `clinvar_ingest.release_on`(CURRENT_DATE()))');
  });
  it('debounceTaskId buckets timestamps within a window to the same id (dedup)', () => {
    const w = 90;
    const base = 90 * 1000 * 11;                        // aligned to a bucket start
    const a = debounceTaskId(base, w);
    const b = debounceTaskId(base + 89 * 1000, w);      // same 90s bucket
    const c = debounceTaskId(base + 90 * 1000, w);      // next bucket
    expect(a).toBe(b);
    expect(a).not.toBe(c);
    expect(a).toMatch(/^enrich-\d+$/);
  });
});

describe('makeEnricher.run orchestration order', () => {
  it('runs snapshot → extract → load → reshape → base refresh → stamp', async () => {
    const rec = [];
    const mkClient = (name) => ({
      createQueryJob: async (opts) => {
        rec.push(name + ':' + (opts.query.includes('EXCEPT(document_id)') ? 'snapshot'
          : opts.query.includes('CREATE OR REPLACE TABLE') && opts.query.includes('cvc_annotations_native_v4') ? 'reshape'
          : opts.query.includes('cvc_review_queue_base') ? 'baseRefresh'
          : opts.query.includes('base_release_date') ? 'stamp' : 'other'));
        return [{ getQueryResults: async () => [[]] }];
      },
      dataset: () => ({ table: () => ({
        extract: async () => { rec.push(name + ':extract'); },
        load: async () => { rec.push(name + ':load'); }
      }) })
    });
    const centralBq = mkClient('central');
    const usBq = mkClient('us');
    const bucket = { file: () => ({}), deleteFiles: async () => { rec.push('bucket:clear'); } };
    const enr = makeEnricher({ centralBq, usBq, bucket, config: { captureProject: 'clingen-cvc-dev', dataset: DS, gcsPrefix: 'native_v4_dev' } });
    const out = await enr.run();
    expect(out).toEqual({ ok: true });
    expect(rec).toEqual([
      'central:snapshot', 'bucket:clear', 'central:extract', 'us:load', 'us:reshape', 'us:baseRefresh', 'us:stamp'
    ]);
  });
});
