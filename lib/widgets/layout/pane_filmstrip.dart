import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// 窄屏投影态的预测返回手势进度（0=原位，1=完全滑出）。
///
/// Android 预测返回手势由 PaneProjectionBackScope 认领后逐帧写入,
/// 正在投影的胶片带监听并把栈顶格向右拖出(露出的是真实的下一层/
/// 列表)。全局单份即可:同一时刻只有活跃 tab 的布局在投影且被 paint。
class PaneProjectionBack {
  PaneProjectionBack._();

  static final ValueNotifier<double> progress = ValueNotifier(0);

  /// 预测返回 commit 收尾:progress 已把顶格滑出屏,随后的清栈不能再
  /// 演一遍退栈动画(顶格会跳回原位再滑出)。清栈前置位,胶片带在
  /// 下一次结构变化时消费(一次性)→ 瞬切。
  static bool _suppressNextPaneSwitch = false;

  static void suppressNextPaneSwitch() => _suppressNextPaneSwitch = true;

  static bool consumeSuppressPaneSwitch() {
    final v = _suppressNextPaneSwitch;
    _suppressNextPaneSwitch = false;
    return v;
  }
}

/// 平行视界「胶片带」容器:一条水平带 `[master 格, 层1格, 层2格, …]`,
/// 每层内容**永久住在自己的格子里**(Element 恒驻、keyed),压/退栈 =
/// 视口沿带平移,格子永不换家。
///
/// 这是四轮层间动画翻车(双活体槽/快照编排/延帧防线)后的结构性答案:
/// 旧结构里内容要在 master/detail 两个槽之间交接(压栈时右栏话题"搬去"
/// 左栏预览位),任何让旧画面多活一会的机制都撞上这次交接——排版缓存
/// 单亲契约断言、OverlayPortal 布局期激活、快照揭示错位。胶片带没有
/// 交接:格子按 key 原地复用(与 PageView/Navigator 同款结构),出场格
/// 保留原实例在原格子演完滑出再移除,全程无第二份挂载、无 GlobalKey
/// 搬家、无占位重挂载、无快照。
///
/// 视口形态:
/// - 宽屏双栏(viewportPanes=2):露最后两格——倒二格即"上一层预览",
///   栈顶格即"详情";pinMaster=true 时 master 格钉死在左,层带只在右
///   格区内滑(PaneHost 系"列表+详情"形态)。
/// - 投影(viewportPanes=1):露最后一格,全宽路由式;master 格也在带
///   上(栈空时它就是视口内容)。
///
/// 附带治愈:压栈时"预览"不再销毁重建——就是原来的格子滑到左栏,
/// 滚动位置/视频/输入态全保。
///
/// 动画约定:
/// - 格子位置(left)按曲线插值;**宽度不逐帧插值**(渲染宽恒取目标宽,
///   跨栏时一次跳变被运动掩盖)——逐帧变宽会让内容(按宽算尺寸的图片
///   等)抖动式重排,且有按新宽重发请求的 429 风险(拖拽分隔线同款
///   教训,8px 量化注释)。
/// - z 序 = 格子插入序(LinkedHashMap):master 最先、层按 push 序 append,
///   栈顶天然画在最上;出场格保持原序,滑出时盖着下层——无需显式管理。
/// - 完全在视口外的格子 Offstage(不 paint,State 保留)+ 焦点/命中/
///   ticker/语义四关(布尔翻转,链型恒定)。
/// - 尺寸或视口形态变化(窗口 resize/宽窄切换)一律瞬切到位,不播动画。
class PaneFilmstrip extends StatefulWidget {
  const PaneFilmstrip({
    super.key,
    required this.master,
    required this.panes,
    required this.masterWidth,
    required this.viewportPanes,
    this.emptyPane,
    this.masterFillsWhenEmpty = false,
    this.pinMaster = true,
    this.dividerColor,
    this.animate = true,
    this.bandDrag,
    this.duration = const Duration(milliseconds: 300),
    this.curve = Curves.easeOutCubic,
  });

  /// master 格(列表)。pinMaster 时钉死在左栏;否则在带上参与滑动。
  final Widget master;

  /// 层格,每层一格,**每个必须有稳定 key**(层身份;换话题=换 key)。
  final List<Widget> panes;

