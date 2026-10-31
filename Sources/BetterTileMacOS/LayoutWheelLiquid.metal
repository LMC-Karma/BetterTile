// The liquid Layout Wheel body: glass tint, edge light, sheen, selection glow,
// separators and fan droplets in one pass. Icons and text are layers above it,
// and the system blur is a view below it. Independently authored for
// BetterTile; see LayoutWheelLiquidRenderer.swift for the uniform layout.

#include <metal_stdlib>
using namespace metal;

constant int rimSamples = 256;
constant int maximumDroplets = 12;

// Keep in step with LayoutWheelLiquidUniforms in Swift: float4 fields only.
struct Uniforms {
    float4 frame;       // pixel size in points, drawing scale, opacity, well radius
    float4 center;      // centre in points (xy), outer rest radius, step rest radius (0 = none)
    float4 glow;        // angle, radius, intensity, angular spread
    float4 glowStyle;   // radial half-width, accent alpha, droplet count, smooth-union radius
    float4 bodyTint;    // premultiplied ring tint
    float4 wellTint;    // premultiplied well tint
    float4 accent;      // accent colour (rgb), dark appearance flag
    float4 light;       // direction toward the light (xy), rim strength, sheen strength
    float4 lines;       // separator alpha, separator inset, seam alpha, shadow alpha
    float4 blur;        // blur-mask shrink (0...1), colorless screen highlight flag, Light colorless rim strength (z), unused (w)
    float4 standIn;     // premultiplied blur-material tint for edges past the blur circles
    float4 droplets[maximumDroplets];      // centre (xy), radius, opacity
    float4 dropletShape[maximumDroplets];  // oval cos 2a, oval sin 2a, swell, opening connection
};

struct VertexOut {
    float4 position [[position]];
};

vertex VertexOut liquidWheelVertex(uint id [[vertex_id]]) {
    // One triangle that covers the whole drawable.
    float2 corner = float2((id << 1) & 2, id & 2);
    VertexOut out;
    out.position = float4(corner * float2(2, -2) + float2(-1, 1), 0, 1);
    return out;
}

struct Edge {
    float radius;
    float slope;    // d radius / d angle
    float bend;     // d2 radius / d angle2
};

// Cubic Hermite between samples, using the exact sampled slope, so the
// outline and its normal stay smooth at any size.
static Edge edgeAt(constant float4 *rim, float angle) {
    float t = angle * (float(rimSamples) / (2 * M_PI_F));
    t -= floor(t / float(rimSamples)) * float(rimSamples);
    int i = int(floor(t));
    float f = t - float(i);
    float4 a = rim[i & (rimSamples - 1)];
    float4 b = rim[(i + 1) & (rimSamples - 1)];
    float h = 2 * M_PI_F / float(rimSamples);
    float f2 = f * f, f3 = f2 * f;
    Edge e;
    e.radius = (2 * f3 - 3 * f2 + 1) * a.x + (f3 - 2 * f2 + f) * h * a.y
             + (-2 * f3 + 3 * f2) * b.x + (f3 - f2) * h * b.y;
    e.slope = mix(a.y, b.y, f);
    e.bend = mix(a.z, b.z, f);
    return e;
}

// Polynomial smooth minimum. `weight` is the share of `a` in the blend.
static float smoothUnion(float a, float b, float k, thread float &weight) {
    if (k <= 0) { weight = a < b ? 1 : 0; return min(a, b); }
    weight = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, weight) - k * weight * (1 - weight);
}

static float4 over(float4 top, float4 bottom) { return top + bottom * (1 - top.a); }

// The same angle in -pi...pi.
static float wrapAngle(float angle) {
    return angle - 2 * M_PI_F * floor((angle + M_PI_F) / (2 * M_PI_F));
}

