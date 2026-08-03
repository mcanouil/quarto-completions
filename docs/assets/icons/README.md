# Icons

Everything here derives from `icon.svg`, the hand-authored master.
Nothing is traced, upscaled, or model-generated, so the whole set is reproducible from source.

The mark is the Quarto quadrant, reduced to a 32x32 grid: a circle split by a gutter on both axes.
Three panes are solid and the fourth is a dashed outline in the accent colour, which is what the project does.
The geometry is an homage to `quarto-icon.svg`, not a reuse of it: the palette is this site's own, from `../../_brand.yml`.

`icon.svg` carries an inline `@media (prefers-color-scheme: dark)` rule, so browsers that load it directly flip it with the theme: ink panes with a phosphor-deep suggestion in the light scheme, ash and phosphor in the dark one.

`logo.svg` is the same mark with those colours fixed to the dark variant.
It is the `logo.small` of `../../_brand.yml`, which Quarto puts in the navbar, and the navbar is graphite in both colour schemes, so a scheme-adaptive mark would draw its ink panes there in the light scheme and disappear.
The two files share their geometry and differ only in how they are coloured; change one and change the other.

## Rasters

The rasters sit on the graphite background, matching the navbar, which is dark in both schemes.
librsvg does not evaluate `prefers-color-scheme`, so `raster-dark.css` forces the dark variant.

Tools: `rsvg-convert` (librsvg) for the vector to raster step, `magick` (ImageMagick 7) for padding, flattening, and `.ico` assembly.
Neither is a build dependency; the commands are run by hand when the master changes.

Run from this directory.

```sh
for size in 32 144 154 410; do
  rsvg-convert -s raster-dark.css -w "${size}" -h "${size}" icon.svg -o "/tmp/icon-${size}.png"
done

magick /tmp/icon-32.png  -background '#0D1210' -flatten -strip /tmp/icon-32-flat.png
magick /tmp/icon-32-flat.png -define icon:format=png ../../favicon.ico
magick /tmp/icon-144.png -background '#0D1210' -gravity center -extent 180x180 -flatten apple-touch-icon.png
magick /tmp/icon-154.png -background '#0D1210' -gravity center -extent 192x192 -flatten icon-192.png
magick /tmp/icon-410.png -background '#0D1210' -gravity center -extent 512x512 -flatten icon-512.png
```

The favicon is flattened to an opaque PNG before the `.ico` is written.
Writing the `.ico` straight from the transparent render makes ImageMagick store an uncompressed 32-bit bitmap for the same 32x32 pixels; going through the flat PNG lets it pick a palette instead, at 2,238 bytes.

| File                   | Size    | Purpose                                             |
| ---------------------- | ------- | --------------------------------------------------- |
| `icon.svg`             | vector  | `rel="icon"`, and the source for everything below   |
| `logo.svg`             | vector  | `logo.small` of `_brand.yml`, the navbar mark       |
| `../../favicon.ico`    | 32x32   | site root, for clients that ignore the SVG          |
| `apple-touch-icon.png` | 180x180 | iOS home screen, opaque, roughly 10% padding        |
| `icon-192.png`         | 192x192 | `site.webmanifest`                                  |
| `icon-512.png`         | 512x512 | `site.webmanifest`, and the mark on the social card |

There is no maskable icon: this is a documentation site, not an installable application.

`icon-512.png` is also what `../social/og-image.typ` places on the social card, since Typst renders SVG through resvg, which ignores the media query.

## After a change

Regenerate the rasters, then regenerate the social card, which embeds `icon-512.png`.
See the header of `../social/og-image.typ`.
