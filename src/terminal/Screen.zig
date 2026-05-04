const std = @import("std");

pub const Cell = struct {
    char: u21 = ' ',
    fg_color: Color = .{ .rgb = .{ 220, 220, 220 } },
    bg_color: Color = .{ .rgb = .{ 0, 0, 0 } },
    attrs: Attributes = .{},
    wide: bool = false,
    dirty: bool = true,

    pub const Attributes = packed struct {
        bold: bool = false,
        italic: bool = false,
        underline: bool = false,
        strikethrough: bool = false,
        blink: bool = false,
        reverse: bool = false,
        invisible: bool = false,
        _padding: u1 = 0,
    };
};

pub const Color = union(enum) {
    default: void,
    palette: u8,
    rgb: [3]u8,
};

pub const ScrollbackLine = struct {
    cells: []Cell,

    pub fn deinit(self: *ScrollbackLine, allocator: std.mem.Allocator) void {
        allocator.free(self.cells);
    }
};

allocator: std.mem.Allocator,
cols: usize,
rows: usize,
buffer: []Cell,
scrollback: std.ArrayList(ScrollbackLine),
scrollback_limit: usize,
cursor: Cursor,
saved_cursor: Cursor,
scroll_region: ?struct { top: usize, bottom: usize },

pub const Cursor = struct {
    x: usize = 0,
    y: usize = 0,
    attrs: Cell.Attributes = .{},
    fg_color: Cell.Color = .{ .rgb = .{ 220, 220, 220 } },
    bg_color: Cell.Color = .{ .rgb = .{ 0, 0, 0 } },
    visible: bool = true,
};

const Self = @This();

pub fn init(allocator: std.mem.Allocator, cols: usize, rows: usize) !Self {
    const buffer = try allocator.alloc(Cell, cols * rows);
    @memset(buffer, Cell{});

    return .{
        .allocator = allocator,
        .cols = cols,
        .rows = rows,
        .buffer = buffer,
        .scrollback = std.ArrayList(ScrollbackLine).init(allocator),
        .scrollback_limit = 10000,
        .cursor = .{},
        .saved_cursor = .{},
        .scroll_region = null,
    };
}

pub fn deinit(self: *Self) void {
    for (self.scrollback.items) |*line| {
        line.deinit(self.allocator);
    }
    self.scrollback.deinit();
    self.allocator.free(self.buffer);
}

pub fn resize(self: *Self, new_cols: usize, new_rows: usize) !void {
    if (new_cols == self.cols and new_rows == self.rows) return;

    const new_buffer = try self.allocator.alloc(Cell, new_cols * new_rows);
    @memset(new_buffer, Cell{});

    const min_rows = @min(self.rows, new_rows);
    const min_cols = @min(self.cols, new_cols);

    for (0..min_rows) |row| {
        for (0..min_cols) |col| {
            new_buffer[row * new_cols + col] = self.buffer[row * self.cols + col];
        }
    }

    self.allocator.free(self.buffer);
    self.buffer = new_buffer;
    self.cols = new_cols;
    self.rows = new_rows;

    self.cursor.x = @min(self.cursor.x, self.cols - 1);
    self.cursor.y = @min(self.cursor.y, self.rows - 1);

    self.markAllDirty();
}

fn markAllDirty(self: *Self) void {
    for (self.buffer) |*cell| {
        cell.dirty = true;
    }
}

pub fn getCell(self: *Self, col: usize, row: usize) ?*Cell {
    if (col >= self.cols or row >= self.rows) return null;
    return &self.buffer[row * self.cols + col];
}

pub fn clearLine(self: *Self, mode: enum { right, left, all }) void {
    const row = self.cursor.y;
    if (row >= self.rows) return;

    switch (mode) {
        .right => {
            for (self.cursor.x..self.cols) |col| {
                const cell = &self.buffer[row * self.cols + col];
                cell.* = Cell{ .dirty = true };
            }
        },
        .left => {
            for (0..self.cursor.x + 1) |col| {
                const cell = &self.buffer[row * self.cols + col];
                cell.* = Cell{ .dirty = true };
            }
        },
        .all => {
            for (0..self.cols) |col| {
                const cell = &self.buffer[row * self.cols + col];
                cell.* = Cell{ .dirty = true };
            }
        },
    }
}

