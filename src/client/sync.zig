const std = @import("std");
const yazap = @import("yazap");
const zeit = @import("zeit");

const client = @import("client.zig");
const sync = @import("../daemon/sync.zig");
const server_auth = @import("../server/auth.zig");

const termios_c = @cImport(@cInclude("termios.h"));

const PURGE_CHALLENGE = "Yes, do as I say!";

pub fn syncCli(allocator: std.mem.Allocator, socket: std.posix.socket_t, matches: yazap.ArgMatches) !void {
    // Arena to make the large amounts of allocations more palatable
    var arena = std.heap.ArenaAllocator.init(allocator);
    const arena_alloc = arena.allocator();

    defer arena.deinit();

    if (matches.subcommandMatches("login")) |_| {
        try login(arena_alloc, socket);
    } else if (matches.subcommandMatches("logout")) |_| {
        try logout(arena_alloc, socket);
    } else if (matches.subcommandMatches("register")) |_| {
        try register(arena_alloc, socket);
    } else if (matches.subcommandMatches("purge")) |_| {
        try purge(arena_alloc, socket);
    } else if (matches.subcommandMatches("status")) |_| {
        try status(arena_alloc, socket);
    }
}

fn login(allocator: std.mem.Allocator, socket: std.posix.socket_t) !void {
    const stdout = std.io.getStdOut().writer();

    // FIXME: Underline here has some weird behavior
    const host = try prompt(
        allocator,
        false,
        "{s}DotVC Sync host{s} (http(s)://dotvc.example.com): {s}",
        .{ client.ANSI_BOLD, client.ANSI_RESET, client.ANSI_UL },
    );

    if (!std.mem.startsWith(u8, host, "http")) {
        try stdout.print("{s}{s}{s}Invalid URI schema, only http(s) is supported.{s}\n", .{ client.ANSI_RESET, client.ANSI_BOLD, client.ANSI_RED, client.ANSI_RESET });
        return;
    }

    const username = try prompt(
        allocator,
        false,
        "{s}{s}Username: {s}",
        .{ client.ANSI_RESET, client.ANSI_BOLD, client.ANSI_RESET },
    );
    const password = try prompt(
        allocator,
        true,
        "{s}Password: {s}",
        .{ client.ANSI_BOLD, client.ANSI_RESET },
    );

    var hostname_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const hostname = try std.posix.gethostname(&hostname_buf);

    const db_name_input = try prompt(
        allocator,
        false,
        "{s}Machine name{s} (leave empty for \"{s}\"): ",
        .{ client.ANSI_BOLD, client.ANSI_RESET, hostname },
    );
    const db_name = if (db_name_input.len == 0) hostname else db_name_input;

    try authenticate(allocator, socket, host, username, password, db_name);

    try stdout.print("{s}{s}Successfully authenticated to host!{s}\n", .{ client.ANSI_BOLD, client.ANSI_GREEN, client.ANSI_RESET });
}

fn logout(allocator: std.mem.Allocator, socket: std.posix.socket_t) !void {
    const answer = try prompt(
        allocator,
        false,
        \\Logging out will only log you out of the account.
        \\It will not delete databases that have been downloaded from the Sync server.
        \\If you also want to delete those databases, use `dotvc sync purge`.
        \\
        \\{s}Are you sure?{s} [y/N]:
    ,
        .{ client.ANSI_BOLD, client.ANSI_RESET },
    );
    if (std.mem.eql(u8, answer, "y") or std.mem.eql(u8, answer, "Y")) {
        _ = try client.ipcMessage(allocator, socket, .{ .sync_logout = .{} });
        try std.io.getStdOut().writer().print("Successfully logged out.\n", .{});
    }
}

