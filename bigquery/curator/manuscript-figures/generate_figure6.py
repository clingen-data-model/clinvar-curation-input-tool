#!/usr/bin/env python3
"""Generate manuscript Figure 6 from 06-conflict-resolution-reasons.sql.

Figure 6A is the total number of ClinVar conflict resolutions by reason. Figure 6B
is the same counts by monthly release. Both split medically significant conflicts
from non-medically significant ones, on one shared scale. Each is its own titled
image.

Uses only the Python standard library and the bq CLI, and needs the table function
that 06-conflict-resolution-reasons.sql creates. Writes SVG, plus PNG when Chrome
is available, and the CSV tables behind each panel.

    python3 generate_figure6.py --out output/figure6
    python3 generate_figure6.py --as-of 2026-06-06 --out output/figure6-jun2026
    python3 generate_figure6.py --input resolution_events.csv --out output/figure6
"""

import argparse
import collections
import csv
import html
import math
import os
import shutil
import subprocess
import sys
import tempfile

EVENTS_QUERY = """
SELECT *
FROM `clinvar_ingest.manuscript_figure6_resolution_events`(@as_of)
ORDER BY snapshot_release_date, variation_id
"""

FONT = "Arial, Helvetica, sans-serif"
INK = "#1f1f1f"
INK_MUTED = "#52514e"
SURFACE = "#ffffff"
RULE = "#c9c8c3"

# Colors stay with a reason in every panel. Flagged through CvC uses the flagged
# color from Figure 3. Bars stack in this order, with the submitter's own changes
# first, then flags, then new higher ranked submissions.
REASONS = [
    ("Reclassified", "#0072B2"),
    ("Removed", "#56B4E9"),
    ("Rank lowered", "#7A5195"),
    ("Flagged through CvC", "#C8341E"),
    ("Flagged outside CvC", "#8F2A17"),
    ("Expert panel added", "#009E73"),
    ("1 star added to 0 star conflict", "#E69F00"),
    ("Other", "#A3A29C"),
]
REASON_COLORS = dict(REASONS)
GROUPS = ["medically significant", "non-medically significant"]
GROUP_TITLES = {
    "medically significant": "Medically significant conflicts",
    "non-medically significant": "Non-medically significant conflicts",
}


def run_query(as_of):
    param = f"as_of:DATE:{as_of or 'NULL'}"
    result = subprocess.run(
        [
            "bq", "--quiet", "--project_id=clingen-dev", "query", "--use_legacy_sql=false",
            "--format=csv", "--max_rows=1000000", f"--parameter={param}", EVENTS_QUERY,
        ],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        sys.exit(f"bq query failed:\n{result.stdout}\n{result.stderr}")
    return result.stdout


def fmt(n):
    return f"{n:,}"


def pct(n, total):
    return f"{100 * n / total:.1f}%" if total else "0.0%"


def text(x, y, value, size=13, weight="normal", fill=INK, anchor="start", extra=""):
    return (
        f'<text x="{x:.1f}" y="{y:.1f}" font-size="{size}" font-weight="{weight}" '
        f'fill="{fill}" text-anchor="{anchor}"{extra}>{html.escape(value)}</text>'
    )


def wrap_svg(width, height, body):
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" '
        f'width="{width}" height="{height}" font-family="{FONT}">'
        f'<rect width="{width}" height="{height}" fill="{SURFACE}"/>{body}</svg>\n'
    )


def bar(x, y, w, h, fill, title):
    return (
        f'<rect x="{x:.2f}" y="{y:.2f}" width="{w:.2f}" height="{h:.2f}" fill="{fill}">'
        f'<title>{html.escape(title)}</title></rect>'
    )


