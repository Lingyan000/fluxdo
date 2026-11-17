import '../../plugin/metaverse_ui_validator.dart';
import '../../plugin/metaverse_component_contract.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';

import '../../../../constants.dart';
import '../../../../providers/core_providers.dart';
import '../../../../providers/theme_provider.dart';
import '../../../../services/log/log_writer.dart';
import '../../../../services/storage/secret_store.dart';
import '../../plugin/metaverse_plugin_host.dart';
import '../../plugin/metaverse_plugin_installer.dart';
import '../../plugin/metaverse_plugin_manifest.dart';
import '../../plugin/metaverse_plugin_store.dart';
import '../../plugin/providers/metaverse_plugin_providers.dart';
import 'development_connection.dart';
import 'development_engine.dart';

final metaverseDevelopmentSessionProvider =
    Provider.autoDispose<DevelopmentSession>((ref) {
      final session = DevelopmentSession(ref);
      ref.onDispose(session.dispose);
      ref.listen(currentUserProvider.select((user) => user.value?.id), (
        previous,
        next,
      ) {
        if (previous != next) {
          session.stop();
        }
      });
      return session;
    });

class DevelopmentProject {
  DevelopmentProject._(
    this.session,
    this.revision,
    this.manifest,
    this.ui,
    this.runner,
    this.entry,
  );
  final String session, ui, runner, entry;
  final int revision;
  final MetaversePluginManifest manifest;
  static DevelopmentProject parse(Map<String, dynamic> packet) {
    if (packet['protocolVersion'] != 1 ||
        packet['session'] is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(packet['session'] as String) ||
        packet['revision'] is! int ||
        (packet['revision'] as int) < 1 ||
        packet['runner'] is! String ||
        utf8.encode(packet['runner'] as String).length > 256 * 1024 ||
        packet['ui'] is! String ||
        utf8.encode(packet['ui'] as String).length >
            MetaversePluginInstaller.maxUiBytes ||
        packet['entry'] is! String ||
        !(packet['entry'] as String).startsWith('/') ||
        (packet['entry'] as String).length > 512) {
      throw const FormatException('development_project_invalid');
    }
    final manifest = MetaversePluginManifest.parse(
      packet['manifest'],
      reservedHosts: [Uri.parse(AppConstants.baseUrl).host],
    );
    if (manifest.apiVersion != 2) {
      throw const FormatException('development_requires_api2');
    }
    MetaversePluginInstaller.validateUi(manifest, packet['ui'] as String);
    final checked = validatePluginUiContract(
      packet['ui'] as String,
      metaverseComponentContract,
    );
    if ((checked['diagnostics'] as List).isNotEmpty) {
      throw FormatException((checked['diagnostics'] as List).join('\n'));
    }
    return DevelopmentProject._(
      packet['session'],
      packet['revision'],
      manifest,
      packet['ui'],
      packet['runner'],
      packet['entry'],
    );
  }
}

