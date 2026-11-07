import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';

import '../../../../services/avif_image_provider.dart';
import '../../../../services/discourse_cache_manager.dart';
import '../../../../services/dio_http_client.dart' show HttpStatusException;
import '../../../../services/emoji_handler.dart';

/// 本次运行内确认没有动态版(动态表情集 404)的表情,不再请求。
final Set<String> _staticOnlyReactions = {};

/// 动态表情解码上限(长边像素),覆盖面板高亮放大后的物理尺寸。
///
/// **所有用处取同一个值**:provider 相等才共用同一个解码流 —— 面板槽位、
/// 飞回按钮的表情、按钮里的表情接力订阅,动画连续播放,不会每换一处
/// 就从首帧重来。
const int _kAnimatedDecodeSize = 128;

/// 静态图与动态表情互相溶解的总时长(两段各占一半)
const Duration _kDissolveDuration = Duration(milliseconds: 280);

/// 动态表情地址;无动态版、已确认缺图或展示表情集不是 Noto 时返回 null。
String? _animatedEmojiUrl(String reactionId) {
  if (_staticOnlyReactions.contains(reactionId)) return null;
  return EmojiHandler().animatedUrl(reactionId);
}

/// 动态表情取图失败:只有 404 才登记为无动态版(网络错误下次再试)。
void _onAnimatedEmojiError(String reactionId, Object error) {
  if (error is HttpStatusException && error.statusCode == 404) {
    _staticOnlyReactions.add(reactionId);
  }
}

/// 预取一组回应的动态表情字节:真正播放时动图已在本地,不用现场下载。
/// 只落缓存不解码。
void prefetchReactionAnimations(Iterable<String> reactionIds) {
  for (final id in reactionIds) {
    final url = _animatedEmojiUrl(id);
    if (url == null) continue;
    BlobImageCache.fetch(
      BlobImageCache.emojiBucket,
      url,
    ).then<void>((_) {}, onError: (Object e) => _onAnimatedEmojiError(id, e));
  }
}

/// 回应表情:静态图打底,需要时叠 Noto 动态表情。
///
/// 播放方式由调用方决定:
/// - [loop]:一直循环(面板里的表情、飞回按钮途中)
/// - [playToken]:变化时播一遍,挂载时非 0 也播(按钮落地换上新表情)
///
/// **静止态是官方静态图而不是动图的某一帧** —— Noto 动画多从中性姿势
/// 起落(实测 😀 首尾帧是 🙂、🎉 首尾帧是空礼花筒、❤️ 比静态图小一圈),
/// 定格首/尾帧会变成另一个表情。「播一遍」播到一圈的末帧定格,再溶回
/// 静态图;这一下姿势变化无法消除,只能溶解得平顺。
///
/// **溶解不掉亮度**:两层透明度此消彼长的交叉淡化,中点合成只剩约 75%
/// 不透明,看着是一闪。这里分两段 —— 先让要出现的一层长满,另一层再
/// 退,任一时刻总有一层完全不透明。动图有透明像素,显示期间静态图必须
/// 退掉,否则两层叠出重影。
///
/// **接力不断档**:订阅时解码流正在播放(别处正显示同一个表情),同步
/// 交付的当前帧直接显示、不溶解 —— 面板槽位 → 飞行 → 按钮一气呵成。
class ReactionEmoji extends StatefulWidget {
  const ReactionEmoji({
    super.key,
    required this.reactionId,
    required this.size,
    this.loop = false,
    this.playToken = 0,
    this.fallbackIcon = Symbols.emoji_emotions_rounded,
  });

  final String reactionId;
  final double size;
  final bool loop;
  final int playToken;

  /// 静态图加载失败时的占位图标
  final IconData fallbackIcon;

  @override
  State<ReactionEmoji> createState() => _ReactionEmojiState();
}

