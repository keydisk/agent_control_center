import 'dart:async';

import 'package:agent_control_center/core/backend/agent_backend.dart';
import 'package:agent_control_center/core/backend/backend_registry.dart';
import 'package:agent_control_center/core/models/agent_models.dart';
import 'package:agent_control_center/main.dart';
import 'package:agent_control_center/services/session_manager.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeAgentBackend implements AgentBackend {
  FakeAgentBackend(this.backendType);

  @override
  final BackendType backendType;

  final StreamController<AgentEvent> eventCtrl =
      StreamController<AgentEvent>.broadcast();
  final StreamController<String> rawLogCtrl =
      StreamController<String>.broadcast();

  bool started = false;
  bool interrupted = false;
  AgentSessionConfig? lastConfig;
  final List<String> sentPrompts = [];

  @override
  Stream<AgentEvent> get events => eventCtrl.stream;

  @override
  Stream<String> get rawLogs => rawLogCtrl.stream;

  @override
  String? get remoteConversationId => 'fake_conv_id';

  bool get isRunning => started && !interrupted;

  @override
  Future<void> start(AgentSessionConfig config) async {
    started = true;
    interrupted = false;
    lastConfig = config;
  }

  @override
  Future<void> send(
    String prompt, {
    List<String> attachments = const [],
  }) async {
    sentPrompts.add(prompt);
  }

  @override
  Future<void> respondToApproval(ApprovalDecision decision) async {}

  @override
  Future<void> respondToQuestion(
    String requestId,
    Map<String, List<String>> answers,
  ) async {}

  @override
  Future<void> interrupt() async {
    interrupted = true;
  }

  @override
  Future<void> resume(String conversationId, AgentSessionConfig config) async {}

  @override
  Future<void> dispose() async {
    await eventCtrl.close();
    await rawLogCtrl.close();
  }
}

