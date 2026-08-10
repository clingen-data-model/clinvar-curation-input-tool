import { useRef, useState, type ReactNode } from 'react';
import { createPortal } from 'react-dom';

// A hover popover that renders into document.body (a portal) so it is NOT clipped
// by the grid cell's overflow:hidden. Positioned (fixed) at the trigger. `load`
// supplies the popover body — sync (e.g. a note) or async (e.g. fetched history);
// it runs once per open. Stays open while the mouse is over the popover.
export function CellHover({ label, className, load }:
  { label: ReactNode; className?: string; load: () => ReactNode | Promise<ReactNode> }) {
  const [open, setOpen] = useState(false);
  const [pos, setPos] = useState<{ left: number; top: number }>({ left: 0, top: 0 });
  const [body, setBody] = useState<ReactNode>(null);
  const timer = useRef<number | undefined>(undefined);

  const show = async (e: React.MouseEvent) => {
    window.clearTimeout(timer.current);
    const r = (e.currentTarget as HTMLElement).getBoundingClientRect();
    setPos({ left: Math.max(8, Math.min(r.left, window.innerWidth - 660)), top: r.bottom + 4 });
    setOpen(true);
    setBody(await load());
  };
  const hide = () => { timer.current = window.setTimeout(() => setOpen(false), 200); };

  return (
    <span className={className} onMouseEnter={show} onMouseLeave={hide}>
      {label}
      {open && createPortal(
        <div className="hist-pop" style={{ position: 'fixed', left: pos.left, top: pos.top }}
          onMouseEnter={() => window.clearTimeout(timer.current)} onMouseLeave={hide}>
          {body ?? 'Loading…'}
        </div>, document.body)}
    </span>
  );
}
