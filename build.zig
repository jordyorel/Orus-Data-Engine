const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const engine = b.addModule("orus_data_engine", .{
        .root_source_file = b.path("src/orus_data_engine.zig"),
        .target = target,
        .optimize = optimize,
    });
    engine.linkSystemLibrary("c", .{});
    engine.linkSystemLibrary("sqlite3", .{});
    const postgres_enabled = b.option(bool, "postgres", "Link the optional PostgreSQL connector") orelse false;
    if (postgres_enabled) {
        const libpq_path = b.option([]const u8, "libpq-path", "Directory containing libpq") orelse
            if (target.result.os.tag == .macos)
                if (target.result.cpu.arch == .aarch64)
                    "/opt/homebrew/opt/libpq/lib"
                else
                    "/usr/local/opt/libpq/lib"
            else
                null;
        if (libpq_path) |path| engine.addLibraryPath(.{ .cwd_relative = path });
        engine.linkSystemLibrary("pq", .{});
    }

    const exe = b.addExecutable(.{
        .name = "orusdata",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "orus_data_engine", .module = engine }},
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run", "Run the orusdata CLI");
    run_step.dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = engine });
    const integration_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "orus_data_engine", .module = engine }},
        }),
    });
    const test_step = b.step("test", "Run engine tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    test_step.dependOn(&b.addRunArtifact(integration_tests).step);

    addBenchmark(b, engine, target, "bench-csv", "benchmarks/csv_parse.zig");
    addBenchmark(b, engine, target, "bench-profile", "benchmarks/profiling.zig");
    addBenchmark(b, engine, target, "bench-cleaning", "benchmarks/cleaning.zig");
    addBenchmark(b, engine, target, "bench-pipeline", "benchmarks/pipeline.zig");
    addBenchmark(b, engine, target, "bench-matching", "benchmarks/matching.zig");
    addBenchmark(b, engine, target, "bench-jsonl", "benchmarks/jsonl.zig");

    const postgres_test = b.addExecutable(.{
        .name = "postgres-integration",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/connectors/postgres_integration.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "orus_data_engine", .module = engine }},
        }),
    });
    const postgres_test_step = b.step("test-postgres", "Run PostgreSQL integration test on port 55432");
    postgres_test_step.dependOn(&b.addRunArtifact(postgres_test).step);
}

fn addBenchmark(
    b: *std.Build,
    engine: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    name: []const u8,
    path: []const u8,
) void {
    const executable = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{.{ .name = "orus_data_engine", .module = engine }},
        }),
    });
    const run = b.addRunArtifact(executable);
    const step = b.step(name, name);
    step.dependOn(&run.step);
}
