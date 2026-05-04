const std = @import("std");
const c = @cImport({
    @cInclude("objc/runtime.h");
    @cInclude("objc/message.h");
    @cInclude("Metal/Metal.h");
    @cInclude("MetalKit/MetalKit.h");
    @cInclude("CoreGraphics/CoreGraphics.h");
    @cInclude("QuartzCore/CAMetalLayer.h");
});
const zigimg = @import("zigimg");

const Cell = @import("Cell.zig");

allocator: std.mem.Allocator,
device: ?*c.MTLDeviceProtocol,
command_queue: ?*c.MTLCommandQueueProtocol,
background_pipeline: ?*c.MTLRenderPipelineStateProtocol,
cell_pipeline: ?*c.MTLRenderPipelineStateProtocol,
background_texture: ?*c.MTLTextureProtocol,
glyph_atlas_texture: ?*c.MTLTextureProtocol,
atlas_size: u32,

background_vertex_buffer: ?*c.MTLBufferProtocol,
cell_vertex_buffer: ?*c.MTLBufferProtocol,
cell_index_buffer: ?*c.MTLBufferProtocol,

library: ?*c.MTLLibraryProtocol,

const Self = @This();

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .allocator = allocator,
        .device = null,
        .command_queue = null,
        .background_pipeline = null,
        .cell_pipeline = null,
        .background_texture = null,
        .glyph_atlas_texture = null,
        .atlas_size = 2048,
        .background_vertex_buffer = null,
        .cell_vertex_buffer = null,
        .cell_index_buffer = null,
        .library = null,
    };
}

pub fn deinit(self: *Self) void {
    self.releaseResources();
}

fn releaseResources(self: *Self) void {
    if (self.background_vertex_buffer) |buf| {
        c.objc_msgSend(buf, c.sel_release);
    }
    if (self.cell_vertex_buffer) |buf| {
        c.objc_msgSend(buf, c.sel_release);
    }
    if (self.cell_index_buffer) |buf| {
        c.objc_msgSend(buf, c.sel_release);
    }
    if (self.background_pipeline) |pipe| {
        c.objc_msgSend(pipe, c.sel_release);
    }
    if (self.cell_pipeline) |pipe| {
        c.objc_msgSend(pipe, c.sel_release);
    }
    if (self.library) |lib| {
        c.objc_msgSend(lib, c.sel_release);
    }
    if (self.background_texture) |tex| {
        c.objc_msgSend(tex, c.sel_release);
    }
    if (self.glyph_atlas_texture) |tex| {
        c.objc_msgSend(tex, c.sel_release);
    }
    if (self.command_queue) |queue| {
        c.objc_msgSend(queue, c.sel_release);
    }
}

pub fn createDevice(self: *Self) !void {
    const device_class = c.objc_getClass("MTLCreateSystemDefaultDevice");
    if (device_class == null) {
        return error.NoMetalDevice;
    }

    self.device = @ptrCast(c.MTLCreateSystemDefaultDevice());
    if (self.device == null) {
        return error.NoMetalDevice;
    }

    const queue_sel = c.sel_registerName("newCommandQueue");
    self.command_queue = @ptrCast(c.objc_msgSend(self.device.?, queue_sel));
}

pub fn loadShaders(self: *Self, shader_source: []const u8) !void {
    if (self.device == null) return error.NoDevice;

    const ns_str = c.objc_getClass("NSString");
    const str_sel = c.sel_registerName("stringWithUTF8String:");
    const shader_nsstring = c.objc_msgSend(ns_str, str_sel, shader_source.ptr);

    const options_class = c.objc_getClass("MTLCompileOptions");
    const alloc_sel = c.sel_registerName("alloc");
    const init_sel = c.sel_registerName("init");
    const options = c.objc_msgSend(c.objc_msgSend(options_class, alloc_sel), init_sel);
    defer _ = c.objc_msgSend(options, c.sel_release);

    const library_sel = c.sel_registerName("newLibraryWithSource:options:error:");
    var error_ptr: ?*c.objc_object = null;
    self.library = @ptrCast(c.objc_msgSend(self.device.?, library_sel, shader_nsstring, options, &error_ptr));

    if (self.library == null) {
        if (error_ptr) |err| {
            const desc_sel = c.sel_registerName("localizedDescription");
            const desc = c.objc_msgSend(err, desc_sel);
            const c_str: [*c]const u8 = @ptrCast(c.objc_msgSend(desc, c.sel_registerName("UTF8String")));
            std.log.err("Shader compilation failed: {s}", .{c_str});
        }
        return error.ShaderCompilationFailed;
    }
}

