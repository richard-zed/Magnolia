const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const sakura_dep = b.dependency("sakura", .{ .target = target, .optimize = optimize });
    const sakura = sakura_dep.module("sakura");

    const mod = b.addModule("magnolia", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{ .root_module = mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the test suite");
    test_step.dependOn(&run_tests.step);

    const sheet = b.addExecutable(.{
        .name = "sheet",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/sheet.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "magnolia", .module = mod }},
        }),
    });
    b.installArtifact(sheet);

    // Oracle: render one SVG at a fixed size for pixel comparison against a
    // reference renderer. Kept because the only trustworthy check on this
    // rasteriser is a diff, not a visual opinion.
    const oracle = b.addExecutable(.{
        .name = "oracle",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/oracle.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "root.zig", .module = mod }},
        }),
    });
    b.installArtifact(oracle);

    // Pixel verification goes through Sakura, an independent decoder. Checking
    // our output with a decoder written the same session as the encoder proves
    // nothing.
    const decode = b.addExecutable(.{
        .name = "decode",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/decode.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "sakura", .module = sakura }},
        }),
    });
    b.installArtifact(decode);

    // `zig build sheet <out.png> <cell> <file.svg>...` needs argv. 0.17 removed
    // `Build.args` in favour of a run step that collects passthru arguments
    // itself, so the two versions need different wiring and neither branch
    // compiles on the other.
    const sheet_step = b.step("sheet", "Render SVGs to a contact sheet");
    if (@hasDecl(std.Build.Step.Run, "addPassthruArgs")) {
        const run_sheet = b.addRunArtifact(sheet);
        run_sheet.addPassthruArgs();
        sheet_step.dependOn(&run_sheet.step);
    } else {
        const run_sheet = b.addRunArtifact(sheet);
        if (b.args) |args| run_sheet.addArgs(args);
        sheet_step.dependOn(&run_sheet.step);
    }

    // `zig build test` must also COMPILE every auxiliary binary. Three separate
    // times a stale field shape hid inside rc/oracle/decode while the suite
    // stayed green, because the test step only builds the module and the test
    // runner. A binary that does not compile is not a test failure unless the
    // test step depends on it.
    test_step.dependOn(&decode.step);
    test_step.dependOn(&oracle.step);
    test_step.dependOn(&sheet.step);
}
