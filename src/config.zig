const std = @import("std");
const builtin = @import("builtin");
const options = @import("options");

pub const log = std.log.scoped(.zvm);
pub const log_level: std.log.Level = @enumFromInt(@intFromEnum(options.log_level));
pub const version = options.version;

pub var stdout: std.io.BufferedWriter(4096, std.fs.File.Writer) = undefined;
pub var stderr: std.io.BufferedWriter(4096, std.fs.File.Writer) = undefined;

/// Memory allocator used by the entire zvm system
pub var allocator: std.mem.Allocator = undefined;
pub var home_dir: []const u8 = undefined;

/// the zig version url
pub const zig_url = "https://ziglang.org/download/index.json";
/// the zls verison url
pub const zls_url = "https://zigtools-releases.nyc3.digitaloceanspaces.com/zls/index.json";
