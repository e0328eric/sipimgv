const std = @import("std");
const rl = @import("raylib");
const fs = std.fs;
const math = std.math;
const mem = std.mem;

const c = @cImport({
    @cInclude("webp/decode.h");
});

const Allocator = mem.Allocator;

const MAX_SCREEN_WIDTH = 2400;
const MAX_SCREEN_HEIGHT = 1600;

const WebpImgMagic = packed struct { magic1: u32, length: u32, magic2: u64 };

fn isWebpImage(filename: []const u8) !bool {
    var webp_file = try fs.cwd().openFile(filename, .{});
    defer webp_file.close();

    var buf = [_]u8{0} ** @sizeOf(WebpImgMagic);
    _ = try webp_file.read(&buf);

    const webp_magic_data = @as(*WebpImgMagic, @ptrCast(@alignCast(&buf))).*;

    return mem.nativeToLittle(u32, webp_magic_data.magic1) == 0x46464952 and
        mem.nativeToLittle(u64, webp_magic_data.magic2) == 0x2038505650424557;
}

fn getImageFromWebp(allocator: Allocator, filename: []const u8) !rl.Image {
    var webp_file = try fs.cwd().openFile(filename, .{});
    defer webp_file.close();

    const content = try webp_file.readToEndAlloc(allocator, math.maxInt(usize));
    defer allocator.free(content);

    var width: c_int = undefined;
    var height: c_int = undefined;
    const raw_rgba_data = c.WebPDecodeRGBA(
        content.ptr,
        content.len,
        &width,
        &height,
    );
    defer c.WebPFree(raw_rgba_data);

    const output_img = rl.genImageColor(@intCast(width), @intCast(height), rl.Color.blank);
    errdefer rl.unloadImage(output_img);

    @memcpy(
        @as([*]u8, @ptrCast(@alignCast(output_img.data))),
        raw_rgba_data[0 .. @as(usize, @intCast(width)) *
            @as(usize, @intCast(height)) * @sizeOf(rl.Color)],
    );

    return output_img;
}

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    const commands = @embedFile("./commands.json");
    var zlap = try @import("zlap").Zlap.init(allocator, commands);
    defer zlap.deinit();

    if (zlap.is_help) {
        std.debug.print("{s}\n", .{zlap.help_msg});
        return;
    }

    const filename = blk: {
        const raw_filename = zlap.main_args.get("FILENAME") orelse {
            std.debug.print("ERROR: filename not found\n", .{});
            std.debug.print("{s}\n", .{zlap.help_msg});
            return error.FilenameNotFound;
        };

        if (mem.eql(u8, raw_filename.value.string, "")) {
            std.debug.print("ERROR: filename not found\n", .{});
            std.debug.print("{s}\n", .{zlap.help_msg});
            return error.FilenameNotFound;
        }

        break :blk try allocator.dupeZ(u8, raw_filename.value.string);
    };
    defer allocator.free(filename);

    rl.initWindow(MAX_SCREEN_WIDTH, MAX_SCREEN_HEIGHT, "Simple Image Viewer");
    defer rl.closeWindow();
    rl.setTargetFPS(60);

    var img = if (try isWebpImage(filename))
        try getImageFromWebp(allocator, filename)
    else
        rl.loadImage(filename);

    const new_width = @min(@divFloor(MAX_SCREEN_WIDTH, 10) * 9, img.width);
    const new_height = @min(@divFloor(MAX_SCREEN_HEIGHT, 10) * 9, img.height);
    rl.imageResize(&img, @intCast(new_width), @intCast(new_height));

    const texture = rl.loadTextureFromImage(img);
    rl.unloadImage(img);
    defer rl.unloadTexture(texture);

    rl.setWindowSize(new_width, new_height);

    while (!rl.windowShouldClose()) {
        {
            rl.beginDrawing();
            defer rl.endDrawing();

            rl.clearBackground(rl.Color.black);
            rl.drawTexture(texture, 0, 0, rl.Color.white);
        }
    }
}
