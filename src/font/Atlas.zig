const std = @import("std");
const Face = @import("Face.zig");

allocator: std.mem.Allocator,
size: u32,
data: []u8,

current_x: u32,
current_y: u32,
row_height: u32,

glyphs: std.AutoHashMap(u21, GlyphInfo),

const Self = @This();

pub const GlyphInfo = struct {
    x: u32,
    y: u32,
    width: u32,
    height: u32,
    bearing_x: i32,
    bearing_y: i32,
    advance: f32,
};

pub fn init(allocator: std.mem.Allocator, size: u32) !Self {
    const data = try allocator.alloc(u8, size * size * 4);
    @memset(data, 0);

    return .{
        .allocator = allocator,
        .size = size,
        .data = data,
        .current_x = 0,
        .current_y = 0,
        .row_height = 0,
        .glyphs = std.AutoHashMap(u21, GlyphInfo).init(allocator),
    };
}

pub fn deinit(self: *Self) void {
    self.glyphs.deinit();
    self.allocator.free(self.data);
}

pub fn getOrInsertGlyph(self: *Self, face: *Face, codepoint: u21) !GlyphInfo {
    if (self.glyphs.get(codepoint)) |info| {
        return info;
    }

    var rendered = (try face.renderGlyph(self.allocator, codepoint)) orelse {
        return .{
            .x = 0,
            .y = 0,
            .width = 0,
            .height = 0,
            .bearing_x = 0,
            .bearing_y = 0,
            .advance = @floatFromInt(face.cell_width),
        };
    };
    defer rendered.deinit(self.allocator);

    const padding = 1;
    const glyph_width = rendered.width + padding * 2;
    const glyph_height = rendered.height + padding * 2;

    if (self.current_x + glyph_width > self.size) {
        self.current_x = 0;
        self.current_y += self.row_height;
        self.row_height = 0;
    }

    if (self.current_y + glyph_height > self.size) {
        self.clear();
        return self.getOrInsertGlyph(face, codepoint);
    }

    if (glyph_height > self.row_height) {
        self.row_height = glyph_height;
    }

    const x = self.current_x + padding;
    const y = self.current_y + padding;

    for (0..rendered.height) |row| {
        for (0..rendered.width) |col| {
            const src_idx = (row * rendered.width + col) * 4;
            const dst_idx = ((y + row) * self.size + (x + col)) * 4;
            
            self.data[dst_idx] = rendered.bitmap[src_idx];
            self.data[dst_idx + 1] = rendered.bitmap[src_idx + 1];
            self.data[dst_idx + 2] = rendered.bitmap[src_idx + 2];
            self.data[dst_idx + 3] = rendered.bitmap[src_idx + 3];
        }
    }

    const info = GlyphInfo{
        .x = x,
        .y = y,
        .width = rendered.width,
        .height = rendered.height,
        .bearing_x = rendered.bearing_x,
        .bearing_y = rendered.bearing_y,
        .advance = rendered.advance,
    };

    try self.glyphs.put(codepoint, info);

    self.current_x += glyph_width;

    return info;
}

pub fn getGlyph(self: *Self, codepoint: u21) ?GlyphInfo {
    return self.glyphs.get(codepoint);
}

pub fn clear(self: *Self) void {
    @memset(self.data, 0);
    self.current_x = 0;
    self.current_y = 0;
    self.row_height = 0;
    self.glyphs.clearRetainingCapacity();
}

pub fn getData(self: *Self) []const u8 {
    return self.data;
}
