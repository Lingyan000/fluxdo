/*
 * line2para 段落归并原生 C99 推理引擎（特征提取 + B-Scale GNN + Signed 解码）。
 *
 * 上游来源与致谢：
 * - 推理算法（特征提取、四层 B-Scale 图注意力网络、Signed 聚类解码与阅读顺序排序）
 *   移植自 mg-chao/simd-paddle-ocr-rs (src/paragraph/)，采用 Apache-2.0 许可证：
 *   https://github.com/mg-chao/simd-paddle-ocr-rs
 * - 配套模型 line2para_1_2-epoch12-signed-1.625.onnx 来自 mgchao/SnowShotOCR（Apache-2.0）：
 *   https://modelscope.cn/models/mgchao/SnowShotOCR
 */

#include <float.h>
#include <math.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#define FLUXDO_OCR_EXPORT __declspec(dllexport)
#else
#define FLUXDO_OCR_EXPORT __attribute__((visibility("default")))
#endif

/* ============================================================================
 * 常量与基础工具
 * ========================================================================== */

#define L2P_NODE_INPUT 3
#define L2P_EDGE_INPUT 26
#define L2P_NODE_WIDTH 96
#define L2P_EDGE_WIDTH 144
#define L2P_REL_WIDTH (2 * L2P_NODE_WIDTH + L2P_EDGE_WIDTH) /* 336 */
#define L2P_LAYERS 4
#define L2P_EPSILON 1e-5f

#define L2P_SIGNED_THRESHOLD 1.625f
#define L2P_SIGNED_VETO (-0.5f)
#define L2P_SIGNED_SUPPORT (-0.65f)
#define L2P_TOLERANCE 1e-6

#define L2P_MAX_LINES 4096
#define L2P_MAX_PAIRS 65536

#define L2P_STROKE_W 64
#define L2P_STROKE_H 32
#define L2P_STROKE_WINDOWS 3
#define L2P_STROKE_WINDOW (L2P_STROKE_W * L2P_STROKE_H)
#define L2P_STROKE_SAMPLES (L2P_STROKE_WINDOW * L2P_STROKE_WINDOWS)
#define L2P_COLOR_INTERIOR (32 * 8)
#define L2P_COLOR_SAMPLES (L2P_COLOR_INTERIOR + 4 * 16)

typedef struct {
  float p[4][2];
} L2PQuad;

typedef struct {
  int32_t a;
  int32_t b;
} L2PPair;

static inline float l2p_minf(float a, float b) { return a < b ? a : b; }
static inline float l2p_maxf(float a, float b) { return a > b ? a : b; }
static inline double l2p_mind(double a, double b) { return a < b ? a : b; }
static inline double l2p_maxd(double a, double b) { return a > b ? a : b; }

static inline float l2p_clampf(float v, float lo, float hi) {
  if (v < lo) return lo;
  if (v > hi) return hi;
  return v;
}

static inline int32_t l2p_round_ties_even_i32(float v) {
  float f = floorf(v);
  float diff = v - f;
  if (diff > 0.5f) return (int32_t)f + 1;
  if (diff < 0.5f) return (int32_t)f;
  int32_t fi = (int32_t)f;
  return (fi & 1) ? (fi + 1) : fi;
}

static inline int l2p_cmp_f64(double a, double b) {
  if (a < b) return -1;
  if (a > b) return 1;
  return 0;
}

static inline int l2p_cmp_f32(float a, float b) {
  if (a < b) return -1;
  if (a > b) return 1;
  return 0;
}

static int l2p_qsort_f64(const void* pa, const void* pb) {
  double a = *(const double*)pa;
  double b = *(const double*)pb;
  return (a > b) - (a < b);
}

static int l2p_qsort_u16(const void* pa, const void* pb) {
  uint16_t a = *(const uint16_t*)pa;
  uint16_t b = *(const uint16_t*)pb;
  return (int)a - (int)b;
}

static int l2p_qsort_i32(const void* pa, const void* pb) {
  int32_t a = *(const int32_t*)pa;
  int32_t b = *(const int32_t*)pb;
  return (a > b) - (a < b);
}

static int l2p_qsort_pair(const void* pa, const void* pb) {
  const L2PPair* a = (const L2PPair*)pa;
  const L2PPair* b = (const L2PPair*)pb;
  if (a->a != b->a) return (a->a > b->a) - (a->a < b->a);
  return (a->b > b->b) - (a->b < b->b);
}

static double l2p_median_f64(double* values, int32_t count, double fallback) {
  if (count <= 0) return fallback;
  qsort(values, (size_t)count, sizeof(double), l2p_qsort_f64);
  if ((count & 1) == 0) {
    return 0.5 * (values[count / 2 - 1] + values[count / 2]);
  }
  return values[count / 2];
}

static double l2p_lower_median_f64(double* values, int32_t count) {
  qsort(values, (size_t)count, sizeof(double), l2p_qsort_f64);
  return values[(count - 1) / 2];
}

/* ============================================================================
 * 权重结构体与 ONNX Protobuf 解析器
 * ========================================================================== */

typedef struct {
  int32_t input;
  int32_t output;
  float* weight; /* [output, input] */
  float* bias;   /* [output] 或 NULL */
} L2PLinear;

typedef struct {
  int32_t output;
  float* w_recv; /* [output, 96] */
  float* w_send; /* [output, 96] */
  float* w_edge; /* [output, 144] */
  float* bias;   /* [output] */
} L2PRelation;

typedef struct {
  int32_t width;
  float* weight;
  float* bias;
} L2PNorm;

typedef struct {
  L2PRelation edge_update_0;
  L2PLinear edge_update_2;
  L2PNorm edge_norm;
  L2PRelation attention_mixed;
  L2PLinear attention_final;
  L2PRelation message_0;
  L2PLinear message_2;
  L2PLinear update_0;
  L2PLinear update_2;
  L2PNorm node_norm;
} L2PLayer;

typedef struct {
  L2PLinear node[2];
  L2PLinear edge[2];
  L2PLayer layers[L2P_LAYERS];
  L2PRelation classifier_0;
  L2PLinear classifier_2;
} FluxdoLine2ParaModel;

static void l2p_free_linear(L2PLinear* l) {
  free(l->weight);
  free(l->bias);
  l->weight = NULL;
  l->bias = NULL;
}

static void l2p_free_relation(L2PRelation* r) {
  free(r->w_recv);
  free(r->w_send);
  free(r->w_edge);
  free(r->bias);
  r->w_recv = NULL;
  r->w_send = NULL;
  r->w_edge = NULL;
  r->bias = NULL;
}

static void l2p_free_norm(L2PNorm* n) {
  free(n->weight);
  free(n->bias);
  n->weight = NULL;
  n->bias = NULL;
}

static void l2p_free_model(FluxdoLine2ParaModel* m) {
  if (!m) return;
  l2p_free_linear(&m->node[0]);
  l2p_free_linear(&m->node[1]);
  l2p_free_linear(&m->edge[0]);
  l2p_free_linear(&m->edge[1]);
  for (int i = 0; i < L2P_LAYERS; i++) {
    l2p_free_relation(&m->layers[i].edge_update_0);
    l2p_free_linear(&m->layers[i].edge_update_2);
    l2p_free_norm(&m->layers[i].edge_norm);
    l2p_free_relation(&m->layers[i].attention_mixed);
    l2p_free_linear(&m->layers[i].attention_final);
    l2p_free_relation(&m->layers[i].message_0);
    l2p_free_linear(&m->layers[i].message_2);
    l2p_free_linear(&m->layers[i].update_0);
    l2p_free_linear(&m->layers[i].update_2);
    l2p_free_norm(&m->layers[i].node_norm);
  }
  l2p_free_relation(&m->classifier_0);
  l2p_free_linear(&m->classifier_2);
  free(m);
}

/* --- Protobuf 轻量读取器 --- */

typedef struct {
  const uint8_t* data;
  size_t pos;
  size_t end;
} PbSlice;

static bool pb_read_varint(PbSlice* s, uint64_t* out) {
  uint64_t val = 0;
  int shift = 0;
  while (s->pos < s->end && shift < 64) {
    uint8_t b = s->data[s->pos++];
    val |= (uint64_t)(b & 0x7Fu) << shift;
    if ((b & 0x80u) == 0) {
      *out = val;
      return true;
    }
    shift += 7;
  }
  return false;
}

static bool pb_read_tag(PbSlice* s, uint32_t* field, uint32_t* wire) {
  if (s->pos >= s->end) return false;
  uint64_t tag = 0;
  if (!pb_read_varint(s, &tag)) return false;
  *field = (uint32_t)(tag >> 3);
  *wire = (uint32_t)(tag & 7u);
  return true;
}

static bool pb_skip(PbSlice* s, uint32_t wire) {
  uint64_t tmp = 0;
  switch (wire) {
    case 0:
      return pb_read_varint(s, &tmp);
    case 1:
      if (s->end - s->pos < 8) return false;
      s->pos += 8;
      return true;
    case 2:
      if (!pb_read_varint(s, &tmp)) return false;
      if (tmp > s->end - s->pos) return false;
      s->pos += (size_t)tmp;
      return true;
    case 5:
      if (s->end - s->pos < 4) return false;
      s->pos += 4;
      return true;
    default:
      return false;
  }
}

static bool pb_read_bytes(PbSlice* s, PbSlice* out) {
  uint64_t len = 0;
  if (!pb_read_varint(s, &len)) return false;
  if (len > s->end - s->pos) return false;
  out->data = s->data + s->pos;
  out->pos = 0;
  out->end = (size_t)len;
  s->pos += (size_t)len;
  return true;
}

typedef struct {
  char* name;
  int64_t dims[4];
  int32_t ndims;
  int32_t data_type;
  float* values;
  size_t count;
} RawTensor;

typedef struct {
  RawTensor* items;
  int32_t count;
  int32_t cap;
  char* attn_weight_names[L2P_LAYERS];
} ParsedGraph;

static void parsed_graph_free(ParsedGraph* g) {
  for (int32_t i = 0; i < g->count; i++) {
    free(g->items[i].name);
    free(g->items[i].values);
  }
  free(g->items);
  for (int i = 0; i < L2P_LAYERS; i++) {
    free(g->attn_weight_names[i]);
  }
  memset(g, 0, sizeof(*g));
}

static char* l2p_strndup(const uint8_t* data, size_t len) {
  char* out = (char*)malloc(len + 1);
  if (!out) return NULL;
  if (len > 0) memcpy(out, data, len);
  out[len] = '\0';
  return out;
}

static bool parse_tensor_proto(PbSlice s, RawTensor* out) {
  memset(out, 0, sizeof(*out));
  const uint8_t* raw_ptr = NULL;
  size_t raw_len = 0;
  float* flt_buf = NULL;
  size_t flt_len = 0;
  size_t flt_cap = 0;

  uint32_t field = 0, wire = 0;
  while (s.pos < s.end) {
    if (!pb_read_tag(&s, &field, &wire)) goto fail;
    if (field == 1 && wire == 0) {
      uint64_t d = 0;
      if (!pb_read_varint(&s, &d)) goto fail;
      if (out->ndims < 4) out->dims[out->ndims++] = (int64_t)d;
    } else if (field == 1 && wire == 2) {
      PbSlice sub;
      if (!pb_read_bytes(&s, &sub)) goto fail;
      while (sub.pos < sub.end) {
        uint64_t d = 0;
        if (!pb_read_varint(&sub, &d)) goto fail;
        if (out->ndims < 4) out->dims[out->ndims++] = (int64_t)d;
      }
    } else if (field == 2 && wire == 0) {
      uint64_t dt = 0;
      if (!pb_read_varint(&s, &dt)) goto fail;
      out->data_type = (int32_t)dt;
    } else if (field == 4 && wire == 5) {
      if (s.end - s.pos < 4) goto fail;
      if (flt_len == flt_cap) {
        size_t next = flt_cap ? flt_cap * 2 : 64;
        float* grown = (float*)realloc(flt_buf, next * sizeof(float));
        if (!grown) goto fail;
        flt_buf = grown;
        flt_cap = next;
      }
      float v = 0.0f;
      memcpy(&v, s.data + s.pos, 4);
      s.pos += 4;
      flt_buf[flt_len++] = v;
    } else if (field == 4 && wire == 2) {
      PbSlice sub;
      if (!pb_read_bytes(&s, &sub)) goto fail;
      if ((sub.end & 3u) != 0) goto fail;
      size_t n = sub.end / 4;
      if (flt_len + n > flt_cap) {
        size_t next = flt_len + n;
        float* grown = (float*)realloc(flt_buf, next * sizeof(float));
        if (!grown) goto fail;
        flt_buf = grown;
        flt_cap = next;
      }
      memcpy(flt_buf + flt_len, sub.data, sub.end);
      flt_len += n;
    } else if (field == 8 && wire == 2) {
      PbSlice sub;
      if (!pb_read_bytes(&s, &sub)) goto fail;
      free(out->name);
      out->name = l2p_strndup(sub.data, sub.end);
      if (!out->name) goto fail;
    } else if (field == 9 && wire == 2) {
      PbSlice sub;
      if (!pb_read_bytes(&s, &sub)) goto fail;
      raw_ptr = sub.data;
      raw_len = sub.end;
    } else {
      if (!pb_skip(&s, wire)) goto fail;
    }
  }

  /* 只加载 FLOAT32 张量；其他类型（如顶层包装图中的 INT64 常量）忽略内容即可。 */
  if (out->data_type == 1) {
    if (raw_ptr != NULL && raw_len > 0) {
      if ((raw_len & 3u) != 0) goto fail;
      out->count = raw_len / 4;
      out->values = (float*)malloc(raw_len);
      if (!out->values) goto fail;
      memcpy(out->values, raw_ptr, raw_len);
      free(flt_buf);
      flt_buf = NULL;
    } else if (flt_buf != NULL && flt_len > 0) {
      out->values = flt_buf;
      out->count = flt_len;
      flt_buf = NULL;
    }
    for (size_t i = 0; i < out->count; i++) {
      if (!isfinite(out->values[i])) goto fail;
    }
  } else {
    free(flt_buf);
  }
  return true;

fail:
  free(flt_buf);
  free(out->name);
  free(out->values);
  memset(out, 0, sizeof(*out));
  return false;
}

static bool parse_graph_proto(PbSlice s, ParsedGraph* out, int depth);

