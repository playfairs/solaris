const std = @import("std");
const Screen = @import("Screen.zig");
const Pty = @import("Pty.zig");
const Parser = @import("Parser.zig");

allocator: std.mem.Allocator,
screen: Screen,
pty: ?Pty,
parser: Parser,
shell_path: []const u8,
needs_render: bool,
scroll_offset: usize,

const Self = @This();

pub fn init(allocator: std.mem.Allocator, cols: usize, rows: usize, shell_path: []const u8) !Self {
    return .{
        .allocator = allocator,
        .screen = try Screen.init(allocator, cols, rows),
        .pty = null,
        .parser = Parser.init(allocator),
        .shell_path = try allocator.dupe(u8, shell_path),
        .needs_render = true,
        .scroll_offset = 0,
    };
}

pub fn deinit(self: *Self) void {
    if (self.pty) |*pty| {
        pty.close();
    }
    self.screen.deinit();
    self.parser.deinit();
    self.allocator.free(self.shell_path);
}

pub fn spawn(self: *Self) !void {
    if (self.pty != null) return;

    self.pty = try Pty.open(
        self.allocator,
        self.shell_path,
        @intCast(self.screen.cols),
        @intCast(self.screen.rows),
    );
}

pub fn resize(self: *Self, cols: usize, rows: usize) !void {
    try self.screen.resize(cols, rows);
    if (self.pty) |*pty| {
        try pty.setWindowSize(@intCast(cols), @intCast(rows));
    }
    self.needs_render = true;
}

pub fn processInput(self: *Self) !void {
    if (self.pty) |*pty| {
        var buffer: [4096]u8 = undefined;
        const has_data = try pty.hasData();
        if (has_data) {
            const n = try pty.read(&buffer);
            if (n > 0) {
                try self.handleInput(buffer[0..n]);
                self.needs_render = true;
            }
        }
    }
}

pub fn handleInput(self: *Self, input: []const u8) !void {
    var sequences = std.ArrayList(Parser.EscapeSequence).init(self.allocator);
    defer {
        for (sequences.items) |seq| {
            switch (seq) {
                .select_graphic_rendition => |params| self.allocator.free(params),
                .set_title, .set_icon_name => |data| self.allocator.free(data),
                .osc_generic => |osc| self.allocator.free(osc.data),
                .dcs_generic => |dcs| self.allocator.free(dcs.data),
                else => {},
            }
        }
        sequences.deinit();
    }

    try self.parser.parse(input, &sequences);

    for (sequences.items) |seq| {
        try self.executeSequence(seq);
    }
}

fn executeSequence(self: *Self, seq: Parser.EscapeSequence) !void {
    switch (seq) {
        .print => |char| {
            self.screen.writeChar(char);
            if (self.scroll_offset > 0) {
                self.scroll_offset = 0;
            }
        },
        .bell => {},
        .backspace => {
            if (self.screen.cursor.x > 0) {
                self.screen.moveCursorRelative(-1, 0);
            }
        },
        .carriage_return => {
            self.screen.moveCursor(0, null);
        },
        .line_feed, .cursor_next_line => {
            self.screen.moveCursorRelative(0, 1);
        },
        .cursor_prev_line => {
            self.screen.moveCursorRelative(0, -1);
        },
        .form_feed, .vertical_tab => {
            self.screen.moveCursorRelative(0, 1);
        },
        .horizontal_tab => |count| {
            for (0..count) |_| {
                const next_tab = (self.screen.cursor.x / 8 + 1) * 8;
                self.screen.moveCursor(@min(next_tab, self.screen.cols - 1), null);
            }
        },
        .horizontal_tab_set => {},
        .tab_clear => |mode| {
            _ = mode;
        },
        .cursor_up => |n| {
            self.screen.moveCursorRelative(0, -@as(isize, @intCast(n)));
        },
        .cursor_down => |n| {
            self.screen.moveCursorRelative(0, @intCast(n));
        },
        .cursor_forward => |n| {
            self.screen.moveCursorRelative(@intCast(n), 0);
        },
        .cursor_back => |n| {
            self.screen.moveCursorRelative(-@as(isize, @intCast(n)), 0);
        },
        .cursor_horizontal_absolute => |col| {
            self.screen.moveCursor(col - 1, null);
        },
        .cursor_position => |pos| {
            self.screen.moveCursor(pos.col - 1, pos.row - 1);
        },
        .cursor_save => {
            self.screen.saveCursor();
        },
        .cursor_restore => {
            self.screen.restoreCursor();
        },
        .erase_in_display => |mode| {
            self.screen.clearScreen(mode);
        },
        .erase_in_line => |mode| {
            self.screen.clearLine(mode);
        },
        .scroll_up => |n| {
            self.screen.scrollUp(n);
        },
        .scroll_down => |n| {
            self.screen.scrollDown(n);
        },
        .insert_lines => |n| {
            self.screen.insertLines(n);
        },
        .delete_lines => |n| {
            self.screen.deleteLines(n);
        },
        .insert_chars => |n| {
            self.screen.insertChars(n);
        },
        .delete_chars => |n| {
            self.screen.deleteChars(n);
        },
        .select_graphic_rendition => |params| {
            Parser.applySgr(&self.screen, params);
        },
        .set_scrolling_region => |region| {
            self.screen.setScrollRegion(region.top, region.bottom);
        },
        .set_mode => |mode| {
            _ = mode;
        },
        .soft_reset => {
            self.screen.resetScrollRegion();
            self.screen.resetAttributes();
        },
        .set_title => |title| {
            _ = title;
        },
        .set_icon_name => |name| {
            _ = name;
        },
        else => {},
    }
}

pub fn writeToPty(self: *Self, data: []const u8) !void {
    if (self.pty) |*pty| {
        try pty.write(data);
    }
}

pub fn sendKey(self: *Self, key: []const u8) !void {
    try self.writeToPty(key);
}

pub fn sendChar(self: *Self, char: u8) !void {
    const buf = [1]u8{char};
    try self.writeToPty(&buf);
}

pub fn isRunning(self: *Self) bool {
    if (self.pty) |*pty| {
        return pty.isRunning();
    }
    return false;
}
