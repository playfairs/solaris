const std = @import("std");
const apl_runtime = @import("apl_runtime_trans_c");

const Renderer = @import("../../renderer/Renderer.zig");
const Terminal = @import("../../terminal/Terminal.zig");
const Config = @import("../../config/Config.zig");
const Keyboard = @import("../../input/Keyboard.zig");
const Mouse = @import("../../input/Mouse.zig");

allocator: std.mem.Allocator,
config: *const Config,
window: ?*apl_runtime.NSWindow,
metal_layer: ?*apl_runtime.CAMetalLayer,
view: ?*apl_runtime.NSView,
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

    const ns_app_class = apl_runtime.objc_getClass("NSApplication");
    const shared_app_sel = apl_runtime.sel_registerName("sharedApplication");
    const ns_app = apl_runtime.objc_msgSend(ns_app_class, shared_app_sel);

    const set_policy_sel = apl_runtime.sel_registerName("setActivationPolicy:");
    _ = apl_runtime.objc_msgSend(ns_app, set_policy_sel, @as(apl_runtime.NSApplicationActivationPolicy, apl_runtime.NSApplicationActivationPolicyRegular));

    const style_mask: apl_runtime.NSWindowStyleMask = apl_runtime.NSWindowStyleMaskBorderless | apl_runtime.NSWindowStyleMaskResizable | apl_runtime.NSWindowStyleMaskClosable | apl_runtime.NSWindowStyleMaskMiniaturizable | apl_runtime.NSWindowStyleMaskFullSizeContentView;

    const window_rect = apl_runtime.NSMakeRect(0, 0, @floatFromInt(self.config.window_width), @floatFromInt(self.config.window_height));

    const window_class = apl_runtime.objc_getClass("NSWindow");
    const alloc_sel = apl_runtime.sel_registerName("alloc");
    const init_sel = apl_runtime.sel_registerName("initWithContentRect:styleMask:backing:defer:");

    const window = apl_runtime.objc_msgSend(window_class, alloc_sel);
    self.window = @ptrCast(apl_runtime.objc_msgSend(window, init_sel, window_rect, style_mask, @as(apl_runtime.NSBackingStoreType, apl_runtime.NSBackingStoreBuffered), false));

    if (self.window == null) {
        return error.WindowCreationFailed;
    }

    const center_sel = apl_runtime.sel_registerName("center");
    _ = apl_runtime.objc_msgSend(self.window.?, center_sel);

    const title_sel = apl_runtime.sel_registerName("setTitle:");
    const ns_string_class = apl_runtime.objc_getClass("NSString");
    const str_sel = apl_runtime.sel_registerName("stringWithUTF8String:");
    const title = apl_runtime.objc_msgSend(ns_string_class, str_sel, "Solaritty");
    _ = apl_runtime.objc_msgSend(self.window.?, title_sel, title);

    const set_titlebar_sel = apl_runtime.sel_registerName("setTitlebarAppearsTransparent:");
    _ = apl_runtime.objc_msgSend(self.window.?, set_titlebar_sel, true);

    const set_title_vis_sel = apl_runtime.sel_registerName("setTitleVisibility:");
    _ = apl_runtime.objc_msgSend(self.window.?, set_title_vis_sel, @as(apl_runtime.NSWindowTitleVisibility, apl_runtime.NSWindowTitleVisibilityHidden));

    const set_opaque_sel = apl_runtime.sel_registerName("setOpaque:");
    _ = apl_runtime.objc_msgSend(self.window.?, set_opaque_sel, false);

    const set_bkg_sel = apl_runtime.sel_registerName("setBackgroundColor:");
    const color_class = apl_runtime.objc_getClass("NSColor");
    const clear_color_sel = apl_runtime.sel_registerName("clearColor");
    const clear_color = apl_runtime.objc_msgSend(color_class, clear_color_sel);
    _ = apl_runtime.objc_msgSend(self.window.?, set_bkg_sel, clear_color);

    const set_corner_radius = apl_runtime.sel_registerName("setCornerRadius:");
    _ = apl_runtime.objc_msgSend(self.window.?, set_corner_radius, @as(f64, 10.0));

    const view_class = apl_runtime.objc_getClass("NSView");
    const view_alloc = apl_runtime.objc_msgSend(view_class, alloc_sel);

    const content_rect_sel = apl_runtime.sel_registerName("contentRectForFrameRect:");
    const content_rect: apl_runtime.NSRect = @bitCast(apl_runtime.objc_msgSend(self.window.?, content_rect_sel, window_rect));

    const init_frame_sel = apl_runtime.sel_registerName("initWithFrame:");
    const view = apl_runtime.objc_msgSend(view_alloc, init_frame_sel, content_rect);
    self.view = @ptrCast(view);

    try self.setupMetalLayer();

    const set_content_sel = apl_runtime.sel_registerName("setContentView:");
    _ = apl_runtime.objc_msgSend(self.window.?, set_content_sel, view);

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

    const make_key_sel = apl_runtime.sel_registerName("makeKeyAndOrderFront:");
    _ = apl_runtime.objc_msgSend(self.window.?, make_key_sel, null);

    const activate_sel = apl_runtime.sel_registerName("activateIgnoringOtherApps:");
    _ = apl_runtime.objc_msgSend(ns_app, activate_sel, true);

    self.running = true;
}

