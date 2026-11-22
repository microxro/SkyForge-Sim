// Host-side checks of the anisotropic GGX used by CockpitMaterialShaders (the MSL itself, compiled through
// metal_shim.h). 1) D integrates to 1 over the projected hemisphere; 2) the specular lobe never returns more
// energy than it receives (F = 1); 3) grooves along t stretch the highlight along b.
#include "part1.cpp"
#include <cstdio>

static bool ok = true;
static void check(bool c, const char* what, double a, double b) { printf("%s %-58s %.5f (want %.5f)\n", c ? "PASS" : "FAIL", what, a, b); ok &= c; }

int main() {
    const float3 n{0, 0, 1}, t{1, 0, 0}, b{0, 1, 0};
    const float rough[] = {0.3f, 0.5f, 0.7f};
    const float aniso[] = {0.0f, 0.5f, 0.8f, 0.95f};
    // 1) ∫ D(h) (h·n) dω_h = 1
    for (float r : rough) for (float an : aniso) {
        float2 a = ck_alphas(r, an);
        const int NT = 4000, NP = 720;
        double sum = 0;
        for (int i = 0; i < NT; i++) {
            double th = (i + 0.5) / NT * M_PI / 2;
            for (int j = 0; j < NP; j++) {
                double ph = (j + 0.5) / NP * 2 * M_PI;
                float3 h{(float)(sin(th) * cos(ph)), (float)(sin(th) * sin(ph)), (float)cos(th)};
                sum += ck_D(dot(h, t), dot(h, b), dot(h, n), a) * cos(th) * sin(th);
            }
        }
        sum *= (M_PI / 2 / NT) * (2 * M_PI / NP);
        char buf[96]; snprintf(buf, sizeof buf, "D normalisation rough=%.1f aniso=%.2f", r, an);
        check(fabs(sum - 1.0) < 2e-3, buf, sum, 1.0);
    }
    // 2) directional albedo ≤ 1 for F = 1, several view angles and tangent rotations
    for (float an : {0.0f, 0.65f, 0.95f}) for (float vz : {0.95f, 0.6f, 0.25f}) for (float rot : {0.0f, 1.0f}) {
        float3 v = normalize(float3{(float)(sqrt(1 - vz * vz) * cos(rot)), (float)(sqrt(1 - vz * vz) * sin(rot)), vz});
        double sum = 0;
        const int NT = 1500, NP = 720;
        for (int i = 0; i < NT; i++) {
            double th = (i + 0.5) / NT * M_PI / 2;
            for (int j = 0; j < NP; j++) {
                double ph = (j + 0.5) / NP * 2 * M_PI;
                float3 l{(float)(sin(th) * cos(ph)), (float)(sin(th) * sin(ph)), (float)cos(th)};
                float3 s = ck_anisoSpecular(n, t, v, l, 0.5f, an, float3(1.0f));
                sum += s.x * sin(th);                      // spec is already × n·l
            }
        }
        sum *= (M_PI / 2 / NT) * (2 * M_PI / NP);
        char buf[96]; snprintf(buf, sizeof buf, "albedo aniso=%.2f nv=%.2f rot=%.0f ≤ 1", an, vz, rot);
        check(sum <= 1.0005 && sum > 0.5, buf, sum, 1.0);
    }
    // 3) orientation: tilt h by 20° along t and along b; with grooves along t the b tilt must be brighter
    {
        float2 a = ck_alphas(0.5f, 0.8f);
        float s = sin(0.349f), c = cos(0.349f);
        float dt = ck_D(s, 0, c, a), db = ck_D(0, s, c, a);
        check(db > dt * 1.5, "highlight stretched along b (perpendicular to grooves)", db / dt, 1.5);
    }
    // 4) isotropic limit equals plain GGX
    {
        float2 a = ck_alphas(0.5f, 0.0f);
        float th = 0.4f, ggx = (a.x * a.x) / (M_PI * powf(cosf(th) * cosf(th) * (a.x * a.x - 1) + 1, 2));
        float d = ck_D(sinf(th), 0, cosf(th), a);
        check(fabs(d - ggx) / ggx < 1e-4, "aniso = 0 reduces to isotropic GGX", d, ggx);
    }
    // 5) glass: finite, non-negative, alpha near 1 - T; dust flares when looking toward the sun
    {
        bool fin = true; float aMin = 1, aMax = 0;
        for (float nvv : {1.0f, 0.7f, 0.3f, 0.08f}) for (float d : {0.0f, 0.5f, 1.0f}) for (int k = 0; k < 40; k++) {
            float3 n{0, 0, 1}, v = normalize(float3{sqrtf(1 - nvv * nvv), 0, nvv}), sun = normalize(float3{0.3f, 0.2f, 0.9f});
            float3 p{0.9f + 0.01f * k, -0.2f + 0.013f * k, -0.6f + 0.007f * k};
            CKGlassOut g = ck_canopyGlass(n, v, sun, float3(3.0f), float3(0.3f), float3(0.2f), 0.5f, normalize(float3{0.3f, 0, 0.7f}),
                                          normalize(float3{0.32f, 0, 0.7f}), p, 0.0004f, d, d, 0.005f);
            fin &= std::isfinite(g.rgb.x) && std::isfinite(g.rgb.y) && std::isfinite(g.rgb.z) && std::isfinite(g.alpha) && g.rgb.x >= 0 && g.rgb.y >= 0 && g.rgb.z >= 0;
            aMin = std::min(aMin, g.alpha); aMax = std::max(aMax, g.alpha);
        }
        check(fin, "glass output finite and non-negative", fin, 1);
        check(aMin > 0.08f && aMin < 0.12f && aMax < 0.9f, "glass alpha at normal incidence ~ 1 - T (two surfaces, ~0.10)", aMin, 0.096);
        float3 n{0, 0, 1}, v{0, 0, 1}, p{0.9f, 0.1f, -0.6f};
        float3 into = float3{0.0f, 0.0f, -1.0f}, off = normalize(float3{0.9f, 0.0f, -0.43f});   // eye at +z looks along -z
        CKGlassOut a = ck_canopyGlass(n, v, into, float3(3.0f), float3(0.3f), float3(0.2f), 0.0f, float3{0, 0.5f, 0.5f}, float3{0, 0.5f, 0.5f}, p, 0.0004f, 1.0f, 0.0f, 0.005f);
        CKGlassOut c = ck_canopyGlass(n, v, off, float3(3.0f), float3(0.3f), float3(0.2f), 0.0f, float3{0, 0.5f, 0.5f}, float3{0, 0.5f, 0.5f}, p, 0.0004f, 1.0f, 0.0f, 0.005f);
        check(a.rgb.x > 1.5f * c.rgb.x, "dust flares when looking toward the sun", a.rgb.x / c.rgb.x, 1.5);
    }
    printf(ok ? "ALL PASS\n" : "FAILURES\n");
    return ok ? 0 : 1;
}