static bool parse_node_proto(PbSlice s, ParsedGraph* out, int depth,
                             bool* found_sub) {
  char* op_type = NULL;
  char* node_name = NULL;
  char* input1 = NULL;
  int32_t input_count = 0;
  PbSlice subgraphs[4];
  int32_t sub_count = 0;

  uint32_t field = 0, wire = 0;
  while (s.pos < s.end) {
    if (!pb_read_tag(&s, &field, &wire)) goto fail;
    if (field == 1 && wire == 2) {
      PbSlice sub;
      if (!pb_read_bytes(&s, &sub)) goto fail;
      if (input_count == 1) {
        free(input1);
        input1 = l2p_strndup(sub.data, sub.end);
        if (!input1) goto fail;
      }
      input_count++;
    } else if (field == 3 && wire == 2) {
      PbSlice sub;
      if (!pb_read_bytes(&s, &sub)) goto fail;
      free(node_name);
      node_name = l2p_strndup(sub.data, sub.end);
      if (!node_name) goto fail;
    } else if (field == 4 && wire == 2) {
      PbSlice sub;
      if (!pb_read_bytes(&s, &sub)) goto fail;
      free(op_type);
      op_type = l2p_strndup(sub.data, sub.end);
      if (!op_type) goto fail;
    } else if (field == 5 && wire == 2) {
      /* AttributeProto：提取子图（field 6 = GraphProto g） */
      PbSlice attr;
      if (!pb_read_bytes(&s, &attr)) goto fail;
      uint32_t af = 0, aw = 0;
      while (attr.pos < attr.end) {
        if (!pb_read_tag(&attr, &af, &aw)) goto fail;
        if (af == 6 && aw == 2) {
          PbSlice gslice;
          if (!pb_read_bytes(&attr, &gslice)) goto fail;
          if (sub_count < 4) subgraphs[sub_count++] = gslice;
        } else {
          if (!pb_skip(&attr, aw)) goto fail;
        }
      }
    } else {
      if (!pb_skip(&s, wire)) goto fail;
    }
  }

  if (op_type && strcmp(op_type, "MatMul") == 0 && node_name && input1 &&
      input_count == 2) {
    for (int i = 0; i < L2P_LAYERS; i++) {
      char expected[48];
      expected[0] = '/';
      expected[1] = 'l';
      expected[2] = 'a';
      expected[3] = 'y';
      expected[4] = 'e';
      expected[5] = 'r';
      expected[6] = 's';
      expected[7] = '.';
      expected[8] = (char)('0' + i);
      memcpy(expected + 9, "/attention_final/MatMul", 24);
      if (strcmp(node_name, expected) == 0) {
        free(out->attn_weight_names[i]);
        out->attn_weight_names[i] = input1;
        input1 = NULL;
        break;
      }
    }
  }

  /* 紧凑导出模型把完整 B-Scale 图放在顶层 If 节点的 then_branch 子图中。 */
  if (depth < 4 && sub_count > 0) {
    for (int32_t i = 0; i < sub_count; i++) {
      ParsedGraph candidate;
      memset(&candidate, 0, sizeof(candidate));
      if (parse_graph_proto(subgraphs[i], &candidate, depth + 1)) {
        if (candidate.count == 88) {
          parsed_graph_free(out);
          *out = candidate;
          *found_sub = true;
          break;
        }
      }
      parsed_graph_free(&candidate);
    }
  }

  free(op_type);
  free(node_name);
  free(input1);
  return true;

fail:
  free(op_type);
  free(node_name);
  free(input1);
  return false;
}

static bool parse_graph_proto(PbSlice s, ParsedGraph* out, int depth) {
  uint32_t field = 0, wire = 0;
  bool found_sub = false;
  while (s.pos < s.end) {
    if (!pb_read_tag(&s, &field, &wire)) return false;
    if (field == 1 && wire == 2) {
      PbSlice node;
      if (!pb_read_bytes(&s, &node)) return false;
      if (!found_sub) {
        if (!parse_node_proto(node, out, depth, &found_sub)) return false;
      }
    } else if (field == 5 && wire == 2) {
      PbSlice tensor;
      if (!pb_read_bytes(&s, &tensor)) return false;
      if (!found_sub) {
        RawTensor rt;
        if (!parse_tensor_proto(tensor, &rt)) return false;
        if (out->count == out->cap) {
          int32_t next = out->cap ? out->cap * 2 : 96;
          RawTensor* grown =
              (RawTensor*)realloc(out->items, (size_t)next * sizeof(RawTensor));
          if (!grown) {
            free(rt.name);
            free(rt.values);
            return false;
          }
          out->items = grown;
          out->cap = next;
        }
        out->items[out->count++] = rt;
      }
    } else {
      if (!pb_skip(&s, wire)) return false;
    }
  }
  return true;
}

static float* take_tensor(ParsedGraph* g, const char* name, int32_t ndims,
                          int64_t d0, int64_t d1) {
  if (!name) return NULL;
  for (int32_t i = 0; i < g->count; i++) {
    RawTensor* t = &g->items[i];
    if (!t->name || !t->values) continue;
    if (strcmp(t->name, name) != 0) continue;
    if (t->data_type != 1 || t->ndims != ndims) return NULL;
    if (t->dims[0] != d0) return NULL;
    if (ndims == 2 && t->dims[1] != d1) return NULL;
    size_t expected = (size_t)d0 * (ndims == 2 ? (size_t)d1 : 1u);
    if (t->count != expected) return NULL;
    float* ptr = t->values;
    t->values = NULL;
    return ptr;
  }
  return NULL;
}

static bool load_linear(ParsedGraph* g, const char* prefix, int32_t input,
                        int32_t output, L2PLinear* dst) {
  char wname[96], bname[96];
  size_t plen = strlen(prefix);
  if (plen + 10 >= sizeof(wname)) return false;
  memcpy(wname, prefix, plen);
  memcpy(wname + plen, ".weight", 8);
  memcpy(bname, prefix, plen);
  memcpy(bname + plen, ".bias", 6);
  float* w = take_tensor(g, wname, 2, output, input);
  float* b = take_tensor(g, bname, 1, output, 0);
  if (!w || !b) {
    free(w);
    free(b);
    return false;
  }
  dst->input = input;
  dst->output = output;
  dst->weight = w;
  dst->bias = b;
  return true;
}

static bool load_relation(ParsedGraph* g, const char* prefix, int32_t output,
                          L2PRelation* dst) {
  L2PLinear tmp;
  memset(&tmp, 0, sizeof(tmp));
  if (!load_linear(g, prefix, L2P_REL_WIDTH, output, &tmp)) return false;

  float* wr = (float*)malloc((size_t)output * L2P_NODE_WIDTH * sizeof(float));
  float* ws = (float*)malloc((size_t)output * L2P_NODE_WIDTH * sizeof(float));
  float* we = (float*)malloc((size_t)output * L2P_EDGE_WIDTH * sizeof(float));
  if (!wr || !ws || !we) {
    free(wr);
    free(ws);
    free(we);
    l2p_free_linear(&tmp);
    return false;
  }
  for (int32_t o = 0; o < output; o++) {
    const float* row = tmp.weight + (size_t)o * L2P_REL_WIDTH;
    memcpy(wr + (size_t)o * L2P_NODE_WIDTH, row,
           L2P_NODE_WIDTH * sizeof(float));
    memcpy(ws + (size_t)o * L2P_NODE_WIDTH, row + L2P_NODE_WIDTH,
           L2P_NODE_WIDTH * sizeof(float));
    memcpy(we + (size_t)o * L2P_EDGE_WIDTH, row + 2 * L2P_NODE_WIDTH,
           L2P_EDGE_WIDTH * sizeof(float));
  }
  free(tmp.weight);
  dst->output = output;
  dst->w_recv = wr;
  dst->w_send = ws;
  dst->w_edge = we;
  dst->bias = tmp.bias;
  return true;
}

static bool load_norm(ParsedGraph* g, const char* prefix, int32_t width,
                      L2PNorm* dst) {
  char wname[96], bname[96];
  size_t plen = strlen(prefix);
  if (plen + 10 >= sizeof(wname)) return false;
  memcpy(wname, prefix, plen);
  memcpy(wname + plen, ".weight", 8);
  memcpy(bname, prefix, plen);
  memcpy(bname + plen, ".bias", 6);
  float* w = take_tensor(g, wname, 1, width, 0);
  float* b = take_tensor(g, bname, 1, width, 0);
  if (!w || !b) {
    free(w);
    free(b);
    return false;
  }
  dst->width = width;
  dst->weight = w;
  dst->bias = b;
  return true;
}

FLUXDO_OCR_EXPORT void* fluxdo_line2para_open(const uint8_t* onnx_bytes,
                                              int32_t byte_len) {
  if (!onnx_bytes || byte_len <= 0) return NULL;
  PbSlice root = {onnx_bytes, 0, (size_t)byte_len};
  PbSlice graph_slice = {NULL, 0, 0};
  bool has_graph = false;

  uint32_t field = 0, wire = 0;
  while (root.pos < root.end) {
    if (!pb_read_tag(&root, &field, &wire)) return NULL;
    if (field == 7 && wire == 2) {
      if (!pb_read_bytes(&root, &graph_slice)) return NULL;
      has_graph = true;
    } else {
      if (!pb_skip(&root, wire)) return NULL;
    }
  }
  if (!has_graph) return NULL;

  ParsedGraph pg;
  memset(&pg, 0, sizeof(pg));
  if (!parse_graph_proto(graph_slice, &pg, 0) || pg.count != 88) {
    parsed_graph_free(&pg);
    return NULL;
  }

  FluxdoLine2ParaModel* m =
      (FluxdoLine2ParaModel*)calloc(1, sizeof(FluxdoLine2ParaModel));
  if (!m) {
    parsed_graph_free(&pg);
    return NULL;
  }

  bool ok = load_linear(&pg, "node.0", L2P_NODE_INPUT, L2P_NODE_WIDTH,
                        &m->node[0]) &&
            load_linear(&pg, "node.2", L2P_NODE_WIDTH, L2P_NODE_WIDTH,
                        &m->node[1]) &&
            load_linear(&pg, "edge_encoder.0", L2P_EDGE_INPUT, L2P_EDGE_WIDTH,
                        &m->edge[0]) &&
            load_linear(&pg, "edge_encoder.2", L2P_EDGE_WIDTH, L2P_EDGE_WIDTH,
                        &m->edge[1]);

  for (int i = 0; ok && i < L2P_LAYERS; i++) {
    char p[64];
    L2PLayer* L = &m->layers[i];
    const char idx = (char)('0' + i);

    memcpy(p, "layers.0.edge_update.0", 23);
    p[7] = idx;
    ok = ok && load_relation(&pg, p, L2P_EDGE_WIDTH, &L->edge_update_0);

    memcpy(p, "layers.0.edge_update.2", 23);
    p[7] = idx;
    ok = ok && load_linear(&pg, p, L2P_EDGE_WIDTH, L2P_EDGE_WIDTH,
                           &L->edge_update_2);

    memcpy(p, "layers.0.edge_norm", 19);
    p[7] = idx;
    ok = ok && load_norm(&pg, p, L2P_EDGE_WIDTH, &L->edge_norm);

    memcpy(p, "layers.0.attention_mixed", 25);
    p[7] = idx;
    ok = ok && load_relation(&pg, p, L2P_NODE_WIDTH, &L->attention_mixed);

    float* aw = take_tensor(&pg, pg.attn_weight_names[i], 2, L2P_NODE_WIDTH, 1);
    if (!aw) {
      ok = false;
    } else {
      L->attention_final.input = L2P_NODE_WIDTH;
      L->attention_final.output = 1;
      L->attention_final.weight = aw;
      L->attention_final.bias = NULL;
    }

    memcpy(p, "layers.0.message.0", 19);
    p[7] = idx;
    ok = ok && load_relation(&pg, p, L2P_NODE_WIDTH, &L->message_0);

    memcpy(p, "layers.0.message.2", 19);
    p[7] = idx;
    ok = ok &&
         load_linear(&pg, p, L2P_NODE_WIDTH, L2P_NODE_WIDTH, &L->message_2);

    memcpy(p, "layers.0.update.0", 18);
    p[7] = idx;
    ok = ok && load_linear(&pg, p, 2 * L2P_NODE_WIDTH, L2P_NODE_WIDTH,
                           &L->update_0);

    memcpy(p, "layers.0.update.2", 18);
    p[7] = idx;
    ok = ok &&
         load_linear(&pg, p, L2P_NODE_WIDTH, L2P_NODE_WIDTH, &L->update_2);

    memcpy(p, "layers.0.node_norm", 19);
    p[7] = idx;
    ok = ok && load_norm(&pg, p, L2P_NODE_WIDTH, &L->node_norm);
  }

  ok = ok &&
       load_relation(&pg, "classifier.0", L2P_NODE_WIDTH, &m->classifier_0) &&
       load_linear(&pg, "classifier.2", L2P_NODE_WIDTH, 1, &m->classifier_2);

  parsed_graph_free(&pg);
  if (!ok) {
    l2p_free_model(m);
    return NULL;
  }
  return m;
}

FLUXDO_OCR_EXPORT void fluxdo_line2para_close(void* handle) {
  l2p_free_model((FluxdoLine2ParaModel*)handle);
}

/* ============================================================================
 * 几何预处理、方向判定与候选边构建（对应 features.rs）
 * ========================================================================== */

static float quad_twice_area_f32(const L2PQuad* q) {
  float s = 0.0f;
  for (int i = 0; i < 4; i++) {
    int j = (i + 1) & 3;
    s += q->p[i][0] * q->p[j][1] - q->p[i][1] * q->p[j][0];
  }
  return s;
}

static double quad_twice_area_f64(const double q[4][2]) {
  double s = 0.0;
  for (int i = 0; i < 4; i++) {
    int j = (i + 1) & 3;
    s += q[i][0] * q[j][1] - q[i][1] * q[j][0];
  }
  return s;
}

static void quad_bounds(const L2PQuad* q, float b[4]) {
  b[0] = b[2] = q->p[0][0];
  b[1] = b[3] = q->p[0][1];
  for (int i = 1; i < 4; i++) {
    b[0] = l2p_minf(b[0], q->p[i][0]);
    b[1] = l2p_minf(b[1], q->p[i][1]);
    b[2] = l2p_maxf(b[2], q->p[i][0]);
    b[3] = l2p_maxf(b[3], q->p[i][1]);
  }
}

