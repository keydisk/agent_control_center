import 'dart:async';
import 'dart:io';

import 'package:agent_control_center/adapters/antigravity/antigravity_adapter.dart';
import 'package:agent_control_center/adapters/antigravity/antigravity_event_parser.dart';
import 'package:agent_control_center/core/backend/agent_backend.dart';
import 'package:agent_control_center/core/backend/local_hook_bridge.dart';
import 'package:agent_control_center/core/models/agent_models.dart';
import 'package:agent_control_center/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeManagedProcess implements ManagedProcess {
  final StreamController<String> stdoutController =
      StreamController<String>.broadcast();
  final StreamController<String> stderrController =
      StreamController<String>.broadcast();
  final Completer<int> exitCompleter = Completer<int>();
  final List<String> writtenLines = [];
  bool killed = false;

  @override
  Stream<String> get stdoutLines => stdoutController.stream;

  @override
  Stream<String> get stderrLines => stderrController.stream;

  @override
  Future<int> get exitCode => exitCompleter.future;

  @override
  void writeLine(String line) {
    writtenLines.add(line);
  }

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killed = true;
    if (!exitCompleter.isCompleted) {
      exitCompleter.complete(0);
    }
    return true;
  }
}

class FakeProcessSpawner implements ProcessSpawner {
  FakeManagedProcess lastProcess = FakeManagedProcess();
  String? lastExecutable;
  List<String> lastArgs = [];

  @override
  Future<ManagedProcess> spawn(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    lastExecutable = executable;
    lastArgs = arguments;
    return lastProcess;
  }

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    return ProcessResult(1, 0, '/usr/local/bin/$executable\n', '');
  }
}

void main() {
  group('1단계: AntigravityEventParser 단위 테스트 (실제 fixture 기반)', () {
    test('agy_stream_sample.jsonl 을 파싱하여 공통 도메인 이벤트를 생성한다', () async {
      final fixtureFile = File('test/fixtures/agy_stream_sample.jsonl');
      final lines = await fixtureFile.readAsLines();
      final parser = AntigravityEventParser(
        sessionId: 'sess_test',
        model: 'gemini-3.8-flash-high',
      );

      final allEvents = <AgentEvent>[];
      for (final line in lines) {
        allEvents.addAll(parser.parseLine(line));
      }

      expect(
        parser.conversationId,
        equals('7e93043f-31b5-4a0a-9b14-b3215454d01f'),
      );
      expect(allEvents.whereType<SkillInvokedEvent>().length, equals(1));
      expect(
        allEvents.whereType<SkillInvokedEvent>().first.skillName,
        equals('ego-browser'),
      );
      expect(allEvents.whereType<ToolCallEvent>().length, greaterThanOrEqualTo(2));
      expect(allEvents.whereType<FileDiffEvent>().length, equals(1));
      expect(
        allEvents.whereType<FileDiffEvent>().first.diff.filePath,
        equals('lib/app.dart'),
      );
      expect(allEvents.whereType<MessageEvent>().length, equals(2));
      expect(allEvents.whereType<DoneEvent>().length, equals(1));
      expect(
        allEvents.whereType<DoneEvent>().first.usage.totalTokens,
        equals(23335),
      );
    });
  });

  group('1단계: LocalHookBridgeServer + AntigravityAdapter 브리지 통합 테스트', () {
    test('훅 브리지로 승인 요청 수신 후 respondToApproval 호출 시 allow 응답을 반환한다', () async {
      final spawner = FakeProcessSpawner();
      final bridge = LocalHookBridgeServer();
      final adapter = AntigravityAdapter(spawner: spawner, hookBridge: bridge);

      await adapter.start(
        const AgentSessionConfig(
          sessionId: 'sess_bridge',
          backendType: BackendType.antigravity,
          workingDirectory: '/tmp',
        ),
      );

      final receivedEvents = <AgentEvent>[];
      final sub = adapter.events.listen(receivedEvents.add);

      // 비동기로 훅 페이로드 전송 후 어댑터에서 승인 응답
      final postFuture = bridge.handleHookPayload({
        'sessionId': 'sess_bridge',
        'backend': 'agy',
        'toolCall': {
          'name': 'run_command',
          'args': {'CommandLine': 'git status'},
        },
      });

      // ApprovalRequestEvent가 발행될 때까지 대기
      await Future<void>.delayed(const Duration(milliseconds: 30));
      final approvalEvents =
          receivedEvents.whereType<ApprovalRequestEvent>().toList();
      expect(approvalEvents.length, equals(1));

      final reqId = approvalEvents.first.request.id;
      await adapter.respondToApproval(
        ApprovalDecision(
          requestId: reqId,
          approved: true,
          scope: ApprovalScope.once,
        ),
      );

      final decoded = await postFuture;
      expect(decoded['decision'], equals('allow'));

      await sub.cancel();
      await adapter.dispose();
      await bridge.dispose();
    });
  });

  group('1단계: 단일 세션 GUI 위젯 테스트', () {
    testWidgets('타임라인에 메시지, 도구 호출 카드, 파일 Diff, 원본 로그 토글 및 슬래시 자동완성을 렌더링한다', (
      tester,
    ) async {
      final spawner = FakeProcessSpawner();
      final adapter = AntigravityAdapter(spawner: spawner);
      final now = DateTime.now();

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: ControlCenterHomeScreen(
              backendOverride: adapter,
              initialEvents: [
                MessageEvent(
                  id: 'm1',
                  sessionId: 's1',
                  backend: BackendType.antigravity,
                  model: 'gemini-3.8-flash-high',
                  timestamp: now,
                  role: 'assistant',
                  text: '안녕하세요!\n```dart\nfinal int x = 42;\n```',
                ),
                ToolCallEvent(
                  id: 't1',
                  sessionId: 's1',
                  backend: BackendType.antigravity,
                  model: 'gemini-3.8-flash-high',
                  timestamp: now,
                  toolName: 'run_command',
                  arguments: const {'CommandLine': 'flutter test'},
                  result: 'All tests passed!',
                  durationMs: 320,
                ),
                FileDiffEvent(
                  id: 'd1',
                  sessionId: 's1',
                  backend: BackendType.antigravity,
                  model: 'gemini-3.8-flash-high',
                  timestamp: now,
                  diff: const FileDiffItem(
                    filePath: 'lib/main.dart',
                    oldContent: 'int x = 1;',
                    newContent: 'final int x = 42;',
                  ),
                ),
              ],
              initialRawLogs: const ['{"event":"init"}'],
            ),
          ),
        ),
      );

      expect(find.text('에이전트 컨트롤 센터'), findsOneWidget);
      expect(find.text('run_command(flutter test)'), findsOneWidget);
      expect(find.text('파일 변경 Diff: lib/main.dart'), findsOneWidget);
      expect(find.byKey(const ValueKey('device_dropdown')), findsOneWidget);

      // 원본 로그 토글 확인
      await tester.tap(find.byKey(const ValueKey('raw_log_toggle')));
      await tester.pump();
      expect(find.text('원본 JSON 스트림 로그 (Raw Logs)'), findsOneWidget);
      expect(find.text('{"event":"init"}'), findsOneWidget);

      // 슬래시 명령 자동완성 확인
      await tester.enterText(
        find.byKey(const ValueKey('prompt_textfield')),
        '/pl',
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('slash_chip_/plan')), findsOneWidget);

      // "/"만 입력해도 레지스트리의 스킬 목록이 함께 표시됨
      await tester.enterText(
        find.byKey(const ValueKey('prompt_textfield')),
        '/',
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('slash_chip_/ego-browser')),
        findsOneWidget,
      );
    });
  });
}
