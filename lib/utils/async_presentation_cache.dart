import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 常驻列表的展示缓存。切换账号/查询时，连同刷新携带的 previous 一起
/// 作废；只缓存展示数据，不拦截 provider 的业务状态或请求。
class AsyncPresentationCache<T> {
  Object? _identity;
  AsyncValue<T>? _cached;
  AsyncValue<T>? _obsolete;

  Object? get identity => _identity;
  AsyncValue<T> get cached => _cached ?? AsyncValue<T>.loading();

  void selectIdentity(Object next) {
    if (_identity == next) return;
    _identity = next;
    final previous = _cached;
    if (previous != null && (previous.hasValue || !previous.isLoading)) {
      _obsolete = previous;
    }
    // 连续切换参数时不能用中间的空 loading 覆盖最初那份失效数据。
    _cached = null;
  }

  AsyncValue<T> accept(AsyncValue<T> next) {
    final obsolete = _obsolete;
    if (obsolete != null &&
        (identical(next, obsolete) ||
            (next.isLoading && identical(next.value, obsolete.value)))) {
      return _cached = AsyncValue<T>.loading();
    }
    _obsolete = null;
    return _cached = next;
  }

  /// 用户信息可能晚于列表返回；现有刷新链未启动请求时，宿主需补一次
  /// 刷新。调度后再读一次 provider 检查，避免与已排队的刷新重复请求。
  bool needsRefresh(AsyncValue<T> latest) =>
      !latest.isLoading && identical(latest, _obsolete);
}
