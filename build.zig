const std = @import("std");
const rl = @import("raylib-zig/build.zig");

// Built with zig 0.12.0-dev.1685+994e19164
pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const raylib = rl.getModule(b, "raylib-zig");
    const raylib_math = rl.math.getModule(b, "raylib-zig");
    //web exports are completely separate
    if (target.getOsTag() == .emscripten) {
        const exe_lib = rl.compileForEmscripten(b, "jae-3d-hyperreal", "src/main.zig", target, optimize);
        exe_lib.addModule("raylib", raylib);
        exe_lib.addModule("raylib-math", raylib_math);
        const raylib_artifact = rl.getArtifact(b, target, optimize);
        // Note that raylib itself is not actually added to the exe_lib output file, so it also needs to be linked with emscripten.
        exe_lib.linkLibrary(raylib_artifact);
        const link_step = try rl.linkWithEmscripten(b, &[_]*std.Build.Step.Compile{ exe_lib, raylib_artifact });
        b.getInstallStep().dependOn(&link_step.step);
        const run_step = try rl.emscriptenRunStep(b);
        run_step.step.dependOn(&link_step.step);
        const run_option = b.step("run", "Run jae-3d-hyperreal");
        run_option.dependOn(&run_step.step);
        return;
    }

    const exe = b.addExecutable(.{ .name = "jae-3d-hyperreal", .root_source_file = .{ .path = "src/main.zig" }, .optimize = optimize, .target = target });

    rl.link(b, exe, target, optimize);
    exe.addModule("raylib", raylib);
    exe.addModule("raylib-math", raylib_math);

    const run_cmd = b.addRunArtifact(exe);
    const run_step = b.step("run", "Run jae-3d-hyperreal");
    run_step.dependOn(&run_cmd.step);
    b.installArtifact(exe);

    // Test suite
    // - Run with "zig build test"
    // {
    //     var test_runner = b.addTest(.{
    //         .root_source_file = .{ .path = "src/trenchbroom.zig" },
    //         .target = target,
    //         .optimize = optimize,
    //     });
    //     const test_step = b.step("test", "Runs the test suite.");
    //     var run = b.addRunArtifact(test_runner);
    //     test_step.dependOn(&run.step);
    // }
}
