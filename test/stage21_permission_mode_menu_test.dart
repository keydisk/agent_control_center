import 'dart:async';

import 'package:agent_control_center/core/backend/agent_backend.dart';
import 'package:agent_control_center/core/models/agent_models.dart';
import 'package:agent_control_center/main.dart';
import 'package:agent_control_center/services/inbox_service.dart';
import 'package:agent_control_center/services/notification_service.dart';
import 'package:agent_control_center/services/permission_center.dart';
import 'package:agent_control_center/services/session_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeBackend implements AgentBackend {
  final eventCtrl = StreamController<AgentEvent>.broadcast();
  final rawLogCtrl = StreamController<String>.broadcast();

  @override
  BackendType get backendType => BackendType.claudeCode;
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
  Future<void> dispose() async {}
}

void main() {
  late SessionManager manager;

  setUp(() {
    manager = SessionManager(defaultPermissionMode: PermissionMode.auto);
    manager.createSession(
      sessionId: 's1',
      backendOverride: _FakeBackend(),
      workingDirectory: '/tmp',
    );
  });
  tearDown(() => manager.dispose());

  Future<void> pump(WidgetTester tester, Size size) async {
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
  }

  Future<void> tap(WidgetTester tester, String key) async {
    await tester.tap(find.byKey(ValueKey(key)));
    await tester.pumpAndSettle();
  }

  testWidgets('현재 모드를 표시하고 메뉴에 5가지 모드와 설명을 보여 준다', (tester) async {
    await pump(tester, const Size(1400, 1000));
    final button = find.byKey(const ValueKey('permission_mode_button'));
    expect(
      find.descendant(of: button, matching: find.text('자동')),
      findsOneWidget,
    );

    await tap(tester, 'permission_mode_button');
    for (final mode in PermissionMode.values) {
      expect(find.byKey(ValueKey('permission_mode_${mode.name}')), findsOneWidget);
      expect(find.text(mode.description), findsOneWidget);
    }
    expect(find.textContaining('파괴적인 작업만 묻고'), findsOneWidget);
    expect(find.byIcon(Icons.check), findsOneWidget);
  });

  testWidgets('다른 모드를 고르면 세션에 바로 반영한다', (tester) async {
    await pump(tester, const Size(1400, 1000));
    await tap(tester, 'permission_mode_button');
    await tap(tester, 'permission_mode_acceptEdits');
    expect(manager.activeSession!.permissionMode, PermissionMode.acceptEdits);
    expect(find.text('편집 자동 수락'), findsOneWidget);
  });

  testWidgets('권한 무시는 확인해야 켜지고 취소하면 그대로다', (tester) async {
    await pump(tester, const Size(1400, 1000));
    await tap(tester, 'permission_mode_button');
    await tap(tester, 'permission_mode_bypass');
    expect(find.byKey(const ValueKey('bypass_mode_dialog')), findsOneWidget);
    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();
    expect(manager.activeSession!.permissionMode, PermissionMode.auto);

    await tap(tester, 'permission_mode_button');
    await tap(tester, 'permission_mode_bypass');
    await tap(tester, 'confirm_bypass_mode_button');
    expect(manager.activeSession!.permissionMode, PermissionMode.bypass);
  });

  testWidgets('세션이 없으면 메뉴를 열 수 없고 좁은 창에서도 넘치지 않는다', (tester) async {
    await pump(tester, const Size(860, 700));
    expect(tester.takeException(), isNull);
    unawaited(manager.deleteSession('s1'));
    await tester.pump();
    final menu = tester.widget<PopupMenuButton<PermissionMode>>(
      find.byKey(const ValueKey('permission_mode_button')),
    );
    expect(menu.enabled, isFalse);
  });
}
