import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class _RefreshableTextEditingController extends TextEditingController {
  _RefreshableTextEditingController.fromValue(super.value) : super.fromValue();

  void refreshOptions() {
    notifyListeners();
  }
}

class BookmarkNameAutocompleteField extends StatefulWidget {
  const BookmarkNameAutocompleteField({
    super.key,
    required this.controller,
    required this.suggestions,
    required this.labelText,
    required this.hintText,
    this.maxLength = 100,
    this.maxOptions,
  });

  final TextEditingController controller;
  final Iterable<String> suggestions;
  final String labelText;
  final String hintText;
  final int maxLength;
  final int? maxOptions;

  @override
  State<BookmarkNameAutocompleteField> createState() =>
      _BookmarkNameAutocompleteFieldState();
}

class _BookmarkNameAutocompleteFieldState
    extends State<BookmarkNameAutocompleteField> {
  late final FocusNode _focusNode;
  late final _RefreshableTextEditingController _internalController;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    _internalController = _RefreshableTextEditingController.fromValue(
      widget.controller.value,
    );
    widget.controller.addListener(_syncFromExternalController);
    _internalController.addListener(_syncToExternalController);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_syncFromExternalController);
    _internalController.removeListener(_syncToExternalController);
    _internalController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant BookmarkNameAutocompleteField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_syncFromExternalController);
      widget.controller.addListener(_syncFromExternalController);
      _syncFromExternalController();
    }
    if (_sameSuggestions(oldWidget.suggestions, widget.suggestions)) {
      return;
    }
    // 候选异步到达后，主动刷新内部 controller 的监听，立即重算补全。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _internalController.refreshOptions();
    });
  }

  void _syncFromExternalController() {
    if (_internalController.value == widget.controller.value) {
      return;
    }
    _internalController.value = widget.controller.value;
  }

  void _syncToExternalController() {
    if (widget.controller.value == _internalController.value) {
      return;
    }
    widget.controller.value = _internalController.value;
  }

  Iterable<String> _buildOptions(TextEditingValue value) {
    final query = value.text.trim().toLowerCase();
    final normalized = <String>[];
    final seen = <String>{};

    for (final suggestion in widget.suggestions) {
      final trimmed = suggestion.trim();
      if (trimmed.isEmpty || !seen.add(trimmed)) {
        continue;
      }
      final lower = trimmed.toLowerCase();
      if (query.isEmpty || lower.startsWith(query) || lower.contains(query)) {
        normalized.add(trimmed);
      }
      if (widget.maxOptions != null &&
          normalized.length >= widget.maxOptions!) {
        break;
      }
    }

    return normalized;
  }

  bool _sameSuggestions(Iterable<String> left, Iterable<String> right) {
    final leftList = left.toList(growable: false);
    final rightList = right.toList(growable: false);
    if (leftList.length != rightList.length) {
      return false;
    }
    for (var index = 0; index < leftList.length; index++) {
      if (leftList[index] != rightList[index]) {
        return false;
      }
    }
    return true;
  }

  Object _suggestionsFingerprint() {
    // 用 Object.hashAll + length 做轻量指纹，避免每次 build 都拼接长字符串。
    // 仅用于 ValueKey 判等，不要求抗碰撞。
    return Object.hash(
      widget.suggestions.length,
      Object.hashAll(widget.suggestions),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return RawAutocomplete<String>(
      // 这里的 ValueKey 是必需的：RawAutocomplete 内部缓存了 optionsBuilder
      // 上一次返回的 options，单纯 _internalController.refreshOptions() 不足
      // 以让它在 widget 重建时重算（详见 widget 测试
      // "候选异步到达后会基于当前输入立即显示补全"）。
      //
      // 重建本身不会打断输入：textEditingController 与 focusNode 都是本 State
      // 持有的字段，RawAutocomplete 重建不会 dispose 它们。会丢失的只是候选
      // 浮层的内部状态，而我们恰好希望浮层基于新候选立即重算。
      key: ValueKey(_suggestionsFingerprint()),
      textEditingController: _internalController,
      focusNode: _focusNode,
      optionsBuilder: _buildOptions,
      onSelected: (value) {
        _internalController.value = TextEditingValue(
          text: value,
          selection: TextSelection.collapsed(offset: value.length),
        );
      },
      fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
        return Focus(
          onKeyEvent: (_, event) {
            if (event is! KeyDownEvent ||
                event.logicalKey != LogicalKeyboardKey.tab) {
              return KeyEventResult.ignored;
            }
            final options = _buildOptions(controller.value).toList();
            if (options.isEmpty) {
              return KeyEventResult.ignored;
            }
            final value = options.first;
            controller.value = TextEditingValue(
              text: value,
              selection: TextSelection.collapsed(offset: value.length),
            );
            return KeyEventResult.handled;
          },
          child: TextFormField(
            controller: controller,
            focusNode: focusNode,
            autofocus: false,
            maxLength: widget.maxLength,
            decoration: InputDecoration(
              labelText: widget.labelText,
              hintText: widget.hintText,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              counterText: '',
              prefixIcon: const Icon(Icons.label_outline, size: 20),
            ),
          ),
        );
      },
      optionsViewBuilder: (context, onSelected, options) {
        final optionList = options.toList();
        if (optionList.isEmpty) {
          return const SizedBox.shrink();
        }

        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 6,
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(12),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420, maxHeight: 240),
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(vertical: 8),
                shrinkWrap: true,
                itemCount: optionList.length,
                separatorBuilder: (_, _) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final option = optionList[index];
                  return ListTile(
                    dense: true,
                    title: Text(option),
                    onTap: () => onSelected(option),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}
