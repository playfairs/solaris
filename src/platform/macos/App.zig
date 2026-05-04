const std = @import("std");
const c = @cImport({
    @cInclude("objc/runtime.h");
    @cInclude("objc/message.h");
    @cInclude("Cocoa/Cocoa.h");
});

const Window = @import("Window.zig");
const Config = @import("../../config/Config.zig");
const Keyboard = @import("../../input/Keyboard.zig");
const Mouse = @import("../../input/Mouse.zig");

allocator: std.mem.Allocator,
config: Config,
window: Window,
delegate_class: ?*c.objc_class,

const Self = @This();

pub fn init(allocator: std.mem.Allocator) !Self {
    var config = Config.init(allocator);
    try config.loadDefault();

    return .{
        .allocator = allocator,
        .config = config,
        .window = try Window.init(allocator, &config),
        .delegate_class = null,
    };
}

pub fn deinit(self: *Self) void {
    self.window.deinit();
    self.config.deinit();
}

pub fn run(self: *Self) !void {
    try self.createDelegateClass();

    try self.window.create();

    try self.window.run();
}

fn createDelegateClass(self: *Self) !void {
    const super_class = c.objc_getClass("NSObject");
    const delegate_class = c.objc_allocateClassPair(super_class, "SolarisAppDelegate", 0);

    if (delegate_class == null) {
        return error.ClassAllocationFailed;
    }

    const window_ivar_name = "window_";
    const window_type = "^";
    _ = c.class_addIvar(delegate_class, window_ivar_name, @sizeOf(*c.NSWindow), @alignOf(*c.NSWindow), window_type);

    const app_will_finish_sel = c.sel_registerName("applicationWillFinishLaunching:");
    _ = c.class_addMethod(delegate_class, app_will_finish_sel, @intCast(@intFromPtr(&appWillFinishLaunching)), "v@:@");

    const app_will_terminate_sel = c.sel_registerName("applicationWillTerminate:");
    _ = c.class_addMethod(delegate_class, app_will_terminate_sel, @intCast(@intFromPtr(&appWillTerminate)), "v@:@");

    const key_down_sel = c.sel_registerName("keyDown:");
    _ = c.class_addMethod(delegate_class, key_down_sel, @intCast(@intFromPtr(&keyDown)), "v@:@");

    c.objc_registerClassPair(delegate_class);
    self.delegate_class = delegate_class;

    const alloc_sel = c.sel_registerName("alloc");
    const init_sel = c.sel_registerName("init");
    const delegate = c.objc_msgSend(delegate_class, alloc_sel);
    _ = c.objc_msgSend(delegate, init_sel);

    const ns_app_class = c.objc_getClass("NSApplication");
    const shared_app_sel = c.sel_registerName("sharedApplication");
    const ns_app = c.objc_msgSend(ns_app_class, shared_app_sel);

    const set_delegate_sel = c.sel_registerName("setDelegate:");
    _ = c.objc_msgSend(ns_app, set_delegate_sel, delegate);
}

fn appWillFinishLaunching(self_id: *c.objc_object, _: c.SEL, notification: *c.objc_object) callconv(.C) void {
    _ = self_id;
    _ = notification;
}

fn appWillTerminate(self_id: *c.objc_object, _: c.SEL, notification: *c.objc_object) callconv(.C) void {
    _ = self_id;
    _ = notification;
}

fn keyDown(self_id: *c.objc_object, _: c.SEL, event: *c.NSEvent) callconv(.C) void {
    _ = self_id;

    const key_code_sel = c.sel_registerName("keyCode");
    const key_code: u16 = @intCast(@intFromPtr(c.objc_msgSend(event, key_code_sel)));

    const modifier_flags_sel = c.sel_registerName("modifierFlags");
    const modifier_flags: c.NSEventModifierFlags = @intCast(@intFromPtr(c.objc_msgSend(event, modifier_flags_sel)));

    const modifiers = Keyboard.KeyEvent.Modifiers{
        .shift = (modifier_flags & c.NSEventModifierFlagShift) != 0,
        .control = (modifier_flags & c.NSEventModifierFlagControl) != 0,
        .alt = (modifier_flags & c.NSEventModifierFlagOption) != 0,
        .command = (modifier_flags & c.NSEventModifierFlagCommand) != 0,
        .caps_lock = (modifier_flags & c.NSEventModifierFlagCapsLock) != 0,
    };

    const chars_sel = c.sel_registerName("characters");
    const chars = c.objc_msgSend(event, chars_sel);
    const utf8_sel = c.sel_registerName("UTF8String");
    const utf8_str: [*c]const u8 = @ptrCast(c.objc_msgSend(chars, utf8_sel));

    const char_len = std.mem.len(utf8_str);
    if (char_len > 0) {
        const codepoint = std.unicode.utf8Decode(utf8_str[0..char_len]) catch |err| {
            std.log.warn("Invalid UTF-8: {}", .{err});
            return;
        };

        const key_event = Keyboard.KeyEvent{
            .key = .{ .character = codepoint },
            .modifiers = modifiers,
            .action = .press,
        };

        // send to window (we need to store a global reference or use associated objects)
        // for temporary simplicity we will just handle this differently
        _ = key_event;
        _ = key_code;
    }
}
