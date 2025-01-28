const std = @import("std");
const sqlite = @import("sqlite");

const ipc = @import("ipc.zig");
const inotify = @import("inotify.zig");
const root = @import("../main.zig");

const DB_SCHEMA = @embedFile("res/schema.sql");

pub const DaemonError = error{
    InvalidDataDir,
};

pub fn run(allocator: std.mem.Allocator, config: root.Config, _: []const u8, cli_data_dir: ?[]const u8) !void {
    const data_dir = if (cli_data_dir) |path| path else dir: {
        const data_dir_postfix = "/dotvc/";

        if (std.posix.getenv("XDG_DATA_HOME")) |data_home| {
            const path = try std.mem.concat(
                allocator,
                u8,
                &[_][]const u8{ data_home, data_dir_postfix },
            );
            break :dir path;
        }

        if (std.posix.getenv("HOME")) |home| {
            const path = try std.mem.concat(
                allocator,
                u8,
                &[_][]const u8{ home, "/.local/share", data_dir_postfix },
            );
            break :dir path;
        }

        std.log.err("Unable to determine data directory", .{});
        return DaemonError.InvalidDataDir;
    };

    std.fs.cwd().makePath(data_dir) catch |err| {
        std.log.err("Failed to create dotvc data directory {s}: {}", .{ data_dir, err });
    };

    // Add 0-sentinel termination as SQlite expects that
    const sentinel_db_path = try std.mem.concatWithSentinel(
        allocator,
        u8,
        &[_][]const u8{ data_dir, "database.db" },
        0,
    );
    defer allocator.free(sentinel_db_path);

    var db = try sqlite.Db.init(.{
        .mode = sqlite.Db.Mode{ .File = sentinel_db_path },
        .open_flags = .{
            .write = true,
            .create = true,
        },
    });
    defer db.deinit();

    var ipc_manager = try ipc.Ipc.init(allocator);
    var watcher = try inotify.Inotify.init(allocator);

    defer ipc_manager.deinit();
    defer watcher.deinit();

    for (config.watch_paths) |watch_path| {
        std.log.info("Adding watcher for: {s}", .{watch_path.path});
        try watcher.addWatcher(watch_path.path);
    }

    // Main daemon event loop
    while (true) {
        const messages = try ipc_manager.readMessages();
        for (messages.items) |msg| {
            switch (msg.ipc_msg.value) {
                .shutdown => {
                    std.log.info("Shutting down daemon...", .{});
                    try msg.client.reply(ipc.IpcResponse{ .ok = ipc.IpcResponseOk{} });
                    try ipc_manager.disconnectClient(msg.client);
                    return;
                },
                .reload_config => unreachable,
            }
        }

        const events = try watcher.readEvents();
        if (events) |_events| {
            defer allocator.free(_events);

            for (_events) |event| {
                std.log.info("Ancestor: {s}, name: {?s}", .{ event.ancestor, event.name });
                try event.printMask();
            }
        }

        std.time.sleep(std.time.ns_per_ms * 10);
    }
}
