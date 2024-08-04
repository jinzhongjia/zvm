const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const tools = @import("tools.zig");
const sha2 = std.crypto.hash.sha2;
const architecture = @import("architecture.zig");
const alias = @import("alias.zig");
const lib = @import("extract.zig");
const config = @import("config.zig");

pub fn content(allocator: std.mem.Allocator, version: []const u8, url: []const u8) !?[32]u8 {
    assert(version.len > 0);
    assert(url.len > 0);

    const root_node = std.Progress.start(.{
        .root_name = "",
        .estimated_total_items = 4,
    });
    defer root_node.end();

    const data_allocator = tools.get_allocator();
    const version_path = try tools.get_zvm_path_segment(data_allocator, "versions");
    defer data_allocator.free(version_path);

    try tools.try_create_path(version_path);

    const uri = std.Uri.parse(url) catch unreachable;
    const version_folder_name = try std.fmt.allocPrint(allocator, "versions/{s}", .{version});
    defer allocator.free(version_folder_name);

    const version_folder_path = try tools.get_zvm_path_segment(data_allocator, version_folder_name);
    defer data_allocator.free(version_folder_path);

    if (tools.does_path_exist(version_folder_path)) {
        std.debug.print("→ Version {s} is already installed.\n", .{version});
        std.debug.print("Do you want to reinstall? (\x1b[1mY\x1b[0mes/\x1b[1mN\x1b[0mo): ", .{});

        if (!confirm_user_choice()) {
            std.debug.print("Do you want to set version {s} as the default? (\x1b[1mY\x1b[0mes/\x1b[1mN\x1b[0mo): ", .{version});
            if (confirm_user_choice()) {
                try alias.set_zig_version(version);
                std.debug.print("Version {s} has been set as the default.\n", .{version});
                return null;
            } else {
                std.debug.print("Aborting...\n", .{});
                return null;
            }
        }

        try std.fs.cwd().deleteTree(version_folder_path);
    } else {
        std.debug.print("→ Version {s} is not installed. Beginning download...\n", .{version});
    }

    const computed_hash = try download_and_extract(allocator, uri, version_path, version, root_node);

    var set_version_node = root_node.start("Setting Version", 1);
    try alias.set_zig_version(version);
    set_version_node.end();

    return computed_hash;
}

fn confirm_user_choice() bool {
    var buffer: [4]u8 = undefined;
    _ = std.io.getStdIn().read(buffer[0..]) catch return false;

    return std.ascii.toLower(buffer[0]) == 'y';
}

fn download_and_extract(
    allocator: std.mem.Allocator,
    uri: std.Uri,
    version_path: []const u8,
    version: []const u8,
    root_node: std.Progress.Node,
) ![32]u8 {
    assert(version_path.len > 0);
    assert(version.len > 0);

    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    var header_buffer: [262144]u8 = undefined; // 256 * 1024 = 262kb

    var req = try client.open(.GET, uri, .{ .server_header_buffer = &header_buffer });
    defer req.deinit();

    try req.send();
    try req.wait();
    try std.testing.expect(req.response.status == .ok);

    const zvm_path = try tools.get_zvm_path_segment(allocator, "");
    defer allocator.free(zvm_path);

    var zvm_dir = std.fs.cwd().makeOpenPath(zvm_path, .{}) catch |err| {
        std.debug.print("sorry, open zvm path failed, erro is {}\n", .{err});
        std.process.exit(1);
    };

    defer zvm_dir.close();

    const platform_str = try architecture.platform_str(architecture.DetectParams{
        .os = builtin.os.tag,
        .arch = builtin.cpu.arch,
        .reverse = false,
    }) orelse unreachable;

    const file_name = try std.mem.concat(allocator, u8, &.{
        "zig-",
        platform_str,
        "-",
        version,
        ".",
        config.zig_archive_ext,
    });
    defer allocator.free(file_name);

    const total_size: usize = @intCast(req.response.content_length orelse 0);
    var downloaded_bytes: usize = 0;

    const download_message = try std.fmt.allocPrint(allocator, "Downloading Zig version {s} for platform {s}...", .{ version, platform_str });
    defer allocator.free(download_message);
    var download_node = root_node.start(download_message, total_size);

    const file_stream = try zvm_dir.createFile(file_name, .{});

    std.debug.print("Download complete, file written: {s}\n", .{file_name});

    var sha256 = sha2.Sha256.init(.{});

    while (true) {
        var buffer: [8192]u8 = undefined;
        const bytes_read = try req.reader().read(buffer[0..]);
        if (bytes_read == 0) break;

        downloaded_bytes += bytes_read;
        download_node.setCompletedItems(downloaded_bytes);
        sha256.update(buffer[0..bytes_read]);
        try file_stream.writeAll(buffer[0..bytes_read]);
    }
    file_stream.close();

    download_node.end();

    var extract_node = root_node.start("Extracting", 1);
    const data_allocator = tools.get_allocator();

    const downloaded_file_path = try std.fs.path.join(data_allocator, &.{ zvm_path, file_name });
    defer data_allocator.free(downloaded_file_path);

    std.debug.print("Downloaded file path: {s}\n", .{downloaded_file_path});

    const folder_path = try std.fs.path.join(allocator, &.{ version_path, version });
    defer allocator.free(folder_path);

    std.fs.makeDirAbsolute(folder_path) catch |err| {
        std.debug.print("makeDirAbsolute: {any}\n", .{err});
    };

    const zvm_dir_version = try std.fs.openDirAbsolute(folder_path, .{});
    const downloaded_file = try zvm_dir.openFile(downloaded_file_path, .{});
    defer downloaded_file.close();

    if (builtin.os.tag == .windows) {
        try lib.extract_zip_dir(zvm_dir_version, downloaded_file);
    } else {
        try lib.extract_tarxz_to_dir(allocator, zvm_dir_version, downloaded_file);
    }

    extract_node.end();

    var result: [32]u8 = undefined;
    sha256.final(&result);
    return result;
}

fn open_or_create_zvm_dir() !std.fs.Dir {
    const allocator = tools.get_allocator();
    const zvm_path = try tools.get_zvm_path_segment(allocator, "");
    defer allocator.free(zvm_path);

    return try std.fs.cwd().makeOpenPath(zvm_path, .{});
}
