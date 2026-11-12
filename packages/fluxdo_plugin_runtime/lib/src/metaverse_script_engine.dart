/// 插件脚本引擎的最小接口。
///
/// 抽成接口是为了让运行时的协议逻辑能在不加载原生库的测试里用假引擎驱动。
abstract class MetaverseScriptEngine {
  /// 脚本向宿主投递消息的通道名。
  static const channel = 'fluxdoMetaverse';

  /// 脚本经 `sendMessage(channel, json)` 发来的消息（已 JSON 解码）。
  set onMessage(void Function(Object? message)? handler);

  /// 引擎不可恢复地失效：脚本长时间不返回（死循环）或引擎崩溃。
  ///
  /// 至多触发一次，之后所有 [evaluate] 都会失败。
  set onFatal(void Function(String reason)? handler);

  /// 执行一段脚本并排空微任务队列。
  ///
  /// 脚本抛错、引擎已失效或已释放时以 [MetaverseScriptException] 失败。
  Future<void> evaluate(String code, {String name});

  void dispose();
}

class MetaverseScriptException implements Exception {
  const MetaverseScriptException(this.message);

  final String message;

  @override
  String toString() => message;
}

typedef MetaverseScriptEngineFactory = Future<MetaverseScriptEngine> Function();
