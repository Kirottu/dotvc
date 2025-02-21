const std = @import("std");
const httpz = @import("httpz");
const myzql = @import("myzql");
const yazap = @import("yazap");

const auth = @import("auth.zig");
const cron = @import("cron.zig");
const databases = @import("databases.zig");

pub const App = struct {
    db_conn: myzql.conn.Conn,

    pub fn init(_: std.mem.Allocator, db_conn: myzql.conn.Conn) !App {
        return App{
            .db_conn = db_conn,
        };
    }

    pub fn deinit(self: *App) void {
        self.db_conn.deinit();
    }

    fn logRequest(_: *App, req: *httpz.Request, res: *httpz.Response) void {
        std.log.info("{} - {} {s}", .{
            res.status,
            req.method,
            req.url.path,
        });
    }

    pub fn dispatch(self: *App, action: httpz.Action(*App), req: *httpz.Request, res: *httpz.Response) !void {
        try action(self, req, res);

        self.logRequest(req, res);
    }

    pub fn notFound(self: *App, req: *httpz.Request, res: *httpz.Response) !void {
        res.status = 404;
        res.body = "Not found";
        self.logRequest(req, res);
    }

    pub fn uncaughtError(self: *App, req: *httpz.Request, res: *httpz.Response, err: anyerror) void {
        res.body = std.fmt.allocPrint(res.arena, "Internal error occurred: {}", .{err}) catch {
            return;
        };
        res.status = 500;
        self.logRequest(req, res);
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer {
        _ = gpa.detectLeaks();
    }

    const allocator = gpa.allocator();

    var yazap_app = yazap.App.init(allocator, "DotVC server", "DotVC server software to facilitate sync between clients");
    defer yazap_app.deinit();

    try yazap_app.rootCommand().addArg(yazap.Arg.booleanOption("cron", null, "Run periodical cleanup job"));

    const matches = try yazap_app.parseProcess();

    var db_conn = try myzql.conn.Conn.init(allocator, &.{
        .username = "dotvc",
        .password = "dotvc",
        .database = "dotvc",
    });

    try db_conn.ping();

    if (matches.containsArg("cron")) {
        try cron.cron(allocator, &db_conn);
    } else {
        var app = try App.init(allocator, db_conn);

        var server = try httpz.Server(*App).init(allocator, .{ .port = 3001 }, &app);
        defer {
            server.stop();
            server.deinit();
        }

        var router = server.router(.{});
        router.post("/auth/register", auth.register, .{});
        router.get("/auth/token", auth.createToken, .{});
        router.get("/databases/manifest", databases.manifest, .{});
        router.get("/databases/download/:hostname", databases.download, .{});
        router.post("/databases/upload/:hostname", databases.upload, .{});
        router.delete("/databases/delete/:hostname", databases.delete, .{});

        try server.listen();
    }
}
