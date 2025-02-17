const std = @import("std");
const myzql = @import("myzql");

const TOKEN_AGE = 604800; // A week, FIXME: A proper time should be determined/should be configurable

/// Job that needs to be ran regularly to clean up expired auth tokens
pub fn cron(allocator: std.mem.Allocator, db_conn: *myzql.conn.Conn) !void {
    var prepare_res = try db_conn.prepare(allocator, "DELETE FROM auth_tokens WHERE last_used < (NOW() - INTERVAL ? SECOND)");
    defer prepare_res.deinit(allocator);
    const stmt = try prepare_res.expect(.stmt);

    const res = try db_conn.execute(&stmt, .{TOKEN_AGE});
    _ = try res.expect(.ok);
}
