import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n/ai_l10n.dart';
import '../models/ai_provider.dart';
import '../providers/ai_provider_providers.dart';
import '../services/ai_provider_service.dart';
import '../services/toast_delegate.dart';
import '../utils/model_capabilities.dart';
import '../widgets/model_detail_sheet.dart';
import '../widgets/model_icon.dart';
import '../widgets/model_tag_wrap.dart';

bool _showRail(BuildContext context) =>
    MediaQuery.sizeOf(context).width >= 600;

class AiProviderEditPage extends ConsumerStatefulWidget {
  final AiProvider? provider;
  const AiProviderEditPage({super.key, this.provider});

  @override
  ConsumerState<AiProviderEditPage> createState() => _AiProviderEditPageState();
}

class _AiProviderEditPageState extends ConsumerState<AiProviderEditPage> {
  late TextEditingController _nameCtrl;
  late TextEditingController _baseUrlCtrl;
  late TextEditingController _apiKeyCtrl;
  late AiProviderType _selectedType;
  late List<AiModel> _models;
  late List<int> _modelRowIds;
  int _nextModelRowId = 0;

  final PageController _pageCtrl = PageController();
  int _tabIndex = 0;

  bool _obscureApiKey = true;
  bool _isCheckingConnectivity = false;
  bool _isSaving = false;
  bool? _connectivitySuccess;
  String? _connectivityError;
  String? _testingModelId;
  final Map<String, String?> _modelTestResults = {};

  bool get _isEditing => widget.provider != null;

  @override
  void initState() {
    super.initState();
    _selectedType = widget.provider?.type ?? AiProviderType.openai;
    _nameCtrl = TextEditingController(text: widget.provider?.name ?? '');
    _baseUrlCtrl = TextEditingController(
        text: widget.provider?.baseUrl ?? _selectedType.defaultBaseUrl);
    _apiKeyCtrl = TextEditingController();
    _models = List.from(widget.provider?.models ?? []);
    _modelRowIds = List.generate(_models.length, (_) => _nextModelRowId++);
    if (_isEditing) _loadApiKey();
  }

  Future<void> _loadApiKey() async {
    final key = await AiProviderListNotifier.getApiKey(widget.provider!.id);
    if (mounted && key != null) _apiKeyCtrl.text = key;
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _baseUrlCtrl.dispose();
    _apiKeyCtrl.dispose();
    _pageCtrl.dispose();
    super.dispose();
  }

  // ────────────────── Actions ──────────────────

  void _onTypeChanged(AiProviderType? type) {
    if (type == null) return;
    setState(() {
      if (_baseUrlCtrl.text.isEmpty ||
          AiProviderType.values
              .any((t) => t.defaultBaseUrl == _baseUrlCtrl.text)) {
        _baseUrlCtrl.text = type.defaultBaseUrl;
      }
      _selectedType = type;
    });
  }

  Future<void> _checkConnectivity() async {
    final apiKey = _apiKeyCtrl.text.trim();
    final baseUrl = _baseUrlCtrl.text.trim();
    if (apiKey.isEmpty || baseUrl.isEmpty) {
      AiToastDelegate.showInfo(AiL10n.current.pleaseEnterBaseUrlAndApiKey);
      return;
    }
    setState(() {
      _isCheckingConnectivity = true;
      _connectivitySuccess = null;
      _connectivityError = null;
    });
    try {
      final service = ref.read(aiProviderApiServiceProvider);
      final ok =
          await service.checkConnectivity(_selectedType, baseUrl, apiKey);
      if (mounted) {
        setState(() {
          _connectivitySuccess = ok;
          _connectivityError = ok ? null : '';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _connectivitySuccess = false;
          _connectivityError = AiProviderApiService.friendlyError(e);
        });
      }
    } finally {
      if (mounted) setState(() => _isCheckingConnectivity = false);
    }
  }

