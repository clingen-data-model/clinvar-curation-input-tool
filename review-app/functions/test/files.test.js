import { describe, it, expect } from 'vitest';
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { makeFilesHandler } = require('../files.js');
const { submissionFilePrefix } = require('../submission.js');

// A fake drive capturing calls + a small in-memory folder.
function fakeDrive(files) {
  const trashed = [];
  return {
    trashed,
    async listFiles({ namePrefix }) { return files.filter((f) => f.name.startsWith(namePrefix)); },
    async getName({ fileId }) { return (files.find((f) => f.id === fileId) || {}).name; },
    async trashFile({ fileId }) { trashed.push(fileId); return { trashed: fileId }; }
  };
}
const FINAL = 'v4-DEV-clinvar-annotation-submission-135-20260807.json';
const DRAFT1 = 'v4-DEV-clinvar-annotation-submission-135-20260805.json';
const DRAFT2 = 'v4-DEV-clinvar-annotation-submission-135-20260806.json';
const OTHER = 'v4-DEV-clinvar-annotation-submission-999-20260806.json';
const files = [
  { id: 'a', name: DRAFT1, link: 'L1' }, { id: 'b', name: DRAFT2, link: 'L2' },
  { id: 'c', name: FINAL, link: 'L3' }, { id: 'z', name: OTHER, link: 'LZ' }
];

describe('submissionFilePrefix', () => {
  it('is the per-batch stem before the date (env-prefixed for dev)', () => {
    expect(submissionFilePrefix({ batchId: '135', env: 'dev' })).toBe('v4-DEV-clinvar-annotation-submission-135-');
    expect(submissionFilePrefix({ batchId: '135', env: 'prod' })).toBe('clinvar-annotation-submission-135-');
  });
});

describe('makeFilesHandler', () => {
  const mk = () => {
    const drive = fakeDrive(files);
    const h = makeFilesHandler({ drive, folderId: 'F', env: 'dev', getFinalizedName: async () => FINAL });
    return { drive, h };
  };

  it('list returns only THIS batch\'s files, flagging the finalized one as protected', async () => {
    const { h } = mk();
    const out = await h.list({ batchId: '135' });
    expect(out.map((f) => f.name).sort()).toEqual([DRAFT1, DRAFT2, FINAL].sort()); // not OTHER (batch 999)
    expect(out.find((f) => f.name === FINAL).protected).toBe(true);
    expect(out.find((f) => f.name === DRAFT1).protected).toBe(false);
  });

  it('remove trashes a draft', async () => {
    const { drive, h } = mk();
    await h.remove({ fileId: 'a' });
    expect(drive.trashed).toEqual(['a']);
  });

  it('remove REFUSES the finalized file', async () => {
    const { drive, h } = mk();
    await expect(h.remove({ fileId: 'c' })).rejects.toThrow(/finalized/);
    expect(drive.trashed).toEqual([]); // nothing trashed
  });

  it('removeDrafts trashes every batch draft but keeps the finalized file', async () => {
    const { drive, h } = mk();
    const out = await h.removeDrafts({ batchId: '135' });
    expect(drive.trashed.sort()).toEqual(['a', 'b']); // drafts only, not 'c' (final) or 'z' (other batch)
    expect(out).toEqual({ removed: 2, kept: 1 });
  });
});
