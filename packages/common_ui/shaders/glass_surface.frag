#version 460 core
#include <flutter/runtime_effect.glsl>

precision highp float;

// 柔光玻璃材质的光学层:圆角矩形边缘折射 + 方向性边缘高光 + 色散 +
// 磨砂噪点。用于悬浮胶囊底栏、Sheet、Dialog 等半透表面。
//
// 原理:把表面当作一块有厚度的透镜。用圆角矩形 SDF 求出每个像素
// 到边缘的距离,距边缘越近则采样点沿法线向内偏移越多(圆形透镜
// 剖面,非线性)—— 这就是边缘把背景"吸"进来的观感来源。同一条
// 法线又用于:与光向取点积得到迎光/背光的边缘亮度差,以及让 R/B
// 通道反向微错位形成色散。
//
// 参考:https://github.com/AritxOnly/Hyper-PiliPlus
// (其圆角矩形 SDF 与圆形透镜思路源自 Kyant0/AndroidLiquidGlass, Apache-2.0)
//
// 主模糊由独立的外层 BackdropFilter 完成，同时建立局部背景纹理；
// 本 shader 在内层进行折射、边缘光和色散，compose 的 outer 仅做
// 极轻的后柔化。不能把主模糊与折射合并回同一条背景滤镜链。
//
// ⚠️ .frag 构建期编译打包,新增/修改后必须冷启动重建,热重载不生效。

// 引擎自动填入:绑定纹理尺寸(物理像素)
uniform vec2 u_size;

// 表面在局部背景纹理中的原点与尺寸(物理像素)。外层主模糊
// BackdropFilter 建立独立 pass 后传入零原点；只有 ClipRRect 不够。
// u_size 是引擎提供的实际采样纹理尺寸，不与形状尺寸混用。
uniform vec2 u_origin;
uniform vec2 u_rect;

// 圆角半径(物理像素)。胶囊传半高。
uniform float u_radius;

// 折射带宽度:自边缘向内多少像素参与透镜弯曲
uniform float u_refract_h;
// 折射强度:边缘处最大采样偏移量(物理像素)
uniform float u_refract_amt;
// 深度感 0-1:法线向径向偏转的比例,越大越像"厚玻璃"
uniform float u_depth;
// 色散:R/B 通道错开的像素数
uniform float u_chroma;
// 边缘高光 alpha 与灰度(1=白边,0=黑边)
uniform float u_hl_alpha;
uniform float u_hl_gray;
// 磨砂噪点强度。量级在 0.1 左右(远高于常见的 0.01 级去带噪):
// 它是磨砂质感本身的来源,不是修饰。调小会直接失去“柔”的观感。
uniform float u_noise;

// 色彩处理:半透表面不只是模糊,还会轻微提升饱和度——
// 缺了这一步背景透过来会发灏。
uniform float u_saturation;
uniform float u_brightness;
uniform float u_contrast;

uniform sampler2D u_texture;

out vec4 frag_color;

// 圆角矩形有符号距离场:内部为负,外部为正
float roundedRectSdf(vec2 coord, vec2 halfSize, float radius) {
  vec2 corner = abs(coord) - (halfSize - vec2(radius));
  float outside = length(max(corner, vec2(0.0))) - radius;
  float inside = min(max(corner.x, corner.y), 0.0);
  return outside + inside;
}

// SDF 梯度 ≈ 表面法线(指向外侧)
vec2 roundedRectGradient(vec2 coord, vec2 halfSize, float radius) {
  vec2 corner = abs(coord) - (halfSize - vec2(radius));
  if (corner.x >= 0.0 || corner.y >= 0.0) {
    return sign(coord) * normalize(max(corner, vec2(0.0)) + vec2(0.0001));
  }
  // 直边区:法线取轴向,哪条边更近就朝哪边
  float horizontal = step(corner.y, corner.x);
  return sign(coord) * vec2(horizontal, 1.0 - horizontal);
}

// 圆形透镜剖面:x=0(带内侧)无偏移,x=1(最边缘)偏移最大且导数陡增。
// 这条曲线是"玻璃感"的来源 —— 线性渐变会显得像塑料贴纸。
float circularLens(float x) {
  x = clamp(x, 0.0, 1.0);
  return 1.0 - sqrt(max(1.0 - x * x, 0.0));
}

float random(vec2 coord, float seed) {
  return fract(sin(dot(coord, vec2(6.9898 + seed, 78.233))) * (43734.5453 + seed));
}

// 饱和度/亮度/对比度。亮度系数用 BT.709(与项目内
// blur_config.saturationFilter 一致)。
vec3 applyColorControls(vec3 c) {
  float luma = dot(c, vec3(0.2126, 0.7152, 0.0722));
  c = mix(vec3(luma), c, u_saturation);
  c = (c - 0.5) * u_contrast + 0.5 + u_brightness;
  return clamp(c, 0.0, 1.0);
}

// 物理像素坐标 → 纹理采样 uv(含 GLES y 轴反转)
vec2 toUv(vec2 px) {
  vec2 uv = px / u_size;
#ifdef IMPELLER_TARGET_OPENGLES
  uv.y = 1.0 - uv.y;
#endif
  return uv;
}

