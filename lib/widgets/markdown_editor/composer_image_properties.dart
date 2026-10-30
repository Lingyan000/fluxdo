import 'package:flutter/material.dart';

Future<String?> showComposerAltEditor(BuildContext context, String initial) =>
    showDialog<String>(
      context: context,
      builder: (_) => _AltDialog(initial: initial),
    );

class _AltDialog extends StatefulWidget {
  const _AltDialog({required this.initial});
  final String initial;
  @override
  State<_AltDialog> createState() => _AltDialogState();
}

class _AltDialogState extends State<_AltDialog> {
  late final controller = TextEditingController(text: widget.initial);
  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('替代文本'),
    content: SizedBox(
      width: 400,
      child: TextField(
        key: const ValueKey('composer-image-alt-input'),
        controller: controller,
        autofocus: true,
        minLines: 2,
        maxLines: 4,
        decoration: const InputDecoration(
          hintText: '描述图片内容',
          border: OutlineInputBorder(),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () => Navigator.pop(context, controller.text.trim()),
        child: const Text('保存'),
      ),
    ],
  );
}
