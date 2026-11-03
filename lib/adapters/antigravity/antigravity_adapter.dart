import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/backend/agent_backend.dart';
import '../../core/backend/local_hook_bridge.dart';
import '../../core/models/agent_models.dart';
import 'antigravity_event_parser.dart';

/// Google Antigravity CLI (`agy`) 어댑터.
/// `agy --input-format stream-json --output-format stream-json` 프로토콜 및
/// LocalHookBridgeServer를 통해 실시간 스트리밍·승인·질문·세션 재개를 처리합니다.
class AntigravityAdapter implements AgentBackend {
  AntigravityAdapter({
    ProcessSpawner? spawner,
    LocalHookBridgeServer? hookBridge,
    File? userSettingsFile,
  }) : _userSettingsFile = userSettingsFile ?? _defaultUserSettingsFile(),
       _spawner = spawner ?? const IoProcessSpawner(),
       _hookBridge = hookBridge,
       _ownsHookBridge = hookBridge == null;

  static File _defaultUserSettingsFile() => File(
    '${Platform.environment['HOME'] ?? ''}/.gemini/antigravity-cli/settings.json',
  );

  final File _userSettingsFile;
  final ProcessSpawner _spawner;
  LocalHookBridgeServer? _hookBridge;
  final bool _ownsHookBridge;

  final StreamController<AgentEvent> _eventsController =
      StreamController<AgentEvent>.broadcast();
  final StreamController<String> _rawLogsController =
      StreamController<String>.broadcast();

  ManagedProcess? _process;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  StreamSubscription<ApprovalRequestData>? _hookApprovalSub;
  AntigravityEventParser? _parser;
  AgentSessionConfig? _config;

  /// 사용자의 답을 기다리는 자동 거부 규칙 (요청 ID → 규칙)
  final Map<String, String> _deniedRules = {};
  final List<String> _newlyApprovedRules = [];

  // ponytail: 1회 승인도 이 프로세스가 끝날 때까지 유지됩니다. --settings는 시작할 때만 적용되기 때문입니다.
  final Set<String> _allowedRules = {};
  DoneEvent? _heldDone;
  TokenUsage _carriedUsage = const TokenUsage();

  @override
  BackendType get backendType => BackendType.antigravity;

  @override
  Stream<AgentEvent> get events => _eventsController.stream;

  @override
  Stream<String> get rawLogs => _rawLogsController.stream;

  @override
  String? get remoteConversationId => _parser?.conversationId;

  @override
  Future<void> start(AgentSessionConfig config) async {
    await _cleanupProcess();
    _config = config;
    _parser = AntigravityEventParser(
      sessionId: config.sessionId,
      model: config.effectiveModel,
    );

    _hookBridge ??= LocalHookBridgeServer();
    await _hookBridge!.start();
    await _hookApprovalSub?.cancel();
    _hookApprovalSub = _hookBridge!.approvalRequests
        .where((req) => req.sessionId == config.sessionId)
        .listen((req) {
          _eventsController.add(
            ApprovalRequestEvent(
              request: req,
              model: config.effectiveModel,
              rawLog: jsonEncodeHook(req),
            ),
          );
        });

    final args = <String>[
      '--input-format',
      'stream-json',
      '--output-format',
      'stream-json',
      if (config.model.isNotEmpty || config.effort != ReasoningEffort.auto) ...[
        '--model',
        backendType.cliModel(config.effectiveModel, config.effort),
      ],
      if (config.conversationId != null &&
          config.conversationId!.isNotEmpty) ...[
        '--conversation',
        config.conversationId!,
      ],
      if (config.skipsPermissions)
        '--dangerously-skip-permissions'
      else
        ...switch (config.permissionMode) {
          // 지원하지 않는 계정이면 agy가 경고만 내고 기본 모드로 실행합니다.
          PermissionMode.auto => ['--mode', 'auto'],
          PermissionMode.acceptEdits => ['--mode', 'accept-edits'],
          PermissionMode.plan => ['--mode', 'plan'],
          _ => const <String>[],
        },
      if (_allowedRules.isNotEmpty || config.trustedDirectories.isNotEmpty) ...[
        '--settings',
        jsonEncode({
          'permissions': {
            'allow': {
              ..._userAllowRules(),
              for (final dir in config.trustedDirectories) ...[
                'read_file($dir)',
                'write_file($dir)',
              ],
              ..._allowedRules,
            }.toList(),
          },
        }),
      ],
      ...config.extraArgs,
    ];

    _process = await _spawner.spawn(
      backendType.executable,
      args,
      workingDirectory: config.workingDirectory,
      environment: config.environment,
    );

    _stdoutSub = _process!.stdoutLines.listen(_onStdoutLine);
    _stderrSub = _process!.stderrLines.listen(_onStderrLine);
  }

  String jsonEncodeHook(ApprovalRequestData req) =>
      '{"hook":"PreToolUse","tool":"${req.toolName}","resource":"${req.targetResource}"}';

  /// 사용자의 기존 허용 규칙을 --settings가 가리지 않도록 함께 넘깁니다.
  List<String> _userAllowRules() {
    try {
      final saved =
          jsonDecode(_userSettingsFile.readAsStringSync())
              as Map<String, dynamic>;
      final permissions = saved['permissions'] as Map<String, dynamic>?;
      return (permissions?['allow'] as List?)?.cast<String>() ?? const [];
    } on Exception catch (_) {
      return const [];
    } on TypeError catch (_) {
      return const [];
    }
  }

