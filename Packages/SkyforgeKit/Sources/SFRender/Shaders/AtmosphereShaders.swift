// SKYFORGE — Apache-2.0
// Hillaire 2020 sky LUTs as Metal compute kernels (runtime-compiled MSL, ADR-0003). A line-for-line
// port of SFAtmosphere/Scattering.swift, which is the oracle in SFRenderTests.

public enum AtmosphereShaders {
    public static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Atmo {
        float4 radii;      // bottom, top, rayleigh H, mie H (km)
        float4 rayleigh;   // scattering xyz (1/km), mie g
        float4 mieScat;    // scattering xyz, turbidity
        float4 mieExt;     // extinction xyz, ozone centre
        float4 ozone;      // absorption xyz, ozone half-width
        float4 ground;     // albedo xyz, view height (km)
        float4 sun;        // unused xyz, cos(sun zenith)
        float4 solar;      // irradiance xyz, unused
    };

    constexpr sampler lin(filter::linear, address::clamp_to_edge, coord::normalized);
    constant float PI = 3.14159265358979;

    static float3 densities(constant Atmo& a, float h) {
        float hh = max(h, 0.0f);
        return float3(exp(-hh / a.radii.z), exp(-hh / a.radii.w) * a.mieScat.w,
                      max(0.0f, 1.0f - abs(h - a.mieExt.w) / a.ozone.w));
    }
    static float3 extinction(constant Atmo& a, float h) {
        float3 d = densities(a, h);
        return a.rayleigh.xyz * d.x + a.mieExt.xyz * d.y + a.ozone.xyz * d.z;
    }
    static bool raySphere(float r, float mu, float R, thread float& t) {
        float disc = r * r * (mu * mu - 1.0f) + R * R;
        if (disc < 0.0f) return false;
        float s = sqrt(disc);
        float t1 = -r * mu - s, t2 = -r * mu + s;
        if (t1 > 0.0f) { t = t1; return true; }
        if (t2 > 0.0f) { t = t2; return true; }
        return false;
    }
    static float2 transmittanceUV(constant Atmo& a, float r, float mu) {
        float bot = a.radii.x, top = a.radii.y;
        float H = sqrt(top * top - bot * bot);
        float rho = sqrt(max(0.0f, r * r - bot * bot));
        float disc = r * r * (mu * mu - 1.0f) + top * top;
        float d = max(0.0f, -r * mu + sqrt(max(0.0f, disc)));
        float dMin = top - r, dMax = rho + H;
        return float2((d - dMin) / max(1e-9f, dMax - dMin), rho / H);
    }
    static float3 transmittance(constant Atmo& a, texture2d<float> t, float r, float mu) {
        return t.sample(lin, transmittanceUV(a, r, mu)).rgb;
    }
    static float rayleighPhase(float c) { return 3.0f / (16.0f * PI) * (1.0f + c * c); }
    static float miePhase(float c, float g) {
        float k = 3.0f / (8.0f * PI) * (1.0f - g * g) / (2.0f + g * g);
        return k * (1.0f + c * c) / pow(1.0f + g * g - 2.0f * g * c, 1.5f);
    }