static L2PQuad quad_canonical(L2PQuad q) {
  float cx = 0.25f * (q.p[0][0] + q.p[1][0] + q.p[2][0] + q.p[3][0]);
  float cy = 0.25f * (q.p[0][1] + q.p[1][1] + q.p[2][1] + q.p[3][1]);
  float ang[4];
  for (int i = 0; i < 4; i++) {
    ang[i] = atan2f(q.p[i][1] - cy, q.p[i][0] - cx);
  }
  /* 4 元素稳定插入排序 */
  for (int i = 1; i < 4; i++) {
    float key_a = ang[i];
    float kx = q.p[i][0], ky = q.p[i][1];
    int j = i - 1;
    while (j >= 0 && ang[j] > key_a) {
      ang[j + 1] = ang[j];
      q.p[j + 1][0] = q.p[j][0];
      q.p[j + 1][1] = q.p[j][1];
      j--;
    }
    ang[j + 1] = key_a;
    q.p[j + 1][0] = kx;
    q.p[j + 1][1] = ky;
  }
  int start = 0;
  for (int i = 1; i < 4; i++) {
    if (q.p[i][1] < q.p[start][1] ||
        (q.p[i][1] == q.p[start][1] && q.p[i][0] < q.p[start][0])) {
      start = i;
    }
  }
  L2PQuad out;
  for (int i = 0; i < 4; i++) {
    int src = (start + i) & 3;
    out.p[i][0] = q.p[src][0];
    out.p[i][1] = q.p[src][1];
  }
  return out;
}

static bool detect_directions(const L2PQuad* quads, int32_t n, uint8_t* vert) {
  int32_t* anchors = (int32_t*)malloc((size_t)n * sizeof(int32_t));
  if (!anchors) return false;
  int32_t anchor_count = 0;
  double strongest_ratio = -1.0;
  uint8_t strongest_dir = 0;

  for (int32_t i = 0; i < n; i++) {
    double sides[4][2];
    double lens[4];
    int major = 0;
    double shortest = DBL_MAX;
    for (int k = 0; k < 4; k++) {
      int kn = (k + 1) & 3;
      sides[k][0] = (double)quads[i].p[kn][0] - (double)quads[i].p[k][0];
      sides[k][1] = (double)quads[i].p[kn][1] - (double)quads[i].p[k][1];
      lens[k] = hypot(sides[k][0], sides[k][1]);
      if (lens[k] > lens[major]) major = k;
      if (lens[k] < shortest) shortest = lens[k];
    }
    double ratio = shortest > 1e-6 ? lens[major] / shortest : 0.0;
    uint8_t v = (ratio > 0.0 && fabs(sides[major][1]) > fabs(sides[major][0]))
                    ? 1u
                    : 0u;
    vert[i] = v;
    if (ratio >= 1.2) anchors[anchor_count++] = i;
    if (ratio > strongest_ratio) {
      strongest_ratio = ratio;
      strongest_dir = v;
    }
  }

  bool all_same = true;
  for (int32_t k = 0; k < anchor_count; k++) {
    if (vert[anchors[k]] != strongest_dir) {
      all_same = false;
      break;
    }
  }
  if (anchor_count == 0 || all_same) {
    memset(vert, strongest_dir, (size_t)n);
    free(anchors);
    return true;
  }

  double* corners = (double*)malloc((size_t)n * 2 * sizeof(double));
  uint8_t* assigned = (uint8_t*)calloc((size_t)n, 1);
  int32_t* child_head = (int32_t*)malloc((size_t)n * sizeof(int32_t));
  int32_t* child_next = (int32_t*)malloc((size_t)n * sizeof(int32_t));
  double* near_dist = (double*)malloc((size_t)n * sizeof(double));
  int32_t* near_par = (int32_t*)malloc((size_t)n * sizeof(int32_t));
  int32_t* queue = (int32_t*)malloc((size_t)n * sizeof(int32_t));
  if (!corners || !assigned || !child_head || !child_next || !near_dist ||
      !near_par || !queue) {
    free(anchors);
    free(corners);
    free(assigned);
    free(child_head);
    free(child_next);
    free(near_dist);
    free(near_par);
    free(queue);
    return false;
  }

  for (int32_t i = 0; i < n; i++) {
    float b[4];
    quad_bounds(&quads[i], b);
    corners[i * 2] = (double)b[0];
    corners[i * 2 + 1] = (double)b[1];
    child_head[i] = -1;
    child_next[i] = -1;
    near_dist[i] = INFINITY;
    near_par[i] = INT32_MAX;
  }
  for (int32_t k = 0; k < anchor_count; k++) assigned[anchors[k]] = 1;

  for (int32_t i = 0; i < n; i++) {
    if (assigned[i]) continue;
    int32_t best_p = -1;
    double best_d = INFINITY;
    for (int32_t j = 0; j < n; j++) {
      if (j == i) continue;
      double dx = corners[i * 2] - corners[j * 2];
      double dy = corners[i * 2 + 1] - corners[j * 2 + 1];
      double d = dx * dx + dy * dy;
      if (best_p < 0 || d < best_d) {
        best_d = d;
        best_p = j;
      }
    }
    if (best_p >= 0) {
      child_next[i] = child_head[best_p];
      child_head[best_p] = i;
    }
  }

  /* 辅助更新函数通过内联宏展开 */
#define L2P_UPDATE_NEAREST(src_idx)                                      \
  do {                                                                   \
    double sx = corners[(src_idx) * 2];                                  \
    double sy = corners[(src_idx) * 2 + 1];                              \
    for (int32_t u = 0; u < n; u++) {                                    \
      if (assigned[u]) continue;                                         \
      double dx = sx - corners[u * 2];                                   \
      double dy = sy - corners[u * 2 + 1];                               \
      double dist = dx * dx + dy * dy;                                   \
      double best = near_dist[u];                                        \
      bool tied = fabs(dist - best) * 1e12 <= l2p_mind(dist, best);      \
      if (dist < best || (tied && (src_idx) < near_par[u])) {            \
        near_dist[u] = dist;                                             \
        near_par[u] = (src_idx);                                         \
      }                                                                  \
    }                                                                    \
  } while (0)

#define L2P_ADOPT(src_idx)                   \
  do {                                       \
    int32_t qh = 0, qt = 0;                  \
    queue[qt++] = (src_idx);                 \
    while (qh < qt) {                        \
      int32_t par = queue[qh++];             \
      for (int32_t c = child_head[par]; c >= 0; c = child_next[c]) { \
        if (!assigned[c]) {                  \
          vert[c] = vert[par];               \
          assigned[c] = 1;                   \
          L2P_UPDATE_NEAREST(c);             \
          queue[qt++] = c;                   \
        }                                    \
      }                                      \
    }                                        \
  } while (0)

  for (int32_t k = 0; k < anchor_count; k++) {
    L2P_UPDATE_NEAREST(anchors[k]);
  }
  for (int32_t k = 0; k < anchor_count; k++) {
    L2P_ADOPT(anchors[k]);
  }
  for (;;) {
    int32_t pick = -1;
    double best = INFINITY;
    for (int32_t i = 0; i < n; i++) {
      if (assigned[i]) continue;
      if (pick < 0 || near_dist[i] < best) {
        best = near_dist[i];
        pick = i;
      }
    }
    if (pick < 0) break;
    vert[pick] = vert[near_par[pick]];
    assigned[pick] = 1;
    L2P_UPDATE_NEAREST(pick);
    L2P_ADOPT(pick);
  }

#undef L2P_UPDATE_NEAREST
#undef L2P_ADOPT

  free(anchors);
  free(corners);
  free(assigned);
  free(child_head);
  free(child_next);
  free(near_dist);
  free(near_par);
  free(queue);
  return true;
}

static void aligned_frame(const L2PQuad* quads, const int32_t* indices,
                          const uint8_t* valid, int32_t count, bool vertical,
                          float (*out_bounds)[4]) {
  float ax = 0.0f, ay = 0.0f;
  for (int32_t idx = 0; idx < count; idx++) {
    if (valid && !valid[idx]) continue;
    const L2PQuad* q = &quads[indices[idx]];
    float pts[4][2];
    for (int k = 0; k < 4; k++) {
      pts[k][0] = vertical ? q->p[k][1] : q->p[k][0];
      pts[k][1] = vertical ? q->p[k][0] : q->p[k][1];
    }
    float sides[4][2], lens[4];
    int major = 0;
    float shortest = FLT_MAX;
    for (int k = 0; k < 4; k++) {
      int kn = (k + 1) & 3;
      sides[k][0] = pts[kn][0] - pts[k][0];
      sides[k][1] = pts[kn][1] - pts[k][1];
      lens[k] = sqrtf(sides[k][0] * sides[k][0] + sides[k][1] * sides[k][1]);
      if (lens[k] > lens[major]) major = k;
      if (lens[k] < shortest) shortest = lens[k];
    }
    float sx = sides[major][0];
    float sy = sides[major][1];
    if (sx < 0.0f) {
      sx = -sx;
      sy = -sy;
    }
    if (lens[major] >= 1.2f * shortest && fabsf(sx) >= fabsf(sy)) {
      ax += sx;
      ay += sy;
    }
  }
  float norm = sqrtf(ax * ax + ay * ay);
  float c = norm > 1e-6f ? ax / norm : 1.0f;
  float s = norm > 1e-6f ? ay / norm : 0.0f;
  for (int32_t idx = 0; idx < count; idx++) {
    const L2PQuad* q = &quads[indices[idx]];
    float l = FLT_MAX, t = FLT_MAX, r = -FLT_MAX, b = -FLT_MAX;
    for (int k = 0; k < 4; k++) {
      float ox = vertical ? q->p[k][1] : q->p[k][0];
      float oy = vertical ? q->p[k][0] : q->p[k][1];
      float rx = ox * c + oy * s;
      float ry = -ox * s + oy * c;
      l = l2p_minf(l, rx);
      t = l2p_minf(t, ry);
      r = l2p_maxf(r, rx);
      b = l2p_maxf(b, ry);
    }
    out_bounds[idx][0] = l;
    out_bounds[idx][1] = t;
    out_bounds[idx][2] = r;
    out_bounds[idx][3] = b;
  }
}

typedef struct {
  float metric;
  int32_t index;
} L2PNeighbor;

static void nominate(L2PNeighbor* best, int k, float metric, int32_t index) {
  for (int pos = 0; pos < k; pos++) {
    if (metric < best[pos].metric) {
      for (int m = k - 1; m > pos; m--) best[m] = best[m - 1];
      best[pos].metric = metric;
      best[pos].index = index;
      return;
    }
  }
}

typedef struct {
  float cy;
  float cx;
  int32_t idx;
} L2PRankKey;

static int cmp_rank_key(const void* pa, const void* pb) {
  const L2PRankKey* a = (const L2PRankKey*)pa;
  const L2PRankKey* b = (const L2PRankKey*)pb;
  int c = l2p_cmp_f32(a->cy, b->cy);
  if (c != 0) return c;
  c = l2p_cmp_f32(a->cx, b->cx);
  if (c != 0) return c;
  return (a->idx > b->idx) - (a->idx < b->idx);
}

