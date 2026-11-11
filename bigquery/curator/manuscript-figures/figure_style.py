#!/usr/bin/env python3
"""Shared style for every CvC manuscript figure: palette, type, spacing and SVG helpers.

This is the one place figure colors, fonts and sizes are defined. Each
generate_figureN.py imports from it instead of defining its own:

    from figure_style import COLORS, TYPE, LAYOUT, text, rect, line, wrap_svg, write_png, write_csv

STYLE.md explains the rules and shows which color each figure uses for what. Change a
color here, not in a generator, then rerun every generator and re-paste the images.

Run this file directly to draw the palette reference into output/style/:

    python3 figure_style.py
"""

import csv
import html
import os
import shutil
import subprocess
import tempfile
import textwrap

# ---------------------------------------------------------------------------
# Palette
#
# Semantic colors carry one meaning in every figure and are never reused for
# anything else. The clinical scale follows slide 4 of the CvC presentation deck
# ("Concordance in ClinVar"): blue is clinically okay, orange is uncertain, red is
# medically significant. CvC's own work is teal-green, the nearest color to the
# deck's teal accent that stays distinct from the clinical blue for color-blind
# readers. Gray is neutral: no change, other, or a comparison group.
#
# The base colors of all six families pass the dataviz validator as one set
# (all pairs, white surface): worst color-blind separation 8.0 (CvC vs uncertain,
# protan), worst normal-vision separation 16.1. Each family's steps pass its
# ordinal check. STYLE.md has the commands to recheck after any change.
#
# Category colors (purple, pink) have no meaning across figures. Use them, in
# order, only for categories a figure's legend names, after the semantic colors
# are used up.
#
# Each family has a base and, where needed, darker and lighter steps. The steps
# are for ordered sub-levels of the same meaning, such as the kinds of CvC outcome.
# ---------------------------------------------------------------------------

COLORS = {
    # Clinically okay: no conflict, concordant, benign/likely benign.
    "ok_dark": "#1F4E79",
    "ok": "#2E75B6",
    "ok_light": "#5B9BD5",
    "ok_pale": "#9DC3E6",       # direct labels required: below 2:1 on white
    # Uncertain: VUS, conflicts that are not medically significant.
    "uncertain_dark": "#C55A11",
    "uncertain": "#ED7D31",
    "uncertain_light": "#F4B183",  # direct labels required: below 2:1 on white
    # Medically significant: P/LP, P/LP vs VUS or B/LB conflicts.
    "medsig_dark": "#8B0000",
    "medsig": "#C00000",
    "medsig_light": "#E2382A",
    # CvC's own work: flagging candidates submitted, CvC flags, CvC outcomes.
    "cvc_dark": "#024F39",
    "cvc_mid": "#0D7154",
    "cvc": "#1B9E77",
    "cvc_light": "#43B991",
    # Neutral: no change, other, not recorded, all ClinVar as a comparison group.
    "neutral_dark": "#5C5B57",
    "neutral": "#A3A29C",
    "neutral_light": "#D9D8D3",
    # Category colors with no shared meaning, used in this order.
    "cat1_dark": "#4A1A70",
    "cat1": "#7030A0",
    "cat1_mid": "#9457C2",
    "cat1_light": "#B585DD",
    "cat2_dark": "#8E4072",
    "cat2_mid": "#B5608F",
    "cat2": "#D17DB0",
    # Chart chrome.
    "ink": "#1F1F1F",
    "ink_muted": "#52514E",
    "rule": "#C9C8C3",
    "rule_light": "#E8E7E3",
    "surface": "#FFFFFF",
}

# Which semantic family each meaning uses. Generators look meanings up here so the
# same thing is the same color everywhere.
MEANING = {
    "clinically_okay": "ok",
    "benign": "ok",
    "uncertain": "uncertain",
    "vus": "uncertain",
    "medically_significant": "medsig",
    "pathogenic": "medsig",
    "cvc": "cvc",
    "no_change": "neutral",
    "other": "neutral",
    "not_recorded": "neutral",
    "all_clinvar": "neutral",
    "not_cvc": "neutral_dark",
}

# Fill text that sits on top of a colored fill.
ON_DARK = COLORS["surface"]
ON_LIGHT = COLORS["ink"]


def luminance(color):
    """WCAG relative luminance of a #RRGGBB color."""
    r, g, b = (int(color[i:i + 2], 16) / 255 for i in (1, 3, 5))
    lin = [c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4 for c in (r, g, b)]
    return 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2]


def contrast(a, b):
    """WCAG contrast ratio between two #RRGGBB colors."""
    hi, lo = sorted((luminance(a), luminance(b)), reverse=True)
    return (hi + 0.05) / (lo + 0.05)


def label_ink(fill):
    """Ink for a label drawn on a fill: white or ink, whichever contrasts more with it."""
    return ON_DARK if contrast(fill, ON_DARK) > contrast(fill, ON_LIGHT) else ON_LIGHT


