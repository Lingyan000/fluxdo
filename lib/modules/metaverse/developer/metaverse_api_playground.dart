part of 'metaverse_developer_page.dart';

class _ApiGallery extends StatefulWidget {
  const _ApiGallery();
  @override
  State<_ApiGallery> createState() => _ApiGalleryState();
}

class _ApiGalleryState extends State<_ApiGallery> {
  final _search = TextEditingController();
  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final query = _search.text.trim().toLowerCase();
    final examples =
        metaverseApiExamples
            .where(
              (example) => '${example.name} ${example.description(l)}'
                  .toLowerCase()
                  .contains(query),
            )
            .toList()
          ..sort((a, b) => a.name.compareTo(b.name));
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: InputFieldShell(
            child: TextField(
              controller: _search,
              textAlignVertical: TextAlignVertical.center,
              decoration: InputDecoration(
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(vertical: 12),
                hintText: l.metaverse_apiSearch,
                prefixIcon: const Icon(Symbols.search_rounded),
                suffixIcon: query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: l.common_clear,
                        onPressed: () => setState(_search.clear),
                        icon: const Icon(Symbols.close_rounded),
                      ),
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
        ),
        Expanded(
          child: examples.isEmpty
              ? AppEmptyState(
                  icon: const Icon(Symbols.search_rounded),
                  title: l.common_noData,
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  itemCount: examples.length,
                  itemBuilder: (context, index) {
                    final example = examples[index];
                    return SegmentedCardItem(
                      index: index,
                      count: examples.length,
                      gap: 3,
                      color: PageBackgroundScope.contentColor(
                        context,
                        Theme.of(context).colorScheme.surfaceContainerLow,
                      ),
                      child: ListTile(
                        title: Text(
                          example.name,
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        subtitle: Text(example.description(l)),
                        trailing: const Icon(Symbols.chevron_right_rounded),
                        onTap: () => Navigator.of(context).push(
                          InteractionPageRoute(
                            builder: (_) =>
                                MetaverseApiPreviewPage(example: example),
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class MetaverseApiPreviewPage extends StatefulWidget {
  const MetaverseApiPreviewPage({super.key, required this.example});
  final MetaverseApiExample example;
  @override
  State<MetaverseApiPreviewPage> createState() => _ApiPreviewState();
}

class _ApiPreviewState extends State<MetaverseApiPreviewPage> {
  late final _arguments = TextEditingController(text: widget.example.arguments);
  final _message = TextEditingController(text: 'Hello, FluxDO!');
  final _url = TextEditingController(text: 'https://example.org');
  LinkOpenMode _browserMode = LinkOpenMode.ask;
  bool _previewGranted = false;
  final _storage = <String, Object?>{
    'example': {'value': 1},
  };
  final _events = <String>[];
  Uint8List? _pickedFile;
  final _uploads = <String, Object>{};
  MetaversePluginRuntime? _runtime;
  final _streamTimers = <String, List<Timer>>{};
  void _clearStreamPreviews() {
    for (final timers in _streamTimers.values) { for (final timer in timers) { timer.cancel(); } }
    _streamTimers.clear();
    _uploads.clear();
  }
  ToastType _toastType = ToastType.info;
  bool _failure = false, _running = false;
  int _generation = 0;
  String? _result;
  bool get _isToast => widget.example.name == 'toast';
  bool get _isBrowser => widget.example.name == 'browser.open';
  String get _input => _isToast
      ? '${jsonEncode(_message.text)}, ${jsonEncode(_toastType.name)}'
      : _isBrowser
      ? '${jsonEncode(_url.text)}, {mode: ${jsonEncode(_browserMode.name)}}'
      : _arguments.text;

  @override
  void dispose() {
    _generation++;
    _runtime?.dispose();
    _clearStreamPreviews();
    _arguments.dispose();
    _message.dispose();
    _url.dispose();
    super.dispose();
  }

  Future<void> _run() async {
    if (_running) return;
    FocusScope.of(context).unfocus();
    final generation = ++_generation;
    _runtime?.dispose();
    _clearStreamPreviews();
    setState(() {
      _events.clear();
      _result = null;
      _running = true;
    });
    try {
      final runtime = await MetaversePluginRuntime.start(
        engineFactory: createMetaverseScriptEngine,
        script: widget.example.scriptWith(_input),
        bridge: MetaverseDocumentationBridge(
          example: widget.example,
          failure: _failure,
          onCall: (method, params) async {
            if (!mounted || generation != _generation) {
              throw const PluginOperationCancelled();
            }
            final result = await _call(method, params);
            if (mounted && generation == _generation) {
              setState(
                () =>
                    _result = const JsonEncoder.withIndent('  ')
                        .convert(result),
              );
            }
            return result;
          },
          onLog: (level, message) {
            if (!mounted || generation != _generation) return;
            setState(() {
              _events.add('[$level] $message');
              if (_events.length > 50) _events.removeAt(0);
              if (level != 'call') _running = false;
              if (level == 'error') _result = message;
            });
          },
        ),
      );
      if (!mounted || generation != _generation) {
        runtime.dispose();
        return;
      }
      _runtime = runtime;
      final surface = runtime.openSurface(kind: 'card');
      if (widget.example.userAction) {
        runtime.dispatch(surface, 'action', const {});
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _events.add('$error');
          _result = '$error';
          _running = false;
        });
      }
    }
  }

  Future<Object?> _call(String method, Map<String, Object?> params) async {
    switch (method) {
      case 'files.pick':
        final file = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['png','jpg','jpeg','webp']);
        if(file?.path == null) return null;
        final bytes = await File(file!.path!).readAsBytes();
        if(bytes.length > 5 * 1024 * 1024) throw const MetaversePluginCallException('file_size_exceeded');
        _pickedFile = bytes;
        return {'handle':'example-file','name':file.name,'size':bytes.length,'mimeType':'image/png'};
      case 'files.preview':
        await ImageViewerPage.openWithLoader(context, loadImage: () async => _pickedFile ?? base64Decode(
          'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a1WQAAAAASUVORK5CYII='));
        return null;
      case 'files.release': _pickedFile = null; return null;
      case 'files.cancel': _uploads.remove(params['id']); return null;
      case 'files.upload':
        final id='${params['id']}';
        final generation=_generation;
        final operation = Object();
        _uploads[id] = operation;
        for(final step in [0,25,50,75,100]) {
          await Future<void>.delayed(const Duration(milliseconds:120));
          if(!mounted || generation != _generation || !identical(_uploads[id],operation)) throw const PluginOperationCancelled();
          final runtime=_runtime,surface=_runtime?.surfaces.firstOrNull;
          if(runtime != null && surface != null) runtime.dispatch(surface,'files.progress',{'id':id,'sent':step,'total':100});
          setState(()=>_events.add('files.progress $step%'));
        }
        _uploads.remove(id);
        return {'status':200,'headers':<String,String>{},'body':'{"example":true}'};
      case 'captcha.request':
        return showCaptchaSheet<String>(context:context,title:context.l10n.metaverse_developerPreview,
          builder:(_)=>MetaverseCaptchaContent(pluginName:context.l10n.metaverse_developerExample,
            request:MetaverseCaptchaRequest(MetaverseCaptchaProvider.hcaptcha,Uri.parse('https://example.org'),'example'),
            checkActive:(){if(!mounted)throw const PluginOperationCancelled();},
            challengeBuilder:(context,event){
              WidgetsBinding.instance.addPostFrameCallback((_){event('challenge','');});
              return Center(child:FilledButton(onPressed:()=>event('token','example-token'),child:Text(context.l10n.common_confirm)));
            }));
      case 'streams.close':
        for (final timer in _streamTimers.remove(params['id']) ?? <Timer>[]) { timer.cancel(); }
        return null;
      case 'streams.open':
        final id = '${params['id']}';
        final generation = _generation;
        for (final timer in _streamTimers.remove(id) ?? <Timer>[]) { timer.cancel(); }
        _streamTimers[id] = [
          for (final (delay, name, event) in [
            (250, 'stream.state', {'id': id, 'state': 'open'}),
            (600, 'stream.event', {'id': id, 'event': 'count.changed', 'data': '{"unread":1}', 'lastEventId': '1'}),
            (1100, 'stream.state', {'id': id, 'state': 'retrying', 'retryInMs': 1000}),
            (2100, 'stream.state', {'id': id, 'state': 'open'}),
            (2400, 'stream.event', {'id': id, 'event': 'count.changed', 'data': '{"unread":2}', 'lastEventId': '2'}),
          ]) Timer(Duration(milliseconds: delay), () {
            if (!mounted || generation != _generation) return;
            final runtime = _runtime, surface = _runtime?.surfaces.firstOrNull;
            if (runtime != null && surface != null) runtime.dispatch(surface, name, event);
          }),
        ];
        return id;
      case 'host.environment':
        return {'locale': Localizations.localeOf(context).toLanguageTag(), 'platform': Theme.of(context).platform.name, 'timeZoneOffsetMinutes': DateTime.now().timeZoneOffset.inMinutes};
      case 'host.features':
        return PluginFeatures.supported.toList();
      case 'permissions.status':
        return {'forumActivity': _previewGranted};
      case 'permissions.request':
        final names = params['names'];
        if (names is! List || names.isEmpty || names.any((p) => p != 'forumActivity')) {
          throw const MetaversePluginCallException('permission_not_requestable');
        }
        return _previewGranted = _previewGranted || await showMetaverseConfirmation(context, context.l10n.metaverse_developerExample,
          {'title': context.l10n.metaverse_requestAccess(context.l10n.metaverse_developerExample),
           'message': context.l10n.metaverse_forumActivity, 'confirmLabel': context.l10n.common_allow});
      case 'dialogs.confirm':
        return showMetaverseConfirmation(context, context.l10n.metaverse_developerExample, params);
      case 'toast':
        showMetaversePluginToast(
          context.l10n.metaverse_developerExample,
          '${params['message']}',
          '${params['type']}',
        );
        return null;
      case 'browser.open':
      case 'openUrl':
        final uri = Uri.tryParse('${params['url']}');
        if (uri == null ||
            uri.host.isEmpty ||
            !['http', 'https'].contains(uri.scheme)) {
          throw const MetaversePluginCallException('invalid_url');
        }
        await launchExternalLink(
          context,
          uri.toString(),
          mode: method == 'browser.open'
              ? LinkOpenMode.values.byName('${params['mode'] ?? 'ask'}')
              : LinkOpenMode.preference,
        );
        return null;
      case 'forum.open':
      case 'navigate':
        final route = InteractionPageRoute<void>(
              builder: (ctx) => Scaffold(
                appBar: AppBar(title: Text('${params['page'] ?? params['type']}')),
                body: Padding(
                  padding: const EdgeInsets.all(16),
                  child: _CodeBlock(
                    title: ctx.l10n.metaverse_developerParameters,
                    code: const JsonEncoder.withIndent('  ')
                        .convert(params['params'] ?? params),
                  ),
                ),
              ),
            );
        if (method == 'navigate' && params['replace'] == true) {
          unawaited(Navigator.of(context).pushReplacement<void, void>(route));
        } else {
          unawaited(Navigator.of(context).push(route));
        }
        return null;
      case 'navigation.prepare':
        return 1;
      case 'payments.request':
        return await showLdcPaymentSheet(
              context,
              payment: _DocumentationPayment(context.l10n, params),
              orderNo: '${params['reference']}',
              username: 'demo',
            ) ??
            {'state': 'cancelled'};
      case 'credentials.request':
      case 'connect.authorize':
      case 'session.login':
      case 'session.open':
        final confirmed = await showAppDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(ctx.l10n.metaverse_developerPreview),
            content: Text(widget.example.description(ctx.l10n)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(ctx.l10n.common_cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(ctx.l10n.common_continue),
              ),
            ],
          ),
        );
        if (method == 'credentials.request') return confirmed == true;
        if (confirmed != true) {
          throw const MetaversePluginCallException('cancelled');
        }
        return widget.example.result;
      case 'storage.compareAndSet':
        final key = params['key'] as String;
        if (!const DeepCollectionEquality().equals(_storage[key], params['expected'])) return false;
        if (params['value'] == null) { _storage.remove(key); } else { _storage[key] = params['value']; }
        return true;
      case 'storage.get':
        return _storage['${params['key']}'];
      case 'storage.set':
        _storage['${params['key']}'] = params['value'];
        return null;
      case 'storage.remove':
        _storage.remove('${params['key']}');
        return null;
      case 'storage.setMany':
        for (final entry in (params['entries'] as Map).entries) {
          if (entry.value == null) {
            _storage.remove(entry.key);
          } else {
            _storage[entry.key as String] = entry.value;
          }
        }
        return null;
      case 'crypto.uuid':
        return const Uuid().v4();
      case 'crypto.pkce':
        final random = Random.secure();
        final verifier = base64Url
            .encode(List.generate(32, (_) => random.nextInt(256)))
            .replaceAll('=', '');
        return {
          'verifier': verifier,
          'challenge': base64Url
              .encode(sha256.convert(utf8.encode(verifier)).bytes)
              .replaceAll('=', ''),
          'method': 'S256',
        };
      case 'crypto.sha256':
        return sha256.convert(utf8.encode('${params['text']}')).toString();
      default:
        return widget.example.result;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = context.l10n;
    final theme = Theme.of(context);
    final example = widget.example;
    return Scaffold(
      appBar: AppBar(title: Text(example.name)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(example.description(l), style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            l.metaverse_apiDemoHint,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            l.metaverse_developerParameters,
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 8),
          InputFieldShell(
            child: TextField(
              controller: _isToast
                  ? _message
                  : _isBrowser
                  ? _url
                  : _arguments,
              enabled: !_running,
              minLines: _isToast || _isBrowser ? 1 : 2,
              maxLines: _isToast || _isBrowser ? 3 : 8,
              decoration: InputDecoration(
                contentPadding: const EdgeInsets.all(16),
                hintText: _isToast
                    ? l.metaverse_developerExample
                    : l.metaverse_apiArgumentsHint,
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
          if (_isToast)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Wrap(
                spacing: 8,
                children: [
                  for (final type in ToastType.values)
                    ChoiceChip(
                      label: Text(type.name),
                      selected: _toastType == type,
                      onSelected: _running
                          ? null
                          : (_) => setState(() => _toastType = type),
                    ),
                ],
              ),
            ),
          if (_isBrowser)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  for (final mode in LinkOpenMode.values)
                    ChoiceChip(
                      label: Text(switch (mode) {
                        LinkOpenMode.preference =>
                          l.metaverse_apiBrowserPreference,
                        LinkOpenMode.inApp => l.externalLink_openInAppBrowser,
                        LinkOpenMode.ask => l.metaverse_apiBrowserAsk,
                        LinkOpenMode.external =>
                          l.externalLink_openInSystemBrowser,
                      }),
                      selected: _browserMode == mode,
                      onSelected: _running
                          ? null
                          : (_) => setState(() => _browserMode = mode),
                    ),
                ],
              ),
            ),
          const SizedBox(height: 16),
          SegmentedCardGroup(
            children: [
              ListTile(
                title: Text(l.metaverse_marketCompatibility),
                trailing: Text('API ${example.apiVersion}'),
              ),
              if (example.permission case final permission?)
                ListTile(
                  title: Text(l.metaverse_marketPermissions),
                  subtitle: Text(permission),
                ),
              M3eSwitchListTile(
                title: Text(l.metaverse_developerSimulateFailure),
                value: _failure,
                onChanged: _running
                    ? null
                    : (value) => setState(() => _failure = value),
              ),
            ],
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: _running ? null : _run,
            icon: _running
                ? const LoadingSpinner(size: 18)
                : const Icon(Symbols.play_arrow_rounded),
            label: Text(l.metaverse_developerRun),
          ),
          if (_result != null) ...[
            const SizedBox(height: 20),
            _CodeBlock(title: l.metaverse_apiResult, code: _result!),
          ],
          if (example.name.startsWith('storage.') && _result != null) ...[
            const SizedBox(height: 16),
            _CodeBlock(
              title: l.metaverse_pluginData,
              code: const JsonEncoder.withIndent('  ').convert(_storage),
            ),
          ],
          const SizedBox(height: 20),
          _CodeBlock(
            title: l.metaverse_developerCode,
            code: example.scriptWith(_input),
          ),
          if (_events.isNotEmpty) ...[
            const SizedBox(height: 20),
            _CodeBlock(
              title: l.metaverse_developerEvents,
              code: _events.join('\n'),
            ),
          ],
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

/// 只改变演示订单的内存状态，供真实收银台组件展示完整交互。
class _DocumentationPayment implements LdcPaymentDelegate {
  _DocumentationPayment(this.l, this.options);
  final AppLocalizations l;
  final Map<String, Object?> options;
  bool _paid = false;
  @override
  Future<LdcPaymentOrder> prepare(String orderNo, String username) async {
    final amount = '${options['amount']}';
    if (LdcPaymentService.amountCents(amount) == null) {
      throw const LdcPaymentException('invalid_amount');
    }
    return LdcPaymentOrder(
      token: 'demo',
      orderNo: orderNo,
      name: l.metaverse_apiPaymentDemo,
      amount: amount,
      payer: username,
      payee: 'demo',
      merchant: l.metaverse_developerExample,
      expiresAt: DateTime.now().toUtc().add(const Duration(hours: 1)),
    );
  }

  @override
  Future<void> pay(LdcPaymentOrder order, String password) async {
    await Future<void>.delayed(const Duration(milliseconds: 900));
    _paid = true;
  }

  @override
  Future<bool> refreshPayment(String orderNo) async => _paid;
  @override
  Future<void> setInitialPassword(String password, String username) async {}
}
