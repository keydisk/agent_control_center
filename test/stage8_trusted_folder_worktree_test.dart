import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_control_center/core/backend/agent_backend.dart';
import 'package:agent_control_center/core/models/agent_models.dart';
import 'package:agent_control_center/services/session_manager.dart';
import 'package:agent_control_center/services/trusted_folder_store.dart';
import 'package:agent_control_center/ui/screens/trusted_folders_screen.dart';
import 'package:agent_control_center/ui/widgets/multi_session_sidebar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeBackend implements AgentBackend {
  final eventCtrl = StreamController<AgentEvent>.broadcast();
  final rawLogCtrl = StreamController<String>.broadcast();
  AgentSessionConfig? lastConfig;
  bool started = false;

  @override
  BackendType get backendType => BackendType.codex;
  @override
  Stream<AgentEvent> get events => eventCtrl.stream;
  @override
  Stream<String> get rawLogs => rawLogCtrl.stream;
  @override
  String? get remoteConversationId => null;
  @override
  Future<void> start(AgentSessionConfig config) async {
    started = true;
    lastConfig = config;
  }

  @override
  Future<void> send(
    String prompt, {
    List<String> attachments = const [],
  }) async {}
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
  Future<void> dispose() async {}
}

Future<String> _git(String dir, List<String> args) async {
  final result = await Process.run('git', args, workingDirectory: dir);
  expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
  return result.stdout.toString().trim();
}

Future<Directory> _createRepo() async {
  final repo = await Directory.systemTemp.createTemp('acc_stage8_');
  addTearDown(() => repo.delete(recursive: true));
  await _git(repo.path, ['init', '-b', 'develop']);
  await _git(repo.path, ['config', 'user.name', 'Test']);
  await _git(repo.path, ['config', 'user.email', 'test@example.com']);
  await File('${repo.path}/source.txt').writeAsString('fixture\n');
  await _git(repo.path, ['add', '.']);
  await _git(repo.path, ['commit', '-m', '초기화']);
  return repo;
}

SessionManager _manager() {
  final manager = SessionManager(autoIsolateWithWorktree: true);
  addTearDown(manager.dispose);
  return manager;
}

