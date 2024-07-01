const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");

/// init the data
pub fn dataInit(new_allocator: std.mem.Allocator) !void {
    // setting the stdout
    const out = std.io.getStdOut().writer();
    config.stdout = std.io.bufferedWriter(out);

    // setting the stderr
    const err = std.io.getStdErr().writer();
    config.stderr = std.io.bufferedWriter(err);

    config.allocator = new_allocator;
    // setting the home dir
    config.home_dir = if (builtin.os.tag == .windows)
        try std.process.getEnvVarOwned(config.allocator, "USERPROFILE")
    else
        std.posix.getenv("HOME") orelse ".";
}

/// deinit the data
pub fn dataDeinit() void {
    if (builtin.os.tag == .windows)
        config.allocator.free(config.home_dir);
}

/// get home dir
pub fn getHome() []const u8 {
    return config.home_dir;
}

/// get the allocator
pub fn getAllocator() std.mem.Allocator {
    return config.allocator;
}

pub fn printOut(comptime format: []const u8, args: anytype) !void {
    try config.stdout.writer().print(format, args);
}

pub fn printOutln(comptime format: []const u8, args: anytype) !void {
    try config.stdout.writer().print(format ++ "\n", args);
    try flushOut();
}

pub fn flushOut() !void {
    try config.stdout.flush();
}

pub fn printErr(comptime format: []const u8, args: anytype) !void {
    try config.stderr.writer().print(format, args);
}

pub fn printErrln(comptime format: []const u8, args: anytype) !void {
    try config.stderr.writer().print(format ++ "\n", args);
    try flushErr();
}

pub fn flushErr() !void {
    try config.stderr.flush();
}

pub const logdebug = config.log.debug;
pub const loginfo = config.log.info;
pub const logwarn = config.log.warn;
pub const logerr = config.log.err;

pub fn getZvmPathSegment(_allocator: std.mem.Allocator, segment: []const u8) ![]u8 {
    return std.fs.path.join(
        _allocator,
        &[_][]const u8{ getHome(), ".zm", segment },
    );
}

pub fn getVersion() std.SemanticVersion {
    return config.version;
}
