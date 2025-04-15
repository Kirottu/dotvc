const std = @import("std");
const sqlite = @import("sqlite");
const toml = @import("zig-toml");

const ipc = @import("ipc.zig");
const inotify = @import("inotify.zig");
const database = @import("database.zig");
const sync = @import("sync.zig");
const root = @import("../main.zig");

pub const DB_FILE = "database";
pub const DB_EXTENSION = ".sqlite3";

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

    const db_path = try std.mem.concat(allocator, u8, &.{ data_dir, DB_FILE, DB_EXTENSION });
    defer allocator.free(db_path);

    var main_db = try database.Database.init(allocator, db_path, false);
    var ipc_manager = try ipc.Ipc.init(allocator);
    var watcher = try inotify.Inotify.init(allocator);
    var sync_manager = try sync.SyncManager.init(allocator, data_dir, &config);
    var watcher_map = std.AutoHashMap(u64, *const root.WatchPath).init(allocator);

    defer main_db.deinit();
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

    // Arena for more eficient memory allocation during loops & not needing
    // to keep track of memory allocations
    var loop_arena = std.heap.ArenaAllocator.init(allocator);
    defer loop_arena.deinit();

    // Main daemon event loop
    while (true) {
        _ = loop_arena.reset(.retain_capacity);
        const loop_alloc = loop_arena.allocator();

        // A bool to track whether or not something has been written to the DB, used to selectively
        // the local DB to the server
        var db_modified = false;

        // Read & handle IPC messages
        if (ipc_manager.readMessages(loop_alloc)) |messages| {
            for (messages.items) |msg| {
                switch (msg.ipc_msg) {
                    .shutdown => {
                        std.log.info("Shutting down daemon...", .{});
                        try msg.client.reply(.{ .ok = .{} });
                        try ipc_manager.disconnectClient(msg.client);
                        return;
                    },
                    .reload_config => {
                        std.log.info("Reloading config...", .{});
                        try msg.client.reply(.{ .ok = .{} });
                        result.deinit();
                        result = try parser.parseFile(config_path);
                        config = result.value;
                        sync_manager.config = &config;

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
                    .index_all => {
                        for (config.watch_paths) |*watch_path| {
                            const file = std.fs.openFileAbsolute(watch_path.path, .{}) catch |err| {
                                std.log.err("Error occurred adding {s} to db: {}", .{ watch_path.path, err });
                                continue;
                            };
                            defer file.close();
                            const metadata = file.metadata() catch |err| {
                                std.log.err("Failed to read file {s} metadata: {}", .{ watch_path.path, err });
                                continue;
                            };

                            if (metadata.kind() == std.fs.File.Kind.directory) {
                                var dir = std.fs.openDirAbsolute(watch_path.path, .{ .iterate = true }) catch |err| {
                                    std.log.err("Failed to open directory {s} for iteration: {}", .{ watch_path.path, err });
                                    continue;
                                };

                                var iterator = dir.iterate();
                                while (try iterator.next()) |entry| {
                                    if (indexFile(
                                        loop_alloc,
                                        watch_path.path,
                                        entry.name,
                                        watch_path,
                                        &main_db,
                                        &config,
                                    ) catch |err| {
                                        std.log.err("Failed to index file {s}: {}", .{ watch_path.path, err });
                                        continue;
                                    }) {
                                        db_modified = true;
                                    }
                                }
                            } else {
                                var it = std.mem.splitBackwardsScalar(u8, watch_path.path, '/');
                                if (it.next()) |filename| {
                                    if (indexFile(
                                        loop_alloc,
                                        watch_path.path[0 .. watch_path.path.len - filename.len],
                                        filename,
                                        watch_path,
                                        &main_db,
                                        &config,
                                    ) catch |err| {
                                        std.log.err("Failed to index file {s}: {}", .{ watch_path.path, err });
                                        continue;
                                    }) {
                                        db_modified = true;
                                    }
                                }
                            }
                        }
                        try msg.client.reply(.{ .ok = .{} });
                    },
                    .get_all_dotfiles => |db_name| blk: {
                        var db, const aux = if (db_name) |_db_name| db_sel: {
                            const aux_db_path = try std.mem.concat(loop_alloc, u8, &.{ data_dir, "/sync_databases/", _db_name, DB_EXTENSION });

                            var db = database.Database.init(loop_alloc, aux_db_path, true) catch {
                                try msg.client.reply(.{ .err = .invalid_database });
                                break :blk;
                            };

                            break :db_sel .{ &db, true };
                        } else db_sel: {
                            break :db_sel .{ &main_db, false };
                        };
                        const db_dotfiles = try db.getDotfiles(loop_alloc);
                        const ipc_dotfile_buf = try loop_alloc.alloc(ipc.IpcDistilledDotfile, db_dotfiles.len);

                        for (0.., db_dotfiles) |i, tuple| {
                            const dotfile, const id = tuple;

                            ipc_dotfile_buf[i] = ipc.IpcDistilledDotfile{
                                .rowid = id,
                                .date = dotfile.date,
                                .path = dotfile.path,
                                .tags = dotfile.tags,
                            };
                        }

                        try msg.client.reply(.{ .dotfiles = ipc_dotfile_buf });

                        // Cleanup database if it's an aux database
                        if (aux) {
                            db.deinit();
                        }
                    },
                    .get_dotfile => |req| blk: {
                        var db, const aux = if (req.database) |db_name| db_sel: {
                            const aux_db_path = try std.mem.concat(loop_alloc, u8, &.{ data_dir, "/sync_databases/", db_name, DB_EXTENSION });

                            var db = database.Database.init(allocator, aux_db_path, true) catch {
                                try msg.client.reply(.{ .err = .invalid_database });
                                break :blk;
                            };
                            break :db_sel .{ &db, true };
                        } else db_sel: {
                            break :db_sel .{ &main_db, false };
                        };

                        const dotfile = try db.getDotfile(loop_alloc, req.rowid);

                        try msg.client.reply(.{
                            .dotfile = ipc.IpcDotfile{ .path = dotfile.path, .content = dotfile.content },
                        });

                        if (aux) {
                            db.deinit();
                        }
                    },
                    .sync_login => |state| {
                        sync_manager.login(loop_alloc, state) catch |err| {
                            std.log.err("Failed to authenticate sync: {}", .{err});
                        };
                        try msg.client.reply(.{ .ok = .{} });
                    },
                    .sync_logout => {
                        sync_manager.logout(loop_alloc) catch |err| {
                            std.log.err("Failed to deauthenticate sync: {}", .{err});
                        };
                        try msg.client.reply(.{ .ok = .{} });
                    },
                    .purge_sync => {
                        sync_manager.purge(loop_alloc) catch |err| {
                            std.log.err("Failed to purge sync: {}", .{err});
                        };
                        try msg.client.reply(.{ .ok = .{} });
                    },
                    .get_sync_status => {
                        if (sync_manager.state) |state| {
                            try msg.client.reply(.{
                                .sync_status = ipc.SyncStatus{ .synced = .{
                                    .last_sync = sync_manager.last_sync,
                                    .host = state.value.host,
                                    .db_name = state.value.db_name,
                                    .username = state.value.username,
                                    .manifests = if (sync_manager.last_sync_manifests) |manifests| manifests.value else null,
                                } },
                            });
                        } else {
                            try msg.client.reply(.{
                                .sync_status = ipc.SyncStatus{ .not_synced = .{} },
                            });
                        }
                    },
                }
            }
        } else |err| {
            std.log.err("Error reading IPC messages: {}", .{err});
        }

        // Read & handle Inotify events
        const events = try watcher.readEvents(loop_alloc);
        for (events.items) |event| {
            std.log.info("Ancestor: {s}, name: {?s}", .{ event.ancestor, event.name });
            try event.printMask();

            const watch_path = watcher_map.get(event.watcher_id).?;

            if (indexFile(
                loop_alloc,
                event.ancestor,
                event.name,
                watch_path,
                &main_db,
                &config,
            ) catch |err| {
                std.log.err("Failed to index file {s}: {}", .{ watch_path.path, err });
                continue;
            }) {
                db_modified = true;
            }
        }

        sync_manager.syncPeriodic(loop_alloc) catch |err| {
            std.log.err("Failed to connect to sync server: {}", .{err});
        };

        if (db_modified) {
            sync_manager.syncLocal(loop_alloc) catch |err| {
                std.log.err("Failed to sync local database: {}", .{err});
            };
        }

        std.time.sleep(std.time.ns_per_ms * 10);
    }
}

fn indexFile(
    loop_alloc: std.mem.Allocator,
    ancestor: []const u8,
    name: []const u8,
    watch_path: *const root.WatchPath,
    db: *database.Database,
    config: *const root.Config,
) !bool {
    var match = false;
    if (watch_path.ignore) |ignore| {
        for (ignore) |pattern| {
            if (glob(pattern, name)) {
                match = true;
                break;
            }
        }
    }

    for (config.global_ignore) |pattern| {
        if (glob(pattern, name)) {
            match = true;
            break;
        }
    }

    if (match) {
        return false;
    }

    const path = try std.mem.concat(
        loop_alloc,
        u8,
        &.{ ancestor, name },
    );

    std.log.info("Adding revision for {s} to database", .{path});

    const file = try std.fs.openFileAbsolute(path, std.fs.File.OpenFlags{});
    defer file.close();

    const size = (try file.stat()).size;
    const date = std.time.timestamp();

    const buf = try loop_alloc.alloc(u8, size);

    _ = try file.readAll(buf);

    try db.addDotfile(database.Dotfile{
        .path = path,
        .content = buf,
        .tags = watch_path.tags,
        .date = date,
    });
    return true;
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
