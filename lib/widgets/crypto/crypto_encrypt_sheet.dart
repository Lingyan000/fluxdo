/// 编辑器加密弹窗：明文 + 算法 + 密码 → 密文（可复制/插回编辑器）。
///
/// 入口：编辑器工具栏「加密」按钮（MarkdownToolbarState.insertEncryptedBlock）。
/// 对称算法输出 ENC1（默认）或 OpenSSL 兼容格式；编码/哈希/经典直接输出。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/s.dart';
import '../../providers/preferences_provider.dart';
import '../../providers/secret_store_provider.dart';
import '../../services/crypto/crypto_algorithm.dart';
import '../../services/crypto/crypto_key_store.dart';
import '../../services/crypto/crypto_toolbox.dart';
import '../../services/crypto/algorithms/symmetric_algorithms.dart' show SymmetricAlgorithm;
import '../../services/toast_service.dart';
import '../common/app_bottom_sheet.dart';
import 'crypto_algorithm_field.dart';
import 'crypto_sheet_style.dart';

/// 打开加密弹窗；返回密文（取消返回 null）。
///
/// [initialPlaintext] 预填明文（编辑器选中文本）。
Future<String?> showCryptoEncryptSheet({
  required BuildContext context,
  String? initialPlaintext,
}) {
  return AppBottomSheet.show<String>(
    context: context,
    style: AppSheetStyle.card,
    title: context.l10n.crypto_encryptTitle,
    builder: (sheetContext) => CryptoEncryptSheet(
      initialPlaintext: initialPlaintext,
    ),
  );
}

class CryptoEncryptSheet extends ConsumerStatefulWidget {
  const CryptoEncryptSheet({super.key, this.initialPlaintext});

  final String? initialPlaintext;

  @override
  ConsumerState<CryptoEncryptSheet> createState() => _CryptoEncryptSheetState();
}

class _CryptoEncryptSheetState extends ConsumerState<CryptoEncryptSheet> {
  late final TextEditingController _plaintextController;
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _pemController = TextEditingController();
  final TextEditingController _caesarController =
      TextEditingController(text: '3');
  final TextEditingController _vigenereController = TextEditingController();
  final TextEditingController _railCountController =
      TextEditingController(text: '2');

  String _algorithmId = CryptoToolbox.defaultAlgorithmId;
  CryptoOutputFormat _outputFormat = CryptoOutputFormat.enc1;
  bool _obscurePassword = true;
  bool _rememberPassword = false;
  bool _rememberEnabled = false;
  List<String> _rememberedPasswords = const [];
  String? _result;
  String? _error;

