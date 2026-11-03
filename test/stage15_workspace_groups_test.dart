import 'dart:async';
import 'dart:io';

import 'package:agent_control_center/core/backend/agent_backend.dart';
import 'package:agent_control_center/core/backend/backend_registry.dart';
import 'package:agent_control_center/core/models/agent_models.dart';
import 'package:agent_control_center/main.dart';
import 'package:agent_control_center/services/inbox_service.dart';
import 'package:agent_control_center/services/notification_service.dart';
import 'package:agent_control_center/services/permission_center.dart';
import 'package:agent_control_center/services/session_context.dart';
import 'package:agent_control_center/services/session_manager.dart';
import 'package:agent_control_center/services/skill_registry.dart';
import 'package:agent_control_center/services/trusted_folder_store.dart';
import 'package:agent_control_center/services/workspace_group_store.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeBackend implements AgentBackend {
  _FakeBackend({this.compressionReply});

  /// 값이 있으면 send 때 이 답변을 내고 턴을 끝내는 압축용 백엔드로 동작합니다.
  final String? compressionReply;
  final eventCtrl = StreamController<AgentEvent>.broadcast(sync: true);
  final rawLogCtrl = StreamController<String>.broadcast();
  AgentSessionConfig? lastConfig;
  final prompts = <String>[];
  int startCount = 0;
  bool disposed = false;

  @override
  BackendType get backendType => BackendType.claudeCode;
  @override
  Stream<AgentEvent> get events => eventCtrl.stream;
  @override
  Stream<String> get rawLogs => rawLogCtrl.stream;
  @override
  String? get remoteConversationId => null;
  @override
  Future<void> start(AgentSessionConfig config) async {
    lastConfig = config;
    startCount++;
  }

  @override
  Future<void> send(
    String prompt, {
    List<String> attachments = const [],
  }) async {
    prompts.add(prompt);
    final reply = compressionReply;
    if (reply == null) return;
    eventCtrl
      ..add(_assistant(reply))
      ..add(_done());
  }

  void finishTurn(String text) {
    eventCtrl
      ..add(_assistant(text))
      ..add(_done());
  }

  @override
  Future<void> respondToApproval(ApprovalDecision decision) async {}
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
  Future<void> dispose() async {
    disposed = true;
  }
}

MessageEvent _assistant(String text) => MessageEvent(
  id: 'a_${DateTime.now().microsecondsSinceEpoch}',
  sessionId: 'x',
  backend: BackendType.claudeCode,
  timestamp: DateTime.now(),
  role: 'assistant',
  text: text,
);

MessageEvent _user(String text) => MessageEvent(
  id: 'u_${DateTime.now().microsecondsSinceEpoch}',
  sessionId: 'x',
  backend: BackendType.claudeCode,
  timestamp: DateTime.now(),
  role: 'user',
  text: text,
);

DoneEvent _done() => DoneEvent(
  id: 'd_${DateTime.now().microsecondsSinceEpoch}',
  sessionId: 'x',
  backend: BackendType.claudeCode,
  timestamp: DateTime.now(),
);

WorkspaceGroup _group({
  String id = 'g1',
  String folder = '/tmp',
  bool useDefault = true,
  String instructions = '',
}) => WorkspaceGroup(
  id: id,
  name: '그룹 $id',
  folder: folder,
  backend: BackendType.codex,
  model: BackendType.codex.defaultModel,
  effort: BackendType.codex.defaultEffort,
  useDefaultInstructions: useDefault,
  instructions: instructions,
);

/// 세션이 만드는 백엔드를 순서대로 돌려주는 레지스트리
BackendRegistry _registry(List<_FakeBackend> created, {String? reply}) {
  final registry = BackendRegistry();
  for (final type in BackendType.values) {
    registry.register(type, ({spawner, hookBridge}) {
      final backend = _FakeBackend(compressionReply: reply);
      created.add(backend);
      return backend;
    });
  }
  return registry;
}

Future<String> _git(String dir, List<String> args) async {
  final result = await Process.run('git', args, workingDirectory: dir);
  expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
  return result.stdout.toString().trim();
}

