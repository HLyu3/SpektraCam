//  Canvas.metal — the app's own drawing, as opposed to the engine's.
//
//  The engine's kernels are compiled by `ios/Tools/build-engine.sh` with
//  safe-math and a `-mmacos-version-min` of its own; the app's shader is
//  compiled by Xcode. That separation is deliberate (RFC-014 §5.1 trap 1):
//  the engine refuses to start if it detects fast-math drift in its kernels,
//  so they must not inherit the app's `MTL_FAST_MATH` setting.
//
//  This shader draws the engine's sRGB texture over the drawable and owns the
//  aspect-fit/zoom viewport. The transform remains available for parity with
//  the desktop canvas, but the iOS session currently uploads the identity.

#include <metal_stdlib>
using namespace metal;

/// The output transform's parameters, uploaded by `CanvasRenderer`.
struct CanvasTransform {
    /// Source linear RGB → target linear RGB, as three rows.
    float3x3 matrix;
    /// The transfer function's mode on each side, as `shaders/nodes.metal`
    /// numbers them: 0 linear, 1 the sRGB-style curve, 2 Cineon.
    uint sourceCCTFMode;
    uint targetCCTFMode;
    /// Whether the gamut compression is on.
    uint gamutActive;
    uint pad0;
    uint pad1;
    uint pad2;
};

/// A full-screen triangle from the vertex id. No vertex buffer, no index
/// buffer: three vertices cover the viewport, and the fragment shader does
/// the rest.
struct CanvasVertexOut {
    float4 position [[position]];
    float2 uv;
};

vertex CanvasVertexOut canvasVertex(uint vertexID [[vertex_id]]) {
    // (-1,-1) (3,-1) (-1,3) — one triangle, twice the area, clipped.
    float2 positions[3] = {float2(-1.0, -1.0), float2(3.0, -1.0), float2(-1.0, 3.0)};
    float2 uv[3] = {float2(0.0, 1.0), float2(2.0, 1.0), float2(0.0, -1.0)};

    CanvasVertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.uv = uv[vertexID];
    return out;
}

/// The transfer functions, as the engine's `nodes.metal` numbers them.
///
/// Mode 0 is sRGB (and Display P3), mode 1 is ProPhoto RGB, mode 2 is Adobe
/// RGB, mode 3 is BT.709/2020. The engine's working space is ProPhoto, so
/// **mode 1 is the one that matters on the source side** -- and it is not
/// the sRGB curve: ProPhoto is a gamma of 1.8 with a 16x linear toe.
///
/// These are the engine's numbers, transcribed from
/// `engine/src/shaders/nodes.metal`'s `cctf_decode_mode` and
/// `cctf_encode_mode`. Using the sRGB curve for mode 1 would look almost
/// right, which is exactly why it has to be the right one.
float decodeTransfer(float value, uint mode) {
    if (mode == 0u) {
        // sRGB: the breakpoint is the *encoded* 0.040449936, as the engine
        // has it.
        float v = max(value, 0.0f);
        return (0.040449936f >= v) ? v / 12.92f : pow((v + 0.055f) / 1.055f, 2.4f);
    }
    if (mode == 1u) {
        // ProPhoto RGB: gamma 1.8, with a 16x linear toe.
        return (value < 16.0f * (1.0f / 512.0f)) ? value / 16.0f
                                                  : pow(max(value, 0.0f), 1.8f);
    }
    if (mode == 2u) {
        return pow(max(value, 0.0f), 563.0f / 256.0f);
    }
    return value;
}

float encodeTransfer(float value, uint mode) {
    if (mode == 0u) {
        float v = max(value, 0.0f);
        return (v <= 0.0031308f) ? 12.92f * v : 1.055f * pow(v, 1.0f / 2.4f) - 0.055f;
    }
    if (mode == 1u) {
        float v = max(value, 0.0f);
        return (v < 1.0f / 512.0f) ? v * 16.0f : pow(v, 1.0f / 1.8f);
    }
    if (mode == 2u) {
        return pow(max(value, 0.0f), 256.0f / 563.0f);
    }
    return value;
}

