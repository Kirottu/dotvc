const std = @import("std");
const sqlite = @import("sqlite");
const toml = @import("zig-toml");

const ipc = @import("ipc.zig");
const inotify = @import("inotify.zig");
const database = @import("database.zig");
const root = @import("../main.zig");

pub const DaemonError = error{
    InvalidDataDir,
};

pub fn run(allocator: std.mem.Allocator, config_path: []const u8, cli_data_dir: ?[]const u8) !void {
    var parser = toml.Parser(root.Config).init(allocator);
    defer parser.deinit();

    var result = try parser.parseFile(config_path);
    defer result.deinit();

    var config = result.value;

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

    var buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const hostname = try std.posix.gethostname(&buf);

    const db_path = try std.mem.concat(allocator, u8, &[_][]const u8{ data_dir, hostname, ".db" });

    _ = try database.Database.init(allocator, db_path);
    var ipc_manager = try ipc.Ipc.init(allocator);
    var watcher = try inotify.Inotify.init(allocator);
    // Map to assiciate the watcher ID with the config entry
    var watcher_map = std.AutoHashMap(u64, *const root.WatchPath).init(allocator);

    defer ipc_manager.deinit();
    defer watcher.deinit();
    defer watcher_map.deinit();

    for (config.watch_paths) |*watch_path| {
        std.log.info("Adding watcher for: {s}", .{watch_path.path});
        const id = watcher.addWatcher(watch_path.path) catch |err| {
            std.log.err("Error creating watcher for path {s}: {}. Skipping directory", .{ watch_path.path, err });
            continue;
        };

        try watcher_map.put(id, watch_path);
    }

    // Main daemon event loop
    while (true) {
        const messages = try ipc_manager.readMessages();
        defer messages.deinit();

        for (messages.items) |msg| {
            switch (msg.ipc_msg.value) {
                .shutdown => {
                    std.log.info("Shutting down daemon...", .{});
                    try msg.client.reply(ipc.IpcResponse{ .ok = ipc.IpcResponseOk{} });
                    try ipc_manager.disconnectClient(msg.client);
                    return;
                },
                .reload_config => {
                    std.log.info("Reloading config...", .{});
                    try msg.client.reply(ipc.IpcResponse{ .ok = ipc.IpcResponseOk{} });
                    try ipc_manager.disconnectClient(msg.client);
                    result.deinit();
                    result = try parser.parseFile(config_path);
                    config = result.value;

                    watcher_map.clearRetainingCapacity();

                    watcher.purgeWatchers();
                    for (config.watch_paths) |*watch_path| {
                        std.log.info("Adding watcher for: {s}", .{watch_path.path});
                        const id = watcher.addWatcher(watch_path.path) catch |err| {
                            std.log.err("Error creating watcher for path {s}: {}. Skipping directory", .{ watch_path.path, err });
                            continue;
                        };

                        try watcher_map.put(id, watch_path);
                    }
                },
            }
        }

        const events = try watcher.readEvents();
        defer events.deinit();

        for (events.items) |event| {
            std.log.info("Ancestor: {s}, name: {?s}", .{ event.ancestor, event.name });
            try event.printMask();
            _ = watcher_map.get(event.watcher_id);
            // TODO: Actually do something with the events
        }

        std.time.sleep(std.time.ns_per_ms * 10);
    }
}
