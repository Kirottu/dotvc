const std = @import("std");

const root = @import("../main.zig");
const daemon = @import("daemon.zig");

// 30 minutes
const DEFAULT_SYNC_INTERVAL = 1800;
pub const AUX_DATABASE_PATH = "/sync_databases";
const STATE_FILE = "sync_state.json";

pub const SyncState = struct {
    token: []const u8,
    db_name: []const u8,
    username: []const u8,
    host: []const u8,
};

pub const Manifest = struct {
    name: []const u8,
    timestamp: i64,
};

pub const SyncManager = struct {
    client: std.http.Client,
    data_dir: []const u8,
    config: *root.Config,
    state: ?root.ArenaAllocated(SyncState),

    last_sync: i64 = 0,
    last_sync_manifests: ?root.ArenaAllocated([]Manifest) = null,

    local_sync_queued: bool = false,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, data_dir: []const u8, config: *root.Config) !SyncManager {
        const client = std.http.Client{ .allocator = allocator };

        const state_path = try std.mem.concat(allocator, u8, &.{ data_dir, "/", STATE_FILE });
        const state_file = std.fs.cwd().openFile(state_path, .{}) catch null;

        defer allocator.free(state_path);
        defer if (state_file) |file| file.close();

        const state = if (state_file) |file| blk: {
            var arena = std.heap.ArenaAllocator.init(allocator);
            const alloc = arena.allocator();
            const size = (try file.metadata()).size();
            const buf = try alloc.alloc(u8, size);
            _ = try file.readAll(buf);

            const state = try std.json.parseFromSliceLeaky(SyncState, alloc, buf, .{});
            break :blk root.ArenaAllocated(SyncState){
                .arena = arena,
                .value = state,
            };
        } else null;

        return SyncManager{
            .client = client,
            .data_dir = data_dir,
            .config = config,
            .state = state,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SyncManager) void {
        self.last_sync_manifests.deinit();
        self.client.deinit();
        self.state.deinit();
    }

    /// Authenticate sync with a state
    pub fn login(self: *SyncManager, loop_alloc: std.mem.Allocator, new_state: SyncState) !void {
        if (self.state) |*state| {
            state.deinit();
        } else {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            const token = try arena.allocator().alloc(u8, new_state.token.len);
            const host = try arena.allocator().alloc(u8, new_state.host.len);
            const db_name = try arena.allocator().alloc(u8, new_state.db_name.len);
            const username = try arena.allocator().alloc(u8, new_state.username.len);

            @memcpy(token, new_state.token);
            @memcpy(host, new_state.host);
            @memcpy(db_name, new_state.db_name);
            @memcpy(username, new_state.username);

            self.state = .{
                .arena = arena,
                .value = .{
                    .token = token,
                    .host = host,
                    .db_name = db_name,
                    .username = username,
                },
            };
        }

        var buf = std.ArrayList(u8).init(loop_alloc);
        try std.json.stringify(new_state, .{}, buf.writer());

        const state_path = try std.mem.concat(loop_alloc, u8, &.{ self.data_dir, "/", STATE_FILE });

        var file = std.fs.cwd().createFile(state_path, .{}) catch |err| {
            std.log.err("Error writing sync state to file: {}", .{err});
            return;
        };

        try file.writeAll(buf.items);
    }

    pub fn purge(self: *SyncManager, loop_alloc: std.mem.Allocator) !void {
        const state = self.state orelse return;
        const url = try std.mem.concat(
            loop_alloc,
            u8,
            &.{ state.value.host, "/databases/delete/", state.value.db_name },
        );

        var body = std.ArrayList(u8).init(loop_alloc);
        const res = try self.client.fetch(.{
            .location = .{ .url = url },
            .method = .DELETE,
            .response_storage = .{ .dynamic = &body },
            .extra_headers = &.{std.http.Header{ .name = "Token", .value = state.value.token }},
        });

        if (res.status != .ok) {
            std.log.err("Fetching database manifest failed: {}, {s}", .{ res.status, body.items });
            return;
        }

        try self.logout(loop_alloc);
    }

    pub fn logout(self: *SyncManager, loop_alloc: std.mem.Allocator) !void {
        var state = self.state orelse return;
        state.deinit();
        self.state = null;

        const state_path = try std.mem.concat(loop_alloc, u8, &.{ self.data_dir, "/", STATE_FILE });

        try std.fs.cwd().deleteFile(state_path);
        var manifests = self.last_sync_manifests orelse return;
        manifests.deinit();
        self.last_sync_manifests = null;
    }

    /// Sync local changes to the configured sync server
    pub fn syncLocal(self: *SyncManager, loop_alloc: std.mem.Allocator) !void {
        const state = self.state orelse return;

        const db_path = try std.mem.concat(loop_alloc, u8, &.{ self.data_dir, daemon.DB_FILE, daemon.DB_EXTENSION });
        const file = try std.fs.cwd().openFile(db_path, .{});

        const url = try std.mem.concat(loop_alloc, u8, &.{ state.value.host, "/databases/upload/", state.value.db_name });

        var compressed = std.ArrayList(u8).init(loop_alloc);

        try std.compress.gzip.compress(file.reader(), compressed.writer(), .{});

        std.log.info("Local database compressed with ratio: 1:{d:.1}", .{
            @as(f32, @floatFromInt((try file.metadata()).size())) / @as(f32, @floatFromInt(compressed.items.len)),
        });

        const res = self.client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = compressed.items,
            .extra_headers = &.{std.http.Header{ .name = "Token", .value = state.value.token }},
        }) catch |err| {
            if (!self.local_sync_queued) {
                std.log.err("Failed to upload local database, queueing upload: {}", .{err});
                // If the upload failed (e.g, machine is temporarily offline) queue the upload to make sure the changes get uploaded
                // when possible
                self.local_sync_queued = true;
            }
            return;
        };

        self.local_sync_queued = false;

        if (res.status != .ok) {
            std.log.err("Failed to upload local database: {}", .{res.status});
        }
    }

    pub fn syncPeriodic(self: *SyncManager, loop_alloc: std.mem.Allocator) !void {
        const elapsed = std.time.timestamp() - self.last_sync;
        const sync_interval = self.config.sync_interval orelse DEFAULT_SYNC_INTERVAL;

        if (elapsed >= sync_interval) {
            try self.sync(loop_alloc);
        }
    }

    pub fn sync(self: *SyncManager, loop_alloc: std.mem.Allocator) !void {
        const state = self.state orelse return;

        std.log.info("Syncing aux databases...", .{});
        if (self.local_sync_queued) {
            try self.syncLocal(loop_alloc);
        }
        self.last_sync = std.time.timestamp();

        const manifest_url = try std.mem.concat(loop_alloc, u8, &.{ state.value.host, "/databases/manifest" });

        var arena = std.heap.ArenaAllocator.init(self.allocator);

        var body = std.ArrayList(u8).init(arena.allocator());
        const res = try self.client.fetch(.{
            .location = .{ .url = manifest_url },
            .method = .GET,
            .response_storage = .{ .dynamic = &body },
            .extra_headers = &.{std.http.Header{ .name = "Token", .value = state.value.token }},
        });

        if (res.status != .ok) {
            std.log.err("Fetching database manifest failed: {}, {s}", .{ res.status, body.items });
            return;
        }

        const manifests = try std.json.parseFromSliceLeaky([]Manifest, arena.allocator(), body.items, .{});
        var databases_to_sync = std.ArrayList([]const u8).init(loop_alloc);

        // FIXME: Logic is a bit unsound when it comes to databases being deleted server-side
        // should be looked into
        for (manifests) |manifest| {
            var found = false;
            if (self.last_sync_manifests) |last_manifests| {
                for (last_manifests.value) |last_manifest| {
                    if (std.mem.eql(u8, last_manifest.name, manifest.name)) {
                        if (last_manifest.timestamp < manifest.timestamp) {
                            try databases_to_sync.append(manifest.name);
                        }
                        found = true;
                    }
                }
            }

            if (!found) {
                try databases_to_sync.append(manifest.name);
            }
        }

        for (databases_to_sync.items) |db_name| {
            if (std.mem.eql(u8, db_name, state.value.db_name)) {
                continue;
            }
            var db_body = std.ArrayList(u8).init(loop_alloc);
            const db_url = try std.mem.concat(loop_alloc, u8, &.{ state.value.host, "/databases/download/", db_name });
            const db_res = try self.client.fetch(.{
                .location = .{ .url = db_url },
                .method = .GET,
                .response_storage = .{ .dynamic = &db_body },
                .extra_headers = &.{std.http.Header{ .name = "Token", .value = state.value.token }},
            });

            const aux_dbs = try std.mem.concat(loop_alloc, u8, &.{ self.data_dir, AUX_DATABASE_PATH });
            try std.fs.cwd().makePath(aux_dbs);

            const db_path = try std.mem.concat(loop_alloc, u8, &.{ aux_dbs, "/", db_name, daemon.DB_EXTENSION });

            if (db_res.status == .gone) {
                std.log.info("Database removed from server, removing...", .{});
                std.fs.cwd().deleteFile(db_path) catch |err| {
                    if (err != error.FileNotFound) {
                        std.log.err("Unexpected I/O error occurred: {}", .{err});
                    }
                };
            } else if (db_res.status != .ok) {
                std.log.err("Error fetching aux database: {}", .{res.status});
            } else {
                var file = try std.fs.cwd().createFile(db_path, .{});

                var fbs = std.io.fixedBufferStream(db_body.items);
                var decompressed = std.ArrayList(u8).init(loop_alloc);

                try std.compress.gzip.decompress(fbs.reader(), decompressed.writer());

                try file.writeAll(decompressed.items);
            }
        }

        if (self.last_sync_manifests) |last_manifests| {
            last_manifests.deinit();
        }

        self.last_sync_manifests = .{
            .arena = arena,
            .value = manifests,
        };
    }
};
