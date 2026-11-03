import 'dart:convert';

enum TargetDeviceType {
  macosDesktop(id: 'macos', label: 'macOS (Desktop)'),
  iosDeviceOrSim(id: 'ios', label: 'iOS (iPhone / iPad / Simulator)'),
  androidDeviceOrEmu(id: 'android', label: 'Android (Device / Emulator)'),
  chromeWeb(id: 'chrome', label: 'Web (Chrome)'),
  windowsDesktop(id: 'windows', label: 'Windows (Desktop)'),
  linuxDesktop(id: 'linux', label: 'Linux (Desktop)');

  const TargetDeviceType({
    required this.id,
    required this.label,
  });

  final String id;
  final String label;
}

enum BackendType {
  antigravity(
    id: 'agy',
    displayName: 'Google Antigravity',
    executable: 'agy',
    defaultModel: 'gemini-3.8-flash',
    availableModels: ['gemini-3.8-flash', 'gemini-4-argon'],
    supportedEfforts: [
      ReasoningEffort.low,
      ReasoningEffort.medium,
      ReasoningEffort.high,
    ],
    defaultEffort: ReasoningEffort.high,
    effortInModelId: true,
    slashCommands: [
      '/load',
      '/resume',
      '/help',
      '/skills',
      '/model',
      '/effort',
      '/context',
      '/usage',
      '/compact',
      '/plan',
      '/goal',
      '/browser',
      '/schedule',
    ],
    installCommand: 'agy install',
    installGuide: 'https://antigravity.google/docs/cli/reference 에서 Antigravity CLI를 설치하세요.',
  ),
  claudeCode(
    id: 'claude',
    displayName: 'Claude Code',
    executable: 'claude',
    defaultModel: 'claude-sonnet-5-5',
    availableModels: [
      'claude-sonnet-5-5',
      'claude-opus-5-5',
      'sonnet',
      'opus',
    ],
    slashCommands: [
      '/load',
      '/resume',
      '/compact',
      '/clear',
      '/model',
      '/effort',
      '/doctor',
      '/review',
      '/verify',
      '/simplify',
      '/ego-browser',
      '/cli-hub-meta-skill',
    ],
    installCommand: 'claude install',
    installGuide: 'curl -fsSL https://claude.ai/install.sh | bash 로 Claude Code를 설치하세요.',
  ),
  codex(
    id: 'codex',
    displayName: 'OpenAI Codex',
    executable: 'codex',
    defaultModel: 'gpt-6-sol',
    availableModels: [
      'gpt-6-sol',
      'gpt-6-astra',
      'gpt-6.1-terra',
      'gpt-5.6-sol',
      'codex-auto-review',
    ],
    slashCommands: [
      '/load',
      '/resume',
      '/review',
      '/compact',
      '/model',
      '/skills',
      '/diff',
      '/clear',
    ],
    installCommand: 'brew install codex',
    installGuide: 'npm i -g @openai/codex 또는 brew install codex 로 OpenAI Codex CLI를 설치하세요.',
  );

  const BackendType({
    required this.id,
    required this.displayName,
    required this.executable,
    required this.defaultModel,
    required this.availableModels,
    required this.slashCommands,
    required this.installCommand,
    required this.installGuide,
    this.supportedEfforts = ReasoningEffort.values,
    this.defaultEffort = ReasoningEffort.auto,
    this.effortInModelId = false,
  });

  final String id;
  final String displayName;
  final String executable;
  final String defaultModel;
  final List<String> availableModels;
  final List<String> slashCommands;
  final String installCommand;
  final String installGuide;
  final List<ReasoningEffort> supportedEfforts;
  final ReasoningEffort defaultEffort;

  /// true면 CLI 모델 ID 끝에 강도를 붙입니다. 예: `gemini-3.8-flash-high`
  final bool effortInModelId;

  /// 강도 접미사를 뺀 모델 이름. 목록에 없는 모델은 그대로 둡니다.
  String baseModel(String model) {
    final suffix = _effortSuffixOf(model);
    return suffix == null
        ? model
        : model.substring(0, model.length - suffix.name.length - 1);
  }

