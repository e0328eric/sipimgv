const std = @import("std");
const builtin = @import("builtin");
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

const WebpImgMagic = packed struct {
    magic1: u32,
    length: u32,
    magic2: u64,
};
const Image = struct {
    texture: ?rl.Texture2D,
    filename: [:0]const u8,
    width: usize,
    height: usize,
};

pub fn main() !void {
    // change the console encoding into utf-8
    // One can find the magic number in here
    // https://learn.microsoft.com/en-us/windows/win32/intl/code-page-identifiers
    if (builtin.os.tag == .windows) {
        if (std.os.windows.kernel32.SetConsoleOutputCP(65001) == 0) {
            std.debug.print("ERROR: cannot set the codepoint into utf-8\n", .{});
            return error.FailedToSetUTF8Codepoint;
        }
    }

    const allocator = std.heap.c_allocator;

    const commands = @embedFile("./commands.json");
    var zlap = try @import("zlap").Zlap.init(allocator, commands);
    defer zlap.deinit();

    if (zlap.is_help) {
        std.debug.print("{s}\n", .{zlap.help_msg});
        return;
    }
    const mag_ratio_flag = zlap.main_flags.get("ratio") orelse return;
    const mag_ratio_raw = mag_ratio_flag.value.number;
    if (mag_ratio_raw <= 0) {
        std.debug.print("--ratio value must be positive\n", .{});
        return error.InvalidRatio;
    }
    const mag_ratio = @as(f32, @floatFromInt(mag_ratio_raw)) / 100.0;
    std.debug.print("{}\n", .{mag_ratio});

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

    const font = rl.loadFont("./fonts/NotoSansKR-Regular.ttf");
    defer rl.unloadFont(font);

    var images = try ArrayList(Image).initCapacity(allocator, filenames.items.len);
    for (filenames.items) |filename| {
        try images.append(.{
            .texture = null,
            .filename = filename,
            .width = 0,
            .height = 0,
        });
    }
    defer {
        for (images.items) |img| {
            if (img.texture) |texture| {
                rl.unloadTexture(texture);
            }
        }
        images.deinit();
    }
    try getImagesList(allocator, &images, filenames, 0, 10);

    var idx: usize = 0;
    var allow_scale: bool = false;
    var init_direction: enum { left, right } = .right;
    while (!rl.windowShouldClose()) {
        switch (rl.getKeyPressed()) {
            .key_q => break,
            .key_a, .key_left => {
                idx = if (idx == 0) images.items.len -| 1 else idx - 1;
                init_direction = .left;
            },
            .key_d, .key_right => {
                idx = if (idx + 1 >= images.items.len) 0 else idx + 1;
                init_direction = .right;
            },
            .key_e => allow_scale = !allow_scale,
            else => {},
        }
        if (images.items[idx].texture == null) {
            switch (init_direction) {
                .left => try getImagesList(allocator, &images, filenames, idx, idx + 10),
                .right => try getImagesList(allocator, &images, filenames, idx -| 10, idx),
            }
        }
        const image = images.items[idx];
        const image_texture = image.texture.?;

        const scale_ratio: f32 = if (allow_scale) mag_ratio else 1.0;
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
                image_texture,
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

            rl.drawTextEx(
                font,
                image.filename,
                .{
                    .x = 10.0,
                    .y = img_height + @as(f32, @floatFromInt(PANE_HEIGHT >> 2)),
                },
                PANE_HEIGHT >> 1,
                0.0,
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

fn getImageFromOther(allocator: Allocator, filename: []const u8) !rl.Image {
    var img_file = try fs.cwd().openFile(filename, .{});
    defer img_file.close();

    const content = try img_file.readToEndAlloc(allocator, math.maxInt(usize));
    defer allocator.free(content);

    const extension = blk: {
        const tmp = fs.path.extension(filename);
        break :blk try allocator.dupeZ(u8, tmp);
    };
    defer allocator.free(extension);

    return rl.loadImageFromMemory(extension, content);
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
    images: *ArrayList(Image),
    filenames: ArrayList([:0]const u8),
    from: usize,
    step: usize,
) !void {
    std.debug.assert(filenames.items.len == images.items.len);

    const end = @min(filenames.items.len, from + step);
    errdefer {
        for (from..end) |idx| {
            if (images.items[idx].texture) |texture| {
                rl.unloadTexture(texture);
            }
            images.items[idx].texture = null;
        }
        images.deinit();
    }

    for (from..end) |idx| {
        if (images.items[idx].texture != null) continue;

        const filename = filenames.items[idx];
        var img_raylib = if (try isWebpImage(filename))
            try getImageFromWebp(allocator, filename)
        else
            try getImageFromOther(allocator, filename);
        defer rl.unloadImage(img_raylib);

        var img_height = @min(MAX_IMAGE_HEIGHT, img_raylib.height);
        var img_width = @divTrunc(img_raylib.width * img_height, img_raylib.height);
        if (img_width > MAX_SCREEN_WIDTH) {
            img_height = @divTrunc(img_height * img_width, MAX_SCREEN_WIDTH);
            img_width = MAX_SCREEN_WIDTH;
        }
        rl.imageResize(&img_raylib, @intCast(img_width), @intCast(img_height));

        const texture = rl.loadTextureFromImage(img_raylib);
        errdefer rl.unloadTexture(texture);

        images.items[idx].texture = texture;
        images.items[idx].width = @intCast(img_width);
        images.items[idx].height = @intCast(img_height);
    }
}
