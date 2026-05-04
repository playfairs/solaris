const std = @import("std");
const apl_runtime = @import("apl_runtime_trans_c");
const zigimg = @import("zigimg");

const Cell = @import("Cell.zig");

allocator: std.mem.Allocator,
device: ?*apl_runtime.MTLDeviceProtocol,
command_queue: ?*apl_runtime.MTLCommandQueueProtocol,
background_pipeline: ?*apl_runtime.MTLRenderPipelineStateProtocol,
cell_pipeline: ?*apl_runtime.MTLRenderPipelineStateProtocol,
background_texture: ?*apl_runtime.MTLTextureProtocol,
glyph_atlas_texture: ?*apl_runtime.MTLTextureProtocol,
atlas_size: u32,

background_vertex_buffer: ?*apl_runtime.MTLBufferProtocol,
cell_vertex_buffer: ?*apl_runtime.MTLBufferProtocol,
cell_index_buffer: ?*apl_runtime.MTLBufferProtocol,

library: ?*apl_runtime.MTLLibraryProtocol,

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
        apl_runtime.objc_msgSend(buf, apl_runtime.sel_release);
    }
    if (self.cell_vertex_buffer) |buf| {
        apl_runtime.objc_msgSend(buf, apl_runtime.sel_release);
    }
    if (self.cell_index_buffer) |buf| {
        apl_runtime.objc_msgSend(buf, apl_runtime.sel_release);
    }
    if (self.background_pipeline) |pipe| {
        apl_runtime.objc_msgSend(pipe, apl_runtime.sel_release);
    }
    if (self.cell_pipeline) |pipe| {
        apl_runtime.objc_msgSend(pipe, apl_runtime.sel_release);
    }
    if (self.library) |lib| {
        apl_runtime.objc_msgSend(lib, apl_runtime.sel_release);
    }
    if (self.background_texture) |tex| {
        apl_runtime.objc_msgSend(tex, apl_runtime.sel_release);
    }
    if (self.glyph_atlas_texture) |tex| {
        apl_runtime.objc_msgSend(tex, apl_runtime.sel_release);
    }
    if (self.command_queue) |queue| {
        apl_runtime.objc_msgSend(queue, apl_runtime.sel_release);
    }
}

pub fn createDevice(self: *Self) !void {
    const device_class = apl_runtime.objc_getClass("MTLCreateSystemDefaultDevice");
    if (device_class == null) {
        return error.NoMetalDevice;
    }

    self.device = @ptrCast(apl_runtime.MTLCreateSystemDefaultDevice());
    if (self.device == null) {
        return error.NoMetalDevice;
    }

    const queue_sel = apl_runtime.sel_registerName("newCommandQueue");
    self.command_queue = @ptrCast(apl_runtime.objc_msgSend(self.device.?, queue_sel));
}

pub fn loadShaders(self: *Self, shader_source: []const u8) !void {
    if (self.device == null) return error.NoDevice;

    const ns_str = apl_runtime.objc_getClass("NSString");
    const str_sel = apl_runtime.sel_registerName("stringWithUTF8String:");
    const shader_nsstring = apl_runtime.objc_msgSend(ns_str, str_sel, shader_source.ptr);

    const options_class = apl_runtime.objc_getClass("MTLCompileOptions");
    const alloc_sel = apl_runtime.sel_registerName("alloc");
    const init_sel = apl_runtime.sel_registerName("init");
    const options = apl_runtime.objc_msgSend(apl_runtime.objc_msgSend(options_class, alloc_sel), init_sel);
    defer _ = apl_runtime.objc_msgSend(options, apl_runtime.sel_release);

    const library_sel = apl_runtime.sel_registerName("newLibraryWithSource:options:error:");
    var error_ptr: ?*apl_runtime.objc_object = null;
    self.library = @ptrCast(apl_runtime.objc_msgSend(self.device.?, library_sel, shader_nsstring, options, &error_ptr));

    if (self.library == null) {
        if (error_ptr) |err| {
            const desc_sel = apl_runtime.sel_registerName("localizedDescription");
            const desc = apl_runtime.objc_msgSend(err, desc_sel);
            const c_str: [*c]const u8 = @ptrCast(apl_runtime.objc_msgSend(desc, apl_runtime.sel_registerName("UTF8String")));
            std.log.err("Shader compilation failed: {s}", .{c_str});
        }
        return error.ShaderCompilationFailed;
    }
}

