const std = @import("std");
const vaxis = @import("vaxis");
const fuzzig = @import("fuzzig");
const zeit = @import("zeit");
const client = @import("client.zig");
const ipc = @import("../daemon/ipc.zig");
const root = @import("../main.zig");

const TEMP_FILE_CHARS = "abcdefghijklmnopqrstuvwxyz0123456789";
const TEMP_FILE_DIR = "/tmp/dotvc";

const Color = enum(u8) {
    black = 0,
    red = 1,
    green = 2,
    yellow = 3,
    blue = 4,
    magenta = 5,
    cyan = 6,
    white = 7,

    bright_black = 8,
    bright_red = 9,
    bright_green = 10,
    bright_yellow = 11,
    bright_blue = 12,
    bright_magenta = 13,
    bright_cyan = 14,
    bright_white = 15,
};

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
};

const SearchResult = struct {
    path: []const u8,
    tags: []const u8,
    date: []const u8,

    // Indices for the matching characters, used for highlighting
    path_matches: ?[]const usize,
    tags_matches: ?[]const usize,
    date_matches: ?[]const usize,
};

pub const State = struct {
    socket: std.posix.socket_t,

    tty: vaxis.tty.PosixTty,
    vx: vaxis.Vaxis,

    allocator: std.mem.Allocator,
    event_arena: std.heap.ArenaAllocator,

    ipc_dotfiles: root.ArenaOutput([]const ipc.IpcDistilledDotfile),
    search_results: ?[]const SearchResult,
    local_tz: zeit.TimeZone,
    text_input: vaxis.widgets.TextInput,

    config: root.Config,

    pub fn init(allocator: std.mem.Allocator, socket: std.posix.socket_t, config: root.Config) !State {
        var tty = try vaxis.Tty.init();
        var vx = try vaxis.init(allocator, .{});

        try vx.enterAltScreen(tty.anyWriter());
        try vx.queryTerminal(tty.anyWriter(), std.time.ns_per_s);

        const text_input = vaxis.widgets.TextInput.init(allocator, &vx.unicode);
        const local_tz = try zeit.local(allocator, null);

        const ipc_dotfiles = try client.ipcMessage(allocator, socket, ipc.IpcMsg{ .get_all_dotfiles = ipc.IpcNone{} });

        const state = State{
            .socket = socket,

            .tty = tty,
            .vx = vx,

            .allocator = allocator,
            .event_arena = std.heap.ArenaAllocator.init(allocator),

            .ipc_dotfiles = .{
                .arena = ipc_dotfiles.arena,
                .value = ipc_dotfiles.value.dotfiles,
            },
            .search_results = null,
            .local_tz = local_tz,

            .text_input = text_input,
            .config = config,
        };

        return state;
    }

    pub fn deinit(self: *State) void {
        self.vx.deinit(self.allocator, self.tty.anyWriter());
        self.tty.deinit();
        self.event_arena.deinit();
        self.ipc_dotfiles.deinit();
        self.local_tz.deinit();
    }

    pub fn run(self: *State) !void {
        var loop = vaxis.Loop(Event){
            .tty = &self.tty,
            .vaxis = &self.vx,
        };
        try loop.init();
        try loop.start();

        defer loop.stop();

        while (true) {
            _ = self.event_arena.reset(.retain_capacity);
            const event_alloc = self.event_arena.allocator();
            const event = loop.nextEvent();
            switch (event) {
                .key_press => |key| {
                    if (key.matches('c', .{ .ctrl = true })) {
                        break;
                    } else if (key.matches('e', .{ .ctrl = true })) {
                        const selected_dotfile = self.ipc_dotfiles.value[5];
                        const res = try client.ipcMessage(event_alloc, self.socket, ipc.IpcMsg{ .get_dotfile = selected_dotfile.rowid });
                        defer res.deinit();
                        const dotfile = res.value.dotfile;
                        var split = std.mem.splitBackwardsScalar(u8, dotfile.path, '/');
                        const filename = split.first();

                        var prng = std.Random.DefaultPrng.init(blk: {
                            var seed: u64 = undefined;
                            try std.posix.getrandom(std.mem.asBytes(&seed));
                            break :blk seed;
                        });
                        const rand = prng.random();

                        const prefix = try event_alloc.alloc(u8, 5);

                        for (0..5) |i| {
                            const index = rand.uintLessThan(usize, TEMP_FILE_CHARS.len);
                            prefix[i] = TEMP_FILE_CHARS[index];
                        }

                        try std.fs.cwd().makePath(TEMP_FILE_DIR);

                        const path = try std.mem.concat(event_alloc, u8, &.{ TEMP_FILE_DIR, "/", prefix, "-", filename });

                        var file = try std.fs.createFileAbsolute(path, .{});
                        try file.writeAll(dotfile.content);

                        loop.stop();
                        self.vx.window().clear();
                        try self.vx.render(self.tty.anyWriter());
                        var child = std.process.Child.init(&.{ "helix", path }, self.allocator);
                        _ = try child.spawnAndWait();
                        try loop.start();

                        try std.fs.deleteFileAbsolute(path);
                    } else if (key.matches('r', .{ .ctrl = true })) {
                        self.vx.queueRefresh();
                    } else {
                        try self.text_input.update(.{ .key_press = key });
                    }
                },
                .winsize => |ws| try self.vx.resize(self.allocator, self.tty.anyWriter(), ws),
                else => {},
            }
            const win = self.vx.window();
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
            self.text_input.draw(input_child);

            _ = win.printSegment(.{
                .text = "DotVC v0.1.0alpha ",
                .style = .{
                    .bold = true,
                    .fg = .{ .index = @intFromEnum(Color.blue) },
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

            const results_child = win.child(.{
                .height = win.height - 2,
            });

            const time_fmt = "%Y-%m-%d %H:%M:%S";
            // The length of the formatted time string is consistent, but %Y expands to 4 digits
            // so that has to be accounted for
            const time_length = time_fmt.len + 2;

            _ = results_child.printSegment(.{
                .text = "Path",
                .style = .{ .dim = true },
            }, .{ .col_offset = 1 });
            _ = results_child.printSegment(.{
                .text = "Tags",
                .style = .{ .dim = true },
            }, .{ .col_offset = @intCast(results_child.width - time_length - 7) });
            _ = results_child.printSegment(.{
                .text = "Time",
                .style = .{ .dim = true },
            }, .{ .col_offset = results_child.width - 5 });

            for (1.., self.ipc_dotfiles.value) |line, dotfile| {
                if (line > results_child.height) {
                    break;
                }

                const tags_str =
                    try std.mem.join(event_alloc, ", ", dotfile.tags);
                const timestamp = try zeit.instant(.{ .source = .{ .unix_timestamp = dotfile.date } });
                const local = timestamp.in(&self.local_tz);
                var time_str = std.ArrayList(u8).init(event_alloc);
                try local.time().strftime(time_str.writer(), "%Y-%m-%d %H:%M:%S");

                const time_offset: u16 = @intCast(results_child.width - time_length - 1);
                const tags_offset: u16 = @intCast(time_offset - tags_str.len - 2);

                _ = results_child.printSegment(.{ .text = dotfile.path }, .{
                    .row_offset = @intCast(line),
                    .col_offset = 1,
                });
                _ = results_child.printSegment(.{
                    .text = tags_str,
                    .style = .{
                        .fg = .{ .index = @intFromEnum(Color.yellow) },
                    },
                }, .{
                    .row_offset = @intCast(line),
                    .col_offset = tags_offset,
                });
                _ = results_child.printSegment(.{
                    .text = time_str.items,
                    .style = .{
                        .fg = .{ .index = @intFromEnum(Color.green) },
                    },
                }, .{
                    .row_offset = @intCast(line),
                    .col_offset = time_offset,
                });
            }

            try self.vx.render(self.tty.anyWriter());
        }
    }
};
