import 'dart:async';
import 'dart:convert';

import '../../core/backend/agent_backend.dart';
import '../../core/models/agent_models.dart';
import 'codex_event_parser.dart';

/// OpenAI Codex CLI (`codex`) 어댑터.
/// - `codex exec --json` 및 `codex app-server --listen stdio://` 양방향 JSON-RPC 응답을 모두 지원합니다.
class CodexAdapter implements AgentBackend {
  CodexAdapter({
    ProcessSpawner? spawner,
    this.useAppServer = false,
  }) : _spawner = spawner ?? const IoProcessSpawner();

  final ProcessSpawner _spawner;
  final bool useAppServer;

  final StreamController<AgentEvent> _eventsController =
      StreamController<AgentEvent>.broadcast();
  final StreamController<String> _rawLogsController =
      StreamController<String>.broadcast();

  ManagedProcess? _process;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  CodexEventParser? _parser;
  AgentSessionConfig? _config;
  String? _activeThreadId;

  @override
  BackendType get backendType => BackendType.codex;

  @override
  Stream<AgentEvent> get events => _eventsController.stream;

  @override
  Stream<String> get rawLogs => _rawLogsController.stream;

  @override
  String? get remoteConversationId => _parser?.threadId ?? _activeThreadId;

  @override
  Future<void> start(AgentSessionConfig config) async {
    await _cleanupProcess();
    _config = config;
    _activeThreadId = config.conversationId;
    _parser = CodexEventParser(
      sessionId: config.sessionId,
      model: config.effectiveModel,
    );

    if (useAppServer) {
      _process = await _spawner.spawn(
        backendType.executable,
        ['app-server', '--listen', 'stdio://'],
        workingDirectory: config.workingDirectory,
        environment: config.environment,
      );
      _stdoutSub = _process!.stdoutLines.listen(_onStdoutLine);
      _stderrSub = _process!.stderrLines.listen(_onStderrLine);
    }
  }

  void _onStdoutLine(String line) {
    _rawLogsController.add(line);
    final parser = _parser;
    if (parser == null) return;
    final parsed = parser.parseLine(line);
    if (parser.threadId != null) {
      _activeThreadId = parser.threadId;
    }
    for (final ev in parsed) {
      _eventsController.add(ev);
    }
  }

  void _onStderrLine(String line) {
    _rawLogsController.add('[stderr] $line');
  }

  @override
  Future<void> send(
    String prompt, {
    List<String> attachments = const [],
  }) async {
    final cfg = _config;
    if (cfg == null) {
      throw StateError('CodexAdapter가 아직 시작되지 않았습니다.');
    }

    final buffer = StringBuffer();
    if (cfg.systemPromptAppend.isNotEmpty) {
      buffer.writeln(cfg.systemPromptAppend);
    }
    buffer.write(prompt);

    _eventsController.add(
      MessageEvent(
        id: 'user_${DateTime.now().microsecondsSinceEpoch}',
        sessionId: cfg.sessionId,
        backend: BackendType.codex,
        model: cfg.effectiveModel,
        timestamp: DateTime.now(),
        role: 'user',
        text: prompt,
      ),
    );

    if (useAppServer && _process != null) {
      final rpcReq = jsonEncode({
        'jsonrpc': '2.0',
        'id': DateTime.now().millisecondsSinceEpoch,
        'method': 'turn/start',
        'params': {
          'threadId': _activeThreadId ?? cfg.sessionId,
          'input': [
            {'type': 'text', 'text': buffer.toString()},
          ],
        },
      });
      _rawLogsController.add('[stdin] $rpcReq');
      _process!.writeLine(rpcReq);
      return;
    }

    // codex exec --json 실행 (세션 재개 시 resume 서브커맨드 활용)
    await _cleanupProcess();
    final args = <String>[
      'exec',
      '--json',
      '--skip-git-repo-check',
      '-C',
      cfg.workingDirectory,
      '-m',
      cfg.effectiveModel,
      if (cfg.effort != ReasoningEffort.auto) ...[
        '-c',
        'model_reasoning_effort="${cfg.effort.name}"',
      ],
      if (cfg.autoApproveBypassEnabled)
        '--dangerously-bypass-approvals-and-sandbox'
      else ...[
        '-s',
        'workspace-write',
      ],
      for (final dir in cfg.trustedDirectories)
        if (dir != cfg.workingDirectory) ...['--add-dir', dir],
      for (final img in attachments) ...['-i', img],
      ...cfg.extraArgs,
      if (_activeThreadId != null && _activeThreadId!.isNotEmpty) ...[
        'resume',
        _activeThreadId!,
      ],
      buffer.toString(),
    ];

    _process = await _spawner.spawn(
      backendType.executable,
      args,
      workingDirectory: cfg.workingDirectory,
      environment: cfg.environment,
    );
    _stdoutSub = _process!.stdoutLines.listen(_onStdoutLine);
    _stderrSub = _process!.stderrLines.listen(_onStderrLine);
    // 열어 두면 codex exec가 추가 입력을 기다리며 시작하지 않습니다.
    final process = _process;
    if (process is IoManagedProcess) await process.closeStdin();
  }

  @override
  Future<void> respondToApproval(ApprovalDecision decision) async {
    final proc = _process;
    if (proc == null) return;

    final decisionValue = decision.approved
        ? (decision.scope == ApprovalScope.session ||
                  decision.scope == ApprovalScope.always
              ? 'acceptForSession'
              : 'accept')
        : 'decline';

    final rpcId = int.tryParse(decision.requestId) ?? decision.requestId;
    final payload = jsonEncode({
      'jsonrpc': '2.0',
      'id': rpcId,
      'result': {
        'decision': decisionValue,
      },
    });
    _rawLogsController.add('[stdin] $payload');
    proc.writeLine(payload);
  }

  @override
  Future<void> respondToQuestion(
    String requestId,
    Map<String, List<String>> answers,
  ) async {
    final proc = _process;
    if (proc == null) return;

    final formatted = <String, dynamic>{
      for (final entry in answers.entries)
        entry.key: {'answers': entry.value},
    };
    final rpcId = int.tryParse(requestId) ?? requestId;
    final payload = jsonEncode({
      'jsonrpc': '2.0',
      'id': rpcId,
      'result': {
        'answers': formatted,
      },
    });
    _rawLogsController.add('[stdin] $payload');
    proc.writeLine(payload);
  }

  @override
  Future<void> interrupt() => _cleanupProcess();

  @override
  Future<void> resume(
    String conversationId,
    AgentSessionConfig config,
  ) async {
    _activeThreadId = conversationId;
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
    await _cleanupProcess();
    await _eventsController.close();
    await _rawLogsController.close();
  }
}
