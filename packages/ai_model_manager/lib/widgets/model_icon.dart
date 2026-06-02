import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:jovial_svg/jovial_svg.dart';

/// 模型/Provider 头像图标
///
/// 设计参考 Cherry Studio + Kelivo + lobe-icons：
/// 1. 优先匹配 brand asset（来自 [lobe-icons](https://github.com/lobehub/lobe-icons)，MIT）
///    - `-color.svg`：彩色变体，保留品牌原色，背景用中性色
///    - 单色 svg（fill=currentColor）：按 brand 色着色
///    - 极深色 brand（Grok / xAI / Ollama 等）反相为深底 + 白色 icon
/// 2. 没有匹配 brand 时 fallback 到首字母 + 哈希色
///
/// 同一名字的颜色稳定（hash 决定），便于视觉记忆。
class ModelIcon extends StatelessWidget {
  const ModelIcon({
    super.key,
    required this.providerName,
    required this.modelName,
    this.size = 28,
    this.withBackground = true,
  });

  final String providerName;
  final String modelName;
  final double size;
  final bool withBackground;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final colorSeed = modelName.trim().isEmpty ? providerName : modelName;
    final brand = _brandColor(colorSeed, isDark: isDark);
    final assetPath = _brandAsset(modelName, providerName);
    final isColorAsset = assetPath != null && assetPath.contains('-color.svg');

    // 三种渲染策略
    Color bgColor;
    ColorFilter? tint;
    Color letterColor = brand;
    if (assetPath == null) {
      // (1) Fallback：首字母 + brand 半透明背景
      bgColor = withBackground
          ? brand.withValues(alpha: isDark ? 0.25 : 0.15)
          : Colors.transparent;
    } else if (isColorAsset) {
      // (2) 彩色变体：保留原色 + 极浅 brand 背景。
      // alpha 取 0.08：足以让单色 -color SVG（DeepSeek/Claude）有点品牌感，
      // 又不会把渐变 -color SVG（Gemini/ChatGLM/Qwen）糊在背景里。
      bgColor = withBackground
          ? brand.withValues(alpha: isDark ? 0.18 : 0.08)
          : Colors.transparent;
      tint = null;
    } else {
      // (3) 单色变体：白色 icon + brand 实底"瓷砖"风（参考 Cherry Studio 的
      // 预绘制 brand 图片视觉），仅极浅 brand（Hugging Face 黄等）退回到
      // brand-on-light-tint 以保证对比度
      final lum = _luminance(brand);
      if (lum > 0.7) {
        // 极浅 brand：实底太浅看不清白 icon，回到 tint 模式
        bgColor = withBackground
            ? brand.withValues(alpha: isDark ? 0.3 : 0.2)
            : Colors.transparent;
        tint = ColorFilter.mode(brand, BlendMode.srcIn);
      } else {
        bgColor = withBackground ? brand : Colors.transparent;
        tint = const ColorFilter.mode(Colors.white, BlendMode.srcIn);
      }
    }

