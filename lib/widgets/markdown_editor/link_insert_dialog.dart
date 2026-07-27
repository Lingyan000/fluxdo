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

  /// 文本与 URL **双向**联动。粘贴进来的裸链接两部分本来就相等,编辑
  /// 时要一直保持相等 —— 改哪一边另一边都跟着走,否则改完就成了
  /// 「显示旧地址、跳新地址」(实测:在文本框删掉 `?u=xxx`,URL 没跟着
  /// 改,切到源码看见 `[无参数地址](带参数地址)`)。
  ///
  /// 只在**进来时两边相等**(或文本为空)才开;本来就不相等的链接是
  /// 「自定义文案」,只改文本,不联动。
  bool _textMirrorsUrl = false;
  bool _syncing = false;

  /// 上一次两个框的值。联动判据用**改动前那一刻是否相等**,不看初始
  /// 状态 —— 进来时锚文本可能是被截断显示的 URL,按初始状态判会直接
  /// 不联动(实测:在文本框删掉 `?u=xxx`,URL 纹丝不动)。
  late String _prevText;
  late String _prevUrl;

  @override
  void initState() {
    super.initState();
    _textController = TextEditingController(text: widget.initialText);
    _urlController = TextEditingController(text: widget.initialUrl);
    _prevText = widget.initialText ?? '';
    _prevUrl = widget.initialUrl ?? '';
    final text = _prevText.trim();
    final url = _prevUrl.trim();
    _textMirrorsUrl = text.isEmpty || (url.isNotEmpty && text == url);
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

  /// 把 [value] 同步到另一个框(光标落末尾;_syncing 防两个 onChanged
  /// 互相递归)。
  void _mirrorTo(TextEditingController target, String value) {
    if (_syncing || target.text == value) return;
    _syncing = true;
    target.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    _syncing = false;
  }

  /// 改动前两边就相等(或文本为空)→ 这是"文本即链接"的裸链接,保持相等。
  bool get _shouldMirror =>
      _textMirrorsUrl || _prevText.trim().isEmpty || _prevText == _prevUrl;

  void _onTextChanged(String value) {
    final mirror = _shouldMirror;
    _prevText = value;
    if (mirror) {
      _mirrorTo(_urlController, value);
      _prevUrl = value;
      _textMirrorsUrl = true;
    } else {
      _textMirrorsUrl = false;
    }
  }

  void _onUrlChanged(String value) {
    final mirror = _shouldMirror;
    _prevUrl = value;
    if (mirror) {
      _mirrorTo(_textController, value);
      _prevText = value;
      _textMirrorsUrl = true;
    }
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
    // 选了站内话题就是"要显示标题",这属于自定义文案,断开联动
    if (_textController.text.trim().isEmpty || _textMirrorsUrl) {
      _textController.text = t.title;
      _textMirrorsUrl = false;
      _prevText = t.title;
      _prevUrl = _urlController.text;
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
                onChanged: _onTextChanged,
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
