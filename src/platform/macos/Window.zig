const std = @import("std");
const c = @cImport({
    @cInclude("objc/runtime.h");
    @cInclude("objc/message.h");
    @cInclude("Cocoa/Cocoa.h");
    @cInclude("QuartzCore/CAMetalLayer.h");
});

const Renderer = @import("../../renderer/Renderer.zig");
const Terminal = @import("../../terminal/Terminal.zig");
const Config = @import("../../config/Config.zig");
const Keyboard = @import("../../input/Keyboard.zig");
const Mouse = @import("../../input/Mouse.zig");

allocator: std.mem.Allocator,
config: *const Config,
window: ?*c.NSWindow,
metal_layer: ?*c.CAMetalLayer,
view: ?*c.NSView,
renderer: ?*Renderer,
terminal: ?*Terminal,
running: bool,
needs_display: bool,

shader_source: []const u8,

const Self = @This();

pub fn init(allocator: std.mem.Allocator, config: *const Config) !Self {
    return .{
        .allocator = allocator,
        .config = config,
        .window = null,
        .metal_layer = null,
        .view = null,
        .renderer = null,
        .terminal = null,
        .running = false,
        .needs_display = true,
        .shader_source = "",
    };
}

pub fn deinit(self: *Self) void {
    if (self.renderer) |renderer| {
        renderer.deinit();
        self.allocator.destroy(renderer);
    }
    if (self.terminal) |terminal| {
        terminal.deinit();
        self.allocator.destroy(terminal);
    }
    self.allocator.free(self.shader_source);
}

pub fn create(self: *Self) !void {
    self.shader_source = try loadShaders(self.allocator);

    const ns_app_class = c.objc_getClass("NSApplication");
    const shared_app_sel = c.sel_registerName("sharedApplication");
    const ns_app = c.objc_msgSend(ns_app_class, shared_app_sel);

    const set_policy_sel = c.sel_registerName("setActivationPolicy:");
    _ = c.objc_msgSend(ns_app, set_policy_sel, @as(c.NSApplicationActivationPolicy, c.NSApplicationActivationPolicyRegular));

    const style_mask: c.NSWindowStyleMask = c.NSWindowStyleMaskBorderless | c.NSWindowStyleMaskResizable | c.NSWindowStyleMaskClosable | c.NSWindowStyleMaskMiniaturizable | c.NSWindowStyleMaskFullSizeContentView;

    const window_rect = c.NSMakeRect(0, 0, @floatFromInt(self.config.window_width), @floatFromInt(self.config.window_height));

    const window_class = c.objc_getClass("NSWindow");
    const alloc_sel = c.sel_registerName("alloc");
    const init_sel = c.sel_registerName("initWithContentRect:styleMask:backing:defer:");

    const window = c.objc_msgSend(window_class, alloc_sel);
    self.window = @ptrCast(c.objc_msgSend(window, init_sel, window_rect, style_mask, @as(c.NSBackingStoreType, c.NSBackingStoreBuffered), false));

    if (self.window == null) {
        return error.WindowCreationFailed;
    }

    const center_sel = c.sel_registerName("center");
    _ = c.objc_msgSend(self.window.?, center_sel);

    const title_sel = c.sel_registerName("setTitle:");
    const ns_string_class = c.objc_getClass("NSString");
    const str_sel = c.sel_registerName("stringWithUTF8String:");
    const title = c.objc_msgSend(ns_string_class, str_sel, "Solaritty");
    _ = c.objc_msgSend(self.window.?, title_sel, title);

    const set_titlebar_sel = c.sel_registerName("setTitlebarAppearsTransparent:");
    _ = c.objc_msgSend(self.window.?, set_titlebar_sel, true);

    const set_title_vis_sel = c.sel_registerName("setTitleVisibility:");
    _ = c.objc_msgSend(self.window.?, set_title_vis_sel, @as(c.NSWindowTitleVisibility, c.NSWindowTitleVisibilityHidden));

    const set_opaque_sel = c.sel_registerName("setOpaque:");
    _ = c.objc_msgSend(self.window.?, set_opaque_sel, false);

    const set_bkg_sel = c.sel_registerName("setBackgroundColor:");
    const color_class = c.objc_getClass("NSColor");
    const clear_color_sel = c.sel_registerName("clearColor");
    const clear_color = c.objc_msgSend(color_class, clear_color_sel);
    _ = c.objc_msgSend(self.window.?, set_bkg_sel, clear_color);

    const set_corner_radius = c.sel_registerName("setCornerRadius:");
    _ = c.objc_msgSend(self.window.?, set_corner_radius, @as(f64, 10.0));

    const view_class = c.objc_getClass("NSView");
    const view_alloc = c.objc_msgSend(view_class, alloc_sel);

    const content_rect_sel = c.sel_registerName("contentRectForFrameRect:");
    const content_rect: c.NSRect = @bitCast(c.objc_msgSend(self.window.?, content_rect_sel, window_rect));

    const init_frame_sel = c.sel_registerName("initWithFrame:");
    const view = c.objc_msgSend(view_alloc, init_frame_sel, content_rect);
    self.view = @ptrCast(view);

    try self.setupMetalLayer();

    const set_content_sel = c.sel_registerName("setContentView:");
    _ = c.objc_msgSend(self.window.?, set_content_sel, view);

    const renderer = try self.allocator.create(Renderer);
    renderer.* = try Renderer.init(self.allocator, self.config);
    self.renderer = renderer;

    if (self.config.background_image_path) |path| {
        self.renderer.?.loadBackgroundImage(path) catch |err| {
            std.log.warn("Failed to load background image: {}", .{err});
        };
    }

    try self.renderer.?.metal.loadShaders(self.shader_source);
    try self.renderer.?.metal.createBackgroundPipeline();
    try self.renderer.?.metal.createCellPipeline();
    try self.renderer.?.metal.createGlyphAtlas(2048);

    const terminal = try self.allocator.create(Terminal);
    terminal.* = try Terminal.init(self.allocator, self.config.cols, self.config.rows, self.config.shell_path);
    self.terminal = terminal;

    try self.terminal.?.spawn();

    const make_key_sel = c.sel_registerName("makeKeyAndOrderFront:");
    _ = c.objc_msgSend(self.window.?, make_key_sel, null);

    const activate_sel = c.sel_registerName("activateIgnoringOtherApps:");
    _ = c.objc_msgSend(ns_app, activate_sel, true);

    self.running = true;
}

