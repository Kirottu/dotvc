const std = @import("std");

const root = @import("../main.zig");
const daemon = @import("daemon.zig");

const DEFAULT_SYNC_INTERVAL = 10;
pub const AUX_DATABASE_PATH = "/sync_databases";

pub const SyncState = struct {
    token: []u8,
    host: []u8,
};

const Manifest = struct {
    hostname: []const u8,
    timestamp: i64,
};

pub const SyncManager = struct {
    client: std.http.Client,
    hostname: []const u8,
    data_dir: []const u8,
    config: *root.Config,
    state: ?root.ArenaAllocated(SyncState),

    last_sync: std.time.Instant,
    last_sync_manifests: ?root.ArenaAllocated([]Manifest),

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, data_dir: []const u8, config: *root.Config) !SyncManager {
        var hostname_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
        const hostname = try std.posix.gethostname(&hostname_buf);
        const hostname_alloc = try allocator.alloc(u8, hostname.len);
        @memcpy(hostname_alloc, hostname);

        const client = std.http.Client{ .allocator = allocator };

        const state_path = try std.mem.concat(allocator, u8, &.{ data_dir, "/sync_state.json" });
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
            .last_sync = try std.time.Instant.now(),
            .last_sync_manifests = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SyncManager) void {
        self.allocator.free(self.hostname);
        self.last_sync_manifests.deinit();
        self.client.deinit();
        self.state.deinit();
    }

    /// Authenticate sync with a token
    pub fn authenticate(self: *SyncManager, new_state: SyncState) !void {
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
    }

    // FIXME: Bad name, should reflect the periodical function of this function
    pub fn sync(self: *SyncManager, loop_alloc: std.mem.Allocator) !void {
        const elapsed = (try std.time.Instant.now()).since(self.last_sync);
        const state = self.state orelse return;
        const sync_interval = self.config.sync_interval orelse DEFAULT_SYNC_INTERVAL;

        if (elapsed > sync_interval * std.time.ns_per_s) {
            std.log.info("Syncing aux databases...", .{});
            self.last_sync = try std.time.Instant.now();

            const manifest_url = try std.mem.concat(loop_alloc, u8, &.{ state.value.host, "/databases/manifest" });

            var arena = std.heap.ArenaAllocator.init(self.allocator);

            var body = std.ArrayList(u8).init(arena.allocator());
            const res = try self.client.fetch(.{
                .location = .{ .url = manifest_url },
                .method = .GET,
                .response_storage = .{ .dynamic = &body },
                .extra_headers = &.{std.http.Header{ .name = "Token", .value = state.value.token }}, // FIXME: Storage of auth token
            });

            if (res.status != .ok) {
                std.log.err("Fetching database manifest failed: {}", .{res.status});
                return;
            }

            const manifests = try std.json.parseFromSliceLeaky([]Manifest, arena.allocator(), body.items, .{});
            var databases_to_sync = std.ArrayList([]const u8).init(loop_alloc);

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
                    std.log.info("Database removed from server, removing...");
                    try std.fs.cwd().deleteFile(db_path);
                } else if (db_res.status != .ok) {
                    std.log.err("Error fetching aux database: {}", .{res.status});
                } else {
                    var file = try std.fs.cwd().createFile(db_path, .{});

                    try file.writeAll(db_body.items);
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