  /// 지원하지 않는 강도는 모델 ID의 접미사나 백엔드 기본값으로 바꿉니다.
  ReasoningEffort resolveEffort(ReasoningEffort effort, String model) {
    if (supportedEfforts.contains(effort)) return effort;
    return _effortSuffixOf(model) ?? defaultEffort;
  }

  /// CLI `--model`에 넘길 ID. 강도가 모델 ID에 들어가는 백엔드만 조합합니다.
  String cliModel(String model, ReasoningEffort effort) {
    if (!effortInModelId) return model;
    final base = baseModel(model);
    if (!availableModels.contains(base)) return model;
    return '$base-${resolveEffort(effort, model).name}';
  }

  ReasoningEffort? _effortSuffixOf(String model) {
    if (!effortInModelId) return null;
    for (final effort in supportedEfforts) {
      final suffix = '-${effort.name}';
      if (model.endsWith(suffix) &&
          availableModels.contains(
            model.substring(0, model.length - suffix.length),
          )) {
        return effort;
      }
    }
    return null;
  }

  static BackendType fromId(String id) {
    return BackendType.values.firstWhere(
      (b) => b.id == id || b.name == id,
      orElse: () => BackendType.antigravity,
    );
  }
}

/// CLI에 전달하는 추론 강도. [auto]는 옵션을 넘기지 않아 CLI·모델 기본값을 따릅니다.
enum ReasoningEffort {
  auto('Default'),
  low('Low'),
  medium('Medium'),
  high('High'),
  xhigh('XHigh'),
  max('Max');

  const ReasoningEffort(this.label);
  final String label;
}

/// 세션의 권한 처리 방식
enum PermissionMode {
  auto('자동', '파괴적인 작업만 묻고 나머지는 자동으로 허용합니다'),
  manual('수동', '변경하기 전에 항상 확인합니다'),
  acceptEdits('편집 자동 수락', '파일 읽기·편집은 자동으로 허용하고 명령은 확인합니다'),
  plan('계획', '변경하기 전에 계획을 세웁니다'),
  bypass('권한 무시', '모든 권한 확인을 건너뜁니다. 파괴적인 작업도 묻지 않습니다');

  const PermissionMode(this.label, this.description);
  final String label;
  final String description;
}

enum ApprovalScope {
  once('이번만 허용'),
  session('이 세션 동안 허용'),
  always('항상 허용'),
  denied('거부');

  const ApprovalScope(this.label);
  final String label;
}

enum ApprovalCategory {
  shellCommand('셸 명령 실행'),
  fileWrite('파일 쓰기/수정'),
  fileDelete('파일 삭제'),
  networkAccess('네트워크 접근'),
  externalSoftware('외부 소프트웨어 실행'),
  skillSiteAccess('스킬: 웹사이트 접근 (ego-browser)'),
  skillProgramExec('스킬: 프로그램 실행/설치 (cli-hub)'),
  osPermission('OS 권한 요청'),
  accountAuth('계정/API 인증 스코프'),
  destructive('파괴적 작업 (항상 확인 필수)');

  const ApprovalCategory(this.label);
  final String label;
}

class ApprovalRequestData {
  const ApprovalRequestData({
    required this.id,
    required this.sessionId,
    required this.backend,
    required this.toolName,
    required this.arguments,
    required this.category,
    required this.reason,
    required this.isDestructive,
    required this.createdAt,
    this.targetResource = '',
  });

  final String id;
  final String sessionId;
  final BackendType backend;
  final String toolName;
  final Map<String, dynamic> arguments;
  final ApprovalCategory category;
  final String reason;
  final bool isDestructive;
  final DateTime createdAt;
  final String targetResource;

  String get formattedArguments =>
      const JsonEncoder.withIndent('  ').convert(arguments);

