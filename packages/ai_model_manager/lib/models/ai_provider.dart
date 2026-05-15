/// AI 供应商类型
enum AiProviderType {
  openai('OpenAI', 'https://api.openai.com/v1'),
  openaiResponse('OpenAI-Response', 'https://api.openai.com/v1'),
  gemini('Gemini', 'https://generativelanguage.googleapis.com/v1beta'),
  anthropic('Anthropic', 'https://api.anthropic.com/v1');

  final String label;
  final String defaultBaseUrl;

  const AiProviderType(this.label, this.defaultBaseUrl);

  static AiProviderType? fromName(String? name) {
    if (name == null) return null;
    for (final type in values) {
      if (type.name == name) return type;
    }
    return null;
  }
}

/// 模型支持的输入/输出模态
enum Modality { text, image }

/// 模型支持的能力
enum ModelAbility { tool, reasoning }

/// 用于 UI 编辑的统一能力维度（合并 Modality / ModelAbility）
///
/// vision = input 含 image
/// imageOutput = output 含 image
/// tool / reasoning = abilities 对应项
enum ModelCapability { vision, reasoning, tool, imageOutput }

/// 思考深度等级，统一映射到各供应商 API 参数。
/// [custom] 使用 [ThinkingConfig.customBudget] 自定义 token 数。
enum ThinkingLevel { off, auto, low, medium, high, custom }

/// 思考配置：等级 + 自定义预算
class ThinkingConfig {
  final ThinkingLevel level;
  final int customBudget;

  const ThinkingConfig({
    this.level = ThinkingLevel.off,
    this.customBudget = 8192,
  });

  bool get isEnabled => level != ThinkingLevel.off;

  ThinkingConfig copyWith({ThinkingLevel? level, int? customBudget}) =>
      ThinkingConfig(
        level: level ?? this.level,
        customBudget: customBudget ?? this.customBudget,
      );
}

List<Modality> _parseModalities(dynamic raw, List<Modality> fallback) {
  if (raw is! List) return List.unmodifiable(fallback);
  final out = <Modality>{};
  for (final e in raw) {
    final s = e?.toString().toLowerCase();
    if (s == 'text') out.add(Modality.text);
    if (s == 'image') out.add(Modality.image);
  }
  if (out.isEmpty) return List.unmodifiable(fallback);
  return List.unmodifiable(out.toList()..sort((a, b) => a.index.compareTo(b.index)));
}

List<ModelAbility> _parseAbilities(dynamic raw) {
  if (raw is! List) return const [];
  final out = <ModelAbility>{};
  for (final e in raw) {
    final s = e?.toString().toLowerCase();
    if (s == 'tool') out.add(ModelAbility.tool);
    if (s == 'reasoning') out.add(ModelAbility.reasoning);
  }
  return List.unmodifiable(out.toList()..sort((a, b) => a.index.compareTo(b.index)));
}

/// AI 模型
class AiModel {
  final String id;
  final String? name;
  final bool enabled;

  /// 输入支持的模态。默认 `[text]`。
  /// 多模态模型（vision）会包含 `image`。
  final List<Modality> input;

  /// 输出支持的模态。默认 `[text]`。
  /// 图像生成模型会包含 `image`。
  final List<Modality> output;

  /// 模型支持的能力（工具调用、推理思考等）。
  final List<ModelAbility> abilities;

  /// 标记 input/output/abilities 是否被用户手动编辑过。
  /// 为 true 时 [ModelCapabilities.infer] 会跳过自动推断，
  /// 避免下次拉模型列表覆盖用户的选择。
  final bool capabilitiesUserEdited;

  const AiModel({
    required this.id,
    this.name,
    this.enabled = true,
    this.input = const [Modality.text],
    this.output = const [Modality.text],
    this.abilities = const [],
    this.capabilitiesUserEdited = false,
  });

  factory AiModel.fromJson(Map<String, dynamic> json) {
    return AiModel(
      id: json['id'] as String,
      name: json['name'] as String?,
      enabled: json['enabled'] as bool? ?? true,
      input: _parseModalities(json['input'], const [Modality.text]),
      output: _parseModalities(json['output'], const [Modality.text]),
      abilities: _parseAbilities(json['abilities']),
      capabilitiesUserEdited:
          json['capabilitiesUserEdited'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      if (name != null) 'name': name,
      'enabled': enabled,
      'input': input.map((m) => m.name).toList(),
      'output': output.map((m) => m.name).toList(),
      'abilities': abilities.map((a) => a.name).toList(),
      if (capabilitiesUserEdited) 'capabilitiesUserEdited': true,
    };
  }

  AiModel copyWith({
    String? id,
    String? name,
    bool? enabled,
    List<Modality>? input,
    List<Modality>? output,
    List<ModelAbility>? abilities,
    bool? capabilitiesUserEdited,
  }) {
    return AiModel(
      id: id ?? this.id,
      name: name ?? this.name,
      enabled: enabled ?? this.enabled,
      input: input ?? this.input,
      output: output ?? this.output,
      abilities: abilities ?? this.abilities,
      capabilitiesUserEdited:
          capabilitiesUserEdited ?? this.capabilitiesUserEdited,
    );
  }
}

/// AI 供应商
class AiProvider {
  final String id;
  final String name;
  final AiProviderType type;
  final String baseUrl;
  final List<AiModel> models;
  final bool pinned;

  const AiProvider({
    required this.id,
    required this.name,
    required this.type,
    required this.baseUrl,
    this.models = const [],
    this.pinned = false,
  });

  factory AiProvider.fromJson(Map<String, dynamic> json) {
    final typeStr = json['type'] as String?;
    final type = AiProviderType.fromName(typeStr) ?? AiProviderType.openai;
    return AiProvider(
      id: json['id'] as String,
      name: json['name'] as String,
      type: type,
      baseUrl: json['base_url'] as String? ?? type.defaultBaseUrl,
      models: (json['models'] as List<dynamic>?)
              ?.map((e) => AiModel.fromJson(e as Map<String, dynamic>))
              .toList() ??
          [],
      pinned: json['pinned'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'type': type.name,
      'base_url': baseUrl,
      'models': models.map((m) => m.toJson()).toList(),
      if (pinned) 'pinned': pinned,
    };
  }

  AiProvider copyWith({
    String? id,
    String? name,
    AiProviderType? type,
    String? baseUrl,
    List<AiModel>? models,
    bool? pinned,
  }) {
    return AiProvider(
      id: id ?? this.id,
      name: name ?? this.name,
      type: type ?? this.type,
      baseUrl: baseUrl ?? this.baseUrl,
      models: models ?? this.models,
      pinned: pinned ?? this.pinned,
    );
  }
}
