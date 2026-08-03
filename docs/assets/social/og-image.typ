// Social preview card for this site, 1200x630.
//
// This is one way to produce a card, not a house style or a template to copy.
// It is committed so that this site's own card can be regenerated from source
// rather than being an orphaned binary; anything that emits a 1200x630 PNG
// would do just as well.
//
// Rendered to og-image.png from `docs/` with:
//
//   typst compile --root . --format png --ppi 72 \
//     assets/social/og-image.typ assets/social/og-image.png
//   magick assets/social/og-image.png -alpha off -strip \
//     -define png:compression-level=9 assets/social/og-image.png
//
// Typst writes an alpha channel that is opaque everywhere, since the page has
// a solid fill. Dropping it is lossless.
//
// `--root .` is what lets the template reach the mark in assets/icons/; Typst
// otherwise sandboxes it to its own directory.
//
// The page is 1200pt by 630pt and the render is 72 ppi, so one point is one
// pixel and the output is exactly 1200x630.
//
// The mark comes in as icon-512.png rather than icon.svg because Typst renders
// SVG through resvg, which does not evaluate `prefers-color-scheme` and would
// draw the light variant: ink panes, invisible on graphite. That PNG is already
// the dark variant on an opaque graphite square, so it sits seamlessly on the
// page fill.
//
// Colours and fonts come from ../../_brand.yml. Both faces have to be installed
// on the machine that renders this; `typst fonts` lists what it can see.

#let graphite = rgb("#0D1210")
#let ash = rgb("#DCE5DE")
#let ash-muted = rgb("#8C9C93")
#let phosphor = rgb("#4FCB84")

#set page(width: 1200pt, height: 630pt, margin: 80pt, fill: graphite)
#set text(fill: ash)

#align(horizon)[
  #stack(
    dir: ttb,
    spacing: 40pt,
    image("/assets/icons/icon-512.png", width: 128pt),
    text(font: "JetBrains Mono", weight: 700, size: 76pt, tracking: -2pt)[
      quarto #text(fill: phosphor)[completions]
    ],
    text(font: "Inter", weight: 300, size: 34pt, fill: ash-muted)[
      Tab completion for the Quarto CLI, in the shell you already use.
    ],
  )
]
