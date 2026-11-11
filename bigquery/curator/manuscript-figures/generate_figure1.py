#!/usr/bin/env python3
"""Generate manuscript Figure 1 from 01-clinvar-landscape.sql.

Panel A (figure1A) is the share of variants by the state of their top ranked group,
with the medically significant conflicts broken out by type as bars. Panel B
(figure1B) is the % of variants in medically significant conflict per gene against
the gene's pathogenicity SCVs.

Uses only the Python standard library and the bq CLI, and needs the table functions
that 01-clinvar-landscape.sql creates. Writes SVG, plus PNG when Chrome is
available, and the CSV tables behind each panel.

    python3 generate_figure1.py --out output/figure1
    python3 generate_figure1.py --as-of 2026-10-31 --out output/figure1-oct31
    python3 generate_figure1.py --input output/figure1 --out output/figure1
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

from figure_style import COLORS, LAYOUT, TYPE, label_ink, legend, line, notes, rect, text, wrap_svg, write_csv, write_png

# The release the manuscript quotes. The pinned views in 01-clinvar-landscape.sql
# use the same date, so change both together.
FIGURE_RELEASE = "2026-11-08"

QUERIES = {
    "figure1a_final_classifications.csv": """
SELECT * FROM `clinvar_ingest.manuscript_figure1a_final_classifications`(@as_of)
ORDER BY variant_state, variants DESC, classification_to_start, top_rank
""",
    "figure1b_gene_rates.csv": """
SELECT * FROM `clinvar_ingest.manuscript_figure1b_gene_rates`(@as_of)
ORDER BY gene_symbol
""",
    "figure1_callouts.csv": """
