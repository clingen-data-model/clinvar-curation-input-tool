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

from figure_style import COLORS, LAYOUT, TYPE, legend, line, notes, rect, text, wrap_svg, write_csv, write_png

EVENTS_QUERY = """
SELECT *
FROM `clinvar_ingest.manuscript_figure6_resolution_events`(@as_of)
ORDER BY snapshot_release_date, variation_id
"""

# Colors stay with a reason in every panel, as STYLE.md assigns them: CvC flags in
# the CvC color, the submitter's own changes in category 1, new higher ranked
# submissions in category 2, and flags from elsewhere and Other in neutral. Bars
# stack in this order, with the submitter's own changes first, then flags, then
# new higher ranked submissions.
REASONS = [
    ("Reclassified", COLORS["cat1_dark"]),
    ("Rank lowered", COLORS["cat1"]),
    ("Removed", COLORS["cat1_light"]),
    ("Flagged through CvC", COLORS["cvc"]),
    ("Flagged outside CvC", COLORS["neutral_dark"]),
    ("Expert panel added", COLORS["cat2_dark"]),
    ("1 star added to 0 star conflict", COLORS["cat2"]),
    ("Other", COLORS["neutral"]),
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


def heading(x, y, name, detail):
    """A heading on one line: the name in bold, then detail (such as n=) in muted label type."""
    return (
        f'<text x="{x:.1f}" y="{y:.1f}" font-size="{TYPE["heading"]}" font-weight="bold" fill="{COLORS["ink"]}">'
        f'{html.escape(name)}<tspan font-size="{TYPE["label"]}" font-weight="normal" fill="{COLORS["ink_muted"]}" dx="8">'
        f'{html.escape(detail)}</tspan></text>'
    )


def note_block(top, note_lines):
    """Footnotes starting LAYOUT["note_gap"] below `top`. Returns (svg list, bottom).

    The bottom is a whole number because write_png passes the SVG height to
    Chrome's --window-size, which rejects decimals.
    """
    first = top + LAYOUT["note_gap"] + TYPE["note"]
    body, height = notes(first, note_lines)
    return body, math.ceil(first + height - TYPE["note"])


def panel_a(counts, ordered, note_lines, title):
    """One row per reason, headed by its all-conflicts total, with one bar per conflict type on a shared scale."""
    width = LAYOUT["width"]
    totals = {g: sum(counts[(g, r)] for r, _ in REASONS) for g in GROUPS}
    grand = sum(totals.values())
    col_gap = 40
    col_w = (width - col_gap) / 2
    col_x = {GROUPS[0]: 0, GROUPS[1]: col_w + col_gap}
    value_room = 118
    biggest = max(counts[(g, r)] for g in GROUPS for r, _ in REASONS)
    scale = (col_w - value_room) / biggest
    bar_h, heading_gap, row_gap = 22, 9, 16

    body = []
    for group in GROUPS:
        body.append(heading(col_x[group], TYPE["heading"], GROUP_TITLES[group], f"n={fmt(totals[group])}"))
    y = TYPE["heading"] + 10
    body.append(line(0, y, width, y))
    y += 12

    for reason in ordered:
        row_total = sum(counts[(g, reason)] for g in GROUPS)
        y += TYPE["heading"]
        body.append(heading(0, y, reason, f"{fmt(row_total)} in all conflicts ({pct(row_total, grand)})"))
        y += heading_gap
        for group in GROUPS:
            n = counts[(group, reason)]
            w = max(n * scale, 1.5) if n else 0
            if n:
                body.append(rect(col_x[group], y, w, bar_h, REASON_COLORS[reason]))
            body.append(text(col_x[group] + w + 6, y + bar_h / 2 + 5, f"{fmt(n)} ({pct(n, totals[group])})"))
        y += bar_h + row_gap

    note_body, bottom = note_block(y - row_gap, note_lines)
    return wrap_svg(bottom, title, body + note_body)


def nice_step(maximum, ticks=4):
    raw = maximum / ticks
    power = 10 ** math.floor(math.log10(raw))
    for multiple in (1, 2, 2.5, 5, 10):
        if multiple * power >= raw:
            return multiple * power
    return 10 * power


def panel_b(monthly, months, ordered, note_lines, title):
    """Stacked monthly bars in two rows that share one scale, so heights compare."""
    width = LAYOUT["width"]
    used = [r for r, _ in REASONS if r in ordered]
    peaks = {
        g: max(sum(monthly[(m, g, r)] for r in used) for m in months)
        for g in GROUPS
    }
    plot_left, plot_right = 50, width
    slot = (plot_right - plot_left) / len(months)
    bar_w = slot * 0.74
    heading_gap, row_gap = 12, 30
    # Each row is only as tall as it needs, so one pixel is the same count in both.
    scale = 440 / sum(peaks.values())
    step = nice_step(max(peaks.values()), ticks=6)
    # Segments shorter than this get no white gap, so small counts stay visible.
    min_gapped = 3

    body = []
    y = 0
    for index, group in enumerate(GROUPS):
        group_total = sum(monthly[(m, group, r)] for m in months for r in used)
        y += TYPE["heading"]
        body.append(heading(plot_left, y, GROUP_TITLES[group], f"n={fmt(group_total)}"))
        y += heading_gap
        row_h = max(peaks[group] * scale, 40)
        base = y + row_h

        tick = 0
        while tick <= peaks[group]:
            ty = base - tick * scale
            body.append(line(plot_left, ty, plot_right, ty, COLORS["rule"] if tick == 0 else COLORS["rule_light"]))
            body.append(text(plot_left - 8, ty + 4, fmt(int(tick)), TYPE["tick"], fill=COLORS["ink_muted"], anchor="end"))
            tick += step

        for i, month in enumerate(months):
            bx = plot_left + i * slot + (slot - bar_w) / 2
            cursor = base
            stacked = []
            for reason in used:
                n = monthly[(month, group, reason)]
                if n:
                    h = n * scale
                    cursor -= h
                    body.append(rect(bx, cursor, bar_w, h, REASON_COLORS[reason]))
                    stacked.append((cursor, h))
            for (top, h), (_, above_h) in zip(stacked, stacked[1:]):
                if h >= min_gapped and above_h >= min_gapped:
                    body.append(line(bx, top, bx + bar_w, top, COLORS["surface"], LAYOUT["bar_gap"]))

        y = base
        if index == len(GROUPS) - 1:
            for i, month in enumerate(months):
                if i % 3 == 0:
                    lx = plot_left + i * slot + slot / 2
                    body.append(text(lx, y + 20, month, TYPE["tick"], fill=COLORS["ink_muted"], anchor="middle"))
            y += 20 + 22
            body.append(text(plot_left, y, "Monthly ClinVar release. Both rows use the same vertical scale.", TYPE["tick"], fill=COLORS["ink_muted"]))
        else:
            y += row_gap

    # Horizontal legend in stack order, beneath the plot.
    legend_y = y + 20
    legend_body, legend_height = legend(plot_left, legend_y, [(r, REASON_COLORS[r]) for r in used], width - plot_left)
    note_body, bottom = note_block(legend_y + legend_height, note_lines)
    return wrap_svg(bottom, title, body + legend_body + note_body)


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
