const std = @import("std");

// simple text shaping, primarily for future ligature support probably
// currently just returns codepoints as-is

allocator: std.mem.Allocator,

const Self = @This();

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .allocator = allocator,
    };
}

pub fn deinit(self: *Self) void {
    _ = self;
}

pub const ShapedGlyph = struct {
    codepoint: u21,
    cluster: u32,
    advance_x: f32,
    advance_y: f32,
    offset_x: f32,
    offset_y: f32,
};

pub fn shape(self: *Self, text: []const u8) ![]ShapedGlyph {
    var glyphs = std.ArrayList(ShapedGlyph).init(self.allocator);
    errdefer glyphs.deinit();

    var iter = std.unicode.Utf8Iterator.init(text);
    var cluster: u32 = 0;

    while (iter.nextCodepoint()) |codepoint| {
        try glyphs.append(.{
            .codepoint = codepoint,
            .cluster = cluster,
            .advance_x = 0,
            .advance_y = 0,
            .offset_x = 0,
            .offset_y = 0,
        });
        cluster += 1;
    }

    return glyphs.toOwnedSlice();
}