SELECT * FROM `clinvar_ingest.manuscript_figure1_callouts`(@as_of)
ORDER BY sort_order
""",
}

# Colors by meaning, as STYLE.md gives Figure 1: blue is no disagreement, orange is
# VUS vs B/LB, and red is the medically significant conflicts.
STATES = [
    (">=2 concordant submissions", "≥2 concordant submissions", COLORS["ok_light"]),
    ("Confidence conflict", "Confidence conflict (P + LP, or B + LB)", COLORS["ok_pale"]),
    ("VUS vs B/LB", "VUS vs B/LB", COLORS["uncertain"]),
    ("P/LP vs VUS/B/LB", "P/LP vs VUS/B/LB", COLORS["medsig"]),
    ("1 submission", "1 submission", COLORS["ok"]),
]
MEDSIG = "P/LP vs VUS/B/LB"

# Same names and order as the sources of the Figure 4B Sankey.
CONFLICT_TYPES = [
    "P + LP vs VUS",
    "P vs VUS",
    "LP vs VUS",
    "P + LP vs B/LB",
    "P vs B/LB",
    "LP vs B/LB",
    "P/LP vs VUS vs B/LB",
]
# The more red, the worse the conflict: P/LP against VUS, then against B/LB, then
# against both. Steps of one family mark ordered levels of its meaning (STYLE.md).
CONFLICT_TYPE_FILLS = {
    t: COLORS["medsig_dark"] if t == "P/LP vs VUS vs B/LB" else COLORS["medsig"] if "B/LB" in t else COLORS["medsig_light"]
    for t in CONFLICT_TYPES
}

# Labels on Panel B: genes readers look for, then the outliers by a stated rule.
NOTABLE_GENES = ["BRCA1", "BRCA2", "TP53"]
TOP_BY_COUNT = 3
TOP_BY_RATE_HIGH_VOLUME = 3
HIGH_VOLUME_SCVS = 1000
TOP_BY_RATE_ANY_VOLUME = 2
# Label position relative to the point, (dx, dy, anchor), where the default collides.
LABEL_OFFSETS = {
    "ALPL": (7, -3, "start"),
    "KCNJ11": (-7, -3, "end"),
    "GALNS": (7, 11, "start"),
    "BRCA1": (-7, 13, "end"),
    "BRCA2": (-2, -30, "middle"),
    "TTN": (7, -4, "start"),
    "NF1": (-7, -3, "end"),
    "TP53": (-7, -3, "end"),
    "MYH7": (7, -4, "start"),
}


def run_query(sql, as_of):
    result = subprocess.run(
        [
            "bq", "--quiet", "--project_id=clingen-dev", "query", "--use_legacy_sql=false",
            "--format=csv", "--max_rows=1000000", f"--parameter=as_of:DATE:{as_of}", sql,
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


def wedge(cx, cy, r, start, end, fill, title):
    x0, y0 = cx + r * math.sin(start), cy - r * math.cos(start)
    x1, y1 = cx + r * math.sin(end), cy - r * math.cos(end)
    large = 1 if end - start > math.pi else 0
    return (
        f'<path d="M{cx:.2f},{cy:.2f} L{x0:.2f},{y0:.2f} A{r},{r} 0 {large} 1 {x1:.2f},{y1:.2f} Z" '
        f'fill="{fill}" stroke="{COLORS["surface"]}" stroke-width="{LAYOUT["bar_gap"]}"><title>{html.escape(title)}</title></path>'
    )


def bar_path(x, y, width, height, radius=4):
    """A horizontal bar anchored to its baseline, rounded at the data end."""
    r = min(radius, width, height / 2)
    return (
        f"M{x:.2f},{y:.2f} H{x + width - r:.2f} Q{x + width:.2f},{y:.2f} {x + width:.2f},{y + r:.2f} "
        f"V{y + height - r:.2f} Q{x + width:.2f},{y + height:.2f} {x + width - r:.2f},{y + height:.2f} "
        f"H{x:.2f} Z"
    )


def heading(x, y, name, detail):
    """A bar heading on one line: the name in bold, then detail in muted type, both at label size."""
    return (
        f'<text x="{x:.1f}" y="{y:.1f}" font-size="{TYPE["label"]}" font-weight="bold" fill="{COLORS["ink"]}">'
        f'{html.escape(name)}<tspan font-size="{TYPE["label"]}" font-weight="normal" fill="{COLORS["ink_muted"]}" dx="8">'
        f'{html.escape(detail)}</tspan></text>'
    )


def inset_bars(types, medsig, x, y, row_h, right):
    """One bar per conflict type, its heading just above it."""
    bar_max = right - x
    biggest = max(types.values())
    parts = []
    for name in CONFLICT_TYPES:
        n = types[name]
        bar_w = max(bar_max * n / biggest, 2)
        parts.append(heading(x, y + 14, name, f"{fmt(n)} ({pct(n, medsig)})"))
        parts.append(
            f'<path d="{bar_path(x, y + 20, bar_w, 12)}" fill="{CONFLICT_TYPE_FILLS[name]}">'
            f'<title>{html.escape(name)}: {fmt(n)} ({pct(n, medsig)})</title></path>'
        )
        y += row_h
    return parts


def panel_a(states, types, callouts, release, title):
    width = LAYOUT["width"]
    total = sum(states.values())
    medsig = states[MEDSIG]

    # The inset box sets the height; the pie is centered beside it, close enough for
    # the zoom lines to stay short.
    row_h = 34
    rows_top = 56
    inset_bottom = rows_top + row_h * len(CONFLICT_TYPES) + 4
    r = 140
    cx, cy = r + 2, inset_bottom / 2
    inset_x = cx + r + 36

    # Turn the pie so the medically significant slice points at the inset.
    before = 0.0
    for name, _, _ in STATES:
        if name == MEDSIG:
            break
        before += 2 * math.pi * states[name] / total
    medsig_sweep = 2 * math.pi * medsig / total
    medsig_mid = math.pi / 2
    angle = medsig_mid - medsig_sweep / 2 - before

    parts = []
    for name, label, color in STATES:
        n = states[name]
        sweep = 2 * math.pi * n / total
        parts.append(wedge(cx, cy, r, angle, angle + sweep, color, f"{label}: {fmt(n)} ({pct(n, total)})"))
        mid = angle + sweep / 2
        if name != MEDSIG:
            # Thin slices lie almost level here, so their labels sit near the rim
            # where the slice is tallest.
            radius = r * (0.76 if sweep < 0.4 else 0.6)
            parts.append(text(
                cx + radius * math.sin(mid), cy - radius * math.cos(mid) + 5, pct(n, total),
                TYPE["label"], "bold", label_ink(color), "middle",
            ))
        angle += sweep

    # Zoom lines from the slice to the inset.
    tip_x, tip_y = cx + r * math.sin(medsig_mid), cy - r * math.cos(medsig_mid)
    for y in (0, inset_bottom):
        parts.append(line(tip_x, tip_y, inset_x, y))
    parts.append(rect(inset_x, 0, width - inset_x, inset_bottom, "none", f' stroke="{COLORS["rule"]}" stroke-width="1" rx="4"'))

    pad = inset_x + 20
    parts.append(heading(pad, 24, MEDSIG, f"{fmt(medsig)} variants ({pct(medsig, total)})"))
    parts.append(text(pad, 43, "Exact classifications in the top ranked group. Darker red is a wider disagreement.", fill=COLORS["ink_muted"]))
    parts.extend(inset_bars(types, medsig, pad, rows_top, row_h, width - 20))

    # Legend beneath the plot, largest share first, with each state's count.
    legend_y = inset_bottom + 18
    entries = [(f"{label}, {fmt(states[name])}", color) for name, label, color in sorted(STATES, key=lambda s: -states[s[0]])]
    legend_body, legend_height = legend(0, legend_y, entries)
    parts.extend(legend_body)

    note_y = legend_y + legend_height + LAYOUT["note_gap"] + TYPE["note"]
    note_body, note_height = notes(note_y, [
        f"ClinVar release {release}. Flagged SCVs do not contribute. {fmt(callouts['excluded_all_scvs_flagged'])} variants with every SCV flagged have no aggregate and are left out.",
        f"1 submission means one SCV in the top ranked group; {fmt(callouts['one_top_scv_with_lower_ranked_scvs'])} of these variants also have lower ranked SCVs.",
        "A slash means either or both of its labels. A plus means both together.",
    ])
    parts.extend(note_body)
    height = note_y + note_height - LAYOUT["note_line"] + 6
    subtitle = f"{fmt(total)} variants with a pathogenicity classification, by the state of their top ranked group"
    return wrap_svg(int(height), title, parts, subtitle=subtitle)


def choose_labels(genes):
    """Return {gene_symbol: why it is labeled}, in the rule's order."""
    labels = {}

    def add(rows, why):
        for row in rows:
            labels.setdefault(row["gene_symbol"], why)

    by_symbol = {g["gene_symbol"]: g for g in genes}
    add([by_symbol[s] for s in NOTABLE_GENES if s in by_symbol], "notable gene")
    add(sorted(genes, key=lambda g: -g["conflicts"])[:TOP_BY_COUNT], "most conflict variants")
    high_volume = [g for g in genes if g["scvs"] >= HIGH_VOLUME_SCVS]
    add(sorted(high_volume, key=lambda g: -g["pct"])[:TOP_BY_RATE_HIGH_VOLUME], f"highest rate with at least {fmt(HIGH_VOLUME_SCVS)} SCVs")
    add(sorted(genes, key=lambda g: -g["pct"])[:TOP_BY_RATE_ANY_VOLUME], "highest rate overall")
    return labels


