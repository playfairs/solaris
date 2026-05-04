const std = @import("std");

const App = @import("platform/macos/App.zig");

pub fn main() !void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer _ = arena.deinit();

    const allocator = arena.allocator();

    var app = try App.init(allocator);
    defer app.deinit();

    try app.run();
}