    kernel void transmittance_lut(texture2d<float, access::write> out [[texture(0)]],
                                  constant Atmo& a [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        uint W = out.get_width(), Hh = out.get_height();
        if (gid.x >= W || gid.y >= Hh) return;
        float u = (float(gid.x) + 0.5f) / float(W), v = (float(gid.y) + 0.5f) / float(Hh);
        float bot = a.radii.x, top = a.radii.y;
        float H = sqrt(top * top - bot * bot);
        float rho = H * v;
        float r = sqrt(rho * rho + bot * bot);
        float dMin = top - r, dMax = rho + H;
        float d = dMin + u * (dMax - dMin);
        float mu = d == 0.0f ? 1.0f : clamp((H * H - rho * rho - d * d) / (2.0f * r * d), -1.0f, 1.0f);
        float t = 0.0f;
        raySphere(r, mu, top, t);
        const int steps = 40;
        float dt = t / float(steps);
        float3 od = 0.0f;
        for (int i = 0; i < steps; i++) {
            float s = (float(i) + 0.5f) * dt;
            float ri = sqrt(r * r + s * s + 2.0f * r * mu * s);
            od += extinction(a, ri - bot) * dt;
        }
        out.write(float4(exp(-od), 1.0f), gid);
    }

    kernel void multiscatter_lut(texture2d<float, access::write> out [[texture(0)]],
                                 texture2d<float> tLUT [[texture(1)]],
                                 constant Atmo& a [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        uint N = out.get_width();
        if (gid.x >= N || gid.y >= out.get_height()) return;
        float cosSun = (float(gid.x) + 0.5f) / float(N) * 2.0f - 1.0f;
        float bot = a.radii.x, top = a.radii.y;
        float r = bot + (float(gid.y) + 0.5f) / float(N) * (top - bot);
        float3 sunDir = float3(sqrt(1.0f - cosSun * cosSun), cosSun, 0.0f);
        const float uniformPhase = 1.0f / (4.0f * PI);
        const int dirs = 8, steps = 20;
        float3 lum = 0.0f, fms = 0.0f;
        for (int j = 0; j < dirs; j++) {
            for (int i = 0; i < dirs; i++) {
                float theta = acos(1.0f - 2.0f * (float(j) + 0.5f) / float(dirs));
                float phi = 2.0f * PI * (float(i) + 0.5f) / float(dirs);
                float3 dir = float3(sin(theta) * cos(phi), cos(theta), sin(theta) * sin(phi));
                float mu = dir.y;
                float tG = 0.0f, tT = 0.0f;
                bool hitGround = raySphere(r, mu, bot, tG);
                bool hitTop = raySphere(r, mu, top, tT);
                if (!hitGround && !hitTop) continue;
                float tMax = hitGround ? tG : tT;
                float dt = tMax / float(steps);
                float3 L = 0.0f, F = 0.0f, T = 1.0f;
                float3 origin = float3(0.0f, r, 0.0f);
                for (int k = 0; k < steps; k++) {
                    float s = (float(k) + 0.5f) * dt;
                    float3 pos = origin + dir * s;
                    float ri = length(pos);
                    float h = ri - bot;
                    float3 d = densities(a, h);
                    float3 scat = a.rayleigh.xyz * d.x + a.mieScat.xyz * d.y;
                    float3 ext = extinction(a, h);
                    float3 stepT = exp(-ext * dt);
                    float3 up = pos / ri;
                    float3 sunT = transmittance(a, tLUT, ri, dot(up, sunDir));
                    float3 S = sunT * scat * uniformPhase;
                    float3 safeExt = max(ext, float3(1e-12f));
                    L += T * (S - S * stepT) / safeExt;
                    F += T * (scat - scat * stepT) / safeExt;
                    T *= stepT;
                }
                if (hitGround) {
                    float3 pos = origin + dir * tMax;
                    float3 up = normalize(pos);
                    float nl = max(0.0f, dot(up, sunDir));
                    L += T * transmittance(a, tLUT, bot, dot(up, sunDir)) * nl * a.ground.xyz / PI;
                }
                lum += L; fms += F;
            }
        }
        float sphere = 4.0f * PI / float(dirs * dirs);
        float3 l2 = lum * sphere * uniformPhase;
        float3 f = fms * sphere * uniformPhase;
        out.write(float4(l2 / (1.0f - f), 1.0f), gid);
    }

    kernel void skyview_lut(texture2d<float, access::write> out [[texture(0)]],
                            texture2d<float> tLUT [[texture(1)]],
                            texture2d<float> msLUT [[texture(2)]],
                            constant Atmo& a [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        uint W = out.get_width(), Hh = out.get_height();
        if (gid.x >= W || gid.y >= Hh) return;
        float bot = a.radii.x, top = a.radii.y;
        float r = bot + max(0.001f, a.ground.w);
        float horizon = PI - asin(min(1.0f, bot / r));
        float sunZ = a.sun.w;
        float3 sunDir = float3(sqrt(max(0.0f, 1.0f - sunZ * sunZ)), sunZ, 0.0f);
        float v = (float(gid.y) + 0.5f) / float(Hh);
        float zenith;
        if (v < 0.5f) { float c = 1.0f - 2.0f * v; zenith = horizon * (1.0f - c * c); }
        else { float c = 2.0f * v - 1.0f; zenith = horizon + (PI - horizon) * c * c; }
        float az = (float(gid.x) + 0.5f) / float(W) * 2.0f * PI;
        float3 dir = float3(sin(zenith) * cos(az), cos(zenith), sin(zenith) * sin(az));
        float mu = dir.y;
        float tG = 0.0f, tT = 0.0f;
        bool hitGround = raySphere(r, mu, bot, tG);
        bool hitTop = raySphere(r, mu, top, tT);
        if (!hitGround && !hitTop) { out.write(float4(0.0f), gid); return; }
        float tMax = hitGround ? tG : tT;
        float cosTheta = dot(dir, sunDir);
        float pR = rayleighPhase(cosTheta), pM = miePhase(cosTheta, a.rayleigh.w);
        float3 origin = float3(0.0f, r, 0.0f);
        float3 L = 0.0f, T = 1.0f;
        const int steps = 32;
        float prev = 0.0f;
        for (int i = 0; i < steps; i++) {
            float f1 = (float(i) + 1.0f) / float(steps);
            float t1 = tMax * f1 * f1;
            float dt = t1 - prev;
            float s = prev + dt * 0.5f;
            prev = t1;
            float3 pos = origin + dir * s;
            float ri = length(pos);
            float h = ri - bot;
            float3 d = densities(a, h);
            float3 scatR = a.rayleigh.xyz * d.x, scatM = a.mieScat.xyz * d.y;
            float3 ext = extinction(a, h);
            float3 up = pos / ri;
            float sunMu = dot(up, sunDir);
            float3 sunT = transmittance(a, tLUT, ri, sunMu);
            float tmp = 0.0f;
            float visible = raySphere(ri, sunMu, bot, tmp) ? 0.0f : 1.0f;
            float3 psi = msLUT.sample(lin, float2(sunMu * 0.5f + 0.5f, h / (top - bot))).rgb;
            float3 S = (sunT * visible * (scatR * pR + scatM * pM) + psi * (scatR + scatM)) * a.solar.xyz;
            float3 stepT = exp(-ext * dt);
            float3 safeExt = max(ext, float3(1e-12f));
            L += T * (S - S * stepT) / safeExt;
            T *= stepT;
        }
        out.write(float4(L, 1.0f), gid);
    }
    """
}
