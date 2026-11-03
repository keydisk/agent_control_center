import 'dart:io';

import 'package:agent_control_center/adapters/antigravity/antigravity_adapter.dart';
import 'package:agent_control_center/adapters/claude/claude_code_adapter.dart';
import 'package:agent_control_center/adapters/codex/codex_adapter.dart';
import 'package:agent_control_center/core/backend/agent_backend.dart';
import 'package:agent_control_center/core/models/agent_models.dart';
import 'package:agent_control_center/services/session_manager.dart';
import 'package:agent_control_center/ui/widgets/prompt_input_bar.dart';
import 'package:agent_control_center/ui/widgets/session_dialogs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'stage1_antigravity_test.dart' show FakeProcessSpawner;
import 'stage4_multi_session_test.dart' show FakeAgentBackend;

AgentSessionConfig _config(BackendType backend, ReasoningEffort effort) =>
    AgentSessionConfig(
      sessionId: 's',
      backendType: backend,
      workingDirectory: '/tmp',
      effort: effort,
    );

void main() {
  group('CLI 인자', () {
    test('Claude와 Antigravity는 --effort로 전달하고 기본값은 생략한다', () async {
      for (final build in [
        (FakeProcessSpawner s) => ClaudeCodeAdapter(spawner: s),
        (FakeProcessSpawner s) => AntigravityAdapter(spawner: s),
      ]) {
        final spawner = FakeProcessSpawner();
        final adapter = build(spawner);
        addTearDown(adapter.dispose);
        await adapter.start(_config(adapter.backendType, ReasoningEffort.xhigh));
        final i = spawner.lastArgs.indexOf('--effort');
        expect(spawner.lastArgs[i + 1], 'xhigh');

        final plain = FakeProcessSpawner();
        final plainAdapter = build(plain);
        addTearDown(plainAdapter.dispose);
        await plainAdapter.start(
          _config(plainAdapter.backendType, ReasoningEffort.auto),
        );
        expect(plain.lastArgs, isNot(contains('--effort')));
      }
    });

    test('Codex는 model_reasoning_effort 설정으로 전달한다', () async {
      final spawner = FakeProcessSpawner();
      final adapter = CodexAdapter(spawner: spawner);
      addTearDown(adapter.dispose);
      await adapter.start(_config(BackendType.codex, ReasoningEffort.high));
      await adapter.send('요청');
      final i = spawner.lastArgs.indexOf('-c');
      expect(spawner.lastArgs[i + 1], 'model_reasoning_effort="high"');

      final plain = FakeProcessSpawner();
      final plainAdapter = CodexAdapter(spawner: plain);
      addTearDown(plainAdapter.dispose);
      await plainAdapter.start(_config(BackendType.codex, ReasoningEffort.auto));
      await plainAdapter.send('요청');
      expect(plain.lastArgs, isNot(contains('-c')));
    });
  });

  group('세션', () {
    test('강도를 바꾸면 대화를 이어서 다음 실행에 반영한다', () async {
      final backend = FakeAgentBackend(BackendType.claudeCode);
      final manager = SessionManager();
      addTearDown(manager.dispose);
      final session = manager.createSession(
        backendOverride: backend,
        workingDirectory: '/tmp',
      );
      await manager.sendPrompt(session.sessionId, '첫 요청');
      expect(backend.lastConfig!.effort, ReasoningEffort.auto);

      manager.updateSessionEffort(session.sessionId, ReasoningEffort.max);
      await manager.sendPrompt(session.sessionId, '다음 요청');
      expect(backend.lastConfig!.effort, ReasoningEffort.max);
      expect(backend.lastConfig!.conversationId, 'fake_conv_id');
    });

    test('같은 강도로 다시 설정하면 프로세스를 재시작하지 않는다', () async {
      final manager = SessionManager();
      addTearDown(manager.dispose);
      final session = manager.createSession(
        backendOverride: FakeAgentBackend(BackendType.claudeCode),
        workingDirectory: '/tmp',
      );
      await manager.sendPrompt(session.sessionId, '요청');
      manager.updateSessionEffort(session.sessionId, ReasoningEffort.auto);
      expect(session.isStarted, isTrue);
    });
  });

  group('UI', () {
    testWidgets('입력창에서 추론 강도를 고른다', (tester) async {
      ReasoningEffort? picked;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PromptInputBar(
              selectedBackend: BackendType.claudeCode,
              selectedModel: BackendType.claudeCode.defaultModel,
              workingDirectory: '/tmp',
              onBackendChanged: (_) {},
              onModelChanged: (_) {},
              onWorkingDirectoryChanged: (_) {},
              onSubmit: (_, _) {},
              onEffortChanged: (e) => picked = e,
            ),
          ),
        ),
      );
      expect(find.text('추론 기본'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('effort_dropdown')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('최대').last);
      await tester.pumpAndSettle();
      expect(picked, ReasoningEffort.max);
    });

    testWidgets('새 세션에서 모델과 추론 강도를 고른다', (tester) async {
      final dir = Directory.systemTemp.createTempSync('acc_effort_');
      addTearDown(() => dir.deleteSync());
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      NewSessionRequest? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await showDialog<NewSessionRequest>(
                  context: context,
                  builder: (_) => NewSessionDialog(
                    initialBackend: BackendType.claudeCode,
                    initialFolder: dir.path,
                  ),
                );
              },
              child: const Text('열기'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('열기'));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('session_model_claude')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('claude-opus-5-5').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('session_effort')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('높음').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('create_session_button')));
      await tester.pumpAndSettle();

      expect(result!.model, 'claude-opus-5-5');
      expect(result!.effort, ReasoningEffort.high);
    });

    testWidgets('실행 중에는 환경 설정의 강도를 바꿀 수 없다', (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final session = ManagedSession(
        sessionId: 's',
        title: '작업',
        backendType: BackendType.claudeCode,
        model: BackendType.claudeCode.defaultModel,
        workingDirectory: '/tmp',
        backend: FakeAgentBackend(BackendType.claudeCode),
        status: SessionStatus.running,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SessionSettingsDialog(session: session)),
        ),
      );
      final field = tester.widget<DropdownButtonFormField<ReasoningEffort>>(
        find.byKey(const ValueKey('session_effort')),
      );
      expect(field.onChanged, isNull);
    });
  });
}
