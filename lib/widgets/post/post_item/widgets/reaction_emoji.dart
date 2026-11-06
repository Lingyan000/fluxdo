import 'package:app_icons/app_icons.dart';
import 'package:flutter/material.dart';

import '../../../../services/avif_image_provider.dart';
import '../../../../services/discourse_cache_manager.dart';
import '../../../../services/dio_http_client.dart' show HttpStatusException;
import '../../../../services/emoji_handler.dart';

/// 本次运行内确认没有动态版(动态表情集 404)的表情,不再请求。
final Set<String> _staticOnlyReactions = {};

/// 动态表情解码上限(长边像素)。源图 128px,覆盖面板高亮放大后的物理尺寸。
///
/// **所有用处取同一个值**:provider 相等才共用同一个解码流 —— 面板槽位、
/// 飞回按钮的表情、按钮里的表情接力监听,动画连续播放,不会每换一处
/// 就从首帧重来。
const int _kAnimatedDecodeSize = 128;

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

/// 回应表情:静态图打底,需要播放时叠 Noto 动态表情。
///
/// 播放时机由调用方决定:
/// - [loop]:持续循环(面板高亮项、飞回按钮途中)
/// - [playOnMount]:挂载时播一遍(面板弹出)
/// - [playToken]:变化时播一遍,挂载时非 0 也播(按钮落地换上新表情)
///
/// 静止态是官方静态图而不是动图的某一帧 —— Noto 动画多从中性姿势起落
/// (😀/😄 首尾帧是 🙂、🎉 首尾帧是空礼花筒),定格首/尾帧会变成另一个
/// 表情。动图首帧到达后与静态图交叉淡化(已在播的解码流同步交付首帧,
/// 直接接上不淡入);停止时淡回静态图再卸载动图,解码器随监听者释放。
/// 动图有透明像素,显示期间静态图必须隐去,否则两层叠出重影。
class ReactionEmoji extends StatefulWidget {
  const ReactionEmoji({
    super.key,
    required this.reactionId,
    required this.size,
    this.loop = false,
    this.playOnMount = false,
    this.playToken = 0,
    this.fallbackIcon = Symbols.emoji_emotions_rounded,
  });

  final String reactionId;
  final double size;
  final bool loop;
  final bool playOnMount;
  final int playToken;

  /// 静态图加载失败时的占位图标
  final IconData fallbackIcon;

  @override
  State<ReactionEmoji> createState() => _ReactionEmojiState();
}

class _ReactionEmojiState extends State<ReactionEmoji> {
  static const _fadeDuration = Duration(milliseconds: 130);

  /// 正在播一遍(播满一圈后清除)
  late bool _oneShot = widget.playOnMount || widget.playToken != 0;

  /// 动图层是否挂载:开始播放即挂,停止后等淡出结束再卸
  bool _mounted = false;

  /// 动图层已收到首帧(未到首帧就停止时直接卸载,不等淡出)
  bool _hasFrame = false;

  /// 播一遍的终点已登记,避免同一圈重复调度
  bool _cycleEndScheduled = false;

  bool get _wantPlay => widget.loop || _oneShot;

  @override
  void didUpdateWidget(ReactionEmoji oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.reactionId != widget.reactionId) {
      // 换表情:动图层随 provider 一起换,帧序号从头数
      _mounted = false;
      _hasFrame = false;
      _cycleEndScheduled = false;
      _oneShot = false;
    }
    // 高亮移走:不再续播剩下的那一遍
    if (oldWidget.loop && !widget.loop) _oneShot = false;
    if (oldWidget.playToken != widget.playToken) {
      _oneShot = true;
      _cycleEndScheduled = false;
    }
  }

  /// 帧序号数满一圈(Image 的帧序号从开始监听算起,中途接上的解码流
  /// 也播满整整一圈)后结束这一遍
  void _onFrame(int frame, String url) {
    _hasFrame = true;
    if (!_oneShot || widget.loop || _cycleEndScheduled) return;
    final frameCount = AvifImageProvider.frameCountOf(url) ?? 1;
    if (frame < frameCount - 1) return;
    _cycleEndScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_cycleEndScheduled) return;
      setState(() {
        _oneShot = false;
        _cycleEndScheduled = false;
      });
    });
  }

  void _onFadeEnd() {
    if (!_wantPlay && _mounted) {
      setState(() {
        _mounted = false;
        _hasFrame = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final staticImage = _StaticReactionEmoji(
      reactionId: widget.reactionId,
      size: widget.size,
      fallbackIcon: widget.fallbackIcon,
    );
    final animatedUrl = MediaQuery.disableAnimationsOf(context)
        ? null
        : _animatedEmojiUrl(widget.reactionId);
    if (animatedUrl == null) return staticImage;

    if (_wantPlay) {
      _mounted = true;
    } else if (!_hasFrame) {
      // 首帧未到就停止:透明度没动过,不会有淡出 onEnd,直接卸载
      _mounted = false;
    }
    if (!_mounted) return staticImage;

    final playing = _wantPlay;
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: Image(
        image: AvifImageProvider(
          animatedUrl,
          bucket: BlobImageCache.emojiBucket,
          maxDimension: _kAnimatedDecodeSize,
        ),
        width: widget.size,
        height: widget.size,
        gaplessPlayback: true,
        frameBuilder: (context, child, frame, _) {
          if (frame != null) _onFrame(frame, animatedUrl);
          final show = frame != null && playing;
          return Stack(
            fit: StackFit.expand,
            children: [
              AnimatedOpacity(
                opacity: show ? 0 : 1,
                duration: _fadeDuration,
                child: staticImage,
              ),
              AnimatedOpacity(
                opacity: show ? 1 : 0,
                duration: _fadeDuration,
                onEnd: _onFadeEnd,
                child: child,
              ),
            ],
          );
        },
        errorBuilder: (_, error, _) {
          _onAnimatedEmojiError(widget.reactionId, error);
          return staticImage;
        },
      ),
    );
  }
}

class _StaticReactionEmoji extends StatelessWidget {
  const _StaticReactionEmoji({
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
