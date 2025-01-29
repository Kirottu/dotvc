const std = @import("std");

pub const SOCKET_PATH = "/tmp/dotvc.sock";

pub const Msg = struct {
    client: *Client,
    ipc_msg: std.json.Parsed(IpcMsg),

    pub fn deinit(self: Msg) void {
        self.ipc_msg.deinit();
    }
};

/// The messages that are actually passed through the IPC
pub const IpcMsg = union(enum) {
    shutdown,
    reload_config,
    index_all,
    get_all_dotfiles,
    get_dotfile: GetDotfile,
};

pub const GetDotfile = struct {
    rowid: i64,
};

pub const IpcResponse = union(enum) {
    ok,
    dotfiles: IpcresponseDotfiles,
    dotfile: IpcResponseDotfile,
};

pub const IpcresponseDotfiles = struct {
    dotfiles: []const IpcDistilledDotfile,
};
pub const IpcResponseDotfile = struct {
    dotfile: IpcDotfile,
};

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

    pub fn readMessages(self: *Ipc) !std.ArrayList(Msg) {
        try self.acceptClients();

        var messages = std.ArrayList(Msg).init(self.allocator);

        for (self.clients.items) |*client| {
            const read =
                std.posix.recv(client.socket, client.buf[client.offset..], std.posix.SOCK.NONBLOCK) catch {
                continue;
            };
            client.offset += read;
            if (client.offset != 0 and client.buf[client.offset - 1] == '\n') {
                const ipc_msg = try std.json.parseFromSlice(IpcMsg, self.allocator, client.buf[0 .. client.offset - 1], .{});
                const msg = Msg{
                    .client = client,
                    .ipc_msg = ipc_msg,
                };
                client.offset = 0;
                try messages.append(msg);
            }
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
