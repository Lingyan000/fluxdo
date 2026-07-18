import 'dart:async';

import 'package:flutter/material.dart';
import '../../../../../l10n/s.dart';
import '../../models/search_result.dart';
import '../../services/discourse/discourse_service.dart';
import '../../utils/dialog_utils.dart';
import '../../utils/url_helper.dart';

/// 链接插入/编辑对话框(官方 upsert-hyperlink 对齐):
/// - URL 框输入非 http 文字(≥4 字符)→ 站内话题搜索联想,选中回填
///   URL + 标题(引用站内帖高频);
/// - 提交时 URL 规范化:无协议补 https://(prefixProtocol 同款);
/// - [editing] = 编辑既有链接(标题/按钮文案切换)。
/// 返回 {text: '链接文本', url: 'https://...'};text 可空(调用方
/// 兜底用 url 当显示文字 —— 官方同语义)。
class LinkInsertDialog extends StatefulWidget {
  final String? initialText;
  final String? initialUrl;
  final bool editing;

  const LinkInsertDialog({
    super.key,
    this.initialText,
    this.initialUrl,
    this.editing = false,
  });

  @override
  State<LinkInsertDialog> createState() => _LinkInsertDialogState();
}

class _LinkInsertDialogState extends State<LinkInsertDialog> {
  late final TextEditingController _textController;
  late final TextEditingController _urlController;
  final _formKey = GlobalKey<FormState>();

  Timer? _searchDebounce;
  List<SearchTopic> _results = const [];
  bool _searching = false;
  int _searchSeq = 0;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: widget.initialText);
    _urlController = TextEditingController(text: widget.initialUrl);
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _textController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  /// 官方 prefixProtocol 同款:无协议且非相对路径/锚点 → 补 https://。
  static String normalizeUrl(String url) {
    final u = url.trim();
    if (u.isEmpty) return u;
    if (u.startsWith('#') || u.startsWith('/')) return u;
    if (RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]*:').hasMatch(u)) return u; // 有协议
    return 'https://$u';
  }

  void _onUrlChanged(String value) {
    _searchDebounce?.cancel();
    final q = value.trim();
    // 官方口径:<4 字符或 http 开头不搜(已是 URL)
    if (q.length < 4 || q.startsWith('http')) {
      if (_results.isNotEmpty || _searching) {
        setState(() {
          _results = const [];
          _searching = false;
        });
      }
      return;
    }
    _searchDebounce = Timer(const Duration(milliseconds: 400), () async {
      final seq = ++_searchSeq;
      setState(() => _searching = true);
      List<SearchTopic> topics = const [];
      try {
        final result =
            await DiscourseService().search(query: q, typeFilter: 'topic');
        // 话题信息挂在 posts[].topic 上,按话题去重
        final seen = <int>{};
        topics = [
          for (final p in result.posts)
            if (p.topic != null && seen.add(p.topic!.id)) p.topic!,
        ];
      } catch (_) {
        // 搜索失败静默(纯联想,不挡手动输入)
      }
      if (!mounted || seq != _searchSeq) return;
      setState(() {
        _searching = false;
        _results = topics.take(6).toList();
      });
    });
  }

  void _selectTopic(SearchTopic t) {
    _searchDebounce?.cancel();
    _searchSeq++; // 作废在途搜索
    _urlController.text = UrlHelper.resolveUrl('/t/${t.slug}/${t.id}');
    if (_textController.text.trim().isEmpty) {
      _textController.text = t.title;
    }
    setState(() {
      _results = const [];
      _searching = false;
    });
  }

  void _submit() {
    if (_formKey.currentState!.validate()) {
      Navigator.of(context).pop({
        'text': _textController.text,
        'url': normalizeUrl(_urlController.text),
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(widget.editing ? '编辑链接' : S.current.link_insertTitle),
      content: Form(
        key: _formKey,
        child: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextFormField(
                controller: _urlController,
                decoration: InputDecoration(
                  labelText: 'URL / 搜索站内话题',
                  hintText: 'https://… 或输入关键词搜话题',
                  border: const OutlineInputBorder(),
                  suffixIcon: _searching
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : null,
                ),
                keyboardType: TextInputType.url,
                autofocus: true,
                textInputAction: TextInputAction.next,
                onChanged: _onUrlChanged,
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return S.current.link_urlRequired;
                  }
                  return null;
                },
              ),
              // 站内话题联想(官方 internal-link-results 同位)
              if (_results.isNotEmpty)
                Container(
                  margin: const EdgeInsets.only(top: 6),
                  constraints: const BoxConstraints(maxHeight: 210),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: scheme.outlineVariant.withValues(alpha: 0.5),
                    ),
                  ),
                  child: ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: _results.length,
                    itemBuilder: (c, i) {
                      final t = _results[i];
                      return InkWell(
                        onTap: () => _selectTopic(t),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 10, vertical: 7),
                          child: Row(children: [
                            if (t.closed || t.archived) ...[
                              Icon(Icons.lock_outline_rounded,
                                  size: 13, color: scheme.onSurfaceVariant),
                              const SizedBox(width: 4),
                            ],
                            Expanded(
                              child: Text(
                                t.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 13),
                              ),
                            ),
                          ]),
                        ),
                      );
                    },
                  ),
                ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _textController,
                decoration: InputDecoration(
                  labelText: S.current.link_textLabel,
                  hintText: '可空,默认用 URL',
                  border: const OutlineInputBorder(),
                ),
                textInputAction: TextInputAction.done,
                onFieldSubmitted: (_) => _submit(),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(S.current.common_cancel),
        ),
        FilledButton(
          onPressed: _submit,
          child: Text(widget.editing ? '保存' : S.current.common_confirm),
        ),
      ],
    );
  }
}

/// 显示链接插入/编辑对话框
Future<Map<String, String>?> showLinkInsertDialog(
  BuildContext context, {
  String? initialText,
  String? initialUrl,
  bool editing = false,
}) {
  return showAppDialog<Map<String, String>>(
    context: context,
    builder: (context) => LinkInsertDialog(
      initialText: initialText,
      initialUrl: initialUrl,
      editing: editing,
    ),
  );
}
