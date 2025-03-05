const std = @import("std");
const httpz = @import("httpz");
const myzql = @import("myzql");
const yazap = @import("yazap");
const toml = @import("zig-toml");

const auth = @import("auth.zig");
const cron = @import("cron.zig");
const databases = @import("databases.zig");

const Config = struct {
    registrations_enabled: bool,
    port: u16,
};

/// All prepared MySQL statements in a single place
const PreparedStatements = struct {
    sel_manifests: myzql.result.PreparedStatement,
    sel_user: myzql.result.PreparedStatement,
    upd_token: myzql.result.PreparedStatement,
    sel_pass: myzql.result.PreparedStatement,
    ins_token: myzql.result.PreparedStatement,
    ins_user: myzql.result.PreparedStatement,
    ins_or_upd_manifest: myzql.result.PreparedStatement,
    del_manifest: myzql.result.PreparedStatement,

    fn init(c: *myzql.conn.Conn, allocator: std.mem.Allocator) !PreparedStatements {
        const sel_manifests = try (try c.prepare(
            allocator,
            "SELECT name, UNIX_TIMESTAMP(modified) FROM db_manifests WHERE username = ?",
        )).expect(.stmt);
        const sel_user = try (try c.prepare(
            allocator,
            "SELECT username FROM auth_tokens WHERE token = ?",
        )).expect(.stmt);
        const upd_token = try (try c.prepare(
            allocator,
            "UPDATE auth_tokens SET last_used = NOW() WHERE token = ?",
        )).expect(.stmt);
        const sel_pass = try (try c.prepare(
            allocator,
            "SELECT pass_hash FROM users WHERE username = ?",
        )).expect(.stmt);
        const ins_token = try (try c.prepare(
            allocator,
            "INSERT INTO auth_tokens VALUES (?, ?, NOW())",
        )).expect(.stmt);
        const ins_user = try (try c.prepare(
            allocator,
            "INSERT INTO users (username, pass_hash) VALUES (?, ?)",
        )).expect(.stmt);
        const ins_or_upd_manifest = try (try c.prepare(
            allocator,
            "INSERT INTO db_manifests VALUES (?, ?, NOW()) ON DUPLICATE KEY UPDATE modified = NOW()",
        )).expect(.stmt);
        const del_manifest = try (try c.prepare(
            allocator,
            "DELETE FROM db_manifests WHERE username = ? AND name = ?",
        )).expect(.stmt);

        return PreparedStatements{
            .sel_manifests = sel_manifests,
            .sel_user = sel_user,
            .upd_token = upd_token,
            .sel_pass = sel_pass,
            .ins_token = ins_token,
            .ins_user = ins_user,
            .ins_or_upd_manifest = ins_or_upd_manifest,
            .del_manifest = del_manifest,
        };
    }
};

pub const App = struct {
    db_conn: myzql.conn.Conn,
    config: Config,
    stmts: PreparedStatements,

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

    var parser = toml.Parser(Config).init(allocator);
    defer parser.deinit();

    var result = try parser.parseFile("config.toml");
    defer result.deinit();

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
        var app = App{
            .stmts = try PreparedStatements.init(&db_conn, allocator),
            .db_conn = db_conn,
            .config = result.value,
        };

        var server = try httpz.Server(*App).init(
            allocator,
            .{ .port = result.value.port },
            &app,
        );
        defer {
            server.stop();
            server.deinit();
        }

        var router = server.router(.{});
        router.post("/auth/register", auth.register, .{});
        router.get("/auth/token", auth.createToken, .{});
        router.get("/databases/manifest", databases.manifest, .{});
        router.get("/databases/download/:name", databases.download, .{});
        router.post("/databases/upload/:name", databases.upload, .{});
        router.delete("/databases/delete/:name", databases.delete, .{});

        try server.listen();
    }
}
