# Manuscript Figure Style

Every manuscript figure uses one palette, one typeface and one set of sizes. They are defined once, in [`figure_style.py`](figure_style.py), and every `generate_figureN.py` imports them. Don't define colors, fonts or sizes in a generator. To change one, change `figure_style.py`, recheck it (below), rerun every generator and re-paste the images.

Run `python3 figure_style.py` to draw the palette reference into `output/style/palette.png`.

## Color carries meaning

The palette follows the [CvC presentation deck](https://docs.google.com/presentation/d/1POxmsRhDwmm_t6ftY4uN9cQ7F-auxpzNud8j5KRPVDw/edit). Slide 4 ("Concordance in ClinVar") sets the clinical scale. The other slides supply the deck's teal accent and slate ink.

| Family | Meaning, in every figure | Base | Steps, dark to light |
| --- | --- | --- | --- |
| Clinically okay | No conflict, concordant submissions, B/LB | `ok` `#2E75B6` | `#1F4E79`, `#2E75B6`, `#5B9BD5`, `#9DC3E6` |
| Uncertain | VUS, conflicts that are not medically significant | `uncertain` `#ED7D31` | `#C55A11`, `#ED7D31`, `#F4B183` |
| Medically significant | P/LP, P/LP vs VUS or B/LB conflicts | `medsig` `#C00000` | `#8B0000`, `#C00000`, `#E2382A` |
| CvC | CvC's own work: candidates submitted, CvC flags, CvC outcomes | `cvc` `#1B9E77` | `#024F39`, `#0D7154`, `#1B9E77`, `#43B991` |
| Neutral | No change, other, not recorded, all ClinVar as a comparison | `neutral` `#A3A29C` | `#5C5B57`, `#A3A29C`, `#D9D8D3` |
| Category 1 | No shared meaning; categories named by the figure's legend | `cat1` `#7030A0` | `#4A1A70`, `#7030A0`, `#9457C2`, `#B585DD` |
| Category 2 | As category 1, used only after it | `cat2` `#D17DB0` | `#8E4072`, `#B5608F`, `#D17DB0` |

Rules:

- **A semantic color means one thing.** Blue, orange, red, teal-green and gray keep the meanings above in every figure. Never use them for anything else, even when a figure has no clinical content. For example, "Reclassified" in Figure 6 is not blue, because blue means clinically okay.
- **CvC is teal-green, not red.** Red means medically significant. The deck's own teal, `#438086`, reads as gray and is too close to the clinical blue for color-blind readers, so CvC uses the nearest teal-green that passes.
- **Steps within a family show ordered sub-levels of the same meaning**, such as the kinds of CvC outcome in Figure 4A. Darker means more of that meaning.
- **Category colors are for legend-named categories only**, such as consequence groups or gene-disease validity levels. They mean nothing across figures. Use category 1's steps first, then category 2. More than seven categories in one figure should fold into "Other".
- **Gray is reserved for neutral.** Use it for no change, other, not recorded, and for all ClinVar when it is the comparison for a CvC group.
- **Text is ink, never a series color.** Values and labels use `ink` `#1F1F1F` or `ink_muted` `#52514E`. Use `label_ink(fill)` for text on a fill.

## Color blindness

The palette was checked with the dataviz skill's validator, which simulates protan, deutan and tritan vision. Passing values:

- **The six base colors as one set, all pairs on white:** worst color-blind separation ΔE 8.0 (CvC vs uncertain, protan), at the 8.0 target. Worst normal-vision separation is ΔE 16.1, above the 15 floor.
- **Each family's steps:** pass the ordinal check, with lightness rising evenly and the lightest step at least 2:1 against white.
- **Lighter fills:** `uncertain` (2.77:1), `cat2` (2.89:1), `ok_light`, `neutral` and the lightest steps are below 3:1 on white. Wherever they appear, label the marks directly or put the values in the table under the figure, which every figure already has.
- **Never rely on color alone.** Use direct labels where they fit, a legend for two or more series, and a 2 px white gap between touching fills.

To recheck after a change, from the dataviz skill's `scripts` folder:

```sh
node validate_palette.js "#2E75B6,#ED7D31,#C00000,#1B9E77,#7030A0,#D17DB0" --mode light --pairs all --surface "#ffffff"
node validate_palette.js "#024F39,#0D7154,#1B9E77,#43B991" --ordinal --mode light --surface "#ffffff"
```

## Type

One family: `Arial, Helvetica, sans-serif`. Sizes are in SVG px at the standard panel width, from `TYPE`:

| Role | Size | Weight and color |
| --- | --- | --- |
| Title, such as "Figure 3A. ..." | 20 | bold, ink |
| Subtitle, one line | 15 | muted ink |
| Heading inside the plot | 15 | bold, ink |
| Labels, legend, values on bars | 14 | ink |
| Axis ticks and axis titles | 13 | muted ink |
| Footnotes | 13 | muted ink |

## Size and white space

- **Every panel is 1000 px wide** (`LAYOUT["width"]`), plus a 16 px margin. When the panels are placed at the same width in the manuscript, their text prints at the same size. PNGs render at 3x.
- **Height follows the content.** Size the plot to its data. Don't leave empty bands, oversized pies or space reserved for a legend that isn't there.
- **Use the standard spacing:** a 16 px margin, the title block from `wrap_svg`, 14 px from the plot to its footnotes, 18 px between footnote lines, and 2 px gaps between fills.
- **Footnotes wrap to the panel width** through `notes()`. They don't run past the plot.
- **Prefer direct labels to a separate legend** when there are four series or fewer and the labels fit.

## What each figure uses

| Figure | Element | Color |
| --- | --- | --- |
| 1A | 1 submission, ≥2 concordant submissions | `ok`, `ok_light` |
| 1A | Confidence conflict | `ok_pale`, as on slide 4 |
| 1A | VUS vs B/LB | `uncertain` |
| 1A | P/LP vs VUS/B/LB | `medsig` |
| 1A | Inset bars: every conflict type within P/LP vs VUS/B/LB | `medsig` |
| 1B | Gene points, and labeled genes | `neutral` points, `medsig` labeled genes (the axis is medically significant conflict) |
| 3A | Flagging candidate submitted, No change, Flagging candidate not submitted | `cvc`, `neutral`, `neutral_dark` |
| 3B | Reasons, all submitted by CvC | `cvc` |
| 3C | All ClinVar variants, CvC-flagged variants | `neutral`, `cvc` |
| 3C (stacked) | Predicted LoF, Missense, In-frame indels, UTR/intronic | `cat1_dark`, `cat1`, `cat1_mid`, `cat1_light` |
| 3C (stacked) | Other | `neutral` |
| 4A | Conflict resolved, Conflict reduced, Incorrect record flagged, Record modified | `cvc_dark`, `cvc_mid`, `cvc`, `cvc_light` |
| 4A | No change | `neutral` |
| 4B | Starting conflict nodes | `neutral_dark` |
| 4B | P/LP, VUS, VUS vs B/LB, B/LB | `medsig`, `uncertain`, `uncertain_light`, `ok` |
| 5 | Limited, Disputed, Refuted | `cat1_light`, `cat1`, `cat1_dark` |
| 5 | Not recorded | `neutral` |
| 5 | No Known (not drawn on current data) | `cat2` |
| 6 | Flagged through CvC | `cvc` |
| 6 | Flagged outside CvC, Other | `neutral_dark`, `neutral` |
| 6 | Reclassified, Rank lowered, Removed | `cat1_dark`, `cat1`, `cat1_light` |
| 6 | Expert panel added, 1 star added to 0 star conflict | `cat2_dark`, `cat2` |

When a new figure needs a color, pick it by meaning from the families above, add its row here, and use the `COLORS` key in the generator.
