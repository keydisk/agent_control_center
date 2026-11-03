import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/agent_models.dart';

class AgentSessionConfig {
  const AgentSessionConfig({
    required this.sessionId,
    required this.backendType,
    required this.workingDirectory,
    this.model = '',
    this.effort = ReasoningEffort.auto,
    this.conversationId,
    this.extraArgs = const [],
    this.environment = const {},
    this.systemPromptAppend = '',
    this.autoApproveBypassEnabled = false,
    this.trustedDirectories = const [],
    this.permissionMode = PermissionMode.manual,
  });

  final String sessionId;
  final BackendType backendType;
  final String workingDirectory;
  final String model;
  final ReasoningEffort effort;
  final String? conversationId;
  final List<String> extraArgs;
  final Map<String, String> environment;
  final String systemPromptAppend;
  final bool autoApproveBypassEnabled;

  /// 승인 없이 읽고 쓸 수 있는 폴더 (신뢰 폴더와 그 세션의 worktree)
  final List<String> trustedDirectories;
  final PermissionMode permissionMode;

  bool get skipsPermissions =>
      autoApproveBypassEnabled || permissionMode == PermissionMode.bypass;

  String get effectiveModel =>
      model.isNotEmpty ? model : backendType.defaultModel;
}

class BackendInstallationStatus {
  const BackendInstallationStatus({
    required this.backend,
    required this.isInstalled,
    this.executablePath = '',
    this.version = '',
  });

  final BackendType backend;
  final bool isInstalled;
  final String executablePath;
  final String version;
}

abstract class ManagedProcess {
  Stream<String> get stdoutLines;
  Stream<String> get stderrLines;
  Future<int> get exitCode;
  void writeLine(String line);
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]);
}

class IoManagedProcess implements ManagedProcess {
  IoManagedProcess(this._process)
    : stdoutLines = _process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .asBroadcastStream(),
      stderrLines = _process.stderr
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .asBroadcastStream();

  final Process _process;

  @override
  final Stream<String> stdoutLines;

  @override
  final Stream<String> stderrLines;

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  void writeLine(String line) {
    _process.stdin.writeln(line);
  }

  /// 입력이 끝났음을 알립니다. 프롬프트를 인자로 받는 CLI는 이것을 기다립니다.
  Future<void> closeStdin() => _process.stdin.close();

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    return _process.kill(signal);
  }
}

abstract class ProcessSpawner {
  Future<ManagedProcess> spawn(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  });

  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  });
}

class IoProcessSpawner implements ProcessSpawner {
  const IoProcessSpawner();

  static Map<String, String> buildMergedEnvironment(
    Map<String, String>? custom,
  ) {
    final env = Map<String, String>.from(Platform.environment);
    final home = env['HOME'] ?? '';
    final extraPaths = <String>[
      if (home.isNotEmpty) '$home/.local/bin',
      '/opt/homebrew/bin',
      '/usr/local/bin',
      '/usr/bin',
      '/bin',
    ];
    final currentPath = env['PATH'] ?? '';
    final mergedPath = [
      ...extraPaths,
      if (currentPath.isNotEmpty) currentPath,
    ].join(':');
    env['PATH'] = mergedPath;
    if (custom != null) {
      env.addAll(custom);
    }
    return env;
  }

  @override
  Future<ManagedProcess> spawn(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: buildMergedEnvironment(environment),
    );
    return IoManagedProcess(process);
  }

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) {
    return Process.run(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: buildMergedEnvironment(environment),
    );
  }
}

abstract class AgentBackend {
  BackendType get backendType;
  Stream<AgentEvent> get events;
  Stream<String> get rawLogs;
  String? get remoteConversationId;

  Future<void> start(AgentSessionConfig config);
  Future<void> send(String prompt, {List<String> attachments = const []});
  Future<void> respondToApproval(ApprovalDecision decision);
  Future<void> respondToQuestion(
    String requestId,
    Map<String, List<String>> answers,
  );
  Future<void> interrupt();
  Future<void> resume(String conversationId, AgentSessionConfig config);
  Future<void> dispose();

  static Future<BackendInstallationStatus> checkInstallation(
    BackendType backend, {
    ProcessSpawner spawner = const IoProcessSpawner(),
  }) async {
    try {
      final whichRes = await spawner.run('which', [backend.executable]);
      if (whichRes.exitCode != 0) {
        return BackendInstallationStatus(
          backend: backend,
          isInstalled: false,
        );
      }
      final execPath = whichRes.stdout.toString().trim().split('\n').first;
      final verRes = await spawner.run(execPath, ['--version']);
      final version = verRes.stdout.toString().trim().split('\n').first;
      return BackendInstallationStatus(
        backend: backend,
        isInstalled: true,
        executablePath: execPath,
        version: version,
      );
    } catch (_) {
      return BackendInstallationStatus(
        backend: backend,
        isInstalled: false,
      );
    }
  }
}