def panel_b(genes, labels, release, title, plot_height=430):
    width = LAYOUT["width"]
    left, top, right = 64, 10, 10
    plot_w = width - left - right
    x_max = math.log10(max(g["scvs"] for g in genes)) * 1.03
    y_top = math.ceil(max(g["pct"] for g in genes) / 2 + 0.25) * 2
    muted = COLORS["ink_muted"]
    halo = f' stroke="{COLORS["surface"]}" stroke-width="3" paint-order="stroke"'

    def px(scvs):
        return left + plot_w * math.log10(scvs) / x_max

    def py(rate):
        return top + plot_height * (1 - rate / y_top)

    zero = sum(1 for g in genes if g["conflicts"] == 0)
    parts = []
    for tick in range(0, y_top + 1, 2):
        y = py(tick)
        parts.append(line(left, y, width - right, y, COLORS["rule"] if tick == 0 else COLORS["rule_light"]))
        parts.append(text(left - 8, y + 4, f"{tick}%", TYPE["tick"], fill=muted, anchor="end"))
    bottom = top + plot_height
    power = 0
    while power <= x_max:
        x = left + plot_w * power / x_max
        parts.append(line(x, bottom, x, bottom + 5))
        parts.append(text(x, bottom + 21, fmt(10 ** power), TYPE["tick"], fill=muted, anchor="middle"))
        power += 1
    parts.append(text(left + plot_w / 2, bottom + 44, "Pathogenicity SCVs in the gene (log scale)", TYPE["tick"], fill=muted, anchor="middle"))
    parts.append(
        f'<text transform="translate(12 {top + plot_height / 2:.1f}) rotate(-90)" font-size="{TYPE["tick"]}" '
        f'fill="{muted}" text-anchor="middle">% of variants in medically significant conflict</text>'
    )

    for gene in genes:
        if gene["gene_symbol"] in labels:
            continue
        parts.append(
            f'<circle cx="{px(gene["scvs"]):.1f}" cy="{py(gene["pct"]):.1f}" r="2.6" fill="{COLORS["neutral"]}" fill-opacity="0.6">'
            f'<title>{html.escape(gene["gene_symbol"])}: {gene["pct"]:.2f}% ({fmt(gene["conflicts"])} of {fmt(gene["variants"])} variants), {fmt(gene["scvs"])} SCVs</title></circle>'
        )
    by_symbol = {g["gene_symbol"]: g for g in genes}
    for symbol in labels:
        gene = by_symbol[symbol]
        x, y = px(gene["scvs"]), py(gene["pct"])
        parts.append(
            f'<circle cx="{x:.1f}" cy="{y:.1f}" r="5" fill="{COLORS["medsig"]}" stroke="{COLORS["surface"]}" stroke-width="1.5">'
            f'<title>{html.escape(symbol)}: {gene["pct"]:.2f}% ({fmt(gene["conflicts"])} of {fmt(gene["variants"])} variants), {fmt(gene["scvs"])} SCVs</title></circle>'
        )
        dx, dy, anchor = LABEL_OFFSETS.get(symbol, (8, -5, "start"))
        if abs(dy) > 15:
            parts.append(line(x, y - 6, x + dx, y + dy + 3, muted))
        parts.append(text(x + dx, y + dy, symbol, TYPE["label"], "bold", anchor=anchor, extra=halo))

    note_y = bottom + 44 + LAYOUT["note_gap"] + TYPE["note"] + 4
    note_body, note_height = notes(note_y, [
        f"ClinVar release {release}. Single-gene variants, read from each variant's top ranked group. Flagged SCVs do not contribute.",
        f"{fmt(zero)} genes have no such conflict and sit on the 0% line. The curved lower edge is genes with exactly one conflict variant.",
    ])
    parts.extend(note_body)
    height = note_y + note_height - LAYOUT["note_line"] + 6
    subtitle = f"{fmt(len(genes))} GenCC Definitive/Strong/Moderate genes"
    return wrap_svg(int(height), title, parts, subtitle=subtitle)


