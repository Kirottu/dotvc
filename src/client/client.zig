const std = @import("std");
const vaxis = @import("vaxis");
const fuzzig = @import("fuzzig");
const yazap = @import("yazap");
const ipc = @import("../daemon/ipc.zig");

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
};

pub fn run(allocator: std.mem.Allocator, matches: yazap.ArgMatches) !void {
    if (matches.subcommandMatches("interactive")) |_| {
        const socket = try std.posix.socket(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0);
        const addr = try std.net.Address.initUnix(ipc.SOCKET_PATH);
        try std.posix.connect(socket, &addr.any, addr.getOsSockLen());

        var buf = std.ArrayList(u8).init(allocator);

        try std.json.stringify(ipc.IpcMsg{ .get_all_dotfiles = ipc.IpcNone{} }, .{}, buf.writer());

        try buf.append('\n');

        _ = try std.posix.send(socket, buf.items, 0);

        var read_buf = try allocator.alloc(u8, 2048);
        defer allocator.free(read_buf);
        var offset: usize = 0;
        while (true) {
            const read = try std.posix.recv(socket, read_buf[offset..], 0);
            offset += read;
            if (read == read_buf.len) {
                read_buf = try allocator.realloc(read_buf, read_buf.len + 2048);
            } else {
                break;
            }
        }

        const parsed = try std.json.parseFromSlice(ipc.IpcResponse, allocator, read_buf[0 .. offset - 1], .{});
        defer parsed.deinit();
        const dotfiles = parsed.value.dotfiles;

        var tty = try vaxis.Tty.init();
        var vx = try vaxis.init(allocator, .{});
        var loop = vaxis.Loop(Event){
            .tty = &tty,
            .vaxis = &vx,
        };
        try loop.init();
        try loop.start();

        defer tty.deinit();
        defer vx.deinit(allocator, tty.anyWriter());
        defer loop.stop();

        try vx.enterAltScreen(tty.anyWriter());
        try vx.queryTerminal(tty.anyWriter(), std.time.ns_per_s);

        var text_input = vaxis.widgets.TextInput.init(allocator, &vx.unicode);
        var table_ctx = vaxis.widgets.Table.TableContext{
            .selected_bg = .default,
            .header_names = .{ .custom = &.{ "Path", "Tags", "Date" } },
        };

        defer text_input.deinit();

        var event_arena = std.heap.ArenaAllocator.init(allocator);
        defer event_arena.deinit();

        // Main client loop
        while (true) {
            _ = event_arena.reset(.retain_capacity);
            const event_alloc = event_arena.allocator();

            const event = loop.nextEvent();
            switch (event) {
                .key_press => |key| {
                    if (key.matches('c', .{ .ctrl = true })) {
                        break;
                    } else {
                        try text_input.update(.{ .key_press = key });
                    }
                },
                .winsize => |ws| try vx.resize(allocator, tty.anyWriter(), ws),
                else => {},
            }

            const win = vx.window();
            win.clear();

            const input_child = win.child(.{
                .y_off = win.height - 2,
                .x_off = 2,
                .width = win.width,
                .height = 2,
                .border = .{
                    .where = .top,
                    .glyphs = .single_square,
                },
            });
            text_input.draw(input_child);

            _ = win.printSegment(.{
                .text = "DotVC v0.1.0alpha",
                .style = .{
                    .bold = true,
                    .fg = .{ .rgb = .{ 0, 100, 255 } },
                },
            }, .{
                .row_offset = win.height - 2,
            });
            _ = win.printSegment(
                .{
                    .text = ">",
                    .style = .{
                        .dim = true,
                    },
                },
                .{
                    .row_offset = win.height - 1,
                },
            );

            const table_child = win.child(.{
                .height = win.height - 2,
            });

            vaxis.widgets.Table.drawTable(event_alloc, table_child, dotfiles, &table_ctx);

            try vx.render(tty.anyWriter());
        }
    }
}