fragment half4 liquidWheelFragment(VertexOut in [[stage_in]],
                                   constant Uniforms &u [[buffer(0)]],
                                   constant float4 *outerRim [[buffer(1)]],
                                   constant float4 *stepRim [[buffer(2)]]) {
    float pointsPerPixel = u.frame.x;
    float drawScale = max(u.frame.y, 0.01);
    float opacity = u.frame.z;
    float wellRadius = u.frame.w;
    float restRadius = u.center.z;
    bool hasStep = u.center.w > 0;
    float aa = pointsPerPixel / drawScale;

    float2 p = (in.position.xy * pointsPerPixel - u.center.xy) / drawScale;
    float r = max(length(p), 1e-3);
    float angle = atan2(p.y, p.x);
    float2 radial = p / r;
    float2 tangent = float2(-radial.y, radial.x);

    // Body: the outer outline as a signed distance, corrected for slope.
    Edge outer = edgeAt(outerRim, angle);
    float slopeRatio = outer.slope / r;
    float body = (r - outer.radius) * rsqrt(1 + slopeRatio * slopeRatio);
    float2 bodyNormal = normalize(radial * outer.radius - tangent * outer.slope);
    // Polar curvature, relative to the resting circle's.
    float rr = outer.radius;
    float curvature = (rr * rr + 2 * outer.slope * outer.slope - rr * outer.bend)
        / pow(rr * rr + outer.slope * outer.slope, 1.5) * restRadius;

    // Droplets join the body with a smooth union, so a neck forms while they are close.
    int count = int(u.glowStyle.z);
    float merge = u.glowStyle.w;
    float d = body;
    float2 normal = bodyNormal;
    float bodyShare = 1;
    float swellGlow = 0;
    float swellRing = 0;
    float4 faded = float4(0);
    // Where the system blur sits behind this pixel: the panel's mask, 1 pt
    // inside the outline and each droplet, shrunk by `recede` while fading.
    float recede = u.blur.x;
    float blurred = recede > 0 ? clamp(0.5 - (r - (outer.radius - 1.0) * recede) / aa, 0.0, 1.0) : 0.0;
    for (int i = 0; i < count && i < maximumDroplets; i++) {
        float4 drop = u.droplets[i];
        float4 shape = u.dropletShape[i];
        if (drop.z <= 0.01) { continue; }
        float2 q = p - drop.xy;
        float dist = max(length(q), 1e-3);
        float a = atan2(q.y, q.x);
        float amplitude = 1 + shape.x * cos(2 * a) + shape.y * sin(2 * a);
        float size = drop.z * amplitude * rsqrt(1 + 0.5 * (shape.x * shape.x + shape.y * shape.y));
        float dd = dist - size;
        if (recede > 0 && drop.z > 2) {
            float reach = (drop.z - 1.0) * min(drop.w, 1.0) * recede;
            blurred = max(blurred, clamp(0.5 - (dist - reach) / aa, 0.0, 1.0));
        }
        // The aimed droplet fills with the accent, brightest at its centre.
        swellGlow = max(swellGlow, shape.z * (0.55 + 0.45 * smoothstep(size, 0.0, dist)) * step(dd, 0.0));
        swellRing = max(swellRing, shape.z * exp(-pow((dd + 1.5) / 3.5, 2.0)));
        if (drop.w < 0.999) {
            // Reduce Motion fades droplets in place; they never merge.
            faded = max(faded, float4(drop.w * clamp(0.5 - dd / aa, 0.0, 1.0)));
            continue;
        }
        float weight;
        d = smoothUnion(d, dd, merge * shape.w, weight);
        normal = normalize(mix(q / dist, normal, weight) + 1e-5);
        bodyShare *= weight;
        curvature = mix(restRadius / max(size, 1.0), curvature, weight);
    }
    float coverage = clamp(0.5 - d / aa, 0.0, 1.0);
    float fadedCoverage = faded.a;
    float fill = max(coverage, fadedCoverage);

    float2 toLight = u.light.xy;
    float lit = dot(normal, toLight);
    float inside = max(0.0, -d);

    // Soft shadow below the body, offset downward through the gradient.
    float shadowDistance = max(0.0, d - 3 * normal.y);
    float4 color = float4(0, 0, 0, u.lines.w * exp(-shadowDistance / 6) * (1 - fill));

    // Past the blur circles, stand in for the blur material's own tint.
    if (recede > 0) {
        color = over(u.standIn * (fill * (1 - blurred)), color);
    }

    // Ring and well tint.
    float well = clamp(0.5 - (r - wellRadius) / aa, 0.0, 1.0) * bodyShare;
    float4 tint = mix(u.bodyTint, u.wellTint, well);
    color = over(tint * fill, color);

    // A broad sheen across the glass, brightest toward the light.
    float sheen = u.light.w * pow(clamp(0.5 + 0.5 * dot(p / restRadius, toLight), 0.0, 1.0), 2.0) * (1 - well);
    color = over(float4(sheen) * fill, color);

    // Selection: an accent cloud around the aimed slot, and the aimed droplet.
    float delta = wrapAngle(angle - u.glow.x);
    // Light enters at the outside and diffuses inward, without an interior peak.
    // Keep the travel widening and fade supplied by the model.
    float travelWidth = u.glow.w / (M_PI_F / 4 * 0.82);
    float halfSlice = M_PI_F / 8 * travelWidth;
    float feather = 12.0 * M_PI_F / 180 * travelWidth;
    float around = 1 - smoothstep(halfSlice - feather, halfSlice + feather, abs(delta));
    float selectedRim = hasStep && u.glow.y < u.center.w ? u.center.w : restRadius;
    float across = smoothstep(wellRadius, selectedRim, r);
    if (selectedRim < restRadius) { across *= 1 - smoothstep(selectedRim - 2, selectedRim + 6, r); }
    float glow = u.glow.z * around * across * bodyShare * (1 - well) + swellGlow;
    float glowAlpha = clamp(u.glowStyle.y * glow, 0.0, 1.0) * fill;
    // A little neutral light lifts the glass beneath the colored cloud.
    float innerLight = 0.06 * u.glow.z * around * across * bodyShare * (1 - well) * fill;
    color.rgb += (color.a - color.rgb) * innerLight;
    if (u.blur.y > 0.5) {
        // Screen the existing glass toward white without adding an opaque white cloud.
        // Preserve alpha: the backdrop remains just as transparent and no hue is introduced.
        color.rgb += (color.a - color.rgb) * glowAlpha;
        if (u.accent.w < 0.5) {
            // A faint neutral contour gives colorless Light glass a visible aim, including opaque fallback.
            float angular = delta / max(u.glow.w, 1e-3);
            float radial = (r - u.glow.y) / max(u.glowStyle.x, 1.0);
            float contour = exp(-pow((angular * angular + radial * radial - 0.80) / 0.30, 2.0));
            float contrast = u.blur.z * contour * u.glow.z * bodyShare * (1 - well) * fill;
            color.rgb *= 1 - contrast;
        }
    } else {
        color = over(float4(u.accent.rgb * glowAlpha, glowAlpha), color);
    }

    // The aimed bubble shares the cloud color and pass, with a soft lit edge.
    float bubbleLight = 0.12 * swellGlow * fill;
    color.rgb += (color.a - color.rgb) * bubbleLight;
    float ringAlpha = 0.22 * swellRing * fill;
    color = over(float4(u.accent.rgb * ringAlpha, ringAlpha), color);

    // Separators between slots, on each ring, fading at both ends.
    float slotWidth = M_PI_F / 4;
    float boundary = -M_PI_F / 2 + slotWidth / 2;
    float k = round((angle - boundary) / slotWidth);
    float lineDistance = abs(r * sin(angle - (boundary + k * slotWidth)));
    float inset = u.lines.y;
    float stepRadius = 0;
    float bandStart = wellRadius + inset;
    float bandEnd = outer.radius - inset;
    float seam = 0;
    if (hasStep) {
        Edge s = edgeAt(stepRim, angle);
        stepRadius = s.radius;
        float ds = r - stepRadius;
        // Engraved step: a dark groove with a lit lip on its outer side.
        float groove = clamp(1 - abs(ds + 0.5) / max(0.9, aa), 0.0, 1.0);
        float lip = clamp(1 - abs(ds - 0.9) / max(0.9, aa), 0.0, 1.0) * (0.4 + 0.6 * clamp(-dot(radial, toLight), 0.0, 1.0));
        seam = groove * u.lines.z * bodyShare;
        color = over(float4(0, 0, 0, seam) * fill, color);
        color = over(float4(lip * 0.7 * u.lines.z) * bodyShare * fill, color);
        if (r < stepRadius) { bandEnd = stepRadius - inset; } else { bandStart = stepRadius + inset; }
    }
    float ends = smoothstep(bandStart, bandStart + 5, r) * (1 - smoothstep(bandEnd - 5, bandEnd, r));
    float separator = u.lines.x * clamp(1 - (lineDistance - 0.5) / aa, 0.0, 1.0) * ends * bodyShare * (1 - well);
    float3 separatorInk = u.accent.w > 0.5 ? float3(1) : float3(0);
    color = over(float4(separatorInk * separator, separator) * fill, color);

    // Bevel: light enters on the lit side and leaves darker on the far side.
    float bevel = exp(-inside / 6);
    color = over(float4(0.10 * bevel * max(lit, 0.0)) * coverage, color);
    color = over(float4(0, 0, 0, 0.10 * bevel * max(-lit, 0.0)) * coverage, color);

    // Edge light: a thin bright line, stronger where the edge curves sharply.
    float line = clamp(1 - abs(inside - 0.8) / max(0.8, aa), 0.0, 1.0);
    float sharp = clamp((curvature - 1) * 0.35, 0.0, 1.0);
    float front = pow(clamp(lit, 0.0, 1.0), 1.5);
    float back = 0.35 * pow(clamp(-lit, 0.0, 1.0), 2.0);
    float rim = u.light.z * line * (0.22 + 0.78 * front + back + 0.6 * sharp);
    float3 rimColor = mix(float3(1), u.accent.rgb, 0.55 * u.glow.z * around * bodyShare);
    color = over(float4(rimColor * rim, rim) * coverage, color);

    // The well sits lower: shaded where the ring overhangs it, lit opposite.
    float wellEdge = clamp(1 - abs(r - wellRadius) / max(1.1, aa), 0.0, 1.0) * bodyShare;
    float facing = dot(radial, toLight);
    color = over(float4(0, 0, 0, 0.28 * wellEdge * clamp(facing, 0.0, 1.0)) * fill, color);
    color = over(float4(0.22 * wellEdge * clamp(-facing, 0.0, 1.0)) * fill, color);

    // Droplets that fade in place under Reduce Motion use the ring tint.
    color = over(u.bodyTint * (fadedCoverage * (1 - coverage)), color);

    return half4(color * opacity);
}

