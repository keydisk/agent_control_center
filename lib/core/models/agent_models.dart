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
    defaultModel: 'gemini-3.8-flash-high',
    availableModels: [
      'gemini-3.8-flash-high',
      'gemini-3.8-flash-medium',
      'gemini-3.8-flash-low',
      'gemini-4-argon-medium',
      'gemini-4-argon-high',
    ],
    slashCommands: [
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
  });

  final String id;
  final String displayName;
  final String executable;
  final String defaultModel;
  final List<String> availableModels;
  final List<String> slashCommands;
  final String installCommand;
  final String installGuide;

  static BackendType fromId(String id) {
    return BackendType.values.firstWhere(
      (b) => b.id == id || b.name == id,
      orElse: () => BackendType.antigravity,
    );
  }
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
    final joined = jsonEncode(args).toLowerCase();
    final destructivePatterns = [
      RegExp(r'\brm\s+(-[rRf]+\s+|/)'),
      RegExp(r'\bgit\s+push\s+.*(--force|-f)\b'),
      RegExp(r'\bgit\s+reset\s+--hard\b'),
      RegExp(r'\bdrop\s+(table|database)\b'),
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

  final String filePath;
  final String oldContent;
  final String newContent;
  final String unifiedDiff;

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
    this.totalTokens = 0,
    this.costUsd = 0.0,
  });

  final int inputTokens;
  final int outputTokens;
  final int thinkingTokens;
  final int cachedTokens;
  final int totalTokens;
  final double costUsd;

  TokenUsage operator +(TokenUsage other) {
    return TokenUsage(
      inputTokens: inputTokens + other.inputTokens,
      outputTokens: outputTokens + other.outputTokens,
      thinkingTokens: thinkingTokens + other.thinkingTokens,
      cachedTokens: cachedTokens + other.cachedTokens,
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

  @override
  String get eventKind => 'tool_call';

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

  @override
  String get eventKind => 'done';
}
