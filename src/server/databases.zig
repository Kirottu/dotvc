const std = @import("std");
const httpz = @import("httpz");
const myzql = @import("myzql");

const root = @import("main.zig");
const auth = @import("auth.zig");

const DATA_DIR = "databases/";
const DB_EXTENSION = ".sqlite3";

pub fn manifest(app: *root.App, req: *httpz.Request, res: *httpz.Response) !void {
    const username = try auth.authenticate(app, req, res, .header) orelse {
        return;
    };

    const Record = struct {
        hostname: []const u8,
        timestamp: i64,
    };

    const stmt = try (try app.db_conn.prepare(
        res.arena,
        "SELECT hostname, UNIX_TIMESTAMP(modified) FROM db_manifests WHERE username = ?",
    )).expect(.stmt);
    const rows = try (try app.db_conn.executeRows(&stmt, .{username}))
        .expect(.rows);
    var iter = rows.iter();

    var manifests = std.ArrayList(*Record).init(res.arena);

    while (try iter.next()) |row| {
        const record = try row.structCreate(Record, res.arena);

        try manifests.append(record);
    }

    try res.json(manifests.items, .{});
}

pub fn download(app: *root.App, req: *httpz.Request, res: *httpz.Response) !void {
    const username = try auth.authenticate(app, req, res, .header) orelse {
        return;
    };
    const hostname = req.param("hostname") orelse {
        res.status = 400;
        res.body = "Missing hostname";
        return;
    };

    const db_path = try std.mem.concat(res.arena, u8, &.{ DATA_DIR, username, "/", hostname, DB_EXTENSION });

    const file = try std.fs.cwd().openFile(db_path, .{});

    const body = try res.arena.alloc(u8, (try file.metadata()).size());

    _ = try file.readAll(body);

    res.content_type = httpz.ContentType.BINARY;
    res.body = body;
}
pub fn upload(app: *root.App, req: *httpz.Request, res: *httpz.Response) !void {
    const username = try auth.authenticate(app, req, res, .header) orelse {
        return;
    };
    const hostname = req.param("hostname") orelse {
        res.status = 400;
        res.body = "Missing hostname";
        return;
    };

    const body = req.body() orelse {
        res.status = 400;
        res.body = "Missing body";
        return;
    };

    const stmt = try (try app.db_conn.prepare(
        res.arena,
        "INSERT INTO db_manifests VALUES (?, ?, NOW()) ON DUPLICATE KEY UPDATE modified = NOW()",
    )).expect(.stmt);

    _ = try (try app.db_conn.execute(&stmt, .{ username, hostname })).expect(.ok);

    const user_dir = try std.mem.concat(res.arena, u8, &.{ DATA_DIR, username });
    try std.fs.cwd().makePath(user_dir);

    const db_path = try std.mem.concat(res.arena, u8, &.{ user_dir, "/", hostname, DB_EXTENSION });

    const db_file = try std.fs.cwd().createFile(db_path, .{});

    try db_file.writeAll(body);
}

pub fn delete(app: *root.App, req: *httpz.Request, res: *httpz.Response) !void {
    _ = try auth.authenticate(app, req, res, .header) orelse {
        return;
    };
}
