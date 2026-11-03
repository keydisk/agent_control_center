import 'dart:io';

import 'package:agent_control_center/core/models/agent_models.dart';
import 'package:agent_control_center/main.dart';
import 'package:agent_control_center/services/inbox_service.dart';
import 'package:agent_control_center/services/notification_service.dart';
import 'package:agent_control_center/services/permission_center.dart';
import 'package:agent_control_center/services/session_manager.dart';
import 'package:agent_control_center/services/storage_service.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'stage4_multi_session_test.dart' show FakeAgentBackend;

ApprovalRequestData request({
  ApprovalCategory category = ApprovalCategory.shellCommand,
  String sessionId = 's1',
}) => ApprovalRequestData(
  id: 'request',
  sessionId: sessionId,
  backend: BackendType.codex,
  toolName: 'tool',
  arguments: const {},
  category: category,
  reason: '권한 경계 검증',
  isDestructive: false,
  createdAt: DateTime.now(),
  targetResource: 'resource',
);

const always = ApprovalDecision(
  requestId: 'request',
  approved: true,
  scope: ApprovalScope.always,
);

void main() {
  test('다른 분류의 권한과 파괴적 분류는 자동 승인 규칙을 공유하지 않는다', () {
    final center = PermissionCenter();
    addTearDown(center.dispose);
    center.recordDecision(request(), always);
    expect(
      center.checkPreApproved(request(category: ApprovalCategory.fileWrite)),
      isNull,
    );
    final decision = center.recordDecision(
      request(category: ApprovalCategory.destructive),
      always,
    );
    expect(decision.scope, ApprovalScope.once);
    expect(center.rules, hasLength(1));
    expect(center.auditLogs.first.isDestructive, isTrue);
  });

  test('권한 재승인과 자동 확인은 DB 규칙을 늘리지 않으며 철회 후 복원되지 않는다', () async {
    final db = AppDriftDatabase();
    final center = PermissionCenter(database: db);
    addTearDown(db.close);
    addTearDown(center.dispose);
    center.recordDecision(request(), always);
    center.recordDecision(request(), always);
    center.checkPreApproved(request());
    center.checkPreApproved(request());
    // 같은 DB 연결의 다음 조회는 앞선 쓰기가 완료된 뒤 실행된다.
    expect(await db.loadPermissionRules(), hasLength(1));
    center.revokeRule(center.rules.single.id);
    expect(await db.loadPermissionRules(), isEmpty);
  });

  test('세션 한정 권한은 DB에서 재시작 후 복원되지 않는다', () async {
    final db = AppDriftDatabase();
    addTearDown(db.close);
    await db.upsertPermissionRule(
      PermissionRule(
        id: 'session_rule',
        backend: BackendType.codex,
        category: ApprovalCategory.shellCommand,
        toolName: 'tool',
        targetResource: 'resource',
        scope: ApprovalScope.session,
        grantedAt: DateTime.now(),
        sessionId: 's1',
      ),
    );
    final center = PermissionCenter(database: db);
    addTearDown(center.dispose);
    await center.loadFromDatabase();
    expect(center.checkPreApproved(request()), isNull);
  });

  test('모델과 디렉터리 변경은 다음 실행 설정에 반영된다', () async {
    final backend = FakeAgentBackend(BackendType.codex);
    final manager = SessionManager();
    addTearDown(manager.dispose);
    final session = manager.createSession(
      backendType: BackendType.codex,
      backendOverride: backend,
      workingDirectory: '/tmp/original',
    );
    await manager.sendPrompt(session.sessionId, '첫 요청');
    manager.updateSessionModel(session.sessionId, 'different-model');
    await manager.sendPrompt(session.sessionId, '모델 변경 후 요청');
    expect(backend.lastConfig!.model, 'different-model');
    expect(backend.lastConfig!.conversationId, 'fake_conv_id');
    manager.updateSessionWorkingDirectory(session.sessionId, '/tmp/changed');
    await manager.sendPrompt(session.sessionId, '디렉터리 변경 후 요청');
    expect(backend.lastConfig!.workingDirectory, '/tmp/changed');
    expect(backend.lastConfig!.conversationId, isNull);
  });

  test('실행 중 세션 격리는 기존 프로세스를 중지하고 격리 경로로 재시작한다', () async {
    final backend = FakeAgentBackend(BackendType.codex);
    final manager = SessionManager(
      worktreeAllocator: (_, _) async => '/tmp/isolated',
    );
    addTearDown(manager.dispose);
    final session = manager.createSession(backendOverride: backend);
    await manager.sendPrompt(session.sessionId, '첫 요청');
    await manager.isolateSessionWithWorktree(session.sessionId);
    expect(backend.interrupted, isTrue);
    expect(session.status, SessionStatus.stopped);
    await manager.sendPrompt(session.sessionId, '두 번째 요청');
    expect(backend.lastConfig!.workingDirectory, '/tmp/isolated');
  });

  test('실제 worktree는 하위 디렉터리를 유지하고 같은 세션 ID에도 고유 경로를 할당한다', () async {
    final repo = await Directory.systemTemp.createTemp('acc_git_');
    final paths = <String>[];
    Future<ProcessResult> git(List<String> args) async {
      final result = await Process.run(
        'git',
        args,
        workingDirectory: repo.path,
      );
      expect(result.exitCode, 0, reason: result.stderr.toString());
      return result;
    }

    addTearDown(() async {
      for (final path in paths) {
        final checkout = Directory(path).parent;
        await git(['worktree', 'remove', '--force', checkout.path]);
        await checkout.parent.delete();
      }
      await repo.delete(recursive: true);
    });
    await git(['init']);
    final app = await Directory('${repo.path}/app').create();
    await File('${app.path}/source.txt').writeAsString('fixture');
    await git(['add', '.']);
    await git([
      '-c',
      'user.name=Test',
      '-c',
      'user.email=test@example.com',
      'commit',
      '-m',
      '테스트 저장소 초기화',
    ]);
    final manager = SessionManager();
    addTearDown(manager.dispose);
    final session = manager.createSession(
      sessionId: 'same_id',
      workingDirectory: app.path,
    );
    for (var i = 0; i < 2; i++) {
      final path = await manager.isolateSessionWithWorktree(session.sessionId);
      paths.add(path);
      expect(await File('$path/source.txt').readAsString(), 'fixture');
    }
    expect(paths[0], isNot(paths[1]));
  });

  test('자동 격리 실패는 세션 오류로 기록하고 백엔드를 실행하지 않는다', () async {
    final backend = FakeAgentBackend(BackendType.codex);
    final manager = SessionManager(worktreeAllocator: (_, _) async => throw StateError('격리 실패'));
    addTearDown(manager.dispose);
    final session = manager.createSession(backendOverride: backend);
    await manager.sendPrompt(session.sessionId, '요청', isolateWithWorktree: true);
    expect(session.status, SessionStatus.failed);
    expect(session.events.last, isA<ErrorEvent>());
    expect(backend.started, isFalse);
  });

  test('Git 저장소가 아니면 격리 성공으로 처리하지 않는다', () async {
    final directory = await Directory.systemTemp.createTemp('acc_non_git_');
    addTearDown(() => directory.delete(recursive: true));
    final manager = SessionManager();
    addTearDown(manager.dispose);
    final session = manager.createSession(workingDirectory: directory.path);
    await expectLater(
      manager.isolateSessionWithWorktree(session.sessionId),
      throwsStateError,
    );
    expect(session.isolatedWorktreePath, isNull);
  });

  test('실패한 Inbox 요약은 다음 수집에서 재시도할 수 있다', () async {
    var attempts = 0;
    final inbox = InboxService(
      notificationService: NotificationService(enableOsPlugin: false),
      customSummarizer: (raw, sanitized, backend, model) async {
        attempts++;
        throw StateError('요약 서버 장애');
      },
    );
    addTearDown(inbox.dispose);
    final message = InboxMessageRaw(
      id: 'retry',
      source: InboxSourceType.gmail,
      sender: 'sender',
      subject: '제목',
      body: '본문',
      receivedAt: DateTime.now(),
    );
    await expectLater(inbox.ingestAndSummarize(message), throwsStateError);
    expect(inbox.isDuplicateMessage(message.source, message.id), isFalse);
    await expectLater(inbox.ingestAndSummarize(message), throwsStateError);
    expect(attempts, 2);
  });

  testWidgets('격리 실패는 UI 오류 안내를 표시하고 충돌 배너를 유지한다', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final manager = SessionManager(
      worktreeAllocator: (_, _) async => throw StateError('git 실패'),
    );
    addTearDown(manager.dispose);
    for (var i = 0; i < 2; i++) {
      final session = manager.createSession(
        workingDirectory: '/tmp/shared',
        backendOverride: FakeAgentBackend(BackendType.codex),
      );
      await manager.sendPrompt(session.sessionId, '작업 $i');
    }
    await tester.pumpWidget(
      MaterialApp(
        home: ControlCenterHomeScreen(sessionManagerOverride: manager),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('banner_isolate_worktree_btn')));
    await tester.pumpAndSettle();
    expect(find.textContaining('작업 디렉터리 격리 실패:'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('active_session_conflict_banner')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
