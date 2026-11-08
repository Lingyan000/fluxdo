/// 引擎只决定宿主如何启动，不改变官方沙箱或应用权限。
enum MiniAppEngine {
  lightweight,
  web;

  static MiniAppEngine parse(String? value) =>
      value == web.name ? web : lightweight;
}
