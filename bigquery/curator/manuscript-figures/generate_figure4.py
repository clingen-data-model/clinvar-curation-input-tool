#!/usr/bin/env python3
"""Generate manuscript Figure 4 from 04-conflict-resolution-outcomes.sql.

Panel A is the share of reviewed variants by outcome. Panel B is a Sankey of the
direction in which conflicts leave that state: medically significant conflicts on
top, non-medically significant conflicts below. Each panel is its own titled image,
drawn with the shared palette, type and sizes in figure_style.py (see STYLE.md).

Uses only the Python standard library and the bq CLI, and needs the table function
that 04-conflict-resolution-outcomes.sql creates. Writes SVG, plus PNG when Chrome
is available, and the CSV tables behind each panel.

    python3 generate_figure4.py --out figure4-output
    python3 generate_figure4.py --as-of 2026-05-31 --out figure4-may2026
    python3 generate_figure4.py --input variant_outcomes.csv --out figure4-output
"""

import argparse
import collections
import csv
import html
import json
import math
import os
import shutil
import subprocess
import sys

from figure_style import COLORS, LAYOUT, TYPE, line, notes, rect, text, wrap_svg, write_csv, write_png

OUTCOMES_QUERY = """
SELECT *
FROM `clinvar_ingest.manuscript_figure4_variant_outcomes`(@as_of)
ORDER BY variation_id
"""

# CvC outcomes are steps of the CvC color, darkest for the largest effect on the
# variant record. No change is neutral. See STYLE.md.
OUTCOMES = [
    ("Conflict resolved", COLORS["cvc_dark"]),
    ("Conflict reduced", COLORS["cvc_mid"]),
    ("Incorrect record flagged", COLORS["cvc"]),
    ("Record modified", COLORS["cvc_light"]),
    ("No change", COLORS["neutral"]),
]

# Destinations use the clinical scale: medically significant, uncertain, okay.
DESTINATIONS = [
    ("P/LP", COLORS["medsig"]),
    ("VUS", COLORS["uncertain"]),
    ("VUS vs B/LB", COLORS["uncertain_light"]),
    ("B/LB", COLORS["ok"]),
]
SOURCE_FILL = COLORS["neutral_dark"]

# Sankey geometry: right edge of the source labels, left edge of the destination
# nodes, and node width.
SANKEY_LEFT = 230
SANKEY_RIGHT = LAYOUT["width"] - 240
SANKEY_NODE = 16

MEDSIG_SOURCES = [
    "P + LP vs VUS",
    "P vs VUS",
    "LP vs VUS",
    "P + LP vs B/LB",
    "P vs B/LB",
    "LP vs B/LB",
    "P/LP vs VUS vs B/LB",
]
NONMEDSIG_SOURCES = ["VUS vs LB", "VUS vs B", "VUS vs B+LB"]


