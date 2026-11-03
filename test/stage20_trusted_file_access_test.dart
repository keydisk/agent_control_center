import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_control_center/adapters/antigravity/antigravity_adapter.dart';
import 'package:agent_control_center/adapters/antigravity/antigravity_event_parser.dart';
import 'package:agent_control_center/adapters/claude/claude_code_adapter.dart';
import 'package:agent_control_center/adapters/codex/codex_adapter.dart';
import 'package:agent_control_center/core/backend/agent_backend.dart';
import 'package:agent_control_center/core/backend/local_hook_bridge.dart';
import 'package:agent_control_center/core/models/agent_models.dart';
import 'package:agent_control_center/services/session_manager.dart';
import 'package:agent_control_center/services/trusted_folder_store.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeBackend implements AgentBackend {
  final eventCtrl = StreamController<AgentEvent>.broadcast(sync: true);
  final rawLogCtrl = StreamController<String>.broadcast();
  final decisions = <ApprovalDecision>[];
  AgentSessionConfig? lastConfig;

  @override
  BackendType get backendType => BackendType.claudeCode;
  @override
  Stream<AgentEvent> get events => eventCtrl.stream;
  @override
  Stream<String> get rawLogs => rawLogCtrl.stream;
  @override
  String? get remoteConversationId => null;
  @override
  Future<void> start(AgentSessionConfig config) async => lastConfig = config;
  @override
  Future<void> send(
    String prompt, {
    List<String> attachments = const [],
  }) async {}
  @override
  Future<void> respondToApproval(ApprovalDecision decision) async =>
      decisions.add(decision);
  @override
  Future<void> respondToQuestion(
    String requestId,
    Map<String, List<String>> answers,
  ) async {}
  @override
  Future<void> interrupt() async {}
  @override
  Future<void> resume(String conversationId, AgentSessionConfig config) async {}
  @override
  Future<void> dispose() async {}
}

class _Process implements ManagedProcess {
  final stdoutCtrl = StreamController<String>.broadcast(sync: true);
  final stderrCtrl = StreamController<String>.broadcast();
  final written = <String>[];
  @override
  Stream<String> get stdoutLines => stdoutCtrl.stream;
  @override
  Stream<String> get stderrLines => stderrCtrl.stream;
  @override
  Future<int> get exitCode async => 0;
  @override
  void writeLine(String line) => written.add(line);
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => true;
}

class _Spawner implements ProcessSpawner {
  final processes = <_Process>[];
  final arguments = <List<String>>[];
  @override
  Future<ManagedProcess> spawn(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    this.arguments.add(arguments);
    final process = _Process();
    processes.add(process);
    return process;
  }

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async => ProcessResult(0, 0, '', '');
}

ApprovalRequestEvent _request(
  String tool,
  Map<String, dynamic> args, {
  String id = 'r1',
  bool destructive = false,
}) => ApprovalRequestEvent(
  request: ApprovalRequestData(
    id: id,
    sessionId: 's',
    backend: BackendType.claudeCode,
    toolName: tool,
    arguments: args,
    category: ApprovalRequestData.classifyTool(tool, args),
    reason: '',
    isDestructive: destructive,
    createdAt: DateTime(2026),
  ),
);

