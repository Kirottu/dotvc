const std = @import("std");
const toml = @import("zig-toml");
const yazap = @import("yazap");
const root = @import("../main.zig");
const ipc = @import("../daemon/ipc.zig");
const sync = @import("../daemon/sync.zig");
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
    } else if (matches.subcommandMatches("auth")) |_| {
        const stdin = std.io.getStdIn().reader();
        const stdout = std.io.getStdOut().writer();

        try stdout.print("DotVC Sync host: ", .{});

        const host = try stdin.readUntilDelimiterOrEofAlloc(allocator, '\n', 255) orelse {
            std.log.err("Invalid host input", .{});
            return;
        };
        defer allocator.free(host);

        try stdout.print("Username: ", .{});
        const username = try stdin.readUntilDelimiterOrEofAlloc(allocator, '\n', 255) orelse {
            std.log.err("Invalid username input", .{});
            return;
        };
        defer allocator.free(username);

        try stdout.print("Password: ", .{});
        const password = try stdin.readUntilDelimiterOrEofAlloc(allocator, '\n', 255) orelse {
            std.log.err("Invalid username input", .{});
            return;
        };
        defer allocator.free(password);

        const url = try std.mem.concat(allocator, u8, &.{ host, "/auth/token" });
        const credentials = try std.mem.concat(allocator, u8, &.{ username, ":", password });

        const encoder = std.base64.standard.Encoder;
        const credentials_buf = try allocator.alloc(u8, encoder.calcSize(credentials.len));
        const credentials_base64 = encoder.encode(credentials_buf, credentials);
        const auth_header = try std.mem.concat(allocator, u8, &.{ "Basic: ", credentials_base64 });

        defer allocator.free(url);
        defer allocator.free(credentials);
        defer allocator.free(credentials_buf);
        defer allocator.free(auth_header);

        var client = std.http.Client{ .allocator = allocator };
        var body = std.ArrayList(u8).init(allocator);

        defer client.deinit();
        defer body.deinit();

        const res = try client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .response_storage = .{ .dynamic = &body },
            .extra_headers = &.{std.http.Header{ .name = "Authorization", .value = auth_header }},
        });

        if (res.status != .ok) {
            std.log.err("Server responded with a non-ok response: {}, {s}", .{ res.status, body.items });
            return;
        }

        _ = try ipcMessage(allocator, socket, .{ .authenticate = sync.SyncState{
            .token = body.items,
            .host = host,
        } });

        try stdout.print("Successfully authenticated to host!", .{});
    }
}
