import { describe, it, expect } from 'vitest';
import { readFileSync } from 'fs';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { assertWriteDataset } = require('../dataset-guard.js');
const here = dirname(fileURLToPath(import.meta.url));
const schemaSql = readFileSync(join(here, '../../sql/00-review-state-schema.sql'), 'utf8');

describe('dataset-guard.assertWriteDataset (write-path guard)', () => {
  it('refuses the live legacy dataset as a write target', () => {
    expect(() => assertWriteDataset('clinvar_curator')).toThrow(/refusing to WRITE/);
  });
  it('allows the v4 shadow datasets (exact match, not substring)', () => {
    expect(assertWriteDataset('clinvar_curator_v4')).toBe('clinvar_curator_v4');
    expect(assertWriteDataset('clinvar_curator_v4_dev')).toBe('clinvar_curator_v4_dev');
  });
});

describe('00-review-state-schema.sql (write targets are tokenized, reads-of-legacy only)', () => {
  // Every CREATE/DROP/INSERT TARGET must be @@DATASET@@ — never a literal
  // clinvar_curator write. Reading FROM clinvar_curator (the snapshot source)
  // is allowed.
  const writeStmts = schemaSql.match(/(?:CREATE TABLE(?: IF NOT EXISTS)?|DROP VIEW(?: IF EXISTS)?|INSERT INTO)\s+`[^`]+`/gi) || [];
  it('has the expected write statements', () => {
    // 3 DROP VIEW + 3 CTAS + cvc_review_state + cvc_review_config + 1 INSERT = 9
    expect(writeStmts.length).toBe(9);
  });
  it('targets ONLY @@DATASET@@ for writes (no literal clinvar_curator write target)', () => {
    for (const s of writeStmts) {
      expect(s, s).toContain('@@DATASET@@');
      expect(/`clingen-dev\.clinvar_curator\./.test(s), `legacy write target: ${s}`).toBe(false);
    }
  });
  it('reads the snapshot source FROM legacy clinvar_curator (allowed)', () => {
    expect(/FROM `clingen-dev\.clinvar_curator\.cvc_clinvar_reviews`/.test(schemaSql)).toBe(true);
  });
});
