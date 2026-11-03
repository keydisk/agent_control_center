import 'package:flutter_test/flutter_test.dart';
import 'package:agent_control_center/core/models/agent_models.dart';
import 'package:agent_control_center/services/provider_usage_service.dart';

void main() {
  test('공급자별 한도는 서로 다른 비율과 초기화 시각을 보존한다', () {
    final claude = parseClaudeWindow({
      'utilization': 42,
      'resets_at': '2099-01-01T00:00:00Z',
    });
    final codex = parseCodexWindow({
      'used_percent': 75,
      'resets_at': 4070908800,
    });
    final agy = parseAntigravityUsage('''{
      "command": {"data": {"groups": [{
        "displayName": "Gemini",
        "buckets": [
          {"bucketId": "session", "remainingFraction": "0.3", "resetTime": "2099-01-01T00:00:00Z"},
          {"bucketId": "weekly", "remainingFraction": 0.8, "resetTime": "2099-01-07T00:00:00Z"}
        ]
      }]}}
    }''');

    expect(claude?.usedPercent, 42);
    expect(codex?.usedPercent, 75);
    expect(agy.single.backend, BackendType.antigravity);
    expect(agy.single.fiveHour?.usedPercent, 70);
    expect(agy.single.weekly?.usedPercent, 20);
    expect(agy.single.weekly?.resetsAt, isNot(agy.single.fiveHour?.resetsAt));
  });

  test('없는 한도는 수치를 만들지 않는다', () {
    expect(parseClaudeWindow({}), isNull);
    expect(parseCodexWindow({}), isNull);
    expect(parseAntigravityUsage('{}'), isEmpty);
  });
}
