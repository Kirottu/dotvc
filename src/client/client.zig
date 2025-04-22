const std = @import("std");
const toml = @import("zig-toml");
const yazap = @import("yazap");
const root = @import("../main.zig");
const ipc = @import("../daemon/ipc.zig");
const search = @import("search.zig");
const sync = @import("sync.zig");

pub const ANSI_BOLD = "\x1B[1m";
pub const ANSI_UL = "\x1B[4m";
pub const ANSI_RESET = "\x1B[0m";

pub const ANSI_GREEN = "\x1B[32m";
pub const ANSI_RED = "\x1B[31m";

pub fn prompt(allocator: std.mem.Allocator, hide_input: bool, comptime fmt: []const u8, args: anytype) ![]u8 {
    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();

    try stdout.print(fmt, args);

    const termios = try std.posix.tcgetattr(std.posix.STDOUT_FILENO);
    if (hide_input) {
        var t = termios;

        // Disable echoing to hide password as it is being typed
        t.lflag.ECHO = false;

        try std.posix.tcsetattr(std.posix.STDOUT_FILENO, std.posix.TCSA.NOW, t);
    }

    const out = try stdin.readUntilDelimiterOrEofAlloc(allocator, '\n', 255) orelse {
        try stdout.print("{s}Invalid input{s}\n", .{ ANSI_RED, ANSI_RESET });
        std.process.exit(1);
    };

    if (hide_input) {
        try std.posix.tcsetattr(std.posix.STDOUT_FILENO, std.posix.TCSA.NOW, termios);
        try stdout.print("\n", .{});
    }

    return out;
}

pub fn ipcMessage(allocator: std.mem.Allocator, socket: std.posix.socket_t, msg: ipc.IpcMsg) !root.ArenaAllocated(ipc.IpcResponse) {
    // Data is read from the sockets in chunks of this size
    const read_chunk = 16384;

    var arena = std.heap.ArenaAllocator.init(allocator);
    const arena_alloc = arena.allocator();
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    try std.json.stringify(msg, .{}, buf.writer());
    try buf.append('\n');

    _ = try std.posix.send(socket, buf.items, 0);

    var read_buf = try arena_alloc.alloc(u8, read_chunk);

    var offset: usize = 0;
    while (true) {
        const read = try std.posix.recv(socket, read_buf[offset..], 0);
        offset += read;
        if (read == read_chunk) {
            read_buf = try arena_alloc.realloc(read_buf, read_buf.len + read_chunk);
        } else {
            break;
        }
    }

    return .{
        .arena = arena,
        .value = try std.json.parseFromSliceLeaky(ipc.IpcResponse, arena_alloc, read_buf[0 .. offset - 1], .{}),
    };
}

/// Run the client
pub fn run(allocator: std.mem.Allocator, matches: yazap.ArgMatches, config_path: []const u8) !void {
    var parser = toml.Parser(root.Config).init(allocator);
    defer parser.deinit();

    var result = try parser.parseFile(config_path);
    defer result.deinit();

    const config = result.value;

    const socket = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    const addr = try std.net.Address.initUnix(ipc.SOCKET_PATH);
    std.posix.connect(socket, &addr.any, addr.getOsSockLen()) catch |err| {
        const stdout = std.io.getStdOut().writer();

        try stdout.print(
            "{s}{s}Failed to connect to daemon!{s}: {}\n\nIs the daemon running?\n",
            .{ ANSI_RED, ANSI_BOLD, ANSI_RESET, err },
        );
        return;
    };

    if (matches.subcommandMatches("search")) |search_matches| {
        var state = search.State.init(allocator, socket, config, search_matches.getSingleValue("database")) catch |err| {
            std.log.err("{}", .{err});
            if (err == search.SearchError.InvalidDatabase) {
                std.log.err("Invalid database name specified.", .{});
            }
            return;
        };
        defer state.deinit();

        try state.run();
    } else if (matches.subcommandMatches("kill")) |_| {
        const res = try ipcMessage(allocator, socket, ipc.IpcMsg{ .shutdown = .{} });
        res.deinit();
    } else if (matches.subcommandMatches("sync")) |sync_cli| {
        try sync.syncCli(allocator, socket, sync_cli);
    } else if (matches.subcommandMatches("index")) |_| {
        const res = try prompt(allocator, false, "This will create a new database entry for each configured config file, are you sure? [y/N]: ", .{});
        defer allocator.free(res);

        if (res.len == 1 and (res[0] == 'y' or res[0] == 'Y')) {
            _ = try ipcMessage(allocator, socket, .{ .index_all = .{} });
        }
    }
}