  @override
  void initState() {
    super.initState();
    _plaintextController =
        TextEditingController(text: widget.initialPlaintext ?? '');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final remember = ref.read(preferencesProvider).cryptoRememberPassword;
      setState(() {
        _rememberEnabled = remember;
        _rememberPassword = remember;
      });
      _loadRememberedPasswords();
    });
  }

  @override
  void dispose() {
    _plaintextController.dispose();
    _passwordController.dispose();
    _pemController.dispose();
    _caesarController.dispose();
    _vigenereController.dispose();
    _railCountController.dispose();
    super.dispose();
  }

  Future<void> _loadRememberedPasswords() async {
    final store = ref.read(secretStoreProvider);
    final passwords = await CryptoKeyStore.readPasswords(store);
    if (mounted) {
      setState(() => _rememberedPasswords = passwords);
    }
  }

  CryptoAlgorithm? get _algorithm => CryptoToolbox.byId(_algorithmId);

  /// OpenSSL 输出仅 CBC 系列与 RC4 支持
  bool get _openSslAvailable {
    final algo = _algorithm;
    return algo is SymmetricAlgorithm && algo.openSslCompatible;
  }

  CryptoParams _buildParams() => CryptoParams(
        password: _passwordController.text,
        rsaPem: _pemController.text,
        caesarShift: int.tryParse(_caesarController.text) ?? 3,
        vigenereKey: _vigenereController.text,
        railCount: int.tryParse(_railCountController.text) ?? 2,
      );

  Future<void> _encrypt() async {
    final plaintext = _plaintextController.text;
    if (plaintext.isEmpty) {
      setState(() => _error = context.l10n.crypto_emptyInput);
      return;
    }
    final algo = _algorithm;
    if (algo == null) return;
    try {
      final ciphertext = CryptoToolbox.encrypt(
        plaintext: plaintext,
        algorithmId: _algorithmId,
        params: _buildParams(),
        format: _outputFormat,
      );
      if (!mounted) return;
      setState(() {
        _result = ciphertext;
        _error = null;
      });
      if (_rememberPassword &&
          algo.category == CryptoAlgorithmCategory.symmetric) {
        final store = ref.read(secretStoreProvider);
        await CryptoKeyStore.rememberPassword(
            store, _passwordController.text);
        await _loadRememberedPasswords();
      }
    } on CryptoException catch (e) {
      if (!mounted) return;
      setState(() {
        _result = null;
        _error = e.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = context.l10n;
    final algo = _algorithm;

    return SingleChildScrollView(
      key: const ValueKey('crypto-encrypt-sheet'),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
      TextField(
            key: const ValueKey('crypto-encrypt-plaintext-input'),
            controller: _plaintextController,
            minLines: 3,
            maxLines: 6,
            decoration: cryptoSheetInputDecoration(
              theme,
              labelText: s.crypto_plaintext,
              prefixIcon: const Icon(Icons.edit_note_rounded, size: 20),
            ),
          ),
          const SizedBox(height: 12),
          CryptoAlgorithmTile(
            algorithmId: _algorithmId,
            onSelected: (id) => setState(() {
              _algorithmId = id;
              _result = null;
              _error = null;
              if (!_openSslAvailable) {
                _outputFormat = CryptoOutputFormat.enc1;
              }
            }),
          ),
          const SizedBox(height: 12),
          if (algo != null) _buildKeyFields(theme, s, algo),
          if (_openSslAvailable) _buildFormatSelector(theme, s),
          _buildRememberRow(theme, s, algo),
          const SizedBox(height: 12),
          Center(
            child: FilledButton.icon(
              key: const ValueKey('crypto-encrypt-action'),
              onPressed: _encrypt,
              icon: const Icon(Icons.key_rounded, size: 18),
              label: Text(s.crypto_encrypt),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                    horizontal: 28, vertical: 12),
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            _buildErrorCard(theme, _error!),
          ],
          if (_result != null) ...[
            const SizedBox(height: 12),
            _buildResultCard(theme, s),
          ],
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildKeyFields(ThemeData theme, AppLocalizations s, CryptoAlgorithm algo) {
    switch (algo.category) {
      case CryptoAlgorithmCategory.symmetric:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_rememberedPasswords.isNotEmpty && _rememberEnabled)
              Padding(
                padding: const EdgeInsets.only(top: 4, left: 12),
                child: Wrap(
                  spacing: 8,
                  children: [
                    for (final pw in _rememberedPasswords.take(3))
                      ActionChip(
                        key: ValueKey('crypto-enc-remembered-pw-${pw.hashCode}'),
                        label: Text(
                          pw.length > 10 ? '${pw.substring(0, 8)}…' : pw,
                        ),
                        tooltip: s.crypto_useRemembered,
                        onPressed: () => setState(() {
                          _passwordController.text = pw;
                        }),
                      ),
                  ],
                ),
              ),
            TextField(
              key: const ValueKey('crypto-encrypt-password-input'),
              controller: _passwordController,
              obscureText: _obscurePassword,
              autofillHints: const [AutofillHints.password],
              decoration: cryptoSheetInputDecoration(
                theme,
                labelText: s.crypto_password,
                prefixIcon: const Icon(Icons.key_rounded, size: 18),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscurePassword
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                  ),
                  onPressed: () => setState(
                      () => _obscurePassword = !_obscurePassword),
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
        );
      case CryptoAlgorithmCategory.asymmetric:
        return Column(
          children: [
            TextField(
              key: const ValueKey('crypto-encrypt-pem-input'),
              controller: _pemController,
              minLines: 3,
              maxLines: 5,
              style: theme.textTheme.bodySmall
                  ?.copyWith(fontFamily: 'monospace'),
              decoration: cryptoSheetInputDecoration(
                theme,
                labelText: s.crypto_rsaPublicKeyHint,
              ),
            ),
            const SizedBox(height: 8),
          ],
        );
      case CryptoAlgorithmCategory.classic:
        return Column(
          children: [
            if (algo.id == 'caesar')
              TextField(
                key: const ValueKey('crypto-encrypt-caesar-input'),
                controller: _caesarController,
                keyboardType: TextInputType.number,
                decoration: cryptoSheetInputDecoration(
                  theme,
                  labelText: s.crypto_caesarShift,
                ),
              )
            else if (algo.id == 'vigenere')
              TextField(
                key: const ValueKey('crypto-encrypt-vigenere-input'),
                controller: _vigenereController,
                decoration: cryptoSheetInputDecoration(
                  theme,
                  labelText: s.crypto_vigenereKey,
                ),
              )
            else if (algo.id == 'railfence')
              TextField(
                key: const ValueKey('crypto-encrypt-rail-input'),
                controller: _railCountController,
                keyboardType: TextInputType.number,
                decoration: cryptoSheetInputDecoration(
                  theme,
                  labelText: s.crypto_railCount,
                ),
              ),
            const SizedBox(height: 8),
          ],
        );
      case CryptoAlgorithmCategory.encoding:
      case CryptoAlgorithmCategory.hash:
        return const SizedBox.shrink();
    }
  }

  /// 输出格式选择：与输入框同风格的填充卡片二选一
  /// （替代 SegmentedButton 的描边胶囊，与整体表单视觉统一）。
  Widget _buildFormatSelector(ThemeData theme, AppLocalizations s) {
    Widget option(CryptoOutputFormat format, String label) {
      final selected = _outputFormat == format;
      return Expanded(
        child: Material(
          key: ValueKey('crypto-format-${format.name}'),
          color: selected
              ? theme.colorScheme.primaryContainer.withValues(alpha: 0.6)
              : theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(() {
              _outputFormat = format;
              _result = null;
            }),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (selected) ...[
                    Icon(
                      Icons.check_circle_rounded,
                      size: 16,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.w500,
                        color: selected
                            ? theme.colorScheme.onPrimaryContainer
                            : theme.colorScheme.onSurface,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 6),
          child: Text(
            s.crypto_outputFormat,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
        ),
        Row(
          children: [
            option(CryptoOutputFormat.enc1, s.crypto_formatFluxdo),
            const SizedBox(width: 8),
            option(CryptoOutputFormat.openssl, s.crypto_formatOpenSsl),
          ],
        ),
        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildRememberRow(
      ThemeData theme, AppLocalizations s, CryptoAlgorithm? algo) {
    if (algo?.category != CryptoAlgorithmCategory.symmetric ||
        !_rememberEnabled) {
      return const SizedBox.shrink();
    }
    return Row(
      children: [
        Switch(
          value: _rememberPassword,
          onChanged: (v) => setState(() => _rememberPassword = v),
        ),
        Expanded(
          child: Text(
            '${s.crypto_rememberPassword}（${s.crypto_secureStorageNote}）',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.colorScheme.outline),
          ),
        ),
      ],
    );
  }

  Widget _buildResultCard(ThemeData theme, AppLocalizations s) {
    final result = _result ?? '';
    return CryptoSheetResultCard(
      key: const ValueKey('crypto-encrypt-result'),
      title: s.crypto_result,
      content: result,
      monospace: true,
      maxContentHeight: 160,
      actions: [
        FilledButton.tonalIcon(
          key: const ValueKey('crypto-encrypt-copy'),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: result));
            ToastService.showSuccess(s.common_copiedToClipboard);
          },
          icon: const Icon(Icons.copy_rounded, size: 18),
          label: Text(s.common_copy),
        ),
        FilledButton.icon(
          key: const ValueKey('crypto-encrypt-use'),
          onPressed: () => Navigator.of(context).pop(result),
          icon: const Icon(Icons.check_rounded, size: 18),
          label: Text(s.crypto_insertToEditor),
        ),
      ],
    );
  }

  Widget _buildErrorCard(ThemeData theme, String text) {
    return CryptoSheetMessageCard(
      icon: Icons.error_outline_rounded,
      color: theme.colorScheme.error,
      text: text,
    );
  }
}
