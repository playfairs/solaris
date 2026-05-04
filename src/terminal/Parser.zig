const std = @import("std");
const Screen = @import("Screen.zig");

pub const EscapeSequence = union(enum) {
    cursor_up: usize,
    cursor_down: usize,
    cursor_forward: usize,
    cursor_back: usize,
    cursor_next_line: usize,
    cursor_prev_line: usize,
    cursor_horizontal_absolute: usize,
    cursor_position: struct { row: usize, col: usize },
    cursor_save,
    cursor_restore,

    erase_in_display: enum { below, above, all, saved },
    erase_in_line: enum { right, left, all },

    scroll_up: usize,
    scroll_down: usize,

    select_graphic_rendition: []const u8,

    set_mode: struct { mode: u16, value: bool },
    reset_mode: u16,

    set_scrolling_region: struct { top: ?usize, bottom: ?usize },

    horizontal_tab_set,
    tab_clear: enum { current, all },
    horizontal_tab: usize,

    insert_lines: usize,
    delete_lines: usize,
    insert_chars: usize,
    delete_chars: usize,

    designate_g0_charset: u8,
    designate_g1_charset: u8,

    double_height_top,
    double_height_bottom,
    single_width,
    double_width,

    set_title: []const u8,
    set_icon_name: []const u8,

    soft_reset,

    device_status_report: u16,

    csi_generic: struct { prefix: u8, params: []const u8, suffix: u8 },

    osc_generic: struct { code: u8, data: []const u8 },

    dcs_generic: struct { params: []const u8, data: []const u8 },

    bell,
    backspace,
    carriage_return,
    line_feed,
    form_feed,
    vertical_tab,
    null_char,

    print: u21,
};

state: enum {
    ground,
    escape,
    escape_intermediate,
    csi_entry,
    csi_param,
    csi_intermediate,
    csi_ignore,
    dcs_entry,
    dcs_param,
    dcs_intermediate,
    dcs_passthrough,
    dcs_ignore,
    osc_string,
    sos_pm_apc_string,
    st_ignore,
},
params: std.ArrayList(u8),
intermediate_chars: std.ArrayList(u8),
osc_buffer: std.ArrayList(u8),
dcs_buffer: std.ArrayList(u8),
param_buffer: [16]u8,
param_count: usize,
current_param: u16,
has_param: bool,

const Self = @This();

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .state = .ground,
        .params = std.ArrayList(u8).init(allocator),
        .intermediate_chars = std.ArrayList(u8).init(allocator),
        .osc_buffer = std.ArrayList(u8).init(allocator),
        .dcs_buffer = std.ArrayList(u8).init(allocator),
        .param_buffer = undefined,
        .param_count = 0,
        .current_param = 0,
        .has_param = false,
    };
}

pub fn deinit(self: *Self) void {
    self.params.deinit();
    self.intermediate_chars.deinit();
    self.osc_buffer.deinit();
    self.dcs_buffer.deinit();
}

pub fn reset(self: *Self) void {
    self.state = .ground;
    self.params.clearRetainingCapacity();
    self.intermediate_chars.clearRetainingCapacity();
    self.osc_buffer.clearRetainingCapacity();
    self.dcs_buffer.clearRetainingCapacity();
    self.param_count = 0;
    self.current_param = 0;
    self.has_param = false;
}

pub fn parse(self: *Self, input: []const u8, sequences: *std.ArrayList(EscapeSequence)) !void {
    for (input) |byte| {
        if (try self.processByte(byte)) |seq| {
            try sequences.append(seq);
        }
    }
}

