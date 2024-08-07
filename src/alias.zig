const std = @import("std");
const assert = std.debug.assert;
const builtin = @import("builtin");
const tools = @import("tools.zig");

/// try to set zig version
/// this will use system link on unix-like
/// for windows, this will use copy dir
pub fn set_zig_version(version: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(tools.get_allocator());
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    const user_home = tools.get_home();
    const version_path = try std.fs.path.join(arena_allocator, &[_][]const u8{ user_home, ".zm", "versions", version });
    const symlink_path = try tools.get_zvm_path_segment(arena_allocator, "current");

    try update_current(version_path, symlink_path);
    try verify_zig_version(version);
}

fn update_current(zig_path: []const u8, symlink_path: []const u8) !void {
    assert(zig_path.len > 0);
    assert(symlink_path.len > 0);

    if (builtin.os.tag == .windows) {
        if (does_dir_exist(symlink_path)) try std.fs.deleteTreeAbsolute(symlink_path);
        try copy_dir(zig_path, symlink_path);
        return;
    }

    // when platform is not windows, this is execute here

    // when file exist(it is a systemlink), delete it
    if (does_file_exist(symlink_path)) try std.fs.cwd().deleteFile(symlink_path);

    // system link it
    try std.posix.symlink(zig_path, symlink_path);
}

/// Nested copy dir
/// only copy dir and file, no including link
fn copy_dir(source_dir: []const u8, dest_dir: []const u8) !void {
    assert(source_dir.len > 0);
    assert(dest_dir.len > 0);

    var source = try std.fs.openDirAbsolute(source_dir, .{ .iterate = true });
    defer source.close();

    std.fs.makeDirAbsolute(dest_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            tools.log.err("Failed to create directory: {s}", .{dest_dir});
            return err;
        },
    };

    var dest = try std.fs.openDirAbsolute(dest_dir, .{ .iterate = true });
    defer dest.close();

    var iterate = source.iterate();
    const allocator = tools.get_allocator();
    while (try iterate.next()) |entry| {
        const entry_name = entry.name;

        const source_sub_path = try std.fs.path.join(allocator, &.{ source_dir, entry_name });
        defer allocator.free(source_sub_path);

        const dest_sub_path = try std.fs.path.join(allocator, &.{ dest_dir, entry_name });
        defer allocator.free(dest_sub_path);

        switch (entry.kind) {
            .directory => try copy_dir(source_sub_path, dest_sub_path),
            .file => try std.fs.copyFileAbsolute(source_sub_path, dest_sub_path, .{}),
            else => {},
        }
    }
}

/// detect the dir whether exist
fn does_dir_exist(path: []const u8) bool {
    const result = blk: {
        std.fs.accessAbsolute(path, .{}) catch |err| {
            if (err == error.FileNotFound)
                break :blk false;
            break :blk true;
        };
        break :blk true;
    };
    return result;
}

/// detect the dir whether exist
fn does_file_exist(path: []const u8) bool {
    const result = blk: {
        std.fs.accessAbsolute(path, .{}) catch |err| {
            if (err == error.FileNotFound)
                break :blk false;
            break :blk true;
        };
        break :blk true;
    };
    return result;
}

/// verify current zig version
fn verify_zig_version(expected_version: []const u8) !void {
    const allocator = tools.get_allocator();

    const actual_version = try retrieve_zig_version(allocator);
    defer allocator.free(actual_version);

    assert(actual_version.len > 0);

    if (!std.mem.eql(u8, expected_version, actual_version)) {
        std.debug.print("Expected Zig version {s}, but currently using {s}. Please check.\n", .{ expected_version, actual_version });
    } else {
        std.debug.print("Now using Zig version {s}\n", .{expected_version});
    }
}

/// try to get zig version
fn retrieve_zig_version(allocator: std.mem.Allocator) ![]u8 {
    const home_dir = tools.get_home();
    const current_zig_path = try std.fs.path.join(allocator, &.{ home_dir, ".zm", "current", tools.zig_name });
    defer allocator.free(current_zig_path);

    // here we must use the absolute path, we can not just use "zig"
    // because child process will use environment variable
    var child_process = std.process.Child.init(&[_][]const u8{ current_zig_path, "version" }, allocator);

    child_process.stdin_behavior = .Close;
    child_process.stdout_behavior = .Pipe;
    child_process.stderr_behavior = .Close;

    try child_process.spawn();

    if (child_process.stdout) |stdout| {
        const version = try stdout.reader().readUntilDelimiterOrEofAlloc(allocator, '\n', 100) orelse return error.EmptyVersion;
        assert(version.len > 0);
        return version;
    }

    return error.FailedToReadVersion;
}
