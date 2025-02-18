const std = @import("std");

const root = @import("../main.zig");

const DEFAULT_SYNC_INTERVAL = 30;

pub const SyncState = struct {
    token: []const u8,
};

pub const SyncManager = struct {
    client: std.http.Client,
    hostname: []const u8,
    data_dir: []const u8,
    config: ?root.SyncConfig,
    state: ?root.ArenaAllocated(SyncState),

    last_sync: std.time.Instant,
    last_sync_manifest: std.StringHashMap(u64),

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, data_dir: []const u8, config: ?root.SyncConfig) !SyncManager {
        var hostname_buf = try allocator.alloc(u8, std.posix.HOST_NAME_MAX);
        const hostname = try std.posix.gethostname(&hostname_buf);
        hostname_buf = allocator.realloc(hostname_buf, hostname.len);

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
            try file.readAll(buf);

            const state = try std.json.parseFromSliceLeaky(SyncState, alloc, buf, .{});
            break :blk .{
                .arena = arena,
                .value = state,
            };
        } else null;

        return SyncManager{
            .client = client,
            .hostname = hostname_buf,
            .data_dir = data_dir,
            .config = config,
            .state = state,
            .last_sync = try std.time.Instant.now(),
            .last_sync_manifest = std.StringHashMap(u64).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SyncManager) void {
        self.allocator.free(self.hostname);
        self.last_sync_manifest.deinit();
        self.client.deinit();
        if (self.state) |state| {
            state.deinit();
        }
    }

    /// Authenticate sync with a token
    pub fn authenticate(self: *SyncManager, token: []const u8) !void {
        if (self.state) |state| {
            state.arena.reset(.retain_capacity);
            state.value.token = state.arena.allocator().alloc(u8, token.len);
            @memcpy(state.value.token, token);
        } else {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            const state = SyncState{
                .token = arena.allocator().alloc(u8, token.len),
            };

            self.state = .{
                .arena = arena,
                .value = state,
            };
        }
    }

    // FIXME: Bad name, should reflect the periodical function of this function
    pub fn sync(self: *SyncManager, loop_alloc: std.mem.Allocator) !void {
        const elapsed = (try std.time.Instant.now()).since(self.last_sync);
        const sync_interval = self.config.sync_interval orelse DEFAULT_SYNC_INTERVAL;

        if (elapsed > sync_interval * std.time.ns_per_s and self.state) |state| {
            self.last_sync = try std.time.Instant.now();

            const manifest_url = try std.mem.concat(loop_alloc, u8, &.{ self.config.host, "/databases/manifest" });

            var body = std.ArrayList(u8).init(loop_alloc);
            const res = try self.client.fetch(.{
                .location = .{ .url = manifest_url },
                .method = .GET,
                .response_storage = .{ .dynamic = &body },
                .extra_headers = &.{std.http.Header{ .name = "Token", .value = state.token }}, // FIXME: Storage of auth token
            });

            if (res.status != std.http.Status.ok) {
                std.log.err("Fetching database manifest failed: {}", .{res.status});
            }
        }
    }
};
