const std = @import("std");

allocator: std.mem.Allocator,

font_family: []const u8,
font_size: f32,

background_image_path: ?[]const u8,
background_overlay_opacity: f32,

shell_path: []const u8,
cols: usize,
rows: usize,
padding: u32,

window_width: u32,
window_height: u32,

const Self = @This();

pub const default_font_family = "SF Mono";
pub const default_font_size: f32 = 14.0;
pub const default_shell = "/bin/zsh";
pub const default_cols: usize = 80;
pub const default_rows: usize = 24;
pub const default_padding: u32 = 8;
pub const default_overlay_opacity: f32 = 0.15;

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .allocator = allocator,
        .font_family = allocator.dupe(u8, default_font_family) catch unreachable,
        .font_size = default_font_size,
        .background_image_path = null,
        .background_overlay_opacity = default_overlay_opacity,
        .shell_path = allocator.dupe(u8, default_shell) catch unreachable,
        .cols = default_cols,
        .rows = default_rows,
        .padding = default_padding,
        .window_width = 800,
        .window_height = 600,
    };
}

pub fn deinit(self: *Self) void {
    self.allocator.free(self.font_family);
    if (self.background_image_path) |path| {
        self.allocator.free(path);
    }
    self.allocator.free(self.shell_path);
}

pub fn loadFromFile(self: *Self, path: []const u8) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const content = try file.readToEndAlloc(self.allocator, 1 * 1024 * 1024);
    defer self.allocator.free(content);

    try self.parse(content);
}

pub fn loadDefault(self: *Self) !void {
    const home = std.process.getEnvVarOwned(self.allocator, "HOME") catch |err| {
        if (err == error.EnvironmentVariableNotFound) {
            return;
        }
        return err;
    };
    defer self.allocator.free(home);

    const config_path = try std.fs.path.join(self.allocator, &.{ home, ".config", "solaris", "config" });
    defer self.allocator.free(config_path);

    self.loadFromFile(config_path) catch |err| {
        if (err == error.FileNotFound) {
            const shell = std.process.getEnvVarOwned(self.allocator, "SHELL") catch |shell_err| {
                if (shell_err == error.EnvironmentVariableNotFound) {
                    return;
                }
                return shell_err;
            };
            defer self.allocator.free(self.shell_path);
            self.shell_path = shell;
        } else {
            return err;
        }
    };
}

fn parse(self: *Self, content: []const u8) !void {
    var lines = std.mem.splitScalar(u8, content, '\n');

    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (std.mem.indexOfScalar(u8, trimmed, '=')) |eq_pos| {
            const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
            const value = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t\"'");

            try self.setValue(key, value);
        }
    }
}

fn setValue(self: *Self, key: []const u8, value: []const u8) !void {
    if (std.mem.eql(u8, key, "font_family")) {
        self.allocator.free(self.font_family);
        self.font_family = try self.allocator.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "font_size")) {
        self.font_size = std.fmt.parseFloat(f32, value) catch default_font_size;
    } else if (std.mem.eql(u8, key, "background_image")) {
        if (self.background_image_path) |path| {
            self.allocator.free(path);
        }
        self.background_image_path = try self.allocator.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "background_overlay_opacity")) {
        self.background_overlay_opacity = std.fmt.parseFloat(f32, value) catch default_overlay_opacity;
    } else if (std.mem.eql(u8, key, "shell")) {
        self.allocator.free(self.shell_path);
        self.shell_path = try self.allocator.dupe(u8, value);
    } else if (std.mem.eql(u8, key, "padding")) {
        self.padding = std.fmt.parseInt(u32, value, 10) catch default_padding;
    } else if (std.mem.eql(u8, key, "cols")) {
        self.cols = std.fmt.parseInt(usize, value, 10) catch default_cols;
    } else if (std.mem.eql(u8, key, "rows")) {
        self.rows = std.fmt.parseInt(usize, value, 10) catch default_rows;
    } else if (std.mem.eql(u8, key, "window_width")) {
        self.window_width = std.fmt.parseInt(u32, value, 10) catch 800;
    } else if (std.mem.eql(u8, key, "window_height")) {
        self.window_height = std.fmt.parseInt(u32, value, 10) catch 600;
    }
}