pub fn createBackgroundPipeline(self: *Self) !void {
    if (self.device == null or self.library == null) return error.NotInitialized;

    const fn_sel = apl_runtime.sel_registerName("newFunctionWithName:");
    const ns_str = apl_runtime.objc_getClass("NSString");
    const str_sel = apl_runtime.sel_registerName("stringWithUTF8String:");

    const vertex_name = apl_runtime.objc_msgSend(ns_str, str_sel, "backgroundVertex");
    const fragment_name = apl_runtime.objc_msgSend(ns_str, str_sel, "backgroundFragment");

    const vertex_fn = apl_runtime.objc_msgSend(self.library.?, fn_sel, vertex_name);
    const fragment_fn = apl_runtime.objc_msgSend(self.library.?, fn_sel, fragment_name);

    if (vertex_fn == null or fragment_fn == null) {
        return error.ShaderFunctionNotFound;
    }

    const desc_class = apl_runtime.objc_getClass("MTLRenderPipelineDescriptor");
    const alloc_sel = apl_runtime.sel_registerName("alloc");
    const init_sel = apl_runtime.sel_registerName("init");
    const desc = apl_runtime.objc_msgSend(apl_runtime.objc_msgSend(desc_class, alloc_sel), init_sel);
    defer _ = apl_runtime.objc_msgSend(desc, apl_runtime.sel_release);

    const set_vertex_sel = apl_runtime.sel_registerName("setVertexFunction:");
    const set_fragment_sel = apl_runtime.sel_registerName("setFragmentFunction:");
    _ = apl_runtime.objc_msgSend(desc, set_vertex_sel, vertex_fn);
    _ = apl_runtime.objc_msgSend(desc, set_fragment_sel, fragment_fn);

    const color_attach_sel = apl_runtime.sel_registerName("colorAttachments");
    const color_attach = apl_runtime.objc_msgSend(desc, color_attach_sel);
    const object_at_sel = apl_runtime.sel_registerName("objectAtIndexedSubscript:");
    const attach_0 = apl_runtime.objc_msgSend(color_attach, object_at_sel, @as(usize, 0));

    const set_pixel_sel = apl_runtime.sel_registerName("setPixelFormat:");
    _ = apl_runtime.objc_msgSend(attach_0, set_pixel_sel, @as(apl_runtime.MTLPixelFormat, apl_runtime.MTLPixelFormatBGRA8Unorm_sRGB));

    const set_blending_sel = apl_runtime.sel_registerName("setBlendingEnabled:");
    _ = apl_runtime.objc_msgSend(attach_0, set_blending_sel, true);

    const set_src_sel = apl_runtime.sel_registerName("setSourceRGBBlendFactor:");
    const set_dst_sel = apl_runtime.sel_registerName("setDestinationRGBBlendFactor:");
    _ = apl_runtime.objc_msgSend(attach_0, set_src_sel, @as(apl_runtime.MTLBlendFactor, apl_runtime.MTLBlendFactorSourceAlpha));
    _ = apl_runtime.objc_msgSend(attach_0, set_dst_sel, @as(apl_runtime.MTLBlendFactor, apl_runtime.MTLBlendFactorOneMinusSourceAlpha));

    const create_sel = apl_runtime.sel_registerName("newRenderPipelineStateWithDescriptor:error:");
    var error_ptr: ?*apl_runtime.objc_object = null;
    self.background_pipeline = @ptrCast(apl_runtime.objc_msgSend(self.device.?, create_sel, desc, &error_ptr));

    _ = apl_runtime.objc_msgSend(vertex_fn, apl_runtime.sel_release);
    _ = apl_runtime.objc_msgSend(fragment_fn, apl_runtime.sel_release);

    if (self.background_pipeline == null) {
        return error.PipelineCreationFailed;
    }
}

