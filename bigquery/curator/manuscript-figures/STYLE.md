# Manuscript Figure Style

Every manuscript figure uses one palette, one typeface and one set of sizes. They are defined once, in [`figure_style.py`](figure_style.py), and every `generate_figureN.py` imports them. Don't define colors, fonts or sizes in a generator. To change one, change `figure_style.py`, recheck it (below), rerun every generator and re-paste the images.

Run `python3 figure_style.py` to draw the palette reference into `output/style/palette.png`.

## Color carries meaning

The palette follows the [CvC presentation deck](https://docs.google.com/presentation/d/1POxmsRhDwmm_t6ftY4uN9cQ7F-auxpzNud8j5KRPVDw/edit). Slide 4 ("Concordance in ClinVar") sets the clinical scale. The other slides supply the deck's teal accent and slate ink.

| Family | Meaning, in every figure | Base | Steps, dark to light |
| --- | --- | --- | --- |
| Clinically okay | No conflict, concordant submissions, B/LB | `ok` `#2E75B6` | `#1F4E79`, `#2E75B6`, `#5B9BD5`, `#9DC3E6` |
| Uncertain | VUS, conflicts that are not medically significant | `uncertain` `#ED7D31` | `#ED7D31`, `#F4B183` |
| Medically significant | P/LP, P/LP vs VUS or B/LB conflicts | `medsig` `#C00000` | `#C00000` only |
| CvC | CvC's own work: candidates submitted, CvC flags, CvC outcomes | `cvc` `#1B9E77` | `#024F39`, `#0D7154`, `#1B9E77`, `#43B991` |
| Neutral | No change, other, not recorded, all ClinVar as a comparison | `neutral` `#A3A29C` | `#5C5B57`, `#A3A29C`, `#D9D8D3` |
| GDR level | ClinGen gene-disease relationship clinical validity levels, in ClinGen's own colors | `gdr_*`, one key per level | Definitive `#245C41`, Strong `#329760`, Moderate `#5DCE88`, Limited `#F87878`, No Known Disease Relationship `#67748A`, Disputed `#DE3B3A`, Refuted `#8E2A29` |
| Category 1 | No shared meaning; categories named by the figure's legend | `cat1` `#7030A0` | `#4A1A70`, `#7030A0`, `#9457C2`, `#B585DD` |
| Category 2 | As category 1, used only after it | `cat2` `#D17DB0` | `#8E4072`, `#B5608F`, `#D17DB0` |

Rules:

- **A semantic color means one thing.** Blue, orange, red, teal-green and gray keep the meanings above in every figure. Never use them for anything else, even when a figure has no clinical content. For example, "Reclassified" in Figure 6 is not blue, because blue means clinically okay.
- **CvC is teal-green, not red.** Red means medically significant. The deck's own teal, `#438086`, reads as gray and is too close to the clinical blue for color-blind readers, so CvC uses the nearest teal-green that passes.
- **Steps within a family show ordered sub-levels of the same meaning**, such as the kinds of CvC outcome in Figure 4A. Darker means more of that meaning.
- **Category colors are for legend-named categories only**, such as consequence groups or gene-disease validity levels. They mean nothing across figures. Use category 1's steps first, then category 2. More than seven categories in one figure should fold into "Other".
- **GDR levels always use ClinGen's colors.** The user set this on 2026-11-19, from ClinGen's Gene-Disease Clinical Validity statistics page, so a GDR level looks the same in the manuscript as on ClinGen's site. Use a `gdr_*` key for every GDR level (Definitive through Refuted) and for nothing else. Key by the level, not by position: Limited is always `gdr_limited`.
- **GDR colors overlap three meanings, so keep them apart.** ClinGen's greens and reds were not chosen against this palette:
  - `gdr_strong` is almost the same as `cvc` (ΔE 3.1). A figure that shows a supported GDR level must not also use `cvc`.
  - `gdr_disputed` is close to `medsig` (ΔE 9.2), and all the GDR reds read as "medically significant" next to it. A figure that shows insufficient GDR levels must not also use `medsig`.
  - `gdr_limited` and `neutral` are close for deutan readers (ΔE 6.6), and Limited vs Disputed is ΔE 13.1 for everyone. Label every GDR segment directly, or give the values in the table under the figure.
  - Limited vs Strong fails for protan readers (ΔE 3.4), as red and green do. Don't rely on color alone to tell supported from insufficient levels; the labels carry it.
- **Steps retired to keep clear of the GDR reds.** On 2026-11-19 the user removed `medsig_dark` `#8B0000` (ΔE 5.0 from `gdr_refuted`), `medsig_light` `#E2382A` (ΔE 1.5 from `gdr_disputed`) and `uncertain_dark` `#C55A11` (ΔE 8.0 from `gdr_disputed`). No figure used them. Don't add darker or lighter medically significant or uncertain steps back without checking them against the GDR reds.
- **`cvc`, `medsig` and `uncertain` stay as they are**, though they sit near GDR colors (`cvc` vs `gdr_strong` ΔE 3.1, `medsig` vs `gdr_disputed` 9.2, `uncertain` vs `gdr_limited` 8.1). Moving them gains little, because the nearby space is taken by `ok` and `cat2`. They also match the deck and the draft's captions. The user decided this on 2026-11-19. Keep the rule above instead: a figure that shows GDR levels uses neither `cvc` nor `medsig`.
- **If a figure must show supported GDR levels next to CvC work**, solve it in that figure, not in the palette. For example, mark CvC's share with an outline or hatching over the GDR fill, or keep CvC in the figure's text and table rather than in color.
- **Gray is reserved for neutral.** Use it for no change, other, not recorded, and for all ClinVar when it is the comparison for a CvC group.
- **Text is ink, never a series color.** Values and labels use `ink` `#1F1F1F` or `ink_muted` `#52514E`. Use `label_ink(fill)` for text on a fill.

## Color blindness

The palette was checked with the dataviz skill's validator, which simulates protan, deutan and tritan vision. Passing values:

- **The six base colors as one set, all pairs on white:** worst color-blind separation ΔE 8.0 (CvC vs uncertain, protan), at the 8.0 target. Worst normal-vision separation is ΔE 16.1, above the 15 floor.
- **GDR levels** are ClinGen's colors and are not tuned to this palette. Each ramp reads light to dark: the reds pass the ordinal check; in the greens, `gdr_moderate` is 1.97:1 on white, just under the 2:1 floor, so label it directly. Their clashes with other families are listed under the color rules above.
- **Each family's steps:** pass the ordinal check, with lightness rising evenly and the lightest step at least 2:1 against white.
- **Lighter fills:** `uncertain` (2.77:1), `cat2` (2.89:1), `ok_light`, `neutral` and the lightest steps are below 3:1 on white. Wherever they appear, label the marks directly or put the values in the table under the figure, which every figure already has.
- **Never rely on color alone.** Use direct labels where they fit, a legend for two or more series, and a 2 px white gap between touching fills.

To recheck after a change, from the dataviz skill's `scripts` folder:

```sh
node validate_palette.js "#2E75B6,#ED7D31,#C00000,#1B9E77,#7030A0,#D17DB0" --mode light --pairs all --surface "#ffffff"
node validate_palette.js "#024F39,#0D7154,#1B9E77,#43B991" --ordinal --mode light --surface "#ffffff"
node validate_palette.js "#F87878,#DE3B3A,#8E2A29" --ordinal --mode light --surface "#ffffff"
node validate_palette.js "#5DCE88,#329760,#245C41" --ordinal --mode light --surface "#ffffff"
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
| 5 | Limited, Disputed, Refuted (switch from `cat1_light`, `cat1`, `cat1_dark`) | `gdr_limited`, `gdr_disputed`, `gdr_refuted` |
| 5 | Not recorded | `neutral` |
| 5 | No Known (not drawn on current data; switch from `cat2`) | `gdr_no_known` |
| 6 | Flagged through CvC | `cvc` |
| 6 | Flagged outside CvC, Other | `neutral_dark`, `neutral` |
| 6 | Reclassified, Rank lowered, Removed | `cat1_dark`, `cat1`, `cat1_light` |
| 6 | Expert panel added, 1 star added to 0 star conflict | `cat2_dark`, `cat2` |

When a new figure needs a color, pick it by meaning from the families above, add its row here, and use the `COLORS` key in the generator.
