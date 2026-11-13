#!/usr/bin/env python3
"""Generate manuscript Figure 3 from 03-flagged-scv-by-consequence.sql.

Draws two versions of the same comparison between CvC-flagged variants and all
ClinVar variants. The bar version pairs the percentages with a forest plot of odds
ratios. The stacked version shows each group's whole consequence mix, with the
change in percentage points from the ClinVar baseline.

Uses only the Python standard library and the bq CLI, and reads the view that
03-flagged-scv-by-consequence.sql creates. Writes SVG, plus PNG when Chrome is
available, and the CSV tables behind the figures.

    python3 generate_figure3.py --out output/figure3
    python3 generate_figure3.py --input consequence_counts.csv --out output/figure3
"""

import argparse
import csv
import html
import math
import os
import shutil
import subprocess
import sys

from figure_style import COLORS, LAYOUT, TYPE, label_ink, legend, line, notes, rect, text, wrap_svg, write_csv, write_png

COUNTS_QUERY = """
SELECT *
FROM `clinvar_ingest.manuscript_cvc_vs_clinvar_consequence_bar_view`
"""

# Colors by meaning, from STYLE.md: all ClinVar is the neutral comparison, CvC is teal-green.
ALL_FILL = COLORS["neutral"]
FLAGGED_FILL = COLORS["cvc"]

# Most to least severe, the same order the SQL uses to place a variant. Each entry
# is the view's group name, its label and its fill. The consequence groups have no
# clinical meaning, so they take the category 1 steps; Other is neutral.
GROUPS = [
    ("predicted LOF", "Predicted LoF", COLORS["cat1_dark"]),
    ("missense", "Missense", COLORS["cat1"]),
    ("inframe indels", "In-frame indels", COLORS["cat1_mid"]),
    ("UTR/intronic", "UTR/intronic", COLORS["cat1_light"]),
    ("other", "Other", COLORS["neutral"]),
]
Z_95 = 1.959964