pub fn createCellPipeline(self: *Self) !void {
    if (self.device == null or self.library == null) return error.NotInitialized;

    const fn_sel = apl_runtime.sel_registerName("newFunctionWithName:");
    const ns_str = apl_runtime.objc_getClass("NSString");
    const str_sel = apl_runtime.sel_registerName("stringWithUTF8String:");

    const vertex_name = apl_runtime.objc_msgSend(ns_str, str_sel, "cellVertex");
    const fragment_name = apl_runtime.objc_msgSend(ns_str, str_sel, "cellFragment");

    const vertex_fn = apl_runtime.objc_msgSend(self.library.?, fn_sel, vertex_name);
    const fragment_fn = apl_runtime.objc_msgSend(self.library.?, fn_sel, fragment_name);

    if (vertex_fn == null or fragment_fn == null) {
        return error.ShaderFunctionNotFound;
    }

    const desc_class = apl_runtime.objc_getClass("MTLRenderPipelineDescriptor");
    const alloc_sel = apl_runtime.sel_registerName("alloc");
    const init_sel = apl_runtime.sel_registerName("init");
    const desc = apl_runtime.objc_msgSend(apl_runtime.objc_msgSend(desc_class, alloc_sel), init_sel);
    defer _ = apl_runtime.objc_msgSend(desc, apl_runtime.sel_release);

    const set_vertex_sel = apl_runtime.sel_registerName("setVertexFunction:");
    const set_fragment_sel = apl_runtime.sel_registerName("setFragmentFunction:");
    _ = apl_runtime.objc_msgSend(desc, set_vertex_sel, vertex_fn);
    _ = apl_runtime.objc_msgSend(desc, set_fragment_sel, fragment_fn);

    const color_attach_sel = apl_runtime.sel_registerName("colorAttachments");
    const color_attach = apl_runtime.objc_msgSend(desc, color_attach_sel);
    const object_at_sel = apl_runtime.sel_registerName("objectAtIndexedSubscript:");
    const attach_0 = apl_runtime.objc_msgSend(color_attach, object_at_sel, @as(usize, 0));

    const set_pixel_sel = apl_runtime.sel_registerName("setPixelFormat:");
    _ = apl_runtime.objc_msgSend(attach_0, set_pixel_sel, @as(apl_runtime.MTLPixelFormat, apl_runtime.MTLPixelFormatBGRA8Unorm_sRGB));

    const set_blending_sel = apl_runtime.sel_registerName("setBlendingEnabled:");
    _ = apl_runtime.objc_msgSend(attach_0, set_blending_sel, true);

    const set_src_sel = apl_runtime.sel_registerName("setSourceRGBBlendFactor:");
    const set_dst_sel = apl_runtime.sel_registerName("setDestinationRGBBlendFactor:");
    _ = apl_runtime.objc_msgSend(attach_0, set_src_sel, @as(apl_runtime.MTLBlendFactor, apl_runtime.MTLBlendFactorSourceAlpha));
    _ = apl_runtime.objc_msgSend(attach_0, set_dst_sel, @as(apl_runtime.MTLBlendFactor, apl_runtime.MTLBlendFactorOneMinusSourceAlpha));

    const create_sel = apl_runtime.sel_registerName("newRenderPipelineStateWithDescriptor:error:");
    var error_ptr: ?*apl_runtime.objc_object = null;
    self.cell_pipeline = @ptrCast(apl_runtime.objc_msgSend(self.device.?, create_sel, desc, &error_ptr));

    _ = apl_runtime.objc_msgSend(vertex_fn, apl_runtime.sel_release);
    _ = apl_runtime.objc_msgSend(fragment_fn, apl_runtime.sel_release);

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

    const desc_class = apl_runtime.objc_getClass("MTLTextureDescriptor");
    const alloc_sel = apl_runtime.sel_registerName("alloc");
    const init_sel = apl_runtime.sel_registerName("init");
    const desc = apl_runtime.objc_msgSend(apl_runtime.objc_msgSend(desc_class, alloc_sel), init_sel);
    defer _ = apl_runtime.objc_msgSend(desc, apl_runtime.sel_release);

    const set_tex_type = apl_runtime.sel_registerName("setTextureType:");
    const set_pixel_fmt = apl_runtime.sel_registerName("setPixelFormat:");
    const set_width = apl_runtime.sel_registerName("setWidth:");
    const set_height = apl_runtime.sel_registerName("setHeight:");
    const set_usage = apl_runtime.sel_registerName("setUsage:");

    _ = apl_runtime.objc_msgSend(desc, set_tex_type, @as(apl_runtime.MTLTextureType, apl_runtime.MTLTextureType2D));
    _ = apl_runtime.objc_msgSend(desc, set_pixel_fmt, @as(apl_runtime.MTLPixelFormat, apl_runtime.MTLPixelFormatRGBA8Unorm));
    _ = apl_runtime.objc_msgSend(desc, set_width, @as(usize, image.width));
    _ = apl_runtime.objc_msgSend(desc, set_height, @as(usize, image.height));
    _ = apl_runtime.objc_msgSend(desc, set_usage, @as(apl_runtime.MTLTextureUsage, apl_runtime.MTLTextureUsageShaderRead));

    const new_tex_sel = apl_runtime.sel_registerName("newTextureWithDescriptor:");
    self.background_texture = @ptrCast(apl_runtime.objc_msgSend(self.device.?, new_tex_sel, desc));

    if (self.background_texture == null) {
        return error.TextureCreationFailed;
    }

    const replace_sel = apl_runtime.sel_registerName("replaceRegion:mipmapLevel:withBytes:bytesPerRow:");
    const region = apl_runtime.MTLRegionMake2D(0, 0, @intCast(image.width), @intCast(image.height));
    _ = apl_runtime.objc_msgSend(self.background_texture.?, replace_sel, region, @as(usize, 0), image.pixels.rgba32.ptr, @as(usize, image.width * 4));
}