class _ReactionEmojiState extends State<ReactionEmoji>
    with SingleTickerProviderStateMixin {
  /// 动图层挂上/卸下时组件树结构会变;静态图带 GlobalKey 整体搬家,
  /// 不重建、不重新取图。
  final GlobalKey _staticKey = GlobalKey();

  /// 动态表情地址;null = 只显示静态图(自定义表情 / 无动态版 /
  /// 减弱动态效果 / 非 Noto 风格)
  String? _url;

  /// 取图失败:本组件不再重试,免得面板动画期间每帧重建都重发请求
  bool _failed = false;

  bool _tickerEnabled = true;

  /// 正在播一遍
  bool _oneShot = false;

  /// 动图层的解码流;null = 动图层未挂载
  ImageStream? _stream;
  bool _listening = false;

  /// 暂停收帧期间(收尾溶解、TickerMode 关闭)对解码流的保活句柄。
  /// 不保活的话,图片缓存若恰好清掉了它,最后一个监听者一退订流就被
  /// 释放,恢复收帧时再订阅会抛错(同 Image 组件的处理)。
  ImageStreamCompleterHandle? _keepAlive;

  /// 播完收尾:不再收帧,定格的末帧溶回静态图后卸下动图层
  bool _settling = false;

  final ValueNotifier<ImageInfo?> _frame = ValueNotifier<ImageInfo?>(null);

  /// 本次订阅以来收到的帧数
  int _framesSinceJoin = 0;

  /// 0 = 静态图,1 = 动态表情;动图层首次挂载时创建
  AnimationController? _reveal;
  late Animation<double> _animatedOpacity;
  late Animation<double> _staticOpacity;

  late final ImageStreamListener _listener = ImageStreamListener(
    _onFrame,
    onError: _onError,
  );

  bool get _wantPlay => _url != null && !_failed && (widget.loop || _oneShot);

  AvifPlaybackProgress? get _progress => switch (_stream?.completer) {
    final AvifPlaybackProgress progress => progress,
    _ => null,
  };

  @override
  void initState() {
    super.initState();
    _oneShot = widget.playToken != 0;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _tickerEnabled = TickerMode.valuesOf(context).enabled;
    _refresh();
  }

  @override
  void didUpdateWidget(ReactionEmoji oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reactionId != widget.reactionId) {
      _detach();
      _failed = false;
      _oneShot = false;
    }
    if (oldWidget.playToken != widget.playToken) {
      _oneShot = true;
      _framesSinceJoin = 0;
    }
    _refresh();
  }

  @override
  void dispose() {
    if (_listening) _stream?.removeListener(_listener);
    _keepAlive?.dispose();
    final frame = _frame.value;
    _frame.dispose();
    frame?.dispose();
    _reveal?.dispose();
    super.dispose();
  }

  /// 按当前配置挂载/卸下动图层、开始/停止收帧
  void _refresh() {
    final url = MediaQuery.disableAnimationsOf(context)
        ? null
        : _animatedEmojiUrl(widget.reactionId);
    if (url != _url) {
      _detach();
      _url = url;
    }
    if (_wantPlay) {
      // TickerMode 关闭时(在被盖住的路由里构建等)先不挂动图层,恢复再挂
      if (_stream == null && _tickerEnabled) {
        _ensureReveal();
        _stream = AvifImageProvider(
          url!,
          bucket: BlobImageCache.emojiBucket,
          maxDimension: _kAnimatedDecodeSize,
        ).resolve(ImageConfiguration.empty);
        _framesSinceJoin = 0;
      }
      if (_settling) {
        // 溶回静态图途中又要播:接着收帧,溶回动图
        _settling = false;
        _reveal!.forward();
      }
    } else if (_stream != null && !_settling) {
      _settle();
    }
    _updateListening();
  }

  void _ensureReveal() {
    if (_reveal != null) return;
    final reveal = AnimationController(
      vsync: this,
      duration: _kDissolveDuration,
    )..addStatusListener(_onRevealStatus);
    // 显现(0→1):前半段动图在静态图上长满,后半段静态图在动图下退掉;
    // 收尾(1→0)倒过来。两层不会同时半透明。
    _animatedOpacity = reveal.drive(
      CurveTween(curve: const Interval(0, 0.5, curve: Curves.easeInOut)),
    );
    _staticOpacity = reveal.drive(
      Tween<double>(begin: 1, end: 0).chain(
        CurveTween(curve: const Interval(0.5, 1, curve: Curves.easeInOut)),
      ),
    );
    _reveal = reveal;
  }

  /// 动图层挂载期间按需开始/暂停收帧(卸下由 [_detach] 负责)
  void _updateListening() {
    final stream = _stream;
    if (stream == null) return;
    final should = !_settling && _tickerEnabled;
    if (should == _listening) return;
    _listening = should;
    if (should) {
      // 解码流已有帧时会同步回调 _onFrame
      stream.addListener(_listener);
      _keepAlive?.dispose();
      _keepAlive = null;
    } else {
      _keepAlive ??= stream.completer?.keepAlive();
      stream.removeListener(_listener);
    }
  }

  void _onFrame(ImageInfo info, bool synchronousCall) {
    final progress = _progress;
    final live = progress?.isPlaying ?? false;
    // 暂停过的解码流同步交付的是暂停前的旧帧,紧接着从第 0 帧重解,不显示
    if (synchronousCall && !live && (progress?.frameCount ?? 2) > 1) {
      info.dispose();
      return;
    }
    final previous = _frame.value;
    _frame.value = info;
    previous?.dispose();
    _framesSinceJoin++;

    final reveal = _reveal!;
    if (previous == null && synchronousCall && live) {
      // 接上正在播放的解码流:直接显示,不溶解
      reveal.value = 1;
    } else if (reveal.status != AnimationStatus.forward && reveal.value < 1) {
      reveal.forward();
    }

    if (!synchronousCall &&
        _oneShot &&
        !widget.loop &&
        _reachedCycleEnd(progress)) {
      _oneShot = false;
      _settle();
      if (mounted) setState(() {});
    }
  }

  void _onError(Object error, StackTrace? stackTrace) {
    _onAnimatedEmojiError(widget.reactionId, error);
    _failed = true;
    if (mounted) setState(_detach);
  }

  /// 一圈的末帧,且本次订阅至少看了半圈(接力订阅时离末帧太近就再播一圈)
  bool _reachedCycleEnd(AvifPlaybackProgress? progress) {
    final count = progress?.frameCount;
    if (progress == null || count == null || count <= 1) return true;
    return progress.frameIndex == count - 1 && _framesSinceJoin * 2 >= count;
  }

  /// 收尾:停止收帧、定格当前帧,溶回静态图后卸下动图层
  void _settle() {
    final reveal = _reveal;
    if (_frame.value == null || reveal == null || reveal.value == 0) {
      // 首帧没到就停:没有可溶的,直接卸下
      _detach();
      return;
    }
    _settling = true;
    _updateListening();
    reveal.reverse();
  }

  void _onRevealStatus(AnimationStatus status) {
    if (status == AnimationStatus.dismissed && _settling && mounted) {
      setState(_detach);
    }
  }

  /// 卸下动图层:退订(最后一个监听者退订时解码器随之释放)、丢掉帧
  void _detach() {
    if (_listening) _stream?.removeListener(_listener);
    _listening = false;
    _keepAlive?.dispose();
    _keepAlive = null;
    _stream = null;
    _settling = false;
    _framesSinceJoin = 0;
    final frame = _frame.value;
    _frame.value = null;
    frame?.dispose();
    _reveal?.value = 0;
  }

  @override
  Widget build(BuildContext context) {
    final staticImage = _StaticReactionEmoji(
      key: _staticKey,
      reactionId: widget.reactionId,
      size: widget.size,
      fallbackIcon: widget.fallbackIcon,
    );
    if (_stream == null) return staticImage;

    final size = widget.size;
    final invertColors = MediaQuery.maybeInvertColorsOf(context) ?? false;
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        fit: StackFit.expand,
        children: [
          FadeTransition(opacity: _staticOpacity, child: staticImage),
          // 动图层只是装饰:命中测试交给底下的静态图,首帧未到时空的
          // RawImage 也不会把点击拦在它身上
          IgnorePointer(
            child: FadeTransition(
              opacity: _animatedOpacity,
              // 逐帧只重建这一个 RawImage
              child: ValueListenableBuilder<ImageInfo?>(
                valueListenable: _frame,
                builder: (context, info, _) => RawImage(
                  image: info?.image,
                  scale: info?.scale ?? 1,
                  width: size,
                  height: size,
                  fit: BoxFit.contain,
                  filterQuality: FilterQuality.medium,
                  invertColors: invertColors,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StaticReactionEmoji extends StatelessWidget {
  const _StaticReactionEmoji({
    super.key,
    required this.reactionId,
    required this.size,
    required this.fallbackIcon,
  });

  final String reactionId;
  final double size;
  final IconData fallbackIcon;

  @override
  Widget build(BuildContext context) {
    return Image(
      image: emojiImageProvider(EmojiHandler().getEmojiUrl(reactionId)),
      width: size,
      height: size,
      gaplessPlayback: true,
      errorBuilder: (_, _, _) => Icon(fallbackIcon, size: size * 0.9),
    );
  }
}
