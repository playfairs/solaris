const std = @import("std");

pub const KeyEvent = struct {
    key: Key,
    modifiers: Modifiers,
    action: Action,

    pub const Key = union(enum) {
        character: u21,
        special: Special,
    };

    pub const Special = enum {
        escape,
        return_key,
        tab,
        backspace,
        delete,
        insert,
        home,
        end,
        page_up,
        page_down,
        up,
        down,
        left,
        right,
        f1, f2, f3, f4, f5, f6, f7, f8, f9, f10, f11, f12,
        space,
        enter,
    };

    pub const Modifiers = packed struct {
        shift: bool = false,
        control: bool = false,
        alt: bool = false,
        command: bool = false,
        caps_lock: bool = false,
        _padding: u3 = 0,
    };

    pub const Action = enum {
        press,
        repeat,
        release,
    };
};

pub fn keyToEscapeSequence(allocator: std.mem.Allocator, event: KeyEvent) ![]const u8 {
    const mods = event.modifiers;
    
    switch (event.key) {
        .special => |key| {
            const base_seq = switch (key) {
                .escape => return try allocator.dupe(u8, "\x1b"),
                .return_key, .enter => return try allocator.dupe(u8, "\r"),
                .tab => {
                    if (mods.shift) return try allocator.dupe(u8, "\x1b[Z");
                    return try allocator.dupe(u8, "\t");
                },
                .backspace => return try allocator.dupe(u8, "\x7f"),
                .delete => return try allocator.dupe(u8, "\x1b[3~"),
                .insert => return try allocator.dupe(u8, "\x1b[2~"),
                .home => return try allocator.dupe(u8, "\x1b[H"),
                .end => return try allocator.dupe(u8, "\x1b[F"),
                .page_up => return try allocator.dupe(u8, "\x1b[5~"),
                .page_down => return try allocator.dupe(u8, "\x1b[6~"),
                .up => {
                    if (mods.control) return try allocator.dupe(u8, "\x1b[1;5A");
                    if (mods.shift) return try allocator.dupe(u8, "\x1b[1;2A");
                    return try allocator.dupe(u8, "\x1b[A");
                },
                .down => {
                    if (mods.control) return try allocator.dupe(u8, "\x1b[1;5B");
                    if (mods.shift) return try allocator.dupe(u8, "\x1b[1;2B");
                    return try allocator.dupe(u8, "\x1b[B");
                },
                .right => {
                    if (mods.control) return try allocator.dupe(u8, "\x1b[1;5C");
                    if (mods.shift) return try allocator.dupe(u8, "\x1b[1;2C");
                    return try allocator.dupe(u8, "\x1b[C");
                },
                .left => {
                    if (mods.control) return try allocator.dupe(u8, "\x1b[1;5D");
                    if (mods.shift) return try allocator.dupe(u8, "\x1b[1;2D");
                    return try allocator.dupe(u8, "\x1b[D");
                },
                .f1 => return try allocator.dupe(u8, "\x1bOP"),
                .f2 => return try allocator.dupe(u8, "\x1bOQ"),
                .f3 => return try allocator.dupe(u8, "\x1bOR"),
                .f4 => return try allocator.dupe(u8, "\x1bOS"),
                .f5 => return try allocator.dupe(u8, "\x1b[15~"),
                .f6 => return try allocator.dupe(u8, "\x1b[17~"),
                .f7 => return try allocator.dupe(u8, "\x1b[18~"),
                .f8 => return try allocator.dupe(u8, "\x1b[19~"),
                .f9 => return try allocator.dupe(u8, "\x1b[20~"),
                .f10 => return try allocator.dupe(u8, "\x1b[21~"),
                .f11 => return try allocator.dupe(u8, "\x1b[23~"),
                .f12 => return try allocator.dupe(u8, "\x1b[24~"),
                .space => return try allocator.dupe(u8, " "),
            }
            return base_seq;
        },
        .character => |char| {
            if (mods.control) {
                const ctrl_char: u8 = switch (char) {
                    '@' => 0,
                    'a'...'z' => char - 'a' + 1,
                    '[' => 27,
                    ']' => 29,
                    '\\' => 28,
                    '^' => 30,
                    '_' => 31,
                    '?' => 127,
                    else => return null,
                };
                return try std.fmt.allocPrint(allocator, "{c}", .{ctrl_char});
            }
            
            if (mods.alt) {
                const buf = try allocator.alloc(u8, std.unicode.utf8Size(char) + 1);
                buf[0] = '\x1b';
                _ = std.unicode.utf8Encode(char, buf[1..]) catch unreachable;
                return buf;
            }
            
            const buf = try allocator.alloc(u8, std.unicode.utf8Size(char));
            _ = std.unicode.utf8Encode(char, buf) catch unreachable;
            return buf;
        },
    }
}
