import 'dart:async';
import 'dart:io';

import 'package:app_icons/app_icons.dart';
import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:image/image.dart' as img;
import 'package:pro_image_editor/pro_image_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/models/topic.dart';
import 'package:fluxdo/pages/image_viewer_page.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/discourse_cache_manager.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/local_notification_service.dart'
    show navigatorKey;
import 'package:fluxdo/services/uploads/upload_progress.dart';
import 'package:fluxdo/widgets/post/image_reply_scope.dart';
import 'package:fluxdo/widgets/post/quote_image_scope.dart';

class _UploadService extends Fake implements DiscourseService {
  _UploadService({required this.failFirst});
  final bool failFirst;
  int attempts = 0;
  final uploaded = Completer<Uint8List>();
  @override
  Future<UploadResult> uploadImage(
    String filePath, {
    CancelToken? cancelToken,
    UploadProgressCallback? onProgress,
  }) async {
    attempts++;
    if (failFirst && attempts == 1) throw const HttpException('上传失败');
    uploaded.complete(await File(filePath).readAsBytes());
    return UploadResult(
      shortUrl: 'upload://edited.png',
      originalFilename: 'edited.png',
      width: 80,
      height: 60,
    );
  }
}

void main() {
  for (final failFirst in [false, true]) {
    testWidgets(
      failFirst ? '上传失败后保留编辑结果，直接重试并回复原楼层' : '从帖子图片打开编辑器，完成后上传并回到该楼层回复草稿',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(400, 800);
        addTearDown(tester.view.reset);
        const url = 'https://example.test/viewer-edit.png';
        final source = img.encodePng(img.Image(width: 80, height: 60));
        final edited = img.encodePng(
          img.Image(width: 80, height: 60)..setPixelRgb(10, 10, 255, 0, 0),
        );
        final directory = Directory.systemTemp.createTempSync(
          'fluxdo-edit-reply-',
        );
        const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          pathChannel,
          (_) async => directory.path,
        );
        await tester.runAsync(() async {
          await BlobImageCache.configureForTesting(root: directory);
          await BlobImageCache.write(
            BlobImageCache.originalBucket,
            url,
            source,
          );
        });
        addTearDown(() async {
          tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            pathChannel,
            null,
          );
          await BlobImageCache.configureForTesting();
          if (directory.existsSync()) directory.deleteSync(recursive: true);
        });
        final service = _UploadService(failFirst: failFirst);
        SharedPreferences.setMockInitialValues({'pref_dialog_blur': false});
        final prefs = await SharedPreferences.getInstance();
        final post = Post.fromJson({
          'id': 42,
          'post_number': 8,
          'username': 'user',
          'created_at': '2026-11-23T00:00:00Z',
          'updated_at': '2026-11-23T00:00:00Z',
        });
        final replies = <(String, Post)>[];
        late BuildContext sourceContext;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              sharedPreferencesProvider.overrideWithValue(prefs),
              discourseServiceProvider.overrideWithValue(service),
            ],
            child: TranslationProvider(
              child: MaterialApp(
                navigatorKey: navigatorKey,
                home: Scaffold(
                  body: QuoteImageScope(
                    handler: (text, target) => replies.add((text, target)),
                    child: ImageReplyScope(
                      post: post,
                      child: Builder(
                        builder: (context) {
                          sourceContext = context;
                          return TextButton(
                            onPressed: () => ImageViewerPage.open(context, url),
                            child: const Text('打开图片'),
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.runAsync(() async {
          await precacheImage(
            ResizeImage(
              discourseImageProvider(
                url,
                bucket: BlobImageCache.originalBucket,
              ),
              width: 2400,
              height: 2400,
              policy: ResizeImagePolicy.fit,
            ),
            sourceContext,
          );
        });
        await tester.tap(find.text('打开图片'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.byIcon(Symbols.more_vert_rounded));
        await tester.pumpAndSettle();
        expect(find.text('编辑图片并回复'), findsOneWidget);
        await tester.tap(find.text('编辑图片并回复'));
        for (
          var attempt = 0;
          attempt < 20 && find.byType(ProImageEditor).evaluate().isEmpty;
          attempt++
        ) {
          await tester.runAsync(() async {
            await Future<void>.delayed(const Duration(milliseconds: 50));
          });
          await tester.pump(const Duration(milliseconds: 50));
        }
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(ProImageEditor), findsOneWidget);
        final editor = tester.widget<ProImageEditor>(
          find.byType(ProImageEditor),
        );
        await editor.callbacks.onImageEditingComplete!(edited);
        if (failFirst) {
          for (
            var attempt = 0;
            attempt < 40 && service.attempts == 0;
            attempt++
          ) {
            await tester.pump(const Duration(milliseconds: 50));
            await tester.runAsync(() async {
              await Future<void>.delayed(const Duration(milliseconds: 25));
            });
          }
          for (var attempt = 0; attempt < 20; attempt++) {
            await tester.runAsync(() async {
              await Future<void>.delayed(const Duration(milliseconds: 25));
            });
            await tester.pump(const Duration(milliseconds: 50));
            if (find.byIcon(Symbols.more_vert_rounded).evaluate().isNotEmpty) {
              break;
            }
          }
          await tester.pump(const Duration(seconds: 6));
          await tester.pumpAndSettle();
          expect(replies, isEmpty);
          expect(find.byType(ImageViewerPage), findsOneWidget);
          await tester.tap(find.byIcon(Symbols.more_vert_rounded));
          await tester.pumpAndSettle();
          await tester.tap(find.text('编辑图片并回复'));
          await tester.pump();
          expect(find.byType(ProImageEditor), findsNothing);
        }
        for (
          var attempt = 0;
          attempt < 40 && !service.uploaded.isCompleted;
          attempt++
        ) {
          await tester.pump(const Duration(milliseconds: 50));
          await tester.runAsync(() async {
            await Future<void>.delayed(const Duration(milliseconds: 25));
          });
        }
        expect(service.uploaded.isCompleted, isTrue);
        expect(await service.uploaded.future, edited);
        await tester.pumpAndSettle();
        expect(find.byType(ImageViewerPage), findsNothing);
        expect(replies, [('![edited.png|80x60](upload://edited.png)\n', post)]);
        expect(service.attempts, failFirst ? 2 : 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
