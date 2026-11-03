import 'dart:async';
import 'dart:io';

import 'package:agent_control_center/core/backend/agent_backend.dart';
import 'package:agent_control_center/core/models/agent_models.dart';
import 'package:agent_control_center/main.dart';
import 'package:agent_control_center/services/inbox_service.dart';
import 'package:agent_control_center/services/notification_service.dart';
import 'package:agent_control_center/services/permission_center.dart';
import 'package:agent_control_center/services/session_manager.dart';
import 'package:agent_control_center/services/trusted_folder_store.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeBackend implements AgentBackend {
  final eventCtrl = StreamController<AgentEvent>.broadcast();
  final rawLogCtrl = StreamController<String>.broadcast();
  bool disposed = false;

  @override
  BackendType get backendType => BackendType.codex;
  @override
  Stream<AgentEvent> get events => eventCtrl.stream;
  @override
  Stream<String> get rawLogs => rawLogCtrl.stream;
  @override
  String? get remoteConversationId => null;
  @override
  Future<void> start(AgentSessionConfig config) async {}
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
  Future<void> dispose() async {
    disposed = true;
  }
}

Future<String> _git(String dir, List<String> args) async {
  final result = await Process.run('git', args, workingDirectory: dir);
  expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
  return result.stdout.toString().trim();
}

