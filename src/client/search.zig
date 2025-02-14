const std = @import("std");
const vaxis = @import("vaxis");
const fuzzig = @import("fuzzig");
const zeit = @import("zeit");
const client = @import("client.zig");
const ipc = @import("../daemon/ipc.zig");
const root = @import("../main.zig");

// Constant strings needed in different parts of the program
const TEMP_FILE_CHARS = "abcdefghijklmnopqrstuvwxyz0123456789";
const TEMP_FILE_DIR = "/tmp/dotvc";
const BANNER_STR = "DotVC v0.1.0alpha ";
const TIME_FMT = "%Y-%m-%d %H:%M:%S";

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
    match_indices: []const usize,
    rowid: i64,
};

pub const SearchError = error{
    InvalidDatabase,
};

pub const State = struct {
    socket: std.posix.socket_t,

    tty: vaxis.tty.PosixTty,
    vx: vaxis.Vaxis,

    allocator: std.mem.Allocator,
    event_arena: std.heap.ArenaAllocator,

    ipc_dotfiles: root.ArenaAllocated([]const ipc.IpcDistilledDotfile),
    search_results: ?root.ArenaAllocated([]const SearchResult),
    local_tz: zeit.TimeZone,
    prng: std.Random.DefaultPrng,

    selected_entry: usize,
    text_input: vaxis.widgets.TextInput,
    searcher: fuzzig.Ascii,

    config: root.Config,
    /// Selected database, if null the default database for the machine is used
    database: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, socket: std.posix.socket_t, config: root.Config, database: ?[]const u8) !State {
        const ipc_dotfiles = try client.ipcMessage(
            allocator,
            socket,
            ipc.IpcMsg{ .get_all_dotfiles = database },
        );
        errdefer ipc_dotfiles.deinit();

        if (ipc_dotfiles.value.isErr()) {
            return SearchError.InvalidDatabase;
        }

        var tty = try vaxis.Tty.init();
        var vx = try vaxis.init(allocator, .{});

        try vx.enterAltScreen(tty.anyWriter());
        try vx.queryTerminal(tty.anyWriter(), std.time.ns_per_s);

        // FIXME: Needs better haystack and needle values
        const searcher = try fuzzig.Ascii.init(allocator, 2048, 2048, .{ .case_sensitive = false });
        const text_input = vaxis.widgets.TextInput.init(allocator, &vx.unicode);
        const local_tz = try zeit.local(allocator, null);

        const prng = std.Random.DefaultPrng.init(blk: {
            var seed: u64 = undefined;
            try std.posix.getrandom(std.mem.asBytes(&seed));
            break :blk seed;
        });

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
            .selected_entry = 0,
            .local_tz = local_tz,
            .prng = prng,

            .searcher = searcher,
            .text_input = text_input,
            .config = config,
            .database = database,
        };

        return state;
    }

    pub fn deinit(self: *State) void {
        self.vx.deinit(self.allocator, self.tty.anyWriter());
        self.tty.deinit();
        self.event_arena.deinit();
        self.ipc_dotfiles.deinit();
        self.local_tz.deinit();
        self.searcher.deinit();
        self.text_input.deinit();
        if (self.search_results) |results| {
            results.deinit();
        }
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
                    } else if (key.matches('e', .{ .ctrl = true }) or key.matches(vaxis.Key.enter, .{})) {
                        loop.stop();
                        try self.openEditor(event_alloc);
                        try loop.start();
                    } else if (key.matches(vaxis.Key.down, .{})) {
                        const max_index = (if (self.search_results) |results| results.value.len else self.ipc_dotfiles.value.len) - 1;
                        if (self.selected_entry < max_index) {
                            self.selected_entry += 1;
                        }
                    } else if (key.matches(vaxis.Key.up, .{})) {
                        if (self.selected_entry > 0) {
                            self.selected_entry -= 1;
                        }
                    } else {
                        try self.text_input.update(.{ .key_press = key });
                        try self.updateSearch(event_alloc);
                        self.selected_entry = 0;
                    }
                },
                .winsize => |ws| try self.vx.resize(self.allocator, self.tty.anyWriter(), ws),
                else => {},
            }
            const win = self.vx.window();
            win.clear();

            // Draw the header
            const header = win.child(.{ .height = 1 });
            _ = header.printSegment(.{
                .text = "Path",
                .style = .{ .dim = true },
            }, .{ .col_offset = 1 });
            _ = header.printSegment(.{
                .text = "Tags",
                .style = .{ .dim = true },
            }, .{ .col_offset = @intCast(header.width - TIME_FMT.len - 9) });
            _ = header.printSegment(.{
                .text = "Time",
                .style = .{ .dim = true },
            }, .{ .col_offset = header.width - 5 });

            // Draw the actual content
            const content = win.child(.{
                .height = win.height - 3,
                .y_off = 1,
            });

            if (self.search_results) |search_results| {
                for (0.., search_results.value) |line, result| {
                    if (line > content.height - 1) {
                        break;
                    }
                    self.drawResult(content, result.path, result.tags, result.date, @intCast(line));
                }
            } else {
                for (0.., self.ipc_dotfiles.value) |line, dotfile| {
                    if (line > content.height) {
                        break;
                    }

                    const tags_str =
                        try std.mem.join(event_alloc, ", ", dotfile.tags);
                    const timestamp = try zeit.instant(.{ .source = .{ .unix_timestamp = dotfile.date } });
                    const local = timestamp.in(&self.local_tz);
                    var time_str = std.ArrayList(u8).init(event_alloc);
                    try local.time().strftime(time_str.writer(), "%Y-%m-%d %H:%M:%S");

                    self.drawResult(content, dotfile.path, tags_str, time_str.items, @intCast(line));
                }
            }

            // Draw search prompt
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
                .text = BANNER_STR,
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

            try self.vx.render(self.tty.anyWriter());
        }
    }

    fn drawResult(self: *State, win: vaxis.Window, path: []const u8, tags: []const u8, time: []const u8, line: u16) void {
        const time_offset: u16 = @intCast(win.width - time.len - 1);
        const tags_offset: u16 = @intCast(time_offset - tags.len - 2);

        _ = win.printSegment(.{
            .text = path,
            .style = .{ .reverse = line == self.selected_entry },
        }, .{
            .row_offset = @intCast(line),
            .col_offset = 1,
        });
        _ = win.printSegment(.{
            .text = tags,
            .style = .{
                .fg = .{ .index = @intFromEnum(Color.yellow) },
            },
        }, .{
            .row_offset = @intCast(line),
            .col_offset = tags_offset,
        });
        _ = win.printSegment(.{
            .text = time,
            .style = .{
                .fg = .{ .index = @intFromEnum(Color.green) },
            },
        }, .{
            .row_offset = @intCast(line),
            .col_offset = time_offset,
        });
    }

    fn updateSearch(self: *State, event_alloc: std.mem.Allocator) !void {
        if (self.search_results) |results| {
            results.deinit();
            self.search_results = null;
        }

        const needle = self.text_input.buf.firstHalf();

        if (needle.len == 0) {
            return;
        }

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        const arena_alloc = arena.allocator();

        const TempResult = struct {
            result: SearchResult,
            score: i32,

            fn sort(_: void, a: @This(), b: @This()) bool {
                return std.sort.desc(i32)({}, a.score, b.score);
            }
        };

        var temp_results = try event_alloc.alloc(TempResult, self.ipc_dotfiles.value.len);

        for (0.., self.ipc_dotfiles.value) |i, dotfile| {
            const tags_str =
                try std.mem.join(arena_alloc, ", ", dotfile.tags);
            const timestamp = try zeit.instant(.{ .source = .{ .unix_timestamp = dotfile.date } });
            const local = timestamp.in(&self.local_tz);
            var time_str = std.ArrayList(u8).init(arena_alloc);
            try local.time().strftime(time_str.writer(), "%Y-%m-%d %H:%M:%S");

            const haystack = try std.mem.concat(event_alloc, u8, &.{ dotfile.path, tags_str, time_str.items });

            const matches = self.searcher.scoreMatches(haystack, needle);

            temp_results[i] = .{ .result = SearchResult{
                .path = dotfile.path,
                .tags = tags_str,
                .date = time_str.items,
                .match_indices = matches.matches,
                .rowid = dotfile.rowid,
            }, .score = matches.score orelse -(std.math.maxInt(i32) - 1) };
        }

        std.mem.sort(TempResult, temp_results, {}, TempResult.sort);
        var last_index: i64 = -1;

        // Prune results with no matches
        for (0.., temp_results) |i, temp_res| {
            if (temp_res.score == -(std.math.maxInt(i32) - 1)) {
                last_index = @intCast(i);
                break;
            }
        }
        if (last_index > -1) {
            temp_results = try event_alloc.realloc(temp_results, @intCast(last_index));
        }

        // Conveniently, the dotfiles as they come out of the database are already ordered by the timestamp,
        // so that does not need to be sorted for
        const search_results = try arena_alloc.alloc(SearchResult, temp_results.len);

        for (0.., temp_results) |i, temp_result| {
            search_results[i] = temp_result.result;
        }

        if (search_results.len > 0) {
            self.search_results = .{
                .arena = arena,
                .value = search_results,
            };
        }
    }

    fn openEditor(self: *State, event_alloc: std.mem.Allocator) !void {
        const selected_rowid = if (self.search_results) |results|
            results.value[self.selected_entry].rowid
        else
            self.ipc_dotfiles.value[self.selected_entry].rowid;
        const res = try client.ipcMessage(
            event_alloc,
            self.socket,
            ipc.IpcMsg{
                .get_dotfile = .{ .rowid = selected_rowid, .database = self.database },
            },
        );
        defer res.deinit();

        const dotfile = res.value.dotfile;
        var split = std.mem.splitBackwardsScalar(u8, dotfile.path, '/');
        const filename = split.first();

        const rand = self.prng.random();
        const prefix = try event_alloc.alloc(u8, 5);

        for (0..5) |i| {
            const index = rand.uintLessThan(usize, TEMP_FILE_CHARS.len);
            prefix[i] = TEMP_FILE_CHARS[index];
        }

        try std.fs.cwd().makePath(TEMP_FILE_DIR);

        const path = try std.mem.concat(event_alloc, u8, &.{ TEMP_FILE_DIR, "/", prefix, "-", filename });

        var file = try std.fs.createFileAbsolute(path, .{});
        try file.writeAll(dotfile.content);

        self.vx.window().clear();
        try self.vx.render(self.tty.anyWriter());
        var child = std.process.Child.init(&.{ self.config.editor, path }, self.allocator);
        _ = try child.spawnAndWait();

        self.vx.queueRefresh();

        try std.fs.deleteFileAbsolute(path);
    }
};
