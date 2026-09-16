// 验证真实 dylib 可加载、桥接导出存在，且 QuickJS 能执行现代 JS。
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "quickjs.h"

#define LOAD(name) __typeof__(&name) fn_##name = dlsym(lib, #name); \
  if (!fn_##name) { fprintf(stderr, "缺少符号：%s\n", #name); return 1; }

int main(int argc, char **argv) {
  if (argc != 2) return 2;
  void *lib = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  if (!lib) { fprintf(stderr, "%s\n", dlerror()); return 1; }
  if (!dlsym(lib, "JSEvalWrapper") || !dlsym(lib, "JS_NewRuntimeDartBridge")) return 1;
  LOAD(JS_NewRuntime);
  LOAD(JS_NewContext);
  LOAD(JS_Eval);
  LOAD(JS_ToCStringLen2);
  LOAD(JS_FreeCString);
  LOAD(JS_FreeContext);
  LOAD(JS_FreeRuntime);
  JSRuntime *runtime = fn_JS_NewRuntime();
  JSContext *context = fn_JS_NewContext(runtime);
  const char *code = "JSON.stringify({sum:[1,2,3].reduce((a,b)=>a+b,0),big:String(2n**64n)})";
  JSValue value = fn_JS_Eval(context, code, strlen(code), "smoke.js", JS_EVAL_TYPE_GLOBAL);
  if (JS_IsException(value)) return 1;
  const char *text = fn_JS_ToCStringLen2(context, NULL, value, false);
  const char *expected = "{\"sum\":6,\"big\":\"18446744073709551616\"}";
  int result = !text || strcmp(text, expected);
  if (text) { puts(text); fn_JS_FreeCString(context, text); }
  // 通过 JS_FreeValue 的导出包装释放，避免测试程序静态链接 QuickJS。
  void (*free_value)(JSContext *, JSValue) = dlsym(lib, "JS_FreeValue");
  if (free_value) free_value(context, value);
  else { fprintf(stderr, "缺少 JS_FreeValue\n"); return 1; }
  fn_JS_FreeContext(context);
  fn_JS_FreeRuntime(runtime);
  dlclose(lib);
  return result;
}
