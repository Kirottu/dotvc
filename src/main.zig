const std = @import("std");
const sqlite = @import("sqlite");
const yazap = @import("yazap");
const toml = @import("zig-toml");
const daemon = @import("daemon/daemon.zig");
const client = @import("client/client.zig");

// Recurse all tests from all files in the project
comptime {
    std.testing.refAllDecls(daemon);
}

pub const Config = struct {
    editor: []const u8,
    global_ignore: [][]const u8,
    watch_paths: []const WatchPath,
    sync_interval: ?u64,
};

pub const WatchPath = struct {
    path: []const u8,
    tags: [][]const u8,
    ignore: ?[][]const u8,
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

    var app = yazap.App.init(allocator, "dotvc", "Version control for your dotfiles");
    defer app.deinit();

    var cli = app.rootCommand();
    cli.setProperty(.subcommand_required);
    try cli.addArg(yazap.Arg.singleValueOption("config", 'c', "Override config file location"));
    try cli.addArg(yazap.Arg.booleanOption("log-leaks", null, "Debugging option, log memory leaks on exit"));

    var search_cli = app.createCommand("search", "Interactively search for dotfiles");
    try search_cli.addArg(yazap.Arg.singleValueOption("database", 'd', "Specify which database to use, hostnames are used as database names"));

    const reload_cli = app.createCommand("reload", "Reload daemon configuration");

    var sync_cli = app.createCommand("sync", "Manage DotVC Sync connection");
    const index_cli = app.createCommand("index", "Create new revisions for all watch paths in the database");
    sync_cli.setProperty(.subcommand_required);
    {
        const login_cli = app.createCommand("login", "Login to a DotVC Sync server with an existing user");
        const logout_cli = app.createCommand("logout", "Logout from DotVC Sync. Data will not be delete from the server");
        const register_cli = app.createCommand("register", "Create a new user on a DotVC Sync server, and log in");
        const unregister_cli = app.createCommand("delete-account", "Delete account and all data associated with it");
        const purge_cli = app.createCommand("purge", "Delete all data related to the current system from the sync server");
        const status_cli = app.createCommand("status", "View sync status");
        const now_cli = app.createCommand("now", "Sync remote databases now");

        try sync_cli.addSubcommands(&.{ login_cli, logout_cli, register_cli, unregister_cli, purge_cli, status_cli, now_cli });
    }

    const kill_cli = app.createCommand("kill", "Gracefully shutdown the daemon");

    var daemon_cli = app.createCommand("daemon", "Run the dotvc daemon");
    try daemon_cli.addArg(yazap.Arg.singleValueOption("data-dir", 'd', "Override the default directory where the database is stored"));

    try cli.addSubcommands(&.{ daemon_cli, search_cli, reload_cli, kill_cli, sync_cli, index_cli });

    const matches = app.parseProcess() catch {
        return 1;
    };
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
