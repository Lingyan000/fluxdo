/// 划词解密弹窗：密文 + 算法（自动识别可改）+ 密码 → 明文结果。
///
/// 入口：帖子阅读页划词菜单「解密」按钮（[showCryptoDecryptSheet]）。
/// 支持 ENC1（自动识别内嵌算法）/ OpenSSL Salted / 裸 base64 / 编码文本。
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
import '../../services/toast_service.dart';
import '../common/app_bottom_sheet.dart';
import 'crypto_algorithm_field.dart';
import 'crypto_sheet_style.dart';

/// 打开解密弹窗。
///
/// [initialCiphertext] 为划词选中的文本（弹窗内可编辑）。
/// [onQuoteReply] 非空时结果区展示「引用回复」，把解密明文交回上层。
Future<void> showCryptoDecryptSheet({
  required BuildContext context,
  required String initialCiphertext,
  void Function(String plaintext)? onQuoteReply,
}) {
  return AppBottomSheet.show<void>(
    context: context,
    style: AppSheetStyle.card,
    title: context.l10n.crypto_decryptTitle,
    builder: (sheetContext) => CryptoDecryptSheet(
      initialCiphertext: initialCiphertext,
      onQuoteReply: onQuoteReply,
    ),
  );
}

class CryptoDecryptSheet extends ConsumerStatefulWidget {
  const CryptoDecryptSheet({
    super.key,
    required this.initialCiphertext,
    this.onQuoteReply,
  });

  final String initialCiphertext;

  final void Function(String plaintext)? onQuoteReply;

  @override
  ConsumerState<CryptoDecryptSheet> createState() => _CryptoDecryptSheetState();
}

class _CryptoDecryptSheetState extends ConsumerState<CryptoDecryptSheet> {
  late final TextEditingController _cipherController;
  final TextEditingController _passwordController = TextEditingController();
  final TextEditingController _pemController = TextEditingController();
  final TextEditingController _caesarController =
      TextEditingController(text: '3');
  final TextEditingController _vigenereController = TextEditingController();
  final TextEditingController _railCountController =
      TextEditingController(text: '2');

  late String _algorithmId;
  bool _autoDetected = false;
  bool _obscurePassword = true;
  bool _rememberPassword = false;
  bool _rememberEnabled = false;
  List<String> _rememberedPasswords = const [];
  String? _result;
  String? _error;