fn processByte(self: *Self, byte: u8) !?EscapeSequence {
    switch (self.state) {
        .ground => {
            switch (byte) {
                0x00 => return .null_char,
                0x07 => return .bell,
                0x08 => return .backspace,
                0x09 => return .{ .horizontal_tab = 1 },
                0x0A => return .line_feed,
                0x0B => return .vertical_tab,
                0x0C => return .form_feed,
                0x0D => return .carriage_return,
                0x18, 0x1A => {
                    self.reset();
                    return null;
                },
                0x1B => {
                    self.state = .escape;
                    return null;
                },
                0x20...0x7E => {
                    return .{ .print = byte };
                },
                0x80...0xFF => {
                    return .{ .print = byte };
                },
                else => return null,
            }
        },

        .escape => {
            switch (byte) {
                '[' => {
                    self.state = .csi_entry;
                    self.param_count = 0;
                    self.has_param = false;
                    return null;
                },
                ']' => {
                    self.state = .osc_string;
                    self.osc_buffer.clearRetainingCapacity();
                    return null;
                },
                'P' => {
                    self.state = .dcs_entry;
                    self.dcs_buffer.clearRetainingCapacity();
                    return null;
                },
                'X', '^', '_' => {
                    self.state = .sos_pm_apc_string;
                    return null;
                },
                'c' => {
                    self.state = .ground;
                    return .soft_reset;
                },
                '7' => {
                    self.state = .ground;
                    return .cursor_save;
                },
                '8' => {
                    self.state = .ground;
                    return .cursor_restore;
                },
                'D' => {
                    self.state = .ground;
                    return .{ .line_feed = {} };
                },
                'E' => {
                    self.state = .ground;
                    return .{ .cursor_next_line = 1 };
                },
                'H' => {
                    self.state = .ground;
                    return .horizontal_tab_set;
                },
                'M' => {
                    self.state = .ground;
                    return .{ .cursor_prev_line = 1 };
                },
                '(', ')', '*', '+' => {
                    self.state = .escape_intermediate;
                    try self.intermediate_chars.append(byte);
                    return null;
                },
                '#', '%', ' ', '!', '"', '&', '\'', '(', ')', '*', '+', ',', '-', '.', '/' => {
                    self.state = .escape_intermediate;
                    try self.intermediate_chars.append(byte);
                    return null;
                },
                0x30...0x7E => {
                    self.state = .ground;
                    return null;
                },
                0x18, 0x1A, 0x1B => {
                    self.state = .ground;
                    if (byte == 0x1B) self.state = .escape;
                    return null;
                },
                else => return null,
            }
        },

        .escape_intermediate => {
            switch (byte) {
                0x20...0x2F => {
                    try self.intermediate_chars.append(byte);
                    return null;
                },
                0x30...0x7E => {
                    const seq = try self.handleEscapeFinal(byte);
                    self.state = .ground;
                    self.intermediate_chars.clearRetainingCapacity();
                    return seq;
                },
                0x18, 0x1A => {
                    self.state = .ground;
                    return null;
                },
                else => return null,
            }
        },

        .csi_entry => {
            switch (byte) {
                0x3A => {
                    self.state = .csi_ignore;
                    return null;
                },
                0x3B, 0x30...0x39, '<', '=', '>', '?' => {
                    self.state = .csi_param;
                    return self.processCsiParam(byte);
                },
                0x20...0x2F => {
                    self.state = .csi_intermediate;
                    try self.intermediate_chars.append(byte);
                    return null;
                },
                0x40...0x7E => {
                    const seq = try self.handleCsiFinal(byte);
                    self.resetCsi();
                    self.state = .ground;
                    return seq;
                },
                0x18, 0x1A, 0x1B => {
                    self.state = .ground;
                    if (byte == 0x1B) self.state = .escape;
                    return null;
                },
                else => return null,
            }
        },

        .csi_param => {
            switch (byte) {
                0x30...0x39, 0x3A, 0x3B => {
                    return self.processCsiParam(byte);
                },
                0x3C, 0x3D, 0x3E, 0x3F => {
                    return self.processCsiParam(byte);
                },
                0x20...0x2F => {
                    self.state = .csi_intermediate;
                    try self.intermediate_chars.append(byte);
                    return null;
                },
                0x40...0x7E => {
                    const seq = try self.handleCsiFinal(byte);
                    self.resetCsi();
                    self.state = .ground;
                    return seq;
                },
                0x18, 0x1A, 0x1B => {
                    self.resetCsi();
                    self.state = .ground;
                    if (byte == 0x1B) self.state = .escape;
                    return null;
                },
                else => return null,
            }
        },

        .csi_intermediate => {
            switch (byte) {
                0x20...0x2F => {
                    try self.intermediate_chars.append(byte);
                    return null;
                },
                0x30...0x3F => {
                    self.state = .csi_ignore;
                    return null;
                },
                0x40...0x7E => {
                    const seq = try self.handleCsiFinal(byte);
                    self.resetCsi();
                    self.state = .ground;
                    return seq;
                },
                0x18, 0x1A, 0x1B => {
                    self.resetCsi();
                    self.state = .ground;
                    if (byte == 0x1B) self.state = .escape;
                    return null;
                },
                else => return null,
            }
        },

        .csi_ignore => {
            switch (byte) {
                0x40...0x7E => {
                    self.state = .ground;
                    return null;
                },
                0x18, 0x1A, 0x1B => {
                    self.state = .ground;
                    if (byte == 0x1B) self.state = .escape;
                    return null;
                },
                else => return null,
            }
        },

        .osc_string => {
            switch (byte) {
                0x07 => {
                    const seq = try self.handleOsc();
                    self.state = .ground;
                    return seq;
                },
                0x1B => {
                    self.state = .st_ignore;
                    return null;
                },
                0x00...0x06, 0x08...0x17, 0x19, 0x1C...0x1F => {
                    return null;
                },
                else => {
                    try self.osc_buffer.append(byte);
                    return null;
                },
            }
        },

        .st_ignore => {
            if (byte == '\\') {
                const seq = try self.handleOsc();
                self.state = .ground;
                return seq;
            } else {
                self.state = .osc_string;
                if (byte != 0x1B) {
                    try self.osc_buffer.append(0x1B);
                    try self.osc_buffer.append(byte);
                }
                return null;
            }
        },

        .dcs_entry, .dcs_param, .dcs_intermediate => {
            switch (byte) {
                0x07 => {
                    const seq = try self.handleDcs();
                    self.state = .ground;
                    return seq;
                },
                0x1B => {
                    self.state = .st_ignore;
                    return null;
                },
                else => {
                    if (self.state == .dcs_entry or self.state == .dcs_param) {
                        if (byte >= 0x30 and byte <= 0x3B) {
                            self.state = .dcs_param;
                        } else if (byte >= 0x20 and byte <= 0x2F) {
                            self.state = .dcs_intermediate;
                        } else if (byte >= 0x40 and byte <= 0x7E) {
                            self.state = .dcs_passthrough;
                        }
                    }
                    if (self.state == .dcs_passthrough) {
                        try self.dcs_buffer.append(byte);
                    }
                    return null;
                },
            }
        },

        .dcs_passthrough => {
            switch (byte) {
                0x07, 0x9C => {
                    const seq = try self.handleDcs();
                    self.state = .ground;
                    return seq;
                },
                0x1B => {
                    self.state = .st_ignore;
                    return null;
                },
                else => {
                    try self.dcs_buffer.append(byte);
                    return null;
                },
            }
        },

        .dcs_ignore, .sos_pm_apc_string => {
            switch (byte) {
                0x07, 0x9C => {
                    self.state = .ground;
                    return null;
                },
                0x1B => {
                    self.state = .st_ignore;
                    return null;
                },
                else => return null,
            }
        },
    }
    return null;
}