void main() {
  group('4단계: 다중 세션 매니저 (병렬 실행, 충돌 감지, worktree 분리, 사용량 집계)', () {
    test('서로 다른 백엔드(Claude Code + Codex)로 병렬 실행 및 동일 디렉터리 충돌 감지/Worktree 분리가 동작한다', () async {
      final createdBackends = <String, FakeAgentBackend>{};
      final registry = BackendRegistry();
      for (final type in BackendType.values) {
        registry.register(type, ({spawner, hookBridge}) {
          final b = FakeAgentBackend(type);
          createdBackends['${type.id}_${createdBackends.length}'] = b;
          return b;
        });
      }

      final manager = SessionManager(
        registry: registry,
        worktreeAllocator: (baseDir, sessionId) async =>
            '$baseDir/.worktrees/$sessionId',
      );

      final s1 = manager.createSession(
        sessionId: 'impl_claude',
        title: '기능 구현',
        backendType: BackendType.claudeCode,
        workingDirectory: '/tmp/shared_project',
      );
      final s2 = manager.createSession(
        sessionId: 'review_codex',
        title: '코드 리뷰',
        backendType: BackendType.codex,
        workingDirectory: '/tmp/shared_project',
      );

      await manager.sendPrompt(s1.sessionId, '로그인 API를 구현해줘');
      expect(s1.status, SessionStatus.running);
      expect(s1.hasDirectoryConflict, isFalse);

      // 동일 디렉터리에서 두 번째 세션 병렬 실행 -> 충돌 감지!
      await manager.sendPrompt(s2.sessionId, '보안 취약점을 리뷰해줘');
      expect(s2.status, SessionStatus.running);
      expect(s1.hasDirectoryConflict, isTrue);
      expect(s2.hasDirectoryConflict, isTrue);

      // s2를 git worktree로 분리 -> 충돌 즉시 해소
      final isolatedPath = await manager.isolateSessionWithWorktree(
        s2.sessionId,
      );
      expect(isolatedPath, '/tmp/shared_project/.worktrees/review_codex');
      expect(s2.effectiveDirectory, isolatedPath);
      expect(s1.hasDirectoryConflict, isFalse);
      expect(s2.hasDirectoryConflict, isFalse);

      // 각 세션 완료 및 백엔드별 토큰/비용 집계 확인
      final b1 = s1.backend as FakeAgentBackend;
      final b2 = s2.backend as FakeAgentBackend;

      b1.eventCtrl.add(
        DoneEvent(
          id: 'done_1',
          sessionId: s1.sessionId,
          backend: BackendType.claudeCode,
          timestamp: DateTime.now(),
          usage: const TokenUsage(totalTokens: 1500, costUsd: 0.025),
          durationMs: 1200,
        ),
      );
      b2.eventCtrl.add(
        DoneEvent(
          id: 'done_2',
          sessionId: s2.sessionId,
          backend: BackendType.codex,
          timestamp: DateTime.now(),
          usage: const TokenUsage(totalTokens: 900, costUsd: 0.012),
          durationMs: 800,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));

      expect(s1.status, SessionStatus.completed);
      expect(s2.status, SessionStatus.completed);
      expect(
        manager.usageByBackend[BackendType.claudeCode]!.totalTokens,
        1500,
      );
      expect(
        manager.usageByBackend[BackendType.claudeCode]!.costUsd,
        closeTo(0.025, 0.0001),
      );
      expect(manager.usageByBackend[BackendType.codex]!.totalTokens, 900);

      // 개별 중지 / 재시도 / 다른 백엔드로 재실행 검증
      await manager.retrySession(s1.sessionId);
      expect(s1.status, SessionStatus.running);
      expect(b1.sentPrompts.length, 2);

      await manager.stopSession(s1.sessionId);
      expect(s1.status, SessionStatus.stopped);
      expect(b1.interrupted, isTrue);

      final rerunSession = await manager.rerunWithBackend(
        s1.sessionId,
        BackendType.antigravity,
      );
      expect(rerunSession, isNotNull);
      expect(rerunSession!.backendType, BackendType.antigravity);
      expect(rerunSession.lastPrompt, '로그인 API를 구현해줘');

      manager.dispose();
    });

    test('백그라운드·요약은 Antigravity가 전담하고, 별도 지시 또는 구현·리뷰는 Antigravity 판단 하에 Claude/Codex로 오케스트레이션한다', () async {
      final registry = BackendRegistry();
      for (final type in BackendType.values) {
        registry.register(
          type,
          ({spawner, hookBridge}) => FakeAgentBackend(type),
        );
      }

      final manager = SessionManager(
        registry: registry,
        worktreeAllocator: (baseDir, sessionId) async =>
            '$baseDir/.worktrees/$sessionId',
      );
      addTearDown(manager.dispose);

      final master = manager.createSession(
        sessionId: 'master_agy',
        title: '마스터 세션',
        backendType: BackendType.antigravity,
        workingDirectory: '/tmp/orch_repo',
      );

      // 1) 백그라운드 지시 및 요약 -> Antigravity가 직접 수행 (위임 없음)
      final summaryPlan = await manager.dispatchOrchestratedPrompt(
        master.sessionId,
        '오늘 수신된 메일과 슬랙 메시지를 백그라운드에서 요약해줘',
      );
      expect(summaryPlan.isDelegated, isFalse);
      expect(
        summaryPlan.subTasks.single.targetBackend,
        BackendType.antigravity,
      );
      expect(manager.sessions.length, 1);

      // 2) 복합 작업(구현 + 코드 리뷰) 지시 -> Antigravity가 판단하여 Claude Code(구현) + Codex(리뷰, worktree 격리)로 병렬 위임
      final complexPlan = await manager.dispatchOrchestratedPrompt(
        master.sessionId,
        '결제 승인 모듈을 구현하고 보안 취약점 코드 리뷰도 해줘',
      );
      expect(complexPlan.isDelegated, isTrue);
      expect(complexPlan.subTasks.length, 2);
      expect(
        complexPlan.subTasks[0].targetBackend,
        BackendType.claudeCode,
      );
      expect(
        complexPlan.subTasks[1].targetBackend,
        BackendType.codex,
      );

      // 마스터 세션 + Claude 서브 세션 + Codex 서브 세션 = 총 3개 세션
      expect(manager.sessions.length, 3);
      final codexSession = manager.sessions.last;
      expect(codexSession.backendType, BackendType.codex);
      expect(codexSession.isolatedWorktreePath, isNotNull);
    });

    testWidgets('MultiSessionSidebar UI에서 다중 세션 전환, 충돌 배너 표시 및 worktree 분리가 동작한다', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final registry = BackendRegistry();
      for (final type in BackendType.values) {
        registry.register(
          type,
          ({spawner, hookBridge}) => FakeAgentBackend(type),
        );
      }

      final manager = SessionManager(
        registry: registry,
        worktreeAllocator: (baseDir, sessionId) async =>
            '$baseDir/.worktrees/$sessionId',
      );

      final s1 = manager.createSession(
        sessionId: 's1',
        title: 'Claude 구현 작업',
        backendType: BackendType.claudeCode,
        workingDirectory: '/tmp/repo',
      );
      final s2 = manager.createSession(
        sessionId: 's2',
        title: 'Codex 리뷰 작업',
        backendType: BackendType.codex,
        workingDirectory: '/tmp/repo',
      );

      await manager.sendPrompt(s1.sessionId, '첫 번째 작업');
      await manager.sendPrompt(s2.sessionId, '두 번째 작업');

      await tester.pumpWidget(
        MaterialApp(
          home: ControlCenterHomeScreen(sessionManagerOverride: manager),
        ),
      );
      await tester.pumpAndSettle();

      // 두 세션 카드가 사이드바에 표시되는지 확인
      expect(find.byKey(const ValueKey('session_card_s1')), findsOneWidget);
      expect(find.byKey(const ValueKey('session_card_s2')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('active_session_conflict_banner')),
        findsOneWidget,
      );

      // 상단 배너의 'git worktree로 분리' 버튼 클릭
      await tester.tap(
        find.byKey(const ValueKey('banner_isolate_worktree_btn')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('active_session_conflict_banner')),
        findsNothing,
      );
      expect(find.textContaining('격리 Worktree:'), findsOneWidget);

      manager.dispose();
    });
  });
}
