const std = @import("std");
const rl = @import("raylib");
const fs = std.fs;
const math = std.math;
const mem = std.mem;

const c = @cImport({
    @cInclude("webp/decode.h");
});

const ArrayList = std.ArrayList;
const Allocator = mem.Allocator;

const MAX_SCREEN_WIDTH = 2400;
const MAX_IMAGE_HEIGHT = 1350;
const PANE_HEIGHT = 40;
const MAX_SCREEN_HEIGHT = MAX_IMAGE_HEIGHT + PANE_HEIGHT;
const SCALE_RATIO = 0.4;

const WebpImgMagic = packed struct {
    magic1: u32,
    length: u32,
    magic2: u64,
};
const Image = struct {
    texture: rl.Texture2D,
    filename: [:0]const u8,
    width: usize,
    height: usize,
};

pub fn main() !void {
    const allocator = std.heap.c_allocator;

    const commands = @embedFile("./commands.json");
    var zlap = try @import("zlap").Zlap.init(allocator, commands);
    defer zlap.deinit();

    if (zlap.is_help) {
        std.debug.print("{s}\n", .{zlap.help_msg});
        return;
    }

    var filenames = try ArrayList([:0]const u8).initCapacity(allocator, 10);
    defer {
        for (filenames.items) |filename| {
            allocator.free(filename);
        }
        filenames.deinit();
    }

    const raw_filenames = zlap.main_args.get("FILENAMES") orelse {
        std.debug.print("ERROR: filename not found\n", .{});
        std.debug.print("{s}\n", .{zlap.help_msg});
        return error.FilenameNotFound;
    };

    for (raw_filenames.value.strings.items) |raw_filename| {
        const filename = try allocator.dupeZ(u8, raw_filename);
        errdefer allocator.free(filename);
        try filenames.append(filename);
    }

    rl.initWindow(MAX_SCREEN_WIDTH, MAX_SCREEN_HEIGHT, "Simple Image Viewer");
    defer rl.closeWindow();
    rl.setTargetFPS(60);

    const images = try getImagesList(allocator, filenames);
    defer {
        for (images.items) |img| {
            rl.unloadTexture(img.texture);
        }
        images.deinit();
    }

    var idx: usize = 0;
    var allow_scale: bool = false;
    while (!rl.windowShouldClose()) {
        const image = images.items[idx];

        switch (rl.getKeyPressed()) {
            .key_q => break,
            .key_a, .key_left => idx = if (idx == 0) images.items.len -| 1 else idx - 1,
            .key_d, .key_right => idx = if (idx + 1 >= images.items.len) 0 else idx + 1,
            .key_e => allow_scale = !allow_scale,
            else => {},
        }

        const scale_ratio =
            @as(f32, @floatFromInt(@intFromBool(allow_scale))) * SCALE_RATIO + 1.0;
        const img_width = @as(f32, @floatFromInt(image.width)) * scale_ratio;
        const img_height = @as(f32, @floatFromInt(image.height)) * scale_ratio;

        rl.setWindowSize(
            @intFromFloat(img_width),
            @as(i32, @intFromFloat(img_height)) + PANE_HEIGHT,
        );

        {
            rl.beginDrawing();
            defer rl.endDrawing();

            rl.clearBackground(rl.Color.black);
            rl.drawTextureEx(
                image.texture,
                .{ .x = 0.0, .y = 0.0 },
                0.0,
                scale_ratio,
                rl.Color.white,
            );
            rl.drawRectangleV(
                .{ .x = 0.0, .y = img_height },
                .{ .x = img_width, .y = @floatFromInt(PANE_HEIGHT) },
                rl.Color.black,
            );

            rl.drawText(
                image.filename,
                10,
                @as(i32, @intFromFloat(img_height)) + (PANE_HEIGHT >> 2),
                PANE_HEIGHT >> 1,
                rl.Color.white,
            );
        }
    }
}

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

fn getImagesList(
    allocator: Allocator,
    filenames: ArrayList([:0]const u8),
) !ArrayList(Image) {
    var images = try ArrayList(Image).initCapacity(allocator, filenames.items.len);
    errdefer {
        for (images.items) |img| {
            rl.unloadTexture(img.texture);
        }
        images.deinit();
    }

    for (filenames.items) |filename| {
        var img = if (try isWebpImage(filename))
            try getImageFromWebp(allocator, filename)
        else
            rl.loadImage(filename);
        defer rl.unloadImage(img);

        const img_width = @min(@divFloor(MAX_SCREEN_WIDTH, 10) * 9, img.width);
        const img_height = @min(@divFloor(MAX_IMAGE_HEIGHT, 10) * 9, img.height);
        rl.imageResize(&img, @intCast(img_width), @intCast(img_height));

        const texture = rl.loadTextureFromImage(img);
        errdefer rl.unloadTexture(texture);

        try images.append(.{
            .texture = texture,
            .filename = filename,
            .width = @intCast(img_width),
            .height = @intCast(img_height),
        });
    }

    return images;
}