  static bool detectDestructive(String toolName, Map<String, dynamic> args) {
    final lowerTool = toolName.toLowerCase();
    if (lowerTool.contains('delete') || lowerTool.contains('remove')) {
      return true;
    }
    final command = args['CommandLine'] ?? args['command'] ?? args['cmd'];
    // 파일 내용에 'rm -rf'가 적혀 있는 것과 실행하는 것은 다르므로 파일 도구는 내용을 보지 않습니다.
    const pathKeys = ['file_path', 'notebook_path', 'Path', 'TargetFile', 'path'];
    if (command == null && pathKeys.any(args.containsKey)) return false;
    final joined = (command ?? jsonEncode(args)).toString().toLowerCase();
    // ponytail: 명령 문자열 패턴 판별이라 스크립트 안의 삭제나 우회 표현은 못 잡습니다. 놓친 패턴은 여기에 더합니다.
    final destructivePatterns = [
      RegExp(r'\b(rm|rmdir|unlink|shred|mkfs(\.\w+)?)(\s|$)'),
      RegExp(r'\btruncate\s|\bdd\s.*\bof=|\bfind\s.*\s-delete\b'),
      RegExp(r'\bsudo\s|\bdiskutil\s+(erase|partition|apfs\s+delete)'),
      RegExp(r'\bgit\s+push\b.*(--force|\s-f\b|--delete|\s-d\b|\s\+\S)'),
      RegExp(r'\bgit\s+reset\s+--hard\b|\bgit\s+clean\s'),
      RegExp(r'\bgit\s+checkout\s+(--\s|\.(\s|$))|\bgit\s+restore\s'),
      RegExp(r'\bgit\s+(branch|tag)\s+(-d|--delete)\b'),
      RegExp(r'\bgit\s+stash\s+(drop|clear)\b|\bgit\s+worktree\s+remove\b'),
      RegExp(r'\bgit\s+filter-(branch|repo)\b'),
      RegExp(r'\bdrop\s+(table|database|schema)\b|\bdelete\s+from\s'),
      RegExp(r'\bkubectl\s+delete\b|\bterraform\s+destroy\b'),
      RegExp(r'\bdocker\s+(rm|rmi|system\s+prune|volume\s+rm)\b'),
      RegExp(r'\bgh\s+\w+\s+delete\b|\bnpm\s+unpublish\b'),
      RegExp(r'\bsend_message\b|\bsend_email\b|\bsendmail\b'),
      RegExp(r'clearbrowsercookies|clearbrowsercache'),
    ];
    return destructivePatterns.any((reg) => reg.hasMatch(joined));
  }

  static ApprovalCategory classifyTool(
    String toolName,
    Map<String, dynamic> args,
  ) {
    if (detectDestructive(toolName, args)) {
      return ApprovalCategory.destructive;
    }
    final cmd =
        (args['CommandLine'] ??
                args['command'] ??
                args['cmd'] ??
                jsonEncode(args))
            .toString();
    if (cmd.contains('ego-browser')) {
      return ApprovalCategory.skillSiteAccess;
    }
    if (cmd.contains('cli-hub') || cmd.contains('cli-anything')) {
      return ApprovalCategory.skillProgramExec;
    }
    final lower = toolName.toLowerCase();
    if (lower.contains('run_command') ||
        lower.contains('bash') ||
        lower.contains('command') ||
        lower.contains('exec')) {
      return ApprovalCategory.shellCommand;
    }
    if (lower.contains('edit') ||
        lower.contains('write') ||
        lower.contains('replace') ||
        lower.contains('patch') ||
        lower.contains('filechange')) {
      return ApprovalCategory.fileWrite;
    }
    if (lower.contains('web') ||
        lower.contains('fetch') ||
        lower.contains('http') ||
        lower.contains('browser')) {
      return ApprovalCategory.networkAccess;
    }
    return ApprovalCategory.externalSoftware;
  }

  static String extractTargetResource(
    String toolName,
    Map<String, dynamic> args,
  ) {
    final cmd =
        (args['CommandLine'] ?? args['command'] ?? args['cmd'] ?? '')
            .toString();
    if (cmd.contains('ego-browser')) {
      final urlMatch = RegExp(r'https?://[^\s"''`)]+').firstMatch(cmd);
      return urlMatch?.group(0) ?? 'ego-browser';
    }
    if (cmd.contains('cli-hub') || cmd.contains('cli-anything')) {
      final match = RegExp(
        r'(?:cli-hub\s+(?:install|info|search)\s+|cli-anything-)([a-zA-Z0-9_-]+)',
      ).firstMatch(cmd);
      return match?.group(1) ?? 'cli-hub';
    }
    if (cmd.isNotEmpty) {
      return cmd.split('\n').first.trim();
    }
    return (args['Path'] ??
            args['file_path'] ??
            args['path'] ??
            args['TargetFile'] ??
            toolName)
        .toString();
  }
}

