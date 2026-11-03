import 'dart:async';

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
  }) : _spawner = spawner ?? const IoProcessSpawner(),
       _hookBridge = hookBridge,
       _ownsHookBridge = hookBridge == null;

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
      if (config.model.isNotEmpty) ...['--model', config.model],
      if (config.conversationId != null &&
          config.conversationId!.isNotEmpty) ...[
        '--conversation',
        config.conversationId!,
      ],
      if (config.autoApproveBypassEnabled) '--dangerously-skip-permissions',
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

  void _onStdoutLine(String line) {
    _rawLogsController.add(line);
    final parser = _parser;
    if (parser == null) return;
    final parsed = parser.parseLine(line);
    for (final ev in parsed) {
      _eventsController.add(ev);
    }
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
    _hookBridge?.resolveApproval(decision);
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
  Future<void> interrupt() async {
    _process?.kill();
  }

  @override
  Future<void> resume(
    String conversationId,
    AgentSessionConfig config,
  ) async {
    await start(
      AgentSessionConfig(
        sessionId: config.sessionId,
        backendType: config.backendType,
        workingDirectory: config.workingDirectory,
        model: config.model,
        conversationId: conversationId,
        extraArgs: config.extraArgs,
        environment: config.environment,
        systemPromptAppend: config.systemPromptAppend,
        autoApproveBypassEnabled: config.autoApproveBypassEnabled,
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
