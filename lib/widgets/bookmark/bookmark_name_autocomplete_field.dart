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

  String _suggestionsKey() {
    return widget.suggestions.join('\u0001');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return RawAutocomplete<String>(
      key: ValueKey(_suggestionsKey()),
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
