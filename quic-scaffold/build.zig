const std = @import("std");

/// Build graph for the QUIC scaffold.
///
/// Produces:
///   - a library module ("quic") assembled from src/root.zig, which
///     re-exports the protocol submodules (packet, frame, connection,
///     stream, tls, varint);
///   - a demo executable (src/main.zig) that links against that module;
///   - a `test` step that runs unit tests found in the library module and
///     the executable's root module.
///
/// This is scaffolding only: none of the QUIC logic is implemented yet, so
/// the build exists to prove the module layout compiles and wires together
/// correctly.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module: the public surface of the QUIC implementation.
    const quic_mod = b.addModule("quic", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Demo/CLI executable that exercises the library module.
    const exe = b.addExecutable(.{
        .name = "quic-scaffold",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "quic", .module = quic_mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the quic-scaffold demo binary");
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    run_step.dependOn(&run_cmd.step);

    // Unit tests for the library module (covers all submodules reachable
    // from src/root.zig: varint, packet, frame, connection, stream, tls).
    const quic_mod_tests = b.addTest(.{
        .root_module = quic_mod,
    });
    const run_quic_mod_tests = b.addRunArtifact(quic_mod_tests);

    // Unit tests for the executable's own root module.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_quic_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);
}
