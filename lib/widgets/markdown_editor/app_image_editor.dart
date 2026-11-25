import 'package:common_ui/common_ui.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pro_image_editor/pro_image_editor.dart';

import 'image_editor_i18n_zh.dart';

Future<Uint8List?> showAppImageEditor(
  BuildContext context, {
  required Uint8List bytes,
  OutputFormat outputFormat = OutputFormat.png,
}) => Navigator.of(context).push<Uint8List>(
  InteractionPageRoute(
    builder: (editorContext) => ProImageEditor.memory(
      bytes,
      callbacks: ProImageEditorCallbacks(
        onImageEditingComplete: (result) async {
          if (editorContext.mounted) Navigator.of(editorContext).pop(result);
        },
      ),
      configs: ProImageEditorConfigs(
        i18n: buildImageEditorI18nZh(),
        imageGeneration: ImageGenerationConfigs(
          outputFormat: outputFormat,
          maxOutputSize: const Size(1920, 1920),
        ),
      ),
    ),
  ),
);
