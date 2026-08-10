import type { Table } from '@tanstack/react-table';

// Combine class name parts, dropping falsy ones.
export const cls = (...parts: (string | false | undefined)[]) => parts.filter(Boolean).join(' ') || undefined;

// Freeze (sticky-left) the first `frozen` columns; `lefts` are cumulative offsets.
export const pinClass = (i: number, frozen: number) => (i < frozen ? (i === frozen - 1 ? 'pin pin-last' : 'pin') : '');
export const pinStyle = (i: number, lefts: number[], frozen: number) => (i < frozen ? { left: lefts[i] } : undefined);

// Cumulative left offset of each visible column (tracks current sizes → resizing).
export function colLefts<T>(table: Table<T>): number[] {
  const lefts: number[] = [];
  let acc = 0;
  table.getVisibleLeafColumns().forEach((c, i) => { lefts[i] = acc; acc += c.getSize(); });
  return lefts;
}

// Download the currently-VISIBLE rows (post-filter/sort) as CSV, one column per
// visible column (minus `skip`, e.g. the checkbox/action columns).
export function exportVisibleCsv<T>(table: Table<T>, filename: string, skip: Set<string> = new Set(['select'])) {
  const cols = table.getVisibleLeafColumns().filter((c) => !skip.has(c.id));
  const esc = (v: unknown) => `"${String(v ?? '').replace(/"/g, '""')}"`;
  const header = cols.map((c) => esc(typeof c.columnDef.header === 'string' ? c.columnDef.header : c.id));
  const lines = [header.join(',')];
  table.getRowModel().rows.forEach((r) => lines.push(cols.map((c) => esc(r.getValue(c.id))).join(',')));
  const blob = new Blob([lines.join('\r\n')], { type: 'text/csv;charset=utf-8' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url; a.download = filename; document.body.appendChild(a); a.click(); a.remove();
  URL.revokeObjectURL(url);
}