def read_csv(path):
    with open(path, newline="") as handle:
        return list(csv.DictReader(handle))


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--as-of", default=FIGURE_RELEASE, help=f"ClinVar release, YYYY-MM-DD. Default: {FIGURE_RELEASE}.")
    parser.add_argument("--input", help="Folder with saved query results, instead of querying BigQuery.")
    parser.add_argument("--out", default="output/figure1", help="Output directory.")
    args = parser.parse_args()

    os.makedirs(args.out, exist_ok=True)
    for name, sql in QUERIES.items():
        path = os.path.join(args.out, name)
        if args.input:
            source = os.path.join(args.input, name)
            if os.path.abspath(source) != os.path.abspath(path):
                shutil.copyfile(source, path)
        else:
            with open(path, "w") as handle:
                handle.write(run_query(sql, args.as_of))

    final = read_csv(os.path.join(args.out, "figure1a_final_classifications.csv"))
    gene_rows = read_csv(os.path.join(args.out, "figure1b_gene_rates.csv"))
    callout_rows = read_csv(os.path.join(args.out, "figure1_callouts.csv"))
    if not final or not gene_rows or not callout_rows:
        sys.exit("A query returned no rows.")

    release = final[0]["release_date"]
    states = collections.Counter()
    types = collections.Counter()
    for row in final:
        states[row["variant_state"]] += int(row["variants"])
        if row["conflict_type"]:
            types[row["conflict_type"]] += int(row["variants"])
    if set(states) != {s[0] for s in STATES}:
        raise ValueError(f"Unplaced states: {set(states) ^ {s[0] for s in STATES}}")
    if set(types) - set(CONFLICT_TYPES):
        raise ValueError(f"Unplaced conflict types: {set(types) - set(CONFLICT_TYPES)}")
    total = sum(states.values())
    callouts = {r["callout"]: int(r["variants"]) for r in callout_rows}
    if callouts["variants_in_figure"] != total or callouts["medsig_top_group"] != states[MEDSIG] or sum(types.values()) != states[MEDSIG]:
        raise ValueError("Panel A totals do not reconcile with the call-out counts.")

    genes = [
        {
            "gene_symbol": r["gene_symbol"],
            "scvs": int(r["total_scvs"]),
            "variants": int(r["total_variants"]),
            "conflicts": int(r["total_clinsig_conflict_variants"]),
            "pct": float(r["clinsig_conflict_pct"]),
        }
        for r in gene_rows
    ]
    labels = choose_labels(genes)

    write_csv(
        os.path.join(args.out, "figure1a_states.csv"),
        ["release_date", "variant_state", "variants", "percent_of_variants"],
        [[release, s[0], states[s[0]], f"{100 * states[s[0]] / total:.2f}"] for s in sorted(STATES, key=lambda s: -states[s[0]])],
    )
    write_csv(
        os.path.join(args.out, "figure1a_conflict_types.csv"),
        ["release_date", "conflict_type", "variants", "percent_of_medically_significant"],
        [[release, t, types[t], f"{100 * types[t] / states[MEDSIG]:.2f}"] for t in CONFLICT_TYPES],
    )
    by_symbol = {g["gene_symbol"]: g for g in genes}
    write_csv(
        os.path.join(args.out, "figure1b_labeled_genes.csv"),
        ["release_date", "gene_symbol", "why_labeled", "total_scvs", "total_variants", "conflict_variants", "conflict_pct"],
        [[release, s, why, by_symbol[s]["scvs"], by_symbol[s]["variants"], by_symbol[s]["conflicts"], by_symbol[s]["pct"]] for s, why in labels.items()],
    )

    a_svg = panel_a(states, types, callouts, release, "Figure 1A. Concordance among ClinVar submissions")
    b_svg = panel_b(genes, labels, release, "Figure 1B. ClinVar conflict rate by gene")
    outputs = {"figure1A.svg": a_svg, "figure1B.svg": b_svg}
    png_written = True
    for name, svg in outputs.items():
        path = os.path.join(args.out, name)
        with open(path, "w") as handle:
            handle.write(svg)
        png_written = write_png(path) and png_written

    print(f"Release {release}: {fmt(total)} variants")
    for name, _, _ in sorted(STATES, key=lambda s: -states[s[0]]):
        print(f"  {name:30}{fmt(states[name]):>10}  {pct(states[name], total):>6}")
    print(f"Medically significant: {fmt(states[MEDSIG])}")
    for name in CONFLICT_TYPES:
        print(f"  {name:30}{fmt(types[name]):>10}  {pct(types[name], states[MEDSIG]):>6}")
    in_range = sum(1 for g in genes if 100 <= g["scvs"] <= 1000)
    print(f"Genes: {fmt(len(genes))}; {fmt(in_range)} with 100-1,000 SCVs; rate 0-{max(g['pct'] for g in genes):.2f}%")
    print("Labeled: " + ", ".join(labels))
    for row in callout_rows:
        print(f"  {row['callout']:40}{fmt(int(row['variants'])):>10}")
    print(f"Wrote {args.out}" + ("" if png_written else " (some PNGs missing: Chrome was not found or did not finish, set CHROME or rerun)"))


if __name__ == "__main__":
    main()
