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
import 'package:flutter/services.dart';
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
    test('Claude는 --effort로 전달하고 기본값은 생략한다', () async {
      final spawner = FakeProcessSpawner();
      final adapter = ClaudeCodeAdapter(spawner: spawner);
      addTearDown(adapter.dispose);
      await adapter.start(_config(BackendType.claudeCode, ReasoningEffort.xhigh));
      final i = spawner.lastArgs.indexOf('--effort');
      expect(spawner.lastArgs[i + 1], 'xhigh');

      final plain = FakeProcessSpawner();
      final plainAdapter = ClaudeCodeAdapter(spawner: plain);
      addTearDown(plainAdapter.dispose);
      await plainAdapter.start(
        _config(BackendType.claudeCode, ReasoningEffort.auto),
      );
      expect(plain.lastArgs, isNot(contains('--effort')));
    });

    test('Antigravity는 모델 이름과 강도를 합친 ID만 전달한다', () async {
      final spawner = FakeProcessSpawner();
      final adapter = AntigravityAdapter(spawner: spawner);
      addTearDown(adapter.dispose);
      await adapter.start(
        const AgentSessionConfig(
          sessionId: 's',
          backendType: BackendType.antigravity,
          workingDirectory: '/tmp',
          model: 'gemini-4-argon',
          effort: ReasoningEffort.low,
        ),
      );
      final i = spawner.lastArgs.indexOf('--model');
      expect(spawner.lastArgs[i + 1], 'gemini-4-argon-low');
      expect(spawner.lastArgs, isNot(contains('--effort')));
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
        backendType: BackendType.claudeCode,
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
        backendType: BackendType.claudeCode,
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
      await tester.tap(find.byKey(const ValueKey('session_effort_claude')));
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
        find.byKey(const ValueKey('session_effort_claude')),
      );
      expect(field.onChanged, isNull);
    });

    testWidgets('Antigravity 입력창은 강도 없는 모델과 3단계 강도만 보여 준다', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PromptInputBar(
              selectedBackend: BackendType.antigravity,
              selectedModel: BackendType.antigravity.defaultModel,
              workingDirectory: '/tmp',
              onBackendChanged: (_) {},
              onModelChanged: (_) {},
              onWorkingDirectoryChanged: (_) {},
              onSubmit: (_, _) {},
            ),
          ),
        ),
      );
      expect(find.text('추론 높음'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('model_dropdown')));
      await tester.pumpAndSettle();
      expect(find.textContaining('flash-high'), findsNothing);
      await tester.tap(find.text('gemini-4-argon').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('effort_dropdown')));
      await tester.pumpAndSettle();
      expect(find.text('낮음'), findsWidgets);
      expect(find.text('최대'), findsNothing);
      expect(find.text('기본'), findsNothing);
    });
  });

  group('모델·강도 분리', () {
    test('모델 ID를 조합하고 목록 밖 모델은 그대로 둔다', () {
      const agy = BackendType.antigravity;
      expect(agy.cliModel('gemini-3.8-flash', ReasoningEffort.medium), 'gemini-3.8-flash-medium');
      expect(agy.cliModel('gemini-3.8-flash', ReasoningEffort.auto), 'gemini-3.8-flash-high');
      expect(agy.cliModel('gemini-3.8-flash-low', ReasoningEffort.auto), 'gemini-3.8-flash-low');
      expect(agy.cliModel('gemini-3.8-flash-low', ReasoningEffort.high), 'gemini-3.8-flash-high');
      expect(agy.cliModel('gemini-3-flash', ReasoningEffort.high), 'gemini-3-flash');
      expect(agy.cliModel('gemini-4-argon', ReasoningEffort.max), 'gemini-4-argon-high');
      expect(BackendType.claudeCode.cliModel('opus', ReasoningEffort.max), 'opus');
    });

    test('강도가 붙은 모델로 세션을 만들면 모델과 강도로 나눈다', () {
      final manager = SessionManager();
      addTearDown(manager.dispose);
      final session = manager.createSession(
        backendOverride: FakeAgentBackend(BackendType.antigravity),
        model: 'gemini-3.8-flash-medium',
        workingDirectory: '/tmp',
      );
      expect(session.model, 'gemini-3.8-flash');
      expect(session.effort, ReasoningEffort.medium);
      expect(session.modelLabel, 'gemini-3.8-flash · 중간');
    });

    test('백엔드를 바꾸면 그 백엔드의 기본 강도로 돌아간다', () {
      final manager = SessionManager();
      addTearDown(manager.dispose);
      final session = manager.createSession(
        backendOverride: FakeAgentBackend(BackendType.antigravity),
        workingDirectory: '/tmp',
      );
      expect(session.effort, ReasoningEffort.high);
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
      expect(session.effort, ReasoningEffort.high);
      manager.updateSessionEffort(session.sessionId, ReasoningEffort.max);
      expect(session.effort, ReasoningEffort.high);
    });
  });

  group('Cmd+Enter 전송', () {
    Future<List<String>> pumpBar(WidgetTester tester, {bool busy = false}) async {
      final sent = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PromptInputBar(
              selectedBackend: BackendType.claudeCode,
              selectedModel: BackendType.claudeCode.defaultModel,
              workingDirectory: '/tmp',
              isBusy: busy,
              onInterrupt: () {},
              onBackendChanged: (_) {},
              onModelChanged: (_) {},
              onWorkingDirectoryChanged: (_) {},
              onSubmit: (prompt, _) => sent.add(prompt),
              skills: const [],
            ),
          ),
        ),
      );
      return sent;
    }

    Future<void> pressShortcut(WidgetTester tester) async {
      final modifier = Platform.isMacOS
          ? LogicalKeyboardKey.metaLeft
          : LogicalKeyboardKey.controlLeft;
      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(modifier);
      await tester.pump();
    }

    Finder field() => find.byKey(const ValueKey('prompt_textfield'));

    testWidgets('단축키로 전송하고 입력창을 비운다', (tester) async {
      final sent = await pumpBar(tester);
      await tester.enterText(field(), '작업 요청');
      await pressShortcut(tester);
      expect(sent, ['작업 요청']);
      expect(tester.widget<TextField>(field()).controller!.text, isEmpty);
    });

    testWidgets('Enter만 누르면 전송하지 않는다', (tester) async {
      final sent = await pumpBar(tester);
      await tester.enterText(field(), '작업 요청');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(sent, isEmpty);
    });

    testWidgets('실행 중에는 전송하지 않고 입력을 유지한다', (tester) async {
      final sent = await pumpBar(tester, busy: true);
      await tester.enterText(field(), '다음 요청');
      await pressShortcut(tester);
      expect(sent, isEmpty);
      expect(tester.widget<TextField>(field()).controller!.text, '다음 요청');
    });

    testWidgets('자동완성이 열려 있어도 단축키는 입력 내용을 전송한다', (tester) async {
      final sent = await pumpBar(tester);
      await tester.enterText(field(), '/comp');
      await tester.pump();
      await pressShortcut(tester);
      expect(sent, ['/comp']);
    });
  });
}