def panel_a(counts, ordered, notes, title, width=1040):
    """One row per reason, with one bar per conflict type on a shared scale."""
    totals = {g: sum(counts[(g, r)] for r, _ in REASONS) for g in GROUPS}
    grand = sum(totals.values())
    label_w, total_w, col_w, col_gap = 216, 124, 310, 40
    value_room = 104
    biggest = max(counts[(g, r)] for g in GROUPS for r, _ in REASONS)
    scale = (col_w - value_room) / biggest

    parts = [text(0, 18, title, 16, "bold")]
    top = 36
    total_x = label_w + total_w - 18
    col_x = {
        GROUPS[0]: label_w + total_w,
        GROUPS[1]: label_w + total_w + col_w + col_gap,
    }
    parts.append(text(total_x, top + 12, "All conflicts", 13, "bold", INK_MUTED, "end"))
    parts.append(text(total_x, top + 29, f"{fmt(grand)} resolutions", 12, fill=INK_MUTED, anchor="end"))
    for group in GROUPS:
        parts.append(text(col_x[group], top + 12, GROUP_TITLES[group], 13, "bold", INK_MUTED))
        parts.append(text(col_x[group], top + 29, f"{fmt(totals[group])} resolutions", 12, fill=INK_MUTED))

    y = top + 42
    row_h, bar_h = 33, 20
    parts.append(f'<line x1="0" y1="{y}" x2="{width}" y2="{y}" stroke="{RULE}" stroke-width="1"/>')
    y += 7
    for reason in ordered:
        mid = y + bar_h / 2
        row_total = sum(counts[(g, reason)] for g in GROUPS)
        parts.append(text(0, mid + 4.5, reason, 13, "bold"))
        parts.append(text(total_x, mid + 4.5, f"{fmt(row_total)} ({pct(row_total, grand)})", 13, anchor="end"))
        for group in GROUPS:
            n = counts[(group, reason)]
            w = n * scale
            if n:
                parts.append(bar(col_x[group], y, max(w, 1.5), bar_h, REASON_COLORS[reason], f"{reason}, {group}: {fmt(n)} ({pct(n, totals[group])})"))
            parts.append(text(col_x[group] + max(w, 1.5) + 6, mid + 4.5, f"{fmt(n)} ({pct(n, totals[group])})", 12, fill=INK_MUTED))
        y += row_h

    y += 12
    for note in notes:
        parts.append(text(0, y, note, 12, fill=INK_MUTED))
        y += 17
    return wrap_svg(width, int(y + 2), "".join(parts))


def nice_step(maximum, ticks=4):
    raw = maximum / ticks
    power = 10 ** math.floor(math.log10(raw))
    for multiple in (1, 2, 2.5, 5, 10):
        if multiple * power >= raw:
            return multiple * power
    return 10 * power


def panel_b(monthly, months, ordered, notes, title, width=1040):
    """Stacked monthly bars in two rows that share one scale, so heights compare."""
    used = [r for r, _ in REASONS if r in ordered]
    peaks = {
        g: max(sum(monthly[(m, g, r)] for r in used) for m in months)
        for g in GROUPS
    }
    plot_left, plot_right = 62, width - 10
    plot_w = plot_right - plot_left
    slot = plot_w / len(months)
    bar_w = slot * 0.74
    row_title_h, row_gap = 26, 30
    # Each row is only as tall as it needs, so one pixel is the same count in both.
    scale = 440 / sum(peaks.values())
    step = nice_step(max(peaks.values()), ticks=6)

    parts = [text(0, 18, title, 16, "bold")]
    top = 36

    # Legend in stack order, on rows that wrap to the plot width.
    x, y = 0, top + 10
    for reason in used:
        item_w = 18 + len(reason) * 6 + 18
        if x + item_w > width:
            x, y = 0, y + 22
        parts.append(f'<rect x="{x}" y="{y - 10}" width="12" height="12" rx="2" fill="{REASON_COLORS[reason]}"/>')
        parts.append(text(x + 18, y, reason, 12.5))
        x += item_w
    y += 22

    for index, group in enumerate(GROUPS):
        group_total = sum(monthly[(m, group, r)] for m in months for r in used)
        parts.append(text(0, y + 14, f"{GROUP_TITLES[group]} ({fmt(group_total)} resolutions)", 13, "bold", INK_MUTED))
        y += row_title_h
        row_h = max(peaks[group] * scale, 40)
        base = y + row_h

        tick = 0
        while tick <= peaks[group]:
            ty = base - tick * scale
            color = RULE if tick == 0 else "#e8e7e3"
            parts.append(f'<line x1="{plot_left}" y1="{ty:.1f}" x2="{plot_right}" y2="{ty:.1f}" stroke="{color}" stroke-width="1"/>')
            parts.append(text(plot_left - 8, ty + 4, fmt(int(tick)), 11, fill=INK_MUTED, anchor="end"))
            tick += step

        for i, month in enumerate(months):
            bx = plot_left + i * slot + (slot - bar_w) / 2
            cursor = base
            for reason in used:
                n = monthly[(month, group, reason)]
                if not n:
                    continue
                h = n * scale
                cursor -= h
                parts.append(bar(bx, cursor, bar_w, h, REASON_COLORS[reason], f"{month}, {reason}, {group}: {fmt(n)}"))

        y = base
        if index == len(GROUPS) - 1:
            for i, month in enumerate(months):
                if i % 3 == 0:
                    lx = plot_left + i * slot + slot / 2
                    parts.append(text(lx, y + 18, month, 11, fill=INK_MUTED, anchor="middle"))
            y += 34
        else:
            y += row_gap

    parts.append(text(plot_left, y + 2, "Monthly ClinVar release. Both rows use the same vertical scale.", 12, fill=INK_MUTED))
    y += 21
    for note in notes:
        parts.append(text(0, y, note, 12, fill=INK_MUTED))
        y += 17
    return wrap_svg(width, int(y + 2), "".join(parts))