void main() {
  late Directory temp;
  late Directory trusted;
  late Directory other;
  late TrustedFolderStore store;
  late SessionManager manager;
  late _FakeBackend backend;
  late List<ApprovalRequestData> asked;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('acc_stage20_');
    trusted = Directory('${temp.path}/project')..createSync();
    other = Directory('${temp.path}/other')..createSync();
    store = TrustedFolderStore()..add(trusted.path);
    asked = [];
    manager = SessionManager(
      trustedFolders: store,
      onApprovalRequired: (session, request) => asked.add(request),
    );
    backend = _FakeBackend();
    manager.createSession(
      sessionId: 's',
      backendType: BackendType.claudeCode,
      backendOverride: backend,
      workingDirectory: trusted.path,
    );
  });
  tearDown(() {
    manager.dispose();
    temp.deleteSync(recursive: true);
  });

  group('신뢰 폴더 자동 허용', () {
    test('신뢰 폴더 안의 읽기·쓰기는 묻지 않고 허용하고 기록을 남긴다', () {
      for (final (i, event) in [
        _request('Write', {'file_path': '${trusted.path}/new/a.dart'}),
        _request('Edit', {'file_path': 'relative.dart'}),
        _request('Read', {'file_path': '${trusted.path}/a.dart'}),
        _request('edit_file', {'Path': '${trusted.path}/a.dart'}),
      ].indexed) {
        backend.eventCtrl.add(event);
        expect(backend.decisions, hasLength(i + 1));
        expect(backend.decisions.last.approved, isTrue);
      }
      expect(asked, isEmpty);
      final session = manager.sessions.single;
      expect(session.status, SessionStatus.idle);
      expect(session.events, isEmpty, reason: '승인 카드를 쌓지 않는다');
      expect(manager.permissionCenter.auditLogs, hasLength(4));
    });

    test('폴더 밖 파일, 명령 실행, 파괴적 작업은 계속 묻는다', () {
      for (final event in [
        _request('Write', {'file_path': '${other.path}/a.dart'}),
        _request('Write', {'file_path': '${trusted.path}/../other/a.dart'}),
        _request('Bash', {'command': 'ls'}),
        _request('Write', {'file_path': '${trusted.path}/a'}, destructive: true),
        _request('Write', {}),
      ]) {
        backend.eventCtrl.add(event);
      }
      expect(asked, hasLength(5));
      expect(backend.decisions, isEmpty);
      expect(manager.sessions.single.status, SessionStatus.awaitingApproval);
    });

    test('심볼릭 링크로 폴더 밖을 가리키는 경로는 묻는다', () {
      Link('${trusted.path}/escape').createSync(other.path);
      backend.eventCtrl.add(
        _request('Write', {'file_path': '${trusted.path}/escape/new.dart'}),
      );
      expect(asked, hasLength(1));
    });

    test('worktree 안의 파일도 허용하고, 폴더 신뢰를 해제하면 묻는다', () {
      final session = manager.sessions.single;
      final worktree = Directory('${temp.path}/wt/checkout')
        ..createSync(recursive: true);
      session.isolatedWorktreePath = worktree.path;
      backend.eventCtrl.add(
        _request('Write', {'file_path': '${worktree.path}/a.dart'}),
      );
      expect(backend.decisions, hasLength(1));

      store.coveringFolders(trusted.path).forEach(store.remove);
      backend.eventCtrl.add(
        _request('Write', {'file_path': '${worktree.path}/b.dart'}),
      );
      expect(backend.decisions, hasLength(1));
      expect(asked, hasLength(1));
    });

    test('시작 설정에 worktree와 신뢰 폴더를 넘기고 신뢰가 없으면 비운다', () async {
      final worktree = Directory('${temp.path}/wt2')..createSync();
      manager.sessions.single.isolatedWorktreePath = worktree.path;
      await manager.sendPrompt('s', '요청');
      expect(backend.lastConfig!.trustedDirectories, [
        TrustedFolderStore.canonicalPath(worktree.path),
        TrustedFolderStore.canonicalPath(trusted.path),
      ]);

      final plain = SessionManager();
      addTearDown(plain.dispose);
      final own = _FakeBackend();
      plain.createSession(
        sessionId: 'p',
        backendOverride: own,
        workingDirectory: trusted.path,
      );
      await plain.sendPrompt('p', '요청');
      expect(own.lastConfig!.trustedDirectories, isEmpty);
    });
  });

  group('Antigravity 명령 자동 승인', () {
    late _FakeBackend agy;

    void createAgySession(String folder) {
      agy = _FakeBackend();
      manager.createSession(
        sessionId: 'agy',
        backendType: BackendType.antigravity,
        backendOverride: agy,
        workingDirectory: folder,
      );
    }

    test('신뢰 폴더의 일반 명령은 묻지 않고 파괴적 명령은 묻는다', () {
      createAgySession(trusted.path);
      agy.eventCtrl.add(_request('run_command', {'CommandLine': 'find lib'}));
      expect(agy.decisions.single.approved, isTrue);
      expect(asked, isEmpty);

      agy.eventCtrl.add(
        _request('run_command', {'CommandLine': 'rm -rf build'}, id: 'r2'),
      );
      expect(agy.decisions, hasLength(1));
      expect(asked, hasLength(1));
    });

    test('신뢰하지 않은 폴더의 명령은 묻는다', () {
      createAgySession(other.path);
      agy.eventCtrl.add(_request('run_command', {'CommandLine': 'find lib'}));
      expect(agy.decisions, isEmpty);
      expect(asked, hasLength(1));
    });
  });

  group('자동 권한 모드', () {
    test('백엔드별 자동 모드로 시작하고 건너뛰기 옵션은 쓰지 않는다', () async {
      final spawner = _Spawner();
      final claude = ClaudeCodeAdapter(spawner: spawner);
      final codex = CodexAdapter(spawner: spawner);
      final bridge = LocalHookBridgeServer();
      final agy = AntigravityAdapter(
        spawner: spawner,
        hookBridge: bridge,
        userSettingsFile: File('/nonexistent/settings.json'),
      );
      addTearDown(() async {
        await claude.dispose();
        await codex.dispose();
        await agy.dispose();
        await bridge.dispose();
      });
      AgentSessionConfig config(BackendType backend) => AgentSessionConfig(
        sessionId: 's',
        backendType: backend,
        workingDirectory: '/tmp',
      );
      await claude.start(config(BackendType.claudeCode));
      await agy.start(config(BackendType.antigravity));
      await codex.start(config(BackendType.codex));
      await codex.send('요청');

      final claudeArgs = spawner.arguments[0];
      expect(claudeArgs[claudeArgs.indexOf('--permission-mode') + 1], 'auto');
      final agyArgs = spawner.arguments[1];
      expect(agyArgs[agyArgs.indexOf('--mode') + 1], 'auto');
      final codexArgs = spawner.arguments[2];
      expect(codexArgs, contains('--approve-for-me'));
      expect(codexArgs, isNot(contains('-s')), reason: '함께 쓸 수 없는 옵션');
      for (final args in spawner.arguments) {
        expect(args.join(' '), isNot(contains('dangerously')));
      }
    });
  });

  group('canonicalPath', () {
    test('아직 없는 파일도 있는 상위 폴더의 실제 경로로 푼다', () {
      final real = trusted.resolveSymbolicLinksSync();
      expect(
        TrustedFolderStore.canonicalPath('${trusted.path}/a/b.dart'),
        '$real/a/b.dart',
      );
      expect(TrustedFolderStore.canonicalPath(trusted.path), real);
    });
  });

  group('Claude Code', () {
    test('권한 요청을 앱으로 받도록 stdio 옵션을 넘긴다', () async {
      final spawner = _Spawner();
      final adapter = ClaudeCodeAdapter(spawner: spawner);
      addTearDown(adapter.dispose);
      await adapter.start(
        const AgentSessionConfig(
          sessionId: 's',
          backendType: BackendType.claudeCode,
          workingDirectory: '/tmp',
          effort: ReasoningEffort.high,
        ),
      );
      final args = spawner.arguments.single;
      expect(args[args.indexOf('--permission-prompt-tool') + 1], 'stdio');

      await adapter.resume(
        'c1',
        const AgentSessionConfig(
          sessionId: 's',
          backendType: BackendType.claudeCode,
          workingDirectory: '/tmp',
          effort: ReasoningEffort.high,
        ),
      );
      final resumed = spawner.arguments.last;
      expect(resumed[resumed.indexOf('--effort') + 1], 'high', reason: '재개해도 유지');
    });
  });

  group('Codex', () {
    test('worktree 세션은 신뢰 폴더를 쓰기 가능 폴더로 추가한다', () async {
      final spawner = _Spawner();
      final adapter = CodexAdapter(spawner: spawner);
      addTearDown(adapter.dispose);
      await adapter.start(
        const AgentSessionConfig(
          sessionId: 's',
          backendType: BackendType.codex,
          workingDirectory: '/tmp/wt',
          trustedDirectories: ['/tmp/wt', '/tmp/project'],
        ),
      );
      await adapter.send('요청');
      final args = spawner.arguments.single;
      expect(args[args.indexOf('--add-dir') + 1], '/tmp/project');
      expect('--add-dir'.allMatches(args.join(' ')), hasLength(1));
    });
  });

  group('Antigravity', () {
    late _Spawner spawner;
    late LocalHookBridgeServer bridge;
    late File userSettings;

    setUp(() {
      spawner = _Spawner();
      bridge = LocalHookBridgeServer();
      userSettings = File('${temp.path}/settings.json');
      addTearDown(bridge.dispose);
    });

    AntigravityAdapter adapter() {
      final created = AntigravityAdapter(
        spawner: spawner,
        hookBridge: bridge,
        userSettingsFile: userSettings,
      );
      addTearDown(created.dispose);
      return created;
    }

    List<String> allowed(List<String> args) =>
        ((jsonDecode(args[args.indexOf('--settings') + 1]) as Map)['permissions']
                as Map)['allow']
            .cast<String>();

    const trustedConfig = AgentSessionConfig(
      sessionId: 's',
      backendType: BackendType.antigravity,
      workingDirectory: '/tmp/wt',
      trustedDirectories: ['/tmp/wt'],
    );

    test('신뢰 폴더 규칙을 넘기면서 사용자의 기존 규칙을 유지한다', () async {
      userSettings.writeAsStringSync(
        jsonEncode({
          'permissions': {
            'allow': ['command(ls)'],
          },
        }),
      );
      await adapter().start(trustedConfig);
      expect(
        allowed(spawner.arguments.single),
        containsAll([
          'command(ls)',
          'read_file(/tmp/wt)',
          'write_file(/tmp/wt)',
        ]),
      );
    });

    test('신뢰 폴더가 없으면 --settings를 넘기지 않는다', () async {
      await adapter().start(
        const AgentSessionConfig(
          sessionId: 's',
          backendType: BackendType.antigravity,
          workingDirectory: '/tmp',
        ),
      );
      expect(spawner.arguments.single, isNot(contains('--settings')));
    });

    test('거부된 파일 쓰기를 물어보고 승인하면 그 규칙으로 잇는다', () async {
      const path = '/outside/lib/a.dart';
      final denied = jsonEncode({
        'event': 'step_update',
        'step_update': {
          'conversation_id': 'c1',
          'step_index': 5,
          'state': 'ERROR',
          'step_type': 'tool',
          'tool_name': 'edit_file',
          'tool_info': {
            'name': 'edit_file',
            'parameters': {'Path': path},
            'error': {
              'type': 'TOOL_ERROR',
              'message':
                  'permission check failed for write_file "$path": user denied '
                  'permission for write_file($path)\nDo not attempt to circumvent '
                  'this denial.',
            },
          },
        },
      });
      final parser = AntigravityEventParser(sessionId: 's', model: 'm');
      final parsed = parser.parseLine(denied);
      expect(parser.deniedRules['agy_denied_5'], 'write_file($path)');
      expect(parsed.whereType<ApprovalRequestEvent>(), hasLength(1));

      final subject = adapter();
      final events = <AgentEvent>[];
      subject.events.listen(events.add);
      await subject.start(trustedConfig);
      spawner.processes.first.stdoutCtrl
        ..add(denied)
        ..add(
          jsonEncode({
            'event': 'result',
            'result': {
              'conversation_id': 'c1',
              'status': 'SUCCESS',
              'response': '',
              'denied_actions': [
                {'action': 'file_write', 'display_name': 'EditFile'},
              ],
            },
          }),
        );
      await Future<void>.delayed(Duration.zero);
      expect(events.whereType<ApprovalRequestEvent>(), hasLength(1));
      expect(events.whereType<DoneEvent>(), isEmpty);
      expect(
        events.whereType<MessageEvent>().where((m) => m.role == 'system'),
        isEmpty,
      );

      await subject.respondToApproval(
        const ApprovalDecision(
          requestId: 'agy_denied_5',
          approved: true,
          scope: ApprovalScope.once,
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(spawner.processes, hasLength(2));
      expect(allowed(spawner.arguments.last), contains('write_file($path)'));
      expect(spawner.processes.last.written.single, contains('write_file($path)'));
    });
  });
}
