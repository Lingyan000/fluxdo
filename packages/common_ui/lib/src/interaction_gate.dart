import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Separates a layer's input ownership from its visual transition.
///
/// Change [enabled] when a close is committed, rather than when its animation
/// finishes. Hit testing updates synchronously, including a new pointer down
/// before the next build. Existing pointer sequences keep their original path.
/// Painting is unchanged, and disabled layers expose the content behind them.
class InteractionGate extends SingleChildRenderObjectWidget {
  const InteractionGate({
    super.key,
    required this.enabled,
    required super.child,
  });

  final ValueListenable<bool> enabled;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderInteractionGate(enabled);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) {
    (renderObject as _RenderInteractionGate).enabled = enabled;
  }
}

class _RenderInteractionGate extends RenderIgnorePointer {
  _RenderInteractionGate(this._enabled) : super(ignoring: !_enabled.value);

  ValueListenable<bool> _enabled;

  set enabled(ValueListenable<bool> value) {
    if (identical(_enabled, value)) return;
    if (attached) _enabled.removeListener(_sync);
    _enabled = value;
    if (attached) _enabled.addListener(_sync);
    _sync();
  }

  void _sync() => ignoring = !_enabled.value;

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _enabled.addListener(_sync);
    _sync();
  }

  @override
  void detach() {
    _enabled.removeListener(_sync);
    super.detach();
  }
}