static bool build_candidates(const L2PQuad* quads, const uint8_t* vertical,
                             int32_t n, L2PPair** out_pairs,
                             int32_t* out_count) {
  L2PPair* pairs = NULL;
  int32_t pair_count = 0;
  int32_t pair_cap = 0;

  int32_t* indices = (int32_t*)malloc((size_t)n * sizeof(int32_t));
  float (*bnds)[4] = (float (*)[4])malloc((size_t)n * sizeof(float[4]));
  float (*sizes)[2] = (float (*)[2])malloc((size_t)n * sizeof(float[2]));
  float (*centers)[2] = (float (*)[2])malloc((size_t)n * sizeof(float[2]));
  L2PRankKey* order = (L2PRankKey*)malloc((size_t)n * sizeof(L2PRankKey));
  int32_t* rank = (int32_t*)malloc((size_t)n * sizeof(int32_t));
  if (!indices || !bnds || !sizes || !centers || !order || !rank) goto fail;

  for (int dir = 0; dir < 2; dir++) {
    int32_t m = 0;
    for (int32_t i = 0; i < n; i++) {
      if ((int)vertical[i] != dir) continue;
      if (fabsf(quad_twice_area_f32(&quads[i])) <= 1e-3f) continue;
      bool edges_ok = true;
      for (int k = 0; k < 4; k++) {
        int kn = (k + 1) & 3;
        float dx = quads[i].p[kn][0] - quads[i].p[k][0];
        float dy = quads[i].p[kn][1] - quads[i].p[k][1];
        if (dx * dx + dy * dy <= 1e-6f) {
          edges_ok = false;
          break;
        }
      }
      if (edges_ok) indices[m++] = i;
    }
    if (m < 2) continue;

    aligned_frame(quads, indices, NULL, m, dir != 0, bnds);
    for (int32_t i = 0; i < m; i++) {
      sizes[i][0] = l2p_maxf(bnds[i][2] - bnds[i][0], 0.25f);
      sizes[i][1] = l2p_maxf(bnds[i][3] - bnds[i][1], 0.25f);
      centers[i][0] = 0.5f * (bnds[i][0] + bnds[i][2]);
      centers[i][1] = 0.5f * (bnds[i][1] + bnds[i][3]);
      order[i].cy = centers[i][1];
      order[i].cx = centers[i][0];
      order[i].idx = i;
    }
    qsort(order, (size_t)m, sizeof(L2PRankKey), cmp_rank_key);
    for (int32_t pos = 0; pos < m; pos++) rank[order[pos].idx] = pos;

    int32_t max_picks = (L2P_MAX_PAIRS - pair_count) * 2;
    int32_t pick_cap = m * 8 < 64 ? 64 : m * 8;
    if (pick_cap > max_picks) pick_cap = max_picks;
    L2PPair* picks = (L2PPair*)malloc((size_t)pick_cap * sizeof(L2PPair));
    if (!picks) goto fail;
    int32_t pick_count = 0;

    for (int32_t i = 0; i < m; i++) {
      L2PNeighbor near_text[6], near_center[5], above[4], below[4], left[2],
          right[2];
      for (int k = 0; k < 6; k++) near_text[k] = (L2PNeighbor){INFINITY, -1};
      for (int k = 0; k < 5; k++) near_center[k] = (L2PNeighbor){INFINITY, -1};
      for (int k = 0; k < 4; k++) {
        above[k] = (L2PNeighbor){INFINITY, -1};
        below[k] = (L2PNeighbor){INFINITY, -1};
      }
      for (int k = 0; k < 2; k++) {
        left[k] = (L2PNeighbor){INFINITY, -1};
        right[k] = (L2PNeighbor){INFINITY, -1};
      }

      const float* a = bnds[i];
      for (int32_t j = 0; j < m; j++) {
        if (i == j) continue;
        const float* b = bnds[j];
        float dx = centers[j][0] - centers[i][0];
        float dy = centers[j][1] - centers[i][1];
        float scale = 0.5f * (sizes[i][1] + sizes[j][1]);
        float x_overlap = l2p_minf(a[2], b[2]) - l2p_maxf(a[0], b[0]);
        float y_overlap = l2p_minf(a[3], b[3]) - l2p_maxf(a[1], b[1]);
        float align_gap = l2p_minf(fabsf(b[0] - a[0]), fabsf(b[2] - a[2]));

        if (fabsf(dy) < 15.0f * scale || fabsf(dx) < 15.0f * scale) {
          float mx = l2p_maxf(-x_overlap, 0.0f) + 0.18f * fabsf(dx);
          nominate(near_text, 6, hypotf(mx, dy), j);
          nominate(near_center, 5, hypotf(dx, dy), j);
        }
        if ((l2p_maxf(x_overlap, 0.0f) / l2p_minf(sizes[i][0], sizes[j][0]) >
                 0.16f ||
             align_gap < 0.9f * scale) &&
            fabsf(dy) > 0.35f * scale) {
          float score = (fabsf(dy) + 0.25f * align_gap) / scale;
          nominate(dy < 0.0f ? above : below, 4, score, j);
        }
        if (l2p_maxf(y_overlap, 0.0f) / l2p_minf(sizes[i][1], sizes[j][1]) >
                0.50f &&
            fabsf(dy) < 0.75f * scale) {
          float score = (fabsf(x_overlap) + fabsf(dy)) / scale;
          if (dx < 0.0f) nominate(left, 2, score, j);
          if (dx > 0.0f) nominate(right, 2, score, j);
        }
      }

      int32_t selected[23];
      int sidx = 0;
      for (int k = 0; k < 6; k++) selected[sidx++] = near_text[k].index;
      for (int k = 0; k < 5; k++) selected[sidx++] = near_center[k].index;
      for (int k = 0; k < 4; k++) selected[sidx++] = above[k].index;
      for (int k = 0; k < 4; k++) selected[sidx++] = below[k].index;
      for (int k = 0; k < 2; k++) selected[sidx++] = left[k].index;
      for (int k = 0; k < 2; k++) selected[sidx++] = right[k].index;
      qsort(selected, 23, sizeof(int32_t), l2p_qsort_i32);

      int32_t prev = -1;
      for (int k = 0; k < 23; k++) {
        int32_t j = selected[k];
        if (j < 0 || j == prev) continue;
        prev = j;
        if (pick_count >= max_picks) {
          free(picks);
          goto fail;
        }
        if (pick_count == pick_cap) {
          int32_t next = pick_cap * 2;
          if (next > max_picks) next = max_picks;
          L2PPair* grown =
              (L2PPair*)realloc(picks, (size_t)next * sizeof(L2PPair));
          if (!grown) {
            free(picks);
            goto fail;
          }
          picks = grown;
          pick_cap = next;
        }
        if (rank[i] < rank[j]) {
          picks[pick_count++] = (L2PPair){indices[i], indices[j]};
        } else {
          picks[pick_count++] = (L2PPair){indices[j], indices[i]};
        }
      }
    }

    qsort(picks, (size_t)pick_count, sizeof(L2PPair), l2p_qsort_pair);
    int32_t unique_count = 0;
    for (int32_t k = 0; k < pick_count; k++) {
      if (unique_count == 0 || picks[k].a != picks[unique_count - 1].a ||
          picks[k].b != picks[unique_count - 1].b) {
        picks[unique_count++] = picks[k];
      }
    }
    if (pair_count + unique_count > L2P_MAX_PAIRS) {
      free(picks);
      goto fail;
    }
    if (pair_count + unique_count > pair_cap) {
      int32_t next = pair_count + unique_count;
      L2PPair* grown = (L2PPair*)realloc(pairs, (size_t)next * sizeof(L2PPair));
      if (!grown) {
        free(picks);
        goto fail;
      }
      pairs = grown;
      pair_cap = next;
    }
    if (unique_count > 0) {
      memcpy(pairs + pair_count, picks, (size_t)unique_count * sizeof(L2PPair));
      pair_count += unique_count;
    }
    free(picks);
  }

  free(indices);
  free(bnds);
  free(sizes);
  free(centers);
  free(order);
  free(rank);
  *out_pairs = pairs;
  *out_count = pair_count;
  return true;

fail:
  free(pairs);
  free(indices);
  free(bnds);
  free(sizes);
  free(centers);
  free(order);
  free(rank);
  return false;
}

typedef struct {
  double q[4][2];
  double center[2];
  double axis[2];
  double normal[2];
  double long_side;
  double short_side;
  double area;
  double length;
  double thickness;
  bool valid;
} L2PMeasure;

static void project_quad(const double q[4][2], const double axis[2],
                         double* out_min, double* out_max) {
  double lo = DBL_MAX, hi = -DBL_MAX;
  for (int i = 0; i < 4; i++) {
    double v = q[i][0] * axis[0] + q[i][1] * axis[1];
    if (v < lo) lo = v;
    if (v > hi) hi = v;
  }
  *out_min = lo;
  *out_max = hi;
}

static void measure_init(const L2PQuad* quad, L2PMeasure* m) {
  double sides[4][2], spans[4];
  int major = 0;
  double shortest = DBL_MAX;
  double cx = 0.0, cy = 0.0;
  for (int i = 0; i < 4; i++) {
    m->q[i][0] = (double)quad->p[i][0];
    m->q[i][1] = (double)quad->p[i][1];
    cx += m->q[i][0];
    cy += m->q[i][1];
  }
  for (int i = 0; i < 4; i++) {
    int j = (i + 1) & 3;
    sides[i][0] = m->q[j][0] - m->q[i][0];
    sides[i][1] = m->q[j][1] - m->q[i][1];
    spans[i] = sqrt(sides[i][0] * sides[i][0] + sides[i][1] * sides[i][1]);
    if (spans[i] > spans[major]) major = i;
    if (spans[i] < shortest) shortest = spans[i];
  }
  m->long_side = spans[major];
  m->short_side = shortest;
  double denom = l2p_maxd(m->long_side, 1e-12);
  m->axis[0] = sides[major][0] / denom;
  m->axis[1] = sides[major][1] / denom;
  if (m->axis[0] < -1e-10 ||
      (fabs(m->axis[0]) <= 1e-10 && m->axis[1] < 0.0)) {
    m->axis[0] = -m->axis[0];
    m->axis[1] = -m->axis[1];
  }
  m->normal[0] = -m->axis[1];
  m->normal[1] = m->axis[0];
  double a = 0, b = 0, c = 0, d = 0;
  project_quad(m->q, m->axis, &a, &b);
  project_quad(m->q, m->normal, &c, &d);
  m->area = fabs(quad_twice_area_f64(m->q));
  m->center[0] = cx * 0.25;
  m->center[1] = cy * 0.25;
  m->length = l2p_maxd(b - a, 1e-6);
  m->thickness = l2p_maxd(d - c, 1e-6);
  m->valid = (m->short_side > 1e-6 && m->area * 0.5 > 1e-6);
}

static inline bool measure_scale_valid(const L2PMeasure* m) {
  return m->short_side * m->short_side > 1e-6 && m->area > 1e-3;
}

static inline double signed_log(double x) {
  double s = x > 0.0 ? 1.0 : (x < 0.0 ? -1.0 : 0.0);
  return s * log1p(fabs(x));
}

static void measure_geometry(const L2PMeasure* self, const L2PMeasure* other,
                             float out[12]) {
  double scale = sqrt(self->thickness * other->thickness);
  double dx = other->center[0] - self->center[0];
  double dy = other->center[1] - self->center[1];

  double a, b, c, d;
  project_quad(self->q, self->axis, &a, &b);
  project_quad(other->q, self->axis, &c, &d);
  double ov_along = l2p_mind(b, d) - l2p_maxd(a, c);
  double along_gap = signed_log(-ov_along / scale);
  double along_overlap =
      l2p_maxd(ov_along, 0.0) / l2p_maxd(l2p_mind(b - a, d - c), 1e-6);
  double start = signed_log((c - a) / scale);
  double end = signed_log((d - b) / scale);

  project_quad(self->q, self->normal, &a, &b);
  project_quad(other->q, self->normal, &c, &d);
  double ov_across = l2p_mind(b, d) - l2p_maxd(a, c);
  double across_gap = signed_log(-ov_across / scale);
  double across_overlap =
      l2p_maxd(ov_across, 0.0) / l2p_maxd(l2p_mind(b - a, d - c), 1e-6);

  double angle_dot =
      self->axis[0] * other->axis[0] + self->axis[1] * other->axis[1];
  double angle_cross =
      self->axis[0] * other->axis[1] - self->axis[1] * other->axis[0];

  out[0] = (float)signed_log((dx * self->axis[0] + dy * self->axis[1]) / scale);
  out[1] =
      (float)signed_log((dx * self->normal[0] + dy * self->normal[1]) / scale);
  out[2] = (float)along_gap;
  out[3] = (float)across_gap;
  out[4] = (float)along_overlap;
  out[5] = (float)across_overlap;
  out[6] = (float)start;
  out[7] = (float)end;
  out[8] = (float)log(other->length / self->length);
  out[9] = (float)log(other->thickness / self->thickness);
  out[10] = (float)(2.0 * angle_dot * angle_dot - 1.0);
  out[11] = (float)(2.0 * angle_dot * angle_cross);
}

/* ============================================================================
 * 外观特征（前景/背景 HSV + Otsu + 精确欧氏距离变换笔画宽度，对应 appearance.rs）
 * ========================================================================== */

static inline void read_pixel_bgr(const uint8_t* img, int32_t width,
                                  int32_t channels, int32_t x, int32_t y,
                                  uint8_t bgr[3]) {
  const uint8_t* p = img + ((size_t)y * (size_t)width + (size_t)x) * (size_t)channels;
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
  bgr[0] = b;
  bgr[1] = g;
  bgr[2] = r;
}

static inline uint8_t bgr_to_gray(const uint8_t bgr[3]) {
  return (uint8_t)((3735u * (uint32_t)bgr[0] + 19235u * (uint32_t)bgr[1] +
                    9798u * (uint32_t)bgr[2] + 16384u) >>
                   15);
}

static uint8_t otsu_threshold(const uint32_t* hist, int32_t bins, uint32_t n) {
  uint32_t total = 0;
  for (int32_t i = 0; i < bins; i++) total += (uint32_t)i * hist[i];
  uint8_t best_t = 0;
  double best_score = 0.0;
  uint32_t left = 0;
  uint32_t weight = 0;
  for (int32_t i = 0; i < bins; i++) {
    left += (uint32_t)i * hist[i];
    weight += hist[i];
    double delta = (double)left * (double)n - (double)total * (double)weight;
    uint32_t denom = weight * (n - weight);
    if (denom == 0) denom = 1;
    double score = (delta * delta) / (double)denom;
    if (score > best_score) {
      best_score = score;
      best_t = (uint8_t)i;
    }
  }
  return best_t;
}

static void cyclic_hsv(const float bgr[3], float out[3]) {
  const float b = bgr[0], g = bgr[1], r = bgr[2];
  float value = l2p_maxf(l2p_maxf(r, g), b);
  float minv = l2p_minf(l2p_minf(r, g), b);
  float chroma = value - minv;
  float saturation = chroma / (fabsf(value) + FLT_EPSILON);
  float factor = 60.0f / (chroma + FLT_EPSILON);
  float hue;
  if (value == r) {
    hue = (g - b) * factor;
  } else if (value == g) {
    hue = (b - r) * factor + 120.0f;
  } else {
    hue = (r - g) * factor + 240.0f;
  }
  if (hue < 0.0f) hue += 360.0f;
  float rad = hue * (float)(3.14159265358979323846 / 180.0);
  out[0] = saturation * cosf(rad);
  out[1] = saturation * sinf(rad);
  out[2] = value;
}

static inline bool is_visible(int32_t w, int32_t h, float x, float y) {
  return x >= 0.0f && x <= (float)(w - 1) && y >= 0.0f && y <= (float)(h - 1);
}

static void extract_colors(const uint8_t* img, int32_t w, int32_t h,
                           int32_t channels, const L2PQuad* q,
                           float output[10]) {
  uint8_t sample_bgr[L2P_COLOR_SAMPLES][3];
  uint8_t sample_bin[L2P_COLOR_SAMPLES];
  uint8_t sample_ok[L2P_COLOR_SAMPLES];
  uint32_t hist[32];
  memset(hist, 0, sizeof(hist));

  for (int i = 0; i < L2P_COLOR_SAMPLES; i++) {
    float u, v;
    if (i < L2P_COLOR_INTERIOR) {
      float x = (float)(i % 32);
      float y = (float)(i / 32);
      u = (x + (y + 0.5f) / 8.0f) / 32.0f;
      v = (y + (x + 0.5f) / 32.0f) / 8.0f;
    } else {
      int edge = i - L2P_COLOR_INTERIOR;
      float t = ((float)(edge % 16) + 0.5f) / 16.0f;
      switch (edge / 16) {
        case 0:
          u = t;
          v = 0.0f;
          break;
        case 1:
          u = 1.0f;
          v = t;
          break;
        case 2:
          u = t;
          v = 1.0f;
          break;
        default:
          u = 0.0f;
          v = t;
          break;
      }
    }
    float w0 = (1.0f - u) * (1.0f - v);
    float w1 = u * (1.0f - v);
    float w2 = u * v;
    float w3 = (1.0f - u) * v;
    float px = w0 * q->p[0][0] + w1 * q->p[1][0] + w2 * q->p[2][0] +
               w3 * q->p[3][0];
    float py = w0 * q->p[0][1] + w1 * q->p[1][1] + w2 * q->p[2][1] +
               w3 * q->p[3][1];
    if (is_visible(w, h, px, py)) {
      int32_t ix = l2p_round_ties_even_i32(px);
      int32_t iy = l2p_round_ties_even_i32(py);
      if (ix >= w) ix = w - 1;
      if (iy >= h) iy = h - 1;
      if (ix < 0) ix = 0;
      if (iy < 0) iy = 0;
      read_pixel_bgr(img, w, channels, ix, iy, sample_bgr[i]);
      uint8_t bin = (uint8_t)(bgr_to_gray(sample_bgr[i]) >> 3);
      hist[bin]++;
      sample_bin[i] = bin;
      sample_ok[i] = 1;
    } else {
      sample_ok[i] = 0;
    }
  }

  uint32_t count = 0;
  for (int i = 0; i < 32; i++) count += hist[i];
  uint8_t thresh = otsu_threshold(hist, 32, count);

  uint32_t sums[2][3] = {{0}};
  uint32_t totals[2] = {0, 0};
  uint32_t border[2] = {0, 0};
  for (int i = 0; i < L2P_COLOR_SAMPLES; i++) {
    if (!sample_ok[i]) continue;
    int light = sample_bin[i] > thresh ? 1 : 0;
    totals[light]++;
    if (i >= L2P_COLOR_INTERIOR) border[light]++;
    sums[light][0] += sample_bgr[i][0];
    sums[light][1] += sample_bgr[i][1];
    sums[light][2] += sample_bgr[i][2];
  }
  uint32_t v0 = (border[0] == 0 && border[1] == 0) ? totals[0] : border[0];
  uint32_t v1 = (border[0] == 0 && border[1] == 0) ? totals[1] : border[1];
  int bg = (v1 >= v0) ? 1 : 0;
  int tones[2] = {bg ^ 1, bg};
  for (int region = 0; region < 2; region++) {
    int tone = tones[region];
    if (totals[tone] != 0) {
      float inv = 1.0f / (float)(totals[tone] * 255u);
      float bgr[3] = {
          (float)sums[tone][0] * inv,
          (float)sums[tone][1] * inv,
          (float)sums[tone][2] * inv,
      };
      cyclic_hsv(bgr, output + region * 3);
      output[7 + region] = 1.0f;
    }
  }
}

