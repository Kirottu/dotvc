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
                &.{ data_home, data_dir_postfix },
            );
            break :dir path;
        }

        if (std.posix.getenv("HOME")) |home| {
            const path = try std.mem.concat(
                allocator,
                u8,
                &.{ home, "/.local/share", data_dir_postfix },
            );
            break :dir path;
        }

        std.log.err("Unable to determine data directory", .{});
        return DaemonError.InvalidDataDir;
    };
    defer allocator.free(data_dir);

    std.fs.cwd().makePath(data_dir) catch |err| {
        std.log.err("Failed to create dotvc data directory {s}: {}", .{ data_dir, err });
    };

    var hostname_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const hostname = try std.posix.gethostname(&hostname_buf);

    const db_path = try std.mem.concat(allocator, u8, &.{ data_dir, hostname, ".db" });
    defer allocator.free(db_path);

    var db = try database.Database.init(allocator, db_path, false);
    var ipc_manager = try ipc.Ipc.init(allocator);
    var watcher = try inotify.Inotify.init(allocator);
    // Map to assiciate the watcher ID with the config entry
    var watcher_map = std.AutoHashMap(u64, *const root.WatchPath).init(allocator);

    defer db.deinit();
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

        for (messages.value.items) |msg| {
            switch (msg.ipc_msg) {
                .shutdown => {
                    std.log.info("Shutting down daemon...", .{});
                    try msg.client.reply(ipc.IpcResponse{ .ok = ipc.IpcNone{} });
                    try ipc_manager.disconnectClient(msg.client);
                    return;
                },
                .reload_config => {
                    std.log.info("Reloading config...", .{});
                    try msg.client.reply(ipc.IpcResponse{ .ok = ipc.IpcNone{} });
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
                .index_all => unreachable,
                .get_all_dotfiles => {
                    const db_dotfiles = try db.getDotfiles();
                    const ipc_dotfile_buf = try allocator.alloc(ipc.IpcDistilledDotfile, db_dotfiles.value.len);

                    defer db_dotfiles.deinit();
                    defer allocator.free(ipc_dotfile_buf);

                    for (0.., db_dotfiles.value) |i, tuple| {
                        const dotfile, const id = tuple;

                        ipc_dotfile_buf[i] = ipc.IpcDistilledDotfile{
                            .rowid = id,
                            .date = dotfile.date,
                            .path = dotfile.path,
                            .tags = dotfile.tags,
                        };
                    }

                    try msg.client.reply(ipc.IpcResponse{ .dotfiles = ipc_dotfile_buf });
                },
                .get_dotfile => |rowid| {
                    const dotfile = try db.getDotfile(rowid);
                    defer dotfile.deinit();

                    try msg.client.reply(ipc.IpcResponse{
                        .dotfile = ipc.IpcDotfile{ .path = dotfile.value.path, .content = dotfile.value.content },
                    });
                },
            }
        }

        const events = try watcher.readEvents();
        defer events.deinit();

        for (events.items) |event| {
            std.log.info("Ancestor: {s}, name: {?s}", .{ event.ancestor, event.name });
            try event.printMask();

            const watch_path = watcher_map.get(event.watcher_id).?;

            var match = false;
            if (watch_path.ignore) |ignore| {
                for (ignore) |pattern| {
                    if (glob(pattern, event.name)) {
                        match = true;
                        break;
                    }
                }
            }

            for (config.global_ignore) |pattern| {
                if (glob(pattern, event.name)) {
                    match = true;
                    break;
                }
            }

            if (match) {
                continue;
            }

            const path = try std.mem.concat(
                allocator,
                u8,
                &.{ event.ancestor, event.name },
            );
            defer allocator.free(path);

            std.log.info("Adding revision for {s} to database", .{path});

            const file = try std.fs.cwd().openFile(path, std.fs.File.OpenFlags{});
            defer file.close();

            const size = (try file.stat()).size;
            const date = std.time.timestamp();

            const buf = try allocator.alloc(u8, size);
            defer allocator.free(buf);

            const read = try file.readAll(buf);
            if (read != size) {
                std.log.err("Read file size does not match expected size, not adding to database (expected: {}, read: {})", .{ size, read });
            } else {
                try db.addDotfile(database.Dotfile{
                    .path = path,
                    .content = buf,
                    .tags = watch_path.tags,
                    .date = date,
                });
            }
        }

        std.time.sleep(std.time.ns_per_ms * 10);
    }
}

/// Supports simple globbing, wildcards at either end or at both of the pattern
fn glob(pattern: []const u8, string: []const u8) bool {
    const wild_start = pattern[0] == '*';
    const wild_end = pattern[pattern.len - 1] == '*';
    const matchable_length = pattern.len - @intFromBool(wild_start) - @intFromBool(wild_end);

    var matched: u32 = 0;
    if (wild_start and wild_end) {
        for (string) |chr| {
            if (chr == pattern[matched + @intFromBool(wild_start)]) {
                matched += 1;
                if (matched == matchable_length) {
                    return true;
                }
            } else {
                matched = 0;
            }
        }
        return false;
    } else if (wild_end) {
        for (string) |chr| {
            if (chr == pattern[matched]) {
                matched += 1;
            } else {
                break;
            }
        }
        return matched == matchable_length;
    } else if (wild_start) {
        var i = string.len;
        var pat_i = pattern.len;
        while (i > 0) {
            i -= 1;
            pat_i -= 1;

            if (string[i] == pattern[pat_i]) {
                matched += 1;
            } else {
                break;
            }
        }
        return matched == matchable_length;
    } else {
        return std.mem.eql(u8, pattern, string);
    }
}

const expect = std.testing.expect;

test "glob start and end" {
    try expect(glob("*test*", "test"));
    try expect(glob("*test*", "___test"));
    try expect(glob("*test*", "test___"));
    try expect(glob("*test*", "___test___"));
    try expect(glob("*test*", "___testtest___"));
    try expect(!glob("*test*", ""));
}

test "glob start" {
    try expect(glob("*test", "_____test"));
    try expect(glob("*test", "test"));
    try expect(!glob("*test", "_____test_"));
    try expect(!glob("*test", "test_"));
}

test "glob end" {
    try expect(glob("test*", "test"));
    try expect(!glob("test*", "_____test"));
    try expect(!glob("test*", "_____test_"));
    try expect(glob("test*", "test_"));
    try expect(glob("test*", "test______"));
    try expect(glob("test*", "test______"));
}

test "glob none" {
    try expect(glob("test", "test"));
    try expect(!glob("test", "tes"));
}
