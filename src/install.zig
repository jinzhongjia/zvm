//! This file is used to install zig or zls
const std = @import("std");
const builtin = @import("builtin");
const config = @import("config.zig");
const alias = @import("alias.zig");
const meta = @import("meta.zig");
const util_arch = @import("util/arch.zig");
const util_data = @import("util/data.zig");
const util_extract = @import("util/extract.zig");
const util_tool = @import("util/tool.zig");
const util_http = @import("util/http.zig");

const Version = struct {
    name: []const u8,
    date: ?[]const u8,
    tarball: ?[]const u8,
    shasum: ?[]const u8,
};

/// try install specified version
pub fn install(version: []const u8, is_zls: bool) !void {
    if (is_zls) {
        try install_zls(version);
    } else {
        try install_zig(version);
    }
}

/// Try to install the specified version of zig
fn install_zig(version: []const u8) !void {
    const allocator = util_data.get_allocator();

    const platform_str = try util_arch.platform_str(.{
        .os = builtin.os.tag,
        .arch = builtin.cpu.arch,
        .reverse = true,
    }) orelse unreachable;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const arena_allocator = arena.allocator();

    // get version path
    const version_path = try util_data.get_zvm_zig_version(arena_allocator);
    // get extract path
    const extract_path = try std.fs.path.join(arena_allocator, &.{ version_path, version });

    if (util_tool.does_path_exist(extract_path)) {
        try alias.set_version(version, false);
        return;
    }

    // get version data
    const version_data: meta.Zig.VersionData = blk: {
        const res = try util_http.http_get(arena_allocator, config.zig_url);
        var zig_meta = try meta.Zig.init(res, arena_allocator);
        const tmp_val = try zig_meta.get_version_data(version, platform_str, arena_allocator);
        break :blk tmp_val orelse return error.UnsupportedVersion;
    };

    const reverse_platform_str = try util_arch.platform_str(.{
        .os = builtin.os.tag,
        .arch = builtin.cpu.arch,
        .reverse = false,
    }) orelse unreachable;

    const file_name = try std.mem.concat(
        arena_allocator,
        u8,
        &.{ "zig-", reverse_platform_str, "-", version, ".", config.archive_ext },
    );

    const parsed_uri = std.Uri.parse(version_data.tarball) catch unreachable;
    const new_file = try util_http.download(parsed_uri, file_name, version_data.shasum, version_data.size);
    defer new_file.close();

    try util_tool.try_create_path(extract_path);
    const extract_dir = try std.fs.openDirAbsolute(extract_path, .{});

    try util_extract.extract(extract_dir, new_file, if (builtin.os.tag == .windows) .zip else .tarxz, false);

    // mv
    const sub_path = try std.fs.path.join(arena_allocator, &.{
        extract_path, try std.mem.concat(
            arena_allocator,
            u8,
            &.{ "zig-", reverse_platform_str, "-", version },
        ),
    });
    defer std.fs.deleteTreeAbsolute(sub_path) catch unreachable;

    try util_tool.copy_dir(sub_path, extract_path);

    try alias.set_version(version, false);
}

/// Try to install the specified version of zls
fn install_zls(version: []const u8) !void {
    const true_version = blk: {
        if (util_tool.eql_str("master", version)) {
            std.debug.print("Sorry, the 'install zls' feature is not supported at this time. Please compile zls locally.", .{});
            return;
        }

        for (config.zls_list_1, 0..) |val, i| {
            if (util_tool.eql_str(val, version))
                break :blk config.zls_list_2[i];
        }
        break :blk version;
    };
    const allocator = util_data.get_allocator();

    const reverse_platform_str = try util_arch.platform_str(.{
        .os = builtin.os.tag,
        .arch = builtin.cpu.arch,
        .reverse = true,
    }) orelse unreachable;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const arena_allocator = arena.allocator();

    // get version path
    const version_path = try util_data.get_zvm_zls_version(arena_allocator);
    // get extract path
    const extract_path = try std.fs.path.join(arena_allocator, &.{ version_path, true_version });

    if (util_tool.does_path_exist(extract_path)) {
        try alias.set_version(true_version, true);
        return;
    }

    // get version data
    const version_data: meta.Zls.VersionData = blk: {
        const res = try util_http.http_get(arena_allocator, config.zls_url);
        var zls_meta = try meta.Zls.init(res, arena_allocator);
        const tmp_val = try zls_meta.get_version_data(true_version, reverse_platform_str, arena_allocator);
        break :blk tmp_val orelse return error.UnsupportedVersion;
    };

    const file_name = try std.mem.concat(
        arena_allocator,
        u8,
        &.{ "zls-", reverse_platform_str, "-", true_version, ".", config.archive_ext },
    );

    const parsed_uri = std.Uri.parse(version_data.tarball) catch unreachable;
    const new_file = try util_http.download(parsed_uri, file_name, null, version_data.size);
    defer new_file.close();

    try util_tool.try_create_path(extract_path);

    const extract_dir = try std.fs.openDirAbsolute(extract_path, .{});
    try util_extract.extract(extract_dir, new_file, if (builtin.os.tag == .windows)
        .zip
    else
        .tarxz, true);

    try alias.set_version(true_version, true);
}

pub fn build_zls() !void {}