void main() {
  group('세션 삭제', () {
    Future<Directory> createRepo() async {
      final repo = await Directory.systemTemp.createTemp('acc_stage10_');
      addTearDown(() => repo.delete(recursive: true));
      await _git(repo.path, ['init', '-b', 'develop']);
      await _git(repo.path, ['config', 'user.name', 'Test']);
      await _git(repo.path, ['config', 'user.email', 'test@example.com']);
      await File('${repo.path}/source.txt').writeAsString('fixture\n');
      await _git(repo.path, ['add', '.']);
      await _git(repo.path, ['commit', '-m', '초기화']);
      return repo;
    }

    test('삭제하면 백엔드를 정리하고 다른 세션을 활성화한다', () async {
      final manager = SessionManager();
      addTearDown(manager.dispose);
      final backend = _FakeBackend();
      manager.createSession(
        sessionId: 'a',
        backendOverride: _FakeBackend(),
        workingDirectory: '/tmp',
      );
      manager.createSession(
        sessionId: 'b',
        backendOverride: backend,
        workingDirectory: '/tmp',
      );
      expect(manager.activeSessionId, 'b');

      expect(await manager.deleteSession('b'), isNull);
      expect(backend.disposed, isTrue);
      expect(manager.activeSessionId, 'a');

      await manager.deleteSession('a');
      expect(manager.activeSession, isNull);
      expect(await manager.deleteSession('none'), isNull);
    });

    test('변경 없는 worktree는 정리하고 변경 있는 worktree는 남긴다', () async {
      final repo = await createRepo();
      final manager = SessionManager(autoIsolateWithWorktree: true);
      addTearDown(manager.dispose);
      final clean = manager.createSession(
        sessionId: 'clean',
        backendOverride: _FakeBackend(),
        workingDirectory: repo.path,
        parentSessionId: 'root',
      );
      await manager.sendPrompt(clean.sessionId, '요청');
      final cleanRoot = clean.activeWorktreeLink!.worktreeRoot;
      expect(await manager.deleteSession('clean'), isNull);
      expect(Directory(cleanRoot).existsSync(), isFalse);
      expect(await _git(repo.path, ['branch', '--list', 'acc/*']), isEmpty);

      final dirty = manager.createSession(
        sessionId: 'dirty',
        backendOverride: _FakeBackend(),
        workingDirectory: repo.path,
        parentSessionId: 'root',
      );
      await manager.sendPrompt(dirty.sessionId, '요청');
      final link = dirty.activeWorktreeLink!;
      addTearDown(() async {
        await _git(repo.path, ['worktree', 'remove', '--force', link.worktreeRoot]);
        await Directory(link.worktreeRoot).parent.delete();
      });
      await File('${link.worktreeRoot}/work.txt').writeAsString('작업');
      expect(await manager.deleteSession('dirty'), link.worktreeRoot);
      expect(File('${link.worktreeRoot}/work.txt').existsSync(), isTrue);
    });
  });

  group('세션 메뉴 UI', () {
    late Directory temp;
    late Directory project;
    late TrustedFolderStore store;
    late SessionManager manager;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('acc_menu_');
      project = Directory('${temp.path}/project')..createSync();
      store = TrustedFolderStore();
      manager = SessionManager(trustedFolders: store);
      manager.createSession(
        sessionId: 's1',
        title: '기존 세션',
        backendType: BackendType.codex,
        backendOverride: _FakeBackend(),
        workingDirectory: project.path,
      );
    });
    tearDown(() {
      manager.dispose();
      temp.deleteSync(recursive: true);
    });

    Future<void> pumpHome(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1400, 1000);
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

    Future<void> openMenu(WidgetTester tester) async {
      await tester.tap(
        find.byKey(const ValueKey('session_card_s1')),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
    }

    Future<void> pick(WidgetTester tester, String key) async {
      await tester.tap(find.byKey(ValueKey(key)));
      await tester.pumpAndSettle();
    }

    testWidgets('오른쪽 클릭 메뉴에 새 세션·환경 설정·삭제가 표시된다', (tester) async {
      await pumpHome(tester);
      expect(find.text('환경 설정'), findsNothing);
      await openMenu(tester);
      expect(find.text('새 세션'), findsOneWidget);
      expect(find.text('환경 설정'), findsOneWidget);
      expect(find.text('삭제'), findsOneWidget);
    });

    testWidgets('새 세션은 지정한 폴더로 만들고 기본으로 신뢰한다', (tester) async {
      await pumpHome(tester);
      await openMenu(tester);
      await pick(tester, 'session_menu_new');
      expect(find.byKey(const ValueKey('new_session_dialog')), findsOneWidget);

      final field = find.byKey(const ValueKey('new_session_folder'));
      await tester.enterText(field, '${temp.path}/none');
      await pick(tester, 'create_session_button');
      expect(find.text('존재하지 않는 폴더입니다.'), findsOneWidget);

      await tester.enterText(field, '/');
      await pick(tester, 'create_session_button');
      expect(find.textContaining('루트 폴더'), findsOneWidget);
      expect(manager.sessions, hasLength(1));

      final other = Directory('${temp.path}/other')..createSync();
      await tester.enterText(field, other.path);
      await pick(tester, 'create_session_button');
      expect(manager.sessions, hasLength(2));
      expect(manager.activeSession!.workingDirectory, other.path);
      expect(manager.activeSession!.backendType, BackendType.codex);
      expect(store.isTrusted(other.path), isTrue);
    });

    testWidgets('상단 버튼에서 취소하면 세션도 신뢰도 추가하지 않는다', (tester) async {
      await pumpHome(tester);
      await pick(tester, 'new_session_button');
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      expect(manager.sessions, hasLength(1));
      expect(store.folders, isEmpty);
    });

    testWidgets('환경 설정에서 이름을 바꾸고 폴더 신뢰를 해제한다', (tester) async {
      store.add(project.path);
      await pumpHome(tester);
      await openMenu(tester);
      await pick(tester, 'session_menu_settings');

      await tester.enterText(
        find.byKey(const ValueKey('session_settings_title')),
        '새 이름',
      );
      await tester.tap(find.byKey(const ValueKey('session_settings_trust')));
      await tester.pump();
      expect(store.isTrusted(project.path), isTrue, reason: '저장 전에는 유지');
      await pick(tester, 'save_session_settings_button');

      expect(manager.activeSession!.title, '새 이름');
      expect(store.isTrusted(project.path), isFalse);
      expect(find.text('신뢰 폴더 (0)'), findsOneWidget);
    });

    testWidgets('상위 폴더로 신뢰된 경우 해제 대상을 알리고 그 등록을 해제한다', (tester) async {
      store.add(temp.path);
      await pumpHome(tester);
      await openMenu(tester);
      await pick(tester, 'session_menu_settings');
      await tester.tap(find.byKey(const ValueKey('session_settings_trust')));
      await tester.pump();
      expect(find.textContaining('신뢰를 해제합니다'), findsOneWidget);
      await pick(tester, 'save_session_settings_button');
      expect(store.folders, isEmpty);
    });

    testWidgets('실행 중에는 폴더를 바꿀 수 없다', (tester) async {
      manager.activeSession!.status = SessionStatus.running;
      await pumpHome(tester);
      await openMenu(tester);
      await pick(tester, 'session_menu_settings');
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('session_settings_folder')),
      );
      expect(field.enabled, isFalse);
      expect(find.text('실행 중에는 폴더를 바꿀 수 없습니다.'), findsOneWidget);
    });

    group('상단 신뢰 폴더 표시', () {
      Finder indicator() =>
          find.byKey(const ValueKey('trusted_folder_indicator'));

      Finder inIndicator(String text) =>
          find.descendant(of: indicator(), matching: find.text(text));

      testWidgets('신뢰된 작업 폴더를 표시한다', (tester) async {
        store.add(project.path);
        await pumpHome(tester);
        expect(inIndicator('project'), findsOneWidget);
      });

      testWidgets('상위 폴더로 신뢰되면 가장 가까운 등록 폴더를 표시한다', (tester) async {
        store.add(temp.path);
        await pumpHome(tester);
        final parentName = temp.path.split('/').last;
        expect(inIndicator(parentName), findsOneWidget);

        store.add(project.path);
        manager.updateSessionTitle('s1', '갱신');
        await tester.pump();
        expect(inIndicator('project'), findsOneWidget);
      });

      testWidgets('신뢰하지 않은 폴더는 상태를 알리고 누르면 환경 설정을 연다', (tester) async {
        await pumpHome(tester);
        expect(inIndicator('신뢰 안 됨 · project'), findsOneWidget);
        await tester.tap(indicator());
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('session_settings_dialog')),
          findsOneWidget,
        );
      });

      testWidgets('환경 설정에서 해제하면 표시가 바뀌고 세션이 없으면 사라진다', (tester) async {
        store.add(project.path);
        await pumpHome(tester);
        await tester.tap(indicator());
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('session_settings_trust')));
        await tester.pump();
        await pick(tester, 'save_session_settings_button');
        expect(inIndicator('신뢰 안 됨 · project'), findsOneWidget);

        // 정리 Future를 기다리면 가짜 시간에서 멈추므로 목록 갱신만 확인합니다.
        unawaited(manager.deleteSession('s1'));
        await tester.pump();
        expect(indicator(), findsNothing);
      });

      testWidgets('좁은 창에서도 넘치지 않는다', (tester) async {
        final long = Directory('${temp.path}/${'아주긴폴더이름' * 12}')..createSync();
        store.add(long.path);
        manager.updateSessionWorkingDirectory('s1', long.path);
        await pumpHome(tester);
        tester.view.physicalSize = const Size(860, 700);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(indicator(), findsOneWidget);
      });
    });

    testWidgets('삭제는 확인 후 수행하고 마지막 세션이면 안내를 표시한다', (tester) async {
      await pumpHome(tester);
      await openMenu(tester);
      await pick(tester, 'session_menu_delete');
      await tester.tap(find.text('취소'));
      await tester.pumpAndSettle();
      expect(manager.sessions, hasLength(1));

      await openMenu(tester);
      await pick(tester, 'session_menu_delete');
      await pick(tester, 'confirm_delete_session_button');
      await tester.pump();
      expect(manager.sessions, isEmpty);
      expect(find.byKey(const ValueKey('session_card_s1')), findsNothing);
      expect(find.text('세션이 없습니다.'), findsOneWidget);
    });
  });
}
