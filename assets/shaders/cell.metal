#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float2 position [[attribute(0)]];
    float2 tex_coord [[attribute(1)]];
    float4 fg_color [[attribute(2)]];
    float4 bg_color [[attribute(3)]];
    float4 glyph_info [[attribute(4)]]; // x, y, width, height in atlas
};

struct VertexOut {
    float4 position [[position]];
    float2 tex_coord;
    float4 fg_color;
    float4 bg_color;
};

vertex VertexOut cellVertex(VertexIn in [[stage_in]]) {
    VertexOut out;
    out.position = float4(in.position, 0.0, 1.0);
    out.tex_coord = in.tex_coord;
    out.fg_color = in.fg_color;
    out.bg_color = in.bg_color;
    return out;
}

fragment float4 cellFragment(VertexOut in [[stage_in]],
                              texture2d<float> glyph_atlas [[texture(0)]]) {
    constexpr sampler atlas_sampler(filter::linear, address::clamp_to_edge);
    
    float4 glyph_sample = glyph_atlas.sample(atlas_sampler, in.tex_coord);
    
    // Background color (with alpha)
    float4 bg = in.bg_color;
    
    // Text color modulated by glyph alpha
    float4 text = in.fg_color * glyph_sample.a;
    
    // Blend text over background
    float4 final = text + bg * (1.0 - text.a);
    final.a = 1.0;
    
    return final;
}