def find_chrome():
    candidates = [
        os.environ.get("CHROME"),
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        shutil.which("google-chrome"),
        shutil.which("chromium"),
    ]
    return next((c for c in candidates if c and os.path.exists(c)), None)


def write_png(svg_path):
    chrome = find_chrome()
    if not chrome:
        return False
    with open(svg_path) as handle:
        svg = handle.read()
    head = svg[:svg.index(">")]
    width = head.split('width="')[1].split('"')[0]
    height = head.split('height="')[1].split('"')[0]
    png_path = os.path.abspath(svg_path[:-4] + ".png")
    # A failed render must not leave an older PNG beside the new SVG.
    if os.path.exists(png_path):
        os.remove(png_path)
    # Headless Chrome occasionally hangs, so each try has a time limit.
    for _ in range(2):
        with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as tmp:
            page = os.path.join(tmp, "page.html")
            with open(page, "w") as handle:
                handle.write(f'<!doctype html><html><body style="margin:0">{svg}</body></html>')
            try:
                subprocess.run(
                    [
                        chrome, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                        f"--user-data-dir={os.path.join(tmp, 'profile')}",
                        "--force-device-scale-factor=3", f"--window-size={width},{height}",
                        f"--screenshot={png_path}", f"file://{page}",
                    ],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                    check=True, timeout=45,
                )
            except (subprocess.TimeoutExpired, subprocess.CalledProcessError):
                continue
        if os.path.exists(png_path):
            return True
    return False


