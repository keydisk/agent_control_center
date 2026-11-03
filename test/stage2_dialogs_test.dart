import 'package:agent_control_center/core/models/agent_models.dart';
import 'package:agent_control_center/services/permission_center.dart';
import 'package:agent_control_center/ui/widgets/approval_and_question_dialogs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('2단계: PermissionCenter 및 승인/질문 다이얼로그 테스트', () {
    test('일반 권한은 세션/항상 규칙으로 캐시되지만 파괴적 작업은 절대 캐시되지 않고 매번 확인한다', () {
      final center = PermissionCenter();
      final normalReq = ApprovalRequestData(
        id: 'req_1',
        sessionId: 'sess_1',
        backend: BackendType.antigravity,
        toolName: 'run_command',
        arguments: const {'CommandLine': 'flutter test'},
        category: ApprovalCategory.shellCommand,
        reason: '테스트 실행',
        isDestructive: false,
        createdAt: DateTime.now(),
        targetResource: 'flutter test',
      );

      expect(center.checkPreApproved(normalReq), isNull);

      center.recordDecision(
        normalReq,
        const ApprovalDecision(
          requestId: 'req_1',
          approved: true,
          scope: ApprovalScope.always,
        ),
      );

      expect(center.checkPreApproved(normalReq), isNotNull);
      expect(center.checkPreApproved(normalReq)!.approved, isTrue);

      // 파괴적 작업 (git push --force)
      final destructiveReq = ApprovalRequestData(
        id: 'req_2',
        sessionId: 'sess_1',
        backend: BackendType.claudeCode,
        toolName: 'Bash',
        arguments: const {'command': 'git push origin main --force'},
        category: ApprovalCategory.destructive,
        reason: '강제 푸시',
        isDestructive: true,
        createdAt: DateTime.now(),
        targetResource: 'git push origin main --force',
      );

      // 설령 always로 전달하더라도 강제로 once로 격하되고 다음번에 자동 승인되지 않음
      final recorded = center.recordDecision(
        destructiveReq,
        const ApprovalDecision(
          requestId: 'req_2',
          approved: true,
          scope: ApprovalScope.always,
        ),
      );
      expect(recorded.scope, equals(ApprovalScope.once));
      expect(center.checkPreApproved(destructiveReq), isNull);
    });

    testWidgets('UnifiedApprovalDialog: 일반 요청은 4개 버튼 모두 표시, 파괴적 작업은 항상/세션 버튼 숨김', (
      tester,
    ) async {
      ApprovalDecision? lastDecision;
      final normalReq = ApprovalRequestData(
        id: 'req_ui_1',
        sessionId: 's1',
        backend: BackendType.antigravity,
        toolName: 'run_command',
        arguments: const {'CommandLine': 'ls -la'},
        category: ApprovalCategory.shellCommand,
        reason: '목록 조회',
        isDestructive: false,
        createdAt: DateTime.now(),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UnifiedApprovalDialog(
              request: normalReq,
              onDecision: (d) => lastDecision = d,
            ),
          ),
        ),
      );

      expect(find.byKey(const ValueKey('approval_btn_deny')), findsOneWidget);
      expect(find.byKey(const ValueKey('approval_btn_once')), findsOneWidget);
      expect(
        find.byKey(const ValueKey('approval_btn_session')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('approval_btn_always')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('approval_btn_session')));
      expect(lastDecision?.scope, equals(ApprovalScope.session));

      // 파괴적 작업 다이얼로그 렌더링
      final destructiveReq = ApprovalRequestData(
        id: 'req_ui_2',
        sessionId: 's1',
        backend: BackendType.codex,
        toolName: 'run_command',
        arguments: const {'CommandLine': 'rm -rf /tmp/build'},
        category: ApprovalCategory.destructive,
        reason: '폴더 삭제',
        isDestructive: true,
        createdAt: DateTime.now(),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: UnifiedApprovalDialog(
              request: destructiveReq,
              onDecision: (d) => lastDecision = d,
            ),
          ),
        ),
      );

      expect(find.byKey(const ValueKey('approval_btn_deny')), findsOneWidget);
      expect(find.byKey(const ValueKey('approval_btn_once')), findsOneWidget);
      expect(find.byKey(const ValueKey('approval_btn_session')), findsNothing);
      expect(find.byKey(const ValueKey('approval_btn_always')), findsNothing);
    });

    testWidgets('AgentQuestionDialog: 에이전트 질문 선택지 및 직접 입력을 백엔드 응답 형식으로 반환한다', (
      tester,
    ) async {
      Map<String, List<String>>? submitted;
      final qReq = QuestionRequestData(
        id: 'q_1',
        sessionId: 's1',
        backend: BackendType.antigravity,
        createdAt: DateTime.now(),
        questions: const [
          AgentQuestionItem(
            id: 'arch',
            question: '선호하는 상태관리 라이브러리는 무엇인가요?',
            options: [
              QuestionOption(label: 'Riverpod'),
              QuestionOption(label: 'Bloc'),
            ],
          ),
        ],
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AgentQuestionDialog(
              request: qReq,
              onSubmitAnswers: (ans) => submitted = ans,
            ),
          ),
        ),
      );

      await tester.tap(find.byKey(const ValueKey('q_opt_arch_Bloc')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('question_submit_btn')));
      expect(submitted?['arch'], equals(['Bloc']));
    });
  });
}
