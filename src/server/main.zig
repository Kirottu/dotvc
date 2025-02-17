const std = @import("std");
const httpz = @import("httpz");
const myzql = @import("myzql");
const yazap = @import("yazap");

const auth = @import("auth.zig");
const cron = @import("cron.zig");

pub const RequestContext = struct {
    app: *App,
};

const App = struct {
    db_conn: myzql.conn.Conn,
    /// Redis is used to cache authenticated sessions
    auth_endpoints: []const []const u8,

    pub fn init(_: std.mem.Allocator, db_conn: myzql.conn.Conn, auth_endpoints: []const []const u8) !App {
        return App{
            .db_conn = db_conn,
            .auth_endpoints = auth_endpoints,
        };
    }

    pub fn deinit(self: *App) void {
        self.db_conn.deinit();
    }

    fn logRequest(_: *App, req: *httpz.Request, res: *httpz.Response) void {
        std.log.info("{} - {s} {s}", .{
            res.status,
            if (req.method_string.len == 0) "GET" else req.method_string,
            req.url.path,
        });
    }

    pub fn dispatch(self: *App, action: httpz.Action(*RequestContext), req: *httpz.Request, res: *httpz.Response) !void {
        var ctx = RequestContext{ .app = self };
        try action(&ctx, req, res);

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
        var app = try App.init(allocator, db_conn, &.{"/restricted"});

        var server = try httpz.Server(*App).init(allocator, .{ .port = 3001 }, &app);
        defer {
            server.stop();
            server.deinit();
        }

        var router = server.router(.{});
        router.get("/hello/world", hello, .{});
        router.post("/auth/register", auth.register, .{});
        router.get("/auth/token", auth.create_token, .{});
        router.get("/restricted", restricted, .{});

        try server.listen();
    }
}

pub fn hello(_: *RequestContext, _: *httpz.Request, res: *httpz.Response) !void {
    try res.chunk("Hello world");
}

/// Test endpoint for authentication
pub fn restricted(ctx: *RequestContext, req: *httpz.Request, res: *httpz.Response) !void {
    const token = req.header("token") orelse {
        res.status = 401;
        res.body = "Missing `Token` header";
        return;
    };
    const username = try auth.authenticate(res.arena, ctx, token) orelse {
        res.status = 401;
        res.body = "Invalid token";
        return;
    };

    res.body = username;
}
