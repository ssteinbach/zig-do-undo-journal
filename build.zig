//! Build script for do-undo journal library

const std = @import("std");

pub fn build(
    b: *std.Build,
) void 
{
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // build option
    const test_filter = b.option(
        []const u8,
        "test-filter",
        "filter for tests to run",
    ) orelse &.{};

    // library
    const lib_mod = b.addModule(
        "do_undo_journal",
        .{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
        }
    );

    const name = "do_undo_journal";
    const lib = b.addLibrary(
        .{
            .linkage = .static,
            .name = name,
            .root_module = lib_mod,
        }
    );

    b.installArtifact(lib);

    const lib_unit_tests = b.addTest(
        .{
            .name = "test_" ++ name,
            .root_module = lib_mod,
            .filters = &.{ test_filter },
        }
    );

    const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_lib_unit_tests.step);

    // also install the test binary for lldb needs
    const install_test_bin = b.addInstallArtifact(
        lib_unit_tests,
        .{},
    );
    test_step.dependOn(&install_test_bin.step);

    // add a target that drops the binary into lldb
    const lldb = b.addSystemCommand(
        &.{
            "lldb",
            "-o",
            "r",
            // add lldb flags before --
            "--",
        }
    );

    lldb.addArtifactArg(lib_unit_tests);
    const lldb_step = b.step(
        "debug",
        "run the tests under lldb"
    );
    lldb_step.dependOn(&lldb.step);

    const install_docs = b.addInstallDirectory(
        .{
            .source_dir = lib_unit_tests.getEmittedDocs(),
            .install_dir = .prefix,
            .install_subdir = "docs/do-undo-journal",
        },
    );

    const docs_step = b.step(
        "docs",
        "Copy documentation artifacts to prefix path",
    );
    docs_step.dependOn(&install_docs.step);
}
