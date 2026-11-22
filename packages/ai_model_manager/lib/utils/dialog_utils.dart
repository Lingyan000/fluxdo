import 'package:common_ui/common_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

typedef AiDialogPresenter = Future<T?> Function<T>({
  required BuildContext context,
  required WidgetBuilder builder,
});

typedef AiBottomSheetPresenter = Future<T?> Function<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool isScrollControlled,
  bool useSafeArea,
  Color? backgroundColor,
  bool? showDragHandle,
});

final aiDialogPresenterProvider = Provider<AiDialogPresenter>(
  (_) => showInteractionDialog,
);

final aiBottomSheetPresenterProvider = Provider<AiBottomSheetPresenter>(
  (_) => showInteractionBottomSheet,
);

Future<T?> showAppDialog<T>({
  required BuildContext context,
  required WidgetBuilder builder,
}) {
  final presenter = ProviderScope.containerOf(context, listen: false)
      .read(aiDialogPresenterProvider);
  return presenter<T>(context: context, builder: builder);
}

Future<T?> showAppBottomSheet<T>({
  required BuildContext context,
  required WidgetBuilder builder,
  bool useSafeArea = false,
}) {
  final presenter = ProviderScope.containerOf(context, listen: false)
      .read(aiBottomSheetPresenterProvider);
  return presenter<T>(
    context: context,
    builder: builder,
    isScrollControlled: true,
    useSafeArea: useSafeArea,
    backgroundColor: Colors.transparent,
    showDragHandle: false,
  );
}
