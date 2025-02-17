const std = @import("std");
const httpz = @import("httpz");
const myzql = @import("myzql");
const root = @import("main.zig");

const argon2 = std.crypto.pwhash.argon2;
const hiredis = root.hiredis;

const ResultSet = myzql.result.ResultSet;
const TextResultRow = myzql.result.TextResultRow;

const REDIS_TOKEN_PREFIX = "dotvc:token";
const TOKEN_LEN = 32;
const TOKEN_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
const TOKEN_AGE = 604800; // A week, FIXME: A proper time should be determined

/// Generate a temporary authentication token by authenticating with HTTP Basic authorization
pub fn token(ctx: *root.RequestContext, req: *httpz.Request, res: *httpz.Response) !void {
    const header = req.headers.get("authorization") orelse {
        res.status = 401;
        res.body = "Unauthorized: Missing `Authorization` header";
        return;
    };

    if (!std.mem.startsWith(u8, header, "Basic")) {
        res.status = 401;
        res.body = "Unauthorized: Invalid `Authorization` header";
        return;
    }

    var header_split = std.mem.splitScalar(u8, header, ' ');
    _ = header_split.next();
    const credentials_base64 = header_split.next() orelse {
        res.status = 401;
        res.body = "Unauthorized: Invalid `Authorization` header";
        return;
    };

    var decoder = std.base64.standard.Decoder;
    const len = try decoder.calcSizeForSlice(credentials_base64);

    const credentials = try res.arena.alloc(u8, len);

    try decoder.decode(credentials, credentials_base64);

    var cred_split = std.mem.splitScalar(u8, credentials, ':');

    const username = cred_split.next() orelse {
        res.status = 401;
        res.body = "Unauthorized: Invalid `Authorization` header";
        return;
    };

    const password = cred_split.next() orelse {
        res.status = 401;
        res.body = "Unauthorized: Invalid `Authorization` header";
        return;
    };

    const stmt = try (try ctx.app.db_conn.prepare(res.arena, "SELECT pass_hash FROM users WHERE username = ?")).expect(.stmt);

    const db_res = try ctx.app.db_conn.executeRows(&stmt, .{username});
    const rows = try db_res.expect(.rows);
    const row = try rows.first() orelse {
        res.status = 401;
        res.body = "Unauthorized: Invalid login details";
        return;
    };

    const Record = struct {
        pass_hash: []const u8,
    };

    const rec = try row.structCreate(Record, res.arena);

    argon2.strVerify(rec.pass_hash, password, .{ .allocator = res.arena }) catch {
        res.status = 401;
        res.body = "Unauthorized: Invalid login details";
        return;
    };

    var prng = std.Random.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        try std.posix.getrandom(std.mem.asBytes(&seed));
        break :blk seed;
    });
    const random = prng.random();

    var new_token = try res.arena.alloc(u8, TOKEN_LEN);

    for (0..TOKEN_LEN) |i| {
        const index = random.uintLessThan(usize, TOKEN_CHARS.len);
        new_token[i] = TOKEN_CHARS[index];
    }

    const reply = hiredis.redisCommand(ctx.app.redis_ctx, try std.fmt.allocPrintZ(
        res.arena,
        "SET {s}{s} {s}",
        .{
            REDIS_TOKEN_PREFIX,
            new_token,
            username,
        },
    ));

    if (reply == null) {
        std.log.err("Redis error: {s}", .{ctx.app.redis_ctx.errstr});
        res.status = 500;
        res.body = "Internal redis error occurred";
        return;
    }

    res.body = new_token;
}

/// Debug endpoint for creating users
/// FIXME: Needs to be deleted in favor of some other user creation method
pub fn register(ctx: *root.RequestContext, req: *httpz.Request, res: *httpz.Response) !void {
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
