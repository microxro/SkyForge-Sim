// SKYFORGE — Apache-2.0
// Screen-space precipitation overlay (rain / drizzle / snow / hail), wet-air veil and lightning flash.
// One full-screen triangle, no textures, no depth: three parallax layers of hashed streaks or flakes
// are composited with premultiplied alpha over the finished frame, after clouds and before post.

public enum WeatherShaders {
    public static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct WeatherUniforms {
        float4 look;     // x density, y fall speed (m/s), z streak length (s), w wetness
        float4 params;   // x kind (0 none, 1 drizzle, 2 rain, 3 snow, 4 hail), y time (s), z lightning 0...1, w aspect (w/h)
        float4 motion;   // x screen-space slant (horizontal shift per unit height), y speed scale, z,w unused
        float4 tint;     // rgb colour of the precipitation (sky/ground ambient), w unused
    };

    static float wx_hash(int x, int y) {
        uint h = uint(x) * 0x8DA6B343u;
        h ^= uint(y) * 0xD8163841u;
        h ^= h >> 13;
        h *= 0x5BD1E995u;
        h ^= h >> 15;
        return float(h & 0x00FFFFFFu) / 16777216.0;
    }

    struct WeatherVarying { float4 position [[position]]; float2 uv; };

    vertex WeatherVarying weather_vertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        WeatherVarying o;
        o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        o.uv = float2(p.x, 1.0 - p.y);
        return o;
    }

    // Premultiplied output: rgb already multiplied by alpha.
    fragment float4 weather_fragment(WeatherVarying in [[stage_in]], constant WeatherUniforms& u [[buffer(0)]]) {
        float density = u.look.x;
        float fall = u.look.y;
        float len = max(u.look.z, 0.004);
        float wet = u.look.w;
        int kind = int(u.params.x + 0.5);
        float time = u.params.y;
        float flash = u.params.z;
        float aspect = u.params.w;
        float slant = u.motion.x;
        float speedScale = u.motion.y;

        float3 acc = float3(0.0);
        float alpha = 0.0;

        if (kind > 0 && density > 0.0) {
            for (int layer = 0; layer < 3; layer++) {
                float depthK = 1.0 + float(layer);               // 1 = near, 3 = far
                float cols = 38.0 * depthK;                      // far drops are thinner and more numerous
                float2 p = float2(in.uv.x * aspect, in.uv.y);
                p.x -= p.y * slant;
                float cx = p.x * cols;
                int col = int(floor(cx));
                float fx = fract(cx) - 0.5;
                float colHash = wx_hash(col, layer * 977);
                float fallRate = fall * 0.045 * speedScale / depthK * (0.75 + 0.5 * colHash);
                float rows = (kind == 3) ? cols * 0.9 : 5.0 / depthK; // snow: square cells; rain: tall cells
                float yy = (p.y - time * fallRate + colHash * 7.0)   // y grows downward, so subtracting moves the pattern down * rows;
                int row = int(floor(yy));
                float fy = fract(yy);
                float present = step(wx_hash(col + layer * 31, row), density / depthK * 1.6);
                float shape = 0.0;
                if (kind == 3) {                                  // snow: soft round flake, gentle sway
                    float sway = 0.18 * sin(time * (0.8 + colHash) + colHash * 20.0);
                    float2 d = float2(fx + sway, fy - 0.5);
                    shape = 1.0 - smoothstep(0.12, 0.34, length(d));
                } else if (kind == 4) {                           // hail: short bright beads
                    float2 d = float2(fx * 1.2, (fy - 0.5) * 2.0);
                    shape = 1.0 - smoothstep(0.1, 0.3, length(d));
                } else {                                          // rain / drizzle: thin tapered streak
                    float along = (len * 6.0 < 0.9) ? len * 6.0 : 0.9;
                    float head = clamp(fy / along, 0.0, 1.0);
                    float inside = step(fy, along);
                    float width = 0.05 + 0.06 * head;               // thin tail at the top, bright leading end at the bottom
                    shape = inside * (1.0 - smoothstep(0.0, width, abs(fx))) * head;
                }
                float a = present * shape * (0.55 / depthK);
                acc += u.tint.rgb * a;
                alpha += a;
            }
        }
        // Wet-air veil: greys and darkens the scene a little as rain thickens.
        float veil = wet * 0.22;
        acc += float3(0.30, 0.33, 0.37) * veil;
        alpha += veil;
        // Lightning: cool white wash.
        acc += float3(0.82, 0.88, 1.0) * flash * 0.42;
        alpha += flash * 0.10;
        alpha = clamp(alpha, 0.0, 0.9);
        return float4(min(acc, float3(1.2)), alpha);
    }
    """
}
