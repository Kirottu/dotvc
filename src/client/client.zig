const std = @import("std");
const toml = @import("zig-toml");
const yazap = @import("yazap");
const root = @import("../main.zig");
const ipc = @import("../daemon/ipc.zig");
const search = @import("search.zig");

pub fn ipcMessage(allocator: std.mem.Allocator, socket: std.posix.socket_t, msg: ipc.IpcMsg) !root.ArenaAllocated(ipc.IpcResponse) {
    var arena = std.heap.ArenaAllocator.init(allocator);
    const arena_alloc = arena.allocator();
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    try std.json.stringify(msg, .{}, buf.writer());
    try buf.append('\n');

    _ = try std.posix.send(socket, buf.items, 0);

    var read_buf = try arena_alloc.alloc(u8, 2048);

    var offset: usize = 0;
    while (true) {
        const read = try std.posix.recv(socket, read_buf[offset..], 0);
        offset += read;
        if (read == read_buf.len) {
            read_buf = try arena_alloc.realloc(read_buf, read_buf.len + 2048);
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
    try std.posix.connect(socket, &addr.any, addr.getOsSockLen());

    if (matches.subcommandMatches("search")) |search_matches| {
        var state = search.State.init(allocator, socket, config, search_matches.getSingleValue("database")) catch |err| {
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
    } else if (matches.subcommandMatches("sync")) |sync_cli| {}
}
