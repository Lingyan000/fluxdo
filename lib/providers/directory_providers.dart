import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/connect_stats.dart';
import 'core_providers.dart';
import 'discourse_providers.dart';

/// connect.linux.do 统计 Provider
final connectStatsProvider = FutureProvider<ConnectStats?>((ref) async {
  final user = ref.watch(
    currentUserProvider.select((value) => value.value),
  );
  if (user == null) return null;

  // 复用共享 Dio(每次 build 都 DiscourseDio.create() 会重装整套
  // 拦截器/adapter/cookie,白付一次构建成本)
  final dio = ref.read(discourseServiceProvider).dio;
  final response = await dio.get('https://connect.linux.do/');
  if (response.statusCode == 200) {
    return ConnectStats.fromHtml(response.data);
  }
  return null;
});