fn processCsiParam(self: *Self, byte: u8) ?EscapeSequence {
    if (byte == ';') {
        if (self.param_count < self.param_buffer.len) {
            self.param_buffer[self.param_count] = @truncate(self.current_param);
            self.param_count += 1;
        }
        self.current_param = 0;
        self.has_param = false;
    } else if (byte >= '0' and byte <= '9') {
        self.current_param = self.current_param * 10 + (byte - '0');
        self.has_param = true;
    } else if (byte == ':') {
        if (self.param_count < self.param_buffer.len) {
            self.param_buffer[self.param_count] = @truncate(self.current_param);
            self.param_count += 1;
        }
        self.current_param = 0;
    }
    return null;
}

fn resetCsi(self: *Self) void {
    self.param_count = 0;
    self.current_param = 0;
    self.has_param = false;
    self.intermediate_chars.clearRetainingCapacity();
}

fn getParam(self: *Self, index: usize, default: u16) u16 {
    if (index < self.param_count) {
        return if (self.param_buffer[index] == 0) default else self.param_buffer[index];
    }
    return default;
}

fn handleCsiFinal(self: *Self, byte: u8) !?EscapeSequence {
    if (self.has_param and self.param_count < self.param_buffer.len) {
        self.param_buffer[self.param_count] = @truncate(self.current_param);
        self.param_count += 1;
    }

    const p1 = self.getParam(0, 1);
    const p2 = self.getParam(1, 1);

    switch (byte) {
        '@' => return .{ .insert_chars = @intCast(p1) },
        'A' => return .{ .cursor_up = @intCast(p1) },
        'B' => return .{ .cursor_down = @intCast(p1) },
        'C' => return .{ .cursor_forward = @intCast(p1) },
        'D' => return .{ .cursor_back = @intCast(p1) },
        'E' => return .{ .cursor_next_line = @intCast(p1) },
        'F' => return .{ .cursor_prev_line = @intCast(p1) },
        'G' => return .{ .cursor_horizontal_absolute = @intCast(if (p1 == 0) 1 else p1) },
        'H', 'f' => return .{ .cursor_position = .{
            .row = @intCast(if (p1 == 0) 1 else p1),
            .col = @intCast(if (p2 == 0) 1 else p2),
        } },
        'I' => return .{ .horizontal_tab = @intCast(p1) },
        'J' => {
            const mode: u16 = @intCast(p1);
            return .{ .erase_in_display = switch (mode) {
                0 => .below,
                1 => .above,
                2 => .all,
                3 => .saved,
                else => .all,
            } };
        },
        'K' => {
            const mode: u16 = @intCast(p1);
            return .{ .erase_in_line = switch (mode) {
                0 => .right,
                1 => .left,
                2 => .all,
                else => .right,
            } };
        },
        'L' => return .{ .insert_lines = @intCast(p1) },
        'M' => return .{ .delete_lines = @intCast(p1) },
        'P' => return .{ .delete_chars = @intCast(p1) },
        'S' => return .{ .scroll_up = @intCast(p1) },
        'T' => return .{ .scroll_down = @intCast(p1) },
        'X' => return .{ .erase_in_line = .all },
        'Z' => return .{ .cursor_back = @intCast(p1) },
        '`', 'd' => return .{ .cursor_horizontal_absolute = @intCast(if (p1 == 0) 1 else p1) },
        'a' => return .{ .cursor_forward = @intCast(p1) },
        'e' => return .{ .cursor_down = @intCast(p1) },
        'g' => return .{ .tab_clear = if (p1 == 0) .current else .all },
        'h' => {
            if (self.param_count > 0) {
                return .{ .set_mode = .{ .mode = self.param_buffer[0], .value = true } };
            }
            return null;
        },
        'l' => {
            if (self.param_count > 0) {
                return .{ .set_mode = .{ .mode = self.param_buffer[0], .value = false } };
            }
            return null;
        },
        'm' => {
            const params = try self.allocator.dupe(u8, self.param_buffer[0..self.param_count]);
            return .{ .select_graphic_rendition = params };
        },
        'n' => return .{ .device_status_report = @intCast(p1) },
        'r' => return .{ .set_scrolling_region = .{
            .top = if (p1 == 0) null else p1 - 1,
            .bottom = if (p2 == 0) null else p2 - 1,
        } },
        's' => return .cursor_save,
        'u' => return .cursor_restore,
        else => return null,
    }
}

