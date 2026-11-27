#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#define FLUXDO_OCR_EXPORT __declspec(dllexport)
#else
#define FLUXDO_OCR_EXPORT __attribute__((visibility("default")))
#endif

static inline int32_t clamp_i32(int32_t v, int32_t lo, int32_t hi) {
  if (v < lo) return lo;
  if (v > hi) return hi;
  return v;
}

static inline void read_pixel_rgb(
    const uint8_t* p,
    int32_t channels,
    float* out_r,
    float* out_g,
    float* out_b
) {
  uint8_t r = p[0];
  uint8_t g = p[1];
  uint8_t b = p[2];
  if (channels == 4) {
    uint8_t a = p[3];
    if (a != 255) {
      uint32_t alpha = (uint32_t)a;
      uint32_t inv = 255u - alpha;
      r = (uint8_t)((r * alpha + 255u * inv + 127u) / 255u);
      g = (uint8_t)((g * alpha + 255u * inv + 127u) / 255u);
      b = (uint8_t)((b * alpha + 255u * inv + 127u) / 255u);
    }
  }
  *out_r = (float)r;
  *out_g = (float)g;
  *out_b = (float)b;
}

static void build_axis_map(
    int32_t src_len,
    int32_t dst_len,
    int32_t* idx0,
    int32_t* idx1,
    float* frac
) {
  if (dst_len <= 0 || src_len <= 0) return;
  if (src_len == dst_len) {
    for (int32_t i = 0; i < dst_len; i++) {
      idx0[i] = i;
      idx1[i] = i;
      frac[i] = 0.0f;
    }
    return;
  }
  const float scale = (float)src_len / (float)dst_len;
  const int32_t max_src = src_len - 1;
  for (int32_t i = 0; i < dst_len; i++) {
    float pos = ((float)i + 0.5f) * scale - 0.5f;
    if (pos < 0.0f) pos = 0.0f;
    if (pos > (float)max_src) pos = (float)max_src;
    int32_t i0 = (int32_t)floorf(pos);
    int32_t i1 = i0 < max_src ? i0 + 1 : max_src;
    idx0[i] = i0;
    idx1[i] = i1;
    frac[i] = pos - (float)i0;
  }
}

