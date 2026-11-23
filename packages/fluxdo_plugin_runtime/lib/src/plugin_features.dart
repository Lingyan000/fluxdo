/// 宿主提供的可选特性。清单要求与运行时查询共用同一注册表。
enum PluginFeature {
  browserModes,
  automaticPagination,
  gridLayouts,
  virtualGrid,
  confirmationDialog,
  nativeExecutionLimits,
  navigationEntries,
  forumRead,
  scheduledTasks,
  localNotifications,
  navigationBadge,
  atomicStorage,
  runtimePermissions,
  adaptiveCollections,
  modalDismiss,
  cardNavigation,
  contentPresentation,
  eventStreams,
  dataMigrations,
  hostEnvironment,
  pluginPreferences,
  pageChrome,
  loadingPlaceholders,
  navigationReplacement,
  credentialClaims,
  iconButtonContent,
  notificationStatus,
}

class PluginFeatures {
  static final supported = Set<String>.unmodifiable(PluginFeature.values.map((v) => v.name));
  static List<String> parse(Object? raw) {
    if (raw == null) return const [];
    if (raw is! List || raw.length > 64 || raw.any((v) => v is! String || !RegExp(r'^[A-Za-z][A-Za-z0-9]{0,63}$').hasMatch(v))) {
      throw const FormatException('requiredFeatures 必须是能力名称数组');
    }
    return List<String>.unmodifiable(raw.cast<String>().toSet());
  }
  static List<String> missing(Iterable<String> required) => required.where((v) => !supported.contains(v)).toList();
}
