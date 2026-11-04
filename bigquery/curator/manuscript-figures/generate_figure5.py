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
import shutil
import subprocess
import sys
import tempfile

FLAGS_QUERY = """
SELECT *
FROM `clinvar_ingest.manuscript_figure5_flags`(@as_of)
ORDER BY scv_id
"""

FONT = "Arial, Helvetica, sans-serif"
INK = "#1f1f1f"
INK_MUTED = "#52514e"
SURFACE = "#ffffff"
RULE = "#c9c8c3"

# Not recorded is gray because it is missing information rather than a level.
LEVELS = [
    ("Limited", "#2A6FD0"),
    ("Disputed", "#E8921C"),
    ("Refuted", "#8E1F3E"),
    ("No Known", "#3E8E7E"),
    ("Not recorded", "#8A8983"),
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


def text(x, y, value, size=13, weight="normal", fill=INK, anchor="start"):
    return (
        f'<text x="{x:.1f}" y="{y:.1f}" font-size="{size}" font-weight="{weight}" '
        f'fill="{fill}" text-anchor="{anchor}">{html.escape(value)}</text>'
    )


def wrap_svg(width, height, body):
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width} {height}" '
        f'width="{width}" height="{height}" font-family="{FONT}">'
        f'<rect width="{width}" height="{height}" fill="{SURFACE}"/>{body}</svg>\n'
    )


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

    width, left, right = 980, 268, 60
    plot_width = width - left - right
    top, row_height, bar_height = 136, 30, 18
    plot_height = row_height * len(domains)
    height = top + plot_height + 62
    scale = plot_width / max_count

    body = [
        text(24, 34, "Figure 5. CvC flags on P/LP submissions in genes with insufficient", 20, "bold"),
        text(24, 60, "gene-disease evidence, by clinical domain", 20, "bold"),
        text(
            24, 86,
            f"{fmt(total)} SCVs flagged in ClinVar on the {as_of} release, stacked by the "
            "validity level that prompted the flag",
            14, fill=INK_MUTED,
        ),
    ]

    x = left
    for name, color in levels:
        body.append(f'<rect x="{x}" y="103" width="12" height="12" rx="2" fill="{color}"/>')
        body.append(text(x + 18, 114, name, 13))
        x += 18 + 8 * len(name) + 26

    step = 10 if max_count > 20 else 5
    for tick in range(0, max_count + 1, step):
        tick_x = left + tick * scale
        body.append(
            f'<line x1="{tick_x:.1f}" y1="{top - 6}" x2="{tick_x:.1f}" y2="{top + plot_height}" '
            f'stroke="{RULE}" stroke-width="1"/>'
        )
        body.append(text(tick_x, top + plot_height + 20, str(tick), 12, fill=INK_MUTED, anchor="middle"))
    body.append(text(left + plot_width / 2, top + plot_height + 44, "Flagged SCVs", 13, fill=INK_MUTED, anchor="middle"))

    for i, domain in enumerate(domains):
        y = top + i * row_height
        body.append(text(left - 12, y + 18, domain, 13, anchor="end"))
        x = left
        domain_total = sum(counts[domain].values())
        for name, color in levels:
            count = counts[domain][name]
            if not count:
                continue
            # A 2px surface gap keeps adjacent segments apart.
            segment = max(count * scale - 2, 2)
            body.append(
                f'<rect x="{x:.1f}" y="{y + 4}" width="{segment:.1f}" height="{bar_height}" fill="{color}">'
                f"<title>{html.escape(domain)}, {name}: {count} SCVs</title></rect>"
            )
            x += count * scale
        body.append(text(x + 6, y + 18, str(domain_total), 13, "bold" if domain_total else "normal"))

    return wrap_svg(width, height, "".join(body))


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