/// 融合检测切片裁剪 + 双线性缩放 + 内联白底 Alpha 合成 + BGR ImageNet 归一化，
/// 直接写入 LiteRT 的 NCHW float32 输入张量缓冲区。
FLUXDO_OCR_EXPORT int32_t fluxdo_ocr_prepare_det_nchw(
    const uint8_t* src,
    int32_t src_w,
    int32_t src_h,
    int32_t channels,
    int32_t crop_y,
    int32_t crop_h,
    int32_t dst_w,
    int32_t dst_h,
    float* dst_nchw
) {
  if (!src || !dst_nchw || src_w <= 0 || src_h <= 0 || dst_w <= 0 ||
      dst_h <= 0 || (channels != 3 && channels != 4)) {
    return -1;
  }
  crop_y = clamp_i32(crop_y, 0, src_h - 1);
  if (crop_h <= 0) return -1;
  if (crop_y + crop_h > src_h) crop_h = src_h - crop_y;

  int32_t* x0 = (int32_t*)malloc((size_t)dst_w * sizeof(int32_t));
  int32_t* x1 = (int32_t*)malloc((size_t)dst_w * sizeof(int32_t));
  float* wx = (float*)malloc((size_t)dst_w * sizeof(float));
  if (!x0 || !x1 || !wx) {
    free(x0);
    free(x1);
    free(wx);
    return -2;
  }
  build_axis_map(src_w, dst_w, x0, x1, wx);

  const int32_t plane = dst_w * dst_h;
  float* dst_b = dst_nchw;
  float* dst_g = dst_nchw + plane;
  float* dst_r = dst_nchw + plane * 2;
  const int32_t row_stride = src_w * channels;

  // BGR ImageNet 归一化线性化系数: (v / 255 - mean) / std = v * scale + bias
  const float scale_b = 1.0f / (255.0f * 0.229f);
  const float bias_b = -0.485f / 0.229f;
  const float scale_g = 1.0f / (255.0f * 0.224f);
  const float bias_g = -0.456f / 0.224f;
  const float scale_r = 1.0f / (255.0f * 0.225f);
  const float bias_r = -0.406f / 0.225f;

  const float y_scale = (float)crop_h / (float)dst_h;
  const int32_t max_y = crop_h - 1;

  for (int32_t y = 0; y < dst_h; y++) {
    float sy = (crop_h == dst_h) ? (float)y : (((float)y + 0.5f) * y_scale - 0.5f);
    if (sy < 0.0f) sy = 0.0f;
    if (sy > (float)max_y) sy = (float)max_y;
    const int32_t y0 = (int32_t)floorf(sy);
    const int32_t y1 = y0 < max_y ? y0 + 1 : max_y;
    const float wy = sy - (float)y0;
    const float inv_wy = 1.0f - wy;

    const uint8_t* row0 = src + (size_t)(crop_y + y0) * (size_t)row_stride;
    const uint8_t* row1 = src + (size_t)(crop_y + y1) * (size_t)row_stride;
    const int32_t dst_row = y * dst_w;

    for (int32_t x = 0; x < dst_w; x++) {
      const float fx = wx[x];
      const float inv_fx = 1.0f - fx;
      const int32_t ox0 = x0[x] * channels;
      const int32_t ox1 = x1[x] * channels;

      float r00, g00, b00, r01, g01, b01, r10, g10, b10, r11, g11, b11;
      read_pixel_rgb(row0 + ox0, channels, &r00, &g00, &b00);
      read_pixel_rgb(row0 + ox1, channels, &r01, &g01, &b01);
      read_pixel_rgb(row1 + ox0, channels, &r10, &g10, &b10);
      read_pixel_rgb(row1 + ox1, channels, &r11, &g11, &b11);

      const float w00 = inv_wy * inv_fx;
      const float w01 = inv_wy * fx;
      const float w10 = wy * inv_fx;
      const float w11 = wy * fx;

      const float r = r00 * w00 + r01 * w01 + r10 * w10 + r11 * w11;
      const float g = g00 * w00 + g01 * w01 + g10 * w10 + g11 * w11;
      const float b = b00 * w00 + b01 * w01 + b10 * w10 + b11 * w11;

      const int32_t pos = dst_row + x;
      dst_b[pos] = b * scale_b + bias_b;
      dst_g[pos] = g * scale_g + bias_g;
      dst_r[pos] = r * scale_r + bias_r;
    }
  }

  free(x0);
  free(x1);
  free(wx);
  return 0;
}

