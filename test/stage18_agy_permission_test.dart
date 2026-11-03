import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:agent_control_center/adapters/antigravity/antigravity_adapter.dart';
import 'package:agent_control_center/adapters/antigravity/antigravity_event_parser.dart';
import 'package:agent_control_center/core/backend/agent_backend.dart';
import 'package:agent_control_center/core/backend/local_hook_bridge.dart';
import 'package:agent_control_center/core/models/agent_models.dart';
import 'package:flutter_test/flutter_test.dart';

const _conversation = '3b3c0582';

/// 실제 agy 1.4.12 헤드리스 출력과 같은 형식의 자동 거부 단계
String _deniedStep(int index, String command) => jsonEncode({
  'event': 'step_update',
  'step_update': {
    'conversation_id': _conversation,
    'step_index': index,
    'state': 'ERROR',
    'step_type': 'tool',
    'tool_name': 'run_command',
    'tool_info': {
      'name': 'run_command',
      'parameters': {'CommandLine': command},
      'error': {
        'type': 'TOOL_ERROR',
        'message':
            'permission check failed for unsandboxed "$command": '
            'user denied permission to run command:\n$command',
      },
    },
  },
});

String _result({List<Object> denied = const [], int tokens = 10}) => jsonEncode({
  'event': 'result',
  'result': {
    'conversation_id': _conversation,
    'status': 'SUCCESS',
    'response': '',
    'usage': {'input_tokens': tokens, 'total_tokens': tokens},
    'denied_actions': denied,
  },
});

const _deniedAction = {'action': 'command', 'display_name': 'RunCommand'};

class _Process implements ManagedProcess {
  final stdoutCtrl = StreamController<String>.broadcast(sync: true);
  final stderrCtrl = StreamController<String>.broadcast();
  final written = <String>[];
  bool killed = false;

  @override
  Stream<String> get stdoutLines => stdoutCtrl.stream;
  @override
  Stream<String> get stderrLines => stderrCtrl.stream;
  @override
  Future<int> get exitCode async => 0;
  @override
  void writeLine(String line) => written.add(line);
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => killed = true;
}

class _Spawner implements ProcessSpawner {
  final processes = <_Process>[];
  final arguments = <List<String>>[];

  @override
  Future<ManagedProcess> spawn(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    this.arguments.add(arguments);
    final process = _Process();
    processes.add(process);
    return process;
  }

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async => ProcessResult(0, 0, '', '');
}