pub fn createBackgroundPipeline(self: *Self) !void {
    if (self.device == null or self.library == null) return error.NotInitialized;

    const fn_sel = c.sel_registerName("newFunctionWithName:");
    const ns_str = c.objc_getClass("NSString");
    const str_sel = c.sel_registerName("stringWithUTF8String:");

    const vertex_name = c.objc_msgSend(ns_str, str_sel, "backgroundVertex");
    const fragment_name = c.objc_msgSend(ns_str, str_sel, "backgroundFragment");

    const vertex_fn = c.objc_msgSend(self.library.?, fn_sel, vertex_name);
    const fragment_fn = c.objc_msgSend(self.library.?, fn_sel, fragment_name);

    if (vertex_fn == null or fragment_fn == null) {
        return error.ShaderFunctionNotFound;
    }

    const desc_class = c.objc_getClass("MTLRenderPipelineDescriptor");
    const alloc_sel = c.sel_registerName("alloc");
    const init_sel = c.sel_registerName("init");
    const desc = c.objc_msgSend(c.objc_msgSend(desc_class, alloc_sel), init_sel);
    defer _ = c.objc_msgSend(desc, c.sel_release);

    const set_vertex_sel = c.sel_registerName("setVertexFunction:");
    const set_fragment_sel = c.sel_registerName("setFragmentFunction:");
    _ = c.objc_msgSend(desc, set_vertex_sel, vertex_fn);
    _ = c.objc_msgSend(desc, set_fragment_sel, fragment_fn);

    const color_attach_sel = c.sel_registerName("colorAttachments");
    const color_attach = c.objc_msgSend(desc, color_attach_sel);
    const object_at_sel = c.sel_registerName("objectAtIndexedSubscript:");
    const attach_0 = c.objc_msgSend(color_attach, object_at_sel, @as(usize, 0));

    const set_pixel_sel = c.sel_registerName("setPixelFormat:");
    _ = c.objc_msgSend(attach_0, set_pixel_sel, @as(c.MTLPixelFormat, c.MTLPixelFormatBGRA8Unorm_sRGB));

    const set_blending_sel = c.sel_registerName("setBlendingEnabled:");
    _ = c.objc_msgSend(attach_0, set_blending_sel, true);

    const set_src_sel = c.sel_registerName("setSourceRGBBlendFactor:");
    const set_dst_sel = c.sel_registerName("setDestinationRGBBlendFactor:");
    _ = c.objc_msgSend(attach_0, set_src_sel, @as(c.MTLBlendFactor, c.MTLBlendFactorSourceAlpha));
    _ = c.objc_msgSend(attach_0, set_dst_sel, @as(c.MTLBlendFactor, c.MTLBlendFactorOneMinusSourceAlpha));

    const create_sel = c.sel_registerName("newRenderPipelineStateWithDescriptor:error:");
    var error_ptr: ?*c.objc_object = null;
    self.background_pipeline = @ptrCast(c.objc_msgSend(self.device.?, create_sel, desc, &error_ptr));

    _ = c.objc_msgSend(vertex_fn, c.sel_release);
    _ = c.objc_msgSend(fragment_fn, c.sel_release);

    if (self.background_pipeline == null) {
        return error.PipelineCreationFailed;
    }
}

