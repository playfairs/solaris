const std = @import("std");

pub const CellVertex = extern struct {
    position: [2]f32,
    tex_coord: [2]f32,
    fg_color: [4]f32,
    bg_color: [4]f32,
    glyph_info: [4]f32,
};

pub const Quad = struct {
    vertices: [4]CellVertex,
    indices: [6]u16,

    pub fn init(
        x: f32,
        y: f32,
        width: f32,
        height: f32,
        atlas_x: f32,
        atlas_y: f32,
        atlas_width: f32,
        atlas_height: f32,
        atlas_size: f32,
        fg_color: [4]f32,
        bg_color: [4]f32,
    ) Quad {
        const x0 = x;
        const y0 = y;
        const x1 = x + width;
        const y1 = y + height;

        const u0 = atlas_x / atlas_size;
        const v0 = atlas_y / atlas_size;
        const u1 = (atlas_x + atlas_width) / atlas_size;
        const v1 = (atlas_y + atlas_height) / atlas_size;

        const glyph_info = [4]f32{ atlas_x, atlas_y, atlas_width, atlas_height };

        return .{
            .vertices = .{
                .{ .position = .{ x0, y0 }, .tex_coord = .{ u0, v0 }, .fg_color = fg_color, .bg_color = bg_color, .glyph_info = glyph_info },
                .{ .position = .{ x1, y0 }, .tex_coord = .{ u1, v0 }, .fg_color = fg_color, .bg_color = bg_color, .glyph_info = glyph_info },
                .{ .position = .{ x0, y1 }, .tex_coord = .{ u0, v1 }, .fg_color = fg_color, .bg_color = bg_color, .glyph_info = glyph_info },
                .{ .position = .{ x1, y1 }, .tex_coord = .{ u1, v1 }, .fg_color = fg_color, .bg_color = bg_color, .glyph_info = glyph_info },
            },
            .indices = .{ 0, 1, 2, 1, 3, 2 },
        };
    }
};

pub const BackgroundVertex = extern struct {
    position: [2]f32,
    tex_coord: [2]f32,
};

pub const BackgroundQuad = struct {
    vertices: [4]BackgroundVertex,
    indices: [6]u16,

    pub fn init(x: f32, y: f32, width: f32, height: f32) BackgroundQuad {
        return .{
            .vertices = .{
                .{ .position = .{ x, y }, .tex_coord = .{ 0, 0 } },
                .{ .position = .{ x + width, y }, .tex_coord = .{ 1, 0 } },
                .{ .position = .{ x, y + height }, .tex_coord = .{ 0, 1 } },
                .{ .position = .{ x + width, y + height }, .tex_coord = .{ 1, 1 } },
            },
            .indices = .{ 0, 1, 2, 1, 3, 2 },
        };
    }
};

pub fn colorToFloats(color: [3]u8, alpha: f32) [4]f32 {
    return .{
        @as(f32, @floatFromInt(color[0])) / 255.0,
        @as(f32, @floatFromInt(color[1])) / 255.0,
        @as(f32, @floatFromInt(color[2])) / 255.0,
        alpha,
    };
}