def run_query(as_of):
    param = f"as_of:DATE:{as_of or 'NULL'}"
    result = subprocess.run(
        [
            "bq", "--quiet", "--project_id=clingen-dev", "query", "--use_legacy_sql=false",
            "--format=csv", "--max_rows=1000000", f"--parameter={param}", OUTCOMES_QUERY,
        ],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        sys.exit(f"bq query failed:\n{result.stdout}\n{result.stderr}")
    return result.stdout


def flows_for(rows, group, sources):
    """Return Sankey flows for a conflict group, and the counts left out of it."""
    conflicted = [r for r in rows if r["conflict_group"] == group]
    flows = collections.Counter(
        (r["panel_b_node"], r["after_state"]) for r in conflicted if r["shown_in_panel_b"] == "true"
    )
    missing = {s for s, _ in flows} - set(sources)
    if missing:
        raise ValueError(f"Unplaced sources: {missing}")
    no_classification = sum(1 for r in conflicted if r["after_state"] == "No classification")
    remained = len(conflicted) - sum(flows.values()) - no_classification
    return flows, len(conflicted), remained, no_classification


def fmt(n):
    return f"{n:,}"


def pct(n, total):
    return f"{100 * n / total:.1f}%" if total else "0.0%"


def wedge(cx, cy, r, start, end, fill, title):
    x0, y0 = cx + r * math.sin(start), cy - r * math.cos(start)
    x1, y1 = cx + r * math.sin(end), cy - r * math.cos(end)
    large = 1 if end - start > math.pi else 0
    return (
        f'<path d="M{cx:.2f},{cy:.2f} L{x0:.2f},{y0:.2f} A{r},{r} 0 {large} 1 {x1:.2f},{y1:.2f} Z" '
        f'fill="{fill}" stroke="{COLORS['surface']}" stroke-width="{LAYOUT['bar_gap']}"><title>{html.escape(title)}</title></path>'
    )


def panel_a(counts, total, flagged, as_of, title):
    parts = []
    cx, cy, r = 160, 160, 150
    angle = 0.0
    label_x = 400
    label_rows = []
    for name, color in OUTCOMES:
        n = counts.get(name, 0)
        sweep = 2 * math.pi * n / total if total else 0
        parts.append(wedge(cx, cy, r, angle, angle + sweep, color, f"{name}: {fmt(n)} ({pct(n, total)})"))
        label_rows.append((name, color, n, angle + sweep / 2))
        angle += sweep

    # Slices sit in the upper right, so labels stack in that order to keep the
    # leader lines from crossing.
    y = cy - 128
    for name, color, n, mid in label_rows:
        ex, ey = cx + (r + 2) * math.sin(mid), cy - (r + 2) * math.cos(mid)
        if name == "No change":
            # The middle of this wedge is on the far side of the pie, so the
            # leader meets the edge level with the label instead.
            y = max(y + 18, cy + 96)
            ey = y - 5
            ex = cx + math.sqrt(max((r + 2) ** 2 - (ey - cy) ** 2, 0))
        parts.append(
            f'<polyline points="{ex:.1f},{ey:.1f} {label_x - 22},{y - 5:.1f} {label_x - 6},{y - 5:.1f}" '
            f'fill="none" stroke="{COLORS['rule']}" stroke-width="1"/>'
        )
        parts.append(rect(label_x, y - 12, LAYOUT["legend_swatch"], LAYOUT["legend_swatch"], color, ' rx="2"'))
        parts.append(text(label_x + 22, y, name, TYPE["label"], "bold"))
        parts.append(text(label_x + 22, y + 19, f"{fmt(n)} ({pct(n, total)})", TYPE["label"], fill=COLORS["ink_muted"]))
        y += 50

    note_parts, note_h = notes(2 * cy + LAYOUT["note_gap"] + TYPE["note"], [
        f"Each variant is counted once, by the outcome of its batch's flagging candidates at the point of submission. Batches through {as_of}.",
    ])
    parts += note_parts
    subtitle = f"{fmt(total)} variants reviewed; {fmt(flagged)} with a flagging candidate submitted"
    return wrap_svg(2 * cy + LAYOUT["note_gap"] + note_h, title, parts, subtitle=subtitle)


def ribbon(x0, x1, y0a, y0b, y1a, y1b, fill, title):
    mid = (x0 + x1) / 2
    return (
        f'<path d="M{x0},{y0a:.2f} C{mid},{y0a:.2f} {mid},{y1a:.2f} {x1},{y1a:.2f} '
        f'L{x1},{y1b:.2f} C{mid},{y1b:.2f} {mid},{y0b:.2f} {x0},{y0b:.2f} Z" '
        f'fill="{fill}" fill-opacity="0.5"><title>{html.escape(title)}</title></path>'
    )


def node(x, y, width, height, fill, title):
    """A Sankey node with a hover title."""
    return rect(x, y, width, height, fill)[:-2] + f"><title>{html.escape(title)}</title></rect>"


def sankey_section(flows, sources, top, plot_height):
    """One two column Sankey drawn from y=top. Ribbons and nodes share one scale,
    so widths are true within the section. Returns (svg list, bottom y)."""
    sources = [s for s in sources if any(k[0] == s for k in flows)]
    dest_colors = dict(DESTINATIONS)
    dests = [d for d, _ in DESTINATIONS if any(k[1] == d for k in flows)]
    total = sum(flows.values())
    src_totals = {s: sum(v for k, v in flows.items() if k[0] == s) for s in sources}
    dst_totals = {d: sum(v for k, v in flows.items() if k[1] == d) for d in dests}

    parts = []
    # Gaps need room for two lines of label, so small nodes do not collide.
    min_gap = 38
    scale = (plot_height - min_gap * (max(len(sources), len(dests)) - 1)) / total

    def place(names, totals):
        used = sum(totals[n] * scale for n in names)
        gap = (plot_height - used) / max(len(names) - 1, 1)
        y = top
        placed = {}
        for name in names:
            placed[name] = y
            y += totals[name] * scale + gap
        return placed

    src_y = place(sources, src_totals)
    dst_y = place(dests, dst_totals)
    src_cursor, dst_cursor = dict(src_y), dict(dst_y)

    # Keep ribbons in destination order at each source, and source order at each
    # destination, which minimizes crossings.
    for src in sources:
        for dst in dests:
            n = flows.get((src, dst), 0)
            if not n:
                continue
            h = n * scale
            y0, y1 = src_cursor[src], dst_cursor[dst]
            parts.append(ribbon(
                SANKEY_LEFT + SANKEY_NODE, SANKEY_RIGHT, y0, y0 + h, y1, y1 + h, dest_colors[dst],
                f"{src} to {dst}: {fmt(n)} ({pct(n, total)})",
            ))
            if h >= 16:
                parts.append(text(SANKEY_LEFT + SANKEY_NODE + 6, y0 + h / 2 + 5, fmt(n), TYPE["tick"]))
            src_cursor[src] += h
            dst_cursor[dst] += h

    for src in sources:
        h = max(src_totals[src] * scale, 1.5)
        y = src_y[src]
        parts.append(node(SANKEY_LEFT, y, SANKEY_NODE, h, SOURCE_FILL, f"{src}: {fmt(src_totals[src])}"))
        mid = y + h / 2
        parts.append(text(SANKEY_LEFT - 8, mid - 3, src, TYPE["label"], "bold", anchor="end"))
        parts.append(text(SANKEY_LEFT - 8, mid + 15, f"{fmt(src_totals[src])} ({pct(src_totals[src], total)})", TYPE["label"], fill=COLORS["ink_muted"], anchor="end"))

    for dst in dests:
        h = max(dst_totals[dst] * scale, 1.5)
        y = dst_y[dst]
        parts.append(node(SANKEY_RIGHT, y, SANKEY_NODE, h, dest_colors[dst], f"{dst}: {fmt(dst_totals[dst])}"))
        mid = y + h / 2
        parts.append(text(SANKEY_RIGHT + SANKEY_NODE + 8, mid - 3, dst, TYPE["label"], "bold"))
        parts.append(text(SANKEY_RIGHT + SANKEY_NODE + 8, mid + 15, f"{fmt(dst_totals[dst])} ({pct(dst_totals[dst], total)})", TYPE["label"], fill=COLORS["ink_muted"]))

    return parts, top + plot_height + 8


def panel_b(sections, closing_notes, title):
    """Sankeys stacked top to bottom under one pair of column headings.

    sections are (heading, flows, sources, footnotes, plot_height). Each section
    has its own scale, which closing_notes should say."""
    head_y = TYPE["heading"]
    parts = [
        text(SANKEY_LEFT + SANKEY_NODE, head_y, "Top ranked group when flagged", TYPE["heading"], "bold", anchor="end"),
        text(SANKEY_RIGHT, head_y, "Top ranked group after flagging", TYPE["heading"], "bold"),
    ]
    y = head_y + 12
    for i, (heading, flows, sources, footnotes, plot_height) in enumerate(sections):
        if i:
            y += 26
            parts.append(line(0, y, LAYOUT["width"], y, COLORS["rule"]))
        y += 30
        parts.append(text(0, y, heading, TYPE["heading"], "bold"))
        body, y = sankey_section(flows, sources, y + 22, plot_height)
        parts += body
        note_parts, note_h = notes(y + LAYOUT["note_gap"] + TYPE["note"], footnotes)
        parts += note_parts
        y += LAYOUT["note_gap"] + note_h
    y += 8
    note_parts, note_h = notes(y + TYPE["note"], closing_notes)
    parts += note_parts
    return wrap_svg(y + note_h, title, parts)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--as-of", help="Last batch_release_date to include, YYYY-MM-DD. Default: all batches.")
    parser.add_argument("--input", help="Use a saved variant_outcomes.csv instead of querying BigQuery.")
    parser.add_argument("--out", default="figure4-output", help="Output directory.")
    args = parser.parse_args()

    os.makedirs(args.out, exist_ok=True)
    variants_csv = os.path.join(args.out, "variant_outcomes.csv")
    if args.input:
        if os.path.abspath(args.input) != os.path.abspath(variants_csv):
            shutil.copyfile(args.input, variants_csv)
    else:
        with open(variants_csv, "w") as handle:
            handle.write(run_query(args.as_of))
    with open(variants_csv, newline="") as handle:
        rows = list(csv.DictReader(handle))
    if not rows:
        sys.exit("The query returned no rows.")

    as_of = rows[0]["as_of_batch_release_date"]
    total = len(rows)
    flagged = sum(1 for r in rows if r["batch_id"])
    counts = collections.Counter(r["figure_4a_outcome"] for r in rows)
    details = collections.Counter((r["figure_4a_outcome"], r["outcome_detail"]) for r in rows)

    write_csv(
        os.path.join(args.out, "figure4a_outcomes.csv"),
        ["as_of_batch_release_date", "outcome", "variants", "percent_of_reviewed"],
        [[as_of, name, counts.get(name, 0), f"{100 * counts.get(name, 0) / total:.2f}"] for name, _ in OUTCOMES],
    )
    write_csv(
        os.path.join(args.out, "figure4a_outcome_detail.csv"),
        ["as_of_batch_release_date", "outcome", "outcome_detail", "variants", "percent_of_reviewed"],
        [[as_of, k[0], k[1], v, f"{100 * v / total:.2f}"] for k, v in sorted(details.items())],
    )

    medsig, medsig_n, medsig_remained, medsig_none = flows_for(rows, "medically significant", MEDSIG_SOURCES)
    nonmed, nonmed_n, nonmed_remained, nonmed_none = flows_for(rows, "non-medically significant", NONMEDSIG_SOURCES)

    def flow_rows(group, flows):
        flow_total = sum(flows.values())
        return [[as_of, group, s, d, n, f"{100 * n / flow_total:.2f}"] for (s, d), n in sorted(flows.items())]

    write_csv(
        os.path.join(args.out, "figure4b_flows.csv"),
        ["as_of_batch_release_date", "conflict_group", "conflict_when_flagged", "state_after_flagging", "variants", "percent_of_group"],
        flow_rows("medically significant", medsig) + flow_rows("non-medically significant", nonmed),
    )

    # The classification labels behind each destination, the third column of the
    # original mock-up.
    final = collections.Counter()
    final_scvs = collections.Counter()
    for row in rows:
        if row["shown_in_panel_b"] == "true" and row["conflict_group"] == "medically significant":
            key = (
                row["panel_b_node"], row["conflict_combination"], row["before_top_rank"],
                row["after_state"], row["after_classif_group"], row["after_top_rank"],
            )
            final[key] += 1
            final_scvs[key] += int(row["resolution_flagged_scvs"])
    write_csv(
        os.path.join(args.out, "figure4b_final_classifications.csv"),
        [
            "as_of_batch_release_date", "conflict_when_flagged", "classification_to_start", "top_rank_to_start",
            "state_after_flagging", "classifications_left", "top_rank_after", "variants", "flagged_scvs",
        ],
        [[as_of, *k, v, final_scvs[k]] for k, v in sorted(final.items(), key=lambda kv: (kv[0][1], -kv[1]))],
    )

    # Every medically significant combination, for the supplement. Panel B groups
    # the smaller ones, and shows only the variants that left that state.
    combinations = collections.Counter(
        (r["conflict_combination"], r["panel_b_node"], r["after_state"], r["shown_in_panel_b"])
        for r in rows if r["conflict_group"] == "medically significant"
    )
    write_csv(
        os.path.join(args.out, "figure4b_conflict_combinations.csv"),
        ["as_of_batch_release_date", "conflict_combination", "panel_b_node", "state_after_flagging", "shown_in_panel_b", "variants"],
        [[as_of, *k, v] for k, v in sorted(combinations.items(), key=lambda kv: (kv[0][0], -kv[1]))],
    )

    # Every rank group touched by a flag, whether or not it decides the aggregate.
    groups = collections.Counter()
    labels = {0: "No classification", 1: "B/LB", 2: "VUS", 3: "VUS vs B/LB", 4: "P/LP", 5: "P/LP vs B/LB", 6: "P/LP vs VUS", 7: "P/LP vs VUS vs B/LB"}
    for row in rows:
        if not row["batch_id"] or row["rank_groups"] in ("", "null"):
            continue
        for group in json.loads(row["rank_groups"]):
            if group["flagged_count"]:
                top = str(group["rank"]) == row["before_top_rank"]
                groups[(group["rank"], "top" if top else "lower", labels[group["before_mask"]], labels[group["after_mask"]])] += 1
    write_csv(
        os.path.join(args.out, "rank_group_transitions.csv"),
        ["as_of_batch_release_date", "rank", "group_position", "state_before", "state_after", "variants"],
        [[as_of, *k, v] for k, v in sorted(groups.items(), key=lambda kv: (-kv[0][0], kv[0][1], -kv[1]))],
    )

    panel_a_svg = panel_a(counts, total, flagged, as_of, "Figure 4A. Outcomes of SCV annotations")

    def notes_for(n, remained, none, name):
        flow_total = n - remained - none
        lines = [f"{fmt(flow_total)} of {fmt(n)} flagged {name} left that state at the point of submission."]
        extra = [f"{fmt(remained)} remained in conflict at that level"] if remained else []
        if none:
            extra.append(f"{fmt(none)} had no classification left")
        if extra:
            lines.append("Not shown: " + "; ".join(extra) + ".")
        return lines

    # Non-medically significant conflicts sit under the medically significant ones.
    # The two are drawn to separate scales, so the small group stays readable.
    panel_b_svg = panel_b(
        [
            ("Medically significant conflicts: P/LP vs VUS or B/LB", medsig, MEDSIG_SOURCES,
             notes_for(medsig_n, medsig_remained, medsig_none, "medically significant conflicts"), 455),
            ("Non-medically significant conflicts: VUS vs B/LB", nonmed, NONMEDSIG_SOURCES,
             notes_for(nonmed_n, nonmed_remained, nonmed_none, "non-medically significant conflicts"), 240),
        ],
        [f"Batches through {as_of}. Ribbon widths are to scale within each section, not between them."],
        "Figure 4B. Direction of conflict resolution",
    )

    outputs = {
        "figure4a.svg": panel_a_svg,
        "figure4b.svg": panel_b_svg,
    }
    png_written = True
    for name, svg in outputs.items():
        path = os.path.join(args.out, name)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(svg)
        png_written = write_png(path) and png_written

    print(f"Batches through {as_of}: {fmt(total)} reviewed, {fmt(flagged)} flagged")
    for name, _ in OUTCOMES:
        print(f"  {name:26}{fmt(counts.get(name, 0)):>8}  {pct(counts.get(name, 0), total):>6}")
    print(f"Medically significant: {fmt(sum(medsig.values()))} of {fmt(medsig_n)} left that state")
    for dest, _ in DESTINATIONS:
        n = sum(v for k, v in medsig.items() if k[1] == dest)
        print(f"  to {dest:23}{fmt(n):>8}  {pct(n, sum(medsig.values())):>6}")
    print(f"Wrote {args.out}" + ("" if png_written else " (some PNGs missing: Chrome was not found or did not finish, set CHROME or rerun)"))


if __name__ == "__main__":
    main()
