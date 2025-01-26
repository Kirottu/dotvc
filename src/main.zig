const std = @import("std");
const sqlite = @import("sqlite");
const yazap = @import("yazap");
const inotify_c = @cImport(@cInclude("sys/inotify.h"));

const db_schema = @embedFile("res/schema.sql");

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var app = yazap.App.init(allocator, "dotvc", "Version control for your dotfiles");
    defer app.deinit();

    var cli = app.rootCommand();
    var daemon = app.createCommand("daemon", "Run the dotvc daemon");
    try daemon.addArg(yazap.Arg.singleValueOption("database", 'd', "Override the default database file path"));

    try cli.addSubcommand(daemon);

    const matches = try app.parseProcess();
    if (matches.subcommandMatches("daemon")) |daemon_match| {
        const db_path = if (daemon_match.getSingleValue("database")) |path| path else dir: {
            const data_dir_postfix = "/dotvc/database.db";

            if (std.posix.getenv("XDG_DATA_HOME")) |data_home| {
                const buf = try allocator.alloc(u8, data_dir_postfix.len + data_home.len);
                _ = try std.fmt.bufPrint(buf, "{s}{s}", .{ data_home, data_dir_postfix });
                break :dir buf;
            }

            if (std.posix.getenv("HOME")) |home| {
                const data_dir = "/.local/share";
                const buf = try allocator.alloc(u8, home.len + data_dir.len + data_dir_postfix.len);
                _ = try std.fmt.bufPrint(buf, "{s}{s}{s}", .{ home, data_dir, data_dir_postfix });
                break :dir buf;
            }

            std.log.err("Unable to determine data directory", .{});
            return 1;
        };

        // Create the path up until the data directory
        var it = std.mem.splitBackwardsScalar(u8, db_path, '/');
        const data_dir = if (it.next()) |filename| db_path[0 .. db_path.len - filename.len] else unreachable;

        std.fs.cwd().makePath(data_dir) catch |err| {
            std.log.err("Failed to create dotvc data directory {s}: {}", .{ data_dir, err });
        };
        // Add 0-sentinel termination as SQlite expects that
        const sentinel_db_path = try allocator.allocSentinel(u8, db_path.len, 0);
        std.mem.copyForwards(u8, sentinel_db_path, db_path);

        var db = try sqlite.Db.init(.{
            .mode = sqlite.Db.Mode{ .File = sentinel_db_path },
            .open_flags = .{
                .write = true,
                .create = true,
            },
        });
        defer db.deinit();

        const inotify_fd = try std.posix.inotify_init1(0);
        _ = try std.posix.inotify_add_watch(inotify_fd, data_dir, inotify_c.IN_ALL_EVENTS);
        const buf = try allocator.alloc(u8, 1024);
        const event_size = @sizeOf(std.os.linux.inotify_event);

        while (true) {
            const read = try std.posix.read(inotify_fd, buf);
            const n_events = read / event_size;
            std.log.info("Read {} bytes from inotify, {} events", .{ read, n_events });

            for (0..n_events) |i| {
                const offset = i * event_size;
                const event: *align(4) std.os.linux.inotify_event = @alignCast(std.mem.bytesAsValue(std.os.linux.inotify_event, buf[offset .. offset + event_size]));
                std.log.info("Path {?s}, event: {}", .{ event.getName(), event });
            }
        }
    }

    return 0;
}