  Future<void> _testModel(String modelId) async {
    final apiKey = _apiKeyCtrl.text.trim();
    final baseUrl = _baseUrlCtrl.text.trim();
    if (apiKey.isEmpty || baseUrl.isEmpty) {
      AiToastDelegate.showInfo(
          AiL10n.current.pleaseEnterBaseUrlAndApiKeyFirst);
      return;
    }
    setState(() {
      _testingModelId = modelId;
      _modelTestResults.remove(modelId);
    });
    try {
      final service = ref.read(aiProviderApiServiceProvider);
      final error =
          await service.testModel(_selectedType, baseUrl, apiKey, modelId);
      if (mounted) {
        setState(() {
          _modelTestResults[modelId] = error;
          _testingModelId = null;
        });
        if (error == null) {
          AiToastDelegate.showSuccess(AiL10n.current.modelAvailable(modelId));
        } else {
          AiToastDelegate.showError(
              AiL10n.current.modelUnavailable(modelId, error));
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _modelTestResults[modelId] = AiProviderApiService.friendlyError(e);
          _testingModelId = null;
        });
      }
    }
  }

  void _showTestModelPicker() {
    if (_models.isEmpty) {
      AiToastDelegate.showInfo(AiL10n.current.selectModelToTest);
      return;
    }
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                AiL10n.current.selectModelToTest,
                style: const TextStyle(
                    fontSize: 16, fontWeight: FontWeight.w500),
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _models.length,
                itemBuilder: (ctx, i) {
                  final m = _models[i];
                  return ListTile(
                    leading: ModelIcon(
                      providerName: widget.provider?.name ?? '',
                      modelName: m.name ?? m.id,
                      size: 24,
                    ),
                    title: Text(m.name ?? m.id),
                    subtitle: m.name != null
                        ? Text(m.id, style: const TextStyle(fontSize: 12))
                        : null,
                    onTap: () {
                      Navigator.pop(ctx);
                      _testModel(m.id);
                    },
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _fetchAndSelectModels() async {
    final apiKey = _apiKeyCtrl.text.trim();
    final baseUrl = _baseUrlCtrl.text.trim();
    if (apiKey.isEmpty || baseUrl.isEmpty) {
      AiToastDelegate.showInfo(AiL10n.current.pleaseEnterBaseUrlAndApiKey);
      return;
    }

    final service = ref.read(aiProviderApiServiceProvider);
    final fetchFuture =
        service.fetchModels(_selectedType, baseUrl, apiKey);

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => _FetchedModelsSelector(
        fetchFuture: fetchFuture,
        currentModels: _models,
        onAdd: (model) {
          setState(() {
            _models.add(ModelCapabilities.infer(model));
            _modelRowIds.add(_nextModelRowId++);
          });
        },
        onRemove: (modelId) {
          setState(() => _removeModelsById(modelId));
        },
      ),
    );
  }

  Future<void> _addModelManually() async {
    final result = await showCreateModelSheet(context);
    if (result != null && mounted) {
      setState(() {
        _models.add(ModelCapabilities.infer(result));
        _modelRowIds.add(_nextModelRowId++);
      });
    }
  }

  Future<void> _save() async {
    final name = _nameCtrl.text.trim();
    final baseUrl = _baseUrlCtrl.text.trim();
    final apiKey = _apiKeyCtrl.text.trim();
    if (name.isEmpty) {
      AiToastDelegate.showInfo(AiL10n.current.pleaseEnterProviderName);
      return;
    }
    if (baseUrl.isEmpty) {
      AiToastDelegate.showInfo(AiL10n.current.pleaseEnterBaseUrl);
      return;
    }
    if (apiKey.isEmpty) {
      AiToastDelegate.showInfo(AiL10n.current.pleaseEnterApiKey);
      return;
    }
    setState(() => _isSaving = true);
    try {
      final notifier = ref.read(aiProviderListProvider.notifier);
      if (_isEditing) {
        await notifier.updateProvider(
          id: widget.provider!.id,
          name: name,
          type: _selectedType,
          baseUrl: baseUrl,
          apiKey: apiKey,
          models: _models,
        );
      } else {
        await notifier.addProvider(
          name: name,
          type: _selectedType,
          baseUrl: baseUrl,
          apiKey: apiKey,
          models: _models,
        );
      }
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        AiToastDelegate.showError(AiL10n.current
            .saveFailed(AiProviderApiService.friendlyError(e)));
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _editModel(int index) async {
    final model = _models[index];
    final result = await showModelDetailSheet(context, model: model);
    if (result != null && mounted) {
      setState(() => _models[index] = result);
    }
  }

  void _reorderModels(int oldIndex, int newIndex) {
    if (oldIndex == newIndex) return;
    setState(() {
      final moved = _models.removeAt(oldIndex);
      final movedRowId = _modelRowIds.removeAt(oldIndex);
      _models.insert(newIndex, moved);
      _modelRowIds.insert(newIndex, movedRowId);
    });
  }

  void _removeModelAt(int index) {
    _models.removeAt(index);
    _modelRowIds.removeAt(index);
  }

  void _removeModelsById(String modelId) {
    for (var i = _models.length - 1; i >= 0; i--) {
      if (_models[i].id == modelId) {
        _removeModelAt(i);
      }
    }
  }

  void _switchTab(int i) {
    setState(() => _tabIndex = i);
    _pageCtrl.animateToPage(
      i,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );
  }

  // ────────────────── Build ──────────────────

  @override
  Widget build(BuildContext context) {
    final showRail = _showRail(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(_isEditing
            ? AiL10n.current.editProvider
            : AiL10n.current.addProvider),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilledButton(
              onPressed: _isSaving ? null : _save,
              child: _isSaving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : Text(AiL10n.current.save),
            ),
          ),
        ],
      ),
      body: Row(
        children: [
          if (showRail) ...[
            _buildRail(context),
            const VerticalDivider(thickness: 1, width: 1),
          ],
          Expanded(
            child: PageView(
              controller: _pageCtrl,
              onPageChanged: (i) => setState(() => _tabIndex = i),
              children: [
                _buildConfigTab(),
                _buildModelsTab(),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: showRail ? null : _buildBottomNav(),
    );
  }

  // ────────────────── Rail (桌面/平板) ──────────────────

  Widget _buildRail(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final destinations = [
      (Icons.settings_outlined, Icons.settings, AiL10n.current.configTab),
      (Icons.layers_outlined, Icons.layers, AiL10n.current.modelsTab),
    ];

    return SafeArea(
      child: SizedBox(
        width: 72,
        child: Column(
          children: [
            const SizedBox(height: 16),
            ...destinations.asMap().entries.map((e) {
              final i = e.key;
              final d = e.value;
              final selected = i == _tabIndex;
              return Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Material(
                  color: selected
                      ? cs.secondaryContainer
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(16),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () => _switchTab(i),
                    child: SizedBox(
                      height: 56,
                      child: Center(
                        child: Icon(
                          selected ? d.$2 : d.$1,
                          color: selected
                              ? cs.onSecondaryContainer
                              : cs.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  // ────────────────── BottomNav (手机) ──────────────────

  Widget _buildBottomNav() {
    return NavigationBar(
      selectedIndex: _tabIndex,
      onDestinationSelected: _switchTab,
      destinations: [
        NavigationDestination(
          icon: const Icon(Icons.settings_outlined),
          selectedIcon: const Icon(Icons.settings),
          label: AiL10n.current.configTab,
        ),
        NavigationDestination(
          icon: const Icon(Icons.layers_outlined),
          selectedIcon: const Icon(Icons.layers),
          label: AiL10n.current.modelsTab,
        ),
      ],
    );
  }

  // ────────────────── 配置 Tab ──────────────────

  Widget _buildConfigTab() {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    InputDecoration inputDeco(String label, {String? hint, Widget? suffix}) =>
        InputDecoration(
          labelText: label,
          hintText: hint,
          filled: true,
          fillColor: isDark ? Colors.white10 : cs.surfaceContainerLow,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide:
                BorderSide(color: cs.outlineVariant.withValues(alpha: 0.4)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide:
                BorderSide(color: cs.outlineVariant.withValues(alpha: 0.4)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide:
                BorderSide(color: cs.primary.withValues(alpha: 0.5)),
          ),
          suffixIcon: suffix,
        );

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        TextField(
          controller: _nameCtrl,
          decoration: inputDeco(AiL10n.current.name,
              hint: AiL10n.current.nameHint),
        ),
        const SizedBox(height: 14),
        DropdownButtonFormField<AiProviderType>(
          initialValue: _selectedType,
          decoration: inputDeco(AiL10n.current.providerType),
          items: AiProviderType.values
              .map((t) => DropdownMenuItem(value: t, child: Text(t.label)))
              .toList(),
          onChanged: _onTypeChanged,
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _baseUrlCtrl,
          decoration: inputDeco('Base URL'),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _apiKeyCtrl,
          obscureText: _obscureApiKey,
          decoration: inputDeco('API Key',
              suffix: IconButton(
                icon: Icon(_obscureApiKey
                    ? Icons.visibility_off
                    : Icons.visibility),
                onPressed: () =>
                    setState(() => _obscureApiKey = !_obscureApiKey),
              )),
        ),
        const SizedBox(height: 20),
        // 连通性 + 测试
        Row(
          children: [
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed:
                    _isCheckingConnectivity ? null : _checkConnectivity,
                icon: _isCheckingConnectivity
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: cs.primary),
                      )
                    : const Icon(Icons.wifi_tethering, size: 18),
                label: Text(AiL10n.current.connectivityCheck),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed:
                    _testingModelId != null ? null : _showTestModelPicker,
                icon: _testingModelId != null
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: cs.primary),
                      )
                    : const Icon(Icons.play_arrow_rounded, size: 18),
                label: Text(AiL10n.current.testModel),
              ),
            ),
          ],
        ),
        if (_connectivitySuccess != null) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(
                _connectivitySuccess! ? Icons.check_circle : Icons.error,
                size: 18,
                color:
                    _connectivitySuccess! ? Colors.green : cs.error,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _connectivitySuccess!
                      ? AiL10n.current.connectionSuccess
                      : (_connectivityError != null &&
                              _connectivityError!.isNotEmpty
                          ? AiL10n.current.connectionFailedWithError(
                              _connectivityError!)
                          : AiL10n.current.connectionFailed),
                  style: TextStyle(
                    fontSize: 13,
                    color: _connectivitySuccess!
                        ? Colors.green
                        : cs.error,
                  ),
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }

  // ────────────────── 模型 Tab ──────────────────

  Widget _buildModelsTab() {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    return Stack(
      children: [
        // 模型列表
        _models.isEmpty
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.layers_outlined,
                        size: 48,
                        color: cs.onSurfaceVariant.withValues(alpha: 0.4)),
                    const SizedBox(height: 12),
                    Text(
                      AiL10n.current.addModelManually,
                      style: TextStyle(color: cs.onSurfaceVariant),
                    ),
                  ],
                ),
              )
            : ReorderableListView.builder(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 80),
                buildDefaultDragHandles: false,
                itemCount: _models.length,
                onReorderItem: _reorderModels,
                itemBuilder: (ctx, index) {
                  final model = _models[index];
                  return ReorderableDelayedDragStartListener(
                    key: ValueKey('provider_model_${_modelRowIds[index]}'),
                    index: index,
                    child: _buildModelItem(
                      theme: theme,
                      model: model,
                      index: index,
                    ),
                  );
                },
              ),

        // 悬浮操作栏
        Positioned(
          left: 0,
          right: 0,
          bottom: 12,
          child: Center(
            child: Container(
              decoration: BoxDecoration(
                color: isDark
                    ? Color.alphaBlend(
                        Colors.white.withValues(alpha: 0.12),
                        cs.surface,
                      )
                    : const Color(0xFFF2F3F5),
                borderRadius: BorderRadius.circular(999),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.08),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              padding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 获取模型
                  _FloatingPill(
                    icon: Icons.cloud_download_outlined,
                    label: AiL10n.current.fetchModels,
                    outlined: true,
                    onTap: _fetchAndSelectModels,
                  ),
                  const SizedBox(width: 6),
                  // 手动添加
                  _FloatingPill(
                    icon: Icons.add,
                    label: AiL10n.current.manuallyAdd,
                    filled: true,
                    onTap: _addModelManually,
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildModelItem({
    required ThemeData theme,
    required AiModel model,
    required int index,
  }) {
    final cs = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => _editModel(index),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 8, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: ModelIcon(
                    providerName: widget.provider?.name ?? '',
                    modelName: model.name ?? model.id,
                    size: 32,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        model.name ?? model.id,
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(fontWeight: FontWeight.w500),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (model.name != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          model.id,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                            fontSize: 11,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      const SizedBox(height: 6),
                      ModelTagWrap(model: model),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.delete_outline,
                      color: cs.error.withValues(alpha: 0.7), size: 20),
                  tooltip: AiL10n.current.remove,
                  visualDensity: VisualDensity.compact,
                  onPressed: () =>
                      setState(() => _removeModelAt(index)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ────────────────── 悬浮 pill 按钮 ──────────────────

class _FloatingPill extends StatelessWidget {
  const _FloatingPill({
    required this.icon,
    required this.label,
    this.onTap,
    this.outlined = false,
    this.filled = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool outlined;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Material(
      color: filled ? cs.primary.withValues(alpha: 0.12) : Colors.transparent,
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          padding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: outlined
              ? BoxDecoration(
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: cs.primary.withValues(alpha: 0.35),
                  ),
                )
              : null,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: cs.primary),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  color: cs.primary,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ────────────────── 获取模型选择器 ──────────────────

// ────────────────── 模型分组工具 ──────────────────

String _modelGroup(String modelId) {
  final id = modelId.toLowerCase();
  if (id.contains('gpt') || RegExp(r'(^|[^a-z])o[1-9]').hasMatch(id)) {
    return 'GPT';
  }
  if (id.contains('gemini')) return 'Gemini';
  if (id.contains('claude')) return 'Claude';
  if (id.contains('deepseek')) return 'DeepSeek';
  if (RegExp(r'qwen|qwq|qvq').hasMatch(id)) return 'Qwen';
  if (RegExp(r'doubao|ark').hasMatch(id)) return 'Doubao';
  if (id.contains('glm') || id.contains('zhipu')) return 'GLM';
  if (id.contains('mistral')) return 'Mistral';
  if (id.contains('grok') || id.contains('xai')) return 'Grok';
  if (id.contains('kimi')) return 'Kimi';
  if (id.contains('llama') || id.contains('meta')) return 'Llama';
  if (id.contains('minimax')) return 'MiniMax';
  if (RegExp(r'embed(?:ding)?').hasMatch(id)) return 'Embedding';
  return 'Other';
}

// ────────────────── 获取模型选择器 ──────────────────

class _FetchedModelsSelector extends StatefulWidget {
  final Future<List<AiModel>> fetchFuture;
  final List<AiModel> currentModels;
  final ValueChanged<AiModel> onAdd;
  final ValueChanged<String> onRemove;

  const _FetchedModelsSelector({
    required this.fetchFuture,
    required this.currentModels,
    required this.onAdd,
    required this.onRemove,
  });

  @override
  State<_FetchedModelsSelector> createState() => _FetchedModelsSelectorState();
}

class _FetchedModelsSelectorState extends State<_FetchedModelsSelector> {
  List<AiModel>? _fetched;
  String? _error;
  final Set<String> _collapsed = {};
  String _search = '';

  Set<String> get _activeIds =>
      widget.currentModels.map((m) => m.id).toSet();

  @override
  void initState() {
    super.initState();
    widget.fetchFuture.then((result) {
      if (mounted) setState(() => _fetched = result);
    }).catchError((e) {
      if (mounted) {
        setState(() => _error = AiProviderApiService.friendlyError(e));
      }
    });
  }

  List<AiModel> get _filtered {
    final models = _fetched;
    if (models == null) return [];
    if (_search.isEmpty) return models;
    final q = _search.toLowerCase();
    return models
        .where((m) =>
            m.id.toLowerCase().contains(q) ||
            (m.name?.toLowerCase().contains(q) ?? false))
        .toList();
  }

  Map<String, List<AiModel>> get _grouped {
    final map = <String, List<AiModel>>{};
    for (final m in _filtered) {
      final g = _modelGroup(m.id);
      (map[g] ??= []).add(m);
    }
    return map;
  }

  void _toggle(AiModel model) {
    if (_activeIds.contains(model.id)) {
      widget.onRemove(model.id);
    } else {
      widget.onAdd(model);
    }
    setState(() {});
  }

  void _toggleGroup(String group) {
    final models = _grouped[group];
    if (models == null) return;
    final active = _activeIds;
    final allActive = models.every((m) => active.contains(m.id));
    for (final m in models) {
      if (allActive) {
        widget.onRemove(m.id);
      } else if (!active.contains(m.id)) {
        widget.onAdd(m);
      }
    }
    setState(() {});
  }

  void _toggleAll() {
    final filtered = _filtered;
    final active = _activeIds;
    final allActive = filtered.every((m) => active.contains(m.id));
    for (final m in filtered) {
      if (allActive) {
        widget.onRemove(m.id);
      } else if (!active.contains(m.id)) {
        widget.onAdd(m);
      }
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isLoading = _fetched == null && _error == null;
    final filtered = _filtered;
    final active = _activeIds;
    final allActive =
        filtered.isNotEmpty && filtered.every((m) => active.contains(m.id));

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      maxChildSize: 0.95,
      minChildSize: 0.4,
      builder: (c, scrollController) {
        return Column(
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: cs.onSurface.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(999),
              ),
            ),
            const SizedBox(height: 12),
            if (!isLoading && _error == null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                child: TextField(
                  onChanged: (v) => setState(() => _search = v),
                  decoration: InputDecoration(
                    hintText: AiL10n.current.searchModelsHint,
                    prefixIcon: const Icon(Icons.search, size: 20),
                    isDense: true,
                    filled: true,
                    fillColor:
                        isDark ? Colors.white10 : const Color(0xFFF2F3F5),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    suffixIcon: filtered.isNotEmpty
                        ? IconButton(
                            icon: Icon(
                              allActive
                                  ? Icons.deselect
                                  : Icons.select_all,
                              size: 22,
                              color: cs.onSurface.withValues(alpha: 0.7),
                            ),
                            tooltip: allActive
                                ? AiL10n.current.fetchModelsDeselectAll
                                : AiL10n.current.fetchModelsSelectAll,
                            onPressed: _toggleAll,
                          )
                        : null,
                  ),
                ),
              ),
            Expanded(child: _buildBody(cs, isDark, scrollController)),
          ],
        );
      },
    );
  }

  Widget _buildBody(
      ColorScheme cs, bool isDark, ScrollController scrollController) {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, size: 48, color: cs.error),
              const SizedBox(height: 12),
              Text(_error!, textAlign: TextAlign.center,
                  style: TextStyle(color: cs.error)),
            ],
          ),
        ),
      );
    }

    if (_fetched == null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AiToastDelegate.buildLoading(color: cs.primary, size: 48),
            const SizedBox(height: 16),
            Text(AiL10n.current.fetchModels,
                style: TextStyle(color: cs.onSurfaceVariant)),
          ],
        ),
      );
    }

    final grouped = _grouped;
    if (grouped.isEmpty) {
      return Center(
        child: Text(AiL10n.current.searchModelsHint,
            style: TextStyle(color: cs.onSurfaceVariant)),
      );
    }

    final active = _activeIds;
    final groupKeys = grouped.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      itemCount: groupKeys.length,
      itemBuilder: (ctx, gi) {
        final group = groupKeys[gi];
        final models = grouped[group]!;
        final isCollapsed = _collapsed.contains(group);
        final groupActiveCount =
            models.where((m) => active.contains(m.id)).length;
        final groupAllActive = groupActiveCount == models.length;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => setState(() {
                if (isCollapsed) {
                  _collapsed.remove(group);
                } else {
                  _collapsed.add(group);
                }
              }),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                child: Row(
                  children: [
                    Icon(
                      isCollapsed
                          ? Icons.chevron_right
                          : Icons.expand_more,
                      size: 20,
                      color: cs.onSurfaceVariant,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      group,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: cs.onSurface.withValues(alpha: 0.7),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '$groupActiveCount/${models.length}',
                      style: TextStyle(
                        fontSize: 12,
                        color: cs.onSurfaceVariant.withValues(alpha: 0.6),
                      ),
                    ),
                    const Spacer(),
                    GestureDetector(
                      onTap: () => _toggleGroup(group),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        child: Icon(
                          groupAllActive
                              ? Icons.check_box
                              : (groupActiveCount > 0
                                  ? Icons.indeterminate_check_box
                                  : Icons.check_box_outline_blank),
                          size: 20,
                          color: groupAllActive || groupActiveCount > 0
                              ? cs.primary
                              : cs.onSurfaceVariant.withValues(alpha: 0.5),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (!isCollapsed)
              ...models.map((m) {
                final checked = active.contains(m.id);
                final inferred = ModelCapabilities.infer(m);
                return Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Material(
                    color: cs.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(12),
                      onTap: () => _toggle(m),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 10),
                        child: Row(
                          children: [
                            Checkbox(
                              value: checked,
                              onChanged: (_) => _toggle(m),
                              visualDensity: VisualDensity.compact,
                            ),
                            const SizedBox(width: 8),
                            ModelIcon(
                              providerName: '',
                              modelName: m.name ?? m.id,
                              size: 28,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment:
                                    CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    m.name ?? m.id,
                                    style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  if (m.name != null) ...[
                                    const SizedBox(height: 2),
                                    Text(
                                      m.id,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: cs.onSurfaceVariant
                                            .withValues(alpha: 0.6),
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                  const SizedBox(height: 4),
                                  ModelTagWrap(model: inferred),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }),
            if (gi < groupKeys.length - 1) const SizedBox(height: 4),
          ],
        );
      },
    );
  }
}