class ApprovalDecision {
  const ApprovalDecision({
    required this.requestId,
    required this.approved,
    required this.scope,
    this.updatedInput,
    this.reason,
  });

  final String requestId;
  final bool approved;
  final ApprovalScope scope;
  final Map<String, dynamic>? updatedInput;
  final String? reason;
}

class QuestionOption {
  const QuestionOption({
    required this.label,
    this.description = '',
  });

  final String label;
  final String description;
}

class AgentQuestionItem {
  const AgentQuestionItem({
    required this.id,
    required this.question,
    this.header = '에이전트 확인 요청',
    this.options = const [],
    this.isMultiSelect = false,
    this.isSecret = false,
  });

  final String id;
  final String header;
  final String question;
  final List<QuestionOption> options;
  final bool isMultiSelect;
  final bool isSecret;
}

class QuestionRequestData {
  const QuestionRequestData({
    required this.id,
    required this.sessionId,
    required this.backend,
    required this.questions,
    required this.createdAt,
  });

  final String id;
  final String sessionId;
  final BackendType backend;
  final List<AgentQuestionItem> questions;
  final DateTime createdAt;
}

class FileDiffItem {
  const FileDiffItem({
    required this.filePath,
    this.oldContent = '',
    this.newContent = '',
    this.unifiedDiff = '',
  });

  factory FileDiffItem.fromJson(Map<String, dynamic> json) => FileDiffItem(
    filePath: (json['filePath'] ?? '') as String,
    oldContent: (json['oldContent'] ?? '') as String,
    newContent: (json['newContent'] ?? '') as String,
    unifiedDiff: (json['unifiedDiff'] ?? '') as String,
  );

  final String filePath;
  final String oldContent;
  final String newContent;
  final String unifiedDiff;

  Map<String, dynamic> toJson() => {
    'filePath': filePath,
    'oldContent': oldContent,
    'newContent': newContent,
    'unifiedDiff': unifiedDiff,
  };

  String computeUnifiedDiff() {
    if (unifiedDiff.isNotEmpty) return unifiedDiff;
    final oldLines = oldContent.isEmpty
        ? const <String>[]
        : oldContent.split('\n');
    final newLines = newContent.isEmpty
        ? const <String>[]
        : newContent.split('\n');
    final buffer = StringBuffer()
      ..writeln('--- a/$filePath')
      ..writeln('+++ b/$filePath');
    for (final line in oldLines) {
      buffer.writeln('- $line');
    }
    for (final line in newLines) {
      buffer.writeln('+ $line');
    }
    return buffer.toString().trimRight();
  }
}

class TokenUsage {
  const TokenUsage({
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.thinkingTokens = 0,
    this.cachedTokens = 0,
    this.promptTokens = 0,
    this.totalTokens = 0,
    this.costUsd = 0.0,
  });

  factory TokenUsage.fromJson(Map<String, dynamic> json) => TokenUsage(
    inputTokens: (json['inputTokens'] as num?)?.toInt() ?? 0,
    outputTokens: (json['outputTokens'] as num?)?.toInt() ?? 0,
    thinkingTokens: (json['thinkingTokens'] as num?)?.toInt() ?? 0,
    cachedTokens: (json['cachedTokens'] as num?)?.toInt() ?? 0,
    promptTokens: (json['promptTokens'] as num?)?.toInt() ?? 0,
    totalTokens: (json['totalTokens'] as num?)?.toInt() ?? 0,
    costUsd: (json['costUsd'] as num?)?.toDouble() ?? 0.0,
  );

  final int inputTokens;
  final int outputTokens;
  final int thinkingTokens;
  final int cachedTokens;

  /// 캐시 적중분을 포함한 전체 입력. 백엔드마다 inputTokens에 캐시를 넣는 방식이 달라 따로 둡니다.
  final int promptTokens;
  final int totalTokens;
  final double costUsd;

  double get cacheHitRate => promptTokens == 0 ? 0 : cachedTokens / promptTokens;

