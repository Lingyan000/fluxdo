import 'dart:ui';

/// Telegram 风格模糊效果参数
///
/// 参考 Telegram Android 源码：
/// - AlertDialog: setBackgroundBlurRadius(50), dimAlpha=0.5
/// - BottomSheet: dimBehindAlpha=51/255≈0.2
/// - BlurBehindDrawable: stackBlur(max(7, maxDim/180))
/// - CupertinoPopupSurface 默认 sigma=30
const blurSigma = 25.0;

/// 全屏模态背景采用逻辑像素，区别于局部玻璃的物理像素配方。
enum ModalBlurScene {
  sheet(18, 0.12, 0.24),
  dialog(25, 0.20, 0.32);

  const ModalBlurScene(this.sigma, this.lightDim, this.darkDim);
  final double sigma;
  final double lightDim;
  final double darkDim;
}

/// 饱和度增强系数（1.0 = 无变化，>1.0 增强饱和度）
///
/// Telegram 源码中有饱和度增强代码但未启用（TODO 状态），
/// 这里保留用以提升模糊后的色彩通透感。
const saturationBoost = 1.3;

/// 饱和度增强 ColorFilter（基于 BT.709 亮度系数）
final ColorFilter saturationFilter = () {
  const s = saturationBoost;
  const sr = (1 - s) * 0.2126;
  const sg = (1 - s) * 0.7152;
  const sb = (1 - s) * 0.0722;
  return ColorFilter.matrix(<double>[
    sr + s,
    sg,
    sb,
    0,
    0,
    sr,
    sg + s,
    sb,
    0,
    0,
    sr,
    sg,
    sb + s,
    0,
    0,
    0,
    0,
    0,
    1,
    0,
  ]);
}();

/// 创建模糊滤镜
///
/// 不叠加饱和度增强 —— `ColorFilter.matrix` 在低精度像素上运算
/// 会放大量化噪声，导致模糊画面出现可见噪点。
ImageFilter createBlurFilter(double sigma) {
  return ImageFilter.blur(
    sigmaX: sigma,
    sigmaY: sigma,
    tileMode: TileMode.mirror,
  );
}

/// 根据当前主题亮度返回模糊遮罩颜色
///
/// sigma=25 的模糊本身已足以模糊内容，遮罩只需提供轻微对比度。
/// 浅色模式使用低透明度遮罩，避免灰蒙蒙；深色模式稍高。
/// 参考 Telegram BottomSheet dimBehindAlpha=51/255≈0.2。
Color blurBarrierColor(Brightness brightness, {ModalBlurScene? scene}) {
  if (scene != null) {
    return const Color(0xFF000000).withValues(
      alpha: brightness == Brightness.dark ? scene.darkDim : scene.lightDim,
    );
  }
  return brightness == Brightness.dark
      ? const Color(0x47000000) // ~28% 黑
      : const Color(0x26000000); // ~15% 黑
}
