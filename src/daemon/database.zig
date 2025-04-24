const std = @import("std");
const sqlite = @import("sqlite");

const ipc = @import("ipc.zig");
const root = @import("../main.zig");

pub const Dotfile = struct {
    path: []const u8,
    content: []const u8,
    tags: [][]const u8,
    date: i64,
};

/// Helper struct for pulling data out of the database
const DbDotfile = struct {
    id: i64,
    path: []const u8,
    content: []const u8,
    date: i64,
};

pub const Database = struct {
    db: sqlite.Db,
    allocator: std.mem.Allocator,
    readonly: bool,

    pub fn init(allocator: std.mem.Allocator, path: []const u8, readonly: bool) !Database {
        // Add 0-sentinel termination as SQlite expects that
        const path_sentinel = try allocator.alloc(u8, path.len + 1);
        defer allocator.free(path_sentinel);

        path_sentinel[path.len] = 0;
        std.mem.copyForwards(u8, path_sentinel, path);
        const mode = sqlite.Db.Mode{ .File = path_sentinel[0 .. path_sentinel.len - 1 :0] };

        const db = sqlite.Db.init(.{
            .mode = mode,
            .open_flags = .{
                .write = !readonly,
                .create = false,
            },
        }) catch |err| blk: {
            // If opening in write mode (aka using database designated to current host), if the DB does not exist
            // create it and initialize it with the DB schema.
            if (err == error.SQLiteCantOpen and !readonly) {
                var db = try sqlite.Db.init(.{ .mode = mode, .open_flags = .{
                    .write = true,
                    .create = true,
                } });

                var dotfiles = try db.prepare(
                    \\CREATE TABLE dotfiles(
                    \\    id INTEGER PRIMARY KEY,
                    \\    path TEXT NOT NULL,
                    \\    content TEXT NOT NULL,
                    \\    date BIGINT NOT NULL
                    \\);
                );
                var tags = try db.prepare(
                    \\CREATE TABLE tags(
                    \\    dotfile_id INTEGER NOT NULL,
                    \\    name VARCHAR(20) NOT NULL,
                    \\    FOREIGN KEY(dotfile_id) REFERENCES dotfiles(id),
                    \\    PRIMARY KEY(name, dotfile_id)
                    \\);
                );
                defer tags.deinit();
                defer dotfiles.deinit();

                try tags.exec(.{}, .{});
                try dotfiles.exec(.{}, .{});

                break :blk db;
            } else {
                return err;
            }
        };

        return Database{
            .db = db,
            .allocator = allocator,
            .readonly = readonly,
        };
    }

    pub fn addDotfile(self: *Database, dotfile: Dotfile) !void {
        var insert_dotfile = try self.db.prepare(
            \\INSERT INTO dotfiles(path, content, date) VALUES(?, ?, ?);
        );
        defer insert_dotfile.deinit();
        try insert_dotfile.exec(.{}, .{
            .path = dotfile.path,
            .content = dotfile.content,
            .date = dotfile.date,
        });
        const id = self.db.getLastInsertRowID();
        var insert_tag = try self.db.prepare(
            \\INSERT INTO tags(dotfile_id, name) VALUES(?, ?);  
        );
        defer insert_tag.deinit();

        for (dotfile.tags) |tag| {
            try insert_tag.exec(.{}, .{ .dotfile_id = id, .name = tag });
            insert_tag.reset();
        }
    }

    /// Get all dotfiles from the database in a distilled form (content omitted)
    pub fn getDotfiles(self: *Database, loop_alloc: std.mem.Allocator) ![]struct { Dotfile, i64 } {
        var get_dotfiles = try self.db.prepare(
            \\SELECT * FROM dotfiles;
        );
        var get_tags = try self.db.prepare(
            \\SELECT (name) FROM tags WHERE dotfile_id = ?;
        );
        defer get_dotfiles.deinit();
        defer get_tags.deinit();
        const dotfiles = try get_dotfiles.all(DbDotfile, loop_alloc, .{}, .{});

        const dotfile_buf = try loop_alloc.alloc(struct { Dotfile, i64 }, dotfiles.len);

        for (0.., dotfiles) |i, db_dotfile| {
            get_tags.reset();
            const tags = try get_tags.all([]const u8, loop_alloc, .{}, .{ .dotfile_id = db_dotfile.id });
            dotfile_buf[i] = .{
                Dotfile{
                    .path = db_dotfile.path,
                    .content = db_dotfile.content,
                    .tags = tags,
                    .date = db_dotfile.date,
                },
                db_dotfile.id,
            };
        }

        return dotfile_buf;
    }

    /// Get a single dotfile from the database
    pub fn getDotfile(self: *Database, loop_alloc: std.mem.Allocator, rowid: i64) !Dotfile {
        var get_dotfile = try self.db.prepare(
            \\SELECT * FROM dotfiles WHERE id = ?;
        );
        var get_tags = try self.db.prepare(
            \\SELECT (name) FROM tags WHERE dotfile_id = ?;
        );
        defer get_dotfile.deinit();
        defer get_tags.deinit();

        const dotfile = (try get_dotfile.oneAlloc(DbDotfile, loop_alloc, .{}, .{ .id = rowid })) orelse unreachable;
        const tags = try get_tags.all([]const u8, loop_alloc, .{}, .{ .dotfile_id = rowid });

        return Dotfile{
            .path = dotfile.path,
            .content = dotfile.content,
            .tags = tags,
            .date = dotfile.date,
        };
    }

    pub fn deinit(self: *Database) void {
        self.db.deinit();
    }
};