ApprovalDecision _decision(String id, {required bool approved}) =>
    ApprovalDecision(
      requestId: id,
      approved: approved,
      scope: approved ? ApprovalScope.once : ApprovalScope.denied,
    );

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  group('파서', () {
    late AntigravityEventParser parser;
    setUp(() => parser = AntigravityEventParser(sessionId: 's', model: 'm'));

    test('자동 거부된 명령은 실제 사유를 표시하고 승인을 요청한다', () {
      final events = parser.parseLine(_deniedStep(2, 'find lib'));
      final tool = events.whereType<ToolCallEvent>().single;
      expect(tool.isError, isTrue);
      expect(tool.result, contains('permission check failed'));
      final approval = events.whereType<ApprovalRequestEvent>().single;
      expect(approval.request.id, 'agy_denied_2');
      expect(approval.request.arguments['CommandLine'], 'find lib');

      final done = parser.parseLine(_result(denied: [_deniedAction]));
      expect(done.whereType<MessageEvent>(), isEmpty, reason: '승인창으로 이미 알렸다');
      expect(done.whereType<DoneEvent>(), hasLength(1));
    });

    test('다른 오류는 사유만 표시하고 승인을 요청하지 않는다', () {
      final events = parser.parseLine(
        jsonEncode({
          'event': 'step_update',
          'step_update': {
            'step_index': 3,
            'state': 'ERROR',
            'step_type': 'tool',
            'tool_name': 'run_command',
            'tool_info': {
              'name': 'run_command',
              'parameters': {'CommandLine': 'false'},
              'error': 'exit status 1',
            },
          },
        }),
      );
      expect(events.whereType<ToolCallEvent>().single.result, 'exit status 1');
      expect(events.whereType<ApprovalRequestEvent>(), isEmpty);
    });

    test('승인할 수 없는 거부로 끝나면 이유를 메시지로 알린다', () {
      final events = parser.parseLine(_result(denied: [_deniedAction]));
      final message = events.whereType<MessageEvent>().single;
      expect(message.role, 'system');
      expect(message.text, contains('RunCommand'));

      // 다음 턴의 판단에 앞선 턴의 승인 요청이 남지 않는다.
      parser.parseLine(_deniedStep(4, 'find lib'));
      parser.parseLine(_result(denied: [_deniedAction]));
      expect(
        parser
            .parseLine(_result(denied: [_deniedAction]))
            .whereType<MessageEvent>(),
        hasLength(1),
      );
    });

    test('거부가 없으면 메시지를 더하지 않는다', () {
      expect(parser.parseLine(_result()).whereType<MessageEvent>(), isEmpty);
    });
  });

  group('어댑터', () {
    late _Spawner spawner;
    late LocalHookBridgeServer bridge;
    late AntigravityAdapter adapter;
    late List<AgentEvent> events;

    setUp(() async {
      spawner = _Spawner();
      bridge = LocalHookBridgeServer();
      adapter = AntigravityAdapter(spawner: spawner, hookBridge: bridge);
      events = [];
      adapter.events.listen(events.add);
      await adapter.start(
        AgentSessionConfig(
          sessionId: 's',
          backendType: BackendType.antigravity,
          workingDirectory: '/tmp',
          model: BackendType.antigravity.defaultModel,
          effort: ReasoningEffort.high,
        ),
      );
    });
    tearDown(() async {
      await adapter.dispose();
      await bridge.dispose();
    });

    void emit(String line, {int process = 0}) =>
        spawner.processes[process].stdoutCtrl.add(line);

    test('승인하면 허용 규칙으로 같은 대화를 잇고 토큰을 합산한다', () async {
      emit(_deniedStep(2, 'find lib'));
      emit(_result(denied: [_deniedAction], tokens: 10));
      await _settle();
      expect(events.whereType<DoneEvent>(), isEmpty, reason: '답을 기다리는 동안 턴을 끝내지 않는다');
      expect(spawner.processes, hasLength(1));

      await adapter.respondToApproval(_decision('agy_denied_2', approved: true));
      await _settle();

      expect(spawner.processes, hasLength(2));
      expect(spawner.processes.first.killed, isTrue);
      final args = spawner.arguments.last;
      expect(args[args.indexOf('--conversation') + 1], _conversation);
      expect(
        jsonDecode(args[args.indexOf('--settings') + 1]),
        {
          'permissions': {
            'allow': ['command(find lib)'],
          },
        },
      );
      expect(
        args[args.indexOf('--model') + 1],
        BackendType.antigravity.cliModel(
          BackendType.antigravity.defaultModel,
          ReasoningEffort.high,
        ),
        reason: '강도 유지',
      );
      expect(spawner.processes.last.written.single, contains('find lib'));
      expect(spawner.arguments.first, isNot(contains('--settings')));

      emit(_result(tokens: 5), process: 1);
      await _settle();
      final done = events.whereType<DoneEvent>().single;
      expect(done.usage.inputTokens, 15);
    });

    test('거부하면 재시작하지 않고 턴을 끝낸다', () async {
      emit(_deniedStep(2, 'rm x'));
      emit(_result(denied: [_deniedAction]));
      await adapter.respondToApproval(_decision('agy_denied_2', approved: false));
      await _settle();
      expect(spawner.processes, hasLength(1));
      expect(events.whereType<DoneEvent>(), hasLength(1));
    });

    test('결과가 오기 전에 답해도 결과를 기다렸다가 잇는다', () async {
      emit(_deniedStep(2, 'find lib'));
      await adapter.respondToApproval(_decision('agy_denied_2', approved: true));
      await _settle();
      expect(spawner.processes, hasLength(1));

      emit(_result(denied: [_deniedAction]));
      await _settle();
      expect(spawner.processes, hasLength(2));
      expect(events.whereType<DoneEvent>(), isEmpty);
    });

    test('거부 명령이 여럿이면 모두 답한 뒤 승인한 것만 허용한다', () async {
      emit(_deniedStep(2, 'find lib'));
      emit(_deniedStep(3, 'rm x'));
      emit(_result(denied: [_deniedAction]));
      await adapter.respondToApproval(_decision('agy_denied_2', approved: true));
      await _settle();
      expect(spawner.processes, hasLength(1));

      await adapter.respondToApproval(_decision('agy_denied_3', approved: false));
      await _settle();
      expect(spawner.processes, hasLength(2));
      final args = spawner.arguments.last;
      final settings = args[args.indexOf('--settings') + 1];
      expect(settings, contains('find lib'));
      expect(settings, isNot(contains('rm x')));
    });

    test('중지하면 대기 중인 거부를 버린다', () async {
      emit(_deniedStep(2, 'find lib'));
      emit(_result(denied: [_deniedAction]));
      await adapter.interrupt();
      await adapter.respondToApproval(_decision('agy_denied_2', approved: true));
      await _settle();
      expect(spawner.processes, hasLength(1));
      expect(events.whereType<DoneEvent>(), isEmpty);
    });
  });
}