  Map<String, dynamic> toJson() => {
    'inputTokens': inputTokens,
    'outputTokens': outputTokens,
    'thinkingTokens': thinkingTokens,
    'cachedTokens': cachedTokens,
    'promptTokens': promptTokens,
    'totalTokens': totalTokens,
    'costUsd': costUsd,
  };

  TokenUsage operator +(TokenUsage other) {
    return TokenUsage(
      inputTokens: inputTokens + other.inputTokens,
      outputTokens: outputTokens + other.outputTokens,
      thinkingTokens: thinkingTokens + other.thinkingTokens,
      cachedTokens: cachedTokens + other.cachedTokens,
      promptTokens: promptTokens + other.promptTokens,
      totalTokens: totalTokens + other.totalTokens,
      costUsd: costUsd + other.costUsd,
    );
  }
}

sealed class AgentEvent {
  const AgentEvent({
    required this.id,
    required this.sessionId,
    required this.backend,
    required this.timestamp,
    this.model = '',
    this.rawLog = '',
  });

  final String id;
  final String sessionId;
  final BackendType backend;
  final String model;
  final DateTime timestamp;
  final String rawLog;

  String get eventKind;

  Map<String, dynamic> _baseJson() => {
    'kind': eventKind,
    'id': id,
    'sessionId': sessionId,
    'backend': backend.id,
    'model': model,
    'timestamp': timestamp.toIso8601String(),
    if (rawLog.isNotEmpty) 'rawLog': rawLog,
  };

  Map<String, dynamic> toJson();

  static AgentEvent? fromJson(Map<String, dynamic> json) {
    final kind = json['kind'] as String?;
    final id = (json['id'] ?? '') as String;
    final sessionId = (json['sessionId'] ?? '') as String;
    final backend = BackendType.fromId((json['backend'] ?? 'agy') as String);
    final model = (json['model'] ?? '') as String;
    final timestamp =
        DateTime.tryParse((json['timestamp'] ?? '') as String) ??
        DateTime.now();
    final rawLog = (json['rawLog'] ?? '') as String;

    return switch (kind) {
      'message' => MessageEvent(
        id: id,
        sessionId: sessionId,
        backend: backend,
        model: model,
        timestamp: timestamp,
        rawLog: rawLog,
        role: (json['role'] ?? 'assistant') as String,
        text: (json['text'] ?? '') as String,
        thinking: (json['thinking'] ?? '') as String,
        isDelta: (json['isDelta'] as bool?) ?? false,
      ),
      'tool_call' => ToolCallEvent(
        id: id,
        sessionId: sessionId,
        backend: backend,
        model: model,
        timestamp: timestamp,
        rawLog: rawLog,
        toolName: (json['toolName'] ?? '') as String,
        arguments: json['arguments'] is Map
            ? Map<String, dynamic>.from(json['arguments'] as Map)
            : const {},
        result: (json['result'] ?? '') as String,
        isRunning: (json['isRunning'] as bool?) ?? false,
        isError: (json['isError'] as bool?) ?? false,
        durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
      ),
      'file_diff' => FileDiffEvent(
        id: id,
        sessionId: sessionId,
        backend: backend,
        model: model,
        timestamp: timestamp,
        rawLog: rawLog,
        diff: json['diff'] is Map
            ? FileDiffItem.fromJson(
                Map<String, dynamic>.from(json['diff'] as Map),
              )
            : const FileDiffItem(filePath: ''),
      ),
      'skill_invoked' => SkillInvokedEvent(
        id: id,
        sessionId: sessionId,
        backend: backend,
        model: model,
        timestamp: timestamp,
        rawLog: rawLog,
        skillName: (json['skillName'] ?? '') as String,
        skillPath: (json['skillPath'] ?? '') as String,
        reason: (json['reason'] ?? '') as String,
      ),
      'child_worktree' => ChildWorktreeEvent(
        id: id,
        sessionId: sessionId,
        backend: backend,
        model: model,
        timestamp: timestamp,
        rawLog: rawLog,
        childSessionId: (json['childSessionId'] ?? '') as String,
        childTitle: (json['childTitle'] ?? '') as String,
        message: (json['message'] ?? '') as String,
        status:
            ChildWorktreeStatus.values.asNameMap()[json['status']] ??
            ChildWorktreeStatus.completed,
        summary: (json['summary'] ?? '') as String,
        needsAttention: (json['needsAttention'] as bool?) ?? false,
        canMerge: (json['canMerge'] as bool?) ?? false,
      ),
      'error' => ErrorEvent(
        id: id,
        sessionId: sessionId,
        backend: backend,
        model: model,
        timestamp: timestamp,
        rawLog: rawLog,
        message: (json['message'] ?? '') as String,
        code: (json['code'] ?? '') as String,
        isFatal: (json['isFatal'] as bool?) ?? false,
      ),
      'done' => DoneEvent(
        id: id,
        sessionId: sessionId,
        backend: backend,
        model: model,
        timestamp: timestamp,
        rawLog: rawLog,
        conversationId: (json['conversationId'] ?? '') as String,
        usage: json['usage'] is Map
            ? TokenUsage.fromJson(
                Map<String, dynamic>.from(json['usage'] as Map),
              )
            : const TokenUsage(),
        durationMs: (json['durationMs'] as num?)?.toInt() ?? 0,
        stopReason: (json['stopReason'] ?? 'completed') as String,
      ),
      _ => null,
    };
  }
}

