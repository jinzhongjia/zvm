const std = @import("std");
const builtin = @import("builtin");
const tools = @import("tools.zig");

const xz = std.compress.xz;
const tar = std.tar;

/// extract tar.xz to dir
pub fn extract_tarxz_to_dir(allocator: std.mem.Allocator, out_dir: std.fs.Dir, file: std.fs.File) !void {
    var buffered_reader = std.io.bufferedReader(file.reader());

    var decompressed = try xz.decompress(allocator, buffered_reader.reader());
    defer decompressed.deinit();

    try tar.pipeToFileSystem(
        out_dir,
        decompressed.reader(),
        .{ .mode_mode = .executable_bit_only, .strip_components = 1 },
    );
}

/// extract zip to directory
pub fn extract_zip_dir(out_dir: std.fs.Dir, file: std.fs.File) !void {
    var arena = std.heap.ArenaAllocator.init(tools.get_allocator());
    defer arena.deinit();

    const allocator = arena.allocator();
    // for decompressing zig, we need to make a temp directory
    const tmp_path = try tools.get_zvm_path_segment(allocator, "tmpdir");
    defer std.fs.deleteDirAbsolute(tmp_path) catch unreachable;

    try std.fs.makeDirAbsolute(tmp_path);
    var tmp_dir = try std.fs.openDirAbsolute(tmp_path, .{ .iterate = true });

    // extract zig
    try std.zip.extract(tmp_dir, file.seekableStream(), .{});

    var iterate = tmp_dir.iterate();
    var sub_dir = blk: {
        const entry = try iterate.next() orelse return error.NotFound;
        break :blk try tmp_dir.openDir(entry.name, .{ .iterate = true });
    };
    defer sub_dir.close();

    const sub_path = try sub_dir.realpathAlloc(allocator, "");
    defer std.fs.deleteDirAbsolute(sub_path) catch unreachable;

    var sub_iterate = sub_dir.iterate();
    while (try sub_iterate.next()) |entry| {
        try std.fs.rename(sub_dir, entry.name, out_dir, entry.name);
    }
}
