const std = @import("std");
const builtin = @import("builtin");
const tools = @import("tools.zig");
const sha2 = @import("std").crypto.hash.sha2;
const architecture = @import("architecture.zig");
const Progress = std.Progress;
const alias = @import("alias.zig");
const hash = @import("hash.zig");
const lib = @import("extract.zig");
const crypto = std.crypto;

const archive_ext = if (builtin.os.tag == .windows) "zip" else "tar.xz";

pub fn content(allocator: std.mem.Allocator, version: []const u8, url: []const u8) !?[32]u8 {
    // Initialize the Progress structure
    const root_node = Progress.start(.{
        .root_name = "",
        .estimated_total_items = 4,
    });

    defer root_node.end();

    const data_allocator = tools.getAllocator();
    // Ensure version directory exists before any operation
    const version_path = try tools.getZvmPathSegment(data_allocator, "versions");
    defer data_allocator.free(version_path);

    std.fs.cwd().makePath(version_path) catch |err| switch (err) {
        error.PathAlreadyExists => {
            // The path already exists and is a directory, nothing to do here
            // std.debug.print("Versions directory already exists: {s}\n", .{version_path});
        },
        else => {
            std.debug.print("Failed to create versions directory: {}\n", .{err});
            return err;
        },
    };

    const uri = std.Uri.parse(url) catch unreachable;
    const version_folder_name = try std.fmt.allocPrint(allocator, "versions/{s}", .{version});
    defer allocator.free(version_folder_name);

    const version_folder_path = try tools.getZvmPathSegment(data_allocator, version_folder_name);
    defer data_allocator.free(version_folder_path);

    if (checkExistingVersion(version_folder_path)) {
        std.debug.print("→ Version {s} is already installed.\n", .{version});
        std.debug.print("Do you want to reinstall? (\x1b[1mY\x1b[0mes/\x1b[1mN\x1b[0mo): ", .{});

        if (!confirmUserChoice()) {
            // Ask if the version should be set as the default
            std.debug.print("Do you want to set version {s} as the default? (\x1b[1mY\x1b[0mes/\x1b[1mN\x1b[0mo): ", .{version});
            if (confirmUserChoice()) {
                try alias.setZigVersion(version);
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

    const computedHash = try downloadAndExtract(allocator, uri, version_path, version, root_node);

    var set_version_node = root_node.start("Setting Version", 1);
    try alias.setZigVersion(version);
    set_version_node.end();

    return computedHash;
}

fn checkExistingVersion(version_path: []const u8) bool {
    const openDirOptions = .{ .access_sub_paths = true, .no_follow = false };
    _ = std.fs.cwd().openDir(version_path, openDirOptions) catch return false;
    return true;
}

fn confirmUserChoice() bool {
    var buffer: [4]u8 = undefined;
    _ = std.io.getStdIn().read(buffer[0..]) catch return false;

    return std.ascii.toLower(buffer[0]) == 'y';
}

fn downloadAndExtract(
    allocator: std.mem.Allocator,
    uri: std.Uri,
    version_path: []const u8,
    version: []const u8,
    root_node: std.Progress.Node,
) ![32]u8 {
    var client = std.http.Client{ .allocator = allocator };
    defer client.deinit();

    // Read the response body with 256kb buffer allocation
    var headerBuffer: [262144]u8 = undefined; // 256 * 1024 = 262kb

    var req = try client.open(.GET, uri, .{ .server_header_buffer = &headerBuffer });
    defer req.deinit();

    try req.send();
    try req.wait();

    try std.testing.expect(req.response.status == .ok);

    var zvm_dir = try openOrCreateZvmDir();
    defer zvm_dir.close();

    const platform = try architecture.detect(allocator, architecture.DetectParams{ .os = builtin.os.tag, .arch = builtin.cpu.arch, .reverse = false }) orelse unreachable;
    defer allocator.free(platform);

    const file_name = try std.mem.concat(allocator, u8, &[_][]const u8{ "zig-", platform, "-", version, ".", archive_ext });
    defer allocator.free(file_name);

    const totalSize: usize = @intCast(req.response.content_length orelse 0);
    var downloadedBytes: usize = 0;

    const downloadMessage = try std.fmt.allocPrint(allocator, "Downloading Zig version {s} for platform {s}...", .{ version, platform });
    defer allocator.free(downloadMessage);
    var download_node = root_node.start(downloadMessage, totalSize);

    const file_stream = try zvm_dir.createFile(file_name, .{});
    defer file_stream.close();

    std.debug.print("Download complete, file written: {s}\n", .{file_name});

    var sha256 = sha2.Sha256.init(.{});

    while (true) {
        var buffer: [8192]u8 = undefined;
        const bytes_read = try req.reader().read(buffer[0..]);
        if (bytes_read == 0) break;

        downloadedBytes += bytes_read;

        download_node.setCompletedItems(downloadedBytes);

        sha256.update(buffer[0..bytes_read]);

        try file_stream.writeAll(buffer[0..bytes_read]);
    }

    download_node.end();

    var extract_node = root_node.start("Extracting", 1);

    // ~/.zm/versions/zig-macos-x86_64-0.10.0.tar.xz
    const data_allocator = tools.getAllocator();

    const zvm_path = try tools.getZvmPathSegment(data_allocator, "");
    defer data_allocator.free(zvm_path);

    const downloaded_file_path = try std.fs.path.join(data_allocator, &.{ zvm_path, file_name });
    defer data_allocator.free(downloaded_file_path);

    std.debug.print("Downloaded file path: {s}\n", .{downloaded_file_path});

    // Construct the full file path
    // example: ~/.zm/0.10.0
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

fn openOrCreateZvmDir() !std.fs.Dir {
    const zvm_path = try tools.getZvmPathSegment(tools.getAllocator(), "");
    defer tools.getAllocator().free(zvm_path);

    const openDirOptions = .{ .access_sub_paths = true, .no_follow = false };
    const potentialDir = std.fs.cwd().openDir(zvm_path, openDirOptions);

    if (potentialDir) |dir| {
        return dir;
    } else |err| switch (err) {
        error.FileNotFound => {
            std.debug.print("→ Directory not found. Creating: {s}...\n", .{zvm_path});

            if (std.fs.cwd().makeDir(zvm_path)) |_| {
                std.debug.print("✓ Directory created successfully: {s}\n", .{zvm_path});
            } else |errMakeDir| {
                std.debug.print("✗ Error: Failed to create directory. Reason: {}\n", .{errMakeDir});
            }

            return std.fs.cwd().openDir(zvm_path, openDirOptions);
        },
        else => |e| {
            std.debug.print("Unexpected error when checking directory: {}\n", .{e});
            return e;
        },
    }
}