  @override
  void initState() {
    super.initState();
    _cipherController = TextEditingController(text: widget.initialCiphertext);
    final suggestion = CryptoToolbox.suggestDecrypt(widget.initialCiphertext);
    _algorithmId =
        suggestion.algorithmId ?? CryptoToolbox.defaultAlgorithmId;
    _autoDetected = suggestion.algorithmId != null;
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
    _cipherController.dispose();
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

  CryptoParams _buildParams() => CryptoParams(
        password: _passwordController.text,
        rsaPem: _pemController.text,
        caesarShift: int.tryParse(_caesarController.text) ?? 3,
        vigenereKey: _vigenereController.text,
        railCount: int.tryParse(_railCountController.text) ?? 2,
      );

  Future<void> _decrypt() async {
    final cipherText = _cipherController.text.trim();
    if (cipherText.isEmpty) {
      setState(() => _error = context.l10n.crypto_emptyInput);
      return;
    }
    final algo = _algorithm;
    if (algo == null) return;
    try {
      final plaintext = CryptoToolbox.decrypt(
        ciphertext: cipherText,
        algorithmId: _algorithmId,
        params: _buildParams(),
      );
      if (!mounted) return;
      setState(() {
        _result = plaintext;
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
      key: const ValueKey('crypto-decrypt-sheet'),
      child: Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _buildCipherField(theme, s),
          const SizedBox(height: 12),
          CryptoAlgorithmTile(
            algorithmId: _algorithmId,
            autoDetected: _autoDetected,
            onSelected: (id) => setState(() {
              _algorithmId = id;
              _autoDetected = false;
              _result = null;
              _error = null;
            }),
          ),
          const SizedBox(height: 12),
          if (algo != null) _buildKeyFields(theme, s, algo),
          _buildRememberRow(theme, s, algo),
          const SizedBox(height: 12),
          Center(
            child: FilledButton.icon(
              key: const ValueKey('crypto-decrypt-action'),
              onPressed: _decrypt,
              icon: const Icon(Icons.lock_open_rounded, size: 18),
              label: Text(s.crypto_decrypt),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                    horizontal: 28, vertical: 12),
              ),
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            _buildMessageCard(
              theme,
              icon: Icons.error_outline_rounded,
              color: theme.colorScheme.error,
              text: _error!,
            ),
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

  Widget _buildCipherField(ThemeData theme, AppLocalizations s) {
    return TextField(
      key: const ValueKey('crypto-decrypt-cipher-input'),
      controller: _cipherController,
      minLines: 2,
      maxLines: 4,
      style: theme.textTheme.bodySmall
          ?.copyWith(fontFamily: 'monospace'),
      decoration: cryptoSheetInputDecoration(
        theme,
        labelText: s.crypto_ciphertext,
      ),
      onChanged: (_) {
        // 输入变化后重新嗅探算法
        final suggestion = CryptoToolbox.suggestDecrypt(
            _cipherController.text);
        if (suggestion.algorithmId != null &&
            suggestion.algorithmId != _algorithmId) {
          setState(() {
            _algorithmId = suggestion.algorithmId!;
            _autoDetected = true;
            _result = null;
            _error = null;
          });
        }
      },
    );
  }

  /// 按算法类型渲染密钥/参数输入区
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
                        key: ValueKey('crypto-remembered-pw-${pw.hashCode}'),
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
              key: const ValueKey('crypto-decrypt-password-input'),
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
              onSubmitted: (_) => _decrypt(),
            ),
            const SizedBox(height: 8),
          ],
        );
      case CryptoAlgorithmCategory.asymmetric:
        return Column(
          children: [
            TextField(
              key: const ValueKey('crypto-decrypt-pem-input'),
              controller: _pemController,
              minLines: 3,
              maxLines: 5,
              style: theme.textTheme.bodySmall
                  ?.copyWith(fontFamily: 'monospace'),
              decoration: cryptoSheetInputDecoration(
                theme,
                labelText: s.crypto_rsaPrivateKeyHint,
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
                key: const ValueKey('crypto-decrypt-caesar-input'),
                controller: _caesarController,
                keyboardType: TextInputType.number,
                decoration: cryptoSheetInputDecoration(
                  theme,
                  labelText: s.crypto_caesarShift,
                ),
              )
            else if (algo.id == 'vigenere')
              TextField(
                key: const ValueKey('crypto-decrypt-vigenere-input'),
                controller: _vigenereController,
                decoration: cryptoSheetInputDecoration(
                  theme,
                  labelText: s.crypto_vigenereKey,
                ),
              )
            else if (algo.id == 'railfence')
              TextField(
                key: const ValueKey('crypto-decrypt-rail-input'),
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
        if (algo.category == CryptoAlgorithmCategory.hash) {
          return Padding(
            padding: const EdgeInsets.only(top: 4),
            child: _buildMessageCard(
              theme,
              icon: Icons.info_outline_rounded,
              color: theme.colorScheme.tertiary,
              text: s.crypto_hashOneWay,
            ),
          );
        }
        return const SizedBox.shrink();
    }
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
      key: const ValueKey('crypto-decrypt-result'),
      title: s.crypto_result,
      content: result,
      actions: [
        FilledButton.tonalIcon(
          key: const ValueKey('crypto-decrypt-copy'),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: result));
            ToastService.showSuccess(s.common_copiedToClipboard);
          },
          icon: const Icon(Icons.copy_rounded, size: 18),
          label: Text(s.common_copy),
        ),
        if (widget.onQuoteReply != null)
          FilledButton.tonalIcon(
            key: const ValueKey('crypto-decrypt-quote'),
            onPressed: () {
              widget.onQuoteReply!.call(result);
              Navigator.of(context).pop();
            },
            icon: const Icon(Icons.format_quote_rounded, size: 18),
            label: Text(s.crypto_quoteReply),
          ),
      ],
    );
  }

  Widget _buildMessageCard(
    ThemeData theme, {
    required IconData icon,
    required Color color,
    required String text,
  }) {
    return CryptoSheetMessageCard(icon: icon, color: color, text: text);
  }
}