class MessageEvent extends AgentEvent {
  const MessageEvent({
    required super.id,
    required super.sessionId,
    required super.backend,
    required super.timestamp,
    required this.role,
    required this.text,
    this.thinking = '',
    this.isDelta = false,
    super.model,
    super.rawLog,
  });

  final String role; // 'user' | 'assistant' | 'system'
  final String text;
  final String thinking;
  final bool isDelta;

  @override
  String get eventKind => 'message';

  @override
  Map<String, dynamic> toJson() => {
    ..._baseJson(),
    'role': role,
    'text': text,
    if (thinking.isNotEmpty) 'thinking': thinking,
    if (isDelta) 'isDelta': isDelta,
  };
}

class ToolCallEvent extends AgentEvent {
  const ToolCallEvent({
    required super.id,
    required super.sessionId,
    required super.backend,
    required super.timestamp,
    required this.toolName,
    this.arguments = const {},
    this.result = '',
    this.isRunning = false,
    this.isError = false,
    this.durationMs = 0,
    super.model,
    super.rawLog,
  });

  final String toolName;
  final Map<String, dynamic> arguments;
  final String result;
  final bool isRunning;
  final bool isError;
  final int durationMs;

  /// CLI처럼 `Bash(git status)` 형태로 한 줄 요약합니다.
  String get displayLine {
    final candidates = [
      for (final key in const ['command', 'file_path', 'path', 'pattern'])
        arguments[key],
      ...arguments.values,
    ];
    final value = candidates
        .whereType<String>()
        .where((v) => v.trim().isNotEmpty)
        .firstOrNull;
    if (value == null) return toolName;
    final line = value.trim().split('\n').first;
    return '$toolName(${line.length > 80 ? '${line.substring(0, 80)}…' : line})';
  }

  @override
  String get eventKind => 'tool_call';

  @override
  Map<String, dynamic> toJson() => {
    ..._baseJson(),
    'toolName': toolName,
    'arguments': arguments,
    'result': result,
    'isRunning': isRunning,
    'isError': isError,
    'durationMs': durationMs,
  };

  ToolCallEvent copyWith({
    Map<String, dynamic>? arguments,
    String? result,
    bool? isRunning,
    bool? isError,
    int? durationMs,
  }) {
    return ToolCallEvent(
      id: id,
      sessionId: sessionId,
      backend: backend,
      timestamp: timestamp,
      toolName: toolName,
      arguments: arguments ?? this.arguments,
      result: result ?? this.result,
      isRunning: isRunning ?? this.isRunning,
      isError: isError ?? this.isError,
      durationMs: durationMs ?? this.durationMs,
      model: model,
      rawLog: rawLog,
    );
  }
}

class ApprovalRequestEvent extends AgentEvent {
  ApprovalRequestEvent({
    required this.request,
    super.model,
    super.rawLog,
  }) : super(
         id: request.id,
         sessionId: request.sessionId,
         backend: request.backend,
         timestamp: request.createdAt,
       );

