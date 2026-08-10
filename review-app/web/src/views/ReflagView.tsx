import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  useReactTable, getCoreRowModel, getFilteredRowModel, getSortedRowModel, flexRender,
  type ColumnDef, type RowSelectionState, type ColumnFiltersState, type SortingState
} from '@tanstack/react-table';
import { api } from '../api';
import { bqv, type ReflagCandidate } from '../types';

interface Row extends ReflagCandidate { scv_disp: string; variant: string }

export function ReflagView() {
  const [raw, setRaw] = useState<ReflagCandidate[]>([]);
  const [rowSelection, setRowSelection] = useState<RowSelectionState>({});
  const [columnFilters, setColumnFilters] = useState<ColumnFiltersState>([]);
  const [sorting, setSorting] = useState<SortingState>([]);
  const [status, setStatus] = useState('');
  const [loaded, setLoaded] = useState(false);

  const rows: Row[] = useMemo(() => raw.map((c) => ({
    ...c, scv_disp: `${c.scv_id}.${bqv(c.current_scv_ver)}`, variant: `${c.vcv_id} (var ${c.variation_id})`
  })), [raw]);

  const load = useCallback(async () => {
    setStatus('Loading candidates…');
    try {
      const c = await api.reflagCandidates();
      setRaw(c); setRowSelection({}); setLoaded(true);
      const auto = c.filter((x) => x.is_autoreflag).length;
      const done = c.filter((x) => x.already_reflagged).length;
      setStatus(`${c.length} candidate(s) · ${auto} autoreflag · ${done} already reflagged`);
    } catch (e) { setStatus('Error: ' + (e as Error).message); }
  }, []);
  useEffect(() => { if (!loaded) void load(); }, [loaded, load]);

  const columns = useMemo<ColumnDef<Row>[]>(() => [
    {
      id: 'select', enableSorting: false, size: 42,
      header: ({ table }) => {
        const fr = table.getFilteredRowModel().rows.filter((r) => !r.original.already_reflagged);
        const allSel = fr.length > 0 && fr.every((r) => r.getIsSelected());
        return <input type="checkbox" title="Select all VISIBLE selectable rows" checked={allSel}
          onChange={(e) => fr.forEach((r) => r.toggleSelected(e.target.checked))} />;
      },
      cell: ({ row }) => row.original.already_reflagged ? null
        : <input type="checkbox" checked={row.getIsSelected()} onChange={row.getToggleSelectedHandler()} />
    },
    { id: 'autoreflag', header: 'autoreflag', size: 100, accessorFn: (r) => (r.is_autoreflag ? 'yes' : ''),
      cell: ({ row }) => row.original.is_autoreflag ? <span className="badge-auto">autoreflag</span> : null },
    { id: 'scv', header: 'SCV', size: 150, accessorFn: (r) => r.scv_disp },
    { id: 'submitter', header: 'Submitter (lab)', size: 180, accessorKey: 'submitter_name' },
    { id: 'variant', header: 'Variant', size: 180, accessorFn: (r) => r.variant },
    { id: 'reason', header: 'Original flag reason', size: 300, accessorKey: 'flagging_reason' },
    { id: 'classif', header: 'Current classification', size: 170, accessorKey: 'current_classification' },
    { id: 'outcome', header: 'Outcome', size: 160, accessorKey: 'outcome' },
    { id: 'batch', header: 'Orig batch', size: 90, accessorKey: 'orig_batch_id' },
    { id: 'bumps', header: 'Bumps', size: 74, accessorFn: (r) => bqv(r.version_bump_count) },
    { id: 'reclassified', header: 'reclassified', size: 100, accessorFn: (r) => (r.was_reclassified ? '✓' : '') },
    { id: 'already', header: 'already reflagged', size: 120, accessorFn: (r) => (r.already_reflagged ? '✓' : '') }
  ], []);

  const table = useReactTable({
    data: rows, columns, state: { rowSelection, columnFilters, sorting },
    enableRowSelection: (row) => !row.original.already_reflagged, getRowId: (r) => r.scv_id,
    onRowSelectionChange: setRowSelection, onColumnFiltersChange: setColumnFilters, onSortingChange: setSorting,
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
    const scvIds = selected.filter((r) => !r.already_reflagged).map((r) => r.scv_id);
    if (!scvIds.length) return;
    if (!confirm(`Reflag ${scvIds.length} SCV(s)? Each becomes a new Flagging Candidate at its current version and enters the review queue.`)) return;
    setStatus(`Reflagging ${scvIds.length}…`);
    try {
      const out = await api.reflag(scvIds);
      setStatus(`Reflagged ${out.created}` + (out.skipped ? ` · ${out.skipped} skipped (already reflagged)` : '') + ' — they enrich into the review queue shortly.');
      await load();
    } catch (e) { setStatus('Error: ' + (e as Error).message); }
  };

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
        <span className="status">{status}</span>
      </div>
      <div className="grid-wrap">
        <table className="grid" style={{ width: table.getTotalSize() }}>
          <colgroup>{table.getVisibleLeafColumns().map((c) => <col key={c.id} style={{ width: c.getSize() }} />)}</colgroup>
          <thead>{table.getHeaderGroups().map((hg) => (
            <tr key={hg.id}>{hg.headers.map((h) => (
              <th key={h.id}>
                <div className={h.column.getCanSort() ? 'sortable' : ''} onClick={h.column.getToggleSortingHandler()}>
                  {flexRender(h.column.columnDef.header, h.getContext())}
                  {{ asc: ' ▲', desc: ' ▼' }[h.column.getIsSorted() as string] ?? ''}
                </div>
                {/* Per-column filtering deferred — see ReviewView. */}
              </th>))}</tr>))}</thead>
          <tbody>{table.getRowModel().rows.map((row) => (
            <tr key={row.id} className={row.original.already_reflagged ? 'done' : ''}>
              {row.getVisibleCells().map((cell) => (
                <td key={cell.id}>{flexRender(cell.column.columnDef.cell ?? ((c) => c.getValue()), cell.getContext())}</td>
              ))}
            </tr>))}</tbody>
        </table>
      </div>
    </div>
  );
}