/// 融合识别文本行裁剪 + 双线性缩放 + 内联白底 Alpha 合成 + [-1, 1] BGR 归一化 +
/// 桶宽右侧零填充，直接写入 LiteRT 的 NCHW float32 输入张量缓冲区。
FLUXDO_OCR_EXPORT int32_t fluxdo_ocr_prepare_rec_nchw(
    const uint8_t* src,
    int32_t src_w,
    int32_t src_h,
    int32_t channels,
    int32_t crop_x,
    int32_t crop_y,
    int32_t crop_w,
    int32_t crop_h,
    int32_t resized_w,
    int32_t bucket_w,
    int32_t dst_h,
    float* dst_nchw
) {
  if (!src || !dst_nchw || src_w <= 0 || src_h <= 0 || crop_w <= 0 ||
      crop_h <= 0 || resized_w <= 0 || bucket_w < resized_w || dst_h <= 0 ||
      (channels != 3 && channels != 4)) {
    return -1;
  }
  crop_x = clamp_i32(crop_x, 0, src_w - 1);
  crop_y = clamp_i32(crop_y, 0, src_h - 1);
  if (crop_x + crop_w > src_w) crop_w = src_w - crop_x;
  if (crop_y + crop_h > src_h) crop_h = src_h - crop_y;
  if (crop_w <= 0 || crop_h <= 0) return -1;

  int32_t* x0 = (int32_t*)malloc((size_t)resized_w * sizeof(int32_t));
  int32_t* x1 = (int32_t*)malloc((size_t)resized_w * sizeof(int32_t));
  float* wx = (float*)malloc((size_t)resized_w * sizeof(float));
  if (!x0 || !x1 || !wx) {
    free(x0);
    free(x1);
    free(wx);
    return -2;
  }
  build_axis_map(crop_w, resized_w, x0, x1, wx);

  const int32_t plane = bucket_w * dst_h;
  float* dst_b = dst_nchw;
  float* dst_g = dst_nchw + plane;
  float* dst_r = dst_nchw + plane * 2;
  const int32_t row_stride = src_w * channels;

  const float scale = 1.0f / 127.5f;
  const float y_scale = (float)crop_h / (float)dst_h;
  const int32_t max_y = crop_h - 1;
  const int32_t pad_w = bucket_w - resized_w;

  for (int32_t y = 0; y < dst_h; y++) {
    float sy = (crop_h == dst_h) ? (float)y : (((float)y + 0.5f) * y_scale - 0.5f);
    if (sy < 0.0f) sy = 0.0f;
    if (sy > (float)max_y) sy = (float)max_y;
    const int32_t y0 = (int32_t)floorf(sy);
    const int32_t y1 = y0 < max_y ? y0 + 1 : max_y;
    const float wy = sy - (float)y0;
    const float inv_wy = 1.0f - wy;

    const uint8_t* row0 = src + (size_t)(crop_y + y0) * (size_t)row_stride;
    const uint8_t* row1 = src + (size_t)(crop_y + y1) * (size_t)row_stride;
    const int32_t dst_row = y * bucket_w;

    for (int32_t x = 0; x < resized_w; x++) {
      const float fx = wx[x];
      const float inv_fx = 1.0f - fx;
      const int32_t ox0 = (crop_x + x0[x]) * channels;
      const int32_t ox1 = (crop_x + x1[x]) * channels;

      float r00, g00, b00, r01, g01, b01, r10, g10, b10, r11, g11, b11;
      read_pixel_rgb(row0 + ox0, channels, &r00, &g00, &b00);
      read_pixel_rgb(row0 + ox1, channels, &r01, &g01, &b01);
      read_pixel_rgb(row1 + ox0, channels, &r10, &g10, &b10);
      read_pixel_rgb(row1 + ox1, channels, &r11, &g11, &b11);

      const float w00 = inv_wy * inv_fx;
      const float w01 = inv_wy * fx;
      const float w10 = wy * inv_fx;
      const float w11 = wy * fx;

      const float r = r00 * w00 + r01 * w01 + r10 * w10 + r11 * w11;
      const float g = g00 * w00 + g01 * w01 + g10 * w10 + g11 * w11;
      const float b = b00 * w00 + b01 * w01 + b10 * w10 + b11 * w11;

      const int32_t pos = dst_row + x;
      dst_b[pos] = b * scale - 1.0f;
      dst_g[pos] = g * scale - 1.0f;
      dst_r[pos] = r * scale - 1.0f;
    }

    if (pad_w > 0) {
      const size_t pad_bytes = (size_t)pad_w * sizeof(float);
      memset(dst_b + dst_row + resized_w, 0, pad_bytes);
      memset(dst_g + dst_row + resized_w, 0, pad_bytes);
      memset(dst_r + dst_row + resized_w, 0, pad_bytes);
    }
  }

  free(x0);
  free(x1);
  free(wx);
  return 0;
}

