const std = @import("std");
const c = @cImport({
    @cInclude("objc/runtime.h");
    @cInclude("objc/message.h");
    @cInclude("QuartzCore/CAMetalLayer.h");
});

const Metal = @import("Metal.zig");
const Cell = @import("Cell.zig");
const Screen = @import("../terminal/Screen.zig");
const Face = @import("../font/Face.zig");
const Atlas = @import("../font/Atlas.zig");
const Config = @import("../config/Config.zig");

allocator: std.mem.Allocator,
metal: Metal,
config: *const Config,

face: ?Face,
atlas: Atlas,

background_quad: Cell.BackgroundQuad,
cell_vertices: std.ArrayList(Cell.CellVertex),
cell_indices: std.ArrayList(u16),

cell_width: f32,
cell_height: f32,
width: u32,
height: u32,

palette: [256][3]u8,

const Self = @This();

const Palette = blk: {
    var colors: [256][3]u8 = undefined;

    colors[0] = .{ 0, 0, 0 }; // black
    colors[1] = .{ 205, 0, 0 }; // red
    colors[2] = .{ 0, 205, 0 }; // green
    colors[3] = .{ 205, 205, 0 }; // yellow
    colors[4] = .{ 0, 0, 238 }; // blue
    colors[5] = .{ 205, 0, 205 }; // magenta
    colors[6] = .{ 0, 205, 205 }; // cyan
    colors[7] = .{ 229, 229, 229 }; // white

    colors[8] = .{ 127, 127, 127 }; // bright black
    colors[9] = .{ 255, 0, 0 }; // bright red
    colors[10] = .{ 0, 255, 0 }; // bright green
    colors[11] = .{ 255, 255, 0 }; // bright yellow
    colors[12] = .{ 92, 92, 255 }; // bright blue
    colors[13] = .{ 255, 0, 255 }; // bright magenta
    colors[14] = .{ 0, 255, 255 }; // bright cyan
    colors[15] = .{ 255, 255, 255 }; // bright white

    var i: usize = 16;
    while (i < 232) : (i += 1) {
        const r = (i - 16) / 36;
        const g = ((i - 16) % 36) / 6;
        const b = (i - 16) % 6;
        colors[i] = .{
            if (r == 0) 0 else @intCast(r * 40 + 55),
            if (g == 0) 0 else @intCast(g * 40 + 55),
            if (b == 0) 0 else @intCast(b * 40 + 55),
        };
    }

    i = 232;
    while (i < 256) : (i += 1) {
        const gray: u8 = @intCast((i - 232) * 10 + 8);
        colors[i] = .{ gray, gray, gray };
    }

    break :blk colors;
};

pub fn init(allocator: std.mem.Allocator, config: *const Config) !Self {
    var metal = Metal.init(allocator);
    try metal.createDevice();

    return .{
        .allocator = allocator,
        .metal = metal,
        .config = config,
        .face = null,
        .atlas = try Atlas.init(allocator, 2048),
        .background_quad = undefined,
        .cell_vertices = std.ArrayList(Cell.CellVertex).init(allocator),
        .cell_indices = std.ArrayList(u16).init(allocator),
        .cell_width = 10,
        .cell_height = 20,
        .width = 0,
        .height = 0,
        .palette = Palette,
    };
}

pub fn deinit(self: *Self) void {
    self.cell_vertices.deinit();
    self.cell_indices.deinit();
    self.atlas.deinit();
    if (self.face) |*face| {
        face.deinit();
    }
    self.metal.deinit();
}

pub fn setFontFace(self: *Self, face: Face) !void {
    if (self.face) |*old_face| {
        old_face.deinit();
    }
    self.face = face;
    self.cell_width = @floatFromInt(face.cell_width);
    self.cell_height = @floatFromInt(face.cell_height);

    self.atlas.deinit();
    self.atlas = try Atlas.init(self.allocator, 2048);
}

pub fn loadBackgroundImage(self: *Self, path: []const u8) !void {
    try self.metal.loadBackgroundImage(path);
}

pub fn resize(self: *Self, width: u32, height: u32) void {
    self.width = width;
    self.height = height;
    self.background_quad = Cell.BackgroundQuad.init(0, 0, @floatFromInt(width), @floatFromInt(height));
}

pub fn render(
    self: *Self,
    screen: *const Screen,
    metal_layer: *c.CAMetalLayer,
    overlay_opacity: f32,
) !void {
    if (self.face == null) return;

    const next_sel = c.sel_registerName("nextDrawable");
    const drawable: ?*c.CAMetalDrawable = @ptrCast(c.objc_msgSend(metal_layer, next_sel));
    if (drawable == null) return;

    try self.buildGeometry(screen, overlay_opacity);

    const clear_color = [4]f32{ 0, 0, 0, 0 };
    const render_pass_desc = try Metal.createRenderPassDescriptor(drawable.?, clear_color);
    defer _ = c.objc_msgSend(render_pass_desc, c.sel_release);

    try self.metal.render(
        drawable.?,
        render_pass_desc,
        self.width,
        self.height,
        &self.background_quad.vertices,
        &self.background_quad.indices,
        self.cell_vertices.items,
        self.cell_indices.items,
    );
}

fn buildGeometry(self: *Self, screen: *const Screen, overlay_opacity: f32) !void {
    self.cell_vertices.clearRetainingCapacity();
    self.cell_indices.clearRetainingCapacity();

    if (self.face == null) return;

    const face = &self.face.?;
    const padding: f32 = @floatFromInt(self.config.padding);

    const cols = screen.cols;
    const rows = screen.rows;

    var index_offset: u16 = 0;

    for (0..rows) |row| {
        for (0..cols) |col| {
            const cell = screen.buffer[row * cols + col];
            if (cell.char == ' ' and !cell.dirty) continue;

            const x = padding + @as(f32, @floatFromInt(col)) * self.cell_width;
            const y = padding + @as(f32, @floatFromInt(row)) * self.cell_height;

            const glyph_info = try self.atlas.getOrInsertGlyph(face, cell.char);

            const fg_color = self.resolveColor(cell.fg_color, .foreground);
            const bg_color = self.resolveColor(cell.bg_color, .background);

            var final_bg_color = bg_color;
            if (cell.char != ' ') {
                final_bg_color[3] = overlay_opacity;
            }

            const quad = Cell.Quad.init(
                x,
                y,
                self.cell_width,
                self.cell_height,
                @floatFromInt(glyph_info.x),
                @floatFromInt(glyph_info.y),
                @floatFromInt(glyph_info.width),
                @floatFromInt(glyph_info.height),
                @floatFromInt(self.atlas.size),
                Cell.colorToFloats(fg_color[0..3].*, 1.0),
                final_bg_color,
            );

            try self.cell_vertices.appendSlice(&quad.vertices);

            for (quad.indices) |idx| {
                try self.cell_indices.append(index_offset + idx);
            }

            index_offset += 4;
        }
    }
}

fn resolveColor(self: *Self, color: Screen.Cell.Color, context: enum { foreground, background }) [4]f32 {
    _ = context;
    const rgb: [3]u8 = switch (color) {
        .default => .{ 220, 220, 220 },
        .palette => |idx| self.palette[@min(idx, 255)],
        .rgb => |rgb| rgb,
    };
    return Cell.colorToFloats(rgb, 1.0);
}

pub fn needsRerender(self: *Self, screen: *const Screen) bool {
    for (screen.buffer) |cell| {
        if (cell.dirty) return true;
    }
    return false;
}

pub fn markRendered(self: *Self, screen: *Screen) void {
    for (screen.buffer) |*cell| {
        cell.dirty = false;
    }
}
