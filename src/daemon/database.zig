const std = @import("std");
const sqlite = @import("sqlite");

pub const Dotfile = struct {
    path: []const u8,
    content: []const u8,
    tags: [][]const u8,
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
        // TODO: Maybe cache statements?
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
        }
    }

    pub fn deinit(self: *Database) void {
        self.db.deinit();
    }
};