fn setupMetalLayer(self: *Self) !void {
    if (self.view == null) return error.NoView;

    const layer_class = c.objc_getClass("CAMetalLayer");
    const alloc_sel = c.sel_registerName("alloc");
    const init_sel = c.sel_registerName("init");

    const metal_layer = c.objc_msgSend(layer_class, alloc_sel);
    self.metal_layer = @ptrCast(c.objc_msgSend(metal_layer, init_sel));

    if (self.metal_layer == null) {
        return error.MetalLayerCreationFailed;
    }

    const set_device_sel = c.sel_registerName("setDevice:");
    _ = c.objc_msgSend(self.metal_layer.?, set_device_sel, self.renderer.?.metal.device);

    const set_pixel_format_sel = c.sel_registerName("setPixelFormat:");
    _ = c.objc_msgSend(self.metal_layer.?, set_pixel_format_sel, @as(c.MTLPixelFormat, c.MTLPixelFormatBGRA8Unorm_sRGB));

    const set_fb_only_sel = c.sel_registerName("setFramebufferOnly:");
    _ = c.objc_msgSend(self.metal_layer.?, set_fb_only_sel, true);

    const set_scale_sel = c.sel_registerName("setContentsScale:");
    const screen_sel = c.sel_registerName("screen");
    const screen = c.objc_msgSend(self.window.?, screen_sel);
    const backing_scale_sel = c.sel_registerName("backingScaleFactor");
    const scale: f64 = @bitCast(c.objc_msgSend(screen, backing_scale_sel));
    _ = c.objc_msgSend(self.metal_layer.?, set_scale_sel, scale);

    const set_layer_sel = c.sel_registerName("setLayer:");
    _ = c.objc_msgSend(self.view.?, set_layer_sel, self.metal_layer.?);

    const set_wants_layer = c.sel_registerName("setWantsLayer:");
    _ = c.objc_msgSend(self.view.?, set_wants_layer, true);

    const set_policy_sel = c.sel_registerName("setLayerContentsRedrawPolicy:");
    _ = c.objc_msgSend(self.view.?, set_policy_sel, @as(c.NSViewLayerContentsRedrawPolicy, c.NSViewLayerContentsRedrawPolicyDuringViewResize));
}

