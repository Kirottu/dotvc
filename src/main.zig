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
};

pub const WatchPath = struct {
    path: []const u8,
    tags: [][]const u8,
    ignore: ?[][]const u8,
};

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const deinit_status = gpa.deinit();
        if (deinit_status == .leak) {
            std.log.err("memory leak", .{});
        }
    }
    const allocator = gpa.allocator();

    var app = yazap.App.init(allocator, "dotvc", "Version control for your dotfiles");
    defer app.deinit();

    var cli = app.rootCommand();
    try cli.addArg(yazap.Arg.singleValueOption("config", 'c', "Override config file location"));

    const search = app.createCommand("interactive", "Interactively search for dotfiles");
    var daemon_cli = app.createCommand("daemon", "Run the dotvc daemon");
    try daemon_cli.addArg(yazap.Arg.singleValueOption("data-dir", 'd', "Override the default directory where the database is stored"));

    try cli.addSubcommands(&[_]yazap.Command{ search, daemon_cli });

    const matches = try app.parseProcess();

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
        try client.run(allocator, matches);
    }
    return 0;
}
