#version 460 core
#include <flutter/runtime_effect.glsl>

precision highp float;

// ImageFilter.shader 约定:第一个 vec2 uniform 由引擎填入绑定纹理
// 尺寸(物理像素);第一个 sampler 由引擎绑定 filter 输入。
//
// 单 pass 变力模糊。⚠️ 不要改成 ImageFilter.compose 两 pass:
// 第二个 pass 的输入是第一 pass 的输出纹理,其尺寸/原点/outset 与
// 原 backdrop 不一致(无文档约定),t 的坐标基准会错位 —— 实测
// 表现为"顶部裸透、中段更糊、底边硬切"。重影伪影由每像素随机
// 旋转采样盘解决,不靠可分离两 pass。

uniform vec2 u_size;
// 滤镜区域高度(物理像素)。⚠️ 不能用 u_size 做纵向归一:u_size 是
// filter 输入纹理尺寸,可能是**全屏**而非裁剪区。
uniform float u_region_h;
// 顶部最大模糊 sigma(物理像素,Dart 侧 = 逻辑值 × devicePixelRatio)
uniform float u_max_sigma;
// 消散曲线指数:sigma = max_sigma * pow(t, curve),越大越集中在顶部
uniform float u_curve;
// 色罩:rgb = surface 色,a = 顶部最大 alpha。
// smoothstep 全程 C1 连续,无折线渐变的马赫带折痕。
uniform vec4 u_tint;

uniform sampler2D u_texture;

out vec4 frag_color;

// vogel 盘采样:黄金角螺旋均匀铺盘
const float TAPS = 48.0;
const float GOLDEN_ANGLE = 2.39996323;
// 色罩平台区:顶部 (1-TINT_KNEE) 比例保持满 alpha,其下 smoothstep 滑到 0
const float TINT_KNEE = 0.75;

// interleaved gradient noise:每像素伪随机 —— 用于旋转采样盘,把
// 固定盘的规律性重影/带状伪影打散成细颗粒噪(雾面观感,罩下不可见)
float ign(vec2 p) {
  return fract(52.9829189 * fract(dot(p, vec2(0.06711056, 0.00583715))));
}

void main() {
  vec2 frag = FlutterFragCoord().xy;

  // FlutterFragCoord 返回几何坐标，所有 Impeller 后端均以顶部为原点。
  // 不要按 GLES 的 gl_FragCoord 再翻转，否则会导致底糊顶清。
  float yTop = frag.y;
  // 视觉纵向位置 t:1=区域顶部,0=区域底部(按滤镜区域高度归一,
  // 与输入纹理尺寸无关)—— 模糊与色罩都随之连续变化
  float t = clamp(1.0 - yTop / u_region_h, 0.0, 1.0);
  float sigma = u_max_sigma * pow(t, u_curve);

  vec2 suv = frag / u_size;
  // GLES 纹理 y 轴反转(采样坐标)
// Flutter 3.47 起 GLES 渲染目标与 Metal/Vulkan 一样自顶向下。
// 仅为旧 SDK 保留翻转，不能影响新 SDK 的采样方向。
#if defined(IMPELLER_TARGET_OPENGLES) && !defined(IMPELLER_OPENGLES_UNFLIPPED_DEPRECATED)
  suv.y = 1.0 - suv.y;
#endif

  vec4 color;
  if (sigma < 0.3) {
    color = texture(u_texture, suv);
  } else {
    float radius = sigma * 2.5;
    vec2 texel = vec2(radius) / u_size;
    float rot = ign(frag) * 6.2831853;
    vec4 acc = vec4(0.0);
    float wsum = 0.0;
    for (float i = 0.0; i < TAPS; i++) {
      float r = sqrt((i + 0.5) / TAPS);
      float a = i * GOLDEN_ANGLE + rot;
      vec2 p = vec2(cos(a), sin(a)) * r;
      float d = r * radius;
      float w = exp(-(d * d) / (2.0 * sigma * sigma));
      acc += texture(u_texture, suv + p * texel) * w;
      wsum += w;
    }
    color = acc / wsum;
  }

  // 色罩:两端导数为零的 S 曲线,顶部平台托状态栏/标题文字对比
  float tintA = u_tint.a * smoothstep(0.0, TINT_KNEE, t);
  frag_color = mix(color, vec4(u_tint.rgb, 1.0), tintA);
}
