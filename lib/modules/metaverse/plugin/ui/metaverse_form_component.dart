part of 'metaverse_widget_library.dart';

enum _PluginFieldType { text, multiline, password, toggle, choice }

class _PluginFormField {
  const _PluginFormField({
    required this.name,
    required this.label,
    required this.type,
    required this.required,
    required this.value,
    required this.options,
    this.hint,
    this.error,
    this.maxLength,
  });
  final String name, label;
  final _PluginFieldType type;
  final bool required;
  final Object? value;
  final String? hint, error;
  final int? maxLength;
  final List<({String value, String label})> options;
}

List<_PluginFormField>? _readFormFields(DataSource source) {
  final fields = <_PluginFormField>[];
  final names = <String>{};
  for (var index = 0; index < source.length(['fields']); index++) {
    final path = <Object>['fields', index];
    final name = source.v<String>([...path, 'name']);
    final type = _PluginFieldType.values
        .asNameMap()[source.v<String>([...path, 'type']) ?? 'text'];
    final maxLength = source.v<int>([...path, 'maxLength']);
    if (name == null ||
        name.isEmpty ||
        !names.add(name) ||
        type == null ||
        (maxLength != null && maxLength < 1)) {
      return null;
    }
    final options = <({String value, String label})>[];
    final optionValues = <String>{};
    for (
      var option = 0;
      option < source.length([...path, 'options']);
      option++
    ) {
      final optionPath = [...path, 'options', option];
      final value = source.v<String>([...optionPath, 'value']);
      if (value == null || !optionValues.add(value)) return null;
      options.add((
        value: value,
        label: source.v<String>([...optionPath, 'label']) ?? value,
      ));
    }
    fields.add(
      _PluginFormField(
        name: name,
        label: source.v<String>([...path, 'label']) ?? name,
        type: type,
        required: source.v<bool>([...path, 'required']) == true,
        value: type == _PluginFieldType.toggle
            ? source.v<bool>([...path, 'value']) ?? false
            : source.v<String>([...path, 'value']) ?? '',
        hint: source.v<String>([...path, 'hint']),
        error: source.v<String>([...path, 'error']),
        maxLength: maxLength,
        options: options,
      ),
    );
  }
  return fields;
}

class _PluginFormPage extends StatefulWidget {
  const _PluginFormPage({
    required this.fields,
    required this.resetKey,
    required this.loading,
    required this.submitLabel,
    required this.actions,
    this.header,
    this.onChanged,
    this.onSubmit,
  });
  final List<_PluginFormField> fields;
  final String resetKey, submitLabel;
  final bool loading;
  final Widget? header;
  final List<Widget> actions;
  final void Function(String field, Object? value)? onChanged;
  final ValueChanged<Map<String, Object?>>? onSubmit;
  @override
  State<_PluginFormPage> createState() => _PluginFormPageState();
}

class _PluginFormPageState extends State<_PluginFormPage> {
  final _form = GlobalKey<FormState>();
  final _values = <String, Object?>{};
  final _revisions = <String, int>{};

  @override
  void initState() {
    super.initState();
    _synchronize(const []);
  }

  @override
  void didUpdateWidget(_PluginFormPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    _synchronize(
      oldWidget.resetKey == widget.resetKey ? oldWidget.fields : const [],
    );
  }

  void _synchronize(List<_PluginFormField> previous) {
    final oldFields = {for (final field in previous) field.name: field};
    final names = widget.fields.map((field) => field.name).toSet();
    _values.removeWhere((name, _) => !names.contains(name));
    _revisions.removeWhere((name, _) => !names.contains(name));
    for (final field in widget.fields) {
      final old = oldFields[field.name];
      var value = _values[field.name];
      final reset = old == null || old.type != field.type;
      if (reset || old.value != field.value) value = field.value;
      if (field.type == _PluginFieldType.choice &&
          !field.options.any((option) => option.value == value)) {
        value = null;
      }
      if (reset || _values[field.name] != value) {
        _values[field.name] = value;
        _revisions.update(field.name, (value) => value + 1, ifAbsent: () => 0);
      }
    }
  }

  void _change(_PluginFormField field, Object? value) {
    _values[field.name] = value;
    widget.onChanged?.call(field.name, value);
  }

  String? _validate(_PluginFormField field, Object? value) {
    final empty =
        value == null ||
        value == false ||
        (value is String && value.trim().isEmpty);
    if (field.required && empty) {
      return context.l10n.metaverse_formRequired(field.label);
    }
    if (value is String &&
        field.maxLength != null &&
        value.characters.length > field.maxLength!) {
      return context.l10n.metaverse_formTooLong(field.label, field.maxLength!);
    }
    return null;
  }

  void _submit() {
    if (widget.loading || _form.currentState?.validate() != true) return;
    FocusScope.of(context).unfocus();
    widget.onSubmit?.call(Map.of(_values));
  }

  Widget _field(_PluginFormField field) {
    final key = ValueKey((field.name, _revisions[field.name]));
    final error = field.error?.isNotEmpty == true ? field.error : null;
    if (field.type == _PluginFieldType.toggle) {
      return FormField<bool>(
        key: key,
        initialValue: _values[field.name] == true,
        validator: (value) => _validate(field, value),
        forceErrorText: error,
        builder: (state) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            M3eSwitchListTile(
              title: Text(field.label),
              value: state.value == true,
              onChanged: widget.loading
                  ? null
                  : (value) {
                      state.didChange(value);
                      _change(field, value);
                    },
            ),
            if (state.errorText case final message?)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  message,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      );
    }
    final decoration = InputDecoration(
      labelText: field.label,
      hintText: field.hint,
    );
    if (field.type == _PluginFieldType.choice) {
      return DropdownButtonFormField<String>(
        key: key,
        initialValue: _values[field.name] as String?,
        isExpanded: true,
        decoration: decoration,
        forceErrorText: error,
        validator: (value) => _validate(field, value),
        items: [
          for (final option in field.options)
            DropdownMenuItem(value: option.value, child: Text(option.label)),
        ],
        onChanged: widget.loading ? null : (value) => _change(field, value),
      );
    }
    return TextFormField(
      key: key,
      initialValue: _values[field.name] as String?,
      enabled: !widget.loading,
      obscureText: field.type == _PluginFieldType.password,
      enableSuggestions: field.type != _PluginFieldType.password,
      autocorrect: field.type != _PluginFieldType.password,
      minLines: field.type == _PluginFieldType.multiline ? 3 : 1,
      maxLines: field.type == _PluginFieldType.multiline ? null : 1,
      maxLength: field.maxLength,
      decoration: decoration,
      forceErrorText: error,
      validator: (value) => _validate(field, value),
      onChanged: (value) => _change(field, value),
    );
  }

  @override
  Widget build(BuildContext context) => Form(
    key: _form,
    child: _PluginPageLayout(
      loading: widget.loading,
      footer: OverflowBar(
        alignment: MainAxisAlignment.end,
        overflowAlignment: OverflowBarAlignment.end,
        spacing: 12,
        overflowSpacing: 8,
        children: [
          ...widget.actions,
          FilledButton.icon(
            onPressed: widget.loading || widget.onSubmit == null
                ? null
                : _submit,
            icon: widget.loading ? const LoadingSpinner(size: 18) : null,
            label: Text(widget.submitLabel),
          ),
        ],
      ),
      children: [
        if (widget.header case final header?) ...[
          header,
          const SizedBox(height: 20),
        ],
        for (final field in widget.fields) ...[
          _field(field),
          const SizedBox(height: 16),
        ],
      ],
    ),
  );
}
