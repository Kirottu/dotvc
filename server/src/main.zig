const std = @import("std");
const httpz = @import("httpz");

const App = struct {};

pub fn main() !u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    const allocator = gpa.allocator();
    var app = App{};

    var server = try httpz.Server(App).init(allocator, .{ .port = 3001 }, .{});
    defer {
        server.stop();
        server.deinit();
    }

    var router = server.router();
}

pub fn hello() !void {}