pub fn createGlyphAtlas(self: *Self, size: u32) !void {
    if (self.device == null) return error.NoDevice;

    self.atlas_size = size;

    const desc_class = apl_runtime.objc_getClass("MTLTextureDescriptor");
    const alloc_sel = apl_runtime.sel_registerName("alloc");
    const init_sel = apl_runtime.sel_registerName("init");
    const desc = apl_runtime.objc_msgSend(apl_runtime.objc_msgSend(desc_class, alloc_sel), init_sel);
    defer _ = apl_runtime.objc_msgSend(desc, apl_runtime.sel_release);

    const set_tex_type = apl_runtime.sel_registerName("setTextureType:");
    const set_pixel_fmt = apl_runtime.sel_registerName("setPixelFormat:");
    const set_width = apl_runtime.sel_registerName("setWidth:");
    const set_height = apl_runtime.sel_registerName("setHeight:");
    const set_usage = apl_runtime.sel_registerName("setUsage:");

    _ = apl_runtime.objc_msgSend(desc, set_tex_type, @as(apl_runtime.MTLTextureType, apl_runtime.MTLTextureType2D));
    _ = apl_runtime.objc_msgSend(desc, set_pixel_fmt, @as(apl_runtime.MTLPixelFormat, apl_runtime.MTLPixelFormatRGBA8Unorm));
    _ = apl_runtime.objc_msgSend(desc, set_width, @as(usize, size));
    _ = apl_runtime.objc_msgSend(desc, set_height, @as(usize, size));
    _ = apl_runtime.objc_msgSend(desc, set_usage, @as(apl_runtime.MTLTextureUsage, apl_runtime.MTLTextureUsageShaderRead));

    const new_tex_sel = apl_runtime.sel_registerName("newTextureWithDescriptor:");
    self.glyph_atlas_texture = @ptrCast(apl_runtime.objc_msgSend(self.device.?, new_tex_sel, desc));

    if (self.glyph_atlas_texture == null) {
        return error.TextureCreationFailed;
    }

    const clear_data = try self.allocator.alloc(u8, size * size * 4);
    defer self.allocator.free(clear_data);
    @memset(clear_data, 0);

    const replace_sel = apl_runtime.sel_registerName("replaceRegion:mipmapLevel:withBytes:bytesPerRow:");
    const region = apl_runtime.MTLRegionMake2D(0, 0, size, size);
    _ = apl_runtime.objc_msgSend(self.glyph_atlas_texture.?, replace_sel, region, @as(usize, 0), clear_data.ptr, @as(usize, size * 4));
}

pub fn updateGlyphAtlas(self: *Self, x: u32, y: u32, width: u32, height: u32, data: []const u8) void {
    if (self.glyph_atlas_texture == null) return;

    const replace_sel = apl_runtime.sel_registerName("replaceRegion:mipmapLevel:withBytes:bytesPerRow:");
    const region = apl_runtime.MTLRegionMake2D(@intCast(x), @intCast(y), @intCast(width), @intCast(height));
    _ = apl_runtime.objc_msgSend(self.glyph_atlas_texture.?, replace_sel, region, @as(usize, 0), data.ptr, @as(usize, width * 4));
}