static uint8_t quantized_gray(const uint8_t* img, int32_t w, int32_t h,
                              int32_t channels, float x, float y) {
  int32_t fx_all = l2p_round_ties_even_i32(x * 32.0f);
  int32_t fy_all = l2p_round_ties_even_i32(y * 32.0f);
  if (fx_all < 0) fx_all = 0;
  if (fy_all < 0) fy_all = 0;
  int32_t x0 = fx_all >> 5;
  int32_t y0 = fy_all >> 5;
  if (x0 >= w) x0 = w - 1;
  if (y0 >= h) y0 = h - 1;
  int32_t x1 = x0 + 1 < w ? x0 + 1 : w - 1;
  int32_t y1 = y0 + 1 < h ? y0 + 1 : h - 1;
  uint32_t fx = (uint32_t)(fx_all & 31);
  uint32_t fy = (uint32_t)(fy_all & 31);

  uint8_t p00[3], p10[3], p01[3], p11[3];
  read_pixel_bgr(img, w, channels, x0, y0, p00);
  read_pixel_bgr(img, w, channels, x1, y0, p10);
  read_pixel_bgr(img, w, channels, x0, y1, p01);
  read_pixel_bgr(img, w, channels, x1, y1, p11);

  uint32_t w00 = (32u - fx) * (32u - fy);
  uint32_t w10 = fx * (32u - fy);
  uint32_t w01 = (32u - fx) * fy;
  uint32_t w11 = fx * fy;
  uint8_t bgr[3];
  for (int d = 0; d < 3; d++) {
    uint32_t s = w00 * p00[d] + w10 * p10[d] + w01 * p01[d] + w11 * p11[d];
    bgr[d] = (uint8_t)((s + 512u) >> 10);
  }
  return bgr_to_gray(bgr);
}

static void transform_run(const uint16_t horiz[L2P_STROKE_H + 2][L2P_STROKE_W],
                          int x, int before, int after,
                          uint16_t out[L2P_STROKE_WINDOW]) {
  int vertices[L2P_STROKE_H + 2];
  double limits[L2P_STROKE_H + 3];
  vertices[0] = before;
  limits[0] = -INFINITY;
  int k = 0;
  for (int q = before + 1; q <= after; q++) {
    int32_t a = (int32_t)horiz[q][x] + q * q;
    double s;
    for (;;) {
      int p = vertices[k];
      int32_t b = (int32_t)horiz[p][x] + p * p;
      s = (double)(a - b) / (double)(2 * (q - p));
      if (s > limits[k]) break;
      k--;
    }
    k++;
    vertices[k] = q;
    limits[k] = s;
  }
  limits[k + 1] = INFINITY;
  k = 0;
  for (int q = before + 1; q < after; q++) {
    while (limits[k + 1] < (double)q) k++;
    int p = vertices[k];
    int dy = q > p ? (q - p) : (p - q);
    out[(q - 1) * L2P_STROKE_W + x] = (uint16_t)(horiz[p][x] + dy * dy);
  }
}

static void squared_edt(const uint8_t window[L2P_STROKE_WINDOW],
                        uint16_t out[L2P_STROKE_WINDOW]) {
  uint16_t horiz[L2P_STROKE_H + 2][L2P_STROKE_W];
  memset(horiz[0], 0, sizeof(horiz[0]));
  memset(horiz[L2P_STROKE_H + 1], 0, sizeof(horiz[0]));
  for (int y = 0; y < L2P_STROKE_H; y++) {
    const uint8_t* row = window + y * L2P_STROKE_W;
    uint16_t* dst = horiz[y + 1];
    uint16_t run = 0;
    for (int x = 0; x < L2P_STROKE_W; x++) {
      run = row[x] ? (uint16_t)(run + 1) : 0;
      dst[x] = (uint16_t)(run * run);
    }
    run = 0;
    for (int x = L2P_STROKE_W - 1; x >= 0; x--) {
      run = row[x] ? (uint16_t)(run + 1) : 0;
      uint16_t sq = (uint16_t)(run * run);
      if (sq < dst[x]) dst[x] = sq;
    }
  }
  memset(out, 0, L2P_STROKE_WINDOW * sizeof(uint16_t));
  for (int x = 0; x < L2P_STROKE_W; x++) {
    int start = 1;
    while (start <= L2P_STROKE_H) {
      if (horiz[start][x] == 0) {
        start++;
        continue;
      }
      int stop = start + 1;
      while (horiz[stop][x] != 0) stop++;
      if (stop - start <= 2) {
        for (int y = start; y < stop; y++) {
          out[(y - 1) * L2P_STROKE_W + x] = 1;
        }
      } else {
        transform_run(horiz, x, start - 1, stop, out);
      }
      start = stop + 1;
    }
  }
}

static void extract_stroke(const uint8_t* img, int32_t w, int32_t h,
                           int32_t channels, const L2PQuad* q, float length,
                           float thickness, float output[10]) {
  float fraction = l2p_minf(2.0f * thickness / l2p_maxf(length, 1e-6f), 1.0f);
  int16_t samples[L2P_STROKE_SAMPLES];
  uint32_t hist[256];
  memset(hist, 0, sizeof(hist));

  const float centers[3] = {1.0f / 6.0f, 0.5f, 5.0f / 6.0f};
  for (int wi = 0; wi < L2P_STROKE_WINDOWS; wi++) {
    float c = l2p_clampf(centers[wi], fraction * 0.5f, 1.0f - fraction * 0.5f);
    float top_x[L2P_STROKE_W], top_y[L2P_STROKE_W];
    float bot_x[L2P_STROKE_W], bot_y[L2P_STROKE_W];
    for (int x = 0; x < L2P_STROKE_W; x++) {
      float u = c + fraction * (((float)x + 0.5f) / (float)L2P_STROKE_W - 0.5f);
      top_x[x] = (1.0f - u) * q->p[0][0] + u * q->p[1][0];
      top_y[x] = (1.0f - u) * q->p[0][1] + u * q->p[1][1];
      bot_x[x] = (1.0f - u) * q->p[3][0] + u * q->p[2][0];
      bot_y[x] = (1.0f - u) * q->p[3][1] + u * q->p[2][1];
    }
    int16_t* patch = samples + wi * L2P_STROKE_WINDOW;
    for (int y = 0; y < L2P_STROKE_H; y++) {
      float v = ((float)y + 0.5f) / (float)L2P_STROKE_H;
      for (int x = 0; x < L2P_STROKE_W; x++) {
        float px = (1.0f - v) * top_x[x] + v * bot_x[x];
        float py = (1.0f - v) * top_y[x] + v * bot_y[x];
        if (is_visible(w, h, px, py)) {
          uint8_t g = quantized_gray(img, w, h, channels, px, py);
          hist[g]++;
          patch[y * L2P_STROKE_W + x] = (int16_t)g;
        } else {
          patch[y * L2P_STROKE_W + x] = -1;
        }
      }
    }
  }

  uint32_t count = 0;
  for (int i = 0; i < 256; i++) count += hist[i];
  if (count < 32) return;

  uint8_t thresh = otsu_threshold(hist, 256, count);
  uint32_t bcnt[2] = {0, 0};
  for (int wi = 0; wi < L2P_STROKE_WINDOWS; wi++) {
    const int16_t* patch = samples + wi * L2P_STROKE_WINDOW;
    for (int x = 0; x < L2P_STROKE_W; x++) {
      int16_t g0 = patch[x];
      if (g0 >= 0) bcnt[g0 > thresh ? 1 : 0]++;
      int16_t g1 = patch[(L2P_STROKE_H - 1) * L2P_STROKE_W + x];
      if (g1 >= 0) bcnt[g1 > thresh ? 1 : 0]++;
    }
    for (int y = 1; y < L2P_STROKE_H - 1; y++) {
      int16_t gl = patch[y * L2P_STROKE_W];
      if (gl >= 0) bcnt[gl > thresh ? 1 : 0]++;
      int16_t gr = patch[y * L2P_STROKE_W + L2P_STROKE_W - 1];
      if (gr >= 0) bcnt[gr > thresh ? 1 : 0]++;
    }
  }
  bool light_bg = bcnt[1] >= bcnt[0];

  uint16_t widths[L2P_STROKE_SAMPLES];
  int32_t width_count = 0;
  uint8_t fg[L2P_STROKE_WINDOW];
  uint16_t dist[L2P_STROKE_WINDOW];

  for (int wi = 0; wi < L2P_STROKE_WINDOWS; wi++) {
    const int16_t* patch = samples + wi * L2P_STROKE_WINDOW;
    for (int i = 0; i < L2P_STROKE_WINDOW; i++) {
      fg[i] = (patch[i] >= 0 && ((patch[i] > thresh) != light_bg)) ? 1u : 0u;
    }
    squared_edt(fg, dist);
    for (int y = 1; y < L2P_STROKE_H - 1; y++) {
      for (int x = 1; x < L2P_STROKE_W - 1; x++) {
        uint16_t r2 = dist[y * L2P_STROKE_W + x];
        if (r2 == 0) continue;
        if (dist[(y - 1) * L2P_STROKE_W + x - 1] <= r2 &&
            dist[(y - 1) * L2P_STROKE_W + x] <= r2 &&
            dist[(y - 1) * L2P_STROKE_W + x + 1] <= r2 &&
            dist[y * L2P_STROKE_W + x - 1] <= r2 &&
            dist[y * L2P_STROKE_W + x + 1] <= r2 &&
            dist[(y + 1) * L2P_STROKE_W + x - 1] <= r2 &&
            dist[(y + 1) * L2P_STROKE_W + x] <= r2 &&
            dist[(y + 1) * L2P_STROKE_W + x + 1] <= r2) {
          widths[width_count++] = r2;
        }
      }
    }
  }
  if (width_count == 0) return;

  qsort(widths, (size_t)width_count, sizeof(uint16_t), l2p_qsort_u16);
  double typical;
  if ((width_count & 1) == 0) {
    double a = (double)(sqrtf((float)widths[width_count / 2 - 1]) * 2.0f);
    double b = (double)(sqrtf((float)widths[width_count / 2]) * 2.0f);
    typical = 0.5 * (a + b);
  } else {
    typical = (double)(sqrtf((float)widths[width_count / 2]) * 2.0f);
  }
  output[6] = (float)(typical / (double)L2P_STROKE_H);
  if (width_count >= 8) {
    double sum = 0.0;
    for (int32_t i = 0; i < width_count; i++) {
      sum += (double)(sqrtf((float)widths[i]) * 2.0f);
    }
    double mean = sum / (double)width_count;
    double var_sum = 0.0;
    for (int32_t i = 0; i < width_count; i++) {
      double d = (double)(sqrtf((float)widths[i]) * 2.0f) - mean;
      var_sum += d * d;
    }
    double variance = var_sum / (double)width_count;
    double consistency = exp(-sqrt(variance) / l2p_maxd(mean, 1e-6));
    output[9] =
        (float)((double)output[7] * (double)count / (double)L2P_STROKE_SAMPLES *
                l2p_mind((double)thickness / 16.0, 1.0) * consistency);
  }
}

static void extract_line_appearance(const uint8_t* img, int32_t w, int32_t h,
                                    int32_t channels, const L2PQuad* quad,
                                    float out[10]) {
  memset(out, 0, 10 * sizeof(float));
  L2PQuad q = *quad;
  float lens[4];
  for (int i = 0; i < 4; i++) {
    int j = (i + 1) & 3;
    float dx = q.p[j][0] - q.p[i][0];
    float dy = q.p[j][1] - q.p[i][1];
    lens[i] = sqrtf(dx * dx + dy * dy);
  }
  float area = fabsf(quad_twice_area_f32(&q));
  if (area <= 1e-6f || lens[0] <= 1e-6f || lens[1] <= 1e-6f ||
      lens[2] <= 1e-6f || lens[3] <= 1e-6f) {
    return;
  }
  float length = 0.5f * (lens[0] + lens[2]);
  float thickness = 0.5f * (lens[1] + lens[3]);
  if (length < thickness) {
    float t0 = q.p[0][0], t1 = q.p[0][1];
    q.p[0][0] = q.p[1][0];
    q.p[0][1] = q.p[1][1];
    q.p[1][0] = q.p[2][0];
    q.p[1][1] = q.p[2][1];
    q.p[2][0] = q.p[3][0];
    q.p[2][1] = q.p[3][1];
    q.p[3][0] = t0;
    q.p[3][1] = t1;
    float tmp = length;
    length = thickness;
    thickness = tmp;
  }
  extract_colors(img, w, h, channels, &q, out);
  if (area * 0.5f > 1e-6f) {
    extract_stroke(img, w, h, channels, &q, length, thickness, out);
  }
}