pub fn clearScreen(self: *Self, mode: enum { below, above, all }) void {
    switch (mode) {
        .below => {
            self.clearLine(.right);
            for (self.cursor.y + 1..self.rows) |row| {
                for (0..self.cols) |col| {
                    const cell = &self.buffer[row * self.cols + col];
                    cell.* = Cell{ .dirty = true };
                }
            }
        },
        .above => {
            self.clearLine(.left);
            for (0..self.cursor.y) |row| {
                for (0..self.cols) |col| {
                    const cell = &self.buffer[row * self.cols + col];
                    cell.* = Cell{ .dirty = true };
                }
            }
        },
        .all => {
            for (self.buffer) |*cell| {
                cell.* = Cell{ .dirty = true };
            }
        },
    }
}

pub fn scrollUp(self: *Self, lines: usize) void {
    const top = if (self.scroll_region) |r| r.top else 0;
    const bottom = if (self.scroll_region) |r| r.bottom else self.rows - 1;

    for (0..lines) |_| {
        if (top == 0 and self.scrollback_limit > 0) {
            if (self.scrollback.items.len >= self.scrollback_limit) {
                var first = self.scrollback.orderedRemove(0);
                first.deinit(self.allocator);
            }

            const line_cells = self.allocator.alloc(Cell, self.cols) catch continue;
            @memcpy(line_cells, self.buffer[0..self.cols]);
            self.scrollback.append(.{ .cells = line_cells }) catch {
                self.allocator.free(line_cells);
                continue;
            };
        }

        for (top..bottom) |row| {
            const dst_start = row * self.cols;
            const src_start = (row + 1) * self.cols;
            @memcpy(self.buffer[dst_start .. dst_start + self.cols], self.buffer[src_start .. src_start + self.cols]);
        }

        for (bottom * self.cols..(bottom + 1) * self.cols) |i| {
            self.buffer[i] = Cell{ .dirty = true };
        }
    }
}

pub fn scrollDown(self: *Self, lines: usize) void {
    const top = if (self.scroll_region) |r| r.top else 0;
    const bottom = if (self.scroll_region) |r| r.bottom else self.rows - 1;

    for (0..lines) |_| {
        var row: usize = bottom;
        while (row > top) {
            row -= 1;
            const dst_start = (row + 1) * self.cols;
            const src_start = row * self.cols;
            @memcpy(self.buffer[dst_start .. dst_start + self.cols], self.buffer[src_start .. src_start + self.cols]);
        }

        for (top * self.cols..(top + 1) * self.cols) |i| {
            self.buffer[i] = Cell{ .dirty = true };
        }
    }
}

pub fn insertLines(self: *Self, count: usize) void {
    const top = self.cursor.y;
    const bottom = if (self.scroll_region) |r| r.bottom else self.rows - 1;
    const actual_count = @min(count, bottom - top + 1);

    var row: usize = bottom - actual_count + 1;
    while (row > top) {
        row -= 1;
        const dst_start = (row + actual_count) * self.cols;
        const src_start = row * self.cols;
        @memcpy(self.buffer[dst_start .. dst_start + self.cols], self.buffer[src_start .. src_start + self.cols]);
    }

    for (top..top + actual_count) |r| {
        for (r * self.cols..(r + 1) * self.cols) |i| {
            self.buffer[i] = Cell{ .dirty = true };
        }
    }
}

pub fn deleteLines(self: *Self, count: usize) void {
    const top = if (self.scroll_region) |r| r.top else 0;
    _ = top;
    const bottom = if (self.scroll_region) |r| r.bottom else self.rows - 1;
    const actual_count = @min(count, bottom - self.cursor.y + 1);

    for (self.cursor.y..bottom - actual_count + 1) |row| {
        const dst_start = row * self.cols;
        const src_start = (row + actual_count) * self.cols;
        @memcpy(self.buffer[dst_start .. dst_start + self.cols], self.buffer[src_start .. src_start + self.cols]);
    }

    for (bottom - actual_count + 1..bottom + 1) |r| {
        for (r * self.cols..(r + 1) * self.cols) |i| {
            self.buffer[i] = Cell{ .dirty = true };
        }
    }
}

