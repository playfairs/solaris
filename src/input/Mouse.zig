const std = @import("std");

pub const MouseEvent = struct {
    x: f32,
    y: f32,
    button: Button,
    action: Action,
    modifiers: Modifiers,

    pub const Button = enum {
        left,
        right,
        middle,
        none,
    };

    pub const Action = enum {
        press,
        release,
        motion,
        scroll_up,
        scroll_down,
        scroll_left,
        scroll_right,
    };

    pub const Modifiers = packed struct {
        shift: bool = false,
        control: bool = false,
        alt: bool = false,
        command: bool = false,
        _padding: u4 = 0,
    };
};

pub const TrackingMode = enum {
    none,
    x10,
    normal,
    button,
    any,
};

pub fn mouseToEscapeSequence(
    allocator: std.mem.Allocator,
    event: MouseEvent,
    cell_x: usize,
    cell_y: usize,
    tracking: TrackingMode,
) !?[]const u8 {
    if (tracking == .none) return null;

    if (event.action == .motion and tracking != .any) return null;

    if (event.action == .release and tracking == .x10) return null;

    var button_code: u32 = 0;

    switch (event.button) {
        .left => button_code = 0,
        .middle => button_code = 1,
        .right => button_code = 2,
        .none => {
            if (event.action == .motion) {
                button_code = 35;
            } else {
                return null;
            }
        },
    }

    if (event.modifiers.shift) button_code |= 4;
    if (event.modifiers.alt) button_code |= 8;
    if (event.modifiers.control) button_code |= 16;

    if (event.action == .release) {
        return try std.fmt.allocPrint(allocator, "\x1b[<{};{};{}m", .{ button_code, cell_x + 1, cell_y + 1 });
    }

    if (event.action == .scroll_up) {
        button_code = 64;
        if (event.modifiers.shift) button_code |= 4;
        if (event.modifiers.alt) button_code |= 8;
        if (event.modifiers.control) button_code |= 16;
    } else if (event.action == .scroll_down) {
        button_code = 65;
        if (event.modifiers.shift) button_code |= 4;
        if (event.modifiers.alt) button_code |= 8;
        if (event.modifiers.control) button_code |= 16;
    }

    return try std.fmt.allocPrint(allocator, "\x1b[<{};{};{}M", .{ button_code, cell_x + 1, cell_y + 1 });
}

pub fn screenToCell(x: f32, y: f32, cell_width: f32, cell_height: f32, padding: f32) struct { col: usize, row: usize } {
    const col = @as(usize, @intFromFloat(@max(0, x - padding) / cell_width));
    const row = @as(usize, @intFromFloat(@max(0, y - padding) / cell_height));
    return .{ .col = col, .row = row };
}
