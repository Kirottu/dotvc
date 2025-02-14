const std = @import("std");
const httpz = @import("httpz");
const myzql = @import("myzql");

const argon2 = std.crypto.pwhash.argon2;

const RequestContext = struct {
    app: *App,
};

const App = struct {
    db_conn: myzql.conn.Conn,

    pub fn init(allocator: std.mem.Allocator) !App {
        var db_conn = try myzql.conn.Conn.init(allocator, &.{
            .username = "dotvc",
            .password = "dotvc",
            .database = "dotvc",
        });

        try db_conn.ping();

        return App{
            .db_conn = db_conn,
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
    var app = try App.init(allocator);

    var server = try httpz.Server(*App).init(allocator, .{ .port = 3001 }, &app);
    defer {
        server.stop();
        server.deinit();
    }

    var router = server.router(.{});
    router.get("/hello/world", hello, .{});
    router.post("/register", register, .{});

    try server.listen();
}

pub fn hello(_: *RequestContext, _: *httpz.Request, res: *httpz.Response) !void {
    try res.chunk("Hello world");
}

pub fn register(ctx: *RequestContext, req: *httpz.Request, res: *httpz.Response) !void {
    const query = try req.query();
    const username = query.get("username") orelse {
        res.status = 400;
        return;
    };
    const password = query.get("username") orelse {
        res.status = 400;
        return;
    };

    var buf: [256]u8 = undefined;

    const out = try argon2.strHash(password, .{
        .allocator = res.arena,
        .params = argon2.Params.owasp_2id,
    }, &buf);

    const stmt = try (try ctx.app.db_conn.prepare(
        res.arena,
        "INSERT INTO users (username, pass_hash) VALUES (?, ?)",
    )).expect(.stmt);

    const db_res = try ctx.app.db_conn.execute(&stmt, .{ username, out });
    _ = try db_res.expect(.ok);
}