fn register(allocator: std.mem.Allocator, socket: std.posix.socket_t) !void {
    const stdout = std.io.getStdOut().writer();

    // FIXME: Underline here has some weird behavior
    const host = try prompt(
        allocator,
        false,
        "{s}DotVC Sync host{s} (http(s)://dotvc.example.com): {s}",
        .{ client.ANSI_BOLD, client.ANSI_RESET, client.ANSI_UL },
    );

    if (!std.mem.startsWith(u8, host, "http")) {
        try stdout.print("{s}{s}{s}Invalid URI schema, only http(s) is supported.{s}\n", .{ client.ANSI_RESET, client.ANSI_BOLD, client.ANSI_RED, client.ANSI_RESET });
        return;
    }

    const username = try prompt(
        allocator,
        false,
        "{s}{s}Username{s} (at least {} characters): ",
        .{ client.ANSI_RESET, client.ANSI_BOLD, client.ANSI_RESET, server_auth.MIN_USERNAME_LEN },
    );
    const p1 = try prompt(
        allocator,
        true,
        "{s}Password{s} (at least {} characters): ",
        .{ client.ANSI_BOLD, client.ANSI_RESET, server_auth.MIN_PASSWORD_LEN },
    );
    const p2 = try prompt(
        allocator,
        true,
        "{s}Repeat password{s}: ",
        .{ client.ANSI_BOLD, client.ANSI_RESET },
    );

    if (!std.mem.eql(u8, p1, p2)) {
        try stdout.print(
            "{s}{s}Passwords do not match.{s}",
            .{ client.ANSI_BOLD, client.ANSI_RED, client.ANSI_RESET },
        );
        return;
    }

    var hostname_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const hostname = try std.posix.gethostname(&hostname_buf);

    const db_name_input = try prompt(
        allocator,
        false,
        "{s}Machine name{s} (leave empty for \"{s}\"): ",
        .{ client.ANSI_BOLD, client.ANSI_RESET, hostname },
    );
    const db_name = if (db_name_input.len == 0) hostname else db_name_input;
    const url = try std.mem.concat(
        allocator,
        u8,
        &.{ host, "/auth/register?username=", username, "&password=", p1 },
    );

    var http_client = std.http.Client{ .allocator = allocator };
    var body = std.ArrayList(u8).init(allocator);

    const res = try http_client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .response_storage = .{ .dynamic = &body },
    });

    if (res.status != .ok) {
        try stdout.print(
            "{s}{s}{}{s}, {s}",
            .{ client.ANSI_RED, client.ANSI_BOLD, res.status, client.ANSI_RESET, body.items },
        );
        return;
    }

    try authenticate(allocator, socket, host, username, p1, db_name);

    try stdout.print(
        "{s}{s}Successfully registered & logged into the host!{s}\n",
        .{ client.ANSI_BOLD, client.ANSI_GREEN, client.ANSI_RESET },
    );
}

fn purge(allocator: std.mem.Allocator, socket: std.posix.socket_t) !void {
    const stdout = std.io.getStdOut().writer();

    const input = try prompt(
        allocator,
        false,
        \\{s}{s}Warning!{s}
        \\This will purge all data related to the existing sync connection.
        \\
        \\This data includes:
        \\ - The local database on the server
        \\ - The remote databases on the local machine
        \\ - Local configuration of the sync connection
        \\
        \\To proceed, type {s}{s}{s}: 
        \\
    ,
        .{ client.ANSI_RED, client.ANSI_BOLD, client.ANSI_RESET, client.ANSI_BOLD, PURGE_CHALLENGE, client.ANSI_RESET },
    );

    if (!std.mem.eql(u8, input, PURGE_CHALLENGE)) {
        try std.io.getStdOut().writer().print(
            "{s}{s}Input does not match challenge.{s}\n",
            .{ client.ANSI_BOLD, client.ANSI_RED, client.ANSI_RESET },
        );
        return;
    }

    const ipc_res = try client.ipcMessage(allocator, socket, .{ .get_sync_status = .{} });

    if (ipc_res.value.sync_status == .not_synced) {
        try stdout.print("Not connected to sync, can't purge anything that doesn't exist.\n", .{});
        return;
    }

    _ = try client.ipcMessage(allocator, socket, .{ .purge_sync = .{} });

    try stdout.print("\nData successfully purged.\n", .{});
}

