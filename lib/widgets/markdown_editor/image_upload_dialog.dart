import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:pro_image_editor/pro_image_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/toast_service.dart';
import '../../utils/dialog_utils.dart';
import 'image_compression_strategy.dart';
import 'image_editor_i18n_zh.dart';
import '../../../../../l10n/s.dart';

/// 图片上传确认弹框结果
class ImageUploadResult {
  /// 处理后的图片路径
  final String path;

  /// 原始文件名
  final String originalName;

  ImageUploadResult({required this.path, required this.originalName});
}

/// 图片上传确认弹框
class ImageUploadDialog extends StatefulWidget {
  final String imagePath;
  final String? imageName;

  const ImageUploadDialog({
    super.key,
    required this.imagePath,
    this.imageName,
  });

  @override
  State<ImageUploadDialog> createState() => _ImageUploadDialogState();
}

class _ImageUploadDialogState extends State<ImageUploadDialog> {
  static const _qualityPreferenceKey = 'markdown_editor.image_upload_quality';

  late String _currentImagePath;
  late ImageCompressionStrategy _compressionStrategy;
  int _quality = 85;
  int? _originalSize;
  int? _estimatedSize;
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    _currentImagePath = widget.imagePath;
    _compressionStrategy = ImageCompressionStrategyFactory.fromPath(widget.imagePath);
    _restoreQualityPreference();
  }

  Future<void> _restoreQualityPreference() async {
    final prefs = await SharedPreferences.getInstance();
    final savedQuality = prefs.getInt(_qualityPreferenceKey);
    if (!mounted) return;
    if (savedQuality != null) {
      setState(() {
        _quality = savedQuality.clamp(10, 100).toInt();
      });
    }
    await _loadImageInfo();
  }

  Future<void> _saveQualityPreference(int quality) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_qualityPreferenceKey, quality);
  }

  Future<void> _loadImageInfo() async {
    final file = File(_currentImagePath);
    if (await file.exists()) {
      final size = await file.length();
      final estimatedSize = _compressionStrategy.estimateCompressedSize(size, _quality);
      if (!mounted) return;
      setState(() {
        _originalSize = size;
        _estimatedSize = estimatedSize;
      });
    }
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  Future<void> _editImage() async {
    if (!_compressionStrategy.canEdit) {
      ToastService.showError(S.current.imageUpload_editNotSupported(_compressionStrategy.displayName));
      return;
    }

    final result = await Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(
        builder: (context) => ProImageEditor.file(
          File(_currentImagePath),
          callbacks: ProImageEditorCallbacks(
            onImageEditingComplete: (Uint8List bytes) async {
              Navigator.of(context).pop(bytes);
            },
          ),
          configs: ProImageEditorConfigs(
            i18n: buildImageEditorI18nZh(),
            imageGeneration: ImageGenerationConfigs(
              outputFormat: _editorOutputFormat,
              maxOutputSize: Size(1920, 1920),
            ),
          ),
        ),
      ),
    );

    if (result != null && mounted) {
      // 保存编辑后的图片到临时文件
      final tempDir = await getTemporaryDirectory();
      final editedPath = p.join(
        tempDir.path,
        'edited_${DateTime.now().millisecondsSinceEpoch}.$_editorExtension',
      );
      await File(editedPath).writeAsBytes(result);

      setState(() {
        _currentImagePath = editedPath;
        _compressionStrategy = ImageCompressionStrategyFactory.fromPath(editedPath);
      });
      await _loadImageInfo();
    }
  }

  OutputFormat get _editorOutputFormat {
    if (p.extension(_currentImagePath).toLowerCase() == '.png') {
      return OutputFormat.png;
    }
    return OutputFormat.jpg;
  }

  String get _editorExtension => _editorOutputFormat == OutputFormat.png ? 'png' : 'jpg';

  Future<String> _compressImage() async {
    return _compressionStrategy.compress(_currentImagePath, _quality);
  }

  Future<void> _submit() async {
    setState(() => _isProcessing = true);

    try {
      await _saveQualityPreference(_quality);
      final compressedPath = await _compressImage();

      if (!mounted) return;

      Navigator.of(context).pop(ImageUploadResult(
        path: compressedPath,
        originalName: widget.imageName ?? p.basename(widget.imagePath),
      ));
    } catch (e) {
      if (!mounted) return;
      ToastService.showError(S.current.imageUpload_processFailed(e.toString()));
      setState(() => _isProcessing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Text(S.current.imageUpload_confirmTitle),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 图片预览
            Container(
              height: 200,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              clipBehavior: Clip.antiAlias,
              child: Image.file(
                File(_currentImagePath),
                fit: BoxFit.contain,
                errorBuilder: (context, error, stackTrace) {
                  return Center(
                    child: Icon(
                      Icons.broken_image_outlined,
                      size: 48,
                      color: theme.colorScheme.outline,
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 16),

            if (!_compressionStrategy.supportsCompression)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  S.current.imageUpload_keepOriginal(_compressionStrategy.displayName),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ),

            // 压缩质量滑块
            Row(
              children: [
                Text(S.current.imageUpload_compressionQuality, style: theme.textTheme.bodyMedium),
                Expanded(
                  child: Slider(
                    value: _quality.toDouble(),
                    min: 10,
                    max: 100,
                    divisions: 18,
                    label: '$_quality%',
                    onChangeEnd: _isProcessing || !_compressionStrategy.supportsCompression
                        ? null
                        : (value) => _saveQualityPreference(value.round()),
                    onChanged: _isProcessing || !_compressionStrategy.supportsCompression
                        ? null
                        : (value) {
                          final nextQuality = value.round();
                          setState(() {
                            _quality = nextQuality;
                            if (_originalSize != null) {
                              _estimatedSize = _compressionStrategy.estimateCompressedSize(
                                _originalSize!,
                                nextQuality,
                              );
                            }
                          });
                        },
                  ),
                ),
                SizedBox(
                  width: 48,
                  child: Text(
                    '$_quality%',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),

            // 文件大小信息
            if (_originalSize != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    Icon(
                      Icons.photo_size_select_large,
                      size: 16,
                      color: theme.colorScheme.outline,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      S.current.imageUpload_originalSize(_formatFileSize(_originalSize!)),
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.outline,
                      ),
                    ),
                    if (_compressionStrategy.supportsCompression &&
                        _quality < 100 &&
                        _estimatedSize != null) ...[
                      const SizedBox(width: 8),
                      Icon(
                        Icons.arrow_forward,
                        size: 14,
                        color: theme.colorScheme.outline,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        S.current.imageUpload_estimatedSize(_formatFileSize(_estimatedSize!)),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ],
                ),
              ),

            const SizedBox(height: 8),

            // 编辑图片按钮
            OutlinedButton.icon(
              onPressed: _isProcessing || !_compressionStrategy.canEdit ? null : _editImage,
              icon: const Icon(Icons.edit),
              label: Text(_compressionStrategy.canEdit ? S.current.imageUpload_editImage : S.current.imageUpload_editNotSupportedLabel),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isProcessing ? null : () => Navigator.of(context).pop(),
          child: Text(S.current.common_cancel),
        ),
        FilledButton(
          onPressed: _isProcessing ? null : _submit,
          child: _isProcessing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(S.current.common_upload),
        ),
      ],
    );
  }
}

/// 显示图片上传确认弹框
Future<ImageUploadResult?> showImageUploadDialog(
  BuildContext context, {
  required String imagePath,
  String? imageName,
}) {
  return showAppDialog<ImageUploadResult>(
    context: context,
    barrierDismissible: false,
    builder: (context) => ImageUploadDialog(
      imagePath: imagePath,
      imageName: imageName,
    ),
  );
}

/// 多图上传确认弹框中的单张图片信息
class _MultiImageItem {
  final String path;
  final String name;
  final ImageCompressionStrategy strategy;
  int? size;

  _MultiImageItem({
    required this.path,
    required this.name,
    required this.strategy,
  });
}

/// 多图上传确认弹框
class MultiImageUploadDialog extends StatefulWidget {
  final List<String> imagePaths;
  final List<String> imageNames;

  const MultiImageUploadDialog({
    super.key,
    required this.imagePaths,
    required this.imageNames,
  });

  @override
  State<MultiImageUploadDialog> createState() => _MultiImageUploadDialogState();
}

class _MultiImageUploadDialogState extends State<MultiImageUploadDialog> {
  static const _qualityPreferenceKey = 'markdown_editor.image_upload_quality';

  final List<_MultiImageItem> _items = [];
  int _quality = 85;
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    for (int i = 0; i < widget.imagePaths.length; i++) {
      final path = widget.imagePaths[i];
      _items.add(_MultiImageItem(
        path: path,
        name: widget.imageNames[i],
        strategy: ImageCompressionStrategyFactory.fromPath(path),
      ));
    }
    _restoreQualityPreference();
  }

  Future<void> _restoreQualityPreference() async {
    final prefs = await SharedPreferences.getInstance();
    final savedQuality = prefs.getInt(_qualityPreferenceKey);
    if (!mounted) return;
    if (savedQuality != null) {
      setState(() {
        _quality = savedQuality.clamp(10, 100).toInt();
      });
    }
    await _loadAllSizes();
  }

  Future<void> _loadAllSizes() async {
    for (final item in _items) {
      final file = File(item.path);
      if (await file.exists()) {
        item.size = await file.length();
      }
    }
    if (mounted) setState(() {});
  }

  Future<void> _saveQualityPreference(int quality) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_qualityPreferenceKey, quality);
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
  }

  int get _totalOriginalSize {
    int total = 0;
    for (final item in _items) {
      if (item.size != null) total += item.size!;
    }
    return total;
  }

  int get _totalEstimatedSize {
    int total = 0;
    for (final item in _items) {
      if (item.size != null) {
        total += item.strategy.estimateCompressedSize(item.size!, _quality);
      }
    }
    return total;
  }

  void _removeItem(int index) {
    if (_items.length <= 1) {
      ToastService.showInfo(S.current.imageUpload_keepAtLeastOne);
      return;
    }
    setState(() => _items.removeAt(index));
  }

  Future<void> _submit() async {
    setState(() => _isProcessing = true);

    try {
      await _saveQualityPreference(_quality);

      final results = <ImageUploadResult>[];
      for (final item in _items) {
        final compressedPath = await item.strategy.compress(item.path, _quality);
        results.add(ImageUploadResult(
          path: compressedPath,
          originalName: item.name,
        ));
      }

      if (!mounted) return;
      Navigator.of(context).pop(results);
    } catch (e) {
      if (!mounted) return;
      ToastService.showError(S.current.imageUpload_processFailed(e.toString()));
      setState(() => _isProcessing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Text(S.current.imageUpload_multiTitle(_items.length)),
      content: SizedBox(
        width: double.maxFinite,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 缩略图网格
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  crossAxisSpacing: 8,
                  mainAxisSpacing: 8,
                ),
                itemCount: _items.length,
                itemBuilder: (context, index) {
                  final item = _items[index];
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          color: theme.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        clipBehavior: Clip.antiAlias,
                        child: Image.file(
                          File(item.path),
                          fit: BoxFit.cover,
                          errorBuilder: (context, error, stackTrace) {
                            return Center(
                              child: Icon(
                                Icons.broken_image_outlined,
                                size: 24,
                                color: theme.colorScheme.outline,
                              ),
                            );
                          },
                        ),
                      ),
                      // 删除按钮
                      Positioned(
                        top: 2,
                        right: 2,
                        child: GestureDetector(
                          onTap: _isProcessing ? null : () => _removeItem(index),
                          child: Container(
                            padding: const EdgeInsets.all(2),
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: const Icon(
                              Icons.close,
                              size: 16,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                      // 文件大小标签
                      if (item.size != null)
                        Positioned(
                          bottom: 2,
                          left: 2,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black54,
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              _formatFileSize(item.size!),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                              ),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 16),

              // 压缩质量滑块
              Row(
                children: [
                  Text(S.current.imageUpload_compressionQuality, style: theme.textTheme.bodyMedium),
                  Expanded(
                    child: Slider(
                      value: _quality.toDouble(),
                      min: 10,
                      max: 100,
                      divisions: 18,
                      label: '$_quality%',
                      onChangeEnd: _isProcessing
                          ? null
                          : (value) => _saveQualityPreference(value.round()),
                      onChanged: _isProcessing
                          ? null
                          : (value) {
                              setState(() {
                                _quality = value.round();
                              });
                            },
                    ),
                  ),
                  SizedBox(
                    width: 48,
                    child: Text(
                      '$_quality%',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),

              // 总大小信息
              if (_totalOriginalSize > 0)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      Icon(
                        Icons.photo_size_select_large,
                        size: 16,
                        color: theme.colorScheme.outline,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        S.current.imageUpload_totalOriginalSize(_formatFileSize(_totalOriginalSize)),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.outline,
                        ),
                      ),
                      if (_quality < 100) ...[
                        const SizedBox(width: 8),
                        Icon(
                          Icons.arrow_forward,
                          size: 14,
                          color: theme.colorScheme.outline,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          S.current.imageUpload_totalEstimatedSize(_formatFileSize(_totalEstimatedSize)),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.primary,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),

              // ≥3 张自动 grid 提示
              if (_items.length >= 3)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    children: [
                      Icon(
                        Icons.grid_view_rounded,
                        size: 16,
                        color: theme.colorScheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          S.current.imageUpload_gridLayoutHint,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isProcessing ? null : () => Navigator.of(context).pop(),
          child: Text(S.current.common_cancel),
        ),
        FilledButton(
          onPressed: _isProcessing ? null : _submit,
          child: _isProcessing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(S.current.imageUpload_uploadCount(_items.length)),
        ),
      ],
    );
  }
}

/// 显示多图上传确认弹框
Future<List<ImageUploadResult>?> showMultiImageUploadDialog(
  BuildContext context, {
  required List<String> imagePaths,
  required List<String> imageNames,
}) {
  return showAppDialog<List<ImageUploadResult>>(
    context: context,
    barrierDismissible: false,
    builder: (context) => MultiImageUploadDialog(
      imagePaths: imagePaths,
      imageNames: imageNames,
    ),
  );
}