/// Enable HDR (upstream `HDRRendition`'s kernels, `HDRGrainGain.log2Gain`): the session's tables and the
/// screen's share of them. `on` 0 draws today's SDR picture, clamped.
struct CanvasHDR {
    float lo, hi, top, kappa;
    float rhoMax, tau, weight, on;
};

/// log2 of a pixel's linear luminance (Rec. 709 / sRGB primaries: the preview session's space).
kernel void canvasLog2Y(texture2d<float, access::read> source [[texture(0)]],
                        texture2d<float, access::write> out [[texture(1)]],
                        uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    float3 c = source.read(gid).rgb;
    float3 l = float3(decodeTransfer(c.r, 0u), decodeTransfer(c.g, 0u), decodeTransfer(c.b, 0u));
    float y = dot(l, float3(0.2126, 0.7152, 0.0722));
    out.write(float4(log2(max(y, 1e-30)), 0, 0, 0), gid);
}

/// A table of 256 over [lo, hi], read linearly (the kernels' own reading).
static float tableAt(constant float* t, float x, float lo, float hi) {
    float u = clamp((x - lo) / (hi - lo), 0.0f, 1.0f) * 255.0f;
    int i0 = min(int(floor(u)), 254);
    float f = u - float(i0);
    return t[i0] + (t[i0 + 1] - t[i0]) * f;
}

fragment float4 canvasFragment(CanvasVertexOut in [[stage_in]],
                               texture2d<float> source [[texture(0)]],
                               texture2d<float> localTone [[texture(1)]],
                               constant CanvasTransform& transform [[buffer(0)]],
                               constant float4& frame [[buffer(1)]],
                               constant CanvasHDR& hdr [[buffer(2)]],
                               constant float* tables [[buffer(3)]]) {
    float2 position = (in.uv * 2.0 - 1.0) * float2(1.0, -1.0);
    if (position.x < frame.x || position.x > frame.y ||
        position.y < frame.z || position.y > frame.w) {
        discard_fragment();
    }

    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);

    // The frame rectangle is also the zoom window. Remap the viewport
    // position back into the photo so aspect fit does not crop the centre
    // strip of a portrait image.
    float2 local = float2((position.x - frame.x) / (frame.y - frame.x),
                          (position.y - frame.z) / (frame.w - frame.z));
    float2 photoUV = float2(local.x, 1.0 - local.y);
    float3 rgb = source.sample(linearSampler, photoUV).rgb;

    // The iOS engine result and drawable are both sRGB encoded. With the
    // identity transform, decoding and re-encoding preserve those values.
    float3 linear = float3(decodeTransfer(rgb.r, transform.sourceCCTFMode),
                            decodeTransfer(rgb.g, transform.sourceCCTFMode),
                            decodeTransfer(rgb.b, transform.sourceCCTFMode));

    // Working space → display space, linearly.
    float3 converted = transform.matrix * linear;

    // Encode for the display.
    float3 encoded = float3(encodeTransfer(converted.r, transform.targetCCTFMode),
                             encodeTransfer(converted.g, transform.targetCCTFMode),
                             encodeTransfer(converted.b, transform.targetCCTFMode));

    if (hdr.on < 0.5) return float4(clamp(encoded, 0.0, 1.0), 1.0);

    // Enable HDR: log2 gain = Ks(L') + κ·clamp(ρ(L'), 0, ρmax)·(log2 Y − L'), L' the local tone held within τ.
    float3 lin = float3(decodeTransfer(encoded.r, 0u), decodeTransfer(encoded.g, 0u), decodeTransfer(encoded.b, 0u));
    float l2y = log2(max(dot(lin, float3(0.2126, 0.7152, 0.0722)), 1e-30));
    float L = localTone.sample(linearSampler, photoUV).r;
    L = l2y - clamp(l2y - L, -hdr.tau, hdr.tau);
    float g = tableAt(tables, L, hdr.lo, hdr.hi);
    float rho = clamp(tableAt(tables + 256, L, hdr.lo, hdr.hi), 0.0f, hdr.rhoMax);
    float gain = clamp(g + hdr.kappa * rho * (l2y - L), 0.0f, hdr.top);
    lin *= exp2(hdr.weight * gain);
    return float4(encodeTransfer(lin.r, 0u), encodeTransfer(lin.g, 0u), encodeTransfer(lin.b, 0u), 1.0);
}
