import 'dart:async';
import 'dart:convert';

import '../../core/backend/agent_backend.dart';
import '../../core/models/agent_models.dart';
import 'claude_code_event_parser.dart';

/// Claude Code (`claude`) 어댑터.
/// `claude -p --input-format stream-json --output-format stream-json --verbose --permission-prompts host`
/// 프로토콜을 사용하여 양방향 메시지 전송, control_request 승인 응답, 세션 재개를 수행합니다.
class ClaudeCodeAdapter implements AgentBackend {
  ClaudeCodeAdapter({ProcessSpawner? spawner})
    : _spawner = spawner ?? const IoProcessSpawner();

  final ProcessSpawner _spawner;
  final StreamController<AgentEvent> _eventsController =
      StreamController<AgentEvent>.broadcast();
  final StreamController<String> _rawLogsController =
      StreamController<String>.broadcast();

  ManagedProcess? _process;
  StreamSubscription<String>? _stdoutSub;
  StreamSubscription<String>? _stderrSub;
  ClaudeCodeEventParser? _parser;
  AgentSessionConfig? _config;

  @override
  BackendType get backendType => BackendType.claudeCode;

  @override
  Stream<AgentEvent> get events => _eventsController.stream;

  @override
  Stream<String> get rawLogs => _rawLogsController.stream;

  @override
  String? get remoteConversationId => _parser?.remoteSessionId;

  @override
  Future<void> start(AgentSessionConfig config) async {
    await _cleanupProcess();
    _config = config;
    _parser = ClaudeCodeEventParser(
      sessionId: config.sessionId,
      model: config.effectiveModel,
    );

    final args = <String>[
      '-p',
      '--input-format',
      'stream-json',
      '--output-format',
      'stream-json',
      '--verbose',
      '--include-partial-messages',
      '--permission-prompts',
      'host',
      // 이 옵션이 없으면 권한 요청이 앱으로 오지 않고 자동 거부됩니다.
      '--permission-prompt-tool',
      'stdio',
      if (config.model.isNotEmpty) ...['--model', config.model],
      if (config.effort != ReasoningEffort.auto) ...[
        '--effort',
        config.effort.name,
      ],
      if (config.systemPromptAppend.isNotEmpty) ...[
        '--append-system-prompt',
        config.systemPromptAppend,
      ],
      if (config.conversationId != null &&
          config.conversationId!.isNotEmpty) ...[
        '--resume',
        config.conversationId!,
      ],
      if (config.skipsPermissions)
        '--dangerously-skip-permissions'
      else ...[
        '--permission-mode',
        switch (config.permissionMode) {
          PermissionMode.acceptEdits => 'acceptEdits',
          PermissionMode.plan => 'plan',
          // 앱의 자동 모드는 파괴적 작업을 묻기 위해 모든 요청을 앱에서 판별합니다.
          // Claude의 auto는 묻지 않고 지울 수 있어 쓰지 않습니다.
          _ => 'manual',
        },
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
  }

  @override
  Future<void> send(
    String prompt, {
    List<String> attachments = const [],
  }) async {
    final proc = _process;
    final cfg = _config;
    if (proc == null || cfg == null) {
      throw StateError('ClaudeCodeAdapter가 아직 시작되지 않았습니다.');
    }

    final buffer = StringBuffer(prompt);
    if (attachments.isNotEmpty) {
      buffer.writeln('\n\n[첨부 파일 경로]');
      for (final path in attachments) {
        buffer.writeln('- $path');
      }
    }

    _eventsController.add(
      MessageEvent(
        id: 'user_${DateTime.now().microsecondsSinceEpoch}',
        sessionId: cfg.sessionId,
        backend: BackendType.claudeCode,
        model: cfg.effectiveModel,
        timestamp: DateTime.now(),
        role: 'user',
        text: prompt,
      ),
    );

    final payload = jsonEncode({
      'type': 'user',
      'message': {
        'role': 'user',
        'content': buffer.toString(),
      },
    });
    _rawLogsController.add('[stdin] $payload');
    proc.writeLine(payload);
  }

  @override
  Future<void> respondToApproval(ApprovalDecision decision) async {
    final proc = _process;
    if (proc == null) return;

    final responseObj = decision.approved
        ? <String, dynamic>{
            'behavior': 'allow',
            'updatedInput': decision.updatedInput ?? <String, dynamic>{},
          }
        : <String, dynamic>{
            'behavior': 'deny',
            'message': decision.reason ?? '사용자가 도구 실행을 거부했습니다.',
          };

    final payload = jsonEncode({
      'type': 'control_response',
      'response': {
        'subtype': 'success',
        'request_id': decision.requestId,
        'response': responseObj,
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
    final flatAnswers = <String, String>{
      for (final entry in answers.entries) entry.key: entry.value.join(', '),
    };
    await respondToApproval(
      ApprovalDecision(
        requestId: requestId,
        approved: true,
        scope: ApprovalScope.once,
        // CLI는 원본 입력에 answers를 더한 값을 검증하므로 questions를 함께 보냅니다.
        updatedInput: {
          ...?_parser?.questionInputs.remove(requestId),
          'answers': flatAnswers,
        },
      ),
    );
  }

  @override
  Future<void> interrupt() => _cleanupProcess();

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
    await _cleanupProcess();
    await _eventsController.close();
    await _rawLogsController.close();
  }
}
