const std = @import("std");
const ipc = @import("../daemon/ipc.zig");

pub fn run(allocator: std.mem.Allocator) !void {
    const socket = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    const addr = try std.net.Address.initUnix(ipc.SOCKET_PATH);
    std.log.info("Connecting to daemon...", .{});
    try std.posix.connect(socket, &addr.any, addr.getOsSockLen());

    var buf = std.ArrayList(u8).init(allocator);

    try std.json.stringify(ipc.IpcMsg{ .shutdown = ipc.IpcShutdownMsg{} }, .{}, buf.writer());

    try buf.append('\n');

    _ = try std.posix.send(socket, buf.items, 0);

    const buf2 = try allocator.alloc(u8, 2048);

    _ = try std.posix.recv(socket, buf2, 0);

    std.log.info("{s}", .{buf2});
}
