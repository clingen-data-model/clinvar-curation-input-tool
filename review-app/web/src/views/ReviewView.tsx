import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  useReactTable, getCoreRowModel, getFilteredRowModel, getSortedRowModel, flexRender,
  type ColumnDef, type RowSelectionState, type ColumnFiltersState, type SortingState, type ColumnSizingState
} from '@tanstack/react-table';
import { api } from '../api';
import { bqv, loadColSizing, type Config, type QueueRow, type GenerateResult, type GeneratedFile } from '../types';
import { HistoryHover } from './HistoryHover';
import { CellHover } from './CellHover';
import { cls, pinClass, pinStyle, colLefts, exportVisibleCsv } from './gridUtil';

const STATUSES = ['', 'OK', 'Fixed', 'Archive', 'Question'];
const ACTIONABLE = ['flagging candidate', 'remove flagged submission'];

// A queue row + the fields the UI derives once per load.
interface Row extends QueueRow {
  scv_disp: string; variant: string; assigned: boolean; eligible: boolean; reason: string;
}

const tick = (v: boolean | null) => (v ? '✓' : '');
const clinvarVcvUrl = (acc: string) => `https://www.ncbi.nlm.nih.gov/clinvar/variation/${acc}/`;

// Freeze the first N columns (sticky-left) — only cols after this scroll.
const FROZEN = 6;