  final ApprovalRequestData request;

  @override
  String get eventKind => 'approval_request';

  @override
  Map<String, dynamic> toJson() => _baseJson();
}

class QuestionEvent extends AgentEvent {
  QuestionEvent({
    required this.request,
    super.model,
    super.rawLog,
  }) : super(
         id: request.id,
         sessionId: request.sessionId,
         backend: request.backend,
         timestamp: request.createdAt,
       );

  final QuestionRequestData request;

  @override
  String get eventKind => 'question';

  @override
  Map<String, dynamic> toJson() => _baseJson();
}

class FileDiffEvent extends AgentEvent {
  const FileDiffEvent({
    required super.id,
    required super.sessionId,
    required super.backend,
    required super.timestamp,
    required this.diff,
    super.model,
    super.rawLog,
  });

  final FileDiffItem diff;

  @override
  String get eventKind => 'file_diff';

  @override
  Map<String, dynamic> toJson() => {..._baseJson(), 'diff': diff.toJson()};
}

class SkillInvokedEvent extends AgentEvent {
  const SkillInvokedEvent({
    required super.id,
    required super.sessionId,
    required super.backend,
    required super.timestamp,
    required this.skillName,
    this.skillPath = '',
    this.reason = '',
    super.model,
    super.rawLog,
  });

  final String skillName;
  final String skillPath;
  final String reason;

  @override
  String get eventKind => 'skill_invoked';

  @override
  Map<String, dynamic> toJson() => {
    ..._baseJson(),
    'skillName': skillName,
    'skillPath': skillPath,
    'reason': reason,
  };
}

enum ChildWorktreeStatus {
  running('작업 중'),
  completed('작업 완료'),
  failed('작업 실패'),
  stopped('작업 중지');

  const ChildWorktreeStatus(this.label);
  final String label;
}

/// 하위 세션의 worktree 작업 상태를 상위 세션 타임라인에 알립니다.
class ChildWorktreeEvent extends AgentEvent {
  const ChildWorktreeEvent({
    required super.id,
    required super.sessionId,
    required super.backend,
    required super.timestamp,
    required this.childSessionId,
    required this.childTitle,
    required this.message,
    this.status = ChildWorktreeStatus.running,
    this.summary = '',
    this.needsAttention = false,
    this.canMerge = false,
    super.model,
    super.rawLog,
  });

  final String childSessionId;
  final String childTitle;
  final String message;
  final ChildWorktreeStatus status;
  final String summary;
  final bool needsAttention;
  final bool canMerge;

  @override
  String get eventKind => 'child_worktree';

  @override
  Map<String, dynamic> toJson() => {
    ..._baseJson(),
    'childSessionId': childSessionId,
    'childTitle': childTitle,
    'message': message,
    'status': status.name,
    'summary': summary,
    'needsAttention': needsAttention,
    'canMerge': canMerge,
  };
}

class ErrorEvent extends AgentEvent {
  const ErrorEvent({
    required super.id,
    required super.sessionId,
    required super.backend,
    required super.timestamp,
    required this.message,
    this.code = '',
    this.isFatal = false,
    super.model,
    super.rawLog,
  });

  final String message;
  final String code;
  final bool isFatal;

  @override
  String get eventKind => 'error';

  @override
  Map<String, dynamic> toJson() => {
    ..._baseJson(),
    'message': message,
    'code': code,
    'isFatal': isFatal,
  };
}

class DoneEvent extends AgentEvent {
  const DoneEvent({
    required super.id,
    required super.sessionId,
    required super.backend,
    required super.timestamp,
    this.conversationId = '',
    this.usage = const TokenUsage(),
    this.durationMs = 0,
    this.stopReason = 'completed',
    super.model,
    super.rawLog,
  });

  final String conversationId;
  final TokenUsage usage;
  final int durationMs;
  final String stopReason;

  static const interrupted = 'interrupted';

  @override
  String get eventKind => 'done';

  @override
  Map<String, dynamic> toJson() => {
    ..._baseJson(),
    'conversationId': conversationId,
    'usage': usage.toJson(),
    'durationMs': durationMs,
    'stopReason': stopReason,
  };
}