void main() {
  // FlutterFragCoord 是几何坐标，不是 GLES 的 gl_FragCoord。
  // GLES 的纹理方向差异只在 toUv 中处理一次，否则两次翻转相互抵消。
  vec2 pos = FlutterFragCoord().xy;

  vec2 halfSize = u_rect * 0.5;
  // 只有形状计算使用局部坐标，采样始终留在输入纹理坐标系。
  vec2 localPos = pos - u_origin;
  vec2 centered = localPos - halfSize;

  float radius = clamp(u_radius, 0.0, min(halfSize.x, halfSize.y));
  float signedDistance = roundedRectSdf(centered, halfSize, radius);

  // 滤镜组合可能请求裁切外的像素。它们必须原样透传，不能被当作
  // 最大折射带，更不能被夹到胶囊边缘后横向或纵向复制。
  if (signedDistance > 0.0) {
    frag_color = texture(u_texture, toUv(pos));
    return;
  }

  // 距边缘的内向深度;带内侧 lensProgress→0,最边缘→1
  float innerDepth = max(-signedDistance, 0.0);
  float lensProgress = 1.0 - innerDepth / max(u_refract_h, 0.001);
  float lens = circularLens(lensProgress);

  // 法线 = SDF 梯度 + 径向分量。径向让平直长边也有轻微弯折,
  // 否则胶囊中段会是一条"没有厚度"的直线。
  // ⚠️ 正中心像素 centered==(0,0):径向除零会产生 NaN,而 NaN
  // 会穿过后面的 mix() 把该像素渲染成黑点。用长度阀值无分支地
  // 把径向分量淡出(中心处 lens 本来就为 0,不影响观感)。
  // 法线与距离场使用同一个圆角。放大半径会让非胶囊表面的光学转角
  // 提前进入直边区；厚度感由下面的径向分量提供，不改变轮廓半径。
  vec2 normal = roundedRectGradient(centered, halfSize, radius);
  float centerDist = length(centered);
  vec2 radial = centered / max(centerDist, 0.001);
  radial *= smoothstep(0.0, 1.0, centerDist);
  normal = normalize(normal + radial * u_depth + vec2(0.0001));

  // 折射位移在输入纹理坐标系中应用。只按纹理范围限幅，不能按
  // 玻璃矩形限幅，否则形状范围与纹理不一致时会重复采样同一行/列。
  // 输入范围由外层主模糊的局部背景层建立，不再假设输入是整屏。
  vec2 sampleMin = vec2(0.5);
  vec2 sampleMax = u_size - vec2(0.5);
  vec2 refracted = clamp(
    pos - normal * u_refract_amt * lens,
    sampleMin,
    sampleMax
  );

  vec4 color = texture(u_texture, toUv(refracted));

  // 色散:R/B 沿法线错开,只在边缘可见(乘了 lens)
  if (u_chroma > 0.001) {
    vec2 dispersion = normal * u_chroma * lens;
    vec4 redSample = texture(u_texture, toUv(clamp(refracted - dispersion, sampleMin, sampleMax)));
    vec4 blueSample = texture(u_texture, toUv(clamp(refracted + dispersion, sampleMin, sampleMax)));
    color.r = redSample.r;
    color.b = blueSample.b;
  }

  // 色彩处理在折射采样之后、边缘光之前。参考实现把 colorControls
  // 放在效果链最前(作用于未模糊的原图),但饱和度与模糊可交换
  // (都是逐通道线性运算),放这里可以复用已采样的像素不额外开销。
  color.rgb = applyColorControls(color.rgb);

  // 方向性边缘高光:假定光源在左上方。纯上下渐变描边是"平"的,
  // 而按法线与光向夹角取幂,左上边缘亮、右下边缘暗,才有立体感。
  //
  // ⚠️ 不能用 abs(dot(...)):绝对值会让背光面与迎光面一样亮
  // (上/下边缘高光会算出同一值),等于没有光源方向。改用
  // 单侧 max(dot,0):迎光的左上亮,背光的右下只剩保底值。
  float edgeWidth = max(1.0, u_refract_h * 0.12);
  float rim = 1.0 - smoothstep(0.0, edgeWidth, innerDepth);
  vec2 lightDirection = normalize(vec2(-0.58, -0.82));
  float directional = pow(max(dot(normal, lightDirection), 0.0), 3.0);
  // 0.22 保底:整条边都有基础亮度勾出轮廓,背光侧不至于消失
  float edgeLight = u_hl_alpha * rim * (0.22 + directional * 0.78);
  color.rgb = mix(color.rgb, vec3(u_hl_gray), edgeLight);

  // 去带噪:模糊后的大面积平缓渐变在 8bit 输出上会有色带,
  // 加极轻三通道独立噪声打散
  if (u_noise > 0.0) {
    color.r += (random(pos, 0.0) - 0.5) * u_noise;
    color.g += (random(pos, 1.0) - 0.5) * u_noise;
    color.b += (random(pos, 2.0) - 0.5) * u_noise;
  }

  frag_color = color;
}