export function ReviewView({ config, onConfigChange }: { config: Config; onConfigChange: () => Promise<void> }) {
  const nextBatchId = config.nextBatchId;
  const [raw, setRaw] = useState<QueueRow[]>([]);
  const [edits, setEdits] = useState<Record<string, { status: string; notes: string }>>({});
  const baseline = useRef<Record<string, { status: string; notes: string }>>({});
  const [rowSelection, setRowSelection] = useState<RowSelectionState>({});
  const [columnFilters, setColumnFilters] = useState<ColumnFiltersState>([]);
  const [sorting, setSorting] = useState<SortingState>([]);
  const [columnSizing, setColumnSizing] = useState<ColumnSizingState>(() => loadColSizing('cvc.review.colSizing'));
  useEffect(() => { localStorage.setItem('cvc.review.colSizing', JSON.stringify(columnSizing)); }, [columnSizing]);
  const [status, setStatus] = useState('Loading queue…');
  const [result, setResult] = useState<GenerateResult | null>(null);
  const [files, setFiles] = useState<GeneratedFile[]>([]);
  const [bulkStatus, setBulkStatus] = useState('');

  const rows: Row[] = useMemo(() => raw.map((r) => {
    const assigned = r.rs_batch_id != null && String(r.rs_batch_id) === String(nextBatchId);
    const savedOk = r.rs_review_status === 'OK';
    const actionable = ACTIONABLE.includes(String(r.action || '').toLowerCase());
    const eligible = !assigned && savedOk && actionable && !r.fresh;
    const reason = !actionable ? 'only Flagging Candidate / Remove Flagged Submission can be batched'
      : !savedOk ? 'set status OK and Save first' : r.fresh ? 'awaiting enrichment' : '';
    return {
      ...r,
      scv_disp: `${r.scv_id}.${bqv(r.scv_ver)}${r.fresh ? ' 🆕' : ''}`,
      // Full VCV accession (base id + annotated version) — rendered as a ClinVar link.
      variant: r.vcv_id.includes('.') ? r.vcv_id : (bqv(r.vcv_ver) ? `${r.vcv_id}.${bqv(r.vcv_ver)}` : r.vcv_id),
      assigned, eligible, reason
    };
  }), [raw, nextBatchId]);

  const loadQueue = useCallback(async () => {
    setStatus('Loading queue…');
    try {
      const data = await api.queue();
      const base: Record<string, { status: string; notes: string }> = {};
      data.forEach((r) => { base[r.annotation_id] = { status: r.rs_review_status || '', notes: r.rs_notes || '' }; });
      baseline.current = base;
      setEdits({ ...base });
      setRaw(data);
      setRowSelection({});
      setStatus(data.length ? '' : 'Queue is empty — no unreviewed annotations.');
    } catch (e) { setStatus('Error: ' + (e as Error).message); }
  }, []);

  const loadFiles = useCallback(async () => {
    try { setFiles(await api.files(nextBatchId)); } catch { /* best-effort */ }
  }, [nextBatchId]);

  useEffect(() => { void loadQueue(); void loadFiles(); }, [loadQueue, loadFiles]);

  const val = (id: string) => edits[id] || baseline.current[id] || { status: '', notes: '' };
  const isDirty = (id: string) => {
    const b = baseline.current[id]; const e = val(id);
    return !!b && (e.status !== b.status || e.notes !== b.notes);
  };
  const fieldDirty = (id: string, k: 'status' | 'notes') => { const b = baseline.current[id]; return !!b && val(id)[k] !== b[k]; };
  const dirtyIds = useMemo(() => rows.map((r) => r.annotation_id).filter(isDirty), [rows, edits]);
  const setCell = (id: string, k: 'status' | 'notes', v: string) =>
    setEdits((prev) => ({ ...prev, [id]: { ...val(id), [k]: v } }));

  const columns = useMemo<ColumnDef<Row>[]>(() => [
    {
      id: 'select', enableSorting: false, size: 42,
      header: ({ table }) => {
        const fr = table.getFilteredRowModel().rows;
        const allSel = fr.length > 0 && fr.every((r) => r.getIsSelected());
        return <input type="checkbox" title="Select all VISIBLE rows" checked={allSel}
          onChange={(e) => fr.forEach((r) => r.toggleSelected(e.target.checked))} />;
      },
      cell: ({ row }) => <input type="checkbox" checked={row.getIsSelected()} onChange={row.getToggleSelectedHandler()} />
    },
    { id: 'status', header: 'Status', size: 110, accessorFn: (r) => val(r.annotation_id).status,
      cell: ({ row }) => (
        <select className={fieldDirty(row.original.annotation_id, 'status') ? 'cell-dirty' : ''}
          value={val(row.original.annotation_id).status} onChange={(e) => setCell(row.original.annotation_id, 'status', e.target.value)}>
          {STATUSES.map((s) => <option key={s} value={s}>{s || '(none)'}</option>)}
        </select>) },
    { id: 'notes', header: 'Review notes', size: 240, accessorFn: (r) => val(r.annotation_id).notes,
      cell: ({ row }) => (
        <input type="text" className={fieldDirty(row.original.annotation_id, 'notes') ? 'cell-dirty' : ''}
          value={val(row.original.annotation_id).notes}
          onChange={(e) => setCell(row.original.annotation_id, 'notes', e.target.value)} />) },
    { id: 'auto', header: 'Auto', size: 100, accessorFn: (r) => r.auto_status || 'manual',
      // Hover shows WHY it was (or wasn't) auto-reviewed (the auto_note reasoning).
      cell: ({ row }) => (
        <CellHover className="auto-cell" label={<span className="auto-label">{row.original.auto_status || 'manual'} ⓘ</span>}
          load={() => (<pre>{row.original.auto_note || 'No auto-review note.'}</pre>)} />) },
    { id: 'batch', header: 'Batch', size: 90,
      accessorFn: (r) => (r.assigned ? String(nextBatchId) : r.eligible ? 'eligible' : ''),
      // Assigned → just the batch number; eligible → empty; not eligible → dash (hover = why).
      cell: ({ row }) => row.original.assigned ? <span>{nextBatchId}</span>
        : row.original.eligible ? null : <span title={row.original.reason}>–</span> },
    { id: 'scv', header: 'SCV', size: 150, accessorFn: (r) => r.scv_disp },
    { id: 'variant', header: 'VCV', size: 170, accessorFn: (r) => r.variant,
      cell: ({ row }) => <a href={clinvarVcvUrl(row.original.variant)} target="_blank" rel="noreferrer">{row.original.variant}</a> },
    { id: 'submitter', header: 'Submitter', size: 170, accessorFn: (r) => r.submitter_name || r.submitter_id },
    { id: 'action', header: 'Action', size: 150, accessorKey: 'action' },
    { id: 'reason', header: 'Reason', size: 240, accessorKey: 'reason' },
    { id: 'scv_review', header: 'SCV rev status', size: 150, accessorFn: (r) => r.clinvar_review_status || '' },
    { id: 'latest_anno', header: 'latest anno', size: 84, accessorFn: (r) => tick(r.is_latest_annotation) },
    { id: 'outdated_vcv', header: 'outdated vcv', size: 90, accessorFn: (r) => tick(r.is_outdated_vcv) },
    { id: 'outdated_scv', header: 'outdated scv', size: 90, accessorFn: (r) => tick(r.is_outdated_scv) },
    { id: 'moved', header: 'moved', size: 72, accessorFn: (r) => tick(r.is_moved_scv) },
    { id: 'deleted', header: 'deleted', size: 72, accessorFn: (r) => tick(r.is_deleted_scv) },
    { id: 'deleted_rel', header: 'deleted rel date', size: 120, accessorFn: (r) => bqv(r.deleted_scv_release_date) },
    { id: 'latest_scv_ver', header: 'latest scv ver', size: 100, accessorFn: (r) => bqv(r.latest_scv_ver) },
    { id: 'latest_scv_classif', header: 'latest scv classif', size: 150, accessorFn: (r) => r.latest_scv_classification || '' },
    { id: 'prior_ver', header: 'prior same ver', size: 100, accessorFn: (r) => tick(r.has_prior_scv_ver_annotation) },
    { id: 'prior_sub', header: 'prior submitted', size: 104, accessorFn: (r) => tick(r.has_prior_submission_batch_id) },
    { id: 'prior_hist', header: 'Prior hist', size: 96, enableSorting: false,
      cell: ({ row }) => row.original.has_prior_scv_id_annotation ? <HistoryHover scvId={row.original.scv_id} /> : null }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  ], [edits, nextBatchId]);

  const table = useReactTable({
    data: rows, columns, state: { rowSelection, columnFilters, sorting, columnSizing },
    enableRowSelection: true, getRowId: (r) => r.annotation_id,
    enableColumnResizing: true, columnResizeMode: 'onChange', defaultColumn: { minSize: 40, maxSize: 900 },
    onRowSelectionChange: setRowSelection, onColumnFiltersChange: setColumnFilters,
    onSortingChange: setSorting, onColumnSizingChange: setColumnSizing,
    getCoreRowModel: getCoreRowModel(), getFilteredRowModel: getFilteredRowModel(), getSortedRowModel: getSortedRowModel()
  });

  // Filter change → deselect any now-hidden rows (never act on unseen records).
  const filteredIds = table.getFilteredRowModel().rows.map((r) => r.id).join(',');
  useEffect(() => {
    const visible = new Set(table.getFilteredRowModel().rows.map((r) => r.id));
    setRowSelection((prev) => {
      const next: RowSelectionState = {};
      Object.keys(prev).forEach((id) => { if (prev[id] && visible.has(id)) next[id] = true; });
      return Object.keys(next).length === Object.keys(prev).length ? prev : next;
    });
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [filteredIds]);

  const selected = table.getSelectedRowModel().rows.map((r) => r.original);
  const assignedCount = rows.filter((r) => r.assigned).length;

  const saveAll = async () => {
    const editsPayload = dirtyIds.map((id) => {
      const r = raw.find((x) => x.annotation_id === id)!;
      return { annotationId: id, scvId: r.scv_id, scvVer: r.scv_ver, status: val(id).status, notes: val(id).notes };
    });
    if (!editsPayload.length) { setStatus('Nothing to save.'); return; }
    setStatus(`Saving ${editsPayload.length}…`);
    try {
      const out = await api.reviewBulk(editsPayload);
      setStatus(`Saved ${editsPayload.length} change(s)` + (out.cleared ? ` (incl. ${out.cleared} cleared)` : ''));
      await loadQueue();
    } catch (e) { setStatus('Error: ' + (e as Error).message); }
  };
  const applyBulkStatus = () => {
    if (!selected.length) { setStatus('Select rows first.'); return; }
    setEdits((prev) => {
      const next = { ...prev };
      selected.forEach((r) => { next[r.annotation_id] = { ...val(r.annotation_id), status: bulkStatus }; });
      return next;
    });
    setStatus(`Set status "${bulkStatus || '(none)'}" on ${selected.length} row(s) — review, then Save all.`);
  };
  const bulkBatch = async (kind: 'assign' | 'unassign') => {
    if (dirtyIds.length) { setStatus('Save your changes first.'); return; }
    const ids = selected.filter((r) => (kind === 'assign' ? r.eligible : r.assigned)).map((r) => r.annotation_id);
    if (!ids.length) { setStatus(`No selected rows can be ${kind === 'assign' ? 'added' : 'unassigned'}.`); return; }
    setStatus(`${kind === 'assign' ? 'Adding' : 'Unassigning'} ${ids.length}…`);
    try {
      const out = kind === 'assign' ? await api.assignBulk(ids, nextBatchId) : await api.unassignBulk(ids, nextBatchId);
      const failed = (out.requested || ids.length) - (out.applied || 0);
      setStatus(`${kind === 'assign' ? 'Added' : 'Unassigned'} ${out.applied}` + (failed > 0 ? ` · ${failed} skipped (not eligible)` : ''));
      await loadQueue();
    } catch (e) { setStatus('Error: ' + (e as Error).message); }
  };
  const doGenerate = async () => { setResult(null); try { setResult(await api.generate(nextBatchId)); await loadFiles(); } catch (e) { setStatus('Error: ' + (e as Error).message); } };
  const doFinalize = async () => {
    if (!confirm(`Finalize batch ${nextBatchId}? This persists the batch and advances the batch id.`)) return;
    try { const out = await api.finalize(nextBatchId); setResult(out); await onConfigChange(); await loadQueue(); await loadFiles(); }
    catch (e) { setStatus('Error: ' + (e as Error).message); }
  };

  const lefts = colLefts(table);   // frozen-column offsets (track resizing)

  return (
    <div>
      <div className="toolbar">
        <span>Next batch: <strong>{nextBatchId || '(unset)'}</strong></span>
        <button className="secondary" onClick={loadQueue}>Reload queue</button>
        <button className="secondary" onClick={() => setColumnSizing({})} title="Reset all column widths">Reset widths</button>
        <a href="#" className="csv-link" onClick={(e) => { e.preventDefault(); exportVisibleCsv(table, 'review-queue.csv', new Set(['select', 'prior_hist'])); }}>⤓ CSV</a>
        <button className="secondary" onClick={doGenerate}>Generate file</button>
        <button className="secondary" disabled={config.releaseStale} onClick={doFinalize}
          title={config.releaseStale ? 'Re-process against the current ClinVar release first' : ''}>Finalize batch</button>
        <span className="muted">{assignedCount} assigned to batch {nextBatchId} · {rows.length} in queue</span>
      </div>
      <div className="toolbar">
        <button disabled={dirtyIds.length === 0} onClick={saveAll}>Save all</button>
        {dirtyIds.length > 0 && <span className="unsaved">{dirtyIds.length} unsaved change{dirtyIds.length > 1 ? 's' : ''}</span>}
        <span className="sep">·</span>
        <label className="inline">Set status of selected:{' '}
          <select value={bulkStatus} onChange={(e) => setBulkStatus(e.target.value)}>
            {STATUSES.map((s) => <option key={s} value={s}>{s || '(none)'}</option>)}
          </select>
        </label>
        <button className="secondary" disabled={!selected.length} onClick={applyBulkStatus}>Apply</button>
        <span className="sep">·</span>
        <button className="secondary" disabled={!selected.some((r) => r.eligible)} onClick={() => bulkBatch('assign')}>Add selected to batch</button>
        <button className="secondary" disabled={!selected.some((r) => r.assigned)} onClick={() => bulkBatch('unassign')}>Unassign selected</button>
        {selected.length > 0 && <span className="muted">{selected.length} selected</span>}
      </div>

      {result && (
        <div className="result">
          {!result.count ? `Nothing to submit (0 annotations).` : (<>
            <span>{result.finalized ? 'Finalized' : 'Generated'}: {result.count} annotation(s)
              {result.warnings?.needsReview ? ` · ${result.warnings.needsReview} still need review` : ''}</span>
            {result.link && <a href={result.link} target="_blank" rel="noreferrer">{result.filename || 'submission file'}</a>}
            {result.mailto && <a href={result.mailto}>— draft submission email</a>}
          </>)}
        </div>
      )}
      {files.length > 0 && (
        <div className="files">
          <strong>Generated files</strong>
          <ul>{files.map((f) => (
            <li key={f.id}>
              <a href={f.link} target="_blank" rel="noreferrer">{f.name}</a>
              {f.protected ? <span className="lock">🔒 finalized</span>
                : <button className="secondary del" onClick={async () => { if (confirm(`Delete ${f.name}?`)) { await api.deleteFile(f.id); await loadFiles(); } }}>Delete</button>}
            </li>))}</ul>
        </div>
      )}

      <div className="status">{status}</div>

      <div className="grid-wrap">
        <table className="grid" style={{ width: table.getTotalSize() }}>
          <colgroup>{table.getVisibleLeafColumns().map((c) => <col key={c.id} style={{ width: c.getSize() }} />)}</colgroup>
          <thead>{table.getHeaderGroups().map((hg) => (
            <tr key={hg.id}>{hg.headers.map((h, i) => (
              <th key={h.id} className={cls(h.column.getCanSort() ? 'sortable' : '', pinClass(i, FROZEN))} style={pinStyle(i, lefts, FROZEN)}
                onClick={h.column.getToggleSortingHandler()}>
                {flexRender(h.column.columnDef.header, h.getContext())}
                {{ asc: ' ▲', desc: ' ▼' }[h.column.getIsSorted() as string] ?? ''}
                {h.column.getCanResize() && (
                  <div className={'resizer' + (h.column.getIsResizing() ? ' resizing' : '')}
                    onClick={(e) => e.stopPropagation()}
                    onMouseDown={h.getResizeHandler()} onTouchStart={h.getResizeHandler()} />)}
              </th>))}</tr>))}</thead>
          <tbody>{table.getRowModel().rows.map((row) => (
            <tr key={row.id} className={cls(row.original.fresh ? 'fresh' : '', isDirty(row.id) ? 'dirty' : '')}>
              {row.getVisibleCells().map((cell, i) => (
                <td key={cell.id} className={cls(pinClass(i, FROZEN))} style={pinStyle(i, lefts, FROZEN)}>
                  {flexRender(cell.column.columnDef.cell ?? ((c) => c.getValue()), cell.getContext())}</td>
              ))}
            </tr>))}</tbody>
        </table>
      </div>
    </div>
  );
}
