import 'dart:convert';

import 'package:agent_control_center/adapters/claude/claude_code_adapter.dart';
import 'package:agent_control_center/adapters/claude/claude_code_event_parser.dart';
import 'package:agent_control_center/core/backend/agent_backend.dart';
import 'package:agent_control_center/core/models/agent_models.dart';
import 'package:agent_control_center/main.dart';
import 'package:agent_control_center/services/session_manager.dart';
import 'package:agent_control_center/ui/widgets/timeline_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'stage1_antigravity_test.dart' show FakeProcessSpawner;
import 'stage4_multi_session_test.dart' show FakeAgentBackend;

ToolCallEvent _tool({bool running = true, Map<String, dynamic>? args}) =>
    ToolCallEvent(
      id: 't1',
      sessionId: 's',
      backend: BackendType.claudeCode,
      timestamp: DateTime(2026),
      toolName: 'Bash',
      arguments: args ?? const {'command': 'git status\nextra'},
      isRunning: running,
    );

void main() {
  group('정지', () {
    test('중지 후 다음 프롬프트는 같은 대화를 새 프로세스로 재개한다', () async {
      final backend = FakeAgentBackend(BackendType.claudeCode);
      final manager = SessionManager();
      addTearDown(manager.dispose);
      final session = manager.createSession(
        backendOverride: backend,
        workingDirectory: '/tmp',
      );
      await manager.sendPrompt(session.sessionId, '첫 요청');
      backend.lastConfig = null;

      await manager.stopSession(session.sessionId);
      expect(session.status, SessionStatus.stopped);
      expect(backend.interrupted, isTrue);

      await manager.sendPrompt(session.sessionId, '이어서');
      expect(backend.lastConfig!.conversationId, 'fake_conv_id');
      expect(session.status, SessionStatus.running);
    });

    test('중지하면 실행 중 도구와 대기 요청을 정리하고 표시를 남긴다', () async {
      final manager = SessionManager();
      addTearDown(manager.dispose);
      final request = ApprovalRequestData(
        id: 'req',
        sessionId: 's',
        backend: BackendType.claudeCode,
        toolName: 'Bash',
        arguments: const {},
        category: ApprovalCategory.shellCommand,
        reason: '',
        isDestructive: false,
        createdAt: DateTime(2026),
      );
      final session = manager.createSession(
        backendOverride: FakeAgentBackend(BackendType.claudeCode),
        workingDirectory: '/tmp',
        initialEvents: [
          _tool(),
          ApprovalRequestEvent(request: request),
        ],
      );
      await manager.sendPrompt(session.sessionId, '요청');

      await manager.stopSession(session.sessionId);

      final tool = session.events.first as ToolCallEvent;
      expect(tool.isRunning, isFalse);
      expect(tool.result, '중지됨');
      expect(session.resolvedRequestIds, contains('req'));
      expect(
        (session.events.last as DoneEvent).stopReason,
        DoneEvent.interrupted,
      );
    });

    test('유휴 세션 중지는 중지 표시를 남기지 않는다', () async {
      final manager = SessionManager();
      addTearDown(manager.dispose);
      final session = manager.createSession(
        backendOverride: FakeAgentBackend(BackendType.claudeCode),
        workingDirectory: '/tmp',
      );
      await manager.stopSession(session.sessionId);
      expect(session.events, isEmpty);
    });

    test('어댑터 중지는 프로세스를 끝내고 이후 출력을 무시한다', () async {
      final spawner = FakeProcessSpawner();
      final adapter = ClaudeCodeAdapter(spawner: spawner);
      addTearDown(adapter.dispose);
      await adapter.start(
        const AgentSessionConfig(
          sessionId: 's',
          backendType: BackendType.claudeCode,
          workingDirectory: '/tmp',
        ),
      );
      expect(spawner.lastArgs, contains('--include-partial-messages'));
      final process = spawner.lastProcess;

      await adapter.interrupt();

      expect(process.killed, isTrue);
      await expectLater(adapter.send('다시'), throwsStateError);
    });
  });

  group('실시간 진행', () {
    String streamLine(Map<String, dynamic> event) =>
        jsonEncode({'type': 'stream_event', 'event': event});

    test('델타를 메시지로 내보내고 최종본은 중복 추가하지 않는다', () {
      final parser = ClaudeCodeEventParser(sessionId: 's');
      parser.parseLine(
        streamLine({
          'type': 'message_start',
          'message': {'id': 'msg1'},
        }),
      );
      final thinking =
          parser
                  .parseLine(
                    streamLine({
                      'type': 'content_block_delta',
                      'delta': {'type': 'thinking_delta', 'thinking': '음'},
                    }),
                  )
                  .single
              as MessageEvent;
      final text =
          parser
                  .parseLine(
                    streamLine({
                      'type': 'content_block_delta',
                      'delta': {'type': 'text_delta', 'text': '안녕'},
                    }),
                  )
                  .single
              as MessageEvent;
      expect(thinking.id, 'msg1');
      expect(thinking.thinking, '음');
      expect(text.isDelta, isTrue);
      expect(text.text, '안녕');

      final finalEvents = parser.parseLine(
        jsonEncode({
          'type': 'assistant',
          'message': {
            'id': 'msg1',
            'content': [
              {'type': 'text', 'text': '안녕'},
              {'type': 'tool_use', 'id': 't', 'name': 'Bash', 'input': {}},
            ],
          },
        }),
      );
      expect(finalEvents.whereType<MessageEvent>(), isEmpty);
      expect(finalEvents.whereType<ToolCallEvent>(), hasLength(1));
    });

    test('블록 배열로 온 도구 결과를 텍스트로 변환한다', () {
      final parser = ClaudeCodeEventParser(sessionId: 's');
      parser.parseLine(
        jsonEncode({
          'type': 'assistant',
          'message': {
            'id': 'm',
            'content': [
              {'type': 'tool_use', 'id': 't', 'name': 'Bash', 'input': {}},
            ],
          },
        }),
      );
      final result =
          parser
                  .parseLine(
                    jsonEncode({
                      'type': 'user',
                      'message': {
                        'content': [
                          {
                            'type': 'tool_result',
                            'tool_use_id': 't',
                            'content': [
                              {'type': 'text', 'text': '출력'},
                            ],
                          },
                        ],
                      },
                    }),
                  )
                  .single
              as ToolCallEvent;
      expect(result.result, '출력');
    });

    test('도구 호출을 CLI처럼 한 줄로 요약한다', () {
      expect(_tool().displayLine, 'Bash(git status)');
      expect(_tool(args: const {}).displayLine, 'Bash');
      expect(_tool(args: const {'CommandLine': 'ls'}).displayLine, 'Bash(ls)');
      expect(
        _tool(args: {'command': 'a' * 100}).displayLine,
        'Bash(${'a' * 80}…)',
      );
    });

    test('현재 활동을 이벤트에서 판단한다', () {
      expect(
        describeAgentActivity(const [], awaitingApproval: true),
        '승인 대기 중',
      );
      expect(describeAgentActivity(const [], awaitingApproval: false), '생각 중');
      expect(
        describeAgentActivity([_tool()], awaitingApproval: false),
        'Bash(git status) 실행 중',
      );
      expect(
        describeAgentActivity([
          _tool(),
          DoneEvent(
            id: 'd',
            sessionId: 's',
            backend: BackendType.claudeCode,
            timestamp: DateTime(2026),
          ),
        ], awaitingApproval: false),
        '생각 중',
      );
      expect(
        describeAgentActivity([
          MessageEvent(
            id: 'm',
            sessionId: 's',
            backend: BackendType.claudeCode,
            timestamp: DateTime(2026),
            role: 'assistant',
            text: '작성',
          ),
        ], awaitingApproval: false),
        '응답 작성 중',
      );
    });
  });

  group('화면', () {
    Future<(SessionManager, FakeAgentBackend)> pumpHome(
      WidgetTester tester,
    ) async {
      final backend = FakeAgentBackend(BackendType.claudeCode);
      final manager = SessionManager();
      addTearDown(manager.dispose);
      manager.createSession(
        backendOverride: backend,
        backendType: BackendType.claudeCode,
        workingDirectory: '/tmp',
      );
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: ControlCenterHomeScreen(sessionManagerOverride: manager),
          ),
        ),
      );
      return (manager, backend);
    }

    testWidgets('실행 중 상태 줄을 표시하고 Esc로 중지한다', (tester) async {
      final (manager, backend) = await pumpHome(tester);
      final id = manager.activeSessionId!;
      expect(find.byKey(const ValueKey('agent_activity_bar')), findsNothing);

      await manager.sendPrompt(id, '요청');
      await tester.pump();
      expect(find.textContaining('생각 중… (0s · Esc 중지)'), findsOneWidget);
      expect(find.byKey(const ValueKey('interrupt_button')), findsOneWidget);

      await tester.pump(const Duration(seconds: 1));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(backend.interrupted, isTrue);
      expect(manager.activeSession!.status, SessionStatus.stopped);
      expect(find.byKey(const ValueKey('agent_activity_bar')), findsNothing);
      expect(find.textContaining('사용자가 중지했습니다'), findsOneWidget);
    });

    testWidgets('긴 타임라인은 맨 아래를 따라가고 위로 스크롤하면 멈춘다', (tester) async {
      final (manager, backend) = await pumpHome(tester);
      final id = manager.activeSessionId!;
      await manager.sendPrompt(id, '요청');
      await tester.pump();
      MessageEvent message(int i) => MessageEvent(
        id: 'm$i',
        sessionId: id,
        backend: BackendType.claudeCode,
        timestamp: DateTime(2026),
        role: 'assistant',
        text: '메시지 $i',
      );
      for (var i = 0; i < 40; i++) {
        backend.eventCtrl.add(message(i));
      }
      await tester.pump();
      await tester.pump();
      final scrollable = find.byType(Scrollable).first;
      final position = tester.state<ScrollableState>(scrollable).position;
      expect(position.pixels, position.maxScrollExtent);

      position.jumpTo(0);
      backend.eventCtrl.add(message(40));
      await tester.pump();
      await tester.pump();
      expect(position.pixels, 0);
    });
  });
}
