#!/usr/bin/env python3
"""Generate manuscript Figure 6 from 06-conflict-resolution-reasons.sql.

Figure 6A is the total number of ClinVar conflict resolutions by reason. Figure 6B
is the same counts by monthly release. Both cover medically significant conflicts;
Figures 6A-Supp and 6B-Supp are the same panels for non-medically significant
ones. Each is its own titled image on its own scale.

Unlike the other figures, the flagged bar counts every flagged submission: flags
submitted through CvC and flags from NCBI or ClinGen outside CvC. The script reads
each of those outside flags' source from its ClinVar release and writes them to
figure6_flag_sources.csv, so the footnotes can give the NCBI and ClinGen counts.

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

# Each figure label, its color and the reasons from the SQL it counts. Colors stay
# with a label in every image, as STYLE.md assigns them: flags in the CvC color,
# the submitter's own changes in category 1, new higher ranked submissions in
# category 2, and Other in neutral. A raised rank is the submitter's own change, so
# it takes category 1's middle step, placed after category 2 to keep it away from
# the other category 1 steps. Flags from NCBI and ClinGen outside CvC count with
# the flags submitted through CvC, which only Figure 6 does. Rows and legends
# follow this order, flags first; in 6B stacks the flag segment is on top. A label
# with no resolutions at all, such as an empty Other, is left out.
FIGURE_REASONS = [
    ("Submission(s) flagged through CvC", COLORS["cvc"], ["Flagged through CvC", "Flagged outside CvC"]),
    ("Submission(s) reclassified", COLORS["cat1_dark"], ["Reclassified"]),
    ("Submission(s) rank lowered", COLORS["cat1"], ["Rank lowered"]),
    ("Submission(s) removed", COLORS["cat1_light"], ["Removed"]),
    ("Expert panel submission(s) added", COLORS["cat2_dark"], ["Expert panel added"]),
    ("1 star submission(s) added to 0 star conflict", COLORS["cat2"], ["1 star added to 0 star conflict"]),
    ("Submission(s) rank raised", COLORS["cat1_mid"], ["Rank raised"]),
    ("Other", COLORS["neutral"], ["Other"]),
]
FLAGGED = FIGURE_REASONS[0][0]
REASONS = [(label, color) for label, color, _ in FIGURE_REASONS]
FIGURE_LABEL = {source: label for label, _, sources in FIGURE_REASONS for source in sources}
REASON_COLORS = dict(REASONS)
GROUPS = ["medically significant", "non-medically significant"]
GROUP_TITLES = {
    "medically significant": "medically significant",
    "non-medically significant": "non-medically significant",
}
# Medically significant conflicts are the main panels, 6A and 6B; non-medically
# significant ones are their supplements, 6A-Supp and 6B-Supp.
GROUP_PANELS = {"medically significant": ("", ""), "non-medically significant": ("-Supp", "_supp")}


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
    if not total or not n:
        return "0.0%"
    share = 100 * n / total
    return "<0.1%" if share < 0.05 else f"{share:.1f}%"


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


def panel_a(counts, group, note_lines, title, subtitle, flag_detail):
    """One row per reason for one conflict type: a bold label, then its bar and value."""
    width = LAYOUT["width"]
    total = sum(counts[(group, r)] for r, _ in REASONS)
    value_room = 130
    scale = (width - value_room) / max(counts[(group, r)] for r, _ in REASONS)
    bar_h, heading_gap, row_gap = 22, 9, 16

    body = []
    y = 0
    for reason, color in REASONS:
        if not any(counts[(g, reason)] for g in GROUPS):
            continue
        n = counts[(group, reason)]
        y += TYPE["heading"]
        body.append(heading(0, y, reason, flag_detail if reason == FLAGGED else ""))
        y += heading_gap
        w = max(n * scale, 1.5) if n else 0
        if n:
            body.append(rect(0, y, w, bar_h, color))
        body.append(text(w + 6, y + bar_h / 2 + 5, f"{fmt(n)} ({pct(n, total)})"))
        y += bar_h + row_gap

    note_body, bottom = note_block(y - row_gap, note_lines)
    return wrap_svg(bottom, title, body + note_body, subtitle=subtitle)


def nice_step(maximum, ticks=4):
    raw = maximum / ticks
    power = 10 ** math.floor(math.log10(raw))
    for multiple in (1, 2, 2.5, 5, 10):
        if multiple * power >= raw:
            return multiple * power
    return 10 * power


def panel_b(monthly, months, group, note_lines, title, subtitle):
    """Stacked monthly bars for one conflict type, with labelled axes and a legend."""
    width = LAYOUT["width"]
    peak = max(sum(monthly[(m, group, r)] for r, _ in REASONS) for m in months)
    plot_left, plot_right = 74, width
    slot = (plot_right - plot_left) / len(months)
    bar_w = slot * 0.74
    plot_h = 300
    step = nice_step(peak, ticks=5)
    top_tick = math.ceil(peak / step) * step
    scale = plot_h / top_tick
    # Segments shorter than this get no white gap, so small counts stay visible.
    min_gapped = 3

    body = []
    base = 10 + plot_h
    tick = 0
    while tick <= top_tick:
        ty = base - tick * scale
        body.append(line(plot_left, ty, plot_right, ty, COLORS["rule"] if tick == 0 else COLORS["rule_light"]))
        body.append(text(plot_left - 8, ty + 4, fmt(int(tick)), TYPE["tick"], fill=COLORS["ink_muted"], anchor="end"))
        tick += step
    axis_x, axis_y = 14, base - plot_h / 2
    body.append(text(axis_x, axis_y, "Resolutions", TYPE["label"], fill=COLORS["ink_muted"], anchor="middle",
                     extra=f' transform="rotate(-90 {axis_x} {axis_y:.1f})"'))

    for i, month in enumerate(months):
        bx = plot_left + i * slot + (slot - bar_w) / 2
        cursor = base
        stacked = []
        for reason, color in REASONS[1:] + REASONS[:1]:
            n = monthly[(month, group, reason)]
            if n:
                h = n * scale
                cursor -= h
                body.append(rect(bx, cursor, bar_w, h, color))
                stacked.append((cursor, h))
        for (top, h), (_, above_h) in zip(stacked, stacked[1:]):
            if h >= min_gapped and above_h >= min_gapped:
                body.append(line(bx, top, bx + bar_w, top, COLORS["surface"], LAYOUT["bar_gap"]))

    y = base
    for i, month in enumerate(months):
        if i % 3 == 0:
            lx = plot_left + i * slot + slot / 2
            body.append(text(lx, y + 20, month, TYPE["tick"], fill=COLORS["ink_muted"], anchor="middle"))
    y += 20 + 24
    body.append(text((plot_left + plot_right) / 2, y, "Monthly ClinVar release", TYPE["label"],
                     fill=COLORS["ink_muted"], anchor="middle"))

    # Horizontal legend beneath the plot, in 6A's row order, flags first.
    legend_y = y + 20
    used = [(r, c) for r, c in REASONS if any(monthly[(m, group, r)] for m in months)]
    legend_body, legend_height = legend(plot_left, legend_y, used, width - plot_left)
    note_body, bottom = note_block(legend_y + legend_height, note_lines)
    return wrap_svg(bottom, title, body + legend_body + note_body, subtitle=subtitle)


def flag_sources(rows, out_dir, saved):
    """Who flagged each resolution flagged outside CvC: NCBI, ClinGen or both.

    Flag comments live only in each release's own scv_summary, so this looks them
    up release by release, unless a saved figure6_flag_sources.csv covers every
    such resolution. Returns {(snapshot_release_date, variation_id): source}.
    """
    outside = [r for r in rows if r["resolution_reason"] == "Flagged outside CvC"]
    keys = {(r["snapshot_release_date"], r["variation_id"]) for r in outside}
    path = os.path.join(out_dir, "figure6_flag_sources.csv")
    if saved and os.path.exists(saved):
        with open(saved, newline="") as handle:
            found = {(r["snapshot_release_date"], r["variation_id"]): r["flag_source"] for r in csv.DictReader(handle)}
        if keys <= set(found):
            if os.path.abspath(saved) != os.path.abspath(path):
                shutil.copyfile(saved, path)
            return found

    def bq(sql):
        result = subprocess.run(
            ["bq", "--quiet", "--project_id=clingen-dev", "query", "--use_legacy_sql=false",
             "--format=csv", "--max_rows=1000000", sql],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            sys.exit(f"bq query failed:\n{result.stdout}\n{result.stderr}")
        return list(csv.DictReader(result.stdout.splitlines()))

    parts = []
    for release in sorted({d for d, _ in keys}):
        schema = bq(f"SELECT schema_name FROM clinvar_ingest.schema_on(DATE '{release}')")[0]["schema_name"]
        pairs = ", ".join(
            f"STRUCT('{v}' AS variation_id, '{scv}' AS scv_id)"
            for r in outside if r["snapshot_release_date"] == release
            for v, scv in [(r["variation_id"], s) for s in r["reason_scvs"].split(", ") if s]
        )
        parts.append(
            f"SELECT '{release}' AS snapshot_release_date, p.variation_id, c.source "
            f"FROM UNNEST([{pairs}]) AS p "
            f"LEFT JOIN `{schema}.scv_summary` AS s ON s.id = p.scv_id "
            f"LEFT JOIN UNNEST(s.comments) AS c ON c.type = 'FlaggedComment'"
        )
    found = {}
    if parts:
        sql = (
            "SELECT snapshot_release_date, variation_id, "
            "IFNULL(STRING_AGG(DISTINCT source, ' + ' ORDER BY source), 'none') AS flag_source "
            f"FROM ({' UNION ALL '.join(parts)}) GROUP BY 1, 2"
        )
        found = {(r["snapshot_release_date"], r["variation_id"]): r["flag_source"] for r in bq(sql)}
    write_csv(
        path,
        ["as_of_release_date", "snapshot_release_date", "variation_id", "conflict_group", "resolution_reason",
         "reason_scvs", "changed_submitters", "flag_source"],
        [
            [r["as_of_release_date"], r["snapshot_release_date"], r["variation_id"], r["conflict_group"],
             r["resolution_reason"], r["reason_scvs"], r["changed_submitters"],
             found.get((r["snapshot_release_date"], r["variation_id"]), "none")]
            for r in outside
        ],
    )
    return found


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

    unknown = {r["resolution_reason"] for r in rows} - set(FIGURE_LABEL)
    if unknown:
        raise ValueError(f"Unplaced reasons: {unknown}")

    as_of = rows[0]["as_of_release_date"]
    total = len(rows)
    variants = len({r["variation_id"] for r in rows})
    months = sorted({r["release_month"] for r in rows})
    first_month = months[0]

    # The images count figure labels; the CSVs keep the SQL reason beside its label.
    counts = collections.Counter((r["conflict_group"], FIGURE_LABEL[r["resolution_reason"]]) for r in rows)
    monthly = collections.Counter((r["release_month"], r["conflict_group"], FIGURE_LABEL[r["resolution_reason"]]) for r in rows)
    source_monthly = collections.Counter((r["release_month"], r["conflict_group"], r["resolution_reason"]) for r in rows)
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
                as_of, group, FIGURE_LABEL[reason], reason, len(matched), len({r["variation_id"] for r in matched}),
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
            "as_of_release_date", "conflict_group", "figure_label", "resolution_reason", "resolution_events", "variants",
            "reason_scvs", "percent_of_group", "returned_by_cutoff", "in_conflict_at_cutoff",
            "events_with_multiple_reasons", "events_with_cvc_candidate_before",
            "events_with_cvc_candidate_within_60_days",
        ],
        totals_rows,
    )

    write_csv(
        os.path.join(args.out, "figure6b_monthly.csv"),
        ["as_of_release_date", "release_month", "conflict_group", "figure_label", "resolution_reason", "resolution_events"],
        [[as_of, m, g, FIGURE_LABEL[r], r, v] for (m, g, r), v in sorted(source_monthly.items())],
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

    sources = flag_sources(rows, args.out, os.path.join(os.path.dirname(args.input), "figure6_flag_sources.csv") if args.input else None)
    outputs = {}
    for group in GROUPS:
        members = [r for r in rows if r["conflict_group"] == group]
        flagged = [r for r in members if FIGURE_LABEL[r["resolution_reason"]] == FLAGGED]
        outside = collections.Counter(
            sources.get((r["snapshot_release_date"], r["variation_id"]), "none")
            for r in members if r["resolution_reason"] == "Flagged outside CvC"
        )
        outside_text = " and ".join(f"{fmt(n)} {source}" for source, n in sorted(outside.items()))
        flag_detail = f"includes {outside_text} flags outside CvC" if outside else ""
        group_note = [
            f"ClinVar monthly releases {first_month} to {as_of[:7]}. {fmt(len(members))} resolutions across "
            f"{fmt(len({r['variation_id'] for r in members}))} variants; a variant that resolves twice counts twice.",
            f"Each resolution is counted in the release where the conflict stopped, with one reason. "
            f"{fmt(sum(is_true(r['returned_by_cutoff']) for r in flagged))} of {fmt(len(flagged))} resolutions "
            f"from flagged submissions were in conflict again later.",
            "Unlike the other figures, flagged submissions here include flags not submitted through CvC"
            + (f": {outside_text} flags." if outside else ", though none of these resolutions has one."),
            f"Left out: the discordance project retraction's flags and removals (batch 129), on {fmt(int(rows[0]['excluded_scvs']))} SCVs. "
            f"{fmt(int(rows[0]['dropped_flag_resolutions']))} flag resolutions in all conflicts, credited only to those flags, are dropped.",
        ]
        subtitle = f"n={fmt(len(members))} resolutions, ClinVar release {as_of}"
        label, suffix = GROUP_PANELS[group]
        outputs[f"figure6a{suffix}.svg"] = panel_a(
            counts, group, group_note,
            f"Figure 6A{label}. Reasons {GROUP_TITLES[group]} ClinVar conflicts resolved, in total", subtitle, flag_detail,
        )
        outputs[f"figure6b{suffix}.svg"] = panel_b(
            monthly, months, group, group_note,
            f"Figure 6B{label}. Reasons {GROUP_TITLES[group]} ClinVar conflicts resolved, by monthly release", subtitle,
        )
    png_written = True
    for name, svg in outputs.items():
        path = os.path.join(args.out, name)
        with open(path, "w") as handle:
            handle.write(svg)
        png_written = write_png(path) and png_written

    print(f"Releases {first_month} to {as_of}: {fmt(total)} resolutions, {fmt(variants)} variants")
    for reason, _ in REASONS:
        med = counts[(GROUPS[0], reason)]
        non = counts[(GROUPS[1], reason)]
        print(f"  {reason:48}{fmt(med + non):>8}  {pct(med + non, total):>6}  medsig {fmt(med):>6}  non {fmt(non):>6}")
    print(f"Wrote {args.out}" + ("" if png_written else " (some PNGs missing: Chrome was not found or did not finish, set CHROME or rerun)"))


if __name__ == "__main__":
    main()
