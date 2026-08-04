import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:app_icons/app_icons.dart';

import '../l10n/s.dart';
import '../models/chat/chat_channel.dart';
import '../models/chat/chat_message.dart';
import '../services/discourse/discourse_service.dart';
import '../services/toast_service.dart';

/// Chat API 探测页(开发者模式临时入口)
///
/// M0 验证:站点有 CF 盾,裸 curl 不可用,借 app 自己的网络栈
/// 在登录态下实测 linux.do 的 chat 插件响应形状与当前账号权限。
/// 结果分"解析摘要"和"原始 JSON"两层——摘要验证模型层字段映射
/// 是否正确,原始 JSON 供比对脱漏字段。
class ChatApiProbePage extends StatefulWidget {
  const ChatApiProbePage({super.key});

  @override
  State<ChatApiProbePage> createState() => _ChatApiProbePageState();
}

class _StepResult {
  final String title;
  final bool ok;
  final String summary;
  final String? rawJson;

  const _StepResult({
    required this.title,
    required this.ok,
    required this.summary,
    this.rawJson,
  });
}

class _ChatApiProbePageState extends State<ChatApiProbePage> {
  final List<_StepResult> _results = [];
  bool _running = false;

  static const _encoder = JsonEncoder.withIndent('  ');

  Future<void> _run() async {
    setState(() {
      _running = true;
      _results.clear();
    });

    final service = DiscourseService();

    // 步骤 1: me/channels —— 权限与响应形状的总入口
    MyChatChannelsResponse? myChannels;
    try {
      final rawResponse = await service.dio.get('/chat/api/me/channels');
      final rawData = rawResponse.data as Map<String, dynamic>;
      myChannels = MyChatChannelsResponse.fromJson(rawData);
      final dmChannels = myChannels.directMessageChannels;
      final summary = StringBuffer()
        ..writeln('公共频道: ${myChannels.publicChannels.length} 个')
        ..writeln('DM 频道: ${dmChannels.length} 个')
        ..writeln(
          '全局 bus last_ids: '
          '${myChannels.globalBusLastIds.keys.join(', ')}',
        )
        ..writeln('tracking 条目: ${myChannels.channelTracking.length}');
      for (final ch in dmChannels.take(3)) {
        summary.writeln(
          '- #${ch.id} ${ch.isGroupDm ? '[群]' : '[1:1]'} '
          'title="${ch.title}" 成员=${ch.dmUsers.map((u) => u.username).join(',')} '
          '未读=${myChannels.channelTracking[ch.id]?.unreadCount ?? 0} '
          'lastRead=${ch.currentUserMembership?.lastReadMessageId}',
        );
      }
      _addResult(
        _StepResult(
          title: 'GET /chat/api/me/channels',
          ok: true,
          summary: summary.toString(),
          rawJson: _encoder.convert(rawData),
        ),
      );
    } catch (e) {
      _addResult(
        _StepResult(
          title: 'GET /chat/api/me/channels',
          ok: false,
          summary: '$e\n\n'
              '403 = chat 未对当前账号开放(chat_allowed_groups/'
              'direct_message_enabled_groups);404 = 插件未装。',
        ),
      );
    }

    // 步骤 2: 有 DM 频道则拉一页消息,验证消息分页形状
    final firstDm = myChannels?.directMessageChannels.firstOrNull;
    if (firstDm != null) {
      try {
        final rawResponse = await service.dio.get(
          '/chat/api/channels/${firstDm.id}/messages',
          queryParameters: {'page_size': 10, 'fetch_from_last_read': true},
        );
        final rawData = rawResponse.data as Map<String, dynamic>;
        final parsed = ChatMessagesResponse.fromJson(
          rawData,
          channelId: firstDm.id,
        );
        final summary = StringBuffer()
          ..writeln('消息: ${parsed.messages.length} 条')
          ..writeln(
            'can_load_more past=${parsed.canLoadMorePast} '
            'future=${parsed.canLoadMoreFuture} '
            'target=${parsed.targetMessageId}',
          );
        for (final m in parsed.messages.take(3)) {
          summary.writeln(
            '- #${m.id} @${m.user?.username} '
            '${m.createdAt} uploads=${m.uploads.length} '
            'reactions=${m.reactions.length} '
            '"${m.excerpt ?? m.message}"',
          );
        }
        _addResult(
          _StepResult(
            title: 'GET /chat/api/channels/${firstDm.id}/messages',
            ok: true,
            summary: summary.toString(),
            rawJson: _encoder.convert(rawData),
          ),
        );
      } catch (e) {
        _addResult(
          _StepResult(
            title: 'GET /chat/api/channels/${firstDm.id}/messages',
            ok: false,
            summary: '$e',
          ),
        );
      }
    } else {
      _addResult(
        const _StepResult(
          title: '消息分页探测',
          ok: false,
          summary: '没有已存在的 DM 频道,跳过。可在网页端先发一条 DM 再回来跑。',
        ),
      );
    }

    if (mounted) setState(() => _running = false);
  }

  void _addResult(_StepResult result) {
    if (mounted) setState(() => _results.add(result));
  }

  void _copyRaw(_StepResult result) {
    Clipboard.setData(ClipboardData(text: result.rawJson!));
    ToastService.showSuccess(S.current.common_copiedToClipboard);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Chat API 探测')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          FilledButton.icon(
            onPressed: _running ? null : _run,
            icon: _running
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Symbols.play_arrow_rounded),
            label: Text(_running ? '探测中…' : '开始探测'),
          ),
          const SizedBox(height: 16),
          for (final result in _results) ...[
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          result.ok
                              ? Symbols.check_circle_rounded
                              : Symbols.error_rounded,
                          size: 18,
                          color: result.ok
                              ? Colors.green
                              : theme.colorScheme.error,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            result.title,
                            style: theme.textTheme.titleSmall,
                          ),
                        ),
                        if (result.rawJson != null)
                          IconButton(
                            icon: const Icon(
                              Symbols.content_copy_rounded,
                              size: 18,
                            ),
                            tooltip: '复制原始 JSON',
                            onPressed: () => _copyRaw(result),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SelectableText(
                      result.summary,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}
