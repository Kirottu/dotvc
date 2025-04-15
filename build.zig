const std = @import("std");

// Although this function looks imperative, note that its job is to
// declaratively construct a build graph that will be executed by an external
// runner.
pub fn build(b: *std.Build) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "dotvc",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const zig_toml = b.dependency("toml", .{}).module("zig-toml");
    const yazap = b.dependency("yazap", .{}).module("yazap");
    const sqlite = b.dependency("sqlite", .{}).module("sqlite");
    const vaxis = b.dependency("vaxis", .{}).module("vaxis");
    const fuzzig = b.dependency("fuzzig", .{}).module("fuzzig");
    const zeit = b.dependency("zeit", .{}).module("zeit");
    const httpz = b.dependency("httpz", .{}).module("httpz");
    const myzql = b.dependency("myzql", .{}).module("myzql");
    const zregex = b.dependency("zregex", .{}).module("zregex");

    exe.root_module.addImport("zig-toml", zig_toml);
    exe.root_module.addImport("yazap", yazap);
    exe.root_module.addImport("sqlite", sqlite);
    exe.root_module.addImport("vaxis", vaxis);
    exe.root_module.addImport("fuzzig", fuzzig);
    exe.root_module.addImport("zeit", zeit);
    exe.root_module.addImport("zregex", zregex);

    const server_exe = b.addExecutable(.{
        .name = "dotvc-server",
        .root_source_file = b.path("src/server/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    server_exe.root_module.addImport("httpz", httpz);
    server_exe.root_module.addImport("myzql", myzql);
    server_exe.root_module.addImport("yazap", yazap);
    server_exe.root_module.addImport("zig-toml", zig_toml);
    server_exe.root_module.addImport("zregex", zregex);

    const client_step = b.step("client", "Build client");
    const server_step = b.step("server", "Build server");

    const install_client = b.addInstallArtifact(exe, .{});
    const install_server = b.addInstallArtifact(server_exe, .{});

    client_step.dependOn(&install_client.step);
    server_step.dependOn(&install_server.step);

    // This *creates* a Run step in the build graph, to be executed when another
    // step is evaluated that depends on it. The next line below will establish
    // such a dependency.
    const run_client = b.addRunArtifact(exe);
    const run_server = b.addRunArtifact(server_exe);

    // By making the run step depend on the install step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    // This is not necessary, however, if the application depends on other installed
    // files, this ensures they will be present and in the expected location.
    run_client.step.dependOn(client_step);
    run_server.step.dependOn(server_step);

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        // Passing args to both run steps, maybe stupid?
        run_client.addArgs(args);
        run_server.addArgs(args);
    }

    // This creates a build step. It will be visible in the `zig build --help` menu,
    // and can be selected like this: `zig build run`
    // This will evaluate the `run` step rather than the default, which is "install".
    const run_client_step = b.step("run", "Run the client");
    const run_server_step = b.step("run-server", "Run the server");
    run_client_step.dependOn(&run_client.step);
    run_server_step.dependOn(&run_server.step);

    const client_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    client_unit_tests.root_module.addImport("zig-toml", zig_toml);
    client_unit_tests.root_module.addImport("yazap", yazap);
    client_unit_tests.root_module.addImport("sqlite", sqlite);
    client_unit_tests.root_module.addImport("zeit", zeit);
    client_unit_tests.root_module.addImport("vaxis", vaxis);
    client_unit_tests.root_module.addImport("fuzzig", fuzzig);

    const server_unit_tests = b.addTest(.{
        .root_source_file = b.path("src/server/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    server_unit_tests.root_module.addImport("zig-toml", zig_toml);
    server_unit_tests.root_module.addImport("yazap", yazap);
    server_unit_tests.root_module.addImport("myzql", myzql);
    server_unit_tests.root_module.addImport("httpz", httpz);
    server_unit_tests.root_module.addImport("zregex", zregex);

    const run_exe_unit_tests = b.addRunArtifact(client_unit_tests);
    const run_server_unit_tests = b.addRunArtifact(server_unit_tests);

    // Similar to creating the run step earlier, this exposes a `test` step to
    // the `zig build --help` menu, providing a way for the user to request
    // running the unit tests.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_exe_unit_tests.step);
    test_step.dependOn(&run_server_unit_tests.step);
}
