#!/usr/bin/env python3
"""Generate manuscript Figures 3A and 3B from 03ab-review-outcomes-and-reasons.sql.

Figure 3A shows the SCVs and variants CvC reviewed, by outcome. Figure 3B shows the
SCVs submitted to ClinVar as flagging candidates, by reason. Each is its own image
file. Figure 3C comes from generate_figure3.py.

Uses only the Python standard library and the bq CLI. Writes SVG, plus PNG when
Chrome is available, and the CSV tables behind the figures.

    python3 generate_figure3ab.py --out output/figure3
    python3 generate_figure3ab.py --as-of 2026-05-27 --out output/figure3-may
    python3 generate_figure3ab.py --input scv_outcomes.csv --out output/figure3

With --input, the discordance project SCVs are read from discordance_scvs.csv in the
same folder as the input, which an earlier run writes.
"""

import argparse
import collections
import csv
import math
import os
import shutil
import subprocess
import sys
import textwrap

from figure_style import COLORS, LAYOUT, TYPE, label_ink, legend, line, notes, rect, text, wrap_svg, write_csv, write_png

OUTCOMES_QUERY = """
SELECT *
FROM `clinvar_ingest.manuscript_figure3ab_scv_outcomes`(@as_of)
"""

# SCVs with a left-out discordance project annotation (00-excluded-scvs.sql). Their
# flags and removals don't count; their other annotations do.
DISCORDANCE_QUERY = """
SELECT scv_id, variation_id, exclusion, excluded_annotations, clinvar_url
FROM `clinvar_ingest.manuscript_excluded_scvs`
ORDER BY scv_id
"""

# Matches Figure 3C, so all three panels read the same date.
DEFAULT_AS_OF = "2026-11-08"

SUBMITTED = "Flagging candidate submitted"
DISCORDANCE = "Discordance project retraction"
ARCHIVED_ONLY = "Only archived reviews (corrected before submission)"
NO_CHANGE = "No change"
NOT_SUBMITTED = "Flagging candidate not submitted"

# Colors by meaning, from STYLE.md: CvC's submissions are CvC teal-green, No change
# is neutral, and candidates CvC did not submit are the darker neutral.
OUTCOMES = [
    (SUBMITTED, COLORS["cvc"]),
    (NO_CHANGE, COLORS["neutral"]),
    (NOT_SUBMITTED, COLORS["neutral_dark"]),
]


