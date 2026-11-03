import 'dart:convert';
import 'dart:io';

import 'package:agent_control_center/adapters/claude/claude_code_adapter.dart';
import 'package:agent_control_center/adapters/claude/claude_code_event_parser.dart';
import 'package:agent_control_center/adapters/codex/codex_adapter.dart';
import 'package:agent_control_center/adapters/codex/codex_event_parser.dart';
import 'package:agent_control_center/core/backend/agent_backend.dart';
import 'package:agent_control_center/core/backend/backend_registry.dart';
import 'package:agent_control_center/core/models/agent_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'stage1_antigravity_test.dart';

void main() {
  group('3단계: ClaudeCodeEventParser 및 ClaudeCodeAdapter 테스트 (fixture 기반)', () {
    test('claude_stream_sample.jsonl 을 파싱하여 승인, 스킬, 도구, Diff, 비용/토큰을 추출한다', () async {
      final lines = await File('test/fixtures/claude_stream_sample.jsonl')
          .readAsLines();
      final parser = ClaudeCodeEventParser(sessionId: 'sess_claude');

      final events = <AgentEvent>[];
      for (final line in lines) {
        events.addAll(parser.parseLine(line));
      }

      expect(
        parser.remoteSessionId,
        equals('50b7acd0-e58f-495a-af99-03c55665e5fb'),
      );
      expect(parser.model, equals('claude-opus-5-5'));
      expect(events.whereType<ApprovalRequestEvent>().length, equals(1));
      expect(
        events.whereType<ApprovalRequestEvent>().first.request.id,
        equals('req_perm_01'),
      );
      expect(events.whereType<SkillInvokedEvent>().length, equals(1));
      expect(
        events.whereType<SkillInvokedEvent>().first.skillName,
        equals('cli-hub-meta-skill'),
      );
      expect(events.whereType<FileDiffEvent>().length, equals(1));
      expect(events.whereType<MessageEvent>().length, equals(1));
      expect(events.whereType<DoneEvent>().length, equals(1));
      expect(
        events.whereType<DoneEvent>().first.usage.costUsd,
        closeTo(0.1908, 0.0001),
      );
    });

    test('ClaudeCodeAdapter respondToApproval 호출 시 control_response JSON을 stdin에 기록한다', () async {
      final spawner = FakeProcessSpawner();
      final adapter = ClaudeCodeAdapter(spawner: spawner);

      await adapter.start(
        const AgentSessionConfig(
          sessionId: 's_claude',
          backendType: BackendType.claudeCode,
          workingDirectory: '/tmp',
        ),
      );

      await adapter.respondToApproval(
        const ApprovalDecision(
          requestId: 'req_perm_01',
          approved: true,
          scope: ApprovalScope.once,
        ),
      );

      expect(spawner.lastProcess.writtenLines.length, equals(1));
      final payload =
          jsonDecode(spawner.lastProcess.writtenLines.first)
              as Map<String, dynamic>;
      expect(payload['type'], equals('control_response'));
      expect(
        (payload['response'] as Map)['request_id'],
        equals('req_perm_01'),
      );
      await adapter.dispose();
    });
  });

  group('3단계: CodexEventParser 및 CodexAdapter 테스트 (fixture 기반)', () {
    test('codex_stream_sample.jsonl 을 파싱하여 JSON-RPC 승인 요청과 JSONL 이벤트를 모두 추출한다', () async {
      final lines = await File('test/fixtures/codex_stream_sample.jsonl')
          .readAsLines();
      final parser = CodexEventParser(
        sessionId: 'sess_codex',
        model: 'gpt-6-sol',
      );

      final events = <AgentEvent>[];
      for (final line in lines) {
        events.addAll(parser.parseLine(line));
      }

      expect(
        parser.threadId,
        equals('01a19f33-d78a-7931-ae67-551d49134fc5'),
      );
      expect(events.whereType<ApprovalRequestEvent>().length, equals(1));
      expect(
        events.whereType<ApprovalRequestEvent>().first.request.id,
        equals('42'),
      );
      expect(events.whereType<SkillInvokedEvent>().length, equals(1));
      expect(
        events.whereType<SkillInvokedEvent>().first.skillName,
        equals('ego-browser'),
      );
      expect(events.whereType<FileDiffEvent>().length, equals(1));
      expect(events.whereType<MessageEvent>().length, equals(1));
      expect(events.whereType<DoneEvent>().length, equals(1));
      expect(
        events.whereType<DoneEvent>().first.usage.inputTokens,
        equals(23577),
      );
    });

    test('CodexAdapter respondToApproval 호출 시 JSON-RPC 2.0 응답을 stdin에 기록한다', () async {
      final spawner = FakeProcessSpawner();
      final adapter = CodexAdapter(spawner: spawner, useAppServer: true);

      await adapter.start(
        const AgentSessionConfig(
          sessionId: 's_codex',
          backendType: BackendType.codex,
          workingDirectory: '/tmp',
        ),
      );

      await adapter.respondToApproval(
        const ApprovalDecision(
          requestId: '42',
          approved: true,
          scope: ApprovalScope.session,
        ),
      );

      expect(spawner.lastProcess.writtenLines.length, equals(1));
      final rpc =
          jsonDecode(spawner.lastProcess.writtenLines.first)
              as Map<String, dynamic>;
      expect(rpc['id'], equals(42));
      expect((rpc['result'] as Map)['decision'], equals('acceptForSession'));
      await adapter.dispose();
    });

    test('BackendRegistry가 3종 백엔드를 생성하고 설치 상태를 점검한다', () async {
      final spawner = FakeProcessSpawner();
      final registry = BackendRegistry(spawner: spawner);

      expect(
        registry.create(BackendType.antigravity).backendType,
        equals(BackendType.antigravity),
      );
      expect(
        registry.create(BackendType.claudeCode).backendType,
        equals(BackendType.claudeCode),
      );
      expect(
        registry.create(BackendType.codex).backendType,
        equals(BackendType.codex),
      );

      final statuses = await registry.checkAllInstallations();
      expect(statuses.length, equals(3));
      expect(statuses[BackendType.antigravity]!.isInstalled, isTrue);
    });
  });
}
