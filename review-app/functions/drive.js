// drive.js — thin, injected Google Drive writer for submission files. The
// `drive` client (googleapis drive_v3) is injected so the orchestration
// (trash any same-name file in the target folder, then create) unit-tests with
// a fake — the wiring (real client + auth) is deploy-time.
//
// Non-impact: writes ONLY to the configured folder id, which pre-cutover is a
// SEPARATE dev folder (never the live submission folder), and the filenames are
// `v4-DEV-` prefixed (see submission.js), so it cannot touch or shadow live
// submission files. Always `supportsAllDrives` — the target is a Shared Drive
// the Functions runtime SA must be a member of (see review-app/README.md).
function makeDriveWriter(drive) {
  return {
    async writeNdjson({ folderId, filename, content }) {
      if (!folderId) throw new Error('drive.writeNdjson: folderId required');
      // Trash any existing same-name file so re-generate is idempotent (scoped
      // to THIS folder — never a name-based sweep of the live folder).
      const safeName = String(filename).replace(/'/g, "\\'");
      const list = await drive.files.list({
        q: `name = '${safeName}' and '${folderId}' in parents and trashed = false`,
        fields: 'files(id)', supportsAllDrives: true, includeItemsFromAllDrives: true
      });
      for (const f of (list.data.files || [])) {
        await drive.files.update({ fileId: f.id, requestBody: { trashed: true }, supportsAllDrives: true });
      }
      const created = await drive.files.create({
        requestBody: { name: filename, parents: [folderId], mimeType: 'application/json' },
        media: { mimeType: 'application/json', body: content },
        fields: 'id, webViewLink', supportsAllDrives: true
      });
      return { id: created.data.id, link: created.data.webViewLink };
    },

    // List non-trashed files in the folder whose name matches a prefix (the
    // per-batch submission-file stem). Newest first.
    async listFiles({ folderId, namePrefix }) {
      if (!folderId) throw new Error('drive.listFiles: folderId required');
      const safe = String(namePrefix || '').replace(/'/g, "\\'");
      const q = `'${folderId}' in parents and trashed = false`
        + (namePrefix ? ` and name contains '${safe}'` : '');
      const list = await drive.files.list({
        q, orderBy: 'createdTime desc',
        fields: 'files(id, name, webViewLink, createdTime)',
        supportsAllDrives: true, includeItemsFromAllDrives: true
      });
      return (list.data.files || []).map((f) => ({ id: f.id, name: f.name, link: f.webViewLink, createdTime: f.createdTime }));
    },

    // Fetch a file's name (used to enforce the finalized-file delete guard).
    async getName({ fileId }) {
      const f = await drive.files.get({ fileId, fields: 'name', supportsAllDrives: true });
      return f.data.name;
    },

    // Trash a file (reversible). Scoped by fileId; the caller enforces which
    // files may be trashed (never the finalized submission file).
    async trashFile({ fileId }) {
      await drive.files.update({ fileId, requestBody: { trashed: true }, supportsAllDrives: true });
      return { trashed: fileId };
    }
  };
}

module.exports = { makeDriveWriter };