pub fn createCellPipeline(self: *Self) !void {
    if (self.device == null or self.library == null) return error.NotInitialized;

    const fn_sel = c.sel_registerName("newFunctionWithName:");
    const ns_str = c.objc_getClass("NSString");
    const str_sel = c.sel_registerName("stringWithUTF8String:");

    const vertex_name = c.objc_msgSend(ns_str, str_sel, "cellVertex");
    const fragment_name = c.objc_msgSend(ns_str, str_sel, "cellFragment");

    const vertex_fn = c.objc_msgSend(self.library.?, fn_sel, vertex_name);
    const fragment_fn = c.objc_msgSend(self.library.?, fn_sel, fragment_name);

    if (vertex_fn == null or fragment_fn == null) {
        return error.ShaderFunctionNotFound;
    }

    const desc_class = c.objc_getClass("MTLRenderPipelineDescriptor");
    const alloc_sel = c.sel_registerName("alloc");
    const init_sel = c.sel_registerName("init");
    const desc = c.objc_msgSend(c.objc_msgSend(desc_class, alloc_sel), init_sel);
    defer _ = c.objc_msgSend(desc, c.sel_release);

    const set_vertex_sel = c.sel_registerName("setVertexFunction:");
    const set_fragment_sel = c.sel_registerName("setFragmentFunction:");
    _ = c.objc_msgSend(desc, set_vertex_sel, vertex_fn);
    _ = c.objc_msgSend(desc, set_fragment_sel, fragment_fn);

    const color_attach_sel = c.sel_registerName("colorAttachments");
    const color_attach = c.objc_msgSend(desc, color_attach_sel);
    const object_at_sel = c.sel_registerName("objectAtIndexedSubscript:");
    const attach_0 = c.objc_msgSend(color_attach, object_at_sel, @as(usize, 0));

    const set_pixel_sel = c.sel_registerName("setPixelFormat:");
    _ = c.objc_msgSend(attach_0, set_pixel_sel, @as(c.MTLPixelFormat, c.MTLPixelFormatBGRA8Unorm_sRGB));

    const set_blending_sel = c.sel_registerName("setBlendingEnabled:");
    _ = c.objc_msgSend(attach_0, set_blending_sel, true);

    const set_src_sel = c.sel_registerName("setSourceRGBBlendFactor:");
    const set_dst_sel = c.sel_registerName("setDestinationRGBBlendFactor:");
    _ = c.objc_msgSend(attach_0, set_src_sel, @as(c.MTLBlendFactor, c.MTLBlendFactorSourceAlpha));
    _ = c.objc_msgSend(attach_0, set_dst_sel, @as(c.MTLBlendFactor, c.MTLBlendFactorOneMinusSourceAlpha));

    const create_sel = c.sel_registerName("newRenderPipelineStateWithDescriptor:error:");
    var error_ptr: ?*c.objc_object = null;
    self.cell_pipeline = @ptrCast(c.objc_msgSend(self.device.?, create_sel, desc, &error_ptr));

    _ = c.objc_msgSend(vertex_fn, c.sel_release);
    _ = c.objc_msgSend(fragment_fn, c.sel_release);

    if (self.cell_pipeline == null) {
        return error.PipelineCreationFailed;
    }
}

