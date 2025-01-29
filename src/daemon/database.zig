const std = @import("std");
const sqlite = @import("sqlite");

const DB_SCHEMA = @embedFile("res/schema.sql");

pub const Database = struct {
    db: sqlite.Db,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !Database {
        // Add 0-sentinel termination as SQlite expects that
        const path_sentinel: [:0]u8 = @ptrCast(try allocator.alloc(u8, path.len + 1));
        defer allocator.free(path_sentinel);

        path_sentinel[path.len] = 0;
        @memcpy(path_sentinel, path);

        const db = sqlite.Db.init(.{
            .mode = sqlite.Db.Mode{ .File = path_sentinel },
            .open_flags = .{
                .write = true,
                .create = false,
            },
        }) catch |err| {
            std.log.err("{}", .{err});
            return err;
        };

        return Database{
            .db = db,
            .allocator = allocator,
        };
    }
};