/// 一次显式配对的临时开发会话。离开页面、换账号时销毁引擎和临时数据。
class DevelopmentSession extends ChangeNotifier {
  DevelopmentSession(
    this._ref, {
    this.temporaryDirectory = getTemporaryDirectory,
  }) {
    connection = DevelopmentConnection(
      onMessage: _receive,
      onDisconnected: () {
        state = 'disconnected';
        _updates.clear();
        restartRequired = host != null;
        _notify();
        _scheduleReconnect();
      },
    );
    _tick = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (_lastBusy != busy) {
        _lastBusy = busy;
        _notify();
      }
      _drain();
    });
    _logs = LogWriter.instance.entries.listen((entry) {
      if (host != null &&
          entry['runtimeId'] == host!.runtimeId &&
          entry['pluginId'] == host!.id) {
        final now = DateTime.now();
        if (now.difference(_logWindow) >= const Duration(seconds: 1)) {
          _logWindow = now;
          _logCount = 0;
        }
        if (++_logCount <= 120) {
          connection.send({'type': 'log', 'entry': entry});
        }
      }
    });
  }
  final Ref _ref;
  final Future<Directory> Function() temporaryDirectory;
  late final DevelopmentConnection connection;
  late final Timer _tick;
  StreamSubscription<Map<String, dynamic>>? _logs;
  Timer? _reconnect;
  String? _pairing;
  int _reconnectCount = 0;
  int _generation = 0, _projectEpoch = 0;
  bool _lastBusy = false;
  bool _closed = false, _draining = false;
  bool foreground = true;
  String state = 'idle';
  final diagnostics = <String>[];
  final _updates = <Map<String, dynamic>>[];
  DevelopmentProject? project, pendingProject;
  MetaversePluginHost? host;
  DevelopmentEngine? _engine;
  MetaversePluginStore? _store;
  Directory? _directory;
  int revision = 0;
  bool restartRequired = false;
  int _logCount = 0;
  DateTime _logWindow = DateTime.now();
  bool get updating => _engine?.updating ?? false;
  bool get waiting => _updates.isNotEmpty;
  bool get busy => host?.hasActiveUi ?? false;
  void Function(BuildContext, String, Map<String, Object?>)? navigate;

  void _notify() {
    if (!_closed) {
      notifyListeners();
    }
  }

  void diagnostic(String message) {
    diagnostics.insert(
      0,
      message.length > 4096 ? message.substring(0, 4096) : message,
    );
    if (diagnostics.length > 20) {
      diagnostics.removeLast();
    }
    connection.send({'type': 'status', 'message': diagnostics.first});
    _notify();
  }

  Future<void> connect(String pairing) async {
    DevelopmentConnection.parse(pairing);
    if (busy) {
      return;
    }
    if (_pairing != null && _pairing != pairing) {
      stop();
    }
    _pairing = pairing;
    _reconnectCount = 0;
    await _connect();
  }

  Future<void> _connect() async {
    final pairing = _pairing;
    if (_closed || pairing == null) {
      return;
    }
    _reconnect?.cancel();
    state = 'connecting';
    _notify();
    try {
      await connection.connect(pairing);
      if (!_closed) {
        state = 'connected';
        _notify();
      }
    } catch (_) {
      if (_closed) {
        return;
      }
      state = 'disconnected';
      _notify();
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (_closed || _pairing == null || _reconnectCount >= 5) {
      return;
    }
    _reconnect = Timer(
      Duration(seconds: 1 << _reconnectCount++),
      () => unawaited(_connect()),
    );
  }

  void _receive(Map<String, dynamic> packet) {
    if (_closed) {
      return;
    }
    try {
      switch (packet['type']) {
        case 'project':
          final next = DevelopmentProject.parse(packet);
          _projectEpoch++;
          pendingProject = next;
          restartRequired = host != null;
          _updates.clear();
          _notify();
        case 'ui':
          if (packet['session'] != project?.session ||
              packet['revision'] is! int ||
              (packet['revision'] as int) <= revision ||
              packet['ui'] is! String ||
              utf8.encode(packet['ui'] as String).length >
                  MetaversePluginInstaller.maxUiBytes) {
            return;
          }
          MetaversePluginInstaller.validateUi(
            project!.manifest,
            packet['ui'] as String,
          );
          _enqueue(packet);
        case 'vite':
          if (restartRequired || pendingProject != null) {
            return;
          }
          final payload = packet['payload'];
          if (payload is! Map<String, dynamic>) {
            return;
          }
          if (payload['type'] == 'full-reload') {
            restartRequired = true;
            _notify();
            return;
          }
          if (payload['type'] == 'update') {
            _enqueue(packet);
            return;
          }
          // 模块调用响应不能排在更新队列后，否则更新会等待自身。
          unawaited(
            _engine
                ?.receive(payload)
                .catchError((Object e) => diagnostic('$e')),
          );
        case 'diagnostic':
          diagnostic('${packet['message']}');
      }
    } catch (error) {
      diagnostic('$error');
    }
  }

  void _enqueue(Map<String, dynamic> packet) {
    if (_updates.length >= 32) {
      _updates.clear();
      restartRequired = true;
      connection.send({'type': 'sync'});
    } else {
      _updates.add(packet);
    }
    _notify();
  }

  Future<void> _drain() async {
    if (_closed ||
        _draining ||
        !foreground ||
        updating ||
        restartRequired ||
        !connection.connected ||
        host?.canApplyDevelopmentUpdate != true ||
        _updates.isEmpty) {
      return;
    }
    _draining = true;
    final packet = _updates.removeAt(0);
    try {
      if (packet['type'] == 'ui') {
        host!.updateDevelopmentUi(packet['ui'] as String);
        revision = packet['revision'] as int;
        final current = project!;
        project = DevelopmentProject._(
          current.session,
          revision,
          current.manifest,
          packet['ui'] as String,
          current.runner,
          current.entry,
        );
        connection.send({
          'type': 'status',
          'message': 'RFW 更新完成，revision=$revision',
        });
      } else {
        await _engine?.receive(packet['payload']);
      }
    } catch (error) {
      diagnostic('$error');
    } finally {
      _draining = false;
      _notify();
    }
  }

  Future<void> start(DevelopmentProject next) async {
    if (_closed ||
        !connection.connected ||
        busy ||
        !identical(next, pendingProject ?? project)) {
      return;
    }
    final generation = ++_generation;
    final epoch = _projectEpoch;
    host?.shutdown();
    host = null;
    _engine = null;
    _updates.clear();
    final reusable =
        project?.session == next.session &&
        project?.manifest.id == next.manifest.id &&
        next.manifest.sameApprovalAs(project!.manifest);
    if (!reusable) {
      await _discardStorage();
      final temp = await temporaryDirectory();
      final directory = await Directory('${temp.path}/fluxdo-dev')
          .create(recursive: true);
      final temporary = await directory.createTemp('session-');
      if (_closed || generation != _generation) {
        await temporary.delete(recursive: true);
        return;
      }
      _directory = temporary;
      _store = MetaversePluginStore(
        preferences: _ref.read(sharedPreferencesProvider),
        secretStore: InMemorySecretStore(),
        rootDirectory: () async => temporary,
        isolated: true,
      );
    }
    if (_closed || generation != _generation) {
      return;
    }
    if (epoch != _projectEpoch) {
      await _discardStorage();
      _notify();
      return;
    }
    project = next;
    revision = next.revision;
    pendingProject = null;
    restartRequired = false;
    late final MetaversePluginHost created;
    created = createDevelopmentPluginHost(
      _ref,
      manifest: next.manifest,
      store: _store!,
      engineFactory: () async {
        final engine = await _ref.read(metaverseScriptEngineFactoryProvider)();
        if (_closed || generation != _generation) {
          engine.dispose();
          throw StateError('development_closed');
        }
        return _engine = DevelopmentEngine(
          engine,
          send: connection.send,
          reloadRequired: () {
            restartRequired = true;
            _notify();
          },
          diagnostic: diagnostic,
          changed: _notify,
        );
      },
      codeLoader: () async => (
        ui: next.ui,
        script: DevelopmentEngine.bootstrap(next.runner, next.entry),
      ),
      active: () =>
          !_closed && generation == _generation && identical(host, created),
      navigate: (context, page, params) =>
          navigate?.call(context, page, params),
      suspended: diagnostic,
    );
    host = created;
    _notify();
  }

  Future<void> _discardStorage() async {
    final directory = _directory;
    final store = _store;
    final pluginId = project?.manifest.id;
    _directory = null;
    _store = null;
    if (store != null && pluginId != null) {
      await store.deleteFiles(pluginId);
    }
    if (directory != null && await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

  void stop() {
    _generation++;
    _pairing = null;
    _reconnect?.cancel();
    connection.close();
    host?.shutdown();
    host = null;
    _engine = null;
    unawaited(_discardStorage());
    _updates.clear();
    pendingProject = null;
    project = null;
    restartRequired = false;
    state = 'idle';
    _notify();
  }

  @override
  void dispose() {
    if (_closed) {
      return;
    }
    _closed = true;
    stop();
    _tick.cancel();
    unawaited(_logs?.cancel());
    super.dispose();
  }
}