static void appearance_pair_diff(const float a[10], const float b[10],
                                 float out[6]) {
  static const double inv_sqrt5 = 0.44721359549995793928;
  float d0 = a[0] - b[0], d1 = a[1] - b[1], d2 = a[2] - b[2];
  float e0 = a[3] - b[3], e1 = a[4] - b[4], e2 = a[5] - b[5];
  out[0] = (float)((double)sqrtf(d0 * d0 + d1 * d1 + d2 * d2) * inv_sqrt5);
  out[1] = (float)((double)sqrtf(e0 * e0 + e1 * e1 + e2 * e2) * inv_sqrt5);
  out[2] = fabsf(logf(l2p_maxf(a[6], 1e-6f) / l2p_maxf(b[6], 1e-6f)));
  out[3] = l2p_minf(a[7], b[7]);
  out[4] = l2p_minf(a[8], b[8]);
  out[5] = l2p_minf(a[9], b[9]);
  for (int i = 0; i < 3; i++) {
    if (out[3 + i] <= 0.0f) out[i] = 0.0f;
  }
}

/* ============================================================================
 * 布局上下文特征（对应 features/layout.rs）
 * ========================================================================== */

typedef struct {
  double left, top, right, bottom, width, height;
} LayoutLine;

typedef struct {
  double dx, dy, scale, gap, overlap;
} LayoutRel;

typedef struct {
  int32_t nearest; /* -1 表示无 */
  double indent_left;
  double indent_right;
  double rank;
  int32_t count;
  double asymmetry;
} LayoutCtx;

static LayoutRel layout_relation(const LayoutLine* a, const LayoutLine* b) {
  LayoutRel r;
  r.dx = 0.5 * (b->left + b->right) - 0.5 * (a->left + a->right);
  r.dy = 0.5 * (b->top + b->bottom) - 0.5 * (a->top + a->bottom);
  r.scale = 0.5 * (a->height + b->height);
  double gap = r.dy >= 0.0 ? (b->top - a->bottom) : (b->bottom - a->top);
  r.gap = fabs(gap);
  double ov = l2p_mind(a->right, b->right) - l2p_maxd(a->left, b->left);
  r.overlap = l2p_maxd(ov, 0.0) / l2p_mind(a->width, b->width);
  return r;
}

static bool compute_layout_features(const L2PQuad* quads,
                                    const uint8_t* vertical, int32_t n,
                                    const L2PPair* pairs, int32_t pair_count,
                                    float (*out_layout)[8]) {
  memset(out_layout, 0, (size_t)pair_count * sizeof(float[8]));

  int32_t* indices = (int32_t*)malloc((size_t)n * sizeof(int32_t));
  uint8_t* valid = (uint8_t*)malloc((size_t)n);
  float (*bnds)[4] = (float (*)[4])malloc((size_t)n * sizeof(float[4]));
  LayoutLine* lines = (LayoutLine*)malloc((size_t)n * sizeof(LayoutLine));
  LayoutCtx* ctx = (LayoutCtx*)malloc((size_t)n * sizeof(LayoutCtx));
  double* tmp = (double*)malloc((size_t)n * sizeof(double));
  double* lefts = (double*)malloc((size_t)n * sizeof(double));
  double* rights = (double*)malloc((size_t)n * sizeof(double));
  int32_t* inverse = (int32_t*)malloc((size_t)n * sizeof(int32_t));
  if (!indices || !valid || !bnds || !lines || !ctx || !tmp || !lefts ||
      !rights || !inverse) {
    free(indices);
    free(valid);
    free(bnds);
    free(lines);
    free(ctx);
    free(tmp);
    free(lefts);
    free(rights);
    free(inverse);
    return false;
  }

  for (int dir = 0; dir < 2; dir++) {
    bool has_pair = false;
    for (int32_t k = 0; k < pair_count; k++) {
      if ((int)vertical[pairs[k].a] == dir) {
        has_pair = true;
        break;
      }
    }
    if (!has_pair) continue;

    int32_t m = 0;
    for (int32_t i = 0; i < n; i++) {
      if ((int)vertical[i] == dir) {
        inverse[i] = m;
        indices[m++] = i;
      }
    }
    for (int32_t i = 0; i < m; i++) {
      const L2PQuad* q = &quads[indices[i]];
      bool ok = fabsf(quad_twice_area_f32(q)) > 1e-3f;
      for (int k = 0; ok && k < 4; k++) {
        int kn = (k + 1) & 3;
        float dx = q->p[kn][0] - q->p[k][0];
        float dy = q->p[kn][1] - q->p[k][1];
        if (sqrtf(dx * dx + dy * dy) <= 1e-6f) ok = false;
      }
      valid[i] = ok ? 1u : 0u;
    }

    aligned_frame(quads, indices, valid, m, dir != 0, bnds);
    for (int32_t i = 0; i < m; i++) {
      lines[i].left = (double)bnds[i][0];
      lines[i].top = (double)bnds[i][1];
      lines[i].right = (double)bnds[i][2];
      lines[i].bottom = (double)bnds[i][3];
      lines[i].width = l2p_maxd(lines[i].right - lines[i].left, 1e-6);
      lines[i].height = l2p_maxd(lines[i].bottom - lines[i].top, 1e-6);
      ctx[i] = (LayoutCtx){-1, 0.0, 0.0, 0.0, 0, 0.0};
    }

    int32_t sched_n = 0;
    for (int32_t i = 0; i < m; i++) {
      if (!valid[i]) continue;
      bool has_best = false;
      bool best_no_ov = true;
      double best_dy = INFINITY, best_dx = INFINITY, best_gap = 0.0;
      int32_t best_j = -1;
      for (int32_t j = 0; j < m; j++) {
        if (i == j || !valid[j]) continue;
        LayoutRel rel = layout_relation(&lines[i], &lines[j]);
        bool no_ov = rel.overlap <= 0.1;
        double ady = fabs(rel.dy);
        double adx = fabs(rel.dx);
        bool better = !has_best;
        if (!better) {
          if (no_ov != best_no_ov) {
            better = !no_ov;
          } else if (ady != best_dy) {
            better = ady < best_dy;
          } else if (adx != best_dx) {
            better = adx < best_dx;
          } else if (j != best_j) {
            better = j < best_j;
          } else {
            better = rel.gap < best_gap;
          }
        }
        if (better) {
          has_best = true;
          best_no_ov = no_ov;
          best_dy = ady;
          best_dx = adx;
          best_j = j;
          best_gap = rel.gap;
        }
      }
      if (has_best) {
        ctx[i].nearest = best_j;
        if (best_gap > 1e-6) tmp[sched_n++] = best_gap;
      }
    }

    int32_t h_n = 0;
    for (int32_t i = 0; i < m; i++) {
      if (valid[i]) lefts[h_n++] = lines[i].height;
    }
    double typical = l2p_median_f64(lefts, h_n, 1.0);
    double center, spread;
    if (sched_n == 0) {
      center = typical;
      spread = typical;
    } else {
      center = l2p_lower_median_f64(tmp, sched_n);
      for (int32_t k = 0; k < sched_n; k++) tmp[k] = fabs(tmp[k] - center);
      spread = l2p_lower_median_f64(tmp, sched_n);
    }
    spread = l2p_maxd(l2p_maxd(spread, 0.25 * typical), 1e-6);

    for (int32_t i = 0; i < m; i++) {
      if (!valid[i]) continue;
      int32_t ln = 0;
      lefts[ln] = lines[i].left;
      rights[ln] = lines[i].right;
      ln++;
      int32_t narrower = 0, equal = 0;
      double side_dist[2] = {INFINITY, INFINITY};
      double side_gap[2] = {center, center};
      for (int32_t j = 0; j < m; j++) {
        if (i == j || !valid[j]) continue;
        LayoutRel rel = layout_relation(&lines[i], &lines[j]);
        if (rel.overlap < 0.15 || fabs(rel.dy) > 7.0 * rel.scale) continue;
        lefts[ln] = lines[j].left;
        rights[ln] = lines[j].right;
        ln++;
        if (lines[j].width < lines[i].width) narrower++;
        if (lines[j].width == lines[i].width) equal++;
        if (rel.gap / rel.scale <= 1.75 &&
            fabs(rel.gap - center) / spread <= 2.5) {
          ctx[i].count++;
        }
        if (rel.dy != 0.0) {
          int k = rel.dy > 0.0 ? 1 : 0;
          double ady = fabs(rel.dy);
          if (ady < side_dist[k]) {
            side_dist[k] = ady;
            side_gap[k] = rel.gap;
          }
        }
      }
      int32_t other_count = ln - 1;
      ctx[i].rank = other_count > 0
                        ? ((double)narrower + 0.5 * (double)equal) /
                              (double)other_count
                        : 0.5;
      ctx[i].indent_left =
          (lines[i].left - l2p_lower_median_f64(lefts, ln)) / lines[i].height;
      ctx[i].indent_right =
          (lines[i].right - l2p_lower_median_f64(rights, ln)) / lines[i].height;
      ctx[i].asymmetry =
          side_gap[1] / lines[i].height - side_gap[0] / lines[i].height;
    }

    for (int32_t k = 0; k < pair_count; k++) {
      if ((int)vertical[pairs[k].a] != dir) continue;
      int32_t i = inverse[pairs[k].a];
      int32_t j = inverse[pairs[k].b];
      if (!valid[i] || !valid[j]) continue;
      const LayoutCtx* ca = &ctx[i];
      const LayoutCtx* cb = &ctx[j];
      double gap = layout_relation(&lines[i], &lines[j]).gap;
      int32_t cmin = ca->count < cb->count ? ca->count : cb->count;
      int32_t cmax = ca->count > cb->count ? ca->count : cb->count;
      if (cmax < 1) cmax = 1;
      out_layout[k][0] = (float)log1p(fabs(gap - center) / spread);
      out_layout[k][1] = (ca->nearest == j && cb->nearest == i) ? 1.0f : 0.0f;
      out_layout[k][2] = (float)log1p(fabs(ca->indent_left - cb->indent_left));
      out_layout[k][3] =
          (float)log1p(fabs(ca->indent_right - cb->indent_right));
      out_layout[k][4] = (float)fabs(ca->rank - cb->rank);
      out_layout[k][5] = (float)cmin / (float)cmax;
      out_layout[k][6] = (float)log1p(fabs(ca->asymmetry - cb->asymmetry));
      out_layout[k][7] = 1.0f;
    }
  }

  free(indices);
  free(valid);
  free(bnds);
  free(lines);
  free(ctx);
  free(tmp);
  free(lefts);
  free(rights);
  free(inverse);
  return true;
}

/* ============================================================================
 * B-Scale 四层 GNN 前向计算（对应 scorer/cpu.rs）
 * ========================================================================== */

enum {
  L2P_ACT_NONE = 0,
  L2P_ACT_RELU = 1,
  L2P_ACT_LEAKY_RELU = 2,
  L2P_ACT_EXP_CLAMP = 3
};

static inline float apply_act(float v, int act) {
  switch (act) {
    case L2P_ACT_RELU:
      return v > 0.0f ? v : 0.0f;
    case L2P_ACT_LEAKY_RELU:
      return v >= 0.0f ? v : v * 0.2f;
    case L2P_ACT_EXP_CLAMP:
      return expf(l2p_clampf(v, -10.0f, 10.0f));
    default:
      return v;
  }
}

static inline float dot_f32(const float* restrict a, const float* restrict b,
                            int32_t k) {
  float s0 = 0.0f, s1 = 0.0f, s2 = 0.0f, s3 = 0.0f;
  int32_t i = 0;
  for (; i + 3 < k; i += 4) {
    s0 += a[i] * b[i];
    s1 += a[i + 1] * b[i + 1];
    s2 += a[i + 2] * b[i + 2];
    s3 += a[i + 3] * b[i + 3];
  }
  float s = (s0 + s1) + (s2 + s3);
  for (; i < k; i++) s += a[i] * b[i];
  return s;
}

static void run_linear_raw(const float* restrict weight,
                           const float* restrict bias, int32_t in_dim,
                           int32_t out_dim, const float* restrict input,
                           int32_t rows, float* restrict out, int act) {
  for (int32_t r = 0; r < rows; r++) {
    const float* x = input + (size_t)r * (size_t)in_dim;
    float* y = out + (size_t)r * (size_t)out_dim;
    for (int32_t o = 0; o < out_dim; o++) {
      float acc = dot_f32(x, weight + (size_t)o * (size_t)in_dim, in_dim);
      if (bias) acc += bias[o];
      y[o] = apply_act(acc, act);
    }
  }
}

static void run_linear(const L2PLinear* l, const float* input, int32_t rows,
                       float* out, int act) {
  run_linear_raw(l->weight, l->bias, l->input, l->output, input, rows, out,
                 act);
}

static void run_relation(const L2PRelation* rel, const L2PPair* pairs,
                         int32_t pair_count, int32_t node_count,
                         const float* nodes, const float* edge,
                         float* endpoints, float* out, int act) {
  const int32_t w = rel->output;
  const size_t table_size = (size_t)node_count * (size_t)w;
  float* left = endpoints;
  float* right = endpoints + table_size;

  run_linear_raw(rel->w_recv, NULL, L2P_NODE_WIDTH, w, nodes, node_count, left,
                 L2P_ACT_NONE);
  run_linear_raw(rel->w_send, NULL, L2P_NODE_WIDTH, w, nodes, node_count, right,
                 L2P_ACT_NONE);
  run_linear_raw(rel->w_edge, rel->bias, L2P_EDGE_WIDTH, w, edge,
                 pair_count * 2, out, L2P_ACT_NONE);

  for (int dir = 0; dir < 2; dir++) {
    float* dir_out = out + (size_t)dir * (size_t)pair_count * (size_t)w;
    for (int32_t e = 0; e < pair_count; e++) {
      int32_t recv_idx = dir == 0 ? pairs[e].a : pairs[e].b;
      int32_t send_idx = dir == 0 ? pairs[e].b : pairs[e].a;
      const float* lr = left + (size_t)recv_idx * (size_t)w;
      const float* rr = right + (size_t)send_idx * (size_t)w;
      float* dst = dir_out + (size_t)e * (size_t)w;
      for (int32_t j = 0; j < w; j++) {
        dst[j] = apply_act(dst[j] + lr[j] + rr[j], act);
      }
    }
  }
}