    Widget inner;
    if (assetPath != null) {
      final svgWidget = ScalableImageWidget.fromSISource(
        si: ScalableImageSource.fromSvg(
          rootBundle,
          assetPath,
          warnF: _silent,
        ),
      );
      inner = tint == null
          ? svgWidget
          : ColorFiltered(colorFilter: tint, child: svgWidget);
    } else {
      inner = Text(
        _firstLetter(colorSeed),
        style: TextStyle(
          color: letterColor,
          fontWeight: FontWeight.w600,
          fontSize: size * 0.46,
          height: 1.0,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      );
    }

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: bgColor,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: SizedBox(
        // logo 占容器 60%，留 padding 让圆形看起来不撑满
        width: size * 0.6,
        height: size * 0.6,
        child: Center(child: inner),
      ),
    );
  }

  static double _luminance(Color c) => c.computeLuminance();

  static void _silent(String _) {}

  static String _firstLetter(String s) {
    final trimmed = s.trim();
    if (trimmed.isEmpty) return '?';
    final lower = trimmed.toLowerCase();
    for (final prefix in const ['gpt-', 'claude-', 'gemini-', 'llama-']) {
      if (lower.startsWith(prefix)) {
        final rest = trimmed.substring(prefix.length).trim();
        if (rest.isNotEmpty) {
          return rest.characters.first.toUpperCase();
        }
      }
    }
    return trimmed.characters.first.toUpperCase();
  }

  /// 解析 brand asset：先匹配 modelName，再匹配 providerName
  static String? _brandAsset(String modelName, String providerName) {
    for (final candidate in [modelName, providerName]) {
      final lower = candidate.trim().toLowerCase();
      if (lower.isEmpty) continue;
      for (final entry in _assetMap.entries) {
        if (entry.key.hasMatch(lower)) return entry.value;
      }
    }
    return null;
  }

  /// model/provider name 正则 → brand asset 路径
  ///
  /// 优先用 lobe-icons 的 `-color` 彩色变体（视觉接近 Cherry Studio）；
  /// 没有彩色变体的回落到单色版（OpenAI / Anthropic / Grok / Ollama 等）。
  ///
  /// 顺序很重要：iter 时第一条命中即返回，所以**子品牌写在父品牌之前**
  /// （gemma 在 google 之前 / hunyuan 在 tencent 之前 / wenxin 在 baidu 之前
  ///  / dalle 在 openai 之前等）。同样 `grok` 必须在 `xai` 前面，避免被
  /// 通配抢匹配。
  static final Map<RegExp, String> _assetMap = {
    // ---- 子品牌（必须排在通用品牌前面）----
    RegExp(r'gemma'): 'assets/ai_brands/gemma-color.svg',
    RegExp(r'gemini|imagen'): 'assets/ai_brands/gemini-color.svg',
    RegExp(r'sora'): 'assets/ai_brands/sora-color.svg',
    RegExp(r'dall-?e'): 'assets/ai_brands/dalle-color.svg',
    // 文心系（含 tao- 系列嵌入模型）
    RegExp(r'wenxin|文心|^ernie|^tao-'): 'assets/ai_brands/wenxin-color.svg',
    RegExp(r'hunyuan|混元'): 'assets/ai_brands/hunyuan-color.svg',
    RegExp(r'longcat|龙猫|美团'): 'assets/ai_brands/longcat-color.svg',
    RegExp(r'spark|讯飞星火|星火'): 'assets/ai_brands/spark-color.svg',
    RegExp(r'baichuan|百川'): 'assets/ai_brands/baichuan-color.svg',
    RegExp(r'(?<![a-z])yi-|零一|^yi$'):
        'assets/ai_brands/yi-color.svg',
    // GLM / ChatGLM / CogView / Zhipu / embedding-3 全系用 Zhipu logo。
    // lobe-icons 的 chatglm 是新版猫脸 logo，识别度低；改用 Zhipu 公司主
    // logo（蓝紫菱形），各类 GLM 模型的识别度更高
    RegExp(r'chatglm|^glm|-glm|cogview|zhipu|智谱|^embedding-3'):
        'assets/ai_brands/zhipu-color.svg',
    RegExp(r'internlm|书生'): 'assets/ai_brands/internlm-color.svg',
    // 豆包系（含 seedream 图像、ep-202* 火山方舟 endpoint id）
    RegExp(r'doubao|豆包|seedream|^ep-202'):
        'assets/ai_brands/doubao-color.svg',
    // pixtral 是 Mistral 的视觉模型 → 走 mistral logo
    RegExp(r'pixtral'): 'assets/ai_brands/mistral-color.svg',
    // jamba- 是 AI21 的 SSM/Transformer 混合模型
    RegExp(r'^jamba|^ai21'): 'assets/ai_brands/ai21.svg',
    // CodeGeeX 是智谱团队的代码模型 → 用 chatglm logo (同团队)
    RegExp(r'codegeex'): 'assets/ai_brands/codegeex-color.svg',
    // InternVL 是上海 AI Lab 的多模态模型 → 用 internlm logo (同 lab)
    RegExp(r'internvl'): 'assets/ai_brands/internlm-color.svg',
    // LLaVA 视觉对话模型
    RegExp(r'llava'): 'assets/ai_brands/llava-color.svg',
    // Microsoft 系（Phi, WizardLM, Microsoft）
    RegExp(r'^phi|wizardlm|^microsoft'):
        'assets/ai_brands/microsoft-color.svg',
    // Databricks DBRX
    RegExp(r'dbrx|databricks'): 'assets/ai_brands/dbrx-color.svg',
    // Jina AI（embedding / reranker）
    RegExp(r'jina'): 'assets/ai_brands/jina.svg',
    // Voyage AI（embedding）
    RegExp(r'^voyage'): 'assets/ai_brands/voyage-color.svg',
    // Suno（音乐生成）
    RegExp(r'suno|chirp'): 'assets/ai_brands/suno.svg',
    // Luma（视频生成）
    RegExp(r'luma'): 'assets/ai_brands/luma-color.svg',
    // 可灵（快手）— 兼容 keling/kling 两种拼写
    RegExp(r'keling|kling|可灵'): 'assets/ai_brands/kling-color.svg',
    // Vidu（视频）
    RegExp(r'^vidu'): 'assets/ai_brands/vidu-color.svg',
    // 海螺（MiniMax 视频/语音）
    RegExp(r'hailuo|海螺'): 'assets/ai_brands/hailuo-color.svg',
    // Upstage Solar
    RegExp(r'upstage|solar'): 'assets/ai_brands/upstage-color.svg',
    // IBM Granite
    RegExp(r'^ibm|granite'): 'assets/ai_brands/ibm.svg',
    // ByteDance（generic 字节生态，独立于豆包/火山方舟）
    RegExp(r'^bytedance|字节跳动'): 'assets/ai_brands/bytedance-color.svg',
    // 魔搭社区 ModelScope
    RegExp(r'modelscope|魔搭'): 'assets/ai_brands/modelscope-color.svg',
    // ---- 主品牌（彩色变体）----
    RegExp(r'claude'): 'assets/ai_brands/claude-color.svg',
    RegExp(r'^google|bard|palm|vertex'): 'assets/ai_brands/google-color.svg',
    RegExp(r'deepseek'): 'assets/ai_brands/deepseek-color.svg',
    RegExp(r'qwen|qwq|qvq|tongyi|通义'): 'assets/ai_brands/qwen-color.svg',
    RegExp(r'^llama|(?<![a-z])llama(?![a-z])|(?<![a-z])meta(?![a-z])'):
        'assets/ai_brands/meta-color.svg',
    RegExp(r'mistral|mixtral|codestral'):
        'assets/ai_brands/mistral-color.svg',
    RegExp(r'huggingface|^hf-?'): 'assets/ai_brands/huggingface-color.svg',
    RegExp(r'perplexity|sonar'): 'assets/ai_brands/perplexity-color.svg',
    RegExp(r'kimi'): 'assets/ai_brands/kimi-color.svg',
    RegExp(r'volc|火山|bytedance|字节'):
        'assets/ai_brands/volcengine-color.svg',
    RegExp(r'minimax'): 'assets/ai_brands/minimax-color.svg',
    RegExp(r'^step|阶跃|stepfun'): 'assets/ai_brands/stepfun-color.svg',
    RegExp(r'cohere|command-?[a-z]?'): 'assets/ai_brands/cohere-color.svg',
    RegExp(r'silicon|硅基'): 'assets/ai_brands/siliconcloud-color.svg',
    RegExp(r'tencent|腾讯'): 'assets/ai_brands/tencent-color.svg',
    RegExp(r'baidu|百度'): 'assets/ai_brands/baidu-color.svg',
    RegExp(r'nvidia|nemotron'): 'assets/ai_brands/nvidia-color.svg',
    RegExp(r'^aws|bedrock'): 'assets/ai_brands/aws-color.svg',
    RegExp(r'azure'): 'assets/ai_brands/azure-color.svg',
    RegExp(r'together'): 'assets/ai_brands/together-color.svg',
    RegExp(r'fireworks'): 'assets/ai_brands/fireworks-color.svg',
    RegExp(r'stability|stable.?diffusion'):
        'assets/ai_brands/stability-color.svg',
    RegExp(r'^copilot|github.copilot'): 'assets/ai_brands/copilot-color.svg',
    // ---- 单色版 brand（走 tint / deep-brand 反相） ----
    RegExp(r'anthropic'): 'assets/ai_brands/anthropic.svg',
    // 阿里的 text-embedding-v* 必须在 OpenAI text-embedding 之前匹配
    RegExp(r'text-embedding-v|^bge-'): 'assets/ai_brands/qwen-color.svg',
    // OpenAI 全系（chat / o-series / 图像 / 音频 / embedding / 工具模型）
    RegExp(r'openai|^gpt|chatgpt|^o\d|gpt-image|whisper|^tts-|davinci|babbage|text-moderation|text-embedding|^omni-'):
        'assets/ai_brands/openai.svg',
    RegExp(r'ollama'): 'assets/ai_brands/ollama.svg',
    RegExp(r'openrouter'): 'assets/ai_brands/openrouter.svg',
    // grok 必须在 xai 之前；groq 跟 grok 是两个不同 brand
    RegExp(r'grok(?!q)'): 'assets/ai_brands/grok.svg',
    RegExp(r'groq'): 'assets/ai_brands/groq.svg',
    RegExp(r'xai|x-ai'): 'assets/ai_brands/xai.svg',
    RegExp(r'moonshot'): 'assets/ai_brands/moonshot.svg',
    RegExp(r'replicate'): 'assets/ai_brands/replicate.svg',
    RegExp(r'runway'): 'assets/ai_brands/runway.svg',
    RegExp(r'ideogram'): 'assets/ai_brands/ideogram.svg',
    RegExp(r'midjourney'): 'assets/ai_brands/midjourney.svg',
    RegExp(r'^flux|black.?forest'): 'assets/ai_brands/flux.svg',
    RegExp(r'^github(?!copilot)'): 'assets/ai_brands/github.svg',
  };

  /// 根据名字哈希到一个稳定的品牌色（用于背景 + svg 着色 + 首字母颜色）
  static Color _brandColor(String name, {required bool isDark}) {
    final lower = name.trim().toLowerCase();
    for (final entry in _brandColors.entries) {
      if (entry.key.hasMatch(lower)) {
        return entry.value;
      }
    }
    var hash = 0;
    for (final c in lower.codeUnits) {
      hash = (hash * 31 + c) & 0x7fffffff;
    }
    final hue = (hash % 360).toDouble();
    return HSLColor.fromAHSL(
      1.0,
      hue,
      0.55,
      isDark ? 0.65 : 0.45,
    ).toColor();
  }

  /// 常见 AI brand 主色（regex → color）
  ///
  /// 极深色 brand（luminance < 0.25）会被 [_brandColor] 路径触发"反相"
  /// 渲染：深底 + 白色 icon。
  ///
  /// 颜色取自各家公司公开的 brand identity（facts，不是创作内容）。
  static final Map<RegExp, Color> _brandColors = {
    // ---- 子品牌（先匹配以免被父品牌通配）----
    RegExp(r'gemma'): const Color(0xFF0F9D58),
    RegExp(r'gemini|imagen'): const Color(0xFF4285F4),
    // 通用图像生成 brand 色（橙）—— 仅独立 brand 的图像模型；
    // OpenAI 系（gpt-image / dall-e / sora）在下面 OpenAI 行走绿色（保品牌一致）
    RegExp(r'midjourney|^flux|stable.?diffusion|sd[a-z]?\d|grok-2-image|ideogram'):
        const Color(0xFFEA580C),
    RegExp(r'wenxin|文心|ernie'): const Color(0xFF2932E1),
    RegExp(r'hunyuan|混元'): const Color(0xFF0063F0),
    RegExp(r'longcat|龙猫|美团'): const Color(0xFFFFD000),
    RegExp(r'spark|讯飞星火|星火'): const Color(0xFF1F6FFF),
    RegExp(r'baichuan|百川'): const Color(0xFFFF6933),
    RegExp(r'(?<![a-z])yi-|零一|^yi$'): const Color(0xFF003425),
    // GLM 系列共用 Zhipu 蓝紫色（asset 也已合并到 zhipu logo）
    RegExp(r'chatglm|^glm|-glm|cogview|^embedding-3'): const Color(0xFF1F65FF),
    RegExp(r'internlm|书生'): const Color(0xFF1B7CE0),
    RegExp(r'doubao|豆包|seedream|^ep-202'): const Color(0xFF7960F0),
    // ---- 子品牌（彩色变体） ----
    RegExp(r'pixtral'): const Color(0xFFFF7000),  // pixtral 用 mistral 色
    RegExp(r'^jamba|^ai21'): const Color(0xFFE91E63),
    RegExp(r'codegeex'): const Color(0xFF35B0F4),  // chatglm 蓝同色
    RegExp(r'internvl'): const Color(0xFF1B7CE0),  // internlm 蓝同色
    RegExp(r'llava'): const Color(0xFFFFB938),
    RegExp(r'^phi|wizardlm|^microsoft'): const Color(0xFF00BCF2),
    RegExp(r'dbrx|databricks'): const Color(0xFFFF3621),
    RegExp(r'jina'): const Color(0xFF009191),
    RegExp(r'^voyage'): const Color(0xFF6E5BFF),
    RegExp(r'suno|chirp'): const Color(0xFF111111),
    RegExp(r'luma'): const Color(0xFF7C3AED),
    RegExp(r'keling|kling|可灵'): const Color(0xFFFF3D71),
    RegExp(r'^vidu'): const Color(0xFF6E5BFF),
    RegExp(r'hailuo|海螺'): const Color(0xFF1FB6FF),
    RegExp(r'upstage|solar'): const Color(0xFF0080FF),
    RegExp(r'^ibm|granite'): const Color(0xFF0530AD),
    RegExp(r'^bytedance|字节跳动'): const Color(0xFFF04142),
    RegExp(r'modelscope|魔搭'): const Color(0xFF624AFF),
    // ---- 主品牌 ----
    // OpenAI 全系（含 dall-e / gpt-image / sora 等图像模型）统一品牌绿，
    // 视觉上不跟通用图像橙混淆
    RegExp(r'openai|^gpt|chatgpt|^o\d|dall-?e|sora'): const Color(0xFF10A37F),
    RegExp(r'anthropic|claude'): const Color(0xFFD97757),
    RegExp(r'^google|bard|palm|vertex'): const Color(0xFF4285F4),
    RegExp(r'deepseek'): const Color(0xFF4D6BFE),
    RegExp(r'mistral|mixtral|codestral'): const Color(0xFFFF7000),
    RegExp(r'qwen|qwq|qvq|dashscope|aliyun|阿里|百炼|tongyi|通义'):
        const Color(0xFF615CED),
    RegExp(r'^llama|(?<![a-z])llama(?![a-z])|(?<![a-z])meta(?![a-z])'):
        const Color(0xFF0467DF),
    RegExp(r'grok(?!q)|xai'): const Color(0xFF000000),
    RegExp(r'groq'): const Color(0xFFF55036),
    RegExp(r'volc|火山|bytedance|字节'): const Color(0xFF1A6EFF),
    RegExp(r'kimi|moonshot'): const Color(0xFF1A1A1A),
    RegExp(r'zhipu|智谱'): const Color(0xFF1F65FF),
    RegExp(r'cohere|command-?[a-z]?'): const Color(0xFFFF7759),
    RegExp(r'perplexity|sonar'): const Color(0xFF20A39E),
    RegExp(r'ollama'): const Color(0xFF000000),
    RegExp(r'openrouter'): const Color(0xFF6967FF),
    RegExp(r'silicon|硅基'): const Color(0xFF6E5BFF),
    RegExp(r'minimax'): const Color(0xFF111111),
    RegExp(r'tencent|腾讯'): const Color(0xFF0088FF),
    RegExp(r'baidu|百度'): const Color(0xFF2932E1),
    RegExp(r'^step|阶跃|stepfun'): const Color(0xFF1AAA72),
    RegExp(r'huggingface|^hf-?'): const Color(0xFFFF9D00),
    // ---- 平台 / inference 厂商 ----
    RegExp(r'nvidia|nemotron'): const Color(0xFF76B900),
    RegExp(r'^aws|bedrock'): const Color(0xFFFF9900),
    RegExp(r'azure'): const Color(0xFF008AD7),
    RegExp(r'together'): const Color(0xFF0F6FFF),
    RegExp(r'fireworks'): const Color(0xFF6720D6),
    RegExp(r'stability|stable.?diffusion'): const Color(0xFF7E22CE),
    RegExp(r'replicate'): const Color(0xFF000000),
    RegExp(r'runway'): const Color(0xFF000000),
    RegExp(r'^copilot|github.copilot'): const Color(0xFF24292F),
    RegExp(r'^github'): const Color(0xFF24292F),
  };
}
