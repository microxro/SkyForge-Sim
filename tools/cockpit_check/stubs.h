// Mirrors of the WorldShaders symbols the glue part uses (signatures copied from WorldShaders.swift).
struct WorldUniforms { float4x4 model; float4 sunDir, sunColour, ambientSky, ambientGround, skyHorizon, skyZenith, quality; };
struct WorldVarying { float4 position; float3 rel; float3 normal; float3 albedo; float material; float field; float3 local; float2 uv; float4 style; };
struct Skin { float3 albedo; float glass; float matte; float3 emissive; };
static Skin fuselageSkin(float3 L, float fp) { Skin s; s.albedo=float3(1.0); s.glass=1.0; s.matte=0.0; s.emissive=float3(0.0); return s; }
static float shadowVisibility(constant WorldUniforms& u, depth2d_array<float> sm, float3 rel, float3 n, float dist, float ndl) { return 1.0; }
static float3 skyEnv(constant WorldUniforms& u, float3 r) { return u.skyZenith.xyz; }
static float3 pbrDielectric(float3 albedo, float3 n, float3 v, float3 l, float rough, float3 sun, float3 env, float vis) { return albedo; }
