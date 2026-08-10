import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  useReactTable, getCoreRowModel, getFilteredRowModel, getSortedRowModel, flexRender,
  type ColumnDef, type RowSelectionState, type ColumnFiltersState, type SortingState, type ColumnSizingState
} from '@tanstack/react-table';
import { api } from '../api';
import { bqv, loadColSizing, type ReflagCandidate } from '../types';
import { cls, pinClass, pinStyle, colLefts, exportVisibleCsv } from './gridUtil';

const FROZEN = 4;               // freeze the first 4 reflag columns
const namePart = (email: string) => (email || '').split('@')[0];

interface Row extends ReflagCandidate { scv_disp: string; variant: string }

export function ReflagView() {
  const [raw, setRaw] = useState<ReflagCandidate[]>([]);
  const [rowSelection, setRowSelection] = useState<RowSelectionState>({});
  const [columnFilters, setColumnFilters] = useState<ColumnFiltersState>([]);
  const [sorting, setSorting] = useState<SortingState>([]);
  const [columnSizing, setColumnSizing] = useState<ColumnSizingState>(() => loadColSizing('cvc.reflag.colSizing'));
  useEffect(() => { localStorage.setItem('cvc.reflag.colSizing', JSON.stringify(columnSizing)); }, [columnSizing]);
  const [status, setStatus] = useState('');
  const [loaded, setLoaded] = useState(false);

  const rows: Row[] = useMemo(() => raw.map((c) => ({
    ...c, scv_disp: `${c.scv_id}.${bqv(c.current_scv_ver)}`,
    variant: bqv(c.current_vcv_ver) ? `${c.vcv_id}.${bqv(c.current_vcv_ver)}` : c.vcv_id
  })), [raw]);

  const load = useCallback(async () => {
    setStatus('Loading candidates…');
    try {
      const c = await api.reflagCandidates();
      setRaw(c); setRowSelection({}); setLoaded(true);
      const auto = c.filter((x) => x.is_autoreflag).length;
      setStatus(`${c.length} candidate(s) · ${auto} autoreflag`);
    } catch (e) { setStatus('Error: ' + (e as Error).message); }
  }, []);
  useEffect(() => { if (!loaded) void load(); }, [loaded, load]);

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
    { id: 'autoreflag', header: 'autoreflag', size: 100, accessorFn: (r) => (r.is_autoreflag ? 'yes' : ''),
      cell: ({ row }) => row.original.is_autoreflag ? <span className="badge-auto">autoreflag</span> : null },
    { id: 'scv', header: 'SCV', size: 150, accessorFn: (r) => r.scv_disp },
    { id: 'submitter', header: 'Submitter (lab)', size: 180, accessorKey: 'submitter_name' },
    { id: 'variant', header: 'VCV', size: 170, accessorFn: (r) => r.variant,
      cell: ({ row }) => <a href={`https://www.ncbi.nlm.nih.gov/clinvar/variation/${row.original.variant}/`} target="_blank" rel="noreferrer">{row.original.variant}</a> },
    { id: 'reason', header: 'Original flag reason', size: 300, accessorKey: 'flagging_reason' },
    // The original annotation being copied — its curator + timestamp (a reflag
    // replicate gets the current user + a new timestamp).
    { id: 'orig_curator', header: 'Orig curator', size: 120, accessorFn: (r) => namePart(r.orig_curator) },
    { id: 'orig_date', header: 'Orig annotated', size: 140, accessorFn: (r) => bqv(r.orig_annotated_date) },
    { id: 'classif', header: 'Current classification', size: 170, accessorKey: 'current_classification' },
    { id: 'outcome', header: 'Outcome', size: 160, accessorKey: 'outcome' },
    { id: 'batch', header: 'Orig batch', size: 90, accessorKey: 'orig_batch_id' },
    { id: 'bumps', header: 'Bumps', size: 74, accessorFn: (r) => bqv(r.version_bump_count) },
    { id: 'reclassified', header: 'reclassified', size: 100, accessorFn: (r) => (r.was_reclassified ? '✓' : '') }
  ], []);

  const table = useReactTable({
    data: rows, columns, state: { rowSelection, columnFilters, sorting, columnSizing },
    enableRowSelection: true, getRowId: (r) => r.scv_id,
    enableColumnResizing: true, columnResizeMode: 'onChange', defaultColumn: { minSize: 40, maxSize: 900 },
    onRowSelectionChange: setRowSelection, onColumnFiltersChange: setColumnFilters,
    onSortingChange: setSorting, onColumnSizingChange: setColumnSizing,
    getCoreRowModel: getCoreRowModel(), getFilteredRowModel: getFilteredRowModel(), getSortedRowModel: getSortedRowModel()
  });

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

  const reflag = async () => {
    const scvIds = selected.map((r) => r.scv_id);
    if (!scvIds.length) return;
    if (!confirm(`Reflag ${scvIds.length} SCV(s)? Each becomes a new Flagging Candidate at its current version and enters the review queue.`)) return;
    setStatus(`Reflagging ${scvIds.length}…`);
    try {
      const out = await api.reflag(scvIds);
      // Optimistically drop the reflagged SCVs from the list now — they won't be
      // in native_v4 until enrichment runs, so a reload can't exclude them yet.
      const done = new Set(scvIds);
      setRaw((prev) => prev.filter((c) => !done.has(c.scv_id)));
      setRowSelection({});
      setStatus(`Reflagged ${out.created}` + (out.skipped ? ` · ${out.skipped} skipped` : '') + ' — removed from the list; they enter the review queue shortly.');
    } catch (e) { setStatus('Error: ' + (e as Error).message); }
  };

  const lefts = colLefts(table);

  return (
    <div>
      <p className="reflag-intro">
        Previously-submitted <strong>Flagging Candidates</strong> whose submitter version-bumped the SCV
        <strong> without substantive change</strong>. Select rows to <strong>reflag</strong> — a new Flagging Candidate
        is captured at the SCV's current version and enters the review queue. <span className="badge-auto">autoreflag</span> = high-confidence subset.
      </p>
      <div className="toolbar">
        <button disabled={!selected.length} onClick={reflag}>Reflag selected</button>
        {selected.length > 0 && <span className="muted">{selected.length} selected</span>}
        <button className="secondary" onClick={load}>Reload candidates</button>
        <button className="secondary" onClick={() => setColumnSizing({})} title="Reset all column widths">Reset widths</button>
        <a href="#" className="csv-link" onClick={(e) => { e.preventDefault(); exportVisibleCsv(table, 'reflag-candidates.csv'); }}>⤓ CSV</a>
        <span className="status">{status}</span>
      </div>
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
            <tr key={row.id}>
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
