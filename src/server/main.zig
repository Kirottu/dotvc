const std = @import("std");
const httpz = @import("httpz");
const myzql = @import("myzql");
pub const hiredis = @cImport(@cInclude("hiredis/hiredis.h"));

const auth = @import("auth.zig");

pub const RequestContext = struct {
    app: *App,
};

const AppError = error{
    RedisError,
};

const App = struct {
    db_conn: myzql.conn.Conn,
    /// Redis is used to cache authenticated sessions
    redis_ctx: *hiredis.redisContext,
    auth_endpoints: []const []const u8,

    pub fn init(allocator: std.mem.Allocator, auth_endpoints: []const []const u8) !App {
        var db_conn = try myzql.conn.Conn.init(allocator, &.{
            .username = "dotvc",
            .password = "dotvc",
            .database = "dotvc",
        });
        const redis_ctx = hiredis.redisConnect("127.0.0.1", 6379);

        if (redis_ctx != null and redis_ctx.*.err != 0) {
            std.log.err("Failed to connect to redis: {s}", .{redis_ctx.*.errstr});
            return AppError.RedisError;
        }

        try db_conn.ping();

        return App{
            .db_conn = db_conn,
            .auth_endpoints = auth_endpoints,
            .redis_ctx = redis_ctx,
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
    var app = try App.init(allocator, &.{"/restricted"});

    var server = try httpz.Server(*App).init(allocator, .{ .port = 3001 }, &app);
    defer {
        server.stop();
        server.deinit();
    }

    var router = server.router(.{});
    router.get("/hello/world", hello, .{});
    router.post("/auth/register", auth.register, .{});
    router.get("/auth/token", auth.token, .{});
    router.get("/restricted", restricted, .{});

    try server.listen();
}

pub fn hello(_: *RequestContext, _: *httpz.Request, res: *httpz.Response) !void {
    try res.chunk("Hello world");
}

/// Test endpoint for authentication
pub fn restricted(_: *RequestContext, _: *httpz.Request, res: *httpz.Response) !void {
    res.body = "You've entered the cum zone";
}
