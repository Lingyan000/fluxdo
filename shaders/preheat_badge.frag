#version 460 core

#include <flutter/runtime_effect.glsl>

precision highp float;

// 启动页状态角标的"衍生"效果,一次单向的液态分离:
// 1. 鼓出:液滴在圆体右下边缘成形,与圆体平滑并集,边缘鼓起
// 2. 拉出:液滴一路被拉到停靠位(先快后慢,不越位不回弹),沿运动方向
//    拉伸;同时染上状态色,液颈从圆体色过渡到状态色
// 3. 断开:到位时液颈断开,断口处的圆体鼓包顺势收回
// 反向播放即缩回圆体。只绘制圆体之外的液颈/鼓包与角标本身,logo 本体
// 由下层负责;停靠后角标与 logo 之间的缝由下层在 logo 上挖出(透明),
// 本 shader 不画任何描边。
//
// 材质保持扁平纯色:液态感只来自形变与运动。停稳后与静态扁平角标
// 逐像素一致(正圆、停靠位精确、无残余拉伸)。
//
// 坐标:以 logo 中心为原点、logo 边长为 1 的归一化空间,y 轴向下。
// 输出预乘 alpha,其余区域透明。
//
// ⚠️ .frag 构建期编译打包,新增/修改后必须冷启动重建,热重载不生效。

uniform vec2 uSize;        // 画布尺寸
uniform vec2 uCenter;      // logo 中心
uniform float uLogoPx;     // logo 边长
uniform float uBodyR;      // 圆体半径(归一化)
uniform float uBadge;      // 角标进度 0..1
uniform float uBadgeR;     // 角标半径(归一化)
uniform float uDock;       // 停靠位:角标中心距圆体边缘的外移量(归一化)
uniform vec4 uBody;        // 圆体颜色
uniform vec4 uBadgeColor;  // 角标状态色

out vec4 fragColor;

const vec2 DIR = vec2(0.70710678, 0.70710678);
// 液颈的平滑并集半径
const float NECK_K = 0.11;

// 平滑并集:x = 距离,y = a 的权重
vec2 smin(float a, float b, float k) {
  float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
  return vec2(mix(b, a, h) - k * h * (1.0 - h), h);
}

float cover(float d, float aa) { return clamp(0.5 - d / aa, 0.0, 1.0); }

float easeOut(float t) { return 1.0 - (1.0 - t) * (1.0 - t) * (1.0 - t); }

vec4 over(vec4 dst, vec3 c, float a) { return vec4(c * a, a) + dst * (1.0 - a); }

// 液滴中心沿 45° 方向距圆体边缘的外移量:单调到达停靠位
float dropOffset(float b) {
  return mix(-0.06, uDock, easeOut(smoothstep(0.05, 0.75, b)));
}

void main() {
  vec2 q = (FlutterFragCoord().xy - uCenter) / uLogoPx;
  float aa = 1.0 / uLogoPx;
  float b = uBadge;
  if (b <= 0.0) {
    fragColor = vec4(0.0);
    return;
  }

  // ---- 液滴:位置、大小、挤压拉伸
  float off = dropOffset(b);
  vec2 c = DIR * (uBodyR + off);
  float r = uBadgeR * easeOut(smoothstep(0.0, 0.5, b));
  // 沿运动方向拉伸、垂直方向收缩(面积守恒)
  float vel = (dropOffset(min(b + 0.01, 1.0)) - dropOffset(max(b - 0.01, 0.0))) / 0.02;
  // 到位后正圆
  float stretch = 1.0 + clamp(abs(vel) * 0.35, 0.0, 0.3) * (1.0 - smoothstep(0.75, 0.9, b));
  vec2 rel = q - c;
  vec2 local = vec2(dot(rel, DIR) / stretch, dot(rel, vec2(-DIR.y, DIR.x)) * sqrt(stretch));
  float dDrop = (length(local) - r) * min(stretch, 1.2);

  // ---- 圆体与断口鼓包:断开瞬间鼓包最大,随后单调收回
  float dBody = length(q) - uBodyR;
  float snapped = smoothstep(0.6, 0.78, b);
  float bump = snapped * (1.0 - smoothstep(0.78, 1.0, b));
  float dBump = length(q - DIR * (uBodyR - 0.01 + 0.03 * bump)) - 0.045 * bump;
  float dHost = bump > 0.0 ? smin(dBody, dBump, 0.04).x : dBody;

  // ---- 液颈:到位时断开
  float k = NECK_K * (1.0 - snapped);
  vec2 u = k > 0.0005 ? smin(dDrop, dHost, k) : vec2(min(dDrop, dHost), step(dDrop, dHost));
  float tint = smoothstep(0.05, 0.4, b);
  vec3 dropCol = mix(uBody.rgb, uBadgeColor.rgb, tint);
  // 液颈大半段已带状态色,拉丝过程看得清
  vec3 col3 = mix(uBody.rgb, dropCol, smoothstep(0.0, 0.6, u.y));

  vec4 col = vec4(0.0);
  // 圆体之内交给下层 logo;液滴本身覆盖在 logo 之上
  float outside = clamp(dBody / aa + 0.5, 0.0, 1.0);
  float inDrop = cover(dDrop, aa);
  float a = cover(u.x, aa) * max(outside, inDrop);

  // 液滴本身(含与圆体重叠的部分)一律用液滴色
  col = over(col, mix(col3, dropCol, inDrop), a);
  fragColor = col;
}
