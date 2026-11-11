#!/usr/bin/env python3
"""Generate manuscript Figure 5 from 05-gdr-flags-by-domain.sql.

Figure 5 shows the CvC flags for insufficient gene-disease evidence that are in
ClinVar on one release, as a bar per clinical domain, stacked by the validity level
that prompted the flag.

Uses only the Python standard library and the bq CLI, and needs the table function
that 05-gdr-flags-by-domain.sql creates. Writes SVG, plus PNG when Chrome is
available, and the CSV tables behind the figure.

    python3 generate_figure5.py --out output/figure5
    python3 generate_figure5.py --as-of 2026-05-31 --out output/figure5-may2026
    python3 generate_figure5.py --input output/figure5/flags.csv --out output/figure5
"""

import argparse
import collections
import csv
import html
import io
import os
import subprocess
import sys

from figure_style import COLORS, LAYOUT, TYPE, label_ink, legend, line, notes, rect, text, wrap_svg, write_csv, write_png

FLAGS_QUERY = """
SELECT *
FROM `clinvar_ingest.manuscript_figure5_flags`(@as_of)
ORDER BY scv_id
"""

# Validity levels are legend-named categories, so they take category 1's steps,
# darker for stronger evidence against the gene-disease relationship (STYLE.md).
# No Known never reaches the figure on the current data; it takes the next unused
# category color so it can't be mistaken for one of the three levels. Not recorded
# is neutral because it is missing information rather than a level.
LEVELS = [
    ("Limited", COLORS["cat1_light"]),
    ("Disputed", COLORS["cat1"]),
    ("Refuted", COLORS["cat1_dark"]),
    ("No Known", COLORS["cat2"]),
    ("Not recorded", COLORS["neutral"]),
]

# All clinical domain working groups, so that a domain with no flags shows as 0.
DOMAINS = [
    "Cardiovascular",
    "Hearing Loss",
    "Hemostasis/Thrombosis",
    "Hereditary Cancer",
    "Immunology",
    "Inborn Errors of Metabolism",
    "Kidney Disease",
    "Neurodevelopmental Disorders",
    "Neurological Disorders",
    "Ocular",
    "Other",
    "Pulmonary",
    "RASopathy",
    "Rheumatologic Autoimmune Disease",
    "Skeletal Disorders",
    "Somatic Cancer",
]


