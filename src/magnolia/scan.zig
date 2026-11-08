//! SVG document scanner: a hand-rolled tag walker, no XML dependency.
//!
//! The scan is a single pass over the bytes. It tracks a transform stack for
//! nested groups, flattens basic shapes and paths into edges, and records
//! anything it recognised but could not render.

const std = @import("std");
const geom = @import("geom.zig");
const FillRule = @import("raster.zig").FillRule;
const numbers = @import("numbers.zig");
const pathdata = @import("pathdata.zig");
const stroke = @import("stroke.zig");
const gradient = @import("gradient.zig");
const defs = @import("defs.zig");
const transform = @import("transform.zig");
const PathBuf = @import("path.zig").PathBuf;

/// Stroke presentation state as it inherits down the tree. Kept separate from
/// `pending_stroke` (which is per-element) so a child that overrides only
/// `stroke-width` still inherits the parent's join and cap.
const StrokeState = struct {
    opts: stroke.Options = .{},
    present: bool = false,
    /// Multiplied into the rasterised outline's coverage. `stroke-opacity`
    /// and `opacity` are treated as the same number: nothing in this renderer
    /// self-overlaps, a stroked outline being one closed region, so the two
    /// only diverge on content that does not exist here yet.
    opacity: f32 = 1,
    /// Stroke paint. Separate from the fill colour: an element routinely has
    /// `fill:none;stroke:#fff`, so the two cannot share one field.
    color: ?[3]u8 = null,
    /// Gradient stroke (`stroke:url(#g)`). Parallel to `color` for exactly the
    /// same reason the fill has a separate `grad`: a paint server replaces the
    /// flat colour rather than supplementing it.
    grad: ?gradient.Linear = null,
};
const DStats = pathdata.DStats;

const Mat = geom.Mat;
const Pt = geom.Pt;
const scanNum = numbers.scanNum;
const skipSep = numbers.skipSep;

/// Attribute bag for one element. Fixed capacity: real SVG elements used for
/// icons stay well under 32 attributes, and this keeps the scan allocation-free.
pub const Attrs = struct {
    keys: [32][]const u8 = undefined,
    vals: [32][]const u8 = undefined,
    n: usize = 0,
    pub fn get(self: *const Attrs, k: []const u8) ?[]const u8 {
        var i: usize = 0;
        while (i < self.n) : (i += 1) if (std.mem.eql(u8, self.keys[i], k)) return self.vals[i];
        return null;
    }
    pub fn num(self: *const Attrs, k: []const u8, dflt: f32) f32 {
        const v = self.get(k) orelse return dflt;
        var i: usize = 0;
        return scanNum(v, &i) orelse dflt;
    }
};

/// What the scanner saw. `unsupported` names features that were recognised
/// but not rendered, so a bad icon fails loudly instead of silently.
pub const Report = struct {
    paths: usize = 0,
    shapes: usize = 0,
    skipped_subtrees: usize = 0,
    no_fill: usize = 0,
    stroked: usize = 0,
    arcs: usize = 0,
    unsupported: std.ArrayList([]const u8) = .empty,

    /// Every entry is duplicated, so the list owns all of it and `deinit` can
    /// free uniformly. Static string literals would leak otherwise, and the
    /// cost is a handful of tiny allocations on a path that only runs when an
    /// icon is already degraded.
    pub fn add(self: *Report, gpa: std.mem.Allocator, s: []const u8) void {
        // Deduplicate: the same limitation fires once per element, and a
        // document with a dozen gradient paths would otherwise bury every
        // other report under identical lines.
        for (self.unsupported.items) |u| {
            if (std.mem.eql(u8, u, s)) return;
        }
        const owned = gpa.dupe(u8, s) catch return;
        self.unsupported.append(gpa, owned) catch gpa.free(owned);
    }

    /// Formats "<tag> is not supported" into allocator-owned memory. The tag
    /// slice points into the source document, which the caller may drop, so
    /// it cannot be stored by reference.
    pub fn addUnsupported(self: *Report, gpa: std.mem.Allocator, tag: []const u8) void {
        const s = std.fmt.allocPrint(gpa, "<{s}> is not supported", .{tag}) catch return;
        self.unsupported.append(gpa, s) catch gpa.free(s);
    }

    pub fn deinit(self: *Report, gpa: std.mem.Allocator) void {
        for (self.unsupported.items) |s| gpa.free(s);
        self.unsupported.deinit(gpa);
        self.* = .{};
    }
};