/// 对 DBNet 概率图执行水平扫描线连通域搜索并应用官方扩边公式，直接输出包围盒列表。
FLUXDO_OCR_EXPORT int32_t fluxdo_ocr_extract_det_boxes(
    const float* scores,
    int32_t width,
    int32_t height,
    float threshold,
    float min_score,
    float unclip_ratio,
    float* out_boxes,
    int32_t max_boxes
) {
  if (!scores || !out_boxes || width <= 0 || height <= 0 || max_boxes <= 0) {
    return 0;
  }
  const int64_t total64 = (int64_t)width * (int64_t)height;
  if (total64 <= 0 || total64 > INT32_MAX) return 0;
  const int32_t total = (int32_t)total64;

  uint8_t* visited = (uint8_t*)calloc((size_t)total, 1);
  int32_t* stack = (int32_t*)malloc((size_t)total * sizeof(int32_t));
  if (!visited || !stack) {
    free(visited);
    free(stack);
    return -1;
  }

  int32_t box_count = 0;
  for (int32_t seed = 0; seed < total; seed++) {
    if (visited[seed] || scores[seed] <= threshold) continue;

    int32_t left = width;
    int32_t right = 0;
    int32_t top = height;
    int32_t bottom = 0;
    double sum = 0.0;
    int32_t count = 0;

    int32_t sp = 0;
    stack[sp++] = seed;

    while (sp > 0) {
      const int32_t pos = stack[--sp];
      if (visited[pos] || scores[pos] <= threshold) continue;
      const int32_t y = pos / width;
      const int32_t row = y * width;
      int32_t x = pos - row;
      while (x > 0 && !visited[row + x - 1] && scores[row + x - 1] > threshold) {
        x--;
      }
      if (x < left) left = x;
      if (y < top) top = y;
      if (y + 1 > bottom) bottom = y + 1;

      int32_t above = 0;
      int32_t below = 0;
      while (x < width && !visited[row + x] && scores[row + x] > threshold) {
        const int32_t i = row + x;
        visited[i] = 1;
        sum += (double)scores[i];
        count++;

        const int32_t has_above =
            (y > 0 && !visited[i - width] && scores[i - width] > threshold) ? 1 : 0;
        const int32_t has_below =
            (y + 1 < height && !visited[i + width] && scores[i + width] > threshold) ? 1 : 0;
        if (has_above && !above && sp < total) stack[sp++] = i - width;
        if (has_below && !below && sp < total) stack[sp++] = i + width;
        above = has_above;
        below = has_below;
        x++;
      }
      if (x > right) right = x;
    }

    const int32_t w = right - left;
    const int32_t h = bottom - top;
    const int32_t min_dim = w < h ? w : h;
    if (min_dim < 3 || count == 0 || (sum / (double)count) < (double)min_score) {
      continue;
    }
    if (box_count < max_boxes) {
      const float pad = unclip_ratio * (float)w * (float)h / (2.0f * (float)(w + h));
      const int32_t base = box_count * 4;
      out_boxes[base] = (float)left - pad;
      out_boxes[base + 1] = (float)top - pad;
      out_boxes[base + 2] = (float)right + pad;
      out_boxes[base + 3] = (float)bottom + pad;
      box_count++;
    }
  }

  free(visited);
  free(stack);
  return box_count;
}

/// 原生 C CTC 贪心解码：直接扫描 LiteRT 输出张量（steps × classes），去重、去 blank 并按窗口过滤。
FLUXDO_OCR_EXPORT int32_t fluxdo_ocr_ctc_argmax(
    const float* scores,
    int32_t steps,
    int32_t classes,
    int32_t width,
    float from_px,
    float until_px,
    int32_t* out_labels,
    float* out_left_px,
    float* out_right_px,
    int32_t max_tokens
) {
  if (!scores || !out_labels || !out_left_px || !out_right_px ||
      steps <= 0 || classes <= 0 || width <= 0 || max_tokens <= 0) {
    return 0;
  }

  int32_t previous = 0;
  int32_t start = 0;
  int32_t count = 0;
  const float step_scale = (float)width / (float)steps;

  for (int32_t step = 0; step <= steps; step++) {
    int32_t label = 0;
    if (step < steps) {
      const float* row = scores + (size_t)step * (size_t)classes;
      float best = row[0];
      for (int32_t c = 1; c < classes; c++) {
        const float v = row[c];
        if (v > best) {
          best = v;
          label = c;
        }
      }
    }
    if (label == previous) continue;
    const float left_px = (float)start * step_scale;
    const float right_px = (float)step * step_scale;
    const float center = 0.5f * (left_px + right_px);
    if (previous != 0 && center >= from_px && center < until_px &&
        count < max_tokens) {
      out_labels[count] = previous;
      out_left_px[count] = left_px;
      out_right_px[count] = right_px;
      count++;
    }
    previous = label;
    start = step;
  }
  return count;
}
