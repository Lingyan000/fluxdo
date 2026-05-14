import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
  }

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant BookmarkNameAutocompleteField oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_sameSuggestions(oldWidget.suggestions, widget.suggestions)) {
      return;
    }
    // RawAutocomplete 只会在输入框 controller 变更时重新计算候选；
    // 候选异步到达后主动触发一次监听，确保当前输入立即刷新补全。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      widget.controller.notifyListeners();
    });
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
    return listEquals(
      left.toList(growable: false),
      right.toList(growable: false),
    );
  }

  String _suggestionsKey() {
    return widget.suggestions.join('\u0001');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return RawAutocomplete<String>(
      key: ValueKey(_suggestionsKey()),
      textEditingController: widget.controller,
      focusNode: _focusNode,
      optionsBuilder: _buildOptions,
      onSelected: (value) {
        widget.controller.value = TextEditingValue(
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
