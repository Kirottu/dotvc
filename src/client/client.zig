const std = @import("std");
const vaxis = @import("vaxis");
const fuzzig = @import("fuzzig");
const yazap = @import("yazap");
const ipc = @import("../daemon/ipc.zig");

const vxfw = vaxis.vxfw;

const Model = struct {
    search_field: vxfw.TextField,

    pub fn widget(self: *Model) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = Model.eventHandler,
            .drawFn = Model.drawFn,
        };
    }

    pub fn eventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) !void {
        const self: *Model = @ptrCast(@alignCast(ptr));
        switch (event) {
            .init => return ctx.requestFocus(self.search_field.widget()),
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) {
                    ctx.quit = true;
                    return;
                }
            },
            else => {},
        }
    }

    pub fn drawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) !vxfw.Surface {
        const self: *Model = @ptrCast(@alignCast(ptr));
        const max_size = ctx.max.size();

        const children = try ctx.arena.alloc(vxfw.SubSurface, 1);
        const border = vxfw.Border{
            .child = self.search_field.widget(),
        };
        const search_field_child = vxfw.SubSurface{
            .origin = .{ .row = max_size.height - 3, .col = 0 },
            .surface = try border.draw(ctx.withConstraints(
                ctx.min,
                .{ .width = max_size.width, .height = 3 },
            )),
        };

        children[0] = search_field_child;

        return vxfw.Surface{
            .size = max_size,
            .widget = self.widget(),
            .buffer = &.{},
            .focusable = false,
            .children = children,
        };
    }
};

pub fn run(allocator: std.mem.Allocator, matches: yazap.ArgMatches) !void {
    // const socket = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
    // const addr = try std.net.Address.initUnix(ipc.SOCKET_PATH);
    // std.log.info("Connecting to daemon...", .{});
    // try std.posix.connect(socket, &addr.any, addr.getOsSockLen());

    // var buf = std.ArrayList(u8).init(allocator);

    // try std.json.stringify(ipc.IpcMsg{ .reload_config = ipc.IpcReloadConfigMsg{} }, .{}, buf.writer());

    // try buf.append('\n');

    // _ = try std.posix.send(socket, buf.items, 0);

    // const buf2 = try allocator.alloc(u8, 2048);

    // _ = try std.posix.recv(socket, buf2, 0);

    // std.log.info("{s}", .{buf2});

    if (matches.subcommandMatches("search")) |_| {
        var app = try vxfw.App.init(allocator);
        defer app.deinit();

        const model = try allocator.create(Model);
        defer allocator.destroy(model);

        var search_buf = vxfw.TextField.Buffer.init(allocator);
        defer search_buf.deinit();

        const unicode = try vaxis.Unicode.init(allocator);

        model.* = Model{ .search_field = vxfw.TextField{ .buf = search_buf, .unicode = &unicode } };

        try app.run(model.widget(), .{});
    }
}
