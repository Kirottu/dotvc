const std = @import("std");
const yazap = @import("yazap");

const client = @import("client.zig");
const sync = @import("../daemon/sync.zig");

const termios_c = @cImport(@cInclude("termios.h"));

const ANSI_BOLD = "\x1B[1m";
const ANSI_UL = "\x1B[4m";
const ANSI_RESET = "\x1B[0m";

const ANSI_GREEN = "\x1B[32m";
const ANSI_RED = "\x1B[31m";

pub fn syncCli(allocator: std.mem.Allocator, socket: std.posix.socket_t, matches: yazap.ArgMatches) !void {
    // Arena to make the large amounts of allocations more palatable
    var arena = std.heap.ArenaAllocator.init(allocator);
    const arena_alloc = arena.allocator();

    defer arena.deinit();

    if (matches.subcommandMatches("auth")) {
        try auth(arena_alloc, socket);
    } else if (matches.subcommandMatches("register")) {
        // TODO
    } else if (matches.subcommandMatches("purge")) {
        // TODO
    } else {
        // status
        // TODO
    }
}

fn auth(allocator: std.mem.Allocator, socket: std.posix.socket_t) !void {
    const stdin = std.io.getStdIn().reader();
    const stdout = std.io.getStdOut().writer();

    // FIXME: Underline here has some weird behavior
    try stdout.print("{s}DotVC Sync host: {s}{s}", .{ ANSI_BOLD, ANSI_RESET, ANSI_UL });

    const host = try stdin.readUntilDelimiterOrEofAlloc(allocator, '\n', 255) orelse {
        std.log.err("Invalid host input", .{});
        return;
    };
    const url = try std.mem.concat(allocator, u8, &.{ host, "/auth/token" });

    const uri = std.Uri.parse(url) catch |err| {
        try stdout.print("{s}{s}{s}Error parsing host URL:{s} {}\n", .{ ANSI_RESET, ANSI_BOLD, ANSI_RED, ANSI_RESET, err });
        return;
    };

    if (!std.mem.startsWith(u8, uri.scheme, "http")) {
        try stdout.print("{s}{s}{s}Invalid URI schema, only http(s) is supported.{s}\n", .{ ANSI_RESET, ANSI_BOLD, ANSI_RED, ANSI_RESET });
        return;
    }

    try stdout.print("{s}{s}Username: {s}", .{ ANSI_RESET, ANSI_BOLD, ANSI_RESET });
    const username = try stdin.readUntilDelimiterOrEofAlloc(allocator, '\n', 255) orelse {
        std.log.err("Invalid username input", .{});
        return;
    };

    try stdout.print("{s}Password: {s}", .{ ANSI_BOLD, ANSI_RESET });

    const termios = try std.posix.tcgetattr(std.posix.STDOUT_FILENO);
    var t = termios;

    // Disable echoing to hide password as it is being typed
    t.lflag.ECHO = false;

    try std.posix.tcsetattr(std.posix.STDOUT_FILENO, std.posix.TCSA.NOW, t);

    const password = try stdin.readUntilDelimiterOrEofAlloc(allocator, '\n', 255) orelse {
        std.log.err("Invalid username input", .{});
        return;
    };

    try std.posix.tcsetattr(std.posix.STDOUT_FILENO, std.posix.TCSA.NOW, termios);

    const credentials = try std.mem.concat(allocator, u8, &.{ username, ":", password });

    const encoder = std.base64.standard.Encoder;
    const credentials_buf = try allocator.alloc(u8, encoder.calcSize(credentials.len));
    const credentials_base64 = encoder.encode(credentials_buf, credentials);
    const auth_header = try std.mem.concat(allocator, u8, &.{ "Basic: ", credentials_base64 });

    var http_client = std.http.Client{ .allocator = allocator };
    var body = std.ArrayList(u8).init(allocator);

    const res = try http_client.fetch(.{
        .location = .{ .uri = uri },
        .method = .GET,
        .response_storage = .{ .dynamic = &body },
        .extra_headers = &.{std.http.Header{ .name = "Authorization", .value = auth_header }},
    });

    if (res.status != .ok) {
        std.log.err("Server responded with a non-ok response: {}, {s}", .{ res.status, body.items });
        return;
    }

    _ = try http_client.ipcMessage(allocator, socket, .{ .authenticate = sync.SyncState{
        .token = body.items,
        .host = host,
    } });

    try stdout.print("\n{s}{s}Successfully authenticated to host!{s}\n", .{ ANSI_BOLD, ANSI_GREEN, ANSI_RESET });
}
