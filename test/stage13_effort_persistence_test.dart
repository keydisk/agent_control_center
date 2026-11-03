import 'dart:io';

import 'package:agent_control_center/core/models/agent_models.dart';
import 'package:agent_control_center/services/effort_preference_store.dart';
import 'package:agent_control_center/services/session_manager.dart';
import 'package:agent_control_center/ui/widgets/session_dialogs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'stage4_multi_session_test.dart' show FakeAgentBackend;

void main() {
  late Directory dir;
  late File file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('acc_effort_pref_');
    file = File('${dir.path}/nested/efforts.json');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  ManagedSession create(SessionManager manager, BackendType backend) =>
      manager.createSession(
        backendType: backend,
        backendOverride: FakeAgentBackend(backend),
        workingDirectory: '/tmp',
      );

  test('고른 강도는 앱을 다시 켠 뒤의 새 세션에도 유지된다', () {
    final first = SessionManager(
      effortPreferences: EffortPreferenceStore(file: file),
    );
    addTearDown(first.dispose);
    final session = create(first, BackendType.claudeCode);
    first.updateSessionEffort(session.sessionId, ReasoningEffort.max);

    final restarted = SessionManager(
      effortPreferences: EffortPreferenceStore(file: file),
    );
    addTearDown(restarted.dispose);
    expect(
      create(restarted, BackendType.claudeCode).effort,
      ReasoningEffort.max,
    );
    expect(create(restarted, BackendType.codex).effort, ReasoningEffort.auto);
  });

  test('백엔드를 바꿨다 돌아와도 그 백엔드의 강도가 유지된다', () {
    final manager = SessionManager(
      effortPreferences: EffortPreferenceStore(file: file),
    );
    addTearDown(manager.dispose);
    final session = create(manager, BackendType.antigravity);
    manager.updateSessionEffort(session.sessionId, ReasoningEffort.low);

    manager.updateSessionBackend(
      session.sessionId,
      BackendType.claudeCode,
      replaceAdapter: false,
    );
    expect(session.effort, ReasoningEffort.auto);
    manager.updateSessionBackend(
      session.sessionId,
      BackendType.antigravity,
      replaceAdapter: false,
    );
    expect(session.effort, ReasoningEffort.low);
  });

  test('지원하지 않는 강도는 기억하지 않는다', () {
    final store = EffortPreferenceStore(file: file);
    final manager = SessionManager(effortPreferences: store);
    addTearDown(manager.dispose);
    final session = create(manager, BackendType.antigravity);
    manager.updateSessionEffort(session.sessionId, ReasoningEffort.max);
    expect(store.effortFor(BackendType.antigravity), isNull);
  });

  test('손상되었거나 지원하지 않는 저장값은 무시한다', () {
    file.parent.createSync(recursive: true);
    for (final content in ['{깨짐', '[1]', '{"agy":"max","codex":3}']) {
      file.writeAsStringSync(content);
      final store = EffortPreferenceStore(file: file);
      for (final backend in BackendType.values) {
        expect(store.effortFor(backend), isNull, reason: content);
      }
    }
  });

  testWidgets('새 세션 창에서 백엔드를 바꾸면 기억한 강도를 보여 준다', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = EffortPreferenceStore()
      ..remember(BackendType.codex, ReasoningEffort.xhigh);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NewSessionDialog(
            initialBackend: BackendType.claudeCode,
            initialFolder: dir.path,
            effortPreferences: store,
          ),
        ),
      ),
    );
    expect(find.text('XHigh'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('new_session_backend')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(BackendType.codex.displayName).last);
    await tester.pumpAndSettle();
    expect(find.text('XHigh'), findsOneWidget);
  });
}