def run_query(as_of):
    param = f"as_of:DATE:{as_of or 'NULL'}"
    result = subprocess.run(
        [
            "bq", "--quiet", "--project_id=clingen-dev", "query", "--use_legacy_sql=false",
            "--format=csv", "--max_rows=1000000", f"--parameter={param}", FLAGS_QUERY,
        ],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        sys.exit(f"bq query failed:\n{result.stdout}\n{result.stderr}")
    return result.stdout


def is_true(value):
    return value == "true"


def fmt(n):
    return f"{n:,}"


def domain_level_counts(rows):
    """Return flag counts per domain and level, for the rows in the figure."""
    counts = collections.defaultdict(collections.Counter)
    for row in rows:
        if is_true(row["shown_in_figure"]):
            counts[row["clinical_domain"]][row["figure_level"]] += 1
    return counts


def figure_svg(rows, as_of):
    counts = domain_level_counts(rows)
    # A flag can only reach the figure with a domain, unless its gene is not in the
    # export. Such a flag gets its own row rather than disappearing.
    domains = DOMAINS + sorted(set(counts) - set(DOMAINS))
    domains.sort(key=lambda d: (-sum(counts[d].values()), d))
    levels = [(n, c) for n, c in LEVELS if any(counts[d][n] for d in domains)]
    total = sum(sum(counts[d].values()) for d in domains)
    max_count = max((sum(counts[d].values()) for d in domains), default=1) or 1

    width = LAYOUT["width"]
    step = 10 if max_count > 20 else 5
    axis_max = -(-max_count // step) * step
    scale = width / axis_max
    bar_height, heading_gap, row_gap = 20, 7, 12
    gap = LAYOUT["bar_gap"]

    # Each domain's heading sits just above its bar, with n= to the right. A domain
    # with no flags keeps its heading so all clinical domains are listed.
    body, y = [], 0
    for domain in domains:
        domain_total = sum(counts[domain].values())
        y += TYPE["label"]
        # n= is a tspan of the heading so it follows the name at a fixed gap.
        heading = text(0, y, domain, TYPE["label"])
        body.append(heading[:-len("</text>")]
                    + f'<tspan dx="10" fill="{COLORS["ink_muted"]}">n={domain_total}</tspan></text>')
        if not domain_total:
            y += row_gap
            continue
        y += heading_gap
        x = 0
        for name, color in levels:
            count = counts[domain][name]
            if not count:
                continue
            segment = max(count * scale - gap, gap)
            tip = html.escape(f"{domain}, {name}: {count} SCVs")
            body.append(rect(x, y, segment, bar_height, color)[:-2] + f"><title>{tip}</title></rect>")
            # Light fills are below 3:1 on white, so wide segments carry their value.
            if segment >= 30:
                body.append(text(x + segment / 2, y + 15, count, TYPE["tick"], "bold",
                                 label_ink(color), "middle"))
            x += count * scale
        y += bar_height + row_gap

    # Value axis along the bottom, ticks only, so it doesn't cross the headings.
    body.append(line(0, y, width, y, COLORS["rule"]))
    for tick in range(0, axis_max + 1, step):
        body.append(line(tick * scale, y, tick * scale, y + 5, COLORS["rule"]))
        body.append(text(tick * scale, y + 20, tick, TYPE["tick"], fill=COLORS["ink_muted"],
                         anchor="end" if tick == axis_max else "middle" if tick else "start"))
    body.append(text(width / 2, y + 40, "Flagged SCVs", TYPE["tick"], fill=COLORS["ink_muted"], anchor="middle"))
    y += 40 + 24

    entries, legend_height = legend(0, y, levels)
    body += entries
    y += legend_height + LAYOUT["note_gap"] + TYPE["note"]

    retracted = sum(r["flag_status"] == "retracted" for r in rows)
    not_in_clinvar = sum(r["flag_status"] == "standing" and not is_true(r["flagged_in_clinvar"]) for r in rows)
    note_body, note_height = notes(y, [
        f"Counts {fmt(total)} of {fmt(len(rows))} CvC flags with this reason. Left out: {fmt(retracted)} that CvC "
        f"later retracted and {fmt(not_in_clinvar)} not flagged in ClinVar on this release.",
        "Level is the one named in the curator's note, or ClinGen's when the note names none. Not recorded: "
        "neither gives one. Domain is the clinical domain of the ClinGen expert panel that curated the gene.",
    ])
    body += note_body
    y += note_height - TYPE["note"]

    title = "Figure 5. CvC flags for insufficient gene-disease evidence, by clinical domain"
    subtitle = (f"{fmt(total)} P/LP SCVs flagged in ClinVar on the {as_of} release, stacked by the "
                "validity level that prompted the flag")
    return wrap_svg(y, title, body, subtitle=subtitle)


def domain_level_rows(rows):
    groups = collections.defaultdict(list)
    for row in rows:
        groups[(row["clinical_domain"], row["figure_level"])].append(row)
    table = []
    for (domain, level), members in sorted(groups.items()):
        shown = [r for r in members if is_true(r["shown_in_figure"])]
        table.append([
            domain, level, len(shown),
            len({r["variation_id"] for r in shown}),
            len({r["gene_symbol"] for r in shown}),
            sum(r["flag_status"] == "standing" and not is_true(r["flagged_in_clinvar"]) for r in members),
            sum(r["flag_status"] == "retracted" for r in members),
            len(members),
        ])
    return table


def gene_rows(rows):
    groups = collections.defaultdict(list)
    for row in rows:
        groups[row["gene_symbol"]].append(row)
    table = []
    for gene, members in groups.items():
        table.append([
            gene,
            members[0]["clingen_low_levels"],
            members[0]["gene_has_moderate_or_higher"],
            " | ".join(sorted({r["clinical_domain"] for r in members})),
            " | ".join(sorted({r["figure_level"] for r in members})),
            sum(is_true(r["shown_in_figure"]) for r in members),
            sum(r["flag_status"] == "standing" and not is_true(r["flagged_in_clinvar"]) for r in members),
            sum(r["flag_status"] == "retracted" for r in members),
            len(members),
        ])
    table.sort(key=lambda r: (-r[5], -r[8], r[0]))
    return table


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", default="output/figure5", help="Output directory")
    parser.add_argument("--as-of", help="Limit to batches released by this date, YYYY-MM-DD")
    parser.add_argument("--input", help="Redraw from a saved flags.csv instead of querying")
    args = parser.parse_args()

    if args.input:
        with open(args.input, newline="") as handle:
            raw = handle.read()
    else:
        raw = run_query(args.as_of)
    rows = list(csv.DictReader(io.StringIO(raw)))
    if not rows:
        sys.exit("No flags returned")
    as_of = rows[0]["as_of_batch_release_date"]

    os.makedirs(args.out, exist_ok=True)
    if not args.input:
        with open(os.path.join(args.out, "flags.csv"), "w", newline="") as handle:
            handle.write(raw)

    write_csv(
        os.path.join(args.out, "figure5_domain_level.csv"),
        ["clinical_domain", "figure_level", "flagged_scvs", "flagged_variants", "flagged_genes",
         "standing_not_flagged_scvs", "retracted_scvs", "submitted_scvs"],
        domain_level_rows(rows),
    )
    write_csv(
        os.path.join(args.out, "figure5_genes.csv"),
        ["gene_symbol", "clingen_low_levels", "gene_has_moderate_or_higher", "clinical_domains",
         "figure_levels", "flagged_scvs", "standing_not_flagged_scvs", "retracted_scvs", "submitted_scvs"],
        gene_rows(rows),
    )

    svg_path = os.path.join(args.out, "figure5.svg")
    with open(svg_path, "w") as handle:
        handle.write(figure_svg(rows, as_of))
    png = write_png(svg_path)

    shown = [r for r in rows if is_true(r["shown_in_figure"])]
    print(f"Batches through {as_of}: {fmt(len(rows))} submitted flags, {fmt(len(shown))} in the figure")
    print(f"Wrote {args.out} ({'SVG and PNG' if png else 'SVG only; Chrome not found or failed'})")


if __name__ == "__main__":
    main()