def run_query(query, as_of=None):
    parameters = [f"--parameter=as_of:DATE:{as_of}"] if as_of else []
    result = subprocess.run(
        [
            "bq", "--quiet", "--project_id=clingen-dev", "query", "--use_legacy_sql=false",
            "--format=csv", "--max_rows=1000000", *parameters, query,
        ],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        sys.exit(f"bq query failed:\n{result.stdout}\n{result.stderr}")
    return result.stdout


def fmt(n):
    return f"{n:,}"


def pct(n, total):
    return f"{100 * n / total:.1f}%"


def round_up(value, step):
    return math.ceil(value / step) * step


def heading(x, y, name, total):
    """A bar heading on one line: the name in bold, then n= in muted label type."""
    return (
        f'<text x="{x:.1f}" y="{y:.1f}" font-size="{TYPE["heading"]}" font-weight="bold" fill="{COLORS["ink"]}">'
        f'{name}<tspan font-size="{TYPE["label"]}" font-weight="normal" fill="{COLORS["ink_muted"]}" dx="8">n={fmt(total)}</tspan></text>'
    )


def variant_outcomes(rows):
    """A variant takes the first outcome, in the order of OUTCOMES, that any of its SCVs has."""
    by_variant = collections.defaultdict(set)
    for r in rows:
        by_variant[r["variation_id"]].add(r["outcome"])
    counts = collections.Counter()
    for outcomes in by_variant.values():
        counts[next(name for name, _ in OUTCOMES if name in outcomes)] += 1
    return counts


def discordance_note(discordance, rows):
    """The footnote for the discordance project's left-out annotations (00-excluded-scvs.sql)."""
    ids = {r["scv_id"] for r in discordance}
    still = sum(r["scv_id"] in ids for r in rows)
    return (f"Left out: the discordance project retraction's flags and removals (batch 129), on {fmt(len(ids))} SCVs. "
            f"{fmt(still)} of those SCVs still count through their other annotations.")


def figure3a(scv_counts, variant_counts, submitted_rows, rows, excluded, discordance, as_of, release):
    """Stacked bars of SCVs and variants by outcome, on one count axis."""
    bar_left, bar_right = 0, 880
    bar_height = 64
    heading_gap = 9      # heading baseline above its bar
    row_height = bar_height + 54
    top = TYPE["heading"] + heading_gap
    scv_total = sum(scv_counts.values())
    variant_total = sum(variant_counts.values())
    axis_max = round_up(scv_total, 5000)
    plot_bottom = top + row_height + bar_height

    def x_at(value):
        return bar_left + (bar_right - bar_left) * value / axis_max

    # An outcome with no SCVs is left out of the bars and the legend; the notes say so.
    shown = [(name, fill) for name, fill in OUTCOMES if scv_counts.get(name, 0) or variant_counts.get(name, 0)]

    body = []
    for tick in range(0, axis_max + 1, 5000):
        x = x_at(tick)
        body.append(line(x, top, x, plot_bottom + 6, COLORS["rule_light"] if tick else COLORS["rule"]))
        body.append(text(x, plot_bottom + 22, fmt(tick), TYPE["tick"], fill=COLORS["ink_muted"], anchor="middle"))

    for i, (label, counts, total) in enumerate((
        ("SCVs reviewed", scv_counts, scv_total),
        ("Variants reviewed", variant_counts, variant_total),
    )):
        y = top + row_height * i
        body.append(heading(bar_left, y - heading_gap, label, total))
        position = 0
        for name, fill in shown:
            n = counts.get(name, 0)
            left, right = x_at(position), x_at(position + n)
            body.append(rect(left, y, max(right - left - LAYOUT["bar_gap"], 1), bar_height, fill))
            middle = (left + right) / 2
            if right - left >= 110:
                on_fill = label_ink(fill)
                body.append(text(middle, y + 29, fmt(n), TYPE["heading"], "bold", on_fill, "middle"))
                body.append(text(middle, y + 48, pct(n, total), TYPE["label"], "normal", on_fill, "middle"))
            else:
                body.append(text(right + 6, y + 29, fmt(n), TYPE["heading"], "bold"))
                body.append(text(right + 6, y + 48, pct(n, total), TYPE["label"], fill=COLORS["ink_muted"]))
            position += n

    legend_y = plot_bottom + 44
    legend_body, legend_height = legend(0, legend_y, shown)
    body += legend_body

    status = collections.Counter(r["status_in_release"] for r in submitted_rows)
    retracted = sum(r["later_retracted"] == "true" for r in submitted_rows)
    discordance_ids = {r["scv_id"] for r in discordance}
    note_body, note_height = notes(legend_y + legend_height + LAYOUT["note_gap"] + TYPE["note"], [
        f"Germline pathogenicity SCVs in CvC batches submitted through {as_of}. Each SCV counts once. "
        "A variant counts as submitted if any of its SCVs was, so the variant counts add up to the distinct variants reviewed.",
        f"Submitted does not mean flagged now. In release {release}, of the {fmt(len(submitted_rows))} SCVs submitted: "
        f"{fmt(status['flagged'])} flagged, {fmt(status['not flagged'])} not flagged, "
        f"{fmt(status['not in ClinVar'])} no longer in ClinVar. {fmt(retracted)} were later retracted by CvC.",
        "Archived reviews are ignored, because the annotation was corrected before submission. "
        + ("Not submitted means approved as OK or Fixed but never included in a submission."
           if scv_counts.get(NOT_SUBMITTED, 0) else
           "Every flagging candidate approved as OK or Fixed was submitted."),
        discordance_note(discordance, rows),
        f"Also left out: {fmt(sum(r['exclusion'] == ARCHIVED_ONLY and r['scv_id'] not in discordance_ids for r in excluded))} "
        "other SCVs whose only reviews were archived.",
    ])
    body += note_body
    height = legend_y + legend_height + LAYOUT["note_gap"] + note_height
    return wrap_svg(height, "Figure 3A. CvC review outcomes for SCVs and variants", body)


def figure3b(reasons, total, submitted_rows, rows, discordance, as_of):
    """One bar per flagging reason, largest first, with Other last."""
    label_width = 400
    bar_left, bar_right = label_width + 16, 880
    row_height = 50
    top = 0
    plot_bottom = top + row_height * len(reasons)
    axis_max = round_up(max(n for _, n in reasons), 500)

    def x_at(value):
        return bar_left + (bar_right - bar_left) * value / axis_max

    body = []
    for tick in range(0, axis_max + 1, 500):
        x = x_at(tick)
        body.append(line(x, top, x, plot_bottom + 6, COLORS["rule_light"] if tick else COLORS["rule"]))
        body.append(text(x, plot_bottom + 22, fmt(tick), TYPE["tick"], fill=COLORS["ink_muted"], anchor="middle"))
    body.append(text((bar_left + bar_right) / 2, plot_bottom + 42, "SCVs submitted as flagging candidates", TYPE["tick"],
                     fill=COLORS["ink_muted"], anchor="middle"))
    for i, (reason, n) in enumerate(reasons):
        center = top + row_height * i + row_height / 2
        lines = textwrap.wrap(reason, 58)
        first = center + 5 - (len(lines) - 1) * 8.5
        for j, value in enumerate(lines):
            body.append(text(label_width, first + j * 17, value, TYPE["label"], anchor="end"))
        body.append(rect(bar_left, center - 14, max(x_at(n) - bar_left, 1), 28, COLORS["cvc"]))
        body.append(text(x_at(n) + 6, center + 5, f"{fmt(n)} ({pct(n, total)})", TYPE["label"], "bold"))
    note_top = plot_bottom + 42 + LAYOUT["note_gap"] + TYPE["note"]
    note_body, note_height = notes(note_top, [
        f"{fmt(total)} germline pathogenicity SCVs in CvC batches submitted through {as_of}. "
        "Each SCV has the reason from its most recent valid submission. "
        f"{fmt(sum(r['later_retracted'] == 'true' for r in submitted_rows))} were later retracted by CvC and still count.",
        discordance_note(discordance, rows),
    ])
    body += note_body
    return wrap_svg(note_top + note_height - TYPE["note"], "Figure 3B. SCVs submitted as flagging candidates, by reason", body)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--as-of", default=DEFAULT_AS_OF, help=f"Last batch date to include, YYYY-MM-DD. Default: {DEFAULT_AS_OF}.")
    parser.add_argument("--input", help="Use a saved scv_outcomes.csv instead of querying BigQuery.")
    parser.add_argument("--out", default="output/figure3", help="Output directory.")
    args = parser.parse_args()

    os.makedirs(args.out, exist_ok=True)
    outcomes_csv = os.path.join(args.out, "scv_outcomes.csv")
    discordance_csv = os.path.join(args.out, "discordance_scvs.csv")
    if args.input:
        saved = os.path.join(os.path.dirname(os.path.abspath(args.input)), "discordance_scvs.csv")
        if not os.path.exists(saved):
            sys.exit(f"--input also needs {saved}, which a run without --input writes.")
        for source, target in ((args.input, outcomes_csv), (saved, discordance_csv)):
            if os.path.abspath(source) != os.path.abspath(target):
                shutil.copyfile(source, target)
    else:
        with open(outcomes_csv, "w", encoding="utf-8") as handle:
            handle.write(run_query(OUTCOMES_QUERY, args.as_of))
        with open(discordance_csv, "w", encoding="utf-8") as handle:
            handle.write(run_query(DISCORDANCE_QUERY))
    with open(outcomes_csv, newline="", encoding="utf-8") as handle:
        all_rows = list(csv.DictReader(handle))
    with open(discordance_csv, newline="", encoding="utf-8") as handle:
        discordance = list(csv.DictReader(handle))
    if not discordance:
        sys.exit("The discordance project query returned no rows; deploy 00-excluded-scvs.sql first.")
    if not all_rows:
        sys.exit("The query returned no rows.")
    as_of = all_rows[0]["as_of_date"]
    release = all_rows[0]["release_date"]

    rows = [r for r in all_rows if r["in_scope"] == "true"]
    excluded = [r for r in all_rows if r["in_scope"] != "true"]
    unknown = {r["outcome"] for r in rows} - {name for name, _ in OUTCOMES}
    if unknown:
        sys.exit(f"Unexpected outcomes: {sorted(unknown)}")
    if any(not r["variation_id"] for r in rows):
        sys.exit("An SCV has no variation_id, so the variant counts would be wrong.")

    scv_counts = collections.Counter(r["outcome"] for r in rows)
    variant_counts = variant_outcomes(rows)
    submitted_rows = [r for r in rows if r["outcome"] == SUBMITTED]
    reason_counts = collections.Counter(r["submitted_reason"] for r in submitted_rows)
    reasons = sorted(reason_counts.items(), key=lambda kv: (kv[0] == "Other", -kv[1]))
    submitted_total = len(submitted_rows)

    write_csv(
        os.path.join(args.out, "figure3a_outcomes.csv"),
        ["as_of_date", "release_date", "outcome", "scvs", "scv_pct", "variants", "variant_pct"],
        [[as_of, release, name, scv_counts[name], f"{100 * scv_counts[name] / len(rows):.2f}",
          variant_counts[name], f"{100 * variant_counts[name] / sum(variant_counts.values()):.2f}"]
         for name, _ in OUTCOMES],
    )
    write_csv(
        os.path.join(args.out, "figure3b_reasons.csv"),
        ["as_of_date", "release_date", "reason", "scvs", "scv_pct"],
        [[as_of, release, reason, n, f"{100 * n / submitted_total:.2f}"] for reason, n in reasons],
    )
    # One row per SCV: discordance project SCVs first, with what happened to each,
    # then the other reviewed SCVs left out of both figures.
    by_scv = {r["scv_id"]: r for r in all_rows}
    discordance_ids = {r["scv_id"] for r in discordance}

    def effect(row):
        if row is None:
            return "Not in either figure: it has no other reviewed annotation"
        if row["in_scope"] != "true":
            return f"Not in either figure: {row['exclusion']}"
        return f"Counts as {row['outcome']} from its other annotations"

    write_csv(
        os.path.join(args.out, "figure3ab_excluded_scvs.csv"),
        ["as_of_date", "exclusion", "scv_id", "variation_id", "proposition_type", "final_action", "outcome", "effect"],
        [[as_of, d["exclusion"], d["scv_id"], d["variation_id"],
          *([by_scv[d["scv_id"]][k] for k in ("proposition_type", "final_action", "outcome")] if d["scv_id"] in by_scv else ["", "", ""]),
          effect(by_scv.get(d["scv_id"]))] for d in discordance]
        + [[as_of, r["exclusion"], r["scv_id"], r["variation_id"], r["proposition_type"], r["final_action"], r["outcome"],
            "Not in either figure"] for r in excluded if r["scv_id"] not in discordance_ids],
    )

    outputs = {
        "figure3a.svg": figure3a(scv_counts, variant_counts, submitted_rows, rows, excluded, discordance, as_of, release),
        "figure3b.svg": figure3b(reasons, submitted_total, submitted_rows, rows, discordance, as_of),
    }
    png_written = True
    for name, svg in outputs.items():
        path = os.path.join(args.out, name)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(svg)
        png_written = write_png(path) and png_written

    print(f"Through {as_of}, release {release}: {fmt(len(rows))} SCVs and {fmt(sum(variant_counts.values()))} variants reviewed; {fmt(len(excluded))} reviewed SCVs excluded; discordance project annotations left out on {fmt(len(discordance))} SCVs")
    for name, _ in OUTCOMES:
        print(f"  {name:34}{fmt(scv_counts[name]):>8} SCVs {fmt(variant_counts[name]):>8} variants")
    for reason, n in reasons:
        print(f"  {fmt(n):>6} {pct(n, submitted_total):>6}  {reason}")
    print(f"Wrote {args.out}" + ("" if png_written else " (some PNGs missing: Chrome was not found or did not finish, set CHROME or rerun)"))


if __name__ == "__main__":
    main()
