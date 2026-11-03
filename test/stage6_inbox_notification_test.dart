import 'dart:io';

import 'package:agent_control_center/core/backend/agent_backend.dart';
import 'package:agent_control_center/core/models/agent_models.dart';
import 'package:agent_control_center/main.dart';
import 'package:agent_control_center/services/inbox_service.dart';
import 'package:agent_control_center/services/notification_service.dart';
import 'package:agent_control_center/services/permission_center.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FakeInboxProcessSpawner implements ProcessSpawner {
  String mailOutput = '101|||boss@company.com|||[긴급] 서버 점검 승인|||즉시 확인 바람';
  String imessageOutput = '501|||+821012345678|||배포 완료되었나요?';

  @override
  Future<ProcessResult> run(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) async {
    if (executable == 'osascript') {
      return ProcessResult(1, 0, mailOutput, '');
    }
    if (executable == 'sqlite3') {
      return ProcessResult(2, 0, imessageOutput, '');
    }
    return ProcessResult(3, 1, '', 'not found');
  }

  @override
  Future<ManagedProcess> spawn(
    String executable,
    List<String> arguments, {
    String? workingDirectory,
    Map<String, String>? environment,
  }) {
    throw UnimplementedError();
  }
}

void main() {
  group('6단계: Inbox 요약 및 알림 (InboxService, NotificationService, 딥링크)', () {
    test('원문 외부 모델 전송 범위 필터링, 핵심 3줄 요약 생성, OS 알림 기록 및 카카오톡 불가 처리가 동작한다', () async {
      final notificationService = NotificationService(enableOsPlugin: false);
      final inboxService = InboxService(
        notificationService: notificationService,
      );

      // 기본 경량 모델 확인
      expect(inboxService.summaryBackend, BackendType.antigravity);
      expect(inboxService.summaryModel, 'gemini-3-flash');

      // 1) 제목만 전송 정책 설정 후 긴 본문 입력
      inboxService.updateForwardingPolicy(ContentForwardingPolicy.subjectOnly);
      final summary1 = await inboxService.ingestAndSummarize(
        InboxMessageRaw(
          id: 'msg_1',
          source: InboxSourceType.gmail,
          sender: 'cto@company.com',
          subject: '[긴급] 보안 패치 배포 승인',
          body: '절대 외부 모델로 나가면 안 되는 기밀 본문 내용입니다.',
          receivedAt: DateTime.now(),
        ),
      );

      expect(summary1.threeLineSummary.length, 3);
      expect(summary1.urgency, UrgencyLevel.critical);
      expect(summary1.requiredAction, isNotEmpty);
      expect(
        summary1.forwardedSnippet,
        isNot(contains('절대 외부 모델로 나가면 안 되는 기밀 본문')),
      );
      expect(notificationService.history.length, 1);
      expect(
        notificationService.history.first.deepLink.targetId,
        summary1.id,
      );

      // 2) 앞 200자까지만 전송 정책 검증
      inboxService.updateForwardingPolicy(
        ContentForwardingPolicy.first200Chars,
      );
      final longBody = 'A' * 350;
      final summary2 = await inboxService.ingestAndSummarize(
        InboxMessageRaw(
          id: 'msg_2',
          source: InboxSourceType.slack,
          sender: '@pm',
          subject: '주간 스프린트 안내',
          body: longBody,
          receivedAt: DateTime.now(),
        ),
      );
      expect(summary2.forwardedSnippet, contains('...(후략)'));
      expect(summary2.forwardedSnippet, isNot(contains('A' * 250)));

      // 3) 카카오톡 개인 채팅은 공식 공개 읽기 API 미제공으로 UnsupportedError 발생
      expect(
        () => inboxService.ingestAndSummarize(
          InboxMessageRaw(
            id: 'kakao_1',
            source: InboxSourceType.kakaoTalk,
            sender: '친구',
            subject: '개인 톡',
            body: '내용',
            receivedAt: DateTime.now(),
          ),
        ),
        throwsUnsupportedError,
      );
    });

    test('권한이 허용된 소스에서 새 메일·메시지를 실시간/주기적으로 자동 감지하고 중복 메시지는 건너뛴다', () async {
      final notificationService = NotificationService(enableOsPlugin: false);
      final permissionCenter = PermissionCenter();
      final spawner = _FakeInboxProcessSpawner();
      final inboxService = InboxService(
        notificationService: notificationService,
        permissionCenter: permissionCenter,
        spawner: spawner,
      );
      addTearDown(inboxService.dispose);

      // 권한 미허용 상태에서는 자동 스캔 시 아무것도 가져오지 않음
      final initialScan = await inboxService.pollAllAuthorizedSourcesOnce();
      expect(initialScan, isEmpty);

      // macOS Mail(자동화 권한) 및 iMessage(Full Disk Access) 권한 허용
      permissionCenter.setOsPermissionScope(
        OsPermissionType.automationAppleEvents,
        ApprovalScope.always,
      );
      permissionCenter.setOsPermissionScope(
        OsPermissionType.fullDiskAccess,
        ApprovalScope.always,
      );

      // 첫 번째 자동 스캔 -> 새 메일 1건 + 새 iMessage 1건 자동 감지 및 요약!
      final firstScan = await inboxService.pollAllAuthorizedSourcesOnce();
      expect(firstScan.length, 2);
      expect(inboxService.summaries.length, 2);

      // 동일한 메시지 ID가 유지될 때 두 번째 자동 스캔 -> 중복 감지 방지(0건)
      final secondScan = await inboxService.pollAllAuthorizedSourcesOnce();
      expect(secondScan, isEmpty);
      expect(inboxService.summaries.length, 2);

      // 새로운 iMessage(ROWID 502) 도착 시 자동 스캔 -> 신규 1건만 정확히 감지!
      spawner.imessageOutput = '502|||+821099998888|||[긴급] 신규 장애 알림';
      final thirdScan = await inboxService.pollAllAuthorizedSourcesOnce();
      expect(thirdScan.length, 1);
      expect(thirdScan.single.source, InboxSourceType.imessage);
      expect(inboxService.summaries.length, 3);
    });

    testWidgets('푸시 알림 탭 시 딥링크로 Inbox 요약 상세 화면이 열리고 핵심 3줄과 모바일 설계안을 표시한다', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);

      final notificationService = NotificationService(enableOsPlugin: false);
      final inboxService = InboxService(
        notificationService: notificationService,
      );

      final summary = await inboxService.ingestAndSummarize(
        InboxMessageRaw(
          id: 'gmail_deep_1',
          source: InboxSourceType.gmail,
          sender: 'lead@company.com',
          subject: '[긴급] DB 마이그레이션 점검 요청',
          body: '오늘 밤 점검 전에 스키마 변경 내역을 확인해 주세요.',
          receivedAt: DateTime.now(),
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: ControlCenterHomeScreen(
            inboxServiceOverride: inboxService,
            notificationServiceOverride: notificationService,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 알림 탭(딥링크) 트리거 -> InboxSummaryDialog가 자동으로 열리고 해당 요약 상세 표시
      notificationService.triggerDeepLinkTap(
        notificationService.history.first.deepLink,
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(ValueKey('inbox_detail_${summary.id}')),
        findsOneWidget,
      );
      expect(find.textContaining('핵심 3줄 요약:'), findsOneWidget);
      expect(
        find.byKey(const ValueKey('kakaotalk_unsupported_chip')),
        findsOneWidget,
      );

      // 모바일 원격 알림(FCM/APNs) 설계안 토글 확인
      await tester.tap(
        find.byKey(const ValueKey('toggle_mobile_relay_spec')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('mobile_relay_spec_view')),
        findsOneWidget,
      );
    });
  });
}