static void residual_layer_norm(float* target, const float* update,
                                int32_t rows, const L2PNorm* norm) {
  const int32_t w = norm->width;
  const float inv_w = 1.0f / (float)w;
  for (int32_t r = 0; r < rows; r++) {
    float* row = target + (size_t)r * (size_t)w;
    const float* upd = update + (size_t)r * (size_t)w;
    float sum = 0.0f;
    for (int32_t j = 0; j < w; j++) {
      float v = row[j] + upd[j];
      row[j] = v;
      sum += v;
    }
    float mean = sum * inv_w;
    float vsum = 0.0f;
    for (int32_t j = 0; j < w; j++) {
      float d = row[j] - mean;
      vsum += d * d;
    }
    float inv_std = 1.0f / sqrtf(vsum * inv_w + L2P_EPSILON);
    for (int32_t j = 0; j < w; j++) {
      row[j] = (row[j] - mean) * inv_std * norm->weight[j] + norm->bias[j];
    }
  }
}

static bool score_graph(const FluxdoLine2ParaModel* model, int32_t node_count,
                        const float* node_in, int32_t pair_count,
                        const L2PPair* pairs, const float* edge_in,
                        float* out_logits) {
  const int32_t rows = pair_count * 2;
  const size_t node_size = (size_t)node_count * L2P_NODE_WIDTH;
  const size_t edge_size = (size_t)rows * L2P_EDGE_WIDTH;
  const size_t ep_size = (size_t)node_count * 2 * L2P_EDGE_WIDTH;
  const size_t work_size = edge_size > node_size ? edge_size : node_size;

  float* nodes = (float*)malloc(node_size * sizeof(float));
  float* edge = (float*)malloc(edge_size * sizeof(float));
  float* edge_work = (float*)malloc(edge_size * sizeof(float));
  float* endpoints = (float*)malloc(ep_size * sizeof(float));
  float* work = (float*)malloc(work_size * sizeof(float));
  float* update = (float*)malloc(node_size * 2 * sizeof(float));
  float* attention = (float*)malloc((size_t)rows * sizeof(float));
  float* mass = (float*)malloc((size_t)node_count * sizeof(float));
  if (!nodes || !edge || !edge_work || !endpoints || !work || !update ||
      !attention || !mass) {
    free(nodes);
    free(edge);
    free(edge_work);
    free(endpoints);
    free(work);
    free(update);
    free(attention);
    free(mass);
    return false;
  }

  run_linear(&model->node[0], node_in, node_count, work, L2P_ACT_RELU);
  run_linear(&model->node[1], work, node_count, nodes, L2P_ACT_NONE);
  run_linear(&model->edge[0], edge_in, rows, work, L2P_ACT_RELU);
  run_linear(&model->edge[1], work, rows, edge, L2P_ACT_NONE);

  for (int li = 0; li < L2P_LAYERS; li++) {
    const L2PLayer* L = &model->layers[li];
    run_relation(&L->edge_update_0, pairs, pair_count, node_count, nodes, edge,
                 endpoints, work, L2P_ACT_RELU);
    run_linear(&L->edge_update_2, work, rows, edge_work, L2P_ACT_NONE);
    residual_layer_norm(edge, edge_work, rows, &L->edge_norm);

    run_relation(&L->attention_mixed, pairs, pair_count, node_count, nodes,
                 edge, endpoints, work, L2P_ACT_LEAKY_RELU);
    run_linear(&L->attention_final, work, rows, attention, L2P_ACT_EXP_CLAMP);

    run_relation(&L->message_0, pairs, pair_count, node_count, nodes, edge,
                 endpoints, work, L2P_ACT_RELU);
    run_linear(&L->message_2, work, rows, edge_work, L2P_ACT_NONE);

    memset(mass, 0, (size_t)node_count * sizeof(float));
    for (int32_t r = 0; r < rows; r++) {
      int32_t recv = r < pair_count ? pairs[r].a : pairs[r - pair_count].b;
      mass[recv] += attention[r];
    }
    for (int32_t i = 0; i < node_count; i++) {
      float* dst = update + (size_t)i * (2 * L2P_NODE_WIDTH);
      memcpy(dst, nodes + (size_t)i * L2P_NODE_WIDTH,
             L2P_NODE_WIDTH * sizeof(float));
      memset(dst + L2P_NODE_WIDTH, 0, L2P_NODE_WIDTH * sizeof(float));
    }
    for (int32_t r = 0; r < rows; r++) {
      int32_t recv = r < pair_count ? pairs[r].a : pairs[r - pair_count].b;
      float m = mass[recv] > 1e-12f ? mass[recv] : 1e-12f;
      float w = attention[r] / m;
      const float* msg = edge_work + (size_t)r * L2P_NODE_WIDTH;
      float* dst = update + (size_t)recv * (2 * L2P_NODE_WIDTH) + L2P_NODE_WIDTH;
      for (int32_t j = 0; j < L2P_NODE_WIDTH; j++) {
        dst[j] += msg[j] * w;
      }
    }
    run_linear(&L->update_0, update, node_count, work, L2P_ACT_RELU);
    run_linear(&L->update_2, work, node_count, update, L2P_ACT_NONE);
    residual_layer_norm(nodes, update, node_count, &L->node_norm);
  }

  run_relation(&model->classifier_0, pairs, pair_count, node_count, nodes, edge,
               endpoints, work, L2P_ACT_RELU);
  run_linear(&model->classifier_2, work, rows, attention, L2P_ACT_NONE);
  for (int32_t i = 0; i < pair_count; i++) {
    out_logits[i] = 0.5f * (attention[i] + attention[pair_count + i]);
  }

  free(nodes);
  free(edge);
  free(edge_work);
  free(endpoints);
  free(work);
  free(update);
  free(attention);
  free(mass);
  return true;
}

/* ============================================================================
 * Signed 聚类解码与几何阅读顺序排序（对应 decode.rs）
 * ========================================================================== */

typedef struct {
  int32_t a;
  int32_t b;
  float strength;
  int32_t orig_idx;
  uint8_t exclude;
} SignedProposal;

static int cmp_proposal(const void* pa, const void* pb) {
  const SignedProposal* a = (const SignedProposal*)pa;
  const SignedProposal* b = (const SignedProposal*)pb;
  if (a->strength > b->strength) return -1;
  if (a->strength < b->strength) return 1;
  return (a->orig_idx > b->orig_idx) - (a->orig_idx < b->orig_idx);
}

typedef struct {
  int32_t* data;
  int32_t len;
  int32_t cap;
} IntVec;

static bool intvec_push(IntVec* v, int32_t val) {
  if (v->len == v->cap) {
    int32_t next = v->cap ? v->cap * 2 : 4;
    int32_t* grown = (int32_t*)realloc(v->data, (size_t)next * sizeof(int32_t));
    if (!grown) return false;
    v->data = grown;
    v->cap = next;
  }
  v->data[v->len++] = val;
  return true;
}

static bool intvec_contains(const IntVec* v, int32_t val) {
  for (int32_t i = 0; i < v->len; i++) {
    if (v->data[i] == val) return true;
  }
  return false;
}

static bool intvec_insert_unique(IntVec* v, int32_t val) {
  if (intvec_contains(v, val)) return true;
  return intvec_push(v, val);
}

static void intvec_remove(IntVec* v, int32_t val) {
  for (int32_t i = 0; i < v->len; i++) {
    if (v->data[i] == val) {
      v->data[i] = v->data[v->len - 1];
      v->len--;
      return;
    }
  }
}

static bool signed_cluster(int32_t n, const L2PPair* pairs, const float* logits,
                           int32_t pair_count, IntVec* members_out,
                           int32_t* group_count_out) {
  SignedProposal* props =
      pair_count > 0
          ? (SignedProposal*)malloc((size_t)pair_count * sizeof(SignedProposal))
          : NULL;
  int32_t* comp = (int32_t*)malloc((size_t)n * sizeof(int32_t));
  IntVec* members = (IntVec*)calloc((size_t)n, sizeof(IntVec));
  IntVec* excl = (IntVec*)calloc((size_t)n, sizeof(IntVec));
  if ((pair_count > 0 && !props) || !comp || !members || !excl) goto fail;

  int32_t prop_n = 0;
  for (int32_t i = 0; i < pair_count; i++) {
    float s = logits[i];
    if (s >= L2P_SIGNED_THRESHOLD) {
      props[prop_n++] = (SignedProposal){
          pairs[i].a, pairs[i].b, s - L2P_SIGNED_THRESHOLD, i, 0u};
    } else if (s <= L2P_SIGNED_VETO) {
      props[prop_n++] = (SignedProposal){
          pairs[i].a, pairs[i].b, L2P_SIGNED_VETO - s + L2P_SIGNED_SUPPORT, i,
          1u};
    }
  }
  if (prop_n > 1) {
    qsort(props, (size_t)prop_n, sizeof(SignedProposal), cmp_proposal);
  }

  for (int32_t i = 0; i < n; i++) {
    comp[i] = i;
    if (!intvec_push(&members[i], i)) goto fail;
  }

  for (int32_t k = 0; k < prop_n; k++) {
    int32_t a = comp[props[k].a];
    int32_t b = comp[props[k].b];
    if (a == b) continue;
    if (props[k].exclude) {
      if (!intvec_insert_unique(&excl[a], b) ||
          !intvec_insert_unique(&excl[b], a)) {
        goto fail;
      }
      continue;
    }
    if (intvec_contains(&excl[a], b)) continue;
    if (members[a].len > members[b].len) {
      int32_t tmp = a;
      a = b;
      b = tmp;
    }
    for (int32_t i = 0; i < members[a].len; i++) {
      int32_t node = members[a].data[i];
      comp[node] = b;
      if (!intvec_push(&members[b], node)) goto fail;
    }
    free(members[a].data);
    members[a] = (IntVec){NULL, 0, 0};

    for (int32_t i = 0; i < excl[a].len; i++) {
      int32_t nb = excl[a].data[i];
      intvec_remove(&excl[nb], a);
      if (!intvec_insert_unique(&excl[nb], b) ||
          !intvec_insert_unique(&excl[b], nb)) {
        goto fail;
      }
    }
    free(excl[a].data);
    excl[a] = (IntVec){NULL, 0, 0};
  }

  int32_t gc = 0;
  for (int32_t i = 0; i < n; i++) {
    free(excl[i].data);
    if (members[i].len > 0) {
      members_out[gc++] = members[i];
    } else {
      free(members[i].data);
    }
  }
  free(props);
  free(comp);
  free(members);
  free(excl);
  *group_count_out = gc;
  return true;

fail:
  if (members) {
    for (int32_t i = 0; i < n; i++) free(members[i].data);
  }
  if (excl) {
    for (int32_t i = 0; i < n; i++) free(excl[i].data);
  }
  free(props);
  free(comp);
  free(members);
  free(excl);
  return false;
}

typedef struct {
  double left, right, top, bottom;
} BlockBounds;

static inline bool block_overlaps_row(const BlockBounds* a,
                                      const BlockBounds* b) {
  double ov = l2p_mind(a->bottom, b->bottom) - l2p_maxd(a->top, b->top);
  double h = l2p_mind(a->bottom - a->top, b->bottom - b->top);
  return ov >= 0.5 * l2p_maxd(h, L2P_TOLERANCE);
}

typedef struct {
  double y;
  double x;
  int32_t* lines;
  int32_t len;
} OrderedBlock;

static void reading_sort_idx(int32_t* items, int32_t len, const double* ys,
                             const double* xs) {
  for (int32_t i = 1; i < len; i++) {
    int32_t cur = items[i];
    double vy = ys[cur], vx = xs[cur];
    int32_t j = i;
    while (j > 0) {
      int32_t prev = items[j - 1];
      double oy = ys[prev], ox = xs[prev];
      bool before = fabs(vy - oy) > L2P_TOLERANCE ? (vy < oy) : (vx < ox);
      if (!before) break;
      items[j] = items[j - 1];
      j--;
    }
    items[j] = cur;
  }
}

static void reading_sort_blocks(OrderedBlock* items, int32_t len) {
  for (int32_t i = 1; i < len; i++) {
    OrderedBlock cur = items[i];
    int32_t j = i;
    while (j > 0) {
      const OrderedBlock* prev = &items[j - 1];
      bool before = fabs(cur.y - prev->y) > L2P_TOLERANCE
                        ? (cur.y < prev->y)
                        : (cur.x < prev->x);
      if (!before) break;
      items[j] = items[j - 1];
      j--;
    }
    items[j] = cur;
  }
}

