// 静态 LiteRT 的 C API 由链接器导出；此编译单元仅提供随包动态库的入口。
__attribute__((visibility("default"))) int fluxdo_litert_runtime_version(void) {
  return 20400;
}
