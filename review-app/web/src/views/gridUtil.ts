import type { MouseEvent } from 'react';
import type { Table } from '@tanstack/react-table';

// Checkbox click with shift-range support (checks OR unchecks). A plain click
// toggles the row; shift-click sets the whole range from the anchor to the state
// the clicked row is toggling TO — so shift-clicking an unchecked row checks the
// range, and shift-clicking a checked row unchecks it. Operates on the VISIBLE
// (filtered/sorted) rows; the last-clicked row becomes the new anchor.
export function rangeSelectClick<T>(e: MouseEvent, table: Table<T>, rowId: string, anchor: { current: number | null }) {
  const visible = table.getRowModel().rows;
  const idx = visible.findIndex((r) => r.id === rowId);
  if (idx < 0) return;
  if (e.shiftKey && anchor.current != null && anchor.current < visible.length) {
    const target = !visible[idx].getIsSelected();
    const [a, b] = anchor.current <= idx ? [anchor.current, idx] : [idx, anchor.current];
    for (let k = a; k <= b; k++) if (visible[k].getCanSelect()) visible[k].toggleSelected(target);
  } else {
    visible[idx].toggleSelected(!visible[idx].getIsSelected());
  }
  anchor.current = idx;
}

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