  /// 右格区空态(栈空时可见),恒驻在所有格子之下。
  final Widget? emptyPane;

  /// true = 栈空时 master 格撑满视口(内容页自排版,无空态区);压栈
  /// 才收窄成左栏、新层从右滑入。适合"页面本身是内容、点开条目才
  /// 分栏"的宿主(用户资料页)。仅 unpinned 生效。
  final bool masterFillsWhenEmpty;

  /// true = master 格钉死左栏,层带只在右格区滑(PaneHost/profile);
  /// false = master 格也在带上,压栈时被顶出视口左侧(首页平行视界)。
  final bool pinMaster;

  /// 视口露几格:2=宽屏双栏,1=窄屏投影/单栏(全宽单格)。
  final int viewportPanes;

  final double masterWidth;
  /// 非空 = 在每个层格/空态的左缘画 1px 分隔线。线是格缘的一部分,
  /// 随格子平移(常显,与车厢一体);格子落位屏最左时不画。
  /// 投影模式恒不画。
  final Color? dividerColor;

  /// 逃生口:false 一律瞬切(结构收益与动画解耦)。
  final bool animate;

  /// 预测返回跟手(0~1):整条带向右拖,顶格拖出、下层格跟进。
  /// null = 不接。
  final ValueListenable<double>? bandDrag;

  final Duration duration;
  final Curve curve;

  @override
  State<PaneFilmstrip> createState() => _PaneFilmstripState();
}

class _Cell {
  _Cell({required this.widget, required this.from, required this.to});

  Widget widget;
  Rect from;
  Rect to;

  /// 退栈出场中:动画完成后从格子表移除。
  bool exiting = false;

  double leftAt(double t) => lerpDouble(from.left, to.left, t)!;
}

