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
import 'package:agent_control_center/services/workspace_group_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeBackend implements AgentBackend {
  _FakeBackend({this.helperReply, this.helperGate});

  /// 값이 있으면 send 때 이 답변을 내고 턴을 끝내는 일회용 백엔드로 동작합니다.
  final String? helperReply;

  /// 답변을 늦춰 이름 짓는 도중의 상황을 시험합니다.
  final Future<void>? helperGate;
  final eventCtrl = StreamController<AgentEvent>.broadcast(sync: true);
  final rawLogCtrl = StreamController<String>.broadcast();
  final prompts = <String>[];

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
  }) async {
    prompts.add(prompt);
    final reply = helperReply;
    if (reply == null) return;
    await helperGate;
    eventCtrl
      ..add(_message('assistant', reply))
      ..add(_done());
  }

  void finishFirstTurn() {
    eventCtrl
      ..add(_message('user', '로그인 화면에서 비밀번호 오류가 나요'))
      ..add(_message('assistant', '검증 로직을 고쳤습니다'))
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
  Future<void> dispose() async {}
}

MessageEvent _message(String role, String text) => MessageEvent(
  id: '${role}_${DateTime.now().microsecondsSinceEpoch}',
  sessionId: 'x',
  backend: BackendType.codex,
  timestamp: DateTime.now(),
  role: role,
  text: text,
);

