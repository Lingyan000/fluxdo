import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:app_icons/app_icons.dart';
import 'package:fluxdo/theme/app_theme.dart';
import 'package:fluxdo/theme/theme_registry.dart';
import 'package:fluxdo/theme/theme_resolver.dart';

import '../helpers/preview_fonts.dart';

import 'package:fluxdo/widgets/settings/settings_group_page.dart';
import 'package:fluxdo/widgets/markdown_editor/emoji_picker.dart';
import 'package:fluxdo/models/emoji.dart';
import 'package:fluxdo/models/user.dart';
import 'package:fluxdo/providers/emoji_provider.dart';
import 'package:fluxdo/pages/forum_preferences/status_dialog.dart';
import 'package:fluxdo/utils/time_utils.dart';
import 'package:fluxdo/services/local_notification_service.dart';

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:file_picker/file_picker.dart';
import 'package:fluxdo/services/discourse_cache_manager.dart';
import 'package:fluxdo/pages/forum_preferences/preference_controls.dart';
import 'package:fluxdo/widgets/common/cached_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/l10n/s.dart';
import 'package:fluxdo/pages/forum_preferences/forum_preferences_page.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/providers/core_providers.dart';
import 'package:fluxdo/services/discourse/discourse_service.dart';
import 'package:fluxdo/services/preloaded_data_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:m3e_ui/m3e_ui.dart';