fn handleEscapeFinal(self: *Self, byte: u8) !?EscapeSequence {
    if (self.intermediate_chars.items.len > 0) {
        const intermediate = self.intermediate_chars.items[0];
        switch (intermediate) {
            '(' => return .{ .designate_g0_charset = byte },
            ')' => return .{ .designate_g1_charset = byte },
            '#' => {
                switch (byte) {
                    '3' => return .double_height_top,
                    '4' => return .double_height_bottom,
                    '5' => return .single_width,
                    '6' => return .double_width,
                    '8' => {
                        return null;
                    },
                    else => return null,
                }
            },
            else => return null,
        }
    }
    return null;
}

fn handleOsc(self: *Self) !?EscapeSequence {
    if (self.osc_buffer.items.len == 0) return null;

    var code: u8 = 0;
    var data_start: usize = 0;

    for (self.osc_buffer.items, 0..) |ch, i| {
        if (ch == ';' or ch == ' ' or ch == 0) {
            if (i > 0) {
                code = self.osc_buffer.items[0] - '0';
                for (1..i) |j| {
                    code = code * 10 + (self.osc_buffer.items[j] - '0');
                }
            }
            data_start = i + 1;
            break;
        }
    }

    if (data_start == 0 and self.osc_buffer.items.len > 0) {
        code = self.osc_buffer.items[0] - '0';
        for (1..self.osc_buffer.items.len) |i| {
            const ch = self.osc_buffer.items[i];
            if (ch >= '0' and ch <= '9') {
                code = code * 10 + (ch - '0');
            } else {
                data_start = i;
                break;
            }
        }
    }

    const data = if (data_start < self.osc_buffer.items.len)
        try self.allocator.dupe(u8, self.osc_buffer.items[data_start..])
    else
        try self.allocator.dupe(u8, &[_]u8{});

    switch (code) {
        0 => return .{ .set_title = data },
        1 => return .{ .set_icon_name = data },
        2 => return .{ .set_title = data },
        else => return .{ .osc_generic = .{ .code = code, .data = data } },
    }
}