fn status(allocator: std.mem.Allocator, socket: std.posix.socket_t) !void {
    const stdout = std.io.getStdOut().writer();
    const res = try client.ipcMessage(allocator, socket, .{ .get_sync_status = .{} });
    const local_tz = try zeit.local(allocator, null);

    switch (res.value.sync_status) {
        .not_synced => {
            try stdout.print(
                \\{s}{s}Not synced!{s}
                \\
                \\Login to a DotVC Sync server with `dotvc sync login`
                \\
            ,
                .{ client.ANSI_BOLD, client.ANSI_RED, client.ANSI_RESET },
            );
        },
        .synced => |synced| {
            const sync_time = try timeStr(allocator, &local_tz, synced.last_sync);
            try stdout.print(
                \\Logged in as {s}{s}{s} on {s}{s}{s}
                \\Last sync: {s}{s}{s}
                \\
                \\
            ,
                .{
                    client.ANSI_BOLD,
                    synced.username,
                    client.ANSI_RESET,
                    client.ANSI_UL,
                    synced.host,
                    client.ANSI_RESET,
                    client.ANSI_BOLD,
                    sync_time.items,
                    client.ANSI_RESET,
                },
            );

            if (synced.manifests) |manifests| {
                try stdout.print("Synced databases:\n", .{});

                for (manifests) |manifest| {
                    const time_str = try timeStr(allocator, &local_tz, manifest.timestamp);
                    const postfix = if (std.mem.eql(u8, synced.db_name, manifest.name)) " [this machine]" else "";
                    try stdout.print(
                        "  {s}{s}{s}{s}{s}: {s}\n",
                        .{ client.ANSI_BOLD, client.ANSI_GREEN, manifest.name, client.ANSI_RESET, postfix, time_str.items },
                    );
                }
            } else {
                try stdout.print(
                    \\{s}{s}No sync manifest available!{s}
                    \\
                    \\Is the machine connected to the internet? Check daemon output for possible connection errors
                    \\or initiate sync now with `dotvc sync now`.
                    \\
                ,
                    .{ client.ANSI_BOLD, client.ANSI_RED, client.ANSI_RESET },
                );
            }
        },
    }
}

/// Helper function to authenticate the daemon
fn authenticate(
    allocator: std.mem.Allocator,
    socket: std.posix.socket_t,
    host: []u8,
    username: []const u8,
    password: []const u8,
    db_name: []const u8,
) !void {
    const credentials = try std.mem.concat(allocator, u8, &.{ username, ":", password });

    const encoder = std.base64.standard.Encoder;
    const credentials_buf = try allocator.alloc(u8, encoder.calcSize(credentials.len));
    const credentials_base64 = encoder.encode(credentials_buf, credentials);
    const auth_header = try std.mem.concat(allocator, u8, &.{ "Basic: ", credentials_base64 });

    var http_client = std.http.Client{ .allocator = allocator };
    var body = std.ArrayList(u8).init(allocator);

    const url = try std.mem.concat(allocator, u8, &.{ host, "/auth/token" });

    const res = try http_client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_storage = .{ .dynamic = &body },
        .extra_headers = &.{std.http.Header{ .name = "Authorization", .value = auth_header }},
    });

    if (res.status != .ok) {
        try std.io.getStdOut().writer().print(
            "{s}{s}{}{s}, {s}",
            .{ client.ANSI_RED, client.ANSI_BOLD, res.status, client.ANSI_RESET, body.items },
        );
        std.process.exit(1);
    }

    _ = try client.ipcMessage(allocator, socket, .{ .sync_login = sync.SyncState{
        .token = body.items,
        .db_name = db_name,
        .username = username,
        .host = host,
    } });
}

fn timeStr(allocator: std.mem.Allocator, tz: *const zeit.TimeZone, timestamp: i64) !std.ArrayList(u8) {
    const zeit_timestamp = try zeit.instant(.{ .source = .{ .unix_timestamp = timestamp } });
    const local = zeit_timestamp.in(tz);
    var time = std.ArrayList(u8).init(allocator);

    try local.time().strftime(time.writer(), "%Y-%m-%d %H:%M:%S");
    return time;
}

fn prompt(allocator: std.mem.Allocator, hide_input: bool, comptime fmt: []const u8, args: anytype) ![]u8 {
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
        try stdout.print("{s}Invalid input{s}\n", .{ client.ANSI_RED, client.ANSI_RESET });
        std.process.exit(1);
    };

    if (hide_input) {
        try std.posix.tcsetattr(std.posix.STDOUT_FILENO, std.posix.TCSA.NOW, termios);
        try stdout.print("\n", .{});
    }

    return out;
}