pub const Scanner = struct {
    gpa: std.mem.Allocator,
    pb: *PathBuf,
    rep: *Report,
    view: ?[4]f32 = null,
    /// Target extent in output pixels. When both are non-zero the viewBox is
    /// mapped onto it (`xMidYMid meet`) before any element is dispatched, so
    /// geometry and stroke widths come out in real pixels. Zero means "leave
    /// the user units alone", which is what the unscaled `parseIcon` callers
    /// want.
    tx: ?f32 = null,
    ty: ?f32 = null,
    /// viewBox -> output mapping, filled in by the root <svg> arm and folded
    /// into the CTM once by `run`.
    root_fit: ?Mat = null,
    dstat: DStats = .{},
    rule: FillRule = .nonzero,
    /// Stroke settings for the element currently being dispatched. Set by
    /// `element`, consumed by `dispatch` once its geometry exists.
    pending_stroke: ?stroke.Options = null,
    /// Presentation attributes inherit down the tree, and icon sets put them
    /// on the root <svg> (fill="none" stroke="currentColor" stroke-width="2"
    /// stroke-linecap="round"). Without inheritance every icon in Feather,
    /// Lucide and Tabler renders as an unstroked outline.
    inherited_stroke: ?StrokeState = null,
    /// True when the nearest ancestor said fill="none".
    inherited_no_fill: bool = false,
    /// Inherited fill colour. Null means "let the caller pick" (an icon with no
    /// colour of its own), which keeps flat-icon callers working unchanged.
    /// Paint servers (`url(#grad)`) cannot be resolved here, so they leave this
    /// null and land in the report instead.
    inherited_fill: ?[3]u8 = null,
    /// Inherited `opacity` for the element currently being dispatched. Unlike
    /// stroke opacity this applies to fills too, so it lives beside the fill
    /// state rather than inside StrokeState.
    inherited_opacity: f32 = 1,
    /// Paint servers collected from the document up front. Empty when the
    /// document declares none, which is the common case for icon sets.
    defs_set: ?*const defs.Set = null,
    /// Stops backing the gradients handed out this parse. `Linear.stops` is a
    /// slice, so something has to own it for the Icon's lifetime; the defs
    /// collector's arrays do, and they outlive the scan.
    grad_owner: ?*const defs.Set = null,
    /// Every stop array this scan allocated, so the caller can transfer
    /// ownership to the Icon and free them in `deinit`.
    grad_stops: std.ArrayList([]gradient.Stop) = .empty,
    /// Inherited gradient fill. Set when an ancestor's fill resolved to a
    /// paint server; `inherited_fill` stays null so the flat path is unchanged.
    inherited_grad: ?gradient.Linear = null,

    fn isSkipTag(name: []const u8) bool {
        const tags = [_][]const u8{ "defs", "clipPath", "mask", "symbol", "pattern", "marker", "style", "title", "desc", "metadata" };
        for (tags) |t| if (std.mem.eql(u8, name, t)) return true;
        // Editor namespaces carry document state, not artwork. Inkscape writes
        // <sodipodi:namedview opacity="0.149"> as a SIBLING of <defs>, and its
        // opacity was absorbed into inherited state and stamped onto every
        // subsequent shape -- the whole daisy rendered at 15% over white.
        const editor_ns = [_][]const u8{ "sodipodi:", "inkscape:", "rdf:", "cc:", "dc:" };
        for (editor_ns) |p| if (std.mem.startsWith(u8, name, p)) return true;
        return false;
    }

    pub fn run(self: *Scanner, doc: []const u8) !void {
        var i: usize = 0;
        var ctm = Mat{};
        var stack: std.ArrayList(Mat) = .empty;
        defer stack.deinit(self.gpa);
        var rule_stack: std.ArrayList(FillRule) = .empty;
        defer rule_stack.deinit(self.gpa);
        var stroke_stack: std.ArrayList(?StrokeState) = .empty;
        defer stroke_stack.deinit(self.gpa);
        var no_fill_stack: std.ArrayList(bool) = .empty;
        defer no_fill_stack.deinit(self.gpa);
        var fill_stack: std.ArrayList(?[3]u8) = .empty;
        defer fill_stack.deinit(self.gpa);
        var depth: usize = 0;
        var skip_depth: ?usize = null;

        while (i < doc.len) {
            const lt = std.mem.indexOfScalarPos(u8, doc, i, '<') orelse break;
            i = lt;
            if (std.mem.startsWith(u8, doc[i..], "<!--")) {
                const e = std.mem.indexOfPos(u8, doc, i + 4, "-->") orelse break;
                i = e + 3;
                continue;
            }
            if (std.mem.startsWith(u8, doc[i..], "<?")) {
                const e = std.mem.indexOfScalarPos(u8, doc, i, '>') orelse break;
                i = e + 1;
                continue;
            }
            if (std.mem.startsWith(u8, doc[i..], "<!")) {
                const e = std.mem.indexOfScalarPos(u8, doc, i, '>') orelse break;
                i = e + 1;
                continue;
            }
            if (std.mem.startsWith(u8, doc[i..], "</")) {
                const e = std.mem.indexOfScalarPos(u8, doc, i, '>') orelse break;
                i = e + 1;
                if (depth > 0) depth -= 1;
                if (stack.pop()) |v| ctm = v;
                if (rule_stack.pop()) |v| self.rule = v;
                if (stroke_stack.pop()) |v| self.inherited_stroke = v;
                if (no_fill_stack.pop()) |v| self.inherited_no_fill = v;
                if (fill_stack.pop()) |v| self.inherited_fill = v;
                if (skip_depth) |sd| {
                    if (depth < sd) {
                        skip_depth = null;
                        self.rep.skipped_subtrees += 1;
                    }
                }
                continue;
            }
            i += 1;
            const ns = i;
            while (i < doc.len and (std.ascii.isAlphanumeric(doc[i]) or doc[i] == ':' or doc[i] == '-' or doc[i] == '_')) i += 1;
            const name = doc[ns..i];

            var at = Attrs{};
            var selfclose = false;
            while (i < doc.len) {
                while (i < doc.len and (doc[i] == ' ' or doc[i] == '\t' or doc[i] == '\n' or doc[i] == '\r')) i += 1;
                if (i >= doc.len) break;
                if (doc[i] == '>') {
                    i += 1;
                    break;
                }
                if (doc[i] == '/') {
                    selfclose = true;
                    i += 1;
                    continue;
                }
                const ks = i;
                while (i < doc.len and doc[i] != '=' and doc[i] != '>' and doc[i] != ' ' and doc[i] != '/') i += 1;
                const key = doc[ks..i];
                while (i < doc.len and (doc[i] == ' ' or doc[i] == '\t')) i += 1;
                var val: []const u8 = "";
                if (i < doc.len and doc[i] == '=') {
                    i += 1;
                    while (i < doc.len and (doc[i] == ' ' or doc[i] == '\t')) i += 1;
                    if (i < doc.len and (doc[i] == '"' or doc[i] == '\'')) {
                        const q = doc[i];
                        i += 1;
                        const vs = i;
                        while (i < doc.len and doc[i] != q) i += 1;
                        val = doc[vs..i];
                        if (i < doc.len) i += 1;
                    } else {
                        const vs = i;
                        while (i < doc.len and doc[i] != '>' and doc[i] != ' ' and doc[i] != '/') i += 1;
                        val = doc[vs..i];
                    }
                }
                if (at.n < at.keys.len and key.len > 0) {
                    at.keys[at.n] = key;
                    at.vals[at.n] = val;
                    at.n += 1;
                }
            }

            var local = Mat{};
            if (at.get("transform")) |t| local = transform.parse(t);
            const eff = ctm.mul(local);

            if (!selfclose) {
                try stack.append(self.gpa, ctm);
                try rule_stack.append(self.gpa, self.rule);
                try stroke_stack.append(self.gpa, self.inherited_stroke);
                try no_fill_stack.append(self.gpa, self.inherited_no_fill);
                try fill_stack.append(self.gpa, self.inherited_fill);
                ctm = eff;
                depth += 1;
                if (skip_depth == null and isSkipTag(name)) skip_depth = depth;
            }

            if (skip_depth == null) self.dispatch(name, &at, eff, selfclose) catch |e| {
                if (e == error.BadPath) self.rep.add(self.gpa, "path data did not parse");
            };
            // Fold the viewBox fit in once the root has been seen. Doing it
            // here rather than inside the root's own matrix keeps the fit out
            // of the root element's coordinates and applies it to everything
            // the root contains, which is the SVG rule.
            if (self.root_fit) |fit| {
                if (!selfclose and stack.items.len > 0) {
                    stack.items[stack.items.len - 1] = stack.items[stack.items.len - 1].mul(fit);
                    ctm = ctm.mul(fit);
                }
                self.root_fit = null;
            }
        }
    }

    fn setM(self: *Scanner, m: Mat) void {
        self.pb.m = m;
        self.pb.cur = .{ .x = 0, .y = 0 };
    }

    /// Draws one element into a SCRATCH path buffer, then decides what its
    /// geometry is for: identical centreline when it is only filled, stroked
    /// outline when a stroke is present. Doing it here rather than inside
    /// `element` keeps every shape arm unchanged -- they still emit a
    /// centreline and still do not know that stroking exists.
    fn dispatch(self: *Scanner, name: []const u8, at: *const Attrs, eff: Mat, selfclose: bool) !void {
        var scratch = PathBuf{ .gpa = self.gpa };
        defer scratch.deinit();

        const saved = self.pb;
        self.pb = &scratch;
        defer self.pb = saved;
        try self.element(name, at, eff, selfclose);

        if (scratch.edges.items.len == 0) return;

        // An element's own stroke wins; otherwise it inherits. A shape with
        // no stroke of its own inside a stroked root is still stroked.
        const opts = self.pending_stroke orelse (if (self.inherited_stroke) |s|
            (if (s.present) s.opts else null)
        else
            null);
        // Count here rather than where the attribute is parsed: a shape that
        // inherits its stroke from the root is still stroked, and counting at
        // the attribution site reported 0 for every Feather icon.
        if (opts != null and self.pending_stroke == null) self.rep.stroked += 1;
        if (opts == null) {
            // Fast path: no stroke, so the centreline is the geometry. This is
            // the only path any icon used before stroking existed.
            // Subpath indices are relative to the scratch, so they must be
            // rebased onto the destination or every element claims index 0.
            const base = saved.edges.items.len;
            for (scratch.edges.items, 0..) |e, i| {
                try saved.edges.append(self.gpa, e);
                try saved.rules.append(self.gpa, if (i < scratch.rules.items.len) scratch.rules.items[i] else saved.rule);
                try saved.alphas.append(self.gpa, if (i < scratch.alphas.items.len) scratch.alphas.items[i] else saved.alpha);
                try saved.colors.append(self.gpa, if (i < scratch.colors.items.len) scratch.colors.items[i] else scratch.color);
                // Gradients must cross this boundary too. Missing them here is
                // the same defect as the fill-colour drop: correct on the
                // scratch buffer, discarded on transfer, so the element
                // renders with nothing to paint and the run falls back to the
                // caller's default.
                try saved.gradients.append(self.gpa, if (i < scratch.gradients.items.len) scratch.gradients.items[i] else scratch.grad);
            }
            for (scratch.subpaths.items) |s| try saved.subpaths.append(self.gpa, base + s);
            return;
        }
        try self.strokeScratch(saved, &scratch, opts.?, eff);
    }

    /// Replaces the scratch centreline with its stroked outline.
    /// Mean linear scale of a transform. Stroke widths are in user units and
    /// must be scaled into output pixels, otherwise `stroke-width="2"` inside
    /// viewBox 24 rendered at 96 is drawn 2px wide instead of 8. Averaging the
    /// two axis magnitudes is what SVG's own non-uniform-stroke rule gives for
    /// the common case where they agree.
    fn meanScale(eff: geom.Mat) f32 {
        const sx = @sqrt(eff.a * eff.a + eff.b * eff.b);
        const sy = @sqrt(eff.c * eff.c + eff.d * eff.d);
        return (sx + sy) * 0.5;
    }

    fn strokeScratch(self: *Scanner, dest: *PathBuf, scratch: *PathBuf, opts: stroke.Options, eff: geom.Mat) !void {
        // A stroked outline is painted with the STROKE colour, which is a
        // different property from the fill. Using the centreline's fill colour
        // here painted the daisy's white petals in whatever the shape's fill
        // resolved to.
        const stroke_color: ?[3]u8 = if (self.inherited_stroke) |s| s.color else null;
        const stroke_grad: ?gradient.Linear = if (self.inherited_stroke) |s| s.grad else null;
        var pts: std.ArrayList(Pt) = .empty;
        defer pts.deinit(self.gpa);
        var out: std.ArrayList(geom.Edge) = .empty;
        defer out.deinit(self.gpa);

        // Scale the stroke into output units once, up front. Geometry in
        // `scratch` has already had the transform applied, so the width is the
        // only stroke quantity still in user units.
        var scaled = opts;
        scaled.width = opts.width * meanScale(eff);

        var k: usize = 0;
        while (k < scratch.subpaths.items.len) : (k += 1) {
            const start = scratch.subpaths.items[k];
            const end = if (k + 1 < scratch.subpaths.items.len) scratch.subpaths.items[k + 1] else scratch.edges.items.len;
            const seg = scratch.edges.items[start..end];
            if (seg.len == 0) continue;

            // A closed contour is one whose last edge returns to its first
            // point; `Z` guarantees that, so there is nothing else to test.
            const closed = @abs(seg[seg.len - 1].b.x - seg[0].a.x) < 1e-4 and
                @abs(seg[seg.len - 1].b.y - seg[0].a.y) < 1e-4;

            pts.clearRetainingCapacity();
            out.clearRetainingCapacity();
            try pts.append(self.gpa, seg[0].a);
            for (seg) |e| try pts.append(self.gpa, e.b);
            if (closed and pts.items.len > 1) _ = pts.pop();

            try stroke.contour(&out, self.gpa, pts.items, closed, scaled);
            const base = dest.edges.items.len;
            try dest.edges.appendSlice(self.gpa, out.items);
            try dest.rules.appendNTimes(self.gpa, dest.rule, out.items.len);
            try dest.alphas.appendNTimes(self.gpa, dest.alpha, out.items.len);
            // The stroke inherits the centreline's colour: `element` ran against
            // the scratch buffer, so the colour lives there, not on `dest`.
            try dest.colors.appendNTimes(self.gpa, stroke_color orelse scratch.color, out.items.len);
            // A stroked shape paints with the STROKE paint, gradient included.
            // Stamping null here discarded a resolved `stroke:url(#g)` and left
            // the outline with no paint at all.
            try dest.gradients.appendNTimes(self.gpa, stroke_grad, out.items.len);
            try dest.subpaths.append(self.gpa, base);
        }
    }

    fn element(self: *Scanner, name: []const u8, at: *const Attrs, eff: Mat, selfclose: bool) !void {
        _ = selfclose;
        if (std.mem.eql(u8, name, "svg")) {
            if (at.get("viewBox")) |vb| {
                var arr = [_]f32{0} ** 4;
                var k: usize = 0;
                var i: usize = 0;
                while (k < 4) {
                    skipSep(vb, &i);
                    arr[k] = scanNum(vb, &i) orelse break;
                    k += 1;
                }
                if (k == 4) self.view = arr;
            }
            // Map the viewBox onto the requested output extent. `meet` scales
            // by the smaller of the two ratios so the drawing fits and stays
            // centred, which is what every icon set assumes. Without this a
            // 0 0 24 24 viewBox rendered at 384 comes out 24px wide in the
            // corner of the frame -- the whole icon measured as a size
            // difference rather than a rendering one.
            // Map the viewBox onto the requested output extent (`xMidYMid
            // meet`: scale by the smaller ratio, then centre). Without this a
            // `0 0 24 24` viewBox rendered at 384 comes out 24px wide in the
            // corner of the frame, so the icon measures as a size difference
            // rather than a rendering one. `root_fit` is applied by the caller
            // once the root's own transform is known.
            if (self.view) |v| {
                if (self.tx) |tx| {
                    if (self.ty) |ty| {
                        if (v[2] > 0 and v[3] > 0 and tx > 0 and ty > 0) {
                            const sc = @min(tx / v[2], ty / v[3]);
                            self.root_fit = Mat{
                                .a = sc,
                                .b = 0,
                                .c = 0,
                                .d = sc,
                                .e = (tx - v[2] * sc) * 0.5 - v[0] * sc,
                                .f = (ty - v[3] * sc) * 0.5 - v[1] * sc,
                            };
                        }
                    }
                }
            }
            // Presentation attributes on the root are the normal place icon
            // sets put them, so they must be captured here rather than only
            // on leaf shapes. `element` also reads these; doing it here as
            // well is what makes them inherit.
            self.absorbPaint(at);
            return;
        }
        // fill-rule inherits through <g>, so it is read on every element and
        // restored on pop. Both the attribute and the style="" form occur in
        // the wild; icon sets mostly use fill-rule as an attribute on <path>,
        // editors tend to emit style="fill-rule:evenodd".
        if (at.get("fill-rule")) |fr| {
            if (std.mem.eql(u8, fr, "evenodd")) self.rule = .evenodd else if (std.mem.eql(u8, fr, "nonzero")) self.rule = .nonzero;
        } else if (at.get("style")) |st| {
            if (styleProp(st, "fill-rule")) |fr| {
                if (std.mem.eql(u8, fr, "evenodd")) self.rule = .evenodd else if (std.mem.eql(u8, fr, "nonzero")) self.rule = .nonzero;
            }
        }
        self.pb.rule = self.rule;
        // Opacity is per-element, NOT inherited like stroke and fill. A <g
        // opacity="0.5"> means "composite this group at half", not "make every
        // descendant half-transparent on top of its own alpha" -- inheriting it
        // down the tree would square it (0.5 group x 0.5 child = 0.25) and
        // darken nested groups progressively. So the accumulated group opacity
        // is a fresh reading of this element's own attribute each time, with
        // the group value folded in exactly once by the caller's stack.
        self.pb.alpha = self.inherited_opacity;
        if (at.get("opacity")) |o| {
            var oi: usize = 0;
            if (scanNum(o, &oi)) |v| self.pb.alpha = self.pb.alpha * std.math.clamp(v, 0, 1);
        } else if (at.get("style")) |st| {
            if (styleProp(st, "opacity")) |ov| {
                var oi: usize = 0;
                if (scanNum(ov, &oi)) |v| self.pb.alpha = self.pb.alpha * std.math.clamp(v, 0, 1);
            }
        }
        self.absorbPaint(at);
        // Stamp after absorbPaint: that call is what reads THIS element's own
        // `fill=` / `style="fill:..."`, so stamping before it would only ever
        // see the parent's colour.
        self.pb.color = self.inherited_fill orelse self.pb.color;
        self.pb.grad = null;
        if (at.get("fill")) |f| self.pb.grad = self.resolveGradient(f, eff);
        if (self.pb.grad == null) {
            if (at.get("style")) |st| {
                if (styleFill(st)) |sv| self.pb.grad = self.resolveGradient(sv, eff);
            }
        }
        // A gradient overrides the flat colour it would otherwise have
        // inherited, so `draw` takes the paint-server branch.
        if (self.pb.grad != null) self.pb.color = null;

        // fill / stroke intent
        const fill_attr = at.get("fill");
        const style_attr = at.get("style");
        const fill_none = if (fill_attr) |f| std.mem.eql(u8, f, "none") else false;
        // fill-opacity is a real coverage multiplier, not just a "is this
        // zero" probe. Reading only for zero meant an element at 0.6 painted
        // fully opaque -- the value was parsed and thrown away.
        const fill_opacity_val: f32 = if (at.get("fill-opacity") orelse (if (style_attr) |s| styleProp(s, "fill-opacity") else null)) |o| (blk: {
            var i: usize = 0;
            const v = scanNum(o, &i) orelse break :blk 1.0;
            break :blk std.math.clamp(v, 0, 1);
        }) else 1.0;
        const fill_opacity_zero = fill_opacity_val == 0;
        // Fold it into the per-edge alpha the fill will be stamped with. The
        // base is captured first so a later element cannot compound it.
        if (fill_opacity_val < 1.0) self.pb.alpha = self.pb.alpha * fill_opacity_val;
        const style_fill_none = if (style_attr) |s| (if (styleProp(s, "fill")) |fv| std.mem.eql(u8, fv, "none") else false) else false;
        self.pending_stroke = null;
        var stroke_opts: ?stroke.Options = null;
        // Editors (Inkscape, Illustrator) write every presentation property into
        // style="", never as a bare attribute. Reading only `stroke` here is
        // what dropped the daisy's petals: fill:none said "no fill" and the
        // stroke was invisible to this block, so the element looked empty and
        // was discarded.
        const stroke_src = at.get("stroke") orelse (if (style_attr) |st| styleProp(st, "stroke") else null);
        if (stroke_src) |s| {
            if (!std.mem.eql(u8, s, "none") and !std.mem.eql(u8, s, "transparent")) {
                self.rep.stroked += 1;
                // Start from the inherited stroke state and let this element's
                // own attributes override it. Building fresh Options here is
                // what gave every Feather path BUTT caps: the icon sets put
                // stroke-linecap="round" on the root <svg>, so a shape that
                // declares only a colour fell back to the struct default and
                // the ends came out square -- which reads as a point or a horn
                // at the end of every open subpath.
                var so = if (self.inherited_stroke) |inh| inh.opts else stroke.Options{};
                const sw = at.get("stroke-width") orelse (if (style_attr) |st| styleProp(st, "stroke-width") else null);
                if (sw) |w| {
                    var wi: usize = 0;
                    so.width = scanNum(w, &wi) orelse so.width;
                }
                const slj = at.get("stroke-linejoin") orelse (if (style_attr) |st| styleProp(st, "stroke-linejoin") else null);
                if (slj) |v| so.join = joinFrom(v);
                const slc = at.get("stroke-linecap") orelse (if (style_attr) |st| styleProp(st, "stroke-linecap") else null);
                if (slc) |v| so.cap = capFrom(v);
                const sml = at.get("stroke-miterlimit") orelse (if (style_attr) |st| styleProp(st, "stroke-miterlimit") else null);
                if (sml) |v| {
                    var mi: usize = 0;
                    so.miter_limit = scanNum(v, &mi) orelse so.miter_limit;
                }
                // Resolve a paint-server stroke here, where the CTM is in
                // scope. `absorbPaint` cannot do it (no `eff`), so without
                // this a `stroke:url(#g)` had no colour at all and the
                // stroked outline fell through to the draw default: black.
                if (std.mem.startsWith(u8, s, "url(")) {
                    if (self.resolveGradient(s, eff)) |g| {
                        var cur = self.inherited_stroke orelse StrokeState{};
                        cur.grad = g;
                        cur.color = null;
                        self.inherited_stroke = cur;
                    }
                }
                stroke_opts = so;
            }
        }
        self.pending_stroke = stroke_opts;
        const wants_fill = !(fill_none or fill_opacity_zero or style_fill_none);
        if (!wants_fill) self.rep.no_fill += 1;
        // A stroke-only element is the normal case for icon sets, not an
        // error. Nothing to draw at all is the error.
        if (!wants_fill and stroke_opts == null and
            !std.mem.eql(u8, name, "g") and !isContainerTag(name)) return;

        if (std.mem.eql(u8, name, "path")) {
            const d = at.get("d") orelse return;
            self.setM(eff);
            try pathdata.parse(self.pb, d, &self.dstat);
            self.rep.arcs = self.dstat.arc_count;
            self.rep.paths += 1;
            return;
        }
        if (std.mem.eql(u8, name, "rect")) {
            const x = at.num("x", 0);
            const y = at.num("y", 0);
            const w = at.num("width", 0);
            const h = at.num("height", 0);
            if (w <= 0 or h <= 0) return;
            if (at.get("rx") != null or at.get("ry") != null) self.rep.add(self.gpa, "rect rx/ry ignored (square corners)");
            self.setM(eff);
            self.pb.moveTo(.{ .x = x, .y = y });
            try self.pb.segTo(.{ .x = x + w, .y = y });
            try self.pb.segTo(.{ .x = x + w, .y = y + h });
            try self.pb.segTo(.{ .x = x, .y = y + h });
            try self.pb.segTo(.{ .x = x, .y = y });
            self.rep.shapes += 1;
            return;
        }
        if (std.mem.eql(u8, name, "circle") or std.mem.eql(u8, name, "ellipse")) {
            const cx = at.num("cx", 0);
            const cy = at.num("cy", 0);
            const rx = if (std.mem.eql(u8, name, "circle")) at.num("r", 0) else at.num("rx", 0);
            const ry = if (std.mem.eql(u8, name, "circle")) at.num("r", 0) else at.num("ry", 0);
            if (rx <= 0 or ry <= 0) return;
            self.setM(eff);
            const k: f32 = 0.5522847498307936;
            const ox = k * rx;
            const oy = k * ry;
            self.pb.moveTo(.{ .x = cx + rx, .y = cy });
            try self.pb.cubic(.{ .x = cx + rx, .y = cy + oy }, .{ .x = cx + ox, .y = cy + ry }, .{ .x = cx, .y = cy + ry });
            try self.pb.cubic(.{ .x = cx - ox, .y = cy + ry }, .{ .x = cx - rx, .y = cy + oy }, .{ .x = cx - rx, .y = cy });
            try self.pb.cubic(.{ .x = cx - rx, .y = cy - oy }, .{ .x = cx - ox, .y = cy - ry }, .{ .x = cx, .y = cy - ry });
            try self.pb.cubic(.{ .x = cx + ox, .y = cy - ry }, .{ .x = cx + rx, .y = cy - oy }, .{ .x = cx + rx, .y = cy });
            self.rep.shapes += 1;
            return;
        }
        if (std.mem.eql(u8, name, "polygon") or std.mem.eql(u8, name, "polyline")) {
            const pts = at.get("points") orelse return;
            self.setM(eff);
            var i: usize = 0;
            var first = true;
            var startp = Pt{ .x = 0, .y = 0 };
            while (true) {
                skipSep(pts, &i);
                if (i >= pts.len) break;
                const x = scanNum(pts, &i) orelse break;
                skipSep(pts, &i);
                const y = scanNum(pts, &i) orelse break;
                const p = Pt{ .x = x, .y = y };
                if (first) {
                    self.pb.moveTo(p);
                    startp = p;
                    first = false;
                } else try self.pb.segTo(p);
            }
            if (std.mem.eql(u8, name, "polygon")) try self.pb.segTo(startp);
            self.rep.shapes += 1;
            return;
        }
        if (std.mem.eql(u8, name, "line")) {
            self.rep.add(self.gpa, "line is stroke-only, nothing to fill");
            return;
        }
        // Anything that reaches here is a tag this scanner does not draw:
        // <text>, <image>, <use>, filters, and the rest. Reporting it is the
        // difference between "this icon is blank" and silence, so the default
        // arm is load-bearing. Unknown presentation tags (<style> children and
        // the like) are filtered out earlier by isSkipTag.
        if (!isContainerTag(name)) self.rep.addUnsupported(self.gpa, name);
    }

    /// Structural tags carry no geometry of their own; reporting them as
    /// unsupported would bury the real ones in noise.
    /// Folds `stroke*` and `fill` attributes into the inherited state.
    /// Called for containers, whose own geometry may be empty but whose
    /// children depend on these values.
    /// Turns a `url(#id)` fill into a `Linear` in device space. Returns null
    /// for everything else -- flat colours are handled by `parseColor`, and a
    /// reference to a paint server that is missing or uses
    /// objectBoundingBox is reported rather than approximated.
    fn resolveGradient(self: *Scanner, val: []const u8, eff: Mat) ?gradient.Linear {
        const id = defs.refId(val) orelse return null;
        const set = self.defs_set orelse {
            self.rep.add(self.gpa, "fill url(...) paint server not found");
            return null;
        };
        const d = set.find(id) orelse {
            self.rep.add(self.gpa, "fill url(...) paint server not found");
            return null;
        };
        if (!d.user_space) {
            self.rep.add(self.gpa, "gradientUnits=objectBoundingBox not supported");
            return null;
        }
        // xlink:href chains: a gradient with no stops of its own borrows them.
        var stops = d.stops.items;
        var hops: usize = 0;
        var cur = d;
        while (stops.len == 0 and cur.href != null and hops < 8) : (hops += 1) {
            const next = set.find(cur.href.?) orelse break;
            stops = next.stops.items;
            cur = next;
        }
        if (stops.len == 0) {
            self.rep.add(self.gpa, "gradient has no stops");
            return null;
        }
        var out_stops = self.gpa.alloc(gradient.Stop, stops.len) catch return null;
        self.grad_stops.append(self.gpa, out_stops) catch {
            self.gpa.free(out_stops);
            return null;
        };
        for (stops, 0..) |sdef, k| {
            out_stops[k] = .{ .offset = sdef.offset, .color = sdef.color, .opacity = sdef.opacity };
        }
        const p0 = eff.apply(.{ .x = d.x1 orelse 0, .y = d.y1 orelse 0 });
        const p1 = eff.apply(.{ .x = d.x2 orelse 1, .y = d.y2 orelse 0 });
        return .{ .x0 = p0.x, .y0 = p0.y, .x1 = p1.x, .y1 = p1.y, .stops = out_stops };
    }

    fn absorbPaint(self: *Scanner, at: *const Attrs) void {
        if (at.get("fill")) |f| {
            self.inherited_no_fill = std.mem.eql(u8, f, "none");
            if (!self.inherited_no_fill) {
                if (std.mem.startsWith(u8, f, "url(")) {
                    // Leave it unresolved here. `absorbPaint` has no CTM, so it
                    // cannot place a gradient; `resolveGradient` does that at
                    // the stamp site and reports only what it cannot resolve.
                    // Warning here too reported a failure for gradients that
                    // subsequently rendered perfectly.
                } else if (parseColor(f)) |c| {
                    self.inherited_fill = c;
                }
            }
        } else if (at.get("style")) |st| {
            if (styleFill(st)) |sv| {
                self.inherited_no_fill = std.mem.eql(u8, sv, "none");
                if (!self.inherited_no_fill) {
                    if (std.mem.startsWith(u8, sv, "url(")) {
                        // See the bare-attribute arm above.
                    } else if (parseColor(sv)) |c| {
                        self.inherited_fill = c;
                    }
                }
            }
            if (styleProp(st, "fill")) |fv| {
                if (std.mem.eql(u8, fv, "none")) self.inherited_no_fill = true;
            }
        }
        // Read opacity before any early return: an element can carry opacity
        // with no stroke attribute at all, and the old `orelse return` below
        // would have dropped it silently.
        if (at.get("opacity")) |o| {
            var oi: usize = 0;
            if (scanNum(o, &oi)) |v| self.inherited_opacity = std.math.clamp(v, 0, 1);
        }
        if (at.get("style")) |st| {
            if (styleProp(st, "opacity")) |ov| {
                var oi: usize = 0;
                if (scanNum(ov, &oi)) |v| self.inherited_opacity = std.math.clamp(v, 0, 1);
            }
        }
        // Editors put every presentation property in style="", so an early
        // return on the bare attribute alone dropped the stroke colour (and
        // the whole inherited stroke state) for every Inkscape file.
        const stroke_val = at.get("stroke") orelse (if (at.get("style")) |st| styleProp(st, "stroke") else null) orelse return;
        if (std.mem.eql(u8, stroke_val, "none") or std.mem.eql(u8, stroke_val, "transparent")) {
            self.inherited_stroke = null;
            return;
        }
        var cur = self.inherited_stroke orelse StrokeState{};
        cur.present = true;
        if (std.mem.startsWith(u8, stroke_val, "url(")) {
            // Leave it unresolved. Like the fill arm above, this function has
            // no CTM, so it cannot place a gradient; the stroke_opts block in
            // `element` resolves it against `eff`. Warning here reported a
            // failure for gradients that then rendered correctly.
        } else if (parseColor(stroke_val)) |c| cur.color = c;
        if (at.get("stroke-width")) |w| {
            var wi: usize = 0;
            cur.opts.width = scanNum(w, &wi) orelse cur.opts.width;
        }
        if (at.get("stroke-linejoin")) |v| cur.opts.join = joinFrom(v);
        if (at.get("stroke-linecap")) |v| cur.opts.cap = capFrom(v);
        if (at.get("stroke-opacity")) |v| {
            var oi: usize = 0;
            if (scanNum(v, &oi)) |o| cur.opacity = std.math.clamp(o, 0, 1);
        }
        if (at.get("stroke-miterlimit")) |v| {
            var mi: usize = 0;
            cur.opts.miter_limit = scanNum(v, &mi) orelse cur.opts.miter_limit;
        }
        // A stroke colour can also arrive through style="".
        if (at.get("style")) |st| {
            if (styleProp(st, "stroke-width")) |sv| {
                var wi: usize = 0;
                cur.opts.width = scanNum(sv, &wi) orelse cur.opts.width;
            }
        }
        self.inherited_stroke = cur;
    }

    /// Reads one property out of a `style=""` declaration list. Matches the
    /// property name exactly and requires the colon, so `stroke` does not
    /// match inside `stroke-width`.
    pub fn styleProp(st: []const u8, prop: []const u8) ?[]const u8 {
        var i: usize = 0;
        while (i < st.len) {
            while (i < st.len and (st[i] == ' ' or st[i] == ';' or st[i] == '\t')) i += 1;
            const ns = i;
            while (i < st.len and st[i] != ':' and st[i] != ';') i += 1;
            const name = std.mem.trim(u8, st[ns..i], " \t");
            if (i >= st.len or st[i] != ':') {
                while (i < st.len and st[i] != ';') i += 1;
                continue;
            }
            i += 1;
            while (i < st.len and (st[i] == ' ' or st[i] == '\t')) i += 1;
            const vs = i;
            while (i < st.len and st[i] != ';') i += 1;
            const val = std.mem.trim(u8, st[vs..i], " \t\r\n");
            if (std.mem.eql(u8, name, prop)) return if (val.len == 0) null else val;
        }
        return null;
    }

    /// Extracts the `fill:` value out of a `style=""` declaration list.
    pub fn styleFill(st: []const u8) ?[]const u8 {
        return styleProp(st, "fill");
    }

    /// Parses the colour forms that actually occur in icon sets: `#rgb`,
    /// `#rrggbb`, `rgb()`/`rgba()`, and the handful of CSS keywords. Anything
    /// else returns null so the caller keeps the inherited colour rather than
    /// painting black over it.
    pub fn parseColor(v: []const u8) ?[3]u8 {
        const t = std.mem.trim(u8, v, " \t\r\n");
        if (t.len == 0) return null;
        if (t[0] == '#') return hexColor(t[1..]);
        if (std.mem.startsWith(u8, t, "rgb")) {
            const o = std.mem.indexOfScalar(u8, t, '(') orelse return null;
            const cl = std.mem.indexOfScalarPos(u8, t, o, ')') orelse return null;
            var it = std.mem.tokenizeAny(u8, t[o + 1 .. cl], ", \t");
            var out: [3]u8 = .{ 0, 0, 0 };
            var n: usize = 0;
            while (it.next()) |tok| : (n += 1) {
                if (n >= 3) break;
                var ci: usize = 0;
                const f = scanNum(tok, &ci) orelse return null;
                out[n] = @intFromFloat(std.math.clamp(f, 0, 255));
            }
            return if (n >= 3) out else null;
        }
        const kw = .{
            .{ "black", [3]u8{ 0, 0, 0 } },      .{ "white", [3]u8{ 255, 255, 255 } },
            .{ "red", [3]u8{ 255, 0, 0 } },      .{ "green", [3]u8{ 0, 128, 0 } },
            .{ "blue", [3]u8{ 0, 0, 255 } },     .{ "yellow", [3]u8{ 255, 255, 0 } },
            .{ "gray", [3]u8{ 128, 128, 128 } }, .{ "grey", [3]u8{ 128, 128, 128 } },
            .{ "transparent", [3]u8{ 0, 0, 0 } },
        };
        inline for (kw) |e| {
            if (std.mem.eql(u8, t, e[0])) return e[1];
        }
        return null;
    }

    fn hexColor(d: []const u8) ?[3]u8 {
        if (d.len != 3 and d.len != 6) return null;
        var out: [3]u8 = .{ 0, 0, 0 };
        if (d.len == 3) {
            for (0..3) |k| {
                const n = std.fmt.charToDigit(d[k], 16) catch return null;
                out[k] = @intCast(n * 17);
            }
        } else {
            for (0..3) |k| {
                const hi = std.fmt.charToDigit(d[k * 2], 16) catch return null;
                const lo = std.fmt.charToDigit(d[k * 2 + 1], 16) catch return null;
                out[k] = @intCast(hi * 16 + lo);
            }
        }
        return out;
    }

    fn joinFrom(v: ?[]const u8) stroke.Join {
        const s = v orelse return .round;
        if (std.mem.eql(u8, s, "miter")) return .miter;
        if (std.mem.eql(u8, s, "bevel")) return .bevel;
        return .round;
    }

    fn capFrom(v: ?[]const u8) stroke.Cap {
        const s = v orelse return .butt;
        if (std.mem.eql(u8, s, "round")) return .round;
        if (std.mem.eql(u8, s, "square")) return .square;
        return .butt;
    }

    fn isContainerTag(name: []const u8) bool {
        const tags = [_][]const u8{ "svg", "g", "a", "switch" };
        for (tags) |t| if (std.mem.eql(u8, name, t)) return true;
        return false;
    }
};
