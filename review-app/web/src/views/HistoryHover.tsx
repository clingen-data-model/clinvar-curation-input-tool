import { useRef, useState } from 'react';
import { api } from '../api';
import { bqv, type HistoryRow } from '../types';

// Prior-annotations history as a hover popover (like the extension's CvC badge).
// Fetches once per SCV (module cache), shows on hover, stays while hovered.
const cache: Record<string, HistoryRow[]> = {};

function line(h: HistoryRow): string {
  const rev = h.review_status
    ? ` [ ${h.review_status}${h.reviewer ? ' (' + h.reviewer + ')' : ''}${h.batch_id ? ' *' + h.batch_id + '*' : ''} ]`
    : '';
  return `.${bqv(h.scv_ver)}\t${bqv(h.annotated_date)} (${h.curator || ''}) ${h.action || ''} ${h.reason || ''}${rev}`;
}

export function HistoryHover({ scvId }: { scvId: string }) {
  const [open, setOpen] = useState(false);
  const [rows, setRows] = useState<HistoryRow[] | null>(cache[scvId] ?? null);
  const [err, setErr] = useState('');
  const hideTimer = useRef<number | undefined>(undefined);

  const show = async () => {
    window.clearTimeout(hideTimer.current);
    setOpen(true);
    if (rows) return;
    try {
      const data = cache[scvId] ?? (cache[scvId] = await api.scvHistory(scvId));
      setRows(data);
    } catch (e) { setErr((e as Error).message); }
  };
  const hide = () => { hideTimer.current = window.setTimeout(() => setOpen(false), 200); };

  return (
    <span className="hist" onMouseEnter={show} onMouseLeave={hide}>
      <span className="hist-link">history ▸</span>
      {open && (
        <div className="hist-pop" onMouseEnter={() => window.clearTimeout(hideTimer.current)} onMouseLeave={hide}>
          <div className="hist-hd">Prior annotations — {scvId}{rows ? ` (${rows.length})` : ''}</div>
          <pre>{err ? 'Error: ' + err : rows ? (rows.length ? rows.map(line).join('\n') : 'No prior annotations found.') : 'Loading…'}</pre>
        </div>
      )}
    </span>
  );
}
