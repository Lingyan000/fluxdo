// 站点插件公开 API
//
// 用于承载各社区自建的 Discourse 插件能力（非 Discourse 标准功能）。
// 新增插件：在 `lib/plugins/<name>/` 下实现 [SitePlugin]，
// 然后在对应站点的 `SiteCustomization.plugins` 里注册。
export 'character_counts/character_counts_plugin.dart'
    show CharacterCountsPlugin;
export 'plugin_context.dart'
    show TopicPluginContext, ReplySubmitContext, ComposerMinLengthContext;
export 'plugin_registry.dart' show PluginRegistry;
export 'reply_cost/reply_cost_plugin.dart' show ReplyCostPlugin;
export 'site_plugin.dart' show SitePlugin;
export 'topic_plugin_data.dart' show TopicPluginData;
export 'warden/warden_plugin.dart' show WardenPlugin;
