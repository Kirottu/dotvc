const std = @import("std");
const httpz = @import("httpz");
const myzql = @import("myzql");

const root = @import("main.zig");
const auth = @import("auth.zig");

const DATA_DIR = "databases/";
const DB_EXTENSION = ".sqlite3";
/// Characters forbidden from DB names, to prevent arbitrary filesystem access
const FORBIDDEN_CHARS = "/.";

pub fn manifest(app: *root.App, req: *httpz.Request, res: *httpz.Response) !void {
    const username = try auth.authenticate(app, req, res, .header) orelse {
        return;
    };

    const Record = struct {
        name: []const u8,
        timestamp: i64,
    };

    const rows = try (try app.db_conn.executeRows(&app.stmts.sel_manifests, .{username}))
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
    const db_name = req.param("name") orelse {
        res.status = 400;
        res.body = "Missing database name";
        return;
    };
    if (!checkName(db_name, res)) {
        return;
    }

    const db_path = try std.mem.concat(res.arena, u8, &.{ DATA_DIR, username, "/", db_name, DB_EXTENSION });

    const file = std.fs.cwd().openFile(db_path, .{}) catch |err| {
        if (err == error.FileNotFound) {
            res.status = 410;
            res.body = "Database does not exist on server";
        } else {
            res.status = 500;
            res.body = "Unknown error opening file";
        }
        return;
    };

    var body = std.ArrayList(u8).init(res.arena);
    try std.compress.gzip.compress(file.reader(), body.writer(), .{});

    res.content_type = httpz.ContentType.BINARY;
    res.body = body.items;
}

pub fn upload(app: *root.App, req: *httpz.Request, res: *httpz.Response) !void {
    const username = try auth.authenticate(app, req, res, .header) orelse {
        return;
    };
    const db_name = req.param("name") orelse {
        res.status = 400;
        res.body = "Missing database name";
        return;
    };
    if (!checkName(db_name, res)) {
        return;
    }

    const body = req.body() orelse {
        res.status = 400;
        res.body = "Missing body";
        return;
    };
    var fbs = std.io.fixedBufferStream(body);
    var decompressed = std.ArrayList(u8).init(res.arena);

    try std.compress.gzip.decompress(fbs.reader(), decompressed.writer());

    _ = try (try app.db_conn.execute(&app.stmts.ins_or_upd_manifest, .{ username, db_name })).expect(.ok);

    const user_dir = try std.mem.concat(res.arena, u8, &.{ DATA_DIR, username });
    try std.fs.cwd().makePath(user_dir);

    const db_path = try std.mem.concat(res.arena, u8, &.{ user_dir, "/", db_name, DB_EXTENSION });

    const db_file = try std.fs.cwd().createFile(db_path, .{});

    try db_file.writeAll(decompressed.items);
}

pub fn delete(app: *root.App, req: *httpz.Request, res: *httpz.Response) !void {
    const username = try auth.authenticate(app, req, res, .header) orelse {
        return;
    };
    const db_name = req.param("name") orelse {
        res.status = 400;
        res.body = "Missing database name";
        return;
    };
    if (!checkName(db_name, res)) {
        return;
    }

    _ = try (try app.db_conn.execute(&app.stmts.del_manifest, .{ username, db_name })).expect(.ok);

    const db_path = try std.mem.concat(res.arena, u8, &.{ DATA_DIR, username, "/", db_name, DB_EXTENSION });

    std.fs.cwd().deleteFile(db_path) catch {};
}

fn checkName(name: []const u8, res: *httpz.Response) bool {
    for (FORBIDDEN_CHARS) |chr| {
        if (std.mem.containsAtLeast(u8, name, 1, &.{chr})) {
            res.status = 400;
            res.body = "Invalid characters in database name";
            return false;
        }
    }

    return true;
}