void main() {
  group('TrustedFolderStore', () {
    late Directory temp;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('acc_trust_');
    });
    tearDown(() => temp.delete(recursive: true));

    test('하위 폴더는 신뢰를 상속하고 형제 폴더와 외부 심볼릭 링크는 제외한다', () async {
      final trusted = await Directory('${temp.path}/project').create();
      final child = await Directory('${trusted.path}/app').create();
      final sibling = await Directory('${temp.path}/project2').create();
      final link = await Link(
        '${trusted.path}/escape',
      ).create(sibling.path);
      final store = TrustedFolderStore()..add(trusted.path);

      expect(store.isTrusted(trusted.path), isTrue);
      expect(store.isTrusted(child.path), isTrue);
      expect(store.isTrusted(sibling.path), isFalse);
      expect(store.isTrusted(link.path), isFalse);
      expect(store.isTrusted('${child.path}/../../project2'), isFalse);
    });

    test('루트와 없는 폴더는 등록을 거부한다', () {
      final store = TrustedFolderStore();
      expect(() => store.add('/'), throwsStateError);
      expect(() => store.add('${temp.path}/none'), throwsStateError);
      expect(store.folders, isEmpty);
    });

    test('목록은 파일에 저장되고 손상된 파일은 신뢰 없음으로 읽는다', () {
      final file = File('${temp.path}/conf/trusted.json');
      TrustedFolderStore(file: file).add(temp.path);
      expect(TrustedFolderStore(file: file).isTrusted(temp.path), isTrue);

      TrustedFolderStore(file: file).remove(
        TrustedFolderStore(file: file).folders.single,
      );
      expect(TrustedFolderStore(file: file).folders, isEmpty);

      for (final corrupt in ['{', jsonEncode({'a': 1}), '[1]']) {
        file.writeAsStringSync(corrupt);
        expect(TrustedFolderStore(file: file).isTrusted(temp.path), isFalse);
      }
    });

    test('신뢰를 거부하면 에이전트를 실행하지 않고 승인하면 저장 후 실행한다', () async {
      final backend = _FakeBackend();
      var answer = false;
      var asked = 0;
      final store = TrustedFolderStore();
      final manager = SessionManager(
        trustedFolders: store,
        onFolderTrustRequired: (_) async {
          asked++;
          return answer;
        },
      );
      addTearDown(manager.dispose);
      final session = manager.createSession(
        backendOverride: backend,
        workingDirectory: temp.path,
      );

      await manager.sendPrompt(session.sessionId, '요청');
      expect(backend.started, isFalse);
      expect(session.status, SessionStatus.failed);
      expect(session.events.last, isA<ErrorEvent>());

      answer = true;
      await manager.retrySession(session.sessionId);
      expect(backend.started, isTrue);
      expect(store.isTrusted(temp.path), isTrue);

      await manager.sendPrompt(session.sessionId, '다음 요청');
      expect(asked, 2);
    });
  });

  group('worktree 연결', () {
    test('Git 저장소가 아니면 원래 폴더에서 실행한다', () async {
      final dir = await Directory.systemTemp.createTemp('acc_no_git_');
      addTearDown(() => dir.delete(recursive: true));
      final backend = _FakeBackend();
      final manager = _manager();
      final session = manager.createSession(
        backendOverride: backend,
        workingDirectory: dir.path,
      );
      await manager.sendPrompt(session.sessionId, '요청');
      expect(backend.lastConfig!.workingDirectory, dir.path);
      expect(session.worktreeLinks, isEmpty);
    });

    test('브랜치 worktree에서 실행하고 병합 후 정리하며 다음 요청은 새 worktree를 쓴다', () async {
      final repo = await _createRepo();
      final backend = _FakeBackend();
      final manager = _manager();
      final session = manager.createSession(
        backendOverride: backend,
        workingDirectory: repo.path,
      );

      await manager.sendPrompt(session.sessionId, '기능 추가');
      final worktree = backend.lastConfig!.workingDirectory;
      expect(worktree, isNot(repo.path));
      final link = session.activeWorktreeLink!;
      expect(link.baseBranch, 'develop');
      expect(link.branch, startsWith('acc/'));

      // 변경이 없으면 병합하지 않는다
      session.status = SessionStatus.completed;
      await expectLater(
        manager.mergeSessionWorktree(session.sessionId),
        throwsStateError,
      );
      expect(session.activeWorktreeLink, same(link));

      // 에이전트가 커밋하지 않은 파일도 함께 병합된다
      await File('$worktree/feature.txt').writeAsString('feature\n');
      await manager.mergeSessionWorktree(session.sessionId);

      expect(File('${repo.path}/feature.txt').existsSync(), isTrue);
      final merged = session.worktreeLinks.single;
      expect(merged.isMerged, isTrue);
      expect(
        merged.mergeCommit,
        await _git(repo.path, ['rev-parse', '--short', 'HEAD']),
      );
      expect(await _git(repo.path, ['log', '-1', '--format=%P']), contains(' '));
      expect(Directory(worktree).existsSync(), isFalse);
      expect(Directory(worktree).parent.existsSync(), isFalse);
      expect(session.isolatedWorktreePath, isNull);
      expect(await _git(repo.path, ['branch', '--list', 'acc/*']), isEmpty);

      await manager.sendPrompt(session.sessionId, '후속 작업');
      addTearDown(() async {
        final next = session.activeWorktreeLink!;
        await _git(repo.path, ['worktree', 'remove', next.worktreeRoot]);
        await Directory(next.worktreeRoot).parent.delete();
      });
      expect(session.worktreeLinks, hasLength(2));
      expect(session.worktreeLinks.first.isMerged, isTrue);
      expect(session.activeWorktreeLink, isNotNull);
      expect(
        File('${backend.lastConfig!.workingDirectory}/feature.txt').existsSync(),
        isTrue,
      );
    });

    test('충돌하면 병합을 되돌리고 연결을 활성 상태로 유지한다', () async {
      final repo = await _createRepo();
      final backend = _FakeBackend();
      final manager = _manager();
      final session = manager.createSession(
        backendOverride: backend,
        workingDirectory: repo.path,
      );
      await manager.sendPrompt(session.sessionId, '요청');
      session.status = SessionStatus.completed;
      final link = session.activeWorktreeLink!;
      addTearDown(() async {
        await _git(repo.path, ['worktree', 'remove', link.worktreeRoot]);
        await Directory(link.worktreeRoot).parent.delete();
      });

      await File('${link.worktreeRoot}/source.txt').writeAsString('branch\n');
      await File('${repo.path}/source.txt').writeAsString('base\n');
      await _git(repo.path, ['commit', '-am', '대상 브랜치 변경']);

      await expectLater(
        manager.mergeSessionWorktree(session.sessionId),
        throwsStateError,
      );
      expect(session.activeWorktreeLink, same(link));
      expect(await _git(repo.path, ['status', '--porcelain']), isEmpty);
      expect(
        await File('${repo.path}/source.txt').readAsString(),
        'base\n',
      );
    });

    test('대상 브랜치가 체크아웃되어 있지 않으면 병합하지 않는다', () async {
      final repo = await _createRepo();
      final manager = _manager();
      final session = manager.createSession(
        backendOverride: _FakeBackend(),
        workingDirectory: repo.path,
      );
      await manager.sendPrompt(session.sessionId, '요청');
      session.status = SessionStatus.completed;
      final link = session.activeWorktreeLink!;
      addTearDown(() async {
        await _git(repo.path, ['worktree', 'remove', '--force', link.worktreeRoot]);
        await Directory(link.worktreeRoot).parent.delete();
      });
      await File('${link.worktreeRoot}/feature.txt').writeAsString('x');
      await _git(repo.path, ['checkout', '-b', 'other']);

      await expectLater(
        manager.mergeSessionWorktree(session.sessionId),
        throwsStateError,
      );
      expect(session.activeWorktreeLink, same(link));
      expect(File('${link.worktreeRoot}/feature.txt').existsSync(), isTrue);
    });

    test('에이전트가 직접 병합하면 턴 종료 시 연결 고리를 표시한다', () async {
      final repo = await _createRepo();
      final backend = _FakeBackend();
      final manager = _manager();
      final session = manager.createSession(
        backendOverride: backend,
        workingDirectory: repo.path,
      );
      await manager.sendPrompt(session.sessionId, '요청');
      final link = session.activeWorktreeLink!;

      await File('${link.worktreeRoot}/agent.txt').writeAsString('agent\n');
      await _git(link.worktreeRoot, ['add', '.']);
      await _git(link.worktreeRoot, ['commit', '-m', '에이전트 커밋']);
      await _git(repo.path, ['merge', '--no-ff', '-m', '병합', link.branch]);

      final done = Completer<void>();
      manager.addListener(() {
        if (session.worktreeLinks.last.isMerged && !done.isCompleted) {
          done.complete();
        }
      });
      backend.eventCtrl.add(
        DoneEvent(
          id: 'd1',
          sessionId: session.sessionId,
          backend: BackendType.codex,
          model: 'm',
          timestamp: DateTime.now(),
        ),
      );
      await done.future.timeout(const Duration(seconds: 10));
      expect(
        session.worktreeLinks.last.mergeCommit,
        await _git(repo.path, ['rev-parse', '--short', 'develop']),
      );
    });
  });

  group('사이드바 UI', () {
    ManagedSession buildSession(List<WorktreeLink> links, {String? worktree}) {
      return ManagedSession(
        sessionId: 's1',
        title: '작업',
        backendType: BackendType.codex,
        model: 'm',
        workingDirectory: '/repo',
        backend: _FakeBackend(),
        isolatedWorktreePath: worktree,
      )..worktreeLinks.addAll(links);
    }

    Widget wrap(ManagedSession session, {
      ValueChanged<String>? onMerge,
      VoidCallback? onManage,
    }) {
      return MaterialApp(
        home: Scaffold(
          body: MultiSessionSidebar(
            sessions: [session],
            activeSessionId: 's1',
            usageByBackend: const {},
            onSelectSession: (_) {},
            onNewSession: (_) {},
            onStopSession: (_) {},
            onRetrySession: (_) {},
            onRerunWithBackend: (_, _) {},
            onIsolateWorktree: (_) {},
            onMergeWorktree: onMerge,
            trustedFolderCount: 2,
            onManageTrustedFolders: onManage,
          ),
        ),
      );
    }

    const active = WorktreeLink(
      baseBranch: 'develop',
      branch: 'acc/one',
      worktreeRoot: '/wt/one',
      startCommit: 'aaa',
    );

    testWidgets('병합 전에는 병합 버튼, 병합 후에는 커밋을 표시한다', (tester) async {
      String? mergedId;
      await tester.pumpWidget(
        wrap(
          buildSession([active], worktree: '/wt/one'),
          onMerge: (id) => mergedId = id,
        ),
      );
      expect(find.text('acc/one'), findsOneWidget);
      expect(find.text('develop'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('merge_worktree_acc/one')));
      expect(mergedId, 's1');

      await tester.pumpWidget(wrap(buildSession([active.merged('abc1234')])));
      expect(find.text('병합됨 abc1234'), findsOneWidget);
      expect(find.byKey(const ValueKey('merge_worktree_acc/one')), findsNothing);
    });

    testWidgets('분리된 미병합 연결은 병합 버튼 없이 미병합으로 표시한다', (tester) async {
      await tester.pumpWidget(wrap(buildSession([active])));
      expect(find.text('미병합'), findsOneWidget);
      expect(find.byKey(const ValueKey('merge_worktree_acc/one')), findsNothing);
    });

    testWidgets('신뢰 폴더 항목과 다이얼로그에서 폴더를 추가·해제한다', (tester) async {
      var opened = false;
      await tester.pumpWidget(
        wrap(buildSession(const []), onManage: () => opened = true),
      );
      expect(find.text('신뢰 폴더 (2)'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('open_trusted_folders_button')));
      expect(opened, isTrue);

      final store = TrustedFolderStore();
      final dir = Directory.systemTemp.createTempSync('acc_dialog_');
      addTearDown(() => dir.deleteSync());
      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: TrustedFoldersDialog(store: store))),
      );
      await tester.enterText(
        find.byKey(const ValueKey('trusted_folder_input')),
        '/',
      );
      await tester.tap(find.byKey(const ValueKey('add_trusted_folder_button')));
      await tester.pump();
      expect(store.folders, isEmpty);
      expect(find.textContaining('루트 폴더'), findsOneWidget);

      await tester.enterText(
        find.byKey(const ValueKey('trusted_folder_input')),
        dir.path,
      );
      await tester.tap(find.byKey(const ValueKey('add_trusted_folder_button')));
      await tester.pump();
      final added = store.folders.single;
      expect(find.text(added), findsOneWidget);

      await tester.tap(find.byKey(ValueKey('remove_trusted_$added')));
      await tester.pump();
      expect(store.folders, isEmpty);
    });
  });
}
