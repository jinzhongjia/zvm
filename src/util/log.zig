const std = @import("std");

/// log func for zvm
const log = std.log.scoped(.ZVM);

pub const info = log.info;
pub const warn = log.warn;
pub const err = log.err;
pub const debug = log.debug;

/// log fn
pub fn logFn(
    comptime message_level: std.log.Level,
    comptime scope: @TypeOf(.enum_literal),
    comptime format: []const u8,
    args: anytype,
) void {
    if (scope != .ZVM)
        return std.log.defaultLog(message_level, scope, format, args);

    if (message_level == .err) {
        const stderr = std.io.getStdErr().writer();
        var err_bw = std.io.bufferedWriter(stderr);
        const err_writer = err_bw.writer();
        err_writer.print("Error:" ++ format ++ "\n", args) catch return;
        err_bw.flush() catch return;
        return;
    }

    const stdout = std.io.getStdOut().writer();
    var out_bw = std.io.bufferedWriter(stdout);
    const out_writer = out_bw.writer();

    if (message_level == .debug) {
        out_writer.print("Debug:" ++ format ++ "\n", args) catch return;
    } else if (message_level == .warn) {
        out_writer.print("Warning:" ++ format ++ "\n", args) catch return;
    } else {
        out_writer.print(format ++ "\n", args) catch return;
    }

    out_bw.flush() catch return;
}
