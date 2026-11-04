#!/usr/bin/env python3
"""Generate manuscript Figure 1 from 01-clinvar-landscape.sql.

Panel A is the share of variants by the state of their top ranked group, with the
medically significant conflicts broken out by type, as bars (figure1A) or as a
second pie (figure1A_pie). Panel B is the % of variants
in medically significant conflict per gene against the gene's pathogenicity SCVs.

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
import tempfile

# The release the manuscript quotes. The pinned views in 01-clinvar-landscape.sql
# use the same date, so change both together.
FIGURE_RELEASE = "2026-10-24"

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

FONT = "Arial, Helvetica, sans-serif"
INK = "#1f1f1f"
INK_MUTED = "#52514e"
SURFACE = "#ffffff"
RULE = "#c9c8c3"
RULE_LIGHT = "#e8e7e3"

# Cool hues are variants with no disagreement. VUS vs B/LB keeps its Figure 4 color,
# and the medically significant conflicts are the one strong warm color.
STATES = [
    (">=2 concordant submissions", "≥2 concordant submissions", "#007E9E", SURFACE),
    ("Confidence conflict", "Confidence conflict (P + LP, or B + LB)", "#D08F00", INK),
    ("VUS vs B/LB", "VUS vs B/LB", "#5C9AF0", INK),
    ("P/LP vs VUS/B/LB", "P/LP vs VUS/B/LB", "#B3261E", SURFACE),
    ("1 submission", "1 submission", "#4FB9CC", INK),
]
MEDSIG = "P/LP vs VUS/B/LB"
MEDSIG_FILL = "#B3261E"
# Inset pie of figure1A_pie. Each slice is also labeled, because the smallest are
# too thin to tell apart by color alone.
CONFLICT_TYPE_FILLS = {
    "P + LP vs VUS": "#E8704F",
    "P vs VUS": "#CFA500",
    "LP vs VUS": "#A81F18",
    "P + LP vs B/LB": "#6F3FA0",
    "P vs B/LB": "#C04FB4",
    "LP vs B/LB": "#9D97E8",
    "P/LP vs VUS vs B/LB": "#1F5FC0",
}

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

# All ClinVar is this blue in Figure 3.
GENE_FILL = "#2A6FD0"
LABEL_FILL = "#0B3F91"

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


def text(x, y, value, size=13, weight="normal", fill=INK, anchor="start", halo=False):
    # A halo keeps a label readable over dense points.
    outline = f'stroke="{SURFACE}" stroke-width="3" paint-order="stroke" ' if halo else ""
    return (
        f'<text x="{x:.1f}" y="{y:.1f}" font-size="{size}" font-weight="{weight}" {outline}'
        f'fill="{fill}" text-anchor="{anchor}">{html.escape(value)}</text>'
    )


def wrap_svg(width, height, body):
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" '
        f'width="{width}" height="{height}" font-family="{FONT}">'
        f'<rect width="{width}" height="{height}" fill="{SURFACE}"/>{body}</svg>\n'
    )


def wedge(cx, cy, r, start, end, fill, title):
    x0, y0 = cx + r * math.sin(start), cy - r * math.cos(start)
    x1, y1 = cx + r * math.sin(end), cy - r * math.cos(end)
    large = 1 if end - start > math.pi else 0
    return (
        f'<path d="M{cx:.2f},{cy:.2f} L{x0:.2f},{y0:.2f} A{r},{r} 0 {large} 1 {x1:.2f},{y1:.2f} Z" '
        f'fill="{fill}" stroke="{SURFACE}" stroke-width="2"><title>{html.escape(title)}</title></path>'
    )


def bar_path(x, y, width, height, radius=4):
    """A horizontal bar anchored to its baseline, rounded at the data end."""
    r = min(radius, width, height / 2)
    return (
        f"M{x:.2f},{y:.2f} H{x + width - r:.2f} Q{x + width:.2f},{y:.2f} {x + width:.2f},{y + r:.2f} "
        f"V{y + height - r:.2f} Q{x + width:.2f},{y + height:.2f} {x + width - r:.2f},{y + height:.2f} "
        f"H{x:.2f} Z"
    )


def inset_bars(types, medsig, pad, y, row_h):
    label_right = pad + 138
    bar_x = label_right + 10
    bar_max = 190
    biggest = max(types.values())
    parts = []
    for name in CONFLICT_TYPES:
        n = types[name]
        bar_w = max(bar_max * n / biggest, 1.5)
        parts.append(text(label_right, y + row_h / 2 + 4, name, 13, anchor="end"))
        parts.append(f'<path d="{bar_path(bar_x, y + row_h / 2 - 9, bar_w, 18)}" fill="{MEDSIG_FILL}"><title>{html.escape(name)}: {fmt(n)} ({pct(n, medsig)})</title></path>')
        parts.append(text(bar_x + bar_w + 6, y + row_h / 2 + 4, f"{fmt(n)} ({pct(n, medsig)})", 12, fill=INK_MUTED))
        y += row_h
    return parts


def inset_pie(types, medsig, pad, y, row_h):
    """The smallest slices are centered on the right, beside their labels."""
    r = 104
    cx, cy = pad + r + 8, y + row_h * len(CONFLICT_TYPES) / 2
    small = [t for t in CONFLICT_TYPES if "B/LB" in t]
    large = ["P + LP vs VUS", "P vs VUS", "LP vs VUS"]
    small_sweep = sum(2 * math.pi * types[t] / medsig for t in small)
    angle = math.pi / 2 - small_sweep / 2

    parts = []
    spans = {}
    for name in small + large:
        sweep = 2 * math.pi * types[name] / medsig
        spans[name] = (angle, angle + sweep)
        parts.append(wedge(cx, cy, r, angle, angle + sweep, CONFLICT_TYPE_FILLS[name], f"{name}: {fmt(types[name])} ({pct(types[name], medsig)})"))
        angle += sweep

    for name in large:
        start, end = spans[name]
        mid = (start + end) / 2
        ink = SURFACE if name == "LP vs VUS" else INK
        parts.append(text(
            cx + r * 0.62 * math.sin(mid), cy - r * 0.62 * math.cos(mid) + 4, pct(types[name], medsig),
            12, "bold", ink, "middle",
        ))

    # Labels run down the right side in clockwise order, so leaders do not cross.
    # Large slices wrap behind the pie, so their leaders meet the rim on the right.
    anchors = {"LP vs VUS": math.radians(40), "P + LP vs VUS": math.radians(125), "P vs VUS": math.radians(170)}
    label_x = cx + r + 44
    row_y = y
    for name in ["LP vs VUS"] + small + ["P + LP vs VUS", "P vs VUS"]:
        start, end = spans[name]
        at = anchors.get(name, (start + end) / 2)
        ex, ey = cx + (r + 1) * math.sin(at), cy - (r + 1) * math.cos(at)
        ly = row_y + row_h / 2
        parts.append(
            f'<polyline points="{ex:.1f},{ey:.1f} {label_x - 24:.1f},{ly:.1f} {label_x - 6:.1f},{ly:.1f}" '
            f'fill="none" stroke="{RULE}" stroke-width="1"/>'
        )
        parts.append(f'<rect x="{label_x:.1f}" y="{ly - 6:.1f}" width="12" height="12" rx="2" fill="{CONFLICT_TYPE_FILLS[name]}"/>')
        parts.append(text(label_x + 18, ly + 4, name, 13))
        parts.append(text(label_x + 18 + 140, ly + 4, f"{fmt(types[name])} ({pct(types[name], medsig)})", 12, fill=INK_MUTED))
        row_y += row_h
    return parts


def panel_a(states, types, callouts, release, inset="bars", title="A", width=960):
    total = sum(states.values())
    medsig = states[MEDSIG]
    parts = [
        text(0, 18, title, 16, "bold"),
        text(24, 18, f"{fmt(total)} variants with a pathogenicity classification, by the state of their top ranked group", 13, fill=INK_MUTED),
    ]

    # Turn the pie so the medically significant slice points at the inset.
    cx, cy, r = 190, 208, 160
    before = 0.0
    for name, _, _, _ in STATES:
        if name == MEDSIG:
            break
        before += 2 * math.pi * states[name] / total
    medsig_sweep = 2 * math.pi * medsig / total
    medsig_mid = math.pi / 2
    angle = medsig_mid - medsig_sweep / 2 - before

    for name, label, color, on_color in STATES:
        n = states[name]
        sweep = 2 * math.pi * n / total
        parts.append(wedge(cx, cy, r, angle, angle + sweep, color, f"{label}: {fmt(n)} ({pct(n, total)})"))
        mid = angle + sweep / 2
        if name != MEDSIG:
            # Thin slices lie almost level here, so their labels sit near the rim
            # where the slice is tallest.
            radius = r * (0.74 if sweep < 0.4 else 0.6)
            parts.append(text(
                cx + radius * math.sin(mid), cy - radius * math.cos(mid) + 4, pct(n, total),
                12, "bold", on_color, "middle",
            ))
        angle += sweep

    # Zoom lines from the slice to the inset.
    inset_x, inset_top, row_h = 410, 52, 38
    inset_bottom = inset_top + 58 + row_h * len(CONFLICT_TYPES)
    tip_x, tip_y = cx + r * math.sin(medsig_mid), cy - r * math.cos(medsig_mid)
    for y in (inset_top, inset_bottom):
        parts.append(f'<line x1="{tip_x:.1f}" y1="{tip_y:.1f}" x2="{inset_x}" y2="{y}" stroke="{RULE}" stroke-width="1"/>')
    parts.append(f'<rect x="{inset_x}" y="{inset_top}" width="{width - inset_x - 1}" height="{inset_bottom - inset_top}" fill="none" stroke="{RULE}" stroke-width="1" rx="4"/>')

    pad = inset_x + 16
    parts.append(text(pad, inset_top + 24, f"{MEDSIG}: {fmt(medsig)} variants ({pct(medsig, total)})", 14, "bold"))
    parts.append(text(pad, inset_top + 43, "Exact classifications in the top ranked group", 12, fill=INK_MUTED))

    draw_inset = inset_pie if inset == "pie" else inset_bars
    parts.extend(draw_inset(types, medsig, pad, inset_top + 58, row_h))

    # Key under the pie, largest share first.
    y = cy + r + 34
    for name, label, color, _ in sorted(STATES, key=lambda s: -states[s[0]]):
        n = states[name]
        parts.append(f'<rect x="0" y="{y - 11}" width="12" height="12" rx="2" fill="{color}"/>')
        parts.append(text(18, y, label, 13))
        parts.append(text(380, y, f"{fmt(n)} ({pct(n, total)})", 13, fill=INK_MUTED, anchor="end"))
        y += 21

    notes = [
        f"ClinVar release {release}. Flagged SCVs do not contribute. {fmt(callouts['excluded_all_scvs_flagged'])} variants with every SCV flagged have no aggregate and are left out.",
        f"1 submission means one SCV in the top ranked group; {fmt(callouts['one_top_scv_with_lower_ranked_scvs'])} of these variants also have lower ranked SCVs.",
        "A slash means either or both of its labels. A plus means both together.",
    ]
    y = max(y, inset_bottom) + 16
    for note in notes:
        parts.append(text(0, y, note, 12, fill=INK_MUTED))
        y += 17
    return wrap_svg(width, int(y), "".join(parts))


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


def panel_b(genes, labels, release, title="B", width=960, plot_height=430):
    left, top, right = 58, 34, 20
    plot_w = width - left - right
    x_max = math.log10(max(g["scvs"] for g in genes)) * 1.03
    y_top = math.ceil(max(g["pct"] for g in genes) / 2 + 0.25) * 2

    def px(scvs):
        return left + plot_w * math.log10(scvs) / x_max

    def py(rate):
        return top + plot_height * (1 - rate / y_top)

    zero = sum(1 for g in genes if g["conflicts"] == 0)
    parts = [
        text(0, 18, title, 16, "bold"),
        text(24, 18, f"{fmt(len(genes))} GenCC Definitive/Strong/Moderate genes", 13, fill=INK_MUTED),
    ]
    for tick in range(0, y_top + 1, 2):
        y = py(tick)
        parts.append(f'<line x1="{left}" y1="{y:.1f}" x2="{width - right}" y2="{y:.1f}" stroke="{RULE if tick == 0 else RULE_LIGHT}" stroke-width="1"/>')
        parts.append(text(left - 8, y + 4, f"{tick}%", 12, fill=INK_MUTED, anchor="end"))
    power = 0
    while power <= x_max:
        x = left + plot_w * power / x_max
        parts.append(f'<line x1="{x:.1f}" y1="{top + plot_height}" x2="{x:.1f}" y2="{top + plot_height + 5}" stroke="{RULE}" stroke-width="1"/>')
        parts.append(text(x, top + plot_height + 20, fmt(10 ** power), 12, fill=INK_MUTED, anchor="middle"))
        power += 1
    parts.append(text(left + plot_w / 2, top + plot_height + 42, "Pathogenicity SCVs in the gene (log scale)", 13, fill=INK, anchor="middle"))
    mid_y = top + plot_height / 2
    parts.append(
        f'<text transform="translate(14 {mid_y:.1f}) rotate(-90)" font-size="13" fill="{INK}" text-anchor="middle">'
        "% of variants in medically significant conflict</text>"
    )

    for gene in genes:
        if gene["gene_symbol"] in labels:
            continue
        parts.append(
            f'<circle cx="{px(gene["scvs"]):.1f}" cy="{py(gene["pct"]):.1f}" r="2.4" fill="{GENE_FILL}" fill-opacity="0.45">'
            f'<title>{html.escape(gene["gene_symbol"])}: {gene["pct"]:.2f}% ({fmt(gene["conflicts"])} of {fmt(gene["variants"])} variants), {fmt(gene["scvs"])} SCVs</title></circle>'
        )
    by_symbol = {g["gene_symbol"]: g for g in genes}
    for symbol in labels:
        gene = by_symbol[symbol]
        x, y = px(gene["scvs"]), py(gene["pct"])
        parts.append(
            f'<circle cx="{x:.1f}" cy="{y:.1f}" r="4.5" fill="{LABEL_FILL}" stroke="{SURFACE}" stroke-width="1.5">'
            f'<title>{html.escape(symbol)}: {gene["pct"]:.2f}% ({fmt(gene["conflicts"])} of {fmt(gene["variants"])} variants), {fmt(gene["scvs"])} SCVs</title></circle>'
        )
        dx, dy, anchor = LABEL_OFFSETS.get(symbol, (7, -4, "start"))
        if abs(dy) > 15:
            parts.append(f'<line x1="{x:.1f}" y1="{y - 5:.1f}" x2="{x + dx:.1f}" y2="{y + dy + 3:.1f}" stroke="{INK_MUTED}" stroke-width="1"/>')
        parts.append(text(x + dx, y + dy, symbol, 12, "bold", INK, anchor, halo=True))

    notes = [
        f"ClinVar release {release}. Single-gene variants, read from each variant's top ranked group. Flagged SCVs do not contribute.",
        f"{fmt(zero)} genes have no such conflict and sit on the 0% line. The curved lower edge is genes with exactly one conflict variant.",
    ]
    y = top + plot_height + 66
    for note in notes:
        parts.append(text(0, y, note, 12, fill=INK_MUTED))
        y += 17
    return wrap_svg(width, int(y), "".join(parts))


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

    a_svg = panel_a(states, types, callouts, release)
    a_pie_svg = panel_a(states, types, callouts, release, inset="pie")
    b_svg = panel_b(genes, labels, release)
    outputs = {"figure1A.svg": a_svg, "figure1A_pie.svg": a_pie_svg, "figure1B.svg": b_svg}
    png_written = True
    for name, svg in outputs.items():
        path = os.path.join(args.out, name)
        with open(path, "w") as handle:
            handle.write(svg)
        png_written = write_png(path) and png_written

    print(f"Release {release}: {fmt(total)} variants")
    for name, _, _, _ in sorted(STATES, key=lambda s: -states[s[0]]):
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