def run_query():
    result = subprocess.run(
        [
            "bq", "--quiet", "--project_id=clingen-dev", "query", "--use_legacy_sql=false",
            "--format=csv", COUNTS_QUERY,
        ],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        sys.exit(f"bq query failed:\n{result.stdout}\n{result.stderr}")
    return result.stdout


def log_sum_at_or_below(log_probs, observed):
    """Sum the probabilities no more likely than the observed one, in log space."""
    keep = [p for p in log_probs if p <= observed + 1e-7]
    top = max(keep)
    return top + math.log(sum(math.exp(p - top) for p in keep))


def log_choose(n, k):
    return math.lgamma(n + 1) - math.lgamma(k + 1) - math.lgamma(n - k + 1)


def fisher_exact(in_group_flagged, flagged, in_group_all, everyone):
    """Two-sided Fisher's exact test, flagged against not flagged."""
    def log_prob(k):
        return (
            log_choose(in_group_all, k)
            + log_choose(everyone - in_group_all, flagged - k)
            - log_choose(everyone, flagged)
        )
    low = max(0, flagged + in_group_all - everyone)
    high = min(flagged, in_group_all)
    probs = [log_prob(k) for k in range(low, high + 1)]
    return min(1.0, math.exp(log_sum_at_or_below(probs, log_prob(in_group_flagged))))


def binomial_exact(in_group_flagged, flagged, baseline):
    """Two-sided exact binomial test against the ClinVar baseline proportion."""
    def log_prob(k):
        return log_choose(flagged, k) + k * math.log(baseline) + (flagged - k) * math.log(1 - baseline)
    probs = [log_prob(k) for k in range(flagged + 1)]
    return min(1.0, math.exp(log_sum_at_or_below(probs, log_prob(in_group_flagged))))


def holm(p_values):
    order = sorted(range(len(p_values)), key=lambda i: p_values[i])
    adjusted = [0.0] * len(p_values)
    running = 0.0
    for rank, i in enumerate(order):
        running = max(running, min(1.0, p_values[i] * (len(p_values) - rank)))
        adjusted[i] = running
    return adjusted


def chi_square_sf(x, df):
    """Upper tail of the chi-square distribution, in closed form so it keeps tiny values."""
    half = x / 2
    if df % 2 == 0:
        term = total = 1.0
        for k in range(1, df // 2):
            term *= half / k
            total += term
        return math.exp(-half) * total
    term = 2 * math.sqrt(half / math.pi) * math.exp(-half)
    total = math.erfc(math.sqrt(half)) + term
    for k in range(1, (df - 1) // 2):
        term *= half / (k + 0.5)
        total += term
    return total


def wilson_interval(k, n):
    p = k / n
    denominator = 1 + Z_95 ** 2 / n
    center = p + Z_95 ** 2 / (2 * n)
    margin = Z_95 * math.sqrt(p * (1 - p) / n + Z_95 ** 2 / (4 * n ** 2))
    return (center - margin) / denominator, (center + margin) / denominator


def group_statistics(counts):
    """Return one dict per group, for the groups in counts, with its tests adjusted across them."""
    flagged_total = sum(c["flagged"] for c in counts)
    all_total = sum(c["all"] for c in counts)
    rest_total = all_total - flagged_total
    stats = []
    for c in counts:
        a, b = c["flagged"], flagged_total - c["flagged"]
        rest = c["all"] - c["flagged"]
        odds_ratio = (a * (rest_total - rest)) / (b * rest)
        se = math.sqrt(1 / a + 1 / b + 1 / rest + 1 / (rest_total - rest))
        baseline = c["all"] / all_total
        low, high = wilson_interval(a, flagged_total)
        stats.append({
            **c,
            "not_flagged": rest,
            "flagged_pct": 100 * a / flagged_total,
            "all_pct": 100 * baseline,
            "not_flagged_pct": 100 * rest / rest_total,
            "odds_ratio": odds_ratio,
            "or_low": math.exp(math.log(odds_ratio) - Z_95 * se),
            "or_high": math.exp(math.log(odds_ratio) + Z_95 * se),
            "fisher_p": fisher_exact(a, flagged_total, c["all"], all_total),
            "change": 100 * (a / flagged_total - baseline),
            "change_low": 100 * (low - baseline),
            "change_high": 100 * (high - baseline),
            "ratio": (a / flagged_total) / baseline,
            "binomial_p": binomial_exact(a, flagged_total, baseline),
        })
    for row, adjusted in zip(stats, holm([s["fisher_p"] for s in stats])):
        row["fisher_holm"] = adjusted
    for row, adjusted in zip(stats, holm([s["binomial_p"] for s in stats])):
        row["binomial_holm"] = adjusted
    return stats


def overall_tests(stats):
    """Return the chi-square test of independence and the goodness-of-fit test."""
    flagged_total = sum(s["flagged"] for s in stats)
    all_total = sum(s["all"] for s in stats)
    rest_total = all_total - flagged_total
    fit = sum((s["flagged"] - s["all"] * flagged_total / all_total) ** 2 / (s["all"] * flagged_total / all_total) for s in stats)
    independence = fit + sum(
        (s["not_flagged"] - s["all"] * rest_total / all_total) ** 2 / (s["all"] * rest_total / all_total) for s in stats
    )
    df = len(stats) - 1
    return {
        "independence": (independence, df, chi_square_sf(independence, df)),
        "goodness_of_fit": (fit, df, chi_square_sf(fit, df)),
    }


def fmt(n):
    return f"{n:,}"


def signed(value, places=1):
    return f"{value:+.{places}f}".replace("-", "−")


def p_label(p):
    return "p < 0.001" if p < 0.001 else f"p = {p:.3f}"


def test_label(test):
    x, df, p = test
    return f"χ² = {x:.1f}, df = {df}, {p_label(p)}"


def bars_figure(stats, tests, release):
    """Not drawn: the user chose the stacked version as Figure 3C on 2026-11-09. Kept for reference."""
    """Paired bars of the percentages beside a forest plot of the odds ratios."""
    width = 1180
    flagged_total = sum(s["flagged"] for s in stats)
    all_total = sum(s["all"] for s in stats)
    row_height = 84
    top = 70
    plot_bottom = top + row_height * len(stats)
    bars_left, bars_right = 150, 590
    axis_max = max(20, math.ceil(max(max(s["all_pct"], s["flagged_pct"]) for s in stats) / 20) * 20)
    forest_left, forest_right = 680, 930
    low_exp = math.floor(math.log2(min(s["or_low"] for s in stats)))
    high_exp = math.ceil(math.log2(max(s["or_high"] for s in stats)))

    def bar_x(value):
        return bars_left + (bars_right - bars_left) * value / axis_max

    def forest_x(value):
        return forest_left + (forest_right - forest_left) * (math.log2(value) - low_exp) / (high_exp - low_exp)

    body = [
        rect(0, 3, 14, 14, ALL_FILL),
        text(21, 15, f"All ClinVar variants (n={fmt(all_total)})", 14),
        rect(290, 3, 14, 14, FLAGGED_FILL),
        text(311, 15, f"CvC-flagged variants (n={fmt(flagged_total)})", 14),
        text(bars_left, top - 16, "% of variants in group", 14, "bold"),
        text(forest_left, top - 16, "Odds ratio, flagged vs. not flagged", 14, "bold"),
        text(forest_right + 22, top - 16, "OR (95% CI)", 14, "bold"),
    ]
    for tick in range(0, axis_max + 1, 20):
        x = bar_x(tick)
        body.append(line(x, top, x, plot_bottom, COLORS["rule_light"] if tick else COLORS["rule"]))
        body.append(text(x, plot_bottom + 19, f"{tick}%", 13, fill=COLORS["ink_muted"], anchor="middle"))
    for exp in range(low_exp, high_exp + 1):
        x = forest_x(2.0 ** exp)
        body.append(line(x, top, x, plot_bottom, COLORS["rule_light"]))
        body.append(text(x, plot_bottom + 19, f"{2.0 ** exp:g}", 13, fill=COLORS["ink_muted"], anchor="middle"))
    no_difference = forest_x(1)
    body.append(line(no_difference, top, no_difference, plot_bottom, COLORS["ink_muted"], 1, "4 3"))
    body.append(text(no_difference - 8, plot_bottom + 39, "← Less common in flagged", 13, fill=COLORS["ink_muted"], anchor="end"))
    body.append(text(no_difference + 8, plot_bottom + 39, "More common in flagged →", 13, fill=COLORS["ink_muted"]))

    for i, s in enumerate(stats):
        y = top + row_height * i
        center = y + row_height / 2
        if i:
            body.append(line(0, y, width, y, COLORS["rule_light"]))
        body.append(text(0, center + 5, s["label"], 15, "bold"))
        for offset, value, fill in ((center - 29, s["all_pct"], ALL_FILL), (center + 3, s["flagged_pct"], FLAGGED_FILL)):
            body.append(rect(bars_left, offset, bar_x(value) - bars_left, 26, fill))
            body.append(text(bar_x(value) + 6, offset + 18, f"{value:.1f}%", 14))
        body.append(line(forest_x(s["or_low"]), center, forest_x(s["or_high"]), center, COLORS["ink"], 2))
        marker = forest_x(s["odds_ratio"])
        for edge in (s["or_low"], s["or_high"]):
            body.append(line(forest_x(edge), center - 6, forest_x(edge), center + 6, COLORS["ink"], 2))
        body.append(rect(marker - 4, center - 4, 8, 8, COLORS["ink"]))
        body.append(text(forest_right + 22, center - 2, f"{s['odds_ratio']:.2f} ({s['or_low']:.2f}–{s['or_high']:.2f})", 14, "bold"))
        body.append(text(forest_right + 22, center + 17, p_label(s["fisher_holm"]), 13, fill=COLORS["ink_muted"]))

    body += notes(plot_bottom + 70, [
        f"ClinVar release {release}. Overall difference, flagged vs. not flagged: {test_label(tests['independence'])} (test of independence).",
        "Per-group p values: two-sided Fisher's exact test, Holm-adjusted across the groups. Odds ratio CIs are Wald intervals.",
    ], width)[0]
    return wrap_svg(plot_bottom + 100, "Figure 3C. Molecular consequence of CvC-flagged variants compared with all ClinVar variants", body, width=width)


def heading(x, y, name, detail):
    """A heading on one line: the name in bold, then detail (such as n=) in muted label type."""
    return (
        f'<text x="{x:.1f}" y="{y:.1f}" font-size="{TYPE["heading"]}" font-weight="bold" fill="{COLORS["ink"]}">'
        f'{html.escape(name)}<tspan font-size="{TYPE["label"]}" font-weight="normal" fill="{COLORS["ink_muted"]}" dx="8">'
        f'{html.escape(detail)}</tspan></text>'
    )


def stacked_figure(stats, tests, release):
    """Two 100% stacked bars joined by bands, with each group's change from the baseline as columns to their right."""
    width = LAYOUT["width"]
    flagged_total = sum(s["flagged"] for s in stats)
    all_total = sum(s["all"] for s in stats)
    bar_left, bar_right = 0, 600
    bar_height = 62
    upper_y, lower_y = 26, 178
    heading_gap = 9      # baseline of each heading, above its bar
    band_gap = 30        # space above the lower bar kept clear of the bands for its heading
    min_inside = 38

    def bar_x(percent):
        return bar_left + (bar_right - bar_left) * percent / 100

    def segments(key):
        position = 0.0
        for s in stats:
            yield s, position, position + s[key]
            position += s[key]

    body = []
    lower_edges = {s["group"]: (a, b) for s, a, b in segments("flagged_pct")}
    for s, a, b in segments("all_pct"):
        c, d = lower_edges[s["group"]]
        points = (
            f"{bar_x(a):.1f},{upper_y + bar_height} {bar_x(b):.1f},{upper_y + bar_height} "
            f"{bar_x(d):.1f},{lower_y - band_gap} {bar_x(c):.1f},{lower_y - band_gap}"
        )
        body.append(f'<polygon points="{points}" fill="{s["fill"]}" fill-opacity="0.22"/>')
    for y, key, name, total, outside_above in (
        (upper_y, "all_pct", "All ClinVar variants", all_total, True),
        (lower_y, "flagged_pct", "CvC-flagged variants", flagged_total, False),
    ):
        body.append(heading(bar_left, y - heading_gap, name, f"n={fmt(total)}"))
        for s, a, b in segments(key):
            body.append(rect(bar_x(a), y, bar_x(b) - bar_x(a), bar_height, s["fill"]))
            body.append(line(bar_x(b), y, bar_x(b), y + bar_height, COLORS["surface"], LAYOUT["bar_gap"]))
            label = f"{s[key]:.1f}%"
            middle = (bar_x(a) + bar_x(b)) / 2
            if bar_x(b) - bar_x(a) >= min_inside:
                body.append(text(middle, y + bar_height / 2 + 5, label, TYPE["label"], "bold", label_ink(s["fill"]), "middle"))
            elif outside_above:
                body.append(line(middle, y - 5, middle, y, COLORS["ink_muted"]))
                body.append(text(middle, y - 9, label, TYPE["label"], "bold", anchor="middle"))
            else:
                body.append(line(middle, y + bar_height, middle, y + bar_height + 5, COLORS["ink_muted"]))
                body.append(text(middle, y + bar_height + 20, label, TYPE["label"], "bold", anchor="middle"))
    axis_y = lower_y + bar_height + 26
    body.append(line(bar_left, axis_y, bar_right, axis_y))
    for tick in (0, 25, 50, 75, 100):
        body.append(line(bar_x(tick), axis_y, bar_x(tick), axis_y + 5))
        body.append(text(bar_x(tick), axis_y + 21, f"{tick}%", TYPE["tick"], fill=COLORS["ink_muted"], anchor="middle"))

    # Change from the All ClinVar baseline, one column per group in legend order,
    # beside the bars. Columns rise for a larger flagged share and fall for a smaller one.
    label_left = bar_right + 36
    change_left, change_right = label_left + 34, width - 8
    rows_top, rows_bottom = upper_y, lower_y + bar_height
    largest = max(abs(v) for s in stats for v in (s["change_low"], s["change_high"]))
    limit = math.ceil(largest * 1.25 / 5) * 5  # room for the value label past each CI

    def change_y(value):
        return rows_bottom - (rows_bottom - rows_top) * (value + limit) / (2 * limit)

    body.append(heading(label_left, upper_y - heading_gap, "Change from baseline", "points, 95% CI"))
    zero = change_y(0)
    step = 10 if limit > 15 else 5
    for tick in range(-(limit // step) * step, limit + 1, step):
        y = change_y(tick)
        body.append(line(change_left, y, change_right, y, COLORS["rule_light"]))
        body.append(text(change_left - 6, y + 4, signed(tick, 0) if tick else "0", TYPE["tick"], fill=COLORS["ink_muted"], anchor="end"))
    body.append(line(change_left, zero, change_right, zero, COLORS["ink_muted"]))
    column_width = (change_right - change_left) / len(stats)
    for i, s in enumerate(stats):
        center = change_left + column_width * (i + 0.5)
        y = change_y(s["change"])
        body.append(rect(center - 12, min(y, zero), 24, abs(y - zero), s["fill"]))
        low, high = change_y(s["change_low"]), change_y(s["change_high"])
        body.append(line(center, low, center, high, COLORS["ink"], 2))
        if s["change"] >= 0:
            body.append(text(center, high - 6, signed(s["change"]), TYPE["tick"], "bold", anchor="middle"))
        else:
            body.append(text(center, low + 16, signed(s["change"]), TYPE["tick"], "bold", anchor="middle"))

    # Horizontal legend for the consequence groups, centered beneath the whole image.
    entries = [(s["label"], s["fill"]) for s in stats]
    legend_width = sum(LAYOUT["legend_swatch"] + 8 + len(label) * TYPE["label"] * 0.55 + LAYOUT["legend_gap"]
                       for label, _ in entries) - LAYOUT["legend_gap"]
    legend_y = axis_y + 44
    legend_body, legend_height = legend(max(0, (width - legend_width) / 2), legend_y, entries)
    body += legend_body

    if all(s["binomial_holm"] < 0.001 for s in stats):
        per_group = "every group p < 0.001"
    else:
        per_group = "; ".join(f"{s['label']} {p_label(s['binomial_holm'])}" for s in stats)
    note_top = legend_y + legend_height + LAYOUT["note_gap"] + TYPE["note"]
    note_body, note_height = notes(note_top, [
        f"ClinVar release {release}. Change is the flagged percentage minus the All ClinVar percentage, in points, with Wilson 95% CIs.",
        f"Two-sided exact binomial tests against the All ClinVar percentage, Holm-adjusted: {per_group}.",
        f"Overall difference from the baseline: {test_label(tests['goodness_of_fit'])} (goodness of fit).",
    ])
    body += note_body
    return wrap_svg(note_top + note_height - TYPE["note"],
                    "Figure 3C. Molecular consequence mix of CvC-flagged variants compared with all ClinVar variants", body)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--input", help="Use a saved consequence_counts.csv instead of querying BigQuery.")
    parser.add_argument("--out", default="figure3-output", help="Output directory.")
    args = parser.parse_args()

    os.makedirs(args.out, exist_ok=True)
    counts_csv = os.path.join(args.out, "consequence_counts.csv")
    if args.input:
        if os.path.abspath(args.input) != os.path.abspath(counts_csv):
            shutil.copyfile(args.input, counts_csv)
    else:
        with open(counts_csv, "w", encoding="utf-8") as handle:
            handle.write(run_query())
    with open(counts_csv, newline="", encoding="utf-8") as handle:
        rows = {r["consequence_group"]: r for r in csv.DictReader(handle)}
    expected = {g[0] for g in GROUPS}
    if set(rows) != expected:
        sys.exit(f"Expected consequence groups {sorted(expected)}, got {sorted(rows)}")
    releases = {r["release_date"] for r in rows.values()}
    if len(releases) != 1:
        sys.exit(f"Expected one release, got {sorted(releases)}")
    release = releases.pop()

    counts = [
        {
            "group": name, "label": label, "fill": fill,
            "flagged": int(rows[name]["cvc_flagged_variant_count"]),
            "all": int(rows[name]["all_variant_count"]),
        }
        for name, label, fill in GROUPS
    ]
    if any(c["flagged"] == 0 for c in counts):
        sys.exit("A group has no flagged variants, so its odds ratio is undefined.")

    stats = group_statistics(counts)
    tests = overall_tests(stats)
    without_other = group_statistics([c for c in counts if c["group"] != "other"])
    tests_without_other = overall_tests(without_other)

    fields = [
        "flagged", "all", "not_flagged", "flagged_pct", "all_pct", "not_flagged_pct", "odds_ratio", "or_low", "or_high",
        "fisher_p", "fisher_holm", "change", "change_low", "change_high", "ratio", "binomial_p", "binomial_holm",
    ]
    write_csv(
        os.path.join(args.out, "figure3_statistics.csv"),
        ["release_date", "groups_compared", "consequence_group"] + fields,
        [[release, compared, s["group"]] + [s[f] for f in fields]
         for compared, group_stats in (("all", stats), ("without other", without_other)) for s in group_stats],
    )
    write_csv(
        os.path.join(args.out, "figure3_overall_tests.csv"),
        ["release_date", "groups_compared", "test", "chi_square", "df", "p"],
        [[release, compared, name, *test]
         for compared, group_tests in (("all", tests), ("without other", tests_without_other))
         for name, test in group_tests.items()],
    )

    outputs = {
        "figure3_stacked.svg": stacked_figure(stats, tests, release),
    }
    png_written = True
    for name, svg in outputs.items():
        path = os.path.join(args.out, name)
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(svg)
        png_written = write_png(path) and png_written

    print(f"ClinVar release {release}: {fmt(sum(c['all'] for c in counts))} variants, {fmt(sum(c['flagged'] for c in counts))} CvC-flagged")
    for s in stats:
        print(
            f"  {s['label']:16}{s['flagged_pct']:6.2f}% vs {s['all_pct']:6.2f}%  OR {s['odds_ratio']:.2f} "
            f"({s['or_low']:.2f}-{s['or_high']:.2f})  {signed(s['change'], 2)} pts  {p_label(s['fisher_holm'])}"
        )
    print(f"Wrote {args.out}" + ("" if png_written else " (some PNGs missing: Chrome was not found or did not finish, set CHROME or rerun)"))


if __name__ == "__main__":
    main()