# ---------------------------------------------------------------------------
# Type: one family, one set of sizes, in SVG px at the standard width.
# ---------------------------------------------------------------------------

FONT = "Arial, Helvetica, sans-serif"

TYPE = {
    "title": 20,      # bold, "Figure 3A. ..."
    "subtitle": 15,   # muted, one line under the title
    "heading": 15,    # bold, column or facet headings inside a plot
    "label": 14,      # category labels, legend entries, values on bars
    "tick": 13,       # axis ticks and axis titles
    "note": 13,       # muted footnotes under the plot
}

# ---------------------------------------------------------------------------
# Layout. Every panel is drawn at the same width so its text prints at the same
# size when panels are placed at the same width in the manuscript. Height follows
# the content: size the plot to the data, with no empty bands.
# ---------------------------------------------------------------------------

LAYOUT = {
    "width": 1000,        # content width of every panel, excluding the margin
    "margin": 16,         # white border on all four sides
    "title_gap": 10,      # title baseline to subtitle baseline is TYPE["title"] + this
    "header_gap": 18,     # last header line to the top of the plot
    "note_gap": 14,       # bottom of the plot to the first footnote
    "note_line": 18,      # footnote line spacing
    "legend_swatch": 14,  # legend square size
    "legend_gap": 22,     # space between legend entries
    "bar_gap": 2,         # white gap between stacked segments and adjacent bars
    "png_scale": 3,       # device scale factor for PNGs
}


# ---------------------------------------------------------------------------
# SVG helpers
# ---------------------------------------------------------------------------

def text(x, y, value, size=TYPE["label"], weight="normal", fill=COLORS["ink"], anchor="start", extra=""):
    return (
        f'<text x="{x:.1f}" y="{y:.1f}" font-size="{size}" font-weight="{weight}" '
        f'fill="{fill}" text-anchor="{anchor}"{extra}>{html.escape(str(value))}</text>'
    )


def rect(x, y, width, height, fill, extra=""):
    return f'<rect x="{x:.1f}" y="{y:.1f}" width="{width:.1f}" height="{height:.1f}" fill="{fill}"{extra}/>'


def line(x1, y1, x2, y2, stroke=COLORS["rule"], width=1, dash=None):
    dash_attr = f' stroke-dasharray="{dash}"' if dash else ""
    return (
        f'<line x1="{x1:.1f}" y1="{y1:.1f}" x2="{x2:.1f}" y2="{y2:.1f}" '
        f'stroke="{stroke}" stroke-width="{width}"{dash_attr}/>'
    )


def legend(x, y, entries, max_width=LAYOUT["width"]):
    """Legend squares in one or more rows. entries are (label, fill). Returns (svg list, height)."""
    char = TYPE["label"] * 0.55
    body, cx, cy = [], x, y
    for label, fill in entries:
        entry_width = LAYOUT["legend_swatch"] + 8 + len(label) * char + LAYOUT["legend_gap"]
        if cx > x and cx + entry_width > x + max_width:
            cx, cy = x, cy + TYPE["label"] + 10
        body.append(rect(cx, cy, LAYOUT["legend_swatch"], LAYOUT["legend_swatch"], fill, ' rx="2"'))
        body.append(text(cx + LAYOUT["legend_swatch"] + 8, cy + 12, label))
        cx += entry_width
    return body, cy - y + LAYOUT["legend_swatch"]


def notes(y, lines, width=LAYOUT["width"]):
    """Muted footnotes, wrapped to the panel width. Returns (svg list, height)."""
    per_line = int(width / (TYPE["note"] * 0.5))
    wrapped = [part for value in lines for part in textwrap.wrap(value, per_line)]
    body = [
        text(0, y + i * LAYOUT["note_line"], value, TYPE["note"], fill=COLORS["ink_muted"])
        for i, value in enumerate(wrapped)
    ]
    return body, len(wrapped) * LAYOUT["note_line"]


def header_height(subtitle=None):
    """Space the title block takes above y=0, the top of the plot."""
    height = TYPE["title"] + LAYOUT["header_gap"]
    if subtitle:
        height += TYPE["subtitle"] + LAYOUT["title_gap"]
    return height


def wrap_svg(height, title, body, subtitle=None, width=LAYOUT["width"]):
    """The standard panel: margin, white surface, title and optional subtitle above y=0.

    Draw the plot from y=0 down to `height`. Pass the full title, such as
    "Figure 3A. CvC review outcomes for SCVs and variants".
    """
    m = LAYOUT["margin"]
    top = header_height(subtitle)
    total_w, total_h = width + 2 * m, height + top + 2 * m
    head = [text(0, -top + TYPE["title"] - 4, title, TYPE["title"], "bold")]
    if subtitle:
        head.append(text(0, -top + TYPE["title"] + LAYOUT["title_gap"] + TYPE["subtitle"] - 2,
                         subtitle, TYPE["subtitle"], fill=COLORS["ink_muted"]))
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{-m} {-top - m} {total_w} {total_h}" '
        f'width="{total_w}" height="{total_h}" font-family="{FONT}">'
        f'{rect(-m, -top - m, total_w, total_h, COLORS["surface"])}'
        f'{"".join(head)}{"".join(body)}</svg>\n'
    )


# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

def find_chrome():
    candidates = [
        os.environ.get("CHROME"),
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        shutil.which("google-chrome"),
        shutil.which("chromium"),
    ]
    return next((c for c in candidates if c and os.path.exists(c)), None)


def write_png(svg_path):
    """Render an SVG to a PNG beside it with headless Chrome. Returns False without Chrome."""
    chrome = find_chrome()
    if not chrome:
        return False
    with open(svg_path, encoding="utf-8") as handle:
        svg = handle.read()
    head = svg[:svg.index(">")]
    width = head.split(' width="')[1].split('"')[0]
    height = head.split(' height="')[1].split('"')[0]
    png_path = os.path.abspath(svg_path[:-4] + ".png")
    # A failed render must not leave an older PNG beside the new SVG.
    if os.path.exists(png_path):
        os.remove(png_path)
    # Headless Chrome occasionally hangs, so each try has a time limit.
    for _ in range(2):
        with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as tmp:
            page = os.path.join(tmp, "page.html")
            with open(page, "w", encoding="utf-8") as handle:
                handle.write(f'<!doctype html><html><head><meta charset="utf-8"></head><body style="margin:0">{svg}</body></html>')
            try:
                subprocess.run(
                    [
                        chrome, "--headless=new", "--disable-gpu", "--hide-scrollbars",
                        f"--user-data-dir={os.path.join(tmp, 'profile')}",
                        f"--force-device-scale-factor={LAYOUT['png_scale']}", f"--window-size={width},{height}",
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
    with open(path, "w", newline="", encoding="utf-8") as handle:
        writer = csv.writer(handle)
        writer.writerow(header)
        writer.writerows(rows)


# ---------------------------------------------------------------------------
# Palette reference: python3 figure_style.py
# ---------------------------------------------------------------------------

FAMILIES = [
    ("Clinically okay", "No conflict, concordant, B/LB", ["ok_dark", "ok", "ok_light", "ok_pale"]),
    ("Uncertain", "VUS, conflicts that are not medically significant", ["uncertain_dark", "uncertain", "uncertain_light"]),
    ("Medically significant", "P/LP, P/LP vs VUS or B/LB conflicts", ["medsig_dark", "medsig", "medsig_light"]),
    ("CvC", "CvC submissions, flags and outcomes", ["cvc_dark", "cvc_mid", "cvc", "cvc_light"]),
    ("Neutral", "No change, other, all ClinVar as a comparison", ["neutral_dark", "neutral", "neutral_light"]),
    ("Category 1", "Legend-named categories, no shared meaning", ["cat1_dark", "cat1", "cat1_mid", "cat1_light"]),
    ("Category 2", "Used after category 1", ["cat2_dark", "cat2_mid", "cat2"]),
]


def palette_reference():
    body = []
    y = 0
    swatch_w, swatch_h = 120, 46
    for name, meaning, keys in FAMILIES:
        body.append(text(0, y + 18, name, TYPE["label"], "bold"))
        body.append(text(0, y + 38, meaning, TYPE["tick"], fill=COLORS["ink_muted"]))
        for i, key in enumerate(keys):
            x = 340 + i * (swatch_w + 8)
            fill = COLORS[key]
            body.append(rect(x, y, swatch_w, swatch_h, fill, ' rx="3"'))
            body.append(text(x + 8, y + 19, key, TYPE["tick"], "bold", label_ink(fill)))
            body.append(text(x + 8, y + 37, fill, TYPE["tick"], fill=label_ink(fill)))
        y += swatch_h + 16
    y += 6
    sizes = ", ".join(f"{k} {v}" for k, v in TYPE.items())
    note_body, note_h = notes(y, [
        f"Type: {FONT}. Sizes in px at the {LAYOUT['width']} px panel width: {sizes}.",
        "Semantic colors keep one meaning in every figure. Category colors are named by each figure's legend only.",
    ])
    body += note_body
    return wrap_svg(y + note_h, "CvC manuscript figure palette", body,
                    subtitle="Clinical scale from slide 4 of the CvC deck: blue okay, orange uncertain, red medically significant")


def main():
    out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "output", "style")
    os.makedirs(out, exist_ok=True)
    path = os.path.join(out, "palette.svg")
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(palette_reference())
    print(path, "and PNG" if write_png(path) else "(no Chrome, SVG only)")


if __name__ == "__main__":
    main()
