const std = @import("std");
const sqlite = @import("sqlite");
const yazap = @import("yazap");
const toml = @import("zig-toml");
const daemon = @import("daemon/daemon.zig");
const client = @import("client/client.zig");

// Recurse all tests from all files in the project
comptime {
    std.testing.refAllDeclsRecursive(@This());
}

pub const Config = struct {
    editor: []const u8,
    global_ignore: [][]const u8,
    watch_paths: []const WatchPath,
    sync: ?SyncConfig,
};

pub const WatchPath = struct {
    path: []const u8,
    tags: [][]const u8,
    ignore: ?[][]const u8,
};

pub const SyncConfig = struct {
    host: []const u8,
    sync_interval: ?u64,
};

pub fn ArenaAllocated(comptime T: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        value: T,

        pub fn deinit(self: @This()) void {
            self.arena.deinit();
        }
    };
}

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var app = yazap.App.init(allocator, "DotVC", "Version control for your dotfiles");
    defer app.deinit();

    var cli = app.rootCommand();
    try cli.addArg(yazap.Arg.singleValueOption("config", 'c', "Override config file location"));
    try cli.addArg(yazap.Arg.booleanOption("log-leaks", null, "Debugging option, log memory leaks on exit"));

    var search = app.createCommand("search", "Interactively search for dotfiles");
    try search.addArg(yazap.Arg.singleValueOption("database", 'd', "Specify which database to use, hostnames are used as database names"));

    const kill = app.createCommand("kill", "Gracefully shutdown the daemon");
    var add = app.createCommand("add", "Add a path to the configuration");
    try add.addArgs(&.{
        yazap.Arg.positional("path", "The target path", null),
        yazap.Arg.multiValuesOption("tags", 't', "Tags for all dotfiles in the target path", 10),
        yazap.Arg.multiValuesOption("ignore", 'i', "Ignore patterns for path contents if target path is a directory", 10),
    });

    var daemon_cli = app.createCommand("daemon", "Run the dotvc daemon");
    try daemon_cli.addArg(yazap.Arg.singleValueOption("data-dir", 'd', "Override the default directory where the database is stored"));

    try cli.addSubcommands(&[_]yazap.Command{ search, kill, daemon_cli });

    const matches = try app.parseProcess();
    const log_leaks = matches.containsArg("log-leaks");
    const config_path = if (matches.getSingleValue("config")) |path| path else dir: {
        const config_dir_postfix = "/dotvc/config.toml";

        if (std.posix.getenv("XDG_CONFIG_HOME")) |data_home| {
            break :dir try std.mem.concat(
                allocator,
                u8,
                &[_][]const u8{ data_home, config_dir_postfix },
            );
        }

        if (std.posix.getenv("HOME")) |home| {
            break :dir try std.mem.concat(
                allocator,
                u8,
                &[_][]const u8{ home, "/.config", config_dir_postfix },
            );
        }

        std.log.err("Unable to determine config file location", .{});
        return 1;
    };

    if (matches.subcommandMatches("daemon")) |daemon_match| {
        const data_dir = daemon_match.getSingleValue("data-dir");
        try daemon.run(allocator, config_path, data_dir);
    } else {
        try client.run(allocator, matches, config_path);
    }

    if (log_leaks) {
        _ = gpa.detectLeaks();
    }

    return 0;
}
