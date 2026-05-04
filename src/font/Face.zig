const std = @import("std");
const c = @cImport({
    @cInclude("CoreText/CoreText.h");
    @cInclude("CoreGraphics/CoreGraphics.h");
    @cInclude("CoreFoundation/CoreFoundation.h");
});

allocator: std.mem.Allocator,
font: *c.CTFontRef,
cell_width: u32,
cell_height: u32,
baseline: u32,

const Self = @This();

pub fn init(allocator: std.mem.Allocator, family_name: []const u8, size: f32) !Self {
    const name_cfstring = c.CFStringCreateWithBytes(
        null,
        family_name.ptr,
        @intCast(family_name.len),
        c.kCFStringEncodingUTF8,
        false,
        null,
    );
    defer c.CFRelease(name_cfstring);

    const descriptor = c.CTFontDescriptorCreateWithNameAndSize(name_cfstring, size);
    defer c.CFRelease(descriptor);

    const font = c.CTFontCreateWithFontDescriptor(descriptor, size, null);
    if (font == null) {
        return error.FontCreationFailed;
    }

    const ascent = c.CTFontGetAscent(font);
    const descent = c.CTFontGetDescent(font);
    const leading = c.CTFontGetLeading(font);
    const cell_height = @as(u32, @intFromFloat(@ceil(ascent + descent + leading)));

    const chars = "M";
    const chars_cfstring = c.CFStringCreateWithBytes(
        null,
        chars.ptr,
        @intCast(chars.len),
        c.kCFStringEncodingUTF8,
        false,
        null,
    );
    defer c.CFRelease(chars_cfstring);

    const glyph = c.CTFontGetGlyphWithName(font, chars_cfstring);
    var advance: c.CGSize = undefined;
    _ = c.CTFontGetAdvancesForGlyphs(font, c.kCTFontOrientationHorizontal, &glyph, &advance, 1);
    const cell_width = @as(u32, @intFromFloat(@ceil(advance.width)));

    return .{
        .allocator = allocator,
        .font = font,
        .cell_width = @max(cell_width, 1),
        .cell_height = @max(cell_height, 1),
        .baseline = @intFromFloat(@ceil(ascent)),
    };
}

pub fn deinit(self: *Self) void {
    if (self.font) |font| {
        c.CFRelease(font);
    }
}

pub fn renderGlyph(self: *Self, allocator: std.mem.Allocator, codepoint: u21) !?RenderedGlyph {
    var utf16_buffer: [2]u16 = undefined;
    const utf16_len = std.unicode.utf8Encode(codepoint, std.mem.asBytes(&utf16_buffer)) catch |err| {
        if (err == error.CodepointTooLarge) {
            const high: u16 = @intCast(0xD800 + ((codepoint - 0x10000) >> 10));
            const low: u16 = @intCast(0xDC00 + ((codepoint - 0x10000) & 0x3FF));
            utf16_buffer[0] = high;
            utf16_buffer[1] = low;
        } else {
            return null;
        }
    };

    const chars_cfstring = c.CFStringCreateWithBytes(
        null,
        @ptrCast(&utf16_buffer),
        utf16_len * 2,
        c.kCFStringEncodingUTF16LE,
        false
    );
    defer c.CFRelease(chars_cfstring);

    const glyph = c.CTFontGetGlyphWithName(self.font, chars_cfstring);
    if (glyph == 0) return null;

    var bounds = c.CTFontGetBoundingRectsForGlyphs(self.font, c.kCTFontOrientationHorizontal, &glyph, null, 1);
    
    var advance: c.CGSize = undefined;
    _ = c.CTFontGetAdvancesForGlyphs(self.font, c.kCTFontOrientationHorizontal, &glyph, &advance, 1);

    const width = @as(u32, @intFromFloat(@ceil(bounds.size.width)));
    const height = @as(u32, @intFromFloat(@ceil(bounds.size.height)));
    
    if (width == 0 or height == 0) {
        return .{
            .bitmap = &[_]u8{},
            .width = @max(width, 1),
            .height = @max(height, 1),
            .advance_x = @as(f32, @floatCast(advance.width)),
            .advance_y = @as(f32, @floatCast(advance.height)),
            .offset_x = @as(f32, @floatCast(bounds.origin.x)),
            .offset_y = @as(f32, @floatCast(bounds.origin.y)),
        };
    }

    const bytes_per_row = width * 4;
    const bitmap_data = try allocator.alloc(u8, height * bytes_per_row);
    @memset(bitmap_data, 0);

    const color_space = c.CGColorSpaceCreateDeviceRGB();
    defer c.CGColorSpaceRelease(color_space);

    const context = c.CGBitmapContextCreate(
        bitmap_data.ptr,
        width,
        height,
        8,
        bytes_per_row,
        color_space,
        c.kCGImageAlphaPremultipliedLast
    );
    defer c.CGContextRelease(context);

    c.CGContextSetRGBFillColor(context, 1, 1, 1, 1);

    const position = c.CGPoint{
        .x = -bounds.origin.x,
        .y = -bounds.origin.y,
    };

    c.CGContextSetTextPosition(context, position.x, position.y);
    c.CGContextShowGlyphsAtPositions(context, &glyph, &position, 1);

    return .{
        .bitmap = bitmap_data,
        .width = width,
        .height = height,
        .advance_x = @as(f32, @floatCast(advance.width)),
        .advance_y = @as(f32, @floatCast(advance.height)),
        .offset_x = @as(f32, @floatCast(bounds.origin.x)),
        .offset_y = @as(f32, @floatCast(bounds.origin.y)),
    };
}

pub const RenderedGlyph = struct {
    bitmap: []u8,
    width: u32,
    height: u32,
    bearing_x: i32,
    bearing_y: i32,
    advance: f32,

    pub fn deinit(self: *RenderedGlyph, allocator: std.mem.Allocator) void {
        if (self.bitmap.len > 0) {
            allocator.free(self.bitmap);
        }
    }
};

pub fn hasGlyph(self: *Self, codepoint: u21) bool {
    var utf16_buffer: [2]u16 = undefined;
    const utf16_len = std.unicode.utf8Encode(codepoint, std.mem.asBytes(&utf16_buffer)) catch |err| {
        if (err == error.CodepointTooLarge) {
            const high: u16 = @intCast(0xD800 + ((codepoint - 0x10000) >> 10));
            const low: u16 = @intCast(0xDC00 + ((codepoint - 0x10000) & 0x3FF));
            utf16_buffer[0] = high;
            utf16_buffer[1] = low;
        } else {
            return false;
        }
    } else {
        _ = utf16_len;
    };

    const chars_cfstring = c.CFStringCreateWithCharacters(
        null,
        &utf16_buffer,
        if (codepoint > 0xFFFF) 2 else 1,
    );
    defer c.CFRelease(chars_cfstring);

    const glyph = c.CTFontGetGlyphWithName(self.font, chars_cfstring);
    return glyph != 0;
}
