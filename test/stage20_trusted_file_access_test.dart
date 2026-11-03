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
      defaultPermissionMode: PermissionMode.auto,
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

  group('파괴적 작업만 묻기', () {
    test('파괴적이지 않은 요청은 폴더와 도구에 관계없이 묻지 않고 기록을 남긴다', () {
      final requests = [
        _request('Write', {'file_path': '${trusted.path}/new/a.dart'}),
        _request('Write', {'file_path': '${other.path}/a.dart'}),
        _request('Read', {'file_path': '/etc/hosts'}),
        _request('Bash', {'command': 'flutter test'}),
        _request('run_command', {'CommandLine': 'git commit -m x'}),
        _request('WebFetch', {'url': 'https://example.com'}),
      ];
      for (final (i, event) in requests.indexed) {
        backend.eventCtrl.add(event);
        expect(backend.decisions, hasLength(i + 1));
        expect(backend.decisions.last.approved, isTrue);
      }
      expect(asked, isEmpty);
      final session = manager.sessions.single;
      expect(session.status, SessionStatus.idle);
      expect(session.events, isEmpty, reason: '승인 카드를 쌓지 않는다');
      expect(manager.permissionCenter.auditLogs, hasLength(requests.length));
    });

    test('파괴적 작업은 묻고 답할 때까지 승인하지 않는다', () {
      backend.eventCtrl.add(_request('Bash', {'command': 'rm -rf build'}));
      expect(backend.decisions, isEmpty);
      expect(asked, hasLength(1));
      expect(manager.sessions.single.status, SessionStatus.awaitingApproval);
    });

    test('수동 모드는 파괴적이지 않아도 묻는다', () {
      final plain = SessionManager(
        onApprovalRequired: (session, request) => asked.add(request),
      );
      addTearDown(plain.dispose);
      final own = _FakeBackend();
      plain.createSession(backendOverride: own, workingDirectory: trusted.path);
      own.eventCtrl.add(_request('Bash', {'command': 'ls'}));
      expect(own.decisions, isEmpty);
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

  group('파괴적 작업 판별', () {
    bool isDestructive(String command) =>
        ApprovalRequestData.detectDestructive('Bash', {'command': command});

    test('삭제·덮어쓰기·강제 푸시 명령을 잡는다', () {
      for (final command in [
        'rm a.txt',
        'rm -rf build',
        'cd x && rm b',
        'xargs rm',
        'rmdir old',
        'find . -name x -delete',
        'git rm a',
        'git clean -fd',
        'git reset --hard HEAD~1',
        'git checkout -- lib/a.dart',
        'git checkout .',
        'git restore lib/a.dart',
        'git branch -D feature',
        'git tag -d v1',
        'git stash drop',
        'git worktree remove x',
        'git push --force origin main',
        'git push -f origin main',
        'git push origin --delete feature',
        'git push origin +main',
        'sudo reboot',
        'dd if=/dev/zero of=/dev/disk1',
        'truncate -s 0 a.log',
        'psql -c "DROP TABLE users"',
        'DELETE FROM users',
        'kubectl delete pod x',
        'terraform destroy',
        'docker system prune',
        'gh repo delete x',
      ]) {
        expect(isDestructive(command), isTrue, reason: command);
      }
    });

    test('일반 개발 명령은 파괴적으로 보지 않는다', () {
      for (final command in [
        'ls -la',
        'find lib -name "*.dart"',
        'flutter test',
        'firmware --version',
        'git status',
        'git add .',
        'git commit -m "문서 정리"',
        'git push origin main',
        'git push origin feature-force',
        'git checkout develop',
        'git checkout -b feature',
        'git branch feature',
        'git worktree add x',
        'npm install',
        'grep -r delete lib',
      ]) {
        expect(isDestructive(command), isFalse, reason: command);
      }
    });

    test('파일 내용은 판별하지 않고 도구 이름은 판별한다', () {
      expect(
        ApprovalRequestData.detectDestructive('Write', {
          'file_path': 'clean.sh',
          'content': 'rm -rf build',
        }),
        isFalse,
      );
      expect(
        ApprovalRequestData.detectDestructive('delete_file', {'Path': 'a'}),
        isTrue,
      );
    });
  });

  group('권한 모드', () {
    late _Spawner spawner;
    late ClaudeCodeAdapter claude;
    late CodexAdapter codex;
    late AntigravityAdapter agy;
    late LocalHookBridgeServer bridge;

    setUp(() {
      spawner = _Spawner();
      claude = ClaudeCodeAdapter(spawner: spawner);
      codex = CodexAdapter(spawner: spawner);
      bridge = LocalHookBridgeServer();
      agy = AntigravityAdapter(
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
    });

    Future<List<List<String>>> argsFor(PermissionMode mode) async {
      spawner.arguments.clear();
      AgentSessionConfig config(BackendType backend) => AgentSessionConfig(
        sessionId: 's',
        backendType: backend,
        workingDirectory: '/tmp',
        permissionMode: mode,
      );
      await claude.start(config(BackendType.claudeCode));
      await agy.start(config(BackendType.antigravity));
      await codex.start(config(BackendType.codex));
      await codex.send('요청');
      return List.of(spawner.arguments);
    }

    String after(List<String> args, String flag) =>
        args[args.indexOf(flag) + 1];

    test('모드별로 각 CLI의 옵션을 고른다', () async {
      var [c, a, x] = await argsFor(PermissionMode.auto);
      expect(after(c, '--permission-mode'), 'manual', reason: '앱이 판별한다');
      expect(after(a, '--mode'), 'auto');
      expect(x, contains('--approve-for-me'));
      expect(x, isNot(contains('-s')), reason: '함께 쓸 수 없다');

      [c, a, x] = await argsFor(PermissionMode.manual);
      expect(after(c, '--permission-mode'), 'manual');
      expect(a, isNot(contains('--mode')));
      expect(after(x, '-s'), 'read-only');

      [c, a, x] = await argsFor(PermissionMode.acceptEdits);
      expect(after(c, '--permission-mode'), 'acceptEdits');
      expect(after(a, '--mode'), 'accept-edits');
      expect(after(x, '-s'), 'workspace-write');

      [c, a, x] = await argsFor(PermissionMode.plan);
      expect(after(c, '--permission-mode'), 'plan');
      expect(after(a, '--mode'), 'plan');
      expect(after(x, '-s'), 'read-only');
    });

    test('건너뛰기 옵션은 권한 무시 모드에서만 쓴다', () async {
      for (final mode in PermissionMode.values) {
        final all = await argsFor(mode);
        for (final args in all) {
          expect(
            args.join(' ').contains('dangerously'),
            mode == PermissionMode.bypass,
            reason: '$mode',
          );
        }
      }
    });

    SessionManager managerWith(PermissionMode mode) {
      final created = SessionManager(
        trustedFolders: store,
        defaultPermissionMode: mode,
        onApprovalRequired: (session, request) => asked.add(request),
      );
      addTearDown(created.dispose);
      return created;
    }

    void send(_FakeBackend own, ApprovalRequestEvent event) =>
        own.eventCtrl.add(event);

    test('모드별로 자동 승인 범위가 다르다', () {
      final edit = _request('Write', {'file_path': '${trusted.path}/a'});
      final read = _request('Read', {'file_path': '/etc/hosts'}, id: 'r2');
      final command = _request('Bash', {'command': 'ls'}, id: 'r3');
      final destructive = _request('Bash', {'command': 'rm a'}, id: 'r4');
      final expected = {
        PermissionMode.auto: 3,
        PermissionMode.manual: 0,
        PermissionMode.acceptEdits: 2,
        PermissionMode.plan: 0,
        PermissionMode.bypass: 4,
      };
      for (final MapEntry(key: mode, value: count) in expected.entries) {
        final own = _FakeBackend();
        managerWith(mode).createSession(
          backendOverride: own,
          workingDirectory: trusted.path,
        );
        for (final event in [edit, read, command, destructive]) {
          send(own, event);
        }
        expect(own.decisions, hasLength(count), reason: '$mode');
        expect(own.decisions.every((d) => d.approved), isTrue);
      }
    });

    test('하위 세션은 상위 세션의 모드를 이어받고 바꾸면 다음 프롬프트에 적용한다', () async {
      final subject = managerWith(PermissionMode.auto);
      final own = _FakeBackend();
      final session = subject.createSession(
        sessionId: 'p',
        backendOverride: own,
        workingDirectory: trusted.path,
      );
      await subject.sendPrompt('p', '요청');
      expect(own.lastConfig!.permissionMode, PermissionMode.auto);
      expect(own.lastConfig!.trustedDirectories, isNotEmpty);

      subject.updateSessionPermissionMode('p', PermissionMode.manual);
      expect(session.isStarted, isFalse);
      await subject.sendPrompt('p', '요청');
      expect(own.lastConfig!.permissionMode, PermissionMode.manual);
      expect(own.lastConfig!.trustedDirectories, isEmpty, reason: '수동은 항상 확인');
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