DoneEvent _done() => DoneEvent(
  id: 'd_${DateTime.now().microsecondsSinceEpoch}',
  sessionId: 'x',
  backend: BackendType.codex,
  timestamp: DateTime.now(),
);

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  group('cleanSessionTitle', () {
    test('첫 내용 줄만 남기고 꾸밈과 긴 이름을 정리한다', () {
      expect(cleanSessionTitle('로그인 오류 수정'), '로그인 오류 수정');
      expect(cleanSessionTitle('\n# "로그인 오류 수정."\n설명'), '로그인 오류 수정');
      expect(cleanSessionTitle('**`결제 연동`**'), '결제 연동');
      expect(cleanSessionTitle('가' * 40), '${'가' * 28}...');
      expect(cleanSessionTitle(' \n"" \n'), isNull);
    });
  });

  group('첫 대화로 이름 짓기', () {
    late List<_FakeBackend> helpers;
    late SessionManager manager;
    late _FakeBackend backend;
    Future<void>? gate;
    var reply = '로그인 오류 수정';

    setUp(() {
      helpers = [];
      gate = null;
      reply = '로그인 오류 수정';
      final registry = BackendRegistry();
      for (final type in BackendType.values) {
        registry.register(type, ({spawner, hookBridge}) {
          final helper = _FakeBackend(helperReply: reply, helperGate: gate);
          helpers.add(helper);
          return helper;
        });
      }
      manager = SessionManager(
        registry: registry,
        groups: WorkspaceGroupStore()
          ..upsert(
            WorkspaceGroup(
              id: 'g1',
              name: '그룹',
              folder: '/tmp',
              backend: BackendType.codex,
              model: BackendType.codex.defaultModel,
              effort: BackendType.codex.defaultEffort,
            ),
          ),
        useHelperAgent: true,
      );
      backend = _FakeBackend();
    });
    tearDown(() => manager.dispose());

    ManagedSession create({String? title}) => manager.createSession(
      title: title,
      backendOverride: backend,
      workingDirectory: '/tmp',
      groupId: 'g1',
    );

    test('이름이 없으면 프롬프트 첫 줄로 시작해 첫 턴 뒤 대화로 이름을 짓는다', () async {
      final session = create();
      await manager.sendPrompt(session.sessionId, '로그인이 안 돼요\n자세한 내용');
      expect(session.title, '로그인이 안 돼요');

      backend.finishFirstTurn();
      await _settle();

      expect(session.title, '로그인 오류 수정');
      expect(helpers.single.prompts.single, contains('검증 로직을 고쳤습니다'));
      expect(manager.sessions, hasLength(1), reason: '이름 짓기는 세션을 만들지 않는다');
      expect(
        manager.groups!.snapshotsFor('g1').single.title,
        '로그인 오류 수정',
        reason: '이어가기 목록에도 새 이름을 쓴다',
      );

      // 이름은 한 번만 짓는다.
      backend.finishFirstTurn();
      await _settle();
      expect(helpers, hasLength(1));
    });

    test('사용자가 정한 이름은 프롬프트와 첫 턴이 바꾸지 않는다', () async {
      final session = create(title: '작업 #내 이름');
      await manager.sendPrompt(session.sessionId, '요청');
      backend.finishFirstTurn();
      await _settle();
      expect(session.title, '작업 #내 이름');

      final named = create(title: '내 이름');
      await manager.sendPrompt(named.sessionId, '요청');
      backend.finishFirstTurn();
      await _settle();
      expect(named.title, '내 이름');
    });

    test('이름을 짓는 동안 사용자가 이름을 바꾸거나 세션을 지우면 그대로 둔다', () async {
      final release = Completer<void>();
      gate = release.future;
      final session = create();
      backend.finishFirstTurn();
      await _settle();
      manager.updateSessionTitle(session.sessionId, '직접 정한 이름');
      release.complete();
      await _settle();
      expect(session.title, '직접 정한 이름');

      final second = Completer<void>();
      gate = second.future;
      backend = _FakeBackend();
      final removed = create();
      backend.finishFirstTurn();
      await _settle();
      await manager.deleteSession(removed.sessionId);
      second.complete();
      await _settle();
      expect(
        manager.groups!.snapshotsFor('g1').any((s) => s.id == removed.snapshotId),
        isFalse,
        reason: '지운 세션의 기록을 되살리지 않는다',
      );
    });

    test('이름을 못 지으면 첫 줄 이름을 유지하고 다시 시도하지 않는다', () async {
      reply = '  ';
      final session = create();
      await manager.sendPrompt(session.sessionId, '첫 줄 이름');
      backend.finishFirstTurn();
      await _settle();
      expect(session.title, '첫 줄 이름');
      expect(session.autoTitle, isFalse);
    });

    test('직접 턴을 돌리지 않은 상위 세션은 하위 세션의 이름을 받는다', () async {
      final parent = create();
      final childBackend = _FakeBackend();
      final child = manager.createSession(
        backendOverride: childBackend,
        workingDirectory: '/tmp',
        parentSessionId: parent.sessionId,
      );
      childBackend.finishFirstTurn();
      await _settle();
      expect(child.title, '로그인 오류 수정');
      expect(parent.title, '로그인 오류 수정');
    });

    test('일회용 백엔드를 끄면 첫 줄 이름만 쓴다', () async {
      final plain = SessionManager();
      addTearDown(plain.dispose);
      final own = _FakeBackend();
      final session = plain.createSession(
        backendOverride: own,
        workingDirectory: '/tmp',
      );
      await plain.sendPrompt(session.sessionId, '첫 줄 이름');
      own.finishFirstTurn();
      await _settle();
      expect(session.title, '첫 줄 이름');
    });
  });

  group('새 세션 대화상자', () {
    late Directory temp;
    late SessionManager manager;

    setUp(() {
      temp = Directory.systemTemp.createTempSync('acc_stage17_');
      manager = SessionManager(
        groups: WorkspaceGroupStore()
          ..upsert(
            WorkspaceGroup(
              id: 'g1',
              name: '그룹',
              folder: temp.path,
              backend: BackendType.codex,
              model: BackendType.codex.defaultModel,
              effort: BackendType.codex.defaultEffort,
            ),
          ),
      );
      manager.createSession(
        sessionId: 's1',
        backendOverride: _FakeBackend(),
        workingDirectory: temp.path,
      );
    });
    tearDown(() {
      manager.dispose();
      temp.deleteSync(recursive: true);
    });

    Future<void> openGroupDialog(WidgetTester tester, Size size) async {
      tester.view.physicalSize = size;
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
      await tester.tap(find.byKey(const ValueKey('new_session_in_group_g1')));
      await tester.pumpAndSettle();
    }

    Future<void> create(WidgetTester tester) async {
      await tester.ensureVisible(
        find.byKey(const ValueKey('create_session_button')),
      );
      await tester.tap(find.byKey(const ValueKey('create_session_button')));
      await tester.pumpAndSettle();
    }

    testWidgets('입력한 이름으로 그룹 세션을 만든다', (tester) async {
      await openGroupDialog(tester, const Size(1400, 1100));
      await tester.enterText(
        find.byKey(const ValueKey('new_session_title')),
        '  결제 작업 ',
      );
      await create(tester);
      final session = manager.activeSession!;
      expect(session.title, '결제 작업');
      expect(session.autoTitle, isFalse);
      expect(session.groupId, 'g1');
    });

    testWidgets('비워 두면 자동 이름 대상이 된다', (tester) async {
      await openGroupDialog(tester, const Size(1400, 1100));
      expect(find.textContaining('첫 대화를 보고 자동으로'), findsOneWidget);
      await create(tester);
      expect(manager.activeSession!.autoTitle, isTrue);
    });

    testWidgets('낮은 창에서도 대화상자가 넘치지 않는다', (tester) async {
      await openGroupDialog(tester, const Size(900, 420));
      expect(tester.takeException(), isNull);
      await create(tester);
      expect(manager.sessions, hasLength(2));
    });
  });
}