def write_csv(path, header, rows):
    with open(path, "w", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(header)
        writer.writerows(rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--as-of", help="Last monthly release to include, YYYY-MM-DD. Default: the latest.")
    parser.add_argument("--input", help="Use a saved resolution_events.csv instead of querying BigQuery.")
    parser.add_argument("--out", default="figure6-output", help="Output directory.")
    args = parser.parse_args()

    os.makedirs(args.out, exist_ok=True)
    events_csv = os.path.join(args.out, "resolution_events.csv")
    if args.input:
        if os.path.abspath(args.input) != os.path.abspath(events_csv):
            shutil.copyfile(args.input, events_csv)
    else:
        with open(events_csv, "w") as handle:
            handle.write(run_query(args.as_of))
    with open(events_csv, newline="") as handle:
        rows = list(csv.DictReader(handle))
    if not rows:
        sys.exit("The query returned no rows.")

    unknown = {r["resolution_reason"] for r in rows} - set(REASON_COLORS)
    if unknown:
        raise ValueError(f"Unplaced reasons: {unknown}")

    as_of = rows[0]["as_of_release_date"]
    total = len(rows)
    variants = len({r["variation_id"] for r in rows})
    months = sorted({r["release_month"] for r in rows})
    first_month = months[0]

    counts = collections.Counter((r["conflict_group"], r["resolution_reason"]) for r in rows)
    monthly = collections.Counter((r["release_month"], r["conflict_group"], r["resolution_reason"]) for r in rows)
    by_reason = collections.Counter(r["resolution_reason"] for r in rows)
    ordered = [r for r, _ in by_reason.most_common() if r != "Other"]
    if by_reason["Other"]:
        ordered.append("Other")

    def is_true(value):
        return value == "true"

    # Panel A's table, by conflict type and for all conflicts.
    totals_rows = []
    for group in ["all conflicts", *GROUPS]:
        members = [r for r in rows if group == "all conflicts" or r["conflict_group"] == group]
        for reason in ordered:
            matched = [r for r in members if r["resolution_reason"] == reason]
            totals_rows.append([
                as_of, group, reason, len(matched), len({r["variation_id"] for r in matched}),
                sum(int(r["reason_scv_count"]) for r in matched),
                f"{100 * len(matched) / len(members):.2f}" if members else "0.00",
                sum(is_true(r["returned_by_cutoff"]) for r in matched),
                sum(is_true(r["in_conflict_at_cutoff"]) for r in matched),
                sum(int(r["reason_count"]) > 1 for r in matched),
                sum(is_true(r["cvc_candidate_before"]) for r in matched),
                sum(is_true(r["cvc_candidate_within_60_days"]) for r in matched),
            ])
    write_csv(
        os.path.join(args.out, "figure6a_reason_totals.csv"),
        [
            "as_of_release_date", "conflict_group", "resolution_reason", "resolution_events", "variants",
            "reason_scvs", "percent_of_group", "returned_by_cutoff", "in_conflict_at_cutoff",
            "events_with_multiple_reasons", "events_with_cvc_candidate_before",
            "events_with_cvc_candidate_within_60_days",
        ],
        totals_rows,
    )

    write_csv(
        os.path.join(args.out, "figure6b_monthly.csv"),
        ["as_of_release_date", "release_month", "conflict_group", "resolution_reason", "resolution_events"],
        [[as_of, *k, v] for k, v in sorted(monthly.items())],
    )

    # The most granular breakdown, one row per exact starting state and result.
    granular = collections.defaultdict(lambda: [0, set(), 0, 0, 0])
    for r in rows:
        entry = granular[(r["conflict_group"], r["classification_to_start"], r["resolution_reason"], r["classification_after"])]
        entry[0] += 1
        entry[1].add(r["variation_id"])
        entry[2] += int(r["reason_scv_count"])
        entry[3] += is_true(r["returned_by_cutoff"])
        entry[4] += is_true(r["cvc_candidate_before"])
    write_csv(
        os.path.join(args.out, "figure6_granular.csv"),
        [
            "as_of_release_date", "conflict_group", "classification_to_start", "resolution_reason",
            "classification_after", "resolution_events", "variants", "reason_scvs",
            "returned_by_cutoff", "events_with_cvc_candidate_before",
        ],
        [[as_of, *k, v[0], len(v[1]), v[2], v[3], v[4]] for k, v in sorted(granular.items(), key=lambda kv: (kv[0][0], kv[0][1], -kv[1][0]))],
    )

    # Which submitters drive each reason. One event can name two submitters.
    submitters = collections.defaultdict(lambda: [0, set()])
    for r in rows:
        for name in filter(None, r["changed_submitters"].split(" | ")):
            entry = submitters[(r["resolution_reason"], name)]
            entry[0] += 1
            entry[1].add(r["release_month"])
    write_csv(
        os.path.join(args.out, "figure6_submitter_concentration.csv"),
        ["as_of_release_date", "resolution_reason", "submitter", "resolution_events", "releases", "first_release", "last_release"],
        [
            [as_of, *k, v[0], len(v[1]), min(v[1]), max(v[1])]
            for k, v in sorted(submitters.items(), key=lambda kv: (kv[0][0], -kv[1][0]))
        ],
    )

    returned_flagged = sum(
        is_true(r["returned_by_cutoff"]) for r in rows if r["resolution_reason"] == "Flagged through CvC"
    )
    common = [
        f"ClinVar monthly releases {first_month} to {as_of[:7]}. {fmt(total)} resolutions across {fmt(variants)} variants; a variant that resolves twice counts twice.",
        f"Each resolution is counted in the release where the conflict stopped, with one reason. {fmt(returned_flagged)} of {fmt(by_reason['Flagged through CvC'])} resolutions flagged through CvC were in conflict again later.",
    ]

    outputs = {
        "figure6a.svg": panel_a(counts, ordered, common, "Figure 6A. Reasons ClinVar conflicts resolved, in total"),
        "figure6b.svg": panel_b(monthly, months, ordered, common, "Figure 6B. Reasons ClinVar conflicts resolved, by monthly release"),
    }
    png_written = True
    for name, svg in outputs.items():
        path = os.path.join(args.out, name)
        with open(path, "w") as handle:
            handle.write(svg)
        png_written = write_png(path) and png_written

    print(f"Releases {first_month} to {as_of}: {fmt(total)} resolutions, {fmt(variants)} variants")
    for reason in ordered:
        med = counts[(GROUPS[0], reason)]
        non = counts[(GROUPS[1], reason)]
        print(f"  {reason:34}{fmt(by_reason[reason]):>8}  {pct(by_reason[reason], total):>6}  medsig {fmt(med):>6}  non {fmt(non):>6}")
    print(f"Wrote {args.out}" + ("" if png_written else " (some PNGs missing: Chrome was not found or did not finish, set CHROME or rerun)"))


if __name__ == "__main__":
    main()
