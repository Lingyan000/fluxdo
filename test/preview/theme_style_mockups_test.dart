import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fluxdo/providers/theme_provider.dart';
import 'package:fluxdo/services/fonts/font_catalog.dart';
import 'package:fluxdo/theme/app_theme.dart';
import 'package:fluxdo/theme/theme_registry.dart';
import 'package:fluxdo/theme/theme_resolver.dart';
import 'package:fluxdo/theme/theme_spec.dart';
import 'package:fluxdo/theme/theme_style.dart';
import 'package:fluxdo/widgets/common/paper_texture.dart';
import 'package:m3e_ui/m3e_ui.dart';

import '../helpers/preview_fonts.dart';

/// 界面风格效果图：THEME_PREVIEW_DIR=<目录> 时为每个主题 × 明暗导出一张
/// 「首页 / 帖子 / 设置」三联图。只用于视觉评审，平时不运行。
void main() {
  const dir = String.fromEnvironment('THEME_PREVIEW_DIR');

  final cases = [
    ('material', Brightness.light),
    ('minimal', Brightness.light),
    ('minimal', Brightness.dark),
    ('paper', Brightness.light),
    ('paper', Brightness.dark),
    ('terminal', Brightness.dark),
  ];

  for (final (id, brightness) in cases) {
    testWidgets('效果图 $id ${brightness.name}', (tester) async {
      if (dir.isEmpty) return;
      await tester.runAsync(_loadFonts);
      ThemeRegistry.setFixed([
        for (final f in Directory('assets/themes').listSync().whereType<File>())
          ThemeSpec.fromJson(
            jsonDecode(f.readAsStringSync()) as Map<String, dynamic>,
          ),
      ]);
      // 正文字体：本机中文字体以 MiSans 字族名注册，经主题装配传入
      FontCatalog.setAll(const [
        FontEntry(
          id: 'source-han-serif',
          family: 'Source Han Serif SC',
          slot: FontSlot.body,
          name: {'zh': '思源宋体'},
          license: '',
          package: '',
          version: '',
          file: '',
          size: 0,
          sha256: '',
          tarballSize: 0,
          tarballIntegrity: '',
        ),
        FontEntry(
          id: 'misans',
          family: 'MiSans',
          slot: FontSlot.body,
          name: {'zh': 'MiSans'},
          license: '',
          package: '',
          version: '',
          file: '',
          size: 0,
          sha256: '',
          tarballSize: 0,
          tarballIntegrity: '',
        ),
      ]);
      final spec = ThemeRegistry.byId(id);
      final state = ThemeState(
        mode: ThemeMode.system,
        seedColor: Colors.blue,
        themeId: id,
        bodyFont: 'misans',
        loadedFonts: const {'misans'},
      );
      final resolved = ThemeResolver.resolve(
        spec: spec,
        mode: ThemeMode.system,
        black: false,
        transparent: false,
        seed: state.effectiveSeedColor,
        variant: state.schemeVariant,
      );
      final light = brightness == Brightness.light;
      final theme = buildAppTheme(
        light ? resolved.light : resolved.dark,
        light ? resolved.lightColors : resolved.darkColors,
        state.effectiveShapes,
        state,
        fullscreenSwipeBack: false,
        transparent: false,
        style: spec.style,
      );
      if (spec.style.texture == TextureStyle.paper) {
        await tester.runAsync(() => PaperTexture.obtain(brightness));
      }

      tester.view.physicalSize = const Size(1290, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          home: RepaintBoundary(
            key: const ValueKey('sheet'),
            child: ColoredBox(
              color: light ? const Color(0xFFE6E6E6) : const Color(0xFF2A2A2A),
              child: Padding(
                padding: const EdgeInsets.all(30),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: const [
                    _Phone(child: _HomeScreen()),
                    _Phone(child: _PostScreen()),
                    _Phone(child: _SettingsScreen()),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(const ValueKey('sheet')),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File(
          '$dir/style_${id}_${brightness.name}.png',
        ).writeAsBytesSync(bytes!.buffer.asUint8List());
      });
      FontCatalog.setAll(const []);
      ThemeRegistry.setFixed(const []);
    });
  }
}

Future<void> _loadFonts() async {
  await loadPreviewCjkFont();
  Future<void> load(String family, String path) async {
    final file = File(path);
    if (!file.existsSync()) return;
    final bytes = file.readAsBytesSync();
    await (FontLoader(
      family,
    )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
  }

  await load('Songti SC', '/System/Library/Fonts/Supplemental/Songti.ttc');
  // 思源宋体：本地有缓存时按「已下载」效果出图
  await load(
    'Source Han Serif SC',
    Platform.environment['PREVIEW_SERIF_FONT'] ??
        '/tmp/preview-fonts/SourceHanSerifSC-VF.ttf',
  );
  await load('Menlo', '/System/Library/Fonts/Menlo.ttc');
  final manifest =
      jsonDecode(await rootBundle.loadString('FontManifest.json')) as List;
  for (final entry in manifest) {
    final family = entry['family'] as String;
    if (!family.contains('Material')) continue;
    final loader = FontLoader(family);
    for (final font in entry['fonts'] as List) {
      loader.addFont(rootBundle.load(font['asset'] as String));
    }
    await loader.load();
  }
}

/// 手机外框：390×780，页面背景按风格（纸张纹理）铺在页面内。
class _Phone extends StatelessWidget {
  const _Phone({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final paper = context.themeStyle.texture == TextureStyle.paper;
    return Container(
      width: 390,
      height: 820,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(36),
        border: Border.all(color: Colors.black.withValues(alpha: 0.4), width: 6),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(30),
        child: paper
            ? Stack(
                fit: StackFit.expand,
                children: [
                  PaperBackground(color: theme.colorScheme.surface),
                  Theme(
                    data: theme.copyWith(
                      scaffoldBackgroundColor: Colors.transparent,
                      appBarTheme: theme.appBarTheme.copyWith(
                        backgroundColor: Colors.transparent,
                      ),
                      navigationBarTheme: theme.navigationBarTheme.copyWith(
                        backgroundColor: Colors.transparent,
                      ),
                    ),
                    child: child,
                  ),
                ],
              )
            : child,
      ),
    );
  }
}

const _topics = [
  ('Flutter 3.47 升级后 Impeller 下的滚动掉帧排查记录', '整理了一下这次升级遇到的几个渲染问题，主要集中在列表快速滑动和图片解码……', '开发调优', Color(0xFF3AB54A), 42, 3, true),
  ('分享一个自用的 Rust 网络代理配置，开箱即用', '支持 DoH、ECH，配置文件附在楼下，有问题欢迎一起讨论。', '资源荟萃', Color(0xFF0E76BD), 18, 0, false),
  ('今天的晚霞好看吗', '下班路上随手拍的，没有调色。', '搞七捻三', Color(0xFFF7941D), 96, 12, true),
  ('求推荐适合长时间阅读的中文字体', '屏幕阅读为主，希望宋体或楷体，最好免费可商用。', '开发调优', Color(0xFF3AB54A), 27, 0, false),
];

class _HomeScreen extends StatelessWidget {
  const _HomeScreen();

  @override
  Widget build(BuildContext context) {
    final style = context.themeStyle;
    final cs = Theme.of(context).colorScheme;
    return DefaultTabController(
      length: 4,
      child: Scaffold(
        appBar: AppBar(
          leading: const Icon(Icons.menu_rounded),
          title: const Text('最新'),
          actions: const [
            Icon(Icons.search_rounded),
            SizedBox(width: 16),
            Icon(Icons.notifications_none_rounded),
            SizedBox(width: 16),
          ],
          bottom: const TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [
              Tab(text: '全部'),
              Tab(text: '开发调优'),
              Tab(text: '资源荟萃'),
              Tab(text: '搞七捻三'),
            ],
          ),
        ),
        body: ListView(
          padding: EdgeInsets.symmetric(
            horizontal: style.surfaces == SurfaceStyle.flat ? 0 : 12,
            vertical: 8,
          ),
          children: [
            for (final (i, t) in _topics.indexed)
              switch (style.surfaces) {
                SurfaceStyle.flat => Column(
                  children: [
                    if (i > 0) const Divider(indent: 16, endIndent: 16),
                    _TopicRow(t),
                  ],
                ),
                SurfaceStyle.outlined => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Card(child: _TopicRow(t)),
                ),
                SurfaceStyle.filled => Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Card(color: cs.surfaceContainerLow, child: _TopicRow(t)),
                ),
              },
          ],
        ),
        floatingActionButton: FloatingActionButton(
          onPressed: () {},
          child: const Icon(Icons.edit_outlined),
        ),
        bottomNavigationBar: M3eNavigationBar(
          selectedIndex: 0,
          onDestinationSelected: (_) {},
          destinations: const [
            NavigationDestination(icon: Icon(Icons.home_outlined), label: '首页'),
            NavigationDestination(icon: Icon(Icons.forum_outlined), label: '消息'),
            NavigationDestination(icon: Icon(Icons.explore_outlined), label: '发现'),
            NavigationDestination(icon: Icon(Icons.person_outline), label: '我的'),
          ],
        ),
      ),
    );
  }
}

class _TopicRow extends StatelessWidget {
  const _TopicRow(this.t);
  final (String, String, String, Color, int, int, bool) t;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final serif = context.themeStyle.titleFont == 'serif';
    final (title, excerpt, category, color, replies, unread, hot) = t;
    final titleStyle = theme.textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w600,
      height: 1.35,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 11,
                backgroundColor: color.withValues(alpha: 0.2),
                child: Text(
                  title.characters.first,
                  style: TextStyle(fontSize: 11, color: color),
                ),
              ),
              const SizedBox(width: 8),
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 5),
              Text(
                category,
                style: theme.textTheme.labelMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
              const Spacer(),
              if (unread > 0)
                Badge(
                  label: Text('$unread'),
                  backgroundColor: cs.primary,
                  textColor: cs.onPrimary,
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            title,
            style: serif ? theme.textTheme.titleLarge?.copyWith(fontSize: 17, height: 1.4) : titleStyle,
          ),
          const SizedBox(height: 4),
          Text(
            excerpt,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: cs.onSurfaceVariant,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '$replies 回复 · 3 分钟前${hot ? ' · 热' : ''}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: cs.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _PostScreen extends StatelessWidget {
  const _PostScreen();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final style = context.themeStyle;
    final body = theme.textTheme.bodyLarge?.copyWith(
      height: style.bodyLineHeight ?? 1.55,
      fontSize: 15.5,
    );
    final quote = style.quote == QuoteStyle.bar
        ? Container(
            padding: const EdgeInsets.fromLTRB(12, 2, 0, 2),
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: cs.primary.withValues(alpha: 0.75),
                  width: 2,
                ),
              ),
            ),
            child: Text(
              '字体选得好，阅读体验能提升一大截。屏幕上宋体要注意字重和行高。',
              style: body?.copyWith(color: cs.onSurfaceVariant),
            ),
          )
        : Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: cs.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '字体选得好，阅读体验能提升一大截。屏幕上宋体要注意字重和行高。',
              style: body?.copyWith(color: cs.onSurfaceVariant),
            ),
          );
    return Scaffold(
      appBar: AppBar(
        leading: const Icon(Icons.arrow_back),
        title: const Text('开发调优'),
        actions: const [Icon(Icons.more_horiz), SizedBox(width: 16)],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        children: [
          Text(
            '求推荐适合长时间阅读的中文字体',
            style: theme.textTheme.headlineSmall?.copyWith(height: 1.35),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              CircleAvatar(
                radius: 16,
                backgroundColor: cs.primaryContainer,
                child: Text('墨', style: TextStyle(color: cs.onPrimaryContainer)),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('mozi', style: theme.textTheme.titleSmall),
                  Text(
                    '2 小时前 · 一楼',
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: cs.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            '最近长时间在屏幕上读文档，眼睛有点吃不消。想找一款适合正文的中文字体，最好是宋体或楷体风格。',
            style: body,
          ),
          const SizedBox(height: 12),
          quote,
          const SizedBox(height: 16),
          Text('目前试过的', style: theme.textTheme.titleLarge?.copyWith(fontSize: 18)),
          const SizedBox(height: 8),
          Text.rich(
            TextSpan(
              style: body,
              children: [
                const TextSpan(text: '霞鹜文楷观感最好，但字重偏细；思源宋体在小字号下更清楚。详细对比见 '),
                TextSpan(
                  text: '这篇笔记',
                  style: TextStyle(
                    color: cs.primary,
                    decoration: TextDecoration.underline,
                    decorationColor: cs.primary.withValues(alpha: 0.4),
                  ),
                ),
                const TextSpan(text: '。'),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            children: [
              FilterChip(label: const Text('❤ 12'), selected: true, onSelected: (_) {}),
              FilterChip(label: const Text('👍 3'), selected: false, onSelected: (_) {}),
            ],
          ),
          const SizedBox(height: 20),
          const Divider(),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: InputDecoration(
                    hintText: '写下你的回复…',
                    isDense: true,
                    filled: style.inputs == InputStyle.filled,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              FilledButton(onPressed: () {}, child: const Text('发送')),
            ],
          ),
        ],
      ),
    );
  }
}

class _SettingsScreen extends StatelessWidget {
  const _SettingsScreen();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    Widget label(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
      child: Text(
        text,
        style: theme.textTheme.labelLarge?.copyWith(color: cs.onSurfaceVariant),
      ),
    );
    return Scaffold(
      appBar: AppBar(
        leading: const Icon(Icons.arrow_back),
        title: const Text('设置'),
      ),
      body: ListView(
        children: [
          label('通用'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedCardGroup(
              children: [
                SwitchListTile(
                  value: true,
                  onChanged: (_) {},
                  secondary: const Icon(Icons.dark_mode_outlined),
                  title: const Text('跟随系统深色模式'),
                ),
                ListTile(
                  leading: const Icon(Icons.translate),
                  title: const Text('语言'),
                  trailing: Text(
                    '简体中文',
                    style: TextStyle(color: cs.onSurfaceVariant),
                  ),
                ),
                SwitchListTile(
                  value: false,
                  onChanged: (_) {},
                  secondary: const Icon(Icons.play_circle_outline),
                  title: const Text('自动播放视频'),
                ),
              ],
            ),
          ),
          label('阅读'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedCardGroup(
              children: [
                const ListTile(
                  leading: Icon(Icons.format_size),
                  title: Text('正文字号'),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  child: Slider(value: 0.45, onChanged: (_) {}),
                ),
                ListTile(
                  leading: const Icon(Icons.view_agenda_outlined),
                  title: const Text('卡片密度'),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Wrap(
                      spacing: 8,
                      children: [
                        ChoiceChip(label: const Text('宽松'), selected: false, onSelected: (_) {}),
                        ChoiceChip(label: const Text('标准'), selected: true, onSelected: (_) {}),
                        ChoiceChip(label: const Text('紧凑'), selected: false, onSelected: (_) {}),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          label('个人资料'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const TextField(
                  decoration: InputDecoration(labelText: '昵称'),
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton(onPressed: () {}, child: const Text('保存')),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton(onPressed: () {}, child: const Text('取消')),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