pub fn loadBackgroundImage(self: *Self, path: []const u8) !void {
    if (self.device == null) return error.NoDevice;

    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const data = try file.readToEndAlloc(self.allocator, 50 * 1024 * 1024); // 50MB max
    defer self.allocator.free(data);

    var image = try zigimg.Image.fromMemory(self.allocator, data);
    defer image.deinit();

    try image.convertToRgba32();

    const desc_class = c.objc_getClass("MTLTextureDescriptor");
    const alloc_sel = c.sel_registerName("alloc");
    const init_sel = c.sel_registerName("init");
    const desc = c.objc_msgSend(c.objc_msgSend(desc_class, alloc_sel), init_sel);
    defer _ = c.objc_msgSend(desc, c.sel_release);

    const set_tex_type = c.sel_registerName("setTextureType:");
    const set_pixel_fmt = c.sel_registerName("setPixelFormat:");
    const set_width = c.sel_registerName("setWidth:");
    const set_height = c.sel_registerName("setHeight:");
    const set_usage = c.sel_registerName("setUsage:");

    _ = c.objc_msgSend(desc, set_tex_type, @as(c.MTLTextureType, c.MTLTextureType2D));
    _ = c.objc_msgSend(desc, set_pixel_fmt, @as(c.MTLPixelFormat, c.MTLPixelFormatRGBA8Unorm));
    _ = c.objc_msgSend(desc, set_width, @as(usize, image.width));
    _ = c.objc_msgSend(desc, set_height, @as(usize, image.height));
    _ = c.objc_msgSend(desc, set_usage, @as(c.MTLTextureUsage, c.MTLTextureUsageShaderRead));

    const new_tex_sel = c.sel_registerName("newTextureWithDescriptor:");
    self.background_texture = @ptrCast(c.objc_msgSend(self.device.?, new_tex_sel, desc));

    if (self.background_texture == null) {
        return error.TextureCreationFailed;
    }

    const replace_sel = c.sel_registerName("replaceRegion:mipmapLevel:withBytes:bytesPerRow:");
    const region = c.MTLRegionMake2D(0, 0, @intCast(image.width), @intCast(image.height));
    _ = c.objc_msgSend(self.background_texture.?, replace_sel, region, @as(usize, 0), image.pixels.rgba32.ptr, @as(usize, image.width * 4));
}

pub fn createGlyphAtlas(self: *Self, size: u32) !void {
    if (self.device == null) return error.NoDevice;

    self.atlas_size = size;

    const desc_class = c.objc_getClass("MTLTextureDescriptor");
    const alloc_sel = c.sel_registerName("alloc");
    const init_sel = c.sel_registerName("init");
    const desc = c.objc_msgSend(c.objc_msgSend(desc_class, alloc_sel), init_sel);
    defer _ = c.objc_msgSend(desc, c.sel_release);

    const set_tex_type = c.sel_registerName("setTextureType:");
    const set_pixel_fmt = c.sel_registerName("setPixelFormat:");
    const set_width = c.sel_registerName("setWidth:");
    const set_height = c.sel_registerName("setHeight:");
    const set_usage = c.sel_registerName("setUsage:");

    _ = c.objc_msgSend(desc, set_tex_type, @as(c.MTLTextureType, c.MTLTextureType2D));
    _ = c.objc_msgSend(desc, set_pixel_fmt, @as(c.MTLPixelFormat, c.MTLPixelFormatRGBA8Unorm));
    _ = c.objc_msgSend(desc, set_width, @as(usize, size));
    _ = c.objc_msgSend(desc, set_height, @as(usize, size));
    _ = c.objc_msgSend(desc, set_usage, @as(c.MTLTextureUsage, c.MTLTextureUsageShaderRead));

    const new_tex_sel = c.sel_registerName("newTextureWithDescriptor:");
    self.glyph_atlas_texture = @ptrCast(c.objc_msgSend(self.device.?, new_tex_sel, desc));

    if (self.glyph_atlas_texture == null) {
        return error.TextureCreationFailed;
    }

    const clear_data = try self.allocator.alloc(u8, size * size * 4);
    defer self.allocator.free(clear_data);
    @memset(clear_data, 0);

    const replace_sel = c.sel_registerName("replaceRegion:mipmapLevel:withBytes:bytesPerRow:");
    const region = c.MTLRegionMake2D(0, 0, size, size);
    _ = c.objc_msgSend(self.glyph_atlas_texture.?, replace_sel, region, @as(usize, 0), clear_data.ptr, @as(usize, size * 4));
}

pub fn updateGlyphAtlas(self: *Self, x: u32, y: u32, width: u32, height: u32, data: []const u8) void {
    if (self.glyph_atlas_texture == null) return;

    const replace_sel = c.sel_registerName("replaceRegion:mipmapLevel:withBytes:bytesPerRow:");
    const region = c.MTLRegionMake2D(@intCast(x), @intCast(y), @intCast(width), @intCast(height));
    _ = c.objc_msgSend(self.glyph_atlas_texture.?, replace_sel, region, @as(usize, 0), data.ptr, @as(usize, width * 4));
}