  void _onStdoutLine(String line) {
    _rawLogsController.add(line);
    final parser = _parser;
    if (parser == null) return;
    final parsed = parser.parseLine(line);
    for (final ev in parsed) {
      if (ev is DoneEvent) {
        _heldDone = ev;
        unawaited(_settleTurn());
        continue;
      }
      if (ev is ApprovalRequestEvent &&
          ev.id.startsWith(AntigravityEventParser.deniedRequestPrefix)) {
        _deniedRules[ev.id] = parser.deniedRules[ev.id]!;
      }
      _eventsController.add(ev);
    }
  }

  /// 거부된 명령에 모두 답하면 승인된 명령으로 대화를 잇거나 턴을 끝냅니다.
  Future<void> _settleTurn() async {
    final done = _heldDone;
    final cfg = _config;
    if (done == null || cfg == null || _deniedRules.isNotEmpty) return;
    _heldDone = null;
    final usage = _carriedUsage + done.usage;
    final approved = List.of(_newlyApprovedRules);
    _newlyApprovedRules.clear();
    final conversationId = _parser?.conversationId;
    if (approved.isEmpty || conversationId == null) {
      _carriedUsage = const TokenUsage();
      _eventsController.add(
        DoneEvent(
          id: done.id,
          sessionId: done.sessionId,
          backend: done.backend,
          model: done.model,
          timestamp: done.timestamp,
          conversationId: done.conversationId,
          usage: usage,
          durationMs: done.durationMs,
          stopReason: done.stopReason,
          rawLog: done.rawLog,
        ),
      );
      return;
    }
    _carriedUsage = usage;
    await resume(conversationId, cfg);
    await send(
      '사용자가 다음 권한을 승인했습니다. 거부됐던 작업을 다시 실행하고 중단된 작업을 이어가세요.\n'
      '${approved.map((c) => '- $c').join('\n')}',
    );
  }

  void _onStderrLine(String line) {
    _rawLogsController.add('[stderr] $line');
    if (line.trim().startsWith('Error:') || line.trim().startsWith('error:')) {
      _eventsController.add(
        ErrorEvent(
          id: 'agy_stderr_${DateTime.now().microsecondsSinceEpoch}',
          sessionId: _config?.sessionId ?? 'default',
          backend: BackendType.antigravity,
          model: _config?.effectiveModel ?? '',
          timestamp: DateTime.now(),
          message: line.trim(),
          rawLog: line,
        ),
      );
    }
  }

  @override
  Future<void> send(
    String prompt, {
    List<String> attachments = const [],
  }) async {
    final proc = _process;
    final cfg = _config;
    if (proc == null || cfg == null) {
      throw StateError('AntigravityAdapter가 아직 시작되지 않았습니다.');
    }

    final buffer = StringBuffer();
    if (cfg.systemPromptAppend.isNotEmpty) {
      buffer.writeln(cfg.systemPromptAppend);
    }
    buffer.write(prompt);
    if (attachments.isNotEmpty) {
      buffer.writeln('\n\n[첨부 파일 경로]');
      for (final path in attachments) {
        buffer.writeln('- $path');
      }
    }

    final fullPrompt = buffer.toString();

    // 사용자 메시지 이벤트를 타임라인에 즉시 발행
    _eventsController.add(
      MessageEvent(
        id: 'user_${DateTime.now().microsecondsSinceEpoch}',
        sessionId: cfg.sessionId,
        backend: BackendType.antigravity,
        model: cfg.effectiveModel,
        timestamp: DateTime.now(),
        role: 'user',
        text: prompt,
      ),
    );

    final escaped = fullPrompt
        .replaceAll(r'\', r'\\')
        .replaceAll('"', r'\"')
        .replaceAll('\n', r'\n')
        .replaceAll('\r', r'\r');
    final payload = '{"event":"user","message":{"content":"$escaped"}}';
    _rawLogsController.add('[stdin] $payload');
    proc.writeLine(payload);
  }

  @override
  Future<void> respondToApproval(ApprovalDecision decision) async {
    final rule = _deniedRules.remove(decision.requestId);
    if (rule == null) {
      _hookBridge?.resolveApproval(decision);
      return;
    }
    if (decision.approved) {
      _allowedRules.add(rule);
      _newlyApprovedRules.add(rule);
    }
    await _settleTurn();
  }

  @override
  Future<void> respondToQuestion(
    String requestId,
    Map<String, List<String>> answers,
  ) async {
    final summary = answers.entries
        .map((e) => '${e.key}: ${e.value.join(", ")}')
        .join('\n');
    await send(summary);
  }

  @override
  Future<void> interrupt() {
    _deniedRules.clear();
    _newlyApprovedRules.clear();
    _heldDone = null;
    return _cleanupProcess();
  }

  @override
  Future<void> resume(String conversationId, AgentSessionConfig config) async {
    await start(
      AgentSessionConfig(
        sessionId: config.sessionId,
        backendType: config.backendType,
        workingDirectory: config.workingDirectory,
        model: config.model,
        effort: config.effort,
        conversationId: conversationId,
        extraArgs: config.extraArgs,
        environment: config.environment,
        systemPromptAppend: config.systemPromptAppend,
        autoApproveBypassEnabled: config.autoApproveBypassEnabled,
        trustedDirectories: config.trustedDirectories,
        permissionMode: config.permissionMode,
      ),
    );
  }

  Future<void> _cleanupProcess() async {
    await _stdoutSub?.cancel();
    await _stderrSub?.cancel();
    _stdoutSub = null;
    _stderrSub = null;
    _process?.kill();
    _process = null;
  }

  @override
  Future<void> dispose() async {
    await _hookApprovalSub?.cancel();
    _hookApprovalSub = null;
    await _cleanupProcess();
    if (_ownsHookBridge) {
      await _hookBridge?.dispose();
    }
    await _eventsController.close();
    await _rawLogsController.close();
  }
}
