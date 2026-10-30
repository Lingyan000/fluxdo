import 'package:flutter/widgets.dart';

/// 导入原文与导出基线分开保存：导入不是编辑，表示形态变化也不是编辑。
/// controller 外部改写后本会话永久失效，旧异步导入和 dispose 均不能覆盖它。
class ComposerRawMirror {
  ComposerRawMirror(this.controller, {required this.onExternalChange})
    : initialValue = controller.value,
      _expectedRaw = controller.text {
    controller.addListener(_onControllerChanged);
  }

  final TextEditingController controller;
  final VoidCallback onExternalChange;
  final TextEditingValue initialValue;
  String _expectedRaw;
  String? _baseline;
  String? _lastExport;
  int? _lastRevision;
  bool _valid = true;
  bool get isCurrent => _valid && controller.text == _expectedRaw;

  void _onControllerChanged() {
    if (!_valid || controller.text == _expectedRaw) return;
    _valid = false;
    onExternalChange();
  }

  void install({required String exported, required int revision}) {
    if (!isCurrent) return;
    _baseline = _lastExport = exported;
    _lastRevision = revision;
  }

  /// 修订号只是导出缓存键；IR 展开也会增号，内容以无副作用导出为准。
  void flush({required int revision, required String Function() export}) {
    if (!isCurrent || _baseline == null) return;
    final exported = revision == _lastRevision ? _lastExport! : export();
    if (!isCurrent) return;
    _lastExport = exported;
    _lastRevision = revision;
    final raw = exported == _baseline ? initialValue.text : exported;
    final value = controller.value;
    final selectionValid =
        value.selection.isValid && value.selection.end <= raw.length;
    if (raw == value.text && selectionValid) return;
    final originalSelection = initialValue.selection;
    final restoreOriginal =
        raw == initialValue.text &&
        originalSelection.isValid &&
        originalSelection.end <= raw.length;
    // 回声同步通知前先记录期望值；监听者再次外部改写仍会使会话失效。
    _expectedRaw = raw;
    controller.value = TextEditingValue(
      text: raw,
      selection: raw == value.text && selectionValid
          ? value.selection
          : restoreOriginal
          ? originalSelection
          : TextSelection.collapsed(offset: raw.length),
    );
  }

  void invalidate() => _valid = false;

  void dispose() {
    controller.removeListener(_onControllerChanged);
    _valid = false;
  }
}
