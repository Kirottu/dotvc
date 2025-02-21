const std = @import("std");

const root = @import("../main.zig");
const daemon = @import("daemon.zig");

// FIXME: Needs a more sensible value for the actual default
const DEFAULT_SYNC_INTERVAL = 10;
pub const AUX_DATABASE_PATH = "/sync_databases";
const STATE_FILE = "sync_state.json";

pub const SyncState = struct {
    token: []u8,
    username: []u8,
    host: []u8,
};

pub const Manifest = struct {
    hostname: []const u8,
    timestamp: i64,
};

pub const SyncManager = struct {
    client: std.http.Client,
    hostname: []const u8,
    data_dir: []const u8,
    config: *root.Config,
    state: ?root.ArenaAllocated(SyncState),

    last_sync: i64 = 0,
    last_sync_manifests: ?root.ArenaAllocated([]Manifest) = null,

    local_sync_queued: bool = false,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, data_dir: []const u8, config: *root.Config) !SyncManager {
        var hostname_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
        const hostname = try std.posix.gethostname(&hostname_buf);
        const hostname_alloc = try allocator.alloc(u8, hostname.len);
        @memcpy(hostname_alloc, hostname);

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
            .hostname = hostname_alloc,
            .data_dir = data_dir,
            .config = config,
            .state = state,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SyncManager) void {
        self.allocator.free(self.hostname);
        self.last_sync_manifests.deinit();
        self.client.deinit();
        self.state.deinit();
    }

    /// Authenticate sync with a state
    pub fn authenticate(self: *SyncManager, loop_alloc: std.mem.Allocator, new_state: SyncState) !void {
        if (self.state) |*state| {
            _ = state.arena.reset(.retain_capacity);
            state.value.token = try state.arena.allocator().alloc(u8, new_state.token.len);
            state.value.host = try state.arena.allocator().alloc(u8, new_state.host.len);
            @memcpy(state.value.token, new_state.token);
            @memcpy(state.value.host, new_state.host);
        } else {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            const state = SyncState{
                .token = try arena.allocator().alloc(u8, new_state.token.len),
                .host = try arena.allocator().alloc(u8, new_state.host.len),
            };

            @memcpy(state.token, new_state.token);
            @memcpy(state.host, new_state.host);
            self.state = .{
                .arena = arena,
                .value = state,
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
        const url = try std.mem.concat(loop_alloc, u8, &.{ state.value.host, "/databases/delete/", self.hostname });

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

        // FIXME: Needs to also delete the synced aux databases

        try self.deauthenticate(loop_alloc);
    }

    pub fn deauthenticate(self: *SyncManager, loop_alloc: std.mem.Allocator) !void {
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

        const url = try std.mem.concat(loop_alloc, u8, &.{ state.value.host, "/databases/upload/", self.hostname });

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
        const state = self.state orelse return;
        const sync_interval = self.config.sync_interval orelse DEFAULT_SYNC_INTERVAL;

        if (elapsed >= sync_interval) {
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
                        if (std.mem.eql(u8, last_manifest.hostname, manifest.hostname)) {
                            if (last_manifest.timestamp < manifest.timestamp) {
                                try databases_to_sync.append(manifest.hostname);
                            }
                            found = true;
                        }
                    }
                }

                if (!found) {
                    try databases_to_sync.append(manifest.hostname);
                }
            }

            for (databases_to_sync.items) |hostname| {
                if (std.mem.eql(u8, hostname, self.hostname)) {
                    continue;
                }
                var db_body = std.ArrayList(u8).init(loop_alloc);
                const db_url = try std.mem.concat(loop_alloc, u8, &.{ state.value.host, "/databases/download/", hostname });
                const db_res = try self.client.fetch(.{
                    .location = .{ .url = db_url },
                    .method = .GET,
                    .response_storage = .{ .dynamic = &db_body },
                    .extra_headers = &.{std.http.Header{ .name = "Token", .value = state.value.token }},
                });

                const aux_dbs = try std.mem.concat(loop_alloc, u8, &.{ self.data_dir, AUX_DATABASE_PATH });
                try std.fs.cwd().makePath(aux_dbs);

                const db_path = try std.mem.concat(loop_alloc, u8, &.{ aux_dbs, "/", hostname, daemon.DB_EXTENSION });

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
    }
};
