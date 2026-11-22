import 'package:material_ui/material_ui.dart';

import 'predictive_back_cupertino_transitions.dart';
import 'route_interaction.dart';

Future<T?> showInteractionBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled = false,
  bool useSafeArea = false,
  Color? backgroundColor,
  bool? showDragHandle,
}) {
  final navigator = Navigator.of(context);
  return navigator.push(
    InteractionModalBottomSheetRoute<T>(
      builder: builder,
      capturedThemes: InheritedTheme.capture(
        from: context,
        to: navigator.context,
      ),
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      modalBarrierColor: Theme.of(context).bottomSheetTheme.modalBarrierColor,
      isScrollControlled: isScrollControlled,
      useSafeArea: useSafeArea,
      backgroundColor: backgroundColor,
      showDragHandle: showDragHandle,
    ),
  );
}

class InteractionModalBottomSheetRoute<T> extends ModalBottomSheetRoute<T>
    with InterruptibleRoute<T> {
  InteractionModalBottomSheetRoute({
    required super.builder,
    super.capturedThemes,
    super.barrierLabel,
    super.backgroundColor,
    super.elevation,
    super.shape,
    super.clipBehavior,
    super.constraints,
    super.modalBarrierColor,
    super.isDismissible,
    super.enableDrag,
    super.showDragHandle,
    required super.isScrollControlled,
    super.settings,
    super.transitionAnimationController,
    super.anchorPoint,
    super.useSafeArea,
    super.sheetAnimationStyle,
  });

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => wrapPredictiveBackForModalRoute(
    route: this,
    child: super.buildTransitions(
      context,
      animation,
      secondaryAnimation,
      child,
    ),
  );
}
