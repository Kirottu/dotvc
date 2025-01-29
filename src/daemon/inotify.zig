const std = @import("std");
const inotify_event = std.os.linux.inotify_event;
// Mask definitions for inotify
const inotify_c = @cImport(@cInclude("sys/inotify.h"));

const Watcher = struct {
    id: u64,
    fd: ?i32,
    path: []const u8,
    /// If specified, only watch for changes in this file
    name: ?[]const u8 = null,
};

pub const Event = struct {
    watcher_id: u64,
    ancestor: []const u8,
    name: []const u8,
    mask: u32,

    pub fn hasMask(self: *const Event, mask: c_int) bool {
        return mask & @as(c_int, @intCast(self.mask)) == mask;
    }

    pub fn printMask(self: *const Event) !void {
        std.log.info("Event {s} masks:", .{self.ancestor});
        if (self.hasMask(inotify_c.IN_ACCESS)) {
            std.log.info("IN_ACCESS", .{});
        }
        if (self.hasMask(inotify_c.IN_MODIFY)) {
            std.log.info("IN_MODIFY", .{});
        }
        if (self.hasMask(inotify_c.IN_ATTRIB)) {
            std.log.info("IN_ATTRIB", .{});
        }
        if (self.hasMask(inotify_c.IN_CLOSE_WRITE)) {
            std.log.info("IN_CLOSE_WRITE", .{});
        }
        if (self.hasMask(inotify_c.IN_CLOSE_NOWRITE)) {
            std.log.info("IN_CLOSE_NOWRITE", .{});
        }
        if (self.hasMask(inotify_c.IN_OPEN)) {
            std.log.info("IN_OPEN", .{});
        }
        if (self.hasMask(inotify_c.IN_MOVED_FROM)) {
            std.log.info("IN_MOVED_FROM", .{});
        }
        if (self.hasMask(inotify_c.IN_MOVED_TO)) {
            std.log.info("IN_MOVED_TO", .{});
        }
        if (self.hasMask(inotify_c.IN_CREATE)) {
            std.log.info("IN_CREATE", .{});
        }
        if (self.hasMask(inotify_c.IN_DELETE)) {
            std.log.info("IN_DELETE", .{});
        }
        if (self.hasMask(inotify_c.IN_DELETE_SELF)) {
            std.log.info("IN_DELETE_SELF", .{});
        }
        if (self.hasMask(inotify_c.IN_MOVE_SELF)) {
            std.log.info("IN_MOVE_SELF", .{});
        }
        std.log.info("---------------", .{});
    }
};

pub const Inotify = struct {
    fd: i32,
    buf: []u8,
    watchers: std.ArrayList(Watcher),
    allocator: std.mem.Allocator,
    watcher_id: u64,

    pub fn init(allocator: std.mem.Allocator) !Inotify {
        const fd = try std.posix.inotify_init1(inotify_c.IN_NONBLOCK);

        const buf = try allocator.alloc(u8, 2048);
        const watchers = std.ArrayList(Watcher).init(allocator);

        return Inotify{
            .fd = fd,
            .buf = buf,
            .watchers = watchers,
            .allocator = allocator,
            .watcher_id = 0,
        };
    }

    pub fn deinit(self: Inotify) void {
        std.posix.close(self.fd);
        self.allocator.free(self.buf);
        self.watchers.deinit();
    }

    pub fn addWatcher(self: *Inotify, path: []const u8) !u64 {
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        const metadata = try file.metadata();
        self.watcher_id += 1;
        var watcher = Watcher{
            .id = self.watcher_id,
            .fd = null,
            .path = "",
        };

        // If watch path points to a normal file, watch the parent directory instead.
        if (metadata.kind() != std.fs.File.Kind.directory) {
            var it = std.mem.splitBackwardsScalar(u8, path, '/');
            if (it.next()) |filename| {
                watcher.name = filename;
                watcher.path = path[0 .. path.len - filename.len];
            }
        } else {
            watcher.path = path;
        }

        const wd = try std.posix.inotify_add_watch(
            self.fd,
            watcher.path,
            inotify_c.IN_MOVED_TO | inotify_c.IN_MODIFY | inotify_c.IN_DELETE_SELF | inotify_c.IN_MOVE_SELF,
        );

        watcher.fd = wd;

        try self.watchers.append(watcher);

        return self.watcher_id;
    }

    pub fn purgeWatchers(self: *Inotify) void {
        for (self.watchers.items) |watcher| {
            if (watcher.fd) |fd| {
                std.posix.inotify_rm_watch(self.fd, fd);
            }
        }

        self.watchers.clearRetainingCapacity();
    }

    pub fn readEvents(self: *Inotify) !std.ArrayList(Event) {
        // Check any file in the retry loop
        for (self.watchers.items) |*watcher| {
            if (watcher.fd == null) {
                const wd = std.posix.inotify_add_watch(
                    self.fd,
                    watcher.path,
                    inotify_c.IN_MOVED_TO | inotify_c.IN_MODIFY | inotify_c.IN_DELETE_SELF | inotify_c.IN_MOVE_SELF,
                ) catch {
                    continue;
                };

                std.log.info("Directory {s} reappeared, watching...", .{watcher.path});

                watcher.fd = wd;
            }
        }

        var events = std.ArrayList(Event).init(self.allocator);
        if (std.posix.read(self.fd, self.buf)) |read| {
            std.log.info("Read {} bytes from inotify", .{read});

            var offset: usize = 0;

            while (offset < read) {
                const event: *align(4) inotify_event = @alignCast(std.mem.bytesAsValue(inotify_event, self.buf[offset .. offset + @sizeOf(inotify_event)]));

                // Directories are ignored
                if (inotify_c.IN_ISDIR & @as(c_int, @intCast(event.mask)) != inotify_c.IN_ISDIR) {
                    for (self.watchers.items) |*watcher| {
                        if (watcher.fd == event.wd) {
                            // If the watched directory was deleted or moved, set fd to null to mark it as pending recreation
                            if (event.mask & inotify_c.IN_DELETE_SELF == inotify_c.IN_DELETE_SELF or
                                event.mask & inotify_c.IN_MOVE_SELF == inotify_c.IN_MOVE_SELF)
                            {
                                std.log.warn("Watched directory {s} deleted, starting recreation attempt loop", .{watcher.path});
                                std.posix.inotify_rm_watch(self.fd, watcher.fd.?);
                                watcher.fd = null;
                            } else if (watcher.name) |name| {
                                if (std.mem.eql(u8, name, event.getName().?)) {
                                    try events.append(Event{
                                        .watcher_id = watcher.id,
                                        .ancestor = watcher.path,
                                        .name = name,
                                        .mask = event.mask,
                                    });
                                }
                            } else {
                                try events.append(Event{
                                    .watcher_id = watcher.id,
                                    .ancestor = watcher.path,
                                    .name = event.getName() orelse unreachable,
                                    .mask = event.mask,
                                });
                            }
                        }
                    }
                }
                offset += @sizeOf(inotify_event) + event.len;
            }
        } else |err| {
            if (err != error.WouldBlock) {
                std.log.err("Unexpected inotify read error: {}", .{err});
            }
        }
        return events;
    }
};