static bool order_single_block(const IntVec* raw_group, const L2PQuad* quads,
                               bool vertical, OrderedBlock* out) {
  int32_t m = raw_group->len;
  int32_t* group = (int32_t*)malloc((size_t)m * sizeof(int32_t));
  double (*pts)[4][2] = (double (*)[4][2])malloc((size_t)m * sizeof(double[4][2]));
  BlockBounds* bnds = (BlockBounds*)malloc((size_t)m * sizeof(BlockBounds));
  int32_t* order = (int32_t*)malloc((size_t)m * sizeof(int32_t));
  double* ys = (double*)malloc((size_t)m * sizeof(double));
  double* xs = (double*)malloc((size_t)m * sizeof(double));
  IntVec* rows = (IntVec*)calloc((size_t)m, sizeof(IntVec));
  int32_t* lines = (int32_t*)malloc((size_t)m * sizeof(int32_t));
  if (!group || !pts || !bnds || !order || !ys || !xs || !rows || !lines) {
    goto fail;
  }

  memcpy(group, raw_group->data, (size_t)m * sizeof(int32_t));
  qsort(group, (size_t)m, sizeof(int32_t), l2p_qsort_i32);

  double sum_x = 0.0, sum_y = 0.0;
  for (int32_t k = 0; k < m; k++) {
    const L2PQuad* q = &quads[group[k]];
    for (int i = 0; i < 4; i++) {
      double x = (double)q->p[i][0];
      double y = (double)q->p[i][1];
      pts[k][i][0] = vertical ? y : x;
      pts[k][i][1] = vertical ? -x : y;
    }
    double hx = 0.0, hy = 0.0;
    double longest = -1.0, shortest = DBL_MAX;
    for (int i = 0; i < 4; i++) {
      int j = (i + 1) & 3;
      double dx = pts[k][j][0] - pts[k][i][0];
      double dy = pts[k][j][1] - pts[k][i][1];
      double len = sqrt(dx * dx + dy * dy);
      if (len < shortest) shortest = len;
      if (len > longest) {
        longest = len;
        hx = dx;
        hy = dy;
      }
    }
    if (shortest > L2P_TOLERANCE) {
      double sign = (hx < 0.0 || (fabs(hx) <= L2P_TOLERANCE && hy < 0.0))
                        ? -1.0
                        : 1.0;
      sum_x += sign * hx;
      sum_y += sign * hy;
    }
  }

  double norm = sqrt(sum_x * sum_x + sum_y * sum_y);
  double c = norm > L2P_TOLERANCE ? sum_x / norm : 1.0;
  double s = norm > L2P_TOLERANCE ? sum_y / norm : 0.0;

  double gl = DBL_MAX, gr = -DBL_MAX, gt = DBL_MAX, gb = -DBL_MAX;
  for (int32_t k = 0; k < m; k++) {
    BlockBounds b = {DBL_MAX, -DBL_MAX, DBL_MAX, -DBL_MAX};
    for (int i = 0; i < 4; i++) {
      double rx = pts[k][i][0] * c + pts[k][i][1] * s;
      double ry = -pts[k][i][0] * s + pts[k][i][1] * c;
      b.left = l2p_mind(b.left, rx);
      b.right = l2p_maxd(b.right, rx);
      b.top = l2p_mind(b.top, ry);
      b.bottom = l2p_maxd(b.bottom, ry);
    }
    bnds[k] = b;
    order[k] = k;
    ys[k] = 0.5 * (b.top + b.bottom);
    xs[k] = b.left;
    gl = l2p_mind(gl, b.left);
    gr = l2p_maxd(gr, b.right);
    gt = l2p_mind(gt, b.top);
    gb = l2p_maxd(gb, b.bottom);
  }

  reading_sort_idx(order, m, ys, xs);
  int32_t row_count = 0;
  for (int32_t oi = 0; oi < m; oi++) {
    int32_t idx = order[oi];
    int32_t placed = -1;
    for (int32_t r = 0; r < row_count; r++) {
      bool all_ov = true;
      for (int32_t k = 0; k < rows[r].len; k++) {
        if (!block_overlaps_row(&bnds[idx], &bnds[rows[r].data[k]])) {
          all_ov = false;
          break;
        }
      }
      if (all_ov) {
        placed = r;
        break;
      }
    }
    if (placed >= 0) {
      if (!intvec_push(&rows[placed], idx)) goto fail;
    } else {
      if (!intvec_push(&rows[row_count], idx)) goto fail;
      row_count++;
    }
  }

  int32_t out_pos = 0;
  for (int32_t r = 0; r < row_count; r++) {
    /* 行内按 (left, top, center_y, center_x) 稳定插入排序 */
    IntVec* row = &rows[r];
    for (int32_t i = 1; i < row->len; i++) {
      int32_t cur = row->data[i];
      const BlockBounds* a = &bnds[cur];
      double acy = 0.5 * (a->top + a->bottom);
      double acx = 0.5 * (a->left + a->right);
      int32_t j = i;
      while (j > 0) {
        const BlockBounds* b = &bnds[row->data[j - 1]];
        double bcy = 0.5 * (b->top + b->bottom);
        double bcx = 0.5 * (b->left + b->right);
        int cmp = l2p_cmp_f64(a->left, b->left);
        if (cmp == 0) cmp = l2p_cmp_f64(a->top, b->top);
        if (cmp == 0) cmp = l2p_cmp_f64(acy, bcy);
        if (cmp == 0) cmp = l2p_cmp_f64(acx, bcx);
        if (cmp >= 0) break;
        row->data[j] = row->data[j - 1];
        j--;
      }
      row->data[j] = cur;
    }
    for (int32_t i = 0; i < row->len; i++) {
      lines[out_pos++] = group[row->data[i]];
    }
  }

  double cx = 0.5 * (gl + gr);
  double cy = 0.5 * (gt + gb);
  out->y = cy * c + cx * s;
  out->x = cx * c - cy * s;
  out->lines = lines;
  out->len = m;

  for (int32_t r = 0; r < row_count; r++) free(rows[r].data);
  free(rows);
  free(group);
  free(pts);
  free(bnds);
  free(order);
  free(ys);
  free(xs);
  return true;

fail:
  if (rows) {
    for (int32_t r = 0; r < m; r++) free(rows[r].data);
  }
  free(rows);
  free(group);
  free(pts);
  free(bnds);
  free(order);
  free(ys);
  free(xs);
  free(lines);
  return false;
}

static int32_t decode_and_order(const L2PQuad* quads, const uint8_t* vertical,
                                int32_t n, const L2PPair* pairs,
                                const float* logits, int32_t pair_count,
                                int32_t* out_order, int32_t* out_group_offsets,
                                int32_t max_groups) {
  for (int32_t i = 0; i < pair_count; i++) {
    if (!isfinite(logits[i])) return -3;
  }
  IntVec* groups = (IntVec*)calloc((size_t)n, sizeof(IntVec));
  OrderedBlock* blocks = (OrderedBlock*)calloc((size_t)n, sizeof(OrderedBlock));
  if (!groups || !blocks) {
    free(groups);
    free(blocks);
    return -2;
  }

  int32_t group_count = 0;
  if (!signed_cluster(n, pairs, logits, pair_count, groups, &group_count)) {
    free(groups);
    free(blocks);
    return -2;
  }
  if (group_count > max_groups) {
    for (int32_t g = 0; g < group_count; g++) free(groups[g].data);
    free(groups);
    free(blocks);
    return -2;
  }

  int32_t write_group = 0;
  int32_t write_line = 0;
  out_group_offsets[0] = 0;

  for (int dir = 0; dir < 2; dir++) {
    int32_t dir_count = 0;
    for (int32_t g = 0; g < group_count; g++) {
      if ((int)vertical[groups[g].data[0]] != dir) continue;
      if (!order_single_block(&groups[g], quads, dir != 0,
                              &blocks[dir_count])) {
        for (int32_t k = 0; k < dir_count; k++) free(blocks[k].lines);
        for (int32_t k = 0; k < group_count; k++) free(groups[k].data);
        free(groups);
        free(blocks);
        return -2;
      }
      dir_count++;
    }
    reading_sort_blocks(blocks, dir_count);
    for (int32_t k = 0; k < dir_count; k++) {
      memcpy(out_order + write_line, blocks[k].lines,
             (size_t)blocks[k].len * sizeof(int32_t));
      write_line += blocks[k].len;
      write_group++;
      out_group_offsets[write_group] = write_line;
      free(blocks[k].lines);
    }
  }

  for (int32_t g = 0; g < group_count; g++) free(groups[g].data);
  free(groups);
  free(blocks);
  return write_group;
}

/* ============================================================================
 * 导出接口
 * ========================================================================== */

FLUXDO_OCR_EXPORT int32_t fluxdo_line2para_group(
    const void* handle, const uint8_t* image, int32_t width, int32_t height,
    int32_t channels, const float* quads_flat, int32_t line_count,
    int32_t* out_order, int32_t* out_group_offsets, int32_t max_groups) {
  if (!handle || !image || width <= 0 || height <= 0 ||
      (channels != 3 && channels != 4) || line_count < 0 || !out_order ||
      !out_group_offsets || max_groups < line_count) {
    return -1;
  }
  if (line_count == 0) {
    out_group_offsets[0] = 0;
    return 0;
  }
  if (line_count > L2P_MAX_LINES || !quads_flat) return -1;
  for (int32_t i = 0; i < line_count * 8; i++) {
    if (!isfinite(quads_flat[i])) return -3;
  }
  if (line_count == 1) {
    out_order[0] = 0;
    out_group_offsets[0] = 0;
    out_group_offsets[1] = 1;
    return 1;
  }

  const FluxdoLine2ParaModel* model = (const FluxdoLine2ParaModel*)handle;
  L2PQuad* quads = (L2PQuad*)malloc((size_t)line_count * sizeof(L2PQuad));
  uint8_t* vertical = (uint8_t*)malloc((size_t)line_count);
  L2PMeasure* info =
      (L2PMeasure*)malloc((size_t)line_count * sizeof(L2PMeasure));
  float* node_in =
      (float*)calloc((size_t)line_count * L2P_NODE_INPUT, sizeof(float));
  L2PPair* pairs = NULL;
  int32_t pair_count = 0;

  if (!quads || !vertical || !info || !node_in) {
    free(quads);
    free(vertical);
    free(info);
    free(node_in);
    return -2;
  }

  for (int32_t i = 0; i < line_count; i++) {
    L2PQuad q;
    for (int k = 0; k < 4; k++) {
      q.p[k][0] = quads_flat[i * 8 + k * 2];
      q.p[k][1] = quads_flat[i * 8 + k * 2 + 1];
    }
    quads[i] = quad_canonical(q);
    measure_init(&quads[i], &info[i]);
  }

  if (!detect_directions(quads, line_count, vertical)) {
    free(quads);
    free(vertical);
    free(info);
    free(node_in);
    return -2;
  }

  if (!build_candidates(quads, vertical, line_count, &pairs, &pair_count)) {
    free(quads);
    free(vertical);
    free(info);
    free(node_in);
    return -2;
  }

  if (pair_count == 0) {
    int32_t rc = decode_and_order(quads, vertical, line_count, NULL, NULL, 0,
                                  out_order, out_group_offsets, max_groups);
    free(pairs);
    free(quads);
    free(vertical);
    free(info);
    free(node_in);
    return rc;
  }

  float (*appearance)[10] =
      (float (*)[10])malloc((size_t)line_count * sizeof(float[10]));
  double* thick_buf = (double*)malloc((size_t)line_count * sizeof(double));
  float (*layouts)[8] =
      (float (*)[8])malloc((size_t)pair_count * sizeof(float[8]));
  float* edge_in = (float*)malloc((size_t)pair_count * 2 * L2P_EDGE_INPUT *
                                  sizeof(float));
  float* logits = (float*)malloc((size_t)pair_count * sizeof(float));

  int32_t rc = -2;
  if (!appearance || !thick_buf || !layouts || !edge_in || !logits) {
    goto cleanup;
  }

  for (int32_t i = 0; i < line_count; i++) {
    extract_line_appearance(image, width, height, channels, &quads[i],
                            appearance[i]);
  }

  for (int dir = 0; dir < 2; dir++) {
    int32_t tn = 0;
    for (int32_t i = 0; i < line_count; i++) {
      if ((int)vertical[i] == dir && measure_scale_valid(&info[i])) {
        thick_buf[tn++] = info[i].short_side;
      }
    }
    double scale = l2p_median_f64(thick_buf, tn, 1.0);
    for (int32_t i = 0; i < line_count; i++) {
      if ((int)vertical[i] == dir && info[i].valid) {
        float* row = node_in + (size_t)i * L2P_NODE_INPUT;
        if (measure_scale_valid(&info[i])) {
          row[0] = (float)log1p(info[i].long_side / scale);
          row[1] = (float)(info[i].short_side / info[i].long_side);
        }
        row[2] = appearance[i][2];
      }
    }
  }

  if (!compute_layout_features(quads, vertical, line_count, pairs, pair_count,
                               layouts)) {
    goto cleanup;
  }

  for (int32_t idx = 0; idx < pair_count; idx++) {
    int32_t a = pairs[idx].a;
    int32_t b = pairs[idx].b;
    if (!info[a].valid || !info[b].valid || layouts[idx][7] != 1.0f) {
      rc = -3;
      goto cleanup;
    }
    float style[6];
    appearance_pair_diff(appearance[a], appearance[b], style);

    float* fwd = edge_in + (size_t)idx * L2P_EDGE_INPUT;
    measure_geometry(&info[a], &info[b], fwd);
    memcpy(fwd + 12, style, 6 * sizeof(float));
    memcpy(fwd + 18, layouts[idx], 8 * sizeof(float));

    float* rev = edge_in + (size_t)(idx + pair_count) * L2P_EDGE_INPUT;
    measure_geometry(&info[b], &info[a], rev);
    memcpy(rev + 12, style, 6 * sizeof(float));
    memcpy(rev + 18, layouts[idx], 8 * sizeof(float));
  }

  for (size_t i = 0; i < (size_t)line_count * L2P_NODE_INPUT; i++) {
    if (!isfinite(node_in[i])) {
      rc = -3;
      goto cleanup;
    }
  }
  for (size_t i = 0; i < (size_t)pair_count * 2 * L2P_EDGE_INPUT; i++) {
    if (!isfinite(edge_in[i])) {
      rc = -3;
      goto cleanup;
    }
  }

  if (!score_graph(model, line_count, node_in, pair_count, pairs, edge_in,
                   logits)) {
    rc = -2;
    goto cleanup;
  }

  rc = decode_and_order(quads, vertical, line_count, pairs, logits, pair_count,
                        out_order, out_group_offsets, max_groups);

cleanup:
  free(logits);
  free(edge_in);
  free(layouts);
  free(thick_buf);
  free(appearance);
  free(pairs);
  free(node_in);
  free(info);
  free(vertical);
  free(quads);
  return rc;
}

/// 供单元测试直接验证 Signed 聚类与几何阅读顺序解码（与上游 decode.rs 测试对齐）。
FLUXDO_OCR_EXPORT int32_t fluxdo_line2para_decode_signed(
    const float* quads_flat, const uint8_t* vertical, int32_t line_count,
    const int32_t* pairs_flat, const float* logits, int32_t pair_count,
    int32_t* out_order, int32_t* out_group_offsets, int32_t max_groups) {
  if (!quads_flat || !vertical || line_count <= 0 || pair_count < 0 ||
      !out_order || !out_group_offsets || max_groups < line_count) {
    return -1;
  }
  L2PQuad* quads = (L2PQuad*)malloc((size_t)line_count * sizeof(L2PQuad));
  L2PPair* pairs =
      pair_count > 0 ? (L2PPair*)malloc((size_t)pair_count * sizeof(L2PPair))
                     : NULL;
  if (!quads || (pair_count > 0 && !pairs)) {
    free(quads);
    free(pairs);
    return -2;
  }
  for (int32_t i = 0; i < line_count; i++) {
    for (int k = 0; k < 4; k++) {
      quads[i].p[k][0] = quads_flat[i * 8 + k * 2];
      quads[i].p[k][1] = quads_flat[i * 8 + k * 2 + 1];
    }
  }
  for (int32_t i = 0; i < pair_count; i++) {
    pairs[i].a = pairs_flat[i * 2];
    pairs[i].b = pairs_flat[i * 2 + 1];
  }
  int32_t rc = decode_and_order(quads, vertical, line_count, pairs, logits,
                                pair_count, out_order, out_group_offsets,
                                max_groups);
  free(quads);
  free(pairs);
  return rc;
}
