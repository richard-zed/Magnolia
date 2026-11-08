# Magnolia

An SVG icon renderer in Zig. Turns an icon file into a coverage raster, with
no runtime dependencies and no allocation per draw.

## What it does

Rasters SVG icons to an antialiased alpha/colour buffer:

- `<path>` (including elliptical arcs), `rect` with `rx`/`ry`, `circle`,
  `ellipse`, `polygon`, `polyline`, `line`
- groups and nested transforms
- `viewBox` with `xMidYMid meet`
- `linearGradient` and `radialGradient`, in both `userSpaceOnUse` and
  `objectBoundingBox` units, with `gradientTransform`, focal `fx`/`fy`, and
  all three `spreadMethod` values
- gradients on fills *and* strokes
- `fill`, `stroke`, `fill-rule`, `opacity`, `fill-opacity`, `stroke-opacity`,
  `stroke-width`, `stroke-linecap`, `stroke-linejoin`, `stroke-miterlimit`
- `currentColor` resolved against the inherited `color` property

Presentation attributes inherit down the tree, and the `style=""` form is
honoured where editors emit it.

## What it does not do

`clipPath`, `mask`, `<use>`/`<symbol>`, `pattern`, `marker`, `stroke-dasharray`,
and `<text>` are skipped. Nothing is silently guessed: skipped subtrees are
counted in the report.

## Usage

```zig
const icon = try magnolia.parseIcon(gpa, svg_source);
defer icon.deinit(gpa);
icon.draw(&raster, .{ 0, 0, 0 });
```

`parseIconSized(gpa, src, width, height)` maps the `viewBox` onto a specific
output extent first.

## Tools

`zig build oracle <svg> <png> <w> [h]` renders one file and prints the resolved
gradient geometry, for comparing against a reference renderer.

## Verified against

`rsvg-convert`. Gradient and shape output agree to within antialiasing; the
`oracle` binary exists to keep that comparison cheap.

## License

MIT. See `LICENSE`.