pub fn render(
    self: *Self,
    drawable: *c.CAMetalDrawable,
    render_pass_desc: *c.MTLRenderPassDescriptor,
    width: u32,
    height: u32,
    background_vertices: []const Cell.BackgroundVertex,
    background_indices: []const u16,
    cell_vertices: []const Cell.CellVertex,
    cell_indices: []const u16,
) !void {
    _ = background_indices;
    if (self.command_queue == null) return error.NotInitialized;

    const cmd_buf_sel = c.sel_registerName("commandBuffer");
    const command_buffer = c.objc_msgSend(self.command_queue.?, cmd_buf_sel);

    const encoder_sel = c.sel_registerName("renderCommandEncoderWithDescriptor:");
    const encoder = c.objc_msgSend(command_buffer, encoder_sel, render_pass_desc);

    const set_viewport_sel = c.sel_registerName("setViewport:");
    const viewport = c.MTLViewport{
        .originX = 0,
        .originY = 0,
        .width = @floatFromInt(width),
        .height = @floatFromInt(height),
        .znear = 0,
        .zfar = 1,
    };
    _ = c.objc_msgSend(encoder, set_viewport_sel, viewport);

    if (background_vertices.len > 0) {
        self.updateOrCreateBuffer(&self.background_vertex_buffer, @sizeOf(Cell.BackgroundVertex) * background_vertices.len);
        if (self.background_vertex_buffer) |buf| {
            const contents = c.objc_msgSend(buf, c.sel_registerName("contents"));
            @memcpy(@as([*]Cell.BackgroundVertex, @ptrCast(@alignCast(contents)))[0..background_vertices.len], background_vertices);
        }
    }

    if (self.background_pipeline) |pipeline| {
        const set_pipeline = c.sel_registerName("setRenderPipelineState:");
        _ = c.objc_msgSend(encoder, set_pipeline, pipeline);

        if (self.background_vertex_buffer) |buf| {
            const set_vbuf = c.sel_registerName("setVertexBuffer:offset:atIndex:");
            _ = c.objc_msgSend(encoder, set_vbuf, buf, @as(usize, 0), @as(usize, 0));
        }

        if (self.background_texture) |tex| {
            const set_tex = c.sel_registerName("setFragmentTexture:atIndex:");
            _ = c.objc_msgSend(encoder, set_tex, tex, @as(usize, 0));
        }

        const draw_sel = c.sel_registerName("drawPrimitives:vertexStart:vertexCount:");
        _ = c.objc_msgSend(encoder, draw_sel, @as(c.MTLPrimitiveType, c.MTLPrimitiveTypeTriangle), @as(usize, 0), @as(usize, 6));
    }

    if (cell_vertices.len > 0) {
        const vertex_size = @sizeOf(Cell.CellVertex) * cell_vertices.len;
        const index_size = @sizeOf(u16) * cell_indices.len;

        self.updateOrCreateBuffer(&self.cell_vertex_buffer, vertex_size);
        self.updateOrCreateBuffer(&self.cell_index_buffer, index_size);

        if (self.cell_vertex_buffer) |buf| {
            const contents = c.objc_msgSend(buf, c.sel_registerName("contents"));
            @memcpy(@as([*]Cell.CellVertex, @ptrCast(@alignCast(contents)))[0..cell_vertices.len], cell_vertices);
        }

        if (self.cell_index_buffer) |buf| {
            const contents = c.objc_msgSend(buf, c.sel_registerName("contents"));
            @memcpy(@as([*]u16, @ptrCast(@alignCast(contents)))[0..cell_indices.len], cell_indices);
        }
    }

    if (self.cell_pipeline) |pipeline| {
        const set_pipeline = c.sel_registerName("setRenderPipelineState:");
        _ = c.objc_msgSend(encoder, set_pipeline, pipeline);

        if (self.cell_vertex_buffer) |buf| {
            const set_vbuf = c.sel_registerName("setVertexBuffer:offset:atIndex:");
            _ = c.objc_msgSend(encoder, set_vbuf, buf, @as(usize, 0), @as(usize, 0));
        }

        if (self.glyph_atlas_texture) |tex| {
            const set_tex = c.sel_registerName("setFragmentTexture:atIndex:");
            _ = c.objc_msgSend(encoder, set_tex, tex, @as(usize, 0));
        }

        if (self.cell_index_buffer) |buf| {
            const draw_indexed = c.sel_registerName("drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:");
            _ = c.objc_msgSend(encoder, draw_indexed, @as(c.MTLPrimitiveType, c.MTLPrimitiveTypeTriangle), @as(usize, cell_indices.len), @as(c.MTLIndexType, c.MTLIndexTypeUInt16), buf, @as(usize, 0));
        }
    }

    const end_encoding = c.sel_registerName("endEncoding");
    _ = c.objc_msgSend(encoder, end_encoding);

    const present_sel = c.sel_registerName("presentDrawable:");
    _ = c.objc_msgSend(command_buffer, present_sel, drawable);

    const commit_sel = c.sel_registerName("commit");
    _ = c.objc_msgSend(command_buffer, commit_sel);
}

