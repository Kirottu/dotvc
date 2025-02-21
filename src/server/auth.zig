const std = @import("std");
const httpz = @import("httpz");
const myzql = @import("myzql");
const root = @import("main.zig");

const argon2 = std.crypto.pwhash.argon2;
const hiredis = root.hiredis;

const ResultSet = myzql.result.ResultSet;
const TextResultRow = myzql.result.TextResultRow;

const TOKEN_LEN = 32;
const TOKEN_CHARS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";

pub const MIN_USERNAME_LEN = 6;
pub const MIN_PASSWORD_LEN = 8;

/// Generate a token based on credentials that will be used for any further authenticated request
pub fn createToken(app: *root.App, req: *httpz.Request, res: *httpz.Response) !void {
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

    const rec = blk: {
        const stmt = try (try app.db_conn.prepare(res.arena, "SELECT pass_hash FROM users WHERE username = ?")).expect(.stmt);

        const db_res = try app.db_conn.executeRows(&stmt, .{username});
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
        break :blk rec;
    };

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

    const stmt = try (try app.db_conn.prepare(res.arena, "INSERT INTO auth_tokens VALUES (?, ?, NOW())")).expect(.stmt);
    const db_res = try app.db_conn.execute(&stmt, .{ new_token, username });
    _ = try db_res.expect(.ok);

    res.body = new_token;
}

/// Function for registering a user on the server
/// NOTE: This endpoint should be guarded with a rate limit
pub fn register(app: *root.App, req: *httpz.Request, res: *httpz.Response) !void {
    if (!app.config.registrations_enabled) {
        res.status = 403;
        res.body = "Registration is disabled on this server";
        return;
    }

    const query = try req.query();
    const username = query.get("username") orelse {
        res.status = 400;
        res.body = "Missing username from query parameters";
        return;
    };
    const password = query.get("password") orelse {
        res.status = 400;
        res.body = "Missing password from query parameters";
        return;
    };

    if (username.len < MIN_USERNAME_LEN) {
        res.status = 400;
        res.body = "Username is too short";
        return;
    }
    if (password.len < MIN_PASSWORD_LEN) {
        res.status = 400;
        res.body = "Password is too short";
        return;
    }

    var buf: [256]u8 = undefined;

    const out = try argon2.strHash(password, .{
        .allocator = res.arena,
        .params = argon2.Params.owasp_2id,
    }, &buf);

    const stmt = try (try app.db_conn.prepare(
        res.arena,
        "INSERT INTO users (username, pass_hash) VALUES (?, ?)",
    )).expect(.stmt);

    const db_res = try app.db_conn.execute(&stmt, .{ username, out });
    if (db_res == .err) {
        // 1062: Duplicate entry for key, aka user already exists
        if (db_res.err.error_code == 1062) {
            res.status = 400;
            res.body = "Username already taken";
        } else {
            res.status = 500;
            res.body = "Internal database error";
        }
    }
}

const AuthenticationMethod = enum {
    header,
    cookie,
};

/// Authenticate user based on token
///
/// Must be provided an arena allocator, otherwise will leak memory
pub fn authenticate(app: *root.App, req: *httpz.Request, res: *httpz.Response, method: AuthenticationMethod) !?[]const u8 {
    const token = switch (method) {
        .header => req.header("token"),
        .cookie => unreachable,
    } orelse {
        res.status = 401;
        res.body = "No token provided";
        return null;
    };

    const rec = blk: {
        const stmt = try (try app.db_conn.prepare(
            res.arena,
            "SELECT username FROM auth_tokens WHERE token = ?",
        )).expect(.stmt);

        const rows = try app.db_conn.executeRows(&stmt, .{token});
        const row = try rows.rows.first() orelse {
            res.status = 401;
            res.body = "Invalid token";
            return null;
        };

        const Record = struct {
            username: []const u8,
        };

        const rec = try row.structCreate(Record, res.arena);
        break :blk rec;
    };

    const stmt = try (try app.db_conn.prepare(
        res.arena,
        "UPDATE auth_tokens SET last_used = NOW() WHERE token = ?",
    )).expect(.stmt);

    const db_res = try app.db_conn.execute(&stmt, .{token});
    _ = try db_res.expect(.ok);

    return rec.username;
}