class _PaneFilmstripState extends State<PaneFilmstrip>
    with SingleTickerProviderStateMixin {
  static const Key masterCellKey = ValueKey('filmstrip-master');

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  );
  late final CurvedAnimation _anim = CurvedAnimation(
    parent: _controller,
    curve: widget.curve,
  );

  /// 带上所有格子(含 master 格与出场格)。插入序 = z 序(见类注释)。
  final _cells = <Key, _Cell>{};

  Size _lastSize = Size.zero;
  int _lastViewportPanes = 0;
  double _lastMasterWidth = 0;
  bool _kickScheduled = false;

  @override
  void initState() {
    super.initState();
    _controller.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        setState(() {
          _cells.removeWhere((_, cell) => cell.exiting);
          for (final cell in _cells.values) {
            cell.from = cell.to;
          }
        });
      }
    });
  }

  @override
  void dispose() {
    _anim.dispose();
    _controller.dispose();
    super.dispose();
  }

  /// 目标布局。带位置:master=0,层 i=i+1;栈顶带位置 = d。
  /// - 单格视口:带位置 p 的格在 (p-d)*V,全宽。
  /// - 双栏 unpinned:p==d 在右格区;p==d-1 在左栏 [0,mW);更左的依次
  ///   -(d-1-p)*mW。d==0 时 master 在左栏,右格区归空态。
  /// - 双栏 pinned:master 恒 [0,mW);层 i(带位置换算 p=i+1)——栈顶
  ///   在右格区,更早的在右格区左带外(rightLeft 往左按 rightW 排)。
  Map<Key, Rect> _targetLayout(Size size) {
    final layout = <Key, Rect>{};
    final v = size.width;
    final h = size.height;
    final mW = widget.masterWidth;
    final d = widget.panes.length;

    if (widget.viewportPanes <= 1) {
      layout[masterCellKey] = Rect.fromLTWH(-d * v, 0, v, h);
      for (var i = 0; i < d; i++) {
        layout[widget.panes[i].key!] =
            Rect.fromLTWH((i + 1 - d) * v, 0, v, h);
      }
      return layout;
    }

    final rightLeft = mW;
    final rightW = (v - rightLeft).clamp(0.0, v);

    if (widget.pinMaster) {
      layout[masterCellKey] = Rect.fromLTWH(0, 0, mW, h);
      for (var i = 0; i < d; i++) {
        layout[widget.panes[i].key!] = Rect.fromLTWH(
          rightLeft + (i - (d - 1)) * rightW,
          0,
          rightW,
          h,
        );
      }
      return layout;
    }

    // unpinned:带位置 p 相对栈顶(p==d)排布。
    Rect slotFor(int p) {
      if (d == 0) {
        // 栈空:master 在左栏,或撑满视口(masterFillsWhenEmpty,
        // 内容页自排版形态——压栈才收窄分栏)。
        return widget.masterFillsWhenEmpty
            ? Rect.fromLTWH(0, 0, v, h)
            : Rect.fromLTWH(0, 0, mW, h);
      }
      if (p == d) return Rect.fromLTWH(rightLeft, 0, rightW, h);
      return Rect.fromLTWH(-(d - 1 - p) * mW, 0, mW, h);
    }

    layout[masterCellKey] = slotFor(0);
    for (var i = 0; i < d; i++) {
      layout[widget.panes[i].key!] = slotFor(i + 1);
    }
    return layout;
  }

  /// 当前动画进度。挂帧等待窗口(_kickScheduled,已把 controller 归 0
  /// 但还没 forward)必须取 0(起点):这一两帧若兜底成 1.0,画面先闪
  /// 终态、起播后跳回起点重滑——肉眼即"抽搐"(第三层构建重时最明显)。
  double get _progress {
    if (_controller.isAnimating) return _anim.value;
    if (_kickScheduled) return 0.0;
    return 1.0;
  }

  void _syncCells(Size size, {required bool animateChanges}) {
    final targets = _targetLayout(size);
    final t = _progress;
    var structureChanged = false;
    // 带是否真的平移了:任何**既有**格子的目标位变化(压/退栈的列车
    // 运动)。false = 原位内容变化(空态上开首层/同深换话题)——这种
    // 场景整格从屏外飞入完全不符直觉,用轻量微移入场(见下)。
    var bandShifted = false;

    Rect currentRectOf(_Cell cell) => Rect.fromLTWH(
      cell.leftAt(t),
      cell.to.top,
      cell.to.width,
      cell.to.height,
    );

    // 第一遍:更新既有格(含 master),记录带是否平移;收集新格。
    final newcomers = <Key, Widget>{};
    void upsert(Key key, Widget content) {
      final target = targets[key]!;
      final cell = _cells[key];
      if (cell == null) {
        if (key == masterCellKey) {
          _cells[key] = _Cell(widget: content, from: target, to: target);
        } else {
          newcomers[key] = content;
        }
        return;
      }
      cell.widget = content;
      cell.exiting = false;
      if (cell.to != target) {
        cell.from = currentRectOf(cell);
        cell.to = target;
        structureChanged = true;
        bandShifted = true;
      }
    }

    upsert(masterCellKey, widget.master);
    final liveKeys = <Key>{masterCellKey};
    for (final pane in widget.panes) {
      assert(pane.key != null, 'PaneFilmstrip: 每个层格必须有稳定 key');
      liveKeys.add(pane.key!);
      upsert(pane.key!, pane);
    }

    // 第二遍:新格入场。两种语义:
    // - 带真平移(压栈列车,既有格目标位变了):从屏右外滑入同速;
    // - 布局没动(空态→首层/同深换话题=右栏内容切换):瞬切——占好
    //   的布局里换内容不该有位移动画(iPad 列表-详情惯例)。
    for (final entry in newcomers.entries) {
      final target = targets[entry.key]!;
      final enterFrom = bandShifted
          ? Rect.fromLTWH(size.width, 0, target.width, target.height)
          : target;
      _cells[entry.key] = _Cell(
        widget: entry.value,
        from: animateChanges ? enterFrom : target,
        to: target,
      );
      structureChanged = true;
    }

    // 第三遍:消失的层格。
    // - 原位替换(布局没动,同深换话题/被新首层顶掉):原地静置垫底,
    //   被新格盖住后随动画完成移除——旧滑出+新滑入的"双动"极怪;
    // - 退栈/清空(带平移或右栏收空):原实例原格子向右滑出。
    for (final entry in _cells.entries) {
      if (liveKeys.contains(entry.key) || entry.value.exiting) continue;
      final cell = entry.value;
      cell.exiting = true;
      final current = currentRectOf(cell);
      final replacedInPlace =
          !bandShifted && newcomers.keys.any((k) => targets[k] == cell.to);
      cell.from = current;
      cell.to = replacedInPlace
          ? current
          : Rect.fromLTWH(
              size.width,
              current.top,
              current.width,
              current.height,
            );
      structureChanged = true;
    }

    if (!animateChanges) {
      _cells.removeWhere((_, cell) => cell.exiting);
      for (final cell in _cells.values) {
        cell.from = cell.to;
      }
      return;
    }

    if (structureChanged && !_kickScheduled) {
      // 挂帧起播:变化帧先按 from(起点)静止渲染一帧——新层格的首次
      // 构建(可达百余毫秒)落在这一帧,动画时长不被吃;下一帧起跑。
      _kickScheduled = true;
      _controller.stop();
      _controller.value = 0;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _kickScheduled = false;
        if (!mounted) return;
        _controller.forward(from: 0);
      });
    } else if (structureChanged && _kickScheduled) {
      // 等待窗口内又来一轮结构变化(快速连按):新变化已并入各格
      // from/to,回调仍未跑,归零即可保持"从新起点完整起播"。
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        // 层格结构是否变化(压/退栈)——先判,下面几何判定要用。
        final structureDiffers =
            widget.panes.length != _cells.length - 1 ||
            widget.panes.any((p) => !_cells.containsKey(p.key));
        // 几何调整(窗口 resize/宽窄切换/拖分隔线改栏宽)一律瞬切:
        // 格子做 300ms 追赶会与已就位的新栏宽脱节,缝隙透 acrylic 底
        // (实测拖拽发透)。但**伴随层级变化的栏宽变化是导航的一部分**
        // (压/退栈时 preferredMasterRatio 0.25↔0.5 翻转),必须照常
        // 播带动画——只有"结构没变、纯栏宽变"才是拖拽。
        final formChanged =
            size != _lastSize ||
            widget.viewportPanes != _lastViewportPanes ||
            (!structureDiffers && widget.masterWidth != _lastMasterWidth);
        _lastSize = size;
        _lastViewportPanes = widget.viewportPanes;
        _lastMasterWidth = widget.masterWidth;
        // suppress:预测返回 commit 收尾的清栈,滑出已由手势演过,这次
        // 结构变化瞬切。只在层格结构真变时消费——无关 build 提前吃掉
        // 标记会让随后的清栈又演一遍滑出(顶格跳回重滑)。
        final suppressed =
            structureDiffers && PaneProjectionBack.consumeSuppressPaneSwitch();
        _syncCells(
          size,
          animateChanges: widget.animate && !formChanged && !suppressed,
        );

        final d = widget.panes.length;
        final projecting = widget.viewportPanes <= 1;
        final rightLeft =
            projecting ? 0.0 : widget.masterWidth;
        final topKey = d > 0 ? widget.panes.last.key : null;

        Widget band = AnimatedBuilder(
          animation: widget.bandDrag == null
              ? _anim
              : Listenable.merge([_anim, widget.bandDrag!]),
          builder: (context, _) {
            final t = _progress;
            // 预测返回跟手:只把栈顶格向右拖出(下层格静止,揭示的是
            // 真实的下一层/列表)。
            final dragDx = projecting
                ? (widget.bandDrag?.value ?? 0) * size.width
                : 0.0;
            // pinned 模式层带裁切在右格区:层格滑到带外时不得侵入
            // master 区(否则盖住列表)。unpinned/投影时全视口。
            final clipLeft = widget.pinMaster && !projecting ? rightLeft : 0.0;

            final masterChildren = <Widget>[];
            // 空态只在栈空或出场动画期挂载(退栈到空要被"揭示"),
            // 有层格的稳态不构建——空态组件可能依赖 l10n 等上层环境,
            // 与旧行为(detail 非空不建空态)保持一致。
            // masterFillsWhenEmpty(unpinned)形态恒不挂空态:栈空 =
            // master 撑满自排版,退栈到空揭示的也是全宽 master——
            // 空态挂上去会盖住 master 的右半边(实测截图踩中)。
            final fillsInsteadOfEmpty =
                widget.masterFillsWhenEmpty && !widget.pinMaster;
            final needEmpty = d == 0 || _cells.values.any((c) => c.exiting);
            final showEmpty = widget.emptyPane != null &&
                !projecting &&
                needEmpty &&
                !fillsInsteadOfEmpty;
            final paneChildren = <Widget>[
              if (showEmpty)
                Positioned(
                  key: const ValueKey(('filmstrip-cell', 'empty')),
                  left: rightLeft - clipLeft,
                  top: 0,
                  bottom: 0,
                  width: (size.width - rightLeft).clamp(0.0, size.width),
                  child: _inertWrap(inert: d > 0, child: widget.emptyPane!),
                ),
            ];
            // 接缝计算面(带坐标,按绘制序=遮挡序):空态最底,层格按
            // 插入序其上。分隔线不属于任何格子——每帧在"实际可见的
            // 接缝"处独立补画(见下),被上层格盖住的边缘不画线。
            final surfaces = <({double left, double right})>[
              if (showEmpty) (left: rightLeft, right: size.width),
            ];

            for (final entry in _cells.entries) {
              final cell = entry.value;
              final isMaster = entry.key == masterCellKey;
              var left = cell.leftAt(t);
              if (dragDx != 0 && entry.key == topKey) left += dragDx;
              final width = cell.to.width;
              final zoneLeft = isMaster ? 0.0 : clipLeft;
              final visible =
                  left + width > zoneLeft && left < size.width;
              final interactive = !cell.exiting && visible;
              final positioned = Positioned(
                // Stack 子项必须带 key:空态/新格插入会改变列表结构,
                // 无 key 时按位置+类型匹配,格子内容 key 对不上 →
                // Element 重建丢 State(实测踩中)。
                key: ValueKey(('filmstrip-cell', entry.key)),
                left: left - (isMaster ? 0.0 : clipLeft),
                top: 0,
                bottom: 0,
                width: width,
                child: Offstage(
                  offstage: !visible,
                  child: _inertWrap(
                    inert: !interactive,
                    child: RepaintBoundary(
                      child: KeyedSubtree(key: entry.key, child: cell.widget),
                    ),
                  ),
                ),
              );
              if (isMaster) {
                masterChildren.add(positioned);
              } else {
                paneChildren.add(positioned);
                if (visible) surfaces.add((left: left, right: left + width));
              }
            }

            // 分隔线:每帧按格子的**实际渲染位置**画在暴露的接缝上,
            // 盖在所有格子之上、随格移动。格缘被更上层的格覆盖时该
            // 处没有接缝,不画——"线钉在被盖住的静止层上劈开画面"
            // (空态/带外格的历史 bug 族)从构造上不可能。屏最左(≤0.5)
            // 是屏边不是接缝,不画。
            if (widget.dividerColor != null && !projecting) {
              for (var i = 0; i < surfaces.length; i++) {
                final x = surfaces[i].left;
                if (x <= 0.5) continue;
                var exposed = true;
                for (var j = i + 1; j < surfaces.length; j++) {
                  if (surfaces[j].left <= x && surfaces[j].right > x) {
                    exposed = false;
                    break;
                  }
                }
                if (!exposed) continue;
                paneChildren.add(
                  Positioned(
                    key: ValueKey(('filmstrip-seam', i)),
                    left: x - clipLeft,
                    top: 0,
                    bottom: 0,
                    width: 1,
                    child: IgnorePointer(
                      child: ColoredBox(color: widget.dividerColor!),
                    ),
                  ),
                );
              }
            }

            return ClipRect(
              child: ColoredBox(
                // 带底兜底铺色:格子运动/几何调整的任何瞬时缝隙都不
                // 透出窗口底(桌面 acrylic 半透明,露底=发透+水印)。
                color: Theme.of(context).scaffoldBackgroundColor,
                child: Stack(
                  children: [
                    ...masterChildren,
                    Positioned(
                      left: clipLeft,
                      top: 0,
                      bottom: 0,
                      width: (size.width - clipLeft).clamp(0.0, size.width),
                      child: ClipRect(
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: paneChildren,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
        return band;
      },
    );
  }

  Widget _inertWrap({required bool inert, required Widget child}) {
    return ExcludeFocus(
      excluding: inert,
      child: ExcludeSemantics(
        excluding: inert,
        child: IgnorePointer(
          ignoring: inert,
          child: TickerMode(enabled: !inert, child: child),
        ),
      ),
    );
  }
}