fn setupMetalLayer(self: *Self) !void {
    if (self.view == null) return error.NoView;

    const layer_class = apl_runtime.objc_getClass("CAMetalLayer");
    const alloc_sel = apl_runtime.sel_registerName("alloc");
    const init_sel = apl_runtime.sel_registerName("init");

    const metal_layer = apl_runtime.objc_msgSend(layer_class, alloc_sel);
    self.metal_layer = @ptrCast(apl_runtime.objc_msgSend(metal_layer, init_sel));

    if (self.metal_layer == null) {
        return error.MetalLayerCreationFailed;
    }

    const set_device_sel = apl_runtime.sel_registerName("setDevice:");
    _ = apl_runtime.objc_msgSend(self.metal_layer.?, set_device_sel, self.renderer.?.metal.device);

    const set_pixel_format_sel = apl_runtime.sel_registerName("setPixelFormat:");
    _ = apl_runtime.objc_msgSend(self.metal_layer.?, set_pixel_format_sel, @as(apl_runtime.MTLPixelFormat, apl_runtime.MTLPixelFormatBGRA8Unorm_sRGB));

    const set_fb_only_sel = apl_runtime.sel_registerName("setFramebufferOnly:");
    _ = apl_runtime.objc_msgSend(self.metal_layer.?, set_fb_only_sel, true);

    const set_scale_sel = apl_runtime.sel_registerName("setContentsScale:");
    const screen_sel = apl_runtime.sel_registerName("screen");
    const screen = apl_runtime.objc_msgSend(self.window.?, screen_sel);
    const backing_scale_sel = apl_runtime.sel_registerName("backingScaleFactor");
    const scale: f64 = @bitCast(apl_runtime.objc_msgSend(screen, backing_scale_sel));
    _ = apl_runtime.objc_msgSend(self.metal_layer.?, set_scale_sel, scale);

    const set_layer_sel = apl_runtime.sel_registerName("setLayer:");
    _ = apl_runtime.objc_msgSend(self.view.?, set_layer_sel, self.metal_layer.?);

    const set_wants_layer = apl_runtime.sel_registerName("setWantsLayer:");
    _ = apl_runtime.objc_msgSend(self.view.?, set_wants_layer, true);

    const set_policy_sel = apl_runtime.sel_registerName("setLayerContentsRedrawPolicy:");
    _ = apl_runtime.objc_msgSend(self.view.?, set_policy_sel, @as(apl_runtime.NSViewLayerContentsRedrawPolicy, apl_runtime.NSViewLayerContentsRedrawPolicyDuringViewResize));
}

pub fn run(self: *Self) !void {
    if (!self.running) return;

    const ns_app_class = apl_runtime.objc_getClass("NSApplication");
    const shared_app_sel = apl_runtime.sel_registerName("sharedApplication");
    const ns_app = apl_runtime.objc_msgSend(ns_app_class, shared_app_sel);

    while (self.running) {
        const mode_sel = apl_runtime.sel_registerName("defaultRunLoopMode");
        const mode = apl_runtime.objc_msgSend(apl_runtime.objc_getClass("NSRunLoop"), mode_sel);
        const distant_future_sel = apl_runtime.sel_registerName("distantFuture");
        const distant_future = apl_runtime.objc_msgSend(apl_runtime.objc_getClass("NSDate"), distant_future_sel);

        const next_event_sel = apl_runtime.sel_registerName("nextEventMatchingMask:untilDate:inMode:dequeue:");
        const event = apl_runtime.objc_msgSend(ns_app, next_event_sel, @as(apl_runtime.NSEventMask, apl_runtime.NSEventMaskAny), distant_future, mode, true);

        if (event) |e| {
            const send_event_sel = apl_runtime.sel_registerName("sendEvent:");
            _ = apl_runtime.objc_msgSend(ns_app, send_event_sel, e);
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

    const frame_sel = apl_runtime.sel_registerName("frame");
    const frame: apl_runtime.NSRect = @bitCast(apl_runtime.objc_msgSend(self.view.?, frame_sel));
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
