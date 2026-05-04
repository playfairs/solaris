#include <metal_stdlib>
using namespace metal;

struct VertexIn {
    float2 position [[attribute(0)]];
    float2 tex_coord [[attribute(1)]];
};

struct VertexOut {
    float4 position [[position]];
    float2 tex_coord;
};

vertex VertexOut backgroundVertex(VertexIn in [[stage_in]]) {
    VertexOut out;
    out.position = float4(in.position, 0.0, 1.0);
    out.tex_coord = in.tex_coord;
    return out;
}

fragment float4 backgroundFragment(VertexOut in [[stage_in]],
                                     texture2d<float> background_texture [[texture(0)]]) {
    constexpr sampler texture_sampler(filter::linear, address::clamp_to_edge);
    float4 color = background_texture.sample(texture_sampler, in.tex_coord);
    return color;
}
