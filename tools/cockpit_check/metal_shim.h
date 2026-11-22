// Minimal host-side stand-in for the parts of Metal Shading Language used by CockpitMaterialShaders.
#pragma once
#include <cmath>
#include <cstdint>
#include <algorithm>
typedef unsigned int uint;
#define constant const
#define thread
#define device
#define fragment
#define vertex
typedef float float2 __attribute__((ext_vector_type(2)));
typedef float float3 __attribute__((ext_vector_type(3)));
typedef float float4 __attribute__((ext_vector_type(4)));
typedef int int2 __attribute__((ext_vector_type(2)));
// constructors (MSL spells them float3(...); function-like macros only fire on call syntax)
inline float2 CK2(float a){return float2{a,a};} inline float2 CK2(float a,float b){return float2{a,b};} inline float2 CK2(float2 a){return a;}
inline float2 CK2(int2 a){return float2{(float)a.x,(float)a.y};}
inline float3 CK3(float a){return float3{a,a,a};} inline float3 CK3(float a,float b,float c){return float3{a,b,c};}
inline float3 CK3(float2 a,float c){return float3{a.x,a.y,c};} inline float3 CK3(float a,float2 b){return float3{a,b.x,b.y};} inline float3 CK3(float3 a){return a;}
inline float4 CK4(float a){return float4{a,a,a,a};} inline float4 CK4(float a,float b,float c,float d){return float4{a,b,c,d};}
inline float4 CK4(float3 a,float d){return float4{a.x,a.y,a.z,d};}
inline int2 CKI2(int a,int b){return int2{a,b};} inline int2 CKI2(float2 a){return int2{(int)a.x,(int)a.y};} inline int2 CKI2(int2 a){return a;}
#define float2(...) CK2(__VA_ARGS__)
#define float3(...) CK3(__VA_ARGS__)
#define float4(...) CK4(__VA_ARGS__)
#define int2(...) CKI2(__VA_ARGS__)
template<class T> inline T saturate(T x){ return x<0?(T)0:(x>1?(T)1:x); }
#define VEC1(f,b) inline float f(float x){return b(x);} inline float2 f(float2 x){return float2{b(x.x),b(x.y)};} inline float3 f(float3 x){return float3{b(x.x),b(x.y),b(x.z)};}
VEC1(floor,::floorf) VEC1(sqrt,::sqrtf) VEC1(sin,::sinf) VEC1(cos,::cosf) VEC1(abs,::fabsf) VEC1(exp,::expf)
inline float2 saturate(float2 x){return float2{saturate(x.x),saturate(x.y)};}
inline float3 saturate(float3 x){return float3{saturate(x.x),saturate(x.y),saturate(x.z)};}
inline float rsqrt(float x){return 1.0f/::sqrtf(x);}
inline float fract(float x){return x-::floorf(x);}
inline float2 fract(float2 x){return x-floor(x);} inline float3 fract(float3 x){return x-floor(x);}
inline float step(float e,float x){return x<e?0.f:1.f;}
inline float pow(float a,float b){return ::powf(a,b);}
inline float atan2(float y,float x){return ::atan2f(y,x);}
inline float max(float a,float b){return a>b?a:b;} inline float min(float a,float b){return a<b?a:b;}
inline float3 max(float3 a,float3 b){return float3{max(a.x,b.x),max(a.y,b.y),max(a.z,b.z)};}
inline float3 min(float3 a,float3 b){return float3{min(a.x,b.x),min(a.y,b.y),min(a.z,b.z)};}
inline float2 min(float2 a,float2 b){return float2{min(a.x,b.x),min(a.y,b.y)};}
inline float3 min(float3 a,float b){return min(a,float3(b));}
inline float3 max(float3 a,float b){return max(a,float3(b));}
inline float clamp(float x,float a,float b){return x<a?a:(x>b?b:x);}
inline float3 clamp(float3 x,float a,float b){return min(max(x,float3(a)),float3(b));}
inline float mix(float a,float b,float t){return a+(b-a)*t;}
inline float2 mix(float2 a,float2 b,float t){return a+(b-a)*t;}
inline float3 mix(float3 a,float3 b,float t){return a+(b-a)*t;} inline float3 mix(float3 a,float3 b,float3 t){return a+(b-a)*t;}
inline float smoothstep(float a,float b,float x){float t=saturate((x-a)/(b-a));return t*t*(3-2*t);}
inline float dot(float2 a,float2 b){return a.x*b.x+a.y*b.y;} inline float dot(float3 a,float3 b){return a.x*b.x+a.y*b.y+a.z*b.z;}
inline float length(float2 a){return ::sqrtf(dot(a,a));} inline float length(float3 a){return ::sqrtf(dot(a,a));}
inline float3 normalize(float3 a){return a/length(a);} inline float2 normalize(float2 a){return a/length(a);}
inline float3 cross(float3 a,float3 b){return float3{a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x};}
inline float3 reflect(float3 i,float3 n){return i-2*dot(n,i)*n;}
inline float fwidth(float x){return 1e-3f;} inline float3 fwidth(float3 x){return float3{1e-3f,1e-3f,1e-3f};}
struct float4x4 { float4 c[4]; float4& operator[](int i){return c[i];} const float4& operator[](int i) const {return c[i];} };
template<class T> struct depth2d_array{ float sample_compare(int,float2,uint,float)const{return 1;} };
struct sampler_stub{}; 
#define discard_fragment() return float4(0.0f)
typedef unsigned int uint2_ __attribute__((ext_vector_type(2)));
inline float4 CK4(float2 a,float c,float d){return float4{a.x,a.y,c,d};}
