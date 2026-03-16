const std = @import("std");

// Learn more about this file here: https://ziglang.org/learn/build-system
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "zest",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    // When testing memory with valgrind
    // exe.linkLibC();

    // This declares intent for the executable to be installed into the
    // standard location when the user invokes the "install" step (the default
    // step when running `zig build`).
    b.installArtifact(exe);
    const install_main_compat = b.addInstallBinFile(exe.getEmittedBin(), "main");
    b.getInstallStep().dependOn(&install_main_compat.step);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_cmd = b.addRunArtifact(exe);

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // -- Tests --
    const t = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test_all.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_t = b.addRunArtifact(t);
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_t.step);

    // -- AFL++ Fuzz Harness --
    const fuzz_step = b.step("fuzz", "Build AFL++ instrumented parser fuzz target");
    const enable_fuzz = b.option(
        bool,
        "enable-fuzz",
        "Enable fuzz build graph wiring (disabled by default to keep normal builds lightweight)",
    ) orelse false;

    if (!enable_fuzz) {
        const explain = b.addSystemCommand(&.{
            "sh",
            "-c",
            "echo 'fuzz step disabled. Re-run with -Denable-fuzz=true.' >&2; exit 1",
        });
        fuzz_step.dependOn(&explain.step);
        return;
    }

    const afl_cc = b.findProgram(&.{"afl-cc"}, &.{}) catch {
        const explain = b.addSystemCommand(&.{
            "sh",
            "-c",
            "echo 'afl-cc not found in PATH. Install AFL++ and retry with -Denable-fuzz=true.' >&2; exit 1",
        });
        fuzz_step.dependOn(&explain.step);
        return;
    };

    const fuzz_obj = b.addObject(.{
        .name = "zest_parser_fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fuzz_main.zig"),
            .target = target,
            .optimize = .Debug,
        }),
    });
    fuzz_obj.root_module.stack_check = false;
    fuzz_obj.root_module.link_libc = true;

    const run_afl_cc = b.addSystemCommand(&.{ afl_cc, "-O3" });
    run_afl_cc.addArg("-o");
    const fuzz_bin = run_afl_cc.addOutputFileArg("zest-fuzz-afl");
    run_afl_cc.addFileArg(b.path("third_party/zig-afl-kit/afl.c"));
    run_afl_cc.addFileArg(fuzz_obj.getEmittedLlvmBc());

    const install_fuzz = b.addInstallBinFile(fuzz_bin, "zest-fuzz-afl");
    fuzz_step.dependOn(&install_fuzz.step);
}