// Icons and chevrons: textured quads from one cached atlas, drawn in the same
// pass as the body so they move with it on exactly the same frame.

struct Sprite {
    float4 rect;    // centre in model points (xy), half size in points (zw)
    float4 uv;      // atlas corners
    float4 style;   // rotation, opacity, tint mix, unused
};

struct SpriteOut {
    float4 position [[position]];
    float2 uv;
    float opacity;
    float tint;
};

vertex SpriteOut liquidWheelSpriteVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                         constant Sprite *sprites [[buffer(0)]],
                                         constant float4 *frame [[buffer(1)]]) {
    // frame[0]: view size in points (xy), drawing scale, opacity; frame[1]: centre in points.
    const float2 corners[6] = { float2(-1, -1), float2(1, -1), float2(-1, 1),
                                float2(1, -1), float2(1, 1), float2(-1, 1) };
    float2 corner = corners[vid];
    Sprite s = sprites[iid];
    float c = cos(s.style.x), n = sin(s.style.x);
    float2 local = corner * s.rect.zw;
    local = float2(local.x * c - local.y * n, local.x * n + local.y * c);
    float2 point = frame[1].xy + (s.rect.xy + local) * frame[0].z;
    SpriteOut out;
    out.position = float4(point.x / frame[0].x * 2 - 1, 1 - point.y / frame[0].y * 2, 0, 1);
    out.uv = mix(s.uv.xy, s.uv.zw, corner * 0.5 + 0.5);
    out.opacity = s.style.y * frame[0].w;
    out.tint = s.style.z;
    return out;
}

fragment half4 liquidWheelSpriteFragment(SpriteOut in [[stage_in]], texture2d<half> atlas [[texture(0)]],
                                        constant float4 &tint [[buffer(0)]]) {
    constexpr sampler linear(filter::linear, address::clamp_to_edge);
    half4 glyph = atlas.sample(linear, in.uv);
    glyph.rgb = mix(glyph.rgb, half3(tint.rgb) * glyph.a, half(in.tint));
    return glyph * half(in.opacity);
}