fn updateOrCreateBuffer(self: *Self, buffer: *?*c.MTLBufferProtocol, size: usize) void {
    var needs_new = true;

    if (buffer.*) |existing| {
        const length_sel = c.sel_registerName("length");
        const current_len: usize = @intFromPtr(c.objc_msgSend(existing, length_sel));
        if (current_len >= size) {
            needs_new = false;
        } else {
            _ = c.objc_msgSend(existing, c.sel_release);
        }
    }

    if (needs_new) {
        const options: c.MTLResourceOptions = c.MTLResourceCPUCacheModeDefaultCache | c.MTLResourceStorageModeShared;
        const new_buf = c.objc_msgSend(self.device.?, c.sel_registerName("newBufferWithLength:options:"), size, options);
        buffer.* = @ptrCast(new_buf);
    }
}

pub fn createRenderPassDescriptor(drawable: *c.CAMetalDrawable, clear_color: [4]f32) !*c.MTLRenderPassDescriptor {
    const desc_class = c.objc_getClass("MTLRenderPassDescriptor");
    const alloc_sel = c.sel_registerName("alloc");
    const init_sel = c.sel_registerName("init");
    const desc = c.objc_msgSend(c.objc_msgSend(desc_class, alloc_sel), init_sel);

    const color_attach_sel = c.sel_registerName("colorAttachments");
    const color_attach = c.objc_msgSend(desc, color_attach_sel);
    const object_at_sel = c.sel_registerName("objectAtIndexedSubscript:");
    const attach_0 = c.objc_msgSend(color_attach, object_at_sel, @as(usize, 0));

    const texture_sel = c.sel_registerName("texture");
    const drawable_tex: ?*c.MTLTextureProtocol = @ptrCast(c.objc_msgSend(drawable, texture_sel));
    const set_texture_sel = c.sel_registerName("setTexture:");
    _ = c.objc_msgSend(attach_0, set_texture_sel, drawable_tex);

    const set_load_sel = c.sel_registerName("setLoadAction:");
    _ = c.objc_msgSend(attach_0, set_load_sel, @as(c.MTLLoadAction, c.MTLLoadActionClear));

    const set_clear_sel = c.sel_registerName("setClearColor:");
    const mtl_color = c.MTLClearColor{
        .red = clear_color[0],
        .green = clear_color[1],
        .blue = clear_color[2],
        .alpha = clear_color[3],
    };
    _ = c.objc_msgSend(attach_0, set_clear_sel, mtl_color);

    const set_store_sel = c.sel_registerName("setStoreAction:");
    _ = c.objc_msgSend(attach_0, set_store_sel, @as(c.MTLStoreAction, c.MTLStoreActionStore));

    return @ptrCast(desc);
}
