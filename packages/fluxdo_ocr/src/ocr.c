#include "onnxruntime_c_api.h"
#include <stdio.h>
#include <stdlib.h>

#ifdef _WIN32
#define OCR_EXPORT __declspec(dllexport)
#else
#define OCR_EXPORT __attribute__((visibility("default")))
#endif

typedef struct {
  const OrtApi *api;
  OrtEnv *env;
  OrtSession *session;
  OrtMemoryInfo *memory;
  OrtAllocator *allocator;
  char *input_name;
  char *output_name;
} OcrModel;

typedef struct {
  OrtValue *value;
  float *data;
  int64_t dimensions[4];
  size_t rank;
} OcrOutput;

// 将错误复制到调用方的缓冲区，所有 ONNX 对象仍由创建它们的运行库释放。
static int failed(const OrtApi *api, OrtStatus *status, char *error) {
  if (!status) return 0;
  snprintf(error, 512, "%s", api->GetErrorMessage(status));
  api->ReleaseStatus(status);
  return 1;
}

OCR_EXPORT void ocr_close(OcrModel *m) {
  if (!m) return;
  if (m->input_name) m->allocator->Free(m->allocator, m->input_name);
  if (m->output_name) m->allocator->Free(m->allocator, m->output_name);
  m->api->ReleaseMemoryInfo(m->memory);
  m->api->ReleaseSession(m->session);
  m->api->ReleaseEnv(m->env);
  free(m);
}

OCR_EXPORT OcrModel *ocr_open(const OrtApiBase *base, const uint8_t *bytes,
                              size_t length, char *error) {
#ifdef FLUX_OCR_STATIC
  base = OrtGetApiBase();
#endif
  const OrtApi *api = base ? base->GetApi(ORT_API_VERSION) : NULL;
  if (!api) {
    snprintf(error, 512, "ONNX Runtime API %d", ORT_API_VERSION);
    return NULL;
  }
  OcrModel *m = (OcrModel *)calloc(1, sizeof(*m));
  if (!m) {
    snprintf(error, 512, "Out of memory");
    return NULL;
  }
  m->api = api;
  OrtSessionOptions *options = NULL;
  if (failed(api, api->CreateEnv(ORT_LOGGING_LEVEL_ERROR, "fluxdo_ocr", &m->env), error) ||
      failed(api, api->CreateSessionOptions(&options), error) ||
      failed(api, api->SetIntraOpNumThreads(options, 2), error) ||
      failed(api, api->SetInterOpNumThreads(options, 1), error) ||
      failed(api, api->CreateSessionFromArray(m->env, bytes, length, options, &m->session), error) ||
      failed(api, api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &m->memory), error) ||
      failed(api, api->GetAllocatorWithDefaultOptions(&m->allocator), error) ||
      failed(api, api->SessionGetInputName(m->session, 0, m->allocator, &m->input_name), error) ||
      failed(api, api->SessionGetOutputName(m->session, 0, m->allocator, &m->output_name), error)) {
    api->ReleaseSessionOptions(options);
    ocr_close(m);
    return NULL;
  }
  api->ReleaseSessionOptions(options);
  return m;
}

OCR_EXPORT void ocr_release_output(OcrModel *m, OcrOutput *out) {
  m->api->ReleaseValue(out->value);
  out->value = NULL;
}

OCR_EXPORT int ocr_run(OcrModel *m, float *pixels, int width, int height,
                       OcrOutput *out, char *error) {
  const OrtApi *api = m->api;
  int64_t shape[] = {1, 3, height, width};
  const char *input_names[] = {m->input_name};
  const char *output_names[] = {m->output_name};
  OrtValue *input = NULL;
  const OrtValue *inputs[1];
  OrtTensorTypeAndShapeInfo *info = NULL;
  ONNXTensorElementDataType type;
  int ok = 0;
  if (failed(api, api->CreateTensorWithDataAsOrtValue(m->memory, pixels,
      (size_t)width * height * 3 * sizeof(float), shape, 4,
      ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &input), error)) goto cleanup;
  inputs[0] = input;
  if (failed(api, api->Run(m->session, NULL, input_names, inputs, 1, output_names, 1, &out->value), error) ||
      failed(api, api->GetTensorTypeAndShape(out->value, &info), error) ||
      failed(api, api->GetTensorElementType(info, &type), error) ||
      failed(api, api->GetDimensionsCount(info, &out->rank), error)) goto cleanup;
  if (type != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT || out->rank == 0 || out->rank > 4) {
    snprintf(error, 512, "Unexpected OCR output tensor");
    goto cleanup;
  }
  if (failed(api, api->GetDimensions(info, out->dimensions, out->rank), error) ||
      failed(api, api->GetTensorMutableData(out->value, (void **)&out->data), error)) goto cleanup;
  ok = 1;
cleanup:
  api->ReleaseTensorTypeAndShapeInfo(info);
  api->ReleaseValue(input);
  if (!ok) ocr_release_output(m, out);
  return ok;
}
