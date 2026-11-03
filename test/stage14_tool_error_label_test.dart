import 'dart:convert';

import 'package:agent_control_center/adapters/antigravity/antigravity_event_parser.dart';
import 'package:agent_control_center/core/models/agent_models.dart';
import 'package:agent_control_center/ui/widgets/timeline_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

ToolCallEvent _parseStep(Map<String, dynamic> fields) {
  final parser = AntigravityEventParser(sessionId: 's', model: 'gemini-4-argon');
  final events = parser.parseLine(
    jsonEncode({
      'event': 'step_update',
      'step_update': {
        'conversation_id': 'c',
        'step_index': 1,
        'step_type': 'run_command',
        'tool_info': {
          'name': 'run_command',
          'parameters': {'command': 'find lib test -type f'},
        },
        ...fields,
      },
    }),
  );
  return events.whereType<ToolCallEvent>().single;
}

void main() {
  test('출력 없이 실패한 단계는 실행 중으로 표시하지 않는다', () {
    final failed = _parseStep({'state': 'ERROR'});
    expect(failed.result, '실패');
    expect(failed.isError, isTrue);
    expect(failed.isRunning, isFalse);

    expect(_parseStep({'state': 'DONE', 'error': '권한 없음'}).result, '권한 없음');
  });

  test('실행 중이거나 완료된 단계의 문구는 그대로다', () {
    expect(_parseStep({'state': 'ACTIVE'}).result, '실행 중...');
    expect(_parseStep({'state': 'DONE'}).result, '실행 완료');
  });

  testWidgets('실패 카드에 실패 문구를 보여 준다', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ToolCallCard(event: _parseStep({'state': 'ERROR'}))),
      ),
    );
    expect(find.textContaining('실패'), findsOneWidget);
    expect(find.textContaining('실행 중'), findsNothing);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
  });
}