pub fn render(
    self: *Self,
    drawable: *apl_runtime.CAMetalDrawable,
    render_pass_desc: *apl_runtime.MTLRenderPassDescriptor,
    width: u32,
    height: u32,
    background_vertices: []const Cell.BackgroundVertex,
    background_indices: []const u16,
    cell_vertices: []const Cell.CellVertex,
    cell_indices: []const u16,
) !void {
    _ = background_indices;
    if (self.command_queue == null) return error.NotInitialized;

    const cmd_buf_sel = apl_runtime.sel_registerName("commandBuffer");
    const command_buffer = apl_runtime.objc_msgSend(self.command_queue.?, cmd_buf_sel);

    const encoder_sel = apl_runtime.sel_registerName("renderCommandEncoderWithDescriptor:");
    const encoder = apl_runtime.objc_msgSend(command_buffer, encoder_sel, render_pass_desc);

    const set_viewport_sel = apl_runtime.sel_registerName("setViewport:");
    const viewport = apl_runtime.MTLViewport{
        .originX = 0,
        .originY = 0,
        .width = @floatFromInt(width),
        .height = @floatFromInt(height),
        .znear = 0,
        .zfar = 1,
    };
    _ = apl_runtime.objc_msgSend(encoder, set_viewport_sel, viewport);

    if (background_vertices.len > 0) {
        self.updateOrCreateBuffer(&self.background_vertex_buffer, @sizeOf(Cell.BackgroundVertex) * background_vertices.len);
        if (self.background_vertex_buffer) |buf| {
            const contents = apl_runtime.objc_msgSend(buf, apl_runtime.sel_registerName("contents"));
            @memcpy(@as([*]Cell.BackgroundVertex, @ptrCast(@alignCast(contents)))[0..background_vertices.len], background_vertices);
        }
    }

    if (self.background_pipeline) |pipeline| {
        const set_pipeline = apl_runtime.sel_registerName("setRenderPipelineState:");
        _ = apl_runtime.objc_msgSend(encoder, set_pipeline, pipeline);

        if (self.background_vertex_buffer) |buf| {
            const set_vbuf = apl_runtime.sel_registerName("setVertexBuffer:offset:atIndex:");
            _ = apl_runtime.objc_msgSend(encoder, set_vbuf, buf, @as(usize, 0), @as(usize, 0));
        }

        if (self.background_texture) |tex| {
            const set_tex = apl_runtime.sel_registerName("setFragmentTexture:atIndex:");
            _ = apl_runtime.objc_msgSend(encoder, set_tex, tex, @as(usize, 0));
        }

        const draw_sel = apl_runtime.sel_registerName("drawPrimitives:vertexStart:vertexCount:");
        _ = apl_runtime.objc_msgSend(encoder, draw_sel, @as(apl_runtime.MTLPrimitiveType, apl_runtime.MTLPrimitiveTypeTriangle), @as(usize, 0), @as(usize, 6));
    }

    if (cell_vertices.len > 0) {
        const vertex_size = @sizeOf(Cell.CellVertex) * cell_vertices.len;
        const index_size = @sizeOf(u16) * cell_indices.len;

        self.updateOrCreateBuffer(&self.cell_vertex_buffer, vertex_size);
        self.updateOrCreateBuffer(&self.cell_index_buffer, index_size);

        if (self.cell_vertex_buffer) |buf| {
            const contents = apl_runtime.objc_msgSend(buf, apl_runtime.sel_registerName("contents"));
            @memcpy(@as([*]Cell.CellVertex, @ptrCast(@alignCast(contents)))[0..cell_vertices.len], cell_vertices);
        }

        if (self.cell_index_buffer) |buf| {
            const contents = apl_runtime.objc_msgSend(buf, apl_runtime.sel_registerName("contents"));
            @memcpy(@as([*]u16, @ptrCast(@alignCast(contents)))[0..cell_indices.len], cell_indices);
        }
    }

    if (self.cell_pipeline) |pipeline| {
        const set_pipeline = apl_runtime.sel_registerName("setRenderPipelineState:");
        _ = apl_runtime.objc_msgSend(encoder, set_pipeline, pipeline);

        if (self.cell_vertex_buffer) |buf| {
            const set_vbuf = apl_runtime.sel_registerName("setVertexBuffer:offset:atIndex:");
            _ = apl_runtime.objc_msgSend(encoder, set_vbuf, buf, @as(usize, 0), @as(usize, 0));
        }

        if (self.glyph_atlas_texture) |tex| {
            const set_tex = apl_runtime.sel_registerName("setFragmentTexture:atIndex:");
            _ = apl_runtime.objc_msgSend(encoder, set_tex, tex, @as(usize, 0));
        }

        if (self.cell_index_buffer) |buf| {
            const draw_indexed = apl_runtime.sel_registerName("drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:");
            _ = apl_runtime.objc_msgSend(encoder, draw_indexed, @as(apl_runtime.MTLPrimitiveType, apl_runtime.MTLPrimitiveTypeTriangle), @as(usize, cell_indices.len), @as(apl_runtime.MTLIndexType, apl_runtime.MTLIndexTypeUInt16), buf, @as(usize, 0));
        }
    }

    const end_encoding = apl_runtime.sel_registerName("endEncoding");
    _ = apl_runtime.objc_msgSend(encoder, end_encoding);

    const present_sel = apl_runtime.sel_registerName("presentDrawable:");
    _ = apl_runtime.objc_msgSend(command_buffer, present_sel, drawable);

    const commit_sel = apl_runtime.sel_registerName("commit");
    _ = apl_runtime.objc_msgSend(command_buffer, commit_sel);
}