void main() {
  const captureDir = String.fromEnvironment('PROFILE_CAPTURE_DIR');
  for (final width in [320.0, 390.0, 1000.0, 1400.0]) {
    testWidgets('原生设置 $width 保存失败保留输入，仅提交改动字段', (tester) async {
      if (captureDir.isNotEmpty) {
        await tester.runAsync(() async {
          await loadPreviewCjkFont();
          final manifest = jsonDecode(
            await rootBundle.loadString('FontManifest.json'),
          ) as List;
          for (final entry in manifest) {
            final family = entry['family'] as String;
            if (!family.contains('Material')) continue;
            final loader = FontLoader(family);
            for (final font in entry['fonts'] as List) {
              loader.addFont(rootBundle.load(font['asset'] as String));
            }
            await loader.load();
          }
        });
      }
      tester.view.physicalSize = Size(width, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({'pref_dialog_blur': false});
      final preferences = await SharedPreferences.getInstance();
      await tester.runAsync(() => ThemeRegistry.loadBuiltins());
      final themeState = ThemeState(
        themeId: width == 1400 ? 'terminal' : ThemeRegistry.materialId,
        mode: ThemeMode.system,
        seedColor: Colors.blue,
      );
      final resolved = ThemeResolver.resolve(
        spec: themeState.themeSpec,
        mode: ThemeMode.system,
        black: false,
        seed: themeState.seedColor,
        variant: themeState.schemeVariant,
      );
      final appTheme = buildAppTheme(
        (width == 390 || width == 1400) ? resolved.dark : resolved.light,
        (width == 390 || width == 1400)
            ? resolved.darkColors
            : resolved.lightColors,
        themeState.effectiveShapes,
        themeState,
        style: themeState.effectiveStyle,
        fullscreenSwipeBack: false,
        pageBackground: false,
      );
      FilePicker? previousPicker;
      try {
        previousPicker = FilePicker.platform;
      } catch (_) {}
      final picker = _ImagePicker();
      FilePicker.platform = picker;
      addTearDown(() {
        if (previousPicker != null) FilePicker.platform = previousPicker;
      });
      const backgroundUrl = 'https://example.com/preference-background.png';
      await tester.runAsync(() async {
        final codec = await ui.instantiateImageCodec(
          File('assets/images/icon_modern_preview.png').readAsBytesSync(),
        );
        final frame = await codec.getNextFrame();
        PaintingBinding.instance.imageCache.putIfAbsent(
          const BlobImageProvider(
            backgroundUrl,
            bucket: BlobImageCache.contentBucket,
          ),
          () => OneFrameImageStreamCompleter(
            Future.value(ImageInfo(image: frame.image)),
          ),
        );
        codec.dispose();
      });
      final user = <String, dynamic>{
        'id': 1,
        'username': 'tester',
        'system_avatar_template': backgroundUrl,
        'can_edit': true,
        'can_change_bio': true,
        'can_change_location': true,
        'can_change_website': true,
        'can_upload_profile_header': true,
        'can_upload_user_card_background': true,
        'profile_background_upload_url': '',
        'card_background_upload_url': backgroundUrl,
        'bio_raw': '原简介',
        'location': '原位置',
        'website': '',
        'date_of_birth': '2000-02-28',
        'can_mute_users': true,
        'muted_usernames': ['existing'],
        'status': {
          'emoji': 'coffee',
          'description': '原状态',
          'ends_at': '2027-01-01T09:00:00.000Z',
        },
        'user_option': {'hide_profile': false, 'future_option': 8},
      };
      await tester.runAsync(
        () => PreloadedDataService().hydrateFromHtml(
          '<meta id="data-discourse-setup"><script id="data-preloaded" type="application/json">${jsonEncode({
            'currentUser': {
              'id': 1,
              'username': 'tester',
              'status': user['status'],
            },
            'siteSettings': {'enable_user_status': true},
            'site': {'categories': []},
          })}</script>',
        ),
      );
      var failSave = true;
      var profileReads = 0;
      final payloads = <Map<String, dynamic>>[];
      final service = DiscourseService();
      final mock = InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.method == 'GET' && options.path == '/u/tester.json') {
            profileReads++;
          }
          Object data = {'user': user};
          if (options.path == '/u/search/users') {
            data = {
              'users': [
                {'username': 'alice', 'name': 'Alice'},
              ],
            };
          }
          if (options.path.endsWith('/emails.json')) {
            data = {'email': 'tester@example.com'};
          }
          if (options.path == '/user-status.json') {
            expect(options.method, anyOf('PUT', 'DELETE'));
            expect(options.extra['noRecovery'], true);
            final status = options.method == 'DELETE' ? null : options.data;
            payloads.add({'status': status});
            // 模拟状态已保存，但资料读取仍返回旧快照。
            handler.resolve(
              Response(
                requestOptions: options,
                data: failSave
                    ? {'success': false, 'error': '测试保存失败'}
                    : {'success': true},
              ),
            );
            return;
          }
          if (options.path.endsWith('/preferences/avatar/pick') && !failSave) {
            user['avatar_template'] = backgroundUrl;
          }
          if (options.method == 'PUT') {
            payloads.add(Map<String, dynamic>.from(options.data as Map));
            expect(options.extra['noRecovery'], true);
            if (!failSave && (options.data as Map).containsKey('status')) {
              user['status'] = options.data['status'];
            }
            data = failSave
                ? {'success': false, 'error': '测试保存失败'}
                : {'success': true};
          }
          handler.resolve(Response(requestOptions: options, data: data));
        },
      );
      service.dio.interceptors.insert(0, mock);
      addTearDown(() => service.dio.interceptors.remove(mock));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            sharedPreferencesProvider.overrideWithValue(preferences),
            emojiGroupsProvider.overrideWith(
              (ref) => Stream.value({
                'people': [Emoji(name: 'smile', url: '', group: 'people')],
              }),
            ),
          ],
          child: TranslationProvider(
            child: MaterialApp(
              navigatorKey: navigatorKey,
              theme: captureDir.isEmpty
                  ? appTheme
                  : appTheme.copyWith(
                      textTheme: appTheme.textTheme.apply(fontFamily: 'MiSans'),
                    ),
              builder: (context, child) => RepaintBoundary(
                key: const ValueKey('preferences-capture'),
                child: child!,
              ),
              locale: const Locale('zh'),
              supportedLocales: AppLocaleUtils.supportedLocales,
              localizationsDelegates: const [
                GlobalMaterialLocalizations.delegate,
                GlobalWidgetsLocalizations.delegate,
                GlobalCupertinoLocalizations.delegate,
              ],
              home: const ForumPreferencesPage(username: 'tester'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byIcon(Symbols.account_circle_rounded), findsOneWidget);
      expect(find.byIcon(Symbols.shield_rounded), findsOneWidget);
      expect(find.text('论坛界面'), findsNothing);
      expect(find.text('论坛导航'), findsNothing);
      await _capture(tester, captureDir, 'preferences-navigation-$width');
      await tester.tap(
        find.byKey(const ValueKey(ForumPreferenceSection.profile)),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      await tester.pump(const Duration(milliseconds: 40));
      final editor = find.byWidgetPredicate(
        (widget) =>
            widget is Scaffold &&
            widget.key ==
                const ValueKey((
                  'forum-preferences-editor',
                  ForumPreferenceSection.profile,
                )),
        skipOffstage: false,
      );
      if (width >= 860) {
        expect(
          tester
              .widget<Opacity>(
                find.byKey(const ValueKey('forum-preferences-opacity')),
              )
              .opacity,
          lessThan(1),
        );
      } else {
        expect(tester.getTopLeft(editor).dx, greaterThan(0));
      }
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(editor).dx,
        closeTo(width >= 860 ? 280 : 0, 0.1),
      );
      expect(find.byType(SettingsGroupPage), findsOneWidget);
      await _capture(tester, captureDir, 'preferences-$width');
      await tester.enterText(
        find.widgetWithText(TextFormField, '个人简介'),
        '修改后的简介',
      );
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();
      expect(payloads, [
        {'bio_raw': '修改后的简介'},
      ]);
      expect(find.text('修改后的简介'), findsOneWidget);
      failSave = false;
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();
      expect(payloads.last, {'bio_raw': '修改后的简介'});
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, '保存'))
            .onPressed,
        isNull,
      );
      expect(tester.takeException(), isNull);
      final imageSettings = find.byWidgetPredicate(
        (widget) =>
            widget is PreferenceControl &&
            widget.field.key == 'card_background_upload_url',
      );
      final profilePreview = find.byKey(
        const ValueKey('image-preview-user.profile_background_upload_url'),
      );
      final cardPreview = find.byKey(
        const ValueKey('image-preview-user.card_background_upload_url'),
      );
      final settingsScroll = find
          .descendant(
            of: find.byType(SettingsGroupPage),
            matching: find.byType(Scrollable),
          )
          .first;
      await tester.scrollUntilVisible(
        profilePreview,
        200,
        scrollable: settingsScroll,
      );
      await Scrollable.ensureVisible(
        tester.element(find.text('背景图片')),
        alignment: 0.12,
      );
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      final profileRect = tester.getRect(profilePreview);
      final cardRect = tester.getRect(cardPreview);
      expect(cardRect.size, profileRect.size);
      if (width >= 1000) {
        expect(cardRect.top, profileRect.top);
        expect(cardRect.left, greaterThan(profileRect.right));
      } else {
        expect(cardRect.left, profileRect.left);
        expect(cardRect.top, greaterThan(profileRect.bottom));
      }
      expect(
        tester
            .widget<CachedImage>(
              find.descendant(
                of: imageSettings,
                matching: find.byType(CachedImage),
              ),
            )
            .fit,
        BoxFit.contain,
      );
      await _capture(tester, captureDir, 'preferences-images-$width');
      await tester.ensureVisible(
        find.descendant(
          of: imageSettings,
          matching: find.widgetWithText(OutlinedButton, '更换图片'),
        ),
      );
      await tester.tap(
        find.descendant(
          of: imageSettings,
          matching: find.widgetWithText(OutlinedButton, '更换图片'),
        ),
      );
      await tester.pumpAndSettle();
      expect(picker.calls, 1);
      expect(
        tester.widget<PreferenceControl>(imageSettings).value,
        backgroundUrl,
      );
      picker.error = PlatformException(
        code: 'picker_failed',
        message: '图片选择失败',
      );
      await tester.tap(
        find.descendant(
          of: imageSettings,
          matching: find.widgetWithText(OutlinedButton, '更换图片'),
        ),
      );
      await tester.pumpAndSettle();
      expect(picker.calls, 2);
      expect(
        tester.widget<PreferenceControl>(imageSettings).value,
        backgroundUrl,
      );
      expect(find.textContaining('图片选择失败'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(
        find.descendant(of: imageSettings, matching: find.byTooltip('移除')),
      );
      await tester.pumpAndSettle();
      expect(tester.getSize(cardPreview), profileRect.size);
      expect(find.textContaining('图片选择失败'), findsNothing);
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();
      expect(payloads.last, {'card_background_upload_url': ''});
      await tester.scrollUntilVisible(
        find.widgetWithText(ListTile, '生日'),
        -200,
        scrollable: settingsScroll,
      );
      await Scrollable.ensureVisible(
        tester.element(find.widgetWithText(ListTile, '生日')),
        alignment: 0.5,
      );
      await tester.pumpAndSettle();
      expect(find.text('2000/2/28'), findsOneWidget);
      await tester.tap(find.widgetWithText(ListTile, '生日'));
      await tester.pumpAndSettle();
      expect(find.byType(DatePickerDialog), findsOneWidget);
      await tester.tap(find.text('29'));
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();
      expect(payloads.last, {'date_of_birth': '2000-02-29'});
      await tester.scrollUntilVisible(
        find.widgetWithText(M3eSwitchListTile, '隐藏公开资料与活动'),
        200,
        scrollable: settingsScroll,
      );
      await Scrollable.ensureVisible(
        tester.element(find.widgetWithText(M3eSwitchListTile, '隐藏公开资料与活动')),
        alignment: 0.5,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(M3eSwitchListTile, '隐藏公开资料与活动'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();
      expect(payloads.last, {'hide_profile': true});
      await tester.scrollUntilVisible(
        find.widgetWithText(TextFormField, '个人简介'),
        -200,
        scrollable: settingsScroll,
      );
      await tester.enterText(
        find.widgetWithText(TextFormField, '个人简介'),
        '尚未保存的简介',
      );
      await tester.pump();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.text('放弃未保存的修改？'), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(find.text('尚未保存的简介'), findsOneWidget);
      // 同一编辑实例跨越双栏断点，输入与选中分区保持一致。
      tester.view.physicalSize = Size(width >= 860 ? 390 : 1000, 850);
      await tester.pumpAndSettle();
      expect(find.text('尚未保存的简介'), findsOneWidget);
      tester.view.physicalSize = Size(width, 850);
      await tester.pumpAndSettle();
      if (width >= 860) {
        await tester.tap(
          find.byKey(const ValueKey(ForumPreferenceSection.account)),
        );
      } else {
        await tester.tap(find.byType(BackButton));
      }
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '确定'));
      await tester.pumpAndSettle();
      if (width < 860) {
        await tester.tap(
          find.byKey(const ValueKey(ForumPreferenceSection.account)),
        );
        await tester.pumpAndSettle();
      }
      picker.error = null;
      picker.path = File('assets/images/icon_modern_preview.png').absolute.path;
      final avatarChange = find.widgetWithText(OutlinedButton, '更换图片');
      await tester.ensureVisible(avatarChange);
      await tester.runAsync(
        () => precacheImage(
          FileImage(File(picker.path!)),
          tester.element(avatarChange),
        ),
      );
      final beforeAvatar = payloads.length;
      await tester.tap(avatarChange);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.widgetWithText(TextButton, '取消'));
      await tester.pumpAndSettle();
      expect(payloads.length, beforeAvatar);
      expect(find.byType(LoadingSpinner), findsNothing);
      picker.path = null;
      failSave = false;
      await tester.tap(find.widgetWithText(TextButton, '重置'));
      await tester.pumpAndSettle();
      expect(payloads.last, {'upload_id': 0, 'type': 'system'});
      final session = ProviderScope.containerOf(
        tester.element(find.byType(ForumPreferencesPage)),
      );
      final current = session.read(currentUserProvider).value!;
      expect(current.avatarTemplate, backgroundUrl);
      expect(
        PreloadedDataService().currentUserSync!['avatar_template'],
        backgroundUrl,
      );
      final statusRow = find.widgetWithText(ListTile, '用户状态');
      await tester.ensureVisible(statusRow);
      await tester.pumpAndSettle();
      await _capture(tester, captureDir, 'preferences-account-$width');
      final readsBeforeStatus = profileReads;
      await tester.tap(statusRow);
      await tester.pumpAndSettle();
      expect(find.byType(StatusDialog), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(StatusDialog),
          matching: find.byType(TextField),
        ),
        findsOneWidget,
      );
      await _capture(tester, captureDir, 'preferences-status-$width');
      await tester.tap(find.byTooltip('状态表情'));
      await tester.pumpAndSettle();
      expect(find.byType(EmojiPicker), findsOneWidget);
      tester
          .widget<EmojiPicker>(find.byType(EmojiPicker))
          .onEmojiSelected(Emoji(name: 'smile', url: '', group: 'people'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byType(StatusDialog),
          matching: find.byType(TextField),
        ),
        '已选择表情',
      );
      failSave = true;
      await tester.tap(
        find.descendant(
          of: find.byType(StatusDialog),
          matching: find.widgetWithText(FilledButton, '保存'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('已选择表情'), findsNWidgets(2));
      expect(payloads.last, {
        'status': {
          'emoji': 'smile',
          'description': '已选择表情',
          'ends_at': '2027-01-01T09:00:00.000Z',
        },
      });
      failSave = false;
      await tester.tap(find.widgetWithText(ListTile, '状态有效期'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('不自动清除'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(StatusDialog),
          matching: find.widgetWithText(FilledButton, '保存'),
        ),
      );
      await tester.pumpAndSettle();
      expect(payloads.last, {
        'status': {'emoji': 'smile', 'description': '已选择表情', 'ends_at': null},
      });
      expect(find.byType(StatusDialog), findsNothing);
      expect(profileReads, readsBeforeStatus);
      expect(
        find.descendant(of: statusRow, matching: find.text('已选择表情')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await session.read(currentUserProvider.notifier).updateIdentity(
        'tester',
        status: UserStatus(description: '外部修改', emoji: 'coffee'),
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: statusRow, matching: find.text('外部修改')),
        findsOneWidget,
      );
      await tester.tap(statusRow);
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(
          find.descendant(
            of: find.byType(StatusDialog),
            matching: find.byType(TextField),
          ),
        ).controller!.text,
        '外部修改',
      );
      await tester.tap(find.widgetWithText(TextButton, '移除'));
      await tester.pumpAndSettle();
      expect(payloads.last, {'status': null});
      await tester.tap(statusRow);
      await tester.pumpAndSettle();
      final statusSave = find.descendant(
        of: find.byType(StatusDialog),
        matching: find.widgetWithText(FilledButton, '保存'),
      );
      expect(tester.widget<FilledButton>(statusSave).onPressed, isNull);
      expect(find.widgetWithText(TextButton, '移除'), findsNothing);
      await tester.tap(find.widgetWithText(ActionChip, '专注中'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, '状态有效期'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('2 小时'));
      await tester.pumpAndSettle();
      await tester.tap(statusSave);
      await tester.pumpAndSettle();
      final savedStatus = payloads.last['status'] as Map;
      expect(savedStatus['description'], '专注中');
      expect(savedStatus['emoji'], 'headphones');
      final expiration = TimeUtils.parseUtcTime(
        savedStatus['ends_at'] as String,
      )!;
      expect(
        expiration.difference(DateTime.now()).inSeconds,
        inInclusiveRange(7190, 7200),
      );
      if (width < 860) {
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
      }
      final usersSection = find.byKey(
        const ValueKey(ForumPreferenceSection.users),
      );
      await tester.ensureVisible(usersSection);
      await tester.tap(usersSection);
      await tester.pumpAndSettle();
      expect(find.widgetWithText(InputChip, '@existing'), findsOneWidget);
      await tester.tap(find.byTooltip('添加'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'ali');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      await tester.tap(find.text('alice'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '添加'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(InputChip, '@alice'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '保存'));
      await tester.pumpAndSettle();
      expect(payloads.last, {'muted_usernames': 'existing,alice'});
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }
}

Future<void> _capture(WidgetTester tester, String dir, String name) async {
  if (dir.isEmpty) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('preferences-capture')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    Directory(dir).createSync(recursive: true);
    File('$dir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

class _ImagePicker extends FilePicker {
  int calls = 0;
  Object? error;
  String? path;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    void Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    calls++;
    expect(type, FileType.image);
    if (error != null) throw error!;
    return path == null
        ? null
        : FilePickerResult([
            PlatformFile(name: 'avatar.png', size: 0, path: path),
          ]);
  }
}
