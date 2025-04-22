const std = @import("std");
const root = @import("../main.zig");
const sync = @import("sync.zig");

pub const SOCKET_PATH = "/tmp/dotvc.sock";

pub const Msg = struct {
    client: *Client,
    ipc_msg: IpcMsg,
};

/// The messages that are actually passed through the IPC
pub const IpcMsg = union(enum) {
    shutdown: struct {},
    reload_config: struct {},

    index_all: struct {},
    get_all_dotfiles: ?[]const u8,
    get_dotfile: IpcGetDotfile,

    sync_login: sync.SyncState,
    purge_sync: struct {},
    sync_logout: struct {},
    get_sync_status: struct {},
    sync_now: struct {},
};

pub const IpcGetDotfile = struct {
    rowid: i64,
    database: ?[]const u8,
};

pub const IpcResponse = union(enum) {
    ok: struct {},
    err: IpcError,
    dotfiles: []const IpcDistilledDotfile,
    dotfile: IpcDotfile,
    sync_status: SyncStatus,

    pub fn isErr(self: IpcResponse) bool {
        return switch (self) {
            inline else => |field| @TypeOf(field) == IpcError,
        };
    }
};

pub const IpcError = enum {
    invalid_database,
    sync_failed,
};

pub const SyncStatus = union(enum) {
    not_synced: struct {},
    synced: struct {
        last_sync: i64,
        host: []const u8,
        db_name: []const u8,
        username: []const u8,
        manifests: ?[]sync.Manifest,
    },
};

/// Dotfile ready for writing into the filesystem or editing
pub const IpcDotfile = struct {
    path: []const u8,
    content: []const u8,
};

/// Simplified dotfile type to avoid sending all dotfile content over IPC unnecessarily
pub const IpcDistilledDotfile = struct {
    rowid: i64,
    date: i64,
    path: []const u8,
    tags: [][]const u8,
};

pub const Client = struct {
    socket: std.posix.socket_t,
    buf: []u8,
    offset: usize = 0,
    allocator: std.mem.Allocator,

    pub fn deinit(self: Client) void {
        self.allocator.free(self.buf);
    }

    pub fn reply(self: *Client, response: IpcResponse) !void {
        var buf = std.ArrayList(u8).init(self.allocator);
        defer buf.deinit();
        try std.json.stringify(response, .{}, buf.writer());

        try buf.append('\n');

        _ = try std.posix.send(self.socket, buf.items, std.posix.SOCK.NONBLOCK);
    }
};

pub const Ipc = struct {
    socket: std.posix.socket_t,
    buf: []u8,
    clients: std.ArrayList(Client),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !Ipc {
        std.fs.deleteFileAbsolute(SOCKET_PATH) catch |err| {
            if (err != error.FileNotFound) {
                std.log.err("Unknown error deleting old socket: {}", .{err});
            }
        };

        const address = try std.net.Address.initUnix(SOCKET_PATH);
        const socket = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM | std.posix.SOCK.NONBLOCK, 0);
        try std.posix.bind(socket, &address.any, address.getOsSockLen());
        try std.posix.listen(socket, 10);

        const buf = try allocator.alloc(u8, 2048);
        const clients = std.ArrayList(Client).init(allocator);

        return Ipc{
            .socket = socket,
            .buf = buf,
            .clients = clients,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Ipc) void {
        self.allocator.free(self.buf);
        for (self.clients.items) |*client| {
            self.disconnectClient(client) catch {};
            client.deinit();
        }
        self.clients.deinit();
    }

    fn acceptClients(self: *Ipc) !void {
        while (true) {
            const socket =
                std.posix.accept(
                    self.socket,
                    null,
                    null,
                    std.posix.SOCK.NONBLOCK,
                ) catch |err| {
                    if (err != error.WouldBlock) {
                        std.log.err("Unexpected IPC accept error: {}", .{err});
                    }
                    return;
                };
            std.log.info("Accepted client connection: {}", .{socket});
            const buf = try self.allocator.alloc(u8, 2048);
            try self.clients.append(Client{
                .socket = socket,
                .buf = buf,
                .allocator = self.allocator,
            });
        }
    }

    pub fn readMessages(self: *Ipc, loop_alloc: std.mem.Allocator) !std.ArrayList(Msg) {
        try self.acceptClients();
        var messages = std.ArrayList(Msg).init(loop_alloc);
        var pending_disconnection = std.ArrayList(*Client).init(loop_alloc);
        defer pending_disconnection.deinit();

        for (self.clients.items) |*client| {
            const read =
                std.posix.recv(client.socket, client.buf[client.offset..], std.posix.SOCK.NONBLOCK) catch |err| {
                    if (err == error.WouldBlock) {
                        continue;
                    } else {
                        std.log.info("Unexpected IPC recv error: {}", .{err});
                        continue;
                    }
                };

            if (read == 0) {
                try pending_disconnection.append(client);
                continue;
            }

            client.offset += read;
            if (client.offset != 0 and client.buf[client.offset - 1] == '\n') {
                // Leaky is fine as loop_lloc is cleaned on every main loop cycle
                const ipc_msg = try std.json.parseFromSliceLeaky(IpcMsg, loop_alloc, client.buf[0 .. client.offset - 1], .{});
                const msg = Msg{
                    .client = client,
                    .ipc_msg = ipc_msg,
                };
                client.offset = 0;
                try messages.append(msg);
            }
        }

        for (pending_disconnection.items) |client| {
            try self.disconnectClient(client);
        }

        return messages;
    }

    pub fn disconnectClient(self: *Ipc, client: *Client) !void {
        var index: ?usize = null;
        for (0.., self.clients.items) |i, *_client| {
            if (client == _client) {
                index = i;
            }
        }
        if (index) |i| {
            std.log.info("Disconnected client {}", .{client.socket});
            client.deinit();
            _ = self.clients.swapRemove(i);
        }
    }
};