pub fn insertChars(self: *Self, count: usize) void {
    const row = self.cursor.y;
    const actual_count = @min(count, self.cols - self.cursor.x);

    var col: usize = self.cols - actual_count;
    while (col > self.cursor.x) {
        col -= 1;
        self.buffer[row * self.cols + col + actual_count] = self.buffer[row * self.cols + col];
    }

    for (self.cursor.x..self.cursor.x + actual_count) |c| {
        self.buffer[row * self.cols + c] = Cell{ .dirty = true };
    }
}

pub fn deleteChars(self: *Self, count: usize) void {
    const row = self.cursor.y;
    const actual_count = @min(count, self.cols - self.cursor.x);

    for (self.cursor.x..self.cols - actual_count) |col| {
        self.buffer[row * self.cols + col] = self.buffer[row * self.cols + col + actual_count];
    }

    for (self.cols - actual_count..self.cols) |col| {
        self.buffer[row * self.cols + col] = Cell{ .dirty = true };
    }
}

pub fn writeChar(self: *Self, char: u21) void {
    const cell = &self.buffer[self.cursor.y * self.cols + self.cursor.x];
    cell.char = char;
    cell.fg_color = self.cursor.fg_color;
    cell.bg_color = self.cursor.bg_color;
    cell.attrs = self.cursor.attrs;
    cell.dirty = true;
    cell.wide = @intFromBool(char > 0xFF);

    self.cursor.x += 1;
    if (self.cursor.x >= self.cols) {
        self.cursor.x = 0;
        self.cursor.y += 1;
        if (self.cursor.y >= self.rows) {
            self.cursor.y = self.rows - 1;
            self.scrollUp(1);
        }
    }
}

pub fn moveCursor(self: *Self, x: ?usize, y: ?usize) void {
    if (x) |new_x| self.cursor.x = @min(new_x, self.cols - 1);
    if (y) |new_y| self.cursor.y = @min(new_y, self.rows - 1);
}

pub fn moveCursorRelative(self: *Self, dx: isize, dy: isize) void {
    const new_x = @as(isize, @intCast(self.cursor.x)) + dx;
    const new_y = @as(isize, @intCast(self.cursor.y)) + dy;
    self.cursor.x = @intCast(@max(0, @min(new_x, @as(isize, @intCast(self.cols - 1)))));
    self.cursor.y = @intCast(@max(0, @min(new_y, @as(isize, @intCast(self.rows - 1)))));
}

pub fn saveCursor(self: *Self) void {
    self.saved_cursor = self.cursor;
}

pub fn restoreCursor(self: *Self) void {
    self.cursor = self.saved_cursor;
}

pub fn setScrollRegion(self: *Self, top: ?usize, bottom: ?usize) void {
    const t = top orelse 0;
    const b = bottom orelse self.rows - 1;
    if (t < b and b < self.rows) {
        self.scroll_region = .{ .top = t, .bottom = b };
        self.cursor.x = 0;
        self.cursor.y = t;
    }
}

pub fn resetScrollRegion(self: *Self) void {
    self.scroll_region = null;
}

pub fn setForegroundColor(self: *Self, color: Cell.Color) void {
    self.cursor.fg_color = color;
}

pub fn setBackgroundColor(self: *Self, color: Cell.Color) void {
    self.cursor.bg_color = color;
}

pub fn setAttribute(self: *Self, attr: Cell.Attributes) void {
    self.cursor.attrs = attr;
}

pub fn resetAttributes(self: *Self) void {
    self.cursor.attrs = .{};
    self.cursor.fg_color = .{ .rgb = .{ 220, 220, 220 } };
    self.cursor.bg_color = .{ .rgb = .{ 0, 0, 0 } };
}
