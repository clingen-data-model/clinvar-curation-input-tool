import { describe, it, expect } from 'vitest';
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { makeDriveWriter } = require('../drive.js');

// Fake drive_v3 client recording calls; returns preset list results.
function fakeDrive(existing) {
  const calls = { list: [], update: [], create: [] };
  return {
    calls,
    files: {
      list: async (args) => { calls.list.push(args); return { data: { files: existing || [] } }; },
      update: async (args) => { calls.update.push(args); return { data: {} }; },
      create: async (args) => { calls.create.push(args); return { data: { id: 'NEW', webViewLink: 'https://drive/NEW' } }; }
    }
  };
}

describe('drive.makeDriveWriter.writeNdjson', () => {
  it('creates the file (supportsAllDrives) and returns id + link', async () => {
    const d = fakeDrive([]);
    const out = await makeDriveWriter(d).writeNdjson({ folderId: 'DEVFOLDER', filename: 'v4-DEV-x.json', content: '{}\n' });
    expect(out).toEqual({ id: 'NEW', link: 'https://drive/NEW' });
    expect(d.calls.create).toHaveLength(1);
    expect(d.calls.create[0].requestBody.parents).toEqual(['DEVFOLDER']);
    expect(d.calls.create[0].supportsAllDrives).toBe(true);
    expect(d.calls.update).toHaveLength(0); // nothing to trash
  });

  it('trashes any existing same-name file first (idempotent re-generate)', async () => {
    const d = fakeDrive([{ id: 'OLD1' }, { id: 'OLD2' }]);
    await makeDriveWriter(d).writeNdjson({ folderId: 'DEVFOLDER', filename: 'v4-DEV-x.json', content: '{}\n' });
    expect(d.calls.update.map((u) => u.fileId)).toEqual(['OLD1', 'OLD2']);
    expect(d.calls.update.every((u) => u.requestBody.trashed === true)).toBe(true);
    // the trash query is scoped to THIS folder — never a global name sweep
    expect(d.calls.list[0].q).toContain("'DEVFOLDER' in parents");
  });

  it('requires a folderId', async () => {
    await expect(makeDriveWriter(fakeDrive([])).writeNdjson({ filename: 'x', content: '{}' }))
      .rejects.toThrow(/folderId required/);
  });
});