pub fn run(self: *Self) !void {
    if (!self.running) return;

    const ns_app_class = c.objc_getClass("NSApplication");
    const shared_app_sel = c.sel_registerName("sharedApplication");
    const ns_app = c.objc_msgSend(ns_app_class, shared_app_sel);

    while (self.running) {
        const mode_sel = c.sel_registerName("defaultRunLoopMode");
        const mode = c.objc_msgSend(c.objc_getClass("NSRunLoop"), mode_sel);
        const distant_future_sel = c.sel_registerName("distantFuture");
        const distant_future = c.objc_msgSend(c.objc_getClass("NSDate"), distant_future_sel);

        const next_event_sel = c.sel_registerName("nextEventMatchingMask:untilDate:inMode:dequeue:");
        const event = c.objc_msgSend(ns_app, next_event_sel, @as(c.NSEventMask, c.NSEventMaskAny), distant_future, mode, true);

        if (event) |e| {
            const send_event_sel = c.sel_registerName("sendEvent:");
            _ = c.objc_msgSend(ns_app, send_event_sel, e);
        }

        try self.terminal.?.processInput();

        if (self.terminal.?.needs_render or self.renderer.?.needsRerender(&self.terminal.?.screen)) {
            try self.render();
            self.terminal.?.needs_render = false;
            self.renderer.?.markRendered(&self.terminal.?.screen);
        }

        std.time.sleep(16_666_667);
    }
}

fn render(self: *Self) !void {
    if (self.window == null or self.metal_layer == null or self.renderer == null) return;

    const frame_sel = c.sel_registerName("frame");
    const frame: c.NSRect = @bitCast(c.objc_msgSend(self.view.?, frame_sel));
    const width = @as(u32, @intFromFloat(frame.size.width));
    const height = @as(u32, @intFromFloat(frame.size.height));

    if (width != self.renderer.?.width or height != self.renderer.?.height) {
        self.renderer.?.resize(width, height);

        const cell_width = self.renderer.?.cell_width;
        const cell_height = self.renderer.?.cell_height;
        const padding: f32 = @floatFromInt(self.config.padding);

        const cols = @as(usize, @intFromFloat(@max(1, (frame.size.width - padding * 2) / cell_width)));
        const rows = @as(usize, @intFromFloat(@max(1, (frame.size.height - padding * 2) / cell_height)));

        try self.terminal.?.resize(cols, rows);
    }

    try self.renderer.?.render(&self.terminal.?.screen, self.metal_layer.?, self.config.background_overlay_opacity);
}

pub fn handleKeyEvent(self: *Self, event: Keyboard.KeyEvent) !void {
    const seq = try Keyboard.keyToEscapeSequence(self.allocator, event);
    defer self.allocator.free(seq);

    try self.terminal.?.writeToPty(seq);
}

pub fn handleMouseEvent(self: *Self, event: Mouse.MouseEvent) !void {
    const cell_width = self.renderer.?.cell_width;
    const cell_height = self.renderer.?.cell_height;
    const padding: f32 = @floatFromInt(self.config.padding);

    const cell_pos = Mouse.screenToCell(event.x, event.y, cell_width, cell_height, padding);

    const seq = try Mouse.mouseToEscapeSequence(
        self.allocator,
        event,
        cell_pos.col,
        cell_pos.row,
        .none, // TODO: implement mouse tracking
    );

    if (seq) |s| {
        defer self.allocator.free(s);
        try self.terminal.?.writeToPty(s);
    }
}

pub fn terminate(self: *Self) void {
    self.running = false;
}

fn loadShaders(allocator: std.mem.Allocator) ![]const u8 {
    const cell_shader = @embedFile("../../../assets/shaders/cell.metal");
    const bg_shader = @embedFile("../../../assets/shaders/background.metal");

    const combined = try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ cell_shader, bg_shader });
    return combined;
}
