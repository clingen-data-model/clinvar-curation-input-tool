// Typed client for the auth-guarded /api/** backend (unchanged from the vanilla
// app). Attaches the Firebase ID token; throws on !ok with the backend message.
import { idToken } from './firebase';
import type { Config, QueueRow, HistoryRow, ReflagCandidate, GenerateResult, GeneratedFile } from './types';

async function req<T>(path: string, method: 'GET' | 'POST' = 'GET', body?: unknown): Promise<T> {
  const token = await idToken();
  const res = await fetch('/api' + path, {
    method,
    headers: { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined
  });
  const json = await res.json().catch(() => ({}));
  if (!res.ok || json.ok === false) throw new Error(json.message || json.error || `HTTP ${res.status}`);
  return json as T;
}

export const api = {
  whoami: () => req<{ email: string }>('/whoami'),
  config: () => req<Config>('/config'),
  queue: () => req<{ rows: QueueRow[] }>('/queue').then((r) => r.rows || []),
  scvHistory: (scvId: string) => req<{ rows: HistoryRow[] }>('/scv-history?scvId=' + encodeURIComponent(scvId)).then((r) => r.rows || []),
  reviewBulk: (edits: Array<{ annotationId: string; scvId: string; scvVer: unknown; status: string; notes: string }>) =>
    req<{ applied: number; cleared: number }>('/review-bulk', 'POST', { edits }),
  assignBulk: (annotationIds: string[], batchId: string | null) =>
    req<{ applied: number; requested: number }>('/assign-bulk', 'POST', { annotationIds, batchId }),
  unassignBulk: (annotationIds: string[], batchId: string | null) =>
    req<{ applied: number; requested: number }>('/unassign-bulk', 'POST', { annotationIds, batchId }),
  generate: (batchId: string | null) => req<GenerateResult>('/generate', 'POST', { batchId }),
  finalize: (batchId: string | null) => req<GenerateResult & { finalized: boolean }>('/finalize', 'POST', { batchId }),
  reprocess: () => req<{ reprocessed: boolean }>('/reprocess', 'POST', {}),
  files: (batchId: string | null) => req<{ files: GeneratedFile[] }>('/files?batchId=' + encodeURIComponent(String(batchId ?? ''))).then((r) => r.files || []),
  deleteFile: (fileId: string) => req<{ trashed: string }>('/files/delete', 'POST', { fileId }),
  deleteDrafts: (batchId: string) => req<{ removed: number; kept: number }>('/files/delete-drafts', 'POST', { batchId }),
  reflagCandidates: () => req<{ candidates: ReflagCandidate[] }>('/reflag-candidates').then((r) => r.candidates || []),
  reflag: (scvIds: string[]) => req<{ created: number; skipped: number }>('/reflag', 'POST', { scvIds })
};