fn updateOrCreateBuffer(self: *Self, buffer: *?*apl_runtime.MTLBufferProtocol, size: usize) void {
    var needs_new = true;

    if (buffer.*) |existing| {
        const length_sel = apl_runtime.sel_registerName("length");
        const current_len: usize = @intFromPtr(apl_runtime.objc_msgSend(existing, length_sel));
        if (current_len >= size) {
            needs_new = false;
        } else {
            _ = apl_runtime.objc_msgSend(existing, apl_runtime.sel_release);
        }
    }

    if (needs_new) {
        const options: apl_runtime.MTLResourceOptions = apl_runtime.MTLResourceCPUCacheModeDefaultCache | apl_runtime.MTLResourceStorageModeShared;
        const new_buf = apl_runtime.objc_msgSend(self.device.?, apl_runtime.sel_registerName("newBufferWithLength:options:"), size, options);
        buffer.* = @ptrCast(new_buf);
    }
}

pub fn createRenderPassDescriptor(drawable: *apl_runtime.CAMetalDrawable, clear_color: [4]f32) !*apl_runtime.MTLRenderPassDescriptor {
    const desc_class = apl_runtime.objc_getClass("MTLRenderPassDescriptor");
    const alloc_sel = apl_runtime.sel_registerName("alloc");
    const init_sel = apl_runtime.sel_registerName("init");
    const desc = apl_runtime.objc_msgSend(apl_runtime.objc_msgSend(desc_class, alloc_sel), init_sel);

    const color_attach_sel = apl_runtime.sel_registerName("colorAttachments");
    const color_attach = apl_runtime.objc_msgSend(desc, color_attach_sel);
    const object_at_sel = apl_runtime.sel_registerName("objectAtIndexedSubscript:");
    const attach_0 = apl_runtime.objc_msgSend(color_attach, object_at_sel, @as(usize, 0));

    const texture_sel = apl_runtime.sel_registerName("texture");
    const drawable_tex: ?*apl_runtime.MTLTextureProtocol = @ptrCast(apl_runtime.objc_msgSend(drawable, texture_sel));
    const set_texture_sel = apl_runtime.sel_registerName("setTexture:");
    _ = apl_runtime.objc_msgSend(attach_0, set_texture_sel, drawable_tex);

    const set_load_sel = apl_runtime.sel_registerName("setLoadAction:");
    _ = apl_runtime.objc_msgSend(attach_0, set_load_sel, @as(apl_runtime.MTLLoadAction, apl_runtime.MTLLoadActionClear));

    const set_clear_sel = apl_runtime.sel_registerName("setClearColor:");
    const mtl_color = apl_runtime.MTLClearColor{
        .red = clear_color[0],
        .green = clear_color[1],
        .blue = clear_color[2],
        .alpha = clear_color[3],
    };
    _ = apl_runtime.objc_msgSend(attach_0, set_clear_sel, mtl_color);

    const set_store_sel = apl_runtime.sel_registerName("setStoreAction:");
    _ = apl_runtime.objc_msgSend(attach_0, set_store_sel, @as(apl_runtime.MTLStoreAction, apl_runtime.MTLStoreActionStore));

    return @ptrCast(desc);
}
