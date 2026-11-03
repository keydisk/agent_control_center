import 'dart:io';

import 'package:agent_control_center/core/models/agent_models.dart';
import 'package:agent_control_center/services/model_preference_store.dart';
import 'package:agent_control_center/services/session_manager.dart';
import 'package:agent_control_center/ui/widgets/session_dialogs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'stage4_multi_session_test.dart' show FakeAgentBackend;

void main() {
  test('모델 선택은 백엔드별로 저장되고 다시 읽힌다', () {
    final dir = Directory.systemTemp.createTempSync('acc_models_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/nested/models.json');
    final manager = SessionManager(
      modelPreferences: ModelPreferenceStore(file: file),
    );
    addTearDown(manager.dispose);
    final session = manager.createSession(
      backendType: BackendType.claudeCode,
      backendOverride: FakeAgentBackend(BackendType.claudeCode),
    );
    manager.updateSessionModel(session.sessionId, 'claude-opus-5-5');
    manager.updateSessionBackend(
      session.sessionId,
      BackendType.codex,
      replaceAdapter: false,
    );
    manager.updateSessionModel(session.sessionId, 'gpt-6-astra');
    manager.updateSessionBackend(
      session.sessionId,
      BackendType.claudeCode,
      replaceAdapter: false,
    );
    expect(session.model, 'claude-opus-5-5');

    final restarted = SessionManager(
      modelPreferences: ModelPreferenceStore(file: file),
    );
    addTearDown(restarted.dispose);
    expect(
      restarted.modelPreferences!.modelFor(BackendType.codex),
      'gpt-6-astra',
    );
    expect(
      restarted
          .createSession(
            backendType: BackendType.claudeCode,
            backendOverride: FakeAgentBackend(BackendType.claudeCode),
          )
          .model,
      'claude-opus-5-5',
    );
  });

  test('저장된 모델이 더는 제공되지 않으면 기본 모델을 쓴다', () {
    final dir = Directory.systemTemp.createTempSync('acc_models_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/models.json')
      ..writeAsStringSync('{"claude":"old-model"}');
    expect(
      ModelPreferenceStore(file: file).modelFor(BackendType.claudeCode),
      BackendType.claudeCode.defaultModel,
    );
  });

  testWidgets('새 세션 창에서 백엔드를 바꾸면 저장된 모델을 보여 준다', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = ModelPreferenceStore()
      ..remember(BackendType.codex, 'gpt-6-astra');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NewSessionDialog(
            initialBackend: BackendType.claudeCode,
            initialFolder: Directory.systemTemp.path,
            modelPreferences: store,
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const ValueKey('new_session_backend')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(BackendType.codex.displayName).last);
    await tester.pumpAndSettle();
    expect(find.text('gpt-6-astra'), findsOneWidget);
  });
}