Future<Directory> _createRepo() async {
  final repo = await Directory.systemTemp.createTemp('acc_stage15_');
  addTearDown(() => repo.delete(recursive: true));
  await _git(repo.path, ['init', '-b', 'develop']);
  await _git(repo.path, ['config', 'user.name', 'Test']);
  await _git(repo.path, ['config', 'user.email', 'test@example.com']);
  await File('${repo.path}/source.txt').writeAsString('fixture\n');
  await _git(repo.path, ['add', '.']);
  await _git(repo.path, ['commit', '-m', '초기화']);
  return repo;
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 300));

void main() {
  group('WorkspaceGroupStore', () {
    late Directory temp;
    setUp(() => temp = Directory.systemTemp.createTempSync('acc_groups_'));
    tearDown(() => temp.deleteSync(recursive: true));

    test('기본 지침 선택 여부에 따라 지침을 합치고 파일에서 복원한다', () {
      final file = File('${temp.path}/sub/groups.json');
      final store = WorkspaceGroupStore(file: file)
        ..upsert(
          _group(instructions: '추가 지침'),
          defaultInstructions: '기본 지침',
        )
        ..upsert(_group(id: 'g2', useDefault: false, instructions: '단독'));
      expect(store.instructionsFor('g1'), '기본 지침\n\n추가 지침');
      expect(store.instructionsFor('g2'), '단독');
      expect(store.instructionsFor(null), isEmpty);

      final snapshot = SessionSnapshot(
        id: 's@1',
        title: '이전 작업',
        backend: BackendType.codex,
        lastTurn: '사용자: 요청',
        updatedAt: DateTime(2026),
      );
      store.recordSnapshot('g1', snapshot);

      final loaded = WorkspaceGroupStore(file: file);
      expect(loaded.groups, hasLength(2));
      expect(loaded.instructionsFor('g1'), '기본 지침\n\n추가 지침');
      expect(loaded.groupById('g1')!.backend, BackendType.codex);
      expect(loaded.snapshotsFor('g1').single.lastTurn, '사용자: 요청');
    });

    test('스냅샷은 같은 세션을 갱신하고 그룹당 10개까지 최근 순으로 남긴다', () {
      final store = WorkspaceGroupStore()..upsert(_group());
      SessionSnapshot snap(String id, String text) => SessionSnapshot(
        id: id,
        title: id,
        backend: BackendType.codex,
        lastTurn: text,
        updatedAt: DateTime(2026),
      );
      for (var i = 0; i < 12; i++) {
        store.recordSnapshot('g1', snap('s$i', '$i'));
      }
      store.recordSnapshot('g1', snap('s5', '새 값'));
      final list = store.snapshotsFor('g1');
      expect(list, hasLength(10));
      expect(list.first.lastTurn, '새 값');
      expect(list.where((s) => s.id == 's5'), hasLength(1));
      store.removeSnapshot('s5');
      expect(store.snapshotsFor('g1').any((s) => s.id == 's5'), isFalse);
      store.recordSnapshot('none', snap('x', 'x'));
      expect(store.snapshotsFor('none'), isEmpty);
    });

    test('손상된 파일은 그룹 없음으로 읽는다', () {
      final file = File('${temp.path}/groups.json')
        ..writeAsStringSync('{"defaultInstructions":"x","groups":[{"id":1}]}');
      final store = WorkspaceGroupStore(file: file);
      expect(store.groups, isEmpty);
      expect(store.defaultInstructions, isEmpty);
    });
  });

  group('세션 기록 압축', () {
    test('마지막 턴만 가져오고 긴 기록은 앞뒤를 남기고 줄인다', () {
      final events = <AgentEvent>[
        _user('첫 요청'),
        _assistant('첫 답변'),
        _done(),
        _user('둘째 요청'),
        _assistant('둘째 답변'),
        _done(),
      ];
      final last = buildSessionTranscript(events, lastTurnOnly: true);
      expect(last, contains('둘째 요청'));
      expect(last, contains('둘째 답변'));
      expect(last, isNot(contains('첫 요청')));
      expect(buildSessionTranscript(events), contains('첫 요청'));

      final long = buildSessionTranscript([
        _user('시작${'가' * 500}'),
        _assistant('${'나' * 500}끝'),
      ], maxChars: 100);
      expect(long, startsWith('사용자: 시작'));
      expect(long, endsWith('끝'));
      expect(long, contains('중략'));
      expect(long.length, lessThan(120));
    });

    test('일회용 백엔드는 답변을 돌려주고 승인 요청이나 오류면 null이다', () async {
      const config = AgentSessionConfig(
        sessionId: 'h',
        backendType: BackendType.codex,
        workingDirectory: '/tmp',
      );
      final ok = _FakeBackend(compressionReply: '요약');
      expect(await runHelperPrompt(ok, config, '압축'), '요약');
      expect(ok.disposed, isTrue);

      final silent = _FakeBackend();
      expect(
        await runHelperPrompt(
          silent,
          config,
          '압축',
          timeout: const Duration(milliseconds: 10),
        ),
        isNull,
      );
      expect(silent.disposed, isTrue);
    });

    test('스킬을 3개 백엔드에 연결하고 기존 항목은 덮어쓰지 않는다', () async {
      final temp = await Directory.systemTemp.createTemp('acc_handoff_');
      addTearDown(() => temp.delete(recursive: true));
      final dirs = {
        for (final b in BackendType.values) b: '${temp.path}/${b.id}/skills',
      };
      final existing = File(
        '${dirs[BackendType.codex]}/$handoffSkillName/SKILL.md',
      )..createSync(recursive: true);
      existing.writeAsStringSync('사용자 스킬');

      final registry = SkillRegistry(backendSkillDirs: dirs, loadDefaults: false);
      await registry.installHandoffSkill('${temp.path}/app');

      final skill = registry.getSkill(handoffSkillName)!;
      expect(skill.description, contains('인계 문서'));
      for (final backend in [BackendType.claudeCode, BackendType.antigravity]) {
        expect(
          File('${dirs[backend]}/$handoffSkillName/SKILL.md').readAsStringSync(),
          handoffSkillMarkdown,
        );
      }
      expect(existing.readAsStringSync(), '사용자 스킬');
    });
  });

  group('그룹과 지침', () {
    test('그룹·세션 지침과 이어받은 컨텍스트를 시작 설정으로 전달한다', () async {
      final store = WorkspaceGroupStore()
        ..upsert(_group(instructions: '그룹 지침'), defaultInstructions: '기본 지침');
      final manager = SessionManager(groups: store);
      addTearDown(manager.dispose);
      final backend = _FakeBackend();
      final session = manager.createSession(
        backendOverride: backend,
        workingDirectory: '/tmp',
        groupId: 'g1',
        instructions: '세션 지침',
      );
      manager.continueFromSnapshot(
        session.sessionId,
        SessionSnapshot(
          id: 'old',
          title: '이전 작업',
          backend: BackendType.codex,
          lastTurn: '사용자: 로그인 구현',
          updatedAt: DateTime(2026),
        ),
      );

      await manager.sendPrompt(session.sessionId, '이어서');

      final append = backend.lastConfig!.systemPromptAppend;
      for (final text in ['기본 지침', '그룹 지침', '세션 지침', '로그인 구현']) {
        expect(append, contains(text));
      }
      expect(append.indexOf('기본 지침'), lessThan(append.indexOf('세션 지침')));
      expect(
        session.events.whereType<MessageEvent>().first.role,
        'system',
      );
    });

    test('지침을 바꾸면 다음 프롬프트에서 다시 시작하고 그룹을 지우면 세션은 남는다', () async {
      final store = WorkspaceGroupStore()..upsert(_group());
      final manager = SessionManager(groups: store);
      addTearDown(manager.dispose);
      final backend = _FakeBackend();
      final session = manager.createSession(
        backendOverride: backend,
        workingDirectory: '/tmp',
        groupId: 'g1',
      );
      await manager.sendPrompt(session.sessionId, '요청');
      await manager.sendPrompt(session.sessionId, '다음');
      expect(backend.startCount, 1);

      manager.saveGroup(_group(instructions: '바뀐 지침'));
      await manager.sendPrompt(session.sessionId, '요청');
      expect(backend.startCount, 2);
      expect(backend.lastConfig!.systemPromptAppend, contains('바뀐 지침'));

      manager.updateSessionInstructions(session.sessionId, '세션 지침');
      await manager.sendPrompt(session.sessionId, '요청');
      expect(backend.startCount, 3);

      manager.deleteGroup('g1');
      expect(store.groups, isEmpty);
      expect(manager.sessions.single.groupId, isNull);
    });

    test('턴이 끝나면 그룹에 마지막 작업을 남기고 세션을 삭제하면 지운다', () async {
      final store = WorkspaceGroupStore()..upsert(_group());
      final manager = SessionManager(groups: store);
      addTearDown(manager.dispose);
      final backend = _FakeBackend();
      final session = manager.createSession(
        backendOverride: backend,
        workingDirectory: '/tmp',
        groupId: 'g1',
      );
      backend.eventCtrl.add(_user('이전 요청'));
      backend.finishTurn('이전 답변');
      backend.eventCtrl.add(_user('마지막 요청'));
      backend.finishTurn('마지막 답변');
      await _settle();

      final snapshot = store.snapshotsFor('g1').single;
      expect(snapshot.lastTurn, contains('마지막 답변'));
      expect(snapshot.lastTurn, isNot(contains('이전 요청')));

      await manager.deleteSession(session.sessionId);
      expect(store.snapshotsFor('g1'), isEmpty);
    });
  });

  group('하위 세션', () {
    test('긴 상위 기록은 스킬로 압축해 넘기고 실패 시 원문을 넘긴다', () async {
      final created = <_FakeBackend>[];
      final skills = SkillRegistry(loadDefaults: false)
        ..registerSkill(
          SkillDefinition(
            name: handoffSkillName,
            description: '',
            skillMdPath: '/skills/SKILL.md',
            directoryPath: '/skills',
          ),
        );
      final manager = SessionManager(
        registry: _registry(created, reply: '압축된 인계 문서'),
        skillRegistry: skills,
        useHelperAgent: true,
      );
      addTearDown(manager.dispose);
      final parent = manager.createSession(
        backendOverride: _FakeBackend(),
        workingDirectory: '/tmp',
        initialEvents: [_user('긴 요청 ${'가' * 3000}')],
      );

      final child = manager.createChildSession(parent.sessionId);
      await child.handoffReady;

      expect(child.parentSessionId, parent.sessionId);
      expect(child.handoffContext, contains('압축된 인계 문서'));
      expect(child.handoffContext, isNot(contains('가' * 100)));
      // created[0]은 하위 세션의 백엔드, created[1]이 일회용 압축 백엔드입니다.
      expect(created[0].prompts, isEmpty);
      expect(created[1].prompts.single, contains('/skills/SKILL.md'));
      expect(created[1].disposed, isTrue);
      expect(manager.sessions, hasLength(2), reason: '압축 백엔드는 세션이 아니다');

      skills.setSkillEnabled(handoffSkillName, false);
      final raw = manager.createChildSession(parent.sessionId);
      await raw.handoffReady;
      expect(raw.handoffContext, contains('가' * 100));
    });

    test('상위 세션을 지우면 하위 세션을 그 위로 올리고 알림을 지운다', () async {
      final manager = SessionManager(registry: _registry([]));
      addTearDown(manager.dispose);
      final root = manager.createSession(
        backendOverride: _FakeBackend(),
        workingDirectory: '/tmp',
      );
      final mid = manager.createChildSession(root.sessionId);
      final leaf = manager.createChildSession(mid.sessionId);
      await manager.deleteSession(mid.sessionId);
      expect(leaf.parentSessionId, root.sessionId);
    });

    test('자동 worktree는 하위 세션에서 실행하고 상위 세션은 비워 둔다', () async {
      final repo = await _createRepo();
      final created = <_FakeBackend>[];
      final notices = <String>[];
      final manager = SessionManager(
        registry: _registry(created),
        autoIsolateWithWorktree: true,
        onChildWorktreeFinished: (parent, child, message) =>
            notices.add(message),
      );
      addTearDown(manager.dispose);
      final parentBackend = _FakeBackend();
      final parent = manager.createSession(
        backendOverride: parentBackend,
        workingDirectory: repo.path,
      );

      await manager.sendPrompt(parent.sessionId, '기능 추가');

      expect(manager.sessions, hasLength(2));
      final child = manager.sessions.last;
      final link = child.activeWorktreeLink!;
      addTearDown(() async {
        await Process.run('git', [
          'worktree',
          'remove',
          '--force',
          link.worktreeRoot,
        ], workingDirectory: repo.path);
        await Directory(link.worktreeRoot).parent
            .delete(recursive: true)
            .then<void>((_) {}, onError: (_) {});
      });
      // 상위 세션은 그대로 선택되어 있고 실행 중이 아니어서 다음 프롬프트를 받을 수 있다.
      expect(child.parentSessionId, parent.sessionId);
      expect(manager.activeSessionId, parent.sessionId);
      expect(parent.status, SessionStatus.idle);
      expect(parent.isolatedWorktreePath, isNull);
      expect(parentBackend.startCount, 0);
      expect(
        Directory(
          created.single.lastConfig!.workingDirectory,
        ).resolveSymbolicLinksSync(),
        Directory(link.worktreeRoot).resolveSymbolicLinksSync(),
      );
      expect(child.status, SessionStatus.running);
      expect(parent.childAttentionCount, 0);

      // 변경 없이 끝나면 병합 요청이 아니다.
      created.single.finishTurn('확인만 했습니다');
      await _settle();
      expect(notices.single, contains('변경 사항이 없습니다'));
      expect(parent.childAttentionCount, 0);

      // 변경이 생기면 병합이 필요하다고 알리고 같은 하위 세션의 알림을 교체한다.
      await File('${link.worktreeRoot}/feature.txt').writeAsString('x\n');
      created.single.finishTurn('구현했습니다');
      await _settle();
      expect(notices.last, contains('develop 병합이 필요합니다'));
      expect(notices.last, contains('미커밋 파일 1개'));
      expect(parent.childAttentionCount, 1);
      final notice = parent.events.whereType<ChildWorktreeEvent>().single;
      expect(notice.canMerge, isTrue);
      expect(notice.summary, '구현했습니다');

      // 병합하면 확인 필요가 사라지고 파일이 대상 브랜치에 들어간다.
      await manager.mergeSessionWorktree(child.sessionId);
      expect(parent.childAttentionCount, 0);
      expect(
        parent.events.whereType<ChildWorktreeEvent>().single.message,
        contains('병합되었습니다'),
      );
      expect(notices, hasLength(2), reason: '직접 병합은 다시 알리지 않는다');
      expect(File('${repo.path}/feature.txt').existsSync(), isTrue);
    });

    test('다음 프롬프트는 새 하위 세션으로 가고 이전 결과를 컨텍스트로 받는다', () async {
      final repo = await _createRepo();
      final created = <_FakeBackend>[];
      final manager = SessionManager(
        registry: _registry(created),
        autoIsolateWithWorktree: true,
      );
      addTearDown(manager.dispose);
      final parent = manager.createSession(
        backendOverride: _FakeBackend(),
        workingDirectory: repo.path,
      );
      addTearDown(() async {
        for (final s in manager.sessions) {
          final link = s.activeWorktreeLink;
          if (link == null) continue;
          await Process.run('git', [
            'worktree',
            'remove',
            '--force',
            link.worktreeRoot,
          ], workingDirectory: repo.path);
        }
      });

      await manager.sendPrompt(parent.sessionId, '첫 작업');
      created.first.finishTurn('첫 작업 결과');
      await _settle();
      await manager.sendPrompt(parent.sessionId, '둘째 작업');

      expect(manager.sessions, hasLength(3));
      final second = created.last.lastConfig!.systemPromptAppend;
      expect(second, contains('첫 작업'));
      expect(second, contains('첫 작업 결과'));
      expect(second, isNot(contains('둘째 작업')));
    });

    test('하위 세션 작업이 실패하면 확인 필요로 알린다', () async {
      final repo = await _createRepo();
      final created = <_FakeBackend>[];
      final manager = SessionManager(
        registry: _registry(created),
        autoIsolateWithWorktree: true,
      );
      addTearDown(manager.dispose);
      final parent = manager.createSession(
        backendOverride: _FakeBackend(),
        workingDirectory: repo.path,
      );
      await manager.sendPrompt(parent.sessionId, '작업');
      final link = manager.sessions.last.activeWorktreeLink!;
      addTearDown(
        () => Process.run('git', [
          'worktree',
          'remove',
          '--force',
          link.worktreeRoot,
        ], workingDirectory: repo.path),
      );
      created.single.eventCtrl.add(
        ErrorEvent(
          id: 'e',
          sessionId: 'x',
          backend: BackendType.claudeCode,
          timestamp: DateTime.now(),
          message: '오류',
        ),
      );
      await _settle();
      expect(parent.childAttentionCount, 1);
      final notice = parent.events.whereType<ChildWorktreeEvent>().single;
      expect(notice.message, contains('실패'));
      expect(notice.canMerge, isFalse);
    });
  });

  group('사이드바 UI', () {
    late Directory temp;
    late TrustedFolderStore trust;
    late WorkspaceGroupStore store;
    late SessionManager manager;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('acc_group_ui_');
      trust = TrustedFolderStore();
      store = WorkspaceGroupStore();
      manager = SessionManager(
        trustedFolders: trust,
        groups: store,
        registry: _registry([]),
      );
    });
    tearDown(() {
      manager.dispose();
      temp.deleteSync(recursive: true);
    });

    Future<void> pumpHome(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final notifications = NotificationService(enableOsPlugin: false);
      final inbox = InboxService(
        notificationService: notifications,
        permissionCenter: PermissionCenter(),
      );
      addTearDown(inbox.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: ControlCenterHomeScreen(
            sessionManagerOverride: manager,
            notificationServiceOverride: notifications,
            inboxServiceOverride: inbox,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> tap(WidgetTester tester, String key) async {
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
    }

    testWidgets('그룹을 만들면 폴더를 신뢰하고 작업 세션 위에 표시한다', (tester) async {
      manager.createSession(
        sessionId: 'free',
        backendOverride: _FakeBackend(),
        workingDirectory: temp.path,
      );
      await pumpHome(tester);
      await tap(tester, 'new_group_button');

      await tester.tap(find.byKey(const ValueKey('save_group_button')));
      await tester.pumpAndSettle();
      expect(find.text('그룹 이름을 입력해 주세요.'), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('group_name')), '프론트');
      await tester.enterText(
        find.byKey(const ValueKey('group_folder')),
        temp.path,
      );
      await tester.enterText(
        find.byKey(const ValueKey('group_default_instructions')),
        '한국어로 답변',
      );
      await tester.enterText(
        find.byKey(const ValueKey('group_extra_instructions')),
        '테스트 필수',
      );
      await tap(tester, 'save_group_button');

      final group = store.groups.single;
      expect(group.name, '프론트');
      expect(trust.isTrusted(temp.path), isTrue);
      expect(store.instructionsFor(group.id), '한국어로 답변\n\n테스트 필수');
      expect(
        tester.getTopLeft(find.text('프론트')).dy,
        lessThan(tester.getTopLeft(find.text('작업 세션')).dy),
      );
    });

    testWidgets('기본 지침을 끄면 입력란이 사라지고 그룹 지침만 적용한다', (tester) async {
      await pumpHome(tester);
      await tap(tester, 'new_group_button');
      await tester.enterText(find.byKey(const ValueKey('group_name')), '단독');
      await tester.enterText(
        find.byKey(const ValueKey('group_folder')),
        temp.path,
      );
      await tap(tester, 'group_use_default_instructions');
      expect(
        find.byKey(const ValueKey('group_default_instructions')),
        findsNothing,
      );
      await tester.enterText(
        find.byKey(const ValueKey('group_extra_instructions')),
        '이것만',
      );
      await tap(tester, 'save_group_button');
      expect(store.instructionsFor(store.groups.single.id), '이것만');
    });

    testWidgets('그룹에서 만든 세션은 그룹 설정을 따르고 이전 세션을 이어갈 수 있다', (tester) async {
      store
        ..upsert(_group(folder: temp.path))
        ..recordSnapshot(
          'g1',
          SessionSnapshot(
            id: 'old',
            title: '이전 작업',
            backend: BackendType.codex,
            lastTurn: '사용자: 결제 구현',
            updatedAt: DateTime(2026),
          ),
        );
      await pumpHome(tester);
      await tap(tester, 'new_session_in_group_g1');

      expect(find.text('새 세션 · 그룹 g1'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey('new_session_instructions')),
        '세션 전용',
      );
      await tap(tester, 'new_session_continue');
      await tester.tap(find.textContaining('이전 작업 · 마지막 작업만').last);
      await tester.pumpAndSettle();
      await tap(tester, 'create_session_button');

      final session = manager.activeSession!;
      expect(session.groupId, 'g1');
      expect(session.backendType, BackendType.codex);
      expect(session.workingDirectory, temp.path);
      expect(session.instructions, '세션 전용');
      await tester.runAsync(() async => session.handoffReady);
      expect(session.handoffContext, contains('결제 구현'));
    });

    testWidgets('이전 세션이 없으면 이어가기 선택을 표시하지 않는다', (tester) async {
      store.upsert(_group(folder: temp.path));
      await pumpHome(tester);
      await tap(tester, 'new_session_in_group_g1');
      expect(find.byKey(const ValueKey('new_session_continue')), findsNothing);
    });

    testWidgets('하위 세션은 상위 세션 아래에 들여써서 표시한다', (tester) async {
      store.upsert(_group(folder: temp.path));
      final root = manager.createSession(
        sessionId: 'root',
        backendOverride: _FakeBackend(),
        workingDirectory: temp.path,
        groupId: 'g1',
      );
      manager.createSession(
        sessionId: 'other',
        title: '다른 세션',
        backendOverride: _FakeBackend(),
        workingDirectory: temp.path,
        groupId: 'g1',
      );
      await pumpHome(tester);
      await tester.tap(
        find.byKey(const ValueKey('session_card_root')),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      await tap(tester, 'session_menu_child');
      expect(find.textContaining('상위 세션의 컨텍스트'), findsOneWidget);
      await tap(tester, 'create_session_button');

      final child = manager.activeSession!;
      expect(child.parentSessionId, root.sessionId);
      expect(child.groupId, 'g1');
      final id = child.sessionId;
      expect(find.byKey(ValueKey('session_child_$id')), findsOneWidget);
      final rootTop = tester.getTopLeft(
        find.byKey(const ValueKey('session_card_root')),
      );
      final childTop = tester.getTopLeft(
        find.byKey(ValueKey('session_card_$id')),
      );
      final otherTop = tester.getTopLeft(
        find.byKey(const ValueKey('session_card_other')),
      );
      expect(childTop.dy, greaterThan(rootTop.dy));
      expect(childTop.dy, lessThan(otherTop.dy), reason: '상위 세션 바로 아래');
      expect(find.byKey(const ValueKey('session_child_root')), findsNothing);
    });

    testWidgets('세션 환경 설정에서 세션별 지침을 바꾼다', (tester) async {
      manager.createSession(
        sessionId: 's1',
        backendOverride: _FakeBackend(),
        workingDirectory: temp.path,
      );
      await pumpHome(tester);
      await tester.tap(
        find.byKey(const ValueKey('session_card_s1')),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      await tap(tester, 'session_menu_settings');
      await tester.enterText(
        find.byKey(const ValueKey('session_settings_instructions')),
        '새 지침',
      );
      await tap(tester, 'save_session_settings_button');
      expect(manager.activeSession!.instructions, '새 지침');
    });

    testWidgets('하위 작업 알림은 상위 세션에 표시되고 열기로 이동한다', (tester) async {
      final root = manager.createSession(
        sessionId: 'root',
        backendOverride: _FakeBackend(),
        workingDirectory: temp.path,
      );
      manager.createSession(
        sessionId: 'kid',
        backendOverride: _FakeBackend(),
        workingDirectory: temp.path,
        parentSessionId: 'root',
        makeActive: false,
      );
      root.events.add(
        ChildWorktreeEvent(
          id: 'n',
          sessionId: 'root',
          backend: BackendType.codex,
          timestamp: DateTime.now(),
          childSessionId: 'kid',
          childTitle: '하위 작업',
          message: 'develop 병합이 필요합니다',
          needsAttention: true,
          canMerge: true,
        ),
      );
      manager.selectSession('root');
      await pumpHome(tester);

      expect(find.byKey(const ValueKey('session_attention_root')), findsOneWidget);
      expect(find.byKey(const ValueKey('merge_child_kid')), findsOneWidget);
      await tap(tester, 'open_child_kid');
      expect(manager.activeSessionId, 'kid');
    });

    testWidgets('그룹을 삭제하면 세션은 작업 세션으로 옮겨진다', (tester) async {
      store.upsert(_group(folder: temp.path));
      manager.createSession(
        sessionId: 's1',
        backendOverride: _FakeBackend(),
        workingDirectory: temp.path,
        groupId: 'g1',
      );
      await pumpHome(tester);
      await tester.tap(find.text('그룹 g1'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tap(tester, 'group_menu_delete');
      await tap(tester, 'confirm_delete_group_button');
      expect(store.groups, isEmpty);
      expect(manager.activeSession!.groupId, isNull);
      expect(find.byKey(const ValueKey('session_card_s1')), findsOneWidget);
    });
  });
}