fn handleDcs(self: *Self) !?EscapeSequence {
    if (self.dcs_buffer.items.len == 0) return null;

    const data = try self.allocator.dupe(u8, self.dcs_buffer.items);
    return .{ .dcs_generic = .{ .params = &[_]u8{}, .data = data } };
}

pub fn applySgr(screen: *Screen, params: []const u8) void {
    if (params.len == 0) {
        screen.resetAttributes();
        return;
    }

    var i: usize = 0;
    while (i < params.len) {
        const param = params[i];
        switch (param) {
            0 => screen.resetAttributes(),
            1 => {
                var attrs = screen.cursor.attrs;
                attrs.bold = true;
                screen.setAttribute(attrs);
            },
            3 => {
                var attrs = screen.cursor.attrs;
                attrs.italic = true;
                screen.setAttribute(attrs);
            },
            4 => {
                var attrs = screen.cursor.attrs;
                attrs.underline = true;
                screen.setAttribute(attrs);
            },
            5, 6 => {
                var attrs = screen.cursor.attrs;
                attrs.blink = true;
                screen.setAttribute(attrs);
            },
            7 => {
                var attrs = screen.cursor.attrs;
                attrs.reverse = true;
                screen.setAttribute(attrs);
            },
            8 => {
                var attrs = screen.cursor.attrs;
                attrs.invisible = true;
                screen.setAttribute(attrs);
            },
            9 => {
                var attrs = screen.cursor.attrs;
                attrs.strikethrough = true;
                screen.setAttribute(attrs);
            },
            22 => {
                var attrs = screen.cursor.attrs;
                attrs.bold = false;
                screen.setAttribute(attrs);
            },
            23 => {
                var attrs = screen.cursor.attrs;
                attrs.italic = false;
                screen.setAttribute(attrs);
            },
            24 => {
                var attrs = screen.cursor.attrs;
                attrs.underline = false;
                screen.setAttribute(attrs);
            },
            25 => {
                var attrs = screen.cursor.attrs;
                attrs.blink = false;
                screen.setAttribute(attrs);
            },
            27 => {
                var attrs = screen.cursor.attrs;
                attrs.reverse = false;
                screen.setAttribute(attrs);
            },
            28 => {
                var attrs = screen.cursor.attrs;
                attrs.invisible = false;
                screen.setAttribute(attrs);
            },
            29 => {
                var attrs = screen.cursor.attrs;
                attrs.strikethrough = false;
                screen.setAttribute(attrs);
            },

            30...37 => screen.setForegroundColor(.{ .palette = param - 30 }),
            38 => {
                if (i + 1 < params.len) {
                    if (params[i + 1] == 5 and i + 2 < params.len) {
                        screen.setForegroundColor(.{ .palette = params[i + 2] });
                        i += 2;
                    } else if (params[i + 1] == 2 and i + 4 < params.len) {
                        screen.setForegroundColor(.{ .rgb = .{ params[i + 2], params[i + 3], params[i + 4] } });
                        i += 4;
                    }
                }
            },
            39 => screen.setForegroundColor(.{ .rgb = .{ 220, 220, 220 } }),

            40...47 => screen.setBackgroundColor(.{ .palette = param - 40 }),
            48 => {
                if (i + 1 < params.len) {
                    if (params[i + 1] == 5 and i + 2 < params.len) {
                        screen.setBackgroundColor(.{ .palette = params[i + 2] });
                        i += 2;
                    } else if (params[i + 1] == 2 and i + 4 < params.len) {
                        screen.setBackgroundColor(.{ .rgb = .{ params[i + 2], params[i + 3], params[i + 4] } });
                        i += 4;
                    }
                }
            },
            49 => screen.setBackgroundColor(.{ .rgb = .{ 0, 0, 0 } }),

            90...97 => screen.setForegroundColor(.{ .palette = param - 90 + 8 }),

            100...107 => screen.setBackgroundColor(.{ .palette = param - 100 + 8 }),

            else => {},
        }
        i += 1;
    }
}
