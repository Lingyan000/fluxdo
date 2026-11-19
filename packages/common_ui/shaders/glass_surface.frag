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
// 作为普通画笔 shader 绘制(不是背景滤镜),Skia 与 Impeller 都可用。
// 背景来自截取宿主(glass_capture.dart):玻璃背后的内容已按主模糊
// 缩小、模糊进一张截取图,这里只按映射取样,再做折射、边缘光和色散。
// 取样映射的做法改编自 prism_ui(chen08209/prism_ui, GPL-3.0)。
//
// ⚠️ .frag 构建期编译打包,新增/修改后必须冷启动重建,热重载不生效。

// 截取图尺寸(像素)
uniform vec2 u_size;
// FlutterFragCoord 到玻璃局部坐标(dp,自左上角)的换算:原点、每单位比例
uniform vec4 u_frame;
// 玻璃局部坐标到截取图像素的换算,同 u_frame
uniform vec4 u_sample;
// 允许取样的首末像素中心:截取图里并排放着其他玻璃的背景
uniform vec4 u_clamp;
// 设备像素比:形状与光学参数按物理像素计算
uniform float u_dpr;

// 表面尺寸(物理像素)
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

uniform float u_superellipse;
uniform float u_top_n;
uniform float u_top_join;
uniform vec2 u_top_center;
uniform float u_top_radius;
uniform float u_right_n;
uniform float u_right_join;
uniform vec2 u_right_center;
uniform float u_right_radius;

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

// Matches Flutter's two-octant rounded superellipse. The implicit gradient
// estimates distance near the boundary, where refraction is visible.
vec3 superellipseField(vec2 coord, vec2 halfSize, float radius) {
  if (radius < 0.001) {
    vec2 d = abs(coord) - halfSize;
    return d.x > d.y ? vec3(d.x, sign(coord.x), 0.0)
                     : vec3(d.y, 0.0, sign(coord.y));
  }
  vec2 p = abs(coord);
  vec2 outside = p - halfSize;
  if (max(outside.x, outside.y) > 0.0) {
    return outside.x > outside.y ? vec3(outside.x, sign(coord.x), 0.0)
                                 : vec3(outside.y, 0.0, sign(coord.y));
  }
  float c = halfSize.x - halfSize.y;
  bool top = p.y > p.x - c;
  vec2 q = top ? vec2(p.x, p.y + c) : vec2(p.y, p.x - c);
  float a = top ? halfSize.x : halfSize.y;
  float n = top ? u_top_n : u_right_n;
  float join = top ? u_top_join : u_right_join;
  vec2 center = top ? u_top_center : u_right_center;
  float arcRadius = top ? u_top_radius : u_right_radius;
  float distance;
  vec2 normal;
  if (q.x <= join) {
    vec2 unit = clamp(q / a, vec2(0.0), vec2(1.1));
    vec2 gradient = (n / a) * pow(unit, vec2(n - 1.0));
    float magnitude = max(length(gradient), 0.00001);
    distance = (pow(unit.x, n) + pow(unit.y, n) - 1.0) / magnitude;
    normal = gradient / magnitude;
  } else {
    vec2 delta = q - center;
    float lengthDelta = max(length(delta), 0.00001);
    distance = lengthDelta - arcRadius;
    normal = delta / lengthDelta;
  }
  return vec3(distance, (top ? normal : normal.yx) * sign(coord));
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

// 截取图像素 → 纹理采样 uv(含 GLES y 轴反转)
vec2 toUv(vec2 texel) {
  vec2 uv = texel / u_size;
// Flutter 3.47 起 GLES 渲染目标与 Metal/Vulkan 一样自顶向下。
// 截取图同样是离屏渲染目标，仅为旧 SDK 保留翻转。
#if defined(IMPELLER_TARGET_OPENGLES) && !defined(IMPELLER_OPENGLES_UNFLIPPED_DEPRECATED)
  uv.y = 1.0 - uv.y;
#endif
  return uv;
}

// 按玻璃局部物理像素取样截取图,钳在本玻璃的槽位内
vec4 sampleBackdrop(vec2 px) {
  vec2 texel = (px / u_dpr - u_sample.xy) / u_sample.zw;
  texel = clamp(texel, u_clamp.xy, min(u_clamp.zw, u_size - vec2(0.5)));
  return texture(u_texture, toUv(texel));
}

void main() {
  // FlutterFragCoord 是绘制坐标，不是 GLES 的 gl_FragCoord。
  // GLES 的纹理方向差异只在 toUv 中处理一次，否则两次翻转相互抵消。
  // pos 为玻璃局部物理像素坐标(自左上角)。
  vec2 pos = (u_frame.xy + FlutterFragCoord().xy * u_frame.zw) * u_dpr;

  vec2 halfSize = u_rect * 0.5;
  vec2 centered = pos - halfSize;

  float radius = clamp(u_radius, 0.0, min(halfSize.x, halfSize.y));
  vec3 field = u_superellipse > 0.5
      ? superellipseField(centered, halfSize, radius)
      : vec3(roundedRectSdf(centered, halfSize, radius),
             roundedRectGradient(centered, halfSize, radius));
  float signedDistance = field.x;

  // 滤镜组合可能请求裁切外的像素。它们必须原样透传，不能被当作
  // 最大折射带，更不能被夹到胶囊边缘后横向或纵向复制。
  if (signedDistance > 0.0) {
    frag_color = sampleBackdrop(pos);
  } else {
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
    vec2 normal = field.yz;
    float centerDist = length(centered);
    vec2 radial = centered / max(centerDist, 0.001);
    radial *= smoothstep(0.0, 1.0, centerDist);
    normal = normalize(normal + radial * u_depth + vec2(0.0001));

    // 折射位移不按玻璃矩形限幅，只在取样时钳在截取槽位内：槽位比
    // 玻璃多留出模糊与折射的余量，边缘取到的仍是真实背景。
    vec2 refracted = pos - normal * u_refract_amt * lens;

    vec4 color = sampleBackdrop(refracted);

    // 色散:R/B 沿法线错开,只在边缘可见(乘了 lens)
    if (u_chroma > 0.001) {
      vec2 dispersion = normal * u_chroma * lens;
      vec4 redSample = sampleBackdrop(refracted - dispersion);
      vec4 blueSample = sampleBackdrop(refracted + dispersion);
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
}
